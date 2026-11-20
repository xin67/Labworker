import Foundation
import SwiftUI
import AppKit

/// 质粒池单条已解析质粒记录（包含完整序列、特征注释、已绑定引物、唯一酶切位点、载体骨架、目的基因、抗性与启动子标签）
public struct PlasmidPoolItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var aliasName: String
    public var categoryTag: String
    public var notes: String
    public var addedAt: Date
    public var dnaInfo: SnapGeneFileInfo
    public var uniqueCutSites: [String]
    public var resistanceMarkers: [String]
    public var promoters: [String]
    public var vectorBackbone: String?
    public var targetGenes: [String]?
    
    public init(
        id: String? = nil,
        name: String,
        aliasName: String = "",
        categoryTag: String = "",
        notes: String = "",
        addedAt: Date = Date(),
        dnaInfo: SnapGeneFileInfo,
        uniqueCutSites: [String]? = nil,
        resistanceMarkers: [String]? = nil,
        promoters: [String]? = nil,
        vectorBackbone: String? = nil,
        targetGenes: [String]? = nil
    ) {
        self.id = id ?? dnaInfo.filePath
        self.name = name
        self.aliasName = aliasName
        self.dnaInfo = dnaInfo
        self.addedAt = addedAt
        self.notes = notes
        
        let scannedUnique = uniqueCutSites ?? Self.extractUniqueCutSiteLabels(from: dnaInfo)
        let scannedRes = Self.extractResistances(from: dnaInfo, plasmidName: name)
        let scannedProm = Self.extractPromoters(from: dnaInfo)
        let scannedVec = vectorBackbone ?? Self.extractVectorBackbone(name: name, info: dnaInfo)
        let scannedGenes = targetGenes ?? Self.extractTargetGenes(name: name, info: dnaInfo, vectorName: scannedVec)
        
        self.uniqueCutSites = scannedUnique
        self.resistanceMarkers = scannedRes.isEmpty ? (resistanceMarkers ?? []) : scannedRes
        self.promoters = scannedProm.isEmpty ? (promoters ?? []) : scannedProm
        self.vectorBackbone = scannedVec
        self.targetGenes = scannedGenes
        self.categoryTag = Self.inferCategory(name: name, features: dnaInfo.features, promoters: self.promoters)
    }
    
    public static func == (lhs: PlasmidPoolItem, rhs: PlasmidPoolItem) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.aliasName == rhs.aliasName && lhs.categoryTag == rhs.categoryTag && lhs.notes == rhs.notes
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(aliasName)
        hasher.combine(categoryTag)
    }
    
    /// 解析出的规范载体骨架名称（如 pCMV、pETDuet、pcDNA3.1、pLKO.1 等）
    public var resolvedVectorBackbone: String {
        if let v = vectorBackbone, !v.isEmpty { return v }
        return Self.extractVectorBackbone(name: name, info: dnaInfo)
    }
    
    /// 解析出的规范目的基因列表（如 TP53、BRCA1、MYC、A1、B1 等）
    public var resolvedTargetGenes: [String] {
        if let g = targetGenes, !g.isEmpty { return g }
        return Self.extractTargetGenes(name: name, info: dnaInfo, vectorName: resolvedVectorBackbone)
    }
    
    /// 解析出的规范抗性标签列表（过滤掉 AmpR promoter 等启动子伪匹配）
    public var resolvedResistances: [String] {
        let clean = Self.extractResistances(from: dnaInfo, plasmidName: name)
        return clean.isEmpty ? resistanceMarkers.filter { !$0.lowercased().contains("promoter") } : clean
    }
    
    /// 重新标准化元数据（用于修复旧版磁盘缓存中的错误分类与启动子抗性标签）
    public func refreshedMetadata() -> PlasmidPoolItem {
        var copy = self
        let vec = Self.extractVectorBackbone(name: name, info: dnaInfo)
        let genes = Self.extractTargetGenes(name: name, info: dnaInfo, vectorName: vec)
        let res = Self.extractResistances(from: dnaInfo, plasmidName: name)
        let prom = Self.extractPromoters(from: dnaInfo)
        copy.vectorBackbone = vec
        copy.targetGenes = genes
        copy.resistanceMarkers = res
        copy.promoters = prom
        copy.categoryTag = Self.inferCategory(name: name, features: dnaInfo.features, promoters: prom)
        return copy
    }
    
    public var gcPercent: Double {
        BioSequence.gcContent(dnaInfo.sequence)
    }
    
    public var cdsAndGeneFeatures: [SnapGeneFeature] {
        dnaInfo.features.filter { f in
            let t = f.type.uppercased()
            return t == "CDS" || t == "GENE" || f.name.count >= 2
        }
    }
    
    public static func extractUniqueCutSiteLabels(from info: SnapGeneFileInfo) -> [String] {
        let sites = info.scanAvailableCutSites(maxCutsPerEnzyme: 1)
        return sites.prefix(24).map { "\($0.enzyme.name) @\($0.position1Based)" }
    }
    
    /// 精准提取抗性标记（严格排除 AmpR promoter 等启动子/调控区，并标准化为 AmpR / KanR / NeoR / PuroR 等）
    public static func extractResistances(from info: SnapGeneFileInfo, plasmidName: String = "") -> [String] {
        var found: [String] = []
        func appendUnique(_ tag: String) {
            if !found.contains(tag) { found.append(tag) }
        }
        
        for f in info.features {
            let lowName = f.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let lowType = f.type.lowercased()
            // 严格排除启动子、终止子、引物结合区等非抗性编码特征
            if lowName.contains("promoter") || lowName.contains("terminator") || lowName.contains("operator") || lowType.contains("promoter") || lowType.contains("terminator") || lowType.contains("primer_bind") || lowType.contains("rep_origin") {
                continue
            }
            if lowName.contains("ampr") || lowName == "amp" || lowName.contains("ampicillin") || lowName == "bla" {
                appendUnique("AmpR")
            }
            if lowName.contains("neor") || lowName == "neo" || lowName.contains("neomycin") || lowName.contains("g418") {
                appendUnique("NeoR")
            }
            if lowName.contains("kanr") || lowName == "kan" || lowName.contains("kanamycin") {
                appendUnique("KanR")
            }
            if lowName.contains("puror") || lowName == "puro" || lowName.contains("puromycin") || lowName == "pac" {
                appendUnique("PuroR")
            }
            if lowName.contains("hygr") || lowName.contains("hygro") || lowName == "hph" {
                appendUnique("HygroR")
            }
            if lowName.contains("cmr") || lowName.contains("chlr") || lowName.contains("chloramphenicol") || lowName == "cat" {
                appendUnique("CmR")
            }
            if lowName.contains("smr") || lowName.contains("specr") || lowName.contains("spectinomycin") || lowName == "aada" {
                appendUnique("SpecR")
            }
            if lowName.contains("tetr") || lowName.contains("tetracycline") {
                appendUnique("TetR")
            }
            if lowName.contains("zeor") || lowName.contains("zeocin") || lowName == "sh ble" {
                appendUnique("ZeoR")
            }
            if lowName.contains("blar") || lowName.contains("blasticidin") || lowName == "bsr" {
                appendUnique("BlaR")
            }
        }
        
        // 补充从文件名中识别明确标注的抗性（如 -Neo-、-Puro-、-Kan-）
        let upperName = plasmidName.uppercased()
        if upperName.contains("-NEO") || upperName.contains("_NEO") { appendUnique("NeoR") }
        if upperName.contains("-PURO") || upperName.contains("_PURO") { appendUnique("PuroR") }
        if upperName.contains("-KAN") || upperName.contains("_KAN") { appendUnique("KanR") }
        if upperName.contains("-AMP") || upperName.contains("_AMP") { appendUnique("AmpR") }
        if upperName.contains("-HYG") || upperName.contains("_HYG") { appendUnique("HygroR") }
        
        return found
    }
    
    /// 精准提取载体骨架名称（如 pCMV、pETDuet、pcDNA3.1、pLKO.1、lentiCRISPR 等）
    public static func extractVectorBackbone(name: String, info: SnapGeneFileInfo) -> String {
        let trimmed = name.replacingOccurrences(
            of: #"^[^A-Za-z0-9]+"#,
            with: "",
            options: .regularExpression
        )
        let upper = trimmed.uppercased()
        
        let knownVectors: [(pattern: String, canonical: String)] = [
            ("PETDUET", "pETDuet"),
            ("PETDUET", "pETDuet"),
            ("PET-28A", "pET-28a"),
            ("PET28A", "pET-28a"),
            ("PET-28B", "pET-28b"),
            ("PET-22B", "pET-22b"),
            ("PET-15B", "pET-15b"),
            ("PCDNA3.1", "pcDNA3.1"),
            ("PCDNA3", "pcDNA3"),
            ("PCMV", "pCMV"),
            ("PLKO.1", "pLKO.1"),
            ("PLKO", "pLKO.1"),
            ("LENTICRISPR", "lentiCRISPR"),
            ("PX458", "pX458"),
            ("PX459", "pX459"),
            ("PLVX", "pLVX"),
            ("PAAV", "pAAV"),
            ("PGEX", "pGEX"),
            ("PCOLD", "pCold"),
            ("PCE2", "pCE2"),
            ("PEGFP", "pEGFP"),
            ("PMCHERRY", "pmCherry"),
            ("PUC19", "pUC19"),
            ("PUC57", "pUC57"),
            ("PMD18", "pMD18-T"),
            ("PMD19", "pMD19-T"),
            ("PGL3", "pGL3"),
            ("PGL4", "pGL4"),
            ("PFASTBAC", "pFastBac")
        ]
        for kv in knownVectors {
            if upper.contains(kv.pattern) {
                return kv.canonical
            }
        }
        
        let tokens = trimmed.components(separatedBy: CharacterSet(charactersIn: "-_ ()（）[]"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let first = tokens.first,
           first.count >= 3,
           first.count <= 16,
           (first.hasPrefix("p") || first.hasPrefix("P")) {
            return first
        }
        
        // 从特征推断常见骨架
        let featUpper = info.features.map { $0.name.uppercased() }.joined(separator: " ")
        if featUpper.contains("CMV") && featUpper.contains("SV40") {
            return "pCMV/pcDNA"
        }
        if featUpper.contains("T7 PROMOTER") && featUpper.contains("LACI") {
            return "pET 系列"
        }
        if featUpper.contains("U6") && featUpper.contains("LTR") {
            return "慢病毒载体"
        }
        return "通用载体"
    }
    
    /// 精准提取质粒中的目的基因/外源插入基因名称（自动剔除骨架基因、常见蛋白标签与中文备注注释）
    public static func extractTargetGenes(name: String, info: SnapGeneFileInfo, vectorName: String) -> [String] {
        var genes: [String] = []
        func appendGene(_ raw: String) {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 2 && cleaned.count <= 20 else { return }
            if !genes.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                genes.append(cleaned)
            }
        }
        
        let ignoredFeatureKeywords = [
            "ampr", "kanr", "neor", "puror", "hygr", "cmr", "specr", "tetr", "zeor", "blar",
            "ori", "f1 ori", "sv40", "laci", "lac operator", "lac promoter", "rop", "bom", "cap binding", "m13",
            "promoter", "enhancer", "terminator", "polya", "poly(a)", "kozak", "rbs", "wpre", "ltr", "ires", " packaging",
            "myc", "3xmyc", "3×myc", "flag", "3xflag", "3×flag", "his", "6xhis", "6×his", "s-tag", "stag", "tev", "gst", "ha", "v5",
            "egfp", "gfp", "mcherry", "rfp", "yfp", "bfp", "luciferase", "cas9",
            "同源臂", "删除", "氨基酸", "突变", "测序", "引物", "接头", "linker", "urs", "drs"
        ]
        
        // 1. 从 SnapGene 特征列表中提取 CDS / 目的基因特征
        for f in info.features {
            let fname = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowName = fname.lowercased()
            let lowType = f.type.lowercased()
            guard fname.count >= 2 && fname.count <= 20 else { continue }
            if lowType.contains("promoter") || lowType.contains("terminator") || lowType.contains("rep_origin") || lowType.contains("primer_bind") || lowType.contains("regulatory") || lowType.contains("poly") || lowType.contains("protein_bind") || lowType.contains("rbs") || lowType.contains("enhancer") {
                continue
            }
            if ignoredFeatureKeywords.contains(where: { lowName.contains($0) }) {
                continue
            }
            let segStart = f.segments.first?.start ?? 1
            let segEnd = f.segments.last?.end ?? 1
            let len = max(0, segEnd - segStart + 1)
            if (lowType == "cds" || lowType == "gene" || len >= 60) {
                appendGene(fname)
            }
        }
        
        // 2. 从质粒文件名补充提取基因名（例如 pETDuet-EGFP-Demo 中的 MYC）
        let cleanedFileName = name
            .replacingOccurrences(of: #"^[^A-Za-z0-9]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "(human)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(mouse)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(rat)", with: "", options: .caseInsensitive)
        
        let rawTokens = cleanedFileName.components(separatedBy: CharacterSet(charactersIn: "-_ ()（）[]"))
        let stopTokens: Set<String> = [
            vectorName.uppercased(), "PCMV", "PETDUET", "PETDUET", "PCDNA3.1", "PCDNA3", "PLKO.1", "PLKO", "PCE2",
            "3XMYC", "3×MYC", "MYC", "3XFLAG", "3×FLAG", "FLAG", "6XHIS", "6×HIS", "HIS", "GST", "EGFP", "GFP",
            "NEO", "NEOR", "AMP", "AMPR", "KAN", "KANR", "PURO", "PUROR", "HYG",
            "HUMAN", "MOUSE", "RAT", "RECOMBINANT", "CONSTRUCT", "VECTOR", "PLASMID", "WT", "MUT", "A1B1"
        ]
        for rawTok in rawTokens {
            // 去除末尾中文供应商/测序后缀（如 "EGFP_Seq" -> "A1B1"、"Vector" -> ""）
            let asciiPart = rawTok.replacingOccurrences(of: #"[^A-Za-z0-9]"#, with: "", options: .regularExpression)
            guard asciiPart.count >= 3 && asciiPart.count <= 14 else { continue }
            let up = asciiPart.uppercased()
            if stopTokens.contains(up) || up.hasPrefix("PET") || up.hasPrefix("PCMV") || up.hasPrefix("PCDNA") {
                continue
            }
            // 基因名通常包含字母且全大写或字母+数字组合（如 TP53, BRCA1, MYC）
            if asciiPart.range(of: #"^[A-Za-z]{2,10}[0-9A-Za-z]{0,4}$"#, options: .regularExpression) != nil {
                appendGene(asciiPart)
            }
        }
        
        return genes
    }
    
    public static func extractPromoters(from info: SnapGeneFileInfo) -> [String] {
        var found: [String] = []
        let keywords = ["CMV", "T7", "U6", "EF-1", "EF1A", "SV40", "LAC", "TAC", "CAG", "PGK", "H1", "TRE"]
        for f in info.features {
            let upper = f.name.uppercased()
            let lowName = f.name.lowercased()
            if lowName.contains("ampr promoter") || lowName.contains("laci promoter") || lowName == "laci" || lowName.contains("poly(a)") || lowName.contains("ori") || lowName.contains("terminator") {
                continue
            }
            if f.type.uppercased().contains("PROMOTER") || keywords.contains(where: { upper.contains($0) }) {
                if !found.contains(f.name) {
                    found.append(f.name)
                }
            }
        }
        return found
    }
    
    public static func inferCategory(name: String, features: [SnapGeneFeature], promoters: [String]) -> String {
        let upper = name.uppercased()
        let featNames = features.map { $0.name.uppercased() }.joined(separator: " ")
        if upper.contains("LENTI") || upper.contains("PLKO") || upper.contains("CRISPR") || upper.contains("PX458") || upper.contains("PX459") || featNames.contains("CAS9") || featNames.contains("LTR") {
            return "慢病毒/CRISPR"
        }
        // 优先判断真核/哺乳动物表达（避免因哺乳动物载体同时含细菌 T7/lac 启动子而被误判为原核表达）
        if upper.contains("PCMV") || upper.contains("PCDNA") || upper.contains("PEGFP") || upper.contains("PMCHERRY") || upper.contains("PLVX") || upper.contains("PAAV") || featNames.contains("CMV PROMOTER") || featNames.contains("CMV ENHANCER") || featNames.contains("EF1A") {
            return "哺乳动物表达"
        }
        if upper.contains("PET") || upper.contains("PGEX") || upper.contains("PCOLD") || upper.contains("PBAD") || featNames.contains("T7 PROMOTER") || featNames.contains("LACI") {
            return "原核表达"
        }
        if upper.contains("RECOMBINANT") || upper.contains("CONSTRUCT") {
            return "重组产物"
        }
        return "通用质粒"
    }
}

/// MCP 跨进程同步历史归档记录（读取自 `mcp_sync/done/<run_id>.json`）
public struct MCPSyncRunRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String { runID }
    public let runID: String
    public let toolName: String
    public let actionSummary: String
    public let timestamp: Date
    
    public init(runID: String, toolName: String, actionSummary: String, timestamp: Date) {
        self.runID = runID
        self.toolName = toolName
        self.actionSummary = actionSummary
        self.timestamp = timestamp
    }
}

/// MCP 跨进程指令同步数据包（当外部 AI 通过 MCP 调用设计引物或计算用量时，实时同步至 GUI 对应模块画布与引物车）
public struct MCPExternalCommandSyncPayload: Codable, Sendable {
    public var schemaVersion: Int?
    public var runId: String?
    public var toolName: String?
    public var timestamp: Date
    public var actionSummary: String
    public var addedPrimers: [PrimerItem]
    public var generatedDNAFilePath: String?
    public var targetModuleRawValue: String?
    public var vectorFilePath: String?
    public var donorFilePath: String?
    public var insertSequence: String?
    public var insertName: String?
    public var cutStartBp: Int?
    public var cutEndBp: Int?
    public var multiFragmentSequences: [String]?
    public var mutUpSequence: String?
    public var mutSiteSequence: String?
    public var mutDownSequence: String?
    public var delStartBp: Int?
    public var delEndBp: Int?
    public var calculatorCloneTypeRaw: String?
    public var calculatorVectorName: String?
    public var calculatorVectorLengthKb: String?
    public var calculatorVectorConc: String?
    public var calculatorVectorCustomNg: String?
    public var calculatorInsertNames: [String]?
    public var calculatorInsertLengthsKb: [String]?
    public var calculatorInsertConcs: [String]?
    public var calculatorInsertCustomNgs: [String]?
    public var calculatorLigationPmol: String?
    public var calculatorLigationRatio: Int?
    
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runId = "run_id"
        case toolName = "tool_name"
        case timestamp
        case actionSummary
        case addedPrimers
        case generatedDNAFilePath
        case targetModuleRawValue
        case vectorFilePath
        case donorFilePath
        case insertSequence
        case insertName
        case cutStartBp
        case cutEndBp
        case multiFragmentSequences
        case mutUpSequence
        case mutSiteSequence
        case mutDownSequence
        case delStartBp
        case delEndBp
        case calculatorCloneTypeRaw
        case calculatorVectorName
        case calculatorVectorLengthKb
        case calculatorVectorConc
        case calculatorVectorCustomNg
        case calculatorInsertNames
        case calculatorInsertLengthsKb
        case calculatorInsertConcs
        case calculatorInsertCustomNgs
        case calculatorLigationPmol
        case calculatorLigationRatio
    }
}

/// 全局质粒池与 MCP 桥接服务管理器（支持按载体、基因、抗性三维智能筛选）
@MainActor
public final class PlasmidPoolManager: ObservableObject {
    public static let shared = PlasmidPoolManager()
    
    public static let categories = ["全部", "哺乳动物表达", "原核表达", "慢病毒/CRISPR", "重组产物", "通用质粒"]
    
    @Published public var items: [PlasmidPoolItem] = []
    @Published public var searchQuery: String = ""
    @Published public var selectedCategory: String = "全部"
    @Published public var selectedVectorFilter: String = "全部"
    @Published public var selectedGeneFilter: String = "全部"
    @Published public var selectedResistanceFilter: String = "全部"
    @Published public var selectedItemID: String? = nil
    @Published public var isScanning: Bool = false
    @Published public var lastMCPActivitySummary: String? = nil
    @Published public var recentMCPSyncRecords: [MCPSyncRunRecord] = []
    
    /// 当前质粒池中动态解析出的全部载体筛选项
    public var availableVectors: [String] {
        var list: [String] = ["全部"]
        for item in items {
            let v = item.resolvedVectorBackbone
            if !v.isEmpty && !list.contains(v) {
                list.append(v)
            }
        }
        return list
    }
    
    /// 当前质粒池中动态解析出的全部目的基因筛选项
    public var availableGenes: [String] {
        var list: [String] = ["全部"]
        for item in items {
            for g in item.resolvedTargetGenes {
                if !g.isEmpty && !list.contains(where: { $0.caseInsensitiveCompare(g) == .orderedSame }) {
                    list.append(g)
                }
            }
        }
        return list
    }
    
    /// 当前质粒池中动态解析出的全部抗性筛选项
    public var availableResistances: [String] {
        var list: [String] = ["全部"]
        for item in items {
            for r in item.resolvedResistances {
                if !r.isEmpty && !list.contains(r) {
                    list.append(r)
                }
            }
        }
        return list
    }
    
    public var hasActiveFilters: Bool {
        selectedVectorFilter != "全部" || selectedGeneFilter != "全部" || selectedResistanceFilter != "全部" || selectedCategory != "全部" || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    public func resetAllFilters() {
        selectedVectorFilter = "全部"
        selectedGeneFilter = "全部"
        selectedResistanceFilter = "全部"
        selectedCategory = "全部"
        searchQuery = ""
    }
    
    private var poolFileURLs: [URL] {
        var urls: [URL] = []
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("CloneStudio", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            urls.append(dir.appendingPathComponent("plasmid_pool.json"))
        }
        let projRoot = CloneStudioResourceLocator.projectRootDirectory
        urls.append(projRoot.appendingPathComponent(".clonestudio_plasmid_pool.json"))
        urls.append(projRoot.deletingLastPathComponent().appendingPathComponent(".clonestudio_plasmid_pool.json"))
        return urls
    }
    
    /// 唯一 MCP 同步事件队列目录：`~/Library/Application Support/CloneStudio/mcp_sync/`（可通过环境变量 `LABWORKER_MCP_SYNC_DIR` 覆盖）
    public func mcpSyncDirectoryURL(customDir: URL? = nil) -> URL {
        if let customDir { return customDir }
        if let envPath = ProcessInfo.processInfo.environment["LABWORKER_MCP_SYNC_DIR"], !envPath.isEmpty {
            return URL(fileURLWithPath: envPath, isDirectory: true)
        }
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("CloneStudio/mcp_sync", isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CloneStudio/mcp_sync", isDirectory: true)
    }
    
    private init() {
        registerMCPNotificationObserver()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            Task { @MainActor in
                _ = self.consumeMCPSyncDirectory(showToastOnSync: false)
            }
        }
        // 延迟 0.25s 后在后台线程异步加载质粒池并刷新标准化标签，彻底释放首屏主线程渲染带宽
        let urls = self.poolFileURLs
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Task.detached(priority: .utility) {
                let fm = FileManager.default
                var loadedItems: [PlasmidPoolItem] = []
                for url in urls {
                    if fm.fileExists(atPath: url.path),
                       let data = try? Data(contentsOf: url),
                       let decoded = try? JSONDecoder().decode([PlasmidPoolItem].self, from: data),
                       !decoded.isEmpty {
                        loadedItems = decoded.map { $0.refreshedMetadata() }
                        break
                    }
                }
                if !loadedItems.isEmpty {
                    let finalItems = loadedItems
                    await MainActor.run {
                        let mgr = PlasmidPoolManager.shared
                        if mgr.items.isEmpty {
                            mgr.items = finalItems
                            mgr.selectedItemID = finalItems.first?.id
                            mgr.savePoolToDisk()
                        }
                    }
                }
            }
        }
    }
    
    /// 按载体、基因、抗性、分类与关键词综合过滤后的质粒池条目
    public var filteredItems: [PlasmidPoolItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            if selectedCategory != "全部" && item.categoryTag != selectedCategory {
                return false
            }
            if selectedVectorFilter != "全部" && item.resolvedVectorBackbone.caseInsensitiveCompare(selectedVectorFilter) != .orderedSame {
                return false
            }
            if selectedGeneFilter != "全部" && !item.resolvedTargetGenes.contains(where: { $0.caseInsensitiveCompare(selectedGeneFilter) == .orderedSame }) {
                return false
            }
            if selectedResistanceFilter != "全部" && !item.resolvedResistances.contains(where: { $0.caseInsensitiveCompare(selectedResistanceFilter) == .orderedSame }) {
                return false
            }
            guard !q.isEmpty else { return true }
            if item.name.lowercased().contains(q) || item.aliasName.lowercased().contains(q) || item.notes.lowercased().contains(q) {
                return true
            }
            if item.resolvedVectorBackbone.lowercased().contains(q) {
                return true
            }
            if item.resolvedTargetGenes.contains(where: { $0.lowercased().contains(q) }) {
                return true
            }
            if item.resolvedResistances.contains(where: { $0.lowercased().contains(q) }) {
                return true
            }
            if item.dnaInfo.features.contains(where: { $0.name.lowercased().contains(q) || $0.type.lowercased().contains(q) }) {
                return true
            }
            if item.uniqueCutSites.contains(where: { $0.lowercased().contains(q) }) {
                return true
            }
            return false
        }
    }
    
    public var selectedItem: PlasmidPoolItem? {
        if let id = selectedItemID, let found = filteredItems.first(where: { $0.id == id }) {
            return found
        }
        return filteredItems.first
    }
    
    // MARK: - 持久化读写
    public func loadPoolFromDisk() {
        let fm = FileManager.default
        for url in poolFileURLs {
            if fm.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([PlasmidPoolItem].self, from: data),
               !decoded.isEmpty {
                let normalized = decoded.map { $0.refreshedMetadata() }
                self.items = normalized
                if self.selectedItemID == nil {
                    self.selectedItemID = normalized.first?.id
                }
                savePoolToDisk()
                return
            }
        }
    }
    
    public func savePoolToDisk() {
        let snapshotItems = self.items
        let urls = self.poolFileURLs
        DispatchQueue.global(qos: .utility).async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshotItems) else { return }
            for url in urls {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    
    /// 首次启动时自动扫描项目目录下的 .dna 质粒入库
    private func autoDiscoverProjectPlasmidsIfEmpty() async {
        let labDir = CloneStudioResourceLocator.projectRootDirectory
        let parentDir = labDir.deletingLastPathComponent()
        let projectDir = FileManager.default.fileExists(atPath: labDir.path) ? labDir : parentDir
        guard FileManager.default.fileExists(atPath: projectDir.path) else { return }
        await importFilesOrFolders(urls: [projectDir], silent: true, maxDepth: 1)
    }
    
    // MARK: - 批量导入 .dna / .fasta / .gb 或文件夹扫描（全后台解析与 441 酶切位点扫描，零主线程阻塞）
    public func importFilesOrFolders(urls: [URL], silent: Bool = false, maxDepth: Int = 4) async {
        isScanning = true
        defer { isScanning = false }
        
        let builtItems: [PlasmidPoolItem] = await Task.detached(priority: .utility) {
            var candidateFiles: [URL] = []
            let fm = FileManager.default
            let allowedExts: Set<String> = ["dna", "fa", "fasta", "gb", "gbk", "seq"]
            
            func collectFiles(in url: URL, depth: Int) {
                guard depth <= maxDepth else { return }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
                if isDir.boolValue {
                    let name = url.lastPathComponent
                    if name.hasPrefix(".") || name == "CloneStudio.app" || name.hasPrefix("CloneCanvasRef") || name.hasPrefix("SPICE_GUI") || name == "Sources" || name == "Tests" || name == "Scripts" || name == "labworker" {
                        return
                    }
                    if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for child in children {
                            collectFiles(in: child, depth: depth + 1)
                        }
                    }
                } else {
                    let ext = url.pathExtension.lowercased()
                    if allowedExts.contains(ext) {
                        candidateFiles.append(url)
                    }
                }
            }
            
            for u in urls {
                collectFiles(in: u, depth: 0)
            }
            
            var parsedList: [PlasmidPoolItem] = []
            for fileURL in candidateFiles {
                let ext = fileURL.pathExtension.lowercased()
                if ext == "dna" {
                    if let info = try? await SnapGeneService.shared.parseDNAFile(at: fileURL) {
                        let cleanName = fileURL.deletingPathExtension().lastPathComponent
                        // 在后台线程执行 PlasmidPoolItem 初始化（包含 441 个内切酶位点扫描）
                        let newItem = PlasmidPoolItem(
                            id: fileURL.path,
                            name: cleanName,
                            dnaInfo: info
                        )
                        parsedList.append(newItem)
                    }
                } else {
                    if let rawText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? (try? String(contentsOf: fileURL, encoding: .ascii)) {
                        let lines = rawText.components(separatedBy: .newlines)
                        let seqLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
                        let cleaned = BioSequence.clean(seqLines.joined())
                        if cleaned.count >= 50 {
                            let cleanName = fileURL.deletingPathExtension().lastPathComponent
                            let info = SnapGeneFileInfo(
                                filePath: fileURL.path,
                                fileName: fileURL.lastPathComponent,
                                sequence: cleaned,
                                length: cleaned.count,
                                isCircular: true,
                                featuresCount: 0,
                                features: [],
                                primersCount: 0,
                                primers: []
                            )
                            let newItem = PlasmidPoolItem(
                                id: fileURL.path,
                                name: cleanName,
                                dnaInfo: info
                            )
                            parsedList.append(newItem)
                        }
                    }
                }
            }
            return parsedList
        }.value
        
        guard !builtItems.isEmpty else {
            if !silent {
                AppState.shared.showToast("未在所选路径中发现有效 .dna 或序列文件")
            }
            return
        }
        
        for item in builtItems {
            upsertItem(item)
        }
        savePoolToDisk()
        if selectedItemID == nil {
            selectedItemID = items.first?.id
        }
        if !silent {
            AppState.shared.showToast("已成功解析并入库 \(builtItems.count) 个质粒到质粒池！")
        }
    }
    
    public func upsertItem(_ item: PlasmidPoolItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id || $0.name == item.name }) {
            var updated = item
            if updated.aliasName.isEmpty { updated.aliasName = items[idx].aliasName }
            if updated.notes.isEmpty { updated.notes = items[idx].notes }
            items[idx] = updated
        } else {
            items.insert(item, at: 0)
        }
    }
    
    public func removeItem(_ item: PlasmidPoolItem) {
        items.removeAll { $0.id == item.id }
        if selectedItemID == item.id {
            selectedItemID = items.first?.id
        }
        savePoolToDisk()
    }
    
    public func clearAll() {
        items.removeAll()
        selectedItemID = nil
        savePoolToDisk()
        AppState.shared.showToast("已清空质粒池")
    }
    
    // MARK: - 一键将质粒池中的质粒送入 5 大克隆构建模块
    public func sendToSingleCloneAsVector(_ item: PlasmidPoolItem) {
        let vm = WorkspaceSessionManager.shared.singleFragmentVM
        let url = URL(fileURLWithPath: item.dnaInfo.filePath)
        if FileManager.default.fileExists(atPath: url.path) && url.pathExtension.lowercased() == "dna" {
            Task {
                await vm.loadVectorDNA(url: url)
                AppState.shared.selectedNav = .singleFragment
            }
        } else {
            vm.vectorDNAInfo = item.dnaInfo
            vm.vectorSeq = item.dnaInfo.sequence
            AppState.shared.selectedNav = .singleFragment
            AppState.shared.showToast("已将「\(item.name)」设为单片段克隆载体")
        }
    }
    
    public func sendToSingleCloneAsDonor(_ item: PlasmidPoolItem) {
        let vm = WorkspaceSessionManager.shared.singleFragmentVM
        let url = URL(fileURLWithPath: item.dnaInfo.filePath)
        if FileManager.default.fileExists(atPath: url.path) && url.pathExtension.lowercased() == "dna" {
            Task {
                await vm.loadInsertSourceDNA(url: url)
                AppState.shared.selectedNav = .singleFragment
            }
        } else {
            vm.insertSourceDNAInfo = item.dnaInfo
            vm.insertSeq = item.dnaInfo.sequence
            vm.insertGeneName = item.name
            AppState.shared.selectedNav = .singleFragment
            AppState.shared.showToast("已将「\(item.name)」设为单片段克隆供体")
        }
    }
    
    public func sendToMultiCloneAsVector(_ item: PlasmidPoolItem) {
        let vm = WorkspaceSessionManager.shared.multiFragmentVM
        let url = URL(fileURLWithPath: item.dnaInfo.filePath)
        if FileManager.default.fileExists(atPath: url.path) && url.pathExtension.lowercased() == "dna" {
            Task {
                await vm.loadVectorDNA(url: url)
                AppState.shared.selectedNav = .multiFragment
            }
        } else {
            vm.vectorDNAInfo = item.dnaInfo
            vm.vectorSeq = item.dnaInfo.sequence
            AppState.shared.selectedNav = .multiFragment
            AppState.shared.showToast("已将「\(item.name)」设为多片段克隆载体")
        }
    }
    
    public func sendToMutagenesis(_ item: PlasmidPoolItem) {
        let vm = WorkspaceSessionManager.shared.mutagenesisVM
        let url = URL(fileURLWithPath: item.dnaInfo.filePath)
        if FileManager.default.fileExists(atPath: url.path) && url.pathExtension.lowercased() == "dna" {
            Task {
                await vm.loadDNAFile(url: url)
                AppState.shared.selectedNav = .mutagenesis
            }
        } else {
            vm.plasmidDNAInfo = item.dnaInfo
            AppState.shared.selectedNav = .mutagenesis
            AppState.shared.showToast("已将「\(item.name)」载入定点突变")
        }
    }
    
    public func sendToFragmentDeletion(_ item: PlasmidPoolItem) {
        let vm = WorkspaceSessionManager.shared.fragmentDeletionVM
        let url = URL(fileURLWithPath: item.dnaInfo.filePath)
        if FileManager.default.fileExists(atPath: url.path) && url.pathExtension.lowercased() == "dna" {
            Task {
                await vm.loadDNAFile(url: url)
                AppState.shared.selectedNav = .fragmentDeletion
            }
        } else {
            vm.plasmidDNAInfo = item.dnaInfo
            vm.plasmidSeq = item.dnaInfo.sequence
            vm.selectedDNAFileName = item.name
            AppState.shared.selectedNav = .fragmentDeletion
            AppState.shared.showToast("已将「\(item.name)」载入片段删除")
        }
    }
    
    // MARK: - MCP Server 20261120 配置与跨进程实时联动
    public var mcpServerScriptPath: String {
        CloneStudioResourceLocator.path(forResource: "clonestudio_mcp_server", ofType: "py")
            ?? CloneStudioResourceLocator.projectRootDirectory.appendingPathComponent("Sources/CloneStudioCore/Resources/clonestudio_mcp_server.py").path
    }
    
    /// Labworker MCP Server 20261120 支持的 23 大全栈实验工具清单（供设置面板展示与检索）
    public struct MCPToolDescriptor: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let category: String
        public let summary: String
    }
    
    public static let mcpToolsCatalog: [MCPToolDescriptor] = [
        MCPToolDescriptor(name: "list_plasmid_pool", category: "分子克隆与质粒", summary: "按载体骨架、目的基因、抗性与分类多维检索本地质粒池"),
        MCPToolDescriptor(name: "inspect_plasmid", category: "分子克隆与质粒", summary: "深度解析指定质粒的全部特征坐标、唯一酶切位点与完整序列"),
        MCPToolDescriptor(name: "add_plasmid_to_pool", category: "分子克隆与质粒", summary: "将本地 .dna 质粒文件导入 Labworker 质粒池并提取抗性/基因标签"),
        MCPToolDescriptor(name: "design_single_clone_primers", category: "分子克隆与质粒", summary: "单片段无缝克隆引物设计、3n 阅读框校验与重组 .dna 自动生成"),
        MCPToolDescriptor(name: "design_multi_fragment_primers", category: "分子克隆与质粒", summary: "2–10 片段 Gibson/同源重组拼接引物设计并同步至多片段画布"),
        MCPToolDescriptor(name: "design_mutagenesis_primers", category: "分子克隆与质粒", summary: "氨基酸定点突变 (如 S42A/K15R) 引物设计与野生型位点核对"),
        MCPToolDescriptor(name: "design_fragment_deletion_primers", category: "分子克隆与质粒", summary: "质粒结构域敲除/片段删除反向 PCR 桥接引物设计"),
        MCPToolDescriptor(name: "verify_sanger_sequencing", category: "分子克隆与质粒", summary: "解析 Sanger 测序 (.ab1/.seq) 四色峰图并与参考质粒比对，自动检出 SNP、Indel 与杂合双峰"),
        MCPToolDescriptor(name: "calculate_recombination_dosage", category: "定量与体系计算", summary: "计算 20 μL 同源重组体系或经典 0.03 pmol 摩尔比 (1:1–1:5) 中载体与插入片段最佳 ng 与移液体积"),
        MCPToolDescriptor(name: "convert_nucleic_acid_units", category: "定量与体系计算", summary: "dsDNA (μg⇄pmol)、ssDNA (μg/mL⇄pmol/μL)、Linear DNA 末端摩尔及 OD260 核酸定量互算"),
        MCPToolDescriptor(name: "convert_protein_and_coding", category: "定量与体系计算", summary: "蛋白质大小/质量/摩尔数 (kDa⇄μg⇄pmol) 三角互算及 DNA 编码容量 (bp⇄aa⇄kDa) 联动推算"),
        MCPToolDescriptor(name: "calculate_solution_and_temperature", category: "定量与体系计算", summary: "摩尔浓度溶液溶质质量配制、C1V1=C2V2 稀释体积及 °F/°C/K 温标换算"),
        MCPToolDescriptor(name: "design_sgrna_primers", category: "基因编辑与靶点", summary: "CRISPR/Cas9 NGG 靶点扫描评分与 lentiCRISPRv2/pX459 退火引物生成"),
        MCPToolDescriptor(name: "design_shrna_primers", category: "基因编辑与靶点", summary: "21nt RNAi 靶点热力学筛选与 pLKO.1 (AgeI/EcoRI) 发夹引物设计"),
        MCPToolDescriptor(name: "manage_primer_cart_and_export", category: "合成订购与导出", summary: "查看引物订购池并一键导出擎科引物合成 Excel 订购表"),
        MCPToolDescriptor(name: "analyze_protein_and_docking_box", category: "蛋白质与分子对接", summary: "计算蛋白 pI/GRAVY、LIGSITE P-S-P 口袋、共晶配体共识 Vina 对接盒与点突变 ΔΔG"),
        MCPToolDescriptor(name: "analyze_western_blot", category: "电泳与图像定量", summary: "Western Blot 目的条带与内参 IOD 归一化、均值/SD 汇总与双组检验"),
        MCPToolDescriptor(name: "analyze_qpcr_ddct", category: "定量与体系计算", summary: "qPCR 2^(-ΔΔCt) 相对表达量计算与复孔高 SD 异常质控告警"),
        MCPToolDescriptor(name: "design_plate_layout", category: "定量与体系计算", summary: "96/384 孔微孔板防边缘效应自动排布与生物学重复孔位分配"),
        MCPToolDescriptor(name: "deconvolute_crispr_sanger", category: "基因编辑与靶点", summary: "CRISPR 编辑池 Sanger 四色峰图 NNLS 解卷积定量（Indel%、KO Score、HDR% 与 R²）"),
        MCPToolDescriptor(name: "auto_annotate_sequence", category: "分子克隆与质粒", summary: "基于 Libraries.sqlite 的本地离线质粒 FASTA 自动注释，支持跨零点匹配与残留片段标注"),
        MCPToolDescriptor(name: "design_golden_gate_assembly", category: "分子克隆与质粒", summary: "Type IIS (BsaI/BsmBI/BbsI/SapI) 2–6 片段零错配接头分配与编码区同义 Domestication"),
        MCPToolDescriptor(name: "design_hdr_donor", category: "基因编辑与靶点", summary: "CRISPR Knock-in HDR 同源供体 (ssODN/dsDNA)、PAM/Seed 同义阻断突变、可选 RFLP 与 Out-Out PCR 引物设计")
    ]
    
    /// 生成标准 MCP 客户端 JSON 配置 (兼容 Claude Desktop / Cursor / Windsurf / Cline / Gemini)
    public var mcpConfigJSONString: String {
        let scriptPath = mcpServerScriptPath
        return """
        {
          "mcpServers": {
            "labworker": {
              "command": "/usr/bin/python3",
              "args": [
                "\(scriptPath)"
              ]
            }
          }
        }
        """
    }
    
    public func copyMCPConfigToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mcpConfigJSONString, forType: .string)
        AppState.shared.showToast("已复制 Labworker MCP 20261120 配置 JSON 到剪贴板！")
    }
    
    /// 一键将 Labworker MCP Server 20261120 注入 Claude Desktop、Cursor 与 Windsurf 的配置文件中
    public func installMCPToLocalAIClients() {
        let scriptPath = mcpServerScriptPath
        let fm = FileManager.default
        let targets: [(name: String, path: String)] = [
            ("Claude Desktop", (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")),
            ("Cursor", (NSHomeDirectory() as NSString).appendingPathComponent(".cursor/mcp.json")),
            ("Windsurf", (NSHomeDirectory() as NSString).appendingPathComponent(".codeium/windsurf/mcp_config.json"))
        ]
        
        var installedNames: [String] = []
        for (clientName, path) in targets {
            let url = URL(fileURLWithPath: path)
            let dir = url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            
            var rootDict: [String: Any] = [:]
            if fm.fileExists(atPath: path),
               let data = try? Data(contentsOf: url),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                rootDict = existing
            }
            
            var servers = (rootDict["mcpServers"] as? [String: Any]) ?? [:]
            servers.removeValue(forKey: "clonestudio")
            servers["labworker"] = [
                "command": "/usr/bin/python3",
                "args": [scriptPath]
            ]
            rootDict["mcpServers"] = servers
            
            if let outData = try? JSONSerialization.data(withJSONObject: rootDict, options: [.prettyPrinted, .sortedKeys]) {
                try? outData.write(to: url, options: .atomic)
                installedNames.append(clientName)
            }
        }
        
        if !installedNames.isEmpty {
            AppState.shared.showToast("已自动注入 Labworker MCP 20261120 至：\(installedNames.joined(separator: "、"))")
        } else {
            copyMCPConfigToClipboard()
        }
    }
    
    private func registerMCPNotificationObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.clonestudio.mcp.updated"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleExternalMCPUpdate()
            }
        }
    }
    
    /// 响应外部 AI 工具通过 MCP 执行引物设计、用量计算或质粒池更新后的全模块画布实时同步
    public func handleExternalMCPUpdate() {
        loadPoolFromDisk()
        _ = consumeMCPSyncDirectory(showToastOnSync: true)
    }
    
    /// 按时间顺序扫描并幂等消费 `mcp_sync/` 下的 `<run_id>.json` 事件文件，归档至 `done/` 并清理 >7 天的历史文件 (P04)
    @discardableResult
    public func consumeMCPSyncDirectory(at customSyncDir: URL? = nil, showToastOnSync: Bool = true) -> Int {
        let fm = FileManager.default
        let syncDir = mcpSyncDirectoryURL(customDir: customSyncDir)
        let doneDir = syncDir.appendingPathComponent("done", isDirectory: true)
        let processedURL = syncDir.appendingPathComponent("processed_runs.json")
        try? fm.createDirectory(at: doneDir, withIntermediateDirectories: true)
        
        // 读取已处理的 run_id 列表（保留最近 500 条防重）
        var processedList: [String] = []
        if let pData = try? Data(contentsOf: processedURL),
           let decoded = try? JSONDecoder().decode([String].self, from: pData) {
            processedList = decoded
        }
        var processedSet = Set(processedList)
        
        guard let entries = try? fm.contentsOfDirectory(at: syncDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            refreshMCPSyncHistory(from: syncDir)
            return 0
        }
        
        let reservedNames: Set<String> = ["latest.json", "processed_runs.json", "done"]
        var pendingEvents: [(url: URL, runID: String, payload: MCPExternalCommandSyncPayload)] = []
        for url in entries {
            let name = url.lastPathComponent
            if reservedNames.contains(name) || url.pathExtension.lowercased() != "json" {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(MCPExternalCommandSyncPayload.self, from: data) else {
                continue
            }
            let fallbackID = url.deletingPathExtension().lastPathComponent
            let runID = (payload.runId?.isEmpty == false) ? payload.runId! : fallbackID
            pendingEvents.append((url: url, runID: runID, payload: payload))
        }
        
        pendingEvents.sort { $0.payload.timestamp < $1.payload.timestamp }
        var consumedCount = 0
        for event in pendingEvents {
            let destDoneURL = doneDir.appendingPathComponent("\(event.runID).json")
            if processedSet.contains(event.runID) {
                try? fm.removeItem(at: destDoneURL)
                try? fm.moveItem(at: event.url, to: destDoneURL)
                continue
            }
            
            applyMCPPayloadToWorkspace(event.payload, showToast: showToastOnSync)
            processedSet.insert(event.runID)
            processedList.append(event.runID)
            if processedList.count > 500 {
                processedList = Array(processedList.suffix(500))
            }
            try? fm.removeItem(at: destDoneURL)
            if (try? fm.moveItem(at: event.url, to: destDoneURL)) == nil {
                try? fm.removeItem(at: event.url)
            }
            consumedCount += 1
        }
        
        if consumedCount > 0 {
            if let encoded = try? JSONEncoder().encode(processedList) {
                try? encoded.write(to: processedURL, options: .atomic)
            }
        }
        
        // 自动清理 done/ 目录中超过 7 天的归档事件
        if let doneFiles = try? fm.contentsOfDirectory(at: doneDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            let cutoff = Date().addingTimeInterval(-7.0 * 86400.0)
            for f in doneFiles where f.pathExtension.lowercased() == "json" {
                if let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey]),
                   let modDate = vals.contentModificationDate,
                   modDate < cutoff {
                    try? fm.removeItem(at: f)
                }
            }
        }
        
        refreshMCPSyncHistory(from: syncDir)
        return consumedCount
    }
    
    public func refreshMCPSyncHistory(from customSyncDir: URL? = nil) {
        let fm = FileManager.default
        let syncDir = mcpSyncDirectoryURL(customDir: customSyncDir)
        let doneDir = syncDir.appendingPathComponent("done", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: doneDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return
        }
        var records: [MCPSyncRunRecord] = []
        for f in files where f.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: f),
                  let payload = try? JSONDecoder().decode(MCPExternalCommandSyncPayload.self, from: data) else {
                continue
            }
            let rid = payload.runId ?? f.deletingPathExtension().lastPathComponent
            let tName = payload.toolName ?? (payload.targetModuleRawValue ?? "mcp_tool")
            records.append(
                MCPSyncRunRecord(
                    runID: rid,
                    toolName: tName,
                    actionSummary: payload.actionSummary,
                    timestamp: payload.timestamp
                )
            )
        }
        records.sort { $0.timestamp > $1.timestamp }
        self.recentMCPSyncRecords = Array(records.prefix(30))
        if let latest = records.first {
            self.lastMCPActivitySummary = latest.actionSummary
        }
    }
    
    private func applyMCPPayloadToWorkspace(_ payload: MCPExternalCommandSyncPayload, showToast: Bool) {
        if !payload.addedPrimers.isEmpty {
            let existingSeqs = Set(AppState.shared.primersCart.map { "\($0.name)_\($0.fullSequence)" })
            let newPrimers = payload.addedPrimers.filter { !existingSeqs.contains("\($0.name)_\($0.fullSequence)") }
            if !newPrimers.isEmpty {
                AppState.shared.primersCart.append(contentsOf: newPrimers)
            }
        }
        
        let session = WorkspaceSessionManager.shared
        switch payload.targetModuleRawValue {
        case "singleFragment":
            let vm = session.singleFragmentVM
            if let vPath = payload.vectorFilePath, let matched = items.first(where: { $0.dnaInfo.filePath == vPath }) {
                vm.vectorDNAInfo = matched.dnaInfo
                vm.vectorSeq = matched.dnaInfo.sequence
            }
            if let dPath = payload.donorFilePath, let matchedDonor = items.first(where: { $0.dnaInfo.filePath == dPath }) {
                vm.insertSourceDNAInfo = matchedDonor.dnaInfo
            }
            if let cs = payload.cutStartBp, let ce = payload.cutEndBp {
                vm.applyVectorTargetRange(start: cs, end: ce)
            }
            if let insSeq = payload.insertSequence, !insSeq.isEmpty {
                vm.insertSeq = insSeq
            }
            if let insName = payload.insertName, !insName.isEmpty {
                vm.insertGeneName = insName
            }
            if !payload.addedPrimers.isEmpty {
                vm.primers = payload.addedPrimers
            }
            AppState.shared.selectedNav = .singleFragment
            
        case "multiFragment":
            let vm = session.multiFragmentVM
            if let vPath = payload.vectorFilePath, let matched = items.first(where: { $0.dnaInfo.filePath == vPath }) {
                vm.vectorDNAInfo = matched.dnaInfo
                vm.vectorSeq = matched.dnaInfo.sequence
            }
            if let cs = payload.cutStartBp, let ce = payload.cutEndBp {
                vm.cutStartText = "\(cs)"
                vm.cutEndText = "\(ce)"
            }
            if let frags = payload.multiFragmentSequences, frags.count >= 2 {
                vm.fragments = frags
            }
            if !payload.addedPrimers.isEmpty {
                vm.primers = payload.addedPrimers
            }
            AppState.shared.selectedNav = .multiFragment
            
        case "mutagenesis":
            let vm = session.mutagenesisVM
            if let vPath = payload.vectorFilePath, let matched = items.first(where: { $0.dnaInfo.filePath == vPath }) {
                vm.plasmidDNAInfo = matched.dnaInfo
            }
            if let up = payload.mutUpSequence { vm.mutUp = up }
            if let site = payload.mutSiteSequence { vm.mutSite = site }
            if let down = payload.mutDownSequence { vm.mutDown = down }
            if !payload.addedPrimers.isEmpty {
                vm.primers = payload.addedPrimers
            }
            AppState.shared.selectedNav = .mutagenesis
            
        case "fragmentDeletion":
            let vm = session.fragmentDeletionVM
            if let vPath = payload.vectorFilePath, let matched = items.first(where: { $0.dnaInfo.filePath == vPath }) {
                vm.plasmidDNAInfo = matched.dnaInfo
                vm.plasmidSeq = matched.dnaInfo.sequence
                vm.selectedDNAFileName = matched.name
            }
            if let ds = payload.delStartBp { vm.delStartText = "\(ds)" }
            if let de = payload.delEndBp { vm.delEndText = "\(de)" }
            if !payload.addedPrimers.isEmpty {
                vm.primers = payload.addedPrimers
            }
            AppState.shared.selectedNav = .fragmentDeletion
            
        case "dnaCalculator":
            let vm = session.calculatorVM
            if let rawType = payload.calculatorCloneTypeRaw,
               let ct = DNAMolarCalculator.CloneType(rawValue: rawType) {
                vm.cloneType = ct
            }
            if let vn = payload.calculatorVectorName { vm.vectorName = vn }
            if let vLen = payload.calculatorVectorLengthKb { vm.vectorLengthKb = vLen }
            if let vConc = payload.calculatorVectorConc { vm.vectorConcentration = vConc }
            if let vNg = payload.calculatorVectorCustomNg { vm.vectorCustomNg = vNg }
            if let iNames = payload.calculatorInsertNames { vm.insertNames = iNames }
            if let iLens = payload.calculatorInsertLengthsKb { vm.insertLengths = iLens }
            if let iConcs = payload.calculatorInsertConcs { vm.insertConcs = iConcs }
            if let iNgs = payload.calculatorInsertCustomNgs { vm.insertCustomNgs = iNgs }
            if let ligPmol = payload.calculatorLigationPmol { vm.ligationVectorPmol = ligPmol }
            if let ligRatio = payload.calculatorLigationRatio,
               let ratioEnum = DNAMolarCalculator.LigationMolarRatio(rawValue: ligRatio) {
                vm.ligationMolarRatio = ratioEnum
            }
            session.bioCalculatorVM.selectedCategory = .cloningAndLigation
            AppState.shared.selectedNav = .dnaCalculator
            
        case "sgRNADesign":
            if !payload.addedPrimers.isEmpty {
                session.sgRNAVM.generatedPrimers = payload.addedPrimers
            }
            AppState.shared.selectedNav = .sgRNADesign
            
        case "shRNADesign":
            if !payload.addedPrimers.isEmpty {
                session.shRNAVM.generatedPrimers = payload.addedPrimers
            }
            AppState.shared.selectedNav = .shRNADesign
            
        case "sangerVerify":
            AppState.shared.selectedNav = .sangerVerify
            
        default:
            break
        }
        
        self.lastMCPActivitySummary = payload.actionSummary
        if showToast {
            AppState.shared.showToast("🤖 MCP AI 指令已同步：\(payload.actionSummary)")
        }
    }
}
