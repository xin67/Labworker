import Foundation

// MARK: - 曲线拟合与酶标仪定量工作台引擎 (BCA / ELISA 4PL-5PL / IC50 Hill / CCK-8 Dunnett-Tukey-ANOVA)

public enum PlateReaderAssayMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case bca = "BCA / Bradford 蛋白定量"
    case elisa = "ELISA 4PL / 5PL 标准曲线"
    case doseResponse = "剂量-效应 (IC50 / EC50)"
    case viability = "CCK-8 / MTT 细胞活力"

    public var id: String { rawValue }
}

public enum StandardCurveModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case linear = "线性回归 (y = kx + b)"
    case quadratic = "二次多项式 (y = ax² + bx + c)"

    public var id: String { rawValue }
}

public enum ELISACurveModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case fourPL = "4PL 四参数逻辑斯蒂"
    case fivePL = "5PL 五参数非对称逻辑斯蒂"

    public var id: String { rawValue }
}

public enum LogisticWeightingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case invY2 = "1/Y² 加权 (ICH M10)"
    case invY = "1/Y 加权"
    case none = "无权重 (OLS)"

    public var id: String { rawValue }
}

public enum ELISAQuantStatus: String, Codable, Sendable {
    case inRange = "标准区间内"
    case belowLLOQ = "低于检测下限 (<LLOQ)"
    case aboveULOQ = "高于检测上限 (>ULOQ)"
    case outOfModel = "超出回归值域"
}

public enum BCAQuantStatus: String, Codable, Sendable {
    case inRange = "标曲范围内"
    case aboveStandardRange = "超出最高标准品 (外推)"
    case belowStandardRange = "低于最低标准品"
    case parabolicSaturated = "超出抛物线顶点 (饱和)"
}

public enum ViabilityPostHocMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case dunnett = "Dunnett 多对一 (vs Control)"
    case tukeyHSD = "Tukey–Kramer HSD"
    case welchHolm = "Welch's t + Holm"
    case kruskalDunn = "Kruskal–Wallis + Dunn"

    public var id: String { rawValue }
}

public enum PlateReaderAssayEngine {

    // MARK: - 1. 数据模型

    public struct AssayCurvePoint: Identifiable, Sendable, Equatable {
        public let id: Int
        public let x: Double
        public let y: Double

        public init(id: Int, x: Double, y: Double) {
            self.id = id
            self.x = x
            self.y = y
        }
    }

    public struct BCASampleLoadingItem: Identifiable, Sendable, Equatable {
        public let id: String
        public let sampleName: String
        public let meanODCorrected: Double
        public let fittedConcUgPerMl: Double
        public let stockConcUgPerMl: Double
        public let stockConcMgPerMl: Double
        public let proteinVolumeUl: Double
        public let lysisBufferVolumeUl: Double
        public let loadingBufferVolumeUl: Double
        public let maxLoadableUg: Double
        public let isDiluteWarning: Bool
        public let quantStatus: BCAQuantStatus
        public let isOutOfRangeWarning: Bool
        public let warningMessage: String?
    }

    public struct BCAAnalysisReport: Sendable, Equatable {
        public let model: StandardCurveModel
        public let coeffA: Double // quadratic x^2 (0 for linear)
        public let coeffB: Double // slope
        public let coeffC: Double // intercept
        public let r2: Double
        public let rmse: Double
        public let degreesOfFreedom: Int
        public let minStdConc: Double
        public let maxStdConc: Double
        public let equationText: String
        public let standardPoints: [AssayCurvePoint]
        public let curvePoints: [AssayCurvePoint]
        public let samples: [BCASampleLoadingItem]
    }

    public struct LogisticParameterConstraints: Sendable, Equatable {
        public let fixedBottom: Double?
        public let fixedTop: Double?
        public let fixedHillSlope: Double?
        public let fixedAsymmetry: Double?

        public init(
            fixedBottom: Double? = nil,
            fixedTop: Double? = nil,
            fixedHillSlope: Double? = nil,
            fixedAsymmetry: Double? = nil
        ) {
            self.fixedBottom = fixedBottom
            self.fixedTop = fixedTop
            self.fixedHillSlope = fixedHillSlope
            self.fixedAsymmetry = fixedAsymmetry
        }

        public static let unconstrained = LogisticParameterConstraints()
    }

    public struct CalibrationStandardBackCalc: Identifiable, Sendable, Equatable {
        public let id: Int
        public let nominalConc: Double
        public let nReplicates: Int
        public let meanOD: Double
        public let backCalculatedConc: Double?
        public let percentRE: Double?
        public let percentCV: Double?
        public let isBoundaryLevel: Bool
        public let limitPercent: Double
        public let passed: Bool
    }

    public struct ICHM10ValidationReport: Sendable, Equatable {
        public let levels: [CalibrationStandardBackCalc]
        public let nonZeroLevelCount: Int
        public let passedLevelCount: Int
        public let passRatePercent: Double
        public let lloq: Double?
        public let uloq: Double?
        public let meetsICHM10: Bool
        public let warnings: [String]
    }

    public struct LogisticFitResult: Sendable, Equatable {
        public let isFivePL: Bool
        public let weighting: LogisticWeightingMode
        public let constraints: LogisticParameterConstraints
        public let paramA: Double
        public let paramB: Double
        public let paramC: Double
        public let paramD: Double
        public let paramG: Double
        /// 真实半数效应浓度：4PL 时等于 paramC；5PL (Gottschalk & Dunn 2005) 时为 C * (2^(1/G) - 1)^(1/B)
        public let trueEC50: Double
        /// 对数域 log10(EC50) 标准误（来自加权雅可比近似协方差矩阵）
        public let seLog10EC50: Double?
        /// 线性域不对称 95% 置信区间下限 10^(log10(EC50) - t * SE)
        public let ec50CI95Low: Double?
        /// 线性域不对称 95% 置信区间上限 10^(log10(EC50) + t * SE)
        public let ec50CI95High: Double?
        public let seHillSlope: Double?
        public let hillSlopeCI95Low: Double?
        public let hillSlopeCI95High: Double?
        /// 绝对 IC50（响应值等于 50% 对照值时对应的浓度；若曲线未跨越 50% 则为 nil）
        public let absoluteIC50At50: Double?
        public let isEC50Extrapolated: Bool
        public let extrapolationWarning: String?
        public let r2: Double
        public let rmse: Double
        public let weightedRMSE: Double
        public let freeParameterCount: Int
        public let degreesOfFreedom: Int
        public let minStdConc: Double
        public let maxStdConc: Double
        public let effectiveLLOQ: Double
        public let effectiveULOQ: Double
        public let ichM10Report: ICHM10ValidationReport
        public let standardPoints: [AssayCurvePoint]
        public let curvePoints: [AssayCurvePoint]

        /// 相对 IC50 / EC50（上下渐近线中点 (A+D)/2 处的浓度）
        public var relativeIC50: Double { trueEC50 }

        /// 曲线单调性：x -> 0 极限为 y0，x -> +inf 极限为 yInf；递增为 true，递减为 false
        public var isIncreasing: Bool {
            let y0 = (paramB >= 0) ? paramA : paramD
            let yInf = (paramB >= 0) ? paramD : paramA
            return yInf > y0
        }

        public func evaluate(x: Double) -> Double {
            if x <= 0 {
                if paramB > 0 { return paramA }
                if paramB < 0 { return paramD }
                return paramD + (paramA - paramD) / max(1e-15, pow(2.0, paramG))
            }
            let logRatio = log10(x) - log10(max(1e-18, paramC))
            let powerTerm = pow(10.0, max(-30.0, min(30.0, paramB * logRatio)))
            let denom = pow(1.0 + powerTerm, paramG)
            return paramD + (paramA - paramD) / max(1e-15, denom)
        }

        /// 无截断反解浓度（供 ICH M10 回算与 Absolute IC50 使用）
        public func rawInvertX(forY y: Double) -> Double? {
            if abs(paramA - paramD) < 1e-12 || abs(paramB) < 1e-9 { return nil }
            let loY = min(paramA, paramD)
            let hiY = max(paramA, paramD)
            guard y > loY && y < hiY else { return nil }
            let ratio = (paramA - paramD) / (y - paramD)
            guard ratio > 1.0 else { return nil }
            let inner = pow(ratio, 1.0 / max(1e-6, paramG)) - 1.0
            guard inner > 0 else { return nil }
            let x = paramC * pow(inner, 1.0 / paramB)
            return (x.isFinite && x > 0) ? x : nil
        }

        public func invertX(forY y: Double, useValidatedLimits: Bool = false) -> (conc: Double?, status: ELISAQuantStatus) {
            let loY = min(paramA, paramD)
            let hiY = max(paramA, paramD)
            if abs(paramA - paramD) < 1e-12 || abs(paramB) < 1e-9 { return (nil, .outOfModel) }
            let inc = isIncreasing
            if y <= loY {
                return (nil, inc ? .belowLLOQ : .aboveULOQ)
            }
            if y >= hiY {
                return (nil, inc ? .aboveULOQ : .belowLLOQ)
            }
            guard let x = rawInvertX(forY: y) else { return (nil, .outOfModel) }
            let loBound = useValidatedLimits ? effectiveLLOQ : minStdConc
            let hiBound = useValidatedLimits ? effectiveULOQ : maxStdConc
            if x < loBound { return (x, .belowLLOQ) }
            if x > hiBound { return (x, .aboveULOQ) }
            return (x, .inRange)
        }
    }

    public struct ELISASampleQuantItem: Identifiable, Sendable, Equatable {
        public let id: String
        public let sampleName: String
        public let meanOD: Double
        public let replicateCVPercent: Double?
        public let interpolatedConc: Double?
        public let finalConc: Double?
        public let status: ELISAQuantStatus
        public let extrapolationWarning: String?
    }

    public struct NormalityTestResult: Sendable, Equatable {
        public let statisticW: Double
        public let pValue: Double
        public let n: Int
        public let passed: Bool
    }

    public struct HomoscedasticityTestResult: Sendable, Equatable {
        public let fStatistic: Double
        public let dfBetween: Int
        public let dfWithin: Int
        public let pValue: Double
        public let passed: Bool
    }

    public struct KruskalWallisResult: Sendable, Equatable {
        public let hStatistic: Double
        public let df: Int
        public let pValue: Double
    }

    public struct PairwiseComparisonResult: Identifiable, Sendable, Equatable {
        public let id: String
        public let groupA: String
        public let groupB: String
        public let meanDiffPercent: Double
        public let statistic: Double
        public let pAdjusted: Double
        public let method: ViabilityPostHocMethod

        public var significanceStars: String {
            if pAdjusted < 0.001 { return "***" }
            if pAdjusted < 0.01 { return "**" }
            if pAdjusted < 0.05 { return "*" }
            return "ns"
        }
    }

    public struct ViabilityGroupResult: Identifiable, Sendable, Equatable {
        public let id: String
        public let groupName: String
        public let n: Int
        public let meanViabilityPercent: Double
        /// 当 n == 1 时为 nil（禁止伪报 0.0），UI 显示 N/A
        public let sdViabilityPercent: Double?
        public let semViabilityPercent: Double?
        public let pValue: Double?
        public let pAdjusted: Double?
        public let dunnettStatistic: Double?
        public let dunnettPValue: Double?
        public let dunnPAdjusted: Double?
        public let isControl: Bool

        public var significanceStars: String {
            guard let p = pAdjusted ?? pValue, !isControl else { return "" }
            if p < 0.001 { return "***" }
            if p < 0.01 { return "**" }
            if p < 0.05 { return "*" }
            return "ns"
        }
    }

    public struct OneWayANOVAResult: Sendable, Equatable {
        public let ssBetween: Double
        public let ssWithin: Double
        public let dfBetween: Int
        public let dfWithin: Int
        public let fStatistic: Double
        public let pValue: Double
    }

    public struct ViabilityAnalysisReport: Sendable, Equatable {
        public let controlGroup: String
        public let controlMeanRawCorrected: Double
        public let postHocMethod: ViabilityPostHocMethod
        public let groups: [ViabilityGroupResult]
        public let anova: OneWayANOVAResult?
        public let kruskalWallis: KruskalWallisResult?
        public let shapiroWilk: NormalityTestResult?
        public let brownForsythe: HomoscedasticityTestResult?
        public let tukeyPairwise: [PairwiseComparisonResult]
        public let assumptionWarnings: [String]
    }

    // MARK: - 2. 酶标仪 8×12 / 16×24 矩阵与长表自动嗅探解析

    public static func parsePlateReaderValues(_ rawText: String) -> [String: Double] {
        let cleaned = rawText
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = cleaned
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return [:] }

        for idx in 0..<lines.count {
            let delim = PlateLayoutEngine.detectDelimiter(in: lines[idx])
            let cols = PlateLayoutEngine.splitDelimitedLine(lines[idx], delimiter: delim)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var colNumMap: [(index: Int, colNumber: Int)] = []
            for (cIdx, cell) in cols.enumerated() {
                if let cNum = Int(cell), cNum >= 1 && cNum <= 24 {
                    colNumMap.append((cIdx, cNum))
                }
            }
            if colNumMap.count >= 4 {
                var matrixMap: [String: Double] = [:]
                for rIdx in (idx + 1)..<min(lines.count, idx + 20) {
                    let rowCells = PlateLayoutEngine.splitDelimitedLine(lines[rIdx], delimiter: delim)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard let first = rowCells.first?.uppercased(),
                          first.count == 1,
                          let scalar = first.unicodeScalars.first,
                          scalar.value >= 65 && scalar.value <= 80 else { continue }
                    for pair in colNumMap where pair.index < rowCells.count {
                        if let v = Double(rowCells[pair.index]) {
                            matrixMap["\(first)\(pair.colNumber)"] = v
                        }
                    }
                }
                if !matrixMap.isEmpty { return matrixMap }
            }
        }

        let firstDelim = PlateLayoutEngine.detectDelimiter(in: lines[0])
        let headers = PlateLayoutEngine.splitDelimitedLine(lines[0], delimiter: firstDelim).map { $0.lowercased() }
        let wellCol = headers.firstIndex { ["well", "pos", "position", "孔位"].contains($0) } ?? 0
        let valCol = headers.firstIndex { ["od", "value", "signal", "absorbance", "reading", "fluo", "lum", "读数", "吸光度"].contains($0) } ?? (headers.count > 1 ? 1 : 0)

        var longMap: [String: Double] = [:]
        let startRow = headers.contains(where: { ["well", "pos", "position", "孔位", "od", "value", "signal"].contains($0) }) ? 1 : 0
        for idx in startRow..<lines.count {
            let cells = PlateLayoutEngine.splitDelimitedLine(lines[idx], delimiter: firstDelim)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard wellCol < cells.count, valCol < cells.count else { continue }
            let well = cells[wellCol].uppercased()
            if !well.isEmpty, let val = Double(cells[valCol]) {
                longMap[well] = val
            }
        }
        return longMap
    }

    // MARK: - 3. 模式 A：BCA / Bradford 标准曲线拟合（中心化 Householder QR 二次回归）与 WB 上样配液表

    public static func analyzeBCA(
        standards: [(concUgPerMl: Double, od: Double)],
        samples: [(name: String, replicates: [Double])],
        model: StandardCurveModel = .linear,
        blankOD: Double = 0.0,
        dilutionFactor: Double = 1.0,
        targetLoadUg: Double = 20.0,
        targetTotalVolUl: Double = 20.0,
        loadingBufferX: Double = 5.0
    ) -> BCAAnalysisReport? {
        let validStd = standards
            .filter { $0.concUgPerMl.isFinite && $0.od.isFinite }
            .map { (conc: $0.concUgPerMl, y: $0.od - blankOD) }
        guard validStd.count >= 2 else { return nil }

        let a: Double
        let b: Double
        let c: Double
        let eqText: String
        let freeParams: Int

        if model == .quadratic && validStd.count >= 3,
           let quad = solveQuadraticLeastSquaresQR(points: validStd.map { ($0.conc, $0.y) }) {
            a = quad.a; b = quad.b; c = quad.c
            freeParams = 3
            eqText = String(format: "y = %.4e·x² + %.4e·x %+.4f", a, b, c)
        } else {
            guard let reg = QPCRStatistics.linearRegression(validStd.map { ($0.conc, $0.y) }) else { return nil }
            a = 0.0; b = reg.slope; c = reg.intercept
            freeParams = 2
            eqText = String(format: "y = %.4e·x %+.4f", b, c)
        }

        let meanY = validStd.reduce(0.0) { $0 + $1.y } / Double(validStd.count)
        var sse = 0.0
        var sst = 0.0
        for p in validStd {
            let pred = a * p.conc * p.conc + b * p.conc + c
            let err = p.y - pred
            sse += err * err
            let dev = p.y - meanY
            sst += dev * dev
        }
        let r2 = sst > 1e-15 ? max(0.0, 1.0 - sse / sst) : 1.0
        let df = max(1, validStd.count - freeParams)
        let rmse = sqrt(sse / Double(df))

        let minX = validStd.map(\.conc).min() ?? 0.0
        let maxX = validStd.map(\.conc).max() ?? 2000.0
        var curve: [AssayCurvePoint] = []
        let steps = 40
        for i in 0...steps {
            let x = minX + (maxX - minX) * Double(i) / Double(steps)
            let y = a * x * x + b * x + c
            curve.append(AssayCurvePoint(id: i, x: x, y: y))
        }

        let bufVol = targetTotalVolUl / max(1.0, loadingBufferX)
        let maxAvailSampleVol = max(0.0, targetTotalVolUl - bufVol)
        let safeDil = max(0.01, dilutionFactor)

        let quantSamples: [BCASampleLoadingItem] = samples.enumerated().compactMap { idx, samp in
            let validVals = samp.replicates.filter(\.isFinite)
            guard !validVals.isEmpty else { return nil }
            let meanCorr = validVals.reduce(0.0, +) / Double(validVals.count) - blankOD
            let inv = invertPolynomialStrict(a: a, b: b, c: c, y: meanCorr, minX: minX, maxX: maxX)

            let clampedConc = max(0.0, inv.conc ?? 0.0)
            let stockUgMl = clampedConc * safeDil
            let stockUgUl = stockUgMl / 1000.0

            let isSaturated = (inv.status == .parabolicSaturated)
            let idealProteinVol = (!isSaturated && stockUgUl > 1e-9) ? (targetLoadUg / stockUgUl) : (isSaturated ? 0.0 : maxAvailSampleVol)
            let isDilute = !isSaturated && (idealProteinVol > maxAvailSampleVol + 1e-6)
            let actualProteinVol = isSaturated ? 0.0 : min(maxAvailSampleVol, max(0.0, idealProteinVol))
            let actualLysisVol = isSaturated ? 0.0 : max(0.0, maxAvailSampleVol - actualProteinVol)
            let maxLoadable = isSaturated ? 0.0 : (stockUgUl * maxAvailSampleVol)

            let isOOR = (inv.status != .inRange)
            let warnMsg: String? = {
                switch inv.status {
                case .inRange: return nil
                case .parabolicSaturated:
                    return L10n.tr(
                        "样本 OD 超出二次抛物线顶点范围（判别式 < 0），已标记饱和，请稀释后重测",
                        "Sample OD exceeds the quadratic parabola vertex (discriminant < 0); marked saturated — dilute and re-assay"
                    )
                case .aboveStandardRange:
                    return L10n.tr(
                        "反算浓度超出最高标准品 (\(String(format: "%.0f", maxX)) µg/mL)，外推结果仅供参考，建议稀释重测",
                        "Back-calculated concentration exceeds highest standard (\(String(format: "%.0f", maxX)) µg/mL); extrapolation unvalidated — dilute and re-assay"
                    )
                case .belowStandardRange:
                    return L10n.tr(
                        "反算浓度低于最低标准品 (\(String(format: "%.0f", minX)) µg/mL)",
                        "Back-calculated concentration is below lowest standard (\(String(format: "%.0f", minX)) µg/mL)"
                    )
                }
            }()

            return BCASampleLoadingItem(
                id: "\(idx)_\(samp.name)",
                sampleName: samp.name,
                meanODCorrected: meanCorr,
                fittedConcUgPerMl: clampedConc,
                stockConcUgPerMl: stockUgMl,
                stockConcMgPerMl: stockUgMl / 1000.0,
                proteinVolumeUl: actualProteinVol,
                lysisBufferVolumeUl: actualLysisVol,
                loadingBufferVolumeUl: bufVol,
                maxLoadableUg: maxLoadable,
                isDiluteWarning: isDilute,
                quantStatus: inv.status,
                isOutOfRangeWarning: isOOR,
                warningMessage: warnMsg
            )
        }

        return BCAAnalysisReport(
            model: (freeParams == 3 ? .quadratic : .linear),
            coeffA: a,
            coeffB: b,
            coeffC: c,
            r2: r2,
            rmse: rmse,
            degreesOfFreedom: df,
            minStdConc: minX,
            maxStdConc: maxX,
            equationText: eqText,
            standardPoints: validStd.enumerated().map { AssayCurvePoint(id: $0.offset, x: $0.element.conc, y: $0.element.y) },
            curvePoints: curve,
            samples: quantSamples
        )
    }

    // MARK: - 4. 模式 B / C：4PL / 5PL / Hill IC50 加权 Levenberg-Marquardt 引擎（ICH M10 + 95% CI + 参数约束）

    public static func fitLogistic4PLOr5PL(
        points rawPoints: [(x: Double, y: Double)],
        fiveParameter: Bool = false,
        weighting: LogisticWeightingMode = .invY2,
        constraints: LogisticParameterConstraints = .unconstrained
    ) -> LogisticFitResult? {
        let allPts = rawPoints
            .filter { $0.x >= 0 && $0.x.isFinite && $0.y.isFinite }
            .sorted { $0.x < $1.x }
        let posPts = allPts.filter { $0.x > 0 }
        guard posPts.count >= 2 else { return nil }

        let ys = allPts.map(\.y)
        // 无量纲缩放 y 轴至 O(1) 区间，彻底消除化学发光/荧光（10^6–10^7 RLU）下 1/Y² 权重与阻尼/主元阈值的量级失配
        let yScale = max(1e-6, ys.map { abs($0) }.max() ?? 1.0)
        let ysScaled = ys.map { $0 / yScale }
        let yMinS = ysScaled.min() ?? 0.0
        let yMaxS = ysScaled.max() ?? 1.0
        let ySpanS = max(1e-3, yMaxS - yMinS)
        let yFirstS = ysScaled.first ?? yMinS
        let yLastS = ysScaled.last ?? yMaxS
        let looksIncreasing = (yLastS >= yFirstS)

        // 按单调方向与显式 Hill 符号映射 Bottom / Top 约束：
        // B >= 0 时 y(0)=A, y(inf)=D；B < 0 时 y(0)=D, y(inf)=A
        let negFixedHill = (constraints.fixedHillSlope ?? 1.0) < 0
        let bottomIsIndex0 = negFixedHill ? !looksIncreasing : looksIncreasing
        var fixedValsScaled: [Int: Double] = [:]
        if let fb = constraints.fixedBottom {
            fixedValsScaled[bottomIsIndex0 ? 0 : 3] = fb / yScale
        }
        if let ft = constraints.fixedTop {
            fixedValsScaled[bottomIsIndex0 ? 3 : 0] = ft / yScale
        }
        if let fh = constraints.fixedHillSlope {
            fixedValsScaled[1] = fh
        }
        if fiveParameter, let fg = constraints.fixedAsymmetry {
            fixedValsScaled[4] = max(0.1, min(10.0, fg))
        }

        let totalParamDim = fiveParameter ? 5 : 4
        let freeIndices = (0..<totalParamDim).filter { fixedValsScaled[$0] == nil }
        let freeCount = freeIndices.count
        guard allPts.count >= max(2, freeCount) else { return nil }

        let logPosXs = posPts.map { log10($0.x) }
        let logMin = logPosXs.min() ?? -2.0
        let logMax = logPosXs.max() ?? 2.0
        let logMid = 0.5 * (logMin + logMax)

        // 零浓度点用 nil 表示 logX（数学极限 x -> 0+）
        let optLogXs: [Double?] = allPts.map { $0.x > 0 ? log10($0.x) : nil }
        let weightsScaled = computeWeights(ys: ysScaled, mode: weighting)
        let rawWeights = computeWeights(ys: ys, mode: weighting)

        // 同步遵循 bottomIsIndex0，防止 fixedHillSlope < 0 时构造 A == D 平坦初始曲线
        let aInitS = fixedValsScaled[0] ?? (bottomIsIndex0 ? yMinS : yMaxS)
        let dInitS = fixedValsScaled[3] ?? (bottomIsIndex0 ? yMaxS : yMinS)

        // 合理物理参数边界（避免渐近线发散并放宽 G 至 [0.1, 10.0]）
        let loBoundsS: [Double] = [
            yMinS - 3.0 * ySpanS,
            -8.0,
            logMin - 4.0,
            yMinS - 3.0 * ySpanS,
            0.1
        ]
        let hiBoundsS: [Double] = [
            yMaxS + 3.0 * ySpanS,
            8.0,
            logMax + 4.0,
            yMaxS + 3.0 * ySpanS,
            10.0
        ]

        var candidateStarts: [[Double]] = []
        let uStarts = [logMid, logMin + 0.30 * (logMax - logMin), logMin + 0.70 * (logMax - logMin)]
        let bStarts: [Double] = fixedValsScaled[1].map { [$0] } ?? [1.0, 1.8, 0.6]
        let gStarts: [Double] = fiveParameter ? (fixedValsScaled[4].map { [$0] } ?? [1.0, 0.5, 2.2]) : [1.0]

        for u0 in uStarts {
            for b0 in bStarts {
                for g0 in gStarts {
                    var theta = fiveParameter ? [aInitS, b0, u0, dInitS, g0] : [aInitS, b0, u0, dInitS]
                    for (k, v) in fixedValsScaled where k < theta.count {
                        theta[k] = v
                    }
                    candidateStarts.append(theta)
                }
            }
        }

        var bestThetaS: [Double]? = nil
        var bestWSSES = Double.infinity

        for startTheta in candidateStarts {
            let (optTheta, wsse) = runWeightedLevenbergMarquardt(
                optLogXs: optLogXs,
                ys: ysScaled,
                weights: weightsScaled,
                initialTheta: startTheta,
                fiveParameter: fiveParameter,
                fixedVals: fixedValsScaled,
                loBounds: loBoundsS,
                hiBounds: hiBoundsS
            )
            if wsse.isFinite && wsse < bestWSSES {
                bestWSSES = wsse
                bestThetaS = optTheta
            }
        }

        guard let thetaS = bestThetaS else { return nil }
        var theta = thetaS
        theta[0] = thetaS[0] * yScale
        theta[3] = thetaS[3] * yScale
        let pA = theta[0]
        let pB = theta[1]
        let pU = theta[2]
        let pC = pow(10.0, pU)
        let pD = theta[3]
        let pG = fiveParameter ? min(10.0, max(0.1, theta[4])) : 1.0

        // 5PL 真实 EC50 (Gottschalk & Dunn, Anal Biochem 2005): EC50 = C * (2^(1/G) - 1)^(1/B)
        let trueEC50: Double = {
            if !fiveParameter || abs(pG - 1.0) < 1e-12 { return pC }
            let term = pow(2.0, 1.0 / pG) - 1.0
            guard term > 0, abs(pB) > 1e-9 else { return pC }
            let val = pC * pow(term, 1.0 / pB)
            return val.isFinite && val > 0 ? val : pC
        }()

        // 无权重 R² / RMSE（自由度修正 n - p）与原始量纲加权 RMSE
        let meanY = ys.reduce(0.0, +) / Double(ys.count)
        var rawSSE = 0.0
        var rawWSSE = 0.0
        var sst = 0.0
        for i in 0..<allPts.count {
            let pred = evalLogisticOpt(optLogX: optLogXs[i], theta: theta, fiveParameter: fiveParameter)
            let r = ys[i] - pred
            rawSSE += r * r
            rawWSSE += rawWeights[i] * r * r
            let dev = ys[i] - meanY
            sst += dev * dev
        }
        let r2 = sst > 1e-15 ? max(0.0, 1.0 - rawSSE / sst) : 1.0
        let df = allPts.count - freeCount
        let safeDf = max(1, df)
        let rmse = sqrt(rawSSE / Double(safeDf))
        let weightedRMSE = sqrt(rawWSSE / Double(safeDf))

        // 在无量纲缩放空间计算协方差矩阵 Σ = σ² (J^T W J)^(-1) 与 95% 置信区间（u/B/G 对正尺度变换数学不变）
        var seLog10EC50: Double? = nil
        var ec50CILow: Double? = nil
        var ec50CIHigh: Double? = nil
        var seHill: Double? = nil
        var hillCILow: Double? = nil
        var hillCIHigh: Double? = nil

        if df > 0 && freeCount > 0,
           let tCrit = QPCRStatistics.studentTQuantileTwoSided(alpha: 0.05, df: Double(df)) {
            let jacFree = computeWeightedJacobian(
                optLogXs: optLogXs,
                weights: weightsScaled,
                theta: thetaS,
                fiveParameter: fiveParameter,
                freeIndices: freeIndices,
                loBounds: loBoundsS,
                hiBounds: hiBoundsS
            )
            var jtj = Array(repeating: Array(repeating: 0.0, count: freeCount), count: freeCount)
            for r in 0..<freeCount {
                for c in 0..<freeCount {
                    var s = 0.0
                    for i in 0..<allPts.count { s += jacFree[i][r] * jacFree[i][c] }
                    jtj[r][c] = s
                }
            }
            if let invJTJ = invertMatrix(jtj) {
                let sigma2S = bestWSSES / Double(df)
                var fullCov = Array(repeating: Array(repeating: 0.0, count: totalParamDim), count: totalParamDim)
                for (rLoc, rGlob) in freeIndices.enumerated() {
                    for (cLoc, cGlob) in freeIndices.enumerated() {
                        fullCov[rGlob][cGlob] = sigma2S * invJTJ[rLoc][cLoc]
                    }
                }
                // Delta 法计算 log10(trueEC50) 方差：
                // h(u, B, G) = u + (1/B) * log10(2^(1/G) - 1)，在 G=1 处无奇点且 ∂h/∂G = -2ln(2)/(B ln(10)) ≠ 0
                var gradH = Array(repeating: 0.0, count: totalParamDim)
                gradH[2] = 1.0
                if fiveParameter && abs(pB) > 1e-9 {
                    let twoInvG = pow(2.0, 1.0 / pG)
                    let term = twoInvG - 1.0
                    if term > 1e-15 {
                        gradH[1] = -log10(term) / (pB * pB)
                        gradH[4] = -(twoInvG * log(2.0)) / (pB * pG * pG * term * log(10.0))
                    }
                }
                var varLogEC50 = 0.0
                for r in 0..<totalParamDim {
                    for c in 0..<totalParamDim {
                        varLogEC50 += gradH[r] * fullCov[r][c] * gradH[c]
                    }
                }
                if varLogEC50.isFinite && varLogEC50 >= 0 {
                    let se = sqrt(varLogEC50)
                    let logEC = log10(max(1e-18, trueEC50))
                    seLog10EC50 = se
                    ec50CILow = pow(10.0, logEC - tCrit * se)
                    ec50CIHigh = pow(10.0, logEC + tCrit * se)
                }
                if fullCov[1][1].isFinite && fullCov[1][1] >= 0 && fixedValsScaled[1] == nil {
                    let seB = sqrt(fullCov[1][1])
                    seHill = seB
                    hillCILow = pB - tCrit * seB
                    hillCIHigh = pB + tCrit * seB
                }
            }
        }

        let minStdC = posPts.first?.x ?? pC * 0.01
        let maxStdC = posPts.last?.x ?? pC * 100.0
        let isExtrap = (trueEC50 < minStdC || trueEC50 > maxStdC)
        let extrapWarn: String? = isExtrap ? L10n.tr(
            "⚠️ 估计 EC50/IC50 (\(BioMathFormatter.format(trueEC50))) 落在实测浓度区间 [\(BioMathFormatter.format(minStdC)), \(BioMathFormatter.format(maxStdC))] 之外，存在外推不确定性",
            "⚠️ Estimated EC50/IC50 (\(BioMathFormatter.format(trueEC50))) lies outside tested concentration range [\(BioMathFormatter.format(minStdC)), \(BioMathFormatter.format(maxStdC))] (extrapolated)"
        ) : nil

        // 先构造临时拟合对象用于 ICH M10 回算与 Absolute IC50 计算
        let tempFit = LogisticFitResult(
            isFivePL: fiveParameter,
            weighting: weighting,
            constraints: constraints,
            paramA: pA,
            paramB: pB,
            paramC: pC,
            paramD: pD,
            paramG: pG,
            trueEC50: trueEC50,
            seLog10EC50: seLog10EC50,
            ec50CI95Low: ec50CILow,
            ec50CI95High: ec50CIHigh,
            seHillSlope: seHill,
            hillSlopeCI95Low: hillCILow,
            hillSlopeCI95High: hillCIHigh,
            absoluteIC50At50: nil,
            isEC50Extrapolated: isExtrap,
            extrapolationWarning: extrapWarn,
            r2: r2,
            rmse: rmse,
            weightedRMSE: weightedRMSE,
            freeParameterCount: freeCount,
            degreesOfFreedom: df,
            minStdConc: minStdC,
            maxStdConc: maxStdC,
            effectiveLLOQ: minStdC,
            effectiveULOQ: maxStdC,
            ichM10Report: ICHM10ValidationReport(levels: [], nonZeroLevelCount: 0, passedLevelCount: 0, passRatePercent: 0, lloq: minStdC, uloq: maxStdC, meetsICHM10: false, warnings: []),
            standardPoints: [],
            curvePoints: []
        )

        let absIC50 = tempFit.rawInvertX(forY: 50.0)
        let ichReport = evaluateICHM10Calibration(points: allPts, fit: tempFit)
        let effLLOQ = ichReport.lloq ?? minStdC
        let effULOQ = ichReport.uloq ?? maxStdC

        var curve: [AssayCurvePoint] = []
        let plotLo = logMin - 0.15
        let plotHi = logMax + 0.15
        let steps = 60
        for i in 0...steps {
            let l = plotLo + (plotHi - plotLo) * Double(i) / Double(steps)
            let x = pow(10.0, l)
            curve.append(AssayCurvePoint(id: i, x: x, y: tempFit.evaluate(x: x)))
        }

        return LogisticFitResult(
            isFivePL: fiveParameter,
            weighting: weighting,
            constraints: constraints,
            paramA: pA,
            paramB: pB,
            paramC: pC,
            paramD: pD,
            paramG: pG,
            trueEC50: trueEC50,
            seLog10EC50: seLog10EC50,
            ec50CI95Low: ec50CILow,
            ec50CI95High: ec50CIHigh,
            seHillSlope: seHill,
            hillSlopeCI95Low: hillCILow,
            hillSlopeCI95High: hillCIHigh,
            absoluteIC50At50: absIC50,
            isEC50Extrapolated: isExtrap,
            extrapolationWarning: extrapWarn,
            r2: r2,
            rmse: rmse,
            weightedRMSE: weightedRMSE,
            freeParameterCount: freeCount,
            degreesOfFreedom: df,
            minStdConc: minStdC,
            maxStdConc: maxStdC,
            effectiveLLOQ: effLLOQ,
            effectiveULOQ: effULOQ,
            ichM10Report: ichReport,
            standardPoints: allPts.enumerated().map { AssayCurvePoint(id: $0.offset, x: $0.element.x, y: $0.element.y) },
            curvePoints: curve
        )
    }

    /// ICH M10 (2022) 生物分析配体结合法（LBA）标准曲线回算验收：
    /// 至少 >= 6 个非零浓度水平，且 >= 75% 的非零标准品满足 |%RE| <= 20%（LLOQ 与 ULOQ 放宽至 <= 25%），复孔 %CV 同限。
    public static func evaluateICHM10Calibration(
        points: [(x: Double, y: Double)],
        fit: LogisticFitResult
    ) -> ICHM10ValidationReport {
        let posPts = points.filter { $0.x > 0 && $0.x.isFinite && $0.y.isFinite }.sorted { $0.x < $1.x }
        // 合并相同标称浓度的复孔
        var grouped: [(conc: Double, ys: [Double])] = []
        for pt in posPts {
            if let last = grouped.last, abs(pt.x - last.conc) <= max(1e-12, 1e-6 * last.conc) {
                grouped[grouped.count - 1].ys.append(pt.y)
            } else {
                grouped.append((pt.x, [pt.y]))
            }
        }

        let levelCount = grouped.count
        var rows: [CalibrationStandardBackCalc] = []
        var passedCount = 0
        var warnings: [String] = []

        for (idx, grp) in grouped.enumerated() {
            let isBoundary = (idx == 0 || idx == levelCount - 1)
            let limit = isBoundary ? 25.0 : 20.0
            let meanOD = QPCRStatistics.mean(grp.ys)
            let cvPct: Double? = {
                guard grp.ys.count >= 2, let sd = QPCRStatistics.sampleSd(grp.ys), abs(meanOD) > 1e-12 else { return nil }
                return (sd / abs(meanOD)) * 100.0
            }()
            let backX = fit.rawInvertX(forY: meanOD)
            let pctRE: Double? = backX.map { (($0 - grp.conc) / grp.conc) * 100.0 }

            let reOK = pctRE.map { abs($0) <= limit } ?? false
            let cvOK = cvPct.map { $0 <= limit } ?? true
            let ok = reOK && cvOK
            if ok { passedCount += 1 }

            rows.append(CalibrationStandardBackCalc(
                id: idx,
                nominalConc: grp.conc,
                nReplicates: grp.ys.count,
                meanOD: meanOD,
                backCalculatedConc: backX,
                percentRE: pctRE,
                percentCV: cvPct,
                isBoundaryLevel: isBoundary,
                limitPercent: limit,
                passed: ok
            ))
        }

        let passRate = levelCount > 0 ? (Double(passedCount) / Double(levelCount)) * 100.0 : 0.0
        let passingConcs = rows.filter(\.passed).map(\.nominalConc)
        let lloq = passingConcs.min()
        let uloq = passingConcs.max()
        // ICH M10 4.2.3: 须同时满足 >= 75% 且至少 6 个合格非零标准品浓度水平
        let meets = (levelCount >= 6) && (passedCount >= 6) && (passRate >= 75.0 - 1e-9) && (lloq != nil && uloq != nil)

        if levelCount < 6 {
            warnings.append(L10n.tr(
                "ICH M10 要求至少 6 个非零标准品浓度水平（当前 \(levelCount) 个）",
                "ICH M10 requires at least 6 non-zero calibration levels (currently \(levelCount))"
            ))
        } else if passedCount < 6 {
            warnings.append(L10n.tr(
                "ICH M10 要求至少 6 个合格非零标准品浓度水平（当前仅 \(passedCount)/\(levelCount) 达标）",
                "ICH M10 requires at least 6 passing non-zero calibration levels (currently \(passedCount)/\(levelCount) passed)"
            ))
        }
        if passRate < 75.0 - 1e-9 {
            warnings.append(L10n.tr(
                "ICH M10 回算达标率 \(String(format: "%.1f%%", passRate)) 低于 75% 门限（\(passedCount)/\(levelCount) 达标）",
                "ICH M10 back-calculation pass rate \(String(format: "%.1f%%", passRate)) is below the 75% threshold (\(passedCount)/\(levelCount) passed)"
            ))
        }
        for row in rows where !row.passed {
            let reFailed = row.percentRE.map { abs($0) > row.limitPercent } ?? true
            let cvFailed = row.percentCV.map { $0 > row.limitPercent } ?? false
            let reStr = row.percentRE.map { String(format: "%+.1f%%", $0) } ?? "N/A"
            let cvStr = row.percentCV.map { String(format: "%.1f%%", $0) } ?? "N/A"
            if reFailed && cvFailed {
                warnings.append(L10n.tr(
                    "标准点 \(BioMathFormatter.format(row.nominalConc)) 回算偏差 %RE=\(reStr) 与复孔 %CV=\(cvStr) 均超出 ±\(Int(row.limitPercent))% 限值",
                    "Standard \(BioMathFormatter.format(row.nominalConc)) back-calc %RE=\(reStr) and replicate %CV=\(cvStr) both exceed ±\(Int(row.limitPercent))% limit"
                ))
            } else if cvFailed {
                warnings.append(L10n.tr(
                    "标准点 \(BioMathFormatter.format(row.nominalConc)) 复孔精密度 %CV=\(cvStr) 超出 \(Int(row.limitPercent))% 限值",
                    "Standard \(BioMathFormatter.format(row.nominalConc)) replicate %CV=\(cvStr) exceeds \(Int(row.limitPercent))% limit"
                ))
            } else {
                warnings.append(L10n.tr(
                    "标准点 \(BioMathFormatter.format(row.nominalConc)) 回算偏差 %RE=\(reStr) 超出 ±\(Int(row.limitPercent))% 限值",
                    "Standard \(BioMathFormatter.format(row.nominalConc)) back-calc %RE=\(reStr) exceeds ±\(Int(row.limitPercent))% limit"
                ))
            }
        }

        return ICHM10ValidationReport(
            levels: rows,
            nonZeroLevelCount: levelCount,
            passedLevelCount: passedCount,
            passRatePercent: passRate,
            lloq: lloq,
            uloq: uloq,
            meetsICHM10: meets,
            warnings: warnings
        )
    }

    public static func quantifyELISASamples(
        samples: [(name: String, replicates: [Double])],
        fit: LogisticFitResult,
        dilutionFactor: Double = 1.0,
        useValidatedLimits: Bool = true
    ) -> [ELISASampleQuantItem] {
        let dil = max(0.01, dilutionFactor)
        return samples.enumerated().compactMap { idx, s in
            let vals = s.replicates.filter(\.isFinite)
            guard !vals.isEmpty else { return nil }
            let meanOD = vals.reduce(0.0, +) / Double(vals.count)
            let cvPct: Double? = {
                guard vals.count >= 2, let sd = QPCRStatistics.sampleSd(vals), abs(meanOD) > 1e-12 else { return nil }
                return (sd / abs(meanOD)) * 100.0
            }()
            let inv = fit.invertX(forY: meanOD, useValidatedLimits: useValidatedLimits)
            // 超出有效 [LLOQ, ULOQ] 区间时阻断未校验外推（finalConc = nil）并标示原因
            let finalC: Double? = (inv.status == .inRange) ? inv.conc.map { $0 * dil } : nil
            let extrapWarn: String? = {
                switch inv.status {
                case .inRange: return nil
                case .belowLLOQ:
                    return L10n.tr(
                        "低于定量下限 LLOQ (\(BioMathFormatter.format(useValidatedLimits ? fit.effectiveLLOQ : fit.minStdConc)))，已阻断未校验外推",
                        "Below LLOQ (\(BioMathFormatter.format(useValidatedLimits ? fit.effectiveLLOQ : fit.minStdConc))); unvalidated extrapolation blocked"
                    )
                case .aboveULOQ:
                    return L10n.tr(
                        "高于定量上限 ULOQ (\(BioMathFormatter.format(useValidatedLimits ? fit.effectiveULOQ : fit.maxStdConc)))，请提高稀释倍数重测",
                        "Above ULOQ (\(BioMathFormatter.format(useValidatedLimits ? fit.effectiveULOQ : fit.maxStdConc))); dilute and re-assay"
                    )
                case .outOfModel:
                    return L10n.tr(
                        "信号超出逻辑斯蒂渐近线值域，无法反算浓度",
                        "Signal lies outside logistic asymptote bounds; back-calculation infeasible"
                    )
                }
            }()
            return ELISASampleQuantItem(
                id: "\(idx)_\(s.name)",
                sampleName: s.name,
                meanOD: meanOD,
                replicateCVPercent: cvPct,
                interpolatedConc: inv.conc,
                finalConc: finalC,
                status: inv.status,
                extrapolationWarning: extrapWarn
            )
        }
    }

    // MARK: - 5. 模式 D：CCK-8 / MTT 细胞活力归一化、Dunnett / Tukey-Kramer / Welch-Holm / Kruskal-Dunn & 假设检验

    public static func analyzeViability(
        groups rawGroups: [(name: String, values: [Double])],
        controlGroupName: String = "Control",
        blankMean: Double = 0.0,
        postHocMethod: ViabilityPostHocMethod = .dunnett
    ) -> ViabilityAnalysisReport? {
        // 移除 max(0, v - blankMean) 截断，保留真实随机测量误差以避免人为制造零方差
        let nonEmpty = rawGroups.compactMap { g -> (name: String, corr: [Double])? in
            let valid = g.values.filter(\.isFinite).map { $0 - blankMean }
            guard !valid.isEmpty else { return nil }
            return (g.name, valid)
        }
        guard !nonEmpty.isEmpty else { return nil }

        let ctrlIdx = nonEmpty.firstIndex(where: { $0.name.caseInsensitiveCompare(controlGroupName) == .orderedSame }) ?? 0
        let ctrlEntry = nonEmpty[ctrlIdx]
        let ctrlMeanRaw = ctrlEntry.corr.reduce(0.0, +) / Double(ctrlEntry.corr.count)
        let ctrlDenom = abs(ctrlMeanRaw) > 1e-9 ? ctrlMeanRaw : 1e-9

        let normGroups: [(name: String, viabilities: [Double], isCtrl: Bool)] = nonEmpty.enumerated().map { idx, entry in
            let isCtrl = (idx == ctrlIdx)
            let pcts = entry.corr.map { $0 * 100.0 / ctrlDenom }
            return (entry.name, pcts, isCtrl)
        }

        // 统一过滤 count >= 2 的有效统计组，防止 n == 1 组污染 ANOVA / Dunnett / Tukey / Dunn 比较族大小与 Shapiro-Wilk 残差
        let validStatEntries = normGroups.enumerated().filter { $0.element.viabilities.count >= 2 }
        let validStatArrays = validStatEntries.map { $0.element.viabilities }
        let validCtrlLocalIdx = validStatEntries.firstIndex(where: { $0.offset == ctrlIdx })

        let anova = computeOneWayANOVA(groups: validStatArrays)
        let kw = computeKruskalWallis(groups: validStatArrays)

        // 正态性检验（仅对 count >= 2 组的组内残差执行 Shapiro-Wilk）与方差齐性检验（Brown-Forsythe）
        let residuals: [Double] = validStatEntries.flatMap { entry -> [Double] in
            let vals = entry.element.viabilities
            let m = QPCRStatistics.mean(vals)
            return vals.map { $0 - m }
        }
        let swResult = shapiroWilkTest(residuals)
        let bfResult = brownForsytheTest(groups: validStatArrays)

        var warnings: [String] = []
        if let sw = swResult, !sw.passed {
            warnings.append(L10n.tr(
                "Shapiro–Wilk 正态性检验偏离正态假设 (W=\(String(format: "%.3f", sw.statisticW)), p=\(String(format: "%.4f", sw.pValue)))，建议参考 Kruskal–Wallis + Dunn 非参数检验",
                "Shapiro–Wilk normality test rejected normality (W=\(String(format: "%.3f", sw.statisticW)), p=\(String(format: "%.4f", sw.pValue))); consider Kruskal–Wallis + Dunn"
            ))
        }
        if let bf = bfResult, !bf.passed {
            warnings.append(L10n.tr(
                "Brown–Forsythe 方差齐性检验提示组间方差不齐 (F=\(String(format: "%.2f", bf.fStatistic)), p=\(String(format: "%.4f", bf.pValue)))，建议参考 Welch's t + Holm 或非参数检验",
                "Brown–Forsythe test indicates heteroscedasticity (F=\(String(format: "%.2f", bf.fStatistic)), p=\(String(format: "%.4f", bf.pValue))); consider Welch's t + Holm or non-parametric test"
            ))
        }

        // 1) Welch's t + Holm（组内 n == 1 时自动跳过，p = nil）
        let ctrlVias = normGroups[ctrlIdx].viabilities
        var welchRawPs: [Double?] = []
        for g in normGroups {
            if g.isCtrl || g.viabilities.count < 2 || ctrlVias.count < 2 {
                welchRawPs.append(nil)
            } else {
                welchRawPs.append(QPCRStatistics.welchTTest(g.viabilities, ctrlVias)?.p)
            }
        }
        let welchAdjPs = QPCRStatistics.holmAdjustOptional(welchRawPs)

        // 2) Dunnett 多对一检验 (vs Control)，仅在 count >= 2 有效组族内计算并映射回原索引
        var dunnettRes: [Int: (tStat: Double, pValue: Double)] = [:]
        if let localCtrl = validCtrlLocalIdx {
            let localDunnett = computeDunnettVsControl(groups: validStatArrays, controlIndex: localCtrl)
            for (locIdx, val) in localDunnett {
                dunnettRes[validStatEntries[locIdx].offset] = val
            }
        }

        // 3) Tukey-Kramer HSD 全两两比较（仅在 count >= 2 有效组族内计算）
        let tukeyPairs = computeTukeyKramerHSD(namedGroups: validStatEntries.map { ($0.element.name, $0.element.viabilities) })

        // 4) Dunn 非参数事后检验 (vs Control, Holm 校正，仅在 count >= 2 有效组族内计算并映射回原索引)
        var dunnVsCtrl: [Int: Double] = [:]
        if let localCtrl = validCtrlLocalIdx {
            let localDunn = computeDunnVsControl(groups: validStatArrays, controlIndex: localCtrl)
            for (locIdx, pVal) in localDunn {
                dunnVsCtrl[validStatEntries[locIdx].offset] = pVal
            }
        }

        let outGroups: [ViabilityGroupResult] = normGroups.enumerated().map { idx, g in
            let meanV = QPCRStatistics.mean(g.viabilities)
            // n == 1 时 sd 与 sem 为 nil（不再伪报 0.0）
            let sdV: Double? = g.viabilities.count >= 2 ? QPCRStatistics.sampleSd(g.viabilities) : nil
            let semV: Double? = g.viabilities.count >= 2 ? QPCRStatistics.sem(g.viabilities) : nil

            let hasSufficientN = !g.isCtrl && g.viabilities.count >= 2 && ctrlVias.count >= 2
            let dStat = hasSufficientN ? dunnettRes[idx]?.tStat : nil
            let dP = hasSufficientN ? dunnettRes[idx]?.pValue : nil
            let dunnP = hasSufficientN ? dunnVsCtrl[idx] : nil

            let selectedP: Double?
            let selectedPAdj: Double?
            if !hasSufficientN {
                selectedP = nil
                selectedPAdj = nil
            } else {
                switch postHocMethod {
                case .dunnett:
                    selectedP = dP
                    selectedPAdj = dP
                case .tukeyHSD:
                    let ctrlName = normGroups[ctrlIdx].name
                    let pair = tukeyPairs.first {
                        ($0.groupA == g.name && $0.groupB == ctrlName) || ($0.groupB == g.name && $0.groupA == ctrlName)
                    }
                    selectedP = pair?.pAdjusted
                    selectedPAdj = pair?.pAdjusted
                case .welchHolm:
                    selectedP = welchRawPs[idx]
                    selectedPAdj = welchAdjPs[idx]
                case .kruskalDunn:
                    selectedP = dunnP
                    selectedPAdj = dunnP
                }
            }

            return ViabilityGroupResult(
                id: "\(idx)_\(g.name)",
                groupName: g.name,
                n: g.viabilities.count,
                meanViabilityPercent: meanV,
                sdViabilityPercent: sdV,
                semViabilityPercent: semV,
                pValue: selectedP,
                pAdjusted: selectedPAdj,
                dunnettStatistic: dStat,
                dunnettPValue: dP,
                dunnPAdjusted: dunnP,
                isControl: g.isCtrl
            )
        }

        return ViabilityAnalysisReport(
            controlGroup: ctrlEntry.name,
            controlMeanRawCorrected: ctrlMeanRaw,
            postHocMethod: postHocMethod,
            groups: outGroups,
            anova: anova,
            kruskalWallis: kw,
            shapiroWilk: swResult,
            brownForsythe: bfResult,
            tukeyPairwise: tukeyPairs,
            assumptionWarnings: warnings
        )
    }

    public static func computeOneWayANOVA(groups: [[Double]]) -> OneWayANOVAResult? {
        let nonEmpty = groups.filter { !$0.isEmpty }
        let k = nonEmpty.count
        let totalN = nonEmpty.reduce(0) { $0 + $1.count }
        guard k >= 2, totalN > k else { return nil }

        let allVals = nonEmpty.flatMap { $0 }
        let grandMean = QPCRStatistics.mean(allVals)

        var ssBetween = 0.0
        var ssWithin = 0.0
        for grp in nonEmpty {
            let gm = QPCRStatistics.mean(grp)
            let diffGrand = gm - grandMean
            ssBetween += Double(grp.count) * diffGrand * diffGrand
            for v in grp {
                let d = v - gm
                ssWithin += d * d
            }
        }

        let df1 = k - 1
        let df2 = totalN - k
        let msB = ssBetween / Double(df1)
        let msW = ssWithin / Double(df2)
        let fStat = msW > 1e-15 ? (msB / msW) : (msB > 0 ? 1e9 : 0.0)
        let x = Double(df2) / (Double(df2) + Double(df1) * max(0.0, fStat))
        let pVal = min(1.0, max(0.0, QPCRStatistics.incompleteBeta(a: Double(df2) / 2.0, b: Double(df1) / 2.0, x: x)))

        return OneWayANOVAResult(
            ssBetween: ssBetween,
            ssWithin: ssWithin,
            dfBetween: df1,
            dfWithin: df2,
            fStatistic: fStat,
            pValue: pVal
        )
    }

    /// Dunnett (1955 / 1964) 双侧多对一检验（各处理组 vs Control），通过精确二维数值积分求多元 t 分布 p 值
    public static func computeDunnettVsControl(
        groups: [[Double]],
        controlIndex: Int = 0
    ) -> [Int: (tStat: Double, pValue: Double)] {
        guard groups.count >= 2, controlIndex >= 0, controlIndex < groups.count else { return [:] }
        guard let anova = computeOneWayANOVA(groups: groups), anova.dfWithin >= 1 else { return [:] }

        let ctrl = groups[controlIndex]
        guard !ctrl.isEmpty else { return [:] }
        let n0 = Double(ctrl.count)
        let mean0 = QPCRStatistics.mean(ctrl)
        let msW = anova.ssWithin / Double(anova.dfWithin)
        let sp = sqrt(max(0.0, msW))
        let df = Double(anova.dfWithin)

        var treatIndices: [Int] = []
        var rhos: [Double] = []
        for idx in 0..<groups.count where idx != controlIndex && !groups[idx].isEmpty {
            treatIndices.append(idx)
            let ni = Double(groups[idx].count)
            rhos.append(sqrt(ni / (ni + n0)))
        }
        guard !treatIndices.isEmpty else { return [:] }

        var results: [Int: (tStat: Double, pValue: Double)] = [:]
        for idx in treatIndices {
            let grp = groups[idx]
            let ni = Double(grp.count)
            let meanI = QPCRStatistics.mean(grp)
            let se = sp * sqrt(1.0 / ni + 1.0 / n0)
            let tStat: Double
            if se > 1e-15 {
                tStat = (meanI - mean0) / se
            } else {
                tStat = abs(meanI - mean0) > 1e-15 ? (meanI > mean0 ? 1e6 : -1e6) : 0.0
            }
            let pVal = dunnettTwoSidedPValue(absT: abs(tStat), df: df, rhos: rhos)
            results[idx] = (tStat, pVal)
        }
        return results
    }

    /// Tukey–Kramer HSD 全两两比较（支持不平衡样本量）
    public static func computeTukeyKramerHSD(
        namedGroups: [(name: String, values: [Double])]
    ) -> [PairwiseComparisonResult] {
        let nonEmpty = namedGroups.filter { !$0.values.isEmpty }
        let k = nonEmpty.count
        guard k >= 2, let anova = computeOneWayANOVA(groups: nonEmpty.map(\.values)), anova.dfWithin >= 1 else {
            return []
        }
        let msW = anova.ssWithin / Double(anova.dfWithin)
        let df = Double(anova.dfWithin)
        var out: [PairwiseComparisonResult] = []
        for i in 0..<k {
            for j in (i + 1)..<k {
                let mA = QPCRStatistics.mean(nonEmpty[i].values)
                let mB = QPCRStatistics.mean(nonEmpty[j].values)
                let nA = Double(nonEmpty[i].values.count)
                let nB = Double(nonEmpty[j].values.count)
                let se = sqrt(0.5 * msW * (1.0 / nA + 1.0 / nB))
                let qStat = se > 1e-15 ? abs(mA - mB) / se : (abs(mA - mB) > 1e-15 ? 1e6 : 0.0)
                let pVal = studentizedRangeUpperTailP(q: qStat, k: k, df: df)
                out.append(PairwiseComparisonResult(
                    id: "\(i)_\(j)",
                    groupA: nonEmpty[i].name,
                    groupB: nonEmpty[j].name,
                    meanDiffPercent: mA - mB,
                    statistic: qStat,
                    pAdjusted: pVal,
                    method: .tukeyHSD
                ))
            }
        }
        return out
    }

    /// Brown–Forsythe 方差齐性检验（基于组中位数绝对离差的 One-Way ANOVA）
    public static func brownForsytheTest(groups: [[Double]]) -> HomoscedasticityTestResult? {
        let valid = groups.filter { $0.count >= 2 }
        guard valid.count >= 2 else { return nil }
        let absDevs: [[Double]] = valid.compactMap { grp in
            guard let med = QPCRStatistics.median(grp) else { return nil }
            return grp.map { abs($0 - med) }
        }
        guard let anova = computeOneWayANOVA(groups: absDevs) else { return nil }
        return HomoscedasticityTestResult(
            fStatistic: anova.fStatistic,
            dfBetween: anova.dfBetween,
            dfWithin: anova.dfWithin,
            pValue: anova.pValue,
            passed: anova.pValue >= 0.05
        )
    }

    /// Kruskal–Wallis 非参数检验（含结值 tie 校正与 χ²_{k-1} 近似 p 值）
    public static func computeKruskalWallis(groups: [[Double]]) -> KruskalWallisResult? {
        let valid = groups.filter { !$0.isEmpty }
        let k = valid.count
        let totalN = valid.reduce(0) { $0 + $1.count }
        guard k >= 2, totalN >= k + 1 else { return nil }

        let (ranksByGroup, tieSum) = computePooledAverageRanks(groups: valid)
        let N = Double(totalN)
        var sumR2OverN = 0.0
        for rGrp in ranksByGroup {
            let rSum = rGrp.reduce(0.0, +)
            sumR2OverN += (rSum * rSum) / Double(rGrp.count)
        }
        var H = (12.0 / (N * (N + 1.0))) * sumR2OverN - 3.0 * (N + 1.0)
        let tieDenom = 1.0 - tieSum / (N * N * N - N)
        if tieDenom > 1e-12 {
            H /= tieDenom
        }
        H = max(0.0, H)
        let df = k - 1
        let pVal = chiSquareUpperTailP(x: H, df: Double(df))
        return KruskalWallisResult(hStatistic: H, df: df, pValue: pVal)
    }

    /// Dunn 非参数事后检验 (vs Control, Holm 校正)
    public static func computeDunnVsControl(
        groups: [[Double]],
        controlIndex: Int = 0
    ) -> [Int: Double] {
        guard groups.count >= 2, controlIndex >= 0, controlIndex < groups.count else { return [:] }
        let validIndices = groups.indices.filter { !groups[$0].isEmpty }
        guard validIndices.count >= 2, !groups[controlIndex].isEmpty else { return [:] }

        let validGroups = validIndices.map { groups[$0] }
        let (ranksByGroup, tieSum) = computePooledAverageRanks(groups: validGroups)
        let totalN = validGroups.reduce(0) { $0 + $1.count }
        guard totalN > 2 else { return [:] }
        let N = Double(totalN)
        let baseVar = (N * (N + 1.0) / 12.0) - tieSum / (12.0 * (N - 1.0))

        guard let localCtrlIdx = validIndices.firstIndex(of: controlIndex) else { return [:] }
        let ctrlRanks = ranksByGroup[localCtrlIdx]
        let ctrlMeanRank = QPCRStatistics.mean(ctrlRanks)
        let n0 = Double(ctrlRanks.count)

        var rawPs: [Double?] = Array(repeating: nil, count: groups.count)
        for (locIdx, origIdx) in validIndices.enumerated() where origIdx != controlIndex {
            let gRanks = ranksByGroup[locIdx]
            let gMeanRank = QPCRStatistics.mean(gRanks)
            let ni = Double(gRanks.count)
            let denom = sqrt(max(1e-15, baseVar * (1.0 / ni + 1.0 / n0)))
            let z = abs(gMeanRank - ctrlMeanRank) / denom
            let p = min(1.0, max(0.0, 2.0 * (1.0 - normalCDF(z))))
            rawPs[origIdx] = p
        }
        let adjPs = QPCRStatistics.holmAdjustOptional(rawPs)
        var out: [Int: Double] = [:]
        for idx in 0..<groups.count {
            if let p = adjPs[idx] { out[idx] = p }
        }
        return out
    }

    /// Shapiro–Wilk 正态性检验（Royston 1992 / 1995 AS R94 近似算法，支持 3 <= n <= 5000）
    public static func shapiroWilkTest(_ rawValues: [Double]) -> NormalityTestResult? {
        let vals = rawValues.filter(\.isFinite).sorted()
        let n = vals.count
        guard n >= 3 && n <= 5000 else { return nil }

        let meanV = QPCRStatistics.mean(vals)
        var ss = 0.0
        for v in vals {
            let d = v - meanV
            ss += d * d
        }
        if ss < 1e-15 {
            return NormalityTestResult(statisticW: 1.0, pValue: 1.0, n: n, passed: true)
        }

        // 标准正态顺序统计量期望值近似 m_i = Φ^{-1}((i - 0.375) / (n + 0.25))
        let nf = Double(n)
        var m = [Double](repeating: 0.0, count: n)
        var mSumSq = 0.0
        for i in 0..<n {
            let p = (Double(i + 1) - 0.375) / (nf + 0.25)
            let mi = inverseNormalCDF(p)
            m[i] = mi
            mSumSq += mi * mi
        }

        var a = [Double](repeating: 0.0, count: n)
        if n == 3 {
            let sq = 0.7071067811865476
            a[0] = -sq; a[1] = 0.0; a[2] = sq
        } else {
            let u = 1.0 / sqrt(nf)
            // Royston (1992) 多项式系数计算末端权重 a_n, a_{n-1}
            let c1 = [-2.706056, 4.434685, -2.071190, -0.147981, 0.221157, 0.0]
            let c2 = [-3.582633, 5.682633, -1.752461, -0.293762, 0.042981, 0.0]
            let poly = { (coef: [Double], x: Double, last: Double) -> Double in
                ((((coef[0] * x + coef[1]) * x + coef[2]) * x + coef[3]) * x + coef[4]) * x + last
            }
            let an = poly(c1, u, m[n - 1] / sqrt(mSumSq))
            a[n - 1] = an
            a[0] = -an

            var phi: Double
            var startIdx = 1
            if n >= 6 {
                let an1 = poly(c2, u, m[n - 2] / sqrt(mSumSq))
                a[n - 2] = an1
                a[1] = -an1
                phi = (mSumSq - 2.0 * m[n - 1] * m[n - 1] - 2.0 * m[n - 2] * m[n - 2]) / max(1e-12, 1.0 - 2.0 * an * an - 2.0 * an1 * an1)
                startIdx = 2
            } else {
                phi = (mSumSq - 2.0 * m[n - 1] * m[n - 1]) / max(1e-12, 1.0 - 2.0 * an * an)
                startIdx = 1
            }
            let sqrtPhi = sqrt(max(1e-12, phi))
            for i in startIdx..<(n - startIdx) {
                a[i] = m[i] / sqrtPhi
            }
        }

        var num = 0.0
        for i in 0..<n {
            num += a[i] * vals[i]
        }
        let w = min(1.0, max(0.0, (num * num) / ss))

        // Royston (1992) 正态化变换求 p 值
        let pVal: Double
        if n == 3 {
            let pi6 = 1.909859317102744 // 6 / pi
            let stqr = 1.0471975511965976 // asin(sqrt(0.75))
            let val = max(0.0, min(1.0, (asin(sqrt(w)) - stqr) * pi6))
            // Royston AS R94: n = 3 时 p = (6/pi) * (asin(sqrt(W)) - asin(sqrt(0.75))) = val
            pVal = val
        } else {
            let y = log(max(1e-15, 1.0 - w))
            let mu: Double
            let sigma: Double
            if n <= 11 {
                let gamma = 0.459 * nf - 2.273
                let yTrans = -log(max(1e-15, gamma - y))
                mu = -0.0006714 * pow(nf, 3) + 0.025054 * pow(nf, 2) - 0.39978 * nf + 0.5440
                sigma = exp(-0.0020322 * pow(nf, 3) + 0.062767 * pow(nf, 2) - 0.77857 * nf + 1.3822)
                let z = (yTrans - mu) / max(1e-12, sigma)
                pVal = min(1.0, max(0.0, 1.0 - normalCDF(z)))
            } else {
                let lnN = log(nf)
                mu = 0.0038915 * pow(lnN, 3) - 0.083751 * pow(lnN, 2) - 0.31082 * lnN - 1.5861
                sigma = exp(0.0030302 * pow(lnN, 2) - 0.082676 * lnN - 0.4803)
                let z = (y - mu) / max(1e-12, sigma)
                pVal = min(1.0, max(0.0, 1.0 - normalCDF(z)))
            }
        }

        return NormalityTestResult(statisticW: w, pValue: pVal, n: n, passed: pVal >= 0.05)
    }

    // MARK: - 6. 数值求解器（中心化 Householder QR 二次拟合 + WLS Levenberg-Marquardt + 精确分布积分）

    private static func computeWeights(ys: [Double], mode: LogisticWeightingMode) -> [Double] {
        switch mode {
        case .none:
            return Array(repeating: 1.0, count: ys.count)
        case .invY:
            let yMax = max(1e-6, ys.map { abs($0) }.max() ?? 1.0)
            let floorVal = max(1e-6, 1e-3 * yMax)
            return ys.map { 1.0 / max(floorVal, abs($0)) }
        case .invY2:
            let yMax = max(1e-6, ys.map { abs($0) }.max() ?? 1.0)
            let floorVal = max(1e-6, 1e-3 * yMax)
            return ys.map {
                let d = max(floorVal, abs($0))
                return 1.0 / (d * d)
            }
        }
    }

    private static func evalLogisticOpt(optLogX: Double?, theta: [Double], fiveParameter: Bool) -> Double {
        let a = theta[0]
        let b = theta[1]
        let u = theta[2]
        let d = theta[3]
        let g = fiveParameter ? min(10.0, max(0.1, theta[4])) : 1.0
        guard let logX = optLogX else {
            // x == 0 数学极限
            if b > 0 { return a }
            if b < 0 { return d }
            return d + (a - d) / max(1e-15, pow(2.0, g))
        }
        let expo = max(-30.0, min(30.0, b * (logX - u)))
        let pTerm = pow(10.0, expo)
        let denom = pow(1.0 + pTerm, g)
        return d + (a - d) / max(1e-15, denom)
    }

    private static func weightedSSE(
        optLogXs: [Double?],
        ys: [Double],
        weights: [Double],
        theta: [Double],
        fiveParameter: Bool
    ) -> Double {
        var s = 0.0
        for i in 0..<optLogXs.count {
            let r = ys[i] - evalLogisticOpt(optLogX: optLogXs[i], theta: theta, fiveParameter: fiveParameter)
            s += weights[i] * r * r
        }
        return s
    }

    /// 加权雅可比矩阵 W^(1/2) * J：
    /// - 对 x == 0 使用解析极限偏导（B > 0 时 ∂f/∂A = 1，B < 0 时 ∂f/∂D = 1，其余为 0）；
    /// - 对贴近参数边界的分量使用向后或前向差分，内部使用二阶中心差分，彻底消除 G 边界死区。
    private static func computeWeightedJacobian(
        optLogXs: [Double?],
        weights: [Double],
        theta: [Double],
        fiveParameter: Bool,
        freeIndices: [Int],
        loBounds: [Double],
        hiBounds: [Double]
    ) -> [[Double]] {
        let n = optLogXs.count
        let pFree = freeIndices.count
        var jac = Array(repeating: Array(repeating: 0.0, count: pFree), count: n)

        for (locCol, globCol) in freeIndices.enumerated() {
            let h = 1e-6 * max(1.0, abs(theta[globCol]))
            let lo = loBounds[globCol]
            let hi = hiBounds[globCol]

            let canPlus = (theta[globCol] + h) <= hi
            let canMinus = (theta[globCol] - h) >= lo

            var tPlus = theta
            var tMinus = theta
            let denom: Double
            if canPlus && canMinus {
                tPlus[globCol] = theta[globCol] + h
                tMinus[globCol] = theta[globCol] - h
                denom = 2.0 * h
            } else if canMinus {
                tPlus[globCol] = theta[globCol]
                tMinus[globCol] = theta[globCol] - h
                denom = h
            } else {
                tPlus[globCol] = min(hi, theta[globCol] + h)
                tMinus[globCol] = theta[globCol]
                denom = max(1e-12, tPlus[globCol] - tMinus[globCol])
            }

            for i in 0..<n {
                let sw = sqrt(weights[i])
                if optLogXs[i] == nil {
                    // x == 0 解析偏导
                    if theta[1] > 0 {
                        jac[i][locCol] = (globCol == 0) ? sw : 0.0
                    } else if theta[1] < 0 {
                        jac[i][locCol] = (globCol == 3) ? sw : 0.0
                    } else {
                        let fp = evalLogisticOpt(optLogX: nil, theta: tPlus, fiveParameter: fiveParameter)
                        let fm = evalLogisticOpt(optLogX: nil, theta: tMinus, fiveParameter: fiveParameter)
                        jac[i][locCol] = sw * (fp - fm) / denom
                    }
                } else {
                    let fp = evalLogisticOpt(optLogX: optLogXs[i], theta: tPlus, fiveParameter: fiveParameter)
                    let fm = evalLogisticOpt(optLogX: optLogXs[i], theta: tMinus, fiveParameter: fiveParameter)
                    jac[i][locCol] = sw * (fp - fm) / denom
                }
            }
        }
        return jac
    }

    private static func runWeightedLevenbergMarquardt(
        optLogXs: [Double?],
        ys: [Double],
        weights: [Double],
        initialTheta: [Double],
        fiveParameter: Bool,
        fixedVals: [Int: Double],
        loBounds: [Double],
        hiBounds: [Double]
    ) -> (theta: [Double], wsse: Double) {
        let totalDim = initialTheta.count
        let freeIndices = (0..<totalDim).filter { fixedVals[$0] == nil }
        let pFree = freeIndices.count
        let n = optLogXs.count
        var theta = initialTheta
        for j in 0..<totalDim {
            if let fv = fixedVals[j] {
                theta[j] = fv
            } else {
                theta[j] = min(hiBounds[j], max(loBounds[j], theta[j]))
            }
        }
        var curWSSE = weightedSSE(optLogXs: optLogXs, ys: ys, weights: weights, theta: theta, fiveParameter: fiveParameter)
        guard pFree > 0 else { return (theta, curWSSE) }

        var lambda = 1e-2

        for _ in 0..<120 {
            var weightedRes = Array(repeating: 0.0, count: n)
            for i in 0..<n {
                let f0 = evalLogisticOpt(optLogX: optLogXs[i], theta: theta, fiveParameter: fiveParameter)
                weightedRes[i] = sqrt(weights[i]) * (ys[i] - f0)
            }

            let jac = computeWeightedJacobian(
                optLogXs: optLogXs,
                weights: weights,
                theta: theta,
                fiveParameter: fiveParameter,
                freeIndices: freeIndices,
                loBounds: loBounds,
                hiBounds: hiBounds
            )

            var jtj = Array(repeating: Array(repeating: 0.0, count: pFree), count: pFree)
            var jtr = Array(repeating: 0.0, count: pFree)
            for r in 0..<pFree {
                for c in 0..<pFree {
                    var sum = 0.0
                    for i in 0..<n { sum += jac[i][r] * jac[i][c] }
                    jtj[r][c] = sum
                }
                var sumR = 0.0
                for i in 0..<n { sumR += jac[i][r] * weightedRes[i] }
                jtr[r] = sumR
            }

            for r in 0..<pFree {
                jtj[r][r] += lambda * max(1e-6, jtj[r][r]) + 1e-10
            }

            guard let delta = solveLinearSystem(matrix: jtj, rhs: jtr) else {
                lambda = min(1e8, lambda * 10.0)
                if lambda >= 1e7 { break }
                continue
            }

            var cand = theta
            for (locIdx, globIdx) in freeIndices.enumerated() {
                cand[globIdx] = min(hiBounds[globIdx], max(loBounds[globIdx], cand[globIdx] + delta[locIdx]))
            }

            let candWSSE = weightedSSE(optLogXs: optLogXs, ys: ys, weights: weights, theta: cand, fiveParameter: fiveParameter)
            if candWSSE < curWSSE {
                let relGain = abs(curWSSE - candWSSE) / max(1e-14, curWSSE)
                theta = cand
                curWSSE = candWSSE
                lambda = max(1e-8, lambda * 0.3)
                if relGain < 1e-11 { break }
            } else {
                lambda = min(1e8, lambda * 5.0)
                if lambda >= 1e7 { break }
            }
        }
        return (theta, curWSSE)
    }

    /// 中心化缩放 + Householder QR 分解求解二次多项式最小二乘（消除原始幂次正规方程 κ~10¹³ 病态性）
    private static func solveQuadraticLeastSquaresQR(points: [(x: Double, y: Double)]) -> (a: Double, b: Double, c: Double)? {
        let n = points.count
        guard n >= 3 else { return nil }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let xMean = QPCRStatistics.mean(xs)
        let xSdRaw = QPCRStatistics.sampleSd(xs) ?? 1.0
        let sx = xSdRaw > 1e-12 ? xSdRaw : 1.0

        // 构造 n × 3 缩放 Vandermonde 矩阵 [1, t, t^2]，其中 t = (x - xMean) / sx
        var mat = Array(repeating: Array(repeating: 0.0, count: 3), count: n)
        var rhs = ys
        for i in 0..<n {
            let t = (xs[i] - xMean) / sx
            mat[i][0] = 1.0
            mat[i][1] = t
            mat[i][2] = t * t
        }

        // Householder QR 原地分解
        let p = 3
        for k in 0..<p {
            var normSq = 0.0
            for i in k..<n { normSq += mat[i][k] * mat[i][k] }
            let normX = sqrt(normSq)
            guard normX > 1e-14 else { return nil }
            let sign = mat[k][k] >= 0 ? 1.0 : -1.0
            var v = Array(repeating: 0.0, count: n - k)
            v[0] = mat[k][k] + sign * normX
            for i in 1..<(n - k) { v[i] = mat[k + i][k] }
            var vNormSq = 0.0
            for val in v { vNormSq += val * val }
            guard vNormSq > 1e-30 else { continue }
            let beta = 2.0 / vNormSq

            // 更新 mat[k..<n, k..<p]
            for j in k..<p {
                var dot = 0.0
                for i in 0..<(n - k) { dot += v[i] * mat[k + i][j] }
                for i in 0..<(n - k) { mat[k + i][j] -= beta * dot * v[i] }
            }
            // 更新 rhs[k..<n]
            var dotY = 0.0
            for i in 0..<(n - k) { dotY += v[i] * rhs[k + i] }
            for i in 0..<(n - k) { rhs[k + i] -= beta * dotY * v[i] }
        }

        // 上三角 R 回代求解 [cTilde, bTilde, aTilde]
        var sol = Array(repeating: 0.0, count: p)
        for i in stride(from: p - 1, through: 0, by: -1) {
            guard abs(mat[i][i]) > 1e-14 else { return nil }
            var sum = rhs[i]
            for j in (i + 1)..<p { sum -= mat[i][j] * sol[j] }
            sol[i] = sum / mat[i][i]
        }
        guard sol.allSatisfy(\.isFinite) else { return nil }

        let cTilde = sol[0]
        let bTilde = sol[1]
        let aTilde = sol[2]

        // 还原至原坐标 y = a*x^2 + b*x + c
        let a = aTilde / (sx * sx)
        let b = bTilde / sx - 2.0 * aTilde * xMean / (sx * sx)
        let c = cTilde - bTilde * xMean / sx + aTilde * xMean * xMean / (sx * sx)
        guard a.isFinite && b.isFinite && c.isFinite else { return nil }
        return (a, b, c)
    }

    /// 严格多项式反算：判别式 < 0 时绝不静默线性降级，明确标记 .parabolicSaturated；超标曲范围标记外推状态
    private static func invertPolynomialStrict(
        a: Double,
        b: Double,
        c: Double,
        y: Double,
        minX: Double,
        maxX: Double
    ) -> (conc: Double?, status: BCAQuantStatus) {
        if abs(a) < 1e-15 {
            guard abs(b) > 1e-12 else { return (nil, .parabolicSaturated) }
            let x = (y - c) / b
            if x > maxX + 1e-9 { return (x, .aboveStandardRange) }
            if x < minX - 1e-9 { return (x, .belowStandardRange) }
            return (x, .inRange)
        }
        let disc = b * b - 4.0 * a * (c - y)
        guard disc >= 0 else {
            return (nil, .parabolicSaturated)
        }
        let sqrtD = sqrt(disc)
        let r1 = (-b + sqrtD) / (2.0 * a)
        let r2 = (-b - sqrtD) / (2.0 * a)
        let inRangeCands = [r1, r2].filter { $0 >= minX - 1e-9 && $0 <= maxX + 1e-9 }
        if let hit = inRangeCands.first {
            return (hit, .inRange)
        }
        // 选择最接近标曲区间的实根并标示超范围状态
        let dist: (Double) -> Double = { r in
            if r < minX { return minX - r }
            if r > maxX { return r - maxX }
            return 0.0
        }
        let chosen = dist(r1) <= dist(r2) ? r1 : r2
        if chosen > maxX { return (chosen, .aboveStandardRange) }
        return (chosen, .belowStandardRange)
    }

    private static func solveLinearSystem(matrix A: [[Double]], rhs b: [Double]) -> [Double]? {
        let n = b.count
        guard n > 0 else { return nil }
        var mat = A
        var vec = b
        var matScale = 0.0
        for r in 0..<n {
            for c in 0..<n { matScale = max(matScale, abs(mat[r][c])) }
        }
        guard matScale > 0 else { return nil }
        let pivotEps = max(1e-30, 1e-14 * matScale)
        for i in 0..<n {
            var pivotRow = i
            var maxVal = abs(mat[i][i])
            for r in (i + 1)..<n {
                if abs(mat[r][i]) > maxVal {
                    maxVal = abs(mat[r][i])
                    pivotRow = r
                }
            }
            guard maxVal > pivotEps else { return nil }
            if pivotRow != i {
                mat.swapAt(i, pivotRow)
                vec.swapAt(i, pivotRow)
            }
            let piv = mat[i][i]
            for r in (i + 1)..<n {
                let factor = mat[r][i] / piv
                for c in i..<n { mat[r][c] -= factor * mat[i][c] }
                vec[r] -= factor * vec[i]
            }
        }
        var sol = Array(repeating: 0.0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = vec[i]
            for c in (i + 1)..<n { sum -= mat[i][c] * sol[c] }
            sol[i] = sum / mat[i][i]
        }
        return sol.allSatisfy(\.isFinite) ? sol : nil
    }

    private static func invertMatrix(_ A: [[Double]]) -> [[Double]]? {
        let n = A.count
        guard n > 0 else { return nil }
        var aug = Array(repeating: Array(repeating: 0.0, count: 2 * n), count: n)
        var matScale = 0.0
        for i in 0..<n {
            for j in 0..<n {
                aug[i][j] = A[i][j]
                matScale = max(matScale, abs(A[i][j]))
            }
            aug[i][n + i] = 1.0
        }
        guard matScale > 0 else { return nil }
        let pivotEps = max(1e-30, 1e-14 * matScale)
        for i in 0..<n {
            var pivotRow = i
            var maxVal = abs(aug[i][i])
            for r in (i + 1)..<n {
                if abs(aug[r][i]) > maxVal {
                    maxVal = abs(aug[r][i])
                    pivotRow = r
                }
            }
            guard maxVal > pivotEps else { return nil }
            if pivotRow != i { aug.swapAt(i, pivotRow) }
            let piv = aug[i][i]
            for c in 0..<(2 * n) { aug[i][c] /= piv }
            for r in 0..<n where r != i {
                let factor = aug[r][i]
                for c in 0..<(2 * n) { aug[r][c] -= factor * aug[i][c] }
            }
        }
        var inv = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n {
                let v = aug[i][n + j]
                guard v.isFinite else { return nil }
                inv[i][j] = v
            }
        }
        return inv
    }

    // MARK: - 精确统计分布辅助函数（正态 CDF/逆 CDF、χ²、Dunnett 多元 t 与 Studentized Range）

    private static func normalCDF(_ x: Double) -> Double {
        0.5 * (1.0 + erf(x / sqrt(2.0)))
    }

    private static func normalPDF(_ x: Double) -> Double {
        0.3989422804014327 * exp(-0.5 * x * x)
    }

    /// Acklam 有理逼近求标准正态逆 CDF (相对精度 < 1.15e-9)
    private static func inverseNormalCDF(_ p: Double) -> Double {
        let pp = min(1.0 - 1e-15, max(1e-15, p))
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                  1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                  6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                 3.754408661907416e+00]
        let pLow = 0.02425
        let pHigh = 1.0 - pLow
        if pp < pLow {
            let q = sqrt(-2.0 * log(pp))
            return (((((c[0]*q + c[1])*q + c[2])*q + c[3])*q + c[4])*q + c[5]) /
                   ((((d[0]*q + d[1])*q + d[2])*q + d[3])*q + 1.0)
        } else if pp <= pHigh {
            let q = pp - 0.5
            let r = q * q
            return (((((a[0]*r + a[1])*r + a[2])*r + a[3])*r + a[4])*r + a[5]) * q /
                   (((((b[0]*r + b[1])*r + b[2])*r + b[3])*r + b[4])*r + 1.0)
        } else {
            let q = sqrt(-2.0 * log(1.0 - pp))
            return -(((((c[0]*q + c[1])*q + c[2])*q + c[3])*q + c[4])*q + c[5]) /
                    ((((d[0]*q + d[1])*q + d[2])*q + d[3])*q + 1.0)
        }
    }

    /// 32 点 Gauss-Legendre 节点与权重（缓存常量，用于区间 [-1, 1] 精确积分）
    private static let gl32: (nodes: [Double], weights: [Double]) = {
        let n = 32
        var nodes = [Double](repeating: 0.0, count: n)
        var weights = [Double](repeating: 0.0, count: n)
        let m = n / 2
        for i in 0..<m {
            var z = cos(Double.pi * (Double(i) + 0.75) / (Double(n) + 0.5))
            var pp = 0.0
            for _ in 0..<20 {
                var p1 = 1.0
                var p2 = 0.0
                for j in 1...n {
                    let p3 = p2
                    p2 = p1
                    p1 = ((2.0 * Double(j) - 1.0) * z * p2 - (Double(j) - 1.0) * p3) / Double(j)
                }
                pp = Double(n) * (z * p1 - p2) / (z * z - 1.0)
                let z1 = z
                z = z1 - p1 / pp
                if abs(z - z1) < 1e-15 { break }
            }
            nodes[i] = -z
            nodes[n - 1 - i] = z
            let w = 2.0 / ((1.0 - z * z) * pp * pp)
            weights[i] = w
            weights[n - 1 - i] = w
        }
        return (nodes, weights)
    }()

    /// χ_ν 分布对数密度（s > 0）
    private static func logChiPDF(s: Double, df: Double) -> Double {
        let halfDf = 0.5 * df
        return (1.0 - halfDf) * log(2.0) + (df - 1.0) * log(s) - 0.5 * s * s - QPCRStatistics.logGamma(halfDf)
    }

    /// Dunnett 双侧精确 p 值：1 - ∫_0^∞ f_{χ_ν}(s) [ ∫_{-∞}^∞ φ(z) ∏_i (Φ((d·s/√ν - ρ_i z)/√(1-ρ_i²)) - Φ((-d·s/√ν - ρ_i z)/√(1-ρ_i²))) dz ] ds
    private static func dunnettTwoSidedPValue(absT d: Double, df: Double, rhos: [Double]) -> Double {
        guard d > 0 else { return 1.0 }
        guard d < 1e4 else { return 0.0 }
        let m = rhos.count
        if m == 1 {
            return QPCRStatistics.studentTTwoSidedP(t: d, df: df) ?? 1.0
        }
        let sqrtDf = sqrt(df)
        let sCenter = sqrt(max(0.5, df - 1.0))
        let sLo = max(1e-6, sCenter - 6.5)
        let sHi = sCenter + 7.5
        let sHalf = 0.5 * (sHi - sLo)
        let sMid = 0.5 * (sHi + sLo)

        let zLo = -7.0
        let zHi = 7.0
        let zHalf = 0.5 * (zHi - zLo)
        let zMid = 0.5 * (zHi + zLo)

        let oneMinusRho2Sqrt = rhos.map { sqrt(max(1e-12, 1.0 - $0 * $0)) }
        let nodes = gl32.nodes
        let weights = gl32.weights

        var probAccept = 0.0
        for isIdx in 0..<nodes.count {
            let s = sMid + sHalf * nodes[isIdx]
            let logFs = logChiPDF(s: s, df: df)
            if logFs < -35.0 { continue }
            let fs = exp(logFs)
            let dsScaled = d * s / sqrtDf

            var innerSum = 0.0
            for izIdx in 0..<nodes.count {
                let z = zMid + zHalf * nodes[izIdx]
                var prod = 1.0
                for j in 0..<m {
                    let denom = oneMinusRho2Sqrt[j]
                    let hiArg = (dsScaled - rhos[j] * z) / denom
                    let loArg = (-dsScaled - rhos[j] * z) / denom
                    let diff = normalCDF(hiArg) - normalCDF(loArg)
                    if diff <= 0 {
                        prod = 0.0
                        break
                    }
                    prod *= diff
                }
                innerSum += weights[izIdx] * normalPDF(z) * prod
            }
            probAccept += weights[isIdx] * fs * (zHalf * innerSum)
        }
        probAccept *= sHalf
        return min(1.0, max(0.0, 1.0 - probAccept))
    }

    /// Studentized Range Q_{k, df} 上尾概率 P(Q >= q)
    private static func studentizedRangeUpperTailP(q: Double, k: Int, df: Double) -> Double {
        guard q > 0 else { return 1.0 }
        guard q < 1e4 else { return 0.0 }
        if k == 2 {
            // Q_{2, df} = sqrt(2) * |t_{df}|
            return QPCRStatistics.studentTTwoSidedP(t: q / sqrt(2.0), df: df) ?? 1.0
        }
        let sqrtDf = sqrt(df)
        let sCenter = sqrt(max(0.5, df - 1.0))
        let sLo = max(1e-6, sCenter - 6.5)
        let sHi = sCenter + 7.5
        let sHalf = 0.5 * (sHi - sLo)
        let sMid = 0.5 * (sHi + sLo)

        let zLo = -7.0
        let zHi = 7.0
        let zHalf = 0.5 * (zHi - zLo)
        let zMid = 0.5 * (zHi + zLo)

        let kf = Double(k)
        let km1 = Double(k - 1)
        let nodes = gl32.nodes
        let weights = gl32.weights

        var probAccept = 0.0
        for isIdx in 0..<nodes.count {
            let s = sMid + sHalf * nodes[isIdx]
            let logFs = logChiPDF(s: s, df: df)
            if logFs < -35.0 { continue }
            let fs = exp(logFs)
            let qsScaled = q * s / sqrtDf

            var innerSum = 0.0
            for izIdx in 0..<nodes.count {
                let z = zMid + zHalf * nodes[izIdx]
                let span = max(0.0, normalCDF(z + qsScaled) - normalCDF(z))
                if span > 0 {
                    innerSum += weights[izIdx] * kf * normalPDF(z) * pow(span, km1)
                }
            }
            probAccept += weights[isIdx] * fs * (zHalf * innerSum)
        }
        probAccept *= sHalf
        return min(1.0, max(0.0, 1.0 - probAccept))
    }

    /// χ² 分布上尾概率 Q(df/2, x/2)（正则化上不完全伽马函数）
    private static func chiSquareUpperTailP(x: Double, df: Double) -> Double {
        guard x > 0, df > 0 else { return 1.0 }
        let a = 0.5 * df
        let z = 0.5 * x
        if z < a + 1.0 {
            // 级数展开求下不完全伽马 P(a, z)
            var ap = a
            var sum = 1.0 / a
            var del = sum
            for _ in 1...200 {
                ap += 1.0
                del *= z / ap
                sum += del
                if abs(del) < abs(sum) * 1e-13 { break }
            }
            let pLower = sum * exp(-z + a * log(z) - QPCRStatistics.logGamma(a))
            return min(1.0, max(0.0, 1.0 - pLower))
        } else {
            // Lentz 连分式求上不完全伽马 Q(a, z)
            let fpMin = 1e-300
            var b = z + 1.0 - a
            var c = 1.0 / fpMin
            var d = 1.0 / b
            var h = d
            for i in 1...200 {
                let an = -Double(i) * (Double(i) - a)
                b += 2.0
                d = an * d + b
                if abs(d) < fpMin { d = fpMin }
                c = b + an / c
                if abs(c) < fpMin { c = fpMin }
                d = 1.0 / d
                let del = d * c
                h *= del
                if abs(del - 1.0) < 1e-13 { break }
            }
            return min(1.0, max(0.0, exp(-z + a * log(z) - QPCRStatistics.logGamma(a)) * h))
        }
    }

    private static func computePooledAverageRanks(groups: [[Double]]) -> (ranksByGroup: [[Double]], tieSum: Double) {
        var flat: [(val: Double, gIdx: Int, itemIdx: Int)] = []
        for (gIdx, grp) in groups.enumerated() {
            for (iIdx, v) in grp.enumerated() {
                flat.append((v, gIdx, iIdx))
            }
        }
        flat.sort { $0.val < $1.val }
        var ranks = groups.map { Array(repeating: 0.0, count: $0.count) }
        var tieSum = 0.0
        var i = 0
        while i < flat.count {
            var j = i + 1
            while j < flat.count && abs(flat[j].val - flat[i].val) <= 1e-12 {
                j += 1
            }
            let count = j - i
            let avgRank = 0.5 * Double(i + 1 + j)
            if count > 1 {
                let t = Double(count)
                tieSum += t * t * t - t
            }
            for k in i..<j {
                ranks[flat[k].gIdx][flat[k].itemIdx] = avgRank
            }
            i = j
        }
        return (ranks, tieSum)
    }

    // MARK: - 7. 公开示例数据集（BCA / ELISA / IC50 / CCK-8）

    public static func demoBCAData() -> (standards: [(concUgPerMl: Double, od: Double)], samples: [(name: String, replicates: [Double])], blankOD: Double) {
        let stds: [(Double, Double)] = [
            (0.0, 0.082),
            (125.0, 0.205),
            (250.0, 0.332),
            (500.0, 0.578),
            (1000.0, 1.072),
            (1500.0, 1.564),
            (2000.0, 2.048)
        ]
        let samps: [(String, [Double])] = [
            ("WT-Cell-Lysate", [0.764, 0.778]),
            ("TP53-KO-Lysate", [0.642, 0.656]),
            ("Dilute-Fraction-3", [0.220, 0.214])
        ]
        return (stds, samps, 0.082)
    }

    public static func demoELISAData() -> (standards: [(x: Double, y: Double)], samples: [(name: String, replicates: [Double])]) {
        // 标准 IFN-γ ELISA 8点梯度（含 0 pg/mL 下渐近线锚点）
        let stds: [(Double, Double)] = [
            (0.0, 0.068),
            (7.8, 0.145),
            (15.6, 0.228),
            (31.25, 0.395),
            (62.5, 0.692),
            (125.0, 1.158),
            (250.0, 1.684),
            (500.0, 2.042),
            (1000.0, 2.248)
        ]
        let samps: [(String, [Double])] = [
            ("Stimulated-Media-1", [0.892, 0.914]),
            ("Stimulated-Media-2", [1.410, 1.435]),
            ("Mock-Control", [0.165, 0.172])
        ]
        return (stds, samps)
    }

    public static func demoDoseResponseData() -> [(x: Double, y: Double)] {
        // 标准 Hill IC50 = 25 nM, Top = 100%, Bottom = 8%, Hill = 1.25
        [
            (0.1, 99.2),
            (0.3, 98.4),
            (1.0, 96.5),
            (3.0, 91.2),
            (10.0, 76.4),
            (30.0, 48.8),
            (100.0, 22.1),
            (300.0, 12.0),
            (1000.0, 8.9),
            (3000.0, 8.1)
        ]
    }

    public static func demoViabilityData() -> [(name: String, values: [Double])] {
        [
            ("Control", [1.24, 1.28, 1.21, 1.26]),
            ("Drug-1uM", [1.08, 1.05, 1.10, 1.04]),
            ("Drug-10uM", [0.68, 0.72, 0.65, 0.70]),
            ("Drug-50uM", [0.34, 0.31, 0.36, 0.33])
        ]
    }
}
