import SwiftUI
import CloneStudioCore

/// CRISPR/Cas9 sgRNA 文库检索与设计界面 (紧凑无冗余、仅在提交后真实预览、多维可靠性打分与排序)
public struct SgRNADesignView: View {
    @ObservedObject private var vm = WorkspaceSessionManager.shared.sgRNAVM
    @ObservedObject private var appState = AppState.shared
    
    public init() {}
    
    private var previewTarget: (gene: String, seq: String)? {
        guard !vm.generatedPrimers.isEmpty else { return nil }
        if vm.isCustomInputMode {
            let g = vm.customGeneName.isEmpty ? "sgTarget" : vm.customGeneName
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
        return PlasmidMapBuilder.forSgRNA(
            species: vm.species,
            geneName: pt.gene,
            spacerSequence: pt.seq,
            overhangType: vm.vectorOverhang,
            hasGenerated: !vm.generatedPrimers.isEmpty
        )
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
                                if !vm.searchQuery.isEmpty {
                                    vm.search()
                                }
                            }
                        }
                    }
                ),
                .action(
                    id: "clear_sgrna",
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
                        // 1. 靶点来源模式
                        StudioCard(title: "靶点来源") {
                            StudioSegmentedPicker(
                                selection: $vm.isCustomInputMode,
                                options: [
                                    StudioSegmentedOption(value: false, title: "文库检索", tint: .blue),
                                    StudioSegmentedOption(value: true, title: "手动输入", tint: .teal)
                                ]
                            )
                        } content: {
                            if !vm.isCustomInputMode {
                                librarySearchSection
                            } else {
                                customInputSection
                            }
                        }
                        
                        // 2. 载体骨架
                        StudioCard(title: "载体骨架与命名") {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) {
                                    Picker("载体", selection: $vm.vectorOverhang) {
                                        ForEach(CRISPRDesigner.VectorOverhang.allCases) { v in
                                            Text(v.rawValue).tag(v)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 200)
                                    
                                    TextField("引物前缀 (可选)", text: $vm.customPrefix)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Picker("载体", selection: $vm.vectorOverhang) {
                                        ForEach(CRISPRDesigner.VectorOverhang.allCases) { v in
                                            Text(v.rawValue).tag(v)
                                        }
                                    }
                                    .labelsHidden()
                                    
                                    TextField("引物前缀 (可选)", text: $vm.customPrefix)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                        
                        // 3. 参考图2对称全宽主操作栏
                        HStack(spacing: 10) {
                            StudioPrimaryActionButton(
                                title: "设计 sgRNA 引物",
                                icon: "sparkles",
                                tint: .cyan,
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
                        // 生成的引物展示 (就近展示)
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
                TextField("输入待检索基因 (如 TP53, PRKAA1, Trp53)", text: $vm.searchQuery)
                    .textFieldStyle(.roundedBorder)
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
                VStack(alignment: .leading, spacing: 6) {
                    // 固定非浮层脱靶核验说明条
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Text("本评分仅评估 GC、二级结构与 Poly-T，未进行全基因组脱靶搜索。请在‘靶点对比’中用 CHOPCHOP 核验特异性。")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        StudioCompactPillButton(
                            title: "靶点对比",
                            icon: "globe.badge.chevron.backward",
                            tint: .orange,
                            help: "在 CHOPCHOP 靶点对比模块中核验脱靶特异性"
                        ) {
                            let clean = vm.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                            let g = !clean.isEmpty ? clean : (vm.searchResults.first?.gene ?? "TP53")
                            vm.compareInCHOPCHOP(gene: g)
                        }
                    }
                    .studioInnerBox(tint: .orange, paddingH: 10, paddingV: 6)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 6) {
                            Text("结果 (\(vm.searchResults.count)条, 已选\(vm.selectedTargetIDs.count)条)")
                                .font(.system(size: 11, weight: .semibold))

                            Text("文库参考基因组: \(vm.species.chopchopGenome)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(vm.species.themeColor.opacity(0.12)))
                                .foregroundColor(vm.species.themeColor)

                            Spacer()

                            StudioMenuPicker(
                                selection: $vm.sortOption,
                                options: TargetSortOption.allCases.map {
                                    StudioMenuPickerOption(value: $0, title: $0.rawValue)
                                },
                                compact: true
                            )

                            StudioCompactPillButton(
                                title: "选高分",
                                tint: .green,
                                help: "快速勾选序列启发式评分高 (★★★ / ★★) 的靶点",
                                action: vm.selectRecommendedOnly
                            )

                            StudioCompactPillButton(title: "全选", action: vm.selectAll)

                            StudioCompactPillButton(title: "清空", tint: .red, action: vm.deselectAll)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("结果 (\(vm.searchResults.count)条, 已选\(vm.selectedTargetIDs.count)条)")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("参考基因组: \(vm.species.chopchopGenome)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(vm.species.themeColor.opacity(0.12)))
                                    .foregroundColor(vm.species.themeColor)
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
                                    title: "选高分",
                                    tint: .green,
                                    help: "快速勾选序列启发式评分高 (★★★ / ★★) 的靶点",
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
                                        .foregroundColor(isChecked ? .cyan : .primary)
                                        .textSelection(.enabled)
                                    
                                    Spacer()
                                    
                                    if scoreRes.hasFatalIssue {
                                        Text("⚠️TTTT")
                                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(.red)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.red.opacity(0.12)))
                                            .help("该靶点含连续4个T，在U6启动子下转录提前终止")
                                    }

                                    Text("GC \(String(format: "%.0f", target.gcPercent))%")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .studioInnerBox(tint: isChecked ? .cyan : nil, isHighlighted: isChecked, paddingH: 8, paddingV: 5)
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

                TextField("20 bp 靶点 Spacer (不含 PAM)", text: $vm.customSequence)
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
