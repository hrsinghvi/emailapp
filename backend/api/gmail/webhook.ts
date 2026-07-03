import type { VercelRequest, VercelResponse } from "@vercel/node";
import { OAuth2Client } from "google-auth-library";
import { supabase } from "../../lib/supabase";
import { decrypt } from "../../lib/crypto";
import * as gmail from "../../lib/gmail";
import { upsertMessage } from "../../lib/messages";

const oauthClient = new OAuth2Client();

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).end();

  // Pub/Sub push signs every request with an OIDC token in the Authorization
  // header — verify it before trusting anything in the body.
  const authHeader = req.headers.authorization;
  const idToken = authHeader?.startsWith("Bearer ") ? authHeader.slice(7) : null;
  if (!idToken) return res.status(401).end();
  try {
    await oauthClient.verifyIdToken({
      idToken,
      audience: `${process.env.PUBLIC_BASE_URL}/api/gmail/webhook`,
    });
  } catch {
    return res.status(401).end();
  }

  const body = req.body as { message?: { data?: string } };
  if (!body.message?.data) return res.status(200).end();

  const decoded = JSON.parse(Buffer.from(body.message.data, "base64").toString("utf8")) as {
    emailAddress: string;
    historyId: string;
  };

  const { data: account } = await supabase
    .from("accounts")
    .select("*")
    .eq("provider", "gmail")
    .eq("email", decoded.emailAddress)
    .single();
  if (!account) return res.status(200).end(); // unknown account, ack and drop

  try {
    const refreshToken = decrypt(account.encrypted_refresh_token);
    const accessToken = await gmail.refreshAccessToken(refreshToken);
    const startHistoryId = account.history_id ?? decoded.historyId;
    const newIds = await gmail.listNewMessageIds(accessToken, startHistoryId);

    for (const id of newIds) {
      const msg = await gmail.getMessage(accessToken, id);
      await upsertMessage({
        accountId: account.id,
        accountEmail: account.email,
        provider: "gmail",
        providerMessageId: msg.providerMessageId,
        threadId: msg.threadId,
        messageIdHeader: msg.messageIdHeader,
        referencesHeader: msg.referencesHeader,
        senderName: msg.senderName,
        senderEmail: msg.senderEmail,
        subject: msg.subject,
        snippet: msg.snippet,
        body: msg.body,
        receivedAt: msg.receivedAt,
        isRead: msg.isRead,
      });
    }

    await supabase.from("accounts").update({ history_id: decoded.historyId }).eq("id", account.id);
  } catch (err) {
    // Log and still 200 — a non-2xx makes Pub/Sub retry the same notification
    // forever; the next real notification carries fresh state regardless.
    console.error("gmail webhook processing failed", err);
  }

  return res.status(200).end();
}
