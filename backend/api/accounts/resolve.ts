import type { VercelRequest, VercelResponse } from "@vercel/node";
import { supabase } from "../../lib/supabase";

/**
 * Resolves (provider, email) pairs to their real Supabase accounts.id —
 * called once per session by the Swift app and cached in memory, so every
 * search after the first skips this lookup entirely (search.ts accepts
 * pre-resolved accountIds directly). Without this, every single search
 * paid for 1-2 sequential "look up this account" round trips on top of the
 * actual search query, which is most of why search felt slow — the real
 * ts_rank query itself runs in ~2ms (see the migration's doc comment),
 * everything else was account-resolution overhead repeated on every
 * keystroke-triggered search instead of once per session.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).end();

  const { accounts: requested } = (req.body ?? {}) as {
    accounts?: Array<{ provider?: "gmail" | "outlook"; email?: string }>;
  };
  if (!Array.isArray(requested) || requested.length === 0) {
    return res.status(400).json({ error: "accounts required" });
  }

  const resolved = await Promise.all(
    requested.map(async ({ provider, email }) => {
      if (!provider || !email) return null;
      const { data } = await supabase.from("accounts").select("id").eq("provider", provider).ilike("email", email).single();
      return data ? { provider, email, id: data.id as string } : null;
    })
  );

  return res.status(200).json({ accounts: resolved.filter((a): a is NonNullable<typeof a> => a !== null) });
}
