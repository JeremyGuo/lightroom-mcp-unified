import { Server } from "@modelcontextprotocol/server";
import type { Dispatcher } from "./dispatcher.js";
import { createCallToolHandler } from "./tool-handler.js";
import { listToolsHandler } from "./list-tools-handler.js";
import { VERSION } from "./version.js";

export interface ServerDeps {
  dispatcher: Pick<Dispatcher, "call">;
  isReady: () => boolean;
  notReadyMessage?: () => string;
  settleReadiness?: () => Promise<void>;
}

export function createMcpServer(deps: ServerDeps): Server {
  const server = new Server(
    { name: "lightroom-mcp-unified", version: VERSION },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler("tools/list", async () =>
    listToolsHandler(),
  );

  const callTool = createCallToolHandler(deps);
  server.setRequestHandler("tools/call", async (request) => {
    const { name, arguments: args } = request.params;
    return callTool(name, args ?? {});
  });

  return server;
}
