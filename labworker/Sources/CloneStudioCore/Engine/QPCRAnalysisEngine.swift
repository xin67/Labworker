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
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .none: return "不校正 (Raw p)"
        case .holm: return "Holm–Bonferroni"
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
        case .holm: return pAdjusted ?? pValue
        case .none: return pValue
        }
    }
    
    public var significanceLabel: String {
        if isControl { return "Ref" }
        guard let p = effectivePValueForSignificance, statNote == .ok else { return "n<2，未检验" }
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
    public let intercept: Double?
    public let r2: Double?
    public let efficiencyPct: Double?
    public let n: Int
    public let xMin: Double?
    public let xMax: Double?
    public let valid: Bool
    public let points: [(x: Double, y: Double)]
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
}

public struct QPCRStandardAnalysisOut: Sendable {
    public let fits: [QPCRStandardCurveFit]
    public let samples: [QPCRStandardSampleResult]
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
    
    /// 由标准曲线斜率计算扩增效率 E = 10^(-1/slope) - 1
    public static func efficiencyFromSlope(_ slope: Double) -> Double {
        guard slope.isFinite && slope != 0.0 else { return .nan }
        return pow(10.0, -1.0 / slope) - 1.0
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
            if w.wellType == .sample && !tKey.isEmpty {
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
                guard let ct = w.ct else { return nil }
                return (w.id, ct)
            }
            let cts = measured.map(\.ct)
            repStats[gKey] = (cts.count, cts.isEmpty ? nil : QPCRStatistics.mean(cts), QPCRStatistics.sampleSd(cts))
            
            if measured.count >= 3 {
                let center = QPCRStatistics.mean(cts)
                let candidates = measured.filter { abs($0.ct - center) > settings.outlierLimit }
                if !candidates.isEmpty {
                    if candidates.count == measured.count {
                        if let farthest = candidates.max(by: { abs($0.ct - center) < abs($1.ct - center) }) {
                            outlierWellIDs.insert(farthest.id)
                        }
                    } else {
                        for c in candidates { outlierWellIDs.insert(c.id) }
                    }
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
        
        // 计算每个样品的内参几何平均 Ct
        var refCtBySample: [String: Double] = [:]
        for sk in orderedSampleKeys {
            let bucket = buckets[sk]!
            var refMeans: [Double] = []
            for rk in activeRefKeys {
                let cts = (bucket.refWells[rk] ?? []).compactMap(\.ct)
                if !cts.isEmpty {
                    refMeans.append(QPCRStatistics.mean(cts))
                }
            }
            if let gm = QPCRStatistics.geometricMean(refMeans) {
                refCtBySample[sk] = gm
            }
        }
        
        let nonRefTargetKeys = sortedTargets.map(normKey).filter { !activeRefKeySet.contains($0) }
        
        // 计算对照组在各目的基因上的平均 ΔCt
        var controlMeanDCt: [String: Double] = [:]
        for tk in nonRefTargetKeys {
            var vals: [Double] = []
            for ck in controlSampleKeys {
                guard let bucket = buckets[ck],
                      let refCt = refCtBySample[ck],
                      let tws = bucket.targetWells[tk],
                      !tws.isEmpty else { continue }
                let cts = tws.compactMap(\.ct)
                if !cts.isEmpty {
                    vals.append(QPCRStatistics.mean(cts) - refCt)
                }
            }
            if !vals.isEmpty {
                controlMeanDCt[tk] = QPCRStatistics.mean(vals)
            }
        }
        
        var sampleResults: [QPCRSampleResult] = []
        var heatmapCells: [QPCRHeatmapCell] = []
        
        for sk in orderedSampleKeys {
            let bucket = buckets[sk]!
            guard let refCt = refCtBySample[sk] else { continue }
            
            for tk in nonRefTargetKeys {
                let tLabel = targetMap[tk] ?? tk
                guard let tws = bucket.targetWells[tk], !tws.isEmpty,
                      let ctrlDCt = controlMeanDCt[tk] else { continue }
                let cts = tws.compactMap(\.ct)
                guard !cts.isEmpty else { continue }
                
                let meanCt = QPCRStatistics.mean(cts)
                let sdCt = QPCRStatistics.sampleSd(cts)
                let dCt = meanCt - refCt
                let ddCt = dCt - ctrlDCt
                
                let targetEffs = nonStandardWells.filter { normKey($0.target) == tk }.compactMap(\.efficiency)
                let eff = targetEffs.isEmpty ? max(0.01, settings.defaultEfficiencyPct / 100.0) : QPCRStatistics.mean(targetEffs)
                let base = settings.efficiencyCorrection ? (1.0 + eff) : 2.0
                
                let foldValues = cts.map { pow(base, -(($0 - refCt) - ctrlDCt)) }
                let fold = QPCRStatistics.mean(foldValues)
                
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
                        isControl: bucket.isControl
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
        
        // 按组汇总并计算相对对照组的 Welch's t-test p 值
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
            let targetEffs = nonStandardWells.filter { normKey($0.target) == tk }.compactMap(\.efficiency)
            let eff = targetEffs.isEmpty ? max(0.01, settings.defaultEfficiencyPct / 100.0) : QPCRStatistics.mean(targetEffs)
            let base = settings.efficiencyCorrection ? (1.0 + eff) : 2.0
            
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
                        ciRes = QPCRStatistics.welchCI95(allDCts, ctrlSampleDCts, base: base)
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
            
            for (idx, item) in pending.enumerated() {
                let pAdj: Double? = item.isCtrl ? nil : (settings.multipleComparison == .holm ? holmPsForTarget[idx] : item.pVal)
                groupResults.append(
                    QPCRGroupSummary(
                        category: item.cat,
                        categoryKey: normKey(item.cat),
                        target: tLabel,
                        targetKey: tk,
                        nBiological: item.nBio,
                        nTechnicalWells: item.nTech,
                        meanFold: QPCRStatistics.mean(item.sampleFolds),
                        sdFold: QPCRStatistics.sampleSd(item.sampleFolds),
                        semFold: QPCRStatistics.sem(item.sampleFolds),
                        meanDCt: QPCRStatistics.mean(item.allDCts),
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
        
        return QPCRDdctAnalysisOut(
            references: activeRefLabels,
            targets: sortedTargets,
            samples: sortedSamples,
            groups: sortedGroups,
            controlLabel: controlLabel,
            contaminatedTargets: contaminatedTargets,
            sampleResults: sampleResults,
            groupResults: groupResults,
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
            if let reg = QPCRStatistics.linearRegression(pts) {
                let eff = QPCRStatistics.efficiencyFromSlope(reg.slope) * 100.0
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
                    points: pts
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
            return QPCRStandardSampleResult(
                sample: b.sample,
                sampleKey: b.sampleKey,
                target: b.target,
                targetKey: b.targetKey,
                group: b.group,
                category: b.category,
                n: b.cts.count,
                meanCt: QPCRStatistics.mean(b.cts),
                log10Quantity: meanLog,
                quantity: pow(10.0, meanLog),
                sdLog: QPCRStatistics.sampleSd(b.logQtys),
                semLog: QPCRStatistics.sem(b.logQtys)
            )
        }.sorted { ($0.category, $0.sample, $0.target) < ($1.category, $1.sample, $1.target) }
        
        return QPCRStandardAnalysisOut(fits: fits, samples: outSamples)
    }
    
    // MARK: - 4. CSV / TSV / 原厂导出表 / RDML 解析、微孔板联动与结果导出
    
    public static func parseQPCRTable(_ rawText: String) -> [QPCRWellRecord] {
        return QPCRInstrumentAndRDMLEngine.parseRawExport(rawText).wells
    }
    
    /// 将微孔板设计器的孔位分配一键合并或生成 qPCR 数据表
    public static func mergeWithPlateAssignments(
        existingWells: [QPCRWellRecord],
        assignments: [String: PlateWellAssignment],
        defaultTargets: [String] = ["GAPDH", "TP53"]
    ) -> [QPCRWellRecord] {
        if !existingWells.isEmpty {
            return existingWells.map { w in
                var copy = w
                if let assigned = assignments[w.well.uppercased()], assigned.type == .sample {
                    if !assigned.sampleName.isEmpty { copy.sample = assigned.sampleName }
                    if !assigned.group.isEmpty { copy.group = assigned.group }
                    if assigned.replicate > 0 { copy.replicate = assigned.replicate }
                }
                return copy
            }
        }
        // 若当前无孔位数据，则根据微孔板样品孔自动创建包含内参与目的基因的模拟示范模板
        let sampleAssignments = assignments.values
            .filter { $0.type == .sample && !$0.sampleName.isEmpty }
            .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        var generated: [QPCRWellRecord] = []
        for (idx, a) in sampleAssignments.enumerated() {
            let target = defaultTargets[idx % max(1, defaultTargets.count)]
            let baseCt: Double = (target == defaultTargets.first) ? 18.5 : 22.0
            generated.append(
                QPCRWellRecord(
                    id: "plate_\(a.well)",
                    row: idx,
                    well: a.well,
                    sample: a.sampleName,
                    target: target,
                    group: a.group,
                    replicate: a.replicate,
                    ct: baseCt + Double(a.replicate) * 0.08
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
                exclusions.append(AnalysisRun.Exclusion(itemID: w.id, reason: "用户手动取消勾选 (\(itemID))"))
            } else if w.wellType == .ntc || w.wellType == .noRT {
                exclusions.append(AnalysisRun.Exclusion(itemID: w.id, reason: "对照孔 (\(w.wellType.rawValue)) 不进入 ΔΔCt 计算"))
            } else if let flags = qc[w.id]?.flags {
                if flags.contains(.meltOutlier) {
                    exclusions.append(AnalysisRun.Exclusion(itemID: w.id, reason: "熔解曲线 Tm 偏离中位数超过容差 (meltOutlier)"))
                } else if flags.contains(.undetermined) {
                    exclusions.append(AnalysisRun.Exclusion(itemID: w.id, reason: "未检出 Ct (Undetermined)"))
                } else if settings.excludeOutliers && flags.contains(.outlier) {
                    exclusions.append(AnalysisRun.Exclusion(itemID: w.id, reason: "复孔离群值自动剔除 (outlier)"))
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
