import Foundation

/// 重组反应与经典连接 DNA 使用量与移液吸取体积计算器 (支持 ClonExpress 经验公式推荐、用户自定义 ng 及 0.03 pmol 经典摩尔比互算)
public struct DNAMolarCalculator {
    
    public enum CloneType: String, CaseIterable, Identifiable {
        case simple = "SimpleClone"
        case single = "SingleClone"
        case multi = "MultiClone"
        case ligationRatio = "LigationRatio"
        
        public var id: String { rawValue }
        
        public var title: String {
            switch self {
            case .simple:        return "入门克隆 (SimpleClone)"
            case .single:        return "单片段克隆 (SingleClone)"
            case .multi:         return "多片段克隆 (MultiClone)"
            case .ligationRatio: return "经典摩尔比 (Ligation)"
            }
        }
    }

    /// 经典连接 / 同源重组载体-片段摩尔比枚举 (`1:1` ~ `1:5`)
    public enum LigationMolarRatio: Int, CaseIterable, Identifiable, Sendable {
        case r1_1 = 1
        case r1_2 = 2
        case r1_3 = 3
        case r1_4 = 4
        case r1_5 = 5

        public var id: Int { rawValue }
        public var title: String { "1:\(rawValue)" }
    }

    /// 经典摩尔比连接计算结果（对齐 `0.65 ng/(pmol·bp)` 换算系数）
    public struct LigationRatioResult: Equatable, Sendable {
        public let vectorLengthBp: Int
        public let vectorPmol: Double
        public let vectorNg: Double
        public let vectorVolUl: Double?
        public let insertLengthBp: Int
        public let molarRatio: LigationMolarRatio
        public let insertNg: Double
        public let insertVolUl: Double?
        public let lowInsertSingleWarning: Bool
        public let lowInsertMultiWarning: Bool
    }
    
    public struct CalculationResult {
        public let recommendedNg: Double
        public let actualNg: Double
        public let isCustomNg: Bool
        public let recommendedVol: Double?
        
        public let unitWarning: String?
        
        public init(
            recommendedNg: Double,
            actualNg: Double? = nil,
            isCustomNg: Bool = false,
            recommendedVol: Double?,
            unitWarning: String? = nil
        ) {
            self.recommendedNg = recommendedNg
            self.actualNg = actualNg ?? recommendedNg
            self.isCustomNg = isCustomNg
            self.recommendedVol = recommendedVol
            self.unitWarning = unitWarning
        }
        
        public var volFormatted: String {
            guard let v = recommendedVol, v > 0 else { return "--" }
            return String(format: "%.2f", v)
        }
        
        public var actualNgFormatted: String {
            if abs(actualNg.rounded() - actualNg) < 0.05 {
                return "\(Int(actualNg.rounded()))"
            }
            return String(format: "%.1f", actualNg)
        }
        
        public var recommendedNgFormatted: String {
            "\(Int(recommendedNg.rounded()))"
        }
    }
    
    /// dsDNA 平均碱基对摩尔质量口径（明确区分 650 Da/bp 无水均重 vs 660 Da/bp 水合二钠盐均重）
    public enum DSDNAMolarMassConvention: Double, CaseIterable, Sendable {
        /// 无水均重 (650 Da/bp，NEBioCalculator / 无缝克隆连接配比标准)
        case anhydrous650 = 650.0
        /// 水合二钠盐均重 (660 Da/bp，常规 dsDNA 质量–摩尔换算标准)
        case hydrated660 = 660.0

        public var daPerBp: Double { rawValue }
        public var label: String {
            switch self {
            case .anhydrous650: return "650 Da/bp (Anhydrous)"
            case .hydrated660:  return "660 Da/bp (Hydrated Na2-salt)"
            }
        }
    }

    /// 显式 bp → kb 换算辅助函数（不再在 calculate 中静默猜改用户输入单位）
    public static func normalizeLengthToKb(_ rawValue: Double) -> Double {
        guard rawValue > 0 else { return 0 }
        return rawValue >= 40.0 ? (rawValue / 1000.0) : rawValue
    }
    
    /// 计算最适 DNA 用量 (ng) 与移液体积 (μL)
    /// - Parameters:
    ///   - cloneType: 克隆模式 (SimpleClone / SingleClone / MultiClone / LigationRatio)
    ///   - isVector: 是否为载体 (若是 false，则为插入片段)
    ///   - lengthKb: 片段长度 (显式单位 kb；若 >= 40 kb 将发出显式单位复核提示，不再静默除以 1000)
    ///   - concentrationNgPerUl: 浓度 (ng/μL)，可选
    ///   - customNg: 用户自定义的投入量 (ng)，若为 nil 或 <= 0 则使用标准推荐量
    ///   - molarMass: dsDNA 平均碱基对摩尔质量口径（默认 650 Da/bp）
    public static func calculate(
        cloneType: CloneType,
        isVector: Bool,
        lengthKb rawLength: Double,
        concentrationNgPerUl: Double? = nil,
        customNg: Double? = nil,
        molarMass: DSDNAMolarMassConvention = .anhydrous650
    ) -> CalculationResult {
        let lengthKb = rawLength
        guard lengthKb > 0 else {
            return CalculationResult(recommendedNg: 0, actualNg: 0, isCustomNg: false, recommendedVol: nil)
        }
        let unitWarn: String? = (rawLength >= 40.0)
            ? L10n.tr("输入长度为 \(rawLength) kb（≥40 kb，常见于 BAC/超大质粒）；若实际单位为 bp，请手动除以 1000 后输入 kb。", "Input length is \(rawLength) kb (>=40 kb); if this value is in bp, divide by 1000 and enter kb explicitly.")
            : nil
        
        var recNg: Double = 0.0
        
        switch cloneType {
        case .simple:
            recNg = min(200.0, max(20.0, 40.0 * lengthKb))
            
        case .single:
            if isVector {
                // 消除原 2.0 kb 处 50 ng -> 40.02 ng 的不连续阶跃：采用平滑单调下限 max(50.0, 20.0 * lengthKb)
                recNg = min(200.0, max(50.0, 20.0 * lengthKb))
            } else {
                recNg = min(200.0, max(20.0, 40.0 * lengthKb))
            }
            
        case .multi:
            if isVector {
                recNg = min(200.0, max(50.0, 20.0 * lengthKb))
            } else {
                if lengthKb <= 0.5 {
                    recNg = 10.0
                } else {
                    ngMultiInsert(&recNg, lengthKb: lengthKb)
                }
            }

        case .ligationRatio:
            recNg = 0.03 * (lengthKb * 1000.0) * (molarMass.daPerBp / 1000.0)
        }
        
        let useCustom = (customNg != nil && customNg! > 0)
        let effectiveNg = useCustom ? customNg! : recNg
        
        var vol: Double? = nil
        if let conc = concentrationNgPerUl, conc > 0 {
            vol = effectiveNg / conc
        }
        
        return CalculationResult(
            recommendedNg: recNg,
            actualNg: effectiveNg,
            isCustomNg: useCustom,
            recommendedVol: vol,
            unitWarning: unitWarn
        )
    }

    /// 经典连接 / 同源重组载体-片段摩尔比使用量计算器（对齐 `0.65 pg/(fmol·bp)` 即 `0.65 ng/(pmol·bp)`）
    public static func calculateLigationByMolarRatio(
        vectorLengthBp: Int,
        vectorConcNgPerUl: Double? = nil,
        vectorPmol: Double = 0.03,
        insertLengthBp: Int,
        insertConcNgPerUl: Double? = nil,
        molarRatio: LigationMolarRatio = .r1_3
    ) -> LigationRatioResult? {
        guard vectorLengthBp > 0, vectorPmol > 0, insertLengthBp > 0 else { return nil }
        let vecNg = vectorPmol * Double(vectorLengthBp) * 0.65
        let vecVol = (vectorConcNgPerUl ?? 0) > 0 ? (vecNg / vectorConcNgPerUl!) : nil
        let insNg = vectorPmol * Double(molarRatio.rawValue) * Double(insertLengthBp) * 0.65
        let insVol = (insertConcNgPerUl ?? 0) > 0 ? (insNg / insertConcNgPerUl!) : nil
        return LigationRatioResult(
            vectorLengthBp: vectorLengthBp,
            vectorPmol: vectorPmol,
            vectorNg: vecNg,
            vectorVolUl: vecVol,
            insertLengthBp: insertLengthBp,
            molarRatio: molarRatio,
            insertNg: insNg,
            insertVolUl: insVol,
            lowInsertSingleWarning: insNg < 20.0,
            lowInsertMultiWarning: insNg < 10.0
        )
    }
    
    private static func ngMultiInsert(_ outNg: inout Double, lengthKb: Double) {
        outNg = min(100.0, 20.0 * lengthKb)
    }
}
