import type { VercelRequest, VercelResponse } from "@vercel/node";
import { supabase } from "../../lib/supabase";
import { decrypt } from "../../lib/crypto";
import * as graph from "../../lib/graph";
import { upsertMessage } from "../../lib/messages";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  // Subscription-creation handshake: Graph calls this URL with
  // ?validationToken=... and expects it echoed back as plain text within 10s.
  const validationToken = req.query.validationToken;
  if (typeof validationToken === "string") {
    res.setHeader("Content-Type", "text/plain");
    return res.status(200).send(validationToken);
  }

  if (req.method !== "POST") return res.status(405).end();

  const body = req.body as {
    value?: { subscriptionId: string; clientState?: string; resource: string }[];
  };

  for (const notification of body.value ?? []) {
    // clientState is Graph's only per-notification integrity check (no
    // request signing) — reject anything that doesn't match what we set
    // when creating the subscription.
    if (notification.clientState !== process.env.GRAPH_CLIENT_STATE) continue;

    const { data: account } = await supabase
      .from("accounts")
      .select("*")
      .eq("provider", "outlook")
      .eq("subscription_id", notification.subscriptionId)
      .single();
    if (!account) continue;

    const messageId = notification.resource.split("/").pop();
    if (!messageId) continue;

    try {
      const refreshToken = decrypt(account.encrypted_refresh_token);
      const accessToken = await graph.refreshAccessToken(refreshToken);
      const msg = await graph.getMessage(accessToken, messageId);
      await upsertMessage({
        accountId: account.id,
        accountEmail: account.email,
        provider: "outlook",
        providerMessageId: msg.providerMessageId,
        senderName: msg.senderName,
        senderEmail: msg.senderEmail,
        subject: msg.subject,
        snippet: msg.snippet,
        body: msg.body,
        receivedAt: msg.receivedAt,
        isRead: msg.isRead,
      });
    } catch (err) {
      console.error("graph webhook processing failed", err);
    }
  }

  return res.status(202).end();
}
