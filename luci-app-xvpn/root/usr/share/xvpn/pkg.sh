#!/bin/sh
# Installs the ipk files of luci-app-xvpn the desktop app downloaded from the GitHub
# release and uploaded with ubus file write. Called through rpcd file exec; the ACL
# group luci-app-xvpn-pkg allows it to root only (not to the rpcd user of rpcd-user.sh).
#
#   pkg.sh install <id> [--force-reinstall] <file> <sha256> [<file> <sha256>...]
#          start opkg install of the files /tmp/xvpn-pkg-<id>-*.ipk, each checked first
#   pkg.sh status    {"id":"<id>","state":"running"|"done"|"lost","code":N,"output":"..."}
#                    or {"state":"idle"}
#   pkg.sh list      the opkg status of luci-app-xvpn and of the LuCI translations
#
# opkg runs in the background: the postinst of a LuCI package re-executes rpcd (SIGHUP),
# and rpcd kills an exec running longer than its timeout (30 s); either would cut the
# install short. The app asks status until its job (its id) is done. One job at a time
# (the lock directory, taken before anything is checked); its files are removed at the end.

. /usr/share/libubox/jshn.sh

STATE=/tmp/xvpn-pkg.json
OUT=/tmp/xvpn-pkg.out
LOCK=/tmp/xvpn-pkg.lock

state() { # id state [code]
	json_init
	json_add_string id "$1"
	json_add_string state "$2"
	[ -z "$3" ] || json_add_int code "$3"
	[ ! -s $OUT ] || json_add_string output "$(tail -c 4000 $OUT)"
	json_dump >$STATE.new && mv $STATE.new $STATE
}

fail() {
	echo "$*" >&2
	exit 1
}

# the job holding the lock is alive; a lock without a pid is being taken right now
locked() {
	[ -d $LOCK ] || return 1
	pid=$(cat $LOCK/pid 2>/dev/null)
	[ -z "$pid" ] || kill -0 "$pid" 2>/dev/null
}

lock() {
	mkdir $LOCK 2>/dev/null && return 0
	! locked || fail "an install is running"
	# the job died (killed with its shell): its lock goes
	rm -rf $LOCK
	mkdir $LOCK 2>/dev/null || fail "an install is running"
}

unlock_fail() {
	rm -rf $LOCK
	fail "$@"
}

case "$1" in
list)
	# only these: the whole status file may not fit into the output rpcd passes on
	exec awk 'BEGIN { RS = ""; ORS = "\n\n" } /^Package: (luci-app-xvpn|luci-i18n-(xvpn|base)-[a-z0-9-]+)\n/' /usr/lib/opkg/status
	;;
status)
	[ -f $STATE ] || { echo '{"state":"idle"}'; exit 0; }
	if grep -q '"state": "running"' $STATE && ! locked; then
		json_load "$(cat $STATE)"
		json_get_var id id
		state "$id" lost
	fi
	cat $STATE
	;;
install)
	id=$2
	shift 2
	case "$id" in *[!0-9a-f]* | '') fail "bad id: $id" ;; esac
	force=
	[ "$1" != --force-reinstall ] || { force=$1; shift; }
	[ $# -gt 0 ] && [ $(($# % 2)) = 0 ] || fail "usage: install <id> [--force-reinstall] <file> <sha256>..."
	[ -x /bin/opkg ] || fail "no opkg"
	lock
	echo $$ >$LOCK/pid
	files=
	while [ $# -gt 0 ]; do
		f=$1 sum=$2
		shift 2
		case "$f" in
		/tmp/xvpn-pkg-"$id"-*/*) unlock_fail "bad file: $f" ;;
		/tmp/xvpn-pkg-"$id"-*.ipk) ;;
		*) unlock_fail "bad file: $f" ;;
		esac
		[ -f "$f" ] || unlock_fail "no file: $f"
		[ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sum" ] || unlock_fail "sha256 mismatch: $f"
		files="$files $f"
	done
	rm -f $OUT
	# before the job starts: its done must not be overwritten
	state "$id" running
	(
		trap '' HUP
		# shellcheck disable=SC2086 # the names are checked above, no spaces
		opkg install $force $files >$OUT 2>&1
		code=$?
		# shellcheck disable=SC2086
		rm -f $files
		state "$id" done $code
		rm -rf $LOCK
	) </dev/null >/dev/null 2>&1 &
	echo $! >$LOCK/pid 2>/dev/null
	echo "{\"id\":\"$id\",\"state\":\"running\"}"
	;;
*)
	fail "usage: $0 install <id> [--force-reinstall] <file> <sha256>... | status | list"
	;;
esac
