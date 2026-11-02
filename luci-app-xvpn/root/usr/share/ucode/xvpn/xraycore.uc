// SPDX-License-Identifier: MIT
// xray-core from the GitHub releases of XTLS/Xray-core (#31): the zip for the arch of the
// router, checked against its .dgst, its xray binary unpacked into XRAY_GH_BIN beside the one
// of the feed (/usr/bin/xray, the package xray-core), which stays for the way back.

'use strict';

import { readfile, open, popen, unlink, rename, stat, access, readlink, symlink } from 'fs';
import { cursor } from 'uci';
import { mkdir_p, read_json, write_json, run, shq, RUN_DIR, XRAY_FEED_BIN, XRAY_GH_BIN } from 'xvpn.util';

export const GH_DIR = '/usr/lib/xvpn';
// { tag, version, installed, sha256 } of XRAY_GH_BIN
export const GH_META = `${GH_DIR}/xray.json`;
// the install job: { id, state: running|done|failed|lost, step, tag, started, error, version, via }
export const JOB_FILE = `${RUN_DIR}/xray-job.json`;
// symlink to the pid of the running job
const JOB_LOCK = `${RUN_DIR}/xray-job.lock`;
// the test override: a file:// URL of a directory laid out like the releases
const RELEASES = getenv('XVPN_XRAY_RELEASES') || 'https://github.com/XTLS/Xray-core/releases';
// the zip of arm64 is ~12 MB, xray in it ~33 MB
const MAX_ZIP = 64 * 1024 * 1024;
// free space left in GH_DIR after the install
const SPARE = 1024 * 1024;

export function valid_tag(t) {
	return type(t) == 'string' && !!match(t, /^v[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$/);
};

// 26.10.31 or v26.10.31 against 25.1.30-r1: < 0 older, 0 the same, > 0 newer
export function compare(a, b) {
	let pa = split(replace(replace(a ?? '', /^v/, ''), /-.*/, ''), '.');
	let pb = split(replace(replace(b ?? '', /^v/, ''), /-.*/, ''), '.');
	for (let i = 0; i < 3; i++) {
		let d = int(pa[i] ?? 0) - int(pb[i] ?? 0);
		if (d)
			return d;
	}
	return 0;
};

// DISTRIB_ARCH of /etc/openwrt_release
export function arch() {
	let m = match(readfile('/etc/openwrt_release') ?? '', /(^|\n)DISTRIB_ARCH='?([^'\n]+)/);
	return m ? m[2] : null;
};

// the release asset for an OpenWrt arch, null when XTLS builds none
export function asset(a) {
	let name = null;
	if (type(a) != 'string')
		return null;
	if (a == 'x86_64')
		name = '64';
	else if (match(a, /^i386/))
		name = '32';
	else if (match(a, /^aarch64/))
		name = 'arm64-v8a';
	else if (match(a, /^arm_(arm926|fa526|xscale)/))
		name = 'arm32-v5';
	else if (match(a, /^arm_(arm1176|mpcore)/))
		name = 'arm32-v6';
	else if (match(a, /^arm_/))
		name = 'arm32-v7a';
	else if (match(a, /^mipsel_/))
		name = 'mips32le';
	else if (match(a, /^mips_/))
		name = 'mips32';
	else if (match(a, /^mips64el_/))
		name = 'mips64le';
	else if (match(a, /^mips64_/))
		name = 'mips64';
	else if (match(a, /^riscv64/))
		name = 'riscv64';
	else if (match(a, /^loongarch64/))
		name = 'loong64';
	return name ? `Xray-linux-${name}.zip` : null;
};

// the SHA2-256 line of a .dgst file
export function parse_dgst(text) {
	let m = match(text ?? '', /(^|\n)SHA2-256= *([0-9a-fA-F]{64})/);
	return m ? lc(m[2]) : null;
};

// the tag of the redirect of releases/latest
export function tag_of(url) {
	let m = match(url ?? '', /\/releases\/tag\/(v[0-9.]+)[[:space:]]*$/);
	return (m && valid_tag(m[1])) ? m[1] : null;
};

// "Xray 26.10.31 (Xray, Penetrates Everything.) ..." of `xray version`
export function parse_version(out) {
	let m = match(out ?? '', /^Xray ([0-9]+\.[0-9]+\.[0-9]+)/);
	return m ? m[1] : null;
};

function le(s, off, n) {
	let v = 0;
	for (let i = n - 1; i >= 0; i--)
		v = v * 256 + ord(s, off + i);
	return v;
}

function read_at(f, off, n) {
	if (!f.seek(off, 0))
		return null;
	let s = f.read(n);
	return (s != null && length(s) == n) ? s : null;
}

// The entry name of a zip from its central directory: { method, crc (4 bytes as in the zip),
// csize, usize, data (offset of the compressed data) } or { error }. No zip64: xray is far
// below 4 GB.
export function zip_entry(path, name) {
	let f = open(path, 'r'), st = stat(path);
	if (!f || !st)
		return { error: 'cannot read the zip' };
	let size = st.size, tail = min(size, 22 + 65535);
	let t = read_at(f, size - tail, tail), e = -1;
	for (let i = tail - 22; t && i >= 0; i--)
		if (substr(t, i, 4) == 'PK\x05\x06') {
			e = i;
			break;
		}
	if (e < 0) {
		f.close();
		return { error: 'not a zip' };
	}
	let count = le(t, e + 10, 2), cd_size = le(t, e + 12, 4), cd_off = le(t, e + 16, 4);
	let cd = (cd_off + cd_size <= size) ? read_at(f, cd_off, cd_size) : null;
	let found = null;
	for (let i = 0, p = 0; cd && i < count && p + 46 <= cd_size; i++) {
		if (substr(cd, p, 4) != 'PK\x01\x02')
			break;
		let nlen = le(cd, p + 28, 2), elen = le(cd, p + 30, 2), clen = le(cd, p + 32, 2);
		if (substr(cd, p + 46, nlen) == name) {
			found = { method: le(cd, p + 10, 2), crc: substr(cd, p + 16, 4), csize: le(cd, p + 20, 4),
				usize: le(cd, p + 24, 4), local: le(cd, p + 42, 4) };
			break;
		}
		p += 46 + nlen + elen + clen;
	}
	let lh = found ? read_at(f, found.local, 30) : null;
	f.close();
	if (!found)
		return { error: `no ${name} in the zip` };
	if (!lh || substr(lh, 0, 4) != 'PK\x03\x04')
		return { error: 'a broken zip' };
	if (!(found.method in [ 0, 8 ]))
		return { error: `zip method ${found.method}` };
	found.data = found.local + 30 + le(lh, 26, 2) + le(lh, 28, 2);
	if (found.data + found.csize > size)
		return { error: 'a broken zip' };
	delete found.local;
	return found;
};

function le_bytes(v) {
	return chr(v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255);
}

// Unpacks the entry of zip_entry() into dest: a deflated one goes to gunzip of busybox
// (OpenWrt has no unzip) as a gzip stream around the same data, gunzip checks the crc.
// null or the error.
export function extract(path, ent, dest) {
	let f = open(path, 'r');
	if (!f || !f.seek(ent.data, 0))
		return 'cannot read the zip';
	let out = (ent.method == 8) ? popen(`gunzip -c > ${shq(dest)}`, 'w') : open(dest, 'w');
	if (!out) {
		f.close();
		return `cannot write ${dest}`;
	}
	let ok = true;
	if (ent.method == 8)
		ok = out.write(chr(0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3)) == 10;
	for (let left = ent.csize; ok && left > 0;) {
		let s = f.read(min(left, 65536));
		if (!length(s))
			ok = false;
		else {
			ok = out.write(s) == length(s);
			left -= length(s);
		}
	}
	if (ok && ent.method == 8)
		ok = out.write(ent.crc + le_bytes(ent.usize)) == 8;
	f.close();
	let code = out.close();
	if (!ok || (ent.method == 8 && code != 0))
		return 'the zip does not unpack';
	if (stat(dest)?.size != ent.usize)
		return 'the zip does not unpack';
	return null;
};

// the version of an xray binary; a run of 25–33 MB, only on demand
export function bin_version(bin) {
	if (!access(bin, 'x'))
		return null;
	return parse_version(run(`${shq(bin)} version 2>&1`).out);
};

// the version of the feed's package (xray-core.control of opkg), without running it
export function feed_version() {
	let m = match(readfile('/usr/lib/opkg/info/xray-core.control') ?? '', /(^|\n)Version: *([^\n]+)/);
	return m ? replace(trim(m[2]), /-r[0-9]+$/, '') : null;
};

function curl(args, proxy_port) {
	let proto = (substr(RELEASES, 0, 7) == 'file://') ? '' : '--proto =https --proto-redir =https ';
	return run(sprintf('curl -sS %s--connect-timeout 10 %s %s 2>&1', proto,
		proxy_port ? `-x socks5h://127.0.0.1:${proxy_port}` : '', args));
}

// the tag of the latest release: the redirect of releases/latest, no GitHub API (60 calls an
// hour without a token). Through the active server, then directly. { tag, via } or { error }
export function latest(proxy_port) {
	let err = null;
	for (let port in (proxy_port ? [ proxy_port, null ] : [ null ])) {
		let r = curl(`-m 10 -o /dev/null -w '%{redirect_url}' ${shq(RELEASES + '/latest')}`, port);
		let tag = (r.code == 0) ? tag_of(trim(r.out)) : null;
		if (tag)
			return { tag, via: port ? 'tunnel' : 'direct' };
		err = (r.code != 0) ? (trim(r.out) || `curl exit code ${r.code}`) : 'no release tag in the redirect';
	}
	return { error: err };
};

function download(url, dest, proxy_port) {
	unlink(dest);
	let r = curl(sprintf('-f -L --max-time 600 --max-filesize %d -o %s %s', MAX_ZIP, shq(dest), shq(url)), proxy_port);
	return (r.code == 0) ? null : (trim(r.out) || `curl exit code ${r.code}`);
}

// free bytes for dir (df -P of busybox: 1K blocks)
export function free_bytes(dir) {
	let l = split(trim(run(`df -Pk ${shq(dir)} 2>/dev/null`).out), '\n');
	let f = split(trim(l[length(l) - 1] ?? ''), /[[:space:]]+/);
	return (length(l) > 1 && match(f[3] ?? '', /^[0-9]+$/)) ? int(f[3]) * 1024 : null;
};

// --- the job: one install at a time, run by `cli.uc xray-install` in the background ---

function job_pid() {
	let pid = readlink(JOB_LOCK);
	return (pid && index(readfile(`/proc/${pid}/cmdline`) ?? '', 'cli.uc') >= 0) ? int(pid) : null;
}

export function job_running() {
	return job_pid() != null;
};

// the job's state; a running one whose process is gone is lost. rpcd writes the first
// running state itself: the job gets STARTUP s to take the lock
const STARTUP = 10;
export function job() {
	let j = read_json(JOB_FILE);
	if (j?.state == 'running' && !job_running() && time() - (j.started ?? 0) > STARTUP)
		j.state = 'lost';
	return j;
};

export function set_job(j) {
	mkdir_p(RUN_DIR);
	write_json(JOB_FILE, j);
};

// symlink() is atomic; a lock of a dead job goes
export function job_lock(pid) {
	mkdir_p(RUN_DIR);
	if (symlink(`${pid}`, JOB_LOCK))
		return true;
	if (job_running())
		return false;
	unlink(JOB_LOCK);
	return !!symlink(`${pid}`, JOB_LOCK);
};

export function job_unlock() {
	unlink(JOB_LOCK);
};

// Downloads and unpacks the release tag into XRAY_GH_BIN. step(name) reports progress.
// { version, via, sha256 } or { error }
export function fetch(tag, proxy_port, step) {
	let name = asset(arch());
	if (!name)
		return { error: `no xray release for the arch ${arch() ?? 'unknown'}` };
	let zip = `/tmp/xvpn-${name}`, base = `${RELEASES}/download/${tag}/${name}`;
	let err = null, via = null, sum = null;
	step('download');
	for (let port in (proxy_port ? [ proxy_port, null ] : [ null ])) {
		via = port ? 'tunnel' : 'direct';
		err = download(`${base}.dgst`, `${zip}.dgst`, port);
		sum = err ? null : parse_dgst(readfile(`${zip}.dgst`));
		if (!err && !sum)
			err = `no SHA2-256 in ${name}.dgst`;
		if (!err)
			err = download(base, zip, port);
		if (!err)
			break;
	}
	unlink(`${zip}.dgst`);
	if (err) {
		unlink(zip);
		return { error: `download of ${tag}/${name}: ${err}` };
	}

	step('check');
	let got = split(run(`sha256sum ${shq(zip)}`).out, ' ')[0];
	let ent = (got == sum) ? zip_entry(zip, 'xray') : { error: `sha256 of ${name} does not match its .dgst` };
	let free = ent.error ? null : free_bytes(stat(GH_DIR) ? GH_DIR : '/usr/lib');
	if (!ent.error && free != null && free < ent.usize + SPARE)
		ent = { error: sprintf('not enough space: %.1f MB free in %s, %.1f MB needed', free / 1048576.0, GH_DIR, (ent.usize + SPARE) / 1048576.0) };
	if (ent.error) {
		unlink(zip);
		return { error: ent.error };
	}

	step('unpack');
	mkdir_p(GH_DIR);
	let tmp = `${XRAY_GH_BIN}.new`;
	err = extract(zip, ent, tmp);
	unlink(zip);
	if (err) {
		unlink(tmp);
		return { error: err };
	}
	run(`chmod 755 ${shq(tmp)}`);

	// it runs on this router and is the release it claims to be
	step('test');
	let v = bin_version(tmp);
	if (!v) {
		unlink(tmp);
		return { error: `xray ${tag} does not run on this router (${arch()})` };
	}
	if (compare(v, tag) != 0) {
		unlink(tmp);
		return { error: `xray of ${tag} says it is ${v}` };
	}
	if (!rename(tmp, XRAY_GH_BIN)) {
		unlink(tmp);
		return { error: `cannot write ${XRAY_GH_BIN}` };
	}
	write_json(GH_META, { tag, version: v, installed: time(), sha256: sum });
	return { version: v, via, sha256: sum };
};

// xray_bin in /etc/config/xvpn
export function set_bin(bin) {
	let c = cursor();
	c.load('xvpn');
	c.set('xvpn', 'main', 'xray_bin', bin);
	return c.commit('xvpn');
};

// for the UI: which xray runs and what is there
export function info(cfg) {
	let bin = cfg.main.xray_bin, meta = read_json(GH_META);
	let gh = access(XRAY_GH_BIN, 'x') ? meta : null;
	let a = arch();
	return {
		bin,
		source: (bin == XRAY_FEED_BIN) ? 'feed' : (bin == XRAY_GH_BIN) ? 'github' : 'other',
		feed: access(XRAY_FEED_BIN, 'x') ? { version: feed_version() } : null,
		github: gh ? { tag: gh.tag, version: gh.version, installed: gh.installed } : null,
		arch: a, asset: asset(a),
		job: job(),
	};
};
