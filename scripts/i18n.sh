#!/bin/sh
# Regenerates luci-app-xvpn/po/templates/xvpn.pot from the _() / N_() strings of the
# views, menu.d and acl.d, and merges it into every po/*/xvpn.po, the way the luci feed
# does (build/i18n-scan.pl and build/i18n-update.pl). Runs in docker: neither the host
# nor the SDK image has gettext. New strings come out untranslated in the po files.
set -eu
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker --context default}"
IMAGE="${IMAGE:-alpine:3.22}"
LUCI_RAW="${LUCI_RAW:-https://raw.githubusercontent.com/openwrt/luci/openwrt-24.10}"

TAR="$(mktemp)"
trap 'rm -f "$TAR"' EXIT
trap 'exit 130' INT TERM
# the po directory comes back as a tar on stdout
$DOCKER run --rm --init -v "$PWD:/src:ro" -e LUCI_RAW="$LUCI_RAW" "$IMAGE" sh -euc '
	exec 3>&1 1>&2
	apk add -q --no-progress gettext perl
	mkdir /w && cd /w
	for f in i18n-scan.pl i18n-update.pl; do
		wget -q -O "$f" "$LUCI_RAW/build/$f"
	done
	cp -r /src/luci-app-xvpn .
	mkdir -p luci-app-xvpn/po/templates
	perl i18n-scan.pl luci-app-xvpn > luci-app-xvpn/po/templates/xvpn.pot
	perl i18n-update.pl luci-app-xvpn/po
	echo
	for po in luci-app-xvpn/po/*/xvpn.po; do
		[ -f "$po" ] || continue
		printf "%s: " "$po"
		msgfmt --check -o /dev/null --statistics "$po"
	done
	tar -c -C luci-app-xvpn po >&3
' > "$TAR"
tar -x -f "$TAR" -C luci-app-xvpn
