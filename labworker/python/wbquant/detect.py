"""自动圈定核心模块：波谷投影分泳道、高斯加权行剖面、条带峰检测、边界收紧与跨泳道同行对齐。"""

from __future__ import annotations

import numpy as np
from scipy.ndimage import gaussian_filter1d
from scipy.signal import find_peaks

from .models import AnalysisParams, BandBox, LaneRegion, RectROI


def lane_profile(lane_slice: np.ndarray) -> np.ndarray:
    """计算单泳道的高斯加权行强度剖面（抑制相邻泳道边缘串光）。"""
    h, w = lane_slice.shape[:2]
    if w <= 2:
        return np.mean(lane_slice, axis=1)
    xs = np.linspace(-1.5, 1.5, w)
    weights = np.exp(-0.5 * xs**2)
    weights /= np.sum(weights)
    return np.dot(lane_slice, weights)


def detect_lanes(
    signal_img: np.ndarray,
    strip_roi: RectROI,
    expected_lanes: int = 0,
) -> list[LaneRegion]:
    """基于膜条区域列投影的波谷检测自动划分泳道边界。"""
    roi = signal_img[strip_roi.y : strip_roi.y2, strip_roi.x : strip_roi.x2]
    h, strip_w = roi.shape[:2]
    if strip_w < 16 or h < 8:
        prof = tuple(float(v) for v in np.mean(roi, axis=1)) if roi.size else ()
        return [
            LaneRegion(
                index=0,
                x_start=strip_roi.x,
                x_end=strip_roi.x2,
                y_start=strip_roi.y,
                y_end=strip_roi.y2,
                profile=prof,
            )
        ]

    col_prof = gaussian_filter1d(np.mean(roi, axis=0), sigma=2.0)
    cmax = float(np.max(col_prof))
    if cmax <= 1e-6:
        prof = tuple(float(v) for v in np.mean(roi, axis=1))
        return [
            LaneRegion(
                index=0,
                x_start=strip_roi.x,
                x_end=strip_roi.x2,
                y_start=strip_roi.y,
                y_end=strip_roi.y2,
                profile=prof,
            )
        ]

    inv = cmax - col_prof
    min_dist = max(35, strip_w // (max(expected_lanes, 8) + 1))
    raw_valleys, _ = find_peaks(inv, distance=min_dist, prominence=cmax * 0.08)
    edge_margin = max(32, int(strip_w * 0.10))
    valleys = [int(v) for v in raw_valleys if edge_margin < v < (strip_w - edge_margin)]

    if expected_lanes > 1:
        target_splits = expected_lanes - 1
        if len(valleys) != target_splits:
            # 在理想等宽网格附近吸附真实局部波谷
            snapped: list[int] = []
            step = strip_w / float(expected_lanes)
            search_r = max(8, int(step * 0.28))
            for k in range(1, expected_lanes):
                ideal = int(round(k * step))
                lo = max(edge_margin, ideal - search_r)
                hi = min(strip_w - edge_margin, ideal + search_r)
                if hi > lo:
                    local_min = lo + int(np.argmin(col_prof[lo:hi]))
                    snapped.append(local_min)
                else:
                    snapped.append(ideal)
            valleys = sorted(set(snapped))

    boundaries = [0] + valleys + [strip_w]
    lanes: list[LaneRegion] = []
    for idx in range(len(boundaries) - 1):
        xs0 = boundaries[idx]
        xs1 = boundaries[idx + 1]
        if xs1 - xs0 < 8:
            continue
        sub = roi[:, xs0:xs1]
        prof = lane_profile(sub)
        lanes.append(
            LaneRegion(
                index=len(lanes),
                x_start=strip_roi.x + xs0,
                x_end=strip_roi.x + xs1,
                y_start=strip_roi.y,
                y_end=strip_roi.y2,
                profile=tuple(float(v) for v in prof),
            )
        )
    return lanes


def _refine_single_band_box(
    signal_img: np.ndarray,
    lane: LaneRegion,
    prof_smooth: np.ndarray,
    peak_idx: int,
) -> tuple[int, int, int, int]:
    """根据行剖面半高宽/谷底收紧上下界，并根据列能量收紧左右界，返回 (x, y, w, h)。"""
    h_lane = len(prof_smooth)
    peak_val = float(prof_smooth[peak_idx])
    cutoff_y = peak_val * 0.16

    top = peak_idx
    while top > 0 and prof_smooth[top - 1] > cutoff_y:
        if top < peak_idx - 2 and prof_smooth[top - 1] > prof_smooth[top]:
            break
        top -= 1

    bot = peak_idx
    while bot < h_lane - 1 and prof_smooth[bot + 1] > cutoff_y:
        if bot > peak_idx + 2 and prof_smooth[bot + 1] > prof_smooth[bot]:
            break
        bot += 1

    # 适当留出 2px 上下包络余量，确保完整包含条带边缘晕影
    top = max(0, top - 2)
    bot = min(h_lane - 1, bot + 2)
    if bot - top < 8:
        half = 4
        top = max(0, peak_idx - half)
        bot = min(h_lane - 1, peak_idx + half)

    y_abs = lane.y_start + top
    h_abs = max(6, bot - top + 1)

    # 左右边界在泳道内部进一步贴合真实蛋白条带水平范围
    band_patch = signal_img[y_abs : y_abs + h_abs, lane.x_start : lane.x_end]
    col_energy = gaussian_filter1d(np.max(band_patch, axis=0), sigma=1.0)
    cmax = float(np.max(col_energy)) if col_energy.size else 0.0
    if cmax > 1e-6 and col_energy.size > 6:
        active_cols = np.where(col_energy >= cmax * 0.18)[0]
        if active_cols.size >= 4:
            lx = max(0, int(active_cols[0]) - 1)
            rx = min(lane.width, int(active_cols[-1]) + 2)
            if rx - lx >= max(8, int(lane.width * 0.45)):
                return lane.x_start + lx, y_abs, rx - lx, h_abs

    pad_x = max(1, int(lane.width * 0.05))
    return lane.x_start + pad_x, y_abs, max(6, lane.width - 2 * pad_x), h_abs


def detect_bands_in_lanes(
    signal_img: np.ndarray,
    lanes: list[LaneRegion],
    params: AnalysisParams,
) -> list[tuple[int, int, int, int, int, int]]:
    """在每条泳道中检测条带并收紧边界框。

    返回列表元素为 (lane_index, x, y, width, height, peak_y_abs)。
    """
    if not lanes:
        return []

    global_peak = max(
        (max(lane.profile) if lane.profile else 0.0) for lane in lanes
    )
    if global_peak <= 1e-6:
        return []

    raw_detections: list[tuple[int, int, int, int, int, int, float]] = []
    for lane in lanes:
        prof = np.asarray(lane.profile, dtype=np.float64)
        if prof.size < 6:
            continue
        prof_smooth = gaussian_filter1d(prof, sigma=1.5)
        lmax = float(np.max(prof_smooth))
        if lmax < global_peak * 0.04:
            continue

        prom = max(lmax * params.band_prominence, global_peak * 0.05)
        peaks, _ = find_peaks(prof_smooth, distance=12, prominence=prom)
        if peaks.size == 0:
            peaks = np.array([int(np.argmax(prof_smooth))])

        if params.primary_band_only and peaks.size > 1:
            best_p = int(peaks[int(np.argmax(prof_smooth[peaks]))])
            peaks = np.array([best_p])

        for p_idx in peaks:
            bx, by, bw, bh = _refine_single_band_box(signal_img, lane, prof_smooth, int(p_idx))
            peak_y_abs = lane.y_start + int(p_idx)
            raw_detections.append(
                (lane.index, bx, by, bw, bh, peak_y_abs, float(prof_smooth[int(p_idx)]))
            )

    return [(li, bx, by, bw, bh, py) for (li, bx, by, bw, bh, py, _) in raw_detections]


def align_band_rows(
    detections: list[tuple[int, int, int, int, int, int]],
    row_tolerance: int = 18,
) -> list[tuple[int, int, int, int, int, int, int]]:
    """按 peak_y 纵向位置将跨泳道同分子量条带聚类对齐为行 (row_index)。

    返回 (lane_index, row_index, x, y, width, height, peak_y)。
    """
    if not detections:
        return []

    sorted_by_y = sorted(detections, key=lambda d: d[5])
    row_centers: list[float] = []
    row_counts: list[int] = []
    assigned_rows: list[int] = []

    for det in sorted_by_y:
        py = float(det[5])
        if not row_centers or abs(py - row_centers[-1]) > row_tolerance:
            row_centers.append(py)
            row_counts.append(1)
            assigned_rows.append(len(row_centers) - 1)
        else:
            r_idx = len(row_centers) - 1
            n = row_counts[r_idx]
            row_centers[r_idx] = (row_centers[r_idx] * n + py) / (n + 1)
            row_counts[r_idx] = n + 1
            assigned_rows.append(r_idx)

    aligned = [
        (det[0], row_idx, det[1], det[2], det[3], det[4], det[5])
        for det, row_idx in zip(sorted_by_y, assigned_rows)
    ]
    aligned.sort(key=lambda item: (item[1], item[0]))
    return aligned
