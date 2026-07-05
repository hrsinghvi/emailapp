const BASE = "https://graph.microsoft.com/v1.0/me";

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

/** Max lifetime for an events-resource subscription is ~4230 min, same as mail. */
export async function createSubscription(
  accessToken: string,
  notificationUrl: string,
  clientState: string
): Promise<{ id: string; expirationDateTime: string }> {
  const expirationDateTime = new Date(Date.now() + 4230 * 60 * 1000).toISOString();
  // /subscriptions is a top-level Graph resource, NOT nested under /me —
  // BASE (which includes /me for the /events endpoints below) doesn't
  // apply here. This mismatch is exactly why createSubscription was
  // getting a 405 while renewSubscription (already using the correct
  // top-level URL) would have worked fine.
  const res = await fetch("https://graph.microsoft.com/v1.0/subscriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      changeType: "created,updated,deleted",
      notificationUrl,
      resource: "me/events",
      expirationDateTime,
      clientState,
    }),
  });
  if (!res.ok) throw new Error(`Graph calendar subscription create failed (${res.status}): ${await res.text()}`);
  return (await res.json()) as { id: string; expirationDateTime: string };
}

export async function renewSubscription(
  accessToken: string,
  subscriptionId: string
): Promise<{ expirationDateTime: string }> {
  const expirationDateTime = new Date(Date.now() + 4230 * 60 * 1000).toISOString();
  const res = await fetch(`https://graph.microsoft.com/v1.0/subscriptions/${subscriptionId}`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ expirationDateTime }),
  });
  if (!res.ok) throw new Error(`Graph calendar subscription renew failed (${res.status}): ${await res.text()}`);
  return (await res.json()) as { expirationDateTime: string };
}

export async function getEvent(accessToken: string, id: string): Promise<ParsedCalendarEvent | null> {
  const res = await fetch(`${BASE}/events/${id}`, {
    headers: { Authorization: `Bearer ${accessToken}`, Prefer: 'outlook.timezone="UTC"' },
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Graph event get failed (${res.status}): ${await res.text()}`);
  return toParsedEvent((await res.json()) as RawEvent);
}

interface RawEvent {
  id: string;
  subject?: string;
  body?: { content?: string };
  location?: { displayName?: string };
  start?: { dateTime?: string };
  end?: { dateTime?: string };
  isAllDay?: boolean;
  isCancelled?: boolean;
  recurrence?: unknown;
  attendees?: { emailAddress: { address: string; name?: string }; status?: { response?: string } }[];
  webLink?: string;
}

function toParsedEvent(raw: RawEvent): ParsedCalendarEvent | null {
  const start = raw.start?.dateTime;
  const end = raw.end?.dateTime;
  if (!start || !end) return null;
  const withZ = (s: string) => (s.endsWith("Z") ? s : `${s}Z`);
  return {
    providerEventId: raw.id,
    calendarId: "primary",
    title: raw.subject ?? "(No title)",
    description: stripHtml(raw.body?.content ?? ""),
    location: raw.location?.displayName ?? "",
    startTime: new Date(withZ(start)).toISOString(),
    endTime: new Date(withZ(end)).toISOString(),
    allDay: raw.isAllDay ?? false,
    recurrenceRule: raw.recurrence ? "RECURRING" : null,
    attendees: (raw.attendees ?? []).map((a) => ({
      name: a.emailAddress.name ?? a.emailAddress.address,
      email: a.emailAddress.address,
      responseStatus: a.status?.response ?? "none",
    })),
    htmlLink: raw.webLink ?? null,
    status: raw.isCancelled ? "cancelled" : "confirmed",
  };
}

function stripHtml(html: string): string {
  return html.replace(/<[^>]+>/g, "").trim();
}
