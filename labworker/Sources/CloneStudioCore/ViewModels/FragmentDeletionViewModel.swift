import Foundation
import SwiftUI
import Combine

// MARK: - 4.5 质粒大片段删除/敲除 ViewModel
@MainActor
public final class FragmentDeletionViewModel: ObservableObject {
    public enum SelectionMode: String, CaseIterable, Identifiable {
        case byFeature = "① 按质粒特征"
        case byPrimers = "② 按已有引物对"
        case byCoordinates = "③ 按起止坐标"
        case bySequence = "④ 按待删除序列"
        public var id: String { rawValue }
        
        public var shortTitle: String {
            switch self {
            case .byFeature: return "① 特征"
            case .byPrimers: return "② 引物"
            case .byCoordinates: return "③ 坐标"
            case .bySequence: return "④ 序列"
            }
        }
    }
    
    @Published public var plasmidSeq: String = ""
    @Published public var plasmidDNAInfo: SnapGeneFileInfo? = nil
    @Published public var selectedDNAFileURL: URL? = nil
    @Published public var selectedDNAFileName: String = ""
    @Published public var plasmidLength: Int = 0
    
    @Published public var selectionMode: SelectionMode = .byCoordinates
    @Published public var selectedDeleteFeatureID: String = ""
    @Published public var selectedDelRevPrimerID: String = ""
    @Published public var selectedDelFwdPrimerID: String = ""
    @Published public var targetDelSeq: String = ""
    @Published public var delStartText: String = ""
    @Published public var delEndText: String = ""
    
    @Published public var homologyLength: Int = AppState.shared.defaultHomologyLength
    @Published public var isDesigning: Bool = false
    @Published public var isExporting: Bool = false
    @Published public var alertMessage: String? = nil
    @Published public var showAlert: Bool = false
    
    @Published public var primers: [PrimerItem] = []
    @Published public var designResult: HomologyArmDesigner.FragmentDeletionDesignResult? = nil
    @Published public var lastExportedURL: URL? = nil
    
    public var sortedFeatures: [SnapGeneFeature] {
        guard let info = plasmidDNAInfo else { return [] }
        return info.features.filter { !$0.segments.isEmpty }.sorted { a, b in
            let aTarget = PlasmidFeatureFilter.targetGenes.matches(a)
            let bTarget = PlasmidFeatureFilter.targetGenes.matches(b)
            if aTarget != bTarget { return aTarget }
            return (a.segments.first?.start ?? 0) < (b.segments.first?.start ?? 0)
        }
    }
    
    public var boundPrimers: [SnapGenePrimer] {
        plasmidDNAInfo?.validBoundPrimers ?? []
    }
    
    public init() {}
    
    public func clear() {
        plasmidSeq = ""
        plasmidDNAInfo = nil
        selectedDNAFileName = ""
        selectedDNAFileURL = nil
        plasmidLength = 0
        selectedDeleteFeatureID = ""
        selectedDelRevPrimerID = ""
        selectedDelFwdPrimerID = ""
        targetDelSeq = ""
        delStartText = ""
        delEndText = ""
        primers = []
        designResult = nil
        lastExportedURL = nil
    }
    
    public func loadSampleData() {
        plasmidSeq = "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA"
            + "CGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA"
        plasmidDNAInfo = nil
        selectedDNAFileName = "pET-28a-EGFP-Sample"
        selectedDNAFileURL = nil
        selectionMode = .byCoordinates
        delStartText = "120"
        delEndText = "360"
        targetDelSeq = ""
        primers = []
        designResult = nil
        lastExportedURL = nil
    }
    
    public func loadDNAFile(url: URL) async {
        do {
            let info = try await SnapGeneService.shared.parseDNAFile(at: url)
            self.plasmidDNAInfo = info
            self.selectedDNAFileURL = url
            self.selectedDNAFileName = url.lastPathComponent
            self.plasmidSeq = info.sequence
            self.plasmidLength = info.length
            
            let bps = info.validBoundPrimers
            self.selectedDelRevPrimerID = (bps.first(where: { !$0.isForwardStrand }) ?? bps.first)?.id ?? ""
            self.selectedDelFwdPrimerID = (bps.first(where: { $0.isForwardStrand }) ?? bps.last)?.id ?? ""
            
            if let firstFeat = self.sortedFeatures.first {
                self.selectionMode = .byFeature
                self.selectDeleteFeature(id: firstFeat.id)
            } else {
                self.selectionMode = .byCoordinates
            }
            AppState.shared.showToast("已解析质粒 \(url.lastPathComponent)：\(info.featuresCount) 个特征、\(bps.count) 条引物可供选择")
        } catch {
            self.alertMessage = "解析 .dna 文件失败: \(error.localizedDescription)"
            self.showAlert = true
        }
    }
    
    public func selectDeleteFeature(id: String) {
        guard let info = plasmidDNAInfo,
              let feat = info.features.first(where: { $0.id == id }),
              let firstSeg = feat.segments.first,
              let lastSeg = feat.segments.last else { return }
        self.selectedDeleteFeatureID = id
        self.delStartText = "\(max(1, firstSeg.start))"
        self.delEndText = "\(min(info.length, lastSeg.end))"
    }
    
    public func applyDeletePrimerPair() {
        let bps = self.boundPrimers
        guard let revP = bps.first(where: { $0.id == selectedDelRevPrimerID }),
              let fwdP = bps.first(where: { $0.id == selectedDelFwdPrimerID }),
              let rEnd = revP.endBp,
              let fStart = fwdP.startBp else { return }
        let s = min(rEnd + 1, fStart)
        let e = max(s, fStart - 1)
        self.delStartText = "\(s)"
        self.delEndText = "\(e)"
    }
    
    public func design() async {
        let cleanPlasmid = BioSequence.clean(plasmidSeq)
        guard cleanPlasmid.count >= 100 else {
            alertMessage = "质粒序列过短，至少需要 100 bp（当前：\(cleanPlasmid.count) bp）"
            showAlert = true
            return
        }
        
        var calculatedStart = 0
        var calculatedEnd = 0
        
        if selectionMode == .bySequence {
            let cleanDel = BioSequence.clean(targetDelSeq)
            guard cleanDel.count >= 1 else {
                alertMessage = "请输入待删除片段序列"
                showAlert = true
                return
            }
            if let range = cleanPlasmid.range(of: cleanDel) {
                let startPos = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.lowerBound) + 1
                let endPos = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.upperBound)
                calculatedStart = startPos
                calculatedEnd = endPos
            } else {
                let rc = BioSequence.reverseComplement(cleanDel)
                if let range = cleanPlasmid.range(of: rc) {
                    let startPos = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.lowerBound) + 1
                    let endPos = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.upperBound)
                    calculatedStart = startPos
                    calculatedEnd = endPos
                } else {
                    alertMessage = "在质粒中未找到待删除序列片段，请核对输入或使用坐标/特征模式"
                    showAlert = true
                    return
                }
            }
        } else {
            guard let s = Int(delStartText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let e = Int(delEndText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  s >= 1, e <= cleanPlasmid.count, s <= e else {
                alertMessage = "删除起止坐标无效（有效范围: 1 ~ \(cleanPlasmid.count)）"
                showAlert = true
                return
            }
            calculatedStart = s
            calculatedEnd = e
        }
        
        isDesigning = true
        defer { isDesigning = false }
        
        let res = HomologyArmDesigner.designFragmentDeletion(
            plasmidSeq: cleanPlasmid,
            delStart: calculatedStart,
            delEnd: calculatedEnd,
            homologyLength: homologyLength,
            targetTm: AppState.shared.mutationTargetTm,
            tolerance: AppState.shared.tmTolerance
        )
        
        if let msg = res.promptMessage {
            alertMessage = msg
            showAlert = true
            return
        }
        
        self.designResult = res
        self.primers = [res.primerF, res.primerR]
        
        // 记录质粒大片段敲除节点到构建谱系树
        let pName = selectedDNAFileName.isEmpty ? "Target-Plasmid" : selectedDNAFileName.replacingOccurrences(of: ".dna", with: "")
        let baseFeats: [(String, Int, Int)] = [
            ("保留骨架上游", 1, max(1, res.delStart - 1)),
            ("待敲除片段 (Δ)", res.delStart, res.delEnd),
            ("保留骨架下游", min(cleanPlasmid.count, res.delEnd + 1), cleanPlasmid.count)
        ]
        let shifts = ConstructHistoryManager.computeFeatureShifts(
            originalFeatures: baseFeats,
            editStartBp: res.delStart,
            editEndBp: res.delEnd,
            insertedBp: 0,
            insertedFeatureName: nil
        )
        let seamSnippet = String(res.newPlasmidSeq.prefix(max(0, res.delStart - 1)).suffix(9))
            + String(res.newPlasmidSeq.dropFirst(max(0, res.delStart - 1)).prefix(9))
        let delNode = ConstructHistoryNode(
            parentNodeID: ConstructHistoryManager.shared.activeNodeID,
            constructName: "\(pName)_Δ\(res.deletedLength)bp",
            operationType: .fragmentDeletion,
            parentVectorName: pName,
            parentLengthBp: cleanPlasmid.count,
            insertOrActionSummary: "Δ 敲除 \(res.delStart)..\(res.delEnd) (-\(res.deletedLength) bp)",
            productLengthBp: res.newPlasmidSeq.count,
            homologyArmLength: homologyLength,
            junctionOverhangs: [
                JunctionOverhangDetail(
                    title: "跨切点反向 PCR 环化接缝",
                    topStrandSnippet: seamSnippet,
                    bottomStrandSnippet: BioSequence.complement(seamSnippet),
                    enzymeOrArmName: "Δ切点接缝",
                    homologyLength: homologyLength
                )
            ],
            featureShifts: shifts,
            primers: self.primers,
            productSequence: res.newPlasmidSeq
        )
        ConstructHistoryManager.shared.recordNode(delNode)
        
        AppState.shared.showToast("已成功生成反向 PCR 缺失引物（删除 \(res.deletedLength) bp）")
    }
    
    public func addAllToCart() {
        guard !primers.isEmpty else { return }
        AppState.shared.addPrimersToCart(primers)
    }
    
    public func exportToSnapGene(openAfterExport: Bool = true) async {
        guard let res = designResult else { return }
        guard let srcURL = selectedDNAFileURL else {
            alertMessage = "当前为纯文本序列模式。如需直接导出 SnapGene .dna 文件，请先点击「载入质粒 .dna」导入原始质粒模板。"
            showAlert = true
            return
        }
        
        isExporting = true
        defer { isExporting = false }
        
        do {
            let outName = srcURL.deletingPathExtension().lastPathComponent + "_Δ\(res.deletedLength)bp.dna"
            let outURL = srcURL.deletingLastPathComponent().appendingPathComponent(outName)
            
            _ = try await SnapGeneService.shared.deleteFragment(
                vectorURL: srcURL,
                delStart: res.delStart,
                delEnd: res.delEnd,
                primers: self.primers,
                outputURL: outURL
            )
            
            self.lastExportedURL = outURL
            AppState.shared.showToast("已生成删除后 SnapGene 质粒: \(outName)")
            
            if openAfterExport {
                SnapGeneService.shared.openInSnapGene(url: outURL)
            }
        } catch {
            alertMessage = "导出 SnapGene 文件失败: \(error.localizedDescription)"
            showAlert = true
        }
    }
}

// MARK: - 成对引物改名与分区一键清除扩展

extension FragmentDeletionViewModel {
    public func clearPlasmidSection() {
        plasmidSeq = ""
        plasmidDNAInfo = nil
        selectedDNAFileName = ""
        selectedDNAFileURL = nil
        plasmidLength = 0
        selectedDeleteFeatureID = ""
        selectedDelRevPrimerID = ""
        selectedDelFwdPrimerID = ""
    }
    
    public func clearDeletionTargetSection() {
        targetDelSeq = ""
        delStartText = ""
        delEndText = ""
        selectedDeleteFeatureID = ""
    }
    
    public func clearPrimersSection() {
        primers = []
        designResult = nil
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
