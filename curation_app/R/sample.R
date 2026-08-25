# ══════════════════════════════════════════════════════════════════════════════
# THE REVIEW SAMPLE
# ══════════════════════════════════════════════════════════════════════════════
#
# 51,311 trials will never all be validated. A representative sample is drawn
# once and split across the reviewers, and the error rate measured on it is what
# generalises to the corpus.
#
# ── Why stratified, and by what ───────────────────────────────────────────────
#
# "Representative" is not "random": a uniform draw of a few hundred from 51k can
# easily under-represent CTIS or a recent year by chance, and then the measured
# error rate does not describe the corpus.
#
# Stratified by REGISTER × ERA:
#   register — EUCTR and CTIS have different field structures and different
#              failure modes. CTIS phase is free text mapped by regex, EUCTR
#              phase is four boolean flags. An error rate that mixes them
#              describes neither.
#   era      — data quality moves over time and CTIS only exists from 2022, so
#              without this the sample tracks whichever period happens to be
#              largest.
#
# Allocation is PROPORTIONAL: each stratum gets its share of N, so the sample
# mirrors the corpus rather than giving every stratum equal weight. A stratum
# too small to earn a whole trial still gets one if it is non-empty, because a
# stratum absent from the sample is one the error rate says nothing about.
#
# ── Why ~10% is assigned twice ────────────────────────────────────────────────
#
# With a fully disjoint split no two reviewers ever see the same trial, so
# inter-rater agreement cannot be computed and the disagreement report can never
# populate. The overlap is what makes "do our reviewers agree" answerable, and
# it is drawn from the same strata so it stays representative.
#
# ── Deterministic ─────────────────────────────────────────────────────────────
#
# Seeded from the sample_id, so the same id always yields the same draw. A
# sample nobody can reproduce is a sample nobody can check.

trial_era <- function(year) {
  y <- suppressWarnings(as.numeric(year))
  cut(y, breaks = c(-Inf, 2009, 2014, 2019, Inf),
      labels = c("<=2009", "2010-2014", "2015-2019", "2020+"), right = TRUE)
}

# Pure: a data frame in, an assignment table out. No database, no Shiny, so the
# representativeness can be tested directly.
draw_review_sample <- function(trials, reviewers, n = 300L, overlap = 0.10,
                               sample_id = NULL, seed = NULL, label = NULL) {
  stopifnot(length(reviewers) >= 1, n >= 1, overlap >= 0, overlap <= 1)
  if (is.null(sample_id)) sample_id <- format(Sys.time(), "sample-%Y%m%d-%H%M%S", tz = "UTC")
  if (is.null(seed)) seed <- sum(utf8ToInt(sample_id))
  set.seed(seed)

  d <- data.frame(trial_id = trials$`_id`,
                  register = as.character(trials$register),
                  era      = as.character(trial_era(trials$year %||% trials$analysis_year)),
                  stringsAsFactors = FALSE)
  d <- d[!is.na(d$trial_id) & nzchar(d$trial_id), , drop = FALSE]
  d$era[is.na(d$era)] <- "unknown"
  d$stratum <- paste(d$register, d$era, sep = " / ")

  sizes <- table(d$stratum)
  # Proportional, then top up: rounding down every stratum loses trials, and
  # the shortfall goes to the largest strata, which is where it least distorts.
  want <- floor(n * as.numeric(sizes) / sum(sizes))
  want[want < 1 & as.numeric(sizes) > 0] <- 1
  names(want) <- names(sizes)
  short <- n - sum(want)
  if (short > 0) {
    ord <- order(as.numeric(sizes), decreasing = TRUE)
    for (i in seq_len(short)) {
      k <- ord[((i - 1) %% length(ord)) + 1]
      if (want[k] < sizes[k]) want[k] <- want[k] + 1
    }
  }

  picked <- do.call(rbind, lapply(names(want), function(st) {
    pool <- d[d$stratum == st, , drop = FALSE]
    take <- min(want[[st]], nrow(pool))
    if (take < 1) return(NULL)
    pool[sample.int(nrow(pool), take), , drop = FALSE]
  }))
  if (is.null(picked) || !nrow(picked)) return(picked)

  # Shuffle before dealing, so a reviewer's queue is not one stratum followed by
  # another — they should meet the mix as they work, not in blocks.
  picked <- picked[sample.int(nrow(picked)), , drop = FALSE]
  picked$reviewer <- rep(reviewers, length.out = nrow(picked))
  picked$is_overlap <- FALSE
  picked$sample_id <- sample_id
  picked$label <- label %||% sample_id

  n_over <- floor(nrow(picked) * overlap)
  if (n_over > 0 && length(reviewers) > 1) {
    idx <- sample.int(nrow(picked), n_over)
    extra <- picked[idx, , drop = FALSE]
    # A different reviewer, deliberately — assigning the same person twice
    # measures nothing.
    extra$reviewer <- vapply(picked$reviewer[idx], function(r)
      sample(setdiff(reviewers, r), 1L), character(1))
    extra$is_overlap <- TRUE
    picked <- rbind(picked, extra)
  }
  rownames(picked) <- NULL
  picked[, c("sample_id", "label", "trial_id", "reviewer", "stratum", "is_overlap")]
}

# How closely the draw mirrors the corpus. Printed when a sample is drawn, so
# the claim "representative" is checked rather than asserted.
sample_representativeness <- function(trials, picked) {
  d <- data.frame(stratum = paste(trials$register, trial_era(trials$year %||% trials$analysis_year),
                                  sep = " / "), stringsAsFactors = FALSE)
  corpus <- prop.table(table(d$stratum))
  smp <- prop.table(table(unique(picked[, c("trial_id", "stratum")])$stratum))
  all_st <- union(names(corpus), names(smp))
  data.frame(
    stratum      = all_st,
    corpus_pct   = round(100 * as.numeric(corpus[all_st]), 2),
    sample_pct   = round(100 * as.numeric(smp[all_st]), 2),
    row.names    = NULL
  ) |> within({
    corpus_pct[is.na(corpus_pct)] <- 0
    sample_pct[is.na(sample_pct)] <- 0
    diff_pp <- round(sample_pct - corpus_pct, 2)
  })
}

sample_store <- function(con, picked) {
  if (is.null(picked) || !nrow(picked)) return(invisible(0L))
  DBI::dbWriteTable(con, "review_sample", picked, append = TRUE, row.names = FALSE)
  invisible(nrow(picked))
}

# Every draw this reviewer has rows in, newest first. They choose which round
# they are working on — a validation can be redone, and the old one has to stay
# readable while the new one runs.
sample_choices_for_reviewer <- function(con, username) {
  DBI::dbGetQuery(con, "
    SELECT sample_id, COALESCE(max(label), sample_id) AS label,
           min(drawn_at_utc) AS drawn, count(*) AS assigned
    FROM review_sample
    WHERE reviewer = $1 AND retired_at_utc IS NULL
    GROUP BY sample_id ORDER BY drawn DESC", params = list(username))
}

sample_for_reviewer <- function(con, username, sample_id = NULL) {
  if (!is.null(sample_id) && !nzchar(sample_id)) sample_id <- NULL
  if (is.null(sample_id)) {
    DBI::dbGetQuery(con, "
      SELECT s.* FROM review_sample s
      WHERE s.reviewer = $1 AND s.retired_at_utc IS NULL
        AND s.sample_id = (SELECT sample_id FROM review_sample
                           WHERE retired_at_utc IS NULL
                           ORDER BY drawn_at_utc DESC LIMIT 1)",
      params = list(username))
  } else {
    DBI::dbGetQuery(con,
      "SELECT * FROM review_sample
       WHERE reviewer = $1 AND sample_id = $2 AND retired_at_utc IS NULL",
      params = list(username, sample_id))
  }
}

# Undo a draw.
#
# Refuses once work has been done against it: deleting the assignment would
# orphan sign-offs and decisions that were made BECAUSE a trial was assigned,
# and the agreement figures are computed from the overlap in this table. A draw
# nobody has touched is free to remove; one with reviews behind it is not, and
# the right move there is to draw a new sample rather than erase the record of
# the old one.
sample_delete <- function(con, sample_id, force = FALSE, by = NA_character_) {
  n_rev <- as.numeric(DBI::dbGetQuery(con, "
    SELECT count(*) n FROM trial_reviews r
    WHERE EXISTS (SELECT 1 FROM review_sample s
                  WHERE s.sample_id = $1 AND s.trial_id = r.trial_id
                    AND s.reviewer = r.reviewer)", params = list(sample_id))$n)
  if (n_rev > 0 && !force)
    stop(sprintf("%d trial(s) in this sample have already been reviewed. Draw a new sample instead, or force it deliberately.",
                 n_rev), call. = FALSE)
  # UPDATE, not DELETE. The app role has no DELETE on anything and this keeps
  # it that way; the row survives as the record of what was assigned.
  n <- DBI::dbExecute(con, "
    UPDATE review_sample SET retired_at_utc = now(), retired_by = $2
    WHERE sample_id = $1 AND retired_at_utc IS NULL",
    params = list(sample_id, by))
  list(deleted = n, reviews_orphaned = if (force) n_rev else 0)
}

# How much work exists against each draw, so the admin can see what deleting
# one would cost before doing it.
sample_ids_with_work <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT s.sample_id,
           COALESCE(max(s.label), s.sample_id) AS label,
           min(s.drawn_at_utc)                 AS drawn,
           count(*)                            AS assignments,
           count(DISTINCT s.trial_id)          AS trials,
           (SELECT count(*) FROM trial_reviews r
             WHERE EXISTS (SELECT 1 FROM review_sample x
                           WHERE x.sample_id = s.sample_id AND x.trial_id = r.trial_id
                             AND x.reviewer = r.reviewer)) AS reviewed
    FROM review_sample s WHERE s.retired_at_utc IS NULL
    GROUP BY s.sample_id ORDER BY drawn DESC")
}

sample_progress <- function(con) {
  DBI::dbGetQuery(con, "SELECT * FROM review_sample_progress ORDER BY sample_id DESC, reviewer")
}

sample_ids <- function(con) {
  DBI::dbGetQuery(con, "SELECT sample_id, min(drawn_at_utc) drawn, count(*) rows_
                        FROM review_sample WHERE retired_at_utc IS NULL
                        GROUP BY sample_id ORDER BY drawn DESC")
}
