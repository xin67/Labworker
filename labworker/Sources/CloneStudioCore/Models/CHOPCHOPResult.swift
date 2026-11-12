import Foundation
import SwiftUI

/// 本地 sgRNA / shRNA / 自定义序列对比项（用于在 CHOPCHOP 检索结果中进行自动高亮对比）
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
}

/// CHOPCHOP 在线预测靶点模型 (包含全基因组脱靶数 MM0～MM3、Doench 2016 效率分与预缓存的全维综合推荐分)
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
    public var efficiency: Double         // CHOPCHOP Doench RS2 切割效率评分
    
    // 预计算缓存（避免列表滚动时重复执行评分算法）
    public let localScore: TargetScore
    public let combinedScore: TargetScore
    
    enum CodingKeys: String, CodingKey {
        case rank, targetSequence, spacer, pam, genomicLocation, strand
        case gcContent, selfComplementarity, mm0, mm1, mm2, mm3, efficiency
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
        efficiency: Double
    ) {
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
            localScore: loc
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
            efficiency: efficiency
        )
    }
    
    /// 脱靶特异性总结 (MM0/MM1/MM2/MM3)
    public var offTargetSummary: String {
        "\(mm0)/\(mm1)/\(mm2)/\(mm3)"
    }
    
    /// 核心脱靶安全评级 (0 错配与 1 错配均为 0)
    public var isHighlySpecific: Bool {
        mm0 == 0 && mm1 == 0
    }
    
    /// 全基因组零脱靶 (MM0～MM3 全为 0)
    public var isZeroOffTarget: Bool {
        mm0 == 0 && mm1 == 0 && mm2 == 0 && mm3 == 0
    }
    
    /// 计算融合了「全基因组脱靶安全度 (45%) + CHOPCHOP 切割效率 (35%) + 本地序列规则 (20%)」的全维综合推荐分
    private static func computeCombinedScore(
        spacer: String,
        mm0: Int,
        mm1: Int,
        mm2: Int,
        mm3: Int,
        selfComp: Int,
        efficiency: Double,
        localScore: TargetScore
    ) -> TargetScore {
        var tags: [ScoreTag] = []
        
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
    
    /// 检测当前 CHOPCHOP 靶点是否与本地查找/生成的 sgRNA 或 shRNA 序列重合
    public func matchAgainstLocalTargets(_ localTargets: [LocalCompareTarget]) -> CHOPCHOPLocalMatchResult? {
        guard !localTargets.isEmpty else { return nil }
        let cleanSpacer = spacer.uppercased()
        let cleanFull = targetSequence.uppercased()
        
        var bestMatch: CHOPCHOPLocalMatchResult? = nil
        
        for item in localTargets {
            let q = item.cleanSequence
            guard q.count >= 15 else { continue }
            
            var candidateKind: CHOPCHOPLocalMatchKind? = nil
            
            // 1. 精确匹配 (20bp Spacer 完全相等，或 21bp shRNA 完整包含 20bp Spacer)
            if cleanSpacer == q || cleanFull == q {
                candidateKind = .exact
            } else if let overlap = Self.longestCommonSubstringLength(cleanFull, q), overlap >= 18 {
                if overlap >= min(cleanSpacer.count, q.count) {
                    candidateKind = .exact
                } else {
                    candidateKind = .coreOverlap(overlap)
                }
            } else {
                // 2. 检查反向互补链同位点重合 (例如正负链靶向同一外显子区域)
                let rc = BioSequence.reverseComplement(q).uppercased()
                if let rcOverlap = Self.longestCommonSubstringLength(cleanFull, rc), rcOverlap >= 18 {
                    candidateKind = .reverseComplementOverlap(rcOverlap)
                }
            }
            
            if let kind = candidateKind {
                let candidate = CHOPCHOPLocalMatchResult(matchedTarget: item, kind: kind)
                if let current = bestMatch {
                    // 优先展示用户已勾选/已生成的靶点，其次按匹配精度排序
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
    
    /// 计算两条序列的最长连续公共子串长度 (针对 19～23bp 短序列极速比对)
    private static func longestCommonSubstringLength(_ a: String, _ b: String) -> Int? {
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
