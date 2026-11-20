import SwiftUI
import CloneStudioCore

/// CRISPR/Cas9 sgRNA 文库检索、内嵌三源在线比对与引物设计界面
public struct SgRNADesignView: View {
    @ObservedObject private var vm = WorkspaceSessionManager.shared.sgRNAVM
    @ObservedObject private var onlineVM = WorkspaceSessionManager.shared.chopchopVM
    @ObservedObject private var appState = AppState.shared
    
    public init() {}
    
    private var previewTarget: (gene: String, seq: String)? {
        guard !vm.generatedPrimers.isEmpty else { return nil }
        switch vm.sourceMode {
        case .custom:
            let g = vm.customGeneName.isEmpty ? "sgTarget" : vm.customGeneName
            return (g, vm.customSequence)
        case .onlineCompare:
            let g = onlineVM.gene.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedGene = g.isEmpty ? "sgTarget" : g
            if let sel = onlineVM.sortedTargets.first(where: { onlineVM.selectedTargetIDs.contains($0.id) }) {
                return (resolvedGene, sel.spacer)
            } else if let first = onlineVM.sortedTargets.first {
                return (resolvedGene, first.spacer)
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
        return PlasmidMapBuilder.forSgRNA(
            species: vm.species,
            geneName: pt.gene,
            spacerSequence: pt.seq,
            overhangType: vm.vectorOverhang,
            hasGenerated: !vm.generatedPrimers.isEmpty
        )
    }
    
    private var activeSelectionCount: Int {
        switch vm.sourceMode {
        case .library:
            return vm.selectedTargetIDs.count
        case .onlineCompare:
            return onlineVM.selectedTargetIDs.count
        case .custom:
            return BioSequence.clean(vm.customSequence).count >= 19 ? 1 : 0
        }
    }
    
    private var canClearAny: Bool {
        !vm.searchQuery.isEmpty
            || !vm.searchResults.isEmpty
            || !vm.customSequence.isEmpty
            || !vm.generatedPrimers.isEmpty
            || !onlineVM.gene.isEmpty
            || !onlineVM.targets.isEmpty
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "CRISPR/Cas9 sgRNA 设计",
            toolbar: [
                .plasmidToggle(isOn: $appState.showPlasmidPreview, isAvailable: previewData != nil),
                .picker(
                    id: "sgrna_species",
                    label: "物种",
                    options: TargetSpecies.allCases.map { spec in
                        StudioToolbarPickerOption(
                            id: spec.rawValue,
                            title: spec == .human ? "人源 (hg38)" : "鼠源 (mm39)",
                            tint: spec == .human ? .blue : .orange,
                            isSelected: vm.species == spec
                        ) {
                            if vm.species != spec {
                                vm.species = spec
                                onlineVM.species = spec
                                if vm.sourceMode == .onlineCompare {
                                    if !onlineVM.gene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        onlineVM.fetchTargets()
                                    }
                                } else if !vm.searchQuery.isEmpty {
                                    vm.search()
                                }
                            }
                        }
                    }
                ),
                .action(
                    id: "sgrna_web_menu",
                    groupKey: nil,
                    title: "网页版",
                    icon: "safari",
                    help: "在 Safari 中打开对应的在线靶点设计数据库",
                    menuItems: [
                        StudioToolbarMenuItem(title: "打开 VBC-Score", icon: "bolt.shield.fill") {
                            onlineVM.openSourceInSafari(.vbcScore)
                        },
                        StudioToolbarMenuItem(title: "打开 CRISPOR (UCSC)", icon: "waveform.path.ecg") {
                            onlineVM.openSourceInSafari(.ucscCrispor)
                        },
                        StudioToolbarMenuItem(title: "打开 CHOPCHOP", icon: "globe") {
                            onlineVM.openSourceInSafari(.chopchop)
                        }
                    ]
                ),
                .action(
                    id: "clear_sgrna",
                    groupKey: nil,
                    title: "",
                    icon: "trash",
                    tint: .red,
                    isDisabled: !canClearAny,
                    help: "一键清除本地与在线检索结果"
                ) {
                    vm.clear()
                    onlineVM.clear()
                }
            ]
        ) {
            AdaptiveTwoColumnWorkspace(hasRight: previewData != nil && appState.showPlasmidPreview) {
                VStack(alignment: .leading, spacing: 12) {
                    // 1. 靶点筛选与在线对比
                    StudioCard(title: "靶点筛选与对比") {
                        StudioSegmentedPicker(
                            selection: $vm.sourceMode,
                            options: [
                                StudioSegmentedOption(value: .library, title: "本地文库", tint: .blue),
                                StudioSegmentedOption(value: .onlineCompare, title: "在线对比", tint: .orange),
                                StudioSegmentedOption(value: .custom, title: "手动输入", tint: .teal)
                            ]
                        )
                    } content: {
                        switch vm.sourceMode {
                        case .library:
                            librarySearchSection
                        case .onlineCompare:
                            SgRNAOnlineComparePanel(
                                species: vm.species,
                                vectorOverhang: vm.vectorOverhang,
                                customPrefix: vm.customPrefix
                            )
                        case .custom:
                            customInputSection
                        }
                    }
                    
                    // 2. 载体骨架与命名
                    StudioCard(title: "载体骨架与命名") {
                        StudioMetricBadge(
                            label: "接头",
                            value: vm.vectorOverhang == .px459_px458 ? "BbsI (CACC)" : "BsmBI (CACCG)",
                            color: .cyan
                        )
                    } content: {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                StudioMenuPicker(
                                    selection: $vm.vectorOverhang,
                                    options: CRISPRDesigner.VectorOverhang.allCases.map {
                                        StudioMenuPickerOption(value: $0, title: $0.rawValue)
                                    },
                                    prefix: "载体",
                                    icon: "circle.dotted.circle",
                                    help: "选择靶点寡核苷酸退火克隆的载体酶切粘性末端"
                                )
                                
                                TextField("引物前缀 (可选)", text: $vm.customPrefix)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.large)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                StudioMenuPicker(
                                    selection: $vm.vectorOverhang,
                                    options: CRISPRDesigner.VectorOverhang.allCases.map {
                                        StudioMenuPickerOption(value: $0, title: $0.rawValue)
                                    },
                                    prefix: "载体",
                                    icon: "circle.dotted.circle"
                                )
                                
                                TextField("引物前缀 (可选)", text: $vm.customPrefix)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.large)
                            }
                        }
                    }
                    
                    // 3. 居左紧凑主操作栏（设计引物 + 次级入池）
                    StudioActionBar {
                        StudioPrimaryActionButton(
                            title: activeSelectionCount > 0 ? "设计 sgRNA 引物 (\(activeSelectionCount))" : "设计 sgRNA 引物",
                            icon: "sparkles",
                            tint: .cyan,
                            action: vm.generatePrimers
                        )
                        
                        if !vm.generatedPrimers.isEmpty {
                            StudioActionPillButton(
                                title: "加入引物池 (\(vm.generatedPrimers.count))",
                                icon: "cart.badge.plus",
                                tint: .green,
                                action: vm.addAllToCart
                            )
                        }
                    }
                    
                    // 4. 生成的引物结果
                    if !vm.generatedPrimers.isEmpty {
                        StudioCard(title: "生成的引物结果") {
                            StudioMetricBadge(label: "数量", value: "\(vm.generatedPrimers.count) 条", color: .green)
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
        .alert("提示", isPresented: $vm.showErrorAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onAppear {
            handleAutoOnlineTrigger()
        }
        .onChange(of: appState.shouldAutoQueryCHOPCHOP) { _, shouldQuery in
            if shouldQuery {
                handleAutoOnlineTrigger()
            }
        }
    }
    
    private func handleAutoOnlineTrigger() {
        if appState.shouldAutoQueryCHOPCHOP {
            appState.shouldAutoQueryCHOPCHOP = false
            vm.species = appState.chopchopSpecies
            vm.openInlineOnlineCompare(gene: appState.chopchopGene, forceRefresh: false)
        }
    }
    
    private var librarySearchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("输入待检索基因 (如 TP53, PRKAA1, Trp53)", text: $vm.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.system(size: 12.5))
                    .onSubmit { vm.search() }
                
                StudioActionPillButton(
                    title: vm.isSearching ? "检索中" : "检索",
                    icon: "magnifyingglass",
                    tint: .cyan,
                    isProminent: true,
                    isDisabled: vm.isSearching,
                    action: vm.search
                )
            }
            
            if !vm.searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        StudioMetricBadge(
                            label: "已选",
                            value: "\(vm.selectedTargetIDs.count)/\(vm.searchResults.count)",
                            color: .cyan
                        )
                        
                        Text(vm.species.chopchopGenome)
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
                            compact: true,
                            help: "本地评分仅评估 GC、二级结构与 Poly-T；点击「在线核验」可用 VBC-Score / UCSC CRISPOR / CHOPCHOP 验证全基因组脱靶"
                        )
                        
                        StudioCompactPillButton(
                            title: "选高分",
                            tint: .green,
                            help: "快速勾选序列启发式评分高 (★★★ / ★★) 的靶点",
                            action: vm.selectRecommendedOnly
                        )
                        
                        StudioCompactPillButton(title: "全选", action: vm.selectAll)
                        StudioCompactPillButton(title: "清空", tint: .red, action: vm.deselectAll)
                        
                        StudioCompactPillButton(
                            title: "在线核验",
                            icon: "waveform.path.ecg",
                            tint: .orange,
                            isProminent: true,
                            help: "转至内嵌三源在线对比，核验全基因组脱靶并交叉评分"
                        ) {
                            vm.openInlineOnlineCompare()
                        }
                    }
                    
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(vm.searchResults) { target in
                                LocalLibraryTargetRow(
                                    target: target,
                                    isChecked: vm.selectedTargetIDs.contains(target.id),
                                    accentColor: .cyan,
                                    copyToastPrefix: "已复制 20bp Spacer",
                                    polyTHelp: "该靶点含连续 4 个 T，在 U6 启动子下转录提前终止",
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
            sequencePlaceholder: "20 bp 靶点 Spacer (不含 PAM)",
            score: vm.customTargetScore
        )
    }
}
