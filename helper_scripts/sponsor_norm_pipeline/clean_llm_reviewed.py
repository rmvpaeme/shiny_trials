"""
clean_llm_reviewed.py
---------------------
Cleans sponsor_llm_reviewed.csv by:
  1. Deleting generic department aliases (no institution anchor)
  2. Deleting confirmed person-name aliases (investigators listed as sponsors)
  3. Fixing canonicals where university/hospital conflation occurred
  4. Title-casing ALL-CAPS institutional canonicals
  5. Deduplicating alias_clean entries (keeps last occurrence)

Run from repo root:
    python3 helper_scripts/sponsor_norm_pipeline/clean_llm_reviewed.py

Also fixes one entry in manual_sponsor_aliases.csv (Aarhus Univ Hospital).
"""

import csv, re
from collections import OrderedDict

LLM_FILE = 'config/sponsor_norm_pipeline/sponsor_llm_reviewed.csv'
MAN_FILE  = 'config/sponsor_norm_pipeline/manual_sponsor_aliases.csv'

# ─────────────────────────────────────────────────────────────────────────────
# 1.  ALIASES TO DELETE
# ─────────────────────────────────────────────────────────────────────────────

# Generic dept labels that map to themselves (no institution)
DELETE_GENERIC = {
    'abteilung fr anaesthesiologie und intensivmedizin',
    'abteilung fr herz-thorax-gef ansthesie intensivmedizin htg',
    'afsnit 360 gastroenheden',
    'brneafdelingen kolding',
    'clinic for nephrology',
    'dipartimento di medicina',
    'dipartimento di neurologia e psichiatria',
    'dipartimento di pediatria',
    'dipartimento di scienze cliniche e biologiche unito',
    'dipartimento di scienze della vita e biotecnologie delluniversit degli studi di ferrara',
    'hillbom matti oys/neurologian klinikka',
    'klinisk farmakologisk afdeling',
    'klinisk forskningsenhed medicinsk afdeling hmatologisk afsnit sygehus f',
    'medicinsk afdeling',
    'neurologisk afdeling',
    'neurologisk afdeling f',
    'onkologisk afdeling r and the unit for experimental chemotherapy',
    'ortopdkirurgisk afdeling',
    'servicio de anestesia-reanimacin',
    'servicio de anestesiologa y reanimacin',
    'servicio de nefrologia',
    'servicio de neurologa',
    'unidad de cirugia artroscpica',
    'unidad de investigacin en tuberculosis de barcelona',
    'unidad de investigacin en tuberculosis de barcelona uitb',
    'unidad de investigacin hospital universitario de canarias',
    'unidad de trasplantes y terapia celular del hospital general universitario',
    'unidad de trasplantes y terapia celular del hospital universitario central de asturias',
    'unidade de investigao em sade mental e psiquiatria do centro hospitalar e universitrio de coimbra',
    'univ clinic of dermatology',
    'univ klinik f ansthesie intensivmedizin und schmerztherapie',
    'university clinic of dermatology division of special and enviromental dermatology',
    'university clinic of nephrology and hypertension',
    'universittsklinik fr augenheilkunde und optometrie',
    'universittsklinik fr innere medizin iii klinische abteilung fr gastroenterologie',
    'universittsklinik fr kinder- und jugendheilkunde',
    'universittsklinik fr kinder-und jugendheilkunde',
    'universittsklinik fr klinische pharmakologie',
    'universittsklinik fr psychiatrie - spezialambulanz fr abhangigkeitserkrankungen',
    'universittsklinik fr psychiatrie und psychotherapie i',
}

# Person + dept aliases that map to person or person+dept canonical
DELETE_PERSONS = {
    'antonio cubillo gracin servicio de oncologa mdica - hospital md anderson',
    'dr angel chamorro snchez servicio de neurologa hospital clinic',
    'dr daniel lpez aguado servicio de otorrinolaringologa hospital universitario nsm',
    'dr jordi montero homs- unidad de neuromuscular- servicio de neurologa- hospital universitario de bellvitge',
    'dr jos gonzlez costello unidad de insuficiencia cardaca avanzada y trasplante cardaco',
    'dra antnia dalmau i llitjs del servicio de anestesia reanimacin y teraputica del dolor del hub-idibell',
    'dra carlota gudiol gonzlez servicio de enfermedades infecciosas hospital universitari de bellvitge',
    'dra irene halperin rabinovich servicio de endocrinologa hospital clnic',
    'erling bjerregaard pedersen medicinsk forskningsafsnit regionshospitalet holstebro',
    'fundacin investigacin y desarrollo rea cardiovascular dr javier segovia cubero',
    'miguel cervero jimnez servicio de medicina interna hospital universitari de bellvitge',
    'miquel pujol i rojo servicio de enfermedades infecciosas del hospital universitari de bellvitge',
    'professor christina eintrei institution of medical health section of anesthesiology and intensive care',
    'prim univ -prof dr gnter janetschek c/o universittsklinik fr urologie und andrologie',
    'rafael martinez sanz servicio de ciruga cardiovascular hospital universitario de canarias',
    # Confirmed pure person-name aliases
    'adelaida lamas ferreiro', 'alejandra garcia botella', 'alfredo tagarro garcia',
    'angel lanas', 'angela puente', 'antonio perez martinez',
    'carlos santos villar', 'carolina ibaez lopez', 'cesar augusto valero martinez',
    'cesar margarit ferri', 'concepcion moro serrano', 'david dalmau',
    'dr alejandro sousa escandn', 'dr enrico montanari', 'dr javier anido rubio',
    'dr joaquim bellmunt molins', 'dr paolo mora',
    'esther uriarte itzazelaia', 'fernado perez ruiz',
    'francisco borja barrachina larraza', 'francisco j blanco garca',
    'francisco jose morales ponce', 'hanna thorn', 'hannu kokki',
    'jesus gonzalez barboteo', 'joaquin portilla',
    'jos antonio serrano trenas', 'jose luis montero alvarez',
    'jose manuel garcia dominguez', 'juan ignacio arenas ruiz-tapiador',
    'juan macias sanchez', 'laura tarrats velasco',
    'luis fernndez- llebrez del rey', 'm angeles calderon',
    'manuel ngel gmez ros', 'mar espino hernandez', 'maria teresa parras maldonado',
    'miguel casares fernndez-alvs', 'mikel urretavizcaya sarachaga',
    'pedro acien alvarez', 'rafael garcia lopez',
    'ricardo moreno otero/maria chaparro sanchez', 'ricardo mouzo mirco',
    'xavier carbonell estrany',
}

DELETE_ALL = DELETE_GENERIC | DELETE_PERSONS

# ─────────────────────────────────────────────────────────────────────────────
# 2.  CANONICAL FIXES
# ─────────────────────────────────────────────────────────────────────────────

FIX_CANONICAL = {
    # Dept suffix → stripped institution
    'abteilung fr augenheilkunde akh linz': 'Kepler Universitätsklinikum',
    'deutsche cll-studiengruppe klinik fur innere medizin': 'Deutsche CLL-Studiengruppe',
    'dipartimento di medicina clinica e chirurgia - universit degli studi di napoli federico ii':
        'Università degli Studi di Napoli Federico II',
    'dipartimento di oncologia medica usl8': 'ASL 8 Arezzo',
    'dipartimento di oncologia-universita degli studi di torino': 'Università degli Studi di Torino',
    'dipartimento di oncologia-universit degli studi di torino': 'Università degli Studi di Torino',
    'dipartimento di pediatria universita di napoli federico ii':
        'Università degli Studi di Napoli Federico II',
    'ka rudolfstiftung - 2 medizinische abteilung': 'Krankenanstalt Rudolfstiftung',
    'klinik und poliklinik fuer strahlentherapie universitt erlangen-nrnberg':
        'Universitätsklinikum Erlangen',
    'nyremedicinsk afdeling aalborg sygehus': 'Aalborg University Hospital',
    'paracelsus medizinische universitt - universittsklinik fr ansthesie':
        'Paracelsus Medical University',
    'section for transfusion medicine capitol region blood bank':
        'Section for Transfusion Medicine, Capital Region Blood Bank, Copenhagen University Hospital',
    'section for transfusion medicines capital region blood bank copenhagen':
        'Section for Transfusion Medicine, Capital Region Blood Bank, Copenhagen University Hospital',
    'servicio de alergia hospital civil mlaga spain': 'Hospital Regional Universitario de Málaga',
    'servicio de gastroenterologa del hospital universitario mtua de terrassa':
        'Hospital Universitari Mútua Terrassa',
    'universittsklinik fr ansthesie - paracelsus medizinische universitt salzburg':
        'Paracelsus Medical University',
    'university clinic of nephrology and hypertension regional hospital holstebro':
        'Regionshospitalet Holstebro',
    'consejera de sanidad de la comunidad de madrid': 'Consejería de Sanidad de la Comunidad de Madrid',
    'service de sant des armes': 'Service de Santé des Armées',
    # University ↔ Hospital corrected
    'department of hepatology and gastroenterology aarhus university hospital':
        'Aarhus University Hospital',
    'department of pediatric oncology aarhus university hospital': 'Aarhus University Hospital',
    'department of respiratory diseases aarhus university hospital': 'Aarhus University Hospital',
    'dept oncology aarhus university hospital': 'Aarhus University Hospital',
    'lund university malm university hospital': 'Skåne University Hospital',
    'inst of ophtalmology lund university hospital': 'Skåne University Hospital',
    'vo anesthesia/icu lunds university hospital': 'Skåne University Hospital',
    'allergy unit department of oto-rhino-laryngology lund/malm u': 'Skåne University Hospital',
    'university hospital regensburg': 'Universitätsklinikum Regensburg',
    'university hospital of regensburg': 'Universitätsklinikum Regensburg',
    'university hospital magdeburg': 'Universitätsklinikum Magdeburg AöR',
    'research and development nottingham university hospital': 'Nottingham University Hospitals NHS Trust',
    'royal liverpool and broadgreen university hospital / university of liverpool':
        'Liverpool University Hospitals NHS Foundation Trust',
    'royal liverpool and broadgreen university hospitals nhs trust':
        'Liverpool University Hospitals NHS Foundation Trust',
    'royal liverpool broadgreen university hospitals trust / university of liverpool':
        'Liverpool University Hospitals NHS Foundation Trust',
    'aintree university hospital nhs foundation trust / university of liverpool':
        'Liverpool University Hospitals NHS Foundation Trust',
    'sandwell and west birmingham hospitals nhs trust / university of birmingham':
        'Sandwell and West Birmingham Hospitals NHS Trust',
    'university bonn': 'University of Bonn',
    'rheinische friedrich-wilhelms-university of bonn': 'University of Bonn',
    'rheinische friedrichs-wilhelms-universitt bonn': 'Rheinische Friedrich-Wilhelms-Universität Bonn',
    'university erlangen-nuremberg': 'Friedrich-Alexander-Universität Erlangen-Nürnberg',
    'university of regensburg': 'Universität Regensburg',
    'universitt regensburg': 'Universität Regensburg',
    'university of tuebingen': 'Eberhard-Karls-Universität Tübingen',
    'university tuebingen': 'Eberhard-Karls-Universität Tübingen',
    'university of lige': 'Université de Liège',
    'university of lige- dpt de mdecine gnrale': 'Université de Liège',
    'universitaet muenster': 'Westfälische Wilhelms-Universität Münster',
}

# ─────────────────────────────────────────────────────────────────────────────
# 3.  SMART TITLE-CASE
# ─────────────────────────────────────────────────────────────────────────────

KEEP_UPPER = {
    'IRCCS', 'IDIBAPS', 'IMIM', 'CNIC', 'CNIO', 'FINBA', 'FFIS', 'FIBHULP',
    'IFO', 'AIL', 'AISF', 'IELSG', 'NIBIT', 'GITMO', 'GOELAMS', 'GELA',
    'NOPHO', 'NVALT', 'EOC', 'VGR', 'AIO', 'IKF', 'APRO', 'ARTIC', 'IBSA',
    'REITHERA', 'TROPHOS', 'TETEC', 'EXONHIT', 'IGENEON',
    'NIDDK', 'NIH', 'NINDS', 'AP-HP', 'BMS', 'MSD', 'GSK', 'NHS', 'CHU',
    'CHRU', 'EBMT', 'EORTC', 'ABCSG', 'NKI', 'HUS', 'DKFZ',
    'GETECCU', 'GEIS', 'GELTAMO', 'GEICAM', 'GEMCAD', 'AGMT', 'SOGUG',
    'GETNE', 'GETH', 'TACL', 'USWM', 'SLL', 'TRASTEC', 'RIBAPHARM',
    'MOLOGEN', 'NERVIANO', 'NEWRON', 'KEDRION', 'BTI', 'BIONOMICS', 'AXON',
    'CETPARP', 'CREPATS', 'BOIRONSIH', 'BIOVOMED', 'AININCAR', 'IMETISA',
    'LAINCO', 'MIPHARM', 'ISDIN', 'IXALTIS', 'FISABIO', 'FIMABIS',
    'INSIGHTEC', 'INMUNAL', 'IMMUPHARMA', 'FARMIGEA', 'EXONHIT', 'FARMEX',
    'INDENA', 'INOTREM', 'ILTOO', 'LABCATAL', 'NUTRIALYS', 'NOVOSIS',
    'NOVELOS', 'EPIFARMA', 'ECUPHARMA', 'EURAND', 'GETECCU', 'GIULIANI',
    'GALENICA', 'FISM', 'DOBECURE', 'CITOSPIN', 'CBLAYAHUGET', 'CELLERIX',
    'COTHERIX', 'CPDS', 'IATEC', 'INCLIVA', 'ASST', 'AUSL', 'ASL', 'AOU',
    'USL', 'AB-BIOTICS', 'ADENOBIO', 'ADIENNE', 'ADRFARCP', 'PHARNEXT',
    'REITHERA', 'OM', 'ONCOSTELLAE', 'ONCOSUR', 'OPERA', 'PIAM', 'PILA',
    'HASCO', 'QUEST', 'SCIPHARM', 'SENDO', 'STELIC', 'STOP', 'TARGEON',
    'TETEC', 'THERAVECTYS', 'TOPIGEN', 'TRASTEC', 'TRB', 'UNI-PHARMA',
    'VACCIBODY', 'VAS', 'VERISFIELD', 'VISIOTACT', 'XOMA', 'ZAMBON',
    'ZIONEXA', 'MOLOGEN', 'NERVIANO', 'NEWRON',
}

LOWERCASE_WORDS = {
    'di', 'de', 'del', 'della', 'degli', 'delle', 'dello', 'dei',
    'e', 'per', 'la', 'le', 'il', 'i', 'lo', 'el', 'los', 'las',
    'y', 'en', 'da', 'do', 'das', 'dos', 'na',
    'van', 'der', 'den', 'het',
    'und', 'fur', 'fuer', 'für', 'et', 'au', 'aux', 'du', 'des',
    'and', 'of', 'for', 'the', 'in', 'a', 'an',
    'auf', 'am', 'an', 'im', 'zu', 'zum', 'zur',
}

INST_KWORDS = re.compile(
    r'(hospital|klinik|universit|pharma|biotech|research|foundation|'
    r'institu|centro|clinic|azienda|fondazione|associaz|grupo|'
    r'stiftung|gesellschaft|gmbh|srl|s\.r\.l\.|s\.p\.a\.|s\.a\.|'
    r'inc\.|llc|ltd|plc|nhs|sairaala|sjukhus|nemocnice|ziekenhuis|'
    r'network|group|committee|society|association|oncolog|'
    r'mumc|umc|nki|hus|ous|tays|irccs|agency|'
    r'\d)', re.I
)


def smart_title_case(s):
    words = s.split()
    result = []
    for i, w in enumerate(words):
        j = 0
        prefix = ''
        while j < len(w) and not w[j].isalpha() and not w[j].isdigit():
            prefix += w[j]; j += 1
        core = w[j:]
        suffix = ''
        while core and not core[-1].isalpha() and not core[-1].isdigit():
            suffix = core[-1] + suffix; core = core[:-1]
        if core.upper() in KEEP_UPPER:
            result.append(prefix + core.upper() + suffix)
        elif core.lower() in LOWERCASE_WORDS and i > 0:
            result.append(prefix + core.lower() + suffix)
        elif '.' in core and all(c.isalpha() or c == '.' for c in core):
            result.append(prefix + core[0].upper() + core[1:].lower() + suffix)
        else:
            result.append(prefix + core.capitalize() + suffix)
    return ' '.join(result)


def is_allcaps_institutional(sc):
    alpha = re.sub(r'[^a-zA-Z]', '', sc)
    return (len(alpha) > 8 and alpha == alpha.upper() and
            INST_KWORDS.search(sc))


# ─────────────────────────────────────────────────────────────────────────────
# APPLY
# ─────────────────────────────────────────────────────────────────────────────

PERSON_AC_PATTERNS = re.compile(
    r'^(dr\.|dra\.|prof\.|dott\.ssa|dott\.|sr\.|sra\.|prof\s|dr\s[a-z]|dra\s[a-z])',
    re.I
)


def run():
    with open(LLM_FILE, encoding='utf-8') as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames
        rows = list(reader)

    kept = []
    stats = dict(deleted_generic=0, deleted_person=0, fixed=0, title_cased=0)

    for r in rows:
        ac = r['alias_clean']
        sc = r['sponsor_clean']

        if ac in DELETE_ALL:
            stats['deleted_generic'] += 1
            continue
        if PERSON_AC_PATTERNS.match(ac) and not INST_KWORDS.search(sc):
            stats['deleted_person'] += 1
            continue

        if ac in FIX_CANONICAL:
            r['sponsor_clean'] = FIX_CANONICAL[ac]
            stats['fixed'] += 1

        if is_allcaps_institutional(r['sponsor_clean']):
            new_sc = smart_title_case(r['sponsor_clean'])
            if new_sc != r['sponsor_clean']:
                r['sponsor_clean'] = new_sc
                stats['title_cased'] += 1

        kept.append(r)

    seen = OrderedDict()
    for r in kept:
        seen[r['alias_clean']] = r
    deduped = list(seen.values())

    with open(LLM_FILE, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(deduped)

    # Fix manual_sponsor_aliases.csv
    with open(MAN_FILE, encoding='utf-8') as f:
        reader = csv.DictReader(f)
        man_fields = reader.fieldnames
        man_rows = list(reader)
    for r in man_rows:
        if r['alias_clean'] == 'department of hepatology and gastroenterology aarhus university hospital':
            r['sponsor_clean'] = 'Aarhus University Hospital'
    with open(MAN_FILE, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=man_fields)
        writer.writeheader()
        writer.writerows(man_rows)

    print(f"Stats: {stats}")
    print(f"Final llm_reviewed entries: {len(deduped)}")


if __name__ == '__main__':
    run()
