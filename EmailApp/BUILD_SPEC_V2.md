# Unified Inbox — Build Spec v2 (Swift)

Native macOS app, Gmail + UIUC Outlook, single user, no login screen. Learning-oriented build: Claude Code should explain non-trivial Swift/SwiftUI patterns as it writes them, not just produce code silently.

## Architecture

Two pieces, split by what actually requires a public endpoint vs what doesn't.

**SwiftUI app (macOS 14+)** — does everything that doesn't need to be publicly reachable:
- UI, all views
- OAuth flow (ASWebAuthenticationSession for the browser consent step)
- Direct Gmail API / Graph API calls for read, send, archive, mark-read, search
- Local token storage in Keychain (not Supabase, not a file, actual macOS Keychain)
- Reads/writes Supabase for message metadata cache

**Thin backend (Node/TS on Vercel)** — only for what requires a public HTTPS endpoint or has to run when the Mac app isn't open:
- Webhook receivers: Gmail Pub/Sub push, Graph change notifications
- Cron jobs: webhook subscription renewal (Gmail every 6 days, Outlook every 2.5 days)
- MCP server: tools so Claude can reach your inbox from any chat regardless of whether the Mac app is running

Supabase is the shared source of truth both sides read/write: message metadata cache. Full message bodies never stored, fetched live.

## Supabase

Use the Supabase MCP for all Supabase work: schema setup, migrations, queries, RLS policies. Don't hand-write SQL through raw client calls when the MCP can do it.

## Data model (Supabase Postgres)

```sql
create table accounts (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('gmail','outlook')),
  email text not null,
  refresh_token text not null, -- encrypted via pgsodium. access token stays local in Keychain, never leaves the Mac.
  webhook_subscription_id text,
  webhook_expires_at timestamptz,
  created_at timestamptz default now()
);

create table messages (
  id uuid primary key default gen_random_uuid(),
  account_id uuid references accounts(id) on delete cascade,
  provider_message_id text not null,
  thread_id text,
  sender_name text,
  sender_email text,
  subject text,
  snippet text,
  received_at timestamptz not null,
  is_read boolean default false,
  is_archived boolean default false,
  provider_category text, -- gmail: primary/promotions/social/updates | outlook: focused/other
  folder text default 'inbox',
  unique(account_id, provider_message_id)
);

create index on messages (account_id, received_at desc);
create index on messages (is_read) where is_read = false;
```

Note the change from v1: refresh token is the only token in Supabase, and it's the backend's copy for webhook/cron use. The Swift app's own access token lives in Keychain and never touches Supabase.

No custom category system. Organization is provider-native tabs only (Gmail Primary/Promotions/Social/Updates, Outlook Focused/Other), no user-defined categories, no rules engine.

## OAuth

**Gmail**: Cloud Console project. Gmail API enabled. OAuth consent: External, Testing, self as test user. Client type: iOS (native/public client, PKCE, no secret). Scopes: `gmail.readonly`, `gmail.send`, `gmail.labels`.

**Outlook**: Azure app, public client/native redirect type, PKCE, no secret used client-side. Scopes: `Mail.Read`, `Mail.Send`, `offline_access`, `openid`, `profile`.

Flow in Swift: `ASWebAuthenticationSession` opens the provider's consent page, callback comes back via custom URL scheme, app exchanges code for tokens, access token to Keychain, refresh token also sent to backend/Supabase (encrypted) so webhook renewal and MCP tools can use it independently of the Mac app being open. Silent refresh on launch using stored refresh token before ever showing the OAuth screen again.

## Sync

Webhooks, backend-side: Gmail Pub/Sub push + Graph change notifications, Vercel cron for renewal. Swift app subscribes to Supabase realtime for new message rows, not polling.

## MCP server

Lives on the backend (Vercel), not the Swift app, since Claude needs to reach it independent of whether the Mac app is open.

```typescript
get_recent_emails(account?: string, limit = 20)
get_email_body(message_id: string)
search_emails(query: string, account?: string)
send_email(to: string[], subject: string, body: string, account: string)
reply_email(message_id: string, body: string)
archive_email(message_id: string)
mark_read(message_id: string, is_read: boolean)
```

## Swift app structure

```
UnifiedInbox/
  UnifiedInboxApp.swift        -- @main entry point
  Models/
    Account.swift
    Message.swift
  Services/
    SupabaseClient.swift       -- wraps supabase-swift
    GmailAPI.swift             -- direct Gmail REST calls
    GraphAPI.swift             -- direct MS Graph REST calls
    OAuthManager.swift         -- ASWebAuthenticationSession flows for both providers
    KeychainService.swift      -- token storage/retrieval
  Views/
    ContentView.swift          -- three-pane root layout
    SidebarView.swift
    MessageListView.swift
    ReadingPaneView.swift
    ComposeView.swift
  ViewModels/
    InboxViewModel.swift       -- @Observable, owns message list state
```

Dependencies via SPM: `supabase-swift`.

## Phase order

1. Xcode project scaffold, SPM deps, basic three-pane SwiftUI shell with mock data — done
2. Gmail OAuth, Keychain, real fetch — done
3. Outlook OAuth, merged into same list — done
4. Send / reply / archive / mark-read, both providers — done
5. Backend webhooks + cron + Supabase realtime — done
6. MCP server, tools above
7. Polish pass: frosted materials via `.ultraThinMaterial`/`.regularMaterial`, dark `#191919` base, provider-colored left borders on list rows (Gmail coral, Outlook blue)

## Required before start
- Xcode installed
- Supabase project, URL + anon key + service role key
- Gmail Cloud Console client ID (public client, no secret)
- Azure app client ID (public client, no secret)
