import Foundation

/// Sanger 测序 (.ab1 / .abi / .seq) 四色荧光毛细管电泳峰图解析与环状质粒比对验证引擎
public struct SangerAlignmentEngine {

    // MARK: - 1. 数据模型

    /// 单个已识别碱基峰位信息
    public struct CalledPeak: Identifiable, Sendable, Equatable {
        public let id: Int                  // 1-based 测序读长位置
        public let base: Character          // 主峰碱基 (A/C/G/T/N)
        public let traceIndex: Int          // 对应荧光轨迹采样点下标
        public let phredQuality: Int        // Phred 质量值 (0 - 62)
        public let primarySignal: Int       // 主峰荧光强度
        public let secondaryBase: Character? // 次峰碱基（当次峰/主峰 >= 0.30 时标记双峰）
        public let secondaryRatio: Double   // 次峰/主峰高度比 (0.0 - 1.0)
        public let isTrimmed: Bool          // 是否处于两端低质量修剪区

        public var isDoublePeak: Bool {
            secondaryBase != nil && secondaryRatio >= 0.30
        }
    }

    /// 解析后的 Sanger 测序记录（支持 ABIF .ab1 二进制与 .seq/.fasta 文本）
    public struct ChromatogramRecord: Sendable, Equatable {
        public let sampleName: String
        public let filePath: String?
        public let isBinaryAB1: Bool
        public let rawSequence: String
        public let qualityScores: [Int]
        public let peakLocations: [Int]
        public let traceA: [Int]
        public let traceC: [Int]
        public let traceG: [Int]
        public let traceT: [Int]
        public let trimStart0: Int          // 0-based 有效高质区起点 (含)
        public let trimEnd0: Int            // 0-based 有效高质区终点 (不含)
        public let calledPeaks: [CalledPeak]

        public var rawLength: Int { rawSequence.count }
        public var trimmedLength: Int { max(0, trimEnd0 - trimStart0) }
        public var trimmedSequence: String {
            guard trimStart0 < trimEnd0, trimStart0 >= 0, trimEnd0 <= rawSequence.count else { return "" }
            let chars = Array(rawSequence)
            return String(chars[trimStart0..<trimEnd0])
        }
        public var meanQualityTrimmed: Double {
            guard trimStart0 < trimEnd0, trimEnd0 <= qualityScores.count else { return 0.0 }
            let slice = qualityScores[trimStart0..<trimEnd0]
            return Double(slice.reduce(0, +)) / Double(max(1, slice.count))
        }
        public var q20Percent: Double {
            guard !qualityScores.isEmpty else { return 0.0 }
            let q20Count = qualityScores.filter { $0 >= 20 }.count
            return Double(q20Count) * 100.0 / Double(qualityScores.count)
        }
        public var maxTraceSignal: Int {
            max(
                traceA.max() ?? 100,
                traceC.max() ?? 100,
                traceG.max() ?? 100,
                traceT.max() ?? 100,
                100
            )
        }
    }

    /// 逐位点比对事件类型
    public enum AlignmentEventKind: String, Sendable, Equatable, Codable {
        case match = "匹配 (Match)"
        case mismatchSNP = "错配替换 (SNP)"
        case insertion = "插入 (Insertion)"
        case deletion = "缺失 (Deletion)"
        case doublePeak = "杂合双峰 (Mixed Peak)"
    }

    /// 逐列比对详情
    public struct AlignedColumn: Identifiable, Sendable, Equatable {
        public let id: Int
        public let refPos1Based: Int        // 参考质粒 1-based 坐标（自动环状回绕）
        public let readPos1Based: Int?      // 测序原始读长 1-based 坐标
        public let traceSampleIndex: Int?   // 对应四色荧光峰采样点坐标
        public let refBase: Character
        public let readBase: Character
        public let phredQuality: Int
        public let secondaryBase: Character?
        public let secondaryRatio: Double
        public let eventKind: AlignmentEventKind
    }

    /// 离散变异/异常位点汇总
    public struct VariantCall: Identifiable, Sendable, Equatable {
        public let id: String
        public let refPos1Based: Int
        public let readPos1Based: Int?
        public let traceSampleIndex: Int?
        public let kind: AlignmentEventKind
        public let hgvsNotation: String
        public let codonImpactNote: String
        public let phredQuality: Int
        public let secondaryRatio: Double
    }

    /// 比对综合结论等级
    public enum VerificationVerdict: String, Sendable, Equatable {
        case verifiedPass = "测序完全匹配 (100% 零突变通过)"
        case pointMutation = "检出点突变 / 碱基替换 (SNP)"
        case indelOrFrameshift = "检出插入/缺失 (Indel 移码风险)"
        case doublePeakWarning = "检出杂合双峰 (混合单克隆预警)"
        case unaligned = "未能匹配到参考质粒序列"
    }

    /// 完整比对报告
    public struct VerificationReport: Sendable, Equatable {
        public let chromatogram: ChromatogramRecord
        public let referenceName: String
        public let referenceLength: Int
        public let isReverseComplement: Bool
        public let matchedRefStart1Based: Int
        public let matchedRefEnd1Based: Int
        public let alignedLength: Int
        public let matchCount: Int
        public let mismatchCount: Int
        public let insertionCount: Int
        public let deletionCount: Int
        public let doublePeakCount: Int
        public let identityPercent: Double
        public let verdict: VerificationVerdict
        public let summaryNotes: [String]
        public let columns: [AlignedColumn]
        public let variants: [VariantCall]
    }

    // MARK: - 2. ABIF (.ab1 / .abi) 原生二进制解析与纯文本回退

    /// 从磁盘文件解析 Sanger 测序数据（支持 .ab1/.abi 二进制及 .seq/.fasta/.txt 文本）
    public static func parseFile(at url: URL, trimQualityThreshold: Int = 20) throws -> ChromatogramRecord {
        let data = try Data(contentsOf: url)
        let sampleName = url.deletingPathExtension().lastPathComponent
        return parseData(data, sampleName: sampleName, filePath: url.path, trimQualityThreshold: trimQualityThreshold)
    }

    /// 从内存 Data 解析 Sanger 测序数据
    public static func parseData(
        _ data: Data,
        sampleName: String = "Sanger_Read",
        filePath: String? = nil,
        trimQualityThreshold: Int = 20
    ) -> ChromatogramRecord {
        if data.count >= 34,
           let magic = String(data: data.subdata(in: 0..<4), encoding: .ascii),
           magic == "ABIF" {
            if let ab1 = parseABIFBinary(data, fallbackSampleName: sampleName, filePath: filePath, trimQualityThreshold: trimQualityThreshold) {
                return ab1
            }
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? ""
        return parsePlainSequenceText(text, sampleName: sampleName, filePath: filePath, trimQualityThreshold: trimQualityThreshold)
    }

    private struct ABIFDirEntry {
        let tagName: String
        let tagNum: Int
        let elemType: Int
        let elemSize: Int
        let numElements: Int
        let dataSize: Int
        let dataOffset: Int
    }

    private static func readUInt16BE(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readInt16BE(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16BE(data, offset))
    }

    private static func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readInt32BE(_ data: Data, _ offset: Int) -> Int {
        Int(Int32(bitPattern: readUInt32BE(data, offset)))
    }

    private static func parseABIFBinary(
        _ data: Data,
        fallbackSampleName: String,
        filePath: String?,
        trimQualityThreshold: Int
    ) -> ChromatogramRecord? {
        // Root directory entry at byte 6..33: numElements at byte 18, dataOffset at byte 26
        let numDirEntries = readInt32BE(data, 18)
        let dirOffset = readInt32BE(data, 26)
        guard numDirEntries > 0, numDirEntries < 10000, dirOffset >= 34, dirOffset + numDirEntries * 28 <= data.count else {
            return nil
        }

        var entries: [String: ABIFDirEntry] = [:]
        for i in 0..<numDirEntries {
            let base = dirOffset + i * 28
            guard let tName = String(data: data.subdata(in: base..<(base + 4)), encoding: .ascii) else { continue }
            let tNum = readInt32BE(data, base + 4)
            let eType = Int(readInt16BE(data, base + 8))
            let eSize = Int(readInt16BE(data, base + 10))
            let nElem = readInt32BE(data, base + 12)
            let dSize = readInt32BE(data, base + 16)
            let dOff = readInt32BE(data, base + 20)
            let key = "\(tName)#\(tNum)"
            entries[key] = ABIFDirEntry(
                tagName: tName,
                tagNum: tNum,
                elemType: eType,
                elemSize: eSize,
                numElements: nElem,
                dataSize: dSize,
                dataOffset: dOff
            )
        }

        func extractBytes(_ entry: ABIFDirEntry) -> Data? {
            if entry.dataSize <= 4 {
                var raw = UInt32(bitPattern: Int32(entry.dataOffset)).bigEndian
                let inlineData = Data(bytes: &raw, count: 4)
                return inlineData.prefix(max(0, entry.dataSize))
            } else {
                guard entry.dataOffset >= 0, entry.dataOffset + entry.dataSize <= data.count else { return nil }
                return data.subdata(in: entry.dataOffset..<(entry.dataOffset + entry.dataSize))
            }
        }

        func extractInt16Array(_ key: String) -> [Int] {
            guard let entry = entries[key], let bytes = extractBytes(entry) else { return [] }
            let count = min(entry.numElements, bytes.count / 2)
            var arr: [Int] = []
            arr.reserveCapacity(count)
            for i in 0..<count {
                let v = Int(readInt16BE(bytes, i * 2))
                arr.append(max(0, v))
            }
            return arr
        }

        // 1. 读取滤光轮通道顺序 FWO_#1 (默认 GATC -> DATA 9, 10, 11, 12)
        var channelOrder: [Character] = ["G", "A", "T", "C"]
        if let fwoEntry = entries["FWO_#1"], let fwoBytes = extractBytes(fwoEntry),
           let fwoStr = String(data: fwoBytes, encoding: .ascii)?.uppercased(), fwoStr.count >= 4 {
            channelOrder = Array(fwoStr.prefix(4))
        }

        // 2. 读取四色荧光轨迹 DATA#9..12（若不存在则回退 DATA#1..4）
        let dataNums = entries["DATA#9"] != nil ? [9, 10, 11, 12] : [1, 2, 3, 4]
        var channelTraces: [Character: [Int]] = [:]
        for (idx, dNum) in dataNums.enumerated() where idx < channelOrder.count {
            channelTraces[channelOrder[idx]] = extractInt16Array("DATA#\(dNum)")
        }
        let traceA = channelTraces["A"] ?? []
        let traceC = channelTraces["C"] ?? []
        let traceG = channelTraces["G"] ?? []
        let traceT = channelTraces["T"] ?? []

        // 3. 读取 Basecalls (PBAS#1 或 PBAS#2)
        let pbasEntry = entries["PBAS#1"] ?? entries["PBAS#2"]
        guard let pbas = pbasEntry, let pbasBytes = extractBytes(pbas),
              let rawBaseStr = String(data: pbasBytes, encoding: .ascii) else {
            return nil
        }
        let validBases = Set("ACGTNacgtn")
        let cleanBases = rawBaseStr.uppercased().filter { validBases.contains($0) }
        guard !cleanBases.isEmpty else { return nil }

        // 4. 读取 Peak Locations (PLOC#1 或 PLOC#2)
        var peakLocs = extractInt16Array("PLOC#1")
        if peakLocs.isEmpty {
            peakLocs = extractInt16Array("PLOC#2")
        }
        let traceLen = max(traceA.count, traceC.count, traceG.count, traceT.count)
        if peakLocs.count < cleanBases.count {
            peakLocs = (0..<cleanBases.count).map { i in
                traceLen > 0 ? min(traceLen - 1, i * 10 + 5) : i * 10 + 5
            }
        }

        // 5. 读取 Phred Quality (PCON#1 或 PCON#2)
        var qualities: [Int] = []
        if let pcon = entries["PCON#1"] ?? entries["PCON#2"], let qBytes = extractBytes(pcon) {
            qualities = qBytes.prefix(cleanBases.count).map { Int($0) }
        }

        // 6. 读取样本名 SMPL#1
        var parsedSampleName = fallbackSampleName
        if let smpl = entries["SMPL#1"], let smplBytes = extractBytes(smpl), !smplBytes.isEmpty {
            if smpl.elemType == 18 && smplBytes.count > 1 {
                let pLen = Int(smplBytes[0])
                if 1 + pLen <= smplBytes.count,
                   let s = String(data: smplBytes.subdata(in: 1..<(1 + pLen)), encoding: .utf8),
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parsedSampleName = s
                }
            } else if let s = String(data: smplBytes, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters),
                      !s.isEmpty {
                parsedSampleName = s
            }
        }

        return buildChromatogramRecord(
            sampleName: parsedSampleName,
            filePath: filePath,
            isBinaryAB1: true,
            rawSequence: cleanBases,
            peakLocations: Array(peakLocs.prefix(cleanBases.count)),
            qualities: qualities,
            traceA: traceA,
            traceC: traceC,
            traceG: traceG,
            traceT: traceT,
            trimQualityThreshold: trimQualityThreshold
        )
    }

    /// 纯文本序列 (.seq / .fasta / .txt) 合成标准高斯峰图以便统一可视化与比对
    public static func parsePlainSequenceText(
        _ rawText: String,
        sampleName: String = "Seq_Read",
        filePath: String? = nil,
        trimQualityThreshold: Int = 20
    ) -> ChromatogramRecord {
        let lines = rawText.components(separatedBy: .newlines)
        var headerName = sampleName
        var bodyLines: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                let h = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !h.isEmpty { headerName = h }
            } else {
                bodyLines.append(trimmed)
            }
        }
        let valid = Set("ACGTN")
        let cleanSeq = String(bodyLines.joined().uppercased().filter { valid.contains($0) })
        let syntheticData = generateSyntheticAB1Data(sequence: cleanSeq, sampleName: headerName)
        if let rec = parseABIFBinary(syntheticData, fallbackSampleName: headerName, filePath: filePath, trimQualityThreshold: trimQualityThreshold) {
            return ChromatogramRecord(
                sampleName: rec.sampleName,
                filePath: filePath,
                isBinaryAB1: false,
                rawSequence: rec.rawSequence,
                qualityScores: rec.qualityScores,
                peakLocations: rec.peakLocations,
                traceA: rec.traceA,
                traceC: rec.traceC,
                traceG: rec.traceG,
                traceT: rec.traceT,
                trimStart0: rec.trimStart0,
                trimEnd0: rec.trimEnd0,
                calledPeaks: rec.calledPeaks
            )
        }
        return ChromatogramRecord(
            sampleName: headerName,
            filePath: filePath,
            isBinaryAB1: false,
            rawSequence: cleanSeq,
            qualityScores: Array(repeating: 40, count: cleanSeq.count),
            peakLocations: (0..<cleanSeq.count).map { $0 * 10 + 5 },
            traceA: [],
            traceC: [],
            traceG: [],
            traceT: [],
            trimStart0: 0,
            trimEnd0: cleanSeq.count,
            calledPeaks: []
        )
    }

    private static func buildChromatogramRecord(
        sampleName: String,
        filePath: String?,
        isBinaryAB1: Bool,
        rawSequence: String,
        peakLocations: [Int],
        qualities: [Int],
        traceA: [Int],
        traceC: [Int],
        traceG: [Int],
        traceT: [Int],
        trimQualityThreshold: Int
    ) -> ChromatogramRecord {
        let chars = Array(rawSequence)
        let n = chars.count
        let traceLen = max(traceA.count, traceC.count, traceG.count, traceT.count)

        var finalQualities: [Int] = []
        finalQualities.reserveCapacity(n)

        var peakList: [(base: Character, tIdx: Int, priSig: Int, secBase: Character?, secRatio: Double, q: Int)] = []
        peakList.reserveCapacity(n)

        for i in 0..<n {
            let b = chars[i]
            let tIdx = i < peakLocations.count ? min(max(0, peakLocations[i]), max(0, traceLen - 1)) : i * 10 + 5
            let sigA = tIdx < traceA.count ? traceA[tIdx] : 0
            let sigC = tIdx < traceC.count ? traceC[tIdx] : 0
            let sigG = tIdx < traceG.count ? traceG[tIdx] : 0
            let sigT = tIdx < traceT.count ? traceT[tIdx] : 0

            let pairs: [(Character, Int)] = [("A", sigA), ("C", sigC), ("G", sigG), ("T", sigT)]
                .sorted { $0.1 > $1.1 }
            let primarySig = max(1, pairs[0].1)
            let secondSig = pairs[1].1
            let ratio = Double(secondSig) / Double(primarySig)
            let secBase: Character? = ratio >= 0.30 ? pairs[1].0 : nil

            let qScore: Int
            if i < qualities.count {
                qScore = qualities[i]
            } else {
                // 根据信噪比自动估算 Phred Q 值
                let estimated = Int(round(max(8.0, min(52.0, 48.0 * (1.0 - ratio * 0.85)))))
                qScore = b == "N" ? 5 : estimated
            }
            finalQualities.append(qScore)
            peakList.append((b, tIdx, primarySig, secBase, (ratio * 100).rounded() / 100.0, qScore))
        }

        // 滑动窗口修剪 5' 与 3' 低质量端 (首尾边界碱基 Q >= trimQualityThreshold 且 10bp 窗口平均 Q >= trimQualityThreshold)
        let winSize = min(10, max(1, n / 4))
        var trimStart = 0
        var trimEnd = n
        if n > winSize * 2 {
            for i in 0..<(n - winSize) {
                let avg = Double(finalQualities[i..<(i + winSize)].reduce(0, +)) / Double(winSize)
                if finalQualities[i] >= trimQualityThreshold && avg >= Double(trimQualityThreshold) {
                    trimStart = i
                    break
                }
            }
            for i in stride(from: n, through: trimStart + winSize, by: -1) {
                let avg = Double(finalQualities[(i - winSize)..<i].reduce(0, +)) / Double(winSize)
                if finalQualities[i - 1] >= trimQualityThreshold && avg >= Double(trimQualityThreshold) {
                    trimEnd = i
                    break
                }
            }
        }

        let calledPeaks: [CalledPeak] = peakList.enumerated().map { idx, item in
            CalledPeak(
                id: idx + 1,
                base: item.base,
                traceIndex: item.tIdx,
                phredQuality: item.q,
                primarySignal: item.priSig,
                secondaryBase: item.secBase,
                secondaryRatio: item.secRatio,
                isTrimmed: idx < trimStart || idx >= trimEnd
            )
        }

        return ChromatogramRecord(
            sampleName: sampleName,
            filePath: filePath,
            isBinaryAB1: isBinaryAB1,
            rawSequence: rawSequence,
            qualityScores: finalQualities,
            peakLocations: peakLocations,
            traceA: traceA,
            traceC: traceC,
            traceG: traceG,
            traceT: traceT,
            trimStart0: trimStart,
            trimEnd0: trimEnd,
            calledPeaks: calledPeaks
        )
    }

    // MARK: - 3. 标准 ABIF (.ab1) 二进制构建器（用于内置真实二进制示例与自动化测试）

    /// 生成符合 Applied Biosystems ABIF 规范的二进制 .ab1 数据流（支持注入杂合双峰与两端低质量峰）
    public static func generateSyntheticAB1Data(
        sequence: String,
        sampleName: String = "Labworker_Demo_Read",
        doublePeakAt1Based: [Int: Character] = [:],
        simulateNoisyEnds: Bool = true
    ) -> Data {
        let clean = BioSequence.clean(sequence)
        let chars = Array(clean.isEmpty ? "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTAC" : clean)
        let numBases = chars.count
        let step = 10
        let traceLen = numBases * step + 10

        var traceG = Array(repeating: Int16(12), count: traceLen)
        var traceA = Array(repeating: Int16(12), count: traceLen)
        var traceT = Array(repeating: Int16(12), count: traceLen)
        var traceC = Array(repeating: Int16(12), count: traceLen)
        var peakLocs: [Int16] = []
        var qualities: [UInt8] = []

        func addGaussian(to trace: inout [Int16], center: Int, amplitude: Double, sigma: Double = 2.4) {
            let radius = 7
            for offset in -radius...radius {
                let idx = center + offset
                guard idx >= 0 && idx < trace.count else { continue }
                let g = amplitude * exp(-Double(offset * offset) / (2.0 * sigma * sigma))
                let nextVal = min(3200, Int(trace[idx]) + Int(g.rounded()))
                trace[idx] = Int16(nextVal)
            }
        }

        for (i, base) in chars.enumerated() {
            let center = i * step + 6
            peakLocs.append(Int16(center))

            let isLowEnd = simulateNoisyEnds && numBases > 40 && (i < 8 || i >= numBases - 8)
            let amp = isLowEnd ? 360.0 : 1250.0
            switch base {
            case "G": addGaussian(to: &traceG, center: center, amplitude: amp)
            case "A": addGaussian(to: &traceA, center: center, amplitude: amp)
            case "T": addGaussian(to: &traceT, center: center, amplitude: amp)
            case "C": addGaussian(to: &traceC, center: center, amplitude: amp)
            default:
                addGaussian(to: &traceA, center: center, amplitude: 250)
                addGaussian(to: &traceC, center: center, amplitude: 250)
            }

            if let secBase = doublePeakAt1Based[i + 1] {
                let secAmp = amp * 0.55
                switch secBase {
                case "G": addGaussian(to: &traceG, center: center, amplitude: secAmp)
                case "A": addGaussian(to: &traceA, center: center, amplitude: secAmp)
                case "T": addGaussian(to: &traceT, center: center, amplitude: secAmp)
                case "C": addGaussian(to: &traceC, center: center, amplitude: secAmp)
                default: break
                }
                qualities.append(24)
            } else if isLowEnd {
                addGaussian(to: &traceT, center: center, amplitude: 170.0)
                qualities.append(12)
            } else {
                qualities.append(48)
            }
        }

        // 构造 ABIF 文件体
        var payload = Data()
        func appendUInt16BE(_ d: inout Data, _ v: UInt16) {
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8(v & 0xFF))
        }
        func appendInt16BE(_ d: inout Data, _ v: Int16) {
            appendUInt16BE(&d, UInt16(bitPattern: v))
        }
        func appendUInt32BE(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8((v >> 24) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8(v & 0xFF))
        }
        func encodeInt16Array(_ arr: [Int16]) -> Data {
            var d = Data(capacity: arr.count * 2)
            for v in arr { appendInt16BE(&d, v) }
            return d
        }

        let headerSize = 128
        payload.append(Data(count: headerSize))

        var dirRecords: [(name: String, num: Int, elemType: Int16, elemSize: Int16, numElem: Int, bytes: Data)] = []
        // FWO_#1 ("GATC" inline 4 bytes)
        dirRecords.append(("FWO_", 1, 2, 1, 4, "GATC".data(using: .ascii)!))
        // SMPL#1 (PString)
        let smplUTF8 = Array(sampleName.utf8.prefix(200))
        var smplData = Data([UInt8(smplUTF8.count)])
        smplData.append(contentsOf: smplUTF8)
        dirRecords.append(("SMPL", 1, 18, 1, smplData.count, smplData))
        // PBAS#1
        let pbasData = String(chars).data(using: .ascii)!
        dirRecords.append(("PBAS", 1, 2, 1, numBases, pbasData))
        // PLOC#1
        dirRecords.append(("PLOC", 1, 4, 2, peakLocs.count, encodeInt16Array(peakLocs)))
        // PCON#1
        dirRecords.append(("PCON", 1, 2, 1, qualities.count, Data(qualities)))
        // DATA#9..12 (G, A, T, C)
        dirRecords.append(("DATA", 9, 4, 2, traceG.count, encodeInt16Array(traceG)))
        dirRecords.append(("DATA", 10, 4, 2, traceA.count, encodeInt16Array(traceA)))
        dirRecords.append(("DATA", 11, 4, 2, traceT.count, encodeInt16Array(traceT)))
        dirRecords.append(("DATA", 12, 4, 2, traceC.count, encodeInt16Array(traceC)))

        var dirTable = Data()
        for rec in dirRecords {
            dirTable.append(rec.name.data(using: .ascii)!.prefix(4))
            appendUInt32BE(&dirTable, UInt32(rec.num))
            appendInt16BE(&dirTable, rec.elemType)
            appendInt16BE(&dirTable, rec.elemSize)
            appendUInt32BE(&dirTable, UInt32(rec.numElem))
            appendUInt32BE(&dirTable, UInt32(rec.bytes.count))
            if rec.bytes.count <= 4 {
                var inlineBytes = Array(rec.bytes)
                while inlineBytes.count < 4 { inlineBytes.append(0) }
                dirTable.append(contentsOf: inlineBytes)
            } else {
                let offset = payload.count
                payload.append(rec.bytes)
                appendUInt32BE(&dirTable, UInt32(offset))
            }
            appendUInt32BE(&dirTable, 0) // dataHandle
        }

        let dirOffset = payload.count
        payload.append(dirTable)

        // Write header at byte 0..33
        var header = Data()
        header.append("ABIF".data(using: .ascii)!)
        appendUInt16BE(&header, 101) // version 1.01
        header.append("tdir".data(using: .ascii)!)
        appendUInt32BE(&header, 1)
        appendInt16BE(&header, 1023)
        appendInt16BE(&header, 28)
        appendUInt32BE(&header, UInt32(dirRecords.count))
        appendUInt32BE(&header, UInt32(dirRecords.count * 28))
        appendUInt32BE(&header, UInt32(dirOffset))
        appendUInt32BE(&header, 0)
        payload.replaceSubrange(0..<header.count, with: header)
        return payload
    }

    // MARK: - 4. 环状质粒双向锚定与全局序列比对验证

    /// 将 Sanger 测序读长与参考质粒序列进行双向环状比对，识别匹配、点突变、移码 Indel 与杂合双峰
    public static func verifyAgainstPlasmid(
        chromatogram: ChromatogramRecord,
        referenceSequence: String,
        referenceName: String = "参考质粒",
        cdsStart1Based: Int? = nil
    ) -> VerificationReport {
        let cleanRef = BioSequence.clean(referenceSequence)
        let refLen = cleanRef.count
        let trimmedRead = chromatogram.trimmedSequence
        guard refLen >= 30, trimmedRead.count >= 16 else {
            return emptyReport(chromatogram: chromatogram, referenceName: referenceName, referenceLength: refLen)
        }

        let doubledRef = cleanRef + cleanRef
        let readFwd = trimmedRead
        let readRev = BioSequence.reverseComplement(trimmedRead)

        // 1. K-mer 种子定锚定位最优正/负链与起点
        let bestFwd = findBestSeedWindow(query: readFwd, doubledRef: doubledRef, refLen: refLen)
        let bestRev = findBestSeedWindow(query: readRev, doubledRef: doubledRef, refLen: refLen)

        let isReverse = bestRev.seedHits > bestFwd.seedHits
        let chosenSeed = isReverse ? bestRev : bestFwd
        let orientedQuery = isReverse ? readRev : readFwd

        guard chosenSeed.seedHits >= 1 else {
            return emptyReport(chromatogram: chromatogram, referenceName: referenceName, referenceLength: refLen)
        }

        let qLen = orientedQuery.count
        let refWindowStart0 = max(0, min(doubledRef.count - qLen, chosenSeed.estimatedRefStart0))
        let refWindowEnd0 = min(doubledRef.count, refWindowStart0 + qLen + 12)
        let refChars = Array(doubledRef)
        let refSlice = Array(refChars[refWindowStart0..<refWindowEnd0])
        let qChars = Array(orientedQuery)

        // 2. 带状全局-半全局比对 (允许末端悬垂与内部 SNP / Indel)
        let alignedPairs = bandedSemiGlobalAlign(refSlice: refSlice, querySlice: qChars)

        // 3. 构建逐位点比对列与变异清单
        var columns: [AlignedColumn] = []
        var variants: [VariantCall] = []
        var matchCount = 0
        var mismatchCount = 0
        var insertionCount = 0
        var deletionCount = 0
        var doublePeakCount = 0

        var curRef0 = refWindowStart0
        var curQuery0 = 0
        var firstMatchedRef1: Int?
        var lastMatchedRef1: Int?

        let trimStart0 = chromatogram.trimStart0
        let trimEnd0 = chromatogram.trimEnd0

        for (colIdx, pair) in alignedPairs.enumerated() {
            let rChar = pair.ref
            let qChar = pair.query

            // 映射回原始测序读长坐标 (1-based) 与峰图采样点
            var rawReadIndex0: Int? = nil
            if qChar != "-" {
                if isReverse {
                    rawReadIndex0 = (trimEnd0 - 1) - curQuery0
                } else {
                    rawReadIndex0 = trimStart0 + curQuery0
                }
                curQuery0 += 1
            }

            let wrappedRef1 = (curRef0 % refLen) + 1
            if rChar != "-" {
                if firstMatchedRef1 == nil { firstMatchedRef1 = wrappedRef1 }
                lastMatchedRef1 = wrappedRef1
                curRef0 += 1
            }

            let peakInfo: CalledPeak? = {
                guard let rIdx0 = rawReadIndex0, rIdx0 >= 0, rIdx0 < chromatogram.calledPeaks.count else { return nil }
                return chromatogram.calledPeaks[rIdx0]
            }()
            let phred = peakInfo?.phredQuality ?? 35
            let traceIdx = peakInfo?.traceIndex
            let secBase: Character? = {
                guard let sb = peakInfo?.secondaryBase else { return nil }
                if isReverse {
                    return BioSequence.reverseComplement(String(sb)).first
                }
                return sb
            }()
            let secRatio = peakInfo?.secondaryRatio ?? 0.0

            let eventKind: AlignmentEventKind
            if rChar == "-" {
                eventKind = .insertion
                insertionCount += 1
            } else if qChar == "-" {
                eventKind = .deletion
                deletionCount += 1
            } else if rChar == qChar {
                if secBase != nil && secRatio >= 0.30 {
                    eventKind = .doublePeak
                    doublePeakCount += 1
                } else {
                    eventKind = .match
                }
                matchCount += 1
            } else {
                eventKind = .mismatchSNP
                mismatchCount += 1
                if secBase != nil && secRatio >= 0.30 {
                    doublePeakCount += 1
                }
            }

            let readPos1 = rawReadIndex0.map { $0 + 1 }
            columns.append(
                AlignedColumn(
                    id: colIdx + 1,
                    refPos1Based: wrappedRef1,
                    readPos1Based: readPos1,
                    traceSampleIndex: traceIdx,
                    refBase: rChar,
                    readBase: qChar,
                    phredQuality: phred,
                    secondaryBase: secBase,
                    secondaryRatio: secRatio,
                    eventKind: eventKind
                )
            )

            if eventKind != .match {
                let hgvs: String
                let impact: String
                switch eventKind {
                case .mismatchSNP:
                    hgvs = "g.\(wrappedRef1)\(rChar)>\(qChar)"
                    impact = inferCodonImpact(refChars: Array(cleanRef), refPos1Based: wrappedRef1, newBase: qChar, cdsStart1Based: cdsStart1Based)
                case .insertion:
                    hgvs = "g.\(wrappedRef1)ins\(qChar)"
                    impact = L10n.t("单碱基插入（若位于 CDS 区将导致 3n+1 移码突变）")
                case .deletion:
                    hgvs = "g.\(wrappedRef1)del\(rChar)"
                    impact = L10n.t("单碱基缺失（若位于 CDS 区将导致 3n-1 移码突变）")
                case .doublePeak:
                    hgvs = "g.\(wrappedRef1)\(rChar)/\(secBase ?? "N")"
                    impact = L10n.tr("主峰 \(qChar) 伴随 \(Int((secRatio * 100).rounded()))% 次峰 \(secBase ?? "N")（提示菌落不纯或杂合突变）", "Primary peak \(qChar) with \(Int((secRatio * 100).rounded()))% secondary \(secBase ?? "N") (mixed colony or heterozygote)")
                case .match:
                    hgvs = ""
                    impact = ""
                }
                variants.append(
                    VariantCall(
                        id: "\(wrappedRef1)-\(colIdx)",
                        refPos1Based: wrappedRef1,
                        readPos1Based: readPos1,
                        traceSampleIndex: traceIdx,
                        kind: eventKind,
                        hgvsNotation: hgvs,
                        codonImpactNote: impact,
                        phredQuality: phred,
                        secondaryRatio: secRatio
                    )
                )
            }
        }

        let alignedLen = max(1, columns.count)
        let identity = (Double(matchCount) * 1000.0 / Double(alignedLen)).rounded() / 10.0

        let verdict: VerificationVerdict
        if insertionCount > 0 || deletionCount > 0 {
            verdict = .indelOrFrameshift
        } else if mismatchCount > 0 {
            verdict = .pointMutation
        } else if doublePeakCount > 0 {
            verdict = .doublePeakWarning
        } else {
            verdict = .verifiedPass
        }

        var notes: [String] = [
            L10n.tr("有效高质读长 \(trimmedRead.count) bp (原始 \(chromatogram.rawLength) bp，已修剪 5' 端 \(trimStart0) bp / 3' 端 \(chromatogram.rawLength - trimEnd0) bp)", "High-quality read \(trimmedRead.count) bp (raw \(chromatogram.rawLength) bp, trimmed 5' \(trimStart0) bp / 3' \(chromatogram.rawLength - trimEnd0) bp)"),
            L10n.tr("匹配方向：\(isReverse ? "反向互补链 (-)" : "正向链 (+)") · 覆盖参考质粒 \(firstMatchedRef1 ?? 1)..\(lastMatchedRef1 ?? 1) bp · 一致率 \(String(format: "%.1f", identity))%", "Orientation: \(L10n.t(isReverse ? "反向互补链 (-)" : "正向链 (+)")) · Ref \(firstMatchedRef1 ?? 1)..\(lastMatchedRef1 ?? 1) bp · Identity \(String(format: "%.1f", identity))%")
        ]
        if variants.isEmpty {
            notes.append(L10n.t("质检通过：高质比对窗口内无任何错配、缺失/插入或杂合双峰。"))
        } else {
            notes.append(L10n.tr("检出 \(mismatchCount) 处错配替换、\(insertionCount + deletionCount) 处 Indel、\(doublePeakCount) 处杂合双峰，请点击下方变异胶囊定位峰图核查。", "Detected \(mismatchCount) SNP(s), \(insertionCount + deletionCount) indel(s), \(doublePeakCount) mixed peak(s); click variant pills below to inspect."))
        }

        return VerificationReport(
            chromatogram: chromatogram,
            referenceName: referenceName,
            referenceLength: refLen,
            isReverseComplement: isReverse,
            matchedRefStart1Based: firstMatchedRef1 ?? 1,
            matchedRefEnd1Based: lastMatchedRef1 ?? 1,
            alignedLength: alignedLen,
            matchCount: matchCount,
            mismatchCount: mismatchCount,
            insertionCount: insertionCount,
            deletionCount: deletionCount,
            doublePeakCount: doublePeakCount,
            identityPercent: identity,
            verdict: verdict,
            summaryNotes: notes,
            columns: columns,
            variants: variants
        )
    }

    // MARK: - 5. 内部算法辅助 (K-mer 锚定 / 带状 DP 比对 / 密码子翻译推断)

    private static func findBestSeedWindow(query: String, doubledRef: String, refLen: Int) -> (estimatedRefStart0: Int, seedHits: Int) {
        let k = min(11, max(7, query.count / 5))
        guard query.count >= k, doubledRef.count >= k else { return (0, 0) }

        let qChars = Array(query)
        let rChars = Array(doubledRef)

        var refKmers: [String: [Int]] = [:]
        for i in 0...(rChars.count - k) {
            let kmer = String(rChars[i..<(i + k)])
            refKmers[kmer, default: []].append(i)
        }

        var offsetVotes: [Int: Int] = [:]
        let strideStep = max(1, (qChars.count - k) / 24)
        for qPos in stride(from: 0, through: qChars.count - k, by: strideStep) {
            let kmer = String(qChars[qPos..<(qPos + k)])
            if let hits = refKmers[kmer] {
                for rPos in hits {
                    let estStart = rPos - qPos
                    if estStart >= 0 && estStart < refLen {
                        // 以 4bp 桶投票容忍小 Indel
                        let bucket = (estStart / 4) * 4
                        offsetVotes[bucket, default: 0] += 1
                    }
                }
            }
        }

        guard let best = offsetVotes.max(by: { $0.value < $1.value }) else {
            return (0, 0)
        }
        return (best.key, best.value)
    }

    private static func bandedSemiGlobalAlign(
        refSlice: [Character],
        querySlice: [Character]
    ) -> [(ref: Character, query: Character)] {
        let m = refSlice.count
        let n = querySlice.count
        guard m > 0 && n > 0 else { return [] }

        let matchScore = 3
        let mismatchScore = -2
        let gapPenalty = -4
        let band = max(16, abs(m - n) + 12)

        let negInf = -1_000_000
        var dp = Array(repeating: Array(repeating: negInf, count: n + 1), count: m + 1)
        var trace = Array(repeating: Array(repeating: UInt8(0), count: n + 1), count: m + 1)
        // Reference 5' leading gaps free (semi-global on ref start)
        for i in 0...min(m, band) {
            dp[i][0] = 0
            trace[i][0] = 1
        }
        for j in 1...min(n, band) {
            dp[0][j] = j * gapPenalty
            trace[0][j] = 2
        }

        for i in 1...m {
            let jMin = max(1, i - band)
            let jMax = min(n, i + band)
            for j in jMin...jMax {
                let sDiag = dp[i - 1][j - 1] + (refSlice[i - 1] == querySlice[j - 1] ? matchScore : mismatchScore)
                let sUp = dp[i - 1][j] + gapPenalty      // deletion in query
                let sLeft = dp[i][j - 1] + gapPenalty    // insertion in query

                if sDiag >= sUp && sDiag >= sLeft {
                    dp[i][j] = sDiag
                    trace[i][j] = 0
                } else if sUp >= sLeft {
                    dp[i][j] = sUp
                    trace[i][j] = 1
                } else {
                    dp[i][j] = sLeft
                    trace[i][j] = 2
                }
            }
        }

        // 选取 query 完全比对完 (j = n) 时得分最高的 ref 终点 i
        var bestI = min(m, n)
        var bestScore = negInf
        for i in max(1, n - band)...min(m, n + band) {
            if dp[i][n] > bestScore {
                bestScore = dp[i][n]
                bestI = i
            }
        }

        var i = bestI
        var j = n
        var aligned: [(ref: Character, query: Character)] = []
        aligned.reserveCapacity(n + 8)

        while j > 0 {
            if i == 0 {
                aligned.append(("-", querySlice[j - 1]))
                j -= 1
                continue
            }
            let dir = trace[i][j]
            if dir == 0 {
                aligned.append((refSlice[i - 1], querySlice[j - 1]))
                i -= 1
                j -= 1
            } else if dir == 1 {
                aligned.append((refSlice[i - 1], "-"))
                i -= 1
            } else {
                aligned.append(("-", querySlice[j - 1]))
                j -= 1
            }
        }
        return aligned.reversed()
    }

    private static func inferCodonImpact(
        refChars: [Character],
        refPos1Based: Int,
        newBase: Character,
        cdsStart1Based: Int?
    ) -> String {
        let start1 = cdsStart1Based ?? 1
        let rel0 = refPos1Based - start1
        guard rel0 >= 0, refPos1Based - 1 < refChars.count else {
            return L10n.t("单碱基替换")
        }
        let codonIdx0 = (rel0 / 3) * 3 + (start1 - 1)
        guard codonIdx0 >= 0, codonIdx0 + 2 < refChars.count else {
            return L10n.t("单碱基替换")
        }
        var wtCodonChars = [refChars[codonIdx0], refChars[codonIdx0 + 1], refChars[codonIdx0 + 2]]
        let posInCodon = rel0 % 3
        let wtCodon = String(wtCodonChars)
        wtCodonChars[posInCodon] = newBase
        let mutCodon = String(wtCodonChars)
        let wtAA = CodonTranslator.standardTable[wtCodon]?.0 ?? "?"
        let mutAA = CodonTranslator.standardTable[mutCodon]?.0 ?? "?"
        let aaIndex1 = (rel0 / 3) + 1
        if wtAA == mutAA {
            return L10n.tr("同义突变 p.\(wtAA)\(aaIndex1)= (\(wtCodon)→\(mutCodon))", "Synonymous p.\(wtAA)\(aaIndex1)= (\(wtCodon)→\(mutCodon))")
        } else {
            return L10n.tr("错义/无义突变 p.\(wtAA)\(aaIndex1)\(mutAA) (\(wtCodon)→\(mutCodon))", "Missense/Nonsense p.\(wtAA)\(aaIndex1)\(mutAA) (\(wtCodon)→\(mutCodon))")
        }
    }

    private static func emptyReport(
        chromatogram: ChromatogramRecord,
        referenceName: String,
        referenceLength: Int
    ) -> VerificationReport {
        VerificationReport(
            chromatogram: chromatogram,
            referenceName: referenceName,
            referenceLength: referenceLength,
            isReverseComplement: false,
            matchedRefStart1Based: 1,
            matchedRefEnd1Based: 1,
            alignedLength: 0,
            matchCount: 0,
            mismatchCount: 0,
            insertionCount: 0,
            deletionCount: 0,
            doublePeakCount: 0,
            identityPercent: 0.0,
            verdict: .unaligned,
            summaryNotes: [L10n.t("未能在参考质粒中找到高置信同源匹配区，请检查是否选错参考载体或测序反应失败。")],
            columns: [],
            variants: []
        )
    }

    // MARK: - 5. Sanger 测序质检报告文本与 AnalysisRun 溯源记录生成 (P10)

    public static func formatVerificationReportText(_ rep: VerificationReport) -> String {
        var lines: [String] = [
            L10n.t("【Labworker Sanger 测序比对质检报告】"),
            L10n.tr("测序样本：\(rep.chromatogram.sampleName) (原始 \(rep.chromatogram.rawLength) bp，高质有效 \(rep.chromatogram.trimmedLength) bp，平均 Q\(String(format: "%.1f", rep.chromatogram.meanQualityTrimmed)))", "Sample: \(rep.chromatogram.sampleName) (Raw \(rep.chromatogram.rawLength) bp, Trimmed \(rep.chromatogram.trimmedLength) bp, Mean Q\(String(format: "%.1f", rep.chromatogram.meanQualityTrimmed)))"),
            L10n.tr("参考质粒：\(rep.referenceName) (\(rep.referenceLength) bp)", "Reference: \(rep.referenceName) (\(rep.referenceLength) bp)"),
            L10n.tr("比对区间：\(rep.matchedRefStart1Based)..\(rep.matchedRefEnd1Based) bp (\(rep.isReverseComplement ? "反向互补链 -" : "正向链 +"))", "Aligned Span: \(rep.matchedRefStart1Based)..\(rep.matchedRefEnd1Based) bp (\(L10n.t(rep.isReverseComplement ? "反向互补链 -" : "正向链 +")))"),
            L10n.tr("序列一致率：\(String(format: "%.1f%%", rep.identityPercent)) (\(rep.matchCount)/\(rep.alignedLength) bp)", "Identity: \(String(format: "%.1f%%", rep.identityPercent)) (\(rep.matchCount)/\(rep.alignedLength) bp)"),
            L10n.tr("综合结论：\(rep.verdict.rawValue)", "Verdict: \(L10n.t(rep.verdict.rawValue))")
        ]
        if !rep.variants.isEmpty {
            lines.append(L10n.t("检出变异明细："))
            for v in rep.variants {
                lines.append("  - \(v.hgvsNotation) [\(v.kind.rawValue)] Read #\(v.readPos1Based ?? 0) (Q\(v.phredQuality)): \(v.codonImpactNote)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 构建 Sanger 测序比对验证的 AnalysisRun 机器可读溯源记录 (P10 / P15)
    public static func buildSangerAnalysisRun(
        report: VerificationReport,
        referenceSequence: String,
        referenceFileURL: URL? = nil,
        trimQualityThreshold: Int = 20,
        secondaryPeakThreshold: Double = 0.30,
        outputs: [String] = [],
        exportDirectoryURL: URL? = nil,
        linkedPlasmidIDs: [String] = []
    ) -> AnalysisRun {
        var inputs: [AnalysisRun.InputFile] = []
        let chrom = report.chromatogram
        if let fp = chrom.filePath,
           let ab1Rec = AnalysisRun.makeInputFile(at: URL(fileURLWithPath: fp), relativeTo: exportDirectoryURL) {
            inputs.append(ab1Rec)
        } else {
            let seqBytes = Data(chrom.rawSequence.utf8)
            inputs.append(
                AnalysisRun.InputFile(
                    path: chrom.sampleName,
                    sha256: AnalysisRun.sha256Hex(ofData: seqBytes),
                    byteSize: Int64(seqBytes.count)
                )
            )
        }
        if let refURL = referenceFileURL,
           let refRec = AnalysisRun.makeInputFile(at: refURL, relativeTo: exportDirectoryURL) {
            inputs.append(refRec)
        }

        let cleanRef = BioSequence.clean(referenceSequence)
        let refSeqSHA = AnalysisRun.sha256Hex(ofString: cleanRef)
        let paramsDict: [String: AnyCodableValue] = [
            "referenceName": .string(report.referenceName),
            "referenceSequenceSHA256": .string(refSeqSHA),
            "referenceLengthBp": .int(report.referenceLength),
            "trimQualityThreshold": .int(trimQualityThreshold),
            "secondaryPeakThreshold": .double(secondaryPeakThreshold),
            "strand": .string(report.isReverseComplement ? "-" : "+"),
            "isReverseComplement": .bool(report.isReverseComplement),
            "verdict": .string(report.verdict.rawValue),
            "identityPercent": .double(report.identityPercent),
            "matchedRefStart1Based": .int(report.matchedRefStart1Based),
            "matchedRefEnd1Based": .int(report.matchedRefEnd1Based),
            "mismatchCount": .int(report.mismatchCount),
            "insertionCount": .int(report.insertionCount),
            "deletionCount": .int(report.deletionCount),
            "doublePeakCount": .int(report.doublePeakCount)
        ]

        var exclusions: [AnalysisRun.Exclusion] = []
        if chrom.trimStart0 > 0 {
            exclusions.append(AnalysisRun.Exclusion(itemID: "5prime_trim_1..\(chrom.trimStart0)", reason: L10n.tr("5'端低质量修剪 (Q < \(trimQualityThreshold))", "5' low-quality trim (Q < \(trimQualityThreshold))")))
        }
        if chrom.trimEnd0 < chrom.rawLength {
            exclusions.append(AnalysisRun.Exclusion(itemID: "3prime_trim_\(chrom.trimEnd0 + 1)..\(chrom.rawLength)", reason: L10n.tr("3'端低质量修剪 (Q < \(trimQualityThreshold))", "3' low-quality trim (Q < \(trimQualityThreshold))")))
        }

        return AnalysisRun(
            schemaVersion: 2,
            module: NavItem.sangerVerify.rawValue,
            engine: "swift-native",
            inputs: inputs,
            parameters: paramsDict,
            manualEdits: [],
            exclusions: exclusions,
            outputs: outputs,
            linkedPlasmidIDs: linkedPlasmidIDs
        )
    }

    /// 导出 Sanger 测序质检报告并同目录生成 <basename>.run.json 溯源伴随文件（绝不修改原始 .ab1 文件）(P10 / P15)
    @discardableResult
    public static func exportVerificationReportWithProvenance(
        report: VerificationReport,
        referenceSequence: String,
        referenceFileURL: URL? = nil,
        trimQualityThreshold: Int = 20,
        secondaryPeakThreshold: Double = 0.30,
        linkedPlasmidIDs: [String] = [],
        to outputReportURL: URL
    ) throws -> (reportURL: URL, sidecarURL: URL, run: AnalysisRun) {
        let reportText = formatVerificationReportText(report)
        try reportText.write(to: outputReportURL, atomically: true, encoding: .utf8)
        let run = buildSangerAnalysisRun(
            report: report,
            referenceSequence: referenceSequence,
            referenceFileURL: referenceFileURL,
            trimQualityThreshold: trimQualityThreshold,
            secondaryPeakThreshold: secondaryPeakThreshold,
            outputs: [outputReportURL.lastPathComponent],
            exportDirectoryURL: outputReportURL.deletingLastPathComponent(),
            linkedPlasmidIDs: linkedPlasmidIDs
        )
        let sidecarURL = try run.writeSidecarJSON(alongsideOutputURL: outputReportURL)
        return (outputReportURL, sidecarURL, run)
    }
}
