#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
SnapGene .dna Bridge for CloneStudio
Supports:
1. Parse .dna binary files (sequence, topology, features, primers)
2. Safe in-place primer injection with automatic timestamped backup
3. Recombinant plasmid assembly from vector .dna + insert source (.dna or sequence)
4. Plasmid fragment deletion / loop-out knockout .dna generation
"""

import sys
import os
import re
import math
import json
import struct
import datetime
import shutil
import xml.etree.ElementTree as ET

# SnapGene TLV Block Types
BLOCK_DNA = 0x00
BLOCK_COMPRESSED_DNA = 0x01
BLOCK_PRIMERS = 0x05
BLOCK_NOTES = 0x06
BLOCK_HISTORY_TREE = 0x07
BLOCK_HEADER = 0x09
BLOCK_FEATURES = 0x0a
BLOCK_SEGMENT_PROPS = 0x0e

# Standard 14-byte SnapGene DNA file header:
# "SnapGene" (8B) + isDNA=1 (2B) + exportVersion=14 (2B) + importVersion=14 (2B)
DEFAULT_SNAPGENE_HEADER = struct.pack(">8sHHH", b"SnapGene", 1, 14, 14)

COMP_TRANS = str.maketrans("ACGTURYKMSWBDHVNacgturykmswbdhvn", "TGCAYRMKSWVHDHBNtgcayrmkswvhdhbn")

def rev_comp(seq: str) -> str:
    return seq.translate(COMP_TRANS)[::-1]

def read_tlv_blocks(file_path: str):
    with open(file_path, "rb") as f:
        data = f.read()
    
    pos = 0
    blocks = []
    while pos < len(data):
        if pos + 5 > len(data):
            break
        btype = data[pos]
        length = struct.unpack(">I", data[pos+1:pos+5])[0]
        payload = data[pos+5:pos+5+length]
        blocks.append((btype, payload))
        pos += 5 + length
    return blocks

def write_tlv_blocks(file_path: str, blocks):
    temp_path = file_path + ".tmp"
    with open(temp_path, "wb") as f:
        for btype, payload in blocks:
            f.write(bytes([btype]))
            f.write(struct.pack(">I", len(payload)))
            f.write(payload)
    shutil.move(temp_path, file_path)

def extract_valid_header(blocks) -> bytes:
    for btype, payload in blocks:
        if btype == BLOCK_HEADER and len(payload) == 14 and payload[:8] == b"SnapGene":
            is_dna = struct.unpack(">H", payload[8:10])[0]
            exp_ver = struct.unpack(">H", payload[10:12])[0]
            imp_ver = struct.unpack(">H", payload[12:14])[0]
            if is_dna == 1 and exp_ver > 0 and imp_ver > 0:
                return payload
    return DEFAULT_SNAPGENE_HEADER

def extract_dna_sequence(blocks):
    for btype, payload in blocks:
        if btype == BLOCK_DNA and len(payload) >= 1:
            props = payload[0]
            is_circular = bool(props & 0x01)
            seq = payload[1:].decode("ascii", errors="replace").upper()
            seq = re.sub(r"[^A-Z]", "", seq)
            if props == 0:
                props = 0x03 if is_circular else 0x02
            return seq, is_circular, props
    return "", True, 0x03

def extract_features(blocks):
    features = []
    for btype, payload in blocks:
        if btype == BLOCK_FEATURES:
            try:
                root = ET.fromstring(payload.decode("utf-8", errors="replace"))
                for feat in root.findall("Feature"):
                    name = feat.attrib.get("name", "Unnamed")
                    ftype = feat.attrib.get("type", "misc_feature")
                    direction = feat.attrib.get("directionality", "0")
                    if direction not in ("0", "1", "2"):
                        direction = "0"
                    segments = []
                    for seg in feat.findall("Segment"):
                        rng = seg.attrib.get("range", "")
                        color = seg.attrib.get("color", "#99ccff")
                        stype = seg.attrib.get("type", "standard")
                        if "-" in rng:
                            parts = rng.split("-")
                            try:
                                s, e = int(parts[0]), int(parts[1])
                                segments.append({
                                    "range": rng,
                                    "start": s,
                                    "end": e,
                                    "color": color,
                                    "type": stype
                                })
                            except ValueError:
                                pass
                    qualifiers = []
                    for q in feat.findall("Q"):
                        qualifiers.append(ET.tostring(q, encoding="unicode"))
                    features.append({
                        "name": name,
                        "type": ftype,
                        "directionality": direction,
                        "segments": segments,
                        "qualifiers": qualifiers
                    })
            except Exception:
                pass
    return features

def _parse_range_str(rng: str):
    if not rng or "-" not in rng:
        return None, None
    parts = rng.split("-")
    try:
        return int(parts[0]), int(parts[1])
    except ValueError:
        return None, None

NN_PARAMS = {
    "AA": (-7.6, -21.3), "TT": (-7.6, -21.3),
    "AT": (-7.2, -20.4), "TA": (-7.2, -21.3),
    "CA": (-8.5, -22.7), "TG": (-8.5, -22.7),
    "GT": (-8.4, -22.4), "AC": (-8.4, -22.4),
    "CT": (-7.8, -21.0), "AG": (-7.8, -21.0),
    "GA": (-8.2, -22.2), "TC": (-8.2, -22.2),
    "CG": (-10.6, -27.2), "GC": (-9.8, -24.4),
    "GG": (-8.0, -19.9), "CC": (-8.0, -19.9),
    # Watkins & SantaLucia (2005) Deoxyinosine (I) parameters
    "AI": (-8.3, -25.0), "IA": (-4.9, -15.8),
    "CI": (-5.4, -13.7), "IC": (-5.0, -12.6),
    "GI": (-6.8, -19.1), "IG": (-7.6, -22.0),
    "TI": (-3.4, -11.2), "IT": (-6.5, -22.0),
    "II": (-3.3, -11.9)
}

# Bommarito, Peyret & SantaLucia (2000) Table 2 — 5' Dangling End parameters (key = "XY": 5'-dangle X adjacent to 5'-paired Y)
FIVE_PRIME_DANGLE_PARAMS = {
    "AA": (0.2, 2.3),    "AC": (-6.3, -17.1), "AG": (-3.7, -10.0), "AT": (-2.9, -7.6),
    "CA": (0.6, 3.3),    "CC": (-4.4, -12.6), "CG": (-4.0, -11.9), "CT": (-4.1, -13.0),
    "GA": (-1.1, -1.6),  "GC": (-5.1, -14.0), "GG": (-3.9, -10.9), "GT": (-4.2, -15.0),
    "TA": (-6.9, -20.0), "TC": (-4.0, -10.9), "TG": (-4.9, -13.8), "TT": (-0.2, -0.5)
}

# Bommarito, Peyret & SantaLucia (2000) Table 2 — 3' Dangling End parameters (key = "YX": 3'-paired Y adjacent to 3'-dangle X)
THREE_PRIME_DANGLE_PARAMS = {
    "AA": (-0.5, -1.1),  "AC": (4.7, 14.2),   "AG": (-4.1, -13.1), "AT": (-3.8, -12.6),
    "CA": (-5.9, -16.5), "CC": (-2.6, -7.4),  "CG": (-3.2, -10.4), "CT": (-5.2, -15.0),
    "GA": (-2.1, -3.9),  "GC": (-0.2, -0.1),  "GG": (-3.9, -11.2), "GT": (-4.4, -13.1),
    "TA": (-0.7, -0.8),  "TC": (4.4, 14.9),   "TG": (-1.6, -3.6),  "TT": (2.9, 10.4)
}

# Allawi & SantaLucia (1997-1998) / Peyret et al. (1999) Internal Mismatch parameters
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

IUPAC_EXPANSION = {
    "A": ["A"], "T": ["T"], "U": ["T"], "C": ["C"], "G": ["G"], "I": ["I"],
    "R": ["A", "G"], "Y": ["C", "T"], "S": ["G", "C"], "W": ["A", "T"],
    "K": ["G", "T"], "M": ["A", "C"],
    "B": ["C", "G", "T"], "D": ["A", "G", "T"], "H": ["A", "C", "T"], "V": ["A", "C", "G"],
    "N": ["A", "T", "C", "G"]
}

def _normalize_oligo(seq: str) -> str:
    out = []
    for ch in seq.upper():
        if ch == "U":
            out.append("T")
        elif ch in IUPAC_EXPANSION:
            out.append(ch)
    return "".join(out)

def _lookup_dinuc(b1: str, b2: str):
    exp1 = IUPAC_EXPANSION.get(b1, ["A"])
    exp2 = IUPAC_EXPANSION.get(b2, ["A"])
    sum_dh = 0.0
    sum_ds = 0.0
    cnt = 0
    for c1 in exp1:
        for c2 in exp2:
            dh, ds = NN_PARAMS.get(c1 + c2, (-8.0, -22.0))
            sum_dh += dh
            sum_ds += ds
            cnt += 1
    return (sum_dh / cnt, sum_ds / cnt) if cnt else (-8.0, -22.0)

def _lookup_5prime_dangle(dangle_base: str, first_paired: str):
    exp_d = IUPAC_EXPANSION.get(dangle_base, ["A"])
    exp_p = IUPAC_EXPANSION.get(first_paired, ["A"])
    sum_dh = 0.0
    sum_ds = 0.0
    cnt = 0
    for d in exp_d:
        for p in exp_p:
            if (d + p) in FIVE_PRIME_DANGLE_PARAMS:
                dh, ds = FIVE_PRIME_DANGLE_PARAMS[d + p]
                sum_dh += dh
                sum_ds += ds
                cnt += 1
    return (sum_dh / cnt, sum_ds / cnt) if cnt else (0.0, 0.0)

def _lookup_3prime_dangle(last_paired: str, dangle_base: str):
    exp_p = IUPAC_EXPANSION.get(last_paired, ["A"])
    exp_d = IUPAC_EXPANSION.get(dangle_base, ["A"])
    sum_dh = 0.0
    sum_ds = 0.0
    cnt = 0
    for p in exp_p:
        for d in exp_d:
            if (p + d) in THREE_PRIME_DANGLE_PARAMS:
                dh, ds = THREE_PRIME_DANGLE_PARAMS[p + d]
                sum_dh += dh
                sum_ds += ds
                cnt += 1
    return (sum_dh / cnt, sum_ds / cnt) if cnt else (0.0, 0.0)

def _terminal_at_contrib(base: str):
    expanded = IUPAC_EXPANSION.get(base, ["A"])
    sum_dh = 0.0
    sum_ds = 0.0
    for b in expanded:
        if b in ("A", "T", "I"):
            sum_dh += 2.2
            sum_ds += 6.9
    n = max(1, len(expanded))
    return sum_dh / n, sum_ds / n

def _is_self_complementary(s: str) -> bool:
    if len(s) % 2 != 0:
        return False
    comp = {"A": "T", "T": "A", "C": "G", "G": "C"}
    for i in range(len(s) // 2):
        l = s[i]
        r = s[len(s) - 1 - i]
        if l not in comp or comp[l] != r:
            return False
    return True

def approx_tm(seq: str, five_prime_overhang: str = "", three_prime_overhang: str = "", template_sense_seq: str = "") -> int:
    """
    100% SnapGene-aligned Nearest-Neighbor thermodynamic model:
    - SantaLucia & Hicks (2004) Annu Rev Biophys Biomol Struct 33:415-40
    - Bommarito, Peyret & SantaLucia (2000) Nucleic Acids Res 28:1929-34 (5'/3' dangling ends)
    - Allawi & SantaLucia (1997-1998) / Peyret et al. (1999) (internal mismatches)
    - Watkins & SantaLucia (2005) (deoxyinosine 'I', 'U' as 'T', degenerate base averaging)
    - [Na+] = 50 mM (0.05 M), [primer] = 250 nM (0.25 uM)
    """
    s = _normalize_oligo(seq)
    n = len(s)
    if n < 2:
        return 0
    ovh5 = _normalize_oligo(five_prime_overhang)
    ovh3 = _normalize_oligo(three_prime_overhang)
    t_sense = _normalize_oligo(template_sense_seq)

    total_dh = 0.2
    total_ds = -5.7

    for end_base in (s[0], s[-1]):
        at_dh, at_ds = _terminal_at_contrib(end_base)
        total_dh += at_dh
        total_ds += at_ds

    is_self_comp = (not ovh5) and (not ovh3) and (not t_sense) and _is_self_complementary(s)
    if is_self_comp:
        total_ds += -1.4

    if t_sense and len(t_sense) == n:
        comp_map = {"A": "T", "T": "A", "C": "G", "G": "C"}
        for i in range(n - 1):
            p1, p2 = s[i], s[i + 1]
            t1, t2 = t_sense[i], t_sense[i + 1]
            if p1 == t1 and p2 == t2:
                dh, ds = _lookup_dinuc(p1, p2)
                total_dh += dh
                total_ds += ds
            else:
                c1 = comp_map.get(t1, t1)
                c2 = comp_map.get(t2, t2)
                key = f"{p1}{p2}/{c1}{c2}"
                rev_key = f"{c2}{c1}/{p2}{p1}"
                imm = INTERNAL_MISMATCH_PARAMS.get(key) or INTERNAL_MISMATCH_PARAMS.get(rev_key)
                if imm:
                    total_dh += imm[0]
                    total_ds += imm[1]
                else:
                    dh, ds = _lookup_dinuc(p1, p2)
                    total_dh += dh + 3.5
                    total_ds += ds + 8.5
    else:
        for i in range(n - 1):
            dh, ds = _lookup_dinuc(s[i], s[i + 1])
            total_dh += dh
            total_ds += ds

    if ovh5:
        dh5, ds5 = _lookup_5prime_dangle(ovh5[-1], s[0])
        total_dh += dh5
        total_ds += ds5

    if ovh3:
        dh3, ds3 = _lookup_3prime_dangle(s[-1], ovh3[0])
        total_dh += dh3
        total_ds += ds3

    total_ds += 0.368 * (n - 1) * math.log(0.05)
    tm_c = (1000.0 * total_dh) / (total_ds + 1.9872 * math.log(250e-9)) - 273.15
    return int(round(tm_c))

def _split_primer_case_overhang(primer_clean: str, explicit_overhang: str = "", explicit_specific: str = ""):
    """
    Splits a primer into (5' overhang tail, 3' specific annealing region).
    1. If explicit_overhang and explicit_specific are provided, uses them directly.
    2. Otherwise, if the primer starts with lowercase bases (5' homology arm) followed by
       uppercase bases (3' specific sequence, >= 12 bp) or vice-versa, splits at the case boundary
       so SnapGene only counts the 3' specific region as annealedBases (avoiding ~70C full-length inflation).
    """
    if explicit_overhang and explicit_specific and len(explicit_overhang) + len(explicit_specific) == len(primer_clean):
        return explicit_overhang, explicit_specific
    m_low_up = re.match(r"^([a-z]{6,35})([A-Z]{12,})$", primer_clean)
    if m_low_up:
        return m_low_up.group(1), m_low_up.group(2)
    m_up_low = re.match(r"^([A-Z]{6,35})([a-z]{12,})$", primer_clean)
    if m_up_low:
        return m_up_low.group(1), m_up_low.group(2)
    return "", primer_clean

def find_binding_site(
    dna_seq: str,
    is_circular: bool,
    primer_seq: str,
    explicit_overhang: str = "",
    explicit_specific: str = "",
    explicit_tm: str = ""
):
    """
    Identifies binding location in SnapGene's 0-based inclusive <Primers> XML format,
    preserving the 5' homology arm as an unhybridized overhang Component so that
    SnapGene displays the true 3' PCR annealing Tm (~60C) rather than the ~70C full-length Tm.
    """
    primer_clean = re.sub(r"[^A-Za-z]", "", primer_seq)
    primer_upper = primer_clean.upper()
    dna_len = len(dna_seq)
    if dna_len == 0 or len(primer_upper) == 0:
        return None
    
    search_dna = (dna_seq + dna_seq) if is_circular else dna_seq
    search_len = len(search_dna)
    
    ovh_prefix, spec_part = _split_primer_case_overhang(primer_clean, explicit_overhang, explicit_specific)
    
    # 0. Explicit 5' Homology Arm + 3' Specific Annealing Region (prevents 70C full-length inflation on recombinant plasmid)
    if ovh_prefix and len(spec_part) >= 12:
        spec_upper = spec_part.upper()
        # Prefer the site where the full primer (or specific part) matches
        idx_full = search_dna.find(primer_upper)
        if idx_full != -1 and (idx_full < dna_len or is_circular):
            spec_idx = (idx_full + len(ovh_prefix)) % dna_len
        else:
            idx_spec = search_dna.find(spec_upper)
            spec_idx = (idx_spec % dna_len) if (idx_spec != -1 and (idx_spec < dna_len or is_circular)) else -1
            
        if spec_idx != -1 and (spec_idx + len(spec_part) <= dna_len):
            s0 = spec_idx
            e0 = spec_idx + len(spec_part) - 1
            loc0 = f"{s0}-{e0}"
            tm_val = int(explicit_tm) if (explicit_tm and str(explicit_tm).isdigit()) else approx_tm(spec_upper, five_prime_overhang=ovh_prefix)
            return {
                "boundStrand": "0",
                "location": loc0,
                "start1Based": s0 + 1,
                "end1Based": e0 + 1,
                "annealedBases": spec_part,
                "meltingTemperature": str(tm_val),
                "components": [
                    {"bases": ovh_prefix},
                    {"hybridizedRange": loc0, "bases": spec_part}
                ]
            }
            
        rc_full = rev_comp(primer_upper)
        idx_rc_full = search_dna.find(rc_full)
        rc_spec = rev_comp(spec_upper)
        if idx_rc_full != -1 and (idx_rc_full < dna_len or is_circular):
            spec_rc_idx = idx_rc_full % dna_len
        else:
            idx_rc_spec = search_dna.find(rc_spec)
            spec_rc_idx = (idx_rc_spec % dna_len) if (idx_rc_spec != -1 and (idx_rc_spec < dna_len or is_circular)) else -1
            
        if spec_rc_idx != -1 and (spec_rc_idx + len(spec_part) <= dna_len):
            s0 = spec_rc_idx
            e0 = spec_rc_idx + len(spec_part) - 1
            loc0 = f"{s0}-{e0}"
            tm_val = int(explicit_tm) if (explicit_tm and str(explicit_tm).isdigit()) else approx_tm(spec_upper, five_prime_overhang=ovh_prefix)
            return {
                "boundStrand": "1",
                "location": loc0,
                "start1Based": s0 + 1,
                "end1Based": e0 + 1,
                "annealedBases": spec_part,
                "meltingTemperature": str(tm_val),
                "components": [
                    {"bases": ovh_prefix},
                    {"hybridizedRange": loc0, "bases": spec_part}
                ]
            }
    
    # 1. Forward Strand Exact Match (0-based inclusive location for SnapGene <Primers> XML)
    idx = search_dna.find(primer_upper)
    if idx != -1 and (idx < dna_len or is_circular):
        s0 = idx % dna_len
        e0 = (idx + len(primer_upper) - 1) % dna_len
        tm = int(explicit_tm) if (explicit_tm and str(explicit_tm).isdigit()) else approx_tm(primer_upper)
        loc0 = f"{s0}-{e0}"
        return {
            "boundStrand": "0",
            "location": loc0,
            "start1Based": s0 + 1,
            "end1Based": e0 + 1,
            "annealedBases": primer_clean,
            "meltingTemperature": str(tm),
            "components": [
                {"hybridizedRange": loc0, "bases": primer_clean}
            ]
        }
        
    # 2. Reverse Strand Exact Match (0-based inclusive location)
    rc_primer = rev_comp(primer_upper)
    idx_rc = search_dna.find(rc_primer)
    if idx_rc != -1 and (idx_rc < dna_len or is_circular):
        s0 = idx_rc % dna_len
        e0 = (idx_rc + len(rc_primer) - 1) % dna_len
        tm = int(explicit_tm) if (explicit_tm and str(explicit_tm).isdigit()) else approx_tm(primer_upper)
        loc0 = f"{s0}-{e0}"
        return {
            "boundStrand": "1",
            "location": loc0,
            "start1Based": s0 + 1,
            "end1Based": e0 + 1,
            "annealedBases": primer_clean,
            "meltingTemperature": str(tm),
            "components": [
                {"hybridizedRange": loc0, "bases": primer_clean}
            ]
        }
        
    # 3. 5' Overhang (Homology Arm / Adapter Tail)
    for anneal_len in range(len(primer_upper), 11, -1):
        anneal_seq = primer_upper[-anneal_len:]
        overhang_seq = primer_clean[:-anneal_len]
        
        idx = search_dna.find(anneal_seq)
        if idx != -1 and (idx < dna_len or is_circular):
            s0 = idx % dna_len
            e0 = (idx + anneal_len - 1) % dna_len
            loc0 = f"{s0}-{e0}"
            tm = approx_tm(anneal_seq, five_prime_overhang=overhang_seq)
            comps = []
            if overhang_seq:
                comps.append({"bases": overhang_seq})
            comps.append({"hybridizedRange": loc0, "bases": primer_clean[-anneal_len:]})
            return {
                "boundStrand": "0",
                "location": loc0,
                "start1Based": s0 + 1,
                "end1Based": e0 + 1,
                "annealedBases": primer_clean[-anneal_len:],
                "meltingTemperature": str(tm),
                "components": comps
            }
            
        rc_anneal = rev_comp(anneal_seq)
        idx_rc = search_dna.find(rc_anneal)
        if idx_rc != -1 and (idx_rc < dna_len or is_circular):
            s0 = idx_rc % dna_len
            e0 = (idx_rc + anneal_len - 1) % dna_len
            loc0 = f"{s0}-{e0}"
            tm = approx_tm(anneal_seq, five_prime_overhang=overhang_seq)
            comps = []
            if overhang_seq:
                comps.append({"bases": overhang_seq})
            comps.append({"hybridizedRange": loc0, "bases": primer_clean[-anneal_len:]})
            return {
                "boundStrand": "1",
                "location": loc0,
                "start1Based": s0 + 1,
                "end1Based": e0 + 1,
                "annealedBases": primer_clean[-anneal_len:],
                "meltingTemperature": str(tm),
                "components": comps
            }
            
    # 4. Point Mutation Mismatch Detection (Center mutation, 0-based inclusive location)
    for flank in range(min(len(primer_upper) // 2 - 1, 20), 7, -1):
        left_flank = primer_upper[:flank]
        right_flank = primer_upper[-flank:]
        
        idx_l = search_dna.find(left_flank)
        if idx_l != -1:
            expected_r_idx = idx_l + len(primer_upper) - flank
            if expected_r_idx + flank <= search_len:
                if search_dna[expected_r_idx:expected_r_idx+flank] == right_flank:
                    mid_primer_bases = primer_clean[flank:-flank]
                    s0 = idx_l % dna_len
                    e0 = (expected_r_idx + flank - 1) % dna_len
                    loc0 = f"{s0}-{e0}"
                    template_seg = search_dna[idx_l:idx_l + len(primer_upper)]
                    tm = approx_tm(primer_upper, template_sense_seq=template_seg)
                    comps = [
                        {"hybridizedRange": f"{s0}-{(idx_l+flank-1)%dna_len}", "bases": primer_clean[:flank]}
                    ]
                    if mid_primer_bases:
                        comps.append({"bases": mid_primer_bases})
                    comps.append({"hybridizedRange": f"{expected_r_idx%dna_len}-{e0}", "bases": primer_clean[-flank:]})
                    return {
                        "boundStrand": "0",
                        "location": loc0,
                        "start1Based": s0 + 1,
                        "end1Based": e0 + 1,
                        "annealedBases": primer_clean,
                        "meltingTemperature": str(tm),
                        "components": comps
                    }
                    
        rc_right = rev_comp(right_flank)
        rc_left = rev_comp(left_flank)
        idx_r_rc = search_dna.find(rc_right)
        if idx_r_rc != -1:
            expected_l_rc = idx_r_rc + len(primer_upper) - flank
            if expected_l_rc + flank <= search_len:
                if search_dna[expected_l_rc:expected_l_rc+flank] == rc_left:
                    s0 = idx_r_rc % dna_len
                    e0 = (expected_l_rc + flank - 1) % dna_len
                    loc0 = f"{s0}-{e0}"
                    template_seg = rev_comp(search_dna[idx_r_rc:idx_r_rc + len(primer_upper)])
                    tm = approx_tm(primer_upper, template_sense_seq=template_seg)
                    mid_primer_bases = primer_clean[flank:-flank]
                    comps = [
                        {"hybridizedRange": f"{expected_l_rc%dna_len}-{e0}", "bases": primer_clean[:flank]}
                    ]
                    if mid_primer_bases:
                        comps.append({"bases": mid_primer_bases})
                    comps.append({"hybridizedRange": f"{s0}-{(idx_r_rc+flank-1)%dna_len}", "bases": primer_clean[-flank:]})
                    return {
                        "boundStrand": "1",
                        "location": loc0,
                        "start1Based": s0 + 1,
                        "end1Based": e0 + 1,
                        "annealedBases": primer_clean,
                        "meltingTemperature": str(tm),
                        "components": comps
                    }
                    
    return None

def is_binding_site_strictly_valid(bs_info, dna_len: int) -> bool:
    """
    Validates that a BindingSite and all its Components strictly conform to SnapGene's
    non-wrapping 0-based inclusive range rules (0 <= s <= e < dna_len).
    """
    if not bs_info or dna_len <= 0:
        return False
    loc = bs_info.get("location", "")
    s, e = _parse_range_str(loc)
    if s is None or e is None or not (0 <= s <= e < dna_len):
        return False
    comps = bs_info.get("components", [])
    if not comps:
        return False
    for c in comps:
        bases = c.get("bases", "")
        if not bases:
            return False
        if "hybridizedRange" in c:
            cs, ce = _parse_range_str(c["hybridizedRange"])
            if cs is None or ce is None or not (0 <= cs <= ce < dna_len):
                return False
            if (ce - cs + 1) != len(bases):
                return False
    return True

def extract_primers(blocks, dna_seq: str = "", is_circular: bool = True):
    primers = []
    for btype, payload in blocks:
        if btype == BLOCK_PRIMERS:
            try:
                root = ET.fromstring(payload.decode("utf-8", errors="replace"))
                for idx, p in enumerate(root.findall("Primer")):
                    name = p.attrib.get("name", f"Primer-{idx+1}")
                    seq = p.attrib.get("sequence", "")
                    recent_id = p.attrib.get("recentID", str(idx))
                    if not recent_id:
                        recent_id = f"{name}_{idx}"
                    sites = []
                    seen_keys = set()
                    for bs in p.findall("BindingSite"):
                        loc = bs.attrib.get("location", "")
                        raw_strand = (bs.attrib.get("boundStrand") or bs.attrib.get("strand") or "0").strip().lower()
                        strand = "1" if raw_strand in {"1", "-", "-1", "reverse", "rev", "true"} else "0"
                        hyb_loc = loc
                        for comp in bs.findall("Component"):
                            if "hybridizedRange" in comp.attrib:
                                hyb_loc = comp.attrib["hybridizedRange"]
                                break
                        key = (hyb_loc or loc, strand)
                        if key in seen_keys:
                            continue
                        seen_keys.add(key)
                        s0, e0 = _parse_range_str(hyb_loc or loc)
                        if s0 is None or e0 is None:
                            s0, e0 = _parse_range_str(loc)
                        # Convert 0-based inclusive XML coordinates to 1-based UI coordinates
                        s1 = (s0 + 1) if s0 is not None else None
                        e1 = (e0 + 1) if e0 is not None else None
                        loc1 = f"{s1}-{e1}" if (s1 is not None and e1 is not None) else (hyb_loc or loc)
                        sites.append({
                            "location": loc1,
                            "start": s1,
                            "end": e1,
                            "strand": strand,
                            "annealedBases": bs.attrib.get("annealedBases", ""),
                            "tm": bs.attrib.get("meltingTemperature", "60")
                        })
                    if not sites and dna_seq and seq:
                        bs_info = find_binding_site(dna_seq, is_circular, seq)
                        if bs_info:
                            s1 = bs_info.get("start1Based")
                            e1 = bs_info.get("end1Based")
                            sites.append({
                                "location": f"{s1}-{e1}" if (s1 and e1) else bs_info["location"],
                                "start": s1,
                                "end": e1,
                                "strand": bs_info["boundStrand"],
                                "annealedBases": bs_info["annealedBases"],
                                "tm": bs_info["meltingTemperature"]
                            })
                    primers.append({
                        "id": f"{recent_id}_{name}",
                        "name": name,
                        "sequence": seq,
                        "bindingSites": sites
                    })
            except Exception:
                pass
    return primers

def parse_dna(file_path: str):
    blocks = read_tlv_blocks(file_path)
    seq, is_circular, _ = extract_dna_sequence(blocks)
    feats = extract_features(blocks)
    prims = extract_primers(blocks, seq, is_circular)
    return {
        "filePath": file_path,
        "fileName": os.path.basename(file_path),
        "sequence": seq,
        "length": len(seq),
        "isCircular": is_circular,
        "featuresCount": len(feats),
        "features": feats,
        "primersCount": len(prims),
        "primers": prims
    }

def build_features_xml_bytes(features_list, max_seq_len: int) -> bytes:
    """
    Builds a strictly valid SnapGene <Features> XML block (Block 0x0a),
    filtering out any invalid or out-of-range segments so SnapGene never rejects the file.
    """
    valid_features = []
    for f in features_list:
        valid_segs = []
        for seg in f.get("segments", []):
            rng = seg.get("range", "")
            s, e = _parse_range_str(rng)
            if s is None or e is None:
                s = seg.get("start")
                e = seg.get("end")
            if s is None or e is None:
                continue
            s = max(1, min(int(s), max_seq_len))
            e = max(1, min(int(e), max_seq_len))
            if s > e:
                continue
            color = seg.get("color", "#99ccff")
            if not color or not color.startswith("#"):
                color = "#99ccff"
            stype = seg.get("type", "standard")
            valid_segs.append({
                "range": f"{s}-{e}",
                "color": color,
                "type": stype
            })
        if valid_segs:
            direction = str(f.get("directionality", "0"))
            if direction not in ("0", "1", "2"):
                direction = "0"
            valid_features.append({
                "name": str(f.get("name", "Feature")).strip() or "Feature",
                "type": str(f.get("type", "misc_feature")).strip() or "misc_feature",
                "directionality": direction,
                "segments": valid_segs,
                "qualifiers": f.get("qualifiers", [])
            })

    feat_root = ET.Element("Features", {"nextValidID": str(len(valid_features))})
    for idx, f in enumerate(valid_features):
        fe_el = ET.SubElement(feat_root, "Feature", {
            "recentID": str(idx),
            "name": f["name"],
            "type": f["type"],
            "directionality": f["directionality"],
            "allowSegmentOverlaps": "0",
            "consecutiveTranslationNumbering": "1"
        })
        for seg in f["segments"]:
            ET.SubElement(fe_el, "Segment", {
                "range": seg["range"],
                "color": seg["color"],
                "type": seg["type"]
            })
        for q_xml in f.get("qualifiers", []):
            try:
                q_el = ET.fromstring(q_xml)
                fe_el.append(q_el)
            except Exception:
                pass

    return b'<?xml version="1.0"?>' + ET.tostring(feat_root, encoding="utf-8")

def inject_primers_to_dna(file_path: str, primers_data, backup: bool = True):
    if not os.path.isfile(file_path):
        raise FileNotFoundError(f"File not found: {file_path}")
        
    backup_path = None
    if backup:
        ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        dir_name = os.path.dirname(file_path)
        base_name = os.path.basename(file_path)
        name_no_ext, ext = os.path.splitext(base_name)
        backup_path = os.path.join(dir_name, f"{name_no_ext}.bak_{ts}{ext}")
        shutil.copy2(file_path, backup_path)
        
    blocks = read_tlv_blocks(file_path)
    dna_seq, is_circular, _ = extract_dna_sequence(blocks)
    dna_len = len(dna_seq)
    
    primers_block_idx = None
    primers_xml = None
    for i, (btype, payload) in enumerate(blocks):
        if btype == BLOCK_PRIMERS:
            primers_block_idx = i
            primers_xml = payload
            break
            
    if primers_xml:
        try:
            root = ET.fromstring(primers_xml.decode("utf-8", errors="replace"))
        except Exception:
            root = ET.Element("Primers", {"nextValidID": "0"})
    else:
        root = ET.Element("Primers", {"nextValidID": "0"})

    if root.find("HybridizationParams") is None:
        hyb = ET.Element("HybridizationParams", {
            "minContinuousMatchLen": "15",
            "allowMismatch": "1",
            "minMeltingTemperature": "40",
            "showAdditionalFivePrimeMatches": "1",
            "minimumFivePrimeAnnealing": "15"
        })
        root.insert(0, hyb)
        
    try:
        next_id = int(root.attrib.get("nextValidID", "0"))
    except ValueError:
        next_id = len(root.findall("Primer"))
        
    now_iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    added_count = 0
    
    for item in primers_data:
        p_name = str(item.get("name") or f"Primer-{next_id}").strip()
        raw_seq = str(item.get("fullSequence") or item.get("sequence") or "").strip()
        p_seq = re.sub(r"[^A-Za-z]", "", raw_seq)
        if not p_seq:
            continue
        p_notes = str(item.get("notes") or item.get("description") or item.get("targetPurpose") or "").strip()
        hom_arm = re.sub(r"[^A-Za-z]", "", str(item.get("homologyArm") or "")).lower()
        enz_site = re.sub(r"[^A-Za-z]", "", str(item.get("enzymeSite") or "")).lower()
        spec_seq = re.sub(r"[^A-Za-z]", "", str(item.get("specificSequence") or "")).upper()
        explicit_ovh = hom_arm + enz_site
        explicit_tm = str(item.get("tm") or "")
        
        if explicit_ovh and spec_seq and len(explicit_ovh) + len(spec_seq) == len(p_seq):
            p_seq = explicit_ovh + spec_seq
        
        exists = False
        for existing in root.findall("Primer"):
            if existing.attrib.get("sequence", "").upper() == p_seq.upper() and existing.attrib.get("name", "") == p_name:
                exists = True
                break
        if exists:
            continue
            
        p_elem = ET.SubElement(root, "Primer", {
            "recentID": str(next_id),
            "name": p_name,
            "sequence": p_seq,
            "description": p_notes,
            "dateAdded": now_iso
        })
        next_id += 1
        added_count += 1
        
        bs_info = find_binding_site(
            dna_seq,
            is_circular,
            p_seq,
            explicit_overhang=explicit_ovh,
            explicit_specific=spec_seq,
            explicit_tm=explicit_tm
        )
        if is_binding_site_strictly_valid(bs_info, dna_len):
            orig_tm = item.get("originalTm")
            orig_annealed = item.get("originalAnnealedBases", "")
            resolved_tm = bs_info["meltingTemperature"]
            if orig_tm and orig_annealed and orig_annealed.upper() == bs_info["annealedBases"].upper():
                resolved_tm = str(orig_tm)
            bs_elem1 = ET.SubElement(p_elem, "BindingSite", {
                "location": bs_info["location"],
                "boundStrand": bs_info["boundStrand"],
                "annealedBases": bs_info["annealedBases"],
                "meltingTemperature": resolved_tm
            })
            for comp in bs_info["components"]:
                c_attrib = {"bases": comp["bases"]}
                if "hybridizedRange" in comp:
                    c_attrib["hybridizedRange"] = comp["hybridizedRange"]
                ET.SubElement(bs_elem1, "Component", c_attrib)
                
            bs_elem2 = ET.SubElement(p_elem, "BindingSite", {
                "simplified": "1",
                "location": bs_info["location"],
                "boundStrand": bs_info["boundStrand"],
                "annealedBases": bs_info["annealedBases"],
                "meltingTemperature": resolved_tm
            })
            for comp in bs_info["components"]:
                c_attrib = {"bases": comp["bases"]}
                if "hybridizedRange" in comp:
                    c_attrib["hybridizedRange"] = comp["hybridizedRange"]
                ET.SubElement(bs_elem2, "Component", c_attrib)
                
    root.attrib["nextValidID"] = str(next_id)
    new_primers_xml = b'<?xml version="1.0"?>' + ET.tostring(root, encoding="utf-8")
    
    if primers_block_idx is not None:
        blocks[primers_block_idx] = (BLOCK_PRIMERS, new_primers_xml)
    else:
        blocks.append((BLOCK_PRIMERS, new_primers_xml))
        
    write_tlv_blocks(file_path, blocks)
    return {
        "status": "success",
        "filePath": file_path,
        "backupPath": backup_path,
        "primersAdded": added_count,
        "totalPrimers": next_id
    }

def collect_clean_existing_primers(blocks) -> list:
    kept = []
    for btype, payload in blocks:
        if btype == BLOCK_PRIMERS:
            try:
                root = ET.fromstring(payload.decode("utf-8", errors="replace"))
                for p in root.findall("Primer"):
                    name = p.attrib.get("name", "")
                    seq = p.attrib.get("sequence", "")
                    desc = p.attrib.get("description", "")
                    orig_tm = None
                    orig_annealed = ""
                    orig_ovh = ""
                    bs = p.find("BindingSite")
                    if bs is not None:
                        orig_tm = bs.attrib.get("meltingTemperature")
                        orig_annealed = bs.attrib.get("annealedBases", "")
                        comps = bs.findall("Component")
                        if len(comps) == 2 and "hybridizedRange" not in comps[0].attrib and "hybridizedRange" in comps[1].attrib:
                            orig_ovh = comps[0].attrib.get("bases", "")
                    if name and seq:
                        kept.append({
                            "name": name,
                            "fullSequence": seq,
                            "homologyArm": orig_ovh,
                            "specificSequence": orig_annealed,
                            "notes": desc,
                            "originalTm": orig_tm,
                            "originalAnnealedBases": orig_annealed
                        })
            except Exception:
                pass
    return kept

def assemble_recombinant_dna(
    vector_path: str,
    insert_path_or_seq: str,
    insert_name: str,
    cut_start: int,
    cut_end: int,
    primers_data,
    output_path: str,
    donor_path: str = "none"
):
    """
    Assembles a 100% SnapGene-compatible recombinant plasmid .dna file:
    Preserves the valid 14-byte SnapGene DNA header, remaps vector & donor features,
    strips stale length-dependent binary history/segment blocks, and injects primers.
    """
    vec_blocks = read_tlv_blocks(vector_path)
    header_payload = extract_valid_header(vec_blocks)
    vec_seq, vec_circular, vec_props = extract_dna_sequence(vec_blocks)
    vec_len = len(vec_seq)
    if vec_len == 0:
        raise ValueError("Vector sequence cannot be empty")
    
    insert_seq = ""
    insert_features = []
    if os.path.isfile(insert_path_or_seq):
        ins_blocks = read_tlv_blocks(insert_path_or_seq)
        insert_seq, _, _ = extract_dna_sequence(ins_blocks)
        insert_features = extract_features(ins_blocks)
    else:
        insert_seq = re.sub(r'[^A-Za-z]', '', insert_path_or_seq).upper()
        if donor_path and donor_path != "none" and os.path.isfile(donor_path):
            donor_blocks = read_tlv_blocks(donor_path)
            donor_seq, _, _ = extract_dna_sequence(donor_blocks)
            all_donor_feats = extract_features(donor_blocks)
            ins_len_tmp = len(insert_seq)
            if donor_seq and ins_len_tmp > 0:
                idx_fwd = donor_seq.find(insert_seq)
                rc_ins = rev_comp(insert_seq)
                idx_rev = donor_seq.find(rc_ins) if idx_fwd == -1 else -1
                if idx_fwd != -1:
                    d_start = idx_fwd + 1
                    d_end = idx_fwd + ins_len_tmp
                    for df in all_donor_feats:
                        mapped_segs = []
                        for seg in df["segments"]:
                            s, e = seg["start"], seg["end"]
                            if s >= d_start and e <= d_end:
                                rel_s = s - d_start + 1
                                rel_e = e - d_start + 1
                                mapped_segs.append({
                                    "range": f"{rel_s}-{rel_e}",
                                    "start": rel_s,
                                    "end": rel_e,
                                    "color": seg.get("color", "#99ccff"),
                                    "type": seg.get("type", "standard")
                                })
                        if mapped_segs:
                            copy_f = dict(df)
                            copy_f["segments"] = mapped_segs
                            insert_features.append(copy_f)
                elif idx_rev != -1:
                    d_start = idx_rev + 1
                    d_end = idx_rev + ins_len_tmp
                    for df in all_donor_feats:
                        mapped_segs = []
                        for seg in df["segments"]:
                            s, e = seg["start"], seg["end"]
                            if s >= d_start and e <= d_end:
                                rel_s = d_end - e + 1
                                rel_e = d_end - s + 1
                                mapped_segs.append({
                                    "range": f"{rel_s}-{rel_e}",
                                    "start": rel_s,
                                    "end": rel_e,
                                    "color": seg.get("color", "#99ccff"),
                                    "type": seg.get("type", "standard")
                                })
                        if mapped_segs:
                            copy_f = dict(df)
                            old_dir = df.get("directionality", "1")
                            copy_f["directionality"] = "2" if old_dir == "1" else ("1" if old_dir == "2" else "0")
                            copy_f["segments"] = mapped_segs
                            insert_features.append(copy_f)
        
    ins_len = len(insert_seq)
    if ins_len == 0:
        raise ValueError("Insert sequence cannot be empty")
        
    cut_start = max(1, min(cut_start, vec_len + 1))
    cut_end = max(cut_start - 1, min(cut_end, vec_len))
    
    left_part = vec_seq[:cut_start - 1]
    right_part = vec_seq[cut_end:]
    recomb_seq = left_part + insert_seq + right_part
    recomb_len = len(recomb_seq)
    
    deleted_vec_len = max(0, cut_end - cut_start + 1)
    delta = ins_len - deleted_vec_len
    insert_start_pos = len(left_part) + 1
    insert_end_pos = insert_start_pos + ins_len - 1
    
    vec_features = extract_features(vec_blocks)
    new_features = []
    
    # 1. Remap vector features
    for f in vec_features:
        new_segs = []
        for seg in f["segments"]:
            s, e = seg["start"], seg["end"]
            c = seg.get("color", "#99ccff")
            st = seg.get("type", "standard")
            if e < cut_start:
                new_segs.append({"range": f"{s}-{e}", "start": s, "end": e, "color": c, "type": st})
            elif s > cut_end:
                ns, ne = s + delta, e + delta
                if 1 <= ns <= ne <= recomb_len:
                    new_segs.append({"range": f"{ns}-{ne}", "start": ns, "end": ne, "color": c, "type": st})
            elif s < cut_start and e > cut_end:
                ns, ne = s, e + delta
                if 1 <= ns <= ne <= recomb_len:
                    new_segs.append({"range": f"{ns}-{ne}", "start": ns, "end": ne, "color": c, "type": st})
        if new_segs:
            new_f = dict(f)
            new_f["segments"] = new_segs
            new_features.append(new_f)
            
    # 2. Add insert features
    has_exact_insert_feat = False
    for f in insert_features:
        new_segs = []
        for seg in f["segments"]:
            s, e = seg["start"], seg["end"]
            new_s = s + insert_start_pos - 1
            new_e = e + insert_start_pos - 1
            if 1 <= new_s <= new_e <= recomb_len:
                new_segs.append({
                    "range": f"{new_s}-{new_e}",
                    "start": new_s,
                    "end": new_e,
                    "color": seg.get("color", "#99ccff"),
                    "type": seg.get("type", "standard")
                })
                if new_s == insert_start_pos and new_e == insert_end_pos and f["name"].lower() == insert_name.lower():
                    has_exact_insert_feat = True
        if new_segs:
            new_f = dict(f)
            new_f["segments"] = new_segs
            new_features.append(new_f)
            
    # 3. Add Recombinant Marker Feature if not already identical
    if not has_exact_insert_feat:
        clean_ins_title = insert_name.strip() or "Insert"
        new_features.append({
            "name": clean_ins_title,
            "type": "CDS" if ins_len >= 30 else "misc_feature",
            "directionality": "1",
            "segments": [{
                "range": f"{insert_start_pos}-{insert_end_pos}",
                "start": insert_start_pos,
                "end": insert_end_pos,
                "color": "#10d286",
                "type": "standard"
            }],
            "qualifiers": []
        })
    
    new_features_xml = build_features_xml_bytes(new_features, recomb_len)
    
    new_seq_payload = bytearray()
    new_seq_payload.append(vec_props)
    new_seq_payload.extend(recomb_seq.encode("ascii"))
    
    new_blocks = [
        (BLOCK_HEADER, header_payload),
        (BLOCK_DNA, bytes(new_seq_payload)),
        (BLOCK_FEATURES, new_features_xml)
    ]
    
    for btype, payload in vec_blocks:
        if btype == BLOCK_NOTES and (payload.startswith(b"<?xml") or payload.startswith(b"<Notes")):
            new_blocks.append((btype, payload))
            break
            
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    write_tlv_blocks(output_path, new_blocks)
    
    combined_primers = collect_clean_existing_primers(vec_blocks) + (list(primers_data) if primers_data else [])
    if combined_primers:
        inject_primers_to_dna(output_path, combined_primers, backup=False)
        
    return {
        "status": "success",
        "outputPath": output_path,
        "recombinantLength": recomb_len,
        "insertRange": f"{insert_start_pos}-{insert_end_pos}",
        "featuresCount": len(new_features)
    }

def delete_fragment_from_dna(vec_file: str, del_start: int, del_end: int, primers_data: list, output_path: str):
    """
    Deletes a fragment [del_start, del_end] (1-based, inclusive) from a SnapGene plasmid,
    re-maps all remaining features, strips stale binary blocks, and injects primers.
    """
    vec_blocks = read_tlv_blocks(vec_file)
    header_payload = extract_valid_header(vec_blocks)
    vec_seq, is_circular, vec_props = extract_dna_sequence(vec_blocks)
    if not vec_seq:
        raise ValueError("载体文件中未找到有效 DNA 序列")
        
    vec_len = len(vec_seq)
    if del_start < 1 or del_end > vec_len or del_start > del_end:
        raise ValueError(f"删除区间 [{del_start}, {del_end}] 无效 (载体长度: {vec_len} bp)")
        
    del_len = del_end - del_start + 1
    new_seq = vec_seq[:del_start - 1] + vec_seq[del_end:]
    new_len = len(new_seq)
    if new_len == 0:
        raise ValueError("删除后质粒序列长度不能为 0")
    
    vec_features = extract_features(vec_blocks)
    new_features = []
    
    for f in vec_features:
        new_segs = []
        for seg in f["segments"]:
            s, e = seg["start"], seg["end"]
            c = seg.get("color", "#99ccff")
            st = seg.get("type", "standard")
            if s >= del_start and e <= del_end:
                continue
            elif e < del_start:
                new_segs.append({"range": f"{s}-{e}", "start": s, "end": e, "color": c, "type": st})
            elif s > del_end:
                new_s = s - del_len
                new_e = e - del_len
                if 1 <= new_s <= new_e <= new_len:
                    new_segs.append({"range": f"{new_s}-{new_e}", "start": new_s, "end": new_e, "color": c, "type": st})
            else:
                if s < del_start:
                    sub_e = min(e, del_start - 1)
                    if 1 <= s <= sub_e <= new_len:
                        new_segs.append({"range": f"{s}-{sub_e}", "start": s, "end": sub_e, "color": c, "type": st})
                if e > del_end:
                    sub_s = max(s, del_end + 1) - del_len
                    sub_e = e - del_len
                    if 1 <= sub_s <= sub_e <= new_len:
                        new_segs.append({"range": f"{sub_s}-{sub_e}", "start": sub_s, "end": sub_e, "color": c, "type": st})
                        
        if new_segs:
            new_f = dict(f)
            new_f["segments"] = new_segs
            new_features.append(new_f)
            
    junction_pos = max(1, min(del_start, new_len))
    new_features.append({
        "name": f"Δ Deletion ({del_len} bp)",
        "type": "misc_feature",
        "directionality": "0",
        "segments": [{
            "range": f"{junction_pos}-{junction_pos}",
            "start": junction_pos,
            "end": junction_pos,
            "color": "#ff4d6d",
            "type": "standard"
        }],
        "qualifiers": []
    })
    
    new_features_xml = build_features_xml_bytes(new_features, new_len)
    
    new_seq_payload = bytearray()
    new_seq_payload.append(vec_props)
    new_seq_payload.extend(new_seq.encode("ascii"))
    
    new_blocks = [
        (BLOCK_HEADER, header_payload),
        (BLOCK_DNA, bytes(new_seq_payload)),
        (BLOCK_FEATURES, new_features_xml)
    ]
    
    for btype, payload in vec_blocks:
        if btype == BLOCK_NOTES and (payload.startswith(b"<?xml") or payload.startswith(b"<Notes")):
            new_blocks.append((btype, payload))
            break
            
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    write_tlv_blocks(output_path, new_blocks)
    
    combined_primers = collect_clean_existing_primers(vec_blocks) + (list(primers_data) if primers_data else [])
    if combined_primers:
        inject_primers_to_dna(output_path, combined_primers, backup=False)
        
    return {
        "status": "success",
        "outputPath": output_path,
        "deletedLength": del_len,
        "newLength": new_len,
        "featuresCount": len(new_features)
    }

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: snapgene_bridge.py <command> <args...>")
        print("Commands: parse, inject, assemble, delete")
        sys.exit(1)
        
    cmd = sys.argv[1].lower()
    
    if cmd == "parse":
        fp = sys.argv[2]
        info = parse_dna(fp)
        print(json.dumps(info, ensure_ascii=False, indent=2))
        
    elif cmd == "inject":
        fp = sys.argv[2]
        json_file = sys.argv[3]
        backup = True if len(sys.argv) <= 4 or sys.argv[4] in ("1", "true", "True") else False
        with open(json_file, "r", encoding="utf-8") as f:
            p_data = json.load(f)
        res = inject_primers_to_dna(fp, p_data, backup=backup)
        print(json.dumps(res, ensure_ascii=False))
        
    elif cmd == "assemble":
        vec_file = sys.argv[2]
        insert_source = sys.argv[3]
        insert_name = sys.argv[4]
        cut_start = int(sys.argv[5])
        cut_end = int(sys.argv[6])
        primers_arg = sys.argv[7]
        out_file = sys.argv[8]
        donor_file = sys.argv[9] if len(sys.argv) > 9 else "none"
        
        primers_list = []
        if primers_arg and primers_arg != "none" and os.path.isfile(primers_arg):
            with open(primers_arg, "r", encoding="utf-8") as f:
                primers_list = json.load(f)
                
        res = assemble_recombinant_dna(
            vec_file, insert_source, insert_name, cut_start, cut_end, primers_list, out_file, donor_file
        )
        print(json.dumps(res, ensure_ascii=False))
        
    elif cmd == "delete":
        vec_file = sys.argv[2]
        del_start = int(sys.argv[3])
        del_end = int(sys.argv[4])
        primers_arg = sys.argv[5]
        out_file = sys.argv[6]
        
        primers_list = []
        if primers_arg and primers_arg != "none" and os.path.isfile(primers_arg):
            with open(primers_arg, "r", encoding="utf-8") as f:
                primers_list = json.load(f)
                
        res = delete_fragment_from_dna(vec_file, del_start, del_end, primers_list, out_file)
        print(json.dumps(res, ensure_ascii=False))
