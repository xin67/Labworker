import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// CRISPR Knock-in HDR 同源供体、PAM/Seed 同义阻断突变、可选 RFLP 与 Out-Out PCR 分型引物工作台（调用 `HDRDonorEngine`）
public struct HDRDonorPanelView: View {
    @ObservedObject private var appState = AppState.shared

    public let externalSelectedSpacer: String?

    @State private var donorName: String = "HDR_KnockIn"
    @State private var referenceSequence: String = ""
    @State private var sgRNASequence: String = ""
    @State private var strand: String = "+"
    @State private var editStart1BasedText: String = "1"
    @State private var editEnd1BasedText: String = "0"
    @State private var replacementSequence: String = ""
    @State private var donorFormat: HDRDonorFormat = .ssODN
    @State private var customArmLengthText: String = ""
    @State private var autoDetectCDS: Bool = true
    @State private var manualCDSStartText: String = ""
    @State private var manualCDSEndText: String = ""
    @State private var enableRFLP: Bool = true
    @State private var outOutMarginText: String = "80"
    @State private var targetTmText: String = "60.0"

    @State private var errorMessage: String? = nil
    @State private var report: HDRDonorDesignReport? = nil

    public init(externalSelectedSpacer: String? = nil) {
        self.externalSelectedSpacer = externalSelectedSpacer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            locusInputCard
            editAndFormatCard
            actionBar
            if let err = errorMessage {
                Text(err)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioInnerBox(tint: .red, paddingH: 10, paddingV: 8)
            }
            if let rep = report {
                resultSummaryCard(rep)
                donorSequenceCard(rep)
                if let rflp = rep.rflp {
                    rflpCard(rflp)
                }
                if let outOut = rep.outOutPCR {
                    outOutPrimersCard(outOut)
                }
            }
        }
        .onAppear {
            if referenceSequence.isEmpty {
                loadKnockInDemo()
            }
        }
    }

    private var locusInputCard: some View {
        StudioCard(title: "靶位点参考序列与 sgRNA 定位") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                if let ext = externalSelectedSpacer, BioSequence.clean(ext).count >= 17 {
                    StudioActionPillButton(title: "同步当前 sgRNA", icon: "arrow.triangle.2.circlepath", tint: .cyan) {
                        sgRNASequence = BioSequence.clean(ext)
                    }
                }
                StudioActionPillButton(title: "导入序列", icon: "folder.badge.plus", tint: .blue) {
                    openReferenceFile()
                }
                StudioActionPillButton(title: "载入 Knock-in 示例", icon: "sparkles") {
                    loadKnockInDemo()
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                SequenceEditorBox(
                    text: $referenceSequence,
                    placeholder: "输入或导入含 sgRNA 位点与侧翼同源臂的基因组/质粒序列...",
                    minHeight: 84
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Text("sgRNA (20 bp):")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        TextField("输入 20 bp Spacer (不含 PAM)", text: $sgRNASequence)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .font(.system(size: 12, design: .monospaced))

                        StudioSegmentedPicker(
                            selection: $strand,
                            options: [
                                StudioSegmentedOption(value: "+", title: "正链 (+)", tint: .blue),
                                StudioSegmentedOption(value: "-", title: "反链 (-)", tint: .purple)
                            ]
                        )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        TextField("输入 20 bp Spacer (不含 PAM)", text: $sgRNASequence)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .font(.system(size: 12, design: .monospaced))
                        StudioSegmentedPicker(
                            selection: $strand,
                            options: [
                                StudioSegmentedOption(value: "+", title: "正链 (+)", tint: .blue),
                                StudioSegmentedOption(value: "-", title: "反链 (-)", tint: .purple)
                            ]
                        )
                    }
                }
            }
        }
    }

    private var editAndFormatCard: some View {
        StudioCard(title: "编辑载荷、同源臂与阻断参数") {
            StudioSegmentedPicker(
                selection: $donorFormat,
                options: [
                    StudioSegmentedOption(value: .ssODN, title: "ssODN (60nt臂)", tint: .teal),
                    StudioSegmentedOption(value: .dsDNAPlasmid, title: "dsDNA质粒 (600bp臂)", tint: .indigo)
                ]
            )
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                    HStack(spacing: 5) {
                        Text("名称:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("Donor 名称", text: $donorName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .frame(width: 140)
                    }

                    HStack(spacing: 5) {
                        Text("编辑起点 (1-based):")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("起", text: $editStart1BasedText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .frame(width: 68)
                    }

                    HStack(spacing: 5) {
                        Text("终点 (0-length 插入填 起点-1):")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("止", text: $editEnd1BasedText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .frame(width: 68)
                    }

                    HStack(spacing: 5) {
                        Text("自定义臂长 (bp):")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("\(donorFormat.defaultArmLengthBp)", text: $customArmLengthText)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .frame(width: 68)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("插入 / 替换载荷 DNA 序列 (5'→3'):")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    SequenceEditorBox(
                        text: $replacementSequence,
                        placeholder: "输入插入标签（如 3xFLAG）或替换突变碱基...",
                        minHeight: 46
                    )
                }

                StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                    Toggle("自动检测 CDS 读框", isOn: $autoDetectCDS)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    if !autoDetectCDS {
                        HStack(spacing: 5) {
                            Text("CDS 起止 (1-based):")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            TextField("起", text: $manualCDSStartText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("~")
                            TextField("止", text: $manualCDSEndText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                        }
                    }

                    Toggle("自动构建/消除同义 RFLP 鉴定酶切位点", isOn: $enableRFLP)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    HStack(spacing: 5) {
                        Text("Out-Out 边距:")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        TextField("80", text: $outOutMarginText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 54)
                        Text("bp")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 5) {
                        Text("引物 Tm:")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        TextField("60.0", text: $targetTmText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 54)
                        Text("℃")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        StudioActionBar {
            StudioPrimaryActionButton(
                title: "生成 HDR 供体与 Out-Out 引物",
                icon: "wand.and.stars",
                tint: .teal,
                action: runDesign
            )
        }
    }

    @ViewBuilder
    private func resultSummaryCard(_ rep: HDRDonorDesignReport) -> some View {
        StudioCard(title: "Cas9 二次切割阻断与蛋白守恒校验") {
            StudioMetricBadge(
                label: "再切阻断",
                value: rep.cas9RecutBlocked ? "已安全阻断" : "需人工复核",
                color: rep.cas9RecutBlocked ? .green : .red
            )
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    StudioMetricBadge(label: "策略", value: blockingStrategyTitle(rep.blockingStrategy), color: .teal)
                    StudioMetricBadge(label: "PAM", value: "\(rep.wtPamSequence) → \(rep.editedPamSequence)", color: .blue)
                    StudioMetricBadge(
                        label: "蛋白守恒",
                        value: rep.isInCDS ? (rep.aminoAcidConserved ? "100% 同义守恒" : "⚠️ 发生改变") : "非编码区",
                        color: (!rep.isInCDS || rep.aminoAcidConserved) ? .green : .red
                    )
                    StudioMetricBadge(
                        label: "Donor 总长",
                        value: "\(rep.donorLengthBp) bp (\(rep.leftArmLengthBp)+\(rep.insertPayload.count)+\(rep.rightArmLengthBp))",
                        color: .purple
                    )
                }

                if !rep.blockingMutations.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("引入的 PAM / Seed 同义阻断突变")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(rep.blockingMutations.enumerated()), id: \.offset) { _, m in
                            HStack(spacing: 8) {
                                StudioMetricBadge(label: "@\(m.position1Based)", value: "\(m.originalBase)→\(m.mutatedBase)", color: .teal)
                                if let cb = m.codonBefore, let ca = m.codonAfter, let aa = m.aminoAcid {
                                    StudioMetricBadge(label: "密码子", value: "\(cb)→\(ca) (\(aa))", color: .green)
                                }
                                Text(m.reason)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .studioInnerBox(paddingH: 8, paddingV: 6)
                        }
                    }
                }

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
            }
        }
    }

    private func donorSequenceCard(_ rep: HDRDonorDesignReport) -> some View {
        StudioCard(title: "HDR 同源修复模板序列 (5'→3')") {
            StudioActionPillButton(title: "复制 FASTA", icon: "doc.on.doc", tint: .teal) {
                let fasta = ">\(donorName)_\(rep.donorFormat.rawValue)_\(rep.donorLengthBp)bp\n\(rep.donorSequence)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fasta, forType: .string)
                appState.showToast("已复制 HDR Donor FASTA 序列")
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text(buildDonorAttributedString(rep))
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                    Label("左同源臂 (\(rep.leftArmLengthBp) bp)", systemImage: "circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                    Label("插入/替换载荷 (\(rep.insertPayload.count) bp)", systemImage: "circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Label("右同源臂 (\(rep.rightArmLengthBp) bp)", systemImage: "circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.purple)
                }
            }
        }
    }

    private func rflpCard(_ rflp: RFLPDesignResult) -> some View {
        StudioCard(title: "同义 RFLP 酶切鉴定标记") {
            StudioMetricBadge(
                label: rflp.mode == .created ? "新增切点" : "消除切点",
                value: "\(rflp.enzymeName) (\(rflp.recognitionSite))",
                color: .orange
            )
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    StudioMetricBadge(
                        label: "WT 扩增子酶切",
                        value: rflp.wtAmpliconBandsBp.map(String.init).joined(separator: " / ") + " bp",
                        color: .blue
                    )
                    StudioMetricBadge(
                        label: "HDR 扩增子酶切",
                        value: rflp.hdrAmpliconBandsBp.map(String.init).joined(separator: " / ") + " bp",
                        color: .green
                    )
                }
                Text(rflp.note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func outOutPrimersCard(_ outOut: OutOutPCRDesign) -> some View {
        StudioCard(title: "同源臂外侧 Out-Out PCR 分型引物") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                StudioMetricBadge(label: "WT 扩增子", value: "\(outOut.wtAmpliconLengthBp) bp", color: .blue)
                StudioMetricBadge(label: "HDR 扩增子", value: "\(outOut.hdrAmpliconLengthBp) bp", color: .green)
                StudioActionPillButton(title: "加入引物池", icon: "cart.badge.plus", tint: .green, isProminent: true) {
                    appState.addPrimersToCart([outOut.forwardPrimer, outOut.reversePrimer])
                }
            }
        } content: {
            VStack(spacing: 10) {
                PrimerPairDimerSummaryBar(
                    forwardPrimer: outOut.forwardPrimer,
                    reversePrimer: outOut.reversePrimer
                )
                PrimerCardView(primer: outOut.forwardPrimer, partnerPrimer: outOut.reversePrimer)
                PrimerCardView(primer: outOut.reversePrimer, partnerPrimer: outOut.forwardPrimer)
            }
        }
    }

    private func buildDonorAttributedString(_ rep: HDRDonorDesignReport) -> AttributedString {
        var str = AttributedString()
        var leftAttr = AttributedString(rep.leftHomologyArm)
        leftAttr.foregroundColor = .blue
        str.append(leftAttr)

        if !rep.insertPayload.isEmpty {
            var midAttr = AttributedString(rep.insertPayload.lowercased())
            midAttr.foregroundColor = .green
            str.append(midAttr)
        }

        var rightAttr = AttributedString(rep.rightHomologyArm)
        rightAttr.foregroundColor = .purple
        str.append(rightAttr)
        return str
    }

    private func blockingStrategyTitle(_ s: HDRBlockingStrategy) -> String {
        switch s {
        case .pamSynonymous:           return "PAM 同义突变"
        case .seedSynonymousFallback:  return "Seed 区同义突变"
        case .pamNonCoding:            return "非编码区 PAM 破坏"
        case .alreadyDisruptedByEdit:  return "编辑载荷已破坏切点"
        case .failedToBlock:           return "未能自动阻断"
        }
    }

    private func runDesign() {
        errorMessage = nil
        let cleanRef = BioSequence.clean(referenceSequence)
        let cleanGuide = BioSequence.clean(sgRNASequence)
        let start1 = max(1, Int(editStart1BasedText.trimmingCharacters(in: .whitespaces)) ?? 1)
        let end1 = Int(editEnd1BasedText.trimmingCharacters(in: .whitespaces)) ?? (start1 - 1)
        let editStart0 = start1 - 1
        let editEnd0 = max(editStart0, end1)
        let armLen = Int(customArmLengthText.trimmingCharacters(in: .whitespaces))
        let marginBp = max(20, Int(outOutMarginText.trimmingCharacters(in: .whitespaces)) ?? 80)
        let tmVal = Double(targetTmText.trimmingCharacters(in: .whitespaces)) ?? 60.0

        let req = HDRDonorRequest(
            referenceSequence: cleanRef,
            sgRNASequence: cleanGuide,
            strand: strand,
            editStart0Based: editStart0,
            editEnd0Based: editEnd0,
            replacementSequence: BioSequence.clean(replacementSequence),
            donorFormat: donorFormat,
            leftArmLengthBp: armLen,
            rightArmLengthBp: armLen,
            cdsStart1Based: autoDetectCDS ? nil : Int(manualCDSStartText.trimmingCharacters(in: .whitespaces)),
            cdsEnd1Based: autoDetectCDS ? nil : Int(manualCDSEndText.trimmingCharacters(in: .whitespaces)),
            autoDetectCDS: autoDetectCDS,
            enableRFLP: enableRFLP,
            outOutMarginBp: marginBp,
            primerTargetTm: tmVal,
            donorName: donorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "HDR_Donor" : donorName
        )

        do {
            let res = try HDRDonorEngine.designHDRDonor(req)
            self.report = res
            appState.showToast("已生成 \(res.donorLengthBp) bp HDR 供体（\(blockingStrategyTitle(res.blockingStrategy))）")
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func openReferenceFile() {
        let panel = NSOpenPanel()
        panel.title = "导入参考位点序列 (.fa / .fasta / .seq / .dna)"
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText]
        for ext in ["fa", "fasta", "seq", "txt", "dna"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            if url.pathExtension.lowercased() == "dna" {
                Task {
                    if let info = try? await SnapGeneService.shared.parseDNAFile(at: url) {
                        await MainActor.run {
                            self.referenceSequence = info.sequence
                            self.donorName = "\(url.deletingPathExtension().lastPathComponent)_HDR"
                        }
                    }
                }
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                let (name, seq) = PlasmidAnnotationEngine.parseFASTA(text, defaultName: url.deletingPathExtension().lastPathComponent)
                self.referenceSequence = seq
                self.donorName = "\(name)_HDR"
            }
        }
    }

    private func loadKnockInDemo() {
        // 含标准起始密码子 ATG + 20 bp sgRNA (GGGCGAGGAGCTGTTCACCG + NGG=GGG) + 充足侧翼用于 ssODN (60nt) + Out-Out PCR
        let leftFlank =
            "AATTCCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATC" +
            "GATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGATCGCTAGCGCTACCGGTCGCCACC"
        let cdsBody =
            "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAAC" +
            "GGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATC" +
            "TGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTC" +
            "AGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAG" +
            "CGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTG" +
            "GTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTAC" +
            "AACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATC" +
            "CGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGC" +
            "CCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGC" +
            "GATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA"
        let rightFlank =
            "GACTACAAAGACCATGACGGTGATTATAAAGATCATGACATCGACTACAAGGATGACGATGACAAGTAGGCG" +
            "GCCGCTCGAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTCAGTC"

        referenceSequence = leftFlank + cdsBody + rightFlank
        let spacer = "GGGCGAGGAGCTGTTCACCG"
        sgRNASequence = BioSequence.clean(externalSelectedSpacer ?? "").count >= 17 && referenceSequence.contains(BioSequence.clean(externalSelectedSpacer ?? ""))
            ? BioSequence.clean(externalSelectedSpacer!)
            : spacer
        strand = "+"
        donorName = "EGFP_N_HA_KnockIn"
        donorFormat = .ssODN
        customArmLengthText = ""
        autoDetectCDS = true
        enableRFLP = true
        outOutMarginText = "60"
        targetTmText = "60.0"

        // 在 N 端 ATG 后紧接着插入 HA 标签 (27 bp)
        let atgStart1 = leftFlank.count + 1
        let insertAt1 = atgStart1 + 3
        editStart1BasedText = "\(insertAt1)"
        editEnd1BasedText = "\(insertAt1 - 1)"
        replacementSequence = "TACCCATACGATGTTCCAGATTACGCT" // HA tag (9 aa)

        runDesign()
    }
}
