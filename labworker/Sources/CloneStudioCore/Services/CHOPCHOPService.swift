import Foundation
import AppKit

/// CHOPCHOP 检索结果（附带服务端 jobId 以便网页版直达结果页）
public struct CHOPCHOPFetchResult: Sendable {
    public let targets: [CHOPCHOPTarget]
    public let jobId: String?
    public let cached: Bool
    
    public init(targets: [CHOPCHOPTarget], jobId: String?, cached: Bool) {
        self.targets = targets
        self.jobId = jobId
        self.cached = cached
    }
}

/// UCSC CRISPOR 预计算轨道检索结果
public struct UCSCCrisporFetchResult: Sendable {
    public let targets: [CHOPCHOPTarget]
    public let genomicSpan: String?
    public let transcriptID: String?
    
    public init(targets: [CHOPCHOPTarget], genomicSpan: String?, transcriptID: String?) {
        self.targets = targets
        self.genomicSpan = genomicSpan
        self.transcriptID = transcriptID
    }
}

/// 在线靶点预测与全基因组脱靶协同服务（支持 CHOPCHOP + VBC-Score + UCSC CRISPOR 三源并发查询）
public final class CHOPCHOPService: @unchecked Sendable {
    public static let shared = CHOPCHOPService()
    
    public static let baseURLString = "https://chopchop.cbu.uib.no/"
    public static let vbcBaseURLString = "https://www.vbc-score.org/"
    public static let crisporBaseURLString = "https://crispor.gi.ucsc.edu/crispor.py"
    
    private let cacheLock = NSLock()
    private var vbcGeneIndexCache: [String: [VBCGeneIndexEntry]] = [:]
    
    private struct VBCGeneIndexEntry: Codable {
        let gene: String?
        let aliasGenes: String?
    }
    
    private struct VBCEntryDTO: Codable {
        let sgRNA: String?
        let position: String?
        let exon: String?
        let autoPick: Int?
        let vbcScore: Double?
        let activity: Double?
        let frameshift: Double?
        let bioscore: Double?
        let OT90: Int?
        let veryLikely: Int?
        let likely: Int?
        let perfectMatch: Int?
    }
    
    private struct CachedUCSCPayload: Codable {
        let targets: [CHOPCHOPTarget]
        let genomicSpan: String?
        let transcriptID: String?
    }
    
    /// 寻找 Python 爬取与查询脚本
    private func locateScript() -> String? {
        CloneStudioResourceLocator.path(forResource: "chopchop_query", ofType: "py")
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
    
    /// 构建 CHOPCHOP 访问 URL（若有有效 jobId 则直达对应结果页）
    public func makeWebURL(gene: String, species: TargetSpecies, jobId: String? = nil) -> URL {
        if let jid = jobId?.trimmingCharacters(in: .whitespacesAndNewlines), !jid.isEmpty,
           let direct = URL(string: "\(Self.baseURLString)results/\(jid)") {
            return direct
        }
        let cleanGene = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: Self.baseURLString)!
        if !cleanGene.isEmpty {
            components.fragment = "target=\(cleanGene)&organism=\(species.chopchopGenome)"
        }
        return components.url ?? URL(string: Self.baseURLString)!
    }
    
    /// 构建 VBC-Score 网页版入口 URL
    public func makeVBCWebURL() -> URL {
        URL(string: Self.vbcBaseURLString)!
    }
    
    /// 构建 CRISPOR (UCSC) 网页版直达 URL
    public func makeCRISPORWebURL(species: TargetSpecies, genomicSpan: String? = nil) -> URL {
        var components = URLComponents(string: Self.crisporBaseURLString)!
        var items = [URLQueryItem(name: "org", value: species.ucscGenome)]
        if let span = genomicSpan?.trimmingCharacters(in: .whitespacesAndNewlines), !span.isEmpty {
            items.append(URLQueryItem(name: "pos", value: span))
        }
        components.queryItems = items
        return components.url ?? URL(string: Self.crisporBaseURLString)!
    }
    
    /// 在默认外部浏览器中打开 CHOPCHOP（向后兼容旧签名）
    public func openInDefaultBrowser(gene: String, species: TargetSpecies) {
        let url = makeWebURL(gene: gene, species: species, jobId: nil)
        NSWorkspace.shared.open(url)
    }
    
    /// 按指定数据源在默认浏览器中打开对应官网/结果页
    public func openInDefaultBrowser(
        source: TargetCompareSource,
        gene: String,
        species: TargetSpecies,
        chopchopJobId: String? = nil,
        ucscSpan: String? = nil
    ) {
        let url: URL
        switch source {
        case .vbcScore:
            url = makeVBCWebURL()
        case .ucscCrispor:
            url = makeCRISPORWebURL(species: species, genomicSpan: ucscSpan)
        case .chopchop:
            url = makeWebURL(gene: gene, species: species, jobId: chopchopJobId)
        }
        NSWorkspace.shared.open(url)
    }
    
    /// 通过 Python 后台异步查询 CHOPCHOP 全基因组预测靶点与脱靶数据（向后兼容接口）
    public func queryTargets(
        gene: String,
        species: TargetSpecies,
        timeout: Int = 75,
        forceRefresh: Bool = false,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> [CHOPCHOPTarget] {
        let result = try await queryCHOPCHOPWithMetadata(
            gene: gene,
            species: species,
            timeout: timeout,
            forceRefresh: forceRefresh,
            progressHandler: progressHandler
        )
        return result.targets
    }
    
    /// 通过 Python 后台异步查询 CHOPCHOP（返回靶点列表与服务端 jobId）
    public func queryCHOPCHOPWithMetadata(
        gene: String,
        species: TargetSpecies,
        timeout: Int = 75,
        forceRefresh: Bool = false,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> CHOPCHOPFetchResult {
        let cleanGene = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGene.isEmpty else {
            throw NSError(domain: "CHOPCHOP", code: -1, userInfo: [NSLocalizedDescriptionKey: "目标基因名称不能为空"])
        }
        
        guard let scriptPath = locateScript() else {
            throw NSError(domain: "CHOPCHOP", code: -2, userInfo: [NSLocalizedDescriptionKey: "未找到后台执行脚本 chopchop_query.py"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                var args = [
                    scriptPath,
                    "--gene", cleanGene,
                    "--genome", species.chopchopGenome,
                    "--timeout", "\(timeout)"
                ]
                if forceRefresh {
                    args.append("--force-refresh")
                }
                process.arguments = args
                
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                
                // 实时监听 stderr 进度输出
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    for line in text.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("PROGRESS:") {
                            let msg = trimmed.replacingOccurrences(of: "PROGRESS:", with: "").trimmingCharacters(in: .whitespaces)
                            DispatchQueue.main.async {
                                progressHandler?(msg)
                            }
                        }
                    }
                }
                
                do {
                    try process.run()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    
                    guard process.terminationStatus == 0 else {
                        continuation.resume(throwing: NSError(domain: "CHOPCHOP", code: -3, userInfo: [NSLocalizedDescriptionKey: "Python 查询进程异常退出 (code: \(process.terminationStatus))"]))
                        return
                    }
                    
                    let decoder = JSONDecoder()
                    let resp = try decoder.decode(CHOPCHOPQueryResponse.self, from: outData)
                    
                    if resp.status == "success" {
                        let list = resp.targets ?? []
                        continuation.resume(returning: CHOPCHOPFetchResult(
                            targets: list,
                            jobId: resp.jobId,
                            cached: resp.cached ?? false
                        ))
                    } else {
                        let err = resp.message ?? "CHOPCHOP 查询未知错误"
                        continuation.resume(throwing: NSError(domain: "CHOPCHOP", code: -4, userInfo: [NSLocalizedDescriptionKey: err]))
                    }
                } catch {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - VBC-Score 原生高速 REST API 客户端 (https://www.vbc-score.org)
    
    public func queryVBCScoreTargets(
        gene: String,
        species: TargetSpecies,
        forceRefresh: Bool = false
    ) async throws -> [CHOPCHOPTarget] {
        let clean = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw NSError(domain: "VBCScore", code: -1, userInfo: [NSLocalizedDescriptionKey: "目标基因名称不能为空"])
        }
        
        let vbcSpecies = species.vbcGenome
        let cacheURL = Self.compareCacheDirectory?.appendingPathComponent("vbc_\(Self.sanitizedCacheKey(clean))_\(vbcSpecies).json")
        if !forceRefresh, let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([CHOPCHOPTarget].self, from: data),
           !cached.isEmpty {
            return cached
        }
        
        var candidates: [String] = []
        let primaryVariant: String = {
            if species == .human {
                return clean.uppercased()
            } else {
                return clean.prefix(1).uppercased() + clean.dropFirst().lowercased()
            }
        }()
        for sym in [primaryVariant, clean, clean.uppercased()] where !sym.isEmpty {
            if !candidates.contains(sym) {
                candidates.append(sym)
            }
        }
        
        var entries = try await postVBCEntries(species: vbcSpecies, genes: candidates)
        if entries.isEmpty {
            if let resolved = try await resolveVBCGeneSymbol(query: clean, species: vbcSpecies) {
                entries = try await postVBCEntries(species: vbcSpecies, genes: [resolved])
            }
        }
        
        var bySpacer: [String: CHOPCHOPTarget] = [:]
        for dto in entries {
            let fullSeq = (dto.sgRNA ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard fullSeq.count >= 23 else { continue }
            let spacer = String(fullSeq.prefix(20))
            let pam = String(fullSeq.dropFirst(20).prefix(3))
            let parsedPos = Self.parseVBCPosition(dto.position)
            let exonClean = dto.exon?.trimmingCharacters(in: .whitespacesAndNewlines)
            let eff = (dto.activity ?? dto.vbcScore ?? 0.0) * 100.0
            let mm0 = max(0, (dto.perfectMatch ?? 1) - 1)
            
            let target = CHOPCHOPTarget(
                rank: 1,
                targetSequence: String(fullSeq.prefix(23)),
                spacer: spacer,
                pam: pam,
                genomicLocation: parsedPos.location,
                strand: parsedPos.strand,
                gcContent: BioSequence.gcContent(spacer),
                selfComplementarity: 0,
                mm0: mm0,
                mm1: 0,
                mm2: 0,
                mm3: 0,
                efficiency: eff,
                sources: [.vbcScore],
                chopchopRank: nil,
                hasCHOPCHOPOffTargets: false,
                vbcScore: dto.vbcScore,
                vbcActivity: dto.activity,
                vbcFrameshift: dto.frameshift,
                vbcBioscore: dto.bioscore,
                vbcAutoPick: dto.autoPick,
                vbcVeryLikelyOT: dto.veryLikely,
                vbcLikelyOT: dto.likely,
                vbcOT90: dto.OT90,
                vbcExon: (exonClean?.isEmpty == false) ? exonClean : nil
            )
            if let existing = bySpacer[spacer] {
                if (target.vbcScore ?? 0) > (existing.vbcScore ?? 0) {
                    bySpacer[spacer] = target
                }
            } else {
                bySpacer[spacer] = target
            }
        }
        
        let sorted = bySpacer.values.sorted { a, b in
            let sA = a.vbcScore ?? 0
            let sB = b.vbcScore ?? 0
            if sA != sB { return sA > sB }
            return a.efficiency > b.efficiency
        }
        let ranked = sorted.enumerated().map { idx, item in
            CHOPCHOPTarget(
                rank: idx + 1,
                targetSequence: item.targetSequence,
                spacer: item.spacer,
                pam: item.pam,
                genomicLocation: item.genomicLocation,
                strand: item.strand,
                gcContent: item.gcContent,
                selfComplementarity: 0,
                mm0: item.mm0,
                mm1: 0,
                mm2: 0,
                mm3: 0,
                efficiency: item.efficiency,
                sources: [.vbcScore],
                chopchopRank: nil,
                hasCHOPCHOPOffTargets: false,
                vbcScore: item.vbcScore,
                vbcActivity: item.vbcActivity,
                vbcFrameshift: item.vbcFrameshift,
                vbcBioscore: item.vbcBioscore,
                vbcAutoPick: item.vbcAutoPick,
                vbcVeryLikelyOT: item.vbcVeryLikelyOT,
                vbcLikelyOT: item.vbcLikelyOT,
                vbcOT90: item.vbcOT90,
                vbcExon: item.vbcExon
            )
        }
        
        if let cacheURL, !ranked.isEmpty, let encoded = try? JSONEncoder().encode(ranked) {
            try? encoded.write(to: cacheURL, options: .atomic)
        }
        return ranked
    }
    
    private func postVBCEntries(species: String, genes: [String]) async throws -> [VBCEntryDTO] {
        guard let url = URL(string: "https://www.vbc-score.org/api/entries") else {
            return []
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let bodyObj: [String: Any] = ["species": species, "genes": genes]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyObj)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "VBCScore", code: code, userInfo: [NSLocalizedDescriptionKey: "VBC-Score 服务返回 HTTP \(code)"])
        }
        return try JSONDecoder().decode([VBCEntryDTO].self, from: data)
    }
    
    private func resolveVBCGeneSymbol(query: String, species: String) async throws -> String? {
        let lower = query.lowercased()
        let cachedList: [VBCGeneIndexEntry]? = cacheLock.withLock {
            vbcGeneIndexCache[species]
        }
        let list: [VBCGeneIndexEntry]
        if let cachedList {
            list = cachedList
        } else {
            guard let url = URL(string: "https://www.vbc-score.org/api/genes/\(species)") else {
                return nil
            }
            let request = URLRequest(url: url, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode([VBCGeneIndexEntry].self, from: data)
            cacheLock.withLock {
                vbcGeneIndexCache[species] = decoded
            }
            list = decoded
        }
        
        if let exact = list.first(where: { ($0.gene ?? "").lowercased() == lower })?.gene {
            return exact
        }
        for entry in list {
            guard let aliases = entry.aliasGenes, !aliases.isEmpty, let canonical = entry.gene else { continue }
            let tokens = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if tokens.contains(lower) {
                return canonical
            }
        }
        return nil
    }
    
    private static func parseVBCPosition(_ raw: String?) -> (location: String, strand: String) {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return ("", "+")
        }
        var strand = "+"
        var body = text
        if body.hasSuffix("(-)") {
            strand = "-"
            body = String(body.dropLast(3))
        } else if body.hasSuffix("(+)") {
            strand = "+"
            body = String(body.dropLast(3))
        }
        if let colonIdx = body.firstIndex(of: ":"),
           let dashIdx = body[colonIdx...].firstIndex(of: "-") {
            return (String(body[..<dashIdx]), strand)
        }
        return (body, strand)
    }
    
    // MARK: - UCSC Genome Browser CRISPOR 预计算轨道客户端 (https://api.genome.ucsc.edu)
    
    public func queryUCSCCrisporTargets(
        gene: String,
        species: TargetSpecies,
        forceRefresh: Bool = false
    ) async throws -> UCSCCrisporFetchResult {
        let clean = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw NSError(domain: "UCSCCRISPOR", code: -1, userInfo: [NSLocalizedDescriptionKey: "目标基因名称不能为空"])
        }
        
        let genome = species.ucscGenome
        let cacheURL = Self.compareCacheDirectory?.appendingPathComponent("ucsc_\(Self.sanitizedCacheKey(clean))_\(genome).json")
        if !forceRefresh, let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedUCSCPayload.self, from: data),
           !cached.targets.isEmpty {
            return UCSCCrisporFetchResult(
                targets: cached.targets,
                genomicSpan: cached.genomicSpan,
                transcriptID: cached.transcriptID
            )
        }
        
        var searchComps = URLComponents(string: "https://api.genome.ucsc.edu/search")!
        searchComps.queryItems = [
            URLQueryItem(name: "search", value: clean),
            URLQueryItem(name: "genome", value: genome)
        ]
        guard let searchURL = searchComps.url else {
            throw NSError(domain: "UCSCCRISPOR", code: -2, userInfo: [NSLocalizedDescriptionKey: "无法构建 UCSC 检索 URL"])
        }
        
        let (searchData, searchResp) = try await URLSession.shared.data(for: URLRequest(url: searchURL, timeoutInterval: 15))
        guard let http = searchResp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (searchResp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "UCSCCRISPOR", code: code, userInfo: [NSLocalizedDescriptionKey: "UCSC Search 服务返回 HTTP \(code)"])
        }
        
        guard let searchObj = try JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let span = Self.pickGeneSpan(from: searchObj, gene: clean),
              let parsedSpan = Self.parseGenomicSpan(span) else {
            throw NSError(domain: "UCSCCRISPOR", code: -3, userInfo: [NSLocalizedDescriptionKey: "未在 UCSC (\(genome)) 中定位到基因「\(clean)」的坐标"])
        }
        
        // 查询 knownGene 解析规范转录本编码外显子区间
        let (exons, txID) = try await fetchUCSCCodingExons(
            genome: genome,
            gene: clean,
            chrom: parsedSpan.chrom,
            start: parsedSpan.start,
            end: parsedSpan.end
        )
        let intervals = exons.isEmpty ? [(parsedSpan.start, min(parsedSpan.end, parsedSpan.start + 10_000))] : exons
        
        // 获取 crisprAllTargets 轨道（超长基因自动合并窗口并发拉取）
        let rawItems = try await fetchUCSCCrisprTrackItems(
            genome: genome,
            chrom: parsedSpan.chrom,
            exons: intervals
        )
        
        var bySpacer: [String: CHOPCHOPTarget] = [:]
        for item in rawItems {
            guard let chromStart = Self.intValue(item["chromStart"]),
                  let chromEnd = Self.intValue(item["chromEnd"]) else {
                continue
            }
            let mid = (chromStart + chromEnd) / 2
            guard intervals.contains(where: { mid >= ($0.0 - 3) && mid <= ($0.1 + 3) }) else {
                continue
            }
            guard let rawGuide = Self.stringValue(item["guideSeq"])?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  rawGuide.count >= 20 else {
                continue
            }
            let spacer = String(rawGuide.prefix(20))
            let pam = (Self.stringValue(item["pam"])?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()).flatMap {
                $0.isEmpty ? nil : String($0.prefix(3))
            } ?? "NGG"
            let strand = Self.stringValue(item["strand"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "+"
            let chrom = Self.stringValue(item["chrom"]) ?? parsedSpan.chrom
            let mitScore = Self.intValue(item["score"])
            let fusiParsed = Self.parseCrisporMetric(value: item["fusi"], percValue: item["fusiPerc"])
            let scanParsed = Self.parseCrisporMetric(value: item["crisprScan"], percValue: item["crisprScanPerc"])
            let oofVal = Self.doubleValue(item["oof"])
            let eff = fusiParsed.perc ?? fusiParsed.raw ?? 50.0
            
            let candidate = CHOPCHOPTarget(
                rank: 1,
                targetSequence: spacer + pam,
                spacer: spacer,
                pam: pam,
                genomicLocation: "\(chrom):\(chromStart)",
                strand: strand,
                gcContent: BioSequence.gcContent(spacer),
                selfComplementarity: 0,
                mm0: 0,
                mm1: 0,
                mm2: 0,
                mm3: 0,
                efficiency: eff,
                sources: [.ucscCrispor],
                chopchopRank: nil,
                hasCHOPCHOPOffTargets: false,
                mitSpecificity: mitScore,
                crisporDoenchPerc: fusiParsed.perc,
                crisporScanScore: scanParsed.perc ?? scanParsed.raw,
                crisporOutOfFrame: oofVal
            )
            if let existing = bySpacer[spacer] {
                let mNew = candidate.mitSpecificity ?? 0
                let mOld = existing.mitSpecificity ?? 0
                if mNew > mOld || (mNew == mOld && (candidate.crisporDoenchPerc ?? 0) > (existing.crisporDoenchPerc ?? 0)) {
                    bySpacer[spacer] = candidate
                }
            } else {
                bySpacer[spacer] = candidate
            }
        }
        
        let sorted = bySpacer.values.sorted { a, b in
            let mA = a.mitSpecificity ?? 0
            let mB = b.mitSpecificity ?? 0
            if mA != mB { return mA > mB }
            return a.efficiency > b.efficiency
        }
        let ranked = sorted.enumerated().map { idx, item in
            CHOPCHOPTarget(
                rank: idx + 1,
                targetSequence: item.targetSequence,
                spacer: item.spacer,
                pam: item.pam,
                genomicLocation: item.genomicLocation,
                strand: item.strand,
                gcContent: item.gcContent,
                selfComplementarity: 0,
                mm0: 0,
                mm1: 0,
                mm2: 0,
                mm3: 0,
                efficiency: item.efficiency,
                sources: [.ucscCrispor],
                chopchopRank: nil,
                hasCHOPCHOPOffTargets: false,
                mitSpecificity: item.mitSpecificity,
                crisporDoenchPerc: item.crisporDoenchPerc,
                crisporScanScore: item.crisporScanScore,
                crisporOutOfFrame: item.crisporOutOfFrame
            )
        }
        
        if let cacheURL, !ranked.isEmpty {
            let payload = CachedUCSCPayload(targets: ranked, genomicSpan: span, transcriptID: txID)
            if let encoded = try? JSONEncoder().encode(payload) {
                try? encoded.write(to: cacheURL, options: .atomic)
            }
        }
        return UCSCCrisporFetchResult(targets: ranked, genomicSpan: span, transcriptID: txID)
    }
    
    private func fetchUCSCCodingExons(
        genome: String,
        gene: String,
        chrom: String,
        start: Int,
        end: Int
    ) async throws -> (exons: [(Int, Int)], transcriptID: String?) {
        guard let url = URL(string: "https://api.genome.ucsc.edu/getData/track?genome=\(genome);track=knownGene;chrom=\(chrom);start=\(start);end=\(end)") else {
            return ([], nil)
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["knownGene"] as? [[String: Any]] else {
            return ([], nil)
        }
        
        let lowerGene = gene.lowercased()
        let matching = rows.filter { row in
            let g1 = Self.stringValue(row["geneName"])?.lowercased() ?? ""
            let g2 = Self.stringValue(row["geneName2"])?.lowercased() ?? ""
            guard g1 == lowerGene || g2 == lowerGene else { return false }
            let ts = Self.intValue(row["thickStart"]) ?? 0
            let te = Self.intValue(row["thickEnd"]) ?? 0
            return te > ts
        }
        
        let candidates = matching.isEmpty ? rows.filter { row in
            let g1 = Self.stringValue(row["geneName"])?.lowercased() ?? ""
            return g1 == lowerGene
        } : matching
        
        var bestTx: [String: Any]?
        var bestScore: Int = -1
        for row in candidates {
            let tag = Self.stringValue(row["tag"]) ?? ""
            let ts = Self.intValue(row["thickStart"]) ?? Self.intValue(row["chromStart"]) ?? 0
            let te = Self.intValue(row["thickEnd"]) ?? Self.intValue(row["chromEnd"]) ?? 0
            let cdsLen = max(0, te - ts)
            var prio = cdsLen
            if tag.contains("MANE_Select") {
                prio += 100_000_000
            } else if tag.contains("Ensembl_canonical") {
                prio += 50_000_000
            }
            if prio > bestScore {
                bestScore = prio
                bestTx = row
            }
        }
        
        guard let picked = bestTx,
              let txStart = Self.intValue(picked["chromStart"]),
              let sizesStr = Self.stringValue(picked["blockSizes"]),
              let startsStr = Self.stringValue(picked["chromStarts"]) else {
            return ([], nil)
        }
        
        let txID = Self.stringValue(picked["name"])
        let thickS = Self.intValue(picked["thickStart"]) ?? txStart
        let thickE = Self.intValue(picked["thickEnd"]) ?? (Self.intValue(picked["chromEnd"]) ?? txStart)
        let useThick = thickE > thickS
        
        let sizes = sizesStr.split(separator: ",").compactMap { Int($0) }
        let starts = startsStr.split(separator: ",").compactMap { Int($0) }
        var rawExons: [(Int, Int)] = []
        for (relStart, size) in zip(starts, sizes) {
            let es = txStart + relStart
            let ee = es + size
            let ces = useThick ? max(es, thickS) : es
            let cee = useThick ? min(ee, thickE) : ee
            if cee > ces {
                rawExons.append((ces, cee))
            }
        }
        return (Self.mergeIntervals(rawExons, maxGap: 0), txID)
    }
    
    private func fetchUCSCCrisprTrackItems(
        genome: String,
        chrom: String,
        exons: [(Int, Int)]
    ) async throws -> [[String: Any]] {
        let sortedExons = Self.mergeIntervals(exons, maxGap: 0)
        guard let minS = sortedExons.first?.0, let maxE = sortedExons.last?.1 else {
            return []
        }
        
        let windows: [(Int, Int)]
        if maxE - minS <= 120_000 {
            windows = [(max(0, minS - 25), maxE + 25)]
        } else {
            let merged = Self.mergeIntervals(sortedExons, maxGap: 4_000)
            windows = Array(merged.prefix(24)).map { (max(0, $0.0 - 25), $0.1 + 25) }
        }
        
        var allItems: [[String: Any]] = []
        let batchSize = 4
        var idx = 0
        while idx < windows.count {
            let endIdx = min(windows.count, idx + batchSize)
            let batch = Array(windows[idx..<endIdx])
            let batchData = try await withThrowingTaskGroup(of: Data?.self) { group in
                for (wStart, wEnd) in batch {
                    group.addTask {
                        guard let url = URL(string: "https://api.genome.ucsc.edu/getData/track?genome=\(genome);track=crisprAllTargets;chrom=\(chrom);start=\(wStart);end=\(wEnd)") else {
                            return nil
                        }
                        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                            return nil
                        }
                        return data
                    }
                }
                var collected: [Data] = []
                for try await part in group {
                    if let d = part {
                        collected.append(d)
                    }
                }
                return collected
            }
            for data in batchData {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let rows = json["crisprAllTargets"] as? [[String: Any]] {
                    allItems.append(contentsOf: rows)
                }
            }
            idx = endIdx
        }
        return allItems
    }
    
    private static func mergeIntervals(_ intervals: [(Int, Int)], maxGap: Int) -> [(Int, Int)] {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var out: [(Int, Int)] = []
        for (s, e) in sorted {
            if let last = out.last, s <= last.1 + maxGap {
                out[out.count - 1] = (last.0, max(last.1, e))
            } else {
                out.append((s, e))
            }
        }
        return out
    }
    
    private static func pickGeneSpan(from searchObj: [String: Any], gene: String) -> String? {
        guard let groups = searchObj["positionMatches"] as? [[String: Any]] else { return nil }
        let upperGene = gene.uppercased()
        let preferredOrder = ["mane", "knownGene", "ncbiRefSeqCurated", "ncbiRefSeq", "hgnc"]
        let sortedGroups = groups.sorted { a, b in
            let na = (a["trackName"] as? String) ?? (a["name"] as? String) ?? ""
            let nb = (b["trackName"] as? String) ?? (b["name"] as? String) ?? ""
            let ia = preferredOrder.firstIndex(of: na) ?? preferredOrder.count
            let ib = preferredOrder.firstIndex(of: nb) ?? preferredOrder.count
            return ia < ib
        }
        
        for grp in sortedGroups {
            guard let matches = grp["matches"] as? [[String: Any]] else { continue }
            for m in matches {
                guard let pos = m["position"] as? String, !pos.isEmpty else { continue }
                let posName = (m["posName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let headToken = posName.split(separator: " ", maxSplits: 1).first.map(String.init) ?? posName
                if headToken.uppercased() == upperGene || posName.uppercased() == upperGene {
                    return pos
                }
            }
        }
        for grp in sortedGroups {
            guard let matches = grp["matches"] as? [[String: Any]] else { continue }
            for m in matches {
                if let pos = m["position"] as? String,
                   let posName = m["posName"] as? String,
                   posName.uppercased().hasPrefix(upperGene) {
                    return pos
                }
            }
        }
        return nil
    }
    
    private static func parseGenomicSpan(_ span: String) -> (chrom: String, start: Int, end: Int)? {
        let parts = span.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let chrom = String(parts[0])
        let coords = parts[1].replacingOccurrences(of: ",", with: "").split(separator: "-", maxSplits: 1)
        guard coords.count == 2, let s = Int(coords[0]), let e = Int(coords[1]), e > s else {
            return nil
        }
        return (chrom, s, e)
    }
    
    private static func parseCrisporMetric(value: Any?, percValue: Any?) -> (perc: Double?, raw: Double?) {
        if let percNum = doubleValue(percValue) {
            return (percNum, parseFirstDouble(value))
        }
        if let str = stringValue(value) {
            let pattern = #"^\s*([0-9]+(?:\.[0-9]+)?)\s*%\s*\(\s*([0-9]+(?:\.[0-9]+)?)\s*\)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)),
               match.numberOfRanges >= 3,
               let r1 = Range(match.range(at: 1), in: str),
               let r2 = Range(match.range(at: 2), in: str) {
                return (Double(str[r1]), Double(str[r2]))
            }
            if let single = parseFirstDouble(str) {
                return (single, single)
            }
        } else if let num = doubleValue(value) {
            return (num, num)
        }
        return (nil, nil)
    }
    
    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }
    
    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
    
    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
    
    private static func parseFirstDouble(_ any: Any?) -> Double? {
        if let d = doubleValue(any) { return d }
        guard let s = stringValue(any) else { return nil }
        let pattern = #"[0-9]+(?:\.[0-9]+)?"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let range = Range(match.range, in: s) {
            return Double(s[range])
        }
        return nil
    }
}
