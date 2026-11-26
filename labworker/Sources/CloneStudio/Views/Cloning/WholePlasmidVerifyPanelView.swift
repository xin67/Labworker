import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// 全质粒 Nanopore 测序验证 & 多 Sanger 读段参考拼接 Contig 面板（嵌入测序验证视图）
public struct WholePlasmidVerifyPanelView: View {
    public enum VerifySubMode: String, CaseIterable, Identifiable {
        case wholePlasmid = "全质粒 Nanopore (.fasta/.fastq)"
        case multiSangerContig = "多 Sanger 拼接 Contig (.ab1/.seq)"

        public var id: String { rawValue }
    }

    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var poolManager = PlasmidPoolManager.shared

    @State private var subMode: VerifySubMode
    @State private var selectedPoolPlasmidID: String = ""
    @State private var referenceName: String = "参考质粒"
    @State private var referenceSequence: String = SangerVerificationView.defaultReferencePlasmid

    // Nanopore / Whole-plasmid 状态
    @State private var nanoporeRawText: String = ""
    @State private var parsedReads: [PlasmidSequencingAssemblyEngine.SequencingReadRecord] = []
    @State private var selectedReadID: String = ""
    @State private var wholeReport: PlasmidSequencingAssemblyEngine.WholePlasmidVerificationReport? = nil

    // 多 Sanger 拼接状态
    @State private var sangerReads: [SangerAlignmentEngine.ChromatogramRecord] = []
    @State private var contigResult: PlasmidSequencingAssemblyEngine.SangerContigAssemblyResult? = nil

    @State private var isEditingTexts: Bool = false

    public init(initialSubMode: VerifySubMode = .wholePlasmid, pendingFileURL: URL? = nil) {
        _subMode = State(initialValue: initialSubMode)
        if let url = pendingFileURL,
           let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .ascii)) {
            let ext = url.pathExtension.lowercased()
            if ["fastq", "fq", "fa", "fasta"].contains(ext) {
                _nanoporeRawText = State(initialValue: raw)
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeAndRefCard
            if subMode == .wholePlasmid {
                wholePlasmidWorkspace
            } else {
                multiSangerWorkspace
            }
        }
        .onAppear {
            if let pending = appState.pendingFinderOpenedFileURL {
                let ext = pending.pathExtension.lowercased()
                if ["fastq", "fq"].contains(ext) {
                    appState.pendingFinderOpenedFileURL = nil
                    loadNanoporeFile(from: pending)
                    return
                }
            }
            if wholeReport == nil && parsedReads.isEmpty {
                loadNanoporeDemo()
            }
            if contigResult == nil && sangerReads.isEmpty {
                loadMultiSangerDemo()
            }
        }
    }

    // MARK: - 顶部模式切换与参考质粒卡

    private var modeAndRefCard: some View {
        StudioCard(title: "全质粒测序验证与多引物双向拼接 (Nanopore / Sanger Contig)") {
            StudioSegmentedPicker(
                selection: $subMode,
                options: VerifySubMode.allCases.map { mode in
                    StudioSegmentedOption(
                        value: mode,
                        title: mode.rawValue,
                        tint: mode == .wholePlasmid ? .indigo : .teal
                    )
                }
            )
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 6) {
                    if !poolManager.items.isEmpty {
                        StudioMenuPicker(
                            selection: $selectedPoolPlasmidID,
                            options: poolManager.items.map { item in
                                StudioMenuPickerOption(value: item.id, title: "\(item.name) (\(item.dnaInfo.length) bp)")
                            },
                            prefix: "参考质粒",
                            icon: "tray.2.fill",
                            tint: .blue,
                            compact: true
                        )
                        .onChange(of: selectedPoolPlasmidID) { _, newID in
                            if let item = poolManager.items.first(where: { $0.id == newID }) {
                                referenceName = item.name
                                referenceSequence = item.dnaInfo.sequence
                                recomputeActiveMode()
                            }
                        }
                    }

                    StudioMetricBadge(label: L10n.t("参考名称"), value: referenceName, color: .blue)
                    StudioMetricBadge(label: L10n.t("参考长度"), value: "\(BioSequence.clean(referenceSequence).count) bp", color: .secondary)

                    StudioCompactPillButton(
                        title: isEditingTexts ? "收起参考文本" : "手动编辑参考/序列",
                        icon: isEditingTexts ? "chevron.up" : "pencil",
                        isSelected: isEditingTexts
                    ) {
                        isEditingTexts.toggle()
                    }
                }

                if isEditingTexts {
                    SequenceEditorBox(
                        text: $referenceSequence,
                        placeholder: L10n.t("粘贴完整参考质粒序列 (5' → 3')"),
                        minHeight: 72
                    )
                }
            }
        }
    }

    // MARK: - 模式 A：全质粒 Nanopore 测序验证

    private var wholePlasmidWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioActionBar(statusText: wholeReport?.summaryText) {
                StudioPrimaryActionButton(
                    title: "运行全质粒比对",
                    icon: "play.fill",
                    tint: .indigo,
                    action: recomputeWholePlasmid
                )
                StudioActionPillButton(title: "导入 FASTQ/FASTA", icon: "doc.badge.plus", tint: .blue, action: selectNanoporeFile)
                StudioActionPillButton(title: "示范 (Origin旋转+SNP+Δ40bp)", icon: "sparkles", tint: .purple, action: loadNanoporeDemo)
            }

            if isEditingTexts || !nanoporeRawText.isEmpty && parsedReads.count > 1 {
                StudioCard(title: L10n.tr("待测全质粒 Reads / Consensus (\(parsedReads.count) 条)", "Query Reads / Consensus (\(parsedReads.count))")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if parsedReads.count > 1 {
                            StudioMenuPicker(
                                selection: $selectedReadID,
                                options: parsedReads.map { StudioMenuPickerOption(value: $0.id, title: "\($0.name) (\($0.sequence.count) bp)") },
                                prefix: "选择读段",
                                tint: .indigo,
                                compact: true
                            )
                            .onChange(of: selectedReadID) { _, _ in
                                recomputeWholePlasmid()
                            }
                        }
                        if isEditingTexts {
                            SequenceEditorBox(
                                text: $nanoporeRawText,
                                placeholder: L10n.t("粘贴全质粒 Nanopore Consensus FASTA 或 .fastq 内容"),
                                minHeight: 72
                            )
                        }
                    }
                }
            }

            if let rep = wholeReport {
                StudioCard(title: "全质粒比对与结构变异判定结论") {
                    StudioMetricBadge(
                        label: L10n.t("结论"),
                        value: rep.verdict.rawValue,
                        color: colorForWholeVerdict(rep.verdict)
                    )
                } content: {
                    VStack(alignment: .leading, spacing: 10) {
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                            StudioMetricBadge(label: L10n.t("长度差异"), value: "\(rep.lengthDeltaBp >= 0 ? "+" : "")\(rep.lengthDeltaBp) bp", color: rep.lengthDeltaBp == 0 ? .green : .orange)
                            StudioMetricBadge(label: L10n.t("Origin 旋转"), value: "\(rep.rotatedOriginOffset0Based) bp", color: .indigo)
                            StudioMetricBadge(label: L10n.t("链方向"), value: L10n.t(rep.isReverseComplement ? "反向互补 (-)" : "正链 (+)"), color: .blue)
                            StudioMetricBadge(label: L10n.t("覆盖度"), value: String(format: "%.1f%%", rep.coveragePercent), color: rep.coveragePercent >= 99 ? .green : .orange)
                            StudioMetricBadge(label: L10n.t("一致率"), value: String(format: "%.2f%%", rep.identityPercent), color: rep.identityPercent >= 99.5 ? .green : .orange)
                            if let mq = rep.queryMeanPhred {
                                StudioMetricBadge(label: L10n.t("平均 Phred"), value: String(format: "Q%.1f", mq), color: mq >= 20 ? .green : .orange)
                            }
                        }

                        // 覆盖区块分布图
                        if !rep.blocks.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.tr("参考质粒锚点覆盖轨迹 (1..\(rep.referenceLength) bp):", "Reference Coverage Track (1..\(rep.referenceLength) bp):"))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Chart {
                                    ForEach(rep.blocks) { blk in
                                        BarMark(
                                            xStart: .value(L10n.t("起点"), blk.refStart1Based),
                                            xEnd: .value(L10n.t("终点"), blk.refEnd1Based),
                                            y: .value(L10n.t("轨道"), L10n.t("匹配区块"))
                                        )
                                        .foregroundStyle(Color.teal.opacity(0.85))
                                    }
                                    ForEach(rep.variants) { v in
                                        PointMark(
                                            x: .value(L10n.t("起点"), v.refStart1Based),
                                            y: .value(L10n.t("轨道"), L10n.t("变异事件"))
                                        )
                                        .foregroundStyle(v.isStructuralVariant ? Color.red : Color.orange)
                                        .symbolSize(70)
                                    }
                                }
                                .chartXScale(domain: 1...max(2, rep.referenceLength))
                                .frame(height: 92)
                            }
                        }
                    }
                }

                StudioCard(title: L10n.tr("检出变异与结构异常清单 (\(rep.variants.count))", "Detected Variants & Structural Events (\(rep.variants.count))")) {
                    if rep.variants.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text(L10n.t("全长参考质粒零 SNP / 零 Indel / 零结构重排，100% 验证通过！"))
                                .font(.system(size: 12.5, weight: .medium))
                        }
                    } else {
                        VStack(spacing: 6) {
                            ForEach(rep.variants) { v in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(L10n.t(v.kind.rawValue))
                                        .font(.system(size: 10.5, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule(style: .continuous).fill(v.isStructuralVariant ? Color.red : Color.orange))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(v.summary)
                                            .font(.system(size: 12, weight: .semibold))
                                        Text(v.detail)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .studioInnerBox(tint: v.isStructuralVariant ? .red : .orange, paddingH: 10, paddingV: 7)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 模式 B：多 Sanger 读段双向拼接

    private var multiSangerWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioActionBar {
                StudioPrimaryActionButton(
                    title: "执行多读段拼接 Contig",
                    icon: "arrow.triangle.merge",
                    tint: .teal,
                    isDisabled: sangerReads.isEmpty,
                    action: recomputeContig
                )
                StudioActionPillButton(title: "批量加入 .ab1/.seq", icon: "folder.badge.plus", tint: .blue, action: selectMultipleSangerFiles)
                StudioActionPillButton(title: "示范 (正反向 2 Reads)", icon: "sparkles", tint: .purple, action: loadMultiSangerDemo)

                if let res = contigResult, !res.consensusFASTA.isEmpty {
                    StudioActionPillButton(title: "导出 Contig FASTA", icon: "square.and.arrow.up", tint: .green) {
                        FinderFileDropHelper.saveTextToFile(
                            content: res.consensusFASTA,
                            defaultFileName: "\(res.referenceName)_Contig.fasta",
                            contentType: .plainText,
                            toastPrefix: "已导出拼接 Consensus FASTA"
                        )
                    }
                    StudioActionPillButton(title: "导出 Contig FASTQ", icon: "doc.text", tint: .indigo) {
                        FinderFileDropHelper.saveTextToFile(
                            content: res.consensusFASTQ,
                            defaultFileName: "\(res.referenceName)_Contig.fastq",
                            contentType: .plainText,
                            toastPrefix: "已导出带质量分 Consensus FASTQ"
                        )
                    }
                }
            }

            if let res = contigResult {
                StudioCard(title: "Sanger Contig 覆盖与质量统计") {
                    StudioMetricBadge(
                        label: L10n.t("总覆盖率"),
                        value: String(format: "%.1f%%", res.coveragePercent),
                        color: res.coveragePercent >= 95 ? .green : .orange
                    )
                } content: {
                    VStack(alignment: .leading, spacing: 10) {
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                            StudioMetricBadge(label: L10n.t("输入读段"), value: L10n.tr("\(res.readBriefs.count) 条", "\(res.readBriefs.count)"), color: .blue)
                            StudioMetricBadge(label: L10n.t("覆盖长度"), value: "\(res.coveredBasesCount)/\(res.referenceLength) bp", color: .teal)
                            StudioMetricBadge(label: L10n.t("双链共同覆盖"), value: "\(res.doubleStrandCoveredCount) bp", color: .purple)
                            StudioMetricBadge(label: L10n.t("平均共识 Q"), value: String(format: "Q%.1f", res.meanConsensusPhred), color: res.meanConsensusPhred >= 30 ? .green : .orange)
                            StudioMetricBadge(label: L10n.t("参考不一致位点"), value: "\(res.mismatchCount)", color: res.mismatchCount == 0 ? .green : .orange)
                            StudioMetricBadge(label: L10n.t("读段冲突位点"), value: "\(res.conflictCount)", color: res.conflictCount == 0 ? .green : .red)
                        }

                        // 读段重叠铺排图
                        Chart {
                            ForEach(res.readBriefs.filter { $0.matchedRefStart1Based > 0 }) { brief in
                                BarMark(
                                    xStart: .value(L10n.t("起点"), brief.matchedRefStart1Based),
                                    xEnd: .value(L10n.t("终点"), max(brief.matchedRefStart1Based + 1, brief.matchedRefEnd1Based)),
                                    y: .value(L10n.t("读段"), brief.sampleName)
                                )
                                .foregroundStyle(brief.isReverseComplement ? Color.indigo : Color.teal)
                            }
                        }
                        .chartXScale(domain: 1...max(2, res.referenceLength))
                        .frame(height: CGFloat(max(80, min(220, res.readBriefs.count * 34 + 30))))

                        if !res.uncoveredRanges.isEmpty {
                            let gapText = res.uncoveredRanges.map { "\($0.lowerBound)..\($0.upperBound)" }.joined(separator: ", ")
                            Text(L10n.tr("未覆盖空洞 (需要补测引物区间): \(gapText) bp", "Uncovered Gaps (need primer walking): \(gapText) bp"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 数据加载与运行逻辑

    private func recomputeActiveMode() {
        if subMode == .wholePlasmid {
            recomputeWholePlasmid()
        } else {
            recomputeContig()
        }
    }

    private func loadNanoporeDemo() {
        let fx = PlasmidSequencingAssemblyEngine.demoWholePlasmidFixture()
        referenceName = fx.refName
        referenceSequence = fx.refSeq
        nanoporeRawText = fx.fastqText
        parsedReads = PlasmidSequencingAssemblyEngine.parseFastqOrFasta(fx.fastqText, defaultName: fx.queryName)
        selectedReadID = parsedReads.first?.id ?? ""
        recomputeWholePlasmid()
    }

    private func loadMultiSangerDemo() {
        let fx = PlasmidSequencingAssemblyEngine.demoMultiSangerFixture()
        if subMode == .multiSangerContig {
            referenceName = fx.refName
            referenceSequence = fx.refSeq
        }
        sangerReads = fx.reads
        contigResult = PlasmidSequencingAssemblyEngine.assembleSangerContig(
            reads: fx.reads,
            referenceSequence: fx.refSeq,
            referenceName: fx.refName
        )
    }

    private func recomputeWholePlasmid() {
        let recs = PlasmidSequencingAssemblyEngine.parseFastqOrFasta(nanoporeRawText, defaultName: "WholePlasmid_Read")
        parsedReads = recs
        let target = recs.first(where: { $0.id == selectedReadID }) ?? recs.first
        if let target {
            selectedReadID = target.id
            wholeReport = PlasmidSequencingAssemblyEngine.verifyWholePlasmid(
                querySequence: target.sequence,
                queryName: target.name,
                queryMeanPhred: target.meanPhred,
                referenceSequence: referenceSequence,
                referenceName: referenceName
            )
        }
    }

    private func recomputeContig() {
        guard !sangerReads.isEmpty else { return }
        contigResult = PlasmidSequencingAssemblyEngine.assembleSangerContig(
            reads: sangerReads,
            referenceSequence: referenceSequence,
            referenceName: referenceName
        )
    }

    private func selectNanoporeFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("选择全质粒测序文件 (.fastq / .fq / .fasta / .fa)")
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            loadNanoporeFile(from: url)
        }
    }

    private func loadNanoporeFile(from url: URL) {
        if let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .ascii)) {
            subMode = .wholePlasmid
            nanoporeRawText = raw
            let recs = PlasmidSequencingAssemblyEngine.parseFastqOrFasta(raw, defaultName: url.deletingPathExtension().lastPathComponent)
            parsedReads = recs
            let cleanRefLen = BioSequence.clean(referenceSequence).count
            // 多 reads FASTQ/FASTA 自动优先挑长度最接近参考质粒的 consensus
            if let best = recs.min(by: { abs($0.sequence.count - cleanRefLen) < abs($1.sequence.count - cleanRefLen) }) {
                selectedReadID = best.id
            } else {
                selectedReadID = recs.first?.id ?? ""
            }
            recomputeWholePlasmid()
            appState.showToast(L10n.tr("已载入全质粒测序文件 \(url.lastPathComponent) (\(recs.count) 条读段)", "Loaded whole-plasmid reads from \(url.lastPathComponent) (\(recs.count) reads)"))
        }
    }

    private func selectMultipleSangerFiles() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("批量选择待拼接的 Sanger .ab1 / .seq 文件")
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let loaded = panel.urls.compactMap { url in
                try? SangerAlignmentEngine.parseFile(at: url, trimQualityThreshold: 20)
            }
            if !loaded.isEmpty {
                sangerReads = loaded
                recomputeContig()
                appState.showToast(L10n.tr("已载入 \(loaded.count) 条 Sanger 读段并完成双向拼接", "Loaded \(loaded.count) Sanger reads and assembled contig"))
            }
        }
    }

    private func colorForWholeVerdict(_ v: PlasmidSequencingAssemblyEngine.WholePlasmidVerdict) -> Color {
        switch v {
        case .verifiedPass: return .green
        case .minorVariantsOnly: return .orange
        case .structuralVariantDetected: return .red
        case .unmatched: return .secondary
        }
    }
}
