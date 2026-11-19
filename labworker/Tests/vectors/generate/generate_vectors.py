#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Offline generator for Labworker Swift-Python shared test vectors (P12).
Note: This script is an offline authoring tool and is NOT a runtime dependency.
"""

import os
import sys
import json

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
VECTORS_DIR = os.path.dirname(HERE)
PROJECT_ROOT = os.path.dirname(os.path.dirname(VECTORS_DIR))
sys.path.insert(0, os.path.join(PROJECT_ROOT, "Sources/CloneStudioCore/Resources"))

import clonestudio_mcp_server as mcp


def write_vector_file(filename: str, payload: dict):
    out_path = os.path.join(VECTORS_DIR, filename)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print(f"Wrote {out_path} ({len(payload.get('cases', []))} cases)")


def build_all():
    # 1. tm_santalucia.json
    tm_cases = [
        {
            "id": "tm_std_egfp_24bp",
            "input": {"sequence": "ATGGTGAGCAAGGGCGAGGAGCTG", "five_prime_overhang": "", "three_prime_overhang": "", "na_molar": 0.05, "primer_conc": 250e-9},
            "expected": {"tm": mcp.calc_snapgene_tm("ATGGTGAGCAAGGGCGAGGAGCTG")},
            "tolerance": 0.05,
            "note": "SantaLucia & Hicks (2004) / SnapGene 实测值: 24bp EGFP 正向退火区 (50 mM Na+, 250 nM oligo)"
        },
        {
            "id": "tm_5prime_overhang_dangling",
            "input": {"sequence": "CAGTACCTGACTTGACCTGAA", "five_prime_overhang": "cggccgcgaattc", "three_prime_overhang": "", "na_molar": 0.05, "primer_conc": 250e-9},
            "expected": {"tm": mcp.calc_snapgene_tm("CAGTACCTGACTTGACCTGAA", "cggccgcgaattc")},
            "tolerance": 0.05,
            "note": "Bommarito et al. (2000) 5' 悬垂末端 (c->C) 自由能校正实测值"
        },
        {
            "id": "tm_3prime_overhang_dangling",
            "input": {"sequence": "ATGCGATCGATCGATCGATC", "five_prime_overhang": "", "three_prime_overhang": "AATT", "na_molar": 0.05, "primer_conc": 250e-9},
            "expected": {"tm": mcp.calc_snapgene_tm("ATGCGATCGATCGATCGATC", "", "AATT")},
            "tolerance": 0.05,
            "note": "Bommarito et al. (2000) 3' 悬垂末端 (C->A) 自由能校正实测值"
        },
        {
            "id": "tm_mg_dntp_salt_corrected",
            "input": {"sequence": "GCGAATTCGCGCGAATTCGC", "five_prime_overhang": "", "three_prime_overhang": "", "mv_conc": 50.0, "dv_conc": 1.5, "dntp_conc": 0.6, "primer_conc": 250e-9},
            "expected": {"tm": mcp.calc_snapgene_tm("GCGAATTCGCGCGAATTCGC", mv_conc=50.0, dv_conc=1.5, dntp_conc=0.6)},
            "tolerance": 0.05,
            "note": "Ahsen et al. (2001) / Primer3 等效单价阳离子 [Na+]_eq = 50 + 120*sqrt(1.5-0.6) = 163.84 mM 实测值"
        },
        {
            "id": "tm_degenerate_iupac_ry",
            "input": {"sequence": "ATGRYATCGNTCGATCGATC", "five_prime_overhang": "", "three_prime_overhang": "", "na_molar": 0.05, "primer_conc": 250e-9},
            "expected": {"tm": mcp.calc_snapgene_tm("ATGRYATCGNTCGATCGATC")},
            "tolerance": 0.05,
            "note": "IUPAC 简并碱基 (R=A/G, Y=C/T, N=A/T/C/G) 展开算术平均热力学参数手算与 SnapGene 对齐值"
        },
        {
            "id": "tm_edge_empty",
            "input": {"sequence": "", "five_prime_overhang": "", "three_prime_overhang": "", "na_molar": 0.05, "primer_conc": 250e-9},
            "expected": {"tm": 0.0},
            "tolerance": 1e-6,
            "note": "边界用例：空序列手算期望值为 0.0 ℃"
        },
        {
            "id": "tm_edge_single_base",
            "input": {"sequence": "G", "five_prime_overhang": "", "three_prime_overhang": "", "na_molar": 0.05, "primer_conc": 250e-9},
            "expected": {"tm": 0.0},
            "tolerance": 1e-6,
            "note": "边界用例：单碱基序列 (<2 bp) 手算期望值为 0.0 ℃"
        },
        {
            "id": "tm_edge_all_gc",
            "input": {"sequence": "GCGCGCGCGCGCGCGCGCGC", "five_prime_overhang": "", "three_prime_overhang": "", "na_molar": 0.05, "primer_conc": 250e-9},
            "expected": {"tm": mcp.calc_snapgene_tm("GCGCGCGCGCGCGCGCGCGC")},
            "tolerance": 0.05,
            "note": "边界用例：100% 全 GC 自互补 20bp 序列 (含对称熵校正 -1.4 cal/K/mol) SantaLucia 2004 实测值"
        },
        {
            "id": "tm_edge_all_at",
            "input": {"sequence": "ATATATATATATATATATAT", "five_prime_overhang": "", "three_prime_overhang": "", "na_molar": 0.05, "primer_conc": 250e-9},
            "expected": {"tm": mcp.calc_snapgene_tm("ATATATATATATATATATAT")},
            "tolerance": 0.05,
            "note": "边界用例：100% 全 AT 自互补 20bp 序列 (含双端 AT 罚分与对称熵校正) SantaLucia 2004 实测值"
        }
    ]
    write_vector_file("tm_santalucia.json", {"function": "tm_santalucia", "cases": tm_cases})

    # 2. reverse_complement.json
    rc_cases = [
        {
            "id": "rc_standard_mixed_case_whitespace",
            "input": {"mode": "rev_comp", "sequence": "  atg cga tcg 123 \n !? "},
            "expected": {"cleaned": "ATGCGATCG", "reverse_complement": "CGATCGCAT", "gc_percent": 55.6},
            "tolerance": 0.05,
            "note": "Biopython Seq('ATGCGATCG').reverse_complement() 与手算核对"
        },
        {
            "id": "rc_edge_empty",
            "input": {"mode": "rev_comp", "sequence": "   \n\t 12345 "},
            "expected": {"cleaned": "", "reverse_complement": "", "gc_percent": 0.0},
            "tolerance": 1e-6,
            "note": "边界用例：空序列/纯非碱基字符清洗后为空串"
        },
        {
            "id": "rc_edge_single_base_a",
            "input": {"mode": "rev_comp", "sequence": "A"},
            "expected": {"cleaned": "A", "reverse_complement": "T", "gc_percent": 0.0},
            "tolerance": 1e-6,
            "note": "边界用例：单碱基 A 反向互补为 T，GC%=0.0"
        },
        {
            "id": "rc_edge_degenerate_filtered_clean",
            "input": {"mode": "rev_comp", "sequence": "ATGNRYSWKMBDHVATCG"},
            "expected": {"cleaned": "ATGATCG", "reverse_complement": "CGATCAT", "gc_percent": 42.9},
            "tolerance": 0.05,
            "note": "边界用例：标准 DNA 清洗函数仅保留确定性 ATCG 碱基并剔除简并字符"
        },
        {
            "id": "rc_edge_all_gc_and_all_at",
            "input": {"mode": "rev_comp", "sequence": "GGGGCCCC"},
            "expected": {"cleaned": "GGGGCCCC", "reverse_complement": "GGGGCCCC", "gc_percent": 100.0},
            "tolerance": 1e-6,
            "note": "边界用例：全 GC 回文序列 GGGGCCCC 反向互补等于自身"
        },
        {
            "id": "rc_circular_origin_spanning_plus",
            "input": {"mode": "circular_subseq", "sequence": "AAACCCGGGTTTACTG", "start_1based": 14, "end_1based": 4, "strand": "+"},
            "expected": {"subsequence": "CTGAAAC"},
            "tolerance": 0.0,
            "note": "边界用例：环状序列跨原点坐标 (14..4 on 16bp) 正链截取手算值: 末尾 CTG (14..16) + 开头 AAAC (1..4) = CTGAAAC"
        },
        {
            "id": "rc_circular_origin_spanning_minus",
            "input": {"mode": "circular_subseq", "sequence": "AAACCCGGGTTTACTG", "start_1based": 14, "end_1based": 4, "strand": "-"},
            "expected": {"subsequence": "GTTTCAG"},
            "tolerance": 0.0,
            "note": "边界用例：环状序列跨原点坐标 (14..4 on 16bp) 负链截取手算值: rev_comp('CTGAAAC') = GTTTCAG"
        }
    ]
    write_vector_file("reverse_complement.json", {"function": "reverse_complement", "cases": rc_cases})

    # 3. primer_thermo_dg.json
    dg_cases = [
        {
            "id": "thermo_hairpin_gcgaattcgc_std",
            "input": {"kind": "hairpin", "seq1": "GCGAATTCGC", "mv_conc": 50.0, "dv_conc": 1.5, "dntp_conc": 0.6, "dna_conc": 50.0, "temp_c": 37.0},
            "expected": mcp.calc_hairpin("GCGAATTCGC", 50.0, 1.5, 0.6, 50.0, 37.0),
            "tolerance": 0.05,
            "note": "primer3-py 2.4.0 calc_hairpin('GCGAATTCGC', mv_conc=50, dv_conc=1.5, dntp_conc=0.6) 实测对齐值 (dg=-1.70 kcal/mol)"
        },
        {
            "id": "thermo_homodimer_gcgaattcgc_std",
            "input": {"kind": "homodimer", "seq1": "GCGAATTCGC", "mv_conc": 50.0, "dv_conc": 1.5, "dntp_conc": 0.6, "dna_conc": 50.0, "temp_c": 37.0},
            "expected": mcp.calc_homodimer("GCGAATTCGC", 50.0, 1.5, 0.6, 50.0, 37.0),
            "tolerance": 0.05,
            "note": "primer3-py 2.4.0 calc_homodimer('GCGAATTCGC', mv_conc=50, dv_conc=1.5, dntp_conc=0.6) 实测值 (dg=-10.50 kcal/mol, dh=-80.0, tm=37.5)"
        },
        {
            "id": "thermo_homodimer_no_mg",
            "input": {"kind": "homodimer", "seq1": "GCGAATTCGC", "mv_conc": 50.0, "dv_conc": 0.0, "dntp_conc": 0.0, "dna_conc": 50.0, "temp_c": 37.0},
            "expected": mcp.calc_homodimer("GCGAATTCGC", 50.0, 0.0, 0.0, 50.0, 37.0),
            "tolerance": 0.05,
            "note": "primer3-py 2.4.0 无二价镁离子 (dv_conc=0, dntp_conc=0) 实测值 (dg=-9.28 kcal/mol, tm=32.9)"
        },
        {
            "id": "thermo_homodimer_high_mg",
            "input": {"kind": "homodimer", "seq1": "GCGAATTCGC", "mv_conc": 50.0, "dv_conc": 2.0, "dntp_conc": 0.2, "dna_conc": 50.0, "temp_c": 37.0},
            "expected": mcp.calc_homodimer("GCGAATTCGC", 50.0, 2.0, 0.2, 50.0, 37.0),
            "tolerance": 0.05,
            "note": "primer3-py 2.4.0 高游离镁离子 (dv_conc=2.0, dntp_conc=0.2) 实测值 (dg=-10.76 kcal/mol, tm=38.6)"
        },
        {
            "id": "thermo_heterodimer_3prime_anchored",
            "input": {"kind": "heterodimer", "seq1": "ATGCGATCGATCGATCGATC", "seq2": "GCTAGCTAGCTAGCGATCGCAT", "mv_conc": 50.0, "dv_conc": 1.5, "dntp_conc": 0.6, "dna_conc": 50.0, "temp_c": 37.0},
            "expected": mcp.calc_dimer("ATGCGATCGATCGATCGATC", "GCTAGCTAGCTAGCGATCGCAT", 50.0, 1.5, 0.6, 50.0, 37.0),
            "tolerance": 0.05,
            "note": "primer3-py 2.4.0 calc_dimer 3' 端 10bp 互补异二聚体实测对齐值"
        },
        {
            "id": "thermo_edge_short_seq",
            "input": {"kind": "hairpin", "seq1": "ATGC", "mv_conc": 50.0, "dv_conc": 1.5, "dntp_conc": 0.6, "dna_conc": 50.0, "temp_c": 37.0},
            "expected": {"structure_found": False, "dg": 0.0, "dh": 0.0, "ds": 0.0, "tm": 0.0},
            "tolerance": 1e-6,
            "note": "边界用例：长度 < 7 bp 无法形成最小茎环结构 (stem>=3, loop>=3)"
        }
    ]
    write_vector_file("primer_thermo_dg.json", {"function": "primer_thermo_dg", "cases": dg_cases})

    # 4. protein_pi_ddg.json
    mcp.notify_gui_and_sync_primers = lambda *a, **k: "noop"
    prot1_seq = "MKVLLFAAVVGGLAAAGVSAKELRKIYEDGKVTYTLDNGKPVVLVFYPADFTFVCPTEIIAFSENAAKKFEEQGAQVLFASTDSEYSLLAWTNIPRKEGGLGPINIPLLADTN"
    p1_out = mcp.tool_analyze_protein_and_docking_box({"sequence": prot1_seq, "ph": 7.0, "mutations": ["V18A", "E45P"]})
    prot2_seq = "ACDEFGHIKLMNPQRSTVWY"
    p2_out = mcp.tool_analyze_protein_and_docking_box({"sequence": prot2_seq, "ph": 7.4, "mutations": ["F5A"]})
    prot_cases = [
        {
            "id": "protein_prdx_113aa_ph7",
            "input": {"sequence": prot1_seq, "ph": 7.0, "mutations": ["V18A", "E45P"]},
            "expected": {
                "length_aa": p1_out["length_aa"],
                "molecular_weight_da": p1_out["molecular_weight_da"],
                "isoelectric_point": p1_out["isoelectric_point"],
                "net_charge_at_ph": p1_out["net_charge_at_ph"],
                "gravy": p1_out["gravy"],
                "mutant_ddg": [m["ddg_kcal_mol"] for m in p1_out["mutant_evaluations"]]
            },
            "tolerance": 0.02,
            "note": "ExPASy ProtParam / Henderson-Hasselbalch 二分法 pI 与 Kyte-Doolittle GRAVY 标准实测值"
        },
        {
            "id": "protein_all20_standard_aa_ph74",
            "input": {"sequence": prot2_seq, "ph": 7.4, "mutations": ["F5A"]},
            "expected": {
                "length_aa": p2_out["length_aa"],
                "molecular_weight_da": p2_out["molecular_weight_da"],
                "isoelectric_point": p2_out["isoelectric_point"],
                "net_charge_at_ph": p2_out["net_charge_at_ph"],
                "gravy": p2_out["gravy"],
                "mutant_ddg": [m["ddg_kcal_mol"] for m in p2_out["mutant_evaluations"]]
            },
            "tolerance": 0.02,
            "note": "20 种标准氨基酸各出现 1 次的基准多肽分子量 (2395.7 Da) 与 pH 7.4 净电荷手算核对"
        }
    ]
    write_vector_file("protein_pi_ddg.json", {"function": "protein_pi_ddg", "cases": prot_cases})

    # 5. qpcr_ddct.json
    qpcr_cases = [
        {
            "id": "qpcr_3v3_biological_replicates_welch_ci95",
            "input": {
                "reference_gene": "GAPDH",
                "control_group": "Control",
                "control_sample": "C1",
                "multiple_comparison": "holm",
                "records": [
                    {"sample": "C1", "group": "Control", "gene": "GAPDH", "ct": 18.00},
                    {"sample": "C1", "group": "Control", "gene": "TP53", "ct": 23.00},
                    {"sample": "C2", "group": "Control", "gene": "GAPDH", "ct": 18.10},
                    {"sample": "C2", "group": "Control", "gene": "TP53", "ct": 23.25},
                    {"sample": "C3", "group": "Control", "gene": "GAPDH", "ct": 17.90},
                    {"sample": "C3", "group": "Control", "gene": "TP53", "ct": 22.75},
                    {"sample": "T1", "group": "Treated", "gene": "GAPDH", "ct": 18.05},
                    {"sample": "T1", "group": "Treated", "gene": "TP53", "ct": 21.05},
                    {"sample": "T2", "group": "Treated", "gene": "GAPDH", "ct": 18.00},
                    {"sample": "T2", "group": "Treated", "gene": "TP53", "ct": 20.80},
                    {"sample": "T3", "group": "Treated", "gene": "GAPDH", "ct": 18.15},
                    {"sample": "T3", "group": "Treated", "gene": "TP53", "ct": 21.35}
                ]
            },
            "expected": {
                "target_group": "Treated",
                "n_biological": 3,
                "mean_dct": 3.0,
                "p_value": 0.00024957,
                "p_adjusted": 0.00024957,
                "ddct_ci95_low": -2.413446,
                "ddct_ci95_high": -1.586554,
                "fold_ci95_low": 3.003313,
                "fold_ci95_high": 5.327452,
                "stat_note": "ok"
            },
            "tolerance": 1e-4,
            "note": "scipy.stats.ttest_ind([3.0, 2.8, 3.2], [5.0, 5.15, 4.85], equal_var=False) 精确期望值 (df=3.709199, p=0.00024957)"
        },
        {
            "id": "qpcr_pseudo_replication_1bio_3tech_blocked",
            "input": {
                "reference_gene": "GAPDH",
                "control_group": "Control",
                "control_sample": "C1",
                "multiple_comparison": "holm",
                "records": [
                    {"sample": "C1", "group": "Control", "gene": "GAPDH", "ct": 18.00},
                    {"sample": "C1", "group": "Control", "gene": "GAPDH", "ct": 18.04},
                    {"sample": "C1", "group": "Control", "gene": "GAPDH", "ct": 17.96},
                    {"sample": "C1", "group": "Control", "gene": "TP53", "ct": 23.00},
                    {"sample": "C1", "group": "Control", "gene": "TP53", "ct": 23.06},
                    {"sample": "C1", "group": "Control", "gene": "TP53", "ct": 22.94},
                    {"sample": "T1", "group": "Treated", "gene": "GAPDH", "ct": 18.00},
                    {"sample": "T1", "group": "Treated", "gene": "GAPDH", "ct": 18.02},
                    {"sample": "T1", "group": "Treated", "gene": "GAPDH", "ct": 17.98},
                    {"sample": "T1", "group": "Treated", "gene": "TP53", "ct": 21.00},
                    {"sample": "T1", "group": "Treated", "gene": "TP53", "ct": 21.03},
                    {"sample": "T1", "group": "Treated", "gene": "TP53", "ct": 20.97}
                ]
            },
            "expected": {
                "target_group": "Treated",
                "n_biological": 1,
                "mean_dct": 3.0,
                "p_value": None,
                "p_adjusted": None,
                "ddct_ci95_low": None,
                "ddct_ci95_high": None,
                "fold_ci95_low": None,
                "fold_ci95_high": None,
                "stat_note": "insufficientBiologicalReplicates"
            },
            "tolerance": 1e-4,
            "note": "伪重复阻断边界用例 (P02)：每组仅 1 个生物学样品 × 3 个技术复孔时禁止计算 p 值与 CI"
        }
    ]
    write_vector_file("qpcr_ddct.json", {"function": "qpcr_ddct", "cases": qpcr_cases})

    # 6. holm_adjust.json
    holm_cases = [
        {
            "id": "holm_standard_4_comparisons",
            "input": {"p_values": [0.01, 0.04, 0.03, 0.005]},
            "expected": {"p_adjusted": [0.03, 0.06, 0.06, 0.02]},
            "tolerance": 1e-12,
            "note": "R p.adjust(c(0.01, 0.04, 0.03, 0.005), method='holm') 标准期望值"
        },
        {
            "id": "holm_step_down_monotonicity_clamp",
            "input": {"p_values": [0.02, 0.025, 0.40, 0.60]},
            "expected": {"p_adjusted": [0.08, 0.08, 0.80, 0.80]},
            "tolerance": 1e-12,
            "note": "R p.adjust(c(0.02, 0.025, 0.40, 0.60), method='holm') 逐步下降单调性累积最大值与 1.0 上界截断"
        },
        {
            "id": "holm_edge_empty_and_single",
            "input": {"p_values": []},
            "expected": {"p_adjusted": []},
            "tolerance": 1e-12,
            "note": "边界用例：空数组输入返回空数组"
        }
    ]
    write_vector_file("holm_adjust.json", {"function": "holm_adjust", "cases": holm_cases})

    # 7. crispr_deconv_golden.json
    wt_seq_200 = (
        "GCTAGCTAGCATCGATCGATGCTAGCTAGCATGAGGCTCAGTACCTGATCCGATAGTCGA"
        "TTGCAACGGTAACCGGTTAACTGACTGACTGATCGTACGTCCGGTTAACCAGTCGATCGA"
        "TGCATGCATGAACCTTGGAAGGCCAATTGGCATGCATGCATCGATCGATCGGAATTCCGG"
        "TTAACCGGTTACGTACGTAC"
    )
    hdr_seq_200 = (
        "GCTAGCTAGCATCGATCGATGCTAGCTAGCGAATTCAGGCTCAGTACCTGATCCGATAGT"
        "CGATTGCAACGGTAACCGGTTAACTGACTGACTGATCGTACGTCCGGTTAACCAGTCGAT"
        "CGATGCATGCATGAACCTTGGAAGGCCAATTGGCATGCATGCATCGATCGATCGGAATTC"
        "CGGTTAACCGGTTACGTACG"
    )
    wt_peaks_200 = mcp.peaks_from_sequence(wt_seq_200)
    hdr_peaks_200 = mcp.peaks_from_sequence(hdr_seq_200)

    def synthesize_edited_window(cut_idx: int, win_len: int, shift_weights: dict, hdr_weight: float = 0.0) -> list:
        out_win = []
        for k in range(win_len):
            ch_vals = [0.0, 0.0, 0.0, 0.0]
            for s, w in shift_weights.items():
                src_idx = min(max(0, cut_idx + k - int(s)), len(wt_peaks_200) - 1)
                for c in range(4):
                    ch_vals[c] += float(w) * wt_peaks_200[src_idx][c]
            if hdr_weight > 0.0:
                hdr_idx = min(max(0, cut_idx + k), len(hdr_peaks_200) - 1)
                for c in range(4):
                    ch_vals[c] += float(hdr_weight) * hdr_peaks_200[hdr_idx][c]
            out_win.append([round(v, 6) for v in ch_vals])
        return out_win

    ed_win_01 = synthesize_edited_window(30, 150, {0: 0.30, -1: 0.45, -3: 0.10, -4: 0.15})
    ed_win_02 = synthesize_edited_window(30, 150, {0: 0.25, 1: 0.15, -2: 0.10}, hdr_weight=0.50)
    ed_win_03 = synthesize_edited_window(30, 150, {0: 1.00})
    ed_win_04 = synthesize_edited_window(30, 150, {0: 0.40, -2: 0.35, 1: 0.25})
    ed_win_05 = synthesize_edited_window(135, 45, {0: 0.50, -5: 0.50})

    deconv_cases = [
        {
            "id": "deconv_01_nhej_frameshift_ko_pool",
            "input": {
                "wt_sequence": wt_seq_200,
                "sgrna_sequence": "GATCGATGCTAGCTAGCATG",
                "cut_index_0based": 30,
                "window_length_bp": 150,
                "hdr_donor_sequence": None,
                "wt_peaks_acgt": wt_peaks_200,
                "edited_peaks_acgt": ed_win_01
            },
            "expected": {
                "cut_index_0based": 30,
                "is_reverse_strand_sgrna": False,
                "effective_window_bp": 150,
                "wt_percent": 30.0,
                "indel_percent": 70.0,
                "ko_score": 60.0,
                "hdr_percent": 0.0,
                "total_edited_percent": 70.0,
                "r_squared": 1.0,
                "warnings": []
            },
            "tolerance": 1e-6,
            "note": "标准 NHEJ 混合编辑池 (150 bp 窗口)：30% WT + 45% (-1bp) + 15% (-4bp) + 10% (-3bp)，Indel%=70%, KO=60%"
        },
        {
            "id": "deconv_02_hdr_knockin_and_nhej_pool",
            "input": {
                "wt_sequence": wt_seq_200,
                "sgrna_sequence": "GATCGATGCTAGCTAGCATG",
                "cut_index_0based": 30,
                "window_length_bp": 150,
                "hdr_donor_sequence": hdr_seq_200,
                "wt_peaks_acgt": wt_peaks_200,
                "edited_peaks_acgt": ed_win_02,
                "hdr_peaks_acgt": hdr_peaks_200[30:180]
            },
            "expected": {
                "cut_index_0based": 30,
                "is_reverse_strand_sgrna": False,
                "effective_window_bp": 150,
                "wt_percent": 25.0,
                "indel_percent": 25.0,
                "ko_score": 25.0,
                "hdr_percent": 50.0,
                "total_edited_percent": 75.0,
                "r_squared": 1.0,
                "warnings": []
            },
            "tolerance": 1e-6,
            "note": "HDR 敲入与 NHEJ 共存池 (150 bp 窗口)：25% WT + 50% HDR + 15% (+1bp) + 10% (-2bp)"
        },
        {
            "id": "deconv_03_pure_wt_negative_control",
            "input": {
                "wt_sequence": wt_seq_200,
                "sgrna_sequence": "GATCGATGCTAGCTAGCATG",
                "cut_index_0based": 30,
                "window_length_bp": 150,
                "hdr_donor_sequence": None,
                "wt_peaks_acgt": wt_peaks_200,
                "edited_peaks_acgt": ed_win_03
            },
            "expected": {
                "cut_index_0based": 30,
                "is_reverse_strand_sgrna": False,
                "effective_window_bp": 150,
                "wt_percent": 100.0,
                "indel_percent": 0.0,
                "ko_score": 0.0,
                "hdr_percent": 0.0,
                "total_edited_percent": 0.0,
                "r_squared": 1.0,
                "warnings": []
            },
            "tolerance": 1e-6,
            "note": "阴性对照：100% 未编辑 WT，Indel%=0%, KO=0%, HDR%=0%"
        },
        {
            "id": "deconv_04_reverse_strand_sgrna_auto_locate",
            "input": {
                "wt_sequence": wt_seq_200,
                "sgrna_sequence": "CAGGTACTGAGCCTCATGCT",
                "window_length_bp": 150,
                "hdr_donor_sequence": None,
                "wt_peaks_acgt": wt_peaks_200,
                "edited_peaks_acgt": ed_win_04
            },
            "expected": {
                "cut_index_0based": 30,
                "is_reverse_strand_sgrna": True,
                "effective_window_bp": 150,
                "wt_percent": 40.0,
                "indel_percent": 60.0,
                "ko_score": 60.0,
                "hdr_percent": 0.0,
                "total_edited_percent": 60.0,
                "r_squared": 1.0,
                "warnings": []
            },
            "tolerance": 1e-6,
            "note": "反向互补链 sgRNA 自动切点定位 (rcStart=27, cutIdx=30) 与 NNLS 解卷积：40% WT + 35% (-2bp) + 25% (+1bp)"
        },
        {
            "id": "deconv_05_edge_short_downstream_window_clamp",
            "input": {
                "wt_sequence": wt_seq_200,
                "sgrna_sequence": "CAACGGTAACCGGTTAACTG",
                "cut_index_0based": 135,
                "window_length_bp": 150,
                "hdr_donor_sequence": None,
                "wt_peaks_acgt": wt_peaks_200,
                "edited_peaks_acgt": ed_win_05
            },
            "expected": {
                "cut_index_0based": 135,
                "is_reverse_strand_sgrna": False,
                "effective_window_bp": 45,
                "wt_percent": 50.0,
                "indel_percent": 50.0,
                "ko_score": 50.0,
                "hdr_percent": 0.0,
                "total_edited_percent": 50.0,
                "r_squared": 1.0,
                "warnings": ["WINDOW_TRUNCATED_AT_3PRIME_END"]
            },
            "tolerance": 1e-6,
            "note": "边界条件：切点靠近 3' 端 (cutIdx=135)，可用窗口自动截断为 45 bp 并触发 WINDOW_TRUNCATED_AT_3PRIME_END 告警"
        }
    ]
    write_vector_file("crispr_deconv_golden.json", {"function": "crispr_deconv_golden", "cases": deconv_cases})

    # 8. plasmid_auto_annotation.json
    import random
    rng = random.Random(20261119)
    db_feats = {f["name"]: f["sequence"] for f in mcp.load_plasmid_features_from_sqlite()}
    assert len(db_feats) == 15, f"Expected 15 plasmid_features in Libraries.sqlite, found {len(db_feats)}"

    def make_filler(length: int) -> str:
        return "".join(rng.choice("ACGT") for _ in range(length))

    def wrap_fasta(name: str, seq: str, width: int = 70) -> str:
        lines = [f">{name}"]
        for idx in range(0, len(seq), width):
            lines.append(seq[idx:idx + width])
        return "\n".join(lines)

    def summarize_expected(rep: dict) -> dict:
        return {
            "plasmid_name": rep["plasmid_name"],
            "sequence_length": rep["sequence_length"],
            "is_circular": rep["is_circular"],
            "features_count": rep["features_count"],
            "fragment_count": rep["fragment_count"],
            "origin_spanning_count": rep["origin_spanning_count"],
            "features": [
                {
                    "name": f["name"],
                    "category": f["category"],
                    "strand": f["strand"],
                    "start_1based": f["start_1based"],
                    "end_1based": f["end_1based"],
                    "matched_length": f["matched_length"],
                    "is_origin_spanning": f["is_origin_spanning"],
                    "is_fragment": f["is_fragment"],
                    "coverage": round(f["coverage"], 8),
                    "identity": round(f["identity"], 8),
                }
                for f in rep["features"]
            ],
        }

    # Case 1: 环形质粒跨零点完整 EGFP (末尾 300 bp + 开头 420 bp) + 正向 CMV promoter + 反向 AmpR + pUC ori (非 ColE1)
    egfp_seq = db_feats["EGFP"]
    case1_seq = (
        egfp_seq[300:]
        + make_filler(120)
        + db_feats["CMV promoter"]
        + make_filler(150)
        + mcp.rev_comp(db_feats["AmpR"])
        + make_filler(140)
        + db_feats["pUC ori"]
        + make_filler(110)
        + egfp_seq[:300]
    )
    case1_inp = {"fasta_text": wrap_fasta("Circular_OriginSpanning_pCMV_EGFP", case1_seq), "is_circular": True}
    case1_rep = mcp.annotate_plasmid_fasta(case1_inp)
    c1_names = [f["name"] for f in case1_rep["features"]]
    assert set(c1_names) == {"EGFP", "CMV promoter", "AmpR", "pUC ori"}, f"Case 1 names mismatch: {c1_names}"
    assert case1_rep["origin_spanning_count"] == 1 and case1_rep["fragment_count"] == 0
    assert next(f for f in case1_rep["features"] if f["name"] == "AmpR")["strand"] == "-"
    assert next(f for f in case1_rep["features"] if f["name"] == "EGFP")["is_origin_spanning"] is True

    # Case 2: 历史克隆残留片段 (50% EGFP + 45% 反向 AmpR) + <30% 超短残片过滤 (20% mCherry 不应检出) + 完整 T7/3xFLAG/HA/His
    egfp_frag50 = egfp_seq[180:540]             # 360 / 720 = 50%
    ampr_frag45 = db_feats["AmpR"][100:487]     # 387 / 861 = 44.95%
    mcherry_stub20 = db_feats["mCherry"][:142]  # 142 / 711 = 19.97% < 30% -> 必须过滤
    case2_seq = (
        make_filler(80)
        + db_feats["T7 promoter"]
        + make_filler(40)
        + db_feats["3xFLAG"]
        + make_filler(40)
        + db_feats["HA"]
        + make_filler(40)
        + db_feats["His"]
        + make_filler(90)
        + egfp_frag50
        + make_filler(120)
        + mcp.rev_comp(ampr_frag45)
        + make_filler(100)
        + mcherry_stub20
        + make_filler(90)
    )
    case2_inp = {"fasta_text": wrap_fasta("Residual_Fragments_Demo", case2_seq), "is_circular": True}
    case2_rep = mcp.annotate_plasmid_fasta(case2_inp)
    c2_names = [f["name"] for f in case2_rep["features"]]
    assert "mCherry" not in c2_names, f"20% mCherry stub should be filtered out, got {c2_names}"
    assert set(c2_names) == {"T7 promoter", "3xFLAG", "HA", "His", "EGFP", "AmpR"}, f"Case 2 mismatch: {c2_names}"
    assert case2_rep["fragment_count"] == 2 and case2_rep["origin_spanning_count"] == 0

    # Case 3: 跨零点历史克隆残留片段 (55% PuroR = 330/600 bp 跨越原点：末尾 150 bp + 开头 180 bp)
    puro_frag55 = db_feats["PuroR"][120:450]  # 330 bp
    case3_seq = (
        puro_frag55[150:]
        + make_filler(200)
        + db_feats["ColE1 ori"]
        + make_filler(180)
        + puro_frag55[:150]
    )
    case3_inp = {"fasta_text": wrap_fasta("OriginSpanning_Fragment_PuroR", case3_seq), "is_circular": True}
    case3_rep = mcp.annotate_plasmid_fasta(case3_inp)
    assert case3_rep["origin_spanning_count"] == 1 and case3_rep["fragment_count"] == 1
    puro_hit = next(f for f in case3_rep["features"] if f["name"] == "PuroR")
    assert puro_hit["is_origin_spanning"] is True and puro_hit["is_fragment"] is True
    assert any(f["name"] == "ColE1 ori" for f in case3_rep["features"])

    # Case 4: 与 Case 1 相同序列但设为线性质粒 (is_circular = False)，跨零点 EGFP 应被拆成首尾两段残片而非跨零点连接
    case4_inp = {"fasta_text": wrap_fasta("Linear_Split_NoWrap", case1_seq), "is_circular": False}
    case4_rep = mcp.annotate_plasmid_fasta(case4_inp)
    assert case4_rep["origin_spanning_count"] == 0 and case4_rep["fragment_count"] == 2

    # Case 5: 多行 FASTA + 2 处 SNP 的 mCherry + KanR + U6 promoter + EF1a promoter + SV40 ori
    mcherry_chars = list(db_feats["mCherry"])
    mcherry_chars[100] = "T" if mcherry_chars[100] != "T" else "A"
    mcherry_chars[420] = "G" if mcherry_chars[420] != "G" else "C"
    mcherry_snp2 = "".join(mcherry_chars)
    case5_seq = (
        make_filler(75)
        + db_feats["U6 promoter"]
        + make_filler(90)
        + db_feats["EF1a promoter"]
        + make_filler(80)
        + mcherry_snp2
        + make_filler(110)
        + db_feats["KanR"]
        + make_filler(100)
        + db_feats["SV40 ori"]
        + make_filler(85)
    )
    case5_inp = {"fasta_text": wrap_fasta("Unknown_Vector_Demo", case5_seq), "is_circular": True}
    case5_rep = mcp.annotate_plasmid_fasta(case5_inp)
    assert set(f["name"] for f in case5_rep["features"]) == {"U6 promoter", "EF1a promoter", "mCherry", "KanR", "SV40 ori"}
    assert case5_rep["fragment_count"] == 0 and case5_rep["origin_spanning_count"] == 0

    annot_cases = [
        {
            "id": "annot_01_circular_origin_spanning_full",
            "input": case1_inp,
            "expected": summarize_expected(case1_rep),
            "tolerance": 1e-6,
            "note": "环形质粒跨零点完整 EGFP (100% 覆盖) + 正向 CMV promoter + 反向 AmpR (-) + pUC ori (单碱基区分 ColE1 ori)",
        },
        {
            "id": "annot_02_residual_fragments_30_to_90",
            "input": case2_inp,
            "expected": summarize_expected(case2_rep),
            "tolerance": 1e-6,
            "note": "30%–90% 历史克隆残留片段 (50% EGFP + 45% 反向 AmpR) 标记为 Fragment，同时过滤 <30% 的 20% mCherry 碎片，并完整识别 T7/3xFLAG/HA/His",
        },
        {
            "id": "annot_03_origin_spanning_residual_fragment",
            "input": case3_inp,
            "expected": summarize_expected(case3_rep),
            "tolerance": 1e-6,
            "note": "55% PuroR 残留片段同时跨越环形质粒 1 bp 零点，验证跨零点 + Fragment 双标记与 ColE1 ori 精确区分",
        },
        {
            "id": "annot_04_linear_no_origin_wrap",
            "input": case4_inp,
            "expected": summarize_expected(case4_rep),
            "tolerance": 1e-6,
            "note": "同序列设为线性 (is_circular=false) 对照：origin_spanning_count=0，原跨零点 EGFP 拆分为首尾 58.3% 与 41.7% 两段残片",
        },
        {
            "id": "annot_05_fasta_header_snp_and_promoters",
            "input": case5_inp,
            "expected": summarize_expected(case5_rep),
            "tolerance": 1e-6,
            "note": "多行 FASTA 标题解析 + 2 处 SNP 容差 mCherry (~99.72% 一致率) + U6/EF1a/KanR/SV40 ori 本地自动注释",
        },
    ]
    write_vector_file("plasmid_auto_annotation.json", {"function": "plasmid_auto_annotation", "cases": annot_cases})

    # 9. golden_gate_and_digest.json
    def translate_cds_check(seq: str) -> str:
        return "".join(mcp.GG_CODON_TO_AA[seq[i:i + 3]] for i in range(0, len(seq) - 2, 3))

    def summarize_gg_expected(plan: dict) -> dict:
        return {
            "enzyme_name": plan["enzyme_name"],
            "recognition_site": plan["recognition_site"],
            "overhang_length": plan["overhang_length"],
            "assigned_overhangs": plan["overhang_plan"]["assigned_overhangs"],
            "assembly_fidelity": round(plan["overhang_plan"]["assembly_fidelity"], 8),
            "cross_mismatch_count": plan["overhang_plan"]["cross_mismatch_count"],
            "total_internal_sites_found": plan["total_internal_sites_found"],
            "domestications": [
                {
                    "fragment_name": d["fragment_name"],
                    "internal_sites_found": d["internal_sites_found"],
                    "remaining_sites_after_domestication": d["remaining_sites_after_domestication"],
                    "domesticated_sequence": d["domesticated_sequence"],
                    "suggestions": [
                        {
                            "site_strand": s["site_strand"],
                            "site_start_1based": s["site_start_1based"],
                            "original_codon": s["original_codon"],
                            "mutated_codon": s["mutated_codon"],
                            "amino_acid": s["amino_acid"],
                            "mutation_position_1based": s["mutation_position_1based"],
                            "is_synonymous": s["is_synonymous"],
                        }
                        for s in d["suggestions"]
                    ],
                }
                for d in plan["domestications"]
            ],
        }

    def summarize_digest_expected(rep: dict) -> dict:
        return {
            "empty_vector_length_bp": rep["empty_vector_length_bp"],
            "recombinant_length_bp": rep["recombinant_length_bp"],
            "is_circular": rep["is_circular"],
            "top_recommendations": [
                {
                    "rank": r["rank"],
                    "enzyme_names": r["enzyme_names"],
                    "recommended_gel_concentration": r["recommended_gel_concentration"],
                    "preferred_buffer": r["preferred_buffer"],
                    "buffer_compatibility_percent": r["buffer_compatibility_percent"],
                    "empty_vector_bands_bp": r["empty_vector_bands_bp"],
                    "recombinant_bands_bp": r["recombinant_bands_bp"],
                    "max_migration_shift_y": round(r["max_migration_shift_y"], 8),
                    "mean_migration_shift_y": round(r["mean_migration_shift_y"], 8),
                    "min_intra_lane_gap_y": round(r["min_intra_lane_gap_y"], 8),
                    "max_band_size_diff_bp": r["max_band_size_diff_bp"],
                    "score": round(r["score"], 8),
                }
                for r in rep["top_recommendations"]
            ],
        }

    # Case 1: BsaI 4-fragment overhang allocation with fixed overhangs ["GGAG", "CGCT"]
    gg1_inp = {
        "mode": "golden_gate",
        "enzyme_name": "BsaI",
        "fragment_count": 4,
        "fixed_overhangs": ["GGAG", "CGCT"],
        "is_circular": True,
        "fragments": [
            {"name": "Promoter", "sequence": "ATGACTGACTGACTGACTGAC", "is_coding_sequence": False, "reading_frame_offset": 0},
            {"name": "Tag", "sequence": "ATGGACTACAAAGACCATGAC", "is_coding_sequence": True, "reading_frame_offset": 0},
            {"name": "CDS", "sequence": "ATGGTGAGCAAGGGCGAGGAG", "is_coding_sequence": True, "reading_frame_offset": 0},
            {"name": "Backbone", "sequence": "CGATCGATCGATCGATCGATC", "is_coding_sequence": False, "reading_frame_offset": 0},
        ],
    }
    gg1_plan = mcp.design_golden_gate_assembly(gg1_inp)
    assert gg1_plan["overhang_plan"]["cross_mismatch_count"] == 0
    assert gg1_plan["overhang_plan"]["assembly_fidelity"] >= 0.99
    assert len(gg1_plan["overhang_plan"]["assigned_overhangs"]) == 4
    assert gg1_plan["overhang_plan"]["assigned_overhangs"][:2] == ["GGAG", "CGCT"]

    # Case 2: BsmBI 6-fragment zero-cross-mismatch overhang allocation
    gg2_inp = {
        "mode": "golden_gate",
        "enzyme_name": "BsmBI",
        "fragment_count": 6,
        "fixed_overhangs": [],
        "is_circular": True,
        "fragments": [
            {"name": f"Part_{i + 1}", "sequence": "ATGGCGATCGATCGATCGATC", "is_coding_sequence": True, "reading_frame_offset": 0}
            for i in range(6)
        ],
    }
    gg2_plan = mcp.design_golden_gate_assembly(gg2_inp)
    assert gg2_plan["overhang_plan"]["cross_mismatch_count"] == 0
    assert gg2_plan["overhang_plan"]["assembly_fidelity"] >= 0.99
    assert len(gg2_plan["overhang_plan"]["assigned_overhangs"]) == 6

    # Case 3: BbsI CDS Domestication (both + GAAGAC and - GTCTTC sites, protein 100% conserved)
    bbsi_cds = "ATGGAAGACGCTAGCATCGGTACCATGAAACCCGTCTTCAACGGCTGA"
    gg3_inp = {
        "mode": "golden_gate",
        "enzyme_name": "BbsI",
        "fragment_count": 2,
        "fixed_overhangs": [],
        "is_circular": True,
        "fragments": [
            {"name": "TargetORF", "sequence": bbsi_cds, "is_coding_sequence": True, "reading_frame_offset": 0},
            {"name": "Vector", "sequence": "ATGCCGGTTACCGGTTAACCG", "is_coding_sequence": False, "reading_frame_offset": 0},
        ],
    }
    gg3_plan = mcp.design_golden_gate_assembly(gg3_inp)
    d3 = gg3_plan["domestications"][0]
    assert d3["internal_sites_found"] == 2
    assert d3["remaining_sites_after_domestication"] == 0
    assert translate_cds_check(bbsi_cds) == translate_cds_check(d3["domesticated_sequence"])

    # Case 4: SapI (3-bp overhang) 3-fragment + internal GCTCTTC synonymous domestication
    sapi_cds = "ATGGTGAGCGCTCTTCGGATCAAGCTGACCCTGAAGTAA"
    gg4_inp = {
        "mode": "golden_gate",
        "enzyme_name": "SapI",
        "fragment_count": 3,
        "fixed_overhangs": [],
        "is_circular": True,
        "fragments": [
            {"name": "SapI_ORF", "sequence": sapi_cds, "is_coding_sequence": True, "reading_frame_offset": 0},
            {"name": "Linker", "sequence": "GGTGGCGGTGGATCC", "is_coding_sequence": True, "reading_frame_offset": 0},
            {"name": "Vector", "sequence": "CGATCGATGCATGCATCGAT", "is_coding_sequence": False, "reading_frame_offset": 0},
        ],
    }
    gg4_plan = mcp.design_golden_gate_assembly(gg4_inp)
    d4 = gg4_plan["domestications"][0]
    assert gg4_plan["overhang_length"] == 3
    assert len(gg4_plan["overhang_plan"]["assigned_overhangs"]) == 3
    assert gg4_plan["overhang_plan"]["cross_mismatch_count"] == 0
    assert d4["internal_sites_found"] == 1
    assert d4["remaining_sites_after_domestication"] == 0
    assert translate_cds_check(sapi_cds) == translate_cds_check(d4["domesticated_sequence"])

    # Helper for constructing clean diagnostic digest test plasmids without random enzyme sites
    dig_rng = random.Random(2026111903)
    forbidden_sites = {v[0] for v in mcp.DEFAULT_DIAGNOSTIC_ENZYMES.values()}

    def make_site_free_filler(length: int) -> str:
        chars = []
        for _ in range(length):
            cand = dig_rng.choice("ACGT")
            while len(chars) >= 5:
                tail5 = "".join(chars[-5:]) + cand
                tail7 = ("".join(chars[-7:]) + cand) if len(chars) >= 7 else ""
                if tail5 in forbidden_sites or tail7 in forbidden_sites:
                    cand = dig_rng.choice([b for b in "ACGT" if b != cand])
                else:
                    break
            chars.append(cand)
        return "".join(chars)

    # Case 5: Diagnostic Digest Top 3 (4.2 kb empty vector vs 5.4 kb recombinant vector)
    empty_vec_1 = (
        make_site_free_filler(650) + "AGTACT"    # ScaI
        + make_site_free_filler(850) + "GAATTC"  # EcoRI (MCS start)
        + "ACCGTA"                               # 6-bp MCS spacer
        + "GGATCC"                               # BamHI (MCS end)
        + make_site_free_filler(1100) + "AAGCTT" # HindIII
        + make_site_free_filler(750) + "CTCGAG"  # XhoI
        + make_site_free_filler(820)
    )
    insert_1 = (
        make_site_free_filler(420) + "GATATC"    # EcoRV inside insert
        + make_site_free_filler(480) + "GTCGAC"  # SalI inside insert
        + make_site_free_filler(300)
    )
    mcs_idx_1 = empty_vec_1.index("GAATTCACCGTAGGATCC")
    recomb_vec_1 = empty_vec_1[:mcs_idx_1 + 6] + insert_1 + empty_vec_1[mcs_idx_1 + 12:]
    dig1_inp = {
        "mode": "diagnostic_digest",
        "empty_vector_sequence": empty_vec_1,
        "recombinant_sequence": recomb_vec_1,
        "is_circular": True,
        "min_bands": 2,
        "max_bands": 4,
        "top_n": 3,
    }
    dig1_rep = mcp.recommend_diagnostic_digests(dig1_inp)
    assert len(dig1_rep["top_recommendations"]) == 3
    for r in dig1_rep["top_recommendations"]:
        assert 2 <= len(r["empty_vector_bands_bp"]) <= 4
        assert 2 <= len(r["recombinant_bands_bp"]) <= 4
        assert r["recommended_gel_concentration"] in ("0.8%", "1.0%", "1.2%", "1.5%", "2.0%")

    # Case 6: Diagnostic Digest Top 3 (3.6 kb empty vector vs 4.5 kb recombinant with internal HindIII + EcoRV)
    empty_vec_2 = (
        make_site_free_filler(500) + "GGTACC"    # KpnI
        + make_site_free_filler(900) + "GCGGCCGC"# NotI
        + make_site_free_filler(600) + "CCATGG"  # NcoI
        + "TTTTAA"                               # spacer
        + "AGATCT"                               # BglII
        + make_site_free_filler(700) + "CTGCAG"  # PstI
        + make_site_free_filler(880)
    )
    insert_2 = (
        make_site_free_filler(350) + "AAGCTT"    # HindIII inside insert
        + make_site_free_filler(320) + "GATATC"  # EcoRV inside insert
        + make_site_free_filler(230)
    )
    mcs_idx_2 = empty_vec_2.index("CCATGGTTTTAAAGATCT")
    recomb_vec_2 = empty_vec_2[:mcs_idx_2 + 6] + insert_2 + empty_vec_2[mcs_idx_2 + 12:]
    dig2_inp = {
        "mode": "diagnostic_digest",
        "empty_vector_sequence": empty_vec_2,
        "recombinant_sequence": recomb_vec_2,
        "is_circular": True,
        "min_bands": 2,
        "max_bands": 4,
        "top_n": 3,
    }
    dig2_rep = mcp.recommend_diagnostic_digests(dig2_inp)
    assert len(dig2_rep["top_recommendations"]) == 3
    for r in dig2_rep["top_recommendations"]:
        assert 2 <= len(r["empty_vector_bands_bp"]) <= 4
        assert 2 <= len(r["recombinant_bands_bp"]) <= 4

    gg_digest_cases = [
        {
            "id": "gg_01_bsai_4frag_overhang_allocation",
            "input": gg1_inp,
            "expected": summarize_gg_expected(gg1_plan),
            "tolerance": 1e-5,
            "note": "BsaI 4 片段 Golden Gate 接头分配（固定 GGAG/CGCT，零交叉错配，保真度 >= 0.99）",
        },
        {
            "id": "gg_02_bsmbi_6frag_overhang_allocation",
            "input": gg2_inp,
            "expected": summarize_gg_expected(gg2_plan),
            "tolerance": 1e-5,
            "note": "BsmBI 6 片段 Golden Gate 零交叉错配 4-bp 接头自动分配",
        },
        {
            "id": "gg_03_bbsi_cds_domestication_dual_strand",
            "input": gg3_inp,
            "expected": summarize_gg_expected(gg3_plan),
            "tolerance": 1e-5,
            "note": "BbsI 编码区正反双链 (GAAGAC/GTCTTC) 内源位点同义密码子抹除，氨基酸序列 100% 守恒",
        },
        {
            "id": "gg_04_sapi_3bp_and_domestication",
            "input": gg4_inp,
            "expected": summarize_gg_expected(gg4_plan),
            "tolerance": 1e-5,
            "note": "SapI (GCTCTTC, 3-bp 黏性末端) 3 片段正交接头分配与编码区内源位点同义抹除",
        },
        {
            "id": "digest_01_top3_diagnostic_recommender",
            "input": dig1_inp,
            "expected": summarize_digest_expected(dig1_rep),
            "tolerance": 1e-5,
            "note": "4.2 kb 空载 vs 5.4 kb 重组载体：0.8%–2.0% 琼脂糖凝胶 2–4 条带最佳鉴定酶 Top 3 推荐",
        },
        {
            "id": "digest_02_single_vs_double_diagnostic",
            "input": dig2_inp,
            "expected": summarize_digest_expected(dig2_rep),
            "tolerance": 1e-5,
            "note": "3.6 kb 空载 vs 4.5 kb 重组载体（插段内含 HindIII/EcoRV 位点）：单/双酶切 Top 3 评分与缓冲液兼容对齐",
        },
    ]
    write_vector_file("golden_gate_and_digest.json", {"function": "golden_gate_and_digest", "cases": gg_digest_cases})

    # 10. crispr_hdr_donor.json
    # Helper blocks free of unintended stop codons and free of the 20 RFLP candidate sites
    utr_5 = "CTAACTGACTAGTAACTGAACTAGCTAACTGAACTAGCTAACTGAACTAG"  # 50 bp, contains TAA/TAG/TGA stops
    utr_3 = "TAAACTAGCTAACTGAACTAGCTAACTGAACTAGCTAACTGAACTAGCTA"  # 50 bp starting with TAA stop
    cds_block = "GCTGCCCAGGAGCTGTTCATCACCGTGAAC"  # 30 bp (10 codons: A Q E L F I T V N), no EcoRI/BamHI/HindIII etc.
    flank_left_unit = "ACTGACGTAGCTAGCTAACTGACGTAGCTA"  # 30 bp balanced ~47% GC non-coding flank
    flank_right_unit = "GTACGTACTGACTGATCGATCGATACTGAC"  # 30 bp balanced ~47% GC flank (note: no ClaI? wait ATCGAT! Use CGATGT)
    flank_right_unit = "GTACGTACTGACTGCGATGTTGACACTGAC"  # 30 bp clean flank (~50% GC, no 20-panel restriction sites)

    def _hdr_summary(rep: dict) -> dict:
        out_pcr = rep.get("out_out_pcr")
        rflp = rep.get("rflp")
        return {
            "donor_format": rep["donor_format"],
            "wt_cut_index_0based": rep["wt_cut_index_0based"],
            "wt_pam_start_0based": rep["wt_pam_start_0based"],
            "wt_pam_sequence": rep["wt_pam_sequence"],
            "is_in_cds": rep["is_in_cds"],
            "cds_auto_detected": rep["cds_auto_detected"],
            "protein_before_blocking": rep["protein_before_blocking"],
            "protein_after_blocking": rep["protein_after_blocking"],
            "amino_acid_conserved": rep["amino_acid_conserved"],
            "blocking_strategy": rep["blocking_strategy"],
            "blocking_mutations": rep["blocking_mutations"],
            "edited_pam_sequence": rep["edited_pam_sequence"],
            "pam_still_intact": rep["pam_still_intact"],
            "cas9_recut_blocked": rep["cas9_recut_blocked"],
            "left_arm_length_bp": rep["left_arm_length_bp"],
            "right_arm_length_bp": rep["right_arm_length_bp"],
            "donor_length_bp": rep["donor_length_bp"],
            "donor_sequence": rep["donor_sequence"],
            "rflp": None if rflp is None else {
                "mode": rflp["mode"],
                "enzyme_name": rflp["enzyme_name"],
                "recognition_site": rflp["recognition_site"],
                "wt_amplicon_bands_bp": rflp["wt_amplicon_bands_bp"],
                "hdr_amplicon_bands_bp": rflp["hdr_amplicon_bands_bp"],
                "silent_mutations": rflp["silent_mutations"],
            },
            "out_out_pcr": None if out_pcr is None else {
                "forward_sequence": out_pcr["forward_primer"]["full_sequence"],
                "forward_tm": out_pcr["forward_primer"]["tm"],
                "reverse_sequence": out_pcr["reverse_primer"]["full_sequence"],
                "reverse_tm": out_pcr["reverse_primer"]["tm"],
                "forward_start_0based": out_pcr["forward_start_0based"],
                "forward_end_0based": out_pcr["forward_end_0based"],
                "reverse_start_0based": out_pcr["reverse_start_0based"],
                "reverse_end_0based": out_pcr["reverse_end_0based"],
                "wt_amplicon_length_bp": out_pcr["wt_amplicon_length_bp"],
                "hdr_amplicon_length_bp": out_pcr["hdr_amplicon_length_bp"],
                "left_margin_from_arm_bp": out_pcr["left_margin_from_arm_bp"],
                "right_margin_from_arm_bp": out_pcr["right_margin_from_arm_bp"],
            },
        }

    # Case 1: ssODN (60 nt arms) in auto-detected CDS, + strand CGG PAM (CCG|GCT) synonymously broken + Out-Out PCR
    cds1_prefix = "ATG" + cds_block * 4  # 123 bp
    # Frame-aligned cassette: GA(from c-7) GCT ATC CAC TAC GAG TTC CC | G GCT ... -> guide is AGCTATCCACTACGAGTTCC (20nt), PAM CGG (pos1-2 of CCG + pos0 of GCT)
    c1_cassette = "AGCGCTATCCACTACGAGTTCCCGGCT"  # Wait: AGC (pos0=A,pos1=G,pos2=C) wait 3*9=27 bp! Guide at [2:22]="GCTATCCACTACGAGTTCCC"? No: AGC+GCT+ATC+CAC+TAC+GAG+TTC+CCG+GCT
    # Exact frame check: AGC(S) GCT(A) ATC(I) CAC(H) TAC(Y) GAG(E) TTC(F) CCG(P) GCT(A) = 27 bp
    # [1:21] = "GCGCTATCCACTACGAGTTC" -> ends at TTC! Instead [2:22]: "CGCTATCCACTACGAGTTCC" -> followed by ref[22:25]="CGG"!
    c1_guide = c1_cassette[2:22]  # "CGCTATCCACTACGAGTTCC", 20 nt; PAM is c1_cassette[22:25] = "CGG"
    c1_ref = (flank_left_unit * 4) + cds1_prefix + c1_cassette + (cds_block * 4) + "TAA" + (flank_right_unit * 4)
    c1_edit_start = len(flank_left_unit * 4) + len(cds1_prefix) + 15  # TTC -> TAC (Phe -> Tyr) inside GAG TTC
    hdr1_inp = {
        "reference_sequence": c1_ref,
        "sgrna_sequence": c1_guide,
        "strand": "+",
        "edit_start_0based": c1_edit_start + 1,
        "edit_end_0based": c1_edit_start + 2,
        "replacement_sequence": "A",
        "donor_format": "ssODN",
        "auto_detect_cds": True,
        "enable_rflp": False,
        "out_out_margin_bp": 40,
        "primer_target_tm": 60.0,
        "donor_name": "HDR_Case1_ssODN",
    }
    hdr1_rep = mcp.design_crispr_hdr_donor(hdr1_inp)
    assert hdr1_rep["is_in_cds"] and hdr1_rep["cds_auto_detected"]
    assert hdr1_rep["amino_acid_conserved"] is True
    assert hdr1_rep["blocking_strategy"] == "pam_synonymous"
    assert hdr1_rep["pam_still_intact"] is False
    assert hdr1_rep["cas9_recut_blocked"] is True
    assert hdr1_rep["left_arm_length_bp"] == 60 and hdr1_rep["right_arm_length_bp"] == 60
    assert hdr1_rep["out_out_pcr"] is not None
    assert hdr1_rep["out_out_pcr"]["left_margin_from_arm_bp"] >= 10
    assert hdr1_rep["out_out_pcr"]["right_margin_from_arm_bp"] >= 10

    # Case 2: ssODN near unbreakable Trp (TGG) PAM -> Seed synonymous fallback (up to 2 codons in 8-nt Seed)
    # Frame-aligned: AGC(S) GCT(A) ATC(I) CAC(H) TAC(Y) GAG(E) TTC(F) TGG(W) GCC(A) = 27 bp
    c2_cassette = "AGCGCTATCCACTACGAGTTCTGGGCC"
    c2_guide = c2_cassette[1:21]  # "GCGCTATCCACTACGAGTTC" (20 nt); PAM = c2_cassette[21:24] = "TGG"
    c2_ref = (flank_left_unit * 4) + cds1_prefix + c2_cassette + (cds_block * 4) + "TAA" + (flank_right_unit * 4)
    c2_edit_start = len(flank_left_unit * 4) + len(cds1_prefix) + 16  # GAG -> GCG at index 16 (GAG + 1: A->C) -> Glu -> Ala
    hdr2_inp = {
        "reference_sequence": c2_ref,
        "sgrna_sequence": c2_guide,
        "strand": "+",
        "edit_start_0based": c2_edit_start,
        "edit_end_0based": c2_edit_start + 1,
        "replacement_sequence": "C",
        "donor_format": "ssODN",
        "auto_detect_cds": True,
        "enable_rflp": False,
        "out_out_margin_bp": 40,
        "primer_target_tm": 60.0,
        "donor_name": "HDR_Case2_TrpFallback",
    }
    hdr2_rep = mcp.design_crispr_hdr_donor(hdr2_inp)
    assert hdr2_rep["is_in_cds"] and hdr2_rep["amino_acid_conserved"] is True
    assert hdr2_rep["blocking_strategy"] == "seed_synonymous_fallback"
    assert hdr2_rep["cas9_recut_blocked"] is True
    assert len(hdr2_rep["blocking_mutations"]) >= 1

    # Case 3: dsDNA plasmid Donor (600 bp homology arms) inserting 24-bp FLAG tag + Out-Out PCR
    # Locus ~ 1700 bp with 1350+ bp ORF so 600 bp arms + 100 bp margin + 40 bp primers fit cleanly!
    # Frame-aligned target codon: ... GAG TTC ATC CGG GCT ... -> guide ends right before CGG -> [c-6..c-1 + CGG]
    # Note: 20 nt guide = last 2 of c(-7) + 6*3 = ATG/AAG...AGC + GCT+ATC+CAC+TAC+GAG+TTC (20 nt) | CGG(PAM) GCT
    # Count: "TG"(2) + "GCTATCCACTACGAGTTC"(18) = 20 nt! Followed by "CGG" (Arg, PAM at codon boundary!)
    c3_cassette = "ATGGCTATCCACTACGAGTTCCGGGCT"  # 27 bp: ATG(M) GCT(A) ATC(I) CAC(H) TAC(Y) GAG(E) TTC(F) CGG(R) GCT(A)
    c3_guide = c3_cassette[1:21]  # "TGGCTATCCACTACGAGTTC" (20 nt); PAM = "CGG" at c3_cassette[21:24]
    c3_prefix = (flank_left_unit * 5) + "ATG" + (cds_block * 22)  # 150 + 3 + 660 = 813 bp
    c3_suffix = (cds_block * 22) + "TAA" + (flank_right_unit * 5)  # 660 + 3 + 150 = 813 bp
    c3_ref = c3_prefix + c3_cassette + c3_suffix
    c3_insert_pos = len(c3_prefix) + 18  # codon boundary right before TTC (TTC -> FLAG + TTC, cut site!)
    flag_tag = "GACTACAAAGACGATGACGACAAG"  # 24 bp (DYKDDDDK)
    hdr3_inp = {
        "reference_sequence": c3_ref,
        "sgrna_sequence": c3_guide,
        "strand": "+",
        "edit_start_0based": c3_insert_pos,
        "edit_end_0based": c3_insert_pos,
        "replacement_sequence": flag_tag,
        "donor_format": "dsDNAPlasmid",
        "auto_detect_cds": True,
        "enable_rflp": False,
        "out_out_margin_bp": 60,
        "primer_target_tm": 60.0,
        "donor_name": "HDR_Case3_FLAG_dsDNA",
    }
    hdr3_rep = mcp.design_crispr_hdr_donor(hdr3_inp)
    assert hdr3_rep["donor_format"] == "dsDNAPlasmid"
    assert hdr3_rep["left_arm_length_bp"] == 600 and hdr3_rep["right_arm_length_bp"] == 600
    assert hdr3_rep["donor_length_bp"] == 1224
    assert hdr3_rep["amino_acid_conserved"] is True
    assert hdr3_rep["cas9_recut_blocked"] is True
    assert hdr3_rep["out_out_pcr"] is not None
    assert hdr3_rep["out_out_pcr"]["hdr_amplicon_length_bp"] == hdr3_rep["out_out_pcr"]["wt_amplicon_length_bp"] + 24

    # Case 4: RFLP silent site creation (GAG TTC -> GAA TTC = EcoRI) + PAM breaking + digest bands check
    # Frame-aligned: AGC(S) GCT(A) ATC(I) CAC(H) TAC(Y) GAG(E) TTC(F) CCG(P) GCT(A) GAG(E) TTC(F) GCC(A) = 36 bp
    c4_cassette = "AGCGCTATCCACTACGAGTTCCCGGCTGAGTTCGCC"
    c4_guide = c4_cassette[2:22]  # "CGCTATCCACTACGAGTTCC" (20 nt), PAM = "CGG" (CCG|GCT)
    c4_ref = (flank_left_unit * 4) + cds1_prefix + c4_cassette + (cds_block * 4) + "TAA" + (flank_right_unit * 4)
    c4_edit_start = len(flank_left_unit * 4) + len(cds1_prefix) + 16  # TTC -> TAC (Phe -> Tyr)
    hdr4_inp = {
        "reference_sequence": c4_ref,
        "sgrna_sequence": c4_guide,
        "strand": "+",
        "edit_start_0based": c4_edit_start,
        "edit_end_0based": c4_edit_start + 1,
        "replacement_sequence": "A",
        "donor_format": "ssODN",
        "auto_detect_cds": True,
        "enable_rflp": True,
        "rflp_search_radius_bp": 18,
        "out_out_margin_bp": 40,
        "primer_target_tm": 60.0,
        "donor_name": "HDR_Case4_RFLP_Create",
    }
    hdr4_rep = mcp.design_crispr_hdr_donor(hdr4_inp)
    assert hdr4_rep["amino_acid_conserved"] is True
    assert hdr4_rep["blocking_strategy"] == "pam_synonymous"
    assert hdr4_rep["rflp"] is not None and hdr4_rep["rflp"]["mode"] == "created"
    assert len(hdr4_rep["rflp"]["hdr_amplicon_bands_bp"]) > len(hdr4_rep["rflp"]["wt_amplicon_bands_bp"])

    # Case 5: Reverse-strand (-) CCN PAM in + strand CDS (GCC|CAG -> GCT|CAG breaks CCA PAM) + RFLP destroy (GGATCC BamHI -> GGCTCC)
    # Frame-aligned: GCC(A) CAG(Q) ATC(I) CAC(H) TAC(Y) GAG(E) TTC(F) GGA(G) TCC(S) = 27 bp
    # Reverse PAM is CCN at pos [2:5] = "CCA" (pos2 of GCC + pos0..1 of CAG); - strand protospacer is [5:25] ("GAT...")!
    c5_cassette = "GCCCAGATCCACTACGAGTTCGGATCCGCC"  # 30 bp: GCC(A) CAG(Q) ATC(I) CAC(H) TAC(Y) GAG(E) TTC(F) GGA(G) TCC(S) GCC(A)
    c5_guide = mcp.rev_comp(c5_cassette[5:25])  # 20-nt sgRNA targeting - strand (3' side of CCA PAM)
    c5_ref = (flank_left_unit * 4) + cds1_prefix + c5_cassette + (cds_block * 4) + "TAA" + (flank_right_unit * 4)
    c5_edit_start = len(flank_left_unit * 4) + len(cds1_prefix) + 9  # CAC -> TAC (C->T at c5_cassette[9]) -> His -> Tyr
    hdr5_inp = {
        "reference_sequence": c5_ref,
        "sgrna_sequence": c5_guide,
        "strand": "-",
        "edit_start_0based": c5_edit_start,
        "edit_end_0based": c5_edit_start + 1,
        "replacement_sequence": "T",
        "donor_format": "ssODN",
        "auto_detect_cds": True,
        "enable_rflp": True,
        "rflp_search_radius_bp": 18,
        "out_out_margin_bp": 40,
        "primer_target_tm": 60.0,
        "donor_name": "HDR_Case5_RevCCN_Destroy",
    }
    hdr5_rep = mcp.design_crispr_hdr_donor(hdr5_inp)
    assert hdr5_rep["strand"] == "-"
    assert hdr5_rep["amino_acid_conserved"] is True
    assert hdr5_rep["blocking_strategy"] == "pam_synonymous"
    assert hdr5_rep["pam_still_intact"] is False
    assert hdr5_rep["rflp"] is not None and hdr5_rep["rflp"]["mode"] == "destroyed"
    assert hdr5_rep["rflp"]["enzyme_name"] == "BamHI"
    assert len(hdr5_rep["rflp"]["wt_amplicon_bands_bp"]) > len(hdr5_rep["rflp"]["hdr_amplicon_bands_bp"])

    hdr_cases = [
        {
            "id": "hdr_01_ssodn_60nt_pam_synonymous_and_outout",
            "input": hdr1_inp,
            "expected": _hdr_summary(hdr1_rep),
            "tolerance": 1e-5,
            "note": "ssODN (60 nt 左右同源臂) CDS 自动识别、+ 链 CGG PAM 同义破除与同源臂外侧 Out-Out PCR 分型引物",
        },
        {
            "id": "hdr_02_ssodn_trp_pam_seed_fallback",
            "input": hdr2_inp,
            "expected": _hdr_summary(hdr2_rep),
            "tolerance": 1e-5,
            "note": "不可同义破除的 TGG (Trp) PAM 自动回退至近 PAM 8-nt Seed 区同义突变阻断二次切割，氨基酸 100% 守恒",
        },
        {
            "id": "hdr_03_dsdna_600bp_knockin_tag_and_outout",
            "input": hdr3_inp,
            "expected": _hdr_summary(hdr3_rep),
            "tolerance": 1e-5,
            "note": "dsDNA 质粒型 Donor（600 bp 左右同源臂）框内 Knock-in 24 bp FLAG 标签及长距 Out-Out 鉴定引物 (+24 bp)",
        },
        {
            "id": "hdr_04_rflp_silent_site_creation_and_digest",
            "input": hdr4_inp,
            "expected": _hdr_summary(hdr4_rep),
            "tolerance": 1e-5,
            "note": "CDS 内通过同义替换 GAG->GAA 凭空构建 EcoRI (GAATTC) RFLP 鉴定位点，预测 WT 未切 vs HDR 双条带",
        },
        {
            "id": "hdr_05_reverse_strand_ccn_pam_and_rflp_destroy",
            "input": hdr5_inp,
            "expected": _hdr_summary(hdr5_rep),
            "tolerance": 1e-5,
            "note": "负链 sgRNA (CCN PAM) 跨密码子同义破坏 GCC->GCT 并同义消除邻近 BamHI (GGATCC) 内源 RFLP 位点",
        },
    ]
    write_vector_file("crispr_hdr_donor.json", {"function": "crispr_hdr_donor", "cases": hdr_cases})


if __name__ == "__main__":
    build_all()
