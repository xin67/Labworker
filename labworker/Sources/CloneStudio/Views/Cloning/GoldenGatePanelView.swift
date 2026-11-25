import SwiftUI
import AppKit
import CloneStudioCore

/// Type IIS Golden Gate 组装工作台面板（嵌入多片段克隆视图，调用 `GoldenGateEngine` 与 NEB T4 4-bp 保真度矩阵）
public struct GoldenGatePanelView: View {
    @ObservedObject var vm: MultiFragmentViewModel
    @ObservedObject private var appState = AppState.shared

    @State private var selectedEnzymeName: String = "BsaI"
    @State private var isCircular: Bool = true
    @State private var fixedOverhangsText: String = ""
    @State private var fragmentCodingFlags: [Int: Bool] = [:]
    @State private var fragmentFrameOffsets: [Int: Int] = [:]
    @State private var plan: GoldenGateEngine.GoldenGateAssemblyPlan? = nil

    private let enzymeOptions: [StudioMenuPickerOption<String>] = [
        StudioMenuPickerOption(value: "BsaI", title: "BsaI (GGTCTC · 4bp)"),
        StudioMenuPickerOption(value: "BsmBI", title: "BsmBI (CGTCTC · 4bp)"),
        StudioMenuPickerOption(value: "BbsI", title: "BbsI (GAAGAC · 4bp)"),
        StudioMenuPickerOption(value: "SapI", title: "SapI (GCTCTTC · 3bp)")
    ]

    public init(vm: MultiFragmentViewModel) {
        self.vm = vm
    }

    private var activeFragmentCount: Int {
        min(6, max(2, vm.fragments.count))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            configCard
            fragmentsDomesticationInputCard
            actionBarSection
            if let plan {
                planResultCard(plan)
            }
        }
    }

    private var configCard: some View {
        StudioCard(title: "Golden Gate (Type IIS) 组装参数") {
            StudioMetricBadge(label: "保真度矩阵", value: "NEB T4 (Potapov/Pryor)", color: .orange)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                    StudioMenuPicker(
                        selection: $selectedEnzymeName,
                        options: enzymeOptions,
                        prefix: "Type IIS 酶",
                        icon: "scissors",
                        tint: .orange,
                        help: "选择 Type IIS 外切内切酶"
                    )

                    Toggle("环状质粒组装", isOn: $isCircular)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    if vm.fragments.count > 6 {
                        StudioMetricBadge(
                            label: "提示",
                            value: "Golden Gate 支持 2–6 片段，当前将取前 6 段",
                            color: .orange
                        )
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("固定黏性末端 (可选):")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        TextField("逗号分隔，如 AATG, GCTT（留空则自动全局最优分配）", text: $fixedOverhangsText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("固定黏性末端 (可选):")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("逗号分隔，如 AATG, GCTT", text: $fixedOverhangsText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
        }
    }

    private var fragmentsDomesticationInputCard: some View {
        StudioCard(title: "待组装片段与 Domestication 设置 (\(activeFragmentCount) 段)") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                StudioActionPillButton(
                    title: "增加片段",
                    icon: "plus",
                    tint: .green,
                    isDisabled: vm.fragments.count >= 6,
                    action: vm.addFragment
                )
            }
        } content: {
            VStack(spacing: 10) {
                ForEach(0..<activeFragmentCount, id: \.self) { idx in
                    let cleanLen = BioSequence.clean(vm.fragments[idx]).count
                    let isCDS = fragmentCodingFlags[idx] ?? true
                    let frameOffset = fragmentFrameOffsets[idx] ?? 0

                    VStack(alignment: .leading, spacing: 6) {
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            Text(vm.fragmentNames[idx] ?? "片段 \(idx + 1)")
                                .font(.system(size: 12.5, weight: .bold))
                            StudioMetricBadge(
                                label: "长度",
                                value: "\(cleanLen) bp",
                                color: cleanLen >= 20 ? .green : .orange
                            )
                            Toggle("编码区 (同义抹除)", isOn: Binding(
                                get: { isCDS },
                                set: { fragmentCodingFlags[idx] = $0 }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)

                            if isCDS {
                                StudioMenuPicker(
                                    selection: Binding(
                                        get: { frameOffset },
                                        set: { fragmentFrameOffsets[idx] = $0 }
                                    ),
                                    options: [
                                        StudioMenuPickerOption(value: 0, title: "读框 +0"),
                                        StudioMenuPickerOption(value: 1, title: "读框 +1"),
                                        StudioMenuPickerOption(value: 2, title: "读框 +2")
                                    ],
                                    compact: true
                                )
                            }

                            if vm.fragments.count > 2 {
                                StudioCompactPillButton(title: "移除", icon: "minus.circle", tint: .red) {
                                    vm.removeFragment(at: idx)
                                }
                            }
                        }

                        SequenceEditorBox(
                            text: $vm.fragments[idx],
                            placeholder: "输入第 \(idx + 1) 个片段序列（>= 20 bp，自动扫描内源 \(selectedEnzymeName) 切点）...",
                            minHeight: 54
                        )
                    }
                    .studioInnerBox(paddingH: 10, paddingV: 8)
                }
            }
        }
    }

    private var actionBarSection: some View {
        StudioActionBar {
            StudioPrimaryActionButton(
                title: "规划 Golden Gate 组装",
                icon: "wand.and.stars",
                tint: .orange,
                action: runGoldenGateDesign
            )

            StudioActionPillButton(
                title: "载入示例",
                icon: "sparkles",
                help: "载入含内源 BsaI 切点的 3 片段 CDS 示范"
            ) {
                loadGoldenGateDemo()
            }

            if let plan, plan.totalInternalSitesFound > 0 {
                StudioActionPillButton(
                    title: "应用 Domesticated 序列",
                    icon: "checkmark.seal",
                    tint: .green,
                    help: "将同义抹除内源位点后的安全序列写回上方片段"
                ) {
                    applyDomesticatedSequences(plan)
                }
            }

            if let plan {
                StudioActionPillButton(
                    title: "复制方案",
                    icon: "doc.on.doc",
                    tint: .teal
                ) {
                    copyPlanSummary(plan)
                }
            }
        }
    }

    @ViewBuilder
    private func planResultCard(_ plan: GoldenGateEngine.GoldenGateAssemblyPlan) -> some View {
        let ovPlan = plan.overhangPlan
        StudioCard(title: "Golden Gate 组装方案与 Domestication 明细") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                StudioMetricBadge(
                    label: "组装保真度",
                    value: String(format: "%.1f%%", ovPlan.assemblyFidelity * 100.0),
                    color: ovPlan.assemblyFidelity >= 0.95 ? .green : .orange
                )
                StudioMetricBadge(
                    label: "跨错配",
                    value: "\(ovPlan.crossMismatchCount) 对",
                    color: ovPlan.crossMismatchCount == 0 ? .green : .red
                )
                StudioMetricBadge(
                    label: "内源位点",
                    value: "\(plan.totalInternalSitesFound) 个",
                    color: plan.totalInternalSitesFound == 0 ? .green : .orange
                )
                StudioMetricBadge(
                    label: "拼接总长",
                    value: "\(plan.assembledSequenceLength) bp",
                    color: .blue
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if !ovPlan.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ovPlan.warnings, id: \.self) { warn in
                            Label(warn, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioInnerBox(tint: .orange, paddingH: 10, paddingV: 8)
                }

                // 1. 高保真黏性末端串联拓扑
                VStack(alignment: .leading, spacing: 6) {
                    Text("高保真 \(plan.overhangLength)-bp 黏性末端顺序 (\(plan.enzymeName) · \(plan.recognitionSite))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)

                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(Array(ovPlan.assignedOverhangs.enumerated()), id: \.offset) { idx, ov in
                            StudioMetricBadge(
                                label: "J\(idx + 1)",
                                value: ov,
                                color: .orange
                            )
                            if idx < plan.domestications.count {
                                Text("→ \(plan.domestications[idx].fragmentName) →")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioInnerBox(tint: .orange, paddingH: 10, paddingV: 9)

                // 2. 各片段 Domestication 详情
                VStack(alignment: .leading, spacing: 8) {
                    Text("片段内源 \(plan.enzymeName) 位点扫描与同义密码子抹除 (Domestication)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)

                    ForEach(plan.domestications, id: \.fragmentIndex) { dom in
                        VStack(alignment: .leading, spacing: 6) {
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                                Text(dom.fragmentName)
                                    .font(.system(size: 12.5, weight: .bold))
                                StudioMetricBadge(label: "长度", value: "\(dom.originalLength) bp", color: .blue)
                                StudioMetricBadge(
                                    label: "检出位点",
                                    value: "\(dom.internalSitesFound)",
                                    color: dom.internalSitesFound == 0 ? .green : .orange
                                )
                                StudioMetricBadge(
                                    label: "抹除后剩余",
                                    value: "\(dom.remainingSitesAfterDomestication)",
                                    color: dom.remainingSitesAfterDomestication == 0 ? .green : .red
                                )
                            }

                            if dom.suggestions.isEmpty {
                                Text("未检出内源 \(plan.enzymeName) 识别序列，可直接用于 Golden Gate 反应。")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(dom.suggestions.enumerated()), id: \.offset) { _, sug in
                                    VStack(alignment: .leading, spacing: 3) {
                                        StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                                            StudioMetricBadge(
                                                label: "\(sug.siteStrand)链",
                                                value: "\(sug.siteStart1Based)..\(sug.siteEnd1Based) bp",
                                                color: .purple
                                            )
                                            if let origC = sug.originalCodon, let mutC = sug.mutatedCodon, let aa = sug.aminoAcid {
                                                StudioMetricBadge(
                                                    label: "密码子",
                                                    value: "\(origC) → \(mutC) (\(aa))",
                                                    color: sug.isSynonymous ? .green : .orange
                                                )
                                            }
                                            StudioMetricBadge(
                                                label: "突变",
                                                value: "@\(sug.mutationPosition1Based) \(sug.originalBase)→\(sug.mutatedBase)",
                                                color: .teal
                                            )
                                        }
                                        Text(sug.note)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .studioInnerBox(paddingH: 8, paddingV: 6)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .studioInnerBox(paddingH: 10, paddingV: 8)
                    }
                }
            }
        }
    }

    private func runGoldenGateDesign() {
        let count = activeFragmentCount
        var inputs: [GoldenGateEngine.GoldenGateFragmentInput] = []
        for idx in 0..<count {
            let clean = BioSequence.clean(vm.fragments[idx])
            guard clean.count >= 20 else {
                vm.alertMessage = "第 \(idx + 1) 个片段有效序列长度不足 20 bp，请补充序列或点击「载入示例」。"
                vm.showAlert = true
                return
            }
            let name = (vm.fragmentNames[idx]?.isEmpty == false) ? vm.fragmentNames[idx]! : "Frag\(idx + 1)"
            inputs.append(
                GoldenGateEngine.GoldenGateFragmentInput(
                    name: name,
                    sequence: clean,
                    isCodingSequence: fragmentCodingFlags[idx] ?? true,
                    readingFrameOffset: fragmentFrameOffsets[idx] ?? 0
                )
            )
        }

        let fixed = fixedOverhangsText
            .components(separatedBy: CharacterSet(charactersIn: ",; \n\t"))
            .map { BioSequence.clean($0) }
            .filter { !$0.isEmpty }

        let result = GoldenGateEngine.designAssembly(
            fragments: inputs,
            enzymeName: selectedEnzymeName,
            fixedOverhangs: fixed,
            isCircular: isCircular
        )
        self.plan = result
        appState.showToast(
            String(
                format: "已完成 %@ Golden Gate 规划：保真度 %.1f%%，抹除 %d 处内源位点",
                result.enzymeName,
                result.overhangPlan.assemblyFidelity * 100.0,
                result.totalInternalSitesFound
            )
        )
    }

    private func applyDomesticatedSequences(_ plan: GoldenGateEngine.GoldenGateAssemblyPlan) {
        for dom in plan.domestications where dom.fragmentIndex < vm.fragments.count {
            vm.fragments[dom.fragmentIndex] = dom.domesticatedSequence
        }
        runGoldenGateDesign()
        appState.showToast("已将同义抹除后的 Domesticated 序列应用到各片段")
    }

    private func loadGoldenGateDemo() {
        selectedEnzymeName = "BsaI"
        isCircular = true
        fixedOverhangsText = ""
        // 含内源 GGTCTC (BsaI) 位点的真实编码密码子示范片段
        vm.fragments = [
            "ATGGTGAGCAAGGGTCTCCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAAC",
            "GGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTC",
            "ATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAG"
        ]
        vm.fragmentNames = [0: "EGFP-N", 1: "EGFP-Mid", 2: "EGFP-C"]
        fragmentCodingFlags = [0: true, 1: true, 2: true]
        fragmentFrameOffsets = [0: 0, 1: 0, 2: 0]
        runGoldenGateDesign()
    }

    private func copyPlanSummary(_ plan: GoldenGateEngine.GoldenGateAssemblyPlan) {
        var lines: [String] = []
        lines.append("Labworker Golden Gate Assembly Plan (\(plan.enzymeName) / \(plan.recognitionSite))")
        lines.append(String(format: "Fidelity: %.2f%% | Cross-mismatches: %d | Length: %d bp", plan.overhangPlan.assemblyFidelity * 100.0, plan.overhangPlan.crossMismatchCount, plan.assembledSequenceLength))
        lines.append("Overhangs: " + plan.overhangPlan.assignedOverhangs.joined(separator: " - "))
        for dom in plan.domestications {
            lines.append("[\(dom.fragmentName)] \(dom.originalLength) bp, internal sites: \(dom.internalSitesFound) -> remaining: \(dom.remainingSitesAfterDomestication)")
            for s in dom.suggestions {
                lines.append("  - \(s.note)")
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        appState.showToast("已复制 Golden Gate 组装方案到剪贴板")
    }
}
