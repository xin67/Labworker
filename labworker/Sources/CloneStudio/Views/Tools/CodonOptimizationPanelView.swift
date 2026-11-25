import SwiftUI
import Charts
import AppKit
import CloneStudioCore

/// 宿主密码子优化与多约束序列求解工作台（嵌入序列工具视图）
public struct CodonOptimizationPanelView: View {
    @ObservedObject private var appState = AppState.shared

    @State private var rawInput: String = CodonOptimizationEngine.demoEGFPFragmentDNA
    @State private var isProteinMode: Bool = false
    @State private var host: CodonHostOrganism = .human
    @State private var preset: SynthesisVendorPreset = .twist
    @State private var forbiddenEnzymes: Set<String> = Set(CodonOptimizationEngine.defaultForbiddenEnzymes)
    @State private var customForbiddenText: String = ""
    @State private var minWindowGC: Double = 35
    @State private var maxWindowGC: Double = 65
    @State private var maxHomopolymer: Int = 5
    @State private var maxRepeatLen: Int = 10
    @State private var optimizeFivePrime: Bool = true
    @State private var report: CodonOptimizationEngine.OptimizationReport? = nil

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            inputAndConstraintsCard
            actionBar
            if let rep = report {
                metricsSummaryCard(rep)
                gcComparisonChartCard(rep)
                constraintsChecklistCard(rep)
                optimizedOutputCard(rep)
            }
        }
        .onAppear {
            if report == nil {
                runOptimization()
            }
        }
    }

    private var inputAndConstraintsCard: some View {
        StudioCard(title: "待优化序列与多约束求解条件 (DnaChisel / poly 风格)") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                StudioCompactPillButton(title: "DNA 示例 (EGFP)", icon: "sparkles", tint: .blue) {
                    isProteinMode = false
                    rawInput = CodonOptimizationEngine.demoEGFPFragmentDNA
                    runOptimization()
                }
                StudioCompactPillButton(title: "蛋白输入模式", icon: "atom", tint: isProteinMode ? .purple : nil, isSelected: isProteinMode) {
                    isProteinMode.toggle()
                    if isProteinMode && rawInput == CodonOptimizationEngine.demoEGFPFragmentDNA {
                        rawInput = CodonOptimizationEngine.translateDNA(CodonOptimizationEngine.demoEGFPFragmentDNA)
                    } else if !isProteinMode && !rawInput.uppercased().contains("ATGGTGAGCAAG") {
                        rawInput = CodonOptimizationEngine.demoEGFPFragmentDNA
                    }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                SequenceEditorBox(
                    text: $rawInput,
                    placeholder: isProteinMode ? "输入氨基酸序列（如 MVSKGEELFT...）" : "输入或粘贴 DNA 编码区序列（5' → 3' CDS，自动按 3 bp 阅读框翻译保持蛋白 100% 不变）",
                    minHeight: 88
                )

                // 宿主与合成商预设
                StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                    StudioMenuPicker(
                        selection: $host,
                        options: CodonHostOrganism.allCases.map { StudioMenuPickerOption(value: $0, title: $0.title) },
                        prefix: "表达宿主",
                        icon: "cpu",
                        tint: .mint,
                        compact: true
                    )

                    StudioMenuPicker(
                        selection: Binding(
                            get: { preset },
                            set: { applyVendorPreset($0) }
                        ),
                        options: SynthesisVendorPreset.allCases.map { StudioMenuPickerOption(value: $0, title: $0.rawValue) },
                        prefix: "合成规范",
                        icon: "checkmark.shield",
                        tint: .blue,
                        compact: true
                    )

                    Toggle("优化 5' 前 45bp 发夹 (ΔG ≥ -3.0)", isOn: $optimizeFivePrime)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5, weight: .medium))
                }

                // 禁用酶切位点切换
                VStack(alignment: .leading, spacing: 6) {
                    Text("自动规避禁区酶切位点 (正向与反向互补均检测):")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(CodonOptimizationEngine.selectableEnzymes, id: \.self) { enz in
                            let on = forbiddenEnzymes.contains(enz)
                            StudioCompactPillButton(
                                title: enz,
                                icon: on ? "checkmark.circle.fill" : "circle",
                                tint: on ? .orange : .secondary,
                                isSelected: on
                            ) {
                                if on { forbiddenEnzymes.remove(enz) } else { forbiddenEnzymes.insert(enz) }
                                preset = .custom
                            }
                        }
                    }
                }

                // 滑动窗 GC% 与同聚物 / 自定义禁忌序列
                StudioFlowLayout(horizontalSpacing: 14, verticalSpacing: 8) {
                    HStack(spacing: 6) {
                        Text("50bp 窗 GC 下限")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Stepper("\(Int(minWindowGC))%", value: $minWindowGC, in: 20...50, step: 5)
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        Text("上限")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Stepper("\(Int(maxWindowGC))%", value: $maxWindowGC, in: 55...80, step: 5)
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        Text("同聚物阈值")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Stepper("<\(maxHomopolymer) bp", value: $maxHomopolymer, in: 4...9)
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        Text("重复子串阈值")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Stepper("<\(maxRepeatLen) bp", value: $maxRepeatLen, in: 8...18)
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                    }
                }

                HStack(spacing: 8) {
                    Text("额外禁用 Motif (逗号分隔):")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("例如 ATTAAA, GCCACC", text: $customForbiddenText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: 260)
                }
            }
        }
    }

    private var actionBar: some View {
        StudioActionBar(statusText: report.map { "蛋白长度 \($0.proteinSequence.count) aa · 修改 \($0.codonChangesCount) 处同义密码子" }) {
            StudioPrimaryActionButton(
                title: "执行多约束密码子优化",
                icon: "wand.and.stars",
                tint: .mint,
                isDisabled: rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: runOptimization
            )

            if let rep = report, !rep.optimizedDNA.isEmpty {
                StudioActionPillButton(title: "复制优化序列", icon: "doc.on.doc", tint: .blue) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rep.optimizedDNA, forType: .string)
                    appState.showToast("已复制 \(rep.lengthBp) bp 优化 DNA 序列")
                }

                StudioActionPillButton(title: "导出 FASTA", icon: "square.and.arrow.up", tint: .teal) {
                    let fasta = ">CodonOptimized_\(rep.host.shortTitle)_\(rep.lengthBp)bp_CAI_\(String(format: "%.3f", rep.optimizedCAI))\n\(rep.optimizedDNA)\n"
                    FinderFileDropHelper.saveTextToFile(
                        content: fasta,
                        defaultFileName: "Optimized_\(rep.host.shortTitle).fasta",
                        contentType: .plainText,
                        toastPrefix: "已导出优化后 FASTA"
                    )
                }

                StudioActionPillButton(title: "送入单片段克隆", icon: "arrow.up.right.square", tint: .purple) {
                    let sf = WorkspaceSessionManager.shared.singleFragmentVM
                    sf.insertSeq = rep.optimizedDNA
                    sf.insertGeneName = "Opt_\(rep.host.shortTitle)"
                    appState.selectedNav = .singleFragment
                    appState.showToast("已将优化序列送入「单片段克隆」插入片段区")
                }
            }
        }
    }

    private func metricsSummaryCard(_ rep: CodonOptimizationEngine.OptimizationReport) -> some View {
        StudioCard(title: "密码子适应度 (CAI) 与合成合规概览") {
            StudioMetricBadge(
                label: "合成就绪",
                value: rep.isSynthesisReady ? "全部约束通过" : "存在局部残留",
                color: rep.isSynthesisReady ? .green : .orange
            )
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    if let c0 = rep.originalCAI {
                        StudioMetricBadge(label: "CAI (优化前→后)", value: String(format: "%.3f → %.3f", c0, rep.optimizedCAI), color: .mint)
                    } else {
                        StudioMetricBadge(label: "优化后 CAI", value: String(format: "%.3f", rep.optimizedCAI), color: .mint)
                    }
                    if let g0 = rep.originalGCPercent {
                        StudioMetricBadge(label: "总 GC%", value: String(format: "%.1f%% → %.1f%%", g0, rep.optimizedGCPercent), color: .blue)
                    } else {
                        StudioMetricBadge(label: "总 GC%", value: String(format: "%.1f%%", rep.optimizedGCPercent), color: .blue)
                    }
                    if let dg0 = rep.originalFivePrimeDG {
                        StudioMetricBadge(label: "5' 发夹 ΔG", value: String(format: "%.2f → %.2f", dg0, rep.optimizedFivePrimeDG), color: rep.optimizedFivePrimeDG >= -3.0 ? .green : .orange)
                    } else {
                        StudioMetricBadge(label: "5' 发夹 ΔG", value: String(format: "%.2f kcal/mol", rep.optimizedFivePrimeDG), color: rep.optimizedFivePrimeDG >= -3.0 ? .green : .orange)
                    }
                    StudioMetricBadge(label: "蛋白一致性", value: "100.0% 守恒", color: .purple)
                }

                ForEach(rep.notices, id: \.self) { note in
                    Text("• \(note)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func gcComparisonChartCard(_ rep: CodonOptimizationEngine.OptimizationReport) -> some View {
        StudioCard(title: "50 bp 滑动窗局部 GC% 分布对比 (参考区间 \(Int(minWindowGC))%–\(Int(maxWindowGC))%)") {
            if rep.gcProfileAfter.isEmpty {
                Text("序列较短，无多窗口剖面")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    RuleMark(y: .value("上限", maxWindowGC))
                        .foregroundStyle(.orange.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    RuleMark(y: .value("下限", minWindowGC))
                        .foregroundStyle(.orange.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    ForEach(rep.gcProfileBefore) { pt in
                        LineMark(
                            x: .value("位置 (bp)", pt.centerBp),
                            y: .value("GC%", pt.gcPercent),
                            series: .value("序列", "优化前")
                        )
                        .foregroundStyle(Color.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    }

                    ForEach(rep.gcProfileAfter) { pt in
                        LineMark(
                            x: .value("位置 (bp)", pt.centerBp),
                            y: .value("GC%", pt.gcPercent),
                            series: .value("序列", "优化后")
                        )
                        .foregroundStyle(Color.mint)
                        .lineStyle(StrokeStyle(lineWidth: 2.2))
                    }
                }
                .chartYScale(domain: 10...90)
                .chartXAxisLabel("核苷酸坐标 (bp)")
                .chartYAxisLabel("局部 GC (%)")
                .frame(height: 190)
            }
        }
    }

    private func constraintsChecklistCard(_ rep: CodonOptimizationEngine.OptimizationReport) -> some View {
        StudioCard(title: "合成规则与序列约束核查明细") {
            VStack(spacing: 6) {
                ForEach(rep.constraintChecks) { chk in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: chk.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(chk.passed ? .green : .orange)
                            .font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chk.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(chk.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .studioInnerBox(tint: chk.passed ? .green : .orange, paddingH: 10, paddingV: 7)
                }
            }
        }
    }

    private func optimizedOutputCard(_ rep: CodonOptimizationEngine.OptimizationReport) -> some View {
        StudioCard(title: "优化后 DNA 序列 (\(rep.lengthBp) bp)") {
            StudioMetricBadge(label: "宿主", value: rep.host.shortTitle, color: .mint)
        } content: {
            Text(rep.optimizedDNA)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioInnerBox(paddingH: 10, paddingV: 10)
        }
    }

    private func applyVendorPreset(_ p: SynthesisVendorPreset) {
        preset = p
        let cfg = CodonOptimizationEngine.OptimizationConfig.presetConfig(p, host: host)
        forbiddenEnzymes = Set(cfg.forbiddenEnzymeNames)
        minWindowGC = cfg.minWindowGC * 100.0
        maxWindowGC = cfg.maxWindowGC * 100.0
        maxHomopolymer = cfg.maxHomopolymerLength
        maxRepeatLen = cfg.maxDirectRepeatLength
        optimizeFivePrime = cfg.optimizeFivePrimeStructure
    }

    private func runOptimization() {
        let customs = customForbiddenText
            .components(separatedBy: CharacterSet(charactersIn: ",;\n "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cfg = CodonOptimizationEngine.OptimizationConfig(
            host: host,
            preset: preset,
            forbiddenEnzymeNames: Array(forbiddenEnzymes).sorted(),
            customForbiddenMotifs: customs,
            minWindowGC: minWindowGC / 100.0,
            maxWindowGC: maxWindowGC / 100.0,
            gcWindowSizeBp: 50,
            maxHomopolymerLength: maxHomopolymer,
            maxDirectRepeatLength: maxRepeatLen,
            optimizeFivePrimeStructure: optimizeFivePrime
        )
        report = CodonOptimizationEngine.optimize(
            inputSequence: rawInput,
            isProteinInput: isProteinMode,
            config: cfg
        )
    }
}
