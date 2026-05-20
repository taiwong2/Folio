CREATE TABLE IF NOT EXISTS embedding_indexes (
  id          TEXT PRIMARY KEY,
  model_id    TEXT NOT NULL,
  dimension   INTEGER NOT NULL,
  created_at  TEXT DEFAULT CURRENT_TIMESTAMP,
  updated_at  TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS doc_chunk_vectors (
  chunk_id  TEXT NOT NULL,
  index_id  TEXT NOT NULL,
  dim       INTEGER NOT NULL,
  vec       BLOB    NOT NULL,
  PRIMARY KEY (chunk_id, index_id),
  FOREIGN KEY (chunk_id) REFERENCES doc_chunks(id) ON DELETE CASCADE,
  FOREIGN KEY (index_id) REFERENCES embedding_indexes(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_vectors_chunk_id ON doc_chunk_vectors(chunk_id);
CREATE INDEX IF NOT EXISTS idx_vectors_index_id ON doc_chunk_vectors(index_id);
