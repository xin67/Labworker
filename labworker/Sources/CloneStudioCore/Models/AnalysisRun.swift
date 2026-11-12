import Foundation
import CryptoKit

// MARK: - 1. 轻量级动态类型 JSON 值容器 (AnyCodableValue)

public enum AnyCodableValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: AnyCodableValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported AnyCodableValue JSON token")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i):    try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b):   try container.encode(b)
        case .array(let a):  try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null:          try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        default:             return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

// MARK: - 2. 科学实验可复现溯源记录核心模型 (AnalysisRun, schemaVersion = 2)

public struct AnalysisRun: Codable, Hashable, Sendable {
    public struct InputFile: Codable, Hashable, Sendable {
        public let path: String
        public let sha256: String
        public let byteSize: Int64

        public init(path: String, sha256: String, byteSize: Int64) {
            self.path = path
            self.sha256 = sha256
            self.byteSize = byteSize
        }
    }

    public struct ManualEdit: Codable, Hashable, Sendable {
        public let what: String
        public let before: String
        public let after: String
        public let at: Date

        public init(what: String, before: String, after: String, at: Date = Date()) {
            self.what = what
            self.before = before
            self.after = after
            self.at = at
        }
    }

    public struct Exclusion: Codable, Hashable, Sendable {
        public let itemID: String
        public let reason: String

        public init(itemID: String, reason: String) {
            self.itemID = itemID
            self.reason = reason
        }
    }

    public let schemaVersion: Int
    public let runID: UUID
    public let module: String
    public let createdAt: Date
    public let appVersion: String
    public let gitCommit: String?
    public let engine: String
    public let inputs: [InputFile]
    public let parameters: [String: AnyCodableValue]
    public let manualEdits: [ManualEdit]
    public let exclusions: [Exclusion]
    public var outputs: [String]
    public var linkedPlasmidIDs: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID
        case module
        case createdAt
        case appVersion
        case gitCommit
        case engine
        case inputs
        case parameters
        case manualEdits
        case exclusions
        case outputs
        case linkedPlasmidIDs
    }

    public init(
        schemaVersion: Int = 2,
        runID: UUID = UUID(),
        module: String,
        createdAt: Date = Date(),
        appVersion: String? = nil,
        gitCommit: String? = nil,
        engine: String,
        inputs: [InputFile],
        parameters: [String: AnyCodableValue],
        manualEdits: [ManualEdit] = [],
        exclusions: [Exclusion] = [],
        outputs: [String] = [],
        linkedPlasmidIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.module = module
        self.createdAt = createdAt
        self.appVersion = appVersion ?? Self.resolveAppVersion()
        self.gitCommit = gitCommit ?? Self.resolveGitCommit()
        self.engine = engine
        self.inputs = inputs
        self.parameters = parameters
        self.manualEdits = manualEdits
        self.exclusions = exclusions
        self.outputs = outputs
        self.linkedPlasmidIDs = Array(Set(linkedPlasmidIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
    }

    /// 显式自定义解码以保证 schemaVersion = 1（不含 linkedPlasmidIDs）的旧版 .run.json 100% 向后兼容 (P15)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.runID = try c.decode(UUID.self, forKey: .runID)
        self.module = try c.decode(String.self, forKey: .module)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? "dev"
        self.gitCommit = try c.decodeIfPresent(String.self, forKey: .gitCommit)
        self.engine = try c.decode(String.self, forKey: .engine)
        self.inputs = try c.decodeIfPresent([InputFile].self, forKey: .inputs) ?? []
        self.parameters = try c.decodeIfPresent([String: AnyCodableValue].self, forKey: .parameters) ?? [:]
        self.manualEdits = try c.decodeIfPresent([ManualEdit].self, forKey: .manualEdits) ?? []
        self.exclusions = try c.decodeIfPresent([Exclusion].self, forKey: .exclusions) ?? []
        self.outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? []
        self.linkedPlasmidIDs = try c.decodeIfPresent([String].self, forKey: .linkedPlasmidIDs) ?? []
    }

    // MARK: - 环境版本与 SHA256 哈希工具

    public static func resolveAppVersion() -> String {
        if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !ver.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ver
        }
        return "dev"
    }

    public static func resolveGitCommit() -> String? {
        if let commit = Bundle.main.infoDictionary?["LWGitCommit"] as? String,
           !commit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           commit != "unknown" {
            return commit
        }
        return nil
    }

    public static func sha256Hex(ofData data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofString text: String) -> String {
        sha256Hex(ofData: Data(text.utf8))
    }

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return sha256Hex(ofData: data)
    }

    /// 计算输入文件相对于导出目录的相对路径（若无法构造相对路径则回退为文件名或标准化路径）
    public static func relativePath(of targetURL: URL, from baseDirectoryURL: URL?) -> String {
        guard let baseDir = baseDirectoryURL else {
            return targetURL.lastPathComponent
        }
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        let baseComponents = baseDir.standardizedFileURL.pathComponents
        var commonCount = 0
        while commonCount < min(targetComponents.count, baseComponents.count),
              targetComponents[commonCount] == baseComponents[commonCount] {
            commonCount += 1
        }
        if commonCount <= 1 {
            return targetURL.standardizedFileURL.path
        }
        let upCount = baseComponents.count - commonCount
        let downSlice = targetComponents[commonCount...]
        let relParts = Array(repeating: "..", count: max(0, upCount)) + Array(downSlice)
        return relParts.isEmpty ? targetURL.lastPathComponent : relParts.joined(separator: "/")
    }

    public static func makeInputFile(at fileURL: URL, relativeTo exportDirectoryURL: URL? = nil) -> InputFile? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        let rel = relativePath(of: fileURL, from: exportDirectoryURL)
        return InputFile(
            path: rel,
            sha256: sha256Hex(ofData: data),
            byteSize: Int64(data.count)
        )
    }

    /// 序列化为格式化的 JSON Data（ISO8601 时间戳 + sortedKeys）
    public func encodePrettyJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> AnalysisRun {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AnalysisRun.self, from: data)
    }

    /// 在导出产物（如 xxx.csv 或 xxx.html）同目录下写出 `<basename>.run.json` 溯源伴随文件，并在存在关联质粒时同步更新本地索引 (P09 / P15)
    @discardableResult
    public func writeSidecarJSON(
        alongsideOutputURL outputURL: URL,
        indexURL: URL? = nil,
        summary: String? = nil
    ) throws -> URL {
        let dir = outputURL.deletingLastPathComponent()
        let stem = outputURL.deletingPathExtension().lastPathComponent
        let sidecarURL = dir.appendingPathComponent("\(stem).run.json")
        let data = try encodePrettyJSONData()
        try data.write(to: sidecarURL, options: .atomic)
        if !linkedPlasmidIDs.isEmpty {
            AnalysisRunIndexStore.record(
                run: self,
                sidecarURL: sidecarURL,
                outputURL: outputURL,
                summary: summary,
                indexURL: indexURL
            )
        }
        return sidecarURL
    }

    /// 用于 HTML 报告底部的简明溯源签名字符串（包含 runID 与首个输入文件 SHA256 前 12 位）
    public var htmlProvenanceFooterText: String {
        let shaPrefix = inputs.first.map { String($0.sha256.prefix(12)) } ?? "in-memory"
        return "AnalysisRun ID: \(runID.uuidString) · Input SHA256(12): \(shaPrefix) · Engine: \(engine)"
    }
}

// MARK: - 3. 跨模块质粒关联溯源本地索引 (AnalysisRunIndexStore, P15)

public struct AnalysisRunIndexEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID { runID }
    public let runID: UUID
    public let schemaVersion: Int
    public let module: String
    public let createdAt: Date
    public let engine: String
    public let linkedPlasmidIDs: [String]
    public let summary: String
    public let sidecarFilePath: String
    public let outputFilePath: String

    public init(
        runID: UUID,
        schemaVersion: Int = 2,
        module: String,
        createdAt: Date,
        engine: String,
        linkedPlasmidIDs: [String],
        summary: String,
        sidecarFilePath: String,
        outputFilePath: String
    ) {
        self.runID = runID
        self.schemaVersion = schemaVersion
        self.module = module
        self.createdAt = createdAt
        self.engine = engine
        self.linkedPlasmidIDs = linkedPlasmidIDs
        self.summary = summary
        self.sidecarFilePath = sidecarFilePath
        self.outputFilePath = outputFilePath
    }
}

public enum AnalysisRunIndexStore {
    public static func defaultIndexURL() -> URL {
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("CloneStudio", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("analysis_runs_index.json")
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("analysis_runs_index.json")
    }

    public static func loadEntries(from customIndexURL: URL? = nil) -> [AnalysisRunIndexEntry] {
        let url = customIndexURL ?? defaultIndexURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AnalysisRunIndexEntry].self, from: data)) ?? []
    }

    public static func defaultSummary(for run: AnalysisRun, outputURL: URL) -> String {
        if let verdict = run.parameters["verdict"]?.stringValue {
            if let idPct = run.parameters["identityPercent"]?.doubleValue {
                return "\(verdict) (\(String(format: "%.1f%%", idPct)))"
            }
            return verdict
        }
        if let mode = run.parameters["mode"]?.stringValue, mode == "batch",
           let cloneCount = run.parameters["cloneCount"]?.intValue {
            return "批量测序验证 · \(cloneCount) 个克隆"
        }
        if let ctrl = run.parameters["resolvedControlLabel"]?.stringValue {
            return "qPCR ΔΔCt 分析 · 对照组 \(ctrl)"
        }
        if let bitDepth = run.parameters["bitDepth"]?.intValue {
            return "WB \(bitDepth)-bit 定量 · \(outputURL.lastPathComponent)"
        }
        return outputURL.lastPathComponent
    }

    public static func record(
        run: AnalysisRun,
        sidecarURL: URL,
        outputURL: URL,
        summary: String? = nil,
        indexURL customIndexURL: URL? = nil
    ) {
        let url = customIndexURL ?? defaultIndexURL()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var entries = loadEntries(from: url)
        entries.removeAll { $0.runID == run.runID }
        let entry = AnalysisRunIndexEntry(
            runID: run.runID,
            schemaVersion: run.schemaVersion,
            module: run.module,
            createdAt: run.createdAt,
            engine: run.engine,
            linkedPlasmidIDs: run.linkedPlasmidIDs,
            summary: summary ?? defaultSummary(for: run, outputURL: outputURL),
            sidecarFilePath: sidecarURL.path,
            outputFilePath: outputURL.path
        )
        entries.insert(entry, at: 0)
        entries.sort { $0.createdAt > $1.createdAt }
        if entries.count > 500 {
            entries = Array(entries.prefix(500))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func entries(
        forPlasmidID plasmidID: String,
        plasmidName: String? = nil,
        from customIndexURL: URL? = nil
    ) -> [AnalysisRunIndexEntry] {
        let all = loadEntries(from: customIndexURL)
        return all.filter { entry in
            entry.linkedPlasmidIDs.contains { linked in
                if linked == plasmidID { return true }
                if let name = plasmidName, !name.isEmpty, linked == name { return true }
                return false
            }
        }
    }
}
