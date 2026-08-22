#!/usr/bin/env Rscript
# Pass A — resolve raw substance strings against ChEMBL and EPAR.
#
# DETERMINISTIC, OFFLINE, FREE, RE-RUNNABLE. No model is involved and no API is
# called. This is the pass that makes substance normalisation cheap: measured on
# the real corpus it resolves 67,801 of 98,842 trial-substance pairs (68.6%)
# before a single token is spent.
#
# THIS IS WHY THE SUBSTANCE PIPELINE IS NOT A COPY OF THE SPONSOR ONE.
# Sponsors had no canonical vocabulary, so pass B had to MINT one and pass C
# assigned against it. Substances already have a vocabulary — ChEMBL's
# pref_name plus the EMA medicines report — so the order inverts:
#
#   sponsors:   block -> mint -> assign -> consolidate -> emit
#   substances: RESOLVE -> assign -> mint -> consolidate -> emit
#
# The model is only asked about what the registry could not place, which is
# 11,189 strings rather than 33,530.
#
# Usage
#   Rscript helper_scripts/substance_norm_pipeline_v2/A_resolve.R
#   Rscript .../A_resolve.R --refresh-chembl    # re-fetch ChEMBL (needs network)
#   Rscript .../A_resolve.R --refresh-epar      # re-fetch the EMA report
#
# Outputs
#   $SUBSTANCE_V2_DIR/registry.csv          one entity per registry canonical
#   $SUBSTANCE_V2_DIR/assignments.csv       raw_substance -> entity_id
#   $SUBSTANCE_V2_DIR/registry_aliases.csv  entity_id -> alias, for B_assign's index
#   $DATA_DIR/substance_residue.csv         what the model must answer
#   $DATA_DIR/substance_rejected.csv        strings judged not-a-substance here

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(stringr)
  library(tibble)
  library(purrr)
})

script_path <- local({
  a <- commandArgs(FALSE); hit <- a[grepl("^--file=", a)]
  if (length(hit)) normalizePath(sub("^--file=", "", hit[[1L]]), mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
pp <- function(...) file.path(project_root, ...)

source(pp("helper_scripts", "llm_norm", "registry.R"), local = FALSE)
source(pp("helper_scripts", "substance_norm_pipeline_v2", "substance_common.R"), local = FALSE)

args <- commandArgs(trailingOnly = TRUE)
refresh_chembl <- "--refresh-chembl" %in% args
refresh_epar   <- "--refresh-epar"   %in% args
# Applies manual_overrides.csv to the EXISTING registry and exits. The full
# rebuild below is destructive once B and C have run, so overrides need a way in
# that does not go through it.
overrides_only <- "--apply-overrides" %in% args
force_rebuild  <- "--force" %in% args
# Classifies only strings the pipeline has never seen and APPENDS the result,
# leaving every existing entity and assignment untouched. This is what a nightly
# needs: the corpus gains a few hundred strings, and without it they stay
# unlabelled forever because the full rebuild is (correctly) refused.
incremental    <- "--incremental" %in% args

# Mutable state lives outside the work tree on the server: the nightly deploy
# runs `git reset --hard origin/main`, which would discard anything written into
# a tracked directory. Same rationale as SPONSOR_V2_DIR.
V2_DIR   <- Sys.getenv("SUBSTANCE_V2_DIR", unset = pp("config", "substance_norm_v2"))
DATA_DIR <- Sys.getenv("DATA_DIR",         unset = pp("data"))

RAW_PATH      <- file.path(DATA_DIR, "trial_substances_raw.csv")
CHEMBL_CACHE  <- file.path(V2_DIR, "chembl_cache.csv")
EPAR_CACHE    <- file.path(V2_DIR, "epar_cache.csv")
REG_PATH      <- file.path(V2_DIR, "registry.csv")
ASG_PATH      <- file.path(V2_DIR, "assignments.csv")
ALIAS_PATH    <- file.path(V2_DIR, "registry_aliases.csv")
RESIDUE_PATH  <- file.path(DATA_DIR, "substance_residue.csv")
REJECT_PATH   <- file.path(DATA_DIR, "substance_rejected.csv")

REGISTRY_VERSION <- "substance-registry-v1"

dir.create(V2_DIR, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(RAW_PATH)) {
  stop("Missing ", RAW_PATH, " — run 1_export_trial_substances.R first.", call. = FALSE)
}

OVERRIDE_PATH <- pp("helper_scripts", "substance_norm_pipeline_v2", "manual_overrides.csv")
# ChEMBL pref_names are USAN. This corpus is EU trial submissions and the
# canonical-granularity decision is the INN, so the handful of entities where
# the two genuinely differ are renamed. Measured: 11 entities, 405 trial labels.
# Not a translation layer — a rename of names the reference registry states in
# a different standard from the one this app displays.
INN_PATH <- pp("helper_scripts", "substance_norm_pipeline_v2", "inn_names.csv")

apply_inn_names <- function(reg) {
  if (!file.exists(INN_PATH)) return(reg)
  inn <- read_csv(INN_PATH, show_col_types = FALSE, progress = FALSE) |>
    filter(!is.na(chembl_pref_name), !is.na(inn), nzchar(trimws(inn)))
  if (!nrow(inn)) return(reg)
  k <- fold1(reg$canonical)
  m <- match(k, fold1(inn$chembl_pref_name))
  hit <- which(!is.na(m) & is.na(reg$merged_into))
  if (!length(hit)) return(reg)

  # RENAMING CAN COLLIDE. The registry may already hold the INN name as its own
  # entity — ChEMBL lists both "Cyclosporine" and "Ciclosporin" — so a blind
  # rename produces two live entities with the same canonical, which is a
  # duplicate the rest of the pipeline has no way to notice. Where the target
  # already exists, MERGE into it instead of renaming.
  live_k <- ifelse(is.na(reg$merged_into), fold1(reg$canonical), NA_character_)
  renamed <- 0L; merged <- 0L
  for (i in hit) {
    target <- inn$inn[[m[[i]]]]
    j <- which(live_k == fold1(target) & seq_along(live_k) != i)
    if (length(j)) {
      reg$merged_into[[i]] <- reg$entity_id[[j[[1L]]]]
      reg$note[[i]] <- paste0("merged into the INN-named entity '", target, "'")
      live_k[[i]] <- NA_character_
      merged <- merged + 1L
      message(sprintf("  INN merge : %-24s -> %s (already present)", reg$canonical[[i]], target))
    } else {
      message(sprintf("  INN rename: %-24s -> %s", reg$canonical[[i]], target))
      reg$canonical[[i]] <- target
      live_k[[i]] <- fold1(target)
      renamed <- renamed + 1L
    }
  }
  message(sprintf("INN names: %d renamed, %d merged into an existing INN entity",
                  renamed, merged))
  reg
}
fold1 <- function(x) tolower(str_squish(stringi::stri_trans_general(x, "Latin-ASCII")))

# Pin the hand-mapped strings onto whatever registry currently exists.
apply_overrides <- function(reg, resolved) {
  if (!file.exists(OVERRIDE_PATH)) return(list(registry = reg, resolved = resolved))
  ov_all <- read_csv(OVERRIDE_PATH, show_col_types = FALSE, progress = FALSE) |>
    filter(!is.na(raw_substance), nzchar(trimws(raw_substance)))

  # An EMPTY canonical means "this string names no substance". Needed for ATC
  # drug-class names — "Beta-blockers", "ANTIVIRALS FOR SYSTEMIC USE",
  # "UROLOGICALS" — which are categories, not molecules. They cannot be mapped to
  # a canonical, and the junk filter cannot recognise them without a class list
  # it has no business maintaining. They are appended to the rejected audit file,
  # which is the same place the deterministic filter's output goes and which
  # E_emit already treats as not-a-substance.
  not_sub <- ov_all |> filter(is.na(canonical) | !nzchar(trimws(canonical)))
  if (nrow(not_sub)) {
    prev <- if (file.exists(REJECT_PATH)) {
      read_csv(REJECT_PATH, show_col_types = FALSE, progress = FALSE)
    } else NULL
    add <- not_sub |> transmute(raw_substance, n_trials = NA_integer_,
                                reason = coalesce(reason, "manual override: not a substance"))
    write_csv(bind_rows(prev, add) |> distinct(raw_substance, .keep_all = TRUE),
              REJECT_PATH, na = "", eol = "\n")
    message(sprintf("manual overrides: %d string(s) marked not-a-substance", nrow(not_sub)))
  }

  ov <- ov_all |> filter(!is.na(canonical), nzchar(trimws(canonical)))
  if (!nrow(ov)) return(list(registry = reg, resolved = resolved))
  known <- setNames(reg$entity_id, fold1(reg$canonical))
  ov$entity_id <- unname(known[fold1(ov$canonical)])
  fresh <- ov |> filter(is.na(entity_id)) |> distinct(canonical)
  if (nrow(fresh)) {
    add <- registry_add(reg, canonical = fresh$canonical, confidence = 1.0,
                        decided_by = "human", model_id = "manual",
                        prompt_version = REGISTRY_VERSION,
                        note = "manual override: bio classifier refuses the raw string")
    reg <- add$registry
    known <- c(known, setNames(add$entity_ids, fold1(fresh$canonical)))
    ov$entity_id <- unname(known[fold1(ov$canonical)])
  }
  rows <- ov |> transmute(raw_substance, entity_id, confidence = 1.0, channel = "manual",
                          reason, decided_by = "human", decided_at_utc = utc_now(),
                          model_id = "manual", prompt_version = REGISTRY_VERSION)
  message(sprintf("manual overrides: %d string(s) pinned (%d new entities)",
                  nrow(ov), nrow(fresh)))
  list(registry = reg,
       resolved = bind_rows(resolved |> filter(!raw_substance %in% rows$raw_substance), rows))
}

# Collapse duplicate live entities. Deterministic, idempotent, no model.
#
# Two ways duplicates arise after the model passes have run:
#   1. Two live entities share an identical canonical. The INN rename above can
#      create this — ChEMBL lists both "Cyclosporine" and "Ciclosporin", so
#      renaming one produced two live entities with the same name.
#   2. A model-minted canonical is an unambiguous ChEMBL alias of another live
#      entity ("Calcium folinate" is an alias of Leucovorin). C_mint's re-join
#      catches most of these at materialise time, but not ones whose target was
#      merged away afterwards by D_consolidate.
#
# Rule 2 only ever merges a MODEL-MINTED entity away, never a registry-derived
# one, and only on an alias that names exactly one substance.
dedup_registry <- function(reg, asg) {
  merges <- tibble(loser_id = character(), winner_id = character(), reason = character())
  live <- registry_live(reg)
  if (!nrow(live)) return(list(registry = reg, assignments = asg, n = 0L))
  imp <- asg |> mutate(entity_id = resolve_entity(reg, entity_id)) |> count(entity_id, name = "n")
  live <- live |> left_join(imp, by = "entity_id") |> mutate(n = coalesce(n, 0L))

  d1 <- live |> mutate(k = fold1(canonical)) |> group_by(k) |> filter(dplyr::n() > 1L) |>
    arrange(desc(n), entity_id) |> mutate(win = first(entity_id)) |> ungroup() |>
    filter(entity_id != win)
  if (nrow(d1)) {
    merges <- bind_rows(merges, d1 |> transmute(loser_id = entity_id, winner_id = win,
      reason = paste0("duplicate canonical '", canonical, "'")))
  }

  if (file.exists(ALIAS_PATH)) {
    au <- read_csv(ALIAS_PATH, show_col_types = FALSE, progress = FALSE) |>
      mutate(entity_id = resolve_entity(reg, entity_id)) |>
      filter(entity_id %in% live$entity_id) |>
      mutate(k = fold1(alias)) |> group_by(k) |>
      filter(n_distinct(entity_id) == 1L) |> slice(1) |> ungroup()
    amap <- setNames(au$entity_id, au$k)
    d2 <- live |> filter(decided_by == "model", !entity_id %in% merges$loser_id) |>
      mutate(tgt = unname(amap[fold1(canonical)])) |>
      filter(!is.na(tgt), tgt != entity_id)
    if (nrow(d2)) {
      merges <- bind_rows(merges, d2 |> transmute(loser_id = entity_id, winner_id = tgt,
        reason = paste0("'", canonical, "' is a reference alias of the winning entity")))
    }
  }

  if (!nrow(merges)) return(list(registry = reg, assignments = asg, n = 0L))
  nm <- setNames(reg$canonical, reg$entity_id)
  for (i in seq_len(min(8L, nrow(merges)))) {
    message(sprintf("  dedup: %-34s -> %s", substr(nm[[merges$loser_id[[i]]]], 1, 34),
                    nm[[merges$winner_id[[i]]]]))
  }
  out <- registry_apply_merges(reg, asg, merges, model_id = "rule",
                               prompt_version = REGISTRY_VERSION)
  message(sprintf("dedup: merged %d duplicate entity/entities", out$applied))
  list(registry = out$registry, assignments = out$assignments, n = out$applied)
}

if (overrides_only) {
  reg0 <- registry_read(REG_PATH)
  asg0 <- assignments_read(ASG_PATH, raw_col = "raw_substance")
  if (!nrow(reg0)) stop("No registry at ", REG_PATH, call. = FALSE)
  out <- apply_overrides(reg0, asg0)
  out$registry <- apply_inn_names(out$registry)
  dd <- dedup_registry(out$registry, out$resolved)
  registry_write(dd$registry, REG_PATH)
  assignments_write(dd$assignments, ASG_PATH, raw_col = "raw_substance")
  out <- list(registry = dd$registry, resolved = dd$assignments)
  message(sprintf("registry: %d entities, assignments: %d",
                  nrow(out$registry), nrow(out$resolved)))
  quit(save = "no", status = 0L)
}

# THE FULL REBUILD IS DESTRUCTIVE ONCE B AND C HAVE RUN. It writes registry.csv
# and assignments.csv from the reference tables alone, so every model-minted
# entity and every model assignment is discarded. Refuse rather than explain it
# afterwards.
if (file.exists(ASG_PATH) && !force_rebuild && !incremental) {
  prior <- assignments_read(ASG_PATH, raw_col = "raw_substance")
  n_model <- sum(prior$decided_by %in% c("model", "human"))
  if (n_model > 0L) {
    stop("Refusing to rebuild: ", ASG_PATH, " holds ", n_model,
         " model/human assignments that this pass would discard.\n",
         "  To pin manual_overrides.csv onto the existing registry, use --apply-overrides.\n",
         "  To rebuild from scratch anyway and lose that work, pass --force.",
         call. = FALSE)
  }
}

# ── Reference registries ──────────────────────────────────────────────────────
# Both are cached to disk and committed, so this script runs with no network.
# v1 cached ChEMBL but NOT EPAR: 2_build_substance_index.R downloads the EMA
# spreadsheet unconditionally at every invocation, including under --no-chembl,
# which is advertised as the offline path. That is why it cannot run in CI, in
# the sandbox, or on a plane. Both are cached here.

fetch_chembl <- function() {
  suppressPackageStartupMessages(library(httr2))
  CHEMBL_URL <- "https://www.ebi.ac.uk/chembl/api/data/molecule"
  fetch_page <- function(offset, limit = 1000) {
    httr2::request(CHEMBL_URL) |>
      httr2::req_url_query(format = "json", limit = limit, offset = offset,
                           max_phase__gte = 1) |>
      httr2::req_timeout(60) |> httr2::req_retry(max_tries = 3) |>
      httr2::req_perform() |> httr2::resp_body_json()
  }
  message("fetching ChEMBL molecule count...")
  total <- fetch_page(0, 1)$page_meta$total_count
  n_req <- ceiling(total / 1000)
  message(sprintf("ChEMBL: %d molecules, %d pages", total, n_req))

  parse_molecule <- function(mol) {
    pref <- mol$pref_name
    if (is.null(pref) || is.na(pref) || !nzchar(str_trim(pref))) return(NULL)
    syns <- mol$molecule_synonyms
    if (length(syns) == 0) return(NULL)
    map_dfr(syns, function(s) {
      if (is.null(s$molecule_synonym) || is.null(s$syn_type)) return(NULL)
      # No confidence_prior. v1 attached one here (0.90 trade_name, 0.85
      # usan/ban, 0.65 everything else) and it is dropped deliberately: it is a
      # pure lookup on syn_type, so it carries nothing alias_type does not, and
      # it was never measured. Putting it in the assignment `confidence` column
      # would be worse than useless — that column means "how sure was the model
      # of its own answer" and route_for_review() gates on it, so a 0.65 on the
      # 97,851 plain synonyms would route every registry match to human review.
      # Provenance lives in alias_type and in the assignment reason.
      tibble(
        alias_clean     = clean_alias(s$molecule_synonym),
        substance_clean = clean_substance(pref),
        alias_type      = case_when(s$syn_type == "TRADE_NAME" ~ "trade_name",
                                    s$syn_type == "USAN"       ~ "usan",
                                    s$syn_type == "BAN"        ~ "ban",
                                    TRUE                       ~ "chembl_synonym"),
        source          = "chembl"
      )
    })
  }
  offsets <- seq(0, (n_req - 1) * 1000, by = 1000)
  out <- vector("list", length(offsets))
  for (i in seq_along(offsets)) {
    if (i %% 10 == 1) message(sprintf("  page %d / %d", i, n_req))
    Sys.sleep(0.1)
    out[[i]] <- map_dfr(fetch_page(offsets[i])$molecules, parse_molecule)
  }
  bind_rows(out)
}

fetch_epar <- function() {
  suppressPackageStartupMessages({ library(httr2); library(readxl) })
  EPAR_URL <- paste0("https://www.ema.europa.eu/en/documents/report/",
                     "medicines-output-medicines-report_en.xlsx")
  message("downloading the EMA medicines report...")
  dest <- tempfile(fileext = ".xlsx")
  httr2::request(EPAR_URL) |> httr2::req_timeout(180) |> httr2::req_perform() |>
    httr2::resp_body_raw() |> writeBin(dest)

  # The EMA sheet carries eight metadata rows before its header. v1 hard-coded
  # row 9 and would have mislabelled every column in silence if the layout ever
  # moved, so the header row is located rather than assumed.
  raw_excel <- readxl::read_excel(dest, col_names = FALSE, skip = 0)
  hdr_row <- NA_integer_
  for (i in seq_len(min(30L, nrow(raw_excel)))) {
    vals <- tolower(as.character(unlist(raw_excel[i, ])))
    if (any(grepl("name of medicine", vals, fixed = TRUE)) &&
        any(grepl("active substance", vals, fixed = TRUE))) { hdr_row <- i; break }
  }
  if (is.na(hdr_row)) {
    stop("Could not locate the EMA header row (looked for 'Name of medicine' and ",
         "'Active substance' in the first 30 rows). The sheet layout has changed.",
         call. = FALSE)
  }
  headers <- as.character(unlist(raw_excel[hdr_row, ]))
  data_rows <- raw_excel[(hdr_row + 1L):nrow(raw_excel), ]
  colnames(data_rows) <- headers
  name_col  <- grep("name of medicine", names(data_rows), ignore.case = TRUE, value = TRUE)[1]
  subst_col <- grep("active substance",  names(data_rows), ignore.case = TRUE, value = TRUE)[1]

  data_rows |>
    select(product_name = all_of(name_col), substance = all_of(subst_col)) |>
    filter(!is.na(product_name), !is.na(substance),
           nchar(str_squish(product_name)) > 0, nchar(str_squish(substance)) > 0) |>
    transmute(alias_clean     = clean_alias(product_name),
              substance_clean = clean_substance(substance),
              alias_type      = "ema_product_name",
              source          = "epar") |>
    distinct()
}

load_or_fetch <- function(path, refresh, fetcher, label) {
  if (refresh || !file.exists(path)) {
    if (!refresh) {
      stop(label, " cache not found: ", path, "\n",
           "  Seed it from the v1 index with seed_caches.R, or fetch it with --refresh-",
           tolower(label), " (needs network).", call. = FALSE)
    }
    x <- fetcher()
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    write_csv(x, path, na = "", eol = "\n")
    message(sprintf("%s: fetched %d rows, cached to %s", label, nrow(x), basename(path)))
    x
  } else {
    x <- read_csv(path, show_col_types = FALSE, progress = FALSE)
    need <- c("alias_clean", "substance_clean", "alias_type", "source")
    if (!all(need %in% names(x))) {
      stop(label, " cache has the wrong schema: ", path, "\n",
           "  expected ", paste(need, collapse = ", "), "\n",
           "  found    ", paste(names(x), collapse = ", "), call. = FALSE)
    }
    message(sprintf("%s: %d rows from cache", label, nrow(x)))
    x
  }
}

chembl <- load_or_fetch(CHEMBL_CACHE, refresh_chembl, fetch_chembl, "ChEMBL")
epar   <- load_or_fetch(EPAR_CACHE,   refresh_epar,   fetch_epar,   "EPAR")

# EPAR first: an EMA-authorised product name is better evidence than a ChEMBL
# synonym, and where the two disagree on a name the EU label should win.
ref <- bind_rows(epar, chembl) |>
  filter(!is.na(alias_clean), !is.na(substance_clean),
         nchar(alias_clean) >= 3, nchar(substance_clean) >= 3) |>
  distinct(alias_clean, substance_clean, .keep_all = TRUE)

message(sprintf("reference table: %d alias->substance pairs, %d distinct canonicals",
                nrow(ref), n_distinct(ref$substance_clean)))

# ── Corpus ────────────────────────────────────────────────────────────────────

raw <- read_csv(RAW_PATH, show_col_types = FALSE, progress = FALSE,
                col_types = cols(`_id` = col_character(), raw_substance = col_character()))
strings <- raw |>
  filter(!is.na(raw_substance), nzchar(trimws(raw_substance))) |>
  count(raw_substance, name = "n_trials") |>
  arrange(desc(n_trials), raw_substance)

message(sprintf("corpus: %d distinct raw strings over %d trial-substance pairs",
                nrow(strings), sum(strings$n_trials)))

prior_asg <- if (file.exists(ASG_PATH)) assignments_read(ASG_PATH, raw_col = "raw_substance") else NULL
if (incremental) {
  seen <- unique(c(
    if (!is.null(prior_asg)) prior_asg$raw_substance else character(),
    if (file.exists(file.path(V2_DIR, "B_not_substance.csv")))
      read_csv(file.path(V2_DIR, "B_not_substance.csv"), show_col_types = FALSE,
               progress = FALSE)$raw_substance else character(),
    if (file.exists(file.path(V2_DIR, "C_not_substance.csv")))
      read_csv(file.path(V2_DIR, "C_not_substance.csv"), show_col_types = FALSE,
               progress = FALSE)$raw_substance else character(),
    if (file.exists(REJECT_PATH))
      read_csv(REJECT_PATH, show_col_types = FALSE, progress = FALSE)$raw_substance
      else character()
  ))
  before <- nrow(strings)
  strings <- strings |> filter(!raw_substance %in% seen)
  message(sprintf("--incremental: %d of %d strings are new (%d trial pairs)",
                  nrow(strings), before, sum(strings$n_trials)))
  if (!nrow(strings)) {
    message("Nothing new. Registry and assignments unchanged.")
    quit(save = "no", status = 0L)
  }
}

# ── Classify ──────────────────────────────────────────────────────────────────
# Order matters and matches v1: placebo, then junk, then the candidate ladder.

n_sub <- ref |> count(alias_clean, name = "n_subst")
alias_n <- setNames(n_sub$n_subst, n_sub$alias_clean)

# IDENTITY BREAKS A TIE. An alias mapping to several substances is normally the
# model's problem, but not when one of those substances IS the alias:
# "tacrolimus" resolves to {tacrolimus, tacrolimus anhydrous}, and the bare INN
# is both the right answer and the one the INN-base decision asks for. v1 had
# this rule (normalise_substances.R:274) and it is worth keeping.
#
# Measured: it settles 85 of the 712 ambiguous strings, covering 419 trial
# pairs — TACROLIMUS (126 trials), Fingolimod, Cefuroxime, Bicalutamide. The
# remaining 627 are brand-plus-strength strings like "TAGRISSO 80 mg
# film-coated tablets", which genuinely need a decision.
identity_alias <- ref |>
  group_by(alias_clean) |>
  filter(n_distinct(substance_clean) > 1L, any(alias_clean == substance_clean)) |>
  ungroup() |>
  distinct(alias_clean) |>
  pull(alias_clean)

# The candidate ladder is v1's, unchanged, because it is the part that worked:
# raw -> dose-stripped -> form-stripped -> first token. Every measurement in
# PLANS/substance-normalisation-v2.md was taken with it.
cands <- map(strings$raw_substance, generate_candidates)
hit_alias <- map_chr(cands, function(cc) {
  h <- cc[cc %in% names(alias_n)]
  if (!length(h)) NA_character_ else h[[1L]]
})

strings <- strings |>
  mutate(
    hit_alias = hit_alias,
    n_subst   = unname(ifelse(is.na(hit_alias), NA_integer_, alias_n[hit_alias])),
    is_ident  = !is.na(hit_alias) & hit_alias %in% identity_alias,
    class = case_when(
      is_placebo(raw_substance)                    ~ "placebo",
      !is.na(n_subst) & n_subst == 1               ~ "registry",
      is_ident                                     ~ "registry",
      is_junk_string(raw_substance)                ~ "rejected",
      !is.na(n_subst) & n_subst > 1                ~ "ambiguous",
      TRUE                                         ~ "residue"
    )
  )

# A registry hit outranks the junk filter deliberately: if ChEMBL knows the
# string, the filter's opinion that it looks like packaging is wrong. "Water for
# injection" and "Sodium chloride" are real ChEMBL molecules and real IMPs.
# The ambiguous class sits BELOW the filter for the mirror reason — a
# multi-substance alias is weak evidence and not worth overriding it with.

cat("\n=== pass A classification ===\n")
print(as.data.frame(
  strings |> group_by(class) |>
    summarise(distinct_strings = n(), trial_pairs = sum(n_trials), .groups = "drop") |>
    arrange(desc(trial_pairs))
))
cat(sprintf("\ntotal: %d strings / %d trial-substance pairs\n",
            nrow(strings), sum(strings$n_trials)))

# ── Build the registry ────────────────────────────────────────────────────────
# One entity per distinct reference canonical. Every canonical is minted, not
# only the ones the corpus reached, because B_assign retrieves against the whole
# vocabulary — that is what lets "metotrexate" find "methotrexate" even though
# no corpus string spells it correctly.

canon <- sort(unique(ref$substance_clean))
# --incremental keeps the registry exactly as it is: the reference vocabulary is
# already minted, and re-minting it would issue new entity_ids for entities that
# already exist, orphaning every assignment that points at the old ones.
reg <- if (incremental && !is.null(prior_asg)) registry_read(REG_PATH) else registry_empty()
existing_canon <- if (nrow(reg)) setNames(reg$entity_id, tolower(reg$canonical)) else character()
canon <- canon[!tolower(display_substance(canon)) %in% names(existing_canon)]
added <- registry_add(
  reg,
  canonical      = display_substance(canon),
  confidence     = 1.0,
  decided_by     = "registry",
  model_id       = "chembl+epar",
  prompt_version = REGISTRY_VERSION,
  note           = canon                    # the lowercase key it was built from
)
reg <- added$registry
entity_of_canon <- c(
  setNames(added$entity_ids, canon),
  # Pre-existing entities, keyed on the same lowercase reference name so a
  # --incremental run resolves onto them rather than minting duplicates.
  if (nrow(reg)) setNames(reg$entity_id, tolower(coalesce(reg$note, reg$canonical))) else character()
)

message(sprintf("registry: %d entities minted from the reference vocabulary", nrow(reg)))

# Alias table, keyed to entity ids. B_assign indexes this ALONGSIDE the observed
# surface forms. Indexing canonicals alone was measured and is materially worse:
# "BNT162b2" is not a ChEMBL pref_name but IS a ChEMBL synonym, so it scores 1.00
# against the alias table and nothing against the canonical list.
aliases <- ref |>
  transmute(entity_id = unname(entity_of_canon[substance_clean]),
            alias     = alias_clean,
            alias_type, source) |>
  filter(!is.na(entity_id)) |>
  distinct(entity_id, alias, .keep_all = TRUE)

# ── Assignments ───────────────────────────────────────────────────────────────

# Identity rows sort first, so an alias that is also a substance name resolves to
# ITSELF rather than to whichever variant happened to come first in the file.
# Without this, "tacrolimus" could land on "tacrolimus anhydrous" — the tie-break
# above would fire and still pick the wrong side of it.
canon_of_alias <- ref |>
  arrange(desc(alias_clean == substance_clean)) |>
  distinct(alias_clean, .keep_all = TRUE)
canon_lut <- setNames(canon_of_alias$substance_clean, canon_of_alias$alias_clean)

# confidence stays 1.0 for both channels: an exact string match against a curated
# chemistry registry is exact, and inventing a lower number for the tie-break
# would be the same unmeasured-judgement move that got confidence_prior dropped.
# What distinguishes them is a FACT, so it goes in `channel`: "registry" is an
# unambiguous single-candidate hit, "registry_identity" is one where the alias
# mapped to several substances and the identity rule picked the bare INN. The
# second kind is a rule applied to an ambiguity and is worth being able to find.
resolved <- strings |>
  filter(class == "registry") |>
  transmute(
    raw_substance,
    entity_id      = unname(entity_of_canon[unname(canon_lut[hit_alias])]),
    confidence     = 1.0,
    channel        = if_else(is_ident, "registry_identity", "registry"),
    reason         = if_else(
      is_ident,
      paste0("registry alias '", hit_alias, "' names several substances; ",
             "identity rule chose the one it is identical to"),
      paste0("exact registry match: '", hit_alias, "'")
    ),
    decided_by     = "registry",
    decided_at_utc = utc_now(),
    model_id       = "chembl+epar",
    prompt_version = REGISTRY_VERSION
  ) |>
  filter(!is.na(entity_id))

# Placebo is its own entity. v1 had a placebo_rule producing the bare string;
# giving it an entity keeps every assignment pointing at the registry, so E_emit
# needs no special case and the reviewer app sees one more ordinary row.
plac <- strings |> filter(class == "placebo")
if (nrow(plac)) {
  pa <- registry_add(reg, canonical = "Placebo", entity_type = "placebo",
                     confidence = 1.0, decided_by = "registry",
                     model_id = "rule", prompt_version = REGISTRY_VERSION,
                     note = "placebo rule")
  reg <- pa$registry
  resolved <- bind_rows(resolved, plac |> transmute(
    raw_substance, entity_id = pa$entity_ids[[1L]], confidence = 1.0,
    channel = "placebo", reason = "placebo rule", decided_by = "registry",
    decided_at_utc = utc_now(), model_id = "rule", prompt_version = REGISTRY_VERSION
  ))
}

ov_out  <- apply_overrides(reg, resolved)
reg      <- apply_inn_names(ov_out$registry)
resolved <- ov_out$resolved

asg <- assignments_empty("raw_substance") |> bind_rows(resolved)
if (incremental && !is.null(prior_asg)) {
  # Existing rows win: a human pin or a model decision already made must not be
  # replaced by a fresh registry match for the same string.
  asg <- bind_rows(prior_asg, asg |> filter(!raw_substance %in% prior_asg$raw_substance))
}

registry_write(reg, REG_PATH)
assignments_write(asg, ASG_PATH, raw_col = "raw_substance")
if (!incremental) write_csv(aliases, ALIAS_PATH, na = "", eol = "\n")

# ── Residue and rejects ───────────────────────────────────────────────────────
# Both are written out. A filter whose output nobody can read is the same class
# of problem as a regression gate that stops measuring: it keeps working long
# after it stops being right.

residue <- strings |>
  filter(class %in% c("residue", "ambiguous")) |>
  transmute(raw_substance, n_trials,
            reason = if_else(class == "ambiguous",
                             "registry alias maps to several substances",
                             "no registry hit")) |>
  arrange(desc(n_trials), raw_substance)

rejected <- strings |>
  filter(class == "rejected") |>
  transmute(raw_substance, n_trials, reason = junk_reason(raw_substance)) |>
  arrange(desc(n_trials), raw_substance)

if (incremental) {
  # Append: the residue is B_assign's work list and the reject file is the audit
  # trail. Overwriting either with just this run's rows loses the earlier ones —
  # the same defect B_abstained.csv had (see the handover, §4.7b).
  prev_res <- if (file.exists(RESIDUE_PATH)) read_csv(RESIDUE_PATH, show_col_types = FALSE, progress = FALSE) else NULL
  prev_rej <- if (file.exists(REJECT_PATH))  read_csv(REJECT_PATH,  show_col_types = FALSE, progress = FALSE) else NULL
  residue  <- bind_rows(prev_res, residue)  |> distinct(raw_substance, .keep_all = TRUE) |> arrange(desc(n_trials))
  rejected <- bind_rows(prev_rej, rejected) |> distinct(raw_substance, .keep_all = TRUE) |> arrange(desc(n_trials))
}
write_csv(residue,  RESIDUE_PATH, na = "", eol = "\n")
write_csv(rejected, REJECT_PATH,  na = "", eol = "\n")

cat(sprintf("\nwrote %s (%d entities)\n", basename(REG_PATH), nrow(reg)))
cat(sprintf("wrote %s (%d assignments)\n", basename(ASG_PATH), nrow(asg)))
cat(sprintf("wrote %s (%d alias rows)\n", basename(ALIAS_PATH), nrow(aliases)))
cat(sprintf("wrote %s (%d strings / %d trial pairs for the model)\n",
            basename(RESIDUE_PATH), nrow(residue), sum(residue$n_trials)))
cat(sprintf("wrote %s (%d strings / %d trial pairs rejected here)\n",
            basename(REJECT_PATH), nrow(rejected), sum(rejected$n_trials)))

cat("\n=== top 15 residue strings by trial count (B_assign's most valuable work) ===\n")
for (i in seq_len(min(15L, nrow(residue)))) {
  cat(sprintf("   %5d  %s\n", residue$n_trials[[i]], substr(residue$raw_substance[[i]], 1L, 80L)))
}

cat("\n=== top 10 rejected strings by trial count (READ THESE) ===\n")
cat("If a real substance appears here, the junk filter is too aggressive.\n")
for (i in seq_len(min(10L, nrow(rejected)))) {
  cat(sprintf("   %5d  %-58s %s\n", rejected$n_trials[[i]],
              substr(rejected$raw_substance[[i]], 1L, 58L), rejected$reason[[i]]))
}

cat("\nNothing was decided by a model. B_assign asks about the residue.\n")
