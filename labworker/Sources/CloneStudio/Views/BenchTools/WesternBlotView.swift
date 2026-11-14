import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers
import CloneStudioCore

// MARK: - 融合 WBStudio (wbquant) 与 CloneStudio 统计引擎的 Western Blot 工作台视图

public struct WesternBlotView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var poolManager = PlasmidPoolManager.shared
    
    // MARK: 1. 样本图层池状态 (自动加载 labworker/Samples/WB/gapdh_*.tif 真实 16-bit 样本 + 内置双排示范膜)
    @State private var sampleGroups: [WBSampleGroup] = []
    @State private var selectedGroupID: String = "__synthetic_dual__"
    @State private var activeLayerRole: String = "raw_chemi"
    @State private var brightfieldOverlayOpacity: Double = 0.0
    
    // MARK: 2. 算法圈定参数与分析结果
    @State private var params: WBAnalysisParams = WBAnalysisParams(
        rollingBallRadius: 50,
        expectedLanes: 0,
        bandProminence: 0.12,
        stripThreshold: 0.08,
        autoDeskew: false,
        controlLaneIndex: 0,
        primaryBandOnly: true
    )
    @State private var currentResult: WBAnalysisResult? = nil
    @State private var selectedLaneIndex: Int = 0
    @State private var selectedBandID: String? = nil
    @State private var laneGroups: [Int: String] = [
        0: "WT", 1: "WT",
        2: "TP53-OE", 3: "TP53-OE",
        4: "TP53-KO", 5: "TP53-KO"
    ]
    @State private var controlGroupName: String = "WT"
    @State private var preferNativeEngine: Bool = false
    
    // MARK: 3. 画布显示与交互状态 (纯视觉层，不修改 16-bit 定量数组)
    @State private var whiteBackgroundMode: Bool = true
    @State private var contrastBoost: Double = 1.15
    @State private var gammaDisplay: Double = 1.0
    @State private var focusOnStripROI: Bool = true
    @State private var canvasZoom: Double = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    
    @State private var showStripROI: Bool = true
    @State private var showLaneGuides: Bool = true
    @State private var showBandBoxes: Bool = true
    @State private var showProfileDrawer: Bool = true
    @State private var showSaturatedPixelMask: Bool = false
    @State private var exposureRecommendation: WesternBlotEngine.WBExposureRecommendation? = nil
    @State private var linkedPlasmidIDs: Set<String> = []
    @State private var manualEdits: [AnalysisRun.ManualEdit] = []
    @State private var chartMode: BottomChartMode = .laneFold
    @State private var inspectorTab: WBInspectorTab = .detect
    
    @State private var cachedPrimaryImage: NSImage? = nil
    @State private var cachedBrightfieldImage: NSImage? = nil
    @State private var syntheticBuffer: WesternBlotEngine.RawGrayBuffer16 = {
        let plane = BioImageProcessor.generateDemoWesternBlotPlane(width: 480, height: 280)
        return WesternBlotEngine.bufferFromBioImagePlane(plane)
    }()
    
    @State private var dragBandID: String? = nil
    @State private var dragStartRect: WBRect? = nil
    @State private var isResizingCorner: Bool = false
    
    public enum WBInspectorTab: String, CaseIterable, Identifiable {
        case detect = "detect"
        case display = "display"
        case quantify = "quantify"
        case export = "export"
        
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .detect: return "圈定"
            case .display: return "显影"
            case .quantify: return "定量"
            case .export: return "导出"
            }
        }
        public var icon: String {
            switch self {
            case .detect: return "viewfinder.rectangular"
            case .display: return "slider.horizontal.below.sun.max"
            case .quantify: return "chart.bar.xaxis"
            case .export: return "square.and.arrow.up"
            }
        }
    }
    
    public enum BottomChartMode: String, CaseIterable, Identifiable {
        case laneFold = "laneFold"
        case groupStat = "groupStat"
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .laneFold: return "单泳道 Fold"
            case .groupStat: return "分组统计 (t-test)"
            }
        }
    }
    
    public init() {}
    
    private var isSyntheticSelected: Bool {
        selectedGroupID == "__synthetic_dual__"
    }
    
    private var selectedGroup: WBSampleGroup? {
        sampleGroups.first(where: { $0.id == selectedGroupID })
    }
    
    private var activeDisplayPath: String? {
        guard let group = selectedGroup else { return nil }
        switch activeLayerRole {
        case "raw_chemi": return group.rawChemi ?? group.primaryQuantPath
        case "chemi": return group.chemi ?? group.primaryQuantPath
        case "brightfield": return group.brightfield ?? group.primaryQuantPath
        case "overlay": return group.overlay ?? group.primaryQuantPath
        default: return group.primaryQuantPath
        }
    }
    
    private var groupQuantOut: BlotQuantificationOut? {
        guard let res = currentResult else { return nil }
        return WesternBlotEngine.computeGroupStatistics(
            from: res,
            laneGroups: laneGroups,
            controlGroup: controlGroupName,
            normalizeBySecondRowIfPresent: true,
            saturationPolicy: params.saturationPolicy
        )
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "WB 灰度定量",
            toolbar: [
                .action(title: "导入", icon: "folder.badge.plus", help: "导入 WB 曝光目录或 TIFF 图像", action: openImportPanel),
                .action(title: "圈定", icon: "sparkles", tint: .blue, help: "重新自动识别泳道并圈定条带", action: runAutoAnalysis),
                .action(title: "视窗", icon: "waveform.path.ecg.rectangle", tint: .teal, help: "启动 PySide6 + pyqtgraph 科学密度视窗", action: launchPyQtViewer),
                .action(title: "Prism", icon: "doc.on.doc", help: "复制 GraphPad Prism / Excel TSV", action: copyPrismTSV),
                .action(title: "导出", icon: "square.and.arrow.up", tint: .green, help: "导出条带定量 CSV 报表", action: exportAnalysisCSV)
            ]
        ) {
            // 顶部曝光批次与图层快速切换栏（完全声明式自适应流式布局）
            sampleAndLayerBar
            
            // 主工作区：左侧交互式自动圈定画布 + 底部 1D 剖面/显著性抽屉 ｜ 右侧四合一胶囊检查器
            StudioResponsiveSplitLayout(breakpoint: 840, spacing: 14, leftRatio: 0.64) {
                VStack(spacing: 12) {
                    interactiveCanvasCard
                    if showProfileDrawer, let res = currentResult {
                        profileAndStatisticsDrawer(result: res)
                    }
                }
                
                VStack(spacing: 12) {
                    inspectorCard
                    bandQuantTableCard
                }
            }
        }
        .onAppear {
            params.rollingBallRadius = appState.defaultWBRollingBallRadius
            whiteBackgroundMode = appState.defaultWBWhiteBackground
            if sampleGroups.isEmpty {
                reloadSampleGroups()
            }
            consumePendingFinderWBFileIfNeeded()
        }
        .onChange(of: appState.pendingFinderOpenedFileURL) { _, _ in
            consumePendingFinderWBFileIfNeeded()
        }
        .onChange(of: appState.defaultWBRollingBallRadius) { _, newVal in
            params.rollingBallRadius = newVal
            runAutoAnalysis()
        }
        .onChange(of: appState.defaultWBWhiteBackground) { _, newVal in
            whiteBackgroundMode = newVal
            refreshDisplayImages()
        }
    }
    
    private func consumePendingFinderWBFileIfNeeded() {
        guard let url = appState.pendingFinderOpenedFileURL else { return }
        let ext = url.pathExtension.lowercased()
        guard ["tif", "tiff", "png", "jpg", "jpeg"].contains(ext) else { return }
        appState.pendingFinderOpenedFileURL = nil
        let parent = url.deletingLastPathComponent()
        reloadSampleGroups(from: parent)
        let stem = url.deletingPathExtension().lastPathComponent
        if let matched = sampleGroups.first(where: { stem.hasPrefix($0.id) }) {
            selectSampleGroup(matched.id)
        }
    }
    
    // MARK: - 1. 顶部曝光批次与明场 Marker 混叠控制栏
    
    private var sampleAndLayerBar: some View {
        StudioCard(title: "样本与图层") {
            if let res = currentResult {
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                    StudioMetricBadge(
                        label: "",
                        value: "\(res.bitDepth)-bit",
                        color: res.bitDepth == 16 ? .teal : .blue
                    )
                    StudioMetricBadge(
                        label: "",
                        value: "\(res.lanes.count)L · \(res.bands.count)B",
                        color: .indigo
                    )
                    if res.bands.contains(where: \.isSaturated) {
                        StudioMetricBadge(label: "", value: "过曝", color: .red)
                    }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                // 样本批次胶囊列表（包含真实 gapdh_*.tif 批次 + 内置双排目的/内参示范膜）
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(sampleGroups) { group in
                        let isSel = (selectedGroupID == group.id)
                        Button {
                            selectSampleGroup(group.id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: group.rawChemi != nil ? "sparkles.rectangle.stack.fill" : "photo")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(isSel ? .white : .accentColor)
                                Text(group.title)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(isSel ? .white : .primary)
                                if group.rawChemi != nil {
                                    Text("16-bit")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(isSel ? Color.white.opacity(0.24) : Color.teal.opacity(0.15)))
                                        .foregroundColor(isSel ? .white : .teal)
                                }
                                if group.brightfield != nil {
                                    Text("明场")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(isSel ? Color.white.opacity(0.24) : Color.orange.opacity(0.15)))
                                        .foregroundColor(isSel ? .white : .orange)
                                }
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSel ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                            .contentShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // 内置双排（TP53 + GAPDH 内参）示范膜按钮
                    let synthSelected = isSyntheticSelected
                    Button {
                        selectSyntheticDualDemo()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(synthSelected ? .white : .purple)
                            Text("TP53 / GAPDH 示范")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundColor(synthSelected ? .white : .primary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            Capsule(style: .continuous)
                                .fill(synthSelected ? Color.purple : Color.primary.opacity(0.06))
                        )
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("切换内置 TP53 + GAPDH 双排目的/内参示范膜")
                }
                
                // 若当前选中的真实样本组包含多个图层（16-bit 原图 / 发光 / 明场 / 叠加），展示图层切换与明场混叠滑块
                if let group = selectedGroup {
                    Divider().opacity(0.4)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            layerRoleSwitcher(for: group)
                            Spacer(minLength: 8)
                            if group.brightfield != nil || group.overlay != nil {
                                brightfieldOverlaySlider
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            layerRoleSwitcher(for: group)
                            if group.brightfield != nil || group.overlay != nil {
                                brightfieldOverlaySlider
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func layerRoleSwitcher(for group: WBSampleGroup) -> some View {
        StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(group.availableLayers, id: \.role) { layer in
                let isSel = (activeLayerRole == layer.role)
                Button {
                    activeLayerRole = layer.role
                    refreshDisplayImages()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: layer.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(layer.label)
                            .font(.system(size: 11.5, weight: isSel ? .semibold : .medium))
                    }
                    .foregroundColor(isSel ? .white : .primary)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isSel ? Color.teal : Color.primary.opacity(0.07))
                    )
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var brightfieldOverlaySlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.2.layers.3d")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.pink)
            Text("Marker")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.secondary)
            Slider(value: $brightfieldOverlayOpacity, in: 0.0...0.85)
                .controlSize(.small)
                .tint(.pink)
                .frame(width: 110)
            Text("\(Int((brightfieldOverlayOpacity * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 34, alignment: .trailing)
        }
        .help("明场 Marker 图层混叠透明度")
    }
    
    // MARK: - 2. 交互式 WB 自动圈定画布 (支持聚焦有效膜条、缩放平移与条带框直接拖拽/拉伸微调)
    
    private func activeViewportRect(for result: WBAnalysisResult?) -> CGRect {
        guard let res = result else {
            let sz = cachedPrimaryImage?.size ?? NSSize(width: 480, height: 280)
            return CGRect(x: 0, y: 0, width: max(1, sz.width), height: max(1, sz.height))
        }
        let fullW = CGFloat(max(1, res.width))
        let fullH = CGFloat(max(1, res.height))
        guard focusOnStripROI else {
            return CGRect(x: 0, y: 0, width: fullW, height: fullH)
        }
        let sr = res.stripROI
        let padX = max(48.0, CGFloat(sr.width) * 0.18)
        let padY = max(42.0, CGFloat(sr.height) * 0.55)
        let x0 = max(0.0, CGFloat(sr.x) - padX)
        let y0 = max(0.0, CGFloat(sr.y) - padY)
        let x1 = min(fullW, CGFloat(sr.x2) + padX)
        let y1 = min(fullH, CGFloat(sr.y2) + padY)
        return CGRect(x: x0, y: y0, width: max(40.0, x1 - x0), height: max(40.0, y1 - y0))
    }
    
    private var interactiveCanvasCard: some View {
        StudioCard(title: "膜条交互画布") {
            StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 6) {
                Toggle("过曝掩码", isOn: $showSaturatedPixelMask)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .medium))
                    .help("高亮显示接近或达到 16-bit 上限的饱和像素")
                    .onChange(of: showSaturatedPixelMask) { _, _ in
                        refreshDisplayImages()
                    }
                
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        focusOnStripROI.toggle()
                        panOffset = .zero
                        lastPanOffset = .zero
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: focusOnStripROI ? "viewfinder.circle.fill" : "aspectratio")
                        Text(focusOnStripROI ? "聚焦" : "全幅")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(focusOnStripROI ? .teal : .secondary)
                }
                .buttonStyle(.plain)
                .help(focusOnStripROI ? "当前聚焦有效膜区，点击切换全画幅视野" : "当前全画幅视野，点击聚焦有效膜区")
                
                HStack(spacing: 4) {
                    Button {
                        canvasZoom = max(0.6, canvasZoom - 0.15)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    Text(String(format: "%.0f%%", canvasZoom * 100))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 38)
                    Button {
                        canvasZoom = min(2.5, canvasZoom + 0.15)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
        } content: {
            GeometryReader { geo in
                let canvasSize = geo.size
                let res = currentResult
                let imgW = CGFloat(res?.width ?? Int(cachedPrimaryImage?.size.width ?? 480))
                let imgH = CGFloat(res?.height ?? Int(cachedPrimaryImage?.size.height ?? 280))
                let viewRect = activeViewportRect(for: res)
                
                let availW = max(80.0, canvasSize.width - 24.0)
                let availH = max(80.0, canvasSize.height - 24.0)
                let baseScale = min(availW / viewRect.width, availH / viewRect.height)
                let scale = baseScale * CGFloat(canvasZoom)
                
                let originX = (canvasSize.width - viewRect.width * scale) * 0.5 - viewRect.minX * scale + panOffset.width
                let originY = (canvasSize.height - viewRect.height * scale) * 0.5 - viewRect.minY * scale + panOffset.height
                
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.84))
                    
                    // 1. 底层化学发光显影图像
                    if let primaryImg = cachedPrimaryImage {
                        Image(nsImage: primaryImg)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: imgW * scale, height: imgH * scale)
                            .position(
                                x: originX + (imgW * scale) * 0.5,
                                y: originY + (imgH * scale) * 0.5
                            )
                    }
                    
                    // 2. 明场蛋白 Marker 半透明叠加图层
                    if brightfieldOverlayOpacity > 0.01,
                       let bfImg = cachedBrightfieldImage {
                        Image(nsImage: bfImg)
                            .resizable()
                            .interpolation(.high)
                            .opacity(brightfieldOverlayOpacity)
                            .blendMode(.multiply)
                            .frame(width: imgW * scale, height: imgH * scale)
                            .position(
                                x: originX + (imgW * scale) * 0.5,
                                y: originY + (imgH * scale) * 0.5
                            )
                    }
                    
                    // 3. 有效膜条区域框 (Active Strip ROI) 与波谷泳道分界线
                    if let res {
                        let sr = res.stripROI
                        if showStripROI {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(
                                    Color.cyan.opacity(0.70),
                                    style: StrokeStyle(lineWidth: 1.3, dash: [5, 4])
                                )
                                .frame(width: CGFloat(sr.width) * scale, height: CGFloat(sr.height) * scale)
                                .position(
                                    x: originX + (CGFloat(sr.x) + CGFloat(sr.width) * 0.5) * scale,
                                    y: originY + (CGFloat(sr.y) + CGFloat(sr.height) * 0.5) * scale
                                )
                        }
                        
                        if showLaneGuides {
                            ForEach(res.lanes) { lane in
                                let isSelectedLane = (lane.index == selectedLaneIndex)
                                let laneX = originX + CGFloat(lane.xStart) * scale
                                let laneW = CGFloat(lane.width) * scale
                                let laneY = originY + CGFloat(lane.yStart) * scale
                                let laneH = CGFloat(lane.yEnd - lane.yStart) * scale
                                
                                Path { path in
                                    path.move(to: CGPoint(x: laneX, y: laneY))
                                    path.addLine(to: CGPoint(x: laneX, y: laneY + laneH))
                                }
                                .stroke(
                                    Color.cyan.opacity(0.45),
                                    style: StrokeStyle(lineWidth: 1.0, dash: [3, 3])
                                )
                                
                                let isCtrl = (lane.index == params.controlLaneIndex)
                                Button {
                                    selectedLaneIndex = lane.index
                                } label: {
                                    HStack(spacing: 2) {
                                        Text("L\(lane.index + 1)")
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                        if isCtrl {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 8))
                                        }
                                    }
                                    .foregroundColor(isSelectedLane ? .black : .white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(isSelectedLane ? Color.cyan : Color.black.opacity(0.68))
                                    )
                                }
                                .buttonStyle(.plain)
                                .position(x: laneX + laneW * 0.5, y: max(16, laneY - 11))
                                .contextMenu {
                                    Button("设为对照泳道 (1.00×)") {
                                        setControlLane(lane.index)
                                    }
                                }
                            }
                        }
                        
                        // 4. 自动圈定的条带框 (支持直接拖拽平移与右下角黄点拉伸微调)
                        if showBandBoxes {
                            ForEach(res.bands) { band in
                                bandBoxOverlay(
                                    band: band,
                                    scale: scale,
                                    originX: originX,
                                    originY: originY
                                )
                            }
                        }
                    }
                    
                    // 右下角复位缩放按钮
                    if panOffset != .zero || abs(canvasZoom - 1.0) > 0.05 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                canvasZoom = 1.0
                                panOffset = .zero
                                lastPanOffset = .zero
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("复位视野")
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.65)))
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            guard dragBandID == nil else { return }
                            panOffset = CGSize(
                                width: lastPanOffset.width + value.translation.width,
                                height: lastPanOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastPanOffset = panOffset
                        }
                )
            }
            .frame(minHeight: 280, idealHeight: 330)
        }
    }
    
    @ViewBuilder
    private func bandBoxOverlay(
        band: WBBand,
        scale: CGFloat,
        originX: CGFloat,
        originY: CGFloat
    ) -> some View {
        let isSelected = (selectedBandID == band.id)
        let w = max(12.0, CGFloat(band.width) * scale)
        let h = max(10.0, CGFloat(band.height) * scale)
        let cx = originX + (CGFloat(band.x) + CGFloat(band.width) * 0.5) * scale
        let cy = originY + (CGFloat(band.y) + CGFloat(band.height) * 0.5) * scale
        
        let strokeColor: Color = band.isSaturated
            ? .red
            : (isSelected ? .yellow : (band.rowIndex == 0 ? .green : .orange))
        
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(strokeColor.opacity(isSelected ? 0.16 : 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(strokeColor, lineWidth: isSelected ? 2.2 : 1.6)
                )
            
            Text(String(format: "%.2f×", band.foldChange))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.black.opacity(0.74)))
                .offset(y: h * 0.5 + 11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            
            if isSelected {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 8, height: 8)
                    .offset(x: 3, y: 3)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { val in
                                if dragBandID != band.id {
                                    dragBandID = band.id
                                    dragStartRect = WBRect(x: band.x, y: band.y, width: band.width, height: band.height)
                                    isResizingCorner = true
                                }
                                guard let start = dragStartRect else { return }
                                let dw = Int((val.translation.width / scale).rounded())
                                let dh = Int((val.translation.height / scale).rounded())
                                let nextRect = WBRect(
                                    x: start.x,
                                    y: start.y,
                                    width: max(8, start.width + dw),
                                    height: max(6, start.height + dh)
                                )
                                updateBandRect(bandID: band.id, newRect: nextRect)
                            }
                            .onEnded { _ in
                                dragBandID = nil
                                dragStartRect = nil
                                isResizingCorner = false
                            }
                    )
            }
        }
        .frame(width: w, height: h)
        .position(x: cx, y: cy)
        .onTapGesture {
            selectedBandID = band.id
            selectedLaneIndex = band.laneIndex
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { val in
                    guard !isResizingCorner else { return }
                    if dragBandID != band.id {
                        dragBandID = band.id
                        dragStartRect = WBRect(x: band.x, y: band.y, width: band.width, height: band.height)
                        selectedBandID = band.id
                        selectedLaneIndex = band.laneIndex
                    }
                    guard let start = dragStartRect else { return }
                    let dx = Int((val.translation.width / scale).rounded())
                    let dy = Int((val.translation.height / scale).rounded())
                    let nextRect = WBRect(
                        x: start.x + dx,
                        y: start.y + dy,
                        width: start.width,
                        height: start.height
                    )
                    updateBandRect(bandID: band.id, newRect: nextRect)
                }
                .onEnded { _ in
                    dragBandID = nil
                    dragStartRect = nil
                }
        )
    }
    
    // MARK: - 3. 底部双联科学图表抽屉 (左：1D 泳道光密度剖面积分曲线 ｜ 右：单泳道 Fold / 分组 Welch's t 检验柱状图)
    
    private func profileAndStatisticsDrawer(result: WBAnalysisResult) -> some View {
        StudioResponsiveSplitLayout(breakpoint: 620, spacing: 12, leftRatio: 0.48) {
            StudioCard(title: "L\(selectedLaneIndex + 1) 光密度剖面") {
                if let band = result.bands.first(where: { $0.laneIndex == selectedLaneIndex }) {
                    Text(String(format: "Net IOD %.0f", band.netIOD))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.teal)
                }
            } content: {
                GeometryReader { geo in
                    if selectedLaneIndex >= 0, selectedLaneIndex < result.lanes.count {
                        let lane = result.lanes[selectedLaneIndex]
                        let prof = lane.profile
                        let pmax = max(1.0, prof.max() ?? 1.0)
                        Canvas { ctx, size in
                            guard prof.count > 1 else { return }
                            var linePath = Path()
                            var fillPath = Path()
                            for (idx, val) in prof.enumerated() {
                                let px = size.width * CGFloat(idx) / CGFloat(max(1, prof.count - 1))
                                let py = size.height - (size.height - 10) * CGFloat(val / pmax) - 4
                                if idx == 0 {
                                    linePath.move(to: CGPoint(x: px, y: py))
                                    fillPath.move(to: CGPoint(x: px, y: size.height - 2))
                                    fillPath.addLine(to: CGPoint(x: px, y: py))
                                } else {
                                    linePath.addLine(to: CGPoint(x: px, y: py))
                                    fillPath.addLine(to: CGPoint(x: px, y: py))
                                }
                            }
                            fillPath.addLine(to: CGPoint(x: size.width, y: size.height - 2))
                            fillPath.closeSubpath()
                            ctx.fill(
                                fillPath,
                                with: .linearGradient(
                                    Gradient(colors: [Color.teal.opacity(0.36), Color.teal.opacity(0.03)]),
                                    startPoint: .zero,
                                    endPoint: CGPoint(x: 0, y: size.height)
                                )
                            )
                            ctx.stroke(linePath, with: .color(.teal), lineWidth: 1.8)
                            
                            for band in result.bands where band.laneIndex == lane.index {
                                let totalY = max(1, lane.yEnd - lane.yStart)
                                let relStart = CGFloat(band.y - lane.yStart) / CGFloat(totalY)
                                let relEnd = CGFloat(band.y + band.height - lane.yStart) / CGFloat(totalY)
                                let bx0 = max(0, min(size.width, relStart * size.width))
                                let bx1 = max(0, min(size.width, relEnd * size.width))
                                let bandRect = CGRect(x: bx0, y: 2, width: max(2, bx1 - bx0), height: size.height - 4)
                                ctx.fill(
                                    Path(bandRect),
                                    with: .color((band.rowIndex == 0 ? Color.green : Color.orange).opacity(0.18))
                                )
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .frame(height: 145)
            }
            
            StudioCard(title: "定量与统计") {
                StudioSegmentedPicker(
                    selection: $chartMode,
                    options: BottomChartMode.allCases.map {
                        StudioSegmentedOption(value: $0, title: $0.title, tint: .indigo)
                    }
                )
            } content: {
                if chartMode == .laneFold {
                    let row0Bands = result.bands.filter { $0.rowIndex == 0 }
                    Chart {
                        ForEach(row0Bands) { band in
                            BarMark(
                                x: .value("泳道", "L\(band.laneIndex + 1)"),
                                y: .value("Fold", band.foldChange)
                            )
                            .foregroundStyle(
                                band.isSaturated
                                    ? Color.red.gradient
                                    : (band.laneIndex == params.controlLaneIndex ? Color.teal.gradient : Color.indigo.gradient)
                            )
                            .cornerRadius(4)
                            .annotation(position: .top) {
                                Text(String(format: "%.2f×", band.foldChange))
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(height: 145)
                } else if let statOut = groupQuantOut {
                    VStack(alignment: .leading, spacing: 8) {
                        Chart {
                            ForEach(statOut.groupStats) { g in
                                BarMark(
                                    x: .value("分组", g.groupName),
                                    y: .value("Fold", g.meanFold)
                                )
                                .foregroundStyle(g.isControl ? Color.secondary.gradient : Color.indigo.gradient)
                                .cornerRadius(5)
                                
                                if let sd = g.sdFold, sd > 0 {
                                    RuleMark(
                                        x: .value("分组", g.groupName),
                                        yStart: .value("Low", max(0, g.meanFold - sd)),
                                        yEnd: .value("High", g.meanFold + sd)
                                    )
                                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                                    .foregroundStyle(Color.primary)
                                }
                                
                                PointMark(
                                    x: .value("分组", g.groupName),
                                    y: .value("Top", g.meanFold + (g.sdFold ?? 0) + 0.08)
                                )
                                .symbolSize(0)
                                .annotation(position: .top) {
                                    Text("\(String(format: "%.2f", g.meanFold)) (\(g.significanceText))")
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundColor(g.significanceText.contains("*") ? .red : .secondary)
                                }
                            }
                        }
                        .frame(height: 135)
                        
                        ForEach(statOut.groupStats) { g in
                            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
                                Text(g.groupName)
                                    .font(.system(size: 11.5, weight: .semibold))
                                StudioMetricBadge(label: "有效 n", value: "\(g.n)", color: .secondary)
                                StudioMetricBadge(label: "Mean±SD", value: String(format: "%.2f±%.2f", g.meanFold, g.sdFold ?? 0), color: .indigo)
                                if g.nExcludedSaturated > 0 {
                                    StudioMetricBadge(
                                        label: "",
                                        value: "已剔除 \(g.nExcludedSaturated) 条过曝条带",
                                        color: .red
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 4. 右侧四合一胶囊检查器 (圈定 / 显影 / 定量 / 导出)
    
    private var inspectorCard: some View {
        StudioCard(title: "检查器") {
            StudioSegmentedPicker(
                selection: $inspectorTab,
                options: WBInspectorTab.allCases.map {
                    StudioSegmentedOption(value: $0, title: $0.title, tint: .blue)
                }
            )
        } content: {
            VStack(alignment: .leading, spacing: 11) {
                switch inspectorTab {
                case .detect:
                    detectInspectorContent
                case .display:
                    displayInspectorContent
                case .quantify:
                    quantifyInspectorContent
                case .export:
                    exportInspectorContent
                }
            }
        }
    }
    
    private var detectInspectorContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                Toggle("有效膜框", isOn: $showStripROI)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Toggle("泳道线", isOn: $showLaneGuides)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Toggle("条带框", isOn: $showBandBoxes)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Toggle("底部峰图", isOn: $showProfileDrawer)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            
            HStack {
                Text("期望泳道数")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("", selection: $params.expectedLanes) {
                    Text("自动波谷").tag(0)
                    Text("4 泳道").tag(4)
                    Text("6 泳道").tag(6)
                    Text("8 泳道").tag(8)
                    Text("10 泳道").tag(10)
                }
                .labelsHidden()
                .frame(width: 120)
                .onChange(of: params.expectedLanes) { _, _ in
                    runAutoAnalysis()
                }
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Rolling-Ball 背景球半径")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(params.rollingBallRadius) px")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
                Slider(
                    value: Binding(
                        get: { Double(params.rollingBallRadius) },
                        set: { params.rollingBallRadius = Int($0.rounded()) }
                    ),
                    in: 10...120,
                    step: 5
                ) { editing in
                    if !editing { runAutoAnalysis() }
                }
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("条带峰值灵敏度")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", params.bandProminence))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
                Slider(value: $params.bandProminence, in: 0.04...0.35) { editing in
                    if !editing { runAutoAnalysis() }
                }
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("有效膜条裁剪阈值")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", params.stripThreshold))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
                Slider(value: $params.stripThreshold, in: 0.03...0.25) { editing in
                    if !editing { runAutoAnalysis() }
                }
            }
            
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                StudioActionPillButton(
                    title: params.primaryBandOnly ? "单主带" : "多行带",
                    icon: "line.3.horizontal.decrease",
                    tint: params.primaryBandOnly ? .blue : .orange,
                    help: params.primaryBandOnly ? "当前模式：仅检测主条带，点击切换多行内参模式" : "当前模式：多行条带 (含内参)，点击切换仅主条带"
                ) {
                    params.primaryBandOnly.toggle()
                    runAutoAnalysis()
                }
                StudioActionPillButton(title: "补框", icon: "plus.rectangle", help: "在当前选中泳道新增一条带选框") {
                    addBandInSelectedLane()
                }
                StudioActionPillButton(title: "删框", icon: "trash", tint: .red, help: "删除当前选中的条带选框") {
                    deleteSelectedBand()
                }
            }
        }
    }
    
    private var displayInspectorContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StudioActionPillButton(
                    title: "白底黑带",
                    icon: "sun.max",
                    tint: whiteBackgroundMode ? .blue : nil,
                    isProminent: whiteBackgroundMode
                ) {
                    whiteBackgroundMode = true
                    refreshDisplayImages()
                }
                StudioActionPillButton(
                    title: "黑底白带",
                    icon: "moon.stars",
                    tint: !whiteBackgroundMode ? .blue : nil,
                    isProminent: !whiteBackgroundMode
                ) {
                    whiteBackgroundMode = false
                    refreshDisplayImages()
                }
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("显影对比度增强（不改定量原图）")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.2f×", contrastBoost))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
                Slider(value: $contrastBoost, in: 0.6...3.0) { _ in
                    refreshDisplayImages()
                }
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Gamma 曲线映射")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.2f", gammaDisplay))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
                Slider(value: $gammaDisplay, in: 0.4...2.2) { _ in
                    refreshDisplayImages()
                }
            }
            
            StudioActionPillButton(title: "复位", icon: "arrow.counterclockwise", help: "复位显影对比度、Gamma 与混叠参数") {
                contrastBoost = 1.15
                gammaDisplay = 1.0
                brightfieldOverlayOpacity = 0.0
                refreshDisplayImages()
            }
        }
    }
    
    private var quantifyInspectorContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let res = currentResult {
                HStack {
                    Text("对照泳道 (1.00×)")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("", selection: $params.controlLaneIndex) {
                        ForEach(res.lanes) { lane in
                            Text("L\(lane.index + 1)").tag(lane.index)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .onChange(of: params.controlLaneIndex) { _, newIdx in
                        setControlLane(newIdx)
                    }
                }
                
                HStack {
                    Text("生物学重复对照组")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    TextField("WT", text: $controlGroupName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    Text("过曝饱和条带统计策略 (>\(String(format: "%.0f%%", params.saturationRatioThreshold * 100)) 核心像素饱和)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Picker("", selection: $params.saturationPolicy) {
                        ForEach(WBSaturationPolicy.allCases) { pol in
                            Text(pol.title).tag(pol)
                        }
                    }
                    .labelsHidden()
                }
                
                Divider().opacity(0.4)
                Text("各泳道实验分组（用于计算 Mean ± SD 与 Welch's t 检验）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                
                ForEach(res.lanes) { lane in
                    HStack(spacing: 8) {
                        Text("L\(lane.index + 1)")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .frame(width: 28, alignment: .leading)
                        TextField(
                            "分组名",
                            text: Binding(
                                get: {
                                    laneGroups[lane.index] ?? ((lane.index < 2) ? "WT" : ((lane.index < 4) ? "Group-2" : "Group-3"))
                                },
                                set: { laneGroups[lane.index] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                    }
                }
                
                Divider().opacity(0.4)
                HStack {
                    Text("多曝光动态线性范围检查 (P14)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        runExposureSeriesAnalysis()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.xyaxis.line")
                            Text("线性度核验")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
                
                if let rec = exposureRecommendation {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: rec.allBandsLinear ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(rec.allBandsLinear ? .teal : .orange)
                                .font(.system(size: 12))
                            Text(rec.reason)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill((rec.allBandsLinear ? Color.teal : Color.orange).opacity(0.12))
                        )
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 125, maximum: 190))], spacing: 6) {
                            ForEach(rec.bandLinearities) { bl in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(bl.bandID)
                                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                        Spacer()
                                        Text(bl.isLinear ? "线性" : "非线性")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundColor(bl.isLinear ? .green : .red)
                                    }
                                    Chart {
                                        ForEach(Array(bl.points.enumerated()), id: \.offset) { _, pt in
                                            LineMark(
                                                x: .value("t", pt.exposureSeconds),
                                                y: .value("IOD", pt.netIOD)
                                            )
                                            .foregroundStyle(bl.isLinear ? Color.teal : Color.red)
                                            PointMark(
                                                x: .value("t", pt.exposureSeconds),
                                                y: .value("IOD", pt.netIOD)
                                            )
                                            .symbolSize(16)
                                            .foregroundStyle(bl.isLinear ? Color.teal : Color.red)
                                        }
                                    }
                                    .chartXAxis(.hidden)
                                    .chartYAxis(.hidden)
                                    .frame(height: 32)
                                    Text(String(format: "R²=%.4f%@", bl.r2, bl.isSaturatedInMaxExposure ? " · 截断" : ""))
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                )
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var exportInspectorContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("强制使用纯 Swift 16-bit 原生引擎", isOn: $preferNativeEngine)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .onChange(of: preferNativeEngine) { _, _ in
                    runAutoAnalysis()
                }
            
            if !poolManager.items.isEmpty {
                Menu {
                    ForEach(poolManager.items) { pItem in
                        Button {
                            if linkedPlasmidIDs.contains(pItem.id) {
                                linkedPlasmidIDs.remove(pItem.id)
                            } else {
                                linkedPlasmidIDs.insert(pItem.id)
                            }
                        } label: {
                            Label(pItem.name, systemImage: linkedPlasmidIDs.contains(pItem.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: {
                    Label(linkedPlasmidIDs.isEmpty ? "关联质粒池条目 (可选)" : "已关联 \(linkedPlasmidIDs.count) 个质粒", systemImage: "link")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .controlSize(.small)
            }
            
            StudioActionPillButton(
                title: "导出 CSV",
                icon: "square.and.arrow.up.fill",
                tint: .blue,
                isProminent: true,
                fillWidth: true,
                help: "导出条带定量 CSV 报表"
            ) {
                exportAnalysisCSV()
            }
            
            StudioActionPillButton(
                title: "导出 HTML 报告",
                icon: "doc.richtext",
                tint: .orange,
                fillWidth: true,
                help: "导出离线 HTML 统计与过曝质控报告"
            ) {
                exportAnalysisHTMLReport()
            }
            
            StudioActionPillButton(
                title: "复制 Prism TSV",
                icon: "doc.on.doc",
                tint: .teal,
                fillWidth: true,
                help: "复制 GraphPad Prism / Excel 兼容 TSV 数据"
            ) {
                copyPrismTSV()
            }
            
            StudioActionPillButton(
                title: "pyqtgraph 视窗",
                icon: "waveform.path.ecg.rectangle",
                tint: .indigo,
                fillWidth: true,
                help: "启动 PySide6 + pyqtgraph 科学密度视窗"
            ) {
                launchPyQtViewer()
            }
        }
    }
    
    // MARK: - 5. 条带积分光密度 (IOD) 与分组统计汇总表
    
    private var bandQuantTableCard: some View {
        StudioCard(title: "条带 IOD 定量明细") {
            if let res = currentResult {
                Text("共 \(res.bands.count) 个圈定框")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        } content: {
            if let res = currentResult {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(res.bands) { band in
                        let isSel = (band.id == selectedBandID)
                        Button {
                            selectedBandID = band.id
                            selectedLaneIndex = band.laneIndex
                        } label: {
                            HStack(spacing: 8) {
                                Text(band.id)
                                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(band.rowIndex == 0 ? .green : .orange)
                                    .frame(width: 48, alignment: .leading)
                                
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(String(format: "Net IOD: %.0f", band.netIOD))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(.primary)
                                    Text("\(band.width)×\(band.height) px · Bg \(String(format: "%.0f", band.backgroundIOD))")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if band.isSaturated {
                                    StudioMetricBadge(label: "", value: "过曝", color: .red)
                                }
                                StudioMetricBadge(
                                    label: "",
                                    value: String(format: "%.2f×", band.foldChange),
                                    color: band.laneIndex == params.controlLaneIndex ? .teal : .indigo
                                )
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSel ? Color.primary.opacity(0.11) : Color.primary.opacity(0.035))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    // MARK: - 6. 核心业务动作函数
    
    private func reloadSampleGroups(from directory: URL? = nil) {
        let groups = WesternBlotEngine.discoverSampleGroups(in: directory)
        sampleGroups = groups
        if let first = groups.first {
            selectSampleGroup(first.id)
        } else {
            selectSyntheticDualDemo()
        }
    }
    
    private func selectSampleGroup(_ groupID: String) {
        selectedGroupID = groupID
        guard let group = sampleGroups.first(where: { $0.id == groupID }) else { return }
        if group.rawChemi != nil {
            activeLayerRole = "raw_chemi"
        } else if group.chemi != nil {
            activeLayerRole = "chemi"
        } else if let firstRole = group.availableLayers.first?.role {
            activeLayerRole = firstRole
        }
        params.primaryBandOnly = true
        refreshDisplayImages()
        runAutoAnalysis()
    }
    
    private func selectSyntheticDualDemo() {
        selectedGroupID = "__synthetic_dual__"
        params.primaryBandOnly = false
        params.expectedLanes = 6
        refreshDisplayImages()
        runAutoAnalysis()
    }
    
    private func refreshDisplayImages() {
        if isSyntheticSelected {
            cachedPrimaryImage = WesternBlotEngine.renderDisplayImage(
                from: syntheticBuffer,
                invertToWhiteBackground: whiteBackgroundMode,
                contrastBoost: contrastBoost,
                gamma: gammaDisplay,
                showSaturatedMask: showSaturatedPixelMask
            )
            cachedBrightfieldImage = nil
            return
        }
        guard let group = selectedGroup,
              let displayPath = activeDisplayPath else {
            cachedPrimaryImage = nil
            cachedBrightfieldImage = nil
            return
        }
        let isChemiRole = (activeLayerRole == "raw_chemi" || activeLayerRole == "chemi")
        cachedPrimaryImage = WesternBlotEngine.renderDisplayImage(
            at: displayPath,
            invertToWhiteBackground: isChemiRole ? whiteBackgroundMode : false,
            contrastBoost: contrastBoost,
            gamma: gammaDisplay,
            showSaturatedMask: showSaturatedPixelMask
        )
        if let bfPath = group.brightfield {
            cachedBrightfieldImage = NSImage(contentsOfFile: bfPath)
        } else if let ovPath = group.overlay {
            cachedBrightfieldImage = NSImage(contentsOfFile: ovPath)
        } else {
            cachedBrightfieldImage = nil
        }
    }
    
    private func runAutoAnalysis() {
        if isSyntheticSelected {
            let res = WesternBlotEngine.analyzeNativeBuffer(
                syntheticBuffer,
                imagePath: "TP53_GAPDH_DualRow_Demo.tif",
                params: params
            )
            currentResult = res
            selectedLaneIndex = min(selectedLaneIndex, max(0, res.lanes.count - 1))
            selectedBandID = res.bands.first?.id
            return
        }
        guard let group = selectedGroup else { return }
        let quantPath = group.primaryQuantPath
        let cfg = params
        let useNative = preferNativeEngine
        Task.detached(priority: .userInitiated) {
            let res = WesternBlotEngine.analyze(
                imagePath: quantPath,
                params: cfg,
                preferNative: useNative
            )
            await MainActor.run {
                if let res {
                    self.currentResult = res
                    if self.selectedLaneIndex >= res.lanes.count {
                        self.selectedLaneIndex = 0
                    }
                    self.selectedBandID = res.bands.first?.id
                }
            }
        }
    }
    
    private func updateBandRect(bandID: String, newRect: WBRect) {
        guard var res = currentResult,
              let idx = res.bands.firstIndex(where: { $0.id == bandID }) else { return }
        var band = res.bands[idx]
        let beforeStr = "x=\(band.x),y=\(band.y),w=\(band.width),h=\(band.height)"
        band.x = max(0, min(res.width - 6, newRect.x))
        band.y = max(0, min(res.height - 6, newRect.y))
        band.width = max(6, min(res.width - band.x, newRect.width))
        band.height = max(6, min(res.height - band.y, newRect.height))
        band.peakY = band.y + band.height / 2
        let afterStr = "x=\(band.x),y=\(band.y),w=\(band.width),h=\(band.height)"
        if beforeStr != afterStr {
            manualEdits.append(AnalysisRun.ManualEdit(what: "band_roi:\(bandID)", before: beforeStr, after: afterStr))
        }
        res.bands[idx] = band
        
        let updated = WesternBlotEngine.requantify(
            imagePath: res.imagePath,
            bands: res.bands,
            params: params,
            fallbackBuffer: isSyntheticSelected ? syntheticBuffer : nil
        )
        res.bands = updated
        currentResult = res
    }
    
    private func setControlLane(_ laneIndex: Int) {
        let oldCtrl = params.controlLaneIndex
        params.controlLaneIndex = laneIndex
        selectedLaneIndex = laneIndex
        if oldCtrl != laneIndex {
            manualEdits.append(AnalysisRun.ManualEdit(what: "control_lane", before: "L\(oldCtrl + 1)", after: "L\(laneIndex + 1)"))
        }
        guard var res = currentResult else {
            runAutoAnalysis()
            return
        }
        let updated = WesternBlotEngine.requantify(
            imagePath: res.imagePath,
            bands: res.bands,
            params: params,
            fallbackBuffer: isSyntheticSelected ? syntheticBuffer : nil
        )
        res.params = params
        res.bands = updated
        currentResult = res
    }
    
    private func addBandInSelectedLane() {
        guard var res = currentResult,
              selectedLaneIndex >= 0,
              selectedLaneIndex < res.lanes.count else { return }
        let lane = res.lanes[selectedLaneIndex]
        let newID = "L\(lane.index + 1)_M\(res.bands.count + 1)"
        let bw = max(12, lane.width - 4)
        let bh = 22
        let bx = lane.xStart + 2
        let by = lane.yStart + max(4, (lane.yEnd - lane.yStart - bh) / 2)
        let newBand = WBBand(
            id: newID,
            laneIndex: lane.index,
            rowIndex: 0,
            x: bx,
            y: by,
            width: bw,
            height: bh,
            peakY: by + bh / 2,
            rawIOD: 0,
            backgroundIOD: 0,
            netIOD: 0
        )
        manualEdits.append(AnalysisRun.ManualEdit(what: "add_band:\(newID)", before: "none", after: "x=\(bx),y=\(by),w=\(bw),h=\(bh)"))
        res.bands.append(newBand)
        selectedBandID = newID
        res.bands = WesternBlotEngine.requantify(
            imagePath: res.imagePath,
            bands: res.bands,
            params: params,
            fallbackBuffer: isSyntheticSelected ? syntheticBuffer : nil
        )
        currentResult = res
    }
    
    private func deleteSelectedBand() {
        guard var res = currentResult,
              let bid = selectedBandID else { return }
        if let b = res.bands.first(where: { $0.id == bid }) {
            manualEdits.append(AnalysisRun.ManualEdit(what: "delete_band:\(bid)", before: "x=\(b.x),y=\(b.y),w=\(b.width),h=\(b.height)", after: "deleted"))
        }
        res.bands.removeAll { $0.id == bid }
        selectedBandID = res.bands.first?.id
        currentResult = res
    }
    
    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择 WB 曝光目录或 16-bit/8-bit TIFF/PNG 图像"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.tiff, .png, .jpeg, .folder]
        if panel.runModal() == .OK, let url = panel.url {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                reloadSampleGroups(from: url)
                appState.showToast("已载入 WB 样本目录：\(url.lastPathComponent)")
            } else {
                let parent = url.deletingLastPathComponent()
                reloadSampleGroups(from: parent)
                let stem = url.deletingPathExtension().lastPathComponent
                if let matched = sampleGroups.first(where: { stem.hasPrefix($0.id) }) {
                    selectSampleGroup(matched.id)
                }
                appState.showToast("已导入 WB 图像：\(url.lastPathComponent)")
            }
        }
    }
    
    private func launchPyQtViewer() {
        guard let group = selectedGroup else {
            appState.showToast("请先选择左侧真实 TIFF 样本组以启动 pyqtgraph 科学视窗")
            return
        }
        WesternBlotEngine.launchPyQtGraphWorkbench(imagePath: group.primaryQuantPath, params: params)
        appState.showToast("正在启动 PySide6 + pyqtgraph 科学密度视窗…")
    }
    
    private func copyPrismTSV() {
        guard let res = currentResult else { return }
        var lines = ["Band_ID\tLane\tRow\tGroup\tNet_IOD\tBackground_IOD\tFold_Change\tSaturated"]
        for b in res.bands {
            let grp = laneGroups[b.laneIndex] ?? "Group"
            lines.append(
                "\(b.id)\tL\(b.laneIndex + 1)\tR\(b.rowIndex + 1)\t\(grp)\t\(String(format: "%.1f", b.netIOD))\t\(String(format: "%.1f", b.backgroundIOD))\t\(String(format: "%.4f", b.foldChange))\t\(b.isSaturated ? "YES" : "NO")"
            )
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        appState.showToast("已复制 WB 定量 TSV 到剪贴板（可直接粘贴至 GraphPad Prism）")
    }
    
    private func exportAnalysisCSV() {
        guard let res = currentResult else { return }
        let qOut = groupQuantOut
        let edits = manualEdits
        let eng = preferNativeEngine ? "swift-native" : "python-wbquant"
        let linked = Array(linkedPlasmidIDs).sorted()
        let csv = WesternBlotEngine.exportWBAnalysisCSV(res, quantOut: qOut)
        FinderFileDropHelper.saveTextToFile(
            content: csv,
            defaultFileName: "Western_Blot_16bit_Quantification.csv",
            contentType: .commaSeparatedText,
            toastPrefix: "已导出 WB 16-bit 定量 CSV 与 .run.json 溯源记录"
        ) { savedURL in
            let run = WesternBlotEngine.buildWBAnalysisRun(
                result: res,
                quantOut: qOut,
                exposureRecommendation: exposureRecommendation,
                backgroundMode: "rollingBall",
                normalizeByLoadingControl: !res.params.primaryBandOnly,
                manualEdits: edits,
                outputs: [savedURL.lastPathComponent],
                exportDirectoryURL: savedURL.deletingLastPathComponent(),
                engine: eng,
                linkedPlasmidIDs: linked
            )
            _ = try? run.writeSidecarJSON(alongsideOutputURL: savedURL)
        }
    }
    
    private func exportAnalysisHTMLReport() {
        guard let res = currentResult, let qOut = groupQuantOut else { return }
        let edits = manualEdits
        let eng = preferNativeEngine ? "swift-native" : "python-wbquant"
        let linked = Array(linkedPlasmidIDs).sorted()
        let previewRun = WesternBlotEngine.buildWBAnalysisRun(
            result: res,
            quantOut: qOut,
            backgroundMode: "rollingBall",
            normalizeByLoadingControl: !res.params.primaryBandOnly,
            manualEdits: edits,
            outputs: ["Western_Blot_16bit_QC_Report.html"],
            engine: eng,
            linkedPlasmidIDs: linked
        )
        let exWarnings = qOut.excludedBands.map {
            "已按策略 (\(qOut.saturationPolicy.rawValue)) 从分组统计中剔除泳道 L\($0.laneIndex) 条带 \($0.bandID) (\($0.groupName))：\($0.reason)"
        }
        let html = FinderFileDropHelper.buildOfflineHTMLReport(
            title: "Western Blot 16-bit 光密度定量与过曝质控报告",
            subtitle: "图像：\((res.imagePath as NSString).lastPathComponent) · 位深 \(res.bitDepth)-bit · 饱和策略：\(qOut.saturationPolicy.title)",
            credibilityBadge: qOut.excludedBands.isEmpty ? "无过曝饱和剔除" : "已剔除 \(qOut.excludedBands.count) 条过曝条带",
            warnings: exWarnings.isEmpty ? ["全部检测条带核心区饱和像素占比均低于阈值 (\(String(format: "%.1f%%", res.params.saturationRatioThreshold * 100)))，数据处于有效动态范围。"] : exWarnings,
            metrics: [
                ("图像尺寸", "\(res.width)×\(res.height) px"),
                ("量化位深", "\(res.bitDepth)-bit"),
                ("滚球半径", "\(res.params.rollingBallRadius) px"),
                ("饱和处理策略", qOut.saturationPolicy.rawValue),
                ("剔除过曝条带数", "\(qOut.excludedBands.count)")
            ],
            tableHeaders: ["分组", "有效样本数 n", "已剔除过曝数", "Mean Fold", "SD", "p (Welch)", "显著性"],
            tableRows: qOut.groupStats.map { g in
                [
                    g.groupName,
                    "\(g.n)",
                    "\(g.nExcludedSaturated)",
                    String(format: "%.3f", g.meanFold),
                    g.sdFold.map { String(format: "%.3f", $0) } ?? "—",
                    g.pValue.map { String(format: "%.4f", $0) } ?? (g.isControl ? "Ref" : "—"),
                    g.significanceText
                ]
            },
            provenanceFooter: previewRun.htmlProvenanceFooterText
        )
        FinderFileDropHelper.saveHTMLReport(
            htmlContent: html,
            defaultFileName: "Western_Blot_16bit_QC_Report.html"
        ) { savedURL in
            var finalRun = WesternBlotEngine.buildWBAnalysisRun(
                result: res,
                quantOut: qOut,
                backgroundMode: "rollingBall",
                normalizeByLoadingControl: !res.params.primaryBandOnly,
                manualEdits: edits,
                outputs: [savedURL.lastPathComponent],
                exportDirectoryURL: savedURL.deletingLastPathComponent(),
                engine: eng,
                linkedPlasmidIDs: linked
            )
            finalRun = AnalysisRun(
                schemaVersion: finalRun.schemaVersion,
                runID: previewRun.runID,
                module: finalRun.module,
                createdAt: previewRun.createdAt,
                appVersion: finalRun.appVersion,
                gitCommit: finalRun.gitCommit,
                engine: finalRun.engine,
                inputs: finalRun.inputs,
                parameters: finalRun.parameters,
                manualEdits: finalRun.manualEdits,
                exclusions: finalRun.exclusions,
                outputs: [savedURL.lastPathComponent],
                linkedPlasmidIDs: linked
            )
            _ = try? finalRun.writeSidecarJSON(alongsideOutputURL: savedURL)
        }
    }
    
    private func runExposureSeriesAnalysis() {
        guard let res = currentResult else { return }
        let rawBuf = isSyntheticSelected ? syntheticBuffer : (WesternBlotEngine.loadRawGrayBuffer(at: res.imagePath) ?? syntheticBuffer)
        let maxRaw = max(1.0, rawBuf.signal.max() ?? 1.0)
        // 归一化基准 1x 使最强条带峰值约为 22000，从而 1x (10s) ~22000、2x (20s) ~44000 均处于未饱和线性区，而 4x (40s) 峰值达 88000 -> 在 65535 处发生过曝截断
        let normFactor = 22000.0 / maxRaw
        let buf1x = WesternBlotEngine.scaleBufferForExposure(rawBuf, factor: normFactor * 1.0)
        let buf2x = WesternBlotEngine.scaleBufferForExposure(rawBuf, factor: normFactor * 2.0)
        let buf4x = WesternBlotEngine.scaleBufferForExposure(rawBuf, factor: normFactor * 4.0)
        let series: [(imagePath: String, exposureSeconds: Double, buffer: WesternBlotEngine.RawGrayBuffer16?)] = [
            ("exp_10s.tif", 10.0, buf1x),
            ("exp_20s.tif", 20.0, buf2x),
            ("exp_40s.tif", 40.0, buf4x)
        ]
        if let rec = WesternBlotEngine.analyzeExposureSeries(series: series, params: params, referenceBands: res.bands) {
            self.exposureRecommendation = rec
            appState.showToast(rec.reason)
        }
    }
}
