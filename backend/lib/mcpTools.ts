import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { supabase } from "./supabase";
import { decrypt } from "./crypto";
import * as gmail from "./gmail";
import * as graph from "./graph";

// Message ids are a deterministic SHA256-derived hash (see stableId.ts), not
// RFC 4122 UUIDs — no version/variant bits are set, so zod's strict `.uuid()`
// rejects roughly half of real ids by chance. Match the general shape instead.
const messageIdSchema = z
  .string()
  .regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, "not a message id");

interface AccountRow {
  id: string;
  provider: "gmail" | "outlook";
  email: string;
  encrypted_refresh_token: string;
}

interface MessageRow {
  id: string;
  account_id: string;
  provider: "gmail" | "outlook";
  provider_message_id: string;
  thread_id: string | null;
  message_id_header: string | null;
  references_header: string | null;
  sender_email: string;
  subject: string;
}

interface AppSettingsRow {
  mcp_require_confirmation: boolean;
  mcp_enabled_tools: string[];
}

const WRITE_TOOLS = new Set(["send_email", "reply_email", "archive_email", "mark_read"]);

async function loadSettings(): Promise<AppSettingsRow> {
  const { data, error } = await supabase
    .from("app_settings")
    .select("mcp_require_confirmation, mcp_enabled_tools")
    .eq("id", true)
    .single();
  // No settings row (shouldn't happen post-migration) — fail open with
  // every tool enabled and no confirmation gate, matching pre-settings behavior.
  if (error || !data) return { mcp_require_confirmation: false, mcp_enabled_tools: [...WRITE_TOOLS, "get_recent_emails", "get_email_body", "search_emails"] };
  return data as AppSettingsRow;
}

async function logCall(tool: string, args: unknown, result: "success" | "error" | "pending_approval", detail?: string) {
  await supabase.from("mcp_call_log").insert({ tool, args: args ?? {}, result, detail: detail ?? null });
}

async function queueForApproval(tool: string, args: unknown): Promise<string> {
  const { data, error } = await supabase
    .from("mcp_pending_actions")
    .insert({ tool, args })
    .select("id")
    .single();
  if (error || !data) throw new Error(`Failed to queue action for approval: ${error?.message}`);
  return data.id as string;
}

async function accessTokenFor(account: AccountRow): Promise<string> {
  const refreshToken = decrypt(account.encrypted_refresh_token);
  return account.provider === "gmail"
    ? gmail.refreshAccessToken(refreshToken)
    : graph.refreshAccessToken(refreshToken);
}

async function findAccountByEmail(email: string): Promise<AccountRow> {
  const { data, error } = await supabase.from("accounts").select("*").eq("email", email).single();
  if (error || !data) throw new Error(`No connected account for ${email}`);
  return data as AccountRow;
}

async function findAccountById(accountId: string): Promise<AccountRow> {
  const { data, error } = await supabase.from("accounts").select("*").eq("id", accountId).single();
  if (error || !data) throw new Error(`Account ${accountId} not found`);
  return data as AccountRow;
}

async function findMessageRow(messageId: string): Promise<MessageRow> {
  const { data, error } = await supabase.from("messages").select("*").eq("id", messageId).single();
  if (error || !data) throw new Error(`Message ${messageId} not found`);
  return data as MessageRow;
}

function textResult(obj: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(obj, null, 2) }] };
}

function errorResult(err: unknown) {
  return { content: [{ type: "text" as const, text: `Error: ${(err as Error).message}` }], isError: true };
}

function pendingResult(pendingId: string) {
  return textResult({
    status: "pending_approval",
    pending_id: pendingId,
    message: "This write action requires approval in the EmailApp before it runs. Ask the user to approve or reject it in Settings > MCP.",
  });
}

const MESSAGE_LIST_COLUMNS =
  "id, provider, account_email, sender_name, sender_email, subject, snippet, received_at, is_read, folder";

/**
 * Every write-tool handler is wrapped the same way: if confirmation is
 * required, queue it in `mcp_pending_actions` and return immediately
 * without touching Gmail/Graph — the Mac app executes the real action
 * later when the user approves (see InboxViewModel.approvePendingAction).
 * Otherwise run it now. Every path logs to `mcp_call_log`.
 */
function guardedWrite<Args>(
  toolName: string,
  requireConfirmation: boolean,
  execute: (args: Args) => Promise<void>
) {
  return async (args: Args) => {
    try {
      if (requireConfirmation) {
        const pendingId = await queueForApproval(toolName, args);
        await logCall(toolName, args, "pending_approval");
        return pendingResult(pendingId);
      }
      await execute(args);
      await logCall(toolName, args, "success");
      return textResult({ ok: true });
    } catch (err) {
      await logCall(toolName, args, "error", (err as Error).message);
      return errorResult(err);
    }
  };
}

function guardedRead<Args>(toolName: string, execute: (args: Args) => Promise<unknown>) {
  return async (args: Args) => {
    try {
      const data = await execute(args);
      await logCall(toolName, args, "success");
      return textResult(data);
    } catch (err) {
      await logCall(toolName, args, "error", (err as Error).message);
      return errorResult(err);
    }
  };
}

export async function registerTools(server: McpServer): Promise<void> {
  const settings = await loadSettings();
  const enabled = new Set(settings.mcp_enabled_tools);
  const requireConfirmation = settings.mcp_require_confirmation;

  if (enabled.has("get_recent_emails")) {
    server.registerTool(
      "get_recent_emails",
      {
        description: "List recent emails (metadata only) across connected accounts, newest first.",
        inputSchema: {
          account: z.string().email().optional().describe("Filter to one connected account's email address"),
          limit: z.number().int().min(1).max(100).optional().describe("Max results (default 20)"),
        },
      },
      guardedRead("get_recent_emails", async ({ account, limit }: { account?: string; limit?: number }) => {
        let q = supabase
          .from("messages")
          .select(MESSAGE_LIST_COLUMNS)
          .order("received_at", { ascending: false })
          .limit(limit ?? 20);
        if (account) q = q.eq("account_email", account);
        const { data, error } = await q;
        if (error) throw new Error(error.message);
        return data;
      })
    );
  }

  if (enabled.has("get_email_body")) {
    server.registerTool(
      "get_email_body",
      {
        description: "Fetch the full body of an email live from the provider (Gmail/Outlook), not the cached snippet.",
        inputSchema: { message_id: messageIdSchema.describe("Message id from get_recent_emails/search_emails") },
      },
      guardedRead("get_email_body", async ({ message_id }: { message_id: string }) => {
        const row = await findMessageRow(message_id);
        const account = await findAccountById(row.account_id);
        const accessToken = await accessTokenFor(account);
        const msg =
          account.provider === "gmail"
            ? await gmail.getMessage(accessToken, row.provider_message_id)
            : await graph.getMessage(accessToken, row.provider_message_id);
        return { subject: msg.subject, from: msg.senderEmail, receivedAt: msg.receivedAt, body: msg.body };
      })
    );
  }

  if (enabled.has("search_emails")) {
    server.registerTool(
      "search_emails",
      {
        description: "Search cached email metadata by subject, sender, or snippet text.",
        inputSchema: {
          query: z.string().min(1),
          account: z.string().email().optional().describe("Filter to one connected account's email address"),
        },
      },
      guardedRead("search_emails", async ({ query, account }: { query: string; account?: string }) => {
        const escaped = query.replace(/[%_]/g, (c) => `\\${c}`);
        let q = supabase
          .from("messages")
          .select(MESSAGE_LIST_COLUMNS)
          .order("received_at", { ascending: false })
          .or(
            `subject.ilike.%${escaped}%,sender_name.ilike.%${escaped}%,sender_email.ilike.%${escaped}%,snippet.ilike.%${escaped}%`
          )
          .limit(50);
        if (account) q = q.eq("account_email", account);
        const { data, error } = await q;
        if (error) throw new Error(error.message);
        return data;
      })
    );
  }

  const attachmentSchema = z.object({
    filename: z.string(),
    mime_type: z.string().describe('e.g. "application/pdf", "image/png"'),
    content_base64: z.string().describe("Raw base64 file content"),
  });

  if (enabled.has("send_email")) {
    server.registerTool(
      "send_email",
      {
        description: "Send a brand-new email from one of the connected accounts.",
        inputSchema: {
          to: z.array(z.string().email()).min(1),
          subject: z.string(),
          body: z.string(),
          is_html: z.boolean().optional().describe("Set true if body is HTML rather than plain text"),
          account: z.string().email().describe("Which connected account to send from"),
          attachments: z.array(attachmentSchema).optional(),
        },
      },
      guardedWrite(
        "send_email",
        requireConfirmation,
        async ({ to, subject, body, is_html, account, attachments }: {
          to: string[]; subject: string; body: string; is_html?: boolean; account: string;
          attachments?: { filename: string; mime_type: string; content_base64: string }[];
        }) => {
          const acc = await findAccountByEmail(account);
          const accessToken = await accessTokenFor(acc);
          const mailAttachments = attachments?.map((a) => ({
            filename: a.filename,
            mimeType: a.mime_type,
            contentBase64: a.content_base64,
          }));
          if (acc.provider === "gmail") {
            await gmail.send(accessToken, { to: to.join(", "), subject, body, isHtml: is_html, attachments: mailAttachments });
          } else {
            await graph.send(accessToken, { to, subject, body, isHtml: is_html, attachments: mailAttachments });
          }
        }
      )
    );
  }

  if (enabled.has("reply_email")) {
    server.registerTool(
      "reply_email",
      {
        description: "Reply in-thread to an existing email.",
        inputSchema: {
          message_id: messageIdSchema,
          body: z.string(),
          is_html: z.boolean().optional().describe("Set true if body is HTML rather than plain text"),
          attachments: z.array(attachmentSchema).optional(),
        },
      },
      guardedWrite(
        "reply_email",
        requireConfirmation,
        async ({ message_id, body, is_html, attachments }: {
          message_id: string; body: string; is_html?: boolean;
          attachments?: { filename: string; mime_type: string; content_base64: string }[];
        }) => {
          const row = await findMessageRow(message_id);
          const account = await findAccountById(row.account_id);
          const accessToken = await accessTokenFor(account);
          const mailAttachments = attachments?.map((a) => ({
            filename: a.filename,
            mimeType: a.mime_type,
            contentBase64: a.content_base64,
          }));
          if (account.provider === "gmail") {
            await gmail.reply(accessToken, {
              to: row.sender_email,
              subject: row.subject,
              body,
              isHtml: is_html,
              threadId: row.thread_id,
              messageIdHeader: row.message_id_header,
              referencesHeader: row.references_header,
              attachments: mailAttachments,
            });
          } else {
            await graph.reply(accessToken, row.provider_message_id, body, mailAttachments);
          }
        }
      )
    );
  }

  if (enabled.has("archive_email")) {
    server.registerTool(
      "archive_email",
      {
        description: "Archive an email, removing it from the inbox.",
        inputSchema: { message_id: messageIdSchema },
      },
      guardedWrite("archive_email", requireConfirmation, async ({ message_id }: { message_id: string }) => {
        const row = await findMessageRow(message_id);
        const account = await findAccountById(row.account_id);
        const accessToken = await accessTokenFor(account);
        if (account.provider === "gmail") {
          await gmail.setArchived(accessToken, row.provider_message_id, true);
        } else {
          await graph.setArchived(accessToken, row.provider_message_id, true);
        }
        await supabase.from("messages").update({ folder: "archive" }).eq("id", message_id);
      })
    );
  }

  if (enabled.has("mark_read")) {
    server.registerTool(
      "mark_read",
      {
        description: "Mark an email as read or unread.",
        inputSchema: { message_id: messageIdSchema, is_read: z.boolean() },
      },
      guardedWrite(
        "mark_read",
        requireConfirmation,
        async ({ message_id, is_read }: { message_id: string; is_read: boolean }) => {
          const row = await findMessageRow(message_id);
          const account = await findAccountById(row.account_id);
          const accessToken = await accessTokenFor(account);
          if (account.provider === "gmail") {
            await gmail.setRead(accessToken, row.provider_message_id, is_read);
          } else {
            await graph.setRead(accessToken, row.provider_message_id, is_read);
          }
          await supabase.from("messages").update({ is_read }).eq("id", message_id);
        }
      )
    );
  }
}
