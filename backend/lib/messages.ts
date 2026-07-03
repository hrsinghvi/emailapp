import { supabase } from "./supabase";
import { stableMessageId } from "./stableId";

export async function upsertMessage(params: {
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
}): Promise<void> {
  const { error } = await supabase.from("messages").upsert(
    {
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
      folder: "inbox",
    },
    { onConflict: "account_id,provider_message_id" }
  );
  if (error) throw error;
}
