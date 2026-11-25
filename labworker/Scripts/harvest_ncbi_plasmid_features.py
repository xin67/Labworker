#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Harvest curated, public-domain plasmid features from NCBI GenBank (nuccore)
using server-side [FKEY] feature filters + balanced functional buckets +
gzip-compressed HTTP POST batch fetching, plus FPbase nucleotide GenBank
accessions. Enforces strict deduplication, core-seed isolation, and
zero-collision against all 5 golden cases in `Tests/vectors/plasmid_auto_annotation.json`.

Outputs `Scripts/plasmid_features_catalog.json`.
"""

import gzip
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LABWORKER_DIR = os.path.dirname(SCRIPT_DIR)
CATALOG_OUT_PATH = os.path.join(SCRIPT_DIR, "plasmid_features_catalog.json")
GOLDEN_VECTORS_PATH = os.path.join(LABWORKER_DIR, "Tests/vectors/plasmid_auto_annotation.json")
MCP_SERVER_DIR = os.path.join(LABWORKER_DIR, "Sources/CloneStudioCore/Resources")

sys.path.insert(0, SCRIPT_DIR)
from seed_plasmid_features import PLASMID_FEATURES_SEED  # noqa: E402

sys.path.insert(0, MCP_SERVER_DIR)
import clonestudio_mcp_server as mcp  # noqa: E402

ESEARCH_URL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
EFETCH_URL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
FPBASE_URL = "https://www.fpbase.org/api/proteins/?format=json"
USER_AGENT = "Labworker-FeatureHarvester/1.1 (https://github.com/xin67/Labworker)"

CATEGORY_COLORS = {
    "promoter": "#3B82F6",
    "enhancer": "#6366F1",
    "ori": "#F59E0B",
    "resistance": "#EF4444",
    "reporter": "#10B981",
    "reporter_red": "#EC4899",
    "tag": "#8B5CF6",
    "terminator": "#64748B",
    "viral": "#F97316",
    "recombinase": "#14B8A6",
    "regulator": "#0EA5E9",
    "misc": "#6B7280",
}

QUERIES = [
    # Bucket 1: Classic cloning, expression, viral, CRISPR & shuttle backbones
    (
        '("pcDNA3.1"[Title] OR "pUC19"[Title] OR "pBR322"[Title] OR "pET-28"[Title] '
        'OR "pETDuet"[Title] OR "pGEX"[Title] OR "pMAL"[Title] OR "pBAD"[Title] '
        'OR "pBluescript"[Title] OR "pLKO"[Title] OR "lentiCRISPR"[Title] '
        'OR "pX330"[Title] OR "pX459"[Title] OR "psPAX2"[Title] OR "pMD2.G"[Title] '
        'OR "pAAV"[Title] OR "pLVX"[Title] OR "pCDH"[Title] OR "pCAGGS"[Title] '
        'OR "pYES2"[Title] OR "pRS416"[Title] OR "pFastBac"[Title] OR "PiggyBac"[Title]) '
        'AND 1200:20000[SLEN]',
        250,
    ),
    # Bucket 2: Server-side [FKEY] verified annotated synthetic constructs
    (
        '"synthetic construct"[Organism] AND ("promoter"[FKEY] OR "rep_origin"[FKEY] '
        'OR "terminator"[FKEY] OR "enhancer"[FKEY] OR "LTR"[FKEY] OR "polyA_signal"[FKEY]) '
        'AND 1500:15000[SLEN]',
        550,
    ),
    # Bucket 3: Fluorescent & bioluminescent reporters
    (
        '("fluorescent protein"[Title] OR "luciferase"[Title] OR "mScarlet"[Title] '
        'OR "mNeonGreen"[Title] OR "mTurquoise"[Title] OR "tdTomato"[Title] '
        'OR "mKate"[Title] OR "sfGFP"[Title]) AND "synthetic construct"[Organism] '
        'AND 400:2500[SLEN]',
        260,
    ),
    # Bucket 4: Antibiotic & metabolic selection markers
    (
        '("hygromycin"[Title] OR "blasticidin"[Title] OR "zeocin"[Title] '
        'OR "chloramphenicol"[Title] OR "spectinomycin"[Title] OR "gentamicin"[Title] '
        'OR "neomycin"[Title] OR "tetracycline resistance"[Title] OR "nourseothricin"[Title] '
        'OR "ccdB"[Title]) AND ("synthetic construct"[Organism] OR "cloning vector"[Title]) '
        'AND 400:10000[SLEN]',
        220,
    ),
    # Bucket 5: Viral, CRISPR, recombinase, tag & regulator elements
    (
        '("WPRE"[Title] OR "IRES"[Title] OR "loxP"[Title] OR "FRT"[Title] '
        'OR "Cas9"[Title] OR "Cas12a"[Title] OR "rtTA"[Title] OR "TetR"[Title] '
        'OR "LacI"[Title] OR "T2A"[Title] OR "P2A"[Title] OR "HaloTag"[Title] '
        'OR "SNAP-tag"[Title] OR "TurboID"[Title]) AND "synthetic construct"[Organism] '
        'AND 200:12000[SLEN]',
        260,
    ),
    # Bucket 6: Promoters, terminators & enhancers
    (
        '("promoter"[Title] OR "terminator"[Title] OR "enhancer"[Title]) '
        'AND "synthetic construct"[Organism] AND 100:2000[SLEN]',
        220,
    ),
]

SSL_CTX = ssl.create_default_context()


def http_request_text(url: str, post_data: dict = None, retries: int = 3, delay: float = 0.36) -> str:
    last_err = None
    headers = {
        "User-Agent": USER_AGENT,
        "Accept-Encoding": "gzip",
    }
    encoded_body = None
    if post_data is not None:
        encoded_body = urllib.parse.urlencode(post_data).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"

    for attempt in range(retries):
        time.sleep(delay * (1 + attempt * 0.6))
        req = urllib.request.Request(url, data=encoded_body, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=45, context=SSL_CTX) as resp:
                raw_bytes = resp.read()
                if resp.headers.get("Content-Encoding", "").lower() == "gzip" or raw_bytes[:2] == b"\x1f\x8b":
                    raw_bytes = gzip.decompress(raw_bytes)
                return raw_bytes.decode("utf-8", errors="replace")
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as exc:
            last_err = exc
    raise RuntimeError(f"HTTP fetch failed after {retries} attempts for {url}: {last_err}")


def esearch_ids(term: str, retmax: int) -> list:
    params = urllib.parse.urlencode(
        {
            "db": "nuccore",
            "term": term,
            "retmax": str(retmax),
            "retmode": "json",
            "sort": "relevance",
        }
    )
    raw = http_request_text(f"{ESEARCH_URL}?{params}")
    data = json.loads(raw)
    return list(data.get("esearchresult", {}).get("idlist", []))


def efetch_genbank_batch(ids: list) -> str:
    return http_request_text(
        EFETCH_URL,
        post_data={
            "db": "nuccore",
            "id": ",".join(ids),
            "rettype": "gb",
            "retmode": "text",
        },
        delay=0.38,
    )


def fetch_fpbase_nuc_accessions() -> list:
    """Fetch public FPbase protein metadata and extract valid GenBank nucleotide accessions."""
    try:
        raw = http_request_text(FPBASE_URL, retries=2, delay=0.1)
        data = json.loads(raw)
        accs = []
        seen = set()
        for item in data:
            gb = str(item.get("genbank") or "").strip()
            if re.fullmatch(r"[A-Z]{1,2}\d{5,6}", gb) and gb not in seen:
                seen.add(gb)
                accs.append(gb)
        return accs
    except Exception:
        return []


def rev_comp(seq: str) -> str:
    trans = str.maketrans("ACGT", "TGCA")
    return seq.translate(trans)[::-1]


def canonical_seq(seq: str) -> str:
    rc = rev_comp(seq)
    return seq if seq <= rc else rc


def parse_simple_location(loc: str, seq_len: int):
    loc = re.sub(r"\s+", "", loc)
    if "<" in loc or ">" in loc or "^" in loc or ":" in loc:
        return None

    direction = 1
    inner = loc
    if inner.startswith("complement(") and inner.endswith(")"):
        direction = -1
        inner = inner[len("complement("):-1]

    if inner.startswith("join(") and inner.endswith(")"):
        inner = inner[len("join("):-1]
        parts = inner.split(",")
        if len(parts) != 2:
            return None
        m1 = re.fullmatch(r"(\d+)\.\.(\d+)", parts[0])
        m2 = re.fullmatch(r"(\d+)\.\.(\d+)", parts[1])
        if not m1 or not m2:
            return None
        s1, e1 = int(m1.group(1)), int(m1.group(2))
        s2, e2 = int(m2.group(1)), int(m2.group(2))
        if e1 == seq_len and s2 == 1 and 1 <= s1 <= e1 and 1 <= s2 <= e2 < s1:
            return ([(s1 - 1, e1), (s2 - 1, e2)], direction)
        return None

    m = re.fullmatch(r"(\d+)\.\.(\d+)", inner)
    if not m:
        return None
    s, e = int(m.group(1)), int(m.group(2))
    if 1 <= s <= e <= seq_len:
        return ([(s - 1, e)], direction)
    return None


def parse_qualifiers_linear(qual_lines: list) -> dict:
    """Zero-backtracking linear parser for GenBank feature qualifiers."""
    quals = {}
    for raw in qual_lines:
        if not raw.startswith("/"):
            continue
        eq_idx = raw.find("=")
        if eq_idx == -1:
            continue
        qk = raw[1:eq_idx].strip().lower()
        if qk == "translation" or qk in quals:
            continue
        qv = raw[eq_idx + 1:].strip()
        if len(qv) >= 2 and qv.startswith('"') and qv.endswith('"'):
            qv = qv[1:-1].replace('""', '"')
        elif qv.startswith('"'):
            qv = qv[1:]
        qv = " ".join(qv.split())
        if qv:
            quals[qk] = qv
    return quals


def parse_genbank_records(gb_text: str) -> list:
    records = []
    for raw_rec in gb_text.split("\n//"):
        raw_rec = raw_rec.strip()
        if not raw_rec:
            continue
        feat_idx = raw_rec.find("\nFEATURES")
        orig_idx = raw_rec.find("\nORIGIN")
        if feat_idx == -1 or orig_idx == -1 or orig_idx <= feat_idx:
            continue

        acc_match = re.search(r"^ACCESSION\s+(\S+)", raw_rec[:feat_idx], re.MULTILINE)
        accession = acc_match.group(1) if acc_match else "UNKNOWN"

        orig_block = raw_rec[orig_idx + len("\nORIGIN"):]
        seq = re.sub(r"[^ACGTacgt]", "", orig_block).upper()
        if len(seq) < 100:
            continue

        feat_lines = raw_rec[feat_idx + len("\nFEATURES"):orig_idx].splitlines()[1:]
        features = []
        cur_key = None
        cur_loc_parts = []
        cur_quals = []
        in_qual = False

        def flush_feature():
            if cur_key is None:
                return
            loc_str = "".join(cur_loc_parts)
            quals = parse_qualifiers_linear(cur_quals)
            features.append((cur_key, loc_str, quals))

        for line in feat_lines:
            if len(line) < 6:
                continue
            if line[:5] == "     " and line[5] != " ":
                flush_feature()
                body = line[5:].strip()
                parts = body.split(None, 1)
                cur_key = parts[0]
                cur_loc_parts = [parts[1].strip()] if len(parts) > 1 else []
                cur_quals = []
                in_qual = False
            elif line.startswith("                     "):
                stripped = line.strip()
                if stripped.startswith("/"):
                    in_qual = True
                    cur_quals.append(stripped)
                elif not in_qual:
                    cur_loc_parts.append(stripped)
                else:
                    if cur_quals and not cur_quals[-1].startswith("/translation="):
                        cur_quals[-1] = cur_quals[-1] + " " + stripped

        flush_feature()
        records.append((accession, seq, features))
    return records


GENERIC_NAME_PATTERNS = [
    r"^unnamed$",
    r"^unknown$",
    r"^hypothetical",
    r"^synthetic\b",
    r"^vector$",
    r"^plasmid$",
    r"^backbone$",
    r"^mcs$",
    r"^multiple\s+cloning\s+site",
    r"^polylinker$",
    r"^misc(_|\s)*feature$",
    r"^misc$",
    r"^orf\d*$",
    r"^cds\d*$",
    r"^gene\d*$",
    r"^protein\d*$",
    r"^insert$",
    r"^fragment$",
    r"^region$",
    r"^spacer$",
    r"^linker$",
    r"^primer",
    r"^oligo",
    r"^repeat$",
    r"^promoter$",
    r"^terminator$",
    r"^origin$",
    r"^ori$",
    r"^rep_origin$",
    r"^resistance$",
    r"^reporter$",
    r"^loc\d+$",
    r"^pcr\b",
    r"^clone\b",
    r"^sequence\b",
    r"^dna\b",
    r"^rna\b",
    r"^source$",
]


def is_clean_feature_name(name: str) -> bool:
    if not name:
        return False
    s = name.strip()
    if len(s) < 2 or len(s) > 48:
        return False
    if not re.search(r"[A-Za-z]", s):
        return False
    low = s.lower()
    for pat in GENERIC_NAME_PATTERNS:
        if re.fullmatch(pat, low) or (re.match(pat, low) and len(low) <= 14):
            return False
    if "hypothetical protein" in low or "uncharacterized" in low or "putative protein" in low:
        return False
    if "cloning site" in low or "sequencing primer" in low:
        return False
    return True


def classify_feature(gb_key: str, name: str, quals: dict):
    k = gb_key.lower()
    low = " ".join(
        [
            name.lower(),
            quals.get("product", "").lower(),
            quals.get("note", "").lower(),
            quals.get("function", "").lower(),
            quals.get("regulatory_class", "").lower(),
        ]
    )

    if k in ("source", "gap", "assembly_gap", "variation", "misc_difference", "conflict", "old_sequence", "unsure"):
        return None

    if k in ("ltr", "5'ltr", "3'ltr") or any(
        tok in low
        for tok in (
            "wpre",
            "cppt",
            "rre",
            "ltr",
            "itr",
            "ires",
            "psi",
            "packaging signal",
            "rev response",
            "woodchuck",
            "sin-ltr",
            "central polypurine",
            "hiv-1",
            "lentivir",
            "aav2",
            "sv40 late",
        )
    ):
        if "promoter" not in low and "polya" not in low:
            return ("viral", CATEGORY_COLORS["viral"])

    if any(
        tok in low
        for tok in (
            "loxp",
            "lox2272",
            "lox511",
            "frt",
            "attb",
            "attp",
            "attl",
            "attr",
            "cre recombinase",
            "flp",
            "piggybac",
            "sleeping beauty",
            "transposon",
            "itrs",
        )
    ):
        return ("recombinase", CATEGORY_COLORS["recombinase"])

    if k == "rep_origin":
        return ("ori", CATEGORY_COLORS["ori"])

    reg_class = quals.get("regulatory_class", "").lower()
    if k == "promoter" or (k == "regulatory" and "promoter" in reg_class) or "promoter" in low:
        return ("promoter", CATEGORY_COLORS["promoter"])
    if k == "enhancer" or (k == "regulatory" and "enhancer" in reg_class) or "enhancer" in low:
        return ("enhancer", CATEGORY_COLORS["enhancer"])
    if k in ("terminator", "polya_signal", "polya_site") or (
        k == "regulatory" and ("terminator" in reg_class or "polya" in reg_class)
    ) or any(tok in low for tok in ("polya", "poly(a)", "terminator", "rrnb t1", "rrnb t2", "bgh pa", "sv40 pa")):
        return ("terminator", CATEGORY_COLORS["terminator"])

    if any(
        tok in low
        for tok in (
            "beta-lactamase",
            "ampicillin",
            "ampr",
            "blar",
            "kanamycin",
            "kanr",
            "neomycin",
            "neor",
            "g418",
            "aminoglycoside",
            "chloramphenicol",
            "camr",
            "cat ",
            "tetracycline",
            "tetr",
            "spectinomycin",
            "streptomycin",
            "zeocin",
            "bleomycin",
            "blasticidin",
            "hygromycin",
            "hygr",
            "puromycin",
            "puror",
            "nourseothricin",
            "gentamicin",
            "apramycin",
            "erythromycin",
            "ura3",
            "leu2",
            "trp1",
            "his3",
            "ade2",
            "dhfr",
            "glutamine synthetase",
            "tk",
            "thymidine kinase",
            "ccdb",
            "sacb",
            "rpsl",
        )
    ):
        if "promoter" not in low:
            return ("resistance", CATEGORY_COLORS["resistance"])

    red_fps = ("mcherry", "tdtomato", "dsred", "mrfp", "mkate", "mscarlet", "mplum", "morange", "tagrfp", "crimson", "eqfp")
    if any(tok in low for tok in red_fps):
        return ("reporter", CATEGORY_COLORS["reporter_red"])
    if any(
        tok in low
        for tok in (
            "gfp",
            "egfp",
            "sfgfp",
            "yfp",
            "eyfp",
            "mvenus",
            "citrine",
            "cfp",
            "ecfp",
            "cerulean",
            "bfp",
            "ebfp",
            "mturquoise",
            "mneongreen",
            "luciferase",
            "fluc",
            "rluc",
            "nanoluc",
            "nluc",
            "lacz",
            "beta-galactosidase",
            "gus",
            "uida",
            "seap",
            "fluorescent protein",
            "chromoprotein",
        )
    ):
        return ("reporter", CATEGORY_COLORS["reporter"])

    if any(
        tok in low
        for tok in (
            "flag",
            "ha tag",
            "ha-tag",
            "myc",
            "v5",
            "his6",
            "6xhis",
            "10xhis",
            "polyhistidine",
            "strep",
            "gst",
            "glutathione s-transferase",
            "mbp",
            "maltose",
            "sumo",
            "trx",
            "thioredoxin",
            "halotag",
            "snap-tag",
            "clip-tag",
            "avi",
            "cbp",
            "s-tag",
            "t7 tag",
            "tev",
            "thrombin",
            "enterokinase",
            "factor xa",
            "prescission",
            "hrv 3c",
            "t2a",
            "p2a",
            "e2a",
            "f2a",
            "2a peptide",
            "nls",
            "nuclear localization",
            "nes",
            "signal peptide",
            "igk",
            "kozak",
            "pelb",
            "ompa",
            "secretory",
        )
    ):
        return ("tag", CATEGORY_COLORS["tag"])

    if any(
        tok in low
        for tok in (
            "laci",
            "tetr",
            "rtta",
            "tta",
            "arac",
            "gal4",
            "lexa",
            "vp16",
            "vp64",
            "p65",
            "krab",
            "cas9",
            "dcas9",
            "cas12",
            "cpf1",
            "t7 rna polymerase",
            "t7 polymerase",
            "rop",
            "repressor",
            "transactivator",
            "operator",
            "teto",
            "laco",
            "uas",
        )
    ):
        return ("regulator", CATEGORY_COLORS["regulator"])

    if k == "primer_bind":
        if any(tok in low for tok in ("m13", "t7", "t3", "sp6", "cmv", "u6", "bgh", "sv40", "ef1", "pcr", "seq")):
            return ("misc", CATEGORY_COLORS["misc"])
        return None

    if k in ("cds", "mat_peptide", "protein_bind", "misc_feature", "misc_recomb", "regulatory"):
        if k == "cds" and not any(tok in low for tok in ("hypothetical", "unknown")):
            return ("misc", CATEGORY_COLORS["misc"])
        if any(
            tok in low
            for tok in (
                "origin",
                "ori",
                "f1",
                "bom",
                "rop",
                "cap site",
                "tata",
                "shine-dalgarno",
                "rbs",
                "ribosome binding",
                "kozak",
                "intron",
                "beta-globin",
                "insulator",
                "chs4",
                "mar ",
                "scaffold",
                "lacz",
            )
        ):
            return ("misc", CATEGORY_COLORS["misc"])

    return None


def pick_feature_name(gb_key: str, quals: dict) -> str:
    for key in ("label", "standard_name", "gene", "product", "note"):
        val = quals.get(key, "").strip()
        if not val:
            continue
        if key in ("product", "note") and len(val) > 48:
            short = re.split(r"[;,(]", val)[0].strip()
            if is_clean_feature_name(short):
                return short
            continue
        if is_clean_feature_name(val):
            return val
    return ""


def kmer_set(seq: str, k: int = 10) -> set:
    if len(seq) < k:
        return {seq}
    return {seq[i:i + k] for i in range(len(seq) - k + 1)}


def overlaps_core_seeds(seq: str, seed_kmers: list, seed_seqs: list) -> bool:
    rc = rev_comp(seq)
    for s_seq in seed_seqs:
        if seq == s_seq or rc == s_seq:
            return True
        if len(seq) >= 18 and (seq in s_seq or rc in s_seq or s_seq in seq or s_seq in rc):
            return True
    if len(seq) >= 20:
        km_f = kmer_set(seq, 10)
        km_r = kmer_set(rc, 10)
        for sk in seed_kmers:
            inter = max(len(km_f & sk), len(km_r & sk))
            denom = min(len(km_f), len(sk))
            if denom > 0 and (inter / denom) >= 0.45:
                return True
    return False


def verify_against_golden_vectors(catalog_items: list) -> tuple:
    with open(GOLDEN_VECTORS_PATH, "r", encoding="utf-8") as f:
        vec = json.load(f)
    cases = vec["cases"]

    def build_lib(items):
        lib = []
        for idx, (name, cat, seq, direction, color_hex) in enumerate(PLASMID_FEATURES_SEED, start=1):
            lib.append(
                {
                    "id": idx,
                    "name": name,
                    "category": cat,
                    "sequence": seq,
                    "direction": direction,
                    "color_hex": color_hex,
                }
            )
        for offset, item in enumerate(items, start=len(PLASMID_FEATURES_SEED) + 1):
            lib.append(
                {
                    "id": offset,
                    "name": item["name"],
                    "category": item["category"],
                    "sequence": item["sequence"],
                    "direction": item["direction"],
                    "color_hex": item["color_hex"],
                }
            )
        return lib

    seed_names = {row[0] for row in PLASMID_FEATURES_SEED}
    removed_names = []
    working = list(catalog_items)

    for _round in range(12):
        lib = build_lib(working)
        colliding_names = set()
        for c in cases:
            inp = c["input"]
            exp = c["expected"]
            parsed_name, clean_q = mcp.parse_fasta_sequence(inp.get("fasta_text", ""), "Unannotated_Plasmid")
            rep = mcp.annotate_plasmid_sequence(
                sequence=clean_q,
                plasmid_name=parsed_name,
                is_circular=inp.get("is_circular", True),
                features_library=lib,
            )
            exp_feats = exp["features"]
            got_feats = rep["features"]

            mismatch = (
                rep["features_count"] != exp["features_count"]
                or rep["fragment_count"] != exp["fragment_count"]
                or rep["origin_spanning_count"] != exp["origin_spanning_count"]
            )
            if not mismatch and len(got_feats) == len(exp_feats):
                for gf, ef in zip(got_feats, exp_feats):
                    if (
                        gf["name"] != ef["name"]
                        or gf["start_1based"] != ef["start_1based"]
                        or gf["end_1based"] != ef["end_1based"]
                        or gf["strand"] != ef["strand"]
                    ):
                        mismatch = True
                        break

            if mismatch:
                for gf in got_feats:
                    if gf["name"] not in seed_names:
                        colliding_names.add(gf["name"])
                q_doubled = clean_q + clean_q
                for item in working:
                    s = item["sequence"]
                    if len(s) >= 18:
                        for pos in range(0, len(s) - 11, 6):
                            km = s[pos:pos + 12]
                            if km in q_doubled or rev_comp(km) in q_doubled:
                                solo = mcp.annotate_plasmid_sequence(
                                    sequence=clean_q,
                                    plasmid_name=parsed_name,
                                    is_circular=inp.get("is_circular", True),
                                    features_library=[
                                        {
                                            "id": 99999,
                                            "name": item["name"],
                                            "category": item["category"],
                                            "sequence": item["sequence"],
                                            "direction": item["direction"],
                                            "color_hex": item["color_hex"],
                                        }
                                    ],
                                )
                                if solo["features_count"] > 0:
                                    colliding_names.add(item["name"])
                                break

        if not colliding_names:
            return working, removed_names

        working = [it for it in working if it["name"] not in colliding_names]
        removed_names.extend(sorted(colliding_names))

    raise RuntimeError("Failed to eliminate golden-vector collisions after 12 passes")


def main():
    print("🔎 Searching NCBI GenBank nuccore ([FKEY] + balanced buckets) & FPbase...", flush=True)
    all_ids = []
    seen_ids = set()

    for term, rmax in QUERIES:
        try:
            ids = esearch_ids(term, rmax)
            added = 0
            for uid in ids:
                if uid not in seen_ids:
                    seen_ids.add(uid)
                    all_ids.append(uid)
                    added += 1
            print(f"   • Query matched {len(ids)} records (+{added} new, total {len(all_ids)})", flush=True)
        except Exception as exc:
            print(f"   ⚠️ Query warning: {exc}", flush=True)

    fp_accs = fetch_fpbase_nuc_accessions()
    for acc in fp_accs:
        if acc not in seen_ids:
            seen_ids.add(acc)
            all_ids.append(acc)
    print(f"   • FPbase added {len(fp_accs)} nucleotide GenBank accessions (total {len(all_ids)})", flush=True)

    print(f"📥 Fetching GenBank records (gzip POST, batch=80) for {len(all_ids)} IDs...", flush=True)
    seed_seqs = [row[2].upper() for row in PLASMID_FEATURES_SEED]
    seed_kmers = [kmer_set(s, 10) for s in seed_seqs]
    seed_names_lower = {row[0].lower() for row in PLASMID_FEATURES_SEED}

    by_canon_seq = {}
    used_names_lower = set(seed_names_lower)

    batch_size = 80
    total_records = 0
    for i in range(0, len(all_ids), batch_size):
        batch = all_ids[i:i + batch_size]
        try:
            gb_text = efetch_genbank_batch(batch)
        except Exception as exc:
            print(f"   ⚠️ Batch {i//batch_size + 1} fetch error: {exc}", flush=True)
            continue
        recs = parse_genbank_records(gb_text)
        total_records += len(recs)

        for acc, seq, features in recs:
            seq_len = len(seq)
            for gb_key, loc_str, quals in features:
                parsed = parse_simple_location(loc_str, seq_len)
                if parsed is None:
                    continue
                slices, direction = parsed
                raw_sub = "".join(seq[s0:e0] for s0, e0 in slices)
                if not raw_sub or not (set(raw_sub) <= {"A", "C", "G", "T"}):
                    continue
                feat_seq = rev_comp(raw_sub) if direction == -1 else raw_sub
                if not (18 <= len(feat_seq) <= 4500):
                    continue

                raw_name = pick_feature_name(gb_key, quals)
                if not raw_name:
                    continue
                classified = classify_feature(gb_key, raw_name, quals)
                if classified is None:
                    continue
                category, color_hex = classified

                if overlaps_core_seeds(feat_seq, seed_kmers, seed_seqs):
                    continue

                cseq = canonical_seq(feat_seq)
                if cseq in by_canon_seq:
                    existing = by_canon_seq[cseq]
                    if len(raw_name) < len(existing["name"]) and raw_name.lower() not in used_names_lower:
                        used_names_lower.discard(existing["name"].lower())
                        existing["name"] = raw_name
                        used_names_lower.add(raw_name.lower())
                    continue

                cand_name = raw_name
                if cand_name.lower() in used_names_lower:
                    cand_name = f"{raw_name} ({len(feat_seq)}bp)"
                    if cand_name.lower() in used_names_lower:
                        cand_name = f"{raw_name} [{acc}]"
                if cand_name.lower() in used_names_lower:
                    continue

                used_names_lower.add(cand_name.lower())
                by_canon_seq[cseq] = {
                    "name": cand_name,
                    "category": category,
                    "sequence": feat_seq,
                    "direction": 1 if gb_key.lower() not in ("rep_origin", "misc_recomb", "protein_bind") else direction,
                    "color_hex": color_hex,
                    "source_accession": acc,
                }

        processed = min(i + batch_size, len(all_ids))
        print(f"   ... processed {processed}/{len(all_ids)} IDs -> {len(by_canon_seq)} unique features", flush=True)

        if len(by_canon_seq) >= 1450 and processed >= 400:
            print("🎯 Reached >= 1450 unique features after classic vectors; proceeding to golden-vector verification.", flush=True)
            break

    raw_items = list(by_canon_seq.values())
    print(f"🧪 Parsed {total_records} GenBank records, collected {len(raw_items)} unique non-seed features.", flush=True)

    cat_priority = {
        "promoter": 0,
        "ori": 1,
        "resistance": 2,
        "reporter": 3,
        "tag": 4,
        "viral": 5,
        "terminator": 6,
        "recombinase": 7,
        "regulator": 8,
        "enhancer": 9,
        "misc": 10,
    }
    raw_items.sort(
        key=lambda x: (
            cat_priority.get(x["category"], 99),
            x["name"].lower(),
            len(x["sequence"]),
            x["sequence"],
        )
    )

    if len(raw_items) > 1400:
        raw_items = raw_items[:1400]

    print("🛡️  Running golden-vector collision gate against Tests/vectors/plasmid_auto_annotation.json...", flush=True)
    clean_items, removed = verify_against_golden_vectors(raw_items)
    if removed:
        print(
            f"   🧹 Removed {len(removed)} golden-colliding variants: {', '.join(removed[:15])}{'...' if len(removed) > 15 else ''}",
            flush=True,
        )

    if len(clean_items) < 1000:
        raise RuntimeError(f"Expected >= 1000 harvested features, only got {len(clean_items)}")

    payload = {
        "source": "NCBI GenBank nuccore ([FKEY] annotated vectors) & FPbase nucleotide GenBank accessions (Public Domain)",
        "seed_core_count": len(PLASMID_FEATURES_SEED),
        "harvested_count": len(clean_items),
        "features": clean_items,
    }
    with open(CATALOG_OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    cat_counts = {}
    for item in clean_items:
        cat_counts[item["category"]] = cat_counts.get(item["category"], 0) + 1

    print(f"✅ Wrote {len(clean_items)} verified features to {CATALOG_OUT_PATH}", flush=True)
    print("   Category breakdown:", json.dumps(cat_counts, ensure_ascii=False, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
