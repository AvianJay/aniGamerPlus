import { build } from 'esbuild';
import { mkdir, writeFile, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const outputDir = new URL('../../Dashboard/static/js/vendor/', import.meta.url);
const result = await build({
  entryPoints: [fileURLToPath(new URL('entry.js', import.meta.url))],
  bundle: true,
  minify: true,
  format: 'iife',
  globalName: 'DiscordEmbeddedAppSDK',
  legalComments: 'eof',
  write: false,
});
await mkdir(outputDir, { recursive: true });
await writeFile(new URL('discord-embedded-app-sdk.js', outputDir), result.outputFiles[0].contents);
await copyFile(new URL('node_modules/@discord/embedded-app-sdk/LICENSE.md', import.meta.url),
  new URL('discord-embedded-app-sdk.LICENSE', outputDir));
console.log('Built Discord Embedded App SDK 2.5.0.');
