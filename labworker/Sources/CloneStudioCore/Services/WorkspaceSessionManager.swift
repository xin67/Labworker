import Foundation
import Combine

/// 全局工作区会话快照与自动保存/异常卡退恢复/正常退出询问保存管理器
@MainActor
public final class WorkspaceSessionManager: ObservableObject {
    public static let shared = WorkspaceSessionManager()
    
    // MARK: - 全部功能模块的共享持久化 ViewModels（切换侧边栏条目绝不丢失状态）
    public let entryCloneVM = EntryCloneViewModel()
    public let singleFragmentVM = SingleFragmentViewModel()
    public let multiFragmentVM = MultiFragmentViewModel()
    public let mutagenesisVM = MutagenesisViewModel()
    public let fragmentDeletionVM = FragmentDeletionViewModel()
    public let sgRNAVM = SgRNADesignViewModel()
    public let shRNAVM = ShRNADesignViewModel()
    public let chopchopVM = CHOPCHOPCompareViewModel()
    public let calculatorVM = CalculatorViewModel()
    public let bioCalculatorVM = BioCalculatorSuiteViewModel()
    public let sequenceToolVM = SequenceToolViewModel()
    
    // MARK: - 持久化模型
    public struct SessionSnapshot: Codable, Sendable {
        public var savedAt: Date
        public var selectedNavRawValue: String
        public var primersCart: [PrimerItem]
        
        // 1. 入门克隆
        public var entrySequence: String
        public var entryHasEnzymes: Bool
        public var entryEnzyme5Name: String?
        public var entryEnzyme3Name: String?
        public var entryPrimerF: PrimerItem?
        public var entryPrimerR: PrimerItem?
        
        // 2. 单片段克隆
        public var singleModeRaw: String
        public var singleVectorSeq: String
        public var singleVectorSeqU: String
        public var singleVectorSeqD: String
        public var singleInsertSeq: String
        public var singleEnzymeSingleName: String?
        public var singleEnzyme5Name: String?
        public var singleEnzyme3Name: String?
        public var singleHomologyLength: Int
        public var singleIncludeVecPCR: Bool
        public var singleVectorDNAInfo: SnapGeneFileInfo?
        public var singleVectorTargetSourceRaw: String
        public var singleSelectedVectorFeatureID: String
        public var singleVectorInsertActionRaw: String
        public var singleCutStartText: String
        public var singleCutEndText: String
        public var singleInsertSourceDNAInfo: SnapGeneFileInfo?
        public var singleDonorExtractSourceRaw: String
        public var singleSelectedInsertFeatureID: String
        public var singleSelectedInsertMergeEndFeatureID: String
        public var singleInsertStartText: String
        public var singleInsertEndText: String
        public var singleInsertUseRevComp: Bool
        public var singleInsertGeneName: String
        public var singleBaseInsertStartBp: Int
        public var singleBaseInsertEndBp: Int
        public var singleRemoveStopCodon: Bool
        public var singleExtra5Bases: String?
        public var singleExtra3Bases: String?
        public var singlePrimers: [PrimerItem]
        
        // 3. 多片段克隆
        public var multiFragments: [String]
        public var multiFragmentNames: [Int: String]
        public var multiFragmentDonorInfos: [Int: SnapGeneFileInfo]
        public var multiFragmentSelectedFeatureIDs: [Int: String]
        public var multiFragmentStartTexts: [Int: String]
        public var multiFragmentEndTexts: [Int: String]
        public var multiFragmentExtra5Bases: [Int: String]?
        public var multiTerminalExtra3Bases: String?
        public var multiVectorDNAInfo: SnapGeneFileInfo?
        public var multiCutStartText: String
        public var multiCutEndText: String
        public var multiVectorSeqU: String
        public var multiVectorSeqD: String
        public var multiVectorSeq: String
        public var multiEnzymeSingleName: String?
        public var multiHomologyLength: Int
        public var multiPrimers: [PrimerItem]
        
        // 4. 定点突变
        public var mutUp: String
        public var mutDown: String
        public var mutSite: String
        public var mutPlasmidDNAInfo: SnapGeneFileInfo?
        public var mutSelectedFeatureID: String
        public var mutReadingFrameOffset: Int
        public var mutSelectedResidueIndex: Int
        public var mutSelectedTargetAA: String
        public var mutTargetStartBp: Int
        public var mutTargetEndBp: Int
        public var mutSummaryLabel: String
        public var mutHomologyLength: Int
        public var mutPrimers: [PrimerItem]
        
        // 5. 质粒片段删除
        public var delPlasmidSeq: String
        public var delPlasmidDNAInfo: SnapGeneFileInfo?
        public var delSelectedDNAFileName: String
        public var delSelectionModeRaw: String
        public var delSelectedFeatureID: String
        public var delTargetSeq: String
        public var delStartText: String
        public var delEndText: String
        public var delHomologyLength: Int
        public var delPrimers: [PrimerItem]
        
        // 6. CHOPCHOP 与本地 SG/SH 状态持久化（可选字段以向下兼容旧快照）
        public var chopchopGene: String?
        public var chopchopSpeciesRaw: String?
        public var chopchopTargets: [CHOPCHOPTarget]?
        public var chopchopSelectedIDs: [Int]?
        public var chopchopSortModeRaw: String?
        public var localCompareTargets: [LocalCompareTarget]?
        public var sgRNASearchQuery: String?
        public var sgRNASpeciesRaw: String?
        public var sgRNASelectedIDs: [Int]?
        public var sgRNAGeneratedPrimers: [PrimerItem]?
        public var shRNASearchQuery: String?
        public var shRNASpeciesRaw: String?
        public var shRNASelectedIDs: [Int]?
        public var shRNAGeneratedPrimers: [PrimerItem]?
    }
    
    private let kDidTerminateCleanly = "cs.workspace.v3.didTerminateCleanly"
    private let kKeepSessionForNextLaunch = "cs.workspace.v3.keepSessionForNextLaunch"
    private let kRestoreWatchdogKey = "cs.workspace.v3.restoreInProgress"
    
    private var cancellables = Set<AnyCancellable>()
    private var isRestoring = false
    private var hasRestoredOnLaunch = false
    
    private init() {
        purgeLegacySnapshotFiles()
        setupAutoSaveObservers()
    }
    
    /// 清理旧版本遗留的快照文件（消除因历史脏快照导致的重复启动卡死循环）
    private func purgeLegacySnapshotFiles() {
        let fm = FileManager.default
        var legacyURLs: [URL] = [
            CloneStudioResourceLocator.projectRootDirectory.deletingLastPathComponent().appendingPathComponent(".clonestudio_autosave.json"),
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clonestudio_workspace_autosave.json")
        ]
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let oldDir = appSupport.appendingPathComponent("CloneStudio", isDirectory: true)
            legacyURLs.append(oldDir.appendingPathComponent("workspace_autosave.json"))
            let oldVazyme = appSupport.appendingPathComponent("VazymeCETool", isDirectory: true)
            legacyURLs.append(oldVazyme.appendingPathComponent("workspace_autosave.json"))
        }
        for u in legacyURLs {
            try? fm.removeItem(at: u)
        }
    }
    
    /// 获取会话快照文件存储路径（v3 独立快照，避免与旧版冲突）
    private var snapshotFileURLs: [URL] {
        var urls: [URL] = []
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("CloneStudio", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            urls.append(dir.appendingPathComponent("workspace_autosave_v3.json"))
        }
        let tmpFallback = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clonestudio_workspace_autosave_v3.json")
        urls.append(tmpFallback)
        return urls
    }
    
    private func setupAutoSaveObservers() {
        // 仅监听业务 ViewModel 与购物车/导航变化，不监听 AppState.objectWillChange（防止 Toast 弹窗与外观刷新触发全量 JSON 编码循环）
        let merged = Publishers.MergeMany([
            entryCloneVM.objectWillChange.eraseToAnyPublisher(),
            singleFragmentVM.objectWillChange.eraseToAnyPublisher(),
            multiFragmentVM.objectWillChange.eraseToAnyPublisher(),
            mutagenesisVM.objectWillChange.eraseToAnyPublisher(),
            fragmentDeletionVM.objectWillChange.eraseToAnyPublisher(),
            sgRNAVM.objectWillChange.eraseToAnyPublisher(),
            shRNAVM.objectWillChange.eraseToAnyPublisher(),
            chopchopVM.objectWillChange.eraseToAnyPublisher(),
            AppState.shared.$primersCart.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            AppState.shared.$selectedNav.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        
        merged
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self, !self.isRestoring else { return }
                self.autoSaveInBackground()
            }
            .store(in: &cancellables)
    }
    
    /// 判断当前工作区是否存在有效输入或设计内容
    public var hasActiveWorkspaceContent: Bool {
        if !entryCloneVM.sequence.isEmpty || entryCloneVM.primerF != nil || entryCloneVM.primerR != nil { return true }
        if singleFragmentVM.vectorDNAInfo != nil || singleFragmentVM.insertSourceDNAInfo != nil || !singleFragmentVM.vectorSeq.isEmpty || !singleFragmentVM.vectorSeqU.isEmpty || !singleFragmentVM.insertSeq.isEmpty || !singleFragmentVM.primers.isEmpty { return true }
        if multiFragmentVM.vectorDNAInfo != nil || !multiFragmentVM.vectorSeq.isEmpty || multiFragmentVM.fragments.contains(where: { !$0.isEmpty }) || !multiFragmentVM.primers.isEmpty { return true }
        if mutagenesisVM.plasmidDNAInfo != nil || !mutagenesisVM.mutUp.isEmpty || !mutagenesisVM.mutDown.isEmpty || !mutagenesisVM.mutSite.isEmpty || !mutagenesisVM.primers.isEmpty { return true }
        if fragmentDeletionVM.plasmidDNAInfo != nil || !fragmentDeletionVM.plasmidSeq.isEmpty || !fragmentDeletionVM.primers.isEmpty { return true }
        if !chopchopVM.gene.isEmpty || !chopchopVM.targets.isEmpty { return true }
        if !sgRNAVM.searchQuery.isEmpty || !sgRNAVM.generatedPrimers.isEmpty { return true }
        if !shRNAVM.searchQuery.isEmpty || !shRNAVM.generatedPrimers.isEmpty { return true }
        if !AppState.shared.primersCart.isEmpty { return true }
        return false
    }
    
    /// 实时自动保存（后台线程异步编码写盘，绝不阻塞主线程）
    public func autoSaveInBackground() {
        guard !isRestoring else { return }
        UserDefaults.standard.set(false, forKey: kDidTerminateCleanly)
        writeSnapshotToDisk(synchronous: false)
    }
    
    /// 正常退出时用户选择「保存并退出」
    public func saveSnapshotOnCleanExit() {
        writeSnapshotToDisk(synchronous: true)
        UserDefaults.standard.set(true, forKey: kDidTerminateCleanly)
        UserDefaults.standard.set(true, forKey: kKeepSessionForNextLaunch)
        UserDefaults.standard.synchronize()
    }
    
    /// 正常退出时用户选择「不保存退出」
    public func discardSnapshotOnCleanExit() {
        let fm = FileManager.default
        for url in snapshotFileURLs {
            try? fm.removeItem(at: url)
        }
        UserDefaults.standard.set(true, forKey: kDidTerminateCleanly)
        UserDefaults.standard.set(false, forKey: kKeepSessionForNextLaunch)
        UserDefaults.standard.synchronize()
    }
    
    private func writeSnapshotToDisk(synchronous: Bool = false) {
        let snap = buildCurrentSnapshot()
        let urls = self.snapshotFileURLs
        if synchronous {
            guard let data = try? JSONEncoder().encode(snap) else { return }
            for url in urls {
                try? data.write(to: url, options: .atomic)
            }
        } else {
            DispatchQueue.global(qos: .utility).async {
                guard let data = try? JSONEncoder().encode(snap) else { return }
                for url in urls {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }
    
    /// 启动时检测（内置看门狗保护：若上次启动恢复期间发生卡死/强退，自动跳过并清除问题快照，彻底杜绝启动死循环）
    public func restoreSessionOnLaunchIfNeeded() {
        guard !hasRestoredOnLaunch else { return }
        hasRestoredOnLaunch = true
        let d = UserDefaults.standard
        
        // 看门狗检测：若上次在恢复快照过程中未完成即卡死/强退，自动丢弃该问题快照
        if d.bool(forKey: kRestoreWatchdogKey) {
            d.set(false, forKey: kRestoreWatchdogKey)
            discardSnapshotOnCleanExit()
            return
        }
        
        let wasCleanExit = (d.object(forKey: kDidTerminateCleanly) as? Bool) ?? true
        let keepSaved = (d.object(forKey: kKeepSessionForNextLaunch) as? Bool) ?? true
        
        if wasCleanExit && !keepSaved {
            d.set(false, forKey: kDidTerminateCleanly)
            return
        }
        
        guard let snap = loadSnapshotFromDisk() else {
            d.set(false, forKey: kDidTerminateCleanly)
            return
        }
        
        d.set(true, forKey: kRestoreWatchdogKey)
        d.synchronize()
        
        isRestoring = true
        applySnapshot(snap)
        isRestoring = false
        
        d.set(false, forKey: kDidTerminateCleanly)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            UserDefaults.standard.set(false, forKey: self.kRestoreWatchdogKey)
        }
        
        if hasActiveWorkspaceContent {
            let msg = !wasCleanExit
                ? "⚡ 检测到上次异常退出，已为您自动恢复全部质粒与引物设计进度"
                : "已自动恢复上次保存的工作进度"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AppState.shared.showToast(msg)
            }
        }
    }
    
    private func loadSnapshotFromDisk() -> SessionSnapshot? {
        let fm = FileManager.default
        for url in snapshotFileURLs {
            if fm.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
                return snap
            }
        }
        return nil
    }
    
    private func buildCurrentSnapshot() -> SessionSnapshot {
        SessionSnapshot(
            savedAt: Date(),
            selectedNavRawValue: AppState.shared.selectedNav.rawValue,
            primersCart: AppState.shared.primersCart,
            entrySequence: entryCloneVM.sequence,
            entryHasEnzymes: entryCloneVM.hasEnzymes,
            entryEnzyme5Name: entryCloneVM.enzyme5?.name,
            entryEnzyme3Name: entryCloneVM.enzyme3?.name,
            entryPrimerF: entryCloneVM.primerF,
            entryPrimerR: entryCloneVM.primerR,
            singleModeRaw: singleFragmentVM.mode.rawValue,
            singleVectorSeq: singleFragmentVM.vectorSeq,
            singleVectorSeqU: singleFragmentVM.vectorSeqU,
            singleVectorSeqD: singleFragmentVM.vectorSeqD,
            singleInsertSeq: singleFragmentVM.insertSeq,
            singleEnzymeSingleName: singleFragmentVM.enzymeSingle?.name,
            singleEnzyme5Name: singleFragmentVM.enzyme5?.name,
            singleEnzyme3Name: singleFragmentVM.enzyme3?.name,
            singleHomologyLength: singleFragmentVM.homologyLength,
            singleIncludeVecPCR: singleFragmentVM.includeVectorPCRPrimers,
            singleVectorDNAInfo: singleFragmentVM.vectorDNAInfo,
            singleVectorTargetSourceRaw: singleFragmentVM.vectorTargetSource.rawValue,
            singleSelectedVectorFeatureID: singleFragmentVM.selectedVectorFeatureID,
            singleVectorInsertActionRaw: singleFragmentVM.vectorInsertAction.rawValue,
            singleCutStartText: singleFragmentVM.cutStartText,
            singleCutEndText: singleFragmentVM.cutEndText,
            singleInsertSourceDNAInfo: singleFragmentVM.insertSourceDNAInfo,
            singleDonorExtractSourceRaw: singleFragmentVM.donorExtractSource.rawValue,
            singleSelectedInsertFeatureID: singleFragmentVM.selectedInsertFeatureID,
            singleSelectedInsertMergeEndFeatureID: singleFragmentVM.selectedInsertMergeEndFeatureID,
            singleInsertStartText: singleFragmentVM.insertStartText,
            singleInsertEndText: singleFragmentVM.insertEndText,
            singleInsertUseRevComp: singleFragmentVM.insertUseReverseComplement,
            singleInsertGeneName: singleFragmentVM.insertGeneName,
            singleBaseInsertStartBp: singleFragmentVM.baseInsertStartBp,
            singleBaseInsertEndBp: singleFragmentVM.baseInsertEndBp,
            singleRemoveStopCodon: singleFragmentVM.removeTerminalStopCodon,
            singleExtra5Bases: singleFragmentVM.extra5Bases,
            singleExtra3Bases: singleFragmentVM.extra3Bases,
            singlePrimers: singleFragmentVM.primers,
            multiFragments: multiFragmentVM.fragments,
            multiFragmentNames: multiFragmentVM.fragmentNames,
            multiFragmentDonorInfos: multiFragmentVM.fragmentDonorInfos,
            multiFragmentSelectedFeatureIDs: multiFragmentVM.fragmentSelectedFeatureIDs,
            multiFragmentStartTexts: multiFragmentVM.fragmentStartTexts,
            multiFragmentEndTexts: multiFragmentVM.fragmentEndTexts,
            multiFragmentExtra5Bases: multiFragmentVM.fragmentExtra5Bases,
            multiTerminalExtra3Bases: multiFragmentVM.terminalExtra3Bases,
            multiVectorDNAInfo: multiFragmentVM.vectorDNAInfo,
            multiCutStartText: multiFragmentVM.cutStartText,
            multiCutEndText: multiFragmentVM.cutEndText,
            multiVectorSeqU: multiFragmentVM.vectorSeqU,
            multiVectorSeqD: multiFragmentVM.vectorSeqD,
            multiVectorSeq: multiFragmentVM.vectorSeq,
            multiEnzymeSingleName: multiFragmentVM.enzymeSingle?.name,
            multiHomologyLength: multiFragmentVM.homologyLength,
            multiPrimers: multiFragmentVM.primers,
            mutUp: mutagenesisVM.mutUp,
            mutDown: mutagenesisVM.mutDown,
            mutSite: mutagenesisVM.mutSite,
            mutPlasmidDNAInfo: mutagenesisVM.plasmidDNAInfo,
            mutSelectedFeatureID: mutagenesisVM.selectedFeatureID,
            mutReadingFrameOffset: mutagenesisVM.readingFrameOffset,
            mutSelectedResidueIndex: mutagenesisVM.selectedResidueIndex,
            mutSelectedTargetAA: mutagenesisVM.selectedTargetAA,
            mutTargetStartBp: mutagenesisVM.mutTargetStartBp,
            mutTargetEndBp: mutagenesisVM.mutTargetEndBp,
            mutSummaryLabel: mutagenesisVM.mutationSummaryLabel,
            mutHomologyLength: mutagenesisVM.homologyLength,
            mutPrimers: mutagenesisVM.primers,
            delPlasmidSeq: fragmentDeletionVM.plasmidSeq,
            delPlasmidDNAInfo: fragmentDeletionVM.plasmidDNAInfo,
            delSelectedDNAFileName: fragmentDeletionVM.selectedDNAFileName,
            delSelectionModeRaw: fragmentDeletionVM.selectionMode.rawValue,
            delSelectedFeatureID: fragmentDeletionVM.selectedDeleteFeatureID,
            delTargetSeq: fragmentDeletionVM.targetDelSeq,
            delStartText: fragmentDeletionVM.delStartText,
            delEndText: fragmentDeletionVM.delEndText,
            delHomologyLength: fragmentDeletionVM.homologyLength,
            delPrimers: fragmentDeletionVM.primers,
            chopchopGene: chopchopVM.gene,
            chopchopSpeciesRaw: chopchopVM.species.rawValue,
            chopchopTargets: chopchopVM.targets,
            chopchopSelectedIDs: Array(chopchopVM.selectedTargetIDs),
            chopchopSortModeRaw: chopchopVM.sortMode.rawValue,
            localCompareTargets: AppState.shared.localCompareTargets,
            sgRNASearchQuery: sgRNAVM.searchQuery,
            sgRNASpeciesRaw: sgRNAVM.species.rawValue,
            sgRNASelectedIDs: Array(sgRNAVM.selectedTargetIDs),
            sgRNAGeneratedPrimers: sgRNAVM.generatedPrimers,
            shRNASearchQuery: shRNAVM.searchQuery,
            shRNASpeciesRaw: shRNAVM.species.rawValue,
            shRNASelectedIDs: Array(shRNAVM.selectedTargetIDs),
            shRNAGeneratedPrimers: shRNAVM.generatedPrimers
        )
    }
    
    private func applySnapshot(_ snap: SessionSnapshot) {
        if let nav = NavItem(rawValue: snap.selectedNavRawValue) {
            AppState.shared.selectedNav = nav
        }
        AppState.shared.primersCart = snap.primersCart
        
        // 1. 入门克隆
        entryCloneVM.sequence = snap.entrySequence
        entryCloneVM.hasEnzymes = snap.entryHasEnzymes
        if let n5 = snap.entryEnzyme5Name {
            entryCloneVM.enzyme5 = RestrictionEnzymeDatabase.shared.find(name: n5)
        }
        if let n3 = snap.entryEnzyme3Name {
            entryCloneVM.enzyme3 = RestrictionEnzymeDatabase.shared.find(name: n3)
        }
        entryCloneVM.primerF = snap.entryPrimerF
        entryCloneVM.primerR = snap.entryPrimerR
        
        // 2. 单片段克隆
        if let m = SingleFragmentViewModel.Mode(rawValue: snap.singleModeRaw) {
            singleFragmentVM.mode = m
        }
        singleFragmentVM.vectorDNAInfo = snap.singleVectorDNAInfo
        if let vecInfo = snap.singleVectorDNAInfo {
            Task.detached(priority: .utility) {
                let sites = vecInfo.scanAvailableCutSites(maxCutsPerEnzyme: 2)
                await MainActor.run {
                    WorkspaceSessionManager.shared.singleFragmentVM.availableVectorCutSites = sites
                }
            }
        }
        singleFragmentVM.vectorSeq = snap.singleVectorSeq
        singleFragmentVM.vectorSeqU = snap.singleVectorSeqU
        singleFragmentVM.vectorSeqD = snap.singleVectorSeqD
        singleFragmentVM.insertSeq = snap.singleInsertSeq
        if let es = snap.singleEnzymeSingleName {
            singleFragmentVM.enzymeSingle = RestrictionEnzymeDatabase.shared.find(name: es)
        }
        if let e5 = snap.singleEnzyme5Name {
            singleFragmentVM.enzyme5 = RestrictionEnzymeDatabase.shared.find(name: e5)
        }
        if let e3 = snap.singleEnzyme3Name {
            singleFragmentVM.enzyme3 = RestrictionEnzymeDatabase.shared.find(name: e3)
        }
        singleFragmentVM.homologyLength = snap.singleHomologyLength
        singleFragmentVM.includeVectorPCRPrimers = snap.singleIncludeVecPCR
        if let vts = SingleFragmentViewModel.VectorTargetSource(rawValue: snap.singleVectorTargetSourceRaw) {
            singleFragmentVM.vectorTargetSource = vts
        }
        singleFragmentVM.selectedVectorFeatureID = snap.singleSelectedVectorFeatureID
        if let via = SingleFragmentViewModel.VectorInsertAction(rawValue: snap.singleVectorInsertActionRaw) {
            singleFragmentVM.vectorInsertAction = via
        }
        singleFragmentVM.cutStartText = snap.singleCutStartText
        singleFragmentVM.cutEndText = snap.singleCutEndText
        singleFragmentVM.insertSourceDNAInfo = snap.singleInsertSourceDNAInfo
        if let des = SingleFragmentViewModel.DonorExtractSource(rawValue: snap.singleDonorExtractSourceRaw) {
            singleFragmentVM.donorExtractSource = des
        }
        singleFragmentVM.selectedInsertFeatureID = snap.singleSelectedInsertFeatureID
        singleFragmentVM.selectedInsertMergeEndFeatureID = snap.singleSelectedInsertMergeEndFeatureID
        singleFragmentVM.insertStartText = snap.singleInsertStartText
        singleFragmentVM.insertEndText = snap.singleInsertEndText
        singleFragmentVM.insertUseReverseComplement = snap.singleInsertUseRevComp
        singleFragmentVM.insertGeneName = snap.singleInsertGeneName
        singleFragmentVM.baseInsertStartBp = snap.singleBaseInsertStartBp
        singleFragmentVM.baseInsertEndBp = snap.singleBaseInsertEndBp
        singleFragmentVM.removeTerminalStopCodon = snap.singleRemoveStopCodon
        singleFragmentVM.extra5Bases = snap.singleExtra5Bases ?? ""
        singleFragmentVM.extra3Bases = snap.singleExtra3Bases ?? ""
        if singleFragmentVM.insertSourceDNAInfo != nil {
            singleFragmentVM.syncDonorExtractWithStopCodonRule()
        }
        singleFragmentVM.primers = snap.singlePrimers
        
        // 3. 多片段克隆
        if !snap.multiFragments.isEmpty {
            multiFragmentVM.fragments = snap.multiFragments
        }
        multiFragmentVM.fragmentNames = snap.multiFragmentNames
        multiFragmentVM.fragmentDonorInfos = snap.multiFragmentDonorInfos
        multiFragmentVM.fragmentSelectedFeatureIDs = snap.multiFragmentSelectedFeatureIDs
        multiFragmentVM.fragmentStartTexts = snap.multiFragmentStartTexts
        multiFragmentVM.fragmentEndTexts = snap.multiFragmentEndTexts
        multiFragmentVM.fragmentExtra5Bases = snap.multiFragmentExtra5Bases ?? [:]
        multiFragmentVM.terminalExtra3Bases = snap.multiTerminalExtra3Bases ?? ""
        multiFragmentVM.vectorDNAInfo = snap.multiVectorDNAInfo
        if let mVec = snap.multiVectorDNAInfo {
            Task.detached(priority: .utility) {
                let sites = mVec.scanAvailableCutSites(maxCutsPerEnzyme: 2)
                await MainActor.run {
                    WorkspaceSessionManager.shared.multiFragmentVM.availableVectorCutSites = sites
                }
            }
        }
        multiFragmentVM.cutStartText = snap.multiCutStartText
        multiFragmentVM.cutEndText = snap.multiCutEndText
        multiFragmentVM.vectorSeqU = snap.multiVectorSeqU
        multiFragmentVM.vectorSeqD = snap.multiVectorSeqD
        multiFragmentVM.vectorSeq = snap.multiVectorSeq
        if let mes = snap.multiEnzymeSingleName {
            multiFragmentVM.enzymeSingle = RestrictionEnzymeDatabase.shared.find(name: mes)
        }
        multiFragmentVM.homologyLength = snap.multiHomologyLength
        multiFragmentVM.primers = snap.multiPrimers
        
        // 4. 定点突变
        mutagenesisVM.plasmidDNAInfo = snap.mutPlasmidDNAInfo
        mutagenesisVM.selectedFeatureID = snap.mutSelectedFeatureID
        mutagenesisVM.readingFrameOffset = snap.mutReadingFrameOffset
        if !snap.mutSelectedFeatureID.isEmpty, snap.mutPlasmidDNAInfo != nil {
            mutagenesisVM.selectFeatureForTranslation(id: snap.mutSelectedFeatureID, frameOffset: snap.mutReadingFrameOffset)
        }
        mutagenesisVM.mutUp = snap.mutUp
        mutagenesisVM.mutDown = snap.mutDown
        mutagenesisVM.mutSite = snap.mutSite
        mutagenesisVM.selectedResidueIndex = snap.mutSelectedResidueIndex
        mutagenesisVM.selectedTargetAA = snap.mutSelectedTargetAA
        mutagenesisVM.mutTargetStartBp = snap.mutTargetStartBp
        mutagenesisVM.mutTargetEndBp = snap.mutTargetEndBp
        mutagenesisVM.mutationSummaryLabel = snap.mutSummaryLabel
        mutagenesisVM.homologyLength = snap.mutHomologyLength
        mutagenesisVM.primers = snap.mutPrimers
        
        // 5. 质粒片段删除
        fragmentDeletionVM.plasmidDNAInfo = snap.delPlasmidDNAInfo
        fragmentDeletionVM.plasmidSeq = snap.delPlasmidSeq
        fragmentDeletionVM.plasmidLength = snap.delPlasmidDNAInfo?.length ?? BioSequence.clean(snap.delPlasmidSeq).count
        fragmentDeletionVM.selectedDNAFileName = snap.delSelectedDNAFileName
        if let sm = FragmentDeletionViewModel.SelectionMode(rawValue: snap.delSelectionModeRaw) {
            fragmentDeletionVM.selectionMode = sm
        }
        fragmentDeletionVM.selectedDeleteFeatureID = snap.delSelectedFeatureID
        fragmentDeletionVM.targetDelSeq = snap.delTargetSeq
        fragmentDeletionVM.delStartText = snap.delStartText
        fragmentDeletionVM.delEndText = snap.delEndText
        fragmentDeletionVM.homologyLength = snap.delHomologyLength
        fragmentDeletionVM.primers = snap.delPrimers
        
        // 6. 恢复本地 SG/SH 与 CHOPCHOP 在线对比状态
        if let localCmp = snap.localCompareTargets {
            AppState.shared.localCompareTargets = localCmp
        }
        if let sgSp = snap.sgRNASpeciesRaw, let sp = TargetSpecies(rawValue: sgSp) {
            sgRNAVM.species = sp
        }
        if let sgQ = snap.sgRNASearchQuery, !sgQ.isEmpty {
            sgRNAVM.searchQuery = sgQ
            sgRNAVM.search()
            if let ids = snap.sgRNASelectedIDs {
                sgRNAVM.selectedTargetIDs = Set(ids)
            }
        }
        if let sgP = snap.sgRNAGeneratedPrimers {
            sgRNAVM.generatedPrimers = sgP
        }
        
        if let shSp = snap.shRNASpeciesRaw, let sp = TargetSpecies(rawValue: shSp) {
            shRNAVM.species = sp
        }
        if let shQ = snap.shRNASearchQuery, !shQ.isEmpty {
            shRNAVM.searchQuery = shQ
            shRNAVM.search()
            if let ids = snap.shRNASelectedIDs {
                shRNAVM.selectedTargetIDs = Set(ids)
            }
        }
        if let shP = snap.shRNAGeneratedPrimers {
            shRNAVM.generatedPrimers = shP
        }
        
        if let ccGene = snap.chopchopGene {
            chopchopVM.gene = ccGene
        }
        if let ccSp = snap.chopchopSpeciesRaw, let sp = TargetSpecies(rawValue: ccSp) {
            chopchopVM.species = sp
        }
        if let ccSort = snap.chopchopSortModeRaw,
           let sm = CHOPCHOPCompareViewModel.CHOPCHOPSortMode(rawValue: ccSort) {
            chopchopVM.sortMode = sm
        }
        if let ccTargets = snap.chopchopTargets {
            chopchopVM.targets = ccTargets
            chopchopVM.recomputeLocalMatches()
        }
        if let ccSel = snap.chopchopSelectedIDs {
            chopchopVM.selectedTargetIDs = Set(ccSel)
        }
    }
    
    // MARK: - 全面适配 macOS Finder：从 Finder 双击 / 打开方式 / 拖入窗口自动智能路由直达对应功能模块
    public func handleFinderOpenURLs(_ urls: [URL]) {
        let validURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !validURLs.isEmpty else { return }
        
        let dnaURLs = validURLs.filter { $0.pathExtension.lowercased() == "dna" }
        let ab1URLs = validURLs.filter { ["ab1", "abi"].contains($0.pathExtension.lowercased()) }
        let pdbURLs = validURLs.filter { ["pdb", "cif", "ent"].contains($0.pathExtension.lowercased()) }
        let imageURLs = validURLs.filter { ["tif", "tiff", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
        let csvURLs = validURLs.filter { ["csv", "tsv"].contains($0.pathExtension.lowercased()) }
        let seqURLs = validURLs.filter { ["fa", "fasta", "gb", "gbk", "seq", "txt"].contains($0.pathExtension.lowercased()) }
        
        // 0. Sanger 测序 .ab1 / .abi 四色峰图文件 -> 自动跳转「测序验证」并载入峰图
        if let firstAB1 = ab1URLs.first {
            AppState.shared.pendingFinderOpenedFileURL = firstAB1
            AppState.shared.selectedNav = .sangerVerify
            AppState.shared.showToast("已从 Finder 载入 Sanger 测序峰图 \(firstAB1.lastPathComponent) 至「测序验证」")
            return
        }
        
        // 1. PDB / AlphaFold 3D 结构文件 -> 自动跳转「蛋白质工作台」并载入结构
        if let firstPDB = pdbURLs.first {
            AppState.shared.pendingFinderOpenedFileURL = firstPDB
            AppState.shared.selectedNav = .proteinWorkbench
            AppState.shared.showToast("已从 Finder 载入三维结构 \(firstPDB.lastPathComponent) 至「蛋白质工作台」")
            return
        }
        
        // 2. 16-bit TIFF / 电泳或胶片图像 -> 若当前已在图像相关模块则留在当前模块，否则直达「WB 灰度定量」
        if let firstImg = imageURLs.first {
            AppState.shared.pendingFinderOpenedFileURL = firstImg
            let currentNav = AppState.shared.selectedNav
            if ![NavItem.westernBlot, .gelFigure, .colonyCounter].contains(currentNav) {
                AppState.shared.selectedNav = .westernBlot
            }
            AppState.shared.showToast("已从 Finder 载入图像 \(firstImg.lastPathComponent) 至「\(AppState.shared.selectedNav.title)」")
            return
        }
        
        // 4. CSV / TSV 实验数据表 -> 自动路由至「qPCR 定量」（若当前在微孔板设计器则保持）
        if let firstCSV = csvURLs.first {
            AppState.shared.pendingFinderOpenedFileURL = firstCSV
            if AppState.shared.selectedNav != .plateDesigner {
                AppState.shared.selectedNav = .qpcrAnalysis
            }
            AppState.shared.showToast("已从 Finder 载入数据表 \(firstCSV.lastPathComponent) 至「\(AppState.shared.selectedNav.title)」")
            return
        }
        
        // 5. SnapGene .dna 载体/质粒文件 -> 智能路由至分子克隆模块
        if !dnaURLs.isEmpty {
            let currentNav = AppState.shared.selectedNav
            switch currentNav {
            case .singleFragment:
                if dnaURLs.count >= 2 {
                    Task {
                        await singleFragmentVM.loadVectorDNA(url: dnaURLs[0])
                        await singleFragmentVM.loadInsertSourceDNA(url: dnaURLs[1])
                    }
                } else if let first = dnaURLs.first {
                    Task {
                        if singleFragmentVM.vectorDNAInfo == nil {
                            await singleFragmentVM.loadVectorDNA(url: first)
                        } else if singleFragmentVM.insertSourceDNAInfo == nil {
                            await singleFragmentVM.loadInsertSourceDNA(url: first)
                        } else {
                            await singleFragmentVM.loadVectorDNA(url: first)
                        }
                    }
                }
            case .multiFragment:
                if let first = dnaURLs.first {
                    Task {
                        if multiFragmentVM.vectorDNAInfo == nil {
                            await multiFragmentVM.loadVectorDNA(url: first)
                        } else {
                            await multiFragmentVM.loadFragmentDonorDNA(at: 0, url: first)
                        }
                    }
                }
            case .mutagenesis:
                if let first = dnaURLs.first {
                    Task { await mutagenesisVM.loadDNAFile(url: first) }
                }
            case .fragmentDeletion:
                if let first = dnaURLs.first {
                    Task { await fragmentDeletionVM.loadDNAFile(url: first) }
                }
            case .plasmidPool:
                break
            default:
                AppState.shared.selectedNav = .singleFragment
                if dnaURLs.count >= 2 {
                    Task {
                        await singleFragmentVM.loadVectorDNA(url: dnaURLs[0])
                        await singleFragmentVM.loadInsertSourceDNA(url: dnaURLs[1])
                    }
                } else if let first = dnaURLs.first {
                    Task { await singleFragmentVM.loadVectorDNA(url: first) }
                }
            }
            return
        }
        
        // 6. FASTA / GenBank / 文本序列文件 -> 智能判别核酸或氨基酸序列
        if let firstSeqURL = seqURLs.first,
           let rawText = (try? String(contentsOf: firstSeqURL, encoding: .utf8)) ?? (try? String(contentsOf: firstSeqURL, encoding: .ascii)) {
            let lines = rawText.components(separatedBy: .newlines)
            let seqLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            let joinedUpper = seqLines.joined().uppercased().filter { $0.isLetter }
            let nonNucleicCount = joinedUpper.filter { !"ATCGUN".contains($0) }.count
            // 若包含明显氨基酸特征字母（如 E/F/I/L/P/Q），自动路由至「蛋白质工作台」
            if !joinedUpper.isEmpty && Double(nonNucleicCount) / Double(joinedUpper.count) > 0.12 {
                AppState.shared.pendingFinderOpenedFileURL = firstSeqURL
                AppState.shared.selectedNav = .proteinWorkbench
                AppState.shared.showToast("已从 Finder 识别蛋白序列 \(firstSeqURL.lastPathComponent) 并打开「蛋白质工作台」")
                return
            }
            
            let cleaned = BioSequence.clean(seqLines.joined())
            guard !cleaned.isEmpty else { return }
            let fileName = firstSeqURL.deletingPathExtension().lastPathComponent
            
            switch AppState.shared.selectedNav {
            case .entryClone:
                entryCloneVM.sequence = cleaned
            case .singleFragment:
                singleFragmentVM.insertSeq = cleaned
                singleFragmentVM.insertGeneName = fileName
            case .multiFragment:
                if !multiFragmentVM.fragments.isEmpty {
                    multiFragmentVM.fragments[0] = cleaned
                }
            case .mutagenesis:
                let mid = cleaned.count / 2
                let midIdx = cleaned.index(cleaned.startIndex, offsetBy: mid)
                mutagenesisVM.mutUp = String(cleaned[..<midIdx])
                mutagenesisVM.mutDown = String(cleaned[midIdx...])
            case .fragmentDeletion:
                fragmentDeletionVM.plasmidSeq = cleaned
                fragmentDeletionVM.selectedDNAFileName = firstSeqURL.lastPathComponent
            case .sangerVerify:
                AppState.shared.pendingFinderOpenedFileURL = firstSeqURL
            default:
                AppState.shared.selectedNav = .entryClone
                entryCloneVM.sequence = cleaned
            }
            AppState.shared.showToast("已从 Finder 导入序列 \(firstSeqURL.lastPathComponent) (\(cleaned.count) bp)")
        }
    }
}
