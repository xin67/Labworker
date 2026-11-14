import Foundation
import SwiftUI
import Combine

// MARK: - 4. 定点突变 ViewModel (支持载入质粒 .dna + 预览界面/氨基酸网格点选密码子或氨基酸直接突变)
public struct MutagenesisResidueItem: Identifiable, Sendable, Equatable {
    public var id: Int { residueIndex1Based }
    public let residueIndex1Based: Int
    public let codon: String
    public let aminoAcid: Character
    public let threeLetter: String
    public let plasmidStartBp: Int
    public let plasmidEndBp: Int
    public let isReverseStrand: Bool
    
    public var displayTag: String {
        "\(aminoAcid)\(residueIndex1Based)"
    }
    
    public init(
        residueIndex1Based: Int,
        codon: String,
        aminoAcid: Character,
        threeLetter: String,
        plasmidStartBp: Int,
        plasmidEndBp: Int,
        isReverseStrand: Bool
    ) {
        self.residueIndex1Based = residueIndex1Based
        self.codon = codon
        self.aminoAcid = aminoAcid
        self.threeLetter = threeLetter
        self.plasmidStartBp = plasmidStartBp
        self.plasmidEndBp = plasmidEndBp
        self.isReverseStrand = isReverseStrand
    }
}

@MainActor
public final class MutagenesisViewModel: ObservableObject {
    @Published public var mutUp: String = ""
    @Published public var mutDown: String = ""
    @Published public var mutSite: String = ""
    
    // MARK: - 质粒 .dna 载入与交互式密码子/氨基酸选择状态
    @Published public var plasmidDNAInfo: SnapGeneFileInfo? = nil
    @Published public var selectedFeatureID: String = ""
    @Published public var readingFrameOffset: Int = 0
    @Published public var translatedResidues: [MutagenesisResidueItem] = []
    @Published public var selectedResidueIndex: Int = 1
    @Published public var selectedTargetAA: String = "A"
    @Published public var residueSearchText: String = ""
    @Published public var mutTargetStartBp: Int = 1
    @Published public var mutTargetEndBp: Int = 3
    @Published public var mutationSummaryLabel: String = ""
    @Published public var isSnapGeneBusy: Bool = false
    
    @Published public var primers: [PrimerItem] = []
    @Published public var homologyLength: Int = AppState.shared.defaultHomologyLength
    @Published public var isDesigning: Bool = false
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    public init() {}
    
    /// 排序后的质粒特征（目的基因/CDS 优先排在最前）
    public var sortedFeatures: [SnapGeneFeature] {
        guard let info = plasmidDNAInfo else { return [] }
        return info.features.filter { !$0.segments.isEmpty }.sorted { a, b in
            let aTarget = PlasmidFeatureFilter.targetGenes.matches(a)
            let bTarget = PlasmidFeatureFilter.targetGenes.matches(b)
            if aTarget != bTarget { return aTarget }
            let aBack = PlasmidFeatureFilter.isBackbone(a)
            let bBack = PlasmidFeatureFilter.isBackbone(b)
            if aBack != bBack { return !aBack }
            let aLen = (a.segments.last?.end ?? 0) - (a.segments.first?.start ?? 0)
            let bLen = (b.segments.last?.end ?? 0) - (b.segments.first?.start ?? 0)
            return aLen > bLen
        }
    }
    
    /// 搜索过滤后的氨基酸残基列表（支持输入如 "42"、"K42"、"AAG"、"Lys"）
    public var filteredResidues: [MutagenesisResidueItem] {
        let q = residueSearchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !q.isEmpty else { return translatedResidues }
        return translatedResidues.filter { item in
            "\(item.residueIndex1Based)".contains(q)
                || item.displayTag.uppercased().contains(q)
                || item.codon.uppercased().contains(q)
                || item.threeLetter.uppercased().contains(q)
        }
    }
    
    public var currentSelectedResidue: MutagenesisResidueItem? {
        translatedResidues.first(where: { $0.residueIndex1Based == selectedResidueIndex }) ?? translatedResidues.first
    }
    
    /// 载入待定点突变的 SnapGene .dna 质粒文件
    public func loadDNAFile(url: URL) async {
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        do {
            let info = try await SnapGeneService.shared.parseDNAFile(at: url)
            self.plasmidDNAInfo = info
            self.readingFrameOffset = 0
            
            let feats = self.sortedFeatures
            if let best = feats.first(where: { $0.name.uppercased() == "A1" || $0.type.uppercased() == "CDS" }) ?? feats.first {
                selectFeatureForTranslation(id: best.id, frameOffset: 0)
            } else {
                translateRawPlasmidRange(startBp: 1, endBp: min(info.length, 900), isReverse: false, frameOffset: 0)
            }
            AppState.shared.showPlasmidPreview = true
            AppState.shared.showToast("已载入质粒 \(info.fileName) (\(info.length) bp)，可在预览图谱或下方氨基酸列表中直接点选密码子进行突变")
        } catch {
            alertMessage = "解析 SnapGene 质粒失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    /// 选择质粒上的某个 CDS / 基因特征并翻译为氨基酸/密码子序列
    public func selectFeatureForTranslation(id: String, frameOffset: Int? = nil) {
        guard let info = plasmidDNAInfo,
              let feat = info.features.first(where: { $0.id == id }),
              let firstSeg = feat.segments.first,
              let lastSeg = feat.segments.last else { return }
        
        self.selectedFeatureID = id
        if let fo = frameOffset {
            self.readingFrameOffset = max(0, min(2, fo))
        }
        let s = max(1, firstSeg.start)
        let e = min(info.length, lastSeg.end)
        let isRev = (feat.directionality == "2")
        translateRawPlasmidRange(startBp: s, endBp: e, isReverse: isRev, frameOffset: self.readingFrameOffset)
    }
    
    /// 将质粒指定区间按正/负链与阅读框翻译为可点击突变的氨基酸序列
    public func translateRawPlasmidRange(startBp: Int, endBp: Int, isReverse: Bool, frameOffset: Int) {
        guard let info = plasmidDNAInfo else { return }
        let cleanSeq = BioSequence.clean(info.sequence)
        let len = cleanSeq.count
        guard len >= 3 else { return }
        
        let s = max(1, min(startBp, len))
        let e = max(s, min(endBp, len))
        let sIdx = cleanSeq.index(cleanSeq.startIndex, offsetBy: s - 1)
        let eIdx = cleanSeq.index(cleanSeq.startIndex, offsetBy: e)
        let rawSub = String(cleanSeq[sIdx..<eIdx])
        let codingSeq = isReverse ? BioSequence.reverseComplement(rawSub) : rawSub
        let chars = Array(codingSeq)
        
        let safeOff = max(0, min(2, frameOffset))
        var items: [MutagenesisResidueItem] = []
        var idx = safeOff
        var aaNum = 1
        
        while idx + 2 < chars.count {
            let codonStr = String(chars[idx...(idx + 2)])
            let (aa, three) = CodonTranslator.translateTriplet(codonStr)
            let pStart: Int
            let pEnd: Int
            if !isReverse {
                pStart = s + idx
                pEnd = s + idx + 2
            } else {
                pEnd = e - idx
                pStart = e - idx - 2
            }
            items.append(MutagenesisResidueItem(
                residueIndex1Based: aaNum,
                codon: codonStr,
                aminoAcid: aa,
                threeLetter: three,
                plasmidStartBp: max(1, pStart),
                plasmidEndBp: min(len, pEnd),
                isReverseStrand: isReverse
            ))
            idx += 3
            aaNum += 1
        }
        
        self.translatedResidues = items
        if !items.isEmpty {
            let defaultPick = min(items.count, max(1, items.count / 3))
            selectResidueAndMutate(residueIndex1Based: defaultPick, targetAA: selectedTargetAA, customCodon: nil)
        }
    }
    
    /// 用户点击某个氨基酸/密码子并指定目标氨基酸或密码子时，自动更新上下游 60bp 与突变碱基
    public func selectResidueAndMutate(residueIndex1Based: Int, targetAA: String? = nil, customCodon: String? = nil) {
        guard let item = translatedResidues.first(where: { $0.residueIndex1Based == residueIndex1Based }) else { return }
        self.selectedResidueIndex = residueIndex1Based
        if let tAA = targetAA {
            self.selectedTargetAA = tAA
        }
        
        let chosenCodon: String
        let targetLabel: String
        if let custom = customCodon {
            chosenCodon = BioSequence.clean(custom)
            if chosenCodon.count == 3 {
                let (aa, _) = CodonTranslator.translateTriplet(chosenCodon)
                targetLabel = "\(aa)(\(chosenCodon))"
            } else if chosenCodon.isEmpty {
                targetLabel = "Δ缺失"
            } else {
                targetLabel = chosenCodon
            }
        } else if self.selectedTargetAA == "Δ" {
            chosenCodon = ""
            targetLabel = "Δ缺失"
        } else if let opt = CodonTranslator.aminoAcidOptions.first(where: { String($0.singleLetter) == self.selectedTargetAA }) {
            chosenCodon = opt.preferredCodon
            targetLabel = "\(opt.singleLetter)(\(chosenCodon))"
        } else {
            chosenCodon = "GCC"
            targetLabel = "A(GCC)"
        }
        
        // 若已载入质粒，从质粒正链（或根据编码方向）提取该密码子上下游各 60 bp
        if let info = plasmidDNAInfo {
            let cleanPlasmid = BioSequence.clean(info.sequence)
            let len = cleanPlasmid.count
            let doubled = cleanPlasmid + cleanPlasmid
            let cStart = item.plasmidStartBp
            let cEnd = item.plasmidEndBp
            self.mutTargetStartBp = cStart
            self.mutTargetEndBp = cEnd
            
            let flankLen = min(60, max(50, len / 4))
            let upEnd0 = (cStart - 1 + len) % len
            let upStart0 = (upEnd0 - flankLen + len) % len
            let uSIdx = doubled.index(doubled.startIndex, offsetBy: upStart0)
            let uEIdx = doubled.index(uSIdx, offsetBy: flankLen)
            let topUp = String(doubled[uSIdx..<uEIdx])
            
            let downStart0 = cEnd % len
            let dSIdx = doubled.index(doubled.startIndex, offsetBy: downStart0)
            let dEIdx = doubled.index(dSIdx, offsetBy: flankLen)
            let topDown = String(doubled[dSIdx..<dEIdx])
            
            // 若该基因在正链，直接填入 topUp / chosenCodon / topDown；若在负链，正链对应突变序列为 chosenCodon 的反向互补
            if !item.isReverseStrand {
                self.mutUp = topUp
                self.mutSite = chosenCodon
                self.mutDown = topDown
            } else {
                self.mutUp = topUp
                self.mutSite = chosenCodon.isEmpty ? "" : BioSequence.reverseComplement(chosenCodon)
                self.mutDown = topDown
            }
            self.mutationSummaryLabel = "\(item.aminoAcid)\(item.residueIndex1Based)\(targetLabel) [\(item.codon)→\(chosenCodon.isEmpty ? "Δ" : chosenCodon), @\(cStart)..\(cEnd) bp]"
        }
    }
    
    /// 接收来自右侧预览面板或独立弹出预览窗口的交互式密码子点选突变指令
    public func applyInteractiveCodonPayload(_ payload: InteractiveCodonMutationPayload) {
        self.mutUp = payload.upstreamFlank60Bp
        self.mutSite = payload.targetCodon
        self.mutDown = payload.downstreamFlank60Bp
        self.mutTargetStartBp = payload.startBp
        self.mutTargetEndBp = payload.endBp
        self.selectedTargetAA = payload.targetAA
        self.mutationSummaryLabel = "\(payload.wildTypeAA)\(payload.residueIndex1Based)\(payload.targetAA) [\(payload.wildTypeCodon)→\(payload.targetCodon.isEmpty ? "Δ" : payload.targetCodon), @\(payload.startBp)..\(payload.endBp) bp]"
        
        if let matched = translatedResidues.first(where: { $0.plasmidStartBp == payload.startBp }) {
            self.selectedResidueIndex = matched.residueIndex1Based
        }
        AppState.shared.showToast("已在预览中选定突变：\(self.mutationSummaryLabel)")
    }
    
    public func design() async {
        let cleanUp = BioSequence.clean(mutUp)
        let cleanDown = BioSequence.clean(mutDown)
        let cleanSite = BioSequence.clean(mutSite)
        
        guard cleanUp.count >= 50 else {
            alertMessage = "突变位点上游序列至少输入 50 bp（当前：\(cleanUp.count) bp）"
            showAlert = true
            return
        }
        guard cleanDown.count >= 50 else {
            alertMessage = "突变位点下游序列至少输入 50 bp（当前：\(cleanDown.count) bp）"
            showAlert = true
            return
        }
        
        isDesigning = true
        defer { isDesigning = false }
        
        do {
            let mTm = AppState.shared.mutationTargetTm
            let tol = AppState.shared.tmTolerance
            if DualEngineCoordinator.shared.currentMode == .offlineOnly || homologyLength != 15 || abs(mTm - 60.0) > 0.1 {
                let res = HomologyArmDesigner.designMutagenesis(
                    mutUp: cleanUp,
                    mutDown: cleanDown,
                    mutSite: cleanSite,
                    homologyLength: homologyLength,
                    targetTm: mTm,
                    tolerance: tol
                )
                self.primers = [res.primerF, res.primerR]
                AppState.shared.showToast("已成功生成定点突变引物（\(mutationSummaryLabel.isEmpty ? "同源重叠臂: \(homologyLength) bp" : mutationSummaryLabel)）")
            } else {
                // 在线官方请求 (15 bp 国标模式)
                let res = try await CloneOnlineAPIClient.shared.requestSingleMutation(
                    mutUp: cleanUp,
                    mutDown: cleanDown,
                    mutSite: cleanSite
                )
                
                var list: [PrimerItem] = []
                if let f = res.PrimerFvalue, !f.isEmpty {
                    let rawF = DualEngineCoordinator.stripHTMLTags(f)
                    let armF = String(BioSequence.clean(rawF).prefix(homologyLength)).lowercased()
                    let (specF, tmF) = DualEngineCoordinator.computeSnapGenePrimerMetrics(fullSequence: rawF, homologyArm: armF)
                    list.append(PrimerItem(
                        name: "Mutation-F",
                        fullSequence: rawF,
                        homologyArm: armF,
                        specificSequence: specF,
                        tm: tmF,
                        targetPurpose: "定点突变正向引物",
                        notes: "5' 突变同源臂 (\(armF.count)bp) + 3' 特异结合端 (Tm: \(tmF)℃)",
                        sourceTool: "定点突变"
                    ))
                }
                if let r = res.PrimerRvalue, !r.isEmpty {
                    let rawR = DualEngineCoordinator.stripHTMLTags(r)
                    let armR = String(BioSequence.clean(rawR).prefix(homologyLength)).lowercased()
                    let (specR, tmR) = DualEngineCoordinator.computeSnapGenePrimerMetrics(fullSequence: rawR, homologyArm: armR)
                    list.append(PrimerItem(
                        name: "Mutation-R",
                        fullSequence: rawR,
                        homologyArm: armR,
                        specificSequence: specR,
                        tm: tmR,
                        targetPurpose: "定点突变反向引物",
                        notes: "5' 突变同源臂 (\(armR.count)bp) + 3' 特异结合端 (Tm: \(tmR)℃)",
                        sourceTool: "定点突变"
                    ))
                }
                self.primers = list
                if let msg = res.promptMessage, !msg.isEmpty {
                    AppState.shared.showToast(msg)
                }
            }
            
            // 记录定点突变节点到构建谱系树
            if !self.primers.isEmpty {
                let mutLabel = !mutationSummaryLabel.isEmpty ? mutationSummaryLabel : (cleanSite.isEmpty ? "Δ缺失" : "★\(cleanSite)")
                let prodSeq = cleanUp + cleanSite + cleanDown
                let origBp = plasmidDNAInfo?.length ?? (cleanUp.count + cleanDown.count)
                let baseFeats: [(String, Int, Int)] = [
                    ("5' Flank", 1, cleanUp.count),
                    ("3' Flank", cleanUp.count + 1, cleanUp.count + cleanDown.count),
                    ("AmpR", cleanUp.count + cleanDown.count + 800, cleanUp.count + cleanDown.count + 1660),
                    ("ori", cleanUp.count + cleanDown.count + 2200, cleanUp.count + cleanDown.count + 2790)
                ]
                let shifts = ConstructHistoryManager.computeFeatureShifts(
                    originalFeatures: baseFeats,
                    editStartBp: cleanUp.count + 1,
                    editEndBp: cleanUp.count,
                    insertedBp: cleanSite.count,
                    insertedFeatureName: mutLabel
                )
                let ovhTop = String(cleanUp.suffix(9)) + cleanSite + String(cleanDown.prefix(9))
                let node = ConstructHistoryNode(
                    parentNodeID: ConstructHistoryManager.shared.activeNodeID,
                    constructName: "pMut-\(cleanSite.isEmpty ? "Del" : cleanSite)",
                    operationType: .mutagenesis,
                    parentVectorName: plasmidDNAInfo?.fileName.replacingOccurrences(of: ".dna", with: "") ?? "WT-Template",
                    parentLengthBp: origBp,
                    insertOrActionSummary: mutLabel,
                    productLengthBp: origBp + cleanSite.count - max(0, mutTargetEndBp - mutTargetStartBp + 1),
                    homologyArmLength: homologyLength,
                    junctionOverhangs: [
                        JunctionOverhangDetail(title: "突变位点环化重叠臂", topStrandSnippet: ovhTop, bottomStrandSnippet: BioSequence.complement(ovhTop), enzymeOrArmName: mutLabel, homologyLength: homologyLength)
                    ],
                    featureShifts: shifts,
                    primers: self.primers,
                    productSequence: prodSeq
                )
                ConstructHistoryManager.shared.recordNode(node)
            }
        } catch {
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
    
    /// 生成定点突变后的新 .dna 质粒文件并在 SnapGene 中打开
    public func generateMutantDNAAndOpen() async {
        guard let info = plasmidDNAInfo else {
            alertMessage = "请先载入待突变的模板质粒 .dna 文件"
            showAlert = true
            return
        }
        isSnapGeneBusy = true
        defer { isSnapGeneBusy = false }
        
        let vecURL = URL(fileURLWithPath: info.filePath)
        let cleanSite = BioSequence.clean(mutSite)
        let tag = SnapGeneService.sanitizeFileName(cleanSite.isEmpty ? "Del_\(mutTargetStartBp)_\(mutTargetEndBp)" : "Mut_\(mutTargetStartBp)_\(cleanSite)")
        let baseVecName = SnapGeneService.sanitizeFileName(info.fileName.replacingOccurrences(of: ".dna", with: ""))
        let outName = "\(baseVecName)-\(tag).dna"
        let parentDir = AppState.shared.exportSaveLocation.resolveDirectory(fallbackSourceURL: vecURL)
        let outURL = parentDir.appendingPathComponent(outName)
        
        do {
            if cleanSite.isEmpty {
                _ = try await SnapGeneService.shared.deleteFragment(
                    vectorURL: vecURL,
                    delStart: mutTargetStartBp,
                    delEnd: mutTargetEndBp,
                    primers: primers,
                    outputURL: outURL
                )
            } else {
                _ = try await SnapGeneService.shared.assembleRecombinant(
                    vectorURL: vecURL,
                    insertSourceURL: nil,
                    insertSeq: cleanSite,
                    insertName: mutationSummaryLabel.isEmpty ? "Mut:\(cleanSite)" : mutationSummaryLabel,
                    cutStart: mutTargetStartBp,
                    cutEnd: mutTargetEndBp,
                    primers: primers,
                    outputURL: outURL
                )
            }
            AppState.shared.showToast("已生成突变质粒：\(outName)")
            if AppState.shared.autoOpenInSnapGene {
                SnapGeneService.shared.openInSnapGene(url: outURL)
            }
        } catch {
            alertMessage = "生成突变质粒失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    public func addAllToCart() {
        guard !primers.isEmpty else { return }
        AppState.shared.addPrimersToCart(primers)
    }
}

// MARK: - 成对引物改名与分区一键清除扩展

extension MutagenesisViewModel {
    public func clearPlasmidSection() {
        plasmidDNAInfo = nil
        selectedFeatureID = ""
        translatedResidues = []
        residueSearchText = ""
        mutationSummaryLabel = ""
    }
    
    public func clearUpstreamSection() {
        mutUp = ""
    }
    
    public func clearMutationSiteSection() {
        mutSite = ""
    }
    
    public func clearDownstreamSection() {
        mutDown = ""
    }
    
    public func clearPrimersSection() {
        primers = []
    }
    
    public func clear() {
        clearPlasmidSection()
        mutUp = ""
        mutSite = ""
        mutDown = ""
        primers = []
        homologyLength = AppState.shared.defaultHomologyLength
    }
    
    public func renamePrimerPair(pairIndex: Int = 0, prefix rawPrefix: String) {
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
