import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
public final class CHOPCHOPCompareViewModel: ObservableObject {
    public enum SourceFilter: String, CaseIterable, Identifiable, Sendable {
        case all = "全部"
        case consensus = "多源共识"
        case vbcScore = "VBC"
        case ucscCrispor = "CRISPOR"
        case chopchop = "CHOPCHOP"
        
        public var id: String { rawValue }
    }
    
    public enum SourceQueryState: Equatable, Sendable {
        case idle
        case loading(String)
        case loaded(Int)
        case failed(String)
        
        public var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
        
        public var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
        
        public var errorMessage: String? {
            if case .failed(let msg) = self { return msg }
            return nil
        }
        
        public var loadedCount: Int? {
            if case .loaded(let cnt) = self { return cnt }
            return nil
        }
    }
    
    @Published public var gene: String = ""
    @Published public var species: TargetSpecies = .human
    @Published public var isLoading: Bool = false
    @Published public var progressMessage: String = ""
    @Published public var targets: [CHOPCHOPTarget] = []
    @Published public var selectedTargetIDs: Set<Int> = []
    @Published public var errorMessage: String? = nil
    @Published public var showErrorAlert: Bool = false
    
    // 多数据源并发检索与共识状态（VBC-Score + UCSC CRISPOR + CHOPCHOP）
    @Published public var enabledSources: Set<TargetCompareSource> = [.vbcScore, .ucscCrispor, .chopchop]
    @Published public var activeSourceFilter: SourceFilter = .all
    @Published public var sourceStates: [TargetCompareSource: SourceQueryState] = [:]
    @Published public var lastCHOPCHOPJobId: String? = nil
    @Published public var lastUCSCSpan: String? = nil
    
    // 本地 sgRNA / shRNA 序列高亮对比状态
    @Published public var manualCompareInput: String = ""
    @Published public var showOnlyLocalMatches: Bool = false
    @Published public var pinLocalMatchesFirst: Bool = true
    @Published public var matchMap: [Int: CHOPCHOPLocalMatchResult] = [:]
    
    // 排序模式（保留原有 rawValue 并扩展多源共识 / VBC-Score 排序）
    @Published public var sortMode: CHOPCHOPSortMode = .smartRecommend
    
    public enum CHOPCHOPSortMode: String, CaseIterable, Identifiable {
        case smartRecommend = "智能推荐 (本地命中+零核心脱靶+高分优先)"
        case consensusFirst = "多源共识优先 (跨站重合+高分)"
        case vbcScoreDesc = "VBC-Score 敲除分 (降序)"
        case combinedScoreDesc = "全维综合评分 (从高到低)"
        case efficiencyDesc = "Doench 切割效率分 (降序)"
        case rankAsc = "CHOPCHOP 原始排名 (#Rank 严苛脱靶序)"
        case offTargetAsc = "脱靶错配最少优先 (MM0～MM3)"
        
        public var id: String { rawValue }
        
        public var ruleExplanation: String {
            switch self {
            case .smartRecommend:
                return L10n.t("优先置顶「本地已选 SG/SH 命中序列」；其余靶点在保证核心特异性前提下，按融合了多源共识加分的全维综合评分从高到低排列。")
            case .consensusFirst:
                return L10n.t("优先展示同时被 3 个或 2 个在线网站命中的高共识 sgRNA，再按全维综合评分降序排列。")
            case .vbcScoreDesc:
                return L10n.t("按 VBC-Score 敲除效能综合分（整合活性、inDelphi 移码率与 Bioscore 蛋白保守度）从高到低排列。")
            case .combinedScoreDesc:
                return L10n.t("严格按全维综合评分（特异性 45% + 效率 35% + 本地序列规则 20% + 多源共识加分）从高到低排列。")
            case .efficiencyDesc:
                return L10n.t("按在线切割效率分（Doench 2016 / CRISPOR 百分位 / VBC 活性）从高到低排列。")
            case .rankAsc:
                return L10n.t("按 CHOPCHOP 原始排名（MM0 → MM1 → MM2 → MM3 从少到多）排列。")
            case .offTargetAsc:
                return L10n.t("按全基因组脱靶错配数（MM0-3 / VBC VeryLikely / MIT 特异性）从最安全到次优排列。")
            }
        }
    }
    
    private var rawCHOPCHOPTargets: [CHOPCHOPTarget] = []
    private var rawVBCTargets: [CHOPCHOPTarget] = []
    private var rawCRISPORTargets: [CHOPCHOPTarget] = []
    private var activeQueryToken = UUID()
    private var activeQueryTasks: [TargetCompareSource: Task<Void, Never>] = [:]
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
    
    /// 当前参与对比的「用户重点选中/生成/手动添加」的本地 SG 序列
    public var activeUserLocalTargets: [LocalCompareTarget] {
        AppState.shared.localCompareTargets.filter {
            $0.isSelectedOrGenerated && ($0.sourceType == .sgRNA || $0.sourceType == .custom)
        }
    }
    
    /// 手动添加一条或多条本地 sgRNA 序列进行高亮对比
    public func addManualCompareSequence() {
        let raw = manualCompareInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",;\n\t "))
            .map { BioSequence.clean($0) }
            .filter { $0.count >= 15 }
        
        guard !parts.isEmpty else {
            AppState.shared.showToast("请输入至少 15 bp 的有效 sgRNA 靶点序列")
            return
        }
        
        let existingCount = activeUserLocalTargets.count
        var newItems: [LocalCompareTarget] = []
        for (i, seq) in parts.enumerated() {
            newItems.append(LocalCompareTarget(
                label: L10n.tr("手动 sg#\(existingCount + i + 1)", "Manual sg#\(existingCount + i + 1)"),
                sequence: seq,
                sourceType: .sgRNA,
                isSelectedOrGenerated: true
            ))
        }
        AppState.shared.syncLocalCompareTargets(newItems, replaceSourceType: nil)
        manualCompareInput = ""
        recomputeLocalMatches()
        AppState.shared.showToast(L10n.tr("已添加 \(newItems.count) 条序列至在线对比高亮池", "Added \(newItems.count) sequence(s) to online comparison"))
    }
    
    /// 移除单条本地对比序列
    public func removeLocalCompareTarget(_ item: LocalCompareTarget) {
        AppState.shared.localCompareTargets.removeAll { $0.id == item.id }
        recomputeLocalMatches()
    }
    
    /// 清空全部自定义/已选 SG 对比序列
    public func clearUserLocalCompareTargets() {
        AppState.shared.localCompareTargets.removeAll {
            $0.isSelectedOrGenerated && ($0.sourceType == .sgRNA || $0.sourceType == .custom)
        }
        showOnlyLocalMatches = false
        recomputeLocalMatches()
    }
    
    /// 自动从本地 SQLite 文库补充同基因的 sgRNA 候选，结合用户已选序列计算全部命中
    public func recomputeLocalMatches() {
        guard !targets.isEmpty else {
            matchMap = [:]
            return
        }
        
        var pool = AppState.shared.localCompareTargets.filter {
            $0.sourceType == .sgRNA || $0.sourceType == .custom
        }
        let cleanGene = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanGene.isEmpty {
            let libSg = GenomicLibraryService.shared.search(query: cleanGene, species: species, type: .sgRNA)
            let existingSeqs = Set(pool.map { $0.cleanSequence })
            
            for sg in libSg where !existingSeqs.contains(sg.sequence.uppercased()) {
                pool.append(LocalCompareTarget(
                    label: L10n.t("本地文库 sgRNA"),
                    sequence: sg.sequence,
                    sourceType: .sgRNA,
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
    
    public var consensusTargetsCount: Int {
        targets.filter(\.isMultiSourceConsensus).count
    }
    
    public func targetCount(for source: TargetCompareSource) -> Int {
        targets.filter { $0.sources.contains(source) }.count
    }
    
    /// 切换参与并发比对的在线数据源（至少保留 1 个数据源）
    public func toggleSource(_ source: TargetCompareSource) {
        if enabledSources.contains(source) {
            guard enabledSources.count > 1 else {
                AppState.shared.showToast("至少保留一个在线靶点数据源")
                return
            }
            enabledSources.remove(source)
            activeQueryTasks[source]?.cancel()
            activeQueryTasks[source] = nil
            sourceStates[source] = .idle
            switch source {
            case .chopchop: rawCHOPCHOPTargets = []
            case .vbcScore: rawVBCTargets = []
            case .ucscCrispor: rawCRISPORTargets = []
            }
            if activeSourceFilter == .vbcScore && source == .vbcScore
                || activeSourceFilter == .ucscCrispor && source == .ucscCrispor
                || activeSourceFilter == .chopchop && source == .chopchop {
                activeSourceFilter = .all
            }
            if !rawCHOPCHOPTargets.isEmpty || !rawVBCTargets.isEmpty || !rawCRISPORTargets.isEmpty {
                mergeAndPublishResults(isInitialBatch: false)
            } else if !targets.isEmpty {
                targets = []
                selectedTargetIDs = []
                matchMap = [:]
            }
            refreshLoadingSummary()
        } else {
            enabledSources.insert(source)
            let clean = gene.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !targets.isEmpty {
                retrySource(source, forceRefresh: false)
            }
        }
    }
    
    /// 并发查询所选在线数据源并按 20bp Spacer 实时合并
    public func fetchTargets(forceRefresh: Bool = false) {
        let clean = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            errorMessage = L10n.t("请输入需要查询的基因名称")
            showErrorAlert = true
            return
        }
        if enabledSources.isEmpty {
            enabledSources = [.vbcScore, .ucscCrispor]
        }
        
        cancelAllActiveTasks()
        let token = UUID()
        activeQueryToken = token
        
        rawCHOPCHOPTargets = []
        rawVBCTargets = []
        rawCRISPORTargets = []
        targets = []
        selectedTargetIDs = []
        matchMap = [:]
        lastCHOPCHOPJobId = nil
        lastUCSCSpan = nil
        activeSourceFilter = .all
        errorMessage = nil
        
        for src in TargetCompareSource.allCases {
            if enabledSources.contains(src) {
                sourceStates[src] = .loading(L10n.tr("正在连接 \(src.rawValue)...", "Connecting to \(src.rawValue)..."))
            } else {
                sourceStates[src] = .idle
            }
        }
        isLoading = true
        refreshLoadingSummary()
        
        for src in TargetCompareSource.allCases where enabledSources.contains(src) {
            launchSourceTask(src, gene: clean, species: species, forceRefresh: forceRefresh, token: token, notifyCompletion: true)
        }
    }
    
    /// 单独重试或补查某一个数据源（不影响已返回的其余数据源结果）
    public func retrySource(_ source: TargetCompareSource, forceRefresh: Bool = true) {
        let clean = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        enabledSources.insert(source)
        activeQueryTasks[source]?.cancel()
        let token = activeQueryToken
        sourceStates[source] = .loading(L10n.tr("正在重新查询 \(source.rawValue)...", "Retrying \(source.rawValue)..."))
        isLoading = true
        refreshLoadingSummary()
        launchSourceTask(source, gene: clean, species: species, forceRefresh: forceRefresh, token: token, notifyCompletion: false)
    }
    
    private func launchSourceTask(
        _ source: TargetCompareSource,
        gene clean: String,
        species targetSpecies: TargetSpecies,
        forceRefresh: Bool,
        token: UUID,
        notifyCompletion: Bool
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                switch source {
                case .vbcScore:
                    let list = try await CHOPCHOPService.shared.queryVBCScoreTargets(
                        gene: clean,
                        species: targetSpecies,
                        forceRefresh: forceRefresh
                    )
                    guard self.activeQueryToken == token, !Task.isCancelled else { return }
                    self.rawVBCTargets = list
                    self.sourceStates[.vbcScore] = .loaded(list.count)
                    self.mergeAndPublishResults(isInitialBatch: self.targets.isEmpty)
                    
                case .ucscCrispor:
                    let res = try await CHOPCHOPService.shared.queryUCSCCrisporTargets(
                        gene: clean,
                        species: targetSpecies,
                        forceRefresh: forceRefresh
                    )
                    guard self.activeQueryToken == token, !Task.isCancelled else { return }
                    self.lastUCSCSpan = res.genomicSpan
                    self.rawCRISPORTargets = res.targets
                    self.sourceStates[.ucscCrispor] = .loaded(res.targets.count)
                    self.mergeAndPublishResults(isInitialBatch: self.targets.isEmpty)
                    
                case .chopchop:
                    let res = try await CHOPCHOPService.shared.queryCHOPCHOPWithMetadata(
                        gene: clean,
                        species: targetSpecies,
                        timeout: 75,
                        forceRefresh: forceRefresh,
                        progressHandler: { [weak self] msg in
                            guard let self, self.activeQueryToken == token else { return }
                            self.sourceStates[.chopchop] = .loading(msg)
                            self.refreshLoadingSummary()
                        }
                    )
                    guard self.activeQueryToken == token, !Task.isCancelled else { return }
                    if let jid = res.jobId, !jid.isEmpty {
                        self.lastCHOPCHOPJobId = jid
                    }
                    self.rawCHOPCHOPTargets = res.targets
                    self.sourceStates[.chopchop] = .loaded(res.targets.count)
                    self.mergeAndPublishResults(isInitialBatch: self.targets.isEmpty)
                }
            } catch {
                guard self.activeQueryToken == token, !Task.isCancelled else { return }
                self.sourceStates[source] = .failed(error.localizedDescription)
            }
            
            guard self.activeQueryToken == token, !Task.isCancelled else { return }
            self.activeQueryTasks[source] = nil
            self.finalizeBatchIfAllFinished(token: token, singleSourceCompleted: notifyCompletion ? nil : source)
        }
        activeQueryTasks[source] = task
    }
    
    private func cancelAllActiveTasks() {
        for task in activeQueryTasks.values {
            task.cancel()
        }
        activeQueryTasks.removeAll()
    }
    
    private func mergeAndPublishResults(isInitialBatch: Bool) {
        let prevSelectedSpacers = Set(
            targets.filter { selectedTargetIDs.contains($0.id) }.map { $0.spacer.uppercased() }
        )
        let merged = CHOPCHOPTarget.mergeTargets(
            chopchop: rawCHOPCHOPTargets,
            vbc: rawVBCTargets,
            crispor: rawCRISPORTargets
        )
        self.targets = merged
        self.recomputeLocalMatches()
        
        if !prevSelectedSpacers.isEmpty && !isInitialBatch {
            let kept = Set(merged.filter { prevSelectedSpacers.contains($0.spacer.uppercased()) }.map(\.id))
            if !kept.isEmpty {
                self.selectedTargetIDs = kept
                return
            }
        }
        
        let primaryHits = self.sortedTargets.filter { self.matchMap[$0.id]?.isPrimaryUserSelection == true }
        if !primaryHits.isEmpty {
            self.selectedTargetIDs = Set(primaryHits.map(\.id))
        } else {
            self.selectedTargetIDs = Set(self.sortedTargets.prefix(5).map(\.id))
        }
    }
    
    private func refreshLoadingSummary() {
        let loadingPairs = TargetCompareSource.allCases.compactMap { src -> (TargetCompareSource, String)? in
            guard enabledSources.contains(src), case .loading(let msg) = sourceStates[src] else { return nil }
            return (src, msg)
        }
        isLoading = !loadingPairs.isEmpty
        if loadingPairs.count == 1, let only = loadingPairs.first {
            progressMessage = "[\(only.0.shortTitle)] \(only.1)"
        } else if !loadingPairs.isEmpty {
            let names = loadingPairs.map(\.0.shortTitle).joined(separator: " / ")
            progressMessage = L10n.tr("正在并发检索 \(names)...", "Querying \(names) in parallel...")
        } else {
            progressMessage = ""
        }
    }
    
    private func finalizeBatchIfAllFinished(token: UUID, singleSourceCompleted: TargetCompareSource?) {
        guard activeQueryToken == token else { return }
        refreshLoadingSummary()
        guard !isLoading else { return }
        
        let failedList = TargetCompareSource.allCases.compactMap { src -> (TargetCompareSource, String)? in
            guard enabledSources.contains(src), case .failed(let msg) = sourceStates[src] else { return nil }
            return (src, msg)
        }
        let succeededSources = TargetCompareSource.allCases.filter { src in
            enabledSources.contains(src) && (sourceStates[src]?.loadedCount != nil)
        }
        
        if let single = singleSourceCompleted {
            if let err = sourceStates[single]?.errorMessage {
                AppState.shared.showToast(L10n.tr("\(single.rawValue) 重试失败: \(err)", "\(single.rawValue) retry failed: \(err)"))
            } else {
                AppState.shared.showToast(L10n.tr("\(single.rawValue) 已补全并合并，当前共 \(targets.count) 条靶点", "\(single.rawValue) merged; \(targets.count) total targets"))
            }
            return
        }
        
        if targets.isEmpty {
            if !failedList.isEmpty {
                let joined = failedList.map { "[\($0.0.rawValue)] \($0.1)" }.joined(separator: "\n")
                self.errorMessage = joined
                self.showErrorAlert = true
                AppState.shared.showToast("在线靶点检索失败")
            } else {
                AppState.shared.showToast(L10n.tr("未检索到基因「\(gene)」的候选靶点", "No candidate targets found for \"\(gene)\""))
            }
            return
        }
        
        let hitCount = totalMatchedTargetsCount
        let consensus = consensusTargetsCount
        if !failedList.isEmpty {
            let okNames = succeededSources.map(\.shortTitle).joined(separator: "+")
            let failNames = failedList.map(\.0.shortTitle).joined(separator: "/")
            AppState.shared.showToast(L10n.tr("\(okNames) 已返回 \(targets.count) 条靶点；\(failNames) 暂未就绪", "\(okNames) returned \(targets.count) targets; \(failNames) unavailable"))
        } else if hitCount > 0 {
            AppState.shared.showToast(L10n.tr("共 \(targets.count) 条靶点（多源共识 \(consensus) 条，本地重合 \(hitCount) 条）", "\(targets.count) targets (\(consensus) consensus, \(hitCount) local hits)"))
        } else {
            AppState.shared.showToast(L10n.tr("共获取 \(targets.count) 条候选靶点（多源共识 \(consensus) 条）", "Fetched \(targets.count) targets (\(consensus) consensus)"))
        }
    }
    
    /// 排序与筛选后的结果列表
    public var sortedTargets: [CHOPCHOPTarget] {
        var baseList = targets
        if showOnlyLocalMatches {
            baseList = baseList.filter { matchMap[$0.id] != nil }
        }
        switch activeSourceFilter {
        case .all:
            break
        case .consensus:
            baseList = baseList.filter(\.isMultiSourceConsensus)
        case .vbcScore:
            baseList = baseList.filter { $0.sources.contains(.vbcScore) }
        case .ucscCrispor:
            baseList = baseList.filter { $0.sources.contains(.ucscCrispor) }
        case .chopchop:
            baseList = baseList.filter { $0.sources.contains(.chopchop) }
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
                let safeA = a.isHighlySpecific && !a.combinedScore.hasFatalIssue
                let safeB = b.isHighlySpecific && !b.combinedScore.hasFatalIssue
                if safeA != safeB { return safeA && !safeB }
                if a.combinedScore.score != b.combinedScore.score {
                    return a.combinedScore.score > b.combinedScore.score
                }
                if a.sources.count != b.sources.count {
                    return a.sources.count > b.sources.count
                }
                if a.efficiency != b.efficiency {
                    return a.efficiency > b.efficiency
                }
                return a.rank < b.rank
                
            case .consensusFirst:
                if a.sources.count != b.sources.count {
                    return a.sources.count > b.sources.count
                }
                if a.combinedScore.score != b.combinedScore.score {
                    return a.combinedScore.score > b.combinedScore.score
                }
                return a.efficiency > b.efficiency
                
            case .vbcScoreDesc:
                let vA = a.vbcScore ?? -1
                let vB = b.vbcScore ?? -1
                if vA != vB { return vA > vB }
                if a.combinedScore.score != b.combinedScore.score {
                    return a.combinedScore.score > b.combinedScore.score
                }
                return a.efficiency > b.efficiency
                
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
                let rA = a.chopchopRank ?? a.rank
                let rB = b.chopchopRank ?? b.rank
                return rA < rB
                
            case .offTargetAsc:
                if a.mm0 != b.mm0 { return a.mm0 < b.mm0 }
                if a.mm1 != b.mm1 { return a.mm1 < b.mm1 }
                if a.mm2 != b.mm2 { return a.mm2 < b.mm2 }
                if a.mm3 != b.mm3 { return a.mm3 < b.mm3 }
                let vlA = a.vbcVeryLikelyOT ?? 0
                let vlB = b.vbcVeryLikelyOT ?? 0
                if vlA != vlB { return vlA < vlB }
                let mA = a.mitSpecificity ?? 0
                let mB = b.mitSpecificity ?? 0
                if mA != mB { return mA > mB }
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
        AppState.shared.showToast(L10n.tr("已勾选全部 \(hitIDs.count) 条本地命中靶点", "Selected all \(hitIDs.count) matching local target(s)"))
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
        AppState.shared.showToast(L10n.tr("已复制 20bp Spacer: \(target.spacer)", "Copied 20-bp Spacer: \(target.spacer)"))
    }
    
    /// 为单条靶点生成配对引物并加入订购单
    public func addPairToCart(
        _ target: CHOPCHOPTarget,
        vector: CRISPRDesigner.VectorOverhang = .lentiCRISPRv2,
        prefix: String = ""
    ) {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let pair = CRISPRDesigner.designPair(
            target: target.spacer,
            geneName: gene,
            index: target.rank,
            prefix: trimmedPrefix.isEmpty ? "CHOP" : trimmedPrefix,
            species: species,
            vector: vector
        )
        AppState.shared.addPrimersToCart([pair.fwdPrimer, pair.revPrimer])
        AppState.shared.showToast(L10n.tr("已将 \(gene) sg#\(target.rank) 配对引物加入订购单！", "Added \(gene) sg#\(target.rank) primer pair to order cart!"))
    }
    
    /// 将所有选中的靶点生成引物并加入订购单
    public func addSelectedToCart(
        vector: CRISPRDesigner.VectorOverhang = .lentiCRISPRv2,
        prefix: String = ""
    ) {
        let selected = sortedTargets.filter { selectedTargetIDs.contains($0.id) }
        guard !selected.isEmpty else {
            AppState.shared.showToast("请至少勾选一条靶点")
            return
        }
        
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        var primers: [PrimerItem] = []
        for t in selected {
            let pair = CRISPRDesigner.designPair(
                target: t.spacer,
                geneName: gene,
                index: t.rank,
                prefix: trimmedPrefix.isEmpty ? "CHOP" : trimmedPrefix,
                species: species,
                vector: vector
            )
            primers.append(pair.fwdPrimer)
            primers.append(pair.revPrimer)
        }
        AppState.shared.addPrimersToCart(primers)
        AppState.shared.showToast(L10n.tr("已将 \(selected.count) 个靶点 (\(primers.count) 条引物) 加入订购单！", "Added \(selected.count) target(s) (\(primers.count) primers) to order cart!"))
    }
    
    /// 在默认外部浏览器中打开 CHOPCHOP 网页（若有 jobId 则直达结果页）
    public func openInSafari() {
        CHOPCHOPService.shared.openInDefaultBrowser(
            source: .chopchop,
            gene: gene,
            species: species,
            chopchopJobId: lastCHOPCHOPJobId,
            ucscSpan: lastUCSCSpan
        )
    }
    
    /// 在默认外部浏览器中打开指定数据源的官网或结果页
    public func openSourceInSafari(_ source: TargetCompareSource) {
        CHOPCHOPService.shared.openInDefaultBrowser(
            source: source,
            gene: gene,
            species: species,
            chopchopJobId: lastCHOPCHOPJobId,
            ucscSpan: lastUCSCSpan
        )
    }
    
    /// 一键清空当前查询结果与多源状态
    public func clear() {
        cancelAllActiveTasks()
        activeQueryToken = UUID()
        gene = ""
        isLoading = false
        progressMessage = ""
        targets = []
        rawCHOPCHOPTargets = []
        rawVBCTargets = []
        rawCRISPORTargets = []
        sourceStates = [:]
        lastCHOPCHOPJobId = nil
        lastUCSCSpan = nil
        activeSourceFilter = .all
        selectedTargetIDs = []
        matchMap = [:]
        manualCompareInput = ""
        showOnlyLocalMatches = false
        errorMessage = nil
        showErrorAlert = false
    }
}
