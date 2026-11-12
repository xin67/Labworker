import Foundation

/// 重组反应 DNA 使用量与移液吸取体积计算器 (支持公式推荐 ng 与用户自定义 ng 实时联动计算)
public struct DNAMolarCalculator {
    
    public enum CloneType: String, CaseIterable, Identifiable {
        case simple = "SimpleClone"
        case single = "SingleClone"
        case multi = "MultiClone"
        
        public var id: String { rawValue }
        
        public var title: String {
            switch self {
            case .simple: return "入门克隆 (SimpleClone)"
            case .single: return "单片段克隆 (SingleClone)"
            case .multi:  return "多片段克隆 (MultiClone)"
            }
        }
    }
    
    public struct CalculationResult {
        public let recommendedNg: Double
        public let actualNg: Double
        public let isCustomNg: Bool
        public let recommendedVol: Double?
        
        public init(
            recommendedNg: Double,
            actualNg: Double? = nil,
            isCustomNg: Bool = false,
            recommendedVol: Double?
        ) {
            self.recommendedNg = recommendedNg
            self.actualNg = actualNg ?? recommendedNg
            self.isCustomNg = isCustomNg
            self.recommendedVol = recommendedVol
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
    
    /// 智能将用户输入的数值解析为 kb（若输入值 >= 40，如 5340，则自动按 bp 换算为 5.34 kb）
    public static func normalizeLengthToKb(_ rawValue: Double) -> Double {
        guard rawValue > 0 else { return 0 }
        return rawValue >= 40.0 ? (rawValue / 1000.0) : rawValue
    }
    
    /// 计算最适 DNA 用量 (ng) 与移液体积 (μL)
    /// - Parameters:
    ///   - cloneType: 克隆模式 (SimpleClone / SingleClone / MultiClone)
    ///   - isVector: 是否为载体 (若是 false，则为插入片段)
    ///   - lengthKb: 片段长度 (kb，若传入 >= 40 自动识别为 bp 并折算为 kb)
    ///   - concentrationNgPerUl: 浓度 (ng/μL)，可选
    ///   - customNg: 用户自定义的投入量 (ng)，若为 nil 或 <= 0 则使用标准推荐量
    public static func calculate(
        cloneType: CloneType,
        isVector: Bool,
        lengthKb rawLength: Double,
        concentrationNgPerUl: Double? = nil,
        customNg: Double? = nil
    ) -> CalculationResult {
        let lengthKb = normalizeLengthToKb(rawLength)
        guard lengthKb > 0 else {
            return CalculationResult(recommendedNg: 0, actualNg: 0, isCustomNg: false, recommendedVol: nil)
        }
        
        var recNg: Double = 0.0
        
        switch cloneType {
        case .simple:
            if lengthKb <= 0.5 {
                recNg = 20.0
            } else {
                recNg = min(200.0, 40.0 * lengthKb)
            }
            
        case .single:
            if isVector {
                if lengthKb <= 2.0 {
                    recNg = 50.0
                } else {
                    recNg = min(200.0, 20.0 * lengthKb)
                }
            } else {
                if lengthKb <= 0.5 {
                    recNg = 20.0
                } else {
                    recNg = min(200.0, 40.0 * lengthKb)
                }
            }
            
        case .multi:
            if isVector {
                if lengthKb <= 2.0 {
                    recNg = 50.0
                } else {
                    recNg = min(200.0, 20.0 * lengthKb)
                }
            } else {
                if lengthKb <= 0.5 {
                    recNg = 10.0
                } else {
                    ngMultiInsert(&recNg, lengthKb: lengthKb)
                }
            }
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
            recommendedVol: vol
        )
    }
    
    private static func ngMultiInsert(_ outNg: inout Double, lengthKb: Double) {
        outNg = min(100.0, 20.0 * lengthKb)
    }
}
