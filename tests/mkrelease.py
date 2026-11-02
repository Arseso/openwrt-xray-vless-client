#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# A fake Xray-core release for the test of cli.uc xray-install (#31), laid out like
# github.com/XTLS/Xray-core/releases: <dir>/download/<tag>/Xray-linux-64.zip and its .dgst.
# Its xray is a script: "version" prints the tag, anything else goes to /usr/bin/xray.
#   v9.9.9  deflated, larger than one read of extract() (64 KB)
#   v9.9.8  stored (zip method 0)
#   v9.9.7  a .dgst that does not match
#   v9.9.6  says it is 1.2.3
#   v9.9.5  no xray in the zip
import base64, hashlib, os, sys, zipfile

out = sys.argv[1]


def script(version):
    pad = base64.b64encode(os.urandom(150000)).decode()
    return ('#!/bin/sh\n'
            'case "$1" in\n'
            f'version) echo "Xray {version} (Xray, Penetrates Everything.) test"; exit 0 ;;\n'
            'esac\n'
            'exec /usr/bin/xray "$@"\n'
            f'# {pad}\n')


def release(tag, files, method=zipfile.ZIP_DEFLATED, bad_sum=False):
    d = os.path.join(out, 'download', tag)
    os.makedirs(d, exist_ok=True)
    z = os.path.join(d, 'Xray-linux-64.zip')
    with zipfile.ZipFile(z, 'w', method) as f:
        for name, text in files.items():
            f.writestr(name, text)
    s = hashlib.sha256(open(z, 'rb').read()).hexdigest()
    if bad_sum:
        s = '0' * 64
    with open(z + '.dgst', 'w') as f:
        f.write(f'MD5= {hashlib.md5(b"").hexdigest()}\nSHA2-256= {s}\nSHA2-512= {"0" * 128}\n')


common = {'LICENSE': 'MPL-2.0\n', 'geoip.dat': 'x' * 1000}
release('v9.9.9', {**common, 'xray': script('9.9.9')})
release('v9.9.8', {'xray': script('9.9.8'), **common}, zipfile.ZIP_STORED)
release('v9.9.7', {'xray': script('9.9.7')}, bad_sum=True)
release('v9.9.6', {'xray': script('1.2.3')})
release('v9.9.5', common)
