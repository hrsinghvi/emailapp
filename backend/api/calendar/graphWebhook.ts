import type { VercelRequest, VercelResponse } from "@vercel/node";
import { supabase } from "../../lib/supabase";
import { decrypt } from "../../lib/crypto";
import * as graph from "../../lib/graph";
import * as graphCalendar from "../../lib/graphCalendar";
import { upsertEvent, deleteEvent } from "../../lib/events";

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const validationToken = req.query.validationToken;
  if (typeof validationToken === "string") {
    res.setHeader("Content-Type", "text/plain");
    return res.status(200).send(validationToken);
  }

  if (req.method !== "POST") return res.status(405).end();

  const body = req.body as {
    value?: { subscriptionId: string; clientState?: string; resource: string; changeType: string }[];
  };

  for (const notification of body.value ?? []) {
    if (notification.clientState !== process.env.GRAPH_CLIENT_STATE) continue;

    const { data: account } = await supabase
      .from("accounts")
      .select("*")
      .eq("provider", "outlook")
      .eq("calendar_subscription_id", notification.subscriptionId)
      .single();
    if (!account) continue;

    const eventId = notification.resource.split("/").pop();
    if (!eventId) continue;

    try {
      const refreshToken = decrypt(account.encrypted_refresh_token);
      const accessToken = await graph.refreshAccessToken(refreshToken);

      if (notification.changeType === "deleted") {
        await deleteEvent(account.id, eventId);
        continue;
      }

      const event = await graphCalendar.getEvent(accessToken, eventId);
      if (!event) {
        await deleteEvent(account.id, eventId);
        continue;
      }
      if (event.status === "cancelled") {
        await deleteEvent(account.id, event.providerEventId);
        continue;
      }
      await upsertEvent({
        accountId: account.id,
        provider: "outlook",
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
    } catch (err) {
      console.error("graph calendar webhook processing failed", err);
    }
  }

  return res.status(202).end();
}
