import CloneStudioCore
import SwiftUI

/// 入门克隆引物设计界面（参考图2层次化胶囊按钮排版 + 放大清晰字号）
public struct EntryCloneView: View {
    @ObservedObject private var vm = WorkspaceSessionManager.shared.entryCloneVM
    @ObservedObject private var appState = AppState.shared
    
    public init() {}
    
    private var previewData: PlasmidConstructPreviewData? {
        PlasmidMapBuilder.forEntryClone(
            insertSeq: vm.sequence,
            hasEnzymes: vm.hasEnzymes,
            enzyme5: vm.enzyme5,
            enzyme3: vm.enzyme3,
            primerF: vm.primerF,
            primerR: vm.primerR
        )
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "入门克隆",
            toolbar: [
                .plasmidToggle(isOn: $appState.showPlasmidPreview, isAvailable: previewData != nil),
                .action(title: "导入", icon: "folder.badge.plus", help: "导入 FASTA / .dna / 文本序列") {
                    FinderFileDropHelper.presentOpenPanel { url in
                        Task { @MainActor in
                            await FinderFileDropHelper.loadSequence(from: url) { seq, name in
                                vm.sequence = seq
                                AppState.shared.showToast(L10n.tr("已导入 \(name) (\(seq.count) bp)", "Imported \(name) (\(seq.count) bp)"))
                            }
                        }
                    }
                },
                .action(title: "算用量", icon: "function", tint: .purple, help: "将载体与片段长度送入体系用量计算") {
                    vm.sendLengthsToCalculator(navigate: true)
                },
                .action(title: "电泳模拟", icon: "chart.bar.doc.horizontal", tint: .blue, help: "在独立窗口放大检视入门克隆 PCR 模拟电泳") {
                    GelSimulationWindowPresenter.shared.openWindow(
                        title: "入门克隆 PCR 模拟电泳",
                        accentTint: .blue,
                        compareLaneTitle: "显示 pCE2+PCR 混合对照",
                        buildSimulation: entryGelSimulation
                    )
                },
                .action(title: "示例", icon: "sparkles", help: "载入 EGFP 标准示例序列", action: loadSampleEGFP),
                .action(
                    id: "clear_entry",
                    title: "",
                    icon: "trash",
                    tint: .red,
                    isDisabled: vm.sequence.isEmpty && !vm.hasEnzymes && vm.primerF == nil && vm.primerR == nil,
                    help: "清空当前入门克隆配置",
                    action: vm.clear
                )
            ]
        ) {
            AdaptiveTwoColumnWorkspace(hasRight: previewData != nil && appState.showPlasmidPreview) {
                VStack(alignment: .leading, spacing: 14) {
                    StudioCard(title: "插入片段与载体长度") {
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            StudioActionPillButton(
                                title: "算用量",
                                icon: "function",
                                tint: .purple,
                                help: "将载体与片段长度送入体系用量计算"
                            ) {
                                vm.sendLengthsToCalculator(navigate: true)
                            }
                            StudioSectionClearButton(
                                title: "清除",
                                isDisabled: vm.sequence.isEmpty,
                                action: vm.clearSequenceSection
                            )
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 10) {
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                StudioMetricBadge(
                                    label: L10n.t("pCE2 载体"),
                                    value: "3957 bp (3.96 kb)",
                                    color: .blue
                                )
                                StudioMetricBadge(
                                    label: L10n.t("插入基因"),
                                    value: "\(vm.cleanLength) bp (\(String(format: "%.2f", Double(vm.cleanLength) / 1000.0)) kb)",
                                    color: vm.cleanLength >= 50 ? .green : .orange
                                )
                                if vm.cleanLength > 0 {
                                    StudioMetricBadge(
                                        label: "GC",
                                        value: "\(String(format: "%.0f", BioSequence.gcContent(vm.sequence)))%",
                                        color: .purple
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            SequenceEditorBox(
                                text: $vm.sequence,
                                placeholder: L10n.t("输入或拖入插入片段序列 (≥ 50 bp)"),
                                minHeight: 115
                            )
                        }
                    }
                        
                        StudioCard(title: "酶切位点") {
                            StudioSegmentedPicker(
                                selection: $vm.hasEnzymes,
                                options: [
                                    StudioSegmentedOption(value: false, title: "URS / DRS 通用接头", tint: .cyan),
                                    StudioSegmentedOption(value: true, title: "双酶切位点", tint: .blue)
                                ]
                            )
                        } content: {
                            if vm.hasEnzymes {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 14) {
                                        HStack(spacing: 8) {
                                            Text(L10n.t("5' 位点:"))
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            enzymePicker(selection: $vm.enzyme5)
                                        }
                                        HStack(spacing: 8) {
                                            Text(L10n.t("3' 位点:"))
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            enzymePicker(selection: $vm.enzyme3)
                                        }
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 8) {
                                            Text(L10n.t("5' 位点:"))
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            enzymePicker(selection: $vm.enzyme5)
                                        }
                                        HStack(spacing: 8) {
                                            Text(L10n.t("3' 位点:"))
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            enzymePicker(selection: $vm.enzyme3)
                                        }
                                    }
                                }
                            } else {
                                HStack(spacing: 8) {
                                    StudioMetricBadge(label: L10n.t("5' 接头"), value: "URS (15 bp)", color: .cyan)
                                    StudioMetricBadge(label: L10n.t("3' 接头"), value: "DRS (15 bp)", color: .cyan)
                                    Spacer()
                                }
                            }
                        }
                        
                        // 居左紧凑主操作栏（Plan A）
                        StudioActionBar(statusText: vm.cleanLength < 50 ? "输入 ≥ 50 bp 插入序列后可设计" : nil) {
                            StudioPrimaryActionButton(
                                title: "设计入门克隆引物",
                                icon: "sparkles",
                                tint: .blue,
                                isLoading: vm.isDesigning,
                                isDisabled: vm.cleanLength < 50
                            ) {
                                Task { await vm.design() }
                            }
                            
                            if vm.primerF != nil || vm.primerR != nil {
                                StudioActionPillButton(
                                    title: "加入引物池",
                                    icon: "cart.badge.plus",
                                    tint: .green,
                                    action: vm.addAllToCart
                                )
                            }
                        }
                        
                        if let primerF = vm.primerF, let primerR = vm.primerR {
                            StudioCard(title: "设计结果") {
                                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                    StudioMetricBadge(label: "", value: "2 条引物", color: .green)
                                    StudioSectionClearButton(
                                        title: "清除",
                                        action: vm.clearPrimersSection
                                    )
                                }
                            } content: {
                                VStack(spacing: 10) {
                                    PrimerPairQuickRenameBar(
                                        pairTitle: "引物前缀",
                                        currentForwardName: primerF.name,
                                        currentReverseName: primerR.name,
                                        suggestedPrefix: "CE-Entry",
                                        onApplyPrefix: { prefix in
                                            vm.renamePrimerPair(prefix: prefix)
                                        }
                                    )
                                    PrimerPairDimerSummaryBar(
                                        forwardPrimer: primerF,
                                        reversePrimer: primerR
                                    )
                                    
                                    PrimerCardView(
                                        primer: primerF,
                                        partnerPrimer: primerR,
                                        onPairedRename: { prefix in vm.renamePrimerPair(prefix: prefix) },
                                        onSingleRename: { newName in vm.renameSinglePrimer(isForward: true, newName: newName) }
                                    )
                                    PrimerCardView(
                                        primer: primerR,
                                        partnerPrimer: primerF,
                                        onPairedRename: { prefix in vm.renamePrimerPair(prefix: prefix) },
                                        onSingleRename: { newName in vm.renameSinglePrimer(isForward: false, newName: newName) }
                                    )
                                }
                            }
                        }

                        // 入门克隆 PCR 凝胶电泳模拟
                        HomologousPCRGelSectionCard(
                            title: "入门克隆 PCR 凝胶电泳模拟",
                            accentTint: .blue,
                            compareLaneTitle: "显示 pCE2+PCR 混合对照",
                            buildSimulation: entryGelSimulation
                        )
                    }
                } right: {
                    if let pData = previewData {
                        PlasmidPreviewPanel(data: pData, onClose: {
                            appState.showPlasmidPreview = false
                        })
                    }
                }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage ?? "")
        }
    }
    
    private func enzymePicker(selection: Binding<RestrictionEnzyme?>) -> some View {
        Picker("", selection: selection) {
            ForEach(RestrictionEnzymeDatabase.shared.enzymes) { enzyme in
                Text("\(enzyme.name) (\(enzyme.site))")
                    .tag(Optional(enzyme))
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
    
    private func loadSampleEGFP() {
        let codons = [
            "ATG", "GTG", "AGC", "AAG", "GGC", "GAG", "GAG", "CTG", "TTC", "ACC",
            "GGG", "GTG", "GTG", "CCC", "ATC", "CTG", "GTC", "GAG", "CTG", "GAC",
            "GGC", "GAC", "GTA", "AAC", "GGC", "CAC", "AAG", "TTC", "AGC", "GTG"
        ]
        vm.sequence = Array(repeating: codons.joined(), count: 8).joined() + "TAA"
    }

    private func entryGelSimulation(
        concOverride: AgaroseGelConcentration?,
        ladderOverride: String?,
        includeMixLane: Bool
    ) -> HomologousPCRGelSimulationResult {
        HomologousPCRGelSimulator.simulateEntryClone(
            cleanInsertLengthBp: vm.cleanLength,
            hasEnzymes: vm.hasEnzymes,
            enzyme5: vm.enzyme5,
            enzyme3: vm.enzyme3,
            primerF: vm.primerF,
            primerR: vm.primerR,
            vectorLengthBp: vm.vectorLengthBp,
            concentrationOverride: concOverride,
            ladderIDOverride: ladderOverride,
            includeMixControlLane: includeMixLane
        )
    }
}
