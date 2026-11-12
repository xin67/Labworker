import Foundation

// MARK: - 1. 质粒连续改造谱系树数据模型 (Ported from CloneCanvas genome/history.ts & HistoryTree.svelte)

public enum ConstructOperationType: String, Sendable, Codable, CaseIterable {
    case entryClone = "入门克隆 (pCE2)"
    case singleFragment = "单片段无缝克隆"
    case multiFragment = "多片段无缝拼接"
    case mutagenesis = "定点突变 (SDM)"
    case fragmentDeletion = "质粒大片段敲除 (Δ)"
    case crisprSgRNA = "CRISPR sgRNA 构建"
    case shRNA = "shRNA 载体构建"
}

public enum FeatureShiftStatus: String, Sendable, Equatable {
    case unchanged = "保留未变"
    case shifted = "坐标平移"
    case inserted = "新增插入"
    case deleted = "已敲除"
    case mutated = "定点突变"
}

/// 改造前后单个质粒特征 (Feature) 的坐标位移对比项
public struct FeatureShiftItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let featureName: String
    public let oldRangeText: String
    public let newRangeText: String
    /// 位移量（正数代表向下游右移，负数代表向上游左移）
    public let deltaBp: Int
    public let status: FeatureShiftStatus
    
    public init(
        id: UUID = UUID(),
        featureName: String,
        oldRangeText: String,
        newRangeText: String,
        deltaBp: Int,
        status: FeatureShiftStatus
    ) {
        self.id = id
        self.featureName = featureName
        self.oldRangeText = oldRangeText
        self.newRangeText = newRangeText
        self.deltaBp = deltaBp
        self.status = status
    }
}

/// 接头黏性末端 / 18bp 同源重组退火配对详情 (对标 HistoryTree.svelte 展开详情块)
public struct JunctionOverhangDetail: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let topStrandSnippet: String
    public let bottomStrandSnippet: String
    public let enzymeOrArmName: String
    public let homologyLength: Int
    
    public init(
        id: UUID = UUID(),
        title: String,
        topStrandSnippet: String,
        bottomStrandSnippet: String,
        enzymeOrArmName: String,
        homologyLength: Int = 18
    ) {
        self.id = id
        self.title = title
        self.topStrandSnippet = topStrandSnippet
        self.bottomStrandSnippet = bottomStrandSnippet
        self.enzymeOrArmName = enzymeOrArmName
        self.homologyLength = homologyLength
    }
}

/// 谱系树中的单次质粒构建/改造节点
public struct ConstructHistoryNode: Identifiable, Sendable {
    public let id: UUID
    public let parentNodeID: UUID?
    public let constructName: String
    public let operationType: ConstructOperationType
    public let parentVectorName: String
    public let parentLengthBp: Int
    public let insertOrActionSummary: String
    public let productLengthBp: Int
    public let homologyArmLength: Int
    public let junctionOverhangs: [JunctionOverhangDetail]
    public let featureShifts: [FeatureShiftItem]
    public let primers: [PrimerItem]
    public let productSequence: String
    public let createdAt: Date
    
    public var deltaBp: Int {
        productLengthBp - parentLengthBp
    }
    
    public init(
        id: UUID = UUID(),
        parentNodeID: UUID? = nil,
        constructName: String,
        operationType: ConstructOperationType,
        parentVectorName: String,
        parentLengthBp: Int,
        insertOrActionSummary: String,
        productLengthBp: Int,
        homologyArmLength: Int = 18,
        junctionOverhangs: [JunctionOverhangDetail] = [],
        featureShifts: [FeatureShiftItem] = [],
        primers: [PrimerItem] = [],
        productSequence: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.parentNodeID = parentNodeID
        self.constructName = constructName
        self.operationType = operationType
        self.parentVectorName = parentVectorName
        self.parentLengthBp = parentLengthBp
        self.insertOrActionSummary = insertOrActionSummary
        self.productLengthBp = productLengthBp
        self.homologyArmLength = homologyArmLength
        self.junctionOverhangs = junctionOverhangs
        self.featureShifts = featureShifts
        self.primers = primers
        self.productSequence = productSequence
        self.createdAt = createdAt
    }
}

// MARK: - 2. 质粒构建谱系树与特征位移对比管理器

@MainActor
public final class ConstructHistoryManager: ObservableObject {
    public static let shared = ConstructHistoryManager()
    
    @Published public private(set) var nodes: [ConstructHistoryNode] = []
    @Published public var activeNodeID: UUID? = nil
    
    public init() {}
    
    public func recordNode(_ node: ConstructHistoryNode) {
        nodes.append(node)
        activeNodeID = node.id
    }
    
    public func clearHistory() {
        nodes.removeAll()
        activeNodeID = nil
    }
    
    /// 获取从根节点到指定节点的完整祖先演进链路
    public func ancestryChain(for nodeID: UUID) -> [ConstructHistoryNode] {
        var chain: [ConstructHistoryNode] = []
        var curID: UUID? = nodeID
        var visited = Set<UUID>()
        while let cid = curID, !visited.contains(cid), let node = nodes.first(where: { $0.id == cid }) {
            visited.insert(cid)
            chain.insert(node, at: 0)
            curID = node.parentNodeID
        }
        return chain
    }
    
    /// 纯算法：根据编辑区间 [editStartBp, editEndBp] 与插入长度计算改造前后 Feature 坐标位移对比表
    public nonisolated static func computeFeatureShifts(
        originalFeatures: [(name: String, start: Int, end: Int)],
        editStartBp: Int,
        editEndBp: Int,
        insertedBp: Int,
        insertedFeatureName: String?
    ) -> [FeatureShiftItem] {
        let removedLen = editEndBp >= editStartBp ? (editEndBp - editStartBp + 1) : 0
        let netDelta = insertedBp - removedLen
        var items: [FeatureShiftItem] = []
        var hasInsertedNew = false
        
        for feat in originalFeatures {
            if feat.end < editStartBp {
                items.append(
                    FeatureShiftItem(
                        featureName: feat.name,
                        oldRangeText: "\(feat.start)..\(feat.end)",
                        newRangeText: "\(feat.start)..\(feat.end)",
                        deltaBp: 0,
                        status: .unchanged
                    )
                )
            } else if feat.start >= editStartBp && feat.end <= editEndBp && removedLen > 0 {
                items.append(
                    FeatureShiftItem(
                        featureName: feat.name,
                        oldRangeText: "\(feat.start)..\(feat.end)",
                        newRangeText: "已移除",
                        deltaBp: -(feat.end - feat.start + 1),
                        status: .deleted
                    )
                )
            } else {
                if !hasInsertedNew, let insName = insertedFeatureName, !insName.isEmpty {
                    let insEnd = editStartBp + max(1, insertedBp) - 1
                    items.append(
                        FeatureShiftItem(
                            featureName: insName,
                            oldRangeText: "---",
                            newRangeText: "\(editStartBp)..\(insEnd)",
                            deltaBp: insertedBp,
                            status: .inserted
                        )
                    )
                    hasInsertedNew = true
                }
                let newS = max(1, feat.start + netDelta)
                let newE = max(newS, feat.end + netDelta)
                items.append(
                    FeatureShiftItem(
                        featureName: feat.name,
                        oldRangeText: "\(feat.start)..\(feat.end)",
                        newRangeText: "\(newS)..\(newE)",
                        deltaBp: netDelta,
                        status: netDelta == 0 ? .unchanged : .shifted
                    )
                )
            }
        }
        
        if !hasInsertedNew, let insName = insertedFeatureName, !insName.isEmpty {
            let insEnd = editStartBp + max(1, insertedBp) - 1
            items.append(
                FeatureShiftItem(
                    featureName: insName,
                    oldRangeText: "---",
                    newRangeText: "\(editStartBp)..\(insEnd)",
                    deltaBp: insertedBp,
                    status: .inserted
                )
            )
        }
        
        return items
    }
}
