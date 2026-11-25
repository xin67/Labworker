import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// CRISPR 编辑池 Sanger 峰图 ICE 反卷积面板（基于 Accelerate vDSP Lawson-Hanson NNLS，嵌入测序验证视图）
public struct CRISPRDeconvolutionPanelView: View {
    @ObservedObject private var appState = AppState.shared

    @State private var wtRecord: SangerAlignmentEngine.ChromatogramRecord? = nil
    @State private var editedRecord: SangerAlignmentEngine.ChromatogramRecord? = nil
    @State private var wtFileName: String = "未选择 WT 对照 (.ab1)"
    @State private var editedFileName: String = "未选择编辑池 (.ab1)"

    @State private var sgRNASpacer: String = ""
    @State private var hdrDonorSequence: String = ""
    @State private var requestedWindowBp: Double = 150
    @State private var maxShiftBp: Int = 20
    @State private var isDemoMode: Bool = false
    @State private var result: CRISPRDeconvolutionEngine.DeconvolutionResult? = nil

    public init() {}

    private var plottedContributions: [CRISPRDeconvolutionEngine.ComponentContribution] {
        guard let res = result else { return [] }
        return res.contributions.filter { c in
            c.percent >= 0.3 || c.shiftBp == 0 || c.isHDR || ((c.shiftBp ?? 99) >= -10 && (c.shiftBp ?? -99) <= 10)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            inputCard
            actionBar
            if let res = result {
                resultSummaryCard(res)
                distributionChartCard(res)
            }
        }
        .onAppear {
            if result == nil {
                loadMixedPoolDemo()
            }
        }
    }

    private var inputCard: some View {
        StudioCard(title: "WT 对照与编辑池 Sanger 文件 (Synthego ICE 风格 NNLS 解卷积)") {
            StudioMetricBadge(label: "求解器", value: "Accelerate vDSP NNLS", color: .purple)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                AdaptiveTwoColumnWorkspace(breakpoint: 680, hasRight: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.path")
                                .foregroundStyle(.blue)
                            Text("野生型对照 (WT Control)")
                                .font(.system(size: 12, weight: .bold))
                            Spacer()
                            StudioActionPillButton(
                                title: "选择 WT .ab1",
                                icon: "folder.badge.plus",
                                tint: .blue
                            ) {
                                selectAB1File(isWT: true)
                            }
                        }
                        Text(wtFileName)
                            .font(.system(size: 11))
                            .foregroundStyle(wtRecord != nil || isDemoMode ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioInnerBox(tint: .blue, paddingH: 10, paddingV: 8)
                } right: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.path.ecg")
                                .foregroundStyle(.purple)
                            Text("编辑池样本 (Edited Pool)")
                                .font(.system(size: 12, weight: .bold))
                            Spacer()
                            StudioActionPillButton(
                                title: "选择 Edited .ab1",
                                icon: "folder.badge.plus",
                                tint: .purple
                            ) {
                                selectAB1File(isWT: false)
                            }
                        }
                        Text(editedFileName)
                            .font(.system(size: 11))
                            .foregroundStyle(editedRecord != nil || isDemoMode ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioInnerBox(tint: .purple, paddingH: 10, paddingV: 8)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Text("20 bp sgRNA Spacer:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        TextField("输入引导序列 (不含 PAM)，如 GGGCGAGGAGCTGTTCACCG", text: $sgRNASpacer)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("20 bp sgRNA Spacer:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("输入 20 bp sgRNA Spacer (不含 PAM)", text: $sgRNASpacer)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("可选 HDR Knock-in 预期序列 (留空则仅分析 NHEJ Indel):")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    SequenceEditorBox(
                        text: $hdrDonorSequence,
                        placeholder: "可选：粘贴期望的 HDR 修复后扩增区序列...",
                        minHeight: 46
                    )
                }

                StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                    HStack(spacing: 6) {
                        Text("下游分析窗口:")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Slider(value: $requestedWindowBp, in: 60...240, step: 10)
                            .frame(width: 110)
                        Text("\(Int(requestedWindowBp)) bp")
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.purple)
                    }

                    StudioMenuPicker(
                        selection: $maxShiftBp,
                        options: [
                            StudioMenuPickerOption(value: 10, title: "±10 bp"),
                            StudioMenuPickerOption(value: 15, title: "±15 bp"),
                            StudioMenuPickerOption(value: 20, title: "±20 bp")
                        ],
                        prefix: "移码范围",
                        compact: true
                    )
                }
            }
        }
    }

    private var actionBar: some View {
        StudioActionBar {
            StudioPrimaryActionButton(
                title: "执行 ICE 峰图反卷积",
                icon: "waveform.path.ecg",
                tint: .purple,
                action: runDeconvolution
            )

            StudioActionPillButton(
                title: "加载编辑池示范 (Indel + HDR)",
                icon: "sparkles",
                help: "载入 WT + (-1bp/+2bp/HDR) 混杂峰矩阵示范并立即求解"
            ) {
                loadMixedPoolDemo()
            }

            if let res = result {
                StudioActionPillButton(title: "复制报告", icon: "doc.on.doc", tint: .teal) {
                    copyDeconvReport(res)
                }
                StudioActionPillButton(title: "导出 CSV", icon: "tablecells.badge.ellipsis", tint: .blue) {
                    exportDeconvCSV(res)
                }
            }
        }
    }

    @ViewBuilder
    private func resultSummaryCard(_ res: CRISPRDeconvolutionEngine.DeconvolutionResult) -> some View {
        StudioCard(title: "反卷积定量指标") {
            StudioMetricBadge(
                label: "R²",
                value: String(format: "%.4f", res.rSquared),
                color: res.rSquared >= 0.85 ? .green : (res.rSquared >= 0.75 ? .orange : .red)
            )
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    StudioMetricBadge(
                        label: "总编辑效率",
                        value: String(format: "%.1f%%", res.totalEditedPercent),
                        color: .purple
                    )
                    StudioMetricBadge(
                        label: "Indel%",
                        value: String(format: "%.1f%%", res.indelPercent),
                        color: .orange
                    )
                    StudioMetricBadge(
                        label: "KO Score (移码)",
                        value: String(format: "%.1f%%", res.koScore),
                        color: .red
                    )
                    StudioMetricBadge(
                        label: "HDR%",
                        value: String(format: "%.1f%%", res.hdrPercent),
                        color: .teal
                    )
                    StudioMetricBadge(
                        label: "WT%",
                        value: String(format: "%.1f%%", res.wtPercent),
                        color: .green
                    )
                    StudioMetricBadge(
                        label: "切点位置",
                        value: "@\(res.cutIndex0Based + 1) bp (\(res.isReverseStrandSgRNA ? "-" : "+")链)",
                        color: .blue
                    )
                    StudioMetricBadge(
                        label: "有效窗口",
                        value: "\(res.effectiveWindowBp) / \(res.requestedWindowBp) bp",
                        color: .secondary
                    )
                }

                if !res.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(res.warnings, id: \.rawValue) { w in
                            Label(warningDescription(w), systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioInnerBox(tint: .orange, paddingH: 10, paddingV: 8)
                }

                if !res.dominantIndels.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("主导贡献分量 (>= 0.5%)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(res.dominantIndels) { item in
                                let col = contributionColor(item)
                                let tag = item.isHDR ? "HDR" : (item.shiftBp == 0 ? "WT" : (item.isFrameshift ? "移码" : "框内"))
                                StudioMetricBadge(
                                    label: "\(item.label) (\(tag))",
                                    value: String(format: "%.1f%%", item.percent),
                                    color: col
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func distributionChartCard(_ res: CRISPRDeconvolutionEngine.DeconvolutionResult) -> some View {
        StudioCard(title: "Indel 移码长度与 HDR 贡献度分布") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                StudioMetricBadge(label: "", value: "WT", color: .green)
                StudioMetricBadge(label: "", value: "移码 (KO)", color: .red)
                StudioMetricBadge(label: "", value: "框内 (3n)", color: .orange)
                StudioMetricBadge(label: "", value: "HDR", color: .teal)
            }
        } content: {
            Chart {
                ForEach(plottedContributions) { item in
                    BarMark(
                        x: .value("分量", item.label),
                        y: .value("占比 (%)", item.percent)
                    )
                    .foregroundStyle(contributionColor(item))
                    .cornerRadius(3)
                }
            }
            .chartYAxisLabel("贡献比例 (%)")
            .frame(minHeight: 200, maxHeight: 260)
        }
    }

    private func contributionColor(_ item: CRISPRDeconvolutionEngine.ComponentContribution) -> Color {
        if item.isHDR { return .teal }
        if item.shiftBp == 0 { return .green }
        return item.isFrameshift ? .red : .orange
    }

    private func warningDescription(_ w: CRISPRDeconvolutionEngine.DeconvolutionWarning) -> String {
        switch w {
        case .windowTruncatedAt3PrimeEnd:
            return "测序末端长度有限，下游比对窗口已在 3' 端截断。"
        case .lowFitRSquared:
            return "拟合优度 R² < 0.75，请核查 WT 与编辑池测序起始质量及 sgRNA 链向。"
        case .sgRNANotFoundInWT:
            return "未在 WT 对照序列中匹配到该 sgRNA Spacer（已自动检查正反两条链）。"
        case .cutSiteTooCloseTo5Prime:
            return "Cas9 切点过于靠近测序读长 5' 端，可能影响大型缺失列构建。"
        case .insufficientDownstreamWindow:
            return "切点下游有效测序碱基过短，不足以完成可靠解卷积。"
        case .hdrCollinearWithWT:
            return "HDR 序列在分析窗口内与 WT 完全共线，已抑制重复 HDR 列。"
        }
    }

    private func selectAB1File(isWT: Bool) {
        let panel = NSOpenPanel()
        panel.title = isWT ? "选择野生型 WT 对照 (.ab1 / .abi / .seq)" : "选择编辑池样本 (.ab1 / .abi / .seq)"
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText]
        for ext in ["ab1", "abi", "seq", "fa", "fasta", "txt"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                let rec = try SangerAlignmentEngine.parseFile(at: url, trimQualityThreshold: 20)
                if isWT {
                    self.wtRecord = rec
                    self.wtFileName = "\(url.lastPathComponent) (\(rec.rawLength) bp)"
                } else {
                    self.editedRecord = rec
                    self.editedFileName = "\(url.lastPathComponent) (\(rec.rawLength) bp)"
                }
                self.isDemoMode = false
                if self.wtRecord != nil && self.editedRecord != nil && BioSequence.clean(self.sgRNASpacer).count >= 17 {
                    self.runDeconvolution()
                }
            } catch {
                appState.showToast("读取测序文件失败: \(error.localizedDescription)")
            }
        }
    }

    private func runDeconvolution() {
        let spacer = BioSequence.clean(sgRNASpacer)
        guard spacer.count >= 17 else {
            appState.showToast("请输入至少 17 bp 的 sgRNA Spacer 序列")
            return
        }
        if let wt = wtRecord, let ed = editedRecord, !isDemoMode {
            let hdrClean = BioSequence.clean(hdrDonorSequence)
            let res = CRISPRDeconvolutionEngine.deconvolveChromatograms(
                wt: wt,
                edited: ed,
                sgRNASequence: spacer,
                hdrDonorSequence: hdrClean.isEmpty ? nil : hdrClean,
                requestedWindowBp: Int(requestedWindowBp),
                shiftRange: (-maxShiftBp)...maxShiftBp
            )
            self.result = res
            appState.showToast(String(format: "ICE 反卷积完成：总编辑 %.1f%% (R²=%.3f)", res.totalEditedPercent, res.rSquared))
        } else {
            loadMixedPoolDemo(keepInputs: true)
        }
    }

    private func loadMixedPoolDemo(keepInputs: Bool = false) {
        let demoWT =
            "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTG" +
            "GTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCT" +
            "ACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGAC" +
            "CACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAG"
        let demoSpacer = "GGGCGAGGAGCTGTTCACCG"
        // 在切点附近构建带 2 处同义突变 + 标签替换的 HDR 示例序列
        let demoHDR =
            "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTTACAGGCGTGGTGCCCATCCTG" +
            "GTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCT" +
            "ACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGAC" +
            "CACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAG"

        if !keepInputs {
            wtRecord = nil
            editedRecord = nil
            wtFileName = "内置示范 WT 对照 (EGFP 位点, 280 bp)"
            editedFileName = "内置示范 编辑池 (45% WT + 30% -1bp + 10% +2bp + 15% HDR)"
            sgRNASpacer = demoSpacer
            hdrDonorSequence = demoHDR
        }
        isDemoMode = true

        let activeSpacer = BioSequence.clean(sgRNASpacer).count >= 17 ? BioSequence.clean(sgRNASpacer) : demoSpacer
        let activeHDR = BioSequence.clean(hdrDonorSequence).isEmpty ? nil : BioSequence.clean(hdrDonorSequence)
        let wtPeaks = CRISPRDeconvolutionEngine.peaksFromSequence(demoWT)

        guard let loc = CRISPRDeconvolutionEngine.locateCutSite(wtSequence: demoWT, sgRNASequence: activeSpacer) else {
            return
        }
        let cut0 = loc.cutIndex0Based
        let reqW = min(Int(requestedWindowBp), demoWT.count - cut0 - 4)
        let hdrFull = activeHDR.map { CRISPRDeconvolutionEngine.peaksFromSequence($0) }

        // 构造真实物理混杂峰矩阵: 0.45*WT + 0.30*(-1bp) + 0.10*(+2bp) + 0.15*HDR
        var editedWin: [[Double]] = []
        for k in 0..<reqW {
            var mix = [0.0, 0.0, 0.0, 0.0]
            let wtP = wtPeaks[cut0 + k]
            let del1P = wtPeaks[cut0 + k + 1]
            let ins2P = (cut0 + k - 2 >= 0) ? wtPeaks[cut0 + k - 2] : [0.25, 0.25, 0.25, 0.25]
            let hdrP = (hdrFull != nil && (cut0 + k) < hdrFull!.count) ? hdrFull![cut0 + k] : wtP
            for ch in 0..<4 {
                mix[ch] = 0.45 * wtP[ch] + 0.30 * del1P[ch] + 0.10 * ins2P[ch] + 0.15 * hdrP[ch]
            }
            editedWin.append(mix)
        }
        let hdrWin = hdrFull.map { Array($0[cut0..<min($0.count, cut0 + reqW)]) }

        let res = CRISPRDeconvolutionEngine.deconvolvePeakMatrices(
            wtPeaksACGT: wtPeaks,
            editedWindowPeaksACGT: editedWin,
            cutIndex0Based: cut0,
            isReverseStrandSgRNA: loc.isReverseStrand,
            requestedWindowBp: Int(requestedWindowBp),
            shiftRange: (-maxShiftBp)...maxShiftBp,
            hdrWindowPeaksACGT: hdrWin
        )
        self.result = res
    }

    private func copyDeconvReport(_ res: CRISPRDeconvolutionEngine.DeconvolutionResult) {
        var lines = [
            "Labworker CRISPR Sanger ICE Deconvolution Report",
            String(format: "Total Edited: %.2f%% | Indel: %.2f%% | KO Score: %.2f%% | HDR: %.2f%% | WT: %.2f%% | R^2: %.4f",
                   res.totalEditedPercent, res.indelPercent, res.koScore, res.hdrPercent, res.wtPercent, res.rSquared),
            "Cut Index (1-based): \(res.cutIndex0Based + 1) | Strand: \(res.isReverseStrandSgRNA ? "-" : "+") | Window: \(res.effectiveWindowBp) bp"
        ]
        for c in res.dominantIndels {
            lines.append(String(format: "  %-6@ : %6.2f%% (%@)", c.label, c.percent, c.isHDR ? "HDR" : (c.isFrameshift ? "Frameshift" : "In-frame/WT")))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        appState.showToast("已复制 ICE 反卷积报告到剪贴板")
    }

    private func exportDeconvCSV(_ res: CRISPRDeconvolutionEngine.DeconvolutionResult) {
        var rows = ["label,shift_bp,is_hdr,is_frameshift,raw_weight,percent"]
        for c in res.contributions {
            let sStr = c.shiftBp.map(String.init) ?? ""
            rows.append("\(c.label),\(sStr),\(c.isHDR),\(c.isFrameshift),\(c.rawWeight),\(c.percent)")
        }
        FinderFileDropHelper.saveTextToFile(
            content: rows.joined(separator: "\n"),
            defaultFileName: "crispr_ice_deconvolution.csv",
            contentType: .commaSeparatedText,
            toastPrefix: "已导出 CRISPR 编辑池定量 CSV"
        )
    }
}
