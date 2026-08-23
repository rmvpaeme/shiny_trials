-- ═══════════════════════════════════════════════════════════════════════════
-- The curation decision store
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Apply with:  psql "$CURATION_DB_URL" -f curation_app/sql/schema.sql
-- Idempotent: safe to re-run.
--
-- WHY POSTGRES AND NOT A FILE. The app is deployed multi-user on a read-only
-- filesystem. A CSV ledger cannot be written there, would be discarded on every
-- redeploy, and filelock does not span containers — worse, atomic rename makes
-- concurrent writers WORSE, because each one cleanly replaces the whole file
-- with its own stale copy. That is what retired the v1 reviewer app.
--
-- WHY TWO DECISION TABLES AND NOT ONE. They differ in key and in lifetime.
-- A normalisation decision is keyed on a RAW STRING, applies to every trial
-- carrying it, and outlives any individual trial. A trial decision is keyed on
-- (trial, field), applies to one trial, and dies with it — and trials genuinely
-- vanish: 5,438 EudraCT trials reappeared under a different country code
-- between two snapshots. One table would force a nullable _id, a nullable
-- raw_value, a field_id meaning two different things, and a CASE inside every
-- DISTINCT ON. That shape is what made the v1 app need 641 lines of dispatch.

CREATE TABLE IF NOT EXISTS reviewers (
  username       TEXT PRIMARY KEY,
  display_name   TEXT NOT NULL,
  email          TEXT,
  -- scrypt via sodium::password_store(), which emits a "$7$..." string
  -- (crypto_pwhash_scryptsalsa208sha256). Memory-hard and salted per call, so
  -- two reviewers with the same password get different hashes.
  --
  -- NOT argon2 and NOT bcrypt, whatever the planning notes said: sodium does
  -- not implement either. Verified by inspecting what password_store() returns
  -- rather than trusting the docs. If this ever moves to argon2 the column is
  -- unchanged, but password_verify() must move with it.
  -- Never a plaintext password, never a reversible encoding, never logged.
  password_hash  TEXT NOT NULL,
  role           TEXT NOT NULL DEFAULT 'reviewer'
                   CHECK (role IN ('reviewer','admin')),
  -- Removing a reviewer is `active = FALSE`, NEVER DELETE: both decision tables
  -- reference this row and their work has to survive them leaving.
  active         BOOLEAN NOT NULL DEFAULT TRUE,
  must_change_pw BOOLEAN NOT NULL DEFAULT TRUE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at  TIMESTAMPTZ
);

-- ── Tab 2: sponsor and substance queues. Keyed on the raw string. ───────────
CREATE TABLE IF NOT EXISTS norm_decisions (
  decision_id      BIGSERIAL PRIMARY KEY,
  domain           TEXT NOT NULL CHECK (domain IN ('sponsor','substance')),
  raw_value        TEXT NOT NULL,   -- = assignments.raw_sponsor / raw_substance
  -- not_a_substance is substance-only: that pipeline has a third match_status
  -- ('rejected') fed by the not-a-substance lists. Sponsors have no analogue.
  action           TEXT NOT NULL CHECK (action IN
                     ('accept','edit','reject','not_a_substance','skip')),
  entity_id_shown  TEXT,
  proposed         TEXT,            -- THE BEFORE VALUE. See the note below.
  final_canonical  TEXT,
  final_entity_id  TEXT,
  new_canonical    BOOLEAN NOT NULL DEFAULT FALSE,
  entity_type      TEXT,
  salt_form        TEXT,
  brand            TEXT,
  parent           TEXT,
  legal_entity     TEXT,
  n_trials_shown   INTEGER,         -- impact at decision time
  confidence_shown REAL,
  review_reason    TEXT,            -- why the pipeline queued it
  comment          TEXT,
  reviewer         TEXT NOT NULL REFERENCES reviewers(username),
  decided_at_utc   TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- PROVENANCE, NOT A RETRIEVAL KEY. `deploy` is force-pushed nightly, so this
  -- SHA becomes unreachable and is eventually garbage-collected. It records
  -- which published state the reviewer was looking at. Do not build anything
  -- that tries to fetch it back.
  snapshot_sha     TEXT NOT NULL,
  decision_ms      INTEGER,         -- time on the card; flags rubber-stamping
  app_version      TEXT
);

-- The DESC on decision_id is not cosmetic. Two reviewers deciding the same row
-- in the same millisecond would otherwise make latest-wins nondeterministic,
-- and export.R must be deterministic or its idempotence cannot be proven.
CREATE INDEX IF NOT EXISTS norm_decisions_latest_idx
  ON norm_decisions (domain, raw_value, decided_at_utc DESC, decision_id DESC);
CREATE INDEX IF NOT EXISTS norm_decisions_reviewer_idx
  ON norm_decisions (reviewer, decided_at_utc);
CREATE INDEX IF NOT EXISTS norm_decisions_action_idx
  ON norm_decisions (action);

-- ── Tab 1: trial validation. Keyed on (trial, field). ───────────────────────
CREATE TABLE IF NOT EXISTS trial_decisions (
  decision_id    BIGSERIAL PRIMARY KEY,
  trial_id       TEXT NOT NULL,   -- trials_cache.rds `_id`
  -- The `id` of an entry in curation_app/R/field_spec.R. That id is a permanent
  -- key: renaming one orphans every decision recorded against it.
  field_id       TEXT NOT NULL,
  action         TEXT NOT NULL CHECK (action IN ('validate','override','clear')),
  raw_shown      TEXT,
  norm_shown     TEXT,            -- THE BEFORE VALUE
  final_value    TEXT,
  -- The cache is typed. Casting from a bare string with no declared type is how
  -- "12" ends up in a numeric column.
  value_type     TEXT CHECK (value_type IS NULL OR value_type IN
                   ('character','numeric','integer','logical','date')),
  comment        TEXT,
  reviewer       TEXT NOT NULL REFERENCES reviewers(username),
  decided_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  snapshot_sha   TEXT NOT NULL,
  decision_ms    INTEGER,
  app_version    TEXT
);

CREATE INDEX IF NOT EXISTS trial_decisions_latest_idx
  ON trial_decisions (trial_id, field_id, decided_at_utc DESC, decision_id DESC);
CREATE INDEX IF NOT EXISTS trial_decisions_reviewer_idx
  ON trial_decisions (reviewer, decided_at_utc);
-- Drives tab 3's per-field change rate, the table that says which normalisation
-- is untrustworthy.
CREATE INDEX IF NOT EXISTS trial_decisions_field_idx
  ON trial_decisions (field_id, action);

-- Whole-trial sign-off, so tab 1 has a completion metric rather than only a
-- pile of individual field edits.
CREATE TABLE IF NOT EXISTS trial_reviews (
  review_id      BIGSERIAL PRIMARY KEY,
  trial_id       TEXT NOT NULL,
  status         TEXT NOT NULL CHECK (status IN ('validated','flagged','reopened')),
  comment        TEXT,
  reviewer       TEXT NOT NULL REFERENCES reviewers(username),
  decided_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  snapshot_sha   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS trial_reviews_latest_idx
  ON trial_reviews (trial_id, decided_at_utc DESC, review_id DESC);

-- Closes the loop. Without this the app cannot answer "is my decision live
-- yet?", which is the first thing a reviewer asks after their first decision.
CREATE TABLE IF NOT EXISTS export_runs (
  export_id             BIGSERIAL PRIMARY KEY,
  started_at_utc        TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at_utc       TIMESTAMPTZ,
  host                  TEXT,
  domain                TEXT CHECK (domain IS NULL OR domain IN
                          ('sponsor','substance','trial')),
  status                TEXT NOT NULL CHECK (status IN
                          ('running','ok','failed','skipped')),
  -- The high-water marks. Compared against max(decision_id) to show the lag.
  max_norm_decision_id  BIGINT,
  max_trial_decision_id BIGINT,
  n_sponsor_pins        INTEGER,
  n_substance_pins      INTEGER,
  n_new_entities        INTEGER,
  n_trial_overrides     INTEGER,
  message               TEXT
);
CREATE INDEX IF NOT EXISTS export_runs_recent_idx
  ON export_runs (started_at_utc DESC);

-- Every privileged write. Hiding a button is not access control, so the writes
-- that matter are recorded whether or not the UI offered them.
CREATE TABLE IF NOT EXISTS admin_audit (
  audit_id BIGSERIAL PRIMARY KEY,
  at_utc   TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor    TEXT NOT NULL REFERENCES reviewers(username),
  action   TEXT NOT NULL,
  target   TEXT,
  detail   JSONB
);
CREATE INDEX IF NOT EXISTS admin_audit_recent_idx
  ON admin_audit (at_utc DESC);

-- ── Latest-wins views ───────────────────────────────────────────────────────
--
-- Defined here rather than as strings in R so the app and export.R cannot drift
-- on the one rule that decides what reaches production.
--
-- 'skip' is excluded: it means "I am not deciding this now", which must leave
-- the row in the queue rather than becoming a decision that suppresses it.

CREATE OR REPLACE VIEW norm_decisions_latest AS
SELECT DISTINCT ON (domain, raw_value) *
FROM norm_decisions
WHERE action <> 'skip'
ORDER BY domain, raw_value, decided_at_utc DESC, decision_id DESC;

CREATE OR REPLACE VIEW trial_decisions_latest AS
SELECT DISTINCT ON (trial_id, field_id) *
FROM trial_decisions
ORDER BY trial_id, field_id, decided_at_utc DESC, decision_id DESC;

-- Disagreements. Last-write-wins is only safe if the loser is VISIBLE, so this
-- is not an optional reporting nicety — it is the entire safety net for the
-- conflict rule. If it is ever dropped or left unread, the rule silently
-- becomes "whoever clicked last was right".
CREATE OR REPLACE VIEW norm_disagreements AS
SELECT domain, raw_value,
       count(*)                          AS n_decisions,
       count(DISTINCT reviewer)          AS n_reviewers,
       count(DISTINCT COALESCE(final_canonical, '<reject>')) AS n_distinct_values,
       array_agg(DISTINCT reviewer)      AS reviewers,
       array_agg(DISTINCT COALESCE(final_canonical, '<reject>')) AS values_chosen,
       max(decided_at_utc)               AS last_decided_at
FROM norm_decisions
WHERE action <> 'skip'
GROUP BY domain, raw_value
HAVING count(DISTINCT reviewer) > 1
   AND count(DISTINCT COALESCE(final_canonical, '<reject>')) > 1;

CREATE OR REPLACE VIEW trial_disagreements AS
SELECT trial_id, field_id,
       count(*)                     AS n_decisions,
       count(DISTINCT reviewer)     AS n_reviewers,
       count(DISTINCT COALESCE(final_value, '<none>')) AS n_distinct_values,
       array_agg(DISTINCT reviewer) AS reviewers,
       max(decided_at_utc)          AS last_decided_at
FROM trial_decisions
GROUP BY trial_id, field_id
HAVING count(DISTINCT reviewer) > 1
   AND count(DISTINCT COALESCE(final_value, '<none>')) > 1;
