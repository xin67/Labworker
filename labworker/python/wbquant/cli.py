"""命令行与双引擎 JSON 桥接入口 (wbquant CLI)。"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .io import discover_sample_groups
from .models import AnalysisParams, RectROI
from .pipeline import analyze_blot, export_annotated_png, export_csv, export_json, requantify_boxes
from .qt_viewer import launch_qt_viewer


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="wbquant", description="WB 条带自动圈定与光密度定量引擎")
    sub = parser.add_subparsers(dest="cmd", required=True)

    # 1. analyze: 分析单张图像并输出 JSON (供 CLI 与 SwiftUI 桥接调用)
    p_ana = sub.add_parser("analyze", help="自动圈定并定量单张 WB 图像")
    p_ana.add_argument("image", help="输入 TIFF/PNG 图像路径")
    p_ana.add_argument("--lanes", type=int, default=0, help="指定泳道数 (0 为自动识别)")
    p_ana.add_argument("--radius", type=int, default=50, help="Rolling-ball 背景球半径")
    p_ana.add_argument("--prominence", type=float, default=0.12, help="条带峰值显著性阈值 (0.02~0.5)")
    p_ana.add_argument("--threshold", type=float, default=0.08, help="有效膜区域激活阈值 (0.02~0.4)")
    p_ana.add_argument("--control-lane", type=int, default=0, help="对照泳道索引 (0-based)")
    p_ana.add_argument("--all-bands", action="store_true", help="检测泳道内所有显著条带而非仅主条带")
    p_ana.add_argument("--deskew", action="store_true", help="启用自动微倾斜校正")
    p_ana.add_argument("--roi", type=str, default="", help="手动指定膜区域 x,y,w,h")
    p_ana.add_argument("--out-csv", type=str, default="", help="可选：导出 CSV 路径")
    p_ana.add_argument("--out-json", type=str, default="", help="可选：导出 JSON 路径")
    p_ana.add_argument("--out-png", type=str, default="", help="可选：导出标注图 PNG 路径")

    # 2. discover: 扫描目录并自动配对同批次发光图/明场图/叠加图
    p_disc = sub.add_parser("discover", help="扫描目录并自动配对 WB 曝光组")
    p_disc.add_argument("directory", help="扫描文件夹路径")

    # 3. requantify: 根据手动调整后的圈定框 JSON 重新计算 IOD
    p_req = sub.add_parser("requantify", help="基于自定义圈定框重算 IOD")
    p_req.add_argument("image", help="原始图像路径")
    p_req.add_argument("--boxes-json", required=True, help="圈定框 JSON 数组字符串")
    p_req.add_argument("--radius", type=int, default=50, help="Rolling-ball 半径")
    p_req.add_argument("--control-lane", type=int, default=0, help="对照泳道索引")

    # 4. qt: 启动 PySide6 + pyqtgraph 交互视窗
    p_qt = sub.add_parser("qt", help="启动 PySide6 + pyqtgraph 科学视窗")
    p_qt.add_argument("image", help="输入 TIFF/PNG 图像路径")
    p_qt.add_argument("--lanes", type=int, default=0, help="指定泳道数")
    p_qt.add_argument("--radius", type=int, default=50, help="Rolling-ball 半径")

    args = parser.parse_args(argv)

    if args.cmd == "discover":
        groups = discover_sample_groups(args.directory)
        sys.stdout.write(json.dumps(groups, ensure_ascii=False, indent=2) + "\n")
        return 0

    if args.cmd == "requantify":
        boxes = json.loads(args.boxes_json)
        params = AnalysisParams(
            rolling_ball_radius=args.radius,
            control_lane_index=args.control_lane,
        )
        updated = requantify_boxes(args.image, boxes, params=params)
        sys.stdout.write(
            json.dumps([b.to_dict() for b in updated], ensure_ascii=False, indent=2) + "\n"
        )
        return 0

    if args.cmd == "qt":
        params = AnalysisParams(
            rolling_ball_radius=args.radius,
            expected_lanes=args.lanes,
        )
        return launch_qt_viewer(args.image, params=params)

    if args.cmd == "analyze":
        custom_roi = None
        if args.roi:
            parts = [int(v.strip()) for v in args.roi.split(",")]
            if len(parts) == 4:
                custom_roi = RectROI(x=parts[0], y=parts[1], width=parts[2], height=parts[3])

        params = AnalysisParams(
            rolling_ball_radius=args.radius,
            expected_lanes=args.lanes,
            band_prominence=args.prominence,
            strip_threshold=args.threshold,
            auto_deskew=args.deskew,
            control_lane_index=args.control_lane,
            primary_band_only=not args.all_bands,
        )
        res = analyze_blot(args.image, params=params, custom_strip_roi=custom_roi)
        if args.out_csv:
            export_csv(res, args.out_csv)
        if args.out_json:
            export_json(res, args.out_json)
        if args.out_png:
            export_annotated_png(res, args.out_png)

        sys.stdout.write(json.dumps(res.to_dict(), ensure_ascii=False) + "\n")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
