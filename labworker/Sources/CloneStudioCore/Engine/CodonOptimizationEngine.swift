import Foundation

// MARK: - 宿主生物密码子频率与多约束序列优化引擎 (DnaChisel / poly 对标)

public enum CodonHostOrganism: String, CaseIterable, Identifiable, Codable, Sendable {
    case human = "human"
    case mouse = "mouse"
    case eColi = "ecoli"
    case yeast = "yeast"
    case insect = "insect"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .human:  return "人 (H. sapiens)"
        case .mouse:  return "鼠 (M. musculus)"
        case .eColi:  return "大肠杆菌 (E. coli)"
        case .yeast:  return "酿酒酵母 (S. cerevisiae)"
        case .insect: return "昆虫 (Sf9 / S. frugiperda)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .human:  return "Human"
        case .mouse:  return "Mouse"
        case .eColi:  return "E. coli"
        case .yeast:  return "Yeast"
        case .insect: return "Insect (Sf9)"
        }
    }

    /// Kazusa 标准密码子使用频率表 (per 1,000 codons)
    public var codonFrequenciesPerThousand: [String: Double] {
        switch self {
        case .human:
            return [
                "TTT": 17.6, "TTC": 20.3, "TTA": 7.7,  "TTG": 12.9, "CTT": 13.2, "CTC": 19.6, "CTA": 7.2,  "CTG": 39.6,
                "ATT": 16.0, "ATC": 20.8, "ATA": 7.5,  "ATG": 22.0, "GTT": 11.0, "GTC": 14.5, "GTA": 7.1,  "GTG": 28.1,
                "TCT": 15.2, "TCC": 17.7, "TCA": 12.2, "TCG": 4.4,  "AGT": 12.1, "AGC": 19.5,
                "CCT": 17.5, "CCC": 19.8, "CCA": 16.9, "CCG": 6.9,
                "ACT": 13.1, "ACC": 18.9, "ACA": 15.1, "ACG": 6.1,
                "GCT": 18.4, "GCC": 27.7, "GCA": 15.8, "GCG": 7.4,
                "TAT": 12.2, "TAC": 15.3, "TAA": 1.0,  "TAG": 0.8,  "TGA": 1.6,
                "CAT": 10.9, "CAC": 15.1, "CAA": 12.3, "CAG": 34.2,
                "AAT": 17.0, "AAC": 19.1, "AAA": 24.4, "AAG": 31.9,
                "GAT": 21.8, "GAC": 25.1, "GAA": 29.0, "GAG": 39.6,
                "TGT": 10.6, "TGC": 12.6, "TGG": 13.2,
                "CGT": 4.5,  "CGC": 10.4, "CGA": 6.2,  "CGG": 11.4, "AGA": 12.2, "AGG": 12.0,
                "GGT": 10.8, "GGC": 22.2, "GGA": 16.5, "GGG": 16.5
            ]
        case .mouse:
            return [
                "TTT": 17.2, "TTC": 21.8, "TTA": 6.7,  "TTG": 13.4, "CTT": 13.4, "CTC": 20.2, "CTA": 8.1,  "CTG": 39.5,
                "ATT": 15.4, "ATC": 22.5, "ATA": 7.4,  "ATG": 22.8, "GTT": 10.7, "GTC": 15.4, "GTA": 7.4,  "GTG": 28.4,
                "TCT": 16.2, "TCC": 18.1, "TCA": 11.8, "TCG": 4.2,  "AGT": 12.7, "AGC": 19.7,
                "CCT": 18.4, "CCC": 18.2, "CCA": 17.3, "CCG": 6.2,
                "ACT": 13.7, "ACC": 19.0, "ACA": 16.0, "ACG": 5.6,
                "GCT": 20.0, "GCC": 26.0, "GCA": 15.8, "GCG": 6.4,
                "TAT": 12.2, "TAC": 16.1, "TAA": 1.0,  "TAG": 0.8,  "TGA": 1.6,
                "CAT": 10.6, "CAC": 15.3, "CAA": 12.0, "CAG": 34.1,
                "AAT": 15.6, "AAC": 20.3, "AAA": 21.9, "AAG": 33.6,
                "GAT": 21.0, "GAC": 26.0, "GAA": 27.0, "GAG": 39.4,
                "TGT": 11.4, "TGC": 12.3, "TGG": 12.5,
                "CGT": 4.7,  "CGC": 9.4,  "CGA": 6.6,  "CGG": 10.2, "AGA": 12.1, "AGG": 12.2,
                "GGT": 11.4, "GGC": 21.2, "GGA": 16.8, "GGG": 15.2
            ]
        case .eColi:
            return [
                "TTT": 22.1, "TTC": 16.6, "TTA": 13.8, "TTG": 13.7, "CTT": 11.0, "CTC": 11.0, "CTA": 3.9,  "CTG": 52.6,
                "ATT": 30.3, "ATC": 25.1, "ATA": 4.4,  "ATG": 27.8, "GTT": 18.3, "GTC": 15.3, "GTA": 10.9, "GTG": 26.4,
                "TCT": 8.5,  "TCC": 8.6,  "TCA": 7.2,  "TCG": 8.9,  "AGT": 8.8,  "AGC": 16.1,
                "CCT": 7.0,  "CCC": 5.5,  "CCA": 8.4,  "CCG": 23.2,
                "ACT": 9.0,  "ACC": 23.4, "ACA": 7.1,  "ACG": 14.4,
                "GCT": 15.3, "GCC": 25.5, "GCA": 20.2, "GCG": 33.6,
                "TAT": 16.2, "TAC": 12.2, "TAA": 2.0,  "TAG": 0.2,  "TGA": 1.0,
                "CAT": 12.9, "CAC": 9.7,  "CAA": 15.3, "CAG": 28.8,
                "AAT": 17.7, "AAC": 21.7, "AAA": 33.6, "AAG": 10.3,
                "GAT": 32.1, "GAC": 19.1, "GAA": 39.4, "GAG": 17.8,
                "TGT": 5.2,  "TGC": 6.5,  "TGG": 15.2,
                "CGT": 20.9, "CGC": 22.0, "CGA": 3.6,  "CGG": 5.4,  "AGA": 2.1,  "AGG": 1.2,
                "GGT": 24.7, "GGC": 29.6, "GGA": 8.0,  "GGG": 11.1
            ]
        case .yeast:
            return [
                "TTT": 26.1, "TTC": 18.4, "TTA": 26.2, "TTG": 27.2, "CTT": 12.3, "CTC": 5.4,  "CTA": 13.4, "CTG": 10.5,
                "ATT": 30.1, "ATC": 17.2, "ATA": 17.8, "ATG": 20.9, "GTT": 22.1, "GTC": 11.8, "GTA": 11.8, "GTG": 10.8,
                "TCT": 23.5, "TCC": 14.2, "TCA": 18.7, "TCG": 8.6,  "AGT": 14.2, "AGC": 9.8,
                "CCT": 13.5, "CCC": 6.8,  "CCA": 18.3, "CCG": 5.3,
                "ACT": 20.3, "ACC": 12.7, "ACA": 17.8, "ACG": 8.0,
                "GCT": 21.2, "GCC": 12.6, "GCA": 16.2, "GCG": 6.2,
                "TAT": 18.8, "TAC": 14.8, "TAA": 1.1,  "TAG": 0.5,  "TGA": 0.7,
                "CAT": 13.6, "CAC": 7.8,  "CAA": 27.3, "CAG": 12.1,
                "AAT": 35.7, "AAC": 24.8, "AAA": 41.9, "AAG": 30.8,
                "GAT": 37.6, "GAC": 20.2, "GAA": 45.6, "GAG": 19.2,
                "TGT": 8.1,  "TGC": 4.8,  "TGG": 10.4,
                "CGT": 6.4,  "CGC": 2.6,  "CGA": 3.0,  "CGG": 1.7,  "AGA": 21.3, "AGG": 9.2,
                "GGT": 23.9, "GGC": 9.8,  "GGA": 10.9, "GGG": 6.0
            ]
        case .insect:
            return [
                "TTT": 16.3, "TTC": 25.0, "TTA": 10.1, "TTG": 19.3, "CTT": 12.6, "CTC": 20.4, "CTA": 9.0,  "CTG": 32.7,
                "ATT": 20.0, "ATC": 26.8, "ATA": 10.6, "ATG": 23.5, "GTT": 15.1, "GTC": 18.2, "GTA": 11.0, "GTG": 27.0,
                "TCT": 13.0, "TCC": 19.8, "TCA": 12.3, "TCG": 10.2, "AGT": 11.4, "AGC": 16.7,
                "CCT": 14.5, "CCC": 18.8, "CCA": 14.9, "CCG": 11.1,
                "ACT": 14.3, "ACC": 23.3, "ACA": 14.0, "ACG": 10.1,
                "GCT": 20.6, "GCC": 30.7, "GCA": 15.5, "GCG": 12.0,
                "TAT": 13.2, "TAC": 21.2, "TAA": 1.3,  "TAG": 0.8,  "TGA": 0.9,
                "CAT": 10.3, "CAC": 15.8, "CAA": 16.1, "CAG": 29.0,
                "AAT": 18.2, "AAC": 25.5, "AAA": 25.2, "AAG": 36.1,
                "GAT": 24.4, "GAC": 27.7, "GAA": 27.4, "GAG": 35.8,
                "TGT": 10.2, "TGC": 12.8, "TGG": 13.0,
                "CGT": 10.0, "CGC": 15.5, "CGA": 6.9,  "CGG": 7.5,  "AGA": 10.9, "AGG": 8.9,
                "GGT": 21.3, "GGC": 25.5, "GGA": 15.9, "GGG": 7.9
            ]
        }
    }

    /// 相对适应度表 w_i = f_i / max(f_synonymous) ∈ (0, 1]
    public var relativeAdaptivenessTable: [String: Double] {
        let freq = codonFrequenciesPerThousand
        var maxByAA: [Character: Double] = [:]
        for (codon, pair) in CodonTranslator.standardTable {
            let f = freq[codon] ?? 1.0
            maxByAA[pair.0] = max(maxByAA[pair.0] ?? 0.001, f)
        }
        var w: [String: Double] = [:]
        for (codon, pair) in CodonTranslator.standardTable {
            let f = freq[codon] ?? 1.0
            w[codon] = min(1.0, max(0.01, f / (maxByAA[pair.0] ?? 1.0)))
        }
        return w
    }
}

public enum SynthesisVendorPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case twist = "Twist Bioscience"
    case idt = "IDT gBlocks"
    case tsingke = "擎科生物 (Tsingke)"
    case custom = "自定义规则"

    public var id: String { rawValue }
}

public enum CodonOptimizationEngine {

    public static let defaultForbiddenEnzymes: [String] = [
        "BsaI", "BsmBI", "BbsI", "SapI", "EcoRI", "BamHI", "HindIII"
    ]

    public static let selectableEnzymes: [String] = [
        "BsaI", "BsmBI", "BbsI", "SapI", "EcoRI", "BamHI", "XhoI", "HindIII", "NotI", "NdeI", "NcoI"
    ]

    public struct OptimizationConfig: Codable, Equatable, Sendable {
        public var host: CodonHostOrganism
        public var preset: SynthesisVendorPreset
        public var forbiddenEnzymeNames: [String]
        public var customForbiddenMotifs: [String]
        public var minWindowGC: Double
        public var maxWindowGC: Double
        public var gcWindowSizeBp: Int
        public var maxHomopolymerLength: Int
        public var maxDirectRepeatLength: Int
        public var optimizeFivePrimeStructure: Bool
        public var preserveOriginalTerminalStop: Bool
        public var useHighExpressionWeights: Bool

        public init(
            host: CodonHostOrganism = .human,
            preset: SynthesisVendorPreset = .twist,
            forbiddenEnzymeNames: [String] = CodonOptimizationEngine.defaultForbiddenEnzymes,
            customForbiddenMotifs: [String] = [],
            minWindowGC: Double = 0.35,
            maxWindowGC: Double = 0.65,
            gcWindowSizeBp: Int = 50,
            maxHomopolymerLength: Int = 5,
            maxDirectRepeatLength: Int = 10,
            optimizeFivePrimeStructure: Bool = true,
            preserveOriginalTerminalStop: Bool = true,
            useHighExpressionWeights: Bool = false
        ) {
            self.host = host
            self.preset = preset
            self.forbiddenEnzymeNames = forbiddenEnzymeNames
            self.customForbiddenMotifs = customForbiddenMotifs
            self.minWindowGC = min(0.60, max(0.15, minWindowGC))
            self.maxWindowGC = max(self.minWindowGC + 0.10, min(0.85, maxWindowGC))
            self.gcWindowSizeBp = max(21, min(120, gcWindowSizeBp))
            self.maxHomopolymerLength = max(4, min(10, maxHomopolymerLength))
            self.maxDirectRepeatLength = max(8, min(20, maxDirectRepeatLength))
            self.optimizeFivePrimeStructure = optimizeFivePrimeStructure
            self.preserveOriginalTerminalStop = preserveOriginalTerminalStop
            self.useHighExpressionWeights = useHighExpressionWeights
        }

        public static func presetConfig(_ preset: SynthesisVendorPreset, host: CodonHostOrganism = .human) -> OptimizationConfig {
            switch preset {
            case .twist:
                return OptimizationConfig(
                    host: host,
                    preset: .twist,
                    forbiddenEnzymeNames: defaultForbiddenEnzymes,
                    minWindowGC: 0.35,
                    maxWindowGC: 0.65,
                    gcWindowSizeBp: 50,
                    maxHomopolymerLength: 5,
                    maxDirectRepeatLength: 10,
                    optimizeFivePrimeStructure: true
                )
            case .idt:
                return OptimizationConfig(
                    host: host,
                    preset: .idt,
                    forbiddenEnzymeNames: ["BsaI", "BsmBI", "BbsI", "SapI", "EcoRI", "BamHI"],
                    minWindowGC: 0.32,
                    maxWindowGC: 0.68,
                    gcWindowSizeBp: 50,
                    maxHomopolymerLength: 6,
                    maxDirectRepeatLength: 10,
                    optimizeFivePrimeStructure: true
                )
            case .tsingke:
                return OptimizationConfig(
                    host: host,
                    preset: .tsingke,
                    forbiddenEnzymeNames: defaultForbiddenEnzymes,
                    minWindowGC: 0.30,
                    maxWindowGC: 0.70,
                    gcWindowSizeBp: 50,
                    maxHomopolymerLength: 6,
                    maxDirectRepeatLength: 12,
                    optimizeFivePrimeStructure: true
                )
            case .custom:
                return OptimizationConfig(host: host, preset: .custom)
            }
        }
    }

    public struct GCWindowPoint: Identifiable, Sendable, Equatable {
        public var id: Int { centerBp }
        public let centerBp: Int
        public let gcPercent: Double
    }

    public struct ConstraintCheckItem: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let passed: Bool
        public let detail: String
        public let violationPositions1Based: [Int]
    }

    public struct OptimizationReport: Sendable, Equatable {
        public let host: CodonHostOrganism
        public let isProteinInput: Bool
        public let originalDNA: String?
        public let optimizedDNA: String
        public let proteinSequence: String
        public let lengthBp: Int
        public let codonCount: Int
        public let originalCAI: Double?
        public let optimizedCAI: Double
        public let originalGCPercent: Double?
        public let optimizedGCPercent: Double
        public let originalFivePrimeDG: Double?
        public let optimizedFivePrimeDG: Double
        public let codonChangesCount: Int
        public let changedCodonIndices: [Int]
        public let gcProfileBefore: [GCWindowPoint]
        public let gcProfileAfter: [GCWindowPoint]
        public let constraintChecks: [ConstraintCheckItem]
        public let notices: [String]
        public let isSynthesisReady: Bool
    }

    public static let demoEGFPFragmentDNA: String =
        "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGAC" +
        "GGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTAC" +
        "GGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACC" +
        "CTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAG" +
        "CAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTC" +
        "TTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTG" +
        "GTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCAC" +
        "AAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAAC" +
        "GGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCC" +
        "GACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCAC" +
        "TACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTC" +
        "CTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA"

    // MARK: - 内部字典与辅助工具

    private struct ResolvedMotif {
        let name: String
        let forwardPattern: String
        let revCompPattern: String
        let length: Int
    }

    private static let iupacMap: [Character: Set<Character>] = [
        "A": ["A"], "C": ["C"], "G": ["G"], "T": ["T"],
        "R": ["A", "G"], "Y": ["C", "T"], "S": ["G", "C"], "W": ["A", "T"],
        "K": ["G", "T"], "M": ["A", "C"], "B": ["C", "G", "T"], "D": ["A", "G", "T"],
        "H": ["A", "C", "T"], "V": ["A", "C", "G"], "N": ["A", "C", "G", "T"]
    ]

    private static let synonymousCodonsByAA: [Character: [String]] = {
        var map: [Character: [String]] = [:]
        for (codon, pair) in CodonTranslator.standardTable {
            map[pair.0, default: []].append(codon)
        }
        return map.mapValues { $0.sorted() }
    }()

    public static func translateDNA(_ dna: String) -> String {
        let chars = Array(BioSequence.clean(dna))
        let count = chars.count / 3
        var out = ""
        out.reserveCapacity(count)
        for i in 0..<count {
            let codon = String(chars[(i * 3)..<(i * 3 + 3)])
            let aa = CodonTranslator.standardTable[codon]?.0 ?? "X"
            out.append(aa)
        }
        return out
    }

    public static func calculateCAI(_ dna: String, host: CodonHostOrganism, useHighExpressionWeights: Bool = false) -> Double {
        let wTable = useHighExpressionWeights ? highExpressionCodonWeights(for: host) : host.relativeAdaptivenessTable
        let chars = Array(BioSequence.clean(dna))
        let nCodons = chars.count / 3
        guard nCodons > 0 else { return 0.0 }
        var logSum = 0.0
        var used = 0
        for i in 0..<nCodons {
            let codon = String(chars[(i * 3)..<(i * 3 + 3)])
            if let aa = CodonTranslator.standardTable[codon]?.0, aa == "*" || aa == "M" || aa == "W" {
                // 标准 Sharp & Li (1987) 排除单密码子 Met/Trp 与终止密码子；若序列很短则保底纳入
                continue
            }
            if let w = wTable[codon] {
                logSum += log(max(0.01, w))
                used += 1
            }
        }
        if used == 0 {
            for i in 0..<nCodons {
                let codon = String(chars[(i * 3)..<(i * 3 + 3)])
                logSum += log(max(0.01, wTable[codon] ?? 1.0))
                used += 1
            }
        }
        return used > 0 ? exp(logSum / Double(used)) : 1.0
    }

    public static func slidingGCProfile(_ dna: String, windowSize: Int = 50, step: Int = 5) -> [GCWindowPoint] {
        let chars = Array(BioSequence.clean(dna))
        guard !chars.isEmpty else { return [] }
        let w = max(10, min(chars.count, windowSize))
        if chars.count <= w {
            return [GCWindowPoint(centerBp: chars.count / 2 + 1, gcPercent: BioSequence.gcContent(dna))]
        }
        var prefixGC = Array(repeating: 0, count: chars.count + 1)
        for i in 0..<chars.count {
            prefixGC[i + 1] = prefixGC[i] + ((chars[i] == "G" || chars[i] == "C") ? 1 : 0)
        }
        var pts: [GCWindowPoint] = []
        let safeStep = max(1, step)
        var s = 0
        while s + w <= chars.count {
            let gc = Double(prefixGC[s + w] - prefixGC[s]) * 100.0 / Double(w)
            pts.append(GCWindowPoint(centerBp: s + w / 2 + 1, gcPercent: gc))
            s += safeStep
        }
        return pts
    }

    // MARK: - 主优化入口

    public static func optimize(
        inputSequence: String,
        isProteinInput: Bool? = nil,
        config: OptimizationConfig = OptimizationConfig()
    ) -> OptimizationReport {
        var notices: [String] = []
        let resolvedIsProtein: Bool = {
            if let explicit = isProteinInput { return explicit }
            let trimmed = inputSequence
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
                .joined()
                .uppercased()
                .filter { $0.isLetter || $0 == "*" }
            guard !trimmed.isEmpty else { return false }
            let nonNucleic = trimmed.filter { !"ATCGUN".contains($0) }.count
            return Double(nonNucleic) / Double(trimmed.count) > 0.08
        }()

        let validAA = Set("ACDEFGHIKLMNPQRSTVWY*")
        let originalDNA: String?
        let aaChars: [Character]
        let originalStopCodon: String?

        if resolvedIsProtein {
            let lines = inputSequence.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            let rawAA = Array(lines.joined().uppercased().filter { validAA.contains($0) })
            aaChars = rawAA
            originalDNA = nil
            originalStopCodon = rawAA.last == "*" ? "TAA" : nil
        } else {
            let rawDNA = BioSequence.clean(inputSequence)
            let rem = rawDNA.count % 3
            if rem != 0 {
                notices.append(L10n.tr("输入 DNA 序列长度 (\(rawDNA.count) bp) 非 3 的整数倍，已截去末尾 \(rem) bp 用于密码子优化。", "Input DNA length (\(rawDNA.count) bp) is not a multiple of 3; truncated trailing \(rem) bp for optimization."))
            }
            let usableCount = rawDNA.count - rem
            let trimmedDNA = String(rawDNA.prefix(usableCount))
            originalDNA = trimmedDNA
            let translated = Array(translateDNA(trimmedDNA))
            aaChars = translated
            if usableCount >= 3 && translated.last == "*" {
                originalStopCodon = String(trimmedDNA.suffix(3))
            } else {
                originalStopCodon = nil
            }
        }

        let proteinSeq = String(aaChars)
        guard !aaChars.isEmpty else {
            return OptimizationReport(
                host: config.host,
                isProteinInput: resolvedIsProtein,
                originalDNA: originalDNA,
                optimizedDNA: "",
                proteinSequence: "",
                lengthBp: 0,
                codonCount: 0,
                originalCAI: nil,
                optimizedCAI: 0,
                originalGCPercent: nil,
                optimizedGCPercent: 0,
                originalFivePrimeDG: nil,
                optimizedFivePrimeDG: 0,
                codonChangesCount: 0,
                changedCodonIndices: [],
                gcProfileBefore: [],
                gcProfileAfter: [],
                constraintChecks: [],
                notices: [L10n.t("请输入有效的 DNA CDS 或氨基酸序列。")],
                isSynthesisReady: false
            )
        }

        let motifs = resolveForbiddenMotifs(config: config)
        let wTable = config.useHighExpressionWeights ? highExpressionCodonWeights(for: config.host) : config.host.relativeAdaptivenessTable
        var rankedSynonymous: [Character: [String]] = [:]
        for (aa, list) in synonymousCodonsByAA {
            rankedSynonymous[aa] = list.sorted { (wTable[$0] ?? 0) > (wTable[$1] ?? 0) }
        }

        // 构建可优化密码子数组
        var codons: [String] = []
        codons.reserveCapacity(aaChars.count)
        for (idx, aa) in aaChars.enumerated() {
            if idx == aaChars.count - 1, aa == "*", config.preserveOriginalTerminalStop, let stop = originalStopCodon {
                codons.append(stop)
            } else if let best = rankedSynonymous[aa]?.first {
                codons.append(best)
            } else {
                codons.append("NNN")
            }
        }

        // 构建全长碱基缓冲以便快速局部修改与全局评分
        var baseBuffer = Array(codons.joined())
        func setCodon(_ cIdx: Int, to codon: String) {
            codons[cIdx] = codon
            let cChars = Array(codon)
            let b = cIdx * 3
            baseBuffer[b] = cChars[0]
            baseBuffer[b + 1] = cChars[1]
            baseBuffer[b + 2] = cChars[2]
        }

        // Pass 1: 基于 RNA Turner 2004 参数（含 G:U 摇摆配对 + 上游 Kozak/RBS 5'-UTR 上下文）的 5' mRNA 二级结构缓解
        let upstream5UTR = (config.host == .eColi) ? "AGGAGGTA" : "GCCACC"
        let fivePrimeCodonLimit = min(15, codons.count)
        if config.optimizeFivePrimeStructure && fivePrimeCodonLimit >= 4 {
            for _ in 0..<2 {
                let prefixSeq = String(baseBuffer.prefix(min(45, baseBuffer.count)))
                if calcRNA5PrimeHairpinDG(dnaSeq: prefixSeq, upstreamUTR: upstream5UTR) >= -3.0 { break }
                for cIdx in 0..<fivePrimeCodonLimit {
                    let aa = aaChars[cIdx]
                    guard let candidates = rankedSynonymous[aa], candidates.count > 1 else { continue }
                    if cIdx == codons.count - 1 && aa == "*" && config.preserveOriginalTerminalStop { continue }
                    let origCodon = codons[cIdx]
                    var bestCodon = origCodon
                    var bestScore = scoreFivePrimePrefix(baseBuffer: baseBuffer, wTable: wTable, codon: origCodon, upstreamUTR: upstream5UTR)
                    for cand in candidates where cand != origCodon {
                        setCodon(cIdx, to: cand)
                        let s = scoreFivePrimePrefix(baseBuffer: baseBuffer, wTable: wTable, codon: cand, upstreamUTR: upstream5UTR)
                        if s > bestScore + 1e-6 {
                            bestScore = s
                            bestCodon = cand
                        }
                    }
                    setCodon(cIdx, to: bestCodon)
                }
            }
        }

        // Pass 2: 迭代多约束局部重选（最多 16 轮，仅重选存在约束违例邻域或极端异常窗口）
        let maxPasses = 16
        for _ in 0..<maxPasses {
            let motifHits = findMotifHits(in: baseBuffer, motifs: motifs)
            let homopolymerPositions = findHomopolymers(in: baseBuffer, minLen: config.maxHomopolymerLength)
            let repeatPositions = findDirectRepeats(in: baseBuffer, repeatLen: config.maxDirectRepeatLength)
            let gcOutIndices = findOutOfRangeGCCodons(in: baseBuffer, config: config)

            var dirtyCodons = Set<Int>()
            for hit in motifHits {
                let cLo = max(0, hit.start0 / 3 - 1)
                let cHi = min(codons.count - 1, hit.end0 / 3 + 1)
                for c in cLo...cHi { dirtyCodons.insert(c) }
            }
            for hp in homopolymerPositions {
                let cLo = max(0, hp.start0 / 3 - 1)
                let cHi = min(codons.count - 1, hp.end0 / 3 + 1)
                for c in cLo...cHi { dirtyCodons.insert(c) }
            }
            for rp in repeatPositions {
                let cLo = max(0, rp.start0 / 3)
                let cHi = min(codons.count - 1, (rp.start0 + config.maxDirectRepeatLength - 1) / 3)
                for c in cLo...cHi { dirtyCodons.insert(c) }
            }
            for c in gcOutIndices {
                dirtyCodons.insert(c)
            }
            if config.optimizeFivePrimeStructure {
                let prefixSeq = String(baseBuffer.prefix(min(45, baseBuffer.count)))
                if calcRNA5PrimeHairpinDG(dnaSeq: prefixSeq, upstreamUTR: upstream5UTR) < -3.0 {
                    for c in 0..<fivePrimeCodonLimit { dirtyCodons.insert(c) }
                }
            }

            if dirtyCodons.isEmpty { break }

            // 构建全序列 repeat k-mer 计数表（O(n)）
            var kmerCounts = buildRepeatCounts(baseBuffer: baseBuffer, k: config.maxDirectRepeatLength)
            var prefixGC = buildPrefixGC(baseBuffer: baseBuffer)
            var madeChange = false

            for cIdx in dirtyCodons.sorted() {
                let aa = aaChars[cIdx]
                if cIdx == codons.count - 1 && aa == "*" && config.preserveOriginalTerminalStop { continue }
                guard let candidates = rankedSynonymous[aa], candidates.count > 1 else { continue }

                let origCodon = codons[cIdx]
                var bestCodon = origCodon
                var bestObj = localObjective(
                    codonIdx: cIdx,
                    codon: origCodon,
                    baseBuffer: baseBuffer,
                    motifs: motifs,
                    config: config,
                    wTable: wTable,
                    kmerCounts: kmerCounts,
                    prefixGC: prefixGC
                )

                for cand in candidates where cand != origCodon {
                    setCodon(cIdx, to: cand)
                    // 仅用局部更新后评估（注意 kmerCounts 与 prefixGC 更新轻量切片）
                    let obj = localObjective(
                        codonIdx: cIdx,
                        codon: cand,
                        baseBuffer: baseBuffer,
                        motifs: motifs,
                        config: config,
                        wTable: wTable,
                        kmerCounts: nil, // 在改动处直接动态检测局部 repeat 与局部 GC
                        prefixGC: nil
                    )
                    if obj > bestObj + 1e-5 {
                        bestObj = obj
                        bestCodon = cand
                    }
                }
                setCodon(cIdx, to: bestCodon)
                if bestCodon != origCodon {
                    madeChange = true
                    kmerCounts = buildRepeatCounts(baseBuffer: baseBuffer, k: config.maxDirectRepeatLength)
                    prefixGC = buildPrefixGC(baseBuffer: baseBuffer)
                }
            }

            if !madeChange { break }
        }

        // 硬性不变量校验：逐一确认每个密码子翻译后仍等于原始蛋白氨基酸
        for i in 0..<aaChars.count {
            let actualAA = CodonTranslator.standardTable[codons[i]]?.0
            if actualAA != aaChars[i], let fallback = rankedSynonymous[aaChars[i]]?.first {
                setCodon(i, to: fallback)
            }
        }

        let optimizedDNA = String(baseBuffer)
        let checks = buildConstraintChecks(optimizedDNA: optimizedDNA, config: config, motifs: motifs)
        let isReady = checks.allSatisfy(\.passed)

        let origCAI = originalDNA.map { calculateCAI($0, host: config.host, useHighExpressionWeights: config.useHighExpressionWeights) }
        let optCAI = calculateCAI(optimizedDNA, host: config.host, useHighExpressionWeights: config.useHighExpressionWeights)
        let origGC = originalDNA.map { BioSequence.gcContent($0) }
        let optGC = BioSequence.gcContent(optimizedDNA)
        let origDG = originalDNA.map { calcRNA5PrimeHairpinDG(dnaSeq: String($0.prefix(45)), upstreamUTR: upstream5UTR) }
        let optDG = calcRNA5PrimeHairpinDG(dnaSeq: String(optimizedDNA.prefix(45)), upstreamUTR: upstream5UTR)

        var changedCodons: [Int] = []
        if let orig = originalDNA {
            let origChars = Array(orig)
            for i in 0..<aaChars.count {
                let c0 = String(origChars[(i * 3)..<(i * 3 + 3)])
                if c0 != codons[i] {
                    changedCodons.append(i + 1)
                }
            }
        }

        return OptimizationReport(
            host: config.host,
            isProteinInput: resolvedIsProtein,
            originalDNA: originalDNA,
            optimizedDNA: optimizedDNA,
            proteinSequence: proteinSeq,
            lengthBp: optimizedDNA.count,
            codonCount: codons.count,
            originalCAI: origCAI,
            optimizedCAI: optCAI,
            originalGCPercent: origGC,
            optimizedGCPercent: optGC,
            originalFivePrimeDG: origDG,
            optimizedFivePrimeDG: optDG,
            codonChangesCount: originalDNA == nil ? codons.count : changedCodons.count,
            changedCodonIndices: changedCodons,
            gcProfileBefore: originalDNA.map { slidingGCProfile($0, windowSize: config.gcWindowSizeBp, step: 5) } ?? [],
            gcProfileAfter: slidingGCProfile(optimizedDNA, windowSize: config.gcWindowSizeBp, step: 5),
            constraintChecks: checks,
            notices: notices,
            isSynthesisReady: isReady
        )
    }

    // MARK: - 约束求解辅助函数

    private static func resolveForbiddenMotifs(config: OptimizationConfig) -> [ResolvedMotif] {
        var out: [ResolvedMotif] = []
        var seen = Set<String>()
        for name in config.forbiddenEnzymeNames {
            let site: String
            if let enz = RestrictionEnzymeDatabase.shared.find(name: name) {
                site = enz.site.uppercased()
            } else {
                continue
            }
            let rc = reverseComplementIUPAC(site)
            let key = "\(name.lowercased()):\(site)"
            if !site.isEmpty && !seen.contains(key) {
                seen.insert(key)
                out.append(ResolvedMotif(name: name, forwardPattern: site, revCompPattern: rc, length: site.count))
            }
        }
        for raw in config.customForbiddenMotifs {
            let cleaned = raw.uppercased().filter { iupacMap[$0] != nil }
            guard cleaned.count >= 4 else { continue }
            let rc = reverseComplementIUPAC(cleaned)
            let key = "custom:\(cleaned)"
            if !seen.contains(key) {
                seen.insert(key)
                out.append(ResolvedMotif(name: cleaned, forwardPattern: cleaned, revCompPattern: rc, length: cleaned.count))
            }
        }
        return out
    }

    private static func reverseComplementIUPAC(_ seq: String) -> String {
        let comp: [Character: Character] = [
            "A": "T", "T": "A", "C": "G", "G": "C",
            "R": "Y", "Y": "R", "S": "S", "W": "W",
            "K": "M", "M": "K", "B": "V", "V": "B",
            "D": "H", "H": "D", "N": "N"
        ]
        return String(seq.reversed().map { comp[$0] ?? "N" })
    }

    private static func matchesIUPAC(_ slice: ArraySlice<Character>, pattern: [Character]) -> Bool {
        guard slice.count == pattern.count else { return false }
        var idx = slice.startIndex
        for p in pattern {
            let ch = slice[idx]
            guard let allowed = iupacMap[p], allowed.contains(ch) else { return false }
            idx = slice.index(after: idx)
        }
        return true
    }

    private static func findMotifHits(
        in chars: [Character],
        motifs: [ResolvedMotif],
        range: Range<Int>? = nil
    ) -> [(name: String, start0: Int, end0: Int)] {
        let n = chars.count
        var hits: [(name: String, start0: Int, end0: Int)] = []
        for m in motifs {
            let mLen = m.length
            guard mLen > 0, mLen <= n else { continue }
            let fPat = Array(m.forwardPattern)
            let rPat = Array(m.revCompPattern)
            let samePal = (fPat == rPat)
            let lo = max(0, (range?.lowerBound ?? 0))
            let hi = min(n - mLen, (range?.upperBound ?? n) - 1)
            guard lo <= hi else { continue }
            for i in lo...hi {
                let slice = chars[i..<(i + mLen)]
                if matchesIUPAC(slice, pattern: fPat) || (!samePal && matchesIUPAC(slice, pattern: rPat)) {
                    hits.append((m.name, i, i + mLen - 1))
                }
            }
        }
        return hits
    }

    private static func findHomopolymers(in chars: [Character], minLen: Int, range: Range<Int>? = nil) -> [(start0: Int, end0: Int)] {
        guard chars.count >= minLen else { return [] }
        let lo = max(0, range?.lowerBound ?? 0)
        let hi = min(chars.count, range?.upperBound ?? chars.count)
        guard hi - lo >= minLen else { return [] }
        var out: [(Int, Int)] = []
        var runStart = lo
        var runLen = 1
        for i in (lo + 1)..<hi {
            if chars[i] == chars[i - 1] {
                runLen += 1
            } else {
                if runLen >= minLen {
                    out.append((runStart, i - 1))
                }
                runStart = i
                runLen = 1
            }
        }
        if runLen >= minLen {
            out.append((runStart, hi - 1))
        }
        return out
    }

    private static func buildRepeatCounts(baseBuffer: [Character], k: Int) -> [String: Int] {
        guard baseBuffer.count >= k else { return [:] }
        var counts: [String: Int] = [:]
        counts.reserveCapacity(baseBuffer.count)
        for i in 0...(baseBuffer.count - k) {
            let s = String(baseBuffer[i..<(i + k)])
            counts[s, default: 0] += 1
        }
        return counts
    }

    private static func findDirectRepeats(in chars: [Character], repeatLen: Int) -> [(seq: String, start0: Int)] {
        guard chars.count >= repeatLen * 2 else { return [] }
        var firstPos: [String: Int] = [:]
        var out: [(String, Int)] = []
        for i in 0...(chars.count - repeatLen) {
            let sub = String(chars[i..<(i + repeatLen)])
            if firstPos[sub] != nil {
                out.append((sub, i))
            } else {
                firstPos[sub] = i
            }
        }
        return out
    }

    private static func buildPrefixGC(baseBuffer: [Character]) -> [Int] {
        var prefixGC = Array(repeating: 0, count: baseBuffer.count + 1)
        for i in 0..<baseBuffer.count {
            prefixGC[i + 1] = prefixGC[i] + ((baseBuffer[i] == "G" || baseBuffer[i] == "C") ? 1 : 0)
        }
        return prefixGC
    }

    private static func findOutOfRangeGCCodons(in chars: [Character], config: OptimizationConfig) -> [Int] {
        let w = min(chars.count, config.gcWindowSizeBp)
        guard w >= 12 else { return [] }
        let prefixGC = buildPrefixGC(baseBuffer: chars)
        var dirty = Set<Int>()
        // 与 evaluateConstraints 统一为 step=3 密码子同相 O(N) 前缀和滑动窗，消除跨相位不一致
        for s in stride(from: 0, through: chars.count - w, by: 3) {
            let gc = Double(prefixGC[s + w] - prefixGC[s]) / Double(w)
            if gc < config.minWindowGC || gc > config.maxWindowGC {
                let cStart = s / 3
                let cEnd = (s + w - 1) / 3
                for c in cStart...cEnd { dirty.insert(c) }
            }
        }
        return Array(dirty)
    }

    /// RNA Turner 2004 (Mathews et al., PNAS 2004) 5' mRNA 局部发夹自由能 ΔG37 (kcal/mol)
    /// 支持 Watson–Crick (AU/UA/CG/GC) 与 RNA 专属 G:U / U:G 摇摆配对，并自动拼接上游 Kozak/RBS 5'-UTR 上下文
    public static func calcRNA5PrimeHairpinDG(dnaSeq: String, upstreamUTR: String = "GCCACC") -> Double {
        let combined = (upstreamUTR + dnaSeq).uppercased().replacingOccurrences(of: "T", with: "U")
        let rna = Array(combined.filter { $0 == "A" || $0 == "U" || $0 == "C" || $0 == "G" })
        let n = rna.count
        guard n >= 10 else { return 0.0 }

        func canPair(_ a: Character, _ b: Character) -> Bool {
            (a == "A" && b == "U") || (a == "U" && b == "A") ||
            (a == "C" && b == "G") || (a == "G" && b == "C") ||
            (a == "G" && b == "U") || (a == "U" && b == "G")
        }
        // Turner 2004 (Mathews et al., PNAS 2004 Table 1) RNA 37°C 最近邻堆叠 ΔG (kcal/mol)，含全部 G:U 摇摆配对参数
        let rnaStackDG: [String: Double] = [
            "AA/UU": -0.93, "UU/AA": -0.93, "AU/UA": -1.10, "UA/AU": -1.33,
            "CA/GU": -2.11, "UG/AC": -2.11, "CU/GA": -2.08, "AG/UC": -2.08,
            "GA/CU": -2.35, "UC/AG": -2.35, "GU/CA": -2.24, "AC/UG": -2.24,
            "CG/GC": -2.36, "GC/CG": -3.42, "GG/CC": -3.26, "CC/GG": -3.26,
            // G:U 摇摆堆叠 (Turner 2004)
            "AG/UU": -0.55, "UU/GA": -0.55, "AU/UG": -1.36, "GU/UA": -1.36,
            "CG/GU": -1.41, "UG/GC": -1.41, "CU/GG": -2.11, "GG/UC": -2.11,
            "GA/UU": -1.27, "UU/AG": -1.27, "GG/CU": -1.53, "UC/GG": -1.53,
            "GU/CG": -2.51, "GC/UG": -2.51,
            "GG/UU": -0.50, "UU/GG": -0.50, "GU/UG": +1.29, "UG/GU": +0.30,
            "UA/GU": -1.00, "UG/AU": -1.00
        ]
        // Turner 2004 发夹环起始 ΔG37 (环长 3..9 nt；>9 nt 按 Jacobson-Stockmayer 对数项外推)
        let loopInit: [Int: Double] = [3: 5.4, 4: 5.6, 5: 5.7, 6: 5.4, 7: 6.0, 8: 5.5, 9: 6.4]
        func hairpinLoopPenalty(_ loopLen: Int) -> Double {
            if let exact = loopInit[loopLen] { return exact }
            return 6.4 + 1.08 * log(Double(max(9, loopLen)) / 9.0)
        }

        var bestDG = 0.0
        for i in 0..<(n - 6) {
            for j in (i + 5)..<n {
                if !canPair(rna[i], rna[j]) { continue }
                var stem = 0
                var stackSum = 0.0
                while (i + stem) < (j - stem - 3) && canPair(rna[i + stem], rna[j - stem]) {
                    if stem > 0 {
                        let k = "\(rna[i + stem - 1])\(rna[i + stem])/\(rna[j - stem + 1])\(rna[j - stem])"
                        stackSum += rnaStackDG[k] ?? -1.0
                    }
                    stem += 1
                }
                guard stem >= 3 else { continue }
                let loopLen = (j - stem) - (i + stem) + 1
                guard loopLen >= 3 else { continue }
                let terminalAU = ((rna[i] == "A" && rna[j] == "U") || (rna[i] == "U" && rna[j] == "A") || (rna[i] == "G" && rna[j] == "U") || (rna[i] == "U" && rna[j] == "G")) ? 0.45 : 0.0
                let dg = stackSum + hairpinLoopPenalty(loopLen) + terminalAU
                if dg < bestDG { bestDG = dg }
            }
        }
        return (bestDG * 100.0).rounded() / 100.0
    }

    /// 扫描生物调控隐患基序：隐匿剪接供体/受体、提前 Poly(A)、原核伪 SD、CpG/UpA 免疫二核苷酸密度与长反向重复
    public static func scanBiologicalMotifs(dna: String, host: CodonHostOrganism) -> [String] {
        let s = BioSequence.clean(dna)
        guard s.count >= 12 else { return [] }
        var findings: [String] = []
        if host == .eColi {
            if s.contains("AGGAGG") || s.contains("AAGGAG") {
                findings.append(L10n.t("检出内部原核伪 Shine-Dalgarno (AGGAGG/AAGGAG) 基序，可能导致异常内部起始翻译"))
            }
            if let re = try? NSRegularExpression(pattern: "TTGACA[ACGT]{15,19}TATAAT"),
               re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil {
                findings.append(L10n.t("检出内部原核伪 σ70 启动子 (-35 TTGACA + 15–19 bp + -10 TATAAT) 基序"))
            }
        } else {
            if s.contains("AGGTAAGT") || s.contains("CAGGTAAG") || s.contains("CAGGTGAG") {
                findings.append(L10n.t("检出真核隐匿 5' 剪接供体基序 (AGGTAAGT/CAGGTAAG/CAGGTGAG)，存在异常剪接风险"))
            }
            if let reAcc = try? NSRegularExpression(pattern: "[CT]{6,}[ACGT]{0,2}[CT]AG"),
               reAcc.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil {
                findings.append(L10n.t("检出真核隐匿 3' 剪接受体基序 (多嘧啶区 + YAG)，存在异常剪接风险"))
            }
            if s.contains("AATAAA") || s.contains("ATTAAA") {
                findings.append(L10n.t("检出内部提前 Poly(A) 加尾信号 (AATAAA/ATTAAA)，可能导致 mRNA 截短"))
            }
            let chars = Array(s)
            var cpg = 0, upa = 0
            for i in 0..<(chars.count - 1) {
                if chars[i] == "C" && chars[i + 1] == "G" { cpg += 1 }
                if chars[i] == "T" && chars[i + 1] == "A" { upa += 1 }
            }
            let cpgRate = Double(cpg) * 100.0 / Double(chars.count)
            let upaRate = Double(upa) * 100.0 / Double(chars.count)
            if cpgRate > 8.0 {
                findings.append(L10n.tr("CpG 二核苷酸密度偏高 (\(String(format: "%.1f%%", cpgRate)))，可能诱发 ZAP/TLR9 固有免疫沉默", "Elevated CpG dinucleotide density (\(String(format: "%.1f%%", cpgRate))); potential ZAP/TLR9 innate immune silencing"))
            }
            if upaRate > 7.5 {
                findings.append(L10n.tr("UpA (TA) 二核苷酸密度偏高 (\(String(format: "%.1f%%", upaRate)))，可能增加 RNase L 降解敏感性", "Elevated UpA (TA) dinucleotide density (\(String(format: "%.1f%%", upaRate))); increased RNase L cleavage risk"))
            }
        }
        let n = s.count
        if n >= 24 {
            let irStem = 10
            var foundIR = false
            for i in 0...(n - 2 * irStem) where !foundIR {
                let stemStart = s.index(s.startIndex, offsetBy: i)
                let stemEnd = s.index(stemStart, offsetBy: irStem)
                let rcStem = BioSequence.reverseComplement(String(s[stemStart..<stemEnd]))
                let searchLo = i + irStem + 3
                let searchHi = min(n - irStem, i + irStem + 20)
                if searchLo <= searchHi {
                    for j in searchLo...searchHi {
                        let jStart = s.index(s.startIndex, offsetBy: j)
                        let jEnd = s.index(jStart, offsetBy: irStem)
                        if String(s[jStart..<jEnd]) == rcStem {
                            foundIR = true
                            break
                        }
                    }
                }
            }
            if foundIR {
                findings.append(L10n.t("检出 ≥10 bp 局部长反向重复 (Inverted Repeat)，存在基因合成失败或强发夹结构风险"))
            }
        }
        return findings
    }

    /// CoCoPUTs / 高表达基因参考集 (HEG) 完整 64 密码子相对适应度权重（全 5 宿主覆盖，缺失密码子按宿主基础表补全）
    public static func highExpressionCodonWeights(for host: CodonHostOrganism) -> [String: Double] {
        var base = host.relativeAdaptivenessTable
        let overrides: [String: Double]
        switch host {
        case .eColi:
            overrides = [
                "CTG": 1.00, "CCG": 1.00, "ACC": 1.00, "CAG": 1.00, "GAA": 1.00, "AAA": 1.00,
                "GGT": 1.00, "GGC": 0.96, "CGT": 1.00, "CGC": 0.72, "GTT": 1.00, "GTA": 0.50,
                "ATC": 1.00, "ATT": 0.48, "TTC": 1.00, "TTT": 0.34, "TAC": 1.00, "TAT": 0.36,
                "AAC": 1.00, "AAT": 0.25, "GAC": 1.00, "GAT": 0.55, "CAC": 1.00, "CAT": 0.35,
                "TCT": 1.00, "TCC": 0.90, "AGC": 0.72, "GCG": 1.00, "GCT": 0.95, "GCC": 0.60,
                "TGC": 1.00, "TGT": 0.65, "ATG": 1.00, "TGG": 1.00, "TAA": 1.00
            ]
        case .yeast:
            overrides = [
                "TTG": 1.00, "GCT": 1.00, "GGT": 1.00, "AGA": 1.00, "GTT": 1.00, "GTC": 0.90,
                "ATT": 1.00, "ATC": 0.92, "TTC": 1.00, "TAC": 1.00, "AAC": 1.00, "GAC": 1.00,
                "GAA": 1.00, "AAG": 1.00, "CAA": 1.00, "CAC": 1.00, "CCA": 1.00, "TCT": 1.00,
                "TCC": 0.92, "ACT": 1.00, "ACC": 0.90, "TGT": 1.00, "ATG": 1.00, "TGG": 1.00, "TAA": 1.00
            ]
        default:
            overrides = [
                "CTG": 1.00, "GTG": 1.00, "GCC": 1.00, "GGC": 1.00, "CAG": 1.00, "GAG": 1.00,
                "AAG": 1.00, "ACC": 1.00, "CCC": 1.00, "TCC": 1.00, "AGC": 0.92, "ATC": 1.00,
                "TTC": 1.00, "TAC": 1.00, "AAC": 1.00, "GAC": 1.00, "CAC": 1.00, "TGC": 1.00,
                "CGC": 1.00, "CGG": 0.95, "AGA": 0.88, "AGG": 0.88, "ATG": 1.00, "TGG": 1.00, "TGA": 1.00
            ]
        }
        for (k, v) in overrides { base[k] = v }
        return base
    }

    private static func scoreFivePrimePrefix(baseBuffer: [Character], wTable: [String: Double], codon: String, upstreamUTR: String = "GCCACC") -> Double {
        let prefixSeq = String(baseBuffer.prefix(min(45, baseBuffer.count)))
        let dg = calcRNA5PrimeHairpinDG(dnaSeq: prefixSeq, upstreamUTR: upstreamUTR)
        let fit = wTable[codon] ?? 0.5
        // 目标是 RNA ΔG37 >= -3.0 kcal/mol，再以适应度破平
        let dgScore = min(0.0, dg) * 100.0
        return dgScore + fit * 1.5
    }

    private static func localObjective(
        codonIdx: Int,
        codon: String,
        baseBuffer: [Character],
        motifs: [ResolvedMotif],
        config: OptimizationConfig,
        wTable: [String: Double],
        kmerCounts: [String: Int]?,
        prefixGC: [Int]?
    ) -> Double {
        let n = baseBuffer.count
        let bStart = codonIdx * 3
        let bEnd = bStart + 2

        // 1. 禁区酶切位点与 Motif 局部窗口检查
        let maxMotifLen = max(8, motifs.map(\.length).max() ?? 8)
        let mWinLo = max(0, bStart - maxMotifLen)
        let mWinHi = min(n, bEnd + maxMotifLen + 1)
        let localMotifs = findMotifHits(in: baseBuffer, motifs: motifs, range: mWinLo..<mWinHi)
        var penalty = Double(localMotifs.count) * 10_000.0

        // 2. 连续同聚物检查
        let hpLo = max(0, bStart - config.maxHomopolymerLength - 2)
        let hpHi = min(n, bEnd + config.maxHomopolymerLength + 3)
        let localHPs = findHomopolymers(in: baseBuffer, minLen: config.maxHomopolymerLength, range: hpLo..<hpHi)
        for hp in localHPs {
            let excess = max(1, (hp.end0 - hp.start0 + 1) - config.maxHomopolymerLength + 1)
            penalty += Double(excess) * 1_500.0
        }

        // 3. 局部 50 bp GC 窗检查（严格对齐 3 的倍数相位，O(w) 局部滑动计数，消除 O(N^2) 全长重建）
        let w = min(n, config.gcWindowSizeBp)
        if w >= 12 {
            let rawMin = max(0, bEnd - w + 1)
            let winStartMin = ((rawMin + 2) / 3) * 3
            let winStartMax = min(n - w, bStart)
            if winStartMin <= winStartMax {
                let midTarget = 0.5 * (config.minWindowGC + config.maxWindowGC)
                var worstDev = 0.0
                var sumMidDist = 0.0
                var winCount = 0
                if let pGC = prefixGC {
                    for s in stride(from: winStartMin, through: winStartMax, by: 3) {
                        let gc = Double(pGC[s + w] - pGC[s]) / Double(w)
                        if gc < config.minWindowGC { worstDev = max(worstDev, config.minWindowGC - gc) }
                        else if gc > config.maxWindowGC { worstDev = max(worstDev, gc - config.maxWindowGC) }
                        sumMidDist += abs(gc - midTarget)
                        winCount += 1
                    }
                } else {
                    var curGC = 0
                    for p in winStartMin..<(winStartMin + w) {
                        if baseBuffer[p] == "G" || baseBuffer[p] == "C" { curGC += 1 }
                    }
                    var s = winStartMin
                    while s <= winStartMax {
                        let gc = Double(curGC) / Double(w)
                        if gc < config.minWindowGC { worstDev = max(worstDev, config.minWindowGC - gc) }
                        else if gc > config.maxWindowGC { worstDev = max(worstDev, gc - config.maxWindowGC) }
                        sumMidDist += abs(gc - midTarget)
                        winCount += 1
                        if s + 3 <= winStartMax {
                            for t in 0..<3 {
                                if baseBuffer[s + t] == "G" || baseBuffer[s + t] == "C" { curGC -= 1 }
                                if baseBuffer[s + w + t] == "G" || baseBuffer[s + w + t] == "C" { curGC += 1 }
                            }
                        }
                        s += 3
                    }
                }
                penalty += worstDev * 2_500.0
                if worstDev > 0 {
                    penalty += (sumMidDist / Double(max(1, winCount))) * 150.0
                }
            }
        }

        // 4. 局部直接重复序列检查（跨越此密码子的 k-mer 是否也在序列他处出现）
        let k = config.maxDirectRepeatLength
        if n >= k * 2 {
            let kLo = max(0, bStart - k + 1)
            let kHi = min(n - k, bEnd)
            if kLo <= kHi {
                let table = kmerCounts ?? buildRepeatCounts(baseBuffer: baseBuffer, k: k)
                for pos in kLo...kHi {
                    let sub = String(baseBuffer[pos..<(pos + k)])
                    if (table[sub] ?? 0) >= 2 {
                        penalty += 400.0
                    }
                }
            }
        }

        // 5. 前 45 bp RNA Turner 2004 二级结构护栏（含上游 Kozak/RBS 5'-UTR 上下文）
        if config.optimizeFivePrimeStructure && codonIdx < 15 {
            let prefixSeq = String(baseBuffer.prefix(min(45, n)))
            let utr = (config.host == .eColi) ? "AGGAGGTA" : "GCCACC"
            let dg = calcRNA5PrimeHairpinDG(dnaSeq: prefixSeq, upstreamUTR: utr)
            if dg < -3.0 {
                penalty += (-3.0 - dg) * 180.0
            }
        }

        // 5b. 局部生物调控隐患基序（隐匿剪接供体/提前 Poly(A)/原核伪 SD）软惩罚
        let bioLo = max(0, bStart - 8)
        let bioHi = min(n, bEnd + 9)
        let bioWin = String(baseBuffer[bioLo..<bioHi])
        if config.host == .eColi {
            if bioWin.contains("AGGAGG") || bioWin.contains("AAGGAG") { penalty += 600.0 }
        } else {
            if bioWin.contains("AATAAA") || bioWin.contains("ATTAAA") || bioWin.contains("AGGTAAGT") || bioWin.contains("CAGGTAAG") || bioWin.contains("CAGGTGAG") {
                penalty += 600.0
            }
        }

        // 6. 宿主 CAI 适应度奖励 & 极端稀有密码子软惩罚
        let fitness = wTable[codon] ?? 0.5
        let rarePenalty = (fitness < 0.12) ? 80.0 : 0.0
        return -penalty - rarePenalty + fitness * 12.0
    }

    private static func buildConstraintChecks(
        optimizedDNA: String,
        config: OptimizationConfig,
        motifs: [ResolvedMotif]
    ) -> [ConstraintCheckItem] {
        let chars = Array(optimizedDNA)
        var checks: [ConstraintCheckItem] = []

        // 1. 禁区酶切位点与 Motif
        let motifHits = findMotifHits(in: chars, motifs: motifs)
        let motifDetail = motifHits.isEmpty
            ? L10n.tr("未检出 \(config.forbiddenEnzymeNames.joined(separator: "/")) 等禁用酶切位点与禁忌序列", "Zero forbidden restriction sites (\(config.forbiddenEnzymeNames.joined(separator: "/"))) or blacklisted motifs")
            : L10n.tr("残留 \(motifHits.count) 处位点：", "\(motifHits.count) remaining site(s): ") + motifHits.prefix(4).map { "\($0.name)@\($0.start0 + 1)" }.joined(separator: ", ")
        checks.append(
            ConstraintCheckItem(
                id: "motifs",
                title: L10n.t("禁用酶切位点与禁忌 Motif 清零"),
                passed: motifHits.isEmpty,
                detail: motifDetail,
                violationPositions1Based: motifHits.map { $0.start0 + 1 }
            )
        )

        // 2. 连续同聚物
        let hps = findHomopolymers(in: chars, minLen: config.maxHomopolymerLength)
        let hpDetail = hps.isEmpty
            ? L10n.tr("全长无 ≥\(config.maxHomopolymerLength) bp 连续单碱基同聚物", "No homopolymer runs >= \(config.maxHomopolymerLength) bp")
            : L10n.tr("残留 \(hps.count) 处长同聚物：", "\(hps.count) long homopolymer(s): ") + hps.prefix(4).map { "@\($0.start0 + 1)(\($0.end0 - $0.start0 + 1)bp)" }.joined(separator: ", ")
        checks.append(
            ConstraintCheckItem(
                id: "homopolymer",
                title: L10n.tr("同聚物控制 (< \(config.maxHomopolymerLength) bp)", "Homopolymer Control (< \(config.maxHomopolymerLength) bp)"),
                passed: hps.isEmpty,
                detail: hpDetail,
                violationPositions1Based: hps.map { $0.start0 + 1 }
            )
        )

        // 3. 局部滑动窗 GC%
        let profile = slidingGCProfile(optimizedDNA, windowSize: config.gcWindowSizeBp, step: 3)
        let minPct = config.minWindowGC * 100.0
        let maxPct = config.maxWindowGC * 100.0
        let badWindows = profile.filter { $0.gcPercent < minPct || $0.gcPercent > maxPct }
        let obsMin = profile.map(\.gcPercent).min() ?? 0
        let obsMax = profile.map(\.gcPercent).max() ?? 0
        let gcDetail = badWindows.isEmpty
            ? String(format: L10n.tr("全部 %d bp 滑动窗 GC 处于 %.1f%%–%.1f%%（目标 %.0f%%–%.0f%%）", "All %d-bp sliding-window GC% within %.1f%%–%.1f%% (target %.0f%%–%.0f%%)"), config.gcWindowSizeBp, obsMin, obsMax, minPct, maxPct)
            : String(format: L10n.tr("%d 个滑动窗越界（实测 %.1f%%–%.1f%% vs 目标 %.0f%%–%.0f%%）", "%d window(s) out of bounds (observed %.1f%%–%.1f%% vs target %.0f%%–%.0f%%)"), badWindows.count, obsMin, obsMax, minPct, maxPct)
        checks.append(
            ConstraintCheckItem(
                id: "window_gc",
                title: L10n.tr("局部 \(config.gcWindowSizeBp) bp 滑动窗 GC (\(Int(minPct))%–\(Int(maxPct))%)", "Local \(config.gcWindowSizeBp)-bp Window GC (\(Int(minPct))%–\(Int(maxPct))%)"),
                passed: badWindows.isEmpty,
                detail: gcDetail,
                violationPositions1Based: badWindows.map(\.centerBp)
            )
        )

        // 4. 直接重复序列
        let repeats = findDirectRepeats(in: chars, repeatLen: config.maxDirectRepeatLength)
        let repDetail = repeats.isEmpty
            ? L10n.tr("未发现长度 ≥\(config.maxDirectRepeatLength) bp 的内部直接重复片段", "No internal direct repeats >= \(config.maxDirectRepeatLength) bp")
            : L10n.tr("发现 \(repeats.count) 处 ≥\(config.maxDirectRepeatLength) bp 直接重复：", "\(repeats.count) direct repeat(s) >= \(config.maxDirectRepeatLength) bp: ") + repeats.prefix(3).map { "\($0.seq)@\($0.start0 + 1)" }.joined(separator: ", ")
        checks.append(
            ConstraintCheckItem(
                id: "repeats",
                title: L10n.tr("内部重复序列 (< \(config.maxDirectRepeatLength) bp)", "Direct Repeats (< \(config.maxDirectRepeatLength) bp)"),
                passed: repeats.isEmpty,
                detail: repDetail,
                violationPositions1Based: repeats.map { $0.start0 + 1 }
            )
        )

        // 5. 5' 端前 45 bp RNA Turner 2004 二级结构（含 5'-UTR 上下文与 G:U 摇摆配对）
        let upstream5UTR = (config.host == .eColi) ? "AGGAGGTA" : "GCCACC"
        let fivePrimeDG = calcRNA5PrimeHairpinDG(dnaSeq: String(optimizedDNA.prefix(45)), upstreamUTR: upstream5UTR)
        let structPassed = !config.optimizeFivePrimeStructure || fivePrimeDG >= -3.0
        checks.append(
            ConstraintCheckItem(
                id: "five_prime_hairpin",
                title: L10n.t("5' 起始区前 45 bp 发夹稳定性"),
                passed: structPassed,
                detail: String(format: L10n.tr("5' 端前 45 bp RNA 发夹 ΔG37 = %.2f kcal/mol（建议 ≥ -3.0 kcal/mol）", "5' first 45-bp RNA hairpin ΔG37 = %.2f kcal/mol (>= -3.0 kcal/mol recommended)"), fivePrimeDG),
                violationPositions1Based: structPassed ? [] : [1]
            )
        )

        // 6. 生物调控隐患基序扫描（隐匿剪接供体/受体、提前 Poly(A)、原核伪 SD/σ70、长反向重复）
        let bioHazards = scanBiologicalMotifs(dna: optimizedDNA, host: config.host)
        checks.append(
            ConstraintCheckItem(
                id: "biological_motifs",
                title: L10n.t("生物调控隐患基序审查"),
                passed: bioHazards.isEmpty,
                detail: bioHazards.isEmpty ? L10n.t("未检出隐匿剪接位点、提前 Poly(A)、伪 SD 或长反向重复") : bioHazards.joined(separator: "；"),
                violationPositions1Based: bioHazards.isEmpty ? [] : [1]
            )
        )

        return checks
    }
}
