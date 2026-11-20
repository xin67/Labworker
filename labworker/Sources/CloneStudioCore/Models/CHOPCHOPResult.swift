import Foundation
import SwiftUI

/// 在线靶点比对数据源
public enum TargetCompareSource: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case vbcScore = "VBC-Score"
    case ucscCrispor = "CRISPOR"
    case chopchop = "CHOPCHOP"
    
    public var id: String { rawValue }
    
    public var shortTitle: String {
        switch self {
        case .vbcScore:    return "VBC"
        case .ucscCrispor: return "CRISPOR"
        case .chopchop:    return "CHOP"
        }
    }
    
    public var icon: String {
        switch self {
        case .vbcScore:    return "bolt.shield.fill"
        case .ucscCrispor: return "waveform.path.ecg"
        case .chopchop:    return "globe"
        }
    }
    
    public var subtitle: String {
        switch self {
        case .vbcScore:    return "LOF / inDelphi / Bioscore"
        case .ucscCrispor: return "UCSC MIT / Doench / CRISPRscan"
        case .chopchop:    return "Bowtie MM0-3 / Doench"
        }
    }
}

/// 本地 sgRNA / shRNA / 自定义序列对比项（用于在在线检索结果中进行自动高亮对比）
public struct LocalCompareTarget: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(sourceType.rawValue)_\(cleanSequence)" }
    public var label: String                  // 例如: "本地已选 sg#1" / "本地已选 sh#2" / "本地文库 sgRNA"
    public var sequence: String               // 原始靶点序列 (20bp sgRNA 或 19~21bp shRNA)
    public var cleanSequence: String          // 大写清洗后序列
    public var sourceType: SourceType         // sgRNA / shRNA / custom
    public var isSelectedOrGenerated: Bool    // true = 用户已勾选或已生成引物的重点序列；false = 同基因本地文库候选
    
    public enum SourceType: String, Codable, Sendable {
        case sgRNA = "sgRNA"
        case shRNA = "shRNA"
        case custom = "自定义"
    }
    
    public init(
        label: String,
        sequence: String,
        sourceType: SourceType,
        isSelectedOrGenerated: Bool = true
    ) {
        self.label = label
        self.sequence = sequence
        self.cleanSequence = BioSequence.clean(sequence).uppercased()
        self.sourceType = sourceType
        self.isSelectedOrGenerated = isSelectedOrGenerated
    }
}

/// 本地靶点与 CHOPCHOP 在线靶点的匹配类型
public enum CHOPCHOPLocalMatchKind: Hashable, Sendable {
    case exact                           // 20bp 完全一致
    case coreOverlap(Int)                // 同链核心区连续重合 (如 21bp shRNA 与 20bp sgRNA 重合 18~20bp)
    case reverseComplementOverlap(Int)   // 反义互补链同位点重合 (>= 18bp)
    
    public var priority: Int {
        switch self {
        case .exact: return 3
        case .coreOverlap(let len): return 2 * 100 + len
        case .reverseComplementOverlap(let len): return 1 * 100 + len
        }
    }
}

/// 本地靶点与 CHOPCHOP 靶点的匹配结果详情
public struct CHOPCHOPLocalMatchResult: Hashable, Sendable {
    public let matchedTarget: LocalCompareTarget
    public let kind: CHOPCHOPLocalMatchKind
    
    public var isPrimaryUserSelection: Bool {
        matchedTarget.isSelectedOrGenerated
    }
    
    public var badgeText: String {
        let prefix = matchedTarget.isSelectedOrGenerated ? "★ \(matchedTarget.label)" : "📚 本地文库 \(matchedTarget.sourceType.rawValue)"
        switch kind {
        case .exact:
            return "\(prefix) (完全一致)"
        case .coreOverlap(let bp):
            return "\(prefix) (同链重合\(bp)bp)"
        case .reverseComplementOverlap(let bp):
            return "\(prefix) (互补链重合\(bp)bp)"
        }
    }
    
    public var detailText: String {
        switch kind {
        case .exact:
            return "与\(matchedTarget.label) [\(matchedTarget.cleanSequence)] 序列 100% 完全一致"
        case .coreOverlap(let bp):
            return "与\(matchedTarget.label) [\(matchedTarget.cleanSequence)] 在同一正/负链连续重合 \(bp) bp"
        case .reverseComplementOverlap(let bp):
            return "与\(matchedTarget.label) [\(matchedTarget.cleanSequence)] 的反向互补链在同一基因组位点连续重合 \(bp) bp"
        }
    }
    
    /// 通用本地靶点序列匹配器（供 CHOPCHOP/VBC/CRISPOR 与 Broad GPP shRNA 共用）
    public static func bestMatch(
        primarySequence: String,
        fullSequence: String? = nil,
        localTargets: [LocalCompareTarget]
    ) -> CHOPCHOPLocalMatchResult? {
        guard !localTargets.isEmpty else { return nil }
        let cleanPrimary = primarySequence.uppercased()
        let cleanFull = (fullSequence ?? primarySequence).uppercased()
        guard !cleanPrimary.isEmpty else { return nil }
        
        var bestMatch: CHOPCHOPLocalMatchResult? = nil
        
        for item in localTargets {
            let q = item.cleanSequence
            guard q.count >= 15 else { continue }
            
            var candidateKind: CHOPCHOPLocalMatchKind? = nil
            
            if cleanPrimary == q || cleanFull == q {
                candidateKind = .exact
            } else if let overlap = longestCommonSubstringLength(cleanFull, q), overlap >= 18 {
                if overlap >= min(cleanPrimary.count, q.count) {
                    candidateKind = .exact
                } else {
                    candidateKind = .coreOverlap(overlap)
                }
            } else {
                let rc = BioSequence.reverseComplement(q).uppercased()
                if let rcOverlap = longestCommonSubstringLength(cleanFull, rc), rcOverlap >= 18 {
                    candidateKind = .reverseComplementOverlap(rcOverlap)
                }
            }
            
            if let kind = candidateKind {
                let candidate = CHOPCHOPLocalMatchResult(matchedTarget: item, kind: kind)
                if let current = bestMatch {
                    if candidate.isPrimaryUserSelection && !current.isPrimaryUserSelection {
                        bestMatch = candidate
                    } else if candidate.isPrimaryUserSelection == current.isPrimaryUserSelection,
                              candidate.kind.priority > current.kind.priority {
                        bestMatch = candidate
                    }
                } else {
                    bestMatch = candidate
                }
            }
        }
        
        return bestMatch
    }
    
    /// 计算两条序列的最长连续公共子串长度
    internal static func longestCommonSubstringLength(_ a: String, _ b: String) -> Int? {
        let charsA = Array(a.utf8)
        let charsB = Array(b.utf8)
        let n = charsA.count
        let m = charsB.count
        guard n > 0 && m > 0 else { return nil }
        
        var maxLen = 0
        for i in 0..<n {
            if n - i <= maxLen { break }
            for j in 0..<m {
                if m - j <= maxLen { break }
                var k = 0
                while i + k < n && j + k < m && charsA[i + k] == charsB[j + k] {
                    k += 1
                }
                if k > maxLen {
                    maxLen = k
                }
            }
        }
        return maxLen > 0 ? maxLen : nil
    }
}

/// 多源在线预测靶点模型（整合 CHOPCHOP / VBC-Score / UCSC CRISPOR 指标与全维综合推荐分）
public struct CHOPCHOPTarget: Identifiable, Hashable, Codable, Sendable {
    public var id: Int { rank }
    public var rank: Int
    public var targetSequence: String     // 23 bp (Spacer + PAM)
    public var spacer: String             // 20 bp
    public var pam: String                // 3 bp PAM
    public var genomicLocation: String    // e.g. chr17:7675056
    public var strand: String             // + 或 -
    public var gcContent: Double          // GC 百分比
    public var selfComplementarity: Int   // 自身互补折叠分
    public var mm0: Int                   // 0 错配全基因组位点数 (除自身外)
    public var mm1: Int                   // 1 错配位点数
    public var mm2: Int                   // 2 错配位点数
    public var mm3: Int                   // 3 错配位点数
    public var efficiency: Double         // 主切割效率评分 (0..100)
    
    // 多源融合与扩展指标
    public var sources: [TargetCompareSource]
    public var chopchopRank: Int?
    public var hasCHOPCHOPOffTargets: Bool
    
    public var vbcScore: Double?
    public var vbcActivity: Double?
    public var vbcFrameshift: Double?
    public var vbcBioscore: Double?
    public var vbcAutoPick: Int?
    public var vbcVeryLikelyOT: Int?
    public var vbcLikelyOT: Int?
    public var vbcOT90: Int?
    public var vbcExon: String?
    
    public var mitSpecificity: Int?
    public var crisporDoenchPerc: Double?
    public var crisporScanScore: Double?
    public var crisporOutOfFrame: Double?
    
    // 预计算缓存（避免列表滚动时重复执行评分算法）
    public let localScore: TargetScore
    public let combinedScore: TargetScore
    
    enum CodingKeys: String, CodingKey {
        case rank, targetSequence, spacer, pam, genomicLocation, strand
        case gcContent, selfComplementarity, mm0, mm1, mm2, mm3, efficiency
        case sources, chopchopRank, hasCHOPCHOPOffTargets
        case vbcScore, vbcActivity, vbcFrameshift, vbcBioscore, vbcAutoPick
        case vbcVeryLikelyOT, vbcLikelyOT, vbcOT90, vbcExon
        case mitSpecificity, crisporDoenchPerc, crisporScanScore, crisporOutOfFrame
    }
    
    public init(
        rank: Int,
        targetSequence: String,
        spacer: String,
        pam: String,
        genomicLocation: String,
        strand: String,
        gcContent: Double,
        selfComplementarity: Int,
        mm0: Int,
        mm1: Int,
        mm2: Int,
        mm3: Int,
        efficiency: Double,
        sources: [TargetCompareSource] = [.chopchop],
        chopchopRank: Int? = nil,
        hasCHOPCHOPOffTargets: Bool = true,
        vbcScore: Double? = nil,
        vbcActivity: Double? = nil,
        vbcFrameshift: Double? = nil,
        vbcBioscore: Double? = nil,
        vbcAutoPick: Int? = nil,
        vbcVeryLikelyOT: Int? = nil,
        vbcLikelyOT: Int? = nil,
        vbcOT90: Int? = nil,
        vbcExon: String? = nil,
        mitSpecificity: Int? = nil,
        crisporDoenchPerc: Double? = nil,
        crisporScanScore: Double? = nil,
        crisporOutOfFrame: Double? = nil
    ) {
        let resolvedSources = sources.isEmpty ? [.chopchop] : sources
        let resolvedChopRank = chopchopRank ?? ((hasCHOPCHOPOffTargets && resolvedSources.contains(.chopchop)) ? rank : nil)
        
        self.rank = rank
        self.targetSequence = targetSequence
        self.spacer = spacer
        self.pam = pam
        self.genomicLocation = genomicLocation
        self.strand = strand
        self.gcContent = gcContent
        self.selfComplementarity = selfComplementarity
        self.mm0 = mm0
        self.mm1 = mm1
        self.mm2 = mm2
        self.mm3 = mm3
        self.efficiency = efficiency
        self.sources = resolvedSources
        self.chopchopRank = resolvedChopRank
        self.hasCHOPCHOPOffTargets = hasCHOPCHOPOffTargets
        self.vbcScore = vbcScore
        self.vbcActivity = vbcActivity
        self.vbcFrameshift = vbcFrameshift
        self.vbcBioscore = vbcBioscore
        self.vbcAutoPick = vbcAutoPick
        self.vbcVeryLikelyOT = vbcVeryLikelyOT
        self.vbcLikelyOT = vbcLikelyOT
        self.vbcOT90 = vbcOT90
        self.vbcExon = vbcExon
        self.mitSpecificity = mitSpecificity
        self.crisporDoenchPerc = crisporDoenchPerc
        self.crisporScanScore = crisporScanScore
        self.crisporOutOfFrame = crisporOutOfFrame
        
        let loc = SgRNAScoringEngine.evaluate(sequence: spacer)
        self.localScore = loc
        self.combinedScore = Self.computeCombinedScore(
            spacer: spacer,
            mm0: mm0,
            mm1: mm1,
            mm2: mm2,
            mm3: mm3,
            selfComp: selfComplementarity,
            efficiency: efficiency,
            localScore: loc,
            sources: resolvedSources,
            hasCHOPCHOPOffTargets: hasCHOPCHOPOffTargets,
            vbcScore: vbcScore,
            vbcActivity: vbcActivity,
            vbcVeryLikelyOT: vbcVeryLikelyOT,
            vbcLikelyOT: vbcLikelyOT,
            vbcOT90: vbcOT90,
            mitSpecificity: mitSpecificity,
            crisporDoenchPerc: crisporDoenchPerc
        )
    }
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rank = try c.decode(Int.self, forKey: .rank)
        let targetSequence = try c.decode(String.self, forKey: .targetSequence)
        let spacer = try c.decode(String.self, forKey: .spacer)
        let pam = try c.decode(String.self, forKey: .pam)
        let genomicLocation = try c.decode(String.self, forKey: .genomicLocation)
        let strand = try c.decode(String.self, forKey: .strand)
        let gcContent = try c.decode(Double.self, forKey: .gcContent)
        let selfComplementarity = try c.decode(Int.self, forKey: .selfComplementarity)
        let mm0 = try c.decode(Int.self, forKey: .mm0)
        let mm1 = try c.decode(Int.self, forKey: .mm1)
        let mm2 = try c.decode(Int.self, forKey: .mm2)
        let mm3 = try c.decode(Int.self, forKey: .mm3)
        let efficiency = try c.decode(Double.self, forKey: .efficiency)
        
        let sources = try c.decodeIfPresent([TargetCompareSource].self, forKey: .sources) ?? [.chopchop]
        let chopchopRank = try c.decodeIfPresent(Int.self, forKey: .chopchopRank)
        let hasCHOPCHOPOffTargets = try c.decodeIfPresent(Bool.self, forKey: .hasCHOPCHOPOffTargets) ?? true
        let vbcScore = try c.decodeIfPresent(Double.self, forKey: .vbcScore)
        let vbcActivity = try c.decodeIfPresent(Double.self, forKey: .vbcActivity)
        let vbcFrameshift = try c.decodeIfPresent(Double.self, forKey: .vbcFrameshift)
        let vbcBioscore = try c.decodeIfPresent(Double.self, forKey: .vbcBioscore)
        let vbcAutoPick = try c.decodeIfPresent(Int.self, forKey: .vbcAutoPick)
        let vbcVeryLikelyOT = try c.decodeIfPresent(Int.self, forKey: .vbcVeryLikelyOT)
        let vbcLikelyOT = try c.decodeIfPresent(Int.self, forKey: .vbcLikelyOT)
        let vbcOT90 = try c.decodeIfPresent(Int.self, forKey: .vbcOT90)
        let vbcExon = try c.decodeIfPresent(String.self, forKey: .vbcExon)
        let mitSpecificity = try c.decodeIfPresent(Int.self, forKey: .mitSpecificity)
        let crisporDoenchPerc = try c.decodeIfPresent(Double.self, forKey: .crisporDoenchPerc)
        let crisporScanScore = try c.decodeIfPresent(Double.self, forKey: .crisporScanScore)
        let crisporOutOfFrame = try c.decodeIfPresent(Double.self, forKey: .crisporOutOfFrame)
        
        self.init(
            rank: rank,
            targetSequence: targetSequence,
            spacer: spacer,
            pam: pam,
            genomicLocation: genomicLocation,
            strand: strand,
            gcContent: gcContent,
            selfComplementarity: selfComplementarity,
            mm0: mm0,
            mm1: mm1,
            mm2: mm2,
            mm3: mm3,
            efficiency: efficiency,
            sources: sources,
            chopchopRank: chopchopRank,
            hasCHOPCHOPOffTargets: hasCHOPCHOPOffTargets,
            vbcScore: vbcScore,
            vbcActivity: vbcActivity,
            vbcFrameshift: vbcFrameshift,
            vbcBioscore: vbcBioscore,
            vbcAutoPick: vbcAutoPick,
            vbcVeryLikelyOT: vbcVeryLikelyOT,
            vbcLikelyOT: vbcLikelyOT,
            vbcOT90: vbcOT90,
            vbcExon: vbcExon,
            mitSpecificity: mitSpecificity,
            crisporDoenchPerc: crisporDoenchPerc,
            crisporScanScore: crisporScanScore,
            crisporOutOfFrame: crisporOutOfFrame
        )
    }
    
    public var sourceCount: Int {
        max(1, sources.count)
    }
    
    public var isMultiSourceConsensus: Bool {
        sources.count >= 2
    }
    
    /// 脱靶特异性总结 (MM0/MM1/MM2/MM3)
    public var offTargetSummary: String {
        "\(mm0)/\(mm1)/\(mm2)/\(mm3)"
    }
    
    /// 核心脱靶安全评级
    public var isHighlySpecific: Bool {
        if hasCHOPCHOPOffTargets {
            return mm0 == 0 && mm1 == 0
        }
        if let vl = vbcVeryLikelyOT {
            return mm0 == 0 && vl == 0
        }
        if let mit = mitSpecificity {
            return mit >= 50
        }
        return mm0 == 0 && mm1 == 0
    }
    
    /// 全基因组零脱靶 (MM0～MM3 全为 0)
    public var isZeroOffTarget: Bool {
        mm0 == 0 && mm1 == 0 && mm2 == 0 && mm3 == 0
    }
    
    /// 计算融合了「全基因组特异性 (45%) + 在线切割/敲除效率 (35%) + 本地序列规则 (20%) + 多源共识加分」的全维综合推荐分
    private static func computeCombinedScore(
        spacer: String,
        mm0: Int,
        mm1: Int,
        mm2: Int,
        mm3: Int,
        selfComp: Int,
        efficiency: Double,
        localScore: TargetScore,
        sources: [TargetCompareSource],
        hasCHOPCHOPOffTargets: Bool,
        vbcScore: Double?,
        vbcActivity: Double?,
        vbcVeryLikelyOT: Int?,
        vbcLikelyOT: Int?,
        vbcOT90: Int?,
        mitSpecificity: Int?,
        crisporDoenchPerc: Double?
    ) -> TargetScore {
        var tags: [ScoreTag] = []
        let isPureLegacyChopchop = hasCHOPCHOPOffTargets
            && sources == [.chopchop]
            && vbcScore == nil
            && mitSpecificity == nil
        
        if isPureLegacyChopchop {
            // 1. 全基因组脱靶安全度 (满分 45 分)
            var offTargetPts = 45.0
            if mm0 > 0 {
                offTargetPts -= Double(mm0) * 35.0
            }
            if mm1 > 0 {
                offTargetPts -= Double(mm1) * 20.0
            }
            if mm2 > 0 {
                offTargetPts -= Double(mm2) * 4.5
            }
            if mm3 > 0 {
                offTargetPts -= min(12.0, Double(mm3) * 1.2)
            }
            offTargetPts = max(0.0, min(45.0, offTargetPts))
            let offInt = Int(round(offTargetPts))
            tags.append(ScoreTag(
                name: "脱靶安全 (\(mm0)/\(mm1)/\(mm2)/\(mm3))",
                points: offInt,
                type: (mm0 == 0 && mm1 == 0) ? .bonus : (mm0 > 0 ? .fatal : .penalty)
            ))
            
            // 2. CHOPCHOP Doench 2016 切割效率分 (满分 35 分)
            let effNormalized = max(0.0, min(35.0, (efficiency / 75.0) * 35.0))
            let effInt = Int(round(effNormalized))
            tags.append(ScoreTag(
                name: "Doench效率 (\(String(format: "%.1f", efficiency)))",
                points: effInt,
                type: efficiency >= 50.0 ? .bonus : .penalty
            ))
            
            // 3. 本地序列热力学与 Pol III 转录规则 (满分 20 分)
            var seqPts = (localScore.score / 100.0) * 20.0
            if selfComp > 0 {
                seqPts = max(0.0, seqPts - Double(selfComp) * 2.5)
            }
            let seqInt = Int(round(seqPts))
            tags.append(ScoreTag(
                name: "序列与转录规则",
                points: seqInt,
                type: localScore.hasFatalIssue ? .fatal : (localScore.score >= 65.0 ? .bonus : .penalty)
            ))
            
            var total = round(offTargetPts + effNormalized + seqPts)
            var fatalMsg = localScore.fatalWarning
            
            if mm0 > 0 {
                fatalMsg = "存在 \(mm0) 个全基因组 0 错配重复位点 (MM0 > 0)，严禁用于特异性敲除"
                total = min(total, 35.0)
            } else if localScore.hasFatalIssue {
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
            
            let summaryText = "全维综合评分 \(Int(total)) 分 = 脱靶安全 \(offInt)/45 + Doench效率 \(effInt)/35 + 序列规则 \(seqInt)/20"
            return TargetScore(
                score: total,
                tier: tier,
                gcPercent: localScore.gcPercent,
                summary: summaryText,
                tags: tags,
                fatalWarning: fatalMsg
            )
        }
        
        // 多源融合评分（VBC-Score / UCSC CRISPOR / CHOPCHOP）
        var offTargetPts = 45.0
        if hasCHOPCHOPOffTargets {
            var chopOff = 45.0
            if mm0 > 0 { chopOff -= Double(mm0) * 35.0 }
            if mm1 > 0 { chopOff -= Double(mm1) * 20.0 }
            if mm2 > 0 { chopOff -= Double(mm2) * 4.5 }
            if mm3 > 0 { chopOff -= min(12.0, Double(mm3) * 1.2) }
            offTargetPts = max(0.0, min(45.0, chopOff))
            tags.append(ScoreTag(
                name: "CHOP 脱靶 (\(mm0)/\(mm1)/\(mm2)/\(mm3))",
                points: Int(round(offTargetPts)),
                type: (mm0 == 0 && mm1 == 0) ? .bonus : (mm0 > 0 ? .fatal : .penalty)
            ))
        } else {
            var specSamples: [Double] = []
            if vbcScore != nil || vbcVeryLikelyOT != nil || vbcLikelyOT != nil || vbcOT90 != nil {
                var vbcSpec = 45.0
                if mm0 > 0 { vbcSpec -= Double(mm0) * 35.0 }
                vbcSpec -= Double(vbcVeryLikelyOT ?? 0) * 18.0
                vbcSpec -= Double(vbcLikelyOT ?? 0) * 5.0
                vbcSpec -= min(10.0, Double(vbcOT90 ?? 0) * 1.5)
                vbcSpec = max(0.0, min(45.0, vbcSpec))
                specSamples.append(vbcSpec)
                tags.append(ScoreTag(
                    name: "VBC 特异性 (VL:\(vbcVeryLikelyOT ?? 0)/L:\(vbcLikelyOT ?? 0))",
                    points: Int(round(vbcSpec)),
                    type: (mm0 == 0 && (vbcVeryLikelyOT ?? 0) == 0) ? .bonus : (mm0 > 0 ? .fatal : .penalty)
                ))
            }
            if let mit = mitSpecificity {
                let mitSpec = max(0.0, min(45.0, (Double(mit) / 90.0) * 45.0))
                specSamples.append(mitSpec)
                tags.append(ScoreTag(
                    name: "MIT 特异性 (\(mit))",
                    points: Int(round(mitSpec)),
                    type: mit >= 60 ? .bonus : .penalty
                ))
            }
            if !specSamples.isEmpty {
                offTargetPts = specSamples.reduce(0.0, +) / Double(specSamples.count)
            }
        }
        let offInt = Int(round(offTargetPts))
        
        var effSamples: [Double] = []
        if hasCHOPCHOPOffTargets {
            let chopEff = max(0.0, min(35.0, (efficiency / 75.0) * 35.0))
            effSamples.append(chopEff)
            tags.append(ScoreTag(
                name: "Doench效率 (\(String(format: "%.1f", efficiency)))",
                points: Int(round(chopEff)),
                type: efficiency >= 50.0 ? .bonus : .penalty
            ))
        }
        if let vbc = vbcScore {
            let vbcEff = max(0.0, min(35.0, (0.65 * vbc + 0.35 * (vbcActivity ?? vbc)) * 35.0))
            effSamples.append(vbcEff)
            tags.append(ScoreTag(
                name: "VBC 敲除分 (\(String(format: "%.2f", vbc)))",
                points: Int(round(vbcEff)),
                type: vbc >= 0.60 ? .bonus : .penalty
            ))
        }
        if mitSpecificity != nil || crisporDoenchPerc != nil {
            let pct = crisporDoenchPerc ?? efficiency
            let crisEff = max(0.0, min(35.0, (pct / 100.0) * 35.0))
            effSamples.append(crisEff)
            tags.append(ScoreTag(
                name: "CRISPOR 效率 (\(String(format: "%.0f%%", pct)))",
                points: Int(round(crisEff)),
                type: pct >= 55.0 ? .bonus : .penalty
            ))
        }
        let effNormalized = effSamples.isEmpty
            ? max(0.0, min(35.0, (efficiency / 75.0) * 35.0))
            : (effSamples.reduce(0.0, +) / Double(effSamples.count))
        let effInt = Int(round(effNormalized))
        
        var seqPts = (localScore.score / 100.0) * 20.0
        if selfComp > 0 {
            seqPts = max(0.0, seqPts - Double(selfComp) * 2.5)
        }
        let seqInt = Int(round(seqPts))
        tags.append(ScoreTag(
            name: "序列与转录规则",
            points: seqInt,
            type: localScore.hasFatalIssue ? .fatal : (localScore.score >= 65.0 ? .bonus : .penalty)
        ))
        
        let consensusBonus: Double = sources.count >= 3 ? 5.0 : (sources.count == 2 ? 3.0 : 0.0)
        if consensusBonus > 0 {
            tags.append(ScoreTag(
                name: "多源共识 (\(sources.count) 站命中)",
                points: Int(consensusBonus),
                type: .bonus
            ))
        }
        
        var total = round(offTargetPts + effNormalized + seqPts + consensusBonus)
        var fatalMsg = localScore.fatalWarning
        
        if mm0 > 0 {
            fatalMsg = "存在 \(mm0) 个全基因组 0 错配重复位点 (MM0 > 0)，严禁用于特异性敲除"
            total = min(total, 35.0)
        } else if localScore.hasFatalIssue {
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
        
        let srcDesc = sources.map(\.shortTitle).joined(separator: "+")
        let bonusDesc = consensusBonus > 0 ? " + 共识 +\(Int(consensusBonus))" : ""
        let summaryText = "[\(srcDesc)] 全维综合评分 \(Int(total)) 分 = 特异性 \(offInt)/45 + 效率 \(effInt)/35 + 序列规则 \(seqInt)/20\(bonusDesc)"
        return TargetScore(
            score: total,
            tier: tier,
            gcPercent: localScore.gcPercent,
            summary: summaryText,
            tags: tags,
            fatalWarning: fatalMsg
        )
    }
    
    /// 按 20bp Spacer 合并多源预测靶点（CHOPCHOP + VBC-Score + UCSC CRISPOR），生成共识条目并重新编号
    public static func mergeTargets(
        chopchop: [CHOPCHOPTarget],
        vbc: [CHOPCHOPTarget],
        crispor: [CHOPCHOPTarget]
    ) -> [CHOPCHOPTarget] {
        var chopBySpacer: [String: CHOPCHOPTarget] = [:]
        for item in chopchop {
            let key = item.spacer.uppercased()
            if chopBySpacer[key] == nil {
                chopBySpacer[key] = item
            }
        }
        
        var vbcBySpacer: [String: CHOPCHOPTarget] = [:]
        for item in vbc {
            let key = item.spacer.uppercased()
            if vbcBySpacer[key] == nil {
                vbcBySpacer[key] = item
            }
        }
        
        var crisporBySpacer: [String: CHOPCHOPTarget] = [:]
        for item in crispor {
            let key = item.spacer.uppercased()
            if crisporBySpacer[key] == nil {
                crisporBySpacer[key] = item
            }
        }
        
        let allKeys = Set(chopBySpacer.keys)
            .union(vbcBySpacer.keys)
            .union(crisporBySpacer.keys)
        
        var merged: [CHOPCHOPTarget] = []
        merged.reserveCapacity(allKeys.count)
        
        for key in allKeys {
            let chop = chopBySpacer[key]
            let vbcItem = vbcBySpacer[key]
            let cris = crisporBySpacer[key]
            
            var activeSources: [TargetCompareSource] = []
            if vbcItem != nil { activeSources.append(.vbcScore) }
            if cris != nil { activeSources.append(.ucscCrispor) }
            if chop != nil { activeSources.append(.chopchop) }
            guard !activeSources.isEmpty else { continue }
            
            let primary = chop ?? cris ?? vbcItem!
            let pam = [chop?.pam, cris?.pam, vbcItem?.pam]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? primary.pam
            let targetSeq = [chop?.targetSequence, cris?.targetSequence, vbcItem?.targetSequence]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? (key + pam)
            let location = [chop?.genomicLocation, cris?.genomicLocation, vbcItem?.genomicLocation]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? ""
            let strand = [chop?.strand, cris?.strand, vbcItem?.strand]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? "+"
            let gc = chop?.gcContent ?? cris?.gcContent ?? vbcItem?.gcContent ?? BioSequence.gcContent(key)
            
            let hasChopOff = (chop?.hasCHOPCHOPOffTargets ?? false)
            let mm0 = hasChopOff ? (chop?.mm0 ?? 0) : (vbcItem?.mm0 ?? 0)
            let mm1 = hasChopOff ? (chop?.mm1 ?? 0) : 0
            let mm2 = hasChopOff ? (chop?.mm2 ?? 0) : 0
            let mm3 = hasChopOff ? (chop?.mm3 ?? 0) : 0
            let eff = chop?.efficiency ?? cris?.efficiency ?? vbcItem?.efficiency ?? 0.0
            
            let combined = CHOPCHOPTarget(
                rank: 1,
                targetSequence: targetSeq,
                spacer: key,
                pam: pam,
                genomicLocation: location,
                strand: strand,
                gcContent: gc,
                selfComplementarity: chop?.selfComplementarity ?? 0,
                mm0: mm0,
                mm1: mm1,
                mm2: mm2,
                mm3: mm3,
                efficiency: eff,
                sources: activeSources,
                chopchopRank: chop?.chopchopRank ?? chop?.rank,
                hasCHOPCHOPOffTargets: hasChopOff,
                vbcScore: vbcItem?.vbcScore,
                vbcActivity: vbcItem?.vbcActivity,
                vbcFrameshift: vbcItem?.vbcFrameshift,
                vbcBioscore: vbcItem?.vbcBioscore,
                vbcAutoPick: vbcItem?.vbcAutoPick,
                vbcVeryLikelyOT: vbcItem?.vbcVeryLikelyOT,
                vbcLikelyOT: vbcItem?.vbcLikelyOT,
                vbcOT90: vbcItem?.vbcOT90,
                vbcExon: vbcItem?.vbcExon,
                mitSpecificity: cris?.mitSpecificity,
                crisporDoenchPerc: cris?.crisporDoenchPerc,
                crisporScanScore: cris?.crisporScanScore,
                crisporOutOfFrame: cris?.crisporOutOfFrame
            )
            merged.append(combined)
        }
        
        merged.sort { a, b in
            if a.combinedScore.score != b.combinedScore.score {
                return a.combinedScore.score > b.combinedScore.score
            }
            if a.sources.count != b.sources.count {
                return a.sources.count > b.sources.count
            }
            if a.efficiency != b.efficiency {
                return a.efficiency > b.efficiency
            }
            return a.targetSequence < b.targetSequence
        }
        
        return merged.enumerated().map { idx, t in
            CHOPCHOPTarget(
                rank: idx + 1,
                targetSequence: t.targetSequence,
                spacer: t.spacer,
                pam: t.pam,
                genomicLocation: t.genomicLocation,
                strand: t.strand,
                gcContent: t.gcContent,
                selfComplementarity: t.selfComplementarity,
                mm0: t.mm0,
                mm1: t.mm1,
                mm2: t.mm2,
                mm3: t.mm3,
                efficiency: t.efficiency,
                sources: t.sources,
                chopchopRank: t.chopchopRank,
                hasCHOPCHOPOffTargets: t.hasCHOPCHOPOffTargets,
                vbcScore: t.vbcScore,
                vbcActivity: t.vbcActivity,
                vbcFrameshift: t.vbcFrameshift,
                vbcBioscore: t.vbcBioscore,
                vbcAutoPick: t.vbcAutoPick,
                vbcVeryLikelyOT: t.vbcVeryLikelyOT,
                vbcLikelyOT: t.vbcLikelyOT,
                vbcOT90: t.vbcOT90,
                vbcExon: t.vbcExon,
                mitSpecificity: t.mitSpecificity,
                crisporDoenchPerc: t.crisporDoenchPerc,
                crisporScanScore: t.crisporScanScore,
                crisporOutOfFrame: t.crisporOutOfFrame
            )
        }
    }
    
    /// 检测当前 CHOPCHOP 靶点是否与本地查找/生成的 sgRNA 或 shRNA 序列重合
    public func matchAgainstLocalTargets(_ localTargets: [LocalCompareTarget]) -> CHOPCHOPLocalMatchResult? {
        CHOPCHOPLocalMatchResult.bestMatch(
            primarySequence: spacer,
            fullSequence: targetSequence,
            localTargets: localTargets
        )
    }
}

/// CHOPCHOP 查询返回包
public struct CHOPCHOPQueryResponse: Codable {
    public var status: String
    public var message: String?
    public var jobId: String?
    public var gene: String?
    public var genome: String?
    public var count: Int?
    public var cached: Bool?
    public var targets: [CHOPCHOPTarget]?
}
