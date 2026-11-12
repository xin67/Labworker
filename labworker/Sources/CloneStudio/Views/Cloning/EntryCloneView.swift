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
        StudioPageLayout(title: "入门克隆") {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                PlasmidPreviewToggle(isOn: $appState.showPlasmidPreview, isAvailable: previewData != nil)
                
                StudioSegmentedPillGroup(items: [
                    StudioPillGroupItem(title: "导入序列", icon: "folder.badge.plus") {
                        FinderFileDropHelper.presentOpenPanel { url in
                            Task { @MainActor in
                                await FinderFileDropHelper.loadSequence(from: url) { seq, name in
                                    vm.sequence = seq
                                    AppState.shared.showToast("已导入 \(name) (\(seq.count) bp)")
                                }
                            }
                        }
                    },
                    StudioPillGroupItem(title: "送入用量计算", icon: "function", tint: .purple) {
                        vm.sendLengthsToCalculator(navigate: true)
                    },
                    StudioPillGroupItem(title: "示例", icon: "sparkles") {
                        loadSampleEGFP()
                    },
                    StudioPillGroupItem(
                        title: "清空",
                        icon: "trash",
                        tint: .red,
                        isDisabled: vm.sequence.isEmpty && !vm.hasEnzymes && vm.primerF == nil && vm.primerR == nil,
                        action: vm.clear
                    )
                ])
            }
        } content: {
            AdaptiveTwoColumnWorkspace(hasRight: previewData != nil && appState.showPlasmidPreview) {
                VStack(alignment: .leading, spacing: 14) {
                    StudioCard(title: "插入片段与载体长度") {
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            StudioActionPillButton(
                                title: "送入用量计算",
                                icon: "function",
                                tint: .purple
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
                                    label: "pCE2 载体",
                                    value: "3957 bp (3.96 kb)",
                                    color: .blue
                                )
                                StudioMetricBadge(
                                    label: "插入基因",
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
                                placeholder: "输入或拖入插入片段序列 (≥ 50 bp)",
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
                                            Text("5' 位点:")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            enzymePicker(selection: $vm.enzyme5)
                                        }
                                        HStack(spacing: 8) {
                                            Text("3' 位点:")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            enzymePicker(selection: $vm.enzyme3)
                                        }
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 8) {
                                            Text("5' 位点:")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            enzymePicker(selection: $vm.enzyme5)
                                        }
                                        HStack(spacing: 8) {
                                            Text("3' 位点:")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            enzymePicker(selection: $vm.enzyme3)
                                        }
                                    }
                                }
                            } else {
                                HStack(spacing: 8) {
                                    StudioMetricBadge(label: "5' 接头", value: "URS (15 bp)", color: .cyan)
                                    StudioMetricBadge(label: "3' 接头", value: "DRS (15 bp)", color: .cyan)
                                    Spacer()
                                }
                            }
                        }
                        
                        // 图2风格对称全宽主操作按钮行
                        HStack(spacing: 10) {
                            StudioPrimaryActionButton(
                                title: "设计入门克隆引物",
                                icon: "sparkles",
                                tint: .blue,
                                isLoading: vm.isDesigning,
                                isDisabled: vm.cleanLength < 50,
                                fillWidth: true
                            ) {
                                Task { await vm.design() }
                            }
                            
                            if vm.primerF != nil || vm.primerR != nil {
                                StudioPrimaryActionButton(
                                    title: "加入引物池",
                                    icon: "cart.badge.plus",
                                    tint: .green,
                                    fillWidth: true,
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
                    }
                } right: {
                    if let pData = previewData {
                        PlasmidPreviewPanel(data: pData, onClose: {
                            appState.showPlasmidPreview = false
                        })
                    }
                }
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
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
}
