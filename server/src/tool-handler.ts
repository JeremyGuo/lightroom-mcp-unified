import type { Dispatcher } from "./dispatcher.js";
import { validateToolArgs } from "./validate-args.js";
import { TOOL_CONTRACTS } from "./tool-contracts.js";
import { previewImage } from "./preview.js";
import type { ImageContent } from "@modelcontextprotocol/server";

export interface ToolHandlerDeps {
  dispatcher: Pick<Dispatcher, "call">;
  isReady: () => boolean;
  notReadyMessage?: () => string;
  settleReadiness?: () => Promise<void>;
}

export interface ToolResponse {
  content: Array<{ type: "text"; text: string } | ImageContent>;
  isError?: boolean;
  [key: string]: unknown;
}

export const NOT_CONNECTED_MESSAGE =
  "Lightroom plugin not connected. Open Lightroom and click 'Start Server' in Plug-in Manager.";

export function createCallToolHandler(deps: ToolHandlerDeps) {
  return async (name: string, args: unknown): Promise<ToolResponse> => {
    if (!TOOL_CONTRACTS.some((tool) => tool.name === name)) {
      return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
    }
    const invalid = validateToolArgs(name, args);
    if (invalid) {
      return {
        content: [{ type: "text", text: invalid }],
        isError: true,
      };
    }

    await deps.settleReadiness?.();

    if (!deps.isReady()) {
      return {
        content: [{ type: "text", text: deps.notReadyMessage?.() ?? NOT_CONNECTED_MESSAGE }],
        isError: true,
      };
    }

    try {
      const resp = await deps.dispatcher.call(name, args);
      if (resp.error) {
        return {
          content: [{ type: "text", text: `Error: ${resp.error}` }],
          isError: true,
        };
      }
      if (resp.result && typeof resp.result === "object" && "success" in resp.result && resp.result.success === false) {
        return { content: [{ type: "text", text: JSON.stringify(resp.result, null, 2) }], isError: true };
      }
      if (name === "lr_export_preview") {
        const img = previewImage(resp.result);
        const meta = { ...(resp.result as Record<string, unknown>) };
        delete meta.image_base64;
        return { content: [{ type: "text", text: JSON.stringify(meta) }, img] };
      }
      return {
        content: [{ type: "text", text: JSON.stringify(resp.result, null, 2) }],
      };
    } catch (e) {
      return {
        content: [{ type: "text", text: e instanceof Error ? e.message : String(e) }],
        isError: true,
      };
    }
  };
}
