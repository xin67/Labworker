import Foundation
import SwiftUI
import Combine

// MARK: - 3. 多片段克隆 ViewModel (支持 2 ~ 11 个片段动态增减 + 载体/各片段 .dna 解析选择)
@MainActor
public final class MultiFragmentViewModel: ObservableObject {
    @Published public var fragments: [String] = ["", ""]
    @Published public var fragmentNames: [Int: String] = [:]
    @Published public var fragmentDonorInfos: [Int: SnapGeneFileInfo] = [:]
    @Published public var fragmentSelectedFeatureIDs: [Int: String] = [:]
    @Published public var fragmentStartTexts: [Int: String] = [:]
    @Published public var fragmentEndTexts: [Int: String] = [:]
    @Published public var fragmentRevComps: [Int: Bool] = [:]
    /// 各片段 5' 接头附加碱基（用于多片段拼接处补码或插入柔性 Linker）以及末段 3' 接头附加碱基
    @Published public var fragmentExtra5Bases: [Int: String] = [:]
    @Published public var terminalExtra3Bases: String = ""
    
    @Published public var vectorDNAInfo: SnapGeneFileInfo? = nil
    @Published public var vectorTargetSource: SingleFragmentViewModel.VectorTargetSource = .byFeature
    @Published public var selectedVectorFeatureID: String = ""
    @Published public var vectorInsertAction: SingleFragmentViewModel.VectorInsertAction = .replaceFeature
    @Published public var availableVectorCutSites: [VectorCutSiteOption] = []
    @Published public var selectedVectorCutSiteID: String = ""
    @Published public var cutStartText: String = "1"
    @Published public var cutEndText: String = "1"
    @Published public var vectorSeqU: String = ""
    @Published public var vectorSeqD: String = ""
    
    @Published public var vectorSeq: String = ""
    @Published public var enzymeSingle: RestrictionEnzyme? = RestrictionEnzymeDatabase.shared.find(name: "BamHI")
    @Published public var primers: [PrimerItem] = []
    @Published public var homologyLength: Int = AppState.shared.defaultHomologyLength
    @Published public var isDesigning: Bool = false
    @Published public var isSnapGeneBusy: Bool = false
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    public var cutStart: Int {
        let maxLen = max(1, vectorDNAInfo?.length ?? max(1, BioSequence.clean(vectorSeq).count))
        let val = Int(cutStartText.trimmingCharacters(in: .whitespaces)) ?? 1
        return max(1, min(val, maxLen + 1))
    }
    
    public var cutEnd: Int {
        let maxLen = max(1, vectorDNAInfo?.length ?? max(1, BioSequence.clean(vectorSeq).count))
        let val = Int(cutEndText.trimmingCharacters(in: .whitespaces)) ?? cutStart
        return max(cutStart - 1, min(val, maxLen))
    }
    
    public var sortedVectorFeatures: [SnapGeneFeature] {
        guard let info = vectorDNAInfo else { return [] }
        return info.features.filter { !$0.segments.isEmpty }.sorted { a, b in
            let aTarget = PlasmidFeatureFilter.targetGenes.matches(a)
            let bTarget = PlasmidFeatureFilter.targetGenes.matches(b)
            if aTarget != bTarget { return aTarget }
            return (a.segments.first?.start ?? 0) < (b.segments.first?.start ?? 0)
        }
    }
    
    public init() {}
    
    public func addFragment() {
        guard fragments.count < 10 else { return }
        fragments.append("")
    }
    
    public func removeFragment(at index: Int) {
        guard fragments.count > 2 && index < fragments.count else { return }
        fragments.remove(at: index)
    }
    
    /// 载入多片段克隆的目标载体 .dna
    public func loadVectorDNA(url: URL) async {
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        do {
            let info = try await SnapGeneService.shared.parseDNAFile(at: url)
            self.vectorDNAInfo = info
            self.vectorSeq = info.sequence
            self.availableVectorCutSites = info.scanAvailableCutSites(maxCutsPerEnzyme: 2)
            if let firstCut = availableVectorCutSites.first {
                self.selectedVectorCutSiteID = firstCut.id
            }
            if let preferred = sortedVectorFeatures.first(where: { $0.name.uppercased() == "A1" }) ?? sortedVectorFeatures.first {
                self.vectorTargetSource = .byFeature
                selectVectorFeature(id: preferred.id, action: .replaceFeature)
            } else if let firstCut = availableVectorCutSites.first {
                self.vectorTargetSource = .byCutSites
                selectVectorCutSite(id: firstCut.id)
            } else {
                applyVectorTargetRange(start: 1, end: 0)
            }
            AppState.shared.showToast("已解析载体 \(info.fileName) (\(info.featuresCount) 个特征，\(availableVectorCutSites.filter { $0.isUnique }.count) 个唯一酶切位点)")
        } catch {
            alertMessage = "解析载体失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    public func selectVectorFeature(id: String, action: SingleFragmentViewModel.VectorInsertAction? = nil) {
        guard let info = vectorDNAInfo,
              let feat = info.features.first(where: { $0.id == id }),
              let firstSeg = feat.segments.first,
              let lastSeg = feat.segments.last else { return }
        self.selectedVectorFeatureID = id
        if let act = action { self.vectorInsertAction = act }
        let s = max(1, firstSeg.start)
        let e = min(info.length, lastSeg.end)
        switch self.vectorInsertAction {
        case .replaceFeature: applyVectorTargetRange(start: s, end: e)
        case .insertUpstream: applyVectorTargetRange(start: s, end: s - 1)
        case .insertDownstream: applyVectorTargetRange(start: min(info.length + 1, e + 1), end: e)
        }
    }
    
    public func selectVectorCutSite(id: String) {
        self.selectedVectorCutSiteID = id
        guard let opt = availableVectorCutSites.first(where: { $0.id == id }) else { return }
        self.enzymeSingle = opt.enzyme
        applyVectorTargetRange(start: opt.position1Based, end: opt.endPosition1Based)
    }
    
    public func applyVectorTargetRange(start: Int, end: Int) {
        guard let info = vectorDNAInfo else { return }
        let seq = BioSequence.clean(info.sequence)
        let len = seq.count
        guard len > 0 else { return }
        let cStart = max(1, min(start, len + 1))
        let cEnd = max(cStart - 1, min(end, len))
        self.cutStartText = "\(cStart)"
        self.cutEndText = "\(cEnd)"
        
        let flankLen = min(60, len)
        let doubled = seq + seq
        let upEnd0 = (cStart - 1 + len) % len
        let upStart0 = (upEnd0 - flankLen + len) % len
        let uSIdx = doubled.index(doubled.startIndex, offsetBy: upStart0)
        let uEIdx = doubled.index(uSIdx, offsetBy: flankLen)
        self.vectorSeqU = String(doubled[uSIdx..<uEIdx])
        
        let downStart0 = cEnd % len
        let dSIdx = doubled.index(doubled.startIndex, offsetBy: downStart0)
        let dEIdx = doubled.index(dSIdx, offsetBy: flankLen)
        self.vectorSeqD = String(doubled[dSIdx..<dEIdx])
    }
    
    /// 为第 index 个插入片段载入供体 .dna 并解析特征供选择
    public func loadFragmentDonorDNA(at index: Int, url: URL) async {
        guard index >= 0 && index < fragments.count else { return }
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        do {
            let info = try await SnapGeneService.shared.parseDNAFile(at: url)
            self.fragmentDonorInfos[index] = info
            let sortedFeats = info.features.filter { !$0.segments.isEmpty }.sorted { a, b in
                let aTarget = PlasmidFeatureFilter.targetGenes.matches(a)
                let bTarget = PlasmidFeatureFilter.targetGenes.matches(b)
                if aTarget != bTarget { return aTarget }
                let aLen = (a.segments.last?.end ?? 0) - (a.segments.first?.start ?? 0)
                let bLen = (b.segments.last?.end ?? 0) - (b.segments.first?.start ?? 0)
                return aLen > bLen
            }
            if let best = sortedFeats.first {
                selectFragmentFeature(at: index, featureID: best.id)
            } else {
                fragmentStartTexts[index] = "1"
                fragmentEndTexts[index] = "\(info.length)"
                fragmentRevComps[index] = false
                fragments[index] = info.sequence
                fragmentNames[index] = info.fileName.replacingOccurrences(of: ".dna", with: "")
            }
            AppState.shared.showToast("片段 \(index + 1) 已解析供体 \(info.fileName) (\(info.featuresCount) 个特征)")
        } catch {
            alertMessage = "解析片段 \(index + 1) 供体失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    public func selectFragmentFeature(at index: Int, featureID: String) {
        guard let info = fragmentDonorInfos[index],
              let feat = info.features.first(where: { $0.id == featureID }),
              let firstSeg = feat.segments.first,
              let lastSeg = feat.segments.last else { return }
        fragmentSelectedFeatureIDs[index] = featureID
        fragmentStartTexts[index] = "\(max(1, firstSeg.start))"
        fragmentEndTexts[index] = "\(min(info.length, lastSeg.end))"
        fragmentRevComps[index] = (feat.directionality == "2")
        fragmentNames[index] = feat.name
        extractFragmentFromCoordinates(at: index)
    }
    
    public func extractFragmentFromCoordinates(at index: Int) {
        guard index >= 0 && index < fragments.count,
              let info = fragmentDonorInfos[index] else { return }
        let seq = BioSequence.clean(info.sequence)
        let len = seq.count
        guard len > 0 else { return }
        let s = max(1, min(Int(fragmentStartTexts[index] ?? "1") ?? 1, len))
        let e = max(s, min(Int(fragmentEndTexts[index] ?? "\(len)") ?? len, len))
        fragmentStartTexts[index] = "\(s)"
        fragmentEndTexts[index] = "\(e)"
        let sIdx = seq.index(seq.startIndex, offsetBy: s - 1)
        let eIdx = seq.index(seq.startIndex, offsetBy: e)
        var sub = String(seq[sIdx..<eIdx])
        if fragmentRevComps[index] == true {
            sub = BioSequence.reverseComplement(sub)
        }
        fragments[index] = sub
    }
    
    public func design() async {
        let validFrags = fragments.map { BioSequence.clean($0) }
        for (i, f) in validFrags.enumerated() {
            if f.count < 50 {
                alertMessage = "插入片段 \(i + 1) 的有效长度小于 50 bp（当前：\(f.count) bp）"
                showAlert = true
                return
            }
        }
        
        isDesigning = true
        defer { isDesigning = false }
        
        do {
            let cTm = AppState.shared.cloningTargetTm
            let tol = AppState.shared.tmTolerance
            let hasAnyExtra = fragmentExtra5Bases.values.contains(where: { !BioSequence.clean($0).isEmpty }) || !BioSequence.clean(terminalExtra3Bases).isEmpty
            if DualEngineCoordinator.shared.currentMode == .offlineOnly || homologyLength != 15 || vectorDNAInfo != nil || abs(cTm - 60.0) > 0.1 || hasAnyExtra {
                var uSeq = vectorSeqU
                var dSeq = vectorSeqD
                if uSeq.isEmpty || dSeq.isEmpty {
                    let cleanVec = BioSequence.clean(vectorSeq)
                    if let enz = enzymeSingle, let pos = enz.findSites(in: cleanVec).first {
                        let sIdx = cleanVec.index(cleanVec.startIndex, offsetBy: pos)
                        let eIdx = cleanVec.index(cleanVec.startIndex, offsetBy: min(cleanVec.count, pos + enz.site.count))
                        uSeq = String(cleanVec[..<sIdx])
                        dSeq = String(cleanVec[eIdx...])
                    } else {
                        uSeq = String(cleanVec.prefix(max(18, cleanVec.count / 2)))
                        dSeq = String(cleanVec.suffix(max(18, cleanVec.count / 2)))
                    }
                }
                self.primers = HomologyArmDesigner.designMultiFragmentClone(
                    fragments: validFrags,
                    vectorSeqU: uSeq,
                    vectorSeqD: dSeq,
                    homologyLength: homologyLength,
                    targetTm: cTm,
                    tolerance: tol,
                    fragmentExtra5Bases: fragmentExtra5Bases,
                    terminalExtra3Bases: terminalExtra3Bases
                )
                AppState.shared.showToast("已生成 \(self.primers.count) 条多片段无缝克隆引物（同源臂: \(homologyLength) bp）")
            } else {
                let res = try await CloneOnlineAPIClient.shared.requestMultiFragmentClone(
                    fragments: validFrags,
                    mode: "Single",
                    vectorSeq: vectorSeq,
                    enzymeName: enzymeSingle?.name ?? "",
                    enzymeSite: enzymeSingle?.site ?? ""
                )
                
                var list: [PrimerItem] = []
                let pairs: [(String?, String?, String)] = [
                    (res.RTB1Fvalue, res.RTB1Rvalue, "片段 1"),
                    (res.RTB2Fvalue, res.RTB2Rvalue, "片段 2"),
                    (res.RTB3Fvalue, res.RTB3Rvalue, "片段 3"),
                    (res.RTB4Fvalue, res.RTB4Rvalue, "片段 4"),
                    (res.RTB5Fvalue, res.RTB5Rvalue, "片段 5")
                ]
                
                for (idx, pair) in pairs.enumerated() {
                    if idx >= validFrags.count { break }
                    if let f = pair.0, !f.isEmpty {
                        let rawF = DualEngineCoordinator.stripHTMLTags(f)
                        let armF = String(BioSequence.clean(rawF).prefix(homologyLength)).lowercased()
                        let (specF, tmF) = DualEngineCoordinator.computeSnapGenePrimerMetrics(fullSequence: rawF, homologyArm: armF)
                        list.append(PrimerItem(
                            name: "Multi-Frag\(idx+1)-F",
                            fullSequence: rawF,
                            homologyArm: armF,
                            specificSequence: specF,
                            tm: tmF,
                            targetPurpose: "\(pair.2) 正向扩增引物",
                            notes: "5' 同源臂 (\(armF.count)bp) + 特异序列 (Tm: \(tmF)℃)",
                            sourceTool: "多片段克隆"
                        ))
                    }
                    if let r = pair.1, !r.isEmpty {
                        let rawR = DualEngineCoordinator.stripHTMLTags(r)
                        let hasRArm = (idx == validFrags.count - 1)
                        let armR = hasRArm ? String(BioSequence.clean(rawR).prefix(homologyLength)).lowercased() : ""
                        let (specR, tmR) = DualEngineCoordinator.computeSnapGenePrimerMetrics(fullSequence: rawR, homologyArm: armR)
                        list.append(PrimerItem(
                            name: "Multi-Frag\(idx+1)-R",
                            fullSequence: rawR,
                            homologyArm: armR,
                            specificSequence: specR,
                            tm: tmR,
                            targetPurpose: "\(pair.2) 反向扩增引物",
                            notes: (armR.isEmpty ? "" : "3' 载体同源臂 (\(armR.count)bp) + ") + "特异序列 (Tm: \(tmR)℃)",
                            sourceTool: "多片段克隆"
                        ))
                    }
                }
                
                self.primers = list
                if let msg = res.promptMessage, !msg.isEmpty {
                    AppState.shared.showToast(msg)
                }
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
    
    public func generateRecombinantDNAAndOpen() async {
        guard let vecInfo = vectorDNAInfo else {
            alertMessage = "请先载入目标载体 .dna 文件"
            showAlert = true
            return
        }
        let validFrags = effectiveFragments.filter { $0.count >= 20 }
        guard !validFrags.isEmpty else { return }
        let combinedInsert = validFrags.joined()
        let combinedName = (0..<fragments.count).compactMap { fragmentNames[$0] }.joined(separator: "-")
        let cleanName = combinedName.isEmpty ? "MultiInsert" : combinedName
        
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        
        let vecURL = URL(fileURLWithPath: vecInfo.filePath)
        let parentDir = AppState.shared.exportSaveLocation.resolveDirectory(fallbackSourceURL: vecURL)
        let safeCleanName = SnapGeneService.sanitizeFileName(cleanName)
        let baseVecName = SnapGeneService.sanitizeFileName(vecInfo.fileName.replacingOccurrences(of: ".dna", with: ""))
        let outName = "\(baseVecName)-\(safeCleanName)-Recombinant.dna"
        let outURL = parentDir.appendingPathComponent(outName)
        
        do {
            let res = try await SnapGeneService.shared.assembleRecombinant(
                vectorURL: vecURL,
                insertSourceURL: nil,
                insertSeq: combinedInsert,
                insertName: cleanName,
                cutStart: self.cutStart,
                cutEnd: self.cutEnd,
                primers: primers,
                outputURL: outURL
            )
            AppState.shared.showToast("已生成多片段重组质粒：\(outName) (\(res.recombinantLength) bp)")
            SnapGeneService.shared.openInSnapGene(url: outURL)
        } catch {
            alertMessage = "生成多片段重组质粒失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    public func addAllToCart() {
        guard !primers.isEmpty else { return }
        AppState.shared.addPrimersToCart(primers)
    }
}

// MARK: - 成对引物改名与分区一键清除扩展

extension MultiFragmentViewModel {
    /// 包含各片段 5' 附加碱基与末段 3' 附加碱基的有效片段序列数组
    public var effectiveFragments: [String] {
        fragments.enumerated().map { idx, raw in
            let ex5 = BioSequence.clean(fragmentExtra5Bases[idx] ?? "")
            let ex3 = (idx == fragments.count - 1) ? BioSequence.clean(terminalExtra3Bases) : ""
            return ex5 + BioSequence.clean(raw) + ex3
        }
    }
    
    public var totalEffectiveInsertLength: Int {
        effectiveFragments.reduce(0) { $0 + $1.count }
    }
    
    public var totalReadingFrameRemainder: Int {
        totalEffectiveInsertLength % 3
    }
    
    public var neededTotalPaddingCount: Int {
        totalReadingFrameRemainder == 0 ? 0 : (3 - totalReadingFrameRemainder)
    }
    
    public var suggestedTotalPaddingBases: String {
        switch neededTotalPaddingCount {
        case 1: return "G"
        case 2: return "GC"
        default: return ""
        }
    }
    
    public func clearVectorSection() {
        vectorDNAInfo = nil
        vectorSeq = ""
        vectorSeqU = ""
        vectorSeqD = ""
        cutStartText = "1"
        cutEndText = "1"
        availableVectorCutSites = []
        selectedVectorFeatureID = ""
        selectedVectorCutSiteID = ""
    }
    
    public func clearFragment(at index: Int) {
        guard fragments.indices.contains(index) else { return }
        fragments[index] = ""
        fragmentNames.removeValue(forKey: index)
        fragmentDonorInfos.removeValue(forKey: index)
        fragmentSelectedFeatureIDs.removeValue(forKey: index)
        fragmentStartTexts.removeValue(forKey: index)
        fragmentEndTexts.removeValue(forKey: index)
        fragmentRevComps.removeValue(forKey: index)
        fragmentExtra5Bases.removeValue(forKey: index)
        if index == fragments.count - 1 {
            terminalExtra3Bases = ""
        }
    }
    
    public func clearAllFragmentsSection() {
        fragments = ["", ""]
        fragmentNames = [:]
        fragmentDonorInfos = [:]
        fragmentSelectedFeatureIDs = [:]
        fragmentStartTexts = [:]
        fragmentEndTexts = [:]
        fragmentRevComps = [:]
        fragmentExtra5Bases = [:]
        terminalExtra3Bases = ""
    }
    
    public func clearPrimersSection() {
        primers = []
    }
    
    public func clear() {
        clearVectorSection()
        clearAllFragmentsSection()
        clearPrimersSection()
        homologyLength = AppState.shared.defaultHomologyLength
    }
    
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
        AppState.shared.showToast("已成对重命名引物为 \(pfx)-F / \(pfx)-R")
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

// MARK: - 同源重组载体/插入基因长度计算与一键送入 DNA 用量计算器扩展

extension MultiFragmentViewModel {
    /// 原始载体全长 (bp)
    public var rawVectorLengthBp: Int {
        if let info = vectorDNAInfo, info.length > 0 {
            return info.length
        }
        return BioSequence.clean(vectorSeq).count
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
    
    /// 各插入片段的长度数组 (bp)
    public var fragmentLengthsBp: [Int] {
        fragments.map { BioSequence.clean($0).count }
    }
    
    /// 全部插入片段总长度 (bp)
    public var totalInsertLengthBp: Int {
        fragmentLengthsBp.reduce(0, +)
    }
    
    public func sendLengthsToCalculator(navigate: Bool = true) {
        let vecName = vectorDNAInfo?.fileName.replacingOccurrences(of: ".dna", with: "") ?? "多片段线性化载体"
        let vecBp = effectiveVectorBackboneLengthBp > 0 ? effectiveVectorBackboneLengthBp : 5000
        let insItems: [(String, Int)] = fragments.enumerated().map { idx, seq in
            let len = BioSequence.clean(seq).count
            let rawName = fragmentNames[idx]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let customName = (!rawName.isEmpty && rawName != "Frag\(idx + 1)")
                ? rawName
                : "片段 \(idx + 1)"
            return (customName, len > 0 ? len : 1000)
        }
        WorkspaceSessionManager.shared.calculatorVM.syncFromHomologousCloning(
            type: .multi,
            vectorName: vecName,
            vectorLengthBp: vecBp,
            inserts: insItems,
            navigate: navigate
        )
    }
}
