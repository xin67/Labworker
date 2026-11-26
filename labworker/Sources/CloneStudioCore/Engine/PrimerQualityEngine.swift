import Foundation

/// Oligonucleotide secondary-structure thermodynamic evaluator (hairpin, homodimer, heterodimer)
/// aligned with primer3-py (`calc_hairpin`, `calc_homodimer`, `calc_dimer`).
public struct PrimerQualityEngine {

    // MARK: - Reaction Conditions

    public struct Conditions: Sendable, Equatable, Codable {
        /// Monovalent cation concentration [Na+/K+] in mM (default 50.0 mM)
        public var mvConc: Double
        /// Divalent cation concentration [Mg2+] in mM (default 1.5 mM)
        public var dvConc: Double
        /// dNTP concentration in mM (default 0.6 mM)
        public var dntpConc: Double
        /// Oligonucleotide concentration in nM (default 50.0 nM)
        public var dnaConc: Double
        /// Evaluation temperature in Celsius (default 37.0 C)
        public var tempC: Double

        public static let standard = Conditions(
            mvConc: 50.0,
            dvConc: 1.5,
            dntpConc: 0.6,
            dnaConc: 50.0,
            tempC: 37.0
        )

        public init(
            mvConc: Double = 50.0,
            dvConc: Double = 1.5,
            dntpConc: Double = 0.6,
            dnaConc: Double = 50.0,
            tempC: Double = 37.0
        ) {
            self.mvConc = max(1.0, mvConc)
            self.dvConc = max(0.0, dvConc)
            self.dntpConc = max(0.0, dntpConc)
            self.dnaConc = max(1.0, dnaConc)
            self.tempC = tempC
        }

        /// Equivalent monovalent cation concentration in Molar (Ahsen et al. / Primer3 thal)
        public var equivalentMonovalentMolar: Double {
            let freeMg = max(0.0, dvConc - dntpConc)
            let eqMm = mvConc + 120.0 * sqrt(freeMg)
            return max(0.001, eqMm / 1000.0)
        }

        public var tempKelvin: Double {
            tempC + 273.15
        }
    }

    // MARK: - Risk Level & Result Models

    public enum StructureKind: String, Sendable, Codable, CaseIterable {
        case hairpin = "发夹 (Hairpin)"
        case homodimer = "自二聚体 (Homodimer)"
        case heterodimer = "异二聚体 (Heterodimer)"
    }

    public enum RiskLevel: String, Sendable, Codable, Comparable {
        case safe = "低风险"
        case moderate = "中风险"
        case high = "高风险"

        private var rank: Int {
            switch self {
            case .safe: return 0
            case .moderate: return 1
            case .high: return 2
            }
        }

        public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    public struct StructureResult: Sendable, Equatable {
        public let kind: StructureKind
        public let structureFound: Bool
        /// Gibbs free energy in kcal/mol at `conditions.tempC`
        public let dg: Double
        /// Gibbs free energy in cal/mol (primer3-py `.dg` unit)
        public var dgCalMol: Double { dg * 1000.0 }
        /// Enthalpy in kcal/mol
        public let dh: Double
        /// Entropy in cal/(K*mol)
        public let ds: Double
        /// Melting temperature of the structure in Celsius
        public let tm: Double
        /// Whether any base within the last 3 bases at the 3' end participates in pairing
        public let threePrimeAnchored: Bool
        /// Number of paired bases in the stem or duplex
        public let pairedBaseCount: Int
        /// ASCII base-pairing alignment diagram
        public let asciiStructure: String
        public let riskLevel: RiskLevel

        public init(
            kind: StructureKind,
            structureFound: Bool,
            dg: Double,
            dh: Double,
            ds: Double,
            tm: Double,
            threePrimeAnchored: Bool,
            pairedBaseCount: Int,
            asciiStructure: String,
            riskLevel: RiskLevel
        ) {
            self.kind = kind
            self.structureFound = structureFound
            self.dg = dg
            self.dh = dh
            self.ds = ds
            self.tm = tm
            self.threePrimeAnchored = threePrimeAnchored
            self.pairedBaseCount = pairedBaseCount
            self.asciiStructure = asciiStructure
            self.riskLevel = riskLevel
        }

        public static func none(kind: StructureKind) -> StructureResult {
            StructureResult(
                kind: kind,
                structureFound: false,
                dg: 0.0,
                dh: 0.0,
                ds: 0.0,
                tm: 0.0,
                threePrimeAnchored: false,
                pairedBaseCount: 0,
                asciiStructure: "",
                riskLevel: .safe
            )
        }
    }

    public struct SinglePrimerReport: Sendable, Equatable {
        public let sequence: String
        public let conditions: Conditions
        public let hairpin: StructureResult
        public let homodimer: StructureResult
        public let overallRisk: RiskLevel

        public var summaryBadgeText: String {
            switch overallRisk {
            case .safe:
                return L10n.t("二级结构安全")
            case .moderate:
                let minDg = min(hairpin.dg, homodimer.dg)
                return String(format: L10n.tr("中风险 (%.1f kcal/mol)", "Moderate Risk (%.1f kcal/mol)"), minDg)
            case .high:
                let minDg = min(hairpin.dg, homodimer.dg)
                let tag = (hairpin.threePrimeAnchored || homodimer.threePrimeAnchored) ? L10n.t("3'端配对 ") : ""
                return String(format: L10n.tr("高风险 %@(%.1f kcal/mol)", "High Risk %@(%.1f kcal/mol)"), tag, minDg)
            }
        }
    }

    public struct PrimerPairReport: Sendable, Equatable {
        public let forwardReport: SinglePrimerReport
        public let reverseReport: SinglePrimerReport
        public let heterodimer: StructureResult
        public let overallRisk: RiskLevel
    }

    // MARK: - SantaLucia 1998 Unified Nearest-Neighbor Parameters (aligned with primer3 thal)

    private static let nn1998: [String: (dH: Double, dS: Double)] = [
        "AA": (-7.9, -22.2), "TT": (-7.9, -22.2),
        "AT": (-7.2, -20.4), "TA": (-7.2, -21.3),
        "CA": (-8.5, -22.7), "TG": (-8.5, -22.7),
        "GT": (-8.4, -22.4), "AC": (-8.4, -22.4),
        "CT": (-7.8, -21.0), "AG": (-7.8, -21.0),
        "GA": (-8.2, -22.2), "TC": (-8.2, -22.2),
        "CG": (-10.6, -27.2), "GC": (-9.8, -24.4),
        "GG": (-8.0, -19.9), "CC": (-8.0, -19.9)
    ]

    /// Hairpin loop entropy penalties (cal/(K*mol)) at 1M Na+ for loop sizes 3...12
    private static let hairpinLoopDS: [Int: Double] = [
        3: -10.18,
        4: -10.80,
        5: -10.16,
        6: -12.41,
        7: -13.06,
        8: -13.38,
        9: -14.02,
        10: -14.35,
        11: -14.81,
        12: -15.10
    ]

    // MARK: - Public API (primer3-py compatible)

    /// Evaluate single-strand hairpin stability (`primer3.calc_hairpin`)
    public static func calcHairpin(
        _ rawSeq: String,
        conditions: Conditions = .standard,
        dgAlertThreshold: Double = -3.0
    ) -> StructureResult {
        let clean = cleanACGT(rawSeq)
        // Primer3 caps single-strand hairpin evaluation at 60 bp
        let seq = clean.count > 60 ? String(clean.suffix(60)) : clean
        let chars = Array(seq)
        let n = chars.count
        guard n >= 7 else { return .none(kind: .hairpin) }

        let tempK = conditions.tempKelvin
        let naEq = conditions.equivalentMonovalentMolar
        let saltPerStep = 0.368 * log(naEq)

        var bestDG = 0.0
        var bestDH = 0.0
        var bestDS = 0.0
        var bestPairs: [(Int, Int)] = []

        // Scan stem outer closing pair (i, j) with minimum apical loop of 3 bases
        for i in 0..<(n - 6) {
            for j in stride(from: n - 1, through: i + 6, by: -1) {
                guard isComplementary(chars[i], chars[j]) else { continue }

                var pairs: [(Int, Int)] = [(i, j)]
                var dh = 0.0
                var ds = 0.0
                var l = i
                var r = j

                // Outer terminal AT penalty
                if isAT(chars[i]) {
                    dh += 2.2
                    ds += 6.9
                }

                // Extend stem inward, allowing up to 1 single-base internal mismatch if flanked by >=2 pairs
                while (r - l - 1) >= 5 {
                    let nl = l + 1
                    let nr = r - 1
                    if isComplementary(chars[nl], chars[nr]) {
                        let key = "\(chars[l])\(chars[nl])"
                        if let st = nn1998[key] {
                            dh += st.dH
                            ds += st.dS
                        }
                        pairs.append((nl, nr))
                        l = nl
                        r = nr
                    } else if (nr - nl - 1) >= 5,
                              isComplementary(chars[nl + 1], chars[nr - 1]),
                              isComplementary(chars[nl + 2], chars[nr - 2]) {
                        // Single internal mismatch bridged by stable stem
                        let key1 = "\(chars[l])\(chars[nl])/\(chars[r])\(chars[nr])"
                        let key2 = "\(chars[nl])\(chars[nl + 1])/\(chars[nr])\(chars[nr - 1])"
                        if let m1 = TmCalculator.internalMismatchParams[key1] {
                            dh += m1.dH
                            ds += m1.dS
                        } else {
                            dh += 1.0
                            ds += 0.0
                        }
                        if let m2 = TmCalculator.internalMismatchParams[key2] {
                            dh += m2.dH
                            ds += m2.dS
                        } else {
                            dh += 1.0
                            ds += 0.0
                        }
                        pairs.append((nl + 1, nr - 1))
                        l = nl + 1
                        r = nr - 1
                    } else {
                        break
                    }

                    let loopLen = r - l - 1
                    guard loopLen >= 3, pairs.count >= 3 else { continue }

                    var candDH = dh
                    var candDS = ds

                    // Hairpin loop entropy + closing terminal mismatch for loops >= 4
                    let loopEntropy: Double
                    if let tableDS = hairpinLoopDS[loopLen] {
                        loopEntropy = tableDS
                    } else {
                        loopEntropy = -16.20 - 1.75 * 1.9872 * log(Double(loopLen) / 12.0)
                    }
                    candDS += loopEntropy

                    if loopLen >= 4 {
                        let mmKey = "\(chars[l])\(chars[l + 1])/\(chars[r])\(chars[r - 1])"
                        let revKey = "\(chars[r])\(chars[r - 1])/\(chars[l])\(chars[l + 1])"
                        if let mm = TmCalculator.internalMismatchParams[mmKey] ?? TmCalculator.internalMismatchParams[revKey] {
                            candDH += mm.dH
                            candDS += mm.dS
                        } else if isComplementary(chars[l + 1], chars[r - 1]) {
                            candDH += -6.0
                            candDS += -16.58
                        } else {
                            candDH += -3.5
                            candDS += -9.5
                        }
                    }

                    // 5' and 3' dangling ends outside outer pair (i, j)
                    if i > 0, let d5 = TmCalculator.fivePrimeDangleParams["\(chars[i - 1])\(chars[i])"] {
                        candDH += d5.dH * 0.5
                        candDS += d5.dS * 0.5
                    }
                    if j < n - 1, let d3 = TmCalculator.threePrimeDangleParams["\(chars[j])\(chars[j + 1])"] {
                        candDH += d3.dH * 0.5
                        candDS += d3.dS * 0.5
                    }

                    // Salt correction
                    candDS += saltPerStep * Double(max(1, pairs.count - 2))

                    let candDG = candDH - (tempK * candDS) / 1000.0
                    if candDG < bestDG {
                        bestDG = candDG
                        bestDH = candDH
                        bestDS = candDS
                        bestPairs = pairs
                    }
                }
            }
        }

        guard !bestPairs.isEmpty, bestDG < -0.2, bestDS < 0 else {
            return .none(kind: .hairpin)
        }

        let tm = (bestDH * 1000.0) / bestDS - 273.15
        let anchored3 = bestPairs.contains { $0.0 >= n - 3 || $0.1 >= n - 3 }
        let ascii = renderHairpinASCII(chars: chars, pairs: bestPairs)
        let risk = classifyRisk(
            kind: .hairpin,
            dg: bestDG,
            threePrimeAnchored: anchored3,
            alertThreshold: dgAlertThreshold
        )

        return StructureResult(
            kind: .hairpin,
            structureFound: true,
            dg: round2(bestDG),
            dh: round2(bestDH),
            ds: round2(bestDS),
            tm: round1(max(0.0, tm)),
            threePrimeAnchored: anchored3,
            pairedBaseCount: bestPairs.count,
            asciiStructure: ascii,
            riskLevel: risk
        )
    }

    /// Evaluate self-dimer stability (`primer3.calc_homodimer`)
    public static func calcHomodimer(
        _ rawSeq: String,
        conditions: Conditions = .standard,
        dgAlertThreshold: Double = -6.0
    ) -> StructureResult {
        calcDuplexDimer(
            rawSeq,
            rawSeq,
            kind: .homodimer,
            conditions: conditions,
            dgAlertThreshold: dgAlertThreshold
        )
    }

    /// Evaluate cross-dimer stability (`primer3.calc_dimer` / `primer3.calc_heterodimer`)
    public static func calcDimer(
        _ rawSeq1: String,
        _ rawSeq2: String,
        conditions: Conditions = .standard,
        dgAlertThreshold: Double = -6.0
    ) -> StructureResult {
        calcDuplexDimer(
            rawSeq1,
            rawSeq2,
            kind: .heterodimer,
            conditions: conditions,
            dgAlertThreshold: dgAlertThreshold
        )
    }

    public static func calcHeterodimer(
        _ rawSeq1: String,
        _ rawSeq2: String,
        conditions: Conditions = .standard,
        dgAlertThreshold: Double = -6.0
    ) -> StructureResult {
        calcDimer(rawSeq1, rawSeq2, conditions: conditions, dgAlertThreshold: dgAlertThreshold)
    }

    /// Comprehensive single-primer QC report
    public static func evaluatePrimer(
        _ rawSeq: String,
        conditions: Conditions = .standard,
        hairpinAlertDg: Double = -3.0,
        dimerAlertDg: Double = -6.0
    ) -> SinglePrimerReport {
        let hp = calcHairpin(rawSeq, conditions: conditions, dgAlertThreshold: hairpinAlertDg)
        let hd = calcHomodimer(rawSeq, conditions: conditions, dgAlertThreshold: dimerAlertDg)
        let risk = max(hp.riskLevel, hd.riskLevel)
        return SinglePrimerReport(
            sequence: cleanACGT(rawSeq),
            conditions: conditions,
            hairpin: hp,
            homodimer: hd,
            overallRisk: risk
        )
    }

    /// Comprehensive forward + reverse primer pair QC report
    public static func evaluatePrimerPair(
        forward: String,
        reverse: String,
        conditions: Conditions = .standard,
        hairpinAlertDg: Double = -3.0,
        dimerAlertDg: Double = -6.0
    ) -> PrimerPairReport {
        let fRep = evaluatePrimer(forward, conditions: conditions, hairpinAlertDg: hairpinAlertDg, dimerAlertDg: dimerAlertDg)
        let rRep = evaluatePrimer(reverse, conditions: conditions, hairpinAlertDg: hairpinAlertDg, dimerAlertDg: dimerAlertDg)
        let het = calcDimer(forward, reverse, conditions: conditions, dgAlertThreshold: dimerAlertDg)
        let overall = max(max(fRep.overallRisk, rRep.overallRisk), het.riskLevel)
        return PrimerPairReport(
            forwardReport: fRep,
            reverseReport: rRep,
            heterodimer: het,
            overallRisk: overall
        )
    }

    // MARK: - Internal Bimolecular Duplex Scanner

    private static func calcDuplexDimer(
        _ rawSeq1: String,
        _ rawSeq2: String,
        kind: StructureKind,
        conditions: Conditions,
        dgAlertThreshold: Double
    ) -> StructureResult {
        let s1 = Array(cleanACGT(rawSeq1))
        let s2Orig = Array(cleanACGT(rawSeq2))
        // Antiparallel strand 2 (3' -> 5' left-to-right)
        let s2Rev = Array(s2Orig.reversed())
        let n1 = s1.count
        let n2 = s2Rev.count
        guard n1 >= 4, n2 >= 4 else { return .none(kind: kind) }

        let tempK = conditions.tempKelvin
        let naEq = conditions.equivalentMonovalentMolar
        let saltPerStep = 0.368 * log(naEq)

        var bestDG = 0.0
        var bestDH = 0.0
        var bestDS = 0.0
        var bestOffset = 0
        var bestPairs: [(Int, Int)] = []

        // Slide s2Rev across s1: index j in s2Rev aligns with index i = j + offset in s1
        for offset in (-(n2 - 2))...(n1 - 2) {
            let startJ = max(0, -offset)
            let endJ = min(n2 - 1, n1 - 1 - offset)
            guard endJ - startJ + 1 >= 2 else { continue }

            // Collect all complementary positions along this diagonal
            var matchPositions: [Int] = []
            for j in startJ...endJ {
                let i = j + offset
                if isComplementary(s1[i], s2Rev[j]) {
                    matchPositions.append(j)
                }
            }
            guard matchPositions.count >= 2 else { continue }

            // Evaluate contiguous or single-mismatch-gapped runs along this diagonal
            for mStart in 0..<(matchPositions.count - 1) {
                var dh = 0.2
                var ds = -5.7
                let j0 = matchPositions[mStart]
                let i0 = j0 + offset
                var pairs: [(Int, Int)] = [(i0, j0)]

                if isAT(s1[i0]) {
                    dh += 2.2
                    ds += 6.9
                }

                var prevJ = j0
                for mEnd in (mStart + 1)..<matchPositions.count {
                    let curJ = matchPositions[mEnd]
                    let curI = curJ + offset
                    let prevI = prevJ + offset
                    let gap = curJ - prevJ

                    if gap == 1 {
                        let key = "\(s1[prevI])\(s1[curI])"
                        if let st = nn1998[key] {
                            dh += st.dH
                            ds += st.dS
                        }
                        pairs.append((curI, curJ))
                        prevJ = curJ
                    } else if gap == 2 {
                        // Single internal mismatch
                        let midI = prevI + 1
                        let midJ = prevJ + 1
                        let k1 = "\(s1[prevI])\(s1[midI])/\(s2Rev[prevJ])\(s2Rev[midJ])"
                        let k2 = "\(s1[midI])\(s1[curI])/\(s2Rev[midJ])\(s2Rev[curJ])"
                        if let m1 = TmCalculator.internalMismatchParams[k1],
                           let m2 = TmCalculator.internalMismatchParams[k2] {
                            dh += m1.dH + m2.dH
                            ds += m1.dS + m2.dS
                        } else {
                            dh += 2.4
                            ds += 4.0
                        }
                        pairs.append((curI, curJ))
                        prevJ = curJ
                    } else {
                        break
                    }

                    guard pairs.count >= 2 else { continue }

                    var candDH = dh
                    var candDS = ds
                    if isAT(s1[curI]) {
                        candDH += 2.2
                        candDS += 6.9
                    }

                    // Dangling ends at left boundary (i0, j0)
                    if i0 > 0 {
                        if let d5 = TmCalculator.fivePrimeDangleParams["\(s1[i0 - 1])\(s1[i0])"] {
                            candDH += d5.dH
                            candDS += d5.dS
                        }
                    }
                    if j0 > 0 {
                        // 3' overhang on s2Rev left corresponds to 3' end of s2Orig
                        let cFirst = complement(s2Rev[j0])
                        if let d3 = TmCalculator.threePrimeDangleParams["\(cFirst)\(s2Rev[j0 - 1])"] {
                            candDH += d3.dH
                            candDS += d3.dS
                        }
                    }

                    // Dangling ends at right boundary (curI, curJ)
                    if curI < n1 - 1 {
                        if let d3 = TmCalculator.threePrimeDangleParams["\(s1[curI])\(s1[curI + 1])"] {
                            candDH += d3.dH
                            candDS += d3.dS
                        }
                    }
                    if curJ < n2 - 1 {
                        if let d5 = TmCalculator.fivePrimeDangleParams["\(s2Rev[curJ + 1])\(s1[curI])"] {
                            candDH += d5.dH
                            candDS += d5.dS
                        }
                    }

                    let steps = max(1, (curI - i0))
                    candDS += saltPerStep * Double(steps)

                    let candDG = candDH - (tempK * candDS) / 1000.0
                    if candDG < bestDG {
                        bestDG = candDG
                        bestDH = candDH
                        bestDS = candDS
                        bestOffset = offset
                        bestPairs = pairs
                    }
                }
            }
        }

        guard !bestPairs.isEmpty, bestDG < -0.5, bestDS < 0 else {
            return .none(kind: kind)
        }

        let rGas = 1.9872
        let cMolar = max(1e-9, conditions.dnaConc * 1e-9)
        let tm = (bestDH * 1000.0) / (bestDS + rGas * log(cMolar)) - 273.15

        // 3' end of s1 is index >= n1 - 3; 3' end of s2Orig is index <= 2 in s2Rev
        let anchored3 = bestPairs.contains { pair in
            pair.0 >= n1 - 3 || pair.1 <= 2
        }

        let ascii = renderDuplexASCII(s1: s1, s2Rev: s2Rev, offset: bestOffset, pairs: bestPairs)
        let risk = classifyRisk(
            kind: kind,
            dg: bestDG,
            threePrimeAnchored: anchored3,
            alertThreshold: dgAlertThreshold
        )

        return StructureResult(
            kind: kind,
            structureFound: true,
            dg: round2(bestDG),
            dh: round2(bestDH),
            ds: round2(bestDS),
            tm: round1(tm),
            threePrimeAnchored: anchored3,
            pairedBaseCount: bestPairs.count,
            asciiStructure: ascii,
            riskLevel: risk
        )
    }

    // MARK: - Risk Classification & ASCII Diagram Formatting

    private static func classifyRisk(
        kind: StructureKind,
        dg: Double,
        threePrimeAnchored: Bool,
        alertThreshold: Double
    ) -> RiskLevel {
        switch kind {
        case .hairpin:
            if (threePrimeAnchored && dg <= alertThreshold) || dg <= (alertThreshold - 3.0) {
                return .high
            } else if dg <= alertThreshold {
                return .moderate
            }
            return .safe
        case .homodimer, .heterodimer:
            if (threePrimeAnchored && dg <= alertThreshold) || dg <= (alertThreshold - 4.5) {
                return .high
            } else if dg <= alertThreshold {
                return .moderate
            }
            return .safe
        }
    }

    private static func renderHairpinASCII(chars: [Character], pairs: [(Int, Int)]) -> String {
        let n = chars.count
        guard let outer = pairs.first, let inner = pairs.last else { return "" }
        var mark = Array(repeating: Character("-"), count: n)
        for (l, r) in pairs {
            if l < n { mark[l] = "/" }
            if r < n { mark[r] = "\\" }
        }
        let primer3Lines = [
            "SEQ\t" + String(mark),
            "STR\t" + String(chars)
        ]

        // Also build folded stem-loop diagram for intuitive visual inspection
        var topStem = "5'- "
        var midBonds = "    "
        var botStem = "3'- "
        if outer.0 > 0 {
            let prefix = String(chars[0..<outer.0])
            topStem += prefix
            midBonds += String(repeating: " ", count: prefix.count)
            botStem += String(repeating: " ", count: prefix.count)
        }
        let pairSet = Set(pairs.map { "\($0.0):\($0.1)" })
        let stemLen = inner.0 - outer.0 + 1
        for k in 0..<stemLen {
            let lIdx = outer.0 + k
            let rIdx = outer.1 - k
            let bTop = lIdx < n ? chars[lIdx] : " "
            let bBot = rIdx >= 0 && rIdx < n ? chars[rIdx] : " "
            topStem.append(bTop)
            botStem.append(bBot)
            midBonds.append(pairSet.contains("\(lIdx):\(rIdx)") ? "|" : ".")
        }
        let loopSeq = (inner.0 + 1 <= inner.1 - 1) ? String(chars[(inner.0 + 1)...(inner.1 - 1)]) : ""
        topStem += " ╭" + loopSeq + "╮"
        midBonds += "  " + String(repeating: " ", count: loopSeq.count) + " "
        botStem += " ╰" + String(repeating: "─", count: loopSeq.count) + "╯"

        return (primer3Lines + [topStem, midBonds, botStem]).joined(separator: "\n")
    }

    private static func renderDuplexASCII(
        s1: [Character],
        s2Rev: [Character],
        offset: Int,
        pairs: [(Int, Int)]
    ) -> String {
        let n1 = s1.count
        let n2 = s2Rev.count
        let minCoord = min(0, offset)
        let maxCoord = max(n1 - 1, (n2 - 1) + offset)
        let totalWidth = maxCoord - minCoord + 1
        guard totalWidth > 0 else { return "" }

        let pairedI = Set(pairs.map { $0.0 })
        let pairedJ = Set(pairs.map { $0.1 })

        var seqTopUnpaired = Array(repeating: Character(" "), count: totalWidth)
        var seqTopPaired   = Array(repeating: Character(" "), count: totalWidth)
        var bondRow        = Array(repeating: Character(" "), count: totalWidth)
        var strBotPaired   = Array(repeating: Character(" "), count: totalWidth)
        var strBotUnpaired = Array(repeating: Character(" "), count: totalWidth)

        for col in 0..<totalWidth {
            let coord = minCoord + col
            let i = coord
            let j = coord - offset
            let has1 = (i >= 0 && i < n1)
            let has2 = (j >= 0 && j < n2)

            if has1 {
                if pairedI.contains(i) {
                    seqTopPaired[col] = s1[i]
                } else {
                    seqTopUnpaired[col] = s1[i]
                }
            }
            if has2 {
                if pairedJ.contains(j) {
                    strBotPaired[col] = s2Rev[j]
                } else {
                    strBotUnpaired[col] = s2Rev[j]
                }
            }
            if has1 && has2 && pairedI.contains(i) && pairedJ.contains(j) {
                bondRow[col] = "|"
            }
        }

        return [
            "SEQ\t5'- " + String(seqTopUnpaired),
            "SEQ\t    " + String(seqTopPaired) + " -3'",
            "   \t    " + String(bondRow),
            "STR\t    " + String(strBotPaired) + " -5'",
            "STR\t3'- " + String(strBotUnpaired)
        ].joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func cleanACGT(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw.uppercased() {
            switch ch {
            case "A", "C", "G", "T":
                out.append(ch)
            case "U":
                out.append("T")
            default:
                break
            }
        }
        return out
    }

    private static func isComplementary(_ a: Character, _ b: Character) -> Bool {
        switch (a, b) {
        case ("A", "T"), ("T", "A"), ("C", "G"), ("G", "C"):
            return true
        default:
            return false
        }
    }

    private static func complement(_ b: Character) -> Character {
        switch b {
        case "A": return "T"
        case "T": return "A"
        case "C": return "G"
        case "G": return "C"
        default:  return b
        }
    }

    private static func isAT(_ b: Character) -> Bool {
        b == "A" || b == "T"
    }

    private static func round1(_ v: Double) -> Double {
        (v * 10.0).rounded() / 10.0
    }

    private static func round2(_ v: Double) -> Double {
        (v * 100.0).rounded() / 100.0
    }
}
