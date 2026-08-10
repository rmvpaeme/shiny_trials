# Replay every derivation rule against the frozen decisions.
#
# This is the acceptance gate for helper_scripts/*/derive_*_canonical.R. For
# each rule it reports, over the whole corpus of (raw, final) pairs:
#
#   agree     rule reproduces the frozen canonical exactly
#   cosmetic  same entity, different capitalisation
#   conflict  rule produces a DIFFERENT entity — the rule is unsafe, or the
#             frozen row is wrong
#   no-op     rule declines
#
# Ship a rule only when its conflict rate is near zero. The report is committed
# as report.md; a rule change that moves these numbers shows up in the diff.
#
# What "agree" does and does not mean: these rules are judged against decisions
# that were made, not against decisions that are right. The gold fixtures in
# tests/fixtures/ are the correctness check; this is the reproducibility check.
#
# Usage:
#   Rscript tests/derivation/replay.R
#   Rscript tests/derivation/replay.R --write-report
#   Rscript tests/derivation/replay.R --held-out=0.10

suppressPackageStartupMessages({
  library(dplyr)
  library(stringr)
  library(readr)
  library(purrr)
  library(tibble)
})

script_path <- local({
  cmd_args   <- commandArgs(FALSE)
  script_arg <- cmd_args[grepl("^--file=", cmd_args)]
  if (length(script_arg)) {
    return(normalizePath(sub("^--file=", "", script_arg[[1]]), mustWork = TRUE))
  }
  NA_character_
})
project_root <- if (!is.na(script_path)) {
  normalizePath(file.path(dirname(script_path), "..", ".."), mustWork = TRUE)
} else {
  getwd()
}
project_path <- function(...) file.path(project_root, ...)

args <- commandArgs(trailingOnly = TRUE)
write_report <- "--write-report" %in% args
held_out_fraction <- local({
  v <- args[startsWith(args, "--held-out=")]
  if (length(v) == 0L) 0.10 else as.numeric(sub("^--held-out=", "", v[[1]]))
})

source(project_path("tests", "derivation", "corpus.R"), local = FALSE)
source(project_path("helper_scripts", "sponsor_norm_pipeline",
                    "derive_sponsor_canonical.R"), local = FALSE)
source(project_path("helper_scripts", "substance_norm_pipeline",
                    "derive_substance_canonical.R"), local = FALSE)

# ── outcome classification ────────────────────────────────────────────────────

classify_outcome <- function(derived, expected, casefold_fn) {
  if (is.na(derived)) return("no-op")
  if (identical(derived, expected)) return("agree")
  if (identical(casefold_fn(derived), casefold_fn(expected))) return("cosmetic")
  "conflict"
}

.sponsor_fold   <- function(x) clean_sponsor_alias(x)
.substance_fold <- function(x) clean_alias(x)

summarise_outcomes <- function(outcomes) {
  n <- length(outcomes)
  counts <- table(factor(outcomes, levels = c("agree", "cosmetic", "conflict", "no-op")))
  tibble::tibble(
    rows      = n,
    agree     = as.integer(counts[["agree"]]),
    cosmetic  = as.integer(counts[["cosmetic"]]),
    conflict  = as.integer(counts[["conflict"]]),
    no_op     = as.integer(counts[["no-op"]]),
    agree_pct    = 100 * agree / n,
    cosmetic_pct = 100 * cosmetic / n,
    conflict_pct = 100 * conflict / n
  )
}

# Two denominators, because they answer different questions.
#
#   whole corpus     — includes the substitution pairs (brand → INN, department
#                      → parent institution) that no rule can ever produce. A
#                      rule scores no-op on almost all of these, so its conflict
#                      rate here is the honest "how often would this rule
#                      contradict a frozen decision if applied blind".
#   mineable subset  — the identical + removal pairs, i.e. the pairs where the
#                      answer IS derivable from the input.
.mineable_kinds <- c("identical", "removal")

# Per-rule safety, and why agree/conflict is the wrong gate for a single rule.
#
# The rules compose: on "imatinib mesylate 100 mg tablet", dose_form correctly
# produces "imatinib mesylate" and salt_form then finishes the job. Scored alone
# against the expected "imatinib", dose_form's correct partial reduction counts
# as a conflict — so a rule that is doing exactly what it should can never reach
# the "conflict ~0" bar, and the bar would select for rules that do nothing.
#
# What actually makes a reduction rule unsafe is destroying material the answer
# needs. That is what this measures: a firing is DESTRUCTIVE when the rule
# removed a token that the frozen answer still contains.
#
#   "amg 706" → "amg"                 destructive (a research code lost its number)
#   "[68ga]fapi-46" → "68ga]fapi-46"  destructive (mangled the name)
#   "timolol maleate," → "timolol maleate"  benign (only punctuation went)
#
# agree/cosmetic/conflict is still the right frame for the PIPELINE, which is
# what ships, and is reported for it below.
rule_safety <- function(raw_vec, expected, derived, casefold_fn) {
  fired <- !is.na(derived)
  if (!any(fired)) {
    return(tibble::tibble(
      fires = 0L, agree = 0L, benign = 0L, destructive = 0L,
      destructive_pct = 0
    ))
  }

  # Fold all three sides the same way first: the rule returns a title-cased
  # label, and comparing that to a lowercase input would read every token as
  # removed.
  tok <- function(x) stringr::str_split(casefold_fn(x), "\\s+")
  raw_toks      <- tok(raw_vec[fired])
  derived_toks  <- tok(derived[fired])
  expected_toks <- tok(expected[fired])

  destroyed <- purrr::pmap_lgl(
    list(raw_toks, derived_toks, expected_toks),
    function(r, d, e) {
      # Single characters are excluded: the cleaner turns "A.C.R.A.F." into
      # "a c r a f", so an initialism shares a bare "a" with the "s p a" that
      # legal_suffix correctly removed, and every such row reads as destroyed.
      removed <- setdiff(r, d)
      removed <- removed[nchar(removed) > 1L]
      length(intersect(removed, e)) > 0L
    }
  )
  agreed <- casefold_fn(derived[fired]) == casefold_fn(expected[fired])

  # Note the names: `agree = sum(agreed)` inside tibble() would shadow `agreed`
  # for every later expression, since tibble() evaluates its arguments in order.
  tibble::tibble(
    fires       = sum(fired),
    agree       = sum(agreed),
    benign      = sum(!agreed & !destroyed),
    destructive = sum(destroyed),
    destructive_pct = 100 * sum(destroyed) / sum(fired)
  )
}

# ── sponsor replay ────────────────────────────────────────────────────────────

replay_sponsors <- function(pairs) {
  rules <- c("case_punct", names(.sponsor_reduction_steps))
  mineable <- classify_pairs(pairs) %in% .mineable_kinds

  outcomes_for <- function(derived) {
    purrr::map2_chr(
      derived, pairs$final, classify_outcome, casefold_fn = .sponsor_fold
    )
  }

  per_rule <- purrr::map_dfr(rules, function(rule_id) {
    derived <- purrr::map_chr(
      pairs$raw, ~ derive_sponsor_rule(.x, rule_id)$derived[[1L]]
    )
    outcomes <- outcomes_for(derived)
    dplyr::bind_rows(
      dplyr::bind_cols(
        tibble::tibble(rule = rule_id, scope = "corpus"),
        summarise_outcomes(outcomes)
      ),
      dplyr::bind_cols(
        tibble::tibble(rule = rule_id, scope = "mineable"),
        summarise_outcomes(outcomes[mineable])
      )
    )
  })

  safety <- purrr::map_dfr(rules, function(rule_id) {
    derived <- purrr::map_chr(
      pairs$raw, ~ derive_sponsor_rule(.x, rule_id)$derived[[1L]]
    )
    # Compare on the cleaned raw, since that is what the rule was handed.
    dplyr::bind_cols(
      tibble::tibble(rule = rule_id),
      rule_safety(pairs$raw_clean, pairs$final, derived, .sponsor_fold)
    )
  })

  pipeline <- derive_sponsor_canonical(pairs$raw)
  pipeline_outcomes <- outcomes_for(pipeline$derived)

  list(
    per_rule  = per_rule,
    safety    = safety,
    mineable  = mineable,
    pipeline  = dplyr::bind_rows(
      dplyr::bind_cols(
        tibble::tibble(rule = "PIPELINE", scope = "corpus"),
        summarise_outcomes(pipeline_outcomes)
      ),
      dplyr::bind_cols(
        tibble::tibble(rule = "PIPELINE", scope = "mineable"),
        summarise_outcomes(pipeline_outcomes[mineable])
      )
    ),
    detail    = tibble::tibble(
      raw = pairs$raw, expected = pairs$final,
      derived = pipeline$derived, rule_id = pipeline$rule_id,
      outcome = pipeline_outcomes, mineable = mineable
    )
  )
}

# ── substance replay ──────────────────────────────────────────────────────────

replay_substances <- function(pairs, canonical) {
  salt_tokens <- unique(c(mine_salt_tokens(canonical), .extra_salt_tokens))
  rules <- c("case_punct", names(.substance_reduction_steps(salt_tokens)))
  mineable <- classify_pairs(pairs) %in% .mineable_kinds

  outcomes_for <- function(derived) {
    purrr::map2_chr(
      derived, pairs$final, classify_outcome, casefold_fn = .substance_fold
    )
  }

  per_rule <- purrr::map_dfr(rules, function(rule_id) {
    derived <- purrr::map_chr(
      pairs$raw, ~ derive_substance_rule(.x, rule_id, salt_tokens)$derived[[1L]]
    )
    outcomes <- outcomes_for(derived)
    dplyr::bind_rows(
      dplyr::bind_cols(
        tibble::tibble(rule = rule_id, scope = "corpus"),
        summarise_outcomes(outcomes)
      ),
      dplyr::bind_cols(
        tibble::tibble(rule = rule_id, scope = "mineable"),
        summarise_outcomes(outcomes[mineable])
      )
    )
  })

  safety <- purrr::map_dfr(rules, function(rule_id) {
    derived <- purrr::map_chr(
      pairs$raw, ~ derive_substance_rule(.x, rule_id, salt_tokens)$derived[[1L]]
    )
    dplyr::bind_cols(
      tibble::tibble(rule = rule_id),
      rule_safety(pairs$raw_clean, pairs$final, derived, .substance_fold)
    )
  })

  pipeline <- derive_substance_canonical(pairs$raw, canonical = canonical)
  pipeline_outcomes <- outcomes_for(pipeline$derived)

  list(
    per_rule = per_rule,
    safety   = safety,
    mineable = mineable,
    pipeline = dplyr::bind_rows(
      dplyr::bind_cols(
        tibble::tibble(rule = "PIPELINE", scope = "corpus"),
        summarise_outcomes(pipeline_outcomes)
      ),
      dplyr::bind_cols(
        tibble::tibble(rule = "PIPELINE", scope = "mineable"),
        summarise_outcomes(pipeline_outcomes[mineable])
      )
    ),
    detail   = tibble::tibble(
      raw = pairs$raw, expected = pairs$final,
      derived = pipeline$derived, rule_id = pipeline$rule_id,
      outcome = pipeline_outcomes, mineable = mineable
    )
  )
}

# ── formatting ────────────────────────────────────────────────────────────────

fmt_table <- function(tbl, scope) {
  tbl <- dplyr::filter(tbl, scope == !!scope)
  lines <- c(
    "| Rule | Rows | agree | cosmetic | conflict | no-op |",
    "|---|---:|---:|---:|---:|---:|"
  )
  for (i in seq_len(nrow(tbl))) {
    r <- tbl[i, ]
    lines <- c(lines, sprintf(
      "| `%s` | %d | %d (%.1f%%) | %d (%.1f%%) | **%d (%.1f%%)** | %d |",
      r$rule, r$rows,
      r$agree, r$agree_pct, r$cosmetic, r$cosmetic_pct,
      r$conflict, r$conflict_pct, r$no_op
    ))
  }
  lines
}

fmt_safety <- function(tbl) {
  lines <- c(
    "| Rule | Fires | agree | benign | destructive |",
    "|---|---:|---:|---:|---:|"
  )
  for (i in seq_len(nrow(tbl))) {
    r <- tbl[i, ]
    lines <- c(lines, sprintf(
      "| `%s` | %d | %d | %d | **%d (%.1f%%)** |",
      r$rule, r$fires, r$agree, r$benign, r$destructive, r$destructive_pct
    ))
  }
  lines
}

fmt_examples <- function(detail, want, n = 8L, mineable_only = FALSE) {
  rows <- detail |>
    dplyr::filter(outcome == want)
  if (mineable_only) rows <- dplyr::filter(rows, mineable)
  rows <- rows |> dplyr::arrange(raw) |> head(n)
  if (nrow(rows) == 0L) return("_none_")
  c(
    "| raw | expected | derived | rule |",
    "|---|---|---|---|",
    sprintf("| `%s` | `%s` | `%s` | `%s` |",
            rows$raw, rows$expected, rows$derived, rows$rule_id)
  )
}

# ── run ───────────────────────────────────────────────────────────────────────

message("Loading frozen-decision corpus...")
sponsor_pairs   <- load_sponsor_corpus(project_root)
substance_pairs <- load_substance_corpus(project_root)
canonical <- readr::read_csv(
  project_path("config", "substance_norm_pipeline", "canonical_substances.csv"),
  show_col_types = FALSE
)

message(sprintf("Sponsors: %d pairs. Substances: %d pairs.",
                nrow(sponsor_pairs), nrow(substance_pairs)))

message("Replaying sponsor rules...")
sponsor_res <- replay_sponsors(sponsor_pairs)
message("Replaying substance rules...")
substance_res <- replay_substances(substance_pairs, canonical)

# Held-out check: the rules carry no fitted parameters, so agreement on unseen
# rows should match agreement overall. A gap would mean a rule is memorising the
# corpus — e.g. via a suffix list mined so finely it only matches known strings.
sponsor_mask   <- held_out_mask(sponsor_pairs$raw_clean, held_out_fraction)
substance_mask <- held_out_mask(substance_pairs$raw_clean, held_out_fraction)

held_out_summary <- function(detail, mask, label) {
  # Measured on the mineable subset, the rules' actual domain: agreement over
  # the whole corpus is dominated by how much of it is entity resolution, which
  # would drown out the signal this check is looking for.
  keep <- detail$mineable
  mask <- mask[keep]
  outcome <- detail$outcome[keep]
  tibble::tibble(
    corpus = label,
    slice  = c(
      sprintf("in-sample (%.0f%%)", 100 * (1 - held_out_fraction)),
      sprintf("held-out (%.0f%%)", 100 * held_out_fraction)
    ),
    rows   = c(sum(!mask), sum(mask)),
    agree_pct = c(
      100 * mean(outcome[!mask] == "agree"),
      100 * mean(outcome[mask]  == "agree")
    ),
    conflict_pct = c(
      100 * mean(outcome[!mask] == "conflict"),
      100 * mean(outcome[mask]  == "conflict")
    )
  )
}

held <- dplyr::bind_rows(
  held_out_summary(sponsor_res$detail, sponsor_mask, "Sponsors"),
  held_out_summary(substance_res$detail, substance_mask, "Substances")
)

report <- c(
  "# Derivation replay report",
  "",
  "Generated by `Rscript tests/derivation/replay.R --write-report`. Committed as",
  "the acceptance record for the derivation rules: a rule change that moves these",
  "numbers should be visible in the diff.",
  "",
  "**What this measures.** Each rule is replayed against every (raw, final) pair",
  "the committed config still holds — decisions that were made once, mostly by an",
  "LLM, and then frozen. `agree` therefore means *reproduces the frozen decision*,",
  "not *is correct*. Correctness is what `tests/fixtures/` checks.",
  "",
  sprintf("Corpus: %d sponsor pairs, %d substance pairs, read from committed config only.",
          nrow(sponsor_pairs), nrow(substance_pairs)),
  "",
  "**Two denominators.** *Corpus* is every pair, including the substitutions",
  "(`Humira` → `adalimumab`, a department → its parent institution) whose output",
  "shares no material with its input. No rule will ever produce those, so a rule",
  "should score `no-op` on them, and its conflict rate over the whole corpus is",
  "the honest answer to \"how often would this contradict a frozen decision if",
  "applied blind\". *Mineable* is the identical + removal pairs — the subset where",
  "the answer is recoverable from the input at all. That is each rule's actual",
  "domain and the denominator the ship gate uses.",
  "",
  sprintf("Mineable share: sponsors %.1f%%, substances %.1f%%.",
          100 * mean(sponsor_res$mineable), 100 * mean(substance_res$mineable)),
  "",
  "## Sponsors",
  "",
  "### Rule safety — the ship gate",
  "",
  "`destructive` is a firing that removed a token the frozen answer still",
  "contains. That is the failure mode a reduction rule can actually cause; a",
  "correct *partial* reduction ('imatinib mesylate 100 mg' → 'imatinib",
  "mesylate') is counted as `benign`, not as a miss, because the next rule in",
  "the pipeline finishes it.",
  "",
  fmt_safety(sponsor_res$safety),
  "",
  "### Per rule, applied alone — mineable pairs",
  "",
  fmt_table(sponsor_res$per_rule, "mineable"),
  "",
  "### Per rule, applied alone — whole corpus",
  "",
  fmt_table(sponsor_res$per_rule, "corpus"),
  "",
  "### All rules composed, in pipeline order",
  "",
  fmt_table(sponsor_res$pipeline, "mineable"),
  "",
  fmt_table(sponsor_res$pipeline, "corpus"),
  "",
  "### Cosmetic disagreements",
  "",
  "Why derived rows are `review` and never `accepted`: the rule cannot know that",
  "`89bio` is lowercase-b or `4TEEN4` is all-caps. That is brand styling, not a",
  "pattern.",
  "",
  fmt_examples(sponsor_res$detail, "cosmetic"),
  "",
  "### Conflicts on mineable pairs",
  "",
  "These are the ones worth reading: the answer *was* derivable and a rule got it",
  "wrong, or the frozen row is wrong.",
  "",
  fmt_examples(sponsor_res$detail, "conflict", mineable_only = TRUE),
  "",
  "## Substances",
  "",
  "### Rule safety — the ship gate",
  "",
  fmt_safety(substance_res$safety),
  "",
  "### Per rule, applied alone — mineable pairs",
  "",
  fmt_table(substance_res$per_rule, "mineable"),
  "",
  "### Per rule, applied alone — whole corpus",
  "",
  fmt_table(substance_res$per_rule, "corpus"),
  "",
  "### All rules composed, in pipeline order",
  "",
  fmt_table(substance_res$pipeline, "mineable"),
  "",
  fmt_table(substance_res$pipeline, "corpus"),
  "",
  "### Conflicts on mineable pairs",
  "",
  fmt_examples(substance_res$detail, "conflict", mineable_only = TRUE),
  "",
  "## Held-out check",
  "",
  "The split is a hash of the raw string, not a random sample, so it is stable",
  "across runs. These rules fit no parameters to the corpus, so the two slices",
  "should agree; a gap would mean a rule had been tuned until it memorised known",
  "strings. Measured on the mineable subset — see the note above.",
  "",
  "| Corpus | Slice | Rows | agree | conflict |",
  "|---|---|---:|---:|---:|",
  sprintf("| %s | %s | %d | %.1f%% | %.1f%% |",
          held$corpus, held$slice, held$rows, held$agree_pct, held$conflict_pct),
  ""
)

cat(paste(report, collapse = "\n"))

if (write_report) {
  report_path <- project_path("tests", "derivation", "report.md")
  writeLines(report, report_path)
  message(sprintf("\nWrote %s", report_path))
}

# Non-zero exit when a reduction rule is destructive, so this can gate CI.
#
# `case_punct` is excluded, and deliberately. It is not a reduction — it is the
# terminal case "no rule fired, so the cleaned raw string is the answer", and it
# removes nothing, so it cannot be destructive. It also replaces a fallback that
# today copies the raw string with no cleaning and no title-casing at all, so
# where it disagrees with the table that is the pre-existing fallback being
# measured for the first time, not a regression introduced here.
#
# The threshold is not zero: some frozen rows are themselves wrong (the 19
# known-failing gold fixtures are the evidence), and a rule that produces the
# right answer where the table holds a wrong one is counted destructive here.
.destructive_threshold <- 5

worst <- dplyr::bind_rows(
  dplyr::mutate(sponsor_res$safety, corpus = "sponsor"),
  dplyr::mutate(substance_res$safety, corpus = "substance")
) |>
  dplyr::filter(rule != "case_punct") |>
  dplyr::arrange(dplyr::desc(destructive_pct)) |>
  dplyr::slice(1)

if (worst$destructive_pct > .destructive_threshold) {
  message(sprintf(
    "\nFAIL: %s rule `%s` is destructive on %.1f%% of its firings (threshold %d%%).",
    worst$corpus, worst$rule, worst$destructive_pct, .destructive_threshold
  ))
  quit(status = 1L)
}
message(sprintf(
  "\nOK: worst reduction-rule destructive rate is %.1f%% (%s `%s`).",
  worst$destructive_pct, worst$corpus, worst$rule
))
