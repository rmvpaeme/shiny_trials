#!/usr/bin/env Rscript
# Pass D — merge registry entries that name the same organisation.
#
# Minting happens block by block, so two blocks can name one organisation twice:
# a sponsor with more than max_block variants spills into a second block, and
# round-2 minting of abstainers mints against a registry that already holds the
# entity. Exact-canonical duplicates are collapsed when the registry is
# materialised; this pass catches the rest — "AstraZeneca" vs "Astra Zeneca",
# "MSD" vs "Merck Sharp & Dohme".
#
# Opus 5, because a wrong merge here is the most expensive error the pipeline
# can make: it silently relabels every trial of two organisations at once, and
# unlike a wrong assignment it is not visible in any single string.
#
# THE MODEL PARTITIONS THE GROUP; IT DOES NOT JUDGE IT.
#
# The first version of this pass asked one boolean — "are these all the same
# organisation?" — over a whole component. Measured against the real 3,509-entity
# registry, that question is unanswerable for most components, because a
# component is a LEXICAL NEIGHBOURHOOD, not a duplicate set. The Leuven component
# holds five spellings of UZ Leuven AND two of KU Leuven; a university and its
# university hospital are correctly different organisations, so the only
# available answer was "no" and all five hospital duplicates survived. 134 of the
# 287 askable groups mixed entity types this way, and single-type groups were no
# better: one held 'Hospital Universitari de Bellvitge' and 'Hospital
# Universitario de Bellvitge' beside four unrelated Catalan hospitals.
#
# So the model now returns `merge_into`: one index per member, naming the entry
# that member merges into (or itself, to stand alone). Members pointing at the
# same target are one organisation. Leuven answers [1,1,1,1,1,6,6] — five
# hospitals merged, two universities merged, the families kept apart — which the
# boolean could not express at all.
#
# This stays inside the constant-schema rule (client.R, and 5_llm_resolve.R:303).
# An ARRAY of integers is one grammar no matter how long it is; what caused the
# grammar-compilation rate limit was a per-row *enum*, whose members changed with
# every request. Bounds are checked in R on receipt, exactly as C_assign does.
#
# Connected components is still right for finding candidates — at a high
# threshold over a few thousand canonicals, "A=B and B=C implies A=C" is what you
# want. But closure did NOT stay tight as the earlier comment here assumed:
# measured, five components exceed MAX_GROUP and cover 723 entities, the largest
# with 529 members, and those were silently skipped. Oversized components are now
# re-split by canopy — the same seed-centred grouping A_block uses, for the same
# reason — instead of being dropped.
#
# Usage
#   Rscript .../D_consolidate.R --dry-run
#   Rscript .../D_consolidate.R --sync --limit=5
#   Rscript .../D_consolidate.R --batch
#   Rscript .../D_consolidate.R --batch --poll=<id>
#   Rscript .../D_consolidate.R --apply            # write the merges

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

args <- commandArgs(trailingOnly = TRUE)
arg_value <- function(flag, default = NA_character_) {
  hit <- args[startsWith(args, paste0(flag, "="))]
  if (length(hit)) sub(paste0("^", flag, "="), "", hit[[1L]]) else default
}
dry_run <- "--dry-run" %in% args
do_sync <- "--sync"    %in% args
do_batch <- "--batch"  %in% args
do_apply <- "--apply"  %in% args
do_translate <- "--translate" %in% args
limit      <- suppressWarnings(as.integer(arg_value("--limit")))
poll_batch <- arg_value("--poll")

MODEL_ID       <- arg_value("--model", "claude-opus-5")
# v2: partition the group, don't judge it whole. See the header.
PROMPT_VERSION <- "sponsor-consolidate-v2"
MAX_TOKENS     <- 4096L
# High: a merge candidate should be an obvious near-duplicate, not a guess. The
# model still has to agree, so this only controls what gets asked about.
THRESHOLD      <- as.numeric(arg_value("--threshold", "0.70"))
MAX_GROUP      <- 12L

# --translate settings. Sonnet: naming a well-known institution in English is
# recall of a fact, not the judgement the merge decision needs.
TR_MODEL   <- arg_value("--model", "claude-sonnet-5")
TR_VERSION <- "sponsor-translate-v1"
# Trial-row floor. 401 entities clear 20 and they carry 64% of all trial rows;
# the long tail below that is 1-2 trials each and not worth a request.
TR_MIN_TRIALS <- suppressWarnings(as.integer(arg_value("--min-trials", "20")))

V2         <- pp("config", "sponsor_norm_v2")
REG_PATH   <- file.path(V2, "registry.csv")
ASG_PATH   <- file.path(V2, "assignments.csv")
CACHE_PATH <- file.path(V2, "D_consolidate_merges.csv")
TR_PATH    <- file.path(V2, "D_translate.csv")
BLOCKS_PATH <- pp("data", "sponsor_blocks.csv")
SPEND_PATH <- file.path(V2, "llm_spend.csv")

if (!file.exists(REG_PATH)) stop("No registry — run B_mint.R and C_assign.R first.", call. = FALSE)

reg  <- registry_read(REG_PATH)
asg  <- assignments_read(ASG_PATH)
live <- registry_live(reg)
message(sprintf("registry: %d live entities", nrow(live)))

# ── Apply mode ────────────────────────────────────────────────────────────────

if (do_apply) {
  m <- llm_cache_read(CACHE_PATH)
  if (is.null(m)) stop("No merge decisions at ", CACHE_PATH, call. = FALSE)
  merges <- m |>
    filter(!is.na(winner_id), !is.na(loser_id), loser_id != winner_id) |>
    mutate(confidence = suppressWarnings(as.numeric(confidence))) |>
    filter(confidence >= 0.8) |>
    select(loser_id, winner_id, reason)
  message(sprintf("%d merge(s) at confidence >= 0.8", nrow(merges)))

  # MIS-INDEX GUARD — two weak signals ANDed, because each alone is useless.
  #
  # The model can emit an index that contradicts its own stated reasoning. On the
  # first live batch it wrote "Institut Pasteur, Institut Pasteur de Lille, and
  # the Lille hospitals are distinct entities" and then pointed 'Centre
  # Hospitalier Universitaire de Lille' (hospital, 17 raw strings) at 'Sanofi
  # Pasteur MSD' (industry) at 0.90 confidence. Confidence does not separate
  # these: the bad merge scored the same as the good ones.
  #
  # Measured over all 267 proposed merges:
  #   entity_type mismatch alone   -> 21 blocked, ~20 of them CORRECT. The type
  #     is model output and disagrees with itself across mints of one
  #     organisation: 'Charité – Universitätsmedizin Berlin' (hospital) vs
  #     'Charité - Universitätsmedizin Berlin' (academic) differ by a dash.
  #   name dissimilarity alone     -> 14 blocked, ~13 of them CORRECT. It fires
  #     hardest on the BEST merges — acronym expansions ('UZ Leuven' <-
  #     'Universitair Ziekenhuis Leuven', 'HUS' <- 'Helsingin ja Uudenmaan
  #     sairaanhoitopiiri') and diacritic pairs ('Grünenthal' <- 'Grunenthal').
  #   BOTH together                -> 1 blocked, and it is the Lille merge.
  #
  # Two organisations that are genuinely one thing almost always share either a
  # type or a name. Sharing neither is the tell. Similarity is character bigrams
  # over an accent-folded string, so a diacritic variant still scores high.
  # 'unknown' never blocks — it means the mint declined to type, not a conflict.
  fold_ascii <- function(x) {
    gsub("[^a-z0-9]", "", iconv(tolower(x), to = "ASCII//TRANSLIT", sub = ""))
  }
  bigrams <- function(s) if (nchar(s) < 2L) s else
    substring(s, 1:(nchar(s) - 1L), 2:nchar(s))
  dice <- function(a, b) {
    mapply(function(x, y) {
      x <- bigrams(x); y <- bigrams(y)
      2 * length(intersect(x, y)) / max(1L, length(x) + length(y))
    }, fold_ascii(a), fold_ascii(b))
  }

  types <- reg |> select(entity_id, entity_type)
  canon <- reg |> select(entity_id, canonical)
  chk <- merges |>
    left_join(types |> rename(winner_id = entity_id, winner_type = entity_type),
              by = "winner_id") |>
    left_join(types |> rename(loser_id = entity_id, loser_type = entity_type),
              by = "loser_id") |>
    left_join(canon |> rename(winner_id = entity_id, wc = canonical), by = "winner_id") |>
    left_join(canon |> rename(loser_id = entity_id, lc = canonical), by = "loser_id") |>
    mutate(sim = dice(wc, lc))
  blocked <- chk |>
    filter(!is.na(winner_type), !is.na(loser_type),
           winner_type != loser_type,
           !winner_type %in% "unknown", !loser_type %in% "unknown",
           sim < 0.30)
  if (nrow(blocked)) {
    message(sprintf("  HELD BACK %d suspected mis-index(es) — review by hand:", nrow(blocked)))
    for (i in seq_len(nrow(blocked))) {
      message(sprintf("    %s (%s) <- %s (%s)  sim=%.2f",
                      blocked$wc[i], blocked$winner_type[i],
                      blocked$lc[i], blocked$loser_type[i], blocked$sim[i]))
    }
    merges <- merges |> anti_join(blocked, by = c("loser_id", "winner_id"))
  }
  message(sprintf("applying %d merge(s)", nrow(merges)))
  out <- registry_apply_merges(reg, asg, merges, MODEL_ID, PROMPT_VERSION)
  registry_write(out$registry, REG_PATH)
  assignments_write(out$assignments, ASG_PATH)
  message(sprintf("applied %d, refused %d (human-decided)", out$applied, out$refused))
  message(sprintf("registry now %d live entities", nrow(registry_live(out$registry))))
  quit(save = "no", status = 0L)
}

if (!dry_run && !do_sync && !do_batch && is.na(poll_batch)) {
  stop("Pick a mode: --dry-run, --sync, --batch, --batch --poll=<id>, or --apply",
       call. = FALSE)
}

# ── Translation channel ───────────────────────────────────────────────────────
#
# WHY THIS EXISTS. One institution named in two languages produces two canonicals
# that share no token, so the pair graph never proposes them and the model is
# never asked. Measured on the emitted labels:
#
#   Medizinische Universität Wien (469 rows) + Medical University of Vienna (26)
#   Ghent University Hospital (128) + Universitair Ziekenhuis Gent (32) + UZ Gent (4)
#   UZ Brussel (57) + Universitair Ziekenhuis Brussel (25)
#   Università degli Studi di Milano-Bicocca (9) + University of Milano-Bicocca (2)
#
# — and that is from ten hand-picked city patterns, so it is a floor. The Vienna
# split is the rank-12 sponsor in the app.
#
# NO LEXICAL CHANNEL REACHES IT, and this was measured rather than assumed:
# 'University Hospital Gent' and 'University Hospital Ghent' share only
# 'university' and 'hospital', which are stoplisted generics, so the only
# discriminating tokens are the ones that differ. Character n-grams add nothing
# (and score NA). Indexing surface forms instead of canonicals does not bridge it
# either. Translation is semantic knowledge; the model is the only thing here
# that has it.
#
# So: ask for the English name and use THAT as a blocking key. No gazetteer, no
# city table, no rule layer — the same move that let a sub-unit find its parent
# in B_mint. Matching English names only PROPOSE a group; the existing partition
# prompt still decides, and the mis-index guard still applies at --apply.

TRANSLATE_SCHEMA <- list(
  type = "object", additionalProperties = FALSE,
  required = list("english_name", "confidence"),
  properties = list(
    english_name = list(type = "string"),
    confidence   = list(type = "number")
  )
)

TRANSLATE_PROMPT <- paste(
  "You give the established ENGLISH name of a clinical-trial sponsor organisation.",
  "",
  "This is used to recognise when one organisation has been recorded under two",
  "language variants of its name, so the answer must be the form an English source",
  "would actually use — not a word-by-word translation you invented.",
  "",
  "  'Medizinische Universität Wien'   -> 'Medical University of Vienna'",
  "  'Universitair Ziekenhuis Gent'    -> 'Ghent University Hospital'",
  "  'UZ Brussel'                      -> 'University Hospital Brussels'",
  "  'Università degli Studi di Milano'-> 'University of Milan'",
  "",
  "IF THE ORGANISATION HAS NO ESTABLISHED ENGLISH NAME, ECHO THE INPUT EXACTLY.",
  "Most sponsors are in this position and that is the expected answer:",
  "",
  "  'Novartis'              -> 'Novartis'",
  "  'Hospices Civils de Lyon' -> 'Hospices Civils de Lyon'",
  "  'Institut Gustave Roussy' -> 'Institut Gustave Roussy'",
  "",
  "Companies keep their trading name; never translate a brand. Do not expand an",
  "acronym unless the expansion IS the English name. Do not add a legal suffix,",
  "a city, or a country that the input does not have.",
  "",
  "WHEN AN INSTITUTION IS KNOWN IN ENGLISH BY ITS NATIVE OR ABBREVIATED NAME,",
  "THAT IS ITS ENGLISH NAME. 'KU Leuven', 'Charité', 'INSERM', 'Karolinska",
  "Institutet' are what English sources write. Echo them.",
  "",
  "UNIVERSITIES THAT SPLIT ALONG LANGUAGE LINES ARE DIFFERENT ORGANISATIONS AND",
  "MUST NEVER RECEIVE THE SAME ENGLISH NAME. This is the one way this task can",
  "cause real damage, because two names that collide here get merged:",
  "",
  "  'KU Leuven' (Dutch) and 'Université catholique de Louvain' (French) split in",
  "  1968. Answer 'KU Leuven' and 'UCLouvain'. NEVER 'Catholic University of",
  "  Louvain' for both.",
  "  'Vrije Universiteit Brussel' (Dutch) and 'Université libre de Bruxelles'",
  "  (French) split in 1969. Answer 'Vrije Universiteit Brussel' and",
  "  'Université libre de Bruxelles'. NEVER 'Free University of Brussels' for",
  "  either — that name is ambiguous between them.",
  "",
  "The same caution applies to any institution whose name differs only by",
  "language from a DIFFERENT institution in the same city or region. If you",
  "cannot be sure two such names are one organisation, echo the input.",
  "",
  "confidence is 0-1: how sure you are that an English source would use this exact",
  "name for this exact organisation. Use a low value when you are guessing, and",
  "prefer echoing the input over guessing.",
  sep = "\n"
)

translate_content <- function(canonical, entity_type) {
  list(list(type = "text", text = paste0(
    "Organisation: ", canonical,
    "\nType: ", ifelse(is.na(entity_type), "unknown", entity_type),
    "\n\nIts established English name, or the input echoed exactly if it has none?"
  )))
}

# Trial impact, not string count: a canonical with one raw string can still carry
# hundreds of trials, and it is trials the app displays.
trials_per_entity <- function() {
  if (!file.exists(BLOCKS_PATH)) return(NULL)
  b <- read_csv(BLOCKS_PATH, show_col_types = FALSE, progress = FALSE)
  asg |>
    left_join(b |> distinct(raw_sponsor, n_trials), by = "raw_sponsor") |>
    group_by(entity_id) |>
    summarise(n_trials = sum(n_trials, na.rm = TRUE), .groups = "drop")
}

if (do_translate) {
  tr_imp <- trials_per_entity()
  if (is.null(tr_imp)) stop("Need ", BLOCKS_PATH, " for trial impact.", call. = FALSE)
  tw <- live |>
    left_join(tr_imp, by = "entity_id") |>
    mutate(n_trials = coalesce(n_trials, 0L)) |>
    filter(n_trials >= TR_MIN_TRIALS) |>
    arrange(desc(n_trials))
  message(sprintf("translate: %d entities at >= %d trial rows (%d live)",
                  nrow(tw), TR_MIN_TRIALS, nrow(live)))

  tw <- tw |>
    mutate(key = purrr::map_chr(canonical, ~ llm_cache_key(.x, TR_VERSION, TR_MODEL)))
  tr_cache <- llm_cache_read(TR_PATH)
  tr_done  <- if (is.null(tr_cache)) character() else
    unique(tr_cache$cache_key[!is.na(tr_cache$english_name)])
  tw <- tw |> filter(!key %in% tr_done)
  if (!is.na(limit) && limit > 0L) tw <- head(tw, limit)
  message(sprintf("  %d to ask (%d cached)", nrow(tw), length(tr_done)))
  if (!nrow(tw)) { message("Nothing to translate."); quit(save = "no", status = 0L) }

  tw <- tw |> mutate(content = purrr::map2(canonical, entity_type, translate_content))

  parse_translate <- function(outcome, item, batch_id = NA_character_) {
    base <- tibble::tibble(
      cache_key = item$key[[1L]], entity_id = item$entity_id[[1L]],
      canonical = item$canonical[[1L]], model_id = TR_MODEL,
      prompt_version = TR_VERSION, english_name = NA_character_,
      confidence = NA_real_, decided_at_utc = utc_now(), batch_id = batch_id
    )
    if (!outcome$ok) return(base)
    nm <- outcome$value$english_name %||% NA_character_
    if (!is.character(nm) || length(nm) != 1L || !nzchar(nm)) return(base)
    base$english_name <- nm
    base$confidence <- suppressWarnings(as.numeric(outcome$value$confidence %||% NA_real_))
    base
  }
  TR_COLS <- c("cache_key", "entity_id", "canonical", "model_id", "prompt_version",
               "english_name", "confidence", "decided_at_utc", "batch_id")
  tr_save <- function(rows) {
    llm_cache_write(llm_cache_merge(tr_cache, rows, "cache_key")[, TR_COLS],
                    TR_PATH, sort_by = "canonical")
    changed <- sum(!is.na(rows$english_name) & rows$english_name != rows$canonical)
    message(sprintf("wrote %d rows (%d renamed, %d echoed, %d failed)",
                    nrow(rows), changed,
                    sum(!is.na(rows$english_name)) - changed,
                    sum(is.na(rows$english_name))))
  }

  tr_spec <- llm_spec(TR_MODEL, TR_VERSION, TRANSLATE_PROMPT, TRANSLATE_SCHEMA,
                      effort = "low", max_tokens = 512L)
  if (dry_run) {
    est <- llm_dry_run(tr_spec, tw, label = paste("D_translate /", TR_MODEL),
                       spend_path = SPEND_PATH)
    llm_budget_guard(est$est_cost_batch, SPEND_PATH, "D_translate")
    quit(save = "no", status = 0L)
  }
  auth <- llm_auth()
  if (do_sync) {
    tr_save(llm_sync(tr_spec, tw, parse = function(o, it) parse_translate(o, it), auth = auth))
    quit(save = "no", status = 0L)
  }
  if (!is.na(poll_batch)) {
    llm_batch_wait(poll_batch, auth)
    tr_save(llm_batch_results(poll_batch, tw, parse = parse_translate, auth = auth))
    u <- llm_batch_usage(poll_batch, auth)
    if (!is.null(u)) llm_spend_record(SPEND_PATH, "D_translate", poll_batch, TR_MODEL,
                                      u$input, u$output, u$cache_read,
                                      n_requests = u$n %||% nrow(tw))
    quit(save = "no", status = 0L)
  }
  est <- llm_dry_run(tr_spec, tw, label = paste("D_translate /", TR_MODEL),
                     spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_batch, SPEND_PATH, "D_translate")
  bid <- llm_batch_submit(tr_spec, tw, auth)
  llm_batch_wait(bid, auth)
  tr_save(llm_batch_results(bid, tw, parse = parse_translate, auth = auth))
  u <- llm_batch_usage(bid, auth)
  if (!is.null(u)) {
    llm_spend_record(SPEND_PATH, "D_translate", bid, TR_MODEL, u$input, u$output,
                     u$cache_read, n_requests = u$n %||% nrow(tw))
    message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  }
  message("Translated. Re-run D_consolidate without --translate to use these as a channel.")
  quit(save = "no", status = 0L)
}

# ── Candidate groups ──────────────────────────────────────────────────────────

message("building merge-candidate graph over canonicals...")
idx   <- build_index(live$canonical, ids = seq_len(nrow(live)))
pairs <- build_pair_graph(idx, evidence = NULL)
strong <- pairs |> filter(score >= THRESHOLD)
message(sprintf("  %d pairs at or above %.2f", nrow(strong), THRESHOLD))

# Translation edges. Two entities whose English names agree are proposed as a
# group even when their canonicals share no token — the Gent/Ghent case. This
# only ADDS candidates; the partition prompt still decides, so a wrong English
# name costs a request and a "leave it alone", not a wrong merge.
tr <- llm_cache_read(TR_PATH)
if (!is.null(tr) && nrow(tr)) {
  # The key is a SORTED BAG OF WORDS, not the string. The English name is a
  # pivot: every language variant of one institution is meant to land on it, so
  # French and Dutch names for one hospital meet here. But they meet only if the
  # model phrases both the same way, and it will not — 'Ghent University
  # Hospital' and 'University Hospital Ghent' are the same answer in two word
  # orders, and an exact key calls them different. Sorting the words and
  # dropping connectives makes the key indifferent to both.
  KEY_STOP <- c("of", "the", "and", "for", "at", "in", "a", "an",
                "de", "du", "des", "di", "della", "der", "den", "das",
                "la", "le", "les", "el", "il")
  fold_key <- function(x) {
    vapply(x, function(s) {
      s <- iconv(tolower(s), to = "ASCII//TRANSLIT", sub = "")
      w <- strsplit(gsub("[^a-z0-9 ]", " ", s), " +")[[1L]]
      w <- setdiff(w[nzchar(w)], KEY_STOP)
      paste(sort(unique(w)), collapse = "")
    }, character(1), USE.NAMES = FALSE)
  }
  tr <- tr |>
    filter(!is.na(english_name), nzchar(english_name)) |>
    mutate(confidence = suppressWarnings(as.numeric(confidence))) |>
    filter(is.na(confidence) | confidence >= 0.6) |>
    select(entity_id, english_name)

  # EVERY live entity gets a key — its English name where we have one, its own
  # canonical otherwise. Keying only the translated rows would let the channel
  # connect two TRANSLATED entities and nothing else, and the English-side
  # counterpart is usually the small one that --min-trials excluded:
  # 'Medizinische Universität Wien' carries 469 trial rows and has to be able to
  # reach 'Medical University of Vienna', which carries 26 and was never asked.
  keyed <- live |>
    mutate(node = seq_len(dplyr::n())) |>
    left_join(tr, by = "entity_id") |>
    mutate(key = fold_key(coalesce(english_name, canonical)))
  # combn over each English-name group, without pulling in tidyr for an unnest.
  tr_groups <- keyed |>
    group_by(key) |>
    filter(dplyr::n() > 1L) |>
    summarise(nodes = list(sort(unique(node))), .groups = "drop")
  tr_edges <- purrr::map_dfr(tr_groups$nodes, function(nd) {
    if (length(nd) < 2L) return(NULL)
    cb <- utils::combn(nd, 2L)
    tibble::tibble(a = cb[1L, ], b = cb[2L, ], score = 1, channel = "translate")
  })
  if (nrow(tr_edges)) {
    before <- nrow(strong)
    strong <- bind_rows(strong, tr_edges) |> distinct(a, b, .keep_all = TRUE)
    message(sprintf("  +%d pair(s) from matching English names (%d entities translated)",
                    nrow(strong) - before, nrow(tr)))
  }
} else {
  message("  no translation cache — run --translate to catch cross-language splits")
}

comp <- components_of(strong |> select(a, b), n_nodes = nrow(live))
live$component <- comp

# Trial impact tells the model which name is the established one, and seeds the
# canopy re-split below, so it is needed before the groups are formed.
impact <- asg |>
  count(entity_id, name = "n_strings") |>
  right_join(live |> select(entity_id), by = "entity_id") |>
  mutate(n_strings = coalesce(n_strings, 0L))
live <- live |> left_join(impact, by = "entity_id")

# Oversized components are RE-SPLIT, not skipped. Measured on the 3,509-entity
# registry: five components exceeded MAX_GROUP and covered 723 entities — 46% of
# every entity with any duplicate neighbour — the largest with 529 members.
# Dropping those to an "inspect by hand" message quietly excused the pass from
# most of its own work.
#
# Canopy is the right instrument for the same reason it is in A_block: it seeds
# from the highest-impact member and admits only entities similar TO THAT SEED,
# so membership stays a statement about the seed instead of a path through the
# graph. Closure keeps its job on components that are already tight.
big <- live |> count(component) |> filter(n > MAX_GROUP)
if (nrow(big)) {
  message(sprintf("  %d component(s) larger than %d — re-splitting by canopy",
                  nrow(big), MAX_GROUP))
  next_id <- max(live$component) + 1L
  for (cc in big$component) {
    members <- which(live$component == cc)
    sub <- strong |>
      filter(a %in% members, b %in% members) |>
      transmute(a = match(a, members), b = match(b, members), score)
    sub_block <- canopy_blocks(sub, n_nodes = length(members),
                               weights = live$n_strings[members],
                               threshold = THRESHOLD, max_block = MAX_GROUP)
    live$component[members] <- next_id + sub_block - 1L
    next_id <- next_id + max(sub_block)
  }
}

groups <- live |>
  group_by(component) |>
  filter(dplyr::n() > 1L, dplyr::n() <= MAX_GROUP) |>
  ungroup()

still_big <- live |> count(component) |> filter(n > MAX_GROUP)
if (nrow(still_big)) {
  message(sprintf("  %d component(s) still over %d after re-splitting — skipped",
                  nrow(still_big), MAX_GROUP))
}

group_ids <- unique(groups$component)
message(sprintf("  %d candidate groups covering %d entities",
                length(group_ids), nrow(groups)))
if (!length(group_ids)) { message("Nothing to consolidate."); quit(save = "no", status = 0L) }

# ── Schema: ONE grammar ───────────────────────────────────────────────────────

MERGE_SCHEMA <- list(
  type = "object", additionalProperties = FALSE,
  required = list("merge_into", "confidence", "reason"),
  properties = list(
    # One entry per member, in the order they were listed. merge_into[i] is the
    # 1-based index of the member whose name survives for member i; i itself
    # means "stands alone". Members sharing a target are one organisation.
    #
    # An array is ONE grammar however long it gets — the schema does not change
    # with the group size. That is the distinction from the per-row enum that
    # cost 190 of 222 requests in 5_llm_resolve.R. Bounds are checked in R.
    merge_into = list(type = "array", items = list(type = "integer")),
    # Parallel to merge_into: how sure the model is about THAT member's target.
    # Per-member, because --apply gates at 0.80 and one shaky member should not
    # veto a confident merge beside it (nor ride in on one).
    confidence = list(type = "array", items = list(type = "number")),
    reason     = list(type = "string")
  )
)

SYSTEM_PROMPT <- paste(
  "You sort a small list of clinical-trial sponsor names into organisations.",
  "",
  "You receive a numbered list of canonical names that a text-similarity step flagged as",
  "possibly overlapping. The list is a LEXICAL NEIGHBOURHOOD, not a duplicate set: it",
  "usually contains SEVERAL different organisations, and often more than one duplicate",
  "family at once. Your job is to say which entries name the same organisation.",
  "",
  "For every entry, return the number of the entry whose name should survive for it.",
  "An entry that stands alone returns ITS OWN number. Entries returning the same",
  "number are one organisation and will be merged under that name.",
  "",
  "Example. Given:",
  "  1. UZ Leuven          2. Universitair Ziekenhuis Leuven",
  "  3. University Hospitals Leuven                4. KU Leuven",
  "  5. Katholieke Universiteit Leuven             6. Hasselt University",
  "answer merge_into = [1, 1, 1, 4, 4, 6]: the three hospital names are one",
  "organisation, the two university names are another, and Hasselt is unrelated.",
  "Note that the hospital and the university are NOT merged with each other.",
  "",
  "Return exactly one number per entry, in the order the entries were listed.",
  "",
  "These canonicals are BRAND-level: national subsidiaries and legal entities were",
  "already folded into the parent brand when they were named. So a pair like",
  "'Novartis' and 'Novartis Pharma', or 'Roche' and 'Hoffmann-La Roche', is a",
  "leftover from naming one company in two separate batches — that IS the same",
  "organisation, and merging it is the main thing this pass exists to do.",
  "",
  "LEAVE AN ENTRY ALONE WHENEVER THERE IS ANY DOUBT — return its own number.",
  "Merging two organisations silently relabels every trial belonging to both, and",
  "unlike a wrong individual match it is invisible in any single record. A missed",
  "merge is cheap; a wrong merge is not.",
  "",
  "Keep these SEPARATE — give them their own numbers:",
  "",
  "- A university and its university hospital. 'Universitat Basel' and",
  "  'Universitatsspital Basel' are different legal entities with different trials.",
  "- MSD / Merck Sharp & Dohme (US) versus Merck KGaA or Merck Serono (Darmstadt).",
  "- Two hospitals in different cities that share a naming pattern, e.g.",
  "  'Centre Rene Huguenin' and 'Centre Rene Gauducheau'.",
  "- A parent group and a subsidiary that was deliberately kept separate because it",
  "  trades under its own brand: AstraZeneca and MedImmune, Roche and Genentech,",
  "  Sanofi and Genzyme, Novartis and Sandoz. These are related, not identical, and",
  "  the naming step separated them on purpose.",
  "- Any pair where the difference might be a real distinction you cannot resolve.",
  "",
  "Point entries at a common survivor only for genuine duplicates of ONE organisation:",
  "",
  "- Spelling, spacing, case and punctuation variants of one name.",
  "- The same name with and without a legal suffix.",
  "- A name whose accented characters were deleted by the source registry:",
  "  'Universittsklinikum Mnchen' is 'Universitatsklinikum Munchen'.",
  "- An organisation's abbreviation and its full name, when unambiguous.",
  "- A translation of one institution's name into another language, when the",
  "  entity is plainly the same: 'Universitair Ziekenhuis Leuven' and",
  "  'University Hospitals Leuven'.",
  "",
  "WHICH NUMBER SURVIVES: prefer the entry with the most raw strings attached,",
  "unless another entry's name is clearly the organisation's correct current form.",
  "Whatever you choose, every member of that family must return the SAME number.",
  "",
  "confidence: one value per entry, 0-1, describing how sure you are of the number",
  "you gave that entry. Use a low value on an entry you were unsure about even if",
  "the rest of the group was obvious.",
  sep = "\n"
)

# entity_type is shown as EVIDENCE, not as a rule. Splitting the group by type
# in R was measured and rejected: it stranded 211 entities whose only neighbour
# was typed differently, and it did not help anyway, because single-type groups
# are just as mixed — one held 'Hospital Universitari de Bellvitge' and
# 'Hospital Universitario de Bellvitge' beside four unrelated Catalan hospitals.
# The type is also model output, so making it a hard barrier would let a
# mistyped entry block a correct merge. Shown, so the model can weigh it.
group_content <- function(g) {
  lines <- sprintf("%d. %s  [%s, %d raw string%s attached]%s",
                   seq_len(nrow(g)), g$canonical,
                   ifelse(is.na(g$entity_type), "unknown", g$entity_type),
                   g$n_strings, ifelse(g$n_strings == 1L, "", "s"),
                   ifelse(is.na(g$parent) | !nzchar(g$parent), "",
                          sprintf("  (parent: %s)", g$parent)))
  list(list(type = "text", text = paste0(
    "Which of these name the same organisation?\n\n",
    paste(lines, collapse = "\n"),
    "\n\nReturn one number per entry, in this order."
  )))
}

# n_strings already rode in on `live`, so no join here — and the sort matters:
# parse_merge breaks a winner tie toward the earliest row, which this makes the
# entity with the most raw strings attached.
work <- tibble::tibble(component = group_ids) |>
  mutate(g = purrr::map(component, ~ groups |>
                          filter(component == .x) |>
                          arrange(desc(n_strings)))) |>
  # Order the WORK by group impact, so --limit samples the groups that matter.
  # Component ids run in entity order, which is effectively alphabetical, so
  # head(work, 5) used to draw '4D Pharma', 'A.N.M.C.O.', 'A.S.L. TO 2' — five
  # correct refusals that exercised nothing. A gate that cannot fail is not a
  # gate: the duplicates this pass exists for sit in the high-impact groups.
  mutate(impact = purrr::map_int(g, ~ sum(.x$n_strings))) |>
  arrange(desc(impact)) |>
  mutate(
    key = purrr::map_chr(g, ~ llm_cache_key(paste(sort(.x$entity_id), collapse = "|"),
                                            PROMPT_VERSION, MODEL_ID)),
    content = purrr::map(g, group_content)
  )

cache <- llm_cache_read(CACHE_PATH)
done  <- if (is.null(cache)) character() else unique(cache$cache_key[!is.na(cache$same_organisation)])
work  <- work |> filter(!key %in% done)
if (!is.na(limit) && limit > 0L) work <- head(work, limit)
message(sprintf("  %d groups to ask (%d cached)", nrow(work), length(done)))
if (!nrow(work)) { message("Nothing to ask."); quit(save = "no", status = 0L) }

# ── Parse ─────────────────────────────────────────────────────────────────────

parse_merge <- function(outcome, item, batch_id = NA_character_) {
  g <- item$g[[1L]]
  n <- nrow(g)
  base <- tibble::tibble(
    cache_key = item$key[[1L]], component = item$component[[1L]],
    model_id = MODEL_ID, prompt_version = PROMPT_VERSION,
    same_organisation = NA, winner_id = NA_character_, loser_id = NA_character_,
    winner_canonical = NA_character_, loser_canonical = NA_character_,
    confidence = NA_real_, reason = NA_character_,
    decided_at_utc = utc_now(), batch_id = batch_id
  )
  if (!outcome$ok) { base$reason <- outcome$error; return(base) }

  why <- outcome$value$reason %||% NA_character_
  tgt <- suppressWarnings(as.integer(unlist(outcome$value$merge_into)))
  if (length(tgt) != n) {
    base$reason <- sprintf("merge_into has %d entries, group has %d",
                           length(tgt), n)
    return(base)
  }
  if (anyNA(tgt) || any(tgt < 1L | tgt > n)) {
    base$reason <- sprintf("merge_into out of range 1..%d", n)
    return(base)
  }
  conf <- suppressWarnings(as.numeric(unlist(outcome$value$confidence)))
  # A scalar confidence is tolerated rather than rejected: it is a well-formed
  # answer to a slightly different question, and refusing it would throw away a
  # correct partition over a formatting choice.
  if (length(conf) == 1L) conf <- rep(conf, n)
  if (length(conf) != n) conf <- rep(NA_real_, n)

  # Resolve through union-find rather than following the pointers directly.
  # The model may answer 3->2 and 2->1, or even 1->2 and 2->1; both mean one
  # family, and closure over the edges gets there without special-casing chains
  # or cycles.
  fam <- components_of(tibble::tibble(a = seq_len(n), b = tgt), n_nodes = n)

  rows <- purrr::map_dfr(unique(fam), function(f) {
    idx <- which(fam == f)
    if (length(idx) < 2L) return(NULL)
    # The survivor is the member the model pointed AT most often; ties break
    # toward the entry with the most raw strings, which is the order `g` is
    # already sorted in.
    votes  <- vapply(idx, function(i) sum(tgt[idx] == i), integer(1))
    winner <- idx[which.max(votes)]
    losers <- setdiff(idx, winner)
    tibble::tibble(
      cache_key = item$key[[1L]], component = item$component[[1L]],
      model_id = MODEL_ID, prompt_version = PROMPT_VERSION,
      same_organisation = TRUE,
      winner_id = g$entity_id[[winner]], loser_id = g$entity_id[losers],
      winner_canonical = g$canonical[[winner]],
      loser_canonical = g$canonical[losers],
      # The loser's own confidence: --apply gates row by row, so a shaky member
      # is dropped without vetoing the confident merges beside it.
      confidence = conf[losers], reason = why,
      decided_at_utc = utc_now(), batch_id = batch_id
    )
  })

  # A group where everything stands alone is a real answer, not a failure. It
  # still needs a cache row, or the group is re-asked on every run.
  if (!nrow(rows)) {
    base$same_organisation <- FALSE
    base$confidence <- suppressWarnings(min(conf, na.rm = TRUE))
    if (!is.finite(base$confidence)) base$confidence <- NA_real_
    base$reason <- why
    return(base)
  }
  rows
}

CACHE_COLS <- c("cache_key", "component", "model_id", "prompt_version",
                "same_organisation", "winner_id", "loser_id", "winner_canonical",
                "loser_canonical", "confidence", "reason", "decided_at_utc", "batch_id")

save_rows <- function(rows) {
  llm_cache_write(llm_cache_merge(cache, rows, "cache_key")[, CACHE_COLS],
                  CACHE_PATH, sort_by = "component")
  # One row per LOSER, so a group can contribute several families and several
  # rows. Count both, or a 5-into-1 merge is indistinguishable from five pairs.
  merged  <- rows |> filter(same_organisation %in% TRUE)
  fams    <- nrow(dplyr::distinct(merged, component, winner_id))
  intact  <- sum(rows$same_organisation %in% FALSE)
  message(sprintf(
    "wrote %d rows (%d entities folded into %d survivors, %d groups left intact, %d failed)",
    nrow(rows), nrow(merged), fams, intact, sum(is.na(rows$same_organisation))))
  multi <- merged |> count(component, winner_id) |> filter(n > 1L)
  if (nrow(multi)) {
    message(sprintf("  %d survivor(s) absorbed more than one entity — the case the",
                    nrow(multi)))
    message("  old boolean schema could not express")
  }
  message("Nothing merged yet. Review ", basename(CACHE_PATH), " then run --apply.")
}

# ── Modes ─────────────────────────────────────────────────────────────────────

spec <- llm_spec(MODEL_ID, PROMPT_VERSION, SYSTEM_PROMPT, MERGE_SCHEMA,
                 effort = "low", max_tokens = MAX_TOKENS)

if (dry_run) {
  est <- llm_dry_run(spec, work, label = paste("D_consolidate /", MODEL_ID),
                   spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_batch, SPEND_PATH, "D_consolidate")
  quit(save = "no", status = 0L)
}

auth <- llm_auth()

if (do_sync) {
  save_rows(llm_sync(spec, work, parse = function(o, it) parse_merge(o, it), auth = auth))
  quit(save = "no", status = 0L)
}

if (!is.na(poll_batch)) {
  llm_batch_wait(poll_batch, auth)
  save_rows(llm_batch_results(poll_batch, work, parse = parse_merge, auth = auth))
  u <- llm_batch_usage(poll_batch, auth)
  if (!is.null(u)) llm_spend_record(SPEND_PATH, "D_consolidate", poll_batch, MODEL_ID,
                                    u$input, u$output, u$cache_read,
                     n_requests = u$n %||% nrow(work))
  quit(save = "no", status = 0L)
}

est <- llm_dry_run(spec, work, label = paste("D_consolidate /", MODEL_ID),
                   spend_path = SPEND_PATH)
llm_budget_guard(est$est_cost_batch, SPEND_PATH, "D_consolidate")
bid <- llm_batch_submit(spec, work, auth)
llm_batch_wait(bid, auth)
save_rows(llm_batch_results(bid, work, parse = parse_merge, auth = auth))
u <- llm_batch_usage(bid, auth)
if (!is.null(u)) {
  llm_spend_record(SPEND_PATH, "D_consolidate", bid, MODEL_ID, u$input, u$output, u$cache_read,
                     n_requests = u$n %||% nrow(work))
  message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
}
