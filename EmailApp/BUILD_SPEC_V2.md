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
- MCP server: the 11 tools, so Claude can reach your inbox from any chat regardless of whether the Mac app is running

Supabase is the shared source of truth both sides read/write: message metadata cache, categories, rules. Full message bodies never stored, fetched live.

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

create table categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  color text not null,
  is_system boolean default false,
  created_at timestamptz default now()
);

create table category_rules (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references categories(id) on delete cascade,
  match_type text not null check (match_type in ('sender_domain','sender_email','keyword')),
  match_value text not null
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
  category_id uuid references categories(id),
  provider_category text,
  folder text default 'inbox',
  unique(account_id, provider_message_id)
);

create index on messages (account_id, received_at desc);
create index on messages (category_id);
create index on messages (is_read) where is_read = false;
```

Note the change from v1: refresh token is the only token in Supabase, and it's the backend's copy for webhook/cron use. The Swift app's own access token lives in Keychain and never touches Supabase.

## OAuth

**Gmail**: new Cloud Console project. Enable Gmail API. OAuth consent: External, Testing, add self as test user. Client type: match to what Swift needs, i.e. a client ID usable with `ASWebAuthenticationSession` (still a "Web application" OAuth client on Google's side, the redirect URI is a custom URL scheme like `com.hritvik.unifiedinbox://oauth-callback` instead of localhost). Scopes: `gmail.readonly`, `gmail.send`, `gmail.labels`.

**Outlook**: reuse or redo the Azure app registration, redirect URI updated to the same custom URL scheme pattern. Scopes already proven working: `Mail.Read`, `Mail.Send`, `offline_access`, `openid`, `profile`.

Flow in Swift: `ASWebAuthenticationSession` opens the provider's consent page, callback comes back via custom URL scheme, app exchanges code for tokens, access token to Keychain, refresh token also sent to backend/Supabase (encrypted) so webhook renewal and MCP tools can use it independently of the Mac app being open.

## Sync

Webhooks, backend-side, same as before: Gmail Pub/Sub push + Graph change notifications, Vercel cron for renewal. Swift app polls Supabase for new metadata rows (simple realtime subscription via Supabase's realtime feature, or a lightweight timer, either works) rather than receiving webhooks directly, since the app isn't always running and can't hold a public endpoint anyway.

## Category rules engine

Same logic as v1: sender_domain / sender_email / keyword matching, first match wins, runs on every new message insert (backend-side, since that's where webhook-triggered inserts happen), bulk pass on first account sync.

## MCP server

Same 11 tools as v1, same signatures, still lives on the backend (Vercel), not in the Swift app, since Claude needs to reach it independent of whether your Mac app is open.

```typescript
get_recent_emails(account?: string, category?: string, limit = 20)
get_email_body(message_id: string)
search_emails(query: string, account?: string)
send_email(to: string[], subject: string, body: string, account: string)
reply_email(message_id: string, body: string)
archive_email(message_id: string)
mark_read(message_id: string, is_read: boolean)
list_categories()
create_category(name: string, color: string)
assign_category(message_id: string, category_id: string)
get_uncategorized_emails(limit = 50)
```

## Swift app structure

```
UnifiedInbox/
  UnifiedInboxApp.swift        -- @main entry point
  Models/
    Account.swift
    Message.swift
    Category.swift
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
    InboxViewModel.swift       -- @Observable, owns message list state, category filters
```

Dependencies via SPM: `supabase-swift` (official Supabase Swift client).

## Phase order

1. Xcode project scaffold, SPM deps added, basic three-pane SwiftUI shell with mock data (no backend yet, just prove the UI compiles and looks right)
2. Gmail OAuth via ASWebAuthenticationSession, Keychain token storage, direct Gmail API fetch, display real messages in the UI
3. Outlook OAuth, same pattern, merge into same list
4. Send / reply / archive / mark-read, both providers, direct from Swift
5. Backend: webhook receivers + cron renewal, Supabase realtime subscription wired into Swift app for near-live updates
6. Category rules engine (backend-side) + bulk first-sync pass
7. MCP server, all 11 tools
8. Polish pass: frosted materials via `.ultraThinMaterial`/`.regularMaterial`, matches the dark `#191919` + Notion-Mail-grouped-categories design locked earlier

## Required before start
- Xcode installed
- New Supabase project (old one discarded), URL + anon key + service role key
- Gmail Cloud Console client ID + secret (custom URL scheme redirect)
- Azure app client ID + secret (custom URL scheme redirect)
