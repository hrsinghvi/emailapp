-- Documentation only — applied live via Supabase MCP's apply_migration.
--
-- websearch_to_tsquery stems and matches whole words only, so typing
-- "singhv" (not yet "singhvi") matched nothing even though the full name
-- was clearly what the user was typing toward — no different from Gmail's
-- own search-as-you-type expecting prefix matches while a word is still
-- incomplete. Replaces search_messages' query construction: each
-- whitespace-separated token is stripped to alphanumerics, lowercased, and
-- turned into a `token:*` prefix lexeme, joined with `&`, instead of running
-- the raw query through websearch_to_tsquery. Multi-word queries now all
-- match as prefixes rather than exact stemmed words — a deliberate tradeoff
-- for an incremental-search box, not a general-purpose query language.
create or replace function search_messages(
  p_query text, p_account_ids uuid[], p_limit int default 200
)
returns table(id uuid, rank real)
language sql stable
as $$
  with words as (
    select lower(regexp_replace(w, '[^a-zA-Z0-9]', '', 'g')) as w
    from unnest(regexp_split_to_array(trim(p_query), '\s+')) as w
  ),
  q as (
    select to_tsquery('english', string_agg(w || ':*', ' & ')) as tsq
    from words where w <> ''
  )
  select m.id, ts_rank(m.search_vector, q.tsq) as rank
  from messages m, q
  where m.account_id = any(p_account_ids)
    and m.search_vector @@ q.tsq
  order by rank desc
  limit p_limit;
$$;
