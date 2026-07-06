import type { VercelRequest, VercelResponse } from "@vercel/node";
import { supabase } from "../../lib/supabase";

/**
 * Real Postgres full-text search (tsvector/tsquery + ts_rank against the
 * GIN-indexed search_vector column — see the add_fulltext_search_to_messages
 * migration) instead of client-side substring matching. Returns ranked
 * (id, rank) pairs only, not full message bodies — InboxViewModel already
 * has the full message content cached locally and just needs to know
 * which ids matched and in what order.
 *
 * Prefers a pre-resolved `accountIds` (real Supabase accounts.id, from
 * api/accounts/resolve.ts, cached client-side for the session) — that's
 * the fast path with zero lookup overhead. Falls back to resolving
 * `accounts` (provider, email) pairs server-side for a client that hasn't
 * resolved yet. Never trusts a client-supplied id blindly for WRITES (see
 * backfill.ts's doc comment on why the Swift app's local Account.id isn't
 * trustworthy there) — but this endpoint is read-only, so a stale/wrong
 * cached id here only means a search returns nothing, not a data
 * integrity problem, which is an acceptable tradeoff for cutting this
 * endpoint's own latency to just the search query itself.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).end();

  const { query, accountIds: providedIds, accounts: requestedAccounts, limit } = (req.body ?? {}) as {
    query?: string;
    accountIds?: string[];
    accounts?: Array<{ provider?: "gmail" | "outlook"; email?: string }>;
    limit?: number;
  };
  if (!query || !query.trim()) {
    return res.status(400).json({ error: "query required" });
  }

  let accountIds: string[] = Array.isArray(providedIds) ? providedIds.filter((id) => !!id) : [];
  if (accountIds.length === 0) {
    if (!Array.isArray(requestedAccounts) || requestedAccounts.length === 0) {
      return res.status(400).json({ error: "accountIds or accounts required" });
    }
    const resolved = await Promise.all(
      requestedAccounts.map(async ({ provider, email }) => {
        if (!provider || !email) return null;
        const { data } = await supabase.from("accounts").select("id").eq("provider", provider).ilike("email", email).single();
        return data?.id as string | undefined;
      })
    );
    accountIds = resolved.filter((id): id is string => !!id);
  }
  if (accountIds.length === 0) return res.status(200).json({ results: [] });

  const { data, error } = await supabase.rpc("search_messages", {
    p_query: query,
    p_account_ids: accountIds,
    p_limit: Math.min(limit ?? 200, 500),
  });
  if (error) {
    console.error("search_messages rpc failed", error);
    return res.status(500).json({ error: String(error.message ?? error) });
  }
  return res.status(200).json({ results: data ?? [] });
}
