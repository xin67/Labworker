import Foundation

/// 蛋白质本地计算工具与对接/共折叠桥接引擎 (AutoDock Vina / Smina / Gnina / Boltz / Open Babel)
/// - 严格零第三方 Swift 依赖，所有可运行二进制路径均通过 `PATH`、常见 Homebrew/Conda 目录或用户覆盖动态探测。
public enum ProteinDockingBridgeEngine {

    // MARK: - 1. 工具类型与本地安装探测模型

    public enum LocalComputeToolKind: String, CaseIterable, Codable, Sendable, Identifiable {
        case vina = "vina"
        case smina = "smina"
        case gnina = "gnina"
        case boltz = "boltz"
        case obabel = "obabel"

        public var id: String { rawValue }

        public var cliName: String { rawValue }

        public var displayName: String {
            switch self {
            case .vina:   return "AutoDock Vina"
            case .smina:  return "Smina"
            case .gnina:  return "Gnina (CNN 深度学习打分)"
            case .boltz:  return "Boltz (全原子共折叠)"
            case .obabel: return "Open Babel (格式转换)"
            }
        }

        public var installHint: String {
            switch self {
            case .vina:   return "brew install autodock-vina"
            case .smina:  return "conda install -c conda-forge smina"
            case .gnina:  return "conda install -c conda-forge gnina"
            case .boltz:  return "pip install boltz"
            case .obabel: return "brew install open-babel"
            }
        }

        public var isDockingEngine: Bool {
            switch self {
            case .vina, .smina, .gnina: return true
            case .boltz, .obabel: return false
            }
        }
    }

    public struct DetectedCLITool: Identifiable, Codable, Sendable, Equatable {
        public var id: String { kind.rawValue }
        public let kind: LocalComputeToolKind
        public let executablePath: String?
        public let versionText: String?
        public let isAvailable: Bool
        public let installHint: String

        public init(
            kind: LocalComputeToolKind,
            executablePath: String?,
            versionText: String?,
            isAvailable: Bool,
            installHint: String
        ) {
            self.kind = kind
            self.executablePath = executablePath
            self.versionText = versionText
            self.isAvailable = isAvailable
            self.installHint = installHint
        }
    }

    public struct DockingPose: Identifiable, Codable, Sendable, Equatable {
        public var id: Int { modeIndex }
        public let modeIndex: Int
        public let affinityKcalMol: Double
        public let rmsdLB: Double
        public let rmsdUB: Double
        public let cnnScore: Double?
        public let cnnAffinity: Double?
        public let pdbqtBlock: String
        public let pdbBlock: String

        public init(
            modeIndex: Int,
            affinityKcalMol: Double,
            rmsdLB: Double,
            rmsdUB: Double,
            cnnScore: Double? = nil,
            cnnAffinity: Double? = nil,
            pdbqtBlock: String,
            pdbBlock: String
        ) {
            self.modeIndex = modeIndex
            self.affinityKcalMol = affinityKcalMol
            self.rmsdLB = rmsdLB
            self.rmsdUB = rmsdUB
            self.cnnScore = cnnScore
            self.cnnAffinity = cnnAffinity
            self.pdbqtBlock = pdbqtBlock
            self.pdbBlock = pdbBlock
        }
    }

    public struct DockingExecutionResult: Codable, Sendable, Equatable {
        public let tool: LocalComputeToolKind
        public let poses: [DockingPose]
        public let outputFilePath: String
        public let stdoutLog: String
        public let stderrLog: String
        public let elapsedSeconds: Double

        public init(
            tool: LocalComputeToolKind,
            poses: [DockingPose],
            outputFilePath: String,
            stdoutLog: String,
            stderrLog: String,
            elapsedSeconds: Double
        ) {
            self.tool = tool
            self.poses = poses
            self.outputFilePath = outputFilePath
            self.stdoutLog = stdoutLog
            self.stderrLog = stderrLog
            self.elapsedSeconds = elapsedSeconds
        }
    }

    public struct BoltzConfidenceSummary: Codable, Sendable, Equatable {
        public let confidenceScore: Double?
        public let ptm: Double?
        public let iptm: Double?
        public let ligandIptm: Double?
        public let complexPLDDT: Double?
        public let structureFilePath: String?
        public let structureFormat: String?
        public let structureText: String?

        public init(
            confidenceScore: Double?,
            ptm: Double?,
            iptm: Double?,
            ligandIptm: Double?,
            complexPLDDT: Double?,
            structureFilePath: String?,
            structureFormat: String?,
            structureText: String?
        ) {
            self.confidenceScore = confidenceScore
            self.ptm = ptm
            self.iptm = iptm
            self.ligandIptm = ligandIptm
            self.complexPLDDT = complexPLDDT
            self.structureFilePath = structureFilePath
            self.structureFormat = structureFormat
            self.structureText = structureText
        }
    }

    public enum BridgeError: LocalizedError {
        case missingExecutable(String)
        case missingOpenBabel(String)
        case invalidInput(String)
        case processFailed(String)

        public var errorDescription: String? {
            switch self {
            case .missingExecutable(let msg),
                 .missingOpenBabel(let msg),
                 .invalidInput(let msg),
                 .processFailed(let msg):
                return msg
            }
        }
    }

    // MARK: - 2. 本地二进制自动探测

    public static func detectInstalledTools(
        customOverrides: [LocalComputeToolKind: String] = [:]
    ) -> [DetectedCLITool] {
        let fm = FileManager.default
        let searchDirs = candidateBinaryDirectories()

        return LocalComputeToolKind.allCases.map { kind in
            var resolvedPath: String? = nil
            if let custom = customOverrides[kind]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !custom.isEmpty,
               fm.isExecutableFile(atPath: custom) {
                resolvedPath = custom
            }
            if resolvedPath == nil {
                for dir in searchDirs {
                    let cand = (dir as NSString).appendingPathComponent(kind.cliName)
                    if fm.isExecutableFile(atPath: cand) {
                        resolvedPath = cand
                        break
                    }
                }
            }

            guard let exe = resolvedPath else {
                return DetectedCLITool(
                    kind: kind,
                    executablePath: nil,
                    versionText: nil,
                    isAvailable: false,
                    installHint: kind.installHint
                )
            }

            let versionArg = (kind == .obabel) ? ["-V"] : ["--version"]
            let ver = probeVersionString(executablePath: exe, arguments: versionArg)
            return DetectedCLITool(
                kind: kind,
                executablePath: exe,
                versionText: ver,
                isAvailable: true,
                installHint: kind.installHint
            )
        }
    }

    private static func candidateBinaryDirectories() -> [String] {
        var dirs: [String] = []
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: pathEnv.split(separator: ":").map(String.init))
        }
        let standard = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let userSubdirs = [
            "miniforge3/bin",
            "miniconda3/bin",
            "anaconda3/bin",
            "mambaforge/bin",
            "micromamba/bin",
            ".local/bin",
            ".venv/bin",
            ".cargo/bin"
        ].map { homeURL.appendingPathComponent($0).path }

        var seen = Set<String>()
        var result: [String] = []
        for d in dirs + standard + userSubdirs where !d.isEmpty {
            if seen.insert(d).inserted {
                result.append(d)
            }
        }
        return result
    }

    private static func probeVersionString(executablePath: String, arguments: [String]) -> String? {
        let res = try? runProcessSync(executablePath: executablePath, arguments: arguments, timeoutSeconds: 3.0)
        let combined = ((res?.stdout ?? "") + "\n" + (res?.stderr ?? ""))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return combined
    }

    // MARK: - 3. PDBQT -> 标准 PDB 清洗转换 & 对接 Pose 解析

    private static let adElementMap: [String: String] = [
        "A": "C", "C": "C",
        "OA": "O", "OS": "O", "O": "O",
        "NA": "N", "NS": "N", "N": "N",
        "SA": "S", "S": "S",
        "HD": "H", "HS": "H", "H": "H",
        "P": "P", "F": "F", "I": "I",
        "CL": "CL", "BR": "BR",
        "FE": "FE", "MG": "MG", "ZN": "ZN", "MN": "MN", "CA": "CA"
    ]

    /// 将 AutoDock PDBQT（含部分电荷与 AD 扩展原子类型）无损转换为标准 PDB v3.3，供 Mol* 正确成键与识别非共价相互作用
    public static func convertPDBQTBlockToPDB(_ pdbqt: String) -> String {
        var outLines: [String] = []
        for raw in pdbqt.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            if line.hasPrefix("ATOM  ") || line.hasPrefix("HETATM") {
                var chars = Array(line)
                if chars.count < 66 {
                    chars.append(contentsOf: Array(repeating: Character(" "), count: 66 - chars.count))
                }
                let prefix66 = String(chars[0..<66])
                let trimmedTokens = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0.isWhitespace })
                let rawADType = trimmedTokens.last.map { String($0).uppercased() } ?? ""

                var elem = adElementMap[rawADType]
                if elem == nil {
                    let atomNameField = String(chars[12..<16]).trimmingCharacters(in: .whitespaces).uppercased()
                    let letters = String(atomNameField.prefix { $0.isLetter })
                    if letters.hasPrefix("CL") { elem = "CL" }
                    else if letters.hasPrefix("BR") { elem = "BR" }
                    else if letters.hasPrefix("ZN") { elem = "ZN" }
                    else if letters.hasPrefix("MG") { elem = "MG" }
                    else if letters.hasPrefix("FE") { elem = "FE" }
                    else if let firstCh = letters.first { elem = String(firstCh) }
                    else { elem = "C" }
                }
                let resolvedElem = elem ?? "C"
                let paddedElem = resolvedElem.count == 1 ? " \(resolvedElem)" : String(resolvedElem.prefix(2))
                outLines.append(prefix66 + "          " + paddedElem)
            } else if line.hasPrefix("MODEL") || line.hasPrefix("ENDMDL") || line.hasPrefix("TER")
                        || line.hasPrefix("CONECT") || line.hasPrefix("END") || line.hasPrefix("REMARK")
                        || line.hasPrefix("CRYST1") {
                outLines.append(line)
            }
        }
        return outLines.joined(separator: "\n")
    }

    private struct TableScoreEntry {
        let mode: Int
        let affinity: Double
        let rmsdLB: Double
        let rmsdUB: Double
        let cnnScore: Double?
        let cnnAffinity: Double?
    }

    public static func parseDockingResults(
        stdoutText: String,
        outputFileText: String,
        tool: LocalComputeToolKind
    ) -> [DockingPose] {
        var scoreByMode: [Int: TableScoreEntry] = [:]

        // 1. 解析 Vina / Smina / Gnina 控制台打分表
        for line in stdoutText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let cols = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard cols.count >= 4, let mode = Int(cols[0]), mode >= 1,
                  let aff = Double(cols[1]), let c2 = Double(cols[2]), let c3 = Double(cols[3]) else {
                continue
            }
            if cols.count >= 5, let c4 = Double(cols[4]) {
                // Gnina 5-column table: mode | affinity | intramol | CNN pose score | CNN affinity
                scoreByMode[mode] = TableScoreEntry(
                    mode: mode,
                    affinity: aff,
                    rmsdLB: 0.0,
                    rmsdUB: 0.0,
                    cnnScore: c3,
                    cnnAffinity: c4
                )
            } else if tool == .gnina && cols.count == 4 {
                scoreByMode[mode] = TableScoreEntry(
                    mode: mode,
                    affinity: aff,
                    rmsdLB: 0.0,
                    rmsdUB: 0.0,
                    cnnScore: c2,
                    cnnAffinity: c3
                )
            } else {
                // Standard Vina / Smina 4-column table: mode | affinity | rmsd l.b. | rmsd u.b.
                scoreByMode[mode] = TableScoreEntry(
                    mode: mode,
                    affinity: aff,
                    rmsdLB: c2,
                    rmsdUB: c3,
                    cnnScore: nil,
                    cnnAffinity: nil
                )
            }
        }

        // 2. 拆分结构文件中的多 Pose 块（支持 multi-MODEL PDBQT/PDB 或 $$$$ 分隔 SDF）
        let rawBlocks = splitPoseBlocks(outputFileText)
        guard !rawBlocks.isEmpty else {
            return scoreByMode.values
                .sorted { $0.mode < $1.mode }
                .map { s in
                    DockingPose(
                        modeIndex: s.mode,
                        affinityKcalMol: s.affinity,
                        rmsdLB: s.rmsdLB,
                        rmsdUB: s.rmsdUB,
                        cnnScore: s.cnnScore,
                        cnnAffinity: s.cnnAffinity,
                        pdbqtBlock: "",
                        pdbBlock: ""
                    )
                }
        }

        var poses: [DockingPose] = []
        for (idx, blockInfo) in rawBlocks.enumerated() {
            let mode = blockInfo.mode ?? (idx + 1)
            let tableEntry = scoreByMode[mode]
            let remarkScores = extractRemarksFromBlock(blockInfo.text)

            let aff = tableEntry?.affinity ?? remarkScores.affinity ?? 0.0
            let rLB = tableEntry?.rmsdLB ?? remarkScores.rmsdLB ?? 0.0
            let rUB = tableEntry?.rmsdUB ?? remarkScores.rmsdUB ?? 0.0
            let cnnS = tableEntry?.cnnScore ?? remarkScores.cnnScore
            let cnnA = tableEntry?.cnnAffinity ?? remarkScores.cnnAffinity

            let isSDF = blockInfo.text.contains("V2000") || blockInfo.text.contains("V3000") || blockInfo.text.contains("$$$$")
            let pdbConverted = isSDF ? "" : convertPDBQTBlockToPDB(blockInfo.text)

            poses.append(
                DockingPose(
                    modeIndex: mode,
                    affinityKcalMol: aff,
                    rmsdLB: rLB,
                    rmsdUB: rUB,
                    cnnScore: cnnS,
                    cnnAffinity: cnnA,
                    pdbqtBlock: blockInfo.text,
                    pdbBlock: pdbConverted
                )
            )
        }
        return poses.sorted { $0.modeIndex < $1.modeIndex }
    }

    private static func splitPoseBlocks(_ text: String) -> [(mode: Int?, text: String)] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }

        if normalized.contains("$$$$") {
            let chunks = normalized.components(separatedBy: "$$$$")
            return chunks.enumerated().compactMap { idx, chunk in
                let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (idx + 1, trimmed + "\n$$$$\n")
            }
        }

        let lines = normalized.components(separatedBy: "\n")
        var blocks: [(mode: Int?, text: String)] = []
        var currentLines: [String] = []
        var currentMode: Int? = nil
        var insideModel = false

        for line in lines {
            if line.hasPrefix("MODEL ") {
                if !currentLines.isEmpty {
                    blocks.append((currentMode, currentLines.joined(separator: "\n")))
                    currentLines.removeAll()
                }
                insideModel = true
                let numStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                currentMode = Int(numStr)
                currentLines.append(line)
            } else if line.hasPrefix("ENDMDL") {
                currentLines.append(line)
                blocks.append((currentMode, currentLines.joined(separator: "\n")))
                currentLines.removeAll()
                currentMode = nil
                insideModel = false
            } else {
                if insideModel || line.hasPrefix("ATOM  ") || line.hasPrefix("HETATM") || line.hasPrefix("REMARK") || line.hasPrefix("ROOT") || line.hasPrefix("ENDROOT") || line.hasPrefix("BRANCH") || line.hasPrefix("ENDBRANCH") || line.hasPrefix("TORSDOF") {
                    currentLines.append(line)
                }
            }
        }
        if !currentLines.isEmpty {
            let joined = currentLines.joined(separator: "\n")
            if joined.contains("ATOM  ") || joined.contains("HETATM") {
                blocks.append((currentMode ?? 1, joined))
            }
        }
        return blocks
    }

    private static func extractRemarksFromBlock(_ block: String) -> (affinity: Double?, rmsdLB: Double?, rmsdUB: Double?, cnnScore: Double?, cnnAffinity: Double?) {
        var aff: Double? = nil
        var rLB: Double? = nil
        var rUB: Double? = nil
        var cnnS: Double? = nil
        var cnnA: Double? = nil

        let lines = block.components(separatedBy: .newlines)
        for (idx, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("REMARK VINA RESULT:") {
                let rest = t.replacingOccurrences(of: "REMARK VINA RESULT:", with: "")
                let nums = rest.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
                if nums.count >= 1 { aff = nums[0] }
                if nums.count >= 2 { rLB = nums[1] }
                if nums.count >= 3 { rUB = nums[2] }
            } else if t.hasPrefix("REMARK minimizedAffinity") {
                if let val = t.split(whereSeparator: { $0.isWhitespace }).last.flatMap({ Double($0) }) {
                    aff = aff ?? val
                }
            } else if t.hasPrefix("REMARK CNNscore") {
                if let val = t.split(whereSeparator: { $0.isWhitespace }).last.flatMap({ Double($0) }) {
                    cnnS = cnnS ?? val
                }
            } else if t.hasPrefix("REMARK CNNaffinity") {
                if let val = t.split(whereSeparator: { $0.isWhitespace }).last.flatMap({ Double($0) }) {
                    cnnA = cnnA ?? val
                }
            } else if t == ">  <minimizedAffinity>" || t == "> <minimizedAffinity>", idx + 1 < lines.count {
                aff = aff ?? Double(lines[idx + 1].trimmingCharacters(in: .whitespaces))
            } else if t == ">  <CNNscore>" || t == "> <CNNscore>", idx + 1 < lines.count {
                cnnS = cnnS ?? Double(lines[idx + 1].trimmingCharacters(in: .whitespaces))
            } else if t == ">  <CNNaffinity>" || t == "> <CNNaffinity>", idx + 1 < lines.count {
                cnnA = cnnA ?? Double(lines[idx + 1].trimmingCharacters(in: .whitespaces))
            }
        }
        return (aff, rLB, rUB, cnnS, cnnA)
    }

    // MARK: - 3.5 受体清洗、质子化与 Vina 参数构建 (Sub-batch 3C)

    public struct ReceptorPrepStats: Codable, Sendable, Equatable {
        public let keptAtomCount: Int
        public let keptCofactorAtomCount: Int
        public let removedWaterCount: Int
        public let removedHetatmCount: Int
        public let removedAltLocCount: Int
        public let truncatedExtraModels: Bool
        public let hasNonCAHeavyAtoms: Bool

        public init(
            keptAtomCount: Int,
            keptCofactorAtomCount: Int,
            removedWaterCount: Int,
            removedHetatmCount: Int,
            removedAltLocCount: Int,
            truncatedExtraModels: Bool,
            hasNonCAHeavyAtoms: Bool
        ) {
            self.keptAtomCount = keptAtomCount
            self.keptCofactorAtomCount = keptCofactorAtomCount
            self.removedWaterCount = removedWaterCount
            self.removedHetatmCount = removedHetatmCount
            self.removedAltLocCount = removedAltLocCount
            self.truncatedExtraModels = truncatedExtraModels
            self.hasNonCAHeavyAtoms = hasNonCAHeavyAtoms
        }
    }

    private static let waterResNames: Set<String> = ["HOH", "WAT", "DOD", "TIP", "TIP3", "SOL"]

    /// 清洗受体 PDB / mmCIF 结构用于本地分子对接：
    /// 1) 拦截教学用 SPICE 合成模型 (`LABWORKER_SPICE_FOLD`) 与仅含 Cα 骨架的粗粒化结构（缺少全原子侧链）；
    /// 2) 截断多 MODEL (NMR) 至 MODEL 1；
    /// 3) 过滤 altLoc 仅保留 ' ' / 'A' / '1'；
    /// 4) 剥离结晶水 (HOH/WAT/DOD) 与无关 HETATM（按 `keepCofactors` 选择性保留关键辅因子或催化金属离子）。
    public static func sanitizeReceptorForDocking(
        _ receptorText: String,
        format: String = "pdb",
        keepCofactors: Set<String> = []
    ) throws -> (sanitizedText: String, stats: ReceptorPrepStats) {
        let trimmed = receptorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BridgeError.invalidInput(L10n.t("当前蛋白三维坐标为空，请先加载受体 PDB / mmCIF 结构。"))
        }
        let upperProbe = trimmed.prefix(4000).uppercased()
        if upperProbe.contains("LABWORKER_SPICE_FOLD") || upperProbe.contains("SYNTHETIC_SPICE_MODEL") {
            throw BridgeError.invalidInput(L10n.t("当前结构为教学用 SPICE 合成 Cα 骨架模型，缺少真实全原子侧链坐标，禁止用于 AutoDock Vina / Smina / Gnina 分子对接。请先导入或在线拉取实验 PDB/mmCIF 或 AlphaFold 全原子结构。"))
        }

        let normalizedCofactors = Set(keepCofactors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty })
        let isCIF = format.lowercased() == "mmcif" || format.lowercased() == "cif" || ProteinBiophysicsEngine.isMMCIFFormat(trimmed)

        if isCIF {
            return try sanitizeMMCIFReceptor(trimmed, keepCofactors: normalizedCofactors)
        } else {
            return try sanitizePDBReceptor(trimmed, keepCofactors: normalizedCofactors)
        }
    }

    private static func sanitizePDBReceptor(
        _ text: String,
        keepCofactors: Set<String>
    ) throws -> (sanitizedText: String, stats: ReceptorPrepStats) {
        var outLines: [String] = []
        var keptAtomCount = 0
        var keptCofactorAtomCount = 0
        var removedWaterCount = 0
        var removedHetatmCount = 0
        var removedAltLocCount = 0
        var truncatedExtraModels = false
        var hasNonCAHeavyAtoms = false
        var seenAtomInModel = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            if line.hasPrefix("ENDMDL") {
                if seenAtomInModel {
                    truncatedExtraModels = true
                    break
                }
                continue
            }
            if line.hasPrefix("MODEL ") {
                let modelStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let mNum = Int(modelStr), mNum > 1 {
                    truncatedExtraModels = true
                    break
                }
                continue
            }
            if line.hasPrefix("ATOM  ") || line.hasPrefix("HETATM") {
                let isHet = line.hasPrefix("HETATM")
                var chars = Array(line)
                guard chars.count >= 54 else { continue }
                let atomName = String(chars[12..<16]).trimmingCharacters(in: .whitespaces).uppercased()
                let altLoc = chars[16]
                let resName = String(chars[17..<20]).trimmingCharacters(in: .whitespaces).uppercased()

                if altLoc != " " && altLoc != "A" && altLoc != "1" {
                    removedAltLocCount += 1
                    continue
                }
                if isHet {
                    if waterResNames.contains(resName) {
                        removedWaterCount += 1
                        continue
                    }
                    if !keepCofactors.contains(resName) {
                        removedHetatmCount += 1
                        continue
                    }
                    keptCofactorAtomCount += 1
                } else {
                    keptAtomCount += 1
                    if atomName != "CA" && !atomName.hasPrefix("H") {
                        hasNonCAHeavyAtoms = true
                    }
                }
                seenAtomInModel = true
                if altLoc == "A" || altLoc == "1" {
                    chars[16] = " "
                    outLines.append(String(chars))
                } else {
                    outLines.append(line)
                }
            } else if line.hasPrefix("TER") || line.hasPrefix("CRYST1") || line.hasPrefix("REMARK") || line.hasPrefix("END") {
                outLines.append(line)
            }
        }

        if keptAtomCount == 0 {
            throw BridgeError.invalidInput(L10n.t("受体结构中未找到有效的蛋白 ATOM 坐标记录，无法执行分子对接。"))
        }
        if !hasNonCAHeavyAtoms {
            throw BridgeError.invalidInput(L10n.t("当前受体结构仅包含 Cα 骨架原子，缺少主链 N/C/O 与侧链重原子，无法执行真实分子对接。"))
        }
        if !outLines.contains(where: { $0.hasPrefix("END") }) {
            outLines.append("END")
        }

        let stats = ReceptorPrepStats(
            keptAtomCount: keptAtomCount,
            keptCofactorAtomCount: keptCofactorAtomCount,
            removedWaterCount: removedWaterCount,
            removedHetatmCount: removedHetatmCount,
            removedAltLocCount: removedAltLocCount,
            truncatedExtraModels: truncatedExtraModels,
            hasNonCAHeavyAtoms: hasNonCAHeavyAtoms
        )
        return (outLines.joined(separator: "\n") + "\n", stats)
    }

    private static func sanitizeMMCIFReceptor(
        _ text: String,
        keepCofactors: Set<String>
    ) throws -> (sanitizedText: String, stats: ReceptorPrepStats) {
        let lines = text.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "\r", with: "") }
        var outLines: [String] = []
        var keptAtomCount = 0
        var keptCofactorAtomCount = 0
        var removedWaterCount = 0
        var removedHetatmCount = 0
        var removedAltLocCount = 0
        var truncatedExtraModels = false
        var hasNonCAHeavyAtoms = false

        var inAtomLoop = false
        var colNames: [String] = []
        var colIndex: [String: Int] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "loop_" {
                inAtomLoop = false
                colNames = []
                colIndex = [:]
                outLines.append(line)
                continue
            }
            if trimmed.hasPrefix("_atom_site.") {
                inAtomLoop = true
                let key = trimmed.components(separatedBy: .whitespaces).first ?? trimmed
                colIndex[key] = colNames.count
                colNames.append(key)
                outLines.append(line)
                continue
            }
            if inAtomLoop {
                if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("_") || trimmed.hasPrefix("data_") {
                    inAtomLoop = false
                    outLines.append(line)
                    continue
                }
                let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard tokens.count >= colNames.count else {
                    outLines.append(line)
                    continue
                }
                let groupPDB = colIndex["_atom_site.group_PDB"].map { tokens[$0].uppercased() } ?? "ATOM"
                let atomID = (colIndex["_atom_site.label_atom_id"] ?? colIndex["_atom_site.auth_atom_id"]).map { tokens[$0].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).uppercased() } ?? ""
                let altID = colIndex["_atom_site.label_alt_id"].map { tokens[$0] } ?? "."
                let compID = (colIndex["_atom_site.label_comp_id"] ?? colIndex["_atom_site.auth_comp_id"]).map { tokens[$0].uppercased() } ?? ""
                let modelNum = colIndex["_atom_site.pdbx_PDB_model_num"].map { tokens[$0] } ?? "1"

                if modelNum != "1" && modelNum != "." && modelNum != "?" {
                    truncatedExtraModels = true
                    continue
                }
                if altID != "." && altID != "?" && altID != "A" && altID != "1" {
                    removedAltLocCount += 1
                    continue
                }
                if groupPDB == "HETATM" {
                    if waterResNames.contains(compID) {
                        removedWaterCount += 1
                        continue
                    }
                    if !keepCofactors.contains(compID) {
                        removedHetatmCount += 1
                        continue
                    }
                    keptCofactorAtomCount += 1
                } else {
                    keptAtomCount += 1
                    if atomID != "CA" && !atomID.hasPrefix("H") {
                        hasNonCAHeavyAtoms = true
                    }
                }
                outLines.append(line)
            } else {
                outLines.append(line)
            }
        }

        if keptAtomCount == 0 {
            throw BridgeError.invalidInput(L10n.t("受体 mmCIF 结构中未找到有效的蛋白 ATOM 坐标记录，无法执行分子对接。"))
        }
        if !hasNonCAHeavyAtoms {
            throw BridgeError.invalidInput(L10n.t("当前受体结构仅包含 Cα 骨架原子，缺少主链 N/C/O 与侧链重原子，无法执行真实分子对接。"))
        }

        let stats = ReceptorPrepStats(
            keptAtomCount: keptAtomCount,
            keptCofactorAtomCount: keptCofactorAtomCount,
            removedWaterCount: removedWaterCount,
            removedHetatmCount: removedHetatmCount,
            removedAltLocCount: removedAltLocCount,
            truncatedExtraModels: truncatedExtraModels,
            hasNonCAHeavyAtoms: hasNonCAHeavyAtoms
        )
        return (outLines.joined(separator: "\n") + "\n", stats)
    }

    /// 检测 SDF / MOL 文件是否为平面 2D 构象（所有原子 Z 坐标均接近 0 或头信息标注 2D）
    public static func ligandFileNeeds3DGeneration(_ content: String, fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        guard ext == "sdf" || ext == "mol" else { return false }
        let lines = content.components(separatedBy: .newlines)
        if lines.count >= 2 && lines[1].uppercased().contains("2D") {
            return true
        }
        guard lines.count >= 4 else { return false }
        let countsTokens = lines[3].split(whereSeparator: { $0.isWhitespace })
        guard let atomCount = countsTokens.first.flatMap({ Int($0) }), atomCount > 0 else { return false }
        var checked = 0
        var maxAbsZ = 0.0
        for idx in 4..<min(lines.count, 4 + atomCount) {
            let cols = lines[idx].split(whereSeparator: { $0.isWhitespace })
            if cols.count >= 3, let z = Double(cols[2]) {
                maxAbsZ = max(maxAbsZ, abs(z))
                checked += 1
            }
        }
        return checked > 0 && maxAbsZ < 1e-4
    }

    /// 构建受体 Open Babel 转换参数（包含生理 pH 7.4 质子化 `-p 7.4` 与刚性受体 `-xr`）
    public static func buildObabelReceptorArgs(
        inputPath: String,
        outputPath: String,
        ph: Double = 7.4
    ) -> [String] {
        [inputPath, "-O", outputPath, "-xr", "-p", String(format: "%.1f", ph)]
    }

    /// 构建配体 Open Babel 转换参数（包含生理 pH 7.4 质子化 `-p 7.4`，并对 SMILES 或 2D SDF/MOL 自动追加 `--gen3d`）
    public static func buildObabelLigandArgs(
        inputPath: String?,
        smiles: String?,
        outputPath: String,
        needs3D: Bool = false,
        ph: Double = 7.4
    ) -> [String] {
        let phStr = String(format: "%.1f", ph)
        if let inPath = inputPath, !inPath.isEmpty {
            var args = [inPath, "-O", outputPath, "-p", phStr]
            if needs3D {
                args.append("--gen3d")
            }
            return args
        }
        let cleanSMILES = (smiles ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ["-:\(cleanSMILES)", "-O", outputPath, "--gen3d", "-p", phStr]
    }

    /// 构建 AutoDock Vina / Smina / Gnina 命令行参数（含可复现随机种子 `--seed` 与可选柔性侧链 `--flex`）
    public static func buildVinaArguments(
        receptorPath: String,
        ligandPath: String,
        outputPath: String,
        box: ProteinDockingBoxRecommendation,
        exhaustiveness: Int? = nil,
        numModes: Int = 9,
        seed: Int = 42,
        flexReceptorPath: String? = nil
    ) -> [String] {
        let exh = max(1, exhaustiveness ?? box.recommendedExhaustiveness)
        var args: [String] = [
            "--receptor", receptorPath,
            "--ligand", ligandPath,
            "--center_x", String(format: "%.3f", box.centerX),
            "--center_y", String(format: "%.3f", box.centerY),
            "--center_z", String(format: "%.3f", box.centerZ),
            "--size_x", String(format: "%.3f", box.sizeX),
            "--size_y", String(format: "%.3f", box.sizeY),
            "--size_z", String(format: "%.3f", box.sizeZ),
            "--exhaustiveness", "\(exh)",
            "--num_modes", "\(max(1, min(20, numModes)))",
            "--seed", "\(seed)"
        ]
        if let flexPath = flexReceptorPath?.trimmingCharacters(in: .whitespacesAndNewlines), !flexPath.isEmpty {
            args.append(contentsOf: ["--flex", flexPath])
        }
        args.append(contentsOf: ["--out", outputPath])
        return args
    }

    // MARK: - 4. 执行本地对接 (Vina / Smina / Gnina)

    public static func runLocalDocking(
        tool: LocalComputeToolKind,
        executablePath: String,
        receptorText: String,
        receptorFormat: String,
        ligandFileURL: URL?,
        ligandSMILES: String?,
        box: ProteinDockingBoxRecommendation,
        obabelExecutable: String?,
        exhaustiveness: Int? = nil,
        numModes: Int = 9,
        keepCofactors: Set<String> = [],
        seed: Int = 42,
        flexReceptorPath: String? = nil,
        protonationPH: Double = 7.4
    ) async throws -> DockingExecutionResult {
        guard tool.isDockingEngine else {
            throw BridgeError.invalidInput(L10n.tr("工具 \(tool.displayName) 不是分子对接引擎。", "\(tool.displayName) is not a docking engine."))
        }
        let cleanReceptor = receptorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanReceptor.isEmpty else {
            throw BridgeError.invalidInput(L10n.t("当前蛋白三维坐标为空，请先加载受体 PDB / mmCIF 结构。"))
        }
        let cleanSMILES = (ligandSMILES ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if ligandFileURL == nil && cleanSMILES.isEmpty {
            throw BridgeError.invalidInput(L10n.t("请先输入配体 SMILES 字符串，或选择一个局部配体文件 (.pdbqt / .sdf / .mol2 / .pdb)。"))
        }

        let recExt = receptorFormat.lowercased() == "mmcif" ? "cif" : receptorFormat.lowercased()
        let preparedReceptor: String
        if recExt == "pdbqt" {
            let probe = cleanReceptor.prefix(4000).uppercased()
            if probe.contains("LABWORKER_SPICE_FOLD") || probe.contains("SYNTHETIC_SPICE_MODEL") {
                throw BridgeError.invalidInput(L10n.t("当前结构为教学用 SPICE 合成 Cα 骨架模型，缺少真实全原子侧链坐标，禁止用于 AutoDock Vina / Smina / Gnina 分子对接。请先导入或在线拉取实验 PDB/mmCIF 或 AlphaFold 全原子结构。"))
            }
            preparedReceptor = cleanReceptor
        } else {
            preparedReceptor = try sanitizeReceptorForDocking(
                cleanReceptor,
                format: recExt,
                keepCofactors: keepCofactors
            ).sanitizedText
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fm = FileManager.default
                    let workDir = fm.temporaryDirectory.appendingPathComponent("labworker_dock_\(UUID().uuidString)")
                    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

                    // 1. 准备受体 .pdbqt（清洗 + 生理 pH 7.4 质子化）
                    let receptorPDBQT = workDir.appendingPathComponent("receptor.pdbqt")
                    if recExt == "pdbqt" {
                        try preparedReceptor.write(to: receptorPDBQT, atomically: true, encoding: .utf8)
                    } else {
                        guard let obabel = obabelExecutable, !obabel.isEmpty else {
                            throw BridgeError.missingOpenBabel(L10n.tr("将受体 (\(recExt)) 转换为 Vina/Smina 所需的 .pdbqt 格式需要 Open Babel（建议安装：`brew install open-babel`）。", "Open Babel is required to convert receptor (\(recExt)) to .pdbqt (`brew install open-babel`)."))
                        }
                        let rawRecURL = workDir.appendingPathComponent("receptor_clean.\(recExt.isEmpty ? "pdb" : recExt)")
                        try preparedReceptor.write(to: rawRecURL, atomically: true, encoding: .utf8)
                        let conv = try runProcessSync(
                            executablePath: obabel,
                            arguments: buildObabelReceptorArgs(inputPath: rawRecURL.path, outputPath: receptorPDBQT.path, ph: protonationPH),
                            timeoutSeconds: 45
                        )
                        guard conv.exitCode == 0, fm.fileExists(atPath: receptorPDBQT.path) else {
                            throw BridgeError.processFailed(L10n.tr("Open Babel 转换受体失败：\(conv.stderr.isEmpty ? conv.stdout : conv.stderr)", "Open Babel receptor conversion failed: \(conv.stderr.isEmpty ? conv.stdout : conv.stderr)"))
                        }
                    }

                    // 2. 准备配体 .pdbqt（pH 7.4 质子化 + 对 2D SDF/MOL 或 SMILES 自动 --gen3d）
                    let ligandPDBQT = workDir.appendingPathComponent("ligand.pdbqt")
                    if let ligURL = ligandFileURL {
                        let ligExt = ligURL.pathExtension.lowercased()
                        if ligExt == "pdbqt" {
                            try fm.copyItem(at: ligURL, to: ligandPDBQT)
                        } else {
                            guard let obabel = obabelExecutable, !obabel.isEmpty else {
                                throw BridgeError.missingOpenBabel(L10n.tr("将配体 \(ligURL.lastPathComponent) 转换为 .pdbqt 需要 Open Babel（建议安装：`brew install open-babel`）。", "Open Babel is required to convert ligand \(ligURL.lastPathComponent) to .pdbqt (`brew install open-babel`)."))
                            }
                            let ligContent = (try? String(contentsOf: ligURL, encoding: .utf8)) ?? ""
                            let needs3D = ligandFileNeeds3DGeneration(ligContent, fileExtension: ligExt)
                            let conv = try runProcessSync(
                                executablePath: obabel,
                                arguments: buildObabelLigandArgs(inputPath: ligURL.path, smiles: nil, outputPath: ligandPDBQT.path, needs3D: needs3D, ph: protonationPH),
                                timeoutSeconds: 60
                            )
                            guard conv.exitCode == 0, fm.fileExists(atPath: ligandPDBQT.path) else {
                                throw BridgeError.processFailed(L10n.tr("Open Babel 转换配体失败：\(conv.stderr.isEmpty ? conv.stdout : conv.stderr)", "Open Babel ligand conversion failed: \(conv.stderr.isEmpty ? conv.stdout : conv.stderr)"))
                            }
                        }
                    } else {
                        guard let obabel = obabelExecutable, !obabel.isEmpty else {
                            throw BridgeError.missingOpenBabel(L10n.t("从 SMILES 自动生成 3D 配体并加氢转换 .pdbqt 需要 Open Babel（建议安装：`brew install open-babel`）。"))
                        }
                        let conv = try runProcessSync(
                            executablePath: obabel,
                            arguments: buildObabelLigandArgs(inputPath: nil, smiles: cleanSMILES, outputPath: ligandPDBQT.path, needs3D: true, ph: protonationPH),
                            timeoutSeconds: 60
                        )
                        guard conv.exitCode == 0, fm.fileExists(atPath: ligandPDBQT.path) else {
                            throw BridgeError.processFailed(L10n.tr("Open Babel 从 SMILES 生成 3D 配体失败：\(conv.stderr.isEmpty ? conv.stdout : conv.stderr)", "Open Babel SMILES->3D conversion failed: \(conv.stderr.isEmpty ? conv.stdout : conv.stderr)"))
                        }
                    }

                    // 3. 运行对接引擎（含 --seed 与可选 --flex）
                    let outPDBQT = workDir.appendingPathComponent("docked_out.pdbqt")
                    let args = buildVinaArguments(
                        receptorPath: receptorPDBQT.path,
                        ligandPath: ligandPDBQT.path,
                        outputPath: outPDBQT.path,
                        box: box,
                        exhaustiveness: exhaustiveness,
                        numModes: numModes,
                        seed: seed,
                        flexReceptorPath: flexReceptorPath
                    )
                    let start = Date()
                    let runRes = try runProcessSync(executablePath: executablePath, arguments: args, timeoutSeconds: 600)
                    let elapsed = Date().timeIntervalSince(start)
                    guard runRes.exitCode == 0 else {
                        throw BridgeError.processFailed(L10n.tr("\(tool.displayName) 运行失败（exit \(runRes.exitCode)）：\n\(runRes.stderr.isEmpty ? runRes.stdout : runRes.stderr)", "\(tool.displayName) failed (exit \(runRes.exitCode)):\n\(runRes.stderr.isEmpty ? runRes.stdout : runRes.stderr)"))
                    }

                    let outText = (try? String(contentsOf: outPDBQT, encoding: .utf8)) ?? ""
                    let poses = parseDockingResults(stdoutText: runRes.stdout, outputFileText: outText, tool: tool)
                    continuation.resume(returning: DockingExecutionResult(
                        tool: tool,
                        poses: poses,
                        outputFilePath: outPDBQT.path,
                        stdoutLog: runRes.stdout,
                        stderrLog: runRes.stderr,
                        elapsedSeconds: elapsed
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 5. Boltz 共折叠 YAML 生成、执行与置信度解析

    public static func generateBoltzYAML(
        proteinSequence: String,
        ligandSMILES: String? = nil,
        ligandCCD: String? = nil,
        chainID: String = "A"
    ) -> String {
        let cleanSeq = ProteinBiophysicsEngine.cleanProteinSequence(proteinSequence)
        var lines: [String] = [
            "version: 1",
            "sequences:",
            "  - protein:",
            "      id: \(chainID)",
            "      sequence: \(cleanSeq)"
        ]
        let smiles = (ligandSMILES ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ccd = (ligandCCD ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !smiles.isEmpty {
            let escaped = smiles.replacingOccurrences(of: "'", with: "''")
            lines.append("  - ligand:")
            lines.append("      id: B")
            lines.append("      smiles: '\(escaped)'")
        } else if !ccd.isEmpty {
            lines.append("  - ligand:")
            lines.append("      id: B")
            lines.append("      ccd: \(ccd)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parseBoltzConfidenceJSON(_ data: Data) -> BoltzConfidenceSummary? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func dbl(_ key: String) -> Double? {
            if let v = obj[key] as? Double { return v }
            if let v = obj[key] as? NSNumber { return v.doubleValue }
            return nil
        }
        let conf = dbl("confidence_score")
        let ptm = dbl("ptm")
        let iptm = dbl("iptm")
        let ligIptm = dbl("ligand_iptm")
        let plddt = dbl("complex_plddt")
        if conf == nil && ptm == nil && iptm == nil && ligIptm == nil && plddt == nil {
            return nil
        }
        return BoltzConfidenceSummary(
            confidenceScore: conf,
            ptm: ptm,
            iptm: iptm,
            ligandIptm: ligIptm,
            complexPLDDT: plddt,
            structureFilePath: nil,
            structureFormat: nil,
            structureText: nil
        )
    }

    public static func runLocalBoltz(
        yamlContent: String,
        boltzExecutable: String,
        useMSAServer: Bool = true,
        workDir: URL? = nil
    ) async throws -> BoltzConfidenceSummary {
        guard !yamlContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.invalidInput(L10n.t("Boltz YAML 配置内容为空。"))
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fm = FileManager.default
                    let baseDir = workDir ?? fm.temporaryDirectory.appendingPathComponent("labworker_boltz_\(UUID().uuidString)")
                    try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
                    let yamlURL = baseDir.appendingPathComponent("complex.yaml")
                    let outDir = baseDir.appendingPathComponent("boltz_out")
                    try yamlContent.write(to: yamlURL, atomically: true, encoding: .utf8)

                    var args = ["predict", yamlURL.path, "--out_dir", outDir.path]
                    if useMSAServer {
                        args.append("--use_msa_server")
                    }
                    let res = try runProcessSync(executablePath: boltzExecutable, arguments: args, timeoutSeconds: 1800)
                    guard res.exitCode == 0 else {
                        throw BridgeError.processFailed(L10n.tr("Boltz 共折叠运行失败（exit \(res.exitCode)）：\n\(res.stderr.isEmpty ? res.stdout : res.stderr)", "Boltz co-folding failed (exit \(res.exitCode)):\n\(res.stderr.isEmpty ? res.stdout : res.stderr)"))
                    }

                    // 递归搜索 confidence_*.json 与预测的 .cif/.pdb 文件
                    var confSummary: BoltzConfidenceSummary? = nil
                    var bestStructURL: URL? = nil
                    var bestStructFormat: String? = nil

                    if let enumerator = fm.enumerator(at: outDir, includingPropertiesForKeys: [.isRegularFileKey]) {
                        let allURLs = enumerator.allObjects.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
                        for u in allURLs {
                            let fn = u.lastPathComponent.lowercased()
                            if fn.hasPrefix("confidence_") && fn.hasSuffix(".json") && confSummary == nil,
                               let data = try? Data(contentsOf: u) {
                                confSummary = parseBoltzConfidenceJSON(data)
                            }
                            if (fn.hasSuffix(".cif") || fn.hasSuffix(".pdb")) && bestStructURL == nil {
                                bestStructURL = u
                                bestStructFormat = fn.hasSuffix(".cif") ? "cif" : "pdb"
                            }
                        }
                    }

                    let structText = bestStructURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    continuation.resume(returning: BoltzConfidenceSummary(
                        confidenceScore: confSummary?.confidenceScore,
                        ptm: confSummary?.ptm,
                        iptm: confSummary?.iptm,
                        ligandIptm: confSummary?.ligandIptm,
                        complexPLDDT: confSummary?.complexPLDDT,
                        structureFilePath: bestStructURL?.path,
                        structureFormat: bestStructFormat,
                        structureText: structText
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 6. 并发排空管道的子进程安全执行辅助

    private static func runProcessSync(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: Double
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var outData = Data()
        var errData = Data()

        try process.run()

        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
        }

        _ = readGroup.wait(timeout: .now() + 2.0)
        if process.isRunning {
            process.waitUntilExit()
        }

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        return (process.terminationStatus, outStr, errStr)
    }
}
