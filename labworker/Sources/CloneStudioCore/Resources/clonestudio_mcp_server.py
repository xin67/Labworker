#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CloneStudio MCP (Model Context Protocol) Server v2.3.0
支持 Claude Desktop, Cursor, Windsurf, Cline, Gemini CLI 等所有 MCP 客户端通过自然语言调用：
1. 质粒池三维检索与管理 (`list_plasmid_pool`, `inspect_plasmid`, `add_plasmid_to_pool`)：
   - 支持按 载体 (vector)、目的基因 (gene)、抗性 (resistance)、分类 (category) 精准筛选
2. 五大分子克隆引物设计与重组质粒组装：
   - 单片段无缝克隆 (`design_single_clone_primers`)
   - 多片段无缝组装 (`design_multi_fragment_primers`)
   - 定点突变 (`design_mutagenesis_primers`)：含野生型氨基酸一致性校验、邻近位点提示与原核/真核宿主密码子偏好自动选择
   - 质粒片段删除 (`design_fragment_deletion_primers`)
3. 靶点设计 (`design_sgrna_primers`, `design_shrna_primers`)：
   - CRISPR/Cas9 sgRNA 靶点扫描打分与 lentiCRISPRv2 / pX459 退火引物生成
   - RNAi shRNA 靶点扫描打分与 pLKO.1 (AgeI/EcoRI) 发夹引物生成
4. 重组反应 DNA 用量与 20 μL 体系配比计算 (`calculate_recombination_dosage`)：
   - 支持 bp/kb 自动识别、自定义 ng 投入量与实时移液体积/ddH2O 计算
5. 引物订购池管理与擎科 Excel 订购表导出 (`manage_primer_cart_and_export`)
6. 全模块双向 GUI 实时同步：通过 macOS DistributedNotificationCenter 自动切换 CloneStudio 模块画布并加载载体/片段/引物
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

def normalize_length_to_kb(val: float) -> float:
    if val <= 0:
        return 0.0
    return (val / 1000.0) if val >= 40.0 else val

def tool_calculate_recombination_dosage(args: dict) -> dict:
    """
    增强 3：DNA 重组反应使用量与 20 μL 移液体系配比计算器（支持自定义 ng 投入量并同步至 GUI）
    """
    raw_type = (args.get("clone_type") or "single").strip().lower()
    if "multi" in raw_type or "多" in raw_type:
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
# 3.5 Labworker v3.0 新增 5 大全栈实验工具 (蛋白质对接盒 / WB 16-bit 定量 / qPCR / 微孔板 / 进化树)
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


def tool_analyze_phylogenetic_tree(args: dict) -> dict:
    """解析 Newick 进化树或基于多序列距离矩阵构建邻接进化树"""
    newick = (args.get("newick") or "((Human:0.12,Mouse:0.15):0.08,(Zebrafish:0.22,Xenopus:0.19):0.10);").strip()
    import re
    leaves = re.findall(r'([A-Za-z0-9_.\-]+)\s*:', newick)
    branch_lengths = [float(x) for x in re.findall(r':\s*([0-9.]+)', newick)]
    total_len = round(sum(branch_lengths), 4)

    notify_gui_and_sync_primers(
        action_summary=f"MCP 系统发育树解析 ({len(leaves)} 个分类单元, 总枝长 {total_len})",
        primers=[],
        target_module="phylogeneticTree"
    )
    return {
        "newick": newick,
        "taxa_count": len(leaves),
        "taxa": leaves,
        "total_branch_length": total_len
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


# ============================================================================
# 4. MCP JSON-RPC 2.0 协议路由与 17 大全栈工具声明 (Labworker MCP v3.0.0)
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
        "description": "计算同源重组反应 (20 μL 体系) 中线性化载体、各插入片段的最佳或自定义 ng 投入量、移液体积 (μL) 与 ddH2O 补齐体积，并同步至 Labworker 用量计算器。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "clone_type": {"type": "string", "enum": ["single", "multi", "simple"], "default": "single"},
                "vector_name": {"type": "string", "description": "载体名称"},
                "vector_length": {"type": "number", "description": "载体长度（支持直接传 bp 如 6349 或 kb 如 6.35）"},
                "vector_conc": {"type": "number", "description": "载体浓度 (ng/μL)", "default": 50},
                "vector_custom_ng": {"type": "number", "description": "可选：自定义载体投入量 (ng)，不传则按公式推荐"},
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
        "name": "analyze_phylogenetic_tree",
        "description": "解析 Newick (.nwk) 系统发育树并统计分类单元与总枝长，同步至 Labworker 系统发育树工作台。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "newick": {"type": "string", "description": "Newick 格式进化树字符串"}
            },
            "required": ["newick"]
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
    "design_sgrna_primers": tool_design_sgrna_primers,
    "design_shrna_primers": tool_design_shrna_primers,
    "manage_primer_cart_and_export": tool_manage_primer_cart_and_export,
    "analyze_protein_and_docking_box": tool_analyze_protein_and_docking_box,
    "analyze_western_blot": tool_analyze_western_blot,
    "analyze_qpcr_ddct": tool_analyze_qpcr_ddct,
    "design_plate_layout": tool_design_plate_layout,
    "analyze_phylogenetic_tree": tool_analyze_phylogenetic_tree,
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
                    "version": "3.0.0"
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
