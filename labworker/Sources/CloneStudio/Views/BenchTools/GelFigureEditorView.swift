import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// 凝胶电泳分子量拟合、多模块虚拟电泳联动与拼图编辑器主视图 (纯声明式响应式 UI + macOS 27 Liquid Glass)
public struct GelFigureEditorView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var plasmidPool = PlasmidPoolManager.shared
    @ObservedObject private var singleVM = WorkspaceSessionManager.shared.singleFragmentVM
    @ObservedObject private var multiVM = WorkspaceSessionManager.shared.multiFragmentVM
    @ObservedObject private var entryVM = WorkspaceSessionManager.shared.entryCloneVM
    @ObservedObject private var deletionVM = WorkspaceSessionManager.shared.fragmentDeletionVM
    @ObservedObject private var mutagenesisVM = WorkspaceSessionManager.shared.mutagenesisVM
    
    @State private var plane: BioImagePlane = BioImageProcessor.generateDemoAgaroseGelPlane()
    @State private var selectedLadderID: String = "dl2000"
    @State private var lanes: [GelLaneItem] = []
    @State private var calibrationFit: GelLadderCalibrationFit? = nil
    
    @State private var predictionSource: GelVirtualPredictionSource = .plasmidDigest
    @State private var selectedPlasmidID: String = "__demo__"
    @State private var selectedEnzyme1: String = "BamHI"
    @State private var selectedEnzyme2: String = "EcoRI"
    @State private var includeMixedControlLane: Bool = false
    @State private var customLaneName: String = "自定义预测"
    @State private var customBandSizesText: String = "1500, 750"
    @State private var appliedPredictionSources: [String] = []
    
    @State private var showBandSizeOverlay: Bool = true
    @State private var showLadderRuler: Bool = true
    @State private var sourceImageURL: URL? = nil
    @State private var showDiagnosticDigestSheet: Bool = false
    
    public init() {}
    
    private static let singleCutOption = "__none__"
    
    private enum GelUI {
        static let section: CGFloat = 12
        static let row: CGFloat     = 8
        static let chip: CGFloat    = 6
    }
    
    private static func shortName(_ text: String, maxLength: Int = 18) -> String {
        guard text.count > maxLength, maxLength >= 6 else { return text }
        let headCount = (maxLength - 1) / 2
        let tailCount = maxLength - 1 - headCount
        return "\(text.prefix(headCount))…\(text.suffix(tailCount))"
    }
    
    private var selectedPlasmidHelp: String {
        if let item = plasmidPool.items.first(where: { $0.id == selectedPlasmidID }) {
            return "待酶切质粒：\(item.name) (\(item.dnaInfo.length) bp)"
        }
        return "待酶切质粒：示例质粒 (pETDuet-Demo)"
    }
    
    private var activeLadder: GelMarkerLadderPreset {
        GelMarkerLadderPreset.builtinPresets.first { $0.id == selectedLadderID }
            ?? GelMarkerLadderPreset.builtinPresets[0]
    }
    
    private var commonDigestEnzymes: [String] {
        var base = DiagnosticDigestEngine.defaultDiagnosticEnzymeNames
        for extra in ["BsaI", "BsmBI", "BbsI"] where !base.contains(extra) {
            base.append(extra)
        }
        return base
    }
    
    private var virtualLaneCount: Int {
        lanes.filter(\.isVirtualDigestLane).count
    }
    
    private var hasSingleFragmentData: Bool {
        singleVM.cleanInsertLengthBp >= 50 || singleVM.effectiveVectorBackboneLengthBp >= 300 || singleVM.vectorDNAInfo != nil
    }
    
    private var hasMultiFragmentData: Bool {
        multiVM.fragments.contains { BioSequence.clean($0).count >= 50 } || multiVM.effectiveVectorBackboneLengthBp >= 300 || multiVM.vectorDNAInfo != nil
    }
    
    private var hasEntryCloneData: Bool {
        entryVM.cleanLength >= 50
    }
    
    private var hasFragmentDeletionData: Bool {
        let pLen = deletionVM.plasmidDNAInfo?.length ?? BioSequence.clean(deletionVM.plasmidSeq).count
        return pLen >= 100 && deletionVM.estimatedDeletionLengthBp > 0
    }
    
    private var hasMutagenesisData: Bool {
        let pLen = mutagenesisVM.plasmidDNAInfo?.length ?? 0
        let flankLen = BioSequence.clean(mutagenesisVM.mutUp).count + BioSequence.clean(mutagenesisVM.mutDown).count
        return pLen >= 100 || flankLen >= 100
    }
    
    private func hasActiveData(for source: GelVirtualPredictionSource) -> Bool {
        switch source {
        case .plasmidDigest:    return !plasmidPool.items.isEmpty
        case .singleFragment:   return hasSingleFragmentData
        case .multiFragment:    return hasMultiFragmentData
        case .entryClone:       return hasEntryCloneData
        case .fragmentDeletion: return hasFragmentDeletionData
        case .mutagenesis:      return hasMutagenesisData
        case .customSizes:      return !GelAnalysisEngine.parseCustomBandSizes(customBandSizesText).isEmpty
        }
    }
    
    private var ladderPickerOptions: [StudioMenuPickerOption<String>] {
        GelMarkerLadderPreset.builtinPresets.map { preset in
            StudioMenuPickerOption(value: preset.id, title: preset.name)
        }
    }
    
    private var plasmidPickerOptions: [StudioMenuPickerOption<String>] {
        var opts = plasmidPool.items.map { item in
            StudioMenuPickerOption(value: item.id, title: Self.shortName(item.name, maxLength: 18))
        }
        if opts.isEmpty {
            opts.append(StudioMenuPickerOption(value: "__demo__", title: "pETDuet-Demo"))
        }
        return opts
    }
    
    private var enzyme1Options: [StudioMenuPickerOption<String>] {
        commonDigestEnzymes.map { StudioMenuPickerOption(value: $0, title: $0) }
    }
    
    private var enzyme2Options: [StudioMenuPickerOption<String>] {
        [StudioMenuPickerOption(value: Self.singleCutOption, title: "无")]
            + commonDigestEnzymes.map { StudioMenuPickerOption(value: $0, title: $0) }
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "凝胶定量",
            toolbar: [
                .action(title: "导入", icon: "photo.badge.plus", tint: .cyan, help: "导入电泳胶图", action: importGelImage),
                .action(title: "拟合", icon: "wand.and.stars", tint: .blue, help: "自动寻道并拟合 Ladder 标准曲线") {
                    runAutoDetection()
                    appState.showToast("已完成泳道寻峰与 \(activeLadder.name) 标准曲线拟合")
                },
                .action(title: "预测道", icon: "sparkles.rectangle.stack", tint: .teal, help: "按当前所选模块叠加虚拟电泳预测道", action: injectActivePredictionSource),
                .action(title: "导出", icon: "square.and.arrow.up", help: "导出条带分子量回归 CSV", action: exportGelCSV)
            ]
        ) {
            StudioResponsiveSplitLayout(breakpoint: 860, spacing: GelUI.section, leftRatio: 0.42) {
                leftColumn
                rightColumn
            }
        }
        .onAppear {
            selectedLadderID = appState.defaultGelLadderID
            syncSelectedPlasmidID()
            if lanes.isEmpty {
                runAutoDetection()
            }
            if let url = appState.pendingFinderOpenedFileURL,
               ["tif", "tiff", "png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
               let img = NSImage(contentsOf: url),
               let loadedPlane = BioImagePlane.fromNSImage(img, maxDimension: 520) {
                appState.pendingFinderOpenedFileURL = nil
                sourceImageURL = url
                plane = loadedPlane
                runAutoDetection()
            }
        }
        .onChange(of: appState.defaultGelLadderID) { _, newLadder in
            selectedLadderID = newLadder
        }
        .onChange(of: selectedLadderID) { _, _ in
            let res = GelAnalysisEngine.recalibrateLanes(lanes: lanes, ladder: activeLadder)
            lanes = res.lanes
            calibrationFit = res.fit
        }
        .onChange(of: plasmidPool.items.count) { _, _ in
            syncSelectedPlasmidID()
        }
        .sheet(isPresented: $showDiagnosticDigestSheet) {
            DiagnosticDigestSheet(
                initialEmptyPlasmidID: plasmidPool.items.first?.id,
                initialRecombinantPlasmidID: (selectedPlasmidID == "__demo__" ? plasmidPool.items.dropFirst().first?.id : selectedPlasmidID),
                onApplyToGel: { enzymeNames in
                    if let e1 = enzymeNames.first {
                        selectedEnzyme1 = e1
                    }
                    if enzymeNames.count >= 2 {
                        selectedEnzyme2 = enzymeNames[1]
                    } else {
                        selectedEnzyme2 = Self.singleCutOption
                    }
                    predictionSource = .plasmidDigest
                    injectVirtualDigestLaneFromPool()
                }
            )
        }
    }
    
    // MARK: - 左栏：Marker 标准曲线 + 预测泳道配置 + 泳道条带明细
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: GelUI.section) {
            ladderCalibrationCard
            virtualPredictionCard
            lanesDetailCard
        }
    }
    
    private var ladderCalibrationCard: some View {
        StudioCard(
            title: "Marker 标准曲线",
            headerTrailing: {
                StudioMenuPicker(
                    selection: $selectedLadderID,
                    options: ladderPickerOptions,
                    icon: "ruler",
                    tint: .blue,
                    help: "\(activeLadder.name) — 切换 DNA / 蛋白质 Marker 并重算所有条带"
                )
            }
        ) {
            VStack(alignment: .leading, spacing: GelUI.row) {
                if let fit = calibrationFit {
                    StudioFlowLayout(horizontalSpacing: GelUI.chip, verticalSpacing: GelUI.chip) {
                        StudioMetricBadge(label: "R²", value: String(format: "%.4f", fit.r2), color: fit.r2 >= 0.98 ? .green : .orange)
                            .help("标准曲线拟合优度 R²")
                        StudioMetricBadge(label: "斜率", value: String(format: "%.3f", fit.slope), color: .blue)
                            .help("对数迁移率回归斜率 (Slope)")
                        StudioMetricBadge(label: "截距", value: String(format: "%.2f", fit.intercept), color: .teal)
                            .help("对数迁移率回归截距 (Intercept)")
                        StudioMetricBadge(label: "点数", value: "\(fit.n)", color: .secondary)
                            .help("参与拟合的 Marker 校准点数")
                    }
                    
                    Chart {
                        ForEach(Array(fit.points.enumerated()), id: \.offset) { _, pt in
                            PointMark(
                                x: .value("迁移率 Y", pt.y),
                                y: .value("log10(\(activeLadder.kind.unit))", pt.log10Size)
                            )
                            .foregroundStyle(Color.cyan)
                            .symbolSize(50)
                        }
                        
                        LineMark(
                            x: .value("迁移率 Y", 0.15),
                            y: .value("log10(\(activeLadder.kind.unit))", fit.slope * 0.15 + fit.intercept)
                        )
                        .foregroundStyle(Color.blue)
                        
                        LineMark(
                            x: .value("迁移率 Y", 0.85),
                            y: .value("log10(\(activeLadder.kind.unit))", fit.slope * 0.85 + fit.intercept)
                        )
                        .foregroundStyle(Color.blue)
                    }
                    .chartXAxisLabel("Normalized Migration Distance (Y)")
                    .chartYAxisLabel("log10(\(activeLadder.kind.unit))")
                    .frame(minHeight: 120, idealHeight: 150, maxHeight: 180)
                }
            }
        }
    }
    
    private var virtualPredictionCard: some View {
        StudioCard(
            title: "预测泳道",
            headerTrailing: {
                if virtualLaneCount > 0 {
                    StudioActionPillButton(
                        title: "\(virtualLaneCount)",
                        icon: "trash",
                        tint: .red,
                        help: "清空全部 \(virtualLaneCount) 条虚拟预测泳道"
                    ) {
                        lanes.removeAll(where: \.isVirtualDigestLane)
                        lanes = GelAnalysisEngine.layoutVirtualLanes(lanes)
                        appliedPredictionSources.removeAll()
                        appState.showToast("已清空全部虚拟预测泳道")
                    }
                }
            }
        ) {
            VStack(alignment: .leading, spacing: GelUI.section) {
                VStack(alignment: .leading, spacing: GelUI.chip) {
                    Text("来源")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    
                    StudioFlowLayout(horizontalSpacing: GelUI.chip, verticalSpacing: GelUI.chip) {
                        ForEach(GelVirtualPredictionSource.allCases) { src in
                            let isReady = hasActiveData(for: src)
                            let helpText: String = {
                                if src == .customSizes {
                                    return "手动输入条带分子量并叠加虚拟预测泳道"
                                }
                                return isReady
                                    ? "\(src.title)（绿点表示该模块已有可用数据，可叠加多条预测泳道同胶对比）"
                                    : "\(src.title)（尚未载入数据，可用示范数据预览）"
                            }()
                            StudioCompactPillButton(
                                title: src.title,
                                icon: src.icon,
                                dotColor: (src == .customSizes || !isReady) ? nil : .green,
                                tint: predictionSource == src ? .teal : nil,
                                isSelected: predictionSource == src,
                                help: helpText
                            ) {
                                predictionSource = src
                            }
                        }
                    }
                }
                
                activeSourceControlPanel
            }
        }
    }
    
    private var lanesDetailCard: some View {
        StudioCard(title: "泳道明细") {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: GelUI.chip) {
                    ForEach($lanes) { $lane in
                        VStack(alignment: .leading, spacing: GelUI.chip) {
                            HStack(alignment: .center, spacing: GelUI.row) {
                                Text("L\(lane.index)")
                                    .font(.system(size: 12, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundColor(lane.isLadderLane ? .orange : (lane.isVirtualDigestLane ? .cyan : .blue))
                                    .frame(minWidth: 26, alignment: .leading)
                                
                                TextField("泳道名称", text: $lane.name)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .font(.system(size: 12))
                                
                                if lane.isVirtualDigestLane {
                                    StudioCompactPillButton(
                                        title: "",
                                        icon: "trash",
                                        tint: .red,
                                        help: "删除此虚拟预测泳道"
                                    ) {
                                        let laneID = lane.id
                                        if let removeIdx = lanes.firstIndex(where: { $0.id == laneID }) {
                                            lanes.remove(at: removeIdx)
                                            lanes = GelAnalysisEngine.layoutVirtualLanes(lanes)
                                        }
                                    }
                                } else {
                                    Color.clear
                                        .frame(width: 24, height: 24)
                                        .accessibilityHidden(true)
                                }
                            }
                            
                            StudioFlowLayout(horizontalSpacing: GelUI.chip, verticalSpacing: 4) {
                                ForEach(lane.bands) { band in
                                    let valStr = band.estimatedSize.map {
                                        activeLadder.kind == .dna ? String(format: "%.0f bp", $0) : String(format: "%.1f kDa", $0)
                                    } ?? "—"
                                    StudioMetricBadge(
                                        label: lane.isLadderLane ? "Std" : (band.isVirtualDigestBand ? "Pred" : "Band"),
                                        value: valStr,
                                        color: lane.isLadderLane ? .orange : (band.isVirtualDigestBand ? .cyan : .teal)
                                    )
                                }
                            }
                        }
                        .studioInnerBox(tint: lane.isVirtualDigestLane ? .cyan : nil, paddingH: 8, paddingV: 8)
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 300)
        }
    }
    
    @ViewBuilder
    private var activeSourceControlPanel: some View {
        VStack(alignment: .leading, spacing: GelUI.row) {
            switch predictionSource {
            case .plasmidDigest:
                StudioFlowLayout(horizontalSpacing: GelUI.row, verticalSpacing: GelUI.row) {
                    StudioMenuPicker(
                        selection: $selectedPlasmidID,
                        options: plasmidPickerOptions,
                        icon: "circle.circle",
                        tint: .blue,
                        help: selectedPlasmidHelp
                    )
                    
                    StudioMenuPicker(
                        selection: $selectedEnzyme1,
                        options: enzyme1Options,
                        prefix: "酶1",
                        tint: .teal,
                        help: "第一种限制性内切酶"
                    )
                    
                    StudioMenuPicker(
                        selection: $selectedEnzyme2,
                        options: enzyme2Options,
                        prefix: "酶2",
                        tint: .teal,
                        help: "第二种限制性内切酶（选“无”为单酶切）"
                    )
                    
                    StudioActionPillButton(
                        title: "叠加",
                        icon: "plus.viewfinder",
                        tint: .teal,
                        isProminent: true,
                        help: "按当前质粒与内切酶叠加理论酶切预测道"
                    ) {
                        injectVirtualDigestLaneFromPool()
                    }

                    StudioActionPillButton(
                        title: "智能推荐",
                        icon: "wand.and.stars",
                        tint: .purple,
                        help: "对比空载与重组质粒，推荐最佳鉴定内切酶并套用到电泳对照"
                    ) {
                        showDiagnosticDigestSheet = true
                    }
                    
                    if plasmidPool.items.isEmpty {
                        StudioActionPillButton(
                            title: "",
                            icon: "arrow.up.right.square",
                            help: "前往质粒池导入质粒"
                        ) {
                            appState.selectedNav = .plasmidPool
                        }
                    }
                }
                
            case .singleFragment:
                cloningModulePredictionPanel(
                    hasData: hasSingleFragmentData,
                    moduleName: "单片段无缝克隆",
                    targetNav: .singleFragment,
                    badges: singleFragmentSummaryBadges,
                    supportsMixedControl: true,
                    onPredictLive: { injectSingleFragmentLanes(useDemo: false) },
                    onPredictDemo: { injectSingleFragmentLanes(useDemo: true) }
                )
                
            case .multiFragment:
                cloningModulePredictionPanel(
                    hasData: hasMultiFragmentData,
                    moduleName: "多片段组装",
                    targetNav: .multiFragment,
                    badges: multiFragmentSummaryBadges,
                    supportsMixedControl: true,
                    onPredictLive: { injectMultiFragmentLanes(useDemo: false) },
                    onPredictDemo: { injectMultiFragmentLanes(useDemo: true) }
                )
                
            case .entryClone:
                cloningModulePredictionPanel(
                    hasData: hasEntryCloneData,
                    moduleName: "入门克隆",
                    targetNav: .entryClone,
                    badges: entryCloneSummaryBadges,
                    supportsMixedControl: true,
                    onPredictLive: { injectEntryCloneLanes(useDemo: false) },
                    onPredictDemo: { injectEntryCloneLanes(useDemo: true) }
                )
                
            case .fragmentDeletion:
                cloningModulePredictionPanel(
                    hasData: hasFragmentDeletionData,
                    moduleName: "片段删除",
                    targetNav: .fragmentDeletion,
                    badges: fragmentDeletionSummaryBadges,
                    supportsMixedControl: true,
                    onPredictLive: { injectFragmentDeletionLanes(useDemo: false) },
                    onPredictDemo: { injectFragmentDeletionLanes(useDemo: true) }
                )
                
            case .mutagenesis:
                cloningModulePredictionPanel(
                    hasData: hasMutagenesisData,
                    moduleName: "定点突变",
                    targetNav: .mutagenesis,
                    badges: mutagenesisSummaryBadges,
                    supportsMixedControl: false,
                    onPredictLive: { injectMutagenesisLane(useDemo: false) },
                    onPredictDemo: { injectMutagenesisLane(useDemo: true) }
                )
                
            case .customSizes:
                customSizesPredictionPanel
            }
        }
        .studioInnerBox(tint: .teal, paddingH: 10, paddingV: 10)
    }
    
    private func cloningModulePredictionPanel(
        hasData: Bool,
        moduleName: String,
        targetNav: NavItem,
        badges: [(label: String, value: String, color: Color)],
        supportsMixedControl: Bool,
        onPredictLive: @escaping () -> Void,
        onPredictDemo: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: GelUI.row) {
            if hasData {
                StudioFlowLayout(horizontalSpacing: GelUI.chip, verticalSpacing: GelUI.chip) {
                    ForEach(Array(badges.enumerated()), id: \.offset) { _, b in
                        StudioMetricBadge(label: b.label, value: b.value, color: b.color)
                    }
                }
                
                StudioFlowLayout(horizontalSpacing: GelUI.row, verticalSpacing: GelUI.row) {
                    StudioActionPillButton(
                        title: "叠加",
                        icon: "plus.viewfinder",
                        tint: .teal,
                        isProminent: true,
                        help: "将「\(moduleName)」当前配置的理论条带映射到胶图",
                        action: onPredictLive
                    )
                    
                    if supportsMixedControl {
                        StudioActionPillButton(
                            title: "混合对照",
                            icon: "square.on.square",
                            tint: .teal,
                            isProminent: includeMixedControlLane,
                            help: includeMixedControlLane ? "已开启：同时叠加混合共泳道对照（点击关闭）" : "同时叠加混合共泳道对照"
                        ) {
                            includeMixedControlLane.toggle()
                        }
                    }
                    
                    StudioActionPillButton(
                        title: "",
                        icon: "arrow.up.right.square",
                        help: "前往\(moduleName)模块"
                    ) {
                        appState.selectedNav = targetNav
                    }
                }
            } else {
                Label("暂无数据", systemImage: "tray")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("「\(moduleName)」尚未载入质粒或输入序列，可前往配置或直接用示范参数预测")
                
                StudioFlowLayout(horizontalSpacing: GelUI.row, verticalSpacing: GelUI.row) {
                    StudioActionPillButton(
                        title: "示范预测",
                        icon: "sparkles",
                        tint: .teal,
                        isProminent: true,
                        help: "使用示范参数生成「\(moduleName)」虚拟预测泳道",
                        action: onPredictDemo
                    )
                    
                    StudioActionPillButton(
                        title: "",
                        icon: "arrow.up.right.square",
                        help: "前往\(moduleName)模块"
                    ) {
                        appState.selectedNav = targetNav
                    }
                }
            }
        }
    }
    
    private var customSizesPredictionPanel: some View {
        let unit = activeLadder.kind.unit
        let parsed = GelAnalysisEngine.parseCustomBandSizes(customBandSizesText)
        return VStack(alignment: .leading, spacing: GelUI.row) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: GelUI.row) {
                    TextField("泳道名", text: $customLaneName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .font(.system(size: 12))
                        .frame(minWidth: 88, idealWidth: 120, maxWidth: 160)
                    
                    TextField("条带大小 (\(unit)，逗号/空格分隔)", text: $customBandSizesText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .frame(minWidth: 150, maxWidth: .infinity)
                }
                
                VStack(alignment: .leading, spacing: GelUI.chip) {
                    TextField("泳道名", text: $customLaneName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .font(.system(size: 12))
                    
                    TextField("条带大小 (\(unit)，逗号/空格分隔)", text: $customBandSizesText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .font(.system(size: 12))
                        .monospacedDigit()
                }
            }
            
            StudioFlowLayout(horizontalSpacing: GelUI.chip, verticalSpacing: GelUI.chip) {
                if activeLadder.kind == .dna {
                    StudioCompactPillButton(title: "PCR 1500/750", help: "填入 PCR 预期：1500, 750 bp") {
                        customLaneName = "PCR-预期"
                        customBandSizesText = "1500, 750"
                    }
                    StudioCompactPillButton(title: "酶切 4200/1200", help: "填入双酶切预期：4200, 1200 bp") {
                        customLaneName = "双酶切-预期"
                        customBandSizesText = "4200, 1200"
                    }
                    StudioCompactPillButton(title: "三带", help: "填入三带对照：3000, 1000, 500 bp") {
                        customLaneName = "三带对照"
                        customBandSizesText = "3000, 1000, 500"
                    }
                } else {
                    StudioCompactPillButton(title: "单带 55", help: "填入单带预期：55 kDa") {
                        customLaneName = "Target-55kDa"
                        customBandSizesText = "55"
                    }
                    StudioCompactPillButton(title: "双带 70/37", help: "填入双带预期：70, 37 kDa") {
                        customLaneName = "Cleavage-预期"
                        customBandSizesText = "70, 37"
                    }
                    StudioCompactPillButton(title: "多聚体", help: "填入多聚体预期：140, 70, 35 kDa") {
                        customLaneName = "Oligomer-预期"
                        customBandSizesText = "140, 70, 35"
                    }
                }
            }
            
            StudioFlowLayout(horizontalSpacing: GelUI.row, verticalSpacing: GelUI.row) {
                StudioActionPillButton(
                    title: "叠加",
                    icon: "plus.viewfinder",
                    tint: .teal,
                    isProminent: true,
                    isDisabled: parsed.isEmpty,
                    help: "将输入的条带分子量按当前 Marker 标准曲线映射到胶图",
                    action: injectCustomSizesLane
                )
                
                if !parsed.isEmpty {
                    StudioMetricBadge(label: "", value: "\(parsed.count) 条带 · \(unit)", color: .cyan)
                        .help("已解析 \(parsed.count) 条自定义条带，单位 \(unit)")
                }
            }
        }
    }
    
    // MARK: - 各克隆模块当前状态摘要
    private var singleFragmentSummaryBadges: [(label: String, value: String, color: Color)] {
        var list: [(String, String, Color)] = []
        if singleVM.effectiveVectorBackboneLengthBp > 0 {
            list.append(("载体", "\(singleVM.effectiveVectorBackboneLengthBp) bp", .blue))
        }
        if singleVM.cleanInsertLengthBp > 0 {
            let name = singleVM.insertGeneName.isEmpty ? "插入" : singleVM.insertGeneName
            list.append((name, "\(singleVM.cleanInsertLengthBp) bp", .green))
        }
        list.append(("同源臂", "\(singleVM.homologyLength) bp", .teal))
        return list
    }
    
    private var multiFragmentSummaryBadges: [(label: String, value: String, color: Color)] {
        let validCount = multiVM.fragments.filter { BioSequence.clean($0).count >= 50 }.count
        var list: [(String, String, Color)] = []
        if multiVM.effectiveVectorBackboneLengthBp > 0 {
            list.append(("载体", "\(multiVM.effectiveVectorBackboneLengthBp) bp", .blue))
        }
        list.append(("有效片段", "\(validCount) 个", .green))
        list.append(("同源臂", "\(multiVM.homologyLength) bp", .teal))
        return list
    }
    
    private var entryCloneSummaryBadges: [(label: String, value: String, color: Color)] {
        var list: [(String, String, Color)] = [
            ("载体", "pCE2 (3957 bp)", .blue),
            ("目的基因", "\(entryVM.cleanLength) bp", .green)
        ]
        if entryVM.hasEnzymes {
            let e5 = entryVM.enzyme5?.name ?? "5'酶"
            let e3 = entryVM.enzyme3?.name ?? "3'酶"
            list.append(("酶切位点", "\(e5)/\(e3)", .teal))
        }
        return list
    }
    
    private var fragmentDeletionSummaryBadges: [(label: String, value: String, color: Color)] {
        let pLen = deletionVM.plasmidDNAInfo?.length ?? BioSequence.clean(deletionVM.plasmidSeq).count
        return [
            ("原质粒", "\(pLen) bp", .blue),
            ("删除长度", "Δ\(deletionVM.estimatedDeletionLengthBp) bp", .orange),
            ("同源臂", "\(deletionVM.homologyLength) bp", .teal)
        ]
    }
    
    private var mutagenesisSummaryBadges: [(label: String, value: String, color: Color)] {
        let pLen = mutagenesisVM.plasmidDNAInfo?.length
            ?? (BioSequence.clean(mutagenesisVM.mutUp).count + BioSequence.clean(mutagenesisVM.mutDown).count)
        var list: [(String, String, Color)] = [
            ("模板", "\(pLen) bp", .blue),
            ("重叠臂", "\(mutagenesisVM.homologyLength) bp", .teal)
        ]
        if !mutagenesisVM.mutationSummaryLabel.isEmpty {
            list.append(("突变", mutagenesisVM.mutationSummaryLabel, .purple))
        }
        return list
    }
    
    // MARK: - 右栏：响应式凝胶电泳拼图与分子量标尺画布
    private var rightColumn: some View {
        StudioCard(
            title: "胶图",
            headerTrailing: {
                StudioFlowLayout(horizontalSpacing: GelUI.row, verticalSpacing: GelUI.chip) {
                    StudioMetricBadge(
                        label: "",
                        value: "\(lanes.count) 泳道 · \(activeLadder.kind.unit)",
                        color: .cyan
                    )
                    .help("共 \(lanes.count) 个泳道，分子量单位 \(activeLadder.kind.unit)")
                    
                    StudioActionPillButton(
                        title: "标尺",
                        icon: "ruler",
                        tint: .orange,
                        isProminent: showLadderRuler,
                        help: showLadderRuler ? "隐藏左侧 Marker 标尺" : "显示左侧 Marker 标尺"
                    ) {
                        showLadderRuler.toggle()
                    }
                    
                    StudioActionPillButton(
                        title: "分子量",
                        icon: "textformat.123",
                        tint: .cyan,
                        isProminent: showBandSizeOverlay,
                        help: showBandSizeOverlay ? "隐藏条带推算分子量" : "显示条带推算分子量"
                    ) {
                        showBandSizeOverlay.toggle()
                    }
                }
            }
        ) {
            VStack(alignment: .leading, spacing: GelUI.row) {
                GeometryReader { geo in
                    let aspect = CGFloat(plane.width) / CGFloat(max(1, plane.height))
                    let availW = max(1, geo.size.width - 16)
                    let availH = max(1, geo.size.height - 16)
                    let drawW = max(1, min(availW, availH * aspect))
                    let drawH = max(1, drawW / max(0.2, aspect))
                    
                    ZStack {
                        if let nsImg = plane.toNSImage() {
                            Image(nsImage: nsImg)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: drawW, height: drawH)
                                .clipShape(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous))
                        }
                        
                        Canvas { context, _ in
                            let staggerHeaders = lanes.count > 5
                            for (laneOffset, lane) in lanes.enumerated() {
                                let lx = CGFloat(lane.centerX) * drawW
                                let bw = CGFloat(lane.widthFrac) * drawW
                                
                                if lane.isVirtualDigestLane {
                                    let topPad: CGFloat = staggerHeaders ? 34 : 26
                                    let laneRect = CGRect(
                                        x: lx - bw * 0.52,
                                        y: topPad,
                                        width: bw * 1.04,
                                        height: max(40, drawH - topPad - 8)
                                    )
                                    context.fill(
                                        Path(roundedRect: laneRect, cornerRadius: 4),
                                        with: .color(Color.cyan.opacity(0.08))
                                    )
                                }
                                
                                // 泳道顶部名称标签（泳道较多时自动错行并截断，避免文字重叠）
                                let headerY: CGFloat = staggerHeaders ? (laneOffset.isMultiple(of: 2) ? 11 : 23) : 14
                                let displayName = Self.shortName(lane.name, maxLength: lanes.count > 5 ? 12 : 16)
                                let headerText = Text(displayName)
                                    .font(.system(size: staggerHeaders ? 9 : 10, weight: .bold))
                                    .foregroundColor(lane.isVirtualDigestLane ? .cyan : .white)
                                context.draw(headerText, at: CGPoint(x: lx, y: headerY))
                                
                                for band in lane.bands {
                                    let by = CGFloat(band.yFraction) * drawH
                                    var line = Path()
                                    line.move(to: CGPoint(x: lx - bw * 0.45, y: by))
                                    line.addLine(to: CGPoint(x: lx + bw * 0.45, y: by))
                                    
                                    let strokeColor: Color = lane.isLadderLane
                                        ? .orange
                                        : (band.isVirtualDigestBand ? .cyan : .green)
                                    context.stroke(
                                        line,
                                        with: .color(strokeColor),
                                        style: StrokeStyle(
                                            lineWidth: band.isVirtualDigestBand ? 2.4 : 1.8,
                                            dash: band.isVirtualDigestBand ? [4, 2] : []
                                        )
                                    )
                                    
                                    if lane.isLadderLane && showLadderRuler, let sz = band.knownSize {
                                        let rulerTxt = Text(activeLadder.kind == .dna ? "\(Int(sz))" : String(format: "%.0f", sz))
                                            .font(.system(size: 9.5, weight: .bold))
                                            .monospacedDigit()
                                            .foregroundColor(.orange)
                                        context.draw(rulerTxt, at: CGPoint(x: max(22, lx - bw * 0.65), y: by), anchor: .trailing)
                                    } else if !lane.isLadderLane && showBandSizeOverlay, let est = band.estimatedSize {
                                        let szTxt = Text(activeLadder.kind == .dna ? "\(Int(round(est)))" : String(format: "%.1f", est))
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .monospacedDigit()
                                            .foregroundColor(band.isVirtualDigestBand ? .cyan : .yellow)
                                        context.draw(szTxt, at: CGPoint(x: lx, y: by - 9))
                                    }
                                }
                            }
                        }
                        .frame(width: drawW, height: drawH)
                    }
                    .allowedDynamicRange(.standard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(minHeight: 360, maxHeight: 520)
                .background(
                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                
                StudioFlowLayout(horizontalSpacing: GelUI.chip, verticalSpacing: GelUI.chip) {
                    StudioMetricBadge(label: "", value: "Marker", color: .orange)
                        .help("橙色标尺：Marker 标准品校准带")
                    StudioMetricBadge(label: "", value: "实测", color: .green)
                        .help("绿色实线：实测样品条带及回归推算分子量")
                    StudioMetricBadge(label: "", value: "预测", color: .cyan)
                        .help("青色虚线：理论预测对照带（酶切/克隆模块/自定义）")
                }
            }
        }
    }
    
    // MARK: - 交互动作与多模块虚拟预测注入
    
    private func syncSelectedPlasmidID() {
        if let first = plasmidPool.selectedItem ?? plasmidPool.items.first {
            if !plasmidPool.items.contains(where: { $0.id == selectedPlasmidID }) {
                selectedPlasmidID = first.id
            }
        } else {
            selectedPlasmidID = "__demo__"
        }
    }
    
    private func runAutoDetection() {
        let existingVirtual = lanes.filter(\.isVirtualDigestLane)
        let res = GelAnalysisEngine.autoDetectAndCalibrate(plane: plane, ladder: activeLadder)
        if existingVirtual.isEmpty {
            lanes = res.lanes
            calibrationFit = res.fit
        } else {
            let combined = res.lanes + existingVirtual
            let recalibrated = GelAnalysisEngine.recalibrateLanes(lanes: combined, ladder: activeLadder)
            lanes = GelAnalysisEngine.layoutVirtualLanes(recalibrated.lanes)
            calibrationFit = recalibrated.fit
        }
    }
    
    private func appendVirtualLanes(_ newLanes: [GelLaneItem], sourceKey: String, toastMessage: String) {
        guard !newLanes.isEmpty else {
            appState.showToast("当前配置未能生成有效预测条带")
            return
        }
        lanes.append(contentsOf: newLanes)
        lanes = GelAnalysisEngine.layoutVirtualLanes(lanes)
        if !appliedPredictionSources.contains(sourceKey) {
            appliedPredictionSources.append(sourceKey)
        }
        appState.showToast(toastMessage)
    }
    
    private func injectActivePredictionSource() {
        switch predictionSource {
        case .plasmidDigest:
            injectVirtualDigestLaneFromPool()
        case .singleFragment:
            injectSingleFragmentLanes(useDemo: !hasSingleFragmentData)
        case .multiFragment:
            injectMultiFragmentLanes(useDemo: !hasMultiFragmentData)
        case .entryClone:
            injectEntryCloneLanes(useDemo: !hasEntryCloneData)
        case .fragmentDeletion:
            injectFragmentDeletionLanes(useDemo: !hasFragmentDeletionData)
        case .mutagenesis:
            injectMutagenesisLane(useDemo: !hasMutagenesisData)
        case .customSizes:
            injectCustomSizesLane()
        }
    }
    
    private func injectVirtualDigestLaneFromPool() {
        let targetPlasmid = plasmidPool.items.first(where: { $0.id == selectedPlasmidID })
            ?? plasmidPool.selectedItem
            ?? plasmidPool.items.first
        let seq = targetPlasmid?.dnaInfo.sequence ?? Self.demoDigestSequence
        let name = targetPlasmid?.name ?? "pETDuet-Demo"
        let isCirc = targetPlasmid?.dnaInfo.isCircular ?? true
        let enzymes = selectedEnzyme2 == Self.singleCutOption
            ? [selectedEnzyme1]
            : (selectedEnzyme2 == selectedEnzyme1 ? [selectedEnzyme1] : [selectedEnzyme1, selectedEnzyme2])
        
        let vLane = GelAnalysisEngine.buildVirtualDigestLane(
            plasmidName: name,
            sequence: seq,
            isCircular: isCirc,
            enzymeNames: enzymes,
            fit: calibrationFit,
            laneIndex: lanes.count + 1
        )
        let enzDesc = enzymes.joined(separator: "+")
        appendVirtualLanes(
            [vLane],
            sourceKey: GelVirtualPredictionSource.plasmidDigest.rawValue,
            toastMessage: "已叠加「\(name)」(\(enzDesc)) 理论酶切预测道"
        )
    }
    
    private func injectSingleFragmentLanes(useDemo: Bool) {
        let sim: HomologousPCRGelSimulationResult
        if useDemo {
            sim = HomologousPCRGelSimulator.simulateSingleFragment(
                rawVectorLengthBp: 5400,
                effectiveVectorBackboneLengthBp: 4800,
                deletedVectorBp: 600,
                linearizationMode: .double,
                cleanInsertCoreLengthBp: 1200,
                homologyLength: 18,
                insertGeneName: "EGFP",
                includeMixControlLane: includeMixedControlLane
            )
        } else {
            let hasFullVector = singleVM.vectorDNAInfo != nil || singleVM.rawVectorLengthBp >= 300
            sim = HomologousPCRGelSimulator.simulateSingleFragment(
                rawVectorLengthBp: hasFullVector ? singleVM.rawVectorLengthBp : 0,
                effectiveVectorBackboneLengthBp: hasFullVector ? singleVM.effectiveVectorBackboneLengthBp : 0,
                deletedVectorBp: hasFullVector ? singleVM.deletedVectorBp : 0,
                linearizationMode: singleVM.mode,
                cleanInsertCoreLengthBp: singleVM.cleanInsertLengthBp,
                extra5LengthBp: BioSequence.clean(singleVM.extra5Bases).count,
                extra3LengthBp: BioSequence.clean(singleVM.extra3Bases).count,
                homologyLength: singleVM.homologyLength,
                insertGeneName: singleVM.insertGeneName,
                includeVectorPCRPrimers: singleVM.includeVectorPCRPrimers,
                primers: singleVM.primers,
                omittedShortVectorBp: hasFullVector ? 0 : singleVM.effectiveVectorBackboneLengthBp,
                includeMixControlLane: includeMixedControlLane
            )
        }
        let vLanes = GelAnalysisEngine.buildVirtualLanesFromSimulation(
            sim,
            sourceTag: "单片段",
            fit: calibrationFit,
            startingLaneIndex: lanes.count + 1,
            includeMixedControl: includeMixedControlLane
        )
        appendVirtualLanes(
            vLanes,
            sourceKey: GelVirtualPredictionSource.singleFragment.rawValue,
            toastMessage: "已叠加单片段克隆 \(vLanes.count) 条虚拟预测泳道"
        )
    }
    
    private func injectMultiFragmentLanes(useDemo: Bool) {
        let sim: HomologousPCRGelSimulationResult
        if useDemo {
            sim = HomologousPCRGelSimulator.simulateMultiFragment(
                effectiveVectorBackboneLengthBp: 4500,
                deletedVectorBp: 0,
                rawVectorLengthBp: 4500,
                fragments: [
                    String(repeating: "ATGC", count: 160),
                    String(repeating: "GCTA", count: 240)
                ],
                homologyLength: 18,
                includeMixControlLane: includeMixedControlLane
            )
        } else {
            let hasFullVector = multiVM.vectorDNAInfo != nil || multiVM.rawVectorLengthBp >= 300
            sim = HomologousPCRGelSimulator.simulateMultiFragment(
                effectiveVectorBackboneLengthBp: hasFullVector ? multiVM.effectiveVectorBackboneLengthBp : 0,
                deletedVectorBp: hasFullVector ? multiVM.deletedVectorBp : 0,
                rawVectorLengthBp: hasFullVector ? multiVM.rawVectorLengthBp : 0,
                fragments: multiVM.fragments,
                fragmentExtra5Bases: multiVM.fragmentExtra5Bases,
                terminalExtra3Bases: multiVM.terminalExtra3Bases,
                homologyLength: multiVM.homologyLength,
                primers: multiVM.primers,
                omittedShortVectorBp: hasFullVector ? 0 : multiVM.effectiveVectorBackboneLengthBp,
                includeMixControlLane: includeMixedControlLane
            )
        }
        let vLanes = GelAnalysisEngine.buildVirtualLanesFromSimulation(
            sim,
            sourceTag: "多片段",
            fit: calibrationFit,
            startingLaneIndex: lanes.count + 1,
            includeMixedControl: includeMixedControlLane
        )
        appendVirtualLanes(
            vLanes,
            sourceKey: GelVirtualPredictionSource.multiFragment.rawValue,
            toastMessage: "已叠加多片段组装 \(vLanes.count) 条虚拟预测泳道"
        )
    }
    
    private func injectEntryCloneLanes(useDemo: Bool) {
        let sim: HomologousPCRGelSimulationResult
        if useDemo {
            sim = HomologousPCRGelSimulator.simulateEntryClone(
                cleanInsertLengthBp: 960,
                hasEnzymes: true,
                enzyme5: RestrictionEnzymeDatabase.shared.find(name: "BamHI"),
                enzyme3: RestrictionEnzymeDatabase.shared.find(name: "EcoRI"),
                primerF: nil,
                primerR: nil,
                includeMixControlLane: includeMixedControlLane
            )
        } else {
            sim = HomologousPCRGelSimulator.simulateEntryClone(
                cleanInsertLengthBp: entryVM.cleanLength,
                hasEnzymes: entryVM.hasEnzymes,
                enzyme5: entryVM.enzyme5,
                enzyme3: entryVM.enzyme3,
                primerF: entryVM.primerF,
                primerR: entryVM.primerR,
                includeMixControlLane: includeMixedControlLane
            )
        }
        let vLanes = GelAnalysisEngine.buildVirtualLanesFromSimulation(
            sim,
            sourceTag: "入门",
            fit: calibrationFit,
            startingLaneIndex: lanes.count + 1,
            includeMixedControl: includeMixedControlLane
        )
        appendVirtualLanes(
            vLanes,
            sourceKey: GelVirtualPredictionSource.entryClone.rawValue,
            toastMessage: "已叠加入门克隆 \(vLanes.count) 条虚拟预测泳道"
        )
    }
    
    private func injectFragmentDeletionLanes(useDemo: Bool) {
        let sim: HomologousPCRGelSimulationResult
        if useDemo {
            sim = HomologousPCRGelSimulator.simulateFragmentDeletion(
                parentalLengthBp: 5800,
                deletedLengthBp: 1100,
                homologyLength: 18,
                includeCompareLane: includeMixedControlLane
            )
        } else {
            let parentalLen = deletionVM.plasmidDNAInfo?.length ?? BioSequence.clean(deletionVM.plasmidSeq).count
            sim = HomologousPCRGelSimulator.simulateFragmentDeletion(
                parentalLengthBp: parentalLen,
                deletedLengthBp: deletionVM.estimatedDeletionLengthBp,
                homologyLength: deletionVM.homologyLength,
                primers: deletionVM.primers,
                includeCompareLane: includeMixedControlLane
            )
        }
        let vLanes = GelAnalysisEngine.buildVirtualLanesFromSimulation(
            sim,
            sourceTag: "删除",
            fit: calibrationFit,
            startingLaneIndex: lanes.count + 1,
            includeMixedControl: includeMixedControlLane
        )
        appendVirtualLanes(
            vLanes,
            sourceKey: GelVirtualPredictionSource.fragmentDeletion.rawValue,
            toastMessage: "已叠加片段删除 \(vLanes.count) 条虚拟预测泳道"
        )
    }
    
    private func injectMutagenesisLane(useDemo: Bool) {
        let vLane: GelLaneItem
        if useDemo {
            vLane = GelAnalysisEngine.buildMutagenesisVirtualLane(
                plasmidName: "pCMV-Demo",
                parentalLengthBp: 5200,
                mutatedLengthBp: 5200,
                homologyLength: 18,
                mutationLabel: "R175H",
                fit: calibrationFit,
                laneIndex: lanes.count + 1
            )
        } else {
            let pLen = mutagenesisVM.plasmidDNAInfo?.length
                ?? (BioSequence.clean(mutagenesisVM.mutUp).count + BioSequence.clean(mutagenesisVM.mutDown).count)
            let replacedLen = max(0, mutagenesisVM.mutTargetEndBp - mutagenesisVM.mutTargetStartBp + 1)
            let siteLen = BioSequence.clean(mutagenesisVM.mutSite).count
            let mutatedLen = mutagenesisVM.plasmidDNAInfo != nil
                ? max(100, pLen - replacedLen + siteLen)
                : max(100, pLen + siteLen)
            let pName = mutagenesisVM.plasmidDNAInfo?.fileName.replacingOccurrences(of: ".dna", with: "") ?? "MutPlasmid"
            vLane = GelAnalysisEngine.buildMutagenesisVirtualLane(
                plasmidName: pName,
                parentalLengthBp: pLen,
                mutatedLengthBp: mutatedLen,
                homologyLength: mutagenesisVM.homologyLength,
                mutationLabel: mutagenesisVM.mutationSummaryLabel,
                fit: calibrationFit,
                laneIndex: lanes.count + 1
            )
        }
        appendVirtualLanes(
            [vLane],
            sourceKey: GelVirtualPredictionSource.mutagenesis.rawValue,
            toastMessage: "已叠加定点突变反向 PCR 虚拟预测泳道"
        )
    }
    
    private func injectCustomSizesLane() {
        let sizes = GelAnalysisEngine.parseCustomBandSizes(customBandSizesText)
        guard !sizes.isEmpty else {
            appState.showToast("请输入有效的条带数值（例如 1500, 750）")
            return
        }
        let vLane = GelAnalysisEngine.buildCustomVirtualLane(
            laneName: customLaneName,
            sizes: sizes,
            fit: calibrationFit,
            laneIndex: lanes.count + 1
        )
        appendVirtualLanes(
            [vLane],
            sourceKey: GelVirtualPredictionSource.customSizes.rawValue,
            toastMessage: "已叠加自定义预测泳道「\(vLane.name)」(\(sizes.count) 条带)"
        )
    }
    
    private func importGelImage() {
        FinderFileDropHelper.presentOpenPanel { url in
            if let img = NSImage(contentsOf: url),
               let loadedPlane = BioImagePlane.fromNSImage(img, maxDimension: 520) {
                sourceImageURL = url
                plane = loadedPlane
                runAutoDetection()
                appState.showToast("已导入电泳胶图并完成自动寻道与分子量拟合")
            }
        }
    }
    
    private func exportGelCSV() {
        let curLanes = lanes
        let curLadder = activeLadder
        let curFit = calibrationFit
        let curSourceURL = sourceImageURL
        let hasVirtual = curLanes.contains(where: \.isVirtualDigestLane)
        let enzymes: [String] = {
            guard hasVirtual && appliedPredictionSources.contains(GelVirtualPredictionSource.plasmidDigest.rawValue) else {
                return []
            }
            return selectedEnzyme2 == Self.singleCutOption ? [selectedEnzyme1] : [selectedEnzyme1, selectedEnzyme2]
        }()
        let sources = hasVirtual ? appliedPredictionSources : []
        let linkedIDs = hasVirtual
            ? [plasmidPool.items.first(where: { $0.id == selectedPlasmidID })?.id ?? plasmidPool.selectedItem?.id ?? plasmidPool.items.first?.id].compactMap { $0 }
            : []
        let csv = GelAnalysisEngine.exportGelBandsCSV(lanes: curLanes, unit: curLadder.kind.unit)
        FinderFileDropHelper.saveTextToFile(
            content: csv,
            defaultFileName: "Gel_Electrophoresis_MolecularWeight_Fit.csv",
            contentType: .commaSeparatedText,
            toastPrefix: "已导出电泳条带分子量 CSV",
            onSavedURL: { savedURL in
                _ = try? GelAnalysisEngine.exportGelBandsCSVWithProvenance(
                    lanes: curLanes,
                    ladder: curLadder,
                    fit: curFit,
                    sourceImageURL: curSourceURL,
                    virtualDigestEnzymes: enzymes,
                    virtualPredictionSources: sources,
                    linkedPlasmidIDs: linkedIDs,
                    to: savedURL
                )
            }
        )
    }
    
    private static let demoDigestSequence: String = "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGGAATTCACTAGTAACGGCCGCCAGTGTGCTGG" + String(repeating: "ATGCGATCGATCGATC", count: 80) + "GGATCCGAGCTCCAGCTTTTGTTCCCTTTAGTGAGGGTTAATTGCGCGCTTGGCGTAATCATGGTCATAGCTGTTTCCTGTGTGAAATTGTTATCCGCTCACAATTCCACACAACATACGAGCCGGAAGCATAAAGTGTAAAGCCTGGGGTGCCTAATGAGTGAGCTAACTCACATTAATTGCGTTGCGCTCACTGCCCGCTTTCCAGTCGGGAAACCTGTCGTGCCAGCTGCATTAATGAATCGGCCAACGCGCGGGGAGAGGCGGTTTGCGTATTGGGCGCTCTTCCGCTTCCTCGCTCACTGACTCGCTGCGCTCGGTCGTTCGGCTGCGGCGAGCGGTATCAGCTCACTCAAAGGCGGTAATACGGTTATCCACAGAATCAGGGGATAACGCAGGAAAGAACATGTGAGCAAAAGGCCAGCAAAAGGCCAGGAACCGTAAAAAGGCCGCGTTGCTGGCGTTTTTCCATAGGCTCCGCCCCCCTGACGAGCATCACAAAAATCGACGCTCAAGTCAGAGGTGGCGAAACCCGACAGGACTATAAAGATACCAGGCGTTTCCCCCTGGAAGCTCCCTCGTGCGCTCTCCTGTTCCGACCCTGCCGCTTACCGGATACCTGTCCGCCTTTCTCCCTTCGGGAAGCGTGGCGCTTTCTCATAGCTCACGCTGTAGGTATCTCAGTTCGGTGTAGGTCGTTCGCTCCAAGCTGGGCTGTGTGCACGAACCCCCCGTTCAGCCCGACCGCTGCGCCTTATCCGGTAACTATCGGTCTTGAGTCCAACCCGGTAAGACACGACTTATCGCCACTGGCAGCAGCCACTGGTAACAGGATTAGCAGAGCGAGGTATGTAGGCGGTGCTACAGAGTTCTTGAAGTGGTGGCCTAACTACGGCTACACTAGAAGAACAGTATTTGGTATCTGCGCTCTGCTGAAGCCAGTTACCTTCGGAAAAAGAGTTGGTAGCTCTTGATCCGGCAAACAAACCACCGCTGGTAGCGGTGGTTTTTTTGTTTGCAAGCAGCAGATTACGCGCAGAAAAAAAGGATCTCAAGAAGATCCTTTGATCTTTTCTACGGGGTCTGACGCTCAGTGGAACGAAAACTCACGTTAAGGGATTTTGGTCATGAGATTATCAAAAAGGATCTTCACCTAGATCCTTTTAAATTAAAAATGAAGTTTTAAATCAATCTAAAGTATATATGAGTAAACTTGGTCTGACAGTTACCAATGCTTAATCAGTGAGGCACCTATCTCAGCGATCTGTCTATTTCGTTCATCCATAGTTGCCTGACTCCCCGTCGTGTAGATAACTACGATACGGGAGGGCTTACCATCTGGCCCCAGTGCTGCAATGATACCGCGAGACCCACGCTCACCGGCTCCAGATTTATCAGCAATAAACCAGCCAGCCGGAAGGGCCGAGCGCAGAAGTGGTCCTGCAACTTTATCCGCCTCCATCCAGTCTATTAATTGTTGCCGGGAAGCTAGAGTAAGTAGTTCGCCAGTTAATAGTTTGCGCAACGTTGTTGCCATTGCTACAGGCATCGTGGTGTCACGCTCGTCGTTTGGTATGGCTTCATTCAGCTCCGGTTCCCAACGATCAAGGCGAGTTACATGATCCCCCATGTTGTGCAAAAAAGCGGTTAGCTCCTTCGGTCCTCCGATCGTTGTCAGAAGTAAGTTGGCCGCAGTGTTATCACTCATGGTTATGGCAGCACTGCATAATTCTCTTACTGTCATGCCATCCGTAAGATGCTTTTCTGTGACTGGTGAGTACTCAACCAAGTCATTCTGAGAATAGTGTATGCGGCGACCGAGTTGCTCTTGCCCGGCGTCAATACGGGATAATACCGCGCCACATAGCAGAACTTTAAAAGTGCTCATCATTGGAAAACGTTCTTCGGGGCGAAAACTCTCAAGGATCTTACCGCTGTTGAGATCCAGTTCGATGTAACCCACTCGTGCACCCAACTGATCTTCAGCATCTTTTACTTTCACCAGCGTTTCTGGGTGAGCAAAAACAGGAAGGCAAAATGCCGCAAAAAAGGGAATAAGGGCGACACGGAAATGTTGAATACTCATACTCTTCCTTTTTCAATATTATTGAAGCATTTATCAGGGTTATTGTCTCATGAGCGGATACATATTTGAATGTATTTAGAAAAATAAACAAATAGGGGTTCCGCGCACATTTCCCCGAAAAGTGCCACCTGACGTCTAAGAAACCATTATTATCATGACATTAACCTATAAAAATAGGCGTATCACGAGGCCCTTTCGTCTCGCGCGTTTCGGTGATGACGGTGAAAACCTCTGACACATGCAGCTCCCGGAGACGGTCACAGCTTGTCTGTAAGCGGATGCCGGGAGCAGACAAGCCCGTCAGGGCGCGTCAGCGGGTGTTGGCGGGTGTCGGGGCTGGCTTAACTATGCGGCATCAGAGCAGATTGTACTGAGAGTGCACCATATGCGGTGTGAAATACCGCACAGATGCGTAAGGAGAAAATACCGCATCAGGCGCCATTCGCCATTCAGGCTGCGCAACTGTTGGGAAGGGCGATCGGTGCGGGCCTCTTCGCTATTACGCCAGCTGGCGAAAGGGGGATGTGCTGCAAGGCGATTAAGTTGGGTAACGCCAGGGTTTTCCCAGTCACGACGTTGTAAAACGACGGCCAGT"
}
