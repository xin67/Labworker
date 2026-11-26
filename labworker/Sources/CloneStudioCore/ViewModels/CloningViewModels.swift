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
            alertMessage = L10n.tr("插入片段长度必须大于等于 50 bp（当前有效长度：\(clean.count) bp）", "Insert fragment must be >= 50 bp (current valid length: \(clean.count) bp)")
            showAlert = true
            return
        }
        
        if hasEnzymes {
            guard let e5 = enzyme5, let e3 = enzyme3 else {
                alertMessage = L10n.t("请先选择 5' 端和 3' 端的酶切位点")
                showAlert = true
                return
            }
            if e5.name == e3.name {
                alertMessage = L10n.tr("两端添加的酶切位点不能相同（\(e5.name)）", "5' and 3' restriction sites cannot be identical (\(e5.name))")
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
                    JunctionOverhangDetail(title: L10n.t("5' URS 同源接头"), topStrandSnippet: "GGATCTTCCAGAGAT" + String(clean.prefix(9)), bottomStrandSnippet: BioSequence.complement("GGATCTTCCAGAGAT" + String(clean.prefix(9))), enzymeOrArmName: "5' URS", homologyLength: 15),
                    JunctionOverhangDetail(title: L10n.t("3' DRS 同源接头"), topStrandSnippet: String(clean.suffix(9)) + "ATCGTCGAACGGCAG", bottomStrandSnippet: BioSequence.complement(String(clean.suffix(9)) + "ATCGTCGAACGGCAG"), enzymeOrArmName: "3' DRS", homologyLength: 15)
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
                self.terminalCodonStatusText = L10n.tr("已去终止子 \(tail3) (-3bp)", "Trimmed Stop \(tail3) (-3 bp)")
            } else {
                self.insertStartText = "\(rawS)"
                self.insertEndText = "\(rawE)"
                self.insertSeq = rawSub
                self.terminalCodonStatusText = L10n.tr("检测到3'终止子 \(tail3)", "Detected 3' Stop \(tail3)")
            }
        } else {
            self.detectedTerminalStopCodon = nil
            self.removeTerminalStopCodon = false
            self.insertStartText = "\(rawS)"
            self.insertEndText = "\(rawE)"
            self.insertSeq = rawSub
            if tail3.count == 3 {
                let (_, three) = CodonTranslator.translateTriplet(tail3)
                self.terminalCodonStatusText = L10n.tr("末端无终止子 (3'端: \(tail3)/\(three))", "No Terminal Stop (3': \(tail3)/\(three))")
            } else {
                self.terminalCodonStatusText = L10n.t("末端无终止子")
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
            AppState.shared.showToast(L10n.tr("已自动去除 3' 末端终止子 \(stop) (-3 bp)", "Trimmed 3' terminal stop codon \(stop) (-3 bp)"))
        } else {
            AppState.shared.showToast(L10n.tr("已恢复 3' 末端终止子 \(stop) (+3 bp)", "Restored 3' terminal stop codon \(stop) (+3 bp)"))
        }
    }
    
    public func design() async {
        let cleanInsert = BioSequence.clean(insertSeq)
        guard cleanInsert.count >= 50 else {
            alertMessage = L10n.t("插入片段长度必须大于等于 50 bp")
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
                        throw NSError(domain: "Clone", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.t("请先选择单酶切位点")])
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
                        throw NSError(domain: "Clone", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.t("请选择双酶切 5' 与 3' 位点")])
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
                    let extraTag = (!cleanEx5.isEmpty || !cleanEx3.isEmpty) ? L10n.tr("，含接头附加碱基 +\(cleanEx5.count + cleanEx3.count) bp", ", +\(cleanEx5.count + cleanEx3.count) bp linker bases") : ""
                    AppState.shared.showToast(L10n.tr("已生成引物（同源臂: \(homologyLength) bp\(extraTag)，目标位点: \(cutStart)..\(cutEnd)）", "Designed primers (Homology Arm: \(homologyLength) bp\(extraTag), site: \(cutStart)..\(cutEnd))"))
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
                        targetPurpose: L10n.t("单片段克隆插入正向引物"),
                        notes: L10n.tr("5' 载体同源臂 (\(armF.count)bp) + 特异性序列 (Tm: \(tmF)℃)", "5' Vector Arm (\(armF.count) bp) + Specific (Tm: \(tmF) °C)"),
                        sourceTool: L10n.t("单片段克隆")
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
                        targetPurpose: L10n.t("单片段克隆插入反向引物"),
                        notes: L10n.tr("3' 载体同源臂 (\(armR.count)bp) + 特异性序列 (Tm: \(tmR)℃)", "3' Vector Arm (\(armR.count) bp) + Specific (Tm: \(tmR) °C)"),
                        sourceTool: L10n.t("单片段克隆")
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
                        targetPurpose: L10n.t("载体反向PCR扩增正向引物"),
                        notes: L10n.tr("结合于目标替换位点 3' 下游载体骨架 (Tm: \(tmCF)℃)", "Binds downstream of 3' replacement junction on vector (Tm: \(tmCF) °C)"),
                        sourceTool: L10n.t("单片段克隆")
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
                        targetPurpose: L10n.t("载体反向PCR扩增反向引物"),
                        notes: L10n.tr("结合于目标替换位点 5' 上游载体骨架 (Tm: \(tmCR)℃)", "Binds upstream of 5' replacement junction on vector (Tm: \(tmCR) °C)"),
                        sourceTool: L10n.t("单片段克隆")
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
                    insertOrActionSummary: delLen > 0 ? L10n.tr("替换 \(cStart)..\(cEnd) (Δ\(delLen)bp) → \(insName) (+\(effIns.count)bp)", "Replace \(cStart)..\(cEnd) (Δ\(delLen) bp) → \(insName) (+\(effIns.count) bp)") : L10n.tr("插入 @\(cStart) → \(insName) (+\(effIns.count)bp)", "Insert @\(cStart) → \(insName) (+\(effIns.count) bp)"),
                    productLengthBp: vecBp - delLen + effIns.count,
                    homologyArmLength: homologyLength,
                    junctionOverhangs: [
                        JunctionOverhangDetail(title: L10n.tr("5' 载体-片段同源接头 (@\(cStart))", "5' Vector–Insert Junction (@\(cStart))"), topStrandSnippet: arm5 + String(cleanInsert.prefix(8)), bottomStrandSnippet: BioSequence.complement(arm5 + String(cleanInsert.prefix(8))), enzymeOrArmName: mode == .single ? (enzymeSingle?.name ?? "5'Arm") : "5'Arm", homologyLength: homologyLength),
                        JunctionOverhangDetail(title: L10n.tr("3' 片段-载体同源接头 (@\(cEnd))", "3' Insert–Vector Junction (@\(cEnd))"), topStrandSnippet: String(cleanInsert.suffix(8)) + arm3, bottomStrandSnippet: BioSequence.complement(String(cleanInsert.suffix(8)) + arm3), enzymeOrArmName: mode == .double ? (enzyme3?.name ?? "3'Arm") : "3'Arm", homologyLength: homologyLength)
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
            
            AppState.shared.showToast(L10n.tr("已解析载体 \(info.fileName)：\(info.featuresCount) 个特征、\(boundPrimers.count) 条引物、\(cutSites.filter { $0.isUnique }.count) 个唯一酶切位点", "Parsed vector \(info.fileName): \(info.featuresCount) features, \(boundPrimers.count) primers, \(cutSites.filter { $0.isUnique }.count) unique cutters"))
        } catch {
            self.alertMessage = L10n.tr("解析 SnapGene 载体失败: \(error.localizedDescription)", "Failed to parse SnapGene vector: \(error.localizedDescription)")
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
            
            AppState.shared.showToast(L10n.tr("已解析供体 \(info.fileName)：共 \(info.featuresCount) 个特征、\(boundPrimers.count) 条引物可供选择", "Parsed donor \(info.fileName): \(info.featuresCount) features, \(boundPrimers.count) primers available"))
        } catch {
            self.alertMessage = L10n.tr("解析供体质粒失败: \(error.localizedDescription)", "Failed to parse donor plasmid: \(error.localizedDescription)")
            self.showAlert = true
        }
    }
    
    /// 仅将引物写入原载体 .dna (自动留备份，并在 SnapGene 中打开)
    public func injectPrimersToVectorDNA() async {
        guard let vecInfo = vectorDNAInfo else {
            alertMessage = L10n.t("请先选择需要写入的载体 .dna 文件")
            showAlert = true
            return
        }
        guard !primers.isEmpty else {
            alertMessage = L10n.t("请先生成引物后再执行写入")
            showAlert = true
            return
        }
        
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        
        let url = URL(fileURLWithPath: vecInfo.filePath)
        do {
            let createBackup = AppState.shared.autoCreateSnapGeneBackup
            let res = try await SnapGeneService.shared.injectPrimers(primers, into: url, createBackup: createBackup)
            AppState.shared.showToast(L10n.tr("已成功将 \(res.primersAdded) 条引物写入原质粒\(createBackup ? "（已备份）" : "")", "Injected \(res.primersAdded) primer(s) into plasmid\(createBackup ? " (backup saved)" : "")"))
            if AppState.shared.autoOpenInSnapGene {
                SnapGeneService.shared.openInSnapGene(url: url)
            }
        } catch {
            alertMessage = L10n.tr("写入 SnapGene 失败: \(error.localizedDescription)", "Failed to write SnapGene file: \(error.localizedDescription)")
            showAlert = true
        }
    }
    
    /// 生成完整重组质粒 .dna 文件并在 SnapGene 中打开
    public func generateRecombinantDNAAndOpen() async {
        guard let vecInfo = vectorDNAInfo else {
            alertMessage = L10n.t("请先导入目的载体 .dna 文件")
            showAlert = true
            return
        }
        let cleanIns = effectiveInsertSeq
        guard cleanIns.count >= 20 else {
            alertMessage = L10n.t("插入片段序列过短，无法生成重组质粒")
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
            AppState.shared.showToast(L10n.tr("已生成重组质粒：\(outName) (插入区间: \(res.insertRange), 总长: \(res.recombinantLength) bp)", "Generated recombinant plasmid: \(outName) (Insert: \(res.insertRange), Total: \(res.recombinantLength) bp)"))
            if AppState.shared.autoOpenInSnapGene {
                SnapGeneService.shared.openInSnapGene(url: outURL)
            }
        } catch {
            alertMessage = L10n.tr("生成重组质粒失败: \(error.localizedDescription)", "Failed to generate recombinant plasmid: \(error.localizedDescription)")
            showAlert = true
        }
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
        AppState.shared.showToast(L10n.tr("已成对重命名引物为 \(pfx)-F / \(pfx)-R", "Renamed primer pair to \(pfx)-F / \(pfx)-R"))
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
                    return L10n.tr("⛔ 5' 接头第 \(c + 1) 个密码子拼出了终止子 (\(codon))，会导致翻译提前终止！", "⛔ Stop codon (\(codon)) formed at 5' junction codon #\(c + 1), causing premature termination!")
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
                    return L10n.tr("⛔ 3' 接头区域拼出了终止密码子 (\(codon))，会导致 C 端融合标签无法翻译！", "⛔ Stop codon (\(codon)) formed in 3' junction, preventing C-terminal tag translation!")
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
        AppState.shared.showToast(L10n.tr("已成对重命名引物为 \(pfx)-F / \(pfx)-R", "Renamed primer pair to \(pfx)-F / \(pfx)-R"))
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
            inserts: [(L10n.t("入门插入片段"), insLen)],
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
        let vecName = vectorDNAInfo?.fileName.replacingOccurrences(of: ".dna", with: "") ?? L10n.t("线性化载体")
        let vecBp = effectiveVectorBackboneLengthBp > 0 ? effectiveVectorBackboneLengthBp : 5000
        let insName = insertGeneName.trimmingCharacters(in: .whitespaces).isEmpty ? L10n.t("插入基因") : insertGeneName
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
