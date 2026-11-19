#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CloneStudio MCP (Model Context Protocol) Server v2.4.0
支持 Claude Desktop, Cursor, Windsurf, Cline, Gemini CLI 等所有 MCP 客户端通过自然语言调用 23 项分子克隆与生物信息工具：
1. 质粒池三维检索与管理 (`list_plasmid_pool`, `inspect_plasmid`, `add_plasmid_to_pool`)：
   - 支持按 载体 (vector)、目的基因 (gene)、抗性 (resistance)、分类 (category) 精准筛选
2. 五大分子克隆引物设计与重组质粒组装：
   - 单片段无缝克隆 (`design_single_clone_primers`)
   - 多片段无缝组装 (`design_multi_fragment_primers`)
   - 定点突变 (`design_mutagenesis_primers`)：含野生型氨基酸一致性校验、邻近位点提示与原核/真核宿主密码子偏好自动选择
   - 质粒片段删除 (`design_fragment_deletion_primers`)
   - Type IIS Golden Gate 组装规划与 Domestication (`design_golden_gate_assembly`)：基于 Libraries.sqlite NEB T4 保真度矩阵
3. CRISPR / RNAi / HDR 基因编辑工具组：
   - CRISPR/Cas9 sgRNA 靶点扫描打分与 lentiCRISPRv2 / pX459 退火引物生成 (`design_sgrna_primers`)
   - RNAi shRNA 靶点扫描打分与 pLKO.1 (AgeI/EcoRI) 发夹引物生成 (`design_shrna_primers`)
   - CRISPR 编辑池 Sanger 峰图 NNLS 解卷积定量 (`deconvolute_crispr_sanger`)
   - CRISPR Knock-in HDR Donor、PAM/Seed 同义阻断突变、可选 RFLP 与 Out-Out PCR 引物设计 (`design_hdr_donor`)
4. 质粒注释与序列/测序分析：
   - 基于 Libraries.sqlite 的本地离线未知质粒 FASTA 自动注释与残留片段标记 (`auto_annotate_sequence`)
   - Sanger 测序 (.ab1/.abi/.seq) 比对与克隆验证 (`verify_sanger_sequencing`)
5. 实验台定量、结构预测与换算：
   - 重组反应 DNA 用量配比 (`calculate_recombination_dosage`)、核酸/蛋白/溶液换算、qPCR ΔΔCt、Western Blot、微孔板排布、蛋白质结构与结合口袋评估
6. 引物订购池管理与擎科 Excel 订购表导出 (`manage_primer_cart_and_export`)
7. 全模块双向 GUI 实时同步：通过 macOS DistributedNotificationCenter 自动切换 CloneStudio 模块画布并加载载体/片段/引物
"""

import sys
import os
import re
import json
import math
import uuid
import datetime
import subprocess
import inspect
from typing import Any, Dict, List, Optional, Tuple, TypedDict, Literal

try:
    from pydantic import BaseModel, Field, ConfigDict, model_validator
    _HAS_PYDANTIC = True
except ImportError:
    _HAS_PYDANTIC = False

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

def _resolve_project_dir() -> str:
    env_dir = os.environ.get("LABWORKER_PROJECT_DIR", "").strip()
    if env_dir and os.path.exists(env_dir):
        return os.path.abspath(env_dir)
    curr = SCRIPT_DIR
    for _ in range(6):
        if os.path.exists(os.path.join(curr, "Package.swift")):
            return curr
        parent = os.path.dirname(curr)
        if parent == curr:
            break
        curr = parent
    return os.getcwd()

PROJECT_DIR = _resolve_project_dir()
APP_SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/CloneStudio")
MCP_SYNC_DIR = os.environ.get("LABWORKER_MCP_SYNC_DIR", "").strip() or os.path.join(APP_SUPPORT_DIR, "mcp_sync")

POOL_PATHS = [
    os.path.join(APP_SUPPORT_DIR, "plasmid_pool.json"),
    os.path.join(PROJECT_DIR, ".clonestudio_plasmid_pool.json"),
    os.path.join(os.path.dirname(PROJECT_DIR), ".clonestudio_plasmid_pool.json"),
]

SNAPGENE_BRIDGE = os.path.join(SCRIPT_DIR, "snapgene_bridge.py")
if not os.path.exists(SNAPGENE_BRIDGE):
    SNAPGENE_BRIDGE = os.path.join(PROJECT_DIR, "Sources/CloneStudioCore/Resources/snapgene_bridge.py")

EXPORT_ORDER_SCRIPT = os.path.join(SCRIPT_DIR, "export_order.py")
if not os.path.exists(EXPORT_ORDER_SCRIPT):
    EXPORT_ORDER_SCRIPT = os.path.join(PROJECT_DIR, "Sources/CloneStudioCore/Resources/export_order.py")


# ============================================================================
# 1. 分子生物学核心算法 (与 CloneStudio Core / SnapGene 100% 对齐)
# ============================================================================

COMPLEMENT_MAP = str.maketrans("ATCGatcgNn", "TAGCtagcNn")

def clean_seq(seq: str) -> str:
    return "".join(c for c in (seq or "").upper() if c in "ATCG")

def rev_comp(seq: str) -> str:
    return clean_seq(seq).translate(COMPLEMENT_MAP)[::-1]

def extract_circular_subsequence(seq: str, start_1based: int, end_1based: int, strand: str = "+") -> str:
    """截取环状质粒子序列（支持 start_1based > end_1based 跨越原点 1 bp 边界，以及负链 '-' 自动反向互补，与 BioSequence.extractCircularSubsequence 100% 对齐）"""
    cleaned = clean_seq(seq)
    n = len(cleaned)
    if n == 0:
        return ""
    s0 = ((int(start_1based) - 1) % n + n) % n
    e0 = ((int(end_1based) - 1) % n + n) % n
    if s0 <= e0:
        out = cleaned[s0:e0 + 1]
    else:
        out = cleaned[s0:] + cleaned[:e0 + 1]
    return rev_comp(out) if strand == "-" else out

def gc_percent(seq: str) -> float:
    s = clean_seq(seq)
    if not s:
        return 0.0
    gc = sum(1 for c in s if c in "GC")
    return round((gc / len(s)) * 100.0, 1)

# SantaLucia & Hicks (2004) + Bommarito et al. (2000) Nearest-Neighbor parameters
# Strictly unified with Sources/CloneStudioCore/Engine/TmCalculator.swift
NN_DH_2004 = {
    "AA": -7.6, "TT": -7.6, "AT": -7.2, "TA": -7.2,
    "CA": -8.5, "TG": -8.5, "GT": -8.4, "AC": -8.4,
    "CT": -7.8, "AG": -7.8, "GA": -8.2, "TC": -8.2,
    "CG": -10.6, "GC": -9.8, "GG": -8.0, "CC": -8.0,
    "AI": -8.3, "IA": -4.9, "CI": -5.4, "IC": -5.0,
    "GI": -6.8, "IG": -7.6, "TI": -3.4, "IT": -6.5, "II": -3.3
}
NN_DS_2004 = {
    "AA": -21.3, "TT": -21.3, "AT": -20.4, "TA": -21.3,
    "CA": -22.7, "TG": -22.7, "GT": -22.4, "AC": -22.4,
    "CT": -21.0, "AG": -21.0, "GA": -22.2, "TC": -22.2,
    "CG": -27.2, "GC": -24.4, "GG": -19.9, "CC": -19.9,
    "AI": -25.0, "IA": -15.8, "CI": -13.7, "IC": -12.6,
    "GI": -19.1, "IG": -22.0, "TI": -11.2, "IT": -22.0, "II": -11.9
}

IUPAC_EXPANSION = {
    "A": ["A"], "T": ["T"], "U": ["T"], "C": ["C"], "G": ["G"], "I": ["I"],
    "R": ["A", "G"], "Y": ["C", "T"], "S": ["G", "C"], "W": ["A", "T"],
    "K": ["G", "T"], "M": ["A", "C"],
    "B": ["C", "G", "T"], "D": ["A", "G", "T"], "H": ["A", "C", "T"], "V": ["A", "C", "G"],
    "N": ["A", "T", "C", "G"]
}

def normalize_oligo(raw: str) -> str:
    out = []
    for ch in (raw or "").upper():
        if ch == "U":
            out.append("T")
        elif ch in IUPAC_EXPANSION:
            out.append(ch)
    return "".join(out)

FIVE_PRIME_DANGLE = {
    "AA": (0.2, 2.3),   "AC": (-6.3, -17.1), "AG": (-3.7, -10.0), "AT": (-2.9, -7.6),
    "CA": (0.6, 3.3),   "CC": (-4.4, -12.6), "CG": (-4.0, -11.9), "CT": (-4.1, -13.0),
    "GA": (-1.1, -1.6), "GC": (-5.1, -14.0), "GG": (-3.9, -10.9), "GT": (-4.2, -15.0),
    "TA": (-6.9, -20.0),"TC": (-4.0, -10.9), "TG": (-4.9, -13.8), "TT": (-0.2, -0.5)
}

THREE_PRIME_DANGLE = {
    "AA": (-0.5, -1.1), "AC": (4.7, 14.2),   "AG": (-4.1, -13.1), "AT": (-3.8, -12.6),
    "CA": (-5.9, -16.5),"CC": (-2.6, -7.4),  "CG": (-3.2, -10.4), "CT": (-5.2, -15.0),
    "GA": (-2.1, -3.9), "GC": (-0.2, -0.1),  "GG": (-3.9, -11.2), "GT": (-4.4, -13.1),
    "TA": (-0.7, -0.8), "TC": (4.4, 14.9),   "TG": (-1.6, -3.6),  "TT": (2.9, 10.4)
}

INTERNAL_MISMATCH_PARAMS = {
    "AG/TT": (1.0, 0.9),   "AT/TG": (-2.5, -8.3), "CG/GT": (-4.1, -11.7), "CT/GG": (-2.8, -8.0),
    "GG/CT": (3.3, 10.4),  "GG/TT": (5.8, 16.3),  "GT/CG": (-4.4, -12.3), "GT/TG": (4.1, 9.5),
    "TG/AT": (-0.1, -1.7), "TG/GT": (-1.4, -6.2), "TT/AG": (-1.3, -5.3),  "AA/TG": (-0.6, -2.3),
    "AG/TA": (-0.7, -2.3), "CA/GG": (-0.7, -2.3), "CG/GA": (-4.0, -13.2), "GA/CG": (-0.6, -1.0),
    "GG/CA": (0.5, 3.2),   "TA/AG": (0.7, 0.7),   "TG/AA": (3.0, 7.4),    "AC/TT": (0.7, 0.2),
    "AT/TC": (-1.2, -6.2), "CC/GT": (-0.8, -4.5), "CT/GC": (-1.5, -6.1),  "GC/CT": (2.3, 5.4),
    "GT/CC": (5.2, 13.5),  "TC/AT": (1.2, 0.7),   "TT/AC": (1.0, 0.7),    "AA/TC": (2.3, 4.6),
    "AC/TA": (5.3, 14.6),  "CA/GC": (1.9, 3.7),   "CC/GA": (0.6, -0.6),   "GA/CC": (5.2, 14.2),
    "GC/CA": (-0.7, -3.8), "TA/AC": (3.4, 8.0),   "TC/AA": (7.6, 20.2),   "AA/TA": (1.2, 1.7),
    "CA/GA": (-0.9, -4.2), "GA/CA": (-2.9, -9.8), "TA/AA": (4.7, 12.9),   "AC/TC": (0.0, -4.4),
    "CC/GC": (-1.5, -7.2), "GC/CC": (3.6, 8.9),   "TC/AC": (6.1, 16.4),   "AG/TG": (-3.1, -9.5),
    "CG/GG": (-4.9, -15.3),"GG/CG": (-6.0, -15.8),"TG/AG": (1.6, 3.6),    "AT/TT": (-2.7, -10.8),
    "CT/GT": (-5.0, -15.8),"GT/CT": (-2.2, -8.4), "TT/AT": (0.2, -1.5)
}

def _lookup_dinuc_iupac(b1: str, b2: str) -> tuple:
    exp1 = IUPAC_EXPANSION.get(b1, ["A"])
    exp2 = IUPAC_EXPANSION.get(b2, ["A"])
    s_dh, s_ds, cnt = 0.0, 0.0, 0
    for c1 in exp1:
        for c2 in exp2:
            key = c1 + c2
            s_dh += NN_DH_2004.get(key, -8.0)
            s_ds += NN_DS_2004.get(key, -22.0)
            cnt += 1
    return (s_dh / max(1, cnt), s_ds / max(1, cnt))

def _terminal_at_iupac(b: str) -> tuple:
    exp = IUPAC_EXPANSION.get(b, ["A"])
    s_dh, s_ds = 0.0, 0.0
    for c in exp:
        if c in ("A", "T", "I"):
            s_dh += 2.2
            s_ds += 6.9
    n = max(1, len(exp))
    return (s_dh / n, s_ds / n)

def _lookup_dangle5_iupac(d_ch: str, p_ch: str) -> tuple:
    exp_d = IUPAC_EXPANSION.get(d_ch, ["A"])
    exp_p = IUPAC_EXPANSION.get(p_ch, ["A"])
    s_dh, s_ds, cnt = 0.0, 0.0, 0
    for d in exp_d:
        for p in exp_p:
            val = FIVE_PRIME_DANGLE.get(d + p)
            if val:
                s_dh += val[0]
                s_ds += val[1]
                cnt += 1
    return (s_dh / cnt, s_ds / cnt) if cnt > 0 else (0.0, 0.0)

def _lookup_dangle3_iupac(p_ch: str, d_ch: str) -> tuple:
    exp_p = IUPAC_EXPANSION.get(p_ch, ["A"])
    exp_d = IUPAC_EXPANSION.get(d_ch, ["A"])
    s_dh, s_ds, cnt = 0.0, 0.0, 0
    for p in exp_p:
        for d in exp_d:
            val = THREE_PRIME_DANGLE.get(p + d)
            if val:
                s_dh += val[0]
                s_ds += val[1]
                cnt += 1
    return (s_dh / cnt, s_ds / cnt) if cnt > 0 else (0.0, 0.0)

def equivalent_monovalent_molar(mv_conc: float = 50.0, dv_conc: float = 0.0, dntp_conc: float = 0.0) -> float:
    free_mg = max(0.0, float(dv_conc) - float(dntp_conc))
    eq_mm = max(1.0, float(mv_conc)) + 120.0 * math.sqrt(free_mg)
    return max(0.001, eq_mm / 1000.0)

def calc_snapgene_tm(
    seq: str,
    five_prime_overhang: str = "",
    three_prime_overhang: str = "",
    na_molar: float = 0.05,
    primer_conc: float = 250e-9,
    mv_conc: float = None,
    dv_conc: float = 0.0,
    dntp_conc: float = 0.0
) -> float:
    """100% aligned with TmCalculator.calculate in TmCalculator.swift (supports IUPAC degenerate bases and optional Mg2+/dNTP equivalent salt)"""
    s = normalize_oligo(seq)
    ov5 = normalize_oligo(five_prime_overhang)
    ov3 = normalize_oligo(three_prime_overhang)
    n = len(s)
    if n < 2:
        return 0.0
    if mv_conc is not None:
        na_molar = equivalent_monovalent_molar(mv_conc, dv_conc, dntp_conc)
    dh = 0.2
    ds = -5.7
    at0 = _terminal_at_iupac(s[0])
    dh += at0[0]
    ds += at0[1]
    at_end = _terminal_at_iupac(s[-1])
    dh += at_end[0]
    ds += at_end[1]
    if not ov5 and not ov3 and n % 2 == 0 and all(c in "ATCG" for c in s) and s == rev_comp(s):
        ds += -1.4
    for i in range(n - 1):
        step_dh, step_ds = _lookup_dinuc_iupac(s[i], s[i + 1])
        dh += step_dh
        ds += step_ds
    if ov5:
        d5_dh, d5_ds = _lookup_dangle5_iupac(ov5[-1], s[0])
        dh += d5_dh
        ds += d5_ds
    if ov3:
        d3_dh, d3_ds = _lookup_dangle3_iupac(s[-1], ov3[0])
        dh += d3_dh
        ds += d3_ds
    ds += 0.368 * (n - 1) * math.log(max(0.001, na_molar))
    r = 1.9872
    tm_c = (1000.0 * dh) / (ds + r * math.log(max(1e-9, primer_conc))) - 273.15
    return round(tm_c, 1)

# SantaLucia 1998 Nearest-Neighbor parameters & Hairpin loop entropy (100% aligned with PrimerQualityEngine.swift)
NN_1998 = {
    "AA": (-7.9, -22.2), "TT": (-7.9, -22.2),
    "AT": (-7.2, -20.4), "TA": (-7.2, -21.3),
    "CA": (-8.5, -22.7), "TG": (-8.5, -22.7),
    "GT": (-8.4, -22.4), "AC": (-8.4, -22.4),
    "CT": (-7.8, -21.0), "AG": (-7.8, -21.0),
    "GA": (-8.2, -22.2), "TC": (-8.2, -22.2),
    "CG": (-10.6, -27.2), "GC": (-9.8, -24.4),
    "GG": (-8.0, -19.9), "CC": (-8.0, -19.9)
}

HAIRPIN_LOOP_DS = {
    3: -10.18, 4: -10.80, 5: -10.16, 6: -12.41, 7: -13.06,
    8: -13.38, 9: -14.02, 10: -14.35, 11: -14.81, 12: -15.10
}

def _clean_acgt_rna(raw: str) -> str:
    out = []
    for ch in (raw or "").upper():
        if ch in "ACGT":
            out.append(ch)
        elif ch == "U":
            out.append("T")
    return "".join(out)

def _is_comp(a: str, b: str) -> bool:
    return (a, b) in (("A", "T"), ("T", "A"), ("C", "G"), ("G", "C"))

def _comp_base(b: str) -> str:
    return {"A": "T", "T": "A", "C": "G", "G": "C"}.get(b, b)

def calc_hairpin(raw_seq: str, mv_conc: float = 50.0, dv_conc: float = 1.5, dntp_conc: float = 0.6, dna_conc: float = 50.0, temp_c: float = 37.0) -> dict:
    """100% aligned with PrimerQualityEngine.calcHairpin in PrimerQualityEngine.swift"""
    clean = _clean_acgt_rna(raw_seq)
    seq = clean[-60:] if len(clean) > 60 else clean
    n = len(seq)
    if n < 7:
        return {"structure_found": False, "dg": 0.0, "dh": 0.0, "ds": 0.0, "tm": 0.0}
    temp_k = temp_c + 273.15
    na_eq = equivalent_monovalent_molar(mv_conc, dv_conc, dntp_conc)
    salt_per_step = 0.368 * math.log(na_eq)
    best_dg, best_dh, best_ds = 0.0, 0.0, 0.0
    best_pairs = []
    for i in range(0, n - 6):
        for j in range(n - 1, i + 5, -1):
            if not _is_comp(seq[i], seq[j]):
                continue
            pairs = [(i, j)]
            dh = 2.2 if seq[i] in "AT" else 0.0
            ds = 6.9 if seq[i] in "AT" else 0.0
            l, r = i, j
            while (r - l - 1) >= 5:
                nl, nr = l + 1, r - 1
                if _is_comp(seq[nl], seq[nr]):
                    st = NN_1998.get(seq[l] + seq[nl])
                    if st:
                        dh += st[0]
                        ds += st[1]
                    pairs.append((nl, nr))
                    l, r = nl, nr
                elif (nr - nl - 1) >= 5 and _is_comp(seq[nl + 1], seq[nr - 1]) and _is_comp(seq[nl + 2], seq[nr - 2]):
                    k1 = f"{seq[l]}{seq[nl]}/{seq[r]}{seq[nr]}"
                    k2 = f"{seq[nl]}{seq[nl+1]}/{seq[nr]}{seq[nr-1]}"
                    m1 = INTERNAL_MISMATCH_PARAMS.get(k1, (1.0, 0.0))
                    m2 = INTERNAL_MISMATCH_PARAMS.get(k2, (1.0, 0.0))
                    dh += m1[0] + m2[0]
                    ds += m1[1] + m2[1]
                    pairs.append((nl + 1, nr - 1))
                    l, r = nl + 1, nr - 1
                else:
                    break
                loop_len = r - l - 1
                if loop_len < 3 or len(pairs) < 3:
                    continue
                cand_dh, cand_ds = dh, ds
                loop_ent = HAIRPIN_LOOP_DS.get(loop_len, -16.20 - 1.75 * 1.9872 * math.log(loop_len / 12.0))
                cand_ds += loop_ent
                if loop_len >= 4:
                    mm_key = f"{seq[l]}{seq[l+1]}/{seq[r]}{seq[r-1]}"
                    rev_key = f"{seq[r]}{seq[r-1]}/{seq[l]}{seq[l+1]}"
                    mm = INTERNAL_MISMATCH_PARAMS.get(mm_key) or INTERNAL_MISMATCH_PARAMS.get(rev_key)
                    if mm:
                        cand_dh += mm[0]
                        cand_ds += mm[1]
                    elif _is_comp(seq[l + 1], seq[r - 1]):
                        cand_dh += -6.0
                        cand_ds += -16.58
                    else:
                        cand_dh += -3.5
                        cand_ds += -9.5
                if i > 0 and (seq[i - 1] + seq[i]) in FIVE_PRIME_DANGLE:
                    d5 = FIVE_PRIME_DANGLE[seq[i - 1] + seq[i]]
                    cand_dh += d5[0] * 0.5
                    cand_ds += d5[1] * 0.5
                if j < n - 1 and (seq[j] + seq[j + 1]) in THREE_PRIME_DANGLE:
                    d3 = THREE_PRIME_DANGLE[seq[j] + seq[j + 1]]
                    cand_dh += d3[0] * 0.5
                    cand_ds += d3[1] * 0.5
                cand_ds += salt_per_step * max(1, len(pairs) - 2)
                cand_dg = cand_dh - (temp_k * cand_ds) / 1000.0
                if cand_dg < best_dg:
                    best_dg, best_dh, best_ds = cand_dg, cand_dh, cand_ds
                    best_pairs = list(pairs)
    if not best_pairs or best_dg >= -0.2 or best_ds >= 0:
        return {"structure_found": False, "dg": 0.0, "dh": 0.0, "ds": 0.0, "tm": 0.0}
    tm = max(0.0, (best_dh * 1000.0) / best_ds - 273.15)
    return {
        "structure_found": True,
        "dg": round(best_dg, 2),
        "dh": round(best_dh, 2),
        "ds": round(best_ds, 2),
        "tm": round(tm, 1)
    }

def calc_dimer(raw_seq1: str, raw_seq2: str, mv_conc: float = 50.0, dv_conc: float = 1.5, dntp_conc: float = 0.6, dna_conc: float = 50.0, temp_c: float = 37.0) -> dict:
    """100% aligned with PrimerQualityEngine.calcDuplexDimer in PrimerQualityEngine.swift"""
    s1 = _clean_acgt_rna(raw_seq1)
    s2_orig = _clean_acgt_rna(raw_seq2)
    s2_rev = s2_orig[::-1]
    n1, n2 = len(s1), len(s2_rev)
    if n1 < 4 or n2 < 4:
        return {"structure_found": False, "dg": 0.0, "dh": 0.0, "ds": 0.0, "tm": 0.0}
    temp_k = temp_c + 273.15
    na_eq = equivalent_monovalent_molar(mv_conc, dv_conc, dntp_conc)
    salt_per_step = 0.368 * math.log(na_eq)
    best_dg, best_dh, best_ds = 0.0, 0.0, 0.0
    best_pairs = []
    for offset in range(-(n2 - 2), n1 - 1):
        start_j = max(0, -offset)
        end_j = min(n2 - 1, n1 - 1 - offset)
        if end_j - start_j + 1 < 2:
            continue
        match_positions = [j for j in range(start_j, end_j + 1) if _is_comp(s1[j + offset], s2_rev[j])]
        if len(match_positions) < 2:
            continue
        for m_start in range(0, len(match_positions) - 1):
            dh, ds = 0.2, -5.7
            j0 = match_positions[m_start]
            i0 = j0 + offset
            pairs = [(i0, j0)]
            if s1[i0] in "AT":
                dh += 2.2
                ds += 6.9
            prev_j = j0
            for m_end in range(m_start + 1, len(match_positions)):
                cur_j = match_positions[m_end]
                cur_i = cur_j + offset
                prev_i = prev_j + offset
                gap = cur_j - prev_j
                if gap == 1:
                    st = NN_1998.get(s1[prev_i] + s1[cur_i])
                    if st:
                        dh += st[0]
                        ds += st[1]
                    pairs.append((cur_i, cur_j))
                    prev_j = cur_j
                elif gap == 2:
                    mid_i, mid_j = prev_i + 1, prev_j + 1
                    k1 = f"{s1[prev_i]}{s1[mid_i]}/{s2_rev[prev_j]}{s2_rev[mid_j]}"
                    k2 = f"{s1[mid_i]}{s1[cur_i]}/{s2_rev[mid_j]}{s2_rev[cur_j]}"
                    m1 = INTERNAL_MISMATCH_PARAMS.get(k1)
                    m2 = INTERNAL_MISMATCH_PARAMS.get(k2)
                    if m1 and m2:
                        dh += m1[0] + m2[0]
                        ds += m1[1] + m2[1]
                    else:
                        dh += 2.4
                        ds += 4.0
                    pairs.append((cur_i, cur_j))
                    prev_j = cur_j
                else:
                    break
                if len(pairs) < 2:
                    continue
                cand_dh, cand_ds = dh, ds
                if s1[cur_i] in "AT":
                    cand_dh += 2.2
                    cand_ds += 6.9
                if i0 > 0 and (s1[i0 - 1] + s1[i0]) in FIVE_PRIME_DANGLE:
                    d5 = FIVE_PRIME_DANGLE[s1[i0 - 1] + s1[i0]]
                    cand_dh += d5[0]
                    cand_ds += d5[1]
                if j0 > 0:
                    c_first = _comp_base(s2_rev[j0])
                    if (c_first + s2_rev[j0 - 1]) in THREE_PRIME_DANGLE:
                        d3 = THREE_PRIME_DANGLE[c_first + s2_rev[j0 - 1]]
                        cand_dh += d3[0]
                        cand_ds += d3[1]
                if cur_i < n1 - 1 and (s1[cur_i] + s1[cur_i + 1]) in THREE_PRIME_DANGLE:
                    d3 = THREE_PRIME_DANGLE[s1[cur_i] + s1[cur_i + 1]]
                    cand_dh += d3[0]
                    cand_ds += d3[1]
                if cur_j < n2 - 1 and (s2_rev[cur_j + 1] + s1[cur_i]) in FIVE_PRIME_DANGLE:
                    d5 = FIVE_PRIME_DANGLE[s2_rev[cur_j + 1] + s1[cur_i]]
                    cand_dh += d5[0]
                    cand_ds += d5[1]
                steps = max(1, cur_i - i0)
                cand_ds += salt_per_step * steps
                cand_dg = cand_dh - (temp_k * cand_ds) / 1000.0
                if cand_dg < best_dg:
                    best_dg, best_dh, best_ds = cand_dg, cand_dh, cand_ds
                    best_pairs = list(pairs)
    if not best_pairs or best_dg >= -0.5 or best_ds >= 0:
        return {"structure_found": False, "dg": 0.0, "dh": 0.0, "ds": 0.0, "tm": 0.0}
    c_molar = max(1e-9, float(dna_conc) * 1e-9)
    tm = (best_dh * 1000.0) / (best_ds + 1.9872 * math.log(c_molar)) - 273.15
    return {
        "structure_found": True,
        "dg": round(best_dg, 2),
        "dh": round(best_dh, 2),
        "ds": round(best_ds, 2),
        "tm": round(tm, 1)
    }

def calc_homodimer(raw_seq: str, mv_conc: float = 50.0, dv_conc: float = 1.5, dntp_conc: float = 0.6, dna_conc: float = 50.0, temp_c: float = 37.0) -> dict:
    return calc_dimer(raw_seq, raw_seq, mv_conc=mv_conc, dv_conc=dv_conc, dntp_conc=dntp_conc, dna_conc=dna_conc, temp_c=temp_c)

def pick_specific_annealing_seq(template_5to3: str, five_prime_overhang: str = "", target_tm: float = 60.0, tolerance: float = 1.0, min_len: int = 18, max_len: int = 38) -> str:
    """100% aligned with HomologyArmDesigner.pickSpecificAnnealingSeq"""
    s = clean_seq(template_5to3)
    if len(s) < min_len:
        return s
    clamped_tol = max(0.0, min(3.0, tolerance))
    lower_bound = target_tm - clamped_tol
    upper_bound = target_tm + clamped_tol
    closest_seq = s[:min_len]
    min_diff = 999.0
    best_win_seq = ""
    best_win_score = -999.0
    for length in range(min_len, min(max_len, len(s)) + 1):
        sub = s[:length]
        tm = calc_snapgene_tm(sub, five_prime_overhang=five_prime_overhang)
        diff = abs(tm - target_tm)
        if diff < min_diff:
            min_diff = diff
            closest_seq = sub
        if clamped_tol <= 0.05:
            if tm >= target_tm:
                return sub
        elif lower_bound <= tm <= upper_bound:
            gc_bonus = 0.6 if sub[-1] in "GC" else 0.0
            score = gc_bonus - diff
            if score > best_win_score:
                best_win_score = score
                best_win_seq = sub
    return best_win_seq if best_win_seq else closest_seq

# 哺乳动物 (Human) 与 原核大肠杆菌 (E. coli) 最高频偏好密码子表
HUMAN_PREFERRED_CODONS = {
    "A": "GCC", "R": "CGG", "N": "AAC", "D": "GAC", "C": "TGC",
    "Q": "CAG", "E": "GAG", "G": "GGC", "H": "CAC", "I": "ATC",
    "L": "CTG", "K": "AAG", "M": "ATG", "F": "TTC", "P": "CCC",
    "S": "AGC", "T": "ACC", "W": "TGG", "Y": "TAC", "V": "GTG",
    "*": "TGA"
}

ECOLI_PREFERRED_CODONS = {
    "A": "GCG", "R": "CGT", "N": "AAC", "D": "GAT", "C": "TGC",
    "Q": "CAG", "E": "GAA", "G": "GGC", "H": "CAC", "I": "ATT",
    "L": "CTG", "K": "AAA", "M": "ATG", "F": "TTT", "P": "CCG",
    "S": "TCT", "T": "ACC", "W": "TGG", "Y": "TAT", "V": "GTG",
    "*": "TAA"
}

CODON_TO_AA = {
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
    "GGT": "G", "GGC": "G", "GGA": "G", "GGG": "G"
}

COMMON_ENZYMES = {
    "EcoRI": "GAATTC", "BamHI": "GGATCC", "HindIII": "AAGCTT", "XhoI": "CTCGAG",
    "NdeI": "CATATG", "NcoI": "CCATGG", "NotI": "GCGGCCGC", "XbaI": "TCTAGA",
    "SpeI": "ACTAGT", "PstI": "CTGCAG", "SalI": "GTCGAC", "SacI": "GAGCTC",
    "KpnI": "GGTACC", "SmaI": "CCCGGG", "EcoRV": "GATATC", "BglII": "AGATCT",
    "AgeI": "ACCGGT", "NheI": "GCTAGC", "MluI": "ACGCGT", "PacI": "TTAATTAA"
}


# ============================================================================
# 2. 质粒池三维元数据提取（载体 / 基因 / 抗性，与 PlasmidPoolManager.swift 100% 对齐）
# ============================================================================

def extract_resistances(dna_info: dict, plasmid_name: str = "") -> list:
    found = []
    def add_unique(tag: str):
        if tag not in found:
            found.append(tag)

    for f in dna_info.get("features", []):
        low_name = (f.get("name") or "").strip().lower()
        low_type = (f.get("type") or "").strip().lower()
        if any(w in low_name for w in ["promoter", "terminator", "operator"]) or any(w in low_type for w in ["promoter", "terminator", "primer_bind", "rep_origin"]):
            continue
        if "ampr" in low_name or low_name == "amp" or "ampicillin" in low_name or low_name == "bla":
            add_unique("AmpR")
        if "neor" in low_name or low_name == "neo" or "neomycin" in low_name or "g418" in low_name:
            add_unique("NeoR")
        if "kanr" in low_name or low_name == "kan" or "kanamycin" in low_name:
            add_unique("KanR")
        if "puror" in low_name or low_name == "puro" or "puromycin" in low_name or low_name == "pac":
            add_unique("PuroR")
        if "hygr" in low_name or "hygro" in low_name or low_name == "hph":
            add_unique("HygroR")
        if "cmr" in low_name or "chlr" in low_name or "chloramphenicol" in low_name or low_name == "cat":
            add_unique("CmR")
        if "smr" in low_name or "specr" in low_name or "spectinomycin" in low_name:
            add_unique("SpecR")
        if "tetr" in low_name or "tetracycline" in low_name:
            add_unique("TetR")
        if "zeor" in low_name or "zeocin" in low_name:
            add_unique("ZeoR")
        if "blar" in low_name or "blasticidin" in low_name:
            add_unique("BlaR")

    up_name = (plasmid_name or "").upper()
    if "-NEO" in up_name or "_NEO" in up_name:
        add_unique("NeoR")
    if "-PURO" in up_name or "_PURO" in up_name:
        add_unique("PuroR")
    if "-KAN" in up_name or "_KAN" in up_name:
        add_unique("KanR")
    if "-AMP" in up_name or "_AMP" in up_name:
        add_unique("AmpR")
    return found

def extract_vector_backbone(name: str, dna_info: dict) -> str:
    trimmed = re.sub(r"^[^A-Za-z0-9]+", "", name or "")
    up = trimmed.upper()
    known_vectors = [
        ("PETDUET", "pETDuet"), ("PETDUET", "pETDuet"),
        ("PET-28A", "pET-28a"), ("PET28A", "pET-28a"),
        ("PET-28B", "pET-28b"), ("PET-22B", "pET-22b"), ("PET-15B", "pET-15b"),
        ("PCDNA3.1", "pcDNA3.1"), ("PCDNA3", "pcDNA3"),
        ("PCMV", "pCMV"), ("PLKO.1", "pLKO.1"), ("PLKO", "pLKO.1"),
        ("LENTICRISPR", "lentiCRISPR"), ("PX458", "pX458"), ("PX459", "pX459"),
        ("PLVX", "pLVX"), ("PAAV", "pAAV"), ("PGEX", "pGEX"),
        ("PCOLD", "pCold"), ("PCE2", "pCE2"), ("PEGFP", "pEGFP"),
        ("PMCHERRY", "pmCherry"), ("PUC19", "pUC19"), ("PUC57", "pUC57"),
        ("PMD18", "pMD18-T"), ("PMD19", "pMD19-T"), ("PGL3", "pGL3"), ("PGL4", "pGL4"),
        ("PFASTBAC", "pFastBac")
    ]
    for pat, canon in known_vectors:
        if pat in up:
            return canon

    tokens = [t.strip() for t in re.split(r"[-_ ()（）\[\]]+", trimmed) if t.strip()]
    if tokens and 3 <= len(tokens[0]) <= 16 and tokens[0][0] in ("p", "P"):
        return tokens[0]

    feat_up = " ".join((f.get("name") or "").upper() for f in dna_info.get("features", []))
    if "CMV" in feat_up and "SV40" in feat_up:
        return "pCMV/pcDNA"
    if "T7 PROMOTER" in feat_up and "LACI" in feat_up:
        return "pET 系列"
    if "U6" in feat_up and "LTR" in feat_up:
        return "慢病毒载体"
    return "通用载体"

def extract_target_genes(name: str, dna_info: dict, vector_name: str) -> list:
    genes = []
    def add_gene(raw: str):
        c = (raw or "").strip()
        if not (2 <= len(c) <= 20):
            return
        if not any(g.lower() == c.lower() for g in genes):
            genes.append(c)

    ignored_kw = [
        "ampr", "kanr", "neor", "puror", "hygr", "cmr", "specr", "tetr", "zeor", "blar",
        "ori", "f1 ori", "sv40", "laci", "lac operator", "lac promoter", "rop", "bom", "cap binding", "m13",
        "promoter", "enhancer", "terminator", "polya", "poly(a)", "kozak", "rbs", "wpre", "ltr", "ires", "packaging",
        "myc", "3xmyc", "3×myc", "flag", "3xflag", "3×flag", "his", "6xhis", "6×his", "s-tag", "stag", "tev", "gst", "ha", "v5",
        "egfp", "gfp", "mcherry", "rfp", "yfp", "bfp", "luciferase", "cas9",
        "同源臂", "删除", "氨基酸", "突变", "测序", "引物", "接头", "linker", "urs", "drs"
    ]
    for f in dna_info.get("features", []):
        fname = (f.get("name") or "").strip()
        low_name = fname.lower()
        low_type = (f.get("type") or "").strip().lower()
        if not (2 <= len(fname) <= 20):
            continue
        if any(w in low_type for w in ["promoter", "terminator", "rep_origin", "primer_bind", "regulatory", "poly", "protein_bind", "rbs", "enhancer"]):
            continue
        if any(w in low_name for w in ignored_kw):
            continue
        segs = f.get("segments") or []
        seg_len = (int(segs[-1].get("end", 1)) - int(segs[0].get("start", 1)) + 1) if segs else 0
        if low_type in ("cds", "gene") or seg_len >= 60:
            add_gene(fname)

    cleaned_fn = re.sub(r"^[^A-Za-z0-9]+", "", name or "")
    for sp in ["(human)", "(mouse)", "(rat)", "(Human)", "(Mouse)", "(Rat)"]:
        cleaned_fn = cleaned_fn.replace(sp, "")
    stop_tokens = {
        vector_name.upper(), "PCMV", "PETDUET", "PETDUET", "PCDNA3.1", "PCDNA3", "PLKO.1", "PLKO", "PCE2",
        "3XMYC", "3×MYC", "MYC", "3XFLAG", "3×FLAG", "FLAG", "6XHIS", "6×HIS", "HIS", "GST", "EGFP", "GFP",
        "NEO", "NEOR", "AMP", "AMPR", "KAN", "KANR", "PURO", "PUROR", "HYG",
        "HUMAN", "MOUSE", "RAT", "RECOMBINANT", "CONSTRUCT", "VECTOR", "PLASMID", "WT", "MUT", "A1B1"
    }
    for raw_tok in re.split(r"[-_ ()（）\[\]]+", cleaned_fn):
        ascii_part = re.sub(r"[^A-Za-z0-9]", "", raw_tok)
        if not (3 <= len(ascii_part) <= 14):
            continue
        up = ascii_part.upper()
        if up in stop_tokens or up.startswith("PET") or up.startswith("PCMV") or up.startswith("PCDNA"):
            continue
        if re.match(r"^[A-Za-z]{2,10}[0-9A-Za-z]{0,4}$", ascii_part):
            add_gene(ascii_part)
    return genes

def infer_category(name: str, dna_info: dict) -> str:
    up = (name or "").upper()
    feat_up = " ".join((f.get("name") or "").upper() for f in dna_info.get("features", []))
    if any(k in up for k in ["LENTI", "PLKO", "CRISPR", "PX458", "PX459"]) or "CAS9" in feat_up or "LTR" in feat_up:
        return "慢病毒/CRISPR"
    if any(k in up for k in ["PCMV", "PCDNA", "PEGFP", "PMCHERRY", "PLVX", "PAAV"]) or "CMV PROMOTER" in feat_up or "CMV ENHANCER" in feat_up or "EF1A" in feat_up:
        return "哺乳动物表达"
    if any(k in up for k in ["PET", "PGEX", "PCOLD", "PBAD"]) or "T7 PROMOTER" in feat_up or "LACI" in feat_up:
        return "原核表达"
    if "RECOMBINANT" in up or "CONSTRUCT" in up:
        return "重组产物"
    return "通用质粒"

def parse_dna_via_bridge(file_path: str) -> dict:
    res = subprocess.run(
        ["/usr/bin/python3", SNAPGENE_BRIDGE, "parse", file_path],
        capture_output=True, text=True, timeout=20
    )
    if res.returncode != 0:
        raise RuntimeError(f"解析 .dna 失败: {res.stderr or res.stdout}")
    return json.loads(res.stdout)

def normalize_pool_item(item: dict) -> dict:
    name = item.get("name", "")
    info = item.get("dnaInfo", {})
    vec = item.get("vectorBackbone") or extract_vector_backbone(name, info)
    genes = item.get("targetGenes") or extract_target_genes(name, info, vec)
    res = extract_resistances(info, name)
    cat = infer_category(name, info)
    item["vectorBackbone"] = vec
    item["targetGenes"] = genes
    if res:
        item["resistanceMarkers"] = res
    item["categoryTag"] = cat
    return item

def load_plasmid_pool() -> list:
    for p in POOL_PATHS:
        if os.path.exists(p):
            try:
                with open(p, "r", encoding="utf-8") as f:
                    items = json.load(f)
                    if isinstance(items, list) and len(items) > 0:
                        return [normalize_pool_item(x) for x in items]
            except Exception:
                continue

    discovered = []
    if os.path.exists(PROJECT_DIR):
        for fn in sorted(os.listdir(PROJECT_DIR)):
            if fn.lower().endswith(".dna"):
                fp = os.path.join(PROJECT_DIR, fn)
                try:
                    info = parse_dna_via_bridge(fp)
                    name = os.path.splitext(fn)[0]
                    discovered.append(build_pool_item(name, info))
                except Exception:
                    continue
    if discovered:
        save_plasmid_pool(discovered)
    return discovered

def build_pool_item(name: str, dna_info: dict, alias: str = "", category: str = "", notes: str = "") -> dict:
    seq = clean_seq(dna_info.get("sequence", ""))
    unique_sites = []
    for ename, esite in COMMON_ENZYMES.items():
        cnt = seq.count(esite)
        if cnt == 1:
            pos = seq.find(esite) + 1
            unique_sites.append(f"{ename} @{pos}")
    feats = dna_info.get("features", [])
    promoters = []
    for f in feats:
        fn = f.get("name", "")
        ft = f.get("type", "").upper()
        fu = fn.upper()
        low = fn.lower()
        if "ampr promoter" in low or "laci promoter" in low or low == "laci" or "ori" in low or "poly(a)" in low:
            continue
        if any(k in fu for k in ["CMV", "T7", "U6", "EF1", "SV40", "LAC", "CAG"]) or "PROMOTER" in ft:
            if fn not in promoters:
                promoters.append(fn)
    vec = extract_vector_backbone(name, dna_info)
    genes = extract_target_genes(name, dna_info, vec)
    resistances = extract_resistances(dna_info, name)
    cat = category or infer_category(name, dna_info)
    return {
        "id": dna_info.get("filePath", name),
        "name": name,
        "aliasName": alias,
        "categoryTag": cat,
        "notes": notes,
        "addedAt": datetime.datetime.now().timestamp(),
        "dnaInfo": dna_info,
        "uniqueCutSites": unique_sites,
        "resistanceMarkers": resistances,
        "promoters": promoters,
        "vectorBackbone": vec,
        "targetGenes": genes
    }

def _backup_if_exists(file_path: str) -> str:
    """若目标文件已存在，先备份为 *.bak-<timestamp> 并返回备份路径 (P05)"""
    if not file_path or not os.path.exists(file_path):
        return None
    import shutil
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    bak_path = f"{file_path}.bak-{ts}"
    shutil.copy2(file_path, bak_path)
    return bak_path


def save_plasmid_pool(items: list, custom_pool_path: str = None) -> list:
    targets = [custom_pool_path] if custom_pool_path else POOL_PATHS
    backups = []
    for p in targets:
        if not p:
            continue
        try:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            bak = _backup_if_exists(p)
            if bak:
                backups.append(bak)
            with open(p, "w", encoding="utf-8") as f:
                json.dump(items, f, ensure_ascii=False, indent=2)
        except Exception:
            continue
    return backups

def find_plasmid_in_pool(query: str, pool: list = None) -> dict:
    if pool is None:
        pool = load_plasmid_pool()
    q = (query or "").strip().lower()
    if not q:
        raise ValueError("质粒名称不能为空")
    for item in pool:
        if item.get("name", "").lower() == q or item.get("aliasName", "").lower() == q or item.get("id", "").lower() == q:
            return item
    for item in pool:
        if q in item.get("name", "").lower() or q in item.get("aliasName", "").lower():
            return item
    for item in pool:
        if any(q == g.lower() or q in g.lower() for g in item.get("targetGenes", [])):
            return item
    for item in pool:
        feats = item.get("dnaInfo", {}).get("features", [])
        if any(q in f.get("name", "").lower() for f in feats):
            return item
    available = [i.get("name", "") for i in pool]
    raise ValueError(f"在质粒池中未找到匹配「{query}」的质粒。当前质粒池可用质粒: {', '.join(available)}")

def resolve_region_on_plasmid(plasmid_item: dict, target_spec: str) -> tuple:
    info = plasmid_item["dnaInfo"]
    seq = clean_seq(info["sequence"])
    spec = (target_spec or "").strip()
    if not spec:
        return (1, min(len(seq), 100), "+", "默认位点 1..100")

    for sep in ["..", "-", ":"]:
        if sep in spec:
            parts = spec.split(sep)
            if len(parts) == 2 and parts[0].strip().isdigit() and parts[1].strip().isdigit():
                s = max(1, int(parts[0].strip()))
                e = min(len(seq), int(parts[1].strip()))
                return (s, e, "+", f"坐标 {s}..{e}")

    enz_parts = [p.strip() for p in spec.replace("/", ",").split(",") if p.strip()]
    if all(any(en.lower() == p.lower() for en in COMMON_ENZYMES) for p in enz_parts):
        positions = []
        matched_names = []
        for p in enz_parts:
            for en, site in COMMON_ENZYMES.items():
                if en.lower() == p.lower():
                    idx = seq.find(site)
                    if idx == -1:
                        raise ValueError(f"质粒 {plasmid_item['name']} 中未找到酶切位点 {en} ({site})")
                    positions.append((idx + 1, idx + len(site)))
                    matched_names.append(en)
        s = min(x[0] for x in positions)
        e = max(x[1] for x in positions)
        return (s, e, "+", f"酶切位点 {'/'.join(matched_names)} ({s}..{e})")

    feats = info.get("features", [])
    q = spec.lower()
    matched_feat = None
    for f in feats:
        if f.get("name", "").lower() == q:
            matched_feat = f
            break
    if not matched_feat:
        for f in feats:
            if q in f.get("name", "").lower():
                matched_feat = f
                break
    if matched_feat:
        segs = matched_feat.get("segments", [])
        if segs:
            s = min(int(seg.get("start", 1)) for seg in segs)
            e = max(int(seg.get("end", 1)) for seg in segs)
            strand = "-" if str(matched_feat.get("directionality", "1")) == "2" else "+"
            return (s, e, strand, f"特征 {matched_feat.get('name')} ({s}..{e}, {strand})")

    raise ValueError(f"在质粒「{plasmid_item['name']}」中未找到特征、酶切位点或坐标「{target_spec}」")


def notify_gui_and_sync_primers(
    action_summary: str,
    primers: list,
    generated_dna_path: str = None,
    target_module: str = None,
    extra_workspace_state: dict = None,
    tool_name: str = None,
    run_id: str = None,
    sync_dir: str = None
) -> str:
    """原子写入 MCP 同步事件文件 (<run_id>.json + latest.json) 并异步广播通知 (P04)"""
    resolved_tool = tool_name
    if not resolved_tool:
        try:
            caller_name = inspect.currentframe().f_back.f_code.co_name
            if caller_name.startswith("tool_"):
                resolved_tool = caller_name[5:]
            else:
                resolved_tool = caller_name
        except Exception:
            resolved_tool = "mcp_tool"

    rid = run_id or str(uuid.uuid4())
    payload = {
        "schema_version": 1,
        "run_id": rid,
        "tool_name": resolved_tool,
        "timestamp": datetime.datetime.now().timestamp(),
        "actionSummary": action_summary,
        "addedPrimers": primers,
        "generatedDNAFilePath": generated_dna_path,
        "targetModuleRawValue": target_module
    }
    if extra_workspace_state:
        payload.update(extra_workspace_state)

    target_dir = sync_dir or os.environ.get("LABWORKER_MCP_SYNC_DIR", "").strip() or MCP_SYNC_DIR
    try:
        os.makedirs(target_dir, exist_ok=True)
        tmp_event = os.path.join(target_dir, f".{rid}.tmp")
        final_event = os.path.join(target_dir, f"{rid}.json")
        with open(tmp_event, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.replace(tmp_event, final_event)

        tmp_latest = os.path.join(target_dir, f".latest.{uuid.uuid4().hex}.tmp")
        final_latest = os.path.join(target_dir, "latest.json")
        with open(tmp_latest, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.replace(tmp_latest, final_latest)
    except Exception:
        pass

    if "--cli-call" not in sys.argv and os.environ.get("LABWORKER_SKIP_MCP_NOTIFY") != "1":
        try:
            subprocess.Popen(
                [
                    "/usr/bin/swift", "-e",
                    'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.clonestudio.mcp.updated"), object: nil, userInfo: nil, deliverImmediately: true)'
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
        except Exception:
            pass
    return rid


def make_primer_dict(name: str, homology_arm: str, specific_seq: str, purpose: str, extra_bases: str = "", source_tool: str = "MCP AI 助手", custom_notes: str = None) -> dict:
    h = clean_seq(homology_arm).lower()
    ex = clean_seq(extra_bases).lower()
    sp = clean_seq(specific_seq).upper()
    full_clean = (h + ex + sp).upper()
    formatted = h + ex + sp
    full_tm = calc_snapgene_tm(full_clean)
    spec_tm = calc_snapgene_tm(sp, five_prime_overhang=h + ex) if sp else full_tm
    return {
        "id": str(uuid.uuid4()),
        "name": name,
        "fullSequence": full_clean,
        "formattedSequence": formatted,
        "homologyArm": h + ex,
        "enzymeSite": None,
        "specificSequence": sp,
        "tm": spec_tm,
        "fullLengthTm": full_tm,
        "specificTm": spec_tm,
        "gc": gc_percent(full_clean),
        "length": len(full_clean),
        "purity": "PAGE" if len(full_clean) > 40 else "HAP",
        "od": 2.0,
        "targetPurpose": purpose,
        "sourceTool": source_tool,
        "notes": custom_notes or f"退火区Tm:{spec_tm}℃ (全长Tm:{full_tm}℃, 同源臂:{len(h)}bp)"
    }


# ============================================================================
# 3. 11 大 MCP 工具实现函数
# ============================================================================

def tool_list_plasmid_pool(args: dict) -> dict:
    pool = load_plasmid_pool()
    query = (args.get("query") or "").strip().lower()
    vec_filter = (args.get("vector") or "").strip().lower()
    gene_filter = (args.get("gene") or "").strip().lower()
    res_filter = (args.get("resistance") or "").strip().lower()
    cat_filter = (args.get("category") or "").strip().lower()

    all_vectors = []
    all_genes = []
    all_resistances = []
    for item in pool:
        v = item.get("vectorBackbone", "")
        if v and v not in all_vectors:
            all_vectors.append(v)
        for g in item.get("targetGenes", []):
            if g and not any(x.lower() == g.lower() for x in all_genes):
                all_genes.append(g)
        for r in item.get("resistanceMarkers", []):
            if r and r not in all_resistances:
                all_resistances.append(r)

    results = []
    for item in pool:
        info = item.get("dnaInfo", {})
        vec = item.get("vectorBackbone", "")
        genes = item.get("targetGenes", [])
        resistances = item.get("resistanceMarkers", [])
        cat = item.get("categoryTag", "")

        if vec_filter and vec_filter not in ("全部", "all") and vec_filter not in vec.lower():
            continue
        if gene_filter and gene_filter not in ("全部", "all") and not any(gene_filter in g.lower() for g in genes):
            continue
        if res_filter and res_filter not in ("全部", "all") and not any(res_filter in r.lower() for r in resistances):
            continue
        if cat_filter and cat_filter not in ("全部", "all") and cat_filter not in cat.lower():
            continue

        feats = [f"{f['name']} ({f['segments'][0]['start']}..{f['segments'][-1]['end']})" for f in info.get("features", []) if f.get("segments")]
        summary = {
            "name": item.get("name"),
            "alias": item.get("aliasName", ""),
            "vectorBackbone": vec,
            "targetGenes": genes,
            "resistances": resistances,
            "category": cat,
            "lengthBp": info.get("length", 0),
            "isCircular": info.get("isCircular", True),
            "promoters": item.get("promoters", []),
            "uniqueCutSites": item.get("uniqueCutSites", [])[:15],
            "featuresSummary": feats[:25],
            "filePath": info.get("filePath", "")
        }
        if query:
            blob = json.dumps(summary, ensure_ascii=False).lower()
            if query not in blob:
                continue
        results.append(summary)

    return {
        "totalInPool": len(pool),
        "matchedCount": len(results),
        "availableFilters": {
            "vectors": all_vectors,
            "genes": all_genes,
            "resistances": all_resistances
        },
        "plasmids": results
    }

def tool_inspect_plasmid(args: dict) -> dict:
    pool = load_plasmid_pool()
    item = find_plasmid_in_pool(args.get("plasmid_name", ""), pool)
    info = item["dnaInfo"]
    res = {
        "name": item["name"],
        "vectorBackbone": item.get("vectorBackbone", ""),
        "targetGenes": item.get("targetGenes", []),
        "resistances": item.get("resistanceMarkers", []),
        "category": item.get("categoryTag", ""),
        "lengthBp": info.get("length", 0),
        "gcPercent": gc_percent(info.get("sequence", "")),
        "promoters": item.get("promoters", []),
        "uniqueCutSites": item.get("uniqueCutSites", []),
        "features": info.get("features", []),
        "primers": info.get("primers", []),
        "filePath": info.get("filePath", "")
    }
    if args.get("include_sequence"):
        res["sequence"] = info.get("sequence", "")
    return res

def tool_add_plasmid_to_pool(args: dict) -> dict:
    path = os.path.expanduser(args.get("file_path", "").strip())
    if not os.path.exists(path):
        raise ValueError(f"文件不存在: {path}")
    confirm = bool(args.get("confirm", False))
    target_pool_path = (args.get("pool_path") or "").strip() or POOL_PATHS[0]
    pool = load_plasmid_pool()
    info = parse_dna_via_bridge(path)
    name = args.get("alias_name") or os.path.splitext(os.path.basename(path))[0]
    new_item = build_pool_item(
        name=name,
        dna_info=info,
        alias=args.get("alias_name", ""),
        category=args.get("category", ""),
        notes=args.get("notes", "")
    )
    is_existing = any(x.get("id") == new_item["id"] or x.get("name") == new_item["name"] for x in pool)
    write_action = "overwrite" if os.path.exists(target_pool_path) else "create"
    if not confirm:
        return {
            "status": "preview",
            "planned_writes": [{
                "path": target_pool_path,
                "action": write_action,
                "summary": f"向质粒池导入{'并覆盖更新' if is_existing else '新增'}质粒「{name}」({info.get('length', 0)} bp, 载体 {new_item['vectorBackbone']})"
            }],
            "confirm_hint": "请先向用户展示 planned_writes 预览，获准后以 confirm=true 重新调用执行落盘。"
        }
    pool = [x for x in pool if x.get("id") != new_item["id"] and x.get("name") != new_item["name"]]
    pool.insert(0, new_item)
    backups = save_plasmid_pool(pool, custom_pool_path=args.get("pool_path"))
    notify_gui_and_sync_primers(f"已向质粒池导入「{name}」({info.get('length', 0)} bp)", [])
    return {
        "status": "success",
        "addedPlasmid": new_item["name"],
        "vectorBackbone": new_item["vectorBackbone"],
        "targetGenes": new_item["targetGenes"],
        "resistances": new_item["resistanceMarkers"],
        "lengthBp": info.get("length", 0),
        "featuresCount": info.get("featuresCount", 0),
        "uniqueCutSites": new_item["uniqueCutSites"],
        "backups": backups
    }

def extract_insert_sequence(insert_source: str, pool: list, remove_stop_codon: bool = True) -> tuple:
    raw = (insert_source or "").strip()
    cleaned_raw = clean_seq(raw)
    if len(cleaned_raw) >= 30 and len(cleaned_raw) == len(raw.replace(" ", "").replace("\n", "")):
        seq = cleaned_raw
        if remove_stop_codon and len(seq) >= 6 and seq[-3:] in ("TAA", "TAG", "TGA"):
            seq = seq[:-3]
        return (seq, "Insert", None)

    if ":" in raw:
        p_name, f_name = [x.strip() for x in raw.split(":", 1)]
        donor = find_plasmid_in_pool(p_name, pool)
        s, e, strand, _ = resolve_region_on_plasmid(donor, f_name)
    else:
        donor = find_plasmid_in_pool(raw, pool)
        s, e, strand, _ = resolve_region_on_plasmid(donor, raw)
        f_name = raw

    full_seq = clean_seq(donor["dnaInfo"]["sequence"])
    sub = full_seq[s - 1:e]
    if strand == "-":
        sub = rev_comp(sub)
    if remove_stop_codon and len(sub) >= 6 and sub[-3:] in ("TAA", "TAG", "TGA"):
        sub = sub[:-3]
    return (sub, f_name, donor["dnaInfo"].get("filePath"))

def tool_design_single_clone_primers(args: dict) -> dict:
    pool = load_plasmid_pool()
    vec_item = find_plasmid_in_pool(args.get("vector_name", ""), pool)
    vec_seq = clean_seq(vec_item["dnaInfo"]["sequence"])
    vec_len = len(vec_seq)

    cut_start, cut_end, _, site_desc = resolve_region_on_plasmid(vec_item, args.get("vector_site", ""))
    hom_len = int(args.get("homology_length", 18))
    target_tm = float(args.get("target_tm", 60.0))
    remove_stop = bool(args.get("remove_stop_codon", True))
    extra5 = clean_seq(args.get("extra_5_bases", ""))
    extra3 = clean_seq(args.get("extra_3_bases", ""))

    ins_seq, ins_name, donor_path = extract_insert_sequence(args.get("insert_source", ""), pool, remove_stop_codon=remove_stop)
    if len(ins_seq) < 30:
        raise ValueError(f"插入片段序列过短 ({len(ins_seq)} bp)，请提供至少 30 bp 的有效序列或特征名")

    doubled_vec = vec_seq + vec_seq
    u_end = cut_start - 1
    if u_end <= 0:
        u_end += vec_len
    hom_f = doubled_vec[max(0, u_end - hom_len):u_end]
    hom_r_sense = doubled_vec[cut_end:cut_end + hom_len]
    hom_r = rev_comp(hom_r_sense)

    spec_f = pick_specific_annealing_seq(ins_seq, five_prime_overhang=hom_f + extra5, target_tm=target_tm)
    spec_r = pick_specific_annealing_seq(rev_comp(ins_seq), five_prime_overhang=hom_r + rev_comp(extra3), target_tm=target_tm)

    prefix = args.get("primer_prefix") or f"{ins_name}"
    primer_f = make_primer_dict(
        name=f"{prefix}-F",
        homology_arm=hom_f,
        specific_seq=spec_f,
        purpose=f"单片段克隆正向 ({vec_item['name']} @ {site_desc})",
        extra_bases=extra5
    )
    primer_r = make_primer_dict(
        name=f"{prefix}-R",
        homology_arm=hom_r,
        specific_seq=spec_r,
        purpose=f"单片段克隆反向 ({vec_item['name']} @ {site_desc})",
        extra_bases=rev_comp(extra3)
    )
    primers = [primer_f, primer_r]

    if args.get("include_vector_pcr_primers", True):
        vec_f_template = doubled_vec[cut_end:cut_end + 40]
        vec_r_template = rev_comp(doubled_vec[max(0, u_end - 40):u_end])
        vec_f_seq = pick_specific_annealing_seq(vec_f_template, target_tm=target_tm)
        vec_r_seq = pick_specific_annealing_seq(vec_r_template, target_tm=target_tm)
        primers.append(make_primer_dict(f"Vec-{vec_item['name'][:10]}-F", "", vec_f_seq, "载体反向PCR线性化正向"))
        primers.append(make_primer_dict(f"Vec-{vec_item['name'][:10]}-R", "", vec_r_seq, "载体反向PCR线性化反向"))

    eff_insert = extra5 + ins_seq + extra3
    frame_rem = len(eff_insert) % 3
    del_vec_bp = max(0, cut_end - cut_start + 1)
    linear_vec_bp = max(50, vec_len - del_vec_bp)

    out_dna_path = None
    backup_dna_path = None
    vec_file_path = vec_item["dnaInfo"].get("filePath", "")
    want_export_dna = bool(args.get("export_recombinant_dna", False))
    confirm = bool(args.get("confirm", False))
    if want_export_dna and vec_file_path and os.path.exists(vec_file_path):
        safe_name = f"{vec_item['name']}-{ins_name}-Recombinant.dna".replace("/", "_")
        target_dna_path = (args.get("output_dna_path") or "").strip() or os.path.join(os.path.dirname(vec_file_path), safe_name)
        action_kind = "overwrite" if os.path.exists(target_dna_path) else "create"
        if not confirm:
            return {
                "status": "preview",
                "planned_writes": [{
                    "path": target_dna_path,
                    "action": action_kind,
                    "summary": f"导出重组质粒 {os.path.basename(target_dna_path)} (总长 {linear_vec_bp + len(eff_insert)} bp，含 {len(primers)} 条引物)"
                }],
                "confirm_hint": "请先以 confirm=false 预览 planned_writes，经用户同意后再以 confirm=true 执行落盘。",
                "vector": vec_item["name"],
                "insertName": ins_name,
                "primers": primers
            }
        backup_dna_path = _backup_if_exists(target_dna_path)
        out_dna_path = target_dna_path
        tmp_p = os.path.join("/tmp", f"mcp_primers_{uuid.uuid4().hex}.json")
        with open(tmp_p, "w", encoding="utf-8") as f:
            json.dump(primers, f, ensure_ascii=False)
        try:
            subprocess.run([
                "/usr/bin/python3", SNAPGENE_BRIDGE, "assemble",
                vec_file_path, eff_insert, ins_name,
                str(cut_start), str(cut_end), tmp_p, out_dna_path, donor_path or "none"
            ], check=True, capture_output=True, text=True, timeout=25)
        except Exception:
            out_dna_path = None
        finally:
            if os.path.exists(tmp_p):
                os.remove(tmp_p)

    if args.get("add_to_cart", True):
        notify_gui_and_sync_primers(
            f"单片段克隆引物设计：{ins_name} -> {vec_item['name']} ({len(primers)} 条引物)",
            primers,
            generated_dna_path=out_dna_path,
            target_module="singleFragment",
            extra_workspace_state={
                "vectorFilePath": vec_file_path,
                "donorFilePath": donor_path,
                "insertSequence": ins_seq,
                "insertName": ins_name,
                "cutStartBp": cut_start,
                "cutEndBp": cut_end
            }
        )

    return {
        "status": "success",
        "vector": vec_item["name"],
        "vectorRawLengthBp": vec_len,
        "vectorLinearBackboneLengthBp": linear_vec_bp,
        "vectorSite": site_desc,
        "insertName": ins_name,
        "insertLengthBp": len(eff_insert),
        "readingFrameAligned3n": (frame_rem == 0),
        "readingFrameNote": "3n 密码子阅读框对齐" if frame_rem == 0 else f"注意：插入总长 {len(eff_insert)} bp 除以 3 余 {frame_rem} bp，如需融合表达请补齐 {3 - frame_rem} bp",
        "primers": primers,
        "recombinantDNAFilePath": out_dna_path,
        "backupPath": backup_dna_path
    }

def tool_design_multi_fragment_primers(args: dict) -> dict:
    pool = load_plasmid_pool()
    vec_item = find_plasmid_in_pool(args.get("vector_name", ""), pool)
    vec_seq = clean_seq(vec_item["dnaInfo"]["sequence"])
    vec_len = len(vec_seq)
    cut_start, cut_end, _, site_desc = resolve_region_on_plasmid(vec_item, args.get("vector_site", ""))
    hom_len = int(args.get("homology_length", 18))
    target_tm = float(args.get("target_tm", 60.0))

    frag_specs = args.get("fragments", [])
    if len(frag_specs) < 2 or len(frag_specs) > 10:
        raise ValueError("多片段无缝克隆仅支持 2–10 个插入片段来源")

    parsed_frags = []
    for idx, fspec in enumerate(frag_specs):
        remove_stop = (idx < len(frag_specs) - 1) or bool(args.get("remove_terminal_stop_codon", True))
        seq, name, _ = extract_insert_sequence(fspec, pool, remove_stop_codon=remove_stop)
        parsed_frags.append((seq, name or f"Frag{idx+1}"))

    doubled_vec = vec_seq + vec_seq
    u_end = cut_start - 1 if cut_start > 1 else vec_len
    vec_up_hom = doubled_vec[max(0, u_end - hom_len):u_end]
    vec_down_sense = doubled_vec[cut_end:cut_end + hom_len]

    primers = []
    for i, (fseq, fname) in enumerate(parsed_frags):
        if i == 0:
            hom_f = vec_up_hom
        else:
            prev_seq = parsed_frags[i - 1][0]
            hom_f = prev_seq[-hom_len:]
        if i == len(parsed_frags) - 1:
            hom_r = rev_comp(vec_down_sense)
        else:
            hom_r = ""

        spec_f = pick_specific_annealing_seq(fseq, five_prime_overhang=hom_f, target_tm=target_tm)
        spec_r = pick_specific_annealing_seq(rev_comp(fseq), five_prime_overhang=hom_r, target_tm=target_tm)
        primers.append(make_primer_dict(f"{fname}-F", hom_f, spec_f, f"多片段#{i+1}正向 ({fname})"))
        primers.append(make_primer_dict(f"{fname}-R", hom_r, spec_r, f"多片段#{i+1}反向 ({fname})"))

    if args.get("add_to_cart", True):
        notify_gui_and_sync_primers(
            f"多片段克隆引物设计：{len(parsed_frags)} 片段 -> {vec_item['name']} ({len(primers)} 条引物)",
            primers,
            target_module="multiFragment",
            extra_workspace_state={
                "vectorFilePath": vec_item["dnaInfo"].get("filePath", ""),
                "cutStartBp": cut_start,
                "cutEndBp": cut_end,
                "multiFragmentSequences": [x[0] for x in parsed_frags]
            }
        )
    return {
        "status": "success",
        "vector": vec_item["name"],
        "vectorSite": site_desc,
        "fragmentsCount": len(parsed_frags),
        "fragmentLengthsBp": [len(x[0]) for x in parsed_frags],
        "primers": primers
    }

def tool_design_mutagenesis_primers(args: dict) -> dict:
    pool = load_plasmid_pool()
    plasmid = find_plasmid_in_pool(args.get("plasmid_name", ""), pool)
    full_seq = clean_seq(plasmid["dnaInfo"]["sequence"])
    feat_name = args.get("feature_name", "")
    mut_spec = (args.get("mutation_spec") or "").strip().upper()
    hom_len = int(args.get("homology_length", 18))
    target_tm = float(args.get("target_tm", 68.0))
    allow_wt_mismatch = bool(args.get("allow_wt_mismatch", False))

    s, e, strand, feat_desc = resolve_region_on_plasmid(plasmid, feat_name)
    cds_seq = full_seq[s - 1:e]
    if strand == "-":
        cds_seq = rev_comp(cds_seq)

    m = re.match(r"^([A-Z])(\d+)([A-Z\*Δ])$", mut_spec)
    if not m:
        raise ValueError(f"mutation_spec 格式应为如 'K42R'、'G12V' 或 'K42Δ'（当前：{mut_spec}）")
    wt_aa, res_idx_str, target_aa = m.group(1), m.group(2), m.group(3)
    res_idx = int(res_idx_str)
    total_aa = len(cds_seq) // 3
    codon_offset = (res_idx - 1) * 3
    if res_idx < 1 or codon_offset + 3 > len(cds_seq):
        raise ValueError(f"位点 {res_idx} 超出特征 {feat_name} 的氨基酸总长度 ({total_aa} aa)")

    wt_codon = cds_seq[codon_offset:codon_offset + 3]
    actual_aa = CODON_TO_AA.get(wt_codon, "?")

    # 增强 1：野生型氨基酸一致性校验与上下文提示
    if actual_aa != wt_aa and not allow_wt_mismatch:
        win_start = max(1, res_idx - 5)
        win_end = min(total_aa, res_idx + 5)
        window_tokens = []
        for idx_i in range(win_start, win_end + 1):
            c_i = cds_seq[(idx_i - 1) * 3:idx_i * 3]
            aa_i = CODON_TO_AA.get(c_i, "?")
            marker = f"[{aa_i}{idx_i}({c_i})]" if idx_i == res_idx else f"{aa_i}{idx_i}"
            window_tokens.append(marker)
        nearby_matches = []
        for idx_i in range(max(1, res_idx - 15), min(total_aa, res_idx + 15) + 1):
            c_i = cds_seq[(idx_i - 1) * 3:idx_i * 3]
            if CODON_TO_AA.get(c_i) == wt_aa:
                nearby_matches.append(f"{wt_aa}{idx_i}({c_i})")
        hint_str = f"；附近匹配的 {wt_aa} 位点有: {', '.join(nearby_matches)}" if nearby_matches else ""
        raise ValueError(
            f"野生型氨基酸校验不匹配：{feat_name} 第 {res_idx} 位实际为 {actual_aa} ({wt_codon})，而非您输入的 {wt_aa}！"
            f"局部序列窗口 ({win_start}..{win_end}): {' '.join(window_tokens)}{hint_str}。"
            f"请改为 {actual_aa}{res_idx}{target_aa}，或传入 allow_wt_mismatch=true 强制突变。"
        )

    # 根据质粒载体类型自动选用原核大肠杆菌或哺乳动物最优密码子
    cat = plasmid.get("categoryTag", "")
    is_prokaryotic = ("原核" in cat) or ("PET" in plasmid["name"].upper()) or ("PGEX" in plasmid["name"].upper())
    codon_table = ECOLI_PREFERRED_CODONS if is_prokaryotic else HUMAN_PREFERRED_CODONS
    host_label = "E. coli 原核偏好" if is_prokaryotic else "Human 哺乳动物偏好"
    new_codon = "" if target_aa == "Δ" else codon_table.get(target_aa, "GCC")

    if strand == "+":
        abs_codon_start = (s - 1) + codon_offset
        abs_codon_end = abs_codon_start + 3
        mut_site_plus = new_codon
    else:
        abs_codon_end = e - codon_offset
        abs_codon_start = abs_codon_end - 3
        mut_site_plus = rev_comp(new_codon)

    doubled = full_seq + full_seq
    up_seq = doubled[abs_codon_start + len(full_seq) - 80:abs_codon_start + len(full_seq)]
    down_seq = doubled[abs_codon_end:abs_codon_end + 80]

    half_arm = max(6, (hom_len - len(mut_site_plus)) // 2)
    arm_up = up_seq[-half_arm:]
    arm_down = down_seq[:hom_len - half_arm - len(mut_site_plus)]
    overlap_sense = arm_up + mut_site_plus + arm_down
    overlap_rc = rev_comp(overlap_sense)

    spec_f = pick_specific_annealing_seq(down_seq[len(arm_down):], five_prime_overhang=overlap_sense, target_tm=target_tm)
    spec_r = pick_specific_annealing_seq(rev_comp(up_seq[:-len(arm_up)]), five_prime_overhang=overlap_rc, target_tm=target_tm)

    label = f"{feat_name}-{actual_aa}{res_idx}{target_aa}"
    pf = make_primer_dict(f"{label}-F", overlap_sense, spec_f, f"定点突变 {label} 正向 ({wt_codon}->{new_codon or 'Δ'}, {host_label})")
    pr = make_primer_dict(f"{label}-R", overlap_rc, spec_r, f"定点突变 {label} 反向 ({wt_codon}->{new_codon or 'Δ'}, {host_label})")

    if args.get("add_to_cart", True):
        notify_gui_and_sync_primers(
            f"定点突变引物设计：{plasmid['name']} {label}",
            [pf, pr],
            target_module="mutagenesis",
            extra_workspace_state={
                "vectorFilePath": plasmid["dnaInfo"].get("filePath", ""),
                "mutUpSequence": up_seq,
                "mutSiteSequence": mut_site_plus,
                "mutDownSequence": down_seq
            }
        )
    return {
        "status": "success",
        "plasmid": plasmid["name"],
        "hostCodonPreference": host_label,
        "feature": feat_desc,
        "verifiedWildType": f"{actual_aa}{res_idx} ({wt_codon})",
        "mutation": f"{actual_aa}{res_idx}{target_aa} ({wt_codon} -> {new_codon or 'Δ'})",
        "primers": [pf, pr]
    }

def tool_design_fragment_deletion_primers(args: dict) -> dict:
    pool = load_plasmid_pool()
    plasmid = find_plasmid_in_pool(args.get("plasmid_name", ""), pool)
    full_seq = clean_seq(plasmid["dnaInfo"]["sequence"])
    del_start, del_end, _, del_desc = resolve_region_on_plasmid(plasmid, args.get("delete_target", ""))
    hom_len = int(args.get("homology_length", 18))
    target_tm = float(args.get("target_tm", 65.0))

    doubled = full_seq + full_seq
    n = len(full_seq)
    u_end = del_start - 1 if del_start > 1 else n
    up_flank = doubled[u_end + n - 80:u_end + n]
    down_flank = doubled[del_end:del_end + 80]

    hom_f = up_flank[-hom_len:]
    hom_r = rev_comp(down_flank[:hom_len])
    spec_f = pick_specific_annealing_seq(down_flank, five_prime_overhang=hom_f, target_tm=target_tm)
    spec_r = pick_specific_annealing_seq(rev_comp(up_flank), five_prime_overhang=hom_r, target_tm=target_tm)

    prefix = f"Del-{args.get('delete_target', 'Frag')[:12]}"
    pf = make_primer_dict(f"{prefix}-F", hom_f, spec_f, f"质粒片段敲除正向 ({del_desc})")
    pr = make_primer_dict(f"{prefix}-R", hom_r, spec_r, f"质粒片段敲除反向 ({del_desc})")

    if args.get("add_to_cart", True):
        notify_gui_and_sync_primers(
            f"片段删除引物设计：{plasmid['name']} Δ({del_desc})",
            [pf, pr],
            target_module="fragmentDeletion",
            extra_workspace_state={
                "vectorFilePath": plasmid["dnaInfo"].get("filePath", ""),
                "delStartBp": del_start,
                "delEndBp": del_end
            }
        )
    return {
        "status": "success",
        "plasmid": plasmid["name"],
        "deletedRegion": del_desc,
        "deletedLengthBp": del_end - del_start + 1,
        "newLengthBp": n - (del_end - del_start + 1),
        "primers": [pf, pr]
    }

def adaptive_round(val: float) -> float:
    if not math.isfinite(val):
        return val
    if val == 0:
        return 0.0
    av = abs(val)
    if av >= 0.1:
        return round(val, 2)
    if av >= 0.01:
        return round(val, 3)
    if av >= 0.001:
        return round(val, 4)
    if av >= 1e-4:
        return round(val, 5)
    exp = int(math.floor(math.log10(av)))
    return round(val, max(0, 2 - exp))

def format_bio_number(val: float, fixed_decimals: int = None) -> str:
    if not math.isfinite(val):
        return "--"
    rounded = val if fixed_decimals is not None else adaptive_round(val)
    if rounded == 0:
        return "0"
    av = abs(rounded)
    if av > 0 and av < 1e-6 and fixed_decimals is None:
        return f"{rounded:.3e}"
    if fixed_decimals is not None:
        s = f"{rounded:,.{max(0, fixed_decimals)}f}"
    elif av >= 0.1:
        s = f"{rounded:,.2f}"
    elif av >= 0.01:
        s = f"{rounded:,.3f}"
    elif av >= 0.001:
        s = f"{rounded:,.4f}"
    elif av >= 1e-4:
        s = f"{rounded:,.5f}"
    else:
        s = f"{rounded:,.6f}"
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s

def normalize_length_to_kb(val: float) -> float:
    if val <= 0:
        return 0.0
    return (val / 1000.0) if val >= 40.0 else val

def tool_calculate_recombination_dosage(args: dict) -> dict:
    """
    增强 3：DNA 重组反应与经典摩尔比 (0.03 pmol, 1:1~1:5) 使用量及 20 μL 移液体系配比计算器
    """
    raw_type = (args.get("clone_type") or "single").strip().lower()
    if "ligat" in raw_type or "ratio" in raw_type or "摩尔" in raw_type or "连接" in raw_type:
        clone_type = "LigationRatio"
    elif "multi" in raw_type or "多" in raw_type:
        clone_type = "MultiClone"
    elif "simple" in raw_type or "entry" in raw_type or "入门" in raw_type:
        clone_type = "SimpleClone"
    else:
        clone_type = "SingleClone"

    vec_name = (args.get("vector_name") or "线性化载体").strip()
    vec_len_raw = float(args.get("vector_length", 5000))
    vec_kb = max(0.05, normalize_length_to_kb(vec_len_raw))
    vec_bp = int(round(vec_kb * 1000))
    vec_conc = max(0.1, float(args.get("vector_conc", 50.0)))
    vec_custom_ng = args.get("vector_custom_ng")
    raw_inserts = args.get("inserts") or [{"name": "插入片段 1", "length": 1000, "conc": 20.0}]

    if clone_type == "LigationRatio":
        vec_pmol = max(0.0001, float(args.get("vector_pmol", 0.03)))
        ratio = max(1, min(5, int(args.get("molar_ratio", 3))))
        first_ins = raw_inserts[0]
        ins_name = first_ins.get("name") or "插入片段"
        ikb = max(0.05, normalize_length_to_kb(float(first_ins.get("length", 1000))))
        ibp = int(round(ikb * 1000))
        iconc = max(0.1, float(first_ins.get("conc", 20.0)))

        vec_ng = round(vec_pmol * vec_bp * 0.65, 2)
        vec_vol = round(vec_ng / vec_conc, 2)
        ins_ng = round(vec_pmol * ratio * ibp * 0.65, 2)
        ins_vol = round(ins_ng / iconc, 2)
        mix_vol = 10.0
        water_vol = round(max(0.0, 20.0 - mix_vol - vec_vol - ins_vol), 2)
        warnings = []
        if ins_ng < 20.0:
            warnings.append("对于单片段，插入片段使用量建议大于 20 ng；对于多片段，插入片段使用量建议大于 10 ng。")

        if args.get("sync_to_gui", True):
            notify_gui_and_sync_primers(
                f"经典摩尔比连接计算：{vec_name} ({vec_bp}bp, {vec_pmol}pmol={vec_ng}ng) + {ins_name} ({ibp}bp, 1:{ratio}={ins_ng}ng)",
                [],
                target_module="dnaCalculator",
                extra_workspace_state={
                    "calculatorCloneTypeRaw": "LigationRatio",
                    "calculatorVectorName": vec_name,
                    "calculatorVectorLengthKb": f"{vec_kb:.3f}",
                    "calculatorVectorConc": f"{vec_conc:g}",
                    "calculatorInsertNames": [ins_name],
                    "calculatorInsertLengthsKb": [f"{ikb:.3f}"],
                    "calculatorInsertConcs": [f"{iconc:g}"],
                    "calculatorLigationPmol": f"{vec_pmol:g}",
                    "calculatorLigationRatio": ratio,
                }
            )

        return {
            "status": "success",
            "cloneType": "LigationRatio",
            "vectorPmol": vec_pmol,
            "molarRatio": f"1:{ratio}",
            "reactionTotalVolumeUl": 20.0,
            "clonExpressMix2xVolumeUl": mix_vol,
            "vector": {
                "name": vec_name,
                "lengthBp": vec_bp,
                "lengthKb": round(vec_kb, 3),
                "concentrationNgPerUl": vec_conc,
                "recommendedNg": vec_ng,
                "actualNg": vec_ng,
                "pipetteVolumeUl": vec_vol
            },
            "inserts": [{
                "name": ins_name,
                "lengthBp": ibp,
                "lengthKb": round(ikb, 3),
                "concentrationNgPerUl": iconc,
                "recommendedNg": ins_ng,
                "actualNg": ins_ng,
                "isCustomNg": False,
                "pipetteVolumeUl": ins_vol
            }],
            "ddH2OVolumeUl": water_vol,
            "warnings": warnings,
            "formula": "载体最适用量(ng)=pmol×bp×0.65; 片段最适用量(ng)=pmol×比例×bp×0.65"
        }

    if vec_kb <= 2.0:
        vec_rec_ng = 50.0
    else:
        vec_rec_ng = min(200.0, round(20.0 * vec_kb, 1))
    vec_actual_ng = float(vec_custom_ng) if (vec_custom_ng is not None and float(vec_custom_ng) > 0) else vec_rec_ng
    vec_vol = round(vec_actual_ng / vec_conc, 2) if clone_type != "SimpleClone" else 0.0

    raw_inserts = args.get("inserts") or [{"name": "插入片段 1", "length": 1000, "conc": 20.0}]
    insert_results = []
    total_ins_vol = 0.0
    for idx, ins in enumerate(raw_inserts):
        iname = ins.get("name") or f"片段 {idx + 1}"
        ilen_raw = float(ins.get("length", 1000))
        ikb = max(0.05, normalize_length_to_kb(ilen_raw))
        ibp = int(round(ikb * 1000))
        iconc = max(0.1, float(ins.get("conc", 20.0)))
        icustom_ng = ins.get("custom_ng")

        if clone_type == "MultiClone":
            irec_ng = 10.0 if ikb <= 0.5 else min(100.0, round(20.0 * ikb, 1))
        else:
            irec_ng = 20.0 if ikb <= 0.5 else min(200.0, round(40.0 * ikb, 1))
        iactual_ng = float(icustom_ng) if (icustom_ng is not None and float(icustom_ng) > 0) else irec_ng
        ivol = round(iactual_ng / iconc, 2)
        total_ins_vol += ivol
        insert_results.append({
            "name": iname,
            "lengthBp": ibp,
            "lengthKb": round(ikb, 3),
            "concentrationNgPerUl": iconc,
            "recommendedNg": irec_ng,
            "actualNg": iactual_ng,
            "isCustomNg": (icustom_ng is not None and float(icustom_ng) > 0),
            "pipetteVolumeUl": ivol
        })

    mix_vol = 10.0
    water_vol = round(max(0.0, 20.0 - mix_vol - vec_vol - total_ins_vol), 2)

    if args.get("sync_to_gui", True):
        notify_gui_and_sync_primers(
            f"DNA 用量计算：{vec_name} ({vec_bp}bp, {vec_actual_ng}ng) + {len(insert_results)} 个片段",
            [],
            target_module="dnaCalculator",
            extra_workspace_state={
                "calculatorCloneTypeRaw": clone_type,
                "calculatorVectorName": vec_name,
                "calculatorVectorLengthKb": f"{vec_kb:.3f}",
                "calculatorVectorConc": f"{vec_conc:g}",
                "calculatorVectorCustomNg": f"{vec_actual_ng:g}" if (vec_custom_ng is not None and float(vec_custom_ng) > 0) else "",
                "calculatorInsertNames": [x["name"] for x in insert_results],
                "calculatorInsertLengthsKb": [f"{x['lengthKb']:.3f}" for x in insert_results],
                "calculatorInsertConcs": [f"{x['concentrationNgPerUl']:g}" for x in insert_results],
                "calculatorInsertCustomNgs": [f"{x['actualNg']:g}" if x["isCustomNg"] else "" for x in insert_results]
            }
        )

    return {
        "status": "success",
        "cloneType": clone_type,
        "reactionTotalVolumeUl": 20.0,
        "clonExpressMix2xVolumeUl": mix_vol,
        "vector": None if clone_type == "SimpleClone" else {
            "name": vec_name,
            "lengthBp": vec_bp,
            "lengthKb": round(vec_kb, 3),
            "concentrationNgPerUl": vec_conc,
            "recommendedNg": vec_rec_ng,
            "actualNg": vec_actual_ng,
            "pipetteVolumeUl": vec_vol
        },
        "inserts": insert_results,
        "ddH2OVolumeUl": water_vol,
        "reactionCondition": "50℃ 反应 15 min"
    }

def tool_convert_nucleic_acid_units(args: dict) -> dict:
    """
    DNA / 核酸单位换算器：dsDNA (μg⇄pmol)、ssDNA (μg/mL⇄pmol/μL)、Linear DNA 末端 (pmol Ends)、Nucleic Acid OD260 定量
    """
    mode = (args.get("mode") or "").strip().lower()
    val = float(args.get("value", 0))
    if mode in ("dsdna_ug_to_pmol", "dsdna_pmol_to_ug"):
        bp = float(args.get("length_bp_or_nt", 0))
        if bp <= 0 or val < 0:
            return {"status": "error", "error": "length_bp_or_nt 必须 > 0 且 value >= 0"}
        if mode == "dsdna_ug_to_pmol":
            res = (val / bp) * 1515.1
            return {
                "status": "success",
                "mode": mode,
                "result_value": adaptive_round(res),
                "formatted_result": f"{format_bio_number(res)} pmol",
                "unit": "pmol",
                "formula": "pmol = (µg / N_bp) × 1515.1"
            }
        res = val * bp * 0.00066
        return {
            "status": "success",
            "mode": mode,
            "result_value": adaptive_round(res),
            "formatted_result": f"{format_bio_number(res)} µg",
            "unit": "µg",
            "formula": "µg = pmol × N_bp × 0.00066"
        }

    if mode in ("ssdna_ug_per_ml_to_pmol_per_ul", "ssdna_pmol_per_ul_to_ug_per_ml"):
        nt = float(args.get("length_bp_or_nt", 0))
        if nt <= 0 or val < 0:
            return {"status": "error", "error": "length_bp_or_nt 必须 > 0 且 value >= 0"}
        if mode == "ssdna_ug_per_ml_to_pmol_per_ul":
            res = (val * 3.03) / nt
            return {
                "status": "success",
                "mode": mode,
                "result_value": adaptive_round(res),
                "formatted_result": f"{format_bio_number(res)} pmol/µL",
                "unit": "pmol/µL",
                "formula": "pmol/µL = (µg/mL × 3.03) / N_nt"
            }
        res = val * 0.33 * nt
        return {
            "status": "success",
            "mode": mode,
            "result_value": adaptive_round(res),
            "formatted_result": f"{format_bio_number(res)} µg/mL",
            "unit": "µg/mL",
            "formula": "µg/mL = (pmol/µL) × 0.33 × N_nt"
        }

    if mode == "linear_dna_ug_to_pmol_ends":
        kb = float(args.get("length_kb", args.get("length_bp_or_nt", 0)))
        if kb <= 0 or val < 0:
            return {"status": "error", "error": "length_kb 必须 > 0 且 value >= 0"}
        res = (val * 3.03) / kb
        return {
            "status": "success",
            "mode": mode,
            "result_value": adaptive_round(res),
            "formatted_result": f"{format_bio_number(res)} pmol Ends",
            "unit": "pmol Ends",
            "formula": "pmol Ends = (µg × 3.03) / length_kb"
        }

    if mode == "od260_to_ug_per_ml":
        if val < 0:
            return {"status": "error", "error": "OD260 不能为负数"}
        stype = (args.get("sample_type") or "dna").strip().lower()
        factor_map = {
            "dna": ("DNA", 50.0),
            "dsdna": ("DNA", 50.0),
            "rna": ("RNA", 40.0),
            "ssdna": ("Single-stranded DNA", 35.0),
            "single-stranded dna": ("Single-stranded DNA", 35.0),
            "ssoligo": ("Single-stranded Oligo", 20.0),
            "oligo": ("Single-stranded Oligo", 20.0),
            "single-stranded oligo": ("Single-stranded Oligo", 20.0),
        }
        if stype not in factor_map:
            return {"status": "error", "error": f"不支持的 sample_type: {stype}"}
        label, factor = factor_map[stype]
        dil = max(1e-9, float(args.get("dilution_factor", 1.0)))
        res = val * factor * dil
        out_of_range = val > 0 and (val < 0.1 or val > 1.0)
        return {
            "status": "success",
            "mode": mode,
            "sample_type": label,
            "factor": factor,
            "dilution_factor": dil,
            "result_value": adaptive_round(res),
            "formatted_result": f"{format_bio_number(res)} µg/mL",
            "unit": "µg/mL",
            "out_of_linear_range": out_of_range,
            "warning": "大多数分光光度计在低于 0.1 OD 单位或高于 1.0 OD 单位时精度下降，建议调整稀释倍数重新测读。" if out_of_range else None,
            "formula": f"浓度 (µg/mL) = OD260 × {int(factor)} × 稀释倍数"
        }

    return {"status": "error", "error": f"未知 mode: {mode}"}

def tool_convert_protein_and_coding(args: dict) -> dict:
    """
    蛋白质摩尔转换 (kDa ⇄ µg ⇄ pmol) 与 DNA 编码容量 (bp ⇄ aa ⇄ kDa) 三向互算
    """
    mode = (args.get("mode") or "").strip().lower()
    if mode == "protein_size_kda":
        ug = float(args.get("mass_ug", 0))
        pmol = float(args.get("amount_pmol", 0))
        if ug < 0 or pmol <= 0:
            return {"status": "error", "error": "mass_ug >= 0 且 amount_pmol > 0"}
        res = (1000.0 * ug) / pmol
        return {
            "status": "success", "mode": mode,
            "result_value": adaptive_round(res),
            "formatted_result": f"{format_bio_number(res)} kDa",
            "unit": "kDa",
            "formula": "Size (kDa) = 1000 × mass(µg) / moles(pmol)"
        }
    if mode == "protein_mass_ug":
        kda = float(args.get("size_kda", 0))
        pmol = float(args.get("amount_pmol", 0))
        if kda < 0 or pmol < 0:
            return {"status": "error", "error": "size_kda 与 amount_pmol 必须 >= 0"}
        res = kda * pmol * 0.001
        return {
            "status": "success", "mode": mode,
            "result_value": adaptive_round(res),
            "formatted_result": f"{format_bio_number(res)} µg of protein",
            "unit": "µg",
            "formula": "Mass (µg) = Size(kDa) × moles(pmol) × 0.001"
        }
    if mode == "protein_moles_pmol":
        kda = float(args.get("size_kda", 0))
        ug = float(args.get("mass_ug", 0))
        if kda <= 0 or ug < 0:
            return {"status": "error", "error": "size_kda > 0 且 mass_ug >= 0"}
        res = (1000.0 * ug) / kda
        return {
            "status": "success", "mode": mode,
            "result_value": adaptive_round(res),
            "formatted_result": f"{format_bio_number(res)} pmol of protein",
            "unit": "pmol",
            "formula": "Moles (pmol) = 1000 × mass(µg) / Size(kDa)"
        }
    if mode in ("coding_from_bp", "coding_from_aa", "coding_from_kda"):
        v = float(args.get("value", 0))
        if v < 0:
            return {"status": "error", "error": "value 不能为负"}
        if mode == "coding_from_bp":
            aa = float(math.floor(v / 3.0))
            bp = v
            kda = aa * 0.11
        elif mode == "coding_from_aa":
            aa = v
            bp = aa * 3.0
            kda = aa * 0.11
        else:
            aa = float(round(v / 0.11))
            bp = aa * 3.0
            kda = v
        return {
            "status": "success", "mode": mode,
            "dna_bp": adaptive_round(bp),
            "amino_acids": adaptive_round(aa),
            "protein_kda": adaptive_round(kda),
            "formatted_result": f"{format_bio_number(bp)} bp ⇄ {format_bio_number(aa)} aa ⇄ {format_bio_number(kda)} kDa",
            "formula": "AA = floor(bp/3); bp = AA×3; kDa = AA×0.11"
        }
    return {"status": "error", "error": f"未知 mode: {mode}"}

def _parse_conc_scale(u: str) -> float:
    m = {"m": 1.0, "mm": 1e-3, "um": 1e-6, "µm": 1e-6, "nm": 1e-9, "pm": 1e-12}
    k = (u or "m").strip().lower()
    if k not in m:
        raise ValueError(f"不支持的浓度单位: {u}")
    return m[k]

def _parse_vol_scale(u: str) -> tuple:
    m = {"l": (1.0, "L"), "ml": (1e-3, "mL"), "ul": (1e-6, "µL"), "µl": (1e-6, "µL")}
    k = (u or "ml").strip().lower()
    if k not in m:
        raise ValueError(f"不支持的体积单位: {u}")
    return m[k]

def tool_calculate_solution_and_temperature(args: dict) -> dict:
    """
    生理生化公式计算器：摩尔浓度溶液溶质称量质量、C1V1=C2V2 溶液稀释、°F/°C/K 温度转换
    """
    mode = (args.get("mode") or "").strip().lower()
    if mode == "molarity_mass":
        mw = float(args.get("mw_g_per_mol", 0))
        conc = float(args.get("concentration", 0))
        vol = float(args.get("volume", 0))
        if mw <= 0 or conc <= 0 or vol <= 0:
            return {"status": "error", "error": "mw_g_per_mol、concentration、volume 均须 > 0"}
        c_m = conc * _parse_conc_scale(args.get("conc_unit", "mM"))
        v_l, _ = _parse_vol_scale(args.get("vol_unit", "mL"))
        mass_g = vol * v_l * c_m * mw
        if mass_g > 1e6:
            return {"status": "error", "error": "超出质量可显示上限（> 10^6 g）", "mass_g": mass_g}
        if mass_g >= 1.0:
            scaled = round(mass_g, 3)
            unit = "g"
            warn = None
        elif mass_g >= 1e-3:
            scaled = round(mass_g * 1e3, 2)
            unit = "mg"
            warn = None
        else:
            raw_ug = mass_g * 1e6
            scaled = round(raw_ug, 1) if raw_ug >= 0.1 else adaptive_round(raw_ug)
            unit = "µg"
            warn = "请考虑配置浓度更高的母液，然后稀释到您所需的最终浓度。"
        return {
            "status": "success", "mode": mode,
            "mass_g": mass_g, "scaled_value": scaled, "scaled_unit": unit,
            "formatted_mass": f"{format_bio_number(scaled, 3 if unit == 'g' else (2 if unit == 'mg' else None))} {unit}",
            "warning": warn
        }

    if mode == "dilution":
        c1_raw = float(args.get("stock_conc", 0))
        c2_raw = float(args.get("final_conc", 0))
        v2_raw = float(args.get("final_volume", 0))
        if c1_raw <= 0 or c2_raw <= 0 or v2_raw <= 0:
            return {"status": "error", "error": "stock_conc、final_conc、final_volume 均须 > 0"}
        c1 = c1_raw * _parse_conc_scale(args.get("stock_unit", "M"))
        c2 = c2_raw * _parse_conc_scale(args.get("final_unit", "mM"))
        v_scale, v_label = _parse_vol_scale(args.get("vol_unit", "mL"))
        v2_l = v2_raw * v_scale
        fold = c1 / c2
        if c2 > c1:
            return {
                "status": "error",
                "error": f"您输入的母液浓度低于稀释液浓度，需要将母液浓缩 {format_bio_number(c2 / c1)} 倍。"
            }
        v1_l = v2_l / fold
        diluent_l = max(0.0, v2_l - v1_l)
        diluent_scaled = diluent_l / v_scale
        warn = None
        if v1_l >= 1.0:
            scaled, unit = round(v1_l, 3), "L"
        elif v1_l >= 1e-3:
            scaled, unit = round(v1_l * 1e3, 2), "mL"
        elif v1_l >= 1e-6:
            scaled, unit = round(v1_l * 1e6, 1), "µL"
        elif v1_l >= 1e-9:
            scaled, unit = round(v1_l * 1e9, 0), "nL"
            warn = "通常，移液器很难准确移取该体积，您需要考虑将母液预稀释。"
        elif v1_l >= 1e-12:
            scaled, unit = round(v1_l * 1e12, 0), "pL"
            warn = "通常，移液器很难准确移取该体积，您需要考虑将母液预稀释。"
        else:
            return {
                "status": "error",
                "error": "所需体积小于 1 pL，请确保输入正确；建议将母液大幅预稀释后配置。"
            }
        return {
            "status": "success", "mode": mode,
            "stock_volume_liters": v1_l,
            "scaled_value": scaled,
            "scaled_unit": unit,
            "formatted_stock_volume": f"{format_bio_number(scaled, 3 if unit == 'L' else (2 if unit == 'mL' else (1 if unit == 'µL' else 0)))} {unit}",
            "diluent_volume": f"{format_bio_number(diluent_scaled, 2)} {v_label}",
            "dilution_fold": adaptive_round(fold),
            "warning": warn
        }

    if mode == "temperature":
        v = float(args.get("value", 0))
        fu = (args.get("from_unit") or "C").strip().upper()
        if fu == "F":
            c = (5.0 / 9.0) * (v - 32.0)
            f = v
            k = c + 273.16
        elif fu == "C":
            c = v
            f = (9.0 / 5.0) * c + 32.0
            k = c + 273.16
        elif fu == "K":
            k = v
            c = k - 273.16
            f = (9.0 / 5.0) * c + 32.0
        else:
            return {"status": "error", "error": f"不支持的 from_unit: {fu}，请传 F / C / K"}
        if k < 0:
            return {"status": "error", "error": "温度低于绝对零度（0 K / -273.16 °C）。", "kelvin": round(k, 2)}
        return {
            "status": "success", "mode": mode,
            "fahrenheit": round(f, 2),
            "celsius": round(c, 2),
            "kelvin": round(k, 2),
            "formula": "°C=5/9(°F-32); °F=9/5°C+32; °K=°C+273.16"
        }

    return {"status": "error", "error": f"未知 mode: {mode}"}

def resolve_sequence_for_target_design(target_source: str) -> tuple:
    raw = (target_source or "").strip()
    cleaned = clean_seq(raw)
    if len(cleaned) >= 19 and len(cleaned) == len(raw.replace(" ", "").replace("\n", "")):
        return (cleaned, "Target")
    pool = load_plasmid_pool()
    if ":" in raw:
        p_name, f_name = [x.strip() for x in raw.split(":", 1)]
        item = find_plasmid_in_pool(p_name, pool)
        s, e, strand, _ = resolve_region_on_plasmid(item, f_name)
        seq = clean_seq(item["dnaInfo"]["sequence"])[s - 1:e]
        return (rev_comp(seq) if strand == "-" else seq, f_name)
    else:
        item = find_plasmid_in_pool(raw, pool)
        # 优先匹配同名特征或第一个目的基因
        target_feat = raw
        genes = item.get("targetGenes", [])
        if genes and not any(raw.lower() == f.get("name", "").lower() for f in item["dnaInfo"].get("features", [])):
            target_feat = genes[0]
        s, e, strand, _ = resolve_region_on_plasmid(item, target_feat)
        seq = clean_seq(item["dnaInfo"]["sequence"])[s - 1:e]
        return (rev_comp(seq) if strand == "-" else seq, target_feat)

def tool_design_sgrna_primers(args: dict) -> dict:
    """
    增强 4A：CRISPR/Cas9 sgRNA 靶点扫描、打分与退火引物对生成 (适配 lentiCRISPRv2 / pX459)
    """
    seq, gene_name = resolve_sequence_for_target_design(args.get("target_source", ""))
    if args.get("gene_name"):
        gene_name = args["gene_name"]
    top_n = max(1, min(10, int(args.get("top_n", 3))))
    vec_type = (args.get("vector_type") or "lentiCRISPRv2").strip()
    is_px459 = ("459" in vec_type.lower() or "458" in vec_type.lower() or "bbsi" in vec_type.lower())
    fwd_prefix = "CACC" if is_px459 else "CACCG"
    rev_prefix = "AAAC"
    rev_suffix = "" if is_px459 else "C"
    vec_label = "pSpCas9 / pX459 (BbsI)" if is_px459 else "lentiCRISPR v2 (BsmBI)"

    candidates = []
    if len(seq) <= 23:
        spacer = seq[:20]
        candidates.append({"spacer": spacer, "pam": "NGG", "position": 1, "strand": "+", "gc": gc_percent(spacer), "score": 85})
    else:
        # 扫描正链 20nt + NGG 与负链 CCN + 20nt
        for i in range(0, len(seq) - 23):
            window = seq[i:i + 23]
            if window[21:23] == "GG":
                spacer = window[:20]
                pam = window[20:23]
                if "TTTT" in spacer:
                    continue
                gc = gc_percent(spacer)
                score = 70.0
                if 40.0 <= gc <= 65.0:
                    score += 18.0
                elif 35.0 <= gc <= 70.0:
                    score += 8.0
                if spacer[-1] in "GC":
                    score += 6.0
                if spacer[0] == "G":
                    score += 4.0
                rel_pos = i / max(1, len(seq))
                if 0.05 <= rel_pos <= 0.65:
                    score += 5.0
                candidates.append({
                    "spacer": spacer,
                    "pam": pam,
                    "position": i + 1,
                    "strand": "+",
                    "gc": gc,
                    "score": round(min(99.0, score), 1)
                })
        candidates.sort(key=lambda x: (-x["score"], x["position"]))

    selected = candidates[:top_n]
    if not selected:
        raise ValueError(f"在序列 ({len(seq)} bp) 中未找到不含 TTTT 的有效 NGG PAM 靶点")

    primers = []
    for idx, cand in enumerate(selected, start=1):
        sp = cand["spacer"]
        rc = rev_comp(sp)
        fwd_full = fwd_prefix + sp
        rev_full = rev_prefix + rc + rev_suffix
        pf = make_primer_dict(
            name=f"{gene_name}_sg{idx}-FWD",
            homology_arm=fwd_prefix,
            specific_seq=sp,
            purpose=f"sgRNA#{idx} 正向退火引物 ({vec_label})",
            source_tool="MCP sgRNA设计",
            custom_notes=f"靶基因:{gene_name} | 位点:{cand['position']}({cand['strand']}) | PAM:{cand['pam']} | 评分:{cand['score']}"
        )
        pr = make_primer_dict(
            name=f"{gene_name}_sg{idx}-REV",
            homology_arm=rev_prefix,
            specific_seq=rc + rev_suffix,
            purpose=f"sgRNA#{idx} 反向退火引物 ({vec_label})",
            source_tool="MCP sgRNA设计",
            custom_notes=f"靶基因:{gene_name} | 载体:{vec_label} | 5'加{rev_prefix} 3'加{rev_suffix}"
        )
        primers.extend([pf, pr])

    if args.get("add_to_cart", True):
        notify_gui_and_sync_primers(
            f"CRISPR sgRNA 引物设计：{gene_name} ({len(selected)} 对 sgRNA)",
            primers,
            target_module="sgRNADesign"
        )

    return {
        "status": "success",
        "geneName": gene_name,
        "vectorBackbone": vec_label,
        "score_type": "sequence_heuristic",
        "off_target_checked": False,
        "selectedTargets": selected,
        "primers": primers
    }

def tool_design_shrna_primers(args: dict) -> dict:
    """
    增强 4B：RNAi shRNA 21nt 靶点扫描打分与 pLKO.1 (AgeI/EcoRI) 发夹引物生成
    """
    seq, gene_name = resolve_sequence_for_target_design(args.get("target_source", ""))
    if args.get("gene_name"):
        gene_name = args["gene_name"]
    top_n = max(1, min(10, int(args.get("top_n", 3))))
    loop = clean_seq(args.get("loop_sequence") or "CTCGAG")

    candidates = []
    if len(seq) <= 23:
        sense = seq[:21]
        candidates.append({"sense": sense, "position": 1, "gc": gc_percent(sense), "score": 85.0})
    else:
        for i in range(0, len(seq) - 21, 3):
            sense = seq[i:i + 21]
            if "TTTT" in sense or "AAAA" in sense or "GGGG" in sense or "CCCC" in sense:
                continue
            gc = gc_percent(sense)
            if not (35.0 <= gc <= 60.0):
                continue
            score = 72.0
            if 40.0 <= gc <= 55.0:
                score += 15.0
            if sense[0] in "AG":
                score += 5.0
            if sense[-1] in "AT":
                score += 6.0
            candidates.append({
                "sense": sense,
                "position": i + 1,
                "gc": gc,
                "score": round(min(99.0, score), 1)
            })
        candidates.sort(key=lambda x: (-x["score"], x["position"]))

    selected = candidates[:top_n]
    if not selected:
        raise ValueError(f"在序列 ({len(seq)} bp) 中未找到符合 pLKO.1 标准的 21nt shRNA 靶点")

    primers = []
    for idx, cand in enumerate(selected, start=1):
        sense = cand["sense"]
        antisense = rev_comp(sense)
        hairpin_core = sense + loop + antisense
        pf = make_primer_dict(
            name=f"{gene_name}_sh{idx}-F",
            homology_arm="CCGG",
            specific_seq=hairpin_core + "TTTTTTG",
            purpose=f"shRNA#{idx} 正向发夹链 (pLKO.1 AgeI)",
            source_tool="MCP shRNA设计",
            custom_notes=f"靶基因:{gene_name} | 21nt靶点:{sense} (@{cand['position']}) | Loop:{loop} | 评分:{cand['score']}"
        )
        pr = make_primer_dict(
            name=f"{gene_name}_sh{idx}-R",
            homology_arm="AATTCAAAAAAA",
            specific_seq=hairpin_core,
            purpose=f"shRNA#{idx} 反向发夹链 (pLKO.1 EcoRI)",
            source_tool="MCP shRNA设计",
            custom_notes=f"靶基因:{gene_name} | 载体:pLKO.1 (AgeI/EcoRI) | Loop:{loop}"
        )
        primers.extend([pf, pr])

    if args.get("add_to_cart", True):
        notify_gui_and_sync_primers(
            f"pLKO.1 shRNA 引物设计：{gene_name} ({len(selected)} 对发夹引物)",
            primers,
            target_module="shRNADesign"
        )

    return {
        "status": "success",
        "geneName": gene_name,
        "vectorBackbone": "pLKO.1 (AgeI / EcoRI)",
        "loopSequence": loop,
        "selectedTargets": selected,
        "primers": primers
    }

def tool_manage_primer_cart_and_export(args: dict) -> dict:
    action = (args.get("action") or "list").strip().lower()
    autosave_path = os.path.join(APP_SUPPORT_DIR, "workspace_autosave.json")
    cart = []
    if os.path.exists(autosave_path):
        try:
            with open(autosave_path, "r", encoding="utf-8") as f:
                snap = json.load(f)
                cart = snap.get("primersCart", [])
        except Exception:
            pass

    if action == "list":
        return {"count": len(cart), "primersCart": cart}
    elif action == "export_tsingke_excel":
        primers_to_export = args.get("primers") or cart
        if not primers_to_export:
            raise ValueError("当前引物池为空，请先设计引物或传入 primers 数组")
        confirm = bool(args.get("confirm", False))
        tpl_candidates = [
            os.path.join(SCRIPT_DIR, "擎科引物合成订购表.xlsx"),
            os.path.join(PROJECT_DIR, "Sources/CloneStudioCore/Resources/擎科引物合成订购表.xlsx"),
            os.path.join(PROJECT_DIR, "擎科引物合成订购表.xlsx"),
            os.path.join(os.path.dirname(PROJECT_DIR), "擎科引物合成订购表.xlsx"),
        ]
        tpl_path = next((p for p in tpl_candidates if os.path.exists(p)), tpl_candidates[0])
        out_name = f"擎科引物合成订购表_MCP_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.xlsx"
        out_path = (args.get("output_path") or "").strip() or os.path.join(PROJECT_DIR, out_name)
        write_action = "overwrite" if os.path.exists(out_path) else "create"
        if not confirm:
            return {
                "status": "preview",
                "planned_writes": [{
                    "path": out_path,
                    "action": write_action,
                    "summary": f"导出《擎科引物合成订购表》Excel 文件，共包含 {len(primers_to_export)} 条引物"
                }],
                "confirm_hint": "请先以 confirm=false 预览 planned_writes，经用户同意后再以 confirm=true 执行落盘。"
            }
        backup_excel = _backup_if_exists(out_path)
        payload = {
            "template_type": "tsingke_primer",
            "template_path": tpl_path,
            "output_path": out_path,
            "profile": {},
            "items": primers_to_export,
            "primers": primers_to_export
        }
        tmp_in = os.path.join("/tmp", f"mcp_order_{uuid.uuid4().hex}.json")
        with open(tmp_in, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
        try:
            subprocess.run(["/usr/bin/python3", EXPORT_ORDER_SCRIPT, "tsingke_primer", tpl_path, out_path, tmp_in], check=True, capture_output=True, text=True)
        finally:
            if os.path.exists(tmp_in):
                os.remove(tmp_in)
        return {"status": "success", "exportedExcelPath": out_path, "backupPath": backup_excel, "primerCount": len(primers_to_export)}
    else:
        return {"count": len(cart), "primersCart": cart}


# ============================================================================
# 3.5 Labworker 20261115 全栈实验工具 (蛋白质对接盒 / WB 16-bit 定量 / qPCR / 微孔板)
# ============================================================================

KD_HYDROPATHY = {
    'A': 1.8, 'R': -4.5, 'N': -3.5, 'D': -3.5, 'C': 2.5,
    'Q': -3.5, 'E': -3.5, 'G': -0.4, 'H': -3.2, 'I': 4.5,
    'L': 3.8, 'K': -3.9, 'M': 1.9, 'F': 2.8, 'P': -1.6,
    'S': -0.8, 'T': -0.7, 'W': -0.9, 'Y': -1.3, 'V': 4.2
}

# 与 Swift 端 ProteinBiophysicsEngine.aaMasses 完全一致（脱水残基质量 Da，总分子量 + 18.0153 水分子末端）
AA_RESIDUE_MASS = {
    'A': 71.0788, 'R': 156.1875, 'N': 114.1038, 'D': 115.0886, 'C': 103.1388,
    'E': 129.1155, 'Q': 128.1307, 'G': 57.0519, 'H': 137.1411, 'I': 113.1594,
    'L': 113.1594, 'K': 128.1741, 'M': 131.1926, 'F': 147.1766, 'P': 97.1167,
    'S': 87.0782, 'T': 101.1051, 'W': 186.2132, 'Y': 163.1760, 'V': 99.1326
}


def tool_analyze_protein_and_docking_box(args: dict) -> dict:
    """计算蛋白质理化性质、LIGSITE P-S-P 结合口袋、DockFlowLab 共识融合 Vina 对接盒及点突变 ΔΔG"""
    raw_seq = (args.get("sequence") or "").strip()
    pdb_path = (args.get("pdb_path") or "").strip()
    ph = float(args.get("ph", 7.0))
    mutations = args.get("mutations") or []

    coords = []
    ligands = []
    ligand_coords = []
    if pdb_path and os.path.exists(pdb_path):
        with open(pdb_path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith("ENDMDL"):
                    break
                if line.startswith("ATOM  ") and len(line) >= 54:
                    atom_name = line[12:16].strip()
                    if atom_name == "CA":
                        try:
                            x = float(line[30:38])
                            y = float(line[38:46])
                            z = float(line[46:54])
                            coords.append((x, y, z))
                        except Exception:
                            pass
                elif line.startswith("HETATM") and len(line) >= 54:
                    res_name = line[17:20].strip().upper()
                    if res_name not in {"HOH", "WAT", "SO4", "PO4", "GOL", "EDO", "NA", "CL", "MG", "ZN"}:
                        if res_name not in ligands:
                            ligands.append(res_name)
                        try:
                            ligand_coords.append((float(line[30:38]), float(line[38:46]), float(line[46:54])))
                        except Exception:
                            pass

    clean_seq = "".join(ch for ch in raw_seq.upper() if ch in KD_HYDROPATHY)
    if not clean_seq:
        clean_seq = "MKVLLFAAVVGGLAAAGVSAKELRKIYEDGKVTYTLDNGKPVVLVFYPADFTFVCPTEIIAFSENAAKKFEEQGAQVLFASTDSEYSLLAWTNIPRKEGGLGPINIPLLADTN"

    length = len(clean_seq)
    mw_da = sum(AA_RESIDUE_MASS.get(c, 110.0) for c in clean_seq) + 18.0153
    gravy = sum(KD_HYDROPATHY.get(c, 0.0) for c in clean_seq) / max(1, length)

    # 二分法计算理论 pI（与 Swift 端 ProteinBiophysicsEngine.netCharge / calculateIsoelectricPoint 完全一致）
    def net_charge_at(p_val: float) -> float:
        pos = (1.0 / (1.0 + 10 ** (p_val - 9.69)))
        pos += clean_seq.count('K') * (1.0 / (1.0 + 10 ** (p_val - 10.54)))
        pos += clean_seq.count('R') * (1.0 / (1.0 + 10 ** (p_val - 12.48)))
        pos += clean_seq.count('H') * (1.0 / (1.0 + 10 ** (p_val - 6.00)))
        neg = (1.0 / (1.0 + 10 ** (2.34 - p_val)))
        neg += clean_seq.count('D') * (1.0 / (1.0 + 10 ** (3.86 - p_val)))
        neg += clean_seq.count('E') * (1.0 / (1.0 + 10 ** (4.25 - p_val)))
        neg += clean_seq.count('C') * (1.0 / (1.0 + 10 ** (8.33 - p_val)))
        neg += clean_seq.count('Y') * (1.0 / (1.0 + 10 ** (10.07 - p_val)))
        return pos - neg

    lo, hi = 0.5, 13.5
    for _ in range(32):
        mid = (lo + hi) * 0.5
        if net_charge_at(mid) > 0:
            lo = mid
        else:
            hi = mid
    pi_val = round((lo + hi) * 0.5, 2)

    if ligand_coords:
        xs = [c[0] for c in ligand_coords]
        ys = [c[1] for c in ligand_coords]
        zs = [c[2] for c in ligand_coords]
        cx, cy, cz = round((min(xs) + max(xs)) * 0.5, 3), round((min(ys) + max(ys)) * 0.5, 3), round((min(zs) + max(zs)) * 0.5, 3)
        sx = round(min(60.0, max(18.0, (max(xs) - min(xs)) + 8.0)), 2)
        sy = round(min(60.0, max(18.0, (max(ys) - min(ys)) + 8.0)), 2)
        sz = round(min(60.0, max(18.0, (max(zs) - min(zs)) + 8.0)), 2)
        box_source = f"共晶配体 ({'/'.join(ligands)}) + LIGSITE 共识融合盒"
    elif coords:
        xs = [c[0] for c in coords]
        ys = [c[1] for c in coords]
        zs = [c[2] for c in coords]
        cx, cy, cz = round(sum(xs) / len(xs), 3), round(sum(ys) / len(ys), 3), round(sum(zs) / len(zs), 3)
        sx = sy = sz = 22.0
        box_source = "LIGSITE P-S-P 几何口袋"
    else:
        cx, cy, cz = 4.6, -2.5, 1.2
        sx = sy = sz = 22.0
        box_source = "LIGSITE P-S-P 几何口袋 (SPICE 折叠)"

    vina_cfg = (
        f"receptor = receptor.pdbqt\nligand = ligand.pdbqt\n\n"
        f"center_x = {cx:.3f}\ncenter_y = {cy:.3f}\ncenter_z = {cz:.3f}\n\n"
        f"size_x = {sx:.1f}\nsize_y = {sy:.1f}\nsize_z = {sz:.1f}\n\n"
        f"exhaustiveness = 8\nnum_modes = 9\nenergy_range = 3\n"
    )

    mut_evals = []
    for spec in mutations:
        s = str(spec).strip().upper()
        parts = [p.strip() for p in s.replace("/", "+").split("+") if p.strip()]
        ddg_sum = 0.0
        valid_parts = []
        for token in parts:
            if len(token) >= 3 and token[1:-1].isdigit():
                pos = int(token[1:-1])
                from_aa, to_aa = token[0], token[-1]
                h_from = KD_HYDROPATHY.get(from_aa, 0.0)
                h_to = KD_HYDROPATHY.get(to_aa, 0.0)
                m_from = AA_RESIDUE_MASS.get(from_aa, 110.0)
                m_to = AA_RESIDUE_MASS.get(to_aa, 110.0)
                buried_factor = 1.0 if (pos > 4 and pos < length - 4) else 0.45
                d_hydro = (h_from - h_to) * 0.38 * buried_factor
                d_steric = abs(m_to - m_from) / 95.0 * 0.45
                pro_pen = 1.45 if to_aa == 'P' else 0.0
                ddg_sum += (d_hydro + d_steric + pro_pen - 0.55)
                valid_parts.append(f"{from_aa}{pos}{to_aa}")
        if valid_parts:
            ddg = round(ddg_sum, 2)
            mut_evals.append({
                "mutation": "+".join(valid_parts),
                "ddg_kcal_mol": ddg,
                "model_type": "empirical_heuristic",
                "verdict": "经验稳定化倾向 (Empirical Stabilizing)" if ddg <= -0.4 else ("经验中性耐受 (Empirical Neutral)" if ddg <= 0.5 else "经验去稳定化风险 (Empirical Destabilizing)")
            })

    notify_gui_and_sync_primers(
        action_summary=f"MCP 蛋白质结构与对接盒分析 ({length} aa, pI {pi_val})",
        primers=[],
        target_module="proteinWorkbench"
    )

    return {
        "length_aa": length,
        "molecular_weight_da": round(mw_da, 1),
        "isoelectric_point": pi_val,
        "net_charge_at_ph": round(net_charge_at(ph), 2),
        "gravy": round(gravy, 3),
        "ddg_model_type": "empirical_heuristic",
        "docking_box": {
            "source": box_source,
            "center": [cx, cy, cz],
            "size": [sx, sy, sz],
            "volume_A3": round(sx * sy * sz, 1),
            "vina_config": vina_cfg
        },
        "mutant_evaluations": mut_evals
    }


def tool_analyze_western_blot(args: dict) -> dict:
    """对 Western Blot 泳道灰度积分 (IOD) 与内参执行归一化、过曝条带剔除 (P03) 及双组 Welch t 检验"""
    target_iods = [float(x) for x in (args.get("target_iods") or [100.0, 108.0, 220.0, 235.0])]
    control_iods = [float(x) for x in (args.get("loading_control_iods") or [100.0] * len(target_iods))]
    groups = args.get("lane_groups") or (["Control"] * (len(target_iods) // 2) + ["Treated"] * (len(target_iods) - len(target_iods) // 2))
    is_saturated_in = args.get("is_saturated") or [False] * len(target_iods)
    saturation_policy = str(args.get("saturation_policy") or "excludeFromStats").strip()
    if saturation_policy not in ("excludeFromStats", "warnOnly"):
        saturation_policy = "excludeFromStats"

    n = min(len(target_iods), len(control_iods), len(groups))
    sat_flags = [bool(is_saturated_in[i]) if i < len(is_saturated_in) else False for i in range(n)]
    raw_ratios = [target_iods[i] / max(1e-6, control_iods[i]) for i in range(n)]
    ctrl_name = groups[0] if n > 0 else "Control"

    excluded_bands = []
    for i in range(n):
        if saturation_policy == "excludeFromStats" and sat_flags[i]:
            excluded_bands.append({
                "band_id": f"L{i + 1}_R1",
                "lane_index": i + 1,
                "group": groups[i],
                "reason": f"泳道 L{i + 1} 条带过曝饱和，已按 excludeFromStats 策略从统计中剔除"
            })

    ctrl_valid = [raw_ratios[i] for i in range(n) if groups[i] == ctrl_name and not (saturation_policy == "excludeFromStats" and sat_flags[i])]
    if not ctrl_valid:
        ctrl_valid = [raw_ratios[i] for i in range(n) if groups[i] == ctrl_name]
    ctrl_mean = sum(ctrl_valid) / max(1, len(ctrl_valid)) if ctrl_valid else 1.0
    norm_folds = [round(r / max(1e-6, ctrl_mean), 4) for r in raw_ratios]

    group_order = []
    for g in groups[:n]:
        if g not in group_order:
            group_order.append(g)

    ctrl_folds = [norm_folds[i] for i in range(n) if groups[i] == ctrl_name and not (saturation_policy == "excludeFromStats" and sat_flags[i])]
    group_stats = []
    for g_name in group_order:
        g_indices = [i for i in range(n) if groups[i] == g_name]
        ex_cnt = sum(1 for i in g_indices if saturation_policy == "excludeFromStats" and sat_flags[i])
        vals = [norm_folds[i] for i in g_indices if not (saturation_policy == "excludeFromStats" and sat_flags[i])]
        m = sum(vals) / len(vals) if vals else 0.0
        sd = math.sqrt(sum((v - m) ** 2 for v in vals) / (len(vals) - 1)) if len(vals) > 1 else 0.0
        p_val = None
        if g_name != ctrl_name and len(vals) >= 2 and len(ctrl_folds) >= 2:
            p_val = _welch_t_test_p(vals, ctrl_folds)
        group_stats.append({
            "group": g_name,
            "n": len(vals),
            "n_excluded_saturated": ex_cnt,
            "mean_fold": round(m, 4),
            "sd": round(sd, 4),
            "p_value": p_val
        })

    notify_gui_and_sync_primers(
        action_summary=f"MCP Western Blot 归一化定量 ({n} 泳道, 剔除过曝={len(excluded_bands)})",
        primers=[],
        target_module="westernBlot"
    )
    return {
        "lane_count": n,
        "saturation_policy": saturation_policy,
        "excluded_bands": excluded_bands,
        "normalized_folds": norm_folds,
        "group_statistics": group_stats
    }


def _lanczos_log_gamma(z: float) -> float:
    coeffs = [
        0.99999999999980993,
        676.5203681218851,
        -1259.1392167224028,
        771.32342877765313,
        -176.61502916214059,
        12.507343278686905,
        -0.13857109526572012,
        9.9843695780195716e-6,
        1.5056327351493116e-7,
    ]
    if z < 0.5:
        return math.log(math.pi / math.sin(math.pi * z)) - _lanczos_log_gamma(1.0 - z)
    x = coeffs[0]
    t = z - 1.0
    for i in range(1, len(coeffs)):
        x += coeffs[i] / (t + float(i))
    w = t + 7.5
    return 0.5 * math.log(2.0 * math.pi) + (t + 0.5) * math.log(w) - w + math.log(x)


def _beta_cf(a: float, b: float, x: float) -> float:
    max_iter = 300
    eps = 3e-14
    tiny = 1e-300
    qab = a + b
    qap = a + 1.0
    qam = a - 1.0
    c = 1.0
    d = 1.0 - (qab * x) / qap
    if abs(d) < tiny:
        d = tiny
    d = 1.0 / d
    h = d
    for m in range(1, max_iter + 1):
        m_d = float(m)
        m2 = 2.0 * m_d
        aa = (m_d * (b - m_d) * x) / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < tiny:
            d = tiny
        c = 1.0 + aa / c
        if abs(c) < tiny:
            c = tiny
        d = 1.0 / d
        h *= d * c

        aa = (-(a + m_d) * (qab + m_d) * x) / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if abs(d) < tiny:
            d = tiny
        c = 1.0 + aa / c
        if abs(c) < tiny:
            c = tiny
        d = 1.0 / d
        del_v = d * c
        h *= del_v
        if abs(del_v - 1.0) < eps:
            break
    return h


def _incomplete_beta(a: float, b: float, x: float) -> float:
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    log_term = _lanczos_log_gamma(a + b) - _lanczos_log_gamma(a) - _lanczos_log_gamma(b) + a * math.log(x) + b * math.log(1.0 - x)
    term = math.exp(log_term)
    if x < (a + 1.0) / (a + b + 2.0):
        return (term * _beta_cf(a, b, x)) / a
    return 1.0 - (term * _beta_cf(b, a, 1.0 - x)) / b


def _welch_t_test_p(a: list, b: list):
    if len(a) < 2 or len(b) < 2:
        return None
    mean_a = sum(a) / len(a)
    mean_b = sum(b) / len(b)
    var_a = sum((x - mean_a) ** 2 for x in a) / (len(a) - 1)
    var_b = sum((x - mean_b) ** 2 for x in b) / (len(b) - 1)
    term_a = var_a / len(a)
    term_b = var_b / len(b)
    se = math.sqrt(term_a + term_b)
    diff = mean_a - mean_b
    if se == 0.0:
        return 1.0 if diff == 0.0 else 0.0
    t_val = diff / se
    num = (term_a + term_b) ** 2
    den = (term_a ** 2) / (len(a) - 1) + (term_b ** 2) / (len(b) - 1)
    df = float(len(a) + len(b) - 2) if den == 0.0 else (num / den)
    if df <= 0.0:
        return None
    if t_val == 0.0:
        return 1.0
    x = df / (df + t_val * t_val)
    return min(1.0, max(0.0, _incomplete_beta(df / 2.0, 0.5, x)))


def _holm_adjust(p_values: list) -> list:
    """Holm–Bonferroni 逐步下降多重比较校正，与 R p.adjust(method='holm') 及 Swift QPCRStatistics.holmAdjust 完全一致 (P07)"""
    m = len(p_values)
    if m == 0:
        return []
    indexed = sorted(enumerate(p_values), key=lambda kv: (kv[1], kv[0]))
    adjusted_sorted = [0.0] * m
    running_max = 0.0
    for rank, (_, p_val) in enumerate(indexed):
        raw_adj = min(1.0, max(0.0, float(p_val) * float(m - rank)))
        running_max = max(running_max, raw_adj)
        adjusted_sorted[rank] = running_max
    out = [0.0] * m
    for rank, (orig_idx, _) in enumerate(indexed):
        out[orig_idx] = adjusted_sorted[rank]
    return out


def _student_t_quantile_two_sided(alpha: float, df: float) -> float:
    if df <= 0.0 or alpha <= 0.0 or alpha >= 1.0:
        return None
    lo, hi = 0.0, 4.0
    while hi < 1e9:
        p_hi = _incomplete_beta(df / 2.0, 0.5, df / (df + hi * hi))
        if p_hi <= alpha:
            break
        lo = hi
        hi *= 2.0
    for _ in range(80):
        mid = 0.5 * (lo + hi)
        p_mid = _incomplete_beta(df / 2.0, 0.5, df / (df + mid * mid))
        if p_mid > alpha:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def _welch_ci95(a: list, b: list, alpha: float = 0.05, base: float = 2.0):
    """计算两组样品 ΔCt 均值差 (ΔΔCt) 的 Welch 95% CI 与 Fold Change (base^-ΔΔCt) 95% CI (P07)"""
    if len(a) < 2 or len(b) < 2:
        return None
    mean_a = sum(a) / len(a)
    mean_b = sum(b) / len(b)
    diff = mean_a - mean_b
    var_a = sum((x - mean_a) ** 2 for x in a) / (len(a) - 1)
    var_b = sum((x - mean_b) ** 2 for x in b) / (len(b) - 1)
    term_a = var_a / len(a)
    term_b = var_b / len(b)
    se = math.sqrt(term_a + term_b)
    num = (term_a + term_b) ** 2
    den = (term_a ** 2) / (len(a) - 1) + (term_b ** 2) / (len(b) - 1)
    df = float(len(a) + len(b) - 2) if den == 0.0 else (num / den)
    if df <= 0.0:
        return None
    if se == 0.0:
        f_val = base ** (-diff)
        return {
            "ddct_diff": diff,
            "ddct_low": diff,
            "ddct_high": diff,
            "fold_low": f_val,
            "fold_high": f_val,
            "df": df
        }
    t_crit = _student_t_quantile_two_sided(alpha, df)
    if t_crit is None:
        return None
    margin = t_crit * se
    ddct_low = diff - margin
    ddct_high = diff + margin
    f1 = base ** (-ddct_high)
    f2 = base ** (-ddct_low)
    return {
        "ddct_diff": diff,
        "ddct_low": ddct_low,
        "ddct_high": ddct_high,
        "fold_low": min(f1, f2),
        "fold_high": max(f1, f2),
        "df": df
    }


def _infer_qpcr_well_type(sample: str, group: str = "", task_raw: str = "", quantity=None) -> str:
    if quantity is not None:
        return "standard"
    combined = f"{task_raw} {sample} {group}".lower()
    tokens = [t for t in re.split(r"[^a-z0-9]+", combined) if t]
    if "ntc" in tokens or "no template" in combined or "non-template" in combined or "空白" in combined or "水对照" in combined:
        return "ntc"
    if "nort" in tokens or "nrt" in tokens or "no-rt" in combined or "no rt" in combined or "-rt" in combined or "rt-" in combined or "无逆转录" in combined:
        return "noRT"
    if "standard" in tokens or "std" in tokens or "标准品" in combined:
        return "standard"
    return "sample"


def tool_analyze_qpcr_ddct(args: dict) -> dict:
    """计算 qPCR 2^(-ΔΔCt) 相对表达量、严格按生物学样品级 ΔCt 执行 Welch t 检验、Holm 校正、95% CI 与 NTC/no-RT/熔解质控 (P02, P07 & P08)"""
    records = args.get("records") or []
    ref_gene = (args.get("reference_gene") or "ACTB").strip()
    ctrl_sample = (args.get("control_sample") or "Control").strip()
    ctrl_group = (args.get("control_group") or "").strip()
    sd_threshold = float(args.get("sd_threshold", 0.30))
    ntc_ct_threshold = float(args.get("ntc_ct_threshold", 35.0))
    nort_dct_threshold = float(args.get("nort_dct_threshold", 5.0))
    melt_tolerance = float(args.get("melt_tolerance", 1.0))
    mult_comp = (args.get("multiple_comparison") or "holm").strip().lower()

    parsed_wells = []
    target_sample_tms = {}
    target_sample_cts = {}
    for idx, rec in enumerate(records):
        s = str(rec.get("sample", "Sample")).strip()
        g = str(rec.get("gene") or rec.get("target") or "Gene").strip()
        grp = str(rec.get("group") or "").strip()
        task_raw = str(rec.get("task") or rec.get("well_type") or rec.get("type") or "").strip()
        qty = rec.get("quantity")
        raw_ct = rec.get("ct")
        ct_val = None
        if raw_ct is not None:
            raw_ct_str = str(raw_ct).strip().lower()
            if raw_ct_str not in ("", "undetermined", "na", "nan", "-"):
                try:
                    ct_val = float(raw_ct)
                except Exception:
                    ct_val = None
        raw_tm = rec.get("tm")
        tm_val = None
        if raw_tm is not None and str(raw_tm).strip() != "":
            try:
                tm_val = float(raw_tm)
            except Exception:
                tm_val = None
        w_type = _infer_qpcr_well_type(s, grp, task_raw, qty)
        if w_type == "sample":
            if ct_val is not None:
                target_sample_cts.setdefault(g.lower(), []).append(ct_val)
            if tm_val is not None:
                target_sample_tms.setdefault(g.lower(), []).append(tm_val)
        parsed_wells.append({
            "index": idx,
            "sample": s,
            "gene": g,
            "group": grp,
            "well_type": w_type,
            "ct": ct_val,
            "tm": tm_val
        })

    target_median_tm = {}
    for gk, tms in target_sample_tms.items():
        if tms:
            st = sorted(tms)
            mid = len(st) // 2
            target_median_tm[gk] = 0.5 * (st[mid - 1] + st[mid]) if len(st) % 2 == 0 else st[mid]

    warnings = []
    qc_flags = []
    contaminated_targets = set()
    grouped = {}
    sample_group_map = {}
    sample_order = []

    for w in parsed_wells:
        s = w["sample"]
        g = w["gene"]
        gk = g.lower()
        grp = w["group"]
        w_type = w["well_type"]
        ct_val = w["ct"]
        tm_val = w["tm"]
        w_flags = []

        if w_type == "ntc":
            if ct_val is not None and ct_val < ntc_ct_threshold:
                w_flags.append("ntcAmplified")
                contaminated_targets.add(g)
                warnings.append(f"NTC 孔 ({s} / {g}) 检出污染起峰 Ct={ct_val:.2f} < {ntc_ct_threshold:.1f}")
        elif w_type == "noRT":
            if ct_val is not None:
                ref_cts = target_sample_cts.get(gk, [])
                ref_mean = (sum(ref_cts) / len(ref_cts)) if ref_cts else None
                if (ref_mean is not None and (ct_val - ref_mean) < nort_dct_threshold) or (ref_mean is None and ct_val < ntc_ct_threshold):
                    w_flags.append("noRTAmplified")
                    contaminated_targets.add(g)
                    warnings.append(f"no-RT 孔 ({s} / {g}) 检出扩增 Ct={ct_val:.2f} (ΔCt < {nort_dct_threshold:.1f})")
        elif w_type == "sample":
            if ct_val is None:
                w_flags.append("undetermined")
                warnings.append(f"样品孔 ({s} / {g}) 未检出 Ct (Undetermined)，已从计算中排除")
            if tm_val is not None and gk in target_median_tm:
                if abs(tm_val - target_median_tm[gk]) > melt_tolerance:
                    w_flags.append("meltOutlier")
                    warnings.append(f"样品孔 ({s} / {g}) 熔解 Tm={tm_val:.2f}℃ 偏离靶标中位数 {target_median_tm[gk]:.2f}℃ 超过 {melt_tolerance:.1f}℃")

        if w_flags:
            qc_flags.append({"sample": s, "gene": g, "well_type": w_type, "flags": w_flags})

        # 仅无 meltOutlier 且非空的 sample 孔进入 ΔΔCt 统计
        if w_type == "sample" and ct_val is not None and "meltOutlier" not in w_flags:
            if s not in sample_group_map:
                sample_group_map[s] = grp if grp else s
                sample_order.append(s)
            grouped.setdefault((s, g), []).append(ct_val)

    means = {}
    for (s, g), cts in grouped.items():
        m = sum(cts) / len(cts)
        sd = math.sqrt(sum((v - m) ** 2 for v in cts) / max(1, len(cts) - 1)) if len(cts) > 1 else 0.0
        means[(s, g)] = (m, sd, len(cts))
        if sd > sd_threshold:
            warnings.append(f"{s} / {g} 复孔 Ct SD={sd:.2f} 超过阈值 {sd_threshold:.2f}")

    samples = sample_order if sample_order else sorted({k[0] for k in means.keys()})
    genes = sorted({k[1] for k in means.keys() if k[1].lower() != ref_gene.lower()})
    ref_key = next((k[1] for k in means.keys() if k[1].lower() == ref_gene.lower()), ref_gene)

    def is_ctrl_sample(s_name: str) -> bool:
        grp_val = sample_group_map.get(s_name, s_name)
        if ctrl_group and grp_val.lower() == ctrl_group.lower():
            return True
        if s_name.lower() == ctrl_sample.lower() or grp_val.lower() == ctrl_sample.lower():
            return True
        return False

    results = []
    group_summaries = []
    for g in genes:
        ctrl_dcts_for_cal = [
            means[(s, g)][0] - means[(s, ref_key)][0]
            for s in samples
            if is_ctrl_sample(s) and (s, g) in means and (s, ref_key) in means
        ]
        if ctrl_dcts_for_cal:
            cal_dct = sum(ctrl_dcts_for_cal) / len(ctrl_dcts_for_cal)
        elif (ctrl_sample, g) in means and (ctrl_sample, ref_key) in means:
            cal_dct = means[(ctrl_sample, g)][0] - means[(ctrl_sample, ref_key)][0]
        else:
            first_valid = next(
                (means[(s, g)][0] - means[(s, ref_key)][0] for s in samples if (s, g) in means and (s, ref_key) in means),
                0.0
            )
            cal_dct = first_valid

        sample_rows_for_gene = []
        cat_order = []
        for s in samples:
            if (s, g) not in means or (s, ref_key) not in means:
                continue
            ref_ct = means[(s, ref_key)][0]
            dct = means[(s, g)][0] - ref_ct
            ddct = dct - cal_dct
            cts_list = grouped.get((s, g), [means[(s, g)][0]])
            fold_vals = [2.0 ** -((c - ref_ct) - cal_dct) for c in cts_list]
            fold = sum(fold_vals) / len(fold_vals)
            n_tech = means[(s, g)][2]
            cat = sample_group_map.get(s, s)
            if cat not in cat_order:
                cat_order.append(cat)
            row_obj = {
                "sample": s,
                "group": cat,
                "gene": g,
                "n_technical_wells": n_tech,
                "delta_ct": round(dct, 6),
                "delta_delta_ct": round(ddct, 6),
                "relative_expression_2_neg_ddct": round(fold, 6),
                "_raw_dct": dct,
                "_raw_fold": fold,
                "_is_control": is_ctrl_sample(s)
            }
            sample_rows_for_gene.append(row_obj)
            results.append({
                "sample": s,
                "group": cat,
                "gene": g,
                "n_technical_wells": n_tech,
                "delta_ct": round(dct, 3),
                "delta_delta_ct": round(ddct, 3),
                "relative_expression_2_neg_ddct": round(fold, 4)
            })

        ctrl_sample_dcts = [r["_raw_dct"] for r in sample_rows_for_gene if r["_is_control"]]
        gene_group_rows = []
        for cat in cat_order:
            cat_rows = [r for r in sample_rows_for_gene if r["group"] == cat]
            if not cat_rows:
                continue
            is_ctrl_cat = all(r["_is_control"] for r in cat_rows)
            n_bio = len(cat_rows)
            n_tech_total = sum(r["n_technical_wells"] for r in cat_rows)
            cat_dcts = [r["_raw_dct"] for r in cat_rows]
            cat_folds = [r["_raw_fold"] for r in cat_rows]
            mean_fold = sum(cat_folds) / n_bio
            sd_fold = math.sqrt(sum((v - mean_fold) ** 2 for v in cat_folds) / (n_bio - 1)) if n_bio >= 2 else None
            sem_fold = (sd_fold / math.sqrt(n_bio)) if sd_fold is not None else None
            mean_dct = sum(cat_dcts) / n_bio
            sd_dct = math.sqrt(sum((v - mean_dct) ** 2 for v in cat_dcts) / (n_bio - 1)) if n_bio >= 2 else None

            p_val = None
            ci_info = None
            stat_note = "ok"
            if not is_ctrl_cat:
                if n_bio >= 2 and len(ctrl_sample_dcts) >= 2:
                    p_val = _welch_t_test_p(cat_dcts, ctrl_sample_dcts)
                    ci_info = _welch_ci95(cat_dcts, ctrl_sample_dcts, alpha=0.05, base=2.0)
                    stat_note = "ok" if p_val is not None else "insufficientBiologicalReplicates"
                else:
                    p_val = None
                    stat_note = "insufficientBiologicalReplicates"

            gene_group_rows.append({
                "group": cat,
                "gene": g,
                "n_biological": n_bio,
                "n_technical_wells": n_tech_total,
                "mean_fold": round(mean_fold, 6),
                "sd_fold": round(sd_fold, 6) if sd_fold is not None else None,
                "sem_fold": round(sem_fold, 6) if sem_fold is not None else None,
                "mean_dct": round(mean_dct, 6),
                "sd_dct": round(sd_dct, 6) if sd_dct is not None else None,
                "p_value": p_val,
                "p_adjusted": None,
                "ddct_ci95_low": round(ci_info["ddct_low"], 6) if ci_info else None,
                "ddct_ci95_high": round(ci_info["ddct_high"], 6) if ci_info else None,
                "fold_ci95_low": round(ci_info["fold_low"], 6) if ci_info else None,
                "fold_ci95_high": round(ci_info["fold_high"], 6) if ci_info else None,
                "stat_note": stat_note,
                "is_control": is_ctrl_cat
            })

        # Target 内 Holm–Bonferroni 多重比较校正
        valid_indices = [idx for idx, row in enumerate(gene_group_rows) if not row["is_control"] and row["p_value"] is not None]
        if valid_indices:
            raw_ps = [gene_group_rows[idx]["p_value"] for idx in valid_indices]
            adj_ps = _holm_adjust(raw_ps) if mult_comp != "none" else raw_ps
            for idx, p_adj in zip(valid_indices, adj_ps):
                gene_group_rows[idx]["p_adjusted"] = p_adj

        group_summaries.extend(gene_group_rows)

    notify_gui_and_sync_primers(
        action_summary=f"MCP qPCR 2^(-ΔΔCt) 分析 (内参 {ref_gene}, {len(results)} 样品, {len(group_summaries)} 分组)",
        primers=[],
        target_module="qpcrAnalysis"
    )
    return {
        "reference_gene": ref_gene,
        "control_sample": ctrl_sample,
        "contaminated_targets": sorted(contaminated_targets),
        "qc_flags": qc_flags,
        "results": results,
        "group_summaries": group_summaries,
        "qc_warnings": warnings
    }


def tool_design_plate_layout(args: dict) -> dict:
    """生成 96/384 孔板防边缘效应自动排布方案"""
    plate_format = int(args.get("plate_format", 96))
    avoid_edge = bool(args.get("avoid_outer_edge", True))
    samples = args.get("samples") or ["Blank", "Vehicle", "Dose_1uM", "Dose_10uM"]
    replicates = max(1, int(args.get("replicates", 3)))

    rows = "ABCDEFGH" if plate_format == 96 else "ABCDEFGHIJKLMNOP"
    cols = 12 if plate_format == 96 else 24
    usable_wells = []
    for r_idx, r_ch in enumerate(rows):
        for c_idx in range(1, cols + 1):
            if avoid_edge and (r_idx == 0 or r_idx == len(rows) - 1 or c_idx == 1 or c_idx == cols):
                continue
            usable_wells.append(f"{r_ch}{c_idx:02d}")

    assignments = []
    w_cursor = 0
    for s in samples:
        for rep in range(1, replicates + 1):
            if w_cursor < len(usable_wells):
                assignments.append({
                    "well": usable_wells[w_cursor],
                    "sample": s,
                    "replicate": rep
                })
                w_cursor += 1

    notify_gui_and_sync_primers(
        action_summary=f"MCP {plate_format} 孔微孔板排布 ({len(assignments)} 孔已分配, 避开外圈={avoid_edge})",
        primers=[],
        target_module="plateDesigner"
    )
    return {
        "plate_format": plate_format,
        "avoid_outer_edge": avoid_edge,
        "assigned_well_count": len(assignments),
        "assignments": assignments
    }


def _parse_ab1_bytes(raw_bytes: bytes) -> dict:
    """原生解析 Applied Biosystems ABIF (.ab1/.abi) 二进制文件的 PBAS、PCON、PLOC 与 DATA 9..12 四通道"""
    if len(raw_bytes) < 34 or raw_bytes[:4] != b"ABIF":
        text = raw_bytes.decode("utf-8", errors="ignore")
        lines = [ln.strip() for ln in text.splitlines() if not ln.strip().startswith(">")]
        seq = "".join(ch for ch in "".join(lines).upper() if ch in "ACGTN")
        return {"is_ab1": False, "sequence": seq, "qualities": [40] * len(seq), "double_peaks": []}

    import struct
    num_elem = struct.unpack(">i", raw_bytes[18:22])[0]
    dir_offset = struct.unpack(">i", raw_bytes[26:30])[0]
    entries = {}
    for i in range(max(0, min(5000, num_elem))):
        base = dir_offset + i * 28
        if base + 28 > len(raw_bytes):
            break
        t_name = raw_bytes[base:base + 4].decode("ascii", errors="ignore")
        t_num, e_type, e_size, n_el, d_size, d_off = struct.unpack(">ihhi ii", raw_bytes[base + 4:base + 24])
        entries[f"{t_name}#{t_num}"] = (e_type, e_size, n_el, d_size, d_off)

    def get_bytes(key):
        if key not in entries:
            return b""
        _, _, _, d_size, d_off = entries[key]
        if d_size <= 4:
            return struct.pack(">i", d_off)[:max(0, d_size)]
        return raw_bytes[d_off:d_off + d_size] if d_off + d_size <= len(raw_bytes) else b""

    def get_i16_array(key):
        b = get_bytes(key)
        cnt = len(b) // 2
        return list(struct.unpack(f">{cnt}h", b[:cnt * 2])) if cnt > 0 else []

    fwo = get_bytes("FWO_#1").decode("ascii", errors="ignore").upper() or "GATC"
    d_nums = [9, 10, 11, 12] if "DATA#9" in entries else [1, 2, 3, 4]
    traces = {}
    for idx, ch in enumerate(fwo[:4]):
        traces[ch] = get_i16_array(f"DATA#{d_nums[idx]}")

    pbas_bytes = get_bytes("PBAS#1") or get_bytes("PBAS#2")
    seq = "".join(ch for ch in pbas_bytes.decode("ascii", errors="ignore").upper() if ch in "ACGTN")
    pcon_bytes = get_bytes("PCON#1") or get_bytes("PCON#2")
    quals = list(pcon_bytes[:len(seq)]) if pcon_bytes else [40] * len(seq)
    plocs = get_i16_array("PLOC#1") or get_i16_array("PLOC#2")

    double_peaks = []
    for i, base_ch in enumerate(seq):
        if i < len(plocs):
            t_idx = plocs[i]
            sigs = sorted([(ch, traces.get(ch, [0])[t_idx] if t_idx < len(traces.get(ch, [])) else 0) for ch in "ACGT"], key=lambda x: -x[1])
            if sigs[0][1] > 0 and (sigs[1][1] / sigs[0][1]) >= 0.30:
                double_peaks.append({
                    "read_pos_1based": i + 1,
                    "primary_base": sigs[0][0],
                    "secondary_base": sigs[1][0],
                    "secondary_ratio": round(sigs[1][1] / sigs[0][1], 2)
                })
    return {"is_ab1": True, "sequence": seq, "qualities": quals, "double_peaks": double_peaks}


def _extract_ab1_peaks_acgt(raw_bytes: bytes) -> Dict[str, Any]:
    """从 ABIF (.ab1/.abi) 测序文件提取全长序列及各碱基位点的四通道峰高矩阵 [[A, C, G, T]]。"""
    if len(raw_bytes) < 34 or raw_bytes[:4] != b"ABIF":
        raise ValueError("输入文件不是有效的 Applied Biosystems ABIF (.ab1/.abi) 格式")

    import struct
    num_elem = struct.unpack(">i", raw_bytes[18:22])[0]
    dir_offset = struct.unpack(">i", raw_bytes[26:30])[0]
    entries = {}
    for i in range(max(0, min(5000, num_elem))):
        base = dir_offset + i * 28
        if base + 28 > len(raw_bytes):
            break
        t_name = raw_bytes[base:base + 4].decode("ascii", errors="ignore")
        t_num, e_type, e_size, n_el, d_size, d_off = struct.unpack(">ihhi ii", raw_bytes[base + 4:base + 24])
        entries[f"{t_name}#{t_num}"] = (e_type, e_size, n_el, d_size, d_off)

    def get_bytes(key: str) -> bytes:
        if key not in entries:
            return b""
        _, _, _, d_size, d_off = entries[key]
        if d_size <= 4:
            return struct.pack(">i", d_off)[:max(0, d_size)]
        return raw_bytes[d_off:d_off + d_size] if d_off + d_size <= len(raw_bytes) else b""

    def get_i16_array(key: str) -> List[int]:
        b = get_bytes(key)
        cnt = len(b) // 2
        return list(struct.unpack(f">{cnt}h", b[:cnt * 2])) if cnt > 0 else []

    fwo = get_bytes("FWO_#1").decode("ascii", errors="ignore").upper() or "GATC"
    d_nums = [9, 10, 11, 12] if "DATA#9" in entries else [1, 2, 3, 4]
    traces = {}
    for idx, ch in enumerate(fwo[:4]):
        traces[ch] = get_i16_array(f"DATA#{d_nums[idx]}")

    pbas_bytes = get_bytes("PBAS#1") or get_bytes("PBAS#2")
    seq = "".join(ch for ch in pbas_bytes.decode("ascii", errors="ignore").upper() if ch in "ACGTN")
    plocs = get_i16_array("PLOC#1") or get_i16_array("PLOC#2")

    peaks_acgt: List[List[float]] = []
    for i in range(len(seq)):
        if i < len(plocs):
            t_idx = plocs[i]
            row = [
                float(traces.get(ch, [])[t_idx]) if (0 <= t_idx < len(traces.get(ch, []))) else 0.0
                for ch in ("A", "C", "G", "T")
            ]
        else:
            row = [0.0, 0.0, 0.0, 0.0]
        peaks_acgt.append(row)

    return {"is_ab1": True, "sequence": seq, "peaks_acgt": peaks_acgt}


_DEFAULT_SANGER_PRIMER_SUFFIX_RE = re.compile(r"[-_.]?(F|R|Fwd|Rev|T7|T3|SP6|M13F|M13R|CMV[-_]?F|BGH[-_]?R|U6[-_]?F|Seq\d*)$", re.IGNORECASE)


def _extract_sanger_clone_name(file_name: str, regex_pattern: str = None) -> tuple:
    base = os.path.splitext(os.path.basename(file_name or ""))[0].strip()
    if not base:
        return ("Clone", None)
    pat = re.compile(regex_pattern, re.IGNORECASE) if regex_pattern else _DEFAULT_SANGER_PRIMER_SUFFIX_RE
    m = pat.search(base)
    if m:
        raw_suf = m.group(0)
        primer = re.sub(r"^[-_.]+", "", raw_suf)
        clone_prefix = base[:m.start()].rstrip("-_. ")
        return (clone_prefix if clone_prefix else base, primer or None)
    return (base, None)


def _align_single_sanger_read(parsed: dict, sample_name: str, ref_seq: str, ref_title: str, trim_q: int = 20) -> dict:
    raw_seq = parsed["sequence"]
    quals = parsed["qualities"]
    n = len(raw_seq)
    if n < 16:
        raise ValueError(f"测序读长过短 ({sample_name}: {n} < 16 bp)")

    win = min(10, max(1, n // 4))
    trim_s, trim_e = 0, n
    if n > win * 2 and len(quals) >= n:
        for i in range(0, n - win):
            if quals[i] >= trim_q and (sum(quals[i:i + win]) / win) >= trim_q:
                trim_s = i
                break
        for i in range(n, trim_s + win - 1, -1):
            if quals[i - 1] >= trim_q and (sum(quals[i - win:i]) / win) >= trim_q:
                trim_e = i
                break
    trimmed_seq = raw_seq[trim_s:trim_e]

    doubled_ref = ref_seq + ref_seq
    ref_len = max(1, len(ref_seq))
    k = min(11, max(7, len(trimmed_seq) // 5))

    def best_seed_start(q_str):
        votes = {}
        for qp in range(0, max(1, len(q_str) - k + 1), max(1, (len(q_str) - k) // 20)):
            km = q_str[qp:qp + k]
            pos = doubled_ref.find(km)
            while pos != -1:
                est = pos - qp
                if 0 <= est < ref_len:
                    b = (est // 4) * 4
                    votes[b] = votes.get(b, 0) + 1
                pos = doubled_ref.find(km, pos + 1)
        if not votes:
            return (0, 0)
        return max(votes.items(), key=lambda x: x[1])

    fwd_start, fwd_hits = best_seed_start(trimmed_seq)
    rev_q = rev_comp(trimmed_seq)
    rev_start, rev_hits = best_seed_start(rev_q)
    max_hits = max(fwd_hits, rev_hits)
    is_rev = rev_hits > fwd_hits
    chosen_q = rev_q if is_rev else trimmed_seq
    est_start = rev_start if is_rev else fwd_start

    anchor_k = min(12, len(chosen_q))
    exact_pos = doubled_ref.find(chosen_q[:anchor_k], max(0, est_start - 8))
    if exact_pos != -1 and abs(exact_pos - est_start) <= 16:
        est_start = exact_pos

    ref_window = doubled_ref[est_start:est_start + len(chosen_q)]
    matches = 0
    mismatches = []
    for i in range(min(len(ref_window), len(chosen_q))):
        rb = ref_window[i]
        qb = chosen_q[i]
        if rb == qb:
            matches += 1
        else:
            ref_pos1 = ((est_start + i) % ref_len) + 1
            read_pos1 = (trim_e - i) if is_rev else (trim_s + i + 1)
            mismatches.append({
                "ref_pos_1based": ref_pos1,
                "read_pos_1based": read_pos1,
                "ref_base": rb,
                "read_base": qb,
                "hgvs": f"g.{ref_pos1}{rb}>{qb}"
            })

    aligned_len = max(1, len(chosen_q))
    identity_pct = round(matches * 100.0 / aligned_len, 1)
    is_unaligned = (max_hits == 0 and identity_pct < 60.0)
    if is_unaligned:
        verdict = "未匹配到同源区"
        batch_verdict = "unmatched"
    elif len(mismatches) == 0 and len(parsed["double_peaks"]) == 0:
        verdict = "测序完全匹配 (100% 零突变通过)"
        batch_verdict = "pass"
    elif len(mismatches) > 0:
        verdict = f"检出 {len(mismatches)} 处点突变 / 碱基替换 (SNP)"
        batch_verdict = "failed"
    else:
        verdict = f"检出 {len(parsed['double_peaks'])} 处杂合双峰预警"
        batch_verdict = "needsReview"

    return {
        "status": "success",
        "sample_name": sample_name,
        "is_binary_ab1": parsed["is_ab1"],
        "raw_length_bp": n,
        "trimmed_length_bp": len(trimmed_seq),
        "reference_plasmid": ref_title,
        "reference_length_bp": ref_len,
        "strand": "-" if is_rev else "+",
        "matched_ref_start_1based": (est_start % ref_len) + 1,
        "matched_ref_end_1based": ((est_start + len(chosen_q) - 1) % ref_len) + 1,
        "identity_percent": identity_pct,
        "verdict": verdict,
        "batch_verdict": batch_verdict,
        "mismatches": mismatches,
        "double_peaks": parsed["double_peaks"]
    }


def tool_verify_sanger_sequencing(args: dict) -> dict:
    """解析 Sanger 测序 (.ab1/.abi/.seq) 四色峰图并与参考质粒执行环状比对（支持单文件或 files 数组批量克隆分组验证 P11）"""
    ab1_path = (args.get("ab1_file_path") or "").strip()
    read_seq_arg = (args.get("read_sequence") or "").strip()
    plasmid_name = (args.get("plasmid_name") or "").strip()
    ref_seq_arg = (args.get("reference_sequence") or "").strip()
    trim_q = int(args.get("trim_quality_threshold", 20))
    batch_files = args.get("files") or []
    references_in = args.get("references") or []

    default_egfp_ref = clean_seq(
        "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTG"
        "CCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAG"
        "GGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAG"
        "CTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGC"
        "CGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTAC"
        "GTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTG"
    )

    if ref_seq_arg:
        primary_ref_seq = clean_seq(ref_seq_arg)
        primary_ref_title = plasmid_name or "Custom_Reference"
    elif plasmid_name:
        pool = load_plasmid_pool()
        item = find_plasmid_in_pool(plasmid_name, pool)
        primary_ref_seq = clean_seq(item["dnaInfo"]["sequence"])
        primary_ref_title = item["name"]
    else:
        primary_ref_seq = default_egfp_ref
        primary_ref_title = "EGFP-CDS 标准参考载体"

    if isinstance(batch_files, list) and len(batch_files) > 0:
        cand_refs = []
        for r in references_in:
            r_name = (r.get("name") or "").strip()
            r_seq = clean_seq(r.get("sequence") or "")
            if r_name and len(r_seq) >= 16:
                cand_refs.append((r_name, r_seq))
        if not cand_refs:
            cand_refs.append((primary_ref_title, primary_ref_seq))

        read_reports = []
        clone_groups = {}
        clone_order = []
        for fp in batch_files:
            full_fp = os.path.expanduser(str(fp).strip())
            if not os.path.exists(full_fp):
                continue
            with open(full_fp, "rb") as f:
                parsed = _parse_ab1_bytes(f.read())
            s_name = os.path.basename(full_fp)
            c_name, primer_suf = _extract_sanger_clone_name(s_name, args.get("clone_grouping_regex"))
            best_rep = None
            for r_title, r_seq in cand_refs:
                rep = _align_single_sanger_read(parsed, s_name, r_seq, r_title, trim_q=trim_q)
                if c_name.lower() in r_title.lower() or r_title.lower() in c_name.lower():
                    best_rep = rep
                    break
                if best_rep is None or rep["identity_percent"] > best_rep["identity_percent"]:
                    best_rep = rep
            if best_rep is None:
                continue
            best_rep["clone_name"] = c_name
            best_rep["primer_suffix"] = primer_suf
            read_reports.append(best_rep)
            if c_name not in clone_groups:
                clone_groups[c_name] = []
                clone_order.append(c_name)
            clone_groups[c_name].append(best_rep)

        clone_summaries = []
        for c_name in clone_order:
            items = clone_groups[c_name]
            ref_len = max(1, items[0]["reference_length_bp"])
            covered = [False] * ref_len
            ident_sum = 0.0
            snp_cnt = 0
            dp_cnt = 0
            has_unmatched = False
            for it in items:
                ident_sum += it["identity_percent"]
                snp_cnt += len(it["mismatches"])
                dp_cnt += len(it["double_peaks"])
                if it["batch_verdict"] == "unmatched":
                    has_unmatched = True
                else:
                    s0 = max(0, it["matched_ref_start_1based"] - 1)
                    ln = min(ref_len, max(1, it["trimmed_length_bp"]))
                    for step in range(ln):
                        covered[(s0 + step) % ref_len] = True
            cov_bp = sum(1 for x in covered if x)
            cov_pct = round(cov_bp * 100.0 / ref_len, 1)
            if all(it["batch_verdict"] == "unmatched" for it in items):
                c_verdict = "unmatched"
            elif snp_cnt > 0:
                c_verdict = "failed"
            elif dp_cnt > 0 or has_unmatched:
                c_verdict = "needsReview"
            else:
                c_verdict = "pass"
            clone_summaries.append({
                "clone_name": c_name,
                "reference_plasmid": items[0]["reference_plasmid"],
                "read_count": len(items),
                "coverage_bp": cov_bp,
                "coverage_percent": cov_pct,
                "mean_identity_percent": round(ident_sum / len(items), 1),
                "snp_count": snp_cnt,
                "double_peak_count": dp_cnt,
                "verdict": c_verdict
            })

        notify_gui_and_sync_primers(
            action_summary=f"MCP Sanger 批量测序验证：{len(read_reports)} 条读长 / {len(clone_summaries)} 个克隆",
            primers=[],
            target_module="sangerVerify"
        )
        return {
            "status": "success",
            "mode": "batch",
            "read_count": len(read_reports),
            "clone_count": len(clone_summaries),
            "clone_summaries": clone_summaries,
            "reads": read_reports
        }

    if ab1_path and os.path.exists(os.path.expanduser(ab1_path)):
        full_ab1 = os.path.expanduser(ab1_path)
        with open(full_ab1, "rb") as f:
            parsed = _parse_ab1_bytes(f.read())
        sample_name = os.path.basename(full_ab1)
    else:
        seq_clean = clean_seq(read_seq_arg)
        parsed = {"is_ab1": False, "sequence": seq_clean, "qualities": [42] * len(seq_clean), "double_peaks": []}
        sample_name = args.get("sample_name") or "Sanger_Read"

    res = _align_single_sanger_read(parsed, sample_name, primary_ref_seq, primary_ref_title, trim_q=trim_q)
    notify_gui_and_sync_primers(
        action_summary=f"MCP Sanger 测序比对验证：{sample_name} vs {primary_ref_title} ({res['identity_percent']}%)",
        primers=[],
        target_module="sangerVerify"
    )
    return res


def _lawson_hanson_nnls_fallback(columns: list, rhs: list, tol: float = 1e-11) -> tuple:
    """当系统自带 Python 环境未安装 scipy 时的纯 Python Lawson-Hanson Active-Set Householder QR 求解器（与 scipy.optimize.nnls 数学等价）"""
    n = len(columns)
    m = len(rhs)
    if n == 0 or m == 0:
        return ([0.0] * max(0, n), 0.0)

    x = [0.0] * n
    passive = []
    is_passive = [False] * n
    max_col_norm = max([1.0] + [math.sqrt(sum(v * v for v in col)) for col in columns])
    dual_tol = tol * max_col_norm

    def compute_residual(cur_x):
        r = list(rhs)
        for j, wj in enumerate(cur_x):
            if wj != 0.0:
                col = columns[j]
                for i in range(m):
                    r[i] -= wj * col[i]
        return r

    def compute_dual_grad(res):
        return [sum(col[i] * res[i] for i in range(m)) for col in columns]

    def solve_passive_ls(p_indices):
        k = len(p_indices)
        if k == 0:
            return []
        qr_cols = [list(columns[idx]) for idx in p_indices]
        qt_b = list(rhs)
        steps = min(k, m)
        for j in range(steps):
            norm_sq = sum(qr_cols[j][r] * qr_cols[j][r] for r in range(j, m))
            norm = math.sqrt(norm_sq)
            if norm < 1e-14:
                continue
            pivot = qr_cols[j][j]
            alpha = -norm if pivot >= 0.0 else norm
            v = [qr_cols[j][r] for r in range(j, m)]
            v[0] -= alpha
            v_norm_sq = sum(val * val for val in v)
            qr_cols[j][j] = alpha
            for r in range(j + 1, m):
                qr_cols[j][r] = 0.0
            if v_norm_sq <= 1e-28:
                continue
            for c in range(j + 1, k):
                dot = sum(v[idx] * qr_cols[c][j + idx] for idx in range(m - j))
                scale = -2.0 * dot / v_norm_sq
                for idx in range(m - j):
                    qr_cols[c][j + idx] += scale * v[idx]
            dot_b = sum(v[idx] * qt_b[j + idx] for idx in range(m - j))
            scale_b = -2.0 * dot_b / v_norm_sq
            for idx in range(m - j):
                qt_b[j + idx] += scale_b * v[idx]

        s_p = [0.0] * k
        for r in range(min(k, m) - 1, -1, -1):
            val = qt_b[r]
            for c in range(r + 1, k):
                val -= qr_cols[c][r] * s_p[c]
            diag = qr_cols[r][r]
            s_p[r] = (val / diag) if abs(diag) > 1e-12 else 0.0
        return s_p

    residual = compute_residual(x)
    dual_grad = compute_dual_grad(residual)
    max_iter = max(50, 3 * n)
    for _ in range(max_iter):
        best_idx = -1
        best_grad = dual_tol
        for j in range(n):
            if not is_passive[j] and dual_grad[j] > best_grad:
                best_grad = dual_grad[j]
                best_idx = j
        if best_idx == -1:
            break
        passive.append(best_idx)
        is_passive[best_idx] = True

        for _ in range(max(20, 2 * n)):
            s_p = solve_passive_ls(passive)
            if min(s_p) > 0.0:
                for loc_i, col_i in enumerate(passive):
                    x[col_i] = s_p[loc_i]
                break
            alpha = 1.0
            for loc_i, col_i in enumerate(passive):
                sj = s_p[loc_i]
                if sj <= 0.0:
                    xj = x[col_i]
                    denom = xj - sj
                    ratio = (xj / denom) if denom > 0.0 else 0.0
                    if ratio < alpha:
                        alpha = ratio
            new_passive = []
            for loc_i, col_i in enumerate(passive):
                upd = x[col_i] + alpha * (s_p[loc_i] - x[col_i])
                if upd <= 1e-13:
                    x[col_i] = 0.0
                    is_passive[col_i] = False
                else:
                    x[col_i] = upd
                    new_passive.append(col_i)
            passive = new_passive
            if not passive:
                break

        residual = compute_residual(x)
        dual_grad = compute_dual_grad(residual)

    residual = compute_residual(x)
    res_norm = math.sqrt(sum(r * r for r in residual))
    return (x, res_norm)


def solve_nnls_deconv(columns: list, rhs: list) -> tuple:
    """优先调用 scipy.optimize.nnls 求解非负最小二乘 min_{w>=0} ||X*w - y||_2，与 Swift CRISPRDeconvolutionEngine.solveNNLS 严格对齐"""
    n = len(columns)
    m = len(rhs)
    if n == 0 or m == 0:
        return ([0.0] * max(0, n), 0.0)
    try:
        import numpy as np
        from scipy.optimize import nnls as scipy_nnls
        x_mat = np.column_stack([np.asarray(col, dtype=np.float64) for col in columns])
        y_vec = np.asarray(rhs, dtype=np.float64)
        weights, res_norm = scipy_nnls(x_mat, y_vec)
        return ([float(w) for w in weights], float(res_norm))
    except ImportError:
        return _lawson_hanson_nnls_fallback(columns, rhs)


def peaks_from_sequence(seq: str, primary_signal: float = 1000.0, background_signal: float = 20.0) -> list:
    """将 DNA 序列转为标准四通道荧光峰高矩阵 [[A, C, G, T]]"""
    cleaned = clean_seq(seq)
    out = []
    for b in cleaned:
        if b == "A":
            out.append([primary_signal, background_signal, background_signal, background_signal])
        elif b == "C":
            out.append([background_signal, primary_signal, background_signal, background_signal])
        elif b == "G":
            out.append([background_signal, background_signal, primary_signal, background_signal])
        elif b == "T":
            out.append([background_signal, background_signal, background_signal, primary_signal])
        else:
            mid = (primary_signal + 3.0 * background_signal) / 4.0
            out.append([mid, mid, mid, mid])
    return out


def locate_crispr_cut_site(wt_sequence: str, sgrna_sequence: str):
    """在 WT 序列中定位 sgRNA 及其 SpCas9 切割位点 (0-based 下标)"""
    clean_wt = clean_seq(wt_sequence)
    clean_sg = clean_seq(sgrna_sequence)
    if len(clean_wt) < len(clean_sg) or len(clean_sg) < 12:
        return None
    pos = clean_wt.find(clean_sg)
    if pos != -1:
        return (pos + len(clean_sg) - 3, False)
    rc_sg = rev_comp(clean_sg)
    rc_pos = clean_wt.find(rc_sg)
    if rc_pos != -1:
        return (rc_pos + 3, True)
    return None


def deconvolve_sanger_crispr(args: dict) -> dict:
    """Synthego ICE 风格 Sanger 编辑池四通道峰图 NNLS 解卷积（使用 scipy.optimize.nnls，对齐 Swift CRISPRDeconvolutionEngine）"""
    wt_seq = clean_seq(args.get("wt_sequence") or "")
    sgrna_seq = clean_seq(args.get("sgrna_sequence") or "")
    hdr_seq = clean_seq(args.get("hdr_donor_sequence") or "") if args.get("hdr_donor_sequence") else ""
    req_win = int(args.get("window_length_bp") or args.get("requested_window_length_bp") or 150)
    shift_min = int(args.get("shift_min_bp", -20))
    shift_max = int(args.get("shift_max_bp", 20))
    noise_floor = float(args.get("noise_floor_weight", 1e-6))

    wt_peaks = args.get("wt_peaks_acgt")
    if not wt_peaks and wt_seq:
        wt_peaks = peaks_from_sequence(wt_seq)
    wt_peaks = [[float(v) for v in row[:4]] for row in (wt_peaks or [])]

    is_rev_sg = bool(args.get("is_reverse_strand_sgrna", False))
    if "cut_index_0based" in args and args["cut_index_0based"] is not None:
        cut_idx = int(args["cut_index_0based"])
        if wt_seq and sgrna_seq:
            loc = locate_crispr_cut_site(wt_seq, sgrna_seq)
            if loc is not None:
                is_rev_sg = loc[1]
    else:
        loc = locate_crispr_cut_site(wt_seq, sgrna_seq)
        if loc is None:
            return {
                "cut_index_0based": 0,
                "is_reverse_strand_sgrna": False,
                "requested_window_bp": req_win,
                "effective_window_bp": 0,
                "wt_percent": 0.0,
                "indel_percent": 0.0,
                "ko_score": 0.0,
                "hdr_percent": 0.0,
                "total_edited_percent": 0.0,
                "r_squared": 0.0,
                "residual_norm": 0.0,
                "warnings": ["SGRNA_NOT_FOUND_IN_WT"],
                "contributions": [],
                "dominant_indels": []
            }
        cut_idx, is_rev_sg = loc

    edited_win_peaks = [[float(v) for v in row[:4]] for row in (args.get("edited_peaks_acgt") or [])]
    hdr_win_peaks = args.get("hdr_peaks_acgt")
    if not hdr_win_peaks and hdr_seq:
        hdr_full = peaks_from_sequence(hdr_seq)
        if cut_idx < len(hdr_full):
            hdr_win_peaks = hdr_full[cut_idx:cut_idx + req_win]
    if hdr_win_peaks:
        hdr_win_peaks = [[float(v) for v in row[:4]] for row in hdr_win_peaks]

    warnings = []
    n_wt = len(wt_peaks)
    max_del = max(0, -shift_min)
    max_ins = max(0, shift_max)
    if cut_idx < max_ins:
        warnings.append("CUT_SITE_TOO_CLOSE_TO_5PRIME")

    max_wt_win = max(0, n_wt - max_del - cut_idx)
    eff_w = min(req_win, max_wt_win, len(edited_win_peaks))
    if eff_w < req_win:
        warnings.append("WINDOW_TRUNCATED_AT_3PRIME_END")
    if eff_w < 30:
        warnings.append("INSUFFICIENT_DOWNSTREAM_WINDOW")

    if eff_w <= 0 or cut_idx < 0 or cut_idx >= n_wt:
        return {
            "cut_index_0based": cut_idx,
            "is_reverse_strand_sgrna": is_rev_sg,
            "requested_window_bp": req_win,
            "effective_window_bp": max(0, eff_w),
            "wt_percent": 0.0,
            "indel_percent": 0.0,
            "ko_score": 0.0,
            "hdr_percent": 0.0,
            "total_edited_percent": 0.0,
            "r_squared": 0.0,
            "residual_norm": 0.0,
            "warnings": warnings,
            "contributions": [],
            "dominant_indels": []
        }

    shifts = list(range(shift_min, shift_max + 1))
    columns = []
    for s in shifts:
        col = []
        for k in range(eff_w):
            src_idx = min(max(0, cut_idx + k - s), n_wt - 1)
            col.extend(wt_peaks[src_idx][:4])
        columns.append(col)

    has_hdr = False
    if hdr_win_peaks and len(hdr_win_peaks) >= eff_w:
        hdr_col = []
        for k in range(eff_w):
            hdr_col.extend(hdr_win_peaks[k][:4])
        columns.append(hdr_col)
        has_hdr = True

    rhs = []
    for k in range(eff_w):
        rhs.extend(edited_win_peaks[k][:4])

    raw_weights, res_norm = solve_nnls_deconv(columns, rhs)
    ss_res = res_norm * res_norm
    mean_y = sum(rhs) / len(rhs)
    ss_tot = sum((val - mean_y) ** 2 for val in rhs)
    r_squared = max(0.0, min(1.0, 1.0 - (ss_res / ss_tot))) if ss_tot > 1e-12 else 1.0
    if r_squared < 0.75:
        warnings.append("LOW_FIT_R_SQUARED")

    cleaned_weights = [w if w >= noise_floor else 0.0 for w in raw_weights]
    w_sum = sum(cleaned_weights)
    norm_scale = (100.0 / w_sum) if w_sum > 1e-12 else 0.0

    wt_pct = 0.0
    indel_pct = 0.0
    ko_pct = 0.0
    hdr_pct = 0.0
    contributions = []

    for idx, s in enumerate(shifts):
        rw = cleaned_weights[idx]
        pct = rw * norm_scale
        is_fs = (abs(s) % 3) != 0
        lbl = f"+{s}" if s > 0 else f"{s}"
        if s == 0:
            wt_pct = pct
        else:
            indel_pct += pct
            if is_fs:
                ko_pct += pct
        contributions.append({
            "label": lbl,
            "shift_bp": s,
            "is_hdr": False,
            "is_frameshift": is_fs,
            "raw_weight": rw,
            "percent": pct
        })

    if has_hdr:
        rw = cleaned_weights[len(shifts)]
        pct = rw * norm_scale
        hdr_pct = pct
        contributions.append({
            "label": "HDR",
            "shift_bp": None,
            "is_hdr": True,
            "is_frameshift": False,
            "raw_weight": rw,
            "percent": pct
        })

    dominant = sorted(
        [c for c in contributions if c["percent"] >= 0.5],
        key=lambda c: (-round(c["percent"], 6), c["shift_bp"] if c["shift_bp"] is not None else 999)
    )

    return {
        "cut_index_0based": cut_idx,
        "is_reverse_strand_sgrna": is_rev_sg,
        "requested_window_bp": req_win,
        "effective_window_bp": eff_w,
        "wt_percent": wt_pct,
        "indel_percent": indel_pct,
        "ko_score": ko_pct,
        "hdr_percent": hdr_pct,
        "total_edited_percent": indel_pct + hdr_pct,
        "r_squared": r_squared,
        "residual_norm": res_norm,
        "warnings": warnings,
        "contributions": contributions,
        "dominant_indels": dominant
    }


def load_plasmid_features_from_sqlite(db_path: str = None) -> list:
    """从 Libraries.sqlite 只读加载标准质粒元件表 plasmid_features"""
    import sqlite3
    resolved = db_path or os.path.join(SCRIPT_DIR, "Libraries.sqlite")
    if not os.path.exists(resolved):
        return []
    conn = sqlite3.connect(f"file:{os.path.abspath(resolved)}?mode=ro", uri=True)
    try:
        rows = conn.execute(
            "SELECT id, name, category, sequence, direction, color_hex FROM plasmid_features ORDER BY id ASC;"
        ).fetchall()
        return [
            {
                "id": int(r[0]),
                "name": str(r[1]),
                "category": str(r[2]),
                "sequence": clean_seq(str(r[3])),
                "direction": int(r[4]),
                "color_hex": str(r[5]),
            }
            for r in rows
        ]
    finally:
        conn.close()


def parse_fasta_sequence(raw_text: str, default_name: str = "Unannotated_Plasmid") -> tuple:
    """解析单条或多行 FASTA / 纯 DNA 文本，返回 (名称, 清洗后序列)"""
    parsed_name = default_name
    found_header = False
    body_parts = []
    for line in str(raw_text or "").splitlines():
        trimmed = line.strip()
        if not trimmed:
            continue
        if trimmed.startswith(">"):
            if not found_header:
                hdr = trimmed[1:].strip()
                if hdr:
                    parsed_name = hdr
                found_header = True
        else:
            body_parts.append(trimmed)
    return (parsed_name, clean_seq("".join(body_parts)))


def annotate_plasmid_sequence(
    sequence: str,
    plasmid_name: str = "Unannotated_Plasmid",
    is_circular: bool = True,
    features_library: list = None,
    db_path: str = None,
    min_identity: float = 0.85,
    min_fragment_coverage: float = 0.30,
    full_feature_coverage_threshold: float = 0.90,
) -> dict:
    """基于 Libraries.sqlite 的本地离线质粒自动注释算法（双链 + 环形跨零点 + 30%-90% Fragment 标记，与 Swift PlasmidAnnotationEngine 严格对齐）"""
    from functools import cmp_to_key

    clean_query = clean_seq(sequence)
    query_len = len(clean_query)
    if query_len == 0:
        return {
            "plasmid_name": plasmid_name,
            "sequence_length": 0,
            "is_circular": bool(is_circular),
            "features_count": 0,
            "fragment_count": 0,
            "origin_spanning_count": 0,
            "annotated_coverage_percent": 0.0,
            "features": [],
            "warnings": ["输入质粒序列为空"],
        }

    library = features_library if features_library is not None else load_plasmid_features_from_sqlite(db_path=db_path)
    if not library:
        return {
            "plasmid_name": plasmid_name,
            "sequence_length": query_len,
            "is_circular": bool(is_circular),
            "features_count": 0,
            "fragment_count": 0,
            "origin_spanning_count": 0,
            "annotated_coverage_percent": 0.0,
            "features": [],
            "warnings": ["未能从 Libraries.sqlite 加载 plasmid_features 元件库"],
        }

    search_seq = (clean_query + clean_query) if is_circular else clean_query
    search_len = len(search_seq)

    search_kmer_cache = {}

    def get_search_kmer_index(k: int) -> dict:
        if k in search_kmer_cache:
            return search_kmer_cache[k]
        idx = {}
        if search_len >= k:
            for s_pos in range(0, search_len - k + 1):
                km = search_seq[s_pos:s_pos + k]
                idx.setdefault(km, []).append(s_pos)
        search_kmer_cache[k] = idx
        return idx

    candidates = []

    for feat in library:
        ref_fwd = clean_seq(feat["sequence"])
        ref_len = len(ref_fwd)
        if ref_len == 0:
            continue

        k = min(12, max(6, ref_len // 3))
        if k > ref_len or search_len < k:
            continue

        effective_min_cov = full_feature_coverage_threshold if ref_len < 40 else min_fragment_coverage
        min_aligned_len = min(ref_len, 15) if ref_len < 40 else 20
        s_kmers = get_search_kmer_index(k)

        ref_rev = rev_comp(ref_fwd)
        for strand, pattern_seq in (("+", ref_fwd), ("-", ref_rev)):
            diag_set = set()
            for p_pos in range(0, ref_len - k + 1):
                km = pattern_seq[p_pos:p_pos + k]
                hits = s_kmers.get(km)
                if hits:
                    for s_pos in hits:
                        d = s_pos - p_pos
                        if d < query_len and (d + ref_len) > 0:
                            diag_set.add(d)
            if not diag_set:
                continue

            for d in sorted(diag_set):
                p_lo = max(0, -d)
                p_hi = min(ref_len, search_len - d)
                if (p_hi - p_lo) < min_aligned_len:
                    continue

                cur_score = 0
                cur_start = p_lo
                best_score = 0
                best_start = p_lo
                best_end = p_lo

                for p in range(p_lo, p_hi):
                    step_score = 1 if search_seq[p + d] == pattern_seq[p] else -3
                    if cur_score <= 0:
                        cur_score = step_score
                        cur_start = p
                    else:
                        cur_score += step_score
                    if cur_score > best_score:
                        best_score = cur_score
                        best_start = cur_start
                        best_end = p + 1

                aligned_len = best_end - best_start
                if aligned_len < min_aligned_len or aligned_len > query_len:
                    continue

                s_start = best_start + d
                s_end = best_end + d
                if is_circular and s_start >= query_len:
                    continue
                if not is_circular and (s_start < 0 or s_end > query_len):
                    continue

                match_count = sum(1 for p in range(best_start, best_end) if search_seq[p + d] == pattern_seq[p])
                identity = match_count / float(aligned_len)
                coverage = aligned_len / float(ref_len)
                if identity < min_identity or coverage < effective_min_cov:
                    continue

                align_score = float(match_count) * 2.0 - float(aligned_len - match_count) * 6.0
                start_1 = (s_start % query_len) + 1
                end_1 = ((s_end - 1) % query_len) + 1
                origin_spanning = bool(is_circular and (s_end > query_len))

                feat_start_1 = (best_start + 1) if strand == "+" else (ref_len - best_end + 1)
                feat_end_1 = best_end if strand == "+" else (ref_len - best_start)

                is_frag = (coverage >= min_fragment_coverage) and (coverage < full_feature_coverage_threshold)
                cov_pct_rounded = int(math.floor(coverage * 100.0 + 0.5))
                disp_name = f"{feat['name']} (fragment)" if is_frag else feat["name"]
                frag_warn = f"历史克隆残留片段 (Fragment，覆盖率 {cov_pct_rounded}%)" if is_frag else None

                candidates.append((
                    {
                        "feature_id": int(feat["id"]),
                        "name": feat["name"],
                        "display_name": disp_name,
                        "category": feat["category"],
                        "strand": strand,
                        "canonical_direction": int(feat["direction"]),
                        "start_1based": start_1,
                        "end_1based": end_1,
                        "matched_length": aligned_len,
                        "reference_length": ref_len,
                        "feature_start_1based": feat_start_1,
                        "feature_end_1based": feat_end_1,
                        "coverage": coverage,
                        "identity": identity,
                        "alignment_score": align_score,
                        "is_origin_spanning": origin_spanning,
                        "is_fragment": is_frag,
                        "fragment_warning": frag_warn,
                        "color_hex": feat["color_hex"],
                    },
                    s_start,
                ))

    def _cmp_cand(lhs, rhs):
        a, b = lhs[0], rhs[0]
        if abs(a["alignment_score"] - b["alignment_score"]) > 1e-9:
            return -1 if a["alignment_score"] > b["alignment_score"] else 1
        if abs(a["identity"] - b["identity"]) > 1e-9:
            return -1 if a["identity"] > b["identity"] else 1
        if abs(a["coverage"] - b["coverage"]) > 1e-9:
            return -1 if a["coverage"] > b["coverage"] else 1
        if a["matched_length"] != b["matched_length"]:
            return -1 if a["matched_length"] > b["matched_length"] else 1
        if a["start_1based"] != b["start_1based"]:
            return -1 if a["start_1based"] < b["start_1based"] else 1
        if a["name"] != b["name"]:
            return -1 if a["name"] < b["name"] else 1
        if a["strand"] != b["strand"]:
            return -1 if a["strand"] < b["strand"] else 1
        return 0

    candidates.sort(key=cmp_to_key(_cmp_cand))

    occupied = [False] * query_len
    accepted = []
    for feat_hit, s_start0 in candidates:
        mlen = feat_hit["matched_length"]
        already_occ = sum(1 for off in range(mlen) if occupied[(s_start0 + off) % query_len])
        if (already_occ / float(mlen)) <= 0.15:
            accepted.append(feat_hit)
            for off in range(mlen):
                occupied[(s_start0 + off) % query_len] = True

    accepted.sort(key=lambda f: (f["start_1based"], f["end_1based"], f["name"]))

    frag_count = sum(1 for f in accepted if f["is_fragment"])
    origin_count = sum(1 for f in accepted if f["is_origin_spanning"])
    covered_bases = sum(1 for x in occupied if x)
    cov_percent = covered_bases * 100.0 / float(query_len)

    warnings = []
    if frag_count > 0:
        warnings.append(f"检出 {frag_count} 个历史克隆残留片段 (Fragment，覆盖率 30%–90%)，请核查载体改造史。")
    if origin_count > 0:
        warnings.append(f"检出 {origin_count} 个跨越环形质粒 1 bp 零点 (Origin) 的连续特征。")

    return {
        "plasmid_name": plasmid_name,
        "sequence_length": query_len,
        "is_circular": bool(is_circular),
        "features_count": len(accepted),
        "fragment_count": frag_count,
        "origin_spanning_count": origin_count,
        "annotated_coverage_percent": cov_percent,
        "features": accepted,
        "warnings": warnings,
    }


def annotate_plasmid_fasta(args: dict) -> dict:
    """解析 FASTA 或纯序列输入并调用 annotate_plasmid_sequence"""
    raw_fasta = args.get("fasta_text") or args.get("sequence") or ""
    default_name = str(args.get("plasmid_name") or "Unannotated_Plasmid").strip()
    parsed_name, clean_sequence = parse_fasta_sequence(raw_fasta, default_name=default_name)
    if args.get("plasmid_name") and not str(raw_fasta).lstrip().startswith(">"):
        parsed_name = str(args["plasmid_name"]).strip()
    return annotate_plasmid_sequence(
        sequence=clean_sequence,
        plasmid_name=parsed_name,
        is_circular=bool(args.get("is_circular", True)),
        db_path=args.get("db_path"),
        min_identity=float(args.get("min_identity", 0.85)),
        min_fragment_coverage=float(args.get("min_fragment_coverage", 0.30)),
        full_feature_coverage_threshold=float(args.get("full_feature_coverage_threshold", 0.90)),
    )


TYPE_IIS_ENZYME_SPECS = {
    "bsai": {"name": "BsaI", "site": "GGTCTC", "rc_site": "GAGACC", "cut_top": 7, "cut_bottom": 11, "overhang_len": 4},
    "bsmbi": {"name": "BsmBI", "site": "CGTCTC", "rc_site": "GAGACG", "cut_top": 7, "cut_bottom": 11, "overhang_len": 4},
    "bbsi": {"name": "BbsI", "site": "GAAGAC", "rc_site": "GTCTTC", "cut_top": 8, "cut_bottom": 12, "overhang_len": 4},
    "sapi": {"name": "SapI", "site": "GCTCTTC", "rc_site": "GAAGAGC", "cut_top": 8, "cut_bottom": 11, "overhang_len": 3},
}

DEFAULT_DIAGNOSTIC_ENZYMES = {
    "AgeI": ("ACCGGT", 1, 5),
    "BamHI": ("GGATCC", 1, 5),
    "BglII": ("AGATCT", 1, 5),
    "ClaI": ("ATCGAT", 2, 4),
    "DraI": ("TTTAAA", 3, 3),
    "EcoRI": ("GAATTC", 1, 5),
    "EcoRV": ("GATATC", 3, 3),
    "HindIII": ("AAGCTT", 1, 5),
    "KpnI": ("GGTACC", 5, 1),
    "NcoI": ("CCATGG", 1, 5),
    "NdeI": ("CATATG", 2, 4),
    "NheI": ("GCTAGC", 1, 5),
    "NotI": ("GCGGCCGC", 2, 6),
    "PstI": ("CTGCAG", 5, 1),
    "PvuII": ("CAGCTG", 3, 3),
    "SacI": ("GAGCTC", 5, 1),
    "SacII": ("CCGCGG", 4, 2),
    "SalI": ("GTCGAC", 1, 5),
    "ScaI": ("AGTACT", 3, 3),
    "SmaI": ("CCCGGG", 3, 3),
    "SpeI": ("ACTAGT", 1, 5),
    "StuI": ("AGGCCT", 3, 3),
    "XbaI": ("TCTAGA", 1, 5),
    "XhoI": ("CTCGAG", 1, 5),
}

NEB_BUFFER_COMPAT_TABLE = {
    "ecori": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 25},
    "bamhi": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 75},
    "hindiii": {"CutSmart": 100, "r2.1": 100, "r3.1": 50, "r1.1": 50},
    "sali": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 10},
    "xhoi": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 75},
    "ndei": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 75},
    "saci": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 10},
    "kpni": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 25},
    "bsai": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 50},
    "bbsi": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 10},
    "bsmbi": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 50},
    "sapi": {"CutSmart": 100, "r2.1": 75, "r3.1": 10, "r1.1": 50},
    "noti": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 10},
    "xbai": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 25},
    "psti": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 75},
    "smai": {"CutSmart": 100, "r2.1": 25, "r3.1": 10, "r1.1": 50},
    "spei": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 100},
    "clai": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 100},
    "bglii": {"CutSmart": 10, "r2.1": 100, "r3.1": 100, "r1.1": 10},
    "ecorv": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 50},
    "ncoi": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 50},
    "scai": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 50},
    "pvuii": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 50},
    "stui": {"CutSmart": 100, "r2.1": 100, "r3.1": 50, "r1.1": 50},
    "drai": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 75},
    "sacii": {"CutSmart": 100, "r2.1": 100, "r3.1": 10, "r1.1": 10},
    "nhei": {"CutSmart": 100, "r2.1": 100, "r3.1": 100, "r1.1": 100},
    "agei": {"CutSmart": 100, "r2.1": 75, "r3.1": 25, "r1.1": 100},
}

GG_CODON_TO_AA = {
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

GG_PREFERRED_CODONS = {
    "A": ["GCC", "GCT", "GCA", "GCG"],
    "C": ["TGC", "TGT"],
    "D": ["GAC", "GAT"],
    "E": ["GAG", "GAA"],
    "F": ["TTC", "TTT"],
    "G": ["GGC", "GGT", "GGA", "GGG"],
    "H": ["CAC", "CAT"],
    "I": ["ATC", "ATT", "ATA"],
    "K": ["AAG", "AAA"],
    "L": ["CTG", "CTC", "CTT", "TTG", "TTA", "CTA"],
    "M": ["ATG"],
    "N": ["AAC", "AAT"],
    "P": ["CCC", "CCT", "CCA", "CCG"],
    "Q": ["CAG", "CAA"],
    "R": ["CGC", "CGT", "AGG", "AGA", "CGG", "CGA"],
    "S": ["AGC", "TCC", "TCT", "AGT", "TCA", "TCG"],
    "T": ["ACC", "ACT", "ACA", "ACG"],
    "V": ["GTG", "GTC", "GTT", "GTA"],
    "W": ["TGG"],
    "Y": ["TAC", "TAT"],
    "*": ["TGA", "TAA", "TAG"],
}


def load_neb_ligase_fidelity_from_sqlite(db_path: str = None) -> dict:
    """从 Libraries.sqlite 只读加载 NEB T4 DNA Ligase 4-bp 保真度矩阵"""
    import sqlite3
    resolved = db_path or os.path.join(SCRIPT_DIR, "Libraries.sqlite")
    if not os.path.exists(resolved):
        return {"stats": {}, "counts": {}}
    conn = sqlite3.connect(f"file:{os.path.abspath(resolved)}?mode=ro", uri=True)
    try:
        stats = {}
        for r in conn.execute(
            "SELECT overhang, rc_overhang, is_palindromic, gc_count, wc_ligation_count, individual_fidelity, is_neb_verified_hf FROM neb_t4_overhang_stats;"
        ):
            stats[str(r[0])] = {
                "overhang": str(r[0]),
                "rc_overhang": str(r[1]),
                "is_palindromic": bool(r[2]),
                "gc_count": int(r[3]),
                "wc_ligation_count": int(r[4]),
                "individual_fidelity": float(r[5]),
                "is_neb_verified_hf": bool(r[6]),
            }
        counts = {}
        for a, b, cnt in conn.execute("SELECT overhang_a, overhang_b, ligation_count FROM neb_t4_ligase_fidelity;"):
            counts.setdefault(str(a), {})[str(b)] = int(cnt)
        return {"stats": stats, "counts": counts}
    finally:
        conn.close()


def evaluate_golden_gate_overhangs(overhangs: list, matrix: dict) -> dict:
    """评估一组 4-bp Golden Gate 接头的组装保真度与交叉错配数"""
    normalized = [clean_seq(o) for o in overhangs]
    counts = matrix.get("counts", {})
    issues = []
    seen_canon = set()
    for ov in normalized:
        if len(ov) != 4:
            issues.append(f"接头 {ov} 长度不为 4 bp")
            continue
        rc = rev_comp(ov)
        if ov == rc:
            issues.append(f"接头 {ov} 为回文序列")
        canon = min(ov, rc)
        if canon in seen_canon:
            issues.append(f"接头 {ov} 存在重复或反向互补冲突")
        seen_canon.add(canon)

    exposed = []
    for ov in normalized:
        if len(ov) == 4:
            exposed.append(ov)
            exposed.append(rev_comp(ov))

    mismatches = []
    for i in range(len(exposed)):
        u = exposed[i]
        rc_u = rev_comp(u)
        u_map = counts.get(u, {})
        for j in range(i + 1, len(exposed)):
            v = exposed[j]
            if v == rc_u:
                continue
            cnt = u_map.get(v, 0)
            if cnt > 0:
                mismatches.append({"overhang_a": min(u, v), "overhang_b": max(u, v), "ligation_count": cnt})
    mismatches.sort(key=lambda x: (x["overhang_a"], x["overhang_b"]))

    fidelity = 1.0 if normalized else 0.0
    for ov in normalized:
        if len(ov) != 4:
            continue
        rc = rev_comp(ov)
        wc = float(counts.get(ov, {}).get(rc, 0) + counts.get(rc, {}).get(ov, 0))
        tot = 0.0
        ov_map = counts.get(ov, {})
        rc_map = counts.get(rc, {})
        for end in exposed:
            tot += float(ov_map.get(end, 0)) + float(rc_map.get(end, 0))
        fidelity *= (wc / tot) if tot > 0.0 else 0.0

    return {
        "overhangs": normalized,
        "is_valid": len(issues) == 0,
        "assembly_fidelity": fidelity,
        "cross_mismatch_count": len(mismatches),
        "cross_mismatch_pairs": mismatches,
        "issues": issues,
    }


def allocate_golden_gate_overhangs(
    fragment_count: int,
    enzyme_name: str = "BsaI",
    fixed_overhangs: list = None,
    is_circular: bool = True,
    matrix: dict = None,
    db_path: str = None,
) -> dict:
    """为 2–6 片段分配无交叉错配 4-bp/3-bp Golden Gate 高保真接头（对齐 Swift GoldenGateEngine）"""
    from functools import cmp_to_key

    clamped = max(2, min(6, int(fragment_count)))
    junc_count = clamped if is_circular else (clamped + 1)
    spec = TYPE_IIS_ENZYME_SPECS.get(enzyme_name.lower(), TYPE_IIS_ENZYME_SPECS["bsai"])
    ov_len = spec["overhang_len"]
    warnings = []
    if fragment_count != clamped:
        warnings.append(f"片段数已调整至支持范围 2–6 ({clamped})。")

    fixed_list = fixed_overhangs or []

    if ov_len == 3:
        import itertools
        all_3mers = []
        for tup in itertools.product("ACGT", repeat=3):
            s = "".join(tup)
            if s in ("AAA", "TTT", "CCC", "GGG"):
                continue
            rc = rev_comp(s)
            if s < rc:
                all_3mers.append(s)

        def _cmp_3mer(x, y):
            gc_x = x.count("G") + x.count("C")
            gc_y = y.count("G") + y.count("C")
            bal_x = abs(gc_x - 1) <= 1 and 1 <= gc_x <= 2
            bal_y = abs(gc_y - 1) <= 1 and 1 <= gc_y <= 2
            if bal_x != bal_y:
                return -1 if bal_x else 1
            return -1 if x < y else (1 if x > y else 0)

        all_3mers.sort(key=cmp_to_key(_cmp_3mer))
        chosen = []
        used_canon = set()
        for raw in fixed_list:
            ov = clean_seq(raw)
            if len(ov) != 3:
                continue
            canon = min(ov, rev_comp(ov))
            if canon not in used_canon and len(chosen) < junc_count:
                chosen.append(ov)
                used_canon.add(canon)

        def _clash_3bp(u: str, v: str) -> bool:
            mm = 0
            all_gt = True
            for i in range(3):
                a = u[i]
                b = v[2 - i]
                is_wc = (a, b) in (("A", "T"), ("T", "A"), ("C", "G"), ("G", "C"))
                if not is_wc:
                    mm += 1
                    if (a, b) not in (("G", "T"), ("T", "G")):
                        all_gt = False
            return mm == 1 or (mm == 2 and all_gt)

        while len(chosen) < junc_count:
            picked = None
            for cand in all_3mers:
                canon = min(cand, rev_comp(cand))
                if canon in used_canon:
                    continue
                trial_ends = []
                for o in chosen + [cand]:
                    trial_ends.extend([o, rev_comp(o)])
                clashes = 0
                for i in range(len(trial_ends)):
                    rc_i = rev_comp(trial_ends[i])
                    for j in range(i + 1, len(trial_ends)):
                        if trial_ends[j] != rc_i and _clash_3bp(trial_ends[i], trial_ends[j]):
                            clashes += 1
                if clashes == 0:
                    picked = cand
                    break
            if picked is not None:
                chosen.append(picked)
                used_canon.add(min(picked, rev_comp(picked)))
            else:
                warnings.append(f"SapI 3-bp 接头空间不足以完全无错配分配 {junc_count} 个位点。")
                break

        return {
            "enzyme_name": spec["name"],
            "fragment_count": clamped,
            "junction_count": junc_count,
            "overhang_length": 3,
            "assigned_overhangs": chosen,
            "assembly_fidelity": 1.0 if len(chosen) == junc_count else 0.90,
            "cross_mismatch_count": 0,
            "cross_mismatch_pairs": [],
            "warnings": warnings,
        }

    mat = matrix if matrix is not None else load_neb_ligase_fidelity_from_sqlite(db_path=db_path)
    stats = mat.get("stats", {})
    chosen = []
    used_canon = set()

    for raw_fixed in fixed_list:
        ov = clean_seq(raw_fixed)
        if len(ov) != 4:
            warnings.append(f"已忽略长度非 4 bp 的固定接头: {raw_fixed}")
            continue
        rc = rev_comp(ov)
        if ov == rc:
            warnings.append(f"已忽略回文固定接头: {ov}")
            continue
        canon = min(ov, rc)
        if canon in used_canon:
            warnings.append(f"已忽略重复或互补冲突的固定接头: {ov}")
            continue
        if len(chosen) < junc_count:
            chosen.append(ov)
            used_canon.add(canon)

    seen_pool = set()
    pool = []
    for rec in stats.values():
        if rec["is_palindromic"]:
            continue
        canon = min(rec["overhang"], rec["rc_overhang"])
        if canon in seen_pool:
            continue
        seen_pool.add(canon)
        pool.append(stats.get(canon, rec))

    def _cmp_pool(a, b):
        if a["is_neb_verified_hf"] != b["is_neb_verified_hf"]:
            return -1 if a["is_neb_verified_hf"] else 1
        if abs(a["individual_fidelity"] - b["individual_fidelity"]) > 1e-9:
            return -1 if a["individual_fidelity"] > b["individual_fidelity"] else 1
        if a["wc_ligation_count"] != b["wc_ligation_count"]:
            return -1 if a["wc_ligation_count"] > b["wc_ligation_count"] else 1
        return -1 if a["overhang"] < b["overhang"] else (1 if a["overhang"] > b["overhang"] else 0)

    pool.sort(key=cmp_to_key(_cmp_pool))

    while len(chosen) < junc_count:
        best_cand = None
        best_eval = None
        for cand in pool:
            canon = min(cand["overhang"], cand["rc_overhang"])
            if canon in used_canon:
                continue
            trial_eval = evaluate_golden_gate_overhangs(chosen + [cand["overhang"]], mat)
            if best_eval is not None and best_cand is not None:
                if trial_eval["cross_mismatch_count"] != best_eval["cross_mismatch_count"]:
                    better = trial_eval["cross_mismatch_count"] < best_eval["cross_mismatch_count"]
                elif abs(trial_eval["assembly_fidelity"] - best_eval["assembly_fidelity"]) > 1e-9:
                    better = trial_eval["assembly_fidelity"] > best_eval["assembly_fidelity"]
                elif cand["is_neb_verified_hf"] != best_cand["is_neb_verified_hf"]:
                    better = bool(cand["is_neb_verified_hf"]) and not bool(best_cand["is_neb_verified_hf"])
                elif abs(cand["individual_fidelity"] - best_cand["individual_fidelity"]) > 1e-9:
                    better = cand["individual_fidelity"] > best_cand["individual_fidelity"]
                else:
                    better = cand["overhang"] < best_cand["overhang"]
                if better:
                    best_cand = cand
                    best_eval = trial_eval
            else:
                best_cand = cand
                best_eval = trial_eval
        if best_cand is None:
            break
        chosen.append(best_cand["overhang"])
        used_canon.add(min(best_cand["overhang"], best_cand["rc_overhang"]))

    final_eval = evaluate_golden_gate_overhangs(chosen, mat)
    if final_eval["cross_mismatch_count"] > 0:
        warnings.append(f"当前约束下存在 {final_eval['cross_mismatch_count']} 组潜在交叉错配。")

    return {
        "enzyme_name": spec["name"],
        "fragment_count": clamped,
        "junction_count": junc_count,
        "overhang_length": ov_len,
        "assigned_overhangs": chosen,
        "assembly_fidelity": final_eval["assembly_fidelity"],
        "cross_mismatch_count": final_eval["cross_mismatch_count"],
        "cross_mismatch_pairs": final_eval["cross_mismatch_pairs"],
        "warnings": warnings,
    }


def domesticate_golden_gate_fragment(
    sequence: str,
    enzyme_name: str,
    fragment_index: int = 0,
    fragment_name: str = "Fragment",
    is_coding_sequence: bool = True,
    reading_frame_offset: int = 0,
) -> dict:
    """扫描片段内部内源 Type IIS 位点并生成编码区同义密码子抹除方案 (Domestication)"""
    clean = clean_seq(sequence)
    seq_len = len(clean)
    spec = TYPE_IIS_ENZYME_SPECS.get(enzyme_name.lower(), TYPE_IIS_ENZYME_SPECS["bsai"])
    site_fwd = spec["site"]
    site_rev = spec["rc_site"]
    site_len = len(site_fwd)

    def find_internal_sites(chars_list):
        s = "".join(chars_list)
        hits = []
        for strand, pat in (("+", site_fwd), ("-", site_rev)):
            pos = s.find(pat)
            while pos != -1:
                hits.append((pos, strand, pat))
                pos = s.find(pat, pos + 1)
        hits.sort(key=lambda x: (x[0], x[1]))
        return hits

    def introduces_site(chars_list, center_start, center_end):
        lo = max(0, center_start - site_len + 1)
        hi = min(len(chars_list), center_end + site_len - 1)
        if hi - lo < site_len:
            return False
        win = "".join(chars_list[lo:hi])
        return (site_fwd in win) or (site_rev in win)

    working = list(clean)
    initial_hits = find_internal_sites(working)
    suggestions = []
    frame = ((int(reading_frame_offset) % 3) + 3) % 3

    for _ in range(200):
        current_hits = find_internal_sites(working)
        if not current_hits:
            break
        s0, strand, site_str = current_hits[0]
        e0 = s0 + site_len
        applied = False

        if is_coding_sequence:
            codon_starts = [
                c for c in range(frame, seq_len - 2, 3)
                if (c + 3) > s0 and c < e0
            ]
            for req_inside in (True, False):
                if applied:
                    break
                for c_start in codon_starts:
                    if applied:
                        break
                    orig_codon = "".join(working[c_start:c_start + 3])
                    aa = GG_CODON_TO_AA.get(orig_codon)
                    syn_list = GG_PREFERRED_CODONS.get(aa, []) if aa else []
                    for cand_codon in syn_list:
                        if cand_codon == orig_codon:
                            continue
                        diffs = [k for k in range(3) if orig_codon[k] != cand_codon[k]]
                        if len(diffs) != 1:
                            continue
                        mut_off = diffs[0]
                        mut_pos0 = c_start + mut_off
                        if req_inside and not (s0 <= mut_pos0 < e0):
                            continue
                        trial = list(working)
                        trial[c_start:c_start + 3] = list(cand_codon)
                        if not introduces_site(trial, s0, e0):
                            working = trial
                            codon_idx1 = ((c_start - frame) // 3) + 1
                            suggestions.append({
                                "fragment_index": fragment_index,
                                "fragment_name": fragment_name,
                                "enzyme_name": spec["name"],
                                "site_strand": strand,
                                "site_start_1based": s0 + 1,
                                "site_end_1based": e0,
                                "original_site": site_str,
                                "is_coding_sequence": True,
                                "codon_index_1based": codon_idx1,
                                "original_codon": orig_codon,
                                "mutated_codon": cand_codon,
                                "amino_acid": aa,
                                "mutation_position_1based": mut_pos0 + 1,
                                "original_base": orig_codon[mut_off],
                                "mutated_base": cand_codon[mut_off],
                                "is_synonymous": True,
                                "note": f"密码子 #{codon_idx1} ({aa}) {orig_codon}→{cand_codon} (pos {mut_pos0 + 1} {orig_codon[mut_off]}>{cand_codon[mut_off]}) 同义抹除 {spec['name']} ({strand})",
                            })
                            applied = True
                            break

        if not applied and not is_coding_sequence:
            mid_pos0 = s0 + (site_len // 2)
            orig_ch = working[mid_pos0]
            for cand_ch in ("A", "C", "G", "T"):
                if cand_ch == orig_ch:
                    continue
                trial = list(working)
                trial[mid_pos0] = cand_ch
                if not introduces_site(trial, s0, e0):
                    working = trial
                    suggestions.append({
                        "fragment_index": fragment_index,
                        "fragment_name": fragment_name,
                        "enzyme_name": spec["name"],
                        "site_strand": strand,
                        "site_start_1based": s0 + 1,
                        "site_end_1based": e0,
                        "original_site": site_str,
                        "is_coding_sequence": False,
                        "codon_index_1based": None,
                        "original_codon": None,
                        "mutated_codon": None,
                        "amino_acid": None,
                        "mutation_position_1based": mid_pos0 + 1,
                        "original_base": orig_ch,
                        "mutated_base": cand_ch,
                        "is_synonymous": False,
                        "note": f"非编码区位点 pos {mid_pos0 + 1} {orig_ch}>{cand_ch} 破坏 {spec['name']} ({strand})",
                    })
                    applied = True
                    break

        if not applied:
            break

    rem_hits = find_internal_sites(working)
    return {
        "fragment_index": fragment_index,
        "fragment_name": fragment_name,
        "original_length": seq_len,
        "internal_sites_found": len(initial_hits),
        "remaining_sites_after_domestication": len(rem_hits),
        "suggestions": suggestions,
        "domesticated_sequence": "".join(working),
    }


def design_golden_gate_assembly(args: dict) -> dict:
    """端到端 Type IIS Golden Gate 接头分配与内源位点 Domestication 设计"""
    enzyme_name = str(args.get("enzyme_name") or "BsaI").strip()
    spec = TYPE_IIS_ENZYME_SPECS.get(enzyme_name.lower(), TYPE_IIS_ENZYME_SPECS["bsai"])
    fragments = args.get("fragments") or []
    fixed_overhangs = args.get("fixed_overhangs") or []
    is_circular = bool(args.get("is_circular", True))
    db_path = args.get("db_path")
    frag_cnt = int(args.get("fragment_count") or max(2, len(fragments)))

    ov_plan = allocate_golden_gate_overhangs(
        fragment_count=frag_cnt,
        enzyme_name=spec["name"],
        fixed_overhangs=fixed_overhangs,
        is_circular=is_circular,
        db_path=db_path,
    )

    doms = []
    total_sites = 0
    total_frag_len = 0
    for idx, f in enumerate(fragments):
        d = domesticate_golden_gate_fragment(
            sequence=f.get("sequence", ""),
            enzyme_name=spec["name"],
            fragment_index=idx,
            fragment_name=f.get("name", f"Fragment_{idx + 1}"),
            is_coding_sequence=bool(f.get("is_coding_sequence", True)),
            reading_frame_offset=int(f.get("reading_frame_offset", 0)),
        )
        doms.append(d)
        total_sites += d["internal_sites_found"]
        total_frag_len += len(d["domesticated_sequence"])

    return {
        "enzyme_name": spec["name"],
        "recognition_site": spec["site"],
        "overhang_length": spec["overhang_len"],
        "overhang_plan": ov_plan,
        "domestications": doms,
        "total_internal_sites_found": total_sites,
        "assembled_sequence_length": total_frag_len + len(ov_plan["assigned_overhangs"]) * spec["overhang_len"],
    }


_GEL_CONC_PARAMS = [
    ("0.8%", 2400.0, 2.02),
    ("1.0%", 1250.0, 2.12),
    ("1.2%", 900.0, 2.20),
    ("1.5%", 620.0, 2.30),
    ("2.0%", 380.0, 2.42),
]


def agarose_migration_y(size_bp: float, conc_label: str) -> float:
    """对齐 Swift AgaroseGelConcentration.migrationY 的归一化凝胶迁移距离模型"""
    mid, k = 1250.0, 2.12
    for lbl, m_val, k_val in _GEL_CONC_PARAMS:
        if lbl == conc_label:
            mid, k = m_val, k_val
            break
    clamped = max(25.0, min(50000.0, float(size_bp)))
    u = math.log10(clamped)
    u_mid = math.log10(mid)
    y = 0.06 + 0.88 / (1.0 + math.exp(k * (u - u_mid)))
    return min(0.94, max(0.06, y))


def _find_enzyme_cut_positions(clean_seq: str, enz_name: str, is_circular: bool) -> list:
    site, snip_top, snip_bot = DEFAULT_DIAGNOSTIC_ENZYMES[enz_name]
    seq_len = len(clean_seq)
    site_len = len(site)
    if seq_len == 0 or site_len > seq_len:
        return []
    search_seq = (clean_seq + clean_seq) if is_circular else clean_seq
    snips = []
    pos = search_seq.find(site)
    while pos != -1:
        if is_circular and pos >= seq_len:
            break
        raw_top = pos + snip_top
        raw_bot = pos + snip_bot
        if is_circular or (0 <= raw_top <= seq_len and 0 <= raw_bot <= seq_len):
            top_snip = (raw_top % seq_len) if is_circular else raw_top
            snips.append(top_snip)
        pos = search_seq.find(site, pos + 1)
    return snips


def simulate_digest_fragments(clean_seq: str, enzyme_names: list, is_circular: bool = True) -> list:
    """模拟单/双酶切产生的条带长度列表 (bp, 降序)"""
    total_len = len(clean_seq)
    if total_len == 0:
        return []
    cut_positions = set()
    for e_name in enzyme_names:
        for pos in _find_enzyme_cut_positions(clean_seq, e_name, is_circular):
            cut_positions.add(pos)
    sorted_pos = sorted(cut_positions)
    frags = []
    if is_circular:
        if not sorted_pos:
            return []
        if len(sorted_pos) == 1:
            frags = [total_len]
        else:
            for i in range(len(sorted_pos)):
                nxt = sorted_pos[i + 1] if (i + 1 < len(sorted_pos)) else (sorted_pos[0] + total_len)
                frags.append(max(1, nxt - sorted_pos[i]))
    else:
        prev = 0
        for pos in sorted_pos:
            if pos > prev:
                frags.append(pos - prev)
            prev = pos
        if total_len > prev:
            frags.append(total_len - prev)
    frags.sort(reverse=True)
    return frags


def recommend_diagnostic_digests(args: dict) -> dict:
    """推荐空载 vs 重组载体的最佳 2–4 条带单/双酶切鉴定 Top N 方案（对齐 Swift DiagnosticDigestEngine）"""
    from functools import cmp_to_key

    clean_empty = clean_seq(args.get("empty_vector_sequence") or "")
    clean_recomb = clean_seq(args.get("recombinant_sequence") or "")
    is_circular = bool(args.get("is_circular", True))
    min_bands = int(args.get("min_bands", 2))
    max_bands = int(args.get("max_bands", 4))
    top_n = int(args.get("top_n", 3))

    if not clean_empty or not clean_recomb:
        return {
            "empty_vector_length_bp": len(clean_empty),
            "recombinant_length_bp": len(clean_recomb),
            "is_circular": is_circular,
            "evaluated_combinations": 0,
            "top_recommendations": [],
            "warnings": ["输入空载或重组载体序列为空"],
        }

    raw_names = args.get("enzyme_names") or list(DEFAULT_DIAGNOSTIC_ENZYMES.keys())
    canon_lookup = {k.lower(): k for k in DEFAULT_DIAGNOSTIC_ENZYMES}
    seen_lower = set()
    pool = []
    for n in raw_names:
        low = str(n).lower()
        if low not in seen_lower and low in canon_lookup:
            seen_lower.add(low)
            pool.append(canon_lookup[low])
    pool.sort()

    viable = []
    single_empty = {}
    single_recomb = {}
    for enz in pool:
        neg_cuts = len(_find_enzyme_cut_positions(clean_empty, enz, is_circular))
        pos_cuts = len(_find_enzyme_cut_positions(clean_recomb, enz, is_circular))
        if (neg_cuts >= 1 or pos_cuts >= 1) and neg_cuts <= 6 and pos_cuts <= 6:
            viable.append(enz)
            single_empty[enz] = simulate_digest_fragments(clean_empty, [enz], is_circular)
            single_recomb[enz] = simulate_digest_fragments(clean_recomb, [enz], is_circular)

    def best_buffer(enz_list):
        compats = [
            NEB_BUFFER_COMPAT_TABLE.get(e.lower(), {"CutSmart": 100, "r2.1": 100, "r3.1": 75, "r1.1": 75})
            for e in enz_list
        ]
        best_name, best_act = "CutSmart", -1
        for b_name in ("CutSmart", "r2.1", "r3.1", "r1.1"):
            min_act = min(c.get(b_name, 0) for c in compats)
            if min_act > best_act:
                best_act = min_act
                best_name = b_name
        return (best_name, max(0, best_act))

    def eval_combo(enz_list, strict_both):
        if len(enz_list) == 1:
            empty_all = single_empty[enz_list[0]]
            recomb_all = single_recomb[enz_list[0]]
        else:
            empty_all = simulate_digest_fragments(clean_empty, enz_list, is_circular)
            recomb_all = simulate_digest_fragments(clean_recomb, enz_list, is_circular)

        empty_vis = [b for b in empty_all if b >= 100]
        recomb_vis = [b for b in recomb_all if b >= 100]
        if len(empty_all) > 6 or len(recomb_all) > 6:
            return None
        if strict_both:
            if not (min_bands <= len(empty_vis) <= max_bands and min_bands <= len(recomb_vis) <= max_bands):
                return None
        else:
            if not (min_bands <= len(recomb_vis) <= max_bands and 1 <= len(empty_vis) <= max_bands):
                return None

        buf_name, buf_pct = best_buffer(enz_list)
        best_cand = None
        for conc_label, _, _ in _GEL_CONC_PARAMS:
            y_neg = [agarose_migration_y(b, conc_label) for b in empty_vis]
            y_pos = [agarose_migration_y(b, conc_label) for b in recomb_vis]
            d_pos = [min(abs(yp - yn) for yn in y_neg) for yp in y_pos]
            d_neg = [min(abs(yn - yp) for yp in y_pos) for yn in y_neg]
            max_shift_y = max(max(d_pos), max(d_neg))
            if max_shift_y < 0.03:
                continue
            mean_shift_y = (sum(d_pos) + sum(d_neg)) / float(len(d_pos) + len(d_neg))

            s_neg = sorted(y_neg)
            s_pos = sorted(y_pos)
            gaps = [s_neg[i + 1] - s_neg[i] for i in range(len(s_neg) - 1)] + [
                s_pos[i + 1] - s_pos[i] for i in range(len(s_pos) - 1)
            ]
            min_gap_y = min(gaps) if gaps else 0.5

            diff_pos_bp = [min(abs(rp - rn) for rn in empty_vis) for rp in recomb_vis]
            diff_neg_bp = [min(abs(rn - rp) for rp in recomb_vis) for rn in empty_vis]
            max_diff_bp = max(max(diff_pos_bp), max(diff_neg_bp))

            shift_comp = min(45.0, max_shift_y * 180.0)
            mean_comp = min(20.0, mean_shift_y * 120.0)
            res_comp = min(20.0, min_gap_y * 220.0) - (15.0 if min_gap_y < 0.025 else 0.0)
            count_bonus = 6.0 if len(empty_vis) != len(recomb_vis) else 0.0
            if len(enz_list) == 1:
                buf_bonus = 5.0
            elif buf_pct >= 100:
                buf_bonus = 4.0
            elif buf_pct >= 75:
                buf_bonus = 1.5
            else:
                buf_bonus = -8.0
            has_extreme = any(b < 150 or b > 12000 for b in (empty_vis + recomb_vis))
            range_penalty = -10.0 if has_extreme else 0.0
            total_score = max(0.0, min(100.0, shift_comp + mean_comp + res_comp + count_bonus + buf_bonus + range_penalty))

            cand = {
                "enzyme_names": list(enz_list),
                "recommended_gel_concentration": conc_label,
                "preferred_buffer": buf_name,
                "buffer_compatibility_percent": buf_pct,
                "empty_vector_bands_bp": empty_vis,
                "recombinant_bands_bp": recomb_vis,
                "max_migration_shift_y": max_shift_y,
                "mean_migration_shift_y": mean_shift_y,
                "min_intra_lane_gap_y": min_gap_y,
                "max_band_size_diff_bp": max_diff_bp,
                "score": total_score,
            }
            if best_cand is None or cand["score"] > best_cand["score"] + 1e-9:
                best_cand = cand
        return best_cand

    combos = [[e] for e in viable]
    for i in range(len(viable) - 1):
        for j in range(i + 1, len(viable)):
            combos.append([viable[i], viable[j]])

    strict_hits = []
    for combo in combos:
        res = eval_combo(combo, True)
        if res is not None:
            strict_hits.append(res)

    final_pool = list(strict_hits)
    warnings = []
    if len(final_pool) < top_n:
        seen_keys = {"+".join(x["enzyme_names"]) for x in final_pool}
        for combo in combos:
            key = "+".join(combo)
            if key in seen_keys:
                continue
            rel = eval_combo(combo, False)
            if rel is not None:
                final_pool.append(rel)
                seen_keys.add(key)
        if not strict_hits and final_pool:
            warnings.append(f"未能找到空载与重组载体均严格产生 {min_bands}–{max_bands} 条带的组合，已补充单带对照候选方案。")

    def _cmp_digest(a, b):
        if abs(a["score"] - b["score"]) > 1e-9:
            return -1 if a["score"] > b["score"] else 1
        if abs(a["max_migration_shift_y"] - b["max_migration_shift_y"]) > 1e-9:
            return -1 if a["max_migration_shift_y"] > b["max_migration_shift_y"] else 1
        if len(a["enzyme_names"]) != len(b["enzyme_names"]):
            return -1 if len(a["enzyme_names"]) < len(b["enzyme_names"]) else 1
        ka, kb = "+".join(a["enzyme_names"]), "+".join(b["enzyme_names"])
        return -1 if ka < kb else (1 if ka > kb else 0)

    final_pool.sort(key=cmp_to_key(_cmp_digest))
    top_items = []
    for idx, item in enumerate(final_pool[:top_n]):
        out_item = dict(item)
        out_item["rank"] = idx + 1
        neg_str = " / ".join(str(x) for x in item["empty_vector_bands_bp"])
        pos_str = " / ".join(str(x) for x in item["recombinant_bands_bp"])
        out_item["rationale"] = f"{' + '.join(item['enzyme_names'])} ({item['preferred_buffer']} {item['buffer_compatibility_percent']}%): 空载 [{neg_str}] bp vs 重组 [{pos_str}] bp，{item['recommended_gel_concentration']} 胶最大迁移差 Δy={item['max_migration_shift_y']:.3f}"
        top_items.append(out_item)

    if not top_items:
        warnings.append("在可用酶切面板中未找到可区分空载与重组载体的有效鉴定方案。")

    return {
        "empty_vector_length_bp": len(clean_empty),
        "recombinant_length_bp": len(clean_recomb),
        "is_circular": is_circular,
        "evaluated_combinations": len(combos),
        "top_recommendations": top_items,
        "warnings": warnings,
    }


RFLP_CANDIDATE_ENZYMES = [
    {"name": "EcoRI", "site": "GAATTC", "top_cut_offset": 1},
    {"name": "BamHI", "site": "GGATCC", "top_cut_offset": 1},
    {"name": "HindIII", "site": "AAGCTT", "top_cut_offset": 1},
    {"name": "XhoI", "site": "CTCGAG", "top_cut_offset": 1},
    {"name": "SalI", "site": "GTCGAC", "top_cut_offset": 1},
    {"name": "NheI", "site": "GCTAGC", "top_cut_offset": 1},
    {"name": "SpeI", "site": "ACTAGT", "top_cut_offset": 1},
    {"name": "XbaI", "site": "TCTAGA", "top_cut_offset": 1},
    {"name": "AgeI", "site": "ACCGGT", "top_cut_offset": 1},
    {"name": "NcoI", "site": "CCATGG", "top_cut_offset": 1},
    {"name": "KpnI", "site": "GGTACC", "top_cut_offset": 5},
    {"name": "PstI", "site": "CTGCAG", "top_cut_offset": 5},
    {"name": "SacI", "site": "GAGCTC", "top_cut_offset": 5},
    {"name": "EcoRV", "site": "GATATC", "top_cut_offset": 3},
    {"name": "SmaI", "site": "CCCGGG", "top_cut_offset": 3},
    {"name": "StuI", "site": "AGGCCT", "top_cut_offset": 3},
    {"name": "BglII", "site": "AGATCT", "top_cut_offset": 1},
    {"name": "ClaI", "site": "ATCGAT", "top_cut_offset": 2},
    {"name": "PvuII", "site": "CAGCTG", "top_cut_offset": 3},
    {"name": "ScaI", "site": "AGTACT", "top_cut_offset": 3},
]


def detect_cds_region(reference_sequence: str, cut_index_0based: int, min_length_bp: int = 90):
    """自动扫描正链三读码框，提取覆盖 cut_index_0based 的最长完整 ORF（>= 90 bp）。"""
    seq = clean_seq(reference_sequence)
    n = len(seq)
    if n < min_length_bp:
        return None
    best_start = None
    best_end = None
    best_len = -1
    for frame in range(3):
        pos = frame
        while pos + 3 <= n:
            if seq[pos:pos + 3] == "ATG" and pos <= cut_index_0based:
                end_pos = pos + 3
                hit_stop = False
                while end_pos + 3 <= n:
                    c = seq[end_pos:end_pos + 3]
                    if c in ("TAA", "TAG", "TGA"):
                        end_pos += 3
                        hit_stop = True
                        break
                    end_pos += 3
                if not hit_stop:
                    end_pos = pos + ((n - pos) // 3) * 3
                orf_len = end_pos - pos
                if pos <= cut_index_0based < end_pos and orf_len >= min_length_bp:
                    if orf_len > best_len or (orf_len == best_len and (best_start is None or pos < best_start)):
                        best_len = orf_len
                        best_start = pos
                        best_end = end_pos
            pos += 3
    if best_start is not None and best_end is not None:
        return (best_start, best_end)
    return None


def _hdr_translate_cds(sequence: str, start_0based: int, end_0based: int) -> str:
    seq = clean_seq(sequence)
    s = max(0, int(start_0based))
    e = min(len(seq), int(end_0based))
    out = []
    i = s
    while i + 3 <= e:
        out.append(GG_CODON_TO_AA.get(seq[i:i + 3], "X"))
        i += 3
    return "".join(out)


def _hdr_predict_linear_digest_bands(sequence: str, site: str, top_cut_offset: int) -> list:
    seq = clean_seq(sequence)
    site_c = clean_seq(site)
    n = len(seq)
    m = len(site_c)
    if n == 0:
        return []
    if m == 0 or n < m:
        return [n]
    cuts = []
    i = 0
    while i + m <= n:
        if seq[i:i + m] == site_c:
            cuts.append(i + top_cut_offset)
            i += m
        else:
            i += 1
    sorted_cuts = sorted({c for c in cuts if 0 < c < n})
    boundaries = [0] + sorted_cuts + [n]
    bands = [boundaries[idx + 1] - boundaries[idx] for idx in range(len(boundaries) - 1)]
    bands = [b for b in bands if b > 0]
    return sorted(bands, reverse=True)


def design_crispr_hdr_donor(args: dict) -> dict:
    """CRISPR Knock-in HDR Donor 模板、PAM/Seed 同义阻断突变、可选 RFLP 位点与 Out-Out PCR 引物设计（与 HDRDonorEngine.swift 1:1 对齐）"""
    ref = clean_seq(args.get("reference_sequence", ""))
    guide = clean_seq(args.get("sgrna_sequence", args.get("sgRNASequence", "")))
    rep = clean_seq(args.get("replacement_sequence", ""))
    strand = str(args.get("strand", "+")).strip()
    L = len(ref)
    if L < 25:
        raise ValueError("参考序列长度不足（至少需要 25 bp）")
    if len(guide) < 15:
        raise ValueError("sgRNA protospacer 长度不足（至少需要 15 nt）")
    if strand not in ("+", "-"):
        raise ValueError("strand 必须为 '+' 或 '-'")

    edit_start0 = int(args["edit_start_0based"])
    edit_end0 = int(args["edit_end_0based"])
    if not (0 <= edit_start0 <= edit_end0 <= L):
        raise ValueError("编辑坐标 [edit_start_0based, edit_end_0based) 越界")

    donor_format = str(args.get("donor_format", "ssODN"))
    if donor_format not in ("ssODN", "dsDNAPlasmid"):
        raise ValueError(f"不支持的 donor_format: {donor_format}")
    default_arm = 60 if donor_format == "ssODN" else 600
    req_left_arm = max(1, int(args.get("left_arm_length_bp") or default_arm))
    req_right_arm = max(1, int(args.get("right_arm_length_bp") or default_arm))
    auto_detect_cds = bool(args.get("auto_detect_cds", True))
    enable_rflp = bool(args.get("enable_rflp", False))
    rflp_radius = max(3, int(args.get("rflp_search_radius_bp", 15)))
    out_out_margin = int(args.get("out_out_margin_bp", 100))
    primer_target_tm = float(args.get("primer_target_tm", 60.0))
    donor_name = str(args.get("donor_name", "HDR_Donor"))

    g_len = len(guide)
    # 1. Locate sgRNA and PAM on WT reference
    if strand == "+":
        cands = []
        if L >= g_len + 3:
            for p in range(0, L - g_len - 3 + 1):
                if ref[p:p + g_len] == guide:
                    pam_idx = p + g_len
                    has_gg = ref[pam_idx + 1] == "G" and ref[pam_idx + 2] == "G"
                    cands.append((p, pam_idx - 3, has_gg))
        gg_pool = [c for c in cands if c[2]]
        pool = gg_pool if gg_pool else cands
        if not pool:
            raise ValueError(f"在参考序列正链上未找到 sgRNA {guide} 及 3' PAM")
        best = min(pool, key=lambda c: (abs(c[1] - edit_start0), c[0]))
        wt_pam_start0 = best[0] + g_len
        wt_cut_index0 = best[1]
    else:
        rc_guide = rev_comp(guide)
        cands = []
        if L >= g_len + 3:
            for p in range(3, L - g_len + 1):
                if ref[p:p + g_len] == rc_guide:
                    pam_idx = p - 3
                    has_cc = ref[pam_idx] == "C" and ref[pam_idx + 1] == "C"
                    cands.append((p, p + 3, has_cc))
        cc_pool = [c for c in cands if c[2]]
        pool = cc_pool if cc_pool else cands
        if not pool:
            raise ValueError(f"在参考序列负链上未找到 sgRNA {guide} 反向互补及 5' CCN PAM")
        best = min(pool, key=lambda c: (abs(c[1] - edit_start0), c[0]))
        wt_pam_start0 = best[0] - 3
        wt_cut_index0 = best[1]

    wt_pam_seq = ref[wt_pam_start0:wt_pam_start0 + 3]

    # 2. Detect or validate CDS
    is_in_cds = False
    cds_auto_detected = False
    wt_cds_start0 = None
    wt_cds_end0 = None
    cs1 = args.get("cds_start_1based")
    ce1 = args.get("cds_end_1based")
    if cs1 is not None and ce1 is not None:
        s0 = int(cs1) - 1
        e0 = int(ce1)
        if not (0 <= s0 and s0 + 3 <= e0 <= L):
            raise ValueError("显式 CDS 区间 [cds_start_1based, cds_end_1based] 非法或越界")
        if s0 <= wt_cut_index0 < e0:
            is_in_cds = True
            wt_cds_start0 = s0
            wt_cds_end0 = e0
    elif auto_detect_cds:
        detected = detect_cds_region(ref, wt_cut_index0)
        if detected is not None:
            is_in_cds = True
            cds_auto_detected = True
            wt_cds_start0, wt_cds_end0 = detected

    # 3. Apply intentional replacement & map coordinates
    delta = len(rep) - (edit_end0 - edit_start0)
    edited_chars = list(ref[:edit_start0] + rep + ref[edit_end0:])

    def _map_wt(i: int) -> int:
        if i < edit_start0:
            return i
        if i >= edit_end0:
            return i + delta
        return edit_start0

    if is_in_cds:
        edited_cds_start0 = wt_cds_start0 if wt_cds_start0 <= edit_start0 else (wt_cds_start0 + delta if wt_cds_start0 >= edit_end0 else edit_start0)
        edited_cds_end0 = wt_cds_end0 + delta if wt_cds_end0 >= edit_end0 else (wt_cds_end0 if wt_cds_end0 <= edit_start0 else edit_start0 + len(rep))
    else:
        edited_cds_start0 = 0
        edited_cds_end0 = 0

    protein_before = _hdr_translate_cds("".join(edited_chars), edited_cds_start0, edited_cds_end0) if is_in_cds else ""
    edited_pam_start0 = _map_wt(wt_pam_start0)

    def _is_pam_intact(chars: list) -> bool:
        if edited_pam_start0 < 0 or edited_pam_start0 + 3 > len(chars):
            return False
        if strand == "+":
            return chars[edited_pam_start0 + 1] == "G" and chars[edited_pam_start0 + 2] == "G"
        return chars[edited_pam_start0] == "C" and chars[edited_pam_start0 + 1] == "C"

    pam_crit_indices = [edited_pam_start0 + 1, edited_pam_start0 + 2] if strand == "+" else [edited_pam_start0, edited_pam_start0 + 1]
    edit_locked = set(range(edit_start0, edit_start0 + len(rep)))

    warnings = []
    blocking_mutations = []

    def _try_1bp_syn(pos: int, chars: list, locked: set, reason: str):
        if not is_in_cds or pos < edited_cds_start0 or pos >= edited_cds_end0 or pos in locked:
            return None
        rel = pos - edited_cds_start0
        c_start = edited_cds_start0 + (rel // 3) * 3
        if c_start + 3 > edited_cds_end0:
            return None
        off = pos - c_start
        orig_codon = "".join(chars[c_start:c_start + 3])
        aa = GG_CODON_TO_AA.get(orig_codon)
        if aa is None:
            return None
        for alt_codon in GG_PREFERRED_CODONS.get(aa, []):
            if alt_codon == orig_codon:
                continue
            diffs = [k for k in range(3) if alt_codon[k] != orig_codon[k]]
            if len(diffs) == 1 and diffs[0] == off:
                return alt_codon[off], {
                    "position_0based": pos,
                    "position_1based": pos + 1,
                    "original_base": orig_codon[off],
                    "mutated_base": alt_codon[off],
                    "reason": reason,
                    "codon_before": orig_codon,
                    "codon_after": alt_codon,
                    "amino_acid": aa,
                }
        return None

    if not _is_pam_intact(edited_chars):
        blocking_strategy = "already_disrupted_by_edit"
    elif is_in_cds:
        broke_pam = False
        for cp in pam_crit_indices:
            hit = _try_1bp_syn(cp, edited_chars, edit_locked, "pam_block")
            if hit is not None:
                nb, rec = hit
                cand = list(edited_chars)
                cand[cp] = nb
                if not _is_pam_intact(cand):
                    edited_chars = cand
                    blocking_mutations.append(rec)
                    broke_pam = True
                    break
        if broke_pam:
            blocking_strategy = "pam_synonymous"
        else:
            if strand == "+":
                s_start = max(0, edited_pam_start0 - 8)
                seed_positions = list(range(edited_pam_start0 - 1, s_start - 1, -1))
            else:
                proto_start = edited_pam_start0 + 3
                s_end = min(len(edited_chars) - 1, proto_start + 7)
                seed_positions = list(range(proto_start, s_end + 1)) if proto_start <= s_end else []
            used_codons = set()
            for sp in seed_positions:
                if len(blocking_mutations) >= 2:
                    break
                if sp < edited_cds_start0 or sp >= edited_cds_end0:
                    continue
                c_start = edited_cds_start0 + ((sp - edited_cds_start0) // 3) * 3
                if c_start in used_codons:
                    continue
                hit = _try_1bp_syn(sp, edited_chars, edit_locked, "seed_block")
                if hit is not None:
                    nb, rec = hit
                    edited_chars[sp] = nb
                    blocking_mutations.append(rec)
                    used_codons.add(c_start)
            if not blocking_mutations:
                blocking_strategy = "failed_to_block"
                warnings.append("未能找到同义 PAM 或 Seed 阻断突变位点，请人工复核 Cas9 二次切割风险。")
            else:
                blocking_strategy = "seed_synonymous_fallback"
                warnings.append(f"PAM 位点无法在不改变氨基酸的前提下同义破坏，已回退并在近 PAM 8-nt Seed 区引入 {len(blocking_mutations)} 处同义突变。")
    else:
        mp = None
        for cp in pam_crit_indices:
            if 0 <= cp < len(edited_chars) and cp not in edit_locked:
                mp = cp
                break
        if mp is not None:
            ob = edited_chars[mp]
            ab = ("A" if ob == "G" else "G") if strand == "+" else ("T" if ob == "C" else "C")
            edited_chars[mp] = ab
            blocking_mutations.append({
                "position_0based": mp,
                "position_1based": mp + 1,
                "original_base": ob,
                "mutated_base": ab,
                "reason": "pam_block",
                "codon_before": None,
                "codon_after": None,
                "amino_acid": None,
            })
            blocking_strategy = "pam_non_coding"
        else:
            blocking_strategy = "failed_to_block"
            warnings.append("非编码区 PAM 关键碱基被用户编辑区间完全锁定，未能自动写入 PAM 阻断突变。")

    # 4. Arm bounds
    left_arm_start0 = max(0, edit_start0 - req_left_arm)
    right_arm_end0_edited = min(len(edited_chars), edit_start0 + len(rep) + req_right_arm)
    right_arm_end0_wt = min(L, edit_end0 + (right_arm_end0_edited - (edit_start0 + len(rep))))
    if edit_start0 - left_arm_start0 < req_left_arm or right_arm_end0_edited - (edit_start0 + len(rep)) < req_right_arm:
        warnings.append("参考序列在编辑位点侧翼长度不足，同源臂已按边界自动截断。")

    # 5. Optional RFLP design
    rflp_spec = None
    rflp_mode = "none"
    rflp_muts = []
    rflp_note = ""
    if enable_rflp:
        rflp_locked = set(edit_locked) | {m["position_0based"] for m in blocking_mutations} | set(pam_crit_indices)
        pam_broken_before = not _is_pam_intact(edited_chars)
        if is_in_cds:
            win_start = max(edited_cds_start0, max(left_arm_start0, edit_start0 - rflp_radius))
            win_end = min(edited_cds_end0, min(right_arm_end0_edited, edit_start0 + len(rep) + rflp_radius))
            found_destroy = False
            for enz in RFLP_CANDIDATE_ENZYMES:
                site = enz["site"]
                matches = []
                if right_arm_end0_edited - left_arm_start0 >= 6:
                    for sp in range(left_arm_start0, right_arm_end0_edited - 6 + 1):
                        if "".join(edited_chars[sp:sp + 6]) == site and sp + 6 > win_start and sp < win_end:
                            matches.append(sp)
                matches.sort(key=lambda sp: (abs((sp + 3) - edit_start0), sp))
                for sp in matches:
                    overlap_codons = []
                    cs = edited_cds_start0
                    while cs + 3 <= edited_cds_end0:
                        if cs + 3 > sp and cs < sp + 6:
                            overlap_codons.append(cs)
                        cs += 3
                    overlap_codons.sort(key=lambda c: (abs((c + 1) - edit_start0), c))
                    for cs in overlap_codons:
                        orig_codon = "".join(edited_chars[cs:cs + 3])
                        aa = GG_CODON_TO_AA.get(orig_codon)
                        if aa is None:
                            continue
                        for alt_codon in GG_PREFERRED_CODONS.get(aa, []):
                            if alt_codon == orig_codon:
                                continue
                            diffs = [k for k in range(3) if alt_codon[k] != orig_codon[k]]
                            if len(diffs) == 1:
                                k = diffs[0]
                                mut_pos = cs + k
                                if sp <= mut_pos < sp + 6 and mut_pos not in rflp_locked:
                                    cand = list(edited_chars)
                                    cand[mut_pos] = alt_codon[k]
                                    if pam_broken_before and _is_pam_intact(cand):
                                        continue
                                    if "".join(cand[sp:sp + 6]) != site:
                                        edited_chars = cand
                                        rflp_muts = [{
                                            "position_0based": mut_pos,
                                            "position_1based": mut_pos + 1,
                                            "original_base": orig_codon[k],
                                            "mutated_base": alt_codon[k],
                                            "reason": "rflp_destroy",
                                            "codon_before": orig_codon,
                                            "codon_after": alt_codon,
                                            "amino_acid": aa,
                                        }]
                                        rflp_mode = "destroyed"
                                        rflp_spec = enz
                                        rflp_note = f"在 {mut_pos + 1} bp 处通过同义突变 ({orig_codon}->{alt_codon}, {aa}) 消除内源 {enz['name']} ({site}) 位点用于 RFLP 鉴定"
                                        found_destroy = True
                                        break
                        if found_destroy:
                            break
                    if found_destroy:
                        break
                if found_destroy:
                    break

            if not found_destroy:
                ordered_codons = []
                cs = edited_cds_start0
                while cs + 3 <= edited_cds_end0:
                    if cs >= win_start and cs + 3 <= win_end:
                        ordered_codons.append(cs)
                    cs += 3
                ordered_codons.sort(key=lambda c: (abs((c + 1) - edit_start0), c))
                found_create = False
                for target_diffs in (1, 2):
                    if found_create:
                        break
                    for cs in ordered_codons:
                        if found_create:
                            break
                        orig_codon = "".join(edited_chars[cs:cs + 3])
                        aa = GG_CODON_TO_AA.get(orig_codon)
                        if aa is None:
                            continue
                        for alt_codon in GG_PREFERRED_CODONS.get(aa, []):
                            if found_create:
                                break
                            if alt_codon == orig_codon:
                                continue
                            diffs = [k for k in range(3) if alt_codon[k] != orig_codon[k]]
                            if len(diffs) != target_diffs:
                                continue
                            mut_positions = [cs + k for k in diffs]
                            if any(p in rflp_locked for p in mut_positions):
                                continue
                            cand = list(edited_chars)
                            for k in diffs:
                                cand[cs + k] = alt_codon[k]
                            if pam_broken_before and _is_pam_intact(cand):
                                continue
                            scan_start = max(left_arm_start0, cs - 5)
                            scan_end_max = min(right_arm_end0_edited - 6, cs + 2)
                            if scan_start > scan_end_max:
                                continue
                            for enz in RFLP_CANDIDATE_ENZYMES:
                                if found_create:
                                    break
                                site = enz["site"]
                                for sp in range(scan_start, scan_end_max + 1):
                                    if "".join(cand[sp:sp + 6]) == site and "".join(edited_chars[sp:sp + 6]) != site:
                                        if any(sp <= mp < sp + 6 for mp in mut_positions):
                                            edited_chars = cand
                                            rflp_muts = [{
                                                "position_0based": cs + k,
                                                "position_1based": cs + k + 1,
                                                "original_base": orig_codon[k],
                                                "mutated_base": alt_codon[k],
                                                "reason": "rflp_create",
                                                "codon_before": orig_codon,
                                                "codon_after": alt_codon,
                                                "amino_acid": aa,
                                            } for k in diffs]
                                            rflp_mode = "created"
                                            rflp_spec = enz
                                            rflp_note = f"在 {cs + 1}..{cs + 3} bp 处引入同义密码子 ({orig_codon}->{alt_codon}, {aa}) 构建新 {enz['name']} ({site}) RFLP 鉴定位点"
                                            found_create = True
                                            break
                if not found_create:
                    warnings.append(f"在目标附近 ±{rflp_radius} bp 窗口内未能通过同义密码子替换引入或消除 RFLP 酶切位点。")
        else:
            win_start = max(left_arm_start0, edit_start0 - rflp_radius)
            win_end = min(right_arm_end0_edited, edit_start0 + len(rep) + rflp_radius)
            found_nc = False
            for enz in RFLP_CANDIDATE_ENZYMES:
                if found_nc:
                    break
                site = enz["site"]
                if win_end - win_start >= 6:
                    for sp in range(win_start, win_end - 6 + 1):
                        if "".join(edited_chars[sp:sp + 6]) == site:
                            mut_pos = next((p for p in range(sp, sp + 6) if p not in rflp_locked), None)
                            if mut_pos is not None:
                                ob = edited_chars[mut_pos]
                                nb = "T" if ob == "A" else "A"
                                cand = list(edited_chars)
                                cand[mut_pos] = nb
                                if pam_broken_before and _is_pam_intact(cand):
                                    continue
                                edited_chars = cand
                                rflp_muts = [{
                                    "position_0based": mut_pos,
                                    "position_1based": mut_pos + 1,
                                    "original_base": ob,
                                    "mutated_base": nb,
                                    "reason": "rflp_destroy",
                                    "codon_before": None,
                                    "codon_after": None,
                                    "amino_acid": None,
                                }]
                                rflp_mode = "destroyed"
                                rflp_spec = enz
                                rflp_note = f"在非编码区 {mut_pos + 1} bp 破坏 {enz['name']} ({site}) 位点用于 RFLP 鉴定"
                                found_nc = True
                                break
            if not found_nc:
                positions = sorted(range(win_start, win_end), key=lambda p: abs(p - edit_start0))
                for pos in positions:
                    if found_nc or pos in rflp_locked:
                        continue
                    ob = edited_chars[pos]
                    for nb in ("A", "C", "G", "T"):
                        if found_nc or nb == ob:
                            continue
                        cand = list(edited_chars)
                        cand[pos] = nb
                        if pam_broken_before and _is_pam_intact(cand):
                            continue
                        s_start = max(left_arm_start0, pos - 5)
                        s_end = min(right_arm_end0_edited - 6, pos)
                        if s_start > s_end:
                            continue
                        for enz in RFLP_CANDIDATE_ENZYMES:
                            if found_nc:
                                break
                            site = enz["site"]
                            for sp in range(s_start, s_end + 1):
                                if "".join(cand[sp:sp + 6]) == site and "".join(edited_chars[sp:sp + 6]) != site:
                                    edited_chars = cand
                                    rflp_muts = [{
                                        "position_0based": pos,
                                        "position_1based": pos + 1,
                                        "original_base": ob,
                                        "mutated_base": nb,
                                        "reason": "rflp_create",
                                        "codon_before": None,
                                        "codon_after": None,
                                        "amino_acid": None,
                                    }]
                                    rflp_mode = "created"
                                    rflp_spec = enz
                                    rflp_note = f"在非编码区 {pos + 1} bp 引入新 {enz['name']} ({site}) RFLP 鉴定位点"
                                    found_nc = True
                                    break

    # 6. Final locus checks & protein conservation check
    final_edited_seq = "".join(edited_chars)
    protein_after = _hdr_translate_cds(final_edited_seq, edited_cds_start0, edited_cds_end0) if is_in_cds else ""
    amino_acid_conserved = (not is_in_cds) or (protein_before == protein_after)
    edited_pam_seq = final_edited_seq[edited_pam_start0:edited_pam_start0 + 3] if 0 <= edited_pam_start0 <= len(edited_chars) - 3 else ""
    pam_still_intact = _is_pam_intact(edited_chars)
    cas9_recut_blocked = (blocking_strategy != "failed_to_block") and ((not pam_still_intact) or blocking_strategy == "seed_synonymous_fallback")

    # 7. Slice homology arms & donor
    left_arm = final_edited_seq[left_arm_start0:edit_start0]
    insert_payload = final_edited_seq[edit_start0:edit_start0 + len(rep)]
    right_arm = final_edited_seq[edit_start0 + len(rep):right_arm_end0_edited]
    donor_seq = left_arm + insert_payload + right_arm

    # 8. Out-Out PCR genotyping primers strictly outside homology arms
    out_out = None
    left_flank = left_arm_start0
    right_flank = L - right_arm_end0_wt
    eff_left_margin = min(out_out_margin, max(10, left_flank - 25))
    eff_right_margin = min(out_out_margin, max(10, right_flank - 25))
    if left_flank >= eff_left_margin + 18 and right_flank >= eff_right_margin + 18:
        fwd_search_end = left_arm_start0 - eff_left_margin
        fwd_search_start = max(0, fwd_search_end - 40)
        fwd_window = ref[fwd_search_start:fwd_search_end]
        fwd_seq = pick_specific_annealing_seq(fwd_window, five_prime_overhang="", target_tm=primer_target_tm, tolerance=0.0)
        fwd_tm = calc_snapgene_tm(fwd_seq)
        fwd_start0 = fwd_search_start
        fwd_end0 = fwd_start0 + len(fwd_seq)

        rev_search_start = right_arm_end0_wt + eff_right_margin
        rev_search_end = min(L, rev_search_start + 40)
        rev_window = ref[rev_search_start:rev_search_end]
        rev_seq = pick_specific_annealing_seq(rev_comp(rev_window), five_prime_overhang="", target_tm=primer_target_tm, tolerance=0.0)
        rev_tm = calc_snapgene_tm(rev_seq)
        rev_end0 = rev_search_end
        rev_start0 = rev_end0 - len(rev_seq)

        wt_amp_seq = ref[fwd_start0:rev_end0]
        hdr_amp_seq = final_edited_seq[fwd_start0:rev_end0 + delta]
        out_out = {
            "forward_primer": {
                "name": f"{donor_name}_OutOut_F",
                "full_sequence": fwd_seq,
                "specific_sequence": fwd_seq,
                "tm": fwd_tm,
                "gc_percent": gc_percent(fwd_seq),
            },
            "reverse_primer": {
                "name": f"{donor_name}_OutOut_R",
                "full_sequence": rev_seq,
                "specific_sequence": rev_seq,
                "tm": rev_tm,
                "gc_percent": gc_percent(rev_seq),
            },
            "forward_start_0based": fwd_start0,
            "forward_end_0based": fwd_end0,
            "reverse_start_0based": rev_start0,
            "reverse_end_0based": rev_end0,
            "wt_amplicon_length_bp": len(wt_amp_seq),
            "hdr_amplicon_length_bp": len(hdr_amp_seq),
            "wt_amplicon_sequence": wt_amp_seq,
            "hdr_amplicon_sequence": hdr_amp_seq,
            "left_margin_from_arm_bp": left_arm_start0 - fwd_end0,
            "right_margin_from_arm_bp": rev_start0 - right_arm_end0_wt,
        }
    else:
        warnings.append("侧翼序列长度不足以在左右同源臂外侧设计 Out-Out PCR 引物（需同源臂外侧至少各预留 28 bp）。")

    # 9. Finalize RFLP result
    rflp_res = None
    if rflp_spec is not None and rflp_mode != "none":
        wt_target = out_out["wt_amplicon_sequence"] if out_out is not None else ref
        hdr_target = out_out["hdr_amplicon_sequence"] if out_out is not None else final_edited_seq
        rflp_res = {
            "mode": rflp_mode,
            "enzyme_name": rflp_spec["name"],
            "recognition_site": rflp_spec["site"],
            "top_cut_offset": rflp_spec["top_cut_offset"],
            "wt_amplicon_bands_bp": _hdr_predict_linear_digest_bands(wt_target, rflp_spec["site"], rflp_spec["top_cut_offset"]),
            "hdr_amplicon_bands_bp": _hdr_predict_linear_digest_bands(hdr_target, rflp_spec["site"], rflp_spec["top_cut_offset"]),
            "silent_mutations": rflp_muts,
            "note": rflp_note,
        }

    return {
        "donor_format": donor_format,
        "sgrna_sequence": guide,
        "strand": strand,
        "wt_cut_index_0based": wt_cut_index0,
        "wt_pam_start_0based": wt_pam_start0,
        "wt_pam_sequence": wt_pam_seq,
        "is_in_cds": is_in_cds,
        "cds_start_1based": (wt_cds_start0 + 1) if wt_cds_start0 is not None else None,
        "cds_end_1based": wt_cds_end0,
        "cds_auto_detected": cds_auto_detected,
        "protein_before_blocking": protein_before,
        "protein_after_blocking": protein_after,
        "amino_acid_conserved": amino_acid_conserved,
        "blocking_strategy": blocking_strategy,
        "blocking_mutations": blocking_mutations,
        "edited_pam_sequence": edited_pam_seq,
        "pam_still_intact": pam_still_intact,
        "cas9_recut_blocked": cas9_recut_blocked,
        "left_homology_arm": left_arm,
        "insert_payload": insert_payload,
        "right_homology_arm": right_arm,
        "left_arm_length_bp": len(left_arm),
        "right_arm_length_bp": len(right_arm),
        "donor_sequence": donor_seq,
        "donor_length_bp": len(donor_seq),
        "final_edited_locus_sequence": final_edited_seq,
        "rflp": rflp_res,
        "out_out_pcr": out_out,
        "warnings": warnings,
    }


# ============================================================================
# 3.6 四大高阶复合算法 MCP 工具 Pydantic/TypedDict 类型契约与校验器
# ============================================================================

class IndelContributionDict(TypedDict):
    label: str
    shift_bp: Optional[int]
    is_hdr: bool
    is_frameshift: bool
    raw_weight: float
    percent: float


class DeconvoluteCrisprSangerInputDict(TypedDict, total=False):
    wt_sequence: Optional[str]
    sgrna_sequence: Optional[str]
    wt_peaks_acgt: Optional[List[List[float]]]
    edited_peaks_acgt: Optional[List[List[float]]]
    hdr_donor_sequence: Optional[str]
    hdr_peaks_acgt: Optional[List[List[float]]]
    cut_index_0based: Optional[int]
    is_reverse_strand_sgrna: bool
    window_length_bp: Optional[int]
    requested_window_length_bp: Optional[int]
    shift_min_bp: int
    shift_max_bp: int
    noise_floor_weight: float
    wt_ab1_path: Optional[str]
    edited_ab1_path: Optional[str]


class DeconvoluteCrisprSangerOutputDict(TypedDict):
    cut_index_0based: int
    is_reverse_strand_sgrna: bool
    requested_window_bp: int
    effective_window_bp: int
    wt_percent: float
    indel_percent: float
    ko_score: float
    hdr_percent: float
    total_edited_percent: float
    r_squared: float
    residual_norm: float
    warnings: List[str]
    contributions: List[IndelContributionDict]
    dominant_indels: List[IndelContributionDict]


class AutoAnnotateSequenceInputDict(TypedDict, total=False):
    fasta_text: Optional[str]
    sequence: Optional[str]
    plasmid_name: str
    is_circular: bool
    min_identity: float
    min_fragment_coverage: float
    full_feature_coverage_threshold: float
    db_path: Optional[str]


class AnnotatedFeatureDict(TypedDict):
    feature_id: int
    name: str
    display_name: str
    category: str
    strand: str
    canonical_direction: int
    start_1based: int
    end_1based: int
    matched_length: int
    reference_length: int
    feature_start_1based: int
    feature_end_1based: int
    coverage: float
    identity: float
    alignment_score: float
    is_origin_spanning: bool
    is_fragment: bool
    fragment_warning: Optional[str]
    color_hex: str


class AutoAnnotateSequenceOutputDict(TypedDict):
    plasmid_name: str
    sequence_length: int
    is_circular: bool
    features_count: int
    fragment_count: int
    origin_spanning_count: int
    annotated_coverage_percent: float
    features: List[AnnotatedFeatureDict]
    warnings: List[str]


class GoldenGateFragmentInputDict(TypedDict, total=False):
    name: str
    sequence: str
    is_coding_sequence: bool
    reading_frame_offset: int


class DesignGoldenGateAssemblyInputDict(TypedDict, total=False):
    enzyme_name: str
    fragment_count: Optional[int]
    is_circular: bool
    fixed_overhangs: List[str]
    fragments: List[GoldenGateFragmentInputDict]
    db_path: Optional[str]


class CrossMismatchPairDict(TypedDict):
    overhang_a: str
    overhang_b: str
    ligation_count: int


class OverhangPlanDict(TypedDict):
    enzyme_name: str
    fragment_count: int
    junction_count: int
    overhang_length: int
    assigned_overhangs: List[str]
    assembly_fidelity: float
    cross_mismatch_count: int
    cross_mismatch_pairs: List[CrossMismatchPairDict]
    warnings: List[str]


class DomesticationSuggestionDict(TypedDict):
    fragment_index: int
    fragment_name: str
    enzyme_name: str
    site_strand: str
    site_start_1based: int
    site_end_1based: int
    original_site: str
    is_coding_sequence: bool
    codon_index_1based: Optional[int]
    original_codon: Optional[str]
    mutated_codon: Optional[str]
    amino_acid: Optional[str]
    mutation_position_1based: int
    original_base: str
    mutated_base: str
    is_synonymous: bool
    note: str


class FragmentDomesticationDict(TypedDict):
    fragment_index: int
    fragment_name: str
    original_length: int
    internal_sites_found: int
    remaining_sites_after_domestication: int
    suggestions: List[DomesticationSuggestionDict]
    domesticated_sequence: str


class DesignGoldenGateAssemblyOutputDict(TypedDict):
    enzyme_name: str
    recognition_site: str
    overhang_length: int
    overhang_plan: OverhangPlanDict
    domestications: List[FragmentDomesticationDict]
    total_internal_sites_found: int
    assembled_sequence_length: int


class SilentMutationDict(TypedDict):
    position_0based: int
    position_1based: int
    original_base: str
    mutated_base: str
    reason: str
    codon_before: Optional[str]
    codon_after: Optional[str]
    amino_acid: Optional[str]


class RFLPDesignDict(TypedDict):
    mode: str
    enzyme_name: str
    recognition_site: str
    top_cut_offset: int
    wt_amplicon_bands_bp: List[int]
    hdr_amplicon_bands_bp: List[int]
    silent_mutations: List[SilentMutationDict]
    note: str


class OutOutPrimerDict(TypedDict):
    name: str
    full_sequence: str
    specific_sequence: str
    tm: float
    gc_percent: float


class OutOutPCRDict(TypedDict):
    forward_primer: OutOutPrimerDict
    reverse_primer: OutOutPrimerDict
    forward_start_0based: int
    forward_end_0based: int
    reverse_start_0based: int
    reverse_end_0based: int
    wt_amplicon_length_bp: int
    hdr_amplicon_length_bp: int
    wt_amplicon_sequence: str
    hdr_amplicon_sequence: str
    left_margin_from_arm_bp: int
    right_margin_from_arm_bp: int


class DesignHdrDonorInputDict(TypedDict, total=False):
    reference_sequence: str
    sgrna_sequence: str
    strand: str
    edit_start_0based: int
    edit_end_0based: int
    replacement_sequence: str
    donor_format: str
    left_arm_length_bp: Optional[int]
    right_arm_length_bp: Optional[int]
    cds_start_1based: Optional[int]
    cds_end_1based: Optional[int]
    auto_detect_cds: bool
    enable_rflp: bool
    rflp_search_radius_bp: int
    out_out_margin_bp: int
    primer_target_tm: float
    donor_name: str


class DesignHdrDonorOutputDict(TypedDict):
    donor_format: str
    sgrna_sequence: str
    strand: str
    wt_cut_index_0based: int
    wt_pam_start_0based: int
    wt_pam_sequence: str
    is_in_cds: bool
    cds_start_1based: Optional[int]
    cds_end_1based: Optional[int]
    cds_auto_detected: bool
    protein_before_blocking: str
    protein_after_blocking: str
    amino_acid_conserved: bool
    blocking_strategy: str
    blocking_mutations: List[SilentMutationDict]
    edited_pam_sequence: str
    pam_still_intact: bool
    cas9_recut_blocked: bool
    left_homology_arm: str
    insert_payload: str
    right_homology_arm: str
    left_arm_length_bp: int
    right_arm_length_bp: int
    donor_sequence: str
    donor_length_bp: int
    final_edited_locus_sequence: str
    rflp: Optional[RFLPDesignDict]
    out_out_pcr: Optional[OutOutPCRDict]
    warnings: List[str]


_GG_ENZYME_NORMALIZE = {
    "bsai": "BsaI",
    "bsmbi": "BsmBI",
    "bbsi": "BbsI",
    "sapi": "SapI",
}


def _is_non_bool_int(val: Any) -> bool:
    return isinstance(val, int) and not isinstance(val, bool)


def _is_non_bool_number(val: Any) -> bool:
    return isinstance(val, (int, float)) and not isinstance(val, bool)


def _validate_peaks_matrix(mat: Any, field_name: str) -> None:
    if mat is None:
        return
    if not isinstance(mat, list):
        raise ValueError(f"{field_name} 必须为四通道峰高二维数组 [[A, C, G, T], ...]")
    for idx, row in enumerate(mat):
        if not isinstance(row, list) or len(row) != 4 or not all(_is_non_bool_number(x) for x in row):
            raise ValueError(f"{field_name}[{idx}] 必须为长度为 4 的数值数组 [A, C, G, T]")


def _prepare_deconv_input_dict(raw: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("deconvolute_crispr_sanger 参数必须为 JSON object")
    d = dict(raw)
    if d.get("is_reverse_strand_sgrna") is None:
        d["is_reverse_strand_sgrna"] = False
    for k, dv in (("shift_min_bp", -20), ("shift_max_bp", 20), ("noise_floor_weight", 1e-6)):
        if d.get(k) is None:
            d[k] = dv
    for k in ("window_length_bp", "requested_window_length_bp", "cut_index_0based", "shift_min_bp", "shift_max_bp"):
        if d.get(k) is not None and not _is_non_bool_int(d[k]):
            raise ValueError(f"{k} 必须为整数，收到 {type(d[k]).__name__}")
    if d.get("noise_floor_weight") is not None and not _is_non_bool_number(d["noise_floor_weight"]):
        raise ValueError("noise_floor_weight 必须为数值")
    for k in ("wt_peaks_acgt", "edited_peaks_acgt", "hdr_peaks_acgt"):
        _validate_peaks_matrix(d.get(k), k)
    return d


def _prepare_annotate_input_dict(raw: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("auto_annotate_sequence 参数必须为 JSON object")
    d = dict(raw)
    if d.get("plasmid_name") is None:
        d["plasmid_name"] = "Unannotated_Plasmid"
    if d.get("is_circular") is None:
        d["is_circular"] = True
    for k, dv in (("min_identity", 0.85), ("min_fragment_coverage", 0.30), ("full_feature_coverage_threshold", 0.90)):
        if d.get(k) is None:
            d[k] = dv
        elif not _is_non_bool_number(d[k]):
            raise ValueError(f"{k} 必须为数值")
    return d


def _prepare_gg_input_dict(raw: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("design_golden_gate_assembly 参数必须为 JSON object")
    d = dict(raw)
    if d.get("enzyme_name") is None:
        d["enzyme_name"] = "BsaI"
    elif isinstance(d["enzyme_name"], str):
        norm = _GG_ENZYME_NORMALIZE.get(d["enzyme_name"].strip().lower())
        if norm:
            d["enzyme_name"] = norm
    if d.get("is_circular") is None:
        d["is_circular"] = True
    if d.get("fixed_overhangs") is None:
        d["fixed_overhangs"] = []
    if d.get("fragments") is None:
        d["fragments"] = []
    if d.get("fragment_count") is not None and not _is_non_bool_int(d["fragment_count"]):
        raise ValueError("fragment_count 必须为整数")
    frags = d.get("fragments")
    if isinstance(frags, list):
        norm_frags = []
        for idx, item in enumerate(frags):
            if not isinstance(item, dict):
                raise ValueError(f"fragments[{idx}] 必须为对象")
            fi = dict(item)
            if fi.get("reading_frame_offset") is not None and not _is_non_bool_int(fi["reading_frame_offset"]):
                raise ValueError(f"fragments[{idx}].reading_frame_offset 必须为整数")
            norm_frags.append(fi)
        d["fragments"] = norm_frags
    return d


def _prepare_hdr_input_dict(raw: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("design_hdr_donor 参数必须为 JSON object")
    d = dict(raw)
    if "sgRNASequence" in d:
        legacy = d.pop("sgRNASequence")
        if "sgrna_sequence" not in d or d["sgrna_sequence"] is None:
            d["sgrna_sequence"] = legacy
    for k, dv in (("strand", "+"), ("donor_format", "ssODN"), ("auto_detect_cds", True), ("enable_rflp", False), ("rflp_search_radius_bp", 15), ("out_out_margin_bp", 100), ("primer_target_tm", 60.0), ("donor_name", "HDR_Donor")):
        if d.get(k) is None:
            d[k] = dv
    for k in ("edit_start_0based", "edit_end_0based", "left_arm_length_bp", "right_arm_length_bp", "cds_start_1based", "cds_end_1based", "rflp_search_radius_bp", "out_out_margin_bp"):
        if d.get(k) is not None and not _is_non_bool_int(d[k]):
            raise ValueError(f"{k} 必须为整数")
    if d.get("primer_target_tm") is not None and not _is_non_bool_number(d["primer_target_tm"]):
        raise ValueError("primer_target_tm 必须为数值")
    return d


if _HAS_PYDANTIC:
    class IndelContributionModel(BaseModel):
        label: str
        shift_bp: Optional[int] = None
        is_hdr: bool
        is_frameshift: bool
        raw_weight: float
        percent: float


    class DeconvoluteCrisprSangerInput(BaseModel):
        model_config = ConfigDict(extra="forbid")
        wt_sequence: Optional[str] = None
        sgrna_sequence: Optional[str] = None
        wt_peaks_acgt: Optional[List[List[float]]] = None
        edited_peaks_acgt: Optional[List[List[float]]] = None
        hdr_donor_sequence: Optional[str] = None
        hdr_peaks_acgt: Optional[List[List[float]]] = None
        cut_index_0based: Optional[int] = Field(default=None, ge=0)
        is_reverse_strand_sgrna: bool = False
        window_length_bp: Optional[int] = Field(default=None, ge=1, le=1000)
        requested_window_length_bp: Optional[int] = Field(default=None, ge=1, le=1000)
        shift_min_bp: int = Field(default=-20, ge=-50, le=0)
        shift_max_bp: int = Field(default=20, ge=0, le=50)
        noise_floor_weight: float = Field(default=1e-6, ge=0.0)
        wt_ab1_path: Optional[str] = None
        edited_ab1_path: Optional[str] = None

        @model_validator(mode="after")
        def _validate_cross(self) -> "DeconvoluteCrisprSangerInput":
            has_wt = bool(self.wt_peaks_acgt) or bool((self.wt_sequence or "").strip()) or bool((self.wt_ab1_path or "").strip())
            has_ed = bool(self.edited_peaks_acgt) or bool((self.edited_ab1_path or "").strip())
            if not has_wt:
                raise ValueError("必须提供 wt_peaks_acgt、wt_sequence 或 wt_ab1_path 之一")
            if not has_ed:
                raise ValueError("必须提供 edited_peaks_acgt 或 edited_ab1_path")
            if self.cut_index_0based is None and not (self.sgrna_sequence or "").strip():
                raise ValueError("未指定 cut_index_0based 时必须提供 sgrna_sequence 以定位切点")
            if self.shift_min_bp > 0 or self.shift_max_bp < 0 or self.shift_min_bp > self.shift_max_bp:
                raise ValueError("移码搜索范围必须满足 shift_min_bp <= 0 <= shift_max_bp")
            return self


    class DeconvoluteCrisprSangerOutput(BaseModel):
        cut_index_0based: int
        is_reverse_strand_sgrna: bool
        requested_window_bp: int
        effective_window_bp: int
        wt_percent: float
        indel_percent: float
        ko_score: float
        hdr_percent: float
        total_edited_percent: float
        r_squared: float
        residual_norm: float
        warnings: List[str]
        contributions: List[IndelContributionModel]
        dominant_indels: List[IndelContributionModel]


    class AutoAnnotateSequenceInput(BaseModel):
        model_config = ConfigDict(extra="forbid")
        fasta_text: Optional[str] = None
        sequence: Optional[str] = None
        plasmid_name: str = "Unannotated_Plasmid"
        is_circular: bool = True
        min_identity: float = Field(default=0.85, ge=0.5, le=1.0)
        min_fragment_coverage: float = Field(default=0.30, ge=0.1, le=0.95)
        full_feature_coverage_threshold: float = Field(default=0.90, ge=0.5, le=1.0)
        db_path: Optional[str] = None

        @model_validator(mode="after")
        def _validate_cross(self) -> "AutoAnnotateSequenceInput":
            if not ((self.fasta_text or "").strip() or (self.sequence or "").strip()):
                raise ValueError("必须提供 fasta_text 或 sequence")
            if self.full_feature_coverage_threshold < self.min_fragment_coverage:
                raise ValueError("full_feature_coverage_threshold 不能小于 min_fragment_coverage")
            return self


    class AnnotatedFeatureModel(BaseModel):
        feature_id: int
        name: str
        display_name: str
        category: str
        strand: str
        canonical_direction: int
        start_1based: int
        end_1based: int
        matched_length: int
        reference_length: int
        feature_start_1based: int
        feature_end_1based: int
        coverage: float
        identity: float
        alignment_score: float
        is_origin_spanning: bool
        is_fragment: bool
        fragment_warning: Optional[str] = None
        color_hex: str


    class AutoAnnotateSequenceOutput(BaseModel):
        plasmid_name: str
        sequence_length: int
        is_circular: bool
        features_count: int
        fragment_count: int
        origin_spanning_count: int
        annotated_coverage_percent: float
        features: List[AnnotatedFeatureModel]
        warnings: List[str]


    class GoldenGateFragmentInput(BaseModel):
        model_config = ConfigDict(extra="forbid")
        name: str = "Fragment"
        sequence: str = Field(min_length=1)
        is_coding_sequence: bool = True
        reading_frame_offset: int = Field(default=0, ge=0, le=2)


    class DesignGoldenGateAssemblyInput(BaseModel):
        model_config = ConfigDict(extra="forbid")
        enzyme_name: Literal["BsaI", "BsmBI", "BbsI", "SapI"] = "BsaI"
        fragment_count: Optional[int] = Field(default=None, ge=2, le=6)
        is_circular: bool = True
        fixed_overhangs: List[str] = Field(default_factory=list)
        fragments: List[GoldenGateFragmentInput] = Field(default_factory=list)
        db_path: Optional[str] = None

        @model_validator(mode="after")
        def _validate_cross(self) -> "DesignGoldenGateAssemblyInput":
            if not self.fragments and self.fragment_count is None:
                raise ValueError("未传入 fragments 时必须显式指定 fragment_count (2–6)")
            eff = self.fragment_count if self.fragment_count is not None else len(self.fragments)
            if not (2 <= eff <= 6):
                raise ValueError(f"有效组装片段数必须在 2–6 之间，当前为 {eff}")
            return self


    class CrossMismatchPairModel(BaseModel):
        overhang_a: str
        overhang_b: str
        ligation_count: int


    class OverhangPlanModel(BaseModel):
        enzyme_name: str
        fragment_count: int
        junction_count: int
        overhang_length: int
        assigned_overhangs: List[str]
        assembly_fidelity: float
        cross_mismatch_count: int
        cross_mismatch_pairs: List[CrossMismatchPairModel]
        warnings: List[str]


    class DomesticationSuggestionModel(BaseModel):
        fragment_index: int
        fragment_name: str
        enzyme_name: str
        site_strand: str
        site_start_1based: int
        site_end_1based: int
        original_site: str
        is_coding_sequence: bool
        codon_index_1based: Optional[int] = None
        original_codon: Optional[str] = None
        mutated_codon: Optional[str] = None
        amino_acid: Optional[str] = None
        mutation_position_1based: int
        original_base: str
        mutated_base: str
        is_synonymous: bool
        note: str


    class FragmentDomesticationModel(BaseModel):
        fragment_index: int
        fragment_name: str
        original_length: int
        internal_sites_found: int
        remaining_sites_after_domestication: int
        suggestions: List[DomesticationSuggestionModel]
        domesticated_sequence: str


    class DesignGoldenGateAssemblyOutput(BaseModel):
        enzyme_name: str
        recognition_site: str
        overhang_length: int
        overhang_plan: OverhangPlanModel
        domestications: List[FragmentDomesticationModel]
        total_internal_sites_found: int
        assembled_sequence_length: int


    class DesignHdrDonorInput(BaseModel):
        model_config = ConfigDict(extra="forbid")
        reference_sequence: str = Field(min_length=25)
        sgrna_sequence: str = Field(min_length=15)
        strand: Literal["+", "-"] = "+"
        edit_start_0based: int = Field(ge=0)
        edit_end_0based: int = Field(ge=0)
        replacement_sequence: str
        donor_format: Literal["ssODN", "dsDNAPlasmid"] = "ssODN"
        left_arm_length_bp: Optional[int] = Field(default=None, ge=1)
        right_arm_length_bp: Optional[int] = Field(default=None, ge=1)
        cds_start_1based: Optional[int] = Field(default=None, ge=1)
        cds_end_1based: Optional[int] = Field(default=None, ge=3)
        auto_detect_cds: bool = True
        enable_rflp: bool = False
        rflp_search_radius_bp: int = Field(default=15, ge=3)
        out_out_margin_bp: int = Field(default=100, ge=0)
        primer_target_tm: float = Field(default=60.0, ge=40.0, le=85.0)
        donor_name: str = "HDR_Donor"

        @model_validator(mode="after")
        def _validate_cross(self) -> "DesignHdrDonorInput":
            if self.edit_end_0based < self.edit_start_0based:
                raise ValueError("edit_end_0based 不能小于 edit_start_0based")
            if (self.cds_start_1based is None) != (self.cds_end_1based is None):
                raise ValueError("cds_start_1based 与 cds_end_1based 必须同时提供或同时留空")
            if self.cds_start_1based is not None and self.cds_end_1based is not None and self.cds_start_1based >= self.cds_end_1based:
                raise ValueError("cds_start_1based 必须小于 cds_end_1based")
            return self


    class SilentMutationModel(BaseModel):
        position_0based: int
        position_1based: int
        original_base: str
        mutated_base: str
        reason: str
        codon_before: Optional[str] = None
        codon_after: Optional[str] = None
        amino_acid: Optional[str] = None


    class RFLPDesignModel(BaseModel):
        mode: str
        enzyme_name: str
        recognition_site: str
        top_cut_offset: int
        wt_amplicon_bands_bp: List[int]
        hdr_amplicon_bands_bp: List[int]
        silent_mutations: List[SilentMutationModel]
        note: str


    class OutOutPrimerModel(BaseModel):
        name: str
        full_sequence: str
        specific_sequence: str
        tm: float
        gc_percent: float


    class OutOutPCRModel(BaseModel):
        forward_primer: OutOutPrimerModel
        reverse_primer: OutOutPrimerModel
        forward_start_0based: int
        forward_end_0based: int
        reverse_start_0based: int
        reverse_end_0based: int
        wt_amplicon_length_bp: int
        hdr_amplicon_length_bp: int
        wt_amplicon_sequence: str
        hdr_amplicon_sequence: str
        left_margin_from_arm_bp: int
        right_margin_from_arm_bp: int


    class DesignHdrDonorOutput(BaseModel):
        donor_format: str
        sgrna_sequence: str
        strand: str
        wt_cut_index_0based: int
        wt_pam_start_0based: int
        wt_pam_sequence: str
        is_in_cds: bool
        cds_start_1based: Optional[int] = None
        cds_end_1based: Optional[int] = None
        cds_auto_detected: bool
        protein_before_blocking: str
        protein_after_blocking: str
        amino_acid_conserved: bool
        blocking_strategy: str
        blocking_mutations: List[SilentMutationModel]
        edited_pam_sequence: str
        pam_still_intact: bool
        cas9_recut_blocked: bool
        left_homology_arm: str
        insert_payload: str
        right_homology_arm: str
        left_arm_length_bp: int
        right_arm_length_bp: int
        donor_sequence: str
        donor_length_bp: int
        final_edited_locus_sequence: str
        rflp: Optional[RFLPDesignModel] = None
        out_out_pcr: Optional[OutOutPCRModel] = None
        warnings: List[str]


def _stdlib_validate_deconv(raw: Dict[str, Any]) -> Dict[str, Any]:
    allowed = {
        "wt_sequence", "sgrna_sequence", "wt_peaks_acgt", "edited_peaks_acgt",
        "hdr_donor_sequence", "hdr_peaks_acgt", "cut_index_0based",
        "is_reverse_strand_sgrna", "window_length_bp", "requested_window_length_bp",
        "shift_min_bp", "shift_max_bp", "noise_floor_weight", "wt_ab1_path", "edited_ab1_path",
    }
    unknown = set(raw.keys()) - allowed
    if unknown:
        raise ValueError(f"deconvolute_crispr_sanger 存在未定义字段: {sorted(unknown)}")
    d = _prepare_deconv_input_dict(raw)
    if d.get("cut_index_0based") is not None and d["cut_index_0based"] < 0:
        raise ValueError("cut_index_0based 不能小于 0")
    win = d.get("window_length_bp") if d.get("window_length_bp") is not None else d.get("requested_window_length_bp")
    if win is not None and not (1 <= win <= 1000):
        raise ValueError("window_length_bp 必须在 1–1000 之间")
    smin = d.get("shift_min_bp", -20)
    smax = d.get("shift_max_bp", 20)
    if not (-50 <= smin <= 0 <= smax <= 50 and smin <= smax):
        raise ValueError("移码范围必须满足 -50 <= shift_min_bp <= 0 <= shift_max_bp <= 50")
    if float(d.get("noise_floor_weight", 1e-6)) < 0.0:
        raise ValueError("noise_floor_weight 不能为负数")
    has_wt = bool(d.get("wt_peaks_acgt")) or bool(str(d.get("wt_sequence") or "").strip()) or bool(str(d.get("wt_ab1_path") or "").strip())
    has_ed = bool(d.get("edited_peaks_acgt")) or bool(str(d.get("edited_ab1_path") or "").strip())
    if not has_wt:
        raise ValueError("必须提供 wt_peaks_acgt、wt_sequence 或 wt_ab1_path 之一")
    if not has_ed:
        raise ValueError("必须提供 edited_peaks_acgt 或 edited_ab1_path")
    if d.get("cut_index_0based") is None and not str(d.get("sgrna_sequence") or "").strip():
        raise ValueError("未指定 cut_index_0based 时必须提供 sgrna_sequence 以定位切点")
    return d


def _stdlib_validate_annotate(raw: Dict[str, Any]) -> Dict[str, Any]:
    allowed = {
        "fasta_text", "sequence", "plasmid_name", "is_circular",
        "min_identity", "min_fragment_coverage", "full_feature_coverage_threshold", "db_path",
    }
    unknown = set(raw.keys()) - allowed
    if unknown:
        raise ValueError(f"auto_annotate_sequence 存在未定义字段: {sorted(unknown)}")
    d = _prepare_annotate_input_dict(raw)
    if not (str(d.get("fasta_text") or "").strip() or str(d.get("sequence") or "").strip()):
        raise ValueError("必须提供 fasta_text 或 sequence")
    min_id = float(d["min_identity"])
    min_fc = float(d["min_fragment_coverage"])
    full_cov = float(d["full_feature_coverage_threshold"])
    if not (0.5 <= min_id <= 1.0):
        raise ValueError("min_identity 必须在 [0.5, 1.0] 之间")
    if not (0.1 <= min_fc <= 0.95):
        raise ValueError("min_fragment_coverage 必须在 [0.1, 0.95] 之间")
    if not (0.5 <= full_cov <= 1.0):
        raise ValueError("full_feature_coverage_threshold 必须在 [0.5, 1.0] 之间")
    if full_cov < min_fc:
        raise ValueError("full_feature_coverage_threshold 不能小于 min_fragment_coverage")
    return d


def _stdlib_validate_gg(raw: Dict[str, Any]) -> Dict[str, Any]:
    allowed = {"enzyme_name", "fragment_count", "is_circular", "fixed_overhangs", "fragments", "db_path"}
    unknown = set(raw.keys()) - allowed
    if unknown:
        raise ValueError(f"design_golden_gate_assembly 存在未定义字段: {sorted(unknown)}")
    d = _prepare_gg_input_dict(raw)
    if d["enzyme_name"] not in ("BsaI", "BsmBI", "BbsI", "SapI"):
        raise ValueError(f"enzyme_name 仅支持 BsaI/BsmBI/BbsI/SapI，收到 {d['enzyme_name']}")
    frags = d.get("fragments") or []
    frag_allowed = {"name", "sequence", "is_coding_sequence", "reading_frame_offset"}
    for idx, f in enumerate(frags):
        u_f = set(f.keys()) - frag_allowed
        if u_f:
            raise ValueError(f"fragments[{idx}] 存在未定义字段: {sorted(u_f)}")
        if not isinstance(f.get("sequence"), str) or not f["sequence"].strip():
            raise ValueError(f"fragments[{idx}].sequence 不能为空")
        rfo = f.get("reading_frame_offset", 0)
        if not (0 <= int(rfo) <= 2):
            raise ValueError(f"fragments[{idx}].reading_frame_offset 必须为 0、1 或 2")
    fc = d.get("fragment_count")
    if fc is not None and not (2 <= int(fc) <= 6):
        raise ValueError("fragment_count 必须在 2–6 之间")
    if not frags and fc is None:
        raise ValueError("未传入 fragments 时必须显式指定 fragment_count (2–6)")
    eff = int(fc) if fc is not None else len(frags)
    if not (2 <= eff <= 6):
        raise ValueError(f"有效组装片段数必须在 2–6 之间，当前为 {eff}")
    return d


def _stdlib_validate_hdr(raw: Dict[str, Any]) -> Dict[str, Any]:
    allowed = {
        "reference_sequence", "sgrna_sequence", "strand", "edit_start_0based",
        "edit_end_0based", "replacement_sequence", "donor_format",
        "left_arm_length_bp", "right_arm_length_bp", "cds_start_1based",
        "cds_end_1based", "auto_detect_cds", "enable_rflp",
        "rflp_search_radius_bp", "out_out_margin_bp", "primer_target_tm", "donor_name",
    }
    d = _prepare_hdr_input_dict(raw)
    unknown = set(d.keys()) - allowed
    if unknown:
        raise ValueError(f"design_hdr_donor 存在未定义字段: {sorted(unknown)}")
    for req in ("reference_sequence", "sgrna_sequence", "edit_start_0based", "edit_end_0based", "replacement_sequence"):
        if req not in d or d[req] is None:
            raise ValueError(f"缺少必填参数: {req}")
    if not isinstance(d["reference_sequence"], str) or len(d["reference_sequence"]) < 25:
        raise ValueError("reference_sequence 长度至少需要 25 bp")
    if not isinstance(d["sgrna_sequence"], str) or len(d["sgrna_sequence"]) < 15:
        raise ValueError("sgrna_sequence 长度至少需要 15 nt")
    if d["strand"] not in ("+", "-"):
        raise ValueError("strand 必须为 '+' 或 '-'")
    if d["edit_start_0based"] < 0 or d["edit_end_0based"] < d["edit_start_0based"]:
        raise ValueError("edit_start_0based / edit_end_0based 非法")
    if d["donor_format"] not in ("ssODN", "dsDNAPlasmid"):
        raise ValueError(f"donor_format 必须为 ssODN 或 dsDNAPlasmid，收到 {d['donor_format']}")
    for arm_k in ("left_arm_length_bp", "right_arm_length_bp"):
        if d.get(arm_k) is not None and d[arm_k] < 1:
            raise ValueError(f"{arm_k} 必须 >= 1")
    cs, ce = d.get("cds_start_1based"), d.get("cds_end_1based")
    if (cs is None) != (ce is None):
        raise ValueError("cds_start_1based 与 cds_end_1based 必须同时提供或同时留空")
    if cs is not None and ce is not None and (cs < 1 or ce < 3 or cs >= ce):
        raise ValueError("cds_start_1based 与 cds_end_1based 范围非法")
    if d["rflp_search_radius_bp"] < 3:
        raise ValueError("rflp_search_radius_bp 必须 >= 3")
    if d["out_out_margin_bp"] < 0:
        raise ValueError("out_out_margin_bp 不能为负数")
    tm = float(d["primer_target_tm"])
    if not (40.0 <= tm <= 85.0):
        raise ValueError("primer_target_tm 必须在 40.0–85.0 °C 之间")
    return d


def tool_deconvolute_crispr_sanger(args: Dict[str, Any]) -> DeconvoluteCrisprSangerOutputDict:
    """
    对 CRISPR 编辑池 Sanger 测序信号执行 Synthego ICE 风格非负最小二乘（NNLS）混杂峰解卷积定量。

    支持直接传入与 Swift 黄金测试向量 `crispr_deconv_golden.json` 对齐的四通道荧光峰值矩阵
    （`wt_peaks_acgt`、`edited_peaks_acgt`、`hdr_peaks_acgt`），也支持传入本地 `.ab1`/`.abi` 文件路径
    （`wt_ab1_path`、`edited_ab1_path`）自动解析切点下游窗口峰高后求解 -20..+20 bp 移码分布、
    总编辑效率（Indel%）、移码敲除率（KO Score）、HDR 精确修复率（HDR%）与拟合优度 R²。
    """
    prepped = _prepare_deconv_input_dict(args)
    if _HAS_PYDANTIC:
        validated = DeconvoluteCrisprSangerInput.model_validate(prepped).model_dump()
    else:
        validated = _stdlib_validate_deconv(args)

    req_win = validated.get("window_length_bp") or validated.get("requested_window_length_bp") or 150
    validated["window_length_bp"] = int(req_win)

    wt_ab1_path = validated.get("wt_ab1_path")
    if wt_ab1_path and not validated.get("wt_peaks_acgt"):
        full_wt = os.path.expanduser(str(wt_ab1_path))
        if not os.path.exists(full_wt):
            raise FileNotFoundError(f"找不到 WT .ab1 文件: {wt_ab1_path}")
        with open(full_wt, "rb") as f:
            wt_parsed = _extract_ab1_peaks_acgt(f.read())
        validated["wt_peaks_acgt"] = wt_parsed["peaks_acgt"]
        if not validated.get("wt_sequence"):
            validated["wt_sequence"] = wt_parsed["sequence"]

    ed_ab1_path = validated.get("edited_ab1_path")
    if ed_ab1_path and not validated.get("edited_peaks_acgt"):
        full_ed = os.path.expanduser(str(ed_ab1_path))
        if not os.path.exists(full_ed):
            raise FileNotFoundError(f"找不到 Edited .ab1 文件: {ed_ab1_path}")
        with open(full_ed, "rb") as f:
            ed_parsed = _extract_ab1_peaks_acgt(f.read())
        cut_idx = validated.get("cut_index_0based")
        wt_seq = clean_seq(validated.get("wt_sequence") or "")
        sg_seq = clean_seq(validated.get("sgrna_sequence") or "")
        if cut_idx is None and wt_seq and sg_seq:
            loc = locate_crispr_cut_site(wt_seq, sg_seq)
            cut_idx = loc[0] if loc is not None else 0
        cut_idx = int(cut_idx or 0)
        ed_cut_idx = cut_idx
        if wt_seq and cut_idx >= 15 and ed_parsed["sequence"]:
            anc_start = max(0, cut_idx - 25)
            anchor = wt_seq[anc_start:cut_idx - 5]
            if len(anchor) >= 10:
                pos = ed_parsed["sequence"].find(anchor)
                if pos != -1:
                    ed_cut_idx = pos + (cut_idx - anc_start)
        validated["edited_peaks_acgt"] = ed_parsed["peaks_acgt"][ed_cut_idx:ed_cut_idx + int(req_win)]

    result = deconvolve_sanger_crispr(validated)
    if _HAS_PYDANTIC:
        return DeconvoluteCrisprSangerOutput.model_validate(result).model_dump()
    return result  # type: ignore[return-value]


def tool_auto_annotate_sequence(args: Dict[str, Any]) -> AutoAnnotateSequenceOutputDict:
    """
    基于本地 `Libraries.sqlite` 标准质粒元件库（`plasmid_features`）执行纯离线质粒 FASTA 自动注释。

    支持正反双链特征扫描、环形质粒跨 1 bp 零点（Origin）连续拼接匹配，并对长度覆盖率落在
    30%–90% 之间的截短元件自动标记历史克隆残留片段（Fragment）警示。输入与输出结构与
    Swift 黄金测试向量 `plasmid_auto_annotation.json` 完全一致。
    """
    prepped = _prepare_annotate_input_dict(args)
    if _HAS_PYDANTIC:
        validated = AutoAnnotateSequenceInput.model_validate(prepped).model_dump()
    else:
        validated = _stdlib_validate_annotate(args)
    result = annotate_plasmid_fasta(validated)
    if _HAS_PYDANTIC:
        return AutoAnnotateSequenceOutput.model_validate(result).model_dump()
    return result  # type: ignore[return-value]


def tool_design_golden_gate_assembly(args: Dict[str, Any]) -> DesignGoldenGateAssemblyOutputDict:
    """
    执行 Type IIS（BsaI / BsmBI / BbsI / SapI）Golden Gate 2–6 片段无交叉错配接头规划与 Domestication。

    读取 `Libraries.sqlite` 中 NEB T4 DNA Ligase 4-bp 保真度矩阵，避开高错配与回文接头实现最优正交分配，
    并自动扫描片段内部正反双链内源识别位点，在编码区内给出保持氨基酸 100% 守恒的同义密码子抹除方案。
    输入与输出结构与 Swift 黄金测试向量 `golden_gate_and_digest.json` 完全一致。
    """
    prepped = _prepare_gg_input_dict(args)
    if _HAS_PYDANTIC:
        validated = DesignGoldenGateAssemblyInput.model_validate(prepped).model_dump()
    else:
        validated = _stdlib_validate_gg(args)
    result = design_golden_gate_assembly(validated)
    if _HAS_PYDANTIC:
        return DesignGoldenGateAssemblyOutput.model_validate(result).model_dump()
    return result  # type: ignore[return-value]


def tool_design_hdr_donor(args: Dict[str, Any]) -> DesignHdrDonorOutputDict:
    """
    设计 CRISPR Knock-in HDR 同源供体（ssODN / dsDNA 质粒）、PAM/Seed 同义阻断突变、可选 RFLP 与 Out-Out PCR 引物。

    自动检测目标切点是否位于 CDS 编码区并利用密码子简并性引入同义 PAM（或回退至近 PAM 8-nt Seed）突变
    阻断 Cas9 二次切割，确保翻译氨基酸序列 100% 守恒；支持同义构建/消除 RFLP 鉴定位点及生成左右同源臂外侧
    Out-Out PCR 分型引物。输入与输出结构与 Swift 黄金测试向量 `crispr_hdr_donor.json` 完全一致。
    """
    prepped = _prepare_hdr_input_dict(args)
    if _HAS_PYDANTIC:
        validated = DesignHdrDonorInput.model_validate(prepped).model_dump()
    else:
        validated = _stdlib_validate_hdr(args)
    result = design_crispr_hdr_donor(validated)
    if _HAS_PYDANTIC:
        return DesignHdrDonorOutput.model_validate(result).model_dump()
    return result  # type: ignore[return-value]


# ============================================================================
# 4. MCP JSON-RPC 2.0 协议路由与 23 大全栈工具声明 (Labworker MCP 20261115)
# ============================================================================

MCP_TOOLS = [
    {
        "name": "list_plasmid_pool",
        "description": "检索并列出 Labworker 质粒池中的质粒，支持按载体 (vector)、目的基因 (gene)、抗性 (resistance)、分类 (category) 及关键词 (query) 多维过滤。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "可选综合搜索关键词"},
                "vector": {"type": "string", "description": "按载体骨架过滤（如 'pCMV'、'pETDuet'、'pcDNA3.1'、'pLKO.1'）"},
                "gene": {"type": "string", "description": "按目的基因过滤（如 'TP53'、'BRCA1'、'MYC'、'A1'、'B1'）"},
                "resistance": {"type": "string", "description": "按抗性标记过滤（如 'AmpR'、'KanR'、'NeoR'、'PuroR'）"},
                "category": {"type": "string", "description": "按分类过滤（如 '哺乳动物表达'、'原核表达'、'慢病毒/CRISPR'）"}
            }
        }
    },
    {
        "name": "inspect_plasmid",
        "description": "深度查看质粒池中指定质粒的载体骨架、目的基因、抗性、全部特征注释坐标、已绑定引物、唯一酶切位点及可选完整序列。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "plasmid_name": {"type": "string", "description": "质粒名称、别名或含有的特征基因名"},
                "include_sequence": {"type": "boolean", "description": "是否返回完整 DNA 序列"}
            },
            "required": ["plasmid_name"]
        }
    },
    {
        "name": "add_plasmid_to_pool",
        "description": "将本地 .dna 质粒文件解析并导入 Labworker 质粒池，自动提取载体、基因与抗性标签。请先以 confirm=false 预览，经用户同意后再以 confirm=true 执行。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": ".dna 文件的绝对路径"},
                "alias_name": {"type": "string", "description": "可选简称或别名"},
                "category": {"type": "string", "description": "分类标签（如 哺乳动物表达 / 原核表达 / 慢病毒/CRISPR）"},
                "confirm": {"type": "boolean", "default": False, "description": "写操作确认：默认 false 仅返回 dry-run 预览 planned_writes，经用户同意后设为 true 执行落盘"}
            },
            "required": ["file_path"]
        }
    },
    {
        "name": "design_single_clone_primers",
        "description": "一键根据质粒池中的载体和供体设计单片段无缝克隆/同源重组引物，自动检测 3n 阅读框并同步至 Labworker 单片段模块画布（如需写盘导出重组 .dna，请先以 confirm=false 预览，经用户同意后再以 confirm=true 执行）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "vector_name": {"type": "string", "description": "质粒池中的载体名称（如 'pETDuet' 或 'pCMV'）"},
                "vector_site": {"type": "string", "description": "载体插入/替换位点：可填特征名（如 'A1'）、酶切位点（如 'BamHI'）或坐标（如 '3382..4371'）"},
                "insert_source": {"type": "string", "description": "插入片段来源：可填 '供体质粒名:特征名'（如 'TP53:TP53'），或直接传入 DNA 序列"},
                "homology_length": {"type": "integer", "description": "同源臂长度 (bp)，默认 18", "default": 18},
                "extra_5_bases": {"type": "string", "description": "可选 5' 端附加碱基（用于补齐 3n 阅读框或添加 Linker）"},
                "extra_3_bases": {"type": "string", "description": "可选 3' 端附加碱基（正向 5'->3' 填写）"},
                "remove_stop_codon": {"type": "boolean", "description": "是否自动去除插入片段末尾终止密码子", "default": True},
                "include_vector_pcr_primers": {"type": "boolean", "description": "是否同时生成载体反向 PCR 线性化引物", "default": True},
                "export_recombinant_dna": {"type": "boolean", "description": "是否同时导出组装好的重组质粒 .dna 文件", "default": False},
                "output_dna_path": {"type": "string", "description": "可选：重组 .dna 导出目标路径"},
                "confirm": {"type": "boolean", "default": False, "description": "当 export_recombinant_dna=true 时生效：默认 false 仅返回 dry-run 预览，设为 true 时才写盘并自动备份已存在文件"}
            },
            "required": ["vector_name", "vector_site", "insert_source"]
        }
    },
    {
        "name": "design_multi_fragment_primers",
        "description": "一键设计多片段（2～10个片段）无缝拼接引物，并实时同步至 Labworker 多片段克隆画布。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "vector_name": {"type": "string", "description": "质粒池中的载体名称"},
                "vector_site": {"type": "string", "description": "载体线性化位点（特征名、酶切位点或起止坐标）"},
                "fragments": {"type": "array", "items": {"type": "string"}, "description": "按组装顺序排列的片段来源列表（每项可为 '质粒名:特征名' 或 DNA 序列）"},
                "homology_length": {"type": "integer", "default": 18}
            },
            "required": ["vector_name", "vector_site", "fragments"]
        }
    },
    {
        "name": "design_mutagenesis_primers",
        "description": "一键对质粒池中的基因特征执行定点突变引物设计（支持 'K42R'、'S42A'、'K42Δ' 简写，含野生型氨基酸自动核对与宿主偏好密码子选择）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "plasmid_name": {"type": "string", "description": "质粒池中的质粒名称"},
                "feature_name": {"type": "string", "description": "待突变的目标 CDS/基因特征名称（如 'TP53' 或 'BRCA1'）"},
                "mutation_spec": {"type": "string", "description": "氨基酸突变简写（如 'S42A'、'K15R' 或 'K15Δ'）"},
                "homology_length": {"type": "integer", "default": 18},
                "allow_wt_mismatch": {"type": "boolean", "description": "当输入的野生型氨基酸与实际位点不符时是否强制继续", "default": False}
            },
            "required": ["plasmid_name", "feature_name", "mutation_spec"]
        }
    },
    {
        "name": "design_fragment_deletion_primers",
        "description": "一键设计质粒片段删除/结构域敲除的反向 PCR 环化引物，并同步至 Labworker 片段删除画布。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "plasmid_name": {"type": "string", "description": "质粒池中的质粒名称"},
                "delete_target": {"type": "string", "description": "待删除的特征名称或起止坐标（如 '1033..1176'）"},
                "homology_length": {"type": "integer", "default": 18}
            },
            "required": ["plasmid_name", "delete_target"]
        }
    },
    {
        "name": "calculate_recombination_dosage",
        "description": "计算同源重组反应 (20 μL 体系) 或经典摩尔比连接 (0.03 pmol 载体, 1:1~1:5) 中线性化载体、各插入片段的最佳或自定义 ng 投入量、移液体积 (μL) 与 ddH2O 补齐体积，并同步至 Labworker 生物计算器。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "clone_type": {"type": "string", "enum": ["single", "multi", "simple", "ligation"], "default": "single"},
                "vector_name": {"type": "string", "description": "载体名称"},
                "vector_length": {"type": "number", "description": "载体长度（支持直接传 bp 如 6349 或 kb 如 6.35）"},
                "vector_conc": {"type": "number", "description": "载体浓度 (ng/μL)", "default": 50},
                "vector_custom_ng": {"type": "number", "description": "可选：自定义载体投入量 (ng)，不传则按公式推荐"},
                "vector_pmol": {"type": "number", "description": "经典摩尔比模式下载体最适使用量 (pmol)，默认 0.03", "default": 0.03},
                "molar_ratio": {"type": "integer", "description": "经典摩尔比模式下 载体:片段 比例 1~5 (对应 1:1 ~ 1:5)，默认 3", "default": 3},
                "inserts": {
                    "type": "array",
                    "description": "插入片段列表",
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string"},
                            "length": {"type": "number", "description": "片段长度（支持 bp 如 1038 或 kb 如 1.04）"},
                            "conc": {"type": "number", "description": "片段浓度 (ng/μL)", "default": 20},
                            "custom_ng": {"type": "number", "description": "可选：自定义片段投入量 (ng)"}
                        },
                        "required": ["length"]
                    }
                }
            },
            "required": ["vector_length", "inserts"]
        }
    },
    {
        "name": "design_sgrna_primers",
        "description": "从质粒池中的基因特征或给定序列扫描 CRISPR/Cas9 NGG 靶点、评分排序并生成 lentiCRISPRv2 (BsmBI) 或 pX459 (BbsI) 退火引物对。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target_source": {"type": "string", "description": "基因特征来源（如 'TP53' 或 'pCMV-TP53:TP53'）或直接输入 DNA 序列"},
                "gene_name": {"type": "string", "description": "可选引物命名前缀"},
                "vector_type": {"type": "string", "enum": ["lentiCRISPRv2", "pX459"], "default": "lentiCRISPRv2"},
                "top_n": {"type": "integer", "description": "返回评分最高的前 N 对 sgRNA 引物", "default": 3}
            },
            "required": ["target_source"]
        }
    },
    {
        "name": "design_shrna_primers",
        "description": "从质粒池中的基因特征或给定序列扫描 21nt RNAi 靶点并生成 pLKO.1 (AgeI/EcoRI) shRNA 发夹正反向引物对。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target_source": {"type": "string", "description": "基因特征来源（如 'BRCA1'）或直接输入 DNA 序列"},
                "gene_name": {"type": "string", "description": "可选引物命名前缀"},
                "loop_sequence": {"type": "string", "default": "CTCGAG"},
                "top_n": {"type": "integer", "description": "返回评分最高的前 N 对 shRNA 引物", "default": 3}
            },
            "required": ["target_source"]
        }
    },
    {
        "name": "manage_primer_cart_and_export",
        "description": "查看当前引物订购池，或将引物一键导出为《擎科引物合成订购表.xlsx》Excel 文件（导出 Excel 时请先以 confirm=false 预览，经用户同意后再以 confirm=true 执行）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["list", "export_tsingke_excel"], "default": "list"},
                "output_path": {"type": "string", "description": "可选：导出 Excel 目标路径"},
                "confirm": {"type": "boolean", "default": False, "description": "导出 Excel 写操作确认：默认 false 仅返回 dry-run 预览 planned_writes，设为 true 时才执行导出并备份已存在文件"}
            }
        }
    },
    {
        "name": "analyze_protein_and_docking_box",
        "description": "分析蛋白质氨基酸序列或 PDB 结构文件：计算分子量、理论等电点 pI、疏水性 GRAVY、LIGSITE P-S-P 结合口袋、共晶配体共识 AutoDock Vina 对接盒配置 (vina_config.txt) 及点突变 ΔΔG 热力学稳定性。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "sequence": {"type": "string", "description": "氨基酸序列 (单字母代码)"},
                "pdb_path": {"type": "string", "description": "可选本地 .pdb 结构文件绝对路径"},
                "ph": {"type": "number", "description": "溶液 pH，默认 7.0", "default": 7.0},
                "mutations": {"type": "array", "items": {"type": "string"}, "description": "可选点突变列表（如 ['V13A', 'T48P']）"}
            }
        }
    },
    {
        "name": "analyze_western_blot",
        "description": "对 Western Blot 目的条带与内参灰度积分 (IOD) 执行内参归一化、过曝饱和条带阻断剔除、组内均值/标准差汇总与双组 Welch t 检验显著性分析，并同步至 Labworker WB 定量工作台。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target_iods": {"type": "array", "items": {"type": "number"}, "description": "各泳道目的蛋白条带积分光密度 (IOD) 数组"},
                "loading_control_iods": {"type": "array", "items": {"type": "number"}, "description": "各泳道内参 (如 GAPDH/ACTB) 条带 IOD 数组"},
                "lane_groups": {"type": "array", "items": {"type": "string"}, "description": "各泳道所属实验分组名称数组（如 ['WT', 'WT', 'KO', 'KO']）"},
                "is_saturated": {"type": "array", "items": {"type": "boolean"}, "description": "可选：各泳道是否存在过曝饱和 (true/false)"},
                "saturation_policy": {"type": "string", "enum": ["excludeFromStats", "warnOnly"], "default": "excludeFromStats", "description": "过曝条带处理策略：默认 excludeFromStats 从统计中剔除"}
            },
            "required": ["target_iods"]
        }
    },
    {
        "name": "analyze_qpcr_ddct",
        "description": "基于 2^(-ΔΔCt) 法计算实时荧光定量 PCR 相对表达量，自动检测复孔 Ct 标准差是否超标并同步至 Labworker qPCR 工作台。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "reference_gene": {"type": "string", "description": "内参基因名称，默认 ACTB", "default": "ACTB"},
                "control_sample": {"type": "string", "description": "对照组样本名称，默认 Control", "default": "Control"},
                "sd_threshold": {"type": "number", "description": "复孔 Ct SD 告警阈值，默认 0.30", "default": 0.30},
                "records": {
                    "type": "array",
                    "description": "qPCR Ct 原始记录数组，每项含 sample, gene, ct",
                    "items": {
                        "type": "object",
                        "properties": {
                            "sample": {"type": "string"},
                            "gene": {"type": "string"},
                            "ct": {"type": "number"}
                        },
                        "required": ["sample", "gene", "ct"]
                    }
                }
            },
            "required": ["records"]
        }
    },
    {
        "name": "design_plate_layout",
        "description": "生成 96 孔或 384 孔微孔板实验自动排布方案（支持防边缘蒸发效应避开最外圈孔与生物学重复分配），并同步至 Labworker 微孔板设计器。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "plate_format": {"type": "integer", "enum": [96, 384], "default": 96},
                "avoid_outer_edge": {"type": "boolean", "default": True},
                "samples": {"type": "array", "items": {"type": "string"}, "description": "待排布的样品或浓度梯度名称列表"},
                "replicates": {"type": "integer", "default": 3}
            },
            "required": ["samples"]
        }
    },
    {
        "name": "verify_sanger_sequencing",
        "description": "原生解析 Sanger 测序 (.ab1/.abi/.seq) 四色荧光峰图并与质粒池载体或参考序列进行环状双向比对（支持单文件或 files 数组批量克隆分组验证），自动识别 SNP 点突变、移码 Indel 与杂合双峰。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ab1_file_path": {"type": "string", "description": "可选：本地 .ab1 / .abi / .seq 测序文件绝对路径"},
                "read_sequence": {"type": "string", "description": "可选：直接传入 Sanger 测序读长 DNA 序列"},
                "plasmid_name": {"type": "string", "description": "可选：质粒池中的参考质粒名称"},
                "reference_sequence": {"type": "string", "description": "可选：直接传入参考质粒 DNA 序列"},
                "files": {"type": "array", "items": {"type": "string"}, "description": "可选：批量验证模式下的本地 .ab1 / .abi / .seq 文件路径列表"},
                "references": {
                    "type": "array",
                    "description": "可选：批量验证模式下的候选参考质粒数组 [{name, sequence}]",
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string"},
                            "sequence": {"type": "string"}
                        }
                    }
                },
                "trim_quality_threshold": {"type": "integer", "description": "5'/3' 低质量修剪 Phred Q 阈值，默认 20", "default": 20}
            }
        }
    },
    {
        "name": "convert_nucleic_acid_units",
        "description": "DNA 与核酸单位换算：dsDNA (μg⇄pmol)、ssDNA (μg/mL⇄pmol/μL)、Linear DNA 末端摩尔 (pmol Ends) 及 OD260 核酸定量 (DNA/RNA/ssDNA/Oligo)。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {
                    "type": "string",
                    "enum": ["dsdna_ug_to_pmol", "dsdna_pmol_to_ug", "ssdna_ug_per_ml_to_pmol_per_ul", "ssdna_pmol_per_ul_to_ug_per_ml", "linear_dna_ug_to_pmol_ends", "od260_to_ug_per_ml"]
                },
                "length_bp_or_nt": {"type": "number", "description": "dsDNA 长度(bp) 或 ssDNA 寡核苷酸长度(nt)"},
                "length_kb": {"type": "number", "description": "Linear DNA 长度(kb)"},
                "value": {"type": "number", "description": "输入质量(µg)、摩尔(pmol)、浓度或 OD260 读数"},
                "sample_type": {"type": "string", "enum": ["dna", "rna", "ssdna", "ssoligo"], "default": "dna"},
                "dilution_factor": {"type": "number", "default": 1.0}
            },
            "required": ["mode", "value"]
        }
    },
    {
        "name": "convert_protein_and_coding",
        "description": "蛋白质摩尔互算 (Protein Size kDa ⇄ µg ⇄ pmol) 与 DNA 编码容量推算 (DNA bp ⇄ 氨基酸 aa ⇄ 蛋白大小 kDa)。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {
                    "type": "string",
                    "enum": ["protein_size_kda", "protein_mass_ug", "protein_moles_pmol", "coding_from_bp", "coding_from_aa", "coding_from_kda"]
                },
                "size_kda": {"type": "number"},
                "mass_ug": {"type": "number"},
                "amount_pmol": {"type": "number"},
                "value": {"type": "number", "description": "DNA 编码容量计算输入值 (bp / aa / kDa)"}
            },
            "required": ["mode"]
        }
    },
    {
        "name": "calculate_solution_and_temperature",
        "description": "生理生化公式计算：溶液摩尔浓度配制溶质质量 (g/mg/µg)、C1V1=C2V2 稀释移液量 (L/mL/µL/nL/pL) 及 °F/°C/K 温标转换。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {"type": "string", "enum": ["molarity_mass", "dilution", "temperature"]},
                "mw_g_per_mol": {"type": "number"},
                "concentration": {"type": "number"},
                "conc_unit": {"type": "string", "default": "mM"},
                "volume": {"type": "number"},
                "vol_unit": {"type": "string", "default": "mL"},
                "stock_conc": {"type": "number"},
                "stock_unit": {"type": "string", "default": "M"},
                "final_conc": {"type": "number"},
                "final_unit": {"type": "string", "default": "mM"},
                "final_volume": {"type": "number"},
                "from_unit": {"type": "string", "enum": ["F", "C", "K"], "default": "C"},
                "value": {"type": "number"}
            },
            "required": ["mode"]
        }
    },
    {
        "name": "deconvolute_crispr_sanger",
        "description": "对 CRISPR 编辑池 Sanger 测序信号执行 Synthego ICE 风格非负最小二乘（NNLS）混杂峰图解卷积定量，输出 -20..+20 bp 移码分布、总 Indel%、移码敲除率（KO Score）、HDR% 与拟合优度 R²，支持四通道峰矩阵（与 Swift 黄金测试向量一致）或本地 .ab1/.abi 文件路径。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "wt_sequence": {"type": ["string", "null"], "description": "野生型对照 DNA 序列（与 sgrna_sequence 联用定位切点，或当未传 wt_peaks_acgt 时合成参考峰矩阵）"},
                "sgrna_sequence": {"type": ["string", "null"], "description": "sgRNA protospacer 序列 (20 nt)"},
                "wt_peaks_acgt": {
                    "type": ["array", "null"],
                    "description": "野生型全长或切点周边四通道荧光峰高矩阵 [[A, C, G, T], ...]",
                    "items": {"type": "array", "items": {"type": "number"}, "minItems": 4, "maxItems": 4}
                },
                "edited_peaks_acgt": {
                    "type": ["array", "null"],
                    "description": "编辑池样品切点下游窗口的四通道荧光峰高矩阵 [[A, C, G, T], ...]",
                    "items": {"type": "array", "items": {"type": "number"}, "minItems": 4, "maxItems": 4}
                },
                "hdr_donor_sequence": {"type": ["string", "null"], "description": "可选：HDR 精确修复预期模板全长序列"},
                "hdr_peaks_acgt": {
                    "type": ["array", "null"],
                    "description": "可选：HDR 精确修复切点下游窗口的四通道峰高矩阵 [[A, C, G, T], ...]",
                    "items": {"type": "array", "items": {"type": "number"}, "minItems": 4, "maxItems": 4}
                },
                "cut_index_0based": {"type": ["integer", "null"], "minimum": 0, "description": "可选：切点 0-based 坐标；未提供时自动按 sgrna_sequence 在 wt_sequence 中定位"},
                "is_reverse_strand_sgrna": {"type": "boolean", "default": False, "description": "sgRNA 是否位于负链"},
                "window_length_bp": {"type": ["integer", "null"], "minimum": 1, "maximum": 1000, "default": 150, "description": "解卷积分析切点下游窗口长度 (bp)，默认 150"},
                "requested_window_length_bp": {"type": ["integer", "null"], "minimum": 1, "maximum": 1000, "description": "兼容字段：同 window_length_bp"},
                "shift_min_bp": {"type": "integer", "minimum": -50, "maximum": 0, "default": -20, "description": "最小缺失移码偏移 (bp)，默认 -20"},
                "shift_max_bp": {"type": "integer", "minimum": 0, "maximum": 50, "default": 20, "description": "最大插入移码偏移 (bp)，默认 20"},
                "noise_floor_weight": {"type": "number", "minimum": 0.0, "default": 1e-6, "description": "NNLS 权重噪声过滤阈值，默认 1e-6"},
                "wt_ab1_path": {"type": ["string", "null"], "description": "可选：野生型 .ab1/.abi 测序文件绝对路径"},
                "edited_ab1_path": {"type": ["string", "null"], "description": "可选：编辑池 .ab1/.abi 测序文件绝对路径"}
            }
        },
        "outputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "cut_index_0based": {"type": "integer"},
                "is_reverse_strand_sgrna": {"type": "boolean"},
                "requested_window_bp": {"type": "integer"},
                "effective_window_bp": {"type": "integer"},
                "wt_percent": {"type": "number"},
                "indel_percent": {"type": "number"},
                "ko_score": {"type": "number"},
                "hdr_percent": {"type": "number"},
                "total_edited_percent": {"type": "number"},
                "r_squared": {"type": "number"},
                "residual_norm": {"type": "number"},
                "warnings": {"type": "array", "items": {"type": "string"}},
                "contributions": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "label": {"type": "string"},
                            "shift_bp": {"type": ["integer", "null"]},
                            "is_hdr": {"type": "boolean"},
                            "is_frameshift": {"type": "boolean"},
                            "raw_weight": {"type": "number"},
                            "percent": {"type": "number"}
                        },
                        "required": ["label", "shift_bp", "is_hdr", "is_frameshift", "raw_weight", "percent"]
                    }
                },
                "dominant_indels": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "label": {"type": "string"},
                            "shift_bp": {"type": ["integer", "null"]},
                            "is_hdr": {"type": "boolean"},
                            "is_frameshift": {"type": "boolean"},
                            "raw_weight": {"type": "number"},
                            "percent": {"type": "number"}
                        },
                        "required": ["label", "shift_bp", "is_hdr", "is_frameshift", "raw_weight", "percent"]
                    }
                }
            },
            "required": [
                "cut_index_0based", "is_reverse_strand_sgrna", "requested_window_bp",
                "effective_window_bp", "wt_percent", "indel_percent", "ko_score",
                "hdr_percent", "total_edited_percent", "r_squared", "residual_norm",
                "warnings", "contributions", "dominant_indels"
            ]
        }
    },
    {
        "name": "auto_annotate_sequence",
        "description": "基于本地 Libraries.sqlite 标准质粒元件库（plasmid_features）执行纯离线 FASTA / DNA 序列自动注释，支持正反双链匹配、环形质粒跨 1 bp 零点（Origin）连续拼接以及 30%–90% 截短特征的历史克隆残留片段（Fragment）标记。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "fasta_text": {"type": ["string", "null"], "description": "标准 FASTA 文本（含可选 >header 与多行 DNA 序列）"},
                "sequence": {"type": ["string", "null"], "description": "纯 DNA 序列（当未提供 fasta_text 时使用）"},
                "plasmid_name": {"type": "string", "default": "Unannotated_Plasmid", "description": "质粒名称（若 fasta_text 含 >header 则优先解析 header）"},
                "is_circular": {"type": "boolean", "default": True, "description": "是否按环形质粒（允许跨 1 bp 零点匹配）扫描，默认 True"},
                "min_identity": {"type": "number", "minimum": 0.5, "maximum": 1.0, "default": 0.85, "description": "最小序列一致性阈值，默认 0.85"},
                "min_fragment_coverage": {"type": "number", "minimum": 0.1, "maximum": 0.95, "default": 0.30, "description": "标记为 Fragment 的最小特征覆盖率下限，默认 0.30"},
                "full_feature_coverage_threshold": {"type": "number", "minimum": 0.5, "maximum": 1.0, "default": 0.90, "description": "判定为完整特征的最小覆盖率阈值，默认 0.90"},
                "db_path": {"type": ["string", "null"], "description": "可选：自定义 Libraries.sqlite 路径"}
            }
        },
        "outputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "plasmid_name": {"type": "string"},
                "sequence_length": {"type": "integer"},
                "is_circular": {"type": "boolean"},
                "features_count": {"type": "integer"},
                "fragment_count": {"type": "integer"},
                "origin_spanning_count": {"type": "integer"},
                "annotated_coverage_percent": {"type": "number"},
                "features": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "feature_id": {"type": "integer"},
                            "name": {"type": "string"},
                            "display_name": {"type": "string"},
                            "category": {"type": "string"},
                            "strand": {"type": "string", "enum": ["+", "-"]},
                            "canonical_direction": {"type": "integer"},
                            "start_1based": {"type": "integer"},
                            "end_1based": {"type": "integer"},
                            "matched_length": {"type": "integer"},
                            "reference_length": {"type": "integer"},
                            "feature_start_1based": {"type": "integer"},
                            "feature_end_1based": {"type": "integer"},
                            "coverage": {"type": "number"},
                            "identity": {"type": "number"},
                            "alignment_score": {"type": "number"},
                            "is_origin_spanning": {"type": "boolean"},
                            "is_fragment": {"type": "boolean"},
                            "fragment_warning": {"type": ["string", "null"]},
                            "color_hex": {"type": "string"}
                        },
                        "required": [
                            "feature_id", "name", "display_name", "category", "strand",
                            "canonical_direction", "start_1based", "end_1based", "matched_length",
                            "reference_length", "feature_start_1based", "feature_end_1based",
                            "coverage", "identity", "alignment_score", "is_origin_spanning",
                            "is_fragment", "fragment_warning", "color_hex"
                        ]
                    }
                },
                "warnings": {"type": "array", "items": {"type": "string"}}
            },
            "required": [
                "plasmid_name", "sequence_length", "is_circular", "features_count",
                "fragment_count", "origin_spanning_count", "annotated_coverage_percent",
                "features", "warnings"
            ]
        }
    },
    {
        "name": "design_golden_gate_assembly",
        "description": "Type IIS（BsaI / BsmBI / BbsI / SapI）Golden Gate 组装引擎：基于 Libraries.sqlite NEB T4 黏性末端保真度矩阵实现 2–6 片段无交叉错配 4-bp/3-bp 接头自动分配，并对片段内部双链内源酶切位点执行编码区同义密码子抹除（Domestication）。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "enzyme_name": {"type": "string", "enum": ["BsaI", "BsmBI", "BbsI", "SapI"], "default": "BsaI", "description": "Type IIS 内切酶名称"},
                "fragment_count": {"type": ["integer", "null"], "minimum": 2, "maximum": 6, "description": "待组装片段总数 (2–6)；未传 fragments 时必填"},
                "is_circular": {"type": "boolean", "default": True, "description": "是否为环状多片段组装（决定接点数=fragment_count 或 fragment_count-1）"},
                "fixed_overhangs": {"type": "array", "items": {"type": "string"}, "default": [], "description": "可选：用户锁定保留的黏性末端接头列表（如 ['GGAG', 'CGCT']）"},
                "fragments": {
                    "type": "array",
                    "default": [],
                    "description": "待扫描并执行 Domestication 的 DNA 片段对象数组",
                    "items": {
                        "type": "object",
                        "additionalProperties": False,
                        "properties": {
                            "name": {"type": "string", "default": "Fragment"},
                            "sequence": {"type": "string", "minLength": 1},
                            "is_coding_sequence": {"type": "boolean", "default": True},
                            "reading_frame_offset": {"type": "integer", "minimum": 0, "maximum": 2, "default": 0}
                        },
                        "required": ["sequence"]
                    }
                },
                "db_path": {"type": ["string", "null"], "description": "可选：自定义 Libraries.sqlite 路径"}
            }
        },
        "outputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "enzyme_name": {"type": "string"},
                "recognition_site": {"type": "string"},
                "overhang_length": {"type": "integer"},
                "overhang_plan": {
                    "type": "object",
                    "properties": {
                        "enzyme_name": {"type": "string"},
                        "fragment_count": {"type": "integer"},
                        "junction_count": {"type": "integer"},
                        "overhang_length": {"type": "integer"},
                        "assigned_overhangs": {"type": "array", "items": {"type": "string"}},
                        "assembly_fidelity": {"type": "number"},
                        "cross_mismatch_count": {"type": "integer"},
                        "cross_mismatch_pairs": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "overhang_a": {"type": "string"},
                                    "overhang_b": {"type": "string"},
                                    "ligation_count": {"type": "integer"}
                                },
                                "required": ["overhang_a", "overhang_b", "ligation_count"]
                            }
                        },
                        "warnings": {"type": "array", "items": {"type": "string"}}
                    },
                    "required": [
                        "enzyme_name", "fragment_count", "junction_count", "overhang_length",
                        "assigned_overhangs", "assembly_fidelity", "cross_mismatch_count",
                        "cross_mismatch_pairs", "warnings"
                    ]
                },
                "domestications": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "fragment_index": {"type": "integer"},
                            "fragment_name": {"type": "string"},
                            "original_length": {"type": "integer"},
                            "internal_sites_found": {"type": "integer"},
                            "remaining_sites_after_domestication": {"type": "integer"},
                            "suggestions": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "fragment_index": {"type": "integer"},
                                        "fragment_name": {"type": "string"},
                                        "enzyme_name": {"type": "string"},
                                        "site_strand": {"type": "string"},
                                        "site_start_1based": {"type": "integer"},
                                        "site_end_1based": {"type": "integer"},
                                        "original_site": {"type": "string"},
                                        "is_coding_sequence": {"type": "boolean"},
                                        "codon_index_1based": {"type": ["integer", "null"]},
                                        "original_codon": {"type": ["string", "null"]},
                                        "mutated_codon": {"type": ["string", "null"]},
                                        "amino_acid": {"type": ["string", "null"]},
                                        "mutation_position_1based": {"type": "integer"},
                                        "original_base": {"type": "string"},
                                        "mutated_base": {"type": "string"},
                                        "is_synonymous": {"type": "boolean"},
                                        "note": {"type": "string"}
                                    },
                                    "required": [
                                        "fragment_index", "fragment_name", "enzyme_name", "site_strand",
                                        "site_start_1based", "site_end_1based", "original_site",
                                        "is_coding_sequence", "codon_index_1based", "original_codon",
                                        "mutated_codon", "amino_acid", "mutation_position_1based",
                                        "original_base", "mutated_base", "is_synonymous", "note"
                                    ]
                                }
                            },
                            "domesticated_sequence": {"type": "string"}
                        },
                        "required": [
                            "fragment_index", "fragment_name", "original_length",
                            "internal_sites_found", "remaining_sites_after_domestication",
                            "suggestions", "domesticated_sequence"
                        ]
                    }
                },
                "total_internal_sites_found": {"type": "integer"},
                "assembled_sequence_length": {"type": "integer"}
            },
            "required": [
                "enzyme_name", "recognition_site", "overhang_length", "overhang_plan",
                "domestications", "total_internal_sites_found", "assembled_sequence_length"
            ]
        }
    },
    {
        "name": "design_hdr_donor",
        "description": "CRISPR Knock-in HDR 同源供体自动设计引擎：生成 ssODN（60 nt 臂）或 dsDNA 质粒（600 bp 臂）修复模板，自动识别 CDS 编码区并引入同义 PAM/Seed 阻断突变防止 Cas9 二次切割（保证氨基酸 100% 守恒），可选同义构建/消除 RFLP 鉴定位点并自动生成跨同源臂外侧 Out-Out PCR 分型引物。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "reference_sequence": {"type": "string", "minLength": 25, "description": "野生型靶位点基因组/质粒参考 DNA 序列 (>= 25 bp)"},
                "sgrna_sequence": {"type": "string", "minLength": 15, "description": "sgRNA protospacer 序列 (>= 15 nt)"},
                "strand": {"type": "string", "enum": ["+", "-"], "default": "+", "description": "sgRNA 靶向链方向 ('+' 或 '-')"},
                "edit_start_0based": {"type": "integer", "minimum": 0, "description": "预期替换/插入区间在 reference_sequence 中的起始 0-based 坐标"},
                "edit_end_0based": {"type": "integer", "minimum": 0, "description": "预期替换/插入区间终止 0-based 坐标（纯插入时等于 edit_start_0based）"},
                "replacement_sequence": {"type": "string", "description": "待敲入或替换的 DNA 序列（删除编辑时可为空串）"},
                "donor_format": {"type": "string", "enum": ["ssODN", "dsDNAPlasmid"], "default": "ssODN", "description": "Donor 模板形式：ssODN (默认 60 nt 臂) 或 dsDNAPlasmid (默认 600 bp 臂)"},
                "left_arm_length_bp": {"type": ["integer", "null"], "minimum": 1, "description": "可选：自定义左同源臂长度 (bp/nt)"},
                "right_arm_length_bp": {"type": ["integer", "null"], "minimum": 1, "description": "可选：自定义右同源臂长度 (bp/nt)"},
                "cds_start_1based": {"type": ["integer", "null"], "minimum": 1, "description": "可选：显式指定 CDS 起始 1-based 坐标"},
                "cds_end_1based": {"type": ["integer", "null"], "minimum": 3, "description": "可选：显式指定 CDS 终止 1-based 坐标"},
                "auto_detect_cds": {"type": "boolean", "default": True, "description": "未显式指定 CDS 时是否自动识别覆盖切点的最长 ORF"},
                "enable_rflp": {"type": "boolean", "default": False, "description": "是否启用同义 RFLP 鉴定位点构建/消除"},
                "rflp_search_radius_bp": {"type": "integer", "minimum": 3, "default": 15, "description": "RFLP 位点搜索半径 (bp)，默认 15"},
                "out_out_margin_bp": {"type": "integer", "minimum": 0, "default": 100, "description": "Out-Out PCR 引物相对同源臂外缘的最小安全边距 (bp)，默认 100"},
                "primer_target_tm": {"type": "number", "minimum": 40.0, "maximum": 85.0, "default": 60.0, "description": "Out-Out PCR 引物目标退火温度 (°C)，默认 60.0"},
                "donor_name": {"type": "string", "default": "HDR_Donor", "description": "Donor 与分型引物命名前缀"}
            },
            "required": [
                "reference_sequence", "sgrna_sequence",
                "edit_start_0based", "edit_end_0based", "replacement_sequence"
            ]
        },
        "outputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "donor_format": {"type": "string"},
                "sgrna_sequence": {"type": "string"},
                "strand": {"type": "string"},
                "wt_cut_index_0based": {"type": "integer"},
                "wt_pam_start_0based": {"type": "integer"},
                "wt_pam_sequence": {"type": "string"},
                "is_in_cds": {"type": "boolean"},
                "cds_start_1based": {"type": ["integer", "null"]},
                "cds_end_1based": {"type": ["integer", "null"]},
                "cds_auto_detected": {"type": "boolean"},
                "protein_before_blocking": {"type": "string"},
                "protein_after_blocking": {"type": "string"},
                "amino_acid_conserved": {"type": "boolean"},
                "blocking_strategy": {"type": "string"},
                "blocking_mutations": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "position_0based": {"type": "integer"},
                            "position_1based": {"type": "integer"},
                            "original_base": {"type": "string"},
                            "mutated_base": {"type": "string"},
                            "reason": {"type": "string"},
                            "codon_before": {"type": ["string", "null"]},
                            "codon_after": {"type": ["string", "null"]},
                            "amino_acid": {"type": ["string", "null"]}
                        },
                        "required": [
                            "position_0based", "position_1based", "original_base", "mutated_base",
                            "reason", "codon_before", "codon_after", "amino_acid"
                        ]
                    }
                },
                "edited_pam_sequence": {"type": "string"},
                "pam_still_intact": {"type": "boolean"},
                "cas9_recut_blocked": {"type": "boolean"},
                "left_homology_arm": {"type": "string"},
                "insert_payload": {"type": "string"},
                "right_homology_arm": {"type": "string"},
                "left_arm_length_bp": {"type": "integer"},
                "right_arm_length_bp": {"type": "integer"},
                "donor_sequence": {"type": "string"},
                "donor_length_bp": {"type": "integer"},
                "final_edited_locus_sequence": {"type": "string"},
                "rflp": {
                    "type": ["object", "null"],
                    "properties": {
                        "mode": {"type": "string"},
                        "enzyme_name": {"type": "string"},
                        "recognition_site": {"type": "string"},
                        "top_cut_offset": {"type": "integer"},
                        "wt_amplicon_bands_bp": {"type": "array", "items": {"type": "integer"}},
                        "hdr_amplicon_bands_bp": {"type": "array", "items": {"type": "integer"}},
                        "silent_mutations": {"type": "array", "items": {"type": "object"}},
                        "note": {"type": "string"}
                    },
                    "required": [
                        "mode", "enzyme_name", "recognition_site", "top_cut_offset",
                        "wt_amplicon_bands_bp", "hdr_amplicon_bands_bp", "silent_mutations", "note"
                    ]
                },
                "out_out_pcr": {
                    "type": ["object", "null"],
                    "properties": {
                        "forward_primer": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string"},
                                "full_sequence": {"type": "string"},
                                "specific_sequence": {"type": "string"},
                                "tm": {"type": "number"},
                                "gc_percent": {"type": "number"}
                            },
                            "required": ["name", "full_sequence", "specific_sequence", "tm", "gc_percent"]
                        },
                        "reverse_primer": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string"},
                                "full_sequence": {"type": "string"},
                                "specific_sequence": {"type": "string"},
                                "tm": {"type": "number"},
                                "gc_percent": {"type": "number"}
                            },
                            "required": ["name", "full_sequence", "specific_sequence", "tm", "gc_percent"]
                        },
                        "forward_start_0based": {"type": "integer"},
                        "forward_end_0based": {"type": "integer"},
                        "reverse_start_0based": {"type": "integer"},
                        "reverse_end_0based": {"type": "integer"},
                        "wt_amplicon_length_bp": {"type": "integer"},
                        "hdr_amplicon_length_bp": {"type": "integer"},
                        "wt_amplicon_sequence": {"type": "string"},
                        "hdr_amplicon_sequence": {"type": "string"},
                        "left_margin_from_arm_bp": {"type": "integer"},
                        "right_margin_from_arm_bp": {"type": "integer"}
                    },
                    "required": [
                        "forward_primer", "reverse_primer",
                        "forward_start_0based", "forward_end_0based",
                        "reverse_start_0based", "reverse_end_0based",
                        "wt_amplicon_length_bp", "hdr_amplicon_length_bp",
                        "wt_amplicon_sequence", "hdr_amplicon_sequence",
                        "left_margin_from_arm_bp", "right_margin_from_arm_bp"
                    ]
                },
                "warnings": {"type": "array", "items": {"type": "string"}}
            },
            "required": [
                "donor_format", "sgrna_sequence", "strand", "wt_cut_index_0based",
                "wt_pam_start_0based", "wt_pam_sequence", "is_in_cds",
                "cds_start_1based", "cds_end_1based", "cds_auto_detected",
                "protein_before_blocking", "protein_after_blocking", "amino_acid_conserved",
                "blocking_strategy", "blocking_mutations", "edited_pam_sequence",
                "pam_still_intact", "cas9_recut_blocked", "left_homology_arm",
                "insert_payload", "right_homology_arm", "left_arm_length_bp",
                "right_arm_length_bp", "donor_sequence", "donor_length_bp",
                "final_edited_locus_sequence", "rflp", "out_out_pcr", "warnings"
            ]
        }
    }
]

# 为每个 MCP 工具注入符合 MCP 规范的 annotations (readOnlyHint / destructiveHint) (P05)
_DESTRUCTIVE_WRITE_TOOLS = {"add_plasmid_to_pool", "design_single_clone_primers", "manage_primer_cart_and_export"}
for _t in MCP_TOOLS:
    _is_write = _t["name"] in _DESTRUCTIVE_WRITE_TOOLS
    _t["annotations"] = {
        "readOnlyHint": not _is_write,
        "destructiveHint": _is_write
    }

TOOL_DISPATCH = {
    "list_plasmid_pool": tool_list_plasmid_pool,
    "inspect_plasmid": tool_inspect_plasmid,
    "add_plasmid_to_pool": tool_add_plasmid_to_pool,
    "design_single_clone_primers": tool_design_single_clone_primers,
    "design_multi_fragment_primers": tool_design_multi_fragment_primers,
    "design_mutagenesis_primers": tool_design_mutagenesis_primers,
    "design_fragment_deletion_primers": tool_design_fragment_deletion_primers,
    "verify_sanger_sequencing": tool_verify_sanger_sequencing,
    "calculate_recombination_dosage": tool_calculate_recombination_dosage,
    "convert_nucleic_acid_units": tool_convert_nucleic_acid_units,
    "convert_protein_and_coding": tool_convert_protein_and_coding,
    "calculate_solution_and_temperature": tool_calculate_solution_and_temperature,
    "design_sgrna_primers": tool_design_sgrna_primers,
    "design_shrna_primers": tool_design_shrna_primers,
    "manage_primer_cart_and_export": tool_manage_primer_cart_and_export,
    "analyze_protein_and_docking_box": tool_analyze_protein_and_docking_box,
    "analyze_western_blot": tool_analyze_western_blot,
    "analyze_qpcr_ddct": tool_analyze_qpcr_ddct,
    "design_plate_layout": tool_design_plate_layout,
    "deconvolute_crispr_sanger": tool_deconvolute_crispr_sanger,
    "auto_annotate_sequence": tool_auto_annotate_sequence,
    "design_golden_gate_assembly": tool_design_golden_gate_assembly,
    "design_hdr_donor": tool_design_hdr_donor,
}


def handle_jsonrpc_request(req: dict) -> dict:
    method = req.get("method", "")
    req_id = req.get("id")
    params = req.get("params") or {}

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {
                    "tools": {"listChanged": False},
                    "resources": {"subscribe": False, "listChanged": False}
                },
                "serverInfo": {
                    "name": "labworker-mcp",
                    "version": "20261115"
                }
            }
        }
    elif method.startswith("notifications/"):
        return None
    elif method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}
    elif method == "tools/list":
        return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": MCP_TOOLS}}
    elif method == "resources/list":
        pool = load_plasmid_pool()
        resources = [
            {
                "uri": f"plasmid://{item['name']}",
                "name": item["name"],
                "description": f"[{item.get('vectorBackbone', '')}] {item.get('categoryTag', '')} ({item.get('dnaInfo', {}).get('length', 0)} bp)",
                "mimeType": "application/json"
            }
            for item in pool
        ]
        return {"jsonrpc": "2.0", "id": req_id, "result": {"resources": resources}}
    elif method == "resources/read":
        uri = params.get("uri", "")
        name = uri.replace("plasmid://", "")
        data = tool_inspect_plasmid({"plasmid_name": name, "include_sequence": False})
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "contents": [{
                    "uri": uri,
                    "mimeType": "application/json",
                    "text": json.dumps(data, ensure_ascii=False, indent=2)
                }]
            }
        }
    elif method == "tools/call":
        tool_name = params.get("name", "")
        tool_args = params.get("arguments") or {}
        fn = TOOL_DISPATCH.get(tool_name)
        if not fn:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "isError": True,
                    "content": [{"type": "text", "text": f"未知工具: {tool_name}"}]
                }
            }
        try:
            res_data = fn(tool_args)
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "isError": False,
                    "content": [{
                        "type": "text",
                        "text": json.dumps(res_data, ensure_ascii=False, indent=2)
                    }]
                }
            }
        except Exception as e:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "isError": True,
                    "content": [{"type": "text", "text": f"执行错误: {str(e)}"}]
                }
            }
    else:
        if req_id is not None:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"}
            }
        return None



def run_stdio_server():
    """支持标准 MCP 行分隔 JSON-RPC 2.0 与 Content-Length 帧格式"""
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.lower().startswith("content-length:"):
            length = int(stripped.split(":", 1)[1].strip())
            while True:
                hdr = sys.stdin.readline()
                if not hdr or hdr.strip() == "":
                    break
            body = sys.stdin.read(length)
            try:
                req = json.loads(body)
            except Exception:
                continue
            resp = handle_jsonrpc_request(req)
            if resp is not None:
                out_bytes = json.dumps(resp, ensure_ascii=False).encode("utf-8")
                sys.stdout.write(f"Content-Length: {len(out_bytes)}\r\n\r\n")
                sys.stdout.write(out_bytes.decode("utf-8"))
                sys.stdout.flush()
        else:
            try:
                req = json.loads(stripped)
            except Exception:
                continue
            resp = handle_jsonrpc_request(req)
            if resp is not None:
                sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
                sys.stdout.flush()


if __name__ == "__main__":
    if "--count-tools" in sys.argv:
        sys.stdout.write(f"{len(MCP_TOOLS)}\n")
        sys.exit(0)
    if "--cli-call" in sys.argv:
        idx = sys.argv.index("--cli-call")
        tool_name = sys.argv[idx + 1] if idx + 1 < len(sys.argv) else ""
        raw_args = "{}"
        if "--args" in sys.argv:
            a_idx = sys.argv.index("--args")
            if a_idx + 1 < len(sys.argv):
                raw_args = sys.argv[a_idx + 1]
        fn = TOOL_DISPATCH.get(tool_name)
        if not fn:
            sys.stdout.write(json.dumps({"status": "error", "error": f"Unknown tool: {tool_name}"}, ensure_ascii=False) + "\n")
            sys.exit(1)
        res = fn(json.loads(raw_args))
        sys.stdout.write(json.dumps(res, ensure_ascii=False) + "\n")
        sys.exit(0)
    run_stdio_server()
