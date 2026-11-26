import Foundation
import SQLite3

/// Type IIS Golden Gate 组装引擎 (BsaI / BsmBI / BbsI / SapI)
/// 基于 Libraries.sqlite 中的 NEB T4 连接酶 4-bp 黏性末端保真度矩阵，实现：
/// 1) 2–6 片段无交叉错配 4-bp / 3-bp 高保真接头自动分配
/// 2) 片段内部内源 Type IIS 位点扫描与编码区同义密码子抹除 (Domestication)
public struct GoldenGateEngine: Sendable {

    // MARK: - 1. 数据模型

    /// 单个 4-bp 黏性末端在 NEB T4 连接酶统计矩阵中的基础指标
    public struct OverhangStatsRecord: Sendable, Equatable, Codable {
        public let overhang: String
        public let rcOverhang: String
        public let isPalindromic: Bool
        public let gcCount: Int
        public let wcLigationCount: Int
        public let individualFidelity: Double
        public let isNEBVerifiedHF: Bool

        public init(
            overhang: String,
            rcOverhang: String,
            isPalindromic: Bool,
            gcCount: Int,
            wcLigationCount: Int,
            individualFidelity: Double,
            isNEBVerifiedHF: Bool
        ) {
            self.overhang = overhang
            self.rcOverhang = rcOverhang
            self.isPalindromic = isPalindromic
            self.gcCount = gcCount
            self.wcLigationCount = wcLigationCount
            self.individualFidelity = individualFidelity
            self.isNEBVerifiedHF = isNEBVerifiedHF
        }
    }

    /// 内存化 NEB T4 DNA Ligase 4-bp 保真度稀疏矩阵
    public struct NEBLigaseFidelityMatrix: Sendable, Equatable {
        public let statsByOverhang: [String: OverhangStatsRecord]
        public let ligationCounts: [String: [String: Int]]

        public init(
            statsByOverhang: [String: OverhangStatsRecord] = [:],
            ligationCounts: [String: [String: Int]] = [:]
        ) {
            self.statsByOverhang = statsByOverhang
            self.ligationCounts = ligationCounts
        }

        public func ligationCount(_ overhangA: String, _ overhangB: String) -> Int {
            ligationCounts[overhangA]?[overhangB] ?? 0
        }

        /// 从 Libraries.sqlite 只读加载 NEB T4 4-bp 保真度矩阵
        public static func loadFromSQLite(dbPath: String? = nil) -> NEBLigaseFidelityMatrix {
            guard let resolved = dbPath ?? CloneStudioResourceLocator.path(forResource: "Libraries", ofType: "sqlite") else {
                return NEBLigaseFidelityMatrix()
            }
            var db: OpaquePointer? = nil
            guard sqlite3_open_v2(resolved, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let openedDB = db else {
                if let db = db { sqlite3_close(db) }
                return NEBLigaseFidelityMatrix()
            }
            defer { sqlite3_close(openedDB) }

            var stats: [String: OverhangStatsRecord] = [:]
            var stmtStats: OpaquePointer? = nil
            let sqlStats = """
                SELECT overhang, rc_overhang, is_palindromic, gc_count, wc_ligation_count, individual_fidelity, is_neb_verified_hf
                FROM neb_t4_overhang_stats;
                """
            if sqlite3_prepare_v2(openedDB, sqlStats, -1, &stmtStats, nil) == SQLITE_OK, let s = stmtStats {
                defer { sqlite3_finalize(s) }
                while sqlite3_step(s) == SQLITE_ROW {
                    guard let ovC = sqlite3_column_text(s, 0),
                          let rcC = sqlite3_column_text(s, 1) else { continue }
                    let ov = String(cString: ovC)
                    let rc = String(cString: rcC)
                    let isPal = sqlite3_column_int(s, 2) != 0
                    let gcCnt = Int(sqlite3_column_int(s, 3))
                    let wcCnt = Int(sqlite3_column_int(s, 4))
                    let fid = sqlite3_column_double(s, 5)
                    let isHF = sqlite3_column_int(s, 6) != 0
                    stats[ov] = OverhangStatsRecord(
                        overhang: ov,
                        rcOverhang: rc,
                        isPalindromic: isPal,
                        gcCount: gcCnt,
                        wcLigationCount: wcCnt,
                        individualFidelity: fid,
                        isNEBVerifiedHF: isHF
                    )
                }
            }

            var counts: [String: [String: Int]] = [:]
            var stmtPairs: OpaquePointer? = nil
            let sqlPairs = "SELECT overhang_a, overhang_b, ligation_count FROM neb_t4_ligase_fidelity;"
            if sqlite3_prepare_v2(openedDB, sqlPairs, -1, &stmtPairs, nil) == SQLITE_OK, let p = stmtPairs {
                defer { sqlite3_finalize(p) }
                while sqlite3_step(p) == SQLITE_ROW {
                    guard let aC = sqlite3_column_text(p, 0),
                          let bC = sqlite3_column_text(p, 1) else { continue }
                    let a = String(cString: aC)
                    let b = String(cString: bC)
                    let cnt = Int(sqlite3_column_int(p, 2))
                    counts[a, default: [:]][b] = cnt
                }
            }

            return NEBLigaseFidelityMatrix(statsByOverhang: stats, ligationCounts: counts)
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

        public init(
            enzymeName: String,
            recognitionSite: String,
            overhangLength: Int,
            overhangPlan: GoldenGateOverhangPlan,
            domestications: [FragmentDomesticationResult],
            totalInternalSitesFound: Int,
            assembledSequenceLength: Int
        ) {
            self.enzymeName = enzymeName
            self.recognitionSite = recognitionSite
            self.overhangLength = overhangLength
            self.overhangPlan = overhangPlan
            self.domestications = domestications
            self.totalInternalSitesFound = totalInternalSitesFound
            self.assembledSequenceLength = assembledSequenceLength
        }
    }

    // MARK: - 2. 共享标准遗传密码表与高优先同义密码子表

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

    private static let preferredCodonsByAA: [String: [String]] = [
        "A": ["GCC", "GCT", "GCA", "GCG"],
        "C": ["TGC", "TGT"],
        "D": ["GAC", "GAT"],
        "E": ["GAG", "GAA"],
        "F": ["TTC", "TTT"],
        "G": ["GGC", "GGT", "GGA", "GGG"],
        "H": ["CAC", "CAT"],
        "I": ["ATC", "ATT", "ATA"],
        "K": ["AAG", "AAA"],
        "L": ["CTG", "CTC", "CTT", "TTG", "TTA", "CTA"],
        "M": ["ATG"],
        "N": ["AAC", "AAT"],
        "P": ["CCC", "CCT", "CCA", "CCG"],
        "Q": ["CAG", "CAA"],
        "R": ["CGC", "CGT", "AGG", "AGA", "CGG", "CGA"],
        "S": ["AGC", "TCC", "TCT", "AGT", "TCA", "TCG"],
        "T": ["ACC", "ACT", "ACA", "ACG"],
        "V": ["GTG", "GTC", "GTT", "GTA"],
        "W": ["TGG"],
        "Y": ["TAC", "TAT"],
        "*": ["TGA", "TAA", "TAG"]
    ]

    // MARK: - 3. NEB T4 矩阵加载与保真度评估

    public static func loadNEBFidelityMatrix(dbPath: String? = nil) -> NEBLigaseFidelityMatrix {
        NEBLigaseFidelityMatrix.loadFromSQLite(dbPath: dbPath)
    }

    public static func evaluateOverhangSet(
        overhangs: [String],
        matrix: NEBLigaseFidelityMatrix
    ) -> OverhangSetEvaluation {
        let normalized = overhangs.map { BioSequence.clean($0) }
        var issues: [String] = []
        var seenCanonical = Set<String>()

        for ov in normalized {
            if ov.count != 4 {
                issues.append(L10n.tr("接头 \(ov) 长度不为 4 bp", "Overhang \(ov) is not 4 bp long"))
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
        }

        var exposedEnds: [String] = []
        exposedEnds.reserveCapacity(normalized.count * 2)
        for ov in normalized where ov.count == 4 {
            exposedEnds.append(ov)
            exposedEnds.append(BioSequence.reverseComplement(ov))
        }

        var mismatches: [CrossMismatchPair] = []
        for i in 0..<exposedEnds.count {
            let u = exposedEnds[i]
            let rcU = BioSequence.reverseComplement(u)
            for j in (i + 1)..<exposedEnds.count {
                let v = exposedEnds[j]
                if v == rcU { continue }
                let cnt = matrix.ligationCount(u, v)
                if cnt > 0 {
                    let a = min(u, v)
                    let b = max(u, v)
                    mismatches.append(CrossMismatchPair(overhangA: a, overhangB: b, ligationCount: cnt))
                }
            }
        }
        mismatches.sort {
            if $0.overhangA != $1.overhangA { return $0.overhangA < $1.overhangA }
            return $0.overhangB < $1.overhangB
        }

        var fidelity = normalized.isEmpty ? 0.0 : 1.0
        for ov in normalized where ov.count == 4 {
            let rc = BioSequence.reverseComplement(ov)
            let wc = Double(matrix.ligationCount(ov, rc) + matrix.ligationCount(rc, ov))
            var total = 0.0
            for end in exposedEnds {
                total += Double(matrix.ligationCount(ov, end)) + Double(matrix.ligationCount(rc, end))
            }
            let jFid = total > 0.0 ? (wc / total) : 0.0
            fidelity *= jFid
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

    // MARK: - 4. 2–6 片段高保真接头自动分配

    public static func allocateHighFidelityOverhangs(
        fragmentCount: Int,
        enzymeName: String = "BsaI",
        fixedOverhangs: [String] = [],
        isCircular: Bool = true,
        matrix: NEBLigaseFidelityMatrix? = nil,
        dbPath: String? = nil
    ) -> GoldenGateOverhangPlan {
        let clampedFrags = max(2, min(6, fragmentCount))
        let junctionCount = isCircular ? clampedFrags : (clampedFrags + 1)
        let spec = RestrictionEnzyme.typeIISCatalog[enzymeName.lowercased()]
            ?? RestrictionEnzyme.typeIISCatalog["bsai"]!
        let ovLen = spec.overhangLength

        var warnings: [String] = []
        if fragmentCount != clampedFrags {
            warnings.append(L10n.tr("片段数已调整至支持范围 2–6 (\(clampedFrags))。", "Fragment count clamped to supported range 2–6 (\(clampedFrags))."))
        }

        if ovLen == 3 {
            return allocateThreeBpOverhangs(
                spec: spec,
                fragmentCount: clampedFrags,
                junctionCount: junctionCount,
                fixedOverhangs: fixedOverhangs,
                initialWarnings: warnings
            )
        }

        let mat = matrix ?? loadNEBFidelityMatrix(dbPath: dbPath)
        var chosen: [String] = []
        var usedCanonical = Set<String>()

        for rawFixed in fixedOverhangs {
            let ov = BioSequence.clean(rawFixed)
            guard ov.count == 4 else {
                warnings.append(L10n.tr("已忽略长度非 4 bp 的固定接头: \(rawFixed)", "Ignored non-4-bp fixed overhang: \(rawFixed)"))
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

        // 构建唯一非回文规范候选池 (120 个正反配对代表)，按 NEB HF -> 单体保真度 -> WC 计数 -> 字典序确定性排序
        var seenPool = Set<String>()
        var pool: [OverhangStatsRecord] = []
        for (_, rec) in mat.statsByOverhang {
            guard !rec.isPalindromic else { continue }
            let canon = min(rec.overhang, rec.rcOverhang)
            guard !seenPool.contains(canon) else { continue }
            seenPool.insert(canon)
            if let canonRec = mat.statsByOverhang[canon] {
                pool.append(canonRec)
            } else {
                pool.append(rec)
            }
        }
        pool.sort { a, b in
            if a.isNEBVerifiedHF != b.isNEBVerifiedHF {
                return a.isNEBVerifiedHF && !b.isNEBVerifiedHF
            }
            if abs(a.individualFidelity - b.individualFidelity) > 1e-9 {
                return a.individualFidelity > b.individualFidelity
            }
            if a.wcLigationCount != b.wcLigationCount {
                return a.wcLigationCount > b.wcLigationCount
            }
            return a.overhang < b.overhang
        }

        while chosen.count < junctionCount {
            var bestCandidate: OverhangStatsRecord? = nil
            var bestEval: OverhangSetEvaluation? = nil

            for cand in pool {
                let canon = min(cand.overhang, cand.rcOverhang)
                if usedCanonical.contains(canon) { continue }
                let trialEval = evaluateOverhangSet(overhangs: chosen + [cand.overhang], matrix: mat)

                if let curBestEval = bestEval, let curBestCand = bestCandidate {
                    let better: Bool
                    if trialEval.crossMismatchCount != curBestEval.crossMismatchCount {
                        better = trialEval.crossMismatchCount < curBestEval.crossMismatchCount
                    } else if abs(trialEval.assemblyFidelity - curBestEval.assemblyFidelity) > 1e-9 {
                        better = trialEval.assemblyFidelity > curBestEval.assemblyFidelity
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

        let finalEval = evaluateOverhangSet(overhangs: chosen, matrix: mat)
        if finalEval.crossMismatchCount > 0 {
            warnings.append(L10n.tr("当前约束下存在 \(finalEval.crossMismatchCount) 组潜在交叉错配。", "\(finalEval.crossMismatchCount) potential cross-mismatch pair(s) remain under constraints."))
        }

        return GoldenGateOverhangPlan(
            enzymeName: spec.name,
            fragmentCount: clampedFrags,
            junctionCount: junctionCount,
            overhangLength: ovLen,
            assignedOverhangs: chosen,
            assemblyFidelity: finalEval.assemblyFidelity,
            crossMismatchCount: finalEval.crossMismatchCount,
            crossMismatchPairs: finalEval.crossMismatchPairs,
            warnings: warnings
        )
    }

    private static func allocateThreeBpOverhangs(
        spec: TypeIISEnzymeSpec,
        fragmentCount: Int,
        junctionCount: Int,
        fixedOverhangs: [String],
        initialWarnings: [String]
    ) -> GoldenGateOverhangPlan {
        var warnings = initialWarnings
        let bases = ["A", "C", "G", "T"]
        var all3Mers: [String] = []
        for a in bases {
            for b in bases {
                for c in bases {
                    let s = a + b + c
                    if s == "AAA" || s == "TTT" || s == "CCC" || s == "GGG" { continue }
                    let rc = BioSequence.reverseComplement(s)
                    if s < rc { all3Mers.append(s) }
                }
            }
        }
        all3Mers.sort { x, y in
            let gcX = x.filter { $0 == "G" || $0 == "C" }.count
            let gcY = y.filter { $0 == "G" || $0 == "C" }.count
            let balX = abs(gcX - 1) <= 1 && gcX >= 1 && gcX <= 2
            let balY = abs(gcY - 1) <= 1 && gcY >= 1 && gcY <= 2
            if balX != balY { return balX && !balY }
            return x < y
        }

        var chosen: [String] = []
        var usedCanon = Set<String>()
        for raw in fixedOverhangs {
            let ov = BioSequence.clean(raw)
            guard ov.count == 3 else { continue }
            let canon = min(ov, BioSequence.reverseComplement(ov))
            if !usedCanon.contains(canon) && chosen.count < junctionCount {
                chosen.append(ov)
                usedCanon.insert(canon)
            }
        }

        func threeBpClash(_ u: String, _ v: String) -> Bool {
            let uChars = Array(u)
            let vChars = Array(v)
            var mm = 0
            var allGT = true
            for i in 0..<3 {
                let a = uChars[i]
                let b = vChars[2 - i]
                let isWC = (a == "A" && b == "T") || (a == "T" && b == "A")
                    || (a == "C" && b == "G") || (a == "G" && b == "C")
                if !isWC {
                    mm += 1
                    let isGT = (a == "G" && b == "T") || (a == "T" && b == "G")
                    if !isGT { allGT = false }
                }
            }
            return mm == 1 || (mm == 2 && allGT)
        }

        while chosen.count < junctionCount {
            var picked: String? = nil
            for cand in all3Mers {
                let canon = min(cand, BioSequence.reverseComplement(cand))
                if usedCanon.contains(canon) { continue }
                let trialEnds = (chosen + [cand]).flatMap { [$0, BioSequence.reverseComplement($0)] }
                var clashes = 0
                for i in 0..<trialEnds.count {
                    let rcI = BioSequence.reverseComplement(trialEnds[i])
                    for j in (i + 1)..<trialEnds.count where trialEnds[j] != rcI {
                        if threeBpClash(trialEnds[i], trialEnds[j]) { clashes += 1 }
                    }
                }
                if clashes == 0 {
                    picked = cand
                    break
                }
            }
            if let p = picked {
                chosen.append(p)
                usedCanon.insert(min(p, BioSequence.reverseComplement(p)))
            } else {
                warnings.append(L10n.tr("SapI 3-bp 接头空间不足以完全无错配分配 \(junctionCount) 个位点。", "SapI 3-bp overhang space is insufficient for zero-mismatch assignment across \(junctionCount) junctions."))
                break
            }
        }

        return GoldenGateOverhangPlan(
            enzymeName: spec.name,
            fragmentCount: fragmentCount,
            junctionCount: junctionCount,
            overhangLength: 3,
            assignedOverhangs: chosen,
            assemblyFidelity: chosen.count == junctionCount ? 1.0 : 0.90,
            crossMismatchCount: 0,
            crossMismatchPairs: [],
            warnings: warnings
        )
    }

    // MARK: - 5. 内源 Type IIS 位点扫描与同义突变抹除 (Domestication)

    public static func domesticateFragment(
        sequence: String,
        enzymeName: String,
        fragmentIndex: Int = 0,
        fragmentName: String = "Fragment",
        isCodingSequence: Bool = true,
        readingFrameOffset: Int = 0
    ) -> FragmentDomesticationResult {
        let cleanSeq = BioSequence.clean(sequence)
        let seqLen = cleanSeq.count
        let spec = RestrictionEnzyme.typeIISCatalog[enzymeName.lowercased()]
            ?? RestrictionEnzyme.typeIISCatalog["bsai"]!
        let siteFwd = spec.recognitionSite
        let siteRev = spec.reverseComplementSite
        let siteLen = siteFwd.count

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

        func introducesSiteAround(chars: [Character], centerStart: Int, centerEnd: Int) -> Bool {
            let lo = max(0, centerStart - siteLen + 1)
            let hi = min(chars.count, centerEnd + siteLen - 1)
            guard hi - lo >= siteLen else { return false }
            let window = String(chars[lo..<hi])
            return window.contains(siteFwd) || window.contains(siteRev)
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

                // 第一轮优先单碱基同义替换且突变点落在酶切识别区内部；第二轮放宽至任意合法单碱基同义替换
                outer: for requireInsideSite in [true, false] {
                    for cStart in codonStarts {
                        let origCodon = String(working[cStart..<(cStart + 3)])
                        guard let aa = codonToAA[origCodon],
                              let synList = preferredCodonsByAA[aa] else { continue }
                        for candCodon in synList where candCodon != origCodon {
                            let origChars = Array(origCodon)
                            let candChars = Array(candCodon)
                            var diffOffsets: [Int] = []
                            for k in 0..<3 where origChars[k] != candChars[k] {
                                diffOffsets.append(k)
                            }
                            guard diffOffsets.count == 1 else { continue }
                            let mutOffset = diffOffsets[0]
                            let mutPos0 = cStart + mutOffset
                            if requireInsideSite && !(mutPos0 >= s0 && mutPos0 < e0) {
                                continue
                            }

                            var trial = working
                            for k in 0..<3 { trial[cStart + k] = candChars[k] }
                            if !introducesSiteAround(chars: trial, centerStart: s0, centerEnd: e0) {
                                working = trial
                                let codonIdx1 = ((cStart - frame) / 3) + 1
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
                                        originalBase: String(origChars[mutOffset]),
                                        mutatedBase: String(candChars[mutOffset]),
                                        isSynonymous: true,
                                        note: L10n.tr("密码子 #\(codonIdx1) (\(aa)) \(origCodon)→\(candCodon) (pos \(mutPos0 + 1) \(origChars[mutOffset])>\(candChars[mutOffset])) 同义抹除 \(spec.name) (\(target.strand))", "Codon #\(codonIdx1) (\(aa)) \(origCodon)→\(candCodon) (pos \(mutPos0 + 1) \(origChars[mutOffset])>\(candChars[mutOffset])) removes \(spec.name) (\(target.strand)) synonymously")
                                    )
                                )
                                applied = true
                                break outer
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
                    if !introducesSiteAround(chars: trial, centerStart: s0, centerEnd: e0) {
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

    // MARK: - 6. 端到端 Golden Gate 方案编排

    public static func designAssembly(
        fragments: [GoldenGateFragmentInput],
        enzymeName: String = "BsaI",
        fixedOverhangs: [String] = [],
        isCircular: Bool = true,
        matrix: NEBLigaseFidelityMatrix? = nil,
        dbPath: String? = nil
    ) -> GoldenGateAssemblyPlan {
        let spec = RestrictionEnzyme.typeIISCatalog[enzymeName.lowercased()]
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
                readingFrameOffset: f.readingFrameOffset
            )
            doms.append(d)
            totalSites += d.internalSitesFound
            totalFragLen += d.domesticatedSequence.count
        }
        let junctionOverhead = ovPlan.assignedOverhangs.count * spec.overhangLength
        return GoldenGateAssemblyPlan(
            enzymeName: spec.name,
            recognitionSite: spec.recognitionSite,
            overhangLength: spec.overhangLength,
            overhangPlan: ovPlan,
            domestications: doms,
            totalInternalSitesFound: totalSites,
            assembledSequenceLength: totalFragLen + junctionOverhead
        )
    }
}
