import Foundation

// MARK: - 全质粒 Nanopore 全局验证 & 多 Sanger 读段参考拼接 Contig 引擎

public enum PlasmidSequencingAssemblyEngine {

    // MARK: - 1. 通用测序读段解析 (.fasta / .fastq / .fq)

    public struct SequencingReadRecord: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let sequence: String
        public let qualities: [Int]
        public let meanPhred: Double?
        public let isFastq: Bool
    }

    public static func parseFastqOrFasta(_ rawText: String, defaultName: String = "Read") -> [SequencingReadRecord] {
        let normalized = rawText
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let nonEmpty = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let firstLine = nonEmpty.first else { return [] }

        // FASTQ 解析（标准 @header / seq / + / qual 四行循环）
        if firstLine.hasPrefix("@") {
            var records: [SequencingReadRecord] = []
            var idx = 0
            while idx + 3 < nonEmpty.count {
                let h = nonEmpty[idx]
                guard h.hasPrefix("@") else {
                    idx += 1
                    continue
                }
                let seqRaw = BioSequence.clean(nonEmpty[idx + 1])
                let plusLine = nonEmpty[idx + 2]
                let qualLine = nonEmpty[idx + 3]
                if plusLine.hasPrefix("+") && !seqRaw.isEmpty {
                    let qScalars = Array(qualLine.unicodeScalars)
                    var qs: [Int] = []
                    qs.reserveCapacity(seqRaw.count)
                    for i in 0..<seqRaw.count {
                        let q = i < qScalars.count ? max(0, min(60, Int(qScalars[i].value) - 33)) : 30
                        qs.append(q)
                    }
                    let meanQ = qs.isEmpty ? nil : Double(qs.reduce(0, +)) / Double(qs.count)
                    let name = String(h.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    records.append(
                        SequencingReadRecord(
                            id: "\(records.count)_\(name)",
                            name: name.isEmpty ? "\(defaultName)_\(records.count + 1)" : name,
                            sequence: seqRaw,
                            qualities: qs,
                            meanPhred: meanQ,
                            isFastq: true
                        )
                    )
                    idx += 4
                } else {
                    idx += 1
                }
            }
            if !records.isEmpty { return records }
        }

        // FASTA / 纯文本回退
        var records: [SequencingReadRecord] = []
        var curName = defaultName
        var curSeq = ""
        for line in nonEmpty {
            if line.hasPrefix(">") {
                let cleaned = BioSequence.clean(curSeq)
                if !cleaned.isEmpty {
                    records.append(
                        SequencingReadRecord(
                            id: "\(records.count)_\(curName)",
                            name: curName,
                            sequence: cleaned,
                            qualities: [],
                            meanPhred: nil,
                            isFastq: false
                        )
                    )
                }
                curName = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if curName.isEmpty { curName = "\(defaultName)_\(records.count + 1)" }
                curSeq = ""
            } else {
                curSeq += line
            }
        }
        let tail = BioSequence.clean(curSeq)
        if !tail.isEmpty {
            records.append(
                SequencingReadRecord(
                    id: "\(records.count)_\(curName)",
                    name: curName,
                    sequence: tail,
                    qualities: [],
                    meanPhred: nil,
                    isFastq: false
                )
            )
        }
        return records
    }

    // MARK: - 2. 多 Sanger 读段双向拼接为带质量分的 Consensus Contig

    public struct AlignedSangerReadBrief: Identifiable, Sendable, Equatable {
        public let id: String
        public let sampleName: String
        public let isReverseComplement: Bool
        public let matchedRefStart1Based: Int
        public let matchedRefEnd1Based: Int
        public let identityPercent: Double
        public let trimmedLength: Int
    }

    public struct ContigConsensusBase: Identifiable, Sendable, Equatable {
        public var id: Int { refPos1Based }
        public let refPos1Based: Int
        public let refBase: Character
        public let consensusBase: Character
        public let consensusPhred: Int
        public let depth: Int
        public let forwardDepth: Int
        public let reverseDepth: Int
        public let hasConflict: Bool
        public let isMatchToRef: Bool
    }

    public struct SangerContigAssemblyResult: Sendable, Equatable {
        public let referenceName: String
        public let referenceLength: Int
        public let readBriefs: [AlignedSangerReadBrief]
        public let bases: [ContigConsensusBase]
        public let coveredBasesCount: Int
        public let coveragePercent: Double
        public let doubleStrandCoveredCount: Int
        public let meanConsensusPhred: Double
        public let conflictCount: Int
        public let mismatchCount: Int
        public let uncoveredRanges: [ClosedRange<Int>]
        public let consensusFASTA: String
        public let consensusFASTQ: String
        public let assembledContigSequence: String
    }

    public static func assembleSangerContig(
        reads: [SangerAlignmentEngine.ChromatogramRecord],
        referenceSequence: String,
        referenceName: String = "Reference_Plasmid"
    ) -> SangerContigAssemblyResult {
        let cleanRef = BioSequence.clean(referenceSequence)
        let refChars = Array(cleanRef)
        let refLen = refChars.count
        guard refLen >= 30, !reads.isEmpty else {
            return SangerContigAssemblyResult(
                referenceName: referenceName,
                referenceLength: refLen,
                readBriefs: [],
                bases: [],
                coveredBasesCount: 0,
                coveragePercent: 0,
                doubleStrandCoveredCount: 0,
                meanConsensusPhred: 0,
                conflictCount: 0,
                mismatchCount: 0,
                uncoveredRanges: refLen > 0 ? [1...refLen] : [],
                consensusFASTA: "",
                consensusFASTQ: "",
                assembledContigSequence: ""
            )
        }

        // refPos1Based -> base -> weighted Q sum, plus strand counts
        struct PosBucket {
            var qSum: [Character: Int] = [:]
            var fwdCount: Int = 0
            var revCount: Int = 0
            var totalDepth: Int = 0
        }
        var buckets = Array(repeating: PosBucket(), count: refLen + 1)
        var briefs: [AlignedSangerReadBrief] = []

        for (rIdx, read) in reads.enumerated() {
            let rep = SangerAlignmentEngine.verifyAgainstPlasmid(
                chromatogram: read,
                referenceSequence: cleanRef,
                referenceName: referenceName
            )
            guard rep.verdict != .unaligned, rep.identityPercent >= 60.0 else {
                briefs.append(
                    AlignedSangerReadBrief(
                        id: "\(rIdx)_\(read.sampleName)",
                        sampleName: read.sampleName,
                        isReverseComplement: false,
                        matchedRefStart1Based: 0,
                        matchedRefEnd1Based: 0,
                        identityPercent: rep.identityPercent,
                        trimmedLength: read.trimmedLength
                    )
                )
                continue
            }

            briefs.append(
                AlignedSangerReadBrief(
                    id: "\(rIdx)_\(read.sampleName)",
                    sampleName: read.sampleName,
                    isReverseComplement: rep.isReverseComplement,
                    matchedRefStart1Based: rep.matchedRefStart1Based,
                    matchedRefEnd1Based: rep.matchedRefEnd1Based,
                    identityPercent: rep.identityPercent,
                    trimmedLength: read.trimmedLength
                )
            )

            var seenRefPosInRead = Set<Int>()
            for col in rep.columns {
                guard col.refPos1Based >= 1 && col.refPos1Based <= refLen else { continue }
                guard col.readBase != "-", col.refBase != "-" else { continue }
                guard !seenRefPosInRead.contains(col.refPos1Based) else { continue }
                seenRefPosInRead.insert(col.refPos1Based)

                let base = col.readBase
                let q = max(5, min(60, col.phredQuality))
                buckets[col.refPos1Based].qSum[base, default: 0] += q
                buckets[col.refPos1Based].totalDepth += 1
                if rep.isReverseComplement {
                    buckets[col.refPos1Based].revCount += 1
                } else {
                    buckets[col.refPos1Based].fwdCount += 1
                }
            }
        }

        var consensusBases: [ContigConsensusBase] = []
        consensusBases.reserveCapacity(refLen)
        var uncovered: [ClosedRange<Int>] = []
        var gapStart: Int? = nil
        var coveredCount = 0
        var doubleStrandCount = 0
        var conflictCount = 0
        var mismatchCount = 0
        var phredSum = 0
        var contigChars: [Character] = []
        var fullCharsWithN: [Character] = []
        var fullQuals: [Int] = []

        for pos1 in 1...refLen {
            let refBase = refChars[pos1 - 1]
            let b = buckets[pos1]
            if b.totalDepth == 0 {
                if gapStart == nil { gapStart = pos1 }
                fullCharsWithN.append("N")
                fullQuals.append(2)
                consensusBases.append(
                    ContigConsensusBase(
                        refPos1Based: pos1,
                        refBase: refBase,
                        consensusBase: "N",
                        consensusPhred: 0,
                        depth: 0,
                        forwardDepth: 0,
                        reverseDepth: 0,
                        hasConflict: false,
                        isMatchToRef: false
                    )
                )
            } else {
                if let gs = gapStart {
                    uncovered.append(gs...(pos1 - 1))
                    gapStart = nil
                }
                coveredCount += 1
                if b.fwdCount > 0 && b.revCount > 0 { doubleStrandCount += 1 }
                let sortedCalls = b.qSum.sorted { a, c in
                    if a.value != c.value { return a.value > c.value }
                    return a.key < c.key
                }
                let bestBase = sortedCalls.first?.key ?? refBase
                let bestScore = sortedCalls.first?.value ?? 0
                let secondScore = sortedCalls.count > 1 ? sortedCalls[1].value : 0
                let conflict = secondScore > 0
                if conflict { conflictCount += 1 }
                let netQ = conflict ? max(10, min(60, bestScore - secondScore)) : min(60, bestScore)
                let matchRef = (bestBase == refBase)
                if !matchRef { mismatchCount += 1 }
                phredSum += netQ
                contigChars.append(bestBase)
                fullCharsWithN.append(bestBase)
                fullQuals.append(netQ)

                consensusBases.append(
                    ContigConsensusBase(
                        refPos1Based: pos1,
                        refBase: refBase,
                        consensusBase: bestBase,
                        consensusPhred: netQ,
                        depth: b.totalDepth,
                        forwardDepth: b.fwdCount,
                        reverseDepth: b.revCount,
                        hasConflict: conflict,
                        isMatchToRef: matchRef
                    )
                )
            }
        }
        if let gs = gapStart {
            uncovered.append(gs...refLen)
        }

        let covPct = Double(coveredCount) * 100.0 / Double(refLen)
        let meanQ = coveredCount > 0 ? Double(phredSum) / Double(coveredCount) : 0.0
        let fullSeq = String(fullCharsWithN)
        let assembledOnly = String(contigChars)
        let qualASCII = String(fullQuals.map { q -> Character in
            let scalar = UnicodeScalar(min(93, max(33, q + 33))) ?? UnicodeScalar(35)!
            return Character(scalar)
        })

        let safeTitle = referenceName.replacingOccurrences(of: " ", with: "_")
        let fasta = ">\(safeTitle)_SangerContig_cov\(String(format: "%.1f", covPct))pct\n\(fullSeq)\n"
        let fastq = "@\(safeTitle)_SangerContig\n\(fullSeq)\n+\n\(qualASCII)\n"

        return SangerContigAssemblyResult(
            referenceName: referenceName,
            referenceLength: refLen,
            readBriefs: briefs,
            bases: consensusBases,
            coveredBasesCount: coveredCount,
            coveragePercent: covPct,
            doubleStrandCoveredCount: doubleStrandCount,
            meanConsensusPhred: meanQ,
            conflictCount: conflictCount,
            mismatchCount: mismatchCount,
            uncoveredRanges: uncovered,
            consensusFASTA: fasta,
            consensusFASTQ: fastq,
            assembledContigSequence: assembledOnly
        )
    }

    // MARK: - 3. 全质粒 Nanopore 环状全局比对与结构变异检测

    public enum WholePlasmidVariantKind: String, Codable, Sendable {
        case snp = "点突变 (SNP)"
        case smallInsertion = "小插入 (Indel +)"
        case smallDeletion = "小缺失 (Indel -)"
        case largeDeletion = "大片段缺失 (SV Del)"
        case largeInsertion = "大片段插入 (SV Ins)"
        case tandemDuplication = "串联重复 (Tandem Dup)"
        case inversion = "倒位重排 (Inversion)"
        case rearrangement = "骨架重排 (Rearrangement)"
    }

    public struct WholePlasmidVariant: Identifiable, Codable, Sendable, Equatable {
        public let id: String
        public let kind: WholePlasmidVariantKind
        public let refStart1Based: Int
        public let refEnd1Based: Int
        public let queryStart1Based: Int
        public let queryEnd1Based: Int
        public let sizeBp: Int
        public let summary: String
        public let detail: String

        public var isStructuralVariant: Bool {
            switch kind {
            case .largeDeletion, .largeInsertion, .tandemDuplication, .inversion, .rearrangement:
                return true
            case .snp, .smallInsertion, .smallDeletion:
                return false
            }
        }
    }

    public struct WholePlasmidCoverageBlock: Identifiable, Sendable, Equatable {
        public let id: Int
        public let refStart1Based: Int
        public let refEnd1Based: Int
        public let queryStart1Based: Int
        public let queryEnd1Based: Int
        public let isReverseComplement: Bool
        public let alignedBp: Int
    }

    public enum WholePlasmidVerdict: String, Codable, Sendable {
        case verifiedPass = "全质粒 100% 匹配通过"
        case minorVariantsOnly = "整体骨架一致，检出少量 SNP/小 Indel"
        case structuralVariantDetected = "检出结构变异（大缺失/插入/重复/重排）"
        case unmatched = "无法匹配参考质粒序列"
    }

    public struct WholePlasmidVerificationReport: Sendable, Equatable {
        public let queryName: String
        public let referenceName: String
        public let queryLength: Int
        public let referenceLength: Int
        public let lengthDeltaBp: Int
        public let queryMeanPhred: Double?
        public let isReverseComplement: Bool
        public let rotatedOriginOffset0Based: Int
        public let rotatedQuerySequence: String
        public let identityPercent: Double
        public let coveragePercent: Double
        public let blocks: [WholePlasmidCoverageBlock]
        public let variants: [WholePlasmidVariant]
        public let snpCount: Int
        public let smallIndelCount: Int
        public let svCount: Int
        public let verdict: WholePlasmidVerdict
        public let summaryText: String
    }

    private struct AnchorBlock: Equatable {
        let refStart0: Int
        let refEnd0: Int
        let qStart0: Int
        let qEnd0: Int
        let isRev: Bool
        var len: Int { refEnd0 - refStart0 }
    }

    public static func verifyWholePlasmid(
        querySequence: String,
        queryName: String = "Nanopore_Consensus",
        queryMeanPhred: Double? = nil,
        referenceSequence: String,
        referenceName: String = "Reference_Plasmid"
    ) -> WholePlasmidVerificationReport {
        let cleanRef = BioSequence.clean(referenceSequence)
        let cleanQ = BioSequence.clean(querySequence)
        let refLen = cleanRef.count
        let qLen = cleanQ.count

        guard refLen >= 40, qLen >= 30 else {
            return WholePlasmidVerificationReport(
                queryName: queryName,
                referenceName: referenceName,
                queryLength: qLen,
                referenceLength: refLen,
                lengthDeltaBp: qLen - refLen,
                queryMeanPhred: queryMeanPhred,
                isReverseComplement: false,
                rotatedOriginOffset0Based: 0,
                rotatedQuerySequence: cleanQ,
                identityPercent: 0,
                coveragePercent: 0,
                blocks: [],
                variants: [],
                snpCount: 0,
                smallIndelCount: 0,
                svCount: 0,
                verdict: .unmatched,
                summaryText: L10n.t("参考或待检序列过短，无法执行全质粒比对。")
            )
        }

        let k = min(15, max(11, refLen / 8))
        let doubledRef = cleanRef + cleanRef
        let refSeedIndex = buildSeedIndex(for: doubledRef, limitRefLen: refLen, k: k)

        let fwdHist = dominantRotationOffset(query: cleanQ, refSeedIndex: refSeedIndex, refLen: refLen, k: k)
        let rcQuery = BioSequence.reverseComplement(cleanQ)
        let revHist = dominantRotationOffset(query: rcQuery, refSeedIndex: refSeedIndex, refLen: refLen, k: k)

        let useRev = revHist.hits > fwdHist.hits
        let orientedQ = useRev ? rcQuery : cleanQ
        let bestHist = useRev ? revHist : fwdHist

        guard bestHist.hits >= 2 else {
            return WholePlasmidVerificationReport(
                queryName: queryName,
                referenceName: referenceName,
                queryLength: qLen,
                referenceLength: refLen,
                lengthDeltaBp: qLen - refLen,
                queryMeanPhred: queryMeanPhred,
                isReverseComplement: useRev,
                rotatedOriginOffset0Based: 0,
                rotatedQuerySequence: orientedQ,
                identityPercent: 0,
                coveragePercent: 0,
                blocks: [],
                variants: [],
                snpCount: 0,
                smallIndelCount: 0,
                svCount: 0,
                verdict: .unmatched,
                summaryText: L10n.tr("未能在正反双链找到足够的 \(k)-mer 同源锚点。", "Insufficient \(k)-mer anchors found on either strand.")
            )
        }

        // 将 orientedQ 按最优 Origin 旋转，使 index 0 对齐 reference 0
        let rotCut0 = findOriginCutIndex(orientedQuery: orientedQ, cleanRef: cleanRef, roughShift: bestHist.shift, k: k)
        let orientedChars = Array(orientedQ)
        let rotatedChars = Array(orientedChars[rotCut0..<qLen] + orientedChars[0..<rotCut0])
        let rotatedQ = String(rotatedChars)

        // 构建非环状双链种子表并在 rotatedQ 上提取正链与反向锚点块
        let singleRefFwdIndex = buildSeedIndex(for: cleanRef, limitRefLen: refLen, k: k)
        let rcRef = BioSequence.reverseComplement(cleanRef)
        let singleRefRevIndex = buildSeedIndex(for: rcRef, limitRefLen: refLen, k: k)

        let rawFwdBlocks = extractAnchorBlocks(queryChars: rotatedChars, seedIndex: singleRefFwdIndex, k: k, isRev: false)
        let rawRevBlocks = extractAnchorBlocks(queryChars: rotatedChars, seedIndex: singleRefRevIndex, k: k, isRev: true)

        var variants: [WholePlasmidVariant] = []
        var coverageBlocks: [WholePlasmidCoverageBlock] = []

        // 检测大倒位块 (在 rotatedQ 上未被更强正链块覆盖且 >= 60 bp 的反向锚点)
        for rb in rawRevBlocks where rb.len >= 60 {
            let coveredByFwd = rawFwdBlocks.contains { fb in
                max(fb.qStart0, rb.qStart0) < min(fb.qEnd0, rb.qEnd0) - 20
            }
            if !coveredByFwd {
                let r1Start = max(1, refLen - rb.refEnd0 + 1)
                let r1End = min(refLen, refLen - rb.refStart0)
                variants.append(
                    WholePlasmidVariant(
                        id: "inv_\(rb.qStart0)",
                        kind: .inversion,
                        refStart1Based: r1Start,
                        refEnd1Based: max(r1Start, r1End),
                        queryStart1Based: rb.qStart0 + 1,
                        queryEnd1Based: rb.qEnd0,
                        sizeBp: rb.len,
                        summary: L10n.tr("序列倒位 \(rb.len) bp @ Ref \(r1Start)..\(max(r1Start, r1End))", "Inversion \(rb.len) bp @ Ref \(r1Start)..\(max(r1Start, r1End))"),
                        detail: L10n.tr("待检质粒 Q \(rb.qStart0 + 1)..\(rb.qEnd0) 反向互补匹配参考区间，提示载体或插入片段方向颠倒/倒位重排。", "Query \(rb.qStart0 + 1)..\(rb.qEnd0) aligns reverse-complementarily to reference, indicating inversion/flipped insert.")
                    )
                )
            }
        }

        // 选取主链正链块并检测串联重复与乱序重排
        let sigFwd = rawFwdBlocks.filter { $0.len >= max(18, k + 2) }.sorted { $0.qStart0 < $1.qStart0 }
        var majorBlocks: [AnchorBlock] = []
        var coveredRefIntervals: [(rStart0: Int, rEnd0: Int, qStart0: Int, qEnd0: Int)] = []

        for blk in sigFwd {
            // 串联重复检测：当前块是否重复命中之前已强覆盖的大段参考区间 (>= 70 bp)
            let isTandem = coveredRefIntervals.contains { prev in
                let ov = min(prev.rEnd0, blk.refEnd0) - max(prev.rStart0, blk.refStart0)
                return ov >= 70 && blk.qStart0 >= prev.qEnd0 - 10
            }
            if isTandem && blk.len >= 70 {
                variants.append(
                    WholePlasmidVariant(
                        id: "dup_\(blk.qStart0)_\(blk.refStart0)",
                        kind: .tandemDuplication,
                        refStart1Based: blk.refStart0 + 1,
                        refEnd1Based: blk.refEnd0,
                        queryStart1Based: blk.qStart0 + 1,
                        queryEnd1Based: blk.qEnd0,
                        sizeBp: blk.len,
                        summary: L10n.tr("串联重复 \(blk.len) bp (Ref \(blk.refStart0 + 1)..\(blk.refEnd0))", "Tandem Duplication \(blk.len) bp (Ref \(blk.refStart0 + 1)..\(blk.refEnd0))"),
                        detail: L10n.tr("参考区间 \(blk.refStart0 + 1)..\(blk.refEnd0) 在全质粒测序结果中额外重复出现 (Query \(blk.qStart0 + 1)..\(blk.qEnd0))。", "Reference \(blk.refStart0 + 1)..\(blk.refEnd0) appears duplicated in query \(blk.qStart0 + 1)..\(blk.qEnd0).")
                    )
                )
                continue
            }

            if let last = majorBlocks.last {
                // 跳过被前一块完全包含的次优冗余短命中
                if blk.qStart0 >= last.qStart0 && blk.qEnd0 <= last.qEnd0 { continue }
                if blk.qStart0 < last.qEnd0 && blk.len < last.len { continue }
                if blk.refStart0 + 25 < last.refEnd0 && blk.len >= 60 {
                    variants.append(
                        WholePlasmidVariant(
                            id: "rearr_\(blk.qStart0)",
                            kind: .rearrangement,
                            refStart1Based: blk.refStart0 + 1,
                            refEnd1Based: blk.refEnd0,
                            queryStart1Based: blk.qStart0 + 1,
                            queryEnd1Based: blk.qEnd0,
                            sizeBp: blk.len,
                            summary: L10n.tr("骨架乱序重排 @ Q \(blk.qStart0 + 1)..\(blk.qEnd0)", "Backbone Rearrangement @ Q \(blk.qStart0 + 1)..\(blk.qEnd0)"),
                            detail: L10n.tr("区块顺序由 Ref \(last.refEnd0) 跳回 Ref \(blk.refStart0 + 1)，存在重排事件。", "Block order jumped from Ref \(last.refEnd0) back to Ref \(blk.refStart0 + 1).")
                        )
                    )
                    continue
                }
            }
            majorBlocks.append(blk)
            coveredRefIntervals.append((blk.refStart0, blk.refEnd0, blk.qStart0, blk.qEnd0))
        }

        // 若单锚点或大间隙存在且两端紧接同一个局部缺失/插入事件，把空隙送入精确对齐或大 SV 提取
        let refChars = Array(cleanRef)
        var alignedMatchBp = 0
        var refCoveredFlags = Array(repeating: false, count: refLen)

        for (idx, blk) in majorBlocks.enumerated() {
            coverageBlocks.append(
                WholePlasmidCoverageBlock(
                    id: idx + 1,
                    refStart1Based: blk.refStart0 + 1,
                    refEnd1Based: blk.refEnd0,
                    queryStart1Based: blk.qStart0 + 1,
                    queryEnd1Based: blk.qEnd0,
                    isReverseComplement: false,
                    alignedBp: blk.len
                )
            )
            alignedMatchBp += blk.len
            for r in blk.refStart0..<min(refLen, blk.refEnd0) {
                refCoveredFlags[r] = true
            }
        }

        // 在相邻主链锚点之间检测 SNP / Indel / 大缺失 / 大插入
        var gapIntervals: [(rS: Int, rE: Int, qS: Int, qE: Int)] = []
        if let first = majorBlocks.first {
            if first.refStart0 > 0 || first.qStart0 > 0 {
                gapIntervals.append((0, first.refStart0, 0, first.qStart0))
            }
            for i in 0..<(majorBlocks.count - 1) {
                let a = majorBlocks[i]
                let b = majorBlocks[i + 1]
                let rS = a.refEnd0
                let rE = max(rS, b.refStart0)
                let qS = a.qEnd0
                let qE = max(qS, b.qStart0)
                if rE > rS || qE > qS {
                    gapIntervals.append((rS, rE, qS, qE))
                }
            }
            if let last = majorBlocks.last, (last.refEnd0 < refLen || last.qEnd0 < qLen) {
                gapIntervals.append((last.refEnd0, refLen, last.qEnd0, qLen))
            }
        }

        for gap in gapIntervals {
            let explainedBySV = variants.contains { v in
                (v.kind == .tandemDuplication || v.kind == .inversion || v.kind == .rearrangement)
                    && (v.queryStart1Based - 1) <= gap.qS + 15
                    && v.queryEnd1Based >= gap.qE - 15
            }
            if explainedBySV && (gap.qE - gap.qS) >= 50 { continue }
            let rSpan = gap.rE - gap.rS
            let qSpan = gap.qE - gap.qS
            let delta = rSpan - qSpan

            if rSpan >= 30 && abs(delta) >= 30 && qSpan <= 10 {
                variants.append(
                    WholePlasmidVariant(
                        id: "ldel_\(gap.rS)",
                        kind: .largeDeletion,
                        refStart1Based: gap.rS + 1,
                        refEnd1Based: gap.rE,
                        queryStart1Based: gap.qS + 1,
                        queryEnd1Based: max(gap.qS + 1, gap.qE),
                        sizeBp: delta,
                        summary: L10n.tr("大片段缺失 Δ\(delta) bp @ Ref \(gap.rS + 1)..\(gap.rE)", "Large Deletion Δ\(delta) bp @ Ref \(gap.rS + 1)..\(gap.rE)"),
                        detail: L10n.tr("参考质粒 \(gap.rS + 1)..\(gap.rE) (\(rSpan) bp) 仅对应 Query \(qSpan) bp，疑似缺失重组失败区段。", "Ref \(gap.rS + 1)..\(gap.rE) (\(rSpan) bp) spans only \(qSpan) bp in query.")
                    )
                )
            } else if qSpan >= 30 && delta <= -30 && rSpan <= 10 {
                let insLen = -delta
                variants.append(
                    WholePlasmidVariant(
                        id: "lins_\(gap.qS)",
                        kind: .largeInsertion,
                        refStart1Based: gap.rS + 1,
                        refEnd1Based: max(gap.rS + 1, gap.rE),
                        queryStart1Based: gap.qS + 1,
                        queryEnd1Based: gap.qE,
                        sizeBp: insLen,
                        summary: L10n.tr("大片段插入 +\(insLen) bp @ Ref \(gap.rS + 1)", "Large Insertion +\(insLen) bp @ Ref \(gap.rS + 1)"),
                        detail: L10n.tr("待检质粒多出 \(insLen) bp 非参考片段 (Query \(gap.qS + 1)..\(gap.qE))。", "Query has \(insLen) bp unmapped insertion (Q \(gap.qS + 1)..\(gap.qE)).")
                    )
                )
            } else if rSpan <= 360 && qSpan <= 360 {
                let refSlice = Array(refChars[gap.rS..<gap.rE])
                let qSlice = Array(rotatedChars[gap.qS..<gap.qE])
                let res = alignLocalGap(refSlice: refSlice, qSlice: qSlice, refStart0: gap.rS, qStart0: gap.qS)
                alignedMatchBp += res.matches
                for rPos in res.matchedRefPositions where rPos >= 0 && rPos < refLen {
                    refCoveredFlags[rPos] = true
                }
                variants.append(contentsOf: res.variants)
            } else {
                // 超过局部 DP 安全上限的大间隙统一判定为结构性插入或缺失
                if delta > 0 {
                    variants.append(
                        WholePlasmidVariant(
                            id: "lsv_del_\(gap.rS)",
                            kind: .largeDeletion,
                            refStart1Based: gap.rS + 1,
                            refEnd1Based: gap.rE,
                            queryStart1Based: gap.qS + 1,
                            queryEnd1Based: max(gap.qS + 1, gap.qE),
                            sizeBp: delta,
                            summary: L10n.tr("大区段差异/缺失 Δ\(delta) bp @ Ref \(gap.rS + 1)..\(gap.rE)", "Large Segment Deletion Δ\(delta) bp @ Ref \(gap.rS + 1)..\(gap.rE)"),
                            detail: L10n.tr("参考 \(rSpan) bp vs Query \(qSpan) bp。", "Ref \(rSpan) bp vs Query \(qSpan) bp.")
                        )
                    )
                } else {
                    variants.append(
                        WholePlasmidVariant(
                            id: "lsv_ins_\(gap.qS)",
                            kind: .largeInsertion,
                            refStart1Based: gap.rS + 1,
                            refEnd1Based: max(gap.rS + 1, gap.rE),
                            queryStart1Based: gap.qS + 1,
                            queryEnd1Based: gap.qE,
                            sizeBp: -delta,
                            summary: L10n.tr("大区段插入 +\(-delta) bp @ Ref \(gap.rS + 1)", "Large Segment Insertion +\(-delta) bp @ Ref \(gap.rS + 1)"),
                            detail: L10n.tr("参考 \(rSpan) bp vs Query \(qSpan) bp。", "Ref \(rSpan) bp vs Query \(qSpan) bp.")
                        )
                    )
                }
            }
        }

        let coveredCount = refCoveredFlags.filter { $0 }.count
        let covPct = Double(coveredCount) * 100.0 / Double(refLen)
        let denom = max(1, max(refLen, qLen))
        let idPct = min(100.0, Double(alignedMatchBp) * 100.0 / Double(denom))

        let snpCnt = variants.filter { $0.kind == .snp }.count
        let smallIndelCnt = variants.filter { $0.kind == .smallInsertion || $0.kind == .smallDeletion }.count
        let svCnt = variants.filter { $0.isStructuralVariant }.count

        let verdict: WholePlasmidVerdict
        if svCnt > 0 {
            verdict = .structuralVariantDetected
        } else if snpCnt == 0 && smallIndelCnt == 0 && covPct >= 99.0 && abs(qLen - refLen) <= 2 {
            verdict = .verifiedPass
        } else if covPct < 35.0 {
            verdict = .unmatched
        } else {
            verdict = .minorVariantsOnly
        }

        let summary = L10n.tr("方向: \(useRev ? "反向互补 (-)" : "正链 (+)") · Origin 旋转: \(rotCut0) bp · 覆盖度 \(String(format: "%.1f%%", covPct)) · 一致率 \(String(format: "%.2f%%", idPct)) · SV \(svCnt) / SNP \(snpCnt) / Indel \(smallIndelCnt)", "Strand: \(L10n.t(useRev ? "反向互补 (-)" : "正链 (+)")) · Origin Rot: \(rotCut0) bp · Cov \(String(format: "%.1f%%", covPct)) · ID \(String(format: "%.2f%%", idPct)) · SV \(svCnt) / SNP \(snpCnt) / Indel \(smallIndelCnt)")

        return WholePlasmidVerificationReport(
            queryName: queryName,
            referenceName: referenceName,
            queryLength: qLen,
            referenceLength: refLen,
            lengthDeltaBp: qLen - refLen,
            queryMeanPhred: queryMeanPhred,
            isReverseComplement: useRev,
            rotatedOriginOffset0Based: rotCut0,
            rotatedQuerySequence: rotatedQ,
            identityPercent: idPct,
            coveragePercent: covPct,
            blocks: coverageBlocks,
            variants: variants.sorted { $0.refStart1Based < $1.refStart1Based },
            snpCount: snpCnt,
            smallIndelCount: smallIndelCnt,
            svCount: svCnt,
            verdict: verdict,
            summaryText: summary
        )
    }

    // MARK: - 内部种子索引与局部精确对齐

    private static func buildSeedIndex(for seq: String, limitRefLen: Int, k: Int) -> [String: [Int]] {
        let chars = Array(seq)
        guard chars.count >= k else { return [:] }
        let maxStart = min(chars.count - k, limitRefLen - 1)
        guard maxStart >= 0 else { return [:] }
        var map: [String: [Int]] = [:]
        map.reserveCapacity(limitRefLen)
        for i in 0...maxStart {
            let kmer = String(chars[i..<(i + k)])
            map[kmer, default: []].append(i)
        }
        return map
    }

    private static func dominantRotationOffset(
        query: String,
        refSeedIndex: [String: [Int]],
        refLen: Int,
        k: Int
    ) -> (shift: Int, hits: Int) {
        let qChars = Array(query)
        guard qChars.count >= k else { return (0, 0) }
        var bins: [Int: Int] = [:]
        let step = max(1, min(4, qChars.count / 200))
        for qPos in stride(from: 0, through: qChars.count - k, by: step) {
            let kmer = String(qChars[qPos..<(qPos + k)])
            guard let refHits = refSeedIndex[kmer], refHits.count <= 6 else { continue }
            for rPos in refHits {
                let rawOffset = ((rPos - qPos) % refLen + refLen) % refLen
                let bin = (rawOffset / 4) * 4
                bins[bin, default: 0] += 1
            }
        }
        guard let best = bins.max(by: { $0.value < $1.value }) else { return (0, 0) }
        return (best.key, best.value)
    }

    private static func findOriginCutIndex(
        orientedQuery: String,
        cleanRef: String,
        roughShift: Int,
        k: Int
    ) -> Int {
        let qChars = Array(orientedQuery)
        let refChars = Array(cleanRef)
        let qLen = qChars.count
        let refLen = refChars.count
        let subK = min(k, min(refLen, qLen))
        if subK >= 10 {
            let expectedQ = roughShift == 0 ? 0 : (((refLen - roughShift) % refLen) % qLen)
            for anchorOffset in [0, 20, 40, 60] where anchorOffset + subK <= refLen {
                let headKmer = String(refChars[anchorOffset..<(anchorOffset + subK)])
                var bestCut: Int? = nil
                var bestDist = Int.max
                for i in 0...(qLen - subK) {
                    if String(qChars[i..<(i + subK)]) == headKmer {
                        let candCut = ((i - anchorOffset) % qLen + qLen) % qLen
                        let cyclicDist = min(abs(candCut - expectedQ), qLen - abs(candCut - expectedQ))
                        if cyclicDist < bestDist {
                            bestDist = cyclicDist
                            bestCut = candCut
                        }
                    }
                }
                if let cut = bestCut, bestDist <= max(120, abs(qLen - refLen) + 80) {
                    return cut
                }
            }
        }
        return roughShift == 0 ? 0 : (((refLen - roughShift) % refLen) % qLen)
    }

    private static func extractAnchorBlocks(
        queryChars: [Character],
        seedIndex: [String: [Int]],
        k: Int,
        isRev: Bool
    ) -> [AnchorBlock] {
        let qLen = queryChars.count
        guard qLen >= k else { return [] }
        var activeByDiag: [Int: (rS: Int, rE: Int, qS: Int, qE: Int)] = [:]
        var finished: [AnchorBlock] = []

        for qPos in 0...(qLen - k) {
            let kmer = String(queryChars[qPos..<(qPos + k)])
            guard let hits = seedIndex[kmer], hits.count <= 4 else { continue }
            for rPos in hits {
                let diag = rPos - qPos
                if var cur = activeByDiag[diag], qPos <= cur.qE && rPos <= cur.rE {
                    cur.rE = max(cur.rE, rPos + k)
                    cur.qE = max(cur.qE, qPos + k)
                    activeByDiag[diag] = cur
                } else {
                    if let prev = activeByDiag[diag] {
                        finished.append(AnchorBlock(refStart0: prev.rS, refEnd0: prev.rE, qStart0: prev.qS, qEnd0: prev.qE, isRev: isRev))
                    }
                    activeByDiag[diag] = (rPos, rPos + k, qPos, qPos + k)
                }
            }
        }
        for (_, cur) in activeByDiag {
            finished.append(AnchorBlock(refStart0: cur.rS, refEnd0: cur.rE, qStart0: cur.qS, qEnd0: cur.qE, isRev: isRev))
        }
        return finished.sorted { ($0.qStart0, -$0.len) < ($1.qStart0, -$1.len) }
    }

    private static func alignLocalGap(
        refSlice: [Character],
        qSlice: [Character],
        refStart0: Int,
        qStart0: Int
    ) -> (matches: Int, matchedRefPositions: [Int], variants: [WholePlasmidVariant]) {
        let m = refSlice.count
        let n = qSlice.count
        if m == 0 && n == 0 { return (0, [], []) }
        if m == 0 {
            let insStr = String(qSlice)
            return (0, [], [
                WholePlasmidVariant(
                    id: "ins_\(refStart0)_\(qStart0)",
                    kind: .smallInsertion,
                    refStart1Based: refStart0 + 1,
                    refEnd1Based: refStart0 + 1,
                    queryStart1Based: qStart0 + 1,
                    queryEnd1Based: qStart0 + n,
                    sizeBp: n,
                    summary: L10n.tr("小插入 +\(n) bp (\(insStr)) @ Ref \(refStart0 + 1)", "Small Insertion +\(n) bp (\(insStr)) @ Ref \(refStart0 + 1)"),
                    detail: L10n.tr("参考位点 \(refStart0 + 1) 前插入 \(n) bp 序列 \(insStr)。", "Inserted \(n) bp (\(insStr)) before Ref \(refStart0 + 1).")
                )
            ])
        }
        if n == 0 {
            let delStr = String(refSlice)
            return (0, [], [
                WholePlasmidVariant(
                    id: "del_\(refStart0)_\(qStart0)",
                    kind: .smallDeletion,
                    refStart1Based: refStart0 + 1,
                    refEnd1Based: refStart0 + m,
                    queryStart1Based: qStart0 + 1,
                    queryEnd1Based: qStart0 + 1,
                    sizeBp: m,
                    summary: L10n.tr("小缺失 -\(m) bp (\(delStr)) @ Ref \(refStart0 + 1)..\(refStart0 + m)", "Small Deletion -\(m) bp (\(delStr)) @ Ref \(refStart0 + 1)..\(refStart0 + m)"),
                    detail: L10n.tr("参考区间 \(refStart0 + 1)..\(refStart0 + m) 缺失 \(m) bp。", "Deleted \(m) bp across Ref \(refStart0 + 1)..\(refStart0 + m).")
                )
            ])
        }

        // 标准全球 DP 对齐局部空隙 (< 360 bp)
        let matchS = 2, mismatchS = -3, gapS = -4
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        var trace = Array(repeating: Array(repeating: UInt8(0), count: n + 1), count: m + 1)
        for i in 1...m { dp[i][0] = i * gapS; trace[i][0] = 1 }
        for j in 1...n { dp[0][j] = j * gapS; trace[0][j] = 2 }
        for i in 1...m {
            for j in 1...n {
                let d = dp[i - 1][j - 1] + (refSlice[i - 1] == qSlice[j - 1] ? matchS : mismatchS)
                let u = dp[i - 1][j] + gapS
                let l = dp[i][j - 1] + gapS
                if d >= u && d >= l { dp[i][j] = d; trace[i][j] = 0 }
                else if u >= l { dp[i][j] = u; trace[i][j] = 1 }
                else { dp[i][j] = l; trace[i][j] = 2 }
            }
        }

        var pairs: [(r: Character, q: Character, rPos0: Int, qPos0: Int)] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && trace[i][j] == 0 {
                pairs.append((refSlice[i - 1], qSlice[j - 1], refStart0 + i - 1, qStart0 + j - 1))
                i -= 1; j -= 1
            } else if i > 0 && (j == 0 || trace[i][j] == 1) {
                pairs.append((refSlice[i - 1], "-", refStart0 + i - 1, qStart0 + j))
                i -= 1
            } else {
                pairs.append(("-", qSlice[j - 1], refStart0 + i, qStart0 + j - 1))
                j -= 1
            }
        }
        pairs.reverse()

        var matches = 0
        var matchedPos: [Int] = []
        var outVars: [WholePlasmidVariant] = []
        var idx = 0
        while idx < pairs.count {
            let p = pairs[idx]
            if p.r == p.q && p.r != "-" {
                matches += 1
                matchedPos.append(p.rPos0)
                idx += 1
            } else if p.r != "-" && p.q != "-" {
                matchedPos.append(p.rPos0)
                outVars.append(
                    WholePlasmidVariant(
                        id: "snp_\(p.rPos0 + 1)",
                        kind: .snp,
                        refStart1Based: p.rPos0 + 1,
                        refEnd1Based: p.rPos0 + 1,
                        queryStart1Based: p.qPos0 + 1,
                        queryEnd1Based: p.qPos0 + 1,
                        sizeBp: 1,
                        summary: "SNP g.\(p.rPos0 + 1)\(p.r)>\(p.q)",
                        detail: L10n.tr("参考第 \(p.rPos0 + 1) 位碱基由 \(p.r) 突变为 \(p.q)。", "Ref pos \(p.rPos0 + 1) mutated \(p.r) → \(p.q).")
                    )
                )
                idx += 1
            } else if p.r == "-" {
                var insSeq = ""
                let r1 = p.rPos0 + 1
                let q1S = p.qPos0 + 1
                var q1E = q1S
                while idx < pairs.count && pairs[idx].r == "-" {
                    insSeq.append(pairs[idx].q)
                    q1E = pairs[idx].qPos0 + 1
                    idx += 1
                }
                outVars.append(
                    WholePlasmidVariant(
                        id: "sins_\(r1)_\(q1S)",
                        kind: .smallInsertion,
                        refStart1Based: r1,
                        refEnd1Based: r1,
                        queryStart1Based: q1S,
                        queryEnd1Based: q1E,
                        sizeBp: insSeq.count,
                        summary: L10n.tr("小插入 +\(insSeq.count) bp (\(insSeq)) @ Ref \(r1)", "Small Insertion +\(insSeq.count) bp (\(insSeq)) @ Ref \(r1)"),
                        detail: L10n.tr("参考第 \(r1) 位处插入 \(insSeq.count) bp：\(insSeq)。", "Inserted \(insSeq.count) bp at Ref \(r1): \(insSeq).")
                    )
                )
            } else {
                var delSeq = ""
                let r1S = p.rPos0 + 1
                var r1E = r1S
                let q1 = p.qPos0 + 1
                while idx < pairs.count && pairs[idx].q == "-" {
                    delSeq.append(pairs[idx].r)
                    r1E = pairs[idx].rPos0 + 1
                    idx += 1
                }
                outVars.append(
                    WholePlasmidVariant(
                        id: "sdel_\(r1S)_\(q1)",
                        kind: .smallDeletion,
                        refStart1Based: r1S,
                        refEnd1Based: r1E,
                        queryStart1Based: q1,
                        queryEnd1Based: q1,
                        sizeBp: delSeq.count,
                        summary: L10n.tr("小缺失 -\(delSeq.count) bp (\(delSeq)) @ Ref \(r1S)..\(r1E)", "Small Deletion -\(delSeq.count) bp (\(delSeq)) @ Ref \(r1S)..\(r1E)"),
                        detail: L10n.tr("参考第 \(r1S)..\(r1E) 位缺失 \(delSeq.count) bp：\(delSeq)。", "Deleted \(delSeq.count) bp at Ref \(r1S)..\(r1E): \(delSeq).")
                    )
                )
            }
        }
        return (matches, matchedPos, outVars)
    }

    // MARK: - 4. 内置演示数据（全公开合成序列）

    public static func demoWholePlasmidFixture() -> (refName: String, refSeq: String, queryName: String, fastqText: String) {
        let baseBlocks = [
            "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGAC",
            "GGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCA",
            "TCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTA",
            "CCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAG",
            "GACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCG",
            "ACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAA",
            "GCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAG",
            "CAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACC"
        ]
        let ref = baseBlocks.joined() // 656 bp
        var mutChars = Array(ref)
        // 1. 引入 1 处 SNP (index 100: T->A 或切换碱基)
        mutChars[100] = (mutChars[100] == "A") ? "G" : "A"
        // 2. 删除 40 bp (index 420..<460)
        let withSV = Array(mutChars[0..<420] + mutChars[460..<mutChars.count])
        // 3. 模拟 Nanopore 从非 0 起点切开并环状旋转 210 bp
        let rot = 210
        let rotated = String(withSV[rot..<withSV.count] + withSV[0..<rot])
        let qual = String(repeating: "I", count: rotated.count) // Phred Q40
        let fastq = "@Nanopore_Demo_Plasmid_Q40\n\(rotated)\n+\n\(qual)\n"
        return ("pEGFP_Demo_Ref", ref, "Nanopore_Demo_Plasmid_Q40", fastq)
    }

    public static func demoMultiSangerFixture() -> (refName: String, refSeq: String, reads: [SangerAlignmentEngine.ChromatogramRecord]) {
        let ref =
            "GCTAGCGCTACCGGTCGCCACCATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTG" +
            "CCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAG" +
            "GGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAG" +
            "CTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGC" +
            "CGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTAC" +
            "GTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTG" // 360 bp
        let chars = Array(ref)
        // 引入第 180 位一个真实点突变供正反向双链共同验证
        var mut = chars
        mut[179] = (mut[179] == "C") ? "T" : "C"
        let r1Seq = String(mut[0..<220])
        let r2Seq = BioSequence.reverseComplement(String(mut[140..<360]))
        let d1 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: r1Seq, sampleName: "Clone1_Fwd_5p", simulateNoisyEnds: false)
        let d2 = SangerAlignmentEngine.generateSyntheticAB1Data(sequence: r2Seq, sampleName: "Clone1_Rev_3p", simulateNoisyEnds: false)
        let rec1 = SangerAlignmentEngine.parseData(d1, sampleName: "Clone1_Fwd_5p", trimQualityThreshold: 15)
        let rec2 = SangerAlignmentEngine.parseData(d2, sampleName: "Clone1_Rev_3p", trimQualityThreshold: 15)
        return ("pEGFP_360bp_Demo", ref, [rec1, rec2])
    }
}
