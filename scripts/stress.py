#!/usr/bin/env python3
"""Long-running stress test of the router's tunnel, run from a LAN client.

  python3 scripts/stress.py run [--duration 24h] [--out DIR] [options]
  python3 scripts/stress.py report DIR

The client must sit behind the router on a tunneled port or SSID. Every probe
writes one JSON line to DIR/metrics.jsonl ("t" is the unix time, "k" the kind);
DIR/router.log keeps the router's logread, DIR/meta.json the environment at
start, DIR/report.md the summary (written on exit, or by "report" at any time).

What it measures:
  http    HTTPS requests through the tunnel and to a direct (split) host:
          curl timings, code, error. With TPROXY the TCP handshake ends on
          the router, so "conn" is the Wi-Fi/LAN hop and "tls"/"ttfb" are the
          tunnel.
  ping    ICMP to the router and to a direct host, 10 s windows (the kill
          switch rejects ICMP into the tunnel, so no tunneled target).
  dns     the router's DNS (xray) for a cached and a fresh name, and raw UDP
          through the tunnel (OpenDNS on port 5353: XTLS Vision drops UDP/443
          on purpose, so QUIC falls back to TCP).
  exit    exit IP and Cloudflare colo; a change or the WAN IP is an event.
  burst   N parallel HTTPS requests at once.
  speed   periodic download (1 and 4 streams) and upload; probes taken
          meanwhile carry "load": 1 (latency under load).
  stream  one long rate-limited download over HTTP/1.1: breaks, stalls, session
          length (curl 8.5 cuts a rate-limited HTTP/2 download at its 10 MiB
          stream window with PROTOCOL_ERROR).
  wifi    this client's signal, bitrate, BSSID, interface counters, load.
  router  via ssh: CPU, softirq, memory, xray RSS/CPU/fds/threads, conntrack,
          tunnel counters, xvpn status (active server, state, restarts), the
          client's station stats on the router.
  event   changes worth a look: server switch, xray restart, reboot, exit IP
          change, leak, BSSID change, suspend of this machine, stalls, and
          sub_change: what an hourly subscription refresh added, dropped or moved
          (names and addresses only), to explain xray restarts after it.

Keep the machine awake for long runs, e.g.:
  systemd-inhibit --what=sleep:idle python3 scripts/stress.py run --duration 24h
"""
import argparse
import json
import os
import random
import re
import select
import signal
import string
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

TUNNEL_URLS = [
	('gstatic', 'https://www.gstatic.com/generate_204', False),
	('cloudflare', 'https://cp.cloudflare.com/generate_204', False),
	('ovh', 'https://proof.ovh.net/files/1Mb.dat', True),
]
DIRECT_URLS = [('direct_ya', 'https://ya.ru/', True)]
BURST_URLS = [
	'https://www.gstatic.com/generate_204',
	'https://cp.cloudflare.com/generate_204',
	'https://www.google.com/generate_204',
]
TRACE_URLS = ['https://one.one.one.one/cdn-cgi/trace', 'https://cp.cloudflare.com/cdn-cgi/trace']
DOWN_URL = 'https://proof.ovh.net/files/1Gb.dat'
UP_URL = 'https://speed.cloudflare.com/__up'

STOP = threading.Event()
OUT = None
CHILDREN = set()
CHILDREN_LOCK = threading.Lock()


class Out:
	def __init__(self, path):
		self.f = open(path, 'a', buffering=1, encoding='utf-8')
		self.lock = threading.Lock()
		self.load = 0
		self.minute = Counter()

	def rec(self, kind, **kw):
		r = {'t': round(time.time(), 3), 'k': kind}
		if self.load and 'load' not in kw:
			r['load'] = 1
		r.update({k: v for k, v in kw.items() if v is not None})
		line = json.dumps(r, ensure_ascii=False, separators=(',', ':'))
		with self.lock:
			self.f.write(line + '\n')

	def event(self, ev, **kw):
		self.rec('event', ev=ev, **kw)
		log('event %s %s' % (ev, json.dumps(kw, ensure_ascii=False)))


def log(msg):
	print(time.strftime('[%H:%M:%S] ') + msg, flush=True)


def parse_duration(s):
	m = re.fullmatch(r'(\d+(?:\.\d+)?)([smhd]?)', s.strip())
	if not m:
		raise argparse.ArgumentTypeError('bad duration: ' + s)
	return float(m.group(1)) * {'': 1, 's': 1, 'm': 60, 'h': 3600, 'd': 86400}[m.group(2)]


def rand_label(n=10):
	return ''.join(random.choice(string.ascii_lowercase + string.digits) for _ in range(n))


def pct(vals, p):
	vals = sorted(v for v in vals if v is not None)
	if not vals:
		return None
	return vals[min(len(vals) - 1, max(0, int(round(p / 100 * len(vals) + 0.5)) - 1))]


def popen(cmd, **kw):
	p = subprocess.Popen(cmd, **kw)
	with CHILDREN_LOCK:
		CHILDREN.add(p)
	return p


def reap(p):
	with CHILDREN_LOCK:
		CHILDREN.discard(p)


def run(cmd, timeout, **kw):
	p = popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **kw)
	try:
		so, se = p.communicate(timeout=timeout)
	except subprocess.TimeoutExpired:
		p.kill()
		so, se = p.communicate()
		return -9, so, (se or '') + ' [killed by timeout]'
	finally:
		reap(p)
	return p.returncode, so, se


def every(interval, fn, delay=0.0):
	nxt = time.monotonic() + delay
	while not STOP.wait(max(0.0, nxt - time.monotonic())):
		try:
			fn()
		except Exception as e:
			OUT.rec('error', where=fn.__name__, err=repr(e))
		nxt += interval
		if nxt < time.monotonic():
			nxt = time.monotonic() + interval


def curl(args, timeout, out='/dev/null', **kw):
	cmd = ['curl', '-sS', '-o', out, '-w', '%{json}', '--max-time', str(timeout)] + args
	rc, so, se = run(cmd, timeout + 15, **kw)
	try:
		j = json.loads(so)
	except ValueError:
		j = {}
	return rc, j, (j.get('errormsg') or se.strip() or None) if rc else None


def ms(j, k):
	v = j.get(k)
	return round(v * 1000, 1) if isinstance(v, (int, float)) else None


# --- probes running on this machine -------------------------------------------------

def http_probe(name, url, head, timeout):
	def http():
		rc, j, err = curl(['-I'] + [url] if head else [url], timeout)
		if STOP.is_set():
			return
		code = j.get('http_code') or 0
		ok = rc == 0 and 0 < code < 500
		OUT.minute['http_n'] += 1
		OUT.minute['http_ok'] += ok
		OUT.rec('http', tgt=name, ok=int(ok), rc=rc, code=code, dns=ms(j, 'time_namelookup'),
			conn=ms(j, 'time_connect'), tls=ms(j, 'time_appconnect'), ttfb=ms(j, 'time_starttransfer'),
			total=ms(j, 'time_total'), ip=j.get('remote_ip') or None, err=err)
	http.__name__ = 'http_' + name
	return http


def ping_loop(target, window):
	while not STOP.is_set():
		p = popen(['ping', '-D', '-O', '-n', '-i', '1', '-W', '2', target],
			stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
		recv, noans, rtts, load, other = set(), set(), [], 0, Counter()
		start = time.monotonic()
		got = False
		while not STOP.is_set():
			r, _, _ = select.select([p.stdout], [], [], 1.0)
			line = p.stdout.readline() if r else None
			if r and line == '':
				break
			if line and not line.startswith('PING'):
				m = re.search(r'icmp_seq=(\d+).*time=([\d.]+) ms', line)
				if m:
					recv.add(int(m.group(1)))
					rtts.append(float(m.group(2)))
				elif 'no answer yet' in line:
					noans.add(int(re.search(r'icmp_seq=(\d+)', line).group(1)))
				else:
					# an error reply (unreachable, filtered) is a lost packet too
					q = re.search(r'icmp_seq=(\d+)', line)
					if q:
						noans.add(int(q.group(1)))
					other[re.sub(r'^\[[\d.]+\] |icmp_seq=\d+ ', '', line).strip()[:100]] += 1
				got |= bool(m) or 'icmp_seq' in line
			load |= OUT.load
			if time.monotonic() - start >= window:
				flush_ping(target, recv, noans, rtts, load, other)
				recv, noans, rtts, load, other = set(), set(), [], 0, Counter()
				start = time.monotonic()
		p.kill()
		rc = p.wait()
		reap(p)
		if STOP.is_set():
			return
		if not got:
			OUT.rec('error', where='ping', tgt=target, rc=rc, err='; '.join(other)[:200] or None)
			log('ping %s does not work (%s), ICMP probe off' % (target, '; '.join(other) or 'rc=%d' % rc))
			return
		flush_ping(target, recv, noans, rtts, load, other)
		OUT.rec('error', where='ping', tgt=target, rc=rc)
		STOP.wait(5)


def flush_ping(target, recv, noans, rtts, load, other):
	lost = len(noans - recv)
	sent = len(recv) + lost
	if not sent and not other:
		return
	jit = None
	if len(rtts) > 1:
		jit = round(sum(abs(a - b) for a, b in zip(rtts, rtts[1:])) / (len(rtts) - 1), 2)
	OUT.rec('ping', tgt=target, sent=sent, lost=lost, min=min(rtts, default=None),
		p50=pct(rtts, 50), p95=pct(rtts, 95), max=max(rtts, default=None), jit=jit,
		load=load or None, other=dict(other) or None)


DIG_RE = {'status': re.compile(r'status: (\w+)'), 'qt': re.compile(r'Query time: (\d+) msec'),
	'ans': re.compile(r'ANSWER: (\d+)')}


def dig(name, server, port, qname):
	rc, so, se = run(['dig', '+tries=1', '+time=5', '-p', str(port), '@' + server, qname], 12)
	if STOP.is_set():
		return
	f = {k: (r.search(so).group(1) if r.search(so) else None) for k, r in DIG_RE.items()}
	ok = rc == 0 and f['status'] == 'NOERROR' and int(f['ans'] or 0) > 0
	OUT.minute['dns_n'] += 1
	OUT.minute['dns_ok'] += ok
	OUT.rec('dns', tgt=name, ok=int(ok), rc=rc, status=f['status'],
		ms=int(f['qt']) if f['qt'] else None, ans=int(f['ans'] or 0),
		err=None if ok else (f['status'] or next((l for l in (so + se).splitlines() if 'timed out' in l or 'error' in l),
			(so + se).strip()[-160:]))[:160])


def dns_probe(router_ip):
	def dns():
		dig('router_cached', router_ip, 53, 'www.google.com')
		dig('router_fresh', router_ip, 53, rand_label() + '.github.io')
		dig('udp_tunnel', '208.67.222.222', 5353, rand_label() + '.github.io')
	return dns


class ExitWatch:
	def __init__(self):
		self.ip = None
		self.colo = None
		self.wan_ip = None

	def exit_ip(self):
		for url in TRACE_URLS:
			rc, so, se = run(['curl', '-sS', '--max-time', '10', url], 20)
			kv = dict(l.split('=', 1) for l in so.splitlines() if '=' in l)
			if rc == 0 and 'ip' in kv:
				break
		else:
			OUT.rec('exit', ok=0, err=(se.strip() or 'no ip')[:160])
			return
		ip, colo = kv['ip'], kv.get('colo')
		OUT.rec('exit', ok=1, ip=ip, colo=colo, loc=kv.get('loc'))
		if self.ip and ip != self.ip:
			OUT.event('exit_change', old=self.ip, new=ip, old_colo=self.colo, colo=colo)
		if self.wan_ip and ip == self.wan_ip:
			OUT.event('leak', ip=ip, note='exit IP equals the router WAN IP')
		self.ip, self.colo = ip, colo


def burst_probe(n, timeout):
	def burst():
		urls = [BURST_URLS[i % len(BURST_URLS)] for i in range(n)]
		t0 = time.monotonic()
		with ThreadPoolExecutor(n) as ex:
			res = list(ex.map(lambda u: curl([u], timeout), urls))
		wall = time.monotonic() - t0
		if STOP.is_set():
			return
		tot = [ms(j, 'time_total') for rc, j, _ in res if rc == 0]
		errs = Counter('%s: %s' % (u.split('/')[2], (err or '')[:60]) for u, (rc, j, err) in zip(urls, res) if rc)
		OUT.rec('burst', n=n, ok=len(tot), wall=round(wall, 2), p50=pct(tot, 50), p95=pct(tot, 95),
			max=max(tot, default=None), errs=dict(errs.most_common(3)) or None)
	return burst


def speed_probe(secs, streams, down_url, up_url):
	def speed():
		OUT.load = 1
		try:
			one = lambda: curl([down_url], secs)
			for test, n in (('down1', 1), ('down%d' % streams, streams)):
				with ThreadPoolExecutor(n) as ex:
					res = list(ex.map(lambda _: one(), range(n)))
				speed_rec(test, res)
				STOP.wait(3)
			if up_url:
				with open('/dev/zero', 'rb') as z:
					res = [curl(['-X', 'POST', '-T', '-', up_url], secs, stdin=z)]
				speed_rec('up1', res, 'size_upload')
		finally:
			OUT.load = 0
	return speed


def speed_rec(test, res, field='size_download'):
	if STOP.is_set():
		return
	size = sum(j.get(field) or 0 for _, j, _ in res)
	secs = max((j.get('time_total') or 0 for _, j, _ in res), default=0)
	# curl exits 28 when --max-time ends the transfer, which is the normal end here
	bad = [err for rc, _, err in res if rc not in (0, 28)]
	mbps = round(size * 8 / secs / 1e6, 2) if secs else None
	OUT.rec('speed', test=test, mbps=mbps, bytes=size, secs=round(secs, 2),
		ok=int(not bad and bool(size)), err=bad[0][:160] if bad else None)
	log('speed %s %s Mbit/s' % (test, mbps))


def stream_loop(rate, url, report_every, stall_after, hang_after):
	while not STOP.is_set():
		p = popen(['curl', '-sS', '-N', '--http1.1', '--limit-rate', rate, '-o', '-', url],
			stdout=subprocess.PIPE, stderr=subprocess.PIPE)
		fd = p.stdout.fileno()
		t0 = last = win_start = time.monotonic()
		total = win = 0
		max_gap = 0.0
		reason = 'eof'
		while not STOP.is_set():
			r, _, _ = select.select([fd], [], [], 1.0)
			now = time.monotonic()
			if r:
				chunk = os.read(fd, 65536)
				if not chunk:
					break
				gap = now - last
				if gap >= stall_after:
					OUT.event('stream_stall', secs=round(gap, 1), at_bytes=total)
				max_gap = max(max_gap, gap)
				last = now
				total += len(chunk)
				win += len(chunk)
			elif now - last >= hang_after:
				reason = 'hang'
				break
			if now - win_start >= report_every:
				OUT.rec('stream', kbps=round(win * 8 / (now - win_start) / 1000, 1), bytes=total,
					gap=round(max(max_gap, now - last), 1), age=round(now - t0))
				win, max_gap, win_start = 0, 0.0, now
		p.kill()
		_, se = p.communicate()
		reap(p)
		if STOP.is_set():
			return
		dur = time.monotonic() - t0
		err = se.decode(errors='replace').strip()[:160] or None
		OUT.rec('stream_end', secs=round(dur), bytes=total, rc=p.returncode, reason=reason, err=err)
		OUT.event('stream_break', secs=round(dur), reason=reason, err=err)
		STOP.wait(5)


class Wifi:
	def __init__(self, iface):
		self.iface = iface
		self.bssid = None
		self.ssid = None
		self.oper = None

	def wifi(self):
		i = self.iface
		st = {}
		for k in ('rx_bytes', 'tx_bytes', 'rx_errors', 'tx_errors', 'rx_dropped', 'tx_dropped'):
			try:
				st[k] = int(open('/sys/class/net/%s/statistics/%s' % (i, k)).read())
			except OSError:
				pass
		oper = read_or(f'/sys/class/net/{i}/operstate')
		link = level = None
		for l in read_or('/proc/net/wireless', '').splitlines():
			if l.strip().startswith(i + ':'):
				f = l.split()
				link, level = float(f[2].rstrip('.')), float(f[3].rstrip('.'))
		bssid = ssid = chan = rate = sig = None
		rc, so, _ = run(['nmcli', '-t', '-f', 'IN-USE,BSSID,SSID,CHAN,RATE,SIGNAL', 'dev', 'wifi', 'list',
			'--rescan', 'no', 'ifname', i], 10)
		for l in so.splitlines():
			f = [x.replace('\\:', ':') for x in re.split(r'(?<!\\):', l)]
			if f[0] == '*' and len(f) >= 6:
				bssid, ssid, chan, rate, sig = f[1], f[2], f[3], f[4], int(f[5]) if f[5].isdigit() else None
		OUT.rec('wifi', iface=i, oper=oper, link=link, level=level, ssid=ssid, bssid=bssid, chan=chan,
			rate=rate, signal=sig, load1=float(read_or('/proc/loadavg', '0').split()[0]), **st)
		if self.oper and oper != self.oper:
			OUT.event('link_' + str(oper), iface=i)
		if self.bssid and bssid and (bssid, ssid) != (self.bssid, self.ssid):
			OUT.event('wifi_roam', old=self.bssid, new=bssid, old_ssid=self.ssid, ssid=ssid)
		self.oper = oper
		if bssid:
			self.bssid, self.ssid = bssid, ssid


def read_or(path, default=None):
	try:
		with open(path) as f:
			return f.read().strip()
	except OSError:
		return default


def heartbeat():
	last = time.time()
	while not STOP.wait(5):
		now = time.time()
		if now - last > 30:
			OUT.event('suspend_gap', secs=round(now - last), note='this machine was asleep or frozen')
		last = now


def console(started):
	n = Counter(OUT.minute)
	OUT.minute.clear()
	part = lambda a, b: '%d/%d' % (n[a], n[b]) if n[b] else '-'
	log('up %s | http ok %s | dns ok %s' % (
		time.strftime('%H:%M:%S', time.gmtime(time.time() - started)), part('http_ok', 'http_n'),
		part('dns_ok', 'dns_n')))


# --- router over ssh ----------------------------------------------------------------

ROUTER_SH = r'''
echo "@uptime $(cut -d' ' -f1 /proc/uptime)"
echo "@loadavg $(cut -d' ' -f1-3 /proc/loadavg)"
echo "@cpu $(head -1 /proc/stat)"
echo "@ncpu $(grep -c '^cpu[0-9]' /proc/stat)"
awk '/^MemTotal:|^MemAvailable:/{sub(":","",$1); print "@" $1 " " $2}' /proc/meminfo
set -- $(pidof xray); x=$1
if [ -n "$x" ]; then
	echo "@xray_pid $x"
	echo "@xray_n $#"
	echo "@xray_rss $(awk '/^VmRSS/{print $2}' /proc/$x/status)"
	echo "@xray_thr $(awk '/^Threads/{print $2}' /proc/$x/status)"
	echo "@xray_ticks $(cut -d' ' -f14,15 /proc/$x/stat)"
	echo "@xray_fds $(ls /proc/$x/fd | wc -l)"
fi
d=; for p in $(pidof ucode); do grep -q xvpnd.uc /proc/$p/cmdline && d=/proc/$p; done
[ -n "$d" ] && echo "@xvpnd_rss $(awk '/^VmRSS/{print $2}' $d/status)"
echo "@ct $(cat /proc/sys/net/netfilter/nf_conntrack_count) $(cat /proc/sys/net/netfilter/nf_conntrack_max)"
for c in tun_up tun_down; do echo "@$c $(nft list counter inet xvpn $c 2>/dev/null | grep -o 'bytes [0-9]*')"; done
w=$(ubus -t 5 call network.interface.wan status 2>/dev/null)
echo "@wan_ip $(echo "$w" | jsonfilter -e '@["ipv4-address"][0].address')"
wd=$(echo "$w" | jsonfilter -e '@.l3_device')
[ -n "$wd" ] && echo "@wan_dev $(grep "$wd:" /proc/net/dev | sed 's/.*://')"
for i in $(iw dev | awk '/Interface/{print $2}'); do
	s=$(iw dev $i station get %MAC% 2>/dev/null) && { echo "@sta_if $i"; echo "$s" | sed -n 's/^\t\([^:]*\):[ \t]*/@sta \1=/p'; }
done
echo "@submd5 $(md5sum /etc/xvpn/subs/*.json 2>/dev/null | cut -d' ' -f1 | tr '\n' ' ')"
echo "@status"
ubus -t 5 call xvpn status
'''


class Router:
	def __init__(self, host, mac, ssh_opts):
		self.host = host
		self.mac = mac
		self.ssh = ['ssh'] + ssh_opts + [host]
		self.prev = None
		self.ok = None
		self.exit = None
		self.tested = {}
		self.subs = None
		self.sub_md5 = None

	def sh(self, script, timeout=25):
		return run(self.ssh + [script], timeout)

	def router(self):
		rc, so, se = self.sh(ROUTER_SH.replace('%MAC%', self.mac))
		if rc != 0 or '@status' not in so:
			OUT.rec('router', ok=0, rc=rc, err=se.strip()[:160] or None)
			if self.ok is not False:
				OUT.event('router_unreachable', rc=rc, err=se.strip()[:160])
			self.ok = False
			return
		if self.ok is False:
			OUT.event('router_back')
		self.ok = True
		head, _, status = so.partition('@status\n')
		v, sta = {}, {}
		for l in head.splitlines():
			if l.startswith('@sta '):
				k, _, val = l[5:].partition('=')
				sta[k.strip()] = val.strip()
			elif l.startswith('@'):
				k, _, val = l[1:].partition(' ')
				v[k] = val.strip()
		try:
			st = json.loads(status)
		except ValueError:
			st = {}
		now = time.monotonic()
		cpu = [int(x) for x in v.get('cpu', '').split()[1:9]]
		ticks = sum(int(x) for x in v.get('xray_ticks', '').split()) if v.get('xray_ticks') else None
		r = {'ok': 1, 'uptime': float(v.get('uptime', 0)), 'load1': fnum(v.get('loadavg', '').split()[:1]),
			'mem_avail': inum(v.get('MemAvailable')), 'mem_total': inum(v.get('MemTotal')),
			'xray_pid': inum(v.get('xray_pid')), 'xray_n': inum(v.get('xray_n')),
			'xray_rss': inum(v.get('xray_rss')), 'xray_thr': inum(v.get('xray_thr')),
			'xray_fds': inum(v.get('xray_fds')), 'xvpnd_rss': inum(v.get('xvpnd_rss'))}
		ct = v.get('ct', '').split()
		if len(ct) == 2:
			r['ct'], r['ct_max'] = int(ct[0]), int(ct[1])
		for c in ('tun_up', 'tun_down'):
			m = re.search(r'bytes (\d+)', v.get(c, ''))
			r[c] = int(m.group(1)) if m else None
		wan = v.get('wan_dev', '').split()
		if len(wan) >= 9:
			r['wan_rx'], r['wan_tx'] = int(wan[0]), int(wan[8])
		r['wan_ip'] = v.get('wan_ip') or None
		if self.prev and len(cpu) == 8 and len(self.prev['cpu']) == 8:
			d = [a - b for a, b in zip(cpu, self.prev['cpu'])]
			tot = sum(d) or 1
			r['cpu'] = round(100 * (tot - d[3] - d[4]) / tot, 1)
			r['sirq'] = round(100 * d[6] / tot, 1)
			dt = now - self.prev['mono']
			if ticks is not None and self.prev['ticks'] is not None and r['xray_pid'] == self.prev['pid']:
				r['xray_cpu'] = round(100 * (ticks - self.prev['ticks']) / 100 / dt, 1)
			for c in ('tun_up', 'tun_down', 'wan_rx', 'wan_tx'):
				if r.get(c) is not None and self.prev.get(c) is not None and r[c] >= self.prev[c]:
					r[c + '_mbps'] = round((r[c] - self.prev[c]) * 8 / dt / 1e6, 2)
		if sta:
			r['sta_if'] = v.get('sta_if')
			r['sta_signal'] = inum((sta.get('signal') or '').split()[:1])
			r['sta_tx_rate'] = fnum((sta.get('tx bitrate') or '').split()[:1])
			r['sta_rx_rate'] = fnum((sta.get('rx bitrate') or '').split()[:1])
			r['sta_tx_retries'] = inum(sta.get('tx retries'))
			r['sta_tx_failed'] = inum(sta.get('tx failed'))
			r['sta_inactive'] = inum((sta.get('inactive time') or '').split()[:1])
		if v.get('submd5') != self.sub_md5:
			self.sub_changed(v.get('submd5'))
		servers = {s.get('id'): s for s in st.get('servers') or []}
		act = servers.get(st.get('active')) or {}
		r.update({'state': st.get('state'), 'active': st.get('active'), 'active_name': act.get('name'),
			'active_latency': act.get('latency'), 'fails': st.get('fails'),
			'xray_restarts': st.get('xray_restarts'), 'passthrough': st.get('passthrough'),
			'testing': st.get('testing'), 'last_error': st.get('last_error'),
			'quarantined': sum(1 for s in servers.values() if s.get('quarantined')),
			'servers_alive': sum(1 for s in servers.values() if s.get('latency') is not None),
			'speed': st.get('speed')})
		OUT.rec('router', **r)
		for s in servers.values():
			if s.get('tested') and self.tested.get(s['id']) != s['tested']:
				self.tested[s['id']] = s['tested']
				OUT.rec('server', id=s['id'], name=s.get('name'), latency=s.get('latency'),
					speed=s.get('speed'), quarantined=int(bool(s.get('quarantined'))), limited=int(bool(s.get('limited'))))
		if self.exit and r['wan_ip']:
			self.exit.wan_ip = r['wan_ip']
		p = self.prev
		if p:
			if r['uptime'] < p['uptime']:
				OUT.event('router_reboot', uptime=r['uptime'])
			if r['xray_pid'] != p['pid']:
				OUT.event('xray_pid_change', old=p['pid'], new=r['xray_pid'])
			if r['active'] != p['active']:
				OUT.event('server_switch', old=p['active_name'], new=r['active_name'], last_error=r['last_error'])
			if r['state'] != p['state']:
				OUT.event('state', old=p['state'], new=r['state'], last_error=r['last_error'])
			if (r['xray_restarts'] or 0) > (p['restarts'] or 0):
				OUT.event('xray_restart', n=r['xray_restarts'], last_error=r['last_error'])
			if r['last_error'] and r['last_error'] != p['last_error']:
				OUT.event('last_error', err=r['last_error'])
		self.prev = {'cpu': cpu, 'mono': now, 'ticks': ticks, 'pid': r['xray_pid'], 'uptime': r['uptime'],
			'active': r['active'], 'active_name': r['active_name'], 'state': r['state'],
			'restarts': r['xray_restarts'], 'last_error': r['last_error'],
			**{c: r.get(c) for c in ('tun_up', 'tun_down', 'wan_rx', 'wan_tx')}}

	def sub_changed(self, md5):
		"""The subscription caches changed (xvpn refreshes them hourly): which servers came, went
		or moved, to see what makes xvpn reload xray after an update. Names and addresses only."""
		rc, so, _ = self.sh('for f in /etc/xvpn/subs/*.json; do echo "@$f"; '
			'jsonfilter -i $f -e "@.skipped"; echo @n; jsonfilter -i $f -e "@.servers[*].name"; '
			'echo @a; jsonfilter -i $f -e "@.servers[*].address"; done')
		if rc != 0:
			return
		cur = parse_subs(so)
		if self.subs is not None:
			for f, (skipped, srv) in cur.items():
				old_skipped, old = self.subs.get(f, (None, []))
				names, onames = [n for n, _ in srv], [n for n, _ in old]
				moved = [(n, dict(old)[n], a) for n, a in srv if n in dict(old) and dict(old)[n] != a]
				OUT.event('sub_change', sub=os.path.basename(f), skipped=skipped, old_skipped=old_skipped,
					gone=[n for n in onames if n not in names], new=[n for n in names if n not in onames],
					moved=moved, count=len(srv))
		self.subs, self.sub_md5 = cur, md5

	def logread(self, path):
		with open(path, 'a', buffering=1, encoding='utf-8') as f:
			while not STOP.is_set():
				p = popen(self.ssh + ['logread -f'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
					text=True, bufsize=1, errors='replace')
				while not STOP.is_set():
					r, _, _ = select.select([p.stdout], [], [], 1.0)
					if not r:
						continue
					line = p.stdout.readline()
					if line == '':
						break
					if 'dropbear[' in line:
						continue
					f.write(time.strftime('%Y-%m-%dT%H:%M:%S ') + line)
					if re.search(r'xvpn|xray', line) and re.search(r'(?i)\.(err|warn|crit|alert|emerg)|error|fail', line):
						OUT.rec('rlog', line=line.strip()[:300])
				p.kill()
				p.wait()
				reap(p)
				if not STOP.is_set():
					f.write(time.strftime('%Y-%m-%dT%H:%M:%S ') + '--- logread stream ended, reconnecting\n')
					STOP.wait(10)


def parse_subs(out):
	"""Output of the loop in Router.sub_changed -> {file: (skipped, [(name, address)])}."""
	res = {}
	for block in out.split('@/etc/')[1:]:
		f, _, rest = block.partition('\n')
		skipped, _, rest = rest.partition('@n\n')
		names, _, addrs = rest.partition('@a\n')
		names, addrs = names.splitlines(), addrs.splitlines()
		res['/etc/' + f.strip()] = (inum(skipped.strip()), list(zip(names, addrs)))
	return res


def inum(x):
	if isinstance(x, list):
		x = x[0] if x else None
	try:
		return int(x)
	except (TypeError, ValueError):
		return None


def fnum(x):
	if isinstance(x, list):
		x = x[0] if x else None
	try:
		return float(x)
	except (TypeError, ValueError):
		return None


def meta(args, router, iface, path):
	sh = lambda c: run(['sh', '-c', c], 15)[1].strip()
	m = {'started': time.strftime('%Y-%m-%dT%H:%M:%S%z'), 'args': vars(args), 'host': {
		'uname': sh('uname -a'), 'iface': iface, 'routes': sh('ip route'), 'addr': sh('ip -br addr'),
		'resolv': sh('grep -v "^#" /etc/resolv.conf'), 'curl': sh('curl --version | head -1')}}
	if router:
		rc, so, _ = router.sh('cat /etc/openwrt_release; echo @@; xray version | head -1; echo @@; '
			'opkg list-installed | grep -E "xvpn|xray"; echo @@; uci show xvpn.main; echo @@; '
			'ubus -t 5 call xvpn status; echo @@; cat /proc/cpuinfo | grep -iE "model|processor" | head -4')
		parts = so.split('@@\n')
		m['router'] = {'release': parts[0].strip() if parts else None}
		if len(parts) >= 6:
			m['router'].update({'xray': parts[1].strip(), 'packages': parts[2].strip(), 'uci': parts[3].strip(),
				'cpu': parts[5].strip()})
			try:
				st = json.loads(parts[4])
				st['servers'] = [{k: s.get(k) for k in ('id', 'name', 'proto', 'transport', 'latency', 'auto')}
					for s in st.get('servers') or []]
				m['router']['status'] = st
			except ValueError:
				pass
	with open(path, 'w', encoding='utf-8') as f:
		json.dump(m, f, ensure_ascii=False, indent=1)


def cmd_run(args):
	global OUT
	out = args.out or os.path.join('stress', time.strftime('%Y%m%d-%H%M%S'))
	os.makedirs(out, exist_ok=True)
	OUT = Out(os.path.join(out, 'metrics.jsonl'))
	route = run(['ip', 'route', 'show', 'default'], 5)[1].split()
	iface = args.iface or (route[route.index('dev') + 1] if 'dev' in route else None)
	gw = route[route.index('via') + 1] if 'via' in route else '192.168.1.1'
	router_host = None if args.no_router else (args.router or 'root@' + gw)
	mac = read_or(f'/sys/class/net/{iface}/address', '') if iface else ''
	ctl = os.path.join(tempfile.gettempdir(), 'xvs-%C')
	ssh_opts = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'ServerAliveInterval=5',
		'-o', 'ServerAliveCountMax=3', '-o', 'ControlMaster=auto', '-o', 'ControlPath=' + ctl,
		'-o', 'ControlPersist=120']
	router = Router(router_host, mac, ssh_opts) if router_host else None
	if router and router.sh('true', 15)[0] != 0:
		log('ssh %s failed, router metrics off (use --router or --no-router)' % router_host)
		router = None
	meta(args, router, iface, os.path.join(out, 'meta.json'))
	log('writing to %s (iface %s, router %s)' % (out, iface, router_host if router else 'off'))
	OUT.event('start', duration=args.duration or None, gw=gw)

	ew = ExitWatch()
	jobs = [(heartbeat,), (every, 60, lambda: console(started), 60)]
	for i, (name, url, head) in enumerate(TUNNEL_URLS + DIRECT_URLS):
		jobs.append((every, args.http_every, http_probe(name, url, head, args.http_timeout), i * args.http_every / 4))
	for t in args.ping.split(',') if args.ping else [gw, '77.88.8.8']:
		jobs.append((ping_loop, t, 10))
	jobs.append((every, args.dns_every, dns_probe(gw), 2))
	jobs.append((every, args.exit_every, ew.exit_ip, 1))
	if args.burst:
		jobs.append((every, args.burst_every, burst_probe(args.burst, args.http_timeout), 30))
	if args.speed_every:
		jobs.append((every, args.speed_every, speed_probe(args.speed_secs, args.streams, args.down_url,
			args.up_url), args.speed_delay))
	if args.stream_rate != '0':
		jobs.append((stream_loop, args.stream_rate, args.down_url, 60, 10, 120))
	if iface and os.path.isdir(f'/sys/class/net/{iface}/wireless'):
		jobs.append((every, 10, Wifi(iface).wifi, 0))
	if router:
		router.exit = ew
		jobs.append((every, args.router_every, router.router, 0))
		jobs.append((router.logread, os.path.join(out, 'router.log')))

	started = time.time()
	threads = [threading.Thread(target=j[0], args=j[1:], daemon=True) for j in jobs]
	for t in threads:
		t.start()

	def stop(sig, _):
		log('got signal %d, stopping' % sig)
		STOP.set()
	signal.signal(signal.SIGINT, stop)
	signal.signal(signal.SIGTERM, stop)
	signal.signal(signal.SIGHUP, stop)
	STOP.wait(args.duration or None)
	STOP.set()
	with CHILDREN_LOCK:
		for p in list(CHILDREN):
			try:
				p.kill()
			except OSError:
				pass
	for t in threads:
		t.join(10)
	OUT.event('stop', secs=round(time.time() - started))
	OUT.f.close()
	path = report(out)
	log('report: ' + path)


# --- report ------------------------------------------------------------------------

def fmt(x, nd=0):
	if x is None:
		return '–'
	return ('%.' + str(nd) + 'f') % x


def ts(t):
	return time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(t))


def dur(s):
	s = int(s)
	return '%dч %02dм %02dс' % (s // 3600, s % 3600 // 60, s % 60) if s >= 3600 else '%dм %02dс' % (s // 60, s % 60)


def table(head, rows):
	out = ['| ' + ' | '.join(head) + ' |', '|' + '---|' * len(head)]
	out += ['| ' + ' | '.join(str(c) for c in r) + ' |' for r in rows]
	return '\n'.join(out) + '\n'


def report(d):
	recs = defaultdict(list)
	with open(os.path.join(d, 'metrics.jsonl'), encoding='utf-8') as f:
		for l in f:
			try:
				r = json.loads(l)
			except ValueError:
				continue
			recs[r['k']].append(r)
	allt = [r['t'] for rs in recs.values() for r in rs]
	if not allt:
		return None
	t0, t1 = min(allt), max(allt)
	o = ['# Стресс-тест VPN: %s\n' % os.path.basename(os.path.abspath(d)),
		'Период: %s — %s (%s), записей: %d\n' % (ts(t0), ts(t1), dur(t1 - t0), len(allt))]
	tunnel = {n for n, _, _ in TUNNEL_URLS}

	http = recs['http']
	if http:
		o.append('## HTTP\n')
		o.append('conn — TCP до роутера (TPROXY отвечает сам), tls/ttfb — путь через туннель. Время в мс.\n')
		rows = []
		for tgt in sorted({r['tgt'] for r in http}):
			rs = [r for r in http if r['tgt'] == tgt]
			ok = [r for r in rs if r['ok']]
			idle = [r['total'] for r in ok if not r.get('load')]
			loaded = [r['total'] for r in ok if r.get('load')]
			rows.append([tgt + ('' if tgt in tunnel else ' (прямой)'), len(rs), fmt(100 * len(ok) / len(rs), 2) + '%',
				fmt(pct([r.get('conn') for r in ok], 50)), fmt(pct([r.get('tls') for r in ok], 50)),
				fmt(pct([r.get('ttfb') for r in ok], 50)), fmt(pct(idle, 50)), fmt(pct(idle, 95)), fmt(pct(idle, 99)),
				fmt(max(idle, default=None)), fmt(pct(loaded, 50))])
		o.append(table(['цель', 'n', 'успех', 'conn p50', 'tls p50', 'ttfb p50', 'total p50', 'p95', 'p99', 'max',
			'p50 под нагрузкой'], rows))
		errs = Counter((r['tgt'], (r.get('err') or 'http %s' % r.get('code'))[:90]) for r in http if not r['ok'])
		if errs:
			o.append('\nОшибки (топ 15):\n\n' + table(['цель', 'ошибка', 'раз'],
				[[t, e.replace('|', '/'), n] for (t, e), n in errs.most_common(15)]))

		o.append('\n## Перерывы связи через туннель\n')
		o.append('Подряд неудачные запросы ко всем туннельным целям (≥2 подряд). «прямой» — работал ли '
			'прямой хост в это время (нет → провайдер/Wi-Fi), «роутер» — потери ping до роутера.\n')
		th = sorted((r for r in http if r['tgt'] in tunnel), key=lambda r: r['t'])
		outages, run_ = [], []
		for r in th:
			if r['ok']:
				if len(run_) >= 2:
					outages.append((run_[0]['t'], r['t'], run_))
				run_ = []
			else:
				run_.append(r)
		if len(run_) >= 2:
			outages.append((run_[0]['t'], run_[-1]['t'], run_))
		gw = next((r.get('gw') for r in recs['event'] if r.get('ev') == 'start'), None)
		gw_ping = [r for r in recs['ping'] if r['tgt'] == gw]
		rows = []
		for a, b, rs in outages:
			dr = [r for r in http if r['tgt'] not in tunnel and a <= r['t'] <= b]
			pr = [r for r in gw_ping if a - 10 <= r['t'] <= b + 10]
			sent = sum(r['sent'] for r in pr)
			rows.append([ts(a), dur(b - a), len(rs), Counter((r.get('err') or '')[:50] for r in rs).most_common(1)[0][0].replace('|', '/'),
				'%d/%d ok' % (sum(r['ok'] for r in dr), len(dr)) if dr else '–',
				'%s%%' % fmt(100 * sum(r['lost'] for r in pr) / sent) if sent else '–'])
		o.append(table(['начало', 'длительность', 'ошибок', 'типичная ошибка', 'прямой', 'роутер'], rows) if rows else 'Не было.\n')
		if outages:
			o.append('\nВсего перерывов: %d, суммарно %s.\n' % (len(outages), dur(sum(b - a for a, b, _ in outages))))

		o.append('\n## По часам (туннельные HTTP)\n')
		hours = defaultdict(list)
		for r in th:
			hours[int(r['t'] // 3600)].append(r)
		router_h = defaultdict(list)
		for r in recs['router']:
			router_h[int(r['t'] // 3600)].append(r)
		rows = []
		for h in sorted(hours):
			rs = hours[h]
			ok = [r['total'] for r in rs if r['ok']]
			rr = [r for r in router_h.get(h, []) if r.get('ok')]
			rows.append([time.strftime('%m-%d %H:00', time.localtime(h * 3600)), len(rs),
				fmt(100 * len(ok) / len(rs), 2) + '%', fmt(pct(ok, 50)), fmt(pct(ok, 95)),
				fmt(sum(r.get('cpu') or 0 for r in rr) / len(rr), 1) if rr else '–',
				fmt(max((r.get('xray_rss') or 0 for r in rr), default=0) / 1024, 1) if rr else '–',
				', '.join(sorted({str(r.get('active_name')) for r in rr}))[:40] if rr else '–'])
		o.append(table(['час', 'n', 'успех', 'p50', 'p95', 'CPU роутера ср.%', 'xray RSS max МБ', 'сервер'], rows))

	if recs['ping']:
		o.append('\n## Ping\n')
		rows = []
		for tgt in sorted({r['tgt'] for r in recs['ping']}):
			for lbl, sel in (('без нагрузки', lambda r: not r.get('load')), ('под нагрузкой', lambda r: r.get('load'))):
				rs = [r for r in recs['ping'] if r['tgt'] == tgt and sel(r)]
				sent = sum(r['sent'] for r in rs)
				if not sent:
					continue
				lost = sum(r['lost'] for r in rs)
				bad = sum(1 for r in rs if r['lost'])
				rows.append([tgt, lbl, sent, fmt(100 * lost / sent, 3) + '%', bad, fmt(pct([r.get('p50') for r in rs], 50), 1),
					fmt(pct([r.get('p95') for r in rs], 95), 1), fmt(max((r.get('max') or 0 for r in rs)), 1),
					fmt(pct([r.get('jit') for r in rs], 50), 1)])
		o.append(table(['цель', 'режим', 'пакетов', 'потери', 'окон с потерями', 'p50', 'p95', 'max', 'jitter p50'], rows))
		o.append('\nДо роутера — Wi-Fi/LAN; до 77.88.8.8 — провайдер мимо туннеля (раздельное туннелирование).\n')

	if recs['dns']:
		o.append('\n## DNS\n')
		rows = []
		for tgt in sorted({r['tgt'] for r in recs['dns']}):
			rs = [r for r in recs['dns'] if r['tgt'] == tgt]
			ok = [r.get('ms') for r in rs if r['ok']]
			st = Counter(r.get('status') or 'timeout' for r in rs if not r['ok'])
			rows.append([tgt, len(rs), fmt(100 * len(ok) / len(rs), 2) + '%', fmt(pct(ok, 50)), fmt(pct(ok, 95)),
				fmt(max(ok, default=None)), ', '.join('%s×%d' % kv for kv in st.most_common(3)) or '–'])
		o.append(table(['запрос', 'n', 'успех', 'p50 мс', 'p95', 'max', 'сбои'], rows))
		o.append('\nrouter_* — DNS xray на роутере, udp_tunnel — сырой UDP через туннель до OpenDNS:5353.\n')

	if recs['burst']:
		rs = recs['burst']
		n = sum(r['n'] for r in rs)
		ok = sum(r['ok'] for r in rs)
		o.append('\n## Пачки параллельных запросов\n')
		o.append('Пачек: %d по %d, успешно %s%% запросов; p95 внутри пачки: медиана %s мс, худшая %s мс; '
			'полностью успешных пачек %d.\n' % (len(rs), rs[0]['n'], fmt(100 * ok / n, 2),
			fmt(pct([r.get('p95') for r in rs], 50)), fmt(max((r.get('p95') or 0 for r in rs))),
			sum(1 for r in rs if r['ok'] == r['n'])))
		errs = Counter()
		for r in rs:
			errs.update(r.get('errs') or {})
		if errs:
			o.append('\n' + table(['ошибка', 'раз'], [[e.replace('|', '/'), c] for e, c in errs.most_common(5)]))

	if recs['speed']:
		o.append('\n## Скорость, Мбит/с\n')
		rows = []
		for test in sorted({r['test'] for r in recs['speed']}):
			v = [r['mbps'] for r in recs['speed'] if r['test'] == test and r.get('ok') and r.get('mbps')]
			n = sum(1 for r in recs['speed'] if r['test'] == test)
			rows.append([test, n, len(v), fmt(min(v, default=None), 1), fmt(pct(v, 50), 1), fmt(max(v, default=None), 1)])
		o.append(table(['тест', 'замеров', 'успешных', 'min', 'медиана', 'max'], rows))
		o.append('\n' + table(['время', 'тест', 'Мбит/с', 'ошибка'], [[ts(r['t']), r['test'], fmt(r.get('mbps'), 1),
			(r.get('err') or '').replace('|', '/')] for r in recs['speed']][-60:]))

	if recs['stream'] or recs['stream_end']:
		ends = recs['stream_end']
		stalls = [r for r in recs['event'] if r.get('ev') == 'stream_stall']
		o.append('\n## Долгое соединение\n')
		o.append('Обрывов: %d; зависаний ≥10 с: %d (макс. %s с); сессии: медиана %s, самая долгая %s.\n' % (
			len(ends), len(stalls), fmt(max((r['secs'] for r in stalls), default=None), 1),
			dur(pct([r['secs'] for r in ends], 50) or 0) if ends else '–',
			dur(max((r['secs'] for r in ends), default=0)) if ends else 'весь тест без обрыва'))
		if ends:
			o.append('\n' + table(['обрыв', 'жило', 'причина', 'ошибка'], [[ts(r['t']), dur(r['secs']), r.get('reason'),
				(r.get('err') or '').replace('|', '/')] for r in ends][-30:]))

	if recs['exit']:
		ex = recs['exit']
		ips = Counter((r.get('ip'), r.get('colo')) for r in ex if r['ok'])
		o.append('\n## Выходной IP\n')
		o.append('Проверок %d, неудачных %d.\n\n' % (len(ex), sum(1 for r in ex if not r['ok'])))
		o.append(table(['IP', 'colo', 'раз'], [[ip, c, n] for (ip, c), n in ips.most_common(10)]))

	rr = [r for r in recs['router'] if r.get('ok')]
	if recs['router']:
		o.append('\n## Роутер\n')
		k = max(1, len(rr) // 10)
		first, last = rr[:k], rr[-k:]
		avg = lambda rs, f: (lambda v: sum(v) / len(v) if v else None)([r[f] for r in rs if r.get(f) is not None])
		rows = []
		for f, name, div in (('cpu', 'CPU %', 1), ('sirq', 'softirq %', 1), ('xray_cpu', 'xray CPU % ядра', 1),
				('load1', 'load1', 1), ('mem_avail', 'MemAvailable МБ', 1024), ('xray_rss', 'xray RSS МБ', 1024),
				('xvpnd_rss', 'xvpnd RSS МБ', 1024), ('xray_thr', 'xray потоки', 1), ('xray_fds', 'xray fd', 1),
				('ct', 'conntrack', 1), ('tun_down_mbps', 'туннель вниз Мбит/с', 1), ('sta_signal', 'сигнал клиента дБм', 1),
				('sta_tx_rate', 'tx bitrate клиенту', 1)):
			v = [r[f] / div for r in rr if r.get(f) is not None]
			if not v:
				continue
			rows.append([name, fmt(min(v), 1), fmt(pct(v, 50), 1), fmt(pct(v, 95), 1), fmt(max(v), 1),
				fmt(avg(first, f) / div if avg(first, f) is not None else None, 1),
				fmt(avg(last, f) / div if avg(last, f) is not None else None, 1)])
		o.append(table(['метрика', 'min', 'p50', 'p95', 'max', 'начало (10%)', 'конец (10%)'], rows))
		o.append('\nРост RSS/fd/потоков xray от начала к концу без перезапусков — признак утечки.\n')
		o.append('\nОпросов: %d, роутер недоступен: %d раз. xray_restarts в конце: %s, перезапусков xray (смена pid): %d.\n' % (
			len(recs['router']), len(recs['router']) - len(rr), rr[-1].get('xray_restarts') if rr else '–',
			sum(1 for r in recs['event'] if r.get('ev') == 'xray_pid_change')))
		if len(rr) > 1 and rr[0].get('sta_tx_failed') is not None and rr[-1].get('sta_tx_failed') is not None:
			o.append('Wi-Fi со стороны роутера: tx retries +%s, tx failed +%s.\n' % (
				(rr[-1].get('sta_tx_retries') or 0) - (rr[0].get('sta_tx_retries') or 0),
				rr[-1]['sta_tx_failed'] - rr[0]['sta_tx_failed']))
		act = Counter(r.get('active_name') for r in rr)
		o.append('\nАктивный сервер (доля опросов): ' + ', '.join('%s %s%%' % (n, fmt(100 * c / len(rr))) for n, c in act.most_common()) + '\n')

	if recs['wifi']:
		w = recs['wifi']
		o.append('\n## Wi-Fi этой машины\n')
		sig = [r.get('signal') for r in w]
		lvl = [r.get('level') for r in w]
		o.append('Сигнал nmcli %%: min %s, p50 %s; уровень дБм: min %s, p50 %s; BSSID: %s; каналы: %s.\n' % (
			fmt(min((s for s in sig if s is not None), default=None)), fmt(pct(sig, 50)),
			fmt(min((s for s in lvl if s is not None), default=None)), fmt(pct(lvl, 50)),
			', '.join(sorted({str(r.get('bssid')) for r in w})), ', '.join(sorted({str(r.get('chan')) for r in w}))))
		if len(w) > 1:
			o.append('Счётчики интерфейса за тест: rx_errors +%s, tx_errors +%s, rx_dropped +%s, tx_dropped +%s.\n' % tuple(
				(w[-1].get(k) or 0) - (w[0].get(k) or 0) for k in ('rx_errors', 'tx_errors', 'rx_dropped', 'tx_dropped')))

	ev = [r for r in recs['event'] if r.get('ev') not in ('start', 'stop')]
	o.append('\n## События\n')
	if ev:
		o.append('Всего %d: %s\n\n' % (len(ev), ', '.join('%s×%d' % kv for kv in Counter(r['ev'] for r in ev).most_common())))
		o.append(table(['время', 'событие', 'подробности'], [[ts(r['t']), r['ev'], json.dumps(
			{k: v for k, v in r.items() if k not in ('t', 'k', 'ev', 'load')}, ensure_ascii=False).replace('|', '/')]
			for r in ev[-200:]]))
	else:
		o.append('Не было.\n')
	if recs['rlog']:
		# logread prefix, xray's own time stamp and the queried name vary: group by the rest
		norm = lambda l: re.sub(r'response for \S+', 'response for *', re.sub(
			r'^.*?\]: (\d{4}/\d\d/\d\d [\d:.]+ )?', '', l))[:160]
		groups = Counter(norm(r['line']) for r in recs['rlog'])
		o.append('\n## Ошибки в журнале роутера\n\nВсего %d строк, полный журнал — router.log.\n\n' % len(recs['rlog'])
			+ table(['раз', 'сообщение'], [[n, m.replace('|', '/')] for m, n in groups.most_common(20)]))
	if recs['error']:
		o.append('\n## Сбои самого скрипта\n\n' + table(['где', 'раз'], Counter(r.get('where') for r in recs['error']).most_common()))

	path = os.path.join(d, 'report.md')
	with open(path, 'w', encoding='utf-8') as f:
		f.write('\n'.join(o))
	return path


def main():
	ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	sub = ap.add_subparsers(dest='cmd', required=True)
	r = sub.add_parser('run', help='run the test')
	r.add_argument('--duration', type=parse_duration, default=0, help='e.g. 90m, 24h, 2d; 0 = until Ctrl+C')
	r.add_argument('--out', help='output dir (default stress/<date-time>)')
	r.add_argument('--router', help='ssh target of the router (default root@<gateway>)')
	r.add_argument('--no-router', action='store_true', help='no ssh to the router')
	r.add_argument('--iface', help='client interface (default: the default route)')
	r.add_argument('--ping', help='comma-separated ICMP targets (default: gateway,77.88.8.8)')
	r.add_argument('--http-every', type=parse_duration, default=5, help='per target (default 5s)')
	r.add_argument('--http-timeout', type=int, default=15)
	r.add_argument('--dns-every', type=parse_duration, default=10)
	r.add_argument('--exit-every', type=parse_duration, default=60)
	r.add_argument('--burst', type=int, default=30, help='parallel requests per burst, 0 = off')
	r.add_argument('--burst-every', type=parse_duration, default=60)
	r.add_argument('--speed-every', type=parse_duration, default=1800, help='0 = off (default 30m)')
	r.add_argument('--speed-delay', type=parse_duration, default=120, help='first speed test after (default 2m)')
	r.add_argument('--speed-secs', type=int, default=20, help='length of each speed test')
	r.add_argument('--streams', type=int, default=4, help='parallel streams in the second download test')
	r.add_argument('--down-url', default=DOWN_URL)
	r.add_argument('--up-url', default=UP_URL, help='empty = no upload test')
	r.add_argument('--stream-rate', default='16k', help='rate of the long download (curl --limit-rate), 0 = off')
	r.add_argument('--router-every', type=parse_duration, default=15)
	p = sub.add_parser('report', help='(re)build report.md from a run dir')
	p.add_argument('dir')
	a = ap.parse_args()
	if a.cmd == 'run':
		cmd_run(a)
	else:
		path = report(a.dir)
		print(open(path, encoding='utf-8').read() if path else 'no records')


if __name__ == '__main__':
	main()
