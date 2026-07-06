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
  watch_expiration?: string | null;
}

interface MessageRow {
  id: string;
  account_id: string;
  provider: "gmail" | "outlook";
  provider_message_id: string;
  thread_id: string | null;
  message_id_header: string | null;
  references_header: string | null;
  sender_name: string;
  sender_email: string;
  subject: string;
  body: string;
  received_at: string;
}

interface AppSettingsRow {
  mcp_require_confirmation: boolean;
  mcp_enabled_tools: string[];
}

const WRITE_TOOLS = new Set(["send_email", "reply_email", "archive_email", "mark_read", "save_draft"]);

const DEFAULT_ENABLED_TOOLS = [
  ...WRITE_TOOLS,
  "get_recent_emails",
  "get_email_body",
  "search_emails",
  "get_thread",
  "list_accounts",
  "search_by_sender",
  "summarize_thread",
  "extract_dates_deadlines",
  "get_unread_count",
  "get_message_metadata",
  "check_sender_reputation",
  "get_reply_context",
];

async function loadSettings(): Promise<AppSettingsRow> {
  const { data, error } = await supabase
    .from("app_settings")
    .select("mcp_require_confirmation, mcp_enabled_tools")
    .eq("id", true)
    .single();
  // No settings row (shouldn't happen post-migration) — fail open with
  // every tool enabled and no confirmation gate, matching pre-settings behavior.
  if (error || !data) return { mcp_require_confirmation: false, mcp_enabled_tools: DEFAULT_ENABLED_TOOLS };
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

// ---------------------------------------------------------------------------
// Tool bodies — plain exported functions, reused by registerTools' thin
// wrappers below and callable directly by other tools (e.g. summarize_thread
// reuses getThread, get_reply_context reuses getThread too).
// ---------------------------------------------------------------------------

export async function getRecentEmails({ account, limit }: { account?: string; limit?: number }) {
  let q = supabase
    .from("messages")
    .select(MESSAGE_LIST_COLUMNS)
    .order("received_at", { ascending: false })
    .limit(limit ?? 20);
  if (account) q = q.eq("account_email", account);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return data;
}

export async function getEmailBody({ message_id }: { message_id: string }) {
  const row = await findMessageRow(message_id);
  const account = await findAccountById(row.account_id);
  const accessToken = await accessTokenFor(account);
  const msg =
    account.provider === "gmail"
      ? await gmail.getMessage(accessToken, row.provider_message_id)
      : await graph.getMessage(accessToken, row.provider_message_id);
  return { subject: msg.subject, from: msg.senderEmail, receivedAt: msg.receivedAt, body: msg.body };
}

export async function searchEmails({ query, account }: { query: string; account?: string }) {
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
}

interface MailAttachmentArg {
  filename: string;
  mime_type: string;
  content_base64: string;
}

export async function sendEmail({ to, subject, body, is_html, account, attachments }: {
  to: string[]; subject: string; body: string; is_html?: boolean; account: string;
  attachments?: MailAttachmentArg[];
}) {
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

export async function replyEmail({ message_id, body, is_html, attachments }: {
  message_id: string; body: string; is_html?: boolean;
  attachments?: MailAttachmentArg[];
}) {
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

export async function archiveEmail({ message_id }: { message_id: string }) {
  const row = await findMessageRow(message_id);
  const account = await findAccountById(row.account_id);
  const accessToken = await accessTokenFor(account);
  if (account.provider === "gmail") {
    await gmail.setArchived(accessToken, row.provider_message_id, true);
  } else {
    await graph.setArchived(accessToken, row.provider_message_id, true);
  }
  await supabase.from("messages").update({ folder: "archive" }).eq("id", message_id);
}

export async function markRead({ message_id, is_read }: { message_id: string; is_read: boolean }) {
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

const THREAD_COLUMNS =
  "id, account_id, provider, provider_message_id, sender_name, sender_email, subject, body, received_at";

/** Rows for a thread, oldest first, with cached body — live fetch only when the cached body is empty. */
async function getThreadRows(threadId: string): Promise<MessageRow[]> {
  const { data, error } = await supabase
    .from("messages")
    .select(THREAD_COLUMNS)
    .eq("thread_id", threadId)
    .order("received_at", { ascending: true });
  if (error) throw new Error(error.message);
  const rows = (data ?? []) as MessageRow[];
  return Promise.all(
    rows.map(async (row) => {
      if (row.body && row.body.trim().length > 0) return row;
      try {
        const account = await findAccountById(row.account_id);
        const accessToken = await accessTokenFor(account);
        const msg =
          account.provider === "gmail"
            ? await gmail.getMessage(accessToken, row.provider_message_id)
            : await graph.getMessage(accessToken, row.provider_message_id);
        return { ...row, body: msg.body };
      } catch {
        return row; // fall back to whatever's cached (possibly empty) rather than fail the whole thread
      }
    })
  );
}

export async function getThread({ thread_id }: { thread_id: string }) {
  const rows = await getThreadRows(thread_id);
  return rows.map((r) => ({
    message_id: r.id,
    sender_name: r.sender_name,
    sender_email: r.sender_email,
    subject: r.subject,
    received_at: r.received_at,
    body: r.body,
  }));
}

export async function listAccounts() {
  const { data, error } = await supabase.from("accounts").select("id, email, provider, watch_expiration");
  if (error) throw new Error(error.message);
  const now = Date.now();
  return (data ?? []).map((a) => {
    const expiresAt = a.watch_expiration ? new Date(a.watch_expiration).getTime() : 0;
    return {
      email: a.email,
      provider: a.provider,
      connection_status: expiresAt > now ? "connected" : "stale",
      watch_expiration: a.watch_expiration ?? null,
    };
  });
}

export async function searchBySender({ email_or_domain, date_range }: {
  email_or_domain: string;
  date_range?: { from?: string; to?: string };
}) {
  const isDomainOnly = !email_or_domain.includes("@") || email_or_domain.startsWith("@");
  const domain = email_or_domain.replace(/^@/, "");
  const pattern = isDomainOnly ? `%@${domain}` : `%${email_or_domain}%`;
  let q = supabase
    .from("messages")
    .select(MESSAGE_LIST_COLUMNS)
    .ilike("sender_email", pattern)
    .order("received_at", { ascending: false })
    .limit(50);
  if (date_range?.from) q = q.gte("received_at", date_range.from);
  if (date_range?.to) q = q.lte("received_at", date_range.to);
  const { data, error } = await q;
  if (error) throw new Error(error.message);
  return data;
}

/**
 * Structured data only — per the hard constraint, this backend never calls
 * an LLM. The calling Claude (via MCP, on the user's Pro plan) does the
 * actual summarizing/unanswered-question reasoning over this payload.
 */
export async function summarizeThread({ thread_id }: { thread_id: string }) {
  const rows = await getThreadRows(thread_id);
  const participants = [...new Set(rows.map((r) => r.sender_email))];
  return {
    thread_id,
    participants,
    message_count: rows.length,
    messages: rows.map((r) => ({
      sender: r.sender_email,
      date: r.received_at,
      snippet: r.body.slice(0, 500),
    })),
  };
}

interface DateCandidate {
  match: string;
  context_sentence: string;
  confidence: "high" | "medium" | "low";
}

// ponytail: regex date/deadline extraction, not a full NLP date parser
// (chrono etc). Upgrade if candidates prove too noisy for real mail.
const DATE_PATTERNS: { re: RegExp; confidence: DateCandidate["confidence"] }[] = [
  // "by/before/until March 5", "due March 5, 2026"
  { re: /\b(?:by|before|until|due)\s+((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s*\d{4})?)/gi, confidence: "high" },
  // ISO / slash dates: 2026-07-06, 07/06/2026
  { re: /\b(\d{4}-\d{2}-\d{2})\b/g, confidence: "medium" },
  { re: /\b(\d{1,2}\/\d{1,2}\/\d{2,4})\b/g, confidence: "medium" },
  // Weekday + relative: "by Friday", "next Monday", "tomorrow", "end of day"
  { re: /\b(?:by|before|next)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/gi, confidence: "medium" },
  { re: /\b(tomorrow|end of day|eod|end of week|eow)\b/gi, confidence: "low" },
  // Bare month-day: "March 5", "Mar 5th"
  { re: /\b((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s*\d{4})?)\b/gi, confidence: "low" },
];

function sentenceContaining(body: string, index: number): string {
  const before = body.lastIndexOf(".", index);
  const after = body.indexOf(".", index);
  const start = before === -1 ? 0 : before + 1;
  const end = after === -1 ? body.length : after + 1;
  return body.slice(Math.max(0, start), Math.min(body.length, end)).trim();
}

export function extractDateCandidates(body: string): DateCandidate[] {
  const seen = new Set<string>();
  const candidates: DateCandidate[] = [];
  for (const { re, confidence } of DATE_PATTERNS) {
    for (const m of body.matchAll(re)) {
      const match = m[0];
      const key = match.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      candidates.push({ match, context_sentence: sentenceContaining(body, m.index ?? 0), confidence });
    }
  }
  return candidates;
}

export async function extractDatesDeadlines({ message_id }: { message_id: string }) {
  const row = await findMessageRow(message_id);
  let body = row.body;
  if (!body || body.trim().length === 0) {
    const account = await findAccountById(row.account_id);
    const accessToken = await accessTokenFor(account);
    const msg =
      account.provider === "gmail"
        ? await gmail.getMessage(accessToken, row.provider_message_id)
        : await graph.getMessage(accessToken, row.provider_message_id);
    body = msg.body;
  }
  return { message_id, candidates: extractDateCandidates(body) };
}

export async function getUnreadCount({ account }: { account?: string }) {
  if (account) {
    const { count, error } = await supabase
      .from("messages")
      .select("id", { count: "exact", head: true })
      .eq("account_email", account)
      .eq("is_read", false);
    if (error) throw new Error(error.message);
    return [{ account_email: account, unread_count: count ?? 0 }];
  }
  const { data: accounts, error: accErr } = await supabase.from("accounts").select("email");
  if (accErr) throw new Error(accErr.message);
  return Promise.all(
    (accounts ?? []).map(async (a) => {
      const { count, error } = await supabase
        .from("messages")
        .select("id", { count: "exact", head: true })
        .eq("account_email", a.email)
        .eq("is_read", false);
      if (error) throw new Error(error.message);
      return { account_email: a.email, unread_count: count ?? 0 };
    })
  );
}

export async function saveDraft({ to, subject, body, account }: {
  to: string[]; subject: string; body: string; account: string;
}) {
  const acc = await findAccountByEmail(account);
  const accessToken = await accessTokenFor(acc);
  if (acc.provider === "gmail") {
    await gmail.createDraft(accessToken, { to: to.join(", "), subject, body });
  } else {
    await graph.createDraft(accessToken, { to, subject, body });
  }
}

export async function getMessageMetadata({ message_id }: { message_id: string }) {
  const row = await findMessageRow(message_id);
  const account = await findAccountById(row.account_id);
  const accessToken = await accessTokenFor(account);
  const msg =
    account.provider === "gmail"
      ? await gmail.getMessage(accessToken, row.provider_message_id)
      : await graph.getMessage(accessToken, row.provider_message_id);

  const replyToDomain = msg.replyTo.split("@")[1]?.toLowerCase().trim();
  const senderDomain = msg.senderEmail.split("@")[1]?.toLowerCase().trim();
  const replyToMismatch = Boolean(msg.replyTo && replyToDomain && senderDomain && replyToDomain !== senderDomain);

  return {
    message_id,
    from: msg.senderEmail,
    from_display_name: msg.senderName,
    to: msg.to,
    cc: msg.cc,
    bcc: msg.bcc,
    reply_to: msg.replyTo || null,
    received_at: msg.receivedAt,
    mass_send_signals: {
      list_unsubscribe: msg.listUnsubscribe,
      precedence: msg.precedence,
      reply_to_domain_mismatch: replyToMismatch,
    },
  };
}

export async function checkSenderReputation({ email }: { email: string }) {
  const { data, error, count } = await supabase
    .from("messages")
    .select("received_at", { count: "exact" })
    .eq("sender_email", email)
    .order("received_at", { ascending: true });
  if (error) throw new Error(error.message);
  const rows = data ?? [];
  const domain = email.split("@")[1]?.toLowerCase() ?? null;
  return {
    email,
    domain,
    prior_message_count: count ?? rows.length,
    first_seen: rows[0]?.received_at ?? null,
    first_contact: (count ?? rows.length) === 0,
  };
}

export async function getReplyContext({ message_id }: { message_id: string }) {
  const row = await findMessageRow(message_id);
  const account = await findAccountById(row.account_id);
  const accessToken = await accessTokenFor(account);
  const threadRows = row.thread_id ? await getThreadRows(row.thread_id) : [];
  const sent =
    account.provider === "gmail"
      ? await gmail.listSentTo(accessToken, row.sender_email, 3)
      : await graph.listSentTo(accessToken, row.sender_email, 3);
  return {
    thread: threadRows.map((r) => ({ sender: r.sender_email, date: r.received_at, snippet: r.body.slice(0, 500) })),
    past_sent_to_recipient: sent.map((s) => ({ subject: s.subject, date: s.receivedAt, snippet: s.snippet })),
  };
}

// ---------------------------------------------------------------------------

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
      guardedRead("get_recent_emails", getRecentEmails)
    );
  }

  if (enabled.has("get_email_body")) {
    server.registerTool(
      "get_email_body",
      {
        description: "Fetch the full body of an email live from the provider (Gmail/Outlook), not the cached snippet.",
        inputSchema: { message_id: messageIdSchema.describe("Message id from get_recent_emails/search_emails") },
      },
      guardedRead("get_email_body", getEmailBody)
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
      guardedRead("search_emails", searchEmails)
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
      guardedWrite("send_email", requireConfirmation, sendEmail)
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
      guardedWrite("reply_email", requireConfirmation, replyEmail)
    );
  }

  if (enabled.has("archive_email")) {
    server.registerTool(
      "archive_email",
      {
        description: "Archive an email, removing it from the inbox.",
        inputSchema: { message_id: messageIdSchema },
      },
      guardedWrite("archive_email", requireConfirmation, archiveEmail)
    );
  }

  if (enabled.has("mark_read")) {
    server.registerTool(
      "mark_read",
      {
        description: "Mark an email as read or unread.",
        inputSchema: { message_id: messageIdSchema, is_read: z.boolean() },
      },
      guardedWrite("mark_read", requireConfirmation, markRead)
    );
  }

  if (enabled.has("get_thread")) {
    server.registerTool(
      "get_thread",
      {
        description: "Get every cached message in a thread, oldest first, with full bodies.",
        inputSchema: { thread_id: z.string().min(1).describe("Provider thread id (Gmail threadId / Graph conversationId)") },
      },
      guardedRead("get_thread", getThread)
    );
  }

  if (enabled.has("list_accounts")) {
    server.registerTool(
      "list_accounts",
      {
        description: "List connected accounts (email, provider, connection status).",
        inputSchema: {},
      },
      guardedRead("list_accounts", listAccounts)
    );
  }

  if (enabled.has("search_by_sender")) {
    server.registerTool(
      "search_by_sender",
      {
        description: "Find cached emails from a specific sender address or domain, optionally within a date range.",
        inputSchema: {
          email_or_domain: z.string().min(1).describe('An email address, or a bare domain like "amazon.com"'),
          date_range: z
            .object({ from: z.string().optional(), to: z.string().optional() })
            .optional()
            .describe("ISO date bounds on received_at"),
        },
      },
      guardedRead("search_by_sender", searchBySender)
    );
  }

  if (enabled.has("summarize_thread")) {
    server.registerTool(
      "summarize_thread",
      {
        description:
          "Return structured per-message data for a thread (participants, sender/date/snippet per message) for the calling model to summarize. Does not generate a summary itself.",
        inputSchema: { thread_id: z.string().min(1) },
      },
      guardedRead("summarize_thread", summarizeThread)
    );
  }

  if (enabled.has("extract_dates_deadlines")) {
    server.registerTool(
      "extract_dates_deadlines",
      {
        description:
          "Regex-extract date/deadline candidates from a message body, with surrounding sentence context, for the calling model to refine.",
        inputSchema: { message_id: messageIdSchema },
      },
      guardedRead("extract_dates_deadlines", extractDatesDeadlines)
    );
  }

  if (enabled.has("get_unread_count")) {
    server.registerTool(
      "get_unread_count",
      {
        description: "Unread message count, per account (or for one account if specified).",
        inputSchema: { account: z.string().email().optional() },
      },
      guardedRead("get_unread_count", getUnreadCount)
    );
  }

  if (enabled.has("save_draft")) {
    server.registerTool(
      "save_draft",
      {
        description: "Save a new email as a draft in the provider (Gmail/Outlook) — never sends it.",
        inputSchema: {
          to: z.array(z.string().email()).min(1),
          subject: z.string(),
          body: z.string(),
          account: z.string().email().describe("Which connected account to save the draft in"),
        },
      },
      guardedWrite("save_draft", requireConfirmation, saveDraft)
    );
  }

  if (enabled.has("get_message_metadata")) {
    server.registerTool(
      "get_message_metadata",
      {
        description:
          "Live-fetch extended headers for a message: full recipients, reply-to, and mass-send signals (List-Unsubscribe, Precedence, reply-to/sender domain mismatch).",
        inputSchema: { message_id: messageIdSchema },
      },
      guardedRead("get_message_metadata", getMessageMetadata)
    );
  }

  if (enabled.has("check_sender_reputation")) {
    server.registerTool(
      "check_sender_reputation",
      {
        description: "Prior message history for a sender address: count, first-seen date, domain, first-contact flag.",
        inputSchema: { email: z.string().email() },
      },
      guardedRead("check_sender_reputation", checkSenderReputation)
    );
  }

  if (enabled.has("get_reply_context")) {
    server.registerTool(
      "get_reply_context",
      {
        description:
          "Thread history plus a sample of past sent messages to the same recipient, for matching tone when drafting a reply.",
        inputSchema: { message_id: messageIdSchema },
      },
      guardedRead("get_reply_context", getReplyContext)
    );
  }
}
