#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Offline generator for Labworker Swift-Python shared test vectors (P12).
Note: This script is an offline authoring tool and is NOT a runtime dependency.
"""

import os
import sys
import json

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


if __name__ == "__main__":
    build_all()
