import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// Sanger 测序 (.ab1 / .abi / .seq) 四色荧光峰图解析、环状质粒比对与批量克隆验证看板（内置 CRISPR 编辑池 ICE 反卷积与全质粒 Nanopore / 多读段拼接模式）
public struct SangerVerificationView: View {
    private enum SangerWorkspaceMode: String, CaseIterable {
        case alignment = "测序比对与批量质检"
        case crisprDeconvolution = "CRISPR 编辑效率 (ICE 反卷积)"
        case wholePlasmidAndContig = "全质粒与多读段拼接"
    }

    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var poolManager = PlasmidPoolManager.shared
    @State private var workspaceMode: SangerWorkspaceMode = .alignment

    // MARK: - 状态属性
    @State private var chromatogram: SangerAlignmentEngine.ChromatogramRecord?
    @State private var report: SangerAlignmentEngine.VerificationReport?
    @State private var selectedPoolPlasmidID: String = ""
    @State private var referenceName: String = "EGFP-CDS 标准参考载体"
    @State private var referenceSequence: String = SangerVerificationView.defaultReferencePlasmid
    @State private var trimQualityThreshold: Double = 20.0
    @State private var cdsStart1BasedText: String = "61"

    // 视图交互状态
    @State private var horizontalZoom: Double = 1.25
    @State private var showChannelA: Bool = true
    @State private var showChannelC: Bool = true
    @State private var showChannelG: Bool = true
    @State private var showChannelT: Bool = true
    @State private var selectedReadPos1Based: Int? = nil
    @State private var scrollTargetReadPos1: Int? = nil
    @State private var isReferenceEditorExpanded: Bool = false
    @State private var isAlignmentTextExpanded: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var activeDemoMode: DemoPreset = .pointMutation

    // 批量克隆验证看板状态 (P11)
    @State private var batchResult: SangerBatchEngine.BatchVerificationResult? = nil
    @State private var batchFilter: CloneBatchFilter = .all
    @State private var isBatchRunning: Bool = false
    @State private var batchProgressDone: Int = 0
    @State private var batchProgressTotal: Int = 0
    @State private var batchTask: Task<Void, Never>? = nil

    public enum CloneBatchFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case pass = "通过"
        case needsReview = "复核"
        case failed = "失败"

        public var id: String { rawValue }
    }

    public enum DemoPreset: String, CaseIterable, Identifiable {
        case perfectMatch = "完美匹配克隆"
        case pointMutation = "定点突变 (p.K42R)"
        case doublePeakAndIndel = "杂合双峰预警"
        case batchMultiClone = "批量克隆验证看板 (6 Reads)"

        public var id: String { rawValue }
    }

    // 默认参考序列：上游 60bp 载体接头 + 240bp EGFP 核心片段 + 下游 60bp 载体骨架 (共 360bp)
    public static let defaultReferencePlasmid: String =
        "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTG" +
        "CCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAG" +
        "GGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAG" +
        "CTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGC" +
        "CGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTAC" +
        "GTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTG"

    public init() {}

    public var body: some View {
        StudioPageLayout(
            title: "Sanger 测序 (.ab1) 峰图与质粒比对验证",
            toolbar: [
                .action(
                    title: "打开 .ab1",
                    icon: "waveform.path.badge.plus",
                    tint: .blue,
                    isProminent: true,
                    help: "打开 .ab1 测序文件或批量验证文件夹",
                    action: selectSangerFileFromFinder
                ),
                .action(
                    title: "示范",
                    icon: "wand.and.stars",
                    help: "加载内置 Sanger 测序示范峰图",
                    menuItems: DemoPreset.allCases.map { preset in
                        StudioToolbarMenuItem(
                            id: preset.id,
                            title: "加载示例：\(preset.rawValue)",
                            icon: "sparkles"
                        ) {
                            loadBuiltinDemo(preset)
                        }
                    }
                ),
                .action(title: "复制报告", icon: "doc.on.doc", help: "复制质检报告", action: copyVerificationSummary),
                .action(title: "导出报告", icon: "square.and.arrow.up", tint: .teal, help: "导出验证报告", action: exportVerificationReport)
            ]
        ) {
            VStack(alignment: .leading, spacing: 14) {
                StudioSegmentedPicker(
                    selection: $workspaceMode,
                    options: [
                        StudioSegmentedOption(value: SangerWorkspaceMode.alignment, title: SangerWorkspaceMode.alignment.rawValue, tint: .blue),
                        StudioSegmentedOption(value: SangerWorkspaceMode.crisprDeconvolution, title: SangerWorkspaceMode.crisprDeconvolution.rawValue, tint: .purple),
                        StudioSegmentedOption(value: SangerWorkspaceMode.wholePlasmidAndContig, title: SangerWorkspaceMode.wholePlasmidAndContig.rawValue, tint: .indigo)
                    ]
                )

                if workspaceMode == .crisprDeconvolution {
                    CRISPRDeconvolutionPanelView()
                } else if workspaceMode == .wholePlasmidAndContig {
                    WholePlasmidVerifyPanelView()
                } else {
                    // 0. 批量克隆验证看板（拖入多文件或文件夹时自动展开 P11）
                    if isBatchRunning || batchResult != nil {
                        batchKanbanCard
                    }

                    // 1. 顶部 KPI 指标自适应网格
                    if let rep = report {
                        metricsSummaryGrid(rep)
                    }

                    // 2. 主工作区：左侧四色峰图与工具栏 + 右侧参考质粒选择与变异位点清单
                    StudioResponsiveSplitLayout(breakpoint: 960, spacing: 14, leftRatio: 0.58) {
                        chromatogramWorkspaceCard
                        rightInspectorColumn
                    }

                    // 3. 底部可展开逐碱基比对文本抽屉
                    if let rep = report, !rep.columns.isEmpty {
                        alignmentDetailDrawer(rep)
                    }
                }
            }
        }
        .onAppear {
            if let pending = appState.pendingFinderOpenedFileURL {
                let ext = pending.pathExtension.lowercased()
                if ["fastq", "fq"].contains(ext) {
                    workspaceMode = .wholePlasmidAndContig
                    return
                }
                if ["ab1", "abi", "seq", "fa", "fasta", "txt"].contains(ext) {
                    appState.pendingFinderOpenedFileURL = nil
                    loadSangerFile(from: pending)
                    return
                }
            }
            if chromatogram == nil {
                loadBuiltinDemo(.pointMutation)
            }
        }
        .onChange(of: appState.pendingFinderOpenedFileURL) { _, newURL in
            guard let url = newURL else { return }
            let ext = url.pathExtension.lowercased()
            if ["fastq", "fq"].contains(ext) {
                workspaceMode = .wholePlasmidAndContig
                return
            }
            if ["ab1", "abi", "seq", "fa", "fasta", "txt"].contains(ext) {
                appState.pendingFinderOpenedFileURL = nil
                loadSangerFile(from: url)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            FinderFileDropHelper.extractAllFileURLs(from: providers) { urls in
                handleOpenedOrDroppedURLs(urls)
            }
        }
    }

    // MARK: - 0. 批量克隆验证看板 (P11)

    @ViewBuilder
    private var batchKanbanCard: some View {
        StudioCard(title: "批量克隆测序验证看板 (Batch Clone Verification Kanban)") {
            if let res = batchResult {
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                    StudioMetricBadge(label: "克隆总数", value: "\(res.cloneSummaries.count)", color: .blue)
                    StudioMetricBadge(label: "测序 Reads", value: "\(res.reads.count)", color: .teal)
                    let passCnt = res.cloneSummaries.filter { $0.verdict == .pass }.count
                    StudioMetricBadge(label: "100% 通过", value: "\(passCnt)", color: .green)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if isBatchRunning {
                    HStack(spacing: 10) {
                        ProgressView(
                            value: Double(batchProgressDone),
                            total: Double(max(1, batchProgressTotal))
                        )
                        .frame(maxWidth: 260)
                        Text("正在并发比对测序文件 \(batchProgressDone) / \(batchProgressTotal)...")
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        StudioCompactPillButton(
                            title: "取消",
                            icon: "xmark",
                            tint: .red,
                            help: "取消批处理"
                        ) {
                            batchTask?.cancel()
                            isBatchRunning = false
                        }
                    }
                }

                if let res = batchResult {
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        StudioSegmentedPicker(
                            selection: $batchFilter,
                            options: CloneBatchFilter.allCases.map { f in
                                StudioSegmentedOption(value: f, title: filterTitle(f, in: res), tint: filterTint(f))
                            }
                        )

                        Spacer()

                        StudioActionPillButton(
                            title: "导出 CSV",
                            icon: "tablecells.badge.ellipsis",
                            tint: .blue,
                            isProminent: true,
                            help: "导出 batch_summary.csv"
                        ) {
                            exportBatchSummaryCSV(res)
                        }

                        StudioSectionClearButton(title: "关闭批量看板") {
                            batchTask?.cancel()
                            batchResult = nil
                            isBatchRunning = false
                        }
                    }

                    let filteredClones = filteredCloneSummaries(res)
                    if filteredClones.isEmpty {
                        Text("当前筛选条件下暂无克隆记录")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 10)], spacing: 10) {
                            ForEach(filteredClones) { clone in
                                cloneSummaryCardView(clone)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cloneSummaryCardView(_ clone: SangerBatchEngine.CloneBatchSummary) -> some View {
        let vColor = colorForBatchVerdict(clone.verdict)
        let isCurrentCloneSelected = clone.reads.contains { $0.report.chromatogram.sampleName == chromatogram?.sampleName }
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 6) {
                Circle()
                    .fill(vColor)
                    .frame(width: 8, height: 8)
                Text(clone.cloneName)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Spacer()
                StudioMetricBadge(label: "", value: clone.verdict.rawValue, color: vColor)
            }

            HStack(spacing: 8) {
                Text("参考: \(clone.referenceName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(String(format: "覆盖 %.1f%% (%d/%d bp)", clone.coveragePercent, clone.coveredBp, clone.referenceLengthBp))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.teal)
            }

            HStack(spacing: 8) {
                Text(String(format: "均值一致率 %.1f%%", clone.meanIdentityPercent))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(clone.snpCount) SNP · \(clone.indelCount) Indel · \(clone.doublePeakCount) 双峰")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle((clone.snpCount + clone.indelCount + clone.doublePeakCount) == 0 ? .green : .orange)
            }

            // 正反向 Read 切换胶囊条（点击任意 Read 即在下方四色峰图画布打开详情）
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                ForEach(clone.reads) { item in
                    let isSelectedRead = (chromatogram?.sampleName == item.report.chromatogram.sampleName)
                    StudioCompactPillButton(
                        title: "\(item.primerSuffix ?? item.fileName) · \(String(format: "%.1f%%", item.report.identityPercent))",
                        icon: item.report.isReverseComplement ? "arrow.left.circle.fill" : "arrow.right.circle.fill",
                        tint: appState.accentTheme.color,
                        isSelected: isSelectedRead
                    ) {
                        selectBatchReadItem(item)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                .fill(isCurrentCloneSelected ? vColor.opacity(appState.isLightAppearance ? 0.09 : 0.16) : StudioPalette.controlSubtleBg(isLight: appState.isLightAppearance))
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                        .stroke(isCurrentCloneSelected ? vColor.opacity(0.55) : StudioPalette.cardBorder(isLight: appState.isLightAppearance), lineWidth: isCurrentCloneSelected ? 1.3 : 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let firstRead = clone.reads.first {
                selectBatchReadItem(firstRead)
            }
        }
    }

    // MARK: - 1. 顶部自适应 KPI 指标汇总卡片

    @ViewBuilder
    private func metricsSummaryGrid(_ rep: SangerAlignmentEngine.VerificationReport) -> some View {
        let verdictColor = colorForVerdict(rep.verdict)
        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            StudioMetricBadge(
                label: "综合结论",
                value: "\(shortVerdictTitle(rep.verdict)) (\(rep.isReverseComplement ? "-" : "+")链)",
                color: verdictColor
            )
            StudioMetricBadge(
                label: "序列一致率",
                value: String(format: "%.1f%% (%d/%d bp)", rep.identityPercent, rep.matchCount, rep.alignedLength),
                color: rep.identityPercent >= 99.5 ? .green : (rep.identityPercent >= 95.0 ? .orange : .red)
            )
            StudioMetricBadge(
                label: "高质读长",
                value: "\(rep.chromatogram.trimmedLength) / \(rep.chromatogram.rawLength) bp",
                color: .blue
            )
            StudioMetricBadge(
                label: "平均质量",
                value: String(format: "Q%.1f (Q20 %.0f%%)", rep.chromatogram.meanQualityTrimmed, rep.chromatogram.q20Percent),
                color: rep.chromatogram.meanQualityTrimmed >= 30 ? .teal : .orange
            )
            StudioMetricBadge(
                label: "变异与双峰",
                value: "\(rep.mismatchCount) SNP · \(rep.insertionCount + rep.deletionCount) Indel · \(rep.doublePeakCount) 双峰",
                color: rep.variants.isEmpty ? .green : .orange
            )
        }
    }

    // MARK: - 2. 左侧四色荧光色谱图工作区

    private var chromatogramWorkspaceCard: some View {
        StudioCard(title: "四色毛细管电泳荧光峰图 (Chromatogram Trace)") {
            VStack(alignment: .leading, spacing: 10) {
                // 顶部控制栏（独立于画布之外，绝不遮挡峰值）
                StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                    // 四通道开关
                    HStack(spacing: 6) {
                        channelTogglePill(label: "A", color: .green, isOn: $showChannelA)
                        channelTogglePill(label: "C", color: .blue, isOn: $showChannelC)
                        channelTogglePill(label: "G", color: .primary, isOn: $showChannelG)
                        channelTogglePill(label: "T", color: .red, isOn: $showChannelT)
                    }

                    Divider().frame(height: 16)

                    // 水平缩放滑块
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left.and.right.square")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("峰距缩放")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Slider(value: $horizontalZoom, in: 0.8...2.4, step: 0.1)
                            .frame(width: 88)
                        Text(String(format: "%.1fx", horizontalZoom))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 32, alignment: .leading)
                    }

                    Divider().frame(height: 16)

                    // 两端修剪 Q 阈值
                    HStack(spacing: 5) {
                        Text("5'/3' 修剪阈值")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Slider(value: $trimQualityThreshold, in: 10...30, step: 2)
                            .frame(width: 78)
                            .onChange(of: trimQualityThreshold) {
                                rerunAlignmentWithCurrentQuality()
                            }
                        Text("Q\(Int(trimQualityThreshold))")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.teal)
                    }
                }

                if let chrom = chromatogram {
                    // 样本与区间提示条
                    HStack(spacing: 8) {
                        Label(chrom.sampleName, systemImage: chrom.isBinaryAB1 ? "doc.zipper" : "doc.text")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(chrom.isBinaryAB1 ? "ABIF 原生二进制四通道" : "序列合成高斯峰预览")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        if let selPos = selectedReadPos1Based,
                           selPos >= 1, selPos <= chrom.calledPeaks.count {
                            let pk = chrom.calledPeaks[selPos - 1]
                            Text("当前选中: Read #\(selPos) (\(String(pk.base))) · Q\(pk.phredQuality)" + (pk.secondaryBase != nil ? " · 次峰 \(String(pk.secondaryBase!)) (\(Int(pk.secondaryRatio * 100))%)" : ""))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        } else {
                            Text("提示：点击下方或右侧任意变异胶囊可自动滚动定位至对应荧光峰")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 可横向滚动与锚点跳转的四色色谱图
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: true) {
                            ChromatogramTraceStripView(
                                chromatogram: chrom,
                                report: report,
                                baseColumnWidth: CGFloat(18.0 * horizontalZoom),
                                showA: showChannelA,
                                showC: showChannelC,
                                showG: showChannelG,
                                showT: showChannelT,
                                selectedReadPos1: $selectedReadPos1Based
                            )
                            .frame(height: 255)
                        }
                        .background(
                            RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                .fill(StudioPalette.controlBg(isLight: appState.isLightAppearance))
                                .overlay(
                                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                        .stroke(StudioPalette.cardBorder(isLight: appState.isLightAppearance), lineWidth: 1)
                                )
                        )
                        .onChange(of: scrollTargetReadPos1) { _, targetPos in
                            guard let pos = targetPos else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo("sanger-peak-\(pos)", anchor: .center)
                            }
                        }
                    }

                    // 快速跳转按钮条（5' 有效起点 / 各变异位点 / 3' 有效终点）
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        StudioCompactPillButton(
                            title: "5' 起点 #\(chrom.trimStart0 + 1)",
                            icon: "arrow.left.to.line",
                            help: "跳至 5' 高质起点"
                        ) {
                            let start1 = chrom.trimStart0 + 1
                            selectedReadPos1Based = start1
                            scrollTargetReadPos1 = start1
                        }

                        if let rep = report {
                            ForEach(rep.variants.prefix(8)) { v in
                                if let rPos = v.readPos1Based {
                                    StudioCompactPillButton(
                                        title: v.hgvsNotation,
                                        dotColor: colorForEvent(v.kind),
                                        tint: colorForEvent(v.kind),
                                        help: v.codonImpactNote
                                    ) {
                                        selectedReadPos1Based = rPos
                                        scrollTargetReadPos1 = rPos
                                    }
                                }
                            }
                        }

                        StudioCompactPillButton(
                            title: "3' 终点 #\(chrom.trimEnd0)",
                            icon: "arrow.right.to.line",
                            help: "跳至 3' 高质终点"
                        ) {
                            let end1 = max(1, chrom.trimEnd0)
                            selectedReadPos1Based = end1
                            scrollTargetReadPos1 = end1
                        }
                    }
                } else {
                    Text("请拖入 .ab1 / .seq 测序文件或点击右上角「示范峰图」")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
    }

    // MARK: - 3. 右侧参考质粒选择与变异核查栏

    private var rightInspectorColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 3.1 参考质粒载体配置卡片
            StudioCard(title: "参考质粒载体 (Reference Plasmid)") {
                VStack(alignment: .leading, spacing: 10) {
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        StudioMenuPillButton(
                            title: referenceName,
                            icon: "tray.2.fill",
                            help: "从质粒池或内置选择参考载体"
                        ) {
                            Button("内置 EGFP-CDS 标准参考载体 (360 bp)") {
                                selectedPoolPlasmidID = ""
                                referenceName = "EGFP-CDS 标准参考载体"
                                referenceSequence = Self.defaultReferencePlasmid
                                cdsStart1BasedText = "61"
                                recomputeVerification()
                            }
                            if !poolManager.items.isEmpty {
                                Divider()
                                ForEach(poolManager.items) { item in
                                    Button("\(item.name) (\(item.dnaInfo.length) bp)") {
                                        selectedPoolPlasmidID = item.id
                                        referenceName = item.name
                                        referenceSequence = item.dnaInfo.sequence
                                        if let firstCDS = item.dnaInfo.features.first(where: { $0.type == "CDS" }),
                                           let sStart = firstCDS.segments.first?.start {
                                            cdsStart1BasedText = "\(sStart)"
                                        } else {
                                            cdsStart1BasedText = "1"
                                        }
                                        recomputeVerification()
                                    }
                                }
                            }
                        }

                        StudioActionPillButton(
                            title: "载入 .dna",
                            icon: "folder.badge.plus",
                            tint: .indigo,
                            help: "从 Finder 载入参考 .dna 质粒"
                        ) {
                            FinderFileDropHelper.selectDNAFile(message: "选择用于测序比对的参考 .dna 质粒文件") { url in
                                loadReferenceDNAFile(url)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Text("参考长度: \(BioSequence.clean(referenceSequence).count) bp")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 4) {
                            Text("CDS 起始位点:")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            TextField("1", text: $cdsStart1BasedText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .frame(width: 58)
                                .onSubmit { recomputeVerification() }
                        }
                    }

                    DisclosureGroup(isExpanded: $isReferenceEditorExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $referenceSequence)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(height: 82)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                        .fill(StudioPalette.controlBg(isLight: appState.isLightAppearance))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                                .stroke(StudioPalette.controlBorder(isLight: appState.isLightAppearance), lineWidth: 1)
                                        )
                                )
                            HStack {
                                Spacer()
                                StudioCompactPillButton(
                                    title: "重新比对",
                                    icon: "arrow.triangle.2.circlepath",
                                    tint: .blue,
                                    isProminent: true,
                                    help: "重新比对参考序列"
                                ) {
                                    recomputeVerification()
                                }
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("展开查看 / 手动编辑参考序列文本")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 3.2 变异与异常峰检出列表
            StudioCard(title: "变异位点与杂合双峰核查清单") {
                if let rep = report {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rep.summaryNotes, id: \.self) { note in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: rep.variants.isEmpty ? "checkmark.seal.fill" : "info.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(colorForVerdict(rep.verdict))
                                    .padding(.top, 2)
                                Text(note)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        if rep.variants.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("高质测序区 100% 匹配无误")
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(.green)
                                    Text("未检出任何错配替换 (SNP)、移码缺失/插入 (Indel) 或杂合双峰。")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 8)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(rep.variants) { v in
                                        Button {
                                            if let rPos = v.readPos1Based {
                                                selectedReadPos1Based = rPos
                                                scrollTargetReadPos1 = rPos
                                            }
                                        } label: {
                                            HStack(alignment: .center, spacing: 10) {
                                                Text(v.hgvsNotation)
                                                    .font(.system(size: 12, weight: .bold))
                                                    .monospacedDigit()
                                                    .foregroundStyle(colorForEvent(v.kind))
                                                    .frame(minWidth: 78, alignment: .leading)

                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(v.kind.rawValue)
                                                        .font(.system(size: 11, weight: .semibold))
                                                        .foregroundStyle(.primary)
                                                    Text(v.codonImpactNote)
                                                        .font(.system(size: 10.5))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(2)
                                                }

                                                Spacer()

                                                VStack(alignment: .trailing, spacing: 2) {
                                                    if let rPos = v.readPos1Based {
                                                        Text("Read #\(rPos)")
                                                            .font(.system(size: 10.5, weight: .semibold))
                                                            .monospacedDigit()
                                                    }
                                                    Text("Q\(v.phredQuality)")
                                                        .font(.system(size: 10))
                                                        .monospacedDigit()
                                                        .foregroundStyle(.secondary)
                                                }
                                                Image(systemName: "scope")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(colorForEvent(v.kind))
                                            }
                                            .studioInnerBox(tint: colorForEvent(v.kind), paddingH: 10, paddingV: 7)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 210)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. 底部可展开逐碱基比对抽屉

    @ViewBuilder
    private func alignmentDetailDrawer(_ rep: SangerAlignmentEngine.VerificationReport) -> some View {
        StudioCard(title: "逐位点双序列比对详情 (Base-by-Base Alignment)") {
            DisclosureGroup(isExpanded: $isAlignmentTextExpanded) {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(formatAlignmentBlock(rep))
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                }
                .studioInnerBox(paddingH: 8, paddingV: 8)
                .padding(.top, 6)
            } label: {
                HStack {
                    Text("展开查看全长逐位点比对矩阵（Ref \(rep.matchedRefStart1Based)..\(rep.matchedRefEnd1Based) bp vs Read \(rep.chromatogram.trimStart0 + 1)..\(rep.chromatogram.trimEnd0)）")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Text("\(rep.alignedLength) 列")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 5. 辅助方法与数据加载

    @ViewBuilder
    private func channelTogglePill(label: String, color: Color, isOn: Binding<Bool>) -> some View {
        StudioCompactPillButton(
            title: label,
            dotColor: isOn.wrappedValue ? color : Color.secondary.opacity(0.35),
            tint: color,
            isSelected: isOn.wrappedValue
        ) {
            isOn.wrappedValue.toggle()
        }
    }

    private func loadBuiltinDemo(_ preset: DemoPreset) {
        activeDemoMode = preset
        referenceName = "EGFP-CDS 标准参考载体"
        referenceSequence = Self.defaultReferencePlasmid
        cdsStart1BasedText = "61"

        if preset == .batchMultiClone {
            loadBuiltinBatchDemo()
            return
        }

        // 取参考序列 41..260 (220bp) 构建模拟测序读长
        let refChars = Array(Self.defaultReferencePlasmid)
        var readChars = Array(refChars[40..<260])
        var doublePeaks: [Int: Character] = [:]
        let sampleTitle: String

        switch preset {
        case .perfectMatch:
            sampleTitle = "EGFP_Colony1_WT_Pass.ab1"
        case .pointMutation:
            if readChars.count > 65 {
                readChars[64] = (readChars[64] == "A") ? "G" : "A"
            }
            sampleTitle = "EGFP_SiteMut_c105_Pass.ab1"
        case .doublePeakAndIndel, .batchMultiClone:
            if readChars.count > 90 {
                doublePeaks[52] = (readChars[51] == "C") ? "T" : "C"
                doublePeaks[84] = (readChars[83] == "G") ? "A" : "G"
            }
            sampleTitle = "EGFP_MixedColony_DoublePeak.ab1"
        }

        let ab1Data = SangerAlignmentEngine.generateSyntheticAB1Data(
            sequence: String(readChars),
            sampleName: sampleTitle,
            doublePeakAt1Based: doublePeaks,
            simulateNoisyEnds: true
        )
        let parsed = SangerAlignmentEngine.parseData(
            ab1Data,
            sampleName: sampleTitle,
            trimQualityThreshold: Int(trimQualityThreshold)
        )
        self.chromatogram = parsed
        recomputeVerification()

        if let firstVar = report?.variants.first?.readPos1Based {
            selectedReadPos1Based = firstVar
            scrollTargetReadPos1 = firstVar
        } else {
            selectedReadPos1Based = parsed.trimStart0 + 15
        }
    }

    private func loadBuiltinBatchDemo() {
        let refSeq = Self.defaultReferencePlasmid
        let refChars = Array(refSeq)
        let fwdSlice = String(refChars[20..<220])
        let revSlice = BioSequence.reverseComplement(String(refChars[140..<340]))
        var snpChars = Array(refChars[30..<230])
        snpChars[50] = (snpChars[50] == "G") ? "A" : "G"
        let dpChars = String(refChars[40..<240])
        let unmatchedSeq = String(repeating: "TTAACCGGTTAACCGG", count: 12)

        let demoSpecs: [(String, String, [Int: Character])] = [
            ("EGFP-Colony1-F.ab1", fwdSlice, [:]),
            ("EGFP-Colony1-R.ab1", revSlice, [:]),
            ("EGFP-Colony2-F.ab1", String(snpChars), [:]),
            ("EGFP-Colony2-R.ab1", revSlice, [:]),
            ("EGFP-Colony3-F.ab1", dpChars, [60: "T"]),
            ("UnknownVec-Colony4-F.ab1", unmatchedSeq, [:])
        ]

        let candidates = buildReferenceCandidates()
        var items: [SangerBatchEngine.BatchReadItem] = []
        for (idx, spec) in demoSpecs.enumerated() {
            let data = SangerAlignmentEngine.generateSyntheticAB1Data(
                sequence: spec.1,
                sampleName: spec.0,
                doublePeakAt1Based: spec.2,
                simulateNoisyEnds: true
            )
            let item = SangerBatchEngine.verifyInMemoryRead(
                data: data,
                fileName: spec.0,
                index: idx,
                candidates: candidates,
                primerSuffixRegex: appState.defaultSangerCloneGroupingPattern,
                trimQualityThreshold: Int(trimQualityThreshold)
            )
            items.append(item)
        }
        let summaries = SangerBatchEngine.summarizeByClone(reads: items, candidates: candidates)
        let res = SangerBatchEngine.BatchVerificationResult(reads: items, cloneSummaries: summaries)
        self.batchResult = res
        self.batchFilter = .all
        if let first = items.first {
            selectBatchReadItem(first)
        }
        appState.showToast("已加载批量测序验证示范：\(summaries.count) 个克隆 (\(items.count) 条 Reads)")
    }

    private func selectSangerFileFromFinder() {
        let panel = NSOpenPanel()
        panel.title = "选择 Sanger 测序峰图文件或包含多个 .ab1 的文件夹"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        var allowed: [UTType] = [.plainText, .data, .folder]
        for ext in ["ab1", "abi", "seq", "fa", "fasta", "txt"] {
            if let t = UTType(filenameExtension: ext) {
                allowed.append(t)
            }
        }
        panel.allowedContentTypes = allowed
        if panel.runModal() == .OK {
            handleOpenedOrDroppedURLs(panel.urls)
        }
    }

    private func handleOpenedOrDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if urls.count == 1, urls[0].pathExtension.lowercased() == "dna" {
            loadReferenceDNAFile(urls[0])
            return
        }
        let expanded = SangerBatchEngine.expandInputURLs(urls)
        if expanded.count > 1 {
            startBatchVerification(urls: expanded)
        } else if let single = expanded.first {
            loadSangerFile(from: single)
        }
    }

    private func buildReferenceCandidates() -> [SangerBatchEngine.SangerReferenceCandidate] {
        var list: [SangerBatchEngine.SangerReferenceCandidate] = []
        let cdsStart = Int(cdsStart1BasedText.trimmingCharacters(in: .whitespaces))
        list.append(
            SangerBatchEngine.SangerReferenceCandidate(
                id: selectedPoolPlasmidID.isEmpty ? referenceName : selectedPoolPlasmidID,
                name: referenceName,
                sequence: referenceSequence,
                cdsStart1Based: cdsStart
            )
        )
        for item in poolManager.items {
            if item.name != referenceName {
                let firstCDS = item.dnaInfo.features.first(where: { $0.type == "CDS" })?.segments.first?.start
                list.append(
                    SangerBatchEngine.SangerReferenceCandidate(
                        id: item.id,
                        name: item.name,
                        sequence: item.dnaInfo.sequence,
                        cdsStart1Based: firstCDS
                    )
                )
            }
        }
        return list
    }

    private func startBatchVerification(urls: [URL]) {
        batchTask?.cancel()
        isBatchRunning = true
        batchProgressDone = 0
        batchProgressTotal = urls.count
        let candidates = buildReferenceCandidates()
        let regex = appState.defaultSangerCloneGroupingPattern
        let trimQ = Int(trimQualityThreshold)

        batchTask = Task {
            let result = await SangerBatchEngine.verifyBatch(
                urls: urls,
                candidates: candidates,
                primerSuffixRegex: regex,
                trimQualityThreshold: trimQ,
                maxConcurrency: 4
            ) { done, total in
                Task { @MainActor in
                    self.batchProgressDone = done
                    self.batchProgressTotal = total
                }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                self.isBatchRunning = false
                self.batchResult = result
                self.batchFilter = .all
                if let first = result.reads.first {
                    self.selectBatchReadItem(first)
                }
                self.appState.showToast("批量验证完成：共 \(result.cloneSummaries.count) 个克隆 (\(result.reads.count) 条测序读长)")
            }
        }
    }

    private func selectBatchReadItem(_ item: SangerBatchEngine.BatchReadItem) {
        self.chromatogram = item.report.chromatogram
        self.report = item.report
        if let firstVar = item.report.variants.first?.readPos1Based {
            selectedReadPos1Based = firstVar
            scrollTargetReadPos1 = firstVar
        } else {
            selectedReadPos1Based = item.report.chromatogram.trimStart0 + 1
        }
    }

    private func filteredCloneSummaries(_ res: SangerBatchEngine.BatchVerificationResult) -> [SangerBatchEngine.CloneBatchSummary] {
        switch batchFilter {
        case .all:
            return res.cloneSummaries
        case .pass:
            return res.cloneSummaries.filter { $0.verdict == .pass }
        case .needsReview:
            return res.cloneSummaries.filter { $0.verdict == .needsReview || $0.verdict == .unmatched }
        case .failed:
            return res.cloneSummaries.filter { $0.verdict == .failed }
        }
    }

    private func filterTitle(_ f: CloneBatchFilter, in res: SangerBatchEngine.BatchVerificationResult) -> String {
        switch f {
        case .all:
            return "全部 (\(res.cloneSummaries.count))"
        case .pass:
            return "通过 (\(res.cloneSummaries.filter { $0.verdict == .pass }.count))"
        case .needsReview:
            return "复核 (\(res.cloneSummaries.filter { $0.verdict == .needsReview || $0.verdict == .unmatched }.count))"
        case .failed:
            return "失败 (\(res.cloneSummaries.filter { $0.verdict == .failed }.count))"
        }
    }

    private func filterTint(_ f: CloneBatchFilter) -> Color {
        switch f {
        case .all:         return .blue
        case .pass:        return .green
        case .needsReview: return .orange
        case .failed:      return .red
        }
    }

    private func colorForBatchVerdict(_ v: SangerBatchEngine.CloneBatchVerdict) -> Color {
        switch v {
        case .pass:        return .green
        case .needsReview: return .orange
        case .failed:      return .red
        case .unmatched:   return .secondary
        }
    }

    private func exportBatchSummaryCSV(_ res: SangerBatchEngine.BatchVerificationResult) {
        let csv = SangerBatchEngine.exportBatchSummaryCSV(res)
        let trimQ = Int(trimQualityThreshold)
        let regex = appState.defaultSangerCloneGroupingPattern
        let cands = buildReferenceCandidates()
        FinderFileDropHelper.saveTextToFile(
            content: csv,
            defaultFileName: "batch_summary.csv",
            contentType: .commaSeparatedText,
            toastPrefix: "已导出 Sanger 批量汇总表与 .run.json 溯源记录"
        ) { savedURL in
            let run = SangerBatchEngine.buildBatchAnalysisRun(
                batchResult: res,
                candidates: cands,
                trimQualityThreshold: trimQ,
                primerSuffixRegex: regex,
                outputs: [savedURL.lastPathComponent],
                exportDirectoryURL: savedURL.deletingLastPathComponent()
            )
            _ = try? run.writeSidecarJSON(alongsideOutputURL: savedURL)
        }
    }

    private func loadSangerFile(from url: URL) {
        do {
            let rec = try SangerAlignmentEngine.parseFile(at: url, trimQualityThreshold: Int(trimQualityThreshold))
            self.chromatogram = rec
            recomputeVerification()
            if let firstVar = report?.variants.first?.readPos1Based {
                selectedReadPos1Based = firstVar
                scrollTargetReadPos1 = firstVar
            }
            appState.showToast("已载入测序文件「\(rec.sampleName)」(\(rec.rawLength) bp)")
        } catch {
            appState.showToast("读取测序文件失败：\(error.localizedDescription)")
        }
    }

    private func loadReferenceDNAFile(_ url: URL) {
        Task {
            do {
                let info = try await SnapGeneService.shared.parseDNAFile(at: url)
                await MainActor.run {
                    self.selectedPoolPlasmidID = poolManager.items.first(where: { $0.dnaInfo.filePath == url.path })?.id ?? url.path
                    self.referenceName = url.deletingPathExtension().lastPathComponent
                    self.referenceSequence = info.sequence
                    if let cds = info.features.first(where: { $0.type == "CDS" }),
                       let start = cds.segments.first?.start {
                        self.cdsStart1BasedText = "\(start)"
                    }
                    self.recomputeVerification()
                    appState.showToast("已载入参考质粒「\(self.referenceName)」(\(info.length) bp)")
                }
            } catch {
                await MainActor.run {
                    appState.showToast("解析参考 .dna 失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func rerunAlignmentWithCurrentQuality() {
        guard let old = chromatogram else { return }
        if let path = old.filePath, FileManager.default.fileExists(atPath: path),
           let updated = try? SangerAlignmentEngine.parseFile(at: URL(fileURLWithPath: path), trimQualityThreshold: Int(trimQualityThreshold)) {
            self.chromatogram = updated
        } else {
            let synthetic = SangerAlignmentEngine.generateSyntheticAB1Data(
                sequence: old.rawSequence,
                sampleName: old.sampleName,
                simulateNoisyEnds: true
            )
            self.chromatogram = SangerAlignmentEngine.parseData(
                synthetic,
                sampleName: old.sampleName,
                trimQualityThreshold: Int(trimQualityThreshold)
            )
        }
        recomputeVerification()
    }

    private func recomputeVerification() {
        guard let chrom = chromatogram else { return }
        let cdsStart = Int(cdsStart1BasedText.trimmingCharacters(in: .whitespaces))
        self.report = SangerAlignmentEngine.verifyAgainstPlasmid(
            chromatogram: chrom,
            referenceSequence: referenceSequence,
            referenceName: referenceName,
            cdsStart1Based: cdsStart
        )
    }

    private func copyVerificationSummary() {
        guard let rep = report else { return }
        let text = SangerAlignmentEngine.formatVerificationReportText(rep)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        appState.showToast("已复制 Sanger 测序质检报告到剪贴板")
    }

    private func exportVerificationReport() {
        guard let rep = report else { return }
        let refSeq = referenceSequence
        let trimQ = Int(trimQualityThreshold)
        let text = SangerAlignmentEngine.formatVerificationReportText(rep)
        let safeSample = (rep.chromatogram.sampleName as NSString).deletingPathExtension
        let linkedIDs: [String] = {
            if !selectedPoolPlasmidID.isEmpty {
                return [selectedPoolPlasmidID]
            }
            if let matched = poolManager.items.first(where: { $0.name == referenceName }) {
                return [matched.id]
            }
            return []
        }()
        FinderFileDropHelper.saveTextToFile(
            content: text,
            defaultFileName: "\(safeSample)_Sanger验证报告.txt",
            contentType: .plainText,
            toastPrefix: "已导出 Sanger 验证报告与 .run.json 溯源记录"
        ) { savedURL in
            let run = SangerAlignmentEngine.buildSangerAnalysisRun(
                report: rep,
                referenceSequence: refSeq,
                trimQualityThreshold: trimQ,
                secondaryPeakThreshold: 0.30,
                outputs: [savedURL.lastPathComponent],
                exportDirectoryURL: savedURL.deletingLastPathComponent(),
                linkedPlasmidIDs: linkedIDs
            )
            _ = try? run.writeSidecarJSON(alongsideOutputURL: savedURL)
        }
    }

    private func formatAlignmentBlock(_ rep: SangerAlignmentEngine.VerificationReport) -> String {
        let cols = rep.columns
        guard !cols.isEmpty else { return "" }
        let chunkSize = 60
        var out: [String] = []
        for start in stride(from: 0, to: cols.count, by: chunkSize) {
            let end = min(cols.count, start + chunkSize)
            let slice = cols[start..<end]
            let refStr = String(slice.map(\.refBase))
            let midStr = String(slice.map { col -> Character in
                switch col.eventKind {
                case .match: return "|"
                case .doublePeak: return ":"
                case .mismatchSNP: return "*"
                case .insertion, .deletion: return "^"
                }
            })
            let qryStr = String(slice.map(\.readBase))
            let rStart = slice.first?.refPos1Based ?? 1
            let rEnd = slice.last?.refPos1Based ?? 1
            let qStart = slice.compactMap(\.readPos1Based).first ?? 1
            let qEnd = slice.compactMap(\.readPos1Based).last ?? 1
            out.append(String(format: "Ref  %5d  %@  %-5d", rStart, refStr, rEnd))
            out.append(String(format: "            %@", midStr))
            out.append(String(format: "Read %5d  %@  %-5d\n", qStart, qryStr, qEnd))
        }
        return out.joined(separator: "\n")
    }

    private func shortVerdictTitle(_ v: SangerAlignmentEngine.VerificationVerdict) -> String {
        switch v {
        case .verifiedPass:      return "100% 匹配通过"
        case .pointMutation:     return "检出点突变 SNP"
        case .indelOrFrameshift: return "检出移码 Indel"
        case .doublePeakWarning: return "检出杂合双峰"
        case .unaligned:         return "未匹配参考序列"
        }
    }

    private func colorForVerdict(_ v: SangerAlignmentEngine.VerificationVerdict) -> Color {
        switch v {
        case .verifiedPass:      return .green
        case .pointMutation:     return .orange
        case .indelOrFrameshift: return .red
        case .doublePeakWarning: return .purple
        case .unaligned:         return .secondary
        }
    }

    private func colorForEvent(_ e: SangerAlignmentEngine.AlignmentEventKind) -> Color {
        switch e {
        case .match:       return .green
        case .mismatchSNP: return .orange
        case .insertion:   return .red
        case .deletion:    return .red
        case .doublePeak:  return .purple
        }
    }
}

// MARK: - 四色荧光毛细管电泳色谱条画布 (ChromatogramTraceStripView)

private struct ChromatogramTraceStripView: View {
    let chromatogram: SangerAlignmentEngine.ChromatogramRecord
    let report: SangerAlignmentEngine.VerificationReport?
    let baseColumnWidth: CGFloat
    let showA: Bool
    let showC: Bool
    let showG: Bool
    let showT: Bool
    @Binding var selectedReadPos1: Int?

    var body: some View {
        let peaks = chromatogram.calledPeaks
        let totalWidth = max(640, CGFloat(max(1, peaks.count)) * baseColumnWidth + 24)
        let refMap = buildReadToColumnMap()

        ZStack(alignment: .topLeading) {
            // 1. 底层四色连续荧光曲线 Canvas
            Canvas { context, size in
                let topHeaderH: CGFloat = 68
                let traceAreaH = max(80, size.height - topHeaderH - 18)
                let baselineY = topHeaderH + traceAreaH - 6
                let maxSig = CGFloat(max(200, chromatogram.maxTraceSignal))

                // 绘制修剪区淡灰背景阴影
                let trimLeftX = CGFloat(chromatogram.trimStart0) * baseColumnWidth + 12
                let trimRightX = CGFloat(chromatogram.trimEnd0) * baseColumnWidth + 12
                if trimLeftX > 12 {
                    let leftRect = CGRect(x: 0, y: 0, width: trimLeftX, height: size.height)
                    context.fill(Path(leftRect), with: .color(Color.secondary.opacity(0.09)))
                }
                if trimRightX < size.width {
                    let rightRect = CGRect(x: trimRightX, y: 0, width: size.width - trimRightX, height: size.height)
                    context.fill(Path(rightRect), with: .color(Color.secondary.opacity(0.09)))
                }

                // 绘制变异与选中位点高亮竖带
                for pk in peaks {
                    let centerX = CGFloat(pk.id - 1) * baseColumnWidth + 12 + baseColumnWidth * 0.5
                    let colRect = CGRect(x: centerX - baseColumnWidth * 0.5, y: 0, width: baseColumnWidth, height: size.height)
                    if let col = refMap[pk.id], col.eventKind != .match {
                        let c: Color = (col.eventKind == .doublePeak) ? .purple : ((col.eventKind == .mismatchSNP) ? .orange : .red)
                        context.fill(Path(colRect), with: .color(c.opacity(0.15)))
                    }
                    if selectedReadPos1 == pk.id {
                        context.fill(Path(colRect), with: .color(Color.accentColor.opacity(0.18)))
                    }
                }

                // 将采样点下标映射为水平 X 坐标（按相邻峰值分段线性插值，保证每个峰尖严格对齐碱基列中央）
                func xForTraceIndex(_ tIdx: Int) -> CGFloat {
                    guard !peaks.isEmpty else { return 12 }
                    if tIdx <= peaks[0].traceIndex {
                        let step = max(1, peaks.count > 1 ? peaks[1].traceIndex - peaks[0].traceIndex : 10)
                        let frac = CGFloat(tIdx - peaks[0].traceIndex) / CGFloat(step)
                        return 12 + baseColumnWidth * 0.5 + frac * baseColumnWidth
                    }
                    if let last = peaks.last, tIdx >= last.traceIndex {
                        let step = max(1, peaks.count > 1 ? last.traceIndex - peaks[peaks.count - 2].traceIndex : 10)
                        let frac = CGFloat(tIdx - last.traceIndex) / CGFloat(step)
                        return 12 + (CGFloat(peaks.count - 1) + 0.5 + frac) * baseColumnWidth
                    }
                    // 二分查找区间
                    var lo = 0
                    var hi = peaks.count - 1
                    while lo + 1 < hi {
                        let mid = (lo + hi) / 2
                        if peaks[mid].traceIndex <= tIdx {
                            lo = mid
                        } else {
                            hi = mid
                        }
                    }
                    let t0 = peaks[lo].traceIndex
                    let t1 = max(t0 + 1, peaks[hi].traceIndex)
                    let frac = CGFloat(tIdx - t0) / CGFloat(t1 - t0)
                    return 12 + (CGFloat(lo) + 0.5 + frac) * baseColumnWidth
                }

                func drawChannel(_ values: [Int], color: Color) {
                    guard values.count > 1 else { return }
                    var path = Path()
                    for (idx, val) in values.enumerated() {
                        let x = xForTraceIndex(idx)
                        let norm = min(1.0, CGFloat(max(0, val)) / maxSig)
                        let y = baselineY - norm * (traceAreaH - 12)
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(path, with: .color(color), lineWidth: 1.45)
                }

                if showG { drawChannel(chromatogram.traceG, color: Color.primary.opacity(0.82)) }
                if showA { drawChannel(chromatogram.traceA, color: .green) }
                if showT { drawChannel(chromatogram.traceT, color: .red) }
                if showC { drawChannel(chromatogram.traceC, color: .blue) }
            }
            .frame(width: totalWidth, height: 255)

            // 2. 顶层可点击碱基列与 ScrollViewReader 锚点行
            HStack(spacing: 0) {
                Spacer().frame(width: 12)
                ForEach(peaks) { pk in
                    let colInfo = refMap[pk.id]
                    VStack(spacing: 2) {
                        // 读长位置刻度（每 10 bp 显示一次）
                        if pk.id == 1 || pk.id % 10 == 0 {
                            Text("\(pk.id)")
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        } else {
                            Text(" ")
                                .font(.system(size: 8.5, design: .monospaced))
                        }

                        // Phred Q 值柱状条
                        let qNorm = CGFloat(min(60, max(4, pk.phredQuality))) / 60.0
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(pk.isTrimmed ? Color.secondary.opacity(0.28) : (pk.phredQuality >= 30 ? Color.green.opacity(0.65) : (pk.phredQuality >= 20 ? Color.orange.opacity(0.65) : Color.red.opacity(0.65))))
                            .frame(width: max(4, baseColumnWidth * 0.52), height: max(3, 18 * qNorm))
                            .frame(height: 18, alignment: .bottom)

                        // 测序识别碱基
                        Text(String(pk.base))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(colorForBase(pk.base, isTrimmed: pk.isTrimmed))

                        // 参考序列对比行
                        if let col = colInfo {
                            if col.eventKind == .match {
                                Text("·")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            } else {
                                Text(String(col.refBase))
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .frame(width: max(12, baseColumnWidth - 2), height: 13)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(col.eventKind == .doublePeak ? Color.purple : (col.eventKind == .mismatchSNP ? Color.orange : Color.red))
                                    )
                            }
                        } else {
                            Text(pk.isTrimmed ? "✂" : " ")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary.opacity(0.5))
                        }

                        Spacer()
                    }
                    .frame(width: baseColumnWidth, height: 250)
                    .contentShape(Rectangle())
                    .id("sanger-peak-\(pk.id)")
                    .onTapGesture {
                        selectedReadPos1 = pk.id
                    }
                }
                Spacer().frame(width: 12)
            }
        }
    }

    private func buildReadToColumnMap() -> [Int: SangerAlignmentEngine.AlignedColumn] {
        guard let rep = report else { return [:] }
        var dict: [Int: SangerAlignmentEngine.AlignedColumn] = [:]
        for col in rep.columns {
            if let rPos = col.readPos1Based {
                dict[rPos] = col
            }
        }
        return dict
    }

    private func colorForBase(_ b: Character, isTrimmed: Bool) -> Color {
        let alpha = isTrimmed ? 0.42 : 1.0
        switch b {
        case "A": return Color.green.opacity(alpha)
        case "C": return Color.blue.opacity(alpha)
        case "G": return Color.primary.opacity(alpha)
        case "T": return Color.red.opacity(alpha)
        default:  return Color.secondary.opacity(alpha)
        }
    }
}
