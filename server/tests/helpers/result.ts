import type { ToolResponse } from "../../src/tool-handler.js";
export function firstText(result: ToolResponse): string {
  const block = result.content[0];
  if (block?.type !== "text") throw new Error("Expected text content");
  return block.text;
}
