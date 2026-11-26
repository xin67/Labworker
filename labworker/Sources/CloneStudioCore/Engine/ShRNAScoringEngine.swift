import Foundation

/// 慢病毒 shRNA / siRNA 靶点有效性与可靠性评分引擎 (参考 Reynolds 8规则, Ui-Tei 规则, Amarzguioui 规则)
public struct ShRNAScoringEngine {
    
    /// 对 19~21 bp shRNA Sense 链序列进行多维打分
    /// - Parameter sequence: 靶向 Sense 序列 (通常 19~21nt)
    /// - Returns: TargetScore 综合评分与诊断标签
    public static func evaluate(sequence: String) -> TargetScore {
        let cleanSeq = BioSequence.clean(sequence)
        guard cleanSeq.count >= 15 else {
            return TargetScore(
                score: 20.0,
                tier: .poor,
                gcPercent: 0.0,
                summary: L10n.t("序列过短（通常需 19~21 bp）"),
                tags: [ScoreTag(name: L10n.t("序列过短"), points: -50, type: .penalty)],
                fatalWarning: L10n.t("序列长度不足 15 bp")
            )
        }
        
        var rawScore: Double = 70.0
        var tags: [ScoreTag] = []
        var fatalWarning: String? = nil
        
        // 1. Pol III 转录终止信号检查 (慢病毒载体 pLKO.1 / U6 启动子致命缺陷)
        if cleanSeq.contains("TTTT") {
            tags.append(ScoreTag(name: L10n.t("⚠️ 含Pol III终止信号TTTT"), points: -40, type: .fatal))
            fatalWarning = L10n.t("Sense链含 4 个及以上连续 T，在 pLKO.1 载体中会导致转录提前终止无法形成发夹")
            rawScore -= 40.0
        }
        
        // 2. 热力学不对称性：Sense 链 3' 端 (反义链 5' 端)
        // Ui-Tei & Reynolds 关键法则：反义链 5' 端稳定性低(A/T富集)促进 Ago2/RISC 优先结合并装载反义链(引导链)
        if let lastBase = cleanSeq.suffix(1).first {
            switch lastBase {
            case "A":
                tags.append(ScoreTag(name: L10n.t("3'端A热力学极佳 (RISC优先加载反义链)"), points: 15, type: .bonus))
                rawScore += 15.0
            case "T":
                tags.append(ScoreTag(name: L10n.t("3'端T热力学良好 (促进反义链装载)"), points: 12, type: .bonus))
                rawScore += 12.0
            case "G", "C":
                tags.append(ScoreTag(name: L10n.t("3'端G/C稳定性过高 (降低反义链选择效率)"), points: -10, type: .penalty))
                rawScore -= 10.0
            default:
                break
            }
        }
        
        // 3. 热力学不对称性：Sense 链 5' 端 (反义链 3' 端)
        // Sense 5' 端稳定性高(G/C)有助于抑制无功能的过客链装载进 RISC
        if let firstBase = cleanSeq.prefix(1).first {
            switch firstBase {
            case "G", "C":
                tags.append(ScoreTag(name: L10n.t("5'端G/C高稳定性 (抑制过客链装载)"), points: 8, type: .bonus))
                rawScore += 8.0
            case "A", "T":
                tags.append(ScoreTag(name: L10n.t("5'端A/T较弱 (可能存在微量过客链干扰)"), points: -5, type: .penalty))
                rawScore -= 5.0
            default:
                break
            }
        }
        
        // 4. Ago2 催化中心裂解位点 (第 10 位碱基)
        // Ago2 在结合靶标 mRNA 的第 10 与 11 位碱基间执行水解，A/T 有利于催化后解离
        if cleanSeq.count >= 10 {
            let pos10Index = cleanSeq.index(cleanSeq.startIndex, offsetBy: 9)
            let pos10 = cleanSeq[pos10Index]
            if pos10 == "A" || pos10 == "T" {
                tags.append(ScoreTag(name: L10n.t("第10位裂解中心A/T偏好 (促进Ago2催化剪切)"), points: 8, type: .bonus))
                rawScore += 8.0
            } else {
                tags.append(ScoreTag(name: L10n.t("第10位G/C较难裂解释放"), points: -4, type: .penalty))
                rawScore -= 4.0
            }
        }
        
        // 5. GC 含量评估 (35%~55% 易于双链解旋与 RISC 组装)
        let gc = BioSequence.gcContent(cleanSeq)
        if gc >= 35.0 && gc <= 50.0 {
            tags.append(ScoreTag(name: L10n.tr("GC理想 (\(Int(gc))%) 便于解旋", "Optimal GC (\(Int(gc))%) for unwinding"), points: 12, type: .bonus))
            rawScore += 12.0
        } else if gc > 50.0 && gc <= 55.0 {
            tags.append(ScoreTag(name: L10n.tr("GC适中 (\(Int(gc))%)", "Moderate GC (\(Int(gc))%)"), points: 6, type: .bonus))
            rawScore += 6.0
        } else if (gc >= 30.0 && gc < 35.0) || (gc > 55.0 && gc <= 65.0) {
            tags.append(ScoreTag(name: L10n.tr("GC略偏离最佳区间 (\(Int(gc))%)", "Suboptimal GC (\(Int(gc))%)"), points: 0, type: .penalty))
        } else {
            tags.append(ScoreTag(name: L10n.tr("极端GC (\(Int(gc))%) 影响Dicer加工或解旋", "Extreme GC (\(Int(gc))%) impairs Dicer processing"), points: -25, type: .penalty))
            rawScore -= 25.0
        }
        
        // 6. 同聚物游程检查 (Poly-N >= 4)
        if cleanSeq.contains("AAAA") || cleanSeq.contains("CCCC") || cleanSeq.contains("GGGG") {
            tags.append(ScoreTag(name: L10n.t("存在同聚物游程 (≥4nt)"), points: -15, type: .penalty))
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
            summary = L10n.t("优质靶点：热力学不对称性显著、RISC加载专一、无终止信号")
        case .good:
            summary = L10n.t("良好靶点：下调效能稳定，适于常规基因敲低实验")
        case .fair:
            summary = L10n.t("次选靶点：存在过客链竞争或解旋偏离，建议优先选高分")
        case .poor:
            summary = fatalWarning ?? L10n.t("低分靶点：存在早停信号或严重解旋阻力")
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
