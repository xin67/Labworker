import Foundation
import CoreGraphics

// MARK: - 1. 系统发育树数据模型与设置 (Phylogenetic Tree Models)

public enum PhyloLayoutMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case phylogram = "phylogram"
    case cladogram = "cladogram"
    case circular = "circular"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .phylogram: return "直角进化树 (Phylogram)"
        case .cladogram: return "等距分支图 (Cladogram)"
        case .circular:  return "环形进化树 (Circular)"
        }
    }
    
    public var shortTitle: String {
        switch self {
        case .phylogram: return "直角真实枝长"
        case .cladogram: return "等距分支"
        case .circular:  return "环形辐射"
        }
    }
}

public struct PhyloTreeNode: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var length: Double?
    public var support: Double?
    public var comment: String?
    public var children: [PhyloTreeNode]
    
    public init(
        id: String,
        name: String = "",
        length: Double? = nil,
        support: Double? = nil,
        comment: String? = nil,
        children: [PhyloTreeNode] = []
    ) {
        self.id = id
        self.name = name
        self.length = length
        self.support = support
        self.comment = comment
        self.children = children
    }
    
    public var isLeaf: Bool { children.isEmpty }
    
    /// 将 0..1 区间的小数支持率统一转换为 0..100 百分比
    public var normalizedSupportPercent: Double? {
        guard let s = support, s.isFinite else { return nil }
        return (s >= 0.0 && s <= 1.0) ? (s * 100.0) : s
    }
}

public struct PhyloMetaEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { leaf }
    public var leaf: String
    public var group: String
    public var colorHex: String
    
    public init(leaf: String, group: String, colorHex: String = "") {
        self.leaf = leaf
        self.group = group
        self.colorHex = colorHex
    }
}

public struct PhyloResolvedMetadata: Sendable {
    public var byLeaf: [String: (group: String, colorHex: String)]
    public var groupOrder: [String]
    public var groupColors: [String: String]
    public var groupCounts: [String: Int]
    
    public init(
        byLeaf: [String: (group: String, colorHex: String)] = [:],
        groupOrder: [String] = [],
        groupColors: [String: String] = [:],
        groupCounts: [String: Int] = [:]
    ) {
        self.byLeaf = byLeaf
        self.groupOrder = groupOrder
        self.groupColors = groupColors
        self.groupCounts = groupCounts
    }
}

public struct PhyloLayoutNode: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let length: Double?
    public let support: Double?
    public let comment: String?
    public let depth: Double
    public let level: Int
    public let parentId: String?
    public var x: Double
    public var y: Double
    public var radius: Double
    public var angle: Double
    public var parentRadius: Double
    public var parentAngle: Double
    public var parentX: Double
    public var parentY: Double
    public let isLeaf: Bool
    public let isCollapsed: Bool
    public let leafCount: Int
    public let terminalIndex: Int?
    public let group: String?
    public let colorHex: String?
    public var startAngle: Double
    public var endAngle: Double
}

public struct PhyloScaleBarInfo: Sendable {
    public let x: Double
    public let y: Double
    public let lengthPx: Double
    public let unit: Double
}

public struct PhyloTreeLayout: Sendable {
    public let mode: PhyloLayoutMode
    public let width: Double
    public let height: Double
    public let centerX: Double
    public let centerY: Double
    public let nodes: [PhyloLayoutNode]
    public let byId: [String: PhyloLayoutNode]
    public let terminals: [PhyloLayoutNode]
    public let leafCount: Int
    public let nodeCount: Int
    public let maxDepth: Double
    public let depthScale: Double
    public let scaleBar: PhyloScaleBarInfo?
}

public struct PhyloTreeComparison: Sendable {
    public let sharedLeaves: [String]
    public let leavesOnlyA: [String]
    public let leavesOnlyB: [String]
    public let splitsA: Int
    public let splitsB: Int
    public let sharedSplits: Int
    public let uniqueA: Int
    public let uniqueB: Int
    public let rfDistance: Int
    public let maxRfDistance: Int
    public let normalizedRf: Double
    public let identical: Bool
}

// MARK: - 2. Newick 解析器、拓扑变换、几何布局与 Robinson-Foulds 比较引擎

public enum PhylogeneticTreeEngine {
    public static let defaultExampleNewick =
        "((((Homo_sapiens:0.021,Pan_troglodytes:0.024)100:0.041,Gorilla_gorilla:0.068)98:0.052,Pongo_abelii:0.091)100:0.113,((Mus_musculus:0.051,Rattus_norvegicus:0.063)100:0.082,((Canis_lupus:0.071,Felis_catus:0.089)96:0.048,((Bos_taurus:0.061,Sus_scrofa:0.083)94:0.051,Equus_caballus:0.102)89:0.044)92:0.061)99:0.104)100;"
    
    public static let defaultComparisonNewick =
        "((((Homo_sapiens:0.021,Pan_troglodytes:0.024)100:0.041,Gorilla_gorilla:0.068)98:0.052,Pongo_abelii:0.091)100:0.113,((Mus_musculus:0.051,Rattus_norvegicus:0.063)100:0.082,((Felis_catus:0.089,(Bos_taurus:0.061,Sus_scrofa:0.083)94:0.051)88:0.045,(Canis_lupus:0.071,Equus_caballus:0.102)85:0.049)91:0.061)99:0.104)100;"
    
    public static let defaultExampleMetadataCSV = """
    leaf,group,color
    Homo_sapiens,Primates,#3B82F6
    Pan_troglodytes,Primates,#3B82F6
    Gorilla_gorilla,Primates,#3B82F6
    Pongo_abelii,Primates,#3B82F6
    Mus_musculus,Rodents,#F59E0B
    Rattus_norvegicus,Rodents,#F59E0B
    Canis_lupus,Carnivores,#EC4899
    Felis_catus,Carnivores,#EC4899
    Bos_taurus,Artiodactyla,#10B981
    Sus_scrofa,Artiodactyla,#10B981
    Equus_caballus,Perissodactyla,#8B5CF6
    """
    
    // MARK: 2.1 Newick 递归下降解析器
    
    public enum NewickParseError: LocalizedError {
        case emptyInput
        case syntaxError(position: Int, detail: String)
        
        public var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "Newick 文本为空"
            case .syntaxError(let pos, let detail):
                return "Newick 语法错误 (字符位置 \(pos))：\(detail)"
            }
        }
    }
    
    private final class Parser {
        private let chars: [Character]
        private var pos: Int = 0
        private var nextId: Int = 1
        
        init(_ text: String) {
            self.chars = Array(text)
        }
        
        private static let stopChars: Set<Character> = ["(", ")", ",", ":", ";", "[", "]", "'", "\""]
        
        func parse() throws -> PhyloTreeNode {
            skipWhitespaceAndLeadingComments()
            if pos >= chars.count { throw NewickParseError.emptyInput }
            if peek() == ";" { throw NewickParseError.syntaxError(position: pos, detail: "缺少根节点") }
            let root = try parseSubtree()
            skipWhitespaceAndLeadingComments()
            if peek() == ";" {
                pos += 1
                skipWhitespaceAndLeadingComments()
            }
            return root
        }
        
        private func parseSubtree() throws -> PhyloTreeNode {
            skipWhitespaceAndLeadingComments()
            guard let first = peek() else {
                throw NewickParseError.syntaxError(position: pos, detail: "意外到达文件末尾")
            }
            if first == "(" {
                pos += 1
                var node = PhyloTreeNode(id: "n\(nextId)")
                nextId += 1
                skipWhitespaceAndLeadingComments()
                if peek() == ")" {
                    throw NewickParseError.syntaxError(position: pos, detail: "空括号 ()")
                }
                while true {
                    let child = try parseSubtree()
                    node.children.append(child)
                    skipWhitespaceAndLeadingComments()
                    guard let ch = peek() else {
                        throw NewickParseError.syntaxError(position: pos, detail: "括号未闭合")
                    }
                    if ch == "," {
                        pos += 1
                        continue
                    } else if ch == ")" {
                        pos += 1
                        break
                    } else {
                        throw NewickParseError.syntaxError(position: pos, detail: "意外字符 '\(ch)'")
                    }
                }
                try parseSuffix(into: &node, isInternal: true)
                return node
            } else {
                if first == ")" || first == ";" {
                    throw NewickParseError.syntaxError(position: pos, detail: "意外分隔符 '\(first)'")
                }
                var node = PhyloTreeNode(id: "n\(nextId)")
                nextId += 1
                if first != ":" && first != "[" && first != "," {
                    node.name = try readLabel()
                }
                try parseSuffix(into: &node, isInternal: false)
                return node
            }
        }
        
        private func parseSuffix(into node: inout PhyloTreeNode, isInternal: Bool) throws {
            while true {
                skipWhitespace()
                guard let ch = peek() else { break }
                if ch == "," || ch == ")" || ch == ";" { break }
                if ch == ":" {
                    pos += 1
                    node.length = try readNumber()
                    continue
                }
                if ch == "[" {
                    let comment = try readComment()
                    node.comment = node.comment.map { "\($0) \(comment)" } ?? comment
                    if node.support == nil, let sup = Self.extractSupportFromComment(comment) {
                        node.support = sup
                    }
                    continue
                }
                let label = try readLabel()
                if label.isEmpty { break }
                if isInternal {
                    if let num = Double(label), node.name.isEmpty, node.support == nil {
                        node.support = num
                    } else if node.name.isEmpty {
                        node.name = label
                    } else if let num = Double(label), node.support == nil {
                        node.support = num
                    } else {
                        node.name += " \(label)"
                    }
                } else {
                    node.name = node.name.isEmpty ? label : "\(node.name) \(label)"
                }
            }
        }
        
        private func readLabel() throws -> String {
            guard let ch = peek() else { return "" }
            if ch == "'" || ch == "\"" {
                return try readQuoted(quote: ch)
            }
            var out = ""
            while pos < chars.count {
                let c = chars[pos]
                if Self.stopChars.contains(c) { break }
                out.append(c)
                pos += 1
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        private func readQuoted(quote: Character) throws -> String {
            let start = pos
            pos += 1
            var out = ""
            while pos < chars.count {
                let c = chars[pos]
                if c == quote {
                    if pos + 1 < chars.count && chars[pos + 1] == quote {
                        out.append(quote)
                        pos += 2
                        continue
                    }
                    pos += 1
                    return out
                }
                out.append(c)
                pos += 1
            }
            throw NewickParseError.syntaxError(position: start, detail: "引号未闭合")
        }
        
        private func readComment() throws -> String {
            let start = pos
            pos += 1
            var depth = 1
            var out = ""
            while pos < chars.count {
                let c = chars[pos]
                pos += 1
                if c == "[" {
                    depth += 1
                    out.append(c)
                } else if c == "]" {
                    depth -= 1
                    if depth == 0 { return out }
                    out.append(c)
                } else {
                    out.append(c)
                }
            }
            throw NewickParseError.syntaxError(position: start, detail: "方括号注释未闭合")
        }
        
        private func readNumber() throws -> Double {
            skipWhitespace()
            let start = pos
            var numStr = ""
            while pos < chars.count {
                let c = chars[pos]
                if c.isNumber || c == "." || c == "-" || c == "+" || c == "e" || c == "E" {
                    numStr.append(c)
                    pos += 1
                } else {
                    break
                }
            }
            guard let val = Double(numStr), val.isFinite else {
                throw NewickParseError.syntaxError(position: start, detail: "无效枝长数值 '\(numStr)'")
            }
            return val
        }
        
        private func skipWhitespace() {
            while pos < chars.count && chars[pos].isWhitespace {
                pos += 1
            }
        }
        
        private func skipWhitespaceAndLeadingComments() {
            while true {
                skipWhitespace()
                if peek() == "[" {
                    _ = try? readComment()
                } else {
                    break
                }
            }
        }
        
        private func peek() -> Character? {
            pos < chars.count ? chars[pos] : nil
        }
        
        private static func extractSupportFromComment(_ comment: String) -> Double? {
            if let range = comment.range(of: #"(?:support|boot(?:strap)?)\s*[=:]\s*([+-]?\d+\.?\d*)"#, options: [.regularExpression, .caseInsensitive]) {
                let sub = String(comment[range])
                if let eqIdx = sub.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                    let numPart = sub[sub.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                    return Double(numPart)
                }
            }
            let trimmed = comment.replacingOccurrences(of: "&", with: "").trimmingCharacters(in: .whitespaces)
            return Double(trimmed)
        }
    }
    
    public static func parseNewick(_ text: String) throws -> PhyloTreeNode {
        try Parser(text).parse()
    }
    
    public static func toNewick(_ root: PhyloTreeNode, collapsedIDs: Set<String> = []) -> String {
        func escape(_ label: String) -> String {
            guard !label.isEmpty else { return "" }
            if label.rangeOfCharacter(from: CharacterSet(charactersIn: " (),:;[]'\"")) != nil {
                return "'\(label.replacingOccurrences(of: "'", with: "''"))'"
            }
            return label
        }
        
        func serialize(_ node: PhyloTreeNode, isRoot: Bool) -> String {
            let isCollapsed = !isRoot && collapsedIDs.contains(node.id) && !node.children.isEmpty
            var out = ""
            if !node.children.isEmpty && !isCollapsed {
                let childJoined = node.children.map { serialize($0, isRoot: false) }.joined(separator: ",")
                out = "(\(childJoined))"
                if !node.name.isEmpty {
                    out += escape(node.name)
                } else if let sup = node.support {
                    out += String(format: "%g", sup)
                }
            } else {
                out = escape(node.name)
            }
            if let len = node.length, (!isRoot || len > 0) {
                out += ":\(String(format: "%g", len))"
            }
            return out
        }
        return serialize(root, isRoot: true) + ";"
    }
    
    // MARK: 2.2 树拓扑操作 (阶梯化、字母排序、中点定根、子树旋转、祖先路径)
    
    public static func collectLeafNodes(_ root: PhyloTreeNode) -> [PhyloTreeNode] {
        var leaves: [PhyloTreeNode] = []
        func walk(_ node: PhyloTreeNode) {
            if node.children.isEmpty {
                leaves.append(node)
            } else {
                for c in node.children { walk(c) }
            }
        }
        walk(root)
        return leaves
    }
    
    public static func descendantLeafCount(_ node: PhyloTreeNode) -> Int {
        if node.children.isEmpty { return 1 }
        return node.children.reduce(0) { $0 + descendantLeafCount($1) }
    }
    
    public static func ancestorPath(root: PhyloTreeNode, targetID: String) -> Set<String> {
        var parentMap: [String: String] = [:]
        func walk(_ n: PhyloTreeNode) {
            for c in n.children {
                parentMap[c.id] = n.id
                walk(c)
            }
        }
        walk(root)
        var path: Set<String> = []
        var cur: String? = targetID
        while let id = cur {
            path.insert(id)
            cur = parentMap[id]
        }
        return path
    }
    
    private static func minLeafName(_ node: PhyloTreeNode) -> String {
        if node.children.isEmpty { return node.name }
        return node.children.map(minLeafName).min() ?? ""
    }
    
    /// 阶梯化排序 (Ladderize)
    public static func ladderize(_ root: PhyloTreeNode, descending: Bool = false) -> PhyloTreeNode {
        var copy = root
        copy.children = copy.children.map { ladderize($0, descending: descending) }
        copy.children.sort { a, b in
            let sa = descendantLeafCount(a)
            let sb = descendantLeafCount(b)
            if sa != sb {
                return descending ? (sa > sb) : (sa < sb)
            }
            let na = minLeafName(a)
            let nb = minLeafName(b)
            return descending ? (na > nb) : (na < nb)
        }
        return copy
    }
    
    /// 按叶节点名称字母序排序
    public static func sortAlphabetically(_ root: PhyloTreeNode) -> PhyloTreeNode {
        var copy = root
        copy.children = copy.children.map(sortAlphabetically)
        copy.children.sort { minLeafName($0).localizedStandardCompare(minLeafName($1)) == .orderedAscending }
        return copy
    }
    
    /// 旋转指定内部节点的子分支顺序
    public static func rotateChildren(in root: PhyloTreeNode, nodeID: String) -> PhyloTreeNode {
        var copy = root
        if copy.id == nodeID, copy.children.count > 1 {
            let first = copy.children.removeFirst()
            copy.children.append(first)
            return copy
        }
        copy.children = copy.children.map { rotateChildren(in: $0, nodeID: nodeID) }
        return copy
    }
    
    /// 中点定根 (Midpoint Rooting)
    public static func midpointRoot(_ root: PhyloTreeNode) -> PhyloTreeNode? {
        struct AdjEdge {
            let neighborID: String
            let length: Double
        }
        var byId: [String: PhyloTreeNode] = [:]
        var adj: [String: [AdjEdge]] = [:]
        
        func indexTree(_ n: PhyloTreeNode) {
            byId[n.id] = n
            for c in n.children {
                let len = max(0.0, c.length ?? 0.0)
                adj[n.id, default: []].append(AdjEdge(neighborID: c.id, length: len))
                adj[c.id, default: []].append(AdjEdge(neighborID: n.id, length: len))
                indexTree(c)
            }
        }
        indexTree(root)
        
        func farthestLeaf(from startID: String) -> (leafID: String, dist: Double, parents: [String: String], dists: [String: Double]) {
            var parents: [String: String] = [:]
            var dists: [String: Double] = [startID: 0.0]
            var bestID = startID
            var bestDist = -1.0
            
            func dfs(_ cur: String, parent: String?, acc: Double) {
                if let p = parent { parents[cur] = p }
                dists[cur] = acc
                let isTerminal = (adj[cur]?.count ?? 0) <= 1
                if isTerminal && acc > bestDist {
                    bestDist = acc
                    bestID = cur
                }
                for edge in adj[cur] ?? [] where edge.neighborID != parent {
                    dfs(edge.neighborID, parent: cur, acc: acc + edge.length)
                }
            }
            dfs(startID, parent: nil, acc: 0.0)
            return (bestID, bestDist, parents, dists)
        }
        
        // 两次 DFS 求整棵无根树直径路径 (Diameter Path)
        let pass1 = farthestLeaf(from: root.id)
        let pass2 = farthestLeaf(from: pass1.leafID)
        guard pass2.dist > 0 else { return nil }
        
        var path: [String] = []
        var cur: String? = pass2.leafID
        while let id = cur {
            path.append(id)
            cur = pass2.parents[id]
        }
        path.reverse()
        guard path.count >= 2 else { return nil }
        
        let halfDist = pass2.dist / 2.0
        var splitIndex = 0
        for i in 0..<(path.count - 1) {
            let d0 = pass2.dists[path[i]] ?? 0.0
            let d1 = pass2.dists[path[i + 1]] ?? 0.0
            if d0 <= halfDist && halfDist <= d1 {
                splitIndex = i
                break
            }
        }
        
        let leftID = path[splitIndex]
        let rightID = path[splitIndex + 1]
        let dLeft = pass2.dists[leftID] ?? 0.0
        let dRight = pass2.dists[rightID] ?? 0.0
        
        func buildDirected(_ nodeID: String, excluding fromID: String) -> PhyloTreeNode {
            let orig = byId[nodeID]!
            var directed = PhyloTreeNode(
                id: orig.id,
                name: orig.name,
                length: nil,
                support: orig.support,
                comment: orig.comment,
                children: []
            )
            for edge in adj[nodeID] ?? [] where edge.neighborID != fromID {
                var child = buildDirected(edge.neighborID, excluding: nodeID)
                child.length = edge.length
                directed.children.append(child)
            }
            return directed
        }
        
        var leftSub = buildDirected(leftID, excluding: rightID)
        var rightSub = buildDirected(rightID, excluding: leftID)
        leftSub.length = max(0.0, halfDist - dLeft)
        rightSub.length = max(0.0, dRight - halfDist)
        
        return PhyloTreeNode(
            id: "root_midpoint",
            name: "",
            length: nil,
            support: 100,
            comment: nil,
            children: [leftSub, rightSub]
        )
    }
    
    // MARK: 2.3 Robinson-Foulds 拓扑距离对比
    
    public static func compareTrees(current: PhyloTreeNode, other: PhyloTreeNode) -> PhyloTreeComparison {
        let leavesA = Set(collectLeafNodes(current).map(\.name).filter { !$0.isEmpty })
        let leavesB = Set(collectLeafNodes(other).map(\.name).filter { !$0.isEmpty })
        let shared = leavesA.intersection(leavesB)
        let sharedSorted = shared.sorted()
        let onlyA = leavesA.subtracting(leavesB).sorted()
        let onlyB = leavesB.subtracting(leavesA).sorted()
        
        func canonicalSplitKey(_ side: Set<String>) -> String {
            let otherSide = shared.subtracting(side).sorted()
            let ownSide = side.sorted()
            let ownJoined = ownSide.joined(separator: "|")
            let otherJoined = otherSide.joined(separator: "|")
            if ownSide.count < otherSide.count || (ownSide.count == otherSide.count && ownJoined <= otherJoined) {
                return ownJoined
            }
            return otherJoined
        }
        
        func collectSplits(_ node: PhyloTreeNode) -> (names: Set<String>, splits: Set<String>) {
            if node.children.isEmpty {
                var names = Set<String>()
                if shared.contains(node.name) { names.insert(node.name) }
                return (names, [])
            }
            var names = Set<String>()
            var splits = Set<String>()
            for child in node.children {
                let res = collectSplits(child)
                names.formUnion(res.names)
                splits.formUnion(res.splits)
            }
            if names.count >= 2 && (shared.count - names.count) >= 2 {
                splits.insert(canonicalSplitKey(names))
            }
            return (names, splits)
        }
        
        let splitsA = collectSplits(current).splits
        let splitsB = collectSplits(other).splits
        let sharedSplits = splitsA.intersection(splitsB).count
        let uniqueA = splitsA.subtracting(splitsB).count
        let uniqueB = splitsB.subtracting(splitsA).count
        let rf = uniqueA + uniqueB
        let maxRf = splitsA.count + splitsB.count
        let normRf = maxRf > 0 ? Double(rf) / Double(maxRf) : 0.0
        
        return PhyloTreeComparison(
            sharedLeaves: sharedSorted,
            leavesOnlyA: onlyA,
            leavesOnlyB: onlyB,
            splitsA: splitsA.count,
            splitsB: splitsB.count,
            sharedSplits: sharedSplits,
            uniqueA: uniqueA,
            uniqueB: uniqueB,
            rfDistance: rf,
            maxRfDistance: maxRf,
            normalizedRf: normRf,
            identical: rf == 0 && onlyA.isEmpty && !sharedSorted.isEmpty
        )
    }
    
    // MARK: 2.4 元数据解析与三种进化树几何布局解算器
    
    public static func parseMetadataCSV(_ rawText: String) -> PhyloResolvedMetadata {
        let cleaned = rawText
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = cleaned
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return PhyloResolvedMetadata() }
        
        let delim = PlateLayoutEngine.detectDelimiter(in: lines[0])
        let firstCells = PlateLayoutEngine.splitDelimitedLine(lines[0], delimiter: delim).map { $0.lowercased() }
        let hasHeader = firstCells.contains("leaf") || firstCells.contains("taxon") || firstCells.contains("name") || firstCells.contains("species")
        let startRow = hasHeader ? 1 : 0
        
        var byLeaf: [String: (group: String, colorHex: String)] = [:]
        var groupOrder: [String] = []
        var groupColors: [String: String] = [:]
        var groupCounts: [String: Int] = [:]
        
        for idx in startRow..<lines.count {
            let cells = PlateLayoutEngine.splitDelimitedLine(lines[idx], delimiter: delim)
            guard cells.count >= 2 else { continue }
            let leaf = cells[0].trimmingCharacters(in: .whitespaces)
            let group = cells[1].trimmingCharacters(in: .whitespaces)
            guard !leaf.isEmpty && !group.isEmpty else { continue }
            if !groupOrder.contains(group) {
                groupOrder.append(group)
            }
            let explicitHex = cells.count >= 3 ? cells[2].trimmingCharacters(in: .whitespaces) : ""
            let resolvedHex = explicitHex.hasPrefix("#")
                ? explicitHex
                : (groupColors[group] ?? PlateColorPalette.hexForGroup(group, indexFallback: groupOrder.count - 1))
            if groupColors[group] == nil {
                groupColors[group] = resolvedHex
            }
            byLeaf[leaf] = (group, resolvedHex)
            groupCounts[group, default: 0] += 1
        }
        return PhyloResolvedMetadata(
            byLeaf: byLeaf,
            groupOrder: groupOrder,
            groupColors: groupColors,
            groupCounts: groupCounts
        )
    }
    
    private static func niceUnit(_ target: Double) -> Double? {
        guard target > 0 && target.isFinite else { return nil }
        let expVal = floor(log10(target))
        let base = pow(10.0, expVal)
        let frac = target / base
        let nice: Double = frac <= 1.0 ? 1.0 : (frac <= 2.0 ? 2.0 : (frac <= 5.0 ? 5.0 : 10.0))
        return nice * base
    }
    
    public static func computeLayout(
        root: PhyloTreeNode,
        mode: PhyloLayoutMode,
        fontSize: Double = 12.0,
        collapsedIDs: Set<String> = [],
        metadata: PhyloResolvedMetadata = PhyloResolvedMetadata(),
        showScaleBar: Bool = true
    ) -> PhyloTreeLayout {
        func maxBranchDist(_ n: PhyloTreeNode) -> Double {
            if n.children.isEmpty || collapsedIDs.contains(n.id) { return 0.0 }
            return n.children.map { max(0.0, $0.length ?? 0.0) + maxBranchDist($0) }.max() ?? 0.0
        }
        let branchMax = maxBranchDist(root)
        let useLevels = (mode == .cladogram) || (branchMax <= 0.0)
        
        func uniformGroup(_ n: PhyloTreeNode) -> String? {
            if n.children.isEmpty {
                return metadata.byLeaf[n.name]?.group
            }
            var firstGrp: String? = nil
            for c in n.children {
                guard let cg = uniformGroup(c) else { return nil }
                if firstGrp == nil { firstGrp = cg }
                else if firstGrp != cg { return nil }
            }
            return firstGrp
        }
        
        var nodes: [PhyloLayoutNode] = []
        var childIDsByNode: [String: [String]] = [:]
        var terminalCursor = 0
        
        func build(_ n: PhyloTreeNode, parentId: String?, depth: Double, level: Int) {
            let isCollapsed = !n.children.isEmpty && collapsedIDs.contains(n.id)
            var cIDs: [String] = []
            if !isCollapsed {
                for c in n.children {
                    cIDs.append(c.id)
                    let step = useLevels ? 1.0 : max(0.0, c.length ?? 0.0)
                    build(c, parentId: n.id, depth: depth + step, level: level + 1)
                }
            }
            childIDsByNode[n.id] = cIDs
            let grp = uniformGroup(n)
            let colorHex: String? = n.children.isEmpty
                ? (metadata.byLeaf[n.name]?.colorHex ?? grp.flatMap { metadata.groupColors[$0] })
                : grp.flatMap { metadata.groupColors[$0] }
            let isTerm = cIDs.isEmpty
            let termIdx: Int? = isTerm ? terminalCursor : nil
            if isTerm { terminalCursor += 1 }
            
            nodes.append(
                PhyloLayoutNode(
                    id: n.id,
                    name: n.name,
                    length: n.length,
                    support: n.normalizedSupportPercent,
                    comment: n.comment,
                    depth: depth,
                    level: level,
                    parentId: parentId,
                    x: 0,
                    y: 0,
                    radius: 0,
                    angle: 0,
                    parentRadius: 0,
                    parentAngle: 0,
                    parentX: 0,
                    parentY: 0,
                    isLeaf: n.children.isEmpty,
                    isCollapsed: isCollapsed,
                    leafCount: descendantLeafCount(n),
                    terminalIndex: termIdx,
                    group: grp,
                    colorHex: colorHex,
                    startAngle: 0,
                    endAngle: 0
                )
            )
        }
        
        build(root, parentId: nil, depth: 0.0, level: 0)
        let terminalCount = max(1, terminalCursor)
        let maxDepth = max(0.000001, nodes.map(\.depth).max() ?? 1.0)
        let rowHeight = max(28.0, fontSize * 2.4)
        let marginLeft = 36.0
        let marginTop = 28.0
        let marginBottom = showScaleBar && !useLevels ? 54.0 : 28.0
        let labelRightAllowance = 190.0
        
        let plotWidth = max(460.0, min(780.0, 440.0 + Double(terminalCount) * 6.0))
        let circularRadius = max(175.0, (Double(terminalCount) * rowHeight) / (2.0 * Double.pi) * 1.15)
        let circularOuter = circularRadius + labelRightAllowance
        
        let width: Double = (mode == .circular)
            ? max(580.0, circularOuter * 2.0 + 48.0)
            : (marginLeft + plotWidth + labelRightAllowance + 32.0)
        let plotHeight: Double = (mode == .circular)
            ? (circularRadius * 2.0)
            : (Double(terminalCount) * rowHeight)
        let height: Double = (mode == .circular)
            ? (marginTop + circularOuter * 2.0 + marginBottom)
            : (marginTop + plotHeight + marginBottom)
        
        let centerX = width / 2.0
        let centerY = (mode == .circular) ? (marginTop + circularOuter) : (marginTop + plotHeight / 2.0)
        let depthScale = (mode == .circular) ? (circularRadius / maxDepth) : (plotWidth / maxDepth)
        
        var indexById: [String: Int] = [:]
        for (idx, item) in nodes.enumerated() {
            indexById[item.id] = idx
        }
        
        // 1) 计算矩形 Y 坐标（后序遍历：终端节点先赋值，内部节点取首尾子节点均值）
        for i in 0..<nodes.count {
            if let tIdx = nodes[i].terminalIndex {
                nodes[i].y = marginTop + (Double(tIdx) + 0.5) * rowHeight
            } else if let cIDs = childIDsByNode[nodes[i].id],
                      let firstId = cIDs.first, let lastId = cIDs.last,
                      let fIdx = indexById[firstId], let lIdx = indexById[lastId] {
                nodes[i].y = 0.5 * (nodes[fIdx].y + nodes[lIdx].y)
            }
        }
        
        // 2) 计算 X 或极坐标 (radius, angle)
        if mode == .circular {
            let stepAngle = (2.0 * Double.pi) / Double(terminalCount)
            let startOffset = -Double.pi / 2.0
            for i in 0..<nodes.count {
                if let tIdx = nodes[i].terminalIndex {
                    let ang = startOffset + (Double(tIdx) + 0.5) * stepAngle
                    nodes[i].angle = ang
                    nodes[i].startAngle = ang
                    nodes[i].endAngle = ang
                } else if let cIDs = childIDsByNode[nodes[i].id],
                          let firstId = cIDs.first, let lastId = cIDs.last,
                          let fIdx = indexById[firstId], let lIdx = indexById[lastId] {
                    nodes[i].startAngle = nodes[fIdx].angle
                    nodes[i].endAngle = nodes[lIdx].angle
                    nodes[i].angle = 0.5 * (nodes[fIdx].angle + nodes[lIdx].angle)
                }
                nodes[i].radius = nodes[i].depth * depthScale
                nodes[i].x = centerX + nodes[i].radius * cos(nodes[i].angle)
                nodes[i].y = centerY + nodes[i].radius * sin(nodes[i].angle)
            }
        } else {
            for i in 0..<nodes.count {
                nodes[i].x = marginLeft + nodes[i].depth * depthScale
            }
        }
        
        // 3) 写入父节点坐标以供直角或圆弧连线
        for i in 0..<nodes.count {
            guard let pid = nodes[i].parentId, let pIdx = indexById[pid] else { continue }
            let pNode = nodes[pIdx]
            if mode == .circular {
                nodes[i].parentRadius = pNode.radius
                nodes[i].parentAngle = pNode.angle
                nodes[i].parentX = centerX + pNode.radius * cos(nodes[i].angle)
                nodes[i].parentY = centerY + pNode.radius * sin(nodes[i].angle)
            } else {
                nodes[i].parentX = pNode.x
                nodes[i].parentY = pNode.y
            }
        }
        
        var byId: [String: PhyloLayoutNode] = [:]
        for item in nodes { byId[item.id] = item }
        let terminals = nodes.filter { $0.terminalIndex != nil }
        
        var scaleBar: PhyloScaleBarInfo? = nil
        if showScaleBar && !useLevels {
            let targetUnit = 100.0 / max(0.000001, depthScale)
            if let unit = niceUnit(targetUnit) {
                scaleBar = PhyloScaleBarInfo(
                    x: marginLeft + 8.0,
                    y: height - 18.0,
                    lengthPx: unit * depthScale,
                    unit: unit
                )
            }
        }
        
        return PhyloTreeLayout(
            mode: mode,
            width: width,
            height: height,
            centerX: centerX,
            centerY: centerY,
            nodes: nodes,
            byId: byId,
            terminals: terminals,
            leafCount: descendantLeafCount(root),
            nodeCount: nodes.count,
            maxDepth: maxDepth,
            depthScale: depthScale,
            scaleBar: scaleBar
        )
    }
}
