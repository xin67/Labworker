import Foundation
import SwiftUI
import Combine

/// 靶点排序偏好
public enum TargetSortOption: String, CaseIterable, Identifiable {
    case scoreDesc = "序列启发式评分"
    case libraryAsc = "文库原始顺序"
    case gcDesc = "GC含量 (降序)"
    case gcAsc = "GC含量 (升序)"
    
    public var id: String { rawValue }
}

@MainActor
public final class SgRNADesignViewModel: ObservableObject {
    @Published public var species: TargetSpecies = .human
    @Published public var searchQuery: String = ""
    @Published public var searchResults: [GenomicTarget] = []
    @Published public var selectedTargetIDs: Set<Int> = []
    
    // 排序与筛选
    @Published public var sortOption: TargetSortOption = .scoreDesc {
        didSet {
            applySort()
        }
    }
    
    // 自定义靶点模式
    @Published public var isCustomInputMode: Bool = false
    @Published public var customGeneName: String = ""
    @Published public var customSequence: String = ""
    
    // 引物生成参数
    @Published public var customPrefix: String = ""
    @Published public var vectorOverhang: CRISPRDesigner.VectorOverhang = .lentiCRISPRv2
    @Published public var generatedPrimers: [PrimerItem] = []
    @Published public var isSearching: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var showErrorAlert: Bool = false
    
    private var rawLibraryResults: [GenomicTarget] = []
    
    public init() {}
    
    /// 自定义输入序列实时打分
    public var customTargetScore: TargetScore? {
        let clean = BioSequence.clean(customSequence)
        guard clean.count >= 10 else { return nil }
        return SgRNAScoringEngine.evaluate(sequence: clean)
    }
    
    public func search() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            rawLibraryResults = []
            searchResults = []
            selectedTargetIDs = []
            return
        }
        
        isSearching = true
        defer { isSearching = false }
        
        let targets = GenomicLibraryService.shared.search(
            query: q,
            species: species,
            type: .sgRNA
        )
        self.rawLibraryResults = targets
        applySort()
        
        // 默认全选序列评分高靶点（若无则全选前5条）
        let recommended = searchResults.filter { $0.scoreTier == .excellent || $0.scoreTier == .good }.map { $0.id }
        if !recommended.isEmpty {
            self.selectedTargetIDs = Set(recommended)
        } else {
            self.selectedTargetIDs = Set(searchResults.prefix(5).map { $0.id })
        }
        syncLocalTargetsToGlobalComparePool()
        
        if targets.isEmpty {
            AppState.shared.showToast("未在\(species.shortName)文库中找到基因「\(q)」")
        } else {
            let topTierCount = targets.filter { $0.scoreTier == .excellent || $0.scoreTier == .good }.count
            AppState.shared.showToast("检索到 \(targets.count) 条靶点（包含 \(topTierCount) 条序列评分高）")
        }
    }
    
    private func applySort() {
        switch sortOption {
        case .scoreDesc:
            self.searchResults = rawLibraryResults.sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.id < $1.id
            }
        case .libraryAsc:
            self.searchResults = rawLibraryResults.sorted { $0.id < $1.id }
        case .gcDesc:
            self.searchResults = rawLibraryResults.sorted { $0.gcPercent > $1.gcPercent }
        case .gcAsc:
            self.searchResults = rawLibraryResults.sorted { $0.gcPercent < $1.gcPercent }
        }
    }
    
    public func selectAll() {
        selectedTargetIDs = Set(searchResults.map { $0.id })
        syncLocalTargetsToGlobalComparePool()
    }
    
    public func deselectAll() {
        selectedTargetIDs.removeAll()
        syncLocalTargetsToGlobalComparePool()
    }
    
    /// 仅勾选序列评分高靶点 (★★★ / ★★)
    public func selectRecommendedOnly() {
        let highTierIDs = searchResults
            .filter { $0.scoreTier == .excellent || $0.scoreTier == .good }
            .map { $0.id }
        selectedTargetIDs = Set(highTierIDs)
        syncLocalTargetsToGlobalComparePool()
        AppState.shared.showToast("已自动勾选 \(highTierIDs.count) 条序列评分高靶点")
    }
    
    public func toggleTarget(_ target: GenomicTarget) {
        if selectedTargetIDs.contains(target.id) {
            selectedTargetIDs.remove(target.id)
        } else {
            selectedTargetIDs.insert(target.id)
        }
        syncLocalTargetsToGlobalComparePool()
    }
    
    /// 构建当前本地查找/选中的 sgRNA 对比序列集合并同步至全局状态
    public func buildLocalCompareTargets() -> [LocalCompareTarget] {
        var items: [LocalCompareTarget] = []
        if isCustomInputMode {
            let clean = BioSequence.clean(customSequence)
            if clean.count >= 15 {
                let geneLabel = customGeneName.trimmingCharacters(in: .whitespaces).isEmpty ? "自定义" : customGeneName
                items.append(LocalCompareTarget(
                    label: "本地\(geneLabel) sgRNA",
                    sequence: clean,
                    sourceType: .sgRNA,
                    isSelectedOrGenerated: true
                ))
            }
        } else {
            var selIdx = 1
            for target in searchResults {
                let isSel = selectedTargetIDs.contains(target.id)
                if isSel {
                    items.append(LocalCompareTarget(
                        label: "本地已选 sg#\(selIdx)",
                        sequence: target.sequence,
                        sourceType: .sgRNA,
                        isSelectedOrGenerated: true
                    ))
                    selIdx += 1
                } else {
                    items.append(LocalCompareTarget(
                        label: "本地文库 sgRNA",
                        sequence: target.sequence,
                        sourceType: .sgRNA,
                        isSelectedOrGenerated: false
                    ))
                }
            }
        }
        return items
    }
    
    public func syncLocalTargetsToGlobalComparePool() {
        let items = buildLocalCompareTargets()
        AppState.shared.syncLocalCompareTargets(items, replaceSourceType: .sgRNA)
    }
    
    /// 一键生成引物
    public func generatePrimers() {
        var list: [PrimerItem] = []
        
        if isCustomInputMode {
            let clean = BioSequence.clean(customSequence)
            guard clean.count >= 19 && clean.count <= 25 else {
                errorMessage = "自定义靶点长度通常为 20 bp（当前：\(clean.count) bp）"
                showErrorAlert = true
                return
            }
            let gene = customGeneName.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom" : customGeneName
            let pair = CRISPRDesigner.designPair(
                target: clean,
                geneName: gene,
                index: 1,
                prefix: customPrefix,
                species: species,
                vector: vectorOverhang
            )
            list.append(pair.fwdPrimer)
            list.append(pair.revPrimer)
        } else {
            let selectedTargets = searchResults.filter { selectedTargetIDs.contains($0.id) }
            guard !selectedTargets.isEmpty else {
                errorMessage = "请先搜索基因，并至少勾选一条需要生成引物的靶点序列！"
                showErrorAlert = true
                return
            }
            
            for (index, target) in selectedTargets.enumerated() {
                let pair = CRISPRDesigner.designPair(
                    target: target.sequence,
                    geneName: target.gene,
                    index: index + 1,
                    prefix: customPrefix,
                    species: species,
                    vector: vectorOverhang
                )
                list.append(pair.fwdPrimer)
                list.append(pair.revPrimer)
            }
        }
        
        self.generatedPrimers = list
        syncLocalTargetsToGlobalComparePool()
        AppState.shared.showToast("已成功生成 \(list.count) 条 sgRNA 引物（已同步至 CHOPCHOP 对比池）！")
    }
    
    /// 全部加入订购单
    public func addAllToCart() {
        guard !generatedPrimers.isEmpty else { return }
        AppState.shared.addPrimersToCart(generatedPrimers)
    }
    
    /// 跳转 CHOPCHOP 对比（自动携带当前本地查找/选中的 sgRNA 靶点进行高亮对比）
    public func compareInCHOPCHOP(gene: String) {
        let localItems = buildLocalCompareTargets()
        AppState.shared.navigateToCHOPCHOP(
            gene: gene,
            species: species,
            localTargets: localItems,
            sourceType: .sgRNA
        )
    }
    
    /// 一键清空当前 sgRNA 检索与引物生成状态
    public func clear() {
        searchQuery = ""
        rawLibraryResults = []
        searchResults = []
        selectedTargetIDs = []
        customGeneName = ""
        customSequence = ""
        customPrefix = ""
        generatedPrimers = []
        AppState.shared.localCompareTargets.removeAll { $0.sourceType == .sgRNA }
    }
}
