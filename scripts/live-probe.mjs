// Opt-in real Lightroom MCP probe. It only executes explicitly supplied calls.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '../server/node_modules/@modelcontextprotocol/client/dist/index.mjs';
import { StdioClientTransport } from '../server/node_modules/@modelcontextprotocol/client/dist/stdio.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = process.env.LR_TEST_OUTPUT || path.join(root, 'artifacts/live-2026-09-20');
await fs.mkdir(out, { recursive: true });
const client = new Client({ name: 'lightroom-real-machine-test', version: '0.1.0' });
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [path.join(root, 'server/dist/index.js')],
  env: { ...process.env, LIGHTROOM_MCP_SKIP_PLUGIN_INSTALL: '1' },
  stderr: 'pipe',
});
const records = [];
const label = new Date().toISOString().replace(/[:.]/g, '-');
try {
  await client.connect(transport);
  const listing = await client.listTools();
  await fs.writeFile(path.join(out, 'tools.json'), JSON.stringify(listing, null, 2));
  console.log(JSON.stringify({ toolCount: listing.tools.length }));
  const input = process.argv[2] || '[]';
  const calls = JSON.parse(input.startsWith('@') ? await fs.readFile(input.slice(1), 'utf8') : input);
  for (const call of calls) {
    if (call.wait_ms !== undefined) {
      if (!Number.isInteger(call.wait_ms) || call.wait_ms<0 || call.wait_ms>300000) throw new Error('wait_ms must be 0..300000');
      await new Promise(resolve=>setTimeout(resolve,call.wait_ms));
      console.log(JSON.stringify({waited_ms:call.wait_ms}));
      continue;
    }
    const start = Date.now();
    try {
      const result = await client.callTool({ name: call.name, arguments: call.args || {} }, { timeout: 330000 });
      const content = [];
      for (const [i, item] of (result.content || []).entries()) {
        if (item.type === 'image') {
          const imagePath = path.join(out, `${label}-${records.length}-${i}-${call.name}.jpg`);
          const bytes = Buffer.from(item.data, 'base64');
          await fs.writeFile(imagePath, bytes);
          content.push({ type: item.type, mimeType: item.mimeType, bytes: bytes.length, path: imagePath });
        } else if (item.type === 'text') {
          try { content.push({ type: 'text', value: JSON.parse(item.text) }); }
          catch { content.push(item); }
        } else content.push(item);
      }
      const record = { name: call.name, args: call.args || {}, ms: Date.now() - start, isError: result.isError || false, content };
      records.push(record);
      console.log(JSON.stringify(record));
    } catch (error) {
      const record = { name: call.name, args: call.args || {}, ms: Date.now() - start, error: error.message };
      records.push(record);
      console.log(JSON.stringify(record));
    }
    await fs.writeFile(path.join(out, `${label}-results.json`), JSON.stringify(records, null, 2));
  }
} finally {
  await client.close();
}
