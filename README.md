# Threadwell

A native macOS email client that unifies Gmail and Outlook into one inbox, with local AI features (Ollama) that never send your mail to a third-party API.

## Features

**Unified inbox**
- Connect multiple Gmail and Outlook accounts, browse them together or filtered by provider
- Gmail-style category tabs (Primary, Social, Promotions, Updates, Forums) computed locally
- Full-text search across all mail (not scoped to whatever folder/category you're currently in), with recent searches and quick filters
- Colored "new mail" badges in the sidebar — count of mail that's arrived since you last clicked into that Inbox/Gmail/Outlook/category, distinct from an unread count
- Keyboard shortcuts for every sidebar destination (Cmd+1-5 for Inbox/Promotions/Social/Updates/Forums, Cmd+G/Cmd+O for Gmail/Outlook, Cmd+T for Trash, Cmd+D for Drafts)

**Organizing mail**
- Right-click context menu: reply/reply all/forward, archive/delete/mark unread, star/mark important, move to any folder or category, ask AI about the email
- Drag and drop (single or multi-select) onto any sidebar destination — drop on a category to move mail there, drop on Starred/Important to flag without moving, with an undo toast after every move
- Per-message actions inside a thread (reply/forward/delete/mark unread from here), not just per-thread
- 8-second Undo Send window before anything actually transmits

**Compose**
- Up to 3 compose windows open simultaneously — replying to something no longer replaces whatever you were already writing. Each is independently minimizable (Escape or the minus button) and everything sends the same rules Gmail does about how many can be open at once
- Rich text editor (bold/italic/underline/strikethrough, lists, alignment, headings, blockquotes, links) built on TextKit, not a web view
- Paste or insert images inline, with Gmail-style resize handles and size presets (Small/Best fit/Original size/Remove) — images flow with surrounding text like any other character
- Live markdown shortcuts (`**bold**`, `# heading`, `- list`, etc.) as you type
- Ghost-text autocomplete (local Ollama) that only becomes real text once you press Tab

**AI, entirely local**
- Ask AI about the open thread, one-shot thread summaries, "Draft with AI" (and "Change with AI" to revise an existing AI draft), and one-tap rewrite icons (polish/formalize/friendly/shorten)
- All generation runs against a local Ollama instance (qwen2.5) — nothing about the content of your email ever leaves your Mac
- Optional web search grounding (Tavily) for requests that need current facts — off by default, requires your own API key, and is the one exception to "nothing leaves your Mac"
- An MCP (Model Context Protocol) server lets Claude read/search/send mail directly, with an in-app approval flow for anything that sends or modifies data

**Reliability**
- Offline queue — actions taken while offline (archive, delete, send, etc.) replay automatically once back online
- Realtime sync via Supabase, with a healing pass that catches anything a placeholder row missed
- Rate-limit-aware request throttling and retry against both Gmail and Graph APIs

## Architecture

- **`EmailApp/`** — the macOS app (SwiftUI + AppKit interop for the rich text editor), talking directly to the Gmail API and Microsoft Graph API for mail operations, and to Ollama on `localhost:11434` for AI features.
- **`backend/`** — a small Vercel-hosted Node/TypeScript backend (Supabase for auth/storage/realtime, an MCP endpoint for Claude integration, and OAuth token handling). The backend never sees message *content* for AI features — that's Ollama, running entirely on-device.

## Requirements

- macOS (Apple Silicon)
- [Ollama](https://ollama.com) running locally with the `qwen2.5:7b` and `nomic-embed-text` models pulled, for AI features
- A Gmail and/or Outlook account to connect

## Building

Open `EmailApp/EmailApp.xcodeproj` in Xcode and build the `EmailApp` scheme (Debug or Release). The build product is `Threadwell.app`.
