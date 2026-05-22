"""
clean_substance_reviewed.py
---------------------------
Post-processes substance_alias_index.csv after build_substance_index.R to
remove entries that should not appear as match targets.

Run from repo root AFTER build_substance_index.R:
    python3 helper_scripts/substance_norm_pipeline/clean_substance_reviewed.py

Actions applied to config/substance_norm_pipeline/substance_alias_index.csv:

  DELETE_SUBSTANCE  — remove rows where substance_clean is in this set.
                      Used for non-therapeutic substances that crept into
                      the generated index as match targets. These would
                      otherwise be returned as accepted matches even though
                      they are excipients, formulation descriptors, or
                      mechanism-class labels.

  DELETE_ALIAS      — remove rows where alias_clean is in this set.
                      Used for aliases that are standalone formulation
                      descriptors with no drug-name component (e.g.
                      pure route/form strings from EPAR product names).

The script is idempotent and prints a run summary.
"""

import csv
import re
from collections import OrderedDict

INDEX_FILE = 'config/substance_norm_pipeline/substance_alias_index.csv'

# ─────────────────────────────────────────────────────────────────────────────
# 1.  SUBSTANCE_CLEAN VALUES TO DELETE
#     Entries where the match target itself should never be returned as
#     an active substance (pure excipients with no therapeutic use,
#     mechanism-class descriptors, overly generic labels).
# ─────────────────────────────────────────────────────────────────────────────

DELETE_SUBSTANCE = {
    # Pure excipients — no therapeutic use as primary drug substance
    'powdered cellulose',
    'croscarmellose sodium',
    'crospovidone',
    'povidone',
    'hydroxypropyl cellulose',
    'stearic acid',
    'silicon dioxide',
    'titanium dioxide',
    'carbomer',
    'carrageenan',
    'poloxamer',
    # Mechanism-class labels — too generic to be a trial substance
    'immunotherapy',
    'chemotherapy',
    'targeted therapy',
    'monoclonal antibody',
    'bispecific antibody',
    'recombinant protein',
    # Trial/blinding phrases
    'study drug',
    'investigational product',
    'test product',
    'vehicle control',
}

# ─────────────────────────────────────────────────────────────────────────────
# 2.  ALIAS_CLEAN VALUES TO DELETE
#     Standalone formulation/route strings that should not act as aliases
#     for any substance. Distinct from negative_aliases.csv (which rejects
#     raw input strings at normalisation time); this removes them from the
#     index so they cannot be fuzzy-matched as alias targets either.
# ─────────────────────────────────────────────────────────────────────────────

DELETE_ALIAS = {
    # Formulation/route-only strings from EPAR product names
    'for injection',
    'for infusion',
    'for oral use',
    'for intravenous use',
    'solution for injection',
    'solution for infusion',
    'concentrate for solution for infusion',
    'powder for solution for injection',
    'suspension for injection',
    'powder for oral suspension',
    'film-coated tablets',
    'modified-release capsules',
    'prolonged-release tablets',
    # Common English words that appear as ChEMBL synonyms via abbreviations
    # and cause spurious first-token matches from longer strings.
    # 'same'    = SAMe (S-adenosylmethionine) abbreviation → ademetionine
    # 'balance' = appears in ChEMBL as synonym for isoxaflutole (likely error)
    'same',
    'balance',
    # Isotope-label notations that are not drug names on their own
    # '13c6' = carbon-13 labeling suffix → cosfroviximab (ChEMBL data error)
    # '12c'  = carbon-12 notation → velaresol (ChEMBL internal code collision)
    '13c6',
    '12c',
    # 'fluval' → fluoxetine is a ChEMBL data error; Fluval is an influenza vaccine brand.
    'fluval',
}

# ─────────────────────────────────────────────────────────────────────────────
# APPLY
# ─────────────────────────────────────────────────────────────────────────────

def run():
    with open(INDEX_FILE, encoding='utf-8', newline='') as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        rows = list(reader)

    kept = []
    stats = dict(deleted_substance=0, deleted_alias=0)

    for r in rows:
        sc = r['substance_clean'].strip().lower()
        ac = r['alias_clean'].strip().lower()

        if sc in DELETE_SUBSTANCE:
            stats['deleted_substance'] += 1
            continue
        if ac in DELETE_ALIAS:
            stats['deleted_alias'] += 1
            continue

        kept.append(r)

    with open(INDEX_FILE, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(kept)

    print(f"Stats: deleted_substance={stats['deleted_substance']}  "
          f"deleted_alias={stats['deleted_alias']}")
    print(f"substance_alias_index.csv: {len(rows)} → {len(kept)} entries "
          f"({len(rows) - len(kept)} removed)")


if __name__ == '__main__':
    run()
