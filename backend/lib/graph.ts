const BASE = "https://graph.microsoft.com/v1.0";

export interface ParsedMessage {
  providerMessageId: string;
  senderName: string;
  senderEmail: string;
  subject: string;
  snippet: string;
  body: string;
  receivedAt: string;
  isRead: boolean;
}

export async function refreshAccessToken(refreshToken: string): Promise<string> {
  const res = await fetch("https://login.microsoftonline.com/common/oauth2/v2.0/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: process.env.AZURE_CLIENT_ID!,
    }),
  });
  if (!res.ok) throw new Error(`Graph token refresh failed (${res.status}): ${await res.text()}`);
  const json = (await res.json()) as { access_token: string };
  return json.access_token;
}

/** Max lifetime for a mail-resource subscription is ~2.94 days (4230 min). */
export async function createSubscription(
  accessToken: string,
  notificationUrl: string,
  clientState: string
): Promise<{ id: string; expirationDateTime: string }> {
  const expirationDateTime = new Date(Date.now() + 4230 * 60 * 1000).toISOString();
  const res = await fetch(`${BASE}/subscriptions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      changeType: "created",
      notificationUrl,
      resource: "me/mailFolders('Inbox')/messages",
      expirationDateTime,
      clientState,
    }),
  });
  if (!res.ok) throw new Error(`Graph subscription create failed (${res.status}): ${await res.text()}`);
  return (await res.json()) as { id: string; expirationDateTime: string };
}

export async function renewSubscription(
  accessToken: string,
  subscriptionId: string
): Promise<{ expirationDateTime: string }> {
  const expirationDateTime = new Date(Date.now() + 4230 * 60 * 1000).toISOString();
  const res = await fetch(`${BASE}/subscriptions/${subscriptionId}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ expirationDateTime }),
  });
  if (!res.ok) throw new Error(`Graph subscription renew failed (${res.status}): ${await res.text()}`);
  return (await res.json()) as { expirationDateTime: string };
}

export async function getMessage(accessToken: string, id: string): Promise<ParsedMessage> {
  const url = `${BASE}/me/messages/${id}?$select=id,subject,bodyPreview,body,from,receivedDateTime,isRead`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (!res.ok) throw new Error(`Graph messages.get failed (${res.status}): ${await res.text()}`);
  const raw = (await res.json()) as {
    id: string;
    subject?: string;
    bodyPreview?: string;
    body?: { contentType?: string; content?: string };
    from?: { emailAddress?: { name?: string; address?: string } };
    receivedDateTime?: string;
    isRead?: boolean;
  };
  const senderName = raw.from?.emailAddress?.name ?? raw.from?.emailAddress?.address ?? "";
  const senderEmail = raw.from?.emailAddress?.address ?? "";
  const plainBody =
    raw.body?.contentType?.toLowerCase() === "html"
      ? stripHtml(raw.body.content ?? "")
      : raw.body?.content ?? raw.bodyPreview ?? "";

  return {
    providerMessageId: raw.id,
    senderName: senderName || senderEmail,
    senderEmail,
    subject: raw.subject ?? "",
    snippet: decodeEntities(raw.bodyPreview ?? ""),
    body: plainBody,
    receivedAt: raw.receivedDateTime ?? new Date().toISOString(),
    isRead: raw.isRead ?? true,
  };
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
