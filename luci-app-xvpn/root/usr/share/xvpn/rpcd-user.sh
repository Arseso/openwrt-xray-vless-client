#!/bin/sh
# SPDX-License-Identifier: MIT
# An rpcd user for remote control (the desktop app, #81) instead of root: it logs in to
# /ubus and gets the ACL of luci-app-xvpn only (luci.xvpn, uci xvpn with apply/rollback),
# no file exec, no other configs.
#
#   sh /usr/share/xvpn/rpcd-user.sh add [name]     create it or set a new password, printed
#   sh /usr/share/xvpn/rpcd-user.sh add [name] -   the same with the password from stdin
#   sh /usr/share/xvpn/rpcd-user.sh del [name]
#
# name is xvpn by default. The login is the section xvpn_<name> in /etc/config/rpcd; rpcd
# reads it at every login. The hash is uhttpd -m (MD5 crypt without salt): with the random
# password (96 bits) that is no weakness, a password of your own should be as long.
set -e
cmd=$1 name=${2:-xvpn}
case "$name" in
root) echo "root is not for this" >&2; exit 1 ;;
[a-z]*) ;;
*) echo "bad name: $name" >&2; exit 1 ;;
esac
case "$name" in *[!a-z0-9_]*) echo "bad name: $name (a-z, 0-9, _)" >&2; exit 1 ;; esac
sec=xvpn_$name

case "$cmd" in
add)
	if [ "$3" = - ]; then
		IFS= read -r pass || true
		[ ${#pass} -ge 8 ] || { echo "the password is shorter than 8" >&2; exit 1; }
	else
		pass=$(hexdump -n 12 -e '12/1 "%02x"' /dev/urandom)
	fi
	hash=$(uhttpd -m "$pass")
	case "$hash" in '$1$'*) ;; *) echo "uhttpd -m failed" >&2; exit 1 ;; esac
	# another login section with this name would be found first
	for s in $(uci -q show rpcd | sed -n "s/^rpcd\.\([^.]*\)\.username='$name'$/\1/p"); do
		[ "$s" = "$sec" ] || { echo "rpcd has another login $name (rpcd.$s)" >&2; exit 1; }
	done
	uci -q batch <<UCI
delete rpcd.$sec
set rpcd.$sec=login
set rpcd.$sec.username=$name
set rpcd.$sec.password='$hash'
add_list rpcd.$sec.read=luci-app-xvpn
add_list rpcd.$sec.read=luci-app-xvpn-remote
add_list rpcd.$sec.write=luci-app-xvpn
add_list rpcd.$sec.write=luci-app-xvpn-remote
commit rpcd
UCI
	[ "$3" = - ] && echo "user $name is ready" || echo "user $name, password $pass"
	;;
del)
	uci -q get rpcd.$sec >/dev/null || { echo "no user $name" >&2; exit 1; }
	uci delete rpcd.$sec
	uci commit rpcd
	echo "user $name deleted (sessions it has open expire after rpcd's timeout)"
	;;
*)
	sed -n '5,8s/^#   //p' "$0" >&2
	exit 1
	;;
esac
