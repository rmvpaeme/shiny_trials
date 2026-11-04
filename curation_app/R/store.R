# ══════════════════════════════════════════════════════════════════════════════
# THE DECISION STORE
# ══════════════════════════════════════════════════════════════════════════════
#
# Every reviewer decision goes here and nowhere else. The app never writes to
# the pipeline's CSVs — there is no shared filesystem between Posit and the
# server, and a second writer racing N_nightly_resolve.R would recreate exactly
# the read-modify-write race that retired the v1 reviewer app. curation_app's
# export.R is the single writer, and it runs on the server inside the nightly.
#
# ── Credentials ───────────────────────────────────────────────────────────────
#
# CURATION_DB_URL only, from the environment. Never a literal in source (there
# is a test for that), never written to a log, never included in an error
# message. Everything below reports the HOST when it needs to say where it was
# talking to, because the host is not a secret and the URL is.

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

curation_db_config <- function(url = Sys.getenv("CURATION_DB_URL")) {
  if (!nzchar(url)) return(NULL)
  u <- httr::parse_url(url)
  list(host     = u$hostname,
       port     = as.integer(u$port %||% 5432L),
       dbname   = sub("^/", "", u$path %||% "postgres"),
       user     = u$username,
       password = u$password,
       # Supabase terminates TLS at the pooler and rejects unencrypted sessions.
       sslmode  = "require")
}

# Human-readable, credential-free. Use this in every message.
curation_db_label <- function(cfg = curation_db_config()) {
  if (is.null(cfg)) "no CURATION_DB_URL" else sprintf("%s:%d/%s", cfg$host, cfg$port, cfg$dbname)
}

curation_connect <- function(cfg = curation_db_config(), timeout = 20L) {
  if (is.null(cfg)) stop("CURATION_DB_URL is not set", call. = FALSE)
  tryCatch(
    DBI::dbConnect(RPostgres::Postgres(),
                   host = cfg$host, port = cfg$port, dbname = cfg$dbname,
                   user = cfg$user, password = cfg$password,
                   sslmode = cfg$sslmode, connect_timeout = timeout),
    error = function(e) stop(explain_connect_error(conditionMessage(e), cfg), call. = FALSE))
}

# Two connection failures are routinely misdiagnosed as bad credentials, and
# both have a specific fix. Say so rather than passing the raw libpq text up.
explain_connect_error <- function(msg, cfg) {
  if (grepl("EMAXCONNSESSION|max clients reached", msg)) {
    return(paste0(
      "the database is out of client slots (", curation_db_label(cfg), ").\n",
      "  Supabase's session pooler allows 15 for the WHOLE project, shared with\n",
      "  export.R, any psql session and any second copy of the app. Nothing is\n",
      "  wrong with the credentials. Close idle sessions or wait for the pooler\n",
      "  to reap them.\n  Original: ", msg))
  }
  if (grepl("no route to host|could not translate host name", msg, ignore.case = TRUE)) {
    return(paste0(
      "cannot reach ", curation_db_label(cfg), ".\n",
      "  Supabase's DIRECT endpoint (db.<ref>.supabase.co) is IPv6-only; on a\n",
      "  network without IPv6 it resolves and then has no route. Use the SESSION\n",
      "  pooler (aws-<n>-<region>.pooler.supabase.com:5432, username\n",
      "  postgres.<ref>).\n  Original: ", msg))
  }
  paste0("could not connect to ", curation_db_label(cfg), ": ", msg)
}

# The app uses a pool: several concurrent sessions each opening their own
# connection is how a free-tier database runs out of them. export.R does not —
# it is one short-lived process and a pool would outlive its usefulness.
#
# THE CEILING IS 15 CLIENTS, NOT 15 PER PROCESS. Supabase's session-mode pooler
# allows pool_size 15 for the whole project, and every one of these slots is
# shared with export.R, any psql, and any second copy of the app — a redeploy
# that overlaps the old process, or a second instance. maxSize 5 means three
# app processes exhaust it and reviewers are told "max clients reached" at the
# LOGIN SCREEN, which reads exactly like a credentials problem.
#
# minSize 0 so an idle process holds nothing; idleTimeout hands slots back.
# Measured the hard way: killed app instances leaked their connections until
# the pooler reaped them, and the database was unreachable for minutes.
curation_pool <- function(cfg = curation_db_config(), min = 0L, max = 3L) {
  if (is.null(cfg)) stop("CURATION_DB_URL is not set", call. = FALSE)
  pool::dbPool(RPostgres::Postgres(),
               host = cfg$host, port = cfg$port, dbname = cfg$dbname,
               user = cfg$user, password = cfg$password,
               sslmode = cfg$sslmode,
               minSize = min, maxSize = max, idleTimeout = 300)
}

# Multi-statement scripts need the SIMPLE query protocol. The default prepares
# the string, and Postgres refuses more than one command in a prepared
# statement — "cannot insert multiple commands into a prepared statement".
db_run_script <- function(con, path) {
  sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
  DBI::dbExecute(con, sql, immediate = TRUE)
}

curation_apply_schema <- function(con, path = "curation_app/sql/schema.sql") {
  db_run_script(con, path)
  invisible(TRUE)
}

# ── Writes ────────────────────────────────────────────────────────────────────
#
# Every write is parameterised. None of these values are ours: a canonical name,
# a comment and a raw registry string all arrive from a form or a CSV, and
# pasting them into SQL is how a reviewer's apostrophe becomes an outage — or
# worse. RPostgres binds $1..$n; there is no interpolation anywhere in this file.

# Appended, never updated. A reviewer changing their mind writes a NEW row and
# the latest-wins view decides; the earlier decision stays, because the
# disagreement report needs the loser to still exist.
append_norm_decision <- function(con, domain, raw_value, action, reviewer,
                                 snapshot_sha,
                                 entity_id_shown = NA, proposed = NA,
                                 final_canonical = NA, final_entity_id = NA,
                                 new_canonical = FALSE, entity_type = NA,
                                 salt_form = NA, brand = NA, parent = NA,
                                 legal_entity = NA, n_trials_shown = NA,
                                 confidence_shown = NA, review_reason = NA,
                                 comment = NA, decision_ms = NA, app_version = NA) {
  stopifnot(domain %in% c("sponsor", "substance"))
  stopifnot(action %in% c("accept", "edit", "reject", "not_a_substance", "skip", "flag"))
  if (identical(action, "not_a_substance") && !identical(domain, "substance")) {
    stop("not_a_substance is a substance-only action", call. = FALSE)
  }
  DBI::dbGetQuery(con, "
    INSERT INTO norm_decisions
      (domain, raw_value, action, entity_id_shown, proposed, final_canonical,
       final_entity_id, new_canonical, entity_type, salt_form, brand, parent,
       legal_entity, n_trials_shown, confidence_shown, review_reason, comment,
       reviewer, snapshot_sha, decision_ms, app_version)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21)
    RETURNING decision_id",
    params = list(domain, raw_value, action, entity_id_shown, proposed,
                  final_canonical, final_entity_id, new_canonical, entity_type,
                  salt_form, brand, parent, legal_entity,
                  as_int(n_trials_shown), as_num(confidence_shown), review_reason,
                  comment, reviewer, snapshot_sha, as_int(decision_ms),
                  app_version))$decision_id
}

append_trial_decision <- function(con, trial_id, field_id, action, reviewer,
                                  snapshot_sha, raw_shown = NA, norm_shown = NA,
                                  final_value = NA, value_type = NA,
                                  comment = NA, decision_ms = NA, app_version = NA) {
  stopifnot(action %in% c("validate", "override", "clear"))
  if (!is.na(value_type) &&
      !value_type %in% c("character", "numeric", "integer", "logical", "date")) {
    stop("unknown value_type: ", value_type, call. = FALSE)
  }
  DBI::dbGetQuery(con, "
    INSERT INTO trial_decisions
      (trial_id, field_id, action, raw_shown, norm_shown, final_value,
       value_type, comment, reviewer, snapshot_sha, decision_ms, app_version)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
    RETURNING decision_id",
    params = list(trial_id, field_id, action, raw_shown, norm_shown, final_value,
                  value_type, comment, reviewer, snapshot_sha,
                  as_int(decision_ms), app_version))$decision_id
}

append_trial_review <- function(con, trial_id, status, reviewer, snapshot_sha,
                                comment = NA) {
  stopifnot(status %in% c("validated", "flagged", "reopened"))
  DBI::dbGetQuery(con, "
    INSERT INTO trial_reviews (trial_id, status, comment, reviewer, snapshot_sha)
    VALUES ($1,$2,$3,$4,$5) RETURNING review_id",
    params = list(trial_id, status, comment, reviewer, snapshot_sha))$review_id
}

# NA has to reach Postgres as a typed NULL. A bare NA is logical, and binding a
# logical into an integer column is an error rather than a null.
as_int <- function(x) if (length(x) == 0 || is.na(x)) NA_integer_ else as.integer(x)
as_num <- function(x) if (length(x) == 0 || is.na(x)) NA_real_    else as.numeric(x)

# ── Reads ─────────────────────────────────────────────────────────────────────
#
# The latest-wins rule lives in the VIEWS (see schema.sql), not here, so the app
# and export.R cannot drift on the one rule that decides what reaches production.

latest_norm_decisions <- function(con, domain = NULL) {
  if (is.null(domain)) DBI::dbGetQuery(con, "SELECT * FROM norm_decisions_latest")
  else DBI::dbGetQuery(con, "SELECT * FROM norm_decisions_latest WHERE domain = $1",
                       params = list(domain))
}

latest_trial_decisions <- function(con, trial_id = NULL) {
  if (is.null(trial_id)) DBI::dbGetQuery(con, "SELECT * FROM trial_decisions_latest")
  else DBI::dbGetQuery(con, "SELECT * FROM trial_decisions_latest WHERE trial_id = $1",
                       params = list(trial_id))
}

latest_trial_reviews <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT DISTINCT ON (trial_id) * FROM trial_reviews
    ORDER BY trial_id, decided_at_utc DESC, review_id DESC")
}

norm_disagreements  <- function(con) DBI::dbGetQuery(con, "SELECT * FROM norm_disagreements ORDER BY last_decided_at DESC")
trial_disagreements <- function(con) DBI::dbGetQuery(con, "SELECT * FROM trial_disagreements ORDER BY last_decided_at DESC")

# Open flags: rows whose most recent non-skip entry is a flag, i.e. someone
# asked for a second look and nobody has decided it since. Read straight from
# the table, because the latest-wins view deliberately leaves flags out.
open_norm_flags <- function(con, domain) {
  DBI::dbGetQuery(con, "
    SELECT raw_value, reviewer, comment, decided_at_utc FROM (
      SELECT DISTINCT ON (raw_value) raw_value, action, reviewer, comment,
             decided_at_utc
      FROM norm_decisions
      WHERE domain = $1 AND action <> 'skip'
      ORDER BY raw_value, decided_at_utc DESC, decision_id DESC) x
    WHERE action = 'flag'
    ORDER BY raw_value", params = list(domain))
}

# Cheap enough to poll. Tab 2 uses it so two reviewers do not work the same row.
max_norm_decision_id <- function(con) {
  as.numeric(DBI::dbGetQuery(con, "SELECT COALESCE(max(decision_id), 0) AS m FROM norm_decisions")$m)
}

# ── Reviewers ─────────────────────────────────────────────────────────────────

reviewer_get <- function(con, username) {
  r <- DBI::dbGetQuery(con,
    "SELECT username, display_name, email, password_hash, role, active, must_change_pw
     FROM reviewers WHERE username = $1", params = list(username))
  if (!nrow(r)) NULL else as.list(r[1, ])
}

# Returns the reviewer on success, NULL on ANY failure — wrong password, unknown
# user, deactivated account. The caller must not be able to tell which, or the
# login form becomes a way to enumerate usernames.
#
# The hash is verified even when the user does not exist, against a dummy, so
# that a missing username and a wrong password take the same time. Without it
# the response time answers the question the uniform error message refuses to.
# A REAL hash, generated once on first use. A hand-written look-alike does not
# work: password_verify() rejects a malformed string immediately instead of
# doing the key derivation, so the unknown-user path returns roughly twice as
# fast as a wrong password and the timing answers the question the uniform
# error message refuses to. Measured at 0.20s vs 0.44s before this was fixed.
dummy_hash <- local({
  cached <- NULL
  function() {
    if (is.null(cached)) cached <<- sodium::password_store(paste(sample(letters, 24, TRUE), collapse = ""))
    cached
  }
})

reviewer_verify <- function(con, username, password) {
  # The CLIENT must not be able to tell these apart. The SERVER LOG must.
  #
  # The uniform failure is a real security property — distinguishing "no such
  # user" from "wrong password" turns the form into a username oracle. But the
  # first version also swallowed connection errors, permission errors and
  # anything else into the same message, which made a failing login impossible
  # to diagnose from outside: every cause looked like a typo. Everything below
  # returns NULL to the caller and says why to the log.
  why <- function(msg) { message("login refused [", username, "]: ", msg); NULL }

  r <- tryCatch(reviewer_get(con, username),
                error = function(e) {
                  message("login ERROR [", username, "]: reviewer lookup failed: ",
                          conditionMessage(e))
                  NULL
                })

  # Verified against a real hash even when the user does not exist, so the two
  # paths take the same time — see dummy_hash().
  hash <- if (is.null(r)) dummy_hash() else r$password_hash
  ok <- tryCatch(sodium::password_verify(hash, password),
                 error = function(e) {
                   message("login ERROR [", username, "]: password_verify failed: ",
                           conditionMessage(e))
                   FALSE
                 })

  if (is.null(r))        return(why("no such user"))
  if (!isTRUE(ok))       return(why("wrong password"))
  if (!isTRUE(r$active)) return(why("account is deactivated"))

  # Bookkeeping, and it MUST NOT be able to block a sign-in. This is an UPDATE,
  # so it is the one statement here that a missing column grant can reject — and
  # in the first version that exception propagated out and the login failed with
  # "check your username and password" for a reason that had nothing to do with
  # either.
  tryCatch(
    DBI::dbExecute(con, "UPDATE reviewers SET last_login_at = now() WHERE username = $1",
                   params = list(username)),
    error = function(e)
      message("login WARN [", username, "]: could not stamp last_login_at (",
              conditionMessage(e), ") — signing in anyway"))

  message("login ok [", username, "] role=", r$role)
  r$password_hash <- NULL   # never leaves this function
  r
}

reviewer_set_password <- function(con, username, password) {
  DBI::dbExecute(con,
    "UPDATE reviewers SET password_hash = $1, must_change_pw = FALSE WHERE username = $2",
    params = list(sodium::password_store(password), username))
}

# Creating an account is a privileged write, so it validates rather than
# trusting the form: a username that is not a plain identifier ends up in
# decision rows, CSV exports and audit entries, and quoting it correctly
# everywhere afterwards is not a bet worth taking.
reviewer_create <- function(con, username, display_name, password,
                            role = "reviewer", email = NA_character_) {
  if (!grepl("^[a-z0-9_.-]{3,32}$", username))
    stop("username must be 3-32 chars of a-z, 0-9, dot, dash or underscore", call. = FALSE)
  if (!role %in% c("reviewer", "admin")) stop("unknown role: ", role, call. = FALSE)
  if (is.null(password) || nchar(password) < 12)
    stop("password must be at least 12 characters", call. = FALSE)
  if (!is.null(reviewer_get(con, username)))
    stop("that username already exists", call. = FALSE)
  DBI::dbExecute(con, "
    INSERT INTO reviewers (username, display_name, email, password_hash, role, must_change_pw)
    VALUES ($1,$2,$3,$4,$5,TRUE)",
    params = list(username, display_name, email,
                  sodium::password_store(password), role))
  invisible(TRUE)
}

# NEVER a DELETE. Both decision tables reference this row and a reviewer's work
# has to outlive their account.
reviewer_set_active <- function(con, username, active) {
  DBI::dbExecute(con, "UPDATE reviewers SET active = $2 WHERE username = $1",
                 params = list(username, isTRUE(active)))
}

reviewer_set_role <- function(con, username, role) {
  if (!role %in% c("reviewer", "admin")) stop("unknown role: ", role, call. = FALSE)
  DBI::dbExecute(con, "UPDATE reviewers SET role = $2 WHERE username = $1",
                 params = list(username, role))
}

# How many admins are left, so the app can refuse to remove the last one.
admin_count <- function(con) {
  as.numeric(DBI::dbGetQuery(con,
    "SELECT count(*) n FROM reviewers WHERE role = 'admin' AND active")$n)
}

# Everything a reviewer did, flattened for download — one row per entry, all
# three tables. Deliberately excludes password_hash and every other reviewers
# column beyond the username.
#
#   kind = norm           tab 2: a sponsor/substance decision (or skip/flag)
#          trial_field    tab 1: a correction to one field of one trial
#          trial_signoff  tab 1: the whole-trial "validated" / "flagged" + comment
#
# trial_signoff was missing until v0.22.1, so a finished Trial validation round
# exported as nothing at all — the comments reviewers wrote there were only in
# the database.
#
# is_current says whether this entry is the one that counts now: entries are
# appended, never updated, so a changed mind leaves the earlier one behind.
# Skips and flags are never current, because they are not decisions.
decisions_export <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT 'norm' AS kind, d.decision_id, d.decided_at_utc, d.reviewer,
           d.domain AS scope, d.raw_value AS key1, NULL::text AS key2, d.action,
           d.raw_value AS raw_value, d.proposed AS before_value,
           d.final_canonical AS after_value, d.new_canonical, d.n_trials_shown,
           d.confidence_shown, d.review_reason, d.comment,
           (l.decision_id IS NOT NULL) AS is_current,
           d.snapshot_sha, d.decision_ms, d.app_version
    FROM norm_decisions d
    LEFT JOIN norm_decisions_latest l ON l.decision_id = d.decision_id
    UNION ALL
    SELECT 'trial_field', d.decision_id, d.decided_at_utc, d.reviewer, 'trial',
           d.trial_id, d.field_id, d.action, d.raw_shown, d.norm_shown,
           d.final_value, NULL::boolean, NULL::integer, NULL::real, NULL::text,
           d.comment, (l.decision_id IS NOT NULL), d.snapshot_sha, d.decision_ms,
           d.app_version
    FROM trial_decisions d
    LEFT JOIN trial_decisions_latest l ON l.decision_id = d.decision_id
    UNION ALL
    SELECT 'trial_signoff', r.review_id, r.decided_at_utc, r.reviewer, 'trial',
           r.trial_id, NULL::text, r.status, NULL::text, NULL::text, NULL::text,
           NULL::boolean, NULL::integer, NULL::real, NULL::text, r.comment,
           (l.review_id IS NOT NULL), r.snapshot_sha, NULL::integer, NULL::text
    FROM trial_reviews r
    LEFT JOIN (SELECT DISTINCT ON (trial_id) review_id FROM trial_reviews
               ORDER BY trial_id, decided_at_utc DESC, review_id DESC) l
           ON l.review_id = r.review_id
    ORDER BY decided_at_utc DESC")
}

# The database only knows a trial by the cache's internal `_id`. A reviewer
# reading the export needs the CT number and title, so they are added from the
# trials cache, right after the key. Pure, so it is testable.
decisions_export_label <- function(d, cache) {
  if (is.null(d) || !nrow(d)) return(d)
  is_trial <- d$scope == "trial"
  ct <- title <- rep(NA_character_, nrow(d))
  if (!is.null(cache) && "_id" %in% names(cache)) {
    m <- match(d$key1, cache$`_id`)
    hit <- is_trial & !is.na(m)
    if ("CT_number" %in% names(cache))  ct[hit]    <- as.character(cache$CT_number[m[hit]])
    if ("Full_title" %in% names(cache)) title[hit] <- as.character(cache$Full_title[m[hit]])
  }
  at <- match("key2", names(d))
  cbind(d[seq_len(at)], ct_number = ct, trial_title = title,
        d[-seq_len(at)], stringsAsFactors = FALSE)
}

# Clears the testing data. Reviewer ACCOUNTS survive — resetting the data
# should not lock everyone out.
#
# Goes through a SECURITY DEFINER function rather than DELETE statements: the
# app role has no DELETE on any table and must not gain one. The function's
# scope is fixed in schema.sql, so this cannot become "delete these rows".
curation_reset_testing_data <- function(con, actor, clear_audit = FALSE) {
  DBI::dbGetQuery(con, "SELECT * FROM curation_reset_testing_data($1, $2)",
                  params = list(actor, isTRUE(clear_audit)))
}

admin_audit_recent <- function(con, n = 200L) {
  DBI::dbGetQuery(con, "SELECT * FROM admin_audit ORDER BY at_utc DESC LIMIT $1",
                  params = list(as.integer(n)))
}

reviewer_list <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT username, display_name, email, role, active, must_change_pw,
           created_at, last_login_at
    FROM reviewers ORDER BY username")
}

# ── Export bookkeeping ────────────────────────────────────────────────────────

export_run_start <- function(con, domain, host = Sys.info()[["nodename"]]) {
  DBI::dbGetQuery(con, "
    INSERT INTO export_runs (host, domain, status) VALUES ($1,$2,'running')
    RETURNING export_id", params = list(host, domain))$export_id
}

export_run_finish <- function(con, export_id, status, message = NA,
                              max_norm_decision_id = NA, max_trial_decision_id = NA,
                              n_sponsor_pins = NA, n_substance_pins = NA,
                              n_new_entities = NA, n_trial_overrides = NA) {
  DBI::dbExecute(con, "
    UPDATE export_runs SET finished_at_utc = now(), status = $2, message = $3,
      max_norm_decision_id = $4, max_trial_decision_id = $5,
      n_sponsor_pins = $6, n_substance_pins = $7, n_new_entities = $8,
      n_trial_overrides = $9
    WHERE export_id = $1",
    params = list(export_id, status, message,
                  as_int(max_norm_decision_id), as_int(max_trial_decision_id),
                  as_int(n_sponsor_pins), as_int(n_substance_pins),
                  as_int(n_new_entities), as_int(n_trial_overrides)))
}

export_runs_recent <- function(con, n = 20L) {
  DBI::dbGetQuery(con, "SELECT * FROM export_runs ORDER BY started_at_utc DESC LIMIT $1",
                  params = list(as.integer(n)))
}

# "Decided but not yet live" — the first question a reviewer asks after their
# first decision, and unanswerable without the high-water marks.
export_lag <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT
      (SELECT COALESCE(max(decision_id),0) FROM norm_decisions)  AS max_norm,
      (SELECT COALESCE(max(decision_id),0) FROM trial_decisions) AS max_trial,
      (SELECT COALESCE(max(max_norm_decision_id),0)  FROM export_runs WHERE status='ok') AS exported_norm,
      (SELECT COALESCE(max(max_trial_decision_id),0) FROM export_runs WHERE status='ok') AS exported_trial,
      (SELECT max(finished_at_utc) FROM export_runs WHERE status='ok') AS last_ok")
}

admin_audit_log <- function(con, actor, action, target = NA, detail = NULL) {
  DBI::dbExecute(con, "
    INSERT INTO admin_audit (actor, action, target, detail) VALUES ($1,$2,$3,$4)",
    params = list(actor, action, target,
                  if (is.null(detail)) NA_character_ else jsonlite::toJSON(detail, auto_unbox = TRUE)))
}
