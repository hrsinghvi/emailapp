import type { VercelRequest, VercelResponse } from "@vercel/node";
import { randomUUID } from "crypto";
import { supabase } from "../../lib/supabase";
import { encrypt } from "../../lib/crypto";
import * as gmail from "../../lib/gmail";
import * as graph from "../../lib/graph";
import * as googleCalendar from "../../lib/googleCalendar";
import * as graphCalendar from "../../lib/graphCalendar";

/**
 * Called by the Swift app right after a provider OAuth flow completes.
 * Stores the refresh token (encrypted) and immediately starts push
 * notifications for that account (Gmail watch / Graph subscription).
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).end();

  const { provider, email, refreshToken } = (req.body ?? {}) as {
    provider?: "gmail" | "outlook";
    email?: string;
    refreshToken?: string;
  };
  if (!provider || !email || !refreshToken || !["gmail", "outlook"].includes(provider)) {
    return res.status(400).json({ error: "provider ('gmail'|'outlook'), email, refreshToken required" });
  }

  const { data: account, error: upsertError } = await supabase
    .from("accounts")
    .upsert(
      { provider, email, encrypted_refresh_token: encrypt(refreshToken) },
      { onConflict: "provider,email" }
    )
    .select()
    .single();
  if (upsertError || !account) {
    return res.status(500).json({ error: upsertError?.message ?? "account upsert failed" });
  }

  let mailWarning: string | null = null;
  try {
    if (provider === "gmail") {
      const accessToken = await gmail.refreshAccessToken(refreshToken);
      const { historyId, expiration } = await gmail.watchInbox(accessToken);
      await supabase
        .from("accounts")
        .update({ history_id: historyId, watch_expiration: new Date(Number(expiration)).toISOString() })
        .eq("id", account.id);
    } else {
      const accessToken = await graph.refreshAccessToken(refreshToken);
      const notificationUrl = `${process.env.PUBLIC_BASE_URL}/api/graph/webhook`;
      const sub = await graph.createSubscription(accessToken, notificationUrl, process.env.GRAPH_CLIENT_STATE!);
      await supabase
        .from("accounts")
        .update({ subscription_id: sub.id, watch_expiration: sub.expirationDateTime })
        .eq("id", account.id);
    }
  } catch (err) {
    // Account + refresh token are safely stored either way; only the push
    // subscription failed. The daily cron will retry since watch_expiration
    // stays null/stale, which the renewal query treats as overdue.
    mailWarning = `mail push setup failed: ${(err as Error).message}`;
  }

  let calendarWarning: string | null = null;
  try {
    if (provider === "gmail" && process.env.GOOGLE_CHANNEL_TOKEN) {
      const accessToken = await gmail.refreshAccessToken(refreshToken);
      const channelId = randomUUID();
      const { resourceId, expiration } = await googleCalendar.watchCalendar(
        accessToken,
        channelId,
        `${process.env.PUBLIC_BASE_URL}/api/calendar/googleWebhook`,
        process.env.GOOGLE_CHANNEL_TOKEN
      );
      await supabase
        .from("accounts")
        .update({
          calendar_channel_id: channelId,
          calendar_resource_id: resourceId,
          calendar_watch_expiration: new Date(Number(expiration)).toISOString(),
        })
        .eq("id", account.id);
    } else if (provider === "outlook") {
      const accessToken = await graph.refreshAccessToken(refreshToken);
      const notificationUrl = `${process.env.PUBLIC_BASE_URL}/api/calendar/graphWebhook`;
      const sub = await graphCalendar.createSubscription(accessToken, notificationUrl, process.env.GRAPH_CLIENT_STATE!);
      await supabase
        .from("accounts")
        .update({ calendar_subscription_id: sub.id, calendar_watch_expiration: sub.expirationDateTime })
        .eq("id", account.id);
    }
  } catch (err) {
    calendarWarning = `calendar push setup failed: ${(err as Error).message}`;
  }

  if (mailWarning || calendarWarning) {
    return res.status(207).json({ ok: true, accountId: account.id, warning: [mailWarning, calendarWarning].filter(Boolean).join("; ") });
  }
  return res.status(200).json({ ok: true, accountId: account.id });
}
