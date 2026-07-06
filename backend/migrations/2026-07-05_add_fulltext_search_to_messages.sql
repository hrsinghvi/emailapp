-- Applied directly via Supabase MCP (this project has no migration runner
-- yet) — kept here for reproducibility/history, not auto-applied.

-- Needed for the has:attachment search operator to work server-side too.
alter table messages add column if not exists has_attachments boolean not null default false;

-- Weighted so an exact subject match ranks above a sender-name match,
-- which ranks above a snippet-only match — ts_rank respects these weights.
alter table messages add column if not exists search_vector tsvector
  generated always as (
    setweight(to_tsvector('english', coalesce(subject, '')), 'A') ||
    setweight(to_tsvector('english', coalesce(sender_name, '')), 'B') ||
    setweight(to_tsvector('english', coalesce(snippet, '')), 'C')
  ) stored;

create index if not exists messages_search_vector_idx on messages using gin(search_vector);

-- websearch_to_tsquery (not plainto_tsquery) so stray punctuation/quotes in
-- real user search input doesn't throw a syntax error — it degrades
-- gracefully instead, same parser Google-style search boxes use.
create or replace function search_messages(
  p_query text,
  p_account_ids uuid[],
  p_limit int default 200
)
returns table(id uuid, rank real)
language sql
stable
as $$
  select m.id, ts_rank(m.search_vector, websearch_to_tsquery('english', p_query)) as rank
  from messages m
  where m.account_id = any(p_account_ids)
    and m.search_vector @@ websearch_to_tsquery('english', p_query)
  order by rank desc
  limit p_limit;
$$;
