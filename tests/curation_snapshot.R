# The snapshot fetch is atomic, validated, and degrades instead of dying.
#
#   Rscript tests/curation_snapshot.R          # small files only
#   FETCH_CACHE=1 Rscript tests/curation_snapshot.R   # + the 16.7 MB cache
#
# Hits the real public repo. Skips (exit 2) when GitHub is unreachable, because
# "the network is down" is not a code failure.

source("curation_app/R/github.R")

failures <- character()
check <- function(cond, msg) {
  if (isTRUE(cond)) cat(sprintf("  ok    %s\n", msg))
  else { cat(sprintf("  FAIL  %s\n", msg)); failures <<- c(failures, msg) }
}

r <- tryCatch(resolve_sha(), error = function(e) e)
if (inherits(r, "error")) {
  message("COULD NOT MEASURE: ", conditionMessage(r))
  quit(save = "no", status = 2L)
}
cat(sprintf("resolved %s -> %s (%s)\n\n", GITHUB_REF, substr(r$sha, 1, 8), r$committed_at))
check(grepl("^[0-9a-f]{40}$", r$sha), "resolve_sha returns a full 40-char sha")

# Small files only by default: the point is the mechanism, not the bandwidth.
small <- Filter(function(f) f$path != "trials_cache.rds", SNAPSHOT_FILES)
if (nzchar(Sys.getenv("FETCH_CACHE"))) small <- SNAPSHOT_FILES

snap <- tryCatch(fetch_snapshot(r$sha, files = small), error = function(e) e)
check(!inherits(snap, "error"),
      if (inherits(snap, "error")) paste("fetch failed:", conditionMessage(snap))
      else "fetch_snapshot succeeds against the live repo")
if (inherits(snap, "error")) quit(save = "no", status = 1L)

check(dir.exists(snap$dir), "snapshot directory exists")
check(identical(snap$sha, r$sha), "snapshot records the sha it fetched")
check(!snap$degraded, "a good fetch is not degraded")

req <- vapply(Filter(function(f) isTRUE(f$required), small), function(f) f$path, character(1))
check(all(req %in% snap$files), "every required file landed")
for (p in req) {
  fp <- file.path(snap$dir, p)
  check(file.exists(fp) && file.size(fp) > 0, sprintf("%s is non-empty", basename(p)))
}

# The optional file is expected to be absent until export.R first runs. It must
# be reported, not silently ignored, and must not fail the fetch.
check("data/trial_overrides.csv" %in% c(snap$files, snap$missing_optional),
      "the optional overrides file is accounted for either way")

# The queues must parse and carry the columns the review tab needs.
q <- read.csv(file.path(snap$dir, "config/sponsor_norm_v2/E_review_queue.csv"),
              stringsAsFactors = FALSE, nrows = 50)
check(all(c("raw_sponsor", "proposed", "confidence", "n_trials", "review_reason") %in% names(q)),
      "the sponsor queue has the expected columns")
reg <- read.csv(file.path(snap$dir, "config/sponsor_norm_v2/registry.csv"),
                stringsAsFactors = FALSE, nrows = 50)
check(all(c("entity_id", "canonical", "decided_by", "merged_into") %in% names(reg)),
      "the sponsor registry has the expected columns")

if (nzchar(Sys.getenv("FETCH_CACHE"))) {
  d <- readRDS(file.path(snap$dir, "trials_cache.rds"))
  check(nrow(d) > 1000 && "_id" %in% names(d), "the fetched cache reads back as trial data")
}

# A required file that does not exist must fail the WHOLE fetch and leave
# nothing behind — a half-populated directory must never become the snapshot.
bogus <- list(list(path = "no/such/file.csv", mode = "w", required = TRUE))
d0 <- file.path(tempdir(), "snap-should-not-survive")
bad <- tryCatch(fetch_snapshot(r$sha, files = bogus, dest = d0), error = function(e) e)
check(inherits(bad, "error"), "a missing REQUIRED file fails the fetch")
check(!dir.exists(d0), "a failed fetch leaves no directory behind")

# Degraded mode: keep the last good snapshot rather than serving nothing.
.snapshot$current <- snap
res <- snapshot_refresh(repo = "rmvpaeme/definitely-not-a-real-repo")
check(!is.null(snapshot_current()), "a failed refresh keeps the previous snapshot")
check(isTRUE(snapshot_current()$degraded), "the kept snapshot is marked degraded")
check(nzchar(snapshot_current()$degraded_reason %||% ""), "the degraded reason is recorded")
check(identical(snapshot_current()$sha, snap$sha), "the kept snapshot is the previous SHA")

# With nothing to fall back on it must return NULL, not error.
.snapshot$current <- NULL
res2 <- tryCatch(snapshot_refresh(repo = "rmvpaeme/definitely-not-a-real-repo"),
                 error = function(e) e)
check(!inherits(res2, "error"), "a first-ever failed fetch does not throw")
check(is.null(snapshot_current()), "and leaves no snapshot")

cat("\n")
if (length(failures)) { cat(sprintf("%d check(s) failed\n", length(failures))); quit(save = "no", status = 1L) }
cat("all checks passed\n")
