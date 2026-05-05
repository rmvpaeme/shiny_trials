# Sponsor Curation Guide

This folder contains the manual sponsor-name curation workflow.

The dashboard itself does **not** read `config/sponsor_aliases.csv` at runtime. That CSV is a review log. The app only changes after you run `apply_sponsor_aliases.R`, which rewrites the sponsor alias block in `app.R` and refreshes the cache.

## Files

- `audit_sponsors.R`: generates `data/sponsor_alias_candidates.csv`.
- `review_sponsor_aliases.R`: interactive row-by-row review.
- `approve_sponsor_aliases.R`: batch approval after editing the candidate CSV.
- `apply_sponsor_aliases.R`: applies approved aliases to `app.R`, refreshes cache/logs/candidates/baseline, and renders preprocessing.
- `sponsors.md`: historical handover notes and longer background.

Project-root files used by these scripts:

- `data/sponsor_alias_candidates.csv`: generated review queue.
- `config/sponsor_aliases.csv`: approved review decisions.
- `config/sponsor_review_decisions.csv`: resume log for candidates you approved or skipped in the interactive reviewer.
- `config/sponsor_curation_baseline.csv`: sponsor labels after the last completed curation.
- `data/sponsor_normalisation_log.csv`: raw-to-normalised sponsor log.

## Recommended First Curation

From the project root, run:

```sh
Rscript sponsor_curation/audit_sponsors.R
Rscript sponsor_curation/review_sponsor_aliases.R 100
```

For each candidate:

- `y`: approve the suggested mapping.
- `n`: skip it.
- `e`: edit canonical sponsor, pattern, match type, or note before approving.
- `q`: quit and save approvals so far.

Repeat the review command until the remaining candidates are mostly false positives:

```sh
Rscript sponsor_curation/review_sponsor_aliases.R 100
```

The reviewer resumes automatically. Every `y` approval and `n` skip is saved immediately to `config/sponsor_review_decisions.csv`, so quitting and reopening will continue with the next unreviewed candidate. To deliberately include already-reviewed candidates again:

At startup, the reviewer prints:

- how many previously reviewed candidates were skipped
- how many total candidates still remain to review
- how many candidates will be shown in the current batch

```sh
Rscript sponsor_curation/review_sponsor_aliases.R 100 --include-reviewed
```

## Spreadsheet-Style Approval

If you prefer editing the CSV directly:

```sh
Rscript sponsor_curation/audit_sponsors.R
```

Open `data/sponsor_alias_candidates.csv`, set `approved=TRUE` for rows that are genuinely the same sponsor, then run:

```sh
Rscript sponsor_curation/approve_sponsor_aliases.R
```

## Apply Approved Decisions

After review, apply the approved aliases to the dashboard data:

```sh
Rscript sponsor_curation/apply_sponsor_aliases.R
```

This command:

1. Rewrites the `sponsor_aliases <- list(...)` block in `app.R`.
2. Refreshes sponsor names in `trials_cache.rds`.
3. Rewrites `data/sponsor_normalisation_log.csv`.
4. Regenerates `data/sponsor_alias_candidates.csv`.
5. Updates `config/sponsor_curation_baseline.csv`.
6. Renders `preprocessing.Rmd`.

Useful variants:

```sh
Rscript sponsor_curation/apply_sponsor_aliases.R --no-render
Rscript sponsor_curation/apply_sponsor_aliases.R --no-cache --no-audit --no-render
```

## After New Trial Loads

After loading new trials and refreshing the cache:

```sh
Rscript sponsor_curation/audit_sponsors.R
Rscript sponsor_curation/review_sponsor_aliases.R 50
Rscript sponsor_curation/apply_sponsor_aliases.R
```

Then check `www/preprocessing.html`. The sponsor section should show how many sponsor labels are new since the previous manual curation.

## Safety Rules

- Skip uncertain matches.
- Prefer `exact` mappings; use `regex` only for clearly safe spelling variants.
- Keep different hospitals, universities, NHS trusts, and city-specific CHUs separate unless the mapping is explicit.
- Be conservative with pharma parent-company mappings.
