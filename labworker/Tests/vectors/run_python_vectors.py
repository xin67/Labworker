#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Labworker Swift–Python Shared Test Vectors Runner (P12).
Executes all JSON test vectors under Tests/vectors/*.json against clonestudio_mcp_server.py.
Supports --tamper-check to verify that mutating any expected value causes a non-zero exit code.
"""

import os
import sys
import glob
import json
import copy

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(HERE))
MCP_DIR = os.path.join(PROJECT_ROOT, "Sources/CloneStudioCore/Resources")
sys.path.insert(0, MCP_DIR)

import clonestudio_mcp_server as mcp

# Disable GUI notification side effects during test vector execution
mcp.notify_gui_and_sync_primers = lambda *a, **k: "noop"


def assert_close(actual, expected, tol: float, label: str):
    if expected is None:
        if actual is not None:
            raise AssertionError(f"{label}: expected None, got {actual}")
        return
    if isinstance(expected, bool):
        if bool(actual) != expected:
            raise AssertionError(f"{label}: expected {expected}, got {actual}")
        return
    if isinstance(expected, (int, float)):
        if actual is None or abs(float(actual) - float(expected)) > tol:
            raise AssertionError(f"{label}: expected {expected} (±{tol}), got {actual}")
        return
    if isinstance(expected, str):
        if str(actual) != expected:
            raise AssertionError(f"{label}: expected '{expected}', got '{actual}'")
        return
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            raise AssertionError(f"{label}: list length mismatch expected {len(expected)}, got {actual}")
        for idx, (a_item, e_item) in enumerate(zip(actual, expected)):
            assert_close(a_item, e_item, tol, f"{label}[{idx}]")
        return
    raise AssertionError(f"{label}: unsupported expected type {type(expected)}")


def run_case(func_name: str, case: dict):
    cid = case.get("id", "unnamed")
    inp = case["input"]
    exp = case["expected"]
    tol = float(case.get("tolerance", 0.01))

    if func_name == "tm_santalucia":
        tm = mcp.calc_snapgene_tm(
            seq=inp.get("sequence", ""),
            five_prime_overhang=inp.get("five_prime_overhang", ""),
            three_prime_overhang=inp.get("three_prime_overhang", ""),
            na_molar=float(inp.get("na_molar", 0.05)),
            primer_conc=float(inp.get("primer_conc", 250e-9)),
            mv_conc=inp.get("mv_conc"),
            dv_conc=float(inp.get("dv_conc", 0.0)),
            dntp_conc=float(inp.get("dntp_conc", 0.0))
        )
        assert_close(tm, exp["tm"], tol, f"{func_name}.{cid}.tm")

    elif func_name == "reverse_complement":
        mode = inp.get("mode", "rev_comp")
        if mode == "circular_subseq":
            sub = mcp.extract_circular_subsequence(
                inp["sequence"],
                int(inp["start_1based"]),
                int(inp["end_1based"]),
                inp.get("strand", "+")
            )
            assert_close(sub, exp["subsequence"], tol, f"{func_name}.{cid}.subsequence")
        else:
            raw = inp.get("sequence", "")
            assert_close(mcp.clean_seq(raw), exp["cleaned"], tol, f"{func_name}.{cid}.cleaned")
            assert_close(mcp.rev_comp(raw), exp["reverse_complement"], tol, f"{func_name}.{cid}.reverse_complement")
            assert_close(mcp.gc_percent(raw), exp["gc_percent"], tol, f"{func_name}.{cid}.gc_percent")

    elif func_name == "primer_thermo_dg":
        kind = inp.get("kind", "hairpin")
        mv = float(inp.get("mv_conc", 50.0))
        dv = float(inp.get("dv_conc", 1.5))
        dntp = float(inp.get("dntp_conc", 0.6))
        dna = float(inp.get("dna_conc", 50.0))
        temp_c = float(inp.get("temp_c", 37.0))
        if kind == "hairpin":
            res = mcp.calc_hairpin(inp["seq1"], mv, dv, dntp, dna, temp_c)
        elif kind == "homodimer":
            res = mcp.calc_homodimer(inp["seq1"], mv, dv, dntp, dna, temp_c)
        else:
            res = mcp.calc_dimer(inp["seq1"], inp["seq2"], mv, dv, dntp, dna, temp_c)
        assert_close(res["structure_found"], exp["structure_found"], tol, f"{func_name}.{cid}.structure_found")
        assert_close(res["dg"], exp["dg"], tol, f"{func_name}.{cid}.dg")
        assert_close(res["tm"], exp["tm"], max(0.2, tol * 4), f"{func_name}.{cid}.tm")

    elif func_name == "protein_pi_ddg":
        out = mcp.tool_analyze_protein_and_docking_box(inp)
        assert_close(out["length_aa"], exp["length_aa"], 0, f"{func_name}.{cid}.length_aa")
        assert_close(out["molecular_weight_da"], exp["molecular_weight_da"], max(0.2, tol), f"{func_name}.{cid}.molecular_weight_da")
        assert_close(out["isoelectric_point"], exp["isoelectric_point"], tol, f"{func_name}.{cid}.isoelectric_point")
        assert_close(out["net_charge_at_ph"], exp["net_charge_at_ph"], tol, f"{func_name}.{cid}.net_charge_at_ph")
        assert_close(out["gravy"], exp["gravy"], tol, f"{func_name}.{cid}.gravy")
        assert_close(out.get("ddg_model_type"), "empirical_heuristic", 0, f"{func_name}.{cid}.ddg_model_type")
        for idx, m in enumerate(out["mutant_evaluations"]):
            assert_close(m.get("model_type"), "empirical_heuristic", 0, f"{func_name}.{cid}.mutant[{idx}].model_type")
        actual_ddgs = [m["ddg_kcal_mol"] for m in out["mutant_evaluations"]]
        assert_close(actual_ddgs, exp["mutant_ddg"], tol, f"{func_name}.{cid}.mutant_ddg")

    elif func_name == "qpcr_ddct":
        out = mcp.tool_analyze_qpcr_ddct(inp)
        target_grp = exp["target_group"]
        grp = next((g for g in out["group_summaries"] if g["group"] == target_grp), None)
        if grp is None:
            raise AssertionError(f"{func_name}.{cid}: group '{target_grp}' not found")
        assert_close(grp["n_biological"], exp["n_biological"], 0, f"{func_name}.{cid}.n_biological")
        assert_close(grp["mean_dct"], exp["mean_dct"], tol, f"{func_name}.{cid}.mean_dct")
        assert_close(grp["p_value"], exp["p_value"], tol, f"{func_name}.{cid}.p_value")
        assert_close(grp["p_adjusted"], exp["p_adjusted"], tol, f"{func_name}.{cid}.p_adjusted")
        assert_close(grp["ddct_ci95_low"], exp["ddct_ci95_low"], tol, f"{func_name}.{cid}.ddct_ci95_low")
        assert_close(grp["ddct_ci95_high"], exp["ddct_ci95_high"], tol, f"{func_name}.{cid}.ddct_ci95_high")
        assert_close(grp["fold_ci95_low"], exp["fold_ci95_low"], tol, f"{func_name}.{cid}.fold_ci95_low")
        assert_close(grp["fold_ci95_high"], exp["fold_ci95_high"], tol, f"{func_name}.{cid}.fold_ci95_high")
        assert_close(grp["stat_note"], exp["stat_note"], tol, f"{func_name}.{cid}.stat_note")

    elif func_name == "holm_adjust":
        adj = mcp._holm_adjust(inp["p_values"])
        assert_close(adj, exp["p_adjusted"], tol, f"{func_name}.{cid}.p_adjusted")

    else:
        raise AssertionError(f"Unknown vector function: {func_name}")


def run_all_vectors(tamper_check: bool = False) -> tuple:
    pattern = os.path.join(HERE, "*.json")
    files = sorted(glob.glob(pattern))
    if not files:
        raise RuntimeError(f"No vector JSON files found in {HERE}")

    total_cases = 0
    for fp in files:
        with open(fp, "r", encoding="utf-8") as f:
            doc = json.load(f)
        func_name = doc["function"]
        for case in doc["cases"]:
            if tamper_check and total_cases == 0:
                mut_case = copy.deepcopy(case)
                for k, v in mut_case["expected"].items():
                    if isinstance(v, (int, float)):
                        mut_case["expected"][k] = v + 999.0
                        break
                    elif isinstance(v, str):
                        mut_case["expected"][k] = v + "_TAMPERED"
                        break
                    elif isinstance(v, list) and len(v) > 0:
                        mut_case["expected"][k] = [999.0] * len(v)
                        break
                run_case(func_name, mut_case)
            else:
                run_case(func_name, case)
            total_cases += 1
    return (len(files), total_cases)


if __name__ == "__main__":
    is_tamper = "--tamper-check" in sys.argv
    try:
        f_cnt, c_cnt = run_all_vectors(tamper_check=is_tamper)
        if is_tamper:
            sys.stderr.write("ERROR: tamper-check unexpectedly passed!\n")
            sys.exit(1)
        print(f"✅ [run_python_vectors] All {c_cnt} shared test cases across {f_cnt} JSON vector files passed!")
        sys.exit(0)
    except Exception as exc:
        if is_tamper:
            print(f"✅ [run_python_vectors] Tamper check caught mutated expectation as expected: {exc}")
            sys.exit(2)
        sys.stderr.write(f"❌ [run_python_vectors] Vector assertion failed: {exc}\n")
        sys.exit(1)
