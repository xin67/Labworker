import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// 微孔板画布交互工具模式
private enum PlatePaintToolMode: String, CaseIterable, Identifiable {
    case inspect = "inspect"
    case paintSample = "paintSample"
    case paintControl = "paintControl"
    case paintBlank = "paintBlank"
    case erase = "erase"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .inspect:      return "点选查看"
        case .paintSample:  return "涂刷样品"
        case .paintControl: return "涂刷对照"
        case .paintBlank:   return "涂刷空白"
        case .erase:        return "橡皮擦"
        }
    }
}

/// 微孔板布局设计器主视图 (纯声明式响应式 UI：任意拉动窗口自动折行与自适应缩放孔位画布)
public struct PlateDesignerView: View {
    @ObservedObject private var store = PlateLayoutStore.shared
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var plasmidPool = PlasmidPoolManager.shared
    
    @State private var selectedWellID: String? = "A1"
    @State private var activeSampleIDForPaint: String = ""
    @State private var paintTool: PlatePaintToolMode = .inspect
    @State private var newSampleName: String = ""
    @State private var newSampleGroup: String = "Group A"
    @State private var showPasteCSVSheet: Bool = false
    @State private var canvasAvailableWidth: CGFloat = 640
    @State private var pastedCSVText: String = "sample,group,replicates\nWT-Ctrl,ControlGroup,3\nTP53-OE,Overexpression,3\nTP53-KO,Knockout,3"
    
    public init() {}
    
    private var formatOptions: [StudioSegmentedOption<PlateFormat>] {
        PlateFormat.allCases.map { fmt in
            StudioSegmentedOption(value: fmt, title: "\(fmt.rawValue)孔", tint: .blue)
        }
    }
    
    private var paintOptions: [StudioSegmentedOption<PlatePaintToolMode>] {
        PlatePaintToolMode.allCases.map { mode in
            let tint: Color = {
                switch mode {
                case .inspect: return .blue
                case .paintSample: return .teal
                case .paintControl: return .purple
                case .paintBlank: return .gray
                case .erase: return .pink
                }
            }()
            return StudioSegmentedOption(value: mode, title: mode.title, tint: tint)
        }
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "微孔板",
            toolbar: [
                .picker(
                    id: "plate_format",
                    label: "孔板规格",
                    options: PlateFormat.allCases.map { fmt in
                        StudioToolbarPickerOption(
                            id: "\(fmt.rawValue)",
                            title: "\(fmt.rawValue)孔",
                            tint: .blue,
                            isSelected: store.format == fmt
                        ) {
                            if store.format != fmt {
                                store.format = fmt
                            }
                        }
                    }
                ),
                .action(title: "重排", icon: "dice.fill", tint: .blue, help: "按新随机种子生成孔位排布") {
                    store.randomizeWithNewSeed()
                    appState.showToast("已按新随机种子 #\(store.rules.seed) 生成孔板排布")
                },
                .action(title: "导出", icon: "square.and.arrow.up", help: "导出微孔板映射 CSV", action: exportPlateCSVToFile),
                .action(title: "qPCR", icon: "chart.bar.xaxis", tint: .teal, help: "将当前孔位映射同步至 qPCR 定量模块") {
                    appState.selectedNav = .qpcrAnalysis
                    appState.showToast("已将当前 \(store.format.title) 孔位映射同步至 qPCR 定量模块")
                }
            ]
        ) {
            StudioResponsiveSplitLayout(breakpoint: 860, spacing: 14, leftRatio: 0.37) {
                leftColumn
                rightColumn
            }
        }
        .onChange(of: store.format) { _, _ in
            store.regenerateLayout()
        }
        .onAppear {
            if let defaultFmt = PlateFormat(rawValue: appState.defaultPlateFormatRaw), store.format != defaultFmt {
                store.format = defaultFmt
            }
            if store.rules.avoidEdge != appState.defaultPlateAvoidOuterEdge {
                store.rules.avoidEdge = appState.defaultPlateAvoidOuterEdge
                store.regenerateLayout()
            }
            if activeSampleIDForPaint.isEmpty, let first = store.samples.first {
                activeSampleIDForPaint = first.id
            }
        }
        .onChange(of: appState.defaultPlateFormatRaw) { _, newRaw in
            if let fmt = PlateFormat(rawValue: newRaw) {
                store.format = fmt
                store.regenerateLayout()
            }
        }
        .onChange(of: appState.defaultPlateAvoidOuterEdge) { _, newAvoid in
            store.rules.avoidEdge = newAvoid
            store.regenerateLayout()
        }
    }
    
    // MARK: - 左栏：排布规则 + 样品清单
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            rulesCard
            samplesCard
        }
    }
    
    private var rulesCard: some View {
        StudioCard(
            title: "排布规则与防边缘效应",
            headerTrailing: {
                StudioActionPillButton(title: "应用规则排布", icon: "sparkles", tint: .blue, isProminent: true) {
                    store.regenerateLayout()
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // 使用 StudioFlowLayout 保证窄窗口下复孔/对照/空白步进器自动换行不挤压
                StudioFlowLayout(horizontalSpacing: 14, verticalSpacing: 8) {
                    Stepper(value: $store.rules.replicates, in: 1...12) {
                        HStack(spacing: 4) {
                            Text("默认复孔:")
                                .font(.system(size: 12.5))
                                .foregroundColor(.secondary)
                            Text("\(store.rules.replicates)")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                    }
                    .fixedSize()
                    .onChange(of: store.rules.replicates) { _, _ in store.regenerateLayout() }
                    
                    Stepper(value: $store.rules.controls, in: 0...48) {
                        HStack(spacing: 4) {
                            Text("对照孔:")
                                .font(.system(size: 12.5))
                                .foregroundColor(.secondary)
                            Text("\(store.rules.controls)")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                    }
                    .fixedSize()
                    .onChange(of: store.rules.controls) { _, _ in store.regenerateLayout() }
                    
                    Stepper(value: $store.rules.blanks, in: 0...48) {
                        HStack(spacing: 4) {
                            Text("空白孔:")
                                .font(.system(size: 12.5))
                                .foregroundColor(.secondary)
                            Text("\(store.rules.blanks)")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                    }
                    .fixedSize()
                    .onChange(of: store.rules.blanks) { _, _ in store.regenerateLayout() }
                }
                
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    Text("复孔聚拢方式:")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                    
                    StudioSegmentedPicker(
                        selection: $store.rules.groupLayout,
                        options: PlateGroupLayoutStrategy.allCases.map {
                            StudioSegmentedOption(value: $0, title: $0.title, tint: .teal)
                        }
                    )
                    .onChange(of: store.rules.groupLayout) { _, _ in store.regenerateLayout() }
                }
                
                StudioFlowLayout(horizontalSpacing: 14, verticalSpacing: 8) {
                    Toggle("同样品复孔保持相邻", isOn: $store.rules.keepTogether)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                        .onChange(of: store.rules.keepTogether) { _, _ in store.regenerateLayout() }
                    
                    Toggle("样品优先避开边缘孔", isOn: $store.rules.avoidEdge)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                        .onChange(of: store.rules.avoidEdge) { _, _ in store.regenerateLayout() }
                    
                    Toggle("外圈固定标为预留孔 (PBS/水封)", isOn: $store.rules.reserveEdge)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                        .onChange(of: store.rules.reserveEdge) { _, _ in store.regenerateLayout() }
                    
                    Toggle("随机打乱样品顺序", isOn: $store.rules.randomize)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                        .onChange(of: store.rules.randomize) { _, _ in store.regenerateLayout() }
                }
                
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    Text("确定性种子:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    TextField("Seed", value: $store.rules.seed, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 110)
                        .onSubmit { store.regenerateLayout() }
                    
                    StudioActionPillButton(title: "换一组种子", icon: "arrow.triangle.2.circlepath") {
                        store.randomizeWithNewSeed()
                    }
                }
            }
        }
    }
    
    private var samplesCard: some View {
        StudioCard(
            title: "实验样品清单 (\(store.samples.count))",
            headerTrailing: {
                StudioSegmentedPillGroup(items: [
                    StudioPillGroupItem(title: "批量粘贴 CSV", icon: "doc.on.clipboard") {
                        showPasteCSVSheet.toggle()
                    },
                    StudioPillGroupItem(
                        title: "从质粒池带入",
                        icon: "tray.and.arrow.down",
                        isDisabled: plasmidPool.items.isEmpty
                    ) {
                        importSamplesFromPlasmidPool()
                    },
                    StudioPillGroupItem(title: "清空", icon: "trash", tint: .red, isDisabled: store.samples.isEmpty) {
                        store.samples.removeAll()
                        store.regenerateLayout()
                    }
                ])
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if showPasteCSVSheet {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("粘贴 CSV / TSV 样品列表（支持 sample, group, replicates 列）：")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        SequenceEditorBox(text: $pastedCSVText, placeholder: "sample,group,replicates...", minHeight: 74)
                        
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            StudioActionPillButton(title: "解析并替换样品", icon: "checkmark.circle.fill", tint: .blue, isProminent: true) {
                                let parsed = PlateLayoutEngine.parseSampleTable(pastedCSVText)
                                if !parsed.isEmpty {
                                    store.samples = parsed
                                    activeSampleIDForPaint = parsed.first?.id ?? ""
                                    store.regenerateLayout()
                                    showPasteCSVSheet = false
                                    appState.showToast("已导入 \(parsed.count) 个实验样品")
                                }
                            }
                            StudioActionPillButton(title: "追加到现有列表", icon: "plus.circle") {
                                let parsed = PlateLayoutEngine.parseSampleTable(pastedCSVText)
                                if !parsed.isEmpty {
                                    store.samples.append(contentsOf: parsed)
                                    store.regenerateLayout()
                                    showPasteCSVSheet = false
                                    appState.showToast("已追加 \(parsed.count) 个实验样品")
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
                
                // 声明式自适应新增样品栏：宽窗口同行排列，窄窗口自动折行
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        TextField("新增样品名称 (如 TP53-Mut)", text: $newSampleName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                            .frame(minWidth: 120)
                        
                        TextField("分组 (Group)", text: $newSampleGroup)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                            .frame(width: 105)
                        
                        StudioActionPillButton(
                            title: "添加",
                            icon: "plus",
                            tint: .blue,
                            isProminent: true,
                            isDisabled: newSampleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ) {
                            addSingleSample()
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("新增样品名称 (如 TP53-Mut)", text: $newSampleName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                        
                        HStack(spacing: 6) {
                            TextField("分组 (Group)", text: $newSampleGroup)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5))
                            
                            StudioActionPillButton(
                                title: "添加",
                                icon: "plus",
                                tint: .blue,
                                isProminent: true,
                                isDisabled: newSampleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ) {
                                addSingleSample()
                            }
                        }
                    }
                }
                
                if store.samples.isEmpty {
                    Text("当前无样品，请添加样品或点击「批量粘贴 CSV」")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 6) {
                            ForEach(Array(store.samples.enumerated()), id: \.element.id) { index, sample in
                                sampleRowItem(index: index, sample: sample)
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
            }
        }
    }
    
    private func sampleRowItem(index: Int, sample: PlateSampleItem) -> some View {
        let resolvedHex = sample.colorHex.isEmpty
            ? PlateColorPalette.hexForGroup(sample.group, indexFallback: index)
            : sample.colorHex
        let badgeColor = PlateColorPalette.color(fromHex: resolvedHex)
        let isSelectedBrush = (activeSampleIDForPaint == sample.id && paintTool == .paintSample)
        
        return HStack(spacing: 8) {
            Circle()
                .fill(badgeColor)
                .frame(width: 10, height: 10)
            
            Text(sample.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            
            Text(sample.group)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(badgeColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(badgeColor.opacity(0.14)))
                .lineLimit(1)
            
            Spacer(minLength: 4)
            
            Text("×\(PlateLayoutEngine.requiredReplicates(for: sample, rules: store.rules))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            
            Button(action: {
                activeSampleIDForPaint = sample.id
                paintTool = .paintSample
            }) {
                Image(systemName: isSelectedBrush ? "paintbrush.pointed.fill" : "paintbrush")
                    .font(.system(size: 12))
                    .foregroundColor(isSelectedBrush ? .white : .secondary)
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelectedBrush ? Color.teal : Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("选为画笔涂刷到指定孔位")
            
            Button(action: {
                store.samples.removeAll { $0.id == sample.id }
                store.regenerateLayout()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelectedBrush ? Color.teal : Color.clear, lineWidth: 1.2)
                )
        )
    }
    
    // MARK: - 右栏：微孔板交互网格 + 校验与孔位详情
    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            plateCanvasCard
            validationAndInspectorCard
        }
    }
    
    private var plateCanvasCard: some View {
        let assignedValues = Array(store.assignments.values)
        let sampleWells = assignedValues.filter { $0.type == .sample }.count
        let ctrlWells = assignedValues.filter { $0.type == .control }.count
        let blankWells = assignedValues.filter { $0.type == .blank }.count
        let emptyWells = max(0, store.format.totalWells - assignedValues.count)
        
        return StudioCard(
            title: "\(store.format.title)孔位交互画布",
            headerTrailing: {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    Toggle("显示标签", isOn: $store.showWellLabels)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    
                    StudioSegmentedPicker(selection: $paintTool, options: paintOptions)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    StudioMetricBadge(label: "总孔数", value: "\(store.format.totalWells)", color: .blue)
                    StudioMetricBadge(label: "样品孔", value: "\(sampleWells)", color: .teal)
                    StudioMetricBadge(label: "对照孔", value: "\(ctrlWells)", color: .purple)
                    StudioMetricBadge(label: "空白孔", value: "\(blankWells)", color: .secondary)
                    StudioMetricBadge(label: "空余孔", value: "\(emptyWells)", color: .orange)
                }
                
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    plateGridContent(availableWidth: canvasAvailableWidth)
                        .padding(6)
                }
                .frame(minHeight: 280, maxHeight: 480)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                if geo.size.width > 120 {
                                    canvasAvailableWidth = geo.size.width
                                }
                            }
                            .onChange(of: geo.size.width) { _, newW in
                                if newW > 120 && abs(newW - canvasAvailableWidth) > 2 {
                                    canvasAvailableWidth = newW
                                }
                            }
                    }
                )
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )
            }
        }
    }
    
    private func plateGridContent(availableWidth: CGFloat) -> some View {
        let rows = store.format.rows
        let cols = store.format.cols
        let minCellW: CGFloat = store.format == .well384 ? 34 : (store.format == .well96 ? 44 : 62)
        let dynamicCellW = floor((availableWidth - 44 - CGFloat(cols) * 4) / CGFloat(max(1, cols)))
        let cellW: CGFloat = max(minCellW, min(120, dynamicCellW))
        let cellH: CGFloat = max(store.format == .well384 ? 28 : 38, round(cellW * 0.74))
        
        return VStack(alignment: .leading, spacing: 4) {
            // 顶部列号表头 1..cols
            HStack(spacing: 4) {
                Text("")
                    .frame(width: 24)
                ForEach(0..<cols, id: \.self) { c in
                    Text("\(c + 1)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: cellW, alignment: .center)
                }
            }
            
            // 每一行 A..rows
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 4) {
                    Text(PlateFormat.rowLabel(for: r))
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 24, alignment: .center)
                    
                    ForEach(0..<cols, id: \.self) { c in
                        wellCellButton(row: r, col: c, width: cellW, height: cellH)
                    }
                }
            }
        }
    }
    
    private func wellCellButton(row: Int, col: Int, width: CGFloat, height: CGFloat) -> some View {
        let wellID = PlateFormat.wellID(row: row, col: col)
        let assignment = store.assignments[wellID]
        let isSelected = (selectedWellID == wellID)
        let isEdge = store.format.isEdgeWell(row: row, col: col)
        
        let fillColor: Color = {
            guard let a = assignment else {
                return Color.primary.opacity(isEdge ? 0.06 : 0.03)
            }
            switch a.type {
            case .sample:
                return PlateColorPalette.color(fromHex: a.colorHex, fallback: .blue).opacity(0.86)
            case .control:
                return Color.purple.opacity(0.80)
            case .blank:
                return Color.gray.opacity(0.55)
            case .reserved:
                return Color.secondary.opacity(0.22)
            }
        }()
        
        return Button(action: {
            handleWellTap(wellID: wellID, row: row, col: col)
        }) {
            VStack(spacing: 1) {
                HStack(spacing: 2) {
                    Text(wellID)
                        .font(.system(size: store.format == .well384 ? 8.5 : 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(assignment != nil ? .white.opacity(0.92) : .secondary)
                    
                    Spacer(minLength: 0)
                    
                    if let a = assignment, a.replicate > 0, store.format != .well384 {
                        Text("#\(a.replicate)")
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
                
                if store.showWellLabels, let a = assignment {
                    Text(a.type == .reserved ? "预留" : a.sampleName)
                        .font(.system(size: store.format == .well384 ? 8 : 10, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                isSelected ? Color.accentColor : Color.primary.opacity(isEdge ? 0.18 : 0.10),
                                lineWidth: isSelected ? 2.0 : 0.8
                            )
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var validationAndInspectorCard: some View {
        StudioCard(
            title: "规则核验与孔位检查器",
            headerTrailing: {
                StudioActionPillButton(title: "复制整板 TSV", icon: "doc.on.doc") {
                    let tsv = PlateLayoutEngine.exportPlateTSV(format: store.format, assignments: store.assignments)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tsv, forType: .string)
                    appState.showToast("已复制整板 TSV 孔位映射至剪贴板")
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let selWell = selectedWellID {
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        StudioMetricBadge(label: "当前选中孔", value: selWell, color: .blue)
                        if let a = store.assignments[selWell] {
                            StudioMetricBadge(label: "类型", value: a.type.displayName, color: .teal)
                            if !a.sampleName.isEmpty {
                                StudioMetricBadge(label: "样品", value: a.sampleName, color: .indigo)
                            }
                            if !a.group.isEmpty {
                                StudioMetricBadge(label: "分组", value: a.group, color: .purple)
                            }
                            if a.replicate > 0 {
                                StudioMetricBadge(label: "复孔序号", value: "#\(a.replicate)", color: .orange)
                            }
                        } else {
                            StudioMetricBadge(label: "状态", value: "空孔（未分配样品）", color: .secondary)
                        }
                    }
                }
                
                if store.issues.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("所有样品复孔、相邻性与边缘避让规则均通过校验！")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(store.issues) { issue in
                            HStack(alignment: .top, spacing: 6) {
                                Image(
                                    systemName: issue.severity == .error
                                        ? "exclamationmark.octagon.fill"
                                        : (issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                )
                                .foregroundColor(
                                    issue.severity == .error ? .red : (issue.severity == .warning ? .orange : .blue)
                                )
                                Text(issue.message)
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 交互动作
    
    private func addSingleSample() {
        let name = newSampleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let group = newSampleGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Group A" : newSampleGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = PlateColorPalette.hexForGroup(group, indexFallback: store.samples.count)
        let item = PlateSampleItem(name: name, group: group, colorHex: hex)
        store.samples.append(item)
        activeSampleIDForPaint = item.id
        newSampleName = ""
        store.regenerateLayout()
    }
    
    private func importSamplesFromPlasmidPool() {
        let imported = plasmidPool.items.prefix(16).enumerated().map { idx, plasmid in
            let res = plasmid.resolvedResistances.first ?? (plasmid.categoryTag.isEmpty ? "Plasmid" : plasmid.categoryTag)
            return PlateSampleItem(
                name: plasmid.name,
                group: res,
                colorHex: PlateColorPalette.hexForGroup(res, indexFallback: idx)
            )
        }
        guard !imported.isEmpty else { return }
        store.samples = imported
        activeSampleIDForPaint = imported.first?.id ?? ""
        store.regenerateLayout()
        appState.showToast("已从本地质粒池带入 \(imported.count) 个载体样品")
    }
    
    private func handleWellTap(wellID: String, row: Int, col: Int) {
        selectedWellID = wellID
        switch paintTool {
        case .inspect:
            break
        case .paintSample:
            let sample = store.samples.first(where: { $0.id == activeSampleIDForPaint }) ?? store.samples.first
            guard let targetSample = sample else { return }
            let existingReps = store.assignments.values.filter { $0.type == .sample && $0.sampleId == targetSample.id }.count
            let hex = targetSample.colorHex.isEmpty ? PlateColorPalette.hexForGroup(targetSample.group) : targetSample.colorHex
            store.assignments[wellID] = PlateWellAssignment(
                well: wellID,
                row: row,
                col: col,
                type: .sample,
                sampleId: targetSample.id,
                sampleName: targetSample.name,
                group: targetSample.group,
                replicate: existingReps + 1,
                colorHex: hex,
                manual: true
            )
            store.revalidateCurrentAssignments()
        case .paintControl:
            let ctrlCount = store.assignments.values.filter { $0.type == .control }.count + 1
            store.assignments[wellID] = PlateWellAssignment(
                well: wellID,
                row: row,
                col: col,
                type: .control,
                sampleId: "",
                sampleName: "CTRL-\(ctrlCount)",
                group: PlateLayoutEngine.controlGroupName,
                replicate: ctrlCount,
                colorHex: PlateColorPalette.controlHex,
                manual: true
            )
            store.revalidateCurrentAssignments()
        case .paintBlank:
            let blankCount = store.assignments.values.filter { $0.type == .blank }.count + 1
            store.assignments[wellID] = PlateWellAssignment(
                well: wellID,
                row: row,
                col: col,
                type: .blank,
                sampleId: "",
                sampleName: "BLANK-\(blankCount)",
                group: PlateLayoutEngine.blankGroupName,
                replicate: blankCount,
                colorHex: PlateColorPalette.blankHex,
                manual: true
            )
            store.revalidateCurrentAssignments()
        case .erase:
            store.assignments.removeValue(forKey: wellID)
            store.revalidateCurrentAssignments()
        }
    }
    
    private func exportPlateCSVToFile() {
        let csv = PlateLayoutEngine.exportPlateCSV(format: store.format, assignments: store.assignments)
        FinderFileDropHelper.saveTextToFile(
            content: csv,
            defaultFileName: "\(store.title)_\(store.format.rawValue)孔板映射.csv",
            contentType: .commaSeparatedText,
            toastPrefix: "已导出微孔板 CSV"
        )
    }
}
