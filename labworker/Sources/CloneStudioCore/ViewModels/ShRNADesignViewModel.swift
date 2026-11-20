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
    
    // 靶点来源模式（支持内嵌 Broad GPP Public Portal 在线对比）
    public enum SourceMode: String, CaseIterable, Identifiable, Sendable {
        case library = "TRC 文库"
        case broadGPP = "Broad GPP"
        case custom = "手动输入"
        
        public var id: String { rawValue }
    }
    
    @Published public var sourceMode: SourceMode = .library
    public var isCustomInputMode: Bool {
        get { sourceMode == .custom }
        set { sourceMode = newValue ? .custom : .library }
    }
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
        if isCustomInputMode || (searchResults.isEmpty && !customSequence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
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
    
    /// 切换至内嵌「Broad GPP」在线对比，自动带入当前基因与本地 shRNA 序列并按需查询
    public func openInlineBroadGPPCompare(gene: String? = nil, forceRefresh: Bool = false) {
        let provided = (gene ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let qClean = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String = {
            if !provided.isEmpty { return provided }
            if !qClean.isEmpty { return qClean }
            if let sel = searchResults.first(where: { selectedTargetIDs.contains($0.id) }) { return sel.gene }
            if let first = searchResults.first { return first.gene }
            let customG = customGeneName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !customG.isEmpty { return customG }
            return ""
        }()
        
        syncLocalTargetsToGlobalComparePool()
        sourceMode = .broadGPP
        
        let gppVM = WorkspaceSessionManager.shared.broadGPPVM
        let effectiveGene = resolved.isEmpty ? gppVM.gene.trimmingCharacters(in: .whitespacesAndNewlines) : resolved
        guard !effectiveGene.isEmpty else { return }
        
        let needsFetch = forceRefresh
            || gppVM.targets.isEmpty
            || gppVM.gene.caseInsensitiveCompare(effectiveGene) != .orderedSame
            || gppVM.species != species
        
        gppVM.updateTarget(gene: effectiveGene, species: species)
        if needsFetch {
            gppVM.fetchTargets(forceRefresh: forceRefresh)
        }
    }
    
    /// 一键生成 shRNA 发夹引物
    public func generatePrimers() {
        var list: [PrimerItem] = []
        
        switch sourceMode {
        case .custom:
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
            
        case .broadGPP:
            let gppVM = WorkspaceSessionManager.shared.broadGPPVM
            let selected = gppVM.sortedTargets.filter { gppVM.selectedTargetIDs.contains($0.id) }
            guard !selected.isEmpty else {
                errorMessage = "请先在「Broad GPP」中检索基因，并至少勾选一条 TRC shRNA 克隆！"
                showErrorAlert = true
                return
            }
            let gppGene = (gppVM.resolvedGeneSymbol ?? gppVM.gene).trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedGene = gppGene.isEmpty
                ? (searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "shTarget" : searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))
                : gppGene
            let userPrefix = customPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            for target in selected {
                let effectivePrefix = userPrefix.isEmpty ? target.primaryCloneID : userPrefix
                let pair = ShRNADesigner.designPair(
                    target: target.targetSequence,
                    geneName: resolvedGene,
                    index: target.rank,
                    prefix: effectivePrefix,
                    species: species,
                    loop: loopSequence
                )
                let noteSuffix = " | Broad TRC: \(target.primaryCloneID)"
                list.append(PrimerItem(
                    name: pair.fwdPrimer.name,
                    fullSequence: pair.fwdPrimer.fullSequence,
                    homologyArm: pair.fwdPrimer.homologyArm,
                    specificSequence: pair.fwdPrimer.specificSequence,
                    tm: pair.fwdPrimer.tm,
                    targetPurpose: pair.fwdPrimer.targetPurpose,
                    notes: pair.fwdPrimer.notes + noteSuffix,
                    sourceTool: pair.fwdPrimer.sourceTool
                ))
                list.append(PrimerItem(
                    name: pair.revPrimer.name,
                    fullSequence: pair.revPrimer.fullSequence,
                    homologyArm: pair.revPrimer.homologyArm,
                    specificSequence: pair.revPrimer.specificSequence,
                    tm: pair.revPrimer.tm,
                    targetPurpose: pair.revPrimer.targetPurpose,
                    notes: pair.revPrimer.notes + noteSuffix,
                    sourceTool: pair.revPrimer.sourceTool
                ))
            }
            
        case .library:
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
        AppState.shared.showToast("已成功生成 \(list.count) 条 shRNA 配对引物（已同步至对比高亮池）！")
    }
    
    public func addAllToCart() {
        guard !generatedPrimers.isEmpty else { return }
        AppState.shared.addPrimersToCart(generatedPrimers)
    }
    
    /// 切换并展开内嵌 Broad GPP 在线克隆对比
    public func compareInCHOPCHOP(gene: String) {
        openInlineBroadGPPCompare(gene: gene, forceRefresh: false)
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
