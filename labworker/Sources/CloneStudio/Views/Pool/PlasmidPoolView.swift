import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// 质粒池 (`PlasmidPool`) 与三维智能筛选工作台（100% 声明式流式自适应布局 `StudioFlowLayout`，窗口任意拉伸不溢出、不截断）
public struct PlasmidPoolView: View {
    @ObservedObject private var pool = PlasmidPoolManager.shared
    @ObservedObject private var appState = AppState.shared
    @State private var isDropTargeted: Bool = false
    @State private var inspectorFeatureFilter: PlasmidFeatureFilter = .targetGenes
    
    public init() {}
    
    public var body: some View {
        StudioPageLayout(title: "质粒池") {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                StudioMetricBadge(
                    label: "共",
                    value: "\(pool.items.count) 个",
                    color: .blue
                )
                
                StudioActionPillButton(
                    title: "导入质粒",
                    icon: "folder.badge.plus",
                    tint: .blue,
                    isProminent: true,
                    action: presentImportFilesOrFolderPanel
                )
                
                StudioActionPillButton(
                    title: "清空",
                    icon: "trash",
                    tint: .red,
                    isDisabled: pool.items.isEmpty,
                    action: pool.clearAll
                )
            }
        } content: {
            AdaptiveTwoColumnWorkspace(breakpoint: 780, hasRight: pool.selectedItem != nil) {
                plasmidListCard
            } right: {
                if let selected = pool.selectedItem {
                    plasmidInspectorCard(selected)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            FinderFileDropHelper.extractAllFileURLs(from: providers) { urls in
                Task {
                    await pool.importFilesOrFolders(urls: urls)
                }
            }
        }
    }
    
    // MARK: - 左侧：三维筛选（载体 / 基因 / 抗性）与质粒列表
    private var plasmidListCard: some View {
        StudioCard(title: "质粒筛选与列表 (\(pool.filteredItems.count)/\(pool.items.count))") {
            HStack(spacing: 8) {
                if pool.isScanning {
                    ProgressView().controlSize(.small)
                }
                if pool.hasActiveFilters {
                    StudioSectionClearButton(
                        title: "重置筛选",
                        action: pool.resetAllFilters
                    )
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                // 1. 搜索框（简洁提示语，绝不截断）
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("搜索质粒、载体、基因、抗性或酶切位点", text: $pool.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !pool.searchQuery.isEmpty {
                        Button(action: { pool.searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(NSColor.textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                )
                
                // 2. 三维动态筛选栏：载体 / 基因 / 抗性（全部采用 StudioFlowLayout 流式自动折行）
                VStack(alignment: .leading, spacing: 8) {
                    filterDimensionRow(
                        label: "载体",
                        icon: "circle.dashed",
                        options: pool.availableVectors,
                        selection: $pool.selectedVectorFilter,
                        tint: .blue
                    )
                    
                    filterDimensionRow(
                        label: "基因",
                        icon: "sparkles",
                        options: pool.availableGenes,
                        selection: $pool.selectedGeneFilter,
                        tint: .purple
                    )
                    
                    filterDimensionRow(
                        label: "抗性",
                        icon: "shield.lefthalf.filled",
                        options: pool.availableResistances,
                        selection: $pool.selectedResistanceFilter,
                        tint: .green
                    )
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                )
                
                // 3. 质粒列表
                if pool.filteredItems.isEmpty {
                    VStack(spacing: 12) {
                        if pool.items.isEmpty {
                            StudioActionPillButton(
                                title: "选择或拖入 .dna 质粒文件 / 文件夹",
                                icon: "folder.badge.plus",
                                tint: .blue,
                                isProminent: true,
                                action: presentImportFilesOrFolderPanel
                            )
                        } else {
                            Text("未找到符合当前「载体 / 基因 / 抗性」筛选条件的质粒")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            StudioActionPillButton(
                                title: "重置全部筛选条件",
                                icon: "arrow.counterclockwise",
                                tint: .blue,
                                action: pool.resetAllFilters
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            .foregroundColor(.secondary.opacity(0.25))
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(pool.filteredItems) { item in
                            plasmidRowCard(item)
                        }
                    }
                }
            }
        }
    }
    
    /// 单行筛选维度胶囊条（采用声明式 `StudioFlowLayout` 流式自动换行）
    private func filterDimensionRow(
        label: String,
        icon: String,
        options: [String],
        selection: Binding<String>,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(tint)
                Text(label)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .frame(width: 48, alignment: .leading)
            .padding(.top, 3)
            
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(options, id: \.self) { opt in
                    let isSelected = (selection.wrappedValue.caseInsensitiveCompare(opt) == .orderedSame)
                    Button(action: {
                        if isSelected && opt != "全部" {
                            selection.wrappedValue = "全部"
                        } else {
                            selection.wrappedValue = opt
                        }
                    }) {
                        Text(opt)
                            .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? tint : Color.primary.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(isSelected ? tint.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 0.8)
                            )
                            .foregroundColor(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    /// 单个质粒列表卡片：
    /// - 第一行：环状图标 + 质粒名称（弹性缩略） + 长度 + 「图谱」胶囊按钮 + 删除按钮（右侧固定，绝不被挤压）
    /// - 第二行：使用声明式 `StudioFlowLayout` 自动换行展示 `[载体] [基因] [抗性]` 标签，绝不撑破外层卡片
    private func plasmidRowCard(_ item: PlasmidPoolItem) -> some View {
        let isSelected = (pool.selectedItem?.id == item.id)
        let vectorName = item.resolvedVectorBackbone
        let genes = item.resolvedTargetGenes
        let resistances = item.resolvedResistances
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.dnaInfo.isCircular ? "circle.circle.fill" : "line.diagonal")
                    .foregroundColor(isSelected ? .blue : .teal)
                    .font(.system(size: 14, weight: .bold))
                
                Text(item.name)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Text("\(item.dnaInfo.length) bp")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                
                Button(action: {
                    PlasmidWindowPresenter.shared.openPreviewWindow(
                        for: item.dnaInfo,
                        roleLabel: item.name,
                        highlightRange: nil
                    )
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("图谱")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundColor(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.blue.opacity(0.12))
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                
                Button(action: { pool.removeItem(item) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("从质粒池移除")
            }
            
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                Button(action: {
                    pool.selectedVectorFilter = (pool.selectedVectorFilter == vectorName) ? "全部" : vectorName
                }) {
                    StudioMetricBadge(label: "载体", value: vectorName, color: .blue)
                }
                .buttonStyle(.plain)
                
                ForEach(genes, id: \.self) { g in
                    Button(action: {
                        pool.selectedGeneFilter = (pool.selectedGeneFilter == g) ? "全部" : g
                    }) {
                        StudioMetricBadge(label: "基因", value: g, color: .purple)
                    }
                    .buttonStyle(.plain)
                }
                
                ForEach(resistances, id: \.self) { r in
                    Button(action: {
                        pool.selectedResistanceFilter = (pool.selectedResistanceFilter == r) ? "全部" : r
                    }) {
                        StudioMetricBadge(label: "抗性", value: r, color: .green)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.blue.opacity(0.09) : Color(NSColor.textBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.blue.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.4 : 1.0)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            pool.selectedItemID = item.id
        }
        .contextMenu {
            Button("送入单片段克隆（作为载体）") { pool.sendToSingleCloneAsVector(item) }
            Button("送入单片段克隆（作为供体）") { pool.sendToSingleCloneAsDonor(item) }
            Button("送入多片段克隆（作为载体）") { pool.sendToMultiCloneAsVector(item) }
            Divider()
            Button("送入定点突变") { pool.sendToMutagenesis(item) }
            Button("送入片段删除") { pool.sendToFragmentDeletion(item) }
            Divider()
            Button("打开独立质粒图谱") {
                PlasmidWindowPresenter.shared.openPreviewWindow(for: item.dnaInfo, roleLabel: item.name, highlightRange: nil)
            }
            Button("从质粒池移除", role: .destructive) { pool.removeItem(item) }
        }
    }
    
    // MARK: - 右侧：选中质粒详情与图2风格双列对称胶囊派发面板
    private func plasmidInspectorCard(_ item: PlasmidPoolItem) -> some View {
        let vectorName = item.resolvedVectorBackbone
        let genes = item.resolvedTargetGenes
        let resistances = item.resolvedResistances
        let filteredFeatures = item.dnaInfo.features.filter { feat in
            guard !feat.segments.isEmpty else { return false }
            return inspectorFeatureFilter.matches(feat)
        }
        let displayedFeatures = filteredFeatures.isEmpty ? item.dnaInfo.features.filter { !$0.segments.isEmpty } : filteredFeatures
        
        return StudioCard(title: "选中质粒详情") {
            HStack(spacing: 8) {
                FinderRevealButton(filePath: item.dnaInfo.filePath, label: "Finder")
                StudioActionPillButton(
                    title: "查看图谱",
                    icon: "eye.fill",
                    tint: .blue,
                    isProminent: true
                ) {
                    PlasmidWindowPresenter.shared.openPreviewWindow(
                        for: item.dnaInfo,
                        roleLabel: item.name,
                        highlightRange: nil
                    )
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                // 1. 质粒完整名称与解析出的载体/基因/抗性概览（使用 StudioFlowLayout 流式自动换行，绝不截断右侧徽章）
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.name)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        StudioMetricBadge(label: "载体", value: vectorName, color: .blue)
                        if !genes.isEmpty {
                            StudioMetricBadge(label: "基因", value: genes.joined(separator: " / "), color: .purple)
                        }
                        if !resistances.isEmpty {
                            StudioMetricBadge(label: "抗性", value: resistances.joined(separator: " / "), color: .green)
                        }
                        StudioMetricBadge(label: "全长", value: "\(item.dnaInfo.length) bp", color: .teal)
                        StudioMetricBadge(label: "GC", value: String(format: "%.1f%%", item.gcPercent), color: .orange)
                        StudioMetricBadge(label: "", value: item.categoryTag, color: .indigo)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
                
                // 2. 参考图2的双列对称胶囊按钮矩阵（一键送入各分子克隆模块）
                VStack(alignment: .leading, spacing: 7) {
                    Text("一键送入克隆模块")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 8) {
                        StudioActionPillButton(
                            title: "作为单片段载体",
                            icon: "circle.dashed",
                            tint: .blue,
                            fillWidth: true
                        ) {
                            pool.sendToSingleCloneAsVector(item)
                        }
                        
                        StudioActionPillButton(
                            title: "作为单片段供体",
                            icon: "arrow.down.forward.circle",
                            tint: .teal,
                            fillWidth: true
                        ) {
                            pool.sendToSingleCloneAsDonor(item)
                        }
                    }
                    
                    HStack(spacing: 8) {
                        StudioActionPillButton(
                            title: "作为多片段载体",
                            icon: "square.stack.3d.up",
                            tint: .indigo,
                            fillWidth: true
                        ) {
                            pool.sendToMultiCloneAsVector(item)
                        }
                        
                        StudioActionPillButton(
                            title: "送入定点突变",
                            icon: "wand.and.rays",
                            tint: .pink,
                            fillWidth: true
                        ) {
                            pool.sendToMutagenesis(item)
                        }
                    }
                    
                    HStack(spacing: 8) {
                        StudioActionPillButton(
                            title: "送入片段删除",
                            icon: "scissors",
                            tint: .purple,
                            fillWidth: true
                        ) {
                            pool.sendToFragmentDeletion(item)
                        }
                        
                        StudioActionPillButton(
                            title: "算用量",
                            icon: "function",
                            tint: .orange,
                            fillWidth: true,
                            help: "将载体长度送入重组用量计算器"
                        ) {
                            let calcVM = WorkspaceSessionManager.shared.calculatorVM
                            calcVM.vectorName = item.name
                            calcVM.vectorLengthKb = String(format: "%.2f", Double(item.dnaInfo.length) / 1000.0)
                            AppState.shared.selectedNav = .dnaCalculator
                            AppState.shared.showToast("已将载体 \(item.name) (\(item.dnaInfo.length) bp) 送入用量计算器")
                        }
                    }
                }
                
                // 3. 唯一酶切位点（采用 StudioFlowLayout 流式自动换行，杜绝右侧截断）
                if !item.uniqueCutSites.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("唯一酶切位点 (\(item.uniqueCutSites.count))")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(item.uniqueCutSites.prefix(16), id: \.self) { site in
                                Text(site)
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.orange.opacity(0.11))
                                    )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                
                // 4. 质粒特征列表（支持按目的基因 / 标签调控 / 骨架抗性 / 全部过滤，标题栏响应式自动折行）
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("特征注释 (\(displayedFeatures.count))")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer()
                            StudioSegmentedPicker(
                                selection: $inspectorFeatureFilter,
                                options: PlasmidFeatureFilter.allCases.map {
                                    StudioSegmentedOption(value: $0, title: $0.shortTitle, tint: .purple)
                                }
                            )
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("特征注释 (\(displayedFeatures.count))")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.secondary)
                            StudioSegmentedPicker(
                                selection: $inspectorFeatureFilter,
                                options: PlasmidFeatureFilter.allCases.map {
                                    StudioSegmentedOption(value: $0, title: $0.shortTitle, tint: .purple)
                                }
                            )
                        }
                    }
                    
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(displayedFeatures) { feat in
                                let s = feat.segments.first?.start ?? 1
                                let e = feat.segments.last?.end ?? 1
                                let len = max(0, e - s + 1)
                                let dir = feat.directionality == "2" ? "←" : "→"
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(feat.name)
                                                .font(.system(size: 12.5, weight: .bold))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                            Text(feat.type)
                                                .font(.system(size: 10.5, weight: .semibold))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .fill(Color.primary.opacity(0.07))
                                                )
                                                .fixedSize(horizontal: true, vertical: false)
                                        }
                                        Text("\(s)..\(e) · \(len) bp (\(dir))")
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    
                                    if len >= 30 {
                                        StudioActionPillButton(
                                            title: "提取克隆",
                                            icon: "arrow.up.right.square",
                                            tint: .teal
                                        ) {
                                            extractFeatureToSingleClone(plasmid: item, feature: feat, start: s, end: e)
                                        }
                                        .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.primary.opacity(0.035))
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 290)
                }
                
                // 5. 关联分析记录 (AnalysisRun 跨模块实验溯源, P15)
                linkedAnalysisRunsSection(for: item)
            }
        }
    }
    
    @ViewBuilder
    private func linkedAnalysisRunsSection(for item: PlasmidPoolItem) -> some View {
        let linkedEntries = AnalysisRunIndexStore.entries(forPlasmidID: item.id, plasmidName: item.name)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("关联分析记录 (AnalysisRun 溯源)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(linkedEntries.count) 条")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.teal)
            }
            
            if linkedEntries.isEmpty {
                Text("暂无关联的 Sanger / WB / qPCR 分析导出记录；在对应模块关联该质粒并导出即可自动归档至此。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
            } else {
                VStack(spacing: 6) {
                    ForEach(linkedEntries.prefix(10)) { entry in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(entry.module)
                                        .font(.system(size: 10.5, weight: .bold))
                                        .foregroundColor(.teal)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.teal.opacity(0.12)))
                                    Text(entry.createdAt, style: .date)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text("v\(entry.schemaVersion)")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                Text(entry.summary)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            FinderRevealButton(filePath: entry.sidecarFilePath, label: ".run.json")
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        )
                    }
                }
            }
        }
    }
    
    private func presentImportFilesOrFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择 .dna / .fasta 文件或文件夹"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let selectedURLs = panel.urls
            Task {
                await pool.importFilesOrFolders(urls: selectedURLs)
            }
        }
    }
    
    private func extractFeatureToSingleClone(plasmid: PlasmidPoolItem, feature: SnapGeneFeature, start: Int, end: Int) {
        let vm = WorkspaceSessionManager.shared.singleFragmentVM
        let seq = BioSequence.clean(plasmid.dnaInfo.sequence)
        guard start >= 1, end <= seq.count, start <= end else { return }
        vm.insertSourceDNAInfo = plasmid.dnaInfo
        vm.donorExtractSource = .byFeature
        vm.selectInsertFeature(id: feature.id)
        AppState.shared.selectedNav = .singleFragment
        AppState.shared.showToast("已从「\(plasmid.name)」提取特征「\(feature.name)」(\(end - start + 1) bp) 至单片段克隆！")
    }
}
