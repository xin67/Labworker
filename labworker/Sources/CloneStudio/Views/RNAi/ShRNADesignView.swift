import SwiftUI
import CloneStudioCore

/// 慢病毒 RNA 干扰 shRNA 文库检索、内嵌 Broad GPP 在线对比与发夹引物设计界面
public struct ShRNADesignView: View {
    @ObservedObject private var vm = WorkspaceSessionManager.shared.shRNAVM
    @ObservedObject private var gppVM = WorkspaceSessionManager.shared.broadGPPVM
    @ObservedObject private var appState = AppState.shared
    
    public init() {}
    
    private var previewTarget: (gene: String, seq: String)? {
        guard !vm.generatedPrimers.isEmpty else { return nil }
        switch vm.sourceMode {
        case .custom:
            let g = vm.customGeneName.isEmpty ? "shTarget" : vm.customGeneName
            return (g, vm.customSequence)
        case .broadGPP:
            let g = (gppVM.resolvedGeneSymbol ?? gppVM.gene).trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedGene = g.isEmpty ? "shTarget" : g
            if let sel = gppVM.sortedTargets.first(where: { gppVM.selectedTargetIDs.contains($0.id) }) {
                return (resolvedGene, sel.targetSequence)
            } else if let first = gppVM.sortedTargets.first {
                return (resolvedGene, first.targetSequence)
            }
            return nil
        case .library:
            if let firstSel = vm.searchResults.first(where: { vm.selectedTargetIDs.contains($0.id) }) {
                return (firstSel.gene, firstSel.sequence)
            } else if let first = vm.searchResults.first {
                return (first.gene, first.sequence)
            }
            return nil
        }
    }
    
    private var previewData: PlasmidConstructPreviewData? {
        guard let pt = previewTarget else { return nil }
        return PlasmidMapBuilder.forShRNA(
            species: vm.species,
            geneName: pt.gene,
            senseSequence: pt.seq,
            loopSequence: vm.loopSequence,
            hasGenerated: !vm.generatedPrimers.isEmpty
        )
    }
    
    private var activeSelectionCount: Int {
        switch vm.sourceMode {
        case .library:
            return vm.selectedTargetIDs.count
        case .broadGPP:
            return gppVM.selectedTargetIDs.count
        case .custom:
            return BioSequence.clean(vm.customSequence).count >= 18 ? 1 : 0
        }
    }
    
    private var canClearAny: Bool {
        !vm.searchQuery.isEmpty
            || !vm.searchResults.isEmpty
            || !vm.customSequence.isEmpty
            || !vm.generatedPrimers.isEmpty
            || !gppVM.gene.isEmpty
            || !gppVM.targets.isEmpty
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "RNAi shRNA 设计 (pLKO.1)",
            toolbar: [
                .plasmidToggle(isOn: $appState.showPlasmidPreview, isAvailable: previewData != nil),
                .picker(
                    id: "shrna_species",
                    label: L10n.t("物种"),
                    options: TargetSpecies.allCases.map { spec in
                        StudioToolbarPickerOption(
                            id: spec.rawValue,
                            title: spec == .human ? "人源 (hg38)" : "鼠源 (mm39)",
                            tint: spec == .human ? .blue : .orange,
                            isSelected: vm.species == spec
                        ) {
                            if vm.species != spec {
                                vm.species = spec
                                gppVM.species = spec
                                if vm.sourceMode == .broadGPP {
                                    if !gppVM.gene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        gppVM.fetchTargets()
                                    }
                                } else if !vm.searchQuery.isEmpty {
                                    vm.search()
                                }
                            }
                        }
                    }
                ),
                .action(
                    id: "shrna_web_menu",
                    groupKey: nil,
                    title: "Broad GPP",
                    icon: "safari",
                    help: "在 Safari 中打开 Broad GPP Public Portal",
                    menuItems: [
                        StudioToolbarMenuItem(
                            title: gppVM.resolvedGeneSymbol.map { L10n.tr("打开 \($0) 克隆详情页", "Open \($0) Clone Page") } ?? L10n.t("打开 Broad GPP 基因检索"),
                            icon: "magnifyingglass"
                        ) {
                            gppVM.openGeneInSafari()
                        },
                        StudioToolbarMenuItem(title: "打开 Broad GPP 主页", icon: "globe") {
                            BroadGPPService.shared.openInDefaultBrowser(geneID: nil)
                        }
                    ]
                ),
                .action(
                    id: "clear_shrna",
                    groupKey: nil,
                    title: "",
                    icon: "trash",
                    tint: .red,
                    isDisabled: !canClearAny,
                    help: "一键清除本地与 Broad GPP 检索结果"
                ) {
                    vm.clear()
                    gppVM.clear()
                }
            ]
        ) {
            AdaptiveTwoColumnWorkspace(hasRight: previewData != nil && appState.showPlasmidPreview) {
                VStack(alignment: .leading, spacing: 12) {
                    // 1. 靶点筛选与在线 Broad GPP 对比
                    StudioCard(title: "靶点筛选与对比") {
                        StudioSegmentedPicker(
                            selection: $vm.sourceMode,
                            options: [
                                StudioSegmentedOption(value: .library, title: "TRC 文库", tint: .indigo),
                                StudioSegmentedOption(value: .broadGPP, title: "Broad GPP", tint: .orange),
                                StudioSegmentedOption(value: .custom, title: "手动输入", tint: .purple)
                            ]
                        )
                    } content: {
                        switch vm.sourceMode {
                        case .library:
                            librarySearchSection
                        case .broadGPP:
                            ShRNABroadGPPComparePanel(
                                species: vm.species,
                                loopSequence: vm.loopSequence,
                                customPrefix: vm.customPrefix
                            )
                        case .custom:
                            customInputSection
                        }
                    }
                    
                    // 2. 发夹环 (Loop) 与命名前缀
                    StudioCard(title: "发夹参数与命名") {
                        StudioMetricBadge(label: L10n.t("载体"), value: "pLKO.1 (AgeI/EcoRI)", color: .indigo)
                    } content: {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                HStack(spacing: 6) {
                                    Text("Loop:")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                    TextField("CTCGAG", text: $vm.loopSequence)
                                        .font(.system(size: 12))
                                        .textFieldStyle(.roundedBorder)
                                        .controlSize(.large)
                                        .frame(width: 108)
                                }
                                
                                loopPresetButton("CTCGAG", label: "CTCGAG")
                                loopPresetButton("TTCAAGAGA", label: "TTCAAGAGA")
                                
                                TextField(L10n.t("引物前缀 (可选)"), text: $vm.customPrefix)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.large)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                    HStack(spacing: 6) {
                                        Text("Loop:")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.secondary)
                                        TextField("CTCGAG", text: $vm.loopSequence)
                                            .font(.system(size: 12))
                                            .textFieldStyle(.roundedBorder)
                                            .controlSize(.large)
                                            .frame(width: 108)
                                    }
                                    loopPresetButton("CTCGAG", label: "CTCGAG")
                                    loopPresetButton("TTCAAGAGA", label: "TTCAAGAGA")
                                }
                                
                                TextField(L10n.t("引物前缀 (可选)"), text: $vm.customPrefix)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.large)
                            }
                        }
                    }
                    
                    // 3. 居左紧凑主操作栏（设计发夹引物 + 次级入池）
                    StudioActionBar {
                        StudioPrimaryActionButton(
                            title: activeSelectionCount > 0 ? L10n.tr("设计 shRNA 引物 (\(activeSelectionCount))", "Design shRNA Primers (\(activeSelectionCount))") : L10n.t("设计 shRNA 引物"),
                            icon: "sparkles",
                            tint: .indigo,
                            action: vm.generatePrimers
                        )
                        
                        if !vm.generatedPrimers.isEmpty {
                            StudioActionPillButton(
                                title: L10n.tr("加入引物池 (\(vm.generatedPrimers.count))", "Add to Primer Cart (\(vm.generatedPrimers.count))"),
                                icon: "cart.badge.plus",
                                tint: .green,
                                action: vm.addAllToCart
                            )
                        }
                    }
                    
                    // 4. 生成的引物结果
                    if !vm.generatedPrimers.isEmpty {
                        StudioCard(title: "生成的引物结果") {
                            StudioMetricBadge(label: L10n.t("数量"), value: L10n.tr("\(vm.generatedPrimers.count) 条", "\(vm.generatedPrimers.count)"), color: .green)
                        } content: {
                            VStack(spacing: 10) {
                                ForEach(Array(vm.generatedPrimers.enumerated()), id: \.element.id) { idx, primer in
                                    let partnerIdx = (idx % 2 == 0) ? (idx + 1) : (idx - 1)
                                    let partner = (partnerIdx >= 0 && partnerIdx < vm.generatedPrimers.count) ? vm.generatedPrimers[partnerIdx] : nil
                                    PrimerCardView(primer: primer, partnerPrimer: partner)
                                }
                            }
                        }
                    }
                }
            } right: {
                if let pData = previewData {
                    PlasmidPreviewPanel(data: pData, onClose: {
                        appState.showPlasmidPreview = false
                    })
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showErrorAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onAppear {
            handleAutoGPPTrigger()
        }
        .onChange(of: appState.shouldAutoQueryBroadGPP) { _, shouldQuery in
            if shouldQuery {
                handleAutoGPPTrigger()
            }
        }
    }
    
    private func loopPresetButton(_ seq: String, label: String) -> some View {
        let isActive = BioSequence.clean(vm.loopSequence).uppercased() == seq
        return StudioCompactPillButton(
            title: label,
            tint: isActive ? .indigo : nil,
            isSelected: isActive,
            help: L10n.tr("切换经典 pLKO.1 发夹环序列 \(seq)", "Switch canonical pLKO.1 loop sequence \(seq)")
        ) {
            vm.loopSequence = seq
        }
    }
    
    private func handleAutoGPPTrigger() {
        if appState.shouldAutoQueryBroadGPP {
            appState.shouldAutoQueryBroadGPP = false
            vm.species = appState.chopchopSpecies
            vm.openInlineBroadGPPCompare(gene: appState.chopchopGene, forceRefresh: false)
        }
    }
    
    private var librarySearchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(L10n.t("输入待检索基因 (如 TP53, CDH17, Trp53)"), text: $vm.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.system(size: 12.5))
                    .onSubmit { vm.search() }
                
                StudioActionPillButton(
                    title: vm.isSearching ? "检索中" : "检索",
                    icon: "magnifyingglass",
                    tint: .indigo,
                    isProminent: true,
                    isDisabled: vm.isSearching,
                    action: vm.search
                )
            }
            
            if !vm.searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        StudioMetricBadge(
                            label: L10n.t("已选"),
                            value: "\(vm.selectedTargetIDs.count)/\(vm.searchResults.count)",
                            color: .indigo
                        )
                        
                        Text(vm.species.shortName)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(vm.species.themeColor.opacity(0.14)))
                            .foregroundColor(vm.species.themeColor)
                        
                        StudioMenuPicker(
                            selection: $vm.sortOption,
                            options: TargetSortOption.allCases.map {
                                StudioMenuPickerOption(value: $0, title: $0.rawValue)
                            },
                            compact: true
                        )
                        
                        StudioCompactPillButton(
                            title: "选推荐",
                            tint: .indigo,
                            help: "快速勾选 ★★★ 卓越与 ★★ 良好靶点",
                            action: vm.selectRecommendedOnly
                        )
                        
                        StudioCompactPillButton(title: "全选", action: vm.selectAll)
                        StudioCompactPillButton(title: "清空", tint: .red, action: vm.deselectAll)
                        
                        StudioCompactPillButton(
                            title: "Broad GPP 核验",
                            icon: "arrow.triangle.2.circlepath",
                            tint: .orange,
                            isProminent: true,
                            help: "转至内嵌 Broad GPP Public Portal 对照官方 TRC 克隆评分与脱靶情况"
                        ) {
                            vm.openInlineBroadGPPCompare()
                        }
                    }
                    
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(vm.searchResults) { target in
                                LocalLibraryTargetRow(
                                    target: target,
                                    isChecked: vm.selectedTargetIDs.contains(target.id),
                                    accentColor: .indigo,
                                    copyToastPrefix: "已复制 shRNA 靶点序列",
                                    polyTHelp: "Sense 链含连续 4 个 T，在 pLKO.1 中导致提前转录终止",
                                    onToggle: { vm.toggleTarget(target) }
                                )
                            }
                        }
                    }
                    .frame(height: min(max(130, CGFloat(vm.searchResults.count) * 34), 260))
                }
            }
        }
    }
    
    private var customInputSection: some View {
        LocalCustomTargetInputSection(
            geneName: $vm.customGeneName,
            sequence: $vm.customSequence,
            sequencePlaceholder: "19~21 bp 靶点 Sense 序列",
            score: vm.customTargetScore
        )
    }
}
