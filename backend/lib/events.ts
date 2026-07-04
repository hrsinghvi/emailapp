import { supabase } from "./supabase";

export interface UpsertEventParams {
  accountId: string;
  provider: "gmail" | "outlook";
  providerEventId: string;
  calendarId: string;
  title: string;
  description: string;
  location: string;
  startTime: string;
  endTime: string;
  allDay: boolean;
  recurrenceRule: string | null;
  attendees: { name: string; email: string; responseStatus: string }[];
  htmlLink: string | null;
  status: string;
}

export async function upsertEvent(params: UpsertEventParams): Promise<void> {
  const { error } = await supabase.from("events").upsert(
    {
      account_id: params.accountId,
      provider: params.provider,
      provider_event_id: params.providerEventId,
      calendar_id: params.calendarId,
      title: params.title,
      description: params.description,
      location: params.location,
      start_time: params.startTime,
      end_time: params.endTime,
      all_day: params.allDay,
      recurrence_rule: params.recurrenceRule,
      attendees: params.attendees,
      html_link: params.htmlLink,
      status: params.status,
      updated_at: new Date().toISOString(),
    },
    { onConflict: "account_id,provider_event_id" }
  );
  if (error) throw error;
}

export async function deleteEvent(accountId: string, providerEventId: string): Promise<void> {
  const { error } = await supabase
    .from("events")
    .delete()
    .eq("account_id", accountId)
    .eq("provider_event_id", providerEventId);
  if (error) throw error;
}
