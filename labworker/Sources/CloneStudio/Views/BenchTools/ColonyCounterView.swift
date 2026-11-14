import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// 菌落画布点击交互模式
private enum ColonyClickMode: String, CaseIterable, Identifiable {
    case toggleInclude = "toggleInclude"
    case addWhite = "addWhite"
    case addBlue = "addBlue"
    case deleteMarker = "deleteMarker"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .toggleInclude: return "点选启用/排除"
        case .addWhite:      return "补加白斑"
        case .addBlue:       return "补加蓝斑"
        case .deleteMarker:  return "点击删除"
        }
    }
}

/// 菌落计数器与蓝白斑筛选主视图 (纯声明式响应式 UI：任意拉动窗口自动折行与等比缩放培养皿画布)
public struct ColonyCounterView: View {
    @ObservedObject private var appState = AppState.shared
    
    @State private var plane: BioImagePlane = BioImageProcessor.generateDemoColonyPlatePlane()
    @State private var params: ColonySegmentationParams = ColonySegmentationParams()
    @State private var markers: [ColonyMarkerItem] = []
    @State private var otsuValue: Double = 140.0
    @State private var appliedThreshold: Double = 140.0
    @State private var useManualThreshold: Bool = false
    @State private var manualThresholdSlider: Double = 155.0
    @State private var clickMode: ColonyClickMode = .toggleInclude
    @State private var showNumberLabels: Bool = true
    @State private var sourceImageURL: URL? = nil
    @State private var manualEdits: [AnalysisRun.ManualEdit] = []
    
    public init() {}
    
    private var summary: ColonyStatisticsSummary {
        ColonyCounterEngine.summarize(
            markers: markers,
            otsu: otsuValue,
            appliedThreshold: appliedThreshold,
            params: params
        )
    }
    
    private var polarityOptions: [StudioSegmentedOption<ColonyPolarityMode>] {
        ColonyPolarityMode.allCases.map { mode in
            StudioSegmentedOption(value: mode, title: mode.title, tint: .blue)
        }
    }
    
    private var clickModeOptions: [StudioSegmentedOption<ColonyClickMode>] {
        ColonyClickMode.allCases.map { mode in
            let tint: Color = {
                switch mode {
                case .toggleInclude: return .teal
                case .addWhite:      return .orange
                case .addBlue:       return .blue
                case .deleteMarker:  return .pink
                }
            }()
            return StudioSegmentedOption(value: mode, title: mode.title, tint: tint)
        }
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "菌落计数器与蓝白斑筛选",
            trailing: {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    StudioSegmentedPillGroup(items: [
                        StudioPillGroupItem(title: "导入平板照片", icon: "photo.badge.plus", tint: .blue) {
                            importPlateImage()
                        },
                        StudioPillGroupItem(title: "蓝白斑示范图", icon: "sparkles") {
                            sourceImageURL = nil
                            plane = BioImageProcessor.generateDemoColonyPlatePlane()
                            runSegmentation()
                            appState.showToast("已载入蓝白斑转化平板示范图并完成自动计数")
                        },
                        StudioPillGroupItem(title: "导出 CSV", icon: "square.and.arrow.up", tint: .teal) {
                            exportColonyCSV()
                        }
                    ])
                }
            }
        ) {
            StudioResponsiveSplitLayout(breakpoint: 860, spacing: 14, leftRatio: 0.38) {
                leftColumn
                rightColumn
            }
        }
        .onAppear {
            if markers.isEmpty {
                runSegmentation()
            }
        }
    }
    
    // MARK: - 左栏：图像分割参数 + 稀释倍数与 CFU 统计
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            segmentationParamsCard
            cfuAndAreaHistogramCard
        }
    }
    
    private var segmentationParamsCard: some View {
        StudioCard(
            title: "Otsu 分割阈值与形态学过滤",
            headerTrailing: {
                StudioActionPillButton(title: "重新识别", icon: "arrow.clockwise", tint: .blue, isProminent: true) {
                    runSegmentation()
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    Text("菌落极性:")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                    StudioSegmentedPicker(selection: $params.polarity, options: polarityOptions)
                        .onChange(of: params.polarity) { _, _ in runSegmentation() }
                }
                
                StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 6) {
                    Toggle("手动指定阈值 (关闭则用 Otsu: \(Int(otsuValue)))", isOn: $useManualThreshold)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                        .onChange(of: useManualThreshold) { _, newVal in
                            params.manualThreshold = newVal ? manualThresholdSlider : nil
                            runSegmentation()
                        }
                    
                    Toggle("启用 X-gal 蓝白斑色相自动分类", isOn: $params.classifyBlueWhite)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                        .onChange(of: params.classifyBlueWhite) { _, _ in runSegmentation() }
                }
                
                if useManualThreshold {
                    HStack(spacing: 8) {
                        Text("阈值 (\(Int(manualThresholdSlider))):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize()
                        Slider(value: $manualThresholdSlider, in: 10...245, step: 1)
                            .onChange(of: manualThresholdSlider) { _, newVal in
                                params.manualThreshold = newVal
                                runSegmentation()
                            }
                    }
                }
                
                StudioFlowLayout(horizontalSpacing: 14, verticalSpacing: 8) {
                    HStack(spacing: 4) {
                        Text("最小面积(px²):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("12", value: $params.minArea, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 54)
                            .onSubmit { runSegmentation() }
                    }
                    
                    HStack(spacing: 4) {
                        Text("最大面积(px²):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("2500", value: $params.maxArea, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 64)
                            .onSubmit { runSegmentation() }
                    }
                    
                    HStack(spacing: 4) {
                        Text("最低圆度:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("0.35", value: $params.minCircularity, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 52)
                            .onSubmit { runSegmentation() }
                    }
                }
            }
        }
    }
    
    private var cfuAndAreaHistogramCard: some View {
        let stat = summary
        return StudioCard(title: "CFU/mL 滴度换算与 Garwood 95% 泊松置信区间") {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 14, verticalSpacing: 8) {
                    HStack(spacing: 4) {
                        Text("稀释倍数 (Dilution):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("1000", value: $params.dilutionFactor, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 78)
                    }
                    
                    HStack(spacing: 4) {
                        Text("涂板体积 (mL):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("0.1", value: $params.platedVolumeMl, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 62)
                    }
                }
                
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    StudioMetricBadge(label: "有效菌落", value: "\(stat.includedCount)", color: .green)
                    StudioMetricBadge(
                        label: "95% 泊松区间",
                        value: String(format: "%.1f – %.1f", stat.poissonLow, stat.poissonHigh),
                        color: .teal
                    )
                    if let cfu = stat.cfuPerMl {
                        StudioMetricBadge(label: "CFU/mL", value: String(format: "%.2e", cfu), color: .blue)
                    }
                    if params.classifyBlueWhite {
                        StudioMetricBadge(label: "白斑(阳性)", value: "\(stat.whiteCount)", color: .orange)
                        StudioMetricBadge(label: "蓝斑(自连)", value: "\(stat.blueCount)", color: .indigo)
                        StudioMetricBadge(
                            label: "阳性克隆率",
                            value: String(format: "%.1f%%", stat.whitePositiveRatePct),
                            color: .pink
                        )
                    }
                }
                
                if !markers.isEmpty {
                    Divider()
                    Text("菌落面积分布直方图 (px²)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    Chart(markers.filter(\.included)) { item in
                        BarMark(
                            x: .value("面积 (px²)", item.area),
                            y: .value("菌落数", 1)
                        )
                        .foregroundStyle(item.colonyClass == .blue ? Color.blue : Color.orange)
                    }
                    .frame(height: 140)
                }
            }
        }
    }
    
    // MARK: - 右栏：响应式培养皿菌落标注画布
    private var rightColumn: some View {
        let stat = summary
        return StudioCard(
            title: "培养皿交互点选画布 (有效 \(stat.includedCount) · 已排除 \(stat.excludedCount) · 手动 \(stat.manualCount))",
            headerTrailing: {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    Toggle("显示编号", isOn: $showNumberLabels)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    
                    StudioSegmentedPicker(selection: $clickMode, options: clickModeOptions)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    let side = max(220, min(geo.size.width, geo.size.height))
                    let scaleX = side / CGFloat(max(1, plane.width))
                    let scaleY = side / CGFloat(max(1, plane.height))
                    
                    ZStack {
                        if let nsImg = plane.toNSImage() {
                            Image(nsImage: nsImg)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: side, height: side)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        
                        Canvas { context, _ in
                            for (idx, marker) in markers.enumerated() {
                                let cx = CGFloat(marker.x) * scaleX
                                let cy = CGFloat(marker.y) * scaleY
                                let rad = max(5.0, CGFloat(marker.radius) * ((scaleX + scaleY) * 0.5))
                                let rect = CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2)
                                
                                let strokeColor: Color = {
                                    if !marker.included { return .gray.opacity(0.55) }
                                    switch marker.colonyClass {
                                    case .blue:         return .cyan
                                    case .white:        return .yellow
                                    case .unclassified: return .green
                                    }
                                }()
                                
                                context.stroke(
                                    Path(ellipseIn: rect),
                                    with: .color(strokeColor),
                                    lineWidth: marker.included ? 2.0 : 1.0
                                )
                                
                                if showNumberLabels && marker.included {
                                    let label = Text("\(idx + 1)")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    context.draw(label, at: CGPoint(x: cx, y: cy - rad - 6))
                                }
                            }
                        }
                        .frame(width: side, height: side)
                        .contentShape(Rectangle())
                        .onTapGesture { tap in
                            handleCanvasTap(at: tap, scaleX: scaleX, scaleY: scaleY)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(minHeight: 380, maxHeight: 540)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.14))
                )
                
                Text("提示：黄色圆圈代表阳性白斑 (LacZ-)，青色圆圈代表自连蓝斑 (LacZ+)；切换右上角模式可点选排除假阳性或手动补点。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    // MARK: - 交互动作
    
    private func runSegmentation() {
        let res = ColonyCounterEngine.segmentPlate(plane: plane, params: params)
        markers = res.markers
        otsuValue = res.otsu
        appliedThreshold = res.appliedThreshold
        manualEdits = []
    }
    
    private func handleCanvasTap(at pt: CGPoint, scaleX: CGFloat, scaleY: CGFloat) {
        let imgX = Double(pt.x / max(0.01, scaleX))
        let imgY = Double(pt.y / max(0.01, scaleY))
        
        // 查找最近标记点
        var nearestIdx: Int? = nil
        var bestDist = 14.0
        for (idx, m) in markers.enumerated() {
            let d = hypot(m.x - imgX, m.y - imgY)
            if d < bestDist {
                bestDist = d
                nearestIdx = idx
            }
        }
        
        switch clickMode {
        case .toggleInclude:
            if let idx = nearestIdx {
                markers[idx].included.toggle()
            }
        case .deleteMarker:
            if let idx = nearestIdx {
                let removed = markers.remove(at: idx)
                manualEdits.append(
                    AnalysisRun.ManualEdit(
                        what: "manual_delete_marker:#\(removed.id)",
                        before: "x=\(String(format: "%.1f", removed.x)),y=\(String(format: "%.1f", removed.y))",
                        after: "deleted"
                    )
                )
            }
        case .addWhite, .addBlue:
            let nextId = (markers.map(\.id).max() ?? 0) + 1
            markers.append(
                ColonyMarkerItem(
                    id: nextId,
                    x: imgX,
                    y: imgY,
                    area: 85.0,
                    radius: 5.2,
                    included: true,
                    isManual: true,
                    colonyClass: clickMode == .addBlue ? .blue : .white
                )
            )
        }
    }
    
    private func importPlateImage() {
        FinderFileDropHelper.presentOpenPanel { url in
            if let img = NSImage(contentsOf: url),
               let loadedPlane = BioImagePlane.fromNSImage(img, maxDimension: 480) {
                sourceImageURL = url
                plane = loadedPlane
                runSegmentation()
                appState.showToast("已载入培养皿图像并识别出 \(markers.count) 个菌落")
            }
        }
    }
    
    private func exportColonyCSV() {
        let curMarkers = markers
        let curOtsu = otsuValue
        let curApplied = appliedThreshold
        let curParams = params
        let curSourceURL = sourceImageURL
        let curW = plane.width
        let curH = plane.height
        let curEdits = manualEdits
        let csv = ColonyCounterEngine.exportMarkersCSV(markers: curMarkers)
        FinderFileDropHelper.saveTextToFile(
            content: csv,
            defaultFileName: "Colony_Count_BlueWhite_Report.csv",
            contentType: .commaSeparatedText,
            toastPrefix: "已导出菌落计数 CSV",
            onSavedURL: { savedURL in
                _ = try? ColonyCounterEngine.exportMarkersCSVWithProvenance(
                    markers: curMarkers,
                    otsu: curOtsu,
                    appliedThreshold: curApplied,
                    params: curParams,
                    sourceImageURL: curSourceURL,
                    planeWidth: curW,
                    planeHeight: curH,
                    manualEdits: curEdits,
                    to: savedURL
                )
            }
        )
    }
}
