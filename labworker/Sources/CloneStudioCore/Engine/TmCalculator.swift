import Foundation

/// 引物退火温度与熔解温度 (Tm) 计算引擎
/// 完全遵循 SnapGene 官方热力学算法：
/// 1. SantaLucia & Hicks (2004) Annu Rev Biophys Biomol Struct 33:415-40 (Nearest-Neighbor 核心参数、起始自由能、末端 A·T 罚分、自互补对称校正、单价阳离子熵校正)
/// 2. Bommarito, Peyret & SantaLucia (2000) Nucleic Acids Res 28:1929-34 (5' 与 3' 悬垂端 / Dangling Ends 自由能增量，共 32 项)
/// 3. Allawi & SantaLucia (1997-1998) / Peyret et al. (1999) (内部错配 Internal Mismatches 参数)
/// 4. Watkins & SantaLucia (2005) Nucleic Acids Res 33:6258-67 (次黄嘌呤 Deoxyinosine 'I' 配对参数，U 等同于 T，简并碱基取均值)
/// 5. SnapGene 标准反应条件假设：[Na+] = 50 mM (0.05 M)，PCR 引物浓度 = 0.25 μM (250 nM)
public struct TmCalculator {
    
    /// 计算结果
    public struct Result: Sendable, Equatable {
        public let length: Int
        public let gcPercent: Double
        /// 精确到 0.1 ℃ 的熔解温度
        public let tm: Double
        /// SnapGene 图谱整数四舍五入显示的 Tm (℃)
        public let snapGeneIntegerTm: Int
        public let recommendedTa: Double
        
        public init(
            length: Int,
            gcPercent: Double,
            tm: Double,
            snapGeneIntegerTm: Int? = nil,
            recommendedTa: Double? = nil
        ) {
            self.length = length
            self.gcPercent = gcPercent
            self.tm = tm
            self.snapGeneIntegerTm = snapGeneIntegerTm ?? Int(tm.rounded())
            self.recommendedTa = recommendedTa ?? tm
        }
    }
    
    // MARK: - 1. SantaLucia & Hicks (2004) Watson-Crick 近邻热力学参数 (dH: kcal/mol, dS: cal/(K·mol))
    public static let nnParams2004: [String: (dH: Double, dS: Double)] = [
        "AA": (-7.6, -21.3), "TT": (-7.6, -21.3),
        "AT": (-7.2, -20.4), "TA": (-7.2, -21.3),
        "CA": (-8.5, -22.7), "TG": (-8.5, -22.7),
        "GT": (-8.4, -22.4), "AC": (-8.4, -22.4),
        "CT": (-7.8, -21.0), "AG": (-7.8, -21.0),
        "GA": (-8.2, -22.2), "TC": (-8.2, -22.2),
        "CG": (-10.6, -27.2), "GC": (-9.8, -24.4),
        "GG": (-8.0, -19.9), "CC": (-8.0, -19.9),
        // Watkins & SantaLucia (2005) Deoxyinosine (I) Watson-Crick-like contexts
        "AI": (-8.3, -25.0), "IA": (-4.9, -15.8),
        "CI": (-5.4, -13.7), "IC": (-5.0, -12.6),
        "GI": (-6.8, -19.1), "IG": (-7.6, -22.0),
        "TI": (-3.4, -11.2), "IT": (-6.5, -22.0),
        "II": (-3.3, -11.9)
    ]
    
    // MARK: - 2. Bommarito, Peyret & SantaLucia (2000) Table 2 — 5' 悬垂端参数 (5'-dangling base X 紧邻首配对碱基 Y: key = "XY")
    /// 结构示意:
    /// 5' - ... X Y ... - 3'  (引物链: X 为 5' 同源臂/悬垂端最末一个未配对碱基，Y 为 3' 退火区第 1 个配对碱基)
    /// 3' - ... . Z ... - 5'  (模板链: Z 为 Y 的互补碱基)
    public static let fivePrimeDangleParams: [String: (dH: Double, dS: Double)] = [
        "AA": (0.2, 2.3),    "AC": (-6.3, -17.1), "AG": (-3.7, -10.0), "AT": (-2.9, -7.6),
        "CA": (0.6, 3.3),    "CC": (-4.4, -12.6), "CG": (-4.0, -11.9), "CT": (-4.1, -13.0),
        "GA": (-1.1, -1.6),  "GC": (-5.1, -14.0), "GG": (-3.9, -10.9), "GT": (-4.2, -15.0),
        "TA": (-6.9, -20.0), "TC": (-4.0, -10.9), "TG": (-4.9, -13.8), "TT": (-0.2, -0.5)
    ]
    
    // MARK: - 3. Bommarito, Peyret & SantaLucia (2000) Table 2 — 3' 悬垂端参数 (末配对碱基 Y 紧邻 3'-dangling base X: key = "YX")
    /// 结构示意:
    /// 5' - ... Y X ... - 3'  (Y 为最末配对碱基，X 为 3' 悬垂未配对碱基)
    /// 3' - ... Z . ... - 5'  (Z 为 Y 的互补碱基)
    public static let threePrimeDangleParams: [String: (dH: Double, dS: Double)] = [
        "AA": (-0.5, -1.1),  "AC": (4.7, 14.2),   "AG": (-4.1, -13.1), "AT": (-3.8, -12.6),
        "CA": (-5.9, -16.5), "CC": (-2.6, -7.4),  "CG": (-3.2, -10.4), "CT": (-5.2, -15.0),
        "GA": (-2.1, -3.9),  "GC": (-0.2, -0.1),  "GG": (-3.9, -11.2), "GT": (-4.4, -13.1),
        "TA": (-0.7, -0.8),  "TC": (4.4, 14.9),   "TG": (-1.6, -3.6),  "TT": (2.9, 10.4)
    ]
    
    // MARK: - 4. Allawi & SantaLucia (1997-1998) / Peyret et al. (1999) 内部错配参数 (key = "XY/ZW", 5'-XY-3' / 3'-ZW-5')
    public static let internalMismatchParams: [String: (dH: Double, dS: Double)] = [
        "AG/TT": (1.0, 0.9),   "AT/TG": (-2.5, -8.3), "CG/GT": (-4.1, -11.7), "CT/GG": (-2.8, -8.0),
        "GG/CT": (3.3, 10.4),  "GG/TT": (5.8, 16.3),  "GT/CG": (-4.4, -12.3), "GT/TG": (4.1, 9.5),
        "TG/AT": (-0.1, -1.7), "TG/GT": (-1.4, -6.2), "TT/AG": (-1.3, -5.3),  "AA/TG": (-0.6, -2.3),
        "AG/TA": (-0.7, -2.3), "CA/GG": (-0.7, -2.3), "CG/GA": (-4.0, -13.2), "GA/CG": (-0.6, -1.0),
        "GG/CA": (0.5, 3.2),   "TA/AG": (0.7, 0.7),   "TG/AA": (3.0, 7.4),    "AC/TT": (0.7, 0.2),
        "AT/TC": (-1.2, -6.2), "CC/GT": (-0.8, -4.5), "CT/GC": (-1.5, -6.1),  "GC/CT": (2.3, 5.4),
        "GT/CC": (5.2, 13.5),  "TC/AT": (1.2, 0.7),   "TT/AC": (1.0, 0.7),    "AA/TC": (2.3, 4.6),
        "AC/TA": (5.3, 14.6),  "CA/GC": (1.9, 3.7),   "CC/GA": (0.6, -0.6),   "GA/CC": (5.2, 14.2),
        "GC/CA": (-0.7, -3.8), "TA/AC": (3.4, 8.0),   "TC/AA": (7.6, 20.2),   "AA/TA": (1.2, 1.7),
        "CA/GA": (-0.9, -4.2), "GA/CA": (-2.9, -9.8), "TA/AA": (4.7, 12.9),   "AC/TC": (0.0, -4.4),
        "CC/GC": (-1.5, -7.2), "GC/CC": (3.6, 8.9),   "TC/AC": (6.1, 16.4),   "AG/TG": (-3.1, -9.5),
        "CG/GG": (-4.9, -15.3),"GG/CG": (-6.0, -15.8),"TG/AG": (1.6, 3.6),    "AT/TT": (-2.7, -10.8),
        "CT/GT": (-5.0, -15.8),"GT/CT": (-2.2, -8.4), "TT/AT": (0.2, -1.5)
    ]
    
    /// IUPAC 简并碱基展开表（SnapGene 规范：简并碱基热力学参数取各展开碱基的算术平均值；U 视为 T）
    private static let iupacExpansion: [Character: [Character]] = [
        "A": ["A"], "T": ["T"], "U": ["T"], "C": ["C"], "G": ["G"], "I": ["I"],
        "R": ["A", "G"], "Y": ["C", "T"], "S": ["G", "C"], "W": ["A", "T"],
        "K": ["G", "T"], "M": ["A", "C"],
        "B": ["C", "G", "T"], "D": ["A", "G", "T"], "H": ["A", "C", "T"], "V": ["A", "C", "G"],
        "N": ["A", "T", "C", "G"]
    ]
    
    /// 清洗并规范化寡核苷酸序列（保留 ATCGUI 及 IUPAC 简并字母，并将 U 转为 T）
    public static func normalizeOligo(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw.uppercased() {
            if ch == "U" {
                out.append("T")
            } else if iupacExpansion[ch] != nil {
                out.append(ch)
            }
        }
        return out
    }
    
    /// 计算引物 Tm 值 (完全遵循 SnapGene 算法：SantaLucia & Hicks 2004 + Bommarito 2000 悬垂端 + 50 mM Na+ / 250 nM Primer)
    /// - Parameters:
    ///   - sequence: 与模板配对退火的序列区段 (5' -> 3')
    ///   - fivePrimeOverhang: 引物 5' 端未配对悬垂序列（如同源重组臂或酶切保护碱基，可选）
    ///   - threePrimeOverhang: 引物 3' 端未配对悬垂序列（可选）
    ///   - naConcentration: Na+ 浓度 (mM)，SnapGene 标准为 50.0 mM
    ///   - primerConcNanoMolar: PCR 引物浓度 (nM)，SnapGene 标准为 250.0 nM (0.25 μM)
    public static func calculate(
        sequence: String,
        fivePrimeOverhang: String = "",
        threePrimeOverhang: String = "",
        naConcentration: Double = 50.0,
        primerConcNanoMolar: Double = 250.0
    ) -> Result {
        let cleanSeq = normalizeOligo(sequence)
        let n = cleanSeq.count
        guard n > 0 else {
            return Result(length: 0, gcPercent: 0, tm: 0, snapGeneIntegerTm: 0, recommendedTa: 0)
        }
        
        let gc = computeGCPercent(cleanSeq)
        guard n >= 2 else {
            return Result(length: n, gcPercent: (gc * 10).rounded() / 10.0, tm: 0, snapGeneIntegerTm: 0, recommendedTa: 0)
        }
        
        let naMolar = max(0.001, naConcentration / 1000.0)
        let primerMolar = max(1e-9, primerConcNanoMolar * 1e-9)
        let tm = calculateNearestNeighbor(
            cleanSeq,
            fivePrimeOverhang: normalizeOligo(fivePrimeOverhang),
            threePrimeOverhang: normalizeOligo(threePrimeOverhang),
            naMolar: naMolar,
            primerConc: primerMolar
        )
        
        let roundedTm = (tm * 10).rounded() / 10.0
        let intTm = Int(tm.rounded())
        
        return Result(
            length: n,
            gcPercent: (gc * 10).rounded() / 10.0,
            tm: roundedTm,
            snapGeneIntegerTm: intTm,
            recommendedTa: roundedTm
        )
    }
    
    /// 计算包含内部错配（如定点突变引物结合野生型模板）的双链 Tm
    /// - Parameters:
    ///   - primerSeq: 引物退火区序列 (5' -> 3')
    ///   - templateComplementSeq: 模板对应区段序列（与引物同向 5' -> 3' 的正义链序列，内部将自动取互补以比对错配）
    ///   - fivePrimeOverhang: 5' 悬垂序列
    public static func calculateWithTemplate(
        primerSeq: String,
        templateSenseSeq: String,
        fivePrimeOverhang: String = "",
        naConcentration: Double = 50.0,
        primerConcNanoMolar: Double = 250.0
    ) -> Result {
        let pClean = normalizeOligo(primerSeq)
        let tClean = normalizeOligo(templateSenseSeq)
        guard pClean.count >= 2, pClean.count == tClean.count else {
            return calculate(
                sequence: primerSeq,
                fivePrimeOverhang: fivePrimeOverhang,
                naConcentration: naConcentration,
                primerConcNanoMolar: primerConcNanoMolar
            )
        }
        
        let pChars = Array(pClean)
        let tChars = Array(tClean)
        let n = pChars.count
        
        var totalDH = 0.2
        var totalDS = -5.7
        
        for endBase in [pChars.first!, pChars.last!] {
            if isATBase(endBase) {
                totalDH += 2.2
                totalDS += 6.9
            }
        }
        
        for i in 0..<(n - 1) {
            let p1 = pChars[i]
            let p2 = pChars[i + 1]
            let t1 = tChars[i]
            let t2 = tChars[i + 1]
            if p1 == t1 && p2 == t2 {
                let (dh, ds) = lookupDinucleotide(p1, p2)
                totalDH += dh
                totalDS += ds
            } else {
                let c1 = complementBase(t1)
                let c2 = complementBase(t2)
                let key = "\(p1)\(p2)/\(c1)\(c2)"
                let revKey = "\(c2)\(c1)/\(p2)\(p1)"
                if let imm = internalMismatchParams[key] ?? internalMismatchParams[revKey] {
                    totalDH += imm.dH
                    totalDS += imm.dS
                } else {
                    let (dh, ds) = lookupDinucleotide(p1, p2)
                    totalDH += dh + 3.5
                    totalDS += ds + 8.5
                }
            }
        }
        
        let cleanOverhang5 = normalizeOligo(fivePrimeOverhang)
        if let dangle5 = cleanOverhang5.last, let firstBase = pChars.first {
            let (dh, ds) = lookupFivePrimeDangle(dangleBase: dangle5, firstPairedBase: firstBase)
            totalDH += dh
            totalDS += ds
        }
        
        let naMolar = max(0.001, naConcentration / 1000.0)
        let primerMolar = max(1e-9, primerConcNanoMolar * 1e-9)
        totalDS += 0.368 * Double(n - 1) * log(naMolar)
        
        let r = 1.9872
        let tm = (1000.0 * totalDH) / (totalDS + r * log(primerMolar)) - 273.15
        let gc = computeGCPercent(pClean)
        let roundedTm = (tm * 10).rounded() / 10.0
        
        return Result(
            length: n,
            gcPercent: (gc * 10).rounded() / 10.0,
            tm: roundedTm,
            snapGeneIntegerTm: Int(tm.rounded()),
            recommendedTa: roundedTm
        )
    }
    
    /// SantaLucia & Hicks (2004) + Bommarito et al. (2000) 核心近邻热力学实现
    public static func calculateNearestNeighbor(
        _ seq: String,
        fivePrimeOverhang: String = "",
        threePrimeOverhang: String = "",
        naMolar: Double = 0.05,
        primerConc: Double = 250e-9
    ) -> Double {
        let clean = normalizeOligo(seq)
        let chars = Array(clean)
        let n = chars.count
        guard n >= 2 else { return 0.0 }
        
        // 1. 双链起始自由能 (SantaLucia & Hicks 2004 Initiation: +0.2 kcal/mol, -5.7 cal/(K·mol))
        var totalDH = 0.2
        var totalDS = -5.7
        
        // 2. 末端 A·T 罚分 (Terminal A·T penalty: +2.2 kcal/mol, +6.9 cal/(K·mol) per terminal A·T)
        if let first = chars.first {
            let (atDH, atDS) = terminalATContribution(for: first)
            totalDH += atDH
            totalDS += atDS
        }
        if let last = chars.last {
            let (atDH, atDS) = terminalATContribution(for: last)
            totalDH += atDH
            totalDS += atDS
        }
        
        // 3. 自互补序列对称熵校正 (SantaLucia & Hicks 2004 Symmetry correction: -1.4 cal/(K·mol))
        let isSelfComp = fivePrimeOverhang.isEmpty
            && threePrimeOverhang.isEmpty
            && isSelfComplementary(chars)
        if isSelfComp {
            totalDS += -1.4
        }
        
        // 4. 相邻碱基对堆叠能 (Nearest-Neighbor Base-Pair Stacking, 支持 I 与 IUPAC 简并碱基均值)
        for i in 0..<(n - 1) {
            let (dh, ds) = lookupDinucleotide(chars[i], chars[i + 1])
            totalDH += dh
            totalDS += ds
        }
        
        // 5. 5' 悬垂端稳定化增量 (Bommarito, Peyret & SantaLucia 2000 Table 2)
        if let dangle5 = fivePrimeOverhang.last, let firstPaired = chars.first {
            let (dh, ds) = lookupFivePrimeDangle(dangleBase: dangle5, firstPairedBase: firstPaired)
            totalDH += dh
            totalDS += ds
        }
        
        // 6. 3' 悬垂端稳定化增量 (Bommarito, Peyret & SantaLucia 2000 Table 2)
        if let dangle3 = threePrimeOverhang.first, let lastPaired = chars.last {
            let (dh, ds) = lookupThreePrimeDangle(lastPairedBase: lastPaired, dangleBase: dangle3)
            totalDH += dh
            totalDS += ds
        }
        
        // 7. 单价阳离子熵校正 (SantaLucia & Hicks 2004 Eq. 5: dS([Na+]) = dS(1M) + 0.368 * (N - 1) * ln([Na+]))
        let saltCorrection = 0.368 * Double(n - 1) * log(naMolar)
        totalDS += saltCorrection
        
        // 8. 二态解链温度方程 (SantaLucia & Hicks 2004 Eq. 3 & SnapGene Official Assumption:
        //    PCR primer C_A = 0.25 μM, template C_B << C_A => C_A - C_B/2 = 0.25 μM;
        //    or two annealed oligos at 0.5 μM each => C_A - C_B/2 = 0.5 - 0.25 = 0.25 μM)
        let r = 1.9872
        let tmKelvin = (1000.0 * totalDH) / (totalDS + r * log(primerConc))
        return tmKelvin - 273.15
    }
    
    // MARK: - 内部辅助查询（支持简并碱基算术平均）
    
    private static func lookupDinucleotide(_ b1: Character, _ b2: Character) -> (dH: Double, dS: Double) {
        let exp1 = iupacExpansion[b1] ?? ["A"]
        let exp2 = iupacExpansion[b2] ?? ["A"]
        var sumDH = 0.0
        var sumDS = 0.0
        var count = 0.0
        for c1 in exp1 {
            for c2 in exp2 {
                let key = "\(c1)\(c2)"
                if let p = nnParams2004[key] {
                    sumDH += p.dH
                    sumDS += p.dS
                } else {
                    sumDH += -8.0
                    sumDS += -22.0
                }
                count += 1.0
            }
        }
        guard count > 0 else { return (-8.0, -22.0) }
        return (sumDH / count, sumDS / count)
    }
    
    private static func lookupFivePrimeDangle(dangleBase: Character, firstPairedBase: Character) -> (dH: Double, dS: Double) {
        let expD = iupacExpansion[dangleBase] ?? ["A"]
        let expP = iupacExpansion[firstPairedBase] ?? ["A"]
        var sumDH = 0.0
        var sumDS = 0.0
        var count = 0.0
        for d in expD {
            for p in expP {
                if let val = fivePrimeDangleParams["\(d)\(p)"] {
                    sumDH += val.dH
                    sumDS += val.dS
                    count += 1.0
                }
            }
        }
        guard count > 0 else { return (0.0, 0.0) }
        return (sumDH / count, sumDS / count)
    }
    
    private static func lookupThreePrimeDangle(lastPairedBase: Character, dangleBase: Character) -> (dH: Double, dS: Double) {
        let expP = iupacExpansion[lastPairedBase] ?? ["A"]
        let expD = iupacExpansion[dangleBase] ?? ["A"]
        var sumDH = 0.0
        var sumDS = 0.0
        var count = 0.0
        for p in expP {
            for d in expD {
                if let val = threePrimeDangleParams["\(p)\(d)"] {
                    sumDH += val.dH
                    sumDS += val.dS
                    count += 1.0
                }
            }
        }
        guard count > 0 else { return (0.0, 0.0) }
        return (sumDH / count, sumDS / count)
    }
    
    private static func terminalATContribution(for base: Character) -> (dH: Double, dS: Double) {
        let expanded = iupacExpansion[base] ?? ["A"]
        var sumDH = 0.0
        var sumDS = 0.0
        for b in expanded {
            if b == "A" || b == "T" || b == "I" {
                sumDH += 2.2
                sumDS += 6.9
            }
        }
        let n = Double(max(1, expanded.count))
        return (sumDH / n, sumDS / n)
    }
    
    private static func isATBase(_ b: Character) -> Bool {
        b == "A" || b == "T"
    }
    
    private static func complementBase(_ b: Character) -> Character {
        switch b {
        case "A": return "T"
        case "T": return "A"
        case "C": return "G"
        case "G": return "C"
        default:  return b
        }
    }
    
    private static func isSelfComplementary(_ chars: [Character]) -> Bool {
        guard chars.count % 2 == 0 else { return false }
        for i in 0..<(chars.count / 2) {
            let left = chars[i]
            let right = chars[chars.count - 1 - i]
            guard ["A", "T", "C", "G"].contains(left),
                  complementBase(left) == right else {
                return false
            }
        }
        return true
    }
    
    private static func computeGCPercent(_ seq: String) -> Double {
        guard !seq.isEmpty else { return 0.0 }
        var gcWeight = 0.0
        for ch in seq {
            let expanded = iupacExpansion[ch] ?? []
            guard !expanded.isEmpty else { continue }
            let gcInExpanded = expanded.filter { $0 == "G" || $0 == "C" }.count
            gcWeight += Double(gcInExpanded) / Double(expanded.count)
        }
        return (gcWeight / Double(seq.count)) * 100.0
    }
}
