import Foundation

/// Broad GPP Public Portal TRC shRNA 候选克隆数据模型
public struct BroadGPPShRNATarget: Identifiable, Hashable, Codable, Sendable {
    public var id: String { primaryCloneID }
    public var rank: Int
    public var primaryCloneID: String
    public var allCloneIDs: [String]
    public var legacyCloneName: String
    public var targetSequence: String
    public var vectors: [String]
    public var matchingTranscripts: [String]
    public var matchRegions: String
    public var matchPercent: Int
    public var sdrMatchPercent: Int
    public var intrinsicScore: Double?
    public var adjustedScore: Double?
    public var matchesOtherGene: Bool
    public var origTargetGeneSymbol: String
    public var forwardOligo: String
    public var reverseOligo: String
    public var addgeneID: String?
    public var isNearMatch: Bool
    
    public let localScore: TargetScore
    public let combinedScore: TargetScore
    
    enum CodingKeys: String, CodingKey {
        case rank, primaryCloneID, allCloneIDs, legacyCloneName, targetSequence
        case vectors, matchingTranscripts, matchRegions, matchPercent, sdrMatchPercent
        case intrinsicScore, adjustedScore, matchesOtherGene, origTargetGeneSymbol
        case forwardOligo, reverseOligo, addgeneID, isNearMatch
    }
    
    public init(
        rank: Int,
        primaryCloneID: String,
        allCloneIDs: [String]? = nil,
        legacyCloneName: String = "",
        targetSequence: String,
        vectors: [String] = ["pLKO.1"],
        matchingTranscripts: [String] = [],
        matchRegions: String = "CDS",
        matchPercent: Int = 100,
        sdrMatchPercent: Int = 100,
        intrinsicScore: Double? = nil,
        adjustedScore: Double? = nil,
        matchesOtherGene: Bool = false,
        origTargetGeneSymbol: String = "",
        forwardOligo: String = "",
        reverseOligo: String = "",
        addgeneID: String? = nil,
        isNearMatch: Bool = false
    ) {
        let cleanSeq = BioSequence.clean(targetSequence).uppercased()
        let resolvedIDs = (allCloneIDs?.isEmpty == false) ? allCloneIDs! : [primaryCloneID]
        let resolvedVectors = vectors.isEmpty ? ["pLKO.1"] : vectors
        
        self.rank = rank
        self.primaryCloneID = primaryCloneID
        self.allCloneIDs = resolvedIDs
        self.legacyCloneName = legacyCloneName
        self.targetSequence = cleanSeq
        self.vectors = resolvedVectors
        self.matchingTranscripts = matchingTranscripts
        self.matchRegions = matchRegions
        self.matchPercent = matchPercent
        self.sdrMatchPercent = sdrMatchPercent
        self.intrinsicScore = intrinsicScore
        self.adjustedScore = adjustedScore
        self.matchesOtherGene = matchesOtherGene
        self.origTargetGeneSymbol = origTargetGeneSymbol
        self.forwardOligo = forwardOligo
        self.reverseOligo = reverseOligo
        self.addgeneID = addgeneID
        self.isNearMatch = isNearMatch
        
        let loc = ShRNAScoringEngine.evaluate(sequence: cleanSeq)
        self.localScore = loc
        self.combinedScore = Self.computeCombinedScore(
            sdrMatchPercent: sdrMatchPercent,
            matchPercent: matchPercent,
            intrinsicScore: intrinsicScore,
            adjustedScore: adjustedScore,
            matchesOtherGene: matchesOtherGene,
            matchRegions: matchRegions,
            localScore: loc
        )
    }
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let primaryCloneID = try c.decode(String.self, forKey: .primaryCloneID)
        let targetSequence = try c.decode(String.self, forKey: .targetSequence)
        self.init(
            rank: try c.decodeIfPresent(Int.self, forKey: .rank) ?? 1,
            primaryCloneID: primaryCloneID,
            allCloneIDs: try c.decodeIfPresent([String].self, forKey: .allCloneIDs),
            legacyCloneName: try c.decodeIfPresent(String.self, forKey: .legacyCloneName) ?? "",
            targetSequence: targetSequence,
            vectors: try c.decodeIfPresent([String].self, forKey: .vectors) ?? ["pLKO.1"],
            matchingTranscripts: try c.decodeIfPresent([String].self, forKey: .matchingTranscripts) ?? [],
            matchRegions: try c.decodeIfPresent(String.self, forKey: .matchRegions) ?? "CDS",
            matchPercent: try c.decodeIfPresent(Int.self, forKey: .matchPercent) ?? 100,
            sdrMatchPercent: try c.decodeIfPresent(Int.self, forKey: .sdrMatchPercent) ?? 100,
            intrinsicScore: try c.decodeIfPresent(Double.self, forKey: .intrinsicScore),
            adjustedScore: try c.decodeIfPresent(Double.self, forKey: .adjustedScore),
            matchesOtherGene: try c.decodeIfPresent(Bool.self, forKey: .matchesOtherGene) ?? false,
            origTargetGeneSymbol: try c.decodeIfPresent(String.self, forKey: .origTargetGeneSymbol) ?? "",
            forwardOligo: try c.decodeIfPresent(String.self, forKey: .forwardOligo) ?? "",
            reverseOligo: try c.decodeIfPresent(String.self, forKey: .reverseOligo) ?? "",
            addgeneID: try c.decodeIfPresent(String.self, forKey: .addgeneID),
            isNearMatch: try c.decodeIfPresent(Bool.self, forKey: .isNearMatch) ?? false
        )
    }
    
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rank, forKey: .rank)
        try c.encode(primaryCloneID, forKey: .primaryCloneID)
        try c.encode(allCloneIDs, forKey: .allCloneIDs)
        try c.encode(legacyCloneName, forKey: .legacyCloneName)
        try c.encode(targetSequence, forKey: .targetSequence)
        try c.encode(vectors, forKey: .vectors)
        try c.encode(matchingTranscripts, forKey: .matchingTranscripts)
        try c.encode(matchRegions, forKey: .matchRegions)
        try c.encode(matchPercent, forKey: .matchPercent)
        try c.encode(sdrMatchPercent, forKey: .sdrMatchPercent)
        try c.encodeIfPresent(intrinsicScore, forKey: .intrinsicScore)
        try c.encodeIfPresent(adjustedScore, forKey: .adjustedScore)
        try c.encode(matchesOtherGene, forKey: .matchesOtherGene)
        try c.encode(origTargetGeneSymbol, forKey: .origTargetGeneSymbol)
        try c.encode(forwardOligo, forKey: .forwardOligo)
        try c.encode(reverseOligo, forKey: .reverseOligo)
        try c.encodeIfPresent(addgeneID, forKey: .addgeneID)
        try c.encode(isNearMatch, forKey: .isNearMatch)
    }
    
    public func rankedCopy(rank newRank: Int) -> BroadGPPShRNATarget {
        BroadGPPShRNATarget(
            rank: newRank,
            primaryCloneID: primaryCloneID,
            allCloneIDs: allCloneIDs,
            legacyCloneName: legacyCloneName,
            targetSequence: targetSequence,
            vectors: vectors,
            matchingTranscripts: matchingTranscripts,
            matchRegions: matchRegions,
            matchPercent: matchPercent,
            sdrMatchPercent: sdrMatchPercent,
            intrinsicScore: intrinsicScore,
            adjustedScore: adjustedScore,
            matchesOtherGene: matchesOtherGene,
            origTargetGeneSymbol: origTargetGeneSymbol,
            forwardOligo: forwardOligo,
            reverseOligo: reverseOligo,
            addgeneID: addgeneID,
            isNearMatch: isNearMatch
        )
    }
    
    public var gcContent: Double {
        BioSequence.gcContent(targetSequence)
    }
    
    public var transcriptCount: Int {
        matchingTranscripts.count
    }
    
    public var isCDS: Bool {
        matchRegions.uppercased().contains("CDS")
    }
    
    public var is3UTR: Bool {
        matchRegions.uppercased().contains("3UTR")
    }
    
    public var isHighlySpecific: Bool {
        !matchesOtherGene && sdrMatchPercent >= 100
    }
    
    public var cloneWebURL: URL? {
        URL(string: "https://portals.broadinstitute.org/gpp/public/clone/details?cloneId=\(primaryCloneID)")
    }
    
    /// 检测当前 Broad GPP shRNA 靶点是否与本地已选/文库 shRNA 序列重合
    public func matchAgainstLocalTargets(_ localTargets: [LocalCompareTarget]) -> CHOPCHOPLocalMatchResult? {
        CHOPCHOPLocalMatchResult.bestMatch(
            primarySequence: targetSequence,
            fullSequence: targetSequence,
            localTargets: localTargets
        )
    }
    
    private static func computeCombinedScore(
        sdrMatchPercent: Int,
        matchPercent: Int,
        intrinsicScore: Double?,
        adjustedScore: Double?,
        matchesOtherGene: Bool,
        matchRegions: String,
        localScore: TargetScore
    ) -> TargetScore {
        var tags: [ScoreTag] = []
        
        // 1. 全基因组特异性与 SDR 匹配度 (满分 45 分)
        var specPts = 45.0
        if matchesOtherGene {
            specPts -= 24.0
        }
        if sdrMatchPercent < 100 {
            specPts -= Double(max(0, 100 - sdrMatchPercent)) * 1.2
        } else if matchPercent < 100 {
            specPts -= Double(max(0, 100 - matchPercent)) * 0.5
        }
        specPts = max(0.0, min(45.0, specPts))
        let specInt = Int(round(specPts))
        tags.append(ScoreTag(
            name: matchesOtherGene ? L10n.t("匹配同物种其他基因 (存在脱靶风险)") : L10n.tr("单基因特异 (SDR \(sdrMatchPercent)%)", "Gene-Specific (SDR \(sdrMatchPercent)%)"),
            points: specInt,
            type: matchesOtherGene ? .penalty : .bonus
        ))
        
        // 2. Broad GPP Knockdown 综合效价 (满分 35 分)
        let adj = adjustedScore ?? intrinsicScore ?? 2.0
        let intr = intrinsicScore ?? adj
        let blended = max(0.0, 0.7 * adj + 0.3 * intr)
        var broadPts = min(33.0, (blended / (blended + 1.8)) * 42.0)
        if matchRegions.uppercased().contains("CDS") {
            broadPts += 2.0
        }
        broadPts = max(0.0, min(35.0, broadPts))
        let broadInt = Int(round(broadPts))
        tags.append(ScoreTag(
            name: "Broad Adjusted (\(String(format: "%.2f", adj)))",
            points: broadInt,
            type: adj >= 2.5 ? .bonus : .penalty
        ))
        
        // 3. 本地热力学与 pLKO.1 Pol III 转录规则 (满分 20 分)
        let seqPts = max(0.0, min(20.0, (localScore.score / 100.0) * 20.0))
        let seqInt = Int(round(seqPts))
        tags.append(ScoreTag(
            name: L10n.t("热力学与 Pol III 规则"),
            points: seqInt,
            type: localScore.hasFatalIssue ? .fatal : (localScore.score >= 65.0 ? .bonus : .penalty)
        ))
        
        var total = round(specPts + broadPts + seqPts)
        let fatalMsg = localScore.fatalWarning
        if localScore.hasFatalIssue {
            total = min(total, 35.0)
        }
        total = max(0.0, min(100.0, total))
        
        let tier: TargetScoreTier
        if fatalMsg != nil || total < 45 {
            tier = .poor
        } else if total >= 80 {
            tier = .excellent
        } else if total >= 65 {
            tier = .good
        } else {
            tier = .fair
        }
        
        let summary = L10n.tr("综合评分 \(Int(total)) 分 = 特异性 \(specInt)/45 + Broad效价 \(broadInt)/35 + 序列规则 \(seqInt)/20", "Composite Score \(Int(total)) = Specificity \(specInt)/45 + Broad Efficacy \(broadInt)/35 + Sequence Rules \(seqInt)/20")
        return TargetScore(
            score: total,
            tier: tier,
            gcPercent: localScore.gcPercent,
            summary: summary,
            tags: tags,
            fatalWarning: fatalMsg
        )
    }
}

/// Broad GPP Public Portal 查询结果包
public struct BroadGPPFetchResult: Codable, Sendable {
    public let geneID: String
    public let geneSymbol: String
    public let geneDescription: String
    public let wtTranscriptCount: Int
    public let targets: [BroadGPPShRNATarget]
    public let isNearMatchFallback: Bool
    
    public init(
        geneID: String,
        geneSymbol: String,
        geneDescription: String,
        wtTranscriptCount: Int,
        targets: [BroadGPPShRNATarget],
        isNearMatchFallback: Bool
    ) {
        self.geneID = geneID
        self.geneSymbol = geneSymbol
        self.geneDescription = geneDescription
        self.wtTranscriptCount = wtTranscriptCount
        self.targets = targets
        self.isNearMatchFallback = isNearMatchFallback
    }
}
