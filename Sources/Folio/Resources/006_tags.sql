CREATE TABLE IF NOT EXISTS source_tags (
  source_id TEXT NOT NULL,
  tag       TEXT NOT NULL,
  PRIMARY KEY (source_id, tag),
  FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_source_tags_tag ON source_tags(tag);
