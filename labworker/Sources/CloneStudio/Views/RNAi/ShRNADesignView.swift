import SwiftUI
import CloneStudioCore

/// 慢病毒 RNA 干扰 shRNA 文库检索与设计界面 (紧凑无冗余、仅在提交后真实预览、多维可靠性打分与排序)
public struct ShRNADesignView: View {
    @ObservedObject private var vm = WorkspaceSessionManager.shared.shRNAVM
    @ObservedObject private var appState = AppState.shared
    
    public init() {}
    
    private var previewTarget: (gene: String, seq: String)? {
        guard !vm.generatedPrimers.isEmpty else { return nil }
        if vm.isCustomInputMode {
            let g = vm.customGeneName.isEmpty ? "shTarget" : vm.customGeneName
            return (g, vm.customSequence)
        } else {
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
    
    public var body: some View {
        StudioPageLayout(
            title: "RNAi shRNA 设计 (pLKO.1)",
            toolbar: [
                .plasmidToggle(isOn: $appState.showPlasmidPreview, isAvailable: previewData != nil),
                .picker(
                    id: "shrna_species",
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
                                if !vm.searchQuery.isEmpty {
                                    vm.search()
                                }
                            }
                        }
                    }
                ),
                .action(
                    id: "clear_shrna",
                    groupKey: nil,
                    title: "",
                    icon: "trash",
                    tint: .red,
                    isDisabled: vm.searchQuery.isEmpty && vm.searchResults.isEmpty && vm.customSequence.isEmpty && vm.generatedPrimers.isEmpty,
                    help: "一键清除",
                    action: vm.clear
                )
            ]
        ) {
                
                AdaptiveTwoColumnWorkspace(hasRight: previewData != nil && appState.showPlasmidPreview) {
                    VStack(alignment: .leading, spacing: 12) {
                        // 1. 靶点模式
                        StudioCard(title: "靶点来源") {
                            StudioSegmentedPicker(
                                selection: $vm.isCustomInputMode,
                                options: [
                                    StudioSegmentedOption(value: false, title: "TRC 文库", tint: .indigo),
                                    StudioSegmentedOption(value: true, title: "手动输入", tint: .purple)
                                ]
                            )
                        } content: {
                            if !vm.isCustomInputMode {
                                librarySearchSection
                            } else {
                                customInputSection
                            }
                        }
                        
                        // 2. Loop 与前缀
                        StudioCard(title: "发夹环 (Loop) 与命名前缀") {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) {
                                    HStack(spacing: 6) {
                                        Text("Loop:").font(.system(size: 11.5)).foregroundColor(.secondary)
                                        TextField("CTCGAG", text: $vm.loopSequence)
                                            .font(.system(size: 12, design: .monospaced))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 90)
                                    }
                                    TextField("引物前缀 (可选)", text: $vm.customPrefix)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Text("Loop:").font(.system(size: 11.5)).foregroundColor(.secondary)
                                        TextField("CTCGAG", text: $vm.loopSequence)
                                            .font(.system(size: 12, design: .monospaced))
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 90)
                                    }
                                    TextField("引物前缀 (可选)", text: $vm.customPrefix)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                        
                        // 3. 参考图2对称全宽主操作栏
                        HStack(spacing: 10) {
                            StudioPrimaryActionButton(
                                title: "设计 shRNA 引物",
                                icon: "sparkles",
                                tint: .indigo,
                                fillWidth: true,
                                action: vm.generatePrimers
                            )
                            
                            StudioPrimaryActionButton(
                                title: "CHOPCHOP 靶点对比",
                                icon: "globe.badge.chevron.backward",
                                tint: .orange,
                                fillWidth: true
                            ) {
                                let clean = vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                                let g: String
                                if !clean.isEmpty {
                                    g = clean
                                } else if let firstSel = vm.searchResults.first(where: { vm.selectedTargetIDs.contains($0.id) }) {
                                    g = firstSel.gene
                                } else if let first = vm.searchResults.first {
                                    g = first.gene
                                } else if vm.isCustomInputMode && !vm.customGeneName.isEmpty {
                                    g = vm.customGeneName
                                } else {
                                    g = "TP53"
                                }
                                vm.compareInCHOPCHOP(gene: g)
                            }
                            
                            if !vm.generatedPrimers.isEmpty {
                                StudioPrimaryActionButton(
                                    title: "加入引物池",
                                    icon: "cart.badge.plus",
                                    tint: .green,
                                    fillWidth: true,
                                    action: vm.addAllToCart
                                )
                            }
                        }
                        // 结果展示 (就近展示)
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
                    // 仅在真实生成引物且开关开启时展示质粒图谱，绝不凭空臆造
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
    }
    
    private var librarySearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("输入待检索基因 (如 TP53, CDH17, GAPDH)", text: $vm.searchQuery)
                    .textFieldStyle(.roundedBorder)
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
                VStack(alignment: .leading, spacing: 5) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 6) {
                            Text("结果 (\(vm.searchResults.count)条, 已选\(vm.selectedTargetIDs.count)条)")
                                .font(.system(size: 11, weight: .semibold))
                            
                            Spacer()
                            
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
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("结果 (\(vm.searchResults.count)条, 已选\(vm.selectedTargetIDs.count)条)")
                                    .font(.system(size: 11, weight: .semibold))
                                Spacer()
                                StudioMenuPicker(
                                    selection: $vm.sortOption,
                                    options: TargetSortOption.allCases.map {
                                        StudioMenuPickerOption(value: $0, title: $0.rawValue)
                                    },
                                    compact: true
                                )
                            }
                            HStack(spacing: 6) {
                                StudioCompactPillButton(
                                    title: "选推荐",
                                    tint: .indigo,
                                    help: "快速勾选 ★★★ 卓越与 ★★ 良好靶点",
                                    action: vm.selectRecommendedOnly
                                )
                                StudioCompactPillButton(title: "全选", action: vm.selectAll)
                                StudioCompactPillButton(title: "清空", tint: .red, action: vm.deselectAll)
                                Spacer()
                            }
                        }
                    }
                    
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(vm.searchResults) { target in
                                let isChecked = vm.selectedTargetIDs.contains(target.id)
                                let scoreRes = target.scoreResult
                                
                                HStack(spacing: 6) {
                                    Toggle("", isOn: Binding(
                                        get: { isChecked },
                                        set: { _ in vm.toggleTarget(target) }
                                    ))
                                    .labelsHidden()
                                    
                                    // 评分徽章 (点击悬停诊断详情)
                                    TargetScoreBadge(score: scoreRes, compact: true)
                                    
                                    Text(target.gene)
                                        .font(.system(size: 11, weight: .bold))
                                        .frame(width: 50, alignment: .leading)
                                    
                                    Text(target.sequence)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(isChecked ? .indigo : .primary)
                                        .textSelection(.enabled)
                                    
                                    Spacer()
                                    
                                    if scoreRes.hasFatalIssue {
                                        Text("⚠️TTTT")
                                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(.red)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.red.opacity(0.12)))
                                            .help("Sense链含连续4个T，在pLKO.1中导致提前转录终止")
                                    }
                                    
                                    Text("GC \(String(format: "%.0f", target.gcPercent))%")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .studioInnerBox(tint: isChecked ? .indigo : nil, isHighlighted: isChecked, paddingH: 8, paddingV: 5)
                            }
                        }
                    }
                    .frame(maxHeight: 170)
                }
            }
        }
    }
    
    private var customInputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("基因名", text: $vm.customGeneName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                
                TextField("19~21 bp 靶点 Sense 序列", text: $vm.customSequence)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                
                if let sc = vm.customTargetScore {
                    TargetScoreBadge(score: sc, compact: false)
                }
            }
            
            if let sc = vm.customTargetScore, sc.hasFatalIssue, let warning = sc.fatalWarning {
                HStack(spacing: 4) {
                    Text("⚠️")
                    Text(warning)
                        .font(.system(size: 10.5))
                        .foregroundColor(.red)
                }
                .studioInnerBox(tint: .red, paddingH: 8, paddingV: 4)
            }
        }
    }
}
