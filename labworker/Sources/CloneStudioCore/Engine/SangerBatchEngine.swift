import Foundation

/// Sanger 批量测序验证、正反向 Reads 自动归并、覆盖度汇总与克隆级筛选看板引擎 (P11)
public enum SangerBatchEngine {

    // MARK: - 1. 数据模型

    public struct SangerReferenceCandidate: Sendable, Equatable, Hashable {
        public let id: String
        public let name: String
        public let sequence: String
        public let cdsStart1Based: Int?
        public let targetStart1Based: Int
        public let targetEnd1Based: Int
        public let hasExplicitTargetRegion: Bool
        public let plasmidID: String?

        public init(
            id: String? = nil,
            name: String,
            sequence: String,
            cdsStart1Based: Int? = nil,
            targetStart1Based: Int? = nil,
            targetEnd1Based: Int? = nil,
            plasmidID: String? = nil
        ) {
            let clean = BioSequence.clean(sequence)
            self.id = id ?? plasmidID ?? name
            self.name = name
            self.sequence = clean
            self.cdsStart1Based = cdsStart1Based
            self.hasExplicitTargetRegion = (targetStart1Based != nil || targetEnd1Based != nil)
            let s1 = max(1, min(max(1, clean.count), targetStart1Based ?? 1))
            let e1 = max(s1, min(max(1, clean.count), targetEnd1Based ?? clean.count))
            self.targetStart1Based = s1
            self.targetEnd1Based = e1
            self.plasmidID = plasmidID ?? id
        }
    }

    public enum CloneBatchVerdict: String, CaseIterable, Identifiable, Codable, Sendable {
        case pass = "通过"
        case needsReview = "需复核"
        case failed = "失败"
        case unmatched = "未匹配"

        public var id: String { rawValue }

        /// 看板筛选分类归属（全部 / 通过 / 复核 / 失败，未匹配归入失败或复核筛选桶）
        public var matchesFailedBucket: Bool {
            self == .failed || self == .unmatched
        }
    }

    public struct BatchReadItem: Identifiable, Sendable, Equatable {
        public let id: String
        public let fileURL: URL
        public let sampleName: String
        public let cloneName: String
        public let primerSuffix: String?
        public let matchedReferenceName: String?
        public let matchStrategy: String
        public let report: SangerAlignmentEngine.VerificationReport
        public let isMatched: Bool

        public var fileName: String { sampleName }
    }

    public struct CloneBatchSummary: Identifiable, Sendable, Equatable {
        public var id: String { cloneName }
        public let cloneName: String
        public let matchedReferenceName: String?
        public let matchedPlasmidID: String?
        public let reads: [BatchReadItem]
        public let targetRegionStart1Based: Int
        public let targetRegionEnd1Based: Int
        public let coveredBasesCount: Int
        public let targetRegionLength: Int
        public let coveragePercent: Double
        public let minRequiredCoveragePercent: Double
        public let minIdentityPercent: Double
        public let meanIdentityPercent: Double
        public let mergedVariants: [SangerAlignmentEngine.VariantCall]
        public let verdict: CloneBatchVerdict

        public var readCount: Int { reads.count }
        public var referenceName: String { matchedReferenceName ?? L10n.t("未匹配") }
        public var coveredBp: Int { coveredBasesCount }
        public var referenceLengthBp: Int { targetRegionLength }
        public var snpCount: Int { mergedVariants.filter { $0.kind == .mismatchSNP }.count }
        public var indelCount: Int { mergedVariants.filter { $0.kind == .insertion || $0.kind == .deletion }.count }
        public var doublePeakCount: Int { mergedVariants.filter { $0.kind == .doublePeak }.count }

        public var variantsSummaryText: String {
            if verdict == .unmatched { return L10n.t("未匹配参考质粒") }
            if mergedVariants.isEmpty {
                if verdict == .needsReview && coveragePercent < minRequiredCoveragePercent {
                    return L10n.tr(
                        "Q20 覆盖度不足 (\(String(format: "%.1f%%", coveragePercent)) < \(String(format: "%.0f%%", minRequiredCoveragePercent)))，需补测",
                        "Insufficient Q20 coverage (\(String(format: "%.1f%%", coveragePercent)) < \(String(format: "%.0f%%", minRequiredCoveragePercent))); re-sequence"
                    )
                }
                return L10n.t("无变异 (WT)")
            }
            return mergedVariants.map { "\($0.hgvsNotation)(\($0.kind.rawValue))" }.joined(separator: "; ")
        }
    }

    public struct BatchVerificationResult: Sendable, Equatable {
        public let readItems: [BatchReadItem]
        public let cloneSummaries: [CloneBatchSummary]
        public let wasCancelled: Bool

        public var reads: [BatchReadItem] { readItems }

        public init(readItems: [BatchReadItem], cloneSummaries: [CloneBatchSummary], wasCancelled: Bool = false) {
            self.readItems = readItems
            self.cloneSummaries = cloneSummaries
            self.wasCancelled = wasCancelled
        }

        public init(reads: [BatchReadItem], cloneSummaries: [CloneBatchSummary], wasCancelled: Bool = false) {
            self.readItems = reads
            self.cloneSummaries = cloneSummaries
            self.wasCancelled = wasCancelled
        }
    }

    /// 默认克隆正反向引物后缀剥离正则（可在系统设置中自定义）
    public static let defaultPrimerSuffixRegex: String =
        #"(?i)[-_](F|R|FWD|REV|Forward|Reverse|T7|T7term|SP6|M13F|M13R|BGH|BGHrev|CMV|U6|pGEX\d*|seq\d*|\d+F|\d+R)$"#

    // MARK: - 2. 文件夹递归扫描与样品克隆名前缀提取

    /// 展开文件或文件夹 URL 列表，收集所有合法的 Sanger 测序文件 (.ab1 / .abi / .seq / .fa / .fasta / .txt)
    public static func expandInputURLs(_ urls: [URL]) -> [URL] {
        let validExts: Set<String> = ["ab1", "abi", "seq", "fa", "fasta", "txt"]
        let fm = FileManager.default
        var collected: [URL] = []
        var seenPaths = Set<String>()

        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let enumerator = fm.enumerator(
                    at: u,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let childURL as URL in enumerator {
                        let ext = childURL.pathExtension.lowercased()
                        if validExts.contains(ext) && !seenPaths.contains(childURL.path) {
                            seenPaths.insert(childURL.path)
                            collected.append(childURL)
                        }
                    }
                }
            } else {
                let ext = u.pathExtension.lowercased()
                if validExts.contains(ext) && !seenPaths.contains(u.path) {
                    seenPaths.insert(u.path)
                    collected.append(u)
                }
            }
        }
        return collected.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func extractCloneAndPrimer(
        fromSampleName sampleName: String,
        suffixRegexPattern: String = defaultPrimerSuffixRegex
    ) -> (cloneName: String, primerSuffix: String?) {
        let base = (sampleName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return ("Clone", nil) }
        if let regex = try? NSRegularExpression(pattern: suffixRegexPattern) {
            let nsBase = base as NSString
            let range = NSRange(location: 0, length: nsBase.length)
            if let match = regex.firstMatch(in: base, options: [], range: range) {
                let rawMatched = nsBase.substring(with: match.range)
                let primer = rawMatched.trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
                let prefix = nsBase.substring(to: match.range.location)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
                if !prefix.isEmpty {
                    return (prefix, primer.isEmpty ? nil : primer)
                }
            }
        }
        return (base, nil)
    }

    public static func extractCloneName(
        fromSampleName sampleName: String,
        suffixRegexPattern: String = defaultPrimerSuffixRegex
    ) -> String {
        extractCloneAndPrimer(fromSampleName: sampleName, suffixRegexPattern: suffixRegexPattern).cloneName
    }

    /// 计算单条测序读长与参考序列的双链最大 k-mer 种子命中数
    public static func maxKmerSeedHits(readSeq: String, refSeq: String, k: Int = 9) -> Int {
        let q = BioSequence.clean(readSeq)
        let r = BioSequence.clean(refSeq)
        guard q.count >= k, r.count >= k else { return 0 }
        let doubledRef = r + r
        let refLen = r.count

        func hitsOnStrand(_ s: String) -> Int {
            let chars = Array(s)
            let step = max(1, (chars.count - k) / 24)
            var bucketVotes: [Int: Int] = [:]
            var idx = 0
            while idx <= chars.count - k {
                let kmer = String(chars[idx..<(idx + k)])
                var searchRange = doubledRef.startIndex..<doubledRef.endIndex
                while let found = doubledRef.range(of: kmer, options: [], range: searchRange) {
                    let pos0 = doubledRef.distance(from: doubledRef.startIndex, to: found.lowerBound)
                    let diag = pos0 - idx
                    if diag >= 0 && diag < refLen {
                        let bucket = (diag / 8) * 8
                        bucketVotes[bucket, default: 0] += 1
                    }
                    let nextStart = doubledRef.index(after: found.lowerBound)
                    if nextStart >= doubledRef.endIndex { break }
                    searchRange = nextStart..<doubledRef.endIndex
                }
                idx += step
            }
            return bucketVotes.values.max() ?? 0
        }

        return max(hitsOnStrand(q), hitsOnStrand(BioSequence.reverseComplement(q)))
    }

    /// 三级参考匹配策略：① 文件名/样品名匹配；② k-mer 种子投票最高者；③ 低于阈值标记未匹配
    public static func matchBestReference(
        sampleName: String,
        trimmedReadSequence: String,
        candidates: [SangerReferenceCandidate],
        minSeedHitsThreshold: Int = 3
    ) -> (candidate: SangerReferenceCandidate, strategy: String)? {
        guard !candidates.isEmpty else { return nil }
        let lowSample = sampleName.lowercased()

        // 策略 ①：文件名包含质粒名或主要基因标识（长度 >= 3）
        for cand in candidates {
            let cleanName = cand.name.lowercased()
            if !cleanName.isEmpty && lowSample.contains(cleanName) {
                let hits = maxKmerSeedHits(readSeq: trimmedReadSequence, refSeq: cand.sequence)
                if hits >= minSeedHitsThreshold {
                    return (cand, "filename_match")
                }
            }
            let tokens = cand.name
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 }
            if tokens.contains(where: { lowSample.contains($0.lowercased()) }) {
                let hits = maxKmerSeedHits(readSeq: trimmedReadSequence, refSeq: cand.sequence)
                if hits >= minSeedHitsThreshold {
                    return (cand, "filename_token_match")
                }
            }
        }

        // 策略 ②：对所有候选参考跑 k-mer 种子，取命中数最高者
        var bestCand: SangerReferenceCandidate? = nil
        var bestHits = 0
        for cand in candidates {
            let hits = maxKmerSeedHits(readSeq: trimmedReadSequence, refSeq: cand.sequence)
            if hits > bestHits {
                bestHits = hits
                bestCand = cand
            }
        }

        // 策略 ③：最高命中低于阈值则标记“未匹配”
        if let chosen = bestCand, bestHits >= minSeedHitsThreshold {
            return (chosen, "kmer_seed(\(bestHits))")
        }
        return nil
    }

    // MARK: - 3. 并发批量比对与克隆级覆盖度/判定归并 (withTaskGroup, 并发上限 4)

    public static func verifyBatch(
        urls: [URL],
        candidates: [SangerReferenceCandidate],
        primerSuffixRegex: String = defaultPrimerSuffixRegex,
        trimQualityThreshold: Int = 20,
        maxConcurrency: Int = 4,
        minPassCoveragePercent: Double? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> BatchVerificationResult {
        await verifyBatch(
            files: urls,
            candidates: candidates,
            suffixRegexPattern: primerSuffixRegex,
            trimQualityThreshold: trimQualityThreshold,
            maxConcurrency: maxConcurrency,
            minPassCoveragePercent: minPassCoveragePercent,
            onProgress: onProgress
        )
    }

    public static func verifyBatch(
        files: [URL],
        references: [(name: String, seq: String, cdsStart: Int?)],
        suffixRegexPattern: String = defaultPrimerSuffixRegex,
        trimQualityThreshold: Int = 20,
        maxConcurrency: Int = 4,
        minPassCoveragePercent: Double? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> BatchVerificationResult {
        let structCandidates = references.map {
            SangerReferenceCandidate(name: $0.name, sequence: $0.seq, cdsStart1Based: $0.cdsStart)
        }
        return await verifyBatch(
            files: files,
            candidates: structCandidates,
            suffixRegexPattern: suffixRegexPattern,
            trimQualityThreshold: trimQualityThreshold,
            maxConcurrency: maxConcurrency,
            minPassCoveragePercent: minPassCoveragePercent,
            onProgress: onProgress
        )
    }

    public static func verifyBatch(
        files: [URL],
        candidates: [SangerReferenceCandidate],
        suffixRegexPattern: String = defaultPrimerSuffixRegex,
        trimQualityThreshold: Int = 20,
        maxConcurrency: Int = 4,
        minPassCoveragePercent: Double? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> BatchVerificationResult {
        let total = files.count
        guard total > 0 else {
            return BatchVerificationResult(readItems: [], cloneSummaries: [], wasCancelled: false)
        }

        let concurrencyLimit = max(1, min(4, maxConcurrency))
        var orderedResults: [Int: BatchReadItem] = [:]
        var completedCount = 0
        var cancelled = false

        await withTaskGroup(of: (Int, BatchReadItem)?.self) { group in
            var nextIndex = 0

            func spawnNext() {
                guard nextIndex < total, !Task.isCancelled else { return }
                let idx = nextIndex
                let fileURL = files[idx]
                nextIndex += 1
                group.addTask {
                    if Task.isCancelled { return nil }
                    let item = evaluateSingleFile(
                        fileURL: fileURL,
                        index: idx,
                        candidates: candidates,
                        suffixRegexPattern: suffixRegexPattern,
                        trimQualityThreshold: trimQualityThreshold
                    )
                    if Task.isCancelled { return nil }
                    return (idx, item)
                }
            }

            for _ in 0..<min(concurrencyLimit, total) {
                spawnNext()
            }

            while let res = await group.next() {
                if Task.isCancelled {
                    cancelled = true
                    group.cancelAll()
                    break
                }
                if let (idx, item) = res {
                    orderedResults[idx] = item
                    completedCount += 1
                    onProgress?(completedCount, total)
                }
                spawnNext()
            }
        }

        if Task.isCancelled {
            cancelled = true
        }

        let readItems = orderedResults.keys.sorted().compactMap { orderedResults[$0] }
        let cloneSummaries = summarizeByClone(readItems: readItems, candidates: candidates, minPassCoveragePercent: minPassCoveragePercent)
        return BatchVerificationResult(
            readItems: readItems,
            cloneSummaries: cloneSummaries,
            wasCancelled: cancelled
        )
    }

    public static func verifyInMemoryRead(
        data: Data,
        fileName: String,
        index: Int,
        candidates: [SangerReferenceCandidate],
        primerSuffixRegex: String = defaultPrimerSuffixRegex,
        trimQualityThreshold: Int = 20
    ) -> BatchReadItem {
        let chrom = SangerAlignmentEngine.parseData(data, sampleName: fileName, trimQualityThreshold: trimQualityThreshold)
        let dummyURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        return evaluateChromatogram(
            chrom: chrom,
            fileURL: dummyURL,
            index: index,
            candidates: candidates,
            suffixRegexPattern: primerSuffixRegex
        )
    }

    private static func evaluateSingleFile(
        fileURL: URL,
        index: Int,
        candidates: [SangerReferenceCandidate],
        suffixRegexPattern: String,
        trimQualityThreshold: Int
    ) -> BatchReadItem {
        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        let chrom = (try? SangerAlignmentEngine.parseFile(at: fileURL, trimQualityThreshold: trimQualityThreshold))
            ?? SangerAlignmentEngine.parseData(Data(), sampleName: fallbackName, filePath: fileURL.path, trimQualityThreshold: trimQualityThreshold)
        return evaluateChromatogram(
            chrom: chrom,
            fileURL: fileURL,
            index: index,
            candidates: candidates,
            suffixRegexPattern: suffixRegexPattern
        )
    }

    private static func evaluateChromatogram(
        chrom: SangerAlignmentEngine.ChromatogramRecord,
        fileURL: URL,
        index: Int,
        candidates: [SangerReferenceCandidate],
        suffixRegexPattern: String
    ) -> BatchReadItem {
        let namingSource = fileURL.lastPathComponent.isEmpty ? chrom.sampleName : fileURL.lastPathComponent
        let (cloneName, primerSuf) = extractCloneAndPrimer(fromSampleName: namingSource, suffixRegexPattern: suffixRegexPattern)

        guard let matched = matchBestReference(
            sampleName: namingSource,
            trimmedReadSequence: chrom.trimmedSequence,
            candidates: candidates
        ) else {
            let unalignedRep = SangerAlignmentEngine.VerificationReport(
                chromatogram: chrom,
                referenceName: L10n.t("未匹配"),
                referenceLength: 0,
                isReverseComplement: false,
                matchedRefStart1Based: 1,
                matchedRefEnd1Based: 1,
                alignedLength: 0,
                matchCount: 0,
                mismatchCount: 0,
                insertionCount: 0,
                deletionCount: 0,
                doublePeakCount: 0,
                identityPercent: 0.0,
                verdict: .unaligned,
                summaryNotes: [L10n.t("未能在候选参考质粒集中找到匹配的同源序列。")],
                columns: [],
                variants: []
            )
            return BatchReadItem(
                id: "\(index)_\(fileURL.lastPathComponent)",
                fileURL: fileURL,
                sampleName: chrom.sampleName,
                cloneName: cloneName,
                primerSuffix: primerSuf,
                matchedReferenceName: nil,
                matchStrategy: "unmatched",
                report: unalignedRep,
                isMatched: false
            )
        }

        let rep = SangerAlignmentEngine.verifyAgainstPlasmid(
            chromatogram: chrom,
            referenceSequence: matched.candidate.sequence,
            referenceName: matched.candidate.name,
            cdsStart1Based: matched.candidate.cdsStart1Based
        )

        if rep.verdict == .unaligned || rep.alignedLength < 20 || rep.identityPercent < 65.0 {
            return BatchReadItem(
                id: "\(index)_\(fileURL.lastPathComponent)",
                fileURL: fileURL,
                sampleName: chrom.sampleName,
                cloneName: cloneName,
                primerSuffix: primerSuf,
                matchedReferenceName: nil,
                matchStrategy: "unmatched",
                report: rep,
                isMatched: false
            )
        }

        return BatchReadItem(
            id: "\(index)_\(fileURL.lastPathComponent)",
            fileURL: fileURL,
            sampleName: chrom.sampleName,
            cloneName: cloneName,
            primerSuffix: primerSuf,
            matchedReferenceName: matched.candidate.name,
            matchStrategy: matched.strategy,
            report: rep,
            isMatched: true
        )
    }

    public static func summarizeByClone(
        reads: [BatchReadItem],
        candidates: [SangerReferenceCandidate],
        minPassCoveragePercent: Double? = nil
    ) -> [CloneBatchSummary] {
        summarizeByClone(readItems: reads, candidates: candidates, minPassCoveragePercent: minPassCoveragePercent)
    }

    /// 将单条测序结果按 cloneName 归并为克隆级汇总
    public static func summarizeByClone(
        readItems: [BatchReadItem],
        candidates: [SangerReferenceCandidate],
        minPassCoveragePercent: Double? = nil
    ) -> [CloneBatchSummary] {
        var cloneOrder: [String] = []
        var grouped: [String: [BatchReadItem]] = [:]
        for item in readItems {
            if grouped[item.cloneName] == nil {
                cloneOrder.append(item.cloneName)
            }
            grouped[item.cloneName, default: []].append(item)
        }

        var candidateMap: [String: SangerReferenceCandidate] = [:]
        for c in candidates {
            candidateMap[c.name] = c
        }

        var summaries: [CloneBatchSummary] = []
        for cName in cloneOrder {
            let items = grouped[cName] ?? []
            guard !items.isEmpty else { continue }

            let matchedItems = items.filter(\.isMatched)
            guard let primaryRefName = matchedItems.first?.matchedReferenceName,
                  let refCand = candidateMap[primaryRefName] else {
                summaries.append(
                    CloneBatchSummary(
                        cloneName: cName,
                        matchedReferenceName: nil,
                        matchedPlasmidID: nil,
                        reads: items,
                        targetRegionStart1Based: 1,
                        targetRegionEnd1Based: 1,
                        coveredBasesCount: 0,
                        targetRegionLength: 1,
                        coveragePercent: 0.0,
                        minRequiredCoveragePercent: minPassCoveragePercent ?? 70.0,
                        minIdentityPercent: 0.0,
                        meanIdentityPercent: 0.0,
                        mergedVariants: [],
                        verdict: .unmatched
                    )
                )
                continue
            }

            // 计算该克隆所有已匹配 reads 覆盖的参考坐标集合与变异并集
            var coveredRefPositions = Set<Int>()
            var highQualityCoveredPositions = Set<Int>()
            var variantMap: [String: SangerAlignmentEngine.VariantCall] = [:]
            var variantOrder: [String] = []

            for rItem in matchedItems where rItem.matchedReferenceName == primaryRefName {
                for col in rItem.report.columns where col.eventKind != .insertion {
                    coveredRefPositions.insert(col.refPos1Based)
                    if col.phredQuality >= 20 && col.eventKind != .deletion {
                        highQualityCoveredPositions.insert(col.refPos1Based)
                    }
                }
                for v in rItem.report.variants {
                    let vKey = "\(v.refPos1Based)_\(v.kind.rawValue)"
                    if variantMap[vKey] == nil {
                        variantMap[vKey] = v
                        variantOrder.append(vKey)
                    }
                }
            }

            let targetStart = refCand.targetStart1Based
            let targetEnd = refCand.targetEnd1Based
            let targetSet = Set(targetStart...max(targetStart, targetEnd))
            let targetLen = max(1, targetSet.count)
            let coveredInTarget = targetSet.intersection(highQualityCoveredPositions).count
            let coveragePct = min(100.0, Double(coveredInTarget) * 100.0 / Double(targetLen))
            let minIdentity = matchedItems.map { $0.report.identityPercent }.min() ?? 0.0
            let meanIdentity = matchedItems.map { $0.report.identityPercent }.reduce(0.0, +) / Double(max(1, matchedItems.count))
            let mergedVars = variantOrder.compactMap { variantMap[$0] }

            let hasAllReadsMatched = (matchedItems.count == items.count)
            let hasFrameshiftOrIndel = mergedVars.contains { $0.kind == .insertion || $0.kind == .deletion }
            let hasSNP = mergedVars.contains { $0.kind == .mismatchSNP }
            let hasDoublePeak = mergedVars.contains { $0.kind == .doublePeak }
            // Ewing & Green (1998) Phred Q20: 未覆盖目标区域禁止直接放行通过
            let requiredCov = minPassCoveragePercent.map { max(0.0, min(100.0, $0)) } ?? (refCand.hasExplicitTargetRegion ? 95.0 : 70.0)
            let hasSufficientCoverage = coveragePct >= requiredCov

            let verdict: CloneBatchVerdict
            if !hasAllReadsMatched || hasFrameshiftOrIndel || hasSNP {
                verdict = .failed
            } else if hasDoublePeak || !hasSufficientCoverage {
                verdict = .needsReview
            } else {
                verdict = .pass
            }

            summaries.append(
                CloneBatchSummary(
                    cloneName: cName,
                    matchedReferenceName: primaryRefName,
                    matchedPlasmidID: refCand.plasmidID,
                    reads: items,
                    targetRegionStart1Based: targetStart,
                    targetRegionEnd1Based: targetEnd,
                    coveredBasesCount: coveredInTarget,
                    targetRegionLength: targetLen,
                    coveragePercent: coveragePct,
                    minRequiredCoveragePercent: requiredCov,
                    minIdentityPercent: minIdentity,
                    meanIdentityPercent: meanIdentity,
                    mergedVariants: mergedVars,
                    verdict: verdict
                )
            )
        }
        return summaries
    }

    // MARK: - 4. 导出 batch_summary.csv 与 AnalysisRun (.run.json) 溯源伴随文件

    public static func exportBatchSummaryCSV(_ result: BatchVerificationResult) -> String {
        exportBatchSummaryCSV(result.cloneSummaries)
    }

    public static func exportBatchSummaryCSV(_ summaries: [CloneBatchSummary]) -> String {
        var lines = ["Clone,Reads_Count,Read_Files,Reference,Coverage_Pct,Min_Identity_Pct,Variants,Verdict"]
        for s in summaries {
            let readNames = s.reads.map(\.sampleName).joined(separator: ";")
            let refName = s.matchedReferenceName ?? "Unmatched"
            let covStr = String(format: "%.1f", s.coveragePercent)
            let idStr = String(format: "%.1f", s.minIdentityPercent)
            let varStr = s.variantsSummaryText.replacingOccurrences(of: ",", with: ";")
            lines.append("\(s.cloneName),\(s.readCount),\(readNames),\(refName),\(covStr),\(idStr),\(varStr),\(s.verdict.rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    public static func buildBatchAnalysisRun(
        batchResult: BatchVerificationResult,
        candidates: [SangerReferenceCandidate] = [],
        trimQualityThreshold: Int = 20,
        primerSuffixRegex: String = defaultPrimerSuffixRegex,
        outputs: [String] = [],
        exportDirectoryURL: URL? = nil,
        linkedPlasmidIDs: [String]? = nil
    ) -> AnalysisRun {
        let inputs: [AnalysisRun.InputFile] = batchResult.readItems.compactMap { item in
            AnalysisRun.makeInputFile(at: item.fileURL, relativeTo: exportDirectoryURL)
        }
        let refHashes: [String: AnyCodableValue] = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.name, .string(AnalysisRun.sha256Hex(ofString: $0.sequence))) }
        )
        let autoLinked = batchResult.cloneSummaries.compactMap(\.matchedPlasmidID)
        let resolvedLinked = linkedPlasmidIDs ?? Array(Set(autoLinked)).sorted()
        let params: [String: AnyCodableValue] = [
            "mode": .string("batch"),
            "totalReadFiles": .int(batchResult.readItems.count),
            "cloneCount": .int(batchResult.cloneSummaries.count),
            "totalClones": .int(batchResult.cloneSummaries.count),
            "trimQualityThreshold": .int(trimQualityThreshold),
            "suffixRegexPattern": .string(primerSuffixRegex),
            "referenceSequenceSHA256": .object(refHashes)
        ]
        return AnalysisRun(
            schemaVersion: 2,
            module: NavItem.sangerVerify.rawValue,
            engine: "swift-native",
            inputs: inputs,
            parameters: params,
            manualEdits: [],
            exclusions: [],
            outputs: outputs,
            linkedPlasmidIDs: resolvedLinked
        )
    }

    @discardableResult
    public static func exportBatchSummaryCSVWithProvenance(
        batchResult: BatchVerificationResult,
        candidates: [SangerReferenceCandidate] = [],
        trimQualityThreshold: Int = 20,
        suffixRegexPattern: String = defaultPrimerSuffixRegex,
        linkedPlasmidIDs: [String]? = nil,
        to outputCSVURL: URL
    ) throws -> (csvURL: URL, sidecarURL: URL, run: AnalysisRun) {
        let csvText = exportBatchSummaryCSV(batchResult.cloneSummaries)
        try csvText.write(to: outputCSVURL, atomically: true, encoding: .utf8)
        let exportDir = outputCSVURL.deletingLastPathComponent()
        let run = buildBatchAnalysisRun(
            batchResult: batchResult,
            candidates: candidates,
            trimQualityThreshold: trimQualityThreshold,
            primerSuffixRegex: suffixRegexPattern,
            outputs: [outputCSVURL.lastPathComponent],
            exportDirectoryURL: exportDir,
            linkedPlasmidIDs: linkedPlasmidIDs
        )
        let sidecarURL = try run.writeSidecarJSON(alongsideOutputURL: outputCSVURL)
        return (outputCSVURL, sidecarURL, run)
    }
}
