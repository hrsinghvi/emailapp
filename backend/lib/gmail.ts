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

function parseFrom(raw: string): { name: string; email: string } {
  const match = raw.match(/^(.*)<(.+)>$/);
  if (match) {
    const name = match[1].trim().replace(/^["']|["']$/g, "");
    const email = match[2].trim();
    return { name: name || email, email };
  }
  return { name: raw.trim(), email: raw.trim() };
}
