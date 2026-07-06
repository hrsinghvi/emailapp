import { supabase } from "./supabase";
import { stableMessageId } from "./stableId";

interface MessageParams {
  accountId: string;
  accountEmail: string;
  provider: "gmail" | "outlook";
  providerMessageId: string;
  threadId?: string | null;
  messageIdHeader?: string | null;
  referencesHeader?: string | null;
  senderName: string;
  senderEmail: string;
  subject: string;
  snippet: string;
  body: string;
  receivedAt: string;
  isRead: boolean;
  folder?: string;
  hasAttachments?: boolean;
}

function toRow(params: MessageParams) {
  return {
    id: stableMessageId(params.providerMessageId),
    account_id: params.accountId,
    account_email: params.accountEmail,
    provider: params.provider,
    provider_message_id: params.providerMessageId,
    thread_id: params.threadId ?? null,
    message_id_header: params.messageIdHeader ?? null,
    references_header: params.referencesHeader ?? null,
    sender_name: params.senderName,
    sender_email: params.senderEmail,
    subject: params.subject,
    snippet: params.snippet,
    body: params.body,
    received_at: params.receivedAt,
    is_read: params.isRead,
    folder: params.folder ?? "inbox",
    has_attachments: params.hasAttachments ?? false,
  };
}

export async function upsertMessage(params: MessageParams): Promise<void> {
  const { error } = await supabase
    .from("messages")
    .upsert(toRow(params), { onConflict: "account_id,provider_message_id" });
  if (error) throw error;
}

/// Bulk variant for the search-index backfill (InboxViewModel calls this
/// with up to a few hundred messages per request, chunked client-side) —
/// one upsert call instead of one round trip per message.
export async function upsertMessages(paramsList: MessageParams[]): Promise<void> {
  if (paramsList.length === 0) return;
  const { error } = await supabase
    .from("messages")
    .upsert(paramsList.map(toRow), { onConflict: "account_id,provider_message_id" });
  if (error) throw error;
}
