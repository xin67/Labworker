"""端到端分析流水线：串联读取、有效位深/线性化检查、预处理、同步掩膜倾斜校正、自动圈定、积分定量与导出。"""

from __future__ import annotations

import csv
import json
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw

from .detect import align_band_rows, detect_bands_in_lanes, detect_lanes
from .io import (
    detect_effective_bit_depth,
    ensure_dark_background,
    linearize_srgb_array,
    load_image,
    saturation_mask,
)
from .models import AnalysisParams, AnalysisResult, BandBox, RectROI
from .preprocess import (
    deskew_image,
    deskew_mask,
    detect_strip_roi,
    estimate_skew_angle,
    subtract_background,
)
from .quantify import quantify_bands


def analyze_array(
    raw_img: np.ndarray,
    bit_depth: int = 8,
    image_path: str = "<memory>",
    params: AnalysisParams | None = None,
    custom_strip_roi: RectROI | None = None,
) -> AnalysisResult:
    """对内存中的 2D 灰度数组执行完整 WB 自动圈定与定量流水线。"""
    cfg = params or AnalysisParams()
    h, w = raw_img.shape[:2]

    eff_bd, nominal_ceiling = detect_effective_bit_depth(
        raw_img,
        container_bit_depth=bit_depth,
        override=cfg.effective_bit_depth,
    )
    warnings: list[str] = []
    is_nonlinear_8bit = (eff_bd <= 8)
    working_raw = raw_img.astype(np.float64, copy=True)
    if is_nonlinear_8bit:
        if cfg.linearize_srgb:
            working_raw = linearize_srgb_array(working_raw)
            warnings.append(
                "已对 8-bit 图像执行 sRGB 反 Gamma 线性化；发表级科研定量仍建议优先导出原始 16-bit 线性 TIFF。"
            )
        else:
            warnings.append(
                "检测到 8-bit 非线性潜在 sRGB/Gamma 编码图像，定量线性度受限；建议使用原始 16-bit TIFF 或在确认 sRGB 后开启反 Gamma 线性化。"
            )

    # 先在原始像素空间完成极性判定，再对工作数组反相（避免 sRGB 反 Gamma 压缩白底导致极性翻转）
    signal_img, inverted = ensure_dark_background(
        working_raw,
        bit_depth=bit_depth,
        effective_bit_depth=eff_bd,
        raw_for_polarity=raw_img,
    )
    # 饱和判定基于原始读数，避免反 Gamma 线性化改变 254/255 阈值
    sat_mask = saturation_mask(
        raw_img,
        bit_depth=bit_depth,
        inverted_polarity=inverted,
        effective_bit_depth=eff_bd,
    )

    if cfg.background_mode == "localTrapezoid":
        corrected_signed = signal_img.copy()
    else:
        corrected_signed, _ = subtract_background(
            signal_img,
            radius=cfg.rolling_ball_radius,
            clip_negative=False,
            intensity_range=None,
        )
    corrected_detect = np.clip(corrected_signed, 0.0, None)
    strip_roi = custom_strip_roi or detect_strip_roi(
        corrected_detect, threshold_ratio=cfg.strip_threshold
    )

    skew_angle = 0.0
    if cfg.auto_deskew:
        skew_angle = estimate_skew_angle(corrected_detect, roi=strip_roi)
        if abs(skew_angle) >= 0.25:
            signal_img = deskew_image(signal_img, skew_angle, clip_negative=True)
            corrected_signed = deskew_image(corrected_signed, skew_angle, clip_negative=False)
            corrected_detect = np.clip(corrected_signed, 0.0, None)
            # 同步旋转饱和像素掩膜，避免过曝标记与旋转后条带错位
            sat_mask = deskew_mask(sat_mask, skew_angle)
            if custom_strip_roi is None:
                strip_roi = detect_strip_roi(corrected_detect, threshold_ratio=cfg.strip_threshold)

    lanes = detect_lanes(
        corrected_detect,
        strip_roi=strip_roi,
        expected_lanes=cfg.expected_lanes,
    )
    raw_boxes = detect_bands_in_lanes(corrected_detect, lanes=lanes, params=cfg)
    aligned = align_band_rows(raw_boxes)
    bands = quantify_bands(
        raw_signal_img=signal_img,
        corrected_img=corrected_signed,
        sat_mask=sat_mask,
        aligned_boxes=aligned,
        control_lane_index=cfg.control_lane_index,
        background_mode=cfg.background_mode,
        saturation_ratio_threshold=cfg.saturation_ratio_threshold,
    )

    return AnalysisResult(
        image_path=str(image_path),
        width=w,
        height=h,
        bit_depth=bit_depth,
        effective_bit_depth=eff_bd,
        is_nonlinear_8bit_warning=is_nonlinear_8bit,
        warnings=tuple(warnings),
        inverted_polarity=inverted,
        skew_angle=skew_angle,
        strip_roi=strip_roi,
        lanes=tuple(lanes),
        bands=tuple(bands),
        params=cfg,
    )


def analyze_blot(
    image_path: str | Path,
    params: AnalysisParams | None = None,
    custom_strip_roi: RectROI | None = None,
) -> AnalysisResult:
    """读取指定路径的 WB 图像并执行完整自动圈定与定量。"""
    p = Path(image_path)
    raw_img, bit_depth = load_image(p)
    return analyze_array(
        raw_img=raw_img,
        bit_depth=bit_depth,
        image_path=str(p.resolve()),
        params=params,
        custom_strip_roi=custom_strip_roi,
    )


def requantify_boxes(
    image_path: str | Path,
    boxes: list[dict[str, Any]],
    params: AnalysisParams | None = None,
    skew_angle: float = 0.0,
) -> list[BandBox]:
    """当用户在 UI 上手动拖拽微调圈定框后，基于原始像素（含一致的倾斜旋转与饱和掩膜变换）重新计算精确 IOD。"""
    cfg = params or AnalysisParams()
    raw_img, bit_depth = load_image(image_path)
    eff_bd, nominal_ceiling = detect_effective_bit_depth(raw_img, container_bit_depth=bit_depth, override=cfg.effective_bit_depth)
    working_raw = linearize_srgb_array(raw_img) if (eff_bd <= 8 and cfg.linearize_srgb) else raw_img
    signal_img, inverted = ensure_dark_background(working_raw, bit_depth=bit_depth, effective_bit_depth=eff_bd, raw_for_polarity=raw_img)
    sat_mask = saturation_mask(raw_img, bit_depth=bit_depth, inverted_polarity=inverted, effective_bit_depth=eff_bd)
    if cfg.background_mode == "localTrapezoid":
        corrected_signed = signal_img.copy()
    else:
        corrected_signed, _ = subtract_background(signal_img, radius=cfg.rolling_ball_radius, clip_negative=False, intensity_range=None)

    angle = float(skew_angle)
    if abs(angle) < 0.25 and cfg.auto_deskew:
        corrected_detect = np.clip(corrected_signed, 0.0, None)
        strip_roi = detect_strip_roi(corrected_detect, threshold_ratio=cfg.strip_threshold)
        angle = estimate_skew_angle(corrected_detect, roi=strip_roi)
    if abs(angle) >= 0.25:
        signal_img = deskew_image(signal_img, angle, clip_negative=True)
        corrected_signed = deskew_image(corrected_signed, angle, clip_negative=False)
        sat_mask = deskew_mask(sat_mask, angle)

    aligned: list[tuple[int, int, int, int, int, int, int]] = []
    for idx, b in enumerate(boxes):
        li = int(b.get("lane_index", idx))
        ri = int(b.get("row_index", 0))
        bx = int(b["x"])
        by = int(b["y"])
        bw = max(4, int(b["width"]))
        bh = max(4, int(b["height"]))
        py = int(b.get("peak_y", by + bh // 2))
        aligned.append((li, ri, bx, by, bw, bh, py))

    return quantify_bands(
        raw_signal_img=signal_img,
        corrected_img=corrected_signed,
        sat_mask=sat_mask,
        aligned_boxes=aligned,
        control_lane_index=cfg.control_lane_index,
        background_mode=cfg.background_mode,
        saturation_ratio_threshold=cfg.saturation_ratio_threshold,
    )


def export_csv(result: AnalysisResult, out_path: str | Path) -> Path:
    """将条带定量结果导出为可直接导入 Prism / Excel 的 CSV 表格。"""
    dest = Path(out_path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    with dest.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.writer(f)
        writer.writerow([
            "Band_ID",
            "Lane",
            "Row",
            "X",
            "Y",
            "Width",
            "Height",
            "Peak_Y",
            "Raw_IOD",
            "Background_IOD",
            "Net_IOD",
            "Normalized_Ratio",
            "Fold_Change",
            "Saturated_Ratio",
            "Is_Saturated",
            "SNR",
        ])
        for b in result.bands:
            writer.writerow([
                b.id,
                b.lane_index + 1,
                b.row_index + 1,
                b.x,
                b.y,
                b.width,
                b.height,
                b.peak_y,
                f"{b.raw_iod:.2f}",
                f"{b.background_iod:.2f}",
                f"{b.net_iod:.2f}",
                f"{b.normalized_ratio:.4f}",
                f"{b.fold_change:.4f}",
                f"{b.saturated_ratio:.4f}",
                "YES" if b.is_saturated else "NO",
                f"{b.snr:.2f}",
            ])
    return dest


def export_json(result: AnalysisResult, out_path: str | Path) -> Path:
    """导出包含全部处理参数、泳道剖面与条带坐标的可复现 JSON 存档。"""
    dest = Path(out_path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(
        json.dumps(result.to_dict(), ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return dest


def export_annotated_png(result: AnalysisResult, out_path: str | Path) -> Path:
    """导出叠加有效膜区域、泳道分界线与自动圈定框的可视化 PNG（白底黑带发表级样式）。"""
    raw_img, bit_depth = load_image(result.image_path)
    signal_img, _ = ensure_dark_background(raw_img, bit_depth=bit_depth, effective_bit_depth=result.effective_bit_depth)
    if abs(result.skew_angle) >= 0.25:
        signal_img = deskew_image(signal_img, result.skew_angle, clip_negative=True)
    smax = float(np.max(signal_img))
    norm = np.clip(signal_img / (smax if smax > 0 else 1.0), 0.0, 1.0)
    vis_u8 = ((1.0 - norm) * 255.0).astype(np.uint8)
    rgb = np.stack([vis_u8, vis_u8, vis_u8], axis=-1)
    pil_img = Image.fromarray(rgb)
    draw = ImageDraw.Draw(pil_img)

    sr = result.strip_roi
    draw.rectangle(
        [sr.x, sr.y, sr.x2, sr.y2],
        outline=(90, 150, 240),
        width=2,
    )
    for lane in result.lanes:
        draw.line(
            [(lane.x_start, sr.y), (lane.x_start, sr.y2)],
            fill=(120, 175, 245),
            width=1,
        )
    for band in result.bands:
        color = (235, 68, 55) if band.is_saturated else (28, 185, 105)
        draw.rectangle(
            [band.x, band.y, band.x + band.width, band.y + band.height],
            outline=color,
            width=2,
        )

    dest = Path(out_path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    pil_img.save(dest)
    return dest
