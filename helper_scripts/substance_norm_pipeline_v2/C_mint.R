#!/usr/bin/env Rscript
# Pass C — mint canonicals for the substances the registry does not contain.
#
# This runs LAST of the two model passes, not first. Sponsors minted before
# assigning because no vocabulary existed; here ChEMBL and EPAR supply 17,272
# canonicals up front, so minting is the residue of a residue — code names
# (BNT162b2), cell and gene therapies, vaccine antigens, investigational
# compounds and national brands that never reached ChEMBL.
#
# Blocking is folded into this script rather than living in its own pass. For
# sponsors, A_block ran over the whole 16,594-string corpus and was worth tuning
# on its own; here it runs over B_assign's abstentions, which is a much smaller
# set, and splitting it across two scripts would only add a file to keep in sync.
# The tuning report A_block prints is reproduced below, and --threshold and
# --max-block work the same way.
#
# WHY BLOCK AT ALL, given the model does the naming: a cluster must be named
# ONCE with every variant visible in the same request. That is what stops
# "BNT162b2", "BNT-162b2" and "BNT162b2 (Comirnaty)" becoming three canonicals.
#
# SINGLETONS MUST BE MINTED. A string with no lexical neighbour is never in a
# multi-member block, so it would never be minted, so it would stay unassigned
# forever. On the sponsor side this was the single largest hole in the whole
# rewrite (3,837 strings). Expect it to be proportionally worse here: 8,986 of
# the residue strings occur in exactly one trial.
#
# Usage
#   Rscript .../C_mint.R --blocks-only                 # tune, no API call
#   Rscript .../C_mint.R --dry-run
#   Rscript .../C_mint.R --sync --limit=20
#   Rscript .../C_mint.R --batch
#   Rscript .../C_mint.R --batch --singletons
#   Rscript .../C_mint.R --batch --retry-failed --model=claude-opus-5
#   Rscript .../C_mint.R --materialise                 # clusters -> registry

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(purrr); library(jsonlite)
  library(stringr); library(stringi)
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
blocks_only  <- "--blocks-only"  %in% args
dry_run      <- "--dry-run"      %in% args
do_sync      <- "--sync"         %in% args
do_batch     <- "--batch"        %in% args
singletons   <- "--singletons"   %in% args
retry_failed <- "--retry-failed" %in% args
materialise  <- "--materialise"  %in% args
limit        <- suppressWarnings(as.integer(arg_value("--limit")))
poll_batch   <- arg_value("--poll")
model_override <- arg_value("--model")
MAX_BLOCK    <- as.integer(arg_value("--max-block", "20"))
THRESHOLD    <- as.numeric(arg_value("--threshold", "0.5"))

if (!blocks_only && !dry_run && !do_sync && !do_batch && !materialise && is.na(poll_batch)) {
  stop("Pick a mode: --blocks-only, --dry-run, --sync, --batch, --batch --poll=<id>, or --materialise",
       call. = FALSE)
}

# --model is part of the cache key, so an unrestricted override would invalidate
# every cached block and re-mint the whole set at the new price. Same guard as
# B_mint.R, for the same reason.
if (!is.na(model_override) && !(retry_failed || singletons || !is.na(limit))) {
  stop("--model changes the cache key, so on its own it re-mints everything.\n",
       "  Combine it with --retry-failed, --singletons or --limit.", call. = FALSE)
}

PROMPT_VERSION <- "substance-mint-v3"    # v1: told the model flu strain names are
                                        #     not substances; no registry framing.
                                        # v3: canonicals must be NAMES. v2 minted 18
                                        #     raw amino-acid sequences and echoed
                                        #     development codes that have a published
                                        #     INN (JNJ-54767414 = daratumumab).
HEAD_MODEL     <- "claude-opus-5"
TAIL_MODEL     <- "claude-sonnet-5"
HEAD_BLOCKS    <- 200L
MAX_TOKENS     <- 8192L
NGRAM_N        <- 3L

V2       <- Sys.getenv("SUBSTANCE_V2_DIR", unset = pp("config", "substance_norm_v2"))
DATA_DIR <- Sys.getenv("DATA_DIR",         unset = pp("data"))

REG_PATH   <- file.path(V2, "registry.csv")
ASG_PATH   <- file.path(V2, "assignments.csv")
CACHE_PATH <- file.path(V2, "C_mint_clusters.csv")
SPEND_PATH <- file.path(V2, "llm_spend.csv")
BLOCK_PATH <- file.path(V2, "C_blocks.csv")
# Written by A_resolve: alias -> entity_id over the whole ChEMBL/EPAR reference
# table. --materialise uses it to re-join minted canonicals to existing entities.
ALIAS_PATH <- file.path(V2, "registry_aliases.csv")
WORK_PATH  <- arg_value("--only", file.path(V2, "B_abstained.csv"))

# ── Schema: ONE grammar for the whole pass ────────────────────────────────────
# member_index is an integer into the numbered list in the request, never an
# enum of that block's strings, so every request compiles the same grammar.

MINT_SCHEMA <- list(
  type = "object",
  additionalProperties = FALSE,
  required = list("clusters"),
  properties = list(
    clusters = list(
      type = "array",
      items = list(
        type = "object",
        additionalProperties = FALSE,
        required = list("canonical", "member_indices", "substance_type", "confidence"),
        properties = list(
          canonical      = list(type = "string"),
          salt_form      = list(type = "string"),
          brand          = list(type = "string"),
          substance_type = list(type = "string", enum = list(
            "small_molecule", "biologic", "vaccine", "cell_or_gene_therapy",
            "radiopharmaceutical", "blood_product", "diagnostic_agent",
            "supplement_or_excipient", "not_a_substance", "unknown")),
          member_indices = list(type = "array", items = list(type = "integer")),
          confidence     = list(type = "number"),
          reason         = list(type = "string")
        )
      )
    )
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
  "You group variant names of clinical-trial substances and give each group one canonical name.",
  "",
  "You receive a numbered list of raw substance strings from EU trial registries. They",
  "were grouped by a text-similarity step that favours recall, so the list may contain",
  "more than one substance. Split it into clusters, one per substance.",
  "",
  "These strings are the ones a chemistry registry could NOT identify, so expect code",
  "names, cell and gene therapies, vaccine antigens, national brands and misspellings.",
  "",
  "THE CANONICAL IS THE INN BASE.",
  "",
  "  'Methotrexat 10mg Tabletten'   -> canonical 'Methotrexate'",
  "  'Metoject 50 mg/ml'            -> canonical 'Methotrexate', brand 'Metoject'",
  "  'methotrexate sodium'          -> canonical 'Methotrexate', salt_form 'sodium'",
  "  'Seloken ZOK 50 mg'            -> canonical 'Metoprolol',   brand 'Seloken ZOK'",
  "",
  "Strip strength, dosage form, pack size, route and manufacturer from the canonical.",
  "Put the trade name in 'brand' and the salt, ester or hydrate in 'salt_form'. Leave",
  "them empty when they do not apply. Where a substance has no INN, use the name it is",
  "known by: a code name (BNT162b2, AZD1222) or an established descriptive name",
  "('autologous CD34+ cells', 'Haemophilus influenzae type b conjugate').",
  "",
  "RULES",
  "",
  "1. DRUGS WITH SIMILAR NAMES ARE DIFFERENT DRUGS. These strings were grouped by",
  "   character overlap, so the list will contain near-identical names that are not",
  "   the same substance. 'vinblastine' and 'vincristine' are two clusters;",
  "   'cisplatin', 'carboplatin' and 'oxaliplatin' are three; 'daunorubicin' and",
  "   'doxorubicin' are two. Split on knowledge, never on spelling distance.",
  "",
  "2. Different SALTS or ESTERS of one INN are ONE cluster with the INN as canonical.",
  "   'metoprolol succinate' and 'metoprolol tartrate' cluster together as 'Metoprolol'.",
  "   Record whichever salt applies in salt_form; if members differ, leave it empty.",
  "",
  "3. Different STRENGTHS or FORMS of one product are ONE cluster.",
  "   'TAGRISSO 40 mg' and 'TAGRISSO 80 mg film-coated tablets' are both 'Osimertinib'.",
  "",
  "4. A CODE NAME matches only the same code. 'BNT162b2' and 'BNT162b1' are DIFFERENT",
  "   compounds, as are 'AZD1222' and 'AZD7442'. Never merge two codes.",
  "",
  "   BUT: IF THE CODE HAS A PUBLISHED INN, USE THE INN as the canonical and put the",
  "   code in 'brand'. A development code is not a name a reader recognises.",
  "     MK-3475      -> canonical 'Pembrolizumab', brand 'MK-3475'",
  "     JNJ-54767414 -> canonical 'Daratumumab',   brand 'JNJ-54767414'",
  "     MK-5592      -> canonical 'Posaconazole',  brand 'MK-5592'",
  "     BNT162b2     -> canonical 'Tozinameran',   brand 'BNT162b2'",
  "   Keep the bare code ONLY when no INN has been assigned, which is the normal case",
  "   for early-phase compounds (MK-1084, JNJ-77242113). Do not guess an INN you are",
  "   not sure of — an unresolved code is fine, a wrong drug name is not.",
  "",
  "5. THE CANONICAL IS A NAME, NOT A DESCRIPTION OR A SEQUENCE.",
  "   Never use as a canonical: an amino-acid sequence ('H-Ala-Val-Ser-Glu-...-OH'), a",
  "   chemical formula, a full product description, or storage/route/packaging prose.",
  "   These appear verbatim in the source data and are useless as a chart label.",
  "   Give a SHORT readable name, at most 60 characters, identifying what it is:",
  "     'H-Leu-Tyr-Cys-Tyr-Glu-Gln-Leu-Asn-Asp-...-OH'  -> 'HPV16 E6 synthetic long peptide'",
  "     'Ala-Val-Ser-Glu-His-Gln-Leu-...-NH2'           -> 'Parathyroid hormone analogue peptide'",
  "   If you cannot identify the peptide, name it by what it plainly is",
  "   ('Synthetic peptide') rather than repeating the sequence.",
  "",
  "6. A COMBINATION product is its own cluster, with the components joined by '|' in",
  "   alphabetical order: 'amoxicillin|clavulanic acid'. Do not split it into two.",
  "",
  "7. VACCINE COMPONENTS ARE SUBSTANCES, and this dataset is full of them. A strain",
  "   designation, an antigen, a toxoid or a serotype is the active substance of a",
  "   vaccine: 'Pertactin', 'Pertussis toxoid', 'Haemagglutinin from A',",
  "   'Pneumococcal polysaccharide serotype 6B', 'IVR-145', 'A/California/7/2009'.",
  "   A bare geographic word ('California', 'Brisbane', 'Wisconsin', 'Victoria',",
  "   'New Caledonia') is an INFLUENZA STRAIN NAME here, not a place — name it as the",
  "   strain it is. Keep the component as the canonical; do not promote it to the",
  "   whole vaccine and do not merge different components or serotypes together.",
  "",
  "NOT A SUBSTANCE. Some strings name no substance at all: dosage language",
  "('mL concentrate for solution for infusion'), placeholders ('Not yet assigned'),",
  "study-arm labels ('study drug', 'Arm A') and devices. Give these their own cluster",
  "with substance_type 'not_a_substance'. Set canonical to the string itself; it will",
  "be discarded, not displayed. Do NOT force them into a real substance's cluster —",
  "and do NOT use this type for anything biological. A wrong not_a_substance deletes",
  "a real substance from the dataset with nothing downstream to catch it.",
  "",
  "IMPORTANT: some strings have had accented characters DELETED by the source registry,",
  "so 'Infusionslosung' may appear as 'Infusionslsung'. Treat those as the intact",
  "spelling, and give the canonical its correct spelling.",
  "",
  "OUTPUT",
  "",
  "- Every member index must appear in exactly one cluster. Do not omit or repeat one.",
  "- confidence is 0-1: how sure you are the cluster is one substance with that name.",
  "- Use confidence below 0.7 when the strings are too vague to identify.",
  sep = "\n"
)

block_content <- function(members) {
  lines <- sprintf("%d. %s  [%d trial%s]",
                   seq_len(nrow(members)), members$raw_substance,
                   members$n_trials, ifelse(members$n_trials == 1L, "", "s"))
  head_line <- if (nrow(members) == 1L) {
    paste0("Name the substance behind this string.\n",
           "It is the only string in its group, so return exactly one cluster ",
           "containing member 1.\n\n")
  } else {
    paste0("Group these ", nrow(members), " substance strings.\n\n")
  }
  list(list(type = "text", text = paste0(head_line, paste(lines, collapse = "\n"))))
}

# ── Materialise mode ──────────────────────────────────────────────────────────
# Turns the cluster cache into registry entities and assignments. Separate from
# minting so it can be re-run for free, and so a failed batch never leaves the
# registry half-written.

if (materialise) {
  if (!file.exists(CACHE_PATH)) stop("No clusters at ", CACHE_PATH, call. = FALSE)
  clusters <- read_csv(CACHE_PATH, show_col_types = FALSE, progress = FALSE)

  if ("prompt_version" %in% names(clusters) && nrow(clusters)) {
    versions <- sort(unique(stats::na.omit(clusters$prompt_version)))
    if (length(versions) > 1L) {
      newest <- versions[[length(versions)]]
      message(sprintf("cache holds %d prompt versions; using %s", length(versions), newest))
      clusters <- clusters |> filter(prompt_version == newest)
    }
  }

  # not_a_substance clusters must never become registry entities. Minting
  # "Not yet assigned" as a canonical would put it in the app's substance filter,
  # which is precisely what the -1 answer and this type exist to prevent.
  ns <- clusters |> filter(substance_type %in% "not_a_substance")
  if (nrow(ns)) {
    ns_path <- file.path(V2, "C_not_substance.csv")
    prev <- if (file.exists(ns_path)) read_csv(ns_path, show_col_types = FALSE, progress = FALSE) else NULL
    write_csv(bind_rows(prev, ns |> transmute(raw_substance, reason)) |>
                distinct(raw_substance, .keep_all = TRUE), ns_path, na = "", eol = "\n")
    message(sprintf("%d not_a_substance rows held back -> %s", nrow(ns), basename(ns_path)))
  }
  clusters <- clusters |> filter(!substance_type %in% "not_a_substance")

  # entity_type is the shared registry column; substance_type is this pass's name
  # for it. Rename rather than adding a column, so one registry schema serves both
  # pipelines and registry_from_clusters needs no domain knowledge.
  if ("substance_type" %in% names(clusters)) {
    clusters <- clusters |> rename(entity_type = substance_type)
  }

  # Re-join minted canonicals onto existing entities before materialising.
  # Implementation is shared with the idempotence test — see substance_common.R.
  clusters <- rejoin_minted_canonicals(clusters, registry_read(REG_PATH), ALIAS_PATH)

  built <- registry_from_clusters(clusters,
                                  registry_read(REG_PATH),
                                  assignments_read(ASG_PATH, raw_col = "raw_substance"),
                                  raw_col = "raw_substance")
  registry_write(built$registry, REG_PATH)
  assignments_write(built$assignments, ASG_PATH, raw_col = "raw_substance")
  message(sprintf("registry: %d entities (%d live), assignments: %d",
                  nrow(built$registry), nrow(registry_live(built$registry)),
                  nrow(built$assignments)))
  quit(save = "no", status = 0L)
}

# ── Blocking ──────────────────────────────────────────────────────────────────

if (!file.exists(WORK_PATH)) {
  stop("No work list at ", WORK_PATH, "\n",
       "  Run B_assign.R first, or pass --only=<csv with a raw_substance column>.",
       call. = FALSE)
}
todo <- read_csv(WORK_PATH, show_col_types = FALSE, progress = FALSE)
if (!"raw_substance" %in% names(todo)) {
  stop("Work list needs a raw_substance column: ", WORK_PATH, call. = FALSE)
}
if (!"n_trials" %in% names(todo)) todo$n_trials <- 1L
todo <- todo |>
  filter(!is.na(raw_substance), nzchar(trimws(raw_substance))) |>
  distinct(raw_substance, .keep_all = TRUE) |>
  arrange(desc(n_trials), raw_substance)

message(sprintf("work list: %d strings over %d trial pairs", nrow(todo), sum(todo$n_trials)))

message("building index and pair graph...")
idx <- build_index(todo$raw_substance, ids = seq_len(nrow(todo)), ngram_n = NGRAM_N,
                   generic = SUBSTANCE_GENERIC_TOKENS, drop_numeric = TRUE)
# n-gram pairs ON for the same reason the retrieval channel is: a single-token
# drug name gives token overlap nothing to work with, and "BNT162b2" vs
# "BNT-162b2" share no token at all after folding.
#
# ACRONYM OFF. Initials of the words in a drug name mean nothing, and measured
# on this corpus the channel produced 14,328 pairs that were all noise.
#
# ngram_max_postings is raised from the library default of 20: at n = 3 almost
# every gram occurs in more than 20 labels, so the default silently drops the
# whole channel — measured, it contributed 0 pairs of 558,957.
pairs <- build_pair_graph(idx, use_ngram = TRUE, use_acronym = FALSE,
                          ngram_max_postings = as.integer(
                            arg_value("--ngram-max-postings", "400")))
message(sprintf("  %d candidate pairs", nrow(pairs)))

if (nrow(pairs)) {
  cat("\npairs by channel:\n"); print(as.data.frame(pairs |> count(channel, sort = TRUE)))
  cat(sprintf("\npair score distribution (%d pairs):\n", nrow(pairs)))
  print(round(quantile(pairs$score, c(0, .25, .5, .75, .9, .95, .99, 1)), 3))
  cat(sprintf("pairs at or above threshold %.2f: %d\n",
              THRESHOLD, sum(pairs$score >= THRESHOLD)))
}

todo$block_raw <- canopy_blocks(pairs, n_nodes = nrow(todo), weights = todo$n_trials,
                                threshold = THRESHOLD, max_block = MAX_BLOCK)
todo <- todo |>
  group_by(block_raw) |> mutate(block_size = dplyr::n()) |> ungroup() |>
  arrange(desc(block_size > 1L), desc(n_trials)) |>
  mutate(block_id = sprintf("sblk_%05d", as.integer(factor(block_raw, levels = unique(block_raw)))))

sizes <- todo |> count(block_id, name = "size")
cat("\n=== block size distribution ===\n")
print(table(cut(sizes$size, breaks = c(0, 1, 2, 5, 10, 20, Inf),
                labels = c("1", "2", "3-5", "6-10", "11-20", ">20"))))
cat(sprintf("\nblocks: %d  (singletons %d, multi-member %d)\n",
            nrow(sizes), sum(sizes$size == 1L), sum(sizes$size > 1L)))

write_csv(todo |> select(raw_substance, block_id, n_trials, block_size),
          BLOCK_PATH, na = "", eol = "\n")
cat(sprintf("wrote %s (%d rows)\n", basename(BLOCK_PATH), nrow(todo)))

if (blocks_only) {
  cat("\n=== largest blocks (inspect before trusting the graph) ===\n")
  for (bid in (sizes |> arrange(desc(size)) |> head(4))$block_id) {
    m <- todo |> filter(block_id == bid) |> arrange(desc(n_trials))
    cat(sprintf("\n%s  (%d members)\n", bid, nrow(m)))
    for (i in seq_len(min(10L, nrow(m)))) {
      cat(sprintf("   %5d  %s\n", m$n_trials[[i]], substr(m$raw_substance[[i]], 1L, 84L)))
    }
    if (nrow(m) > 10L) cat(sprintf("   ... %d more\n", nrow(m) - 10L))
  }
  cat("\nNo API call was made. Nothing was spent.\n")
  quit(save = "no", status = 0L)
}

# ── Work list ─────────────────────────────────────────────────────────────────

blocks <- todo
blocks <- if (singletons) filter(blocks, block_size == 1L) else filter(blocks, block_size > 1L)
if (!nrow(blocks)) { message("No blocks match this selection."); quit(save = "no", status = 0L) }

impact <- blocks |>
  group_by(block_id) |>
  summarise(trials = sum(n_trials), size = dplyr::n(), .groups = "drop") |>
  arrange(desc(trials))

if (retry_failed) {
  prior <- llm_cache_read(CACHE_PATH)
  if (is.null(prior)) stop("--retry-failed: no cache at ", CACHE_PATH, call. = FALSE)
  bad <- prior |> filter(is.na(canonical)) |> distinct(block_id) |> pull(block_id)
  impact <- impact |> filter(block_id %in% bad)
  message(sprintf("--retry-failed: %d block(s) previously failed to mint", nrow(impact)))
  if (!nrow(impact)) { message("Nothing to retry."); quit(save = "no", status = 0L) }
}

impact$model <- if (!is.na(model_override)) model_override else if (singletons) TAIL_MODEL else {
  ifelse(seq_len(nrow(impact)) <= HEAD_BLOCKS, HEAD_MODEL, TAIL_MODEL)
}

work <- impact |>
  rowwise() |>
  mutate(members_sha = sha256_hex(paste(sort(blocks$raw_substance[blocks$block_id == block_id]),
                                        collapse = "\n"))) |>
  ungroup() |>
  mutate(key = purrr::map2_chr(members_sha, model, ~ llm_cache_key(.x, PROMPT_VERSION, .y)))

cache <- llm_cache_read(CACHE_PATH)
done  <- if (is.null(cache)) character() else unique(cache$cache_key[!is.na(cache$canonical)])
work  <- work |> filter(!key %in% done)
if (!is.na(limit) && limit > 0L) work <- head(work, limit)
message(sprintf("blocks to mint: %d (%d already cached)", nrow(work), length(done)))
if (!nrow(work)) { message("Nothing to mint."); quit(save = "no", status = 0L) }

work <- work |>
  mutate(content = purrr::map(block_id, ~ block_content(
    blocks |> filter(block_id == .x) |> arrange(desc(n_trials))
  )))

# ── Parse ─────────────────────────────────────────────────────────────────────

parse_clusters <- function(outcome, item, batch_id = NA_character_, members = NULL) {
  if (is.null(members)) {
    members <- blocks |> filter(block_id == item$block_id[[1L]]) |> arrange(desc(n_trials))
  }
  fail <- function(msg) tibble(
    cache_key = item$key[[1L]], block_id = item$block_id[[1L]], model_id = item$model[[1L]],
    prompt_version = PROMPT_VERSION, cluster_no = NA_integer_, canonical = NA_character_,
    salt_form = NA_character_, brand = NA_character_, substance_type = NA_character_,
    raw_substance = NA_character_, confidence = NA_real_, reason = msg,
    decided_at_utc = utc_now(), batch_id = batch_id
  )
  if (!outcome$ok) return(fail(outcome$error))

  cl <- outcome$value$clusters
  if (is.null(cl) || (is.data.frame(cl) && !nrow(cl)) || (!is.data.frame(cl) && !length(cl))) {
    return(fail("no clusters returned"))
  }
  if (is.data.frame(cl)) cl <- purrr::transpose(as.list(cl))

  idx_all <- unlist(purrr::map(cl, ~ as.integer(unlist(.x$member_indices))), use.names = FALSE)
  if (anyNA(idx_all)) return(fail("non-integer member index"))
  if (any(idx_all < 1L | idx_all > nrow(members))) {
    return(fail(sprintf("member index out of range 1..%d", nrow(members))))
  }
  if (anyDuplicated(idx_all)) return(fail("a member appears in more than one cluster"))
  if (!setequal(idx_all, seq_len(nrow(members)))) {
    return(fail(sprintf("clusters cover %d of %d members", length(idx_all), nrow(members))))
  }

  purrr::imap_dfr(cl, function(c1, i) {
    ix <- as.integer(unlist(c1$member_indices))
    tibble(
      cache_key = item$key[[1L]], block_id = item$block_id[[1L]],
      model_id = item$model[[1L]], prompt_version = PROMPT_VERSION,
      cluster_no = as.integer(i),
      canonical = c1$canonical %||% NA_character_,
      salt_form = c1$salt_form %||% NA_character_,
      brand = c1$brand %||% NA_character_,
      substance_type = c1$substance_type %||% NA_character_,
      raw_substance = members$raw_substance[ix],
      confidence = as.numeric(c1$confidence %||% NA_real_),
      reason = c1$reason %||% NA_character_,
      decided_at_utc = utc_now(), batch_id = batch_id
    )
  })
}

CACHE_COLS <- c("cache_key", "block_id", "model_id", "prompt_version", "cluster_no",
                "canonical", "salt_form", "brand", "substance_type", "raw_substance",
                "confidence", "reason", "decided_at_utc", "batch_id")

save_rows <- function(rows) {
  merged <- llm_cache_merge(cache, rows, key_col = "cache_key")
  llm_cache_write(merged[, CACHE_COLS], CACHE_PATH, sort_by = c("block_id", "cluster_no"))
  ok <- sum(!is.na(rows$canonical))
  ns <- sum(rows$substance_type %in% "not_a_substance")
  message(sprintf("wrote %d rows to %s (%d named, %d not-a-substance, %d failed)",
                  nrow(rows), basename(CACHE_PATH), ok, ns, sum(is.na(rows$canonical))))

  # A canonical is a CHART LABEL. Nothing rejects a bad one — the schema only
  # says "string" — so an amino-acid sequence or a paragraph of storage prose
  # parses perfectly and lands in the app's substance filter. v2 minted 18 raw
  # peptide sequences this way, the longest 145 characters, and the only reason
  # it was caught is that someone opened the CSV. Surface it on every run.
  named <- rows |> filter(!is.na(canonical)) |>
    distinct(block_id, cluster_no, .keep_all = TRUE)
  # Length ALONE is not the signal, and a flat cap buries the real cases. Of 71
  # canonicals over 60 characters in the v3 head mint, 63 were correct — a
  # biological name is legitimately long ("Neisseria meningitidis group B outer
  # membrane vesicles (NZ98/254, PorA P1.4)"). What actually indicates a bad
  # canonical is a raw sequence, English prose, or a small molecule with a name
  # no small molecule would have.
  # "^H-" alone is too loose: it flags "H-1 Parvovirus (H-1PV)", a real oncolytic
  # virus. A peptide sequence is H- followed by a three-letter amino-acid code.
  bad <- named |> filter(
    grepl("^H-[A-Z][a-z]{2}-|-OH$|-NH2$|(-[A-Z][a-z]{2}){4,}", canonical) |
      grepl("\\b(it is|this is|used (for|to)|reduces|contains|indicated|belongs to)\\b",
            canonical, ignore.case = TRUE) |
      (nchar(canonical) > 90 &
         substance_type %in% c("small_molecule", "unknown", NA_character_))
  )
  if (nrow(bad)) {
    message(sprintf("  WARNING: %d canonical(s) look like a sequence or a description, not a name:",
                    nrow(bad)))
    for (i in seq_len(min(5L, nrow(bad)))) {
      message(sprintf("    [%s] %s", bad$block_id[[i]], substr(bad$canonical[[i]], 1L, 72L)))
    }
    message("  These become labels in the app. Check them before --materialise.")
  }
  message("Run --materialise to fold these into the registry.")
}

# ── Modes ─────────────────────────────────────────────────────────────────────

spec_for <- function(model) {
  llm_spec(model = model, prompt_version = PROMPT_VERSION, system_prompt = SYSTEM_PROMPT,
           schema = MINT_SCHEMA, effort = "low", max_tokens = MAX_TOKENS)
}
primary_model <- if (nrow(work)) work$model[[1L]] else TAIL_MODEL
spec <- spec_for(primary_model)

if (dry_run) {
  est <- llm_dry_run(spec, work, label = paste("C_mint /", primary_model), spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_batch, SPEND_PATH, "C_mint")
  quit(save = "no", status = 0L)
}

auth <- llm_auth()

if (do_sync) {
  est <- llm_dry_run(spec, work, label = paste("C_mint /", primary_model), spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_sync %||% est$est_cost_batch, SPEND_PATH, "C_mint")
  rows <- llm_sync(spec, work, parse = function(o, it) parse_clusters(o, it), auth = auth)
  save_rows(rows)
  llm_spend_record_sync(SPEND_PATH, "C_mint", primary_model, rows)
  message(sprintf("recorded sync spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  cat("\nSCALE GATE: no 'grammar compilation rate limit' above, and check that\n")
  cat("failed rows are rare. An out-of-range member_index is a model-capability\n")
  cat("failure, not a prompt failure — retry those on Opus, not on the same model.\n")
  quit(save = "no", status = 0L)
}

if (!is.na(poll_batch)) {
  llm_batch_wait(poll_batch, auth)
  rows <- llm_batch_results(poll_batch, work, parse = parse_clusters, auth = auth)
  save_rows(rows)
  u <- llm_batch_usage(poll_batch, auth)
  if (!is.null(u)) {
    llm_spend_record(SPEND_PATH, "C_mint", poll_batch, primary_model, u$input, u$output,
                     u$cache_read, n_requests = u$n %||% nrow(work))
    message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  }
  quit(save = "no", status = 0L)
}

# A mixed head/tail selection is submitted per model: one batch cannot carry two
# models, and the system prompt is the cache breakpoint, so splitting them also
# keeps each model's prompt cache intact.
for (m in unique(work$model)) {
  w <- work |> filter(model == m)
  message(sprintf("\n=== %d block(s) on %s ===", nrow(w), m))
  sp <- spec_for(m)
  est <- llm_dry_run(sp, w, label = paste("C_mint /", m), spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_batch, SPEND_PATH, "C_mint")
  bid  <- llm_batch_submit(sp, w, auth)
  llm_batch_wait(bid, auth)
  rows <- llm_batch_results(bid, w, parse = parse_clusters, auth = auth)
  save_rows(rows)
  u <- llm_batch_usage(bid, auth)
  if (!is.null(u)) {
    llm_spend_record(SPEND_PATH, "C_mint", bid, m, u$input, u$output, u$cache_read,
                     n_requests = u$n %||% nrow(w))
    message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
  }
}
message("\nMinted. Run --materialise to fold the clusters into the registry.")
