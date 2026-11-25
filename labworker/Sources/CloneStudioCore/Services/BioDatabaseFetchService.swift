import Foundation

// MARK: - 在线生信数据库直连客户端 (Addgene / NCBI GenBank / RCSB PDB / AlphaFold DB / UniProt)

public enum BioDatabaseFetchService {

    public enum FetchError: LocalizedError, Sendable {
        case invalidIdentifier(String)
        case networkFailure(String)
        case parseFailure(String)

        public var errorDescription: String? {
            switch self {
            case .invalidIdentifier(let msg): return msg
            case .networkFailure(let msg):    return msg
            case .parseFailure(let msg):      return msg
            }
        }
    }

    public struct FetchedPlasmidResult: Sendable {
        public let source: String
        public let identifier: String
        public let dnaInfo: SnapGeneFileInfo
        public let autoAnnotatedCount: Int
    }

    public struct FetchedProteinStructureResult: Sendable {
        public let source: String
        public let identifier: String
        public let format: String // "cif", "pdb", "fasta"
        public let contentText: String
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 35
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Labworker/20261120 (macOS Wet-Lab Workbench)"
        ]
        return URLSession(configuration: cfg)
    }()

    // MARK: - 1. NCBI RefSeq / GenBank Accession 抓取

    public static func fetchNCBIGenBank(accession rawAcc: String) async throws -> FetchedPlasmidResult {
        let cleanedAcc = rawAcc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAcc.isEmpty else {
            throw FetchError.invalidIdentifier("请输入有效的 NCBI GenBank / RefSeq 登录号（如 NM_000546 或 L09137）。")
        }
        guard let encoded = cleanedAcc.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=\(encoded)&rettype=gbwithparts&retmode=text") else {
            throw FetchError.invalidIdentifier("登录号格式无效：\(cleanedAcc)")
        }

        let rawText = try await fetchText(url: url, context: "NCBI E-utilities (\(cleanedAcc))")
        guard var parsed = SequenceFormatEngine.parseGenBank(rawText, fallbackName: cleanedAcc, filePath: "ncbi://\(cleanedAcc)") else {
            throw FetchError.parseFailure("NCBI 返回的内容未能解析为 GenBank 序列，请确认登录号 \(cleanedAcc) 是否存在。")
        }

        var autoCount = 0
        if parsed.features.isEmpty && !parsed.sequence.isEmpty {
            let ann = PlasmidAnnotationEngine.annotate(
                sequence: parsed.sequence,
                plasmidName: cleanedAcc,
                isCircular: parsed.isCircular
            )
            let snapFeats = ann.toSnapGeneFeatures()
            autoCount = snapFeats.count
            parsed = SnapGeneFileInfo(
                filePath: parsed.filePath,
                fileName: parsed.fileName,
                sequence: parsed.sequence,
                length: parsed.length,
                isCircular: parsed.isCircular,
                featuresCount: snapFeats.count,
                features: snapFeats
            )
        }

        return FetchedPlasmidResult(source: "NCBI NuCore", identifier: cleanedAcc, dnaInfo: parsed, autoAnnotatedCount: autoCount)
    }

    // MARK: - 2. Addgene Plasmid ID 抓取

    public static func fetchAddgenePlasmid(id rawID: String) async throws -> FetchedPlasmidResult {
        let digits = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "addgene", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else {
            throw FetchError.invalidIdentifier("请输入纯数字 Addgene 质粒编号（如 52961 或 #52961）。")
        }

        guard let pageURL = URL(string: "https://www.addgene.org/\(digits)/sequences/") else {
            throw FetchError.invalidIdentifier("无效 Addgene 编号：\(digits)")
        }
        let html = try await fetchText(url: pageURL, context: "Addgene #\(digits)")

        // 匹配公开序列文件链接（优先 Full GenBank .gbk，其次 .fasta）
        let gbkLinks = extractLinks(fromHTML: html, pattern: #"https?://media\.addgene\.org/[^"'\s<>]+\.gbk?"#)
        for linkStr in gbkLinks {
            if let gbkURL = URL(string: linkStr),
               let gbkText = try? await fetchText(url: gbkURL, context: "Addgene GenBank"),
               let parsed = SequenceFormatEngine.parseGenBank(gbkText, fallbackName: "Addgene_\(digits)", filePath: "addgene://\(digits)") {
                return FetchedPlasmidResult(source: "Addgene", identifier: "#\(digits)", dnaInfo: parsed, autoAnnotatedCount: 0)
            }
        }

        let fastaLinks = extractLinks(fromHTML: html, pattern: #"https?://media\.addgene\.org/[^"'\s<>]+\.(?:fasta|fa|txt)"#)
        for linkStr in fastaLinks {
            if let faURL = URL(string: linkStr),
               let faText = try? await fetchText(url: faURL, context: "Addgene FASTA") {
                let (parsedName, cleanedSeq) = PlasmidAnnotationEngine.parseFASTA(faText, defaultName: "Addgene_\(digits)")
                if cleanedSeq.count >= 50 {
                    let ann = PlasmidAnnotationEngine.annotate(sequence: cleanedSeq, plasmidName: parsedName, isCircular: true)
                    let snapFeats = ann.toSnapGeneFeatures()
                    let info = SnapGeneFileInfo(
                        filePath: "addgene://\(digits)",
                        fileName: "Addgene_\(digits).gb",
                        sequence: cleanedSeq,
                        length: cleanedSeq.count,
                        isCircular: true,
                        featuresCount: snapFeats.count,
                        features: snapFeats
                    )
                    return FetchedPlasmidResult(source: "Addgene", identifier: "#\(digits)", dnaInfo: info, autoAnnotatedCount: snapFeats.count)
                }
            }
        }

        throw FetchError.parseFailure("在 Addgene #\(digits) 页面未检测到公开的 Full/SnapGene GenBank 或 FASTA 序列资源（可能仅含部分 Sanger 测序读段或无全长序列）。")
    }

    // MARK: - 3. RCSB PDB 结构抓取 (.cif 优先，回退 .pdb)

    public static func fetchRCSBStructure(pdbID rawID: String) async throws -> FetchedProteinStructureResult {
        let pid = rawID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard pid.count == 4, pid.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw FetchError.invalidIdentifier("请输入标准 4 位 RCSB PDB ID（如 1ATP、1UBQ、6LU7）。")
        }
        if let cifURL = URL(string: "https://files.rcsb.org/download/\(pid).cif"),
           let cifText = try? await fetchText(url: cifURL, context: "RCSB mmCIF (\(pid))"),
           ProteinBiophysicsEngine.isMMCIFFormat(cifText) {
            return FetchedProteinStructureResult(source: "RCSB PDB (mmCIF)", identifier: pid, format: "cif", contentText: cifText)
        }
        guard let pdbURL = URL(string: "https://files.rcsb.org/download/\(pid).pdb") else {
            throw FetchError.invalidIdentifier("无效 PDB ID：\(pid)")
        }
        let pdbText = try await fetchText(url: pdbURL, context: "RCSB PDB (\(pid))")
        return FetchedProteinStructureResult(source: "RCSB PDB", identifier: pid, format: "pdb", contentText: pdbText)
    }

    // MARK: - 4. AlphaFold DB / UniProt 抓取

    public static func fetchAlphaFoldOrUniProt(identifier rawID: String) async throws -> FetchedProteinStructureResult {
        var acc = rawID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if acc.hasPrefix("AF-") {
            let parts = acc.split(separator: "-")
            if parts.count >= 2 { acc = String(parts[1]) }
        }
        guard acc.count >= 4, acc.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw FetchError.invalidIdentifier("请输入标准 UniProt 登录号（如 P04637）或 AlphaFold ID（如 AF-P04637-F1）。")
        }

        // 先尝试 AlphaFold EBI API 获取最新 mmCIF 下载链接
        if let apiURL = URL(string: "https://alphafold.ebi.ac.uk/api/prediction/\(acc)"),
           let apiText = try? await fetchText(url: apiURL, context: "AlphaFold DB API"),
           let data = apiText.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = arr.first {
            if let cifStr = first["cifUrl"] as? String, let cifURL = URL(string: cifStr),
               let cifText = try? await fetchText(url: cifURL, context: "AlphaFold mmCIF (\(acc))"),
               ProteinBiophysicsEngine.isMMCIFFormat(cifText) {
                return FetchedProteinStructureResult(source: "AlphaFold DB (mmCIF)", identifier: acc, format: "cif", contentText: cifText)
            }
            if let pdbStr = first["pdbUrl"] as? String, let pdbURL = URL(string: pdbStr),
               let pdbText = try? await fetchText(url: pdbURL, context: "AlphaFold PDB (\(acc))") {
                return FetchedProteinStructureResult(source: "AlphaFold DB (PDB)", identifier: acc, format: "pdb", contentText: pdbText)
            }
        }

        // 回退至 UniProt REST FASTA
        guard let uniURL = URL(string: "https://rest.uniprot.org/uniprotkb/\(acc).fasta") else {
            throw FetchError.invalidIdentifier("无效 UniProt 登录号：\(acc)")
        }
        let fastaText = try await fetchText(url: uniURL, context: "UniProt (\(acc))")
        guard !ProteinBiophysicsEngine.cleanProteinSequence(fastaText).isEmpty else {
            throw FetchError.parseFailure("未在 AlphaFold DB 与 UniProt 找到 \(acc) 的结构或序列数据。")
        }
        return FetchedProteinStructureResult(source: "UniProt FASTA (无 AlphaFold 结构)", identifier: acc, format: "fasta", contentText: fastaText)
    }

    // MARK: - 网络与正则是辅助

    private static func fetchText(url: URL, context: String) async throws -> String {
        do {
            let (data, resp) = try await session.data(from: url)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw FetchError.networkFailure("\(context) 请求失败（HTTP \(http.statusCode)）。")
            }
            if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
            if let ascii = String(data: data, encoding: .ascii) { return ascii }
            throw FetchError.parseFailure("\(context) 响应编码无法读取。")
        } catch let e as FetchError {
            throw e
        } catch {
            throw FetchError.networkFailure("\(context) 网络请求失败：\(error.localizedDescription)")
        }
    }

    private static func extractLinks(fromHTML html: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var out: [String] = []
        for m in matches {
            let s = ns.substring(with: m.range)
            if !seen.contains(s) {
                seen.insert(s)
                out.append(s)
            }
        }
        return out
    }
}
