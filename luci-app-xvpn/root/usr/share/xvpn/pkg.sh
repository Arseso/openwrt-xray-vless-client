#!/bin/sh
# Installs the ipk files of luci-app-xvpn the desktop app downloaded from the GitHub
# release and uploaded with ubus file write. Called through rpcd file exec; the ACL
# group luci-app-xvpn-pkg allows it to root only (not to the rpcd user of rpcd-user.sh).
#
#   pkg.sh install [--force-reinstall] /tmp/xvpn-pkg-<name>.ipk ...   start opkg install
#   pkg.sh status    {"state":"idle"|"running"|"done"|"lost","code":N,"output":"..."}
#   pkg.sh list      the installed packages (the opkg status file)
#
# opkg runs in the background: the postinst of a LuCI package re-executes rpcd (SIGHUP),
# and rpcd kills an exec running longer than its timeout (30 s); either would cut the
# install short. The app asks status until it is done. The ipk files are removed then.

. /usr/share/libubox/jshn.sh

STATE=/tmp/xvpn-pkg.json
OUT=/tmp/xvpn-pkg.out
PID=/tmp/xvpn-pkg.pid

state() { # state [code]
	json_init
	json_add_string state "$1"
	[ -z "$2" ] || json_add_int code "$2"
	[ ! -s $OUT ] || json_add_string output "$(tail -c 4000 $OUT)"
	json_dump >$STATE.new && mv $STATE.new $STATE
}

running() {
	grep -q '"running"' $STATE 2>/dev/null || return 1
	[ -f $PID ] || return 0
	kill -0 "$(cat $PID)" 2>/dev/null
}

fail() {
	echo "$*" >&2
	exit 1
}

case "$1" in
list)
	exec cat /usr/lib/opkg/status
	;;
status)
	[ -f $STATE ] || { echo '{"state":"idle"}'; exit 0; }
	# a killed job leaves running behind (the pid is written right after the start)
	if running; then :; elif grep -q '"running"' $STATE; then state lost; fi
	cat $STATE
	;;
install)
	shift
	force=
	[ "$1" != --force-reinstall ] || { force=$1; shift; }
	[ $# -gt 0 ] || fail "no files"
	[ -x /bin/opkg ] || fail "no opkg"
	for f in "$@"; do
		case "$f" in
		/tmp/xvpn-pkg-*/*) fail "bad file: $f" ;;
		/tmp/xvpn-pkg-*.ipk) [ -f "$f" ] || fail "no file: $f" ;;
		*) fail "bad file: $f" ;;
		esac
	done
	! running || fail "an install is running"
	rm -f $OUT $PID
	# before the job starts: its done must not be overwritten
	state running
	(
		trap '' HUP
		opkg install $force "$@" >$OUT 2>&1
		code=$?
		rm -f "$@"
		state done $code
	) </dev/null >/dev/null 2>&1 &
	echo $! >$PID
	echo '{"state":"running"}'
	;;
*)
	fail "usage: $0 install [--force-reinstall] file... | status | list"
	;;
esac
