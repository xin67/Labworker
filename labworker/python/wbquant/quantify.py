"""光密度积分定量（IOD）、单次去背景（无双重扣除/无噪声整流偏置）、重叠双带高斯混合去卷积、全蛋白归一化（TPN）与内参归一化。"""

from __future__ import annotations

from dataclasses import replace
import math

import numpy as np
from scipy.optimize import least_squares

from .models import BandBox, LaneRegion


def quantify_bands(
    raw_signal_img: np.ndarray,
    corrected_img: np.ndarray,
    sat_mask: np.ndarray,
    aligned_boxes: list[tuple[int, int, int, int, int, int, int]],
    control_lane_index: int = 0,
    background_mode: str = "globalRollingBall",
    saturation_ratio_threshold: float = 0.01,
) -> list[BandBox]:
    """计算每个条带圈定框的积分光密度（IOD）、信噪比、过曝比例与相对对照泳道的倍数变化。

    严格消除双重减背景与单侧 max(0, ...) 噪声整流偏置：
    - background_mode == "globalRollingBall"：直接对全局滚动球去背景后的有符号图像积分，不再叠加局部基线扣除；
    - background_mode == "localTrapezoid"：在原始信号图上对上下外侧各 2px 边缘中位数线性插值构建局部梯形基线并扣除。
    """
    h_img, w_img = corrected_img.shape[:2]
    preliminary: list[BandBox] = []

    for lane_idx, row_idx, x, y, w, h, peak_y in aligned_boxes:
        x0 = max(0, min(w_img - 1, int(x)))
        y0 = max(0, min(h_img - 1, int(y)))
        x1 = max(x0 + 1, min(w_img, int(x + w)))
        y1 = max(y0 + 1, min(h_img, int(y + h)))

        raw_patch = raw_signal_img[y0:y1, x0:x1]
        corr_patch = corrected_img[y0:y1, x0:x1]
        sat_patch = sat_mask[y0:y1, x0:x1]
        bh = y1 - y0

        if background_mode == "localTrapezoid":
            top_strip = raw_signal_img[max(0, y0 - 2) : y0, x0:x1]
            bot_strip = raw_signal_img[y1 : min(h_img, y1 + 2), x0:x1]
            top_med = float(np.median(top_strip)) if top_strip.size > 0 else 0.0
            bot_med = float(np.median(bot_strip)) if bot_strip.size > 0 else top_med
            if top_strip.size == 0:
                top_med = bot_med
            t = np.linspace(0.0, 1.0, bh)[:, None]
            trapezoid_bg = top_med * (1.0 - t) + bot_med * t
            net_patch = raw_patch - trapezoid_bg
            border_ref = np.concatenate([a.ravel() for a in (top_strip, bot_strip) if a.size > 0]) if (top_strip.size > 0 or bot_strip.size > 0) else raw_patch.ravel()
            noise_sd = float(np.std(border_ref)) if border_ref.size > 1 else 0.0
        else:
            # 全局 Rolling Ball 去背景模式：直接使用有符号残差积分，禁止二次叠加局部基线扣除
            net_patch = corr_patch
            top_strip = corrected_img[max(0, y0 - 2) : y0, x0:x1]
            bot_strip = corrected_img[y1 : min(h_img, y1 + 2), x0:x1]
            border_vals = [a.ravel() for a in (top_strip, bot_strip) if a.size > 0]
            border_ref = np.concatenate(border_vals) if border_vals else corr_patch.ravel()
            noise_sd = float(np.std(border_ref)) if border_ref.size > 1 else 0.0

        # 允许有符号残差在积分内自然抵消背景噪声，仅最终总 IOD 钳位 >= 0
        raw_iod = float(np.sum(raw_patch))
        signed_net_iod = float(np.sum(net_patch))
        net_iod = max(0.0, signed_net_iod)
        bg_iod = max(0.0, raw_iod - net_iod)

        pmax = float(np.max(net_patch)) if net_patch.size else 0.0
        snr = (pmax / noise_sd) if noise_sd > 1e-9 else (100.0 if pmax > 0 else 0.0)

        # 统计条带核心发光区内的过曝像素占比
        core_mask = net_patch >= (pmax * 0.25) if pmax > 0 else np.ones_like(net_patch, dtype=bool)
        core_count = max(1, int(np.sum(core_mask)))
        sat_ratio = float(np.sum(sat_patch & core_mask)) / float(core_count)

        preliminary.append(
            BandBox(
                id=f"L{lane_idx + 1}_R{row_idx + 1}",
                lane_index=lane_idx,
                row_index=row_idx,
                x=x0,
                y=y0,
                width=x1 - x0,
                height=y1 - y0,
                peak_y=int(peak_y),
                raw_iod=raw_iod,
                background_iod=bg_iod,
                net_iod=net_iod,
                normalized_ratio=1.0,
                fold_change=1.0,
                saturated_ratio=sat_ratio,
                is_saturated=sat_ratio >= max(0.001, float(saturation_ratio_threshold)),
                is_primary=(row_idx == 0),
                snr=snr,
            )
        )

    # 按行计算相对 control_lane_index 的 Fold Change
    by_row: dict[int, list[BandBox]] = {}
    for b in preliminary:
        by_row.setdefault(b.row_index, []).append(b)

    final_bands: list[BandBox] = []
    for r_idx, row_bands in sorted(by_row.items()):
        ctrl = next((b for b in row_bands if b.lane_index == control_lane_index), row_bands[0])
        base_iod = ctrl.net_iod if ctrl.net_iod > 1e-6 else 1.0
        for b in rowBands_sorted(row_bands):
            fc = b.net_iod / base_iod
            final_bands.append(
                replace(
                    b,
                    normalized_ratio=fc,
                    fold_change=fc,
                    is_primary=(r_idx == 0),
                )
            )
    return final_bands


def rowBands_sorted(row_bands: list[BandBox]) -> list[BandBox]:
    return sorted(row_bands, key=lambda b: b.lane_index)


def compute_total_lane_protein_iods(
    corrected_tpn_img: np.ndarray,
    lanes: list[LaneRegion] | tuple[LaneRegion, ...],
) -> dict[int, float]:
    """计算全蛋白染色膜（Ponceau S / Stain-Free / Revert 700）每条泳道的整泳道垂直积分净信号（TPN 分母）。"""
    h_img, w_img = corrected_tpn_img.shape[:2]
    totals: dict[int, float] = {}
    for lane in lanes:
        x0 = max(0, min(w_img - 1, int(lane.x_start)))
        x1 = max(x0 + 1, min(w_img, int(lane.x_end)))
        y0 = max(0, min(h_img - 1, int(lane.y_start)))
        y1 = max(y0 + 1, min(h_img, int(lane.y_end)))
        patch = corrected_tpn_img[y0:y1, x0:x1]
        totals[lane.index] = max(0.0, float(np.sum(patch)))
    return totals


def normalize_to_total_protein(
    target_bands: list[BandBox],
    total_protein_lane_iods: dict[int, float],
    control_lane_index: int = 0,
) -> list[BandBox]:
    """全蛋白归一化（TPN — 按 row_index 分行独立锚定对照，杜绝多行条带按 lane_index 互相覆写）。"""
    by_row: dict[int, list[BandBox]] = {}
    for b in target_bands:
        by_row.setdefault(b.row_index, []).append(b)

    row_ctrl_ratio: dict[int, float] = {}
    for r_idx, row_bands in by_row.items():
        row_ratios = [
            (b.lane_index, (b.net_iod / total_protein_lane_iods[b.lane_index]) if total_protein_lane_iods.get(b.lane_index, 0.0) > 1e-6 else 0.0)
            for b in row_bands
        ]
        ctrl_match = next((r for l, r in row_ratios if l == control_lane_index and r > 1e-9), None)
        if ctrl_match is not None:
            row_ctrl_ratio[r_idx] = ctrl_match
        else:
            first_pos = next((r for _, r in row_ratios if r > 1e-9), None)
            row_ctrl_ratio[r_idx] = first_pos if first_pos is not None else 1.0

    out: list[BandBox] = []
    for b in target_bands:
        tpn_val = total_protein_lane_iods.get(b.lane_index, 0.0)
        r = (b.net_iod / tpn_val) if tpn_val > 1e-6 else 0.0
        ctrl_anchor = row_ctrl_ratio.get(b.row_index, 1.0)
        out.append(replace(b, normalized_ratio=r, fold_change=r / ctrl_anchor))
    return out


def normalize_to_housekeeping(
    target_bands: list[BandBox],
    reference_bands: list[BandBox],
    control_lane_index: int = 0,
) -> list[BandBox]:
    """使用内参蛋白（如 GAPDH / β-actin）对目的蛋白条带做跨膜归一化（按 row_index 分行独立锚定对照）。"""
    ref_by_lane = {b.lane_index: b.net_iod for b in reference_bands if b.net_iod > 1e-6}
    by_row: dict[int, list[BandBox]] = {}
    for b in target_bands:
        by_row.setdefault(b.row_index, []).append(b)

    row_ctrl_ratio: dict[int, float] = {}
    for r_idx, row_bands in by_row.items():
        row_ratios = [
            (b.lane_index, (b.net_iod / ref_by_lane[b.lane_index]) if ref_by_lane.get(b.lane_index) else 0.0)
            for b in row_bands
        ]
        ctrl_match = next((r for l, r in row_ratios if l == control_lane_index and r > 1e-9), None)
        if ctrl_match is not None:
            row_ctrl_ratio[r_idx] = ctrl_match
        else:
            first_pos = next((r for _, r in row_ratios if r > 1e-9), None)
            row_ctrl_ratio[r_idx] = first_pos if first_pos is not None else 1.0

    out: list[BandBox] = []
    for b in target_bands:
        ref_val = ref_by_lane.get(b.lane_index)
        r = (b.net_iod / ref_val) if ref_val else 0.0
        ctrl_anchor = row_ctrl_ratio.get(b.row_index, 1.0)
        out.append(replace(b, normalized_ratio=r, fold_change=r / ctrl_anchor))
    return out


def deconvolve_overlapping_bands_gaussian(
    profile: np.ndarray | list[float],
    peak_indices: list[int],
) -> list[dict[str, float]]:
    """对重叠双带/多带（如 LC3-I/LC3-II、磷酸化/非磷酸化双带）执行 1D 高斯混合非线性最小二乘去卷积。

    模型：f(y) = sum_k A_k * exp(-0.5 * ((y - mu_k) / sigma_k)^2)
    返回各独立高斯峰的振幅 A、中心 mu、标准差 sigma、解析面积 A*sigma*sqrt(2*pi) 与面积占比 fraction。
    """
    y_arr = np.asarray(profile, dtype=np.float64)
    n = y_arr.size
    k = len(peak_indices)
    if n < 3 or k == 0:
        return []

    xs = np.arange(n, dtype=np.float64)
    ymax = max(1e-6, float(np.max(y_arr)))
    p0 = []
    lb = []
    ub = []
    for idx in peak_indices:
        mu0 = float(max(0, min(n - 1, idx)))
        amp0 = max(1e-3 * ymax, float(y_arr[int(round(mu0))]))
        sig0 = max(1.5, min(float(n) * 0.15, 3.0))
        p0.extend([amp0, mu0, sig0])
        lb.extend([0.0, max(0.0, mu0 - 8.0), 0.5])
        ub.extend([ymax * 2.5, min(float(n - 1), mu0 + 8.0), float(n) * 0.5])

    def residuals(params: np.ndarray) -> np.ndarray:
        pred = np.zeros(n, dtype=np.float64)
        for j in range(k):
            a_j = params[3 * j]
            mu_j = params[3 * j + 1]
            sig_j = params[3 * j + 2]
            pred += a_j * np.exp(-0.5 * ((xs - mu_j) / sig_j) ** 2)
        return pred - y_arr

    res = least_squares(residuals, np.asarray(p0, dtype=np.float64), bounds=(lb, ub), max_nfev=400)
    opt = res.x
    sqrt_2pi = math.sqrt(2.0 * math.pi)

    components: list[dict[str, float]] = []
    total_area = 0.0
    for j in range(k):
        a_j = float(opt[3 * j])
        mu_j = float(opt[3 * j + 1])
        sig_j = float(opt[3 * j + 2])
        area_j = a_j * sig_j * sqrt_2pi
        total_area += area_j
        components.append({
            "amplitude": a_j,
            "center": mu_j,
            "sigma": sig_j,
            "area": area_j,
            "fraction": 0.0,
        })

    for comp in components:
        comp["fraction"] = (comp["area"] / total_area) if total_area > 1e-12 else (1.0 / k)
    return components
