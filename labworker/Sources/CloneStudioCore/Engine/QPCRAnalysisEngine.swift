import Foundation
import Combine

// MARK: - 1. qPCR 数据模型与配置 (QPCR Models & Settings)

public enum QPCRAnalysisMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case ddct = "ddct"
    case standardCurve = "standard"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .ddct:          return "ΔΔCt 相对定量"
        case .standardCurve: return "标准曲线绝对定量"
        }
    }
}

public enum QPCRWellType: String, CaseIterable, Identifiable, Codable, Sendable {
    case sample = "sample"
    case ntc = "ntc"
    case noRT = "noRT"
    case standard = "standard"
    
    public var id: String { rawValue }
    
    public var badgeTitle: String {
        switch self {
        case .sample:   return "样品"
        case .ntc:      return "NTC"
        case .noRT:     return "no-RT"
        case .standard: return "标准品"
        }
    }
    
    public static func infer(sample: String, group: String = "", taskRaw: String = "", quantity: Double? = nil) -> QPCRWellType {
        if quantity != nil {
            return .standard
        }
        let combined = "\(taskRaw) \(sample) \(group)".lowercased()
        let tokens = combined.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if tokens.contains("ntc") || combined.contains("no template") || combined.contains("non-template") || combined.contains("空白") || combined.contains("水对照") {
            return .ntc
        }
        if tokens.contains("nort") || tokens.contains("nrt") || combined.contains("no-rt") || combined.contains("no rt") || combined.contains("-rt") || combined.contains("rt-") || combined.contains("无逆转录") {
            return .noRT
        }
        if tokens.contains("standard") || tokens.contains("std") || combined.contains("标准品") {
            return .standard
        }
        return .sample
    }
}

public enum QPCRQCFlag: String, CaseIterable, Identifiable, Codable, Sendable {
    case ntcAmplified = "NTC污染起峰"
    case noRTAmplified = "no-RT扩增告警"
    case meltOutlier = "Tm熔解偏离"
    case undetermined = "未检出(Undetermined)"
    case missingCt = "缺失Ct"
    case highCt = "高Ct(>阈值)"
    case replicateSd = "复孔SD偏大"
    case outlier = "离群值"
    case duplicateWell = "孔位重复"
    case missingRef = "内参缺失"
    case invalid = "信息不全"
    
    public var id: String { rawValue }
}

public struct QPCRWellRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var row: Int
    public var well: String
    public var sample: String
    public var target: String
    public var group: String
    public var wellType: QPCRWellType
    public var replicate: Int?
    public var ct: Double?
    public var tm: Double?
    public var efficiency: Double?
    /// 已知标准品浓度/拷贝数（非 nil 时作为标准曲线校准孔）
    public var quantity: Double?
    public var include: Bool
    
    public init(
        id: String = UUID().uuidString,
        row: Int = 0,
        well: String,
        sample: String,
        target: String,
        group: String = "",
        wellType: QPCRWellType? = nil,
        replicate: Int? = nil,
        ct: Double? = nil,
        tm: Double? = nil,
        efficiency: Double? = nil,
        quantity: Double? = nil,
        include: Bool = true
    ) {
        self.id = id
        self.row = row
        self.well = well
        self.sample = sample
        self.target = target
        self.group = group
        self.wellType = wellType ?? QPCRWellType.infer(sample: sample, group: group, quantity: quantity)
        self.replicate = replicate
        self.ct = ct
        self.tm = tm
        self.efficiency = efficiency
        self.quantity = quantity
        self.include = include
    }
}

public enum QPCRMultipleComparisonMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "none"
    case holm = "holm"
    case bhFDR = "bh_fdr"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .none:  return "不校正 (Raw p)"
        case .holm:  return "Holm–Bonferroni"
        case .bhFDR: return "Benjamini–Hochberg FDR"
        }
    }
}

public enum QPCRErrorBarMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case sd = "sd"
    case sem = "sem"
    case ci95 = "ci95"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .sd:   return "SD"
        case .sem:  return "SEM"
        case .ci95: return "95% CI"
        }
    }
}

public struct QPCRSettings: Hashable, Codable, Sendable {
    public var highCtThreshold: Double
    public var ntcCtThreshold: Double
    public var noRTDeltaCtThreshold: Double
    public var meltTolerance: Double
    public var sdLimit: Double
    public var outlierLimit: Double
    public var excludeOutliers: Bool
    public var efficiencyCorrection: Bool
    public var defaultEfficiencyPct: Double
    public var quantityIsLog10: Bool
    public var referenceTargets: [String]
    public var controlGroup: String
    public var controlSample: String
    public var multipleComparison: QPCRMultipleComparisonMethod
    
    public init(
        highCtThreshold: Double = 35.0,
        ntcCtThreshold: Double = 35.0,
        noRTDeltaCtThreshold: Double = 5.0,
        meltTolerance: Double = 1.0,
        sdLimit: Double = 0.5,
        outlierLimit: Double = 0.5,
        excludeOutliers: Bool = false,
        efficiencyCorrection: Bool = false,
        defaultEfficiencyPct: Double = 100.0,
        quantityIsLog10: Bool = false,
        referenceTargets: [String] = ["GAPDH"],
        controlGroup: String = "ControlGroup",
        controlSample: String = "WT-Ctrl",
        multipleComparison: QPCRMultipleComparisonMethod = .holm
    ) {
        self.highCtThreshold = highCtThreshold
        self.ntcCtThreshold = ntcCtThreshold
        self.noRTDeltaCtThreshold = noRTDeltaCtThreshold
        self.meltTolerance = meltTolerance
        self.sdLimit = sdLimit
        self.outlierLimit = outlierLimit
        self.excludeOutliers = excludeOutliers
        self.efficiencyCorrection = efficiencyCorrection
        self.defaultEfficiencyPct = defaultEfficiencyPct
        self.quantityIsLog10 = quantityIsLog10
        self.referenceTargets = referenceTargets
        self.controlGroup = controlGroup
        self.controlSample = controlSample
        self.multipleComparison = multipleComparison
    }
}

public struct QPCRWellQCResult: Sendable {
    public let flags: [QPCRQCFlag]
    public let replicateN: Int
    public let replicateMean: Double?
    public let replicateSd: Double?
}

public struct QPCRSampleResult: Identifiable, Sendable {
    public var id: String { "\(sampleKey)|\(targetKey)" }
    public let sample: String
    public let sampleKey: String
    public let target: String
    public let targetKey: String
    public let group: String
    public let category: String
    public let n: Int
    public let meanCt: Double
    public let sdCt: Double?
    public let refCt: Double
    public let dCt: Double
    public let ddCt: Double
    public let efficiency: Double
    public let fold: Double
    public let foldSd: Double?
    public let foldSem: Double?
    public let foldValues: [Double]
    public let isControl: Bool
    /// 由标准曲线斜率标准误一阶泰勒传播至扩增效率后的 Fold 相对定量标准误
    public let efficiencyPropagatedFoldSE: Double?

    public init(
        sample: String,
        sampleKey: String,
        target: String,
        targetKey: String,
        group: String,
        category: String,
        n: Int,
        meanCt: Double,
        sdCt: Double?,
        refCt: Double,
        dCt: Double,
        ddCt: Double,
        efficiency: Double,
        fold: Double,
        foldSd: Double?,
        foldSem: Double?,
        foldValues: [Double],
        isControl: Bool,
        efficiencyPropagatedFoldSE: Double? = nil
    ) {
        self.sample = sample
        self.sampleKey = sampleKey
        self.target = target
        self.targetKey = targetKey
        self.group = group
        self.category = category
        self.n = n
        self.meanCt = meanCt
        self.sdCt = sdCt
        self.refCt = refCt
        self.dCt = dCt
        self.ddCt = ddCt
        self.efficiency = efficiency
        self.fold = fold
        self.foldSd = foldSd
        self.foldSem = foldSem
        self.foldValues = foldValues
        self.isControl = isControl
        self.efficiencyPropagatedFoldSE = efficiencyPropagatedFoldSE
    }
}

public enum QPCRStatNote: String, Codable, Sendable {
    case ok = "ok"
    case insufficientBiologicalReplicates = "insufficientBiologicalReplicates"
}

public struct QPCRGroupSummary: Identifiable, Sendable {
    public var id: String { "\(categoryKey)|\(targetKey)" }
    public let category: String
    public let categoryKey: String
    public let target: String
    public let targetKey: String
    public let nBiological: Int
    public let nTechnicalWells: Int
    public var nSamples: Int { nBiological }
    public let meanFold: Double
    public let sdFold: Double?
    public let semFold: Double?
    public let meanDCt: Double
    public let sdDCt: Double?
    public let pValue: Double?
    public let pAdjusted: Double?
    public let multipleComparison: QPCRMultipleComparisonMethod
    public let ddCtCI95Low: Double?
    public let ddCtCI95High: Double?
    public let foldCI95Low: Double?
    public let foldCI95High: Double?
    public let statNote: QPCRStatNote
    public let foldValues: [Double]
    public let isControl: Bool
    
    public var effectivePValueForSignificance: Double? {
        switch multipleComparison {
        case .holm, .bhFDR: return pAdjusted ?? pValue
        case .none:         return pValue
        }
    }
    
    public var significanceLabel: String {
        if isControl { return "Ref" }
        guard let p = effectivePValueForSignificance, statNote == .ok else { return L10n.t("n<2，未检验") }
        if p < 0.001 { return "***" }
        if p < 0.01  { return "**" }
        if p < 0.05  { return "*" }
        return "ns"
    }
}

public struct QPCRHeatmapCell: Identifiable, Sendable {
    public var id: String { "\(sample)|\(target)" }
    public let sample: String
    public let group: String
    public let target: String
    public let dCt: Double?
    public let ddCt: Double?
    public let fold: Double?
}

public struct QPCRDdctAnalysisOut: Sendable {
    public let references: [String]
    public let targets: [String]
    public let samples: [String]
    public let groups: [String]
    public let controlLabel: String
    public let contaminatedTargets: [String]
    public let sampleResults: [QPCRSampleResult]
    public let groupResults: [QPCRGroupSummary]
    public let heatmapCells: [QPCRHeatmapCell]
}

public struct QPCRStandardCurveFit: Identifiable, Sendable {
    public var id: String { targetKey }
    public let targetKey: String
    public let target: String
    public let slope: Double?
    public let slopeSE: Double?
    public let intercept: Double?
    public let r2: Double?
    public let efficiencyPct: Double?
    /// 扩增效率 E = 10^(-1/slope) 的一阶泰勒传播标准误（绝对效率单位，如 0.03 表示 ±3%）
    public let efficiencySE: Double?
    public let n: Int
    public let xMin: Double?
    public let xMax: Double?
    public let ctMin: Double?
    public let ctMax: Double?
    public let valid: Bool
    public let points: [(x: Double, y: Double)]

    public init(
        targetKey: String,
        target: String,
        slope: Double?,
        intercept: Double?,
        r2: Double?,
        efficiencyPct: Double?,
        n: Int,
        xMin: Double?,
        xMax: Double?,
        valid: Bool,
        points: [(x: Double, y: Double)],
        slopeSE: Double? = nil,
        efficiencySE: Double? = nil,
        ctMin: Double? = nil,
        ctMax: Double? = nil
    ) {
        self.targetKey = targetKey
        self.target = target
        self.slope = slope
        self.slopeSE = slopeSE
        self.intercept = intercept
        self.r2 = r2
        self.efficiencyPct = efficiencyPct
        self.efficiencySE = efficiencySE
        self.n = n
        self.xMin = xMin
        self.xMax = xMax
        self.ctMin = ctMin
        self.ctMax = ctMax
        self.valid = valid
        self.points = points
    }
}

public struct QPCRStandardSampleResult: Identifiable, Sendable {
    public var id: String { "\(sampleKey)|\(targetKey)" }
    public let sample: String
    public let sampleKey: String
    public let target: String
    public let targetKey: String
    public let group: String
    public let category: String
    public let n: Int
    public let meanCt: Double
    public let log10Quantity: Double
    public let quantity: Double
    public let sdLog: Double?
    public let semLog: Double?
    public let isExtrapolated: Bool
    public let extrapolationWarning: String?

    public init(
        sample: String,
        sampleKey: String,
        target: String,
        targetKey: String,
        group: String,
        category: String,
        n: Int,
        meanCt: Double,
        log10Quantity: Double,
        quantity: Double,
        sdLog: Double?,
        semLog: Double?,
        isExtrapolated: Bool = false,
        extrapolationWarning: String? = nil
    ) {
        self.sample = sample
        self.sampleKey = sampleKey
        self.target = target
        self.targetKey = targetKey
        self.group = group
        self.category = category
        self.n = n
        self.meanCt = meanCt
        self.log10Quantity = log10Quantity
        self.quantity = quantity
        self.sdLog = sdLog
        self.semLog = semLog
        self.isExtrapolated = isExtrapolated
        self.extrapolationWarning = extrapolationWarning
    }
}

public struct QPCRStandardAnalysisOut: Sendable {
    public let fits: [QPCRStandardCurveFit]
    public let samples: [QPCRStandardSampleResult]
}

/// geNorm (Vandesompele 2002) & NormFinder (Andersen 2004) 内参基因稳定性评估条目
public struct QPCRReferenceGeneMetric: Identifiable, Sendable, Equatable {
    public var id: String { targetKey }
    public let targetKey: String
    public let target: String
    /// geNorm 平均成对变异度 M 值（越小越稳定；常规阈值 M <= 1.0，同质组织推荐 <= 0.5）
    public let geNormM: Double
    /// NormFinder 综合稳定性值 rho = mean_g(|d_gj| + sqrt(v_gj))（越小越稳定）
    public let normFinderRho: Double?
    /// 各生物学分组间均值 Ct 最大极差（用于识别处理诱导变化的不稳定内参）
    public let maxInterGroupCtShift: Double
}

public struct QPCRPairwiseVariation: Identifiable, Sendable, Equatable {
    public var id: String { label }
    public let label: String          // 如 "V2/3"
    public let nGenes: Int
    public let value: Double          // V_{n/n+1}，Vandesompele 推荐阈值 < 0.15
}

public struct QPCRReferenceStabilityReport: Sendable, Equatable {
    public let genes: [QPCRReferenceGeneMetric]
    /// geNorm 逐步剔除顺序（从最不稳定到最稳定）
    public let stepwiseExclusionOrder: [String]
    public let pairwiseVariations: [QPCRPairwiseVariation]
    public let bestReferencePair: [String]
    public let isStable: Bool
    public let warnings: [String]
}

// MARK: - 2. 生物统计与回归数学工具箱 (Lanczos LogGamma + 不完全 Beta 函数 + Welch's t-test + OLS 线性回归)

public enum QPCRStatistics {
    private static let lanczosCoefficients: [Double] = [
        0.99999999999980993,
        676.5203681218851,
        -1259.1392167224028,
        771.32342877765313,
        -176.61502916214059,
        12.507343278686905,
        -0.13857109526572012,
        9.9843695780195716e-6,
        1.5056327351493116e-7
    ]
    
    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        return values.reduce(0, +) / Double(values.count)
    }
    
    public static func median(_ values: [Double]) -> Double? {
        let valid = values.filter(\.isFinite).sorted()
        guard !valid.isEmpty else { return nil }
        let mid = valid.count / 2
        return (valid.count % 2 == 0) ? 0.5 * (valid[mid - 1] + valid[mid]) : valid[mid]
    }
    
    /// Grubbs (1969, Technometrics 11:1–21) 双侧单离群值检验，返回最偏离均值的离群索引（若超过显著性水平 alpha 临界值）
    public static func grubbsTestOutlierIndex(_ values: [Double], alpha: Double = 0.05) -> Int? {
        let n = values.count
        guard n >= 3, alpha > 0, alpha < 1,
              values.allSatisfy(\.isFinite),
              let sd = sampleSd(values), sd > 0 else {
            return nil
        }
        let m = mean(values)
        var maxIdx = 0
        var maxDev = -1.0
        for (idx, v) in values.enumerated() {
            let dev = abs(v - m)
            if dev > maxDev {
                maxDev = dev
                maxIdx = idx
            }
        }
        let gStat = maxDev / sd
        // studentTQuantileTwoSided(alpha: p, df: df) 返回 P(|T| >= t) = p，取 p = alpha / n 即对应 t_{alpha/(2n), n-2}
        guard let tCrit = studentTQuantileTwoSided(alpha: alpha / Double(n), df: Double(n - 2)) else {
            return nil
        }
        let tSq = tCrit * tCrit
        let nD = Double(n)
        let gCrit = ((nD - 1.0) / sqrt(nD)) * sqrt(tSq / ((nD - 2.0) + tSq))
        return gStat > gCrit ? maxIdx : nil
    }
    
    /// 统一归一化扩增效率写法为小数分数 (如 95.0% -> 0.95, 1.95倍增因子 -> 0.95, 0.95 -> 0.95)
    public static func normalizeEfficiencyFraction(_ raw: Double) -> Double? {
        guard raw.isFinite && raw > 0 else { return nil }
        let eff: Double
        if raw > 2.5 {
            eff = raw / 100.0
        } else if raw > 1.5 {
            eff = raw - 1.0
        } else {
            eff = raw
        }
        return max(0.10, min(1.50, eff))
    }
    
    public static func sampleSd(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let m = mean(values)
        let sumSq = values.reduce(0.0) { acc, v in
            let d = v - m
            return acc + d * d
        }
        return sqrt(sumSq / Double(values.count - 1))
    }
    
    public static func sem(_ values: [Double]) -> Double? {
        guard let sd = sampleSd(values) else { return nil }
        return sd / sqrt(Double(values.count))
    }
    
    public static func geometricMean(_ values: [Double]) -> Double? {
        let usable = values.filter { $0.isFinite && $0 > 0 }
        guard !usable.isEmpty else { return nil }
        let logSum = usable.reduce(0.0) { $0 + log($1) }
        return exp(logSum / Double(usable.count))
    }
    
    public static func logGamma(_ z: Double) -> Double {
        if z < 0.5 {
            return log(Double.pi / sin(Double.pi * z)) - logGamma(1.0 - z)
        }
        var x = lanczosCoefficients[0]
        let t = z - 1.0
        for i in 1..<lanczosCoefficients.count {
            x += lanczosCoefficients[i] / (t + Double(i))
        }
        let w = t + 7.5
        return 0.5 * log(2.0 * Double.pi) + (t + 0.5) * log(w) - w + log(x)
    }
    
    private static func betaContinuedFraction(a: Double, b: Double, x: Double) -> Double {
        let maxIterations = 300
        let epsilon = 3e-14
        let tiny = 1e-300
        let qab = a + b
        let qap = a + 1.0
        let qam = a - 1.0
        var c = 1.0
        var d = 1.0 - (qab * x) / qap
        if abs(d) < tiny { d = tiny }
        d = 1.0 / d
        var h = d
        
        for m in 1...maxIterations {
            let mD = Double(m)
            let m2 = 2.0 * mD
            var aa = (mD * (b - mD) * x) / ((qam + m2) * (a + m2))
            d = 1.0 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1.0 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1.0 / d
            h *= d * c
            
            aa = (-(a + mD) * (qab + mD) * x) / ((a + m2) * (qap + m2))
            d = 1.0 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1.0 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1.0 / d
            let del = d * c
            h *= del
            if abs(del - 1.0) < epsilon { break }
        }
        return h
    }
    
    public static func incompleteBeta(a: Double, b: Double, x: Double) -> Double {
        if x <= 0.0 { return 0.0 }
        if x >= 1.0 { return 1.0 }
        let logTerm = logGamma(a + b) - logGamma(a) - logGamma(b) + a * log(x) + b * log(1.0 - x)
        let term = exp(logTerm)
        if x < (a + 1.0) / (a + b + 2.0) {
            return (term * betaContinuedFraction(a: a, b: b, x: x)) / a
        }
        return 1.0 - (term * betaContinuedFraction(a: b, b: a, x: 1.0 - x)) / b
    }
    
    public static func studentTTwoSidedP(t: Double, df: Double) -> Double? {
        guard df.isFinite && df > 0 else { return nil }
        if !t.isFinite { return 0.0 }
        if t == 0.0 { return 1.0 }
        let x = df / (df + t * t)
        let p = incompleteBeta(a: df / 2.0, b: 0.5, x: x)
        return min(1.0, max(0.0, p))
    }
    
    /// 双样本异方差 Welch's t-test
    public static func welchTTest(_ a: [Double], _ b: [Double]) -> (t: Double, df: Double, p: Double)? {
        guard a.count >= 2, b.count >= 2,
              let sdA = sampleSd(a), let sdB = sampleSd(b) else {
            return nil
        }
        let meanA = mean(a)
        let meanB = mean(b)
        let varA = sdA * sdA
        let varB = sdB * sdB
        let termA = varA / Double(a.count)
        let termB = varB / Double(b.count)
        let se = sqrt(termA + termB)
        let diff = meanA - meanB
        
        if se == 0.0 {
            if diff == 0.0 { return (0.0, Double(a.count + b.count - 2), 1.0) }
            return (diff > 0 ? .infinity : -.infinity, Double(a.count + b.count - 2), 0.0)
        }
        let t = diff / se
        let num = (termA + termB) * (termA + termB)
        let den = (termA * termA) / Double(a.count - 1) + (termB * termB) / Double(b.count - 1)
        let df = den == 0.0 ? Double(a.count + b.count - 2) : (num / den)
        guard let p = studentTTwoSidedP(t: t, df: df) else { return nil }
        return (t, df, p)
    }
    
    /// Holm–Bonferroni 逐步下降多重比较校正（与 R p.adjust(method="holm") 完全一致）
    public static func holmAdjust(_ pValues: [Double]) -> [Double] {
        let m = pValues.count
        guard m > 0 else { return [] }
        let indexed = pValues.enumerated().sorted { a, b in
            if a.element != b.element { return a.element < b.element }
            return a.offset < b.offset
        }
        var adjustedSorted = Array(repeating: 0.0, count: m)
        var runningMax = 0.0
        for (rank, item) in indexed.enumerated() {
            let factor = Double(m - rank)
            let rawAdj = min(1.0, max(0.0, item.element * factor))
            runningMax = max(runningMax, rawAdj)
            adjustedSorted[rank] = runningMax
        }
        var result = Array(repeating: 0.0, count: m)
        for (rank, item) in indexed.enumerated() {
            result[item.offset] = adjustedSorted[rank]
        }
        return result
    }
    
    /// 支持可选值的 Holm–Bonferroni 校正（仅对非 nil 的 p 值做族内校正）
    public static func holmAdjustOptional(_ pValues: [Double?]) -> [Double?] {
        var validIndices: [Int] = []
        var validPs: [Double] = []
        for (i, p) in pValues.enumerated() {
            if let p = p, p.isFinite {
                validIndices.append(i)
                validPs.append(p)
            }
        }
        guard !validPs.isEmpty else { return Array(repeating: nil, count: pValues.count) }
        let adj = holmAdjust(validPs)
        var out: [Double?] = Array(repeating: nil, count: pValues.count)
        for (k, origIdx) in validIndices.enumerated() {
            out[origIdx] = adj[k]
        }
        return out
    }

    /// Benjamini–Hochberg 逐步上升 FDR 多重比较校正（与 R p.adjust(method="BH") 完全一致，用于多基因筛查）
    public static func bhAdjust(_ pValues: [Double]) -> [Double] {
        let m = pValues.count
        guard m > 0 else { return [] }
        let indexed = pValues.enumerated().sorted { a, b in
            if a.element != b.element { return a.element < b.element }
            return a.offset < b.offset
        }
        var adjustedSorted = Array(repeating: 1.0, count: m)
        var runningMin = 1.0
        for rank in stride(from: m - 1, through: 0, by: -1) {
            let p = indexed[rank].element
            let rawQ = min(1.0, max(0.0, p * Double(m) / Double(rank + 1)))
            runningMin = min(runningMin, rawQ)
            adjustedSorted[rank] = runningMin
        }
        var result = Array(repeating: 1.0, count: m)
        for (rank, item) in indexed.enumerated() {
            result[item.offset] = adjustedSorted[rank]
        }
        return result
    }

    /// 支持可选值的 Benjamini–Hochberg FDR 校正
    public static func bhAdjustOptional(_ pValues: [Double?]) -> [Double?] {
        var validIndices: [Int] = []
        var validPs: [Double] = []
        for (i, p) in pValues.enumerated() {
            if let p = p, p.isFinite {
                validIndices.append(i)
                validPs.append(p)
            }
        }
        guard !validPs.isEmpty else { return Array(repeating: nil, count: pValues.count) }
        let adj = bhAdjust(validPs)
        var out: [Double?] = Array(repeating: nil, count: pValues.count)
        for (k, origIdx) in validIndices.enumerated() {
            out[origIdx] = adj[k]
        }
        return out
    }
    
    /// 利用 incompleteBeta 二分求逆计算双侧 Student's t 临界分位数 t_{alpha/2, df}
    public static func studentTQuantileTwoSided(alpha: Double = 0.05, df: Double) -> Double? {
        guard df.isFinite && df > 0 && alpha > 0 && alpha < 1 else { return nil }
        var lo = 0.0
        var hi = 4.0
        while let pHi = studentTTwoSidedP(t: hi, df: df), pHi > alpha, hi < 1e9 {
            lo = hi
            hi *= 2.0
        }
        for _ in 0..<80 {
            let mid = 0.5 * (lo + hi)
            guard let pMid = studentTTwoSidedP(t: mid, df: df) else { break }
            if pMid > alpha {
                lo = mid
            } else {
                hi = mid
            }
        }
        return 0.5 * (lo + hi)
    }
    
    /// 计算两组生物学样品 ΔCt 均值差 (ΔΔCt = mean(a) - mean(b)) 的 Welch 95% 置信区间及对应 Fold Change (base^-ΔΔCt) 95% 置信区间
    public static func welchCI95(
        _ a: [Double],
        _ b: [Double],
        alpha: Double = 0.05,
        base: Double = 2.0
    ) -> (ddCtDiff: Double, ddCtLow: Double, ddCtHigh: Double, foldLow: Double, foldHigh: Double, df: Double)? {
        guard a.count >= 2, b.count >= 2,
              let sdA = sampleSd(a), let sdB = sampleSd(b) else {
            return nil
        }
        let meanA = mean(a)
        let meanB = mean(b)
        let diff = meanA - meanB
        let varA = sdA * sdA
        let varB = sdB * sdB
        let termA = varA / Double(a.count)
        let termB = varB / Double(b.count)
        let se = sqrt(termA + termB)
        let num = (termA + termB) * (termA + termB)
        let den = (termA * termA) / Double(a.count - 1) + (termB * termB) / Double(b.count - 1)
        let df = den == 0.0 ? Double(a.count + b.count - 2) : (num / den)
        guard df.isFinite && df > 0 else { return nil }
        if se == 0.0 {
            let f = pow(base, -diff)
            return (diff, diff, diff, f, f, df)
        }
        guard let tCrit = studentTQuantileTwoSided(alpha: alpha, df: df) else { return nil }
        let margin = tCrit * se
        let ddCtLow = diff - margin
        let ddCtHigh = diff + margin
        let fold1 = pow(base, -ddCtHigh)
        let fold2 = pow(base, -ddCtLow)
        return (diff, ddCtLow, ddCtHigh, min(fold1, fold2), max(fold1, fold2), df)
    }
    
    /// 普通最小二乘法线性回归 y = slope * x + intercept
    public static func linearRegression(_ points: [(x: Double, y: Double)]) -> (slope: Double, intercept: Double, r2: Double, xMin: Double, xMax: Double)? {
        let n = points.count
        guard n >= 2 else { return nil }
        let nD = Double(n)
        var sumX = 0.0
        var sumY = 0.0
        var sumXX = 0.0
        var sumXY = 0.0
        for p in points {
            sumX += p.x
            sumY += p.y
            sumXX += p.x * p.x
            sumXY += p.x * p.y
        }
        let denom = nD * sumXX - sumX * sumX
        guard abs(denom) > 1e-14 else { return nil }
        let slope = (nD * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / nD
        let meanY = sumY / nD
        var ssTot = 0.0
        var ssRes = 0.0
        for p in points {
            let pred = slope * p.x + intercept
            ssTot += (p.y - meanY) * (p.y - meanY)
            ssRes += (p.y - pred) * (p.y - pred)
        }
        let r2 = ssTot == 0.0 ? 0.0 : max(0.0, min(1.0, 1.0 - ssRes / ssTot))
        let xs = points.map(\.x)
        return (slope, intercept, r2, xs.min() ?? 0.0, xs.max() ?? 0.0)
    }

    /// 普通最小二乘线性回归并输出斜率标准误 SE(slope)（用于标准曲线效率误差传播）
    public static func linearRegressionWithSE(_ points: [(x: Double, y: Double)]) -> (slope: Double, intercept: Double, r2: Double, xMin: Double, xMax: Double, slopeSE: Double?)? {
        guard let base = linearRegression(points) else { return nil }
        let n = points.count
        guard n > 2 else {
            return (base.slope, base.intercept, base.r2, base.xMin, base.xMax, nil)
        }
        let meanX = points.reduce(0.0) { $0 + $1.x } / Double(n)
        var sxx = 0.0
        var ssRes = 0.0
        for p in points {
            sxx += (p.x - meanX) * (p.x - meanX)
            let resid = p.y - (base.slope * p.x + base.intercept)
            ssRes += resid * resid
        }
        let se: Double? = sxx > 1e-14 ? sqrt((ssRes / Double(n - 2)) / sxx) : nil
        return (base.slope, base.intercept, base.r2, base.xMin, base.xMax, se)
    }
    
    /// 由标准曲线斜率计算扩增效率 E = 10^(-1/slope) - 1
    public static func efficiencyFromSlope(_ slope: Double) -> Double {
        guard slope.isFinite && slope != 0.0 else { return .nan }
        return pow(10.0, -1.0 / slope) - 1.0
    }

    /// 一阶泰勒误差传播计算扩增因子 E_factor = 10^(-1/slope) 的标准误：SE(E) = E_factor * (ln(10) / slope^2) * SE(slope)
    public static func efficiencySEFromSlope(slope: Double, slopeSE: Double) -> Double? {
        guard slope.isFinite, slope < 0, slopeSE.isFinite, slopeSE >= 0 else { return nil }
        let eFactor = pow(10.0, -1.0 / slope)
        return eFactor * (log(10.0) / (slope * slope)) * slopeSE
    }
}

// MARK: - 3. qPCR 核心定量分析引擎 (QPCRAnalysisEngine)

public enum QPCRAnalysisEngine {
    public static func normKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }
    
    /// 计算每个反应孔的质量控制标记（NTC污染、no-RT扩增、Tm熔解偏离、Undetermined、高Ct、复孔SD超标、离群值、重复孔位、缺失内参）(P08)
    public static func computeQC(
        wells: [QPCRWellRecord],
        settings: QPCRSettings
    ) -> [String: QPCRWellQCResult] {
        let refKeys = Set(settings.referenceTargets.map(normKey).filter { !$0.isEmpty })
        var repGroups: [String: [QPCRWellRecord]] = [:]
        var wellCounts: [String: Int] = [:]
        var targetSampleCts: [String: [Double]] = [:]
        var targetSampleTms: [String: [Double]] = [:]
        
        for w in wells {
            let sKey = normKey(w.sample)
            let tKey = normKey(w.target)
            if !sKey.isEmpty && !tKey.isEmpty {
                let gKey = "\(sKey)|\(tKey)"
                repGroups[gKey, default: []].append(w)
            }
            let wKey = normKey(w.well)
            if !wKey.isEmpty {
                wellCounts[wKey, default: 0] += 1
            }
            if w.include && w.wellType == .sample && !tKey.isEmpty {
                if let ct = w.ct {
                    targetSampleCts[tKey, default: []].append(ct)
                }
                if let tm = w.tm {
                    targetSampleTms[tKey, default: []].append(tm)
                }
            }
        }
        
        // 计算各 target 的样品孔 Tm 中位数（用于检测非特异扩增或引物二聚体导致的熔解峰偏离）
        var targetMedianTm: [String: Double] = [:]
        for (tKey, tms) in targetSampleTms where !tms.isEmpty {
            let sorted = tms.sorted()
            let mid = sorted.count / 2
            let med = (sorted.count % 2 == 0) ? 0.5 * (sorted[mid - 1] + sorted[mid]) : sorted[mid]
            targetMedianTm[tKey] = med
        }
        
        var repStats: [String: (n: Int, mean: Double?, sd: Double?)] = [:]
        var outlierWellIDs = Set<String>()
        
        for (gKey, list) in repGroups {
            let measured = list.compactMap { w -> (id: String, ct: Double)? in
                guard w.include, let ct = w.ct else { return nil }
                if let tm = w.tm, let med = targetMedianTm[normKey(w.target)], abs(tm - med) > settings.meltTolerance {
                    return nil
                }
                return (w.id, ct)
            }
            let cts = measured.map(\.ct)
            repStats[gKey] = (cts.count, cts.isEmpty ? nil : QPCRStatistics.mean(cts), QPCRStatistics.sampleSd(cts))
            
            // 基于中位数的稳健离群检测：避免均值掩蔽或 n=3 时将正常孔连同离群孔一并误删
            if measured.count >= 3, let center = QPCRStatistics.median(cts) {
                let candidates = measured
                    .filter { abs($0.ct - center) > settings.outlierLimit }
                    .sorted { abs($0.ct - center) > abs($1.ct - center) }
                let maxRemovable = max(1, (measured.count - 1) / 2)
                for c in candidates.prefix(maxRemovable) {
                    outlierWellIDs.insert(c.id)
                }
            }
        }
        
        var out: [String: QPCRWellQCResult] = [:]
        for w in wells {
            var flags: [QPCRQCFlag] = []
            let sKey = normKey(w.sample)
            let tKey = normKey(w.target)
            let wKey = normKey(w.well)
            
            if sKey.isEmpty || tKey.isEmpty {
                flags.append(.invalid)
            }
            
            switch w.wellType {
            case .ntc:
                if let ct = w.ct, ct < settings.ntcCtThreshold {
                    flags.append(.ntcAmplified)
                }
            case .noRT:
                if let ct = w.ct {
                    let strippedSample = sKey
                        .replacingOccurrences(of: "no-rt", with: "")
                        .replacingOccurrences(of: "nort", with: "")
                        .replacingOccurrences(of: "nrt", with: "")
                        .replacingOccurrences(of: "-rt", with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
                    let matchedSampleMean = repStats["\(strippedSample)|\(tKey)"]?.mean
                    let fallbackTargetMean = targetSampleCts[tKey].flatMap { $0.isEmpty ? nil : QPCRStatistics.mean($0) }
                    if let refSampleCt = matchedSampleMean ?? fallbackTargetMean {
                        if (ct - refSampleCt) < settings.noRTDeltaCtThreshold {
                            flags.append(.noRTAmplified)
                        }
                    } else if ct < settings.ntcCtThreshold {
                        flags.append(.noRTAmplified)
                    }
                }
            case .sample, .standard:
                if let ct = w.ct {
                    if ct > settings.highCtThreshold {
                        flags.append(.highCt)
                    }
                } else {
                    flags.append(.undetermined)
                    flags.append(.missingCt)
                    if refKeys.contains(tKey) {
                        flags.append(.missingRef)
                    }
                }
                if let tm = w.tm, let medTm = targetMedianTm[tKey] {
                    if abs(tm - medTm) > settings.meltTolerance {
                        flags.append(.meltOutlier)
                    }
                }
                let gKey = "\(sKey)|\(tKey)"
                if let st = repStats[gKey], w.ct != nil {
                    if st.n >= 2, let sd = st.sd, sd > settings.sdLimit {
                        flags.append(.replicateSd)
                    }
                    if outlierWellIDs.contains(w.id) {
                        flags.append(.outlier)
                    }
                }
            }
            
            if !wKey.isEmpty && (wellCounts[wKey] ?? 0) > 1 {
                flags.append(.duplicateWell)
            }
            let st = repStats["\(sKey)|\(tKey)"]
            out[w.id] = QPCRWellQCResult(
                flags: flags,
                replicateN: st?.n ?? 0,
                replicateMean: st?.mean,
                replicateSd: st?.sd
            )
        }
        return out
    }
    
    public static func isUsableWell(
        _ well: QPCRWellRecord,
        qc: QPCRWellQCResult?,
        settings: QPCRSettings
    ) -> Bool {
        guard well.include else { return false }
        // NTC 与 no-RT 对照孔绝不进入 ΔΔCt 或标准曲线未知样品定量计算 (P08)
        guard well.wellType == .sample || well.wellType == .standard else { return false }
        guard !well.sample.trimmingCharacters(in: .whitespaces).isEmpty,
              !well.target.trimmingCharacters(in: .whitespaces).isEmpty,
              well.ct != nil else { return false }
        if let qc = qc {
            // 熔解曲线 Tm 偏离孔（非特异扩增/引物二聚体）不参与定量计算 (P08)
            if qc.flags.contains(.meltOutlier) {
                return false
            }
            if settings.excludeOutliers && qc.flags.contains(.outlier) {
                return false
            }
        }
        return true
    }
    
    /// 执行 ΔΔCt 相对定量分析（支持多内参基因几何平均与自定义扩增效率校正）
    public static func computeDdct(
        wells: [QPCRWellRecord],
        settings: QPCRSettings,
        qc: [String: QPCRWellQCResult]
    ) -> QPCRDdctAnalysisOut {
        // 汇总存在 NTC 或 no-RT 污染起峰的靶标基因名称 (P08)
        var contaminatedSet = Set<String>()
        for w in wells {
            if let flags = qc[w.id]?.flags, (flags.contains(.ntcAmplified) || flags.contains(.noRTAmplified)) {
                let tName = w.target.trimmingCharacters(in: .whitespaces)
                if !tName.isEmpty {
                    contaminatedSet.insert(tName)
                }
            }
        }
        let contaminatedTargets = contaminatedSet.sorted()
        let nonStandardWells = wells.filter { $0.wellType == .sample && $0.quantity == nil }
        var targetMap: [String: String] = [:]
        var sampleMap: [String: String] = [:]
        var groupMap: [String: String] = [:]
        
        for w in nonStandardWells {
            let tk = normKey(w.target)
            if !tk.isEmpty && targetMap[tk] == nil { targetMap[tk] = w.target.trimmingCharacters(in: .whitespaces) }
            let sk = normKey(w.sample)
            if !sk.isEmpty && sampleMap[sk] == nil { sampleMap[sk] = w.sample.trimmingCharacters(in: .whitespaces) }
            let gk = normKey(w.group)
            if !gk.isEmpty && groupMap[gk] == nil { groupMap[gk] = w.group.trimmingCharacters(in: .whitespaces) }
        }
        
        let sortedTargets = targetMap.values.sorted()
        let sortedSamples = sampleMap.values.sorted()
        let sortedGroups = groupMap.values.sorted()
        let hasGroups = !sortedGroups.isEmpty
        
        // 解析内参基因列表
        let reqRefKeys = settings.referenceTargets.map(normKey).filter { targetMap[$0] != nil }
        let activeRefKeys: [String] = !reqRefKeys.isEmpty
            ? reqRefKeys
            : (sortedTargets.first.map { [normKey($0)] } ?? [])
        let activeRefKeySet = Set(activeRefKeys)
        let activeRefLabels = activeRefKeys.compactMap { targetMap[$0] }
        
        struct SampleBucket {
            let sample: String
            let sampleKey: String
            let group: String
            let category: String
            var isControl: Bool
            var refWells: [String: [QPCRWellRecord]] = [:]
            var targetWells: [String: [QPCRWellRecord]] = [:]
        }
        
        var buckets: [String: SampleBucket] = [:]
        for w in nonStandardWells {
            guard isUsableWell(w, qc: qc[w.id], settings: settings) else { continue }
            let sk = normKey(w.sample)
            let tk = normKey(w.target)
            let gk = normKey(w.group)
            let sLabel = sampleMap[sk] ?? w.sample
            let gLabel = groupMap[gk] ?? w.group
            let category = (hasGroups && !gLabel.isEmpty) ? gLabel : sLabel
            
            if buckets[sk] == nil {
                buckets[sk] = SampleBucket(
                    sample: sLabel,
                    sampleKey: sk,
                    group: gLabel,
                    category: category,
                    isControl: false
                )
            }
            if activeRefKeySet.contains(tk) {
                buckets[sk]?.refWells[tk, default: []].append(w)
            } else {
                buckets[sk]?.targetWells[tk, default: []].append(w)
            }
        }
        
        let orderedSampleKeys = buckets.keys.sorted { a, b in
            let ba = buckets[a]!
            let bb = buckets[b]!
            if ba.category != bb.category { return ba.category < bb.category }
            return ba.sample < bb.sample
        }
        
        // 确定对照组样品集合
        var controlSampleKeys = Set<String>()
        var controlLabel = ""
        let reqCtrlGroupKey = normKey(settings.controlGroup)
        let reqCtrlSampleKey = normKey(settings.controlSample)
        
        if hasGroups && !reqCtrlGroupKey.isEmpty {
            let matched = orderedSampleKeys.filter { normKey(buckets[$0]!.group) == reqCtrlGroupKey }
            if !matched.isEmpty {
                controlSampleKeys = Set(matched)
                controlLabel = groupMap[reqCtrlGroupKey] ?? settings.controlGroup
            }
        }
        if controlSampleKeys.isEmpty && !reqCtrlSampleKey.isEmpty, buckets[reqCtrlSampleKey] != nil {
            controlSampleKeys = [reqCtrlSampleKey]
            controlLabel = sampleMap[reqCtrlSampleKey] ?? settings.controlSample
        }
        if controlSampleKeys.isEmpty, let firstKey = orderedSampleKeys.first {
            controlSampleKeys = [firstKey]
            controlLabel = buckets[firstKey]!.category
        }
        for ck in controlSampleKeys {
            buckets[ck]?.isControl = true
        }
        
        // 若数据集含标准曲线孔且开启效率校正，自动提取有效标曲扩增效率及标准误差 SE(E) (Pfaffl 2001 / qBase 2007)
        // 注意：fit.efficiencyPct 为已知百分比制 (%)，不可再走单位猜测分支
        var stdCurveEffByTarget: [String: Double] = [:]
        var stdCurveEffSEByTarget: [String: Double] = [:]
        if settings.efficiencyCorrection && wells.contains(where: { $0.wellType == .standard || $0.quantity != nil }) {
            let stdOut = computeStandardCurve(wells: wells, settings: settings, qc: qc)
            for fit in stdOut.fits where fit.valid {
                if let effPct = fit.efficiencyPct, effPct.isFinite, effPct > 0 {
                    stdCurveEffByTarget[fit.targetKey] = max(0.10, min(1.50, effPct / 100.0))
                }
                if let effSE = fit.efficiencySE, effSE.isFinite, effSE >= 0 {
                    stdCurveEffSEByTarget[fit.targetKey] = effSE
                }
            }
        }
        let usableSampleWells = nonStandardWells.filter { isUsableWell($0, qc: qc[$0.id], settings: settings) }
        func resolveTargetEfficiency(forKey tk: String) -> Double {
            guard settings.efficiencyCorrection else { return 1.0 }
            if let stdEff = stdCurveEffByTarget[tk] {
                return stdEff
            }
            let wellEffs = usableSampleWells
                .filter { normKey($0.target) == tk }
                .compactMap { $0.efficiency.flatMap(QPCRStatistics.normalizeEfficiencyFraction) }
            if !wellEffs.isEmpty {
                return QPCRStatistics.mean(wellEffs)
            }
            let fallbackPct = settings.defaultEfficiencyPct
            return (fallbackPct.isFinite && fallbackPct > 0) ? max(0.10, min(1.50, fallbackPct / 100.0)) : 1.0
        }
        
        // 计算每个样品的内参归一化 Ct (Vandesompele et al., Genome Biol. 2002 / Hellemans et al., Genome Biol. 2007 Eq. 5–8):
        // 先按各个内参分别在对照组（若无对照组则全部样本）建立基线均值 mu_r，再对样品实测内参子集做基线中心化平均，
        // 避免当某样品缺失其中一个内参时因各内参本底丰度截距不同产生严重虚假倍数偏移（完整内参时严格退化为算术/加权均值）
        var refCtBySample: [String: Double] = [:]
        var refEffCtBySample: [String: Double] = [:]
        var refEffCache: [String: Double] = [:]
        for rk in activeRefKeys {
            refEffCache[rk] = resolveTargetEfficiency(forKey: rk)
        }
        var refRawBaseline: [String: Double] = [:]
        var refEffBaseline: [String: Double] = [:]
        for rk in activeRefKeys {
            let effR = refEffCache[rk] ?? 1.0
            let scaleR = log2(1.0 + effR)
            let ctrlMeans = orderedSampleKeys.compactMap { sk -> Double? in
                guard controlSampleKeys.contains(sk), let b = buckets[sk] else { return nil }
                let cts = (b.refWells[rk] ?? []).compactMap(\.ct)
                return cts.isEmpty ? nil : QPCRStatistics.mean(cts)
            }
            let basePool = !ctrlMeans.isEmpty ? ctrlMeans : orderedSampleKeys.compactMap { sk -> Double? in
                guard let b = buckets[sk] else { return nil }
                let cts = (b.refWells[rk] ?? []).compactMap(\.ct)
                return cts.isEmpty ? nil : QPCRStatistics.mean(cts)
            }
            if !basePool.isEmpty {
                let rawMu = QPCRStatistics.mean(basePool)
                refRawBaseline[rk] = rawMu
                refEffBaseline[rk] = rawMu * scaleR
            }
        }
        let validBaselineRefs = activeRefKeys.filter { refRawBaseline[$0] != nil }
        let globalRawAnchor = validBaselineRefs.isEmpty ? 0.0 : QPCRStatistics.mean(validBaselineRefs.map { refRawBaseline[$0]! })
        let globalEffAnchor = validBaselineRefs.isEmpty ? 0.0 : QPCRStatistics.mean(validBaselineRefs.map { refEffBaseline[$0]! })
        
        for sk in orderedSampleKeys {
            let bucket = buckets[sk]!
            var rawDeltas: [Double] = []
            var effDeltas: [Double] = []
            for rk in validBaselineRefs {
                let cts = (bucket.refWells[rk] ?? []).compactMap(\.ct)
                if !cts.isEmpty, let rawMu = refRawBaseline[rk], let effMu = refEffBaseline[rk] {
                    let meanRefCt = QPCRStatistics.mean(cts)
                    let effR = refEffCache[rk] ?? 1.0
                    rawDeltas.append(meanRefCt - rawMu)
                    effDeltas.append(meanRefCt * log2(1.0 + effR) - effMu)
                }
            }
            if !rawDeltas.isEmpty {
                refCtBySample[sk] = globalRawAnchor + QPCRStatistics.mean(rawDeltas)
                refEffCtBySample[sk] = globalEffAnchor + QPCRStatistics.mean(effDeltas)
            }
        }
        
        let nonRefTargetKeys = sortedTargets.map(normKey).filter { !activeRefKeySet.contains($0) }
        var targetEffCache: [String: Double] = [:]
        for tk in nonRefTargetKeys {
            targetEffCache[tk] = resolveTargetEfficiency(forKey: tk)
        }
        
        // 计算对照组在各目的基因上的平均 ΔCt_eff（以 log2 归一化周期为单位）与原始平均 Cq（用于效率误差传播）
        var controlMeanDCt: [String: Double] = [:]
        var controlMeanRawCt: [String: Double] = [:]
        for tk in nonRefTargetKeys {
            let effT = targetEffCache[tk] ?? 1.0
            let scaleT = log2(1.0 + effT)
            var vals: [Double] = []
            var rawVals: [Double] = []
            for ck in controlSampleKeys {
                guard let bucket = buckets[ck],
                      let refEffCt = refEffCtBySample[ck],
                      let tws = bucket.targetWells[tk],
                      !tws.isEmpty else { continue }
                let cts = tws.compactMap(\.ct)
                if !cts.isEmpty {
                    let mCt = QPCRStatistics.mean(cts)
                    vals.append(mCt * scaleT - refEffCt)
                    rawVals.append(mCt)
                }
            }
            if !vals.isEmpty {
                controlMeanDCt[tk] = QPCRStatistics.mean(vals)
                controlMeanRawCt[tk] = QPCRStatistics.mean(rawVals)
            }
        }
        
        var sampleResults: [QPCRSampleResult] = []
        var heatmapCells: [QPCRHeatmapCell] = []
        
        for sk in orderedSampleKeys {
            let bucket = buckets[sk]!
            guard let refCt = refCtBySample[sk],
                  let refEffCt = refEffCtBySample[sk] else { continue }
            
            for tk in nonRefTargetKeys {
                let tLabel = targetMap[tk] ?? tk
                guard let tws = bucket.targetWells[tk], !tws.isEmpty,
                      let ctrlDCt = controlMeanDCt[tk] else { continue }
                let cts = tws.compactMap(\.ct)
                guard !cts.isEmpty else { continue }
                
                let eff = targetEffCache[tk] ?? 1.0
                let scaleT = log2(1.0 + eff)
                let meanCt = QPCRStatistics.mean(cts)
                let sdCt = QPCRStatistics.sampleSd(cts)
                let dCt = meanCt * scaleT - refEffCt
                let ddCt = dCt - ctrlDCt
                
                // 各技术复孔与样本主值均在 log2(NRQ) 空间严格满足 Pfaffl (2001) / qBase (2007) 且无 Jensen 偏倚
                let foldValues = cts.map { pow(2.0, -(($0 * scaleT - refEffCt) - ctrlDCt)) }
                let fold = pow(2.0, -ddCt)

                // Pfaffl/qBase 一阶泰勒误差传播：同时纳入靶基因 ΔCq_t/E_t·SE(E_t) 与各内参基因 ΔCq_r/(R·E_r)·SE(E_r)
                let effPropSE: Double? = {
                    guard settings.efficiencyCorrection else { return nil }
                    var relVarSum = 0.0
                    var hasAnySE = false
                    let eFactorT = 1.0 + eff
                    if let eSEt = stdCurveEffSEByTarget[tk], eFactorT > 0.1,
                       let ctrlRawT = controlMeanRawCt[tk] {
                        let dCqT = meanCt - ctrlRawT
                        let termT = (dCqT / eFactorT) * eSEt
                        relVarSum += termT * termT
                        hasAnySE = true
                    }
                    let presentRefs = validBaselineRefs.filter { rk in
                        !(bucket.refWells[rk]?.compactMap(\.ct).isEmpty ?? true)
                    }
                    let rCount = Double(max(1, presentRefs.count))
                    for rk in presentRefs {
                        let effR = refEffCache[rk] ?? 1.0
                        let eFactorR = 1.0 + effR
                        guard let eSEr = stdCurveEffSEByTarget[rk], eFactorR > 0.1,
                              let rawMuR = refRawBaseline[rk] else { continue }
                        let rCts = (bucket.refWells[rk] ?? []).compactMap(\.ct)
                        guard !rCts.isEmpty else { continue }
                        let dCqR = QPCRStatistics.mean(rCts) - rawMuR
                        let termR = (dCqR / (rCount * eFactorR)) * eSEr
                        relVarSum += termR * termR
                        hasAnySE = true
                    }
                    return hasAnySE ? (fold * sqrt(max(0.0, relVarSum))) : nil
                }()
                
                sampleResults.append(
                    QPCRSampleResult(
                        sample: bucket.sample,
                        sampleKey: sk,
                        target: tLabel,
                        targetKey: tk,
                        group: bucket.group,
                        category: bucket.category,
                        n: cts.count,
                        meanCt: meanCt,
                        sdCt: sdCt,
                        refCt: refCt,
                        dCt: dCt,
                        ddCt: ddCt,
                        efficiency: eff,
                        fold: fold,
                        foldSd: QPCRStatistics.sampleSd(foldValues),
                        foldSem: QPCRStatistics.sem(foldValues),
                        foldValues: foldValues,
                        isControl: bucket.isControl,
                        efficiencyPropagatedFoldSE: effPropSE
                    )
                )
                
                heatmapCells.append(
                    QPCRHeatmapCell(
                        sample: bucket.sample,
                        group: bucket.category,
                        target: tLabel,
                        dCt: dCt,
                        ddCt: ddCt,
                        fold: fold
                    )
                )
            }
        }
        
        // 按组汇总并计算相对对照组的 Welch's t-test p 值（在 log2 NRQ / dCt_eff 空间检验，并以几何均值确保与 95% CI 自洽）
        var categoryOrder: [String] = []
        for s in sampleResults where !categoryOrder.contains(s.category) {
            categoryOrder.append(s.category)
        }
        
        var groupResults: [QPCRGroupSummary] = []
        for tk in nonRefTargetKeys {
            let tLabel = targetMap[tk] ?? tk
            let ctrlRows = sampleResults.filter { $0.isControl && $0.targetKey == tk }
            // 严格仅使用生物学样品级 dCt 进行 Welch's t-test，禁止把技术复孔当作独立生物学样本 (P02)
            let ctrlSampleDCts = ctrlRows.map(\.dCt)
            
            struct PendingTargetGroup {
                let cat: String
                let isCtrl: Bool
                let sampleFolds: [Double]
                let allDCts: [Double]
                let nBio: Int
                let nTech: Int
                let pVal: Double?
                let ci: (ddCtDiff: Double, ddCtLow: Double, ddCtHigh: Double, foldLow: Double, foldHigh: Double, df: Double)?
                let note: QPCRStatNote
            }
            
            var pending: [PendingTargetGroup] = []
            for cat in categoryOrder {
                let rows = sampleResults.filter { $0.category == cat && $0.targetKey == tk }
                guard !rows.isEmpty else { continue }
                let isCtrl = rows.allSatisfy(\.isControl)
                let sampleFolds = rows.map(\.fold)
                let allDCts = rows.map(\.dCt)
                let nBio = rows.count
                let nTech = rows.reduce(0) { $0 + $1.n }
                
                var pVal: Double? = nil
                var ciRes: (ddCtDiff: Double, ddCtLow: Double, ddCtHigh: Double, foldLow: Double, foldHigh: Double, df: Double)? = nil
                var note: QPCRStatNote = .ok
                if !isCtrl {
                    if nBio >= 2 && ctrlSampleDCts.count >= 2 {
                        pVal = QPCRStatistics.welchTTest(allDCts, ctrlSampleDCts)?.p
                        ciRes = QPCRStatistics.welchCI95(allDCts, ctrlSampleDCts, base: 2.0)
                        note = (pVal != nil) ? .ok : .insufficientBiologicalReplicates
                    } else {
                        pVal = nil
                        note = .insufficientBiologicalReplicates
                    }
                }
                pending.append(
                    PendingTargetGroup(
                        cat: cat,
                        isCtrl: isCtrl,
                        sampleFolds: sampleFolds,
                        allDCts: allDCts,
                        nBio: nBio,
                        nTech: nTech,
                        pVal: pVal,
                        ci: ciRes,
                        note: note
                    )
                )
            }
            
            // 每个 target 内部对所有“处理组 vs 对照组”的 p 值执行 Holm–Bonferroni 多重比较校正 (P07)
            let rawPsForTarget: [Double?] = pending.map { $0.isCtrl ? nil : $0.pVal }
            let holmPsForTarget = QPCRStatistics.holmAdjustOptional(rawPsForTarget)
            let ctrlMeanDCt = ctrlSampleDCts.isEmpty ? (controlMeanDCt[tk] ?? 0.0) : QPCRStatistics.mean(ctrlSampleDCts)
            
            for (idx, item) in pending.enumerated() {
                let pAdj: Double? = item.isCtrl ? nil : (settings.multipleComparison == .holm ? holmPsForTarget[idx] : item.pVal)
                let grpMeanDCt = QPCRStatistics.mean(item.allDCts)
                let geomFold = pow(2.0, -(grpMeanDCt - ctrlMeanDCt))
                groupResults.append(
                    QPCRGroupSummary(
                        category: item.cat,
                        categoryKey: normKey(item.cat),
                        target: tLabel,
                        targetKey: tk,
                        nBiological: item.nBio,
                        nTechnicalWells: item.nTech,
                        meanFold: geomFold,
                        sdFold: QPCRStatistics.sampleSd(item.sampleFolds),
                        semFold: QPCRStatistics.sem(item.sampleFolds),
                        meanDCt: grpMeanDCt,
                        sdDCt: QPCRStatistics.sampleSd(item.allDCts),
                        pValue: item.pVal,
                        pAdjusted: pAdj,
                        multipleComparison: settings.multipleComparison,
                        ddCtCI95Low: item.ci?.ddCtLow,
                        ddCtCI95High: item.ci?.ddCtHigh,
                        foldCI95Low: item.ci?.foldLow,
                        foldCI95High: item.ci?.foldHigh,
                        statNote: item.note,
                        foldValues: item.sampleFolds,
                        isControl: item.isCtrl
                    )
                )
            }
        }
        
        // 多基因批量筛查 Benjamini–Hochberg FDR 跨基因多重检验校正
        let finalGroupResults: [QPCRGroupSummary]
        if settings.multipleComparison == .bhFDR {
            let allRawPs: [Double?] = groupResults.map { $0.isControl ? nil : $0.pValue }
            let bhAdjPs = QPCRStatistics.bhAdjustOptional(allRawPs)
            finalGroupResults = groupResults.enumerated().map { idx, g in
                QPCRGroupSummary(
                    category: g.category,
                    categoryKey: g.categoryKey,
                    target: g.target,
                    targetKey: g.targetKey,
                    nBiological: g.nBiological,
                    nTechnicalWells: g.nTechnicalWells,
                    meanFold: g.meanFold,
                    sdFold: g.sdFold,
                    semFold: g.semFold,
                    meanDCt: g.meanDCt,
                    sdDCt: g.sdDCt,
                    pValue: g.pValue,
                    pAdjusted: g.isControl ? nil : bhAdjPs[idx],
                    multipleComparison: .bhFDR,
                    ddCtCI95Low: g.ddCtCI95Low,
                    ddCtCI95High: g.ddCtCI95High,
                    foldCI95Low: g.foldCI95Low,
                    foldCI95High: g.foldCI95High,
                    statNote: g.statNote,
                    foldValues: g.foldValues,
                    isControl: g.isControl
                )
            }
        } else {
            finalGroupResults = groupResults
        }
        
        return QPCRDdctAnalysisOut(
            references: activeRefLabels,
            targets: sortedTargets,
            samples: sortedSamples,
            groups: sortedGroups,
            controlLabel: controlLabel,
            contaminatedTargets: contaminatedTargets,
            sampleResults: sampleResults,
            groupResults: finalGroupResults,
            heatmapCells: heatmapCells
        )
    }
    
    /// 执行标准曲线拟合与未知样品绝对定量插值
    public static func computeStandardCurve(
        wells: [QPCRWellRecord],
        settings: QPCRSettings,
        qc: [String: QPCRWellQCResult]
    ) -> QPCRStandardAnalysisOut {
        var targetMap: [String: String] = [:]
        var ptsByTarget: [String: [(x: Double, y: Double)]] = [:]
        
        for w in wells {
            guard isUsableWell(w, qc: qc[w.id], settings: settings),
                  let ct = w.ct, let qty = w.quantity else { continue }
            let logX = settings.quantityIsLog10 ? qty : (qty > 0 ? log10(qty) : .nan)
            guard logX.isFinite else { continue }
            let tk = normKey(w.target)
            guard !tk.isEmpty else { continue }
            if targetMap[tk] == nil { targetMap[tk] = w.target.trimmingCharacters(in: .whitespaces) }
            ptsByTarget[tk, default: []].append((x: logX, y: ct))
        }
        
        var fits: [QPCRStandardCurveFit] = []
        var fitMap: [String: QPCRStandardCurveFit] = [:]
        for (tk, pts) in ptsByTarget.sorted(by: { $0.key < $1.key }) {
            let label = targetMap[tk] ?? tk
            let ys = pts.map(\.y)
            if let reg = QPCRStatistics.linearRegressionWithSE(pts) {
                let eff = QPCRStatistics.efficiencyFromSlope(reg.slope) * 100.0
                let effSE = reg.slopeSE.flatMap { QPCRStatistics.efficiencySEFromSlope(slope: reg.slope, slopeSE: $0) }
                let valid = reg.slope < 0 && eff.isFinite
                let fit = QPCRStandardCurveFit(
                    targetKey: tk,
                    target: label,
                    slope: reg.slope,
                    intercept: reg.intercept,
                    r2: reg.r2,
                    efficiencyPct: eff,
                    n: pts.count,
                    xMin: reg.xMin,
                    xMax: reg.xMax,
                    valid: valid,
                    points: pts,
                    slopeSE: reg.slopeSE,
                    efficiencySE: effSE,
                    ctMin: ys.min(),
                    ctMax: ys.max()
                )
                fits.append(fit)
                fitMap[tk] = fit
            } else {
                let fit = QPCRStandardCurveFit(
                    targetKey: tk,
                    target: label,
                    slope: nil,
                    intercept: nil,
                    r2: nil,
                    efficiencyPct: nil,
                    n: pts.count,
                    xMin: nil,
                    xMax: nil,
                    valid: false,
                    points: pts
                )
                fits.append(fit)
            }
        }
        
        struct StdBucket {
            let sample: String
            let sampleKey: String
            let target: String
            let targetKey: String
            let group: String
            let category: String
            var cts: [Double] = []
            var logQtys: [Double] = []
        }
        
        var buckets: [String: StdBucket] = [:]
        for w in wells {
            guard isUsableWell(w, qc: qc[w.id], settings: settings),
                  w.quantity == nil, let ct = w.ct else { continue }
            let tk = normKey(w.target)
            let sk = normKey(w.sample)
            guard !sk.isEmpty,
                  let fit = fitMap[tk], fit.valid,
                  let slope = fit.slope, slope != 0,
                  let intercept = fit.intercept else { continue }
            
            let logQ = (ct - intercept) / slope
            let bKey = "\(sk)|\(tk)"
            if buckets[bKey] == nil {
                let grp = w.group.trimmingCharacters(in: .whitespaces)
                let smp = w.sample.trimmingCharacters(in: .whitespaces)
                buckets[bKey] = StdBucket(
                    sample: smp,
                    sampleKey: sk,
                    target: fit.target,
                    targetKey: tk,
                    group: grp,
                    category: grp.isEmpty ? smp : grp
                )
            }
            buckets[bKey]?.cts.append(ct)
            buckets[bKey]?.logQtys.append(logQ)
        }
        
        let outSamples = buckets.values.map { b -> QPCRStandardSampleResult in
            let meanLog = QPCRStatistics.mean(b.logQtys)
            let meanCt = QPCRStatistics.mean(b.cts)
            let fit = fitMap[b.targetKey]
            var isExtrap = false
            var extrapWarn: String? = nil
            if let xMin = fit?.xMin, let xMax = fit?.xMax {
                if meanLog < xMin - 1e-9 {
                    isExtrap = true
                    extrapWarn = L10n.tr(
                        "低于标准曲线最低定量浓度（Ct=\(String(format: "%.2f", meanCt)) 超出标准品上限），存在外推不确定性",
                        "Below standard curve lowest concentration (Ct=\(String(format: "%.2f", meanCt))); extrapolated estimate"
                    )
                } else if meanLog > xMax + 1e-9 {
                    isExtrap = true
                    extrapWarn = L10n.tr(
                        "高于标准曲线最高定量浓度（Ct=\(String(format: "%.2f", meanCt)) 低于标准品下限），存在外推不确定性",
                        "Above standard curve highest concentration (Ct=\(String(format: "%.2f", meanCt))); extrapolated estimate"
                    )
                }
            }
            return QPCRStandardSampleResult(
                sample: b.sample,
                sampleKey: b.sampleKey,
                target: b.target,
                targetKey: b.targetKey,
                group: b.group,
                category: b.category,
                n: b.cts.count,
                meanCt: meanCt,
                log10Quantity: meanLog,
                quantity: pow(10.0, meanLog),
                sdLog: QPCRStatistics.sampleSd(b.logQtys),
                semLog: QPCRStatistics.sem(b.logQtys),
                isExtrapolated: isExtrap,
                extrapolationWarning: extrapWarn
            )
        }.sorted { ($0.category, $0.sample, $0.target) < ($1.category, $1.sample, $1.target) }
        
        return QPCRStandardAnalysisOut(fits: fits, samples: outSamples)
    }

    /// geNorm (Vandesompele et al. 2002) 与 NormFinder (Andersen et al. 2004, Cancer Res. 64:5245-5250) 内参基因稳定性真实评估
    public static func evaluateReferenceStability(
        wells: [QPCRWellRecord],
        settings: QPCRSettings,
        qc: [String: QPCRWellQCResult]
    ) -> QPCRReferenceStabilityReport {
        // 先过滤出在板上真实存在的候选内参基因，避免配置中残留未上板基因导致可用样本归零
        var presentSampleTargets = Set<String>()
        for w in wells {
            guard isUsableWell(w, qc: qc[w.id], settings: settings),
                  w.wellType == .sample, w.ct != nil else { continue }
            let tk = normKey(w.target)
            if !tk.isEmpty { presentSampleTargets.insert(tk) }
        }
        let refKeysOrdered: [String] = settings.referenceTargets.map { normKey($0) }.filter { !$0.isEmpty && presentSampleTargets.contains($0) }
        var uniqueRefKeys: [String] = []
        for k in refKeysOrdered where !uniqueRefKeys.contains(k) { uniqueRefKeys.append(k) }
        guard uniqueRefKeys.count >= 2 else {
            return QPCRReferenceStabilityReport(
                genes: [],
                stepwiseExclusionOrder: [],
                pairwiseVariations: [],
                bestReferencePair: uniqueRefKeys,
                isStable: false,
                warnings: [L10n.t("至少需要 2 个候选内参基因才能执行 geNorm / NormFinder 稳定性评估。")]
            )
        }

        // 若开启扩增效率校正，按标准曲线 / 孔级效率 / 默认效率解析各内参的 log2(1 + E_j) 缩放因子
        var stdCurveEffByTarget: [String: Double] = [:]
        if settings.efficiencyCorrection && wells.contains(where: { $0.wellType == .standard || $0.quantity != nil }) {
            let stdOut = computeStandardCurve(wells: wells, settings: settings, qc: qc)
            for fit in stdOut.fits where fit.valid {
                if let effPct = fit.efficiencyPct, effPct.isFinite, effPct > 0 {
                    stdCurveEffByTarget[fit.targetKey] = max(0.10, min(1.50, effPct / 100.0))
                }
            }
        }
        let usableSampleWells = wells.filter { $0.wellType == .sample && $0.quantity == nil && isUsableWell($0, qc: qc[$0.id], settings: settings) }
        func resolveRefScale(forKey tk: String) -> Double {
            guard settings.efficiencyCorrection else { return 1.0 }
            let eff: Double
            if let stdEff = stdCurveEffByTarget[tk] {
                eff = stdEff
            } else {
                let wellEffs = usableSampleWells
                    .filter { normKey($0.target) == tk }
                    .compactMap { $0.efficiency.flatMap(QPCRStatistics.normalizeEfficiencyFraction) }
                if !wellEffs.isEmpty {
                    eff = QPCRStatistics.mean(wellEffs)
                } else {
                    let fallbackPct = settings.defaultEfficiencyPct
                    eff = (fallbackPct.isFinite && fallbackPct > 0) ? max(0.10, min(1.50, fallbackPct / 100.0)) : 1.0
                }
            }
            return log2(1.0 + eff)
        }
        let refScales: [Double] = uniqueRefKeys.map { resolveRefScale(forKey: $0) }

        var targetLabel: [String: String] = [:]
        var sampleGroup: [String: String] = [:]
        var sampleRefCts: [String: [String: [Double]]] = [:]
        for w in wells {
            guard isUsableWell(w, qc: qc[w.id], settings: settings),
                  w.wellType == .sample, let ct = w.ct else { continue }
            let tk = normKey(w.target)
            guard uniqueRefKeys.contains(tk) else { continue }
            let sk = normKey(w.sample)
            guard !sk.isEmpty else { continue }
            if targetLabel[tk] == nil { targetLabel[tk] = w.target.trimmingCharacters(in: .whitespaces) }
            let grp = w.group.trimmingCharacters(in: .whitespaces)
            // 严禁将空 group 回退为 sample 名制造伪单样本分组
            if sampleGroup[sk] == nil || (sampleGroup[sk]?.isEmpty == true && !grp.isEmpty) {
                sampleGroup[sk] = grp
            }
            sampleRefCts[sk, default: [:]][tk, default: []].append(ct)
        }

        let completeSamples = sampleRefCts.keys.sorted().filter { sk in
            uniqueRefKeys.allSatisfy { !(sampleRefCts[sk]?[$0]?.isEmpty ?? true) }
        }
        guard completeSamples.count >= 2 else {
            return QPCRReferenceStabilityReport(
                genes: [],
                stepwiseExclusionOrder: [],
                pairwiseVariations: [],
                bestReferencePair: uniqueRefKeys.map { targetLabel[$0] ?? $0 },
                isStable: false,
                warnings: [L10n.t("同时包含全部候选内参的有效样本不足 2 个，无法计算 geNorm M 值。")]
            )
        }

        let mSamples = completeSamples.count
        let nGenes = uniqueRefKeys.count
        var rawCtMat = Array(repeating: Array(repeating: 0.0, count: nGenes), count: mSamples)
        var ctMat = Array(repeating: Array(repeating: 0.0, count: nGenes), count: mSamples)
        for (i, sk) in completeSamples.enumerated() {
            for (j, rk) in uniqueRefKeys.enumerated() {
                let rawMean = QPCRStatistics.mean(sampleRefCts[sk]?[rk] ?? [0.0])
                rawCtMat[i][j] = rawMean
                ctMat[i][j] = rawMean * refScales[j]
            }
        }

        func computeGeNormM(indices: [Int]) -> [Int: Double] {
            let k = indices.count
            guard k >= 2 else { return [:] }
            var mMap: [Int: Double] = [:]
            for j in indices {
                var sumV = 0.0
                for l in indices where l != j {
                    let logRatios = (0..<mSamples).map { ctMat[$0][l] - ctMat[$0][j] }
                    let sd = QPCRStatistics.sampleSd(logRatios) ?? 0.0
                    sumV += sd
                }
                mMap[j] = sumV / Double(k - 1)
            }
            return mMap
        }

        // 逐步排除并记录每个基因在被剔除步骤的最终 geNorm M（最佳双基因对记录最终成对 M）
        var active = Array(0..<nGenes)
        var exclusionOrder: [String] = []
        var pairwiseVars: [QPCRPairwiseVariation] = []
        var stepwiseM: [Int: Double] = [:]
        while active.count > 2 {
            let mNow = computeGeNormM(indices: active)
            let worst = active.max { (mNow[$0] ?? 0.0) < (mNow[$1] ?? 0.0) } ?? active[0]
            stepwiseM[worst] = mNow[worst] ?? 0.0
            let nextActive = active.filter { $0 != worst }
            let nfDiffs = (0..<mSamples).map { i -> Double in
                let nfNext = nextActive.reduce(0.0) { $0 - ctMat[i][$1] } / Double(nextActive.count)
                let nfCurr = active.reduce(0.0) { $0 - ctMat[i][$1] } / Double(active.count)
                return nfNext - nfCurr
            }
            let vVal = QPCRStatistics.sampleSd(nfDiffs) ?? 0.0
            pairwiseVars.append(QPCRPairwiseVariation(label: "V\(nextActive.count)/\(active.count)", nGenes: nextActive.count, value: vVal))
            exclusionOrder.append(targetLabel[uniqueRefKeys[worst]] ?? uniqueRefKeys[worst])
            active = nextActive
        }
        let finalPairM = computeGeNormM(indices: active)
        for idx in active {
            stepwiseM[idx] = finalPairM[idx] ?? 0.0
        }
        let bestPairLabels = active.map { targetLabel[uniqueRefKeys[$0]] ?? uniqueRefKeys[$0] }

        // 仅对显式赋予非空 group 的样本进行组间分析与 NormFinder (Andersen et al. 2004, Cancer Res. 64:5245-5250)
        let labeledIndices = (0..<mSamples).filter { !(sampleGroup[completeSamples[$0]] ?? "").isEmpty }
        let groupedSampleIndices = Dictionary(grouping: labeledIndices) { sampleGroup[completeSamples[$0]]! }
        let validGroupKeys = groupedSampleIndices.keys.sorted().filter { (groupedSampleIndices[$0]?.count ?? 0) >= 2 }
        var normFinderMap: [Int: Double] = [:]
        if nGenes >= 3 && validGroupKeys.count >= 2 {
            let k = nGenes
            let gCount = validGroupKeys.count
            let yMat = ctMat.map { row in row.map { -$0 } }

            // 1. 计算 k × G 组均值矩阵并做双中心化（支持非平衡分组 n_g）
            var groupMeanMat = Array(repeating: Array(repeating: 0.0, count: gCount), count: k)
            var nByG = Array(repeating: 0, count: gCount)
            for (gIdx, gk) in validGroupKeys.enumerated() {
                let idxs = groupedSampleIndices[gk] ?? []
                nByG[gIdx] = idxs.count
                for i in 0..<k {
                    groupMeanMat[i][gIdx] = QPCRStatistics.mean(idxs.map { yMat[$0][i] })
                }
            }
            let geneMeanOfGroups = (0..<k).map { i in
                groupMeanMat[i].reduce(0.0, +) / Double(gCount)
            }
            let groupMeanOfGenes = (0..<gCount).map { g in
                (0..<k).reduce(0.0) { $0 + groupMeanMat[$1][g] } / Double(k)
            }
            let grandMeanOfGroups = geneMeanOfGroups.reduce(0.0, +) / Double(k)
            var dMat = Array(repeating: Array(repeating: 0.0, count: gCount), count: k)
            var sumDSq = 0.0
            for i in 0..<k {
                for g in 0..<gCount {
                    let d = groupMeanMat[i][g] - geneMeanOfGroups[i] - groupMeanOfGenes[g] + grandMeanOfGroups
                    dMat[i][g] = d
                    sumDSq += d * d
                }
            }

            // 2. 组内无偏方差估计 σ²_{ig}（修正 (1 - 2/k) 与跨基因泄露项）
            var sigma2Mat = Array(repeating: Array(repeating: 0.0, count: gCount), count: k)
            let denomFactor = 1.0 - 2.0 / Double(k)
            var sumSigma2OverN = 0.0
            for (gIdx, gk) in validGroupKeys.enumerated() {
                let idxs = groupedSampleIndices[gk] ?? []
                let ng = idxs.count
                guard ng >= 2 else { continue }
                var vVec = Array(repeating: 0.0, count: k)
                for sIdx in idxs {
                    let sampleMeanAcrossGenes = (0..<k).reduce(0.0) { $0 + yMat[sIdx][$1] } / Double(k)
                    for i in 0..<k {
                        let r = yMat[sIdx][i] - groupMeanMat[i][gIdx] - sampleMeanAcrossGenes + groupMeanOfGenes[gIdx]
                        vVec[i] += r * r
                    }
                }
                for i in 0..<k { vVec[i] /= Double(ng - 1) }
                let vSum = vVec.reduce(0.0, +)
                let leakTerm = vSum / Double(k * (k - 1))
                for i in 0..<k {
                    let unbiased = max(0.0, (vVec[i] - leakTerm) / denomFactor)
                    sigma2Mat[i][gIdx] = unbiased
                    sumSigma2OverN += unbiased / Double(ng)
                }
            }

            // 3. 经验贝叶斯先验方差 τ²、后验收缩均值 γ̂_{ig} 与后验方差 ω̂²_{ig}
            let tau2 = max(0.0, sumDSq / Double((k - 1) * (gCount - 1)) - sumSigma2OverN / Double(k * gCount))
            for i in 0..<k {
                var rhoSum = 0.0
                for g in 0..<gCount {
                    let ng = Double(max(1, nByG[g]))
                    let s2OverN = sigma2Mat[i][g] / ng
                    let denom = tau2 + s2OverN
                    let gammaHat = denom > 1e-18 ? (tau2 / denom) * dMat[i][g] : 0.0
                    let omega2 = s2OverN + (denom > 1e-18 ? (tau2 * s2OverN / denom) : 0.0)
                    rhoSum += abs(gammaHat) + sqrt(max(0.0, omega2))
                }
                normFinderMap[i] = rhoSum / Double(gCount)
            }
        }

        var metrics: [QPCRReferenceGeneMetric] = []
        var warnings: [String] = []
        var anyUnstable = false

        for j in 0..<nGenes {
            let rk = uniqueRefKeys[j]
            let label = targetLabel[rk] ?? rk
            let mVal = stepwiseM[j] ?? 0.0
            let maxShift: Double
            if groupedSampleIndices.count >= 2 {
                let groupMeans = groupedSampleIndices.values.map { idxs in
                    QPCRStatistics.mean(idxs.map { rawCtMat[$0][j] })
                }
                maxShift = (groupMeans.max() ?? 0.0) - (groupMeans.min() ?? 0.0)
            } else {
                maxShift = 0.0
            }
            let nfRho = normFinderMap[j]
            metrics.append(QPCRReferenceGeneMetric(
                targetKey: rk,
                target: label,
                geNormM: mVal,
                normFinderRho: nfRho,
                maxInterGroupCtShift: maxShift
            ))
            if mVal > 1.0 {
                anyUnstable = true
                warnings.append(L10n.tr(
                    "内参 \(label) 的逐步排除 geNorm M=\(String(format: "%.3f", mVal)) > 1.0，稳定性不达标。",
                    "Reference \(label) has stepwise geNorm M=\(String(format: "%.3f", mVal)) > 1.0 (unstable)."
                ))
            }
            if let rho = nfRho, rho > 0.50 {
                anyUnstable = true
                warnings.append(L10n.tr(
                    "内参 \(label) 的 NormFinder 稳定度 ρ=\(String(format: "%.3f", rho)) > 0.50，组间/组内变异过高。",
                    "Reference \(label) has NormFinder stability ρ=\(String(format: "%.3f", rho)) > 0.50 (excessive inter/intra-group variation)."
                ))
            }
        }

        // 双内参 (k == 2) 额外检验组间成对 ΔCt 漂移（排除均一 cDNA 上样量漂移误报）
        if nGenes == 2 && groupedSampleIndices.count >= 2 {
            let pairGroupMeans = groupedSampleIndices.values.map { idxs in
                QPCRStatistics.mean(idxs.map { ctMat[$0][0] - ctMat[$0][1] })
            }
            let pairDeltaShift = (pairGroupMeans.max() ?? 0.0) - (pairGroupMeans.min() ?? 0.0)
            if pairDeltaShift > 1.0 {
                anyUnstable = true
                warnings.append(L10n.tr(
                    "双内参组间成对 ΔCt 漂移达 \(String(format: "%.2f", pairDeltaShift)) (>1.0)，至少一个内参受实验处理调控。",
                    "Pairwise reference ΔCt shifts by \(String(format: "%.2f", pairDeltaShift)) (>1.0) across groups; at least one reference is regulated."
                ))
            }
        }

        // 若所有内参均通过相对稳定性检验但存在 >1.0 Ct 的同步组间漂移，仅给出上样量提示，不判为不合规
        let maxObservedShift = metrics.map(\.maxInterGroupCtShift).max() ?? 0.0
        if !anyUnstable && maxObservedShift > 1.0 {
            warnings.append(L10n.tr(
                "提示：各稳定内参在组间存在约 \(String(format: "%.2f", maxObservedShift)) Ct 同步漂移（可能为 cDNA 上样量差异），归一化已自动校正。",
                "Advisory: Stable reference genes shifted uniformly by ~\(String(format: "%.2f", maxObservedShift)) Ct across groups (likely cDNA loading difference), which normalization corrects."
            ))
        }

        if let bestV = pairwiseVars.map(\.value).min(), bestV > 0.15 {
            warnings.append(L10n.tr(
                "最小成对变异度 V=\(String(format: "%.3f", bestV)) > 0.15，建议增加更多稳定内参。",
                "Minimum pairwise variation V=\(String(format: "%.3f", bestV)) > 0.15; consider adding more stable reference genes."
            ))
        }

        metrics.sort { $0.geNormM < $1.geNormM }
        return QPCRReferenceStabilityReport(
            genes: metrics,
            stepwiseExclusionOrder: exclusionOrder,
            pairwiseVariations: pairwiseVars,
            bestReferencePair: bestPairLabels,
            isStable: !anyUnstable,
            warnings: warnings
        )
    }
    
    // MARK: - 4. CSV / TSV / 原厂导出表 / RDML 解析、微孔板联动与结果导出
    
    public static func parseQPCRTable(_ rawText: String) -> [QPCRWellRecord] {
        return QPCRInstrumentAndRDMLEngine.parseRawExport(rawText).wells
    }
    
    /// 将微孔板设计器的孔位分配一键合并或生成 qPCR 数据表（保留既有靶基因关联并同步样品/对照/空白类型）
    public static func mergeWithPlateAssignments(
        existingWells: [QPCRWellRecord],
        assignments: [String: PlateWellAssignment],
        defaultTargets: [String] = ["GAPDH", "TP53"]
    ) -> [QPCRWellRecord] {
        func mappedWellType(_ pType: StoredWellType, fallback: QPCRWellType) -> QPCRWellType {
            switch pType {
            case .blank:    return .ntc
            case .control:  return .sample
            case .sample:   return .sample
            case .reserved: return fallback
            }
        }
        if !existingWells.isEmpty {
            let upperMap = Dictionary(assignments.map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            return existingWells.map { w in
                var copy = w
                if let assigned = upperMap[w.well.uppercased()], assigned.type != .reserved {
                    if w.wellType == .noRT || w.wellType == .standard {
                        if assigned.type == .blank {
                            copy.wellType = .ntc
                        }
                    } else {
                        copy.wellType = mappedWellType(assigned.type, fallback: w.wellType)
                    }
                    if !assigned.sampleName.isEmpty {
                        copy.sample = assigned.sampleName
                    } else if assigned.type == .blank && copy.sample.isEmpty {
                        copy.sample = "NTC"
                    }
                    if !assigned.group.isEmpty {
                        copy.group = assigned.group
                    } else if assigned.type == .control && copy.group.isEmpty {
                        copy.group = "Control"
                    }
                    if assigned.replicate > 0 { copy.replicate = assigned.replicate }
                    // 严格保留既有 target，避免覆盖已导入的靶基因关联
                }
                return copy
            }
        }
        let safeTargets = defaultTargets.isEmpty ? ["GAPDH", "TP53"] : defaultTargets
        let activeAssignments = assignments.values
            .filter { $0.type != .reserved }
            .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        var generated: [QPCRWellRecord] = []
        for (idx, a) in activeAssignments.enumerated() {
            let target = safeTargets[idx % safeTargets.count]
            let wType = mappedWellType(a.type, fallback: .sample)
            let sampleLabel = !a.sampleName.isEmpty ? a.sampleName : (a.type == .blank ? "NTC" : "Control_\(a.well)")
            let groupLabel = !a.group.isEmpty ? a.group : (a.type == .control ? "Control" : (a.type == .blank ? "NTC" : ""))
            let baseCt: Double? = (wType == .ntc) ? nil : ((target == safeTargets.first) ? 18.5 : 22.0)
            generated.append(
                QPCRWellRecord(
                    id: "plate_\(a.well)",
                    row: idx,
                    well: a.well,
                    sample: sampleLabel,
                    target: target,
                    group: groupLabel,
                    wellType: wType,
                    replicate: a.replicate > 0 ? a.replicate : nil,
                    ct: baseCt.map { $0 + Double(max(0, a.replicate)) * 0.08 }
                )
            )
        }
        return generated
    }
    
    public static func exportDdctResultsCSV(_ analysis: QPCRDdctAnalysisOut) -> String {
        var groupLookup: [String: QPCRGroupSummary] = [:]
        for g in analysis.groupResults {
            groupLookup["\(g.category)|\(g.targetKey)"] = g
        }
        var lines = ["Group,Sample,Target,N_Biological,N_Technical_Wells,Stat_Note,P_Value,P_Adjusted,Fold_CI95_Low,Fold_CI95_High,Mean_Ct,SD_Ct,Ref_Ct,Delta_Ct,DeltaDelta_Ct,Fold_Change,Fold_SD,Fold_SEM,Is_Control"]
        for r in analysis.sampleResults {
            let grp = groupLookup["\(r.category)|\(r.targetKey)"]
            let nBio = grp?.nBiological ?? 1
            let nTech = r.n
            let statNote = grp?.statNote.rawValue ?? QPCRStatNote.ok.rawValue
            let pStr = grp?.pValue.map { String(format: "%.6f", $0) } ?? ""
            let pAdjStr = grp?.pAdjusted.map { String(format: "%.6f", $0) } ?? ""
            let ciLoStr = grp?.foldCI95Low.map { String(format: "%.4f", $0) } ?? ""
            let ciHiStr = grp?.foldCI95High.map { String(format: "%.4f", $0) } ?? ""
            let sdCt = r.sdCt.map { String(format: "%.4f", $0) } ?? ""
            let fSd = r.foldSd.map { String(format: "%.4f", $0) } ?? ""
            let fSem = r.foldSem.map { String(format: "%.4f", $0) } ?? ""
            lines.append(
                "\(r.category),\(r.sample),\(r.target),\(nBio),\(nTech),\(statNote),\(pStr),\(pAdjStr),\(ciLoStr),\(ciHiStr),\(String(format: "%.3f", r.meanCt)),\(sdCt),\(String(format: "%.3f", r.refCt)),\(String(format: "%.4f", r.dCt)),\(String(format: "%.4f", r.ddCt)),\(String(format: "%.4f", r.fold)),\(fSd),\(fSem),\(r.isControl)"
            )
        }
        return lines.joined(separator: "\n")
    }
    
    /// 构建 qPCR ΔΔCt 定量分析的 AnalysisRun 机器可读溯源记录 (P10 / P15)
    public static func buildQPCRAnalysisRun(
        rawCSVText: String,
        sourceFileURL: URL? = nil,
        wells: [QPCRWellRecord],
        settings: QPCRSettings,
        qc: [String: QPCRWellQCResult],
        analysis: QPCRDdctAnalysisOut,
        manualEdits: [AnalysisRun.ManualEdit] = [],
        outputs: [String] = [],
        exportDirectoryURL: URL? = nil,
        linkedPlasmidIDs: [String] = []
    ) -> AnalysisRun {
        var inputs: [AnalysisRun.InputFile] = []
        if let srcURL = sourceFileURL,
           let fileRec = AnalysisRun.makeInputFile(at: srcURL, relativeTo: exportDirectoryURL) {
            inputs.append(fileRec)
        } else {
            let rawBytes = Data(rawCSVText.utf8)
            inputs.append(
                AnalysisRun.InputFile(
                    path: "inline_qpcr_table.csv",
                    sha256: AnalysisRun.sha256Hex(ofData: rawBytes),
                    byteSize: Int64(rawBytes.count)
                )
            )
        }
        
        let paramsDict: [String: AnyCodableValue] = [
            "referenceTargets": .array(settings.referenceTargets.map { .string($0) }),
            "activeReferences": .array(analysis.references.map { .string($0) }),
            "controlGroup": .string(settings.controlGroup),
            "controlSample": .string(settings.controlSample),
            "resolvedControlLabel": .string(analysis.controlLabel),
            "multipleComparison": .string(settings.multipleComparison.rawValue),
            "highCtThreshold": .double(settings.highCtThreshold),
            "ntcCtThreshold": .double(settings.ntcCtThreshold),
            "noRTDeltaCtThreshold": .double(settings.noRTDeltaCtThreshold),
            "meltTolerance": .double(settings.meltTolerance),
            "sdLimit": .double(settings.sdLimit),
            "outlierLimit": .double(settings.outlierLimit),
            "excludeOutliers": .bool(settings.excludeOutliers),
            "efficiencyCorrection": .bool(settings.efficiencyCorrection),
            "defaultEfficiencyPct": .double(settings.defaultEfficiencyPct),
            "quantityIsLog10": .bool(settings.quantityIsLog10)
        ]
        
        var exclusions: [AnalysisRun.Exclusion] = []
        for w in wells {
            let itemID = "\(w.well) (\(w.sample)/\(w.target))"
            if !w.include {
                exclusions.append(AnalysisRun.Exclusion(itemID: w.id, reason: L10n.tr("用户手动取消勾选 (\(itemID))", "Manually unchecked (\(itemID))")))
            } else if w.wellType == .ntc || w.wellType == .noRT {
                exclusions.append(AnalysisRun.Exclusion(itemID: w.id, reason: L10n.tr("对照孔 (\(w.wellType.rawValue)) 不进入 ΔΔCt 计算", "Control well (\(w.wellType.rawValue)) excluded from ΔΔCt")))
            } else if let flags = qc[w.id]?.flags {
                if flags.contains(.meltOutlier) {
                    exclusions.append(AnalysisRun.Exclusion(itemID: w.id, reason: L10n.t("熔解曲线 Tm 偏离中位数超过容差 (meltOutlier)")))
                } else if flags.contains(.undetermined) {
                    exclusions.append(AnalysisRun.Exclusion(itemID: w.id, reason: L10n.t("未检出 Ct (Undetermined)")))
                } else if settings.excludeOutliers && flags.contains(.outlier) {
                    exclusions.append(AnalysisRun.Exclusion(itemID: w.id, reason: L10n.t("复孔离群值自动剔除 (outlier)")))
                }
            }
        }
        
        return AnalysisRun(
            schemaVersion: 2,
            module: NavItem.qpcrAnalysis.rawValue,
            engine: "swift-native",
            inputs: inputs,
            parameters: paramsDict,
            manualEdits: manualEdits,
            exclusions: exclusions,
            outputs: outputs,
            linkedPlasmidIDs: linkedPlasmidIDs
        )
    }
    
    /// 导出 qPCR ΔΔCt CSV 并同目录生成 <basename>.run.json 溯源伴随文件（绝不修改原始输入文件）(P10 / P15)
    @discardableResult
    public static func exportDdctResultsCSVWithProvenance(
        _ analysis: QPCRDdctAnalysisOut,
        rawCSVText: String,
        sourceFileURL: URL? = nil,
        wells: [QPCRWellRecord],
        settings: QPCRSettings,
        qc: [String: QPCRWellQCResult],
        linkedPlasmidIDs: [String] = [],
        to outputCSVURL: URL
    ) throws -> (csvURL: URL, sidecarURL: URL, run: AnalysisRun) {
        let csvText = exportDdctResultsCSV(analysis)
        try csvText.write(to: outputCSVURL, atomically: true, encoding: .utf8)
        let run = buildQPCRAnalysisRun(
            rawCSVText: rawCSVText,
            sourceFileURL: sourceFileURL,
            wells: wells,
            settings: settings,
            qc: qc,
            analysis: analysis,
            outputs: [outputCSVURL.lastPathComponent],
            exportDirectoryURL: outputCSVURL.deletingLastPathComponent(),
            linkedPlasmidIDs: linkedPlasmidIDs
        )
        let sidecarURL = try run.writeSidecarJSON(alongsideOutputURL: outputCSVURL)
        return (outputCSVURL, sidecarURL, run)
    }
    
    /// 内置完整实验示范 CSV（包含 WT-Ctrl、TP53-OE、TP53-KO 三个分组在 GAPDH 与 TP53、MYC 上的真实感复孔 Ct 与梯度标准品）
    public static let defaultExampleCSV: String = """
    well,sample,group,target,replicate,ct,quantity
    A1,WT-Ctrl,ControlGroup,GAPDH,1,18.42,
    A2,WT-Ctrl,ControlGroup,GAPDH,2,18.48,
    A3,WT-Ctrl,ControlGroup,GAPDH,3,18.39,
    A4,WT-Ctrl,ControlGroup,TP53,1,23.15,
    A5,WT-Ctrl,ControlGroup,TP53,2,23.22,
    A6,WT-Ctrl,ControlGroup,TP53,3,23.11,
    A7,WT-Ctrl,ControlGroup,MYC,1,22.40,
    A8,WT-Ctrl,ControlGroup,MYC,2,22.46,
    A9,WT-Ctrl,ControlGroup,MYC,3,22.34,
    B1,TP53-OE,Overexpression,GAPDH,1,18.50,
    B2,TP53-OE,Overexpression,GAPDH,2,18.44,
    B3,TP53-OE,Overexpression,GAPDH,3,18.47,
    B4,TP53-OE,Overexpression,TP53,1,21.02,
    B5,TP53-OE,Overexpression,TP53,2,21.11,
    B6,TP53-OE,Overexpression,TP53,3,20.96,
    B7,TP53-OE,Overexpression,MYC,1,21.58,
    B8,TP53-OE,Overexpression,MYC,2,21.65,
    B9,TP53-OE,Overexpression,MYC,3,21.52,
    C1,TP53-KO,Knockout,GAPDH,1,18.38,
    C2,TP53-KO,Knockout,GAPDH,2,18.45,
    C3,TP53-KO,Knockout,GAPDH,3,18.41,
    C4,TP53-KO,Knockout,TP53,1,25.84,
    C5,TP53-KO,Knockout,TP53,2,25.92,
    C6,TP53-KO,Knockout,TP53,3,25.76,
    C7,TP53-KO,Knockout,MYC,1,23.62,
    C8,TP53-KO,Knockout,MYC,2,23.70,
    C9,TP53-KO,Knockout,MYC,3,23.55,
    H1,STD-1,Standard,TP53,1,16.20,1000000
    H2,STD-2,Standard,TP53,1,19.52,100000
    H3,STD-3,Standard,TP53,1,22.86,10000
    H4,STD-4,Standard,TP53,1,26.18,1000
    H5,STD-5,Standard,TP53,1,29.50,100
    """
}
