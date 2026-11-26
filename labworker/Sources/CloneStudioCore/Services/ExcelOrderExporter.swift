import Foundation
import AppKit

/// 测序订购样品条目模型 (适配擎科电子订单与生工V9等全套表单)
public struct SequencingSampleItem: Identifiable, Hashable, Codable {
    public var id: UUID = UUID()
    public var sampleName: String
    public var sampleType: String
    public var resistance: String
    public var vectorName: String
    public var fragmentLength: Int
    public var primerName: String
    public var primerName2: String
    public var primerType: String
    public var primerCategory: String
    public var requirement: String
    public var characteristics: String
    public var returnRequirement: String
    public var notes: String
    
    public init(
        sampleName: String,
        sampleType: String = "质粒",
        resistance: String = "Amp",
        vectorName: String = "pCE-Entry",
        fragmentLength: Int = 1000,
        primerName: String = "T7",
        primerName2: String = "",
        primerType: String = "通用",
        primerCategory: String = "A、通用引物",
        requirement: String = "单向测通",
        characteristics: String = "A、正常",
        returnRequirement: String = "C、无需返还质粒",
        notes: String = ""
    ) {
        self.sampleName = sampleName
        self.sampleType = sampleType
        self.resistance = resistance
        self.vectorName = vectorName
        self.fragmentLength = fragmentLength
        self.primerName = primerName
        self.primerName2 = primerName2
        self.primerType = primerType
        self.primerCategory = primerCategory
        self.requirement = requirement
        self.characteristics = characteristics
        self.returnRequirement = returnRequirement
        self.notes = notes
    }
}

public typealias SangonSampleItem = SequencingSampleItem

/// 订购业务大类
public enum OrderCategory: String, CaseIterable, Identifiable {
    case primerSynthesis = "引物合成"
    case dnaSequencing = "DNA测序"
    public var id: String { rawValue }
}

/// 支持的商业订购模板 (擎科 / 生工 / IDT / Twist / GenScript / Eurofins / BGI / 自定义 JSON)
public enum OrderFormTemplate: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case tsingkePrimer = "tsingke_primer"
    case tsingkeSeq    = "tsingke_seq"
    case sangonSeq     = "sangon_seq"
    case sangonV9Seq   = "sangon_v9_seq"
    case idtBulk       = "idt_bulk"
    case twistBulk     = "twist_bulk"
    case genscriptBulk = "genscript_bulk"
    case eurofinsBulk  = "eurofins_bulk"
    case bgiBulk       = "bgi_bulk"
    case customJSON    = "custom_json"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .tsingkePrimer: return "擎科引物合成订购表 (专属版)"
        case .tsingkeSeq:    return "擎科DNA测序订购表 (专属电子订单)"
        case .sangonSeq:     return "生工DNA测序订购表 (专属版)"
        case .sangonV9Seq:   return "生工DNA测序订购表 (官方通用V9版)"
        case .idtBulk:       return "IDT Bulk Input (引物 / Ultramer 批量订购)"
        case .twistBulk:     return "Twist Bioscience (基因片段 / Oligo 批量订购)"
        case .genscriptBulk: return "GenScript 金斯瑞 (GenSmart 批量订购)"
        case .eurofinsBulk:  return "Eurofins Genomics (96孔板引物批量订购)"
        case .bgiBulk:       return "华大基因 BGI (引物 / 基因批量订购)"
        case .customJSON:    return "自定义列映射模板 (.json)"
        }
    }
    
    public var filename: String {
        switch self {
        case .tsingkePrimer: return "擎科引物合成订购表.xlsx"
        case .tsingkeSeq:    return "擎科测序订购表专属电子订单.xlsx"
        case .sangonSeq:     return "生工DNA测序订购表.xlsx"
        case .sangonV9Seq:   return "DNA测序订购表_V9(1).xlsx"
        case .idtBulk:       return "IDT_Bulk_Input_Order.xlsx"
        case .twistBulk:     return "Twist_Bioscience_Order.csv"
        case .genscriptBulk: return "GenScript_Bulk_Order.xlsx"
        case .eurofinsBulk:  return "Eurofins_Plate_Order.csv"
        case .bgiBulk:       return "BGI_Synthesis_Order.xlsx"
        case .customJSON:    return "Labworker_Custom_Order.csv"
        }
    }
    
    public var category: OrderCategory {
        switch self {
        case .tsingkePrimer, .idtBulk, .twistBulk, .genscriptBulk, .eurofinsBulk, .bgiBulk, .customJSON:
            return .primerSynthesis
        case .tsingkeSeq, .sangonSeq, .sangonV9Seq:
            return .dnaSequencing
        }
    }

    public var requiresBundledXLSXTemplate: Bool {
        switch self {
        case .tsingkePrimer, .tsingkeSeq, .sangonSeq, .sangonV9Seq:
            return true
        case .idtBulk, .twistBulk, .genscriptBulk, .eurofinsBulk, .bgiBulk, .customJSON:
            return false
        }
    }

    public var supportedFormats: [OrderOutputFileFormat] {
        requiresBundledXLSXTemplate ? [.xlsx] : [.xlsx, .csv]
    }
}

/// Excel 商业订购表导出服务 (集成当前工程 4 套专用订购单)
public final class ExcelOrderExporter {
    public static let shared = ExcelOrderExporter()
    
    public static let defaultTsingkeTemplateName = OrderFormTemplate.tsingkePrimer.filename
    public static let defaultSangonTemplateName = OrderFormTemplate.sangonSeq.filename
    public static let defaultTsingkeSeqTemplateName = OrderFormTemplate.tsingkeSeq.filename
    public static let defaultSangonV9TemplateName = OrderFormTemplate.sangonV9Seq.filename
    
    /// 寻找当前工作目录或包内的模板文件
    public func locateTemplate(name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return CloneStudioResourceLocator.path(forResource: stem, ofType: ext.isEmpty ? "xlsx" : ext)
    }
    
    /// 寻找 Python 导出助手脚本
    private func locateScript() -> String? {
        CloneStudioResourceLocator.path(forResource: "export_order", ofType: "py")
    }
    
    /// 导出擎科引物订购表
    public func exportTsingkeOrder(
        primers: [PrimerItem],
        profile: OrderFormProfile = OrderFormProfile(),
        targetDir: String? = nil
    ) throws -> String {
        return try exportOrder(
            template: .tsingkePrimer,
            primers: primers,
            samples: [],
            profile: profile,
            targetDir: targetDir
        )
    }
    
    /// 导出生工 DNA 测序订购表 (专属版)
    public func exportSangonOrder(
        samples: [SequencingSampleItem],
        profile: OrderFormProfile = OrderFormProfile(),
        targetDir: String? = nil
    ) throws -> String {
        return try exportOrder(
            template: .sangonSeq,
            primers: [],
            samples: samples,
            profile: profile,
            targetDir: targetDir
        )
    }
    
    /// 通用模板导出调度核心（支持内置母版、国际批量合成模板与自定义 JSON 列映射）
    public func exportOrder(
        template: OrderFormTemplate,
        primers: [PrimerItem],
        samples: [SequencingSampleItem],
        profile: OrderFormProfile = OrderFormProfile(),
        targetDir: String? = nil,
        fileFormat: OrderOutputFileFormat = .xlsx,
        customTemplate: CustomOrderTemplateSpec? = nil
    ) throws -> String {
        var templatePath = "-"
        if template.requiresBundledXLSXTemplate {
            guard let bundled = locateTemplate(name: template.filename) else {
                throw NSError(domain: "ExcelExport", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.tr("未找到母版文件：\(template.filename)", "Template file not found: \(template.filename)")])
            }
            templatePath = bundled
        } else if template == .customJSON && customTemplate == nil {
            throw NSError(domain: "ExcelExport", code: -4, userInfo: [NSLocalizedDescriptionKey: L10n.t("自定义列映射导出需要提供有效的 CustomOrderTemplateSpec 配置。")])
        }
        guard let scriptPath = locateScript() else {
            throw NSError(domain: "ExcelExport", code: -2, userInfo: [NSLocalizedDescriptionKey: L10n.t("未找到导出脚本 export_order.py")])
        }
        
        let resolvedFormat: OrderOutputFileFormat = template.requiresBundledXLSXTemplate ? .xlsx : fileFormat
        let defaultDir: String = {
            if templatePath != "-" {
                let parent = (templatePath as NSString).deletingLastPathComponent
                if !parent.contains(".app/") && !parent.contains(".bundle") {
                    return parent
                }
            }
            let projRoot = CloneStudioResourceLocator.projectRootDirectory
            for cand in [projRoot.path, projRoot.deletingLastPathComponent().path] {
                if FileManager.default.fileExists(atPath: cand) {
                    return cand
                }
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        }()
        let outputDir = targetDir ?? defaultDir
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        
        let baseStem: String = {
            if template == .customJSON, let ct = customTemplate, !ct.name.isEmpty {
                let cleaned = ct.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "_")
                return cleaned
            }
            return (template.filename as NSString).deletingPathExtension
        }()
        let outputPath = (outputDir as NSString).appendingPathComponent("\(baseStem)_\(timestamp).\(resolvedFormat.rawValue)")
        
        var payload: [String: Any]
        if template.category == .primerSynthesis {
            payload = [
                "fileFormat": resolvedFormat.rawValue,
                "profile": [
                    "customerName": profile.customerName,
                    "piName": profile.piName,
                    "organization": profile.organization,
                    "phone": profile.phone,
                    "email": profile.email,
                    "address": profile.address,
                    "defaultPurity": profile.defaultPurity,
                    "defaultOD": profile.defaultOD
                ],
                "items": primers.map { [
                    "name": $0.name,
                    "fullSequence": $0.fullSequence,
                    "purity": $0.purity,
                    "od": $0.od,
                    "tubes": $0.tubes,
                    "targetPurpose": $0.targetPurpose,
                    "notes": $0.notes
                ]}
            ]
            if let ct = customTemplate,
               let ctData = try? JSONEncoder().encode(ct),
               let ctObj = try? JSONSerialization.jsonObject(with: ctData) {
                payload["customTemplate"] = ctObj
            }
        } else {
            payload = [
                "fileFormat": "xlsx",
                "profile": [
                    "customerName": profile.customerName,
                    "piName": profile.piName,
                    "organization": profile.organization,
                    "phone": profile.phone,
                    "email": profile.email,
                    "address": profile.address
                ],
                "items": samples.map { [
                    "sampleName": $0.sampleName,
                    "sampleType": $0.sampleType,
                    "resistance": $0.resistance,
                    "vectorName": $0.vectorName,
                    "fragmentLength": $0.fragmentLength,
                    "primerName": $0.primerName,
                    "primerName2": $0.primerName2,
                    "primerType": $0.primerType,
                    "primerCategory": $0.primerCategory,
                    "requirement": $0.requirement,
                    "characteristics": $0.characteristics,
                    "returnRequirement": $0.returnRequirement,
                    "notes": $0.notes
                ]}
            ]
        }
        
        let tempJsonPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("order_\(UUID().uuidString).json")
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
        try jsonData.write(to: URL(fileURLWithPath: tempJsonPath))
        
        defer {
            try? FileManager.default.removeItem(atPath: tempJsonPath)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptPath, template.rawValue, templatePath, outputPath, tempJsonPath]
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        try process.run()
        
        // 必须在 waitUntilExit() 之前并发排空 stdout/stderr 管道，防止子进程输出超过 64KB 时双向死锁
        var errData = Data()
        let errGroup = DispatchGroup()
        errGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errGroup.wait()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            let outStr = String(data: outData, encoding: .utf8) ?? ""
            let errMsg = errStr.isEmpty ? (outStr.isEmpty ? L10n.t("未知导出错误") : outStr) : errStr
            throw NSError(domain: "ExcelExport", code: -3, userInfo: [NSLocalizedDescriptionKey: L10n.tr("导出处理失败：\(errMsg)", "Export failed: \(errMsg)")])
        }
        
        return outputPath
    }
}
