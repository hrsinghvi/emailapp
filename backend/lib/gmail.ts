import { randomUUID } from "crypto";

const BASE = "https://gmail.googleapis.com/gmail/v1/users/me";

export interface ParsedMessage {
  providerMessageId: string;
  threadId: string | null;
  messageIdHeader: string | null;
  referencesHeader: string | null;
  senderName: string;
  senderEmail: string;
  subject: string;
  snippet: string;
  body: string;
  receivedAt: string;
  isRead: boolean;
  to: string;
  cc: string;
  bcc: string;
  replyTo: string;
  listUnsubscribe: string | null;
  precedence: string | null;
}

export async function refreshAccessToken(refreshToken: string): Promise<string> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: process.env.GOOGLE_CLIENT_ID!,
    }),
  });
  if (!res.ok) throw new Error(`Gmail token refresh failed (${res.status}): ${await res.text()}`);
  const json = (await res.json()) as { access_token: string };
  return json.access_token;
}

export async function watchInbox(accessToken: string): Promise<{ historyId: string; expiration: string }> {
  const res = await fetch(`${BASE}/watch`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ topicName: process.env.GMAIL_PUBSUB_TOPIC, labelIds: ["INBOX"] }),
  });
  if (!res.ok) throw new Error(`Gmail watch failed (${res.status}): ${await res.text()}`);
  return (await res.json()) as { historyId: string; expiration: string };
}

/** Returns new INBOX message ids added since `startHistoryId`. */
export async function listNewMessageIds(accessToken: string, startHistoryId: string): Promise<string[]> {
  const url = `${BASE}/history?startHistoryId=${startHistoryId}&historyTypes=messageAdded&labelId=INBOX`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (!res.ok) throw new Error(`Gmail history.list failed (${res.status}): ${await res.text()}`);
  const json = (await res.json()) as {
    history?: { messagesAdded?: { message: { id: string } }[] }[];
  };
  const ids = new Set<string>();
  for (const h of json.history ?? []) {
    for (const m of h.messagesAdded ?? []) ids.add(m.message.id);
  }
  return [...ids];
}

export async function getMessage(accessToken: string, id: string): Promise<ParsedMessage> {
  const res = await fetch(`${BASE}/messages/${id}?format=full`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) throw new Error(`Gmail messages.get failed (${res.status}): ${await res.text()}`);
  const raw = (await res.json()) as {
    id: string;
    threadId?: string;
    snippet?: string;
    internalDate?: string;
    labelIds?: string[];
    payload?: Payload;
  };
  const headers = raw.payload?.headers ?? [];
  const header = (name: string) =>
    headers.find((h) => h.name.toLowerCase() === name.toLowerCase())?.value ?? "";
  const { name, email } = parseFrom(header("From"));
  const receivedAt = raw.internalDate
    ? new Date(Number(raw.internalDate)).toISOString()
    : new Date().toISOString();

  return {
    providerMessageId: raw.id,
    threadId: raw.threadId ?? null,
    messageIdHeader: header("Message-ID") || null,
    referencesHeader: header("References") || null,
    senderName: name,
    senderEmail: email,
    subject: header("Subject"),
    snippet: decodeEntities(raw.snippet ?? ""),
    body: extractBody(raw.payload) ?? raw.snippet ?? "",
    receivedAt,
    isRead: !(raw.labelIds ?? []).includes("UNREAD"),
    to: header("To"),
    cc: header("Cc"),
    bcc: header("Bcc"),
    replyTo: header("Reply-To"),
    listUnsubscribe: header("List-Unsubscribe") || null,
    precedence: header("Precedence") || null,
  };
}

interface Payload {
  mimeType?: string;
  headers?: { name: string; value: string }[];
  body?: { data?: string };
  parts?: Payload[];
}

function extractBody(payload?: Payload): string | null {
  if (!payload) return null;
  if (payload.mimeType === "text/plain" && payload.body?.data) {
    return decodeBase64Url(payload.body.data);
  }
  if (payload.parts) {
    for (const p of payload.parts) {
      if (p.mimeType === "text/plain" && p.body?.data) return decodeBase64Url(p.body.data);
    }
    for (const p of payload.parts) {
      const nested = extractBody(p);
      if (nested) return nested;
    }
  }
  if (payload.mimeType === "text/html" && payload.body?.data) {
    return stripHtml(decodeBase64Url(payload.body.data) ?? "");
  }
  return null;
}

function decodeBase64Url(s: string): string {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  return Buffer.from(b64, "base64").toString("utf8");
}

function stripHtml(html: string): string {
  return decodeEntities(html.replace(/<[^>]+>/g, "")).trim();
}

function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ");
}

// MARK: - Mutations

async function modifyLabels(
  accessToken: string,
  id: string,
  { add = [], remove = [] }: { add?: string[]; remove?: string[] }
): Promise<void> {
  const res = await fetch(`${BASE}/messages/${id}/modify`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ addLabelIds: add, removeLabelIds: remove }),
  });
  if (!res.ok) throw new Error(`Gmail modify failed (${res.status}): ${await res.text()}`);
}

export async function setRead(accessToken: string, id: string, read: boolean): Promise<void> {
  await modifyLabels(accessToken, id, read ? { remove: ["UNREAD"] } : { add: ["UNREAD"] });
}

/** Gmail has no "archive" label — archiving just removes INBOX. */
export async function setArchived(accessToken: string, id: string, archived: boolean): Promise<void> {
  await modifyLabels(accessToken, id, archived ? { remove: ["INBOX"] } : { add: ["INBOX"] });
}

export interface MailAttachment {
  filename: string;
  mimeType: string;
  /** Raw base64 content (not base64url), exactly as an MCP client would send it. */
  contentBase64: string;
}

export async function send(
  accessToken: string,
  params: { to: string; subject: string; body: string; isHtml?: boolean; attachments?: MailAttachment[] }
): Promise<void> {
  const raw = buildRawMessage(params);
  await sendRaw(accessToken, raw, null);
}

export async function reply(
  accessToken: string,
  params: {
    to: string;
    subject: string;
    body: string;
    isHtml?: boolean;
    threadId: string | null;
    messageIdHeader: string | null;
    referencesHeader: string | null;
    attachments?: MailAttachment[];
  }
): Promise<void> {
  let subject = params.subject;
  if (!subject.toLowerCase().startsWith("re:")) subject = `Re: ${subject}`;
  const references = [params.referencesHeader, params.messageIdHeader].filter(Boolean).join(" ");
  const raw = buildRawMessage({
    to: params.to,
    subject,
    body: params.body,
    isHtml: params.isHtml,
    inReplyTo: params.messageIdHeader ?? undefined,
    references: references || undefined,
    attachments: params.attachments,
  });
  await sendRaw(accessToken, raw, params.threadId);
}

function buildRawMessage(params: {
  to: string;
  subject: string;
  body: string;
  isHtml?: boolean;
  inReplyTo?: string;
  references?: string;
  attachments?: MailAttachment[];
}): string {
  const bodyContentType = params.isHtml ? "text/html" : "text/plain";
  const attachments = params.attachments ?? [];
  if (attachments.length === 0) {
    let headers = `To: ${params.to}\r\nSubject: ${params.subject}\r\nContent-Type: ${bodyContentType}; charset=UTF-8\r\n`;
    if (params.inReplyTo) headers += `In-Reply-To: ${params.inReplyTo}\r\n`;
    if (params.references) headers += `References: ${params.references}\r\n`;
    return base64UrlEncode(`${headers}\r\n${params.body}`);
  }

  const boundary = `boundary-${randomUUID()}`;
  let headers = `To: ${params.to}\r\nSubject: ${params.subject}\r\nMIME-Version: 1.0\r\n`;
  headers += `Content-Type: multipart/mixed; boundary="${boundary}"\r\n`;
  if (params.inReplyTo) headers += `In-Reply-To: ${params.inReplyTo}\r\n`;
  if (params.references) headers += `References: ${params.references}\r\n`;

  let mime = `--${boundary}\r\nContent-Type: ${bodyContentType}; charset=UTF-8\r\n\r\n${params.body}\r\n`;
  for (const attachment of attachments) {
    const b64 = Buffer.from(attachment.contentBase64, "base64").toString("base64").replace(/(.{76})/g, "$1\r\n");
    mime += `--${boundary}\r\n`;
    mime += `Content-Type: ${attachment.mimeType}; name="${attachment.filename}"\r\n`;
    mime += `Content-Disposition: attachment; filename="${attachment.filename}"\r\n`;
    mime += `Content-Transfer-Encoding: base64\r\n\r\n${b64}\r\n`;
  }
  mime += `--${boundary}--`;

  return base64UrlEncode(`${headers}\r\n${mime}`);
}

async function sendRaw(accessToken: string, raw: string, threadId: string | null): Promise<void> {
  const res = await fetch(`${BASE}/messages/send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ raw, threadId: threadId ?? undefined }),
  });
  if (!res.ok) throw new Error(`Gmail send failed (${res.status}): ${await res.text()}`);
}

/** Creates a Gmail draft (POST /drafts) — never sends. */
export async function createDraft(
  accessToken: string,
  params: { to: string; subject: string; body: string; isHtml?: boolean }
): Promise<void> {
  const raw = buildRawMessage(params);
  const res = await fetch(`${BASE}/drafts`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ message: { raw } }),
  });
  if (!res.ok) throw new Error(`Gmail draft create failed (${res.status}): ${await res.text()}`);
}

/** Recent messages sent to `recipient` from the Sent folder (subject + snippet). */
export async function listSentTo(
  accessToken: string,
  recipient: string,
  limit: number
): Promise<{ providerMessageId: string; subject: string; snippet: string; receivedAt: string }[]> {
  const q = encodeURIComponent(`in:sent to:${recipient}`);
  const listRes = await fetch(`${BASE}/messages?q=${q}&maxResults=${limit}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!listRes.ok) throw new Error(`Gmail sent search failed (${listRes.status}): ${await listRes.text()}`);
  const listJson = (await listRes.json()) as { messages?: { id: string }[] };
  const ids = (listJson.messages ?? []).slice(0, limit).map((m) => m.id);
  const messages = await Promise.all(
    ids.map(async (id) => {
      const msg = await getMessage(accessToken, id);
      return {
        providerMessageId: msg.providerMessageId,
        subject: msg.subject,
        snippet: msg.snippet,
        receivedAt: msg.receivedAt,
      };
    })
  );
  return messages;
}

function base64UrlEncode(s: string): string {
  return Buffer.from(s, "utf8").toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function parseFrom(raw: string): { name: string; email: string } {
  const match = raw.match(/^(.*)<(.+)>$/);
  if (match) {
    const name = match[1].trim().replace(/^["']|["']$/g, "");
    const email = match[2].trim();
    return { name: name || email, email };
  }
  return { name: raw.trim(), email: raw.trim() };
}
