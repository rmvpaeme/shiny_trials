# Curation app — handover

Written for whoever picks this up next. Assumes you can read the code; this is
for the things the code cannot tell you.

Branch `feature/curation-app-v2`, ~22 commits off `main`. Not merged. Plan at
`PLANS/curation-app-v2.md`; user-facing docs at `curation_app/README.md`.

---

## 1. Read this first

**The pipeline's read side has always been ready. The write side did not exist.**
`helper_scripts/llm_norm/registry.R` honours `decided_by = "human"` in three
places — pinned assignments survive a re-run (`:271`), merges of human entities
are refused (`:307`), `route_for_review()` drops human rows (`:377`). Nothing
produced it. That is the entire reason this app exists, and it means **you
mostly should not need to touch the pipeline**: write `decided_by = "human"` and
everything downstream already behaves.

**One writer.** `curation_app/export.R`, on the server, inside the nightly. The
app never touches `config/*_norm_v2/` or `data/`. There is no shared filesystem
between Posit and the server, and a second writer racing `N_nightly_resolve.R`
is precisely the read-modify-write collision that killed the v1 reviewer app.
If you are about to make the app write a file, stop.

**Decisions are append-only and the loser is kept.** Latest-wins is a *view*
(`norm_decisions_latest`), not a string in R, so the app and `export.R` cannot
drift on the one rule that decides what reaches production. Superseded rows stay
because the disagreement report is the only safety net for last-write-wins.

---

## 2. Things that will bite you

Each of these cost real time. None is obvious from the code.

**A human reject used to freeze sponsor labels forever.** `entity_id = NA` →
`match_status "unknown"` → classified `REGRESSION: -> unknown` → exit 1 under
`--assert-no-regressions` → `rebuild_cache.R` keeps yesterday's labels
*permanently*, reported as a pipeline fault. Fixed by adding a third status,
`human_unassigned`, tested **before** the unknown branch in both `E_emit.R`
files. If you ever see that classifier reordered, this comes straight back.

**`git add -f` stages the WORK TREE copy.** The registries live outside the work
tree via `SPONSOR_V2_DIR` so the nightly's `git reset --hard` cannot revert
them — which means the path git stages is `main`'s frozen version. The nightly
now copies the live files in first (`publish_live`). This was already broken:
the substance queue had been published stale every night since 2026-08-22,
silently.

**Shiny outputs are cached; a plain list is not reactive.** The first auth
implementation held identity in `session$userData` as a list. `auth_user()`
correctly returned NULL on expiry and **the outputs kept rendering**, because
nothing invalidated them. Identity is a `reactiveVal` now, and `auth_watch()`
clears it on a timer. `last_seen` is deliberately *not* reactive — it is bumped
on every keystroke.

**`req(FALSE)` raises under `testServer`.** It does not return NULL. A test
asserting `is.null(output$x)` reports a working guard as a failure. Use the
`blocked()` helper.

**`.Renviron` is read from the STARTUP directory and overrides the inherited
environment.** The app starts in `curation_app/`, so a repo-root `.Renviron` is
invisible to it. And a test that passes a deliberately-bad `CURATION_DB_URL`
gets it silently overwritten — set `R_ENVIRON_USER=/dev/null` too.

**The Supabase session pooler allows 15 clients for the whole project**, not per
process. Exhausting it fails *at the login screen* and reads exactly like bad
credentials. The pool is 0–3 and `explain_connect_error()` says what is really
wrong. The direct endpoint `db.<ref>.supabase.co` is IPv6-only and unusable on a
network without IPv6.

**`rsconnect::deployApp()` bundles dotfiles.** Verified: a bare call uploads
`.Renviron`. Use `deploy.R`, which allowlists. An exclusion list fails open.

**Process substitution `<(...)` fails in some sandboxes** and `grep` then
succeeds having read nothing. Two tests in this repo passed without running
because of it. Read into a variable and assert it is non-empty.

---

## 3. The routing split

The single most important invariant in the app.

- `sponsor`, `sponsor_type`, `substance` → the registries, keyed on the **raw
  string**, fixing every trial that carries it.
- the other 15 editable fields → `data/trial_overrides.csv`, one trial only.

Enforced in **three independent places**, on purpose:

1. `field_spec.R` — registry-routed fields have `override_col = NA`
2. `attach_trial_overrides()` — an `OVERRIDE_DENY` list refuses `sponsor_*`,
   `substance_label` and every `_raw` column even if a hand-edited CSV asks
3. `tests/field_spec_matches_cache.R` — fails if 1 and 2 ever disagree

If you loosen any of these, the app starts *lying to the reviewer* about whether
their edit affects one trial or four hundred. That is worse than a crash.

---

## 4. What is deliberately absent

Do not "fix" these.

- **No row locking or claim protocol** in the queues. Last-write-wins, made safe
  by the disagreement report. A claim table is a stale-claim problem.
- **No same-day visibility.** A decision is live after the nightly. The app says
  "pending" rather than pretending.
- **No account self-service.** Accounts are seeded by SQL / created by an admin.
- **Accounts are never deleted**, only deactivated — decisions reference them.
- **`assignments.csv` is not fetched** (7.4 MB). Siblings come from the cache.
- **`REVIEW_LEDGER_PATH` / `read_human_sponsor_decisions()` in `app.R` is
  untouched.** It is a v1 CSV path keyed on `row_key` with a different action
  vocabulary. It returns NULL on a missing file and costs nothing. Wiring it up
  would give sponsor overrides two live mechanisms. **Do not connect it.**

---

## 5. State of play

**Working and verified against the live database and repo:** snapshot fetch,
login and role gating, all four tabs, the stratified sample, `export.R` end to
end including the reject case, and the nightly wiring.

**Not yet done:**

- The branch is **not merged**. Until it is, the deployed cache is v0.21.0 with
  73 columns and the five new `_raw` columns show "not retained in this
  snapshot".
- `export.R` has **never run on the server**. It has run in scratch dirs.
- The container needs `libpq-dev`, `RPostgres`, `sodium` installed — the
  `Dockerfile` was updated but the running `rstudio-rstudio-1` was not, and
  `docker exec` is what the nightly uses.
- `sql/app_role.sql` is written but **not applied**; the app still uses the
  `postgres` superuser.
- No sample has been drawn, so tab 1 is empty for every reviewer.
- Root `README.md` / `CHANGELOG.md` not yet updated for v0.22.0.

**Live accounts:** `laurevm`, `levih` (reviewers), `rubenvp` (admin). Their
initial passwords passed through a chat transcript and should be rotated via
Admin → Accounts.

---

## 6. If you change one thing, check these

| You change | Then check |
|---|---|
| `field_spec.R` | both apps render — it is shared; and `manifest.json`'s checksum |
| a `_raw` column | `DATA_PROCESSING_VERSION`, `cache_is_valid()`, and a full rebuild |
| `E_emit.R`'s classifier | `tests/emit_human_unassign.R` — both directions |
| either nightly script | `tests/nightly_scripts_agree.sh` — they must stay identical |
| anything with a credential | `tests/no_secrets.sh`, and verify it fails when broken |
| `export.R` | the round trip, twice, and confirm no second backup appears |

Run `tests/no_secrets.sh` before every push. The repo is public.
