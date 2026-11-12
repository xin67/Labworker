import Foundation

/// 引物设计条目模型（用于结果显示、暂存与导出订购表）
public struct PrimerItem: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var fullSequence: String
    public var homologyArm: String
    public var enzymeName: String?
    public var enzymeSite: String?
    public var specificSequence: String
    public var tm: Double?
    public var gcPercent: Double?
    public var purity: String
    public var od: Double
    public var tubes: Int
    public var targetPurpose: String
    public var notes: String
    public var sourceTool: String
    public var dateAdded: Date
    
    public init(
        id: UUID = UUID(),
        name: String,
        fullSequence: String,
        homologyArm: String = "",
        enzymeName: String? = nil,
        enzymeSite: String? = nil,
        specificSequence: String = "",
        tm: Double? = nil,
        gcPercent: Double? = nil,
        purity: String = "PAGE",
        od: Double = 2.0,
        tubes: Int = 1,
        targetPurpose: String = "片段PCR扩增 / 同源重组",
        notes: String = "",
        sourceTool: String = "无缝克隆",
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.fullSequence = BioSequence.clean(fullSequence)
        self.homologyArm = BioSequence.clean(homologyArm).lowercased()
        self.enzymeName = enzymeName
        self.enzymeSite = enzymeSite.map { BioSequence.clean($0).lowercased() }
        self.specificSequence = BioSequence.clean(specificSequence).uppercased()
        self.tm = tm
        self.gcPercent = gcPercent ?? BioSequence.gcContent(fullSequence)
        self.purity = purity
        self.od = od
        self.tubes = tubes
        self.targetPurpose = targetPurpose
        self.notes = notes
        self.sourceTool = sourceTool
        self.dateAdded = dateAdded
    }
    
    /// 保留 5' 同源臂/酶切位点小写 + 3' 特异退火区大写的 SnapGene 标准格式序列
    public var formattedSequence: String {
        let prefix = homologyArm.lowercased() + (enzymeSite?.lowercased() ?? "")
        if !prefix.isEmpty && !specificSequence.isEmpty && (prefix.count + specificSequence.count == fullSequence.count) {
            return prefix + specificSequence.uppercased()
        }
        if !prefix.isEmpty && fullSequence.lowercased().hasPrefix(prefix) && fullSequence.count > prefix.count {
            let splitIdx = fullSequence.index(fullSequence.startIndex, offsetBy: prefix.count)
            return prefix + String(fullSequence[splitIdx...]).uppercased()
        }
        return fullSequence
    }
    
    public var length: Int {
        fullSequence.count
    }
    
    /// 从引物名称或用户输入中提取成对引物前缀（自动剥离末尾的 -F / -R / _F / _R 等后缀）
    public static func extractPairPrefix(from rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Primer" }
        let suffixes = ["-F", "-R", "_F", "_R", "-f", "-r", "_f", "_r", ".F", ".R", "-Fwd", "-Rev", "_Fwd", "_Rev"]
        for sfx in suffixes {
            if trimmed.hasSuffix(sfx) && trimmed.count > sfx.count {
                return String(trimmed.dropLast(sfx.count))
            }
        }
        return trimmed
    }
}
