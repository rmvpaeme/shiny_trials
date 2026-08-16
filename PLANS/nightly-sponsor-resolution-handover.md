# Nightly sponsor resolution — handover

**Branch:** `normalisation-v2`.
**Status:** Built and verified offline. **The API path has never run** — there was
no `ANTHROPIC_API_KEY` in the build environment, so every check below that needed
one was exercised through its refusal path instead. First live run is the
outstanding work.
**Last worked:** 2026-08-16.

---

## 1. Why this exists

The A–E passes are a one-shot batch over a frozen corpus. All 16,594 distinct raw
strings were assigned at mint time. But the database updates nightly, and a trial
registered today can carry a sponsor string the registry has never seen. That
string falls through `E_emit.R`'s `coalesce(sponsor_clean, sponsor_name)` and is
displayed raw — so the app slowly re-accumulates exactly the unnormalised names
the rewrite removed.

The flow, as specified:

```
rebuild_cache
  -> strings already assigned      ignored
  -> new strings that match nothing -> the LLM API
  -> low confidence                 -> existing curation flow
```

**Out of scope by instruction:** `curation_app/` is untouched. Wiring the reviewer
to `E_review_queue.csv` is separate work — a plan already exists at
`PLANS/curation-app-sponsor-v2.md`.

---

## 2. Two pre-existing bugs found while planning. Read this first.

Both were live in committed code and neither is specific to the nightly.

### 2.1 Re-materialising the registry resurrected merged-away entities

`C_assign.R` re-materialises the **entire** mint cache on every invocation.
`registry_from_clusters()` built its canonical → entity map from `registry_live()`
alone, so a canonical whose entity had been merged away was not "known", was
treated as fresh, and was **minted again as a live duplicate**.

Measured on the real registry, per run:

```
registry 7,238 -> 7,522   (+284, exactly the merged-away set)
assignments re-pointed: 527
```

One re-run of `C_assign` — by hand or nightly — silently undid every
`D_consolidate --apply`. Nothing errored; the registry just grew back.

Fixed in `registry.R` by resolving each canonical to its **terminal** entity
through `merged_into` (reusing the existing `resolve_entity()`), live rows winning
ties. Pinned by `tests/sponsor_v2_idempotence.R`, which fails with +284/527 against
the pre-fix code and passes now.

**This is why idempotence is load-bearing here.** Anything that runs unattended
must be safe to run twice.

### 2.2 The `--sync` path was unbudgeted and unmetered

The sync branches of `B_mint` and `C_assign` called `llm_sync()`, saved rows and
quit — no `llm_budget_guard()` before, no `llm_spend_record()` after — and
`llm_sync()` discarded `resp$usage` entirely. Evidence: 373 real `C_assign` sync
requests left **no row at all** in `llm_spend.csv`.

The nightly must use sync, so without this it would be completely unmetered and
`BUDGET_CAP_USD` would never bind. `llm_sync()` now returns usage on
`attr(rows, "usage")`, and both branches guard and record via the new
`llm_spend_record_sync()`.

---

## 3. What was built

| File | Change |
|---|---|
| **NEW** `helper_scripts/sponsor_norm_pipeline/N_nightly_resolve.R` | the orchestrator |
| **NEW** `tests/sponsor_v2_idempotence.R` | regression fixture for 2.1 |
| `helper_scripts/llm_norm/registry.R` | terminal-entity resolution (2.1) |
| `helper_scripts/llm_norm/client.R` | sync usage capture, `llm_spend_record_sync()`, `llm_run_cap_guard()`, `ant` fallback timeout + `LLM_REQUIRE_API_KEY` |
| `B_mint.R`, `C_assign.R` | `--blocks=`, sync guard + metering |
| `D_consolidate.R`, `E_emit.R` | `SPONSOR_V2_DIR`; `E_emit` gained `--assert-no-regressions` |
| `rebuild_cache.R` | `run_step()`, the four-step sponsor sequence |
| `nightly_update/nightly_deploy_posit.sh` | scoped dirty check, sentinel, exit 3 after push |

Every default is unchanged, so manual runs and the documented A→E workflow behave
exactly as before.

### Design decisions worth not re-litigating

- **C before B.** Offering a new string to the existing registry before minting is
  what stops a new Novartis variant becoming a second Novartis. Minting first
  fragments the registry the way v1 did.
- **Never `A_block`.** It rewrites `data/sponsor_blocks.csv`, which is `B_mint`'s
  `members_sha` cache-key input — re-blocking would trigger paid re-mints of
  unrelated blocks. New strings get a singleton work list at `N_blocks.csv` via
  the new `--blocks=` flag.
- **Never `D_consolidate`.** A wrong merge is the most expensive error the pipeline
  can make and its mis-index guard is hand-tuned against measured failures. New
  canonicals go to `N_new_entities.csv` for a periodic human run.
- **Never `--batch`.** `llm_batch_wait()` blocks on a 60s poll for up to 24h; the
  nightly window is ~1h. At ~$0.0013/string, sync on 30 strings is four cents.
- **Refuse, never truncate.** Above the ceiling or the cap, no calls are made at
  all. A silently truncated work list becomes a permanent backlog nobody notices.
- **`rebuild_cache.R` always exits 0.** `set -e` in the deploy script would
  otherwise abort before `trials_cache.rds` is committed — a sponsor hiccup must
  not cost the data refresh. Failure travels by sentinel file instead.
- **Detection precedes authentication.** The "0 new strings" path needs no key and
  makes no network call. On a normal night that is the whole program.

---

## 4. What was verified, and what was not

Verified end to end:

| Check | Result |
|---|---|
| 0 new strings, key unset | exit 0, no calls, state byte-identical |
| 2 synthetic new strings, `--dry-run` | both detected, $0.0026 estimated, no calls |
| new strings, no key | **exit 10**, backlog + sentinel written |
| `SPONSOR_NIGHTLY_MAX_SYNC=1` | **exit 12**, backlog written, no calls |
| `SPONSOR_NIGHTLY_CAP_USD=0` | **exit 11**, backlog written, no calls |
| run history across 4 runs | appends cleanly |
| `E_emit --assert-no-regressions`, clean state | exit 0 |
| same, against a deliberately damaged registry | **exit 1**, 17 regressions reported |
| `tests/sponsor_v2_idempotence.R` | 7/7 pass; fails pre-fix |
| real `config/sponsor_norm_v2/` after all testing | untouched |

**Not verified — this is the gap:** no request has ever been sent by this code
path. Exit 13 (API failure detection) and the success path are untested against a
live API. `SPONSOR_V2_DIR` and `DATA_DIR` were exercised throughout, so the first
live run can safely be done against a scratch copy.

### First live run

```sh
export ANTHROPIC_API_KEY='sk-ant-...' LLM_REQUIRE_API_KEY=1
cp -a config/sponsor_norm_v2 /tmp/v2test
cp -a data /tmp/dtest
printf '2099-000001-01-XX,Novartis Pharma Services Trading Ltd,TRUE\n' >> /tmp/dtest/trial_sponsors_raw.csv
SPONSOR_V2_DIR=/tmp/v2test DATA_DIR=/tmp/dtest \
  Rscript helper_scripts/sponsor_norm_pipeline/N_nightly_resolve.R
```

Expect: C places it on the **existing** Novartis entity, `registry.csv` row count
**unchanged**, `assignments.csv` +1, a `C_assign` row appears in `llm_spend.csv`
with `batch = FALSE`. If the registry grew, C abstained where it should have
matched — check retrieval before letting it run unattended.

---

## 5. Deployment — not done yet

The nightly runs on a separate Ubuntu box that `docker exec`s into the
`rstudio-rstudio-1` container. Three things must be set up there:

1. **`ANTHROPIC_API_KEY` inside the container.** `docker exec` is called without
   `-e`, so the cron environment does not reach it. Use an `env_file:`, or the
   container user's `~/.Renviron` — **not** the project one, because
   `rebuild_cache.R` `setwd()`s after R has started, so a project-directory
   `.Renviron` is never read.
2. **`LLM_REQUIRE_API_KEY=1`** in the same place. Without it a missing key falls
   back to the `ant` CLI, which can block; a cron job that blocks holds the deploy
   all day. (There is now a 10s timeout as a second line of defence.)
3. **`SPONSOR_V2_DIR` pointing outside the git work tree.** The deploy script runs
   `git reset --hard "$REMOTE/$SOURCE_BRANCH"` at the *start* of every run, so
   anything the nightly writes under `config/` is discarded before the next one.
   Without this the same strings are re-sent every night and `llm_spend.csv`
   resets, meaning the $60 cap never binds.

**Reconcile the drifted production script first.** `git show --stat 64836a3` (a real
nightly commit) contains 15 files including `data/trial_sponsors_raw.csv`, but the
committed `nightly_deploy_posit.sh` stages only 2 — the host copy is not the repo
copy, so edits here will not be what runs.

---

## 6. Known gaps

1. **State promotion back into git is deliberately undesigned.** You asked to skip
   it because the curation app will import new curations. `SPONSOR_V2_DIR` is the
   minimum that keeps the nightly working; where it points and how registry growth
   returns to the repo is open.
2. **A full re-materialisation still rewrites `decided_at_utc`** on every
   mint-derived assignment row, so `assignments.csv` churns even when nothing
   changes semantically. Harmless while state lives outside git; add
   `--materialise=new` to `C_assign` if that ever matters.
3. **`curation_app/` is not wired to the v2 queue** — `PLANS/curation-app-sponsor-v2.md`.
4. **`A0_extract_evidence.R` still does not exist**, so the structured retrieval
   channel is inert. It remains the only channel that could reach a string sharing
   no text with its match.
5. **No alerting beyond cron's exit code.** The deploy exits 3 on sponsor failure;
   whether anyone sees that depends on `MAILTO`.
6. **`--round=2` in `C_assign` does not widen retrieval** — it computes `min_score`
   and never passes it, and `retrieve()` has no such parameter. Pre-existing,
   unrelated to this work, but it means round 2 behaves like round 1.
