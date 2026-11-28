import Foundation

public enum HDRDonorFormat: String, Codable, CaseIterable, Sendable {
    case ssODN = "ssODN"
    case dsDNAPlasmid = "dsDNAPlasmid"

    public var defaultArmLengthBp: Int {
        switch self {
        case .ssODN: return 60
        case .dsDNAPlasmid: return 600
        }
    }
}

public enum HDRBlockingStrategy: String, Codable, Sendable {
    case pamSynonymous = "pam_synonymous"
    case seedSynonymousFallback = "seed_synonymous_fallback"
    case pamNonCoding = "pam_non_coding"
    case alreadyDisruptedByEdit = "already_disrupted_by_edit"
    case failedToBlock = "failed_to_block"
}

public enum RFLPMode: String, Codable, Sendable {
    case created = "created"
    case destroyed = "destroyed"
    case none = "none"
}

public enum HDRDonorError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput(String)
    case sgRNANotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return msg
        case .sgRNANotFound(let msg): return msg
        }
    }
}

public struct SilentMutationRecord: Codable, Equatable, Sendable {
    public let position0Based: Int
    public let position1Based: Int
    public let originalBase: String
    public let mutatedBase: String
    public let reason: String
    public let codonBefore: String?
    public let codonAfter: String?
    public let aminoAcid: String?

    public init(
        position0Based: Int,
        position1Based: Int,
        originalBase: String,
        mutatedBase: String,
        reason: String,
        codonBefore: String? = nil,
        codonAfter: String? = nil,
        aminoAcid: String? = nil
    ) {
        self.position0Based = position0Based
        self.position1Based = position1Based
        self.originalBase = originalBase
        self.mutatedBase = mutatedBase
        self.reason = reason
        self.codonBefore = codonBefore
        self.codonAfter = codonAfter
        self.aminoAcid = aminoAcid
    }
}

public struct RFLPDesignResult: Codable, Equatable, Sendable {
    public let mode: RFLPMode
    public let enzymeName: String
    public let recognitionSite: String
    public let topCutOffset: Int
    public let wtAmpliconBandsBp: [Int]
    public let hdrAmpliconBandsBp: [Int]
    public let silentMutations: [SilentMutationRecord]
    public let note: String

    public init(
        mode: RFLPMode,
        enzymeName: String,
        recognitionSite: String,
        topCutOffset: Int,
        wtAmpliconBandsBp: [Int],
        hdrAmpliconBandsBp: [Int],
        silentMutations: [SilentMutationRecord],
        note: String
    ) {
        self.mode = mode
        self.enzymeName = enzymeName
        self.recognitionSite = recognitionSite
        self.topCutOffset = topCutOffset
        self.wtAmpliconBandsBp = wtAmpliconBandsBp
        self.hdrAmpliconBandsBp = hdrAmpliconBandsBp
        self.silentMutations = silentMutations
        self.note = note
    }
}

public struct OutOutPCRDesign: Codable, Equatable, Sendable {
    public let forwardPrimer: PrimerItem
    public let reversePrimer: PrimerItem
    public let forwardStart0Based: Int
    public let forwardEnd0Based: Int
    public let reverseStart0Based: Int
    public let reverseEnd0Based: Int
    public let wtAmpliconLengthBp: Int
    public let hdrAmpliconLengthBp: Int
    public let wtAmpliconSequence: String
    public let hdrAmpliconSequence: String
    public let leftMarginFromArmBp: Int
    public let rightMarginFromArmBp: Int

    public init(
        forwardPrimer: PrimerItem,
        reversePrimer: PrimerItem,
        forwardStart0Based: Int,
        forwardEnd0Based: Int,
        reverseStart0Based: Int,
        reverseEnd0Based: Int,
        wtAmpliconLengthBp: Int,
        hdrAmpliconLengthBp: Int,
        wtAmpliconSequence: String,
        hdrAmpliconSequence: String,
        leftMarginFromArmBp: Int,
        rightMarginFromArmBp: Int
    ) {
        self.forwardPrimer = forwardPrimer
        self.reversePrimer = reversePrimer
        self.forwardStart0Based = forwardStart0Based
        self.forwardEnd0Based = forwardEnd0Based
        self.reverseStart0Based = reverseStart0Based
        self.reverseEnd0Based = reverseEnd0Based
        self.wtAmpliconLengthBp = wtAmpliconLengthBp
        self.hdrAmpliconLengthBp = hdrAmpliconLengthBp
        self.wtAmpliconSequence = wtAmpliconSequence
        self.hdrAmpliconSequence = hdrAmpliconSequence
        self.leftMarginFromArmBp = leftMarginFromArmBp
        self.rightMarginFromArmBp = rightMarginFromArmBp
    }
}

public struct HDRDonorRequest: Codable, Sendable {
    public var referenceSequence: String
    public var sgRNASequence: String
    public var strand: String
    public var editStart0Based: Int
    public var editEnd0Based: Int
    public var replacementSequence: String
    public var donorFormat: HDRDonorFormat
    public var leftArmLengthBp: Int?
    public var rightArmLengthBp: Int?
    public var cdsStart1Based: Int?
    public var cdsEnd1Based: Int?
    public var cdsStrand: String
    public var cdsFrameOffset: Int?
    public var autoDetectCDS: Bool
    public var asymmetricRichardsonSSODN: Bool
    public var enableRFLP: Bool
    public var rflpSearchRadiusBp: Int
    public var outOutMarginBp: Int
    public var primerTargetTm: Double
    public var donorName: String

    public init(
        referenceSequence: String,
        sgRNASequence: String,
        strand: String = "+",
        editStart0Based: Int,
        editEnd0Based: Int,
        replacementSequence: String,
        donorFormat: HDRDonorFormat = .ssODN,
        leftArmLengthBp: Int? = nil,
        rightArmLengthBp: Int? = nil,
        cdsStart1Based: Int? = nil,
        cdsEnd1Based: Int? = nil,
        cdsStrand: String = "+",
        cdsFrameOffset: Int? = nil,
        autoDetectCDS: Bool = true,
        asymmetricRichardsonSSODN: Bool = false,
        enableRFLP: Bool = false,
        rflpSearchRadiusBp: Int = 15,
        outOutMarginBp: Int = 100,
        primerTargetTm: Double = 60.0,
        donorName: String = "HDR_Donor"
    ) {
        self.referenceSequence = referenceSequence
        self.sgRNASequence = sgRNASequence
        self.strand = strand
        self.editStart0Based = editStart0Based
        self.editEnd0Based = editEnd0Based
        self.replacementSequence = replacementSequence
        self.donorFormat = donorFormat
        self.leftArmLengthBp = leftArmLengthBp
        self.rightArmLengthBp = rightArmLengthBp
        self.cdsStart1Based = cdsStart1Based
        self.cdsEnd1Based = cdsEnd1Based
        self.cdsStrand = (cdsStrand == "-") ? "-" : "+"
        self.cdsFrameOffset = cdsFrameOffset
        self.autoDetectCDS = autoDetectCDS
        self.asymmetricRichardsonSSODN = asymmetricRichardsonSSODN
        self.enableRFLP = enableRFLP
        self.rflpSearchRadiusBp = rflpSearchRadiusBp
        self.outOutMarginBp = outOutMarginBp
        self.primerTargetTm = primerTargetTm
        self.donorName = donorName
    }
}

public struct HDRDonorDesignReport: Codable, Equatable, Sendable {
    public let donorFormat: HDRDonorFormat
    public let sgRNASequence: String
    public let strand: String
    public let wtCutIndex0Based: Int
    public let cutToEditDistanceBp: Int
    public let wtPamStart0Based: Int
    public let wtPamSequence: String
    public let isInCDS: Bool
    public let cdsStrand: String
    public let cdsStart1Based: Int?
    public let cdsEnd1Based: Int?
    public let cdsAutoDetected: Bool
    public let proteinBeforeBlocking: String
    public let proteinAfterBlocking: String
    public let aminoAcidConserved: Bool
    public let blockingStrategy: HDRBlockingStrategy
    public let blockingMutations: [SilentMutationRecord]
    public let editedPamSequence: String
    public let pamStillIntact: Bool
    public let cas9RecutBlocked: Bool
    public let leftHomologyArm: String
    public let insertPayload: String
    public let rightHomologyArm: String
    public let leftArmLengthBp: Int
    public let rightArmLengthBp: Int
    public let donorSequence: String
    public let donorLengthBp: Int
    public let donorStrandOrientation: String
    public let finalEditedLocusSequence: String
    public let rflp: RFLPDesignResult?
    public let outOutPCR: OutOutPCRDesign?
    public let warnings: [String]
}

/// CRISPR Knock-in HDR Donor 模板、PAM/Seed 同义阻断突变、可选 RFLP 鉴定酶及 Out-Out PCR 分型引物设计引擎
public enum HDRDonorEngine {

    private static let codonToAA: [String: String] = [
        "TTT": "F", "TTC": "F", "TTA": "L", "TTG": "L",
        "CTT": "L", "CTC": "L", "CTA": "L", "CTG": "L",
        "ATT": "I", "ATC": "I", "ATA": "I", "ATG": "M",
        "GTT": "V", "GTC": "V", "GTA": "V", "GTG": "V",
        "TCT": "S", "TCC": "S", "TCA": "S", "TCG": "S",
        "CCT": "P", "CCC": "P", "CCA": "P", "CCG": "P",
        "ACT": "T", "ACC": "T", "ACA": "T", "ACG": "T",
        "GCT": "A", "GCC": "A", "GCA": "A", "GCG": "A",
        "TAT": "Y", "TAC": "Y", "TAA": "*", "TAG": "*",
        "CAT": "H", "CAC": "H", "CAA": "Q", "CAG": "Q",
        "AAT": "N", "AAC": "N", "AAA": "K", "AAG": "K",
        "GAT": "D", "GAC": "D", "GAA": "E", "GAG": "E",
        "TGT": "C", "TGC": "C", "TGA": "*", "TGG": "W",
        "CGT": "R", "CGC": "R", "CGA": "R", "CGG": "R",
        "AGT": "S", "AGC": "S", "AGA": "R", "AGG": "R",
        "GGT": "G", "GGC": "G", "GGA": "G", "GGG": "G"
    ]

    private static let preferredCodonsByAA: [String: [String]] = [
        "A": ["GCC", "GCT", "GCA", "GCG"],
        "C": ["TGC", "TGT"],
        "D": ["GAC", "GAT"],
        "E": ["GAG", "GAA"],
        "F": ["TTC", "TTT"],
        "G": ["GGC", "GGT", "GGA", "GGG"],
        "H": ["CAC", "CAT"],
        "I": ["ATC", "ATT", "ATA"],
        "K": ["AAG", "AAA"],
        "L": ["CTG", "CTC", "CTT", "TTG", "TTA", "CTA"],
        "M": ["ATG"],
        "N": ["AAC", "AAT"],
        "P": ["CCC", "CCT", "CCA", "CCG"],
        "Q": ["CAG", "CAA"],
        "R": ["CGC", "CGT", "AGG", "AGA", "CGG", "CGA"],
        "S": ["AGC", "TCC", "TCT", "AGT", "TCA", "TCG"],
        "T": ["ACC", "ACT", "ACA", "ACG"],
        "V": ["GTG", "GTC", "GTT", "GTA"],
        "W": ["TGG"],
        "Y": ["TAC", "TAT"],
        "*": ["TGA", "TAA", "TAG"]
    ]

    public struct RFLPEnzymeSpec: Sendable, Equatable {
        public let name: String
        public let site: String
        public let topCutOffset: Int
    }

    public static let rflpCandidateEnzymes: [RFLPEnzymeSpec] = [
        RFLPEnzymeSpec(name: "EcoRI", site: "GAATTC", topCutOffset: 1),
        RFLPEnzymeSpec(name: "BamHI", site: "GGATCC", topCutOffset: 1),
        RFLPEnzymeSpec(name: "HindIII", site: "AAGCTT", topCutOffset: 1),
        RFLPEnzymeSpec(name: "XhoI", site: "CTCGAG", topCutOffset: 1),
        RFLPEnzymeSpec(name: "SalI", site: "GTCGAC", topCutOffset: 1),
        RFLPEnzymeSpec(name: "NheI", site: "GCTAGC", topCutOffset: 1),
        RFLPEnzymeSpec(name: "SpeI", site: "ACTAGT", topCutOffset: 1),
        RFLPEnzymeSpec(name: "XbaI", site: "TCTAGA", topCutOffset: 1),
        RFLPEnzymeSpec(name: "AgeI", site: "ACCGGT", topCutOffset: 1),
        RFLPEnzymeSpec(name: "NcoI", site: "CCATGG", topCutOffset: 1),
        RFLPEnzymeSpec(name: "KpnI", site: "GGTACC", topCutOffset: 5),
        RFLPEnzymeSpec(name: "PstI", site: "CTGCAG", topCutOffset: 5),
        RFLPEnzymeSpec(name: "SacI", site: "GAGCTC", topCutOffset: 5),
        RFLPEnzymeSpec(name: "EcoRV", site: "GATATC", topCutOffset: 3),
        RFLPEnzymeSpec(name: "SmaI", site: "CCCGGG", topCutOffset: 3),
        RFLPEnzymeSpec(name: "StuI", site: "AGGCCT", topCutOffset: 3),
        RFLPEnzymeSpec(name: "BglII", site: "AGATCT", topCutOffset: 1),
        RFLPEnzymeSpec(name: "ClaI", site: "ATCGAT", topCutOffset: 2),
        RFLPEnzymeSpec(name: "PvuII", site: "CAGCTG", topCutOffset: 3),
        RFLPEnzymeSpec(name: "ScaI", site: "AGTACT", topCutOffset: 3)
    ]

    public static func detectCDSRegion(
        in referenceSequence: String,
        coveringIndex0Based cutIndex0: Int,
        minLengthBp: Int = 90
    ) -> (start0Based: Int, end0Based: Int)? {
        let chars = Array(BioSequence.clean(referenceSequence)).map { String($0) }
        let n = chars.count
        guard n >= minLengthBp else { return nil }

        var bestStart: Int?
        var bestEnd: Int?
        var bestLen = -1

        for frame in 0..<3 {
            var pos = frame
            while pos + 3 <= n {
                let codon = chars[pos] + chars[pos + 1] + chars[pos + 2]
                if codon == "ATG" && pos <= cutIndex0 {
                    var endPos = pos + 3
                    var hitStop = false
                    while endPos + 3 <= n {
                        let c = chars[endPos] + chars[endPos + 1] + chars[endPos + 2]
                        if c == "TAA" || c == "TAG" || c == "TGA" {
                            endPos += 3
                            hitStop = true
                            break
                        }
                        endPos += 3
                    }
                    if !hitStop {
                        endPos = pos + ((n - pos) / 3) * 3
                    }
                    let orfLen = endPos - pos
                    if pos <= cutIndex0 && cutIndex0 < endPos && orfLen >= minLengthBp {
                        if orfLen > bestLen || (orfLen == bestLen && pos < (bestStart ?? Int.max)) {
                            bestLen = orfLen
                            bestStart = pos
                            bestEnd = endPos
                        }
                    }
                }
                pos += 3
            }
        }

        if let s = bestStart, let e = bestEnd {
            return (s, e)
        }
        return nil
    }

    /// 支持正向链与反向互补链 (-) 的双链 CDS 识别（双链并行扫描并择优选取最长覆盖 ORF）
    public static func detectCDSRegionWithStrand(
        in referenceSequence: String,
        coveringIndex0Based cutIndex0: Int,
        minLengthBp: Int = 90
    ) -> (start0Based: Int, end0Based: Int, strand: String)? {
        let clean = BioSequence.clean(referenceSequence)
        let n = clean.count
        guard n >= minLengthBp else { return nil }
        let fwd = detectCDSRegion(in: clean, coveringIndex0Based: cutIndex0, minLengthBp: minLengthBp)
        let rc = BioSequence.reverseComplement(clean)
        let rcCut = max(0, min(n - 1, n - 1 - cutIndex0))
        let revRaw = detectCDSRegion(in: rc, coveringIndex0Based: rcCut, minLengthBp: minLengthBp)
        let rev: (start0Based: Int, end0Based: Int)? = revRaw.map { (n - $0.end0Based, n - $0.start0Based) }
        switch (fwd, rev) {
        case let (f?, r?):
            let fLen = f.end0Based - f.start0Based
            let rLen = r.end0Based - r.start0Based
            return (rLen > fLen) ? (r.start0Based, r.end0Based, "-") : (f.start0Based, f.end0Based, "+")
        case let (f?, nil):
            return (f.start0Based, f.end0Based, "+")
        case let (nil, r?):
            return (r.start0Based, r.end0Based, "-")
        case (nil, nil):
            return nil
        }
    }

    public static func translateCDS(_ sequence: String, start0Based: Int, end0Based: Int, strand: String = "+") -> String {
        let clean = BioSequence.clean(sequence)
        let chars = Array(clean).map { String($0) }
        let s = max(0, start0Based)
        let e = min(chars.count, end0Based)
        guard s < e else { return "" }
        let sliceStr = chars[s..<e].joined()
        let codingStr = (strand == "-") ? BioSequence.reverseComplement(sliceStr) : sliceStr
        let cArr = Array(codingStr).map { String($0) }
        var aa = ""
        var i = 0
        while i + 3 <= cArr.count {
            let codon = cArr[i] + cArr[i + 1] + cArr[i + 2]
            aa += codonToAA[codon] ?? "X"
            i += 3
        }
        return aa
    }

    public static func predictLinearDigestBands(sequence: String, site: String, topCutOffset: Int) -> [Int] {
        let seqChars = Array(BioSequence.clean(sequence)).map { String($0) }
        let siteChars = Array(BioSequence.clean(site)).map { String($0) }
        let n = seqChars.count
        let m = siteChars.count
        guard n > 0 else { return [] }
        guard m > 0 && n >= m else { return [n] }

        var cuts: [Int] = []
        var i = 0
        while i + m <= n {
            var matched = true
            for k in 0..<m where seqChars[i + k] != siteChars[k] {
                matched = false
                break
            }
            if matched {
                cuts.append(i + topCutOffset)
                i += m
            } else {
                i += 1
            }
        }
        let sortedCuts = Array(Set(cuts)).filter { $0 > 0 && $0 < n }.sorted()
        let boundaries = [0] + sortedCuts + [n]
        var bands: [Int] = []
        for idx in 0..<(boundaries.count - 1) {
            let len = boundaries[idx + 1] - boundaries[idx]
            if len > 0 {
                bands.append(len)
            }
        }
        return bands.sorted(by: >)
    }

    public static func designHDRDonor(_ request: HDRDonorRequest) throws -> HDRDonorDesignReport {
        let ref = BioSequence.clean(request.referenceSequence)
        let guide = BioSequence.clean(request.sgRNASequence)
        let rep = BioSequence.clean(request.replacementSequence)
        let strand = request.strand.trimmingCharacters(in: .whitespacesAndNewlines)
        let L = ref.count

        guard L >= 25 else {
            throw HDRDonorError.invalidInput(L10n.t("参考序列长度不足（至少需要 25 bp）"))
        }
        guard guide.count >= 15 else {
            throw HDRDonorError.invalidInput(L10n.t("sgRNA protospacer 长度不足（至少需要 15 nt）"))
        }
        guard strand == "+" || strand == "-" else {
            throw HDRDonorError.invalidInput(L10n.t("strand 必须为 '+' 或 '-'"))
        }
        guard request.editStart0Based >= 0 && request.editEnd0Based >= request.editStart0Based && request.editEnd0Based <= L else {
            throw HDRDonorError.invalidInput(L10n.t("编辑坐标 [editStart0Based, editEnd0Based) 越界"))
        }

        let editStart0 = request.editStart0Based
        let editEnd0 = request.editEnd0Based
        let refChars = Array(ref).map { String($0) }
        let gLen = guide.count

        // 1. Locate sgRNA and PAM on WT reference
        let wtPamStart0: Int
        let wtCutIndex0: Int
        if strand == "+" {
            let guideChars = Array(guide).map { String($0) }
            var candidates: [(pos: Int, cut: Int, hasGG: Bool)] = []
            if L >= gLen + 3 {
                for p in 0...(L - gLen - 3) {
                    var ok = true
                    for k in 0..<gLen where refChars[p + k] != guideChars[k] {
                        ok = false
                        break
                    }
                    if ok {
                        let pamIdx = p + gLen
                        let hasGG = (refChars[pamIdx + 1] == "G" && refChars[pamIdx + 2] == "G")
                        candidates.append((p, pamIdx - 3, hasGG))
                    }
                }
            }
            let ggPool = candidates.filter(\.hasGG)
            let pool = ggPool.isEmpty ? candidates : ggPool
            guard let best = pool.min(by: { a, b in
                let da = abs(a.cut - editStart0)
                let db = abs(b.cut - editStart0)
                return da != db ? da < db : a.pos < b.pos
            }) else {
                throw HDRDonorError.sgRNANotFound(L10n.tr("在参考序列正链上未找到 sgRNA \(guide) 及 3' PAM", "sgRNA \(guide) with 3' PAM not found on sense strand"))
            }
            wtPamStart0 = best.pos + gLen
            wtCutIndex0 = best.cut
        } else {
            let rcGuide = BioSequence.reverseComplement(guide)
            let rcChars = Array(rcGuide).map { String($0) }
            var candidates: [(pos: Int, cut: Int, hasCC: Bool)] = []
            if L >= gLen + 3 {
                for p in 3...(L - gLen) {
                    var ok = true
                    for k in 0..<gLen where refChars[p + k] != rcChars[k] {
                        ok = false
                        break
                    }
                    if ok {
                        let pamIdx = p - 3
                        let hasCC = (refChars[pamIdx] == "C" && refChars[pamIdx + 1] == "C")
                        candidates.append((p, p + 3, hasCC))
                    }
                }
            }
            let ccPool = candidates.filter(\.hasCC)
            let pool = ccPool.isEmpty ? candidates : ccPool
            guard let best = pool.min(by: { a, b in
                let da = abs(a.cut - editStart0)
                let db = abs(b.cut - editStart0)
                return da != db ? da < db : a.pos < b.pos
            }) else {
                throw HDRDonorError.sgRNANotFound(L10n.tr("在参考序列负链上未找到 sgRNA \(guide) 反向互补及 5' CCN PAM", "Reverse-complement sgRNA \(guide) with 5' CCN PAM not found on antisense strand"))
            }
            wtPamStart0 = best.pos - 3
            wtCutIndex0 = best.cut
        }
        let wtPamSeq = refChars[wtPamStart0] + refChars[wtPamStart0 + 1] + refChars[wtPamStart0 + 2]

        // 2. Detect or validate CDS (supports forward/reverse strand & non-ATG internal exon frameOffset)
        var isInCDS = false
        var cdsAutoDetected = false
        var resolvedCdsStrand = (request.cdsStrand == "-") ? "-" : "+"
        var wtCdsStart0: Int?
        var wtCdsEnd0: Int?
        if let cs1 = request.cdsStart1Based, let ce1 = request.cdsEnd1Based {
            let s0 = cs1 - 1
            let e0 = ce1
            guard s0 >= 0 && e0 <= L && s0 + 3 <= e0 else {
                throw HDRDonorError.invalidInput(L10n.t("显式 CDS 区间 [cdsStart1Based, cdsEnd1Based] 非法或越界"))
            }
            if s0 <= wtCutIndex0 && wtCutIndex0 < e0 {
                isInCDS = true
                wtCdsStart0 = s0
                wtCdsEnd0 = e0
            }
        } else if let frameOff = request.cdsFrameOffset, frameOff >= 0 && frameOff <= 2 {
            let s0 = frameOff
            let e0 = s0 + ((L - s0) / 3) * 3
            if s0 <= wtCutIndex0 && wtCutIndex0 < e0 && e0 - s0 >= 9 {
                isInCDS = true
                wtCdsStart0 = s0
                wtCdsEnd0 = e0
            }
        } else if request.autoDetectCDS {
            if let detected = detectCDSRegionWithStrand(in: ref, coveringIndex0Based: wtCutIndex0) {
                isInCDS = true
                cdsAutoDetected = true
                wtCdsStart0 = detected.start0Based
                wtCdsEnd0 = detected.end0Based
                resolvedCdsStrand = detected.strand
            }
        }

        // 3. Apply intentional HDR replacement & coordinate mapping
        let delta = rep.count - (editEnd0 - editStart0)
        let repChars = Array(rep).map { String($0) }
        var editedChars = Array(refChars[0..<editStart0]) + repChars + Array(refChars[editEnd0..<L])

        func mapWTIndex(_ i: Int) -> Int {
            if i < editStart0 { return i }
            if i >= editEnd0 { return i + delta }
            return editStart0
        }

        let editedCdsStart0: Int
        let editedCdsEnd0: Int
        if isInCDS, let cs0 = wtCdsStart0, let ce0 = wtCdsEnd0 {
            editedCdsStart0 = cs0 <= editStart0 ? cs0 : (cs0 >= editEnd0 ? cs0 + delta : editStart0)
            editedCdsEnd0 = ce0 >= editEnd0 ? ce0 + delta : (ce0 <= editStart0 ? ce0 : editStart0 + rep.count)
        } else {
            editedCdsStart0 = 0
            editedCdsEnd0 = 0
        }

        let proteinBeforeBlocking = isInCDS
            ? translateCDS(editedChars.joined(), start0Based: editedCdsStart0, end0Based: editedCdsEnd0, strand: resolvedCdsStrand)
            : ""

        let cutToEditDistanceBp: Int = {
            if wtCutIndex0 >= editStart0 && wtCutIndex0 <= editEnd0 { return 0 }
            return min(abs(wtCutIndex0 - editStart0), abs(wtCutIndex0 - editEnd0))
        }()

        let editedPamStart0 = mapWTIndex(wtPamStart0)
        func isPamIntact(_ chars: [String]) -> Bool {
            guard editedPamStart0 >= 0 && editedPamStart0 + 3 <= chars.count else { return false }
            if strand == "+" {
                return chars[editedPamStart0 + 1] == "G" && chars[editedPamStart0 + 2] == "G"
            } else {
                return chars[editedPamStart0] == "C" && chars[editedPamStart0 + 1] == "C"
            }
        }

        /// 检测非典型 SpCas9 活性 PAM（正链 NAG/NGA，负链对应 CTN/TCN），防止阻断突变误引入仍可切割的次级 PAM
        func isNonCanonicalActivePam(_ chars: [String]) -> Bool {
            guard editedPamStart0 >= 0 && editedPamStart0 + 3 <= chars.count else { return false }
            if strand == "+" {
                let b1 = chars[editedPamStart0 + 1], b2 = chars[editedPamStart0 + 2]
                return (b1 == "A" && b2 == "G") || (b1 == "G" && b2 == "A")
            } else {
                let b0 = chars[editedPamStart0], b1 = chars[editedPamStart0 + 1]
                return (b0 == "C" && b1 == "T") || (b0 == "T" && b1 == "C")
            }
        }

        let pamCritIndices: [Int] = strand == "+"
            ? [editedPamStart0 + 1, editedPamStart0 + 2]
            : [editedPamStart0, editedPamStart0 + 1]
        let editLockedSet = Set(editStart0..<(editStart0 + rep.count))

        var warnings: [String] = []
        if cutToEditDistanceBp > 10 {
            warnings.append(L10n.tr(
                "DSB 切点至编辑位点距离为 \(cutToEditDistanceBp) bp（>10 bp），据 Paquet et al. (Nature 2016) HDR 效率将显著下降，强烈建议保留沉默阻断突变或改选更近的 sgRNA。",
                "DSB-to-edit distance is \(cutToEditDistanceBp) bp (>10 bp); per Paquet et al. (Nature 2016), HDR efficiency drops sharply—retain silent blocking mutations or choose a closer sgRNA."
            ))
        }
        var blockingMutations: [SilentMutationRecord] = []
        let blockingStrategy: HDRBlockingStrategy

        func complementBase(_ b: String) -> String {
            switch b {
            case "A": return "T"
            case "T": return "A"
            case "C": return "G"
            case "G": return "C"
            default: return b
            }
        }

        // Helper for 1-bp synonymous mutation inside editedChars (supports both + and - CDS strands)
        func try1bpSynonymousCandidatesAt(
            pos: Int,
            chars: [String],
            locked: Set<Int>,
            reason: String
        ) -> [(newBase: String, record: SilentMutationRecord)] {
            guard isInCDS, pos >= editedCdsStart0, pos < editedCdsEnd0, !locked.contains(pos) else {
                return []
            }
            let cStart: Int
            let offsetInCodon: Int
            let origCodon: String
            if resolvedCdsStrand == "+" {
                let rel = pos - editedCdsStart0
                cStart = editedCdsStart0 + (rel / 3) * 3
                guard cStart + 3 <= editedCdsEnd0 else { return [] }
                offsetInCodon = pos - cStart
                origCodon = chars[cStart] + chars[cStart + 1] + chars[cStart + 2]
            } else {
                let revRel = (editedCdsEnd0 - 1) - pos
                let revCodonIdx = revRel / 3
                let cEnd = editedCdsEnd0 - revCodonIdx * 3
                cStart = cEnd - 3
                guard cStart >= editedCdsStart0 && cEnd <= editedCdsEnd0 else { return [] }
                offsetInCodon = revRel % 3
                origCodon = complementBase(chars[cEnd - 1]) + complementBase(chars[cEnd - 2]) + complementBase(chars[cEnd - 3])
            }
            guard let aa = codonToAA[origCodon], let alts = preferredCodonsByAA[aa] else {
                return []
            }
            let origArr = Array(origCodon).map { String($0) }
            var out: [(newBase: String, record: SilentMutationRecord)] = []
            for altCodon in alts where altCodon != origCodon {
                let altArr = Array(altCodon).map { String($0) }
                var diffOffsets: [Int] = []
                for k in 0..<3 where altArr[k] != origArr[k] {
                    diffOffsets.append(k)
                }
                if diffOffsets.count == 1 && diffOffsets[0] == offsetInCodon {
                    let fwdNewBase = (resolvedCdsStrand == "+") ? altArr[offsetInCodon] : complementBase(altArr[offsetInCodon])
                    let rec = SilentMutationRecord(
                        position0Based: pos,
                        position1Based: pos + 1,
                        originalBase: chars[pos],
                        mutatedBase: fwdNewBase,
                        reason: reason,
                        codonBefore: origCodon,
                        codonAfter: altCodon,
                        aminoAcid: aa
                    )
                    out.append((fwdNewBase, rec))
                }
            }
            return out
        }

        func try1bpSynonymousAt(
            pos: Int,
            chars: [String],
            locked: Set<Int>,
            reason: String
        ) -> (newBase: String, record: SilentMutationRecord)? {
            try1bpSynonymousCandidatesAt(pos: pos, chars: chars, locked: locked, reason: reason).first
        }

        if !isPamIntact(editedChars) {
            blockingStrategy = .alreadyDisruptedByEdit
        } else if isInCDS {
            var brokePam = false
            var fallbackHit: (pos: Int, newBase: String, record: SilentMutationRecord)? = nil
            // 第一优先级：同义破坏 NGG 且同时避开 NAG/NGA 非典型 SpCas9 PAM
            outerPamSearch: for critPos in pamCritIndices {
                let cands = try1bpSynonymousCandidatesAt(pos: critPos, chars: editedChars, locked: editLockedSet, reason: "pam_block")
                for hit in cands {
                    var cand = editedChars
                    cand[critPos] = hit.newBase
                    if !isPamIntact(cand) {
                        if !isNonCanonicalActivePam(cand) {
                            editedChars = cand
                            blockingMutations.append(hit.record)
                            brokePam = true
                            break outerPamSearch
                        } else if fallbackHit == nil {
                            fallbackHit = (critPos, hit.newBase, hit.record)
                        }
                    }
                }
            }
            if !brokePam, let fb = fallbackHit {
                editedChars[fb.pos] = fb.newBase
                blockingMutations.append(fb.record)
                brokePam = true
                warnings.append(L10n.t("同义突变受限，阻断后产生 SpCas9 次级非典型 PAM (NAG/NGA)，建议结合 Seed 区附加沉默突变以降低残留切割风险。"))
            }

            if brokePam {
                blockingStrategy = .pamSynonymous
            } else {
                // Fall back to up to 2 distinct-codon 1-bp synonymous mutations in PAM-proximal 8-nt Seed
                let seedPositions: [Int]
                if strand == "+" {
                    let sStart = max(0, editedPamStart0 - 8)
                    seedPositions = stride(from: editedPamStart0 - 1, through: sStart, by: -1).map { $0 }
                } else {
                    let protoStart = editedPamStart0 + 3
                    let sEnd = min(editedChars.count - 1, protoStart + 7)
                    seedPositions = protoStart <= sEnd ? Array(protoStart...sEnd) : []
                }

                var usedCodonStarts = Set<Int>()
                for sPos in seedPositions {
                    if blockingMutations.count >= 2 { break }
                    guard sPos >= editedCdsStart0 && sPos < editedCdsEnd0 else { continue }
                    let cStart = (resolvedCdsStrand == "+")
                        ? (editedCdsStart0 + ((sPos - editedCdsStart0) / 3) * 3)
                        : (editedCdsEnd0 - (((editedCdsEnd0 - 1) - sPos) / 3 + 1) * 3)
                    if usedCodonStarts.contains(cStart) { continue }
                    if let hit = try1bpSynonymousAt(pos: sPos, chars: editedChars, locked: editLockedSet, reason: "seed_block") {
                        editedChars[sPos] = hit.newBase
                        blockingMutations.append(hit.record)
                        usedCodonStarts.insert(cStart)
                    }
                }
                if blockingMutations.isEmpty {
                    blockingStrategy = .failedToBlock
                    warnings.append(L10n.t("未能找到同义 PAM 或 Seed 阻断突变位点，请人工复核 Cas9 二次切割风险。"))
                } else {
                    blockingStrategy = .seedSynonymousFallback
                    warnings.append(L10n.tr("PAM 位点无法在不改变氨基酸的前提下同义破坏，已回退并在近 PAM 8-nt Seed 区引入 \(blockingMutations.count) 处同义突变。", "PAM could not be synonymously disrupted; introduced \(blockingMutations.count) silent mutation(s) in proximal 8-nt Seed region."))
                }
            }
        } else {
            var mutPos: Int?
            for critPos in pamCritIndices where critPos >= 0 && critPos < editedChars.count && !editLockedSet.contains(critPos) {
                mutPos = critPos
                break
            }
            if let mp = mutPos {
                let origBase = editedChars[mp]
                // 非编码区严格避开 NAG/NGA（正链优选 C/T，负链优选 G/A）
                let preferredAlts = (strand == "+") ? ["C", "T", "A", "G"] : ["G", "A", "T", "C"]
                var chosenBase: String? = nil
                for b in preferredAlts where b != origBase {
                    var cand = editedChars
                    cand[mp] = b
                    if !isPamIntact(cand) && !isNonCanonicalActivePam(cand) {
                        chosenBase = b
                        break
                    }
                }
                let altBase = chosenBase ?? (strand == "+" ? (origBase == "G" ? "C" : "T") : (origBase == "C" ? "G" : "A"))
                editedChars[mp] = altBase
                blockingMutations.append(
                    SilentMutationRecord(
                        position0Based: mp,
                        position1Based: mp + 1,
                        originalBase: origBase,
                        mutatedBase: altBase,
                        reason: "pam_block"
                    )
                )
                blockingStrategy = .pamNonCoding
            } else {
                blockingStrategy = .failedToBlock
                warnings.append(L10n.t("非编码区 PAM 关键碱基被用户编辑区间完全锁定，未能自动写入 PAM 阻断突变。"))
            }
        }

        // 4. Arm bounds on editedChars & WT ref (supports Richardson et al. Nat Biotechnol 2016 36/91 nt asymmetric ssODN)
        let defaultLeftArm: Int
        let defaultRightArm: Int
        if request.donorFormat == .ssODN && request.asymmetricRichardsonSSODN {
            defaultLeftArm = (strand == "+") ? 36 : 91
            defaultRightArm = (strand == "+") ? 91 : 36
        } else {
            defaultLeftArm = request.donorFormat.defaultArmLengthBp
            defaultRightArm = request.donorFormat.defaultArmLengthBp
        }
        let reqLeftArm = max(1, request.leftArmLengthBp ?? defaultLeftArm)
        let reqRightArm = max(1, request.rightArmLengthBp ?? defaultRightArm)
        let leftArmStart0 = max(0, editStart0 - reqLeftArm)
        let rightArmEnd0InEdited = min(editedChars.count, editStart0 + rep.count + reqRightArm)
        let rightArmEnd0InWT = min(L, editEnd0 + (rightArmEnd0InEdited - (editStart0 + rep.count)))

        if editStart0 - leftArmStart0 < reqLeftArm || rightArmEnd0InEdited - (editStart0 + rep.count) < reqRightArm {
            warnings.append(L10n.t("参考序列在编辑位点侧翼长度不足，同源臂已按边界自动截断。"))
        }

        // 5. Optional RFLP design (destroy existing or create new silent enzyme site)
        var rflpSelectedSpec: RFLPEnzymeSpec?
        var rflpMode: RFLPMode = .none
        var rflpMutations: [SilentMutationRecord] = []
        var rflpNote = ""

        if request.enableRFLP {
            let radius = max(3, request.rflpSearchRadiusBp)
            var rflpLocked = editLockedSet
            for m in blockingMutations { rflpLocked.insert(m.position0Based) }
            for p in pamCritIndices { rflpLocked.insert(p) }
            let pamWasBrokenBeforeRFLP = !isPamIntact(editedChars)

            if isInCDS {
                let winStart = max(editedCdsStart0, max(leftArmStart0, editStart0 - radius))
                let winEnd = min(editedCdsEnd0, min(rightArmEnd0InEdited, editStart0 + rep.count + radius))

                // First try DESTROY existing site from canonical 20-enzyme panel
                var foundDestroy = false
                for enz in rflpCandidateEnzymes {
                    let sChars = Array(enz.site).map { String($0) }
                    var matches: [Int] = []
                    if rightArmEnd0InEdited - leftArmStart0 >= 6 {
                        for sp in leftArmStart0...(rightArmEnd0InEdited - 6) {
                            var ok = true
                            for k in 0..<6 where editedChars[sp + k] != sChars[k] {
                                ok = false
                                break
                            }
                            if ok && sp + 6 > winStart && sp < winEnd {
                                matches.append(sp)
                            }
                        }
                    }
                    matches.sort { a, b in
                        let da = abs((a + 3) - editStart0)
                        let db = abs((b + 3) - editStart0)
                        return da != db ? da < db : a < b
                    }
                    let allCdsCodonStarts: [Int] = { () -> [Int] in
                        var out: [Int] = []
                        if resolvedCdsStrand == "+" {
                            var c = editedCdsStart0
                            while c + 3 <= editedCdsEnd0 { out.append(c); c += 3 }
                        } else {
                            var c = editedCdsEnd0 - 3
                            while c >= editedCdsStart0 { out.append(c); c -= 3 }
                        }
                        return out
                    }()
                    func senseCodonAndFwdBases(at cs: Int) -> (origCodon: String, fwdOrig: [String]) {
                        let f0 = editedChars[cs], f1 = editedChars[cs + 1], f2 = editedChars[cs + 2]
                        let origCodon = (resolvedCdsStrand == "+")
                            ? (f0 + f1 + f2)
                            : (complementBase(f2) + complementBase(f1) + complementBase(f0))
                        return (origCodon, [f0, f1, f2])
                    }
                    func fwdBasesForSenseCodon(_ altCodon: String) -> [String] {
                        let a = Array(altCodon).map { String($0) }
                        return (resolvedCdsStrand == "+") ? a : [complementBase(a[2]), complementBase(a[1]), complementBase(a[0])]
                    }

                    for sp in matches {
                        var overlapCodons = allCdsCodonStarts.filter { $0 + 3 > sp && $0 < sp + 6 }
                        overlapCodons.sort { a, b in
                            let da = abs((a + 1) - editStart0)
                            let db = abs((b + 1) - editStart0)
                            return da != db ? da < db : a < b
                        }
                        for cs in overlapCodons {
                            let (origCodon, origArr) = senseCodonAndFwdBases(at: cs)
                            guard let aa = codonToAA[origCodon], let alts = preferredCodonsByAA[aa] else { continue }
                            for altCodon in alts where altCodon != origCodon {
                                let altArr = fwdBasesForSenseCodon(altCodon)
                                var diffs: [Int] = []
                                for k in 0..<3 where altArr[k] != origArr[k] { diffs.append(k) }
                                if diffs.count == 1 {
                                    let k = diffs[0]
                                    let mutPos = cs + k
                                    if mutPos >= sp && mutPos < sp + 6 && !rflpLocked.contains(mutPos) {
                                        var cand = editedChars
                                        cand[mutPos] = altArr[k]
                                        if pamWasBrokenBeforeRFLP && isPamIntact(cand) { continue }
                                        let siteStillThere = (0..<6).allSatisfy { cand[sp + $0] == sChars[$0] }
                                        if !siteStillThere {
                                            editedChars = cand
                                            let rec = SilentMutationRecord(
                                                position0Based: mutPos,
                                                position1Based: mutPos + 1,
                                                originalBase: origArr[k],
                                                mutatedBase: altArr[k],
                                                reason: "rflp_destroy",
                                                codonBefore: origCodon,
                                                codonAfter: altCodon,
                                                aminoAcid: aa
                                            )
                                            rflpMutations = [rec]
                                            rflpMode = .destroyed
                                            rflpSelectedSpec = enz
                                            rflpNote = L10n.tr("在 \(mutPos + 1) bp 处通过同义突变 (\(origCodon)->\(altCodon), \(aa)) 消除内源 \(enz.name) (\(enz.site)) 位点用于 RFLP 鉴定", "Eliminated internal \(enz.name) (\(enz.site)) site at \(mutPos + 1) bp via silent mutation (\(origCodon)->\(altCodon), \(aa)) for RFLP")
                                            foundDestroy = true
                                            break
                                        }
                                    }
                                }
                            }
                            if foundDestroy { break }
                        }
                        if foundDestroy { break }
                    }
                    if foundDestroy { break }
                }

                // Else try CREATE a new 6-bp enzyme site via 1-bp then 2-bp synonymous substitution (supports + and - CDS strands)
                if !foundDestroy {
                    var orderedCodons: [Int] = []
                    if resolvedCdsStrand == "+" {
                        var cs = editedCdsStart0
                        while cs + 3 <= editedCdsEnd0 {
                            if cs >= winStart && cs + 3 <= winEnd { orderedCodons.append(cs) }
                            cs += 3
                        }
                    } else {
                        var cs = editedCdsEnd0 - 3
                        while cs >= editedCdsStart0 {
                            if cs >= winStart && cs + 3 <= winEnd { orderedCodons.append(cs) }
                            cs -= 3
                        }
                    }
                    orderedCodons.sort { a, b in
                        let da = abs((a + 1) - editStart0)
                        let db = abs((b + 1) - editStart0)
                        return da != db ? da < db : a < b
                    }

                    var foundCreate = false
                    for targetDiffs in [1, 2] where !foundCreate {
                        for cs in orderedCodons where !foundCreate {
                            let f0 = editedChars[cs], f1 = editedChars[cs + 1], f2 = editedChars[cs + 2]
                            let origArr = [f0, f1, f2]
                            let origCodon = (resolvedCdsStrand == "+")
                                ? (f0 + f1 + f2)
                                : (complementBase(f2) + complementBase(f1) + complementBase(f0))
                            guard let aa = codonToAA[origCodon], let alts = preferredCodonsByAA[aa] else { continue }
                            for altCodon in alts where altCodon != origCodon && !foundCreate {
                                let senseAlt = Array(altCodon).map { String($0) }
                                let altArr = (resolvedCdsStrand == "+")
                                    ? senseAlt
                                    : [complementBase(senseAlt[2]), complementBase(senseAlt[1]), complementBase(senseAlt[0])]
                                var diffs: [Int] = []
                                for k in 0..<3 where altArr[k] != origArr[k] { diffs.append(k) }
                                guard diffs.count == targetDiffs else { continue }
                                let mutPositions = diffs.map { cs + $0 }
                                if mutPositions.contains(where: { rflpLocked.contains($0) }) { continue }

                                var cand = editedChars
                                for k in diffs {
                                    cand[cs + k] = altArr[k]
                                }
                                if pamWasBrokenBeforeRFLP && isPamIntact(cand) { continue }

                                let scanStart = max(leftArmStart0, cs - 5)
                                let scanEndMaxStart = min(rightArmEnd0InEdited - 6, cs + 2)
                                guard scanStart <= scanEndMaxStart else { continue }

                                for enz in rflpCandidateEnzymes where !foundCreate {
                                    let sChars = Array(enz.site).map { String($0) }
                                    for sp in scanStart...scanEndMaxStart {
                                        let hitsNew = (0..<6).allSatisfy { cand[sp + $0] == sChars[$0] }
                                        guard hitsNew else { continue }
                                        let wasPresent = (0..<6).allSatisfy { editedChars[sp + $0] == sChars[$0] }
                                        guard !wasPresent else { continue }
                                        let overlapsMut = mutPositions.contains { $0 >= sp && $0 < sp + 6 }
                                        guard overlapsMut else { continue }

                                        editedChars = cand
                                        rflpMutations = diffs.map { k in
                                            SilentMutationRecord(
                                                position0Based: cs + k,
                                                position1Based: cs + k + 1,
                                                originalBase: origArr[k],
                                                mutatedBase: altArr[k],
                                                reason: "rflp_create",
                                                codonBefore: origCodon,
                                                codonAfter: altCodon,
                                                aminoAcid: aa
                                            )
                                        }
                                        rflpMode = .created
                                        rflpSelectedSpec = enz
                                        rflpNote = L10n.tr("在 \(cs + 1)..\(cs + 3) bp 处引入同义密码子 (\(origCodon)->\(altCodon), \(aa)) 构建新 \(enz.name) (\(enz.site)) RFLP 鉴定位点", "Created \(enz.name) (\(enz.site)) RFLP site at \(cs + 1)..\(cs + 3) bp via silent codon (\(origCodon)->\(altCodon), \(aa))")
                                        foundCreate = true
                                        break
                                    }
                                }
                            }
                        }
                    }
                    if !foundCreate {
                        warnings.append(L10n.tr("在目标附近 ±\(radius) bp 窗口内未能通过同义密码子替换引入或消除 RFLP 酶切位点。", "Unable to create/remove a silent RFLP site within ±\(radius) bp window."))
                    }
                }
            } else {
                // Non-coding RFLP fallback
                let winStart = max(leftArmStart0, editStart0 - radius)
                let winEnd = min(rightArmEnd0InEdited, editStart0 + rep.count + radius)
                var foundNC = false
                for enz in rflpCandidateEnzymes where !foundNC {
                    let sChars = Array(enz.site).map { String($0) }
                    if winEnd - winStart >= 6 {
                        for sp in winStart...(winEnd - 6) where !foundNC {
                            if (0..<6).allSatisfy({ editedChars[sp + $0] == sChars[$0] }) {
                                if let mutPos = (sp..<(sp + 6)).first(where: { !rflpLocked.contains($0) }) {
                                    let ob = editedChars[mutPos]
                                    let nb = ob == "A" ? "T" : "A"
                                    var cand = editedChars
                                    cand[mutPos] = nb
                                    if pamWasBrokenBeforeRFLP && isPamIntact(cand) { continue }
                                    editedChars = cand
                                    rflpMutations = [
                                        SilentMutationRecord(
                                            position0Based: mutPos,
                                            position1Based: mutPos + 1,
                                            originalBase: ob,
                                            mutatedBase: nb,
                                            reason: "rflp_destroy"
                                        )
                                    ]
                                    rflpMode = .destroyed
                                    rflpSelectedSpec = enz
                                    rflpNote = L10n.tr("在非编码区 \(mutPos + 1) bp 破坏 \(enz.name) (\(enz.site)) 位点用于 RFLP 鉴定", "Disrupted non-coding \(enz.name) (\(enz.site)) site at \(mutPos + 1) bp for RFLP")
                                    foundNC = true
                                }
                            }
                        }
                    }
                }
                if !foundNC {
                    let positions = (winStart..<winEnd).sorted { abs($0 - editStart0) < abs($1 - editStart0) }
                    for pos in positions where !rflpLocked.contains(pos) && !foundNC {
                        let ob = editedChars[pos]
                        for nb in ["A", "C", "G", "T"] where nb != ob && !foundNC {
                            var cand = editedChars
                            cand[pos] = nb
                            if pamWasBrokenBeforeRFLP && isPamIntact(cand) { continue }
                            let sStart = max(leftArmStart0, pos - 5)
                            let sEnd = min(rightArmEnd0InEdited - 6, pos)
                            guard sStart <= sEnd else { continue }
                            for enz in rflpCandidateEnzymes where !foundNC {
                                let sChars = Array(enz.site).map { String($0) }
                                for sp in sStart...sEnd {
                                    if (0..<6).allSatisfy({ cand[sp + $0] == sChars[$0] }) &&
                                       !(0..<6).allSatisfy({ editedChars[sp + $0] == sChars[$0] }) {
                                        editedChars = cand
                                        rflpMutations = [
                                            SilentMutationRecord(
                                                position0Based: pos,
                                                position1Based: pos + 1,
                                                originalBase: ob,
                                                mutatedBase: nb,
                                                reason: "rflp_create"
                                            )
                                        ]
                                        rflpMode = .created
                                        rflpSelectedSpec = enz
                                        rflpNote = L10n.tr("在非编码区 \(pos + 1) bp 引入新 \(enz.name) (\(enz.site)) RFLP 鉴定位点", "Introduced non-coding \(enz.name) (\(enz.site)) RFLP site at \(pos + 1) bp")
                                        foundNC = true
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 6. Final locus checks, GT-AG splice-site check & protein conservation check
        let finalEditedSeq = editedChars.joined()
        let proteinAfterBlocking = isInCDS
            ? translateCDS(finalEditedSeq, start0Based: editedCdsStart0, end0Based: editedCdsEnd0, strand: resolvedCdsStrand)
            : ""
        let aminoAcidConserved = !isInCDS || (proteinBeforeBlocking == proteinAfterBlocking)

        let allSilentMuts = blockingMutations + rflpMutations
        if isInCDS && !allSilentMuts.isEmpty {
            var preSilentEdited = editedChars
            for m in allSilentMuts where m.position0Based >= 0 && m.position0Based < preSilentEdited.count {
                preSilentEdited[m.position0Based] = m.originalBase
            }
            let spliceDinucs: Set<String> = (resolvedCdsStrand == "-") ? ["CT", "AC"] : ["GT", "AG"]
            let boundaryMuts = allSilentMuts.map(\.position0Based).filter { p in
                abs(p - editedCdsStart0) <= 3 || abs(p - (editedCdsEnd0 - 1)) <= 3
            }
            let hitsSpliceDinuc = boundaryMuts.contains { p in
                let leftPair = (p > 0 && p < preSilentEdited.count) ? (preSilentEdited[p - 1] + preSilentEdited[p]) : ""
                let rightPair = (p >= 0 && p + 1 < preSilentEdited.count) ? (preSilentEdited[p] + preSilentEdited[p + 1]) : ""
                return spliceDinucs.contains(leftPair) || spliceDinucs.contains(rightPair)
            }
            if hitsSpliceDinuc {
                warnings.append(L10n.t("沉默阻断/RFLP 突变位于 CDS 边界 ±3 bp 的经典 GT-AG 剪接供体/受体二核苷酸处，存在破坏 mRNA 剪接风险，请人工复核。"))
            }
        }

        let editedPamSeq = (editedPamStart0 >= 0 && editedPamStart0 + 3 <= editedChars.count)
            ? (editedChars[editedPamStart0] + editedChars[editedPamStart0 + 1] + editedChars[editedPamStart0 + 2])
            : ""
        let pamStillIntact = isPamIntact(editedChars)
        let cas9RecutBlocked = (blockingStrategy != .failedToBlock) && (!pamStillIntact || blockingStrategy == .seedSynonymousFallback)

        // 7. Slice homology arms & donor from final edited locus (Richardson 2016 asymmetric ssODN targets non-target strand)
        let leftHomologyArm = editedChars[leftArmStart0..<editStart0].joined()
        let insertPayload = editedChars[editStart0..<(editStart0 + rep.count)].joined()
        let rightHomologyArm = editedChars[(editStart0 + rep.count)..<rightArmEnd0InEdited].joined()
        let rawDonorForward = leftHomologyArm + insertPayload + rightHomologyArm
        let donorSequence: String
        let donorStrandOrientation: String
        if request.donorFormat == .ssODN && request.asymmetricRichardsonSSODN {
            if strand == "+" {
                donorSequence = BioSequence.reverseComplement(rawDonorForward)
                donorStrandOrientation = "target_strand_antisense_richardson_36_91"
            } else {
                donorSequence = rawDonorForward
                donorStrandOrientation = "target_strand_sense_richardson_91_36"
            }
        } else {
            donorSequence = rawDonorForward
            donorStrandOrientation = "forward_reference"
        }

        // 8. Out-Out PCR genotyping primers strictly outside homology arms
        var outOutResult: OutOutPCRDesign?
        let leftFlankAvail = leftArmStart0
        let rightFlankAvail = L - rightArmEnd0InWT
        let effLeftMargin = min(request.outOutMarginBp, max(10, leftFlankAvail - 25))
        let effRightMargin = min(request.outOutMarginBp, max(10, rightFlankAvail - 25))

        if leftFlankAvail >= effLeftMargin + 18 && rightFlankAvail >= effRightMargin + 18 {
            let fwdSearchEnd = leftArmStart0 - effLeftMargin
            let fwdSearchStart = max(0, fwdSearchEnd - 40)
            let fwdWindow = refChars[fwdSearchStart..<fwdSearchEnd].joined()
            let (fwdSeq, fwdTm) = HomologyArmDesigner.pickSpecificAnnealingSeq(
                from: fwdWindow,
                fivePrimeOverhang: "",
                targetTm: request.primerTargetTm,
                tolerance: 1.5,
                isForward: true
            )
            let fwdStart0 = fwdSearchStart
            let fwdEnd0 = fwdStart0 + fwdSeq.count

            let revSearchStart = rightArmEnd0InWT + effRightMargin
            let revSearchEnd = min(L, revSearchStart + 40)
            let revWindow = refChars[revSearchStart..<revSearchEnd].joined()
            let (revSeq, revTm) = HomologyArmDesigner.pickSpecificAnnealingSeq(
                from: revWindow,
                fivePrimeOverhang: "",
                targetTm: request.primerTargetTm,
                tolerance: 1.5,
                isForward: false
            )
            let revEnd0 = revSearchEnd
            let revStart0 = revEnd0 - revSeq.count

            let fwdGC = ((Double(fwdSeq.filter { $0 == "G" || $0 == "C" }.count) / Double(max(1, fwdSeq.count)) * 100.0) * 10.0).rounded() / 10.0
            let revGC = ((Double(revSeq.filter { $0 == "G" || $0 == "C" }.count) / Double(max(1, revSeq.count)) * 100.0) * 10.0).rounded() / 10.0

            let fwdItem = PrimerItem(
                name: "\(request.donorName)_OutOut_F",
                fullSequence: fwdSeq,
                homologyArm: "",
                specificSequence: fwdSeq,
                tm: fwdTm,
                gcPercent: fwdGC,
                targetPurpose: L10n.t("HDR Out-Out PCR 正向分型引物"),
                notes: L10n.tr("位于左同源臂外侧 -\(leftArmStart0 - fwdEnd0) bp", "-\(leftArmStart0 - fwdEnd0) bp outside left homology arm"),
                sourceTool: "HDR Donor"
            )
            let revItem = PrimerItem(
                name: "\(request.donorName)_OutOut_R",
                fullSequence: revSeq,
                homologyArm: "",
                specificSequence: revSeq,
                tm: revTm,
                gcPercent: revGC,
                targetPurpose: L10n.t("HDR Out-Out PCR 反向分型引物"),
                notes: L10n.tr("位于右同源臂外侧 +\(revStart0 - rightArmEnd0InWT) bp", "+\(revStart0 - rightArmEnd0InWT) bp outside right homology arm"),
                sourceTool: "HDR Donor"
            )

            let wtAmpSeq = refChars[fwdStart0..<revEnd0].joined()
            let hdrAmpEnd0 = revEnd0 + delta
            let hdrAmpSeq = editedChars[fwdStart0..<hdrAmpEnd0].joined()

            outOutResult = OutOutPCRDesign(
                forwardPrimer: fwdItem,
                reversePrimer: revItem,
                forwardStart0Based: fwdStart0,
                forwardEnd0Based: fwdEnd0,
                reverseStart0Based: revStart0,
                reverseEnd0Based: revEnd0,
                wtAmpliconLengthBp: wtAmpSeq.count,
                hdrAmpliconLengthBp: hdrAmpSeq.count,
                wtAmpliconSequence: wtAmpSeq,
                hdrAmpliconSequence: hdrAmpSeq,
                leftMarginFromArmBp: leftArmStart0 - fwdEnd0,
                rightMarginFromArmBp: revStart0 - rightArmEnd0InWT
            )
        } else {
            warnings.append(L10n.t("侧翼序列长度不足以在左右同源臂外侧设计 Out-Out PCR 引物（需同源臂外侧至少各预留 28 bp）。"))
        }

        // 9. Finalize RFLP digest band prediction on amplicon (or full locus fallback)
        var finalRFLP: RFLPDesignResult?
        if let spec = rflpSelectedSpec, rflpMode != .none {
            let wtTarget = outOutResult?.wtAmpliconSequence ?? ref
            let hdrTarget = outOutResult?.hdrAmpliconSequence ?? finalEditedSeq
            let wtBands = predictLinearDigestBands(sequence: wtTarget, site: spec.site, topCutOffset: spec.topCutOffset)
            let hdrBands = predictLinearDigestBands(sequence: hdrTarget, site: spec.site, topCutOffset: spec.topCutOffset)
            let hasExtraBackgroundCut = (rflpMode == .created) ? (wtBands.count > 1 || hdrBands.count > 2) : (wtBands.count > 2 || hdrBands.count > 1)
            if hasExtraBackgroundCut {
                warnings.append(L10n.tr(
                    "RFLP 诊断酶 \(spec.name) 在扩增子全长内存在额外背景切点（WT \(wtBands.count) 条带 / HDR \(hdrBands.count) 条带），电泳判读时请注意区分背景片段。",
                    "RFLP enzyme \(spec.name) cuts additional background site(s) within the amplicon (WT \(wtBands.count) bands / HDR \(hdrBands.count) bands); interpret gel bands carefully."
                ))
            }
            let methSensitiveRFLP: [String: String] = [
                "ClaI": "Dam / CpG", "XbaI": "Dam", "StuI": "Dcm",
                "AgeI": "CpG", "SmaI": "CpG", "XhoI": "CpG", "SalI": "CpG", "NotI": "CpG"
            ]
            if let methType = methSensitiveRFLP[spec.name] {
                warnings.append(L10n.tr(
                    "RFLP 酶 \(spec.name) 受 \(methType) 甲基化敏感阻断，建议仅对 PCR 扩增产物（无甲基化）而非基因组/质粒原液执行酶切鉴定。",
                    "RFLP enzyme \(spec.name) is sensitive to \(methType) methylation; digest unmethylated PCR amplicons rather than genomic/plasmid DNA."
                ))
            }
            finalRFLP = RFLPDesignResult(
                mode: rflpMode,
                enzymeName: spec.name,
                recognitionSite: spec.site,
                topCutOffset: spec.topCutOffset,
                wtAmpliconBandsBp: wtBands,
                hdrAmpliconBandsBp: hdrBands,
                silentMutations: rflpMutations,
                note: rflpNote
            )
        }

        return HDRDonorDesignReport(
            donorFormat: request.donorFormat,
            sgRNASequence: guide,
            strand: strand,
            wtCutIndex0Based: wtCutIndex0,
            cutToEditDistanceBp: cutToEditDistanceBp,
            wtPamStart0Based: wtPamStart0,
            wtPamSequence: wtPamSeq,
            isInCDS: isInCDS,
            cdsStrand: resolvedCdsStrand,
            cdsStart1Based: wtCdsStart0.map { $0 + 1 },
            cdsEnd1Based: wtCdsEnd0,
            cdsAutoDetected: cdsAutoDetected,
            proteinBeforeBlocking: proteinBeforeBlocking,
            proteinAfterBlocking: proteinAfterBlocking,
            aminoAcidConserved: aminoAcidConserved,
            blockingStrategy: blockingStrategy,
            blockingMutations: blockingMutations,
            editedPamSequence: editedPamSeq,
            pamStillIntact: pamStillIntact,
            cas9RecutBlocked: cas9RecutBlocked,
            leftHomologyArm: leftHomologyArm,
            insertPayload: insertPayload,
            rightHomologyArm: rightHomologyArm,
            leftArmLengthBp: leftHomologyArm.count,
            rightArmLengthBp: rightHomologyArm.count,
            donorSequence: donorSequence,
            donorLengthBp: donorSequence.count,
            donorStrandOrientation: donorStrandOrientation,
            finalEditedLocusSequence: finalEditedSeq,
            rflp: finalRFLP,
            outOutPCR: outOutResult,
            warnings: warnings
        )
    }
}
