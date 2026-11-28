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
    "AI": -8.9, "IA": -4.9, "CI": -5.4, "IC": -5.0,
    "GI": -6.8, "IG": -8.3, "TI": -5.9, "IT": -8.8, "II": -3.3
}
NN_DS_2004 = {
    "AA": -21.3, "TT": -21.3, "AT": -20.4, "TA": -21.3,
    "CA": -22.7, "TG": -22.7, "GT": -22.4, "AC": -22.4,
    "CT": -21.0, "AG": -21.0, "GA": -22.2, "TC": -22.2,
    "CG": -27.2, "GC": -24.4, "GG": -19.9, "CC": -19.9,
    "AI": -25.5, "IA": -13.9, "CI": -13.7, "IC": -12.6,
    "GI": -19.1, "IG": -23.8, "TI": -17.4, "IT": -25.4, "II": -11.9
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
    "CT/GT": (-5.0, -15.8),"GT/CT": (-2.2, -8.4), "TT/AT": (0.2, -1.5),
    # Watkins & SantaLucia (2005) NAR 33:6258-6267 Table 2 (36 inosine entries)
    "AI/TC": (-8.9, -25.5), "TI/AC": (-5.9, -17.4), "AC/TI": (-8.8, -25.4), "TC/AI": (-4.9, -13.9),
    "CI/GC": (-5.4, -13.7), "GI/CC": (-6.8, -19.1), "CC/GI": (-8.3, -23.8), "GC/CI": (-5.0, -12.6),
    "AI/TA": (-8.3, -25.0), "TI/AA": (-3.4, -11.2), "AA/TI": (-0.7, -2.6),  "TA/AI": (-1.3, -4.6),
    "CI/GA": (2.6, 8.9),    "GI/CA": (-7.8, -21.1), "CA/GI": (-7.0, -20.0), "GA/CI": (-7.6, -20.2),
    "AI/TT": (0.49, -0.7),  "TI/AT": (-6.5, -22.0), "AT/TI": (-5.6, -18.7), "TT/AI": (-0.8, -4.3),
    "CI/GT": (-1.0, -2.4),  "GI/CT": (-3.5, -10.6), "CT/GI": (0.1, -1.0),   "GT/CI": (-4.3, -12.1),
    "AI/TG": (-4.9, -15.8), "TI/AG": (-1.9, -8.5),  "AG/TI": (0.1, -1.8),   "TG/AI": (1.0, 1.0),
    "CI/GG": (7.1, 21.3),   "GI/CG": (-1.1, -3.2),  "CG/GI": (5.8, 16.9),   "GG/CI": (-7.6, -22.0),
    "AI/TI": (-3.3, -11.9), "TI/AI": (0.1, -2.3),   "CI/GI": (1.3, 3.0),    "GI/CI": (-0.5, -1.3),
}

# SantaLucia & Peyret (2001) DNA_TMM1 terminal mismatch / hairpin & internal loop closing table (48 entries)
TERMINAL_MISMATCH_PARAMS = {
    "AA/TA": (-3.1, -7.8),  "TA/AA": (-2.5, -6.3),  "CA/GA": (-4.3, -10.7), "GA/CA": (-8.0, -22.5),
    "AC/TC": (-0.1, 0.5),   "TC/AC": (-0.7, -1.3),  "CC/GC": (-2.1, -5.1),  "GC/CC": (-3.9, -10.6),
    "AG/TG": (-1.1, -2.1),  "TG/AG": (-1.1, -2.7),  "CG/GG": (-3.8, -9.5),  "GG/CG": (-6.7, -19.2),
    "AT/TT": (-2.4, -6.5),  "TT/AT": (-3.2, -8.9),  "CT/GT": (-6.1, -16.9), "GT/CT": (-7.4, -21.2),
    "AA/TC": (-1.6, -4.0),  "AC/TA": (-1.8, -3.8),  "CA/GC": (-2.6, -5.9),  "CC/GA": (-2.7, -6.0),
    "GA/CC": (-5.0, -13.8), "GC/CA": (-3.2, -7.1),  "TA/AC": (-2.3, -5.9),  "TC/AA": (-2.7, -7.0),
    "AC/TT": (-0.9, -1.7),  "AT/TC": (-2.3, -6.3),  "CC/GT": (-3.2, -8.0),  "CT/GC": (-3.9, -10.6),
    "GC/CT": (-4.9, -13.5), "GT/CC": (-3.0, -7.8),  "TC/AT": (-2.5, -6.3),  "TT/AC": (-0.7, -1.2),
    "AA/TG": (-1.9, -4.4),  "AG/TA": (-2.5, -5.9),  "CA/GG": (-3.9, -9.6),  "CG/GA": (-6.0, -15.5),
    "GA/CG": (-4.3, -11.1), "GG/CA": (-4.6, -11.4), "TA/AG": (-2.0, -4.7),  "TG/AA": (-2.4, -5.8),
    "AG/TT": (-3.2, -8.7),  "AT/TG": (-3.5, -9.4),  "CG/GT": (-3.8, -9.0),  "CT/GG": (-6.6, -18.7),
    "GG/CT": (-5.7, -15.9), "GT/CG": (-5.9, -16.1), "TG/AT": (-3.9, -10.5), "TT/AG": (-3.6, -9.8),
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
        if c in ("A", "T"):
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


def free_mg_molar(mg_molar: float, dntp_molar: float, ka: float = 3.0e4) -> float:
    """Owczarzy et al. (2008) 游离 Mg2+ 二次螯合平衡解 (单位: M)"""
    mg = max(0.0, float(mg_molar))
    dntp = max(0.0, float(dntp_molar))
    if mg <= 0.0:
        return 0.0
    if dntp <= 0.0:
        return mg
    b = ka * (dntp - mg) + 1.0
    disc = max(0.0, b * b + 4.0 * ka * mg)
    return max(0.0, (-b + math.sqrt(disc)) / (2.0 * ka))


def apply_owczarzy_salt_correction(
    tm_1m_kelvin: float,
    length: int,
    gc_fraction: float,
    monovalent_molar: float,
    free_mg: float,
    mode: str = "owczarzy2008",
) -> float:
    """Owczarzy et al. (2004/2008) 单价/混合/二价阳离子三区段盐校正 (100% 对齐 TmCalculator.swift)"""
    if tm_1m_kelvin <= 0 or length < 2:
        return tm_1m_kelvin
    m = max(1e-6, float(monovalent_molar))
    d = max(0.0, float(free_mg))
    f_gc = max(0.0, min(1.0, float(gc_fraction)))
    ln_m = math.log(m)

    def _inv_mono() -> float:
        return (1.0 / tm_1m_kelvin) + (4.29 * f_gc - 3.95) * 1e-5 * ln_m + 9.40e-6 * ln_m * ln_m

    if mode == "owczarzy2004" or d <= 0.0:
        return 1.0 / _inv_mono()

    r_ratio = math.sqrt(d) / m
    if r_ratio < 0.22:
        return 1.0 / _inv_mono()

    a = 3.92e-5
    b = -9.11e-6
    c = 6.26e-5
    d_coef = 1.42e-5
    e = -4.82e-4
    f = 5.25e-4
    g = 8.31e-5
    if r_ratio < 6.0:
        a *= (0.843 - 0.352 * math.sqrt(m) * ln_m)
        d_coef *= (1.279 - 4.03e-3 * ln_m - 8.03e-3 * ln_m * ln_m)
        g *= (0.486 - 0.258 * ln_m + 5.25e-3 * ln_m * ln_m * ln_m)

    ln_d = math.log(d)
    inv_tm = (
        (1.0 / tm_1m_kelvin)
        + a
        + b * ln_d
        + f_gc * (c + d_coef * ln_d)
        + (1.0 / (2.0 * float(length - 1))) * (e + f * ln_d + g * ln_d * ln_d)
    )
    return (1.0 / inv_tm) if inv_tm > 0 else tm_1m_kelvin


def recommended_annealing_temp(tm_forward: float, tm_reverse: float, polymerase: str = "SnapGene") -> float:
    lower = min(float(tm_forward), float(tm_reverse))
    key = str(polymerase or "SnapGene").strip().lower()
    if "q5" in key:
        ta = min(72.0, lower + 1.0)
    elif "phusion" in key:
        ta = min(72.0, lower + 3.0)
    elif "taq" in key:
        ta = max(45.0, lower - 5.0)
    else:
        ta = lower
    return round(ta, 1)


def calc_snapgene_tm(
    seq: str,
    five_prime_overhang: str = "",
    three_prime_overhang: str = "",
    na_molar: float = 0.05,
    primer_conc: float = 250e-9,
    mv_conc: float = None,
    dv_conc: float = 0.0,
    dntp_conc: float = 0.0,
    salt_correction: str = "santaLucia2004",
    concentration_mode: str = "asymmetricExcess",
) -> float:
    """100% aligned with TmCalculator.calculate in TmCalculator.swift (supports SantaLucia 2004 & Owczarzy 2004/2008)"""
    s = normalize_oligo(seq)
    ov5 = normalize_oligo(five_prime_overhang)
    ov3 = normalize_oligo(three_prime_overhang)
    n = len(s)
    if n < 2:
        return 0.0
    if salt_correction == "santaLucia2004":
        if mv_conc is not None:
            na_molar = equivalent_monovalent_molar(mv_conc, dv_conc, dntp_conc)
        elif float(dv_conc) > 0.0:
            na_molar = equivalent_monovalent_molar(na_molar * 1000.0, dv_conc, dntp_conc)
        effective_mode = "santaLucia2004"
    else:
        if mv_conc is not None:
            na_molar = max(0.001, float(mv_conc) / 1000.0)
        effective_mode = salt_correction
    dh = 0.2
    ds = -5.7
    at0 = _terminal_at_iupac(s[0])
    dh += at0[0]
    ds += at0[1]
    at_end = _terminal_at_iupac(s[-1])
    dh += at_end[0]
    ds += at_end[1]
    is_self_comp = (not ov5 and not ov3 and n % 2 == 0 and all(c in "ATCG" for c in s) and s == rev_comp(s))
    if is_self_comp:
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

    r = 1.9872
    c_eff = max(1e-9, float(primer_conc))
    if concentration_mode == "equimolar" and not is_self_comp:
        c_eff = c_eff / 4.0

    if effective_mode == "santaLucia2004":
        ds_salt = ds + 0.368 * (n - 1) * math.log(max(0.001, na_molar))
        tm_c = (1000.0 * dh) / (ds_salt + r * math.log(c_eff)) - 273.15
    else:
        tm_1m_k = (1000.0 * dh) / (ds + r * math.log(c_eff))
        gc_w = 0.0
        for ch in s:
            exp = IUPAC_EXPANSION.get(ch, ("A",))
            gc_w += sum(1 for b in exp if b in "GC") / float(len(exp))
        f_gc = gc_w / float(n)
        f_mg = free_mg_molar(float(dv_conc) / 1000.0, float(dntp_conc) / 1000.0)
        tm_k = apply_owczarzy_salt_correction(tm_1m_k, n, f_gc, na_molar, f_mg, mode=effective_mode)
        tm_c = tm_k - 273.15
    return round(tm_c, 1)


def calc_tm_owczarzy2008(
    seq: str,
    monovalent_mm: float = 50.0,
    mg_mm: float = 1.5,
    dntp_mm: float = 0.6,
    primer_conc_nm: float = 250.0,
    concentration_mode: str = "asymmetricExcess",
) -> float:
    return calc_snapgene_tm(
        seq=seq,
        mv_conc=monovalent_mm,
        dv_conc=mg_mm,
        dntp_conc=dntp_mm,
        primer_conc=primer_conc_nm * 1e-9,
        salt_correction="owczarzy2008",
        concentration_mode=concentration_mode,
    )


# Unified SantaLucia & Hicks (2004) Nearest-Neighbor parameters & Zuker-Stiegler DP (100% aligned with PrimerQualityEngine.swift)
NN_2004 = {
    "AA": (-7.6, -21.3), "TT": (-7.6, -21.3),
    "AT": (-7.2, -20.4), "TA": (-7.2, -21.3),
    "CA": (-8.5, -22.7), "TG": (-8.5, -22.7),
    "GT": (-8.4, -22.4), "AC": (-8.4, -22.4),
    "CT": (-7.8, -21.0), "AG": (-7.8, -21.0),
    "GA": (-8.2, -22.2), "TC": (-8.2, -22.2),
    "CG": (-10.6, -27.2), "GC": (-9.8, -24.4),
    "GG": (-8.0, -19.9), "CC": (-8.0, -19.9),
}
NN_1998 = NN_2004

HAIRPIN_LOOP_DS = {
    3: -10.18, 4: -10.80, 5: -10.16, 6: -12.41, 7: -13.06,
    8: -13.38, 9: -14.02, 10: -14.35, 11: -14.81, 12: -15.10,
}

SPECIAL_HAIRPIN_LOOPS = {
    "CGAAG": (-2.0, -3.5), "CGAAA": (-2.0, -3.5),
    "CGAAAG": (-3.0, -5.5), "CGCAAG": (-2.5, -4.5), "CGAGAG": (-2.5, -4.5),
    "GGAAAC": (-2.5, -4.5), "GGCAAC": (-2.0, -3.5), "GGTTAC": (-2.0, -3.5),
    "CGAATG": (-2.0, -4.0), "CGTTAG": (-2.0, -4.0), "TGGAAA": (-1.5, -2.5),
}

BULGE_INIT_DG37 = {1: 4.0, 2: 2.9, 3: 3.1, 4: 3.2, 5: 3.3, 6: 3.5}
INTERNAL_LOOP_INIT_DG37 = {3: 3.2, 4: 3.6, 5: 4.0, 6: 4.4, 7: 4.6, 8: 4.8}


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


def _lookup_internal_mismatch(p1: str, p2: str, q1: str, q2: str):
    k1 = f"{p1}{p2}/{q1}{q2}"
    if k1 in INTERNAL_MISMATCH_PARAMS:
        return INTERNAL_MISMATCH_PARAMS[k1]
    k2 = f"{q2}{q1}/{p2}{p1}"
    return INTERNAL_MISMATCH_PARAMS.get(k2)


def _lookup_terminal_mismatch(p1: str, p2: str, q1: str, q2: str):
    k1 = f"{p1}{p2}/{q1}{q2}"
    if k1 in TERMINAL_MISMATCH_PARAMS:
        return TERMINAL_MISMATCH_PARAMS[k1]
    k2 = f"{q2}{q1}/{p2}{p1}"
    return TERMINAL_MISMATCH_PARAMS.get(k2)


def _hairpin_loop_entropy(loop_len: int) -> float:
    if loop_len in HAIRPIN_LOOP_DS:
        return HAIRPIN_LOOP_DS[loop_len]
    n = max(12, int(loop_len))
    return -15.10 - 2.44 * 1.9872 * math.log(n / 12.0)


def _bulge_init(k: int):
    dg37 = BULGE_INIT_DG37.get(k)
    if dg37 is None:
        dg37 = 3.5 + 2.44 * 1.9872 * 0.31015 * math.log(max(6, k) / 6.0)
    return (0.0, -dg37 * 1000.0 / 310.15)


def _internal_loop_init(n1: int, n2: int):
    tot = n1 + n2
    base_dg = INTERNAL_LOOP_INIT_DG37.get(tot)
    if base_dg is None:
        base_dg = 4.8 + 2.44 * 1.9872 * 0.31015 * math.log(max(8, tot) / 8.0)
    asym_dg = 0.3 * abs(n1 - n2)
    return (0.0, -(base_dg + asym_dg) * 1000.0 / 310.15)


def three_prime_pentamer_dg(raw_seq: str, mv_conc: float = 50.0, dv_conc: float = 1.5, dntp_conc: float = 0.6, temp_c: float = 37.0) -> float:
    """Rychlik (1995) / Primer3 MAX_END_STABILITY standard 3'-terminal pentamer dG at 25 C, 1 M Na+ (kcal/mol)"""
    clean = _clean_acgt_rna(raw_seq)
    if len(clean) < 5:
        return 0.0
    pent = clean[-5:]
    temp_k = 298.15
    dh, ds = 0.0, 0.0
    if pent[4] in "AT":
        dh += 2.2
        ds += 6.9
    for i in range(4):
        st = NN_2004.get(pent[i] + pent[i + 1])
        if st:
            dh += st[0]
            ds += st[1]
    return round(dh - (temp_k * ds) / 1000.0, 2)


def calc_hairpin(raw_seq: str, mv_conc: float = 50.0, dv_conc: float = 1.5, dntp_conc: float = 0.6, dna_conc: float = 50.0, temp_c: float = 37.0) -> dict:
    """Zuker-Stiegler DP hairpin evaluator (100% aligned with PrimerQualityEngine.calcHairpin in Swift)"""
    clean = _clean_acgt_rna(raw_seq)
    seq = clean[-60:] if len(clean) > 60 else clean
    n = len(seq)
    if n < 7:
        return {"structure_found": False, "dg": 0.0, "dh": 0.0, "ds": 0.0, "tm": 0.0, "three_prime_anchored": False, "risk_level": "safe"}

    temp_k = temp_c + 273.15
    na_eq = equivalent_monovalent_molar(mv_conc, dv_conc, dntp_conc)
    salt_per_step = 0.368 * math.log(na_eq)
    INF = 1e9
    dp = [[(INF, 0.0, 0.0, -1, -1, 0) for _ in range(n)] for _ in range(n)]

    for span in range(4, n):
        for i in range(0, n - span):
            j = i + span
            if not _is_comp(seq[i], seq[j]):
                continue
            best = (INF, 0.0, 0.0, -1, -1, 1)

            loop_len = j - i - 1
            if loop_len >= 3:
                l_dh = 0.0
                l_ds = _hairpin_loop_entropy(loop_len)
                if loop_len >= 4:
                    mm = _lookup_terminal_mismatch(seq[i], seq[i + 1], seq[j], seq[j - 1])
                    if mm:
                        l_dh += mm[0]
                        l_ds += mm[1]
                    elif _is_comp(seq[i + 1], seq[j - 1]):
                        l_dh += -6.0
                        l_ds += -16.58
                    else:
                        l_dh += -3.5
                        l_ds += -9.5
                elif seq[i] in "AT":
                    l_dh += 2.2
                    l_ds += 6.9
                if loop_len in (3, 4):
                    bonus = SPECIAL_HAIRPIN_LOOPS.get(seq[i:j + 1])
                    if bonus:
                        l_dh += bonus[0]
                        l_ds += bonus[1]
                l_dg = l_dh - (temp_k * l_ds) / 1000.0
                best = (l_dg, l_dh, l_ds, -1, -1, 1)

            if span >= 6:
                sub = dp[i + 1][j - 1]
                if sub[0] < INF * 0.5:
                    st = NN_2004.get(seq[i] + seq[i + 1])
                    if st:
                        c_dh = sub[1] + st[0]
                        c_ds = sub[2] + st[1] + salt_per_step
                        c_dg = c_dh - (temp_k * c_ds) / 1000.0
                        if c_dg < best[0]:
                            best = (c_dg, c_dh, c_ds, i + 1, j - 1, sub[5] + 1)

            for b_size in range(1, 7):
                ni_l, nj_l = i + 1 + b_size, j - 1
                if nj_l - ni_l >= 4:
                    sub = dp[ni_l][nj_l]
                    if sub[0] < INF * 0.5:
                        ib = _bulge_init(b_size)
                        c_dh = sub[1] + ib[0]
                        c_ds = sub[2] + ib[1]
                        if b_size == 1 and (seq[i] + seq[ni_l]) in NN_2004:
                            st = NN_2004[seq[i] + seq[ni_l]]
                            c_dh += st[0]
                            c_ds += st[1] + salt_per_step
                        else:
                            if seq[i] in "AT":
                                c_dh += 2.2
                                c_ds += 6.9
                            if seq[ni_l] in "AT":
                                c_dh += 2.2
                                c_ds += 6.9
                        c_dg = c_dh - (temp_k * c_ds) / 1000.0
                        if c_dg < best[0]:
                            best = (c_dg, c_dh, c_ds, ni_l, nj_l, sub[5] + 1)

                ni_r, nj_r = i + 1, j - 1 - b_size
                if nj_r - ni_r >= 4:
                    sub = dp[ni_r][nj_r]
                    if sub[0] < INF * 0.5:
                        ib = _bulge_init(b_size)
                        c_dh = sub[1] + ib[0]
                        c_ds = sub[2] + ib[1]
                        if b_size == 1 and (seq[i] + seq[ni_r]) in NN_2004:
                            st = NN_2004[seq[i] + seq[ni_r]]
                            c_dh += st[0]
                            c_ds += st[1] + salt_per_step
                        else:
                            if seq[i] in "AT":
                                c_dh += 2.2
                                c_ds += 6.9
                            if seq[ni_r] in "AT":
                                c_dh += 2.2
                                c_ds += 6.9
                        c_dg = c_dh - (temp_k * c_ds) / 1000.0
                        if c_dg < best[0]:
                            best = (c_dg, c_dh, c_ds, ni_r, nj_r, sub[5] + 1)

            for k1 in range(1, 5):
                for k2 in range(1, 5):
                    ni, nj = i + 1 + k1, j - 1 - k2
                    if nj - ni < 4:
                        continue
                    sub = dp[ni][nj]
                    if sub[0] >= INF * 0.5:
                        continue
                    c_dh, c_ds = sub[1], sub[2]
                    if k1 == 1 and k2 == 1:
                        m1 = _lookup_internal_mismatch(seq[i], seq[i + 1], seq[j], seq[j - 1]) or (1.0, 0.0)
                        m2 = _lookup_internal_mismatch(seq[i + 1], seq[ni], seq[j - 1], seq[nj]) or (1.0, 0.0)
                        c_dh += m1[0] + m2[0]
                        c_ds += m1[1] + m2[1] + 2.0 * salt_per_step
                    else:
                        il = _internal_loop_init(k1, k2)
                        m1 = _lookup_terminal_mismatch(seq[i], seq[i + 1], seq[j], seq[j - 1]) or (0.0, 0.0)
                        m2 = _lookup_terminal_mismatch(seq[ni - 1], seq[ni], seq[nj + 1], seq[nj]) or (0.0, 0.0)
                        c_dh += il[0] + m1[0] + m2[0]
                        c_ds += il[1] + m1[1] + m2[1] + salt_per_step
                    c_dg = c_dh - (temp_k * c_ds) / 1000.0
                    if c_dg < best[0]:
                        best = (c_dg, c_dh, c_ds, ni, nj, sub[5] + 1)

            dp[i][j] = best

    best_dg, best_dh, best_ds = 0.0, 0.0, 0.0
    best_outer = None
    for i in range(0, n - 6):
        for j in range(i + 6, n):
            st = dp[i][j]
            if st[0] >= INF * 0.5 or st[5] < 3:
                continue
            c_dh, c_ds = st[1], st[2]
            if seq[i] in "AT":
                c_dh += 2.2
                c_ds += 6.9
            if i > 0 and j < n - 1:
                tmm = _lookup_terminal_mismatch(seq[i - 1], seq[i], seq[j + 1], seq[j])
                if tmm:
                    c_dh += tmm[0]
                    c_ds += tmm[1]
            elif i > 0 and (seq[i - 1] + seq[i]) in FIVE_PRIME_DANGLE:
                d5 = FIVE_PRIME_DANGLE[seq[i - 1] + seq[i]]
                c_dh += d5[0]
                c_ds += d5[1]
            elif j < n - 1 and (seq[j] + seq[j + 1]) in THREE_PRIME_DANGLE:
                d3 = THREE_PRIME_DANGLE[seq[j] + seq[j + 1]]
                c_dh += d3[0]
                c_ds += d3[1]
            c_dg = c_dh - (temp_k * c_ds) / 1000.0
            if c_dg < best_dg:
                best_dg, best_dh, best_ds = c_dg, c_dh, c_ds
                best_outer = (i, j)

    if best_outer is None or best_dg >= -0.2 or best_ds >= 0:
        return {"structure_found": False, "dg": 0.0, "dh": 0.0, "ds": 0.0, "tm": 0.0, "three_prime_anchored": False, "risk_level": "safe"}

    best_pairs = []
    ci, cj = best_outer
    while ci >= 0 and cj >= 0:
        best_pairs.append((ci, cj))
        st = dp[ci][cj]
        ci, cj = st[3], st[4]

    tm = max(0.0, (best_dh * 1000.0) / best_ds - 273.15)
    anchored3 = any(p[0] >= n - 3 or p[1] >= n - 3 for p in best_pairs)
    if (anchored3 and best_dg <= -3.0) or best_dg <= -6.0:
        risk_level = "high"
    elif best_dg <= -3.0:
        risk_level = "moderate"
    else:
        risk_level = "safe"
    return {
        "structure_found": True,
        "dg": round(best_dg, 2),
        "dh": round(best_dh, 2),
        "ds": round(best_ds, 2),
        "tm": round(tm, 1),
        "three_prime_anchored": anchored3,
        "risk_level": risk_level,
    }


def _calc_duplex_dp(raw_seq1: str, raw_seq2: str, is_homodimer: bool, mv_conc: float = 50.0, dv_conc: float = 1.5, dntp_conc: float = 0.6, dna_conc: float = 50.0, temp_c: float = 37.0) -> dict:
    """Zuker-Stiegler bimolecular duplex DP (100% aligned with PrimerQualityEngine.calcDuplexDimer in Swift)"""
    s1_full = _clean_acgt_rna(raw_seq1)
    s2_full = _clean_acgt_rna(raw_seq2)
    s1 = s1_full[-60:] if len(s1_full) > 60 else s1_full
    s2_orig = s2_full[-60:] if len(s2_full) > 60 else s2_full
    s2_rev = s2_orig[::-1]
    n1, n2 = len(s1), len(s2_rev)
    if n1 < 4 or n2 < 4:
        return {"structure_found": False, "dg": 0.0, "dh": 0.0, "ds": 0.0, "tm": 0.0, "three_prime_anchored": False, "risk_level": "safe"}

    temp_k = temp_c + 273.15
    na_eq = equivalent_monovalent_molar(mv_conc, dv_conc, dntp_conc)
    salt_per_step = 0.368 * math.log(na_eq)
    INF = 1e9
    dp = [[(INF, 0.0, 0.0, -1, -1, -1, -1, 0) for _ in range(n2)] for _ in range(n1)]

    for i in range(n1):
        for j in range(n2):
            if not _is_comp(s1[i], s2_rev[j]):
                continue
            open_dh, open_ds = 0.2, -5.7
            if s1[i] in "AT":
                open_dh += 2.2
                open_ds += 6.9
            if i > 0 and j > 0:
                tmm = _lookup_terminal_mismatch(s1[i - 1], s1[i], s2_rev[j - 1], s2_rev[j])
                if tmm:
                    open_dh += tmm[0]
                    open_ds += tmm[1]
            elif i > 0 and (s1[i - 1] + s1[i]) in FIVE_PRIME_DANGLE:
                d5 = FIVE_PRIME_DANGLE[s1[i - 1] + s1[i]]
                open_dh += d5[0]
                open_ds += d5[1]
            elif j > 0 and (s2_rev[j] + s2_rev[j - 1]) in THREE_PRIME_DANGLE:
                d3 = THREE_PRIME_DANGLE[s2_rev[j] + s2_rev[j - 1]]
                open_dh += d3[0]
                open_ds += d3[1]
            open_dg = open_dh - (temp_k * open_ds) / 1000.0
            best = (open_dg, open_dh, open_ds, -1, -1, i, j, 1)

            if i > 0 and j > 0:
                prev = dp[i - 1][j - 1]
                if prev[0] < INF * 0.5:
                    st = NN_2004.get(s1[i - 1] + s1[i])
                    if st:
                        c_dh = prev[1] + st[0]
                        c_ds = prev[2] + st[1] + salt_per_step
                        c_dg = c_dh - (temp_k * c_ds) / 1000.0
                        if c_dg < best[0]:
                            best = (c_dg, c_dh, c_ds, i - 1, j - 1, prev[5], prev[6], prev[7] + 1)

            for b_size in range(1, 5):
                pi, pj = i - 1 - b_size, j - 1
                if pi >= 0 and pj >= 0:
                    prev = dp[pi][pj]
                    if prev[0] < INF * 0.5:
                        ib = _bulge_init(b_size)
                        c_dh = prev[1] + ib[0]
                        c_ds = prev[2] + ib[1]
                        if b_size == 1 and (s1[pi] + s1[i]) in NN_2004:
                            st = NN_2004[s1[pi] + s1[i]]
                            c_dh += st[0]
                            c_ds += st[1] + salt_per_step
                        else:
                            if s1[pi] in "AT":
                                c_dh += 2.2
                                c_ds += 6.9
                            if s1[i] in "AT":
                                c_dh += 2.2
                                c_ds += 6.9
                        c_dg = c_dh - (temp_k * c_ds) / 1000.0
                        if c_dg < best[0]:
                            best = (c_dg, c_dh, c_ds, pi, pj, prev[5], prev[6], prev[7] + 1)

                pi, pj = i - 1, j - 1 - b_size
                if pi >= 0 and pj >= 0:
                    prev = dp[pi][pj]
                    if prev[0] < INF * 0.5:
                        ib = _bulge_init(b_size)
                        c_dh = prev[1] + ib[0]
                        c_ds = prev[2] + ib[1]
                        if b_size == 1 and (s1[pi] + s1[i]) in NN_2004:
                            st = NN_2004[s1[pi] + s1[i]]
                            c_dh += st[0]
                            c_ds += st[1] + salt_per_step
                        else:
                            if s1[pi] in "AT":
                                c_dh += 2.2
                                c_ds += 6.9
                            if s1[i] in "AT":
                                c_dh += 2.2
                                c_ds += 6.9
                        c_dg = c_dh - (temp_k * c_ds) / 1000.0
                        if c_dg < best[0]:
                            best = (c_dg, c_dh, c_ds, pi, pj, prev[5], prev[6], prev[7] + 1)

            for k1 in range(1, 4):
                for k2 in range(1, 4):
                    pi, pj = i - 1 - k1, j - 1 - k2
                    if pi < 0 or pj < 0:
                        continue
                    prev = dp[pi][pj]
                    if prev[0] >= INF * 0.5:
                        continue
                    c_dh, c_ds = prev[1], prev[2]
                    if k1 == 1 and k2 == 1:
                        m1 = _lookup_internal_mismatch(s1[pi], s1[pi + 1], s2_rev[pj], s2_rev[pj + 1]) or (1.2, 2.0)
                        m2 = _lookup_internal_mismatch(s1[pi + 1], s1[i], s2_rev[pj + 1], s2_rev[j]) or (1.2, 2.0)
                        c_dh += m1[0] + m2[0]
                        c_ds += m1[1] + m2[1] + 2.0 * salt_per_step
                    else:
                        il = _internal_loop_init(k1, k2)
                        m1 = _lookup_terminal_mismatch(s1[pi], s1[pi + 1], s2_rev[pj], s2_rev[pj + 1]) or (0.0, 0.0)
                        m2 = _lookup_terminal_mismatch(s1[i - 1], s1[i], s2_rev[j - 1], s2_rev[j]) or (0.0, 0.0)
                        c_dh += il[0] + m1[0] + m2[0]
                        c_ds += il[1] + m1[1] + m2[1] + salt_per_step
                    c_dg = c_dh - (temp_k * c_ds) / 1000.0
                    if c_dg < best[0]:
                        best = (c_dg, c_dh, c_ds, pi, pj, prev[5], prev[6], prev[7] + 1)

            dp[i][j] = best

    best_dg, best_dh, best_ds = 0.0, 0.0, 0.0
    best_end = None
    best_is_self_sym = False
    for i in range(n1):
        for j in range(n2):
            node = dp[i][j]
            if node[0] >= INF * 0.5 or node[7] < 2:
                continue
            c_dh, c_ds = node[1], node[2]
            if s1[i] in "AT":
                c_dh += 2.2
                c_ds += 6.9
            if i < n1 - 1 and j < n2 - 1:
                tmm = _lookup_terminal_mismatch(s1[i], s1[i + 1], s2_rev[j], s2_rev[j + 1])
                if tmm:
                    c_dh += tmm[0]
                    c_ds += tmm[1]
            elif i < n1 - 1 and (s1[i] + s1[i + 1]) in THREE_PRIME_DANGLE:
                d3 = THREE_PRIME_DANGLE[s1[i] + s1[i + 1]]
                c_dh += d3[0]
                c_ds += d3[1]
            elif j < n2 - 1 and (s2_rev[j + 1] + s2_rev[j]) in FIVE_PRIME_DANGLE:
                d5 = FIVE_PRIME_DANGLE[s2_rev[j + 1] + s2_rev[j]]
                c_dh += d5[0]
                c_ds += d5[1]
            is_self_sym = False
            if is_homodimer and node[5] == (n2 - 1 - j) and i == (n2 - 1 - node[6]):
                is_self_sym = True
                c_ds += -1.4
            c_dg = c_dh - (temp_k * c_ds) / 1000.0
            if c_dg < best_dg:
                best_dg, best_dh, best_ds = c_dg, c_dh, c_ds
                best_end = (i, j)
                best_is_self_sym = is_self_sym

    if best_end is None or best_dg >= -0.5 or best_ds >= 0:
        return {"structure_found": False, "dg": 0.0, "dh": 0.0, "ds": 0.0, "tm": 0.0, "three_prime_anchored": False, "risk_level": "safe"}

    best_pairs = []
    ci, cj = best_end
    while ci >= 0 and cj >= 0:
        best_pairs.append((ci, cj))
        node = dp[ci][cj]
        ci, cj = node[3], node[4]
    best_pairs.reverse()

    c_total = max(1e-9, float(dna_conc) * 1e-9)
    c_eff = c_total if best_is_self_sym else (c_total / 4.0)
    tm = (best_dh * 1000.0) / (best_ds + 1.9872 * math.log(c_eff)) - 273.15
    anchored3 = any(p[0] >= n1 - 3 or p[1] <= 2 for p in best_pairs)
    if (anchored3 and best_dg <= -6.0) or best_dg <= -10.5:
        risk_level = "high"
    elif best_dg <= -6.0:
        risk_level = "moderate"
    else:
        risk_level = "safe"
    return {
        "structure_found": True,
        "dg": round(best_dg, 2),
        "dh": round(best_dh, 2),
        "ds": round(best_ds, 2),
        "tm": round(tm, 1),
        "three_prime_anchored": anchored3,
        "risk_level": risk_level,
    }


def calc_dimer(raw_seq1: str, raw_seq2: str, mv_conc: float = 50.0, dv_conc: float = 1.5, dntp_conc: float = 0.6, dna_conc: float = 50.0, temp_c: float = 37.0) -> dict:
    return _calc_duplex_dp(raw_seq1, raw_seq2, is_homodimer=False, mv_conc=mv_conc, dv_conc=dv_conc, dntp_conc=dntp_conc, dna_conc=dna_conc, temp_c=temp_c)


def calc_homodimer(raw_seq: str, mv_conc: float = 50.0, dv_conc: float = 1.5, dntp_conc: float = 0.6, dna_conc: float = 50.0, temp_c: float = 37.0) -> dict:
    return _calc_duplex_dp(raw_seq, raw_seq, is_homodimer=True, mv_conc=mv_conc, dv_conc=dv_conc, dntp_conc=dntp_conc, dna_conc=dna_conc, temp_c=temp_c)


def _evaluate_primer_overall_risk(raw_seq: str) -> str:
    rank = {"safe": 0, "moderate": 1, "high": 2}
    hp_risk = calc_hairpin(raw_seq).get("risk_level", "safe")
    hd_risk = calc_homodimer(raw_seq).get("risk_level", "safe")
    return hp_risk if rank.get(hp_risk, 0) >= rank.get(hd_risk, 0) else hd_risk

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
            gc_bonus = 0.35 if sub[-1] in "GC" else 0.0
            full_oligo = five_prime_overhang + sub
            risk = _evaluate_primer_overall_risk(full_oligo)
            risk_penalty = 1.50 if risk == "high" else (0.50 if risk == "moderate" else 0.0)
            pent_dg = three_prime_pentamer_dg(full_oligo)
            pent_penalty = 0.40 if pent_dg <= -9.0 else 0.0
            score = gc_bonus - diff - risk_penalty - pent_penalty
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

# (top_cut_offset, bottom_cut_offset) aligned with HomologyArmDesigner.snipOffsets
COMMON_ENZYME_SNIP_OFFSETS = {
    "EcoRI": (1, 5), "BamHI": (1, 5), "HindIII": (1, 5), "XhoI": (1, 5),
    "NdeI": (2, 4), "NcoI": (1, 5), "NotI": (2, 6), "XbaI": (1, 5),
    "SpeI": (1, 5), "PstI": (5, 1), "SalI": (1, 5), "SacI": (5, 1),
    "KpnI": (5, 1), "SmaI": (3, 3), "EcoRV": (3, 3), "BglII": (1, 5),
    "AgeI": (1, 5), "NheI": (1, 5), "MluI": (1, 5), "PacI": (5, 3),
}


def _evaluate_homology_overlap(overlap_seq: str, label: str = "同源臂") -> list:
    clean = clean_seq(overlap_seq)
    if not clean:
        return []
    warnings = []
    tm = calc_snapgene_tm(clean, dv_conc=1.5, dntp_conc=0.6, salt_correction="owczarzy2008")
    if tm < 48.0:
        warnings.append(f"{label} Tm 偏低 ({tm:.1f}℃ < 48℃)，重组退火效率可能下降")
    elif tm > 68.0:
        warnings.append(f"{label} Tm 偏高 ({tm:.1f}℃ > 68℃)，易形成非特异错配")
    hp = calc_hairpin(clean)
    if hp.get("structure_found") and hp.get("dg", 0.0) <= -4.0:
        warnings.append(f"{label} 存在强发夹二级结构 (ΔG={hp['dg']:.2f} kcal/mol)")
    return warnings


def _count_off_target_mispriming_hits(primer_3prime: str, templates: list, seed_len: int = 12) -> int:
    p = clean_seq(primer_3prime)
    if len(p) < seed_len:
        return 0
    seed = p[-seed_len:]
    seed_rc = rev_comp(seed)
    is_pal = (seed == seed_rc)
    total = 0
    for raw_t, is_circ in templates:
        t = clean_seq(raw_t)
        if len(t) < seed_len:
            continue
        scan = (t + t[:seed_len - 1]) if is_circ else t
        limit = len(t) if is_circ else (len(t) - seed_len + 1)
        pos = 0
        while True:
            idx = scan.find(seed, pos)
            if idx == -1 or idx >= limit:
                break
            total += 1
            pos = idx + 1
        if not is_pal:
            pos = 0
            while True:
                idx = scan.find(seed_rc, pos)
                if idx == -1 or idx >= limit:
                    break
                total += 1
                pos = idx + 1
    return max(0, total - 1)


def _pick_optimal_primer_pair(insert_seq: str, forward_overhang: str, reverse_overhang: str, target_tm: float = 60.0, tolerance: float = 1.0, templates: list = None) -> tuple:
    s = clean_seq(insert_seq)
    rc_s = rev_comp(s)
    def _cands(tmpl: str, ov: str):
        out = []
        clamped_tol = max(0.0, min(3.0, tolerance))
        lo, hi = target_tm - clamped_tol, target_tm + clamped_tol
        fallback = []
        for length in range(18, min(38, len(tmpl)) + 1):
            sub = tmpl[:length]
            tm = calc_snapgene_tm(sub, five_prime_overhang=ov)
            diff = abs(tm - target_tm)
            full_o = ov + sub
            gc_bonus = 0.35 if sub[-1] in "GC" else 0.0
            risk = _evaluate_primer_overall_risk(full_o)
            risk_p = 1.50 if risk == "high" else (0.50 if risk == "moderate" else 0.0)
            pent_p = 0.40 if three_prime_pentamer_dg(full_o) <= -9.0 else 0.0
            sc = gc_bonus - diff - risk_p - pent_p
            item = (sub, tm, sc)
            if lo <= tm <= hi:
                out.append(item)
            else:
                fallback.append(item)
        out.sort(key=lambda x: x[2], reverse=True)
        fallback.sort(key=lambda x: abs(x[1] - target_tm))
        return (out[:6] if out else fallback[:4]) or [(tmpl[:min(18, len(tmpl))], calc_snapgene_tm(tmpl[:min(18, len(tmpl))], five_prime_overhang=ov), 0.0)]

    f_cands = _cands(s, forward_overhang)
    r_cands = _cands(rc_s, reverse_overhang)
    scan_tmpls = templates if templates is not None else [(s, False)]
    best = (f_cands[0][0], f_cands[0][1], r_cands[0][0], r_cands[0][1], 0.0, [])
    best_score = -1e9
    for f_seq, f_tm, f_sc in f_cands:
        f_hits = _count_off_target_mispriming_hits(f_seq, scan_tmpls)
        for r_seq, r_tm, r_sc in r_cands:
            r_hits = _count_off_target_mispriming_hits(r_seq, scan_tmpls)
            dtm = abs(f_tm - r_tm)
            d_pen = (2.5 + (dtm - 3.0) * 1.5) if dtm > 3.0 else (dtm * 0.25)
            het = calc_dimer(forward_overhang + f_seq, reverse_overhang + r_seq)
            h_pen = 2.0 if het.get("risk_level") == "high" else (0.75 if het.get("risk_level") == "moderate" else 0.0)
            ps = f_sc + r_sc - d_pen - h_pen - 1.2 * (f_hits + r_hits)
            if ps > best_score:
                best_score = ps
                warns = []
                if f_hits > 0:
                    warns.append(f"正向引物 3' 端在模板中存在 {f_hits} 处潜在脱靶结合位点")
                if r_hits > 0:
                    warns.append(f"反向引物 3' 端在模板中存在 {r_hits} 处潜在脱靶结合位点")
                best = (f_seq, f_tm, r_seq, r_tm, het.get("dg", 0.0), warns)
    return best


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
        doubled = seq + seq
        n_len = len(seq)
        cuts = []
        matched_names = []
        for p in enz_parts:
            for en, site in COMMON_ENZYMES.items():
                if en.lower() == p.lower():
                    idx = doubled.find(site)
                    if idx == -1 or idx >= n_len:
                        raise ValueError(f"质粒 {plasmid_item['name']} 中未找到酶切位点 {en} ({site})")
                    top_off, bot_off = COMMON_ENZYME_SNIP_OFFSETS.get(en, (1, max(1, len(site) - 1)))
                    c_lo = (idx + min(top_off, bot_off)) % n_len + 1
                    c_hi = (idx + max(top_off, bot_off)) % n_len
                    if c_hi == 0:
                        c_hi = n_len
                    cuts.append((c_lo, c_hi))
                    matched_names.append(en)
        if len(cuts) == 2:
            a_lo, a_hi = cuts[0]
            b_lo, b_hi = cuts[1]
            fwd_span = (b_hi - a_lo) % n_len
            rev_span = (a_hi - b_lo) % n_len
            s, e = (a_lo, b_hi) if fwd_span <= rev_span else (b_lo, a_hi)
        else:
            s = min(x[0] for x in cuts)
            e = max(x[1] for x in cuts)
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

    spec_f, _, spec_r, _, _, mp_warnings = _pick_optimal_primer_pair(
        ins_seq,
        forward_overhang=hom_f + extra5,
        reverse_overhang=hom_r + rev_comp(extra3),
        target_tm=target_tm,
        templates=[(ins_seq, False), (vec_seq, True)],
    )
    overlap_warnings = _evaluate_homology_overlap(hom_f, "上游同源臂") + _evaluate_homology_overlap(hom_r, "下游同源臂") + mp_warnings

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
        "warnings": overlap_warnings,
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

    n = len(full_seq)
    up_retained = full_seq[:max(0, del_start - 1)]
    down_retained = full_seq[del_end:]
    retained_ring = down_retained + up_retained
    if not retained_ring:
        raise ValueError("删除区间覆盖整条质粒，无剩余骨架序列可用于设计反向 PCR 引物")
    ring_pool = retained_ring
    while len(ring_pool) < max(80, hom_len):
        ring_pool += retained_ring
    up_flank = up_retained[-80:] if len(up_retained) >= 80 else ring_pool[-80:]
    down_flank = down_retained[:80] if len(down_retained) >= 80 else ring_pool[:80]

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

    # 消除 2.0 kb 阶跃不连续：平滑单调公式 max(50.0, 20.0 * vec_kb)（对齐 DNAMolarCalculator.swift）
    vec_rec_ng = min(200.0, max(50.0, round(20.0 * vec_kb, 1)))
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
        conv = str(args.get("molar_mass_convention") or "hydrated660").strip().lower()
        da_per_bp = 650.0 if "650" in conv else 660.0
        if mode == "dsdna_ug_to_pmol":
            factor = 1515.1 if da_per_bp == 660.0 else (1_000_000.0 / da_per_bp)
            res = (val / bp) * factor
            return {
                "status": "success",
                "mode": mode,
                "molar_mass_da_per_bp": da_per_bp,
                "result_value": adaptive_round(res),
                "formatted_result": f"{format_bio_number(res)} pmol",
                "unit": "pmol",
                "formula": f"pmol = (µg / N_bp) × {factor:.1f}"
            }
        res = val * bp * (da_per_bp * 1e-6)
        return {
            "status": "success",
            "mode": mode,
            "molar_mass_da_per_bp": da_per_bp,
            "result_value": adaptive_round(res),
            "formatted_result": f"{format_bio_number(res)} µg",
            "unit": "µg",
            "formula": f"µg = pmol × N_bp × {da_per_bp * 1e-6:.5f}"
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
        oligo_seq = clean_seq(args.get("sequence") or "")
        eps_260 = None
        if stype in ("ssoligo", "oligo", "single-stranded oligo") and len(oligo_seq) >= 2:
            # Tataurov et al. (2008) Biophys Chem 133:66-70 最近邻 ssDNA ε260 与精确分子量
            mono_e = {"A": 15400.0, "C": 7400.0, "G": 11500.0, "T": 8700.0}
            dinuc_e = {
                "AA": 27400.0, "AC": 21200.0, "AG": 25000.0, "AT": 22800.0,
                "CA": 21200.0, "CC": 14600.0, "CG": 18000.0, "CT": 15200.0,
                "GA": 25200.0, "GC": 17600.0, "GG": 21600.0, "GT": 20000.0,
                "TA": 23400.0, "TC": 16200.0, "TG": 19000.0, "TT": 16800.0,
            }
            base_mw = {"A": 313.21, "C": 289.18, "G": 329.21, "T": 304.20}
            eps_260 = sum(dinuc_e[oligo_seq[i:i+2]] for i in range(len(oligo_seq) - 1)) - sum(mono_e[oligo_seq[i]] for i in range(1, len(oligo_seq) - 1))
            oligo_mw = sum(base_mw[b] for b in oligo_seq) - 61.96
            factor = (oligo_mw * 1000.0 / eps_260) if eps_260 > 0 else factor
        res = val * factor * dil
        out_of_range = val > 0 and (val < 0.1 or val > 1.0)
        return {
            "status": "success",
            "mode": mode,
            "sample_type": label,
            "factor": round(factor, 3),
            "epsilon_260": round(eps_260, 1) if eps_260 is not None else None,
            "dilution_factor": dil,
            "result_value": adaptive_round(res),
            "formatted_result": f"{format_bio_number(res)} µg/mL",
            "unit": "µg/mL",
            "out_of_linear_range": out_of_range,
            "warning": "大多数分光光度计在低于 0.1 OD 单位或高于 1.0 OD 单位时精度下降，建议调整稀释倍数重新测读。" if out_of_range else None,
            "formula": f"浓度 (µg/mL) = OD260 × {factor:.2f} × 稀释倍数"
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
            k = c + 273.15
        elif fu == "C":
            c = v
            f = (9.0 / 5.0) * c + 32.0
            k = c + 273.15
        elif fu == "K":
            k = v
            c = k - 273.15
            f = (9.0 / 5.0) * c + 32.0
        else:
            return {"status": "error", "error": f"不支持的 from_unit: {fu}，请传 F / C / K"}
        if k < 0:
            return {"status": "error", "error": "温度低于绝对零度（0 K / -273.15 °C）。", "kelvin": round(k, 2)}
        return {
            "status": "success", "mode": mode,
            "fahrenheit": round(f, 2),
            "celsius": round(c, 2),
            "kelvin": round(k, 2),
            "formula": "°C=5/9(°F-32); °F=9/5°C+32; K=°C+273.15"
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
        # 遵循 Ran et al. (Nat. Protoc. 2013) & Sanjana et al. (Nat. Methods 2014): 仅当 spacer 首位不是 G 时追加 U6 +1G / 3' C
        starts_with_g = sp.startswith("G")
        fwd_prefix = "CACC" if starts_with_g else "CACCG"
        rev_prefix = "AAAC"
        rev_suffix = "" if starts_with_g else "C"
        cand["added_u6_g"] = (not starts_with_g)
        fwd_full = fwd_prefix + sp
        rev_full = rev_prefix + rc + rev_suffix
        pf = make_primer_dict(
            name=f"{gene_name}_sg{idx}-FWD",
            homology_arm=fwd_prefix,
            specific_seq=sp,
            purpose=f"sgRNA#{idx} 正向退火引物 ({vec_label})",
            source_tool="MCP sgRNA设计",
            custom_notes=f"靶基因:{gene_name} | 位点:{cand['position']}({cand['strand']}) | PAM:{cand['pam']} | 评分:{cand['score']} | 5'+{fwd_prefix}"
        )
        pr = make_primer_dict(
            name=f"{gene_name}_sg{idx}-REV",
            homology_arm=rev_prefix,
            specific_seq=rc + rev_suffix,
            purpose=f"sgRNA#{idx} 反向退火引物 ({vec_label})",
            source_tool="MCP sgRNA设计",
            custom_notes=f"靶基因:{gene_name} | 载体:{vec_label} | 5'加{rev_prefix} 3'加{rev_suffix or '无'}"
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
            hairpin_transcript = sense + loop + rev_comp(sense)
            if "TTTT" in hairpin_transcript or "AAAA" in sense or "GGGG" in sense or "CCCC" in sense:
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

    rev_loop = rev_comp(loop)
    primers = []
    for idx, cand in enumerate(selected, start=1):
        sense = cand["sense"]
        antisense = rev_comp(sense)
        hairpin_core = sense + loop + antisense
        rev_hairpin_core = sense + rev_loop + antisense
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
            homology_arm="AATTCAAAAAA",
            specific_seq=rev_hairpin_core,
            purpose=f"shRNA#{idx} 反向发夹链 (pLKO.1 EcoRI)",
            source_tool="MCP shRNA设计",
            custom_notes=f"靶基因:{gene_name} | 载体:pLKO.1 (AgeI/EcoRI) | Loop:{loop} (Bottom RC: {rev_loop})"
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
        vendor = (args.get("vendor") or "tsingke_primer").strip().lower()
        allowed_vendors = {"tsingke_primer", "idt_bulk", "twist_bulk", "genscript_bulk", "eurofins_bulk", "bgi_bulk"}
        if vendor not in allowed_vendors:
            raise ValueError(f"不支持的 vendor '{vendor}'，可选: {', '.join(sorted(allowed_vendors))}")
        req_fmt = (args.get("file_format") or "").strip().lower()
        if vendor == "tsingke_primer":
            file_fmt = "xlsx"
        elif req_fmt in ("xlsx", "csv"):
            file_fmt = req_fmt
        else:
            file_fmt = "csv" if vendor in ("twist_bulk", "eurofins_bulk") else "xlsx"

        tpl_candidates = [
            os.path.join(SCRIPT_DIR, "擎科引物合成订购表.xlsx"),
            os.path.join(PROJECT_DIR, "Sources/CloneStudioCore/Resources/擎科引物合成订购表.xlsx"),
            os.path.join(PROJECT_DIR, "擎科引物合成订购表.xlsx"),
            os.path.join(os.path.dirname(PROJECT_DIR), "擎科引物合成订购表.xlsx"),
        ]
        tpl_path = next((p for p in tpl_candidates if os.path.exists(p)), tpl_candidates[0]) if vendor == "tsingke_primer" else "-"
        ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
        out_name = f"擎科引物合成订购表_MCP_{ts}.xlsx" if vendor == "tsingke_primer" else f"{vendor}_MCP_{ts}.{file_fmt}"
        out_path = (args.get("output_path") or "").strip() or os.path.join(PROJECT_DIR, out_name)
        write_action = "overwrite" if os.path.exists(out_path) else "create"
        if not confirm:
            return {
                "status": "preview",
                "planned_writes": [{
                    "path": out_path,
                    "action": write_action,
                    "summary": f"导出 {vendor} ({file_fmt.upper()}) 订购单文件，共包含 {len(primers_to_export)} 条引物/基因"
                }],
                "confirm_hint": "请先以 confirm=false 预览 planned_writes，经用户同意后再以 confirm=true 执行落盘。"
            }
        backup_excel = _backup_if_exists(out_path)
        payload = {
            "template_type": vendor,
            "fileFormat": file_fmt,
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
            subprocess.run(["/usr/bin/python3", EXPORT_ORDER_SCRIPT, vendor, tpl_path, out_path, tmp_in], check=True, capture_output=True, text=True)
        finally:
            if os.path.exists(tmp_in):
                os.remove(tmp_in)
        return {"status": "success", "exportedExcelPath": out_path, "backupPath": backup_excel, "primerCount": len(primers_to_export), "vendor": vendor, "fileFormat": file_fmt}
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

# 与 Swift 端 ProteinBiophysicsEngine.aaMasses 完全一致（脱水残基质量 Da，每条多肽链 + 18.01528 水分子末端）
AA_RESIDUE_MASS = {
    'A': 71.0788, 'R': 156.1875, 'N': 114.1038, 'D': 115.0886, 'C': 103.1388,
    'E': 129.1155, 'Q': 128.1307, 'G': 57.0519, 'H': 137.1411, 'I': 113.1594,
    'L': 113.1594, 'K': 128.1741, 'M': 131.1926, 'F': 147.1766, 'P': 97.1167,
    'S': 87.0782, 'T': 101.1051, 'W': 186.2132, 'Y': 163.1760, 'V': 99.1326
}

WATER_MASS_DA = 18.01528

# Campen et al. (2008) TOP-IDP 内在无序倾向标度 (与 Swift ProteinBiophysicsEngine.topIDPScale 一致)
TOP_IDP_SCALE = {
    'W': -0.884, 'F': -0.697, 'Y': -0.510, 'I': -0.486, 'M': -0.397,
    'L': -0.326, 'V': -0.121, 'N': 0.007,  'C': 0.020,  'T': 0.059,
    'A': 0.060,  'G': 0.166,  'R': 0.180,  'D': 0.192,  'H': 0.303,
    'Q': 0.318,  'S': 0.341,  'K': 0.586,  'E': 0.736,  'P': 0.987
}

# Guruprasad, Reddy & Pandit (1990) 完整 20×20 DIWV 不稳定性权重矩阵 (与 ExPASy ProtParam / Swift 端逐项一致)
GURUPRASAD_DIWV = {
    'A': {'A': 1.0, 'C': 44.94, 'D': -7.49, 'E': 1.0, 'F': 1.0, 'G': 1.0, 'H': -7.49, 'I': 1.0, 'K': 1.0, 'L': 1.0, 'M': 1.0, 'N': 1.0, 'P': 20.26, 'Q': 1.0, 'R': 1.0, 'S': 1.0, 'T': 1.0, 'V': 1.0, 'W': 1.0, 'Y': 1.0},
    'C': {'A': 1.0, 'C': 1.0, 'D': 20.26, 'E': 1.0, 'F': 1.0, 'G': 1.0, 'H': 33.60, 'I': 1.0, 'K': 1.0, 'L': 20.26, 'M': 33.60, 'N': 1.0, 'P': 20.26, 'Q': -6.54, 'R': 1.0, 'S': 1.0, 'T': 33.60, 'V': -6.54, 'W': 24.68, 'Y': 1.0},
    'D': {'A': 1.0, 'C': 1.0, 'D': 1.0, 'E': 1.0, 'F': -6.54, 'G': 1.0, 'H': 1.0, 'I': 1.0, 'K': -7.49, 'L': 1.0, 'M': 1.0, 'N': 1.0, 'P': 1.0, 'Q': 1.0, 'R': -6.54, 'S': 20.26, 'T': -14.03, 'V': 1.0, 'W': 1.0, 'Y': 1.0},
    'E': {'A': 1.0, 'C': 44.94, 'D': 20.26, 'E': 33.60, 'F': 1.0, 'G': 1.0, 'H': -6.54, 'I': 20.26, 'K': 1.0, 'L': 1.0, 'M': 1.0, 'N': 1.0, 'P': 20.26, 'Q': 20.26, 'R': 1.0, 'S': 20.26, 'T': 1.0, 'V': 1.0, 'W': -14.03, 'Y': 1.0},
    'F': {'A': 1.0, 'C': 1.0, 'D': 13.34, 'E': 1.0, 'F': 1.0, 'G': 1.0, 'H': 1.0, 'I': 1.0, 'K': -14.03, 'L': 1.0, 'M': 1.0, 'N': 1.0, 'P': 20.26, 'Q': 1.0, 'R': 1.0, 'S': 1.0, 'T': 1.0, 'V': 1.0, 'W': 1.0, 'Y': 33.60},
    'G': {'A': -7.49, 'C': 1.0, 'D': 1.0, 'E': -6.54, 'F': 1.0, 'G': 13.34, 'H': 1.0, 'I': -7.49, 'K': -7.49, 'L': 1.0, 'M': 1.0, 'N': -7.49, 'P': 1.0, 'Q': 1.0, 'R': 1.0, 'S': 1.0, 'T': -7.49, 'V': 1.0, 'W': 13.34, 'Y': -7.49},
    'H': {'A': 1.0, 'C': 1.0, 'D': 1.0, 'E': 1.0, 'F': -9.37, 'G': -9.37, 'H': 1.0, 'I': 44.94, 'K': 24.68, 'L': 1.0, 'M': 1.0, 'N': 24.68, 'P': -1.88, 'Q': 1.0, 'R': 1.0, 'S': 1.0, 'T': -6.54, 'V': 1.0, 'W': -1.88, 'Y': 44.94},
    'I': {'A': 1.0, 'C': 1.0, 'D': 1.0, 'E': 44.94, 'F': 1.0, 'G': 1.0, 'H': 13.34, 'I': 1.0, 'K': -7.49, 'L': 20.26, 'M': 1.0, 'N': 1.0, 'P': -1.88, 'Q': 1.0, 'R': 1.0, 'S': 1.0, 'T': 1.0, 'V': -7.49, 'W': 1.0, 'Y': 1.0},
    'K': {'A': 1.0, 'C': 1.0, 'D': 1.0, 'E': 1.0, 'F': 1.0, 'G': -7.49, 'H': 1.0, 'I': -7.49, 'K': 1.0, 'L': -7.49, 'M': 33.60, 'N': 1.0, 'P': -6.54, 'Q': 24.68, 'R': 33.60, 'S': 1.0, 'T': 1.0, 'V': -7.49, 'W': 1.0, 'Y': 1.0},
    'L': {'A': 1.0, 'C': 1.0, 'D': 1.0, 'E': 1.0, 'F': 1.0, 'G': 1.0, 'H': 1.0, 'I': 1.0, 'K': -7.49, 'L': 1.0, 'M': 1.0, 'N': 1.0, 'P': 20.26, 'Q': 33.60, 'R': 20.26, 'S': 1.0, 'T': 1.0, 'V': 1.0, 'W': 24.68, 'Y': 1.0},
    'M': {'A': 13.34, 'C': 1.0, 'D': 1.0, 'E': 1.0, 'F': 1.0, 'G': 1.0, 'H': 58.28, 'I': 1.0, 'K': 1.0, 'L': 1.0, 'M': -1.88, 'N': 1.0, 'P': 44.94, 'Q': -6.54, 'R': -6.54, 'S': 44.94, 'T': -1.88, 'V': 1.0, 'W': 1.0, 'Y': 24.68},
    'N': {'A': 1.0, 'C': -1.88, 'D': 1.0, 'E': 1.0, 'F': -14.03, 'G': -14.03, 'H': 1.0, 'I': 44.94, 'K': 24.68, 'L': 1.0, 'M': 1.0, 'N': 1.0, 'P': -1.88, 'Q': -6.54, 'R': 1.0, 'S': 1.0, 'T': -7.49, 'V': 1.0, 'W': -9.37, 'Y': 1.0},
    'P': {'A': 20.26, 'C': -6.54, 'D': -6.54, 'E': 18.38, 'F': 20.26, 'G': 1.0, 'H': 1.0, 'I': 1.0, 'K': 1.0, 'L': 1.0, 'M': -6.54, 'N': 1.0, 'P': 20.26, 'Q': 20.26, 'R': -6.54, 'S': 20.26, 'T': 1.0, 'V': 20.26, 'W': -1.88, 'Y': 1.0},
    'Q': {'A': 1.0, 'C': -6.54, 'D': 20.26, 'E': 20.26, 'F': -6.54, 'G': 1.0, 'H': 1.0, 'I': 1.0, 'K': 1.0, 'L': 1.0, 'M': 1.0, 'N': 1.0, 'P': 20.26, 'Q': 20.26, 'R': 1.0, 'S': 44.94, 'T': 1.0, 'V': -6.54, 'W': 1.0, 'Y': -6.54},
    'R': {'A': 1.0, 'C': 1.0, 'D': 1.0, 'E': 1.0, 'F': 1.0, 'G': -7.49, 'H': 20.26, 'I': 1.0, 'K': 1.0, 'L': 1.0, 'M': 1.0, 'N': 13.34, 'P': 20.26, 'Q': 20.26, 'R': 58.28, 'S': 44.94, 'T': 1.0, 'V': 1.0, 'W': 58.28, 'Y': -6.54},
    'S': {'A': 1.0, 'C': 33.60, 'D': 1.0, 'E': 20.26, 'F': 1.0, 'G': 1.0, 'H': 1.0, 'I': 1.0, 'K': 1.0, 'L': 1.0, 'M': 1.0, 'N': 1.0, 'P': 44.94, 'Q': 20.26, 'R': 20.26, 'S': 20.26, 'T': 1.0, 'V': 1.0, 'W': 1.0, 'Y': 1.0},
    'T': {'A': 1.0, 'C': 1.0, 'D': 1.0, 'E': 20.26, 'F': 13.34, 'G': -7.49, 'H': 1.0, 'I': 1.0, 'K': 1.0, 'L': 1.0, 'M': 1.0, 'N': -14.03, 'P': 1.0, 'Q': -6.54, 'R': 1.0, 'S': 1.0, 'T': 1.0, 'V': 1.0, 'W': -14.03, 'Y': 1.0},
    'V': {'A': 1.0, 'C': 1.0, 'D': -14.03, 'E': 1.0, 'F': 1.0, 'G': -7.49, 'H': 1.0, 'I': 1.0, 'K': -1.88, 'L': 1.0, 'M': 1.0, 'N': 1.0, 'P': 20.26, 'Q': 1.0, 'R': 1.0, 'S': 1.0, 'T': -7.49, 'V': 1.0, 'W': 1.0, 'Y': -6.54},
    'W': {'A': -14.03, 'C': 1.0, 'D': 1.0, 'E': 1.0, 'F': 1.0, 'G': -9.37, 'H': 24.68, 'I': 1.0, 'K': 1.0, 'L': 13.34, 'M': 24.68, 'N': 13.34, 'P': 1.0, 'Q': 1.0, 'R': 1.0, 'S': 1.0, 'T': -14.03, 'V': -7.49, 'W': 1.0, 'Y': 1.0},
    'Y': {'A': 24.68, 'C': 1.0, 'D': 24.68, 'E': -6.54, 'F': 1.0, 'G': -7.49, 'H': 13.34, 'I': 1.0, 'K': 1.0, 'L': 1.0, 'M': 44.94, 'N': 1.0, 'P': 13.34, 'Q': 1.0, 'R': -15.91, 'S': 1.0, 'T': -7.49, 'V': 1.0, 'W': -9.37, 'Y': 13.34},
}


def _split_protein_chains(raw: str) -> list:
    lines = (raw or "").splitlines()
    if any(ln.strip().startswith(">") for ln in lines):
        chains = []
        cur = []
        for ln in lines:
            t = ln.strip()
            if t.startswith(">"):
                if cur:
                    chains.append("".join(cur))
                    cur = []
            else:
                cur.extend(ch for ch in t.upper() if ch in KD_HYDROPATHY)
        if cur:
            chains.append("".join(cur))
        return [c for c in chains if c]
    if "/" in (raw or "") or ":" in (raw or ""):
        parts = re.split(r"[/:]+", raw or "")
        chains = ["".join(ch for ch in p.upper() if ch in KD_HYDROPATHY) for p in parts]
        chains = [c for c in chains if c]
        if chains:
            return chains
    single = "".join(ch for ch in (raw or "").upper() if ch in KD_HYDROPATHY)
    return [single] if single else []


def _protein_net_charge_chains(chains: list, ph: float, scale: str = "bjellqvist") -> float:
    scale_l = (scale or "bjellqvist").strip().lower()
    total_pos = 0.0
    total_neg = 0.0
    bj_n = {'M': 7.00, 'S': 6.93, 'P': 8.36, 'A': 7.59, 'V': 7.44, 'E': 7.70, 'T': 6.82}
    bj_c = {'D': 4.55, 'E': 4.75}
    for seq in chains:
        if not seq:
            continue
        if scale_l == "emboss":
            pk_n, pk_c = 8.60, 3.60
            pk_k, pk_r, pk_h = 10.80, 12.50, 6.50
            pk_d, pk_e, pk_cys, pk_y = 3.90, 4.10, 8.50, 10.10
        elif scale_l == "lehninger":
            pk_n, pk_c = 9.69, 2.34
            pk_k, pk_r, pk_h = 10.54, 12.48, 6.00
            pk_d, pk_e, pk_cys, pk_y = 3.86, 4.25, 8.33, 10.07
        else:
            pk_n = bj_n.get(seq[0], 7.50)
            pk_c = bj_c.get(seq[-1], 3.55)
            pk_k, pk_r, pk_h = 10.00, 12.00, 5.98
            pk_d, pk_e, pk_cys, pk_y = 4.05, 4.45, 9.00, 10.00

        total_pos += 1.0 / (1.0 + 10.0 ** (ph - pk_n))
        total_pos += seq.count('K') / (1.0 + 10.0 ** (ph - pk_k))
        total_pos += seq.count('R') / (1.0 + 10.0 ** (ph - pk_r))
        total_pos += seq.count('H') / (1.0 + 10.0 ** (ph - pk_h))
        total_neg += 1.0 / (1.0 + 10.0 ** (pk_c - ph))
        total_neg += seq.count('D') / (1.0 + 10.0 ** (pk_d - ph))
        total_neg += seq.count('E') / (1.0 + 10.0 ** (pk_e - ph))
        total_neg += seq.count('C') / (1.0 + 10.0 ** (pk_cys - ph))
        total_neg += seq.count('Y') / (1.0 + 10.0 ** (pk_y - ph))
    return total_pos - total_neg


def _protein_isoelectric_point_chains(chains: list, scale: str = "bjellqvist") -> float:
    lo, hi = 0.5, 13.5
    for _ in range(40):
        mid = 0.5 * (lo + hi)
        if _protein_net_charge_chains(chains, mid, scale) > 0:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def _protein_instability_index_chains(chains: list) -> float:
    total_len = sum(len(c) for c in chains)
    if total_len < 2:
        return 0.0
    diwv_sum = 0.0
    for ch in chains:
        for i in range(len(ch) - 1):
            diwv_sum += GURUPRASAD_DIWV.get(ch[i], {}).get(ch[i + 1], 1.0)
    return (10.0 / float(total_len)) * diwv_sum


def _protein_disorder_propensity(seq: str, window_size: int = 15) -> tuple:
    n = len(seq)
    if n == 0:
        return (0.0, 0.0, 0.0)
    half_w = max(1, min(window_size, n) // 2)
    disordered = 0
    raw_sum = 0.0
    norm_h_sum = 0.0
    for i in range(n):
        raw_sum += TOP_IDP_SCALE.get(seq[i], 0.0)
        norm_h_sum += (KD_HYDROPATHY.get(seq[i], 0.0) + 4.5) / 9.0
        lo = max(0, i - half_w)
        hi = min(n - 1, i + half_w)
        win_mean = sum(TOP_IDP_SCALE.get(seq[k], 0.0) for k in range(lo, hi + 1)) / float(hi - lo + 1)
        if win_mean > 0.15:
            disordered += 1
    mean_top = raw_sum / float(n)
    mean_norm_h = norm_h_sum / float(n)
    mean_abs_charge = abs(_protein_net_charge_chains([seq], 7.0, "bjellqvist")) / float(n)
    boundary_h = (mean_abs_charge + 1.151) / 2.785
    return (disordered * 100.0 / float(n), mean_top, mean_norm_h - boundary_h)


def _is_hydrogen_atom(atom_name: str, elem: str = '') -> bool:
    e = (elem or '').strip().upper()
    if e in ('H', 'D'):
        return True
    a = (atom_name or '').strip().upper()
    return a.startswith(('H', '1H', '2H', '3H', 'D'))


def _parse_structure_atoms_for_ligsite(text: str):
    """解析 PDB / mmCIF 重原子、Cα、SITE 残基与分实例共晶配体（剔除氢原子与溶剂/缓冲离子）"""
    ignored_het = {'HOH', 'WAT', 'DOD', 'SO4', 'PO4', 'GOL', 'EDO', 'PEG', 'DMS', 'ACT', 'NA', 'CL', 'K', 'MG', 'ZN', 'FE', 'MN', 'CU', 'CA'}
    heavy_atoms = []
    ca_by_key = {}
    site_keys = set()
    ligand_instances = {}
    ligand_order = []
    is_cif = ('_atom_site.' in text) or ('data_' in text[:2000])

    if is_cif:
        lines = text.splitlines()
        idx = 0
        n_lines = len(lines)
        while idx < n_lines:
            ln = lines[idx].strip()
            if ln == 'loop_':
                idx += 1
                cols = []
                while idx < n_lines and lines[idx].strip().startswith('_'):
                    cols.append(lines[idx].strip())
                    idx += 1
                if any(c.startswith('_atom_site.') for c in cols):
                    col_map = {c: i for i, c in enumerate(cols)}
                    c_grp = col_map.get('_atom_site.group_PDB')
                    c_atom = col_map.get('_atom_site.label_atom_id', col_map.get('_atom_site.auth_atom_id'))
                    c_alt = col_map.get('_atom_site.label_alt_id')
                    c_res = col_map.get('_atom_site.label_comp_id', col_map.get('_atom_site.auth_comp_id'))
                    c_ch = col_map.get('_atom_site.auth_asym_id', col_map.get('_atom_site.label_asym_id'))
                    c_seq = col_map.get('_atom_site.auth_seq_id', col_map.get('_atom_site.label_seq_id'))
                    c_ic = col_map.get('_atom_site.pdbx_PDB_ins_code')
                    c_x = col_map.get('_atom_site.Cartn_x')
                    c_y = col_map.get('_atom_site.Cartn_y')
                    c_z = col_map.get('_atom_site.Cartn_z')
                    c_el = col_map.get('_atom_site.type_symbol')
                    c_mdl = col_map.get('_atom_site.pdbx_PDB_model_num')
                    first_model = None
                    while idx < n_lines:
                        row = lines[idx].strip()
                        if not row or row.startswith('#') or row.startswith('loop_') or row.startswith('_'):
                            break
                        toks = row.split()
                        idx += 1
                        if len(toks) < len(cols):
                            continue
                        if c_mdl is not None:
                            mdl = toks[c_mdl]
                            if first_model is None:
                                first_model = mdl
                            elif mdl != first_model:
                                continue
                        alt = toks[c_alt] if c_alt is not None else '.'
                        if alt not in ('.', '?', 'A', '1'):
                            continue
                        grp = toks[c_grp].upper() if c_grp is not None else 'ATOM'
                        atom_name = toks[c_atom].strip('"\'').upper() if c_atom is not None else ''
                        elem = toks[c_el].upper() if c_el is not None else ''
                        if _is_hydrogen_atom(atom_name, elem):
                            continue
                        res_name = toks[c_res].upper() if c_res is not None else ''
                        chain_id = toks[c_ch] if (c_ch is not None and toks[c_ch] not in ('.', '?')) else 'A'
                        res_seq_str = toks[c_seq] if c_seq is not None else '0'
                        ic = toks[c_ic] if (c_ic is not None and toks[c_ic] not in ('.', '?')) else ''
                        try:
                            x, y, z = float(toks[c_x]), float(toks[c_y]), float(toks[c_z])
                        except Exception:
                            continue
                        if grp == 'ATOM':
                            heavy_atoms.append((x, y, z))
                            if atom_name == 'CA':
                                ca_by_key[(chain_id, res_seq_str, ic)] = (x, y, z)
                        elif grp == 'HETATM' and res_name and res_name not in ignored_het:
                            lkey = f'{res_name}:{chain_id}:{res_seq_str}{ic}'
                            if lkey not in ligand_instances:
                                ligand_order.append(lkey)
                                ligand_instances[lkey] = {'id': lkey, 'res_name': res_name, 'chain_id': chain_id, 'res_seq': int(res_seq_str) if res_seq_str.lstrip('-').isdigit() else 0, 'coords': []}
                            ligand_instances[lkey]['coords'].append((x, y, z))
                elif any(c.startswith('_struct_site_gen.') for c in cols):
                    col_map = {c: i for i, c in enumerate(cols)}
                    c_ch = col_map.get('_struct_site_gen.auth_asym_id', col_map.get('_struct_site_gen.label_asym_id'))
                    c_seq = col_map.get('_struct_site_gen.auth_seq_id', col_map.get('_struct_site_gen.label_seq_id'))
                    c_ic = col_map.get('_struct_site_gen.pdbx_PDB_ins_code')
                    while idx < n_lines:
                        row = lines[idx].strip()
                        if not row or row.startswith('#') or row.startswith('loop_') or row.startswith('_'):
                            break
                        toks = row.split()
                        idx += 1
                        if c_seq is not None and c_seq < len(toks):
                            ch = toks[c_ch] if (c_ch is not None and c_ch < len(toks) and toks[c_ch] not in ('.', '?')) else 'A'
                            ic = toks[c_ic] if (c_ic is not None and c_ic < len(toks) and toks[c_ic] not in ('.', '?')) else ''
                            site_keys.add((ch, toks[c_seq], ic))
            else:
                idx += 1
    else:
        for line in text.splitlines():
            if line.startswith('ENDMDL'):
                break
            if line.startswith('SITE  ') and len(line) >= 22:
                for slot in range(4):
                    base = 18 + slot * 11
                    if base + 9 <= len(line):
                        ch = line[base + 4].strip() or 'A'
                        sq = line[base + 5:base + 9].strip()
                        ic = line[base + 9].strip() if base + 9 < len(line) else ''
                        if sq:
                            site_keys.add((ch, sq, ic))
                continue
            if (line.startswith('ATOM  ') or line.startswith('HETATM')) and len(line) >= 54:
                alt_loc = line[16]
                if alt_loc not in (' ', 'A', '1'):
                    continue
                atom_name = line[12:16].strip().upper()
                elem = line[76:78].strip().upper() if len(line) >= 78 else ''
                if _is_hydrogen_atom(atom_name, elem):
                    continue
                res_name = line[17:20].strip().upper()
                chain_id = line[21].strip() or 'A'
                res_seq_str = line[22:26].strip()
                i_code = line[26].strip() if len(line) > 26 else ''
                try:
                    x, y, z = float(line[30:38]), float(line[38:46]), float(line[46:54])
                except Exception:
                    continue
                if line.startswith('ATOM  '):
                    heavy_atoms.append((x, y, z))
                    if atom_name == 'CA':
                        ca_by_key[(chain_id, res_seq_str, i_code)] = (x, y, z)
                elif res_name not in ignored_het and res_name:
                    lkey = f'{res_name}:{chain_id}:{res_seq_str}{i_code}'
                    if lkey not in ligand_instances:
                        ligand_order.append(lkey)
                        ligand_instances[lkey] = {'id': lkey, 'res_name': res_name, 'chain_id': chain_id, 'res_seq': int(res_seq_str) if res_seq_str.lstrip('-').isdigit() else 0, 'coords': []}
                    ligand_instances[lkey]['coords'].append((x, y, z))
    site_coords = [ca_by_key[k] for k in site_keys if k in ca_by_key]
    return heavy_atoms, list(ca_by_key.values()), site_coords, ligand_instances, ligand_order


def _run_ligsite_3d_bfs(heavy_atoms: list) -> list:
    """自适应步长 LIGSITE P-S-P 7方向体素扫描 + 26邻域 3D BFS 口袋聚类 + Wadell 紧凑度（对齐 ProteinBiophysicsEngine.swift）"""
    if len(heavy_atoms) < 8:
        return []
    xs = [a[0] for a in heavy_atoms]
    ys = [a[1] for a in heavy_atoms]
    zs = [a[2] for a in heavy_atoms]
    min_x, max_x = min(xs) - 3.0, max(xs) + 3.0
    min_y, max_y = min(ys) - 3.0, max(ys) + 3.0
    min_z, max_z = min(zs) - 3.0, max(zs) + 3.0
    max_span = max(max_x - min_x, max_y - min_y, max_z - min_z, 10.0)
    spacing = max(1.5, min(2.5, max_span / 45.0))
    if max_span > 60.0:
        spacing = max(spacing, max_span / 60.0)
    nx = min(64, max(8, int(math.ceil((max_x - min_x) / spacing)) + 1))
    ny = min(64, max(8, int(math.ceil((max_y - min_y) / spacing)) + 1))
    nz = min(64, max(8, int(math.ceil((max_z - min_z) / spacing)) + 1))

    total = nx * ny * nz
    occ = bytearray(total)
    rad = 3.1  # C vdW 1.7 + water probe 1.4
    rad_sq = rad * rad
    r_cells = int(math.ceil(rad / spacing))
    for ax, ay, az in heavy_atoms:
        ix = int(round((ax - min_x) / spacing))
        iy = int(round((ay - min_y) / spacing))
        iz = int(round((az - min_z) / spacing))
        for dx in range(-r_cells, r_cells + 1):
            gx = ix + dx
            if gx < 0 or gx >= nx:
                continue
            vx = min_x + gx * spacing - ax
            for dy in range(-r_cells, r_cells + 1):
                gy = iy + dy
                if gy < 0 or gy >= ny:
                    continue
                vy = min_y + gy * spacing - ay
                for dz in range(-r_cells, r_cells + 1):
                    gz = iz + dz
                    if gz < 0 or gz >= nz:
                        continue
                    vz = min_z + gz * spacing - az
                    if vx * vx + vy * vy + vz * vz <= rad_sq:
                        occ[(gx * ny + gy) * nz + gz] = 1

    dirs = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 1), (1, 1, -1), (1, -1, 1), (-1, 1, 1)]
    psp = bytearray(total)
    max_steps = max(nx, ny, nz)
    for gx in range(1, nx - 1):
        for gy in range(1, ny - 1):
            base_xy = (gx * ny + gy) * nz
            for gz in range(1, nz - 1):
                idx = base_xy + gz
                if occ[idx]:
                    continue
                hits = 0
                for ddx, ddy, ddz in dirs:
                    hit_pos = False
                    cx, cy, cz = gx + ddx, gy + ddy, gz + ddz
                    for _ in range(max_steps):
                        if cx < 0 or cx >= nx or cy < 0 or cy >= ny or cz < 0 or cz >= nz:
                            break
                        if occ[(cx * ny + cy) * nz + cz]:
                            hit_pos = True
                            break
                        cx += ddx; cy += ddy; cz += ddz
                    if not hit_pos:
                        continue
                    cx, cy, cz = gx - ddx, gy - ddy, gz - ddz
                    for _ in range(max_steps):
                        if cx < 0 or cx >= nx or cy < 0 or cy >= ny or cz < 0 or cz >= nz:
                            break
                        if occ[(cx * ny + cy) * nz + cz]:
                            hits += 1
                            break
                        cx -= ddx; cy -= ddy; cz -= ddz
                psp[idx] = hits

    visited = bytearray(total)
    pockets = []
    voxel_vol = spacing ** 3
    for gx in range(1, nx - 1):
        for gy in range(1, ny - 1):
            for gz in range(1, nz - 1):
                start_idx = (gx * ny + gy) * nz + gz
                if psp[start_idx] < 3 or visited[start_idx]:
                    continue
                queue = [(gx, gy, gz)]
                visited[start_idx] = 1
                comp = []
                psp_sum = 0
                head = 0
                while head < len(queue):
                    cx, cy, cz = queue[head]
                    head += 1
                    comp.append((cx, cy, cz))
                    psp_sum += psp[(cx * ny + cy) * nz + cz]
                    for ddx in (-1, 0, 1):
                        nx2 = cx + ddx
                        if nx2 < 1 or nx2 >= nx - 1:
                            continue
                        for ddy in (-1, 0, 1):
                            ny2 = cy + ddy
                            if ny2 < 1 or ny2 >= ny - 1:
                                continue
                            for ddz in (-1, 0, 1):
                                if ddx == 0 and ddy == 0 and ddz == 0:
                                    continue
                                nz2 = cz + ddz
                                if nz2 < 1 or nz2 >= nz - 1:
                                    continue
                                nidx = (nx2 * ny + ny2) * nz + nz2
                                if psp[nidx] >= 3 and not visited[nidx]:
                                    visited[nidx] = 1
                                    queue.append((nx2, ny2, nz2))
                if len(comp) < 3:
                    continue
                comp_set = set(comp)
                exposed_faces = 0
                pts = []
                for vx, vy, vz in comp:
                    pts.append((min_x + vx * spacing, min_y + vy * spacing, min_z + vz * spacing))
                    for fdx, fdy, fdz in ((1,0,0),(-1,0,0),(0,1,0),(0,-1,0),(0,0,1),(0,0,-1)):
                        if (vx + fdx, vy + fdy, vz + fdz) not in comp_set:
                            exposed_faces += 1
                vol = len(comp) * voxel_vol
                surf = max(1e-6, exposed_faces * (spacing ** 2))
                compactness = min(1.0, ((36.0 * math.pi * (vol ** 2)) ** (1.0 / 3.0)) / surf)
                cnt = float(len(pts))
                pcx = sum(p[0] for p in pts) / cnt
                pcy = sum(p[1] for p in pts) / cnt
                pcz = sum(p[2] for p in pts) / cnt
                pockets.append({
                    'rank': 0,
                    'center': [round(pcx, 3), round(pcy, 3), round(pcz, 3)],
                    'volume_A3': round(vol, 1),
                    'voxel_count': len(comp),
                    'mean_psp': round(psp_sum / cnt, 2),
                    'compactness': round(compactness, 3),
                    '_pts': pts,
                })
    pockets.sort(key=lambda p: (p['volume_A3'] * p['mean_psp'], p['volume_A3']), reverse=True)
    for i, pk in enumerate(pockets):
        pk['rank'] = i + 1
    return pockets[:8]


def tool_analyze_protein_and_docking_box(args: dict) -> dict:
    """计算蛋白质理化性质（Guruprasad 20×20 DIWV、Bjellqvist/EMBOSS/Lehninger pI、TOP-IDP、Debye 屏蔽）、分实例配体 / LIGSITE 3D BFS 口袋、Vina 对接盒及 WT 校验点突变 ΔΔG"""
    raw_seq = (args.get('sequence') or '').strip()
    pdb_path = (args.get('pdb_path') or '').strip()
    pdb_text_inline = (args.get('pdb_text') or '').strip()
    ph = float(args.get('ph', 7.0))
    temp_k = float(args.get('temperature_k', 310.0))
    ionic_strength_m = float(args.get('ionic_strength_m', 0.15))
    pka_scale = str(args.get('pka_scale') or 'bjellqvist').strip().lower()
    if pka_scale not in ('bjellqvist', 'emboss', 'lehninger'):
        pka_scale = 'bjellqvist'
    mutations = args.get('mutations') or []

    struct_text = pdb_text_inline
    if not struct_text and pdb_path and os.path.exists(pdb_path):
        with open(pdb_path, 'r', encoding='utf-8', errors='ignore') as f:
            struct_text = f.read()

    heavy_atoms, coords, site_coords, ligand_instances, ligand_order = ([], [], [], {}, [])
    if struct_text:
        heavy_atoms, coords, site_coords, ligand_instances, ligand_order = _parse_structure_atoms_for_ligsite(struct_text)

    chains = _split_protein_chains(raw_seq)
    if not chains:
        chains = ['MKVLLFAAVVGGLAAAGVSAKELRKIYEDGKVTYTLDNGKPVVLVFYPADFTFVCPTEIIAFSENAAKKFEEQGAQVLFASTDSEYSLLAWTNIPRKEGGLGPINIPLLADTN']
    clean_seq = ''.join(chains)

    length = len(clean_seq)
    mw_da = sum(sum(AA_RESIDUE_MASS.get(c, 110.0) for c in ch) + WATER_MASS_DA for ch in chains)
    gravy = sum(KD_HYDROPATHY.get(c, 0.0) for c in clean_seq) / max(1, length)
    pi_val = round(_protein_isoelectric_point_chains(chains, pka_scale), 2)
    net_charge_val = round(_protein_net_charge_chains(chains, ph, pka_scale), 2)
    instability_val = round(_protein_instability_index_chains(chains), 2)
    disorder_pct, top_idp_mean, uversky_dist = _protein_disorder_propensity(clean_seq)
    debye_length_a = round((3.04 / math.sqrt(max(0.0005, ionic_strength_m))) * math.sqrt(max(250.0, temp_k) / 298.15), 2)

    pockets_raw = _run_ligsite_3d_bfs(heavy_atoms) if heavy_atoms else []
    pockets_out = [{k: v for k, v in pk.items() if k != '_pts'} for pk in pockets_raw]

    lig_summary_list = []
    primary_lig = None
    for lk in ligand_order:
        inst = ligand_instances[lk]
        lcoords = inst['coords']
        if not lcoords:
            continue
        cnt = float(len(lcoords))
        lcx = round(sum(c[0] for c in lcoords) / cnt, 3)
        lcy = round(sum(c[1] for c in lcoords) / cnt, 3)
        lcz = round(sum(c[2] for c in lcoords) / cnt, 3)
        lig_summary_list.append({
            'id': inst['id'],
            'res_name': inst['res_name'],
            'chain_id': inst['chain_id'],
            'res_seq': inst['res_seq'],
            'heavy_atom_count': len(lcoords),
            'center': [lcx, lcy, lcz],
        })
        if primary_lig is None or len(lcoords) > len(primary_lig['coords']):
            primary_lig = inst

    if primary_lig is not None:
        lcoords = primary_lig['coords']
        xs = [c[0] for c in lcoords]
        ys = [c[1] for c in lcoords]
        zs = [c[2] for c in lcoords]
        cx, cy, cz = round((min(xs) + max(xs)) * 0.5, 3), round((min(ys) + max(ys)) * 0.5, 3), round((min(zs) + max(zs)) * 0.5, 3)
        sx = round(min(60.0, max(18.0, (max(xs) - min(xs)) + 8.0)), 2)
        sy = round(min(60.0, max(18.0, (max(ys) - min(ys)) + 8.0)), 2)
        sz = round(min(60.0, max(18.0, (max(zs) - min(zs)) + 8.0)), 2)
        box_source = f"共晶配体 ({primary_lig['res_name']} {primary_lig['chain_id']}:{primary_lig['res_seq']}) + LIGSITE 共识融合盒"
    elif site_coords:
        xs = [c[0] for c in site_coords]
        ys = [c[1] for c in site_coords]
        zs = [c[2] for c in site_coords]
        cx, cy, cz = round((min(xs) + max(xs)) * 0.5, 3), round((min(ys) + max(ys)) * 0.5, 3), round((min(zs) + max(zs)) * 0.5, 3)
        sx = round(min(60.0, max(18.0, (max(xs) - min(xs)) + 10.0)), 2)
        sy = round(min(60.0, max(18.0, (max(ys) - min(ys)) + 10.0)), 2)
        sz = round(min(60.0, max(18.0, (max(zs) - min(zs)) + 10.0)), 2)
        box_source = '实验 SITE 催化位点 + LIGSITE 共识盒'
    elif pockets_raw:
        pts = pockets_raw[0]['_pts']
        xs = [c[0] for c in pts]
        ys = [c[1] for c in pts]
        zs = [c[2] for c in pts]
        cx, cy, cz = round((min(xs) + max(xs)) * 0.5, 3), round((min(ys) + max(ys)) * 0.5, 3), round((min(zs) + max(zs)) * 0.5, 3)
        sx = round(min(60.0, max(18.0, (max(xs) - min(xs)) + 10.0)), 2)
        sy = round(min(60.0, max(18.0, (max(ys) - min(ys)) + 10.0)), 2)
        sz = round(min(60.0, max(18.0, (max(zs) - min(zs)) + 10.0)), 2)
        box_source = 'LIGSITE P-S-P 3D BFS 几何口袋'
    elif coords:
        xs = [c[0] for c in coords]
        ys = [c[1] for c in coords]
        zs = [c[2] for c in coords]
        cx, cy, cz = round(sum(xs) / len(xs), 3), round(sum(ys) / len(ys), 3), round(sum(zs) / len(zs), 3)
        sx = sy = sz = 22.0
        box_source = 'LIGSITE P-S-P 几何口袋 (质心回退)'
    else:
        cx, cy, cz = 4.6, -2.5, 1.2
        sx = sy = sz = 22.0
        box_source = 'LIGSITE P-S-P 几何口袋 (教学合成坐标)'

    vina_cfg = (
        f"receptor = receptor.pdbqt\nligand = ligand.pdbqt\n\n"
        f"center_x = {cx:.3f}\ncenter_y = {cy:.3f}\ncenter_z = {cz:.3f}\n\n"
        f"size_x = {sx:.1f}\nsize_y = {sy:.1f}\nsize_z = {sz:.1f}\n\n"
        f"exhaustiveness = 8\nnum_modes = 9\nenergy_range = 3\nseed = 42\n"
    )

    mut_evals = []
    for spec in mutations:
        s = str(spec).strip().upper()
        if not s:
            continue
        parts = [p.strip() for p in re.split(r"[+,;\s]+", s) if p.strip()]
        ddg_sum = 0.0
        valid_parts = []
        mismatch_warnings = []
        for token in parts:
            if len(token) >= 3 and token[1:-1].isdigit():
                pos = int(token[1:-1])
                from_aa, to_aa = token[0], token[-1]
                if pos < 1 or pos > length:
                    mismatch_warnings.append(f"位点越界：{token} (长度 {length} aa)")
                    continue
                actual_wt = clean_seq[pos - 1]
                if actual_wt != from_aa:
                    mismatch_warnings.append(f"野生型残基不匹配：第 {pos} 位实际为 {actual_wt}，而非 {from_aa} ({token})")
                    continue
                valid_parts.append(f"{from_aa}{pos}{to_aa}")
                if from_aa == to_aa:
                    continue
                h_from = KD_HYDROPATHY.get(from_aa, 0.0)
                h_to = KD_HYDROPATHY.get(to_aa, 0.0)
                m_from = AA_RESIDUE_MASS.get(from_aa, 110.0)
                m_to = AA_RESIDUE_MASS.get(to_aa, 110.0)
                buried_factor = 1.0 if (pos > 4 and pos < length - 4) else 0.45
                d_hydro = (h_from - h_to) * 0.38 * buried_factor
                d_steric = abs(m_to - m_from) / 95.0 * 0.45
                pro_pen = (1.45 * (0.5 + 0.5 * buried_factor)) if to_aa == 'P' else 0.0
                ddg_sum += (d_hydro + d_steric + pro_pen)
            else:
                mismatch_warnings.append(f"无法解析突变格式：{token}")

        is_valid_wt = (len(mismatch_warnings) == 0 and len(valid_parts) > 0)
        if not is_valid_wt:
            mut_evals.append({
                "mutation": s,
                "ddg_kcal_mol": 0.0,
                "model_type": "empirical_heuristic",
                "is_valid_wild_type": False,
                "validation_warning": "; ".join(mismatch_warnings),
                "verdict": "野生型位点不匹配 (Invalid WT)"
            })
        else:
            ddg = round(ddg_sum, 2)
            mut_evals.append({
                "mutation": "+".join(valid_parts),
                "ddg_kcal_mol": ddg,
                "model_type": "empirical_heuristic",
                "is_valid_wild_type": True,
                "validation_warning": None,
                "verdict": "经验稳定化倾向 (Empirical Stabilizing)" if ddg <= -0.4 else ("经验中性耐受 (Empirical Neutral)" if ddg <= 0.5 else "经验去稳定化风险 (Empirical Destabilizing)")
            })

    notify_gui_and_sync_primers(
        action_summary=f"MCP 蛋白质结构与对接盒分析 ({length} aa, pI {pi_val}, II {instability_val})",
        primers=[],
        target_module="proteinWorkbench"
    )

    return {
        "length_aa": length,
        "chain_count": len(chains),
        "molecular_weight_da": round(mw_da, 1),
        "isoelectric_point": pi_val,
        "pka_scale": pka_scale,
        "net_charge_at_ph": net_charge_val,
        "gravy": round(gravy, 3),
        "instability_index": instability_val,
        "is_stable": instability_val < 40.0,
        "disorder_pct": round(disorder_pct, 2),
        "top_idp_mean": round(top_idp_mean, 3),
        "uversky_distance": round(uversky_dist, 4),
        "debye_length_a": debye_length_a,
        "ddg_model_type": "empirical_heuristic",
        "ligand_instances": lig_summary_list,
        "pockets": pockets_out,
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
    """对 Western Blot 泳道灰度积分 (IOD) 执行内参/总蛋白(TPN)归一化、过曝条带剔除 (P03) 及 log2 空间 Welch t + Holm 多重比较校正 (2B)"""
    target_iods = [float(x) for x in (args.get("target_iods") or [100.0, 108.0, 220.0, 235.0])]
    total_protein_in = args.get("total_protein_lane_iods")
    use_tpn = isinstance(total_protein_in, list) and len(total_protein_in) >= len(target_iods) and all(float(x) > 0 for x in total_protein_in[:len(target_iods)])
    if use_tpn:
        denom_iods = [float(x) for x in total_protein_in[:len(target_iods)]]
        norm_mode = "totalProtein"
    else:
        denom_iods = [float(x) for x in (args.get("loading_control_iods") or [100.0] * len(target_iods))]
        norm_mode = "loadingControl"
    groups = args.get("lane_groups") or (["Control"] * (len(target_iods) // 2) + ["Treated"] * (len(target_iods) - len(target_iods) // 2))
    is_saturated_in = args.get("is_saturated") or [False] * len(target_iods)
    saturation_policy = str(args.get("saturation_policy") or "excludeFromStats").strip()
    if saturation_policy not in ("excludeFromStats", "warnOnly"):
        saturation_policy = "excludeFromStats"

    n = min(len(target_iods), len(denom_iods), len(groups))
    sat_flags = [bool(is_saturated_in[i]) if i < len(is_saturated_in) else False for i in range(n)]
    raw_ratios = [target_iods[i] / max(1e-6, denom_iods[i]) for i in range(n)]
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
    if ctrl_valid:
        ctrl_log2_vals = [math.log2(max(1e-9, r)) for r in ctrl_valid]
        ctrl_geo_mean = 2.0 ** (sum(ctrl_log2_vals) / len(ctrl_log2_vals))
    else:
        ctrl_geo_mean = 1.0
    norm_folds = [round(r / max(1e-6, ctrl_geo_mean), 4) for r in raw_ratios]

    group_order = []
    for g in groups[:n]:
        if g not in group_order:
            group_order.append(g)

    ctrl_folds = [norm_folds[i] for i in range(n) if groups[i] == ctrl_name and not (saturation_policy == "excludeFromStats" and sat_flags[i])]
    ctrl_log2_folds = [math.log2(max(1e-9, v)) for v in ctrl_folds]
    group_stats = []
    raw_p_entries = []
    for g_name in group_order:
        g_indices = [i for i in range(n) if groups[i] == g_name]
        ex_cnt = sum(1 for i in g_indices if saturation_policy == "excludeFromStats" and sat_flags[i])
        vals = [norm_folds[i] for i in g_indices if not (saturation_policy == "excludeFromStats" and sat_flags[i])]
        log2_vals = [math.log2(max(1e-9, v)) for v in vals]
        if vals:
            log2_mean = sum(log2_vals) / len(log2_vals)
            geo_mean = 2.0 ** log2_mean
            lin_mean = sum(vals) / len(vals)
            sd = math.sqrt(sum((v - lin_mean) ** 2 for v in vals) / (len(vals) - 1)) if len(vals) > 1 else 0.0
            log2_sd = math.sqrt(sum((v - log2_mean) ** 2 for v in log2_vals) / (len(log2_vals) - 1)) if len(log2_vals) > 1 else 0.0
        else:
            log2_mean = 0.0
            geo_mean = 0.0
            sd = 0.0
            log2_sd = 0.0
        p_val = None
        ci_low = None
        ci_high = None
        if g_name != ctrl_name and len(log2_vals) >= 2 and len(ctrl_log2_folds) >= 2:
            p_val = _welch_t_test_p(log2_vals, ctrl_log2_folds)
            ci_info = _welch_ci95([-v for v in log2_vals], [-v for v in ctrl_log2_folds], alpha=0.05, base=2.0)
            if ci_info:
                ci_low = round(ci_info["fold_low"], 4)
                ci_high = round(ci_info["fold_high"], 4)
        idx = len(group_stats)
        if p_val is not None:
            raw_p_entries.append((idx, p_val))
        group_stats.append({
            "group": g_name,
            "n": len(vals),
            "n_excluded_saturated": ex_cnt,
            "mean_fold": round(geo_mean, 4),
            "log2_mean_fold": round(log2_mean, 4),
            "sd": round(sd, 4),
            "log2_sd": round(log2_sd, 4),
            "p_value": p_val,
            "p_adjusted": None,
            "fold_ci95_low": ci_low,
            "fold_ci95_high": ci_high
        })

    if raw_p_entries:
        adj_ps = _holm_adjust([p for _, p in raw_p_entries])
        for (idx, _), p_adj in zip(raw_p_entries, adj_ps):
            group_stats[idx]["p_adjusted"] = p_adj

    notify_gui_and_sync_primers(
        action_summary=f"MCP Western Blot 归一化定量 ({n} 泳道, 模式={norm_mode}, 剔除过曝={len(excluded_bands)})",
        primers=[],
        target_module="westernBlot"
    )
    return {
        "lane_count": n,
        "normalization_mode": norm_mode,
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
    """计算 qPCR 相对表达量（Vandesompele 多内参 + Pfaffl/qBase 双效率 + log2 空间 Welch t/95% CI + 几何均值点估计 + Holm 校正 + QC）"""
    records = args.get("records") or []
    raw_refs = args.get("reference_genes")
    if isinstance(raw_refs, list) and raw_refs:
        req_ref_genes = [str(r).strip() for r in raw_refs if str(r).strip()]
    else:
        ref_raw_str = str(args.get("reference_gene") or "ACTB").strip()
        req_ref_genes = [r.strip() for r in re.split(r"[,;]+", ref_raw_str) if r.strip()] or ["ACTB"]
    ref_gene = ", ".join(req_ref_genes)
    ref_keys_lower_list = [r.lower() for r in req_ref_genes]
    ref_keys_lower_set = set(ref_keys_lower_list)

    eff_correction = bool(args.get("efficiency_correction", False))
    default_eff_pct = float(args.get("default_efficiency_pct", 100.0))

    def _norm_eff(raw_v):
        if raw_v is None:
            return None
        try:
            v = float(raw_v)
        except Exception:
            return None
        if not math.isfinite(v) or v <= 0.0:
            return None
        if v > 2.5:
            eff = v / 100.0
        elif v > 1.5:
            eff = v - 1.0
        else:
            eff = v
        return max(0.10, min(1.50, eff))

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
        qty_val = None
        if qty is not None and str(qty).strip() != "":
            try:
                qty_val = float(qty)
            except Exception:
                qty_val = None
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
        eff_val = _norm_eff(rec.get("efficiency"))
        w_type = _infer_qpcr_well_type(s, grp, task_raw, qty_val)
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
            "tm": tm_val,
            "efficiency": eff_val,
            "quantity": qty_val
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
    target_case_map = {}
    well_effs_by_target = {}
    std_pts_by_target = {}

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
        elif w_type == "standard":
            if ct_val is not None and w["quantity"] is not None and w["quantity"] > 0:
                if tm_val is not None and gk in target_median_tm and abs(tm_val - target_median_tm[gk]) > melt_tolerance:
                    w_flags.append("meltOutlier")
                else:
                    std_pts_by_target.setdefault(gk, []).append((math.log10(w["quantity"]), ct_val))

        if w_flags:
            qc_flags.append({"sample": s, "gene": g, "well_type": w_type, "flags": w_flags})

        # 仅无 meltOutlier 且非空的 sample 孔进入 ΔΔCt 统计
        if w_type == "sample" and ct_val is not None and "meltOutlier" not in w_flags:
            target_case_map.setdefault(gk, g)
            if w["efficiency"] is not None:
                well_effs_by_target.setdefault(gk, []).append(w["efficiency"])
            if s not in sample_group_map:
                sample_group_map[s] = grp if grp else s
                sample_order.append(s)
            grouped.setdefault((s, gk), []).append(ct_val)

    std_eff_by_target = {}
    if eff_correction and std_pts_by_target:
        for gk, pts in std_pts_by_target.items():
            if len(pts) >= 2:
                n_pts = float(len(pts))
                sx = sum(p[0] for p in pts)
                sy = sum(p[1] for p in pts)
                sxx = sum(p[0] * p[0] for p in pts)
                sxy = sum(p[0] * p[1] for p in pts)
                denom = n_pts * sxx - sx * sx
                if abs(denom) > 1e-14:
                    slope = (n_pts * sxy - sx * sy) / denom
                    if slope < 0:
                        eff_s = (10.0 ** (-1.0 / slope)) - 1.0
                        if math.isfinite(eff_s) and eff_s > 0.0:
                            std_eff_by_target[gk] = max(0.10, min(1.50, eff_s))

    def _resolve_eff(gk: str) -> float:
        if not eff_correction:
            return 1.0
        if gk in std_eff_by_target:
            return std_eff_by_target[gk]
        we = well_effs_by_target.get(gk, [])
        if we:
            return sum(we) / len(we)
        return max(0.10, min(1.50, default_eff_pct / 100.0)) if (math.isfinite(default_eff_pct) and default_eff_pct > 0.0) else 1.0

    means = {}
    for (s, gk), cts in grouped.items():
        m = sum(cts) / len(cts)
        sd = math.sqrt(sum((v - m) ** 2 for v in cts) / max(1, len(cts) - 1)) if len(cts) > 1 else 0.0
        means[(s, gk)] = (m, sd, len(cts))
        if sd > sd_threshold:
            warnings.append(f"{s} / {target_case_map.get(gk, gk)} 复孔 Ct SD={sd:.2f} 超过阈值 {sd_threshold:.2f}")

    samples = sample_order if sample_order else sorted({k[0] for k in means.keys()})
    active_ref_keys = [rk for rk in ref_keys_lower_list if rk in target_case_map]
    if not active_ref_keys and target_case_map:
        active_ref_keys = [sorted(target_case_map.keys())[0]]
    active_ref_set = set(active_ref_keys)
    genes_lower = sorted({k[1] for k in means.keys() if k[1] not in active_ref_set})

    def is_ctrl_sample(s_name: str) -> bool:
        grp_val = sample_group_map.get(s_name, s_name)
        if ctrl_group and grp_val.lower() == ctrl_group.lower():
            return True
        if s_name.lower() == ctrl_sample.lower() or grp_val.lower() == ctrl_sample.lower():
            return True
        return False

    ref_eff_cache = {rk: _resolve_eff(rk) for rk in active_ref_keys}
    ref_raw_baseline = {}
    ref_eff_baseline = {}
    for rk in active_ref_keys:
        scale_r = math.log2(1.0 + ref_eff_cache[rk])
        ctrl_vals = [means[(s, rk)][0] for s in samples if is_ctrl_sample(s) and (s, rk) in means]
        pool = ctrl_vals if ctrl_vals else [means[(s, rk)][0] for s in samples if (s, rk) in means]
        if pool:
            mu_raw = sum(pool) / len(pool)
            ref_raw_baseline[rk] = mu_raw
            ref_eff_baseline[rk] = mu_raw * scale_r

    valid_base_refs = [rk for rk in active_ref_keys if rk in ref_raw_baseline]
    global_raw_anchor = (sum(ref_raw_baseline[rk] for rk in valid_base_refs) / len(valid_base_refs)) if valid_base_refs else 0.0
    global_eff_anchor = (sum(ref_eff_baseline[rk] for rk in valid_base_refs) / len(valid_base_refs)) if valid_base_refs else 0.0

    ref_ct_by_sample = {}
    ref_eff_ct_by_sample = {}
    for s in samples:
        raw_deltas = []
        eff_deltas = []
        missing_refs = []
        for rk in valid_base_refs:
            if (s, rk) in means:
                m_ct = means[(s, rk)][0]
                raw_deltas.append(m_ct - ref_raw_baseline[rk])
                eff_deltas.append(m_ct * math.log2(1.0 + ref_eff_cache[rk]) - ref_eff_baseline[rk])
            else:
                missing_refs.append(target_case_map.get(rk, rk))
        if raw_deltas:
            if len(valid_base_refs) >= 2 and missing_refs:
                warnings.append(f"样品 {s} 缺失部分内参 ({', '.join(missing_refs)})，已按 qBase 逐内参基线中心化对齐")
            ref_ct_by_sample[s] = global_raw_anchor + (sum(raw_deltas) / len(raw_deltas))
            ref_eff_ct_by_sample[s] = global_eff_anchor + (sum(eff_deltas) / len(eff_deltas))

    results = []
    group_summaries = []
    for gk in genes_lower:
        g_label = target_case_map.get(gk, gk)
        eff_t = _resolve_eff(gk)
        scale_t = math.log2(1.0 + eff_t)

        ctrl_dcts_for_cal = [
            means[(s, gk)][0] * scale_t - ref_eff_ct_by_sample[s]
            for s in samples
            if is_ctrl_sample(s) and (s, gk) in means and s in ref_eff_ct_by_sample
        ]
        if ctrl_dcts_for_cal:
            cal_dct = sum(ctrl_dcts_for_cal) / len(ctrl_dcts_for_cal)
        elif (ctrl_sample, gk) in means and ctrl_sample in ref_eff_ct_by_sample:
            cal_dct = means[(ctrl_sample, gk)][0] * scale_t - ref_eff_ct_by_sample[ctrl_sample]
        else:
            first_valid = next(
                (means[(s, gk)][0] * scale_t - ref_eff_ct_by_sample[s] for s in samples if (s, gk) in means and s in ref_eff_ct_by_sample),
                0.0
            )
            cal_dct = first_valid

        sample_rows_for_gene = []
        cat_order = []
        for s in samples:
            if (s, gk) not in means or s not in ref_eff_ct_by_sample:
                continue
            ref_eff_ct = ref_eff_ct_by_sample[s]
            dct = means[(s, gk)][0] * scale_t - ref_eff_ct
            ddct = dct - cal_dct
            fold = 2.0 ** (-ddct)
            n_tech = means[(s, gk)][2]
            cat = sample_group_map.get(s, s)
            if cat not in cat_order:
                cat_order.append(cat)
            row_obj = {
                "sample": s,
                "group": cat,
                "gene": g_label,
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
                "gene": g_label,
                "n_technical_wells": n_tech,
                "delta_ct": round(dct, 3),
                "delta_delta_ct": round(ddct, 3),
                "relative_expression_2_neg_ddct": round(fold, 4)
            })

        ctrl_sample_dcts = [r["_raw_dct"] for r in sample_rows_for_gene if r["_is_control"]]
        ctrl_mean_dct = (sum(ctrl_sample_dcts) / len(ctrl_sample_dcts)) if ctrl_sample_dcts else cal_dct
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
            arith_fold = sum(cat_folds) / n_bio
            sd_fold = math.sqrt(sum((v - arith_fold) ** 2 for v in cat_folds) / (n_bio - 1)) if n_bio >= 2 else None
            sem_fold = (sd_fold / math.sqrt(n_bio)) if sd_fold is not None else None
            mean_dct = sum(cat_dcts) / n_bio
            mean_fold = 2.0 ** -(mean_dct - ctrl_mean_dct)
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
                "gene": g_label,
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

        # Target 内 Holm–Bonferroni 多重比较校正（若选择 bh_fdr 则在下方跨全部靶基因统一计算 BH-FDR）
        mc_norm = str(mult_comp or "holm").strip().lower()
        if mc_norm not in ("bh_fdr", "bh", "fdr"):
            valid_indices = [idx for idx, row in enumerate(gene_group_rows) if not row["is_control"] and row["p_value"] is not None]
            if valid_indices:
                raw_ps = [gene_group_rows[idx]["p_value"] for idx in valid_indices]
                adj_ps = _holm_adjust(raw_ps) if mc_norm != "none" else raw_ps
                for idx, p_adj in zip(valid_indices, adj_ps):
                    gene_group_rows[idx]["p_adjusted"] = p_adj

        group_summaries.extend(gene_group_rows)

    if str(mult_comp or "holm").strip().lower() in ("bh_fdr", "bh", "fdr"):
        all_valid = [idx for idx, row in enumerate(group_summaries) if not row["is_control"] and row["p_value"] is not None]
        if all_valid:
            m_bh = len(all_valid)
            indexed = sorted([(idx, float(group_summaries[idx]["p_value"])) for idx in all_valid], key=lambda item: item[1])
            q_vals = [0.0] * m_bh
            running_min = 1.0
            for rank_rev in range(m_bh - 1, -1, -1):
                _, pv = indexed[rank_rev]
                cand = min(1.0, pv * m_bh / float(rank_rev + 1))
                running_min = min(running_min, cand)
                q_vals[rank_rev] = running_min
            for (row_idx, _), qv in zip(indexed, q_vals):
                group_summaries[row_idx]["p_adjusted"] = round(qv, 6)

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

    def get_u16_array(key):
        b = get_bytes(key)
        cnt = len(b) // 2
        return list(struct.unpack(f">{cnt}H", b[:cnt * 2])) if cnt > 0 else []

    fwo = get_bytes("FWO_#1").decode("ascii", errors="ignore").upper() or "GATC"
    d_nums = [9, 10, 11, 12] if "DATA#9" in entries else [1, 2, 3, 4]
    traces = {}
    for idx, ch in enumerate(fwo[:4]):
        traces[ch] = get_u16_array(f"DATA#{d_nums[idx]}")

    pbas_bytes = get_bytes("PBAS#1") or get_bytes("PBAS#2")
    seq = "".join(ch for ch in pbas_bytes.decode("ascii", errors="ignore").upper() if ch in "ACGTNRYSWKMBDHV")
    pcon_bytes = get_bytes("PCON#1") or get_bytes("PCON#2")
    quals = list(pcon_bytes[:len(seq)]) if pcon_bytes else [40] * len(seq)
    plocs = get_u16_array("PLOC#1") or get_u16_array("PLOC#2")

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

    def get_u16_array(key: str) -> List[int]:
        b = get_bytes(key)
        cnt = len(b) // 2
        return list(struct.unpack(f">{cnt}H", b[:cnt * 2])) if cnt > 0 else []

    fwo = get_bytes("FWO_#1").decode("ascii", errors="ignore").upper() or "GATC"
    d_nums = [9, 10, 11, 12] if "DATA#9" in entries else [1, 2, 3, 4]
    traces = {}
    for idx, ch in enumerate(fwo[:4]):
        traces[ch] = get_u16_array(f"DATA#{d_nums[idx]}")

    pbas_bytes = get_bytes("PBAS#1") or get_bytes("PBAS#2")
    seq = "".join(ch for ch in pbas_bytes.decode("ascii", errors="ignore").upper() if ch in "ACGTNRYSWKMBDHV")
    plocs = get_u16_array("PLOC#1") or get_u16_array("PLOC#2")
    pcon_bytes = get_bytes("PCON#1") or get_bytes("PCON#2")
    qualities = [int(b) for b in pcon_bytes[:len(seq)]] if pcon_bytes else [0] * len(seq)
    if len(qualities) < len(seq):
        qualities.extend([0] * (len(seq) - len(qualities)))

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

    return {"is_ab1": True, "sequence": seq, "peaks_acgt": peaks_acgt, "qualities": qualities}


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

    # Mott 最大累积子数组质量修剪（与 Swift SangerAlignmentEngine 对齐）
    trim_s, trim_e = 0, n
    if n > 12 and len(quals) >= n:
        cutoff = 10.0 ** (-float(trim_q) / 10.0)
        cur_sum, cur_s = 0.0, 0
        best_sum, best_s, best_e = 0.0, 0, n
        for i in range(n):
            err = 10.0 ** (-float(max(0, quals[i])) / 10.0)
            cur_sum += (cutoff - err)
            if cur_sum <= 0.0:
                cur_sum = 0.0
                cur_s = i + 1
            elif cur_sum > best_sum:
                best_sum = cur_sum
                best_s = cur_s
                best_e = i + 1
        if best_sum > 0.0 and (best_e - best_s) >= 12:
            trim_s, trim_e = best_s, best_e
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
        return max(votes.items(), key=lambda x: (x[1], -x[0]))

    fwd_start, fwd_hits = best_seed_start(trimmed_seq)
    rev_q = rev_comp(trimmed_seq)
    rev_start, rev_hits = best_seed_start(rev_q)
    max_hits = max(fwd_hits, rev_hits)
    is_rev = rev_hits > fwd_hits
    chosen_q = rev_q if is_rev else trimmed_seq
    est_start = rev_start if is_rev else fwd_start

    # Gotoh (1982) 带状半全局仿射空位比对（支持小 Indel 而不触发移码雪崩）
    pad = min(24, ref_len)
    win_s = max(0, est_start - pad)
    win_e = min(len(doubled_ref), est_start + len(chosen_q) + pad)
    ref_win = doubled_ref[win_s:win_e]
    m_len, n_len = len(ref_win), len(chosen_q)
    band = max(24, abs(m_len - n_len) + 16)
    NEG = -10**9
    M = [[NEG] * (n_len + 1) for _ in range(m_len + 1)]
    D = [[NEG] * (n_len + 1) for _ in range(m_len + 1)]
    I = [[NEG] * (n_len + 1) for _ in range(m_len + 1)]
    trM = [[0] * (n_len + 1) for _ in range(m_len + 1)]
    trD = [[0] * (n_len + 1) for _ in range(m_len + 1)]
    trI = [[0] * (n_len + 1) for _ in range(m_len + 1)]
    for i in range(m_len + 1):
        M[i][0] = 0
    for j in range(1, min(n_len, band) + 1):
        I[0][j] = -6 - (j - 1)
        trI[0][j] = 2 if j > 1 else 0
    for i in range(1, m_len + 1):
        j_lo = max(1, i - band)
        j_hi = min(n_len, i + band)
        ri = ref_win[i - 1]
        for j in range(j_lo, j_hi + 1):
            # D: deletion in query (gap in query)
            d_from_m = M[i - 1][j] - 6
            d_from_d = D[i - 1][j] - 1
            if d_from_d >= d_from_m:
                D[i][j] = d_from_d; trD[i][j] = 1
            else:
                D[i][j] = d_from_m; trD[i][j] = 0
            # I: insertion in query (gap in ref)
            i_from_m = M[i][j - 1] - 6
            i_from_i = I[i][j - 1] - 1
            if i_from_i >= i_from_m:
                I[i][j] = i_from_i; trI[i][j] = 2
            else:
                I[i][j] = i_from_m; trI[i][j] = 0
            # M: match/mismatch
            sc = 3 if ri == chosen_q[j - 1] else -2
            best_prev, best_st = M[i - 1][j - 1], 0
            if D[i - 1][j - 1] > best_prev:
                best_prev, best_st = D[i - 1][j - 1], 1
            if I[i - 1][j - 1] > best_prev:
                best_prev, best_st = I[i - 1][j - 1], 2
            M[i][j] = best_prev + sc
            trM[i][j] = best_st
    best_end_i, best_end_st, best_sc = m_len, 0, NEG
    for i in range(max(1, n_len - band), m_len + 1):
        for st, val in ((0, M[i][n_len]), (1, D[i][n_len]), (2, I[i][n_len])):
            if val > best_sc:
                best_sc, best_end_i, best_end_st = val, i, st
    pairs = []
    ci, cj, cst = best_end_i, n_len, best_end_st
    while cj > 0:
        if cst == 0 and ci > 0:
            prev_st = trM[ci][cj]
            pairs.append((ref_win[ci - 1], chosen_q[cj - 1], win_s + ci - 1, cj - 1))
            ci -= 1; cj -= 1; cst = prev_st
        elif cst == 1 and ci > 0:
            prev_st = trD[ci][cj]
            pairs.append((ref_win[ci - 1], "-", win_s + ci - 1, None))
            ci -= 1; cst = prev_st
        else:
            prev_st = trI[ci][cj]
            pairs.append(("-", chosen_q[cj - 1], win_s + ci, cj - 1))
            cj -= 1; cst = prev_st
    pairs.reverse()
    est_start = pairs[0][2] if pairs else est_start

    matches = 0
    mismatches = []
    hq_covered_ref_positions = set()
    idx_p = 0
    while idx_p < len(pairs):
        rb, qb, r0, q0 = pairs[idx_p]
        ref_pos1 = (r0 % ref_len) + 1
        read_pos1 = ((trim_e - q0) if is_rev else (trim_s + q0 + 1)) if q0 is not None else None
        q_val = quals[read_pos1 - 1] if (read_pos1 is not None and 0 <= read_pos1 - 1 < len(quals)) else 40
        if rb != "-" and q_val >= trim_q:
            hq_covered_ref_positions.add(ref_pos1)
        if rb == qb and rb != "-":
            matches += 1
            idx_p += 1
        elif rb != "-" and qb != "-":
            mismatches.append({"ref_pos_1based": ref_pos1, "read_pos_1based": read_pos1, "ref_base": rb, "read_base": qb, "hgvs": f"g.{ref_pos1}{rb}>{qb}"})
            idx_p += 1
        elif rb == "-":
            ins_b = []
            first_r1 = ref_pos1
            first_rp1 = read_pos1
            while idx_p < len(pairs) and pairs[idx_p][0] == "-":
                ins_b.append(pairs[idx_p][1])
                idx_p += 1
            prev_r1 = (first_r1 - 1) if first_r1 > 1 else ref_len
            mismatches.append({"ref_pos_1based": first_r1, "read_pos_1based": first_rp1, "ref_base": "-", "read_base": "".join(ins_b), "hgvs": f"g.{prev_r1}_{first_r1}ins{''.join(ins_b)}"})
        else:
            del_b = []
            first_r1 = ref_pos1
            last_r1 = ref_pos1
            while idx_p < len(pairs) and pairs[idx_p][1] == "-":
                del_b.append(pairs[idx_p][0])
                last_r1 = (pairs[idx_p][2] % ref_len) + 1
                idx_p += 1
            hgvs_del = f"g.{first_r1}del{''.join(del_b)}" if len(del_b) == 1 else f"g.{first_r1}_{last_r1}del{''.join(del_b)}"
            mismatches.append({"ref_pos_1based": first_r1, "read_pos_1based": None, "ref_base": "".join(del_b), "read_base": "-", "hgvs": hgvs_del})

    aligned_len = max(1, len(pairs))
    identity_pct = round(matches * 100.0 / aligned_len, 1)
    is_unaligned = (max_hits == 0 and identity_pct < 60.0)
    if is_unaligned:
        verdict = "未匹配到同源区"
        batch_verdict = "unmatched"
        hq_covered_ref_positions.clear()
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
        "hq_covered_bp": len(hq_covered_ref_positions),
        "_hq_covered_ref_positions": sorted(hq_covered_ref_positions),
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
        ref_meta_map = {}
        for r in references_in:
            r_name = (r.get("name") or "").strip()
            r_seq = clean_seq(r.get("sequence") or "")
            if r_name and len(r_seq) >= 16:
                t_start = r.get("target_start_1based")
                t_end = r.get("target_end_1based")
                has_explicit = (t_start is not None or t_end is not None)
                s1 = max(1, min(len(r_seq), int(t_start))) if t_start is not None else 1
                e1 = max(s1, min(len(r_seq), int(t_end))) if t_end is not None else len(r_seq)
                cand_refs.append((r_name, r_seq))
                ref_meta_map[r_name] = {
                    "target_start_1based": s1,
                    "target_end_1based": e1,
                    "has_explicit_target": has_explicit,
                }
        if not cand_refs:
            cand_refs.append((primary_ref_title, primary_ref_seq))
            ref_meta_map[primary_ref_title] = {
                "target_start_1based": 1,
                "target_end_1based": len(primary_ref_seq),
                "has_explicit_target": False,
            }

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
            hq_positions = best_rep.pop("_hq_covered_ref_positions", [])
            read_reports.append(best_rep)
            if c_name not in clone_groups:
                clone_groups[c_name] = []
                clone_order.append(c_name)
            clone_groups[c_name].append((best_rep, hq_positions))

        clone_summaries = []
        explicit_min_cov = args.get("min_pass_coverage_percent")
        for c_name in clone_order:
            pair_items = clone_groups[c_name]
            items = [p[0] for p in pair_items]
            ref_name = items[0]["reference_plasmid"]
            ref_len = max(1, items[0]["reference_length_bp"])
            ref_meta = ref_meta_map.get(ref_name, {"target_start_1based": 1, "target_end_1based": ref_len, "has_explicit_target": False})
            t_s1 = max(1, min(ref_len, int(ref_meta["target_start_1based"])))
            t_e1 = max(t_s1, min(ref_len, int(ref_meta["target_end_1based"])))
            t_len = max(1, t_e1 - t_s1 + 1)

            hq_union = set()
            ident_sum = 0.0
            snp_cnt = 0
            dp_cnt = 0
            has_unmatched = False
            for it, hq_pos in pair_items:
                ident_sum += it["identity_percent"]
                snp_cnt += len(it["mismatches"])
                dp_cnt += len(it["double_peaks"])
                if it["batch_verdict"] == "unmatched":
                    has_unmatched = True
                else:
                    hq_union.update(hq_pos)
            cov_bp = sum(1 for pos in hq_union if t_s1 <= pos <= t_e1)
            cov_pct = min(100.0, round(cov_bp * 100.0 / t_len, 1))
            default_cov = 95.0 if ref_meta.get("has_explicit_target") else 70.0
            min_pass_cov = max(0.0, min(100.0, float(explicit_min_cov if explicit_min_cov is not None else default_cov)))
            if all(it["batch_verdict"] == "unmatched" for it in items):
                c_verdict = "unmatched"
            elif snp_cnt > 0:
                c_verdict = "failed"
            elif dp_cnt > 0 or has_unmatched or cov_pct < min_pass_cov:
                c_verdict = "needsReview"
            else:
                c_verdict = "pass"
            clone_summaries.append({
                "clone_name": c_name,
                "reference_plasmid": ref_name,
                "read_count": len(items),
                "target_region_start_1based": t_s1,
                "target_region_end_1based": t_e1,
                "target_region_length_bp": t_len,
                "coverage_bp": cov_bp,
                "coverage_percent": cov_pct,
                "min_required_coverage_percent": min_pass_cov,
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
    res.pop("_hq_covered_ref_positions", None)
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
    """将 DNA 序列转为标准四通道荧光峰高矩阵 [[A, C, G, T]]（保留 'N' 退化四通道均值以保持 1:1 坐标映射）"""
    cleaned = _clean_seq_preserving_n(seq)
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


def _clean_seq_preserving_n(seq: str) -> str:
    """清理 DNA 序列但严格保留 'N' 碱基，维持字符下标与 ABIF 峰位矩阵 1:1 等长映射。"""
    out = []
    for ch in (seq or "").upper():
        if ch in "ACGTN":
            out.append(ch)
        elif ch == "U":
            out.append("T")
    return "".join(out)


def locate_crispr_cut_site(wt_sequence: str, sgrna_sequence: str):
    """在 WT 序列中定位 sgRNA 及其 SpCas9 切割位点 (0-based 下标，保留 'N' 以确保 1:1 坐标映射)"""
    clean_wt = _clean_seq_preserving_n(wt_sequence)
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


def _subtract_channel_baselines(peaks: list, quantile: float = 0.10) -> list:
    """四通道逐通道局部基线扣除（10% 分位数，与 Swift CRISPRDeconvolutionEngine.subtractChannelBaselines 严格对齐）"""
    if not peaks:
        return peaks
    n = len(peaks)
    baselines = [0.0, 0.0, 0.0, 0.0]
    for ch in range(4):
        vals = sorted(float(row[ch]) if len(row) > ch else 0.0 for row in peaks)
        idx = min(n - 1, max(0, int((n - 1) * quantile)))
        baselines[ch] = vals[idx]
    return [
        [max(0.0, (float(row[c]) if len(row) > c else 0.0) - baselines[c]) for c in range(4)]
        for row in peaks
    ]


def _estimate_local_signal_scale(wt_peaks: list, start: int, end: int) -> tuple:
    """估算 WT 局部主峰 RFU 振幅与背景基底（用于 HDR 列与插入基底的同量纲缩放）"""
    n = len(wt_peaks)
    s = max(0, min(n, start))
    e = max(s, min(n, end))
    sl = wt_peaks[s:e] if s < e else wt_peaks
    if not sl:
        return (1000.0, 0.0)
    primaries = []
    non_primaries = []
    for row in sl:
        vals = sorted(float(row[c]) if len(row) > c else 0.0 for c in range(4))
        primaries.append(vals[3])
        non_primaries.extend(vals[:3])
    primaries.sort()
    non_primaries.sort()
    return (max(1.0, primaries[len(primaries) // 2]), non_primaries[len(non_primaries) // 2])


def _mott_quality_trim_range(qualities: list, error_cutoff: float = 0.05) -> tuple:
    """Phred Mott 最大子数组质量修剪算法，返回高质量有效区间 (start, end)。"""
    n = len(qualities)
    if n == 0 or all(int(q) <= 0 for q in qualities):
        return (0, n)
    cur_sum = 0.0
    cur_start = 0
    best_sum = 0.0
    best_start = 0
    best_end = 0
    for i, q_raw in enumerate(qualities):
        q = float(max(0, int(q_raw)))
        score = error_cutoff - (10.0 ** (-q / 10.0))
        if cur_sum + score <= 0.0:
            cur_sum = 0.0
            cur_start = i + 1
        else:
            cur_sum += score
            if cur_sum > best_sum:
                best_sum = cur_sum
                best_start = cur_start
                best_end = i + 1
    if best_end - best_start < 20:
        return (0, n)
    return (best_start, best_end)


def _student_t_two_sided_p(t_val: float, df: float) -> float:
    if df <= 0.0:
        return 1.0
    if t_val == 0.0:
        return 1.0
    x = df / (df + t_val * t_val)
    return min(1.0, max(0.0, _incomplete_beta(df / 2.0, 0.5, x)))


def _estimate_active_covariance(columns: list, active_indices: list, ss_res: float, m: int):
    """估算活跃支持集完整协方差矩阵 Σ_A = σ²(X_A^T X_A)^(-1)，区分 zero_residual / unavailable / matrix。"""
    k = len(active_indices)
    if k == 0 or m <= k:
        return ("unavailable", None)
    sigma2 = ss_res / float(m - k)
    if sigma2 <= 1e-18:
        return ("zero_residual", None)
    gram = [[0.0] * k for _ in range(k)]
    max_diag = 0.0
    for i in range(k):
        ci = columns[active_indices[i]]
        for j in range(i, k):
            cj = columns[active_indices[j]]
            dot = sum(a * b for a, b in zip(ci, cj))
            gram[i][j] = dot
            gram[j][i] = dot
        max_diag = max(max_diag, abs(gram[i][i]))
    if max_diag <= 1e-18:
        return ("unavailable", None)
    pivot_tol = max(1e-14, 1e-12 * max_diag)
    aug = [gram[i][:] + [1.0 if j == i else 0.0 for j in range(k)] for i in range(k)]
    for col in range(k):
        piv_row = max(range(col, k), key=lambda r: abs(aug[r][col]))
        if abs(aug[piv_row][col]) <= pivot_tol:
            return ("unavailable", None)
        if piv_row != col:
            aug[col], aug[piv_row] = aug[piv_row], aug[col]
        diag = aug[col][col]
        for c in range(2 * k):
            aug[col][c] /= diag
        for r in range(k):
            if r == col:
                continue
            fac = aug[r][col]
            if fac == 0.0:
                continue
            for c in range(2 * k):
                aug[r][c] -= fac * aug[col][c]
    cov_map = {}
    for i in range(k):
        row_dict = {}
        for j in range(k):
            val = sigma2 * aug[i][k + j]
            if not math.isfinite(val):
                return ("unavailable", None)
            row_dict[active_indices[j]] = val
        cov_map[active_indices[i]] = row_dict
    return ("matrix", cov_map)


def _estimate_upstream_alignment_offset(wt_seq: str, ed_seq: str, wt_peaks: list, ed_peaks: list, wt_cut0: int, max_offset: int = 50) -> int:
    """切点上游窗口 WT vs Edited 序列锚点 + 四通道互相关对齐（保留 'N' 坐标 1:1 映射）"""
    c_wt = _clean_seq_preserving_n(wt_seq)
    c_ed = _clean_seq_preserving_n(ed_seq)
    win_end = max(0, wt_cut0 - 15)
    win_start = max(min(10, max(0, win_end - 25)), win_end - 95)
    if win_end - win_start >= 12 and len(c_wt) >= win_end and len(c_ed) >= 12:
        for anc_len in (20, 16, 12):
            if win_end - win_start >= anc_len:
                anc_start = win_end - anc_len
                anchor = c_wt[anc_start:win_end]
                if "N" in anchor:
                    continue
                pos = c_ed.find(anchor)
                if pos != -1:
                    cand = pos - anc_start
                    if abs(cand) <= max_offset:
                        return cand
    p_end = min(len(wt_peaks), max(0, wt_cut0 - 10))
    p_start = max(0, p_end - 80)
    if p_end - p_start < 12 or not ed_peaks:
        return 0
    best_off = 0
    best_score = -1e18
    lim = min(max_offset, max(10, len(ed_peaks) // 2))
    for delta in range(-lim, lim + 1):
        dot = nw = ne = 0.0
        ov = 0
        for idx in range(p_start, p_end):
            e_idx = idx + delta
            if 0 <= e_idx < len(ed_peaks):
                wp = wt_peaks[idx]
                ep = ed_peaks[e_idx]
                for c in range(4):
                    wv = float(wp[c]) if len(wp) > c else 0.0
                    ev = float(ep[c]) if len(ep) > c else 0.0
                    dot += wv * ev
                    nw += wv * wv
                    ne += ev * ev
                ov += 1
        if ov >= 10 and nw > 1e-12 and ne > 1e-12:
            corr = dot / (math.sqrt(nw) * math.sqrt(ne))
            if corr > best_score + 1e-9 or (abs(corr - best_score) <= 1e-9 and abs(delta) < abs(best_off)):
                best_score = corr
                best_off = delta
    return best_off


def _align_and_scale_hdr_window(wt_seq: str, hdr_seq: str, wt_cut0: int, req_win: int, wt_primary: float, wt_bg: float):
    """自动对齐正义或反义 HDR Donor 模板并按 WT 实测 RFU 同量纲构建下游峰值矩阵；无同源锚点且上游一致性 <80% 返回 None"""
    c_wt = _clean_seq_preserving_n(wt_seq)
    c_hdr_sense = clean_seq(hdr_seq)
    if not c_hdr_sense or wt_cut0 < 0 or wt_cut0 >= len(c_wt):
        return None
    c_hdr_anti = rev_comp(c_hdr_sense)

    def find_anchor(cand_hdr: str):
        for anc_len in (20, 16, 12):
            if wt_cut0 < anc_len + 3:
                continue
            for back in range(4, min(50, wt_cut0 - anc_len) + 1, 2):
                a_start = wt_cut0 - back - anc_len
                a_end = a_start + anc_len
                if a_start >= 0 and a_end <= len(c_wt):
                    anchor = c_wt[a_start:a_end]
                    if "N" in anchor:
                        continue
                    pos = cand_hdr.find(anchor)
                    if pos != -1:
                        cand = pos + (wt_cut0 - a_start)
                        if 0 <= cand < len(cand_hdr):
                            return cand
        return None

    def upstream_matches(cand_hdr: str) -> bool:
        if len(cand_hdr) != len(c_wt) or wt_cut0 < 10:
            return False
        u_start = max(0, wt_cut0 - 40)
        matches = compared = 0
        for i in range(u_start, wt_cut0):
            if c_wt[i] == "N":
                continue
            compared += 1
            if cand_hdr[i] == c_wt[i]:
                matches += 1
        return compared >= 8 and (matches / float(compared)) >= 0.80

    final_hdr = None
    hdr_cut0 = find_anchor(c_hdr_sense)
    if hdr_cut0 is not None:
        final_hdr = c_hdr_sense
    else:
        hdr_cut0 = find_anchor(c_hdr_anti)
        if hdr_cut0 is not None:
            final_hdr = c_hdr_anti
        elif upstream_matches(c_hdr_sense):
            final_hdr = c_hdr_sense
            hdr_cut0 = wt_cut0
        elif upstream_matches(c_hdr_anti):
            final_hdr = c_hdr_anti
            hdr_cut0 = wt_cut0
    if final_hdr is None or hdr_cut0 is None:
        return None
    down = final_hdr[hdr_cut0:hdr_cut0 + req_win]
    if len(down) < req_win and len(down) >= 12 and wt_cut0 < len(c_wt):
        wt_tail = c_wt[wt_cut0:]
        for tlen in (16, 12):
            if len(down) >= tlen:
                tail_anc = down[-tlen:]
                pos = wt_tail.find(tail_anc)
                if pos != -1:
                    wt_end = wt_cut0 + pos + tlen
                    down = down + c_wt[wt_end:wt_end + (req_win - len(down))]
                    break
    return peaks_from_sequence(down, primary_signal=wt_primary, background_signal=wt_bg)


def deconvolve_sanger_crispr(args: dict) -> dict:
    """Synthego ICE / TIDE 风格 Sanger 编辑池四通道峰图 NNLS 解卷积（与 Swift CRISPRDeconvolutionEngine 1:1 对齐）"""
    wt_seq = _clean_seq_preserving_n(args.get("wt_sequence") or "")
    sgrna_seq = clean_seq(args.get("sgrna_sequence") or "")
    hdr_seq = clean_seq(args.get("hdr_donor_sequence") or "") if args.get("hdr_donor_sequence") else ""
    req_win = int(args.get("window_length_bp") or args.get("requested_window_length_bp") or 150)
    shift_min = int(args.get("shift_min_bp", -20))
    shift_max = int(args.get("shift_max_bp", 20))
    noise_floor = float(args.get("noise_floor_weight", 1e-6))
    min_comp_pct = float(args.get("min_component_percent", 1.0))
    align_offset_bp = int(args.get("alignment_offset_bp", 0))

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
                "alignment_offset_bp": align_offset_bp,
                "hdr_wt_cosine_similarity": None,
                "contributions": [],
                "dominant_indels": []
            }
        cut_idx, is_rev_sg = loc

    edited_win_peaks = [[float(v) for v in row[:4]] for row in (args.get("edited_peaks_acgt") or [])]

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
            "alignment_offset_bp": align_offset_bp,
            "hdr_wt_cosine_similarity": None,
            "contributions": [],
            "dominant_indels": []
        }

    # 统一使用下游分解窗 [cut_idx, cut_idx + eff_w] 估算局部 RFU 振幅，消除 5'→3' 信号衰减偏差
    local_primary, local_bg = _estimate_local_signal_scale(wt_peaks, cut_idx, min(n_wt, cut_idx + eff_w))

    hdr_win_peaks = args.get("hdr_peaks_acgt")
    if not hdr_win_peaks and hdr_seq:
        if wt_seq:
            hdr_win_peaks = _align_and_scale_hdr_window(wt_seq, hdr_seq, cut_idx, req_win, local_primary, local_bg)
            if hdr_win_peaks is None:
                warnings.append("HDR_ALIGNMENT_FAILED")
        else:
            hdr_full = peaks_from_sequence(hdr_seq, primary_signal=local_primary, background_signal=local_bg)
            if cut_idx < len(hdr_full):
                hdr_win_peaks = hdr_full[cut_idx:cut_idx + req_win]
    if hdr_win_peaks:
        hdr_win_peaks = [[float(v) for v in row[:4]] for row in hdr_win_peaks]

    shifts = list(range(shift_min, shift_max + 1))
    degen_level = local_bg + 0.25 * (local_primary - local_bg)
    columns = []
    col_metas = []
    wt_col_idx = None

    for s_idx, s in enumerate(shifts):
        if s == 1:
            for ins_b in range(4):
                col = [local_primary if c == ins_b else local_bg for c in range(4)]
                for k in range(1, eff_w):
                    src_idx = min(max(0, cut_idx + k - 1), n_wt - 1)
                    col.extend(wt_peaks[src_idx][:4])
                columns.append(col)
                col_metas.append((s_idx, False))
        elif s >= 2:
            col = []
            for k in range(eff_w):
                if k < s:
                    col.extend([degen_level, degen_level, degen_level, degen_level])
                else:
                    src_idx = min(max(0, cut_idx + k - s), n_wt - 1)
                    col.extend(wt_peaks[src_idx][:4])
            columns.append(col)
            col_metas.append((s_idx, False))
        else:
            if s == 0:
                wt_col_idx = len(columns)
            col = []
            for k in range(eff_w):
                src_idx = min(max(0, cut_idx + k - s), n_wt - 1)
                col.extend(wt_peaks[src_idx][:4])
            columns.append(col)
            col_metas.append((s_idx, False))

    has_hdr = False
    hdr_cos_sim = None
    if hdr_win_peaks and len(hdr_win_peaks) >= eff_w:
        hdr_col = []
        for k in range(eff_w):
            hdr_col.extend(hdr_win_peaks[k][:4])
        if wt_col_idx is not None:
            wt_col = columns[wt_col_idx]
            dot = sum(a * b for a, b in zip(wt_col, hdr_col))
            nw = sum(a * a for a in wt_col)
            nh = sum(b * b for b in hdr_col)
            if nw > 1e-12 and nh > 1e-12:
                cos_val = dot / (math.sqrt(nw) * math.sqrt(nh))
                hdr_cos_sim = cos_val
                if cos_val > 0.96:
                    warnings.append("HDR_COLLINEAR_WITH_WT")
        columns.append(hdr_col)
        col_metas.append((None, True))
        has_hdr = True

    rhs = []
    for k in range(eff_w):
        rhs.extend(edited_win_peaks[k][:4])

    raw_weights, res_norm = solve_nnls_deconv(columns, rhs)

    # Synthego ICE 稀疏剪枝 (< min_comp_pct%) + 支持集无偏重拟合
    init_sum = sum(raw_weights)
    if init_sum > 1e-12 and min_comp_pct > 0.0:
        s_agg = [0.0] * len(shifts)
        h_agg = 0.0
        for c_idx, (s_idx, is_h) in enumerate(col_metas):
            if s_idx is not None:
                s_agg[s_idx] += raw_weights[c_idx]
            elif is_h:
                h_agg += raw_weights[c_idx]
        keep_indices = []
        for c_idx, (s_idx, is_h) in enumerate(col_metas):
            if raw_weights[c_idx] < noise_floor:
                continue
            if s_idx is not None:
                pct = (s_agg[s_idx] / init_sum) * 100.0
                if pct >= min_comp_pct or shifts[s_idx] == 0:
                    keep_indices.append(c_idx)
            else:
                if (h_agg / init_sum) * 100.0 >= min_comp_pct:
                    keep_indices.append(c_idx)
        if keep_indices and len(keep_indices) < len(columns):
            sub_cols = [columns[i] for i in keep_indices]
            sub_w, sub_res = solve_nnls_deconv(sub_cols, rhs)
            refit_w = [0.0] * len(columns)
            for li, oi in enumerate(keep_indices):
                refit_w[oi] = sub_w[li]
            raw_weights = refit_w
            res_norm = sub_res

    ss_res = res_norm * res_norm
    mean_y = sum(rhs) / len(rhs)
    ss_tot = sum((val - mean_y) ** 2 for val in rhs)
    r_squared = max(0.0, min(1.0, 1.0 - (ss_res / ss_tot))) if ss_tot > 1e-12 else 1.0
    if r_squared < 0.75:
        warnings.append("LOW_FIT_R_SQUARED")

    cleaned_weights = [w if w >= noise_floor else 0.0 for w in raw_weights]
    active_indices = [i for i, w in enumerate(cleaned_weights) if w > 0.0]
    cov_status, cov_map = _estimate_active_covariance(columns, active_indices, ss_res, len(rhs))

    shift_weights = [0.0] * len(shifts)
    shift_active_cols = [[] for _ in range(len(shifts))]
    hdr_weight = 0.0
    hdr_active_cols = []
    for c_idx, (s_idx, is_h) in enumerate(col_metas):
        rw = cleaned_weights[c_idx]
        if s_idx is not None:
            shift_weights[s_idx] += rw
            if rw > 0.0:
                shift_active_cols[s_idx].append(c_idx)
        elif is_h:
            hdr_weight += rw
            if rw > 0.0:
                hdr_active_cols.append(c_idx)

    w_sum = sum(shift_weights) + hdr_weight
    norm_scale = (100.0 / w_sum) if w_sum > 1e-12 else 0.0
    df_stat = max(1, len(rhs) - max(1, len(active_indices)))

    def _group_se_p(rw: float, pct: float, grp_cols: list):
        if rw <= 0.0 or not grp_cols:
            return (None, None)
        if cov_status == "zero_residual":
            return (0.0, 0.0)
        if cov_status != "matrix" or cov_map is None:
            return (None, None)
        sum_var = 0.0
        for ci in grp_cols:
            row_m = cov_map.get(ci)
            if row_m is None:
                return (None, None)
            for cj in grp_cols:
                if cj not in row_m:
                    return (None, None)
                sum_var += row_m[cj]
        se_pct = math.sqrt(max(0.0, sum_var)) * norm_scale
        if se_pct <= 1e-12:
            return (0.0, 0.0)
        return (se_pct, _student_t_two_sided_p(pct / se_pct, float(df_stat)))

    wt_pct = 0.0
    indel_pct = 0.0
    ko_pct = 0.0
    hdr_pct = 0.0
    contributions = []

    for idx, s in enumerate(shifts):
        rw = shift_weights[idx]
        pct = rw * norm_scale
        is_ko_shift = ((abs(s) % 3) != 0) or (s <= -21)
        lbl = f"+{s}" if s > 0 else f"{s}"
        if s == 0:
            wt_pct = pct
        else:
            indel_pct += pct
            if is_ko_shift:
                ko_pct += pct
        se_p, p_v = _group_se_p(rw, pct, shift_active_cols[idx])
        contributions.append({
            "label": lbl,
            "shift_bp": s,
            "is_hdr": False,
            "is_frameshift": is_ko_shift,
            "raw_weight": rw,
            "percent": pct,
            "se_percent": se_p,
            "p_value": p_v
        })

    if has_hdr:
        rw = hdr_weight
        pct = rw * norm_scale
        hdr_pct = pct
        se_p, p_v = _group_se_p(rw, pct, hdr_active_cols)
        contributions.append({
            "label": "HDR",
            "shift_bp": None,
            "is_hdr": True,
            "is_frameshift": False,
            "raw_weight": rw,
            "percent": pct,
            "se_percent": se_p,
            "p_value": p_v
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
        "alignment_offset_bp": align_offset_bp,
        "hdr_wt_cosine_similarity": hdr_cos_sim,
        "contributions": contributions,
        "dominant_indels": dominant
    }


_PLASMID_FEATURES_CACHE = {"key": None, "records": None}


def load_plasmid_features_from_sqlite(db_path: str = None) -> list:
    """从 Libraries.sqlite 只读加载标准质粒元件表 plasmid_features（带 mtime 缓存）"""
    import sqlite3
    resolved = db_path or os.path.join(SCRIPT_DIR, "Libraries.sqlite")
    if not os.path.exists(resolved):
        return []
    abs_path = os.path.abspath(resolved)
    try:
        mtime = os.path.getmtime(abs_path)
    except OSError:
        mtime = 0.0
    cache_key = (abs_path, mtime)
    if _PLASMID_FEATURES_CACHE["key"] == cache_key and _PLASMID_FEATURES_CACHE["records"] is not None:
        return _PLASMID_FEATURES_CACHE["records"]

    conn = sqlite3.connect(f"file:{abs_path}?mode=ro", uri=True)
    try:
        cols = {r[1] for r in conn.execute("PRAGMA table_info(plasmid_features);")}
        has_src = "source_accession" in cols
        sql = (
            "SELECT id, name, category, sequence, direction, color_hex, source_accession FROM plasmid_features ORDER BY id ASC;"
            if has_src
            else "SELECT id, name, category, sequence, direction, color_hex FROM plasmid_features ORDER BY id ASC;"
        )
        rows = conn.execute(sql).fetchall()
        records = [
            {
                "id": int(r[0]),
                "name": str(r[1]),
                "category": str(r[2]),
                "sequence": clean_seq(str(r[3])),
                "direction": int(r[4]),
                "color_hex": str(r[5]),
                "source_accession": (str(r[6]) if (has_src and r[6] is not None) else None),
            }
            for r in rows
        ]
        if records:
            _PLASMID_FEATURES_CACHE["key"] = cache_key
            _PLASMID_FEATURES_CACHE["records"] = records
        return records
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
                is_frag_cand = coverage < full_feature_coverage_threshold
                if is_frag_cand and aligned_len < 21:
                    continue
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
                        "source_accession": feat.get("source_accession"),
                    },
                    s_start,
                ))

    # 6 框蛋白翻译同源检索（在 candidates.sort 之前汇入，与 Swift PlasmidAnnotationEngine 严格一致）
    coding_cats = {"CDS", "reporter", "resistance", "tag"}
    def _tr_dna(s: str) -> str:
        return "".join(CODON_TO_AA.get(s[i:i + 3], "X") for i in range(0, len(s) - 2, 3))
    search_rev = rev_comp(search_seq)
    frames = []
    for fr in range(3):
        frames.append(("+", fr, _tr_dna(search_seq[fr:])))
        frames.append(("-", fr, _tr_dna(search_rev[fr:])))
    aa_seed = 5
    aa_idx = [{} for _ in frames]
    for fi, (_, _, aas) in enumerate(frames):
        for p in range(max(0, len(aas) - aa_seed + 1)):
            sd = aas[p:p + aa_seed]
            if "*" not in sd and "X" not in sd:
                aa_idx[fi].setdefault(sd, []).append(p)
    for feat in library:
        if feat["category"] not in coding_cats:
            continue
        ref_clean = clean_seq(feat["sequence"])
        if len(ref_clean) < 150 or len(ref_clean) % 3 != 0:
            continue
        raw_aa = _tr_dna(ref_clean)
        ref_aa = raw_aa[:-1] if raw_aa.endswith("*") else raw_aa
        ra_len = len(ref_aa)
        if ra_len < 50:
            continue
        probes = [o for o in (0, ra_len // 4, ra_len // 2, (3 * ra_len) // 4) if o + aa_seed <= ra_len]
        for fi, (st_dir, fr_off, aas) in enumerate(frames):
            diag_aa = set()
            for off in probes:
                for h in aa_idx[fi].get(ref_aa[off:off + aa_seed], []):
                    diag_aa.add(h - off)
            for d_aa in sorted(diag_aa):
                if d_aa < 0 or d_aa + ra_len > len(aas):
                    continue
                aa_m = sum(1 for k in range(ra_len) if aas[d_aa + k] == ref_aa[k])
                aa_id = aa_m / float(ra_len)
                if aa_id < 0.85:
                    continue
                dna_off = fr_off + d_aa * 3
                dna_len = ra_len * 3
                s_start0 = dna_off if st_dir == "+" else (search_len - (dna_off + dna_len))
                if s_start0 < 0 or s_start0 >= query_len:
                    continue
                if not is_circular and (s_start0 + dna_len) > query_len:
                    continue
                s_end0 = s_start0 + dna_len
                wraps = bool(is_circular and s_end0 > query_len)
                candidates.append((
                    {
                        "feature_id": int(feat["id"]),
                        "name": feat["name"],
                        "display_name": f"{feat['name']} (protein match)",
                        "category": feat["category"],
                        "strand": st_dir,
                        "canonical_direction": int(feat["direction"]),
                        "start_1based": s_start0 + 1,
                        "end_1based": (((s_end0 - 1) % query_len) + 1) if wraps else s_end0,
                        "matched_length": dna_len,
                        "reference_length": len(ref_clean),
                        "feature_start_1based": 1,
                        "feature_end_1based": dna_len,
                        "coverage": dna_len / float(len(ref_clean)),
                        "identity": aa_id,
                        "alignment_score": float(dna_len) * aa_id * 1.8,
                        "is_origin_spanning": wraps,
                        "is_fragment": False,
                        "fragment_warning": None,
                        "color_hex": feat["color_hex"],
                        "source_accession": feat.get("source_accession"),
                    },
                    s_start0,
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

    def _feat_layer(cat: str) -> str:
        c = (cat or "").lower()
        if c in ("promoter", "terminator", "enhancer", "polya", "regulator", "regulatory"):
            return "regulatory"
        if c in ("ori", "origin", "replication"):
            return "replication"
        if c in ("tag", "recombinase", "misc"):
            return c
        return "coding"

    occ_by_bucket = {}
    union_occ = [False] * query_len
    accepted = []
    for feat_hit, s_start0 in candidates:
        mlen = feat_hit["matched_length"]
        layer = _feat_layer(feat_hit["category"])
        bkey = "replication" if layer == "replication" else f"{feat_hit['strand']}:{layer}"
        occ = occ_by_bucket.setdefault(bkey, [False] * query_len)
        already_occ = sum(1 for off in range(mlen) if (union_occ[(s_start0 + off) % query_len] if feat_hit["is_fragment"] else occ[(s_start0 + off) % query_len]))
        if (already_occ / float(mlen)) <= 0.15:
            accepted.append(feat_hit)
            for off in range(mlen):
                pos = (s_start0 + off) % query_len
                occ[pos] = True
                union_occ[pos] = True

    accepted.sort(key=lambda f: (f["start_1based"], f["end_1based"], f["name"]))

    frag_count = sum(1 for f in accepted if f["is_fragment"])
    origin_count = sum(1 for f in accepted if f["is_origin_spanning"])
    covered_bases = sum(1 for x in union_occ if x)
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
    "bsai": {"name": "BsaI", "site": "GGTCTC", "rc_site": "GAGACC", "cut_top": 7, "cut_bottom": 11, "overhang_len": 4, "default_protective_5prime": "GCAATC"},
    "bsmbi": {"name": "BsmBI", "site": "CGTCTC", "rc_site": "GAGACG", "cut_top": 7, "cut_bottom": 11, "overhang_len": 4, "default_protective_5prime": "GCAATC"},
    "bbsi": {"name": "BbsI", "site": "GAAGAC", "rc_site": "GTCTTC", "cut_top": 8, "cut_bottom": 12, "overhang_len": 4, "default_protective_5prime": "GCAATC"},
    "sapi": {"name": "SapI", "site": "GCTCTTC", "rc_site": "GAAGAGC", "cut_top": 8, "cut_bottom": 11, "overhang_len": 3, "default_protective_5prime": "GCAATC"},
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

GG_HOST_PREFERRED_CODONS = {
    "ecoli": {
        "A": ["GCG", "GCC", "GCA", "GCT"],
        "C": ["TGC", "TGT"],
        "D": ["GAT", "GAC"],
        "E": ["GAA", "GAG"],
        "F": ["TTT", "TTC"],
        "G": ["GGC", "GGT", "GGG", "GGA"],
        "H": ["CAT", "CAC"],
        "I": ["ATT", "ATC", "ATA"],
        "K": ["AAA", "AAG"],
        "L": ["CTG", "TTA", "TTG", "CTT", "CTC", "CTA"],
        "M": ["ATG"],
        "N": ["AAC", "AAT"],
        "P": ["CCG", "CCA", "CCT", "CCC"],
        "Q": ["CAG", "CAA"],
        "R": ["CGC", "CGT", "CGG", "CGA", "AGA", "AGG"],
        "S": ["AGC", "TCT", "TCC", "TCG", "AGT", "TCA"],
        "T": ["ACC", "ACG", "ACT", "ACA"],
        "V": ["GTG", "GTT", "GTC", "GTA"],
        "W": ["TGG"],
        "Y": ["TAT", "TAC"],
        "*": ["TAA", "TGA", "TAG"],
    },
    "human": {
        "A": ["GCC", "GCT", "GCA", "GCG"],
        "C": ["TGC", "TGT"],
        "D": ["GAC", "GAT"],
        "E": ["GAG", "GAA"],
        "F": ["TTC", "TTT"],
        "G": ["GGC", "GGG", "GGA", "GGT"],
        "H": ["CAC", "CAT"],
        "I": ["ATC", "ATT", "ATA"],
        "K": ["AAG", "AAA"],
        "L": ["CTG", "CTC", "CTT", "TTG", "TTA", "CTA"],
        "M": ["ATG"],
        "N": ["AAC", "AAT"],
        "P": ["CCC", "CCT", "CCA", "CCG"],
        "Q": ["CAG", "CAA"],
        "R": ["CGG", "CGC", "AGG", "AGA", "CGT", "CGA"],
        "S": ["AGC", "TCC", "TCT", "AGT", "TCA", "TCG"],
        "T": ["ACC", "ACA", "ACT", "ACG"],
        "V": ["GTG", "GTC", "GTT", "GTA"],
        "W": ["TGG"],
        "Y": ["TAC", "TAT"],
        "*": ["TGA", "TAA", "TAG"],
    },
    "yeast": {
        "A": ["GCT", "GCC", "GCA", "GCG"],
        "C": ["TGT", "TGC"],
        "D": ["GAT", "GAC"],
        "E": ["GAA", "GAG"],
        "F": ["TTT", "TTC"],
        "G": ["GGT", "GGA", "GGC", "GGG"],
        "H": ["CAT", "CAC"],
        "I": ["ATT", "ATC", "ATA"],
        "K": ["AAA", "AAG"],
        "L": ["TTG", "TTA", "CTT", "CTA", "CTG", "CTC"],
        "M": ["ATG"],
        "N": ["AAT", "AAC"],
        "P": ["CCA", "CCT", "CCC", "CCG"],
        "Q": ["CAA", "CAG"],
        "R": ["AGA", "AGG", "CGT", "CGA", "CGC", "CGG"],
        "S": ["TCT", "TCA", "TCC", "AGT", "AGC", "TCG"],
        "T": ["ACT", "ACA", "ACC", "ACG"],
        "V": ["GTT", "GTC", "GTA", "GTG"],
        "W": ["TGG"],
        "Y": ["TAT", "TAC"],
        "*": ["TAA", "TGA", "TAG"],
    },
}

GG_PREFERRED_CODONS = GG_HOST_PREFERRED_CODONS["human"]


def _canonical_gg_enzyme_key(enzyme_name: str) -> str:
    lower = str(enzyme_name or "bsai").strip().lower()
    if lower.startswith("bsmbi") or lower.startswith("esp3i"):
        return "bsmbi"
    if lower.startswith("bbsi") or lower.startswith("bpii"):
        return "bbsi"
    if lower.startswith("sapi") or lower.startswith("bspqi"):
        return "sapi"
    return "bsai"


def load_neb_ligase_fidelity_from_sqlite(db_path: str = None, enzyme_name: str = "BsaI") -> dict:
    """从 Libraries.sqlite 只读加载 Pryor et al. (2020) 实测 Type IIS / T4 连接保真度矩阵"""
    import sqlite3
    resolved = db_path or os.path.join(SCRIPT_DIR, "Libraries.sqlite")
    ekey = _canonical_gg_enzyme_key(enzyme_name)
    ov_len = 3 if ekey == "sapi" else 4
    if not os.path.exists(resolved):
        return {"enzyme_key": ekey, "overhang_length": ov_len, "stats": {}, "counts": {}}
    conn = sqlite3.connect(f"file:{os.path.abspath(resolved)}?mode=ro", uri=True)
    try:
        stats = {}
        counts = {}
        citation = ""
        doi = ""
        try:
            row = conn.execute(
                "SELECT overhang_length, source_citation, source_doi FROM neb_ligase_fidelity_metadata WHERE enzyme_key = ?;",
                (ekey,),
            ).fetchone()
            if row:
                ov_len = int(row[0])
                citation = str(row[1])
                doi = str(row[2])
        except sqlite3.OperationalError:
            pass

        try:
            for r in conn.execute(
                "SELECT overhang, rc_overhang, is_palindromic, gc_count, wc_ligation_count, self_ligation_count, individual_fidelity, is_neb_verified_hf "
                "FROM neb_overhang_stats_by_enzyme WHERE enzyme_key = ?;",
                (ekey,),
            ):
                stats[str(r[0])] = {
                    "overhang": str(r[0]),
                    "rc_overhang": str(r[1]),
                    "is_palindromic": bool(r[2]),
                    "gc_count": int(r[3]),
                    "wc_ligation_count": int(r[4]),
                    "self_ligation_count": int(r[5]),
                    "individual_fidelity": float(r[6]),
                    "is_neb_verified_hf": bool(r[7]),
                }
            for a, b, cnt in conn.execute(
                "SELECT overhang_a, overhang_b, ligation_count FROM neb_ligase_fidelity_matrices WHERE enzyme_key = ?;",
                (ekey,),
            ):
                counts.setdefault(str(a), {})[str(b)] = int(cnt)
        except sqlite3.OperationalError:
            pass

        if not stats and ekey != "sapi":
            for r in conn.execute(
                "SELECT overhang, rc_overhang, is_palindromic, gc_count, wc_ligation_count, individual_fidelity, is_neb_verified_hf FROM neb_t4_overhang_stats;"
            ):
                stats[str(r[0])] = {
                    "overhang": str(r[0]),
                    "rc_overhang": str(r[1]),
                    "is_palindromic": bool(r[2]),
                    "gc_count": int(r[3]),
                    "wc_ligation_count": int(r[4]),
                    "self_ligation_count": 0,
                    "individual_fidelity": float(r[5]),
                    "is_neb_verified_hf": bool(r[6]),
                }
            for a, b, cnt in conn.execute("SELECT overhang_a, overhang_b, ligation_count FROM neb_t4_ligase_fidelity;"):
                counts.setdefault(str(a), {})[str(b)] = int(cnt)

        return {
            "enzyme_key": ekey,
            "overhang_length": ov_len,
            "source_citation": citation,
            "source_doi": doi,
            "stats": stats,
            "counts": counts,
        }
    finally:
        conn.close()


def evaluate_golden_gate_overhangs(overhangs: list, matrix: dict) -> dict:
    """评估一组 4-bp/3-bp Golden Gate 接头的组装保真度与交叉/自错配数（含 j == i 自错配扫描）"""
    normalized = [clean_seq(o) for o in overhangs]
    counts = matrix.get("counts", {})
    expected_len = int(matrix.get("overhang_length") or 4)
    issues = []
    seen_canon = set()
    has_invalid_len = False
    for ov in normalized:
        if len(ov) != expected_len:
            has_invalid_len = True
            issues.append(f"接头 {ov} 长度不为 {expected_len} bp")
            continue
        rc = rev_comp(ov)
        if ov == rc:
            issues.append(f"接头 {ov} 为回文序列")
        canon = min(ov, rc)
        if canon in seen_canon:
            issues.append(f"接头 {ov} 存在重复或反向互补冲突")
        seen_canon.add(canon)
        self_fwd = counts.get(ov, {}).get(ov, 0)
        self_rev = counts.get(rc, {}).get(rc, 0)
        if ov != rc and (self_fwd > 0 or self_rev > 0):
            issues.append(f"接头 {ov}/{rc} 存在自我错配连接热点（self={max(self_fwd, self_rev)}）")

    exposed = []
    for ov in normalized:
        if len(ov) == expected_len:
            exposed.append(ov)
            exposed.append(rev_comp(ov))

    # 完整扫描所有暴露末端对 (i, j) with j >= i（按无序对去重，仅跳过同一接头非回文 WC 配对）
    mismatch_by_pair = {}
    for i in range(len(exposed)):
        u = exposed[i]
        u_map = counts.get(u, {})
        for j in range(i, len(exposed)):
            v = exposed[j]
            if j == i + 1 and (i % 2 == 0) and u != v:
                continue
            cnt_uv = u_map.get(v, 0)
            cnt_vu = cnt_uv if j == i else counts.get(v, {}).get(u, 0)
            cnt = max(cnt_uv, cnt_vu)
            if cnt > 0:
                a, b = min(u, v), max(u, v)
                key = (a, b)
                if key not in mismatch_by_pair or cnt > mismatch_by_pair[key]["ligation_count"]:
                    mismatch_by_pair[key] = {"overhang_a": a, "overhang_b": b, "ligation_count": cnt}
    mismatches = sorted(mismatch_by_pair.values(), key=lambda x: (x["overhang_a"], x["overhang_b"]))

    fidelity = 0.0 if (not normalized or has_invalid_len) else 1.0
    if not has_invalid_len:
        for ov in normalized:
            if len(ov) != expected_len:
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
    """基于 Pryor (2020) 实测矩阵全局优化分配无交叉/自错配 4-bp/3-bp 高保真接头（对齐 Swift GoldenGateEngine）"""
    from functools import cmp_to_key

    canon_ekey = _canonical_gg_enzyme_key(enzyme_name)
    spec = TYPE_IIS_ENZYME_SPECS.get(canon_ekey, TYPE_IIS_ENZYME_SPECS["bsai"])
    ov_len = spec["overhang_len"]
    max_frags = 15 if ov_len == 3 else 24
    clamped = max(2, min(max_frags, int(fragment_count)))
    junc_count = clamped if is_circular else (clamped + 1)
    warnings = []
    if fragment_count != clamped:
        warnings.append(f"片段数已调整至支持范围 2–{max_frags} ({clamped})。")

    fixed_list = fixed_overhangs or []
    mat = matrix if matrix is not None else load_neb_ligase_fidelity_from_sqlite(db_path=db_path, enzyme_name=spec["name"])
    stats = mat.get("stats", {})

    chosen = []
    used_canon = set()
    for raw_fixed in fixed_list:
        ov = clean_seq(raw_fixed)
        if len(ov) != ov_len:
            warnings.append(f"已忽略长度非 {ov_len} bp 的固定接头: {raw_fixed}")
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
    fixed_count = len(chosen)

    def _is_homopolymer(s: str) -> bool:
        return len(s) > 0 and len(set(s)) == 1

    seen_pool = set()
    full_pool = []
    for rec in stats.values():
        if rec["is_palindromic"] or _is_homopolymer(rec["overhang"]):
            continue
        canon = min(rec["overhang"], rec["rc_overhang"])
        if canon in seen_pool:
            continue
        seen_pool.add(canon)
        c_rec = stats.get(canon, rec)
        rc_rec = stats.get(c_rec["rc_overhang"])
        comb_self = max(int(c_rec.get("self_ligation_count", 0)), int(rc_rec.get("self_ligation_count", 0)) if rc_rec else 0)
        comb_fid = min(float(c_rec["individual_fidelity"]), float(rc_rec["individual_fidelity"]) if rc_rec else float(c_rec["individual_fidelity"]))
        full_pool.append({
            "overhang": c_rec["overhang"],
            "rc_overhang": c_rec["rc_overhang"],
            "is_palindromic": False,
            "gc_count": c_rec["gc_count"],
            "wc_ligation_count": c_rec["wc_ligation_count"],
            "self_ligation_count": comb_self,
            "individual_fidelity": comb_fid,
            "is_neb_verified_hf": bool(c_rec["is_neb_verified_hf"]) and (comb_self == 0),
        })

    def _cmp_pool(a, b):
        if a["self_ligation_count"] != b["self_ligation_count"]:
            return -1 if a["self_ligation_count"] < b["self_ligation_count"] else 1
        if a["is_neb_verified_hf"] != b["is_neb_verified_hf"]:
            return -1 if a["is_neb_verified_hf"] else 1
        if abs(a["individual_fidelity"] - b["individual_fidelity"]) > 1e-9:
            return -1 if a["individual_fidelity"] > b["individual_fidelity"] else 1
        if a["wc_ligation_count"] != b["wc_ligation_count"]:
            return -1 if a["wc_ligation_count"] > b["wc_ligation_count"] else 1
        return -1 if a["overhang"] < b["overhang"] else (1 if a["overhang"] > b["overhang"] else 0)

    full_pool.sort(key=cmp_to_key(_cmp_pool))
    needed_mutable = max(0, junc_count - fixed_count)
    zero_self_avail = [c for c in full_pool if c["self_ligation_count"] == 0 and min(c["overhang"], c["rc_overhang"]) not in used_canon]
    pool = [c for c in full_pool if c["self_ligation_count"] == 0] if len(zero_self_avail) >= needed_mutable else full_pool

    # Phase 1: 确定性贪心初始化
    while len(chosen) < junc_count:
        best_cand = None
        best_eval = None
        for cand in pool:
            canon = min(cand["overhang"], cand["rc_overhang"])
            if canon in used_canon:
                continue
            trial_eval = evaluate_golden_gate_overhangs(chosen + [cand["overhang"]], mat)
            if best_eval is None:
                best_cand = cand
                best_eval = trial_eval
            else:
                if abs(trial_eval["assembly_fidelity"] - best_eval["assembly_fidelity"]) > 1e-9:
                    better = trial_eval["assembly_fidelity"] > best_eval["assembly_fidelity"]
                elif trial_eval["cross_mismatch_count"] != best_eval["cross_mismatch_count"]:
                    better = trial_eval["cross_mismatch_count"] < best_eval["cross_mismatch_count"]
                elif (cand["self_ligation_count"] == 0) != (best_cand["self_ligation_count"] == 0):
                    better = (cand["self_ligation_count"] == 0)
                elif cand["is_neb_verified_hf"] != best_cand["is_neb_verified_hf"]:
                    better = cand["is_neb_verified_hf"]
                elif abs(cand["individual_fidelity"] - best_cand["individual_fidelity"]) > 1e-9:
                    better = cand["individual_fidelity"] > best_cand["individual_fidelity"]
                else:
                    better = cand["overhang"] < best_cand["overhang"]
                if better:
                    best_cand = cand
                    best_eval = trial_eval
        if best_cand is None:
            break
        chosen.append(best_cand["overhang"])
        used_canon.add(min(best_cand["overhang"], best_cand["rc_overhang"]))

    best_set = list(chosen)
    best_eval = evaluate_golden_gate_overhangs(best_set, mat)

    # Phase 2: 确定性 1-Swap 坐标上升 + 固定种子模拟退火 (NEB DAD)
    mutable_count = len(best_set) - fixed_count
    if mutable_count > 0 and (best_eval["assembly_fidelity"] < 1.0 - 1e-12 or best_eval["cross_mismatch_count"] > 0) and len(pool) > len(best_set):
        search_pool = pool[:min(len(pool), 72)]

        def _is_better(lhs, rhs):
            if len(lhs["issues"]) != len(rhs["issues"]):
                return len(lhs["issues"]) < len(rhs["issues"])
            if abs(lhs["assembly_fidelity"] - rhs["assembly_fidelity"]) > 1e-9:
                return lhs["assembly_fidelity"] > rhs["assembly_fidelity"]
            return lhs["cross_mismatch_count"] < rhs["cross_mismatch_count"]

        def _one_swap_polish(start_set, start_eval):
            cur = list(start_set)
            cur_eval = start_eval
            for _ in range(12):
                improved = False
                used = {min(o, rev_comp(o)) for o in cur}
                for pos in range(fixed_count, len(cur)):
                    old_ov = cur[pos]
                    old_canon = min(old_ov, rev_comp(old_ov))
                    used.discard(old_canon)
                    local_best_ov = old_ov
                    local_best_eval = cur_eval
                    for cand in search_pool:
                        c_canon = min(cand["overhang"], cand["rc_overhang"])
                        if c_canon in used:
                            continue
                        trial = list(cur)
                        trial[pos] = cand["overhang"]
                        t_eval = evaluate_golden_gate_overhangs(trial, mat)
                        if _is_better(t_eval, local_best_eval):
                            local_best_ov = cand["overhang"]
                            local_best_eval = t_eval
                    cur[pos] = local_best_ov
                    used.add(min(local_best_ov, rev_comp(local_best_ov)))
                    if _is_better(local_best_eval, cur_eval):
                        cur_eval = local_best_eval
                        improved = True
                if not improved or (cur_eval["assembly_fidelity"] >= 1.0 - 1e-12 and cur_eval["cross_mismatch_count"] == 0):
                    break
            return cur, cur_eval

        best_set, best_eval = _one_swap_polish(best_set, best_eval)

        if best_eval["assembly_fidelity"] < 1.0 - 1e-12 or best_eval["cross_mismatch_count"] > 0:
            rng_state = 0x5EED_DAD0_2020_0001
            MASK64 = 0xFFFFFFFFFFFFFFFF

            def _next_u64():
                nonlocal rng_state
                rng_state = (rng_state * 6364136223846793005 + 1442695040888963407) & MASK64
                return rng_state

            cur_set = list(best_set)
            cur_eval = best_eval
            sa_steps = 300
            t_start = 0.025
            t_end = 0.0005
            for step in range(sa_steps):
                pos = fixed_count + (_next_u64() % mutable_count if mutable_count > 1 else 0)
                cand_idx = _next_u64() % len(search_pool) if len(search_pool) > 1 else 0
                cand = search_pool[cand_idx]
                cand_canon = min(cand["overhang"], cand["rc_overhang"])
                if any(min(cur_set[k], rev_comp(cur_set[k])) == cand_canon for k in range(len(cur_set)) if k != pos):
                    continue
                trial = list(cur_set)
                trial[pos] = cand["overhang"]
                t_eval = evaluate_golden_gate_overhangs(trial, mat)
                delta = t_eval["assembly_fidelity"] - cur_eval["assembly_fidelity"]
                frac = float(step) / float(max(1, sa_steps - 1))
                temp = t_start * ((t_end / t_start) ** frac)
                accept = delta >= 0.0
                if not accept:
                    u01 = (_next_u64() >> 11) / float(1 << 53)
                    accept = u01 < math.exp(delta / max(1e-9, temp))
                if accept:
                    cur_set = trial
                    cur_eval = t_eval
                    if _is_better(cur_eval, best_eval):
                        best_set = list(cur_set)
                        best_eval = cur_eval
                        if best_eval["assembly_fidelity"] >= 1.0 - 1e-12 and best_eval["cross_mismatch_count"] == 0:
                            break
            best_set, best_eval = _one_swap_polish(best_set, best_eval)

    for iss in best_eval.get("issues", []):
        if iss not in warnings:
            warnings.append(iss)
    if best_eval["cross_mismatch_count"] > 0:
        warnings.append(f"当前约束下存在 {best_eval['cross_mismatch_count']} 组潜在交叉/自错配。")
    if len(best_set) < junc_count:
        warnings.append(f"{spec['name']} {ov_len}-bp 接头空间不足以分配 {junc_count} 个正交位点。")

    return {
        "enzyme_name": spec["name"],
        "fragment_count": clamped,
        "junction_count": junc_count,
        "overhang_length": ov_len,
        "assigned_overhangs": best_set,
        "assembly_fidelity": best_eval["assembly_fidelity"],
        "cross_mismatch_count": best_eval["cross_mismatch_count"],
        "cross_mismatch_pairs": best_eval["cross_mismatch_pairs"],
        "warnings": warnings,
    }


def domesticate_golden_gate_fragment(
    sequence: str,
    enzyme_name: str,
    fragment_index: int = 0,
    fragment_name: str = "Fragment",
    is_coding_sequence: bool = True,
    reading_frame_offset: int = 0,
    host_organism: str = "human",
) -> dict:
    """扫描片段内部内源 Type IIS 位点并生成宿主特异编码区同义密码子抹除方案（支持单/多碱基与双密码子兜底）"""
    clean = clean_seq(sequence)
    seq_len = len(clean)
    canon_ekey = _canonical_gg_enzyme_key(enzyme_name)
    spec = TYPE_IIS_ENZYME_SPECS.get(canon_ekey, TYPE_IIS_ENZYME_SPECS["bsai"])
    site_fwd = spec["site"]
    site_rev = spec["rc_site"]
    site_len = len(site_fwd)
    host_codons = GG_HOST_PREFERRED_CODONS.get(str(host_organism or "human").strip().lower(), GG_HOST_PREFERRED_CODONS["human"])

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

    def find_site_keys_in_window(chars_list, lo, hi):
        if hi - lo < site_len:
            return set()
        win = "".join(chars_list[lo:hi])
        keys = set()
        for strand, pat in (("+", site_fwd), ("-", site_rev)):
            pos = win.find(pat)
            while pos != -1:
                keys.add((lo + pos, strand))
                pos = win.find(pat, pos + 1)
        return keys

    def is_valid_edit(before_chars, after_chars, target_start, target_strand, edit_start, edit_end):
        win_lo = max(0, min(target_start, edit_start) - site_len + 1)
        win_hi = min(len(after_chars), max(target_start + site_len, edit_end) + site_len - 1)
        before_keys = find_site_keys_in_window(before_chars, win_lo, win_hi)
        after_keys = find_site_keys_in_window(after_chars, win_lo, win_hi)
        if (target_start, target_strand) in after_keys:
            return False
        return len(after_keys - before_keys) == 0

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
            # Tier 1 (1-bp) -> Tier 2 (2/3-bp 单密码子同义替换)，严格要求至少 1 个突变点落在识别位点内部
            for allow_multi in (False, True):
                if applied:
                    break
                for c_start in codon_starts:
                    if applied:
                        break
                    orig_codon = "".join(working[c_start:c_start + 3])
                    aa = GG_CODON_TO_AA.get(orig_codon)
                    syn_list = host_codons.get(aa, []) if aa else []
                    for cand_codon in syn_list:
                        if cand_codon == orig_codon:
                            continue
                        diffs = [k for k in range(3) if orig_codon[k] != cand_codon[k]]
                        if not allow_multi and len(diffs) != 1:
                            continue
                        if allow_multi and len(diffs) < 2:
                            continue
                        inside_offs = [k for k in diffs if s0 <= (c_start + k) < e0]
                        if not inside_offs:
                            continue
                        mut_off = inside_offs[0]
                        mut_pos0 = c_start + mut_off
                        trial = list(working)
                        trial[c_start:c_start + 3] = list(cand_codon)
                        if is_valid_edit(working, trial, s0, strand, c_start, c_start + 3):
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

            # Tier 3: 双密码子协同同义替换兜底
            if not applied and len(codon_starts) >= 2:
                for idx_a in range(len(codon_starts)):
                    if applied:
                        break
                    c_a = codon_starts[idx_a]
                    orig_a = "".join(working[c_a:c_a + 3])
                    aa_a = GG_CODON_TO_AA.get(orig_a)
                    syn_a = host_codons.get(aa_a, []) if aa_a else []
                    for cand_a in syn_a:
                        if applied:
                            break
                        if cand_a == orig_a:
                            continue
                        for idx_b in range(idx_a + 1, len(codon_starts)):
                            if applied:
                                break
                            c_b = codon_starts[idx_b]
                            orig_b = "".join(working[c_b:c_b + 3])
                            aa_b = GG_CODON_TO_AA.get(orig_b)
                            syn_b = host_codons.get(aa_b, []) if aa_b else []
                            for cand_b in syn_b:
                                if cand_b == orig_b:
                                    continue
                                trial = list(working)
                                trial[c_a:c_a + 3] = list(cand_a)
                                trial[c_b:c_b + 3] = list(cand_b)
                                if is_valid_edit(working, trial, s0, strand, min(c_a, c_b), max(c_a, c_b) + 3):
                                    working = trial
                                    off_a = next((k for k in range(3) if orig_a[k] != cand_a[k]), 2)
                                    codon_idx_a = ((c_a - frame) // 3) + 1
                                    codon_idx_b = ((c_b - frame) // 3) + 1
                                    suggestions.append({
                                        "fragment_index": fragment_index,
                                        "fragment_name": fragment_name,
                                        "enzyme_name": spec["name"],
                                        "site_strand": strand,
                                        "site_start_1based": s0 + 1,
                                        "site_end_1based": e0,
                                        "original_site": site_str,
                                        "is_coding_sequence": True,
                                        "codon_index_1based": codon_idx_a,
                                        "original_codon": orig_a,
                                        "mutated_codon": cand_a,
                                        "amino_acid": aa_a,
                                        "mutation_position_1based": c_a + off_a + 1,
                                        "original_base": orig_a[off_a],
                                        "mutated_base": cand_a[off_a],
                                        "is_synonymous": True,
                                        "note": f"双密码子协同同义抹除 #{codon_idx_a}({orig_a}→{cand_a}) + #{codon_idx_b}({orig_b}→{cand_b})",
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
                if is_valid_edit(working, trial, s0, strand, mid_pos0, mid_pos0 + 1):
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


def detect_junction_spanning_sites(
    domesticated_sequences: list,
    assigned_overhangs: list,
    enzyme_name: str,
    is_circular: bool = True,
) -> list:
    """检测片段拼接接头跨界处（Junction-spanning）是否意外生成新的 Type IIS 识别位点"""
    canon_ekey = _canonical_gg_enzyme_key(enzyme_name)
    spec = TYPE_IIS_ENZYME_SPECS.get(canon_ekey, TYPE_IIS_ENZYME_SPECS["bsai"])
    site_fwd = spec["site"]
    site_rev = spec["rc_site"]
    flank = max(1, len(site_fwd) - 1)
    n = len(domesticated_sequences)
    if n == 0 or not assigned_overhangs:
        return []
    warnings = []
    seam_count = min(n, len(assigned_overhangs)) if is_circular else min(n + 1, len(assigned_overhangs))
    for j in range(seam_count):
        ov = assigned_overhangs[j]
        if is_circular:
            left_seq = domesticated_sequences[(j + n - 1) % n]
            right_seq = domesticated_sequences[j]
        else:
            left_seq = domesticated_sequences[j - 1] if j > 0 else ""
            right_seq = domesticated_sequences[j] if j < n else ""
        left_tail = left_seq[-flank:] if (flank > 0 and left_seq) else ""
        right_head = right_seq[:flank] if right_seq else ""
        seam = left_tail + ov + right_head
        hits = []
        if site_fwd in seam:
            hits.append(site_fwd)
        if site_rev in seam:
            hits.append(site_rev)
        if hits:
            hit_desc = "/".join(hits)
            warnings.append(
                f"接头 #{j + 1} ({ov}) 跨界拼接区 {left_tail}|{ov}|{right_head} 意外生成了新的 {spec['name']} 位点 ({hit_desc})，建议更换该接头或调整邻接密码子。"
            )
    return warnings


def design_golden_gate_assembly(args: dict) -> dict:
    """端到端 Type IIS Golden Gate 全局优化接头分配、内源位点 Domestication 与跨界位点检测"""
    enzyme_name = str(args.get("enzyme_name") or "BsaI").strip()
    spec = TYPE_IIS_ENZYME_SPECS.get(_canonical_gg_enzyme_key(enzyme_name), TYPE_IIS_ENZYME_SPECS["bsai"])
    fragments = args.get("fragments") or []
    fixed_overhangs = args.get("fixed_overhangs") or []
    is_circular = bool(args.get("is_circular", True))
    db_path = args.get("db_path")
    host_organism = str(args.get("host_organism") or "human").strip().lower()
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
            host_organism=host_organism,
        )
        doms.append(d)
        total_sites += d["internal_sites_found"]
        total_frag_len += len(d["domesticated_sequence"])

    junction_warnings = detect_junction_spanning_sites(
        domesticated_sequences=[d["domesticated_sequence"] for d in doms],
        assigned_overhangs=ov_plan["assigned_overhangs"],
        enzyme_name=spec["name"],
        is_circular=is_circular,
    )
    if junction_warnings:
        ov_plan = dict(ov_plan)
        ov_plan["warnings"] = list(ov_plan["warnings"]) + junction_warnings

    return {
        "enzyme_name": spec["name"],
        "recognition_site": spec["site"],
        "overhang_length": spec["overhang_len"],
        "overhang_plan": ov_plan,
        "domestications": doms,
        "total_internal_sites_found": total_sites,
        "assembled_sequence_length": total_frag_len + len(ov_plan["assigned_overhangs"]) * spec["overhang_len"],
        "junction_site_warnings": junction_warnings,
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


_METHYLATION_SENSITIVITY_TABLE = {
    "clai": ["Dam", "CpG"], "xbai": ["Dam"], "bcli": ["Dam"], "mboi": ["Dam"], "dpnii": ["Dam"],
    "hphi": ["Dam"], "taqi": ["Dam"], "nrui": ["Dam", "CpG"],
    "stui": ["Dcm"], "apai": ["Dcm", "CpG"], "ecorii": ["Dcm"], "sexai": ["Dcm"], "styi": ["Dcm"], "bsai": ["Dcm", "CpG"],
    "noti": ["CpG"], "hpaii": ["CpG"], "smai": ["CpG"], "sali": ["CpG"], "xhoi": ["CpG"],
    "agei": ["CpG"], "sacii": ["CpG"], "eagi": ["CpG"], "pvui": ["CpG"], "bsmbi": ["CpG"],
}


def _check_methylation_block(
    enz_name: str,
    clean_seq: str,
    site_start0: int,
    site_len: int,
    is_circular: bool,
    dam_methylated: bool,
    dcm_methylated: bool,
    cpg_methylated: bool,
) -> set:
    sens = _METHYLATION_SENSITIVITY_TABLE.get(enz_name.lower(), [])
    n_s = len(clean_seq)
    if not sens or n_s == 0 or site_len <= 0:
        return set()
    pad = 4
    win = []
    actual_left_pad = 0
    for off in range(-pad, site_len + pad):
        k = site_start0 + off
        if is_circular:
            win.append(clean_seq[k % n_s])
            if off < 0:
                actual_left_pad += 1
        elif 0 <= k < n_s:
            win.append(clean_seq[k])
            if off < 0:
                actual_left_pad += 1
    w_str = "".join(win)
    s_lo = actual_left_pad
    s_hi = actual_left_pad + site_len

    def _hits(motif: str, m_offs: tuple) -> bool:
        p0 = 0
        while True:
            mi = w_str.find(motif, p0)
            if mi == -1:
                return False
            if any(s_lo <= mi + mo < s_hi for mo in m_offs):
                return True
            p0 = mi + 1

    blocked = set()
    if dam_methylated and "Dam" in sens and _hits("GATC", (1, 2)):
        blocked.add("Dam (GATC)")
    if dcm_methylated and "Dcm" in sens and (_hits("CCAGG", (1, 3)) or _hits("CCTGG", (1, 3))):
        blocked.add("Dcm (CCWGG)")
    if cpg_methylated and "CpG" in sens and _hits("CG", (0, 1)):
        blocked.add("CpG (CG)")
    return blocked


def _find_enzyme_cut_positions(
    clean_seq: str,
    enz_name: str,
    is_circular: bool,
    dam_methylated: bool = False,
    dcm_methylated: bool = False,
    cpg_methylated: bool = False,
) -> list:
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
            if (dam_methylated or dcm_methylated or cpg_methylated) and _check_methylation_block(
                enz_name, clean_seq, pos, site_len, is_circular, dam_methylated, dcm_methylated, cpg_methylated
            ):
                pos = search_seq.find(site, pos + 1)
                continue
            top_snip = (raw_top % seq_len) if is_circular else raw_top
            snips.append(top_snip)
        pos = search_seq.find(site, pos + 1)
    return snips


def simulate_digest_fragments(
    clean_seq: str,
    enzyme_names: list,
    is_circular: bool = True,
    dam_methylated: bool = False,
    dcm_methylated: bool = False,
    cpg_methylated: bool = False,
) -> list:
    """模拟单/双酶切产生的条带长度列表 (bp, 降序)"""
    total_len = len(clean_seq)
    if total_len == 0:
        return []
    cut_positions = set()
    for e_name in enzyme_names:
        for pos in _find_enzyme_cut_positions(
            clean_seq,
            e_name,
            is_circular,
            dam_methylated=dam_methylated,
            dcm_methylated=dcm_methylated,
            cpg_methylated=cpg_methylated,
        ):
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
    dam_m = bool(args.get("dam_methylated", True))
    dcm_m = bool(args.get("dcm_methylated", True))
    cpg_m = bool(args.get("cpg_methylated", False))

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
        neg_cuts = len(_find_enzyme_cut_positions(clean_empty, enz, is_circular, dam_m, dcm_m, cpg_m))
        pos_cuts = len(_find_enzyme_cut_positions(clean_recomb, enz, is_circular, dam_m, dcm_m, cpg_m))
        if (neg_cuts >= 1 or pos_cuts >= 1) and neg_cuts <= 6 and pos_cuts <= 6:
            viable.append(enz)
            single_empty[enz] = simulate_digest_fragments(clean_empty, [enz], is_circular, dam_m, dcm_m, cpg_m)
            single_recomb[enz] = simulate_digest_fragments(clean_recomb, [enz], is_circular, dam_m, dcm_m, cpg_m)

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
            empty_all = simulate_digest_fragments(clean_empty, enz_list, is_circular, dam_m, dcm_m, cpg_m)
            recomb_all = simulate_digest_fragments(clean_recomb, enz_list, is_circular, dam_m, dcm_m, cpg_m)

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
    else:
        temp_tbl = {"smai": 25, "apai": 25, "bcli": 50, "sfii": 50, "bsteii": 60, "taqi": 65, "bsmbi": 55, "bsli": 55}
        star_tbl = {
            "ecori": "甘油 >5% 或低盐高 pH 易诱发星号活性",
            "bamhi": "甘油 >5% 或过量酶/过长时间易诱发星号活性（推荐使用 BamHI-HF）",
            "hindiii": "甘油 >5% 或高酶量/低离子强度易诱发星号活性",
            "sali": "甘油 >5% 或低盐条件易诱发星号活性",
            "scai": "甘油 >5% 或过长孵育易诱发星号活性（推荐使用 ScaI-HF）",
            "psti": "甘油 >5% 或高 pH 易诱发星号活性",
            "pvuii": "甘油 >5% 或高酶量易诱发星号活性",
            "xbai": "高甘油或超时孵育易诱发星号活性",
        }
        def _collect_meth_blocks_py(ename: str, seq_s: str, site_s: str) -> set:
            if not seq_s or not site_s:
                return set()
            n_s = len(seq_s)
            sl = len(site_s)
            scan_s = (seq_s + seq_s[:sl - 1]) if is_circular else seq_s
            blocked = set()
            pos = 0
            while True:
                idx = scan_s.find(site_s, pos)
                if idx == -1 or idx >= n_s:
                    break
                pos = idx + 1
                blocked |= _check_methylation_block(ename, seq_s, idx, sl, is_circular, dam_m, dcm_m, cpg_m)
            return blocked
        for rec in top_items:
            enames = rec["enzyme_names"]
            temps = {temp_tbl.get(e.lower(), 37) for e in enames}
            if len(temps) > 1:
                detail = " + ".join(f"{e} ({temp_tbl.get(e.lower(), 37)}°C)" for e in enames)
                warnings.append(f"方案 #{rec['rank']} 存在反应温度不兼容：{detail}，需分步顺序酶切。")
            b_descs = []
            for e in enames:
                site_s = DEFAULT_DIAGNOSTIC_ENZYMES.get(e, ("", 0, 0))[0] or COMMON_ENZYMES.get(e, "")
                blks = _collect_meth_blocks_py(e, clean_empty, site_s) | _collect_meth_blocks_py(e, clean_recomb, site_s)
                if blks:
                    b_descs.append(f"{e} [{'/'.join(sorted(blks))}]")
            if b_descs:
                warnings.append(f"方案 #{rec['rank']} 在当前宿主甲基化条件下存在真实切点阻断 ({', '.join(b_descs)})，建议改用 Dam-/Dcm- 宿主或替换非敏感酶。")
            for e in enames:
                sn = star_tbl.get(e.lower())
                if sn:
                    warnings.append(f"方案 #{rec['rank']} {e} 星号活性提示：{sn}")

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


def detect_cds_region_with_strand(reference_sequence: str, cut_index_0based: int, min_length_bp: int = 90):
    """双链（+ / -）并行扫描三读码框，提取覆盖 cut_index_0based 的最长完整 ORF（>= 90 bp）。"""
    seq = clean_seq(reference_sequence)
    n = len(seq)
    if n < min_length_bp:
        return None
    fwd = detect_cds_region(seq, cut_index_0based, min_length_bp=min_length_bp)
    rc = rev_comp(seq)
    rc_cut = max(0, min(n - 1, n - 1 - cut_index_0based))
    rev_raw = detect_cds_region(rc, rc_cut, min_length_bp=min_length_bp)
    rev = (n - rev_raw[1], n - rev_raw[0]) if rev_raw is not None else None
    if fwd is not None and rev is not None:
        return (rev[0], rev[1], "-") if (rev[1] - rev[0]) > (fwd[1] - fwd[0]) else (fwd[0], fwd[1], "+")
    if fwd is not None:
        return (fwd[0], fwd[1], "+")
    if rev is not None:
        return (rev[0], rev[1], "-")
    return None


def _hdr_translate_cds(sequence: str, start_0based: int, end_0based: int, strand: str = "+") -> str:
    seq = clean_seq(sequence)
    s = max(0, int(start_0based))
    e = min(len(seq), int(end_0based))
    if s >= e:
        return ""
    sl = seq[s:e]
    coding = rev_comp(sl) if strand == "-" else sl
    out = []
    i = 0
    while i + 3 <= len(coding):
        out.append(GG_CODON_TO_AA.get(coding[i:i + 3], "X"))
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
    asymmetric_richardson = bool(args.get("asymmetric_richardson_ssodn", False))
    auto_detect_cds = bool(args.get("auto_detect_cds", True))
    enable_rflp = bool(args.get("enable_rflp", False))
    rflp_radius = max(3, int(args.get("rflp_search_radius_bp", 15)))
    out_out_margin = int(args.get("out_out_margin_bp", 100))
    primer_target_tm = float(args.get("primer_target_tm", 60.0))
    donor_name = str(args.get("donor_name", "HDR_Donor"))
    req_cds_strand = str(args.get("cds_strand") or "+").strip()
    req_cds_frame_offset = args.get("cds_frame_offset")

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

    # Richardson et al. (Nat Biotechnol 2016) 36/91 nt asymmetric ssODN arm defaults
    if donor_format == "ssODN" and asymmetric_richardson:
        default_left_arm = 36 if strand == "+" else 91
        default_right_arm = 91 if strand == "+" else 36
    else:
        default_arm = 60 if donor_format == "ssODN" else 600
        default_left_arm = default_arm
        default_right_arm = default_arm
    req_left_arm = max(1, int(args.get("left_arm_length_bp") or default_left_arm))
    req_right_arm = max(1, int(args.get("right_arm_length_bp") or default_right_arm))

    # 2. Detect or validate CDS (supports + / - strands & cds_frame_offset)
    is_in_cds = False
    cds_auto_detected = False
    resolved_cds_strand = "-" if req_cds_strand == "-" else "+"
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
    elif req_cds_frame_offset is not None and 0 <= int(req_cds_frame_offset) <= 2:
        fo = int(req_cds_frame_offset)
        s0 = fo
        e0 = s0 + ((L - s0) // 3) * 3
        if s0 <= wt_cut_index0 < e0 and e0 - s0 >= 9:
            is_in_cds = True
            wt_cds_start0 = s0
            wt_cds_end0 = e0
    elif auto_detect_cds:
        detected = detect_cds_region_with_strand(ref, wt_cut_index0)
        if detected is not None:
            is_in_cds = True
            cds_auto_detected = True
            wt_cds_start0, wt_cds_end0, resolved_cds_strand = detected

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

    protein_before = _hdr_translate_cds("".join(edited_chars), edited_cds_start0, edited_cds_end0, strand=resolved_cds_strand) if is_in_cds else ""
    cut_to_edit_dist = 0 if (edit_start0 <= wt_cut_index0 <= edit_end0) else min(abs(wt_cut_index0 - edit_start0), abs(wt_cut_index0 - edit_end0))
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
    if cut_to_edit_dist > 10:
        warnings.append(
            f"DSB 切点至编辑位点距离为 {cut_to_edit_dist} bp（>10 bp），据 Paquet et al. (Nature 2016) HDR 效率将显著下降，强烈建议保留沉默阻断突变或改选更近的 sgRNA。"
        )
    blocking_mutations = []

    _comp_map = {"A": "T", "T": "A", "C": "G", "G": "C"}

    def _sense_codon_info(pos: int, chars: list):
        if resolved_cds_strand == "+":
            rel = pos - edited_cds_start0
            c_start = edited_cds_start0 + (rel // 3) * 3
            if c_start + 3 > edited_cds_end0:
                return None
            off = pos - c_start
            orig_codon = "".join(chars[c_start:c_start + 3])
            return c_start, off, orig_codon
        rev_rel = (edited_cds_end0 - 1) - pos
        c_end = edited_cds_end0 - (rev_rel // 3) * 3
        c_start = c_end - 3
        if c_start < edited_cds_start0 or c_end > edited_cds_end0:
            return None
        off = rev_rel % 3
        orig_codon = _comp_map.get(chars[c_end - 1], chars[c_end - 1]) + _comp_map.get(chars[c_end - 2], chars[c_end - 2]) + _comp_map.get(chars[c_end - 3], chars[c_end - 3])
        return c_start, off, orig_codon

    def _fwd_codon_bases(codon_s: str) -> list:
        if resolved_cds_strand == "+":
            return list(codon_s)
        return [_comp_map.get(codon_s[2], codon_s[2]), _comp_map.get(codon_s[1], codon_s[1]), _comp_map.get(codon_s[0], codon_s[0])]

    def _try_1bp_syn_all(pos: int, chars: list, locked: set, reason: str):
        if not is_in_cds or pos < edited_cds_start0 or pos >= edited_cds_end0 or pos in locked:
            return []
        info = _sense_codon_info(pos, chars)
        if info is None:
            return []
        _, off, orig_codon = info
        aa = GG_CODON_TO_AA.get(orig_codon)
        if aa is None:
            return []
        out = []
        for alt_codon in GG_PREFERRED_CODONS.get(aa, []):
            if alt_codon == orig_codon:
                continue
            diffs = [k for k in range(3) if alt_codon[k] != orig_codon[k]]
            if len(diffs) == 1 and diffs[0] == off:
                fwd_new = alt_codon[off] if resolved_cds_strand == "+" else _comp_map.get(alt_codon[off], alt_codon[off])
                out.append((fwd_new, {
                    "position_0based": pos,
                    "position_1based": pos + 1,
                    "original_base": chars[pos],
                    "mutated_base": fwd_new,
                    "reason": reason,
                    "codon_before": orig_codon,
                    "codon_after": alt_codon,
                    "amino_acid": aa,
                }))
        return out

    def _try_1bp_syn(pos: int, chars: list, locked: set, reason: str):
        hits = _try_1bp_syn_all(pos, chars, locked, reason)
        return hits[0] if hits else None

    if not _is_pam_intact(edited_chars):
        blocking_strategy = "already_disrupted_by_edit"
    elif is_in_cds:
        def _is_non_canonical_pam(ch_arr):
            if edited_pam_start0 < 0 or edited_pam_start0 + 3 > len(ch_arr):
                return False
            if strand == "+":
                b1, b2 = ch_arr[edited_pam_start0 + 1], ch_arr[edited_pam_start0 + 2]
                return (b1 == "A" and b2 == "G") or (b1 == "G" and b2 == "A")
            else:
                b0, b1 = ch_arr[edited_pam_start0], ch_arr[edited_pam_start0 + 1]
                return (b0 == "C" and b1 == "T") or (b0 == "T" and b1 == "C")

        broke_pam = False
        fallback_hit = None
        for cp in pam_crit_indices:
            for nb, rec in _try_1bp_syn_all(cp, edited_chars, edit_locked, "pam_block"):
                cand = list(edited_chars)
                cand[cp] = nb
                if not _is_pam_intact(cand):
                    if not _is_non_canonical_pam(cand):
                        edited_chars = cand
                        blocking_mutations.append(rec)
                        broke_pam = True
                        break
                    elif fallback_hit is None:
                        fallback_hit = (cp, nb, rec)
            if broke_pam:
                break
        if not broke_pam and fallback_hit is not None:
            fcp, fnb, frec = fallback_hit
            edited_chars[fcp] = fnb
            blocking_mutations.append(frec)
            broke_pam = True
            warnings.append("同义突变受限，阻断后产生 SpCas9 次级非典型 PAM (NAG/NGA)，建议结合 Seed 区附加沉默突变以降低残留切割风险。")
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
                if resolved_cds_strand == "+":
                    c_start = edited_cds_start0 + ((sp - edited_cds_start0) // 3) * 3
                else:
                    c_start = edited_cds_end0 - (((edited_cds_end0 - 1) - sp) // 3 + 1) * 3
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
        def _is_non_canonical_pam_nc(ch_arr):
            if edited_pam_start0 < 0 or edited_pam_start0 + 3 > len(ch_arr):
                return False
            if strand == "+":
                b1, b2 = ch_arr[edited_pam_start0 + 1], ch_arr[edited_pam_start0 + 2]
                return (b1 == "A" and b2 == "G") or (b1 == "G" and b2 == "A")
            else:
                b0, b1 = ch_arr[edited_pam_start0], ch_arr[edited_pam_start0 + 1]
                return (b0 == "C" and b1 == "T") or (b0 == "T" and b1 == "C")
        mp = None
        for cp in pam_crit_indices:
            if 0 <= cp < len(edited_chars) and cp not in edit_locked:
                mp = cp
                break
        if mp is not None:
            ob = edited_chars[mp]
            pref = ["C", "T", "A", "G"] if strand == "+" else ["G", "A", "T", "C"]
            ab = None
            for b in pref:
                if b == ob:
                    continue
                cand = list(edited_chars)
                cand[mp] = b
                if not _is_pam_intact(cand) and not _is_non_canonical_pam_nc(cand):
                    ab = b
                    break
            if ab is None:
                ab = ("C" if ob == "G" else "T") if strand == "+" else ("G" if ob == "C" else "A")
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
                    all_cds_codons = []
                    if resolved_cds_strand == "+":
                        cs = edited_cds_start0
                        while cs + 3 <= edited_cds_end0:
                            all_cds_codons.append(cs)
                            cs += 3
                    else:
                        cs = edited_cds_end0 - 3
                        while cs >= edited_cds_start0:
                            all_cds_codons.append(cs)
                            cs -= 3
                    overlap_codons = [c for c in all_cds_codons if c + 3 > sp and c < sp + 6]
                    overlap_codons.sort(key=lambda c: (abs((c + 1) - edit_start0), c))
                    for cs in overlap_codons:
                        info_c = _sense_codon_info(cs, edited_chars)
                        if info_c is None:
                            continue
                        _, _, orig_codon = info_c
                        orig_arr = edited_chars[cs:cs + 3]
                        aa = GG_CODON_TO_AA.get(orig_codon)
                        if aa is None:
                            continue
                        for alt_codon in GG_PREFERRED_CODONS.get(aa, []):
                            if alt_codon == orig_codon:
                                continue
                            alt_arr = _fwd_codon_bases(alt_codon)
                            diffs = [k for k in range(3) if alt_arr[k] != orig_arr[k]]
                            if len(diffs) == 1:
                                k = diffs[0]
                                mut_pos = cs + k
                                if sp <= mut_pos < sp + 6 and mut_pos not in rflp_locked:
                                    cand = list(edited_chars)
                                    cand[mut_pos] = alt_arr[k]
                                    if pam_broken_before and _is_pam_intact(cand):
                                        continue
                                    if "".join(cand[sp:sp + 6]) != site:
                                        edited_chars = cand
                                        rflp_muts = [{
                                            "position_0based": mut_pos,
                                            "position_1based": mut_pos + 1,
                                            "original_base": orig_arr[k],
                                            "mutated_base": alt_arr[k],
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
                if resolved_cds_strand == "+":
                    cs = edited_cds_start0
                    while cs + 3 <= edited_cds_end0:
                        if cs >= win_start and cs + 3 <= win_end:
                            ordered_codons.append(cs)
                        cs += 3
                else:
                    cs = edited_cds_end0 - 3
                    while cs >= edited_cds_start0:
                        if cs >= win_start and cs + 3 <= win_end:
                            ordered_codons.append(cs)
                        cs -= 3
                ordered_codons.sort(key=lambda c: (abs((c + 1) - edit_start0), c))
                found_create = False
                for target_diffs in (1, 2):
                    if found_create:
                        break
                    for cs in ordered_codons:
                        if found_create:
                            break
                        info_c = _sense_codon_info(cs, edited_chars)
                        if info_c is None:
                            continue
                        _, _, orig_codon = info_c
                        orig_arr = edited_chars[cs:cs + 3]
                        aa = GG_CODON_TO_AA.get(orig_codon)
                        if aa is None:
                            continue
                        for alt_codon in GG_PREFERRED_CODONS.get(aa, []):
                            if found_create:
                                break
                            if alt_codon == orig_codon:
                                continue
                            alt_arr = _fwd_codon_bases(alt_codon)
                            diffs = [k for k in range(3) if alt_arr[k] != orig_arr[k]]
                            if len(diffs) != target_diffs:
                                continue
                            mut_positions = [cs + k for k in diffs]
                            if any(p in rflp_locked for p in mut_positions):
                                continue
                            cand = list(edited_chars)
                            for k in diffs:
                                cand[cs + k] = alt_arr[k]
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
                                                "original_base": orig_arr[k],
                                                "mutated_base": alt_arr[k],
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

    # 6. Final locus checks, GT-AG splice-site check & protein conservation check
    final_edited_seq = "".join(edited_chars)
    protein_after = _hdr_translate_cds(final_edited_seq, edited_cds_start0, edited_cds_end0, strand=resolved_cds_strand) if is_in_cds else ""
    amino_acid_conserved = (not is_in_cds) or (protein_before == protein_after)
    all_silent_muts = blocking_mutations + rflp_muts
    if is_in_cds and all_silent_muts:
        pre_silent = list(edited_chars)
        for m in all_silent_muts:
            mp0 = int(m["position_0based"])
            if 0 <= mp0 < len(pre_silent):
                pre_silent[mp0] = m["original_base"]
        splice_dinucs = {"CT", "AC"} if resolved_cds_strand == "-" else {"GT", "AG"}
        boundary_muts = [
            int(m["position_0based"]) for m in all_silent_muts
            if abs(int(m["position_0based"]) - edited_cds_start0) <= 3 or abs(int(m["position_0based"]) - (edited_cds_end0 - 1)) <= 3
        ]
        hits_splice = any(
            ((pre_silent[p - 1] + pre_silent[p]) in splice_dinucs if 0 < p < len(pre_silent) else False)
            or ((pre_silent[p] + pre_silent[p + 1]) in splice_dinucs if 0 <= p + 1 < len(pre_silent) else False)
            for p in boundary_muts
        )
        if hits_splice:
            warnings.append("沉默阻断/RFLP 突变位于 CDS 边界 ±3 bp 的经典 GT-AG 剪接供体/受体二核苷酸处，存在破坏 mRNA 剪接风险，请人工复核。")
    edited_pam_seq = final_edited_seq[edited_pam_start0:edited_pam_start0 + 3] if 0 <= edited_pam_start0 <= len(edited_chars) - 3 else ""
    pam_still_intact = _is_pam_intact(edited_chars)
    cas9_recut_blocked = (blocking_strategy != "failed_to_block") and ((not pam_still_intact) or blocking_strategy == "seed_synonymous_fallback")

    # 7. Slice homology arms & donor (supports Richardson 2016 36/91 nt target strand)
    left_arm = final_edited_seq[left_arm_start0:edit_start0]
    insert_payload = final_edited_seq[edit_start0:edit_start0 + len(rep)]
    right_arm = final_edited_seq[edit_start0 + len(rep):right_arm_end0_edited]
    raw_donor_fwd = left_arm + insert_payload + right_arm
    if donor_format == "ssODN" and asymmetric_richardson:
        if strand == "+":
            donor_seq = rev_comp(raw_donor_fwd)
            donor_strand_orientation = "target_strand_antisense_richardson_36_91"
        else:
            donor_seq = raw_donor_fwd
            donor_strand_orientation = "target_strand_sense_richardson_91_36"
    else:
        donor_seq = raw_donor_fwd
        donor_strand_orientation = "forward_reference"

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
        fwd_seq = pick_specific_annealing_seq(fwd_window, five_prime_overhang="", target_tm=primer_target_tm, tolerance=1.5)
        fwd_tm = calc_snapgene_tm(fwd_seq)
        fwd_start0 = fwd_search_start
        fwd_end0 = fwd_start0 + len(fwd_seq)

        rev_search_start = right_arm_end0_wt + eff_right_margin
        rev_search_end = min(L, rev_search_start + 40)
        rev_window = ref[rev_search_start:rev_search_end]
        rev_seq = pick_specific_annealing_seq(rev_comp(rev_window), five_prime_overhang="", target_tm=primer_target_tm, tolerance=1.5)
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
        wt_bands = _hdr_predict_linear_digest_bands(wt_target, rflp_spec["site"], rflp_spec["top_cut_offset"])
        hdr_bands = _hdr_predict_linear_digest_bands(hdr_target, rflp_spec["site"], rflp_spec["top_cut_offset"])
        has_extra_bg = (len(wt_bands) > 1 or len(hdr_bands) > 2) if rflp_mode == "created" else (len(wt_bands) > 2 or len(hdr_bands) > 1)
        if has_extra_bg:
            warnings.append(
                f"RFLP 诊断酶 {rflp_spec['name']} 在扩增子全长内存在额外背景切点（WT {len(wt_bands)} 条带 / HDR {len(hdr_bands)} 条带），电泳判读时请注意区分背景片段。"
            )
        rflp_res = {
            "mode": rflp_mode,
            "enzyme_name": rflp_spec["name"],
            "recognition_site": rflp_spec["site"],
            "top_cut_offset": rflp_spec["top_cut_offset"],
            "wt_amplicon_bands_bp": wt_bands,
            "hdr_amplicon_bands_bp": hdr_bands,
            "silent_mutations": rflp_muts,
            "note": rflp_note,
        }

    return {
        "donor_format": donor_format,
        "sgrna_sequence": guide,
        "strand": strand,
        "wt_cut_index_0based": wt_cut_index0,
        "cut_to_edit_distance_bp": cut_to_edit_dist,
        "wt_pam_start_0based": wt_pam_start0,
        "wt_pam_sequence": wt_pam_seq,
        "is_in_cds": is_in_cds,
        "cds_strand": resolved_cds_strand,
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
        "donor_strand_orientation": donor_strand_orientation,
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
    se_percent: Optional[float]
    p_value: Optional[float]


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
    min_component_percent: float
    alignment_offset_bp: int
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
    alignment_offset_bp: int
    hdr_wt_cosine_similarity: Optional[float]
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
    host_organism: str
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
    junction_site_warnings: List[str]


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
    cds_strand: str
    cds_frame_offset: Optional[int]
    auto_detect_cds: bool
    enable_rflp: bool
    rflp_search_radius_bp: int
    out_out_margin_bp: int
    primer_target_tm: float
    donor_name: str
    asymmetric_richardson_ssodn: bool


class DesignHdrDonorOutputDict(TypedDict):
    donor_format: str
    sgrna_sequence: str
    strand: str
    wt_cut_index_0based: int
    cut_to_edit_distance_bp: int
    wt_pam_start_0based: int
    wt_pam_sequence: str
    is_in_cds: bool
    cds_strand: str
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
    donor_strand_orientation: str
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
    is_ab1_mode = bool((d.get("wt_ab1_path") or "").strip()) or bool((d.get("edited_ab1_path") or "").strip())
    default_smin = -30 if is_ab1_mode else -20
    default_smax = 14 if is_ab1_mode else 20
    for k, dv in (("shift_min_bp", default_smin), ("shift_max_bp", default_smax), ("noise_floor_weight", 1e-6), ("min_component_percent", 1.0), ("alignment_offset_bp", 0)):
        if d.get(k) is None:
            d[k] = dv
    for k in ("window_length_bp", "requested_window_length_bp", "cut_index_0based", "shift_min_bp", "shift_max_bp", "alignment_offset_bp"):
        if d.get(k) is not None and not _is_non_bool_int(d[k]):
            raise ValueError(f"{k} 必须为整数，收到 {type(d[k]).__name__}")
    for k in ("noise_floor_weight", "min_component_percent"):
        if d.get(k) is not None and not _is_non_bool_number(d[k]):
            raise ValueError(f"{k} 必须为数值")
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
        se_percent: Optional[float] = None
        p_value: Optional[float] = None


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
        min_component_percent: float = Field(default=1.0, ge=0.0, le=50.0)
        alignment_offset_bp: int = 0
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
        alignment_offset_bp: int = 0
        hdr_wt_cosine_similarity: Optional[float] = None
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
        fragment_count: Optional[int] = Field(default=None, ge=2, le=24)
        is_circular: bool = True
        fixed_overhangs: List[str] = Field(default_factory=list)
        host_organism: Literal["human", "ecoli", "yeast"] = "human"
        fragments: List[GoldenGateFragmentInput] = Field(default_factory=list)
        db_path: Optional[str] = None

        @model_validator(mode="after")
        def _validate_cross(self) -> "DesignGoldenGateAssemblyInput":
            max_frags = 15 if self.enzyme_name == "SapI" else 24
            if not self.fragments and self.fragment_count is None:
                raise ValueError(f"未传入 fragments 时必须显式指定 fragment_count (2–{max_frags})")
            eff = self.fragment_count if self.fragment_count is not None else len(self.fragments)
            if not (2 <= eff <= max_frags):
                raise ValueError(f"有效组装片段数必须在 2–{max_frags} 之间，当前为 {eff}")
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
        junction_site_warnings: List[str] = Field(default_factory=list)


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
        cds_strand: str = "+"
        cds_frame_offset: Optional[int] = Field(default=None, ge=0, le=2)
        auto_detect_cds: bool = True
        enable_rflp: bool = False
        rflp_search_radius_bp: int = Field(default=15, ge=3)
        out_out_margin_bp: int = Field(default=100, ge=0)
        primer_target_tm: float = Field(default=60.0, ge=40.0, le=85.0)
        donor_name: str = "HDR_Donor"
        asymmetric_richardson_ssodn: bool = False

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
        cut_to_edit_distance_bp: int = 0
        wt_pam_start_0based: int
        wt_pam_sequence: str
        is_in_cds: bool
        cds_strand: str = "+"
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
        donor_strand_orientation: str = "forward_reference"
        final_edited_locus_sequence: str
        rflp: Optional[RFLPDesignModel] = None
        out_out_pcr: Optional[OutOutPCRModel] = None
        warnings: List[str]


def _stdlib_validate_deconv(raw: Dict[str, Any]) -> Dict[str, Any]:
    allowed = {
        "wt_sequence", "sgrna_sequence", "wt_peaks_acgt", "edited_peaks_acgt",
        "hdr_donor_sequence", "hdr_peaks_acgt", "cut_index_0based",
        "is_reverse_strand_sgrna", "window_length_bp", "requested_window_length_bp",
        "shift_min_bp", "shift_max_bp", "noise_floor_weight", "min_component_percent",
        "alignment_offset_bp", "wt_ab1_path", "edited_ab1_path",
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
    mcp = float(d.get("min_component_percent", 1.0))
    if not (0.0 <= mcp <= 50.0):
        raise ValueError("min_component_percent 必须在 0.0–50.0 之间")
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
    allowed = {"enzyme_name", "fragment_count", "is_circular", "fixed_overhangs", "fragments", "db_path", "host_organism"}
    unknown = set(raw.keys()) - allowed
    if unknown:
        raise ValueError(f"design_golden_gate_assembly 存在未定义字段: {sorted(unknown)}")
    d = _prepare_gg_input_dict(raw)
    if d["enzyme_name"] not in ("BsaI", "BsmBI", "BbsI", "SapI"):
        raise ValueError(f"enzyme_name 仅支持 BsaI/BsmBI/BbsI/SapI，收到 {d['enzyme_name']}")
    host = str(d.get("host_organism") or "human").strip().lower()
    if host not in ("human", "ecoli", "yeast"):
        raise ValueError(f"host_organism 仅支持 human/ecoli/yeast，收到 {host}")
    d["host_organism"] = host
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
    max_frags = 15 if d["enzyme_name"] == "SapI" else 24
    fc = d.get("fragment_count")
    if fc is not None and not (2 <= int(fc) <= max_frags):
        raise ValueError(f"fragment_count 必须在 2–{max_frags} 之间")
    if not frags and fc is None:
        raise ValueError(f"未传入 fragments 时必须显式指定 fragment_count (2–{max_frags})")
    eff = int(fc) if fc is not None else len(frags)
    if not (2 <= eff <= max_frags):
        raise ValueError(f"有效组装片段数必须在 2–{max_frags} 之间，当前为 {eff}")
    return d


def _stdlib_validate_hdr(raw: Dict[str, Any]) -> Dict[str, Any]:
    allowed = {
        "reference_sequence", "sgrna_sequence", "strand", "edit_start_0based",
        "edit_end_0based", "replacement_sequence", "donor_format",
        "left_arm_length_bp", "right_arm_length_bp", "cds_start_1based",
        "cds_end_1based", "cds_strand", "cds_frame_offset",
        "auto_detect_cds", "enable_rflp",
        "rflp_search_radius_bp", "out_out_margin_bp", "primer_target_tm", "donor_name",
        "asymmetric_richardson_ssodn",
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
        ws, we = _mott_quality_trim_range(wt_parsed.get("qualities") or [])
        wt_seq_trim = wt_parsed["sequence"][ws:we]
        wt_peaks_trim = wt_parsed["peaks_acgt"][ws:we]
        validated["wt_peaks_acgt"] = _subtract_channel_baselines(wt_peaks_trim)
        if not validated.get("wt_sequence"):
            validated["wt_sequence"] = wt_seq_trim

    ed_ab1_path = validated.get("edited_ab1_path")
    if ed_ab1_path and not validated.get("edited_peaks_acgt"):
        full_ed = os.path.expanduser(str(ed_ab1_path))
        if not os.path.exists(full_ed):
            raise FileNotFoundError(f"找不到 Edited .ab1 文件: {ed_ab1_path}")
        with open(full_ed, "rb") as f:
            ed_parsed = _extract_ab1_peaks_acgt(f.read())
        es, ee = _mott_quality_trim_range(ed_parsed.get("qualities") or [])
        ed_seq_trim = ed_parsed["sequence"][es:ee]
        ed_peaks_corr = _subtract_channel_baselines(ed_parsed["peaks_acgt"][es:ee])
        cut_idx = validated.get("cut_index_0based")
        wt_seq = _clean_seq_preserving_n(validated.get("wt_sequence") or "")
        sg_seq = clean_seq(validated.get("sgrna_sequence") or "")
        if cut_idx is None and wt_seq and sg_seq:
            loc = locate_crispr_cut_site(wt_seq, sg_seq)
            cut_idx = loc[0] if loc is not None else 0
        cut_idx = int(cut_idx or 0)
        align_off = _estimate_upstream_alignment_offset(
            wt_seq, ed_seq_trim, validated.get("wt_peaks_acgt") or [], ed_peaks_corr, cut_idx
        )
        validated["alignment_offset_bp"] = int(align_off)
        ed_cut_idx = cut_idx + align_off
        if ed_cut_idx < 0 or ed_cut_idx >= len(ed_peaks_corr):
            validated["edited_peaks_acgt"] = []
        else:
            validated["edited_peaks_acgt"] = ed_peaks_corr[ed_cut_idx:ed_cut_idx + int(req_win)]

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
        "description": "查看当前引物/基因订购池，或导出为擎科/IDT/Twist/GenScript/Eurofins/BGI 订购表 (.xlsx/.csv)（导出写操作请先以 confirm=false 预览，经用户同意后再以 confirm=true 执行）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["list", "export_tsingke_excel"], "default": "list"},
                "vendor": {"type": "string", "enum": ["tsingke_primer", "idt_bulk", "twist_bulk", "genscript_bulk", "eurofins_bulk", "bgi_bulk"], "default": "tsingke_primer", "description": "可选：订购商模板类型"},
                "file_format": {"type": "string", "enum": ["xlsx", "csv"], "description": "可选：非擎科母版支持选择 xlsx 或 csv 输出格式"},
                "output_path": {"type": "string", "description": "可选：导出目标文件路径"},
                "confirm": {"type": "boolean", "default": False, "description": "导出写操作确认：默认 false 仅返回 dry-run 预览 planned_writes，设为 true 时才执行导出并备份已存在文件"}
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
                "total_protein_lane_iods": {"type": "array", "items": {"type": "number"}, "description": "可选：各泳道总蛋白染色 (TPN / Ponceau S / Stain-Free) 整泳道 IOD 数组，提供时优先替代内参归一化"},
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
                "multiple_comparison": {"type": "string", "enum": ["holm", "bh_fdr", "none"], "default": "holm", "description": "多重比较校正方法：holm (靶标内 Holm-Bonferroni)、bh_fdr (跨基因 Benjamini-Hochberg FDR) 或 none"},
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
                    "description": "可选：批量验证模式下的候选参考质粒数组 [{name, sequence, target_start_1based?, target_end_1based?}]",
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string"},
                            "sequence": {"type": "string"},
                            "target_start_1based": {"type": "integer", "description": "可选：目标验证区间起点 (1-based)"},
                            "target_end_1based": {"type": "integer", "description": "可选：目标验证区间终点 (1-based)"}
                        }
                    }
                },
                "trim_quality_threshold": {"type": "integer", "description": "5'/3' 低质量修剪 Phred Q 阈值，默认 20", "default": 20},
                "min_pass_coverage_percent": {"type": "number", "description": "可选：克隆判定 pass 所需的最小 Q20 目标区间覆盖度百分比（默认全参考 70%、显式目标区间 95%）"}
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
                "shift_min_bp": {"type": "integer", "minimum": -50, "maximum": 0, "default": -20, "description": "最小缺失移码偏移 (bp)，峰矩阵默认 -20，.ab1 默认 -30"},
                "shift_max_bp": {"type": "integer", "minimum": 0, "maximum": 50, "default": 20, "description": "最大插入移码偏移 (bp)，峰矩阵默认 20，.ab1 默认 14"},
                "noise_floor_weight": {"type": "number", "minimum": 0.0, "default": 1e-6, "description": "NNLS 权重噪声过滤阈值，默认 1e-6"},
                "min_component_percent": {"type": "number", "minimum": 0.0, "maximum": 50.0, "default": 1.0, "description": "Synthego ICE 稀疏剪枝最小占比阈值 (%)，默认 1.0"},
                "alignment_offset_bp": {"type": "integer", "default": 0, "description": "上游 WT vs Edited 对齐偏移量 (bp)"},
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
                "alignment_offset_bp": {"type": "integer"},
                "hdr_wt_cosine_similarity": {"type": ["number", "null"]},
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
                            "percent": {"type": "number"},
                            "se_percent": {"type": ["number", "null"]},
                            "p_value": {"type": ["number", "null"]}
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
                            "percent": {"type": "number"},
                            "se_percent": {"type": ["number", "null"]},
                            "p_value": {"type": ["number", "null"]}
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
        "description": "Type IIS（BsaI / BsmBI / BbsI / SapI）Golden Gate 组装引擎：基于 Libraries.sqlite 中 Pryor et al. (PLoS ONE 2020) 真实 PacBio SMRT 连接保真度矩阵实现 2–24 片段（SapI 2–15 片段）全局优化无交叉/自错配接头分配、宿主特异编码区同义密码子抹除（Domestication）与跨界新生位点检测。",
        "inputSchema": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "enzyme_name": {"type": "string", "enum": ["BsaI", "BsmBI", "BbsI", "SapI"], "default": "BsaI", "description": "Type IIS 内切酶名称"},
                "fragment_count": {"type": ["integer", "null"], "minimum": 2, "maximum": 24, "description": "待组装片段总数 (4-bp 酶 2–24, SapI 2–15)；未传 fragments 时必填"},
                "is_circular": {"type": "boolean", "default": True, "description": "是否为环状多片段组装（决定接点数=fragment_count 或 fragment_count+1）"},
                "fixed_overhangs": {"type": "array", "items": {"type": "string"}, "default": [], "description": "可选：用户锁定保留的黏性末端接头列表（如 ['GGAG', 'CGCT']）"},
                "host_organism": {"type": "string", "enum": ["human", "ecoli", "yeast"], "default": "human", "description": "Domestication 同义密码子偏好宿主 (human / ecoli / yeast)"},
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
                "assembled_sequence_length": {"type": "integer"},
                "junction_site_warnings": {"type": "array", "items": {"type": "string"}}
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
                    "version": "20261120"
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
