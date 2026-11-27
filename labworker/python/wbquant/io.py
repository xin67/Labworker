"""图像读取、真实有效位深识别 (12/14/16-bit)、sRGB 反 Gamma 线性化、稳健极性标准化与过曝掩膜检测。"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import numpy as np
import tifffile
from PIL import Image


def load_image(path: str | Path) -> tuple[np.ndarray, int]:
    """读取 16-bit/8-bit TIFF 或 PNG 图像，返回 (2D float64 灰度数组, 容器位深 8 或 16)。"""
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


def detect_effective_bit_depth(
    raw_img: np.ndarray,
    container_bit_depth: int = 16,
    override: int | None = None,
    metadata_max_sample_value: int | None = None,
) -> tuple[int, float]:
    """识别真实有效位深与饱和天花板：
    严禁将 uint16 容器降级为 8-bit 非线性 sRGB；仅当 TIFF 元数据声明或存在多像素
    精准钉死在 4095 / 16383 硬件截断边界时推断 12/14-bit。返回 (effective_bit_depth, ceiling)。
    """
    if override is not None and override in (8, 12, 14, 16):
        return override, float((1 << override) - 1)
    if container_bit_depth <= 8:
        return 8, 255.0
    if metadata_max_sample_value is not None:
        if metadata_max_sample_value == 4095:
            return 12, 4095.0
        if metadata_max_sample_value == 16383:
            return 14, 16383.0
        if metadata_max_sample_value >= 65535:
            return 16, 65535.0

    vmax = float(np.max(raw_img)) if raw_img.size > 0 else 0.0
    if abs(vmax - 4095.0) <= 0.5:
        pinned = int(np.sum(np.abs(raw_img - 4095.0) <= 0.5))
        if pinned >= 3:
            return 12, 4095.0
    if abs(vmax - 16383.0) <= 0.5:
        pinned = int(np.sum(np.abs(raw_img - 16383.0) <= 0.5))
        if pinned >= 3:
            return 14, 16383.0
    return 16, 65535.0


def linearize_srgb_array(img: np.ndarray) -> np.ndarray:
    """对标准 8-bit sRGB 非线性编码图像执行 IEC 61966-2-1 反 Gamma 线性化（输出仍在 0..255 量纲）。"""
    u = np.clip(img.astype(np.float64) / 255.0, 0.0, 1.0)
    lin = np.where(u <= 0.04045, u / 12.92, np.power((u + 0.055) / 1.055, 2.4))
    return lin * 255.0


def detect_bright_background_polarity(raw_img: np.ndarray) -> bool:
    """在原始像素空间（反 sRGB 之前）稳健判定明底黑带极性。
    外框 8% 几乎全零（zero-padded 暗场膜）时直接判为暗底（False），绝不以高亮带中位数冒充背景。
    """
    h, w = raw_img.shape[:2]
    vmax = float(np.max(raw_img)) if raw_img.size > 0 else 0.0
    if vmax <= 1e-12:
        return False

    bw = max(2, int(round(w * 0.08)))
    bh = max(2, int(round(h * 0.08)))
    border_mask = np.zeros((h, w), dtype=bool)
    border_mask[:bh, :] = True
    border_mask[h - bh :, :] = True
    border_mask[:, :bw] = True
    border_mask[:, w - bw :] = True
    border_nz = raw_img[border_mask & (raw_img > 0.0)]
    if border_nz.size < 8:
        return False

    nz = raw_img[raw_img > 0.0]
    if nz.size < 16:
        return False
    p01, p99 = float(np.percentile(nz, 1)), float(np.percentile(nz, 99))
    span = p99 - p01
    if span <= 1e-9:
        return False

    border_med = float(np.median(border_nz))
    hist, edges = np.histogram(nz, bins=256, range=(p01, p99))
    mode_idx = int(np.argmax(hist))
    mode_val = 0.5 * (float(edges[mode_idx]) + float(edges[mode_idx + 1]))
    mid = p01 + 0.5 * span
    return (mode_val > mid) and (border_med > mid)


def ensure_dark_background(
    img: np.ndarray,
    bit_depth: int = 8,
    effective_bit_depth: int | None = None,
    raw_for_polarity: np.ndarray | None = None,
) -> tuple[np.ndarray, bool]:
    """确保输出图像为暗背景、亮条带（数值越大代表蛋白信号越强）。
    先在原始像素空间完成极性判定，再对当前工作图像执行反相，避免 sRGB 线性化扭曲极性。
    """
    pol_src = raw_for_polarity if raw_for_polarity is not None else img
    _, ceiling_nominal = detect_effective_bit_depth(pol_src, container_bit_depth=bit_depth, override=effective_bit_depth)
    inverted = detect_bright_background_polarity(pol_src)
    if inverted:
        vmax = float(np.max(img)) if img.size > 0 else 0.0
        ceiling = ceiling_nominal if vmax <= ceiling_nominal else vmax
        return np.clip(ceiling - img, 0.0, None), True
    return img.copy(), False


def saturation_mask(
    raw_img: np.ndarray,
    bit_depth: int = 8,
    inverted_polarity: bool = False,
    effective_bit_depth: int | None = None,
) -> np.ndarray:
    """检测过曝/饱和像素掩膜（依据真实有效位深 8/12/14/16-bit 饱和天花板，12/14-bit 严禁放宽至 4085/16350）。"""
    eff_bd, ceiling = detect_effective_bit_depth(raw_img, container_bit_depth=bit_depth, override=effective_bit_depth)
    if eff_bd == 16:
        lo_cut, hi_cut = 15.0, 65400.0
    elif eff_bd == 14:
        lo_cut, hi_cut = 1.0, 16382.5
    elif eff_bd == 12:
        lo_cut, hi_cut = 1.0, 4094.5
    else:
        lo_cut, hi_cut = 1.0, 254.0

    if inverted_polarity:
        return raw_img <= lo_cut
    return raw_img >= min(hi_cut, ceiling)


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
        primary = g["raw_chemi"] or g["chemi"] or g["overlay"] or g["brightfield"]
        if primary:
            g["primary_quant_path"] = primary
            result.append(g)
    return result
