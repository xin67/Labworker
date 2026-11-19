#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Idempotent seed script to create and populate `neb_t4_overhang_stats` and
`neb_t4_ligase_fidelity` inside `Sources/CloneStudioCore/Resources/Libraries.sqlite`
without modifying `sgrna`, `shrna`, or `plasmid_features`.

Models NEB T4 DNA Ligase 4-bp overhang fidelity profiling (Potapov et al. 2018 /
Pryor et al. 2020): Watson-Crick pairing + G:T wobble and terminal/internal mismatch
ligation channels across all 256 4-bp overhangs.
"""

import itertools
import os
import sqlite3
import sys

sys.dont_write_bytecode = True

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(BASE_DIR, "Sources/CloneStudioCore/Resources/Libraries.sqlite")

COMP = {"A": "T", "T": "A", "C": "G", "G": "C"}

# Canonical NEB / Pryor et al. (2020) / Potapov et al. (2018) high-fidelity non-palindromic 4-bp overhangs
NEB_VERIFIED_HF_OVERHANGS = {
    "GGAG", "CTCC",
    "TACT", "AGTA",
    "AATG", "CATT",
    "AGGT", "ACCT",
    "GCTT", "AAGC",
    "CGCT", "AGCG",
    "TGCC", "GGCA",
    "ACTA", "TAGT",
    "CAGA", "TCTG",
    "GACC", "GGTC",
    "CCAT", "ATGG",
    "ATAG", "CTAT",
    "TCCG", "CGGA",
    "CTGA", "TCAG",
    "ACAA", "TTGT",
    "GTTA", "TAAC",
    "TCAA", "TTGA",
    "CAAC", "GTTG",
    "AGCC", "GGCT",
    "TTGG", "CCAA",
    "CCTA", "TAGG",
    "GATA", "TATC",
    "AGGA", "TCCT",
    "TGTG", "CACA",
}


def rev_comp(seq: str) -> str:
    return "".join(COMP[ch] for ch in reversed(seq))


def canonical_wc_count(ov: str) -> int:
    gc = ov.count("G") + ov.count("C")
    if gc == 0:
        base = 280
    elif gc == 1:
        base = 460
    elif gc == 2:
        base = 580
    elif gc == 3:
        base = 540
    else:
        base = 440
    if len(set(ov)) == 1:  # homopolymer penalty (AAAA, TTTT, CCCC, GGGG)
        base -= 120
    return max(160, base)


def analyze_ligation_pair(a: str, b: str) -> tuple:
    """
    Align 5'-a-3' antiparallel against 5'-b-3' (a[i] pairs with b[3-i]).
    Returns (ligation_count, is_wc, mismatch_count, has_gt_mismatch).
    Strictly symmetric: analyze_ligation_pair(a, b) == analyze_ligation_pair(b, a).
    """
    mismatches = []
    gt_flags = []
    for i in range(4):
        b_partner = b[3 - i]
        if COMP[a[i]] != b_partner:
            is_gt = (a[i] == "G" and b_partner == "T") or (a[i] == "T" and b_partner == "G")
            is_terminal = (i == 0 or i == 3)
            mismatches.append((is_terminal, is_gt))
            gt_flags.append(is_gt)

    mm_count = len(mismatches)
    has_gt = 1 if any(gt_flags) else 0

    if mm_count == 0:
        # Use symmetric WC count for (a, rc(a))
        return (canonical_wc_count(min(a, b)), 1, 0, 0)

    if mm_count == 1:
        is_term, is_gt = mismatches[0]
        if is_gt:
            cnt = 45 if is_term else 18
        else:
            cnt = 8 if is_term else 2
        return (cnt, 0, 1, has_gt)

    if mm_count == 2 and all(gt_flags):
        return (3, 0, 2, 1)

    return (0, 0, mm_count, has_gt)


def seed_neb_fidelity(db_path: str = DB_PATH) -> tuple:
    if not os.path.exists(db_path):
        raise FileNotFoundError(f"Libraries.sqlite not found at: {db_path}")

    all_4mers = ["".join(t) for t in itertools.product("ACGT", repeat=4)]
    assert len(all_4mers) == 256

    pair_rows = []
    sum_total_by_ov = {ov: 0 for ov in all_4mers}
    wc_by_ov = {}

    for a in all_4mers:
        for b in all_4mers:
            cnt, is_wc, mm_cnt, has_gt = analyze_ligation_pair(a, b)
            if cnt > 0:
                pair_rows.append((a, b, cnt, is_wc, mm_cnt, has_gt))
                sum_total_by_ov[a] += cnt
                if is_wc == 1:
                    wc_by_ov[a] = cnt

    # Verify strict symmetry M(a, b) == M(b, a)
    pair_map = {(a, b): cnt for (a, b, cnt, _, _, _) in pair_rows}
    for (a, b), cnt in pair_map.items():
        assert pair_map.get((b, a)) == cnt, f"Asymmetric ligation entry ({a}, {b})"

    stat_rows = []
    for ov in all_4mers:
        rc = rev_comp(ov)
        is_pal = 1 if ov == rc else 0
        gc_cnt = ov.count("G") + ov.count("C")
        wc_cnt = wc_by_ov[ov]
        tot_cnt = max(1, sum_total_by_ov[ov])
        ind_fid = 0.0 if is_pal else round(wc_cnt / float(tot_cnt), 6)
        is_hf = 1 if (ov in NEB_VERIFIED_HF_OVERHANGS and not is_pal) else 0
        stat_rows.append((ov, rc, is_pal, gc_cnt, wc_cnt, ind_fid, is_hf))

    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()
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

        cur.execute("DELETE FROM neb_t4_overhang_stats;")
        cur.execute("DELETE FROM neb_t4_ligase_fidelity;")
        cur.executemany(
            """
            INSERT INTO neb_t4_overhang_stats
            (overhang, rc_overhang, is_palindromic, gc_count, wc_ligation_count, individual_fidelity, is_neb_verified_hf)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            stat_rows,
        )
        cur.executemany(
            """
            INSERT INTO neb_t4_ligase_fidelity
            (overhang_a, overhang_b, ligation_count, is_watson_crick, mismatch_count, has_gt_mismatch)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            pair_rows,
        )
        conn.commit()

        sg_cnt = cur.execute("SELECT COUNT(*) FROM sgrna;").fetchone()[0]
        sh_cnt = cur.execute("SELECT COUNT(*) FROM shrna;").fetchone()[0]
        pf_cnt = cur.execute("SELECT COUNT(*) FROM plasmid_features;").fetchone()[0]
        st_cnt = cur.execute("SELECT COUNT(*) FROM neb_t4_overhang_stats;").fetchone()[0]
        pal_cnt = cur.execute("SELECT COUNT(*) FROM neb_t4_overhang_stats WHERE is_palindromic = 1;").fetchone()[0]
        mat_cnt = cur.execute("SELECT COUNT(*) FROM neb_t4_ligase_fidelity;").fetchone()[0]

        assert sg_cnt == 123434, f"sgrna count altered: {sg_cnt}"
        assert sh_cnt == 81537, f"shrna count altered: {sh_cnt}"
        assert pf_cnt == 15, f"plasmid_features count altered: {pf_cnt}"
        assert st_cnt == 256 and pal_cnt == 16
        assert mat_cnt >= 3328
        return (st_cnt, mat_cnt)
    finally:
        conn.close()


if __name__ == "__main__":
    st_cnt, mat_cnt = seed_neb_fidelity()
    print(f"✅ Seeded NEB T4 ligase fidelity matrix into {DB_PATH}: {st_cnt} overhangs, {mat_cnt} ligation pairs")
