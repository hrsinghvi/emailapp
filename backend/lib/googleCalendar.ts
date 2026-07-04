const BASE = "https://www.googleapis.com/calendar/v3/calendars/primary/events";

export interface ParsedCalendarEvent {
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

/**
 * Registers a push channel for primary-calendar changes. Google's calendar
 * watch is a plain HTTPS webhook (unlike Gmail's Pub/Sub) — max lifetime is
 * ~30 days, renewed by the same daily cron that renews mail watches.
 */
export async function watchCalendar(
  accessToken: string,
  channelId: string,
  webhookUrl: string,
  clientToken: string
): Promise<{ resourceId: string; expiration: string }> {
  const res = await fetch(`${BASE}/watch`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ id: channelId, type: "web_hook", address: webhookUrl, token: clientToken }),
  });
  if (!res.ok) throw new Error(`Calendar watch failed (${res.status}): ${await res.text()}`);
  const json = (await res.json()) as { resourceId: string; expiration: string };
  return json;
}

export async function stopChannel(accessToken: string, channelId: string, resourceId: string): Promise<void> {
  await fetch("https://www.googleapis.com/calendar/v3/channels/stop", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ id: channelId, resourceId }),
  });
}

/**
 * Incremental sync via syncToken — on first call (no token yet), does a
 * full list scoped to a wide time window and returns the syncToken that
 * comes back once every page has been walked, per Google's documented
 * pattern for establishing an initial sync cursor.
 */
export async function listChangedEvents(
  accessToken: string,
  syncToken: string | null
): Promise<{ events: ParsedCalendarEvent[]; nextSyncToken: string }> {
  const events: ParsedCalendarEvent[] = [];
  let pageToken: string | undefined;
  let nextSyncToken = "";

  do {
    const params = new URLSearchParams({ maxResults: "250", singleEvents: "true" });
    if (syncToken) {
      params.set("syncToken", syncToken);
    } else {
      params.set("timeMin", new Date(Date.now() - 30 * 86400 * 1000).toISOString());
      params.set("timeMax", new Date(Date.now() + 365 * 86400 * 1000).toISOString());
    }
    if (pageToken) params.set("pageToken", pageToken);

    const res = await fetch(`${BASE}?${params.toString()}`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!res.ok) {
      // 410 Gone means the sync token expired — caller should retry with
      // syncToken=null to re-establish a fresh one.
      throw new Error(`Calendar list failed (${res.status}): ${await res.text()}`);
    }
    const json = (await res.json()) as {
      items: RawEvent[];
      nextPageToken?: string;
      nextSyncToken?: string;
    };
    events.push(...json.items.map(toParsedEvent).filter((e): e is ParsedCalendarEvent => e !== null));
    pageToken = json.nextPageToken;
    if (json.nextSyncToken) nextSyncToken = json.nextSyncToken;
  } while (pageToken);

  return { events, nextSyncToken };
}

interface RawEvent {
  id: string;
  status?: string;
  summary?: string;
  description?: string;
  location?: string;
  start?: { date?: string; dateTime?: string };
  end?: { date?: string; dateTime?: string };
  recurrence?: string[];
  attendees?: { displayName?: string; email: string; responseStatus?: string }[];
  htmlLink?: string;
}

function toParsedEvent(raw: RawEvent): ParsedCalendarEvent | null {
  const start = raw.start?.dateTime ?? raw.start?.date;
  const end = raw.end?.dateTime ?? raw.end?.date;
  if (!start || !end) return null;
  const allDay = !!raw.start?.date;
  return {
    providerEventId: raw.id,
    calendarId: "primary",
    title: raw.summary ?? "(No title)",
    description: raw.description ?? "",
    location: raw.location ?? "",
    startTime: allDay ? new Date(`${start}T00:00:00Z`).toISOString() : new Date(start).toISOString(),
    endTime: allDay ? new Date(`${end}T00:00:00Z`).toISOString() : new Date(end).toISOString(),
    allDay,
    recurrenceRule: raw.recurrence?.[0] ?? null,
    attendees: (raw.attendees ?? []).map((a) => ({
      name: a.displayName ?? a.email,
      email: a.email,
      responseStatus: a.responseStatus ?? "needsAction",
    })),
    htmlLink: raw.htmlLink ?? null,
    status: raw.status ?? "confirmed",
  };
}
