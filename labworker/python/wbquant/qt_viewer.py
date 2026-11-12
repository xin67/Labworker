"""基于 PySide6 + pyqtgraph 的交互式科学视窗：支持可拖拽 RectROI 圈定框与实时 1D 密度积分曲线。"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

from .io import ensure_dark_background, load_image
from .models import AnalysisParams
from .pipeline import analyze_blot, export_csv, requantify_boxes


def launch_qt_viewer(
    image_path: str | Path,
    params: AnalysisParams | None = None,
) -> int:
    """启动 PySide6 + pyqtgraph 科学密度分析视窗。"""
    try:
        import pyqtgraph as pg
        from PySide6 import QtCore, QtGui, QtWidgets
    except ImportError as exc:
        sys.stderr.write(
            f"[wbquant] 启动 PySide6 + pyqtgraph 视窗需要安装 Qt 依赖 (uv sync --extra qt): {exc}\n"
        )
        return 1

    pg.setConfigOptions(imageAxisOrder="row-major", antialias=True)
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(sys.argv)
    app.setStyle("Fusion")

    # 深色 macOS 27 协调配色
    palette = QtGui.QPalette()
    palette.setColor(QtGui.QPalette.ColorRole.Window, QtGui.QColor(30, 31, 35))
    palette.setColor(QtGui.QPalette.ColorRole.WindowText, QtGui.QColor(238, 240, 245))
    palette.setColor(QtGui.QPalette.ColorRole.Base, QtGui.QColor(22, 23, 26))
    palette.setColor(QtGui.QPalette.ColorRole.Text, QtGui.QColor(238, 240, 245))
    palette.setColor(QtGui.QPalette.ColorRole.Button, QtGui.QColor(44, 46, 52))
    palette.setColor(QtGui.QPalette.ColorRole.ButtonText, QtGui.QColor(238, 240, 245))
    app.setPalette(palette)

    cfg = params or AnalysisParams()
    img_file = Path(image_path)
    raw_img, bit_depth = load_image(img_file)
    signal_img, _ = ensure_dark_background(raw_img, bit_depth=bit_depth)
    result = analyze_blot(img_file, params=cfg)

    win = QtWidgets.QMainWindow()
    win.setWindowTitle(f"WBStudio · pyqtgraph 科学密度工作台 — {img_file.name}")
    win.resize(1220, 780)

    central = QtWidgets.QWidget()
    win.setCentralWidget(central)
    root_layout = QtWidgets.QVBoxLayout(central)
    root_layout.setContentsMargins(12, 12, 12, 12)
    root_layout.setSpacing(10)

    # 顶部精简胶囊工具栏
    toolbar = QtWidgets.QHBoxLayout()
    toolbar.setSpacing(10)
    lbl_info = QtWidgets.QLabel(
        f"{img_file.name}  ·  {result.width}×{result.height} ({result.bit_depth}-bit)  ·  "
        f"{len(result.lanes)} 泳道 / {len(result.bands)} 条带"
    )
    lbl_info.setStyleSheet("font-weight: 600; color: #E5E7EB;")
    toolbar.addWidget(lbl_info)
    toolbar.addStretch(1)

    btn_export = QtWidgets.QPushButton("导出 CSV")
    btn_export.setCursor(QtCore.Qt.CursorShape.PointingHandCursor)
    btn_export.setStyleSheet(
        "QPushButton { background: #2563EB; color: white; border-radius: 6px; padding: 5px 14px; font-weight: 600; }"
    )
    toolbar.addWidget(btn_export)
    root_layout.addLayout(toolbar)

    splitter = QtWidgets.QSplitter(QtCore.Qt.Orientation.Vertical)
    root_layout.addWidget(splitter, stretch=1)

    # 上半部分：WB 原图与可拖拽 pyqtgraph RectROI 圈定框
    img_plot = pg.PlotWidget(title="")
    img_plot.setBackground((20, 21, 24))
    img_plot.getViewBox().invertY(True)
    img_plot.getViewBox().setAspectLocked(True)
    smax = float(np.max(signal_img)) or 1.0
    vis_img = (1.0 - np.clip(signal_img / smax, 0.0, 1.0)) * 255.0
    img_item = pg.ImageItem(vis_img)
    img_plot.addItem(img_item)
    splitter.addWidget(img_plot)

    # 下半部分：左 1D 泳道剖面积分曲线 + 右 Fold Change 柱状图
    bottom_split = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
    profile_plot = pg.PlotWidget(title="")
    profile_plot.setBackground((24, 25, 29))
    profile_plot.showGrid(x=True, y=True, alpha=0.2)

    bar_plot = pg.PlotWidget(title="")
    bar_plot.setBackground((24, 25, 29))
    bar_plot.showGrid(x=False, y=True, alpha=0.2)

    bottom_split.addWidget(profile_plot)
    bottom_split.addWidget(bar_plot)
    splitter.addWidget(bottom_split)
    splitter.setSizes([460, 280])

    # 绘制有效膜区域框
    sr = result.strip_roi
    strip_rect = QtWidgets.QGraphicsRectItem(sr.x, sr.y, sr.width, sr.height)
    strip_rect.setPen(pg.mkPen((96, 165, 250, 170), width=1.5, style=QtCore.Qt.PenStyle.DashLine))
    img_plot.addItem(strip_rect)
    img_plot.setXRange( max(0, sr.x - 40), min(result.width, sr.x2 + 40), padding=0)
    img_plot.setYRange(max(0, sr.y - 35), min(result.height, sr.y2 + 35), padding=0)

    roi_items: list[tuple[int, pg.RectROI]] = []
    current_bands = list(result.bands)

    def refresh_charts(selected_lane: int = 0) -> None:
        profile_plot.clear()
        if 0 <= selected_lane < len(result.lanes):
            lane = result.lanes[selected_lane]
            ys = np.arange(lane.y_start, lane.y_end)
            prof = np.asarray(lane.profile, dtype=np.float64)
            if ys.size == prof.size and prof.size > 0:
                curve = profile_plot.plot(
                    ys,
                    prof,
                    pen=pg.mkPen((56, 189, 248), width=2),
                    fillLevel=0,
                    brush=(56, 189, 248, 55),
                )
                _ = curve

        bar_plot.clear()
        if current_bands:
            xs = np.arange(1, len(current_bands) + 1)
            fcs = np.array([b.fold_change for b in current_bands], dtype=np.float64)
            brushes = [
                pg.mkBrush(239, 68, 68, 210) if b.is_saturated else pg.mkBrush(52, 211, 153, 210)
                for b in current_bands
            ]
            bg_item = pg.BarGraphItem(x=xs, height=fcs, width=0.55, brushes=brushes)
            bar_plot.addItem(bg_item)

    def on_roi_changed() -> None:
        nonlocal current_bands
        payload = []
        for idx, (lane_idx, r_item) in enumerate(roi_items):
            pos = r_item.pos()
            size = r_item.size()
            payload.append({
                "lane_index": lane_idx,
                "row_index": 0,
                "x": int(round(pos.x())),
                "y": int(round(pos.y())),
                "width": max(4, int(round(size.x()))),
                "height": max(4, int(round(size.y()))),
            })
        current_bands = requantify_boxes(img_file, payload, params=cfg)
        refresh_charts(0)

    for band in result.bands:
        pen_color = (239, 68, 68) if band.is_saturated else (16, 185, 129)
        roi = pg.RectROI(
            [band.x, band.y],
            [band.width, band.height],
            pen=pg.mkPen(pen_color, width=2),
            hoverPen=pg.mkPen((250, 204, 21), width=2.5),
        )
        roi.sigRegionChangeFinished.connect(on_roi_changed)
        img_plot.addItem(roi)
        roi_items.append((band.lane_index, roi))

    def on_export() -> None:
        out_csv = img_file.with_suffix(".quant.csv")
        from dataclasses import replace as dc_replace
        updated_res = dc_replace(result, bands=tuple(current_bands))
        export_csv(updated_res, out_csv)
        QtWidgets.QMessageBox.information(win, "导出完成", f"已导出至:\n{out_csv}")

    btn_export.clicked.connect(on_export)
    refresh_charts(0)
    win.show()
    return int(app.exec())
