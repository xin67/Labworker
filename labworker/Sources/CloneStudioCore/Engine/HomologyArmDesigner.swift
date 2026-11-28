import Foundation

/// 本地无缝克隆引物与同源臂生成引擎
/// 升级特性 (Sub-batch 3B)：
/// 1. 使用 RestrictionEnzyme 真实上下链切口偏移 (snipOffsets.top / snipOffsets.bottom) 精确计算 5'凸出 / 3'凸出 / 平末端同源臂边界
/// 2. 修复双酶切跨质粒原点 (origin-spanning) 回绕片段截取，严格保持用户 5'->3' 酶切方向
/// 3. Gibson / In-Fusion 同源臂重叠区自身 Tm (>= 48–50 ℃) 与局部发夹阻断检测
/// 4. 正反向引物对协同优化（约束 |ΔTm| <= 3 ℃、惩罚异源二聚体与全质粒模板脱靶错配扩增 mispriming）
public struct HomologyArmDesigner {

    /// ClonExpress Entry 载体固定 15 bp 同源重组臂
    public static let entryURS = "ggatcttccagagat" // 上游 URS
    public static let entryDRS = "ctgccgttcgacgat" // 下游 DRS

    public struct OverlapCheckResult: Sendable, Equatable {
        public let sequence: String
        public let tm: Double
        public let hairpinDG: Double
        public let warning: String?
    }

    public struct DesignResult {
        public let primerF: PrimerItem
        public let primerR: PrimerItem
        public let vectorPrimerF: PrimerItem?
        public let vectorPrimerR: PrimerItem?
        public let resolvedCutStart: Int?
        public let resolvedCutEnd: Int?
        public let promptMessage: String?
        public let overlapWarnings: [String]
        public let misprimingWarnings: [String]

        public init(
            primerF: PrimerItem,
            primerR: PrimerItem,
            vectorPrimerF: PrimerItem? = nil,
            vectorPrimerR: PrimerItem? = nil,
            resolvedCutStart: Int? = nil,
            resolvedCutEnd: Int? = nil,
            promptMessage: String? = nil,
            overlapWarnings: [String] = [],
            misprimingWarnings: [String] = []
        ) {
            self.primerF = primerF
            self.primerR = primerR
            self.vectorPrimerF = vectorPrimerF
            self.vectorPrimerR = vectorPrimerR
            self.resolvedCutStart = resolvedCutStart
            self.resolvedCutEnd = resolvedCutEnd
            self.promptMessage = promptMessage
            self.overlapWarnings = overlapWarnings
            self.misprimingWarnings = misprimingWarnings
        }
    }

    // MARK: - Gibson / In-Fusion 同源臂 Tm & 发夹检测与模板脱靶检查

    /// 评估 Gibson / In-Fusion 同源臂重叠区退火 Tm (推荐 >= 48–50 ℃) 与强局部发夹阻塞风险
    public static func evaluateHomologyOverlap(_ arm: String, label: String? = nil) -> OverlapCheckResult {
        let resolvedLabel = label ?? L10n.tr("同源臂", "Homology arm")
        let clean = BioSequence.clean(arm)
        guard clean.count >= 6 else {
            return OverlapCheckResult(sequence: clean, tm: 0.0, hairpinDG: 0.0, warning: nil)
        }
        let tm = TmCalculator.calculate(sequence: clean).tm
        let hp = PrimerQualityEngine.calcHairpin(clean)
        var warns: [String] = []
        if tm < 48.0 {
            warns.append(L10n.tr(
                "\(resolvedLabel) Tm (\(String(format: "%.1f", tm))℃) 低于 Gibson/In-Fusion 推荐下限 48℃，建议延长同源臂长度。",
                "\(resolvedLabel) overlap Tm (\(String(format: "%.1f", tm)) °C) is below the 48 °C Gibson/In-Fusion recommendation; consider lengthening the arm."
            ))
        }
        if hp.structureFound && hp.dg <= -4.0 {
            warns.append(L10n.tr(
                "\(resolvedLabel) 存在较强局部发夹 (ΔG=\(String(format: "%.1f", hp.dg)) kcal/mol)，可能阻碍 3'-exo 回切退火。",
                "\(resolvedLabel) forms a stable local hairpin (ΔG=\(String(format: "%.1f", hp.dg)) kcal/mol) that may impede exonuclease chew-back."
            ))
        }
        return OverlapCheckResult(
            sequence: clean,
            tm: tm,
            hairpinDG: hp.dg,
            warning: warns.isEmpty ? nil : warns.joined(separator: " ")
        )
    }

    /// 检测引物 3' 端 12-mer 在独立模板集合（分别区分线性/环状，不制造假嵌合环，且回文 12-mer 不重复计数）上的精确脱靶错配结合数
    public static func countOffTargetMisprimingHits(
        primer3Prime: String,
        templates: [(sequence: String, isCircular: Bool)],
        seedLength: Int = 12
    ) -> Int {
        let pClean = BioSequence.clean(primer3Prime)
        guard pClean.count >= seedLength else { return 0 }
        let seed = String(pClean.suffix(seedLength))
        let seedRC = BioSequence.reverseComplement(seed)
        let isPalindromeSeed = (seed == seedRC)

        func countOccurrences(of pat: String, in text: String, maxPos: Int) -> Int {
            var cnt = 0
            var searchStart = text.startIndex
            while let r = text.range(of: pat, options: .literal, range: searchStart..<text.endIndex) {
                let pos = text.distance(from: text.startIndex, to: r.lowerBound)
                if pos < maxPos { cnt += 1 }
                searchStart = text.index(after: r.lowerBound)
            }
            return cnt
        }

        var totalHits = 0
        for item in templates {
            let tClean = BioSequence.clean(item.sequence)
            guard tClean.count >= seedLength else { continue }
            let searchText = item.isCircular ? (tClean + String(tClean.prefix(seedLength - 1))) : tClean
            let maxPos = item.isCircular ? tClean.count : (tClean.count - seedLength + 1)
            totalHits += countOccurrences(of: seed, in: searchText, maxPos: maxPos)
            if !isPalindromeSeed {
                totalHits += countOccurrences(of: seedRC, in: searchText, maxPos: maxPos)
            }
        }
        return max(0, totalHits - 1)
    }

    /// 单模板兼容入口（支持指定线性/环状）
    public static func countOffTargetMisprimingHits(primer3Prime: String, template: String, seedLength: Int = 12, isCircular: Bool = true) -> Int {
        countOffTargetMisprimingHits(primer3Prime: primer3Prime, templates: [(template, isCircular)], seedLength: seedLength)
    }

    /// 从序列端点动态截取退火区段（单端兼容接口）
    public static func pickSpecificAnnealingSeq(
        from sequence: String,
        fivePrimeOverhang: String = "",
        targetTm: Double = 60.0,
        tolerance: Double = 1.0,
        isForward: Bool
    ) -> (seq: String, tm: Double) {
        let candidates = enumerateAnnealingCandidates(
            from: sequence,
            fivePrimeOverhang: fivePrimeOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: isForward
        )
        if let best = candidates.first {
            return (best.seq, best.tm)
        }
        let cleanSeq = BioSequence.clean(sequence)
        let oriented = isForward ? cleanSeq : BioSequence.reverseComplement(cleanSeq)
        let res = TmCalculator.calculate(sequence: oriented, fivePrimeOverhang: fivePrimeOverhang)
        return (oriented, res.tm)
    }

    private struct AnnealingCandidate {
        let seq: String
        let tm: Double
        let singleScore: Double
        let inWindow: Bool
    }

    private static func enumerateAnnealingCandidates(
        from sequence: String,
        fivePrimeOverhang: String,
        targetTm: Double,
        tolerance: Double,
        isForward: Bool
    ) -> [AnnealingCandidate] {
        let cleanSeq = BioSequence.clean(sequence)
        let minLen = 18
        let maxLen = min(38, cleanSeq.count)
        guard cleanSeq.count >= minLen else {
            let oriented = isForward ? cleanSeq : BioSequence.reverseComplement(cleanSeq)
            let tm = TmCalculator.calculate(sequence: oriented, fivePrimeOverhang: fivePrimeOverhang).tm
            return [AnnealingCandidate(seq: oriented, tm: tm, singleScore: 0.0, inWindow: true)]
        }

        let clampedTol = max(0.0, min(3.0, tolerance))
        let lowerBound = targetTm - clampedTol
        let upperBound = targetTm + clampedTol

        var inWin: [AnnealingCandidate] = []
        var fallback: [AnnealingCandidate] = []

        for len in minLen...maxLen {
            let sub: String
            if isForward {
                let endIdx = cleanSeq.index(cleanSeq.startIndex, offsetBy: len)
                sub = String(cleanSeq[..<endIdx])
            } else {
                let startIdx = cleanSeq.index(cleanSeq.endIndex, offsetBy: -len)
                sub = BioSequence.reverseComplement(String(cleanSeq[startIdx...]))
            }
            let tm = TmCalculator.calculate(sequence: sub, fivePrimeOverhang: fivePrimeOverhang).tm
            let diff = abs(tm - targetTm)

            if clampedTol <= 0.05 && tm >= targetTm {
                return [AnnealingCandidate(seq: sub, tm: tm, singleScore: -diff, inWindow: true)]
            }

            let endsWithGC = sub.last.map { $0 == "G" || $0 == "C" } ?? false
            let gcBonus = endsWithGC ? 0.35 : 0.0
            let qc = PrimerQualityEngine.evaluatePrimer(fivePrimeOverhang + sub)
            let riskPenalty: Double = (qc.overallRisk == .high) ? 1.50 : (qc.overallRisk == .moderate ? 0.50 : 0.0)
            let pentPenalty: Double = qc.isThreePrimeStabilityHighRisk ? 0.40 : 0.0
            let score = gcBonus - diff - riskPenalty - pentPenalty

            let cand = AnnealingCandidate(seq: sub, tm: tm, singleScore: score, inWindow: tm >= lowerBound && tm <= upperBound)
            if cand.inWindow {
                inWin.append(cand)
            } else {
                fallback.append(cand)
            }
        }

        if !inWin.isEmpty {
            return inWin.sorted { $0.singleScore > $1.singleScore }
        }
        return fallback.sorted { abs($0.tm - targetTm) < abs($1.tm - targetTm) }
    }

    /// 正反向引物对协同优化：联合约束 |ΔTm| <= 3 ℃、最小化异源二聚体风险与模板脱靶错配扩增
    public static func pickOptimalPrimerPair(
        insertSeq: String,
        forwardOverhang: String,
        reverseOverhang: String,
        targetTm: Double = 60.0,
        tolerance: Double = 1.0,
        misprimingTemplate: String? = nil,
        misprimingTemplates: [(sequence: String, isCircular: Bool)]? = nil
    ) -> (fSeq: String, fTm: Double, rSeq: String, rTm: Double, heterodimerDG: Double, misprimingWarnings: [String]) {
        let fCands = Array(enumerateAnnealingCandidates(
            from: insertSeq,
            fivePrimeOverhang: forwardOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: true
        ).prefix(6))
        let rCands = Array(enumerateAnnealingCandidates(
            from: insertSeq,
            fivePrimeOverhang: reverseOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: false
        ).prefix(6))

        guard let firstF = fCands.first, let firstR = rCands.first else {
            let f = pickSpecificAnnealingSeq(from: insertSeq, fivePrimeOverhang: forwardOverhang, targetTm: targetTm, tolerance: tolerance, isForward: true)
            let r = pickSpecificAnnealingSeq(from: insertSeq, fivePrimeOverhang: reverseOverhang, targetTm: targetTm, tolerance: tolerance, isForward: false)
            let het = PrimerQualityEngine.calcDimer(forwardOverhang + f.seq, reverseOverhang + r.seq)
            return (f.seq, f.tm, r.seq, r.tm, het.dg, [])
        }

        let scanTemplates: [(sequence: String, isCircular: Bool)] = misprimingTemplates
            ?? [(misprimingTemplate ?? insertSeq, false)]
        var bestF = firstF
        var bestR = firstR
        var bestHetDG = 0.0
        var bestPairScore = -1e9
        var bestFHits = 0
        var bestRHits = 0

        for fc in fCands {
            let fFull = forwardOverhang + fc.seq
            let fHits = countOffTargetMisprimingHits(primer3Prime: fc.seq, templates: scanTemplates)
            for rc in rCands {
                let rFull = reverseOverhang + rc.seq
                let rHits = countOffTargetMisprimingHits(primer3Prime: rc.seq, templates: scanTemplates)
                let deltaTm = abs(fc.tm - rc.tm)
                let deltaPenalty = (deltaTm > 3.0) ? (2.5 + (deltaTm - 3.0) * 1.5) : (deltaTm * 0.25)
                let het = PrimerQualityEngine.calcDimer(fFull, rFull)
                let hetPenalty: Double = (het.riskLevel == .high) ? 2.0 : (het.riskLevel == .moderate ? 0.75 : 0.0)
                let misprimePenalty = Double(fHits + rHits) * 1.2
                let pairScore = fc.singleScore + rc.singleScore - deltaPenalty - hetPenalty - misprimePenalty
                if pairScore > bestPairScore {
                    bestPairScore = pairScore
                    bestF = fc
                    bestR = rc
                    bestHetDG = het.dg
                    bestFHits = fHits
                    bestRHits = rHits
                }
            }
        }

        var mpWarnings: [String] = []
        if bestFHits > 0 {
            mpWarnings.append(L10n.tr(
                "正向引物 3' 端在模板中存在 \(bestFHits) 处潜在脱靶结合位点。",
                "Forward primer 3' seed has \(bestFHits) potential off-target binding hit(s) on template."
            ))
        }
        if bestRHits > 0 {
            mpWarnings.append(L10n.tr(
                "反向引物 3' 端在模板中存在 \(bestRHits) 处潜在脱靶结合位点。",
                "Reverse primer 3' seed has \(bestRHits) potential off-target binding hit(s) on template."
            ))
        }
        return (bestF.seq, bestF.tm, bestR.seq, bestR.tm, bestHetDG, mpWarnings)
    }

    /// 1. 入门克隆引物设计 (Entry Clone)
    public static func designEntryClone(
        insertSeq: String,
        hasEnzymes: Bool,
        enzyme5: RestrictionEnzyme? = nil,
        enzyme3: RestrictionEnzyme? = nil,
        targetTm: Double = 60.0,
        tolerance: Double = 1.0
    ) -> DesignResult {
        let cleanInsert = BioSequence.clean(insertSeq)
        guard cleanInsert.count >= 50 else {
            return DesignResult(
                primerF: PrimerItem(name: "F", fullSequence: ""),
                primerR: PrimerItem(name: "R", fullSequence: ""),
                promptMessage: L10n.t("插入片段长度必须大于等于 50 bp")
            )
        }

        let e5Site = hasEnzymes ? (enzyme5?.site.lowercased() ?? "") : ""
        let e3Site = hasEnzymes ? (enzyme3?.site.lowercased() ?? "") : ""
        let fOverhang = entryURS + e5Site
        let rOverhang = entryDRS + e3Site

        let pair = pickOptimalPrimerPair(
            insertSeq: cleanInsert,
            forwardOverhang: fOverhang,
            reverseOverhang: rOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            misprimingTemplate: cleanInsert
        )

        let fullF = fOverhang + pair.fSeq
        let fullR = rOverhang + pair.rSeq

        let primerF = PrimerItem(
            name: "CE-Entry-F",
            fullSequence: fullF,
            homologyArm: entryURS,
            enzymeName: hasEnzymes ? enzyme5?.name : nil,
            enzymeSite: hasEnzymes ? e5Site : nil,
            specificSequence: pair.fSeq,
            tm: pair.fTm,
            gcPercent: BioSequence.gcContent(fullF),
            targetPurpose: L10n.t("ClonExpress 入门克隆正向引物"),
            notes: "5' URS (15bp)" + (hasEnzymes ? " + \(enzyme5?.name ?? "")" : "") + L10n.tr(" + 特异序列 (Tm: \(pair.fTm)℃)", " + Specific (Tm: \(pair.fTm) °C)"),
            sourceTool: L10n.t("入门克隆")
        )

        let primerR = PrimerItem(
            name: "CE-Entry-R",
            fullSequence: fullR,
            homologyArm: entryDRS,
            enzymeName: hasEnzymes ? enzyme3?.name : nil,
            enzymeSite: hasEnzymes ? e3Site : nil,
            specificSequence: pair.rSeq,
            tm: pair.rTm,
            gcPercent: BioSequence.gcContent(fullR),
            targetPurpose: L10n.t("ClonExpress 入门克隆反向引物"),
            notes: "5' DRS (15bp)" + (hasEnzymes ? " + \(enzyme3?.name ?? "")" : "") + L10n.tr(" + 特异序列 (Tm: \(pair.rTm)℃)", " + Specific (Tm: \(pair.rTm) °C)"),
            sourceTool: L10n.t("入门克隆")
        )

        return DesignResult(
            primerF: primerF,
            primerR: primerR,
            promptMessage: nil,
            overlapWarnings: [],
            misprimingWarnings: pair.misprimingWarnings
        )
    }

    /// 2. 单酶切单片段克隆设计 (Single Enzyme Digestion — 严格采用 RestrictionEnzyme.snipOffsets 精确切割边界)
    public static func designSingleEnzymeClone(
        vectorSeq: String,
        insertSeq: String,
        enzyme: RestrictionEnzyme,
        homologyLength: Int = 18,
        targetTm: Double = 60.0,
        tolerance: Double = 1.0,
        preferredSiteIndex: Int = 0,
        extra5Bases: String = "",
        extra3Bases: String = ""
    ) -> DesignResult {
        let cleanVec = BioSequence.clean(vectorSeq)
        let cleanInsert = BioSequence.clean(insertSeq)
        let extra5 = BioSequence.clean(extra5Bases).lowercased()
        let extra3RC = BioSequence.reverseComplement(BioSequence.clean(extra3Bases)).lowercased()

        let sites = enzyme.findSites(in: cleanVec)
        let selectedSite = sites.indices.contains(preferredSiteIndex) ? sites[preferredSiteIndex] : sites.first
        let cutPos = selectedSite ?? (cleanVec.count / 2)
        var warnParts: [String] = []
        if sites.isEmpty {
            warnParts.append(L10n.tr("⚠️ 载体序列中未检测到 \(enzyme.name) (\(enzyme.site)) 位点，请确认酶切位点或改用反向 PCR 模式", "⚠️ \(enzyme.name) (\(enzyme.site)) site not found in vector; verify site or switch to inverse PCR"))
        } else if sites.count > 1 {
            warnParts.append(L10n.tr("提示：载体中存在 \(sites.count) 个 \(enzyme.name) 位点，当前使用第 \(min(preferredSiteIndex + 1, sites.count)) 个位点 (\(cutPos + 1) bp)", "Note: \(sites.count) \(enzyme.name) sites in vector; using site #\(min(preferredSiteIndex + 1, sites.count)) (\(cutPos + 1) bp)"))
        }

        // 严格依据上下链真实裂解偏移 (topSnipOffset / bottomSnipOffset) 定位重组暴露双链边界：
        // 5'凸出(如 EcoRI 1,5): 上游止于 cut+1，下游起于 cut+5；平末端(EcoRV 3,3): 上游止于 cut+3，下游起于 cut+3；3'凸出(KpnI 5,1): 经外切修平后上游止于 cut+1，下游起于 cut+5
        let snip = enzyme.snipOffsets
        let upCutEndOffset = max(0, min(snip.top, snip.bottom))
        let downCutStartOffset = max(snip.top, snip.bottom)

        let doubledVec = cleanVec + cleanVec
        let vecLen = max(1, cleanVec.count)
        let armLen = min(homologyLength, vecLen)
        let upEndPos = (cutPos + upCutEndOffset) % vecLen
        let upStartOffset = (upEndPos - armLen + vecLen) % vecLen
        let upStartIdx = doubledVec.index(doubledVec.startIndex, offsetBy: upStartOffset)
        let upEndIdx = doubledVec.index(upStartIdx, offsetBy: armLen)
        let upArm = String(doubledVec[upStartIdx..<upEndIdx]).lowercased()

        let downStartOffset = (cutPos + downCutStartOffset) % vecLen
        let downStartIdx = doubledVec.index(doubledVec.startIndex, offsetBy: downStartOffset)
        let downEndIdx = doubledVec.index(downStartIdx, offsetBy: armLen)
        let rawDown = String(doubledVec[downStartIdx..<downEndIdx])
        let downArm = BioSequence.reverseComplement(rawDown).lowercased()

        let upCheck = evaluateHomologyOverlap(upArm, label: L10n.t("5' 同源臂"))
        let downCheck = evaluateHomologyOverlap(downArm, label: L10n.t("3' 同源臂"))
        let ovWarnings = [upCheck.warning, downCheck.warning].compactMap { $0 }

        let fOverhang = upArm + extra5
        let rOverhang = downArm + extra3RC

        let pair = pickOptimalPrimerPair(
            insertSeq: cleanInsert,
            forwardOverhang: fOverhang,
            reverseOverhang: rOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            misprimingTemplates: [(cleanInsert, false), (cleanVec, true)]
        )

        let fullF = fOverhang + pair.fSeq
        let fullR = rOverhang + pair.rSeq
        let fNoteExtra = extra5.isEmpty ? "" : L10n.tr(" + 5'补码/Linker(\(extra5.count)bp)", " + 5'Linker(\(extra5.count) bp)")
        let rNoteExtra = extra3RC.isEmpty ? "" : L10n.tr(" + 3'补码/Linker(\(extra3RC.count)bp)", " + 3'Linker(\(extra3RC.count) bp)")

        let primerF = PrimerItem(
            name: "Single-Frag-F",
            fullSequence: fullF,
            homologyArm: upArm,
            enzymeName: extra5.isEmpty ? enzyme.name : L10n.tr("\(enzyme.name)+5'附加", "\(enzyme.name)+5'Linker"),
            enzymeSite: extra5.isEmpty ? nil : extra5,
            specificSequence: pair.fSeq,
            tm: pair.fTm,
            targetPurpose: L10n.t("单片段克隆 (单酶切) 正向引物"),
            notes: L10n.tr("载体上游同源臂 (\(upArm.count)bp, 臂Tm \(String(format: "%.1f", upCheck.tm))℃, @\(cutPos + 1))\(fNoteExtra) + 特异性序列 (Tm: \(pair.fTm)℃)", "Vector 5' Arm (\(upArm.count) bp, arm Tm \(String(format: "%.1f", upCheck.tm)) °C, @\(cutPos + 1))\(fNoteExtra) + Specific (Tm: \(pair.fTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )

        let primerR = PrimerItem(
            name: "Single-Frag-R",
            fullSequence: fullR,
            homologyArm: downArm,
            enzymeName: extra3RC.isEmpty ? enzyme.name : L10n.tr("\(enzyme.name)+3'附加", "\(enzyme.name)+3'Linker"),
            enzymeSite: extra3RC.isEmpty ? nil : extra3RC,
            specificSequence: pair.rSeq,
            tm: pair.rTm,
            targetPurpose: L10n.t("单片段克隆 (单酶切) 反向引物"),
            notes: L10n.tr("载体下游同源臂 (\(downArm.count)bp, 臂Tm \(String(format: "%.1f", downCheck.tm))℃, @\(cutPos + downCutStartOffset))\(rNoteExtra) + 特异性序列 (Tm: \(pair.rTm)℃)", "Vector 3' Arm (\(downArm.count) bp, arm Tm \(String(format: "%.1f", downCheck.tm)) °C, @\(cutPos + downCutStartOffset))\(rNoteExtra) + Specific (Tm: \(pair.rTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )

        let warnMsg = warnParts.isEmpty ? nil : warnParts.joined(separator: "；")
        return DesignResult(
            primerF: primerF,
            primerR: primerR,
            resolvedCutStart: cutPos + 1,
            resolvedCutEnd: min(vecLen, cutPos + enzyme.site.count),
            promptMessage: warnMsg,
            overlapWarnings: ovWarnings,
            misprimingWarnings: pair.misprimingWarnings
        )
    }

    /// 3. 双酶切单片段克隆设计 (Double Enzyme Digestion — 支持跨质粒原点回绕与精确 snipOffsets 边界)
    public static func designDoubleEnzymeClone(
        vectorSeq: String,
        insertSeq: String,
        enzyme5: RestrictionEnzyme,
        enzyme3: RestrictionEnzyme,
        homologyLength: Int = 18,
        targetTm: Double = 60.0,
        tolerance: Double = 1.0,
        extra5Bases: String = "",
        extra3Bases: String = ""
    ) -> DesignResult {
        let cleanVec = BioSequence.clean(vectorSeq)
        let cleanInsert = BioSequence.clean(insertSeq)
        let extra5 = BioSequence.clean(extra5Bases).lowercased()
        let extra3RC = BioSequence.reverseComplement(BioSequence.clean(extra3Bases)).lowercased()

        let sites5 = enzyme5.findSites(in: cleanVec)
        let sites3 = enzyme3.findSites(in: cleanVec)

        let vecLen = max(1, cleanVec.count)
        // 严格保留用户 5'->3' 酶切方向（支持 enzyme5 位于质粒末端、enzyme3 跨越原点 0 的环状回绕）
        let cut5 = sites5.first ?? 0
        let cut3 = sites3.first ?? ((cut5 + min(30, vecLen - 1)) % vecLen)

        var warnParts: [String] = []
        if sites5.isEmpty { warnParts.append(L10n.tr("未找到 5' 酶切位点 \(enzyme5.name)", "5' site \(enzyme5.name) not found")) }
        if sites3.isEmpty { warnParts.append(L10n.tr("未找到 3' 酶切位点 \(enzyme3.name)", "3' site \(enzyme3.name) not found")) }
        let warnMsg: String? = warnParts.isEmpty ? nil : ("⚠️ " + warnParts.joined(separator: "；"))

        let snip5 = enzyme5.snipOffsets
        let snip3 = enzyme3.snipOffsets
        let upCutEndOffset = max(0, min(snip5.top, snip5.bottom))
        let downCutStartOffset = max(snip3.top, snip3.bottom)

        let doubledVec = cleanVec + cleanVec
        let armLen = min(homologyLength, vecLen)

        let upEndPos = (cut5 + upCutEndOffset) % vecLen
        let upStartOffset = (upEndPos - armLen + vecLen) % vecLen
        let upStartIdx = doubledVec.index(doubledVec.startIndex, offsetBy: upStartOffset)
        let upEndIdx = doubledVec.index(upStartIdx, offsetBy: armLen)
        let upArm = String(doubledVec[upStartIdx..<upEndIdx]).lowercased()

        let downStartOffset = (cut3 + downCutStartOffset) % vecLen
        let downStartIdx = doubledVec.index(doubledVec.startIndex, offsetBy: downStartOffset)
        let downEndIdx = doubledVec.index(downStartIdx, offsetBy: armLen)
        let rawDown = String(doubledVec[downStartIdx..<downEndIdx])
        let downArm = BioSequence.reverseComplement(rawDown).lowercased()

        let upCheck = evaluateHomologyOverlap(upArm, label: L10n.t("5' 同源臂"))
        let downCheck = evaluateHomologyOverlap(downArm, label: L10n.t("3' 同源臂"))
        let ovWarnings = [upCheck.warning, downCheck.warning].compactMap { $0 }

        let fOverhang = upArm + extra5
        let rOverhang = downArm + extra3RC

        let pair = pickOptimalPrimerPair(
            insertSeq: cleanInsert,
            forwardOverhang: fOverhang,
            reverseOverhang: rOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            misprimingTemplates: [(cleanInsert, false), (cleanVec, true)]
        )

        let fullF = fOverhang + pair.fSeq
        let fullR = rOverhang + pair.rSeq
        let fNoteExtra = extra5.isEmpty ? "" : L10n.tr(" + 5'补码/Linker(\(extra5.count)bp)", " + 5'Linker(\(extra5.count) bp)")
        let rNoteExtra = extra3RC.isEmpty ? "" : L10n.tr(" + 3'补码/Linker(\(extra3RC.count)bp)", " + 3'Linker(\(extra3RC.count) bp)")

        let primerF = PrimerItem(
            name: "Single-Frag-F",
            fullSequence: fullF,
            homologyArm: upArm,
            enzymeName: extra5.isEmpty ? enzyme5.name : L10n.tr("\(enzyme5.name)+5'附加", "\(enzyme5.name)+5'Linker"),
            enzymeSite: extra5.isEmpty ? nil : extra5,
            specificSequence: pair.fSeq,
            tm: pair.fTm,
            targetPurpose: L10n.t("单片段克隆 (双酶切) 正向引物"),
            notes: L10n.tr("5' 载体同源臂 (\(upArm.count)bp, 臂Tm \(String(format: "%.1f", upCheck.tm))℃, @\(cut5 + 1))\(fNoteExtra) + 特异性序列 (Tm: \(pair.fTm)℃)", "5' Vector Arm (\(upArm.count) bp, arm Tm \(String(format: "%.1f", upCheck.tm)) °C, @\(cut5 + 1))\(fNoteExtra) + Specific (Tm: \(pair.fTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )

        let primerR = PrimerItem(
            name: "Single-Frag-R",
            fullSequence: fullR,
            homologyArm: downArm,
            enzymeName: extra3RC.isEmpty ? enzyme3.name : L10n.tr("\(enzyme3.name)+3'附加", "\(enzyme3.name)+3'Linker"),
            enzymeSite: extra3RC.isEmpty ? nil : extra3RC,
            specificSequence: pair.rSeq,
            tm: pair.rTm,
            targetPurpose: L10n.t("单片段克隆 (双酶切) 反向引物"),
            notes: L10n.tr("3' 载体同源臂 (\(downArm.count)bp, 臂Tm \(String(format: "%.1f", downCheck.tm))℃, @\(cut3 + downCutStartOffset))\(rNoteExtra) + 特异性序列 (Tm: \(pair.rTm)℃)", "3' Vector Arm (\(downArm.count) bp, arm Tm \(String(format: "%.1f", downCheck.tm)) °C, @\(cut3 + downCutStartOffset))\(rNoteExtra) + Specific (Tm: \(pair.rTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )

        return DesignResult(
            primerF: primerF,
            primerR: primerR,
            resolvedCutStart: cut5 + 1,
            resolvedCutEnd: ((cut3 + enzyme3.site.count - 1) % vecLen) + 1,
            promptMessage: warnMsg,
            overlapWarnings: ovWarnings,
            misprimingWarnings: pair.misprimingWarnings
        )
    }

    /// 4. 反向 PCR 线性化载体克隆设计 (Reverse PCR Linearized Vector)
    public static func designPCRVectorClone(
        vectorSeqU: String,
        vectorSeqD: String,
        insertSeq: String,
        homologyLength: Int = 18,
        targetTm: Double = 60.0,
        tolerance: Double = 1.0,
        extra5Bases: String = "",
        extra3Bases: String = ""
    ) -> DesignResult {
        let cleanU = BioSequence.clean(vectorSeqU)
        let cleanD = BioSequence.clean(vectorSeqD)
        let cleanInsert = BioSequence.clean(insertSeq)
        let extra5 = BioSequence.clean(extra5Bases).lowercased()
        let extra3RC = BioSequence.reverseComplement(BioSequence.clean(extra3Bases)).lowercased()

        let armLen = homologyLength
        let upArm = cleanU.count >= armLen ? String(cleanU.suffix(armLen)).lowercased() : cleanU.lowercased()
        let downArm = cleanD.count >= armLen ? BioSequence.reverseComplement(String(cleanD.prefix(armLen))).lowercased() : BioSequence.reverseComplement(cleanD).lowercased()

        let upCheck = evaluateHomologyOverlap(upArm, label: L10n.t("5' 同源臂"))
        let downCheck = evaluateHomologyOverlap(downArm, label: L10n.t("3' 同源臂"))
        let ovWarnings = [upCheck.warning, downCheck.warning].compactMap { $0 }

        let fOverhang = upArm + extra5
        let rOverhang = downArm + extra3RC

        let pair = pickOptimalPrimerPair(
            insertSeq: cleanInsert,
            forwardOverhang: fOverhang,
            reverseOverhang: rOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            misprimingTemplates: [(cleanInsert, false), (cleanU, false), (cleanD, false)]
        )

        let fullF = fOverhang + pair.fSeq
        let fullR = rOverhang + pair.rSeq
        let fNoteExtra = extra5.isEmpty ? "" : L10n.tr(" + 5'补码/Linker(\(extra5.count)bp)", " + 5'Linker(\(extra5.count) bp)")
        let rNoteExtra = extra3RC.isEmpty ? "" : L10n.tr(" + 3'补码/Linker(\(extra3RC.count)bp)", " + 3'Linker(\(extra3RC.count) bp)")

        let primerF = PrimerItem(
            name: "Single-Frag-F",
            fullSequence: fullF,
            homologyArm: upArm,
            enzymeName: extra5.isEmpty ? nil : L10n.t("5'补码/Linker"),
            enzymeSite: extra5.isEmpty ? nil : extra5,
            specificSequence: pair.fSeq,
            tm: pair.fTm,
            targetPurpose: L10n.t("单片段克隆 (反向PCR) 插入正向引物"),
            notes: L10n.tr("5' 载体同源臂 (\(upArm.count)bp, 臂Tm \(String(format: "%.1f", upCheck.tm))℃)\(fNoteExtra) + 特异性序列 (Tm: \(pair.fTm)℃)", "5' Vector Arm (\(upArm.count) bp, arm Tm \(String(format: "%.1f", upCheck.tm)) °C)\(fNoteExtra) + Specific (Tm: \(pair.fTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )

        let primerR = PrimerItem(
            name: "Single-Frag-R",
            fullSequence: fullR,
            homologyArm: downArm,
            enzymeName: extra3RC.isEmpty ? nil : L10n.t("3'补码/Linker"),
            enzymeSite: extra3RC.isEmpty ? nil : extra3RC,
            specificSequence: pair.rSeq,
            tm: pair.rTm,
            targetPurpose: L10n.t("单片段克隆 (反向PCR) 插入反向引物"),
            notes: L10n.tr("3' 载体同源臂 (\(downArm.count)bp, 臂Tm \(String(format: "%.1f", downCheck.tm))℃)\(rNoteExtra) + 特异性序列 (Tm: \(pair.rTm)℃)", "3' Vector Arm (\(downArm.count) bp, arm Tm \(String(format: "%.1f", downCheck.tm)) °C)\(rNoteExtra) + Specific (Tm: \(pair.rTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )

        var vecPrimerF: PrimerItem? = nil
        var vecPrimerR: PrimerItem? = nil
        if cleanD.count >= 18 {
            let (vfSeq, vfTm) = pickSpecificAnnealingSeq(
                from: cleanD,
                fivePrimeOverhang: "",
                targetTm: targetTm,
                tolerance: tolerance,
                isForward: true
            )
            vecPrimerF = PrimerItem(
                name: "Vector-PCR-F",
                fullSequence: vfSeq,
                specificSequence: vfSeq,
                tm: vfTm,
                targetPurpose: L10n.t("载体反向PCR扩增正向引物 (下游断点顺时针)"),
                notes: L10n.tr("结合于目标替换位点 3' 下游载体骨架 (Tm: \(vfTm)℃)", "Binds downstream of 3' replacement junction on vector (Tm: \(vfTm) °C)"),
                sourceTool: L10n.t("单片段克隆")
            )
        }
        if cleanU.count >= 18 {
            let (vrSeq, vrTm) = pickSpecificAnnealingSeq(
                from: cleanU,
                fivePrimeOverhang: "",
                targetTm: targetTm,
                tolerance: tolerance,
                isForward: false
            )
            vecPrimerR = PrimerItem(
                name: "Vector-PCR-R",
                fullSequence: vrSeq,
                specificSequence: vrSeq,
                tm: vrTm,
                targetPurpose: L10n.t("载体反向PCR扩增反向引物 (上游断点逆时针)"),
                notes: L10n.tr("结合于目标替换位点 5' 上游载体骨架 (Tm: \(vrTm)℃)", "Binds upstream of 5' replacement junction on vector (Tm: \(vrTm) °C)"),
                sourceTool: L10n.t("单片段克隆")
            )
        }

        return DesignResult(
            primerF: primerF,
            primerR: primerR,
            vectorPrimerF: vecPrimerF,
            vectorPrimerR: vecPrimerR,
            promptMessage: nil,
            overlapWarnings: ovWarnings,
            misprimingWarnings: pair.misprimingWarnings
        )
    }

    /// 5. 定点突变引物设计 (Site-Directed Mutagenesis)
    public static func designMutagenesis(
        mutUp: String,
        mutDown: String,
        mutSite: String,
        homologyLength: Int = 18,
        targetTm: Double = 68.0,
        tolerance: Double = 1.0
    ) -> DesignResult {
        let cleanUp = BioSequence.clean(mutUp)
        let cleanDown = BioSequence.clean(mutDown)
        let cleanMut = BioSequence.clean(mutSite)

        guard cleanUp.count >= 20 && cleanDown.count >= 20 else {
            return DesignResult(
                primerF: PrimerItem(name: "Mutation-F", fullSequence: ""),
                primerR: PrimerItem(name: "Mutation-R", fullSequence: ""),
                promptMessage: L10n.t("上下游序列长度至少需要 20 bp")
            )
        }

        let mutLen = cleanMut.count
        let rem = max(0, homologyLength - mutLen)
        let halfUp = rem / 2
        let halfDown = rem - halfUp

        let upOverlap = halfUp > 0 && cleanUp.count >= halfUp ? String(cleanUp.suffix(halfUp)) : ""
        let downOverlap = halfDown > 0 && cleanDown.count >= halfDown ? String(cleanDown.prefix(halfDown)) : ""

        let fOverlap = (upOverlap + cleanMut + downOverlap).lowercased()
        let rOverlap = BioSequence.reverseComplement(fOverlap).lowercased()

        let remainDown = cleanDown.count >= halfDown ? String(cleanDown.dropFirst(halfDown)) : cleanDown
        let (fSpec, fTm) = pickSpecificAnnealingSeq(
            from: remainDown,
            fivePrimeOverhang: fOverlap,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: true
        )

        let remainUp = cleanUp.count >= halfUp ? String(cleanUp.dropLast(halfUp)) : cleanUp
        let (rSpec, rTm) = pickSpecificAnnealingSeq(
            from: remainUp,
            fivePrimeOverhang: rOverlap,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: false
        )

        let fullF = fOverlap + fSpec
        let fullR = rOverlap + rSpec

        let primerF = PrimerItem(
            name: "Mutation-F",
            fullSequence: fullF,
            homologyArm: fOverlap,
            specificSequence: fSpec,
            tm: fTm,
            targetPurpose: L10n.t("定点突变正向引物"),
            notes: L10n.tr("5' 突变同源臂 (\(fOverlap.count)bp) + 3' 特异结合端 (Tm: \(fTm)℃)", "5' Mutant Arm (\(fOverlap.count) bp) + 3' Binding (Tm: \(fTm) °C)"),
            sourceTool: L10n.t("定点突变")
        )

        let primerR = PrimerItem(
            name: "Mutation-R",
            fullSequence: fullR,
            homologyArm: rOverlap,
            specificSequence: rSpec,
            tm: rTm,
            targetPurpose: L10n.t("定点突变反向引物"),
            notes: L10n.tr("5' 突变同源臂 (\(rOverlap.count)bp) + 3' 特异结合端 (Tm: \(rTm)℃)", "5' Mutant Arm (\(rOverlap.count) bp) + 3' Binding (Tm: \(rTm) °C)"),
            sourceTool: L10n.t("定点突变")
        )

        return DesignResult(primerF: primerF, primerR: primerR, promptMessage: nil)
    }

    // MARK: - 6. 质粒大片段删除与敲除 (Plasmid Fragment Deletion / Loop-out Inverse PCR)

    public struct FragmentDeletionDesignResult: Sendable {
        public let primerF: PrimerItem
        public let primerR: PrimerItem
        public let deletedSeq: String
        public let deletedLength: Int
        public let newPlasmidSeq: String
        public let newLength: Int
        public let delStart: Int
        public let delEnd: Int
        public let promptMessage: String?

        public init(
            primerF: PrimerItem,
            primerR: PrimerItem,
            deletedSeq: String,
            deletedLength: Int,
            newPlasmidSeq: String,
            newLength: Int,
            delStart: Int,
            delEnd: Int,
            promptMessage: String? = nil
        ) {
            self.primerF = primerF
            self.primerR = primerR
            self.deletedSeq = deletedSeq
            self.deletedLength = deletedLength
            self.newPlasmidSeq = newPlasmidSeq
            self.newLength = newLength
            self.delStart = delStart
            self.delEnd = delEnd
            self.promptMessage = promptMessage
        }
    }

    /// 质粒大片段删除与反向 PCR 环化引物设计
    public static func designFragmentDeletion(
        plasmidSeq: String,
        delStart: Int,
        delEnd: Int,
        homologyLength: Int = 18,
        targetTm: Double = 68.0,
        tolerance: Double = 1.0
    ) -> FragmentDeletionDesignResult {
        let cleanPlasmid = BioSequence.clean(plasmidSeq)
        guard cleanPlasmid.count >= 100 else {
            return FragmentDeletionDesignResult(
                primerF: PrimerItem(name: "Deletion-F", fullSequence: ""),
                primerR: PrimerItem(name: "Deletion-R", fullSequence: ""),
                deletedSeq: "",
                deletedLength: 0,
                newPlasmidSeq: "",
                newLength: 0,
                delStart: delStart,
                delEnd: delEnd,
                promptMessage: L10n.t("质粒序列长度至少需要 100 bp")
            )
        }

        guard delStart >= 1 && delEnd <= cleanPlasmid.count && delStart <= delEnd else {
            return FragmentDeletionDesignResult(
                primerF: PrimerItem(name: "Deletion-F", fullSequence: ""),
                primerR: PrimerItem(name: "Deletion-R", fullSequence: ""),
                deletedSeq: "",
                deletedLength: 0,
                newPlasmidSeq: "",
                newLength: 0,
                delStart: delStart,
                delEnd: delEnd,
                promptMessage: L10n.tr("删除坐标区间 [\(delStart), \(delEnd)] 无效 (质粒总长: \(cleanPlasmid.count) bp)", "Invalid deletion range [\(delStart), \(delEnd)] (plasmid length: \(cleanPlasmid.count) bp)")
            )
        }

        let delLen = delEnd - delStart + 1
        let sIdx = cleanPlasmid.index(cleanPlasmid.startIndex, offsetBy: delStart - 1)
        let eIdx = cleanPlasmid.index(cleanPlasmid.startIndex, offsetBy: delEnd)

        let deletedSeq = String(cleanPlasmid[sIdx..<eIdx])
        let upRetained = String(cleanPlasmid[cleanPlasmid.startIndex..<sIdx])
        let downRetained = String(cleanPlasmid[eIdx..<cleanPlasmid.endIndex])
        let newPlasmidSeq = upRetained + downRetained
        let newLength = newPlasmidSeq.count

        let upPool = downRetained + upRetained
        let downPool = downRetained + upRetained

        let armLen = min(homologyLength, newLength)
        let upArm = upRetained.count >= armLen
            ? String(upRetained.suffix(armLen)).lowercased()
            : String(upPool.suffix(armLen)).lowercased()

        let (fSpec, fTm) = pickSpecificAnnealingSeq(
            from: downRetained.count >= 38 ? downRetained : downPool,
            fivePrimeOverhang: upArm,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: true
        )
        let fullF = upArm + fSpec

        let (rSpec, rTm) = pickSpecificAnnealingSeq(
            from: upRetained.count >= 38 ? upRetained : upPool,
            fivePrimeOverhang: "",
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: false
        )
        let fullR = rSpec

        let primerF = PrimerItem(
            name: "Deletion-F",
            fullSequence: fullF,
            homologyArm: upArm,
            specificSequence: fSpec,
            tm: fTm,
            gcPercent: BioSequence.gcContent(fullF),
            targetPurpose: L10n.t("质粒片段删除反向PCR正向引物"),
            notes: L10n.tr("5' 上游同源臂 (\(upArm.count)bp) + 3' 特异结合端 (Tm: \(fTm)℃)", "5' Upstream Arm (\(upArm.count) bp) + 3' Binding (Tm: \(fTm) °C)"),
            sourceTool: L10n.t("片段删除")
        )

        let primerR = PrimerItem(
            name: "Deletion-R",
            fullSequence: fullR,
            homologyArm: "",
            specificSequence: rSpec,
            tm: rTm,
            gcPercent: BioSequence.gcContent(fullR),
            targetPurpose: L10n.t("质粒片段删除反向PCR反向引物"),
            notes: L10n.tr("上游断点逆时针退火结合端 (Tm: \(rTm)℃)", "Binds upstream breakpoint counterclockwise (Tm: \(rTm) °C)"),
            sourceTool: L10n.t("片段删除")
        )

        return FragmentDeletionDesignResult(
            primerF: primerF,
            primerR: primerR,
            deletedSeq: deletedSeq,
            deletedLength: delLen,
            newPlasmidSeq: newPlasmidSeq,
            newLength: newLength,
            delStart: delStart,
            delEnd: delEnd,
            promptMessage: nil
        )
    }

    // MARK: - 7. 多片段无缝克隆引物设计 (Multi-Fragment Seamless Cloning)
    public static func designMultiFragmentClone(
        fragments: [String],
        vectorSeqU: String,
        vectorSeqD: String,
        homologyLength: Int = 18,
        targetTm: Double = 60.0,
        tolerance: Double = 1.0,
        fragmentExtra5Bases: [Int: String] = [:],
        terminalExtra3Bases: String = ""
    ) -> [PrimerItem] {
        let validFrags = Array(fragments.map { BioSequence.clean($0) }.filter { !$0.isEmpty }.prefix(10))
        guard !validFrags.isEmpty else { return [] }

        let cleanU = BioSequence.clean(vectorSeqU)
        let cleanD = BioSequence.clean(vectorSeqD)
        let armLen = max(15, homologyLength)

        let vecUpArm = cleanU.count >= armLen ? String(cleanU.suffix(armLen)).lowercased() : cleanU.lowercased()
        let vecDownRaw = cleanD.count >= armLen ? String(cleanD.prefix(armLen)) : cleanD
        let vecDownArm = BioSequence.reverseComplement(vecDownRaw).lowercased()
        let cleanTermExtra3RC = BioSequence.reverseComplement(BioSequence.clean(terminalExtra3Bases)).lowercased()

        var primers: [PrimerItem] = []
        let count = validFrags.count

        for i in 0..<count {
            let frag = validFrags[i]
            let extra5 = BioSequence.clean(fragmentExtra5Bases[i] ?? "").lowercased()
            let fArm: String
            let fArmNote: String
            if i == 0 {
                fArm = vecUpArm
                fArmNote = L10n.tr("载体5'同源臂(\(fArm.count)bp)", "Vector 5' Arm (\(fArm.count) bp)")
            } else {
                let prevFrag = validFrags[i - 1]
                fArm = (prevFrag.count >= armLen ? String(prevFrag.suffix(armLen)) : prevFrag).lowercased()
                fArmNote = L10n.tr("片段\(i)末端同源臂(\(fArm.count)bp)", "Frag \(i) End Arm (\(fArm.count) bp)")
            }

            let rArm: String
            let rArmNote: String
            let rExtraRC: String
            if i == count - 1 {
                rArm = vecDownArm
                rArmNote = L10n.tr("载体3'同源臂(\(rArm.count)bp)", "Vector 3' Arm (\(rArm.count) bp)")
                rExtraRC = cleanTermExtra3RC
            } else {
                rArm = ""
                rArmNote = L10n.t("无缝拼接端")
                rExtraRC = ""
            }

            let fOverhang = fArm + extra5
            let rOverhang = rArm + rExtraRC

            let pair = pickOptimalPrimerPair(
                insertSeq: frag,
                forwardOverhang: fOverhang,
                reverseOverhang: rOverhang,
                targetTm: targetTm,
                tolerance: tolerance,
                misprimingTemplate: frag
            )

            let fullF = fOverhang + pair.fSeq
            let fullR = rOverhang + pair.rSeq
            let fExtraNote = extra5.isEmpty ? "" : L10n.tr(" + 5'补码/Linker(\(extra5.count)bp)", " + 5'Linker(\(extra5.count) bp)")
            let rExtraNote = rExtraRC.isEmpty ? "" : L10n.tr(" + 3'补码/Linker(\(rExtraRC.count)bp)", " + 3'Linker(\(rExtraRC.count) bp)")
            let pairQC = PrimerQualityEngine.evaluatePrimerPair(forward: fullF, reverse: fullR)
            let fQCNote = L10n.tr(" · 二级结构:\(pairQC.forwardReport.overallRisk.rawValue)(发夹\(String(format: "%.1f", pairQC.forwardReport.hairpin.dg))/异二聚\(String(format: "%.1f", pairQC.heterodimer.dg)))", " · Structure:\(L10n.t(pairQC.forwardReport.overallRisk.rawValue))(Hairpin \(String(format: "%.1f", pairQC.forwardReport.hairpin.dg))/Heterodimer \(String(format: "%.1f", pairQC.heterodimer.dg)))")
            let rQCNote = L10n.tr(" · 二级结构:\(pairQC.reverseReport.overallRisk.rawValue)(发夹\(String(format: "%.1f", pairQC.reverseReport.hairpin.dg))/异二聚\(String(format: "%.1f", pairQC.heterodimer.dg)))", " · Structure:\(L10n.t(pairQC.reverseReport.overallRisk.rawValue))(Hairpin \(String(format: "%.1f", pairQC.reverseReport.hairpin.dg))/Heterodimer \(String(format: "%.1f", pairQC.heterodimer.dg)))")

            primers.append(PrimerItem(
                name: "Multi-Frag\(i + 1)-F",
                fullSequence: fullF,
                homologyArm: fArm,
                enzymeName: extra5.isEmpty ? nil : L10n.t("5'补码/Linker"),
                enzymeSite: extra5.isEmpty ? nil : extra5,
                specificSequence: pair.fSeq,
                tm: pair.fTm,
                gcPercent: BioSequence.gcContent(fullF),
                targetPurpose: L10n.tr("片段 \(i + 1) 正向扩增引物", "Fragment \(i + 1) Forward Primer"),
                notes: L10n.tr("\(fArmNote)\(fExtraNote) + 特异序列 (Tm: \(pair.fTm)℃)\(fQCNote)", "\(fArmNote)\(fExtraNote) + Specific (Tm: \(pair.fTm) °C)\(fQCNote)"),
                sourceTool: L10n.t("多片段克隆")
            ))

            primers.append(PrimerItem(
                name: "Multi-Frag\(i + 1)-R",
                fullSequence: fullR,
                homologyArm: rArm,
                enzymeName: rExtraRC.isEmpty ? nil : L10n.t("3'补码/Linker"),
                enzymeSite: rExtraRC.isEmpty ? nil : rExtraRC,
                specificSequence: pair.rSeq,
                tm: pair.rTm,
                gcPercent: BioSequence.gcContent(fullR),
                targetPurpose: L10n.tr("片段 \(i + 1) 反向扩增引物", "Fragment \(i + 1) Reverse Primer"),
                notes: (rArm.isEmpty ? "" : "\(rArmNote)\(rExtraNote) + ") + L10n.tr("特异序列 (Tm: \(pair.rTm)℃)\(rQCNote)", "Specific (Tm: \(pair.rTm) °C)\(rQCNote)"),
                sourceTool: L10n.t("多片段克隆")
            ))
        }

        return primers
    }
}
