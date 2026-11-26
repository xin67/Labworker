import Foundation

/// CRISPR/Cas9 sgRNA 靶点有效性与可靠性评分引擎 (参考 Doench Rule Set 2, Hsu et al., CRISPRscan)
public struct SgRNAScoringEngine {
    
    /// 对 20 bp sgRNA Spacer 序列进行多维打分
    /// - Parameter sequence: 靶向 Spacer 序列 (不含 PAM，通常 20nt)
    /// - Returns: TargetScore 综合评分与诊断标签
    public static func evaluate(sequence: String) -> TargetScore {
        let cleanSeq = BioSequence.clean(sequence)
        guard cleanSeq.count >= 15 else {
            return TargetScore(
                score: 20.0,
                tier: .poor,
                gcPercent: 0.0,
                summary: L10n.t("序列过短（通常需 20 bp）"),
                tags: [ScoreTag(name: L10n.t("序列过短"), points: -50, type: .penalty)],
                fatalWarning: L10n.t("序列长度不足 15 bp")
            )
        }
        
        var rawScore: Double = 70.0
        var tags: [ScoreTag] = []
        var fatalWarning: String? = nil
        
        // 1. Pol III 转录终止信号检查 (质粒 U6 启动子致命缺陷)
        if cleanSeq.contains("TTTT") {
            tags.append(ScoreTag(name: L10n.t("⚠️ 含Pol III终止信号TTTT"), points: -40, type: .fatal))
            fatalWarning = L10n.t("含 4 个及以上连续 T，在人/鼠 U6 启动子下会导致转录提前终止无法生成完整 sgRNA")
            rawScore -= 40.0
        }
        
        // 2. GC 含量评估 (维持适度解旋与结合能)
        let gc = BioSequence.gcContent(cleanSeq)
        if gc >= 45.0 && gc <= 55.0 {
            tags.append(ScoreTag(name: L10n.tr("GC理想 (\(Int(gc))%)", "Optimal GC (\(Int(gc))%)"), points: 15, type: .bonus))
            rawScore += 15.0
        } else if (gc >= 40.0 && gc < 45.0) || (gc > 55.0 && gc <= 60.0) {
            tags.append(ScoreTag(name: L10n.tr("GC适中 (\(Int(gc))%)", "Moderate GC (\(Int(gc))%)"), points: 10, type: .bonus))
            rawScore += 10.0
        } else if (gc >= 30.0 && gc < 40.0) || (gc > 60.0 && gc <= 70.0) {
            tags.append(ScoreTag(name: L10n.tr("GC略偏离区间 (\(Int(gc))%)", "Suboptimal GC (\(Int(gc))%)"), points: 0, type: .penalty))
        } else {
            tags.append(ScoreTag(name: L10n.tr("极端GC (\(Int(gc))%) 影响结合或形成发夹", "Extreme GC (\(Int(gc))%) affects binding/hairpins"), points: -25, type: .penalty))
            rawScore -= 25.0
        }
        
        // 3. PAM 邻接第 20 位碱基偏好 (Doench 规则核心特征)
        if let pos20 = cleanSeq.suffix(1).first {
            switch pos20 {
            case "G":
                tags.append(ScoreTag(name: L10n.t("PAM邻近G优选 (显著促进Cas9切割)"), points: 10, type: .bonus))
                rawScore += 10.0
            case "A":
                tags.append(ScoreTag(name: L10n.t("PAM邻近A良好"), points: 6, type: .bonus))
                rawScore += 6.0
            case "C":
                // 中性
                break
            case "T":
                tags.append(ScoreTag(name: L10n.t("PAM邻近T受抑 (Doench统计显示切割率低下)"), points: -20, type: .penalty))
                rawScore -= 20.0
            default:
                break
            }
        }
        
        // 4. 种子区第 19 位碱基 (倒数第 2 位)
        if cleanSeq.count >= 2 {
            let pos19 = cleanSeq[cleanSeq.index(cleanSeq.endIndex, offsetBy: -2)]
            if pos19 == "G" || pos19 == "C" {
                tags.append(ScoreTag(name: L10n.t("种子区G/C (形成稳定R-loop)"), points: 5, type: .bonus))
                rawScore += 5.0
            } else if pos19 == "T" {
                tags.append(ScoreTag(name: L10n.t("种子区T (削弱结合稳定性)"), points: -8, type: .penalty))
                rawScore -= 8.0
            }
        }
        
        // 5. 5' 端起始碱基 (U6 启动子偏好)
        if let pos1 = cleanSeq.prefix(1).first {
            if pos1 == "G" {
                tags.append(ScoreTag(name: L10n.t("U6启动子天然起始G"), points: 5, type: .bonus))
                rawScore += 5.0
            }
        }
        
        // 6. 同聚物游程检查 (Poly-N >= 4)
        if cleanSeq.contains("AAAA") || cleanSeq.contains("CCCC") || cleanSeq.contains("GGGG") {
            tags.append(ScoreTag(name: L10n.t("存在同聚物游程 (≥4nt 滑移风险)"), points: -15, type: .penalty))
            rawScore -= 15.0
        }
        
        // 若存在致命终止信号，强制上限封顶 35 分
        if fatalWarning != nil {
            rawScore = min(rawScore, 35.0)
        }
        
        let finalScore = min(max(rawScore, 0.0), 100.0)
        let tier = TargetScoreTier.from(score: finalScore)
        
        let summary: String
        switch tier {
        case .excellent:
            summary = L10n.t("优质靶点：GC平衡、PAM邻接碱基优选、无终止信号")
        case .good:
            summary = L10n.t("良好靶点：参数正常，适于常规敲除实验")
        case .fair:
            summary = L10n.t("次选靶点：存在一定偏好偏差，建议优先考虑高分靶点")
        case .poor:
            summary = fatalWarning ?? L10n.t("低分靶点：存在显著切割抑制或极端GC")
        }
        
        return TargetScore(
            score: finalScore,
            tier: tier,
            gcPercent: gc,
            summary: summary,
            tags: tags,
            fatalWarning: fatalWarning
        )
    }
}
