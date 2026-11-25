#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Idempotent seed script to create and populate the `plasmid_features` table
inside `Sources/CloneStudioCore/Resources/Libraries.sqlite` without touching
the existing `sgrna` (123,434 rows) or `shrna` (81,537 rows) tables.
"""

import json
import os
import sqlite3
import sys

sys.dont_write_bytecode = True

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CATALOG_PATH = os.path.join(SCRIPT_DIR, "plasmid_features_catalog.json")
DB_PATH = os.path.join(BASE_DIR, "Sources/CloneStudioCore/Resources/Libraries.sqlite")

CODON_TABLE = {
    "TTT": "F", "TTC": "F", "TTA": "L", "TTG": "L",
    "CTT": "L", "CTC": "L", "CTA": "L", "CTG": "L",
    "ATT": "I", "ATC": "I", "ATA": "I", "ATG": "M",
    "GTT": "V", "GTC": "V", "GTA": "V", "GTG": "V",
    "TCT": "S", "TCC": "S", "TCA": "S", "TCG": "S",
    "CCT": "P", "CCC": "P", "CCA": "P", "CCG": "P",
    "ACT": "T", "ACC": "T", "ACA": "T", "ACG": "T",
    "GCT": "A", "GCC": "A", "GCA": "A", "GCG": "A",
    "TAT": "Y", "TAC": "Y", "TAA": "*", "TAG": "*",
    "CAT": "H", "CAC": "H", "CAA": "Q", "CAG": "Q",
    "AAT": "N", "AAC": "N", "AAA": "K", "AAG": "K",
    "GAT": "D", "GAC": "D", "GAA": "E", "GAG": "E",
    "TGT": "C", "TGC": "C", "TGA": "*", "TGG": "W",
    "CGT": "R", "CGC": "R", "CGA": "R", "CGG": "R",
    "AGT": "S", "AGC": "S", "AGA": "R", "AGG": "R",
    "GGT": "G", "GGC": "G", "GGA": "G", "GGG": "G",
}


def translate_dna(seq: str) -> str:
    assert len(seq) % 3 == 0, f"Coding sequence length {len(seq)} is not divisible by 3"
    return "".join(CODON_TABLE[seq[i:i + 3]] for i in range(0, len(seq), 3))


# Canonical plasmid feature seed catalog (15 standard molecular biology elements)
PLASMID_FEATURES_SEED = [
    # --- Promoters ---
    (
        "CMV promoter",
        "promoter",
        (
            "CGTTACATAACTTACGGTAAATGGCCCGCCTGGCTGACCGCCCAACGACCCCCGCCCATTGACGTCAATA"
            "ATGACGTATGTTCCCATAGTAACGCCAATAGGGACTTTCCATTGACGTCAATGGGTGGAGTATTTACGGT"
            "AAACTGCCCACTTGGCAGTACATCAAGTGTATCATATGCCAAGTACGCCCCCTATTGACGTCAATGACGG"
            "TAAATGGCCCGCCTGGCATTATGCCCAGTACATGACCTTATGGGACTTTCCTACTTGGCAGTACATCTAC"
            "GTATTAGTCATCGCTATTACCATGGTGATGCGGTTTTGGCAGTACATCAATGGGCGTGGATAGCGGTTTG"
            "ACTCACGGGGATTTCCAAGTCTCCACCCCATTGACGTCAATGGGAGTTTGTTTTGGCACCAAAATCAACG"
            "GGACTTTCCAAAATGTCGTAACAACTCCGCCCCATTGACGCAAATGGGCGGTAGGCGTGTACGGTGGGAG"
            "GTCTATATAAGCAGAGCT"
        ),
        1,
        "#3B82F6",
    ),
    (
        "EF1a promoter",
        "promoter",
        (
            "GGCTCCGGTGCCCGTCAGTGGGCAGAGCGCACATCGCCCACAGTCCCCGAGAAGTTGGGGGGAGGGGTCG"
            "GCAATTGAACCGGTGCCTAGAGAAGGTGGCGCGGGGTAAACTGGGAAAGTGATGTCGTGTACTGGCTCCG"
            "CCTTTTTCCCGAGGGTGGGGGAGAACCGTATATAAGTGCAGTAGTCGCCGTGAACGTTCTTTTTCGCAAC"
            "GGGTTTGCCGCCAGAACACAG"
        ),
        1,
        "#3B82F6",
    ),
    (
        "U6 promoter",
        "promoter",
        (
            "GAGGGCCTATTTCCCATGATTCCTTCATATTTGCATATACGATACAAGGCTGTTAGAGAGATAATTGGAA"
            "TTAATTTGACTGTAAACACAAAGATATTAGTACAAAATACGTGACGTAGAAAGTAATAATTTCTTGGGTA"
            "GTTTGCAGTTTTAAAATTATGTTTTAAAATGGACTATCATATGCTTACCGTAACTTGAAAGTATTTCGAT"
            "TTCTTGGCTTTATATATCTTGTGGAAAGGACGAAACACC"
        ),
        1,
        "#3B82F6",
    ),
    (
        "T7 promoter",
        "promoter",
        "TAATACGACTCACTATAGG",
        1,
        "#3B82F6",
    ),
    # --- Resistance Genes ---
    (
        "AmpR",
        "resistance",
        (
            "ATGAGTATTCAACATTTCCGTGTCGCCCTTATTCCCTTTTTTGCGGCATTTTGCCTTCCTGTTTTTGCTC"
            "ACCCAGAAACGCTGGTGAAAGTAAAAGATGCTGAAGATCAGTTGGGTGCACGAGTGGGTTACATCGAACT"
            "GGATCTCAACAGCGGTAAGATCCTTGAGAGTTTTCGCCCCGAAGAACGTTTTCCAATGATGAGCACTTTT"
            "AAAGTTCTGCTATGTGGCGCGGTATTATCCCGTATTGACGCCGGGCAAGAGCAACTCGGTCGCCGCATAC"
            "ACTATTCTCAGAATGACTTGGTTGAGTACTCACCAGTCACAGAAAAGCATCTTACGGATGGCATGACAGT"
            "AAGAGAATTATGCAGTGCTGCCATAACCATGAGTGATAACACTGCGGCCAACTTACTTCTGACAACGATC"
            "GGAGGACCGAAGGAGCTAACCGCTTTTTTGCACAACATGGGGGATCATGTAACTCGCCTTGATCGTTGGG"
            "AACCGGAGCTGAATGAAGCCATACCAAACGACGAGCGTGACACCACGATGCCTGTAGCAATGGCAACAAC"
            "GTTGCGCAAACTATTAACTGGCGAACTACTTACTCTAGCTTCCCGGCAACAATTAATAGACTGGATGGAG"
            "GCGGATAAAGTTGCAGGACCACTTCTGCGCTCGGCCCTTCCGGCTGGCTGGTTTATTGCTGATAAATCTG"
            "GAGCCGGTGAGCGTGGGTCTCGCGGTATCATTGCAGCACTGGGGCCAGATGGTAAGCCCTCCCGTATCGT"
            "AGTTATCTACACGACGGGGAGTCAGGCAACTATGGATGAACGAAATAGACAGATCGCTGAGATAGGTGCC"
            "TCACTGATTAAGCATTGGTAA"
        ),
        1,
        "#EF4444",
    ),
    (
        "KanR",
        "resistance",
        (
            "ATGAGCCATATTCAACGGGAAACGTCTTGCTCGAGGCCGCGATTAAATTCCAACATGGATGCTGATTTAT"
            "ATGGGTATAAATGGGCTCGCGATAATGTCGGGCAATCAGGTGCGACAATCTATCGCTTGTATGGGAAGCC"
            "CGATGCGCCAGAGTTGTTTCTGAAACATGGCAAAGGTAGCGTTGCCAATGATGTTACAGATGAGATGGTC"
            "AGACTAAACTGGCTGACGGAATTTATGCCTCTTCCGACCATCAAGCATTTTATCCGTACTCCTGATGATG"
            "CATGGTTACTCACCACTGCGATCCCCGGAAAAACAGCATTCCAGGTATTAGAAGAATATCCTGATTCAGG"
            "TGAAAATATTGTTGATGCGCTGGCAGTGTTCCTGCGCCGGTTGCATTCGATTCCTGTTTGTAATTGTCCT"
            "TTTAACAGCGATCGCGTATTTCGTCTCGCTCAGGCGCAATCACGAATGAATAACGGTTTGGTTGATGCGA"
            "GTGATTTTGATGACGAGCGTAATGGCTGGCCTGTTGAACAAGTCTGGAAAGAAATGCATAAACTTTTGCC"
            "ATTCTCACCGGATTCAGTCGTCACTCATGGTGATTTCTCACTTGATAACCTTATTTTTGACGAGGGGAAA"
            "TTAATAGGTTGTATTGATGTTGGACGAGTCGGAATCGCAGACCGATACCAGGATCTTGCCATCCTATGGA"
            "ACTGCCTCGGTGAGTTTTCTCCTTCATTACAGAAACGGCTTTTTCAAAAATATGGTATTGATAATCCTGA"
            "TATGAATAAATTGCAGTTTCATTTGATGCTCGATGAGTTTTTCTAA"
        ),
        1,
        "#EF4444",
    ),
    (
        "PuroR",
        "resistance",
        (
            "ATGACCGAGTACAAGCCCACGGTGCGCCTCGCCACCCGCGACGACGTCCCCAGGGCCGTACGCACCCTCG"
            "CCGCCGCGTTCGCCGACTACCCCGCCACGCGCCACACCGTCGATCCGGACCGCCACATCGAGCGGGTCAC"
            "CGAGCTGCAAGAACTCTTCCTCACGCGCGTCGGGCTCGACATCGGCAAGGTGTGGGTCGCGGACGACGGC"
            "GCCGCGGTGGCGGTCTGGACCACGCCGGAGAGCGTCGAAGCGGGGGCGGTGTTCGCCGAGATCGGCCCGC"
            "GCATGGCCGAGTTGAGCGGTTCCCGGCTGGCCGCGCAGCAACAGATGGAAGGCCTCCTGGCGCCGCACCG"
            "GCCCAAGGAGCCCGCGTGGTTCCTGGCCACCGTCGGCGTCTCGCCCGACCACCAGGGCAAGGGTCTGGGC"
            "AGCGCCGTCGTGCTCCCCGGAGTGGAGGCGGCCGAGCGCGCCGGGGTGCCCGCCTTCCTGGAGACCTCCG"
            "CGCCCCGCAACCTCCCCTTCTACGAGCGGCTCGGCTTCACCGTCACCGCCGACGTCGAGGTGCCCGAAGG"
            "ACCGCGCACCTGGTGCATGACCCGCAAGCCCGGTGCCTGA"
        ),
        1,
        "#EF4444",
    ),
    # --- Replication Origins ---
    (
        "pUC ori",
        "ori",
        (
            "TTGAGATCCTTTTTTTCTGCGCGTAATCTGCTGCTTGCAAACAAAAAAACCACCGCTACCAGCGGTGGTT"
            "TGTTTGCCGGATCAAGAGCTACCAACTCTTTTTCCGAAGGTAACTGGCTTCAGCAGAGCGCAGATACCAA"
            "ATACTGTTCTTCTAGTGTAGCCGTAGTTAGGCCACCACTTCAAGAACTCTGTAGCACCGCCTACATACCT"
            "CGCTCTGCTAATCCTGTTACCAGTGGCTGCTGCCAGTGGCGATAAGTCGTGTCTTACCGGGTTGGACTCA"
            "AGACGATAGTTACCGGATAAGGCGCAGCGGTCGGGCTGAACGGGGGGTTCGTGCACACAGCCCAGCTTGG"
            "AGCGAACGACCTACACCGAACTGAGATACCTACAGCGTGAGCTATGAGAAAGCGCCACGCTTCCCGAAGG"
            "GAGAAAGGCGGACAGGTATCCGGTAAGCGGCAGGGTCGGAACAGGAGAGCGCACGAGGGAGCTTCCAGGG"
            "GGAAACGCCTGGTATCTTTATAGTCCTGTCGGGTTTCGCCACCTCTGACTTGAGCGTCGATTTTTGTGAT"
            "GCTCGTCAGGGGGGCGGAGCCTATGGAAAAACGCCAGCAACGC"
        ),
        1,
        "#F59E0B",
    ),
    (
        "ColE1 ori",
        "ori",
        (
            "TTGAGATCCTTTTTTTCTGCGCGTAATCTGCTGCTTGCAAACAAAAAAACCACCGCTACCAGCGGTGGTT"
            "TGTTTGCCGGATCAAGAGCTACCAACTCTTTTTCCGAAGGTAACTGGCTTCAGCAGAGCGCAGATACCAA"
            "ATACTGTCCTTCTAGTGTAGCCGTAGTTAGGCCACCACTTCAAGAACTCTGTAGCACCGCCTACATACCT"
            "CGCTCTGCTAATCCTGTTACCAGTGGCTGCTGCCAGTGGCGATAAGTCGTGTCTTACCGGGTTGGACTCA"
            "AGACGATAGTTACCGGATAAGGCGCAGCGGTCGGGCTGAACGGGGGGTTCGTGCACACAGCCCAGCTTGG"
            "AGCGAACGACCTACACCGAACTGAGATACCTACAGCGTGAGCTATGAGAAAGCGCCACGCTTCCCGAAGG"
            "GAGAAAGGCGGACAGGTATCCGGTAAGCGGCAGGGTCGGAACAGGAGAGCGCACGAGGGAGCTTCCAGGG"
            "GGAAACGCCTGGTATCTTTATAGTCCTGTCGGGTTTCGCCACCTCTGACTTGAGCGTCGATTTTTGTGAT"
            "GCTCGTCAGGGGGGCGGAGCCTATGGAAAAACGCCAGCAACGC"
        ),
        1,
        "#F59E0B",
    ),
    (
        "SV40 ori",
        "ori",
        (
            "ATCCCGCCCCTAACTCCGCCCAGTTCCGCCCATTCTCCGCCCCATGGCTGACTAATTTTTTTTATTTATG"
            "CAGAGGCCGAGGCCGCCTCGGCCTCTGAGCTATTCCGAAGTAGTGAGGAGGCTTTTTTGGAGGCC"
        ),
        0,
        "#F59E0B",
    ),
    # --- Protein Tags ---
    (
        "3xFLAG",
        "tag",
        "GACTACAAAGACCATGACGGTGATTATAAAGATCATGACATCGACTACAAGGATGACGATGACAAG",
        1,
        "#8B5CF6",
    ),
    (
        "HA",
        "tag",
        "TACCCATACGATGTTCCAGATTACGCT",
        1,
        "#8B5CF6",
    ),
    (
        "His",
        "tag",
        "CACCACCACCACCACCAC",
        1,
        "#8B5CF6",
    ),
    # --- Fluorescent Reporters ---
    (
        "EGFP",
        "reporter",
        (
            "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAA"
            "ACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTT"
            "CATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAG"
            "TGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACG"
            "TCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGG"
            "CGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCAC"
            "AAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGG"
            "TGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACAC"
            "CCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAA"
            "GACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCA"
            "TGGACGAGCTGTACAAGTAA"
        ),
        1,
        "#10B981",
    ),
    (
        "mCherry",
        "reporter",
        (
            "ATGGTGAGCAAGGGCGAGGAGGATAACATGGCCATCATCAAGGAGTTCATGCGCTTCAAGGTGCACATGG"
            "AGGGCTCCGTGAACGGCCACGAGTTCGAGATCGAGGGCGAGGGCGAGGGCCGCCCCTACGAGGGCACCCA"
            "GACCGCCAAGCTGAAGGTGACCAAGGGTGGCCCCCTGCCCTTCGCCTGGGACATCCTGTCCCCTCAGTTC"
            "ATGTACGGCTCCAAGGCCTACGTGAAGCACCCCGCCGACATCCCCGACTACTTGAAGCTGTCCTTCCCCG"
            "AGGGCTTCAAGTGGGAGCGCGTGATGAACTTCGAGGACGGCGGCGTGGTGACCGTGACCCAGGACTCCTC"
            "CCTGCAGGACGGCGAGTTCATCTACAAGGTGAAGCTGCGCGGCACCAACTTCCCCTCCGACGGCCCCGTA"
            "ATGCAGAAGAAGACCATGGGCTGGGAGGCCTCCTCCGAGCGGATGTACCCCGAGGACGGCGCCCTGAAGG"
            "GCGAGATCAAGCAGAGGCTGAAGCTGAAGGACGGCGGCCACTACGACGCTGAGGTCAAGACCACCTACAA"
            "GGCCAAGAAGCCCGTGCAGCTGCCCGGCGCCTACAACGTCAACATCAAGTTGGACATCACCTCCCACAAC"
            "GAGGACTACACCATCGTGGAACAGTACGAACGCGCCGAGGGCCGCCACTCCACCGGCGGCATGGACGAGC"
            "TGTACAAGTAA"
        ),
        1,
        "#EC4899",
    ),
]


def validate_seed_catalog() -> None:
    orf_checks = {
        "AmpR": ("MSIQHFRVAL", "IKHW*"),
        "KanR": ("MSHIQRETSC", "DEFF*"),
        "PuroR": ("MTEYKPTVRL", "KPGA*"),
        "EGFP": ("MVSKGEELFT", "ELYK*"),
        "mCherry": ("MVSKGEEDNM", "ELYK*"),
    }
    tag_checks = {
        "3xFLAG": "DYKDHDGDYKDHDIDYKDDDDK",
        "HA": "YPYDVPDYA",
        "His": "HHHHHH",
    }

    by_name = {}
    for name, category, seq, direction, color_hex in PLASMID_FEATURES_SEED:
        assert set(seq) <= {"A", "C", "G", "T"}, f"{name}: invalid DNA characters"
        assert direction in (-1, 0, 1), f"{name}: invalid direction {direction}"
        assert color_hex.startswith("#") and len(color_hex) == 7, f"{name}: invalid color_hex {color_hex}"
        by_name[name] = seq

        if name in orf_checks:
            aa = translate_dna(seq)
            start_prefix, end_suffix = orf_checks[name]
            assert aa.startswith(start_prefix), f"{name} protein prefix mismatch: {aa[:12]}"
            assert aa.endswith(end_suffix), f"{name} protein suffix mismatch: {aa[-8:]}"
            assert aa[:-1].count("*") == 0, f"{name} contains internal stop codon: {aa}"
        if name in tag_checks:
            aa = translate_dna(seq)
            assert aa == tag_checks[name], f"{name} tag translation mismatch: {aa}"

    # Verify canonical 1-bp difference between pUC ori and ColE1 ori
    puc = by_name["pUC ori"]
    cole1 = by_name["ColE1 ori"]
    assert len(puc) == len(cole1) == 603
    diffs = [i for i in range(len(puc)) if puc[i] != cole1[i]]
    assert len(diffs) == 1, f"Expected 1 canonical SNP between pUC ori and ColE1 ori, found {diffs}"


def load_extended_catalog() -> list:
    if not os.path.exists(CATALOG_PATH):
        return []
    with open(CATALOG_PATH, "r", encoding="utf-8") as f:
        payload = json.load(f)
    raw_items = payload.get("features", [])
    seed_names_lower = {row[0].lower() for row in PLASMID_FEATURES_SEED}
    used_names_lower = set(seed_names_lower)
    rows = []
    for item in raw_items:
        name = str(item["name"]).strip()
        cat = str(item["category"]).strip()
        seq = str(item["sequence"]).strip().upper()
        direction = int(item.get("direction", 1))
        color_hex = str(item["color_hex"]).strip()
        if not name or name.lower() in used_names_lower:
            continue
        if not seq or not (set(seq) <= {"A", "C", "G", "T"}):
            continue
        if direction not in (-1, 0, 1):
            direction = 1
        if not (color_hex.startswith("#") and len(color_hex) == 7):
            color_hex = "#6B7280"
        used_names_lower.add(name.lower())
        rows.append((name, cat, seq, direction, color_hex))
    return rows


def seed_database(db_path: str = DB_PATH) -> int:
    if not os.path.exists(db_path):
        raise FileNotFoundError(f"Libraries.sqlite not found at: {db_path}")

    validate_seed_catalog()
    extended_rows = load_extended_catalog()
    all_rows = list(PLASMID_FEATURES_SEED) + extended_rows

    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS plasmid_features (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                category TEXT NOT NULL,
                sequence TEXT NOT NULL,
                direction INTEGER NOT NULL DEFAULT 1,
                color_hex TEXT NOT NULL
            );
            """
        )
        cur.execute("CREATE INDEX IF NOT EXISTS idx_plasmid_features_category ON plasmid_features(category);")
        cur.execute("CREATE INDEX IF NOT EXISTS idx_plasmid_features_name ON plasmid_features(name);")

        cur.execute("DELETE FROM plasmid_features;")
        cur.execute("DELETE FROM sqlite_sequence WHERE name = 'plasmid_features';")
        cur.executemany(
            """
            INSERT INTO plasmid_features (name, category, sequence, direction, color_hex)
            VALUES (?, ?, ?, ?, ?);
            """,
            all_rows,
        )
        conn.commit()

        sg_cnt = cur.execute("SELECT COUNT(*) FROM sgrna;").fetchone()[0]
        sh_cnt = cur.execute("SELECT COUNT(*) FROM shrna;").fetchone()[0]
        pf_cnt = cur.execute("SELECT COUNT(*) FROM plasmid_features;").fetchone()[0]
        assert sg_cnt == 123434, f"sgrna count altered unexpectedly: {sg_cnt}"
        assert sh_cnt == 81537, f"shrna count altered unexpectedly: {sh_cnt}"
        assert pf_cnt == len(all_rows), f"plasmid_features count mismatch: {pf_cnt} != {len(all_rows)}"
        assert pf_cnt >= len(PLASMID_FEATURES_SEED)
        return pf_cnt
    finally:
        conn.close()


if __name__ == "__main__":
    count = seed_database()
    print(f"✅ Seeded {count} plasmid features into {DB_PATH}")
