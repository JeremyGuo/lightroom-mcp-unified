import type { ImageContent } from "@modelcontextprotocol/server";

/** Receive only image bytes over the authenticated bridge; never read a plugin-supplied path. */
export function previewImage(result: unknown): ImageContent {
  if (!result || typeof result !== "object") throw new Error("Missing preview result");
  const record = result as Record<string, unknown>;
  const data = record.image_base64;
  if (record.mime_type !== "image/jpeg" || typeof data !== "string") throw new Error("Invalid JPEG preview response");
  if (data.length > 11_184_812 || data.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(data)) {
    throw new Error("Invalid or oversized base64 preview");
  }
  const bytes = Buffer.from(data, "base64");
  if (bytes.length > 8 * 1024 * 1024 || bytes.length < 5 || bytes[0] !== 255 || bytes[1] !== 216 || bytes[2] !== 255 || bytes[bytes.length - 2] !== 255 || bytes[bytes.length - 1] !== 217) {
    throw new Error("Preview is not a complete JPEG under 8 MiB");
  }
  return { type: "image", mimeType: "image/jpeg", data };
}
