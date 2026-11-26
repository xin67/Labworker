import Foundation

/// CRISPR/Cas9 sgRNA 寡核苷酸设计引擎 (适配 lentiCRISPR v2, px459, px458 等骨架)
public struct CRISPRDesigner {
    
    public enum VectorOverhang: String, CaseIterable, Identifiable {
        case lentiCRISPRv2 = "lentiCRISPR v2 (BsmBI)"
        case px459_px458 = "pSpCas9 / px459 (BbsI)"
        case custom = "自定义悬垂末端"
        
        public var id: String { rawValue }
        
        /// 基础 4-nt 黏性末端前缀；完整 U6 +1G 条件悬垂请调用 `resolvedOverhangs(forSpacer:)`
        public var fwdPrefix: String { "CACC" }
        
        public var revPrefix: String { "AAAC" }
        
        public var revSuffix: String { "" }
        
        /// 遵循 Ran et al. (Nat. Protoc. 2013) 与 Sanjana et al. (Nat. Methods 2014) hU6 启动子规范：
        /// 当 spacer 首位已为 G 时使用 4-nt CACC/AAAC（避免多插一个 G）；首位非 G 时追加 5' G / 互补 3' C (CACCG/C)。
        public func resolvedOverhangs(forSpacer spacer: String) -> (fwdPrefix: String, revPrefix: String, revSuffix: String, addedU6G: Bool) {
            let clean = BioSequence.clean(spacer)
            let needsExtraG = (clean.first != "G")
            return (needsExtraG ? "CACCG" : "CACC", "AAAC", needsExtraG ? "C" : "", needsExtraG)
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
    ///   - customFwdPrefix: 可选自定义正向 5' 悬垂（仅 `vector == .custom` 时生效）
    ///   - customRevPrefix: 可选自定义反向 5' 悬垂（仅 `vector == .custom` 时生效）
    ///   - customRevSuffix: 可选自定义反向 3' 补足碱基（仅 `vector == .custom` 时生效）
    public static func designPair(
        target: String,
        geneName: String,
        index: Int,
        prefix: String = "",
        species: TargetSpecies = .human,
        vector: VectorOverhang = .lentiCRISPRv2,
        customFwdPrefix: String? = nil,
        customRevPrefix: String? = nil,
        customRevSuffix: String? = nil
    ) -> PairResult {
        let cleanSeq = BioSequence.clean(target)
        let shortGene = geneName.components(separatedBy: CharacterSet(charactersIn: " -_")).first ?? geneName
        let baseName = prefix.trimmingCharacters(in: .whitespaces).isEmpty ? shortGene : prefix.trimmingCharacters(in: .whitespaces)
        
        let fwdName = "\(baseName)_sg\(index)-FWD"
        let revName = "\(baseName)_sg\(index)-REV"
        
        let revComp = BioSequence.reverseComplement(cleanSeq)
        let resolved: (fwdPrefix: String, revPrefix: String, revSuffix: String, addedU6G: Bool)
        if vector == .custom,
           let cFwd = customFwdPrefix, !cFwd.trimmingCharacters(in: .whitespaces).isEmpty,
           let cRev = customRevPrefix, !cRev.trimmingCharacters(in: .whitespaces).isEmpty {
            let cSuf = (customRevSuffix ?? "").uppercased()
            resolved = (cFwd.uppercased(), cRev.uppercased(), cSuf, cFwd.uppercased().hasSuffix("G") && cleanSeq.first != "G")
        } else {
            resolved = vector.resolvedOverhangs(forSpacer: cleanSeq)
        }
        
        let fwdFull = resolved.fwdPrefix + cleanSeq
        let revFull = resolved.revPrefix + revComp + resolved.revSuffix
        
        let fwdTm = TmCalculator.calculate(sequence: fwdFull).tm
        let revTm = TmCalculator.calculate(sequence: revFull).tm
        let u6TagZh = resolved.addedU6G ? "含额外U6 +1G" : "Spacer首位已含G"
        let u6TagEn = resolved.addedU6G ? "added U6 +1G" : "native 5'-G spacer"
        
        let fwdItem = PrimerItem(
            name: fwdName,
            fullSequence: fwdFull,
            homologyArm: resolved.fwdPrefix.lowercased(),
            specificSequence: cleanSeq,
            tm: fwdTm,
            targetPurpose: L10n.tr("[\(species.shortName) sgRNA] 正向退火引物 (Top)", "[\(species.shortName) sgRNA] Forward Annealing Oligo (Top)"),
            notes: L10n.tr("[\(species.shortName)] 靶基因: \(geneName) | 载体: \(vector.rawValue) | 5'加 \(resolved.fwdPrefix) (\(u6TagZh))", "[\(species.shortName)] Target: \(geneName) | Vector: \(vector.rawValue) | 5'+\(resolved.fwdPrefix) (\(u6TagEn))"),
            sourceTool: L10n.t("sgRNA设计")
        )
        
        let revItem = PrimerItem(
            name: revName,
            fullSequence: revFull,
            homologyArm: resolved.revPrefix.lowercased(),
            specificSequence: revComp,
            tm: revTm,
            targetPurpose: L10n.tr("[\(species.shortName) sgRNA] 反向退火引物 (Bottom)", "[\(species.shortName) sgRNA] Reverse Annealing Oligo (Bottom)"),
            notes: L10n.tr("[\(species.shortName)] 靶基因: \(geneName) | 载体: \(vector.rawValue) | 5'加 \(resolved.revPrefix) 3'加 \(resolved.revSuffix.isEmpty ? "无" : resolved.revSuffix)", "[\(species.shortName)] Target: \(geneName) | Vector: \(vector.rawValue) | 5'+\(resolved.revPrefix) 3'+\(resolved.revSuffix.isEmpty ? "none" : resolved.revSuffix)"),
            sourceTool: L10n.t("sgRNA设计")
        )
        
        return PairResult(fwdPrimer: fwdItem, revPrimer: revItem)
    }
}
