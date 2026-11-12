import Foundation
import SwiftUI
import AppKit

@MainActor
public final class OrderExportViewModel: ObservableObject {
    @Published public var selectedCategory: OrderCategory = .primerSynthesis
    @Published public var selectedSeqTemplate: OrderFormTemplate = .tsingkeSeq
    @Published public var isExporting: Bool = false
    @Published public var exportedFilePath: String? = nil
    @Published public var errorMessage: String? = nil
    @Published public var showSuccessAlert: Bool = false
    @Published public var showErrorAlert: Bool = false
    
    public init() {}
    
    /// 执行引物合成表导出 (擎科)
    public func exportPrimersOrder() {
        let primers = AppState.shared.primersCart
        guard !primers.isEmpty else {
            errorMessage = "待订购引物池为空，请先在克隆或突变设计界面生成引物并加入订购单。"
            showErrorAlert = true
            return
        }
        
        isExporting = true
        defer { isExporting = false }
        
        do {
            let path = try ExcelOrderExporter.shared.exportTsingkeOrder(
                primers: primers,
                profile: AppState.shared.profile
            )
            self.exportedFilePath = path
            self.showSuccessAlert = true
            AppState.shared.showToast("已成功导出擎科引物合成订购单！")
        } catch {
            self.errorMessage = error.localizedDescription
            self.showErrorAlert = true
        }
    }
    
    /// 执行测序样品表导出 (支持擎科电子订单、生工专属版、生工V9通用版)
    public func exportSequencingOrder() {
        let samples = AppState.shared.sangonSamples
        guard !samples.isEmpty else {
            errorMessage = "待测序样品列表为空，请先添加测序质粒与引物信息。"
            showErrorAlert = true
            return
        }
        
        isExporting = true
        defer { isExporting = false }
        
        do {
            let path = try ExcelOrderExporter.shared.exportOrder(
                template: selectedSeqTemplate,
                primers: [],
                samples: samples,
                profile: AppState.shared.profile
            )
            self.exportedFilePath = path
            self.showSuccessAlert = true
            AppState.shared.showToast("已成功导出「\(selectedSeqTemplate.displayName)」！")
        } catch {
            self.errorMessage = error.localizedDescription
            self.showErrorAlert = true
        }
    }
    
    /// 添加单个测序样品
    public func addSample(name: String = "Construct", vector: String = "pCE-Entry", primer: String = "T7", fragmentLength: Int = 1000) {
        let count = AppState.shared.sangonSamples.count + 1
        let item = SequencingSampleItem(
            sampleName: "\(name)-\(count)",
            sampleType: "质粒",
            resistance: "Amp",
            vectorName: vector,
            fragmentLength: fragmentLength,
            primerName: primer,
            primerCategory: "A、通用引物",
            requirement: "单向测通",
            notes: "重组质粒测序验证"
        )
        AppState.shared.sangonSamples.append(item)
        AppState.shared.showToast("已添加测序样品：\(item.sampleName)")
    }
    
    /// 快速添加 T7 + BGH (或通用正反向) 测序对
    public func addPairSample(name: String = "Recombinant-Plasmid", vector: String = "pCE-Entry") {
        let count = AppState.shared.sangonSamples.count + 1
        let s1 = SequencingSampleItem(
            sampleName: "\(name)-\(count)",
            sampleType: "质粒",
            resistance: "Amp",
            vectorName: vector,
            fragmentLength: 1200,
            primerName: "T7",
            primerCategory: "A、通用引物",
            requirement: "正向测序",
            notes: "正向验证"
        )
        let s2 = SequencingSampleItem(
            sampleName: "\(name)-\(count)",
            sampleType: "质粒",
            resistance: "Amp",
            vectorName: vector,
            fragmentLength: 1200,
            primerName: "BGH",
            primerCategory: "A、通用引物",
            requirement: "反向测序",
            notes: "反向验证"
        )
        AppState.shared.sangonSamples.append(contentsOf: [s1, s2])
        AppState.shared.showToast("已添加成对测序样品 (T7 + BGH)")
    }
    
    /// 删除测序样品
    public func removeSample(at index: Int) {
        guard index >= 0 && index < AppState.shared.sangonSamples.count else { return }
        AppState.shared.sangonSamples.remove(at: index)
    }
    
    /// 清空测序样品池
    public func clearSamples() {
        AppState.shared.sangonSamples.removeAll()
        AppState.shared.showToast("已清空测序样品池")
    }
    
    /// 导出为纯文本 TSV
    public func copyAsTSV() {
        let primers = AppState.shared.primersCart
        guard !primers.isEmpty else { return }
        
        var lines: [String] = ["引物名称\t引物序列(5'->3')\t碱基数\t纯度\tOD\t备注"]
        for p in primers {
            lines.append("\(p.name)\t\(p.fullSequence)\t\(p.length)\t\(p.purity)\t\(p.od)\t\(p.notes)")
        }
        let tsv = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tsv, forType: .string)
        AppState.shared.showToast("已复制 TSV 格式数据到剪贴板")
    }
    
    /// 导出为 FASTA 格式
    public func copyAsFASTA() {
        let primers = AppState.shared.primersCart
        guard !primers.isEmpty else { return }
        
        var lines: [String] = []
        for p in primers {
            lines.append(">\(p.name) length=\(p.length) notes=\(p.notes)")
            lines.append(p.fullSequence)
        }
        let fasta = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fasta, forType: .string)
        AppState.shared.showToast("已复制 FASTA 格式到剪贴板")
    }
    
    public func revealLastExported() {
        guard let path = exportedFilePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
    }
}
