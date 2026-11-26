import CloneStudioCore
import SwiftUI

/// DNA 序列处理、引物 Tm 测算与宿主密码子约束优化工作台
public struct SequenceToolsView: View {
    private enum SequenceToolMode: String, CaseIterable {
        case basicAndTm = "序列转换与 Tm 测算"
        case codonOptimization = "密码子与合成优化"
    }

    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject private var vm = WorkspaceSessionManager.shared.sequenceToolVM
    @State private var toolMode: SequenceToolMode = .basicAndTm

    public init() {}

    public var body: some View {
        let _ = appLanguage
        StudioPageLayout(
            title: "序列工具与 Tm 测算",
            toolbar: [
                .action(
                    id: "clear_seqtools",
                    groupKey: nil,
                    title: "",
                    icon: "trash",
                    tint: .red,
                    isDisabled: toolMode == .basicAndTm && vm.inputSeq.isEmpty && vm.outputSeq.isEmpty && vm.tmResult == nil,
                    help: "清空序列工具输入与计算结果"
                ) {
                    vm.inputSeq = ""
                    vm.outputSeq = ""
                    vm.tmResult = nil
                }
            ]
        ) {
                StudioSegmentedPicker(
                    selection: $toolMode,
                    options: [
                        StudioSegmentedOption(value: SequenceToolMode.basicAndTm, title: SequenceToolMode.basicAndTm.rawValue, tint: .blue),
                        StudioSegmentedOption(value: SequenceToolMode.codonOptimization, title: SequenceToolMode.codonOptimization.rawValue, tint: .mint)
                    ]
                )

                if toolMode == .codonOptimization {
                    CodonOptimizationPanelView()
                } else {
                StudioCard(title: "输入序列 (5' → 3')") {
                    HStack(spacing: 8) {
                        StudioMetricBadge(label: L10n.t("长度"), value: "\(vm.cleanLength) bp", color: .blue)
                        StudioMetricBadge(label: "GC", value: "\(String(format: "%.0f", vm.cleanGC))%", color: .purple)
                    }
                } content: {
                    VStack(alignment: .leading, spacing: 12) {
                        SequenceEditorBox(
                            text: $vm.inputSeq,
                            placeholder: L10n.t("输入或粘贴 DNA 序列"),
                            minHeight: 100
                        )
                        
                        // 居左紧凑操作栏（测算主按钮 + 序列转换分段胶囊组）
                        StudioActionBar {
                            StudioPrimaryActionButton(
                                title: vm.isCalculating ? "计算中..." : "测算解链温度 (Tm)",
                                icon: "thermometer.medium",
                                tint: .orange,
                                isLoading: vm.isCalculating,
                                isDisabled: vm.cleanLength == 0
                            ) {
                                Task { await vm.calculateTm() }
                            }
                            
                            StudioSegmentedPillGroup(
                                items: [
                                    StudioPillGroupItem(title: "反向互补", icon: "arrow.left.arrow.right", tint: .blue, action: vm.doReverseComplement),
                                    StudioPillGroupItem(title: "仅反向", icon: "arrow.uturn.backward", action: vm.doReverse),
                                    StudioPillGroupItem(title: "仅互补", icon: "arrow.up.arrow.down", action: vm.doComplement)
                                ]
                            )
                        }
                    }
                }
                
                if let tm = vm.tmResult {
                    StudioCard(title: "Tm 与二级结构热力学评估 (SantaLucia + primer3)") {
                        EmptyView()
                    } content: {
                        VStack(alignment: .leading, spacing: 10) {
                            StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 6) {
                                StudioMetricBadge(label: L10n.t("长度"), value: "\(tm.length) bp", color: .blue)
                                StudioMetricBadge(label: L10n.t("GC 含量"), value: "\(String(format: "%.1f", tm.gcPercent))%", color: .purple)
                                StudioMetricBadge(label: L10n.t("解链温度 Tm"), value: "\(String(format: "%.1f", tm.tm)) ℃", color: .red)
                                StudioMetricBadge(label: L10n.t("推荐退火 Ta"), value: "\(String(format: "%.1f", tm.recommendedTa)) ℃", color: .green)
                            }
                            PrimerCardView(
                                primer: PrimerItem(
                                    name: "Query-Oligo",
                                    fullSequence: vm.inputSeq,
                                    specificSequence: vm.inputSeq,
                                    tm: tm.tm,
                                    gcPercent: tm.gcPercent,
                                    targetPurpose: "序列工具单链热力学与二级结构评估"
                                )
                            )
                        }
                    }
                }
                
                if !vm.outputSeq.isEmpty {
                    StudioCard(title: "转换结果") {
                        StudioActionPillButton(title: "复制结果", icon: "doc.on.doc", tint: .blue, action: vm.copyOutput)
                    } content: {
                        Text(vm.outputSeq)
                            .font(.system(size: 13.5, weight: .medium))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .studioInnerBox(paddingH: 10, paddingV: 10)
                    }
                }
                }
        }
    }
}
