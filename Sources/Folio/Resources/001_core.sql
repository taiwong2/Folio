CREATE TABLE IF NOT EXISTS sources (
  id TEXT PRIMARY KEY,
  display_name TEXT,
  file_path TEXT,
  url TEXT,
  uti TEXT,
  file_type TEXT,
  pages INTEGER,
  chunks INTEGER,
  imported_at TEXT DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS doc_chunks (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL,
  page INTEGER,
  content TEXT NOT NULL,
  section_title TEXT,
  context_prefix TEXT,
  parent_id TEXT,
  content_hash TEXT NOT NULL,
  FOREIGN KEY(source_id) REFERENCES sources(id)
);
