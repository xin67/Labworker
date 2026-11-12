"""预处理模块：有效膜条区域（Active Strip ROI）定位、Rolling-ball 背景扣除与倾斜校正。"""

from __future__ import annotations

import numpy as np
from scipy.ndimage import binary_opening, gaussian_filter, label, rotate, zoom
from skimage.restoration import rolling_ball

from .models import RectROI


def subtract_background(
    img: np.ndarray,
    radius: int = 50,
) -> tuple[np.ndarray, np.ndarray]:
    """使用 Rolling-ball 算法扣除不均匀背景。

    返回 (扣除背景后的净信号图像, 估计的背景曲面)，不修改输入数组。
    """
    if radius <= 0:
        bg_med = float(np.median(img))
        bg = np.full_like(img, bg_med, dtype=np.float64)
        return np.clip(img - bg, 0.0, None), bg

    h, w = img.shape[:2]
    # 背景曲面是低频平滑场，采用自适应下采样计算球面再双线性插值回原图，耗时 <30ms
    if min(h, w) > 400 and radius >= 24:
        scale = 0.25
    elif min(h, w) > 200 and radius >= 12:
        scale = 0.5
    else:
        scale = 1.0

    if scale < 1.0:
        small = zoom(img, scale, order=1)
        eff_radius = max(3, int(round(radius * scale)))
        bg_small = rolling_ball(small, radius=eff_radius)
        bg = zoom(bg_small, (h / bg_small.shape[0], w / bg_small.shape[1]), order=1)
        bg = bg[:h, :w]
    else:
        bg = rolling_ball(img, radius=max(3, int(radius)))

    corrected = np.clip(img - bg, 0.0, None)
    return corrected, bg


def detect_strip_roi(
    signal_img: np.ndarray,
    threshold_ratio: float = 0.08,
    pad_x: int = 2,
    pad_y: int = 14,
) -> RectROI:
    """自动定位全画幅视野中的有效蛋白条带膜区域（对单条带过曝鲁棒，过滤孤立噪点）。"""
    h, w = signal_img.shape[:2]
    smoothed = gaussian_filter(signal_img, sigma=1.5)
    vmax = float(np.max(smoothed))
    if vmax <= 1e-6:
        return RectROI(x=0, y=0, width=w, height=h)

    # 防止单条带极端过曝拉高全局最大值导致弱条带被漏裁：结合非零像素分位数设定稳健参考峰值
    pos = smoothed[smoothed > vmax * 0.01]
    robust_ref = float(np.percentile(pos, 92)) if pos.size > 50 else vmax
    ref_peak = min(vmax, max(robust_ref * 1.25, vmax * 0.25))

    ratio = max(0.03, min(0.45, threshold_ratio))
    mask = smoothed > (ref_peak * ratio)
    mask = binary_opening(mask, structure=np.ones((3, 5), dtype=bool))
    if not np.any(mask):
        mask = smoothed > (vmax * 0.05)

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
    sub = (
        signal_img[roi.y : roi.y2, roi.x : roi.x2]
        if roi is not None
        else signal_img
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


def deskew_image(img: np.ndarray, angle: float) -> np.ndarray:
    """按指定角度旋转校正图像。"""
    if abs(angle) < 0.1:
        return img.copy()
    return np.clip(
        rotate(img, angle, reshape=False, order=1, mode="constant", cval=0.0),
        0.0,
        None,
    )
