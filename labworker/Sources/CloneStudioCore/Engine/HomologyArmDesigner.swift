import Foundation

/// 本地无缝克隆引物与同源臂生成引擎 (完全遵循 SnapGene 热力学算法：SantaLucia & Hicks 2004 + Bommarito 2000 5' 悬垂端模型)
public struct HomologyArmDesigner {
    
    /// ClonExpress Entry 载体固定 15 bp 同源重组臂
    public static let entryURS = "ggatcttccagagat" // 上游 URS
    public static let entryDRS = "ctgccgttcgacgat" // 下游 DRS
    
    public struct DesignResult {
        public let primerF: PrimerItem
        public let primerR: PrimerItem
        public let vectorPrimerF: PrimerItem?
        public let vectorPrimerR: PrimerItem?
        public let resolvedCutStart: Int?
        public let resolvedCutEnd: Int?
        public let promptMessage: String?
        
        public init(
            primerF: PrimerItem,
            primerR: PrimerItem,
            vectorPrimerF: PrimerItem? = nil,
            vectorPrimerR: PrimerItem? = nil,
            resolvedCutStart: Int? = nil,
            resolvedCutEnd: Int? = nil,
            promptMessage: String? = nil
        ) {
            self.primerF = primerF
            self.primerR = primerR
            self.vectorPrimerF = vectorPrimerF
            self.vectorPrimerR = vectorPrimerR
            self.resolvedCutStart = resolvedCutStart
            self.resolvedCutEnd = resolvedCutEnd
            self.promptMessage = promptMessage
        }
    }
    
    /// 从序列端点动态截取退火区段，按 SnapGene 算法（含 5' 悬垂端热力学贡献）计算 Tm，使其落在 [targetTm - tolerance, targetTm + tolerance] 浮动区间内并优选 3' GC 锚定端
    public static func pickSpecificAnnealingSeq(
        from sequence: String,
        fivePrimeOverhang: String = "",
        targetTm: Double = 60.0,
        tolerance: Double = 1.0,
        isForward: Bool
    ) -> (seq: String, tm: Double) {
        let cleanSeq = BioSequence.clean(sequence)
        let minLen = 18
        let maxLen = min(38, cleanSeq.count)
        guard cleanSeq.count >= minLen else {
            let oriented = isForward ? cleanSeq : BioSequence.reverseComplement(cleanSeq)
            let res = TmCalculator.calculate(sequence: oriented, fivePrimeOverhang: fivePrimeOverhang)
            return (oriented, res.tm)
        }
        
        let clampedTol = max(0.0, min(3.0, tolerance))
        let lowerBound = targetTm - clampedTol
        let upperBound = targetTm + clampedTol
        
        var closestSeq = ""
        var closestTm = 0.0
        var minDiff = 999.0
        
        var bestWindowSeq = ""
        var bestWindowTm = 0.0
        var bestWindowScore = -999.0
        
        for len in minLen...maxLen {
            let sub: String
            if isForward {
                let endIdx = cleanSeq.index(cleanSeq.startIndex, offsetBy: len)
                sub = String(cleanSeq[..<endIdx])
            } else {
                let startIdx = cleanSeq.index(cleanSeq.endIndex, offsetBy: -len)
                let raw3 = String(cleanSeq[startIdx...])
                sub = BioSequence.reverseComplement(raw3)
            }
            
            let tm = TmCalculator.calculate(sequence: sub, fivePrimeOverhang: fivePrimeOverhang).tm
            let diff = abs(tm - targetTm)
            
            if diff < minDiff {
                minDiff = diff
                closestSeq = sub
                closestTm = tm
            }
            
            if clampedTol <= 0.05 {
                if tm >= targetTm {
                    return (sub, tm)
                }
            } else if tm >= lowerBound && tm <= upperBound {
                let endsWithGC = sub.last.map { $0 == "G" || $0 == "C" || $0 == "g" || $0 == "c" } ?? false
                let gcBonus = endsWithGC ? 0.35 : 0.0
                let qc = PrimerQualityEngine.evaluatePrimer(fivePrimeOverhang + sub)
                let riskPenalty: Double = (qc.overallRisk == .high) ? 1.50 : (qc.overallRisk == .moderate ? 0.50 : 0.0)
                let score = gcBonus - diff - riskPenalty
                if score > bestWindowScore {
                    bestWindowScore = score
                    bestWindowSeq = sub
                    bestWindowTm = tm
                }
            }
        }
        
        if !bestWindowSeq.isEmpty {
            return (bestWindowSeq, bestWindowTm)
        }
        return (closestSeq, closestTm)
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
        
        let (fSpec, fTm) = pickSpecificAnnealingSeq(
            from: cleanInsert,
            fivePrimeOverhang: fOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: true
        )
        let (rSpec, rTm) = pickSpecificAnnealingSeq(
            from: cleanInsert,
            fivePrimeOverhang: rOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: false
        )
        
        let fullF = fOverhang + fSpec
        let fullR = rOverhang + rSpec
        
        let primerF = PrimerItem(
            name: "CE-Entry-F",
            fullSequence: fullF,
            homologyArm: entryURS,
            enzymeName: hasEnzymes ? enzyme5?.name : nil,
            enzymeSite: hasEnzymes ? e5Site : nil,
            specificSequence: fSpec,
            tm: fTm,
            gcPercent: BioSequence.gcContent(fullF),
            targetPurpose: L10n.t("ClonExpress 入门克隆正向引物"),
            notes: "5' URS (15bp)" + (hasEnzymes ? " + \(enzyme5?.name ?? "")" : "") + L10n.tr(" + 特异序列 (Tm: \(fTm)℃)", " + Specific (Tm: \(fTm) °C)"),
            sourceTool: L10n.t("入门克隆")
        )
        
        let primerR = PrimerItem(
            name: "CE-Entry-R",
            fullSequence: fullR,
            homologyArm: entryDRS,
            enzymeName: hasEnzymes ? enzyme3?.name : nil,
            enzymeSite: hasEnzymes ? e3Site : nil,
            specificSequence: rSpec,
            tm: rTm,
            gcPercent: BioSequence.gcContent(fullR),
            targetPurpose: L10n.t("ClonExpress 入门克隆反向引物"),
            notes: "5' DRS (15bp)" + (hasEnzymes ? " + \(enzyme3?.name ?? "")" : "") + L10n.tr(" + 特异序列 (Tm: \(rTm)℃)", " + Specific (Tm: \(rTm) °C)"),
            sourceTool: L10n.t("入门克隆")
        )
        
        return DesignResult(primerF: primerF, primerR: primerR, promptMessage: nil)
    }
    
    /// 2. 单酶切单片段克隆设计 (Single Enzyme Digestion)
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
        let warnMsg: String? = sites.isEmpty
            ? L10n.tr("⚠️ 载体序列中未检测到 \(enzyme.name) (\(enzyme.site)) 位点，请确认酶切位点或改用反向 PCR 模式", "⚠️ \(enzyme.name) (\(enzyme.site)) site not found in vector; verify site or switch to inverse PCR")
            : (sites.count > 1 ? L10n.tr("提示：载体中存在 \(sites.count) 个 \(enzyme.name) 位点，当前使用第 \(min(preferredSiteIndex + 1, sites.count)) 个位点 (\(cutPos + 1) bp)", "Note: \(sites.count) \(enzyme.name) sites in vector; using site #\(min(preferredSiteIndex + 1, sites.count)) (\(cutPos + 1) bp)") : nil)
        
        let doubledVec = cleanVec + cleanVec
        let vecLen = max(1, cleanVec.count)
        let armLen = min(homologyLength, vecLen)
        let upStartOffset = (cutPos - armLen + vecLen) % vecLen
        let upStartIdx = doubledVec.index(doubledVec.startIndex, offsetBy: upStartOffset)
        let upEndIdx = doubledVec.index(upStartIdx, offsetBy: armLen)
        let upArm = String(doubledVec[upStartIdx..<upEndIdx]).lowercased()
        
        let downStartOffset = (cutPos + enzyme.site.count) % vecLen
        let downStartIdx = doubledVec.index(doubledVec.startIndex, offsetBy: downStartOffset)
        let downEndIdx = doubledVec.index(downStartIdx, offsetBy: armLen)
        let rawDown = String(doubledVec[downStartIdx..<downEndIdx])
        let downArm = BioSequence.reverseComplement(rawDown).lowercased()
        
        let fOverhang = upArm + extra5
        let rOverhang = downArm + extra3RC
        
        let (fSpec, fTm) = pickSpecificAnnealingSeq(
            from: cleanInsert,
            fivePrimeOverhang: fOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: true
        )
        let (rSpec, rTm) = pickSpecificAnnealingSeq(
            from: cleanInsert,
            fivePrimeOverhang: rOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: false
        )
        
        let fullF = fOverhang + fSpec
        let fullR = rOverhang + rSpec
        let fNoteExtra = extra5.isEmpty ? "" : L10n.tr(" + 5'补码/Linker(\(extra5.count)bp)", " + 5'Linker(\(extra5.count) bp)")
        let rNoteExtra = extra3RC.isEmpty ? "" : L10n.tr(" + 3'补码/Linker(\(extra3RC.count)bp)", " + 3'Linker(\(extra3RC.count) bp)")
        
        let primerF = PrimerItem(
            name: "Single-Frag-F",
            fullSequence: fullF,
            homologyArm: upArm,
            enzymeName: extra5.isEmpty ? enzyme.name : L10n.tr("\(enzyme.name)+5'附加", "\(enzyme.name)+5'Linker"),
            enzymeSite: extra5.isEmpty ? nil : extra5,
            specificSequence: fSpec,
            tm: fTm,
            targetPurpose: L10n.t("单片段克隆 (单酶切) 正向引物"),
            notes: L10n.tr("载体上游同源臂 (\(upArm.count)bp, @\(cutPos + 1))\(fNoteExtra) + 特异性序列 (Tm: \(fTm)℃)", "Vector 5' Arm (\(upArm.count) bp, @\(cutPos + 1))\(fNoteExtra) + Specific (Tm: \(fTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )
        
        let primerR = PrimerItem(
            name: "Single-Frag-R",
            fullSequence: fullR,
            homologyArm: downArm,
            enzymeName: extra3RC.isEmpty ? enzyme.name : L10n.tr("\(enzyme.name)+3'附加", "\(enzyme.name)+3'Linker"),
            enzymeSite: extra3RC.isEmpty ? nil : extra3RC,
            specificSequence: rSpec,
            tm: rTm,
            targetPurpose: L10n.t("单片段克隆 (单酶切) 反向引物"),
            notes: L10n.tr("载体下游同源臂 (\(downArm.count)bp, @\(cutPos + enzyme.site.count))\(rNoteExtra) + 特异性序列 (Tm: \(rTm)℃)", "Vector 3' Arm (\(downArm.count) bp, @\(cutPos + enzyme.site.count))\(rNoteExtra) + Specific (Tm: \(rTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )
        
        return DesignResult(
            primerF: primerF,
            primerR: primerR,
            resolvedCutStart: cutPos + 1,
            resolvedCutEnd: min(vecLen, cutPos + enzyme.site.count),
            promptMessage: warnMsg
        )
    }
    
    /// 3. 双酶切单片段克隆设计 (Double Enzyme Digestion)
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
        
        let raw5 = sites5.first ?? 0
        let raw3 = sites3.first ?? min(cleanVec.count, raw5 + 30)
        let cut5 = min(raw5, raw3)
        let cut3 = max(raw5, raw3)
        let endEnzLen = (raw5 <= raw3) ? enzyme3.site.count : enzyme5.site.count
        
        var warnParts: [String] = []
        if sites5.isEmpty { warnParts.append(L10n.tr("未找到 5' 酶切位点 \(enzyme5.name)", "5' site \(enzyme5.name) not found")) }
        if sites3.isEmpty { warnParts.append(L10n.tr("未找到 3' 酶切位点 \(enzyme3.name)", "3' site \(enzyme3.name) not found")) }
        let warnMsg: String? = warnParts.isEmpty ? nil : ("⚠️ " + warnParts.joined(separator: "；"))
        
        let vecLen = max(1, cleanVec.count)
        let doubledVec = cleanVec + cleanVec
        let armLen = min(homologyLength, vecLen)
        
        let upStartOffset = (cut5 - armLen + vecLen) % vecLen
        let upStartIdx = doubledVec.index(doubledVec.startIndex, offsetBy: upStartOffset)
        let upEndIdx = doubledVec.index(upStartIdx, offsetBy: armLen)
        let upArm = String(doubledVec[upStartIdx..<upEndIdx]).lowercased()
        
        let downStartOffset = (cut3 + endEnzLen) % vecLen
        let downStartIdx = doubledVec.index(doubledVec.startIndex, offsetBy: downStartOffset)
        let downEndIdx = doubledVec.index(downStartIdx, offsetBy: armLen)
        let rawDown = String(doubledVec[downStartIdx..<downEndIdx])
        let downArm = BioSequence.reverseComplement(rawDown).lowercased()
        
        let fOverhang = upArm + extra5
        let rOverhang = downArm + extra3RC
        
        let (fSpec, fTm) = pickSpecificAnnealingSeq(
            from: cleanInsert,
            fivePrimeOverhang: fOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: true
        )
        let (rSpec, rTm) = pickSpecificAnnealingSeq(
            from: cleanInsert,
            fivePrimeOverhang: rOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: false
        )
        
        let fullF = fOverhang + fSpec
        let fullR = rOverhang + rSpec
        let fNoteExtra = extra5.isEmpty ? "" : L10n.tr(" + 5'补码/Linker(\(extra5.count)bp)", " + 5'Linker(\(extra5.count) bp)")
        let rNoteExtra = extra3RC.isEmpty ? "" : L10n.tr(" + 3'补码/Linker(\(extra3RC.count)bp)", " + 3'Linker(\(extra3RC.count) bp)")
        
        let primerF = PrimerItem(
            name: "Single-Frag-F",
            fullSequence: fullF,
            homologyArm: upArm,
            enzymeName: extra5.isEmpty ? enzyme5.name : L10n.tr("\(enzyme5.name)+5'附加", "\(enzyme5.name)+5'Linker"),
            enzymeSite: extra5.isEmpty ? nil : extra5,
            specificSequence: fSpec,
            tm: fTm,
            targetPurpose: L10n.t("单片段克隆 (双酶切) 正向引物"),
            notes: L10n.tr("5' 载体同源臂 (\(upArm.count)bp, @\(cut5 + 1))\(fNoteExtra) + 特异性序列 (Tm: \(fTm)℃)", "5' Vector Arm (\(upArm.count) bp, @\(cut5 + 1))\(fNoteExtra) + Specific (Tm: \(fTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )
        
        let primerR = PrimerItem(
            name: "Single-Frag-R",
            fullSequence: fullR,
            homologyArm: downArm,
            enzymeName: extra3RC.isEmpty ? enzyme3.name : L10n.tr("\(enzyme3.name)+3'附加", "\(enzyme3.name)+3'Linker"),
            enzymeSite: extra3RC.isEmpty ? nil : extra3RC,
            specificSequence: rSpec,
            tm: rTm,
            targetPurpose: L10n.t("单片段克隆 (双酶切) 反向引物"),
            notes: L10n.tr("3' 载体同源臂 (\(downArm.count)bp, @\(cut3 + endEnzLen))\(rNoteExtra) + 特异性序列 (Tm: \(rTm)℃)", "3' Vector Arm (\(downArm.count) bp, @\(cut3 + endEnzLen))\(rNoteExtra) + Specific (Tm: \(rTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )
        
        return DesignResult(
            primerF: primerF,
            primerR: primerR,
            resolvedCutStart: cut5 + 1,
            resolvedCutEnd: min(vecLen, cut3 + endEnzLen),
            promptMessage: warnMsg
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
        
        let fOverhang = upArm + extra5
        let rOverhang = downArm + extra3RC
        
        let (fSpec, fTm) = pickSpecificAnnealingSeq(
            from: cleanInsert,
            fivePrimeOverhang: fOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: true
        )
        let (rSpec, rTm) = pickSpecificAnnealingSeq(
            from: cleanInsert,
            fivePrimeOverhang: rOverhang,
            targetTm: targetTm,
            tolerance: tolerance,
            isForward: false
        )
        
        let fullF = fOverhang + fSpec
        let fullR = rOverhang + rSpec
        let fNoteExtra = extra5.isEmpty ? "" : L10n.tr(" + 5'补码/Linker(\(extra5.count)bp)", " + 5'Linker(\(extra5.count) bp)")
        let rNoteExtra = extra3RC.isEmpty ? "" : L10n.tr(" + 3'补码/Linker(\(extra3RC.count)bp)", " + 3'Linker(\(extra3RC.count) bp)")
        
        let primerF = PrimerItem(
            name: "Single-Frag-F",
            fullSequence: fullF,
            homologyArm: upArm,
            enzymeName: extra5.isEmpty ? nil : L10n.t("5'补码/Linker"),
            enzymeSite: extra5.isEmpty ? nil : extra5,
            specificSequence: fSpec,
            tm: fTm,
            targetPurpose: L10n.t("单片段克隆 (反向PCR) 插入正向引物"),
            notes: L10n.tr("5' 载体同源臂 (\(upArm.count)bp)\(fNoteExtra) + 特异性序列 (Tm: \(fTm)℃)", "5' Vector Arm (\(upArm.count) bp)\(fNoteExtra) + Specific (Tm: \(fTm) °C)"),
            sourceTool: L10n.t("单片段克隆")
        )
        
        let primerR = PrimerItem(
            name: "Single-Frag-R",
            fullSequence: fullR,
            homologyArm: downArm,
            enzymeName: extra3RC.isEmpty ? nil : L10n.t("3'补码/Linker"),
            enzymeSite: extra3RC.isEmpty ? nil : extra3RC,
            specificSequence: rSpec,
            tm: rTm,
            targetPurpose: L10n.t("单片段克隆 (反向PCR) 插入反向引物"),
            notes: L10n.tr("3' 载体同源臂 (\(downArm.count)bp)\(rNoteExtra) + 特异性序列 (Tm: \(rTm)℃)", "3' Vector Arm (\(downArm.count) bp)\(rNoteExtra) + Specific (Tm: \(rTm) °C)"),
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
            promptMessage: nil
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
            
            let (fSpec, fTm) = pickSpecificAnnealingSeq(
                from: frag,
                fivePrimeOverhang: fOverhang,
                targetTm: targetTm,
                tolerance: tolerance,
                isForward: true
            )
            let (rSpec, rTm) = pickSpecificAnnealingSeq(
                from: frag,
                fivePrimeOverhang: rOverhang,
                targetTm: targetTm,
                tolerance: tolerance,
                isForward: false
            )
            
            let fullF = fOverhang + fSpec
            let fullR = rOverhang + rSpec
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
                specificSequence: fSpec,
                tm: fTm,
                gcPercent: BioSequence.gcContent(fullF),
                targetPurpose: L10n.tr("片段 \(i + 1) 正向扩增引物", "Fragment \(i + 1) Forward Primer"),
                notes: L10n.tr("\(fArmNote)\(fExtraNote) + 特异序列 (Tm: \(fTm)℃)\(fQCNote)", "\(fArmNote)\(fExtraNote) + Specific (Tm: \(fTm) °C)\(fQCNote)"),
                sourceTool: L10n.t("多片段克隆")
            ))
            
            primers.append(PrimerItem(
                name: "Multi-Frag\(i + 1)-R",
                fullSequence: fullR,
                homologyArm: rArm,
                enzymeName: rExtraRC.isEmpty ? nil : L10n.t("3'补码/Linker"),
                enzymeSite: rExtraRC.isEmpty ? nil : rExtraRC,
                specificSequence: rSpec,
                tm: rTm,
                gcPercent: BioSequence.gcContent(fullR),
                targetPurpose: L10n.tr("片段 \(i + 1) 反向扩增引物", "Fragment \(i + 1) Reverse Primer"),
                notes: (rArm.isEmpty ? "" : "\(rArmNote)\(rExtraNote) + ") + L10n.tr("特异序列 (Tm: \(rTm)℃)\(rQCNote)", "Specific (Tm: \(rTm) °C)\(rQCNote)"),
                sourceTool: L10n.t("多片段克隆")
            ))
        }
        
        return primers
    }
}
