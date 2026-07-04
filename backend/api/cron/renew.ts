import type { VercelRequest, VercelResponse } from "@vercel/node";
import { randomUUID } from "crypto";
import { supabase } from "../../lib/supabase";
import { decrypt } from "../../lib/crypto";
import * as gmail from "../../lib/gmail";
import * as graph from "../../lib/graph";
import * as googleCalendar from "../../lib/googleCalendar";
import * as graphCalendar from "../../lib/graphCalendar";

// Standard cron syntax can't express "every 6 days" / "every 2.5 days" —
// day-of-month steps reset each month and don't divide evenly into it. This
// runs daily instead and renews whatever's actually due, checked against
// each provider's real max lifetime (Gmail watch: 7 days, Graph mail
// subscription: ~2.94 days) minus a safety buffer. Same effective cadence,
// but correct even if a single cron run is delayed or skipped.
const GMAIL_RENEW_BUFFER_MS = 2 * 24 * 60 * 60 * 1000; // renew when <2 days remain
const GRAPH_RENEW_BUFFER_MS = 1 * 24 * 60 * 60 * 1000; // renew when <1 day remains

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (process.env.CRON_SECRET) {
    if (req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) {
      return res.status(401).end();
    }
  }

  const { data: accounts, error } = await supabase.from("accounts").select("*");
  if (error) return res.status(500).json({ error: error.message });

  const results: { email: string; provider: string; renewed: boolean; error?: string }[] = [];
  const now = Date.now();

  for (const account of accounts ?? []) {
    const buffer = account.provider === "gmail" ? GMAIL_RENEW_BUFFER_MS : GRAPH_RENEW_BUFFER_MS;
    const expiresAt = account.watch_expiration ? new Date(account.watch_expiration).getTime() : 0;
    if (expiresAt - now > buffer) continue; // not due yet

    try {
      const refreshToken = decrypt(account.encrypted_refresh_token);
      if (account.provider === "gmail") {
        const accessToken = await gmail.refreshAccessToken(refreshToken);
        const { expiration } = await gmail.watchInbox(accessToken);
        await supabase
          .from("accounts")
          .update({ watch_expiration: new Date(Number(expiration)).toISOString() })
          .eq("id", account.id);
      } else {
        const accessToken = await graph.refreshAccessToken(refreshToken);
        const { expirationDateTime } = await graph.renewSubscription(accessToken, account.subscription_id);
        await supabase.from("accounts").update({ watch_expiration: expirationDateTime }).eq("id", account.id);
      }
      results.push({ email: account.email, provider: account.provider, renewed: true });
    } catch (err) {
      results.push({
        email: account.email,
        provider: account.provider,
        renewed: false,
        error: (err as Error).message,
      });
    }

    // Calendar watches renew on the same daily pass, independent of the
    // mail watch above (different resource, different expiration column).
    const calendarExpiresAt = account.calendar_watch_expiration
      ? new Date(account.calendar_watch_expiration).getTime()
      : 0;
    if (calendarExpiresAt - now > buffer) continue;
    if (!process.env.PUBLIC_BASE_URL) continue;

    try {
      const refreshToken = decrypt(account.encrypted_refresh_token);
      if (account.provider === "gmail") {
        if (!process.env.GOOGLE_CHANNEL_TOKEN) continue;
        const accessToken = await gmail.refreshAccessToken(refreshToken);
        // Google can't renew a channel in place — a new one replaces it.
        const channelId = randomUUID();
        const { resourceId, expiration } = await googleCalendar.watchCalendar(
          accessToken,
          channelId,
          `${process.env.PUBLIC_BASE_URL}/api/calendar/googleWebhook`,
          process.env.GOOGLE_CHANNEL_TOKEN
        );
        if (account.calendar_channel_id && account.calendar_resource_id) {
          await googleCalendar.stopChannel(accessToken, account.calendar_channel_id, account.calendar_resource_id);
        }
        await supabase
          .from("accounts")
          .update({
            calendar_channel_id: channelId,
            calendar_resource_id: resourceId,
            calendar_watch_expiration: new Date(Number(expiration)).toISOString(),
          })
          .eq("id", account.id);
      } else {
        if (!account.calendar_subscription_id) continue;
        const accessToken = await graph.refreshAccessToken(refreshToken);
        const { expirationDateTime } = await graphCalendar.renewSubscription(
          accessToken,
          account.calendar_subscription_id
        );
        await supabase
          .from("accounts")
          .update({ calendar_watch_expiration: expirationDateTime })
          .eq("id", account.id);
      }
      results.push({ email: account.email, provider: `${account.provider}-calendar`, renewed: true });
    } catch (err) {
      results.push({
        email: account.email,
        provider: `${account.provider}-calendar`,
        renewed: false,
        error: (err as Error).message,
      });
    }
  }

  return res.status(200).json({ checked: accounts?.length ?? 0, results });
}
