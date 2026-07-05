import type { VercelRequest, VercelResponse } from "@vercel/node";
import { supabase } from "../../lib/supabase";
import { decrypt } from "../../lib/crypto";
import * as gmail from "../../lib/gmail";
import * as graph from "../../lib/graph";

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
  }

  return res.status(200).json({ checked: accounts?.length ?? 0, results });
}
