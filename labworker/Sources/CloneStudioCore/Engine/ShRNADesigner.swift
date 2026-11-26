import Foundation

/// RNA 干扰 (RNAi) shRNA 发夹结构引物设计引擎 (适配经典慢病毒骨架 pLKO.1)
public struct ShRNADesigner {
    
    public struct PairResult {
        public let fwdPrimer: PrimerItem
        public let revPrimer: PrimerItem
    }
    
    /// pLKO.1 经典接头与发夹元件 (Moffat et al., Cell 2006 / Addgene TRC Protocol: 6T/6A 等长配对)
    public static let ageIOverhang = "CCGG"         // 5' AgeI 黏性末端
    public static let defaultLoop = "CTCGAG"        // XhoI 经典 6nt loop
    public static let polIIITerminator = "TTTTTT"   // T6 转录终止信号
    public static let ecoRIPrecursor = "G"          // 衔接 EcoRI (3'-G 配合载体 5'-AATTC 恢复位点)
    public static let ecoRIOverhang = "AATTCAAAAAA" // 5' EcoRI 黏性末端 AATT + C + A6 (与 TTTTTTG 等长反向互补)
    
    /// 生成配对 shRNA 发夹引物
    /// - Parameters:
    ///   - target: 19~21bp 靶向 Sense 序列
    ///   - geneName: 基因名称
    ///   - index: 编号 (1, 2, 3...)
    ///   - prefix: 自定义命名前缀
    ///   - species: 物种 (人源/鼠源)
    ///   - loop: 发夹环序列 (默认 CTCGAG；非回文环如 TTCAAGAGA 在反向链取反向互补)
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
        let revLoop = BioSequence.reverseComplement(cleanLoop)
        
        // Fwd (Top 5'->3'): CCGG + Sense + Loop + Antisense + TTTTTTG
        let fwdFull = ageIOverhang + cleanSense + cleanLoop + antisense + polIIITerminator + ecoRIPrecursor
        // Rev (Bottom 5'->3'): AATTCAAAAAA + Sense + RC(Loop) + Antisense
        let revCore = cleanSense + revLoop + antisense
        let revFull = ecoRIOverhang + revCore
        
        let fwdTm = TmCalculator.calculate(sequence: fwdFull).tm
        let revTm = TmCalculator.calculate(sequence: revFull).tm
        
        let fwdItem = PrimerItem(
            name: fwdName,
            fullSequence: fwdFull,
            homologyArm: ageIOverhang.lowercased(),
            specificSequence: cleanSense + cleanLoop + antisense,
            tm: fwdTm,
            targetPurpose: L10n.tr("[\(species.shortName) shRNA] 正向发夹链 (Top)", "[\(species.shortName) shRNA] Sense Hairpin Oligo (Top)"),
            notes: L10n.tr("[\(species.shortName)] 靶基因: \(geneName) | 载体: pLKO.1 (AgeI/EcoRI) | 发夹环: \(cleanLoop)", "[\(species.shortName)] Target: \(geneName) | Vector: pLKO.1 (AgeI/EcoRI) | Loop: \(cleanLoop)"),
            sourceTool: L10n.t("shRNA设计")
        )
        
        let revItem = PrimerItem(
            name: revName,
            fullSequence: revFull,
            homologyArm: ecoRIOverhang.lowercased(),
            specificSequence: revCore,
            tm: revTm,
            targetPurpose: L10n.tr("[\(species.shortName) shRNA] 反向发夹链 (Bottom)", "[\(species.shortName) shRNA] Antisense Hairpin Oligo (Bottom)"),
            notes: L10n.tr("[\(species.shortName)] 靶基因: \(geneName) | 载体: pLKO.1 (AgeI/EcoRI) | 发夹环: \(cleanLoop)", "[\(species.shortName)] Target: \(geneName) | Vector: pLKO.1 (AgeI/EcoRI) | Loop: \(cleanLoop)"),
            sourceTool: L10n.t("shRNA设计")
        )
        
        return PairResult(fwdPrimer: fwdItem, revPrimer: revItem)
    }
}
