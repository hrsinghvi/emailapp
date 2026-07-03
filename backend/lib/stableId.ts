import { createHash } from "node:crypto";

/**
 * Deterministic UUID from a provider message id — must match Swift's
 * `UUID(stableFrom:)` exactly (SHA256, first 16 bytes, raw byte order) so a
 * message fetched directly via the Gmail/Graph REST API and the same message
 * arriving later via this backend's webhook resolve to the identical id.
 * Without this, the two paths would collide as "different" messages.
 */
export function stableMessageId(providerMessageId: string): string {
  const hash = createHash("sha256").update(providerMessageId, "utf8").digest();
  const hex = hash.subarray(0, 16).toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}
