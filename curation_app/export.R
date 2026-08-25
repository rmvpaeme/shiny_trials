#!/usr/bin/env Rscript
# Materialise reviewer decisions into the pipeline's own files.
#
#   Rscript curation_app/export.R --domain=sponsor            # dry run
#   Rscript curation_app/export.R --domain=sponsor   --write
#   Rscript curation_app/export.R --domain=substance --write
#   Rscript curation_app/export.R --domain=trial     --write
#
# THE SINGLE WRITER. The app never touches these files: it runs on Posit with no
# shared filesystem, and a second writer racing N_nightly_resolve.R is exactly
# the read-modify-write collision that retired the v1 reviewer app. This runs on
# the server, inside the nightly, one domain at a time.
#
# ── What it produces ──────────────────────────────────────────────────────────
#
#   sponsor / substance   assignments.csv and registry.csv in $SPONSOR_V2_DIR /
#                         $SUBSTANCE_V2_DIR, with decided_by = "human"
#   substance also        $DATA_DIR/substance_rejected.csv for not-a-substance
#   trial                 $DATA_DIR/trial_overrides.csv
#
# decided_by = "human" is a contract the pipeline has honoured since v0.20 with
# nothing writing to it: pinned assignments survive a re-run (registry.R:271),
# merges of human entities are refused (registry.R:307), and route_for_review()
# drops human rows so the string leaves the queue by construction (registry.R:377).
#
# ── It must never abort the nightly ───────────────────────────────────────────
#
# rebuild_cache.R's governing rule is that a sponsor hiccup never costs the data
# refresh. Every failure path here exits 0 and reports through a sentinel file,
# exactly as N_nightly_resolve.R does. The only non-zero exit is a bad argument,
# which is a caller bug and cannot happen in the nightly.

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble)
})

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default = NA_character_) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit)) sub(paste0("^", flag, "="), "", hit[[1L]]) else default
}
domain <- arg_value("--domain")
do_write <- "--write" %in% args

if (!domain %in% c("sponsor", "substance", "trial")) {
  message("usage: export.R --domain=sponsor|substance|trial [--write]")
  quit(save = "no", status = 2L)
}

script_dir <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) dirname(normalizePath(sub("^--file=", "", hit[[1L]]))) else getwd()
})
project_root <- normalizePath(file.path(script_dir, ".."), mustWork = FALSE)
pp <- function(...) file.path(project_root, ...)

source(pp("helper_scripts", "llm_norm", "registry.R"))
source(file.path(script_dir, "R", "store.R"))

DATA_DIR      <- Sys.getenv("DATA_DIR",          unset = pp("data"))
SPONSOR_V2    <- Sys.getenv("SPONSOR_V2_DIR",    unset = pp("config", "sponsor_norm_v2"))
SUBSTANCE_V2  <- Sys.getenv("SUBSTANCE_V2_DIR",  unset = pp("config", "substance_norm_v2"))
SENTINEL      <- file.path(DATA_DIR, ".curation_export_failed")

fail_soft <- function(msg) {
  message("*** CURATION EXPORT FAILED — ", msg, " ***")
  message("    The nightly continues; nothing was written.")
  try({
    dir.create(dirname(SENTINEL), recursive = TRUE, showWarnings = FALSE)
    writeLines(sprintf("%s %s: %s", format(Sys.time()), domain, msg), SENTINEL)
  }, silent = TRUE)
  quit(save = "no", status = 0L)
}

# ── Connect ───────────────────────────────────────────────────────────────────
#
# No connection string is NOT a failure. A laptop rebuild has no database and
# must behave exactly as it did before this script existed — no sentinel, no
# noise, no change to any file.
if (is.null(curation_db_config())) {
  message("No CURATION_DB_URL — nothing to export. (This is normal off the server.)")
  quit(save = "no", status = 0L)
}
con <- tryCatch(curation_connect(), error = function(e) NULL)
if (is.null(con)) fail_soft(paste("cannot reach", curation_db_label()))
on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

export_id <- tryCatch(export_run_start(con, domain), error = function(e) NA)

finish <- function(status, message_text = NA, ...) {
  if (!is.na(export_id))
    try(export_run_finish(con, export_id, status, message = message_text, ...), silent = TRUE)
}

# ── Writing ───────────────────────────────────────────────────────────────────

# Byte-compare before touching anything. Two reasons: it makes "nothing changed"
# observable rather than asserted — an unchanged night leaves no new backup
# directory — and it keeps the nightly's git diff empty when no one has curated,
# instead of rewriting two multi-megabyte CSVs every run.
would_change <- function(x, path, cols, sort_by) {
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)
  write_table_atomic(x, tmp, cols, sort_by)
  if (!file.exists(path)) return(TRUE)
  !identical(readBin(tmp, "raw", file.size(tmp)),
             readBin(path, "raw", file.size(path)))
}

# These files are the product of paid model output, and once the state lives
# outside the work tree git is no longer an undo.
backup_once <- local({
  done <- FALSE
  function(dir, paths) {
    if (done) return(invisible(NULL))
    stamp <- format(Sys.time(), "%Y%m%dT%H%M%SZ", tz = "UTC")
    dest <- file.path(dir, "backups", stamp)
    dir.create(dest, recursive = TRUE, showWarnings = FALSE)
    for (p in paths) if (file.exists(p)) file.copy(p, file.path(dest, basename(p)))
    message("  backed up to ", dest)
    # Keep the last 14. Unbounded backups of a 4.8 MB file fill a disk quietly.
    all_b <- sort(list.dirs(file.path(dir, "backups"), recursive = FALSE))
    if (length(all_b) > 14) unlink(head(all_b, length(all_b) - 14), recursive = TRUE)
    done <<- TRUE
    invisible(NULL)
  }
})

# Postgres timestamps in the pipeline's own format. NOT utc_now(): using the
# time of the RUN instead of the time of the DECISION rewrites every human row
# on every nightly, so the file churns forever and idempotence is unprovable.
as_pipeline_time <- function(x) format(as.POSIXct(x, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

# ── Sponsor and substance ─────────────────────────────────────────────────────

export_norm <- function(domain) {
  v2      <- if (domain == "sponsor") SPONSOR_V2 else SUBSTANCE_V2
  raw_col <- if (domain == "sponsor") "raw_sponsor" else "raw_substance"
  reg_path <- file.path(v2, "registry.csv")
  asg_path <- file.path(v2, "assignments.csv")
  if (!file.exists(reg_path)) fail_soft(paste("no registry at", reg_path))

  reg <- registry_read(reg_path)
  asg <- assignments_read(asg_path, raw_col)
  dec <- latest_norm_decisions(con, domain)
  if (!nrow(dec)) {
    message("No decisions for ", domain, " — nothing to do.")
    finish("ok", "no decisions", n_sponsor_pins = 0L, n_substance_pins = 0L)
    return(invisible(TRUE))
  }
  message(sprintf("%d decision(s) for %s", nrow(dec), domain))

  n_new <- 0L
  rejected_rows <- character()

  for (i in seq_len(nrow(dec))) {
    d <- dec[i, ]
    entity <- NA_character_

    if (d$action %in% c("accept", "edit")) {
      target <- d$final_canonical
      if (is.na(target) || !nzchar(target)) target <- d$proposed
      if (!is.na(target) && nzchar(target)) {
        # Case- and accent-insensitive, so a re-run does not mint a second
        # entity that differs only in capitalisation from one it made last time.
        key <- tolower(trimws(iconv(target, to = "ASCII//TRANSLIT")))
        reg_key <- tolower(trimws(iconv(reg$canonical, to = "ASCII//TRANSLIT")))
        hit <- which(reg_key == key)
        if (length(hit)) {
          entity <- reg$entity_id[hit[1]]
        } else {
          added <- registry_add(
            reg, canonical = target,
            entity_type = d$entity_type, salt_form = d$salt_form, brand = d$brand,
            parent = d$parent, legal_entity = d$legal_entity,
            confidence = 1, decided_by = "human", model_id = "curation",
            note = sprintf("curation:%s:%s", d$reviewer, d$decision_id))
          reg <- added$registry
          entity <- added$entity_ids[1]
          n_new <- n_new + 1L
          message("  minted ", entity, " = ", target)
        }
      }
    } else if (d$action == "not_a_substance") {
      rejected_rows <- c(rejected_rows, d$raw_value)
    }
    # reject and not_a_substance both leave entity NA. E_emit then classifies
    # the row as human_unassigned rather than a regression — the gate fix that
    # had to land before this script could exist at all.

    if (!is.na(entity)) entity <- resolve_entity(reg, entity)

    row <- tibble::tibble(
      !!raw_col := d$raw_value,
      entity_id = entity,
      confidence = 1,
      channel = "review",
      reason = sprintf("curation:%s:%s", d$reviewer, d$decision_id),
      decided_by = "human",
      decided_at_utc = as_pipeline_time(d$decided_at_utc),
      model_id = "curation",
      prompt_version = NA_character_)

    # INSERT or UPDATE. route_for_review() queues rows with no assignment at
    # all, so a decided string may have no row to update — an update-only export
    # would silently drop exactly the strings a reviewer was asked to look at.
    hit <- which(asg[[raw_col]] == d$raw_value)
    if (length(hit)) asg[hit[1], names(row)] <- row else asg <- bind_rows(asg, row)
  }

  n_pins <- nrow(dec)
  changed_reg <- would_change(reg, reg_path, REGISTRY_COLS, "entity_id")
  changed_asg <- would_change(asg, asg_path, assignment_cols(raw_col), raw_col)

  if (!changed_reg && !changed_asg) {
    message("Already up to date — no write, no backup.")
    finish("ok", "no change")
    return(invisible(TRUE))
  }
  if (!do_write) {
    message(sprintf("DRY RUN: would update %s%s (%d pin(s), %d new entity(ies))",
                    if (changed_asg) "assignments.csv " else "",
                    if (changed_reg) "registry.csv" else "", n_pins, n_new))
    finish("skipped", "dry run")
    return(invisible(TRUE))
  }

  backup_once(v2, c(reg_path, asg_path))
  if (changed_reg) registry_write(reg, reg_path)
  if (changed_asg) assignments_write(asg, asg_path, raw_col)
  message(sprintf("Wrote %d pin(s), %d new entity(ies) to %s", n_pins, n_new, v2))

  if (length(rejected_rows)) append_not_substance(rejected_rows)

  finish("ok", NA,
         max_norm_decision_id = suppressWarnings(max(as.numeric(dec$decision_id))),
         n_sponsor_pins   = if (domain == "sponsor")   n_pins else NA,
         n_substance_pins = if (domain == "substance") n_pins else NA,
         n_new_entities = n_new)
  invisible(TRUE)
}

# The not-a-substance list is what E_emit reads to classify a string "rejected"
# rather than "unknown". The pin alone is not enough: without this row the
# string is unlabelled but still a candidate, and the queue re-proposes it.
append_not_substance <- function(raws) {
  path <- file.path(DATA_DIR, "substance_rejected.csv")
  cur <- if (file.exists(path))
    read_csv(path, show_col_types = FALSE, progress = FALSE) else
    tibble(raw_substance = character(), n_trials = integer(), reason = character())
  add <- tibble(raw_substance = setdiff(raws, cur$raw_substance),
                n_trials = NA_integer_, reason = "human review: not a substance")
  if (!nrow(add)) return(invisible(NULL))
  out <- bind_rows(cur, add) |> distinct(raw_substance, .keep_all = TRUE) |>
    arrange(raw_substance)   # sorted, or the file churns on row order alone
  tmp <- paste0(path, ".tmp")
  write_csv(out, tmp, na = "", eol = "\n")
  file.rename(tmp, path)
  message("  added ", nrow(add), " string(s) to substance_rejected.csv")
}

# ── Per-trial overrides ───────────────────────────────────────────────────────

export_trial <- function() {
  path <- file.path(DATA_DIR, "trial_overrides.csv")
  dec <- latest_trial_decisions(con)
  dec <- dec[dec$action == "override", , drop = FALSE]

  spec_path <- file.path(script_dir, "R", "field_spec.R")
  if (!file.exists(spec_path)) fail_soft("field_spec.R not found")
  source(spec_path, local = TRUE)
  by_id <- setNames(TRIAL_FIELD_SPEC, vapply(TRIAL_FIELD_SPEC, function(f) f$id, character(1)))

  rows <- lapply(seq_len(nrow(dec)), function(i) {
    d <- dec[i, ]
    f <- by_id[[d$field_id]]
    # A decision whose field no longer exists, or which is not an override
    # field, is DROPPED rather than guessed at. The spec is the authority on
    # where a correction may land, and attach_trial_overrides() refuses the
    # same columns independently.
    if (is.null(f) || !identical(f$route, "trial_override") || is.na(f$override_col)) return(NULL)
    tibble(`_id` = d$trial_id, field_id = d$field_id, column = f$override_col,
           value = d$final_value, value_type = d$value_type %||% "character",
           reviewer = d$reviewer, decided_at_utc = as_pipeline_time(d$decided_at_utc),
           decision_id = as.character(d$decision_id),
           comment = d$comment %||% NA_character_)
  })
  out <- bind_rows(rows)
  dropped <- nrow(dec) - nrow(out)
  if (dropped > 0) message("  skipped ", dropped, " decision(s) with no override route")
  if (nrow(out)) out <- arrange(out, `_id`, column)

  tmp <- tempfile(fileext = ".csv")
  write_csv(out, tmp, na = "", eol = "\n")
  changed <- !file.exists(path) ||
    !identical(readBin(tmp, "raw", file.size(tmp)), readBin(path, "raw", file.size(path)))
  unlink(tmp)

  if (!changed) { message("trial_overrides.csv already up to date."); finish("ok", "no change"); return(invisible(TRUE)) }
  if (!do_write) { message(sprintf("DRY RUN: would write %d override(s)", nrow(out)))
                   finish("skipped", "dry run"); return(invisible(TRUE)) }

  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp2 <- paste0(path, ".tmp")
  write_csv(out, tmp2, na = "", eol = "\n")
  file.rename(tmp2, path)
  message(sprintf("Wrote %d override(s) to %s", nrow(out), path))
  finish("ok", NA,
         max_trial_decision_id = suppressWarnings(max(as.numeric(dec$decision_id))),
         n_trial_overrides = nrow(out))
  invisible(TRUE)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || is.na(a)) b else a

ok <- tryCatch({
  if (domain == "trial") export_trial() else export_norm(domain)
  TRUE
}, error = function(e) { finish("failed", conditionMessage(e)); fail_soft(conditionMessage(e)); FALSE })

quit(save = "no", status = 0L)
