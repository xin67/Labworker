import Foundation
import AppKit

// MARK: - SnapGene 数据模型

public struct SnapGeneSegment: Codable, Identifiable, Sendable {
    public var id: String { range }
    public let range: String
    public let start: Int
    public let end: Int
    public let color: String
    
    public init(range: String, start: Int, end: Int, color: String) {
        self.range = range
        self.start = start
        self.end = end
        self.color = color
    }
}

public struct SnapGeneFeature: Codable, Identifiable, Sendable {
    public var id: String { "\(name)_\(segments.first?.range ?? "")" }
    public let name: String
    public let type: String
    public let directionality: String
    public let segments: [SnapGeneSegment]
    
    public init(name: String, type: String, directionality: String = "1", segments: [SnapGeneSegment] = []) {
        self.name = name
        self.type = type
        self.directionality = directionality
        self.segments = segments
    }
}

public struct SnapGeneBindingSite: Codable, Sendable {
    public let location: String
    public let start: Int?
    public let end: Int?
    public let strand: String
    public let annealedBases: String
    public let tm: String
    
    public var resolvedStart: Int? {
        if let s = start { return s }
        let parts = location.split(separator: "-")
        if parts.count == 2, let s = Int(parts[0]) { return s }
        return nil
    }
    
    public var resolvedEnd: Int? {
        if let e = end { return e }
        let parts = location.split(separator: "-")
        if parts.count == 2, let e = Int(parts[1]) { return e }
        return nil
    }
}

public struct SnapGenePrimer: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let sequence: String
    public let bindingSites: [SnapGeneBindingSite]?
    
    public init(id: String, name: String, sequence: String, bindingSites: [SnapGeneBindingSite]? = nil) {
        self.id = id
        self.name = name
        self.sequence = sequence
        self.bindingSites = bindingSites
    }
    
    public var primarySite: SnapGeneBindingSite? {
        bindingSites?.first
    }
    
    public var startBp: Int? {
        primarySite?.resolvedStart
    }
    
    public var endBp: Int? {
        primarySite?.resolvedEnd
    }
    
    /// boundStrand == "0" 表示正义链 (5'->3' 顺时针 →)，"1" 表示反义互补链 (逆时针 ←)
    public var isForwardStrand: Bool {
        (primarySite?.strand ?? "0") == "0"
    }
    
    public var displayLabel: String {
        if let s = startBp, let e = endBp {
            let arrow = isForwardStrand ? "→" : "←"
            return "\(name) [\(s)..\(e) \(arrow)]"
        }
        return name
    }
}

/// 扫描出的载体真实内切酶切点项（含坐标、切点总数及所在特征注释）
public struct VectorCutSiteOption: Identifiable, Hashable, Sendable {
    public var id: String { "\(enzyme.name)_\(position1Based)" }
    public let enzyme: RestrictionEnzyme
    public let position1Based: Int // 1-based start of recognition site
    public let endPosition1Based: Int
    public let totalCutsInVector: Int
    public let overlappingFeatureName: String?
    
    public var isUnique: Bool { totalCutsInVector == 1 }
    
    public var displayTitle: String {
        let cutTag = totalCutsInVector == 1 ? L10n.t("★唯一切点") : L10n.tr("共\(totalCutsInVector)切点", "\(totalCutsInVector) cuts")
        let featTag = overlappingFeatureName != nil ? L10n.tr(" · 位于 \(overlappingFeatureName!)", " · in \(overlappingFeatureName!)") : ""
        return "\(enzyme.name) (@\(position1Based) bp, \(enzyme.site)) [\(cutTag)\(featTag)]"
    }
    
    public init(
        enzyme: RestrictionEnzyme,
        position1Based: Int,
        endPosition1Based: Int,
        totalCutsInVector: Int,
        overlappingFeatureName: String?
    ) {
        self.enzyme = enzyme
        self.position1Based = position1Based
        self.endPosition1Based = endPosition1Based
        self.totalCutsInVector = totalCutsInVector
        self.overlappingFeatureName = overlappingFeatureName
    }
}

public struct SnapGeneFileInfo: Codable, Sendable {
    public let filePath: String
    public let fileName: String
    public let sequence: String
    public let length: Int
    public let isCircular: Bool
    public let featuresCount: Int
    public let features: [SnapGeneFeature]
    public let primersCount: Int
    public let primers: [SnapGenePrimer]

    public init(
        filePath: String,
        fileName: String,
        sequence: String,
        length: Int,
        isCircular: Bool,
        featuresCount: Int,
        features: [SnapGeneFeature],
        primersCount: Int = 0,
        primers: [SnapGenePrimer] = []
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.sequence = sequence
        self.length = length
        self.isCircular = isCircular
        self.featuresCount = featuresCount
        self.features = features
        self.primersCount = primersCount
        self.primers = primers
    }
    
    /// 返回具有明确结合位点坐标的引物列表（按起始坐标升序）
    public var validBoundPrimers: [SnapGenePrimer] {
        primers.filter { $0.startBp != nil && $0.endBp != nil }
            .sorted { ($0.startBp ?? 0) < ($1.startBp ?? 0) }
    }
    
    private static let cutSiteCacheLock = NSLock()
    nonisolated(unsafe) private static var cutSiteScanCache: [String: [VectorCutSiteOption]] = [:]
    
    /// 扫描当前质粒序列中真实存在的限制性内切酶切点（带内存缓存，避免 UI 刷新重复扫描 441 个酶）
    public func scanAvailableCutSites(maxCutsPerEnzyme: Int = 2) -> [VectorCutSiteOption] {
        let cleanSeq = BioSequence.clean(sequence)
        guard cleanSeq.count >= 20 else { return [] }
        
        let cacheKey = "\(filePath)_\(cleanSeq.hashValue)_\(maxCutsPerEnzyme)_\(features.count)"
        Self.cutSiteCacheLock.lock()
        if let cached = Self.cutSiteScanCache[cacheKey] {
            Self.cutSiteCacheLock.unlock()
            return cached
        }
        Self.cutSiteCacheLock.unlock()
        
        var options: [VectorCutSiteOption] = []
        for enz in RestrictionEnzymeDatabase.shared.enzymes {
            let sites = enz.findSitesInCleaned(cleanSeq)
            guard !sites.isEmpty && sites.count <= maxCutsPerEnzyme else { continue }
            for pos0 in sites {
                let start1 = pos0 + 1
                let end1 = min(cleanSeq.count, pos0 + enz.site.count)
                let featName = features.first { f in
                    f.segments.contains { seg in start1 >= seg.start && start1 <= seg.end }
                }?.name
                options.append(VectorCutSiteOption(
                    enzyme: enz,
                    position1Based: start1,
                    endPosition1Based: end1,
                    totalCutsInVector: sites.count,
                    overlappingFeatureName: featName
                ))
            }
        }
        
        let sorted = options.sorted { a, b in
            if a.totalCutsInVector != b.totalCutsInVector {
                return a.totalCutsInVector < b.totalCutsInVector
            }
            return a.position1Based < b.position1Based
        }
        Self.cutSiteCacheLock.lock()
        if Self.cutSiteScanCache.count > 32 {
            Self.cutSiteScanCache.removeAll()
        }
        Self.cutSiteScanCache[cacheKey] = sorted
        Self.cutSiteCacheLock.unlock()
        return sorted
    }
}

public struct SnapGeneInjectResult: Codable, Sendable {
    public let status: String
    public let filePath: String
    public let backupPath: String?
    public let primersAdded: Int
    public let totalPrimers: Int
}

public struct SnapGeneAssembleResult: Codable, Sendable {
    public let status: String
    public let outputPath: String
    public let recombinantLength: Int
    public let insertRange: String
    public let featuresCount: Int
}

public struct SnapGeneDeleteResult: Codable, Sendable {
    public let status: String
    public let outputPath: String
    public let deletedLength: Int
    public let newLength: Int
    public let featuresCount: Int
}

public enum SnapGeneError: LocalizedError {
    case scriptNotFound
    case fileNotFound(String)
    case executionFailed(String)
    case invalidJSON(String)
    
    public var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return L10n.t("未找到 SnapGene 桥接助手脚本 (snapgene_bridge.py)")
        case .fileNotFound(let path):
            return L10n.tr("文件不存在: \(path)", "File not found: \(path)")
        case .executionFailed(let msg):
            return L10n.tr("SnapGene 处理执行失败: \(msg)", "SnapGene execution failed: \(msg)")
        case .invalidJSON(let msg):
            return L10n.tr("解析 SnapGene 返回数据失败: \(msg)", "Failed to decode SnapGene response: \(msg)")
        }
    }
}

// MARK: - SnapGene 核心服务管理器

public final class SnapGeneService: Sendable {
    public static let shared = SnapGeneService()
    
    private init() {}
    
    /// 将文件名中的特殊路径字符（如 / : \）替换为安全下划线，防止输出文件路径失效
    public static func sanitizeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Construct" : cleaned
    }
    
    /// 寻找 Python 脚本路径（惰性按序查找，避免在 .app 包中触发 Bundle.module 断言）
    private func locateScript() -> String? {
        CloneStudioResourceLocator.path(forResource: "snapgene_bridge", ofType: "py")
    }
    
    /// 同步执行 Python 桥接命令（先读取管道再 waitUntilExit，彻底消除 >64KB 输出时的 UNIX 管道死锁）
    private func runBridge(arguments: [String]) throws -> String {
        guard let scriptPath = locateScript() else {
            throw SnapGeneError.scriptNotFound
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptPath] + arguments
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        try process.run()
        
        // 必须在 waitUntilExit() 之前并发排空 stdout/stderr 管道，防止子进程输出超过 64KB 时主线程与子进程双向死锁
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
        
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        
        if process.terminationStatus != 0 {
            throw SnapGeneError.executionFailed(errStr.isEmpty ? outStr : errStr)
        }
        return outStr
    }
    
    /// 在后台线程异步执行 Python 桥接命令（绝不阻塞主线程 UI）
    private func runBridgeAsync(arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runBridge(arguments: arguments)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - 1. 解析 .dna 文件
    public func parseDNAFile(at url: URL) async throws -> SnapGeneFileInfo {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw SnapGeneError.fileNotFound(path)
        }
        
        let output = try await runBridgeAsync(arguments: ["parse", path])
        guard let data = output.data(using: .utf8) else {
            throw SnapGeneError.invalidJSON(L10n.t("输出编码异常"))
        }
        let decoder = JSONDecoder()
        return try decoder.decode(SnapGeneFileInfo.self, from: data)
    }
    
    // MARK: - 2. 向现有 .dna 文件原位注入引物 (自动留备份)
    @discardableResult
    public func injectPrimers(
        _ primers: [PrimerItem],
        into dnaURL: URL,
        createBackup: Bool = true
    ) async throws -> SnapGeneInjectResult {
        let path = dnaURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw SnapGeneError.fileNotFound(path)
        }
        
        // 构造引物 JSON（传递区分大小写的 formattedSequence、同源臂与特异退火区，确保 SnapGene 精确识别退火区与 5' 悬垂端）
        let primersData: [[String: String]] = primers.map { p in
            [
                "name": p.name,
                "fullSequence": p.formattedSequence,
                "homologyArm": p.homologyArm,
                "enzymeSite": p.enzymeSite ?? "",
                "specificSequence": p.specificSequence,
                "tm": p.tm != nil ? "\(Int(p.tm!.rounded()))" : "",
                "targetPurpose": p.targetPurpose,
                "notes": p.notes
            ]
        }
        
        let tempJsonPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("primers_\(UUID().uuidString).json")
        let jsonData = try JSONSerialization.data(withJSONObject: primersData, options: .prettyPrinted)
        try jsonData.write(to: URL(fileURLWithPath: tempJsonPath))
        defer {
            try? FileManager.default.removeItem(atPath: tempJsonPath)
        }
        
        let output = try await runBridgeAsync(arguments: [
            "inject",
            path,
            tempJsonPath,
            createBackup ? "1" : "0"
        ])
        
        guard let data = output.data(using: .utf8) else {
            throw SnapGeneError.invalidJSON(L10n.t("注入结果无法解析"))
        }
        let decoder = JSONDecoder()
        return try decoder.decode(SnapGeneInjectResult.self, from: data)
    }
    
    // MARK: - 3. 双质粒重组装配生成新 .dna
    @discardableResult
    public func assembleRecombinant(
        vectorURL: URL,
        insertSourceURL: URL?,
        insertSeq: String,
        insertName: String,
        cutStart: Int,
        cutEnd: Int,
        primers: [PrimerItem],
        outputURL: URL
    ) async throws -> SnapGeneAssembleResult {
        guard FileManager.default.fileExists(atPath: vectorURL.path) else {
            throw SnapGeneError.fileNotFound(vectorURL.path)
        }
        
        let cleanInsertSeq = BioSequence.clean(insertSeq)
        let donorPathArg = insertSourceURL?.path ?? "none"
        
        var tempJsonPath: String? = nil
        if !primers.isEmpty {
            let primersData: [[String: String]] = primers.map { p in
                [
                    "name": p.name,
                    "fullSequence": p.formattedSequence,
                    "homologyArm": p.homologyArm,
                    "enzymeSite": p.enzymeSite ?? "",
                    "specificSequence": p.specificSequence,
                    "tm": p.tm != nil ? "\(Int(p.tm!.rounded()))" : "",
                    "targetPurpose": p.targetPurpose,
                    "notes": p.notes
                ]
            }
            let p = (NSTemporaryDirectory() as NSString).appendingPathComponent("recomb_primers_\(UUID().uuidString).json")
            let jsonData = try JSONSerialization.data(withJSONObject: primersData, options: .prettyPrinted)
            try jsonData.write(to: URL(fileURLWithPath: p))
            tempJsonPath = p
        }
        
        defer {
            if let p = tempJsonPath {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
        
        let output = try await runBridgeAsync(arguments: [
            "assemble",
            vectorURL.path,
            cleanInsertSeq,
            insertName.isEmpty ? "Recombinant-Insert" : insertName,
            String(cutStart),
            String(cutEnd),
            tempJsonPath ?? "none",
            outputURL.path,
            donorPathArg
        ])
        
        guard let data = output.data(using: .utf8) else {
            throw SnapGeneError.invalidJSON(L10n.t("组装结果无法解析"))
        }
        let decoder = JSONDecoder()
        return try decoder.decode(SnapGeneAssembleResult.self, from: data)
    }
    
    // MARK: - 4. 质粒片段删除与新质粒导出
    public func deleteFragment(
        vectorURL: URL,
        delStart: Int,
        delEnd: Int,
        primers: [PrimerItem] = [],
        outputURL: URL
    ) async throws -> SnapGeneDeleteResult {
        guard FileManager.default.fileExists(atPath: vectorURL.path) else {
            throw SnapGeneError.fileNotFound(vectorURL.path)
        }
        
        var tempJsonPath: String? = nil
        if !primers.isEmpty {
            let primerDicts: [[String: String]] = primers.map { p in
                [
                    "name": p.name,
                    "fullSequence": p.formattedSequence,
                    "sequence": p.formattedSequence,
                    "homologyArm": p.homologyArm,
                    "enzymeSite": p.enzymeSite ?? "",
                    "specificSequence": p.specificSequence,
                    "tm": p.tm != nil ? "\(Int(p.tm!.rounded()))" : "",
                    "description": p.notes.isEmpty ? (p.targetPurpose + " (Tm: \(p.tm != nil ? String(format: "%.1f℃", p.tm!) : "N/A"))") : p.notes
                ]
            }
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sg_del_primers_\(UUID().uuidString).json")
            let data = try JSONSerialization.data(withJSONObject: primerDicts, options: .prettyPrinted)
            try data.write(to: tempURL)
            tempJsonPath = tempURL.path
        }
        
        defer {
            if let p = tempJsonPath {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
        
        let output = try await runBridgeAsync(arguments: [
            "delete",
            vectorURL.path,
            String(delStart),
            String(delEnd),
            tempJsonPath ?? "none",
            outputURL.path
        ])
        
        guard let data = output.data(using: .utf8) else {
            throw SnapGeneError.invalidJSON(L10n.t("删除结果无法解析"))
        }
        let decoder = JSONDecoder()
        return try decoder.decode(SnapGeneDeleteResult.self, from: data)
    }
    
    // MARK: - 5. 唤起 SnapGene 打开指定文件 (支持系统默认关联、多路径探测与命令行兜底)
    @MainActor
    public func openInSnapGene(url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            AppState.shared.showToast(L10n.tr("未找到生成的 .dna 文件: \(url.lastPathComponent)", "Generated .dna file not found: \(url.lastPathComponent)"))
            return
        }
        
        // 1. 优先通过系统 LaunchServices 打开 .dna 默认关联应用 (如用户安装的 SnapGene)
        if NSWorkspace.shared.open(url) {
            return
        }
        
        // 2. 备选：探测常见 SnapGene 安装路径或通过 /usr/bin/open 启动
        let candidateAppPaths = [
            "/Applications/SnapGene.app",
            "/Applications/SnapGene Viewer.app",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/SnapGene.app"),
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/SnapGene Viewer.app")
        ]
        
        if let appPath = candidateAppPaths.first(where: { fm.fileExists(atPath: $0) }) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", appPath, url.path]
            try? proc.run()
        } else {
            // 3. 兜底：在 Finder 中高亮选中该生成的 .dna 文件
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
