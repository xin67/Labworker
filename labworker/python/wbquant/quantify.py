"""光密度积分定量（IOD）、局部基线扣除、过曝判定与内参归一化计算。"""

from __future__ import annotations

from dataclasses import replace

import numpy as np

from .models import BandBox


def quantify_bands(
    raw_signal_img: np.ndarray,
    corrected_img: np.ndarray,
    sat_mask: np.ndarray,
    aligned_boxes: list[tuple[int, int, int, int, int, int, int]],
    control_lane_index: int = 0,
) -> list[BandBox]:
    """计算每个条带圈定框的积分光密度（IOD）、过曝比例与相对对照泳道的倍数变化。"""
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

        # 取上下外侧各 2px 边缘中位数作为残余局部基线（等效 ImageJ 峰底连线闭合扣除）
        top_strip = corrected_img[max(0, y0 - 2) : y0, x0:x1]
        bot_strip = corrected_img[y1 : min(h_img, y1 + 2), x0:x1]
        border_vals = [arr.ravel() for arr in (top_strip, bot_strip) if arr.size > 0]
        local_base = float(np.median(np.concatenate(border_vals))) if border_vals else 0.0

        net_patch = np.clip(corr_patch - local_base, 0.0, None)
        raw_iod = float(np.sum(raw_patch))
        net_iod = float(np.sum(net_patch))
        bg_iod = max(0.0, raw_iod - net_iod)

        # 统计条带核心发光区内的过曝像素占比
        pmax = float(np.max(corr_patch)) if corr_patch.size else 0.0
        core_mask = corr_patch >= (pmax * 0.25) if pmax > 0 else np.ones_like(corr_patch, dtype=bool)
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
                is_saturated=sat_ratio >= 0.01,
                is_primary=(row_idx == 0),
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
        for b in row_bands:
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


def normalize_to_housekeeping(
    target_bands: list[BandBox],
    reference_bands: list[BandBox],
    control_lane_index: int = 0,
) -> list[BandBox]:
    """使用内参蛋白（如 GAPDH / β-actin）对目的蛋白条带做跨膜归一化。"""
    ref_by_lane = {b.lane_index: b.net_iod for b in reference_bands if b.net_iod > 1e-6}
    ratios: dict[int, float] = {}
    for b in target_bands:
        ref_val = ref_by_lane.get(b.lane_index)
        ratios[b.lane_index] = (b.net_iod / ref_val) if ref_val else 0.0

    ctrl_ratio = ratios.get(control_lane_index)
    if not ctrl_ratio or ctrl_ratio <= 1e-9:
        non_zero = [v for v in ratios.values() if v > 1e-9]
        ctrl_ratio = non_zero[0] if non_zero else 1.0

    return [
        replace(
            b,
            normalized_ratio=ratios.get(b.lane_index, 0.0),
            fold_change=ratios.get(b.lane_index, 0.0) / ctrl_ratio,
        )
        for b in target_bands
    ]
