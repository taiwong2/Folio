CREATE INDEX IF NOT EXISTS idx_chunks_source ON doc_chunks(source_id);

CREATE INDEX IF NOT EXISTS idx_chunks_source_ordinal ON doc_chunks(source_id, ordinal);

CREATE INDEX IF NOT EXISTS idx_chunks_content_hash ON doc_chunks(content_hash);
