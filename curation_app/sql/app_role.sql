-- A least-privilege role for the deployed app.
--
-- Apply with:  Rscript curation_app/apply_app_role.R
--
-- That script does not need psql — it runs these statements over DBI, creates
-- the role with a generated password, and prints the connection string once.
-- (psql works too, but the CREATE ROLE below has no password in it: the applier
-- supplies one, because a password committed to a .sql file is a password in
-- the repo.)
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

-- The role itself is created by apply_app_role.R, which supplies the password.
-- Everything below is the grant set, and is safe to re-run.

GRANT CONNECT ON DATABASE postgres TO curation_app;
GRANT USAGE   ON SCHEMA public     TO curation_app;

-- Append-only: the app writes decisions and reads them back, never deletes.
GRANT SELECT, INSERT ON norm_decisions, trial_decisions, trial_reviews,
                        export_runs, admin_audit, review_sample TO curation_app;
-- export.R closes out its own run row.
GRANT UPDATE ON export_runs TO curation_app;
GRANT USAGE  ON ALL SEQUENCES IN SCHEMA public TO curation_app;

-- Sign-in, and the admin panel's account management. No DELETE.
GRANT SELECT ON reviewers TO curation_app;
GRANT UPDATE (password_hash, must_change_pw, role, active, display_name,
              email, last_login_at) ON reviewers TO curation_app;
GRANT INSERT ON reviewers TO curation_app;   -- admin panel creates reviewers

GRANT SELECT ON norm_decisions_latest, trial_decisions_latest,
                norm_disagreements, trial_disagreements,
                review_sample_progress, review_sample_agreement TO curation_app;

-- Deliberately NOT granted: DELETE or TRUNCATE on anything, and any default
-- privilege on tables created later. A new table is unreachable until granted,
-- which is the safe direction.
