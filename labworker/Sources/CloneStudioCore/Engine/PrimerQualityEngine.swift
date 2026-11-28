import Foundation

/// Oligonucleotide secondary-structure thermodynamic evaluator (hairpin, homodimer, heterodimer)
/// upgraded to Zuker–Stiegler dynamic programming (UNAFold / Primer3 `thal` equivalent):
/// - Unified SantaLucia & Hicks (2004) nearest-neighbor parameters (eliminating 1998/2004 mix)
/// - Bidirectional internal mismatch lookup (5'-p1p2-3'/3'-q1q2-5' & 180-deg rotated revKey)
/// - Exact strand-oriented dangling ends & terminal mismatches (no double-counting opposite dangles)
/// - Continuous DNA hairpin loop entropy with DNA Jacobson–Stockmayer 2.44 coefficient & triloop/tetraloop bonuses
/// - 1-bp and multi-base Bulge loops + Internal loops (>= 2 nt) via Zuker–Stiegler DP
/// - Self-complementary homodimer symmetry penalty (+0.43 kcal/mol, dS = -1.4 cal/K/mol) & equimolar heterodimer C_T/4
/// - 3'-pentamer dG stability screening (<= -9.0 kcal/mol non-specific priming alert) & extendable 3'-OH risk
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
        /// Whether the 3'-OH terminal base itself is paired (directly extendable by DNA polymerase)
        public let threePrimeExtendableRisk: Bool
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
            threePrimeExtendableRisk: Bool = false,
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
            self.threePrimeExtendableRisk = threePrimeExtendableRisk
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
                threePrimeExtendableRisk: false,
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
        /// 3'-terminal pentamer duplex stability dG (kcal/mol); <= -9.0 kcal/mol indicates high non-specific 3' priming risk
        public let threePrimePentamerDG: Double
        public let overallRisk: RiskLevel

        public var isThreePrimeStabilityHighRisk: Bool {
            threePrimePentamerDG <= -9.0
        }

        public init(
            sequence: String,
            conditions: Conditions,
            hairpin: StructureResult,
            homodimer: StructureResult,
            threePrimePentamerDG: Double = 0.0,
            overallRisk: RiskLevel
        ) {
            self.sequence = sequence
            self.conditions = conditions
            self.hairpin = hairpin
            self.homodimer = homodimer
            self.threePrimePentamerDG = threePrimePentamerDG
            self.overallRisk = overallRisk
        }

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

    // MARK: - Unified SantaLucia & Hicks (2004) DNA Parameters (aligned with TmCalculator)

    private static let rGas = 1.9872

    private static let nn2004: [String: (dH: Double, dS: Double)] = [
        "AA": (-7.6, -21.3), "TT": (-7.6, -21.3),
        "AT": (-7.2, -20.4), "TA": (-7.2, -21.3),
        "CA": (-8.5, -22.7), "TG": (-8.5, -22.7),
        "GT": (-8.4, -22.4), "AC": (-8.4, -22.4),
        "CT": (-7.8, -21.0), "AG": (-7.8, -21.0),
        "GA": (-8.2, -22.2), "TC": (-8.2, -22.2),
        "CG": (-10.6, -27.2), "GC": (-9.8, -24.4),
        "GG": (-8.0, -19.9), "CC": (-8.0, -19.9)
    ]

    /// SantaLucia & Hicks (2004) Table 3 DNA hairpin loop entropy penalties (cal/(K*mol)) at 1M Na+ for sizes 3...12
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

    /// SantaLucia & Hicks (2004) DNA triloop & tetraloop stabilizing bonuses (dH kcal/mol, dS cal/(K*mol))
    /// Key = closing 5' base + loop bases + closing 3' base
    private static let specialHairpinLoops: [String: (dH: Double, dS: Double)] = [
        "CGAAG": (-2.0, -3.5), "CGAAA": (-2.0, -3.5),
        "CGAAAG": (-3.0, -5.5), "CGCAAG": (-2.5, -4.5), "CGAGAG": (-2.5, -4.5),
        "GGAAAC": (-2.5, -4.5), "GGCAAC": (-2.0, -3.5), "GGTTAC": (-2.0, -3.5),
        "CGAATG": (-2.0, -4.0), "CGTTAG": (-2.0, -4.0), "TGGAAA": (-1.5, -2.5)
    ]

    /// SantaLucia & Hicks (2004) Table 3 DNA bulge loop initiation dG37 (kcal/mol) converted to pure entropic dS = -dG37*1000/310.15
    private static let bulgeInitDG37: [Int: Double] = [
        1: 4.0, 2: 2.9, 3: 3.1, 4: 3.2, 5: 3.3, 6: 3.5
    ]

    /// SantaLucia & Hicks (2004) Table 3 DNA internal loop initiation dG37 (kcal/mol) for total unpaired size n >= 3
    private static let internalLoopInitDG37: [Int: Double] = [
        3: 3.2, 4: 3.6, 5: 4.0, 6: 4.4, 7: 4.6, 8: 4.8
    ]

    /// Continuous DNA hairpin loop entropy (SantaLucia 2004 DNA Jacobson-Stockmayer coeff = 2.44, zero jump at n=12->13)
    public static func hairpinLoopEntropy(length loopLen: Int) -> Double {
        if let v = hairpinLoopDS[loopLen] { return v }
        let n = max(12, loopLen)
        return -15.10 - 2.44 * rGas * log(Double(n) / 12.0)
    }

    private static func bulgeInitiation(size k: Int) -> (dH: Double, dS: Double) {
        let dg37: Double
        if let v = bulgeInitDG37[k] {
            dg37 = v
        } else {
            dg37 = 3.5 + 2.44 * rGas * 0.31015 * log(Double(max(6, k)) / 6.0)
        }
        return (0.0, -dg37 * 1000.0 / 310.15)
    }

    private static func internalLoopInitiation(n1: Int, n2: Int) -> (dH: Double, dS: Double) {
        let total = n1 + n2
        let baseDG: Double
        if let v = internalLoopInitDG37[total] {
            baseDG = v
        } else {
            baseDG = 4.8 + 2.44 * rGas * 0.31015 * log(Double(max(8, total)) / 8.0)
        }
        // SantaLucia 2004 asymmetry penalty: 0.3 * |n1 - n2| kcal/mol
        let asymDG = 0.3 * Double(abs(n1 - n2))
        return (0.0, -(baseDG + asymDG) * 1000.0 / 310.15)
    }

    // MARK: - 3'-Pentamer Stability (Primer3 MAX_END_STABILITY)

    /// Computes exact SantaLucia & Hicks (2004) Gibbs free energy dG (kcal/mol) of the 3'-terminal 5 bases
    /// Values <= -9.0 kcal/mol indicate excessive 3' stability (risk of non-specific priming / mispriming).
    public static func threePrimePentamerDG(
        _ rawSeq: String,
        conditions: Conditions = .standard
    ) -> Double {
        let clean = cleanACGT(rawSeq)
        guard clean.count >= 5 else { return 0.0 }
        let pent = Array(clean.suffix(5))
        // Rychlik (1995) / Primer3 MAX_END_STABILITY standard reference: 25 °C (298.15 K), 1 M Na+
        // (At 37 °C + 50 mM Na+, even CGCGC is only -7.97 kcal/mol; at 25 °C / 1 M Na+, CGCGC = -10.03 <= -9.0 threshold)
        _ = conditions
        let tempK = 298.15

        var dh = 0.0
        var ds = 0.0
        if isAT(pent[4]) { dh += 2.2; ds += 6.9 }
        for i in 0..<4 {
            if let st = nn2004["\(pent[i])\(pent[i + 1])"] {
                dh += st.dH
                ds += st.dS
            }
        }
        return round2(dh - (tempK * ds) / 1000.0)
    }

    // MARK: - Public API (Zuker–Stiegler DP)

    /// Evaluate single-strand hairpin stability via Zuker–Stiegler DP (supports stacks, 1x1 mismatches, bulges 1..6, internal loops >= 2 nt)
    public static func calcHairpin(
        _ rawSeq: String,
        conditions: Conditions = .standard,
        dgAlertThreshold: Double = -3.0
    ) -> StructureResult {
        let clean = cleanACGT(rawSeq)
        let seq = clean.count > 60 ? String(clean.suffix(60)) : clean
        let chars = Array(seq)
        let n = chars.count
        guard n >= 7 else { return .none(kind: .hairpin) }

        let tempK = conditions.tempKelvin
        let naEq = conditions.equivalentMonovalentMolar
        let saltPerStep = 0.368 * log(naEq)

        struct DPState {
            var dg: Double
            var dh: Double
            var ds: Double
            var nextI: Int
            var nextJ: Int
            var pairedCount: Int
        }
        let inf = 1e9
        var dp = Array(repeating: Array(repeating: DPState(dg: inf, dh: 0, ds: 0, nextI: -1, nextJ: -1, pairedCount: 0), count: n), count: n)

        // Fill DP table bottom-up by span = j - i (minimum apical loop = 3 => span >= 4)
        for span in 4..<n {
            for i in 0..<(n - span) {
                let j = i + span
                guard isComplementary(chars[i], chars[j]) else { continue }

                var best = DPState(dg: inf, dh: 0, ds: 0, nextI: -1, nextJ: -1, pairedCount: 1)

                // 1. Direct apical hairpin loop closed by (i, j)
                let loopLen = j - i - 1
                if loopLen >= 3 {
                    var lDH = 0.0
                    var lDS = hairpinLoopEntropy(length: loopLen)
                    if loopLen >= 4 {
                        if let mm = TmCalculator.lookupTerminalMismatch(chars[i], chars[i + 1], chars[j], chars[j - 1]) {
                            lDH += mm.dH
                            lDS += mm.dS
                        } else if isComplementary(chars[i + 1], chars[j - 1]) {
                            lDH += -6.0
                            lDS += -16.58
                        } else {
                            lDH += -3.5
                            lDS += -9.5
                        }
                    } else if isAT(chars[i]) {
                        // Triloop closing AT penalty (SantaLucia 2004)
                        lDH += 2.2
                        lDS += 6.9
                    }
                    if loopLen == 3 || loopLen == 4 {
                        let loopKey = String(chars[i...j])
                        if let bonus = specialHairpinLoops[loopKey] {
                            lDH += bonus.dH
                            lDS += bonus.dS
                        }
                    }
                    let lDG = lDH - (tempK * lDS) / 1000.0
                    best = DPState(dg: lDG, dh: lDH, ds: lDS, nextI: -1, nextJ: -1, pairedCount: 1)
                }

                // 2. Stacked WC pair (i, j) enclosing (i+1, j-1)
                if span >= 6 {
                    let sub = dp[i + 1][j - 1]
                    if sub.dg < inf * 0.5, let st = nn2004["\(chars[i])\(chars[i + 1])"] {
                        let cDH = sub.dh + st.dH
                        let cDS = sub.ds + st.dS + saltPerStep
                        let cDG = cDH - (tempK * cDS) / 1000.0
                        if cDG < best.dg {
                            best = DPState(dg: cDG, dh: cDH, ds: cDS, nextI: i + 1, nextJ: j - 1, pairedCount: sub.pairedCount + 1)
                        }
                    }
                }

                // 3. Bulge loops (1..6 nt on left or right strand)
                for bSize in 1...6 {
                    // Left bulge: (i, j) encloses (i + 1 + bSize, j - 1)
                    let niL = i + 1 + bSize
                    let njL = j - 1
                    if njL - niL >= 4 {
                        let sub = dp[niL][njL]
                        if sub.dg < inf * 0.5 {
                            let initB = bulgeInitiation(size: bSize)
                            var cDH = sub.dh + initB.dH
                            var cDS = sub.ds + initB.dS
                            if bSize == 1, let st = nn2004["\(chars[i])\(chars[niL])"] {
                                // 1-nt bulge retains intervening base-pair stack (SantaLucia 2004)
                                cDH += st.dH
                                cDS += st.dS + saltPerStep
                            } else {
                                if isAT(chars[i]) { cDH += 2.2; cDS += 6.9 }
                                if isAT(chars[niL]) { cDH += 2.2; cDS += 6.9 }
                            }
                            let cDG = cDH - (tempK * cDS) / 1000.0
                            if cDG < best.dg {
                                best = DPState(dg: cDG, dh: cDH, ds: cDS, nextI: niL, nextJ: njL, pairedCount: sub.pairedCount + 1)
                            }
                        }
                    }
                    // Right bulge: (i, j) encloses (i + 1, j - 1 - bSize)
                    let niR = i + 1
                    let njR = j - 1 - bSize
                    if njR - niR >= 4 {
                        let sub = dp[niR][njR]
                        if sub.dg < inf * 0.5 {
                            let initB = bulgeInitiation(size: bSize)
                            var cDH = sub.dh + initB.dH
                            var cDS = sub.ds + initB.dS
                            if bSize == 1, let st = nn2004["\(chars[i])\(chars[niR])"] {
                                cDH += st.dH
                                cDS += st.dS + saltPerStep
                            } else {
                                if isAT(chars[i]) { cDH += 2.2; cDS += 6.9 }
                                if isAT(chars[niR]) { cDH += 2.2; cDS += 6.9 }
                            }
                            let cDG = cDH - (tempK * cDS) / 1000.0
                            if cDG < best.dg {
                                best = DPState(dg: cDG, dh: cDH, ds: cDS, nextI: niR, nextJ: njR, pairedCount: sub.pairedCount + 1)
                            }
                        }
                    }
                }

                // 4. Internal loops (1x1 mismatch via bidirectional lookup, plus k1 x k2 internal loops up to 4x4)
                for k1 in 1...4 {
                    for k2 in 1...4 {
                        let ni = i + 1 + k1
                        let nj = j - 1 - k2
                        if nj - ni < 4 { continue }
                        let sub = dp[ni][nj]
                        guard sub.dg < inf * 0.5 else { continue }
                        var cDH = sub.dh
                        var cDS = sub.ds
                        if k1 == 1 && k2 == 1 {
                            let m1 = TmCalculator.lookupInternalMismatch(chars[i], chars[i + 1], chars[j], chars[j - 1]) ?? (1.0, 0.0)
                            let m2 = TmCalculator.lookupInternalMismatch(chars[i + 1], chars[ni], chars[j - 1], chars[nj]) ?? (1.0, 0.0)
                            cDH += m1.dH + m2.dH
                            cDS += m1.dS + m2.dS + 2.0 * saltPerStep
                        } else {
                            let initIL = internalLoopInitiation(n1: k1, n2: k2)
                            let m1 = TmCalculator.lookupTerminalMismatch(chars[i], chars[i + 1], chars[j], chars[j - 1]) ?? (0.0, 0.0)
                            let m2 = TmCalculator.lookupTerminalMismatch(chars[ni - 1], chars[ni], chars[nj + 1], chars[nj]) ?? (0.0, 0.0)
                            cDH += initIL.dH + m1.dH + m2.dH
                            cDS += initIL.dS + m1.dS + m2.dS + saltPerStep
                        }
                        let cDG = cDH - (tempK * cDS) / 1000.0
                        if cDG < best.dg {
                            best = DPState(dg: cDG, dh: cDH, ds: cDS, nextI: ni, nextJ: nj, pairedCount: sub.pairedCount + 1)
                        }
                    }
                }

                dp[i][j] = best
            }
        }

        // Select globally optimal outer closing pair (i, j) with >= 3 paired bases + outer AT penalty + exact external dangle/TMM
        var bestDG = 0.0
        var bestDH = 0.0
        var bestDS = 0.0
        var bestOuter: (Int, Int)? = nil

        for i in 0..<(n - 6) {
            for j in (i + 6)..<n {
                let st = dp[i][j]
                guard st.dg < inf * 0.5, st.pairedCount >= 3 else { continue }
                var cDH = st.dh
                var cDS = st.ds
                if isAT(chars[i]) {
                    cDH += 2.2
                    cDS += 6.9
                }
                // Exact external terminal mismatch (SantaLucia & Peyret 2001 DNA_TMM1) or Bommarito (2000) dangle without arbitrary 0.5 scaling
                if i > 0 && j < n - 1 {
                    if let tmm = TmCalculator.lookupTerminalMismatch(chars[i - 1], chars[i], chars[j + 1], chars[j]) {
                        cDH += tmm.dH
                        cDS += tmm.dS
                    }
                } else if i > 0, let d5 = TmCalculator.fivePrimeDangleParams["\(chars[i - 1])\(chars[i])"] {
                    cDH += d5.dH
                    cDS += d5.dS
                } else if j < n - 1, let d3 = TmCalculator.threePrimeDangleParams["\(chars[j])\(chars[j + 1])"] {
                    cDH += d3.dH
                    cDS += d3.dS
                }
                let cDG = cDH - (tempK * cDS) / 1000.0
                if cDG < bestDG {
                    bestDG = cDG
                    bestDH = cDH
                    bestDS = cDS
                    bestOuter = (i, j)
                }
            }
        }

        guard let outer = bestOuter, bestDG < -0.2, bestDS < 0 else {
            return .none(kind: .hairpin)
        }

        // Backtrack pairs
        var bestPairs: [(Int, Int)] = []
        var ci = outer.0
        var cj = outer.1
        while ci >= 0 && cj >= 0 {
            bestPairs.append((ci, cj))
            let st = dp[ci][cj]
            ci = st.nextI
            cj = st.nextJ
        }

        let tm = (bestDH * 1000.0) / bestDS - 273.15
        let anchored3 = bestPairs.contains { $0.0 >= n - 3 || $0.1 >= n - 3 }
        let extendable3 = bestPairs.contains { $0.1 == n - 1 }
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
            threePrimeExtendableRisk: extendable3,
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

    /// Comprehensive single-primer QC report (Hairpin DP + Homodimer DP + 3'-pentamer dG)
    public static func evaluatePrimer(
        _ rawSeq: String,
        conditions: Conditions = .standard,
        hairpinAlertDg: Double = -3.0,
        dimerAlertDg: Double = -6.0
    ) -> SinglePrimerReport {
        let clean = cleanACGT(rawSeq)
        let hp = calcHairpin(clean, conditions: conditions, dgAlertThreshold: hairpinAlertDg)
        let hd = calcHomodimer(clean, conditions: conditions, dgAlertThreshold: dimerAlertDg)
        let pentDG = threePrimePentamerDG(clean, conditions: conditions)
        let risk = max(hp.riskLevel, hd.riskLevel)
        return SinglePrimerReport(
            sequence: clean,
            conditions: conditions,
            hairpin: hp,
            homodimer: hd,
            threePrimePentamerDG: pentDG,
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

    // MARK: - Internal Bimolecular Duplex Zuker–Stiegler DP

    private static func calcDuplexDimer(
        _ rawSeq1: String,
        _ rawSeq2: String,
        kind: StructureKind,
        conditions: Conditions,
        dgAlertThreshold: Double
    ) -> StructureResult {
        let s1Full = cleanACGT(rawSeq1)
        let s2Full = cleanACGT(rawSeq2)
        let s1 = Array(s1Full.count > 60 ? String(s1Full.suffix(60)) : s1Full)
        let s2Orig = Array(s2Full.count > 60 ? String(s2Full.suffix(60)) : s2Full)
        // Antiparallel strand 2 (3' -> 5' left-to-right)
        let s2Rev = Array(s2Orig.reversed())
        let n1 = s1.count
        let n2 = s2Rev.count
        guard n1 >= 4, n2 >= 4 else { return .none(kind: kind) }

        let tempK = conditions.tempKelvin
        let naEq = conditions.equivalentMonovalentMolar
        let saltPerStep = 0.368 * log(naEq)

        struct DuplexNode {
            var dg: Double
            var dh: Double
            var ds: Double
            var prevI: Int
            var prevJ: Int
            var startI: Int
            var startJ: Int
            var pairedCount: Int
        }
        let inf = 1e9
        var dp = Array(
            repeating: Array(repeating: DuplexNode(dg: inf, dh: 0, ds: 0, prevI: -1, prevJ: -1, startI: -1, startJ: -1, pairedCount: 0), count: n2),
            count: n1
        )

        for i in 0..<n1 {
            for j in 0..<n2 {
                guard isComplementary(s1[i], s2Rev[j]) else { continue }

                // 1. Open new duplex at left boundary (i, j)
                var openDH = 0.2
                var openDS = -5.7
                if isAT(s1[i]) {
                    openDH += 2.2
                    openDS += 6.9
                }
                // Exact left-boundary dangle / terminal mismatch (SantaLucia & Peyret 2001 DNA_TMM1)
                if i > 0 && j > 0 {
                    if let tmm = TmCalculator.lookupTerminalMismatch(s1[i - 1], s1[i], s2Rev[j - 1], s2Rev[j]) {
                        openDH += tmm.dH
                        openDS += tmm.dS
                    }
                } else if i > 0 {
                    // 5' dangle on strand 1: 5'-s1[i-1] s1[i]-3'
                    if let d5 = TmCalculator.fivePrimeDangleParams["\(s1[i - 1])\(s1[i])"] {
                        openDH += d5.dH
                        openDS += d5.dS
                    }
                } else if j > 0 {
                    // 3' dangle on strand 2 (5'->3' on s2Rev goes right-to-left): paired base s2Rev[j], 3'-dangle s2Rev[j-1]
                    if let d3 = TmCalculator.threePrimeDangleParams["\(s2Rev[j])\(s2Rev[j - 1])"] {
                        openDH += d3.dH
                        openDS += d3.dS
                    }
                }
                let openDG = openDH - (tempK * openDS) / 1000.0
                var best = DuplexNode(dg: openDG, dh: openDH, ds: openDS, prevI: -1, prevJ: -1, startI: i, startJ: j, pairedCount: 1)

                // 2. Extend by WC stack from (i-1, j-1)
                if i > 0 && j > 0 {
                    let prev = dp[i - 1][j - 1]
                    if prev.dg < inf * 0.5, let st = nn2004["\(s1[i - 1])\(s1[i])"] {
                        let cDH = prev.dh + st.dH
                        let cDS = prev.ds + st.dS + saltPerStep
                        let cDG = cDH - (tempK * cDS) / 1000.0
                        if cDG < best.dg {
                            best = DuplexNode(dg: cDG, dh: cDH, ds: cDS, prevI: i - 1, prevJ: j - 1, startI: prev.startI, startJ: prev.startJ, pairedCount: prev.pairedCount + 1)
                        }
                    }
                }

                // 3. Extend by 1..4 bp Bulge on strand 1 or strand 2
                for bSize in 1...4 {
                    if i - 1 - bSize >= 0 && j - 1 >= 0 {
                        let pi = i - 1 - bSize
                        let pj = j - 1
                        let prev = dp[pi][pj]
                        if prev.dg < inf * 0.5 {
                            let initB = bulgeInitiation(size: bSize)
                            var cDH = prev.dh + initB.dH
                            var cDS = prev.ds + initB.dS
                            if bSize == 1, let st = nn2004["\(s1[pi])\(s1[i])"] {
                                cDH += st.dH
                                cDS += st.dS + saltPerStep
                            } else {
                                if isAT(s1[pi]) { cDH += 2.2; cDS += 6.9 }
                                if isAT(s1[i]) { cDH += 2.2; cDS += 6.9 }
                            }
                            let cDG = cDH - (tempK * cDS) / 1000.0
                            if cDG < best.dg {
                                best = DuplexNode(dg: cDG, dh: cDH, ds: cDS, prevI: pi, prevJ: pj, startI: prev.startI, startJ: prev.startJ, pairedCount: prev.pairedCount + 1)
                            }
                        }
                    }
                    if i - 1 >= 0 && j - 1 - bSize >= 0 {
                        let pi = i - 1
                        let pj = j - 1 - bSize
                        let prev = dp[pi][pj]
                        if prev.dg < inf * 0.5 {
                            let initB = bulgeInitiation(size: bSize)
                            var cDH = prev.dh + initB.dH
                            var cDS = prev.ds + initB.dS
                            if bSize == 1, let st = nn2004["\(s1[pi])\(s1[i])"] {
                                cDH += st.dH
                                cDS += st.dS + saltPerStep
                            } else {
                                if isAT(s1[pi]) { cDH += 2.2; cDS += 6.9 }
                                if isAT(s1[i]) { cDH += 2.2; cDS += 6.9 }
                            }
                            let cDG = cDH - (tempK * cDS) / 1000.0
                            if cDG < best.dg {
                                best = DuplexNode(dg: cDG, dh: cDH, ds: cDS, prevI: pi, prevJ: pj, startI: prev.startI, startJ: prev.startJ, pairedCount: prev.pairedCount + 1)
                            }
                        }
                    }
                }

                // 4. Extend by Internal Loop (1x1 exact bidirectional mismatch + k1 x k2 internal loops up to 3x3)
                for k1 in 1...3 {
                    for k2 in 1...3 {
                        let pi = i - 1 - k1
                        let pj = j - 1 - k2
                        if pi < 0 || pj < 0 { continue }
                        let prev = dp[pi][pj]
                        guard prev.dg < inf * 0.5 else { continue }
                        var cDH = prev.dh
                        var cDS = prev.ds
                        if k1 == 1 && k2 == 1 {
                            let m1 = TmCalculator.lookupInternalMismatch(s1[pi], s1[pi + 1], s2Rev[pj], s2Rev[pj + 1]) ?? (1.2, 2.0)
                            let m2 = TmCalculator.lookupInternalMismatch(s1[pi + 1], s1[i], s2Rev[pj + 1], s2Rev[j]) ?? (1.2, 2.0)
                            cDH += m1.dH + m2.dH
                            cDS += m1.dS + m2.dS + 2.0 * saltPerStep
                        } else {
                            let initIL = internalLoopInitiation(n1: k1, n2: k2)
                            let m1 = TmCalculator.lookupTerminalMismatch(s1[pi], s1[pi + 1], s2Rev[pj], s2Rev[pj + 1]) ?? (0.0, 0.0)
                            let m2 = TmCalculator.lookupTerminalMismatch(s1[i - 1], s1[i], s2Rev[j - 1], s2Rev[j]) ?? (0.0, 0.0)
                            cDH += initIL.dH + m1.dH + m2.dH
                            cDS += initIL.dS + m1.dS + m2.dS + saltPerStep
                        }
                        let cDG = cDH - (tempK * cDS) / 1000.0
                        if cDG < best.dg {
                            best = DuplexNode(dg: cDG, dh: cDH, ds: cDS, prevI: pi, prevJ: pj, startI: prev.startI, startJ: prev.startJ, pairedCount: prev.pairedCount + 1)
                        }
                    }
                }

                dp[i][j] = best
            }
        }

        // Evaluate right-boundary closure (AT penalty + right dangle/terminal mismatch + self-complementary symmetry penalty)
        var bestDG = 0.0
        var bestDH = 0.0
        var bestDS = 0.0
        var bestEnd: (Int, Int)? = nil
        var bestIsSelfSym = false

        for i in 0..<n1 {
            for j in 0..<n2 {
                let node = dp[i][j]
                guard node.dg < inf * 0.5, node.pairedCount >= 2 else { continue }
                var cDH = node.dh
                var cDS = node.ds
                if isAT(s1[i]) {
                    cDH += 2.2
                    cDS += 6.9
                }
                // Exact right-boundary dangle / terminal mismatch (SantaLucia & Peyret 2001 DNA_TMM1)
                if i < n1 - 1 && j < n2 - 1 {
                    if let tmm = TmCalculator.lookupTerminalMismatch(s1[i], s1[i + 1], s2Rev[j], s2Rev[j + 1]) {
                        cDH += tmm.dH
                        cDS += tmm.dS
                    }
                } else if i < n1 - 1 {
                    // 3' dangle on strand 1: 5'-s1[i] s1[i+1]-3'
                    if let d3 = TmCalculator.threePrimeDangleParams["\(s1[i])\(s1[i + 1])"] {
                        cDH += d3.dH
                        cDS += d3.dS
                    }
                } else if j < n2 - 1 {
                    // 5' dangle on strand 2 (5'->3' on s2Rev goes right-to-left): 5'-s2Rev[j+1] s2Rev[j]-3'
                    if let d5 = TmCalculator.fivePrimeDangleParams["\(s2Rev[j + 1])\(s2Rev[j])"] {
                        cDH += d5.dH
                        cDS += d5.dS
                    }
                }

                // Self-complementary homodimer symmetry correction (SantaLucia & Hicks 2004: dS_sym = -1.4 cal/K/mol, dG37 = +0.43 kcal/mol)
                var isSelfSym = false
                if kind == .homodimer && node.startI == (n2 - 1 - j) && i == (n2 - 1 - node.startJ) {
                    isSelfSym = true
                    cDS += -1.4
                }

                let cDG = cDH - (tempK * cDS) / 1000.0
                if cDG < bestDG {
                    bestDG = cDG
                    bestDH = cDH
                    bestDS = cDS
                    bestEnd = (i, j)
                    bestIsSelfSym = isSelfSym
                }
            }
        }

        guard let end = bestEnd, bestDG < -0.5, bestDS < 0 else {
            return .none(kind: kind)
        }

        // Backtrack pairs
        var bestPairs: [(Int, Int)] = []
        var ci = end.0
        var cj = end.1
        while ci >= 0 && cj >= 0 {
            bestPairs.append((ci, cj))
            let node = dp[ci][cj]
            ci = node.prevI
            cj = node.prevJ
        }
        bestPairs.reverse()

        // Equimolar concentration correction: C_T for self-complementary homodimer, C_T / 4 for non-self-complementary / heterodimer
        let cTotal = max(1e-9, conditions.dnaConc * 1e-9)
        let cEff = bestIsSelfSym ? cTotal : (cTotal / 4.0)
        let tm = (bestDH * 1000.0) / (bestDS + rGas * log(cEff)) - 273.15

        // 3' end of s1 is index >= n1 - 3; 3' end of s2Orig is index <= 2 in s2Rev
        let anchored3 = bestPairs.contains { pair in
            pair.0 >= n1 - 3 || pair.1 <= 2
        }
        let extendable3 = bestPairs.contains { pair in
            pair.0 == n1 - 1 || pair.1 == 0
        }

        let bestOffset = bestPairs.first.map { $0.0 - $0.1 } ?? 0
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
            threePrimeExtendableRisk: extendable3,
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
        let stemLen = max(1, min(inner.0 - outer.0 + 1, outer.1 - inner.1 + 1))
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
