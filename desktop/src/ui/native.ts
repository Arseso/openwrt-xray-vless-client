// The clipboard and saving a file through the Tauri plugins (src-tauri/src/screens.rs,
// capabilities/screens.json); in a plain browser (npm run dev) the web APIs instead.

const inTauri = () => typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

export async function readClipboard(): Promise<string> {
  if (inTauri()) {
    const { readText } = await import('@tauri-apps/plugin-clipboard-manager');
    return (await readText()) ?? '';
  }
  return navigator.clipboard.readText();
}

export async function writeClipboard(text: string): Promise<void> {
  if (inTauri()) {
    const { writeText } = await import('@tauri-apps/plugin-clipboard-manager');
    return writeText(text);
  }
  return navigator.clipboard.writeText(text);
}

/** asks where to save; false: the user cancelled */
export async function saveTextFile(name: string, text: string): Promise<boolean> {
  if (inTauri()) {
    const { save } = await import('@tauri-apps/plugin-dialog');
    const { writeTextFile } = await import('@tauri-apps/plugin-fs');
    const path = await save({ defaultPath: name, filters: [{ name: 'Text', extensions: ['txt'] }] });
    if (!path)
      return false;
    await writeTextFile(path, text);
    return true;
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
  a.download = name;
  a.click();
  URL.revokeObjectURL(a.href);
  return true;
}

export async function appVersion(): Promise<string> {
  if (!inTauri())
    return 'dev';
  const { getVersion } = await import('@tauri-apps/api/app');
  return getVersion();
}
