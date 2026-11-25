import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// qPCR 定量分析与统计图表主视图 (纯声明式响应式 UI：任意拉动窗口自动折行与自适应滚动表格)
public struct QPCRAnalysisView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var plateStore = PlateLayoutStore.shared
    @ObservedObject private var poolManager = PlasmidPoolManager.shared
    
    @State private var mode: QPCRAnalysisMode = .ddct
    @State private var rawCSVText: String = QPCRAnalysisEngine.defaultExampleCSV
    @State private var sourceFileURL: URL? = nil
    @State private var wells: [QPCRWellRecord] = []
    @State private var settings: QPCRSettings = QPCRSettings()
    @State private var errorBarMode: QPCRErrorBarMode = .sem
    @State private var selectedQCFilter: QPCRQCFlag? = nil
    @State private var showCSVEditor: Bool = false
    @State private var showHeatmap: Bool = true
    @State private var linkedPlasmidIDs: Set<String> = []
    @State private var detectedInstrumentFormat: QPCRInstrumentFormat = .genericCSV
    @State private var importMetaSummary: String = ""
    @State private var isMIQEExpanded: Bool = true
    
    public init() {}
    
    private var qcMap: [String: QPCRWellQCResult] {
        QPCRAnalysisEngine.computeQC(wells: wells, settings: settings)
    }
    
    private var ddctOut: QPCRDdctAnalysisOut {
        QPCRAnalysisEngine.computeDdct(wells: wells, settings: settings, qc: qcMap)
    }
    
    private var stdOut: QPCRStandardAnalysisOut {
        QPCRAnalysisEngine.computeStandardCurve(wells: wells, settings: settings, qc: qcMap)
    }

    private var miqeReport: MIQEComplianceReport {
        QPCRInstrumentAndRDMLEngine.evaluateMIQECompliance(
            wells: wells,
            settings: settings,
            qc: qcMap,
            ddctOut: ddctOut,
            stdOut: stdOut,
            detectedFormat: detectedInstrumentFormat
        )
    }
    
    private var modeOptions: [StudioSegmentedOption<QPCRAnalysisMode>] {
        QPCRAnalysisMode.allCases.map { m in
            StudioSegmentedOption(value: m, title: m.title, tint: m == .ddct ? .teal : .blue)
        }
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "qPCR 定量",
            toolbar: [
                .picker(
                    id: "qpcr_mode",
                    label: "分析模式",
                    options: QPCRAnalysisMode.allCases.map { m in
                        StudioToolbarPickerOption(
                            id: m.title,
                            title: m.title,
                            tint: m == .ddct ? .teal : .blue,
                            isSelected: mode == m
                        ) {
                            mode = m
                        }
                    }
                ),
                .action(title: "同步板", icon: "square.grid.3x3.fill", tint: .blue, help: "关联微孔板设计器中的样品与分组映射") {
                    wells = QPCRAnalysisEngine.mergeWithPlateAssignments(
                        existingWells: wells,
                        assignments: plateStore.assignments
                    )
                    syncDefaultRefAndControlIfNeeded()
                    appState.showToast("已关联微孔板设计器中的样品与分组映射")
                },
                .action(title: "示范", icon: "sparkles", help: "载入 TP53 / MYC 标准 qPCR 示范数据集") {
                    rawCSVText = QPCRAnalysisEngine.defaultExampleCSV
                    reloadFromRawCSV()
                    appState.showToast("已载入 TP53 / MYC 标准 qPCR 示范数据集")
                },
                .action(title: "导出", icon: "square.and.arrow.up", tint: .teal, help: "导出 qPCR ΔΔCt 与显著性统计 CSV", action: exportResultsCSV),
                .action(title: "导出 RDML", icon: "doc.zipper", tint: .indigo, help: "导出符合 MIQE 标准的 RDML v1.3 归档 (.rdml)", action: exportRDMLFile)
            ]
        ) {
            StudioResponsiveSplitLayout(breakpoint: 860, spacing: 14, leftRatio: 0.40) {
                leftColumn
                rightColumn
            }
        }
        .onAppear {
            settings.sdLimit = appState.defaultQPCRSdThreshold
            settings.ntcCtThreshold = appState.defaultQPCRNtcCtThreshold
            settings.noRTDeltaCtThreshold = appState.defaultQPCRNoRTDeltaCt
            settings.meltTolerance = appState.defaultQPCRMeltTolerance
            if wells.isEmpty {
                reloadFromRawCSV()
            }
            let prefRef = appState.defaultQPCRReferenceGene.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefRef.isEmpty, ddctOut.targets.contains(where: { QPCRAnalysisEngine.normKey($0) == QPCRAnalysisEngine.normKey(prefRef) }) {
                settings.referenceTargets = [prefRef]
            }
            consumePendingFinderQPCRFileIfNeeded()
        }
        .onChange(of: appState.pendingFinderOpenedFileURL) { _, _ in
            consumePendingFinderQPCRFileIfNeeded()
        }
        .onChange(of: appState.defaultQPCRSdThreshold) { _, newVal in
            settings.sdLimit = newVal
        }
        .onChange(of: appState.defaultQPCRNtcCtThreshold) { _, newVal in
            settings.ntcCtThreshold = newVal
        }
        .onChange(of: appState.defaultQPCRNoRTDeltaCt) { _, newVal in
            settings.noRTDeltaCtThreshold = newVal
        }
        .onChange(of: appState.defaultQPCRMeltTolerance) { _, newVal in
            settings.meltTolerance = newVal
        }
    }
    
    private func consumePendingFinderQPCRFileIfNeeded() {
        guard let url = appState.pendingFinderOpenedFileURL,
              ["csv", "tsv", "rdml", "xml", "txt"].contains(url.pathExtension.lowercased()) else { return }
        appState.pendingFinderOpenedFileURL = nil
        loadQPCRFile(from: url)
    }
    
    // MARK: - 左栏：定量参数设置 + 反应孔 QC 数据表
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsCard
            wellsTableCard
        }
    }
    
    private var settingsCard: some View {
        let out = ddctOut
        return StudioCard(
            title: "内参基因、对照组与质控阈值",
            headerTrailing: {
                Toggle("自动剔除离群孔", isOn: $settings.excludeOutliers)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // 内参基因多选胶囊（支持几何平均）
                VStack(alignment: .leading, spacing: 5) {
                    Text("内参基因 (支持多选几何平均 Reference Ct):")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(out.targets, id: \.self) { target in
                            let isRef = settings.referenceTargets.contains {
                                QPCRAnalysisEngine.normKey($0) == QPCRAnalysisEngine.normKey(target)
                            }
                            StudioActionPillButton(
                                title: target,
                                icon: isRef ? "checkmark.circle.fill" : "circle",
                                tint: isRef ? .teal : nil,
                                isProminent: isRef
                            ) {
                                toggleReferenceTarget(target)
                            }
                        }
                    }
                }
                
                // 对照组选择
                if !out.groups.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("基准对照组 (Control Group):")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(out.groups, id: \.self) { grp in
                                let isCtrl = (QPCRAnalysisEngine.normKey(settings.controlGroup) == QPCRAnalysisEngine.normKey(grp))
                                StudioActionPillButton(
                                    title: grp,
                                    icon: isCtrl ? "flag.fill" : nil,
                                    tint: isCtrl ? .blue : nil,
                                    isProminent: isCtrl
                                ) {
                                    settings.controlGroup = grp
                                }
                            }
                        }
                    }
                }
                
                Divider()
                
                // QC 阈值与扩增效率校正（流式自动换行）
                StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                    HStack(spacing: 4) {
                        Text("高 Ct 警告:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("35", value: $settings.highCtThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                    
                    HStack(spacing: 4) {
                        Text("NTC 阈值:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("35", value: $settings.ntcCtThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                    
                    HStack(spacing: 4) {
                        Text("no-RT ΔCt:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("5", value: $settings.noRTDeltaCtThreshold, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .frame(width: 46)
                    }
                    
                    HStack(spacing: 4) {
                        Text("Tm 容差(℃):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("1.0", value: $settings.meltTolerance, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .frame(width: 48)
                    }
                    
                    HStack(spacing: 4) {
                        Text("复孔 SD 阈值:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        TextField("0.5", value: $settings.sdLimit, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                    
                    Toggle("启用扩增效率校正", isOn: $settings.efficiencyCorrection)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                    
                    if settings.efficiencyCorrection {
                        HStack(spacing: 4) {
                            Text("默认效率(%):")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            TextField("100", value: $settings.defaultEfficiencyPct, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .frame(width: 56)
                        }
                    }
                    
                    HStack(spacing: 4) {
                        Text("多组校正:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        StudioMenuPicker(
                            selection: $settings.multipleComparison,
                            options: QPCRMultipleComparisonMethod.allCases.map {
                                StudioMenuPickerOption(value: $0, title: $0.title)
                            },
                            compact: true
                        )
                    }
                    
                    if !poolManager.items.isEmpty {
                        StudioMenuPillButton(
                            title: linkedPlasmidIDs.isEmpty ? "关联质粒池" : "已关联 \(linkedPlasmidIDs.count)",
                            icon: "link",
                            tint: linkedPlasmidIDs.isEmpty ? nil : .accentColor,
                            compact: true,
                            help: "可选关联本地质粒池载体"
                        ) {
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
                        }
                    }
                }
            }
        }
    }
    
    private var wellsTableCard: some View {
        let qc = qcMap
        let flaggedCount = qc.values.filter { !$0.flags.isEmpty }.count
        let flagCounts: [(flag: QPCRQCFlag, count: Int)] = QPCRQCFlag.allCases.compactMap { flg in
            let cnt = wells.filter { qc[$0.id]?.flags.contains(flg) == true }.count
            return cnt > 0 ? (flg, cnt) : nil
        }
        let filteredIndices: [Int] = wells.indices.filter { idx in
            guard let flg = selectedQCFilter else { return true }
            return qc[wells[idx].id]?.flags.contains(flg) == true
        }
        
        return StudioCard(
            title: "反应孔原始数据与 QC 质控 (\(wells.count) 孔)",
            headerTrailing: {
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    StudioMetricBadge(label: "格式", value: detectedInstrumentFormat.shortTitle, color: .teal)
                    if flaggedCount > 0 {
                        StudioMetricBadge(label: "QC提醒", value: "\(flaggedCount)", color: .orange)
                    }
                    StudioSegmentedPillGroup(items: [
                        StudioPillGroupItem(title: showCSVEditor ? "收起粘贴框" : "粘贴/导入 CSV", icon: "doc.text") {
                            showCSVEditor.toggle()
                        },
                        StudioPillGroupItem(title: "导入文件", icon: "folder") {
                            importQPCRFile()
                        }
                    ])
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // 按 flag 分类计数可筛选面板 (P08)
                if !flagCounts.isEmpty {
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 5) {
                        StudioActionPillButton(
                            title: "全部 (\(wells.count))",
                            icon: selectedQCFilter == nil ? "line.3.horizontal.decrease.circle.fill" : nil,
                            tint: selectedQCFilter == nil ? .blue : nil,
                            isProminent: selectedQCFilter == nil
                        ) {
                            selectedQCFilter = nil
                        }
                        ForEach(flagCounts, id: \.flag) { item in
                            let isSel = (selectedQCFilter == item.flag)
                            let isSevere = (item.flag == .ntcAmplified || item.flag == .noRTAmplified || item.flag == .meltOutlier)
                            StudioActionPillButton(
                                title: "\(item.flag.rawValue) (\(item.count))",
                                icon: isSel ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                tint: isSevere ? .red : .orange,
                                isProminent: isSel
                            ) {
                                selectedQCFilter = isSel ? nil : item.flag
                            }
                        }
                    }
                }
                
                if showCSVEditor {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("粘贴 CSV / TSV 表格（包含 well, sample, group, target, ct, tm, task, quantity 列）：")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        SequenceEditorBox(text: $rawCSVText, placeholder: "well,sample,group,target,ct,tm...", minHeight: 96)
                        
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            StudioActionPillButton(title: "解析并更新数据表", icon: "checkmark.circle.fill", tint: .teal, isProminent: true) {
                                reloadFromRawCSV()
                                showCSVEditor = false
                            }
                        }
                    }
                    .studioInnerBox(paddingH: 10, paddingV: 10)
                }
                
                // 表头
                HStack(spacing: 6) {
                    Text("启用")
                        .frame(width: 28, alignment: .leading)
                    Text("孔位")
                        .frame(width: 32, alignment: .leading)
                    Text("样品 / 类型")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("靶标")
                        .frame(width: 54, alignment: .leading)
                    Text("Ct / Tm")
                        .frame(width: 68, alignment: .trailing)
                    Text("状态")
                        .frame(width: 82, alignment: .trailing)
                }
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredIndices, id: \.self) { idx in
                            let well = wells[idx]
                            let wellQC = qc[well.id]
                            HStack(spacing: 6) {
                                Toggle("", isOn: $wells[idx].include)
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .frame(width: 28, alignment: .leading)
                                
                                Text(well.well)
                                    .font(.system(size: 11.5, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .frame(width: 32, alignment: .leading)
                                
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(well.sample)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        if well.wellType != .sample {
                                            Text(well.wellType.badgeTitle)
                                                .font(.system(size: 9.5, weight: .bold))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.indigo.opacity(0.14)))
                                                .foregroundColor(.indigo)
                                        }
                                    }
                                    if !well.group.isEmpty {
                                        Text(well.group)
                                            .font(.system(size: 10.5))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                
                                Text(well.target)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.teal)
                                    .frame(width: 54, alignment: .leading)
                                    .lineLimit(1)
                                
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(well.ct.map { String(format: "%.2f", $0) } ?? "Undet.")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .monospacedDigit()
                                    if let tm = well.tm {
                                        Text(String(format: "Tm %.1f℃", tm))
                                            .font(.system(size: 9.5))
                                            .monospacedDigit()
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(width: 68, alignment: .trailing)
                                
                                Group {
                                    if let flags = wellQC?.flags, !flags.isEmpty {
                                        let primaryFlag = flags.first!
                                        let isRed = (primaryFlag == .ntcAmplified || primaryFlag == .noRTAmplified || primaryFlag == .meltOutlier)
                                        Text(primaryFlag.rawValue)
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundColor(isRed ? .red : .orange)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill((isRed ? Color.red : Color.orange).opacity(0.14)))
                                            .lineLimit(1)
                                    } else if well.wellType == .standard {
                                        Text("标准品")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.blue)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                                    } else if well.wellType == .ntc || well.wellType == .noRT {
                                        Text("阴性合格")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.green)
                                    } else {
                                        Text("正常")
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundColor(.green)
                                    }
                                }
                                .frame(width: 82, alignment: .trailing)
                            }
                            .studioInnerBox(paddingH: 8, paddingV: 5)
                            .opacity(well.include ? 1.0 : 0.58)
                        }
                    }
                }
                .frame(minHeight: 240, maxHeight: 380)
            }
        }
    }
    
    // MARK: - 右栏：原生 Swift Charts 图表 + 统计汇总与热图
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            if mode == .ddct {
                ddctChartCard
                ddctSummaryAndHeatmapCard
            } else {
                standardCurveChartCard
                standardCurveTableCard
            }
            miqeComplianceCard
        }
    }
    
    private func errorBarBounds(for item: QPCRGroupSummary) -> (low: Double, high: Double)? {
        switch errorBarMode {
        case .sd:
            guard let sd = item.sdFold, sd > 0 else { return nil }
            return (max(0, item.meanFold - sd), item.meanFold + sd)
        case .sem:
            guard let sem = item.semFold, sem > 0 else { return nil }
            return (max(0, item.meanFold - sem), item.meanFold + sem)
        case .ci95:
            if let lo = item.foldCI95Low, let hi = item.foldCI95High, hi > lo {
                return (max(0, lo), hi)
            }
            return nil
        }
    }
    
    private var ddctChartCard: some View {
        let out = ddctOut
        return StudioCard(
            title: "相对表达量柱状图 (2^-ΔΔCt Fold Change ± \(errorBarMode.title))",
            headerTrailing: {
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                    StudioMenuPicker(
                        selection: $errorBarMode,
                        options: QPCRErrorBarMode.allCases.map {
                            StudioMenuPickerOption(value: $0, title: $0.title)
                        },
                        prefix: "误差线",
                        compact: true
                    )
                    
                    StudioMetricBadge(label: "内参", value: out.references.joined(separator: "/"), color: .teal)
                    StudioMetricBadge(label: "对照组", value: out.controlLabel, color: .blue)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if !out.contaminatedTargets.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 13))
                        Text("靶标 [\(out.contaminatedTargets.joined(separator: "、"))] 检出 NTC / no-RT 阴性对照污染起峰，该靶标定量结果存在假阳性或 gDNA 污染风险（NTC/no-RT 孔已自动排除在 ΔΔCt 计算外），请复核体系！")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .studioInnerBox(tint: .red, paddingH: 10, paddingV: 8)
                }
                
                if out.groupResults.isEmpty {
                    Text("暂无可计算的 ΔΔCt 分组结果，请检查内参基因与目的基因设置")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 24)
                } else {
                    Chart {
                    RuleMark(y: .value("Baseline", 1.0))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                    
                    ForEach(out.groupResults) { item in
                        BarMark(
                            x: .value("分组", item.category),
                            y: .value("相对表达量 (Fold)", item.meanFold)
                        )
                        .foregroundStyle(by: .value("目的基因", item.target))
                        .position(by: .value("目的基因", item.target))
                        .cornerRadius(5)
                        .annotation(position: .top, spacing: 4) {
                            VStack(spacing: 1) {
                                if !item.isControl {
                                    if item.effectivePValueForSignificance != nil {
                                        Text(item.significanceLabel)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(item.significanceLabel.hasPrefix("*") ? .pink : .secondary)
                                    } else {
                                        Text("n<2，未检验")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text(String(format: "%.2f", item.meanFold))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let bounds = errorBarBounds(for: item) {
                            RuleMark(
                                x: .value("分组", item.category),
                                yStart: .value("Low", bounds.low),
                                yEnd: .value("High", bounds.high)
                            )
                            .position(by: .value("目的基因", item.target))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .foregroundStyle(Color.primary.opacity(0.75))
                        }
                    }
                    }
                    .chartYAxisLabel("Relative Fold Change")
                    .frame(height: 270)
                    .padding(.top, 8)
                }
            }
        }
    }
    
    private var ddctSummaryAndHeatmapCard: some View {
        let out = ddctOut
        return StudioCard(
            title: "统计显著性检验 (Welch's t-test) 与 ΔCt 热图",
            headerTrailing: {
                Toggle("显示 ΔCt 热图矩阵", isOn: $showHeatmap)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if showHeatmap && !out.heatmapCells.isEmpty {
                    Chart(out.heatmapCells) { cell in
                        RectangleMark(
                            x: .value("靶基因", cell.target),
                            y: .value("样品", cell.sample)
                        )
                        .foregroundStyle(by: .value("ΔΔCt", cell.ddCt ?? 0.0))
                        .annotation(position: .overlay) {
                            Text(cell.fold.map { String(format: "%.2f×", $0) } ?? "—")
                                .font(.system(size: 10.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(.white)
                                .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
                        }
                    }
                    .frame(height: max(120, CGFloat(out.samples.count * 38)))
                }
                
                // 表头说明：明确区分生物学重复数与技术复孔数及 Holm 校正
                HStack {
                    Text("分组 / 靶基因")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("n（生物学重复）/ 复孔数 · 显著性星号基于 \(settings.multipleComparison == .holm ? "p (Holm)" : "p (raw)")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                // 响应式统计汇总列表（窄窗口下自动切换为流式卡片行，绝不横向溢出）
                VStack(spacing: 6) {
                    ForEach(out.groupResults) { row in
                        let pRawText: String = {
                            if row.isControl { return "对照基准" }
                            if let p = row.pValue { return String(format: "%.4f", p) }
                            return "n<2，未检验"
                        }()
                        let pHolmText: String = {
                            if row.isControl { return "Ref" }
                            if let pAdj = row.pAdjusted { return String(format: "%.4f (%@)", pAdj, row.significanceLabel) }
                            return "n<2，未检验"
                        }()
                        let ci95Text: String = {
                            if row.isControl { return "1.00 (Ref)" }
                            if let lo = row.foldCI95Low, let hi = row.foldCI95High {
                                return String(format: "[%.2f, %.2f]", lo, hi)
                            }
                            return "—"
                        }()
                        let pBadgeColor: Color = {
                            guard let p = row.effectivePValueForSignificance else { return .secondary }
                            return p < 0.05 ? .pink : .secondary
                        }()
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text(row.category)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .frame(minWidth: 82, maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                Text(row.target)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.teal)
                                    .frame(width: 62, alignment: .leading)
                                    .lineLimit(1)
                                StudioMetricBadge(label: "n（生物学重复）/ 复孔数", value: "\(row.nBiological)/\(row.nTechnicalWells)", color: .secondary)
                                StudioMetricBadge(label: "Fold", value: String(format: "%.2f±%.2f", row.meanFold, row.semFold ?? 0), color: .blue)
                                StudioMetricBadge(label: "Fold 95% CI", value: ci95Text, color: .indigo)
                                StudioMetricBadge(label: "p (raw)", value: pRawText, color: .secondary)
                                StudioMetricBadge(label: "p (Holm)", value: pHolmText, color: pBadgeColor)
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(row.category)
                                        .font(.system(size: 12.5, weight: .semibold))
                                    Text(row.target)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.teal)
                                    Spacer()
                                }
                                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                                    StudioMetricBadge(label: "n（生物学重复）/ 复孔数", value: "\(row.nBiological)/\(row.nTechnicalWells)", color: .secondary)
                                    StudioMetricBadge(label: "ΔCt", value: String(format: "%.2f±%.2f", row.meanDCt, row.sdDCt ?? 0), color: .indigo)
                                    StudioMetricBadge(label: "Fold", value: String(format: "%.2f±%.2f", row.meanFold, row.semFold ?? 0), color: .blue)
                                    StudioMetricBadge(label: "Fold 95% CI", value: ci95Text, color: .indigo)
                                    StudioMetricBadge(label: "p (raw)", value: pRawText, color: .secondary)
                                    StudioMetricBadge(label: "p (Holm)", value: pHolmText, color: pBadgeColor)
                                }
                            }
                        }
                        .studioInnerBox(paddingH: 10, paddingV: 6)
                    }
                }
            }
        }
    }
    
    private var standardCurveChartCard: some View {
        let out = stdOut
        return StudioCard(title: "标准曲线线性回归 (Ct vs. log10 Quantity)") {
            VStack(alignment: .leading, spacing: 12) {
                if out.fits.isEmpty {
                    Text("当前数据中未检测到含 Quantity 浓度的标准品孔（如示范数据底部的 STD-1..STD-5）")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 20)
                } else {
                    ForEach(out.fits) { fit in
                        VStack(alignment: .leading, spacing: 8) {
                            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                StudioMetricBadge(label: "靶标", value: fit.target, color: .teal)
                                if let s = fit.slope {
                                    StudioMetricBadge(label: "Slope", value: String(format: "%.3f", s), color: .blue)
                                }
                                if let b = fit.intercept {
                                    StudioMetricBadge(label: "Intercept", value: String(format: "%.2f", b), color: .indigo)
                                }
                                if let r2 = fit.r2 {
                                    StudioMetricBadge(label: "R²", value: String(format: "%.4f", r2), color: r2 >= 0.98 ? .green : .orange)
                                }
                                if let eff = fit.efficiencyPct {
                                    StudioMetricBadge(label: "扩增效率 E", value: String(format: "%.1f%%", eff), color: (eff >= 90 && eff <= 110) ? .green : .orange)
                                }
                            }
                            
                            Chart {
                                ForEach(Array(fit.points.enumerated()), id: \.offset) { _, pt in
                                    PointMark(
                                        x: .value("log10(Quantity)", pt.x),
                                        y: .value("Ct", pt.y)
                                    )
                                    .foregroundStyle(Color.teal)
                                    .symbolSize(55)
                                }
                                
                                if let s = fit.slope, let b = fit.intercept,
                                   let xMin = fit.xMin, let xMax = fit.xMax {
                                    LineMark(
                                        x: .value("log10(Quantity)", xMin),
                                        y: .value("Ct", s * xMin + b)
                                    )
                                    .foregroundStyle(Color.blue)
                                    LineMark(
                                        x: .value("log10(Quantity)", xMax),
                                        y: .value("Ct", s * xMax + b)
                                    )
                                    .foregroundStyle(Color.blue)
                                }
                            }
                            .chartXAxisLabel("log10(Quantity)")
                            .chartYAxisLabel("Ct")
                            .frame(height: 220)
                        }
                    }
                }
            }
        }
    }
    
    private var standardCurveTableCard: some View {
        let out = stdOut
        return StudioCard(title: "未知样品标准曲线绝对定量插值结果") {
            if out.samples.isEmpty {
                Text("暂无可插值的未知样品数据")
                    .font(.system(size: 12.5))
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(out.samples) { s in
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            Text(s.sample)
                                .font(.system(size: 12.5, weight: .semibold))
                            StudioMetricBadge(label: "靶标", value: s.target, color: .teal)
                            StudioMetricBadge(label: "平均 Ct", value: String(format: "%.2f", s.meanCt), color: .secondary)
                            StudioMetricBadge(label: "log10(Qty)", value: String(format: "%.3f", s.log10Quantity), color: .indigo)
                            StudioMetricBadge(label: "绝对浓度/拷贝", value: String(format: "%.2e", s.quantity), color: .blue)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .studioInnerBox(paddingH: 10, paddingV: 6)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var miqeComplianceCard: some View {
        let rep = miqeReport
        StudioCard(title: "MIQE 指南合规性自检清单 (\(rep.detectedFormat))") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                StudioMetricBadge(label: "合规", value: "\(rep.passCount)/\(rep.items.count)", color: rep.failCount == 0 ? .green : .orange)
                if rep.failCount > 0 {
                    StudioMetricBadge(label: "告警", value: "\(rep.failCount)", color: .red)
                }
                StudioActionPillButton(title: "复制清单", icon: "doc.on.doc", tint: .blue, compact: true) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rep.exportMarkdownChecklist(), forType: .string)
                    appState.showToast("已复制 MIQE 自检 Markdown 清单")
                }
                StudioCompactPillButton(title: isMIQEExpanded ? "收起" : "展开", icon: isMIQEExpanded ? "chevron.up" : "chevron.down") {
                    isMIQEExpanded.toggle()
                }
            }
        } content: {
            if isMIQEExpanded {
                VStack(spacing: 6) {
                    ForEach(rep.items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.status == .pass ? "checkmark.circle.fill" : (item.status == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                                .foregroundStyle(item.status == .pass ? .green : (item.status == .warning ? .orange : .red))
                                .font(.system(size: 12.5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.itemNumber). \(item.title)")
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text(item.evidence)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .studioInnerBox(tint: item.status == .pass ? .green : (item.status == .warning ? .orange : .red), paddingH: 9, paddingV: 6)
                    }
                }
            }
        }
    }

    // MARK: - 辅助逻辑
    
    private func reloadFromRawCSV() {
        let res = QPCRInstrumentAndRDMLEngine.parseRawExport(rawCSVText)
        if !res.wells.isEmpty {
            detectedInstrumentFormat = res.format
            importMetaSummary = res.metadataSummary
            wells = res.wells
            syncDefaultRefAndControlIfNeeded()
        }
    }
    
    private func syncDefaultRefAndControlIfNeeded() {
        let out = QPCRAnalysisEngine.computeDdct(wells: wells, settings: settings, qc: qcMap)
        if settings.referenceTargets.isEmpty, let first = out.targets.first {
            settings.referenceTargets = [first]
        }
        if settings.controlGroup.isEmpty, let firstGrp = out.groups.first {
            settings.controlGroup = firstGrp
        }
    }
    
    private func toggleReferenceTarget(_ target: String) {
        let tk = QPCRAnalysisEngine.normKey(target)
        if settings.referenceTargets.contains(where: { QPCRAnalysisEngine.normKey($0) == tk }) {
            if settings.referenceTargets.count > 1 {
                settings.referenceTargets.removeAll { QPCRAnalysisEngine.normKey($0) == tk }
            }
        } else {
            settings.referenceTargets.append(target)
        }
    }
    
    private func importQPCRFile() {
        FinderFileDropHelper.presentOpenPanel { url in
            loadQPCRFile(from: url)
        }
    }

    private func loadQPCRFile(from url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "rdml" || ext == "xml" {
            if let data = try? Data(contentsOf: url),
               let res = try? QPCRInstrumentAndRDMLEngine.parseRDMLData(data, fileName: url.lastPathComponent),
               !res.wells.isEmpty {
                sourceFileURL = url
                detectedInstrumentFormat = res.format
                importMetaSummary = res.metadataSummary
                wells = res.wells
                syncDefaultRefAndControlIfNeeded()
                appState.showToast("已解析 RDML 实验归档：\(url.lastPathComponent) (\(res.wells.count) 条反应孔)")
                return
            }
        }
        if let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .ascii)) {
            sourceFileURL = url
            rawCSVText = text
            let res = QPCRInstrumentAndRDMLEngine.parseRawExport(text)
            if !res.wells.isEmpty {
                detectedInstrumentFormat = res.format
                importMetaSummary = res.metadataSummary
                wells = res.wells
                syncDefaultRefAndControlIfNeeded()
                let skippedTip = res.skippedHeaderLines > 0 ? " · 自动跳过 \(res.skippedHeaderLines) 行仪器头" : ""
                appState.showToast("已识别 \(res.format.shortTitle) 格式\(skippedTip)：\(url.lastPathComponent)")
            }
        }
    }

    private func exportRDMLFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Labworker_qPCR_Experiment.rdml"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try QPCRInstrumentAndRDMLEngine.writeRDMLArchive(
                    wells: wells,
                    settings: settings,
                    experimentName: url.deletingPathExtension().lastPathComponent,
                    to: url
                )
                appState.showToast("已导出 RDML 归档：\(url.lastPathComponent)")
            } catch {
                appState.showToast("导出 RDML 失败：\(error.localizedDescription)")
            }
        }
    }
    
    private func exportResultsCSV() {
        let out = ddctOut
        let rawText = rawCSVText
        let srcURL = sourceFileURL
        let curWells = wells
        let curSettings = settings
        let curQC = qcMap
        let linked = Array(linkedPlasmidIDs).sorted()
        let csv = QPCRAnalysisEngine.exportDdctResultsCSV(out)
        FinderFileDropHelper.saveTextToFile(
            content: csv,
            defaultFileName: "qPCR_DeltaDeltaCt_定量统计结果.csv",
            contentType: .commaSeparatedText,
            toastPrefix: "已导出 qPCR 统计 CSV 与 .run.json 溯源记录"
        ) { savedURL in
            let run = QPCRAnalysisEngine.buildQPCRAnalysisRun(
                rawCSVText: rawText,
                sourceFileURL: srcURL,
                wells: curWells,
                settings: curSettings,
                qc: curQC,
                analysis: out,
                outputs: [savedURL.lastPathComponent],
                exportDirectoryURL: savedURL.deletingLastPathComponent(),
                linkedPlasmidIDs: linked
            )
            _ = try? run.writeSidecarJSON(alongsideOutputURL: savedURL)
        }
    }
}
