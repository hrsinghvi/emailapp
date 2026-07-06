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
 * Takes (provider, email) pairs, not accountIds — see backfill.ts's doc
 * comment for why a client-supplied accountId isn't trustworthy here (the
 * Swift app's local Account.id has no relationship to this table's
 * DB-generated accounts.id).
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).end();

  const { query, accounts: requestedAccounts, limit } = (req.body ?? {}) as {
    query?: string;
    accounts?: Array<{ provider?: "gmail" | "outlook"; email?: string }>;
    limit?: number;
  };
  if (!query || !query.trim() || !Array.isArray(requestedAccounts) || requestedAccounts.length === 0) {
    return res.status(400).json({ error: "query and accounts required" });
  }

  const accountIds: string[] = [];
  for (const { provider, email } of requestedAccounts) {
    if (!provider || !email) continue;
    const { data } = await supabase.from("accounts").select("id").eq("provider", provider).ilike("email", email).single();
    if (data) accountIds.push(data.id);
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
