import { describe, it, expect, beforeEach, afterEach } from '@jest/globals';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { readToken, tokenFilePath } from '../src/token.js';

describe('token', () => {
  let tmpDir: string;
  let tmpFile: string;
  const originalEnv = process.env.LIGHTROOM_MCP_TOKEN_PATH;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lr-mcp-token-'));
    tmpFile = path.join(tmpDir, 'token');
    process.env.LIGHTROOM_MCP_TOKEN_PATH = tmpFile;
  });

  afterEach(() => {
    if (originalEnv === undefined) delete process.env.LIGHTROOM_MCP_TOKEN_PATH;
    else process.env.LIGHTROOM_MCP_TOKEN_PATH = originalEnv;
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it('reads and trims the token file', () => {
    fs.writeFileSync(tmpFile, '  abcdef123\n');
    expect(readToken()).toBe('abcdef123');
  });

  it('throws with the path when the file is missing', () => {
    expect(() => readToken()).toThrow(tmpFile);
  });

  it('throws when the file is empty', () => {
    fs.writeFileSync(tmpFile, '   \n');
    expect(() => readToken()).toThrow(/empty/);
  });

  it('respects LIGHTROOM_MCP_TOKEN_PATH override', () => {
    expect(tokenFilePath()).toBe(tmpFile);
  });

  it('falls back to the isolated unified token without override', () => {
    delete process.env.LIGHTROOM_MCP_TOKEN_PATH;
    expect(tokenFilePath()).toBe(
      path.join(os.homedir(), '.config', 'lightroom-mcp-unified', 'token'),
    );
  });

  it('restricts token permissions on POSIX', () => {
    if (process.platform === 'win32') return;
    fs.writeFileSync(tmpFile, 'test-token', { mode: 0o644 });
    readToken();
    expect(fs.statSync(tmpFile).mode & 0o777).toBe(0o600);
  });

  it('refuses token symlinks on POSIX', () => {
    if (process.platform === 'win32') return;
    fs.writeFileSync(tmpFile + '-real', 'test-token');
    fs.symlinkSync(tmpFile + '-real', tmpFile);
    expect(() => readToken()).toThrow(/securely read/);
  });
});
