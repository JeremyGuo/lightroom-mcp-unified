import { describe, it, expect } from '@jest/globals';
import net from 'node:net';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';

describe('built CLI over actual stdio and TCP sockets', () => {
  it('authenticates, lists tools, returns an image over the v2 protocol', async () => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'lr-unified-integration-'));
    const tokenPath = path.join(directory, 'token');
    const token = 'integration-only-not-a-real-credential';
    await fs.writeFile(tokenPath, token, { mode: 0o600 });
    let responseSocket: net.Socket | undefined;
    const connections: net.Socket[] = [];
    const socketErrors: Error[] = [];
    let closing = false;
    const track = (socket: net.Socket) => {
      connections.push(socket);
      socket.on('error', (error: NodeJS.ErrnoException) => {
        // Terminating the child closes its TCP connections with RST on Windows.
        // Only accept that specific error during intentional fixture teardown.
        if (!closing || error.code !== 'ECONNRESET') socketErrors.push(error);
      });
    };
    const seen: string[] = [];
    const output = net.createServer(socket => { responseSocket = socket; track(socket); });
    const input = net.createServer(socket => {
      track(socket);
      let buffer = '';
      socket.setEncoding('utf8');
      socket.on('data', (part: string) => {
        buffer += part;
        let end: number;
        while ((end = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
          const request = JSON.parse(line) as { hello: string; id: string; action: string; expires_at: number };
          if (request.hello !== token) throw new Error('Missing bridge authentication');
          if (!Number.isFinite(request.expires_at)) throw new Error('Missing execution deadline');
          seen.push(request.action);
          const result = request.action === 'lr_export_preview'
            ? { success: true, mime_type: 'image/jpeg', image_base64: Buffer.from([255,216,255,224,0,2,255,217]).toString('base64') }
            : { pong: true };
          responseSocket?.write(JSON.stringify({ id: request.id, result }) + '\n');
        }
      });
    });
    const listen = (server: net.Server) => new Promise<number>(resolve => {
      server.listen(0, '127.0.0.1', () => resolve((server.address() as net.AddressInfo).port));
    });
    const requestPort = await listen(input);
    const responsePort = await listen(output);
    const env = Object.fromEntries(Object.entries(process.env).filter((item): item is [string, string] => item[1] !== undefined));
    const transport = new StdioClientTransport({ command: process.execPath,
      args: [path.resolve('dist/index.js')], stderr: 'pipe',
      env: { ...env, LIGHTROOM_MCP_TOKEN_PATH: tokenPath,
        LIGHTROOM_MCP_REQUEST_PORT: String(requestPort), LIGHTROOM_MCP_RESPONSE_PORT: String(responsePort),
        LIGHTROOM_MCP_STATE_DIR: directory, LIGHTROOM_MCP_SKIP_PLUGIN_INSTALL: '1' },
    });
    const client = new Client({ name: 'integration-test', version: '0.1.0' });
    try {
      await client.connect(transport);
      expect((await client.listTools()).tools).toHaveLength(31);
      const result = await client.callTool({ name: 'lr_export_preview', arguments: { size: 128 } });
      expect(result.isError).toBeFalsy();
      expect(result.content).toEqual(expect.arrayContaining([expect.objectContaining({ type: 'image', mimeType: 'image/jpeg' })]));
      expect(seen).toContain('ping');
      expect(seen).toContain('lr_export_preview');
    } finally {
      closing = true;
      await client.close();
      for (const socket of connections) socket.destroy();
      await Promise.all([input, output].map(server => new Promise<void>(resolve => server.close(() => resolve()))));
      await fs.rm(directory, { recursive: true, force: true });
    }
    expect(socketErrors).toEqual([]);
  }, 15000);
});
