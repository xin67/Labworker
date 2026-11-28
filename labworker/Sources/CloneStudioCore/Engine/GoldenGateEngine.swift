import Foundation
import SQLite3

/// Type IIS Golden Gate 组装引擎 (BsaI-HFv2 / BsmBI-v2 / BbsI-HF / SapI)
/// 基于 Libraries.sqlite 中 Pryor et al. (PLoS ONE 2020, DOI: 10.1371/journal.pone.0238592) 真实 PacBio SMRT
/// 实测连接保真度矩阵（含 4-bp 256×256 与 SapI 3-bp 64×64 非对称方向计数），实现：
/// 1) 全局优化（贪心初值 + 1-Swap 坐标上升 + 确定性模拟退火 NEB DAD）无交叉/自错配高保真接头分配
/// 2) 片段内部内源 Type IIS 位点扫描与宿主特异同义密码子抹除（支持单/多碱基与双密码子兜底）
/// 3) 片段拼接跨界处（Junction-spanning）新生 Type IIS 识别位点检测
public struct GoldenGateEngine: Sendable {

    // MARK: - 1. 数据模型

    /// 同义突变去酶切位点（Domestication）时的目标宿主密码子偏好
    public enum HostOrganism: String, Sendable, Equatable, Codable, CaseIterable {
        case eColi = "ecoli"
        case human = "human"
        case yeast = "yeast"
    }

    /// 单个 4-bp / 3-bp 黏性末端在实测连接矩阵中的基础指标
    public struct OverhangStatsRecord: Sendable, Equatable, Codable {
        public let overhang: String
        public let rcOverhang: String
        public let isPalindromic: Bool
        public let gcCount: Int
        public let wcLigationCount: Int
        public let selfLigationCount: Int
        public let individualFidelity: Double
        public let isNEBVerifiedHF: Bool

        public init(
            overhang: String,
            rcOverhang: String,
            isPalindromic: Bool,
            gcCount: Int,
            wcLigationCount: Int,
            selfLigationCount: Int = 0,
            individualFidelity: Double,
            isNEBVerifiedHF: Bool
        ) {
            self.overhang = overhang
            self.rcOverhang = rcOverhang
            self.isPalindromic = isPalindromic
            self.gcCount = gcCount
            self.wcLigationCount = wcLigationCount
            self.selfLigationCount = selfLigationCount
            self.individualFidelity = individualFidelity
            self.isNEBVerifiedHF = isNEBVerifiedHF
        }
    }

    /// 内存化 NEB Type IIS / T4 DNA Ligase 实测保真度稀疏矩阵（保留方向非对称性 M(a,b) vs M(rc(a),rc(b))）
    public struct NEBLigaseFidelityMatrix: Sendable, Equatable {
        public let enzymeKey: String
        public let overhangLength: Int
        public let sourceCitation: String
        public let sourceDOI: String
        public let statsByOverhang: [String: OverhangStatsRecord]
        public let ligationCounts: [String: [String: Int]]

        public init(
            enzymeKey: String = "bsai",
            overhangLength: Int = 4,
            sourceCitation: String = "",
            sourceDOI: String = "",
            statsByOverhang: [String: OverhangStatsRecord] = [:],
            ligationCounts: [String: [String: Int]] = [:]
        ) {
            self.enzymeKey = enzymeKey
            self.overhangLength = overhangLength
            self.sourceCitation = sourceCitation
            self.sourceDOI = sourceDOI
            self.statsByOverhang = statsByOverhang
            self.ligationCounts = ligationCounts
        }

        public func ligationCount(_ overhangA: String, _ overhangB: String) -> Int {
            ligationCounts[overhangA]?[overhangB] ?? 0
        }

        public static func canonicalEnzymeKey(_ enzymeName: String) -> String {
            let lower = enzymeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.hasPrefix("bsmbi") || lower.hasPrefix("esp3i") { return "bsmbi" }
            if lower.hasPrefix("bbsi") || lower.hasPrefix("bpii") { return "bbsi" }
            if lower.hasPrefix("sapi") || lower.hasPrefix("bspqi") { return "sapi" }
            return "bsai"
        }

        /// 从 Libraries.sqlite 只读加载指定酶的实测 PacBio 连接保真度矩阵（默认 BsaI-HFv2）
        public static func loadFromSQLite(dbPath: String? = nil, enzymeName: String = "BsaI") -> NEBLigaseFidelityMatrix {
            guard let resolved = dbPath ?? CloneStudioResourceLocator.path(forResource: "Libraries", ofType: "sqlite") else {
                return NEBLigaseFidelityMatrix()
            }
            var db: OpaquePointer? = nil
            guard sqlite3_open_v2(resolved, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let openedDB = db else {
                if let db = db { sqlite3_close(db) }
                return NEBLigaseFidelityMatrix()
            }
            defer { sqlite3_close(openedDB) }

            let ekey = canonicalEnzymeKey(enzymeName)
            var ovLen = (ekey == "sapi") ? 3 : 4
            var citation = ""
            var doi = ""

            var stmtMeta: OpaquePointer? = nil
            let sqlMeta = """
                SELECT overhang_length, source_citation, source_doi
                FROM neb_ligase_fidelity_metadata WHERE enzyme_key = ?;
                """
            if sqlite3_prepare_v2(openedDB, sqlMeta, -1, &stmtMeta, nil) == SQLITE_OK, let m = stmtMeta {
                defer { sqlite3_finalize(m) }
                sqlite3_bind_text(m, 1, (ekey as NSString).utf8String, -1, nil)
                if sqlite3_step(m) == SQLITE_ROW {
                    ovLen = Int(sqlite3_column_int(m, 0))
                    if let cC = sqlite3_column_text(m, 1) { citation = String(cString: cC) }
                    if let dC = sqlite3_column_text(m, 2) { doi = String(cString: dC) }
                }
            }

            var stats: [String: OverhangStatsRecord] = [:]
            var counts: [String: [String: Int]] = [:]

            // 优先读取按酶分表的多酶实测矩阵 (Pryor et al. 2020)
            var stmtStats: OpaquePointer? = nil
            let sqlStats = """
                SELECT overhang, rc_overhang, is_palindromic, gc_count, wc_ligation_count, self_ligation_count, individual_fidelity, is_neb_verified_hf
                FROM neb_overhang_stats_by_enzyme WHERE enzyme_key = ?;
                """
            if sqlite3_prepare_v2(openedDB, sqlStats, -1, &stmtStats, nil) == SQLITE_OK, let s = stmtStats {
                defer { sqlite3_finalize(s) }
                sqlite3_bind_text(s, 1, (ekey as NSString).utf8String, -1, nil)
                while sqlite3_step(s) == SQLITE_ROW {
                    guard let ovC = sqlite3_column_text(s, 0),
                          let rcC = sqlite3_column_text(s, 1) else { continue }
                    let ov = String(cString: ovC)
                    let rc = String(cString: rcC)
                    let isPal = sqlite3_column_int(s, 2) != 0
                    let gcCnt = Int(sqlite3_column_int(s, 3))
                    let wcCnt = Int(sqlite3_column_int(s, 4))
                    let selfCnt = Int(sqlite3_column_int(s, 5))
                    let fid = sqlite3_column_double(s, 6)
                    let isHF = sqlite3_column_int(s, 7) != 0
                    stats[ov] = OverhangStatsRecord(
                        overhang: ov,
                        rcOverhang: rc,
                        isPalindromic: isPal,
                        gcCount: gcCnt,
                        wcLigationCount: wcCnt,
                        selfLigationCount: selfCnt,
                        individualFidelity: fid,
                        isNEBVerifiedHF: isHF
                    )
                }
            }

            var stmtPairs: OpaquePointer? = nil
            let sqlPairs = """
                SELECT overhang_a, overhang_b, ligation_count
                FROM neb_ligase_fidelity_matrices WHERE enzyme_key = ?;
                """
            if sqlite3_prepare_v2(openedDB, sqlPairs, -1, &stmtPairs, nil) == SQLITE_OK, let p = stmtPairs {
                defer { sqlite3_finalize(p) }
                sqlite3_bind_text(p, 1, (ekey as NSString).utf8String, -1, nil)
                while sqlite3_step(p) == SQLITE_ROW {
                    guard let aC = sqlite3_column_text(p, 0),
                          let bC = sqlite3_column_text(p, 1) else { continue }
                    let a = String(cString: aC)
                    let b = String(cString: bC)
                    let cnt = Int(sqlite3_column_int(p, 2))
                    counts[a, default: [:]][b] = cnt
                }
            }

            // 兼容旧版仅含 neb_t4_* 表的外部数据库
            if stats.isEmpty && ekey != "sapi" {
                var legStats: OpaquePointer? = nil
                let sqlLegStats = """
                    SELECT overhang, rc_overhang, is_palindromic, gc_count, wc_ligation_count, individual_fidelity, is_neb_verified_hf
                    FROM neb_t4_overhang_stats;
                    """
                if sqlite3_prepare_v2(openedDB, sqlLegStats, -1, &legStats, nil) == SQLITE_OK, let s = legStats {
                    defer { sqlite3_finalize(s) }
                    while sqlite3_step(s) == SQLITE_ROW {
                        guard let ovC = sqlite3_column_text(s, 0),
                              let rcC = sqlite3_column_text(s, 1) else { continue }
                        let ov = String(cString: ovC)
                        let rc = String(cString: rcC)
                        stats[ov] = OverhangStatsRecord(
                            overhang: ov,
                            rcOverhang: rc,
                            isPalindromic: sqlite3_column_int(s, 2) != 0,
                            gcCount: Int(sqlite3_column_int(s, 3)),
                            wcLigationCount: Int(sqlite3_column_int(s, 4)),
                            selfLigationCount: 0,
                            individualFidelity: sqlite3_column_double(s, 5),
                            isNEBVerifiedHF: sqlite3_column_int(s, 6) != 0
                        )
                    }
                }
                var legPairs: OpaquePointer? = nil
                if sqlite3_prepare_v2(openedDB, "SELECT overhang_a, overhang_b, ligation_count FROM neb_t4_ligase_fidelity;", -1, &legPairs, nil) == SQLITE_OK, let p = legPairs {
                    defer { sqlite3_finalize(p) }
                    while sqlite3_step(p) == SQLITE_ROW {
                        guard let aC = sqlite3_column_text(p, 0),
                              let bC = sqlite3_column_text(p, 1) else { continue }
                        counts[String(cString: aC), default: [:]][String(cString: bC)] = Int(sqlite3_column_int(p, 2))
                    }
                }
            }

            return NEBLigaseFidelityMatrix(
                enzymeKey: ekey,
                overhangLength: ovLen,
                sourceCitation: citation,
                sourceDOI: doi,
                statsByOverhang: stats,
                ligationCounts: counts
            )
        }
    }

    public struct CrossMismatchPair: Sendable, Equatable, Codable {
        public let overhangA: String
        public let overhangB: String
        public let ligationCount: Int

        public init(overhangA: String, overhangB: String, ligationCount: Int) {
            self.overhangA = overhangA
            self.overhangB = overhangB
            self.ligationCount = ligationCount
        }
    }

    public struct OverhangSetEvaluation: Sendable, Equatable, Codable {
        public let overhangs: [String]
        public let isValid: Bool
        public let assemblyFidelity: Double
        public let crossMismatchCount: Int
        public let crossMismatchPairs: [CrossMismatchPair]
        public let issues: [String]

        public init(
            overhangs: [String],
            isValid: Bool,
            assemblyFidelity: Double,
            crossMismatchCount: Int,
            crossMismatchPairs: [CrossMismatchPair],
            issues: [String]
        ) {
            self.overhangs = overhangs
            self.isValid = isValid
            self.assemblyFidelity = assemblyFidelity
            self.crossMismatchCount = crossMismatchCount
            self.crossMismatchPairs = crossMismatchPairs
            self.issues = issues
        }
    }

    public struct GoldenGateOverhangPlan: Sendable, Equatable, Codable {
        public let enzymeName: String
        public let fragmentCount: Int
        public let junctionCount: Int
        public let overhangLength: Int
        public let assignedOverhangs: [String]
        public let assemblyFidelity: Double
        public let crossMismatchCount: Int
        public let crossMismatchPairs: [CrossMismatchPair]
        public let warnings: [String]

        public init(
            enzymeName: String,
            fragmentCount: Int,
            junctionCount: Int,
            overhangLength: Int,
            assignedOverhangs: [String],
            assemblyFidelity: Double,
            crossMismatchCount: Int,
            crossMismatchPairs: [CrossMismatchPair],
            warnings: [String]
        ) {
            self.enzymeName = enzymeName
            self.fragmentCount = fragmentCount
            self.junctionCount = junctionCount
            self.overhangLength = overhangLength
            self.assignedOverhangs = assignedOverhangs
            self.assemblyFidelity = assemblyFidelity
            self.crossMismatchCount = crossMismatchCount
            self.crossMismatchPairs = crossMismatchPairs
            self.warnings = warnings
        }
    }

    public struct DomesticationSuggestion: Sendable, Equatable, Codable {
        public let fragmentIndex: Int
        public let fragmentName: String
        public let enzymeName: String
        public let siteStrand: String
        public let siteStart1Based: Int
        public let siteEnd1Based: Int
        public let originalSite: String
        public let isCodingSequence: Bool
        public let codonIndex1Based: Int?
        public let originalCodon: String?
        public let mutatedCodon: String?
        public let aminoAcid: String?
        public let mutationPosition1Based: Int
        public let originalBase: String
        public let mutatedBase: String
        public let isSynonymous: Bool
        public let note: String

        public init(
            fragmentIndex: Int,
            fragmentName: String,
            enzymeName: String,
            siteStrand: String,
            siteStart1Based: Int,
            siteEnd1Based: Int,
            originalSite: String,
            isCodingSequence: Bool,
            codonIndex1Based: Int?,
            originalCodon: String?,
            mutatedCodon: String?,
            aminoAcid: String?,
            mutationPosition1Based: Int,
            originalBase: String,
            mutatedBase: String,
            isSynonymous: Bool,
            note: String
        ) {
            self.fragmentIndex = fragmentIndex
            self.fragmentName = fragmentName
            self.enzymeName = enzymeName
            self.siteStrand = siteStrand
            self.siteStart1Based = siteStart1Based
            self.siteEnd1Based = siteEnd1Based
            self.originalSite = originalSite
            self.isCodingSequence = isCodingSequence
            self.codonIndex1Based = codonIndex1Based
            self.originalCodon = originalCodon
            self.mutatedCodon = mutatedCodon
            self.aminoAcid = aminoAcid
            self.mutationPosition1Based = mutationPosition1Based
            self.originalBase = originalBase
            self.mutatedBase = mutatedBase
            self.isSynonymous = isSynonymous
            self.note = note
        }
    }

    public struct FragmentDomesticationResult: Sendable, Equatable, Codable {
        public let fragmentIndex: Int
        public let fragmentName: String
        public let originalLength: Int
        public let internalSitesFound: Int
        public let remainingSitesAfterDomestication: Int
        public let suggestions: [DomesticationSuggestion]
        public let domesticatedSequence: String

        public init(
            fragmentIndex: Int,
            fragmentName: String,
            originalLength: Int,
            internalSitesFound: Int,
            remainingSitesAfterDomestication: Int,
            suggestions: [DomesticationSuggestion],
            domesticatedSequence: String
        ) {
            self.fragmentIndex = fragmentIndex
            self.fragmentName = fragmentName
            self.originalLength = originalLength
            self.internalSitesFound = internalSitesFound
            self.remainingSitesAfterDomestication = remainingSitesAfterDomestication
            self.suggestions = suggestions
            self.domesticatedSequence = domesticatedSequence
        }
    }

    public struct GoldenGateFragmentInput: Sendable, Equatable, Codable {
        public let name: String
        public let sequence: String
        public let isCodingSequence: Bool
        public let readingFrameOffset: Int

        public init(
            name: String,
            sequence: String,
            isCodingSequence: Bool = true,
            readingFrameOffset: Int = 0
        ) {
            self.name = name
            self.sequence = sequence
            self.isCodingSequence = isCodingSequence
            self.readingFrameOffset = readingFrameOffset
        }
    }

    public struct GoldenGateAssemblyPlan: Sendable, Equatable, Codable {
        public let enzymeName: String
        public let recognitionSite: String
        public let overhangLength: Int
        public let overhangPlan: GoldenGateOverhangPlan
        public let domestications: [FragmentDomesticationResult]
        public let totalInternalSitesFound: Int
        public let assembledSequenceLength: Int
        public let junctionSiteWarnings: [String]

        public init(
            enzymeName: String,
            recognitionSite: String,
            overhangLength: Int,
            overhangPlan: GoldenGateOverhangPlan,
            domestications: [FragmentDomesticationResult],
            totalInternalSitesFound: Int,
            assembledSequenceLength: Int,
            junctionSiteWarnings: [String] = []
        ) {
            self.enzymeName = enzymeName
            self.recognitionSite = recognitionSite
            self.overhangLength = overhangLength
            self.overhangPlan = overhangPlan
            self.domestications = domestications
            self.totalInternalSitesFound = totalInternalSitesFound
            self.assembledSequenceLength = assembledSequenceLength
            self.junctionSiteWarnings = junctionSiteWarnings
        }
    }

    // MARK: - 2. 标准遗传密码表与宿主特异同义密码子偏好表

    private static let codonToAA: [String: String] = [
        "TTT": "F", "TTC": "F", "TTA": "L", "TTG": "L",
        "CTT": "L", "CTC": "L", "CTA": "L", "CTG": "L",
        "ATT": "I", "ATC": "I", "ATA": "I", "ATG": "M",
        "GTT": "V", "GTC": "V", "GTA": "V", "GTG": "V",
        "TCT": "S", "TCC": "S", "TCA": "S", "TCG": "S",
        "CCT": "P", "CCC": "P", "CCA": "P", "CCG": "P",
        "ACT": "T", "ACC": "T", "ACA": "T", "ACG": "T",
        "GCT": "A", "GCC": "A", "GCA": "A", "GCG": "A",
        "TAT": "Y", "TAC": "Y", "TAA": "*", "TAG": "*",
        "CAT": "H", "CAC": "H", "CAA": "Q", "CAG": "Q",
        "AAT": "N", "AAC": "N", "AAA": "K", "AAG": "K",
        "GAT": "D", "GAC": "D", "GAA": "E", "GAG": "E",
        "TGT": "C", "TGC": "C", "TGA": "*", "TGG": "W",
        "CGT": "R", "CGC": "R", "CGA": "R", "CGG": "R",
        "AGT": "S", "AGC": "S", "AGA": "R", "AGG": "R",
        "GGT": "G", "GGC": "G", "GGA": "G", "GGG": "G"
    ]

    /// 宿主特异同义密码子偏好排序（按高表达基因频率降序）
    private static func preferredCodons(for host: HostOrganism) -> [String: [String]] {
        switch host {
        case .eColi:
            return [
                "A": ["GCG", "GCC", "GCA", "GCT"],
                "C": ["TGC", "TGT"],
                "D": ["GAT", "GAC"],
                "E": ["GAA", "GAG"],
                "F": ["TTT", "TTC"],
                "G": ["GGC", "GGT", "GGG", "GGA"],
                "H": ["CAT", "CAC"],
                "I": ["ATT", "ATC", "ATA"],
                "K": ["AAA", "AAG"],
                "L": ["CTG", "TTA", "TTG", "CTT", "CTC", "CTA"],
                "M": ["ATG"],
                "N": ["AAC", "AAT"],
                "P": ["CCG", "CCA", "CCT", "CCC"],
                "Q": ["CAG", "CAA"],
                "R": ["CGC", "CGT", "CGG", "CGA", "AGA", "AGG"],
                "S": ["AGC", "TCT", "TCC", "TCG", "AGT", "TCA"],
                "T": ["ACC", "ACG", "ACT", "ACA"],
                "V": ["GTG", "GTT", "GTC", "GTA"],
                "W": ["TGG"],
                "Y": ["TAT", "TAC"],
                "*": ["TAA", "TGA", "TAG"]
            ]
        case .human:
            return [
                "A": ["GCC", "GCT", "GCA", "GCG"],
                "C": ["TGC", "TGT"],
                "D": ["GAC", "GAT"],
                "E": ["GAG", "GAA"],
                "F": ["TTC", "TTT"],
                "G": ["GGC", "GGG", "GGA", "GGT"],
                "H": ["CAC", "CAT"],
                "I": ["ATC", "ATT", "ATA"],
                "K": ["AAG", "AAA"],
                "L": ["CTG", "CTC", "CTT", "TTG", "TTA", "CTA"],
                "M": ["ATG"],
                "N": ["AAC", "AAT"],
                "P": ["CCC", "CCT", "CCA", "CCG"],
                "Q": ["CAG", "CAA"],
                "R": ["CGG", "CGC", "AGG", "AGA", "CGT", "CGA"],
                "S": ["AGC", "TCC", "TCT", "AGT", "TCA", "TCG"],
                "T": ["ACC", "ACA", "ACT", "ACG"],
                "V": ["GTG", "GTC", "GTT", "GTA"],
                "W": ["TGG"],
                "Y": ["TAC", "TAT"],
                "*": ["TGA", "TAA", "TAG"]
            ]
        case .yeast:
            return [
                "A": ["GCT", "GCC", "GCA", "GCG"],
                "C": ["TGT", "TGC"],
                "D": ["GAT", "GAC"],
                "E": ["GAA", "GAG"],
                "F": ["TTT", "TTC"],
                "G": ["GGT", "GGA", "GGC", "GGG"],
                "H": ["CAT", "CAC"],
                "I": ["ATT", "ATC", "ATA"],
                "K": ["AAA", "AAG"],
                "L": ["TTG", "TTA", "CTT", "CTA", "CTG", "CTC"],
                "M": ["ATG"],
                "N": ["AAT", "AAC"],
                "P": ["CCA", "CCT", "CCC", "CCG"],
                "Q": ["CAA", "CAG"],
                "R": ["AGA", "AGG", "CGT", "CGA", "CGC", "CGG"],
                "S": ["TCT", "TCA", "TCC", "AGT", "AGC", "TCG"],
                "T": ["ACT", "ACA", "ACC", "ACG"],
                "V": ["GTT", "GTC", "GTA", "GTG"],
                "W": ["TGG"],
                "Y": ["TAT", "TAC"],
                "*": ["TAA", "TGA", "TAG"]
            ]
        }
    }

    // MARK: - 3. NEB 实测矩阵加载与保真度评估（含 j == i 自错配扫描与方向非对称性保留）

    public static func loadNEBFidelityMatrix(
        dbPath: String? = nil,
        enzymeName: String = "BsaI"
    ) -> NEBLigaseFidelityMatrix {
        NEBLigaseFidelityMatrix.loadFromSQLite(dbPath: dbPath, enzymeName: enzymeName)
    }

    public static func evaluateOverhangSet(
        overhangs: [String],
        matrix: NEBLigaseFidelityMatrix
    ) -> OverhangSetEvaluation {
        let normalized = overhangs.map { BioSequence.clean($0) }
        let expectedLen = matrix.overhangLength
        var issues: [String] = []
        var seenCanonical = Set<String>()
        var hasInvalidLength = false

        for ov in normalized {
            if ov.count != expectedLen {
                hasInvalidLength = true
                issues.append(L10n.tr("接头 \(ov) 长度不为 \(expectedLen) bp", "Overhang \(ov) is not \(expectedLen) bp long"))
                continue
            }
            let rc = BioSequence.reverseComplement(ov)
            if ov == rc {
                issues.append(L10n.tr("接头 \(ov) 为回文序列，会导致载体/片段自连或反向组装", "Overhang \(ov) is palindromic, causing vector/insert self-ligation or inverted assembly"))
            }
            let canon = min(ov, rc)
            if seenCanonical.contains(canon) {
                issues.append(L10n.tr("接头 \(ov) 与已有接头重复或反向互补冲突", "Overhang \(ov) duplicates or reverse-complements an existing overhang"))
            }
            seenCanonical.insert(canon)

            let selfFwd = matrix.ligationCount(ov, ov)
            let selfRev = matrix.ligationCount(rc, rc)
            if ov != rc && (selfFwd > 0 || selfRev > 0) {
                issues.append(L10n.tr("接头 \(ov)/\(rc) 存在自我错配连接热点（self=\(max(selfFwd, selfRev))）", "Overhang \(ov)/\(rc) exhibits self-misligation hotspot (self=\(max(selfFwd, selfRev)))"))
            }
        }

        var exposedEnds: [String] = []
        exposedEnds.reserveCapacity(normalized.count * 2)
        for ov in normalized where ov.count == expectedLen {
            exposedEnds.append(ov)
            exposedEnds.append(BioSequence.reverseComplement(ov))
        }

        // 完整扫描所有暴露末端对 (i, j) with j >= i（按无序对去重，仅跳过同一接头非回文 WC 配对）
        var mismatchByPair: [String: CrossMismatchPair] = [:]
        for i in 0..<exposedEnds.count {
            let u = exposedEnds[i]
            for j in i..<exposedEnds.count {
                let v = exposedEnds[j]
                if j == i + 1 && (i % 2 == 0) && u != v { continue }
                let cntUV = matrix.ligationCount(u, v)
                let cntVU = (j == i) ? cntUV : matrix.ligationCount(v, u)
                let cnt = max(cntUV, cntVU)
                if cnt > 0 {
                    let a = min(u, v)
                    let b = max(u, v)
                    let key = "\(a)|\(b)"
                    if let prev = mismatchByPair[key] {
                        if cnt > prev.ligationCount {
                            mismatchByPair[key] = CrossMismatchPair(overhangA: a, overhangB: b, ligationCount: cnt)
                        }
                    } else {
                        mismatchByPair[key] = CrossMismatchPair(overhangA: a, overhangB: b, ligationCount: cnt)
                    }
                }
            }
        }
        var mismatches = Array(mismatchByPair.values)
        mismatches.sort {
            if $0.overhangA != $1.overhangA { return $0.overhangA < $1.overhangA }
            return $0.overhangB < $1.overhangB
        }

        // Pryor et al. (2020) / Potapov et al. (2018) 联合组装保真度乘积；任一悬突长度非法时严格返回 0.0
        var fidelity = (normalized.isEmpty || hasInvalidLength) ? 0.0 : 1.0
        if !hasInvalidLength {
            for ov in normalized where ov.count == expectedLen {
                let rc = BioSequence.reverseComplement(ov)
                let wc = Double(matrix.ligationCount(ov, rc) + matrix.ligationCount(rc, ov))
                var total = 0.0
                for end in exposedEnds {
                    total += Double(matrix.ligationCount(ov, end)) + Double(matrix.ligationCount(rc, end))
                }
                let jFid = total > 0.0 ? (wc / total) : 0.0
                fidelity *= jFid
            }
        }

        return OverhangSetEvaluation(
            overhangs: normalized,
            isValid: issues.isEmpty,
            assemblyFidelity: fidelity,
            crossMismatchCount: mismatches.count,
            crossMismatchPairs: mismatches,
            issues: issues
        )
    }

    // MARK: - 4. 全局优化高保真接头自动分配（NEB DAD: 贪心初值 + 1-Swap 坐标上升 + 确定性模拟退火）

    private static func isHomopolymer(_ s: String) -> Bool {
        guard let first = s.first else { return false }
        return s.allSatisfy { $0 == first }
    }

    /// 跨平台确定性 64-bit LCG（确保 Swift 与 Python MCP 模拟退火轨迹完全一致）
    private struct DeterministicLCG {
        var state: UInt64
        mutating func nextUInt64() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func nextInt(_ upperBound: Int) -> Int {
            guard upperBound > 1 else { return 0 }
            return Int(nextUInt64() % UInt64(upperBound))
        }
        mutating func nextUnitDouble() -> Double {
            return Double(nextUInt64() >> 11) / Double(1 << 53)
        }
    }

    public static func allocateHighFidelityOverhangs(
        fragmentCount: Int,
        enzymeName: String = "BsaI",
        fixedOverhangs: [String] = [],
        isCircular: Bool = true,
        matrix: NEBLigaseFidelityMatrix? = nil,
        dbPath: String? = nil
    ) -> GoldenGateOverhangPlan {
        let canonKey = NEBLigaseFidelityMatrix.canonicalEnzymeKey(enzymeName)
        let spec = RestrictionEnzyme.typeIISCatalog[canonKey]
            ?? RestrictionEnzyme.typeIISCatalog["bsai"]!
        let ovLen = spec.overhangLength
        let maxFrags = (ovLen == 3) ? 15 : 24
        let clampedFrags = max(2, min(maxFrags, fragmentCount))
        let junctionCount = isCircular ? clampedFrags : (clampedFrags + 1)

        var warnings: [String] = []
        if fragmentCount != clampedFrags {
            warnings.append(L10n.tr("片段数已调整至支持范围 2–\(maxFrags) (\(clampedFrags))。", "Fragment count clamped to supported range 2–\(maxFrags) (\(clampedFrags))."))
        }

        let mat = matrix ?? loadNEBFidelityMatrix(dbPath: dbPath, enzymeName: spec.name)
        var chosen: [String] = []
        var usedCanonical = Set<String>()

        for rawFixed in fixedOverhangs {
            let ov = BioSequence.clean(rawFixed)
            guard ov.count == ovLen else {
                warnings.append(L10n.tr("已忽略长度非 \(ovLen) bp 的固定接头: \(rawFixed)", "Ignored non-\(ovLen)-bp fixed overhang: \(rawFixed)"))
                continue
            }
            let rc = BioSequence.reverseComplement(ov)
            if ov == rc {
                warnings.append(L10n.tr("已忽略回文固定接头: \(ov)", "Ignored palindromic fixed overhang: \(ov)"))
                continue
            }
            let canon = min(ov, rc)
            if usedCanonical.contains(canon) {
                warnings.append(L10n.tr("已忽略重复或互补冲突的固定接头: \(ov)", "Ignored duplicate/complementary fixed overhang: \(ov)"))
                continue
            }
            if chosen.count < junctionCount {
                chosen.append(ov)
                usedCanonical.insert(canon)
            }
        }
        let fixedCount = chosen.count

        // 构建非回文、非同聚物规范候选池，严格按 selfLigationCount 升序优先无自我错配末端
        var seenPool = Set<String>()
        var fullPool: [OverhangStatsRecord] = []
        for (_, rec) in mat.statsByOverhang {
            guard !rec.isPalindromic, !isHomopolymer(rec.overhang) else { continue }
            let canon = min(rec.overhang, rec.rcOverhang)
            guard !seenPool.contains(canon) else { continue }
            seenPool.insert(canon)
            let canonRec = mat.statsByOverhang[canon] ?? rec
            let rcRec = mat.statsByOverhang[canonRec.rcOverhang]
            let combinedSelf = max(canonRec.selfLigationCount, rcRec?.selfLigationCount ?? 0)
            let combinedFid = min(canonRec.individualFidelity, rcRec?.individualFidelity ?? canonRec.individualFidelity)
            fullPool.append(OverhangStatsRecord(
                overhang: canonRec.overhang,
                rcOverhang: canonRec.rcOverhang,
                isPalindromic: false,
                gcCount: canonRec.gcCount,
                wcLigationCount: canonRec.wcLigationCount,
                selfLigationCount: combinedSelf,
                individualFidelity: combinedFid,
                isNEBVerifiedHF: canonRec.isNEBVerifiedHF && combinedSelf == 0
            ))
        }
        fullPool.sort { a, b in
            if a.selfLigationCount != b.selfLigationCount { return a.selfLigationCount < b.selfLigationCount }
            if a.isNEBVerifiedHF != b.isNEBVerifiedHF { return a.isNEBVerifiedHF && !b.isNEBVerifiedHF }
            if abs(a.individualFidelity - b.individualFidelity) > 1e-9 { return a.individualFidelity > b.individualFidelity }
            if a.wcLigationCount != b.wcLigationCount { return a.wcLigationCount > b.wcLigationCount }
            return a.overhang < b.overhang
        }
        let neededMutable = max(0, junctionCount - fixedCount)
        let zeroSelfPool = fullPool.filter { $0.selfLigationCount == 0 && !usedCanonical.contains(min($0.overhang, $0.rcOverhang)) }
        let pool: [OverhangStatsRecord] = (zeroSelfPool.count >= neededMutable)
            ? fullPool.filter { $0.selfLigationCount == 0 }
            : fullPool

        // Phase 1: 确定性贪心初始化
        while chosen.count < junctionCount {
            var bestCandidate: OverhangStatsRecord? = nil
            var bestEval: OverhangSetEvaluation? = nil

            for cand in pool {
                let canon = min(cand.overhang, cand.rcOverhang)
                if usedCanonical.contains(canon) { continue }
                let trialEval = evaluateOverhangSet(overhangs: chosen + [cand.overhang], matrix: mat)

                if let curBestEval = bestEval, let curBestCand = bestCandidate {
                    let better: Bool
                    if abs(trialEval.assemblyFidelity - curBestEval.assemblyFidelity) > 1e-9 {
                        better = trialEval.assemblyFidelity > curBestEval.assemblyFidelity
                    } else if trialEval.crossMismatchCount != curBestEval.crossMismatchCount {
                        better = trialEval.crossMismatchCount < curBestEval.crossMismatchCount
                    } else if (cand.selfLigationCount == 0) != (curBestCand.selfLigationCount == 0) {
                        better = (cand.selfLigationCount == 0)
                    } else if cand.isNEBVerifiedHF != curBestCand.isNEBVerifiedHF {
                        better = cand.isNEBVerifiedHF && !curBestCand.isNEBVerifiedHF
                    } else if abs(cand.individualFidelity - curBestCand.individualFidelity) > 1e-9 {
                        better = cand.individualFidelity > curBestCand.individualFidelity
                    } else {
                        better = cand.overhang < curBestCand.overhang
                    }
                    if better {
                        bestCandidate = cand
                        bestEval = trialEval
                    }
                } else {
                    bestCandidate = cand
                    bestEval = trialEval
                }
            }

            guard let picked = bestCandidate else { break }
            chosen.append(picked.overhang)
            usedCanonical.insert(min(picked.overhang, picked.rcOverhang))
        }

        var bestSet = chosen
        var bestEval = evaluateOverhangSet(overhangs: bestSet, matrix: mat)

        // Phase 2: 当贪心解尚未达到 100% 零错配全局最优时，执行确定性 1-Swap 坐标上升 + 模拟退火 (NEB DAD)
        let mutableCount = bestSet.count - fixedCount
        if mutableCount > 0 && (bestEval.assemblyFidelity < 1.0 - 1e-12 || bestEval.crossMismatchCount > 0) && pool.count > bestSet.count {
            let searchPool = Array(pool.prefix(min(pool.count, 72)))

            func isStrictlyBetter(_ lhs: OverhangSetEvaluation, than rhs: OverhangSetEvaluation) -> Bool {
                if lhs.issues.count != rhs.issues.count {
                    return lhs.issues.count < rhs.issues.count
                }
                if abs(lhs.assemblyFidelity - rhs.assemblyFidelity) > 1e-9 {
                    return lhs.assemblyFidelity > rhs.assemblyFidelity
                }
                return lhs.crossMismatchCount < rhs.crossMismatchCount
            }

            func runOneSwapPolish(_ startSet: [String], _ startEval: OverhangSetEvaluation) -> ([String], OverhangSetEvaluation) {
                var cur = startSet
                var curEval = startEval
                for _ in 0..<12 {
                    var improved = false
                    var used = Set(cur.map { min($0, BioSequence.reverseComplement($0)) })
                    for pos in fixedCount..<cur.count {
                        let oldOv = cur[pos]
                        let oldCanon = min(oldOv, BioSequence.reverseComplement(oldOv))
                        used.remove(oldCanon)
                        var localBestOv = oldOv
                        var localBestEval = curEval
                        for cand in searchPool {
                            let cCanon = min(cand.overhang, cand.rcOverhang)
                            if used.contains(cCanon) { continue }
                            var trial = cur
                            trial[pos] = cand.overhang
                            let tEval = evaluateOverhangSet(overhangs: trial, matrix: mat)
                            if isStrictlyBetter(tEval, than: localBestEval) {
                                localBestOv = cand.overhang
                                localBestEval = tEval
                            }
                        }
                        cur[pos] = localBestOv
                        used.insert(min(localBestOv, BioSequence.reverseComplement(localBestOv)))
                        if isStrictlyBetter(localBestEval, than: curEval) {
                            curEval = localBestEval
                            improved = true
                        }
                    }
                    if !improved || (curEval.assemblyFidelity >= 1.0 - 1e-12 && curEval.crossMismatchCount == 0) {
                        break
                    }
                }
                return (cur, curEval)
            }

            (bestSet, bestEval) = runOneSwapPolish(bestSet, bestEval)

            // 确定性模拟退火跳出局部最优（固定种子确保 Swift/Python 100% 对齐）
            if bestEval.assemblyFidelity < 1.0 - 1e-12 || bestEval.crossMismatchCount > 0 {
                var rng = DeterministicLCG(state: 0x5EED_DAD0_2020_0001)
                var curSet = bestSet
                var curEval = bestEval
                let saSteps = 300
                let tStart = 0.025
                let tEnd = 0.0005
                for step in 0..<saSteps {
                    let pos = fixedCount + rng.nextInt(mutableCount)
                    let candIdx = rng.nextInt(searchPool.count)
                    let cand = searchPool[candIdx]
                    let candCanon = min(cand.overhang, cand.rcOverhang)
                    var conflict = false
                    for k in 0..<curSet.count where k != pos {
                        if min(curSet[k], BioSequence.reverseComplement(curSet[k])) == candCanon {
                            conflict = true
                            break
                        }
                    }
                    if conflict { continue }
                    var trial = curSet
                    trial[pos] = cand.overhang
                    let tEval = evaluateOverhangSet(overhangs: trial, matrix: mat)
                    let delta = tEval.assemblyFidelity - curEval.assemblyFidelity
                    let frac = Double(step) / Double(max(1, saSteps - 1))
                    let temp = tStart * pow(tEnd / tStart, frac)
                    if delta >= 0.0 || rng.nextUnitDouble() < exp(delta / max(1e-9, temp)) {
                        curSet = trial
                        curEval = tEval
                        if isStrictlyBetter(curEval, than: bestEval) {
                            bestSet = curSet
                            bestEval = curEval
                            if bestEval.assemblyFidelity >= 1.0 - 1e-12 && bestEval.crossMismatchCount == 0 {
                                break
                            }
                        }
                    }
                }
                (bestSet, bestEval) = runOneSwapPolish(bestSet, bestEval)
            }
        }

        for iss in bestEval.issues where !warnings.contains(iss) {
            warnings.append(iss)
        }
        if bestEval.crossMismatchCount > 0 {
            warnings.append(L10n.tr("当前约束下存在 \(bestEval.crossMismatchCount) 组潜在交叉/自错配。", "\(bestEval.crossMismatchCount) potential cross/self-mismatch pair(s) remain under constraints."))
        }
        if bestSet.count < junctionCount {
            warnings.append(L10n.tr("\(spec.name) \(ovLen)-bp 接头空间不足以分配 \(junctionCount) 个正交位点。", "\(spec.name) \(ovLen)-bp overhang space is insufficient for \(junctionCount) orthogonal junctions."))
        }

        return GoldenGateOverhangPlan(
            enzymeName: spec.name,
            fragmentCount: clampedFrags,
            junctionCount: junctionCount,
            overhangLength: ovLen,
            assignedOverhangs: bestSet,
            assemblyFidelity: bestEval.assemblyFidelity,
            crossMismatchCount: bestEval.crossMismatchCount,
            crossMismatchPairs: bestEval.crossMismatchPairs,
            warnings: warnings
        )
    }

    // MARK: - 5. 内源 Type IIS 位点扫描与宿主特异同义突变抹除 (Domestication)

    public static func domesticateFragment(
        sequence: String,
        enzymeName: String,
        fragmentIndex: Int = 0,
        fragmentName: String = "Fragment",
        isCodingSequence: Bool = true,
        readingFrameOffset: Int = 0,
        hostOrganism: HostOrganism = .human
    ) -> FragmentDomesticationResult {
        let cleanSeq = BioSequence.clean(sequence)
        let seqLen = cleanSeq.count
        let canonKey = NEBLigaseFidelityMatrix.canonicalEnzymeKey(enzymeName)
        let spec = RestrictionEnzyme.typeIISCatalog[canonKey]
            ?? RestrictionEnzyme.typeIISCatalog["bsai"]!
        let siteFwd = spec.recognitionSite
        let siteRev = spec.reverseComplementSite
        let siteLen = siteFwd.count
        let hostCodons = preferredCodons(for: hostOrganism)

        func findInternalSites(in seqChars: [Character]) -> [(start0: Int, strand: String, site: String)] {
            let s = String(seqChars)
            var hits: [(start0: Int, strand: String, site: String)] = []
            for (strand, pat) in [("+", siteFwd), ("-", siteRev)] {
                var searchIdx = s.startIndex
                while let r = s.range(of: pat, options: .literal, range: searchIdx..<s.endIndex) {
                    let pos = s.distance(from: s.startIndex, to: r.lowerBound)
                    hits.append((pos, strand, pat))
                    searchIdx = s.index(after: r.lowerBound)
                }
            }
            return hits.sorted {
                if $0.start0 != $1.start0 { return $0.start0 < $1.start0 }
                return $0.strand < $1.strand
            }
        }

        func findSiteKeysInWindow(chars: [Character], lo: Int, hi: Int) -> Set<String> {
            guard hi - lo >= siteLen else { return [] }
            let window = String(chars[lo..<hi])
            var keys = Set<String>()
            for (strand, pat) in [("+", siteFwd), ("-", siteRev)] {
                var searchIdx = window.startIndex
                while let r = window.range(of: pat, options: .literal, range: searchIdx..<window.endIndex) {
                    let pos = lo + window.distance(from: window.startIndex, to: r.lowerBound)
                    keys.insert("\(pos):\(strand)")
                    searchIdx = window.index(after: r.lowerBound)
                }
            }
            return keys
        }

        /// 兼容双链重叠位点并扩窗覆盖全部突变碱基：只要目标位点消除且无新增位点即合法
        func isValidDomesticationEdit(before: [Character], after: [Character], targetStart: Int, targetStrand: String, editStart: Int, editEnd: Int) -> Bool {
            let winLo = max(0, min(targetStart, editStart) - siteLen + 1)
            let winHi = min(after.count, max(targetStart + siteLen, editEnd) + siteLen - 1)
            let beforeKeys = findSiteKeysInWindow(chars: before, lo: winLo, hi: winHi)
            let afterKeys = findSiteKeysInWindow(chars: after, lo: winLo, hi: winHi)
            guard !afterKeys.contains("\(targetStart):\(targetStrand)") else { return false }
            return afterKeys.subtracting(beforeKeys).isEmpty
        }

        var working = Array(cleanSeq)
        let initialHits = findInternalSites(in: working)
        var suggestions: [DomesticationSuggestion] = []

        let frame = ((readingFrameOffset % 3) + 3) % 3
        var iter = 0
        while iter < 200 {
            iter += 1
            let currentHits = findInternalSites(in: working)
            guard let target = currentHits.first else { break }
            let s0 = target.start0
            let e0 = s0 + siteLen
            var applied = false

            if isCodingSequence {
                var codonStarts: [Int] = []
                var c = frame
                while c + 3 <= seqLen {
                    if (c + 3) > s0 && c < e0 {
                        codonStarts.append(c)
                    }
                    c += 3
                }

                // Tier 1 (1-bp 同义替换) -> Tier 2 (单密码子 2/3-bp 同义替换，如 Ser/Leu/Arg)；严格要求至少 1 个突变碱基落在识别位点内部
                outerSingle: for allowMultiBase in [false, true] {
                    for cStart in codonStarts {
                        let origCodon = String(working[cStart..<(cStart + 3)])
                        guard let aa = codonToAA[origCodon],
                              let synList = hostCodons[aa] else { continue }
                        for candCodon in synList where candCodon != origCodon {
                            let origChars = Array(origCodon)
                            let candChars = Array(candCodon)
                            var diffOffsets: [Int] = []
                            for k in 0..<3 where origChars[k] != candChars[k] {
                                diffOffsets.append(k)
                            }
                            if !allowMultiBase && diffOffsets.count != 1 { continue }
                            if allowMultiBase && diffOffsets.count < 2 { continue }
                            guard let insideOffset = diffOffsets.first(where: { (cStart + $0) >= s0 && (cStart + $0) < e0 }) else {
                                continue
                            }

                            var trial = working
                            for k in 0..<3 { trial[cStart + k] = candChars[k] }
                            if isValidDomesticationEdit(before: working, after: trial, targetStart: s0, targetStrand: target.strand, editStart: cStart, editEnd: cStart + 3) {
                                working = trial
                                let codonIdx1 = ((cStart - frame) / 3) + 1
                                let mutPos0 = cStart + insideOffset
                                suggestions.append(
                                    DomesticationSuggestion(
                                        fragmentIndex: fragmentIndex,
                                        fragmentName: fragmentName,
                                        enzymeName: spec.name,
                                        siteStrand: target.strand,
                                        siteStart1Based: s0 + 1,
                                        siteEnd1Based: e0,
                                        originalSite: target.site,
                                        isCodingSequence: true,
                                        codonIndex1Based: codonIdx1,
                                        originalCodon: origCodon,
                                        mutatedCodon: candCodon,
                                        aminoAcid: aa,
                                        mutationPosition1Based: mutPos0 + 1,
                                        originalBase: String(origChars[insideOffset]),
                                        mutatedBase: String(candChars[insideOffset]),
                                        isSynonymous: true,
                                        note: L10n.tr("密码子 #\(codonIdx1) (\(aa)) \(origCodon)→\(candCodon) (pos \(mutPos0 + 1) \(origChars[insideOffset])>\(candChars[insideOffset])) 同义抹除 \(spec.name) (\(target.strand))", "Codon #\(codonIdx1) (\(aa)) \(origCodon)→\(candCodon) (pos \(mutPos0 + 1) \(origChars[insideOffset])>\(candChars[insideOffset])) removes \(spec.name) (\(target.strand)) synonymously")
                                    )
                                )
                                applied = true
                                break outerSingle
                            }
                        }
                    }
                }

                // Tier 3: 双密码子协同同义替换兜底（解决单密码子改写引发邻接次生酶切位点的极端情形）
                if !applied && codonStarts.count >= 2 {
                    outerPair: for idxA in 0..<codonStarts.count {
                        let cA = codonStarts[idxA]
                        let origA = String(working[cA..<(cA + 3)])
                        guard let aaA = codonToAA[origA], let synA = hostCodons[aaA] else { continue }
                        for candA in synA where candA != origA {
                            let charsA = Array(candA)
                            for idxB in (idxA + 1)..<codonStarts.count {
                                let cB = codonStarts[idxB]
                                let origB = String(working[cB..<(cB + 3)])
                                guard let aaB = codonToAA[origB], let synB = hostCodons[aaB] else { continue }
                                for candB in synB where candB != origB {
                                    let charsB = Array(candB)
                                    var trial = working
                                    for k in 0..<3 { trial[cA + k] = charsA[k] }
                                    for k in 0..<3 { trial[cB + k] = charsB[k] }
                                    if isValidDomesticationEdit(before: working, after: trial, targetStart: s0, targetStrand: target.strand, editStart: min(cA, cB), editEnd: max(cA, cB) + 3) {
                                        working = trial
                                        let origAChars = Array(origA)
                                        let offA = (0..<3).first(where: { origAChars[$0] != charsA[$0] }) ?? 2
                                        let codonIdxA = ((cA - frame) / 3) + 1
                                        suggestions.append(
                                            DomesticationSuggestion(
                                                fragmentIndex: fragmentIndex,
                                                fragmentName: fragmentName,
                                                enzymeName: spec.name,
                                                siteStrand: target.strand,
                                                siteStart1Based: s0 + 1,
                                                siteEnd1Based: e0,
                                                originalSite: target.site,
                                                isCodingSequence: true,
                                                codonIndex1Based: codonIdxA,
                                                originalCodon: origA,
                                                mutatedCodon: candA,
                                                aminoAcid: aaA,
                                                mutationPosition1Based: cA + offA + 1,
                                                originalBase: String(origAChars[offA]),
                                                mutatedBase: String(charsA[offA]),
                                                isSynonymous: true,
                                                note: L10n.tr("双密码子协同同义抹除 #\(codonIdxA)(\(origA)→\(candA)) + #\( ((cB - frame) / 3) + 1 )(\(origB)→\(candB))", "Dual-codon synonymous domestication #\(codonIdxA)(\(origA)→\(candA)) + #\( ((cB - frame) / 3) + 1 )(\(origB)→\(candB))")
                                            )
                                        )
                                        applied = true
                                        break outerPair
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !applied && !isCodingSequence {
                let midPos0 = s0 + (siteLen / 2)
                let origCh = working[midPos0]
                for candCh in [Character("A"), Character("C"), Character("G"), Character("T")] where candCh != origCh {
                    var trial = working
                    trial[midPos0] = candCh
                    if isValidDomesticationEdit(before: working, after: trial, targetStart: s0, targetStrand: target.strand, editStart: midPos0, editEnd: midPos0 + 1) {
                        working = trial
                        suggestions.append(
                            DomesticationSuggestion(
                                fragmentIndex: fragmentIndex,
                                fragmentName: fragmentName,
                                enzymeName: spec.name,
                                siteStrand: target.strand,
                                siteStart1Based: s0 + 1,
                                siteEnd1Based: e0,
                                originalSite: target.site,
                                isCodingSequence: false,
                                codonIndex1Based: nil,
                                originalCodon: nil,
                                mutatedCodon: nil,
                                aminoAcid: nil,
                                mutationPosition1Based: midPos0 + 1,
                                originalBase: String(origCh),
                                mutatedBase: String(candCh),
                                isSynonymous: false,
                                note: L10n.tr("非编码区位点 pos \(midPos0 + 1) \(origCh)>\(candCh) 破坏 \(spec.name) (\(target.strand))", "Non-coding edit pos \(midPos0 + 1) \(origCh)>\(candCh) disrupts \(spec.name) (\(target.strand))")
                            )
                        )
                        applied = true
                        break
                    }
                }
            }

            if !applied { break }
        }

        let remainingHits = findInternalSites(in: working)
        return FragmentDomesticationResult(
            fragmentIndex: fragmentIndex,
            fragmentName: fragmentName,
            originalLength: seqLen,
            internalSitesFound: initialHits.count,
            remainingSitesAfterDomestication: remainingHits.count,
            suggestions: suggestions,
            domesticatedSequence: String(working)
        )
    }

    // MARK: - 6. 端到端 Golden Gate 方案编排（含接头跨界新生位点检测）

    /// 检测片段拼接接头跨界处（Junction-spanning）是否意外生成新的 Type IIS 识别位点
    public static func detectJunctionSpanningSites(
        domesticatedSequences: [String],
        assignedOverhangs: [String],
        enzymeName: String,
        isCircular: Bool = true
    ) -> [String] {
        let canonKey = NEBLigaseFidelityMatrix.canonicalEnzymeKey(enzymeName)
        let spec = RestrictionEnzyme.typeIISCatalog[canonKey]
            ?? RestrictionEnzyme.typeIISCatalog["bsai"]!
        let siteFwd = spec.recognitionSite
        let siteRev = spec.reverseComplementSite
        let flank = max(1, siteFwd.count - 1)
        let n = domesticatedSequences.count
        guard n > 0, !assignedOverhangs.isEmpty else { return [] }

        var warnings: [String] = []
        let seamCount = isCircular ? min(n, assignedOverhangs.count) : min(n + 1, assignedOverhangs.count)
        for j in 0..<seamCount {
            let leftSeq: String
            let rightSeq: String
            let ov = assignedOverhangs[j]
            if isCircular {
                leftSeq = domesticatedSequences[(j + n - 1) % n]
                rightSeq = domesticatedSequences[j]
            } else {
                leftSeq = (j > 0) ? domesticatedSequences[j - 1] : ""
                rightSeq = (j < n) ? domesticatedSequences[j] : ""
            }
            let leftTail = String(leftSeq.suffix(flank))
            let rightHead = String(rightSeq.prefix(flank))
            let seam = leftTail + ov + rightHead
            var hits: [String] = []
            if seam.contains(siteFwd) { hits.append(siteFwd) }
            if seam.contains(siteRev) { hits.append(siteRev) }
            if !hits.isEmpty {
                let hitDesc = hits.joined(separator: "/")
                warnings.append(L10n.tr(
                    "接头 #\(j + 1) (\(ov)) 跨界拼接区 \(leftTail)|\(ov)|\(rightHead) 意外生成了新的 \(spec.name) 位点 (\(hitDesc))，建议更换该接头或调整邻接密码子。",
                    "Junction #\(j + 1) (\(ov)) seam \(leftTail)|\(ov)|\(rightHead) creates a new \(spec.name) site (\(hitDesc)); replace this overhang or adjust adjacent codons."
                ))
            }
        }
        return warnings
    }

    public static func designAssembly(
        fragments: [GoldenGateFragmentInput],
        enzymeName: String = "BsaI",
        fixedOverhangs: [String] = [],
        isCircular: Bool = true,
        matrix: NEBLigaseFidelityMatrix? = nil,
        dbPath: String? = nil,
        hostOrganism: HostOrganism = .human
    ) -> GoldenGateAssemblyPlan {
        let canonKey = NEBLigaseFidelityMatrix.canonicalEnzymeKey(enzymeName)
        let spec = RestrictionEnzyme.typeIISCatalog[canonKey]
            ?? RestrictionEnzyme.typeIISCatalog["bsai"]!
        let ovPlan = allocateHighFidelityOverhangs(
            fragmentCount: max(2, fragments.count),
            enzymeName: spec.name,
            fixedOverhangs: fixedOverhangs,
            isCircular: isCircular,
            matrix: matrix,
            dbPath: dbPath
        )

        var doms: [FragmentDomesticationResult] = []
        doms.reserveCapacity(fragments.count)
        var totalSites = 0
        var totalFragLen = 0
        for (idx, f) in fragments.enumerated() {
            let d = domesticateFragment(
                sequence: f.sequence,
                enzymeName: spec.name,
                fragmentIndex: idx,
                fragmentName: f.name,
                isCodingSequence: f.isCodingSequence,
                readingFrameOffset: f.readingFrameOffset,
                hostOrganism: hostOrganism
            )
            doms.append(d)
            totalSites += d.internalSitesFound
            totalFragLen += d.domesticatedSequence.count
        }
        let junctionWarnings = detectJunctionSpanningSites(
            domesticatedSequences: doms.map(\.domesticatedSequence),
            assignedOverhangs: ovPlan.assignedOverhangs,
            enzymeName: spec.name,
            isCircular: isCircular
        )
        let mergedPlan = GoldenGateOverhangPlan(
            enzymeName: ovPlan.enzymeName,
            fragmentCount: ovPlan.fragmentCount,
            junctionCount: ovPlan.junctionCount,
            overhangLength: ovPlan.overhangLength,
            assignedOverhangs: ovPlan.assignedOverhangs,
            assemblyFidelity: ovPlan.assemblyFidelity,
            crossMismatchCount: ovPlan.crossMismatchCount,
            crossMismatchPairs: ovPlan.crossMismatchPairs,
            warnings: ovPlan.warnings + junctionWarnings
        )
        let junctionOverhead = ovPlan.assignedOverhangs.count * spec.overhangLength
        return GoldenGateAssemblyPlan(
            enzymeName: spec.name,
            recognitionSite: spec.recognitionSite,
            overhangLength: spec.overhangLength,
            overhangPlan: mergedPlan,
            domestications: doms,
            totalInternalSitesFound: totalSites,
            assembledSequenceLength: totalFragLen + junctionOverhead,
            junctionSiteWarnings: junctionWarnings
        )
    }
}
