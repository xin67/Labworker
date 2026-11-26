import SwiftUI
import CloneStudioCore

/// 靶点可靠性评分胶囊微徽章与诊断悬浮窗 (TargetScoreBadge)
public struct TargetScoreBadge: View {
    @Environment(\.appLanguage) private var appLanguage
    public let score: TargetScore
    public var compact: Bool = false
    
    @State private var showPopover: Bool = false
    
    public init(score: TargetScore, compact: Bool = false) {
        self.score = score
        self.compact = compact
    }
    
    public var body: some View {
        let _ = appLanguage
        Button(action: {
            showPopover.toggle()
        }) {
            HStack(spacing: 3.5) {
                Text(score.formattedScore)
                    .font(.system(size: compact ? 10.5 : 11, weight: .bold))
                    .monospacedDigit()
                
                Text(score.tier.stars)
                    .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
            }
            .padding(.horizontal, compact ? 5.5 : 7.5)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                Capsule(style: .continuous)
                    .fill(score.tier.color.opacity(0.14))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(score.tier.color.opacity(0.30), lineWidth: 1)
                    )
            )
            .foregroundColor(score.tier.color)
        }
        .buttonStyle(.plain)
        .help(L10n.tr(
            "序列启发式评分组成：GC 含量、二级结构/自互补、Poly-T 终止信号与位置权重（未包含全基因组脱靶搜索，当前: \(score.formattedScore)分）",
            "Sequence heuristic score breakdown: GC%, secondary structure/self-complementarity, Poly-T terminator & positional weights (excludes genome-wide off-target scan; score: \(score.formattedScore))"
        ))
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            scoreDetailPopover
        }
    }
    
    private var scoreDetailPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶栏：评分与评级
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.tr("\(score.formattedScore) 分", "\(score.formattedScore) pts"))
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(score.tier.color)
                
                Text(score.tier.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(score.tier.color.opacity(0.15))
                    .foregroundColor(score.tier.color)
                    .clipShape(Capsule(style: .continuous))
                
                Spacer()
                
                Text("GC \(String(format: "%.0f", score.gcPercent))%")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            
            Text(score.tier.recommendation)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            
            Divider()
            
            // 致命缺陷提示 (如 TTTT)
            if let warning = score.fatalWarning {
                HStack(alignment: .top, spacing: 6) {
                    Text("⚠️")
                    Text(warning)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.red)
                }
                .padding(6)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            
            // 规则诊断标签明细
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("序列启发式评分明细（GC / 二级结构 / Poly-T / 位置权重）："))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.secondary)
                
                ForEach(score.tags) { tag in
                    HStack(spacing: 6) {
                        Text(tag.formattedPoints)
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(tag.tagColor.opacity(0.15))
                            .foregroundColor(tag.tagColor)
                            .clipShape(Capsule(style: .continuous))
                            .frame(width: 38, alignment: .center)
                        
                        Text(tag.name)
                            .font(.system(size: 11))
                            .foregroundColor(.primary)
                        
                        Spacer()
                    }
                }
            }
            
            Divider()
            
            HStack {
                Text(L10n.t("基于序列启发式规则（Doench RS2 / Reynolds 与 U6 转录特征，未含全基因组脱靶搜索）"))
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary.opacity(0.8))
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 290)
    }
}
