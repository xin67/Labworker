import Foundation
import AppKit

/// Broad GPP Public Portal (The RNAi Consortium / TRC) 在线 shRNA 检索服务
public final class BroadGPPService: @unchecked Sendable {
    public static let shared = BroadGPPService()
    
    public static let baseURLString = "https://portals.broadinstitute.org/gpp/public"
    public static let geneSearchURLString = "https://portals.broadinstitute.org/gpp/public/gene/search"
    public static let geneDetailsBaseURLString = "https://portals.broadinstitute.org/gpp/public/gene/details"
    public static let cloneDetailsBaseURLString = "https://portals.broadinstitute.org/gpp/public/clone/details"
    
    private struct MyGeneQueryResponse: Decodable {
        let hits: [MyGeneHit]?
    }
    
    private struct MyGeneHit: Decodable {
        let entrezgene: FlexibleString?
        let symbol: String?
        let alias: StringOrStringArray?
    }
    
    private enum FlexibleString: Decodable {
        case string(String)
        case int(Int)
        
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let intVal = try? c.decode(Int.self) {
                self = .int(intVal)
            } else if let strVal = try? c.decode(String.self) {
                self = .string(strVal)
            } else {
                throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected String or Int"))
            }
        }
        
        var value: String {
            switch self {
            case .string(let s): return s
            case .int(let i): return String(i)
            }
        }
    }
    
    private enum StringOrStringArray: Decodable {
        case single(String)
        case multiple([String])
        
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let arr = try? c.decode([String].self) {
                self = .multiple(arr)
            } else if let str = try? c.decode(String.self) {
                self = .single(str)
            } else {
                self = .multiple([])
            }
        }
        
        var values: [String] {
            switch self {
            case .single(let s): return [s]
            case .multiple(let a): return a
            }
        }
    }
    
    public struct ResolvedGeneInfo: Sendable, Equatable {
        public let geneID: String
        public let symbol: String
        public let description: String
        public let transcriptCount: Int
    }
    
    private static var compareCacheDirectory: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("CloneStudio", isDirectory: true)
            .appendingPathComponent("target_compare_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private static func sanitizedCacheKey(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return raw.uppercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.map(String.init).joined()
    }
    
    private init() {}
    
    // MARK: - 网页版直达 URL 与浏览器跳转
    
    public func makeWebURL(geneID: String? = nil) -> URL {
        if let gid = geneID?.trimmingCharacters(in: .whitespacesAndNewlines), !gid.isEmpty,
           let direct = URL(string: "\(Self.geneDetailsBaseURLString)?geneId=\(gid)") {
            return direct
        }
        return URL(string: Self.geneSearchURLString) ?? URL(string: Self.baseURLString)!
    }
    
    public func makeCloneWebURL(cloneID: String) -> URL {
        let clean = cloneID.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: "\(Self.cloneDetailsBaseURLString)?cloneId=\(clean)") ?? makeWebURL()
    }
    
    @MainActor
    public func openInDefaultBrowser(geneID: String? = nil) {
        NSWorkspace.shared.open(makeWebURL(geneID: geneID))
    }
    
    @MainActor
    public func openCloneInDefaultBrowser(cloneID: String) {
        NSWorkspace.shared.open(makeCloneWebURL(cloneID: cloneID))
    }
    
    // MARK: - 核心检索入口
    
    public func queryTargets(
        gene: String,
        species: TargetSpecies,
        forceRefresh: Bool = false
    ) async throws -> BroadGPPFetchResult {
        let clean = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw NSError(domain: "BroadGPPService", code: 400, userInfo: [
                NSLocalizedDescriptionKey: L10n.t("请输入有效的基因名或 NCBI Gene / RefSeq ID（如 TP53、Trp53、7157）。")
            ])
        }
        
        let cacheURL = Self.compareCacheDirectory?.appendingPathComponent("broad_gpp_\(Self.sanitizedCacheKey(clean))_\(species.rawValue).json")
        if !forceRefresh, let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(BroadGPPFetchResult.self, from: data),
           !cached.targets.isEmpty {
            return cached
        }
        
        let resolved = try await resolveGeneInfo(query: clean, species: species)
        
        var targets = try await fetchShRNAClonesCSV(geneID: resolved.geneID, grid: 1, isNearMatch: false)
        var usedNearFallback = false
        if targets.isEmpty {
            targets = try await fetchShRNAClonesCSV(geneID: resolved.geneID, grid: 2, isNearMatch: true)
            usedNearFallback = !targets.isEmpty
        }
        
        guard !targets.isEmpty else {
            throw NSError(domain: "BroadGPPService", code: 404, userInfo: [
                NSLocalizedDescriptionKey: L10n.tr("Broad GPP 数据库中「\(resolved.symbol) (\(resolved.geneID))」暂无公开 TRC shRNA 克隆记录。", "No public TRC shRNA clones for \(resolved.symbol) (\(resolved.geneID)) in Broad GPP.")
            ])
        }
        
        let result = BroadGPPFetchResult(
            geneID: resolved.geneID,
            geneSymbol: resolved.symbol,
            geneDescription: resolved.description,
            wtTranscriptCount: resolved.transcriptCount,
            targets: targets,
            isNearMatchFallback: usedNearFallback
        )
        
        if let cacheURL, let encoded = try? JSONEncoder().encode(result) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        return result
    }
    
    // MARK: - 基因解析 & CSV 拉取
    
    private func resolveGeneInfo(query clean: String, species: TargetSpecies) async throws -> ResolvedGeneInfo {
        let upper = clean.uppercased()
        let isNumericID = clean.allSatisfy(\.isNumber)
        let isRefSeqID = upper.hasPrefix("NM_") || upper.hasPrefix("XM_") || upper.hasPrefix("NR_") || upper.hasPrefix("XR_")
        
        if isNumericID || isRefSeqID {
            let csv = try await postGeneSearchCSV(taxonID: species.ncbiTaxonId, geneIDs: clean, geneSymbols: "")
            if let parsed = Self.parseGeneSearchCSV(csv) {
                return parsed
            }
        } else {
            var candidates: [String] = []
            let primaryCase: String = (species == .human)
                ? clean.uppercased()
                : (clean.prefix(1).uppercased() + clean.dropFirst().lowercased())
            
            for cand in [clean, primaryCase, clean.uppercased()] where !cand.isEmpty {
                if !candidates.contains(cand) { candidates.append(cand) }
            }
            if species == .mouse && upper == "TP53" && !candidates.contains("Trp53") {
                candidates.append("Trp53")
            } else if species == .human && upper == "TRP53" && !candidates.contains("TP53") {
                candidates.append("TP53")
            }
            
            let csv = try await postGeneSearchCSV(
                taxonID: species.ncbiTaxonId,
                geneIDs: "",
                geneSymbols: candidates.joined(separator: "\n")
            )
            if let parsed = Self.parseGeneSearchCSV(csv) {
                return parsed
            }
            
            if let entrezID = try await lookupEntrezGeneIDViaMyGene(query: clean, species: species) {
                let fallbackCSV = try await postGeneSearchCSV(taxonID: species.ncbiTaxonId, geneIDs: entrezID, geneSymbols: "")
                if let parsed = Self.parseGeneSearchCSV(fallbackCSV) {
                    return parsed
                }
            }
        }
        
        throw NSError(domain: "BroadGPPService", code: 404, userInfo: [
            NSLocalizedDescriptionKey: L10n.tr("在 Broad GPP (\(species.shortName)) 中未找到基因「\(clean)」，请核对官方基因符号（人源通常大写、鼠源首字母大写）或直接使用 NCBI Gene ID。", "Gene \"\(clean)\" not found in Broad GPP (\(species.shortName)); verify official gene symbol or use NCBI Gene ID.")
        ])
    }
    
    private func postGeneSearchCSV(taxonID: String, geneIDs: String, geneSymbols: String) async throws -> String {
        guard let url = URL(string: Self.geneSearchURLString) else { return "" }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Labworker/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        
        let fields: [(String, String)] = [
            ("gene_taxon", taxonID),
            ("gene_ids", geneIDs),
            ("gene_symbols", geneSymbols),
            ("view", "csv"),
            ("grid", "1")
        ]
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "BroadGPPService", code: code, userInfo: [
                NSLocalizedDescriptionKey: L10n.tr("Broad GPP 基因检索请求失败 (HTTP \(code))", "Broad GPP gene search failed (HTTP \(code))")
            ])
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
    
    private func fetchShRNAClonesCSV(geneID: String, grid: Int, isNearMatch: Bool) async throws -> [BroadGPPShRNATarget] {
        var comps = URLComponents(string: Self.geneDetailsBaseURLString)!
        comps.queryItems = [
            URLQueryItem(name: "grid", value: "\(grid)"),
            URLQueryItem(name: "geneId", value: geneID),
            URLQueryItem(name: "view", value: "csv")
        ]
        guard let url = comps.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("Labworker/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "BroadGPPService", code: code, userInfo: [
                NSLocalizedDescriptionKey: L10n.tr("Broad GPP 克隆列表获取失败 (HTTP \(code))", "Broad GPP clone fetch failed (HTTP \(code))")
            ])
        }
        let csv = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return Self.parseShRNAClonesCSV(csv, isNearMatch: isNearMatch)
    }
    
    private func lookupEntrezGeneIDViaMyGene(query: String, species: TargetSpecies) async throws -> String? {
        var comps = URLComponents(string: "https://mygene.info/v3/query")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "species", value: species.rawValue),
            URLQueryItem(name: "fields", value: "entrezgene,symbol,alias"),
            URLQueryItem(name: "size", value: "15")
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(MyGeneQueryResponse.self, from: data),
              let hits = decoded.hits else {
            return nil
        }
        
        let qUpper = query.uppercased()
        // 1. 优先精确命中官方 symbol
        for hit in hits {
            if let gid = hit.entrezgene?.value, !gid.isEmpty,
               hit.symbol?.uppercased() == qUpper {
                return gid
            }
        }
        // 2. 其次精确命中 alias 数组中的别名（如 p53 -> TP53 [7157]）
        for hit in hits {
            if let gid = hit.entrezgene?.value, !gid.isEmpty,
               let aliases = hit.alias?.values,
               aliases.contains(where: { $0.uppercased() == qUpper }) {
                return gid
            }
        }
        // 3. 兜底取第一条拥有有效 entrezgene 的结果
        return hits.first(where: { !($0.entrezgene?.value ?? "").isEmpty })?.entrezgene?.value
    }
    
    // MARK: - RFC-4180 CSV 解析（支持带引号逗号、跨行与双引号转义）
    
    public static func parseCSV(_ text: String) -> [[String]] {
        let cleanText = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        
        let chars = Array(cleanText)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    currentRow.append(currentField)
                    currentField = ""
                } else if ch == "\r" {
                    if i + 1 < chars.count && chars[i + 1] == "\n" {
                        i += 1
                    }
                    currentRow.append(currentField)
                    if !(currentRow.count == 1 && currentRow[0].isEmpty) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                    currentField = ""
                } else if ch == "\n" {
                    currentRow.append(currentField)
                    if !(currentRow.count == 1 && currentRow[0].isEmpty) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                    currentField = ""
                } else {
                    currentField.append(ch)
                }
            }
            i += 1
        }
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            if !(currentRow.count == 1 && currentRow[0].isEmpty) {
                rows.append(currentRow)
            }
        }
        return rows
    }
    
    public static func parseGeneSearchCSV(_ csv: String) -> ResolvedGeneInfo? {
        let lowerHead = csv.prefix(200).lowercased()
        if lowerHead.contains("<!doctype") || lowerHead.contains("<html") {
            return nil
        }
        let rows = parseCSV(csv)
        guard rows.count >= 2 else { return nil }
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let geneIDIdx = header.firstIndex(of: "gene id") else { return nil }
        let symbolIdx = header.firstIndex(of: "gene symbol")
        let currentIdx = header.firstIndex(of: "current?")
        let descIdx = header.firstIndex(of: "gene description")
        let transIdx = header.firstIndex(of: "current wt transcripts")
        
        var best: ResolvedGeneInfo? = nil
        for row in rows.dropFirst() {
            guard geneIDIdx < row.count else { continue }
            let gid = row[geneIDIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !gid.isEmpty else { continue }
            let sym = (symbolIdx != nil && symbolIdx! < row.count)
                ? row[symbolIdx!].trimmingCharacters(in: .whitespacesAndNewlines)
                : gid
            let desc = (descIdx != nil && descIdx! < row.count)
                ? row[descIdx!].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let transRaw = (transIdx != nil && transIdx! < row.count) ? row[transIdx!] : ""
            let transCount = transRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.count
            let isCurrent = (currentIdx != nil && currentIdx! < row.count)
                ? row[currentIdx!].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "Y"
                : true
            let candidate = ResolvedGeneInfo(geneID: gid, symbol: sym, description: desc, transcriptCount: transCount)
            if isCurrent {
                return candidate
            }
            if best == nil {
                best = candidate
            }
        }
        return best
    }
    
    private struct MergedCloneAccumulator {
        var primaryCloneID: String
        var allCloneIDs: [String]
        var legacyCloneName: String
        var targetSequence: String
        var vectors: [String]
        var matchingTranscripts: [String]
        var matchRegionsList: [String]
        var matchPercent: Int
        var sdrMatchPercent: Int
        var intrinsicScore: Double?
        var adjustedScore: Double?
        var matchesOtherGene: Bool
        var origTargetGeneSymbol: String
        var forwardOligo: String
        var reverseOligo: String
        var addgeneID: String?
    }
    
    public static func parseShRNAClonesCSV(_ csv: String, isNearMatch: Bool = false) -> [BroadGPPShRNATarget] {
        let lowerHead = csv.prefix(200).lowercased()
        if lowerHead.contains("<!doctype") || lowerHead.contains("<html") {
            return []
        }
        let rows = parseCSV(csv)
        guard rows.count >= 2 else { return [] }
        
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let cloneIdx = header.firstIndex(of: "clone id"),
              let seqIdx = header.firstIndex(of: "target seq") else {
            return []
        }
        
        let legacyIdx = header.firstIndex(of: "legacy clone name")
        let vectorIdx = header.firstIndex(of: "vector")
        let transcriptsIdx = header.firstIndex(of: "matching transcripts for gene") ?? header.firstIndex(of: "transcript")
        let regionIdx = header.firstIndex(of: "match regions") ?? header.firstIndex(of: "match region")
        let matchPctIdx = header.firstIndex(of: "match %")
        let sdrIdx = header.firstIndex(of: "sdr match %")
        let intrIdx = header.firstIndex(of: "intrinsic score")
        let adjIdx = header.firstIndex(of: "adjusted score")
        let otherGeneIdx = header.firstIndex(where: { $0.hasPrefix("matches other gene") })
        let origSymIdx = header.firstIndex(of: "orig. target gene symbol")
        let fwdIdx = header.firstIndex(of: "forward oligo sequence")
        let revIdx = header.firstIndex(of: "reverse oligo sequence")
        let addgeneIdx = header.firstIndex(of: "addgene")
        
        func cell(_ row: [String], _ idx: Int?) -> String {
            guard let idx, idx < row.count else { return "" }
            return row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        var bySeq: [String: MergedCloneAccumulator] = [:]
        var insertionOrder: [String] = []
        
        for row in rows.dropFirst() {
            let cloneID = cell(row, cloneIdx)
            let rawSeq = cell(row, seqIdx)
            let cleanSeq = BioSequence.clean(rawSeq).uppercased()
            guard !cloneID.isEmpty, cleanSeq.count >= 18 else { continue }
            
            let legacy = cell(row, legacyIdx)
            let vecRaw = cell(row, vectorIdx)
            let vec = vecRaw.isEmpty ? "pLKO.1" : vecRaw
            let transList = cell(row, transcriptsIdx)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let regParts = cell(row, regionIdx)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let matchPct = Int(Double(cell(row, matchPctIdx)) ?? 100)
            let sdrPct = Int(Double(cell(row, sdrIdx)) ?? 100)
            let intr = Double(cell(row, intrIdx))
            let adj = Double(cell(row, adjIdx))
            let otherGene = cell(row, otherGeneIdx).uppercased().hasPrefix("Y")
            let origSym = cell(row, origSymIdx)
            let fwd = BioSequence.clean(cell(row, fwdIdx)).uppercased()
            let rev = BioSequence.clean(cell(row, revIdx)).uppercased()
            let addgeneRaw = cell(row, addgeneIdx)
            let addgene: String? = (addgeneRaw.isEmpty || addgeneRaw.lowercased() == "n/a") ? nil : addgeneRaw
            
            if var acc = bySeq[cleanSeq] {
                if !acc.allCloneIDs.contains(cloneID) {
                    acc.allCloneIDs.append(cloneID)
                }
                if !acc.vectors.contains(vec) {
                    acc.vectors.append(vec)
                }
                for t in transList where !acc.matchingTranscripts.contains(t) {
                    acc.matchingTranscripts.append(t)
                }
                for r in regParts where !acc.matchRegionsList.contains(r) {
                    acc.matchRegionsList.append(r)
                }
                let currentAdj = acc.adjustedScore ?? -1
                let newAdj = adj ?? -1
                let preferNewPrimary = (vec == "pLKO.1" && !acc.vectors.first.map({ $0 == "pLKO.1" }).valueOrFalse)
                    || (newAdj > currentAdj)
                if preferNewPrimary {
                    acc.primaryCloneID = cloneID
                    if !legacy.isEmpty { acc.legacyCloneName = legacy }
                }
                if let adj {
                    acc.adjustedScore = max(acc.adjustedScore ?? adj, adj)
                }
                if let intr {
                    acc.intrinsicScore = max(acc.intrinsicScore ?? intr, intr)
                }
                acc.matchPercent = max(acc.matchPercent, matchPct)
                acc.sdrMatchPercent = max(acc.sdrMatchPercent, sdrPct)
                acc.matchesOtherGene = acc.matchesOtherGene || otherGene
                if acc.origTargetGeneSymbol.isEmpty { acc.origTargetGeneSymbol = origSym }
                if acc.forwardOligo.isEmpty { acc.forwardOligo = fwd }
                if acc.reverseOligo.isEmpty { acc.reverseOligo = rev }
                if acc.addgeneID == nil { acc.addgeneID = addgene }
                bySeq[cleanSeq] = acc
            } else {
                insertionOrder.append(cleanSeq)
                bySeq[cleanSeq] = MergedCloneAccumulator(
                    primaryCloneID: cloneID,
                    allCloneIDs: [cloneID],
                    legacyCloneName: legacy,
                    targetSequence: cleanSeq,
                    vectors: [vec],
                    matchingTranscripts: transList,
                    matchRegionsList: regParts.isEmpty ? ["CDS"] : regParts,
                    matchPercent: matchPct,
                    sdrMatchPercent: sdrPct,
                    intrinsicScore: intr,
                    adjustedScore: adj,
                    matchesOtherGene: otherGene,
                    origTargetGeneSymbol: origSym,
                    forwardOligo: fwd,
                    reverseOligo: rev,
                    addgeneID: addgene
                )
            }
        }
        
        let built = insertionOrder.compactMap { key -> BroadGPPShRNATarget? in
            guard let acc = bySeq[key] else { return nil }
            let regionsJoined = acc.matchRegionsList.joined(separator: ", ")
            return BroadGPPShRNATarget(
                rank: 1,
                primaryCloneID: acc.primaryCloneID,
                allCloneIDs: acc.allCloneIDs,
                legacyCloneName: acc.legacyCloneName,
                targetSequence: acc.targetSequence,
                vectors: acc.vectors,
                matchingTranscripts: acc.matchingTranscripts,
                matchRegions: regionsJoined,
                matchPercent: acc.matchPercent,
                sdrMatchPercent: acc.sdrMatchPercent,
                intrinsicScore: acc.intrinsicScore,
                adjustedScore: acc.adjustedScore,
                matchesOtherGene: acc.matchesOtherGene,
                origTargetGeneSymbol: acc.origTargetGeneSymbol,
                forwardOligo: acc.forwardOligo,
                reverseOligo: acc.reverseOligo,
                addgeneID: acc.addgeneID,
                isNearMatch: isNearMatch
            )
        }
        
        let sorted = built.sorted { a, b in
            if a.matchesOtherGene != b.matchesOtherGene {
                return !a.matchesOtherGene && b.matchesOtherGene
            }
            let adjA = a.adjustedScore ?? -1
            let adjB = b.adjustedScore ?? -1
            if adjA != adjB { return adjA > adjB }
            let intrA = a.intrinsicScore ?? -1
            let intrB = b.intrinsicScore ?? -1
            if intrA != intrB { return intrA > intrB }
            return a.combinedScore.score > b.combinedScore.score
        }
        
        return sorted.enumerated().map { idx, item in
            item.rankedCopy(rank: idx + 1)
        }
    }
}

private extension Optional where Wrapped == Bool {
    var valueOrFalse: Bool {
        self ?? false
    }
}
