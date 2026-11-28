import Foundation

// MARK: - 通用生信格式双向引擎：GenBank (.gb/.gbk) / OpenCloning JSON / SBOL3 JSON-LD

public enum SequenceFormatEngine {

    // MARK: - 1. GenBank (.gb / .gbk) 完整双向解析与导出

    public static func parseGenBank(
        _ rawText: String,
        fallbackName: String = "Imported_GenBank",
        filePath: String = "genbank://imported"
    ) -> SnapGeneFileInfo? {
        let text = rawText
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")

        var locusName = fallbackName
        var isCircular = true
        var features: [SnapGeneFeature] = []
        var originChars: [Character] = []

        enum Section { case header, features, origin }
        var section: Section = .header

        struct PendingFeature {
            var type: String
            var rawLocation: String
            var collectingLocation: Bool
            var qualifiers: [String: String] = [:]
            var lastQualKey: String?
        }
        var currentFeature: PendingFeature? = nil

        func flushPendingFeature() {
            guard let pf = currentFeature else { return }
            currentFeature = nil
            let parsed = parseGenBankLocation(pf.rawLocation, featureType: pf.type, qualifiers: pf.qualifiers)
            if !parsed.segments.isEmpty {
                features.append(parsed)
            }
        }

        for rawLine in lines {
            if rawLine.hasPrefix("//") {
                flushPendingFeature()
                break
            }
            if rawLine.hasPrefix("LOCUS") {
                let parts = rawLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if parts.count >= 2 && !parts[1].isEmpty {
                    locusName = parts[1]
                }
                let lower = rawLine.lowercased()
                if lower.contains("linear") && !lower.contains("circular") {
                    isCircular = false
                } else if lower.contains("circular") {
                    isCircular = true
                }
                continue
            }
            if rawLine.hasPrefix("FEATURES") {
                section = .features
                continue
            }
            if rawLine.hasPrefix("ORIGIN") {
                flushPendingFeature()
                section = .origin
                continue
            }

            switch section {
            case .header:
                continue

            case .origin:
                // 保留完整 IUPAC 简并碱基 (ACGTNRYSWKMBDHV)，不再静默剥离 N/R/Y/S/W/K/M 等简并位点
                let iupacValid = Set("ACGTNRYSWKMBDHV")
                for ch in rawLine.uppercased() {
                    if iupacValid.contains(ch) {
                        originChars.append(ch)
                    }
                }

            case .features:
                // GenBank 规范：第 0..20 列包含非空白 Feature Key（前导缩进，非 `/` 开头）
                let chars = Array(rawLine)
                let prefix21 = String(chars.prefix(min(21, chars.count)))
                let trimmedPrefix = prefix21.trimmingCharacters(in: .whitespaces)
                if rawLine.hasPrefix(" ") && !trimmedPrefix.isEmpty && !trimmedPrefix.hasPrefix("/") {
                    flushPendingFeature()
                    let keyPart = trimmedPrefix
                    let locPart = chars.count > 21 ? String(chars[21...]).trimmingCharacters(in: .whitespaces) : ""
                    let openParens = locPart.filter { $0 == "(" }.count
                    let closeParens = locPart.filter { $0 == ")" }.count
                    currentFeature = PendingFeature(
                        type: keyPart.isEmpty ? "misc_feature" : keyPart,
                        rawLocation: locPart,
                        collectingLocation: openParens > closeParens || locPart.hasSuffix(",")
                    )
                    continue
                } else if !rawLine.hasPrefix(" ") && !trimmedPrefix.isEmpty && !trimmedPrefix.hasPrefix("BASE COUNT") {
                    flushPendingFeature()
                    section = .header
                    continue
                }

                guard var pf = currentFeature else { continue }
                let contentTrimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if contentTrimmed.isEmpty { continue }

                if pf.collectingLocation && !contentTrimmed.hasPrefix("/") {
                    pf.rawLocation += contentTrimmed
                    let openP = pf.rawLocation.filter { $0 == "(" }.count
                    let closeP = pf.rawLocation.filter { $0 == ")" }.count
                    pf.collectingLocation = openP > closeP || pf.rawLocation.hasSuffix(",")
                    currentFeature = pf
                } else if contentTrimmed.hasPrefix("/") {
                    pf.collectingLocation = false
                    let body = String(contentTrimmed.dropFirst())
                    if let eqIdx = body.firstIndex(of: "=") {
                        let qKey = String(body[..<eqIdx]).lowercased()
                        var qVal = String(body[body.index(after: eqIdx)...])
                        if qVal.hasPrefix("\"") { qVal.removeFirst() }
                        if qVal.hasSuffix("\"") && !qVal.isEmpty { qVal.removeLast() }
                        pf.qualifiers[qKey] = qVal
                        pf.lastQualKey = qKey
                    } else {
                        let qKey = body.lowercased()
                        pf.qualifiers[qKey] = "true"
                        pf.lastQualKey = qKey
                    }
                    currentFeature = pf
                } else if let lastKey = pf.lastQualKey {
                    var appended = contentTrimmed
                    if appended.hasSuffix("\"") { appended.removeLast() }
                    let oldVal = pf.qualifiers[lastKey] ?? ""
                    pf.qualifiers[lastKey] = oldVal.isEmpty ? appended : "\(oldVal) \(appended)"
                    currentFeature = pf
                }
            }
        }
        flushPendingFeature()

        let seq = String(originChars)
        guard !seq.isEmpty else { return nil }

        let safeName = locusName.trimmingCharacters(in: .whitespacesAndNewlines)
        return SnapGeneFileInfo(
            filePath: filePath,
            fileName: safeName.hasSuffix(".gb") || safeName.hasSuffix(".gbk") ? safeName : "\(safeName).gb",
            sequence: seq,
            length: seq.count,
            isCircular: isCircular,
            featuresCount: features.count,
            features: features,
            primersCount: 0,
            primers: []
        )
    }

    private static func parseGenBankLocation(
        _ rawLocation: String,
        featureType: String,
        qualifiers: [String: String]
    ) -> SnapGeneFeature {
        let cleanLoc = rawLocation.replacingOccurrences(of: " ", with: "")
        let lowerLoc = cleanLoc.lowercased()
        let isRev = lowerLoc.hasPrefix("complement(") || lowerLoc.contains("complement(")
        var segments: [SnapGeneSegment] = []

        // 正确转义 \^（位点间符号如 123^124），提取全部 <start>..<end>、start^end 或单点坐标
        let pattern = #"<?(\d+)(?:(?:\.\.|\^)>?(\d+))?"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = cleanLoc as NSString
            let matches = regex.matches(in: cleanLoc, range: NSRange(location: 0, length: ns.length))
            let color = qualifiers["apeinfo_fwdcolor"] ?? qualifiers["apeinfo_revcolor"] ?? colorForGenBankType(featureType)
            for m in matches {
                guard m.range(at: 1).location != NSNotFound,
                      let s = Int(ns.substring(with: m.range(at: 1))) else { continue }
                let e: Int = {
                    if m.range(at: 2).location != NSNotFound, let val = Int(ns.substring(with: m.range(at: 2))) {
                        return val
                    }
                    return s
                }()
                let lo = min(s, e)
                let hi = max(s, e)
                segments.append(SnapGeneSegment(range: "\(lo)-\(hi)", start: lo, end: hi, color: color))
            }
            // 纯 join(complement(...),complement(...)) 复合段在 GenBank 中按反链 5'→3' 排列，无条件反转为正向坐标序（兼容跨原点特征）
            if lowerLoc.hasPrefix("join(complement(") && segments.count > 1 {
                segments.reverse()
            }
        }

        let name = qualifiers["label"]
            ?? qualifiers["gene"]
            ?? qualifiers["product"]
            ?? qualifiers["standard_name"]
            ?? qualifiers["note"]
            ?? featureType

        return SnapGeneFeature(
            name: String(name.prefix(80)),
            type: featureType,
            directionality: isRev ? "2" : "1",
            segments: segments
        )
    }

    private static func cleanIUPACPreserving(_ raw: String) -> String {
        let allowed = Set("ACGTNRYSWKMBDHV")
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw.uppercased() {
            if ch == "U" { out.append("T") }
            else if allowed.contains(ch) { out.append(ch) }
        }
        return out
    }

    public static func exportGenBank(info: SnapGeneFileInfo, name: String? = nil) -> String {
        let cleanSeq = cleanIUPACPreserving(info.sequence)
        let seqLen = cleanSeq.count
        let rawTitle = (name ?? info.fileName)
            .replacingOccurrences(of: ".dna", with: "")
            .replacingOccurrences(of: ".gbk", with: "")
            .replacingOccurrences(of: ".gb", with: "")
        let locusToken = rawTitle
            .replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted)
            .joined()
        let safeLocus = locusToken.isEmpty ? "Labworker_Construct" : String(locusToken.prefix(24))
        let topology = info.isCircular ? "circular" : "linear"
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "dd-MMM-yyyy"
        let dateStr = df.string(from: Date()).uppercased()

        var lines: [String] = []
        let locusPad = safeLocus.padding(toLength: 16, withPad: " ", startingAt: 0)
        lines.append("LOCUS       \(locusPad) \(String(format: "%7d", seqLen)) bp    DNA     \(topology) SYN \(dateStr)")
        lines.append("DEFINITION  \(rawTitle), exported by Labworker.")
        lines.append("ACCESSION   \(safeLocus)")
        lines.append("SOURCE      synthetic DNA construct")
        lines.append("FEATURES             Location/Qualifiers")

        if info.features.isEmpty && seqLen > 0 {
            lines.append("     source          1..\(seqLen)")
            lines.append("                     /mol_type=\"other DNA\"")
        } else {
            for feat in info.features where !feat.segments.isEmpty {
                let isRev = feat.directionality == "2" || feat.directionality == "-"
                let segStrings = feat.segments.map { "\($0.start)..\($0.end)" }
                let locCore = segStrings.count == 1 ? segStrings[0] : "join(\(segStrings.joined(separator: ",")))"
                let fullLoc = isRev ? "complement(\(locCore))" : locCore
                let fType = sanitizeGBFeatureType(feat.type)
                let keyPad = fType.padding(toLength: 16, withPad: " ", startingAt: 0)
                lines.append("     \(keyPad)\(fullLoc)")
                let safeLabel = feat.name.replacingOccurrences(of: "\"", with: "'")
                lines.append("                     /label=\"\(safeLabel)\"")
                if let col = feat.segments.first?.color, !col.isEmpty {
                    lines.append("                     /ApEinfo_fwdcolor=\"\(col)\"")
                }
            }
        }

        lines.append("ORIGIN")
        let chars = Array(cleanSeq.lowercased())
        var idx = 0
        while idx < chars.count {
            let lineNum = String(format: "%9d", idx + 1)
            var chunks: [String] = []
            for c in stride(from: idx, to: min(chars.count, idx + 60), by: 10) {
                let end = min(chars.count, c + 10)
                chunks.append(String(chars[c..<end]))
            }
            lines.append("\(lineNum) \(chunks.joined(separator: " "))")
            idx += 60
        }
        lines.append("//")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 2. OpenCloning JSON 导入导出

    public static func exportOpenCloningJSON(info: SnapGeneFileInfo, name: String) throws -> String {
        let gbText = exportGenBank(info: info, name: name)
        let seqId = abs(name.hashValue % 900_000) + 1
        let payload: [String: Any] = [
            "description": "Exported by Labworker",
            "sequences": [
                [
                    "id": seqId,
                    "type": "TextFileSequence",
                    "sequence_file_format": "genbank",
                    "overhang_crick_3prime": 0,
                    "overhang_watson_3prime": 0,
                    "file_content": gbText
                ]
            ],
            "sources": [
                [
                    "id": seqId + 1,
                    "type": "ManuallyTypedSource",
                    "input": [],
                    "output": seqId
                ]
            ],
            "primers": info.primers.enumerated().map { idx, p in
                [
                    "id": idx + 1,
                    "name": p.name,
                    "sequence": p.sequence
                ] as [String: Any]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func parseOpenCloningJSON(_ rawText: String, filePath: String = "opencloning://imported") -> [SnapGeneFileInfo] {
        guard let data = rawText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sequences = root["sequences"] as? [[String: Any]] else {
            return []
        }
        var results: [SnapGeneFileInfo] = []
        for (idx, seqObj) in sequences.enumerated() {
            if let fileContent = seqObj["file_content"] as? String {
                let fmt = (seqObj["sequence_file_format"] as? String ?? "genbank").lowercased()
                if fmt == "genbank" || fileContent.contains("LOCUS") {
                    if let parsed = parseGenBank(fileContent, fallbackName: "OpenCloning_Seq_\(idx + 1)", filePath: filePath) {
                        results.append(parsed)
                        continue
                    }
                }
                let cleaned = cleanIUPACPreserving(fileContent)
                if !cleaned.isEmpty {
                    results.append(
                        SnapGeneFileInfo(
                            filePath: filePath,
                            fileName: "OpenCloning_Seq_\(idx + 1).fasta",
                            sequence: cleaned,
                            length: cleaned.count,
                            isCircular: true,
                            featuresCount: 0,
                            features: []
                        )
                    )
                }
            } else if let rawSeq = seqObj["sequence"] as? String {
                let cleaned = cleanIUPACPreserving(rawSeq)
                guard !cleaned.isEmpty else { continue }
                let seqName = (seqObj["name"] as? String) ?? "OpenCloning_Seq_\(idx + 1)"
                results.append(
                    SnapGeneFileInfo(
                        filePath: filePath,
                        fileName: "\(seqName).json",
                        sequence: cleaned,
                        length: cleaned.count,
                        isCircular: (seqObj["circular"] as? Bool) ?? true,
                        featuresCount: 0,
                        features: []
                    )
                )
            }
        }
        return results
    }

    // MARK: - 3. SBOL3 JSON-LD 导入导出

    public static func exportSBOL3JSONLD(info: SnapGeneFileInfo, name: String) throws -> String {
        let baseURI = "https://labworker.local/sbol/"
        let cleanToken = name
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted)
            .joined()
        let safeID = cleanToken.isEmpty ? "Construct" : cleanToken
        let seqURI = "\(baseURI)\(safeID)_seq"
        let compURI = "\(baseURI)\(safeID)"

        var featureNodes: [[String: Any]] = []
        for (idx, feat) in info.features.enumerated() {
            guard !feat.segments.isEmpty else { continue }
            let ori = (feat.directionality == "2" || feat.directionality == "-")
                ? "https://identifiers.org/SO:0001031" // reverseComplement
                : "https://identifiers.org/SO:0001030" // inline
            // 多段或跨原点特征导出为 sbol:Range 数组，防止首尾拼接导致区间翻转丢失目标区
            let locationValue: Any
            if feat.segments.count == 1, let seg = feat.segments.first {
                locationValue = [
                    "@type": "sbol:Range",
                    "sbol:hasSequence": seqURI,
                    "sbol:start": seg.start,
                    "sbol:end": seg.end
                ]
            } else {
                locationValue = feat.segments.enumerated().map { sIdx, seg -> [String: Any] in
                    [
                        "@type": "sbol:Range",
                        "sbol:hasSequence": seqURI,
                        "sbol:order": sIdx + 1,
                        "sbol:start": seg.start,
                        "sbol:end": seg.end
                    ]
                }
            }
            featureNodes.append([
                "@id": "\(compURI)/feat_\(idx + 1)",
                "@type": "sbol:SequenceFeature",
                "sbol:name": feat.name,
                "sbol:role": [feat.type],
                "sbol:orientation": ori,
                "sbol:hasLocation": locationValue
            ])
        }

        let componentNode: [String: Any] = [
            "@id": compURI,
            "@type": "sbol:Component",
            "sbol:displayId": safeID,
            "sbol:name": name,
            "sbol:type": ["https://identifiers.org/SBO:0000251"],
            "sbol:hasSequence": [seqURI],
            "sbol:hasFeature": featureNodes
        ]

        let sequenceNode: [String: Any] = [
            "@id": seqURI,
            "@type": "sbol:Sequence",
            "sbol:displayId": "\(safeID)_seq",
            "sbol:elements": cleanIUPACPreserving(info.sequence).lowercased(),
            "sbol:encoding": "https://identifiers.org/edam:format_1207",
            "sbol:isCircular": info.isCircular
        ]

        let doc: [String: Any] = [
            "@context": [
                "sbol": "http://sbols.org/v3#"
            ],
            "@graph": [sequenceNode, componentNode]
        ]
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func parseSBOL3JSONLD(_ rawText: String, filePath: String = "sbol3://imported") -> [SnapGeneFileInfo] {
        guard let data = rawText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let graph = root["@graph"] as? [[String: Any]] else {
            return []
        }

        var seqByID: [String: (seq: String, isCircular: Bool)] = [:]
        var comps: [[String: Any]] = []

        for node in graph {
            let typ = (node["@type"] as? String) ?? ""
            if typ.contains("Sequence") && !typ.contains("Feature") {
                if let id = node["@id"] as? String,
                   let elements = node["sbol:elements"] as? String {
                    let cleaned = cleanIUPACPreserving(elements)
                    if !cleaned.isEmpty {
                        let circ = (node["sbol:isCircular"] as? Bool) ?? true
                        seqByID[id] = (cleaned, circ)
                    }
                }
            } else if typ.contains("Component") {
                comps.append(node)
            }
        }

        var out: [SnapGeneFileInfo] = []
        for (idx, comp) in comps.enumerated() {
            let name = (comp["sbol:name"] as? String) ?? (comp["sbol:displayId"] as? String) ?? "SBOL3_Component_\(idx + 1)"
            let seqRefs = comp["sbol:hasSequence"] as? [String] ?? []
            guard let firstRef = seqRefs.first, let seqEntry = seqByID[firstRef] else { continue }

            var feats: [SnapGeneFeature] = []
            if let rawFeats = comp["sbol:hasFeature"] as? [[String: Any]] {
                for fObj in rawFeats {
                    let fname = (fObj["sbol:name"] as? String) ?? "Feature"
                    let role = (fObj["sbol:role"] as? [String])?.first ?? "misc_feature"
                    let ori = (fObj["sbol:orientation"] as? String) ?? ""
                    let isRev = ori.contains("reverse") || ori.contains("SO:0001031")
                    let color = colorForGenBankType(role)
                    var parsedSegments: [SnapGeneSegment] = []
                    let seqLen = seqEntry.seq.count
                    func appendRangeDict(_ loc: [String: Any]) {
                        guard let s = (loc["sbol:start"] as? NSNumber)?.intValue,
                              let e = (loc["sbol:end"] as? NSNumber)?.intValue else { return }
                        if s > e && seqEntry.isCircular && seqLen > 0 {
                            // 兼容单 Range 表达的跨原点特征 (start > end)：拆分为 [s..seqLen, 1..e]，绝不反写为补集 [e..s]
                            parsedSegments.append(SnapGeneSegment(range: "\(s)-\(seqLen)", start: s, end: seqLen, color: color))
                            parsedSegments.append(SnapGeneSegment(range: "1-\(e)", start: 1, end: e, color: color))
                        } else {
                            let lo = min(s, e)
                            let hi = max(s, e)
                            parsedSegments.append(SnapGeneSegment(range: "\(lo)-\(hi)", start: lo, end: hi, color: color))
                        }
                    }
                    if let locList = fObj["sbol:hasLocation"] as? [[String: Any]] {
                        let ordered = locList.sorted { a, b in
                            let oa = (a["sbol:order"] as? NSNumber)?.intValue ?? 0
                            let ob = (b["sbol:order"] as? NSNumber)?.intValue ?? 0
                            return oa < ob
                        }
                        for loc in ordered { appendRangeDict(loc) }
                    } else if let loc = fObj["sbol:hasLocation"] as? [String: Any] {
                        appendRangeDict(loc)
                    }
                    if !parsedSegments.isEmpty {
                        feats.append(
                            SnapGeneFeature(
                                name: fname,
                                type: role,
                                directionality: isRev ? "2" : "1",
                                segments: parsedSegments
                            )
                        )
                    }
                }
            }

            out.append(
                SnapGeneFileInfo(
                    filePath: filePath,
                    fileName: "\(name).sbol3.json",
                    sequence: seqEntry.seq,
                    length: seqEntry.seq.count,
                    isCircular: seqEntry.isCircular,
                    featuresCount: feats.count,
                    features: feats
                )
            )
        }
        return out
    }

    // MARK: - 内部色彩与特征规范辅助

    private static func sanitizeGBFeatureType(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "misc_feature" }
        let safe = trimmed.replacingOccurrences(of: " ", with: "_")
        return String(safe.prefix(15))
    }

    private static func colorForGenBankType(_ rawType: String) -> String {
        let low = rawType.lowercased()
        if low.contains("promoter") { return "#f59e0b" }
        if low.contains("cds") || low.contains("gene") { return "#3b82f6" }
        if low.contains("rep_origin") || low.contains("ori") { return "#8b5cf6" }
        if low.contains("terminator") { return "#ef4444" }
        if low.contains("primer") { return "#10b981" }
        return "#06b6d4"
    }
}
