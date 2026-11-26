import SwiftUI
import CloneStudioCore

/// 诊断性限制酶切 Top 3 智能推荐弹窗（调用 `DiagnosticDigestEngine`，可嵌入质粒池与凝胶电泳工作台）
public struct DiagnosticDigestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var pool = PlasmidPoolManager.shared

    public let onApplyToGel: (([String]) -> Void)?

    @State private var selectedEmptyID: String = "__manual__"
    @State private var selectedRecombID: String = "__manual__"
    @State private var emptySeqText: String = ""
    @State private var recombSeqText: String = ""
    @State private var isManualDrawerExpanded: Bool = false
    @State private var isCircular: Bool = true
    @State private var minBands: Int = 2
    @State private var maxBands: Int = 4
    @State private var report: DiagnosticDigestEngine.DiagnosticDigestReport? = nil
    @State private var selectedRank: Int = 1

    public init(
        initialEmptyPlasmidID: String? = nil,
        initialRecombinantPlasmidID: String? = nil,
        onApplyToGel: (([String]) -> Void)? = nil
    ) {
        self.onApplyToGel = onApplyToGel
        let items = PlasmidPoolManager.shared.items
        if let eID = initialEmptyPlasmidID, items.contains(where: { $0.id == eID }) {
            _selectedEmptyID = State(initialValue: eID)
        } else if let first = items.first {
            _selectedEmptyID = State(initialValue: first.id)
        }
        if let rID = initialRecombinantPlasmidID, items.contains(where: { $0.id == rID }) {
            _selectedRecombID = State(initialValue: rID)
        } else if items.count >= 2 {
            _selectedRecombID = State(initialValue: items[1].id)
        } else if let first = items.first {
            _selectedRecombID = State(initialValue: first.id)
        }
    }

    private var emptyPickerOptions: [StudioMenuPickerOption<String>] {
        pool.items.map { StudioMenuPickerOption(value: $0.id, title: $0.name) }
            + [StudioMenuPickerOption(value: "__manual__", title: "手动输入序列")]
    }

    private var activeRecommendation: DiagnosticDigestEngine.DiagnosticDigestRecommendation? {
        guard let rep = report else { return nil }
        return rep.topRecommendations.first(where: { $0.rank == selectedRank }) ?? rep.topRecommendations.first
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "scissors.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("克隆鉴定最佳单/双内切酶推荐"))
                        .font(.system(size: 15, weight: .bold))
                    Text(L10n.t("枚举 24 种常用克隆内切酶与 NEB CutSmart/r2.1/r3.1/r1.1 Buffer 兼容矩阵，筛选电泳分辨率差异最大的 Top 3 方案"))
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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    selectionCard
                    actionRow
                    if let rep = report {
                        resultSection(rep)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 800, idealWidth: 940, minHeight: 600, idealHeight: 700)
        .background(StudioPalette.workspaceBg(isLight: appState.isLightAppearance))
        .onAppear {
            syncSequencesFromSelection()
            if pool.items.count < 2 && emptySeqText.isEmpty {
                loadDemoSequences()
            } else if !emptySeqText.isEmpty && !recombSeqText.isEmpty {
                runRecommendation()
            }
        }
    }

    private var selectionCard: some View {
        StudioCard(title: "阴性对照 (空载) 与 阳性目标 (重组) 载体") {
            StudioActionPillButton(title: "载入示例对照", icon: "sparkles") {
                loadDemoSequences()
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                    StudioMenuPicker(
                        selection: $selectedEmptyID,
                        options: emptyPickerOptions,
                        prefix: "阴性空载",
                        icon: "circle.dashed",
                        tint: .blue
                    )
                    .onChange(of: selectedEmptyID) { _, _ in
                        syncSequencesFromSelection()
                    }

                    StudioMenuPicker(
                        selection: $selectedRecombID,
                        options: emptyPickerOptions,
                        prefix: "阳性重组",
                        icon: "circle.circle.fill",
                        tint: .teal
                    )
                    .onChange(of: selectedRecombID) { _, _ in
                        syncSequencesFromSelection()
                    }

                    Toggle(L10n.t("环状质粒"), isOn: $isCircular)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    StudioMenuPicker(
                        selection: $maxBands,
                        options: [
                            StudioMenuPickerOption(value: 3, title: "2–3 条带"),
                            StudioMenuPickerOption(value: 4, title: "2–4 条带"),
                            StudioMenuPickerOption(value: 5, title: "2–5 条带")
                        ],
                        prefix: "条带数",
                        compact: true
                    )

                    StudioCompactPillButton(
                        title: isManualDrawerExpanded ? "收起序列" : "手动编辑序列",
                        icon: isManualDrawerExpanded ? "chevron.up" : "chevron.down"
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isManualDrawerExpanded.toggle()
                        }
                    }
                }

                if isManualDrawerExpanded || selectedEmptyID == "__manual__" || selectedRecombID == "__manual__" {
                    AdaptiveTwoColumnWorkspace(breakpoint: 680, hasRight: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("空载对照序列 (\(BioSequence.clean(emptySeqText).count) bp)", "Empty Vector Control (\(BioSequence.clean(emptySeqText).count) bp)"))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            SequenceEditorBox(text: $emptySeqText, placeholder: L10n.t("输入空载 DNA 序列..."), minHeight: 75)
                        }
                    } right: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("重组阳性序列 (\(BioSequence.clean(recombSeqText).count) bp)", "Recombinant Positive (\(BioSequence.clean(recombSeqText).count) bp)"))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            SequenceEditorBox(text: $recombSeqText, placeholder: L10n.t("输入重组质粒 DNA 序列..."), minHeight: 75)
                        }
                    }
                }
            }
        }
    }

    private var actionRow: some View {
        StudioActionBar {
            StudioPrimaryActionButton(
                title: "推荐 Top 3 鉴定酶",
                icon: "scissors",
                tint: .teal,
                action: runRecommendation
            )

            if let onApply = onApplyToGel, let rec = activeRecommendation {
                StudioActionPillButton(
                    title: L10n.tr("应用 #\(rec.rank) (\(rec.enzymeNames.joined(separator: "+"))) 到凝胶对照", "Apply #\(rec.rank) (\(rec.enzymeNames.joined(separator: "+"))) to Gel Lane"),
                    icon: "arrow.down.doc.fill",
                    tint: .blue,
                    isProminent: true
                ) {
                    onApply(rec.enzymeNames)
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ rep: DiagnosticDigestEngine.DiagnosticDigestReport) -> some View {
        StudioCard(title: L10n.tr("推荐方案 (\(rep.evaluatedCombinations) 种单/双酶切组合)", "Recommended Digests (\(rep.evaluatedCombinations) combinations)")) {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                StudioMetricBadge(label: L10n.t("空载"), value: "\(rep.emptyVectorLengthBp) bp", color: .blue)
                StudioMetricBadge(label: L10n.t("重组"), value: "\(rep.recombinantLengthBp) bp", color: .teal)
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

                AdaptiveTwoColumnWorkspace(breakpoint: 720, hasRight: activeRecommendation != nil) {
                    VStack(spacing: 8) {
                        ForEach(rep.topRecommendations) { rec in
                            let isSel = (rec.rank == selectedRank)
                            VStack(alignment: .leading, spacing: 6) {
                                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                                    StudioMetricBadge(
                                        label: "Top \(rec.rank)",
                                        value: rec.enzymeNames.joined(separator: " + "),
                                        color: isSel ? .teal : .blue
                                    )
                                    StudioMetricBadge(
                                        label: L10n.t("得分"),
                                        value: String(format: "%.1f", rec.score),
                                        color: .green
                                    )
                                    StudioMetricBadge(
                                        label: rec.preferredBuffer,
                                        value: "\(rec.bufferCompatibilityPercent)%",
                                        color: rec.bufferCompatibilityPercent >= 100 ? .green : .orange
                                    )
                                    StudioMetricBadge(
                                        label: L10n.t("推荐胶"),
                                        value: rec.recommendedGelConcentration,
                                        color: .purple
                                    )
                                }

                                Text(rec.rationale)
                                    .font(.system(size: 11.5))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)

                                if let onApply = onApplyToGel {
                                    HStack {
                                        Spacer()
                                        StudioCompactPillButton(
                                            title: "套用此方案到凝胶",
                                            icon: "checkmark.circle",
                                            tint: .teal,
                                            isProminent: isSel
                                        ) {
                                            onApply(rec.enzymeNames)
                                            dismiss()
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .studioInnerBox(tint: isSel ? .teal : nil, paddingH: 10, paddingV: 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedRank = rec.rank
                            }
                        }
                    }
                } right: {
                    if let rec = activeRecommendation {
                        miniVirtualDigestGelCard(rec)
                    }
                }
            }
        }
    }

    private func miniVirtualDigestGelCard(_ rec: DiagnosticDigestEngine.DiagnosticDigestRecommendation) -> some View {
        let conc = AgaroseGelConcentration(rawValue: rec.recommendedGelConcentration) ?? .c1_0
        let ladderSizes = [5000, 3000, 2000, 1500, 1000, 750, 500, 250, 100]

        return StudioCard(title: L10n.tr("虚拟电泳对照 (#\(rec.rank) · \(rec.recommendedGelConcentration))", "Virtual Gel Overlay (#\(rec.rank) · \(rec.recommendedGelConcentration))")) {
            Canvas { ctx, size in
                let bg = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: StudioRadius.inner)
                ctx.fill(bg, with: .color(Color(red: 0.06, green: 0.08, blue: 0.12)))

                let lanesData: [(title: String, bands: [Int], color: Color)] = [
                    ("DL5000", ladderSizes, .orange),
                    (L10n.t("空载"), rec.emptyVectorBandsBp, .cyan),
                    (L10n.t("重组"), rec.recombinantBandsBp, .green)
                ]
                let topMargin: CGFloat = 28
                let bottomMargin: CGFloat = 14
                let usableH = max(40, size.height - topMargin - bottomMargin)
                let colW = size.width / CGFloat(lanesData.count)

                for (idx, lane) in lanesData.enumerated() {
                    let cx = colW * (CGFloat(idx) + 0.5)
                    let bw = min(46, colW * 0.52)

                    let header = Text(lane.title)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                    ctx.draw(header, at: CGPoint(x: cx, y: 13))

                    // Well slot
                    let wellRect = CGRect(x: cx - bw / 2, y: topMargin - 4, width: bw, height: 3)
                    ctx.fill(Path(wellRect), with: .color(.white.opacity(0.25)))

                    for bp in lane.bands {
                        let yFrac = conc.migrationY(sizeBp: bp)
                        let yPos = topMargin + CGFloat(yFrac) * usableH
                        let bandRect = CGRect(x: cx - bw / 2, y: yPos - 1.8, width: bw, height: 3.6)
                        ctx.fill(Path(roundedRect: bandRect, cornerRadius: 1.5), with: .color(lane.color))

                        if idx > 0 || [5000, 2000, 1000, 500, 100].contains(bp) {
                            let label = Text("\(bp)")
                                .font(.system(size: 8.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundColor(.white.opacity(0.75))
                            ctx.draw(label, at: CGPoint(x: cx + bw / 2 + 4, y: yPos), anchor: .leading)
                        }
                    }
                }
            }
            .allowedDynamicRange(.standard)
            .clipShape(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                    .stroke(StudioPalette.cardBorder(isLight: appState.isLightAppearance), lineWidth: 1)
            )
            .frame(minHeight: 240, maxHeight: 300)
        }
    }

    private func syncSequencesFromSelection() {
        if let e = pool.items.first(where: { $0.id == selectedEmptyID }) {
            emptySeqText = e.dnaInfo.sequence
        }
        if let r = pool.items.first(where: { $0.id == selectedRecombID }) {
            recombSeqText = r.dnaInfo.sequence
        }
    }

    private func runRecommendation() {
        let eSeq = BioSequence.clean(emptySeqText)
        let rSeq = BioSequence.clean(recombSeqText)
        guard !eSeq.isEmpty, !rSeq.isEmpty else {
            appState.showToast("请先选择或输入空载与重组载体序列")
            return
        }
        let rep = DiagnosticDigestEngine.recommendTopDigests(
            emptyVectorSequence: eSeq,
            recombinantSequence: rSeq,
            isCircular: isCircular,
            minBands: minBands,
            maxBands: maxBands,
            topN: 3
        )
        self.report = rep
        if let first = rep.topRecommendations.first {
            self.selectedRank = first.rank
        }
    }

    private func loadDemoSequences() {
        selectedEmptyID = "__manual__"
        selectedRecombID = "__manual__"
        isCircular = true
        // 构建空载 vs 插入携带 HindIII+EcoRV 的 1.2kb 片段示例
        let segA = String(repeating: "ATGCGATCGTAGCTAGCATG", count: 40) // 800 bp
        let segB = String(repeating: "GCTAGCTAGCATCGATCGAT", count: 55) // 1100 bp
        let segC = String(repeating: "TTGCAAGCTTGCTAGCTGAC", count: 65) // 1300 bp
        let insertFrag = "GATATC" + String(repeating: "ACGTACGTAGCT", count: 90) + "AAGCTT" // ~1092 bp 含 EcoRV+HindIII
        emptySeqText = "GGATCC" + segA + "GAATTC" + segB + "CTCGAG" + segC
        recombSeqText = "GGATCC" + segA + "GAATTC" + insertFrag + segB + "CTCGAG" + segC
        runRecommendation()
    }
}
