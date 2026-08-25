#!/usr/bin/env Rscript
# Create the least-privilege role the deployed app should use, and print its
# connection string once.
#
#   Rscript curation_app/apply_app_role.R
#   Rscript curation_app/apply_app_role.R --rotate    # new password, same grants
#
# Needs CURATION_DB_URL set to a SUPERUSER connection (the one you have now).
# Needs no psql: everything runs over DBI.
#
# ── Why ───────────────────────────────────────────────────────────────────────
#
# The app's connection string reaches Posit one way or another — as a Vars entry
# on Connect Cloud, or inside the bundle on a target without one. Assume it can
# be read by someone who should not have it. What matters then is what it can
# DO. `postgres` is the superuser: it reads every password hash in `reviewers`,
# drops tables, and disables the audit trail that would show it happened.
#
# This role cannot. No DELETE or TRUNCATE anywhere, no rights on tables added
# later, and only a column-scoped UPDATE on `reviewers`.

args <- commandArgs(trailingOnly = TRUE)
rotate <- "--rotate" %in% args

here <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) dirname(normalizePath(sub("^--file=", "", hit[[1L]]))) else getwd()
})
source(file.path(here, "R", "store.R"))

cfg <- curation_db_config()
if (is.null(cfg)) stop("CURATION_DB_URL is not set", call. = FALSE)
con <- curation_connect()
on.exit(DBI::dbDisconnect(con), add = TRUE)
cat("Connected to", curation_db_label(), "as", cfg$user, "\n")

# Generated here, never stored. 32 chars from a set with no quoting hazards —
# a password containing @ : / or ? breaks URL parsing, which is a confusing
# failure to debug from "authentication failed".
alphabet <- c(letters, LETTERS, 0:9, "-", "_", ".")
pw <- paste(sample(alphabet, 32, replace = TRUE), collapse = "")

exists_already <- nrow(DBI::dbGetQuery(con,
  "SELECT 1 FROM pg_roles WHERE rolname = 'curation_app'")) > 0

if (!exists_already) {
  DBI::dbExecute(con, paste0("CREATE ROLE curation_app LOGIN PASSWORD ",
                             DBI::dbQuoteLiteral(con, pw)))
  cat("Created role curation_app.\n")
} else if (rotate) {
  DBI::dbExecute(con, paste0("ALTER ROLE curation_app PASSWORD ",
                             DBI::dbQuoteLiteral(con, pw)))
  cat("Rotated the password for curation_app.\n")
} else {
  cat("Role curation_app already exists; leaving its password alone.\n")
  cat("  Re-run with --rotate to set a new one.\n")
  pw <- NULL
}

# The grants, re-run every time so a new table added to schema.sql cannot be
# left unreachable by an older role.
sql <- paste(readLines(file.path(here, "sql", "app_role.sql"), warn = FALSE), collapse = "\n")
sql <- paste(Filter(function(l) !grepl("^\\s*--", l) && nzchar(trimws(l)),
                    strsplit(sql, "\n")[[1]]), collapse = "\n")
for (stmt in Filter(nzchar, trimws(strsplit(sql, ";")[[1]]))) {
  DBI::dbExecute(con, stmt)
}
cat("Grants applied.\n")

# ── Verify EVERY table and view, not a sample of them ────────────────────────
#
# The grant list is hand-written and will fall behind schema.sql — it already
# did: review_sample was added to the schema after this file, so the role had no
# rights on it at all and the app would have failed the moment anyone opened tab
# 1. Checking a couple of representative tables would not have caught that, so
# this enumerates what is actually in the database.
problems <- character()

tbls <- DBI::dbGetQuery(con, "
  SELECT table_name FROM information_schema.tables
  WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name")$table_name
cat("\nVerified:\n")
cat(sprintf("  %-22s %-7s %-7s %-7s\n", "table", "SELECT", "INSERT", "DELETE"))
for (t in tbls) {
  p <- DBI::dbGetQuery(con, sprintf("
    SELECT has_table_privilege('curation_app','%s','SELECT') s,
           has_table_privilege('curation_app','%s','INSERT') i,
           has_table_privilege('curation_app','%s','DELETE') d", t, t, t))
  cat(sprintf("  %-22s %-7s %-7s %-7s\n", t, p$s, p$i, p$d))
  if (!isTRUE(p$s)) problems <- c(problems, paste(t, "cannot SELECT"))
  if (!isTRUE(p$i)) problems <- c(problems, paste(t, "cannot INSERT"))
  # The point of the whole exercise: an append-only store the app cannot prune.
  if (isTRUE(p$d)) problems <- c(problems, paste(t, "CAN DELETE"))
}

views <- DBI::dbGetQuery(con, "
  SELECT table_name FROM information_schema.views
  WHERE table_schema='public' ORDER BY table_name")$table_name
for (v in views) {
  okv <- DBI::dbGetQuery(con, sprintf(
    "SELECT has_table_privilege('curation_app','%s','SELECT') x", v))$x
  if (!isTRUE(okv)) problems <- c(problems, paste("view", v, "not readable"))
}
cat("  views readable        :", length(views) - sum(grepl("^view ", problems)),
    "of", length(views), "\n")

# Column-scoped UPDATE does not show up in has_table_privilege(), so ask about
# the columns the admin panel actually writes.
for (col in c("password_hash", "role", "active")) {
  okc <- DBI::dbGetQuery(con, sprintf(
    "SELECT has_column_privilege('curation_app','reviewers','%s','UPDATE') x", col))$x
  if (!isTRUE(okc)) problems <- c(problems, paste("cannot UPDATE reviewers.", col, sep = ""))
}
cat("  admin can set password/role/active on reviewers\n")

seq_ok <- DBI::dbGetQuery(con, "
  SELECT COALESCE(bool_and(has_sequence_privilege('curation_app', c.oid, 'USAGE')), TRUE) ok
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'S' AND n.nspname = 'public'")$ok
if (!isTRUE(seq_ok)) problems <- c(problems, "sequences not usable (BIGSERIAL inserts fail)")

if (length(problems)) {
  cat("\nPROBLEMS:\n"); for (x in problems) cat("  -", x, "\n")
  stop("the role does not have the rights the app needs, or has rights it must not",
       call. = FALSE)
}
cat("\n  role has exactly the rights the app needs, and none it must not.\n")

if (!is.null(pw)) {
  # THE POOLER ROUTES BY <db_user>.<project_ref>.
  #
  # A bare "curation_app" never authenticates through it — the pooler cannot
  # tell which project the connection is for. The superuser string shows the
  # shape: postgres.<project_ref>. The project ref is taken from the
  # username we connected with, not guessed.
  ref <- sub("^[^.]+\\.", "", cfg$user)
  app_user <- if (grepl("pooler", cfg$host) && nzchar(ref) && !identical(ref, cfg$user))
    paste0("curation_app.", ref) else "curation_app"
  url <- sprintf("postgresql://%s:%s@%s:%d/%s", app_user, pw, cfg$host, cfg$port, cfg$dbname)
  cat("\n", strrep("-", 72), "\n", sep = "")
  cat("CURATION_DB_URL for the DEPLOYED app — shown once, not stored anywhere:\n\n")
  cat(url, "\n\n")
  cat("Username is '", app_user, "' — through the pooler the project ref is\n", sep = "")
  cat("part of it. A bare role name will not authenticate.\n\n")
  cat("Paste it into Connect Cloud -> the app -> Vars -> CURATION_DB_URL.\n")
  cat("Do NOT put it in curation_app/.Renviron: that file is for local\n")
  cat("development and keeping the superuser there is fine, but the deployed\n")
  cat("app should never have superuser rights.\n")
  cat(strrep("-", 72), "\n")
}
