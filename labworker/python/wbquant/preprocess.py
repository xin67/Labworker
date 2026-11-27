"""预处理模块：有效膜条区域（Active Strip ROI）定位、抗混叠 Rolling-ball 背景扣除与倾斜校正（同步掩膜旋转）。"""

from __future__ import annotations

import numpy as np
from scipy.ndimage import binary_opening, gaussian_filter, label, rotate, uniform_filter, zoom
try:
    from skimage.restoration import ellipsoid_kernel, rolling_ball
except ImportError:
    ellipsoid_kernel = None
    rolling_ball = None

from .models import RectROI


def _downsample_area_average(img: np.ndarray, factor: int) -> np.ndarray:
    """盒式/区域平均抗混叠降采样，与 Swift 原生引擎严格等价。"""
    if factor <= 1:
        return img.astype(np.float64, copy=True)
    h, w = img.shape[:2]
    sh = max(4, h // factor)
    sw = max(4, w // factor)
    # 先用盒式均值滤波再裁剪整数倍块求平均
    cropped = img[: sh * factor, : sw * factor]
    return cropped.reshape(sh, factor, sw, factor).mean(axis=(1, 3))


def subtract_background(
    img: np.ndarray,
    radius: int = 50,
    clip_negative: bool = False,
    intensity_range: float | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """使用真 2D 椭球面 Rolling-ball 算法（Sternberg 1983）扣除不均匀背景。

    空间半轴 r_xy = radius / factor，强度半轴 R_z = radius * (intensity_range / 255.0)
    与降采样因子完全解耦，确保 [0,1] / 8-bit / 12-bit / 14-bit / 16-bit 及不同高度下曲率一致。
    """
    if radius <= 0:
        bg_med = float(np.median(img))
        bg = np.full_like(img, bg_med, dtype=np.float64)
        diff = img - bg
        return (np.clip(diff, 0.0, None) if clip_negative else diff), bg

    if ellipsoid_kernel is None or rolling_ball is None:
        raise ImportError("scikit-image is required for wbquant.preprocess.subtract_background")

    if intensity_range is not None and intensity_range > 0:
        eff_range = float(intensity_range)
    elif img.size > 0:
        flat = img.ravel()
        if flat.size > 250_000:
            step = max(1, flat.size // 100_000)
            flat = flat[::step]
        p_lo, p_hi = np.percentile(flat, [0.2, 99.8])
        span_pct = float(p_hi - p_lo)
        if span_pct > 1e-6:
            eff_range = span_pct
        else:
            span_mm = float(np.max(flat) - np.min(flat))
            eff_range = span_mm if span_mm > 1e-6 else 1.0
    else:
        eff_range = 1.0

    # 将图像线性缩放至 [0, 255] 等价量纲，使强度半轴 R_z 恒为 radius（与降采样因子 factor 解耦）
    scale_to_255 = 255.0 / eff_range
    img_scaled = img.astype(np.float64) * scale_to_255

    h, w = img.shape[:2]
    if min(h, w) > 360 and radius >= 24:
        factor = 4
    elif min(h, w) > 180 and radius >= 12:
        factor = 2
    else:
        factor = 1

    if factor > 1:
        small = _downsample_area_average(img_scaled, factor)
        eff_radius = max(2, int(round(radius / factor)))
        # skimage.restoration.ellipsoid_kernel 接收主轴全长（直径 = 2*r_xy, 2*R_z）
        kernel = ellipsoid_kernel((2 * eff_radius, 2 * eff_radius), 2.0 * float(radius))
        bg_small = rolling_ball(small, kernel=kernel)
        bg_scaled = zoom(bg_small, (h / bg_small.shape[0], w / bg_small.shape[1]), order=1)
        bg_scaled = bg_scaled[:h, :w]
    else:
        r_int = max(2, int(radius))
        bg_scaled = rolling_ball(img_scaled, radius=r_int)

    bg = bg_scaled / scale_to_255
    diff = img - bg
    corrected = np.clip(diff, 0.0, None) if clip_negative else diff
    return corrected, bg


def detect_strip_roi(
    signal_img: np.ndarray,
    threshold_ratio: float = 0.08,
    pad_x: int = 2,
    pad_y: int = 14,
) -> RectROI:
    """自动定位全画幅视野中的有效蛋白条带膜区域（对单条带过曝鲁棒，过滤孤立噪点）。"""
    h, w = signal_img.shape[:2]
    pos_img = np.clip(signal_img, 0.0, None)
    smoothed = gaussian_filter(pos_img, sigma=1.5)
    vmax = float(np.max(smoothed))
    if vmax <= 1e-6:
        return RectROI(x=0, y=0, width=w, height=h)

    pos = smoothed[smoothed > vmax * 0.01]
    ref_peak = min(vmax, float(np.percentile(pos, 92)) * 1.25) if pos.size > 50 else vmax

    ratio = max(0.03, min(0.45, threshold_ratio))
    mask = smoothed > (ref_peak * ratio)
    mask = binary_opening(mask, structure=np.ones((3, 5), dtype=bool))
    if not np.any(mask):
        mask = smoothed > (ref_peak * 0.05)

    labeled, num_features = label(mask)
    if num_features > 1:
        comp_areas = np.array(
            [int(np.sum(labeled == idx)) for idx in range(1, num_features + 1)]
        )
        max_area = int(np.max(comp_areas)) if comp_areas.size > 0 else 0
        valid_labels = {
            idx + 1 for idx, area in enumerate(comp_areas) if area >= max(25, int(max_area * 0.08))
        }
        mask = np.isin(labeled, list(valid_labels))

    ys, xs = np.where(mask)
    if ys.size == 0 or xs.size == 0:
        return RectROI(x=0, y=0, width=w, height=h)

    x0 = max(0, int(np.min(xs)) - pad_x)
    x1 = min(w, int(np.max(xs)) + 1 + pad_x)
    y0 = max(0, int(np.min(ys)) - pad_y)
    y1 = min(h, int(np.max(ys)) + 1 + pad_y)
    return RectROI(x=x0, y=y0, width=max(1, x1 - x0), height=max(1, y1 - y0))


def estimate_skew_angle(
    signal_img: np.ndarray,
    roi: RectROI | None = None,
    max_angle: float = 4.0,
) -> float:
    """基于行投影梯度能量最大化估计条带微倾斜角度（度）。"""
    pos_img = np.clip(signal_img, 0.0, None)
    sub = (
        pos_img[roi.y : roi.y2, roi.x : roi.x2]
        if roi is not None
        else pos_img
    )
    if min(sub.shape[:2]) < 20:
        return 0.0

    angles = np.linspace(-max_angle, max_angle, 33)
    best_angle = 0.0
    best_score = -1.0
    for ang in angles:
        rot = rotate(sub, ang, reshape=False, order=1, mode="constant", cval=0.0)
        row_prof = np.sum(rot, axis=1)
        grad_energy = float(np.sum(np.diff(row_prof) ** 2))
        if grad_energy > best_score:
            best_score = grad_energy
            best_angle = float(ang)
    return best_angle if abs(best_angle) >= 0.25 else 0.0


def deskew_image(img: np.ndarray, angle: float, clip_negative: bool = False) -> np.ndarray:
    """按指定角度旋转校正图像。"""
    if abs(angle) < 0.1:
        return img.copy()
    rot = rotate(img, angle, reshape=False, order=1, mode="constant", cval=0.0)
    return np.clip(rot, 0.0, None) if clip_negative else rot


def deskew_mask(mask: np.ndarray, angle: float) -> np.ndarray:
    """使用完全相同的旋转角度与最近邻插值同步旋转布尔饱和像素掩膜，避免过曝标记错位。"""
    if abs(angle) < 0.1:
        return mask.astype(bool, copy=True)
    rot = rotate(mask.astype(np.float64), angle, reshape=False, order=0, mode="constant", cval=0.0)
    return rot > 0.5
