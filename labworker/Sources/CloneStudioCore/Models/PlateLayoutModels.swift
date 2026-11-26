import Foundation
import SwiftUI

// MARK: - 1. 微孔板规格与几何定义 (Plate Format & Geometry)

public enum PlateFormat: Int, CaseIterable, Identifiable, Codable, Sendable {
    case well6 = 6
    case well12 = 12
    case well24 = 24
    case well48 = 48
    case well96 = 96
    case well384 = 384
    
    public var id: Int { rawValue }
    
    public var title: String {
        L10n.tr("\(rawValue) 孔板", "\(rawValue)-Well Plate")
    }
    
    public var rows: Int {
        switch self {
        case .well6:   return 2
        case .well12:  return 3
        case .well24:  return 4
        case .well48:  return 6
        case .well96:  return 8
        case .well384: return 16
        }
    }
    
    public var cols: Int {
        switch self {
        case .well6:   return 3
        case .well12:  return 4
        case .well24:  return 6
        case .well48:  return 8
        case .well96:  return 12
        case .well384: return 24
        }
    }
    
    public var totalWells: Int {
        rows * cols
    }
    
    public static func rowLabel(for row: Int) -> String {
        var n = row
        var label = ""
        repeat {
            let scalar = UnicodeScalar(65 + (n % 26))!
            label = String(Character(scalar)) + label
            n = (n / 26) - 1
        } while n >= 0
        return label
    }
    
    public static func wellID(row: Int, col: Int) -> String {
        "\(rowLabel(for: row))\(col + 1)"
    }
    
    public func isEdgeWell(row: Int, col: Int) -> Bool {
        row == 0 || col == 0 || row == rows - 1 || col == cols - 1
    }
    
    public func buildWellCells() -> [PlateWellCell] {
        var cells: [PlateWellCell] = []
        cells.reserveCapacity(totalWells)
        for r in 0..<rows {
            for c in 0..<cols {
                cells.append(
                    PlateWellCell(
                        id: Self.wellID(row: r, col: c),
                        row: r,
                        col: c,
                        isEdge: isEdgeWell(row: r, col: c)
                    )
                )
            }
        }
        return cells
    }
}

public struct PlateWellCell: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let row: Int
    public let col: Int
    public let isEdge: Bool
    
    public init(id: String, row: Int, col: Int, isEdge: Bool) {
        self.id = id
        self.row = row
        self.col = col
        self.isEdge = isEdge
    }
}

// MARK: - 2. 孔位类型与分配模型 (Well Assignment & Sample Row)

public enum StoredWellType: String, CaseIterable, Identifiable, Codable, Sendable {
    case sample = "sample"
    case control = "control"
    case blank = "blank"
    case reserved = "reserved"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .sample:   return "实验样品"
        case .control:  return "对照孔 (Ctrl)"
        case .blank:    return "空白孔 (Blank)"
        case .reserved: return "边缘预留"
        }
    }
}

public struct PlateWellAssignment: Identifiable, Hashable, Codable, Sendable {
    public var id: String { well }
    public var well: String
    public var row: Int
    public var col: Int
    public var type: StoredWellType
    public var sampleId: String
    public var sampleName: String
    public var group: String
    public var replicate: Int
    public var colorHex: String
    public var manual: Bool
    
    public init(
        well: String,
        row: Int,
        col: Int,
        type: StoredWellType,
        sampleId: String = "",
        sampleName: String = "",
        group: String = "",
        replicate: Int = 1,
        colorHex: String = "#3B82F6",
        manual: Bool = false
    ) {
        self.well = well
        self.row = row
        self.col = col
        self.type = type
        self.sampleId = sampleId
        self.sampleName = sampleName
        self.group = group
        self.replicate = replicate
        self.colorHex = colorHex
        self.manual = manual
    }
}

public struct PlateSampleItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var group: String
    public var colorHex: String
    /// nil 表示跟随全局复孔数规则
    public var customReplicates: Int?
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        group: String = "Default",
        colorHex: String = "",
        customReplicates: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.colorHex = colorHex
        self.customReplicates = customReplicates
    }
}

// MARK: - 3. 排布规则与校验结果 (Plate Rules & Validation Issues)

public enum PlateGroupLayoutStrategy: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"
    case row = "row"
    case column = "column"
    case block = "block"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .auto:   return "自动优选"
        case .row:    return "同行连续"
        case .column: return "同列连续"
        case .block:  return "矩形块"
        }
    }
}

public struct PlateLayoutRules: Hashable, Codable, Sendable {
    public var replicates: Int
    public var controls: Int
    public var blanks: Int
    public var reserveEdge: Bool
    public var avoidEdge: Bool
    public var keepTogether: Bool
    public var groupLayout: PlateGroupLayoutStrategy
    public var groupColumns: Int
    public var groupRows: Int
    public var randomize: Bool
    public var seed: UInt32
    
    public init(
        replicates: Int = 3,
        controls: Int = 2,
        blanks: Int = 2,
        reserveEdge: Bool = false,
        avoidEdge: Bool = true,
        keepTogether: Bool = true,
        groupLayout: PlateGroupLayoutStrategy = .auto,
        groupColumns: Int = 0,
        groupRows: Int = 0,
        randomize: Bool = true,
        seed: UInt32 = 20261104
    ) {
        self.replicates = max(1, min(12, replicates))
        self.controls = max(0, controls)
        self.blanks = max(0, blanks)
        self.reserveEdge = reserveEdge
        self.avoidEdge = avoidEdge
        self.keepTogether = keepTogether
        self.groupLayout = groupLayout
        self.groupColumns = max(0, groupColumns)
        self.groupRows = max(0, groupRows)
        self.randomize = randomize
        self.seed = seed
    }
}

public enum PlateIssueSeverity: String, Codable, Sendable {
    case error = "error"
    case warning = "warning"
    case info = "info"
}

public struct PlateLayoutIssue: Identifiable, Hashable, Codable, Sendable {
    public var id: String { "\(severity.rawValue):\(message)" }
    public let severity: PlateIssueSeverity
    public let message: String
    
    public init(severity: PlateIssueSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public struct PlateUnplacedSample: Identifiable, Hashable, Codable, Sendable {
    public var id: String { sampleId }
    public let sampleId: String
    public let name: String
    public let requested: Int
    public let placed: Int
    public let missing: Int
}

public struct PlateAssignResult: Sendable {
    public let assignments: [String: PlateWellAssignment]
    public let issues: [PlateLayoutIssue]
    public let unplaced: [PlateUnplacedSample]
    public let seed: UInt32
    public let reservedCount: Int
    public let assignedCount: Int
    public let sampleWellsCount: Int
    public let controlWellsCount: Int
    public let blankWellsCount: Int
}

public struct PlateTableRow: Identifiable, Hashable, Codable, Sendable {
    public var id: String { well }
    public let well: String
    public let row: Int
    public let col: Int
    public let sample: String
    public let group: String
    public let type: String
    public let replicate: Int?
}

// MARK: - 4. 预设科研配色板与颜色解析

public enum PlateColorPalette {
    public static let defaultGroupHexColors: [String] = [
        "#3B82F6", // Blue
        "#10B981", // Emerald
        "#F59E0B", // Amber
        "#EC4899", // Pink
        "#8B5CF6", // Violet
        "#06B6D4", // Cyan
        "#EF4444", // Red
        "#84CC16", // Lime
        "#F97316", // Orange
        "#6366F1"  // Indigo
    ]
    
    public static let controlHex = "#B48CFF"
    public static let blankHex = "#7F8BA8"
    public static let reservedHex = "#334155"
    
    public static func hexForGroup(_ group: String, indexFallback: Int = 0) -> String {
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("Control") == .orderedSame { return controlHex }
        if trimmed.caseInsensitiveCompare("Blank") == .orderedSame { return blankHex }
        var hash: UInt64 = 5381
        for byte in trimmed.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let idx = trimmed.isEmpty ? indexFallback : Int(hash % UInt64(defaultGroupHexColors.count))
        return defaultGroupHexColors[abs(idx) % defaultGroupHexColors.count]
    }
    
    public static func color(fromHex hex: String, fallback: Color = .blue) -> Color {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let val = UInt64(cleaned, radix: 16) else {
            return fallback
        }
        let r = Double((val >> 16) & 0xFF) / 255.0
        let g = Double((val >> 8) & 0xFF) / 255.0
        let b = Double(val & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}
