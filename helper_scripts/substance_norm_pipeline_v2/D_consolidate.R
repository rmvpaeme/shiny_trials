#!/usr/bin/env Rscript
# Pass D — collapse registry entries that are the same substance.
#
# Two mechanisms, deliberately separate.
#
# 1. SALT ROLLUP (--rollup), deterministic, free, no model.
#    ChEMBL pref_names are frequently salt-specific, so pass A resolves
#    "ATORVASTATIN CALCIUM" to a canonical of that name. The INN-base decision
#    says the canonical is "Atorvastatin". Measured on the live registry: 605
#    canonicals covering 6,039 trial pairs are of the form "<base> <salt>" where
#    <base> is ITSELF a registry canonical — fluticasone propionate,
#    doxorubicin hydrochloride, metformin hydrochloride, vincristine sulfate.
#    That is a string operation validated against the registry, not a judgement,
#    so asking a model would be slower, dearer and less reproducible.
#
# 2. MODEL PARTITION (--batch), for everything else: spelling variants, language
#    variants, brand-vs-INN duplicates minted by C_mint.
#
# THE SCHEMA IS A PARTITION, NOT A BOOLEAN. A group is a lexical neighbourhood,
# not a duplicate set — asking "are these the same?" of a group holding
# vinblastine, vincristine and two spellings of vincristine has no honest
# answer. `merge_into` gives one index per member naming the entry whose name
# survives, or itself to stand alone. An array of integers is ONE grammar
# however long it gets, so this does not reintroduce the per-row-enum problem.
#
# NO --translate CHANNEL. Sponsors needed one because an institution named in
# two languages shares no token with itself. INNs are an international standard;
# there is no Dutch word for pembrolizumab. The sorted-word-bag KEY from that
# channel is kept, because on the sponsor side most of its yield came from the
# key rather than the translation (punctuation, spacing, diacritics, & vs and)
# and the key costs nothing.
#
# Usage
#   Rscript .../D_consolidate.R --rollup                # propose salt rollups
#   Rscript .../D_consolidate.R --rollup --apply        # execute them
#   Rscript .../D_consolidate.R --groups-only           # inspect groups, no API
#   Rscript .../D_consolidate.R --sync --limit=5
#   Rscript .../D_consolidate.R --batch
#   Rscript .../D_consolidate.R --apply                 # execute model merges

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(purrr); library(jsonlite); library(stringr)
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
do_rollup   <- "--rollup"      %in% args
groups_only <- "--groups-only" %in% args
dry_run     <- "--dry-run"     %in% args
do_sync     <- "--sync"        %in% args
do_batch    <- "--batch"       %in% args
do_apply    <- "--apply"       %in% args
limit       <- suppressWarnings(as.integer(arg_value("--limit")))
poll_batch  <- arg_value("--poll")
THRESHOLD   <- as.numeric(arg_value("--threshold", "0.60"))
MAX_GROUP   <- as.integer(arg_value("--max-group", "12"))
APPLY_CONF  <- as.numeric(arg_value("--min-confidence", "0.80"))

if (!do_rollup && !groups_only && !dry_run && !do_sync && !do_batch && !do_apply &&
    is.na(poll_batch)) {
  stop("Pick a mode: --rollup, --groups-only, --dry-run, --sync, --batch, --apply",
       call. = FALSE)
}

MODEL_ID       <- arg_value("--model", "claude-opus-5")
PROMPT_VERSION <- "substance-consolidate-v1"
MAX_TOKENS     <- 4096L
NGRAM_N        <- 3L

V2 <- Sys.getenv("SUBSTANCE_V2_DIR", unset = pp("config", "substance_norm_v2"))
REG_PATH    <- file.path(V2, "registry.csv")
ASG_PATH    <- file.path(V2, "assignments.csv")
MERGE_PATH  <- file.path(V2, "D_consolidate_merges.csv")
ROLLUP_PATH <- file.path(V2, "D_salt_rollups.csv")
SPEND_PATH  <- file.path(V2, "llm_spend.csv")
CHEMBL_PATH <- file.path(V2, "chembl_cache.csv")
EPAR_PATH   <- file.path(V2, "epar_cache.csv")

reg  <- registry_read(REG_PATH)
asg  <- assignments_read(ASG_PATH, raw_col = "raw_substance")
live <- registry_live(reg)
if (!nrow(live)) stop("Registry is empty — run A_resolve.R first.", call. = FALSE)

impact <- asg |>
  mutate(entity_id = resolve_entity(reg, entity_id)) |>
  count(entity_id, name = "n_assigned")
live <- live |> left_join(impact, by = "entity_id") |>
  mutate(n_assigned = coalesce(n_assigned, 0L))

message(sprintf("registry: %d live entities, %d assignments", nrow(live), nrow(asg)))

# ── Salt rollup ───────────────────────────────────────────────────────────────

SALT_SUFFIX <- c(
  "sodium", "potassium", "calcium", "magnesium", "hydrochloride", "hcl",
  "sulfate", "sulphate", "phosphate", "acetate", "maleate", "tartrate",
  "bitartrate", "succinate", "fumarate", "citrate", "mesylate", "mesilate",
  "besylate", "besilate", "tosylate", "malate", "lactate", "gluconate",
  "bromide", "chloride", "nitrate", "oxalate", "stearate", "palmitate",
  "valerate", "propionate", "dipropionate", "furoate", "xinafoate",
  "dihydrate", "trihydrate", "monohydrate", "hydrate", "anhydrous",
  "hemihydrate", "hydrobromide", "dipotassium", "disodium", "carbonate",
  "pamoate", "embonate", "decanoate", "enantate", "enanthate", "undecanoate"
)

# A base that is an element or simple ion is NOT a drug that its salt rolls up
# to. Without this, "sodium chloride" rolls into "sodium" and "calcium
# carbonate" into "calcium" — both of which are real ChEMBL pref_names, so the
# registry check alone does not catch it. This is the whole collision class.
ELEMENTAL_BASE <- c(
  "sodium", "potassium", "calcium", "magnesium", "zinc", "iron", "lithium",
  "ammonium", "aluminium", "aluminum", "copper", "manganese", "selenium",
  "chromium", "iodine", "fluoride", "phosphorus", "silver", "gold", "barium",
  "strontium", "water", "oxygen", "nitrogen", "carbon", "hydrogen"
)

salt_pattern <- paste0("^(.*?)[ -]+(", paste(SALT_SUFFIX, collapse = "|"), ")$")

rollup_proposals <- function(live) {
  canon_lc <- tolower(live$canonical)
  by_name  <- setNames(live$entity_id, canon_lc)
  m <- str_match(canon_lc, salt_pattern)
  tibble(
    loser_id   = live$entity_id,
    loser_name = live$canonical,
    base       = str_squish(m[, 2]),
    salt       = m[, 3],
    n_assigned = live$n_assigned
  ) |>
    filter(!is.na(base), nzchar(base), !base %in% ELEMENTAL_BASE) |>
    mutate(winner_id = unname(by_name[base])) |>
    filter(!is.na(winner_id), winner_id != loser_id) |>
    left_join(live |> select(entity_id, winner_name = canonical),
              by = c("winner_id" = "entity_id")) |>
    transmute(loser_id, winner_id, loser_name, winner_name, salt_form = salt,
              n_assigned,
              reason = paste0("salt/ester rollup: '", loser_name, "' -> '",
                              winner_name, "' (", salt, ")"))
}

if (do_rollup) {
  prop <- rollup_proposals(live)
  write_csv(prop, ROLLUP_PATH, na = "", eol = "\n")
  cat(sprintf("\n%d salt rollups proposed, covering %d assignments -> %s\n",
              nrow(prop), sum(prop$n_assigned), basename(ROLLUP_PATH)))
  cat("\ntop 20 by assignment count:\n")
  print(as.data.frame(prop |> arrange(desc(n_assigned)) |>
                        select(loser_name, winner_name, salt_form, n_assigned) |> head(20)))
  cat("\nsalt forms:\n"); print(prop |> count(salt_form, sort = TRUE) |> head(12))

  if (!do_apply) {
    cat("\nNothing applied. Read the list above, then re-run with --apply.\n")
    quit(save = "no", status = 0L)
  }

  out <- registry_apply_merges(reg, asg, prop |> select(loser_id, winner_id, reason),
                               model_id = "rule", prompt_version = PROMPT_VERSION)
  # The salt is not lost: it moves onto the winner's row only when every entry
  # rolling into it carries the same one, otherwise it would claim "Metoprolol
  # is the succinate" on the strength of one member.
  salt_of <- prop |> group_by(winner_id) |>
    summarise(s = if (n_distinct(salt_form) == 1L) first(salt_form) else NA_character_,
              .groups = "drop")
  out$registry <- out$registry |>
    left_join(salt_of, by = c("entity_id" = "winner_id")) |>
    mutate(salt_form = coalesce(salt_form, s)) |> select(-s)

  registry_write(out$registry, REG_PATH)
  assignments_write(out$assignments, ASG_PATH, raw_col = "raw_substance")
  cat(sprintf("\napplied %d rollups, refused %d; %d live entities remain\n",
              out$applied, out$refused, nrow(registry_live(out$registry))))
  quit(save = "no", status = 0L)
}

# ── Reference facts for the merge guard ───────────────────────────────────────
# Whether a canonical is a ChEMBL/EPAR pref_name is an EXTERNAL fact, not a model
# opinion, and it is the strongest guard available here. Two entries that are
# both registry pref_names are different substances — UNLESS one is a salt form
# of the other or they fold to the same word bag. Without that exception the
# guard would block exactly the merges pass D exists to make.

ref_canon <- if (file.exists(CHEMBL_PATH)) {
  r <- read_csv(CHEMBL_PATH, show_col_types = FALSE, progress = FALSE)
  e <- if (file.exists(EPAR_PATH)) read_csv(EPAR_PATH, show_col_types = FALSE, progress = FALSE) else NULL
  unique(tolower(c(r$substance_clean, e$substance_clean)))
} else {
  message("NOTE: no chembl_cache.csv — the pref_name merge guard is inert.")
  character()
}

KEY_STOP <- c("of", "the", "and", "de", "der", "die", "das", "du", "la", "le",
              "les", "el", "et", "en", "van", "di", "da", "do", "for", "with")
fold_key <- function(x) {
  w <- strsplit(fold_translit(tolower(x)), " ", fixed = TRUE)[[1L]]
  w <- sort(unique(w[nzchar(w) & !w %in% KEY_STOP]))
  paste(w, collapse = " ")
}

is_salt_of <- function(a, b) {
  m <- str_match(tolower(a), salt_pattern)
  !is.na(m[, 2]) && str_squish(m[, 2]) == tolower(b)
}

# Pick which name survives a merge family. THE INN BASE WINS.
#
# The obvious rule — most trial strings wins — is wrong here and was the bug.
# "Rucaparib camsylate" outnumbers "Rucaparib" in this corpus, so impact alone
# elected the salt and produced 62 backwards merges of 678: Bavisant ->
# Bavisant dihydrochloride, Delafloxacin -> Delafloxacin meglumine. That
# contradicts the whole INN-base decision, and it is invisible in the merge
# count because the merge itself is correct — only its direction is not.
#
# So: if one member's name is a word-prefix of another's, it is the base and it
# wins, shortest first. This deliberately also collapses prodrug esters that
# carry their own INN (olmesartan medoxomil -> Olmesartan), which is what the
# INN-base decision asks for even though both names are legitimate.
# Impact only breaks ties between unrelated spellings.
pick_winner <- function(canons, impact) {
  n <- length(canons)
  if (n == 1L) return(1L)
  lc <- tolower(str_squish(canons))
  # A member is a BASE when another member is it plus an extra word, on EITHER
  # side. Salt order is not consistent in this corpus: "rucaparib camsylate"
  # puts it last, "calcium clofibrate" puts it first. Testing only the prefix
  # form left the clofibrate family electing "Calcium clofibrate" over the bare
  # "Clofibrate" on impact alone.
  is_base <- vapply(seq_len(n), function(i) {
    any(startsWith(lc[-i], paste0(lc[[i]], " "))) ||
      any(endsWith(lc[-i], paste0(" ", lc[[i]])))
  }, logical(1))
  if (any(is_base)) {
    cand <- which(is_base)
    return(cand[order(nchar(lc[cand]))][[1L]])   # shortest base
  }
  # No base/suffix relationship: nothing here says which spelling is more
  # canonical, so keep the previous behaviour and let impact decide. Electing
  # the shortest name in this case was an overreach — it silently rewrote
  # "Imidazole-4-carboxylic acid" to "4-imidazolecarboxylic acid" purely on
  # length, which is not a judgement this function is entitled to make.
  which.max(impact)
}

# TRUE when a merge should be held back.
blocked_merge <- function(a_name, b_name, a_type, b_type) {
  a <- tolower(a_name); b <- tolower(b_name)
  if (identical(fold_key(a_name), fold_key(b_name))) return(FALSE)
  if (is_salt_of(a, b) || is_salt_of(b, a)) return(FALSE)
  # Both are registry pref_names and neither is the other's salt: different drugs.
  if (a %in% ref_canon && b %in% ref_canon) return(TRUE)
  # Sponsor-style backstop for everything the registry does not cover: type
  # mismatch AND name dissimilarity. Each signal alone was measured worse than
  # useless on the sponsor side; only the conjunction earned its place.
  sim <- {
    ga <- char_ngrams(fold_translit(a), 3L); gb <- char_ngrams(fold_translit(b), 3L)
    if (!length(ga) || !length(gb)) 0 else
      length(intersect(ga, gb)) / length(union(ga, gb))
  }
  !is.na(a_type) && !is.na(b_type) && a_type != b_type && sim < 0.30
}

# ── Grouping ──────────────────────────────────────────────────────────────────

message("building groups...")

# SALT WORDS ARE GENERIC IN THIS POPULATION, and that is not true of the corpus.
#
# SUBSTANCE_GENERIC_TOKENS deliberately keeps chemical words, because "sodium"
# and "chloride" are parts of INNs and stoplisting them would delete the only
# discriminating token some raw strings have. But pass D indexes CANONICALS, a
# different population: 501 of them end in "hydrochloride", 230 in "sodium".
# There, the salt word carries no information about WHICH drug it is.
#
# Measured before this: one group held "Insulin human", "Irinotecan
# hydrochloride", "Iptacopan hydrochloride", "Irbesartan hydrochloride" and
# "Inupadenant hydrochloride" — five unrelated drugs joined on that one token.
# Same failure §3.4 fixed for sponsors by stoplisting "pharmaceuticals".
D_GENERIC <- unique(c(SUBSTANCE_GENERIC_TOKENS, SALT_SUFFIX))

idx <- build_index(live$canonical, ids = seq_len(nrow(live)), ngram_n = NGRAM_N,
                   generic = D_GENERIC, drop_numeric = TRUE)
# Acronym off: initials of a drug name mean nothing. n-gram on, with a postings
# cap high enough for the channel to actually fire (the library default of 20
# makes it inert at n = 3).
pairs <- build_pair_graph(idx, use_ngram = TRUE, use_acronym = FALSE,
                          ngram_max_postings = 400L)
pairs <- pairs |> filter(score >= THRESHOLD)

# Free channel: identical accent-folded sorted word bags. Catches punctuation,
# spacing, diacritic and word-order variants that the token graph cannot see
# ("Linkoping"/"Linköping", "PARI Pharma"/"PARIPharma").
keys <- vapply(live$canonical, fold_key, character(1), USE.NAMES = FALSE)
key_pairs <- tibble(key = keys, id = seq_along(keys)) |>
  filter(nzchar(key)) |> group_by(key) |> filter(dplyr::n() > 1L, dplyr::n() <= 20L) |>
  group_modify(~ {
    v <- sort(.x$id)
    cb <- utils::combn(v, 2L)
    tibble(a = cb[1L, ], b = cb[2L, ])
  }) |> ungroup() |> transmute(a, b, score = 1, channel = "fold_key")
if (nrow(key_pairs)) {
  message(sprintf("  +%d pair(s) from identical folded word bags", nrow(key_pairs)))
  pairs <- bind_rows(pairs, key_pairs) |> distinct(a, b, .keep_all = TRUE)
}

comp <- components_of(pairs |> select(a, b), n_nodes = nrow(live))
live$group_raw <- comp
grp <- live |> group_by(group_raw) |> mutate(gsize = dplyr::n()) |> ungroup()

# Oversized components are RE-SPLIT by canopy, never skipped. On the sponsor side
# a MAX_GROUP skip stranded 723 entities — 46% of everything with a duplicate
# neighbour — behind an "inspect by hand" message nobody was going to action.
big <- grp |> filter(gsize > MAX_GROUP) |> distinct(group_raw) |> pull(group_raw)
if (length(big)) {
  message(sprintf("  re-splitting %d oversized component(s) by canopy", length(big)))
  next_id <- max(grp$group_raw) + 1L
  for (g in big) {
    ix <- which(grp$group_raw == g)
    sub_pairs <- pairs |> filter(a %in% ix, b %in% ix) |>
      mutate(a = match(a, ix), b = match(b, ix))
    sub <- canopy_blocks(sub_pairs, n_nodes = length(ix),
                         weights = grp$n_assigned[ix], threshold = THRESHOLD,
                         max_block = MAX_GROUP)
    grp$group_raw[ix] <- next_id + sub - 1L
    next_id <- next_id + max(sub)
  }
  grp <- grp |> group_by(group_raw) |> mutate(gsize = dplyr::n()) |> ungroup()
}

groups <- grp |> filter(gsize > 1L) |>
  group_by(group_raw) |>
  summarise(ids = list(entity_id), n = dplyr::n(),
            trials = sum(n_assigned), .groups = "drop") |>
  arrange(desc(trials))

message(sprintf("  %d group(s) with more than one member, covering %d entities",
                nrow(groups), sum(groups$n)))

if (groups_only) {
  cat("\n=== largest groups by assignment count (READ THESE) ===\n")
  for (i in seq_len(min(12L, nrow(groups)))) {
    ids <- groups$ids[[i]]
    m <- live |> filter(entity_id %in% ids) |> arrange(desc(n_assigned))
    cat(sprintf("\ngroup %d  (%d members, %d assignments)\n", i, nrow(m), groups$trials[[i]]))
    for (j in seq_len(nrow(m))) {
      cat(sprintf("   %5d  %-46s %s\n", m$n_assigned[[j]],
                  substr(m$canonical[[j]], 1L, 46L), coalesce(m$entity_type[[j]], "")))
    }
  }
  cat("\nA group is a lexical NEIGHBOURHOOD, not a duplicate set. Expect it to\n")
  cat("hold genuinely different drugs — that is what the partition is for.\n")
  cat("\nNo API call was made. Nothing was spent.\n")
  quit(save = "no", status = 0L)
}

# ── Apply mode ────────────────────────────────────────────────────────────────

if (do_apply && !do_batch && !do_sync && is.na(poll_batch)) {
  if (!file.exists(MERGE_PATH)) stop("No merges at ", MERGE_PATH, call. = FALSE)
  m <- read_csv(MERGE_PATH, show_col_types = FALSE, progress = FALSE)
  name_of <- setNames(reg$canonical, reg$entity_id)
  type_of <- setNames(reg$entity_type, reg$entity_id)
  m <- m |> filter(!is.na(winner_id), !is.na(loser_id), loser_id != winner_id,
                   coalesce(confidence, 0) >= APPLY_CONF)

  # Re-elect the survivor of every family before applying. The merge SET is the
  # model's answer and is kept; only the direction is recomputed, because
  # parse_merge() historically chose by impact and that elects salts over their
  # INN base (see pick_winner). Doing it here rather than only in parse_merge
  # means an already-paid batch does not need re-polling to be corrected.
  if (nrow(m)) {
    ids <- unique(c(m$loser_id, m$winner_id))
    idx <- setNames(seq_along(ids), ids)
    fam <- components_of(tibble(a = unname(idx[m$loser_id]), b = unname(idx[m$winner_id])),
                         n_nodes = length(ids))
    cn <- setNames(reg$canonical, reg$entity_id)[ids]
    im <- setNames(live$n_assigned, live$entity_id)[ids]
    im[is.na(im)] <- 0L
    # Only families that actually contain a base are re-elected. Recomputing
    # every family churns the ones where no member is a base — there the choice
    # falls back to impact, ties at zero are broken by position, and the result
    # is a different arbitrary winner, not a better one ("Gossypol" losing to an
    # IUPAC name). Leave the model's answer alone unless there is a base to
    # prefer.
    new_winner <- setNames(rep(NA_character_, length(ids)), ids)
    for (f in unique(fam)) {
      k <- which(fam == f)
      lc <- tolower(str_squish(cn[k]))
      is_base <- vapply(seq_along(k), function(i) {
        any(startsWith(lc[-i], paste0(lc[[i]], " "))) ||
          any(endsWith(lc[-i], paste0(" ", lc[[i]])))
      }, logical(1))
      if (!any(is_base)) next
      cand <- which(is_base)
      new_winner[k] <- ids[[k[[cand[order(nchar(lc[cand]))][[1L]]]]]]
    }
    keep <- is.na(new_winner[m$loser_id])
    new_winner_for <- ifelse(keep, m$winner_id, unname(new_winner[m$loser_id]))
    flipped <- sum(m$winner_id != new_winner_for, na.rm = TRUE)
    m <- m |>
      mutate(winner_id = new_winner_for) |>
      filter(!is.na(winner_id), loser_id != winner_id)
    if (flipped) {
      cat(sprintf("\nre-elected the survivor in %d merge(s) so the INN base wins:\n", flipped))
      ex <- m |> mutate(l = unname(cn[loser_id]), w = unname(cn[winner_id])) |>
        filter(nchar(l) > nchar(w)) |> head(6)
      for (i in seq_len(nrow(ex))) cat(sprintf("    %-40s -> %s\n", ex$l[[i]], ex$w[[i]]))
    }
  }
  m$blocked <- purrr::pmap_lgl(list(m$loser_id, m$winner_id), function(l, w) {
    blocked_merge(name_of[[l]], name_of[[w]], type_of[[l]], type_of[[w]])
  })
  if (any(m$blocked)) {
    cat(sprintf("\nHELD BACK %d merge(s) by the guard:\n", sum(m$blocked)))
    for (i in which(m$blocked)) {
      cat(sprintf("   %-34s <- %-34s (conf %.2f)\n",
                  name_of[[m$winner_id[[i]]]], name_of[[m$loser_id[[i]]]],
                  m$confidence[[i]]))
    }
    cat("Both are reference pref_names and neither is the other's salt form,\n")
    cat("or their types and names both disagree. Edit the file to override.\n")
  }
  m <- m |> filter(!blocked)
  out <- registry_apply_merges(reg, asg, m |> select(loser_id, winner_id, reason),
                               model_id = MODEL_ID, prompt_version = PROMPT_VERSION)
  registry_write(out$registry, REG_PATH)
  assignments_write(out$assignments, ASG_PATH, raw_col = "raw_substance")
  cat(sprintf("\napplied %d merge(s), refused %d; %d live entities remain\n",
              out$applied, out$refused, nrow(registry_live(out$registry))))
  quit(save = "no", status = 0L)
}

if (!nrow(groups)) { message("No groups to consolidate."); quit(save = "no", status = 0L) }

# ── Schema and prompt ─────────────────────────────────────────────────────────

MERGE_SCHEMA <- list(
  type = "object",
  additionalProperties = FALSE,
  required = list("merge_into", "confidence"),
  properties = list(
    merge_into = list(type = "array", items = list(type = "integer")),
    confidence = list(type = "array", items = list(type = "number")),
    reason     = list(type = "string")
  )
)

SYSTEM_PROMPT <- paste(
  "You decide which entries in a numbered list of substance names are the SAME substance.",
  "",
  "The list was assembled by text similarity, so it is a neighbourhood, not a duplicate",
  "set. It will usually contain several different substances. Do not assume the list is",
  "one substance, and do not assume it is all distinct.",
  "",
  "Return 'merge_into': one integer per entry, in order. For entry i give the number of",
  "the entry whose NAME SHOULD SURVIVE, or i itself if it stands alone.",
  "",
  "  1. Vincristine          -> 1   (stands alone)",
  "  2. Vincristine sulfate  -> 1   (same substance as 1)",
  "  3. Vinblastine          -> 3   (DIFFERENT drug, stands alone)",
  "  4. Vinblastine sulphate -> 3",
  "  giving merge_into [1,1,3,3]",
  "",
  "MERGE these:",
  "  - salts, esters and hydrates of one INN, into the bare INN",
  "  - spelling and transliteration variants ('sulfate'/'sulphate', 'Linkoping'/'Linköping')",
  "  - a brand name and its active substance, into the INN",
  "  - the same name with different punctuation, spacing or capitalisation",
  "",
  "KEEP SEPARATE — this is the direction that matters here:",
  "  - different INNs that look alike: vinblastine/vincristine, cisplatin/carboplatin/",
  "    oxaliplatin, daunorubicin/doxorubicin, methotrexate/ketotrexate,",
  "    peginterferon alfa-2a/alfa-2b, insulin glargine/insulin degludec",
  "  - different code names: BNT162b1 and BNT162b2, AZD1222 and AZD7442",
  "  - a single agent and a combination containing it",
  "  - different vaccine antigens or serotypes",
  "  - enantiomers and racemates: levocetirizine is not cetirizine, esomeprazole is",
  "    not omeprazole",
  "",
  "When the INN itself is in the list, it should be the survivor, not the salt or brand.",
  "",
  "'confidence' is an array the SAME LENGTH as merge_into: how sure you are of each",
  "entry's answer, 0-1. Use a low value rather than leaving an entry out.",
  "",
  "If you are unsure whether two entries are one substance, point each at ITSELF.",
  "A wrong merge silently relabels every trial for both; leaving them apart is",
  "visible and fixable.",
  sep = "\n"
)

group_content <- function(ids) {
  m <- live |> filter(entity_id %in% ids) |> arrange(desc(n_assigned))
  lines <- sprintf("%d. %s%s%s", seq_len(nrow(m)), m$canonical,
                   ifelse(is.na(m$entity_type) | !nzchar(m$entity_type), "",
                          sprintf("  [%s]", m$entity_type)),
                   sprintf("  (%d trial strings)", m$n_assigned))
  list(list(type = "text", text = paste0(
    "Which of these are the same substance?\n\n", paste(lines, collapse = "\n"),
    "\n\nReturn merge_into with ", nrow(m), " integers."
  )))
}

work <- groups |>
  mutate(group_key = purrr::map_chr(ids, ~ paste(sort(.x), collapse = "|")),
         key = purrr::map_chr(group_key, ~ llm_cache_key(.x, PROMPT_VERSION, MODEL_ID)))

cache <- llm_cache_read(MERGE_PATH)
done  <- if (is.null(cache)) character() else unique(cache$cache_key[!is.na(cache$winner_id)])
work  <- work |> filter(!key %in% done)
if (!is.na(limit) && limit > 0L) work <- head(work, limit)
message(sprintf("groups to ask: %d (%d already cached)", nrow(work), length(done)))
if (!nrow(work)) { message("Nothing to ask."); quit(save = "no", status = 0L) }

work <- work |> mutate(content = purrr::map(ids, group_content))

# ── Parse ─────────────────────────────────────────────────────────────────────

parse_merge <- function(outcome, item, batch_id = NA_character_) {
  ids <- item$ids[[1L]]
  m <- live |> filter(entity_id %in% ids) |> arrange(desc(n_assigned))
  fail <- function(msg) tibble(
    cache_key = item$key[[1L]], group_key = item$group_key[[1L]],
    loser_id = NA_character_, winner_id = NA_character_, confidence = NA_real_,
    model_id = MODEL_ID, prompt_version = PROMPT_VERSION, reason = msg,
    decided_at_utc = utc_now(), batch_id = batch_id
  )
  if (!outcome$ok) return(fail(outcome$error))

  mi <- suppressWarnings(as.integer(unlist(outcome$value$merge_into)))
  if (length(mi) != nrow(m)) {
    return(fail(sprintf("merge_into has %d entries, group has %d", length(mi), nrow(m))))
  }
  if (anyNA(mi) || any(mi < 1L | mi > nrow(m))) {
    return(fail(sprintf("merge_into index out of range 1..%d", nrow(m))))
  }
  cf <- suppressWarnings(as.numeric(unlist(outcome$value$confidence)))
  if (length(cf) == 1L) cf <- rep(cf, nrow(m))
  if (length(cf) != nrow(m)) cf <- rep(NA_real_, nrow(m))
  rs <- outcome$value$reason %||% NA_character_

  # Resolve chains (3->2->1) and cycles (1<->2) into families, then let the
  # member with the most assignments carry the surviving name.
  fam <- components_of(tibble(a = seq_len(nrow(m)), b = mi) |> filter(a != b),
                       n_nodes = nrow(m))
  out <- purrr::map_dfr(unique(fam), function(f) {
    ix <- which(fam == f)
    if (length(ix) < 2L) return(tibble())
    # The INN base survives, not the highest-impact member — see pick_winner().
    win <- ix[[pick_winner(m$canonical[ix], m$n_assigned[ix])]]
    tibble(
      cache_key = item$key[[1L]], group_key = item$group_key[[1L]],
      loser_id = m$entity_id[setdiff(ix, win)], winner_id = m$entity_id[[win]],
      confidence = cf[setdiff(ix, win)],
      model_id = MODEL_ID, prompt_version = PROMPT_VERSION, reason = rs,
      decided_at_utc = utc_now(), batch_id = batch_id
    )
  })
  if (!nrow(out)) return(fail("no merges proposed (every entry stands alone)"))
  out
}

MERGE_COLS <- c("cache_key", "group_key", "loser_id", "winner_id", "confidence",
                "model_id", "prompt_version", "reason", "decided_at_utc", "batch_id")

save_rows <- function(rows) {
  merged <- llm_cache_merge(cache, rows, key_col = "cache_key")
  llm_cache_write(merged[, MERGE_COLS], MERGE_PATH, sort_by = "group_key")
  message(sprintf("wrote %d row(s) to %s (%d proposed merges)",
                  nrow(rows), basename(MERGE_PATH), sum(!is.na(rows$winner_id))))
  message("Nothing applied. Read the file, then run --apply.")
}

# ── Modes ─────────────────────────────────────────────────────────────────────

spec <- llm_spec(model = MODEL_ID, prompt_version = PROMPT_VERSION,
                 system_prompt = SYSTEM_PROMPT, schema = MERGE_SCHEMA,
                 effort = "low", max_tokens = MAX_TOKENS)

if (dry_run) {
  est <- llm_dry_run(spec, work, label = paste("D_consolidate /", MODEL_ID), spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_batch, SPEND_PATH, "D_consolidate")
  quit(save = "no", status = 0L)
}

auth <- llm_auth()

if (do_sync) {
  est <- llm_dry_run(spec, work, label = paste("D_consolidate /", MODEL_ID), spend_path = SPEND_PATH)
  llm_budget_guard(est$est_cost_sync %||% est$est_cost_batch, SPEND_PATH, "D_consolidate")
  rows <- llm_sync(spec, work, parse = function(o, it) parse_merge(o, it), auth = auth)
  save_rows(rows)
  llm_spend_record_sync(SPEND_PATH, "D_consolidate", MODEL_ID, rows)
  cat("\nSCALE GATE: the answers must PARTITION. A group returning one family\n")
  cat("for everything is the boolean failure in disguise — check that a group\n")
  cat("holding two different drugs came back with two families.\n")
  quit(save = "no", status = 0L)
}

if (!is.na(poll_batch)) {
  llm_batch_wait(poll_batch, auth)
  rows <- llm_batch_results(poll_batch, work, parse = parse_merge, auth = auth)
  save_rows(rows)
  u <- llm_batch_usage(poll_batch, auth)
  if (!is.null(u)) {
    llm_spend_record(SPEND_PATH, "D_consolidate", poll_batch, MODEL_ID, u$input, u$output,
                     u$cache_read, n_requests = u$n %||% nrow(work))
  }
  quit(save = "no", status = 0L)
}

est <- llm_dry_run(spec, work, label = paste("D_consolidate /", MODEL_ID), spend_path = SPEND_PATH)
llm_budget_guard(est$est_cost_batch, SPEND_PATH, "D_consolidate")
bid  <- llm_batch_submit(spec, work, auth)
llm_batch_wait(bid, auth)
rows <- llm_batch_results(bid, work, parse = parse_merge, auth = auth)
save_rows(rows)
u <- llm_batch_usage(bid, auth)
if (!is.null(u)) {
  llm_spend_record(SPEND_PATH, "D_consolidate", bid, MODEL_ID, u$input, u$output,
                   u$cache_read, n_requests = u$n %||% nrow(work))
  message(sprintf("recorded spend; total now $%.2f", llm_spend_total(SPEND_PATH)))
}
message("Proposed. Run --apply to execute.")
