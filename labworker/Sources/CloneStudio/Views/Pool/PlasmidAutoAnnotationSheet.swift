import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// 离线质粒自动注释工作台弹窗（调用 `PlasmidAnnotationEngine` 与千级本地 `Libraries.sqlite` 元件库）
public struct PlasmidAutoAnnotationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var pool = PlasmidPoolManager.shared

    public let existingItemID: String?

    @State private var plasmidName: String
    @State private var rawFastaText: String
    @State private var isCircular: Bool
    @State private var minIdentity: Double = 0.85
    @State private var categoryFilter: String = "全部"
    @State private var libraryFeatureCount: Int = 0
    @State private var isAnnotating: Bool = false
    @State private var report: PlasmidAnnotationEngine.PlasmidAnnotationReport? = nil

    public init(initialItem: PlasmidPoolItem? = nil) {
        self.existingItemID = initialItem?.id
        _plasmidName = State(initialValue: initialItem?.name ?? "Unknown_Vector")
        _rawFastaText = State(initialValue: initialItem?.dnaInfo.sequence ?? "")
        _isCircular = State(initialValue: initialItem?.dnaInfo.isCircular ?? true)
    }

    private var previewData: PlasmidConstructPreviewData? {
        guard let rep = report else { return nil }
        let (_, seq) = PlasmidAnnotationEngine.parseFASTA(rawFastaText, defaultName: plasmidName)
        let info = SnapGeneFileInfo(
            filePath: existingItemID ?? "annotated://preview",
            fileName: "\(rep.plasmidName).fasta",
            sequence: seq,
            length: seq.count,
            isCircular: rep.isCircular,
            featuresCount: rep.featuresCount,
            features: rep.toSnapGeneFeatures(),
            primersCount: 0,
            primers: []
        )
        return PlasmidMapBuilder.forRawSnapGeneFile(info: info, highlightRange: nil)
    }

    private var categories: [String] {
        guard let rep = report else { return ["全部"] }
        let unique = Array(Set(rep.features.map(\.category))).sorted()
        return ["全部"] + unique
    }

    private var filteredFeatures: [PlasmidAnnotationEngine.AnnotatedFeature] {
        guard let rep = report else { return [] }
        if categoryFilter == "全部" { return rep.features }
        return rep.features.filter { $0.category == categoryFilter }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    inputCard
                    actionRow
                    if let rep = report {
                        resultSection(rep)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 820, idealWidth: 960, minHeight: 620, idealHeight: 720)
        .background(StudioPalette.workspaceBg(isLight: appState.isLightAppearance))
        .onAppear {
            Task.detached(priority: .userInitiated) {
                let cnt = PlasmidAnnotationEngine.loadFeaturesFromSQLite().count
                await MainActor.run {
                    libraryFeatureCount = cnt
                }
            }
            if !rawFastaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && report == nil {
                runAnnotation()
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("离线质粒 FASTA 自动注释"))
                    .font(.system(size: 15, weight: .bold))
                Text(L10n.tr("基于本地 Libraries.sqlite 元件库（已载入 \(libraryFeatureCount) 条标准质粒特征），支持双链扫描、跨 Origin 与 Fragment 预警", "Powered by local Libraries.sqlite feature database (\(libraryFeatureCount) curated features); supports dual-strand scan, Origin-spanning & remnant fragment warnings."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StudioActionPillButton(title: "关闭", icon: "xmark") {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var inputCard: some View {
        StudioCard(title: "待注释序列输入") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                StudioActionPillButton(title: "打开 FASTA", icon: "folder.badge.plus", tint: .blue) {
                    openFASTAFile()
                }
                StudioActionPillButton(title: "载入示例", icon: "sparkles") {
                    loadDemoFASTA()
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                    HStack(spacing: 6) {
                        Text(L10n.t("质粒名称:"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField(L10n.t("质粒名称"), text: $plasmidName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .frame(width: 210)
                    }

                    Toggle(L10n.t("环状质粒 (跨 Origin 扫描)"), isOn: $isCircular)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    HStack(spacing: 6) {
                        Text(L10n.t("最低一致率:"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Slider(value: $minIdentity, in: 0.75...0.98, step: 0.01)
                            .frame(width: 110)
                        Text("\(Int(round(minIdentity * 100)))%")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.purple)
                    }
                }

                SequenceEditorBox(
                    text: $rawFastaText,
                    placeholder: L10n.t("粘贴 >FASTA 文本或纯 DNA 序列（ATGCG...）"),
                    minHeight: 100
                )
            }
        }
    }

    private var actionRow: some View {
        StudioActionBar {
            StudioPrimaryActionButton(
                title: "开始离线注释",
                icon: "wand.and.stars",
                tint: .purple,
                isLoading: isAnnotating,
                action: runAnnotation
            )

            if let rep = report {
                StudioActionPillButton(
                    title: existingItemID != nil ? "更新至质粒池" : "保存至质粒池",
                    icon: "tray.and.arrow.down.fill",
                    tint: .green,
                    isProminent: true
                ) {
                    saveToPool(rep)
                }
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ rep: PlasmidAnnotationEngine.PlasmidAnnotationReport) -> some View {
        StudioCard(title: L10n.tr("注释结果：\(rep.plasmidName)", "Annotation Report: \(rep.plasmidName)")) {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                StudioMetricBadge(label: L10n.t("命中特征"), value: L10n.tr("\(rep.featuresCount) 个", "\(rep.featuresCount)"), color: .purple)
                StudioMetricBadge(
                    label: L10n.t("覆盖率"),
                    value: String(format: "%.1f%%", rep.annotatedCoveragePercent),
                    color: .blue
                )
                StudioMetricBadge(
                    label: L10n.t("跨零点"),
                    value: "\(rep.originSpanningCount)",
                    color: rep.originSpanningCount > 0 ? .teal : .secondary
                )
                StudioMetricBadge(
                    label: L10n.t("残留片段"),
                    value: "\(rep.fragmentCount)",
                    color: rep.fragmentCount > 0 ? .orange : .green
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if !rep.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rep.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioInnerBox(tint: .orange, paddingH: 10, paddingV: 8)
                }

                AdaptiveTwoColumnWorkspace(breakpoint: 720, hasRight: previewData != nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            ForEach(categories, id: \.self) { cat in
                                StudioCompactPillButton(
                                    title: cat == "全部" ? L10n.t("全部") : cat,
                                    tint: .purple,
                                    isSelected: categoryFilter == cat
                                ) {
                                    categoryFilter = cat
                                }
                            }
                        }

                        if filteredFeatures.isEmpty {
                            Text(L10n.t("当前筛选条件下未命中特征元件"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 6) {
                                    ForEach(filteredFeatures) { feat in
                                        HStack(spacing: 8) {
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .fill(Color(hexString: feat.colorHex))
                                                .frame(width: 4, height: 28)

                                            VStack(alignment: .leading, spacing: 2) {
                                                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 3) {
                                                    Text(feat.displayName)
                                                        .font(.system(size: 12.5, weight: .bold))
                                                    Text(feat.category)
                                                        .font(.system(size: 10, weight: .semibold))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 1.5)
                                                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.07)))
                                                    if feat.isFragment {
                                                        StudioMetricBadge(label: "Fragment", value: "\(Int(round(feat.coverage * 100)))%", color: .orange)
                                                    }
                                                    if feat.isOriginSpanning {
                                                        StudioMetricBadge(label: "", value: "跨 Origin", color: .teal)
                                                    }
                                                }
                                                Text(L10n.tr("\(feat.start1Based)..\(feat.end1Based) (\(feat.strand)链) · 长度 \(feat.matchedLength)/\(feat.referenceLength) bp · 一致率 \(String(format: "%.1f%%", feat.identity * 100))", "\(feat.start1Based)..\(feat.end1Based) (\(feat.strand) strand) · Length \(feat.matchedLength)/\(feat.referenceLength) bp · Identity \(String(format: "%.1f%%", feat.identity * 100))"))
                                                    .font(.system(size: 11))
                                                    .monospacedDigit()
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .studioInnerBox(paddingH: 9, paddingV: 6)
                                    }
                                }
                            }
                            .frame(minHeight: 220, maxHeight: 340)
                        }
                    }
                } right: {
                    if let pData = previewData {
                        PlasmidPreviewPanel(data: pData, onClose: nil)
                    }
                }
            }
        }
    }

    private func runAnnotation() {
        let trimmed = rawFastaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appState.showToast("请先输入或打开待注释 FASTA / DNA 序列")
            return
        }
        let defaultN = plasmidName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown_Vector" : plasmidName
        let circ = isCircular
        let minId = minIdentity

        isAnnotating = true
        Task.detached(priority: .userInitiated) {
            let res = PlasmidAnnotationEngine.annotateFASTA(
                trimmed,
                defaultName: defaultN,
                isCircular: circ,
                minIdentity: minId
            )
            let libCnt = PlasmidAnnotationEngine.loadFeaturesFromSQLite().count
            await MainActor.run {
                self.isAnnotating = false
                self.report = res
                self.libraryFeatureCount = libCnt
                self.categoryFilter = "全部"
                if !res.plasmidName.isEmpty && trimmed.hasPrefix(">") {
                    self.plasmidName = res.plasmidName
                }
            }
        }
    }

    private func saveToPool(_ rep: PlasmidAnnotationEngine.PlasmidAnnotationReport) {
        let (_, cleanSeq) = PlasmidAnnotationEngine.parseFASTA(rawFastaText, defaultName: plasmidName)
        guard !cleanSeq.isEmpty else { return }
        let saved = pool.upsertAnnotatedPlasmid(
            existingItemID: existingItemID,
            name: plasmidName.isEmpty ? rep.plasmidName : plasmidName,
            sequence: cleanSeq,
            isCircular: rep.isCircular,
            features: rep.toSnapGeneFeatures()
        )
        appState.showToast(L10n.tr("已将「\(saved.name)」(\(rep.featuresCount) 个注释特征) 保存至质粒池", "Saved \"\(saved.name)\" (\(rep.featuresCount) annotated features) to Plasmid Pool"))
        dismiss()
    }

    private func openFASTAFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("选择 FASTA / 序列文件 (.fa / .fasta / .seq / .txt)")
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText]
        for ext in ["fa", "fasta", "seq", "txt"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        panel.begin { resp in
            guard resp == .OK, let url = panel.url,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            self.rawFastaText = text
            let (parsedName, _) = PlasmidAnnotationEngine.parseFASTA(text, defaultName: url.deletingPathExtension().lastPathComponent)
            self.plasmidName = parsedName
            self.runAnnotation()
        }
    }

    private func loadDemoFASTA() {
        plasmidName = "Unknown_pT7_EGFP_Kan_Demo"
        isCircular = true
        rawFastaText = """
>Unknown_pT7_EGFP_Kan_Demo
GCTAGCTAATACGACTCACTATAGGGGGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAAGACTACAAAGACCATGACGGTGATTATAAAGATCATGACATCGACTACAAGGATGACGATGACAAGTAGGCGGCCGCATGAATATGGATTGCATATGAGCCATATTCAACGGGAAACGTCTTGCTCGAGGCCGCGATTAAATTCCAACATGGATGCTGATTTATATGGGTATAAATGGGCTCGCGATAATGTCGGGCAATCAGGTGCGACAATCTATCGCTTGTATGGGAAGCCCGATGCGCCAGAGTTGTTTCTGAAACATGGCAAAGGTAGCGTTGCCAATGATGTTACAGATGAGATGGTCAGACTAAACTGGCTGACGGAATTTATGCCTCTTCCGACCATCAAGCATTTTATCCGTACTCCTGATGATGCATGGTTACTCACCACTGCGATCCCCGGAAAAACAGCATTCCAGGTATTAGAAGAATATCCTGATTCAGGTGAAAATATTGTTGATGCGCTGGCAGTGTTCCTGCGCCGGTTGCATTCGATTCCTGTTTGTAATTGTCCTTTTAACAGCGATCGCGTATTTCGTCTCGCTCAGGCGCAATCACGAATGAATAACGGTTTGGTTGATGCGAGTGATTTTGATGACGAGCGTAATGGCTGGCCTGTTGAACAAGTCTGGAAAGAAATGCATAAACTTTTGCCATTCTCACCGGATTCAGTCGTCACTCATGGTGATTTCTCACTTGATAACCTTATTTTTGACGAGGGGAAATTAATAGGTTGTATTGATGTTGGACGAGTCGGAATCGCAGACCGATACCAGGATCTTGCCATCCTATGGAACTGCCTCGGTGAGTTTTCTCCTTCATTACAGAAACGGCTTTTTCAAAAATATGGTATTGATAATCCTGATATGAATAAATTGCAGTTTCATTTGATGCTCGATGAGTTTTTCTAATTGGCCAGCTTGGCGTAATCATGGTCATAGCTGTTTCCTGTTGAGATCCTTTTTTTCTGCGCGTAATCTGCTGCTTGCAAACAAAAAAACCACCGCTACCAGCGGTGGTTTGTTTGCCGGATCAAGAGCTACCAACTCTTTTTCCGAAGGTAACTGGCTTCAGCAGAGCGCAGATACCAAATACTGTTCTTCTAGTGTAGCCGTAGTTAGGCCACCACTTCAAGAACTCTGTAGCACCGCCTACATACCTCGCTCTGCTAATCCTGTTACCAGTGGCTGCTGCCAGTGGCGATAAGTCGTGTCTTACCGGGTTGGACTCAAGACGATAGTTACCGGATAAGGCGCAGCGGTCGGGCTGAACGGGGGGTTCGTGCACACAGCCCAGCTTGGAGCGAACGACCTACACCGAACTGAGATACCTACAGCGTGAGCTATGAGAAAGCGCCACGCTTCCCGAAGGGAGAAAGGCGGACAGGTATCCGGTAAGCGGCAGGGTCGGAACAGGAGAGCGCACGAGGGAGCTTCCAGGGGGAAACGCCTGGTATCTTTATAGTCCTGTCGGGTTTCGCCACCTCTGACTTGAGCGTCGATTTTTGTGATGCTCGTCAGGGGGGCGGAGCCTATGGAAAAACGCCAGCAACGC
"""
        runAnnotation()
    }
}
