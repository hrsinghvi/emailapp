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

const MESSAGE_LIST_COLUMNS =
  "id, provider, account_email, sender_name, sender_email, subject, snippet, received_at, is_read, folder";

export function registerTools(server: McpServer): void {
  server.registerTool(
    "get_recent_emails",
    {
      description: "List recent emails (metadata only) across connected accounts, newest first.",
      inputSchema: {
        account: z.string().email().optional().describe("Filter to one connected account's email address"),
        limit: z.number().int().min(1).max(100).optional().describe("Max results (default 20)"),
      },
    },
    async ({ account, limit }) => {
      try {
        let q = supabase
          .from("messages")
          .select(MESSAGE_LIST_COLUMNS)
          .order("received_at", { ascending: false })
          .limit(limit ?? 20);
        if (account) q = q.eq("account_email", account);
        const { data, error } = await q;
        if (error) throw new Error(error.message);
        return textResult(data);
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "get_email_body",
    {
      description: "Fetch the full body of an email live from the provider (Gmail/Outlook), not the cached snippet.",
      inputSchema: { message_id: messageIdSchema.describe("Message id from get_recent_emails/search_emails") },
    },
    async ({ message_id }) => {
      try {
        const row = await findMessageRow(message_id);
        const account = await findAccountById(row.account_id);
        const accessToken = await accessTokenFor(account);
        const msg =
          account.provider === "gmail"
            ? await gmail.getMessage(accessToken, row.provider_message_id)
            : await graph.getMessage(accessToken, row.provider_message_id);
        return textResult({ subject: msg.subject, from: msg.senderEmail, receivedAt: msg.receivedAt, body: msg.body });
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "search_emails",
    {
      description: "Search cached email metadata by subject, sender, or snippet text.",
      inputSchema: {
        query: z.string().min(1),
        account: z.string().email().optional().describe("Filter to one connected account's email address"),
      },
    },
    async ({ query, account }) => {
      try {
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
        return textResult(data);
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "send_email",
    {
      description: "Send a brand-new email from one of the connected accounts.",
      inputSchema: {
        to: z.array(z.string().email()).min(1),
        subject: z.string(),
        body: z.string(),
        account: z.string().email().describe("Which connected account to send from"),
      },
    },
    async ({ to, subject, body, account }) => {
      try {
        const acc = await findAccountByEmail(account);
        const accessToken = await accessTokenFor(acc);
        if (acc.provider === "gmail") {
          await gmail.send(accessToken, { to: to.join(", "), subject, body });
        } else {
          await graph.send(accessToken, { to, subject, body });
        }
        return textResult({ ok: true });
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "reply_email",
    {
      description: "Reply in-thread to an existing email.",
      inputSchema: {
        message_id: messageIdSchema,
        body: z.string(),
      },
    },
    async ({ message_id, body }) => {
      try {
        const row = await findMessageRow(message_id);
        const account = await findAccountById(row.account_id);
        const accessToken = await accessTokenFor(account);
        if (account.provider === "gmail") {
          await gmail.reply(accessToken, {
            to: row.sender_email,
            subject: row.subject,
            body,
            threadId: row.thread_id,
            messageIdHeader: row.message_id_header,
            referencesHeader: row.references_header,
          });
        } else {
          await graph.reply(accessToken, row.provider_message_id, body);
        }
        return textResult({ ok: true });
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "archive_email",
    {
      description: "Archive an email, removing it from the inbox.",
      inputSchema: { message_id: messageIdSchema },
    },
    async ({ message_id }) => {
      try {
        const row = await findMessageRow(message_id);
        const account = await findAccountById(row.account_id);
        const accessToken = await accessTokenFor(account);
        if (account.provider === "gmail") {
          await gmail.setArchived(accessToken, row.provider_message_id, true);
        } else {
          await graph.setArchived(accessToken, row.provider_message_id, true);
        }
        await supabase.from("messages").update({ folder: "archive" }).eq("id", message_id);
        return textResult({ ok: true });
      } catch (err) {
        return errorResult(err);
      }
    }
  );

  server.registerTool(
    "mark_read",
    {
      description: "Mark an email as read or unread.",
      inputSchema: { message_id: messageIdSchema, is_read: z.boolean() },
    },
    async ({ message_id, is_read }) => {
      try {
        const row = await findMessageRow(message_id);
        const account = await findAccountById(row.account_id);
        const accessToken = await accessTokenFor(account);
        if (account.provider === "gmail") {
          await gmail.setRead(accessToken, row.provider_message_id, is_read);
        } else {
          await graph.setRead(accessToken, row.provider_message_id, is_read);
        }
        await supabase.from("messages").update({ is_read }).eq("id", message_id);
        return textResult({ ok: true });
      } catch (err) {
        return errorResult(err);
      }
    }
  );
}
