import AppKit
import CloneStudioCore
import SwiftUI

// MARK: - 1. 通用子组件：公式原理卡 / 结果横幅 / 输入行 / 计算记录

/// 高清原生数学公式与常数对照卡片（替代静态图片，深浅色自适应）
private struct BioFormulaReferenceCard: View {
    @Environment(\.appLanguage) private var appLanguage
    let title: String
    let equationLines: [String]
    let notes: [String]
    let tint: Color

    var body: some View {
        let _ = appLanguage
        StudioCard(title: title) {
            StudioMetricBadge(label: "公式原理", value: "实时计算", color: tint)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(equationLines.enumerated()), id: \.offset) { _, eq in
                        Text(L10n.t(eq))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioInnerBox(tint: tint, paddingH: 12, paddingV: 10)

                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .foregroundColor(tint)
                                    .font(.system(size: 11.5, weight: .bold))
                                Text(L10n.t(note))
                                    .font(.system(size: 11.5))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 非阻塞行内警告 / 提示框
private struct BioInlineNoticeBox: View {
    @Environment(\.appLanguage) private var appLanguage
    let icon: String
    let message: String
    let tint: Color

    var body: some View {
        let _ = appLanguage
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(tint)
                .padding(.top, 1)
            Text(L10n.t(message))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioInnerBox(tint: tint, paddingH: 10, paddingV: 8)
    }
}

/// 大号高对比结果展示卡（支持一键复制结果与记录历史）
private struct BioResultDisplayBox: View {
    @Environment(\.appLanguage) private var appLanguage
    let label: String
    let valueText: String
    let unitText: String
    let tint: Color
    let onCopyAndLog: () -> Void

    var body: some View {
        let _ = appLanguage
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                resultTextBlock
                Spacer(minLength: 6)
                copyButton
            }
            VStack(alignment: .leading, spacing: 8) {
                resultTextBlock
                copyButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioInnerBox(tint: tint, paddingH: 12, paddingV: 10)
    }

    private var resultTextBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.t(label))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(valueText)
                    .font(.system(size: 20, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(tint)
                    .textSelection(.enabled)
                if !unitText.isEmpty {
                    Text(L10n.t(unitText))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    private var copyButton: some View {
        StudioCompactPillButton(
            title: "复制并记录",
            icon: "doc.on.doc",
            tint: tint,
            isDisabled: valueText == "--"
        ) {
            onCopyAndLog()
        }
    }
}

/// 标准化单行参数输入框（带标题、右侧单位标签与活跃高亮边框）
private struct BioMetricTextField: View {
    @Environment(\.appLanguage) private var appLanguage
    let label: String
    let placeholder: String
    @Binding var text: String
    let unit: String
    var highlightColor: Color? = nil
    var onEdit: ((String) -> Void)? = nil

    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(L10n.t(label))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                if !unit.isEmpty {
                    Text(L10n.t(unit))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            TextField(
                L10n.t(placeholder),
                text: Binding(
                    get: { text },
                    set: { newVal in
                        text = newVal
                        onEdit?(newVal)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(highlightColor?.opacity(0.55) ?? Color.clear, lineWidth: 1.2)
            )
        }
    }
}

/// 近期换算记录卡
private struct BioCalculationHistoryCard: View {
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject var bioVM: BioCalculatorSuiteViewModel

    var body: some View {
        let _ = appLanguage
        StudioCard(title: "最近计算记录") {
            if !bioVM.history.isEmpty {
                StudioCompactPillButton(title: "清空记录", icon: "trash", tint: .red) {
                    bioVM.history.removeAll()
                }
            }
        } content: {
            if bioVM.history.isEmpty {
                Text(L10n.t("点击任意计算结果的「复制并记录」即可沉淀当前参数与结论，便于对照配液记录。"))
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(bioVM.history) { entry in
                        HStack(alignment: .center, spacing: 8) {
                            Text(L10n.t(entry.category))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.blue)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue.opacity(0.12)))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.expression)
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(entry.resultText)
                                    .font(.system(size: 12, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 4)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.resultText, forType: .string)
                                AppState.shared.showToast(L10n.tr("已复制：\(entry.resultText)", "Copied: \(entry.resultText)"))
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.t("复制此条计算结果"))
                        }
                        .studioInnerBox(paddingH: 9, paddingV: 7)
                    }
                }
            }
        }
    }
}

// MARK: - 2. DNA 换算工作区 (dsDNA / ssDNA / Linear DNA / Nucleic Acid OD260)

public struct DNAConversionsWorkspaceView: View {
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject var bioVM: BioCalculatorSuiteViewModel
    @ObservedObject private var session = WorkspaceSessionManager.shared

    public init(bioVM: BioCalculatorSuiteViewModel) {
        self.bioVM = bioVM
    }

    public var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: 14) {
            StudioSegmentedPicker(
                selection: $bioVM.dnaSubtool,
                options: DNAConversionSubtool.allCases.map { tool in
                    StudioSegmentedOption(value: tool, title: tool.title, tint: .blue)
                }
            )

            switch bioVM.dnaSubtool {
            case .dsDNA:
                dsDNAWorkspace
            case .ssDNA:
                ssDNAWorkspace
            case .linearDNA:
                linearDNAWorkspace
            case .nucleicAcid:
                nucleicAcidWorkspace
            }
        }
    }

    private var dsDNAWorkspace: some View {
        let outVal = bioVM.dsdnaComputedValue
        let formatted = outVal.map { BioMathFormatter.format($0) } ?? "--"
        let outUnit = (bioVM.dsdnaDirection == .ugToPmol) ? "pmol (dsDNA)" : "µg (dsDNA)"

        return AdaptiveTwoColumnWorkspace(breakpoint: 760) {
            StudioCard(title: "dsDNA（双链 DNA）单位转换") {
                let singleVecLen = session.singleFragmentVM.effectiveVectorBackboneLengthBp
                if singleVecLen >= 200 {
                    StudioCompactPillButton(title: L10n.tr("带入单片段载体 (\(singleVecLen) bp)", "Import Vector (\(singleVecLen) bp)"), icon: "arrow.down.circle", tint: .teal) {
                        bioVM.dsdnaLengthBp = "\(singleVecLen)"
                    }
                }
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    StudioSegmentedPicker(
                        selection: $bioVM.dsdnaDirection,
                        options: LabDNAConverter.DSDNADirection.allCases.map { dir in
                            StudioSegmentedOption(value: dir, title: dir.title, tint: .blue)
                        }
                    )

                    BioMetricTextField(
                        label: L10n.t("DNA 长度 (N)"),
                        placeholder: L10n.t("例如 5000"),
                        text: $bioVM.dsdnaLengthBp,
                        unit: "bp",
                        highlightColor: .blue
                    )

                    BioMetricTextField(
                        label: bioVM.dsdnaDirection == .ugToPmol ? "双链 DNA 质量" : "双链 DNA 摩尔数",
                        placeholder: bioVM.dsdnaDirection == .ugToPmol ? "例如 1" : "例如 0.303",
                        text: $bioVM.dsdnaInputValue,
                        unit: bioVM.dsdnaDirection == .ugToPmol ? "µg" : "pmol",
                        highlightColor: .blue
                    )

                    BioResultDisplayBox(
                        label: L10n.t("转换结果"),
                        valueText: formatted,
                        unitText: outUnit,
                        tint: .blue
                    ) {
                        let msg = "\(formatted) \(outUnit)"
                        copyToClipboard(msg)
                        let inputUnit = bioVM.dsdnaDirection == .ugToPmol ? "µg" : "pmol"
                        bioVM.appendHistory(
                            category: "dsDNA",
                            expression: "\(bioVM.dsdnaLengthBp) bp, \(bioVM.dsdnaInputValue) \(inputUnit)",
                            resultText: msg
                        )
                    }
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 14) {
                BioFormulaReferenceCard(
                    title: "dsDNA 计算公式",
                    equationLines: bioVM.dsdnaDirection == .ugToPmol
                        ? ["pmol DNA = µg DNA × (1 pmol / 660 pg) × (10⁶ pg / 1 µg) × (1 / N)", "简化形式：pmol = (µg / N) × 1515.1"]
                        : ["µg DNA = pmol DNA × (660 pg / pmol) × (1 µg / 10⁶ pg) × N", "简化形式：µg = pmol × N × 0.00066"],
                    notes: [
                        "N 为双链核酸碱基对数目（bp）",
                        "660 pg/pmol 为单个双链 DNA 碱基对的平均分子量",
                        "该换算同时适用于环状质粒与双链线性 PCR 产物整体摩尔量测算"
                    ],
                    tint: .blue
                )
                BioCalculationHistoryCard(bioVM: bioVM)
            }
        }
    }

    private var ssDNAWorkspace: some View {
        let outVal = bioVM.ssdnaComputedValue
        let formatted = outVal.map { BioMathFormatter.format($0) } ?? "--"
        let outUnit = (bioVM.ssdnaDirection == .ugPerMlToPmolPerUl) ? "pmol/µL (= µM)" : "µg/mL (= ng/µL)"

        return AdaptiveTwoColumnWorkspace(breakpoint: 760) {
            StudioCard(title: "ssDNA（单链 DNA / 引物）浓度转换") {
                let seqLen = session.sequenceToolVM.cleanLength
                if seqLen > 0 {
                    StudioCompactPillButton(title: L10n.tr("带入序列工具 (\(seqLen) nt)", "Import Seq Tool (\(seqLen) nt)"), icon: "arrow.down.circle", tint: .mint) {
                        bioVM.ssdnaLengthNt = "\(seqLen)"
                    }
                }
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    StudioSegmentedPicker(
                        selection: $bioVM.ssdnaDirection,
                        options: LabDNAConverter.SSDNADirection.allCases.map { dir in
                            StudioSegmentedOption(value: dir, title: dir.title, tint: .teal)
                        }
                    )

                    BioMetricTextField(
                        label: L10n.t("寡核苷酸 / 单链长度 (N)"),
                        placeholder: L10n.t("例如 20"),
                        text: $bioVM.ssdnaLengthNt,
                        unit: "nt (bp)",
                        highlightColor: .teal
                    )

                    BioMetricTextField(
                        label: bioVM.ssdnaDirection == .ugPerMlToPmolPerUl ? "单链 DNA 质量浓度" : "单链 DNA 摩尔浓度",
                        placeholder: bioVM.ssdnaDirection == .ugPerMlToPmolPerUl ? "例如 100" : "例如 15.15",
                        text: $bioVM.ssdnaInputValue,
                        unit: bioVM.ssdnaDirection == .ugPerMlToPmolPerUl ? "µg/mL (ng/µL)" : "pmol/µL (µM)",
                        highlightColor: .teal
                    )

                    BioResultDisplayBox(
                        label: L10n.t("转换结果"),
                        valueText: formatted,
                        unitText: outUnit,
                        tint: .teal
                    ) {
                        let msg = "\(formatted) \(outUnit)"
                        copyToClipboard(msg)
                        let inU = bioVM.ssdnaDirection == .ugPerMlToPmolPerUl ? "µg/mL" : "pmol/µL"
                        bioVM.appendHistory(
                            category: "ssDNA",
                            expression: "\(bioVM.ssdnaLengthNt) nt, \(bioVM.ssdnaInputValue) \(inU)",
                            resultText: msg
                        )
                    }
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 14) {
                BioFormulaReferenceCard(
                    title: "ssDNA 计算公式",
                    equationLines: bioVM.ssdnaDirection == .ugPerMlToPmolPerUl
                        ? ["pmol/µL = (µg/mL × 3.03) / N", "等价关系：1 pmol/µL = 1 µM；1 µg/mL = 1 ng/µL"]
                        : ["µg/mL = (pmol/µL) × 0.33 × N", "用于按引物合成 nmol/OD 量核对母液工作浓度 (例如 10 µM / 100 µM)"],
                    notes: [
                        "N 为单链寡核苷酸碱基数（nt / bp）",
                        "330 pg/pmol 为单链核苷酸平均分子量（1000 / 330 ≈ 3.03）"
                    ],
                    tint: .teal
                )
                BioCalculationHistoryCard(bioVM: bioVM)
            }
        }
    }

    private var linearDNAWorkspace: some View {
        let outVal = bioVM.linearEndsComputedValue
        let formatted = outVal.map { BioMathFormatter.format($0) } ?? "--"

        return AdaptiveTwoColumnWorkspace(breakpoint: 760) {
            StudioCard(title: "Linear DNA（线性 DNA）末端摩尔换算") {
                let singleVecLen = session.singleFragmentVM.effectiveVectorBackboneLengthBp
                if singleVecLen >= 200 {
                    StudioCompactPillButton(
                        title: L10n.tr("带入载体 (\(String(format: "%.2f", Double(singleVecLen) / 1000.0)) kb)", "Import Vector (\(String(format: "%.2f", Double(singleVecLen) / 1000.0)) kb)"),
                        icon: "arrow.down.circle",
                        tint: .indigo
                    ) {
                        bioVM.linearLengthKb = String(format: "%.3f", Double(singleVecLen) / 1000.0)
                    }
                }
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    BioMetricTextField(
                        label: L10n.t("线性双链 DNA 质量"),
                        placeholder: L10n.t("例如 1"),
                        text: $bioVM.linearMassUg,
                        unit: "µg",
                        highlightColor: .indigo
                    )

                    BioMetricTextField(
                        label: L10n.t("DNA 长度"),
                        placeholder: L10n.t("例如 5.0"),
                        text: $bioVM.linearLengthKb,
                        unit: "kb",
                        highlightColor: .indigo
                    )

                    BioResultDisplayBox(
                        label: L10n.t("dsDNA 末端总量"),
                        valueText: formatted,
                        unitText: "pmol Ends",
                        tint: .indigo
                    ) {
                        let msg = "\(formatted) pmol Ends"
                        copyToClipboard(msg)
                        bioVM.appendHistory(
                            category: "Linear Ends",
                            expression: "\(bioVM.linearMassUg) µg · \(bioVM.linearLengthKb) kb",
                            resultText: msg
                        )
                    }
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 14) {
                BioFormulaReferenceCard(
                    title: "线性 DNA 末端摩尔公式",
                    equationLines: [
                        "pmol Ends = (µg DNA × 3.03) / 长度 (kb)",
                        "等价推导：pmol Ends = 2 × (µg × 10⁶) / (660 × kb × 1000)"
                    ],
                    notes: [
                        "每分子线性双链 DNA 拥有 2 个 5'/3' 末端，因此末端摩尔数为双链分子摩尔数的 2 倍",
                        "适用于 T4 PNK 末端磷酸化、CIAP/rSAP 去磷酸化及平端/粘端连接体系计量"
                    ],
                    tint: .indigo
                )
                BioCalculationHistoryCard(bioVM: bioVM)
            }
        }
    }

    private var nucleicAcidWorkspace: some View {
        let res = bioVM.od260Result
        let formatted = res.map { BioMathFormatter.format($0.concentrationUgPerMl) } ?? "--"

        return AdaptiveTwoColumnWorkspace(breakpoint: 760) {
            StudioCard(title: "Nucleic Acid（核酸）OD260 浓度换算") {
                VStack(alignment: .leading, spacing: 12) {
                    BioMetricTextField(
                        label: L10n.t("分光光度计读数 (OD260)"),
                        placeholder: L10n.t("推荐线性区 0.1 – 1.0"),
                        text: $bioVM.od260Reading,
                        unit: "OD₂₆₀",
                        highlightColor: (res?.isOutOfLinearRange == true) ? .orange : .purple
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("样本类型与换算系数"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                        StudioMenuPicker(
                            selection: $bioVM.od260SampleType,
                            options: LabDNAConverter.NucleicAcidSampleType.allCases.map { st in
                                StudioMenuPickerOption(value: st, title: st.displayTitle)
                            },
                            prefix: "类型",
                            icon: "drop.halffull",
                            tint: .purple
                        )
                    }

                    BioMetricTextField(
                        label: L10n.t("稀释倍数（直测填 1）"),
                        placeholder: "1",
                        text: $bioVM.od260DilutionFactor,
                        unit: "× 稀释",
                        highlightColor: .purple
                    )

                    if let warn = res?.rangeWarning {
                        BioInlineNoticeBox(
                            icon: "exclamationmark.triangle.fill",
                            message: warn,
                            tint: .orange
                        )
                    }

                    BioResultDisplayBox(
                        label: L10n.t("核酸样本质量浓度"),
                        valueText: formatted,
                        unitText: "µg/mL (= ng/µL)",
                        tint: .purple
                    ) {
                        let msg = "\(formatted) µg/mL"
                        copyToClipboard(msg)
                        bioVM.appendHistory(
                            category: "OD260",
                            expression: "OD=\(bioVM.od260Reading) · \(bioVM.od260SampleType.rawValue) · ×\(bioVM.od260DilutionFactor)",
                            resultText: msg
                        )
                    }
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 14) {
                BioFormulaReferenceCard(
                    title: "OD260 比色定量公式与常数表",
                    equationLines: [
                        "浓度 (µg/mL) = OD₂₆₀ × 样本换算系数 × 稀释倍数"
                    ],
                    notes: [
                        "双链 DNA (dsDNA)：1 OD₂₆₀ = 50 µg/mL",
                        "单链 RNA：1 OD₂₆₀ = 40 µg/mL",
                        "单链 DNA (ssDNA)：1 OD₂₆₀ = 35 µg/mL",
                        "单链寡核苷酸 (Single-stranded Oligo)：1 OD₂₆₀ = 20 µg/mL",
                        "注意：当 OD₂₆₀ < 0.1 或 > 1.0 时超出大多数紫外分光光度计最佳线性响应区"
                    ],
                    tint: .purple
                )
                BioCalculationHistoryCard(bioVM: bioVM)
            }
        }
    }
}

// MARK: - 3. 蛋白质换算工作区 (摩尔互算 / DNA 编码容量)

public struct ProteinConversionsWorkspaceView: View {
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject var bioVM: BioCalculatorSuiteViewModel

    public init(bioVM: BioCalculatorSuiteViewModel) {
        self.bioVM = bioVM
    }

    public var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: 14) {
            StudioSegmentedPicker(
                selection: $bioVM.proteinSubtool,
                options: ProteinConversionSubtool.allCases.map { tool in
                    StudioSegmentedOption(value: tool, title: tool.title, tint: .orange)
                }
            )

            switch bioVM.proteinSubtool {
            case .molar:
                proteinMolarWorkspace
            case .codingCapacity:
                codingCapacityWorkspace
            }
        }
    }

    private var proteinMolarWorkspace: some View {
        let res = bioVM.proteinMolarResult
        let valueStr = res.map { BioMathFormatter.format($0.value) } ?? "--"
        let unitStr = bioVM.proteinTarget.unitSuffix

        let inputALabel: (String, String) = {
            switch bioVM.proteinTarget {
            case .sizeKDa:    return ("蛋白质量 (µg)", "µg")
            case .massUg:     return ("蛋白质分子量 (Protein Size)", "kDa")
            case .amountPmol: return ("蛋白质分子量 (Protein Size)", "kDa")
            }
        }()
        let inputBLabel: (String, String) = {
            switch bioVM.proteinTarget {
            case .sizeKDa:    return ("蛋白摩尔数 (pmol)", "pmol")
            case .massUg:     return ("蛋白摩尔数 (pmol)", "pmol")
            case .amountPmol: return ("蛋白质量 (µg)", "µg")
            }
        }()

        return AdaptiveTwoColumnWorkspace(breakpoint: 760) {
            StudioCard(title: "蛋白质摩尔转换器") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("目标求解量（计算为）"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                        StudioSegmentedPicker(
                            selection: $bioVM.proteinTarget,
                            options: LabProteinConverter.ProteinMolarTarget.allCases.map { t in
                                StudioSegmentedOption(value: t, title: t.title, tint: .orange)
                            }
                        )
                    }

                    BioMetricTextField(
                        label: inputALabel.0,
                        placeholder: L10n.t("输入正数"),
                        text: $bioVM.proteinInputA,
                        unit: inputALabel.1,
                        highlightColor: .orange
                    )

                    BioMetricTextField(
                        label: inputBLabel.0,
                        placeholder: L10n.t("输入正数"),
                        text: $bioVM.proteinInputB,
                        unit: inputBLabel.1,
                        highlightColor: .orange
                    )

                    BioResultDisplayBox(
                        label: L10n.tr("计算结果 (\(bioVM.proteinTarget.title))", "Result (\(L10n.t(bioVM.proteinTarget.title)))"),
                        valueText: valueStr,
                        unitText: unitStr,
                        tint: .orange
                    ) {
                        let msg = "\(valueStr) \(unitStr)"
                        copyToClipboard(msg)
                        bioVM.appendHistory(
                            category: L10n.t("蛋白摩尔"),
                            expression: "\(bioVM.proteinInputA) \(inputALabel.1), \(bioVM.proteinInputB) \(inputBLabel.1)",
                            resultText: msg
                        )
                    }
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 14) {
                BioFormulaReferenceCard(
                    title: "蛋白质摩尔转换核心公式",
                    equationLines: [
                        "1 µg 蛋白质 ÷ 1 pmol 蛋白质 = 1,000 kDa",
                        "Size (kDa) = 1000 × 质量 (µg) ÷ 摩尔数 (pmol)",
                        "Mass (µg) = Size (kDa) × 摩尔数 (pmol) × 0.001",
                        "Moles (pmol) = 1000 × 质量 (µg) ÷ Size (kDa)"
                    ],
                    notes: [
                        "1 kDa = 1,000 g/mol = 1 ng/pmol",
                        "示例：50 kDa 蛋白取 50 µg 恰好对应 1,000 pmol (1 nmol)"
                    ],
                    tint: .orange
                )
                BioCalculationHistoryCard(bioVM: bioVM)
            }
        }
    }

    private var codingCapacityWorkspace: some View {
        let canCopy = !bioVM.codingBP.isEmpty && !bioVM.codingAA.isEmpty && !bioVM.codingKDa.isEmpty
        return AdaptiveTwoColumnWorkspace(breakpoint: 760) {
            StudioCard(title: "DNA 编码容量计算器（三向联动）") {
                StudioMetricBadge(label: L10n.t("规则"), value: "任意输入一项", color: .pink)
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    BioMetricTextField(
                        label: L10n.t("DNA 编码区长度 (CDS /ORF)"),
                        placeholder: L10n.t("输入碱基长度 bp"),
                        text: $bioVM.codingBP,
                        unit: "bp",
                        highlightColor: bioVM.codingLastEdited == "bp" ? .pink : nil
                    ) { newVal in
                        bioVM.updateCodingBP(newVal)
                    }

                    BioMetricTextField(
                        label: L10n.t("蛋白质氨基酸长度"),
                        placeholder: L10n.t("输入氨基酸残基数"),
                        text: $bioVM.codingAA,
                        unit: "氨基酸 (aa)",
                        highlightColor: bioVM.codingLastEdited == "aa" ? .pink : nil
                    ) { newVal in
                        bioVM.updateCodingAA(newVal)
                    }

                    BioMetricTextField(
                        label: L10n.t("蛋白质预计分子量"),
                        placeholder: L10n.t("输入分子量 kDa"),
                        text: $bioVM.codingKDa,
                        unit: "kDa",
                        highlightColor: bioVM.codingLastEdited == "kda" ? .pink : nil
                    ) { newVal in
                        bioVM.updateCodingKDa(newVal)
                    }

                    BioResultDisplayBox(
                        label: L10n.t("编码对应汇总"),
                        valueText: canCopy ? "\(bioVM.codingAA) aa · \(bioVM.codingKDa) kDa" : "--",
                        unitText: canCopy ? "(\(bioVM.codingBP) bp)" : "",
                        tint: .pink
                    ) {
                        let summary = "\(bioVM.codingBP) bp ⇄ \(bioVM.codingAA) aa ⇄ \(bioVM.codingKDa) kDa"
                        copyToClipboard(summary)
                        bioVM.appendHistory(category: L10n.t("编码容量"), expression: L10n.t("三向联动推算"), resultText: summary)
                    }
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 14) {
                BioFormulaReferenceCard(
                    title: "DNA 编码容量推算公式",
                    equationLines: [
                        "氨基酸数 (aa) = floor(DNA 长度 bp ÷ 3)",
                        "DNA 长度 (bp) = 氨基酸数 (aa) × 3",
                        "蛋白分子量 (kDa) = 氨基酸数 (aa) × 0.11"
                    ],
                    notes: [
                        "按蛋白质残基平均分子量 110 Da (0.11 kDa / aa) 快速估算",
                        "如需依据真实氨基酸序列计算精确分子量、等电点 pI 与消光系数，可使用左侧「蛋白质工作台」"
                    ],
                    tint: .pink
                )
                BioCalculationHistoryCard(bioVM: bioVM)
            }
        }
    }
}

// MARK: - 4. 生理生化公式换算工作区 (摩尔浓度配制 / 稀释度 C1V1=C2V2 / 温度转换)

public struct BiochemFormulasWorkspaceView: View {
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject var bioVM: BioCalculatorSuiteViewModel

    private static let commonReagentMWs: [(name: String, mw: String)] = [
        ("Tris", "121.14"),
        ("NaCl", "58.44"),
        ("EDTA·Na₂", "372.24"),
        ("SDS", "288.38"),
        ("Amp", "371.39"),
        ("Kan", "582.58"),
        ("IPTG", "238.30"),
        ("DTT", "154.25")
    ]

    private static let commonTempsC: [(label: String, c: String)] = [
        ("-80°C", "-80"),
        ("-20°C", "-20"),
        ("4°C", "4"),
        ("25°C", "25"),
        ("37°C", "37"),
        ("50°C", "50"),
        ("72°C", "72"),
        ("95°C", "95")
    ]

    public init(bioVM: BioCalculatorSuiteViewModel) {
        self.bioVM = bioVM
    }

    public var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: 14) {
            StudioSegmentedPicker(
                selection: $bioVM.biochemSubtool,
                options: BiochemFormulaSubtool.allCases.map { tool in
                    StudioSegmentedOption(value: tool, title: tool.title, tint: .green)
                }
            )

            switch bioVM.biochemSubtool {
            case .molarityMass:
                molarityWorkspace
            case .dilution:
                dilutionWorkspace
            case .temperature:
                temperatureWorkspace
            }
        }
    }

    private var molarityWorkspace: some View {
        let res = bioVM.molarityMassResult
        let valDisplay: String = {
            guard let r = res else { return "--" }
            return r.exceedsDisplayLimit ? "--" : BioMathFormatter.format(r.displayValue, fixedDecimals: r.displayUnit == "g" ? 3 : (r.displayUnit == "mg" ? 2 : nil))
        }()
        let unitDisplay = (res != nil && res?.exceedsDisplayLimit == false) ? res!.displayUnit : ""

        return AdaptiveTwoColumnWorkspace(breakpoint: 760) {
            StudioCard(title: "摩尔浓度配制质量计算器") {
                VStack(alignment: .leading, spacing: 12) {
                    BioMetricTextField(
                        label: L10n.t("化合物分子量 (MW)"),
                        placeholder: L10n.t("例如 NaCl = 58.44"),
                        text: $bioVM.molarityMW,
                        unit: "g/mol",
                        highlightColor: .green
                    )

                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        Text(L10n.t("常用试剂 MW:"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 3)
                        ForEach(Self.commonReagentMWs, id: \.name) { item in
                            StudioCompactPillButton(
                                title: "\(item.name) (\(item.mw))",
                                tint: .green,
                                isProminent: bioVM.molarityMW == item.mw
                            ) {
                                bioVM.molarityMW = item.mw
                            }
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: 10) {
                            BioMetricTextField(
                                label: L10n.t("目标最终浓度"),
                                placeholder: "100",
                                text: $bioVM.molarityConc,
                                unit: bioVM.molarityConcUnit.title,
                                highlightColor: .green
                            )
                            StudioMenuPicker(
                                selection: $bioVM.molarityConcUnit,
                                options: LabBiochemCalculator.MolarUnit.molarityMassCases.map { u in
                                    StudioMenuPickerOption(value: u, title: u.title)
                                },
                                prefix: "单位",
                                tint: .green
                            )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            BioMetricTextField(
                                label: L10n.t("目标最终浓度"),
                                placeholder: "100",
                                text: $bioVM.molarityConc,
                                unit: bioVM.molarityConcUnit.title,
                                highlightColor: .green
                            )
                            StudioMenuPicker(
                                selection: $bioVM.molarityConcUnit,
                                options: LabBiochemCalculator.MolarUnit.molarityMassCases.map { u in
                                    StudioMenuPickerOption(value: u, title: u.title)
                                },
                                prefix: "单位",
                                tint: .green
                            )
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .bottom, spacing: 10) {
                            BioMetricTextField(
                                label: L10n.t("溶液最终体积"),
                                placeholder: "500",
                                text: $bioVM.molarityVol,
                                unit: bioVM.molarityVolUnit.title,
                                highlightColor: .green
                            )
                            StudioMenuPicker(
                                selection: $bioVM.molarityVolUnit,
                                options: LabBiochemCalculator.VolumeUnit.allCases.map { u in
                                    StudioMenuPickerOption(value: u, title: u.title)
                                },
                                prefix: "单位",
                                tint: .green
                            )
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            BioMetricTextField(
                                label: L10n.t("溶液最终体积"),
                                placeholder: "500",
                                text: $bioVM.molarityVol,
                                unit: bioVM.molarityVolUnit.title,
                                highlightColor: .green
                            )
                            StudioMenuPicker(
                                selection: $bioVM.molarityVolUnit,
                                options: LabBiochemCalculator.VolumeUnit.allCases.map { u in
                                    StudioMenuPickerOption(value: u, title: u.title)
                                },
                                prefix: "单位",
                                tint: .green
                            )
                        }
                    }

                    if let warn = res?.warningMessage {
                        BioInlineNoticeBox(
                            icon: (res?.exceedsDisplayLimit == true) ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                            message: warn,
                            tint: (res?.exceedsDisplayLimit == true) ? .red : .orange
                        )
                    }

                    BioResultDisplayBox(
                        label: L10n.t("所需称量溶质质量"),
                        valueText: valDisplay,
                        unitText: unitDisplay,
                        tint: .green
                    ) {
                        let msg = res?.formattedMass ?? "--"
                        copyToClipboard(msg)
                        bioVM.appendHistory(
                            category: L10n.t("摩尔配制"),
                            expression: "MW \(bioVM.molarityMW), \(bioVM.molarityConc) \(bioVM.molarityConcUnit.title) × \(bioVM.molarityVol) \(bioVM.molarityVolUnit.title)",
                            resultText: msg
                        )
                    }
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 14) {
                BioFormulaReferenceCard(
                    title: "摩尔浓度溶液配制公式",
                    equationLines: [
                        "质量 m (g) = 浓度 C (mol/L) × 体积 V (L) × 分子量 MW (g/mol)",
                        "量纲自适应：≥ 1 g → g；1 mg ~ 1 g → mg；< 1 mg → µg"
                    ],
                    notes: [
                        "当所需称量质量小于 1 mg 时，普通分析天平称量误差较大，建议先配制 100× 或 1000× 高浓度母液再稀释",
                        "支持直接点选常用分子生物学试剂分子量标签"
                    ],
                    tint: .green
                )
                BioCalculationHistoryCard(bioVM: bioVM)
            }
        }
    }

    private var dilutionWorkspace: some View {
        let res = bioVM.dilutionResult
        let stockText = (res?.isValid == true) ? "\(BioMathFormatter.format(res!.displayValue)) \(res!.displayUnit)" : (res?.formattedStockVolume ?? "--")

        return AdaptiveTwoColumnWorkspace(breakpoint: 760) {
            StudioCard(title: "溶液稀释度计算器 (C₁V₁ = C₂V₂)") {
                VStack(alignment: .leading, spacing: 12) {
                    // C1 母液浓度
                    dilutionRow(
                        label: L10n.t("母液起始浓度 (C₁)"),
                        placeholder: "1",
                        text: $bioVM.dilutionStockConc,
                        unitBinding: $bioVM.dilutionStockUnit,
                        unitOptions: LabBiochemCalculator.MolarUnit.allCases.map { StudioMenuPickerOption(value: $0, title: $0.title) }
                    )

                    // C2 最终浓度
                    dilutionRow(
                        label: L10n.t("工作液最终浓度 (C₂)"),
                        placeholder: "10",
                        text: $bioVM.dilutionFinalConc,
                        unitBinding: $bioVM.dilutionFinalUnit,
                        unitOptions: LabBiochemCalculator.MolarUnit.allCases.map { StudioMenuPickerOption(value: $0, title: $0.title) }
                    )

                    // V2 最终体积
                    dilutionRow(
                        label: L10n.t("工作液最终体积 (V₂)"),
                        placeholder: "50",
                        text: $bioVM.dilutionFinalVol,
                        unitBinding: $bioVM.dilutionFinalVolUnit,
                        unitOptions: LabBiochemCalculator.VolumeUnit.allCases.map { StudioMenuPickerOption(value: $0, title: $0.title) }
                    )

                    if let err = res?.errorMessage {
                        BioInlineNoticeBox(icon: "xmark.octagon.fill", message: err, tint: .red)
                    } else if let warn = res?.warningMessage {
                        BioInlineNoticeBox(icon: "exclamationmark.triangle.fill", message: warn, tint: .orange)
                    }

                    BioResultDisplayBox(
                        label: L10n.t("所需母液体积 (V₁)"),
                        valueText: (res?.isValid == true) ? BioMathFormatter.format(res!.displayValue) : "--",
                        unitText: (res?.isValid == true) ? res!.displayUnit : "",
                        tint: .cyan
                    ) {
                        copyToClipboard(stockText)
                        bioVM.appendHistory(
                            category: L10n.t("溶液稀释"),
                            expression: "\(bioVM.dilutionStockConc)\(bioVM.dilutionStockUnit.title) → \(bioVM.dilutionFinalConc)\(bioVM.dilutionFinalUnit.title) (\(bioVM.dilutionFinalVol)\(bioVM.dilutionFinalVolUnit.title))",
                            resultText: L10n.tr("吸取母液 \(stockText)", "Pipette Stock \(stockText)")
                        )
                    }

                    if let validRes = res, validRes.isValid {
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            StudioMetricBadge(
                                label: L10n.t("稀释倍数"),
                                value: "\(BioMathFormatter.format(validRes.dilutionFold))×",
                                color: .blue
                            )
                            StudioMetricBadge(
                                label: L10n.t("补加稀释液"),
                                value: validRes.formattedDiluentVolume,
                                color: .teal
                            )
                        }
                    }
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 14) {
                BioFormulaReferenceCard(
                    title: "C₁V₁ = C₂V₂ 稀释公式",
                    equationLines: [
                        "所需母液体积 V₁ = (C₂ × V₂) ÷ C₁",
                        "稀释液/缓冲液补加体积 = V₂ − V₁"
                    ],
                    notes: [
                        "系统自动统一换算 M / mM / µM / nM / pM 与 L / mL / µL 量纲",
                        "当 V₁ 小于 1 µL 时（自动显示为 nL 或 pL），将主动提醒常规移液器难以精确移取，建议逐级稀释母液",
                        "当 C₂ > C₁ 时自动提示需要浓缩母液而非稀释"
                    ],
                    tint: .cyan
                )
                BioCalculationHistoryCard(bioVM: bioVM)
            }
        }
    }

    private func dilutionRow<U: Hashable>(
        label: String,
        placeholder: String,
        text: Binding<String>,
        unitBinding: Binding<U>,
        unitOptions: [StudioMenuPickerOption<U>]
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                BioMetricTextField(
                    label: label,
                    placeholder: placeholder,
                    text: text,
                    unit: unitOptions.first(where: { $0.value == unitBinding.wrappedValue })?.title ?? "",
                    highlightColor: .cyan
                )
                StudioMenuPicker(
                    selection: unitBinding,
                    options: unitOptions,
                    prefix: "单位",
                    tint: .cyan
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                BioMetricTextField(
                    label: label,
                    placeholder: placeholder,
                    text: text,
                    unit: unitOptions.first(where: { $0.value == unitBinding.wrappedValue })?.title ?? "",
                    highlightColor: .cyan
                )
                StudioMenuPicker(
                    selection: unitBinding,
                    options: unitOptions,
                    prefix: "单位",
                    tint: .cyan
                )
            }
        }
    }

    private var temperatureWorkspace: some View {
        let validSummary = (!bioVM.tempF.isEmpty && !bioVM.tempC.isEmpty && !bioVM.tempK.isEmpty)
        return AdaptiveTwoColumnWorkspace(breakpoint: 760) {
            StudioCard(title: "温度单位转换计算器（三向联动）") {
                StudioMetricBadge(label: L10n.t("规则"), value: "任意输入一项", color: .red)
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        Text(L10n.t("常用实验温区:"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 3)
                        ForEach(Self.commonTempsC, id: \.label) { preset in
                            StudioCompactPillButton(
                                title: preset.label,
                                tint: .red,
                                isProminent: bioVM.tempC == preset.c
                            ) {
                                bioVM.updateTempC(preset.c)
                            }
                        }
                    }

                    BioMetricTextField(
                        label: L10n.t("华氏度"),
                        placeholder: L10n.t("例如 98.6"),
                        text: $bioVM.tempF,
                        unit: "°F",
                        highlightColor: bioVM.tempLastEdited == "f" ? .red : nil
                    ) { newVal in
                        bioVM.updateTempF(newVal)
                    }

                    BioMetricTextField(
                        label: L10n.t("摄氏度"),
                        placeholder: L10n.t("例如 37"),
                        text: $bioVM.tempC,
                        unit: "°C",
                        highlightColor: bioVM.tempLastEdited == "c" ? .red : nil
                    ) { newVal in
                        bioVM.updateTempC(newVal)
                    }

                    BioMetricTextField(
                        label: L10n.t("热力学温标（开尔文）"),
                        placeholder: L10n.t("例如 310.16"),
                        text: $bioVM.tempK,
                        unit: "°K",
                        highlightColor: bioVM.tempLastEdited == "k" ? .red : nil
                    ) { newVal in
                        bioVM.updateTempK(newVal)
                    }

                    if let err = bioVM.temperatureValidationError {
                        BioInlineNoticeBox(icon: "xmark.octagon.fill", message: err, tint: .red)
                    }

                    BioResultDisplayBox(
                        label: L10n.t("温标对照汇总"),
                        valueText: validSummary ? "\(bioVM.tempC) °C · \(bioVM.tempF) °F" : "--",
                        unitText: validSummary ? "(\(bioVM.tempK) K)" : "",
                        tint: .red
                    ) {
                        let msg = "\(bioVM.tempC) °C = \(bioVM.tempF) °F = \(bioVM.tempK) K"
                        copyToClipboard(msg)
                        bioVM.appendHistory(category: L10n.t("温度转换"), expression: "°F/°C/K", resultText: msg)
                    }
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 14) {
                BioFormulaReferenceCard(
                    title: "温标转换公式",
                    equationLines: [
                        "°C = (5 / 9) × (°F − 32)",
                        "°F = (9 / 5) × °C + 32",
                        "°K = °C + 273.16"
                    ],
                    notes: [
                        "输入任意一个温标值即可实时刷新另外两个温标值（精确至 2 位小数）",
                        "温度低于绝对零度（0 K / -273.16 °C）时将自动提示越界校验"
                    ],
                    tint: .red
                )
                BioCalculationHistoryCard(bioVM: bioVM)
            }
        }
    }
}

private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    AppState.shared.showToast(L10n.tr("已复制到剪贴板：\(text)", "Copied to clipboard: \(text)"))
}
