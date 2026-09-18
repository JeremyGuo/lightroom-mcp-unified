import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export function tokenFilePath(): string {
  return (
    process.env.LIGHTROOM_MCP_TOKEN_PATH ??
    path.join(os.homedir(), ".config", "lightroom-mcp-unified", "token")
  );
}

export function readToken(): string {
  const p = tokenFilePath();
  let raw: string;
  let descriptor: number | undefined;
  try {
    descriptor = fs.openSync(p, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW ?? 0));
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) throw new Error("Token must be a regular file");
    if (process.platform !== "win32") {
      if (stat.uid !== process.getuid?.()) throw new Error("Token must be owned by the current user");
      fs.fchmodSync(descriptor, 0o600);
    }
    raw = fs.readFileSync(descriptor, "utf8");
  } catch (error) {
    throw new Error(
      `Cannot securely read Lightroom MCP token at ${p}: ${(error as Error).message}. ` +
        `Open Lightroom and click 'Start Server' in Plug-in Manager to generate one.`,
    );
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
  const token = raw.trim();
  if (!token) throw new Error(`Token file ${p} is empty`);
  return token;
}
