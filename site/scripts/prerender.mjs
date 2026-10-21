import { readFile, writeFile } from 'node:fs/promises';
import { render } from '../.ssr/entry-server.js';
const file = new URL('../dist/index.html', import.meta.url);
const template = await readFile(file, 'utf8');
if (!template.includes('<!--app-html-->')) throw new Error('Prerender placeholder missing');
await writeFile(file, template.replace('<!--app-html-->', render()));
console.log('PRERENDER: complete readable HTML emitted for no-JavaScript browsing');
