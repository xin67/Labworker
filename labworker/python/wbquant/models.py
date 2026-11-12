"""领域数据模型：有效膜条区域、泳道、条带圈定框、分析参数与定量结果。"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any


@dataclass(frozen=True)
class RectROI:
    """矩形区域坐标（像素系，左上角为原点）。"""

    x: int
    y: int
    width: int
    height: int

    @property
    def x2(self) -> int:
        return self.x + self.width

    @property
    def y2(self) -> int:
        return self.y + self.height

    def to_dict(self) -> dict[str, Any]:
        return {"x": int(self.x), "y": int(self.y), "width": int(self.width), "height": int(self.height)}


@dataclass(frozen=True)
class LaneRegion:
    """单条泳道区域及其 1D 纵向强度剖面。"""

    index: int
    x_start: int
    x_end: int
    y_start: int
    y_end: int
    profile: tuple[float, ...] = ()

    @property
    def width(self) -> int:
        return self.x_end - self.x_start

    @property
    def x_center(self) -> float:
        return (self.x_start + self.x_end) / 2.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "index": int(self.index),
            "x_start": int(self.x_start),
            "x_end": int(self.x_end),
            "y_start": int(self.y_start),
            "y_end": int(self.y_end),
            "profile": [round(float(v), 3) for v in self.profile],
        }


@dataclass(frozen=True)
class BandBox:
    """自动圈定的单个条带边界框与光密度定量指标。"""

    id: str
    lane_index: int
    row_index: int
    x: int
    y: int
    width: int
    height: int
    peak_y: int
    raw_iod: float
    background_iod: float
    net_iod: float
    normalized_ratio: float = 1.0
    fold_change: float = 1.0
    saturated_ratio: float = 0.0
    is_saturated: bool = False
    is_primary: bool = True

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "lane_index": int(self.lane_index),
            "row_index": int(self.row_index),
            "x": int(self.x),
            "y": int(self.y),
            "width": int(self.width),
            "height": int(self.height),
            "peak_y": int(self.peak_y),
            "raw_iod": round(float(self.raw_iod), 2),
            "background_iod": round(float(self.background_iod), 2),
            "net_iod": round(float(self.net_iod), 2),
            "normalized_ratio": round(float(self.normalized_ratio), 4),
            "fold_change": round(float(self.fold_change), 4),
            "saturated_ratio": round(float(self.saturated_ratio), 4),
            "is_saturated": bool(self.is_saturated),
            "is_primary": bool(self.is_primary),
        }


@dataclass(frozen=True)
class AnalysisParams:
    """WB 条带自动圈定与背景扣除参数。"""

    rolling_ball_radius: int = 50
    expected_lanes: int = 0  # 0 表示全自动推断泳道数
    band_prominence: float = 0.12
    strip_threshold: float = 0.08
    auto_deskew: bool = False
    control_lane_index: int = 0
    primary_band_only: bool = True

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class AnalysisResult:
    """单张 WB 图像完整分析结果。"""

    image_path: str
    width: int
    height: int
    bit_depth: int
    inverted_polarity: bool
    skew_angle: float
    strip_roi: RectROI
    lanes: tuple[LaneRegion, ...]
    bands: tuple[BandBox, ...]
    params: AnalysisParams = field(default_factory=AnalysisParams)

    def to_dict(self) -> dict[str, Any]:
        return {
            "image_path": self.image_path,
            "width": int(self.width),
            "height": int(self.height),
            "bit_depth": int(self.bit_depth),
            "inverted_polarity": bool(self.inverted_polarity),
            "skew_angle": round(float(self.skew_angle), 3),
            "strip_roi": self.strip_roi.to_dict(),
            "lanes": [lane.to_dict() for lane in self.lanes],
            "bands": [band.to_dict() for band in self.bands],
            "params": self.params.to_dict(),
        }
