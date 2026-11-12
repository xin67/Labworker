import Foundation
import SwiftUI

/// 靶点质量与可靠性分级
public enum TargetScoreTier: String, CaseIterable, Identifiable, Codable, Sendable {
    case excellent = "excellent" // 80 ~ 100
    case good = "good"           // 60 ~ 79
    case fair = "fair"           // 40 ~ 59
    case poor = "poor"           // 0 ~ 39
    
    public var id: String { rawValue }
    
    public var stars: String {
        switch self {
        case .excellent: return "★★★"
        case .good:      return "★★"
        case .fair:      return "★"
        case .poor:      return "⚠️"
        }
    }
    
    public var displayName: String {
        switch self {
        case .excellent: return "★★★ 卓越"
        case .good:      return "★★ 良好"
        case .fair:      return "★ 一般"
        case .poor:      return "⚠️ 慎选"
        }
    }
    
    public var shortName: String {
        switch self {
        case .excellent: return "卓越"
        case .good:      return "良好"
        case .fair:      return "一般"
        case .poor:      return "慎选"
        }
    }
    
    public var color: Color {
        switch self {
        case .excellent: return .green
        case .good:      return .blue
        case .fair:      return .orange
        case .poor:      return .red
        }
    }
    
    public var recommendation: String {
        switch self {
        case .excellent: return "首选推荐：切割/沉默效率极高，转录与热力学参数理想"
        case .good:      return "推荐使用：切割/干扰效能良好，可满足常规功能验证"
        case .fair:      return "次选备选：GC偏离最佳区间或存在次选碱基偏好"
        case .poor:      return "谨慎选用：存在质粒转录早停(TTTT)或严重热力学/GC缺陷"
        }
    }
    
    public static func from(score: Double) -> TargetScoreTier {
        if score >= 80.0 {
            return .excellent
        } else if score >= 60.0 {
            return .good
        } else if score >= 40.0 {
            return .fair
        } else {
            return .poor
        }
    }
}

/// 评分特征与诊断标签
public struct ScoreTag: Identifiable, Hashable, Codable, Sendable {
    public enum TagType: String, Codable, Sendable {
        case bonus    // 加分项
        case penalty  // 普通扣分
        case fatal    // 致命警示扣分
    }
    
    public var id: String { "\(name)_\(points)" }
    public var name: String
    public var points: Int
    public var type: TagType
    
    public init(name: String, points: Int, type: TagType) {
        self.name = name
        self.points = points
        self.type = type
    }
    
    public var formattedPoints: String {
        if points > 0 {
            return "+\(points)"
        } else {
            return "\(points)"
        }
    }
    
    public var tagColor: Color {
        switch type {
        case .bonus:   return .green
        case .penalty: return .orange
        case .fatal:   return .red
        }
    }
}

/// 综合评分与质量评定结果
public struct TargetScore: Hashable, Codable, Sendable {
    public var score: Double
    public var tier: TargetScoreTier
    public var gcPercent: Double
    public var summary: String
    public var tags: [ScoreTag]
    public var fatalWarning: String?
    
    public init(
        score: Double,
        tier: TargetScoreTier,
        gcPercent: Double,
        summary: String,
        tags: [ScoreTag],
        fatalWarning: String? = nil
    ) {
        self.score = min(max(score, 0.0), 100.0)
        self.tier = tier
        self.gcPercent = gcPercent
        self.summary = summary
        self.tags = tags
        self.fatalWarning = fatalWarning
    }
    
    public var hasFatalIssue: Bool {
        fatalWarning != nil
    }
    
    public var formattedScore: String {
        String(format: "%.0f", score)
    }
}
