import Foundation

/// 导出文件格式
public enum OrderOutputFileFormat: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case xlsx = "xlsx"
    case csv  = "csv"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .xlsx: return "Excel (.xlsx)"
        case .csv:  return "CSV (.csv)"
        }
    }
}

/// 订购单自定义列映射字段枚举
public enum OrderColumnField: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case index1Based           = "index1Based"
    case name                  = "name"
    case sanitizedNameIDT      = "sanitizedNameIDT"
    case sanitizedNameEurofins = "sanitizedNameEurofins"
    case sequence              = "sequence"
    case length                = "length"
    case well96                = "well96"
    case plateID               = "plateID"
    case scaleIDT              = "scaleIDT"
    case purificationRaw       = "purificationRaw"
    case purificationIDT       = "purificationIDT"
    case od                    = "od"
    case tubes                 = "tubes"
    case targetPurpose         = "targetPurpose"
    case notes                 = "notes"
    case mod5Prime             = "mod5Prime"
    case mod3Prime             = "mod3Prime"
    case customerName          = "customerName"
    case organization          = "organization"
    case staticDefault         = "staticDefault"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .index1Based:           return "序号 (1..N)"
        case .name:                  return "引物 / 基因名称"
        case .sanitizedNameIDT:      return "IDT 安全名称"
        case .sanitizedNameEurofins: return "Eurofins 25字符名称"
        case .sequence:              return "5'->3' 序列"
        case .length:                return "碱基长度 (bp)"
        case .well96:                return "96孔板孔位 (A1..H12)"
        case .plateID:               return "板号 (Plate_1)"
        case .scaleIDT:              return "IDT 规模 (25nm/100nm)"
        case .purificationRaw:       return "纯化方式 (原值)"
        case .purificationIDT:       return "IDT 纯化 (STD/HPLC/PAGE)"
        case .od:                    return "合成规格 (OD)"
        case .tubes:                 return "分装管数"
        case .targetPurpose:         return "用途 / 构建目标"
        case .notes:                 return "备注"
        case .mod5Prime:             return "5' 修饰"
        case .mod3Prime:             return "3' 修饰"
        case .customerName:          return "订购人姓名"
        case .organization:          return "所属单位"
        case .staticDefault:         return "固定默认值"
        }
    }
}

/// 单列映射配置
public struct OrderColumnMapping: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var header: String
    public var field: OrderColumnField
    public var defaultValue: String

    public init(
        id: String = UUID().uuidString,
        header: String,
        field: OrderColumnField,
        defaultValue: String = ""
    ) {
        self.id = id
        self.header = header
        self.field = field
        self.defaultValue = defaultValue
    }
}

/// 国际供应商及自定义 JSON 列映射订购模板规范
public struct CustomOrderTemplateSpec: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var vendorLabel: String
    public var preferredFormat: OrderOutputFileFormat
    public var delimiter: String
    public var includeHeader: Bool
    public var sheetName: String
    public var sanitizeNameChars: String
    public var maxNameLength: Int
    public var columns: [OrderColumnMapping]

    public init(
        id: String = UUID().uuidString,
        name: String,
        vendorLabel: String = "Custom",
        preferredFormat: OrderOutputFileFormat = .csv,
        delimiter: String = ",",
        includeHeader: Bool = true,
        sheetName: String = "Order",
        sanitizeNameChars: String = "",
        maxNameLength: Int = 0,
        columns: [OrderColumnMapping]
    ) {
        self.id = id
        self.name = name
        self.vendorLabel = vendorLabel
        self.preferredFormat = preferredFormat
        self.delimiter = delimiter
        self.includeHeader = includeHeader
        self.sheetName = sheetName
        self.sanitizeNameChars = sanitizeNameChars
        self.maxNameLength = maxNameLength
        self.columns = columns
    }
}

/// 国际化合成模板预设、名称合规性清洗与自定义列映射引擎
public enum OrderTemplateEngine {

    public static let idtDisallowedChars: String = "<>'/\\&\",~"

    public static func defaultCustomTemplate() -> CustomOrderTemplateSpec {
        CustomOrderTemplateSpec(
            id: "custom_default",
            name: "自定义实验室引物/基因表",
            vendorLabel: "Lab Custom",
            preferredFormat: .csv,
            delimiter: ",",
            includeHeader: true,
            sheetName: "OligoOrder",
            sanitizeNameChars: "",
            maxNameLength: 0,
            columns: [
                OrderColumnMapping(header: "Name", field: .name),
                OrderColumnMapping(header: "Sequence", field: .sequence),
                OrderColumnMapping(header: "Length_bp", field: .length),
                OrderColumnMapping(header: "Scale", field: .scaleIDT, defaultValue: "25nm"),
                OrderColumnMapping(header: "Purification", field: .purificationIDT, defaultValue: "STD"),
                OrderColumnMapping(header: "Well", field: .well96),
                OrderColumnMapping(header: "Notes", field: .notes)
            ]
        )
    }

    public static func builtinPreset(for template: OrderFormTemplate) -> CustomOrderTemplateSpec? {
        switch template {
        case .idtBulk:
            return CustomOrderTemplateSpec(
                id: "builtin_idt_bulk",
                name: "IDT Bulk Input",
                vendorLabel: "IDT",
                preferredFormat: .xlsx,
                sheetName: "IDT Bulk Input",
                sanitizeNameChars: idtDisallowedChars,
                columns: [
                    OrderColumnMapping(header: "Name", field: .sanitizedNameIDT),
                    OrderColumnMapping(header: "Sequence", field: .sequence),
                    OrderColumnMapping(header: "Scale", field: .scaleIDT, defaultValue: "25nm"),
                    OrderColumnMapping(header: "Purification", field: .purificationIDT, defaultValue: "STD")
                ]
            )
        case .twistBulk:
            return CustomOrderTemplateSpec(
                id: "builtin_twist_bulk",
                name: "Twist Bioscience Bulk",
                vendorLabel: "Twist Bioscience",
                preferredFormat: .csv,
                sheetName: "Twist Order",
                columns: [
                    OrderColumnMapping(header: "Sequence Name", field: .name),
                    OrderColumnMapping(header: "Sequence", field: .sequence),
                    OrderColumnMapping(header: "Well Position", field: .well96),
                    OrderColumnMapping(header: "Plate ID", field: .plateID),
                    OrderColumnMapping(header: "Length (bp)", field: .length),
                    OrderColumnMapping(header: "Notes", field: .notes)
                ]
            )
        case .genscriptBulk:
            return CustomOrderTemplateSpec(
                id: "builtin_genscript_bulk",
                name: "GenScript GenSmart Bulk",
                vendorLabel: "GenScript 金斯瑞",
                preferredFormat: .xlsx,
                sheetName: "GenScript Order",
                columns: [
                    OrderColumnMapping(header: "Gene/Oligo Name", field: .name),
                    OrderColumnMapping(header: "Sequence (5'-3')", field: .sequence),
                    OrderColumnMapping(header: "Length (nt)", field: .length),
                    OrderColumnMapping(header: "Scale / Quantity", field: .od, defaultValue: "2.0 OD"),
                    OrderColumnMapping(header: "Purification", field: .purificationRaw, defaultValue: "PAGE"),
                    OrderColumnMapping(header: "Well Position", field: .well96),
                    OrderColumnMapping(header: "Notes", field: .notes)
                ]
            )
        case .eurofinsBulk:
            return CustomOrderTemplateSpec(
                id: "builtin_eurofins_bulk",
                name: "Eurofins Genomics Plate",
                vendorLabel: "Eurofins Genomics",
                preferredFormat: .csv,
                sheetName: "Eurofins Plate",
                sanitizeNameChars: " ,.",
                maxNameLength: 25,
                columns: [
                    OrderColumnMapping(header: "Well", field: .well96),
                    OrderColumnMapping(header: "Oligo Name", field: .sanitizedNameEurofins),
                    OrderColumnMapping(header: "Sequence", field: .sequence),
                    OrderColumnMapping(header: "Plate Name", field: .plateID),
                    OrderColumnMapping(header: "5' Modification", field: .mod5Prime),
                    OrderColumnMapping(header: "3' Modification", field: .mod3Prime),
                    OrderColumnMapping(header: "Purification", field: .purificationIDT, defaultValue: "STD"),
                    OrderColumnMapping(header: "Notes", field: .notes)
                ]
            )
        case .bgiBulk:
            return CustomOrderTemplateSpec(
                id: "builtin_bgi_bulk",
                name: "华大基因 (BGI) 批量合成",
                vendorLabel: "BGI 华大基因",
                preferredFormat: .xlsx,
                sheetName: "BGI Synthesis Order",
                columns: [
                    OrderColumnMapping(header: "引物/基因名称 (Name)", field: .name),
                    OrderColumnMapping(header: "序列 (5'->3')", field: .sequence),
                    OrderColumnMapping(header: "碱基数 (bp)", field: .length),
                    OrderColumnMapping(header: "合成规格 (OD)", field: .od),
                    OrderColumnMapping(header: "纯化方式 (Purification)", field: .purificationRaw),
                    OrderColumnMapping(header: "管数 (Tubes)", field: .tubes),
                    OrderColumnMapping(header: "用途/备注 (Notes)", field: .notes)
                ]
            )
        case .customJSON:
            return defaultCustomTemplate()
        case .tsingkePrimer, .tsingkeSeq, .sangonSeq, .sangonV9Seq:
            return nil
        }
    }

    // MARK: - 字段换算与名称清洗辅助

    public static func idtScale(fromOD od: Double) -> String {
        if od <= 2.0 { return "25nm" }
        if od <= 5.0 { return "100nm" }
        if od <= 10.0 { return "250nm" }
        return "1um"
    }

    public static func idtPurification(from purity: String) -> String {
        let up = purity.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if up.contains("PAGE") { return "PAGE" }
        if up.contains("HPLC") { return "HPLC" }
        if up.contains("STD") || up.contains("DESALT") || up.contains("DSL") { return "STD" }
        return "STD"
    }

    public static func sanitizeName(_ raw: String, disallowedChars: String, maxLen: Int, replacement: Character? = nil) -> String {
        let disallowed = Set(disallowedChars)
        var cleaned = String(raw.compactMap { ch -> Character? in
            if disallowed.contains(ch) {
                return replacement
            }
            return ch
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "Oligo" }
        if maxLen > 0 && cleaned.count > maxLen {
            cleaned = String(cleaned.prefix(maxLen))
        }
        return cleaned
    }

    public static func well96(forIndex index: Int) -> (well: String, plateID: String) {
        let rows = ["A", "B", "C", "D", "E", "F", "G", "H"]
        let plateNum = (index / 96) + 1
        let within = index % 96
        let rowLetter = rows[within / 12]
        let colNum = (within % 12) + 1
        return ("\(rowLetter)\(colNum)", "Plate_\(plateNum)")
    }

    /// 检查当前引物清单在目标供应商模板下是否存在需要清洗/截断的合规告警
    public static func validateSanitizationWarnings(
        template: OrderFormTemplate,
        spec: CustomOrderTemplateSpec?,
        primers: [PrimerItem]
    ) -> [String] {
        var warnings: [String] = []
        let activeSpec = spec ?? builtinPreset(for: template)
        let badChars = Set(activeSpec?.sanitizeNameChars ?? (template == .idtBulk ? idtDisallowedChars : (template == .eurofinsBulk ? " ,." : "")))
        let maxLen = activeSpec?.maxNameLength ?? (template == .eurofinsBulk ? 25 : 0)

        for p in primers {
            let trimmed = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !badChars.isEmpty && trimmed.contains(where: { badChars.contains($0) }) {
                warnings.append("「\(trimmed)」含受限特殊字符，导出时将自动清洗")
            }
            if maxLen > 0 && trimmed.count > maxLen {
                warnings.append("「\(trimmed)」超过 \(maxLen) 字符限制，导出时将截断")
            }
            let cleanSeq = BioSequence.clean(p.fullSequence)
            if cleanSeq.count < p.fullSequence.trimmingCharacters(in: .whitespacesAndNewlines).count {
                warnings.append("「\(trimmed)」含非标准碱基或空白符，已自动规范化")
            }
        }
        return Array(warnings.prefix(6))
    }

    public static func renderRows(
        spec: CustomOrderTemplateSpec,
        primers: [PrimerItem],
        profile: OrderFormProfile = OrderFormProfile()
    ) -> [[String]] {
        return primers.enumerated().map { idx, p in
            let wellInfo = well96(forIndex: idx)
            let cleanSeq = p.fullSequence.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return spec.columns.map { col in
                let rawVal: String
                switch col.field {
                case .index1Based:
                    rawVal = "\(idx + 1)"
                case .name:
                    var val = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !spec.sanitizeNameChars.isEmpty || spec.maxNameLength > 0 {
                        val = sanitizeName(
                            val,
                            disallowedChars: spec.sanitizeNameChars,
                            maxLen: spec.maxNameLength,
                            replacement: spec.sanitizeNameChars.contains(" ") ? "_" : nil
                        )
                    }
                    rawVal = val
                case .sanitizedNameIDT:
                    rawVal = sanitizeName(p.name, disallowedChars: idtDisallowedChars, maxLen: 0, replacement: nil)
                case .sanitizedNameEurofins:
                    rawVal = sanitizeName(p.name, disallowedChars: " ,.", maxLen: 25, replacement: "_")
                case .sequence:
                    rawVal = cleanSeq
                case .length:
                    rawVal = "\(cleanSeq.count)"
                case .well96:
                    rawVal = wellInfo.well
                case .plateID:
                    rawVal = wellInfo.plateID
                case .scaleIDT:
                    rawVal = idtScale(fromOD: p.od)
                case .purificationRaw:
                    rawVal = p.purity.isEmpty ? profile.defaultPurity : p.purity
                case .purificationIDT:
                    rawVal = idtPurification(from: p.purity.isEmpty ? profile.defaultPurity : p.purity)
                case .od:
                    rawVal = String(format: "%.1f OD", p.od)
                case .tubes:
                    rawVal = "\(max(1, p.tubes))"
                case .targetPurpose:
                    rawVal = p.targetPurpose
                case .notes:
                    let combined = [p.targetPurpose, p.notes].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " | ")
                    rawVal = combined
                case .mod5Prime, .mod3Prime:
                    rawVal = ""
                case .customerName:
                    rawVal = profile.customerName
                case .organization:
                    rawVal = profile.organization
                case .staticDefault:
                    rawVal = col.defaultValue
                }
                return rawVal.isEmpty ? col.defaultValue : rawVal
            }
        }
    }

    public static func renderCSVPreview(
        spec: CustomOrderTemplateSpec,
        primers: [PrimerItem],
        profile: OrderFormProfile = OrderFormProfile()
    ) -> String {
        let sep = spec.delimiter.isEmpty ? "," : spec.delimiter
        func escapeCell(_ s: String) -> String {
            if s.contains("\"") || s.contains(sep) || s.contains("\n") || s.contains("\r") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        var lines: [String] = []
        if spec.includeHeader {
            lines.append(spec.columns.map { escapeCell($0.header) }.joined(separator: sep))
        }
        for row in renderRows(spec: spec, primers: primers, profile: profile) {
            lines.append(row.map(escapeCell).joined(separator: sep))
        }
        return lines.joined(separator: "\n")
    }
}

/// 自定义 JSON 列映射模板持久化存储
public enum CustomOrderTemplateStore {

    public static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Labworker", isDirectory: true)
            .appendingPathComponent("custom_order_templates.json")
    }

    public static func loadTemplates(from url: URL? = nil) -> [CustomOrderTemplateSpec] {
        let target = url ?? defaultStoreURL()
        guard let data = try? Data(contentsOf: target),
              let decoded = try? JSONDecoder().decode([CustomOrderTemplateSpec].self, from: data),
              !decoded.isEmpty else {
            return [OrderTemplateEngine.defaultCustomTemplate()]
        }
        return decoded
    }

    public static func saveTemplates(_ templates: [CustomOrderTemplateSpec], to url: URL? = nil) throws {
        let target = url ?? defaultStoreURL()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(templates)
        try data.write(to: target, options: .atomic)
    }
}
