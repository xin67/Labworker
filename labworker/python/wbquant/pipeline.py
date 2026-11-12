"""端到端分析流水线：串联读取、预处理、自动圈定、积分定量与 CSV/JSON/标注图导出。"""

from __future__ import annotations

import csv
import json
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw

from .detect import align_band_rows, detect_bands_in_lanes, detect_lanes
from .io import ensure_dark_background, load_image, saturation_mask
from .models import AnalysisParams, AnalysisResult, BandBox, RectROI
from .preprocess import deskew_image, detect_strip_roi, estimate_skew_angle, subtract_background
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

    signal_img, inverted = ensure_dark_background(raw_img, bit_depth=bit_depth)
    sat_mask = saturation_mask(raw_img, bit_depth=bit_depth, inverted_polarity=inverted)

    corrected, _ = subtract_background(signal_img, radius=cfg.rolling_ball_radius)
    strip_roi = custom_strip_roi or detect_strip_roi(
        corrected, threshold_ratio=cfg.strip_threshold
    )

    skew_angle = 0.0
    if cfg.auto_deskew:
        skew_angle = estimate_skew_angle(corrected, roi=strip_roi)
        if abs(skew_angle) >= 0.25:
            signal_img = deskew_image(signal_img, skew_angle)
            corrected = deskew_image(corrected, skew_angle)
            if custom_strip_roi is None:
                strip_roi = detect_strip_roi(corrected, threshold_ratio=cfg.strip_threshold)

    lanes = detect_lanes(
        corrected,
        strip_roi=strip_roi,
        expected_lanes=cfg.expected_lanes,
    )
    raw_boxes = detect_bands_in_lanes(corrected, lanes=lanes, params=cfg)
    aligned = align_band_rows(raw_boxes)
    bands = quantify_bands(
        raw_signal_img=signal_img,
        corrected_img=corrected,
        sat_mask=sat_mask,
        aligned_boxes=aligned,
        control_lane_index=cfg.control_lane_index,
    )

    return AnalysisResult(
        image_path=str(image_path),
        width=w,
        height=h,
        bit_depth=bit_depth,
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
) -> list[BandBox]:
    """当用户在 UI 上手动拖拽微调圈定框后，基于原始像素重新计算精确 IOD 与 Fold Change。"""
    cfg = params or AnalysisParams()
    raw_img, bit_depth = load_image(image_path)
    signal_img, inverted = ensure_dark_background(raw_img, bit_depth=bit_depth)
    sat_mask = saturation_mask(raw_img, bit_depth=bit_depth, inverted_polarity=inverted)
    corrected, _ = subtract_background(signal_img, radius=cfg.rolling_ball_radius)

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
        corrected_img=corrected,
        sat_mask=sat_mask,
        aligned_boxes=aligned,
        control_lane_index=cfg.control_lane_index,
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
    signal_img, _ = ensure_dark_background(raw_img, bit_depth=bit_depth)
    smax = float(np.max(signal_img))
    norm = np.clip(signal_img / (smax if smax > 0 else 1.0), 0.0, 1.0)
    # 转换为发表级白底黑带 8-bit RGB
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
