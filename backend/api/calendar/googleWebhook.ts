import type { VercelRequest, VercelResponse } from "@vercel/node";
import { supabase } from "../../lib/supabase";
import { decrypt } from "../../lib/crypto";
import * as gmail from "../../lib/gmail";
import * as googleCalendar from "../../lib/googleCalendar";
import { upsertEvent, deleteEvent } from "../../lib/events";

/**
 * Google Calendar's push notification carries no body — just headers
 * identifying the channel and a "sync" (handshake, ignore) or "exists"
 * (something changed, go fetch it) resource state. The actual changes are
 * then pulled via an incremental syncToken, same pattern Gmail uses via
 * historyId but for Calendar's own events.list endpoint.
 */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== "POST") return res.status(405).end();

  const channelId = req.headers["x-goog-channel-id"];
  const resourceState = req.headers["x-goog-resource-state"];
  const channelToken = req.headers["x-goog-channel-token"];

  if (typeof channelId !== "string" || channelToken !== process.env.GOOGLE_CHANNEL_TOKEN) {
    return res.status(401).end();
  }
  if (resourceState === "sync") {
    // Initial handshake when the channel is created — nothing changed yet.
    return res.status(200).end();
  }

  const { data: account } = await supabase
    .from("accounts")
    .select("*")
    .eq("provider", "gmail")
    .eq("calendar_channel_id", channelId)
    .single();
  if (!account) return res.status(200).end();

  try {
    const refreshToken = decrypt(account.encrypted_refresh_token);
    const accessToken = await gmail.refreshAccessToken(refreshToken);

    let result: Awaited<ReturnType<typeof googleCalendar.listChangedEvents>>;
    try {
      result = await googleCalendar.listChangedEvents(accessToken, account.calendar_sync_token ?? null);
    } catch {
      // Sync token expired (410) — re-establish from scratch.
      result = await googleCalendar.listChangedEvents(accessToken, null);
    }

    for (const event of result.events) {
      if (event.status === "cancelled") {
        await deleteEvent(account.id, event.providerEventId);
        continue;
      }
      await upsertEvent({
        accountId: account.id,
        provider: "gmail",
        providerEventId: event.providerEventId,
        calendarId: event.calendarId,
        title: event.title,
        description: event.description,
        location: event.location,
        startTime: event.startTime,
        endTime: event.endTime,
        allDay: event.allDay,
        recurrenceRule: event.recurrenceRule,
        attendees: event.attendees,
        htmlLink: event.htmlLink,
        status: event.status,
      });
    }

    await supabase.from("accounts").update({ calendar_sync_token: result.nextSyncToken }).eq("id", account.id);
  } catch (err) {
    console.error("google calendar webhook processing failed", err);
  }

  return res.status(200).end();
}
