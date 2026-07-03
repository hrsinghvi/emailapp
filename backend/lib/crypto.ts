import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

// AES-256-GCM. Key is a 32-byte value, base64-encoded in ENCRYPTION_KEY.
// Stored format: base64(iv[12] || authTag[16] || ciphertext).
function key(): Buffer {
  const k = Buffer.from(process.env.ENCRYPTION_KEY!, "base64");
  if (k.length !== 32) throw new Error("ENCRYPTION_KEY must decode to 32 bytes");
  return k;
}

export function encrypt(plaintext: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key(), iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return Buffer.concat([iv, authTag, ciphertext]).toString("base64");
}

export function decrypt(stored: string): string {
  const raw = Buffer.from(stored, "base64");
  const iv = raw.subarray(0, 12);
  const authTag = raw.subarray(12, 28);
  const ciphertext = raw.subarray(28);
  const decipher = createDecipheriv("aes-256-gcm", key(), iv);
  decipher.setAuthTag(authTag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString("utf8");
}
