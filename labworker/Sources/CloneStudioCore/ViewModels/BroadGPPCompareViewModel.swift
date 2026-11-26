import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
public final class BroadGPPCompareViewModel: ObservableObject {
    public enum RegionFilter: String, CaseIterable, Identifiable, Sendable {
        case all = "全部"
        case cds = "CDS"
        case utr3 = "3'UTR"
        
        public var id: String { rawValue }
    }
    
    public enum BroadGPPSortMode: String, CaseIterable, Identifiable {
        case smartRecommend = "智能推荐 (本地命中+特异性+高分)"
        case adjustedScoreDesc = "Broad Adjusted 分 (降序)"
        case intrinsicScoreDesc = "Broad Intrinsic 分 (降序)"
        case combinedScoreDesc = "综合评分 (降序)"
        case transcriptCountDesc = "覆盖转录本数 (降序)"
        
        public var id: String { rawValue }
        
        public var ruleExplanation: String {
            switch self {
            case .smartRecommend:
                return L10n.t("优先置顶命中本地 TRC 文库/自定义 shRNA 的序列；其余优先展示不匹配其他基因且综合评分最高的 TRC 克隆。")
            case .adjustedScoreDesc:
                return L10n.t("严格按 Broad GPP 特异性校正分（Adjusted Score = Intrinsic Score × Specificity Factor）从高到低排列。")
            case .intrinsicScoreDesc:
                return L10n.t("按 Broad GPP 原始效能分（Intrinsic Score）从高到低排列。")
            case .combinedScoreDesc:
                return L10n.t("按融合物种特异性（45%）+ Broad 敲低效价（35%）+ 热力学与 Pol III 规则（20%）的综合评分降序排列。")
            case .transcriptCountDesc:
                return L10n.t("优先展示可覆盖当前基因最多野生型转录本异构体的 shRNA 克隆。")
            }
        }
    }
    
    @Published public var gene: String = ""
    @Published public var species: TargetSpecies = .human
    @Published public var isLoading: Bool = false
    @Published public var progressMessage: String = ""
    @Published public var resolvedGeneID: String? = nil
    @Published public var resolvedGeneSymbol: String? = nil
    @Published public var resolvedGeneDescription: String = ""
    @Published public var wtTranscriptCount: Int = 0
    @Published public var isNearMatchFallback: Bool = false
    @Published public var targets: [BroadGPPShRNATarget] = []
    @Published public var selectedTargetIDs: Set<String> = []
    @Published public var errorMessage: String? = nil
    @Published public var showErrorAlert: Bool = false
    
    @Published public var regionFilter: RegionFilter = .all
    @Published public var onlySpecific: Bool = false
    @Published public var manualCompareInput: String = ""
    @Published public var showOnlyLocalMatches: Bool = false
    @Published public var pinLocalMatchesFirst: Bool = true
    @Published public var matchMap: [String: CHOPCHOPLocalMatchResult] = [:]
    @Published public var sortMode: BroadGPPSortMode = .smartRecommend
    
    private var activeQueryToken = UUID()
    private var activeTask: Task<Void, Never>? = nil
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
    
    public var activeUserLocalTargets: [LocalCompareTarget] {
        AppState.shared.localCompareTargets.filter {
            $0.isSelectedOrGenerated && ($0.sourceType == .shRNA || $0.sourceType == .custom)
        }
    }
    
    public func addManualCompareSequence() {
        let raw = manualCompareInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",;\n\t "))
            .map { BioSequence.clean($0) }
            .filter { $0.count >= 15 }
        
        guard !parts.isEmpty else {
            AppState.shared.showToast("请输入至少 15 bp 的有效 shRNA 靶点序列")
            return
        }
        
        let existingCount = activeUserLocalTargets.count
        var newItems: [LocalCompareTarget] = []
        for (i, seq) in parts.enumerated() {
            newItems.append(LocalCompareTarget(
                label: L10n.tr("手动 sh#\(existingCount + i + 1)", "Manual sh#\(existingCount + i + 1)"),
                sequence: seq,
                sourceType: .shRNA,
                isSelectedOrGenerated: true
            ))
        }
        AppState.shared.syncLocalCompareTargets(newItems, replaceSourceType: nil)
        manualCompareInput = ""
        recomputeLocalMatches()
        AppState.shared.showToast(L10n.tr("已添加 \(newItems.count) 条 shRNA 序列至 Broad GPP 高亮对比池", "Added \(newItems.count) shRNA sequence(s) to Broad GPP comparison"))
    }
    
    public func removeLocalCompareTarget(_ item: LocalCompareTarget) {
        AppState.shared.localCompareTargets.removeAll { $0.id == item.id }
        recomputeLocalMatches()
    }
    
    public func clearUserLocalCompareTargets() {
        AppState.shared.localCompareTargets.removeAll {
            $0.isSelectedOrGenerated && ($0.sourceType == .shRNA || $0.sourceType == .custom)
        }
        recomputeLocalMatches()
        AppState.shared.showToast("已清空手动对比的 shRNA 序列")
    }
    
    public func bestHitForLocalTarget(_ localTarget: LocalCompareTarget) -> BroadGPPShRNATarget? {
        for target in targets {
            if let hit = target.matchAgainstLocalTargets([localTarget]),
               case .exact = hit.kind {
                return target
            }
        }
        for target in targets {
            if target.matchAgainstLocalTargets([localTarget]) != nil {
                return target
            }
        }
        return nil
    }
    
    public func recomputeLocalMatches() {
        guard !targets.isEmpty else {
            matchMap = [:]
            return
        }
        var pool = AppState.shared.localCompareTargets.filter {
            $0.sourceType == .shRNA || $0.sourceType == .custom
        }
        let cleanGene = (resolvedGeneSymbol ?? gene).trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanGene.isEmpty {
            let libSh = GenomicLibraryService.shared.search(query: cleanGene, species: species, type: .shRNA)
            let existingSeqs = Set(pool.map { $0.cleanSequence })
            for sh in libSh where !existingSeqs.contains(sh.sequence.uppercased()) {
                pool.append(LocalCompareTarget(
                    label: L10n.t("本地文库 shRNA"),
                    sequence: sh.sequence,
                    sourceType: .shRNA,
                    isSelectedOrGenerated: false
                ))
            }
        }
        guard !pool.isEmpty else {
            matchMap = [:]
            return
        }
        var map: [String: CHOPCHOPLocalMatchResult] = [:]
        for t in targets {
            if let match = t.matchAgainstLocalTargets(pool) {
                map[t.id] = match
            }
        }
        self.matchMap = map
    }
    
    public func fetchTargets(forceRefresh: Bool = false) {
        let clean = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            errorMessage = L10n.t("请输入需要查询的基因名或 NCBI ID")
            showErrorAlert = true
            return
        }
        
        activeTask?.cancel()
        let token = UUID()
        activeQueryToken = token
        let targetSpecies = species
        
        isLoading = true
        progressMessage = L10n.tr("正在从 Broad GPP Public Portal 检索「\(clean)」...", "Querying Broad GPP Public Portal for \"\(clean)\"...")
        errorMessage = nil
        
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let res = try await BroadGPPService.shared.queryTargets(
                    gene: clean,
                    species: targetSpecies,
                    forceRefresh: forceRefresh
                )
                guard self.activeQueryToken == token, !Task.isCancelled else { return }
                self.resolvedGeneID = res.geneID
                self.resolvedGeneSymbol = res.geneSymbol
                self.resolvedGeneDescription = res.geneDescription
                self.wtTranscriptCount = res.wtTranscriptCount
                self.isNearMatchFallback = res.isNearMatchFallback
                self.targets = res.targets
                self.recomputeLocalMatches()
                
                let primaryHits = self.sortedTargets.filter { self.matchMap[$0.id]?.isPrimaryUserSelection == true }
                if !primaryHits.isEmpty {
                    self.selectedTargetIDs = Set(primaryHits.map(\.id))
                } else {
                    let topSpecific = self.sortedTargets.filter(\.isHighlySpecific).prefix(3)
                    self.selectedTargetIDs = topSpecific.isEmpty
                        ? Set(self.sortedTargets.prefix(3).map(\.id))
                        : Set(topSpecific.map(\.id))
                }
                self.isLoading = false
                self.progressMessage = ""
                
                let hitCount = self.matchMap.count
                if hitCount > 0 {
                    AppState.shared.showToast(L10n.tr("Broad GPP 已加载 \(res.targets.count) 条 TRC shRNA（命中本地 \(hitCount) 条）", "Loaded \(res.targets.count) Broad GPP TRC shRNAs (\(hitCount) local hit(s))"))
                } else {
                    AppState.shared.showToast(L10n.tr("Broad GPP 已加载 \(res.targets.count) 条 \(res.geneSymbol) TRC shRNA", "Loaded \(res.targets.count) TRC shRNAs for \(res.geneSymbol)"))
                }
            } catch {
                guard self.activeQueryToken == token, !Task.isCancelled else { return }
                self.isLoading = false
                self.progressMessage = ""
                self.errorMessage = error.localizedDescription
                AppState.shared.showToast("Broad GPP 检索失败")
            }
        }
    }
    
    public var totalMatchedTargetsCount: Int {
        matchMap.count
    }
    
    public var cdsCount: Int {
        targets.filter(\.isCDS).count
    }
    
    public var utr3Count: Int {
        targets.filter(\.is3UTR).count
    }
    
    public var specificCount: Int {
        targets.filter(\.isHighlySpecific).count
    }
    
    public var sortedTargets: [BroadGPPShRNATarget] {
        var list = targets
        switch regionFilter {
        case .all:
            break
        case .cds:
            list = list.filter(\.isCDS)
        case .utr3:
            list = list.filter(\.is3UTR)
        }
        if onlySpecific {
            list = list.filter { !$0.matchesOtherGene }
        }
        if showOnlyLocalMatches && !matchMap.isEmpty {
            list = list.filter { matchMap[$0.id] != nil }
        }
        
        return list.sorted { a, b in
            if pinLocalMatchesFirst && !matchMap.isEmpty {
                let mA = matchMap[a.id]
                let mB = matchMap[b.id]
                let pA = (mA != nil) ? (mA!.isPrimaryUserSelection ? 2 : 1) : 0
                let pB = (mB != nil) ? (mB!.isPrimaryUserSelection ? 2 : 1) : 0
                if pA != pB { return pA > pB }
                if let kA = mA, let kB = mB, kA.kind.priority != kB.kind.priority {
                    return kA.kind.priority > kB.kind.priority
                }
            }
            
            switch sortMode {
            case .smartRecommend:
                if a.matchesOtherGene != b.matchesOtherGene {
                    return !a.matchesOtherGene && b.matchesOtherGene
                }
                if a.combinedScore.score != b.combinedScore.score {
                    return a.combinedScore.score > b.combinedScore.score
                }
                return (a.adjustedScore ?? 0) > (b.adjustedScore ?? 0)
                
            case .adjustedScoreDesc:
                let adjA = a.adjustedScore ?? -1
                let adjB = b.adjustedScore ?? -1
                if adjA != adjB { return adjA > adjB }
                return (a.intrinsicScore ?? -1) > (b.intrinsicScore ?? -1)
                
            case .intrinsicScoreDesc:
                let intrA = a.intrinsicScore ?? -1
                let intrB = b.intrinsicScore ?? -1
                if intrA != intrB { return intrA > intrB }
                return (a.adjustedScore ?? -1) > (b.adjustedScore ?? -1)
                
            case .combinedScoreDesc:
                if a.combinedScore.score != b.combinedScore.score {
                    return a.combinedScore.score > b.combinedScore.score
                }
                return (a.adjustedScore ?? -1) > (b.adjustedScore ?? -1)
                
            case .transcriptCountDesc:
                if a.transcriptCount != b.transcriptCount {
                    return a.transcriptCount > b.transcriptCount
                }
                return (a.adjustedScore ?? -1) > (b.adjustedScore ?? -1)
            }
        }
    }
    
    public func selectAll() {
        selectedTargetIDs = Set(sortedTargets.map(\.id))
    }
    
    public func deselectAll() {
        selectedTargetIDs.removeAll()
    }
    
    public func selectLocalHitsOnly() {
        let hitIDs = targets.filter { matchMap[$0.id] != nil }.map(\.id)
        selectedTargetIDs = Set(hitIDs)
        AppState.shared.showToast(L10n.tr("已勾选全部 \(hitIDs.count) 条本地命中克隆", "Selected all \(hitIDs.count) matching local clone(s)"))
    }
    
    public func toggleTarget(_ target: BroadGPPShRNATarget) {
        if selectedTargetIDs.contains(target.id) {
            selectedTargetIDs.remove(target.id)
        } else {
            selectedTargetIDs.insert(target.id)
        }
    }
    
    public func copyTargetSequence(_ target: BroadGPPShRNATarget) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(target.targetSequence, forType: .string)
        AppState.shared.showToast(L10n.tr("已复制 21bp 靶点序列: \(target.targetSequence)", "Copied 21-bp target: \(target.targetSequence)"))
    }
    
    public func copyOfficialBroadOligos(_ target: BroadGPPShRNATarget) {
        let text: String
        if !target.forwardOligo.isEmpty && !target.reverseOligo.isEmpty {
            text = "\(target.primaryCloneID)_F\t\(target.forwardOligo)\n\(target.primaryCloneID)_R\t\(target.reverseOligo)"
        } else {
            let pair = ShRNADesigner.designPair(target: target.targetSequence, geneName: resolvedGeneSymbol ?? gene, index: target.rank, species: species)
            text = "\(pair.fwdPrimer.name)\t\(pair.fwdPrimer.fullSequence)\n\(pair.revPrimer.name)\t\(pair.revPrimer.fullSequence)"
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        AppState.shared.showToast(L10n.tr("已复制 \(target.primaryCloneID) 正反向克隆 Oligo", "Copied cloning oligos for \(target.primaryCloneID)"))
    }
    
    public func addPairToCart(_ target: BroadGPPShRNATarget, loop: String = ShRNADesigner.defaultLoop, prefix: String = "") {
        let geneName = resolvedGeneSymbol ?? (gene.isEmpty ? "shTarget" : gene)
        var pair = ShRNADesigner.designPair(
            target: target.targetSequence,
            geneName: geneName,
            index: target.rank,
            prefix: prefix.isEmpty ? target.primaryCloneID : prefix,
            species: species,
            loop: loop
        )
        let extra = " | Broad TRC: \(target.primaryCloneID)"
        pair = ShRNADesigner.PairResult(
            fwdPrimer: PrimerItem(
                name: pair.fwdPrimer.name,
                fullSequence: pair.fwdPrimer.fullSequence,
                homologyArm: pair.fwdPrimer.homologyArm,
                specificSequence: pair.fwdPrimer.specificSequence,
                tm: pair.fwdPrimer.tm,
                targetPurpose: pair.fwdPrimer.targetPurpose,
                notes: pair.fwdPrimer.notes + extra,
                sourceTool: pair.fwdPrimer.sourceTool
            ),
            revPrimer: PrimerItem(
                name: pair.revPrimer.name,
                fullSequence: pair.revPrimer.fullSequence,
                homologyArm: pair.revPrimer.homologyArm,
                specificSequence: pair.revPrimer.specificSequence,
                tm: pair.revPrimer.tm,
                targetPurpose: pair.revPrimer.targetPurpose,
                notes: pair.revPrimer.notes + extra,
                sourceTool: pair.revPrimer.sourceTool
            )
        )
        AppState.shared.addPrimersToCart([pair.fwdPrimer, pair.revPrimer])
        AppState.shared.showToast(L10n.tr("已将 \(target.primaryCloneID) 发夹引物加入订购单", "Added \(target.primaryCloneID) hairpin primers to order cart"))
    }
    
    public func addSelectedToCart(loop: String = ShRNADesigner.defaultLoop, prefix: String = "") {
        let selected = sortedTargets.filter { selectedTargetIDs.contains($0.id) }
        guard !selected.isEmpty else {
            AppState.shared.showToast("请至少勾选一条 TRC shRNA 克隆")
            return
        }
        let geneName = resolvedGeneSymbol ?? (gene.isEmpty ? "shTarget" : gene)
        var primers: [PrimerItem] = []
        for t in selected {
            let pair = ShRNADesigner.designPair(
                target: t.targetSequence,
                geneName: geneName,
                index: t.rank,
                prefix: prefix.isEmpty ? t.primaryCloneID : prefix,
                species: species,
                loop: loop
            )
            let extra = " | Broad TRC: \(t.primaryCloneID)"
            primers.append(PrimerItem(
                name: pair.fwdPrimer.name,
                fullSequence: pair.fwdPrimer.fullSequence,
                homologyArm: pair.fwdPrimer.homologyArm,
                specificSequence: pair.fwdPrimer.specificSequence,
                tm: pair.fwdPrimer.tm,
                targetPurpose: pair.fwdPrimer.targetPurpose,
                notes: pair.fwdPrimer.notes + extra,
                sourceTool: pair.fwdPrimer.sourceTool
            ))
            primers.append(PrimerItem(
                name: pair.revPrimer.name,
                fullSequence: pair.revPrimer.fullSequence,
                homologyArm: pair.revPrimer.homologyArm,
                specificSequence: pair.revPrimer.specificSequence,
                tm: pair.revPrimer.tm,
                targetPurpose: pair.revPrimer.targetPurpose,
                notes: pair.revPrimer.notes + extra,
                sourceTool: pair.revPrimer.sourceTool
            ))
        }
        AppState.shared.addPrimersToCart(primers)
        AppState.shared.showToast(L10n.tr("已将 \(selected.count) 个 Broad TRC 克隆 (\(primers.count) 条引物) 加入订购单", "Added \(selected.count) Broad TRC clone(s) (\(primers.count) primers) to order cart"))
    }
    
    public func openGeneInSafari() {
        BroadGPPService.shared.openInDefaultBrowser(geneID: resolvedGeneID)
    }
    
    public func openCloneInSafari(_ target: BroadGPPShRNATarget) {
        BroadGPPService.shared.openCloneInDefaultBrowser(cloneID: target.primaryCloneID)
    }
    
    public func clear() {
        activeTask?.cancel()
        activeTask = nil
        activeQueryToken = UUID()
        gene = ""
        isLoading = false
        progressMessage = ""
        resolvedGeneID = nil
        resolvedGeneSymbol = nil
        resolvedGeneDescription = ""
        wtTranscriptCount = 0
        isNearMatchFallback = false
        targets = []
        selectedTargetIDs = []
        matchMap = [:]
        manualCompareInput = ""
        regionFilter = .all
        onlySpecific = false
        showOnlyLocalMatches = false
        errorMessage = nil
        showErrorAlert = false
    }
}
