-- A least-privilege role for the deployed app.
--
-- Apply as the superuser:  psql "$CURATION_DB_URL" -f curation_app/sql/app_role.sql
-- Then use THIS role's connection string in the app.
--
-- ── WHY ───────────────────────────────────────────────────────────────────────
--
-- The app's connection string reaches Posit one way or another — as a platform
-- environment variable if the target supports one, otherwise inside the deploy
-- bundle. Either way it is worth assuming it can be read by someone who should
-- not have it.
--
-- What matters then is what the credential can DO. `postgres` is the superuser:
-- it can read every password hash in `reviewers`, drop tables, and disable the
-- audit trail that would show it happened. This role cannot.
--
--   * INSERT and SELECT on the decision tables — the app appends and reads back.
--   * NO DELETE, NO TRUNCATE anywhere. Decisions are append-only by design and
--     the app has no legitimate reason to remove one; export.R reads, it does
--     not prune.
--   * SELECT plus a narrow UPDATE on `reviewers` — enough to sign in and for an
--     admin to change a password, role or active flag. NOT DELETE: accounts are
--     deactivated, never removed, because decisions reference them.
--   * No rights on anything else in the schema, and none by default on tables
--     added later.
--
-- Set the password to something long and unrelated to the superuser's.

\set app_password 'CHANGE-ME-a-long-random-string'

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'curation_app') THEN
    CREATE ROLE curation_app LOGIN PASSWORD :'app_password';
  END IF;
END
$$;

GRANT CONNECT ON DATABASE postgres TO curation_app;
GRANT USAGE   ON SCHEMA public     TO curation_app;

-- Append-only: the app writes decisions and reads them back, never deletes.
GRANT SELECT, INSERT ON norm_decisions, trial_decisions, trial_reviews,
                        export_runs, admin_audit TO curation_app;
-- export.R closes out its own run row.
GRANT UPDATE ON export_runs TO curation_app;
GRANT USAGE  ON ALL SEQUENCES IN SCHEMA public TO curation_app;

-- Sign-in, and the admin panel's account management. No DELETE.
GRANT SELECT ON reviewers TO curation_app;
GRANT UPDATE (password_hash, must_change_pw, role, active, display_name,
              email, last_login_at) ON reviewers TO curation_app;
GRANT INSERT ON reviewers TO curation_app;   -- admin panel creates reviewers

GRANT SELECT ON norm_decisions_latest, trial_decisions_latest,
                norm_disagreements, trial_disagreements TO curation_app;

-- Deliberately NOT granted: DELETE or TRUNCATE on anything, and any default
-- privilege on tables created later. A new table is unreachable until granted,
-- which is the safe direction.
