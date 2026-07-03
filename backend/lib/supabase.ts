import { createClient } from "@supabase/supabase-js";

// Service-role client: bypasses RLS. Never expose this key client-side —
// it's read from Vercel env vars only, set directly in the dashboard.
export const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
  { auth: { persistSession: false } }
);
