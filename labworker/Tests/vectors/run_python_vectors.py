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

sys.dont_write_bytecode = True

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
    if isinstance(expected, dict):
        if not isinstance(actual, dict) or set(actual.keys()) != set(expected.keys()):
            raise AssertionError(f"{label}: dict keys mismatch expected {sorted(expected.keys())}, got {actual}")
        for k, e_val in expected.items():
            assert_close(actual.get(k), e_val, tol, f"{label}.{k}")
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

    elif func_name == "crispr_deconv_golden":
        out = mcp.deconvolve_sanger_crispr(inp)
        assert_close(out["cut_index_0based"], exp["cut_index_0based"], 0, f"{func_name}.{cid}.cut_index_0based")
        assert_close(out["is_reverse_strand_sgrna"], exp["is_reverse_strand_sgrna"], 0, f"{func_name}.{cid}.is_reverse_strand_sgrna")
        assert_close(out["effective_window_bp"], exp["effective_window_bp"], 0, f"{func_name}.{cid}.effective_window_bp")
        assert_close(out["wt_percent"], exp["wt_percent"], tol, f"{func_name}.{cid}.wt_percent")
        assert_close(out["indel_percent"], exp["indel_percent"], tol, f"{func_name}.{cid}.indel_percent")
        assert_close(out["ko_score"], exp["ko_score"], tol, f"{func_name}.{cid}.ko_score")
        assert_close(out["hdr_percent"], exp["hdr_percent"], tol, f"{func_name}.{cid}.hdr_percent")
        assert_close(out["total_edited_percent"], exp["total_edited_percent"], tol, f"{func_name}.{cid}.total_edited_percent")
        assert_close(out["r_squared"], exp["r_squared"], tol, f"{func_name}.{cid}.r_squared")
        assert_close(out["warnings"], exp["warnings"], tol, f"{func_name}.{cid}.warnings")

    elif func_name == "plasmid_auto_annotation":
        out = mcp.annotate_plasmid_fasta(inp)
        assert_close(out["plasmid_name"], exp["plasmid_name"], 0, f"{func_name}.{cid}.plasmid_name")
        assert_close(out["sequence_length"], exp["sequence_length"], 0, f"{func_name}.{cid}.sequence_length")
        assert_close(out["is_circular"], exp["is_circular"], 0, f"{func_name}.{cid}.is_circular")
        assert_close(out["features_count"], exp["features_count"], 0, f"{func_name}.{cid}.features_count")
        assert_close(out["fragment_count"], exp["fragment_count"], 0, f"{func_name}.{cid}.fragment_count")
        assert_close(out["origin_spanning_count"], exp["origin_spanning_count"], 0, f"{func_name}.{cid}.origin_spanning_count")
        exp_feats = exp["features"]
        act_feats = out["features"]
        if len(act_feats) != len(exp_feats):
            raise AssertionError(f"{func_name}.{cid}: feature count mismatch expected {len(exp_feats)}, got {len(act_feats)}")
        for idx, (af, ef) in enumerate(zip(act_feats, exp_feats)):
            assert_close(af["name"], ef["name"], 0, f"{func_name}.{cid}.features[{idx}].name")
            assert_close(af["category"], ef["category"], 0, f"{func_name}.{cid}.features[{idx}].category")
            assert_close(af["strand"], ef["strand"], 0, f"{func_name}.{cid}.features[{idx}].strand")
            assert_close(af["start_1based"], ef["start_1based"], 0, f"{func_name}.{cid}.features[{idx}].start_1based")
            assert_close(af["end_1based"], ef["end_1based"], 0, f"{func_name}.{cid}.features[{idx}].end_1based")
            assert_close(af["matched_length"], ef["matched_length"], 0, f"{func_name}.{cid}.features[{idx}].matched_length")
            assert_close(af["is_origin_spanning"], ef["is_origin_spanning"], 0, f"{func_name}.{cid}.features[{idx}].is_origin_spanning")
            assert_close(af["is_fragment"], ef["is_fragment"], 0, f"{func_name}.{cid}.features[{idx}].is_fragment")
            assert_close(af["coverage"], ef["coverage"], tol, f"{func_name}.{cid}.features[{idx}].coverage")
            assert_close(af["identity"], ef["identity"], tol, f"{func_name}.{cid}.features[{idx}].identity")

    elif func_name == "golden_gate_and_digest":
        mode = inp.get("mode", "golden_gate")
        if mode == "golden_gate":
            out = mcp.design_golden_gate_assembly(inp)
            assert_close(out["enzyme_name"], exp["enzyme_name"], 0, f"{func_name}.{cid}.enzyme_name")
            assert_close(out["recognition_site"], exp["recognition_site"], 0, f"{func_name}.{cid}.recognition_site")
            assert_close(out["overhang_length"], exp["overhang_length"], 0, f"{func_name}.{cid}.overhang_length")
            assert_close(out["overhang_plan"]["assigned_overhangs"], exp["assigned_overhangs"], 0, f"{func_name}.{cid}.assigned_overhangs")
            assert_close(out["overhang_plan"]["assembly_fidelity"], exp["assembly_fidelity"], tol, f"{func_name}.{cid}.assembly_fidelity")
            assert_close(out["overhang_plan"]["cross_mismatch_count"], exp["cross_mismatch_count"], 0, f"{func_name}.{cid}.cross_mismatch_count")
            assert_close(out["total_internal_sites_found"], exp["total_internal_sites_found"], 0, f"{func_name}.{cid}.total_internal_sites_found")
            exp_doms = exp["domestications"]
            act_doms = out["domestications"]
            if len(act_doms) != len(exp_doms):
                raise AssertionError(f"{func_name}.{cid}: domestications count mismatch")
            for idx, (ad, ed) in enumerate(zip(act_doms, exp_doms)):
                assert_close(ad["fragment_name"], ed["fragment_name"], 0, f"{func_name}.{cid}.dom[{idx}].fragment_name")
                assert_close(ad["internal_sites_found"], ed["internal_sites_found"], 0, f"{func_name}.{cid}.dom[{idx}].internal_sites_found")
                assert_close(ad["remaining_sites_after_domestication"], ed["remaining_sites_after_domestication"], 0, f"{func_name}.{cid}.dom[{idx}].remaining_sites")
                assert_close(ad["domesticated_sequence"], ed["domesticated_sequence"], 0, f"{func_name}.{cid}.dom[{idx}].domesticated_sequence")
                if len(ad["suggestions"]) != len(ed["suggestions"]):
                    raise AssertionError(f"{func_name}.{cid}.dom[{idx}]: suggestion count mismatch")
                for s_idx, (asug, esug) in enumerate(zip(ad["suggestions"], ed["suggestions"])):
                    assert_close(asug["site_strand"], esug["site_strand"], 0, f"{func_name}.{cid}.dom[{idx}].sug[{s_idx}].site_strand")
                    assert_close(asug["site_start_1based"], esug["site_start_1based"], 0, f"{func_name}.{cid}.dom[{idx}].sug[{s_idx}].site_start_1based")
                    assert_close(asug["original_codon"], esug["original_codon"], 0, f"{func_name}.{cid}.dom[{idx}].sug[{s_idx}].original_codon")
                    assert_close(asug["mutated_codon"], esug["mutated_codon"], 0, f"{func_name}.{cid}.dom[{idx}].sug[{s_idx}].mutated_codon")
                    assert_close(asug["amino_acid"], esug["amino_acid"], 0, f"{func_name}.{cid}.dom[{idx}].sug[{s_idx}].amino_acid")
                    assert_close(asug["mutation_position_1based"], esug["mutation_position_1based"], 0, f"{func_name}.{cid}.dom[{idx}].sug[{s_idx}].mutation_position_1based")
                    assert_close(asug["is_synonymous"], esug["is_synonymous"], 0, f"{func_name}.{cid}.dom[{idx}].sug[{s_idx}].is_synonymous")
        elif mode == "diagnostic_digest":
            out = mcp.recommend_diagnostic_digests(inp)
            assert_close(out["empty_vector_length_bp"], exp["empty_vector_length_bp"], 0, f"{func_name}.{cid}.empty_vector_length_bp")
            assert_close(out["recombinant_length_bp"], exp["recombinant_length_bp"], 0, f"{func_name}.{cid}.recombinant_length_bp")
            assert_close(out["is_circular"], exp["is_circular"], 0, f"{func_name}.{cid}.is_circular")
            act_recs = out["top_recommendations"]
            exp_recs = exp["top_recommendations"]
            if len(act_recs) != len(exp_recs):
                raise AssertionError(f"{func_name}.{cid}: top_recommendations count mismatch")
            for idx, (ar, er) in enumerate(zip(act_recs, exp_recs)):
                assert_close(ar["rank"], er["rank"], 0, f"{func_name}.{cid}.rec[{idx}].rank")
                assert_close(ar["enzyme_names"], er["enzyme_names"], 0, f"{func_name}.{cid}.rec[{idx}].enzyme_names")
                assert_close(ar["recommended_gel_concentration"], er["recommended_gel_concentration"], 0, f"{func_name}.{cid}.rec[{idx}].recommended_gel_concentration")
                assert_close(ar["preferred_buffer"], er["preferred_buffer"], 0, f"{func_name}.{cid}.rec[{idx}].preferred_buffer")
                assert_close(ar["buffer_compatibility_percent"], er["buffer_compatibility_percent"], 0, f"{func_name}.{cid}.rec[{idx}].buffer_compatibility_percent")
                assert_close(ar["empty_vector_bands_bp"], er["empty_vector_bands_bp"], 0, f"{func_name}.{cid}.rec[{idx}].empty_vector_bands_bp")
                assert_close(ar["recombinant_bands_bp"], er["recombinant_bands_bp"], 0, f"{func_name}.{cid}.rec[{idx}].recombinant_bands_bp")
                assert_close(ar["max_migration_shift_y"], er["max_migration_shift_y"], tol, f"{func_name}.{cid}.rec[{idx}].max_migration_shift_y")
                assert_close(ar["mean_migration_shift_y"], er["mean_migration_shift_y"], tol, f"{func_name}.{cid}.rec[{idx}].mean_migration_shift_y")
                assert_close(ar["min_intra_lane_gap_y"], er["min_intra_lane_gap_y"], tol, f"{func_name}.{cid}.rec[{idx}].min_intra_lane_gap_y")
                assert_close(ar["max_band_size_diff_bp"], er["max_band_size_diff_bp"], 0, f"{func_name}.{cid}.rec[{idx}].max_band_size_diff_bp")
                assert_close(ar["score"], er["score"], tol, f"{func_name}.{cid}.rec[{idx}].score")
        else:
            raise AssertionError(f"{func_name}.{cid}: unknown mode {mode}")

    elif func_name == "crispr_hdr_donor":
        rep = mcp.design_crispr_hdr_donor(inp)
        assert_close(rep["donor_format"], exp["donor_format"], 0, f"{func_name}.{cid}.donor_format")
        assert_close(rep["wt_cut_index_0based"], exp["wt_cut_index_0based"], 0, f"{func_name}.{cid}.wt_cut_index_0based")
        assert_close(rep["wt_pam_start_0based"], exp["wt_pam_start_0based"], 0, f"{func_name}.{cid}.wt_pam_start_0based")
        assert_close(rep["wt_pam_sequence"], exp["wt_pam_sequence"], 0, f"{func_name}.{cid}.wt_pam_sequence")
        assert_close(rep["is_in_cds"], exp["is_in_cds"], 0, f"{func_name}.{cid}.is_in_cds")
        assert_close(rep["cds_auto_detected"], exp["cds_auto_detected"], 0, f"{func_name}.{cid}.cds_auto_detected")
        assert_close(rep["protein_before_blocking"], exp["protein_before_blocking"], 0, f"{func_name}.{cid}.protein_before_blocking")
        assert_close(rep["protein_after_blocking"], exp["protein_after_blocking"], 0, f"{func_name}.{cid}.protein_after_blocking")
        assert_close(rep["amino_acid_conserved"], exp["amino_acid_conserved"], 0, f"{func_name}.{cid}.amino_acid_conserved")
        assert_close(rep["blocking_strategy"], exp["blocking_strategy"], 0, f"{func_name}.{cid}.blocking_strategy")
        assert_close(rep["blocking_mutations"], exp["blocking_mutations"], 0, f"{func_name}.{cid}.blocking_mutations")
        assert_close(rep["edited_pam_sequence"], exp["edited_pam_sequence"], 0, f"{func_name}.{cid}.edited_pam_sequence")
        assert_close(rep["pam_still_intact"], exp["pam_still_intact"], 0, f"{func_name}.{cid}.pam_still_intact")
        assert_close(rep["cas9_recut_blocked"], exp["cas9_recut_blocked"], 0, f"{func_name}.{cid}.cas9_recut_blocked")
        assert_close(rep["left_arm_length_bp"], exp["left_arm_length_bp"], 0, f"{func_name}.{cid}.left_arm_length_bp")
        assert_close(rep["right_arm_length_bp"], exp["right_arm_length_bp"], 0, f"{func_name}.{cid}.right_arm_length_bp")
        assert_close(rep["donor_length_bp"], exp["donor_length_bp"], 0, f"{func_name}.{cid}.donor_length_bp")
        assert_close(rep["donor_sequence"], exp["donor_sequence"], 0, f"{func_name}.{cid}.donor_sequence")

        exp_rflp = exp.get("rflp")
        act_rflp = rep.get("rflp")
        if exp_rflp is None:
            if act_rflp is not None:
                raise AssertionError(f"{func_name}.{cid}.rflp expected None, got {act_rflp}")
        else:
            if act_rflp is None:
                raise AssertionError(f"{func_name}.{cid}.rflp expected non-None, got None")
            assert_close(act_rflp["mode"], exp_rflp["mode"], 0, f"{func_name}.{cid}.rflp.mode")
            assert_close(act_rflp["enzyme_name"], exp_rflp["enzyme_name"], 0, f"{func_name}.{cid}.rflp.enzyme_name")
            assert_close(act_rflp["recognition_site"], exp_rflp["recognition_site"], 0, f"{func_name}.{cid}.rflp.recognition_site")
            assert_close(act_rflp["wt_amplicon_bands_bp"], exp_rflp["wt_amplicon_bands_bp"], 0, f"{func_name}.{cid}.rflp.wt_amplicon_bands_bp")
            assert_close(act_rflp["hdr_amplicon_bands_bp"], exp_rflp["hdr_amplicon_bands_bp"], 0, f"{func_name}.{cid}.rflp.hdr_amplicon_bands_bp")
            assert_close(act_rflp["silent_mutations"], exp_rflp["silent_mutations"], 0, f"{func_name}.{cid}.rflp.silent_mutations")

        exp_pcr = exp.get("out_out_pcr")
        act_pcr = rep.get("out_out_pcr")
        if exp_pcr is None:
            if act_pcr is not None:
                raise AssertionError(f"{func_name}.{cid}.out_out_pcr expected None, got {act_pcr}")
        else:
            if act_pcr is None:
                raise AssertionError(f"{func_name}.{cid}.out_out_pcr expected non-None, got None")
            assert_close(act_pcr["forward_primer"]["full_sequence"], exp_pcr["forward_sequence"], 0, f"{func_name}.{cid}.pcr.forward_sequence")
            assert_close(act_pcr["forward_primer"]["tm"], exp_pcr["forward_tm"], tol, f"{func_name}.{cid}.pcr.forward_tm")
            assert_close(act_pcr["reverse_primer"]["full_sequence"], exp_pcr["reverse_sequence"], 0, f"{func_name}.{cid}.pcr.reverse_sequence")
            assert_close(act_pcr["reverse_primer"]["tm"], exp_pcr["reverse_tm"], tol, f"{func_name}.{cid}.pcr.reverse_tm")
            assert_close(act_pcr["forward_start_0based"], exp_pcr["forward_start_0based"], 0, f"{func_name}.{cid}.pcr.forward_start_0based")
            assert_close(act_pcr["forward_end_0based"], exp_pcr["forward_end_0based"], 0, f"{func_name}.{cid}.pcr.forward_end_0based")
            assert_close(act_pcr["reverse_start_0based"], exp_pcr["reverse_start_0based"], 0, f"{func_name}.{cid}.pcr.reverse_start_0based")
            assert_close(act_pcr["reverse_end_0based"], exp_pcr["reverse_end_0based"], 0, f"{func_name}.{cid}.pcr.reverse_end_0based")
            assert_close(act_pcr["wt_amplicon_length_bp"], exp_pcr["wt_amplicon_length_bp"], 0, f"{func_name}.{cid}.pcr.wt_amplicon_length_bp")
            assert_close(act_pcr["hdr_amplicon_length_bp"], exp_pcr["hdr_amplicon_length_bp"], 0, f"{func_name}.{cid}.pcr.hdr_amplicon_length_bp")
            assert_close(act_pcr["left_margin_from_arm_bp"], exp_pcr["left_margin_from_arm_bp"], 0, f"{func_name}.{cid}.pcr.left_margin_from_arm_bp")
            assert_close(act_pcr["right_margin_from_arm_bp"], exp_pcr["right_margin_from_arm_bp"], 0, f"{func_name}.{cid}.pcr.right_margin_from_arm_bp")

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
