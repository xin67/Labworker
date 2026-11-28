import Foundation

/// NEB 双酶切缓冲液活性兼容矩阵模型
public struct NEBBufferCompatibility: Sendable, Equatable {
    public let r1_1: Int
    public let r2_1: Int
    public let r3_1: Int
    public let cutSmart: Int
    public let preferredBuffer: String
    public let heatInactivation: Bool
    public let incubationTempC: Int
    public let methylationSensitivity: [String]
    public let starActivityNote: String?
    public let isCuratedNEBEntry: Bool
    
    public init(
        r1_1: Int,
        r2_1: Int,
        r3_1: Int,
        cutSmart: Int,
        preferredBuffer: String = "CutSmart",
        heatInactivation: Bool = true,
        incubationTempC: Int = 37,
        methylationSensitivity: [String] = [],
        starActivityNote: String? = nil,
        isCuratedNEBEntry: Bool = true
    ) {
        self.r1_1 = r1_1
        self.r2_1 = r2_1
        self.r3_1 = r3_1
        self.cutSmart = cutSmart
        self.preferredBuffer = preferredBuffer
        self.heatInactivation = heatInactivation
        self.incubationTempC = incubationTempC
        self.methylationSensitivity = methylationSensitivity
        self.starActivityNote = starActivityNote
        self.isCuratedNEBEntry = isCuratedNEBEntry
    }
}

/// 质粒全序列真实酶切位点扫描结果 (1:1 OVE Cutsite 几何结构)
public struct ConstructCutsite: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let recognitionSite: String
    /// 1-based 识别起点坐标
    public let position1Based: Int
    /// 0-based 识别序列起始偏移
    public let recognitionStart0Based: Int
    /// 0-based 识别序列终止偏移 (inclusive)
    public let recognitionEnd0Based: Int
    /// 0-based 正义链 (5'->3') 裂解切口偏移（位于第 topSnip0Based 个碱基之前）
    public let topSnip0Based: Int
    /// 0-based 互补链 (3'->5') 裂解切口偏移（位于第 bottomSnip0Based 个碱基之前）
    public let bottomSnip0Based: Int
    /// 黏性末端悬垂序列
    public let overhangBps: String
    /// 该酶在当前质粒中的总切点数
    public var cutCountInPlasmid: Int
    public let isType2S: Bool
    public let colorHex: String
    
    public var isUniqueCutter: Bool {
        cutCountInPlasmid == 1
    }
    
    public init(
        id: UUID = UUID(),
        name: String,
        recognitionSite: String,
        position1Based: Int,
        recognitionStart0Based: Int,
        recognitionEnd0Based: Int,
        topSnip0Based: Int,
        bottomSnip0Based: Int,
        overhangBps: String = "",
        cutCountInPlasmid: Int = 1,
        isType2S: Bool = false,
        colorHex: String = "#38bdf8"
    ) {
        self.id = id
        self.name = name
        self.recognitionSite = recognitionSite
        self.position1Based = position1Based
        self.recognitionStart0Based = recognitionStart0Based
        self.recognitionEnd0Based = recognitionEnd0Based
        self.topSnip0Based = topSnip0Based
        self.bottomSnip0Based = bottomSnip0Based
        self.overhangBps = overhangBps
        self.cutCountInPlasmid = cutCountInPlasmid
        self.isType2S = isType2S
        self.colorHex = colorHex
    }
}

/// Type IIS 内切酶外切规范 (识别序列 + 识别区下游裂解偏移 + 粘性末端长度)
public struct TypeIISEnzymeSpec: Sendable, Equatable, Codable {
    public let name: String
    public let recognitionSite: String
    public let reverseComplementSite: String
    /// 识别序列 3' 端下游正链裂解偏移 (bp)
    public let downstreamCutTop: Int
    /// 识别序列 3' 端下游互补链裂解偏移 (bp)
    public let downstreamCutBottom: Int
    /// 产生的粘性末端长度 (bp)
    public let overhangLength: Int
    /// 引物 5' 端默认保护碱基
    public let defaultProtective5Prime: String

    public init(
        name: String,
        recognitionSite: String,
        reverseComplementSite: String,
        downstreamCutTop: Int,
        downstreamCutBottom: Int,
        overhangLength: Int,
        defaultProtective5Prime: String = "GCAATC"
    ) {
        self.name = name
        self.recognitionSite = recognitionSite
        self.reverseComplementSite = reverseComplementSite
        self.downstreamCutTop = downstreamCutTop
        self.downstreamCutBottom = downstreamCutBottom
        self.overhangLength = overhangLength
        self.defaultProtective5Prime = defaultProtective5Prime
    }
}

/// 限制性内切酶双链精确扫描结果（含非回文 Type IIS 正/反链外切坐标与跨零点标记）
public struct DualStrandCutSite: Sendable, Equatable, Codable {
    public let enzymeName: String
    public let recognitionSite: String
    public let strand: String
    public let recognitionStart0Based: Int
    public let recognitionEnd0Based: Int
    public let topSnip0Based: Int
    public let bottomSnip0Based: Int
    public let overhangBps: String
    public let isOriginSpanning: Bool

    public init(
        enzymeName: String,
        recognitionSite: String,
        strand: String,
        recognitionStart0Based: Int,
        recognitionEnd0Based: Int,
        topSnip0Based: Int,
        bottomSnip0Based: Int,
        overhangBps: String,
        isOriginSpanning: Bool
    ) {
        self.enzymeName = enzymeName
        self.recognitionSite = recognitionSite
        self.strand = strand
        self.recognitionStart0Based = recognitionStart0Based
        self.recognitionEnd0Based = recognitionEnd0Based
        self.topSnip0Based = topSnip0Based
        self.bottomSnip0Based = bottomSnip0Based
        self.overhangBps = overhangBps
        self.isOriginSpanning = isOriginSpanning
    }
}

/// 预设限制性内切酶组
public struct EnzymePresetGroup: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let displayTitle: String
    public let enzymeNames: [String]
    public let isDynamicUnique: Bool
    
    public init(name: String, displayTitle: String, enzymeNames: [String], isDynamicUnique: Bool = false) {
        self.name = name
        self.displayTitle = displayTitle
        self.enzymeNames = enzymeNames
        self.isDynamicUnique = isDynamicUnique
    }
}

/// 限制性核酸内切酶模型
public struct RestrictionEnzyme: Identifiable, Hashable, Codable, Sendable {
    public var id: String { name }
    public let name: String
    public let site: String
    
    public init(name: String, site: String) {
        self.name = name
        self.site = site.uppercased()
    }
    
    private enum CodingKeys: String, CodingKey {
        case name = "value"
        case site = "key"
    }
    
    /// 上下链精确裂解切口偏移 (topSnipOffset, bottomSnipOffset)，相对于识别序列 0-based 起点
    public var snipOffsets: (top: Int, bottom: Int) {
        if let known = Self.knownSnipTable[name.lowercased()] {
            return known
        }
        let len = site.count
        if len == 6 {
            // 默认 6bp 回文酶按典型 5' 悬垂 (1, 5) 解算
            return (1, 5)
        } else if len == 4 {
            // 默认 4bp 酶按中间平切 (2, 2) 解算
            return (2, 2)
        } else if len == 8 {
            return (2, 6)
        }
        return (len / 2, len / 2)
    }
    
    public var topSnipOffset: Int { snipOffsets.top }
    public var bottomSnipOffset: Int { snipOffsets.bottom }
    
    /// 是否为 Type IIS (识别区外切割) 内切酶
    public var isType2S: Bool {
        let s = snipOffsets
        return s.top > site.count || s.bottom > site.count || s.top < 0 || s.bottom < 0
    }

    /// 粘性末端长度 (bp)
    public var overhangLength: Int {
        let s = snipOffsets
        return abs(s.bottom - s.top)
    }

    /// 识别序列的反向互补序列
    public var reverseComplementSite: String {
        BioSequence.reverseComplement(site)
    }

    /// 识别序列是否回文对称
    public var isPalindromic: Bool {
        isPureLiteralSite && site == reverseComplementSite
    }

    /// 若为 Type IIS 外切酶，返回其识别序列 3' 下游正链外切偏移 (bp)
    public var downstreamCutTopOffset: Int? {
        guard isType2S else { return nil }
        return snipOffsets.top - site.count
    }

    /// 若为 Type IIS 外切酶，返回其识别序列 3' 下游互补链外切偏移 (bp)
    public var downstreamCutBottomOffset: Int? {
        guard isType2S else { return nil }
        return snipOffsets.bottom - site.count
    }

    /// Type IIS 常用组装酶规范表 (BsaI / BsmBI / BbsI / SapI；采用 NEB 推荐 6-bp 5' 端保护碱基)
    public static let typeIISCatalog: [String: TypeIISEnzymeSpec] = [
        "bsai": TypeIISEnzymeSpec(
            name: "BsaI",
            recognitionSite: "GGTCTC",
            reverseComplementSite: "GAGACC",
            downstreamCutTop: 1,
            downstreamCutBottom: 5,
            overhangLength: 4,
            defaultProtective5Prime: "GCAATC"
        ),
        "bsmbi": TypeIISEnzymeSpec(
            name: "BsmBI",
            recognitionSite: "CGTCTC",
            reverseComplementSite: "GAGACG",
            downstreamCutTop: 1,
            downstreamCutBottom: 5,
            overhangLength: 4,
            defaultProtective5Prime: "GCAATC"
        ),
        "bbsi": TypeIISEnzymeSpec(
            name: "BbsI",
            recognitionSite: "GAAGAC",
            reverseComplementSite: "GTCTTC",
            downstreamCutTop: 2,
            downstreamCutBottom: 6,
            overhangLength: 4,
            defaultProtective5Prime: "GCAATC"
        ),
        "sapi": TypeIISEnzymeSpec(
            name: "SapI",
            recognitionSite: "GCTCTTC",
            reverseComplementSite: "GAAGAGC",
            downstreamCutTop: 1,
            downstreamCutBottom: 4,
            overhangLength: 3,
            defaultProtective5Prime: "GCAATC"
        )
    ]

    /// 获取对应的 Type IIS 标准外切规格
    public var typeIISSpec: TypeIISEnzymeSpec? {
        Self.typeIISCatalog[name.lowercased()]
    }
    
    /// 推荐视觉配色 Hex (还原 CloneCanvas 酶切色彩层级)
    public var colorHex: String {
        if isType2S { return "#fbbf24" } // 琥珀金 Type IIS (BsaI, BbsI, FokI)
        let s = snipOffsets
        if s.top == s.bottom { return "#f87171" } // 珊瑚红 平末端 (StuI, HaeIII, EcoRV, PvuII)
        switch name.lowercased() {
        case "ecori", "bamhi", "hindiii", "xhoi", "noti":
            return "#4ade80" // 翠绿 核心克隆酶
        case "psti", "saci", "sali", "kpni", "spei":
            return "#fb923c" // 亮橙 高频多克隆位点酶
        case "ndei", "ncoi", "agei", "nhci", "nhei", "xbai", "bglii":
            return "#c084fc" // 紫罗兰 表达载体起止酶
        default:
            return "#38bdf8" // 天青蓝
        }
    }
    
    /// 常见内切酶精确裂解切口坐标表 (Ported from TeselaGen / REBASE)
    private static let knownSnipTable: [String: (top: Int, bottom: Int)] = [
        // 5' 黏性末端 (top < bottom)
        "ecori": (1, 5),     // G^AATT_C
        "bamhi": (1, 5),     // G^GATC_C
        "hindiii": (1, 5),   // A^AGCT_T
        "xhoi": (1, 5),      // C^TCGA_G
        "sali": (1, 5),      // G^TCGA_C
        "ndei": (2, 4),      // CA^TA_TG
        "noti": (2, 6),      // GC^GGCC_GC
        "nhei": (1, 5),      // G^CTAG_C
        "spei": (1, 5),      // A^CTAG_T
        "bglii": (1, 5),     // A^GATC_T
        "xbai": (1, 5),      // T^CTAG_A
        "agei": (1, 5),      // A^CCGG_T
        "clai": (2, 4),      // AT^CG_AT
        "ncoi": (1, 5),      // C^CATG_G
        "mlui": (1, 5),      // A^CGCG_T
        "aflii": (1, 5),     // C^TTAA_G
        "avrii": (1, 5),     // C^CTAG_G
        "xmai": (1, 5),      // C^CCGG_G
        "bsiwi": (1, 5),     // C^GTAC_G
        "bsshii": (1, 5),    // G^CGCG_C
        "eagi": (1, 5),      // C^GGCC_G
        "asci": (2, 6),      // GG^CGCG_CC
        "bcli": (1, 5),      // T^GATC_A
        "mfeI": (1, 5),      // C^AATT_G
        "mfei": (1, 5),
        // 3' 黏性末端 (top > bottom)
        "kpni": (5, 1),      // G_GTAC^C
        "psti": (5, 1),      // C_TGCA^G
        "saci": (5, 1),      // G_AGCT^C
        "sacii": (4, 2),     // CC_GC^GG
        "sphi": (5, 1),      // G_CATG^C
        "apai": (5, 1),      // G_GGCC^C
        "nsii": (5, 1),      // A_TGCA^T
        "pvui": (4, 2),      // CG_AT^CG
        "sbffi": (6, 2),     // CC_TGCA^GG
        "sbfi": (6, 2),
        "fsei": (6, 2),      // GG_CCGG^CC
        "paci": (5, 3),      // TTA_AT^TAA
        // 平末端 Blunt (top == bottom)
        "ecorv": (3, 3),     // GAT^ATC
        "smai": (3, 3),      // CCC^GGG
        "stui": (3, 3),      // AGG^CCT
        "haeiii": (2, 2),    // GG^CC
        "drai": (3, 3),      // TTT^AAA
        "pvuii": (3, 3),     // CAG^CTG
        "scai": (3, 3),      // AGT^ACT
        "hpai": (3, 3),      // GTT^AAC
        "hincii": (3, 3),    // GTY^RAC
        "sspi": (3, 3),      // AAT^ATT
        "alui": (2, 2),      // AG^CT
        "dpni": (2, 2),      // GA^TC
        "pmei": (4, 4),      // GTTT^AAAC
        "swai": (4, 4),      // ATTT^AAAT
        "naei": (3, 3),      // GCC^GGC
        "fsphi": (3, 3),     // TGC^GCA
        // Type IIS (识别位点外裂解)
        "bsai": (7, 11),     // GGTCTC(1/5)
        "bbsi": (8, 12),     // GAAGAC(2/6)
        "bsmbi": (7, 11),    // CGTCTC(1/5)
        "sapi": (8, 11),     // GCTCTTC(1/4)
        "bspqi": (8, 11),    // GCTCTTC(1/4)
        "aari": (11, 15),    // CACCTGC(4/8)
        "foki": (14, 18)     // GGATG(9/13)
    ]
    
    /// 将包含 IUPAC 简并碱基的酶切位点转换为正则表达式模式
    public var regexPattern: String {
        var pattern = ""
        for char in site {
            switch char {
            case "A", "T", "C", "G": pattern.append(char)
            case "R": pattern.append("[AG]")
            case "Y": pattern.append("[CT]")
            case "M": pattern.append("[AC]")
            case "K": pattern.append("[GT]")
            case "S": pattern.append("[GC]")
            case "W": pattern.append("[AT]")
            case "H": pattern.append("[ACT]")
            case "B": pattern.append("[CGT]")
            case "V": pattern.append("[ACG]")
            case "D": pattern.append("[AGT]")
            case "N": pattern.append("[ACGT]")
            default:  pattern.append(char)
            }
        }
        return pattern
    }
    
    /// 预编译正则表达式缓存，避免每次扫描重复编译 NSRegularExpression
    private static let regexCacheLock = NSLock()
    nonisolated(unsafe) private static var compiledRegexCache: [String: NSRegularExpression] = [:]
    
    private var compiledRegex: NSRegularExpression? {
        let pat = regexPattern
        Self.regexCacheLock.lock()
        defer { Self.regexCacheLock.unlock() }
        if let cached = Self.compiledRegexCache[pat] {
            return cached
        }
        if let created = try? NSRegularExpression(pattern: pat, options: []) {
            Self.compiledRegexCache[pat] = created
            return created
        }
        return nil
    }
    
    /// 是否仅包含标准 A/T/C/G 碱基（可使用高速字面量搜索代替正则）
    public var isPureLiteralSite: Bool {
        for ch in site {
            if ch != "A" && ch != "T" && ch != "C" && ch != "G" {
                return false
            }
        }
        return !site.isEmpty
    }
    
    /// 检查指定 DNA 序列中是否包含该酶切位点
    public func isIn(sequence: String) -> Bool {
        let cleanSeq = BioSequence.clean(sequence)
        if isPureLiteralSite {
            return cleanSeq.range(of: site) != nil
        }
        guard let regex = compiledRegex else { return false }
        let range = NSRange(location: 0, length: cleanSeq.utf16.count)
        return regex.firstMatch(in: cleanSeq, options: [], range: range) != nil
    }
    
    /// 查找在指定已清洗序列中的所有位点索引 (0-based)
    public func findSitesInCleaned(_ cleanSeq: String) -> [Int] {
        guard !cleanSeq.isEmpty, site.count <= cleanSeq.count else { return [] }
        if isPureLiteralSite {
            var results: [Int] = []
            var searchStart = cleanSeq.startIndex
            while let range = cleanSeq.range(of: site, options: .literal, range: searchStart..<cleanSeq.endIndex) {
                let offset = cleanSeq.distance(from: cleanSeq.startIndex, to: range.lowerBound)
                results.append(offset)
                searchStart = cleanSeq.index(after: range.lowerBound)
            }
            return results
        }
        guard let regex = compiledRegex else { return [] }
        let range = NSRange(location: 0, length: cleanSeq.utf16.count)
        return regex.matches(in: cleanSeq, options: [], range: range).map { $0.range.location }
    }
    
    /// 查找在指定序列中的所有位点索引 (0-based)
    public func findSites(in sequence: String) -> [Int] {
        findSitesInCleaned(BioSequence.clean(sequence))
    }

    /// 双链精确扫描切点（支持非回文 Type IIS 正/反链外切偏移坐标及环形质粒跨零点匹配）
    public func findDualStrandSites(in sequence: String, circular: Bool = true) -> [DualStrandCutSite] {
        let cleanSeq = BioSequence.clean(sequence)
        let seqLen = cleanSeq.count
        let siteLen = site.count
        guard seqLen > 0, siteLen > 0, siteLen <= seqLen else { return [] }

        let chars = Array(cleanSeq)
        let searchSeq = circular ? (cleanSeq + cleanSeq) : cleanSeq
        let snips = snipOffsets
        var results: [DualStrandCutSite] = []

        func extractOverhang(rawStart: Int, rawEnd: Int) -> String {
            let len = rawEnd - rawStart
            guard len > 0, len <= 12 else { return "" }
            var out = ""
            out.reserveCapacity(len)
            for pos in rawStart..<rawEnd {
                if circular {
                    let wrapped = ((pos % seqLen) + seqLen) % seqLen
                    out.append(chars[wrapped])
                } else if pos >= 0 && pos < seqLen {
                    out.append(chars[pos])
                }
            }
            return out
        }

        // 正向链扫描
        let fwdPattern = RestrictionEnzyme(name: name, site: site)
        for recStart0 in fwdPattern.findSitesInCleaned(searchSeq) {
            if circular && recStart0 >= seqLen { continue }
            let rawTop = recStart0 + snips.top
            let rawBot = recStart0 + snips.bottom
            if !circular && (rawTop < 0 || rawBot < 0 || rawTop > seqLen || rawBot > seqLen) {
                continue
            }
            let topSnip = circular ? ((rawTop % seqLen) + seqLen) % seqLen : rawTop
            let botSnip = circular ? ((rawBot % seqLen) + seqLen) % seqLen : rawBot
            let ovh = extractOverhang(rawStart: min(rawTop, rawBot), rawEnd: max(rawTop, rawBot))
            let recEnd0 = (recStart0 + siteLen - 1) % seqLen
            let spans = circular && (recStart0 + siteLen > seqLen || max(rawTop, rawBot) > seqLen || min(rawTop, rawBot) < 0)
            results.append(
                DualStrandCutSite(
                    enzymeName: name,
                    recognitionSite: site,
                    strand: "+",
                    recognitionStart0Based: recStart0,
                    recognitionEnd0Based: recEnd0,
                    topSnip0Based: topSnip,
                    bottomSnip0Based: botSnip,
                    overhangBps: ovh,
                    isOriginSpanning: spans
                )
            )
        }

        // 若非回文序列，追加反向互补链扫描
        if !isPalindromic {
            let rcSite = reverseComplementSite
            let revPattern = RestrictionEnzyme(name: name, site: rcSite)
            for recStart0 in revPattern.findSitesInCleaned(searchSeq) {
                if circular && recStart0 >= seqLen { continue }
                let rawTop = recStart0 + siteLen - snips.bottom
                let rawBot = recStart0 + siteLen - snips.top
                if !circular && (rawTop < 0 || rawBot < 0 || rawTop > seqLen || rawBot > seqLen) {
                    continue
                }
                let topSnip = circular ? ((rawTop % seqLen) + seqLen) % seqLen : rawTop
                let botSnip = circular ? ((rawBot % seqLen) + seqLen) % seqLen : rawBot
                let ovh = extractOverhang(rawStart: min(rawTop, rawBot), rawEnd: max(rawTop, rawBot))
                let recEnd0 = (recStart0 + siteLen - 1) % seqLen
                let spans = circular && (recStart0 + siteLen > seqLen || max(rawTop, rawBot) > seqLen || min(rawTop, rawBot) < 0)
                results.append(
                    DualStrandCutSite(
                        enzymeName: name,
                        recognitionSite: rcSite,
                        strand: "-",
                        recognitionStart0Based: recStart0,
                        recognitionEnd0Based: recEnd0,
                        topSnip0Based: topSnip,
                        bottomSnip0Based: botSnip,
                        overhangBps: ovh,
                        isOriginSpanning: spans
                    )
                )
            }
        }

        return results.sorted {
            if $0.recognitionStart0Based != $1.recognitionStart0Based {
                return $0.recognitionStart0Based < $1.recognitionStart0Based
            }
            return $0.strand < $1.strand
        }
    }
}

/// 限制性内切酶数据库管理类
public final class RestrictionEnzymeDatabase: @unchecked Sendable {
    public static let shared = RestrictionEnzymeDatabase()
    
    public private(set) var enzymes: [RestrictionEnzyme] = []
    
    /// 预设酶切组合列表 (对齐 CloneCanvas EnzymeSelector)
    public static let presetGroups: [EnzymePresetGroup] = [
        EnzymePresetGroup(
            name: "NEB Standard",
            displayTitle: "SET: NEB STANDARD",
            enzymeNames: [
                "EcoRI", "BamHI", "HindIII", "SacI", "SalI", "KpnI", "PstI", "NotI", "XbaI",
                "XhoI", "NdeI", "NcoI", "BglII", "SpeI", "AgeI", "StuI", "HaeIII", "DraI",
                "PvuII", "ScaI", "HincII", "BsaI", "BbsI", "FokI", "AarI", "NheI", "SacII"
            ]
        ),
        EnzymePresetGroup(
            name: "Unique Cutters",
            displayTitle: L10n.t("SET: UNIQUE CUTTERS (单酶切)"),
            enzymeNames: commonEnzymeNames,
            isDynamicUnique: true
        ),
        EnzymePresetGroup(
            name: "Standard Lab Cloning",
            displayTitle: L10n.t("SET: LAB CLONING (18 常用酶)"),
            enzymeNames: commonEnzymeNames
        ),
        EnzymePresetGroup(
            name: "Golden Gate (Type IIS)",
            displayTitle: "SET: GOLDEN GATE (Type IIS)",
            enzymeNames: ["BsaI", "BbsI", "BsmBI", "SapI", "BspQI", "AarI", "FokI"]
        ),
        EnzymePresetGroup(
            name: "Blunt End Cutters",
            displayTitle: L10n.t("SET: BLUNT END (平末端)"),
            enzymeNames: ["EcoRV", "SmaI", "HpaI", "DraI", "PvuII", "ScaI", "StuI", "NaeI", "HaeIII", "HincII"]
        ),
        EnzymePresetGroup(
            name: "Rare Cutters (8bp+)",
            displayTitle: "SET: RARE CUTTERS (8bp+)",
            enzymeNames: ["NotI", "AscI", "FseI", "PacI", "PmeI", "SbfI", "SfiI", "SwaI"]
        ),
        EnzymePresetGroup(
            name: "BioBrick Standard",
            displayTitle: "SET: BIOBRICK STANDARD",
            enzymeNames: ["EcoRI", "XbaI", "SpeI", "PstI"]
        )
    ]
    
    public init() {
        loadEnzymes()
    }
    
    private func loadEnzymes() {
        var loaded: [RestrictionEnzyme] = []
        if let url = CloneStudioResourceLocator.url(forResource: "select", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([RestrictionEnzyme].self, from: data) {
            loaded = list
        }
        
        if loaded.isEmpty {
            loaded = Self.fallbackEnzymes
        } else {
            // 确保所有预设高频酶（如 HaeIII, StuI, FokI, BsaI, BbsI, AarI）一定在库中可查
            let existingNames = Set(loaded.map { $0.name.lowercased() })
            for fb in Self.fallbackEnzymes where !existingNames.contains(fb.name.lowercased()) {
                loaded.append(fb)
            }
        }
        self.enzymes = loaded
    }
    
    /// 常用核心克隆酶列表
    public static let commonEnzymeNames: [String] = [
        "BamHI", "EcoRI", "HindIII", "XhoI", "NdeI", "NotI", "SalI", "KpnI", "PstI",
        "SacI", "NheI", "ClaI", "SpeI", "BglII", "XbaI", "EcoRV", "SmaI", "AgeI"
    ]
    
    public var commonEnzymes: [RestrictionEnzyme] {
        enzymes.filter { Self.commonEnzymeNames.contains($0.name) }
    }
    
    public func find(name: String) -> RestrictionEnzyme? {
        enzymes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    
    public func filter(query: String) -> [RestrictionEnzyme] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return enzymes
        }
        let q = query.lowercased()
        return enzymes.filter { $0.name.lowercased().contains(q) || $0.site.lowercased().contains(q) }
    }
    
    /// 查询指定内切酶的 NEB Buffer 活性兼容数据
    /// 典型 Dam / Dcm / CpG 甲基化阻断映射表（依据 NEB 官方 Methylation Sensitivity 规范）
    public static let methylationSensitivityTable: [String: [String]] = [
        "clai": ["Dam", "CpG"], "xbai": ["Dam"], "bcli": ["Dam"], "mboi": ["Dam"], "dpnii": ["Dam"],
        "hphi": ["Dam"], "taqi": ["Dam"], "nrui": ["Dam", "CpG"],
        "stui": ["Dcm"], "apai": ["Dcm", "CpG"], "ecorii": ["Dcm"], "sexai": ["Dcm"], "styi": ["Dcm"], "bsai": ["Dcm", "CpG"],
        "noti": ["CpG"], "hpaii": ["CpG"], "smai": ["CpG"], "sali": ["CpG"], "xhoi": ["CpG"],
        "agei": ["CpG"], "sacii": ["CpG"], "eagi": ["CpG"], "pvui": ["CpG"], "bsmbi": ["CpG"]
    ]

    /// 非 37°C 最适反应温度表（如 SmaI/ApaI 25°C、BclI/SfiI 50°C、BstEII 60°C、TaqI 65°C）
    public static let non37IncubationTempTable: [String: Int] = [
        "smai": 25, "apai": 25, "bcli": 50, "sfii": 50, "bsteii": 60, "taqi": 65, "bsmbi": 55, "bsli": 55
    ]

    /// 常见星号活性 (Star Activity) 条件提示表
    public static let starActivityTable: [String: String] = [
        "ecori": "甘油 >5% 或低盐高 pH 易诱发星号活性",
        "bamhi": "甘油 >5% 或过量酶/过长时间易诱发星号活性（推荐使用 BamHI-HF）",
        "hindiii": "甘油 >5% 或高酶量/低离子强度易诱发星号活性",
        "sali": "甘油 >5% 或低盐条件易诱发星号活性",
        "scai": "甘油 >5% 或过长孵育易诱发星号活性（推荐使用 ScaI-HF）",
        "psti": "甘油 >5% 或高 pH 易诱发星号活性",
        "pvuii": "甘油 >5% 或高酶量易诱发星号活性",
        "xbai": "高甘油或超时孵育易诱发星号活性"
    ]

    public func bufferCompatibility(for enzymeName: String) -> NEBBufferCompatibility {
        let low = enzymeName.lowercased()
        let meth = Self.methylationSensitivityTable[low] ?? []
        let temp = Self.non37IncubationTempTable[low] ?? 37
        let star = Self.starActivityTable[low].map { L10n.t($0) }
        if let hit = Self.nebBufferTable[low] {
            return NEBBufferCompatibility(
                r1_1: hit.r1_1, r2_1: hit.r2_1, r3_1: hit.r3_1, cutSmart: hit.cutSmart,
                preferredBuffer: hit.preferredBuffer, heatInactivation: hit.heatInactivation,
                incubationTempC: temp, methylationSensitivity: meth, starActivityNote: star, isCuratedNEBEntry: true
            )
        }
        // 未收录至精选 NEB 缓冲液表的酶不再盲目假设 CutSmart 100%，标记 isCuratedNEBEntry = false
        return NEBBufferCompatibility(
            r1_1: 50, r2_1: 50, r3_1: 50, cutSmart: 50,
            preferredBuffer: "Verify NEB",
            heatInactivation: true,
            incubationTempC: temp,
            methylationSensitivity: meth,
            starActivityNote: star,
            isCuratedNEBEntry: false
        )
    }

    /// 检测给定切点在 Dam (GATC) / Dcm (CCWGG) / CpG (CG) 甲基化宿主中是否发生识别位点重叠阻断
    public func checkMethylationBlock(
        enzymeName: String,
        sequence: String,
        siteStart0Based: Int,
        siteLength: Int,
        circular: Bool = true,
        damMethylated: Bool = true,
        dcmMethylated: Bool = true,
        cpgMethylated: Bool = false
    ) -> [String] {
        let sens = Self.methylationSensitivityTable[enzymeName.lowercased()] ?? []
        guard !sens.isEmpty else { return [] }
        let clean = BioSequence.clean(sequence)
        let n = clean.count
        guard n > 0 else { return [] }
        let pad = 4
        let chars = Array(clean)
        var window = ""
        var actualLeftPad = 0
        for off in -pad..<(siteLength + pad) {
            let idx = siteStart0Based + off
            if circular {
                let w = ((idx % n) + n) % n
                window.append(chars[w])
                if off < 0 { actualLeftPad += 1 }
            } else if idx >= 0 && idx < n {
                window.append(chars[idx])
                if off < 0 { actualLeftPad += 1 }
            }
        }
        // 严格依据实际左侧填充量定位识别位点 [siteLo, siteHi)，并仅当甲基化碱基本身落入识别位点内时才判定阻断
        let siteLo = actualLeftPad
        let siteHi = actualLeftPad + siteLength
        let wChars = Array(window)
        func methylatedBaseInsideSite(_ motif: String, methylatedOffsets: [Int]) -> Bool {
            let mArr = Array(motif)
            guard wChars.count >= mArr.count else { return false }
            for i in 0...(wChars.count - mArr.count) {
                var ok = true
                for k in 0..<mArr.count where wChars[i + k] != mArr[k] { ok = false; break }
                if ok {
                    if methylatedOffsets.contains(where: { (i + $0) >= siteLo && (i + $0) < siteHi }) {
                        return true
                    }
                }
            }
            return false
        }
        var blockedBy: [String] = []
        if damMethylated && sens.contains("Dam") && methylatedBaseInsideSite("GATC", methylatedOffsets: [1, 2]) {
            blockedBy.append("Dam (GATC)")
        }
        if dcmMethylated && sens.contains("Dcm") && (methylatedBaseInsideSite("CCAGG", methylatedOffsets: [1, 3]) || methylatedBaseInsideSite("CCTGG", methylatedOffsets: [1, 3])) {
            blockedBy.append("Dcm (CCWGG)")
        }
        if cpgMethylated && sens.contains("CpG") && methylatedBaseInsideSite("CG", methylatedOffsets: [0, 1]) {
            blockedBy.append("CpG (CG)")
        }
        return blockedBy
    }
    
    private let scanCacheLock = NSLock()
    private var constructScanCache: [String: [ConstructCutsite]] = [:]
    
    /// 对完整质粒或线性序列进行高速全酶切扫描（带内存缓存与字面量加速），返回带精确上下链裂解切口的 ConstructCutsite 数组
    public func scanConstructCutsites(
        sequence: String,
        circular: Bool = true,
        enzymeNames: [String],
        uniqueOnly: Bool = false
    ) -> [ConstructCutsite] {
        let cleanSeq = BioSequence.clean(sequence)
        let seqLen = cleanSeq.count
        guard seqLen >= 10 else { return [] }
        
        let cacheKey = "\(cleanSeq.hashValue)_\(seqLen)_\(circular)_\(uniqueOnly)_\(enzymeNames.joined(separator: ","))"
        scanCacheLock.lock()
        if let hit = constructScanCache[cacheKey] {
            scanCacheLock.unlock()
            return hit
        }
        scanCacheLock.unlock()
        
        let targetEnzymes: [RestrictionEnzyme] = {
            if uniqueOnly {
                let poolNames = Self.presetGroups[0].enzymeNames + Self.commonEnzymeNames
                var seen = Set<String>()
                var list: [RestrictionEnzyme] = []
                for n in poolNames {
                    let low = n.lowercased()
                    if !seen.contains(low), let e = find(name: n) {
                        seen.insert(low)
                        list.append(e)
                    }
                }
                return list
            } else {
                return enzymeNames.compactMap { find(name: $0) }
            }
        }()
        
        let chars = Array(cleanSeq)
        var rawSites: [ConstructCutsite] = []
        
        for enz in targetEnzymes {
            let siteLen = enz.site.count
            guard siteLen > 0 && siteLen <= seqLen else { continue }
            let hits = enz.findSitesInCleaned(cleanSeq)
            guard !hits.isEmpty else { continue }
            if uniqueOnly && hits.count != 1 { continue }
            
            let snips = enz.snipOffsets
            for matchIdx in hits {
                let recStart = matchIdx
                let recEnd = min(seqLen - 1, matchIdx + siteLen - 1)
                let topSnip = (recStart + snips.top + seqLen) % seqLen
                let botSnip = (recStart + snips.bottom + seqLen) % seqLen
                
                let minS = min(topSnip, botSnip)
                let maxS = max(topSnip, botSnip)
                var ovh = ""
                if maxS > minS && maxS <= seqLen && (maxS - minS) <= 8 {
                    ovh = String(chars[minS..<maxS])
                }
                
                rawSites.append(
                    ConstructCutsite(
                        name: enz.name,
                        recognitionSite: enz.site,
                        position1Based: recStart + 1,
                        recognitionStart0Based: recStart,
                        recognitionEnd0Based: recEnd,
                        topSnip0Based: topSnip,
                        bottomSnip0Based: botSnip,
                        overhangBps: ovh,
                        cutCountInPlasmid: hits.count,
                        isType2S: enz.isType2S,
                        colorHex: enz.colorHex
                    )
                )
            }
        }
        
        let sorted = rawSites.sorted { $0.position1Based < $1.position1Based }
        scanCacheLock.lock()
        if constructScanCache.count > 48 {
            constructScanCache.removeAll()
        }
        constructScanCache[cacheKey] = sorted
        scanCacheLock.unlock()
        return sorted
    }
    
    private static let nebBufferTable: [String: NEBBufferCompatibility] = [
        "ecori": NEBBufferCompatibility(r1_1: 25, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "bamhi": NEBBufferCompatibility(r1_1: 75, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: false),
        "hindiii": NEBBufferCompatibility(r1_1: 50, r2_1: 100, r3_1: 50, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "sali": NEBBufferCompatibility(r1_1: 10, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "r3.1", heatInactivation: true),
        "xhoi": NEBBufferCompatibility(r1_1: 75, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "ndei": NEBBufferCompatibility(r1_1: 75, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "saci": NEBBufferCompatibility(r1_1: 10, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "kpni": NEBBufferCompatibility(r1_1: 25, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: false),
        "bsai": NEBBufferCompatibility(r1_1: 50, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "bbsi": NEBBufferCompatibility(r1_1: 10, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "bsmbi": NEBBufferCompatibility(r1_1: 50, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "r3.1", heatInactivation: true),
        "sapi": NEBBufferCompatibility(r1_1: 50, r2_1: 75, r3_1: 10, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "bspqi": NEBBufferCompatibility(r1_1: 50, r2_1: 50, r3_1: 100, cutSmart: 100, preferredBuffer: "r3.1", heatInactivation: true),
        "noti": NEBBufferCompatibility(r1_1: 10, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "xbai": NEBBufferCompatibility(r1_1: 25, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "psti": NEBBufferCompatibility(r1_1: 75, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "r3.1", heatInactivation: true),
        "smai": NEBBufferCompatibility(r1_1: 50, r2_1: 25, r3_1: 10, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "spei": NEBBufferCompatibility(r1_1: 100, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "clai": NEBBufferCompatibility(r1_1: 100, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "bglii": NEBBufferCompatibility(r1_1: 10, r2_1: 100, r3_1: 100, cutSmart: 10, preferredBuffer: "r3.1", heatInactivation: false),
        "ecorv": NEBBufferCompatibility(r1_1: 50, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "ncoi": NEBBufferCompatibility(r1_1: 50, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "scai": NEBBufferCompatibility(r1_1: 50, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "aari": NEBBufferCompatibility(r1_1: 10, r2_1: 50, r3_1: 100, cutSmart: 100, preferredBuffer: "r3.1", heatInactivation: true),
        "pvuii": NEBBufferCompatibility(r1_1: 50, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: false),
        "dpni": NEBBufferCompatibility(r1_1: 100, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "haeiii": NEBBufferCompatibility(r1_1: 100, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "stui": NEBBufferCompatibility(r1_1: 50, r2_1: 100, r3_1: 50, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "drai": NEBBufferCompatibility(r1_1: 75, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "foki": NEBBufferCompatibility(r1_1: 100, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "hincii": NEBBufferCompatibility(r1_1: 100, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "sacii": NEBBufferCompatibility(r1_1: 10, r2_1: 100, r3_1: 10, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "nhei": NEBBufferCompatibility(r1_1: 100, r2_1: 100, r3_1: 100, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true),
        "agei": NEBBufferCompatibility(r1_1: 100, r2_1: 75, r3_1: 25, cutSmart: 100, preferredBuffer: "CutSmart", heatInactivation: true)
    ]
    
    private static let fallbackEnzymes: [RestrictionEnzyme] = [
        RestrictionEnzyme(name: "BamHI", site: "GGATCC"),
        RestrictionEnzyme(name: "EcoRI", site: "GAATTC"),
        RestrictionEnzyme(name: "HindIII", site: "AAGCTT"),
        RestrictionEnzyme(name: "XhoI", site: "CTCGAG"),
        RestrictionEnzyme(name: "NdeI", site: "CATATG"),
        RestrictionEnzyme(name: "NotI", site: "GCGGCCGC"),
        RestrictionEnzyme(name: "SalI", site: "GTCGAC"),
        RestrictionEnzyme(name: "KpnI", site: "GGTACC"),
        RestrictionEnzyme(name: "PstI", site: "CTGCAG"),
        RestrictionEnzyme(name: "SacI", site: "GAGCTC"),
        RestrictionEnzyme(name: "SacII", site: "CCGCGG"),
        RestrictionEnzyme(name: "NheI", site: "GCTAGC"),
        RestrictionEnzyme(name: "ClaI", site: "ATCGAT"),
        RestrictionEnzyme(name: "SpeI", site: "ACTAGT"),
        RestrictionEnzyme(name: "BglII", site: "AGATCT"),
        RestrictionEnzyme(name: "XbaI", site: "TCTAGA"),
        RestrictionEnzyme(name: "EcoRV", site: "GATATC"),
        RestrictionEnzyme(name: "SmaI", site: "CCCGGG"),
        RestrictionEnzyme(name: "AgeI", site: "ACCGGT"),
        RestrictionEnzyme(name: "StuI", site: "AGGCCT"),
        RestrictionEnzyme(name: "HaeIII", site: "GGCC"),
        RestrictionEnzyme(name: "DraI", site: "TTTAAA"),
        RestrictionEnzyme(name: "PvuII", site: "CAGCTG"),
        RestrictionEnzyme(name: "ScaI", site: "AGTACT"),
        RestrictionEnzyme(name: "HincII", site: "GTYRAC"),
        RestrictionEnzyme(name: "NcoI", site: "CCATGG"),
        RestrictionEnzyme(name: "BsaI", site: "GGTCTC"),
        RestrictionEnzyme(name: "BbsI", site: "GAAGAC"),
        RestrictionEnzyme(name: "BsmBI", site: "CGTCTC"),
        RestrictionEnzyme(name: "SapI", site: "GCTCTTC"),
        RestrictionEnzyme(name: "BspQI", site: "GCTCTTC"),
        RestrictionEnzyme(name: "AarI", site: "CACCTGC"),
        RestrictionEnzyme(name: "FokI", site: "GGATG"),
        RestrictionEnzyme(name: "HpaI", site: "GTTAAC"),
        RestrictionEnzyme(name: "NaeI", site: "GCCGGC"),
        RestrictionEnzyme(name: "AscI", site: "GGCGCGCC"),
        RestrictionEnzyme(name: "FseI", site: "GGCCGGCC"),
        RestrictionEnzyme(name: "PacI", site: "TTAATTAA"),
        RestrictionEnzyme(name: "PmeI", site: "GTTTAAAC"),
        RestrictionEnzyme(name: "SbfI", site: "CCTGCAGG"),
        RestrictionEnzyme(name: "SwaI", site: "ATTTAAAT")
    ]
}
