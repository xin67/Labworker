import Foundation
import Combine

// MARK: - 1. 确定性伪随机数发生器 (Mulberry32 — 与 SPICE_GUI 保持完全一致的可复现随机序列)

public struct Mulberry32Generator {
    private var state: UInt32
    
    public init(seed: UInt32) {
        self.state = seed
    }
    
    public mutating func nextDouble() -> Double {
        state = state &+ 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        let result = t ^ (t >> 14)
        return Double(result) / 4294967296.0
    }
    
    public mutating func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, through: 1, by: -1) {
            let j = Int(floor(nextDouble() * Double(i + 1)))
            if i != j {
                array.swapAt(i, j)
            }
        }
    }
    
    public mutating func shuffled<T>(_ array: [T]) -> [T] {
        var copy = array
        shuffle(&copy)
        return copy
    }
}

// MARK: - 2. 微孔板自动排布、冲突校验与 CSV/TSV 导入导出引擎

public enum PlateLayoutEngine {
    public static let controlGroupName = "Control"
    public static let blankGroupName = "Blank"
    
    public static func requiredReplicates(for sample: PlateSampleItem, rules: PlateLayoutRules) -> Int {
        let raw = sample.customReplicates ?? rules.replicates
        return max(1, min(12, raw))
    }
    
    /// 计算正交四邻域连通块数量（检测同一组样品复孔是否被拆分到不相邻的位置）
    public static func orthogonalConnectedComponents(_ cells: [PlateWellAssignment]) -> Int {
        guard cells.count >= 2 else { return cells.count }
        struct Coord: Hashable {
            let r: Int
            let c: Int
        }
        let coords = Set(cells.map { Coord(r: $0.row, c: $0.col) })
        var visited = Set<Coord>()
        var components = 0
        
        for start in coords where !visited.contains(start) {
            components += 1
            visited.insert(start)
            var stack = [start]
            while let cur = stack.popLast() {
                let neighbors = [
                    Coord(r: cur.r + 1, c: cur.c),
                    Coord(r: cur.r - 1, c: cur.c),
                    Coord(r: cur.r, c: cur.c + 1),
                    Coord(r: cur.r, c: cur.c - 1)
                ]
                for nb in neighbors where coords.contains(nb) && !visited.contains(nb) {
                    visited.insert(nb)
                    stack.append(nb)
                }
            }
        }
        return components
    }
    
    /// 校验当前孔位分配是否满足容量、复孔、相邻性与边缘避让规则
    public static func validateLayout(
        format: PlateFormat,
        samples: [PlateSampleItem],
        rules: PlateLayoutRules,
        assignments: [String: PlateWellAssignment]
    ) -> (issues: [PlateLayoutIssue], unplaced: [PlateUnplacedSample]) {
        let allAssigned = Array(assignments.values)
        var issues: [PlateLayoutIssue] = []
        var unplaced: [PlateUnplacedSample] = []
        
        if samples.isEmpty {
            issues.append(PlateLayoutIssue(severity: .info, message: L10n.t("尚未添加实验样品，可在左侧添加样品或粘贴 CSV 表格")))
        }
        
        // 样品重名与空名检查
        var blankNameReported = false
        var nameCounts: [String: (label: String, count: Int)] = [:]
        for sample in samples {
            let trimmed = sample.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !blankNameReported {
                    issues.append(PlateLayoutIssue(severity: .warning, message: L10n.t("存在未填写名称的样品行")))
                    blankNameReported = true
                }
                continue
            }
            let key = trimmed.lowercased()
            if let existing = nameCounts[key] {
                nameCounts[key] = (existing.label, existing.count + 1)
            } else {
                nameCounts[key] = (trimmed, 1)
            }
        }
        for entry in nameCounts.values where entry.count > 1 {
            issues.append(PlateLayoutIssue(severity: .warning, message: L10n.tr("样品名称「\(entry.label)」重复出现 \(entry.count) 次", "Sample name \"\(entry.label)\" appears \(entry.count) times")))
        }
        
        // 容量核验
        let sampleNeed = samples.reduce(0) { $0 + requiredReplicates(for: $1, rules: rules) }
        let auxNeed = max(0, rules.controls) + max(0, rules.blanks)
        let allCells = format.buildWellCells()
        let edgeCount = allCells.filter(\.isEdge).count
        let interiorCount = format.totalWells - edgeCount
        
        if rules.reserveEdge && (sampleNeed + auxNeed) > interiorCount {
            issues.append(
                PlateLayoutIssue(
                    severity: .error,
                    message: L10n.tr("内部可用孔位不足：启用边缘预留后仅剩 \(interiorCount) 个内部孔，但样品与对照/空白共需 \(sampleNeed + auxNeed) 个孔", "Insufficient interior wells: \(interiorCount) available with edge reservation, \(sampleNeed + auxNeed) needed for samples and controls/blanks")
                )
            )
        } else if sampleNeed + auxNeed > format.totalWells {
            issues.append(
                PlateLayoutIssue(
                    severity: .error,
                    message: L10n.tr("总孔位超出 \(format.rawValue) 孔板上限：共需 \(sampleNeed + auxNeed) 孔，当前规格仅 \(format.totalWells) 孔", "Total wells needed (\(sampleNeed + auxNeed)) exceed \(format.rawValue)-well capacity (\(format.totalWells))")
                )
            )
        }
        
        // 逐个样品检查复孔落位、连通性与边缘使用情况
        for sample in samples {
            let requested = requiredReplicates(for: sample, rules: rules)
            let placedCells = allAssigned
                .filter { $0.type == .sample && $0.sampleId == sample.id }
                .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
            let placed = placedCells.count
            let missing = max(0, requested - placed)
            let displayName = sample.name.isEmpty ? sample.id : sample.name
            
            if missing > 0 {
                issues.append(
                    PlateLayoutIssue(
                        severity: .error,
                        message: L10n.tr("样品「\(displayName)」复孔未完全排入：已排 \(placed)/\(requested) 孔（缺 \(missing) 孔）", "Sample \"\(displayName)\" replicates incomplete: \(placed)/\(requested) assigned (missing \(missing))")
                    )
                )
                unplaced.append(
                    PlateUnplacedSample(
                        sampleId: sample.id,
                        name: displayName,
                        requested: requested,
                        placed: placed,
                        missing: missing
                    )
                )
            }
            if placedCells.count > 1 && rules.keepTogether && orthogonalConnectedComponents(placedCells) > 1 {
                issues.append(
                    PlateLayoutIssue(
                        severity: .warning,
                        message: L10n.tr("样品「\(displayName)」的复孔被拆分到了不相邻的孔位", "Replicates for \"\(displayName)\" are split across non-adjacent wells")
                    )
                )
            }
            if (rules.avoidEdge || rules.reserveEdge) && placedCells.contains(where: { format.isEdgeWell(row: $0.row, col: $0.col) }) {
                issues.append(
                    PlateLayoutIssue(
                        severity: .warning,
                        message: L10n.tr("样品「\(displayName)」使用了外圈边缘孔位", "Sample \"\(displayName)\" uses edge perimeter well(s)")
                    )
                )
            }
        }
        
        let controlPlaced = allAssigned.filter { $0.type == .control }.count
        let blankPlaced = allAssigned.filter { $0.type == .blank }.count
        if controlPlaced < rules.controls {
            issues.append(
                PlateLayoutIssue(
                    severity: .warning,
                    message: L10n.tr("对照孔数量不足：已分配 \(controlPlaced)/\(rules.controls) 孔", "Insufficient control wells: \(controlPlaced)/\(rules.controls) assigned")
                )
            )
        }
        if blankPlaced < rules.blanks {
            issues.append(
                PlateLayoutIssue(
                    severity: .warning,
                    message: L10n.tr("空白孔数量不足：已分配 \(blankPlaced)/\(rules.blanks) 孔", "Insufficient blank wells: \(blankPlaced)/\(rules.blanks) assigned")
                )
            )
        }
        if (rules.avoidEdge || rules.reserveEdge) && allAssigned.contains(where: { ($0.type == .control || $0.type == .blank) && format.isEdgeWell(row: $0.row, col: $0.col) }) {
            issues.append(
                PlateLayoutIssue(
                    severity: .warning,
                    message: L10n.t("对照孔或空白孔使用了外圈边缘孔位，可能引入边缘蒸发偏差")
                )
            )
        }
        
        // 按严重程度排序并去重
        var seen = Set<String>()
        var uniqueIssues: [PlateLayoutIssue] = []
        for issue in issues where !seen.contains(issue.id) {
            seen.insert(issue.id)
            uniqueIssues.append(issue)
        }
        let order: [PlateIssueSeverity: Int] = [.error: 0, .warning: 1, .info: 2]
        uniqueIssues.sort { (order[$0.severity] ?? 3) < (order[$1.severity] ?? 3) }
        return (uniqueIssues, unplaced)
    }
    
    /// 执行确定性微孔板自动排布
    public static func assignPlate(
        format: PlateFormat,
        samples: [PlateSampleItem],
        rules: PlateLayoutRules
    ) -> PlateAssignResult {
        let allCells = format.buildWellCells()
        var assignments: [String: PlateWellAssignment] = [:]
        var used = Set<String>()
        var rng = Mulberry32Generator(seed: rules.seed)
        
        let cellAt: (Int, Int) -> PlateWellCell = { r, c in
            allCells[r * format.cols + c]
        }
        let sampleEligible: (PlateWellCell) -> Bool = { cell in
            (rules.reserveEdge || rules.avoidEdge) ? !cell.isEdge : true
        }
        let usable: (PlateWellCell) -> Bool = { cell in
            !used.contains(cell.id) && sampleEligible(cell)
        }
        
        func takeFrom(_ pool: [PlateWellCell], count: Int) -> [PlateWellCell] {
            guard count > 0 else { return [] }
            var available = pool.filter { !used.contains($0.id) }
            if rules.randomize {
                rng.shuffle(&available)
            }
            let picked = Array(available.prefix(count))
            for c in picked { used.insert(c.id) }
            return picked
        }
        
        func placeScattered(count: Int) -> [PlateWellCell] {
            var picked = takeFrom(allCells.filter(usable), count: count)
            if picked.count < count && rules.avoidEdge && !rules.reserveEdge {
                let remaining = count - picked.count
                picked.append(contentsOf: takeFrom(allCells.filter(\.isEdge), count: remaining))
            }
            return picked
        }
        
        func rowCandidates(count: Int) -> [[PlateWellCell]] {
            guard count <= format.cols else { return [] }
            var out: [[PlateWellCell]] = []
            for r in 0..<format.rows {
                for c in 0...(format.cols - count) {
                    var block: [PlateWellCell] = []
                    var ok = true
                    for step in 0..<count {
                        let cell = cellAt(r, c + step)
                        if !usable(cell) {
                            ok = false
                            break
                        }
                        block.append(cell)
                    }
                    if ok { out.append(block) }
                }
            }
            return out
        }
        
        func columnCandidates(count: Int) -> [[PlateWellCell]] {
            guard count <= format.rows else { return [] }
            var out: [[PlateWellCell]] = []
            for c in 0..<format.cols {
                for r in 0...(format.rows - count) {
                    var block: [PlateWellCell] = []
                    var ok = true
                    for step in 0..<count {
                        let cell = cellAt(r + step, c)
                        if !usable(cell) {
                            ok = false
                            break
                        }
                        block.append(cell)
                    }
                    if ok { out.append(block) }
                }
            }
            return out
        }
        
        func blockDimensions(count: Int) -> (rows: Int, cols: Int) {
            var bCols = rules.groupColumns > 0 ? min(rules.groupColumns, format.cols) : 0
            var bRows = rules.groupRows > 0 ? min(rules.groupRows, format.rows) : 0
            if bCols > 0 && bRows > 0 {
                while bCols * bRows < count {
                    if bCols < format.cols { bCols += 1 }
                    else if bRows < format.rows { bRows += 1 }
                    else { break }
                }
                return (bRows, bCols)
            }
            if bCols > 0 {
                let r = min(format.rows, Int(ceil(Double(count) / Double(bCols))))
                return (r, bCols)
            }
            if bRows > 0 {
                let c = min(format.cols, Int(ceil(Double(count) / Double(bRows))))
                return (bRows, c)
            }
            var bestR = min(format.rows, count)
            var bestC = min(format.cols, Int(ceil(Double(count) / Double(max(1, bestR)))))
            var bestScore = Int.max
            let maxW = min(count, format.cols)
            if maxW >= 1 {
                for w in 1...maxW {
                    let h = Int(ceil(Double(count) / Double(w)))
                    if h > format.rows { continue }
                    let waste = w * h - count
                    let score = waste * 20 + abs(w - h)
                    if score < bestScore {
                        bestScore = score
                        bestR = h
                        bestC = w
                    }
                }
            }
            return (bestR, bestC)
        }
        
        func blockCandidates(count: Int) -> [[PlateWellCell]] {
            let dims = blockDimensions(count: count)
            guard dims.rows >= 1, dims.cols >= 1, dims.rows <= format.rows, dims.cols <= format.cols else {
                return []
            }
            var out: [[PlateWellCell]] = []
            for r in 0...(format.rows - dims.rows) {
                for c in 0...(format.cols - dims.cols) {
                    var cells: [PlateWellCell] = []
                    var ok = true
                    for dr in 0..<dims.rows where ok {
                        for dc in 0..<dims.cols {
                            let cell = cellAt(r + dr, c + dc)
                            if !usable(cell) {
                                ok = false
                                break
                            }
                            if cells.count < count {
                                cells.append(cell)
                            }
                        }
                    }
                    if ok && cells.count == count {
                        out.append(cells)
                    }
                }
            }
            return out
        }
        
        func placeGrouped(count: Int) -> [PlateWellCell] {
            let strategies: [PlateGroupLayoutStrategy] = (rules.groupLayout == .auto)
                ? [.row, .column, .block]
                : [rules.groupLayout]
            let minRow = (rules.reserveEdge || rules.avoidEdge) && format.rows > 2 ? 1 : 0
            let minCol = (rules.reserveEdge || rules.avoidEdge) && format.cols > 2 ? 1 : 0
            for st in strategies {
                let candidates: [[PlateWellCell]]
                switch st {
                case .row, .auto: candidates = rowCandidates(count: count)
                case .column:     candidates = columnCandidates(count: count)
                case .block:      candidates = blockCandidates(count: count)
                }
                guard !candidates.isEmpty else { continue }
                let choice: [PlateWellCell]?
                if rules.randomize {
                    let aligned: [[PlateWellCell]]
                    switch st {
                    case .row, .auto:
                        aligned = candidates.filter { ($0[0].col - minCol) % max(1, count) == 0 }
                    case .column:
                        aligned = candidates.filter { ($0[0].row - minRow) % max(1, count) == 0 }
                    case .block:
                        aligned = candidates
                    }
                    var pool = aligned.isEmpty ? candidates : aligned
                    rng.shuffle(&pool)
                    choice = pool.first
                } else {
                    choice = candidates.first
                }
                if let choice, choice.count == count {
                    for cell in choice { used.insert(cell.id) }
                    return choice
                }
            }
            return placeScattered(count: count)
        }
        
        let orderedSamples = rules.randomize ? rng.shuffled(samples) : samples
        for (sampleIdx, sample) in orderedSamples.enumerated() {
            let count = requiredReplicates(for: sample, rules: rules)
            let cells = rules.keepTogether ? placeGrouped(count: count) : placeScattered(count: count)
            let resolvedHex = sample.colorHex.isEmpty
                ? PlateColorPalette.hexForGroup(sample.group, indexFallback: sampleIdx)
                : sample.colorHex
            for (repIdx, cell) in cells.enumerated() {
                assignments[cell.id] = PlateWellAssignment(
                    well: cell.id,
                    row: cell.row,
                    col: cell.col,
                    type: .sample,
                    sampleId: sample.id,
                    sampleName: sample.name,
                    group: sample.group,
                    replicate: repIdx + 1,
                    colorHex: resolvedHex,
                    manual: false
                )
            }
        }
        
        func takeAuxCells(count: Int) -> [PlateWellCell] {
            let wanted = max(0, min(format.totalWells, count))
            guard wanted > 0 else { return [] }
            // 遵循 Festing & Altman (2002) 与 NIH Assay Guidance Manual：
            // 严禁把 Control / Blank 优先放进高蒸发边缘孔制造空间混杂
            let pools: [[PlateWellCell]]
            if rules.reserveEdge {
                pools = [allCells.filter { !$0.isEdge }]
            } else if rules.avoidEdge {
                pools = [allCells.filter { !$0.isEdge }, allCells.filter(\.isEdge)]
            } else {
                pools = [allCells]
            }
            var picked: [PlateWellCell] = []
            for pool in pools {
                if picked.count >= wanted { break }
                var avail = pool.filter { !used.contains($0.id) }
                if rules.randomize { rng.shuffle(&avail) }
                for cell in avail.prefix(wanted - picked.count) {
                    used.insert(cell.id)
                    picked.append(cell)
                }
            }
            return picked
        }
        
        let controlCells = takeAuxCells(count: rules.controls)
        for (idx, cell) in controlCells.enumerated() {
            assignments[cell.id] = PlateWellAssignment(
                well: cell.id,
                row: cell.row,
                col: cell.col,
                type: .control,
                sampleId: "",
                sampleName: "CTRL-\(idx + 1)",
                group: controlGroupName,
                replicate: idx + 1,
                colorHex: PlateColorPalette.controlHex,
                manual: false
            )
        }
        
        let blankCells = takeAuxCells(count: rules.blanks)
        for (idx, cell) in blankCells.enumerated() {
            assignments[cell.id] = PlateWellAssignment(
                well: cell.id,
                row: cell.row,
                col: cell.col,
                type: .blank,
                sampleId: "",
                sampleName: "BLANK-\(idx + 1)",
                group: blankGroupName,
                replicate: idx + 1,
                colorHex: PlateColorPalette.blankHex,
                manual: false
            )
        }
        
        if rules.reserveEdge {
            for cell in allCells where cell.isEdge && !used.contains(cell.id) {
                used.insert(cell.id)
                assignments[cell.id] = PlateWellAssignment(
                    well: cell.id,
                    row: cell.row,
                    col: cell.col,
                    type: .reserved,
                    sampleId: "",
                    sampleName: "",
                    group: "",
                    replicate: 0,
                    colorHex: PlateColorPalette.reservedHex,
                    manual: false
                )
            }
        }
        
        let validation = validateLayout(format: format, samples: samples, rules: rules, assignments: assignments)
        let vals = Array(assignments.values)
        return PlateAssignResult(
            assignments: assignments,
            issues: validation.issues,
            unplaced: validation.unplaced,
            seed: rules.seed,
            reservedCount: vals.filter { $0.type == .reserved }.count,
            assignedCount: vals.count,
            sampleWellsCount: vals.filter { $0.type == .sample }.count,
            controlWellsCount: vals.filter { $0.type == .control }.count,
            blankWellsCount: vals.filter { $0.type == .blank }.count
        )
    }
    
    // MARK: - 3. CSV / TSV 解析与导出 (与 qPCR 模块无缝互通)
    
    public static func splitDelimitedLine(_ line: String, delimiter: Character) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        current.append("\"")
                        i += 2
                        continue
                    } else {
                        quoted = false
                    }
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "\"" {
                    quoted = true
                } else if ch == delimiter {
                    out.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            i += 1
        }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }
    
    public static func detectDelimiter(in line: String) -> Character {
        var tabs = 0
        var commas = 0
        var semicolons = 0
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() }
            if quoted { continue }
            if ch == "\t" { tabs += 1 }
            else if ch == "," { commas += 1 }
            else if ch == ";" { semicolons += 1 }
        }
        if tabs >= commas && tabs >= semicolons && tabs > 0 { return "\t" }
        if semicolons > commas { return ";" }
        return ","
    }
    
    /// 解析粘贴或导入的样品列表 CSV/TSV
    public static func parseSampleTable(_ text: String) -> [PlateSampleItem] {
        let cleaned = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = cleaned
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let firstLine = lines.first else { return [] }
        
        let delimiter = detectDelimiter(in: firstLine)
        let firstCells = splitDelimitedLine(firstLine, delimiter: delimiter)
        let nameHeaders: Set<String> = ["sample", "samples", "sample id", "sampleid", "sample name", "samplename", "sample_id", "name", "id", "样品", "样品名称"]
        let groupHeaders: Set<String> = ["group", "condition", "treatment", "category", "class", "分组", "组别"]
        let repHeaders: Set<String> = ["replicate", "replicates", "reps", "rep", "n", "count", "复孔", "复孔数"]
        
        let hasHeader = firstCells.contains { nameHeaders.contains($0.lowercased()) }
        var nameIdx = 0
        var groupIdx = 1
        var repIdx = 2
        var startRow = 0
        
        if hasHeader {
            startRow = 1
            nameIdx = firstCells.firstIndex { nameHeaders.contains($0.lowercased()) } ?? 0
            groupIdx = firstCells.firstIndex { groupHeaders.contains($0.lowercased()) } ?? -1
            repIdx = firstCells.firstIndex { repHeaders.contains($0.lowercased()) } ?? -1
        }
        
        var items: [PlateSampleItem] = []
        for idx in startRow..<lines.count {
            let cells = splitDelimitedLine(lines[idx], delimiter: delimiter)
            let name = nameIdx < cells.count ? cells[nameIdx] : ""
            guard !name.isEmpty else { continue }
            let group = (groupIdx >= 0 && groupIdx < cells.count && !cells[groupIdx].isEmpty) ? cells[groupIdx] : "Group A"
            var reps: Int? = nil
            if repIdx >= 0 && repIdx < cells.count, let parsed = Int(cells[repIdx]) {
                reps = max(1, min(12, parsed))
            }
            let colorHex = PlateColorPalette.hexForGroup(group, indexFallback: items.count)
            items.append(PlateSampleItem(name: name, group: group, colorHex: colorHex, customReplicates: reps))
        }
        return items
    }
    
    /// 构建整板孔位明细行
    public static func buildPlateTableRows(
        format: PlateFormat,
        assignments: [String: PlateWellAssignment]
    ) -> [PlateTableRow] {
        var rows: [PlateTableRow] = []
        rows.reserveCapacity(format.totalWells)
        for r in 0..<format.rows {
            for c in 0..<format.cols {
                let well = PlateFormat.wellID(row: r, col: c)
                if let a = assignments[well] {
                    rows.append(
                        PlateTableRow(
                            well: well,
                            row: r,
                            col: c,
                            sample: a.sampleName.isEmpty ? a.sampleId : a.sampleName,
                            group: a.group,
                            type: a.type.rawValue,
                            replicate: a.type == .reserved ? nil : a.replicate
                        )
                    )
                } else {
                    rows.append(
                        PlateTableRow(
                            well: well,
                            row: r,
                            col: c,
                            sample: "",
                            group: "",
                            type: "empty",
                            replicate: nil
                        )
                    )
                }
            }
        }
        return rows
    }
    
    public static func exportPlateCSV(format: PlateFormat, assignments: [String: PlateWellAssignment]) -> String {
        let rows = buildPlateTableRows(format: format, assignments: assignments)
        var lines = ["well,sample,group,type,replicate"]
        for row in rows {
            let repStr = row.replicate.map(String.init) ?? ""
            let cells = [row.well, row.sample, row.group, row.type, repStr].map { cell -> String in
                if cell.contains(",") || cell.contains("\"") || cell.contains("\n") {
                    return "\"\(cell.replacingOccurrences(of: "\"", with: "\"\""))\""
                }
                return cell
            }
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
    
    public static func exportPlateTSV(format: PlateFormat, assignments: [String: PlateWellAssignment]) -> String {
        let rows = buildPlateTableRows(format: format, assignments: assignments)
        var lines = ["well\tsample\tgroup\ttype\treplicate"]
        for row in rows {
            let repStr = row.replicate.map(String.init) ?? ""
            lines.append([row.well, row.sample, row.group, row.type, repStr].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 4. 全局微孔板共享状态中心 (供 PlateDesignerView 与 QPCRAnalysisView 跨模块一键联动)

public final class PlateLayoutStore: ObservableObject {
    public static let shared = PlateLayoutStore()
    
    @Published public var title: String = "96孔板_qPCR与克隆排布"
    @Published public var format: PlateFormat = .well96
    @Published public var samples: [PlateSampleItem] = [
        PlateSampleItem(name: "WT-Ctrl", group: "ControlGroup", colorHex: "#3B82F6", customReplicates: 3),
        PlateSampleItem(name: "TP53-OE", group: "Overexpression", colorHex: "#10B981", customReplicates: 3),
        PlateSampleItem(name: "TP53-KO1", group: "Knockout", colorHex: "#F59E0B", customReplicates: 3),
        PlateSampleItem(name: "TP53-KO2", group: "Knockout", colorHex: "#EC4899", customReplicates: 3),
        PlateSampleItem(name: "Rescue-Mut", group: "Rescue", colorHex: "#8B5CF6", customReplicates: 3)
    ]
    @Published public var rules: PlateLayoutRules = PlateLayoutRules()
    @Published public var assignments: [String: PlateWellAssignment] = [:]
    @Published public var issues: [PlateLayoutIssue] = []
    @Published public var unplaced: [PlateUnplacedSample] = []
    @Published public var colorByGroup: Bool = true
    @Published public var showWellLabels: Bool = true
    
    private init() {
        regenerateLayout()
    }
    
    public func regenerateLayout() {
        let res = PlateLayoutEngine.assignPlate(format: format, samples: samples, rules: rules)
        self.assignments = res.assignments
        self.issues = res.issues
        self.unplaced = res.unplaced
    }
    
    public func revalidateCurrentAssignments() {
        let val = PlateLayoutEngine.validateLayout(format: format, samples: samples, rules: rules, assignments: assignments)
        self.issues = val.issues
        self.unplaced = val.unplaced
    }
    
    public func randomizeWithNewSeed() {
        rules.seed = UInt32.random(in: 100_000...999_999_999)
        regenerateLayout()
    }
}
