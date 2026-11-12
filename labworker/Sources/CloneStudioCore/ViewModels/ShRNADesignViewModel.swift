import Foundation
import SwiftUI
import Combine

@MainActor
public final class ShRNADesignViewModel: ObservableObject {
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
    
    // 自定义模式
    @Published public var isCustomInputMode: Bool = false
    @Published public var customGeneName: String = ""
    @Published public var customSequence: String = ""
    
    // 发夹参数
    @Published public var customPrefix: String = ""
    @Published public var loopSequence: String = ShRNADesigner.defaultLoop
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
        return ShRNAScoringEngine.evaluate(sequence: clean)
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
            type: .shRNA
        )
        self.rawLibraryResults = targets
        applySort()
        
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
    
    /// 构建当前本地查找/选中的 shRNA 对比序列集合并同步至全局状态
    public func buildLocalCompareTargets() -> [LocalCompareTarget] {
        var items: [LocalCompareTarget] = []
        if isCustomInputMode {
            let clean = BioSequence.clean(customSequence)
            if clean.count >= 15 {
                let geneLabel = customGeneName.trimmingCharacters(in: .whitespaces).isEmpty ? "自定义" : customGeneName
                items.append(LocalCompareTarget(
                    label: "本地\(geneLabel) shRNA",
                    sequence: clean,
                    sourceType: .shRNA,
                    isSelectedOrGenerated: true
                ))
            }
        } else {
            var selIdx = 1
            for target in searchResults {
                let isSel = selectedTargetIDs.contains(target.id)
                if isSel {
                    items.append(LocalCompareTarget(
                        label: "本地已选 sh#\(selIdx)",
                        sequence: target.sequence,
                        sourceType: .shRNA,
                        isSelectedOrGenerated: true
                    ))
                    selIdx += 1
                } else {
                    items.append(LocalCompareTarget(
                        label: "本地文库 shRNA",
                        sequence: target.sequence,
                        sourceType: .shRNA,
                        isSelectedOrGenerated: false
                    ))
                }
            }
        }
        return items
    }
    
    public func syncLocalTargetsToGlobalComparePool() {
        let items = buildLocalCompareTargets()
        AppState.shared.syncLocalCompareTargets(items, replaceSourceType: .shRNA)
    }
    
    /// 一键生成 shRNA 发夹引物
    public func generatePrimers() {
        var list: [PrimerItem] = []
        
        if isCustomInputMode {
            let clean = BioSequence.clean(customSequence)
            guard clean.count >= 18 && clean.count <= 26 else {
                errorMessage = "自定义 shRNA 靶点长度通常为 19～21 bp（当前：\(clean.count) bp）"
                showErrorAlert = true
                return
            }
            let gene = customGeneName.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom" : customGeneName
            let pair = ShRNADesigner.designPair(
                target: clean,
                geneName: gene,
                index: 1,
                prefix: customPrefix,
                species: species,
                loop: loopSequence
            )
            list.append(pair.fwdPrimer)
            list.append(pair.revPrimer)
        } else {
            let selectedTargets = searchResults.filter { selectedTargetIDs.contains($0.id) }
            guard !selectedTargets.isEmpty else {
                errorMessage = "请先搜索基因，并至少勾选一条需要生成的 shRNA 靶点！"
                showErrorAlert = true
                return
            }
            
            for (index, target) in selectedTargets.enumerated() {
                let pair = ShRNADesigner.designPair(
                    target: target.sequence,
                    geneName: target.gene,
                    index: index + 1,
                    prefix: customPrefix,
                    species: species,
                    loop: loopSequence
                )
                list.append(pair.fwdPrimer)
                list.append(pair.revPrimer)
            }
        }
        
        self.generatedPrimers = list
        syncLocalTargetsToGlobalComparePool()
        AppState.shared.showToast("已成功生成 \(list.count) 条 shRNA 配对引物（已同步至 CHOPCHOP 对比池）！")
    }
    
    public func addAllToCart() {
        guard !generatedPrimers.isEmpty else { return }
        AppState.shared.addPrimersToCart(generatedPrimers)
    }
    
    /// 跳转 CHOPCHOP 对比（自动携带当前本地查找/选中的 shRNA 靶点进行高亮对比）
    public func compareInCHOPCHOP(gene: String) {
        let localItems = buildLocalCompareTargets()
        AppState.shared.navigateToCHOPCHOP(
            gene: gene,
            species: species,
            localTargets: localItems,
            sourceType: .shRNA
        )
    }
    
    /// 一键清空当前 shRNA 检索与引物生成状态
    public func clear() {
        searchQuery = ""
        rawLibraryResults = []
        searchResults = []
        selectedTargetIDs = []
        customGeneName = ""
        customSequence = ""
        customPrefix = ""
        generatedPrimers = []
        AppState.shared.localCompareTargets.removeAll { $0.sourceType == .shRNA }
    }
}
