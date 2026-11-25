import Foundation

// MARK: - 曲线拟合与酶标仪定量工作台引擎 (BCA / ELISA 4PL-5PL / IC50 Hill / CCK-8 ANOVA)

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

public enum ELISAQuantStatus: String, Codable, Sendable {
    case inRange = "标准区间内"
    case belowLLOQ = "低于检测下限 (<LLOQ)"
    case aboveULOQ = "高于检测上限 (>ULOQ)"
    case outOfModel = "超出回归值域"
}

public enum PlateReaderAssayEngine {

    // MARK: - 1. 数据模型

    public struct AssayCurvePoint: Identifiable, Sendable, Equatable {
        public let id: Int
        public let x: Double
        public let y: Double
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
    }

    public struct BCAAnalysisReport: Sendable, Equatable {
        public let model: StandardCurveModel
        public let coeffA: Double // quadratic x^2 (0 for linear)
        public let coeffB: Double // slope
        public let coeffC: Double // intercept
        public let r2: Double
        public let rmse: Double
        public let equationText: String
        public let standardPoints: [AssayCurvePoint]
        public let curvePoints: [AssayCurvePoint]
        public let samples: [BCASampleLoadingItem]
    }

    public struct LogisticFitResult: Sendable, Equatable {
        public let isFivePL: Bool
        public let paramA: Double
        public let paramB: Double
        public let paramC: Double
        public let paramD: Double
        public let paramG: Double
        public let r2: Double
        public let rmse: Double
        public let minStdConc: Double
        public let maxStdConc: Double
        public let standardPoints: [AssayCurvePoint]
        public let curvePoints: [AssayCurvePoint]

        public func evaluate(x: Double) -> Double {
            guard x > 0 else { return paramA }
            let logRatio = log10(x) - log10(max(1e-18, paramC))
            let powerTerm = pow(10.0, max(-30.0, min(30.0, paramB * logRatio)))
            let denom = pow(1.0 + powerTerm, paramG)
            return paramD + (paramA - paramD) / max(1e-15, denom)
        }

        public func invertX(forY y: Double) -> (conc: Double?, status: ELISAQuantStatus) {
            let loY = min(paramA, paramD)
            let hiY = max(paramA, paramD)
            if abs(paramA - paramD) < 1e-12 { return (nil, .outOfModel) }
            if y <= loY {
                return (nil, paramA < paramD ? .belowLLOQ : .aboveULOQ)
            }
            if y >= hiY {
                return (nil, paramA < paramD ? .aboveULOQ : .belowLLOQ)
            }
            let ratio = (paramA - paramD) / (y - paramD)
            guard ratio > 1.0 else { return (nil, .outOfModel) }
            let inner = pow(ratio, 1.0 / max(1e-6, paramG)) - 1.0
            guard inner > 0, abs(paramB) > 1e-9 else { return (nil, .outOfModel) }
            let x = paramC * pow(inner, 1.0 / paramB)
            guard x.isFinite && x > 0 else { return (nil, .outOfModel) }
            if x < minStdConc { return (x, .belowLLOQ) }
            if x > maxStdConc { return (x, .aboveULOQ) }
            return (x, .inRange)
        }
    }

    public struct ELISASampleQuantItem: Identifiable, Sendable, Equatable {
        public let id: String
        public let sampleName: String
        public let meanOD: Double
        public let interpolatedConc: Double?
        public let finalConc: Double?
        public let status: ELISAQuantStatus
    }

    public struct ViabilityGroupResult: Identifiable, Sendable, Equatable {
        public let id: String
        public let groupName: String
        public let n: Int
        public let meanViabilityPercent: Double
        public let sdViabilityPercent: Double
        public let semViabilityPercent: Double
        public let pValue: Double?
        public let pAdjusted: Double?
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
        public let groups: [ViabilityGroupResult]
        public let anova: OneWayANOVAResult?
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

        // A) 优先探测 8×12 / 16×24 矩阵格式：存在含 1,2,3... 列号表头，且紧邻下方 A/B/C... 行首
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

        // B) 回退长表模式：Well, Value/OD/Signal
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

    // MARK: - 3. 模式 A：BCA / Bradford 标准曲线拟合与 WB 上样配液表

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
        let validStd = standards.map { (conc: $0.concUgPerMl, y: $0.od - blankOD) }
        guard validStd.count >= 2 else { return nil }

        let a: Double
        let b: Double
        let c: Double
        let eqText: String

        if model == .quadratic && validStd.count >= 3,
           let quad = solveQuadraticLeastSquares(points: validStd.map { ($0.conc, $0.y) }) {
            a = quad.a; b = quad.b; c = quad.c
            eqText = String(format: "y = %.4e·x² + %.4e·x %+.4f", a, b, c)
        } else {
            guard let reg = QPCRStatistics.linearRegression(validStd.map { ($0.conc, $0.y) }) else { return nil }
            a = 0.0; b = reg.slope; c = reg.intercept
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
        let rmse = sqrt(sse / Double(validStd.count))

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
            let concFitted = invertPolynomial(a: a, b: b, c: c, y: meanCorr, maxHint: maxX)
            let clampedConc = max(0.0, concFitted)
            let stockUgMl = clampedConc * safeDil
            let stockUgUl = stockUgMl / 1000.0

            let idealProteinVol = stockUgUl > 1e-9 ? (targetLoadUg / stockUgUl) : maxAvailSampleVol
            let isDilute = idealProteinVol > maxAvailSampleVol + 1e-6
            let actualProteinVol = min(maxAvailSampleVol, max(0.0, idealProteinVol))
            let actualLysisVol = max(0.0, maxAvailSampleVol - actualProteinVol)
            let maxLoadable = stockUgUl * maxAvailSampleVol

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
                isDiluteWarning: isDilute
            )
        }

        return BCAAnalysisReport(
            model: (a != 0 ? .quadratic : .linear),
            coeffA: a,
            coeffB: b,
            coeffC: c,
            r2: r2,
            rmse: rmse,
            equationText: eqText,
            standardPoints: validStd.enumerated().map { AssayCurvePoint(id: $0.offset, x: $0.element.conc, y: $0.element.y) },
            curvePoints: curve,
            samples: quantSamples
        )
    }

    // MARK: - 4. 模式 B / C：4PL / 5PL / Hill IC50 统一 Levenberg-Marquardt 非线性最小二乘引擎

    public static func fitLogistic4PLOr5PL(
        points rawPoints: [(x: Double, y: Double)],
        fiveParameter: Bool = false
    ) -> LogisticFitResult? {
        let pts = rawPoints.filter { $0.x > 0 && $0.x.isFinite && $0.y.isFinite }.sorted { $0.x < $1.x }
        let minNeeded = fiveParameter ? 5 : 4
        guard pts.count >= minNeeded else { return nil }

        let logXs = pts.map { log10($0.x) }
        let ys = pts.map(\.y)
        let logMin = logXs.min() ?? -2.0
        let logMax = logXs.max() ?? 2.0
        let logMid = 0.5 * (logMin + logMax)
        let yFirst = ys.first ?? 0.0
        let yLast = ys.last ?? 1.0
        let yMin = ys.min() ?? 0.0
        let yMax = ys.max() ?? 1.0
        let aInit = (yFirst <= yLast) ? yMin : yMax
        let dInit = (yFirst <= yLast) ? yMax : yMin

        // 多初值组合搜索最优全局解
        var candidateStarts: [[Double]] = []
        for u0 in [logMid, logMin + 0.35 * (logMax - logMin), logMin + 0.65 * (logMax - logMin)] {
            for b0 in [1.0, 1.8, 0.6] {
                if fiveParameter {
                    candidateStarts.append([aInit, b0, u0, dInit, 1.0])
                } else {
                    candidateStarts.append([aInit, b0, u0, dInit])
                }
            }
        }

        var bestTheta: [Double]? = nil
        var bestSSE = Double.infinity

        for startTheta in candidateStarts {
            let (optTheta, sse) = runLevenbergMarquardt(
                logXs: logXs,
                ys: ys,
                initialTheta: startTheta,
                fiveParameter: fiveParameter
            )
            if sse.isFinite && sse < bestSSE {
                bestSSE = sse
                bestTheta = optTheta
            }
        }

        guard let theta = bestTheta else { return nil }
        let pA = theta[0]
        let pB = theta[1]
        let pC = pow(10.0, theta[2])
        let pD = theta[3]
        let pG = fiveParameter ? min(4.0, max(0.25, theta[4])) : 1.0

        let meanY = ys.reduce(0.0, +) / Double(ys.count)
        let sst = ys.reduce(0.0) { $0 + ($1 - meanY) * ($1 - meanY) }
        let r2 = sst > 1e-15 ? max(0.0, 1.0 - bestSSE / sst) : 1.0
        let rmse = sqrt(bestSSE / Double(ys.count))

        let fit = LogisticFitResult(
            isFivePL: fiveParameter,
            paramA: pA,
            paramB: pB,
            paramC: pC,
            paramD: pD,
            paramG: pG,
            r2: r2,
            rmse: rmse,
            minStdConc: pts.first?.x ?? pC * 0.01,
            maxStdConc: pts.last?.x ?? pC * 100.0,
            standardPoints: pts.enumerated().map { AssayCurvePoint(id: $0.offset, x: $0.element.x, y: $0.element.y) },
            curvePoints: []
        )

        var curve: [AssayCurvePoint] = []
        let plotLo = logMin - 0.15
        let plotHi = logMax + 0.15
        let steps = 60
        for i in 0...steps {
            let l = plotLo + (plotHi - plotLo) * Double(i) / Double(steps)
            let x = pow(10.0, l)
            curve.append(AssayCurvePoint(id: i, x: x, y: fit.evaluate(x: x)))
        }

        return LogisticFitResult(
            isFivePL: fit.isFivePL,
            paramA: fit.paramA,
            paramB: fit.paramB,
            paramC: fit.paramC,
            paramD: fit.paramD,
            paramG: fit.paramG,
            r2: fit.r2,
            rmse: fit.rmse,
            minStdConc: fit.minStdConc,
            maxStdConc: fit.maxStdConc,
            standardPoints: fit.standardPoints,
            curvePoints: curve
        )
    }

    public static func quantifyELISASamples(
        samples: [(name: String, replicates: [Double])],
        fit: LogisticFitResult,
        dilutionFactor: Double = 1.0
    ) -> [ELISASampleQuantItem] {
        let dil = max(0.01, dilutionFactor)
        return samples.enumerated().compactMap { idx, s in
            let vals = s.replicates.filter(\.isFinite)
            guard !vals.isEmpty else { return nil }
            let meanOD = vals.reduce(0.0, +) / Double(vals.count)
            let inv = fit.invertX(forY: meanOD)
            let finalC = inv.conc.map { $0 * dil }
            return ELISASampleQuantItem(
                id: "\(idx)_\(s.name)",
                sampleName: s.name,
                meanOD: meanOD,
                interpolatedConc: inv.conc,
                finalConc: finalC,
                status: inv.status
            )
        }
    }

    // MARK: - 5. 模式 D：CCK-8 / MTT 细胞活力归一化、Welch's t-test、Holm 与 One-Way ANOVA

    public static func analyzeViability(
        groups rawGroups: [(name: String, values: [Double])],
        controlGroupName: String = "Control",
        blankMean: Double = 0.0
    ) -> ViabilityAnalysisReport? {
        let nonEmpty = rawGroups.compactMap { g -> (name: String, corr: [Double])? in
            let valid = g.values.filter(\.isFinite).map { max(0.0, $0 - blankMean) }
            guard !valid.isEmpty else { return nil }
            return (g.name, valid)
        }
        guard !nonEmpty.isEmpty else { return nil }

        let ctrlEntry = nonEmpty.first(where: { $0.name.caseInsensitiveCompare(controlGroupName) == .orderedSame }) ?? nonEmpty[0]
        let ctrlMean = max(1e-9, ctrlEntry.corr.reduce(0.0, +) / Double(ctrlEntry.corr.count))

        let normGroups: [(name: String, viabilities: [Double], isCtrl: Bool)] = nonEmpty.map { entry in
            let isCtrl = (entry.name.caseInsensitiveCompare(ctrlEntry.name) == .orderedSame)
            let pcts = entry.corr.map { $0 * 100.0 / ctrlMean }
            return (entry.name, pcts, isCtrl)
        }

        let ctrlVias = normGroups.first(where: \.isCtrl)?.viabilities ?? []
        var rawPs: [Double?] = []
        for g in normGroups {
            if g.isCtrl {
                rawPs.append(nil)
            } else {
                rawPs.append(QPCRStatistics.welchTTest(g.viabilities, ctrlVias)?.p)
            }
        }
        let adjPs = QPCRStatistics.holmAdjustOptional(rawPs)

        let outGroups: [ViabilityGroupResult] = normGroups.enumerated().map { idx, g in
            let meanV = QPCRStatistics.mean(g.viabilities)
            let sdV = QPCRStatistics.sampleSd(g.viabilities) ?? 0.0
            let semV = QPCRStatistics.sem(g.viabilities) ?? 0.0
            return ViabilityGroupResult(
                id: "\(idx)_\(g.name)",
                groupName: g.name,
                n: g.viabilities.count,
                meanViabilityPercent: meanV,
                sdViabilityPercent: sdV,
                semViabilityPercent: semV,
                pValue: rawPs[idx],
                pAdjusted: adjPs[idx],
                isControl: g.isCtrl
            )
        }

        let anova = computeOneWayANOVA(groups: normGroups.map(\.viabilities))
        return ViabilityAnalysisReport(
            controlGroup: ctrlEntry.name,
            controlMeanRawCorrected: ctrlMean,
            groups: outGroups,
            anova: anova
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
        // F 分布上尾概率 P(F_{df1, df2} >= f) = I_{x}(df2/2, df1/2), x = df2 / (df2 + df1 * F)
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

    // MARK: - 6. 数值求解器（多项式拟合 + Levenberg-Marquardt）

    private static func evalLogistic(logX: Double, theta: [Double], fiveParameter: Bool) -> Double {
        let a = theta[0]
        let b = theta[1]
        let u = theta[2]
        let d = theta[3]
        let g = fiveParameter ? min(4.0, max(0.25, theta[4])) : 1.0
        let expo = max(-30.0, min(30.0, b * (logX - u)))
        let pTerm = pow(10.0, expo)
        let denom = pow(1.0 + pTerm, g)
        return d + (a - d) / max(1e-15, denom)
    }

    private static func sseFor(logXs: [Double], ys: [Double], theta: [Double], fiveParameter: Bool) -> Double {
        var s = 0.0
        for i in 0..<logXs.count {
            let r = ys[i] - evalLogistic(logX: logXs[i], theta: theta, fiveParameter: fiveParameter)
            s += r * r
        }
        return s
    }

    private static func runLevenbergMarquardt(
        logXs: [Double],
        ys: [Double],
        initialTheta: [Double],
        fiveParameter: Bool
    ) -> (theta: [Double], sse: Double) {
        let p = initialTheta.count
        let n = logXs.count
        var theta = initialTheta
        var lambda = 1e-2
        var curSSE = sseFor(logXs: logXs, ys: ys, theta: theta, fiveParameter: fiveParameter)

        for _ in 0..<90 {
            var jtj = Array(repeating: Array(repeating: 0.0, count: p), count: p)
            var jtr = Array(repeating: 0.0, count: p)
            var jacobian = Array(repeating: Array(repeating: 0.0, count: p), count: n)
            var residuals = Array(repeating: 0.0, count: n)

            for i in 0..<n {
                let f0 = evalLogistic(logX: logXs[i], theta: theta, fiveParameter: fiveParameter)
                residuals[i] = ys[i] - f0
            }

            for col in 0..<p {
                let step = 1e-6 * max(1.0, abs(theta[col]))
                var tPlus = theta
                tPlus[col] += step
                if fiveParameter && col == 4 { tPlus[4] = min(4.0, max(0.25, tPlus[4])) }
                for i in 0..<n {
                    let fp = evalLogistic(logX: logXs[i], theta: tPlus, fiveParameter: fiveParameter)
                    let f0 = evalLogistic(logX: logXs[i], theta: theta, fiveParameter: fiveParameter)
                    jacobian[i][col] = (fp - f0) / max(1e-12, tPlus[col] - theta[col])
                }
            }

            for r in 0..<p {
                for c in 0..<p {
                    var sum = 0.0
                    for i in 0..<n { sum += jacobian[i][r] * jacobian[i][c] }
                    jtj[r][c] = sum
                }
                var sumR = 0.0
                for i in 0..<n { sumR += jacobian[i][r] * residuals[i] }
                jtr[r] = sumR
            }

            for r in 0..<p {
                jtj[r][r] += lambda * max(1e-6, jtj[r][r]) + 1e-9
            }

            guard let delta = solveLinearSystem(matrix: jtj, rhs: jtr) else {
                lambda *= 10.0
                continue
            }

            var cand = theta
            for j in 0..<p { cand[j] += delta[j] }
            // 物理参数夹紧保护
            cand[1] = max(-8.0, min(8.0, cand[1]))
            cand[2] = max(-15.0, min(15.0, cand[2]))
            if fiveParameter {
                cand[4] = min(4.0, max(0.25, cand[4]))
            }

            let candSSE = sseFor(logXs: logXs, ys: ys, theta: cand, fiveParameter: fiveParameter)
            if candSSE < curSSE {
                let relGain = abs(curSSE - candSSE) / max(1e-12, curSSE)
                theta = cand
                curSSE = candSSE
                lambda = max(1e-7, lambda * 0.3)
                if relGain < 1e-10 { break }
            } else {
                lambda = min(1e8, lambda * 5.0)
                if lambda >= 1e7 { break }
            }
        }
        return (theta, curSSE)
    }

    private static func solveQuadraticLeastSquares(points: [(x: Double, y: Double)]) -> (a: Double, b: Double, c: Double)? {
        guard points.count >= 3 else { return nil }
        var s0 = Double(points.count), s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var sy = 0.0, sxy = 0.0, sx2y = 0.0
        for p in points {
            let x = p.x
            let x2 = x * x
            s1 += x; s2 += x2; s3 += x2 * x; s4 += x2 * x2
            sy += p.y; sxy += x * p.y; sx2y += x2 * p.y
        }
        let mat = [
            [s4, s3, s2],
            [s3, s2, s1],
            [s2, s1, s0]
        ]
        guard let sol = solveLinearSystem(matrix: mat, rhs: [sx2y, sxy, sy]) else { return nil }
        return (sol[0], sol[1], sol[2])
    }

    private static func invertPolynomial(a: Double, b: Double, c: Double, y: Double, maxHint: Double) -> Double {
        if abs(a) < 1e-15 {
            guard abs(b) > 1e-12 else { return 0.0 }
            return (y - c) / b
        }
        // 解 a x^2 + b x + (c - y) = 0，选取正且最靠近标准区间 [0, 3*maxHint] 的根
        let disc = b * b - 4.0 * a * (c - y)
        guard disc >= 0 else {
            return abs(b) > 1e-12 ? (y - c) / b : 0.0
        }
        let sqrtD = sqrt(disc)
        let r1 = (-b + sqrtD) / (2.0 * a)
        let r2 = (-b - sqrtD) / (2.0 * a)
        let cap = max(100.0, maxHint * 3.0)
        let cands = [r1, r2].filter { $0 >= 0 && $0 <= cap }
        return cands.first ?? max(r1, r2)
    }

    private static func solveLinearSystem(matrix A: [[Double]], rhs b: [Double]) -> [Double]? {
        let n = b.count
        var mat = A
        var vec = b
        for i in 0..<n {
            var pivotRow = i
            var maxVal = abs(mat[i][i])
            for r in (i + 1)..<n {
                if abs(mat[r][i]) > maxVal {
                    maxVal = abs(mat[r][i])
                    pivotRow = r
                }
            }
            guard maxVal > 1e-14 else { return nil }
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
        // 标准 IFN-γ ELISA 7点梯度 (pg/mL vs OD450)
        let stds: [(Double, Double)] = [
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
