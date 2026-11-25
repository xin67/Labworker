import SwiftUI
import Charts
import AppKit
import CloneStudioCore

/// 酶标仪定量与曲线拟合工作台 (BCA / Bradford + WB 上样配液、ELISA 4PL/5PL、IC50/EC50 Hill、CCK-8 细胞活力 Welch/Holm/ANOVA)
public struct PlateReaderAssayView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var plateStore = PlateLayoutStore.shared

    @State private var assayMode: PlateReaderAssayMode = .bca
    @State private var bcaModel: StandardCurveModel = .linear
    @State private var elisaModel: ELISACurveModel = .fourPL

    // BCA & WB 配液参数
    @State private var blankODText: String = "0.082"
    @State private var dilutionText: String = "1.0"
    @State private var targetLoadUgText: String = "20"
    @State private var targetTotalVolText: String = "20"
    @State private var loadingBufferX: Double = 5.0

    // 表格输入文本（标准品与样本支持直接编辑或从酶标仪 8×12 矩阵导入）
    @State private var stdInputText: String = ""
    @State private var sampleInputText: String = ""
    @State private var matrixImportPreview: [String: Double] = [:]
    @State private var showRawEditor: Bool = true
    @State private var ccK8ControlGroup: String = "Control"

    // 缓存曲线拟合与统计分析结果，避免每次界面重绘/点击在主线程重复求解
    @State private var cachedBCAReport: PlateReaderAssayEngine.BCAAnalysisReport? = nil
    @State private var cachedELISAFit: PlateReaderAssayEngine.LogisticFitResult? = nil
    @State private var cachedELISAQuants: [PlateReaderAssayEngine.ELISASampleQuantItem] = []
    @State private var cachedDoseFit: PlateReaderAssayEngine.LogisticFitResult? = nil
    @State private var cachedViabilityReport: PlateReaderAssayEngine.ViabilityAnalysisReport? = nil

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeSwitchAndActionsBar

            StudioResponsiveSplitLayout(breakpoint: 880, spacing: 14, leftRatio: 0.41) {
                leftInputColumn
                rightAnalysisColumn
            }
        }
        .onAppear {
            if stdInputText.isEmpty && sampleInputText.isEmpty {
                loadModeDemo(assayMode)
            } else {
                recomputeActiveAssay()
            }
        }
        .onChange(of: bcaModel) { _, _ in recomputeActiveAssay() }
        .onChange(of: elisaModel) { _, _ in recomputeActiveAssay() }
        .onChange(of: stdInputText) { _, _ in recomputeActiveAssay() }
        .onChange(of: sampleInputText) { _, _ in recomputeActiveAssay() }
        .onChange(of: blankODText) { _, _ in recomputeActiveAssay() }
        .onChange(of: dilutionText) { _, _ in recomputeActiveAssay() }
        .onChange(of: targetLoadUgText) { _, _ in recomputeActiveAssay() }
        .onChange(of: targetTotalVolText) { _, _ in recomputeActiveAssay() }
        .onChange(of: loadingBufferX) { _, _ in recomputeActiveAssay() }
        .onChange(of: ccK8ControlGroup) { _, _ in recomputeActiveAssay() }
    }

    // MARK: - 顶部模式切换与快捷工具

    private var modeSwitchAndActionsBar: some View {
        StudioCard(title: "酶标仪曲线拟合与湿实验定量工作台 (对齐孔板排布)") {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
                StudioActionPillButton(title: "导入 8×12 读数", icon: "doc.badge.plus", tint: .blue, action: importMatrixCSVFile)
                StudioActionPillButton(title: "载入本模式示范", icon: "sparkles", tint: .purple) {
                    loadModeDemo(assayMode)
                }
                if !matrixImportPreview.isEmpty {
                    StudioActionPillButton(title: "按微孔板分组配对 (\(matrixImportPreview.count) 孔)", icon: "square.grid.3x3.fill", tint: .teal, action: pairMatrixWithPlateStore)
                }
            }
        } content: {
            StudioSegmentedPicker(
                selection: $assayMode,
                options: PlateReaderAssayMode.allCases.map { mode in
                    let tint: Color = {
                        switch mode {
                        case .bca: return .blue
                        case .elisa: return .teal
                        case .doseResponse: return .indigo
                        case .viability: return .green
                        }
                    }()
                    return StudioSegmentedOption(value: mode, title: mode.rawValue, tint: tint)
                }
            )
            .onChange(of: assayMode) { _, newMode in
                loadModeDemo(newMode)
            }
        }
    }

    // MARK: - 左栏：参数设置与数据录入

    private var leftInputColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            parametersCard
            rawDataInputCard
        }
    }

    private var parametersCard: some View {
        StudioCard(title: "拟合模型与反应/配液参数") {
            VStack(alignment: .leading, spacing: 10) {
                switch assayMode {
                case .bca:
                    StudioMenuPicker(
                        selection: $bcaModel,
                        options: StandardCurveModel.allCases.map { StudioMenuPickerOption(value: $0, title: $0.rawValue) },
                        prefix: "标曲模型",
                        tint: .blue,
                        compact: true
                    )
                    StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                        labeledNumberField("Blank OD", text: $blankODText, width: 64)
                        labeledNumberField("稀释倍数", text: $dilutionText, width: 56)
                        labeledNumberField("WB目标上样(µg)", text: $targetLoadUgText, width: 56)
                        labeledNumberField("每管总体积(µL)", text: $targetTotalVolText, width: 56)
                    }
                    HStack(spacing: 8) {
                        Text("Loading Buffer 倍数:")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Stepper("\(Int(loadingBufferX))× SDS", value: $loadingBufferX, in: 2...6, step: 1)
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                    }

                case .elisa:
                    StudioMenuPicker(
                        selection: $elisaModel,
                        options: ELISACurveModel.allCases.map { StudioMenuPickerOption(value: $0, title: $0.rawValue) },
                        prefix: "拟合方程",
                        tint: .teal,
                        compact: true
                    )
                    StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                        labeledNumberField("样本稀释倍数", text: $dilutionText, width: 64)
                    }

                case .doseResponse:
                    Text("自动在 log10(Conc) 空间执行 4 参数 Hill 非线性最小二乘 (Levenberg-Marquardt) 拟合，兼容抑制 IC50 与激活 EC50 曲线。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                case .viability:
                    StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                        labeledNumberField("空白培养基 OD", text: $blankODText, width: 70)
                        HStack(spacing: 6) {
                            Text("基准对照组:")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                            TextField("Control", text: $ccK8ControlGroup)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5))
                                .frame(width: 96)
                        }
                    }
                }
            }
        }
    }

    private var rawDataInputCard: some View {
        StudioCard(title: "实验读数输入 (支持 CSV / 粘贴 8×12 矩阵)") {
            StudioCompactPillButton(
                title: showRawEditor ? "收起编辑" : "展开编辑",
                icon: showRawEditor ? "chevron.up" : "chevron.down"
            ) {
                showRawEditor.toggle()
            }
        } content: {
            if showRawEditor {
                VStack(alignment: .leading, spacing: 10) {
                    if assayMode == .bca || assayMode == .elisa || assayMode == .doseResponse {
                        Text(assayMode == .doseResponse ? "剂量-效应数据 (浓度, 读数):" : "标准品梯度 (浓度, 吸光度 OD):")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        SequenceEditorBox(text: $stdInputText, placeholder: "conc,od", minHeight: 96)
                    }

                    if assayMode == .bca || assayMode == .elisa || assayMode == .viability {
                        Text(assayMode == .viability ? "各处理组复孔 OD (Group, v1, v2, ...):" : "待测样本复孔 OD (SampleName, rep1, rep2...):")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        SequenceEditorBox(text: $sampleInputText, placeholder: "sample,od1,od2", minHeight: 96)
                    }
                }
            }
        }
    }

    // MARK: - 右栏：回归拟合图表与统计结果

    @ViewBuilder
    private var rightAnalysisColumn: some View {
        switch assayMode {
        case .bca:
            bcaRightColumn
        case .elisa:
            elisaRightColumn
        case .doseResponse:
            doseResponseRightColumn
        case .viability:
            viabilityRightColumn
        }
    }

    // --- BCA Right ---
    @ViewBuilder
    private var bcaRightColumn: some View {
        if let rep = cachedBCAReport {
            StudioCard(title: "BCA 标准曲线线性/二次回归") {
                StudioActionPillButton(title: "导出上样表 CSV", icon: "square.and.arrow.up", tint: .blue) {
                    exportBCACSV(rep)
                }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        StudioMetricBadge(label: "方程", value: rep.equationText, color: .blue)
                        StudioMetricBadge(label: "R²", value: String(format: "%.5f", rep.r2), color: rep.r2 >= 0.99 ? .green : .orange)
                        StudioMetricBadge(label: "RMSE", value: String(format: "%.4f", rep.rmse), color: .secondary)
                    }
                    Chart {
                        ForEach(rep.curvePoints) { pt in
                            LineMark(x: .value("浓度 (µg/mL)", pt.x), y: .value("校正 OD562", pt.y))
                                .foregroundStyle(Color.blue)
                        }
                        ForEach(rep.standardPoints) { pt in
                            PointMark(x: .value("浓度 (µg/mL)", pt.x), y: .value("校正 OD562", pt.y))
                                .foregroundStyle(Color.indigo)
                                .symbolSize(60)
                        }
                    }
                    .chartXAxisLabel("BSA 标准浓度 (µg/mL)")
                    .chartYAxisLabel("校正 OD")
                    .frame(height: 210)
                }
            }

            StudioCard(title: "样本蛋白浓度反算与 WB 上样配液方案 (每孔总体积 \(targetTotalVolText) µL)") {
                VStack(spacing: 6) {
                    ForEach(rep.samples) { s in
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text(s.sampleName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                                StudioMetricBadge(label: "原液浓度", value: String(format: "%.2f µg/µL", s.stockConcUgPerMl / 1000.0), color: .blue)
                                StudioMetricBadge(label: "蛋白", value: String(format: "%.2f µL", s.proteinVolumeUl), color: s.isDiluteWarning ? .orange : .green)
                                StudioMetricBadge(label: "裂解液", value: String(format: "%.2f µL", s.lysisBufferVolumeUl), color: .secondary)
                                StudioMetricBadge(label: "\(Int(loadingBufferX))×Buf", value: String(format: "%.2f µL", s.loadingBufferVolumeUl), color: .purple)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(s.sampleName).font(.system(size: 12.5, weight: .semibold))
                                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                                    StudioMetricBadge(label: "原液浓度", value: String(format: "%.2f µg/µL", s.stockConcUgPerMl / 1000.0), color: .blue)
                                    StudioMetricBadge(label: "蛋白", value: String(format: "%.2f µL", s.proteinVolumeUl), color: s.isDiluteWarning ? .orange : .green)
                                    StudioMetricBadge(label: "裂解液", value: String(format: "%.2f µL", s.lysisBufferVolumeUl), color: .secondary)
                                    StudioMetricBadge(label: "\(Int(loadingBufferX))×Buf", value: String(format: "%.2f µL", s.loadingBufferVolumeUl), color: .purple)
                                }
                            }
                        }
                        .studioInnerBox(tint: s.isDiluteWarning ? .orange : nil, paddingH: 10, paddingV: 7)

                        if s.isDiluteWarning {
                            Text("⚠️ 「\(s.sampleName)」浓度偏低，最大可上样量约为 \(String(format: "%.1f µg", s.maxLoadableUg))")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        } else {
            emptyStateCard("请输入至少 2 个有效 BCA 标准点")
        }
    }

    // --- ELISA Right ---
    @ViewBuilder
    private var elisaRightColumn: some View {
        let isFive = (elisaModel == .fivePL)
        if let fit = cachedELISAFit {
            let quants = cachedELISAQuants
            StudioCard(title: "ELISA \(isFive ? "5PL" : "4PL") 非线性标准曲线 (Levenberg-Marquardt)") {
                VStack(alignment: .leading, spacing: 10) {
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        StudioMetricBadge(label: "R²", value: String(format: "%.5f", fit.r2), color: fit.r2 >= 0.99 ? .green : .orange)
                        StudioMetricBadge(label: "EC50 (c)", value: String(format: "%.2f", fit.paramC), color: .teal)
                        StudioMetricBadge(label: "斜率 (b)", value: String(format: "%.3f", fit.paramB), color: .blue)
                        if isFive {
                            StudioMetricBadge(label: "非对称 g", value: String(format: "%.3f", fit.paramG), color: .purple)
                        }
                    }
                    Chart {
                        ForEach(fit.curvePoints) { pt in
                            LineMark(x: .value("log10(Conc)", log10(pt.x)), y: .value("OD", pt.y))
                                .foregroundStyle(Color.teal)
                        }
                        ForEach(fit.standardPoints) { pt in
                            PointMark(x: .value("log10(Conc)", log10(pt.x)), y: .value("OD", pt.y))
                                .foregroundStyle(Color.blue)
                                .symbolSize(60)
                        }
                    }
                    .chartXAxisLabel("log10(标准品浓度)")
                    .chartYAxisLabel("信号 / OD")
                    .frame(height: 210)
                }
            }

            StudioCard(title: "待测样本浓度反算结果 (\(quants.count))") {
                VStack(spacing: 6) {
                    ForEach(quants) { q in
                        HStack(spacing: 8) {
                            Text(q.sampleName)
                                .font(.system(size: 12.5, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            StudioMetricBadge(label: "均值 OD", value: String(format: "%.3f", q.meanOD), color: .secondary)
                            if let fc = q.finalConc {
                                StudioMetricBadge(label: "终浓度", value: String(format: "%.2f", fc), color: q.status == .inRange ? .green : .orange)
                            }
                            Text(q.status.rawValue)
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(q.status == .inRange ? .green : .orange)
                        }
                        .studioInnerBox(paddingH: 10, paddingV: 7)
                    }
                }
            }
        } else {
            emptyStateCard("4PL 需要 ≥4 个标准品浓度点，5PL 需要 ≥5 个标准品浓度点")
        }
    }

    // --- IC50 / EC50 Right ---
    @ViewBuilder
    private var doseResponseRightColumn: some View {
        if let fit = cachedDoseFit {
            StudioCard(title: "剂量-效应曲线拟合 (4 参数 Hill 方程)") {
                VStack(alignment: .leading, spacing: 10) {
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        StudioMetricBadge(label: "IC50 / EC50", value: BioMathFormatter.format(fit.paramC), color: .indigo)
                        StudioMetricBadge(label: "log(IC50)", value: String(format: "%.3f", log10(fit.paramC)), color: .blue)
                        StudioMetricBadge(label: "Hill Slope", value: String(format: "%.3f", fit.paramB), color: .purple)
                        StudioMetricBadge(label: "Bottom / Top", value: String(format: "%.1f / %.1f", min(fit.paramA, fit.paramD), max(fit.paramA, fit.paramD)), color: .secondary)
                        StudioMetricBadge(label: "R²", value: String(format: "%.5f", fit.r2), color: fit.r2 >= 0.98 ? .green : .orange)
                    }
                    Chart {
                        RuleMark(x: .value("log10(IC50)", log10(fit.paramC)))
                            .foregroundStyle(.indigo.opacity(0.65))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        ForEach(fit.curvePoints) { pt in
                            LineMark(x: .value("log10(Dose)", log10(pt.x)), y: .value("响应 %", pt.y))
                                .foregroundStyle(Color.indigo)
                        }
                        ForEach(fit.standardPoints) { pt in
                            PointMark(x: .value("log10(Dose)", log10(pt.x)), y: .value("响应 %", pt.y))
                                .foregroundStyle(Color.orange)
                                .symbolSize(60)
                        }
                    }
                    .chartXAxisLabel("log10(浓度)")
                    .chartYAxisLabel("细胞活力 / 抑制响应 (%)")
                    .frame(height: 240)
                }
            }
        } else {
            emptyStateCard("请输入至少 4 个正浓度剂量响应数据点")
        }
    }

    // --- CCK-8 Viability Right ---
    @ViewBuilder
    private var viabilityRightColumn: some View {
        if let rep = cachedViabilityReport {
            StudioCard(title: "CCK-8 / MTT 相对细胞活力统计 (One-Way ANOVA + Welch / Holm)") {
                if let anova = rep.anova {
                    StudioMetricBadge(
                        label: "ANOVA",
                        value: String(format: "F=%.2f, p=%.4g", anova.fStatistic, anova.pValue),
                        color: anova.pValue < 0.05 ? .green : .secondary
                    )
                }
            } content: {
                VStack(alignment: .leading, spacing: 12) {
                    Chart {
                        ForEach(rep.groups) { g in
                            BarMark(
                                x: .value("组别", g.groupName),
                                y: .value("细胞活力 (%)", g.meanViabilityPercent)
                            )
                            .foregroundStyle(g.isControl ? Color.blue : Color.green)

                            RuleMark(
                                x: .value("组别", g.groupName),
                                yStart: .value("Low", max(0, g.meanViabilityPercent - g.sdViabilityPercent)),
                                yEnd: .value("High", g.meanViabilityPercent + g.sdViabilityPercent)
                            )
                            .foregroundStyle(Color.primary.opacity(0.75))
                        }
                    }
                    .chartYAxisLabel("相对活力 (% Control)")
                    .frame(height: 210)

                    VStack(spacing: 6) {
                        ForEach(rep.groups) { g in
                            HStack(spacing: 8) {
                                Text(g.groupName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                StudioMetricBadge(label: "n", value: "\(g.n)", color: .secondary)
                                StudioMetricBadge(label: "活力", value: String(format: "%.1f±%.1f%%", g.meanViabilityPercent, g.sdViabilityPercent), color: .green)
                                if let pa = g.pAdjusted {
                                    StudioMetricBadge(label: "p (Holm)", value: String(format: "%.4f (%@)", pa, g.significanceStars), color: pa < 0.05 ? .pink : .secondary)
                                } else {
                                    StudioMetricBadge(label: "基准", value: "100% Ref", color: .blue)
                                }
                            }
                            .studioInnerBox(paddingH: 10, paddingV: 6)
                        }
                    }
                }
            }
        } else {
            emptyStateCard("请输入分组复孔 OD 数据")
        }
    }

    // MARK: - 辅助控件与解析器

    private func labeledNumberField(_ label: String, text: Binding<String>, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .frame(width: width)
        }
    }

    private func emptyStateCard(_ msg: String) -> some View {
        StudioCard(title: "待计算") {
            Text(msg)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(.vertical, 16)
        }
    }

    private func parseTwoColumnPairs(_ raw: String) -> [(Double, Double)] {
        raw.components(separatedBy: .newlines).compactMap { line -> (Double, Double)? in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("#") { return nil }
            let cells = t.components(separatedBy: CharacterSet(charactersIn: ",\t; ")).filter { !$0.isEmpty }
            guard cells.count >= 2, let x = Double(cells[0]), let y = Double(cells[1]) else { return nil }
            return (x, y)
        }
    }

    private func parseSampleRows(_ raw: String) -> [(name: String, replicates: [Double])] {
        raw.components(separatedBy: .newlines).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("#") { return nil }
            let cells = t.components(separatedBy: CharacterSet(charactersIn: ",\t;")).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = cells.first, !name.isEmpty else { return nil }
            let vals = cells.dropFirst().compactMap { Double($0) }
            guard !vals.isEmpty else { return nil }
            return (name, vals)
        }
    }

    private func loadModeDemo(_ mode: PlateReaderAssayMode) {
        switch mode {
        case .bca:
            let fx = PlateReaderAssayEngine.demoBCAData()
            blankODText = String(format: "%.3f", fx.blankOD)
            dilutionText = "1.0"
            stdInputText = fx.standards.map { "\($0.0),\($0.1)" }.joined(separator: "\n")
            sampleInputText = fx.samples.map { "\($0.0)," + $0.1.map { String($0) }.joined(separator: ",") }.joined(separator: "\n")
        case .elisa:
            let fx = PlateReaderAssayEngine.demoELISAData()
            dilutionText = "1.0"
            stdInputText = fx.standards.map { "\($0.0),\($0.1)" }.joined(separator: "\n")
            sampleInputText = fx.samples.map { "\($0.0)," + $0.1.map { String($0) }.joined(separator: ",") }.joined(separator: "\n")
        case .doseResponse:
            let fx = PlateReaderAssayEngine.demoDoseResponseData()
            stdInputText = fx.map { "\($0.0),\($0.1)" }.joined(separator: "\n")
            sampleInputText = ""
        case .viability:
            blankODText = "0.08"
            ccK8ControlGroup = "Control"
            let fx = PlateReaderAssayEngine.demoViabilityData()
            sampleInputText = fx.map { "\($0.0)," + $0.1.map { String($0) }.joined(separator: ",") }.joined(separator: "\n")
        }
        recomputeActiveAssay(for: mode)
    }

    private func recomputeActiveAssay(for targetMode: PlateReaderAssayMode? = nil) {
        let active = targetMode ?? assayMode
        switch active {
        case .bca:
            let stdPts = parseTwoColumnPairs(stdInputText).map { (concUgPerMl: $0.0, od: $0.1) }
            let samps = parseSampleRows(sampleInputText)
            cachedBCAReport = PlateReaderAssayEngine.analyzeBCA(
                standards: stdPts,
                samples: samps,
                model: bcaModel,
                blankOD: Double(blankODText) ?? 0.0,
                dilutionFactor: Double(dilutionText) ?? 1.0,
                targetLoadUg: Double(targetLoadUgText) ?? 20.0,
                targetTotalVolUl: Double(targetTotalVolText) ?? 20.0,
                loadingBufferX: loadingBufferX
            )
        case .elisa:
            let stdPts = parseTwoColumnPairs(stdInputText)
            let fit = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: stdPts, fiveParameter: elisaModel == .fivePL)
            cachedELISAFit = fit
            if let fit {
                let samps = parseSampleRows(sampleInputText)
                cachedELISAQuants = PlateReaderAssayEngine.quantifyELISASamples(
                    samples: samps,
                    fit: fit,
                    dilutionFactor: Double(dilutionText) ?? 1.0
                )
            } else {
                cachedELISAQuants = []
            }
        case .doseResponse:
            let stdPts = parseTwoColumnPairs(stdInputText)
            cachedDoseFit = PlateReaderAssayEngine.fitLogistic4PLOr5PL(points: stdPts, fiveParameter: false)
        case .viability:
            let groups = parseSampleRows(sampleInputText).map { (name: $0.name, values: $0.replicates) }
            cachedViabilityReport = PlateReaderAssayEngine.analyzeViability(
                groups: groups,
                controlGroupName: ccK8ControlGroup,
                blankMean: Double(blankODText) ?? 0.0
            )
        }
    }

    private func importMatrixCSVFile() {
        FinderFileDropHelper.presentOpenPanel { url in
            if let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .ascii)) {
                let parsed = PlateReaderAssayEngine.parsePlateReaderValues(text)
                if !parsed.isEmpty {
                    matrixImportPreview = parsed
                    pairMatrixWithPlateStore()
                } else {
                    appState.showToast("未能从 \(url.lastPathComponent) 识别 8×12 酶标仪矩阵或孔位读数表")
                }
            }
        }
    }

    private func pairMatrixWithPlateStore() {
        var grouped: [String: [Double]] = [:]
        var blankVals: [Double] = []
        for (well, val) in matrixImportPreview.sorted(by: { $0.key < $1.key }) {
            if let a = plateStore.assignments[well] {
                if a.type == .blank {
                    blankVals.append(val)
                } else {
                    let key = a.sampleName.isEmpty ? a.group : a.sampleName
                    grouped[key, default: []].append(val)
                }
            } else {
                grouped[well, default: []].append(val)
            }
        }
        if !blankVals.isEmpty {
            let bMean = blankVals.reduce(0.0, +) / Double(blankVals.count)
            blankODText = String(format: "%.4f", bMean)
        }
        if !grouped.isEmpty {
            sampleInputText = grouped.sorted { $0.key < $1.key }
                .map { "\($0.key)," + $0.value.map { String($0) }.joined(separator: ",") }
                .joined(separator: "\n")
            appState.showToast("已按微孔板分配映射 \(matrixImportPreview.count) 个酶标孔读数")
        }
    }

    private func exportBCACSV(_ rep: PlateReaderAssayEngine.BCAAnalysisReport) {
        var lines = ["Sample,CorrectedOD,StockConc_ug_mL,StockConc_ug_uL,Protein_uL,LysisBuffer_uL,LoadingBuffer_uL,DiluteWarning"]
        for s in rep.samples {
            lines.append([
                s.sampleName,
                String(format: "%.4f", s.meanODCorrected),
                String(format: "%.1f", s.stockConcUgPerMl),
                String(format: "%.3f", s.stockConcMgPerMl),
                String(format: "%.2f", s.proteinVolumeUl),
                String(format: "%.2f", s.lysisBufferVolumeUl),
                String(format: "%.2f", s.loadingBufferVolumeUl),
                s.isDiluteWarning ? "YES" : "NO"
            ].joined(separator: ","))
        }
        FinderFileDropHelper.saveTextToFile(
            content: lines.joined(separator: "\n") + "\n",
            defaultFileName: "BCA_WB_上样配液方案.csv",
            contentType: .commaSeparatedText,
            toastPrefix: "已导出 BCA 与 WB 配液表"
        )
    }
}
