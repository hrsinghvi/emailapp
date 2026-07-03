import type { VercelRequest, VercelResponse } from "@vercel/node";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { registerTools } from "../lib/mcpTools";

export const config = { api: { bodyParser: true } };

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const auth = req.headers.authorization ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!process.env.MCP_AUTH_TOKEN || token !== process.env.MCP_AUTH_TOKEN) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }

  // Stateless mode (sessionIdGenerator: undefined) — appropriate for a
  // serverless deployment where each invocation is its own fresh process.
  const server = new McpServer({ name: "emailapp", version: "1.0.0" });
  registerTools(server);

  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    void transport.close();
    void server.close();
  });

  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
}
