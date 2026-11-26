import Foundation
import SwiftUI
import AppKit

@MainActor
public final class OrderExportViewModel: ObservableObject {
    @Published public var selectedCategory: OrderCategory = .primerSynthesis
    @Published public var selectedPrimerTemplate: OrderFormTemplate = .tsingkePrimer
    @Published public var selectedOutputFormat: OrderOutputFileFormat = .xlsx
    @Published public var customTemplates: [CustomOrderTemplateSpec]
    @Published public var selectedCustomTemplateID: String
    @Published public var selectedSeqTemplate: OrderFormTemplate = .tsingkeSeq
    @Published public var isExporting: Bool = false
    @Published public var exportedFilePath: String? = nil
    @Published public var errorMessage: String? = nil
    @Published public var showSuccessAlert: Bool = false
    @Published public var showErrorAlert: Bool = false
    
    public init() {
        let loaded = CustomOrderTemplateStore.loadTemplates()
        self.customTemplates = loaded
        self.selectedCustomTemplateID = loaded.first?.id ?? "custom_default"
    }

    public var activeCustomTemplate: CustomOrderTemplateSpec? {
        customTemplates.first(where: { $0.id == selectedCustomTemplateID }) ?? customTemplates.first
    }

    public var sanitizationWarnings: [String] {
        let spec: CustomOrderTemplateSpec? = (selectedPrimerTemplate == .customJSON) ? activeCustomTemplate : nil
        return OrderTemplateEngine.validateSanitizationWarnings(
            template: selectedPrimerTemplate,
            spec: spec,
            primers: AppState.shared.primersCart
        )
    }

    /// 切换供应商模板并同步推荐输出格式
    public func selectPrimerTemplate(_ tpl: OrderFormTemplate, customTemplateID: String? = nil) {
        selectedPrimerTemplate = tpl
        if let customID = customTemplateID {
            selectedCustomTemplateID = customID
        }
        if tpl == .tsingkePrimer {
            selectedOutputFormat = .xlsx
        } else if let spec = (tpl == .customJSON ? activeCustomTemplate : OrderTemplateEngine.builtinPreset(for: tpl)) {
            selectedOutputFormat = spec.preferredFormat
        }
    }

    /// 执行引物 / 基因合成订购表导出（支持擎科 / IDT / Twist / GenScript / Eurofins / BGI / 自定义 JSON）
    public func exportPrimersOrder() {
        let primers = AppState.shared.primersCart
        guard !primers.isEmpty else {
            errorMessage = L10n.t("待订购引物/基因池为空，请先在设计界面生成或手动添加条目。")
            showErrorAlert = true
            return
        }
        
        isExporting = true
        defer { isExporting = false }
        
        do {
            let customSpec = (selectedPrimerTemplate == .customJSON) ? activeCustomTemplate : nil
            let format: OrderOutputFileFormat = selectedPrimerTemplate.requiresBundledXLSXTemplate ? .xlsx : selectedOutputFormat
            let path = try ExcelOrderExporter.shared.exportOrder(
                template: selectedPrimerTemplate,
                primers: primers,
                samples: [],
                profile: AppState.shared.profile,
                targetDir: nil,
                fileFormat: format,
                customTemplate: customSpec
            )
            self.exportedFilePath = path
            self.showSuccessAlert = true
            let tplLabel = (selectedPrimerTemplate == .customJSON) ? (customSpec?.name ?? L10n.t("自定义模板")) : L10n.t(selectedPrimerTemplate.displayName)
            AppState.shared.showToast(L10n.tr("已成功导出「\(tplLabel)」(\(format.rawValue.uppercased()))！", "Exported \"\(tplLabel)\" (\(format.rawValue.uppercased()))!"))
        } catch {
            self.errorMessage = error.localizedDescription
            self.showErrorAlert = true
        }
    }

    /// 手动添加引物或基因合成片段到订购池
    public func addManualOligoOrGene(
        name: String,
        sequence: String,
        purity: String = "PAGE",
        od: Double = 2.0,
        purpose: String = "手动添加/基因合成",
        notes: String = ""
    ) {
        let cleanSeq = BioSequence.clean(sequence)
        guard !cleanSeq.isEmpty else {
            AppState.shared.showToast("请输入有效的 A/C/G/T 核苷酸序列")
            return
        }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? "Oligo-\(AppState.shared.primersCart.count + 1)" : cleanName
        let item = PrimerItem(
            name: finalName,
            fullSequence: cleanSeq,
            homologyArm: "",
            specificSequence: cleanSeq,
            tm: 0.0,
            purity: purity.isEmpty ? "PAGE" : purity,
            od: od > 0 ? od : 2.0,
            tubes: 1,
            targetPurpose: purpose,
            notes: notes
        )
        AppState.shared.primersCart.append(item)
        AppState.shared.showToast(L10n.tr("已加入订购池：\(finalName) (\(cleanSeq.count) bp)", "Added to order cart: \(finalName) (\(cleanSeq.count) bp)"))
    }

    public func saveCustomTemplate(_ spec: CustomOrderTemplateSpec) {
        if let idx = customTemplates.firstIndex(where: { $0.id == spec.id }) {
            customTemplates[idx] = spec
        } else {
            customTemplates.append(spec)
        }
        selectedCustomTemplateID = spec.id
        selectedPrimerTemplate = .customJSON
        selectedOutputFormat = spec.preferredFormat
        try? CustomOrderTemplateStore.saveTemplates(customTemplates)
        AppState.shared.showToast(L10n.tr("已保存自定义列映射模板：\(spec.name)", "Saved custom column template: \(spec.name)"))
    }

    public func deleteCustomTemplate(id: String) {
        guard customTemplates.count > 1 else {
            AppState.shared.showToast("至少保留一套自定义模板")
            return
        }
        customTemplates.removeAll { $0.id == id }
        if selectedCustomTemplateID == id {
            selectedCustomTemplateID = customTemplates.first?.id ?? "custom_default"
        }
        try? CustomOrderTemplateStore.saveTemplates(customTemplates)
    }

    public func importCustomTemplateJSON(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(CustomOrderTemplateSpec.self, from: data)
        var spec = decoded
        if spec.id.isEmpty { spec.id = UUID().uuidString }
        saveCustomTemplate(spec)
    }

    public func exportCustomTemplateJSON(_ spec: CustomOrderTemplateSpec, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(spec)
        try data.write(to: url, options: .atomic)
        AppState.shared.showToast(L10n.tr("已导出列映射模板 JSON：\(url.lastPathComponent)", "Exported column mapping JSON: \(url.lastPathComponent)"))
    }
    
    /// 执行测序样品表导出 (支持擎科电子订单、生工专属版、生工V9通用版)
    public func exportSequencingOrder() {
        let samples = AppState.shared.sangonSamples
        guard !samples.isEmpty else {
            errorMessage = L10n.t("待测序样品列表为空，请先添加测序质粒与引物信息。")
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
            AppState.shared.showToast(L10n.tr("已成功导出「\(selectedSeqTemplate.displayName)」！", "Exported \"\(L10n.t(selectedSeqTemplate.displayName))\"!"))
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
        AppState.shared.showToast(L10n.tr("已添加测序样品：\(item.sampleName)", "Added sequencing sample: \(item.sampleName)"))
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
        
        var lines: [String] = [L10n.t("引物名称\t引物序列(5'->3')\t碱基数\t纯度\tOD\t备注")]
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
