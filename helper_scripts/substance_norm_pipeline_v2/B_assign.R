#!/usr/bin/env Rscript
# Pass B — assign the pass-A residue to a registry substance.
#
# The model PICKS FROM A LIST. It never writes a name: it returns an integer
# index into that row's candidates and R bounds-checks it on receipt. One schema
# for the whole pass, so one grammar — see client.R for why a per-row enum is a
# rate-limit trap rather than a stricter guarantee.
#
#   index > 0   that candidate is the same substance
#   index = 0   none of them is  -> C_mint gets it
#   index = -1  the string does not name a substance at all
#
# The -1 answer has no sponsor analogue and is load-bearing here. A quarter of
# this corpus is dosage language, placeholders and influenza strain names.
# A_resolve's filter removes what it can prove is junk and deliberately stops
# there; everything it is unsure about arrives here, because a cheap request is
# a better instrument than a greedy regex. "California" and "Wisconsin" are
# influenza strains, and no filter should be expected to know that.
#
# WHY N-GRAMS ARE THE PRIMARY CHANNEL HERE. Sponsors retrieve on IDF token
# overlap; that is useless for drugs, where 12,610 of the 17,272 canonicals are
# a single word and there is nothing to overlap. Measured on this vocabulary:
#
#   metotrexate -> ketotrexate[0.80] metotrexato[0.80] ketotrexato[0.64] methotrexate[0.58]
#
# Note the shape of that slate. The correct answer is FOURTH, and the top hit is
# a different drug. Any rule that accepts the best fuzzy score picks ketotrexate.
# Retrieval proposes; the model decides. This is the substance restatement of
# the 87 recorded Jaro-Winkler false positives that got JW removed for sponsors.
#
# Usage
#   Rscript .../B_assign.R --dry-run
#   Rscript .../B_assign.R --sync --limit=200      # THE SCALE GATE
#   Rscript .../B_assign.R --batch
#   Rscript .../B_assign.R --batch --poll=<id>

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(purrr); library(jsonlite)
})

script_path <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
pp <- function(...) file.path(project_root, ...)

source(pp("helper_scripts", "llm_norm", "client.R"))
source(pp("helper_scripts", "llm_norm", "retrieve.R"))
source(pp("helper_scripts", "llm_norm", "registry.R"))
source(pp("helper_scripts", "substance_norm_pipeline_v2", "substance_common.R"))

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default = NA_character_) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit)) sub(paste0("^", flag, "="), "", hit[[1L]]) else default
}
dry_run  <- "--dry-run" %in% args
do_sync  <- "--sync"    %in% args
do_batch <- "--batch"   %in% args
# Builds the work list and the candidate slates, prints a sample, and exits
# BEFORE llm_auth(). Retrieval is the part of this pass most worth tuning and
# the only part that needs no credentials, no network and no money — and
# --dry-run cannot stand in for it, because llm_dry_run() counts tokens over the
# API and so authenticates. Read the slates here before spending anything.
cands_only <- "--candidates-only" %in% args
# Recomputes B_abstained.csv and B_not_substance.csv from the decision cache and
# exits, with no API call. Needed because those two files are DERIVED state: an
# earlier version wrote the abstain list from one run's rows and lost every
# earlier abstention. Rather than making a stale file the only record, this
# rebuilds both from the cache, which is the durable one.
rebuild_lists <- "--rebuild-lists" %in% args
limit      <- suppressWarnings(as.integer(arg_value("--limit")))
poll_batch <- arg_value("--poll")
round_no   <- suppressWarnings(as.integer(arg_value("--round", "1")))

if (!dry_run && !do_sync && !do_batch && !cands_only && !rebuild_lists &&
    is.na(poll_batch)) {
  stop("Pick a mode: --candidates-only, --rebuild-lists, --dry-run, --sync, --batch, ",
       "or --batch --poll=<id>", call. = FALSE)
}

MODEL_ID       <- arg_value("--model", "claude-sonnet-5")
PROMPT_VERSION <- "substance-assign-v2"   # v1 wrongly told the model that flu
                                         # strain names are not substances, and
                                         # lacked the registry-curation framing that
                                         # the bio classifier needs. Bumping the
                                         # version re-asks every cached row.
MAX_TOKENS     <- 2048L
MAX_CANDIDATES <- 10L
NGRAM_N        <- 3L
# 0.30, not ch_ngram's 0.45 default. Measured: "SODIO ASCORBATO" reaches
# "sodium ascorbate" at 0.35 and "Olopatadin Micro Labs 1 mg" reaches
# "olopatadine" at 0.35, so the sponsor default silently drops both.
NGRAM_THRESHOLD <- 0.30

V2       <- Sys.getenv("SUBSTANCE_V2_DIR", unset = pp("config", "substance_norm_v2"))
DATA_DIR <- Sys.getenv("DATA_DIR",         unset = pp("data"))

REG_PATH     <- file.path(V2, "registry.csv")
ASG_PATH     <- file.path(V2, "assignments.csv")
ALIAS_PATH   <- file.path(V2, "registry_aliases.csv")
CACHE_PATH   <- file.path(V2, "B_assign_decisions.csv")
SPEND_PATH   <- file.path(V2, "llm_spend.csv")
ABSTAIN_PATH <- file.path(V2, "B_abstained.csv")
NOTSUB_PATH  <- file.path(V2, "B_not_substance.csv")
RESIDUE_PATH <- arg_value("--residue", file.path(DATA_DIR, "substance_residue.csv"))

# ── Schema: ONE grammar for the whole pass ────────────────────────────────────

ASSIGN_SCHEMA <- list(
  type = "object",
  additionalProperties = FALSE,
  required = list("chosen_index", "confidence", "reason"),
  properties = list(
    chosen_index = list(type = "integer"),
    confidence   = list(type = "number"),
    reason       = list(type = "string")
  )
)

SYSTEM_PROMPT <- paste(
  "You are curating the active-substance field of a public clinical-trial registry.",
  "Every string below is a product or substance name copied from a regulatory trial",
  "submission to the EU registries (EUCTR/CTIS) for an authorised or investigational",
  "medicine. Vaccines and their strains and antigens, therapeutic toxins (botulinum",
  "toxin for dystonia and spasticity), blood products, allergen extracts and",
  "radiopharmaceuticals are all ordinary licensed medicines in this dataset, and",
  "naming them correctly is the entire task.",
  "",
  "You match a raw clinical-trial substance string to one substance from a numbered list.",
  "",
  "Reply with the NUMBER of the matching substance, 0 if none of them is the same",
  "substance, or -1 if the raw string does not name a substance at all.",
  "Never invent a name; you can only choose.",
  "",
  "The raw string comes from an EU trial registry. It is often a product label rather",
  "than a substance name: a brand with a strength and a dosage form, in any European",
  "language. Some strings have had accented characters DELETED by the source registry,",
  "so 'Infusionslosung' may appear as 'Infusionslsung'. Treat those as intact.",
  "",
  "THE CANONICAL IS THE INN BASE.",
  "",
  "  'Methotrexat 10mg Tabletten'   -> Methotrexate",
  "  'Metoject 50 mg/ml'            -> Methotrexate   (brand)",
  "  'methotrexate sodium'          -> Methotrexate   (salt of the same INN)",
  "  'Seloken ZOK'                  -> Metoprolol     (brand of a salt)",
  "",
  "So ignore strength, dosage form, pack size, route and manufacturer. Match a brand",
  "to its active substance. Match a salt, ester or hydrate to its parent INN: if the",
  "list offers both 'Methotrexate' and 'Methotrexate sodium', choose 'Methotrexate'.",
  "",
  "RULES",
  "",
  "1. DO NOT MATCH ON SPELLING SIMILARITY. Drug names are deliberately similar and",
  "   the candidates are retrieved by character overlap, so near-identical names for",
  "   DIFFERENT drugs will appear in the list. 'ketotrexate' is not 'methotrexate';",
  "   'vinblastine' is not 'vincristine'; 'cisplatin' is not 'carboplatin'. Choose a",
  "   candidate only if you know it is the same substance, not because it looks close.",
  "",
  "2. A combination product matches a combined entry if the list has one",
  "   (written 'amoxicillin|clavulanic acid'). Otherwise answer 0.",
  "",
  "3. A code name with no INN yet (BNT162b2, AZD1222) matches only an entry for that",
  "   same code. Do not match it to a similar code — those are different compounds.",
  "",
  "4. VACCINE COMPONENTS ARE SUBSTANCES. A strain designation, an antigen, a toxoid or",
  "   a serotype is the active substance of a vaccine and must be treated as one:",
  "   'Haemagglutinin from A', 'Pertactin', 'Pertussis toxoid', 'A/California/7/2009',",
  "   'Pneumococcal polysaccharide serotype 6B', 'IVR-145'. A bare geographic word",
  "   ('California', 'Brisbane', 'Wisconsin', 'Victoria') in this dataset is an",
  "   INFLUENZA STRAIN NAME, not a place — it is a substance. If the list has no entry",
  "   for it, answer 0 so it can be named properly. NEVER answer -1 for these.",
  "",
  "ANSWER -1 ONLY WHEN THE STRING NAMES NO SUBSTANCE AT ALL. Real examples:",
  "  dosage language only  - 'mL concentrate for solution for infusion', 'ml'",
  "  placeholders          - 'Not yet assigned', 'Not available', 'to be confirmed'",
  "  devices               - 'medical device', 'test product', 'vehicle control'",
  "  study-arm labels      - 'study drug', 'investigational product', 'Arm A'",
  "When in doubt between 0 and -1, answer 0. A 0 sends the string on to be named; a",
  "wrong -1 deletes a real substance from the dataset with nothing downstream to catch it.",
  "",
  "ANSWER 0 WHENEVER YOU ARE UNSURE BETWEEN 0 AND A NUMBER. A wrong match silently",
  "mislabels every trial for that substance; a 0 just sends the string on to be named",
  "properly. 0 is the safe answer.",
  "",
  "confidence is 0-1 and describes how sure you are of the number you chose",
  "(including when you choose 0 or -1).",
  sep = "\n"
)

candidate_content <- function(raw, cands) {
  # Where the retrieved surface form is not the canonical itself, show it. The
  # model is otherwise asked to judge "Methotrexate" against "metotrexate" with
  # no sight of the fact that retrieval got there through "metotrexato".
  extra <- ifelse(
    is.na(cands$matched) | tolower(cands$matched) == tolower(cands$label), "",
    sprintf("  (also known as: %s)", cands$matched)
  )
  salt <- ifelse(is.na(cands$salt_form) | !nzchar(cands$salt_form), "",
                 sprintf("  [salt: %s]", cands$salt_form))
  lines <- sprintf("%d. %s%s%s", seq_len(nrow(cands)), cands$label, extra, salt)
  list(list(type = "text", text = paste0(
    "Raw substance string:\n  ", raw,
    "\n\nCandidate substances:\n", paste(lines, collapse = "\n"),
    "\n\nWhich number is the same substance? 0 if none, -1 if this is not a substance."
  )))
}

# ── Registry ──────────────────────────────────────────────────────────────────

if (!file.exists(REG_PATH)) {
  stop("Run A_resolve.R first — no registry at ", REG_PATH, call. = FALSE)
}
reg <- registry_read(REG_PATH)
asg <- assignments_read(ASG_PATH, raw_col = "raw_substance")
live <- registry_live(reg)
message(sprintf("registry: %d live entities, %d assignments so far", nrow(live), nrow(asg)))
if (!nrow(live)) stop("Registry is empty.", call. = FALSE)

if (rebuild_lists) {
  cache <- llm_cache_read(CACHE_PATH)
  if (is.null(cache)) stop("No decision cache at ", CACHE_PATH, call. = FALSE)
  cur <- cache |> filter(prompt_version == PROMPT_VERSION) |>
    mutate(ci = suppressWarnings(as.integer(chosen_index)))
  resid <- read_csv(RESIDUE_PATH, show_col_types = FALSE, progress = FALSE)

  ns <- cur |> filter(ci == -1L) |> distinct(raw_substance, .keep_all = TRUE) |>
    select(raw_substance, confidence, reason)
  write_csv(ns, NOTSUB_PATH, na = "", eol = "\n")

  # Everything still unresolved: abstained, never asked, or failed. A failure is
  # not an abstention, but it is also not an answer — leaving it out of both
  # lists would drop the string from the pipeline entirely.
  answered_ok <- cur |> filter(!is.na(ci), ci != 0L) |> pull(raw_substance)
  ab <- resid |>
    filter(!raw_substance %in% asg$raw_substance,
           !raw_substance %in% ns$raw_substance,
           !raw_substance %in% answered_ok) |>
    select(raw_substance, n_trials) |>
    distinct(raw_substance, .keep_all = TRUE) |>
    arrange(desc(n_trials))
  write_csv(ab, ABSTAIN_PATH, na = "", eol = "\n")

  cat(sprintf("\nrebuilt from %d cached decisions:\n", nrow(cur)))
  cat(sprintf("  %s : %d strings (not a substance)\n", basename(NOTSUB_PATH), nrow(ns)))
  cat(sprintf("  %s : %d strings / %d trial pairs (C_mint work list)\n",
              basename(ABSTAIN_PATH), nrow(ab), sum(ab$n_trials)))
  cat("\nNo API call was made.\n")
  quit(save = "no", status = 0L)
}

# ── Work list ─────────────────────────────────────────────────────────────────

if (!file.exists(RESIDUE_PATH)) {
  stop("No residue at ", RESIDUE_PATH, " — run A_resolve.R first.", call. = FALSE)
}
todo <- read_csv(RESIDUE_PATH, show_col_types = FALSE, progress = FALSE) |>
  distinct(raw_substance, n_trials) |>
  filter(!raw_substance %in% asg$raw_substance) |>
  arrange(desc(n_trials))

message(sprintf("strings to assign: %d over %d trial pairs", nrow(todo), sum(todo$n_trials)))
if (!nrow(todo)) { message("Nothing to assign."); quit(save = "no", status = 0L) }

# ── Candidates ────────────────────────────────────────────────────────────────
# The index is the observed surface forms PLUS the full ChEMBL/EPAR alias table.
# Indexing canonicals alone was measured and is materially worse: "BNT162b2" is
# not a ChEMBL pref_name but IS a ChEMBL synonym, so it scores 1.00 against the
# alias table and nothing at all against the canonical list. Same for
# "SODIO ASCORBATO", which reaches its entity through the Spanish alias
# "ascorbato de sodio".

# PLACEBO CONTRIBUTES ITS CANONICAL AND NOTHING ELSE.
#
# is_placebo() matches any string CONTAINING "placebo", so "Placebo Forxiga 10 mg"
# is correctly assigned to the placebo entity — and registry_surface_forms() then
# indexes that raw string, which makes "forxiga" a surface form of Placebo. The
# entity accumulates the name of every drug it is a placebo for, and each one
# becomes a retrieval key pointing at it.
#
# Measured on the real slates: "Forxiga 10 mg film-coated tablets" retrieved
#   1. Dapagliflozin propanediol            1.00 token_idf
#   2. Dapagliflozin propanediol monohydrate 1.00 token_idf
#   3. Placebo                              1.00 token_idf
# — a wrong candidate at the top score, on 33 trials, and one wasted slot on
# every drug that has a matching placebo arm.
#
# Dropping these costs nothing: a placebo string never reaches B_assign, because
# A_resolve's deterministic rule has already claimed it.
asg_for_index <- asg |> filter(!channel %in% "placebo")
surface <- registry_surface_forms(reg, asg_for_index, raw_col = "raw_substance")
aliases <- if (file.exists(ALIAS_PATH)) {
  read_csv(ALIAS_PATH, show_col_types = FALSE, progress = FALSE) |>
    filter(entity_id %in% live$entity_id) |>
    transmute(entity_id, label = alias)
} else {
  message("NOTE: no registry_aliases.csv — retrieval will be much weaker.")
  tibble(entity_id = character(), label = character())
}
vocab <- bind_rows(surface, aliases) |>
  filter(!is.na(label), nzchar(trimws(label))) |>
  distinct(entity_id, label)

message(sprintf("building index over %d surface forms (ngram_n=%d)...", nrow(vocab), NGRAM_N))
t0 <- Sys.time()
idx <- build_index(vocab$label, ids = match(vocab$entity_id, live$entity_id),
                   ngram_n = NGRAM_N, generic = SUBSTANCE_GENERIC_TOKENS,
                   drop_numeric = TRUE)
message(sprintf("  %d token postings, %d grams, %.0fs", nrow(idx$tokens), nrow(idx$grams),
                as.numeric(difftime(Sys.time(), t0, units = "secs"))))

min_score <- if (round_no >= 2L) 0.05 else 0.15

cand_for <- function(raw) {
  hits <- retrieve(raw, idx, k = MAX_CANDIDATES,
                   use_ngram = TRUE, use_acronym = FALSE,
                   ngram_threshold = NGRAM_THRESHOLD, interleave = TRUE)
  if (!nrow(hits)) return(tibble())
  hits |>
    mutate(entity_id = live$entity_id[label_id]) |>
    left_join(live |> select(entity_id, canonical, salt_form), by = "entity_id") |>
    transmute(entity_id, label = canonical, matched = label, salt_form, score, channel) |>
    distinct(entity_id, .keep_all = TRUE)
}

message("building candidates...")
work <- todo |>
  mutate(cands = purrr::map(raw_substance, cand_for),
         n_cands = purrr::map_int(cands, nrow))

no_cands <- work |> filter(n_cands == 0L)
work     <- work |> filter(n_cands > 0L)
message(sprintf("  %d strings have candidates, %d have none (auto-abstain)",
                nrow(work), nrow(no_cands)))

if (cands_only) {
  cat("\n=== candidates per string ===\n")
  print(table(cut(c(work$n_cands, rep(0L, nrow(no_cands))),
                  breaks = c(-1, 0, 1, 2, 5, 9, Inf),
                  labels = c("0 (auto-abstain)", "1", "2", "3-5", "6-9", "10 (full slate)"))))
  cat("\nA full slate of 10 on most rows means retrieval is scraping the barrel.\n")
  cat("One or two strong hits is retrieval working.\n")

  cat("\n=== channel of the top candidate ===\n")
  print(table(purrr::map_chr(work$cands, ~ .x$channel[[1L]])))

  show <- bind_rows(head(work, 12), work |> filter(n_trials == 1L) |> head(8)) |>
    distinct(raw_substance, .keep_all = TRUE)
  cat("\n=== sample slates (READ THESE — this is what the model will see) ===\n")
  for (i in seq_len(nrow(show))) {
    cat(sprintf("\n%-58s (%d trials)\n", substr(show$raw_substance[[i]], 1L, 58L),
                show$n_trials[[i]]))
    cc <- show$cands[[i]]
    for (j in seq_len(min(5L, nrow(cc)))) {
      cat(sprintf("   %d. %-42s %.2f %s%s\n", j, substr(cc$label[[j]], 1L, 42L),
                  cc$score[[j]], cc$channel[[j]],
                  if (!is.na(cc$matched[[j]]) &&
                      tolower(cc$matched[[j]]) != tolower(cc$label[[j]]))
                    paste0("  via '", substr(cc$matched[[j]], 1L, 30L), "'") else ""))
    }
    if (nrow(cc) > 5L) cat(sprintf("   ... %d more\n", nrow(cc) - 5L))
  }
  cat("\nNo API call was made. Nothing was spent.\n")
  quit(save = "no", status = 0L)
}

cache <- llm_cache_read(CACHE_PATH)
work <- work |>
  mutate(
    cands_sha = purrr::map_chr(cands, ~ sha256_hex(paste(.x$entity_id, collapse = "\n"))),
    key       = purrr::map2_chr(raw_substance, cands_sha,
                                ~ llm_cache_key(.x, PROMPT_VERSION, MODEL_ID, .y))
  )
# CONVERGENCE: skip on the STRING, not on the cache key.
#
# The cache key includes cands_sha, and the candidate set is not stable across
# runs: registry_surface_forms() indexes every raw string already assigned, so
# the moment a batch assigns anything, the index grows, every slate shifts and
# every cache key changes. Keyed on cache_key, a re-run therefore re-asks every
# string it has already answered — measured, the first retry run re-asked 3,695
# strings and cost $2.22 to recover 481 genuine failures.
#
# A string that has an answer (matched, abstain, or not-a-substance) under this
# prompt version and model is DONE. Only rows with a NA chosen_index — API
# errors, refusals, usage limits — are retried, which is exactly the behaviour
# the run instructions promise ("re-running costs nothing").
#
# To deliberately re-ask everything, bump PROMPT_VERSION. That is the one lever,
# and it is explicit rather than an accident of index growth.
answered <- if (is.null(cache)) character() else {
  cache |>
    filter(prompt_version == PROMPT_VERSION, model_id == MODEL_ID,
           !is.na(chosen_index)) |>
    pull(raw_substance) |> unique()
}
work <- work |> filter(!raw_substance %in% answered)
if (!is.na(limit) && limit > 0L) work <- head(work, limit)
message(sprintf("  %d to ask (%d strings already answered)", nrow(work), length(answered)))
if (!nrow(work)) { message("Nothing to ask."); quit(save = "no", status = 0L) }

work <- work |> mutate(content = purrr::map2(raw_substance, cands, candidate_content))

# ── Parse ─────────────────────────────────────────────────────────────────────
# -1 is a valid answer, so the lower bound is -1 rather than 0. Everything below
# that, and everything above the candidate count, is rejected here rather than
# becoming a wrong label.

parse_choice <- function(outcome, item, batch_id = NA_character_) {
  cands <- item$cands[[1L]]
  base <- tibble(
    cache_key = item$key[[1L]], raw_substance = item$raw_substance[[1L]],
    model_id = MODEL_ID, prompt_version = PROMPT_VERSION,
    candidates_sha256 = item$cands_sha[[1L]], n_candidates = nrow(cands),
    chosen_index = NA_integer_, entity_id = NA_character_, confidence = NA_real_,
    channel = NA_character_, reason = NA_character_,
    decided_at_utc = utc_now(), batch_id = batch_id
  )
  if (!outcome$ok) { base$reason <- outcome$error; return(base) }

  i <- suppressWarnings(as.integer(outcome$value$chosen_index))
  if (length(i) != 1L || is.na(i)) { base$reason <- "no chosen_index"; return(base) }
  if (i < -1L || i > nrow(cands)) {
    base$reason <- sprintf("index %d out of range -1..%d", i, nrow(cands))
    return(base)
  }
  base$chosen_index <- i
  base$confidence   <- suppressWarnings(as.numeric(outcome$value$confidence %||% NA_real_))
  base$reason       <- outcome$value$reason %||% NA_character_
  if (i > 0L) {
    base$entity_id <- cands$entity_id[[i]]
    base$channel   <- cands$channel[[i]]
  }
  base
}

CACHE_COLS <- c("cache_key", "raw_substance", "model_id", "prompt_version",
                "candidates_sha256", "n_candidates", "chosen_index", "entity_id",
                "confidence", "channel", "reason", "decided_at_utc", "batch_id")

save_rows <- function(rows) {
  merged <- llm_cache_merge(cache, rows, key_col = "cache_key")
  llm_cache_write(merged[, CACHE_COLS], CACHE_PATH, sort_by = "raw_substance")

  matched   <- sum(!is.na(rows$entity_id))
  abstained <- sum(rows$chosen_index %in% 0L)
  notsub    <- sum(rows$chosen_index %in% -1L)
  failed    <- sum(is.na(rows$chosen_index))
  message(sprintf("wrote %d rows (%d matched, %d abstained, %d not-a-substance, %d failed)",
                  nrow(rows), matched, abstained, notsub, failed))

  ok <- rows |> filter(!is.na(entity_id))
  if (nrow(ok)) {
    new_asg <- ok |>
      transmute(raw_substance, entity_id, confidence, channel, reason,
                decided_by = "model", decided_at_utc, model_id, prompt_version)
    cur <- assignments_read(ASG_PATH, raw_col = "raw_substance")
    pinned <- cur |> filter(decided_by %in% "human")
    keep   <- cur |> filter(!decided_by %in% "human",
                            !raw_substance %in% new_asg$raw_substance)
    new_asg <- new_asg |> filter(!raw_substance %in% pinned$raw_substance)
    assignments_write(bind_rows(pinned, keep, new_asg), ASG_PATH, raw_col = "raw_substance")
    message(sprintf("  assignments now %d", nrow(pinned) + nrow(keep) + nrow(new_asg)))
  }

  # Abstentions feed C_mint. Not-a-substance answers must NOT: minting a
  # canonical for "Not yet assigned" is exactly the failure this pass exists to
  # prevent, so the two are written to separate files.
  # n_trials travels with the abstention: C_mint seeds its canopy blocks in
  # descending trial impact, exactly as A_block does, so the highest-value
  # strings get the cleanest blocks. Without the count C_mint would have to
  # re-derive it or block in arbitrary order.
  # Built from the WHOLE cache, not just this run's rows.
  #
  # Writing only `rows` overwrites the file with the current batch's abstentions
  # and silently discards every earlier one. Measured: after the retry run,
  # C_mint's work list collapsed from 9,000 strings to 4,566 — 4,400 strings
  # that had legitimately abstained in the first batch simply vanished, and
  # nothing downstream would ever have asked about them again.
  all_rows <- llm_cache_read(CACHE_PATH)
  cached_abstain <- if (is.null(all_rows)) character() else {
    all_rows |>
      filter(prompt_version == PROMPT_VERSION,
             suppressWarnings(as.integer(chosen_index)) == 0L) |>
      pull(raw_substance)
  }
  ab <- tibble(raw_substance = unique(c(
    cached_abstain,
    rows$raw_substance[rows$chosen_index %in% 0L],
    no_cands$raw_substance
  ))) |>
    filter(!is.na(raw_substance), nzchar(raw_substance)) |>
    # A string later matched or judged not-a-substance must not linger here.
    filter(!raw_substance %in% assignments_read(ASG_PATH, raw_col = "raw_substance")$raw_substance) |>
    filter(!raw_substance %in% (if (file.exists(NOTSUB_PATH)) {
      read_csv(NOTSUB_PATH, show_col_types = FALSE, progress = FALSE)$raw_substance
    } else character())) |>
    left_join(read_csv(RESIDUE_PATH, show_col_types = FALSE, progress = FALSE) |>
                select(raw_substance, n_trials), by = "raw_substance") |>
    mutate(n_trials = coalesce(n_trials, 1L)) |>
    arrange(desc(n_trials))
  if (nrow(ab)) {
    write_csv(ab, ABSTAIN_PATH, na = "", eol = "\n")
    message(sprintf("  %d abstentions / %d trial pairs -> %s (C_mint's work list)",
                    nrow(ab), sum(ab$n_trials), basename(ABSTAIN_PATH)))
  }

  ns <- rows |> filter(chosen_index %in% -1L) |>
    select(raw_substance, confidence, reason)
  if (nrow(ns)) {
    prev <- if (file.exists(NOTSUB_PATH)) {
      read_csv(NOTSUB_PATH, show_col_types = FALSE, progress = FALSE)
    } else NULL
    write_csv(bind_rows(prev, ns) |> distinct(raw_substance, .keep_all = TRUE),
              NOTSUB_PATH, na = "", eol = "\n")
    message(sprintf("  %d not-a-substance -> %s", nrow(ns), basename(NOTSUB_PATH)))
  }
}

# ── Modes ─────────────────────────────────────────────────────────────────────

spec <- llm_spec(model = MODEL_ID, prompt_version = PROMPT_VERSION,
                 system_prompt = SYSTEM_PROMPT, schema = ASSIGN_SCHEMA,
                 effort = "low", max_tokens = MAX_TOKENS)

if (dry_run) {
  est <- llm_dry_run(spec, work, label = paste("B_assign /", MODEL_ID), spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_batch, SPEND_PATH, "B_assign")
  quit(save = "no", status = 0L)
}

auth <- llm_auth()

if (do_sync) {
  est <- llm_dry_run(spec, work, label = paste("B_assign /", MODEL_ID), spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_sync %||% est$est_cost_batch, SPEND_PATH, "B_assign")
  rows <- llm_sync(spec, work, parse = function(o, it) parse_choice(o, it), auth = auth)
  save_rows(rows)
  llm_spend_record_sync(SPEND_PATH, "B_assign", MODEL_ID, rows)
  message(sprintf("recorded sync spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  cat("\nSCALE GATE, check three things before submitting a batch:\n")
  cat("  1. no 'grammar compilation rate limit' above — the schema is constant\n")
  cat("  2. abstentions should be offered MORE candidates than matches are.\n")
  cat("     A full slate of 10 is retrieval scraping the barrel; one or two\n")
  cat("     strong hits is retrieval working.\n")
  cat("  3. read the -1 answers. They are the ones no filter could have caught.\n")
  quit(save = "no", status = 0L)
}

if (!is.na(poll_batch)) {
  llm_batch_wait(poll_batch, auth)
  rows <- llm_batch_results(poll_batch, work, parse = parse_choice, auth = auth)
  save_rows(rows)
  u <- llm_batch_usage(poll_batch, auth)
  if (!is.null(u)) {
    llm_spend_record(SPEND_PATH, "B_assign", poll_batch, MODEL_ID, u$input, u$output,
                     u$cache_read, n_requests = u$n %||% nrow(work))
    message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  }
  quit(save = "no", status = 0L)
}

est <- llm_dry_run(spec, work, label = paste("B_assign /", MODEL_ID), spend_path = SPEND_PATH)
llm_budget_guard(est$est_cost_batch, SPEND_PATH, "B_assign")
bid  <- llm_batch_submit(spec, work, auth)
llm_batch_wait(bid, auth)
rows <- llm_batch_results(bid, work, parse = parse_choice, auth = auth)
save_rows(rows)
u <- llm_batch_usage(bid, auth)
if (!is.null(u)) {
  llm_spend_record(SPEND_PATH, "B_assign", bid, MODEL_ID, u$input, u$output,
                   u$cache_read, n_requests = u$n %||% nrow(work))
  message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
}
message("Assigned. Nothing applied to any label — E_emit.R does that.")
