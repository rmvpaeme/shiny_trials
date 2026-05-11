# Build config/sponsor_norm_pipeline/sponsor_alias_index.csv
# from manual aliases, EMA EPAR MAH names, and optionally ROR + DB-sourced tiers.
#
# Sources (priority order):
#   1. manual_sponsor_aliases.csv  (seed, confidence 1.00) — always included
#   2. EMA EPAR Marketing Authorisation Holders (confidence 0.85) — MAH name variants
#      for sponsors already in the manual alias table
#   3. ROR academic/hospital name variants (confidence 0.75, --no-ror to skip)
#   4. CTIS businessKey EMA org IDs (confidence 0.95, --no-businesskey to skip)
#      Ground-truth aliases: EMA's own organisation registry links name variants.
#   5. EUCTR email domain (confidence 0.85, --no-email to skip)
#      Sponsors sharing a corporate email domain → same canonical.
#      CRO / generic / NHS-shared domains are blocked.
#   6. Postcode + country + JW name similarity (confidence 0.70, --no-location to skip)
#      Same registered postcode + similar name → institution alias candidate.
#      Only proposed when one name already resolves to a known canonical.
#
# Strategy: for EPAR/ROR, we look up each external name against the manual alias
# table using the same candidate generation logic. If a match is found, the
# external name becomes an additional alias for that canonical sponsor.
# Unmatched external names are written to new_sponsor_candidates.csv for review.
#
# For DB-sourced tiers (4-6), aliases are only added when the resolved names for
# a given businessKey / domain / location group all agree on the same canonical.
# Ambiguous groups are silently skipped.
#
# Usage:
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-ror
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-epar
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-db
#   Rscript helper_scripts/sponsor_norm_pipeline/build_sponsor_index.R --no-businesskey --no-location
#
# Environment:
#   DB_PATH  path to trials.sqlite (default: <project>/data/trials.sqlite)
#
# Outputs:
#   config/sponsor_norm_pipeline/sponsor_alias_index.csv       full merged alias table
#   config/sponsor_norm_pipeline/sponsor_ambiguous_aliases.csv aliases → multiple sponsors
#   config/sponsor_norm_pipeline/new_sponsor_candidates.csv    unmatched for manual review

suppressPackageStartupMessages({
  library(httr2)
  library(readxl)
  library(dplyr)
  library(stringr)
  library(stringi)
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
  ofiles <- vapply(sys.frames(), function(frame) {
    if (!is.null(frame$ofile)) frame$ofile else NA_character_
  }, character(1))
  ofiles <- ofiles[!is.na(ofiles)]
  if (length(ofiles)) normalizePath(ofiles[[length(ofiles)]], mustWork = TRUE) else NA_character_
})
script_dir   <- if (!is.na(script_path)) dirname(script_path) else getwd()
project_root <- normalizePath(file.path(script_dir, "..", ".."), mustWork = TRUE)
project_path <- function(...) file.path(project_root, ...)

args            <- commandArgs(trailingOnly = TRUE)
no_epar         <- "--no-epar"         %in% args
no_ror          <- "--no-ror"          %in% args
no_db           <- "--no-db"           %in% args
no_businesskey  <- "--no-businesskey"  %in% args
no_email        <- "--no-email"        %in% args
no_location     <- "--no-location"     %in% args

SNP          <- project_path("config", "sponsor_norm_pipeline")
OUT_INDEX    <- file.path(SNP, "sponsor_alias_index.csv")
OUT_AMBIG    <- file.path(SNP, "sponsor_ambiguous_aliases.csv")
OUT_NEW      <- file.path(SNP, "new_sponsor_candidates.csv")
OUT_ORGS     <- file.path(SNP, "ctis_org_candidates.csv")

# ── Load normaliser helpers ───────────────────────────────────────────────────
source(
  project_path("helper_scripts", "sponsor_norm_pipeline", "normalise_sponsors.R"),
  local = FALSE
)

# ── Manual aliases (seed) ─────────────────────────────────────────────────────

manual_path <- file.path(SNP, "manual_sponsor_aliases.csv")
manual <- readr::read_csv(manual_path, show_col_types = FALSE) |>
  dplyr::mutate(alias_clean = clean_sponsor_alias(alias_clean))

message(sprintf("Manual aliases: %d entries", nrow(manual)))

# Build a lookup table: alias_clean → canonical sponsor fields
# Used to resolve external source names against known canonicals.
alias_lookup <- manual |>
  dplyr::select(
    alias_clean, sponsor_clean, sponsor_parent, sponsor_group, sponsor_type
  ) |>
  dplyr::distinct(alias_clean, .keep_all = TRUE)

resolve_external <- function(raw_name, source_label, confidence) {
  ac         <- clean_sponsor_alias(raw_name)
  candidates <- make_sponsor_candidates(raw_name)

  hit <- alias_lookup |>
    dplyr::filter(alias_clean %in% candidates) |>
    dplyr::slice(1)

  if (nrow(hit) == 0) return(NULL)

  tibble::tibble(
    alias_clean      = ac,
    sponsor_clean    = hit$sponsor_clean,
    sponsor_parent   = hit$sponsor_parent,
    sponsor_group    = hit$sponsor_group,
    sponsor_type     = hit$sponsor_type,
    alias_type       = source_label,
    source           = source_label,
    confidence_prior = confidence
  )
}

# ── EMA EPAR — Marketing Authorisation Holder names ──────────────────────────

epar_rows <- tibble::tibble(
  alias_clean      = character(),
  sponsor_clean    = character(),
  sponsor_parent   = character(),
  sponsor_group    = character(),
  sponsor_type     = character(),
  alias_type       = character(),
  source           = character(),
  confidence_prior = numeric()
)

if (!no_epar) {
  EPAR_URL <- paste0(
    "https://www.ema.europa.eu/en/documents/report/",
    "medicines-output-medicines-report_en.xlsx"
  )

  message("Downloading EMA medicines report...")
  dest <- tempfile(fileext = ".xlsx")
  tryCatch({
    request(EPAR_URL) |>
      req_timeout(180) |>
      req_perform() |>
      resp_body_raw() |>
      writeBin(dest)
    message("Download complete.")

    # Find the header row dynamically — EMA occasionally adds/removes metadata rows.
    # The header row is the first row containing "name of medicine" or "active substance".
    raw_excel <- readxl::read_excel(dest, col_names = FALSE, skip = 0,
                                    .name_repair = "minimal")
    row_strings <- apply(raw_excel, 1, function(r) {
      paste(tolower(trimws(as.character(unlist(r, use.names = FALSE)))),
            collapse = " ")
    })
    header_idx <- which(
      grepl("name of medicine", row_strings) |
      grepl("active substance", row_strings)
    )[1]

    if (is.na(header_idx)) {
      stop("Could not find header row in EPAR Excel")
    }

    headers   <- stringr::str_squish(
      as.character(unlist(raw_excel[header_idx, ], use.names = FALSE))
    )
    data_rows <- raw_excel[(header_idx + 1):nrow(raw_excel), ]
    colnames(data_rows) <- headers

    # The EMA MAH column is "Marketing authorisation developer / applicant / holder"
    # (exact wording varies across releases); match on the shared prefix.
    # Use ignore.case so the returned value preserves the original column name.
    mah_col <- grep(
      "marketing authori[sz]ation",
      names(data_rows),
      ignore.case = TRUE,
      value = TRUE
    )[1]

    if (is.na(mah_col)) {
      message(
        "WARNING: Could not find MAH column. Columns: ",
        paste(names(data_rows), collapse = ", ")
      )
    } else {
      mah_names <- data_rows[[mah_col]]
      mah_names <- unique(mah_names[!is.na(mah_names) & nzchar(trimws(mah_names))])
      message(sprintf("EPAR: %d unique MAH names", length(mah_names)))

      epar_resolved <- purrr::map_dfr(
        mah_names,
        ~ resolve_external(.x, source_label = "epar_mah", confidence = 0.85)
      )

      n_unmatched <- length(mah_names) - nrow(epar_resolved)
      message(sprintf(
        "EPAR: %d matched, %d unmatched (see new_sponsor_candidates.csv)",
        nrow(epar_resolved), n_unmatched
      ))

      # Write unmatched MAH names for manual review
      unmatched_mah <- mah_names[
        !clean_sponsor_alias(mah_names) %in% epar_resolved$alias_clean
      ]
      epar_rows <- epar_resolved
    }
  }, error = function(e) {
    message("WARNING: EPAR download/parse failed: ", conditionMessage(e))
  })
}

# ── ROR — academic and hospital name variants ─────────────────────────────────

ror_rows <- tibble::tibble(
  alias_clean      = character(),
  sponsor_clean    = character(),
  sponsor_parent   = character(),
  sponsor_group    = character(),
  sponsor_type     = character(),
  alias_type       = character(),
  source           = character(),
  confidence_prior = numeric()
)

if (!no_ror) {
  # Query ROR for academic/hospital organizations in EU trial-heavy countries.
  # ROR v1 API: paginated, 20 results per page.
  # We target organizations that are likely EU clinical trial sponsors.

  EU_COUNTRIES <- c(
    "NL", "BE", "DE", "FR", "GB", "IT", "ES", "DK", "SE", "NO",
    "AT", "CH", "FI", "PT", "IE", "PL", "CZ", "HU", "GR", "RO"
  )
  ROR_TYPES <- c("education", "healthcare")
  ROR_BASE  <- "https://api.ror.org/organizations"

  fetch_ror_page <- function(page, country, type) {
    tryCatch({
      resp <- request(ROR_BASE) |>
        req_url_query(
          page    = page,
          filter  = paste0(
            "country.country_code:", country,
            ",types:", stringr::str_to_title(type)
          )
        ) |>
        req_timeout(30) |>
        req_retry(max_tries = 3, backoff = ~ 2) |>
        req_perform() |>
        resp_body_json()
      resp
    }, error = function(e) {
      message("  ROR page error (", country, "/", type, "/p", page, "): ",
              conditionMessage(e))
      NULL
    })
  }

  extract_ror_names <- function(org) {
    names_vec <- character(0)
    if (!is.null(org$name)) names_vec <- c(names_vec, org$name)
    if (!is.null(org$aliases) && length(org$aliases) > 0) {
      names_vec <- c(names_vec, unlist(org$aliases))
    }
    if (!is.null(org$labels) && length(org$labels) > 0) {
      labels <- purrr::map_chr(org$labels, ~ .x$label %||% NA_character_)
      names_vec <- c(names_vec, labels[!is.na(labels)])
    }
    if (!is.null(org$acronyms) && length(org$acronyms) > 0) {
      names_vec <- c(names_vec, unlist(org$acronyms))
    }
    unique(names_vec[nzchar(names_vec)])
  }

  `%||%` <- function(a, b) if (!is.null(a)) a else b

  message("Querying ROR for EU academic/hospital organizations...")

  ror_all_names <- character(0)

  for (country in EU_COUNTRIES) {
    for (type in ROR_TYPES) {
      page1 <- fetch_ror_page(1, country, type)
      if (is.null(page1)) next

      total     <- page1$number_of_results %||% 0L
      n_pages   <- ceiling(total / 20)
      if (n_pages == 0) next

      message(sprintf("  %s/%s: %d orgs, %d pages", country, type, total, n_pages))

      orgs <- page1$items %||% list()
      for (p in seq_len(min(n_pages, 50))) {  # cap at 50 pages (1000 orgs) per combo
        if (p > 1) {
          Sys.sleep(0.05)
          pg <- fetch_ror_page(p, country, type)
          if (!is.null(pg)) orgs <- c(orgs, pg$items %||% list())
        }
      }

      new_names <- purrr::map(orgs, extract_ror_names) |> unlist()
      ror_all_names <- unique(c(ror_all_names, new_names))
    }
  }

  message(sprintf("ROR: %d unique name strings collected", length(ror_all_names)))

  ror_resolved <- purrr::map_dfr(
    ror_all_names,
    ~ resolve_external(.x, source_label = "ror", confidence = 0.75)
  )

  n_ror_unmatched <- length(ror_all_names) - nrow(ror_resolved)
  message(sprintf(
    "ROR: %d matched, %d unmatched",
    nrow(ror_resolved), n_ror_unmatched
  ))

  ror_rows <- ror_resolved
}

# ── DB-sourced tiers: businessKey / email-domain / postcode ──────────────────

empty_tier <- tibble::tibble(
  alias_clean      = character(),
  sponsor_clean    = character(),
  sponsor_parent   = character(),
  sponsor_group    = character(),
  sponsor_type     = character(),
  alias_type       = character(),
  source           = character(),
  confidence_prior = numeric()
)
bk_rows    <- empty_tier
email_rows <- empty_tier
loc_rows   <- empty_tier

bk_unresolved <- tibble::tibble(
  businesskey = character(),
  raw_name    = character(),
  alias_clean = character()
)

if (!no_db) {
  db_path <- Sys.getenv(
    "DB_PATH", unset = project_path("data", "trials.sqlite")
  )
  if (!file.exists(db_path)) {
    message(
      "WARNING: DB not found at ", db_path,
      " — skipping DB tiers (use --no-db to suppress, or set DB_PATH)"
    )
  } else {
    suppressPackageStartupMessages({
      library(nodbi)
      library(ctrdata)
    })

    db <- nodbi::src_sqlite(dbname = db_path, collection = "trials")

    # Helper: resolve a raw name against the manual alias lookup.
    # Returns the first matching alias_lookup row, or NULL.
    resolve_name <- function(raw_name) {
      cands <- make_sponsor_candidates(raw_name)
      hit   <- alias_lookup[alias_lookup$alias_clean %in% cands, , drop = FALSE]
      if (nrow(hit) > 0) hit[1L, ] else NULL
    }

    # Helper: build one alias row given a canonical hit tibble.
    make_alias_row <- function(ac, canonical, alias_type, source, conf) {
      tibble::tibble(
        alias_clean      = ac,
        sponsor_clean    = canonical$sponsor_clean,
        sponsor_parent   = canonical$sponsor_parent,
        sponsor_group    = canonical$sponsor_group,
        sponsor_type     = canonical$sponsor_type,
        alias_type       = alias_type,
        source           = source,
        confidence_prior = conf
      )
    }

    # ── Tier 1: CTIS businessKey (confidence 0.95) ───────────────────────────

    if (!no_businesskey) {
      message("Tier 1 — CTIS businessKey aliases...")
      NAME_COL <- paste0(
        "authorizedApplication.authorizedPartI",
        ".sponsors.organisation.name"
      )
      BK_COL <- paste0(
        "authorizedApplication.authorizedPartI",
        ".sponsors.organisation.businessKey"
      )

      bk_df <- ctrdata::dbGetFieldsIntoDf(
        fields = c(NAME_COL, BK_COL), con = db
      )
      bk_df <- bk_df[
        grepl("[0-9][0-9]$", bk_df[["_id"]]) &
        !is.na(bk_df[[BK_COL]]) & !is.na(bk_df[[NAME_COL]]),
      ]

      bk_groups <- bk_df |>
        dplyr::group_by(.data[[BK_COL]]) |>
        dplyr::summarise(
          names = list(unique(.data[[NAME_COL]])), .groups = "drop"
        ) |>
        dplyr::filter(purrr::map_int(names, length) > 1L)

      message(sprintf(
        "  %d businessKeys with >=2 name variants", nrow(bk_groups)
      ))

      new_bk <- vector("list", nrow(bk_groups))

      for (i in seq_len(nrow(bk_groups))) {
        names_i <- bk_groups$names[[i]]
        hits    <- purrr::map(names_i, resolve_name)
        resolved   <- purrr::compact(hits)
        canonicals <- purrr::map_chr(resolved, ~ .x$sponsor_clean)

        if (length(resolved) == 0L) {
          bk_unresolved <- dplyr::bind_rows(
            bk_unresolved,
            tibble::tibble(
              businesskey = bk_groups[[BK_COL]][i],
              raw_name    = names_i,
              alias_clean = clean_sponsor_alias(names_i)
            )
          )
          next
        }
        if (dplyr::n_distinct(canonicals) > 1L) next  # ambiguous key

        canonical    <- resolved[[1L]]
        unresolved_i <- names_i[purrr::map_lgl(hits, is.null)]

        new_bk[[i]] <- purrr::map_dfr(unresolved_i, function(nm) {
          ac <- clean_sponsor_alias(nm)
          if (nchar(ac) < 2L) return(NULL)
          make_alias_row(ac, canonical, "ctis_businesskey",
                         "ctis_businesskey", 0.95)
        })
      }

      bk_rows <- dplyr::bind_rows(new_bk)
      message(sprintf("  %d new alias entries", nrow(bk_rows)))
    }

    # ── Tier 2: EUCTR email domain (confidence 0.85) ─────────────────────────

    if (!no_email) {
      # Domains shared by CROs, generic mail, or regional health authorities
      # that umbrella multiple distinct sponsor institutions.
      blocked_domains <- c(
        "ppdi.com", "covance.com", "quintiles.com", "iqvia.com",
        "parexel.com", "pra.com", "praintl.com", "icon.com", "iconplc.com",
        "syneos.com", "medpace.com", "clinipace.com", "clinact.com",
        "inventivhealth.com", "tfscro.com", "psi-cro.com", "nuvisan.com",
        "worldwide.com", "icta.fr",
        "gmail.com", "yahoo.com", "hotmail.com", "outlook.com", "nhs.net"
      )

      # Generic institution-type tokens that are too common to be discriminative.
      generic_tokens <- c(
        "university", "hospital", "centre", "center", "medical", "institute",
        "research", "department", "foundation", "national", "general",
        "royal", "clinical", "health", "science", "sciences", "college",
        "academic", "school", "faculty", "division", "unit", "trust",
        "regional", "municipal", "canton", "universitaire", "universitario",
        "universitaria", "universitaet", "universitets", "universitets",
        "clinique", "clinic", "klinik", "klinikum", "ziekenhuis",
        "ospedale", "hopital", "krankenhaus", "sjukhuset", "sygehus",
        "uniklinik", "medizinische"
      )

      message("Tier 2 — EUCTR email domain aliases...")

      em_df <- ctrdata::dbGetFieldsIntoDf(
        fields = c("b1_sponsor.b11_name_of_sponsor", "b1_sponsor.b56_email"),
        con    = db
      )
      em_df <- em_df[
        grepl("[A-Z][A-Z0-9]*$", em_df[["_id"]]) &
        !is.na(em_df[["b1_sponsor.b56_email"]]) &
        !is.na(em_df[["b1_sponsor.b11_name_of_sponsor"]]),
      ]

      raw_email <- stringr::str_replace_all(
        em_df[["b1_sponsor.b56_email"]], "&#64;|&#x40;", "@"
      )
      em_df$domain <- tolower(trimws(sub(".*@", "", raw_email)))
      em_df$domain <- stringr::str_extract(
        em_df$domain, "^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}"
      )
      em_df <- em_df[
        !is.na(em_df$domain) & !em_df$domain %in% blocked_domains,
      ]

      dom_groups <- em_df |>
        dplyr::group_by(domain) |>
        dplyr::summarise(
          names = list(unique(`b1_sponsor.b11_name_of_sponsor`)),
          .groups = "drop"
        )

      new_em <- vector("list", nrow(dom_groups))

      for (i in seq_len(nrow(dom_groups))) {
        names_i  <- dom_groups$names[[i]]
        domain_i <- dom_groups$domain[i]
        hits     <- purrr::map(names_i, resolve_name)
        resolved   <- purrr::compact(hits)
        canonicals <- purrr::map_chr(resolved, ~ .x$sponsor_clean)

        if (length(resolved) == 0L)             next
        if (dplyr::n_distinct(canonicals) > 1L) next  # ambiguous domain

        canonical     <- resolved[[1L]]
        canonical_clean <- clean_sponsor_alias(canonical$sponsor_clean)
        sig_tokens <- function(s) {
          t <- stringr::str_split(clean_sponsor_alias(s), "\\s+")[[1L]]
          t <- t[nchar(t) >= 4L]
          t[!t %in% generic_tokens]
        }
        # Discriminative tokens from all resolved names in this domain
        anchor_tokens <- unique(unlist(purrr::map(
          purrr::map_chr(resolved, ~ .x$sponsor_clean), sig_tokens
        )))
        unresolved_i <- names_i[purrr::map_lgl(hits, is.null)]

        new_em[[i]] <- purrr::map_dfr(unresolved_i, function(nm) {
          ac <- clean_sponsor_alias(nm)
          if (nchar(ac) < 2L) return(NULL)
          # Require at least one shared discriminative token to guard against
          # investigator emails being attributed to an unrelated sponsor.
          if (length(anchor_tokens) == 0L) return(NULL)
          nm_sig <- sig_tokens(nm)
          if (length(intersect(nm_sig, anchor_tokens)) == 0L) return(NULL)
          make_alias_row(ac, canonical, "euctr_email_domain",
                         paste0("euctr_email_domain:", domain_i), 0.85)
        })
      }

      email_rows <- dplyr::bind_rows(new_em)
      message(sprintf("  %d new alias entries", nrow(email_rows)))
    }

    # ── Tier 3: Postcode + country + JW similarity (confidence 0.70) ─────────

    if (!no_location) {
      message("Tier 3 — Postcode + country aliases...")

      ctis_loc <- ctrdata::dbGetFieldsIntoDf(fields = c(
        paste0("authorizedApplication.authorizedPartI",
               ".sponsors.organisation.name"),
        paste0("authorizedApplication.authorizedPartI",
               ".sponsors.addresses.address.postcode"),
        paste0("authorizedApplication.authorizedPartI",
               ".sponsors.addresses.address.countryName")
      ), con = db)

      ctis_loc <- ctis_loc[
        grepl("[0-9][0-9]$", ctis_loc[["_id"]]),
      ] |>
        dplyr::transmute(
          name = .data[[paste0(
            "authorizedApplication.authorizedPartI",
            ".sponsors.organisation.name"
          )]],
          postcode = toupper(stringr::str_squish(.data[[paste0(
            "authorizedApplication.authorizedPartI",
            ".sponsors.addresses.address.postcode"
          )]])),
          country = .data[[paste0(
            "authorizedApplication.authorizedPartI",
            ".sponsors.addresses.address.countryName"
          )]]
        ) |>
        dplyr::filter(
          !is.na(name), !is.na(postcode), !is.na(country), nzchar(postcode)
        )

      euctr_loc <- ctrdata::dbGetFieldsIntoDf(fields = c(
        "b1_sponsor.b11_name_of_sponsor",
        "b1_sponsor.b533_post_code",
        "b1_sponsor.b534_country"
      ), con = db)

      euctr_loc <- euctr_loc[
        grepl("[A-Z][A-Z0-9]*$", euctr_loc[["_id"]]),
      ] |>
        dplyr::transmute(
          name     = .data[["b1_sponsor.b11_name_of_sponsor"]],
          postcode = toupper(stringr::str_squish(
            .data[["b1_sponsor.b533_post_code"]]
          )),
          country  = .data[["b1_sponsor.b534_country"]]
        ) |>
        dplyr::filter(
          !is.na(name), !is.na(postcode), !is.na(country), nzchar(postcode)
        )

      all_loc <- dplyr::bind_rows(ctis_loc, euctr_loc)

      loc_groups <- all_loc |>
        dplyr::group_by(postcode, country) |>
        dplyr::summarise(
          names = list(unique(name)), .groups = "drop"
        ) |>
        dplyr::filter(purrr::map_int(names, length) > 1L)

      message(sprintf(
        "  %d postcode+country groups with >=2 names", nrow(loc_groups)
      ))

      new_loc <- vector("list", nrow(loc_groups))

      for (i in seq_len(nrow(loc_groups))) {
        names_i      <- loc_groups$names[[i]]
        hits         <- purrr::map(names_i, resolve_name)
        resolved_idx <- which(!purrr::map_lgl(hits, is.null))

        if (length(resolved_idx) == 0L) next

        name_clean_i <- clean_sponsor_alias(names_i)
        unresolved_j <- which(purrr::map_lgl(hits, is.null))
        group_rows   <- list()

        for (ri in resolved_idx) {
          canonical    <- hits[[ri]]
          anchor_clean <- name_clean_i[[ri]]

          for (j in unresolved_j) {
            jw_sim <- 1 - stringdist::stringdist(
              anchor_clean, name_clean_i[[j]], method = "jw", p = 0.1
            )
            if (jw_sim < 0.88) next
            ac <- clean_sponsor_alias(names_i[[j]])
            if (nchar(ac) < 2L) next
            group_rows <- c(group_rows, list(
              make_alias_row(ac, canonical,
                             "location_postcode", "location_postcode", 0.70)
            ))
          }
        }

        if (length(group_rows) > 0L) {
          new_loc[[i]] <- dplyr::bind_rows(group_rows)
        }
      }

      loc_rows <- dplyr::bind_rows(new_loc)
      message(sprintf("  %d new alias entries", nrow(loc_rows)))
    }
  }
}

db_rows <- dplyr::bind_rows(bk_rows, email_rows, loc_rows)

# ── Merge ─────────────────────────────────────────────────────────────────────

# Prepare manual seed in the same schema
manual_index <- manual |>
  dplyr::mutate(alias_type = "manual") |>
  dplyr::select(
    alias_clean, sponsor_clean, sponsor_parent, sponsor_group,
    sponsor_type, alias_type, source, confidence_prior
  )

# Row order = priority: manual > epar > ror > db (businesskey > email > location)
combined <- dplyr::bind_rows(manual_index, epar_rows, ror_rows, db_rows) |>
  dplyr::filter(
    !is.na(alias_clean), !is.na(sponsor_clean),
    nchar(alias_clean) >= 2, nchar(sponsor_clean) >= 2
  ) |>
  dplyr::distinct(alias_clean, sponsor_clean, .keep_all = TRUE)

message(sprintf("Combined index: %d total alias entries", nrow(combined)))

# ── Ambiguous aliases ─────────────────────────────────────────────────────────

n_per_alias <- combined |>
  dplyr::distinct(alias_clean, sponsor_clean) |>
  dplyr::count(alias_clean, name = "n_sponsors")

ambiguous <- combined |>
  dplyr::filter(
    alias_clean %in% (n_per_alias |> dplyr::filter(n_sponsors > 1))$alias_clean
  ) |>
  dplyr::group_by(alias_clean) |>
  dplyr::summarise(
    sponsors_all = paste(sort(unique(sponsor_clean)), collapse = "|"),
    n_sponsors   = dplyr::n_distinct(sponsor_clean),
    sources      = paste(sort(unique(source)), collapse = "|"),
    .groups      = "drop"
  ) |>
  dplyr::arrange(dplyr::desc(n_sponsors), alias_clean)

message(sprintf(
  "Ambiguous aliases (one alias → multiple sponsors): %d",
  nrow(ambiguous)
))

readr::write_csv(ambiguous, OUT_AMBIG)
message(sprintf("Wrote %d ambiguous aliases to %s", nrow(ambiguous), OUT_AMBIG))

# ── New sponsor candidates (unmatched external names) ─────────────────────────

# Collect all external names that didn't match anything in the manual table
new_candidates <- tibble::tibble(
  raw_name   = character(),
  source     = character(),
  alias_clean = character()
)

if (!no_epar && exists("unmatched_mah")) {
  new_candidates <- dplyr::bind_rows(
    new_candidates,
    tibble::tibble(
      raw_name    = unmatched_mah,
      source      = "epar_mah",
      alias_clean = clean_sponsor_alias(unmatched_mah)
    )
  )
}

if (!no_db && nrow(bk_unresolved) > 0L) {
  # Collapse each businessKey group to one row.
  # Canonical = shortest alias_clean in the group (tends to be the most
  # stripped-down form; reviewer can override when adding to manual aliases).
  org_candidates <- bk_unresolved |>
    dplyr::group_by(businesskey) |>
    dplyr::arrange(nchar(alias_clean), .by_group = TRUE) |>
    dplyr::summarise(
      suggested_canonical = raw_name[1L],
      alias_clean         = alias_clean[1L],
      n_variants          = dplyr::n(),
      other_names         = if (dplyr::n() > 1L) {
        paste(raw_name[-1L], collapse = " | ")
      } else NA_character_,
      .groups = "drop"
    ) |>
    dplyr::arrange(alias_clean)

  readr::write_csv(org_candidates, OUT_ORGS)
  message(sprintf(
    "Wrote %d unresolved CTIS org groups to %s (for manual review)",
    nrow(org_candidates), OUT_ORGS
  ))
}

# Collapse variants into one row per group using two passes:
#  1. Exact suggest_key match — strips legal suffixes + single-char fragments
#     (handles S.A./SA, GmbH/AG, B.V./BV, Ltd/Limited, etc.)
#  2. JW fuzzy cluster on suggest_key at >=0.90 — catches linguistic variants
#     that survive suffix stripping (Companhia/Ca/Cª, Corp./Co., etc.)
suggest_key <- function(raw) {
  s <- tolower(suggest_sponsor_clean(raw))

  # Strip branch/office indicators and the city token that follows them.
  # e.g. "Zweigniederlassung Jena" → "", "Sucursal Madrid" → ""
  s <- stringr::str_remove_all(s, stringr::regex(
    "\\b(zweigniederlassung|niederlassung|sucursal|filiale|agencia|branch)\\b(\\s+[a-z]+)?",
    ignore_case = TRUE
  ))

  # Strip country name tokens not already covered by .address_rx.
  s <- stringr::str_remove_all(s, stringr::regex(paste0("\\b(", paste(c(
    "ireland", "spain", "italy", "portugal", "sweden", "denmark",
    "norway", "finland", "poland", "czech", "hungary", "greece",
    "romania", "bulgaria", "slovakia", "croatia", "slovenia",
    "luxembourg", "malta", "cyprus", "australia", "canada",
    "japan", "china", "india", "brazil", "mexico"
  ), collapse = "|"), ")\\b"), ignore_case = TRUE))

  s <- stringr::str_squish(s)

  # Re-apply legal suffix strip — catches suffixes exposed by the removals
  # above (e.g. "Limited" in "Biolitec Limited Zweigniederlassung Jena").
  legal_rx <- paste0(
    "\\s+\\b(",
    paste(c(
      "inc", "corp", "corporation", "company", "co", "ltd", "limited",
      "llc", "plc", "ag", "gmbh", "kg", "kgaa", "bv", "nv", "sa",
      "sas", "srl", "spa", "ab", "oy", "pte", "kk", "ehf", "hf"
    ), collapse = "|"),
    ")$"
  )
  s <- stringr::str_remove(s, stringr::regex(legal_rx, ignore_case = TRUE))
  s <- stringr::str_squish(s)

  toks <- stringr::str_split(s, "\\s+")[[1L]]
  stringr::str_squish(paste(toks[nchar(toks) > 1L], collapse = " "))
}

nc <- new_candidates |>
  dplyr::filter(!is.na(raw_name), nchar(alias_clean) >= 4L) |>
  dplyr::mutate(grp = purrr::map_chr(raw_name, suggest_key))

# Pass 1: exact key collapse — collect all raw names per (grp, source)
nc_grp <- nc |>
  dplyr::group_by(grp, source) |>
  dplyr::arrange(nchar(alias_clean), .by_group = TRUE) |>
  dplyr::summarise(raw_names = list(unique(raw_name)), .groups = "drop") |>
  dplyr::arrange(nchar(grp))  # shortest key first so clusters pick it as head

# Pass 2: JW fuzzy cluster within each source
n_nc   <- nrow(nc_grp)
parent <- seq_len(n_nc)
find   <- function(x) { r <- x; while (parent[r] != r) r <- parent[[r]]; r }

if (n_nc > 1L) {
  dist_mat <- stringdist::stringdistmatrix(
    nc_grp$grp, nc_grp$grp, method = "jw", p = 0.1
  )
  for (i in seq_len(n_nc - 1L)) {
    for (j in (i + 1L):n_nc) {
      if (nc_grp$source[i] != nc_grp$source[j]) next
      if (1 - dist_mat[i, j] < 0.90)            next
      ri <- find(i); rj <- find(j)
      if (ri != rj) parent[rj] <- ri
    }
  }
}

nc_grp$cluster <- vapply(seq_len(n_nc), find, integer(1L))

new_candidates <- nc_grp |>
  dplyr::group_by(cluster, source) |>
  dplyr::summarise(
    raw_name            = raw_names[[1L]][[1L]],
    suggested_canonical = stringr::str_to_title(grp[[1L]]),
    other_names = {
      all_r <- unique(unlist(raw_names))
      rest  <- all_r[all_r != raw_names[[1L]][[1L]]]
      if (length(rest) > 0L) paste(rest, collapse = " | ") else NA_character_
    },
    .groups = "drop"
  ) |>
  dplyr::select(raw_name, source, suggested_canonical, other_names) |>
  dplyr::arrange(source, suggested_canonical)

readr::write_csv(new_candidates, OUT_NEW)
message(sprintf(
  "Wrote %d unmatched external names to %s (for manual review)",
  nrow(new_candidates), OUT_NEW
))

# ── Write index ───────────────────────────────────────────────────────────────

readr::write_csv(combined, OUT_INDEX)
message(sprintf(
  "Wrote %d alias entries to %s", nrow(combined), OUT_INDEX
))
message("Done. Run build_sponsor_labels.R to apply the new index.")
