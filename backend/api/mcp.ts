import type { VercelRequest, VercelResponse } from "@vercel/node";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { registerTools } from "../lib/mcpTools";
import { supabase } from "../lib/supabase";

export const config = { api: { bodyParser: true } };

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const auth = req.headers.authorization ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";

  // The active token lives in Supabase, not a static env var — Settings >
  // MCP > "Regenerate" just updates this row, so rotation takes effect on
  // the very next request with no redeploy. Falls back to the env var only
  // if the settings row is somehow missing.
  const { data: settingsRow } = await supabase.from("app_settings").select("mcp_bearer_token").eq("id", true).single();
  const expectedToken = settingsRow?.mcp_bearer_token ?? process.env.MCP_AUTH_TOKEN;
  if (!expectedToken || token !== expectedToken) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }

  // Stateless mode (sessionIdGenerator: undefined) — appropriate for a
  // serverless deployment where each invocation is its own fresh process.
  const server = new McpServer({ name: "emailapp", version: "1.0.0" });
  await registerTools(server);

  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    void transport.close();
    void server.close();
  });

  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
}
