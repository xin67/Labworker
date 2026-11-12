import Foundation
import SwiftUI

/// 物种类型定义
public enum TargetSpecies: String, CaseIterable, Identifiable, Codable, Sendable {
    case human = "human"
    case mouse = "mouse"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .human: return "👤 人源 (Human / hg38)"
        case .mouse: return "🐭 鼠源 (Mouse / mm39)"
        }
    }
    
    public var shortName: String {
        switch self {
        case .human: return "人源"
        case .mouse: return "鼠源"
        }
    }
    
    public var chopchopGenome: String {
        switch self {
        case .human: return "hg38"
        case .mouse: return "mm39"
        }
    }
    
    public var themeColor: Color {
        switch self {
        case .human: return .blue
        case .mouse: return .orange
        }
    }
}

/// 靶点类型定义
public enum GenomicTargetType: String, CaseIterable, Identifiable, Codable {
    case sgRNA = "sgRNA"
    case shRNA = "shRNA"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .sgRNA: return "CRISPR/Cas9 sgRNA"
        case .shRNA: return "慢病毒发夹 shRNA"
        }
    }
}

/// 基因组靶点条目模型
public struct GenomicTarget: Identifiable, Hashable, Codable {
    public var id: Int
    public var gene: String
    public var sequence: String
    public var species: TargetSpecies
    public var type: GenomicTargetType
    
    public init(id: Int, gene: String, sequence: String, species: TargetSpecies, type: GenomicTargetType) {
        self.id = id
        self.gene = gene
        self.sequence = BioSequence.clean(sequence)
        self.species = species
        self.type = type
    }
    
    public var length: Int {
        sequence.count
    }
    
    public var gcPercent: Double {
        BioSequence.gcContent(sequence)
    }
    
    /// 靶点可靠性与有效性综合评分
    public var scoreResult: TargetScore {
        switch type {
        case .sgRNA:
            return SgRNAScoringEngine.evaluate(sequence: sequence)
        case .shRNA:
            return ShRNAScoringEngine.evaluate(sequence: sequence)
        }
    }
    
    public var score: Double {
        scoreResult.score
    }
    
    public var scoreTier: TargetScoreTier {
        scoreResult.tier
    }
}
