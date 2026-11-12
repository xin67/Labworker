import Foundation
import SwiftUI
import Combine

// MARK: - 1. 入门克隆 ViewModel
@MainActor
public final class EntryCloneViewModel: ObservableObject {
    @Published public var sequence: String = ""
    @Published public var hasEnzymes: Bool = false
    @Published public var enzyme5: RestrictionEnzyme? = RestrictionEnzymeDatabase.shared.find(name: "BamHI")
    @Published public var enzyme3: RestrictionEnzyme? = RestrictionEnzymeDatabase.shared.find(name: "EcoRI")
    @Published public var targetTm: Double = AppState.shared.cloningTargetTm
    
    @Published public var primerF: PrimerItem? = nil
    @Published public var primerR: PrimerItem? = nil
    @Published public var isDesigning: Bool = false
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    public init() {}
    
    public var cleanLength: Int {
        BioSequence.clean(sequence).count
    }
    
    public func design() async {
        let clean = BioSequence.clean(sequence)
        guard clean.count >= 50 else {
            alertMessage = "插入片段长度必须大于等于 50 bp（当前有效长度：\(clean.count) bp）"
            showAlert = true
            return
        }
        
        if hasEnzymes {
            guard let e5 = enzyme5, let e3 = enzyme3 else {
                alertMessage = "请先选择 5' 端和 3' 端的酶切位点"
                showAlert = true
                return
            }
            if e5.name == e3.name {
                alertMessage = "两端添加的酶切位点不能相同（\(e5.name)）"
                showAlert = true
                return
            }
        }
        
        isDesigning = true
        defer { isDesigning = false }
        
        do {
            let result = try await DualEngineCoordinator.shared.designEntryClone(
                sequence: clean,
                hasEnzymes: hasEnzymes,
                enzyme5: enzyme5,
                enzyme3: enzyme3,
                targetTm: AppState.shared.cloningTargetTm,
                tolerance: AppState.shared.tmTolerance
            )
            self.primerF = result.primerF
            self.primerR = result.primerR
            
            // 记录到构建谱系树
            let e5Site = (hasEnzymes ? enzyme5?.site : nil) ?? ""
            let e3Site = (hasEnzymes ? enzyme3?.site : nil) ?? ""
            let prodSeq = "GGATCTTCCAGAGAT" + e5Site + clean + e3Site + "ATCGTCGAACGGCAG"
            let parentID = ConstructHistoryManager.shared.activeNodeID
            let baseFeatures: [(String, Int, Int)] = [
                ("lacZ/T7", 1, 240),
                ("5' URS", 241, 255),
                ("3' DRS", 256, 270),
                ("KanR", 1200, 2016),
                ("ori", 2600, 3189)
            ]
            let shifts = ConstructHistoryManager.computeFeatureShifts(
                originalFeatures: baseFeatures,
                editStartBp: 256,
                editEndBp: 255,
                insertedBp: clean.count,
                insertedFeatureName: "Insert (\(clean.count)bp)"
            )
            let node = ConstructHistoryNode(
                parentNodeID: parentID,
                constructName: "pCE2-Entry-\(clean.count)bp",
                operationType: .entryClone,
                parentVectorName: "pCE2-TA/Blunt",
                parentLengthBp: 3957,
                insertOrActionSummary: "Insert (\(clean.count) bp)",
                productLengthBp: 3957 + clean.count + 30,
                homologyArmLength: 15,
                junctionOverhangs: [
                    JunctionOverhangDetail(title: "5' URS 同源接头", topStrandSnippet: "GGATCTTCCAGAGAT" + String(clean.prefix(9)), bottomStrandSnippet: BioSequence.complement("GGATCTTCCAGAGAT" + String(clean.prefix(9))), enzymeOrArmName: "5' URS", homologyLength: 15),
                    JunctionOverhangDetail(title: "3' DRS 同源接头", topStrandSnippet: String(clean.suffix(9)) + "ATCGTCGAACGGCAG", bottomStrandSnippet: BioSequence.complement(String(clean.suffix(9)) + "ATCGTCGAACGGCAG"), enzymeOrArmName: "3' DRS", homologyLength: 15)
                ],
                featureShifts: shifts,
                primers: [result.primerF, result.primerR],
                productSequence: prodSeq
            )
            ConstructHistoryManager.shared.recordNode(node)
            
            if let msg = result.promptMessage, !msg.isEmpty {
                AppState.shared.showToast(msg)
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
    
    public func clear() {
        sequence = ""
        primerF = nil
        primerR = nil
    }
    
    public func addAllToCart() {
        var items: [PrimerItem] = []
        if let f = primerF { items.append(f) }
        if let r = primerR { items.append(r) }
        guard !items.isEmpty else { return }
        AppState.shared.addPrimersToCart(items)
    }
}

// MARK: - 质粒特征分类辅助器
public enum PlasmidFeatureFilter: String, CaseIterable, Identifiable {
    case targetGenes = "目的基因/CDS"
    case tagsAndPromoters = "标签/调控"
    case backbone = "骨架/抗性"
    case all = "全部特征"
    
    public var id: String { rawValue }
    
    public var shortTitle: String {
        switch self {
        case .targetGenes: return "目的基因"
        case .tagsAndPromoters: return "标签/调控"
        case .backbone: return "骨架/抗性"
        case .all: return "全部"
        }
    }
    
    public static func isBackbone(_ f: SnapGeneFeature) -> Bool {
        let lowName = f.name.lowercased()
        let lowType = f.type.lowercased()
        let backboneKeywords = [
            "ori", "f1 ori", "sv40 ori", "ampr", "kanr", "neor", "puror", "hygr", "cmr",
            "laci", "rop", "bom", "cap binding", "m13"
        ]
        if lowType.contains("rep_origin") { return true }
        return backboneKeywords.contains { lowName.contains($0) }
    }
    
    public static func isTagOrRegulatory(_ f: SnapGeneFeature) -> Bool {
        let lowName = f.name.lowercased()
        let lowType = f.type.lowercased()
        let regKeywords = [
            "promoter", "terminator", "enhancer", "operator", "rbs", "poly(a)", "wpre", "kozak",
            "his", "flag", "myc", "ha", "gst", "egfp", "gfp", "mcherry", "s-tag", "tev",
            "同源臂", "删除", "氨基酸", "定位", "注释", "备注"
        ]
        if lowType.contains("promoter") || lowType.contains("terminator") || lowType.contains("regulatory") || lowType.contains("primer_bind") || lowType.contains("poly") || lowType.contains("protein_bind") {
            return true
        }
        return regKeywords.contains { lowName.contains($0) }
    }
    
    public func matches(_ f: SnapGeneFeature) -> Bool {
        switch self {
        case .all:
            return true
        case .targetGenes:
            return !Self.isBackbone(f) && !Self.isTagOrRegulatory(f)
        case .tagsAndPromoters:
            return Self.isTagOrRegulatory(f)
        case .backbone:
            return Self.isBackbone(f)
        }
    }
}

// MARK: - 2. 单片段克隆 ViewModel
@MainActor
public final class SingleFragmentViewModel: ObservableObject {
    public enum Mode: String, CaseIterable, Identifiable {
        case pcr = "PCR"
        case single = "Single"
        case double = "Double"
        
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .pcr:    return "反向PCR扩增载体"
            case .single: return "单酶切线性化"
            case .double: return "双酶切线性化"
            }
        }
    }
    
    /// 载入载体 .dna 后的四维定位方式
    public enum VectorTargetSource: String, CaseIterable, Identifiable {
        case byFeature = "① 按载体特征 (Feature)"
        case byPrimers = "② 按载体已有引物对"
        case byCutSites = "③ 按载体真实酶切位点"
        case byCoordinates = "④ 自定义坐标 (Start..End)"
        
        public var id: String { rawValue }
        
        public var shortTitle: String {
            switch self {
            case .byFeature: return "① 特征定位"
            case .byPrimers: return "② 引物对"
            case .byCutSites: return "③ 酶切位点"
            case .byCoordinates: return "④ 坐标"
            }
        }
    }
    
    public enum VectorInsertAction: String, CaseIterable, Identifiable {
        case replaceFeature = "替换该特征 (切除原序列)"
        case insertUpstream = "无缝插入到 5' 上游"
        case insertDownstream = "无缝插入到 3' 下游"
        
        public var id: String { rawValue }
    }
    
    /// 载入供体 .dna 后的三维提取方式
    public enum DonorExtractSource: String, CaseIterable, Identifiable {
        case byFeature = "① 按供体特征提取 (支持合并相邻特征)"
        case byPrimers = "② 按供体已有引物对提取"
        case byCoordinates = "③ 自定义起止坐标提取"
        
        public var id: String { rawValue }
        
        public var shortTitle: String {
            switch self {
            case .byFeature: return "① 特征提取"
            case .byPrimers: return "② 引物对"
            case .byCoordinates: return "③ 坐标"
            }
        }
    }
    
    @Published public var mode: Mode = .pcr {
        didSet {
            if let info = vectorDNAInfo {
                if mode != .pcr && vectorSeq.isEmpty {
                    vectorSeq = info.sequence
                }
                if mode == .single || mode == .double {
                    vectorTargetSource = .byCutSites
                    updateEnzymeCutCoordinatesIfNeeded()
                }
            }
        }
    }
    @Published public var vectorSeq: String = ""
    @Published public var vectorSeqU: String = ""
    @Published public var vectorSeqD: String = ""
    @Published public var insertSeq: String = ""
    
    /// 5' 与 3' 接头附加碱基（用于补齐 1~2 bp 阅读框移码或插入柔性 Linker，均按编码链正向 5'→3' 输入）
    @Published public var extra5Bases: String = ""
    @Published public var extra3Bases: String = ""
    
    @Published public var enzymeSingle: RestrictionEnzyme? = RestrictionEnzymeDatabase.shared.find(name: "BamHI") {
        didSet { updateEnzymeCutCoordinatesIfNeeded() }
    }
    @Published public var enzyme5: RestrictionEnzyme? = RestrictionEnzymeDatabase.shared.find(name: "BamHI") {
        didSet { updateEnzymeCutCoordinatesIfNeeded() }
    }
    @Published public var enzyme3: RestrictionEnzyme? = RestrictionEnzymeDatabase.shared.find(name: "EcoRI") {
        didSet { updateEnzymeCutCoordinatesIfNeeded() }
    }
    
    @Published public var primers: [PrimerItem] = []
    @Published public var homologyLength: Int = AppState.shared.defaultHomologyLength
    @Published public var includeVectorPCRPrimers: Bool = AppState.shared.defaultIncludeVectorPCRPrimers
    @Published public var isDesigning: Bool = false
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    // MARK: - 载体 SnapGene 解析与多维定位状态
    @Published public var vectorDNAInfo: SnapGeneFileInfo? = nil
    @Published public var vectorTargetSource: VectorTargetSource = .byFeature
    @Published public var vectorFeatureFilter: PlasmidFeatureFilter = .targetGenes
    @Published public var selectedVectorFeatureID: String = ""
    @Published public var vectorInsertAction: VectorInsertAction = .replaceFeature
    
    @Published public var selectedVectorRevPrimerID: String = "" // 上游逆时针引物 (如 pETDuet-A1-R)
    @Published public var selectedVectorFwdPrimerID: String = "" // 下游顺时针引物 (如 pETDuet-A1-F)
    
    @Published public var availableVectorCutSites: [VectorCutSiteOption] = []
    @Published public var onlyShowUniqueVectorCutters: Bool = true
    @Published public var selectedVectorCutSite5ID: String = ""
    @Published public var selectedVectorCutSite3ID: String = ""
    
    @Published public var cutStartText: String = "1"
    @Published public var cutEndText: String = "1"
    
    // MARK: - 供体 SnapGene 解析与多维提取状态 (含 3' 末端终止密码子自动解析与无损切换)
    @Published public var insertSourceDNAInfo: SnapGeneFileInfo? = nil
    @Published public var donorExtractSource: DonorExtractSource = .byFeature
    @Published public var donorFeatureFilter: PlasmidFeatureFilter = .targetGenes
    @Published public var selectedInsertFeatureID: String = ""
    @Published public var selectedInsertMergeEndFeatureID: String = "" // 可选：合并提取至相邻特征（如 TP53 + 3xFLAG）
    
    @Published public var selectedDonorFwdPrimerID: String = "" // 供体正向扩增引物 (如 suc1-f)
    @Published public var selectedDonorRevPrimerID: String = "" // 供体反向扩增引物 (如 suc1-r)
    
    @Published public var insertStartText: String = "1"
    @Published public var insertEndText: String = "1"
    @Published public var insertUseReverseComplement: Bool = false
    @Published public var insertGeneName: String = "TargetGene"
    @Published public var isSnapGeneBusy: Bool = false
    
    /// 原始未去终止子的基准起止坐标与自动解析出的 3' 末端终止子信息
    @Published public var baseInsertStartBp: Int = 1
    @Published public var baseInsertEndBp: Int = 1
    @Published public var removeTerminalStopCodon: Bool = false
    @Published public var detectedTerminalStopCodon: String? = nil
    @Published public var terminalCodonStatusText: String = ""
    
    /// 当前解析出的载体切点/替换起点 (1-based)
    public var cutStart: Int {
        let maxLen = max(1, vectorDNAInfo?.length ?? max(1, BioSequence.clean(vectorSeq).count))
        let val = Int(cutStartText.trimmingCharacters(in: .whitespaces)) ?? 1
        return max(1, min(val, maxLen + 1))
    }
    
    /// 当前解析出的载体切点/替换终点 (1-based, inclusive; 若为 cutStart - 1 则表示纯插入不删碱基)
    public var cutEnd: Int {
        let maxLen = max(1, vectorDNAInfo?.length ?? max(1, BioSequence.clean(vectorSeq).count))
        let val = Int(cutEndText.trimmingCharacters(in: .whitespaces)) ?? cutStart
        return max(cutStart - 1, min(val, maxLen))
    }
    
    /// 排序并按分类过滤后的载体特征列表（目的基因如 A1、B1 排在最前）
    public var sortedVectorFeatures: [SnapGeneFeature] {
        guard let info = vectorDNAInfo else { return [] }
        let valid = info.features.filter { !$0.segments.isEmpty && vectorFeatureFilter.matches($0) }
        let list = valid.isEmpty ? info.features.filter { !$0.segments.isEmpty } : valid
        return list.sorted { a, b in
            let aTarget = PlasmidFeatureFilter.targetGenes.matches(a)
            let bTarget = PlasmidFeatureFilter.targetGenes.matches(b)
            if aTarget != bTarget { return aTarget }
            let aBack = PlasmidFeatureFilter.isBackbone(a)
            let bBack = PlasmidFeatureFilter.isBackbone(b)
            if aBack != bBack { return !aBack }
            return (a.segments.first?.start ?? 0) < (b.segments.first?.start ?? 0)
        }
    }
    
    /// 载体中已解析出结合坐标的引物列表
    public var vectorBoundPrimers: [SnapGenePrimer] {
        vectorDNAInfo?.validBoundPrimers ?? []
    }
    
    /// 载体真实存在的酶切位点（支持仅看唯一切点或查看 1~2 切点）
    public var displayedVectorCutSites: [VectorCutSiteOption] {
        if onlyShowUniqueVectorCutters {
            let unique = availableVectorCutSites.filter { $0.isUnique }
            return unique.isEmpty ? availableVectorCutSites : unique
        }
        return availableVectorCutSites
    }
    
    /// 排序并按分类过滤后的供体特征列表（目的基因如 TP53 排在最前）
    public var sortedInsertFeatures: [SnapGeneFeature] {
        guard let info = insertSourceDNAInfo else { return [] }
        let valid = info.features.filter { !$0.segments.isEmpty && donorFeatureFilter.matches($0) }
        let list = valid.isEmpty ? info.features.filter { !$0.segments.isEmpty } : valid
        return list.sorted { a, b in
            let aTarget = PlasmidFeatureFilter.targetGenes.matches(a)
            let bTarget = PlasmidFeatureFilter.targetGenes.matches(b)
            if aTarget != bTarget { return aTarget }
            let aBack = PlasmidFeatureFilter.isBackbone(a)
            let bBack = PlasmidFeatureFilter.isBackbone(b)
            if aBack != bBack { return !aBack }
            let aLen = (a.segments.last?.end ?? 0) - (a.segments.first?.start ?? 0)
            let bLen = (b.segments.last?.end ?? 0) - (b.segments.first?.start ?? 0)
            return aLen > bLen
        }
    }
    
    /// 供体中已解析出结合坐标的引物列表
    public var donorBoundPrimers: [SnapGenePrimer] {
        insertSourceDNAInfo?.validBoundPrimers ?? []
    }
    
    public init() {}
    
    // MARK: - 载体四维定位动作
    
    /// ① 根据载体特征与动作计算切点坐标并提取上下游载体序列
    public func selectVectorFeature(id: String, action: VectorInsertAction? = nil) {
        guard let info = vectorDNAInfo,
              let feat = info.features.first(where: { $0.id == id }),
              let firstSeg = feat.segments.first,
              let lastSeg = feat.segments.last else { return }
        
        self.selectedVectorFeatureID = id
        if let act = action {
            self.vectorInsertAction = act
        }
        
        let s = max(1, firstSeg.start)
        let e = min(info.length, lastSeg.end)
        
        switch self.vectorInsertAction {
        case .replaceFeature:
            applyVectorTargetRange(start: s, end: e)
        case .insertUpstream:
            applyVectorTargetRange(start: s, end: s - 1)
        case .insertDownstream:
            applyVectorTargetRange(start: min(info.length + 1, e + 1), end: e)
        }
    }
    
    /// ② 根据载体中用户选中的上下游引物对（如 pETDuet-A1-R 与 pETDuet-A1-F）定位待替换区间与同源臂
    public func applyVectorPrimerPair() {
        guard let info = vectorDNAInfo else { return }
        let allPrimers = info.validBoundPrimers
        guard let revP = allPrimers.first(where: { $0.id == selectedVectorRevPrimerID }),
              let fwdP = allPrimers.first(where: { $0.id == selectedVectorFwdPrimerID }),
              let revEnd = revP.endBp,
              let fwdStart = fwdP.startBp else { return }
        
        // 上游反向引物 (←) 的 5' 端在 revEnd，因此保留骨架截止到 revEnd，待替换区从 revEnd + 1 开始
        // 下游正向引物 (→) 的 5' 端在 fwdStart，因此保留骨架从 fwdStart 开始，待替换区到 fwdStart - 1 结束
        let s = min(revEnd + 1, fwdStart)
        let e = max(s - 1, fwdStart - 1)
        self.mode = .pcr
        applyVectorTargetRange(start: s, end: e)
    }
    
    /// ③ 根据载体真实扫描出的酶切位点选择单酶切或双酶切坐标
    public func selectVectorCutSite5(id: String) {
        self.selectedVectorCutSite5ID = id
        guard let opt5 = availableVectorCutSites.first(where: { $0.id == id }) else { return }
        if mode == .pcr {
            mode = .single
        }
        if mode == .single {
            self.enzymeSingle = opt5.enzyme
            applyVectorTargetRange(start: opt5.position1Based, end: opt5.endPosition1Based)
        } else if mode == .double {
            self.enzyme5 = opt5.enzyme
            if let opt3 = availableVectorCutSites.first(where: { $0.id == selectedVectorCutSite3ID }) {
                let cStart = min(opt5.position1Based, opt3.position1Based)
                let cEnd = max(opt5.endPosition1Based, opt3.endPosition1Based)
                applyVectorTargetRange(start: cStart, end: cEnd)
            } else {
                applyVectorTargetRange(start: opt5.position1Based, end: opt5.endPosition1Based)
            }
        }
    }
    
    public func selectVectorCutSite3(id: String) {
        self.selectedVectorCutSite3ID = id
        guard let opt3 = availableVectorCutSites.first(where: { $0.id == id }) else { return }
        if mode != .double {
            mode = .double
        }
        self.enzyme3 = opt3.enzyme
        if let opt5 = availableVectorCutSites.first(where: { $0.id == selectedVectorCutSite5ID }) {
            let cStart = min(opt5.position1Based, opt3.position1Based)
            let cEnd = max(opt5.endPosition1Based, opt3.endPosition1Based)
            applyVectorTargetRange(start: cStart, end: cEnd)
        } else {
            applyVectorTargetRange(start: opt3.position1Based, end: opt3.endPosition1Based)
        }
    }
    
    /// ④ 根据用户指定的载体坐标区间 [start, end] (1-based) 自动更新上下游保留侧翼序列 vectorSeqU 和 vectorSeqD
    public func applyVectorTargetRange(start: Int, end: Int) {
        guard let info = vectorDNAInfo else {
            self.cutStartText = "\(max(1, start))"
            self.cutEndText = "\(max(start - 1, end))"
            return
        }
        let seq = BioSequence.clean(info.sequence)
        let len = seq.count
        guard len > 0 else { return }
        
        let clampedStart = max(1, min(start, len + 1))
        let clampedEnd = max(clampedStart - 1, min(end, len))
        self.cutStartText = "\(clampedStart)"
        self.cutEndText = "\(clampedEnd)"
        
        // 环状双倍序列，确保跨 1 bp 原点时也能准确截取上下游 60 bp
        let flankLen = min(60, len)
        let doubled = seq + seq
        
        // 上游保留区末端紧邻 clampedStart - 1 (1-based)
        let upEnd0 = (clampedStart - 1 + len) % len
        let upStart0 = (upEnd0 - flankLen + len) % len
        let uStartIdx = doubled.index(doubled.startIndex, offsetBy: upStart0)
        let uEndIdx = doubled.index(uStartIdx, offsetBy: flankLen)
        self.vectorSeqU = String(doubled[uStartIdx..<uEndIdx])
        
        // 下游保留区起点紧邻 clampedEnd + 1 (1-based)
        let downStart0 = clampedEnd % len
        let dStartIdx = doubled.index(doubled.startIndex, offsetBy: downStart0)
        let dEndIdx = doubled.index(dStartIdx, offsetBy: flankLen)
        self.vectorSeqD = String(doubled[dStartIdx..<dEndIdx])
    }
    
    /// 若用户手动修改了 vectorSeqU / vectorSeqD，自动在载体全序列中反查真实切点坐标
    public func resolveCutRangeFromFlanksIfNeeded() {
        guard let info = vectorDNAInfo else { return }
        let vecClean = BioSequence.clean(info.sequence)
        guard vecClean.count >= 40 else { return }
        
        let cleanU = BioSequence.clean(vectorSeqU)
        let cleanD = BioSequence.clean(vectorSeqD)
        let probeU = cleanU.count >= 18 ? String(cleanU.suffix(18)) : cleanU
        let probeD = cleanD.count >= 18 ? String(cleanD.prefix(18)) : cleanD
        guard probeU.count >= 12 && probeD.count >= 12 else { return }
        
        if let uRange = vecClean.range(of: probeU),
           let dRange = vecClean.range(of: probeD) {
            let uEnd1Based = vecClean.distance(from: vecClean.startIndex, to: uRange.upperBound)
            let dStart1Based = vecClean.distance(from: vecClean.startIndex, to: dRange.lowerBound) + 1
            if uEnd1Based < dStart1Based {
                self.cutStartText = "\(uEnd1Based + 1)"
                self.cutEndText = "\(dStart1Based - 1)"
            }
        }
    }
    
    /// 单酶切 / 双酶切模式下同步更新切点坐标
    public func updateEnzymeCutCoordinatesIfNeeded() {
        let cleanVec = BioSequence.clean(vectorDNAInfo?.sequence ?? vectorSeq)
        guard cleanVec.count >= 20 else { return }
        switch mode {
        case .single:
            if let enz = enzymeSingle, let firstSite = enz.findSites(in: cleanVec).first {
                applyVectorTargetRange(start: firstSite + 1, end: min(cleanVec.count, firstSite + enz.site.count))
            }
        case .double:
            if let e5 = enzyme5, let e3 = enzyme3 {
                let s5 = e5.findSites(in: cleanVec).first
                let s3 = e3.findSites(in: cleanVec).first
                if let p5 = s5, let p3 = s3 {
                    let cStart = min(p5, p3) + 1
                    let cEnd = max(p5, p3) + (p5 <= p3 ? e3.site.count : e5.site.count)
                    applyVectorTargetRange(start: cStart, end: min(cleanVec.count, cEnd))
                }
            }
        case .pcr:
            break
        }
    }
    
    // MARK: - 供体三维提取动作
    
    /// ① 选择供体质粒中的某个 Feature（或合并相邻 Feature）作为插入片段，并自动解析 3' 末端是否含终止密码子
    public func selectInsertFeature(id: String, mergeEndID: String? = nil) {
        guard let info = insertSourceDNAInfo,
              let feat = info.features.first(where: { $0.id == id }),
              let firstSeg = feat.segments.first,
              let lastSeg = feat.segments.last else { return }
        
        self.selectedInsertFeatureID = id
        let resolvedEndID = mergeEndID ?? self.selectedInsertMergeEndFeatureID
        self.selectedInsertMergeEndFeatureID = resolvedEndID
        
        var s = max(1, firstSeg.start)
        var e = min(info.length, lastSeg.end)
        var nameBuilder = feat.name
        
        if !resolvedEndID.isEmpty,
           resolvedEndID != id,
           let endFeat = info.features.first(where: { $0.id == resolvedEndID }),
           let efFirst = endFeat.segments.first,
           let efLast = endFeat.segments.last {
            s = min(s, max(1, efFirst.start))
            e = max(e, min(info.length, efLast.end))
            nameBuilder = "\(feat.name)-\(endFeat.name)"
        }
        
        self.baseInsertStartBp = s
        self.baseInsertEndBp = e
        self.removeTerminalStopCodon = false
        self.insertUseReverseComplement = (feat.directionality == "2")
        self.insertGeneName = nameBuilder
        syncDonorExtractWithStopCodonRule()
    }
    
    /// ② 根据供体已有引物对（如 suc1-f 与 suc1-r）提取扩增子序列，并自动解析 3' 末端终止密码子
    public func applyDonorPrimerPair() {
        guard let info = insertSourceDNAInfo else { return }
        let allPrimers = info.validBoundPrimers
        guard let fwdP = allPrimers.first(where: { $0.id == selectedDonorFwdPrimerID }),
              let revP = allPrimers.first(where: { $0.id == selectedDonorRevPrimerID }),
              let fStart = fwdP.startBp, let fEnd = fwdP.endBp,
              let rStart = revP.startBp, let rEnd = revP.endBp else { return }
        
        let s = max(1, min(min(fStart, fEnd), min(rStart, rEnd)))
        let e = min(info.length, max(max(fStart, fEnd), max(rStart, rEnd)))
        self.baseInsertStartBp = s
        self.baseInsertEndBp = e
        self.removeTerminalStopCodon = false
        self.insertUseReverseComplement = (!fwdP.isForwardStrand && revP.isForwardStrand)
        
        if let matchedFeat = info.features.first(where: { f in
            guard let fs = f.segments.first?.start, let fe = f.segments.last?.end else { return false }
            return abs(fs - s) <= 30 && abs(fe - e) <= 30
        }) {
            self.insertGeneName = matchedFeat.name
        } else {
            self.insertGeneName = "\(fwdP.name)_\(revP.name)"
        }
        syncDonorExtractWithStopCodonRule()
    }
    
    /// ③ 根据用户在输入框指定的起止坐标与正负链方向提取插入片段序列，并自动解析 3' 末端终止密码子
    public func extractInsertFromDonorCoordinates() {
        guard let info = insertSourceDNAInfo else { return }
        let seq = BioSequence.clean(info.sequence)
        let len = seq.count
        guard len > 0 else { return }
        
        let s = max(1, min(Int(insertStartText.trimmingCharacters(in: .whitespaces)) ?? 1, len))
        let e = max(s, min(Int(insertEndText.trimmingCharacters(in: .whitespaces)) ?? len, len))
        self.baseInsertStartBp = s
        self.baseInsertEndBp = e
        self.removeTerminalStopCodon = false
        syncDonorExtractWithStopCodonRule()
    }
    
    /// 自动解析原始区间 3' 末端是否为终止密码子 (TAA / TAG / TGA)，并根据 removeTerminalStopCodon 状态无损截取或恢复
    public func syncDonorExtractWithStopCodonRule() {
        guard let info = insertSourceDNAInfo else { return }
        let seq = BioSequence.clean(info.sequence)
        let len = seq.count
        guard len > 0 else { return }
        
        let rawS = max(1, min(baseInsertStartBp, len))
        let rawE = max(rawS, min(baseInsertEndBp, len))
        self.baseInsertStartBp = rawS
        self.baseInsertEndBp = rawE
        
        let rawStartIdx = seq.index(seq.startIndex, offsetBy: rawS - 1)
        let rawEndIdx = seq.index(seq.startIndex, offsetBy: rawE)
        var rawSub = String(seq[rawStartIdx..<rawEndIdx])
        if insertUseReverseComplement {
            rawSub = BioSequence.reverseComplement(rawSub)
        }
        
        let tail3 = rawSub.count >= 3 ? String(rawSub.suffix(3)).uppercased() : ""
        let stopCodons: Set<String> = ["TAA", "TAG", "TGA"]
        
        if stopCodons.contains(tail3) && rawSub.count >= 6 {
            self.detectedTerminalStopCodon = tail3
            if removeTerminalStopCodon {
                let effS = insertUseReverseComplement ? (rawS + 3) : rawS
                let effE = insertUseReverseComplement ? rawE : (rawE - 3)
                self.insertStartText = "\(effS)"
                self.insertEndText = "\(effE)"
                self.insertSeq = String(rawSub.dropLast(3))
                self.terminalCodonStatusText = "已去终止子 \(tail3) (-3bp)"
            } else {
                self.insertStartText = "\(rawS)"
                self.insertEndText = "\(rawE)"
                self.insertSeq = rawSub
                self.terminalCodonStatusText = "检测到3'终止子 \(tail3)"
            }
        } else {
            self.detectedTerminalStopCodon = nil
            self.removeTerminalStopCodon = false
            self.insertStartText = "\(rawS)"
            self.insertEndText = "\(rawE)"
            self.insertSeq = rawSub
            if tail3.count == 3 {
                let (_, three) = CodonTranslator.translateTriplet(tail3)
                self.terminalCodonStatusText = "末端无终止子 (3'端: \(tail3)/\(three))"
            } else {
                self.terminalCodonStatusText = "末端无终止子"
            }
        }
    }
    
    /// 智能切换去除/恢复 3' 末端终止密码子（仅当实际检测到 TAA/TAG/TGA 时生效，绝不误删编码序列）
    public func toggleTerminalStopCodon() {
        guard let stop = detectedTerminalStopCodon else {
            AppState.shared.showToast("当前片段 3' 末端无终止密码子 (TAA/TAG/TGA)，无需去除")
            return
        }
        removeTerminalStopCodon.toggle()
        syncDonorExtractWithStopCodonRule()
        if removeTerminalStopCodon {
            AppState.shared.showToast("已自动去除 3' 末端终止子 \(stop) (-3 bp)")
        } else {
            AppState.shared.showToast("已恢复 3' 末端终止子 \(stop) (+3 bp)")
        }
    }
    
    public func design() async {
        let cleanInsert = BioSequence.clean(insertSeq)
        guard cleanInsert.count >= 50 else {
            alertMessage = "插入片段长度必须大于等于 50 bp"
            showAlert = true
            return
        }
        
        if mode == .pcr {
            resolveCutRangeFromFlanksIfNeeded()
        } else {
            updateEnzymeCutCoordinatesIfNeeded()
        }
        
        isDesigning = true
        defer { isDesigning = false }
        
        do {
            var warnPrompt: String? = nil
            let cTm = AppState.shared.cloningTargetTm
            let tol = AppState.shared.tmTolerance
            let cleanEx5 = BioSequence.clean(extra5Bases)
            let cleanEx3 = BioSequence.clean(extra3Bases)
            if DualEngineCoordinator.shared.currentMode == .offlineOnly || homologyLength != 15 || abs(cTm - 60.0) > 0.1 || !cleanEx5.isEmpty || !cleanEx3.isEmpty {
                switch mode {
                case .single:
                    guard let e = enzymeSingle else {
                        throw NSError(domain: "Clone", code: -1, userInfo: [NSLocalizedDescriptionKey: "请先选择单酶切位点"])
                    }
                    let res = HomologyArmDesigner.designSingleEnzymeClone(
                        vectorSeq: vectorSeq.isEmpty ? (vectorDNAInfo?.sequence ?? "") : vectorSeq,
                        insertSeq: cleanInsert,
                        enzyme: e,
                        homologyLength: homologyLength,
                        targetTm: cTm,
                        tolerance: tol,
                        extra5Bases: cleanEx5,
                        extra3Bases: cleanEx3
                    )
                    if let cs = res.resolvedCutStart, let ce = res.resolvedCutEnd {
                        self.cutStartText = "\(cs)"
                        self.cutEndText = "\(ce)"
                    }
                    warnPrompt = res.promptMessage
                    self.primers = [res.primerF, res.primerR]
                case .double:
                    guard let e5 = enzyme5, let e3 = enzyme3 else {
                        throw NSError(domain: "Clone", code: -1, userInfo: [NSLocalizedDescriptionKey: "请选择双酶切 5' 与 3' 位点"])
                    }
                    let res = HomologyArmDesigner.designDoubleEnzymeClone(
                        vectorSeq: vectorSeq.isEmpty ? (vectorDNAInfo?.sequence ?? "") : vectorSeq,
                        insertSeq: cleanInsert,
                        enzyme5: e5,
                        enzyme3: e3,
                        homologyLength: homologyLength,
                        targetTm: cTm,
                        tolerance: tol,
                        extra5Bases: cleanEx5,
                        extra3Bases: cleanEx3
                    )
                    if let cs = res.resolvedCutStart, let ce = res.resolvedCutEnd {
                        self.cutStartText = "\(cs)"
                        self.cutEndText = "\(ce)"
                    }
                    warnPrompt = res.promptMessage
                    self.primers = [res.primerF, res.primerR]
                case .pcr:
                    let res = HomologyArmDesigner.designPCRVectorClone(
                        vectorSeqU: vectorSeqU,
                        vectorSeqD: vectorSeqD,
                        insertSeq: cleanInsert,
                        homologyLength: homologyLength,
                        targetTm: cTm,
                        tolerance: tol,
                        extra5Bases: cleanEx5,
                        extra3Bases: cleanEx3
                    )
                    var list = [res.primerF, res.primerR]
                    if includeVectorPCRPrimers {
                        if let vf = res.vectorPrimerF { list.append(vf) }
                        if let vr = res.vectorPrimerR { list.append(vr) }
                    }
                    self.primers = list
                }
                if let warn = warnPrompt, !warn.isEmpty {
                    AppState.shared.showToast(warn)
                } else {
                    let extraTag = (!cleanEx5.isEmpty || !cleanEx3.isEmpty) ? "，含接头附加碱基 +\(cleanEx5.count + cleanEx3.count) bp" : ""
                    AppState.shared.showToast("已生成引物（同源臂: \(homologyLength) bp\(extraTag)，目标位点: \(cutStart)..\(cutEnd)）")
                }
            } else {
                // 在线官方请求 (15 bp 国标模式)
                let res = try await CloneOnlineAPIClient.shared.requestSingleFragmentClone(
                    mode: mode.rawValue,
                    vectorSeq: vectorSeq,
                    insertSeq: cleanInsert,
                    vectorSeqU: vectorSeqU,
                    vectorSeqD: vectorSeqD,
                    enzymeName: enzymeSingle?.name ?? "",
                    enzymeSite: enzymeSingle?.site ?? "",
                    enzyme5Name: enzyme5?.name ?? "",
                    enzyme5Site: enzyme5?.site ?? "",
                    enzyme3Name: enzyme3?.name ?? "",
                    enzyme3Site: enzyme3?.site ?? ""
                )
                
                var list: [PrimerItem] = []
                if let fVal = res.PrimerFvalue, !fVal.isEmpty {
                    let rawF = DualEngineCoordinator.stripHTMLTags(fVal)
                    let armF = String(BioSequence.clean(rawF).prefix(homologyLength)).lowercased()
                    let (specF, tmF) = DualEngineCoordinator.computeSnapGenePrimerMetrics(fullSequence: rawF, homologyArm: armF)
                    list.append(PrimerItem(
                        name: "Single-Frag-F",
                        fullSequence: rawF,
                        homologyArm: armF,
                        specificSequence: specF,
                        tm: tmF,
                        targetPurpose: "单片段克隆插入正向引物",
                        notes: "5' 载体同源臂 (\(armF.count)bp) + 特异性序列 (Tm: \(tmF)℃)",
                        sourceTool: "单片段克隆"
                    ))
                }
                if let rVal = res.PrimerRvalue, !rVal.isEmpty {
                    let rawR = DualEngineCoordinator.stripHTMLTags(rVal)
                    let armR = String(BioSequence.clean(rawR).prefix(homologyLength)).lowercased()
                    let (specR, tmR) = DualEngineCoordinator.computeSnapGenePrimerMetrics(fullSequence: rawR, homologyArm: armR)
                    list.append(PrimerItem(
                        name: "Single-Frag-R",
                        fullSequence: rawR,
                        homologyArm: armR,
                        specificSequence: specR,
                        tm: tmR,
                        targetPurpose: "单片段克隆插入反向引物",
                        notes: "3' 载体同源臂 (\(armR.count)bp) + 特异性序列 (Tm: \(tmR)℃)",
                        sourceTool: "单片段克隆"
                    ))
                }
                if let cfVal = res.ClonePrimerFvalue, !cfVal.isEmpty {
                    let rawCF = DualEngineCoordinator.stripHTMLTags(cfVal)
                    let cleanCF = BioSequence.clean(rawCF)
                    let tmCF = TmCalculator.calculate(sequence: cleanCF).tm
                    list.append(PrimerItem(
                        name: "Vector-PCR-F",
                        fullSequence: rawCF,
                        specificSequence: cleanCF,
                        tm: tmCF,
                        targetPurpose: "载体反向PCR扩增正向引物",
                        notes: "结合于目标替换位点 3' 下游载体骨架 (Tm: \(tmCF)℃)",
                        sourceTool: "单片段克隆"
                    ))
                }
                if let crVal = res.ClonePrimerRvalue, !crVal.isEmpty {
                    let rawCR = DualEngineCoordinator.stripHTMLTags(crVal)
                    let cleanCR = BioSequence.clean(rawCR)
                    let tmCR = TmCalculator.calculate(sequence: cleanCR).tm
                    list.append(PrimerItem(
                        name: "Vector-PCR-R",
                        fullSequence: rawCR,
                        specificSequence: cleanCR,
                        tm: tmCR,
                        targetPurpose: "载体反向PCR扩增反向引物",
                        notes: "结合于目标替换位点 5' 上游载体骨架 (Tm: \(tmCR)℃)",
                        sourceTool: "单片段克隆"
                    ))
                }
                self.primers = list
                if let msg = res.promptMessage, !msg.isEmpty {
                    AppState.shared.showToast(msg)
                }
            }
            
            // 记录单片段克隆节点到构建谱系树
            if !self.primers.isEmpty {
                let fullVec = BioSequence.clean(vectorDNAInfo?.sequence ?? (mode == .pcr ? (vectorSeqU + vectorSeqD) : vectorSeq))
                let vecBp = max(fullVec.count, 5369)
                let parentName = vectorDNAInfo?.fileName.replacingOccurrences(of: ".dna", with: "") ?? "pVector-\(mode.rawValue)"
                let insName = insertGeneName.isEmpty ? "Insert" : insertGeneName
                let effIns = effectiveInsertSeq
                let cStart = cutStart
                let cEnd = cutEnd
                let delLen = max(0, cEnd - cStart + 1)
                let prodSeq: String
                if !fullVec.isEmpty && cStart >= 1 && cEnd <= fullVec.count {
                    let lIdx = fullVec.index(fullVec.startIndex, offsetBy: cStart - 1)
                    let rIdx = fullVec.index(fullVec.startIndex, offsetBy: max(cStart - 1, cEnd))
                    prodSeq = String(fullVec[..<lIdx]) + effIns + String(fullVec[rIdx...])
                } else {
                    prodSeq = (fullVec.isEmpty ? "CGGCCGCTCGAGCATGGA" : fullVec) + effIns
                }
                let baseFeats: [(String, Int, Int)] = vectorDNAInfo?.features.compactMap { f in
                    guard let seg = f.segments.first else { return nil }
                    return (f.name, seg.start, seg.end)
                } ?? [
                    ("Promoter", 1, 580),
                    ("MCS-5'Arm", 581, 598),
                    ("MCS-3'Arm", 599, 616),
                    ("AmpR", 2200, 3060),
                    ("ori", 3800, 4420)
                ]
                let shifts = ConstructHistoryManager.computeFeatureShifts(
                    originalFeatures: baseFeats,
                    editStartBp: cStart,
                    editEndBp: cEnd,
                    insertedBp: effIns.count,
                    insertedFeatureName: "\(insName) (\(effIns.count)bp)"
                )
                let cleanU = BioSequence.clean(vectorSeqU)
                let cleanD = BioSequence.clean(vectorSeqD)
                let arm5 = cleanU.count >= homologyLength ? String(cleanU.suffix(homologyLength)).uppercased() : "CGGCCGCTCGAGCATGGA"
                let arm3 = cleanD.count >= homologyLength ? String(cleanD.prefix(homologyLength)).uppercased() : "GATCCGAATTCGAGCTCG"
                let node = ConstructHistoryNode(
                    parentNodeID: ConstructHistoryManager.shared.activeNodeID,
                    constructName: "\(parentName)-\(insName)",
                    operationType: .singleFragment,
                    parentVectorName: parentName,
                    parentLengthBp: vecBp,
                    insertOrActionSummary: delLen > 0 ? "替换 \(cStart)..\(cEnd) (Δ\(delLen)bp) → \(insName) (+\(effIns.count)bp)" : "插入 @\(cStart) → \(insName) (+\(effIns.count)bp)",
                    productLengthBp: vecBp - delLen + effIns.count,
                    homologyArmLength: homologyLength,
                    junctionOverhangs: [
                        JunctionOverhangDetail(title: "5' 载体-片段同源接头 (@\(cStart))", topStrandSnippet: arm5 + String(cleanInsert.prefix(8)), bottomStrandSnippet: BioSequence.complement(arm5 + String(cleanInsert.prefix(8))), enzymeOrArmName: mode == .single ? (enzymeSingle?.name ?? "5'Arm") : "5'Arm", homologyLength: homologyLength),
                        JunctionOverhangDetail(title: "3' 片段-载体同源接头 (@\(cEnd))", topStrandSnippet: String(cleanInsert.suffix(8)) + arm3, bottomStrandSnippet: BioSequence.complement(String(cleanInsert.suffix(8)) + arm3), enzymeOrArmName: mode == .double ? (enzyme3?.name ?? "3'Arm") : "3'Arm", homologyLength: homologyLength)
                    ],
                    featureShifts: shifts,
                    primers: self.primers,
                    productSequence: prodSeq
                )
                ConstructHistoryManager.shared.recordNode(node)
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
    
    public func addAllToCart() {
        guard !primers.isEmpty else { return }
        AppState.shared.addPrimersToCart(primers)
    }
    
    // MARK: - SnapGene 动作方法
    
    /// 载入目标载体 .dna 文件：立即解析全部特征、引物结合位点与真实酶切位点供用户点选
    public func loadVectorDNA(url: URL) async {
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        do {
            let info = try await SnapGeneService.shared.parseDNAFile(at: url)
            self.vectorDNAInfo = info
            self.vectorSeq = info.sequence
            self.vectorFeatureFilter = .targetGenes
            
            // 1. 扫描载体真实酶切位点 (1~2 切点)
            let cutSites = info.scanAvailableCutSites(maxCutsPerEnzyme: 2)
            self.availableVectorCutSites = cutSites
            if let firstCut = cutSites.first {
                self.selectedVectorCutSite5ID = firstCut.id
            }
            if cutSites.count > 1 {
                self.selectedVectorCutSite3ID = cutSites[1].id
            } else if let firstCut = cutSites.first {
                self.selectedVectorCutSite3ID = firstCut.id
            }
            
            // 2. 初始化载体已有引物对选项
            let boundPrimers = info.validBoundPrimers
            let revCand = boundPrimers.first(where: { !$0.isForwardStrand }) ?? boundPrimers.first
            let fwdCand = boundPrimers.first(where: { $0.isForwardStrand && $0.id != revCand?.id }) ?? boundPrimers.last
            self.selectedVectorRevPrimerID = revCand?.id ?? ""
            self.selectedVectorFwdPrimerID = fwdCand?.id ?? ""
            
            // 3. 初始化默认特征选项供用户在下拉框/标签中直接切换
            let candidates = self.sortedVectorFeatures
            if let preferred = candidates.first(where: { $0.name.uppercased() == "A1" }) ?? candidates.first {
                self.vectorTargetSource = .byFeature
                self.selectVectorFeature(id: preferred.id, action: .replaceFeature)
            } else if let firstCut = cutSites.first {
                self.vectorTargetSource = .byCutSites
                self.selectVectorCutSite5(id: firstCut.id)
            } else {
                self.vectorTargetSource = .byCoordinates
                self.applyVectorTargetRange(start: 1, end: 0)
            }
            
            AppState.shared.showToast("已解析载体 \(info.fileName)：\(info.featuresCount) 个特征、\(boundPrimers.count) 条引物、\(cutSites.filter { $0.isUnique }.count) 个唯一酶切位点")
        } catch {
            self.alertMessage = "解析 SnapGene 载体失败: \(error.localizedDescription)"
            self.showAlert = true
        }
    }
    
    /// 载入插入片段源质粒 .dna 文件：立即解析全部特征与已有引物对供用户点选
    public func loadInsertSourceDNA(url: URL) async {
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        do {
            let info = try await SnapGeneService.shared.parseDNAFile(at: url)
            self.insertSourceDNAInfo = info
            self.donorFeatureFilter = .targetGenes
            self.selectedInsertMergeEndFeatureID = ""
            
            // 1. 初始化供体引物对选项 (如 suc1-f 与 suc1-r)
            let boundPrimers = info.validBoundPrimers
            let fwdCand = boundPrimers.first(where: { $0.isForwardStrand }) ?? boundPrimers.first
            let revCand = boundPrimers.first(where: { !$0.isForwardStrand && $0.id != fwdCand?.id }) ?? boundPrimers.last
            self.selectedDonorFwdPrimerID = fwdCand?.id ?? ""
            self.selectedDonorRevPrimerID = revCand?.id ?? ""
            
            // 2. 初始化特征选项
            let candidates = self.sortedInsertFeatures
            if let bestFeat = candidates.first {
                self.donorExtractSource = .byFeature
                self.selectInsertFeature(id: bestFeat.id, mergeEndID: "")
            } else if fwdCand != nil && revCand != nil {
                self.donorExtractSource = .byPrimers
                self.applyDonorPrimerPair()
            } else {
                self.donorExtractSource = .byCoordinates
                self.insertStartText = "1"
                self.insertEndText = "\(info.length)"
                self.insertUseReverseComplement = false
                self.insertSeq = info.sequence
                self.insertGeneName = info.fileName.replacingOccurrences(of: ".dna", with: "")
            }
            
            AppState.shared.showToast("已解析供体 \(info.fileName)：共 \(info.featuresCount) 个特征、\(boundPrimers.count) 条引物可供选择")
        } catch {
            self.alertMessage = "解析供体质粒失败: \(error.localizedDescription)"
            self.showAlert = true
        }
    }
    
    /// 仅将引物写入原载体 .dna (自动留备份，并在 SnapGene 中打开)
    public func injectPrimersToVectorDNA() async {
        guard let vecInfo = vectorDNAInfo else {
            alertMessage = "请先选择需要写入的载体 .dna 文件"
            showAlert = true
            return
        }
        guard !primers.isEmpty else {
            alertMessage = "请先生成引物后再执行写入"
            showAlert = true
            return
        }
        
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        
        let url = URL(fileURLWithPath: vecInfo.filePath)
        do {
            let createBackup = AppState.shared.autoCreateSnapGeneBackup
            let res = try await SnapGeneService.shared.injectPrimers(primers, into: url, createBackup: createBackup)
            AppState.shared.showToast("已成功将 \(res.primersAdded) 条引物写入原质粒\(createBackup ? "（已备份）" : "")")
            if AppState.shared.autoOpenInSnapGene {
                SnapGeneService.shared.openInSnapGene(url: url)
            }
        } catch {
            alertMessage = "写入 SnapGene 失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    /// 生成完整重组质粒 .dna 文件并在 SnapGene 中打开
    public func generateRecombinantDNAAndOpen() async {
        guard let vecInfo = vectorDNAInfo else {
            alertMessage = "请先导入目的载体 .dna 文件"
            showAlert = true
            return
        }
        let cleanIns = effectiveInsertSeq
        guard cleanIns.count >= 20 else {
            alertMessage = "插入片段序列过短，无法生成重组质粒"
            showAlert = true
            return
        }
        
        if mode == .pcr {
            resolveCutRangeFromFlanksIfNeeded()
        } else {
            updateEnzymeCutCoordinatesIfNeeded()
        }
        
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        
        let vecURL = URL(fileURLWithPath: vecInfo.filePath)
        let parentDir = AppState.shared.exportSaveLocation.resolveDirectory(fallbackSourceURL: vecURL)
        let cleanName = SnapGeneService.sanitizeFileName(insertGeneName.isEmpty ? "Insert" : insertGeneName)
        let baseVecName = SnapGeneService.sanitizeFileName(vecInfo.fileName.replacingOccurrences(of: ".dna", with: ""))
        let outName = "\(baseVecName)-\(cleanName)-Recombinant.dna"
        let outURL = parentDir.appendingPathComponent(outName)
        
        do {
            let res = try await SnapGeneService.shared.assembleRecombinant(
                vectorURL: vecURL,
                insertSourceURL: insertSourceDNAInfo != nil ? URL(fileURLWithPath: insertSourceDNAInfo!.filePath) : nil,
                insertSeq: cleanIns,
                insertName: cleanName,
                cutStart: self.cutStart,
                cutEnd: self.cutEnd,
                primers: primers,
                outputURL: outURL
            )
            AppState.shared.showToast("已生成重组质粒：\(outName) (插入区间: \(res.insertRange), 总长: \(res.recombinantLength) bp)")
            if AppState.shared.autoOpenInSnapGene {
                SnapGeneService.shared.openInSnapGene(url: outURL)
            }
        } catch {
            alertMessage = "生成重组质粒失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
}

// MARK: - 3. 多片段克隆 ViewModel (支持 2 ~ 11 个片段动态增减 + 载体/各片段 .dna 解析选择)
@MainActor
public final class MultiFragmentViewModel: ObservableObject {
    @Published public var fragments: [String] = ["", ""]
    @Published public var fragmentNames: [Int: String] = [:]
    @Published public var fragmentDonorInfos: [Int: SnapGeneFileInfo] = [:]
    @Published public var fragmentSelectedFeatureIDs: [Int: String] = [:]
    @Published public var fragmentStartTexts: [Int: String] = [:]
    @Published public var fragmentEndTexts: [Int: String] = [:]
    @Published public var fragmentRevComps: [Int: Bool] = [:]
    /// 各片段 5' 接头附加碱基（用于多片段拼接处补码或插入柔性 Linker）以及末段 3' 接头附加碱基
    @Published public var fragmentExtra5Bases: [Int: String] = [:]
    @Published public var terminalExtra3Bases: String = ""
    
    @Published public var vectorDNAInfo: SnapGeneFileInfo? = nil
    @Published public var vectorTargetSource: SingleFragmentViewModel.VectorTargetSource = .byFeature
    @Published public var selectedVectorFeatureID: String = ""
    @Published public var vectorInsertAction: SingleFragmentViewModel.VectorInsertAction = .replaceFeature
    @Published public var availableVectorCutSites: [VectorCutSiteOption] = []
    @Published public var selectedVectorCutSiteID: String = ""
    @Published public var cutStartText: String = "1"
    @Published public var cutEndText: String = "1"
    @Published public var vectorSeqU: String = ""
    @Published public var vectorSeqD: String = ""
    
    @Published public var vectorSeq: String = ""
    @Published public var enzymeSingle: RestrictionEnzyme? = RestrictionEnzymeDatabase.shared.find(name: "BamHI")
    @Published public var primers: [PrimerItem] = []
    @Published public var homologyLength: Int = AppState.shared.defaultHomologyLength
    @Published public var isDesigning: Bool = false
    @Published public var isSnapGeneBusy: Bool = false
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    public var cutStart: Int {
        let maxLen = max(1, vectorDNAInfo?.length ?? max(1, BioSequence.clean(vectorSeq).count))
        let val = Int(cutStartText.trimmingCharacters(in: .whitespaces)) ?? 1
        return max(1, min(val, maxLen + 1))
    }
    
    public var cutEnd: Int {
        let maxLen = max(1, vectorDNAInfo?.length ?? max(1, BioSequence.clean(vectorSeq).count))
        let val = Int(cutEndText.trimmingCharacters(in: .whitespaces)) ?? cutStart
        return max(cutStart - 1, min(val, maxLen))
    }
    
    public var sortedVectorFeatures: [SnapGeneFeature] {
        guard let info = vectorDNAInfo else { return [] }
        return info.features.filter { !$0.segments.isEmpty }.sorted { a, b in
            let aTarget = PlasmidFeatureFilter.targetGenes.matches(a)
            let bTarget = PlasmidFeatureFilter.targetGenes.matches(b)
            if aTarget != bTarget { return aTarget }
            return (a.segments.first?.start ?? 0) < (b.segments.first?.start ?? 0)
        }
    }
    
    public init() {}
    
    public func addFragment() {
        guard fragments.count < 10 else { return }
        fragments.append("")
    }
    
    public func removeFragment(at index: Int) {
        guard fragments.count > 2 && index < fragments.count else { return }
        fragments.remove(at: index)
    }
    
    /// 载入多片段克隆的目标载体 .dna
    public func loadVectorDNA(url: URL) async {
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        do {
            let info = try await SnapGeneService.shared.parseDNAFile(at: url)
            self.vectorDNAInfo = info
            self.vectorSeq = info.sequence
            self.availableVectorCutSites = info.scanAvailableCutSites(maxCutsPerEnzyme: 2)
            if let firstCut = availableVectorCutSites.first {
                self.selectedVectorCutSiteID = firstCut.id
            }
            if let preferred = sortedVectorFeatures.first(where: { $0.name.uppercased() == "A1" }) ?? sortedVectorFeatures.first {
                self.vectorTargetSource = .byFeature
                selectVectorFeature(id: preferred.id, action: .replaceFeature)
            } else if let firstCut = availableVectorCutSites.first {
                self.vectorTargetSource = .byCutSites
                selectVectorCutSite(id: firstCut.id)
            } else {
                applyVectorTargetRange(start: 1, end: 0)
            }
            AppState.shared.showToast("已解析载体 \(info.fileName) (\(info.featuresCount) 个特征，\(availableVectorCutSites.filter { $0.isUnique }.count) 个唯一酶切位点)")
        } catch {
            alertMessage = "解析载体失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    public func selectVectorFeature(id: String, action: SingleFragmentViewModel.VectorInsertAction? = nil) {
        guard let info = vectorDNAInfo,
              let feat = info.features.first(where: { $0.id == id }),
              let firstSeg = feat.segments.first,
              let lastSeg = feat.segments.last else { return }
        self.selectedVectorFeatureID = id
        if let act = action { self.vectorInsertAction = act }
        let s = max(1, firstSeg.start)
        let e = min(info.length, lastSeg.end)
        switch self.vectorInsertAction {
        case .replaceFeature: applyVectorTargetRange(start: s, end: e)
        case .insertUpstream: applyVectorTargetRange(start: s, end: s - 1)
        case .insertDownstream: applyVectorTargetRange(start: min(info.length + 1, e + 1), end: e)
        }
    }
    
    public func selectVectorCutSite(id: String) {
        self.selectedVectorCutSiteID = id
        guard let opt = availableVectorCutSites.first(where: { $0.id == id }) else { return }
        self.enzymeSingle = opt.enzyme
        applyVectorTargetRange(start: opt.position1Based, end: opt.endPosition1Based)
    }
    
    public func applyVectorTargetRange(start: Int, end: Int) {
        guard let info = vectorDNAInfo else { return }
        let seq = BioSequence.clean(info.sequence)
        let len = seq.count
        guard len > 0 else { return }
        let cStart = max(1, min(start, len + 1))
        let cEnd = max(cStart - 1, min(end, len))
        self.cutStartText = "\(cStart)"
        self.cutEndText = "\(cEnd)"
        
        let flankLen = min(60, len)
        let doubled = seq + seq
        let upEnd0 = (cStart - 1 + len) % len
        let upStart0 = (upEnd0 - flankLen + len) % len
        let uSIdx = doubled.index(doubled.startIndex, offsetBy: upStart0)
        let uEIdx = doubled.index(uSIdx, offsetBy: flankLen)
        self.vectorSeqU = String(doubled[uSIdx..<uEIdx])
        
        let downStart0 = cEnd % len
        let dSIdx = doubled.index(doubled.startIndex, offsetBy: downStart0)
        let dEIdx = doubled.index(dSIdx, offsetBy: flankLen)
        self.vectorSeqD = String(doubled[dSIdx..<dEIdx])
    }
    
    /// 为第 index 个插入片段载入供体 .dna 并解析特征供选择
    public func loadFragmentDonorDNA(at index: Int, url: URL) async {
        guard index >= 0 && index < fragments.count else { return }
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        do {
            let info = try await SnapGeneService.shared.parseDNAFile(at: url)
            self.fragmentDonorInfos[index] = info
            let sortedFeats = info.features.filter { !$0.segments.isEmpty }.sorted { a, b in
                let aTarget = PlasmidFeatureFilter.targetGenes.matches(a)
                let bTarget = PlasmidFeatureFilter.targetGenes.matches(b)
                if aTarget != bTarget { return aTarget }
                let aLen = (a.segments.last?.end ?? 0) - (a.segments.first?.start ?? 0)
                let bLen = (b.segments.last?.end ?? 0) - (b.segments.first?.start ?? 0)
                return aLen > bLen
            }
            if let best = sortedFeats.first {
                selectFragmentFeature(at: index, featureID: best.id)
            } else {
                fragmentStartTexts[index] = "1"
                fragmentEndTexts[index] = "\(info.length)"
                fragmentRevComps[index] = false
                fragments[index] = info.sequence
                fragmentNames[index] = info.fileName.replacingOccurrences(of: ".dna", with: "")
            }
            AppState.shared.showToast("片段 \(index + 1) 已解析供体 \(info.fileName) (\(info.featuresCount) 个特征)")
        } catch {
            alertMessage = "解析片段 \(index + 1) 供体失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    public func selectFragmentFeature(at index: Int, featureID: String) {
        guard let info = fragmentDonorInfos[index],
              let feat = info.features.first(where: { $0.id == featureID }),
              let firstSeg = feat.segments.first,
              let lastSeg = feat.segments.last else { return }
        fragmentSelectedFeatureIDs[index] = featureID
        fragmentStartTexts[index] = "\(max(1, firstSeg.start))"
        fragmentEndTexts[index] = "\(min(info.length, lastSeg.end))"
        fragmentRevComps[index] = (feat.directionality == "2")
        fragmentNames[index] = feat.name
        extractFragmentFromCoordinates(at: index)
    }
    
    public func extractFragmentFromCoordinates(at index: Int) {
        guard index >= 0 && index < fragments.count,
              let info = fragmentDonorInfos[index] else { return }
        let seq = BioSequence.clean(info.sequence)
        let len = seq.count
        guard len > 0 else { return }
        let s = max(1, min(Int(fragmentStartTexts[index] ?? "1") ?? 1, len))
        let e = max(s, min(Int(fragmentEndTexts[index] ?? "\(len)") ?? len, len))
        fragmentStartTexts[index] = "\(s)"
        fragmentEndTexts[index] = "\(e)"
        let sIdx = seq.index(seq.startIndex, offsetBy: s - 1)
        let eIdx = seq.index(seq.startIndex, offsetBy: e)
        var sub = String(seq[sIdx..<eIdx])
        if fragmentRevComps[index] == true {
            sub = BioSequence.reverseComplement(sub)
        }
        fragments[index] = sub
    }
    
    public func design() async {
        let validFrags = fragments.map { BioSequence.clean($0) }
        for (i, f) in validFrags.enumerated() {
            if f.count < 50 {
                alertMessage = "插入片段 \(i + 1) 的有效长度小于 50 bp（当前：\(f.count) bp）"
                showAlert = true
                return
            }
        }
        
        isDesigning = true
        defer { isDesigning = false }
        
        do {
            let cTm = AppState.shared.cloningTargetTm
            let tol = AppState.shared.tmTolerance
            let hasAnyExtra = fragmentExtra5Bases.values.contains(where: { !BioSequence.clean($0).isEmpty }) || !BioSequence.clean(terminalExtra3Bases).isEmpty
            if DualEngineCoordinator.shared.currentMode == .offlineOnly || homologyLength != 15 || vectorDNAInfo != nil || abs(cTm - 60.0) > 0.1 || hasAnyExtra {
                var uSeq = vectorSeqU
                var dSeq = vectorSeqD
                if uSeq.isEmpty || dSeq.isEmpty {
                    let cleanVec = BioSequence.clean(vectorSeq)
                    if let enz = enzymeSingle, let pos = enz.findSites(in: cleanVec).first {
                        let sIdx = cleanVec.index(cleanVec.startIndex, offsetBy: pos)
                        let eIdx = cleanVec.index(cleanVec.startIndex, offsetBy: min(cleanVec.count, pos + enz.site.count))
                        uSeq = String(cleanVec[..<sIdx])
                        dSeq = String(cleanVec[eIdx...])
                    } else {
                        uSeq = String(cleanVec.prefix(max(18, cleanVec.count / 2)))
                        dSeq = String(cleanVec.suffix(max(18, cleanVec.count / 2)))
                    }
                }
                self.primers = HomologyArmDesigner.designMultiFragmentClone(
                    fragments: validFrags,
                    vectorSeqU: uSeq,
                    vectorSeqD: dSeq,
                    homologyLength: homologyLength,
                    targetTm: cTm,
                    tolerance: tol,
                    fragmentExtra5Bases: fragmentExtra5Bases,
                    terminalExtra3Bases: terminalExtra3Bases
                )
                AppState.shared.showToast("已生成 \(self.primers.count) 条多片段无缝克隆引物（同源臂: \(homologyLength) bp）")
            } else {
                let res = try await CloneOnlineAPIClient.shared.requestMultiFragmentClone(
                    fragments: validFrags,
                    mode: "Single",
                    vectorSeq: vectorSeq,
                    enzymeName: enzymeSingle?.name ?? "",
                    enzymeSite: enzymeSingle?.site ?? ""
                )
                
                var list: [PrimerItem] = []
                let pairs: [(String?, String?, String)] = [
                    (res.RTB1Fvalue, res.RTB1Rvalue, "片段 1"),
                    (res.RTB2Fvalue, res.RTB2Rvalue, "片段 2"),
                    (res.RTB3Fvalue, res.RTB3Rvalue, "片段 3"),
                    (res.RTB4Fvalue, res.RTB4Rvalue, "片段 4"),
                    (res.RTB5Fvalue, res.RTB5Rvalue, "片段 5")
                ]
                
                for (idx, pair) in pairs.enumerated() {
                    if idx >= validFrags.count { break }
                    if let f = pair.0, !f.isEmpty {
                        let rawF = DualEngineCoordinator.stripHTMLTags(f)
                        let armF = String(BioSequence.clean(rawF).prefix(homologyLength)).lowercased()
                        let (specF, tmF) = DualEngineCoordinator.computeSnapGenePrimerMetrics(fullSequence: rawF, homologyArm: armF)
                        list.append(PrimerItem(
                            name: "Multi-Frag\(idx+1)-F",
                            fullSequence: rawF,
                            homologyArm: armF,
                            specificSequence: specF,
                            tm: tmF,
                            targetPurpose: "\(pair.2) 正向扩增引物",
                            notes: "5' 同源臂 (\(armF.count)bp) + 特异序列 (Tm: \(tmF)℃)",
                            sourceTool: "多片段克隆"
                        ))
                    }
                    if let r = pair.1, !r.isEmpty {
                        let rawR = DualEngineCoordinator.stripHTMLTags(r)
                        let hasRArm = (idx == validFrags.count - 1)
                        let armR = hasRArm ? String(BioSequence.clean(rawR).prefix(homologyLength)).lowercased() : ""
                        let (specR, tmR) = DualEngineCoordinator.computeSnapGenePrimerMetrics(fullSequence: rawR, homologyArm: armR)
                        list.append(PrimerItem(
                            name: "Multi-Frag\(idx+1)-R",
                            fullSequence: rawR,
                            homologyArm: armR,
                            specificSequence: specR,
                            tm: tmR,
                            targetPurpose: "\(pair.2) 反向扩增引物",
                            notes: (armR.isEmpty ? "" : "3' 载体同源臂 (\(armR.count)bp) + ") + "特异序列 (Tm: \(tmR)℃)",
                            sourceTool: "多片段克隆"
                        ))
                    }
                }
                
                self.primers = list
                if let msg = res.promptMessage, !msg.isEmpty {
                    AppState.shared.showToast(msg)
                }
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
    
    public func generateRecombinantDNAAndOpen() async {
        guard let vecInfo = vectorDNAInfo else {
            alertMessage = "请先载入目标载体 .dna 文件"
            showAlert = true
            return
        }
        let validFrags = effectiveFragments.filter { $0.count >= 20 }
        guard !validFrags.isEmpty else { return }
        let combinedInsert = validFrags.joined()
        let combinedName = (0..<fragments.count).compactMap { fragmentNames[$0] }.joined(separator: "-")
        let cleanName = combinedName.isEmpty ? "MultiInsert" : combinedName
        
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        
        let vecURL = URL(fileURLWithPath: vecInfo.filePath)
        let parentDir = AppState.shared.exportSaveLocation.resolveDirectory(fallbackSourceURL: vecURL)
        let safeCleanName = SnapGeneService.sanitizeFileName(cleanName)
        let baseVecName = SnapGeneService.sanitizeFileName(vecInfo.fileName.replacingOccurrences(of: ".dna", with: ""))
        let outName = "\(baseVecName)-\(safeCleanName)-Recombinant.dna"
        let outURL = parentDir.appendingPathComponent(outName)
        
        do {
            let res = try await SnapGeneService.shared.assembleRecombinant(
                vectorURL: vecURL,
                insertSourceURL: nil,
                insertSeq: combinedInsert,
                insertName: cleanName,
                cutStart: self.cutStart,
                cutEnd: self.cutEnd,
                primers: primers,
                outputURL: outURL
            )
            AppState.shared.showToast("已生成多片段重组质粒：\(outName) (\(res.recombinantLength) bp)")
            SnapGeneService.shared.openInSnapGene(url: outURL)
        } catch {
            alertMessage = "生成多片段重组质粒失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    public func addAllToCart() {
        guard !primers.isEmpty else { return }
        AppState.shared.addPrimersToCart(primers)
    }
}

// MARK: - 4. 定点突变 ViewModel (支持载入质粒 .dna + 预览界面/氨基酸网格点选密码子或氨基酸直接突变)
public struct MutagenesisResidueItem: Identifiable, Sendable, Equatable {
    public var id: Int { residueIndex1Based }
    public let residueIndex1Based: Int
    public let codon: String
    public let aminoAcid: Character
    public let threeLetter: String
    public let plasmidStartBp: Int
    public let plasmidEndBp: Int
    public let isReverseStrand: Bool
    
    public var displayTag: String {
        "\(aminoAcid)\(residueIndex1Based)"
    }
    
    public init(
        residueIndex1Based: Int,
        codon: String,
        aminoAcid: Character,
        threeLetter: String,
        plasmidStartBp: Int,
        plasmidEndBp: Int,
        isReverseStrand: Bool
    ) {
        self.residueIndex1Based = residueIndex1Based
        self.codon = codon
        self.aminoAcid = aminoAcid
        self.threeLetter = threeLetter
        self.plasmidStartBp = plasmidStartBp
        self.plasmidEndBp = plasmidEndBp
        self.isReverseStrand = isReverseStrand
    }
}

@MainActor
public final class MutagenesisViewModel: ObservableObject {
    @Published public var mutUp: String = ""
    @Published public var mutDown: String = ""
    @Published public var mutSite: String = ""
    
    // MARK: - 质粒 .dna 载入与交互式密码子/氨基酸选择状态
    @Published public var plasmidDNAInfo: SnapGeneFileInfo? = nil
    @Published public var selectedFeatureID: String = ""
    @Published public var readingFrameOffset: Int = 0
    @Published public var translatedResidues: [MutagenesisResidueItem] = []
    @Published public var selectedResidueIndex: Int = 1
    @Published public var selectedTargetAA: String = "A"
    @Published public var residueSearchText: String = ""
    @Published public var mutTargetStartBp: Int = 1
    @Published public var mutTargetEndBp: Int = 3
    @Published public var mutationSummaryLabel: String = ""
    @Published public var isSnapGeneBusy: Bool = false
    
    @Published public var primers: [PrimerItem] = []
    @Published public var homologyLength: Int = AppState.shared.defaultHomologyLength
    @Published public var isDesigning: Bool = false
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    public init() {}
    
    /// 排序后的质粒特征（目的基因/CDS 优先排在最前）
    public var sortedFeatures: [SnapGeneFeature] {
        guard let info = plasmidDNAInfo else { return [] }
        return info.features.filter { !$0.segments.isEmpty }.sorted { a, b in
            let aTarget = PlasmidFeatureFilter.targetGenes.matches(a)
            let bTarget = PlasmidFeatureFilter.targetGenes.matches(b)
            if aTarget != bTarget { return aTarget }
            let aBack = PlasmidFeatureFilter.isBackbone(a)
            let bBack = PlasmidFeatureFilter.isBackbone(b)
            if aBack != bBack { return !aBack }
            let aLen = (a.segments.last?.end ?? 0) - (a.segments.first?.start ?? 0)
            let bLen = (b.segments.last?.end ?? 0) - (b.segments.first?.start ?? 0)
            return aLen > bLen
        }
    }
    
    /// 搜索过滤后的氨基酸残基列表（支持输入如 "42"、"K42"、"AAG"、"Lys"）
    public var filteredResidues: [MutagenesisResidueItem] {
        let q = residueSearchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !q.isEmpty else { return translatedResidues }
        return translatedResidues.filter { item in
            "\(item.residueIndex1Based)".contains(q)
                || item.displayTag.uppercased().contains(q)
                || item.codon.uppercased().contains(q)
                || item.threeLetter.uppercased().contains(q)
        }
    }
    
    public var currentSelectedResidue: MutagenesisResidueItem? {
        translatedResidues.first(where: { $0.residueIndex1Based == selectedResidueIndex }) ?? translatedResidues.first
    }
    
    /// 载入待定点突变的 SnapGene .dna 质粒文件
    public func loadDNAFile(url: URL) async {
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        do {
            let info = try await SnapGeneService.shared.parseDNAFile(at: url)
            self.plasmidDNAInfo = info
            self.readingFrameOffset = 0
            
            let feats = self.sortedFeatures
            if let best = feats.first(where: { $0.name.uppercased() == "A1" || $0.type.uppercased() == "CDS" }) ?? feats.first {
                selectFeatureForTranslation(id: best.id, frameOffset: 0)
            } else {
                translateRawPlasmidRange(startBp: 1, endBp: min(info.length, 900), isReverse: false, frameOffset: 0)
            }
            AppState.shared.showPlasmidPreview = true
            AppState.shared.showToast("已载入质粒 \(info.fileName) (\(info.length) bp)，可在预览图谱或下方氨基酸列表中直接点选密码子进行突变")
        } catch {
            alertMessage = "解析 SnapGene 质粒失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    /// 选择质粒上的某个 CDS / 基因特征并翻译为氨基酸/密码子序列
    public func selectFeatureForTranslation(id: String, frameOffset: Int? = nil) {
        guard let info = plasmidDNAInfo,
              let feat = info.features.first(where: { $0.id == id }),
              let firstSeg = feat.segments.first,
              let lastSeg = feat.segments.last else { return }
        
        self.selectedFeatureID = id
        if let fo = frameOffset {
            self.readingFrameOffset = max(0, min(2, fo))
        }
        let s = max(1, firstSeg.start)
        let e = min(info.length, lastSeg.end)
        let isRev = (feat.directionality == "2")
        translateRawPlasmidRange(startBp: s, endBp: e, isReverse: isRev, frameOffset: self.readingFrameOffset)
    }
    
    /// 将质粒指定区间按正/负链与阅读框翻译为可点击突变的氨基酸序列
    public func translateRawPlasmidRange(startBp: Int, endBp: Int, isReverse: Bool, frameOffset: Int) {
        guard let info = plasmidDNAInfo else { return }
        let cleanSeq = BioSequence.clean(info.sequence)
        let len = cleanSeq.count
        guard len >= 3 else { return }
        
        let s = max(1, min(startBp, len))
        let e = max(s, min(endBp, len))
        let sIdx = cleanSeq.index(cleanSeq.startIndex, offsetBy: s - 1)
        let eIdx = cleanSeq.index(cleanSeq.startIndex, offsetBy: e)
        let rawSub = String(cleanSeq[sIdx..<eIdx])
        let codingSeq = isReverse ? BioSequence.reverseComplement(rawSub) : rawSub
        let chars = Array(codingSeq)
        
        let safeOff = max(0, min(2, frameOffset))
        var items: [MutagenesisResidueItem] = []
        var idx = safeOff
        var aaNum = 1
        
        while idx + 2 < chars.count {
            let codonStr = String(chars[idx...(idx + 2)])
            let (aa, three) = CodonTranslator.translateTriplet(codonStr)
            let pStart: Int
            let pEnd: Int
            if !isReverse {
                pStart = s + idx
                pEnd = s + idx + 2
            } else {
                pEnd = e - idx
                pStart = e - idx - 2
            }
            items.append(MutagenesisResidueItem(
                residueIndex1Based: aaNum,
                codon: codonStr,
                aminoAcid: aa,
                threeLetter: three,
                plasmidStartBp: max(1, pStart),
                plasmidEndBp: min(len, pEnd),
                isReverseStrand: isReverse
            ))
            idx += 3
            aaNum += 1
        }
        
        self.translatedResidues = items
        if !items.isEmpty {
            let defaultPick = min(items.count, max(1, items.count / 3))
            selectResidueAndMutate(residueIndex1Based: defaultPick, targetAA: selectedTargetAA, customCodon: nil)
        }
    }
    
    /// 用户点击某个氨基酸/密码子并指定目标氨基酸或密码子时，自动更新上下游 60bp 与突变碱基
    public func selectResidueAndMutate(residueIndex1Based: Int, targetAA: String? = nil, customCodon: String? = nil) {
        guard let item = translatedResidues.first(where: { $0.residueIndex1Based == residueIndex1Based }) else { return }
        self.selectedResidueIndex = residueIndex1Based
        if let tAA = targetAA {
            self.selectedTargetAA = tAA
        }
        
        let chosenCodon: String
        let targetLabel: String
        if let custom = customCodon {
            chosenCodon = BioSequence.clean(custom)
            if chosenCodon.count == 3 {
                let (aa, _) = CodonTranslator.translateTriplet(chosenCodon)
                targetLabel = "\(aa)(\(chosenCodon))"
            } else if chosenCodon.isEmpty {
                targetLabel = "Δ缺失"
            } else {
                targetLabel = chosenCodon
            }
        } else if self.selectedTargetAA == "Δ" {
            chosenCodon = ""
            targetLabel = "Δ缺失"
        } else if let opt = CodonTranslator.aminoAcidOptions.first(where: { String($0.singleLetter) == self.selectedTargetAA }) {
            chosenCodon = opt.preferredCodon
            targetLabel = "\(opt.singleLetter)(\(chosenCodon))"
        } else {
            chosenCodon = "GCC"
            targetLabel = "A(GCC)"
        }
        
        // 若已载入质粒，从质粒正链（或根据编码方向）提取该密码子上下游各 60 bp
        if let info = plasmidDNAInfo {
            let cleanPlasmid = BioSequence.clean(info.sequence)
            let len = cleanPlasmid.count
            let doubled = cleanPlasmid + cleanPlasmid
            let cStart = item.plasmidStartBp
            let cEnd = item.plasmidEndBp
            self.mutTargetStartBp = cStart
            self.mutTargetEndBp = cEnd
            
            let flankLen = min(60, max(50, len / 4))
            let upEnd0 = (cStart - 1 + len) % len
            let upStart0 = (upEnd0 - flankLen + len) % len
            let uSIdx = doubled.index(doubled.startIndex, offsetBy: upStart0)
            let uEIdx = doubled.index(uSIdx, offsetBy: flankLen)
            let topUp = String(doubled[uSIdx..<uEIdx])
            
            let downStart0 = cEnd % len
            let dSIdx = doubled.index(doubled.startIndex, offsetBy: downStart0)
            let dEIdx = doubled.index(dSIdx, offsetBy: flankLen)
            let topDown = String(doubled[dSIdx..<dEIdx])
            
            // 若该基因在正链，直接填入 topUp / chosenCodon / topDown；若在负链，正链对应突变序列为 chosenCodon 的反向互补
            if !item.isReverseStrand {
                self.mutUp = topUp
                self.mutSite = chosenCodon
                self.mutDown = topDown
            } else {
                self.mutUp = topUp
                self.mutSite = chosenCodon.isEmpty ? "" : BioSequence.reverseComplement(chosenCodon)
                self.mutDown = topDown
            }
            self.mutationSummaryLabel = "\(item.aminoAcid)\(item.residueIndex1Based)\(targetLabel) [\(item.codon)→\(chosenCodon.isEmpty ? "Δ" : chosenCodon), @\(cStart)..\(cEnd) bp]"
        }
    }
    
    /// 接收来自右侧预览面板或独立弹出预览窗口的交互式密码子点选突变指令
    public func applyInteractiveCodonPayload(_ payload: InteractiveCodonMutationPayload) {
        self.mutUp = payload.upstreamFlank60Bp
        self.mutSite = payload.targetCodon
        self.mutDown = payload.downstreamFlank60Bp
        self.mutTargetStartBp = payload.startBp
        self.mutTargetEndBp = payload.endBp
        self.selectedTargetAA = payload.targetAA
        self.mutationSummaryLabel = "\(payload.wildTypeAA)\(payload.residueIndex1Based)\(payload.targetAA) [\(payload.wildTypeCodon)→\(payload.targetCodon.isEmpty ? "Δ" : payload.targetCodon), @\(payload.startBp)..\(payload.endBp) bp]"
        
        if let matched = translatedResidues.first(where: { $0.plasmidStartBp == payload.startBp }) {
            self.selectedResidueIndex = matched.residueIndex1Based
        }
        AppState.shared.showToast("已在预览中选定突变：\(self.mutationSummaryLabel)")
    }
    
    public func design() async {
        let cleanUp = BioSequence.clean(mutUp)
        let cleanDown = BioSequence.clean(mutDown)
        let cleanSite = BioSequence.clean(mutSite)
        
        guard cleanUp.count >= 50 else {
            alertMessage = "突变位点上游序列至少输入 50 bp（当前：\(cleanUp.count) bp）"
            showAlert = true
            return
        }
        guard cleanDown.count >= 50 else {
            alertMessage = "突变位点下游序列至少输入 50 bp（当前：\(cleanDown.count) bp）"
            showAlert = true
            return
        }
        
        isDesigning = true
        defer { isDesigning = false }
        
        do {
            let mTm = AppState.shared.mutationTargetTm
            let tol = AppState.shared.tmTolerance
            if DualEngineCoordinator.shared.currentMode == .offlineOnly || homologyLength != 15 || abs(mTm - 60.0) > 0.1 {
                let res = HomologyArmDesigner.designMutagenesis(
                    mutUp: cleanUp,
                    mutDown: cleanDown,
                    mutSite: cleanSite,
                    homologyLength: homologyLength,
                    targetTm: mTm,
                    tolerance: tol
                )
                self.primers = [res.primerF, res.primerR]
                AppState.shared.showToast("已成功生成定点突变引物（\(mutationSummaryLabel.isEmpty ? "同源重叠臂: \(homologyLength) bp" : mutationSummaryLabel)）")
            } else {
                // 在线官方请求 (15 bp 国标模式)
                let res = try await CloneOnlineAPIClient.shared.requestSingleMutation(
                    mutUp: cleanUp,
                    mutDown: cleanDown,
                    mutSite: cleanSite
                )
                
                var list: [PrimerItem] = []
                if let f = res.PrimerFvalue, !f.isEmpty {
                    let rawF = DualEngineCoordinator.stripHTMLTags(f)
                    let armF = String(BioSequence.clean(rawF).prefix(homologyLength)).lowercased()
                    let (specF, tmF) = DualEngineCoordinator.computeSnapGenePrimerMetrics(fullSequence: rawF, homologyArm: armF)
                    list.append(PrimerItem(
                        name: "Mutation-F",
                        fullSequence: rawF,
                        homologyArm: armF,
                        specificSequence: specF,
                        tm: tmF,
                        targetPurpose: "定点突变正向引物",
                        notes: "5' 突变同源臂 (\(armF.count)bp) + 3' 特异结合端 (Tm: \(tmF)℃)",
                        sourceTool: "定点突变"
                    ))
                }
                if let r = res.PrimerRvalue, !r.isEmpty {
                    let rawR = DualEngineCoordinator.stripHTMLTags(r)
                    let armR = String(BioSequence.clean(rawR).prefix(homologyLength)).lowercased()
                    let (specR, tmR) = DualEngineCoordinator.computeSnapGenePrimerMetrics(fullSequence: rawR, homologyArm: armR)
                    list.append(PrimerItem(
                        name: "Mutation-R",
                        fullSequence: rawR,
                        homologyArm: armR,
                        specificSequence: specR,
                        tm: tmR,
                        targetPurpose: "定点突变反向引物",
                        notes: "5' 突变同源臂 (\(armR.count)bp) + 3' 特异结合端 (Tm: \(tmR)℃)",
                        sourceTool: "定点突变"
                    ))
                }
                self.primers = list
                if let msg = res.promptMessage, !msg.isEmpty {
                    AppState.shared.showToast(msg)
                }
            }
            
            // 记录定点突变节点到构建谱系树
            if !self.primers.isEmpty {
                let mutLabel = !mutationSummaryLabel.isEmpty ? mutationSummaryLabel : (cleanSite.isEmpty ? "Δ缺失" : "★\(cleanSite)")
                let prodSeq = cleanUp + cleanSite + cleanDown
                let origBp = plasmidDNAInfo?.length ?? (cleanUp.count + cleanDown.count)
                let baseFeats: [(String, Int, Int)] = [
                    ("5' Flank", 1, cleanUp.count),
                    ("3' Flank", cleanUp.count + 1, cleanUp.count + cleanDown.count),
                    ("AmpR", cleanUp.count + cleanDown.count + 800, cleanUp.count + cleanDown.count + 1660),
                    ("ori", cleanUp.count + cleanDown.count + 2200, cleanUp.count + cleanDown.count + 2790)
                ]
                let shifts = ConstructHistoryManager.computeFeatureShifts(
                    originalFeatures: baseFeats,
                    editStartBp: cleanUp.count + 1,
                    editEndBp: cleanUp.count,
                    insertedBp: cleanSite.count,
                    insertedFeatureName: mutLabel
                )
                let ovhTop = String(cleanUp.suffix(9)) + cleanSite + String(cleanDown.prefix(9))
                let node = ConstructHistoryNode(
                    parentNodeID: ConstructHistoryManager.shared.activeNodeID,
                    constructName: "pMut-\(cleanSite.isEmpty ? "Del" : cleanSite)",
                    operationType: .mutagenesis,
                    parentVectorName: plasmidDNAInfo?.fileName.replacingOccurrences(of: ".dna", with: "") ?? "WT-Template",
                    parentLengthBp: origBp,
                    insertOrActionSummary: mutLabel,
                    productLengthBp: origBp + cleanSite.count - max(0, mutTargetEndBp - mutTargetStartBp + 1),
                    homologyArmLength: homologyLength,
                    junctionOverhangs: [
                        JunctionOverhangDetail(title: "突变位点环化重叠臂", topStrandSnippet: ovhTop, bottomStrandSnippet: BioSequence.complement(ovhTop), enzymeOrArmName: mutLabel, homologyLength: homologyLength)
                    ],
                    featureShifts: shifts,
                    primers: self.primers,
                    productSequence: prodSeq
                )
                ConstructHistoryManager.shared.recordNode(node)
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
    
    /// 生成定点突变后的新 .dna 质粒文件并在 SnapGene 中打开
    public func generateMutantDNAAndOpen() async {
        guard let info = plasmidDNAInfo else {
            alertMessage = "请先载入待突变的模板质粒 .dna 文件"
            showAlert = true
            return
        }
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        
        let vecURL = URL(fileURLWithPath: info.filePath)
        let cleanSite = BioSequence.clean(mutSite)
        let tag = SnapGeneService.sanitizeFileName(cleanSite.isEmpty ? "Del_\(mutTargetStartBp)_\(mutTargetEndBp)" : "Mut_\(mutTargetStartBp)_\(cleanSite)")
        let baseVecName = SnapGeneService.sanitizeFileName(info.fileName.replacingOccurrences(of: ".dna", with: ""))
        let outName = "\(baseVecName)-\(tag).dna"
        let parentDir = AppState.shared.exportSaveLocation.resolveDirectory(fallbackSourceURL: vecURL)
        let outURL = parentDir.appendingPathComponent(outName)
        
        do {
            if cleanSite.isEmpty {
                _ = try await SnapGeneService.shared.deleteFragment(
                    vectorURL: vecURL,
                    delStart: mutTargetStartBp,
                    delEnd: mutTargetEndBp,
                    primers: primers,
                    outputURL: outURL
                )
            } else {
                _ = try await SnapGeneService.shared.assembleRecombinant(
                    vectorURL: vecURL,
                    insertSourceURL: nil,
                    insertSeq: cleanSite,
                    insertName: mutationSummaryLabel.isEmpty ? "Mut:\(cleanSite)" : mutationSummaryLabel,
                    cutStart: mutTargetStartBp,
                    cutEnd: mutTargetEndBp,
                    primers: primers,
                    outputURL: outURL
                )
            }
            AppState.shared.showToast("已生成突变质粒：\(outName)")
            if AppState.shared.autoOpenInSnapGene {
                SnapGeneService.shared.openInSnapGene(url: outURL)
            }
        } catch {
            alertMessage = "生成突变质粒失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    public func addAllToCart() {
        guard !primers.isEmpty else { return }
        AppState.shared.addPrimersToCart(primers)
    }
}

// MARK: - 4.5 质粒大片段删除/敲除 ViewModel
@MainActor
public final class FragmentDeletionViewModel: ObservableObject {
    public enum SelectionMode: String, CaseIterable, Identifiable {
        case byFeature = "① 按质粒特征"
        case byPrimers = "② 按已有引物对"
        case byCoordinates = "③ 按起止坐标"
        case bySequence = "④ 按待删除序列"
        public var id: String { rawValue }
        
        public var shortTitle: String {
            switch self {
            case .byFeature: return "① 特征"
            case .byPrimers: return "② 引物"
            case .byCoordinates: return "③ 坐标"
            case .bySequence: return "④ 序列"
            }
        }
    }
    
    @Published public var plasmidSeq: String = ""
    @Published public var plasmidDNAInfo: SnapGeneFileInfo? = nil
    @Published public var selectedDNAFileURL: URL? = nil
    @Published public var selectedDNAFileName: String = ""
    @Published public var plasmidLength: Int = 0
    
    @Published public var selectionMode: SelectionMode = .byCoordinates
    @Published public var selectedDeleteFeatureID: String = ""
    @Published public var selectedDelRevPrimerID: String = ""
    @Published public var selectedDelFwdPrimerID: String = ""
    @Published public var targetDelSeq: String = ""
    @Published public var delStartText: String = ""
    @Published public var delEndText: String = ""
    
    @Published public var homologyLength: Int = AppState.shared.defaultHomologyLength
    @Published public var isDesigning: Bool = false
    @Published public var isExporting: Bool = false
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    @Published public var primers: [PrimerItem] = []
    @Published public var designResult: HomologyArmDesigner.FragmentDeletionDesignResult? = nil
    @Published public var lastExportedURL: URL? = nil
    
    public var sortedFeatures: [SnapGeneFeature] {
        guard let info = plasmidDNAInfo else { return [] }
        return info.features.filter { !$0.segments.isEmpty }.sorted { a, b in
            let aTarget = PlasmidFeatureFilter.targetGenes.matches(a)
            let bTarget = PlasmidFeatureFilter.targetGenes.matches(b)
            if aTarget != bTarget { return aTarget }
            return (a.segments.first?.start ?? 0) < (b.segments.first?.start ?? 0)
        }
    }
    
    public var boundPrimers: [SnapGenePrimer] {
        plasmidDNAInfo?.validBoundPrimers ?? []
    }
    
    public init() {}
    
    public func clear() {
        plasmidSeq = ""
        plasmidDNAInfo = nil
        selectedDNAFileName = ""
        selectedDNAFileURL = nil
        plasmidLength = 0
        selectedDeleteFeatureID = ""
        selectedDelRevPrimerID = ""
        selectedDelFwdPrimerID = ""
        targetDelSeq = ""
        delStartText = ""
        delEndText = ""
        primers = []
        designResult = nil
        lastExportedURL = nil
    }
    
    public func loadSampleData() {
        plasmidSeq = "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA"
            + "CGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA"
        plasmidDNAInfo = nil
        selectedDNAFileName = "pET-28a-EGFP-Sample"
        selectedDNAFileURL = nil
        selectionMode = .byCoordinates
        delStartText = "120"
        delEndText = "360"
        targetDelSeq = ""
        primers = []
        designResult = nil
        lastExportedURL = nil
    }
    
    public func loadDNAFile(url: URL) async {
        do {
            let info = try await SnapGeneService.shared.parseDNAFile(at: url)
            self.plasmidDNAInfo = info
            self.selectedDNAFileURL = url
            self.selectedDNAFileName = url.lastPathComponent
            self.plasmidSeq = info.sequence
            self.plasmidLength = info.length
            
            let bps = info.validBoundPrimers
            self.selectedDelRevPrimerID = (bps.first(where: { !$0.isForwardStrand }) ?? bps.first)?.id ?? ""
            self.selectedDelFwdPrimerID = (bps.first(where: { $0.isForwardStrand }) ?? bps.last)?.id ?? ""
            
            if let firstFeat = self.sortedFeatures.first {
                self.selectionMode = .byFeature
                self.selectDeleteFeature(id: firstFeat.id)
            } else {
                self.selectionMode = .byCoordinates
            }
            AppState.shared.showToast("已解析质粒 \(url.lastPathComponent)：\(info.featuresCount) 个特征、\(bps.count) 条引物可供选择")
        } catch {
            self.alertMessage = "解析 .dna 文件失败: \(error.localizedDescription)"
            self.showAlert = true
        }
    }
    
    public func selectDeleteFeature(id: String) {
        guard let info = plasmidDNAInfo,
              let feat = info.features.first(where: { $0.id == id }),
              let firstSeg = feat.segments.first,
              let lastSeg = feat.segments.last else { return }
        self.selectedDeleteFeatureID = id
        self.delStartText = "\(max(1, firstSeg.start))"
        self.delEndText = "\(min(info.length, lastSeg.end))"
    }
    
    public func applyDeletePrimerPair() {
        let bps = self.boundPrimers
        guard let revP = bps.first(where: { $0.id == selectedDelRevPrimerID }),
              let fwdP = bps.first(where: { $0.id == selectedDelFwdPrimerID }),
              let rEnd = revP.endBp,
              let fStart = fwdP.startBp else { return }
        let s = min(rEnd + 1, fStart)
        let e = max(s, fStart - 1)
        self.delStartText = "\(s)"
        self.delEndText = "\(e)"
    }
    
    public func design() async {
        let cleanPlasmid = BioSequence.clean(plasmidSeq)
        guard cleanPlasmid.count >= 100 else {
            alertMessage = "质粒序列过短，至少需要 100 bp（当前：\(cleanPlasmid.count) bp）"
            showAlert = true
            return
        }
        
        var calculatedStart = 0
        var calculatedEnd = 0
        
        if selectionMode == .bySequence {
            let cleanDel = BioSequence.clean(targetDelSeq)
            guard cleanDel.count >= 1 else {
                alertMessage = "请输入待删除片段序列"
                showAlert = true
                return
            }
            if let range = cleanPlasmid.range(of: cleanDel) {
                let startPos = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.lowerBound) + 1
                let endPos = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.upperBound)
                calculatedStart = startPos
                calculatedEnd = endPos
            } else {
                let rc = BioSequence.reverseComplement(cleanDel)
                if let range = cleanPlasmid.range(of: rc) {
                    let startPos = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.lowerBound) + 1
                    let endPos = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.upperBound)
                    calculatedStart = startPos
                    calculatedEnd = endPos
                } else {
                    alertMessage = "在质粒中未找到待删除序列片段，请核对输入或使用坐标/特征模式"
                    showAlert = true
                    return
                }
            }
        } else {
            guard let s = Int(delStartText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let e = Int(delEndText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  s >= 1, e <= cleanPlasmid.count, s <= e else {
                alertMessage = "删除起止坐标无效（有效范围: 1 ~ \(cleanPlasmid.count)）"
                showAlert = true
                return
            }
            calculatedStart = s
            calculatedEnd = e
        }
        
        isDesigning = true
        defer { isDesigning = false }
        
        let res = HomologyArmDesigner.designFragmentDeletion(
            plasmidSeq: cleanPlasmid,
            delStart: calculatedStart,
            delEnd: calculatedEnd,
            homologyLength: homologyLength,
            targetTm: AppState.shared.mutationTargetTm,
            tolerance: AppState.shared.tmTolerance
        )
        
        if let msg = res.promptMessage {
            alertMessage = msg
            showAlert = true
            return
        }
        
        self.designResult = res
        self.primers = [res.primerF, res.primerR]
        
        // 记录质粒大片段敲除节点到构建谱系树
        let pName = selectedDNAFileName.isEmpty ? "Target-Plasmid" : selectedDNAFileName.replacingOccurrences(of: ".dna", with: "")
        let baseFeats: [(String, Int, Int)] = [
            ("保留骨架上游", 1, max(1, res.delStart - 1)),
            ("待敲除片段 (Δ)", res.delStart, res.delEnd),
            ("保留骨架下游", min(cleanPlasmid.count, res.delEnd + 1), cleanPlasmid.count)
        ]
        let shifts = ConstructHistoryManager.computeFeatureShifts(
            originalFeatures: baseFeats,
            editStartBp: res.delStart,
            editEndBp: res.delEnd,
            insertedBp: 0,
            insertedFeatureName: nil
        )
        let seamSnippet = String(res.newPlasmidSeq.prefix(max(0, res.delStart - 1)).suffix(9))
            + String(res.newPlasmidSeq.dropFirst(max(0, res.delStart - 1)).prefix(9))
        let delNode = ConstructHistoryNode(
            parentNodeID: ConstructHistoryManager.shared.activeNodeID,
            constructName: "\(pName)_Δ\(res.deletedLength)bp",
            operationType: .fragmentDeletion,
            parentVectorName: pName,
            parentLengthBp: cleanPlasmid.count,
            insertOrActionSummary: "Δ 敲除 \(res.delStart)..\(res.delEnd) (-\(res.deletedLength) bp)",
            productLengthBp: res.newPlasmidSeq.count,
            homologyArmLength: homologyLength,
            junctionOverhangs: [
                JunctionOverhangDetail(
                    title: "跨切点反向 PCR 环化接缝",
                    topStrandSnippet: seamSnippet,
                    bottomStrandSnippet: BioSequence.complement(seamSnippet),
                    enzymeOrArmName: "Δ切点接缝",
                    homologyLength: homologyLength
                )
            ],
            featureShifts: shifts,
            primers: self.primers,
            productSequence: res.newPlasmidSeq
        )
        ConstructHistoryManager.shared.recordNode(delNode)
        
        AppState.shared.showToast("已成功生成反向 PCR 缺失引物（删除 \(res.deletedLength) bp）")
    }
    
    public func addAllToCart() {
        guard !primers.isEmpty else { return }
        AppState.shared.addPrimersToCart(primers)
    }
    
    public func exportToSnapGene(openAfterExport: Bool = true) async {
        guard let res = designResult else { return }
        guard let srcURL = selectedDNAFileURL else {
            alertMessage = "当前为纯文本序列模式。如需直接导出 SnapGene .dna 文件，请先点击「载入质粒 .dna」导入原始质粒模板。"
            showAlert = true
            return
        }
        
        isExporting = true
        defer { isExporting = false }
        
        do {
            let outName = srcURL.deletingPathExtension().lastPathComponent + "_Δ\(res.deletedLength)bp.dna"
            let outURL = srcURL.deletingLastPathComponent().appendingPathComponent(outName)
            
            _ = try await SnapGeneService.shared.deleteFragment(
                vectorURL: srcURL,
                delStart: res.delStart,
                delEnd: res.delEnd,
                primers: self.primers,
                outputURL: outURL
            )
            
            self.lastExportedURL = outURL
            AppState.shared.showToast("已生成删除后 SnapGene 质粒: \(outName)")
            
            if openAfterExport {
                SnapGeneService.shared.openInSnapGene(url: outURL)
            }
        } catch {
            alertMessage = "导出 SnapGene 文件失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
}

// MARK: - 5. 重组反应 DNA 使用量计算器 ViewModel
@MainActor
public final class CalculatorViewModel: ObservableObject {
    @Published public var cloneType: DNAMolarCalculator.CloneType = .single
    @Published public var vectorName: String = ""
    @Published public var vectorLengthKb: String = "5.0"
    @Published public var vectorConcentration: String = "50"
    /// 载体自定义投入量 (ng)，留空时默认采用公式推荐值
    @Published public var vectorCustomNg: String = ""
    
    @Published public var insertNames: [String] = ["片段 1", "片段 2"]
    @Published public var insertLengths: [String] = ["1.0", "1.0"]
    @Published public var insertConcs: [String] = ["20", "20"]
    /// 插入片段自定义投入量 (ng)，留空时默认采用公式推荐值
    @Published public var insertCustomNgs: [String] = ["", ""]
    
    public init() {}
    
    /// 解析载体长度 (bp)
    public var parsedVectorLengthBp: Int {
        let raw = Double(vectorLengthKb.trimmingCharacters(in: .whitespaces)) ?? 5.0
        let kb = DNAMolarCalculator.normalizeLengthToKb(raw)
        return max(0, Int((kb * 1000.0).rounded()))
    }
    
    /// 解析指定插入片段长度 (bp)
    public func parsedInsertLengthBp(at index: Int) -> Int {
        let lenStr = index < insertLengths.count ? insertLengths[index] : "1.0"
        let raw = Double(lenStr.trimmingCharacters(in: .whitespaces)) ?? 1.0
        let kb = DNAMolarCalculator.normalizeLengthToKb(raw)
        return max(0, Int((kb * 1000.0).rounded()))
    }
    
    public var vectorResult: DNAMolarCalculator.CalculationResult {
        let len = Double(vectorLengthKb.trimmingCharacters(in: .whitespaces)) ?? 5.0
        let conc = Double(vectorConcentration.trimmingCharacters(in: .whitespaces)) ?? 50.0
        let custom = Double(vectorCustomNg.trimmingCharacters(in: .whitespaces))
        return DNAMolarCalculator.calculate(
            cloneType: cloneType,
            isVector: true,
            lengthKb: max(0.05, len),
            concentrationNgPerUl: max(0.1, conc),
            customNg: custom
        )
    }
    
    public func insertResult(at index: Int) -> DNAMolarCalculator.CalculationResult {
        let lenStr = index < insertLengths.count ? insertLengths[index] : "1.0"
        let concStr = index < insertConcs.count ? insertConcs[index] : "20"
        let ngStr = index < insertCustomNgs.count ? insertCustomNgs[index] : ""
        let len = Double(lenStr.trimmingCharacters(in: .whitespaces)) ?? 1.0
        let conc = Double(concStr.trimmingCharacters(in: .whitespaces)) ?? 20.0
        let custom = Double(ngStr.trimmingCharacters(in: .whitespaces))
        return DNAMolarCalculator.calculate(
            cloneType: cloneType,
            isVector: false,
            lengthKb: max(0.05, len),
            concentrationNgPerUl: max(0.1, conc),
            customNg: custom
        )
    }
    
    /// 计算 20 μL 反应体系中除 10 μL 2× Mix 与 DNA 外的剩余 ddH₂O 体积 (μL)
    public var remainingWaterVolumeUl: Double {
        var dnaVol = 0.0
        if cloneType != .simple {
            dnaVol += (vectorResult.recommendedVol ?? 0)
        }
        let count = (cloneType == .multi) ? insertLengths.count : 1
        for idx in 0..<count {
            dnaVol += (insertResult(at: idx).recommendedVol ?? 0)
        }
        return max(0.0, 20.0 - 10.0 - dnaVol)
    }
    
    public var remainingWaterFormatted: String {
        let w = remainingWaterVolumeUl
        return String(format: "%.2f μL (补齐至 20 μL)", w)
    }
    
    public func addInsertSlot() {
        guard insertLengths.count < 11 else { return }
        let nextIdx = insertLengths.count + 1
        insertNames.append("片段 \(nextIdx)")
        insertLengths.append("1.0")
        insertConcs.append("20")
        insertCustomNgs.append("")
    }
    
    public func removeInsertSlot(at index: Int) {
        guard insertLengths.count > 1, index < insertLengths.count else { return }
        insertLengths.remove(at: index)
        if index < insertNames.count { insertNames.remove(at: index) }
        if index < insertConcs.count { insertConcs.remove(at: index) }
        if index < insertCustomNgs.count { insertCustomNgs.remove(at: index) }
    }
    
    /// 一键从同源重组克隆模块同步载体长度与插入片段长度
    public func syncFromHomologousCloning(
        type: DNAMolarCalculator.CloneType,
        vectorName: String = "",
        vectorLengthBp: Int,
        inserts: [(name: String, lengthBp: Int)],
        navigate: Bool = true
    ) {
        self.cloneType = type
        self.vectorName = vectorName
        if vectorLengthBp > 0 {
            self.vectorLengthKb = String(format: "%.3f", Double(vectorLengthBp) / 1000.0)
        }
        if !inserts.isEmpty {
            self.insertNames = inserts.enumerated().map { idx, item in
                item.name.isEmpty ? "片段 \(idx + 1)" : item.name
            }
            self.insertLengths = inserts.map { item in
                let bp = max(50, item.lengthBp)
                return String(format: "%.3f", Double(bp) / 1000.0)
            }
            while self.insertConcs.count < inserts.count {
                self.insertConcs.append("20")
            }
            while self.insertCustomNgs.count < inserts.count {
                self.insertCustomNgs.append("")
            }
        }
        if navigate {
            AppState.shared.selectedNav = .dnaCalculator
        }
        let vecDesc = vectorLengthBp > 0 ? "载体 \(vectorLengthBp) bp" : "载体未设"
        let insDesc = inserts.map { "\($0.name.isEmpty ? "片段" : $0.name) \($0.lengthBp) bp" }.joined(separator: " + ")
        AppState.shared.showToast("已同步至用量计算：\(vecDesc)，\(insDesc)")
    }
}

// MARK: - 6. 序列工具与 Tm 测算 ViewModel
@MainActor
public final class SequenceToolViewModel: ObservableObject {
    @Published public var inputSeq: String = ""
    @Published public var outputSeq: String = ""
    @Published public var tmResult: TmCalculator.Result? = nil
    @Published public var isCalculating: Bool = false
    
    public init() {}
    
    public var cleanLength: Int {
        BioSequence.clean(inputSeq).count
    }
    
    public var cleanGC: Double {
        BioSequence.gcContent(inputSeq)
    }
    
    public func doReverseComplement() {
        outputSeq = BioSequence.reverseComplement(BioSequence.clean(inputSeq))
    }
    
    public func doReverse() {
        outputSeq = BioSequence.reverse(BioSequence.clean(inputSeq))
    }
    
    public func doComplement() {
        outputSeq = BioSequence.complement(BioSequence.clean(inputSeq))
    }
    
    public func calculateTm() async {
        let clean = BioSequence.clean(inputSeq)
        guard !clean.isEmpty else { return }
        isCalculating = true
        defer { isCalculating = false }
        tmResult = await DualEngineCoordinator.shared.calculateTm(sequence: clean)
    }
    
    public func copyOutput() {
        guard !outputSeq.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(outputSeq, forType: .string)
        AppState.shared.showToast("已复制到剪贴板")
    }
}

// MARK: - 7. 五大质粒构建模块：成对引物改名与分区一键清除扩展

extension EntryCloneViewModel {
    public func clearSequenceSection() {
        sequence = ""
    }
    
    public func clearEnzymesSection() {
        hasEnzymes = false
        enzyme5 = RestrictionEnzymeDatabase.shared.find(name: "BamHI")
        enzyme3 = RestrictionEnzymeDatabase.shared.find(name: "EcoRI")
    }
    
    public func clearPrimersSection() {
        primerF = nil
        primerR = nil
    }
    
    public func renamePrimerPair(prefix rawPrefix: String) {
        let pfx = PrimerItem.extractPairPrefix(from: rawPrefix)
        guard !pfx.isEmpty else { return }
        if var f = primerF {
            f.name = "\(pfx)-F"
            primerF = f
        }
        if var r = primerR {
            r.name = "\(pfx)-R"
            primerR = r
        }
        WorkspaceSessionManager.shared.autoSaveInBackground()
        AppState.shared.showToast("已成对重命名引物为 \(pfx)-F / \(pfx)-R")
    }
    
    public func renameSinglePrimer(isForward: Bool, newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if isForward, var f = primerF {
            f.name = clean
            primerF = f
        } else if !isForward, var r = primerR {
            r.name = clean
            primerR = r
        }
        WorkspaceSessionManager.shared.autoSaveInBackground()
    }
}

extension SingleFragmentViewModel {
    public func clearVectorSection() {
        vectorDNAInfo = nil
        vectorSeq = ""
        vectorSeqU = ""
        vectorSeqD = ""
        cutStartText = "1"
        cutEndText = "1"
        availableVectorCutSites = []
        selectedVectorFeatureID = ""
        selectedVectorRevPrimerID = ""
        selectedVectorFwdPrimerID = ""
        selectedVectorCutSite5ID = ""
        selectedVectorCutSite3ID = ""
    }
    
    public func clearInsertSection() {
        insertSourceDNAInfo = nil
        insertSeq = ""
        insertGeneName = "TargetGene"
        insertStartText = "1"
        insertEndText = "1"
        baseInsertStartBp = 1
        baseInsertEndBp = 1
        insertUseReverseComplement = false
        removeTerminalStopCodon = false
        detectedTerminalStopCodon = nil
        terminalCodonStatusText = ""
        selectedInsertFeatureID = ""
        selectedInsertMergeEndFeatureID = ""
        selectedDonorFwdPrimerID = ""
        selectedDonorRevPrimerID = ""
        extra5Bases = ""
        extra3Bases = ""
    }
    
    public func clearExtraBasesSection() {
        extra5Bases = ""
        extra3Bases = ""
    }
    
    /// 含 5'/3' 接头附加碱基的完整插入序列（正向 5'→3'）
    public var effectiveInsertSeq: String {
        BioSequence.clean(extra5Bases) + BioSequence.clean(insertSeq) + BioSequence.clean(extra3Bases)
    }
    
    /// 阅读框余数（0 表示 3n 整倍数完整密码子；1 或 2 表示存在移码）
    public var readingFrameRemainder: Int {
        effectiveInsertSeq.count % 3
    }
    
    /// 凑齐 3n 阅读框所需补充的碱基数（0、1 或 2 bp）
    public var neededPaddingBasesCount: Int {
        readingFrameRemainder == 0 ? 0 : (3 - readingFrameRemainder)
    }
    
    /// 推荐的安全补码碱基（1 bp 补 G，2 bp 补 GC，避免拼出 TAA/TAG/TGA 终止子）
    public var suggestedPaddingBases: String {
        switch neededPaddingBasesCount {
        case 1: return "G"
        case 2: return "GC"
        default: return ""
        }
    }
    
    /// 检测 5' 或 3' 接头附加区及边界是否意外拼出阅读框内终止密码子 (TAA/TAG/TGA)
    public var junctionInFrameStopCodonWarning: String? {
        let eff = effectiveInsertSeq
        guard eff.count >= 6 else { return nil }
        let stops: Set<String> = ["TAA", "TAG", "TGA"]
        let ex5Len = BioSequence.clean(extra5Bases).count
        let ex3Len = BioSequence.clean(extra3Bases).count
        // 检查前几个密码子（覆盖 5' 附加碱基及交界处）
        if ex5Len > 0 {
            let checkCodonCount = min(eff.count / 3, (ex5Len / 3) + 2)
            for c in 0..<checkCodonCount {
                let s = eff.index(eff.startIndex, offsetBy: c * 3)
                let e = eff.index(s, offsetBy: 3)
                let codon = String(eff[s..<e]).uppercased()
                if stops.contains(codon) {
                    return "⛔ 5' 接头第 \(c + 1) 个密码子拼出了终止子 (\(codon))，会导致翻译提前终止！"
                }
            }
        }
        // 检查末尾密码子（若用户开启了 3' 附加碱基）
        if ex3Len > 0 && eff.count % 3 == 0 {
            let totalCodons = eff.count / 3
            let startCodon = max(0, totalCodons - (ex3Len / 3) - 2)
            for c in startCodon..<totalCodons {
                let s = eff.index(eff.startIndex, offsetBy: c * 3)
                let e = eff.index(s, offsetBy: 3)
                let codon = String(eff[s..<e]).uppercased()
                if stops.contains(codon) {
                    return "⛔ 3' 接头区域拼出了终止密码子 (\(codon))，会导致 C 端融合标签无法翻译！"
                }
            }
        }
        return nil
    }
    
    public func clearPrimersSection() {
        primers = []
    }
    
    public func clear() {
        clearVectorSection()
        clearInsertSection()
        clearPrimersSection()
        homologyLength = AppState.shared.defaultHomologyLength
    }
    
    /// 成对重命名指定引物对（pairIndex = 0 表示插入扩增引物对 F/R，pairIndex = 1 表示载体扩增引物对 F/R）
    public func renamePrimerPair(pairIndex: Int, prefix rawPrefix: String) {
        let pfx = PrimerItem.extractPairPrefix(from: rawPrefix)
        guard !pfx.isEmpty else { return }
        let fIdx = pairIndex * 2
        let rIdx = pairIndex * 2 + 1
        var updated = primers
        if updated.indices.contains(fIdx) {
            updated[fIdx].name = "\(pfx)-F"
        }
        if updated.indices.contains(rIdx) {
            updated[rIdx].name = "\(pfx)-R"
        }
        primers = updated
        WorkspaceSessionManager.shared.autoSaveInBackground()
        AppState.shared.showToast("已成对重命名引物为 \(pfx)-F / \(pfx)-R")
    }
    
    public func renameSinglePrimer(at index: Int, newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, primers.indices.contains(index) else { return }
        var updated = primers
        updated[index].name = clean
        primers = updated
        WorkspaceSessionManager.shared.autoSaveInBackground()
    }
}

extension MultiFragmentViewModel {
    /// 包含各片段 5' 附加碱基与末段 3' 附加碱基的有效片段序列数组
    public var effectiveFragments: [String] {
        fragments.enumerated().map { idx, raw in
            let ex5 = BioSequence.clean(fragmentExtra5Bases[idx] ?? "")
            let ex3 = (idx == fragments.count - 1) ? BioSequence.clean(terminalExtra3Bases) : ""
            return ex5 + BioSequence.clean(raw) + ex3
        }
    }
    
    public var totalEffectiveInsertLength: Int {
        effectiveFragments.reduce(0) { $0 + $1.count }
    }
    
    public var totalReadingFrameRemainder: Int {
        totalEffectiveInsertLength % 3
    }
    
    public var neededTotalPaddingCount: Int {
        totalReadingFrameRemainder == 0 ? 0 : (3 - totalReadingFrameRemainder)
    }
    
    public var suggestedTotalPaddingBases: String {
        switch neededTotalPaddingCount {
        case 1: return "G"
        case 2: return "GC"
        default: return ""
        }
    }
    
    public func clearVectorSection() {
        vectorDNAInfo = nil
        vectorSeq = ""
        vectorSeqU = ""
        vectorSeqD = ""
        cutStartText = "1"
        cutEndText = "1"
        availableVectorCutSites = []
        selectedVectorFeatureID = ""
        selectedVectorCutSiteID = ""
    }
    
    public func clearFragment(at index: Int) {
        guard fragments.indices.contains(index) else { return }
        fragments[index] = ""
        fragmentNames.removeValue(forKey: index)
        fragmentDonorInfos.removeValue(forKey: index)
        fragmentSelectedFeatureIDs.removeValue(forKey: index)
        fragmentStartTexts.removeValue(forKey: index)
        fragmentEndTexts.removeValue(forKey: index)
        fragmentRevComps.removeValue(forKey: index)
        fragmentExtra5Bases.removeValue(forKey: index)
        if index == fragments.count - 1 {
            terminalExtra3Bases = ""
        }
    }
    
    public func clearAllFragmentsSection() {
        fragments = ["", ""]
        fragmentNames = [:]
        fragmentDonorInfos = [:]
        fragmentSelectedFeatureIDs = [:]
        fragmentStartTexts = [:]
        fragmentEndTexts = [:]
        fragmentRevComps = [:]
        fragmentExtra5Bases = [:]
        terminalExtra3Bases = ""
    }
    
    public func clearPrimersSection() {
        primers = []
    }
    
    public func clear() {
        clearVectorSection()
        clearAllFragmentsSection()
        clearPrimersSection()
        homologyLength = AppState.shared.defaultHomologyLength
    }
    
    public func renamePrimerPair(pairIndex: Int, prefix rawPrefix: String) {
        let pfx = PrimerItem.extractPairPrefix(from: rawPrefix)
        guard !pfx.isEmpty else { return }
        let fIdx = pairIndex * 2
        let rIdx = pairIndex * 2 + 1
        var updated = primers
        if updated.indices.contains(fIdx) {
            updated[fIdx].name = "\(pfx)-F"
        }
        if updated.indices.contains(rIdx) {
            updated[rIdx].name = "\(pfx)-R"
        }
        primers = updated
        WorkspaceSessionManager.shared.autoSaveInBackground()
        AppState.shared.showToast("已成对重命名引物为 \(pfx)-F / \(pfx)-R")
    }
    
    public func renameSinglePrimer(at index: Int, newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, primers.indices.contains(index) else { return }
        var updated = primers
        updated[index].name = clean
        primers = updated
        WorkspaceSessionManager.shared.autoSaveInBackground()
    }
}

extension MutagenesisViewModel {
    public func clearPlasmidSection() {
        plasmidDNAInfo = nil
        selectedFeatureID = ""
        translatedResidues = []
        residueSearchText = ""
        mutationSummaryLabel = ""
    }
    
    public func clearUpstreamSection() {
        mutUp = ""
    }
    
    public func clearMutationSiteSection() {
        mutSite = ""
    }
    
    public func clearDownstreamSection() {
        mutDown = ""
    }
    
    public func clearPrimersSection() {
        primers = []
    }
    
    public func clear() {
        clearPlasmidSection()
        mutUp = ""
        mutSite = ""
        mutDown = ""
        primers = []
        homologyLength = AppState.shared.defaultHomologyLength
    }
    
    public func renamePrimerPair(pairIndex: Int = 0, prefix rawPrefix: String) {
        let pfx = PrimerItem.extractPairPrefix(from: rawPrefix)
        guard !pfx.isEmpty else { return }
        let fIdx = pairIndex * 2
        let rIdx = pairIndex * 2 + 1
        var updated = primers
        if updated.indices.contains(fIdx) {
            updated[fIdx].name = "\(pfx)-F"
        }
        if updated.indices.contains(rIdx) {
            updated[rIdx].name = "\(pfx)-R"
        }
        primers = updated
        WorkspaceSessionManager.shared.autoSaveInBackground()
        AppState.shared.showToast("已成对重命名引物为 \(pfx)-F / \(pfx)-R")
    }
    
    public func renameSinglePrimer(at index: Int, newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, primers.indices.contains(index) else { return }
        var updated = primers
        updated[index].name = clean
        primers = updated
        WorkspaceSessionManager.shared.autoSaveInBackground()
    }
}

extension FragmentDeletionViewModel {
    public func clearPlasmidSection() {
        plasmidSeq = ""
        plasmidDNAInfo = nil
        selectedDNAFileName = ""
        selectedDNAFileURL = nil
        plasmidLength = 0
        selectedDeleteFeatureID = ""
        selectedDelRevPrimerID = ""
        selectedDelFwdPrimerID = ""
    }
    
    public func clearDeletionTargetSection() {
        targetDelSeq = ""
        delStartText = ""
        delEndText = ""
        selectedDeleteFeatureID = ""
    }
    
    public func clearPrimersSection() {
        primers = []
        designResult = nil
    }
    
    public func renamePrimerPair(pairIndex: Int = 0, prefix rawPrefix: String) {
        let pfx = PrimerItem.extractPairPrefix(from: rawPrefix)
        guard !pfx.isEmpty else { return }
        let fIdx = pairIndex * 2
        let rIdx = pairIndex * 2 + 1
        var updated = primers
        if updated.indices.contains(fIdx) {
            updated[fIdx].name = "\(pfx)-F"
        }
        if updated.indices.contains(rIdx) {
            updated[rIdx].name = "\(pfx)-R"
        }
        primers = updated
        WorkspaceSessionManager.shared.autoSaveInBackground()
        AppState.shared.showToast("已成对重命名引物为 \(pfx)-F / \(pfx)-R")
    }
    
    public func renameSinglePrimer(at index: Int, newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, primers.indices.contains(index) else { return }
        var updated = primers
        updated[index].name = clean
        primers = updated
        WorkspaceSessionManager.shared.autoSaveInBackground()
    }
}

// MARK: - 8. 同源重组载体/插入基因长度计算与一键送入 DNA 用量计算器扩展

extension EntryCloneViewModel {
    /// pCE2-TA/Blunt 入门克隆标准载体长度 (bp)
    public var vectorLengthBp: Int { 3957 }
    
    public func sendLengthsToCalculator(navigate: Bool = true) {
        let insLen = max(0, cleanLength)
        WorkspaceSessionManager.shared.calculatorVM.syncFromHomologousCloning(
            type: .simple,
            vectorName: "pCE2-TA/Blunt",
            vectorLengthBp: vectorLengthBp,
            inserts: [("入门插入片段", insLen)],
            navigate: navigate
        )
    }
}

extension SingleFragmentViewModel {
    /// 原始载体全长 (bp)
    public var rawVectorLengthBp: Int {
        if let info = vectorDNAInfo, info.length > 0 {
            return info.length
        }
        let fullVec = BioSequence.clean(vectorSeq).count
        if fullVec > 0 { return fullVec }
        return BioSequence.clean(vectorSeqU).count + BioSequence.clean(vectorSeqD).count
    }
    
    /// 载体在克隆位点切除的片段长度 (bp)
    public var deletedVectorBp: Int {
        guard vectorDNAInfo != nil || BioSequence.clean(vectorSeq).count >= 200 else { return 0 }
        return max(0, cutEnd - cutStart + 1)
    }
    
    /// 线性化后实际参与同源重组的有效载体骨架长度 (bp)
    public var effectiveVectorBackboneLengthBp: Int {
        let raw = rawVectorLengthBp
        guard raw > 0 else { return 0 }
        let eff = raw - deletedVectorBp
        return eff > 50 ? eff : raw
    }
    
    /// 纯插入目的基因长度 (bp)
    public var cleanInsertLengthBp: Int {
        BioSequence.clean(insertSeq).count
    }
    
    /// 含两端同源臂与附加碱基的 PCR 扩增产物总长度 (bp)
    public var pcrAmpliconInsertLengthBp: Int {
        let eff = effectiveInsertSeq.count
        guard eff > 0 else { return 0 }
        return eff + 2 * homologyLength
    }
    
    public func sendLengthsToCalculator(navigate: Bool = true) {
        let vecName = vectorDNAInfo?.fileName.replacingOccurrences(of: ".dna", with: "") ?? "线性化载体"
        let vecBp = effectiveVectorBackboneLengthBp > 0 ? effectiveVectorBackboneLengthBp : 5000
        let insName = insertGeneName.trimmingCharacters(in: .whitespaces).isEmpty ? "插入基因" : insertGeneName
        let insBp = cleanInsertLengthBp > 0 ? cleanInsertLengthBp : 1000
        WorkspaceSessionManager.shared.calculatorVM.syncFromHomologousCloning(
            type: .single,
            vectorName: vecName,
            vectorLengthBp: vecBp,
            inserts: [(insName, insBp)],
            navigate: navigate
        )
    }
}

extension MultiFragmentViewModel {
    /// 原始载体全长 (bp)
    public var rawVectorLengthBp: Int {
        if let info = vectorDNAInfo, info.length > 0 {
            return info.length
        }
        return BioSequence.clean(vectorSeq).count
    }
    
    /// 载体在克隆位点切除的片段长度 (bp)
    public var deletedVectorBp: Int {
        guard vectorDNAInfo != nil || BioSequence.clean(vectorSeq).count >= 200 else { return 0 }
        return max(0, cutEnd - cutStart + 1)
    }
    
    /// 线性化后实际参与同源重组的有效载体骨架长度 (bp)
    public var effectiveVectorBackboneLengthBp: Int {
        let raw = rawVectorLengthBp
        guard raw > 0 else { return 0 }
        let eff = raw - deletedVectorBp
        return eff > 50 ? eff : raw
    }
    
    /// 各插入片段的长度数组 (bp)
    public var fragmentLengthsBp: [Int] {
        fragments.map { BioSequence.clean($0).count }
    }
    
    /// 全部插入片段总长度 (bp)
    public var totalInsertLengthBp: Int {
        fragmentLengthsBp.reduce(0, +)
    }
    
    public func sendLengthsToCalculator(navigate: Bool = true) {
        let vecName = vectorDNAInfo?.fileName.replacingOccurrences(of: ".dna", with: "") ?? "多片段线性化载体"
        let vecBp = effectiveVectorBackboneLengthBp > 0 ? effectiveVectorBackboneLengthBp : 5000
        let insItems: [(String, Int)] = fragments.enumerated().map { idx, seq in
            let len = BioSequence.clean(seq).count
            let rawName = fragmentNames[idx]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let customName = (!rawName.isEmpty && rawName != "Frag\(idx + 1)")
                ? rawName
                : "片段 \(idx + 1)"
            return (customName, len > 0 ? len : 1000)
        }
        WorkspaceSessionManager.shared.calculatorVM.syncFromHomologousCloning(
            type: .multi,
            vectorName: vecName,
            vectorLengthBp: vecBp,
            inserts: insItems,
            navigate: navigate
        )
    }
}



