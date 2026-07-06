-- Applied directly via Supabase MCP (this project has no migration runner
-- yet) — kept here for reproducibility/history, not auto-applied.

-- nomic-embed-text (run locally by the Mac app — see constraint 2 in the
-- semantic-search plan: Vercel can't reach localhost Ollama) produces
-- 768-dim vectors.
create extension if not exists vector;
alter table messages add column if not exists embedding vector(768);

-- HNSW over IVFFlat: no training/list-count tuning needed at this table
-- size, and cosine distance matches nomic-embed-text's intended metric.
create index if not exists messages_embedding_idx on messages using hnsw (embedding vector_cosine_ops);

create or replace function semantic_search_messages(
  p_embedding vector(768), p_account_ids uuid[], p_limit int default 30)
returns table(id uuid, similarity float) language sql stable as $$
  select m.id, 1 - (m.embedding <=> p_embedding) as similarity
  from messages m
  where m.embedding is not null and m.account_id = any(p_account_ids)
  order by m.embedding <=> p_embedding limit p_limit;
$$;

-- Batch embedding writes in one round trip instead of one UPDATE per row —
-- embeddings.ts's `store` action passes a jsonb array of {id, embedding}.
-- Plain `.update().eq()` in a loop would work too but this keeps a backfill
-- batch (up to 100 rows) as a single statement. Returns the updated row
-- count (not void) so the client's backfill loop can detect a silent
-- no-op — e.g. an id/cast mismatch — and stop instead of re-fetching the
-- same "pending" rows forever.
create or replace function store_embeddings(p_items jsonb)
returns integer language plpgsql as $$
declare
  updated_count integer;
begin
  update messages m
  set embedding = (item->>'embedding')::vector(768)
  from jsonb_array_elements(p_items) as item
  where m.id = (item->>'id')::uuid;
  get diagnostics updated_count = row_count;
  return updated_count;
end;
$$;
