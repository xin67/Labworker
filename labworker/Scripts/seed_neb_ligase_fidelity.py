#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Idempotent empirical seed script to populate NEB Type IIS / T4 DNA Ligase PacBio SMRT
ligation fidelity matrices inside `Sources/CloneStudioCore/Resources/Libraries.sqlite`
without modifying `sgrna`, `shrna`, or `plasmid_features`.

Empirical Data Sources (CC-BY 4.0 Open Access):
  - Pryor JM, Potapov V, Kucera RB, Bilotti K, Cantor EJ, Lohman GJS (2020).
    "Enabling one-pot Golden Gate assemblies of unprecedented complexity using
    data-optimized assembly design." PLoS ONE 15(9): e0238592.
    DOI: 10.1371/journal.pone.0238592
      * S1 Table (S1_BsaI-HFv2.xlsx): BsaI-HFv2 + T4 DNA Ligase (4-bp, 256x256)
      * S2 Table (S2_BsmBI-v2.xlsx):  BsmBI-v2  + T4 DNA Ligase (4-bp, 256x256)
      * S4 Table (S4_BbsI-HF.xlsx):   BbsI-HF   + T4 DNA Ligase (4-bp, 256x256)
      * S5 Table (S5_SapI.xlsx):      SapI      + T4 DNA Ligase (3-bp, 64x64)
  - Methodology reference: Potapov V, Ong JL, Kucera RB, Langhorst BW, Bilotti K,
    Pryor JM, Cantor EJ, Canton B, Knight TF, Evans TC Jr, Lohman GJS (2018).
    "Comprehensive Profiling of Four Base Overhang Ligation Fidelity by T4 DNA Ligase
    and Application to DNA Assembly." ACS Synth Biol 7(11): 2665-2674.

All empirical ligation counts M(a, b) are imported verbatim without synthetic smoothing
or reverse-complement averaging, preserving strand-polarity mismatch asymmetry
M(a, b) != M(rc(a), rc(b)) and exact self-ligation counts M(a, a).
"""

import hashlib
import os
import sqlite3
import sys
import xml.etree.ElementTree as ET
import zipfile

sys.dont_write_bytecode = True

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(BASE_DIR, "Sources/CloneStudioCore/Resources/Libraries.sqlite")
DATA_DIR = os.path.join(BASE_DIR, "Scripts/data/pryor2020")

COMP = {"A": "T", "T": "A", "C": "G", "G": "C"}

EMPIRICAL_DATASETS = [
    {
        "enzyme_key": "bsai",
        "enzyme_label": "BsaI-HFv2 + T4 DNA Ligase (Pryor et al. 2020 S1 Table)",
        "overhang_length": 4,
        "filename": "S1_BsaI-HFv2.xlsx",
        "source_doi": "10.1371/journal.pone.0238592.s001",
        "source_citation": "Pryor et al., PLoS ONE 2020; 15(9): e0238592 (S1 Table, BsaI-HFv2 cycling)",
        "sha256": "320dd058f3ca6372768c7ddfe9cda2a2ea2a076c4f86dd08587d8f295aae1d15",
    },
    {
        "enzyme_key": "bsmbi",
        "enzyme_label": "BsmBI-v2 + T4 DNA Ligase (Pryor et al. 2020 S2 Table)",
        "overhang_length": 4,
        "filename": "S2_BsmBI-v2.xlsx",
        "source_doi": "10.1371/journal.pone.0238592.s002",
        "source_citation": "Pryor et al., PLoS ONE 2020; 15(9): e0238592 (S2 Table, BsmBI-v2 cycling)",
        "sha256": "7c444e99e5e4d245461a892e8543a35c84987f93abcee7098de9d9d817237e94",
    },
    {
        "enzyme_key": "bbsi",
        "enzyme_label": "BbsI-HF + T4 DNA Ligase (Pryor et al. 2020 S4 Table)",
        "overhang_length": 4,
        "filename": "S4_BbsI-HF.xlsx",
        "source_doi": "10.1371/journal.pone.0238592.s004",
        "source_citation": "Pryor et al., PLoS ONE 2020; 15(9): e0238592 (S4 Table, BbsI-HF cycling)",
        "sha256": "56143bb445e6d84bba646429402e0948793395269cc5d8ba0e80962c0cac6492",
    },
    {
        "enzyme_key": "sapi",
        "enzyme_label": "SapI + T4 DNA Ligase (Pryor et al. 2020 S5 Table, 3-bp)",
        "overhang_length": 3,
        "filename": "S5_SapI.xlsx",
        "source_doi": "10.1371/journal.pone.0238592.s005",
        "source_citation": "Pryor et al., PLoS ONE 2020; 15(9): e0238592 (S5 Table, SapI 3-bp cycling)",
        "sha256": "dfa2df906bd306e3971652c4b95d004818fdb8dd9e49f4522691959d28f537cb",
    },
]

# Published NEB / Potapov et al. (2018) / Pryor et al. (2020) high-fidelity non-palindromic 4-bp overhangs
NEB_VERIFIED_HF_OVERHANGS = {
    "GGAG", "CTCC", "TACT", "AGTA", "AATG", "CATT", "AGGT", "ACCT",
    "GCTT", "AAGC", "CGCT", "AGCG", "TGCC", "GGCA", "ACTA", "TAGT",
    "CAGA", "TCTG", "GACC", "GGTC", "CCAT", "ATGG", "ATAG", "CTAT",
    "TCCG", "CGGA", "CTGA", "TCAG", "ACAA", "TTGT", "GTTA", "TAAC",
    "TCAA", "TTGA", "CAAC", "GTTG", "AGCC", "GGCT", "TTGG", "CCAA",
    "CCTA", "TAGG", "GATA", "TATC", "AGGA", "TCCT", "TGTG", "CACA",
}


def rev_comp(seq: str) -> str:
    return "".join(COMP[ch] for ch in reversed(seq))


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def classify_pair(a: str, b: str) -> tuple:
    """Classify antiparallel pairing of 5'-a-3' against 5'-b-3' (a[i] vs b[L-1-i])."""
    n = len(a)
    mm_count = 0
    has_gt = 0
    for i in range(n):
        bp = b[n - 1 - i]
        if COMP[a[i]] != bp:
            mm_count += 1
            if (a[i] == "G" and bp == "T") or (a[i] == "T" and bp == "G"):
                has_gt = 1
    is_wc = 1 if mm_count == 0 else 0
    return (is_wc, mm_count, has_gt)


def parse_pryor_xlsx(path: str, expected_len: int) -> tuple:
    """Parse Pryor et al. (2020) PLoS ONE supplementary XLSX matrix using Python stdlib only."""
    with zipfile.ZipFile(path) as zf:
        shared_strings = []
        if "xl/sharedStrings.xml" in zf.namelist():
            root = ET.fromstring(zf.read("xl/sharedStrings.xml"))
            ns = {"a": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
            for si in root.findall("a:si", ns):
                shared_strings.append("".join(t.text or "" for t in si.findall(".//a:t", ns)))

        sheet = ET.fromstring(zf.read("xl/worksheets/sheet1.xml"))
        ns = {"a": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
        rows = sheet.findall(".//a:sheetData/a:row", ns)

        def extract_row(row_el):
            vals = []
            for c in row_el.findall("a:c", ns):
                ctype = c.attrib.get("t")
                v_el = c.find("a:v", ns)
                val = v_el.text if v_el is not None else "0"
                if ctype == "s" and val.isdigit():
                    val = shared_strings[int(val)]
                vals.append(val)
            return vals

        header = [x.strip().upper() for x in extract_row(rows[0])[1:]]
        expected_n = 4 ** expected_len
        assert len(header) == expected_n, f"Expected {expected_n} columns in {path}, got {len(header)}"

        counts = {}
        row_overhangs = []
        for r_el in rows[1:]:
            vals = extract_row(r_el)
            if not vals:
                continue
            row_ov = vals[0].strip().upper()
            if len(row_ov) != expected_len:
                continue
            row_overhangs.append(row_ov)
            for col_ov, raw_v in zip(header, vals[1:]):
                cnt = int(round(float(raw_v))) if raw_v else 0
                if cnt > 0:
                    counts[(row_ov, col_ov)] = cnt

        assert len(row_overhangs) == expected_n, f"Expected {expected_n} rows in {path}, got {len(row_overhangs)}"
        return (sorted(set(header)), counts)


def seed_neb_fidelity(db_path: str = DB_PATH, data_dir: str = DATA_DIR) -> dict:
    if not os.path.exists(db_path):
        raise FileNotFoundError(f"Libraries.sqlite not found at: {db_path}")

    all_meta_rows = []
    all_stat_rows = []
    all_pair_rows = []
    bsai_legacy_stats = []
    bsai_legacy_pairs = []
    summary = {}

    for ds in EMPIRICAL_DATASETS:
        xlsx_path = os.path.join(data_dir, ds["filename"])
        if not os.path.exists(xlsx_path):
            raise FileNotFoundError(f"Empirical dataset missing: {xlsx_path}")
        actual_sha = sha256_file(xlsx_path)
        assert actual_sha == ds["sha256"], (
            f"SHA256 mismatch for {ds['filename']}: expected {ds['sha256']}, got {actual_sha}"
        )

        ov_len = ds["overhang_length"]
        ekey = ds["enzyme_key"]
        overhangs, counts = parse_pryor_xlsx(xlsx_path, ov_len)

        # Verify strand-polarity asymmetry is preserved: M(a, b) != M(rc(a), rc(b)) for real data
        rc_asym = sum(
            1 for (a, b), c in counts.items()
            if counts.get((rev_comp(a), rev_comp(b)), 0) != c
        )
        assert rc_asym > 0, f"Expected directional strand-polarity asymmetry in {ds['filename']}"

        sum_by_ov = {ov: 0 for ov in overhangs}
        wc_by_ov = {ov: 0 for ov in overhangs}
        self_by_ov = {ov: counts.get((ov, ov), 0) for ov in overhangs}

        for (a, b), cnt in sorted(counts.items()):
            is_wc, mm_cnt, has_gt = classify_pair(a, b)
            all_pair_rows.append((ekey, a, b, cnt, is_wc, mm_cnt, has_gt))
            if ekey == "bsai":
                bsai_legacy_pairs.append((a, b, cnt, is_wc, mm_cnt, has_gt))
            sum_by_ov[a] += cnt
            if is_wc == 1:
                wc_by_ov[a] = cnt

        for ov in overhangs:
            rc = rev_comp(ov)
            is_pal = 1 if ov == rc else 0
            gc_cnt = ov.count("G") + ov.count("C")
            wc_cnt = wc_by_ov[ov]
            self_cnt = self_by_ov[ov]
            tot_cnt = max(1, sum_by_ov[ov])
            ind_fid = 0.0 if is_pal else round(wc_cnt / float(tot_cnt), 6)
            is_hf = 1 if (ov_len == 4 and ov in NEB_VERIFIED_HF_OVERHANGS and not is_pal and self_cnt == 0) else 0
            all_stat_rows.append((ekey, ov, rc, ov_len, is_pal, gc_cnt, wc_cnt, self_cnt, ind_fid, is_hf))
            if ekey == "bsai":
                bsai_legacy_stats.append((ov, rc, is_pal, gc_cnt, wc_cnt, ind_fid, is_hf))

        all_meta_rows.append((
            ekey,
            ds["enzyme_label"],
            ov_len,
            ds["source_citation"],
            ds["source_doi"],
            ds["filename"],
            actual_sha,
            len(overhangs),
            len(counts),
        ))
        summary[ekey] = (len(overhangs), len(counts), rc_asym)

    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()
        # Legacy tables (kept populated with real Pryor 2020 S1 BsaI-HFv2 empirical data for backward compatibility)
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS neb_t4_overhang_stats (
                overhang TEXT PRIMARY KEY,
                rc_overhang TEXT NOT NULL,
                is_palindromic INTEGER NOT NULL,
                gc_count INTEGER NOT NULL,
                wc_ligation_count INTEGER NOT NULL,
                individual_fidelity REAL NOT NULL,
                is_neb_verified_hf INTEGER NOT NULL DEFAULT 0
            );
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS neb_t4_ligase_fidelity (
                overhang_a TEXT NOT NULL,
                overhang_b TEXT NOT NULL,
                ligation_count INTEGER NOT NULL,
                is_watson_crick INTEGER NOT NULL,
                mismatch_count INTEGER NOT NULL,
                has_gt_mismatch INTEGER NOT NULL,
                PRIMARY KEY (overhang_a, overhang_b)
            );
            """
        )
        cur.execute("CREATE INDEX IF NOT EXISTS idx_neb_t4_overhang_a ON neb_t4_ligase_fidelity(overhang_a);")

        # Multi-enzyme empirical tables (BsaI-HFv2, BsmBI-v2, BbsI-HF, SapI 3-bp)
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS neb_ligase_fidelity_metadata (
                enzyme_key TEXT PRIMARY KEY,
                enzyme_label TEXT NOT NULL,
                overhang_length INTEGER NOT NULL,
                source_citation TEXT NOT NULL,
                source_doi TEXT NOT NULL,
                source_file TEXT NOT NULL,
                sha256 TEXT NOT NULL,
                overhang_count INTEGER NOT NULL,
                nonzero_pairs INTEGER NOT NULL
            );
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS neb_overhang_stats_by_enzyme (
                enzyme_key TEXT NOT NULL,
                overhang TEXT NOT NULL,
                rc_overhang TEXT NOT NULL,
                overhang_length INTEGER NOT NULL,
                is_palindromic INTEGER NOT NULL,
                gc_count INTEGER NOT NULL,
                wc_ligation_count INTEGER NOT NULL,
                self_ligation_count INTEGER NOT NULL,
                individual_fidelity REAL NOT NULL,
                is_neb_verified_hf INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (enzyme_key, overhang)
            );
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS neb_ligase_fidelity_matrices (
                enzyme_key TEXT NOT NULL,
                overhang_a TEXT NOT NULL,
                overhang_b TEXT NOT NULL,
                ligation_count INTEGER NOT NULL,
                is_watson_crick INTEGER NOT NULL,
                mismatch_count INTEGER NOT NULL,
                has_gt_mismatch INTEGER NOT NULL,
                PRIMARY KEY (enzyme_key, overhang_a, overhang_b)
            );
            """
        )
        cur.execute(
            "CREATE INDEX IF NOT EXISTS idx_neb_mat_enzyme_a ON neb_ligase_fidelity_matrices(enzyme_key, overhang_a);"
        )

        cur.execute("DELETE FROM neb_t4_overhang_stats;")
        cur.execute("DELETE FROM neb_t4_ligase_fidelity;")
        cur.execute("DELETE FROM neb_ligase_fidelity_metadata;")
        cur.execute("DELETE FROM neb_overhang_stats_by_enzyme;")
        cur.execute("DELETE FROM neb_ligase_fidelity_matrices;")

        cur.executemany(
            """
            INSERT INTO neb_t4_overhang_stats
            (overhang, rc_overhang, is_palindromic, gc_count, wc_ligation_count, individual_fidelity, is_neb_verified_hf)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            bsai_legacy_stats,
        )
        cur.executemany(
            """
            INSERT INTO neb_t4_ligase_fidelity
            (overhang_a, overhang_b, ligation_count, is_watson_crick, mismatch_count, has_gt_mismatch)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bsai_legacy_pairs,
        )
        cur.executemany(
            """
            INSERT INTO neb_ligase_fidelity_metadata
            (enzyme_key, enzyme_label, overhang_length, source_citation, source_doi, source_file, sha256, overhang_count, nonzero_pairs)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            all_meta_rows,
        )
        cur.executemany(
            """
            INSERT INTO neb_overhang_stats_by_enzyme
            (enzyme_key, overhang, rc_overhang, overhang_length, is_palindromic, gc_count, wc_ligation_count, self_ligation_count, individual_fidelity, is_neb_verified_hf)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            all_stat_rows,
        )
        cur.executemany(
            """
            INSERT INTO neb_ligase_fidelity_matrices
            (enzyme_key, overhang_a, overhang_b, ligation_count, is_watson_crick, mismatch_count, has_gt_mismatch)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            all_pair_rows,
        )
        conn.commit()

        sg_cnt = cur.execute("SELECT COUNT(*) FROM sgrna;").fetchone()[0]
        sh_cnt = cur.execute("SELECT COUNT(*) FROM shrna;").fetchone()[0]
        pf_cnt = cur.execute("SELECT COUNT(*) FROM plasmid_features;").fetchone()[0]
        assert sg_cnt == 123434, f"sgrna count altered: {sg_cnt}"
        assert sh_cnt == 81537, f"shrna count altered: {sh_cnt}"
        assert pf_cnt >= 1415, f"plasmid_features count altered: {pf_cnt}"
        return summary
    finally:
        conn.close()


if __name__ == "__main__":
    summary = seed_neb_fidelity()
    for ekey, (n_ov, n_pairs, n_asym) in summary.items():
        print(f"✅ Seeded empirical Pryor (2020) matrix [{ekey}]: {n_ov} overhangs, {n_pairs} nonzero pairs (rc-asymmetry={n_asym})")
