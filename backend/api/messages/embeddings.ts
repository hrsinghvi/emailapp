import type { VercelRequest, VercelResponse } from "@vercel/node";
import { supabase } from "../../lib/supabase";

/**
 * Feeds the Mac app's local Ollama backfill loop: `pending` hands back rows
 * still missing an embedding (truncated body — the full body never needs
 * to leave the client, and nomic-embed-text's context window is small
 * anyway); `store` writes the vectors back once the app computes them
 * locally. The backend itself never calls Ollama — see the plan's
 * constraint 2, Vercel can't reach localhost.
 *
 * `pending` is read-only, so (like search.ts, not backfill.ts) it accepts
 * pre-resolved `accountIds` — a stale/wrong cached id here just means the
 * backfill loop finds nothing to do this round, not a data-integrity
 * problem. `store` never needs account resolution at all: it updates rows
 * by the same `id` `pending` already returned, which came straight out of
 * this table.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).end();

  const { action } = (req.body ?? {}) as { action?: "pending" | "store" };

  if (action === "pending") {
    const { accountIds, limit } = (req.body ?? {}) as { accountIds?: string[]; limit?: number };
    if (!Array.isArray(accountIds) || accountIds.length === 0) {
      return res.status(400).json({ error: "accountIds required" });
    }
    const { data, error } = await supabase
      .from("messages")
      .select("id, subject, snippet, sender_name, body")
      .in("account_id", accountIds)
      .is("embedding", null)
      .limit(Math.min(limit ?? 100, 500));
    if (error) {
      console.error("embeddings pending query failed", error);
      return res.status(500).json({ error: String(error.message ?? error) });
    }
    const items = (data ?? []).map((row) => ({
      id: row.id,
      subject: row.subject,
      snippet: row.snippet,
      sender_name: row.sender_name,
      // Truncated server-side so the app never has to think about it —
      // nomic-embed-text's 2048-token context window is well under what a
      // long email body would be anyway.
      body: (row.body ?? "").slice(0, 2000),
    }));
    return res.status(200).json({ items });
  }

  if (action === "store") {
    const { items } = (req.body ?? {}) as { items?: Array<{ id?: string; embedding?: number[] }> };
    const valid = (items ?? []).filter(
      (i): i is { id: string; embedding: number[] } =>
        !!i.id && Array.isArray(i.embedding) && i.embedding.length === 768
    );
    if (valid.length === 0) return res.status(400).json({ error: "no valid items to store" });

    const { data, error } = await supabase.rpc("store_embeddings", {
      p_items: valid.map((i) => ({ id: i.id, embedding: i.embedding })),
    });
    if (error) {
      console.error("store_embeddings rpc failed", error);
      return res.status(500).json({ error: String(error.message ?? error) });
    }
    // `data` is the actual updated-row count (get diagnostics row_count in
    // the RPC) — not just valid.length — so the client's backfill loop can
    // tell a silent id/cast mismatch apart from a real success.
    return res.status(200).json({ stored: data ?? 0 });
  }

  return res.status(400).json({ error: "action must be 'pending' or 'store'" });
}
