import Foundation

/// CRISPR/Cas9 sgRNA 寡核苷酸设计引擎 (适配 lentiCRISPR v2, px459, px458 等骨架)
public struct CRISPRDesigner {
    
    public enum VectorOverhang: String, CaseIterable, Identifiable {
        case lentiCRISPRv2 = "lentiCRISPR v2 (BsmBI)"
        case px459_px458 = "pSpCas9 / px459 (BbsI)"
        case custom = "自定义悬垂末端"
        
        public var id: String { rawValue }
        
        public var fwdPrefix: String {
            switch self {
            case .lentiCRISPRv2: return "CACCG"
            case .px459_px458:   return "CACC"
            case .custom:        return "CACCG"
            }
        }
        
        public var revPrefix: String {
            switch self {
            case .lentiCRISPRv2: return "AAAC"
            case .px459_px458:   return "AAAC"
            case .custom:        return "AAAC"
            }
        }
        
        public var revSuffix: String {
            switch self {
            case .lentiCRISPRv2: return "C"
            case .px459_px458:   return ""
            case .custom:        return "C"
            }
        }
    }
    
    public struct PairResult {
        public let fwdPrimer: PrimerItem
        public let revPrimer: PrimerItem
    }
    
    /// 生成配对 sgRNA 引物
    /// - Parameters:
    ///   - target: 20bp 靶点序列
    ///   - geneName: 基因名称
    ///   - index: 编号 (1, 2, 3...)
    ///   - prefix: 自定义命名前缀
    ///   - species: 物种 (人源/鼠源)
    ///   - vector: 载体骨架悬垂预设
    public static func designPair(
        target: String,
        geneName: String,
        index: Int,
        prefix: String = "",
        species: TargetSpecies = .human,
        vector: VectorOverhang = .lentiCRISPRv2
    ) -> PairResult {
        let cleanSeq = BioSequence.clean(target)
        let shortGene = geneName.components(separatedBy: CharacterSet(charactersIn: " -_")).first ?? geneName
        let baseName = prefix.trimmingCharacters(in: .whitespaces).isEmpty ? shortGene : prefix.trimmingCharacters(in: .whitespaces)
        
        let fwdName = "\(baseName)_sg\(index)-FWD"
        let revName = "\(baseName)_sg\(index)-REV"
        
        let revComp = BioSequence.reverseComplement(cleanSeq)
        
        let fwdFull = vector.fwdPrefix + cleanSeq
        let revFull = vector.revPrefix + revComp + vector.revSuffix
        
        let fwdTm = TmCalculator.calculate(sequence: fwdFull).tm
        let revTm = TmCalculator.calculate(sequence: revFull).tm
        
        let fwdItem = PrimerItem(
            name: fwdName,
            fullSequence: fwdFull,
            homologyArm: vector.fwdPrefix.lowercased(),
            specificSequence: cleanSeq,
            tm: fwdTm,
            targetPurpose: "[\(species.shortName) sgRNA] 正向退火引物 (Top)",
            notes: "[\(species.shortName)] 靶基因: \(geneName) | 载体: \(vector.rawValue) | 5'加 \(vector.fwdPrefix)",
            sourceTool: "sgRNA设计"
        )
        
        let revItem = PrimerItem(
            name: revName,
            fullSequence: revFull,
            homologyArm: vector.revPrefix.lowercased(),
            specificSequence: revComp,
            tm: revTm,
            targetPurpose: "[\(species.shortName) sgRNA] 反向退火引物 (Bottom)",
            notes: "[\(species.shortName)] 靶基因: \(geneName) | 载体: \(vector.rawValue) | 5'加 \(vector.revPrefix) 3'加 \(vector.revSuffix)",
            sourceTool: "sgRNA设计"
        )
        
        return PairResult(fwdPrimer: fwdItem, revPrimer: revItem)
    }
}
