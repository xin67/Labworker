import Foundation

/// RNA 干扰 (RNAi) shRNA 发夹结构引物设计引擎 (适配经典慢病毒骨架 pLKO.1)
public struct ShRNADesigner {
    
    public struct PairResult {
        public let fwdPrimer: PrimerItem
        public let revPrimer: PrimerItem
    }
    
    /// pLKO.1 经典接头与发夹元件
    public static let ageIOverhang = "CCGG"         // 5' AgeI 黏性末端
    public static let defaultLoop = "CTCGAG"         // XhoI 经典 6nt loop
    public static let polIIITerminator = "TTTTTT"    // T6 转录终止信号
    public static let ecoRIPrecursor = "G"           // 衔接 EcoRI
    public static let ecoRIOverhang = "AATTCAAAAAAA" // 5' EcoRI 黏性末端 + A7 互补
    
    /// 生成配对 shRNA 发夹引物
    /// - Parameters:
    ///   - target: 19~21bp 靶向 Sense 序列
    ///   - geneName: 基因名称
    ///   - index: 编号 (1, 2, 3...)
    ///   - prefix: 自定义命名前缀
    ///   - species: 物种 (人源/鼠源)
    ///   - loop: 发夹环序列 (默认 CTCGAG)
    public static func designPair(
        target: String,
        geneName: String,
        index: Int,
        prefix: String = "",
        species: TargetSpecies = .human,
        loop: String = defaultLoop
    ) -> PairResult {
        let cleanSense = BioSequence.clean(target)
        let shortGene = geneName.components(separatedBy: CharacterSet(charactersIn: " -_")).first ?? geneName
        let baseName = prefix.trimmingCharacters(in: .whitespaces).isEmpty ? shortGene : prefix.trimmingCharacters(in: .whitespaces)
        
        let fwdName = "\(baseName)_sh\(index)-F"
        let revName = "\(baseName)_sh\(index)-R"
        
        let antisense = BioSequence.reverseComplement(cleanSense)
        let cleanLoop = BioSequence.clean(loop)
        
        // Fwd: CCGG + Sense + Loop + Antisense + TTTTTTG
        let fwdFull = ageIOverhang + cleanSense + cleanLoop + antisense + polIIITerminator + ecoRIPrecursor
        // Rev: AATTCAAAAAAA + Sense + Loop + Antisense
        let revFull = ecoRIOverhang + cleanSense + cleanLoop + antisense
        
        let fwdTm = TmCalculator.calculate(sequence: fwdFull).tm
        let revTm = TmCalculator.calculate(sequence: revFull).tm
        
        let fwdItem = PrimerItem(
            name: fwdName,
            fullSequence: fwdFull,
            homologyArm: ageIOverhang.lowercased(),
            specificSequence: cleanSense + cleanLoop + antisense,
            tm: fwdTm,
            targetPurpose: "[\(species.shortName) shRNA] 正向发夹链 (Top)",
            notes: "[\(species.shortName)] 靶基因: \(geneName) | 载体: pLKO.1 (AgeI/EcoRI) | 发夹环: \(cleanLoop)",
            sourceTool: "shRNA设计"
        )
        
        let revItem = PrimerItem(
            name: revName,
            fullSequence: revFull,
            homologyArm: ecoRIOverhang.lowercased(),
            specificSequence: cleanSense + cleanLoop + antisense,
            tm: revTm,
            targetPurpose: "[\(species.shortName) shRNA] 反向发夹链 (Bottom)",
            notes: "[\(species.shortName)] 靶基因: \(geneName) | 载体: pLKO.1 (AgeI/EcoRI) | 发夹环: \(cleanLoop)",
            sourceTool: "shRNA设计"
        )
        
        return PairResult(fwdPrimer: fwdItem, revPrimer: revItem)
    }
}
