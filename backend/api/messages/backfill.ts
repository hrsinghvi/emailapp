import type { VercelRequest, VercelResponse } from "@vercel/node";
import { supabase } from "../../lib/supabase";
import { upsertMessages } from "../../lib/messages";

/**
 * Bulk-indexes already-synced mail into Supabase's messages table for
 * Postgres full-text search — the regular sync path never routed message
 * content through here at all (only the realtime-webhook path did, for new
 * mail notifications), so full history has to be backfilled once. Called
 * by InboxViewModel's one-time search-index migration, chunked into
 * batches of a few hundred messages per request.
 *
 * Deliberately does NOT trust a client-supplied accountId: the Swift app's
 * local Account.id (deterministically hashed from provider+email, purely
 * for its own in-app bookkeeping) has no relationship to this table's
 * accounts.id (DB-generated at registration time) — sending it straight
 * through caused every message to collide with a different account's rows
 * on messages_pkey the moment their hashed message id happened to already
 * exist under a different (wrong) account_id. Resolving the real id from
 * (provider, email) server-side — the one thing both sides can agree on —
 * sidesteps the whole class of id-mismatch bugs.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).end();

  const { messages } = (req.body ?? {}) as {
    messages?: Array<{
      accountEmail?: string;
      provider?: "gmail" | "outlook";
      providerMessageId?: string;
      threadId?: string | null;
      messageIdHeader?: string | null;
      referencesHeader?: string | null;
      senderName?: string;
      senderEmail?: string;
      subject?: string;
      snippet?: string;
      body?: string;
      receivedAt?: string;
      isRead?: boolean;
      folder?: string;
      hasAttachments?: boolean;
    }>;
  };
  if (!Array.isArray(messages) || messages.length === 0) {
    return res.status(400).json({ error: "messages array required" });
  }

  const valid = messages.filter(
    (m): m is Required<Pick<typeof m, "accountEmail" | "provider" | "providerMessageId" | "senderName" | "senderEmail" | "subject" | "snippet" | "body" | "receivedAt" | "isRead">> & typeof m =>
      !!(m.accountEmail && m.provider && m.providerMessageId && m.receivedAt)
  );
  if (valid.length === 0) return res.status(400).json({ error: "no valid messages in batch" });

  // Resolve every distinct (provider, email) pair in this batch once,
  // rather than once per message — a batch is almost always 1-2 accounts.
  const accountKey = (provider: string, email: string) => `${provider}:${email.toLowerCase()}`;
  const uniquePairs = new Map<string, { provider: string; email: string }>();
  for (const m of valid) uniquePairs.set(accountKey(m.provider, m.accountEmail), { provider: m.provider, email: m.accountEmail });

  const accountIdByKey = new Map<string, string>();
  for (const { provider, email } of uniquePairs.values()) {
    const { data, error } = await supabase
      .from("accounts")
      .select("id")
      .eq("provider", provider)
      .ilike("email", email)
      .single();
    if (error || !data) {
      console.error("account lookup failed for backfill", provider, email, error);
      continue;
    }
    accountIdByKey.set(accountKey(provider, email), data.id);
  }

  const resolved = valid
    .map((m) => ({ ...m, accountId: accountIdByKey.get(accountKey(m.provider, m.accountEmail)) }))
    .filter((m): m is typeof m & { accountId: string } => !!m.accountId);
  if (resolved.length === 0) {
    return res.status(400).json({ error: "no messages matched a known account" });
  }

  try {
    await upsertMessages(
      resolved.map((m) => ({
        accountId: m.accountId,
        accountEmail: m.accountEmail!,
        provider: m.provider!,
        providerMessageId: m.providerMessageId!,
        threadId: m.threadId,
        messageIdHeader: m.messageIdHeader,
        referencesHeader: m.referencesHeader,
        senderName: m.senderName ?? "",
        senderEmail: m.senderEmail ?? "",
        subject: m.subject ?? "",
        snippet: m.snippet ?? "",
        body: m.body ?? "",
        receivedAt: m.receivedAt!,
        isRead: m.isRead ?? true,
        folder: m.folder,
        hasAttachments: m.hasAttachments,
      }))
    );
    return res.status(200).json({ indexed: resolved.length });
  } catch (err) {
    console.error("messages backfill failed", err);
    // Supabase's PostgrestError is a plain object with no useful toString —
    // String(err) on it was producing the useless "[object Object]".
    const message =
      err instanceof Error
        ? err.message
        : (err as { message?: string; details?: string; code?: string })?.message ??
          JSON.stringify(err);
    return res.status(500).json({ error: message });
  }
}
