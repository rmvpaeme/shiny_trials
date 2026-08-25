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
  DBI::dbConnect(RPostgres::Postgres(),
                 host = cfg$host, port = cfg$port, dbname = cfg$dbname,
                 user = cfg$user, password = cfg$password,
                 sslmode = cfg$sslmode, connect_timeout = timeout)
}

# The app uses a pool: several concurrent sessions each opening their own
# connection is how a free-tier database runs out of them. export.R does not —
# it is one short-lived process and a pool would outlive its usefulness.
curation_pool <- function(cfg = curation_db_config(), min = 1L, max = 5L) {
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
  stopifnot(action %in% c("accept", "edit", "reject", "not_a_substance", "skip"))
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
  r <- tryCatch(reviewer_get(con, username), error = function(e) NULL)
  hash <- if (is.null(r)) dummy_hash() else r$password_hash
  ok <- tryCatch(sodium::password_verify(hash, password), error = function(e) FALSE)
  if (is.null(r) || !isTRUE(ok) || !isTRUE(r$active)) return(NULL)
  DBI::dbExecute(con, "UPDATE reviewers SET last_login_at = now() WHERE username = $1",
                 params = list(username))
  r$password_hash <- NULL   # never leaves this function
  r
}

reviewer_set_password <- function(con, username, password) {
  DBI::dbExecute(con,
    "UPDATE reviewers SET password_hash = $1, must_change_pw = FALSE WHERE username = $2",
    params = list(sodium::password_store(password), username))
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
