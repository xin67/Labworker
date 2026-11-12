import CloneStudioCore
import SwiftUI

/// DNA 序列处理与引物 Tm 测算工具箱（参考图2层次化胶囊按钮组 + 清晰大字号）
public struct SequenceToolsView: View {
    @ObservedObject private var vm = WorkspaceSessionManager.shared.sequenceToolVM
    
    public init() {}
    
    public var body: some View {
        StudioPageLayout(title: "序列工具与 Tm 测算") {
            StudioSectionClearButton(
                title: "清空",
                isDisabled: vm.inputSeq.isEmpty && vm.outputSeq.isEmpty && vm.tmResult == nil
            ) {
                vm.inputSeq = ""
                vm.outputSeq = ""
                vm.tmResult = nil
            }
        } content: {
                
                StudioCard(title: "输入序列 (5' → 3')") {
                    HStack(spacing: 8) {
                        StudioMetricBadge(label: "长度", value: "\(vm.cleanLength) bp", color: .blue)
                        StudioMetricBadge(label: "GC", value: "\(String(format: "%.0f", vm.cleanGC))%", color: .purple)
                    }
                } content: {
                    VStack(alignment: .leading, spacing: 12) {
                        SequenceEditorBox(
                            text: $vm.inputSeq,
                            placeholder: "输入或粘贴 DNA 序列",
                            minHeight: 100
                        )
                        
                        // 图2风格：第一层对称分段转换胶囊组 + 第二层醒目全宽测算按钮
                        HStack(spacing: 10) {
                            StudioSegmentedPillGroup(
                                items: [
                                    StudioPillGroupItem(title: "反向互补", icon: "arrow.left.arrow.right", tint: .blue, action: vm.doReverseComplement),
                                    StudioPillGroupItem(title: "仅反向", icon: "arrow.uturn.backward", action: vm.doReverse),
                                    StudioPillGroupItem(title: "仅互补", icon: "arrow.up.arrow.down", action: vm.doComplement)
                                ],
                                expandEqually: true
                            )
                            
                            StudioPrimaryActionButton(
                                title: vm.isCalculating ? "计算中..." : "测算解链温度 (Tm)",
                                icon: "thermometer.medium",
                                tint: .orange,
                                isLoading: vm.isCalculating,
                                isDisabled: vm.cleanLength == 0,
                                fillWidth: true
                            ) {
                                Task { await vm.calculateTm() }
                            }
                        }
                    }
                }
                
                if let tm = vm.tmResult {
                    StudioCard(title: "Tm 与二级结构热力学评估 (SantaLucia + primer3)") {
                        EmptyView()
                    } content: {
                        VStack(alignment: .leading, spacing: 10) {
                            StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 6) {
                                StudioMetricBadge(label: "长度", value: "\(tm.length) bp", color: .blue)
                                StudioMetricBadge(label: "GC 含量", value: "\(String(format: "%.1f", tm.gcPercent))%", color: .purple)
                                StudioMetricBadge(label: "解链温度 Tm", value: "\(String(format: "%.1f", tm.tm)) ℃", color: .red)
                                StudioMetricBadge(label: "推荐退火 Ta", value: "\(String(format: "%.1f", tm.recommendedTa)) ℃", color: .green)
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
                            .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(8)
                    }
                }
        }
    }
}
