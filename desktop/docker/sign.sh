#!/bin/bash
# Signs the updater packages and checks them; scripts/desktop-build.sh runs it in the build
# image without network, with no volumes and only the key file mounted:
#   /out                 the packages (dist/desktop)
#   /src                 desktop/ read-only: the public key in src-tauri/tauri.conf.json
#   /key/updater.key     (sign) the key of `tauri signer generate`; updater.pass beside it
# MODE=sign signs every AppImage, deb and NSIS setup (tauri signer sign: <file>.sig), writes
# latest.json and checks; MODE=verify checks only: each .sig with minisign against the public
# key the installed apps know, and latest.json carrying the same signatures.
set -euo pipefail
shopt -s nullglob
case "${MODE:-}" in sign|verify) ;; *) echo "MODE must be sign or verify"; exit 2 ;; esac
cd /out
files=(*.AppImage *.deb *-setup.exe)
[ ${#files[@]} -gt 0 ] || { echo "no packages in dist/desktop"; exit 1; }
if [ "$MODE" = sign ]; then
	pass=$(cat /key/updater.pass 2>/dev/null || true)
	for f in "${files[@]}"; do
		rm -f "$f.sig"
		tauri signer sign -f /key/updater.key -p "$pass" "$f" >/dev/null
	done
	node /src/docker/manifest.mjs write
fi
node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync("/src/src-tauri/tauri.conf.json", "utf8")).plugins.updater.pubkey)' \
	| base64 -d > /tmp/pub
for f in "${files[@]}"; do
	[ -s "$f.sig" ] || { echo "no signature $f.sig"; exit 1; }
	base64 -d "$f.sig" > /tmp/sig
	minisign -Vq -p /tmp/pub -m "$f" -x /tmp/sig || { echo "$f.sig: not a signature of the key in tauri.conf.json"; exit 1; }
done
node /src/docker/manifest.mjs check
echo "signatures ok: ${files[*]}"
