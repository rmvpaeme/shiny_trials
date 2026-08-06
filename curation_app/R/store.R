# Durable storage for reviewer decisions.
#
# Two things are written for every decision:
#   1. an append-only ledger row (the permanent record), and
#   2. for queue tiers, the decision columns in the queue CSV itself, which is
#      what curate_*.R --export already consumes.
#
# The queue CSVs are rebuilt by build_*_labels.R, which drops decided rows, so
# the ledger — not the queue — is the durable record.

LEDGER_FIELDS <- c(
  "decision_id", "decided_at_utc", "reviewer", "tier", "domain", "source_file",
  "row_key", "raw_value", "proposed_value", "final_value", "action",
  "created_new_canonical", "extra_fields", "comment", "input_hash"
)

VALID_ACTIONS <- c("accept", "edit", "reject", "skip")

utc_now <- function() format(as.POSIXlt(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")

store_paths <- function(project_root) {
  ledger_dir <- file.path(project_root, "config", "review_ledger")
  list(
    root    = project_root,
    dir     = ledger_dir,
    ledger  = file.path(ledger_dir, "review_decisions.csv"),
    lock    = file.path(ledger_dir, ".review.lock")
  )
}

# ── atomic write ──────────────────────────────────────────────────────────────

# Write to a temp file in the same directory, then rename. rename(2) is atomic
# within a filesystem, so a crash mid-write leaves the original intact rather
# than a half-written CSV.
write_csv_atomic <- function(d, path, eol = "\n", quote = c("needed", "all")) {
  quote <- match.arg(quote)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  tmp <- tempfile(paste0(".", basename(path), "-"), tmpdir = dirname(path))
  on.exit(unlink(tmp), add = TRUE)
  readr::write_csv(d, tmp, na = "NA", eol = eol, quote = quote)
  if (!file.rename(tmp, path)) stop("Could not atomically replace ", path, call. = FALSE)
  invisible(path)
}

with_store_lock <- function(paths, code, timeout_ms = 10000L) {
  dir.create(paths$dir, recursive = TRUE, showWarnings = FALSE)
  lock <- filelock::lock(paths$lock, timeout = as.integer(timeout_ms))
  if (is.null(lock)) stop("Timed out waiting for the review lock", call. = FALSE)
  on.exit(filelock::unlock(lock), add = TRUE)
  force(code)
}

# Preserve a file's existing line endings — readr defaults to LF, which would
# otherwise rewrite every line of a CRLF file.
detect_eol <- function(path) {
  if (!file.exists(path)) return("\n")
  head_bytes <- readBin(path, "raw", n = 8192)
  if (length(head_bytes) && any(head_bytes == as.raw(13))) "\r\n" else "\n"
}

# ── ledger ────────────────────────────────────────────────────────────────────

empty_ledger <- function() {
  d <- as.data.frame(
    setNames(rep(list(character()), length(LEDGER_FIELDS)), LEDGER_FIELDS),
    stringsAsFactors = FALSE
  )
  tibble::as_tibble(d)
}

read_ledger <- function(paths) {
  if (!file.exists(paths$ledger)) return(empty_ledger())
  readr::read_csv(
    paths$ledger,
    col_types = readr::cols(.default = readr::col_character()),
    progress  = FALSE
  )
}

# Hash of the row as it was shown to the reviewer, so a decision taken against
# since-changed data is detectable rather than silently stale.
row_hash <- function(...) {
  parts <- vapply(list(...), function(x) paste(as.character(x), collapse = ""), character(1))
  substr(digest::digest(paste(parts, collapse = ""), algo = "sha256", serialize = FALSE), 1L, 16L)
}

append_decision <- function(paths, decision) {
  missing <- setdiff(LEDGER_FIELDS, names(decision))
  if (length(missing)) stop("Decision missing fields: ", paste(missing, collapse = ", "), call. = FALSE)
  if (!decision$action %in% VALID_ACTIONS) {
    stop("Unsupported action: ", decision$action, call. = FALSE)
  }
  row <- tibble::as_tibble(lapply(decision[LEDGER_FIELDS], function(x) {
    if (length(x) != 1L || is.na(x)) NA_character_ else as.character(x)
  }))
  with_store_lock(paths, {
    existing <- read_ledger(paths)
    write_csv_atomic(dplyr::bind_rows(existing, row), paths$ledger)
  })
  invisible(row)
}

# The ledger is append-only, so a reviewer changing their mind writes a second
# row. Latest decision per (tier, row_key) wins.
latest_decisions <- function(ledger) {
  if (!nrow(ledger)) return(ledger)
  ledger |>
    dplyr::group_by(tier, row_key) |>
    dplyr::slice_tail(n = 1L) |>
    dplyr::ungroup()
}

# ── queue CSV write-back ──────────────────────────────────────────────────────

# Mirror a decision into the queue CSV's decision columns, which is the format
# curate_sponsors.R --export / curate_substances.R --export already read.
write_queue_decision <- function(paths, queue_path, key_col, row_key,
                                 decision, canonical, comment,
                                 canonical_col) {
  with_store_lock(paths, {
    q <- readr::read_csv(queue_path, show_col_types = FALSE, progress = FALSE)
    idx <- which(as.character(q[[key_col]]) == row_key)
    if (!length(idx)) return(invisible(FALSE))
    for (cc in c("decision", canonical_col, "comment")) {
      if (!cc %in% names(q)) q[[cc]] <- NA_character_
    }
    q[["decision"]][idx]      <- decision
    q[[canonical_col]][idx]   <- if (is.na(canonical) || !nzchar(canonical)) NA_character_ else canonical
    q[["comment"]][idx]       <- if (is.na(comment) || !nzchar(comment)) NA_character_ else comment
    write_csv_atomic(q, queue_path, eol = detect_eol(queue_path))
    invisible(TRUE)
  })
}
