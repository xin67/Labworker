"""图像读取、位深识别、极性标准化、过曝掩膜检测与同批次曝光图像自动配对。"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import numpy as np
import tifffile
from PIL import Image


def load_image(path: str | Path) -> tuple[np.ndarray, int]:
    """读取 16-bit/8-bit TIFF 或 PNG 图像，返回 (2D float64 灰度数组, 位深 8 或 16)。"""
    file_path = Path(path)
    suffix = file_path.suffix.lower()
    if suffix in {".tif", ".tiff"}:
        arr = tifffile.imread(str(file_path))
    else:
        with Image.open(file_path) as im:
            arr = np.asarray(im)

    bit_depth = 16 if arr.dtype == np.uint16 or np.max(arr) > 255 else 8
    img = arr.astype(np.float64)
    if img.ndim == 3:
        img = img[..., :3].mean(axis=2)
    return img, bit_depth


def ensure_dark_background(img: np.ndarray, bit_depth: int = 8) -> tuple[np.ndarray, bool]:
    """确保输出图像为暗背景、亮条带（数值越大代表蛋白信号越强）。

    返回 (转换后 float64 数组, 是否执行了反相)。
    """
    med = float(np.median(img))
    vmin, vmax = float(np.min(img)), float(np.max(img))
    mid = (vmin + vmax) * 0.5
    if med > mid:
        ceiling = float((1 << bit_depth) - 1) if vmax <= ((1 << bit_depth) - 1) else vmax
        return np.clip(ceiling - img, 0.0, None), True
    return img.copy(), False


def saturation_mask(
    raw_img: np.ndarray,
    bit_depth: int = 8,
    inverted_polarity: bool = False,
) -> np.ndarray:
    """检测过曝/饱和像素掩膜（True 表示该像素已达成像仪动态范围上限）。"""
    if bit_depth == 16:
        if inverted_polarity:
            return raw_img <= 15.0
        return raw_img >= 65400.0
    if inverted_polarity:
        return raw_img <= 1.0
    return raw_img >= 254.0


def discover_sample_groups(directory: str | Path) -> list[dict[str, Any]]:
    """扫描目录并将同一次曝光批次的原始发光图、发光图、明场图、叠加图自动配对成组。"""
    folder = Path(directory)
    files = sorted(
        p for p in folder.iterdir()
        if p.is_file() and p.suffix.lower() in {".tif", ".tiff", ".png", ".jpg", ".jpeg"}
        and not p.name.startswith("参考")
    )
    groups: dict[str, dict[str, Any]] = {}
    role_patterns = [
        ("raw_chemi", "_原始文件_发光图"),
        ("chemi", "_发光图"),
        ("brightfield", "_明场图"),
        ("overlay", "_叠加图"),
    ]

    for f in files:
        stem = f.stem
        matched_role = "chemi"
        base_key = stem
        for role, suffix_tag in role_patterns:
            if stem.endswith(suffix_tag):
                matched_role = role
                base_key = stem[: -len(suffix_tag)]
                break

        if base_key not in groups:
            # 提取简短可读标题，如 gapdh_20260714_124017899 -> GAPDH · 07-14 12:40
            m = re.match(r"^([A-Za-z0-9_-]+?)_(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})", base_key)
            if m:
                target, _, mm, dd, hh, minu = m.groups()
                display_title = f"{target.upper()} · {mm}/{dd} {hh}:{minu}"
            else:
                display_title = base_key
            groups[base_key] = {
                "id": base_key,
                "title": display_title,
                "raw_chemi": None,
                "chemi": None,
                "brightfield": None,
                "overlay": None,
                "primary_quant_path": None,
            }
        groups[base_key][matched_role] = str(f.resolve())

    result: list[dict[str, Any]] = []
    for g in groups.values():
        # 优先使用 16-bit 原始发光图做定量，其次使用常规发光图
        primary = g["raw_chemi"] or g["chemi"] or g["overlay"] or g["brightfield"]
        if primary:
            g["primary_quant_path"] = primary
            result.append(g)
    return result
