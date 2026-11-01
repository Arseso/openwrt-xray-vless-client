// latest.json of tauri-plugin-updater for the packages in the current directory (sign.sh):
// the AppImage for Linux (also what an installation without a bundle type gets), the deb for
// a deb installation (the plugin looks for "<os>-<arch>-<bundle type>" first), the NSIS setup
// for Windows. URLs point at the GitHub release TAG of REPO.
//
//   node manifest.mjs write   VERSION, TAG, REPO from the environment
//   node manifest.mjs check   every entry has the signature of its file's .sig

import fs from 'node:fs';

const PLATFORMS = [
  ['linux-x86_64', /\.AppImage$/],
  ['linux-x86_64-deb', /\.deb$/],
  ['windows-x86_64', /-setup\.exe$/],
];
const files = fs.readdirSync('.');

if (process.argv[2] === 'write') {
  const { VERSION, TAG, REPO } = process.env;
  const base = `https://github.com/${REPO}/releases/download/${TAG}/`;
  const platforms = {};
  for (const [key, re] of PLATFORMS) {
    const f = files.find((n) => re.test(n));
    if (f)
      platforms[key] = { signature: fs.readFileSync(`${f}.sig`, 'utf8'), url: base + encodeURIComponent(f) };
  }
  fs.writeFileSync('latest.json', JSON.stringify({
    version: VERSION,
    notes: `https://github.com/${REPO}/releases/tag/${TAG}`,
    pub_date: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
    platforms,
  }, null, 2) + '\n');
}
else if (process.argv[2] === 'check') {
  const m = JSON.parse(fs.readFileSync('latest.json', 'utf8'));
  for (const [key, re] of PLATFORMS) {
    const f = files.find((n) => re.test(n));
    if (!f)
      continue;
    const p = m.platforms?.[key];
    if (!p || p.signature !== fs.readFileSync(`${f}.sig`, 'utf8') || !p.url.endsWith('/' + encodeURIComponent(f))) {
      console.error(`latest.json: ${key} does not match ${f} and its signature`);
      process.exit(1);
    }
  }
}
else {
  console.error('usage: node manifest.mjs write|check');
  process.exit(2);
}
