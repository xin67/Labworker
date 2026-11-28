import Foundation
import SQLite3

/// 纯本地离线未知质粒 FASTA 自动注释引擎（参考 pLannotate 算法逻辑，基于 Libraries.sqlite）
/// 支持正反双链扫描、环形质粒跨零点 (Origin) 拼接匹配、以及 30%–90% 历史克隆残留片段 (Fragment) 标记
public struct PlasmidAnnotationEngine: Sendable {

    // MARK: - 1. 数据模型

    /// 离线 SQLite 标准质粒元件特征记录
    public struct PlasmidFeatureRecord: Identifiable, Sendable, Equatable, Codable {
        public let id: Int
        public let name: String
        public let category: String
        public let sequence: String
        public let direction: Int       // 1 = 正向, -1 = 反向, 0 = 无方向性
        public let colorHex: String
        public let sourceAccession: String?

        public init(
            id: Int,
            name: String,
            category: String,
            sequence: String,
            direction: Int = 1,
            colorHex: String = "#3B82F6",
            sourceAccession: String? = nil
        ) {
            self.id = id
            self.name = name
            self.category = category
            self.sequence = BioSequence.clean(sequence)
            self.direction = direction
            self.colorHex = colorHex
            self.sourceAccession = sourceAccession
        }
    }

    /// 单个自动注释命中结果
    public struct AnnotatedFeature: Identifiable, Sendable, Equatable, Codable {
        public var id: String { "\(name)_\(strand)_\(start1Based)_\(end1Based)" }
        public let featureID: Int
        public let name: String
        public let displayName: String
        public let category: String
        public let strand: String               // "+" 或 "-"
        public let canonicalDirection: Int      // 数据库原始 direction (1 / -1 / 0)
        public let start1Based: Int             // 质粒 1-based 起始坐标（跨零点时 start1Based > end1Based）
        public let end1Based: Int               // 质粒 1-based 终止坐标（含）
        public let matchedLength: Int           // 实际比对长度 (bp)
        public let referenceLength: Int         // 标准元件参考全长 (bp)
        public let featureStart1Based: Int      // 命中区域在参考元件自身 1-based 起点
        public let featureEnd1Based: Int        // 命中区域在参考元件自身 1-based 终点
        public let coverage: Double             // 长度覆盖率 (0.0 - 1.0)
        public let identity: Double             // 碱基一致率 (0.0 - 1.0)
        public let alignmentScore: Double       // 局部比对得分
        public let isOriginSpanning: Bool       // 是否跨越环形质粒 1 bp 零点
        public let isFragment: Bool             // 覆盖率在 30%–90% 之间的历史克隆残留片段标记
        public let fragmentWarning: String?     // 残留片段中文预警说明
        public let colorHex: String
        public let sourceAccession: String?

        /// 转换为可直接用于图谱渲染或写入 .dna 文件的 SnapGeneFeature（跨零点自动拆分为双 Segment）
        public func toSnapGeneFeature(plasmidLength: Int) -> SnapGeneFeature {
            let dirStr: String
            if canonicalDirection == 0 {
                dirStr = "0"
            } else {
                dirStr = (strand == "+") ? "1" : "2"
            }
            let segments: [SnapGeneSegment]
            if isOriginSpanning && start1Based > end1Based && plasmidLength > 0 {
                segments = [
                    SnapGeneSegment(
                        range: "\(start1Based)-\(plasmidLength)",
                        start: start1Based,
                        end: plasmidLength,
                        color: colorHex
                    ),
                    SnapGeneSegment(
                        range: "1-\(end1Based)",
                        start: 1,
                        end: end1Based,
                        color: colorHex
                    )
                ]
            } else {
                segments = [
                    SnapGeneSegment(
                        range: "\(start1Based)-\(end1Based)",
                        start: start1Based,
                        end: end1Based,
                        color: colorHex
                    )
                ]
            }
            return SnapGeneFeature(
                name: displayName,
                type: category,
                directionality: dirStr,
                segments: segments
            )
        }
    }

    /// 质粒自动注释完整报告
    public struct PlasmidAnnotationReport: Sendable, Equatable, Codable {
        public let plasmidName: String
        public let sequenceLength: Int
        public let isCircular: Bool
        public let featuresCount: Int
        public let fragmentCount: Int
        public let originSpanningCount: Int
        public let annotatedCoveragePercent: Double
        public let features: [AnnotatedFeature]
        public let warnings: [String]

        public func toSnapGeneFeatures() -> [SnapGeneFeature] {
            features.map { $0.toSnapGeneFeature(plasmidLength: sequenceLength) }
        }
    }

    // MARK: - 2. SQLite 特征库读取 & FASTA 解析

    private static let featureCacheLock = NSLock()
    nonisolated(unsafe) private static var cachedLibraryKey: String? = nil
    nonisolated(unsafe) private static var cachedLibraryRecords: [PlasmidFeatureRecord] = []

    /// 从 Libraries.sqlite 只读加载标准质粒元件表 `plasmid_features`（按路径与 mtime 缓存）
    public static func loadFeaturesFromSQLite(dbPath: String? = nil) -> [PlasmidFeatureRecord] {
        guard let resolvedPath = dbPath ?? CloneStudioResourceLocator.path(forResource: "Libraries", ofType: "sqlite") else {
            return []
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: resolvedPath)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cacheKey = "\(resolvedPath)#\(mtime)"
        featureCacheLock.lock()
        if cachedLibraryKey == cacheKey, !cachedLibraryRecords.isEmpty {
            let hit = cachedLibraryRecords
            featureCacheLock.unlock()
            return hit
        }
        featureCacheLock.unlock()

        var db: OpaquePointer? = nil
        guard sqlite3_open_v2(resolvedPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let openedDB = db else {
            if let db = db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(openedDB) }

        var hasSourceCol = false
        var pragmaStmt: OpaquePointer? = nil
        if sqlite3_prepare_v2(openedDB, "PRAGMA table_info(plasmid_features);", -1, &pragmaStmt, nil) == SQLITE_OK, let ps = pragmaStmt {
            while sqlite3_step(ps) == SQLITE_ROW {
                if let colC = sqlite3_column_text(ps, 1), String(cString: colC) == "source_accession" {
                    hasSourceCol = true
                }
            }
            sqlite3_finalize(ps)
        }
        let sql = hasSourceCol
            ? "SELECT id, name, category, sequence, direction, color_hex, source_accession FROM plasmid_features ORDER BY id ASC;"
            : "SELECT id, name, category, sequence, direction, color_hex FROM plasmid_features ORDER BY id ASC;"
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(openedDB, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            return []
        }
        defer { sqlite3_finalize(prepared) }

        var records: [PlasmidFeatureRecord] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(prepared, 0))
            guard let nameC = sqlite3_column_text(prepared, 1),
                  let catC = sqlite3_column_text(prepared, 2),
                  let seqC = sqlite3_column_text(prepared, 3),
                  let colorC = sqlite3_column_text(prepared, 5) else {
                continue
            }
            let dir = Int(sqlite3_column_int(prepared, 4))
            let srcAcc: String? = (hasSourceCol && sqlite3_column_type(prepared, 6) != SQLITE_NULL)
                ? sqlite3_column_text(prepared, 6).map { String(cString: $0) }
                : nil
            records.append(
                PlasmidFeatureRecord(
                    id: id,
                    name: String(cString: nameC),
                    category: String(cString: catC),
                    sequence: String(cString: seqC),
                    direction: dir,
                    colorHex: String(cString: colorC),
                    sourceAccession: srcAcc
                )
            )
        }
        if !records.isEmpty {
            featureCacheLock.lock()
            cachedLibraryKey = cacheKey
            cachedLibraryRecords = records
            featureCacheLock.unlock()
        }
        return records
    }

    /// 解析单条或多行 FASTA / 纯 DNA 文本，返回 (名称, 清洗后序列)
    public static func parseFASTA(
        _ rawText: String,
        defaultName: String = "Unannotated_Plasmid"
    ) -> (name: String, sequence: String) {
        let lines = rawText.components(separatedBy: .newlines)
        var parsedName = defaultName
        var foundHeader = false
        var bodyParts: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix(">") {
                if !foundHeader {
                    let hdr = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !hdr.isEmpty { parsedName = hdr }
                    foundHeader = true
                }
            } else {
                bodyParts.append(trimmed)
            }
        }
        return (parsedName, BioSequence.clean(bodyParts.joined()))
    }

    // MARK: - 3. 核心离线特征扫描算法 (双链 + 环形跨零点 + 30%–90% Fragment 预警)

    private struct CandidateHit {
        let feature: AnnotatedFeature
        let sStart0: Int
    }

    /// 基于本地 FASTA 文本执行质粒自动注释
    public static func annotateFASTA(
        _ fastaText: String,
        defaultName: String = "Unannotated_Plasmid",
        isCircular: Bool = true,
        featuresLibrary: [PlasmidFeatureRecord]? = nil,
        dbPath: String? = nil,
        minIdentity: Double = 0.85,
        minFragmentCoverage: Double = 0.30,
        fullFeatureCoverageThreshold: Double = 0.90
    ) -> PlasmidAnnotationReport {
        let (name, seq) = parseFASTA(fastaText, defaultName: defaultName)
        return annotate(
            sequence: seq,
            plasmidName: name,
            isCircular: isCircular,
            featuresLibrary: featuresLibrary,
            dbPath: dbPath,
            minIdentity: minIdentity,
            minFragmentCoverage: minFragmentCoverage,
            fullFeatureCoverageThreshold: fullFeatureCoverageThreshold
        )
    }

    /// 基于清洗后质粒 DNA 序列执行本地特征扫描与 pLannotate 风格贪心非重叠筛选
    public static func annotate(
        sequence: String,
        plasmidName: String = "Unannotated_Plasmid",
        isCircular: Bool = true,
        featuresLibrary: [PlasmidFeatureRecord]? = nil,
        dbPath: String? = nil,
        minIdentity: Double = 0.85,
        minFragmentCoverage: Double = 0.30,
        fullFeatureCoverageThreshold: Double = 0.90
    ) -> PlasmidAnnotationReport {
        let cleanQuery = BioSequence.clean(sequence)
        let queryLen = cleanQuery.count
        guard queryLen > 0 else {
            return PlasmidAnnotationReport(
                plasmidName: plasmidName,
                sequenceLength: 0,
                isCircular: isCircular,
                featuresCount: 0,
                fragmentCount: 0,
                originSpanningCount: 0,
                annotatedCoveragePercent: 0.0,
                features: [],
                warnings: [L10n.t("输入质粒序列为空")]
            )
        }

        let library = featuresLibrary ?? loadFeaturesFromSQLite(dbPath: dbPath)
        guard !library.isEmpty else {
            return PlasmidAnnotationReport(
                plasmidName: plasmidName,
                sequenceLength: queryLen,
                isCircular: isCircular,
                featuresCount: 0,
                fragmentCount: 0,
                originSpanningCount: 0,
                annotatedCoveragePercent: 0.0,
                features: [],
                warnings: [L10n.t("未能从 Libraries.sqlite 加载 plasmid_features 元件库")]
            )
        }

        let searchSeq = isCircular ? (cleanQuery + cleanQuery) : cleanQuery
        let searchBytes = Array(searchSeq.utf8)
        let searchLen = searchBytes.count

        @inline(__always)
        func baseCode(_ b: UInt8) -> Int {
            switch b {
            case 65: return 0 // 'A'
            case 67: return 1 // 'C'
            case 71: return 2 // 'G'
            case 84: return 3 // 'T'
            default: return -1
            }
        }

        // 按参考特征所需的不同 k 值按需缓存质粒 2-bit 滚动 UInt64 k-mer 倒排索引
        var searchKmerCache: [Int: [UInt64: [Int]]] = [:]
        func getSearchKmerIndex(k: Int) -> [UInt64: [Int]] {
            if let cached = searchKmerCache[k] {
                return cached
            }
            var index: [UInt64: [Int]] = [:]
            if searchLen >= k {
                index.reserveCapacity(searchLen)
                let mask: UInt64 = (UInt64(1) << (2 * k)) - 1
                var rolling: UInt64 = 0
                var validRun = 0
                for idx in 0..<searchLen {
                    let code = baseCode(searchBytes[idx])
                    if code < 0 {
                        rolling = 0
                        validRun = 0
                    } else {
                        rolling = ((rolling << 2) | UInt64(code)) & mask
                        validRun += 1
                        if validRun >= k {
                            index[rolling, default: []].append(idx - k + 1)
                        }
                    }
                }
            }
            searchKmerCache[k] = index
            return index
        }

        var candidates: [CandidateHit] = []

        for feat in library {
            let refFwd = BioSequence.clean(feat.sequence)
            let refLen = refFwd.count
            guard refLen > 0 else { continue }

            let k = min(12, max(6, refLen / 3))
            guard k <= refLen, searchLen >= k else { continue }

            let effectiveMinCov = (refLen < 40) ? fullFeatureCoverageThreshold : minFragmentCoverage
            let minAlignedLen = (refLen < 40) ? min(refLen, 15) : 20
            let sKmers = getSearchKmerIndex(k: k)
            let mask: UInt64 = (UInt64(1) << (2 * k)) - 1

            let refRev = BioSequence.reverseComplement(refFwd)
            let strands: [(strand: String, seq: String)] = [("+", refFwd), ("-", refRev)]

            for (strand, patternSeq) in strands {
                let pBytes = Array(patternSeq.utf8)

                var diagSet = Set<Int>()
                var pRolling: UInt64 = 0
                var pValidRun = 0
                for pIdx in 0..<refLen {
                    let code = baseCode(pBytes[pIdx])
                    if code < 0 {
                        pRolling = 0
                        pValidRun = 0
                    } else {
                        pRolling = ((pRolling << 2) | UInt64(code)) & mask
                        pValidRun += 1
                        if pValidRun >= k, let hits = sKmers[pRolling] {
                            let pPos = pIdx - k + 1
                            for sPos in hits {
                                let d = sPos - pPos
                                if d < queryLen && (d + refLen) > 0 {
                                    diagSet.insert(d)
                                }
                            }
                        }
                    }
                }
                guard !diagSet.isEmpty else { continue }

                for d in diagSet.sorted() {
                    let pLo = max(0, -d)
                    let pHi = min(refLen, searchLen - d)
                    guard pHi - pLo >= minAlignedLen else { continue }

                    // 1D Kadane 最大子数组局部比对 (+1 匹配, -3 错配)
                    var curScore = 0
                    var curStart = pLo
                    var bestScore = 0
                    var bestStart = pLo
                    var bestEnd = pLo

                    for p in pLo..<pHi {
                        let stepScore = (searchBytes[p + d] == pBytes[p]) ? 1 : -3
                        if curScore <= 0 {
                            curScore = stepScore
                            curStart = p
                        } else {
                            curScore += stepScore
                        }
                        if curScore > bestScore {
                            bestScore = curScore
                            bestStart = curStart
                            bestEnd = p + 1
                        }
                    }

                    let alignedLen = bestEnd - bestStart
                    guard alignedLen >= minAlignedLen, alignedLen <= queryLen else { continue }

                    let sStart = bestStart + d
                    let sEnd = bestEnd + d
                    if isCircular && sStart >= queryLen { continue }
                    if !isCircular && (sStart < 0 || sEnd > queryLen) { continue }

                    var matchCount = 0
                    for p in bestStart..<bestEnd where searchBytes[p + d] == pBytes[p] {
                        matchCount += 1
                    }

                    let identity = Double(matchCount) / Double(alignedLen)
                    let coverage = Double(alignedLen) / Double(refLen)
                    let isFragCandidate = coverage < fullFeatureCoverageThreshold
                    // 过滤 <21 bp 高频假阳性碎片，同时保留 >=18 bp 的完整全长短标签 (coverage >= 0.99)
                    if isFragCandidate && alignedLen < 21 { continue }
                    guard identity >= minIdentity, coverage >= effectiveMinCov else { continue }

                    let alignScore = Double(matchCount) * 2.0 - Double(alignedLen - matchCount) * 6.0
                    let start1 = (sStart % queryLen) + 1
                    let end1 = ((sEnd - 1) % queryLen) + 1
                    let originSpanning = isCircular && (sEnd > queryLen)

                    let featStart1 = (strand == "+") ? (bestStart + 1) : (refLen - bestEnd + 1)
                    let featEnd1 = (strand == "+") ? bestEnd : (refLen - bestStart)

                    let isFrag = (coverage >= minFragmentCoverage) && (coverage < fullFeatureCoverageThreshold)
                    let covPctRounded = Int(floor(coverage * 100.0 + 0.5))
                    let dispName = isFrag ? "\(feat.name) (fragment)" : feat.name
                    let fragWarn = isFrag ? L10n.tr("历史克隆残留片段 (Fragment，覆盖率 \(covPctRounded)%)", "Remnant cloning fragment (\(covPctRounded)% coverage)") : nil

                    let ann = AnnotatedFeature(
                        featureID: feat.id,
                        name: feat.name,
                        displayName: dispName,
                        category: feat.category,
                        strand: strand,
                        canonicalDirection: feat.direction,
                        start1Based: start1,
                        end1Based: end1,
                        matchedLength: alignedLen,
                        referenceLength: refLen,
                        featureStart1Based: featStart1,
                        featureEnd1Based: featEnd1,
                        coverage: coverage,
                        identity: identity,
                        alignmentScore: alignScore,
                        isOriginSpanning: originSpanning,
                        isFragment: isFrag,
                        fragmentWarning: fragWarn,
                        colorHex: feat.colorHex,
                        sourceAccession: feat.sourceAccession
                    )
                    candidates.append(CandidateHit(feature: ann, sStart0: sStart))
                }

                // 带状空位比对回退（容忍 1–6 bp 小 Indel 导致相邻对角线漂移的完整特征）
                let sortedDiags = diagSet.sorted()
                if sortedDiags.count >= 2 && refLen >= 40 && refLen <= 2500 {
                    var dClusters: [(minD: Int, maxD: Int)] = []
                    var cMin = sortedDiags[0], cMax = sortedDiags[0]
                    for d in sortedDiags.dropFirst() {
                        if d - cMax <= 6 {
                            cMax = d
                        } else {
                            if cMax > cMin { dClusters.append((cMin, cMax)) }
                            cMin = d; cMax = d
                        }
                    }
                    if cMax > cMin { dClusters.append((cMin, cMax)) }
                    for cl in dClusters where (cl.maxD - cl.minD) <= 8 {
                        let winStart = max(0, cl.minD)
                        let winEnd = min(searchLen, cl.maxD + refLen)
                        let qLenWin = winEnd - winStart
                        guard qLenWin >= minAlignedLen, qLenWin <= queryLen, abs(qLenWin - refLen) <= 10 else { continue }
                        if isCircular && winStart >= queryLen { continue }
                        if !isCircular && winEnd > queryLen { continue }
                        let band = 8
                        let m = refLen
                        let n = qLenWin
                        var prevRow = Array(repeating: -999999, count: n + 1)
                        var currRow = Array(repeating: -999999, count: n + 1)
                        for j in 0...min(n, band) { prevRow[j] = -4 * j }
                        for i in 1...m {
                            let jLo = max(0, i - band)
                            let jHi = min(n, i + band)
                            for j in jLo...jHi { currRow[j] = -999999 }
                            if jLo == 0 { currRow[0] = -4 * i }
                            for j in max(1, jLo)...jHi {
                                let sub = (pBytes[i - 1] == searchBytes[winStart + j - 1]) ? 2 : -4
                                var bestV = prevRow[j - 1] + sub
                                if j <= i - 1 + band { bestV = max(bestV, prevRow[j] - 4) }
                                if j - 1 >= jLo { bestV = max(bestV, currRow[j - 1] - 4) }
                                currRow[j] = bestV
                            }
                            swap(&prevRow, &currRow)
                        }
                        let gappedScore = prevRow[n]
                        let approxMatches = max(0, (gappedScore + 4 * abs(m - n)) / 2)
                        let approxId = min(1.0, Double(approxMatches) / Double(max(m, n)))
                        if approxId >= minIdentity && gappedScore > 0 {
                            let start1 = (winStart % queryLen) + 1
                            let end1 = ((winEnd - 1) % queryLen) + 1
                            let originSpanning = isCircular && (winEnd > queryLen)
                            let ann = AnnotatedFeature(
                                featureID: feat.id,
                                name: feat.name,
                                displayName: feat.name,
                                category: feat.category,
                                strand: strand,
                                canonicalDirection: feat.direction,
                                start1Based: start1,
                                end1Based: end1,
                                matchedLength: qLenWin,
                                referenceLength: refLen,
                                featureStart1Based: 1,
                                featureEnd1Based: refLen,
                                coverage: 1.0,
                                identity: approxId,
                                alignmentScore: Double(gappedScore),
                                isOriginSpanning: originSpanning,
                                isFragment: false,
                                fragmentWarning: nil,
                                colorHex: feat.colorHex,
                                sourceAccession: feat.sourceAccession
                            )
                            candidates.append(CandidateHit(feature: ann, sStart0: winStart))
                        }
                    }
                }
            }
        }

        // pLannotate 风格 6 框蛋白翻译同源检索（必须在 candidates.sort 之前汇入，确保完整 6 框蛋白命中优先于短 DNA 碎片）
        let codingCategories: Set<String> = ["CDS", "reporter", "resistance", "tag"]
        let searchFwd = searchSeq
        let searchRev = BioSequence.reverseComplement(searchSeq)
        var translatedFrames: [(strand: String, frame: Int, aa: [Character])] = []
        for frame in 0..<3 {
            let fwdAA = Array(CodonOptimizationEngine.translateDNA(String(searchFwd.dropFirst(frame))))
            let revAA = Array(CodonOptimizationEngine.translateDNA(String(searchRev.dropFirst(frame))))
            translatedFrames.append(("+", frame, fwdAA))
            translatedFrames.append(("-", frame, revAA))
        }
        let aaSeedLen = 5
        var aaFrameIndex: [[String: [Int]]] = Array(repeating: [:], count: translatedFrames.count)
        for (fIdx, fr) in translatedFrames.enumerated() where fr.aa.count >= aaSeedLen {
            for p in 0...(fr.aa.count - aaSeedLen) {
                let seed = String(fr.aa[p..<(p + aaSeedLen)])
                if seed.contains("*") || seed.contains("X") { continue }
                aaFrameIndex[fIdx][seed, default: []].append(p)
            }
        }
        for feat in library where codingCategories.contains(feat.category) {
            let refClean = BioSequence.clean(feat.sequence)
            guard refClean.count >= 150 && refClean.count % 3 == 0 else { continue }
            let rawRefAA = Array(CodonOptimizationEngine.translateDNA(refClean))
            let refAA = rawRefAA.last == "*" ? Array(rawRefAA.dropLast()) : rawRefAA
            let refAALen = refAA.count
            guard refAALen >= 50 else { continue }
            let probeOffsets = [0, refAALen / 4, refAALen / 2, (3 * refAALen) / 4].filter { $0 + aaSeedLen <= refAALen }
            for (fIdx, fr) in translatedFrames.enumerated() {
                var diagAA = Set<Int>()
                for off in probeOffsets {
                    let seed = String(refAA[off..<(off + aaSeedLen)])
                    if let hits = aaFrameIndex[fIdx][seed] {
                        for h in hits { diagAA.insert(h - off) }
                    }
                }
                for dAA in diagAA.sorted() {
                    guard dAA >= 0 && dAA + refAALen <= fr.aa.count else { continue }
                    var aaMatch = 0
                    for k in 0..<refAALen where fr.aa[dAA + k] == refAA[k] { aaMatch += 1 }
                    let aaId = Double(aaMatch) / Double(refAALen)
                    guard aaId >= 0.85 else { continue }
                    let dnaStartInOriented = fr.frame + dAA * 3
                    let dnaLen = refAALen * 3
                    let sStart0: Int
                    if fr.strand == "+" {
                        sStart0 = dnaStartInOriented
                    } else {
                        sStart0 = searchLen - (dnaStartInOriented + dnaLen)
                    }
                    guard sStart0 >= 0 && sStart0 < queryLen else { continue }
                    if !isCircular && (sStart0 + dnaLen) > queryLen { continue }
                    let sEnd0 = sStart0 + dnaLen
                    let wrapsOrigin = isCircular && sEnd0 > queryLen
                    let start1 = sStart0 + 1
                    let end1 = wrapsOrigin ? ((sEnd0 - 1) % queryLen) + 1 : sEnd0
                    let af = AnnotatedFeature(
                        featureID: feat.id,
                        name: feat.name,
                        displayName: "\(feat.name) (protein match)",
                        category: feat.category,
                        strand: fr.strand,
                        canonicalDirection: feat.direction,
                        start1Based: start1,
                        end1Based: end1,
                        matchedLength: dnaLen,
                        referenceLength: refClean.count,
                        featureStart1Based: 1,
                        featureEnd1Based: dnaLen,
                        coverage: Double(dnaLen) / Double(refClean.count),
                        identity: aaId,
                        alignmentScore: Double(dnaLen) * aaId * 1.8,
                        isOriginSpanning: wrapsOrigin,
                        isFragment: false,
                        fragmentWarning: nil,
                        colorHex: feat.colorHex,
                        sourceAccession: feat.sourceAccession
                    )
                    candidates.append(CandidateHit(feature: af, sStart0: sStart0))
                }
            }
        }

        // 确定性排序：按比对得分降序 -> 一致率 -> 覆盖率 -> 匹配长度 -> 坐标升序 -> 名称 -> 链向
        candidates.sort { lhs, rhs in
            let a = lhs.feature
            let b = rhs.feature
            if abs(a.alignmentScore - b.alignmentScore) > 1e-9 {
                return a.alignmentScore > b.alignmentScore
            }
            if abs(a.identity - b.identity) > 1e-9 {
                return a.identity > b.identity
            }
            if abs(a.coverage - b.coverage) > 1e-9 {
                return a.coverage > b.coverage
            }
            if a.matchedLength != b.matchedLength {
                return a.matchedLength > b.matchedLength
            }
            if a.start1Based != b.start1Based {
                return a.start1Based < b.start1Based
            }
            if a.name != b.name {
                return a.name < b.name
            }
            return a.strand < b.strand
        }

        // 按链方向与功能层（regulatory / coding / replication / tag / recombinase / misc）分桶贪心非重叠抑制
        func featureLayer(_ category: String) -> String {
            switch category.lowercased() {
            case "promoter", "terminator", "enhancer", "polya", "regulator", "regulatory": return "regulatory"
            case "ori", "origin", "replication": return "replication"
            case "tag": return "tag"
            case "recombinase": return "recombinase"
            case "misc": return "misc"
            default: return "coding"
            }
        }
        var occupiedByBucket: [String: [Bool]] = [:]
        var unionOccupied = Array(repeating: false, count: queryLen)
        var accepted: [AnnotatedFeature] = []

        for cand in candidates {
            let f = cand.feature
            let layer = featureLayer(f.category)
            let bucketKey = (layer == "replication") ? "replication" : "\(f.strand):\(layer)"
            var occ = occupiedByBucket[bucketKey] ?? Array(repeating: false, count: queryLen)
            var alreadyOccupied = 0
            for offset in 0..<f.matchedLength {
                let pos = (cand.sStart0 + offset) % queryLen
                // 碎片命中 (isFragment) 不得叠加于任何已注释完整元件之上；完整全长特征按链与功能层独立判断
                if f.isFragment ? unionOccupied[pos] : occ[pos] {
                    alreadyOccupied += 1
                }
            }
            let overlapFrac = Double(alreadyOccupied) / Double(f.matchedLength)
            if overlapFrac <= 0.15 {
                accepted.append(f)
                for offset in 0..<f.matchedLength {
                    let pos = (cand.sStart0 + offset) % queryLen
                    occ[pos] = true
                    unionOccupied[pos] = true
                }
                occupiedByBucket[bucketKey] = occ
            }
        }

        accepted.sort {
            if $0.start1Based != $1.start1Based { return $0.start1Based < $1.start1Based }
            if $0.end1Based != $1.end1Based { return $0.end1Based < $1.end1Based }
            return $0.name < $1.name
        }

        let fragCount = accepted.filter(\.isFragment).count
        let originCount = accepted.filter(\.isOriginSpanning).count
        let coveredBases = unionOccupied.filter { $0 }.count
        let covPercent = (Double(coveredBases) * 100.0 / Double(queryLen))

        var warnings: [String] = []
        if fragCount > 0 {
            warnings.append(L10n.tr("检出 \(fragCount) 个历史克隆残留片段 (Fragment，覆盖率 30%–90%)，请核查载体改造史。", "Detected \(fragCount) remnant fragment(s) (30%–90% coverage); review construct history."))
        }
        if originCount > 0 {
            warnings.append(L10n.tr("检出 \(originCount) 个跨越环形质粒 1 bp 零点 (Origin) 的连续特征。", "Detected \(originCount) Origin-spanning feature(s) across 1 bp."))
        }

        return PlasmidAnnotationReport(
            plasmidName: plasmidName,
            sequenceLength: queryLen,
            isCircular: isCircular,
            featuresCount: accepted.count,
            fragmentCount: fragCount,
            originSpanningCount: originCount,
            annotatedCoveragePercent: covPercent,
            features: accepted,
            warnings: warnings
        )
    }
}
