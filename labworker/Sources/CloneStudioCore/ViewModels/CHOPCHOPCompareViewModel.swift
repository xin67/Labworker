import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
public final class CHOPCHOPCompareViewModel: ObservableObject {
    @Published public var gene: String = ""
    @Published public var species: TargetSpecies = .human
    @Published public var isLoading: Bool = false
    @Published public var progressMessage: String = ""
    @Published public var targets: [CHOPCHOPTarget] = []
    @Published public var selectedTargetIDs: Set<Int> = []
    @Published public var errorMessage: String? = nil
    @Published public var showErrorAlert: Bool = false
    
    // 本地 sgRNA / shRNA 序列高亮对比状态
    @Published public var manualCompareInput: String = ""
    @Published public var showOnlyLocalMatches: Bool = false
    @Published public var pinLocalMatchesFirst: Bool = true
    @Published public var matchMap: [Int: CHOPCHOPLocalMatchResult] = [:]
    
    // 排序模式（默认采用「智能综合推荐」，解决高综合分靶点因单个远端错配沉底的问题）
    @Published public var sortMode: CHOPCHOPSortMode = .smartRecommend
    
    public enum CHOPCHOPSortMode: String, CaseIterable, Identifiable {
        case smartRecommend = "智能推荐 (本地命中+零核心脱靶+高分优先)"
        case combinedScoreDesc = "全维综合评分 (从高到低)"
        case efficiencyDesc = "Doench 切割效率分 (降序)"
        case rankAsc = "CHOPCHOP 原始排名 (#Rank 严苛脱靶序)"
        case offTargetAsc = "脱靶错配最少优先 (MM0～MM3)"
        
        public var id: String { rawValue }
        
        public var ruleExplanation: String {
            switch self {
            case .smartRecommend:
                return "优先置顶「本地已选 SG/SH 命中序列」；其余靶点在保证核心特异性 (MM0=0, MM1=0) 前提下，按「全维综合评分 (45%脱靶+35%效率+20%序列)」从高到低排列。"
            case .combinedScoreDesc:
                return "严格按「全维综合评分 (0～100分)」从高到低排列，综合衡量全基因组脱靶数 (45%)、Doench 2016 切割效率 (35%) 与本地序列热力学规则 (20%)。"
            case .efficiencyDesc:
                return "按 CHOPCHOP 官方 Doench 2016 切割效率分从高到低排列（注意检查右侧脱靶数 MM0/MM1 是否为 0）。"
            case .rankAsc:
                return "CHOPCHOP 原始字典序排名：严格按 MM0 → MM1 → MM2 → MM3 从少到多排，同为 0/0/0/0 时才按效率分排序（因此有 1 个 MM2/MM3 的高分靶点会排在下面）。"
            case .offTargetAsc:
                return "按全基因组错配位点数 MM0 → MM1 → MM2 → MM3 由少到多排列。"
            }
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        AppState.shared.$localCompareTargets
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recomputeLocalMatches()
            }
            .store(in: &cancellables)
    }
    
    public func updateTarget(gene: String, species: TargetSpecies) {
        self.gene = gene
        self.species = species
    }
    
    /// 当前参与对比的「用户重点选中/生成/手动添加」的本地 SG/SH 序列
    public var activeUserLocalTargets: [LocalCompareTarget] {
        AppState.shared.localCompareTargets.filter { $0.isSelectedOrGenerated }
    }
    
    /// 手动添加一条或多条本地 sgRNA / shRNA 序列进行高亮对比
    public func addManualCompareSequence() {
        let raw = manualCompareInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",;\n\t "))
            .map { BioSequence.clean($0) }
            .filter { $0.count >= 15 }
        
        guard !parts.isEmpty else {
            AppState.shared.showToast("请输入至少 15 bp 的有效 sgRNA 或 shRNA 靶点序列")
            return
        }
        
        let existingCount = activeUserLocalTargets.count
        var newItems: [LocalCompareTarget] = []
        for (i, seq) in parts.enumerated() {
            let typeLabel: LocalCompareTarget.SourceType = (seq.count == 20) ? .sgRNA : (seq.count >= 21 ? .shRNA : .custom)
            newItems.append(LocalCompareTarget(
                label: "手动对比 #\(existingCount + i + 1)",
                sequence: seq,
                sourceType: typeLabel,
                isSelectedOrGenerated: true
            ))
        }
        AppState.shared.syncLocalCompareTargets(newItems, replaceSourceType: nil)
        manualCompareInput = ""
        recomputeLocalMatches()
        AppState.shared.showToast("已添加 \(newItems.count) 条序列至 CHOPCHOP 高亮对比池")
    }
    
    /// 移除单条本地对比序列
    public func removeLocalCompareTarget(_ item: LocalCompareTarget) {
        AppState.shared.localCompareTargets.removeAll { $0.id == item.id }
        recomputeLocalMatches()
    }
    
    /// 清空全部自定义/已选对比序列
    public func clearUserLocalCompareTargets() {
        AppState.shared.localCompareTargets.removeAll { $0.isSelectedOrGenerated }
        showOnlyLocalMatches = false
        recomputeLocalMatches()
    }
    
    /// 自动从本地 SQLite 文库补充同基因的 sgRNA 与 shRNA 候选，结合用户已选序列计算全部 CHOPCHOP 命中
    public func recomputeLocalMatches() {
        guard !targets.isEmpty else {
            matchMap = [:]
            return
        }
        
        var pool = AppState.shared.localCompareTargets
        let cleanGene = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanGene.isEmpty {
            let libSg = GenomicLibraryService.shared.search(query: cleanGene, species: species, type: .sgRNA)
            let libSh = GenomicLibraryService.shared.search(query: cleanGene, species: species, type: .shRNA)
            let existingSeqs = Set(pool.map { $0.cleanSequence })
            
            for sg in libSg where !existingSeqs.contains(sg.sequence.uppercased()) {
                pool.append(LocalCompareTarget(
                    label: "本地文库 sgRNA",
                    sequence: sg.sequence,
                    sourceType: .sgRNA,
                    isSelectedOrGenerated: false
                ))
            }
            for sh in libSh where !existingSeqs.contains(sh.sequence.uppercased()) {
                pool.append(LocalCompareTarget(
                    label: "本地文库 shRNA",
                    sequence: sh.sequence,
                    sourceType: .shRNA,
                    isSelectedOrGenerated: false
                ))
            }
        }
        
        var newMap: [Int: CHOPCHOPLocalMatchResult] = [:]
        for t in targets {
            if let m = t.matchAgainstLocalTargets(pool) {
                newMap[t.id] = m
            }
        }
        self.matchMap = newMap
    }
    
    /// 命中「用户已选/已生成引物」的 CHOPCHOP 靶点数量
    public var primaryMatchedTargetsCount: Int {
        matchMap.values.filter { $0.isPrimaryUserSelection }.count
    }
    
    /// 命中全部本地序列（含本地 SQLite 文库收录）的靶点数量
    public var totalMatchedTargetsCount: Int {
        matchMap.count
    }
    
    /// 查询某个本地对比序列在当前 CHOPCHOP 结果中命中的最佳靶点
    public func bestHitForLocalTarget(_ localTarget: LocalCompareTarget) -> CHOPCHOPTarget? {
        let singlePool = [localTarget]
        return targets.first { $0.matchAgainstLocalTargets(singlePool) != nil }
    }
    
    /// 执行 Python 后台查询 CHOPCHOP
    public func fetchTargets(forceRefresh: Bool = false) {
        let clean = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            errorMessage = "请输入需要查询的基因名称"
            showErrorAlert = true
            return
        }
        
        isLoading = true
        progressMessage = forceRefresh
            ? "正在忽略缓存向 CHOPCHOP 云端重新提交任务..."
            : "正在建立高速通道并查询 CHOPCHOP 全基因组靶点..."
        errorMessage = nil
        
        Task {
            do {
                let results = try await CHOPCHOPService.shared.queryTargets(
                    gene: clean,
                    species: species,
                    timeout: 55,
                    forceRefresh: forceRefresh,
                    progressHandler: { [weak self] msg in
                        self?.progressMessage = msg
                    }
                )
                
                self.targets = results
                self.recomputeLocalMatches()
                
                // 默认优先勾选本地命中的靶点，若无则勾选综合推荐前 5 条
                let primaryHits = self.sortedTargets.filter { self.matchMap[$0.id]?.isPrimaryUserSelection == true }
                if !primaryHits.isEmpty {
                    self.selectedTargetIDs = Set(primaryHits.map { $0.id })
                } else {
                    let topIDs = self.sortedTargets.prefix(5).map { $0.id }
                    self.selectedTargetIDs = Set(topIDs)
                }
                
                self.isLoading = false
                self.progressMessage = ""
                
                let hitCount = self.totalMatchedTargetsCount
                if hitCount > 0 {
                    AppState.shared.showToast("获取 \(results.count) 条 CHOPCHOP 靶点，其中 \(hitCount) 条与本地 SG/SH 序列重合！")
                } else {
                    AppState.shared.showToast("成功获取 \(results.count) 条 CHOPCHOP 全基因组预测靶点！")
                }
            } catch {
                self.isLoading = false
                self.progressMessage = ""
                self.errorMessage = error.localizedDescription
                self.showErrorAlert = true
                AppState.shared.showToast("查询失败: \(error.localizedDescription)")
            }
        }
    }
    
    /// 排序与筛选后的结果列表
    public var sortedTargets: [CHOPCHOPTarget] {
        let baseList: [CHOPCHOPTarget]
        if showOnlyLocalMatches {
            baseList = targets.filter { matchMap[$0.id] != nil }
        } else {
            baseList = targets
        }
        
        return baseList.sorted { a, b in
            // 当开启「本地命中优先置顶」或处于「智能推荐」模式时，将本地命中靶点优先排在最前面
            if pinLocalMatchesFirst || sortMode == .smartRecommend {
                let matchA = matchMap[a.id]
                let matchB = matchMap[b.id]
                let priA = matchA == nil ? 0 : (matchA!.isPrimaryUserSelection ? 2 : 1)
                let priB = matchB == nil ? 0 : (matchB!.isPrimaryUserSelection ? 2 : 1)
                if priA != priB {
                    return priA > priB
                }
            }
            
            switch sortMode {
            case .smartRecommend:
                // 优先保证无严重脱靶 (MM0 == 0 && MM1 == 0) 且无 TTTT 终止
                let safeA = a.isHighlySpecific && !a.combinedScore.hasFatalIssue
                let safeB = b.isHighlySpecific && !b.combinedScore.hasFatalIssue
                if safeA != safeB { return safeA && !safeB }
                if a.combinedScore.score != b.combinedScore.score {
                    return a.combinedScore.score > b.combinedScore.score
                }
                if a.efficiency != b.efficiency {
                    return a.efficiency > b.efficiency
                }
                return a.rank < b.rank
                
            case .combinedScoreDesc:
                if a.combinedScore.score != b.combinedScore.score {
                    return a.combinedScore.score > b.combinedScore.score
                }
                return a.efficiency > b.efficiency
                
            case .efficiencyDesc:
                if a.efficiency != b.efficiency {
                    return a.efficiency > b.efficiency
                }
                return a.rank < b.rank
                
            case .rankAsc:
                return a.rank < b.rank
                
            case .offTargetAsc:
                if a.mm0 != b.mm0 { return a.mm0 < b.mm0 }
                if a.mm1 != b.mm1 { return a.mm1 < b.mm1 }
                if a.mm2 != b.mm2 { return a.mm2 < b.mm2 }
                if a.mm3 != b.mm3 { return a.mm3 < b.mm3 }
                return a.efficiency > b.efficiency
            }
        }
    }
    
    public func selectAll() {
        selectedTargetIDs = Set(sortedTargets.map { $0.id })
    }
    
    public func deselectAll() {
        selectedTargetIDs.removeAll()
    }
    
    public func selectLocalHitsOnly() {
        let hitIDs = targets.filter { matchMap[$0.id] != nil }.map { $0.id }
        selectedTargetIDs = Set(hitIDs)
        AppState.shared.showToast("已勾选全部 \(hitIDs.count) 条本地命中靶点")
    }
    
    public func toggleTarget(_ target: CHOPCHOPTarget) {
        if selectedTargetIDs.contains(target.id) {
            selectedTargetIDs.remove(target.id)
        } else {
            selectedTargetIDs.insert(target.id)
        }
    }
    
    /// 复制 20bp Spacer
    public func copySpacer(_ target: CHOPCHOPTarget) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(target.spacer, forType: .string)
        AppState.shared.showToast("已复制 20bp Spacer: \(target.spacer)")
    }
    
    /// 为单条靶点生成配对引物并加入订购单
    public func addPairToCart(_ target: CHOPCHOPTarget) {
        let pair = CRISPRDesigner.designPair(
            target: target.spacer,
            geneName: gene,
            index: target.rank,
            prefix: "CHOP",
            species: species,
            vector: .lentiCRISPRv2
        )
        AppState.shared.addPrimersToCart([pair.fwdPrimer, pair.revPrimer])
        AppState.shared.showToast("已将 \(gene) sg#\(target.rank) 配对引物加入订购单！")
    }
    
    /// 将所有选中的靶点生成引物并加入订购单
    public func addSelectedToCart() {
        let selected = sortedTargets.filter { selectedTargetIDs.contains($0.id) }
        guard !selected.isEmpty else {
            AppState.shared.showToast("请至少勾选一条靶点")
            return
        }
        
        var primers: [PrimerItem] = []
        for t in selected {
            let pair = CRISPRDesigner.designPair(
                target: t.spacer,
                geneName: gene,
                index: t.rank,
                prefix: "CHOP",
                species: species,
                vector: .lentiCRISPRv2
            )
            primers.append(pair.fwdPrimer)
            primers.append(pair.revPrimer)
        }
        AppState.shared.addPrimersToCart(primers)
        AppState.shared.showToast("已将 \(selected.count) 个靶点 (\(primers.count) 条引物) 加入订购单！")
    }
    
    /// 在默认外部浏览器中打开原始网页
    public func openInSafari() {
        CHOPCHOPService.shared.openInDefaultBrowser(gene: gene, species: species)
    }
    
    /// 一键清空当前 CHOPCHOP 查询结果与状态
    public func clear() {
        gene = ""
        targets = []
        selectedTargetIDs = []
        matchMap = [:]
        manualCompareInput = ""
        showOnlyLocalMatches = false
        errorMessage = nil
        showErrorAlert = false
    }
}
