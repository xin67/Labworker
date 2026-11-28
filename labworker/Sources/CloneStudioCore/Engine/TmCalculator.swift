import Foundation

/// 引物退火温度与熔解温度 (Tm) 计算引擎
/// 完整实现：
/// 1. SantaLucia & Hicks (2004) Annu Rev Biophys Biomol Struct 33:415-40 (Nearest-Neighbor 核心参数、起始自由能、末端 A·T 罚分、自互补对称校正、单价阳离子熵校正)
/// 2. Owczarzy et al. (2004) Biochemistry 43:3537-3554 & Owczarzy et al. (2008) Biochemistry 47:5336-5353 (完整 dNTP 螯合游离 Mg2+ 二次平衡 + R = sqrt([Mg2+]_free)/[Mon+] 三区段单价/混合/二价盐校正)
/// 3. Bommarito, Peyret & SantaLucia (2000) Nucleic Acids Res 28:1929-34 (5' 与 3' 悬垂端自由能增量，共 32 项)
/// 4. Allawi & SantaLucia (1997-1998) / Peyret et al. (1999) (内部错配与末端错配参数)
/// 5. Watkins & SantaLucia (2005) Nucleic Acids Res 33:6258-67 (次黄嘌呤 Deoxyinosine 'I' 配对参数，U 等同于 T，简并碱基取均值)
/// 6. 聚合酶专属退火温度 Ta 推荐 (NEB Q5 / Phusion / Taq / SnapGene)
public struct TmCalculator {

    /// 盐校正模型
    public enum SaltCorrectionMode: String, Sendable, Equatable, Codable, CaseIterable {
        /// SantaLucia & Hicks (2004) 单价阳离子熵校正（SnapGene 兼容默认）
        case santaLucia2004 = "santaLucia2004"
        /// Owczarzy et al. (2004) Eq. 22 GC 含量依赖单价阳离子校正
        case owczarzy2004 = "owczarzy2004"
        /// Owczarzy et al. (2008) 完整单价 + 游离 Mg2+ (dNTP 螯合) 三区段盐校正
        case owczarzy2008 = "owczarzy2008"
    }

    /// 双链有效寡核苷酸浓度近似模式
    public enum ConcentrationMode: String, Sendable, Equatable, Codable, CaseIterable {
        /// 非对称模板过量/引物过量近似: C_eff = C_primer - C_template / 2 ≈ C_primer（SnapGene 默认）
        case asymmetricExcess = "asymmetricExcess"
        /// 等摩尔双链退火近似: 非自互补 C_eff = C_T / 4，自互补 C_eff = C_T（Primer3 / SantaLucia 2004 标准）
        case equimolar = "equimolar"
    }

    /// 常见 PCR 聚合酶推荐退火温度 (Ta) 规则
    public enum PolymerasePreset: String, Sendable, Equatable, Codable, CaseIterable {
        case snapGene = "SnapGene"
        case nebQ5 = "NEB Q5"
        case phusion = "Phusion"
        case taq = "Taq"
    }

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
        // Watkins & SantaLucia (2005) Table 2 Deoxyinosine (I·C) 精确默认近邻参数（I·A/I·T/I·G/I·I 全 36 项上下文见 internalMismatchParams）
        "AI": (-8.9, -25.5), "IA": (-4.9, -13.9),
        "CI": (-5.4, -13.7), "IC": (-5.0, -12.6),
        "GI": (-6.8, -19.1), "IG": (-8.3, -23.8),
        "TI": (-5.9, -17.4), "IT": (-8.8, -25.4),
        "II": (-3.3, -11.9)
    ]

    // MARK: - 2. Bommarito, Peyret & SantaLucia (2000) Table 2 — 5' 悬垂端参数 (key = "XY": 5'-X(dangle) Y(paired)-3')
    public static let fivePrimeDangleParams: [String: (dH: Double, dS: Double)] = [
        "AA": (0.2, 2.3),    "AC": (-6.3, -17.1), "AG": (-3.7, -10.0), "AT": (-2.9, -7.6),
        "CA": (0.6, 3.3),    "CC": (-4.4, -12.6), "CG": (-4.0, -11.9), "CT": (-4.1, -13.0),
        "GA": (-1.1, -1.6),  "GC": (-5.1, -14.0), "GG": (-3.9, -10.9), "GT": (-4.2, -15.0),
        "TA": (-6.9, -20.0), "TC": (-4.0, -10.9), "TG": (-4.9, -13.8), "TT": (-0.2, -0.5)
    ]

    // MARK: - 3. Bommarito, Peyret & SantaLucia (2000) Table 2 — 3' 悬垂端参数 (key = "YX": 5'-Y(paired) X(dangle)-3')
    public static let threePrimeDangleParams: [String: (dH: Double, dS: Double)] = [
        "AA": (-0.5, -1.1),  "AC": (4.7, 14.2),   "AG": (-4.1, -13.1), "AT": (-3.8, -12.6),
        "CA": (-5.9, -16.5), "CC": (-2.6, -7.4),  "CG": (-3.2, -10.4), "CT": (-5.2, -15.0),
        "GA": (-2.1, -3.9),  "GC": (-0.2, -0.1),  "GG": (-3.9, -11.2), "GT": (-4.4, -13.1),
        "TA": (-0.7, -0.8),  "TC": (4.4, 14.9),   "TG": (-1.6, -3.6),  "TT": (2.9, 10.4)
    ]

    // MARK: - 4. Allawi & SantaLucia (1997-1998) / Peyret et al. (1999) / Watkins & SantaLucia (2005) 内部错配与肌苷参数 (key = "XY/ZW", 5'-XY-3' / 3'-ZW-5')
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
        "CT/GT": (-5.0, -15.8),"GT/CT": (-2.2, -8.4), "TT/AT": (0.2, -1.5),
        // Watkins & SantaLucia (2005) NAR 33:6258-6267 Table 2 (全部 36 项 I·C / I·A / I·T / I·G / I·I 上下文参数)
        "AI/TC": (-8.9, -25.5), "TI/AC": (-5.9, -17.4), "AC/TI": (-8.8, -25.4), "TC/AI": (-4.9, -13.9),
        "CI/GC": (-5.4, -13.7), "GI/CC": (-6.8, -19.1), "CC/GI": (-8.3, -23.8), "GC/CI": (-5.0, -12.6),
        "AI/TA": (-8.3, -25.0), "TI/AA": (-3.4, -11.2), "AA/TI": (-0.7, -2.6),  "TA/AI": (-1.3, -4.6),
        "CI/GA": (2.6, 8.9),    "GI/CA": (-7.8, -21.1), "CA/GI": (-7.0, -20.0), "GA/CI": (-7.6, -20.2),
        "AI/TT": (0.49, -0.7),  "TI/AT": (-6.5, -22.0), "AT/TI": (-5.6, -18.7), "TT/AI": (-0.8, -4.3),
        "CI/GT": (-1.0, -2.4),  "GI/CT": (-3.5, -10.6), "CT/GI": (0.1, -1.0),   "GT/CI": (-4.3, -12.1),
        "AI/TG": (-4.9, -15.8), "TI/AG": (-1.9, -8.5),  "AG/TI": (0.1, -1.8),   "TG/AI": (1.0, 1.0),
        "CI/GG": (7.1, 21.3),   "GI/CG": (-1.1, -3.2),  "CG/GI": (5.8, 16.9),   "GG/CI": (-7.6, -22.0),
        "AI/TI": (-3.3, -11.9), "TI/AI": (0.1, -2.3),   "CI/GI": (1.3, 3.0),    "GI/CI": (-0.5, -1.3)
    ]

    // MARK: - 5. SantaLucia & Peyret (2001) DNA_TMM1 末端错配 / 发夹与内环闭口参数 (key = "XY/ZW", X/Z 为闭口 WC 对, Y/W 为末端错配)
    public static let terminalMismatchParams: [String: (dH: Double, dS: Double)] = [
        "AA/TA": (-3.1, -7.8),  "TA/AA": (-2.5, -6.3),  "CA/GA": (-4.3, -10.7), "GA/CA": (-8.0, -22.5),
        "AC/TC": (-0.1, 0.5),   "TC/AC": (-0.7, -1.3),  "CC/GC": (-2.1, -5.1),  "GC/CC": (-3.9, -10.6),
        "AG/TG": (-1.1, -2.1),  "TG/AG": (-1.1, -2.7),  "CG/GG": (-3.8, -9.5),  "GG/CG": (-6.7, -19.2),
        "AT/TT": (-2.4, -6.5),  "TT/AT": (-3.2, -8.9),  "CT/GT": (-6.1, -16.9), "GT/CT": (-7.4, -21.2),
        "AA/TC": (-1.6, -4.0),  "AC/TA": (-1.8, -3.8),  "CA/GC": (-2.6, -5.9),  "CC/GA": (-2.7, -6.0),
        "GA/CC": (-5.0, -13.8), "GC/CA": (-3.2, -7.1),  "TA/AC": (-2.3, -5.9),  "TC/AA": (-2.7, -7.0),
        "AC/TT": (-0.9, -1.7),  "AT/TC": (-2.3, -6.3),  "CC/GT": (-3.2, -8.0),  "CT/GC": (-3.9, -10.6),
        "GC/CT": (-4.9, -13.5), "GT/CC": (-3.0, -7.8),  "TC/AT": (-2.5, -6.3),  "TT/AC": (-0.7, -1.2),
        "AA/TG": (-1.9, -4.4),  "AG/TA": (-2.5, -5.9),  "CA/GG": (-3.9, -9.6),  "CG/GA": (-6.0, -15.5),
        "GA/CG": (-4.3, -11.1), "GG/CA": (-4.6, -11.4), "TA/AG": (-2.0, -4.7),  "TG/AA": (-2.4, -5.8),
        "AG/TT": (-3.2, -8.7),  "AT/TG": (-3.5, -9.4),  "CG/GT": (-3.8, -9.0),  "CT/GG": (-6.6, -18.7),
        "GG/CT": (-5.7, -15.9), "GT/CG": (-5.9, -16.1), "TG/AT": (-3.9, -10.5), "TT/AG": (-3.6, -9.8)
    ]

    /// 双向反平行查找内部错配 / 肌苷参数（自动检查 5'-p1p2-3'/3'-q1q2-5' 与 180° 旋转等价键 5'-q2q1-3'/3'-p2p1-5'）
    public static func lookupInternalMismatch(_ p1: Character, _ p2: Character, _ q1: Character, _ q2: Character) -> (dH: Double, dS: Double)? {
        let k1 = "\(p1)\(p2)/\(q1)\(q2)"
        if let v = internalMismatchParams[k1] { return v }
        let k2 = "\(q2)\(q1)/\(p2)\(p1)"
        return internalMismatchParams[k2]
    }

    /// 双向反平行查找末端错配 / 环闭口参数（SantaLucia & Peyret 2001 DNA_TMM1）
    public static func lookupTerminalMismatch(_ p1: Character, _ p2: Character, _ q1: Character, _ q2: Character) -> (dH: Double, dS: Double)? {
        let k1 = "\(p1)\(p2)/\(q1)\(q2)"
        if let v = terminalMismatchParams[k1] { return v }
        let k2 = "\(q2)\(q1)/\(p2)\(p1)"
        return terminalMismatchParams[k2]
    }

    /// IUPAC 简并碱基展开表（U 视为 T）
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

    /// 计算 dNTP 螯合后的游离 Mg2+ 浓度（单位：M，Owczarzy et al. 2008 / Ka = 3e4 M^-1 精确二次平衡解）
    public static func freeMgMolar(mgMolar: Double, dntpMolar: Double, ka: Double = 3.0e4) -> Double {
        let mg = max(0.0, mgMolar)
        let dntp = max(0.0, dntpMolar)
        if mg <= 0.0 { return 0.0 }
        if dntp <= 0.0 { return mg }
        let b = ka * (dntp - mg) + 1.0
        let disc = max(0.0, b * b + 4.0 * ka * mg)
        return max(0.0, (-b + sqrt(disc)) / (2.0 * ka))
    }

    /// 根据目标 PCR 聚合酶规则计算推荐退火温度 Ta (℃)
    public static func recommendedAnnealingTemp(
        tmForward: Double,
        tmReverse: Double,
        polymerase: PolymerasePreset = .snapGene
    ) -> Double {
        let lowerTm = min(tmForward, tmReverse)
        let ta: Double
        switch polymerase {
        case .snapGene:
            ta = lowerTm
        case .nebQ5:
            // NEB Q5 High-Fidelity 官方规则：min(Tm) + 1 ℃，封顶 72 ℃
            ta = min(72.0, lowerTm + 1.0)
        case .phusion:
            // Thermo/NEB Phusion 官方规则：min(Tm) + 3 ℃，封顶 72 ℃
            ta = min(72.0, lowerTm + 3.0)
        case .taq:
            // 经典 Taq 聚合酶规则：min(Tm) - 5 ℃
            ta = max(45.0, lowerTm - 5.0)
        }
        return (ta * 10.0).rounded() / 10.0
    }

    /// Owczarzy et al. (2004 / 2008) 完整单价/混合/二价阳离子盐校正（将 1 M Na+ 下的 Tm1M_K 换算为目标盐条件 Tm_K）
    public static func applyOwczarzySaltCorrection(
        tm1MKelvin: Double,
        length: Int,
        gcFraction: Double,
        monovalentMolar: Double,
        freeMgMolar: Double,
        mode: SaltCorrectionMode = .owczarzy2008
    ) -> Double {
        guard tm1MKelvin > 0, length >= 2 else { return tm1MKelvin }
        let m = max(1e-6, monovalentMolar)
        let d = max(0.0, freeMgMolar)
        let fGC = max(0.0, min(1.0, gcFraction))
        let lnM = log(m)

        // Owczarzy et al. (2004) Eq. 22: 纯单价阳离子校正
        func invTmMonovalent() -> Double {
            (1.0 / tm1MKelvin) + (4.29 * fGC - 3.95) * 1e-5 * lnM + 9.40e-6 * lnM * lnM
        }

        if mode == .owczarzy2004 || d <= 0.0 {
            return 1.0 / invTmMonovalent()
        }

        let rRatio = sqrt(d) / m
        if rRatio < 0.22 {
            return 1.0 / invTmMonovalent()
        }

        // Owczarzy et al. (2008) Table 2 常数
        var a = 3.92e-5
        let b = -9.11e-6
        let c = 6.26e-5
        var dCoef = 1.42e-5
        let e = -4.82e-4
        let f = 5.25e-4
        var g = 8.31e-5

        if rRatio < 6.0 {
            // 混合单价 + 二价区段 (Owczarzy 2008 Eqs. 18-20)
            a *= (0.843 - 0.352 * sqrt(m) * lnM)
            dCoef *= (1.279 - 4.03e-3 * lnM - 8.03e-3 * lnM * lnM)
            g *= (0.486 - 0.258 * lnM + 5.25e-3 * lnM * lnM * lnM)
        }

        let lnD = log(d)
        let invTm = (1.0 / tm1MKelvin)
            + a
            + b * lnD
            + fGC * (c + dCoef * lnD)
            + (1.0 / (2.0 * Double(length - 1))) * (e + f * lnD + g * lnD * lnD)
        return invTm > 0 ? (1.0 / invTm) : tm1MKelvin
    }

    /// 计算引物 Tm 值（默认兼容 SnapGene SantaLucia 2004；支持显式启用 Owczarzy 2008 Mg2+/dNTP 盐校正与聚合酶 Ta）
    public static func calculate(
        sequence: String,
        fivePrimeOverhang: String = "",
        threePrimeOverhang: String = "",
        naConcentration: Double = 50.0,
        primerConcNanoMolar: Double = 250.0,
        mgConcentration: Double = 0.0,
        dntpConcentration: Double = 0.0,
        saltCorrection: SaltCorrectionMode = .santaLucia2004,
        concentrationMode: ConcentrationMode = .asymmetricExcess,
        polymerase: PolymerasePreset = .snapGene
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
        let mgMolar = max(0.0, mgConcentration / 1000.0)
        let dntpMolar = max(0.0, dntpConcentration / 1000.0)
        let primerMolar = max(1e-9, primerConcNanoMolar * 1e-9)

        let effectiveMode: SaltCorrectionMode = (mgMolar > 0.0 && saltCorrection == .santaLucia2004)
            ? .owczarzy2008
            : saltCorrection

        let tm = calculateNearestNeighbor(
            cleanSeq,
            fivePrimeOverhang: normalizeOligo(fivePrimeOverhang),
            threePrimeOverhang: normalizeOligo(threePrimeOverhang),
            naMolar: naMolar,
            primerConc: primerMolar,
            mgMolar: mgMolar,
            dntpMolar: dntpMolar,
            saltCorrection: effectiveMode,
            concentrationMode: concentrationMode
        )

        let roundedTm = (tm * 10).rounded() / 10.0
        let intTm = Int(tm.rounded())
        let ta = recommendedAnnealingTemp(tmForward: roundedTm, tmReverse: roundedTm, polymerase: polymerase)

        return Result(
            length: n,
            gcPercent: (gc * 10).rounded() / 10.0,
            tm: roundedTm,
            snapGeneIntegerTm: intTm,
            recommendedTa: ta
        )
    }

    /// 便捷入口：Owczarzy et al. (2008) 完整 PCR 体系 Tm 计算（50 mM Mon+, 1.5 mM Mg2+, 0.2–0.8 mM dNTP）
    public static func calculateOwczarzy2008(
        sequence: String,
        fivePrimeOverhang: String = "",
        threePrimeOverhang: String = "",
        monovalentMm: Double = 50.0,
        mgMm: Double = 1.5,
        dntpMm: Double = 0.6,
        primerConcNanoMolar: Double = 250.0,
        concentrationMode: ConcentrationMode = .asymmetricExcess,
        polymerase: PolymerasePreset = .nebQ5
    ) -> Result {
        calculate(
            sequence: sequence,
            fivePrimeOverhang: fivePrimeOverhang,
            threePrimeOverhang: threePrimeOverhang,
            naConcentration: monovalentMm,
            primerConcNanoMolar: primerConcNanoMolar,
            mgConcentration: mgMm,
            dntpConcentration: dntpMm,
            saltCorrection: .owczarzy2008,
            concentrationMode: concentrationMode,
            polymerase: polymerase
        )
    }

    /// 计算包含内部/末端错配（如定点突变引物结合野生型模板或含次黄嘌呤 I）的双链 Tm
    public static func calculateWithTemplate(
        primerSeq: String,
        templateSenseSeq: String,
        fivePrimeOverhang: String = "",
        naConcentration: Double = 50.0,
        primerConcNanoMolar: Double = 250.0,
        mgConcentration: Double = 0.0,
        dntpConcentration: Double = 0.0,
        saltCorrection: SaltCorrectionMode = .santaLucia2004
    ) -> Result {
        let pClean = normalizeOligo(primerSeq)
        let tClean = normalizeOligo(templateSenseSeq)
        guard pClean.count >= 2, pClean.count == tClean.count else {
            return calculate(
                sequence: primerSeq,
                fivePrimeOverhang: fivePrimeOverhang,
                naConcentration: naConcentration,
                primerConcNanoMolar: primerConcNanoMolar,
                mgConcentration: mgConcentration,
                dntpConcentration: dntpConcentration,
                saltCorrection: saltCorrection
            )
        }

        let pChars = Array(pClean)
        let tChars = Array(tClean)
        let n = pChars.count

        // 定位首尾已配对碱基范围（正确剥离 5' / 3' 末端错配，不对其误施 WC 末端 A·T 罚分）
        var leftPaired = 0
        while leftPaired < n && pChars[leftPaired] != tChars[leftPaired] && pChars[leftPaired] != "I" {
            leftPaired += 1
        }
        var rightPaired = n - 1
        while rightPaired >= leftPaired && pChars[rightPaired] != tChars[rightPaired] && pChars[rightPaired] != "I" {
            rightPaired -= 1
        }
        guard rightPaired - leftPaired >= 1 else {
            let gc = computeGCPercent(pClean)
            return Result(length: n, gcPercent: (gc * 10).rounded() / 10.0, tm: 0.0, snapGeneIntegerTm: 0, recommendedTa: 0.0)
        }

        var totalDH = 0.2
        var totalDS = -5.7

        // 仅对真实 WC 配对末端施用 A·T 罚分（不对次黄嘌呤 I 或错配末端施用）
        if isATBase(pChars[leftPaired]) && pChars[leftPaired] == tChars[leftPaired] {
            totalDH += 2.2
            totalDS += 6.9
        }
        if isATBase(pChars[rightPaired]) && pChars[rightPaired] == tChars[rightPaired] {
            totalDH += 2.2
            totalDS += 6.9
        }

        // 处理 5' 末端错配（SantaLucia & Peyret 2001 DNA_TMM1）或 5' 悬垂端
        if leftPaired > 0 {
            let pPrev = pChars[leftPaired - 1]
            let cPrev = complementBase(tChars[leftPaired - 1])
            let cCur = complementBase(tChars[leftPaired])
            if let tmm = lookupTerminalMismatch(pPrev, pChars[leftPaired], cPrev, cCur) {
                totalDH += tmm.dH
                totalDS += tmm.dS
            } else {
                let (dh, ds) = lookupFivePrimeDangle(dangleBase: pPrev, firstPairedBase: pChars[leftPaired])
                totalDH += dh
                totalDS += ds
            }
        } else {
            let cleanOverhang5 = normalizeOligo(fivePrimeOverhang)
            if let dangle5 = cleanOverhang5.last {
                let (dh, ds) = lookupFivePrimeDangle(dangleBase: dangle5, firstPairedBase: pChars[leftPaired])
                totalDH += dh
                totalDS += ds
            }
        }

        // 处理 3' 末端错配（SantaLucia & Peyret 2001 DNA_TMM1）
        if rightPaired < n - 1 {
            let pNext = pChars[rightPaired + 1]
            let cCur = complementBase(tChars[rightPaired])
            let cNext = complementBase(tChars[rightPaired + 1])
            if let tmm = lookupTerminalMismatch(pChars[rightPaired], pNext, cCur, cNext) {
                totalDH += tmm.dH
                totalDS += tmm.dS
            } else {
                let (dh, ds) = lookupThreePrimeDangle(lastPairedBase: pChars[rightPaired], dangleBase: pNext)
                totalDH += dh
                totalDS += ds
            }
        }

        // 内部近邻栈能（严格查 Watkins & SantaLucia 2005 Table 2 全部 36 项 I·X 上下文与双向错配表，不掩盖邻位错配）
        for i in leftPaired..<rightPaired {
            let p1 = pChars[i]
            let p2 = pChars[i + 1]
            let t1 = tChars[i]
            let t2 = tChars[i + 1]
            let match1 = (p1 == t1 && p1 != "I")
            let match2 = (p2 == t2 && p2 != "I")

            if match1 && match2 {
                let (dh, ds) = lookupDinucleotide(p1, p2)
                totalDH += dh
                totalDS += ds
            } else {
                let c1 = complementBase(t1)
                let c2 = complementBase(t2)
                if let imm = lookupInternalMismatch(p1, p2, c1, c2) {
                    totalDH += imm.dH
                    totalDS += imm.dS
                } else {
                    // 连续双错配、邻位错配与肌苷组合或未知上下文：施加去稳定内部环罚分
                    totalDH += 0.5
                    totalDS += -2.0
                }
            }
        }

        let pairedLen = rightPaired - leftPaired + 1
        // 含 1-bp 末端错配时补计该错配磷酸二酯步的阳离子熵校正（与 Biopython Tm_NN 一致），不把多碱基悬垂尾纳入盐长
        let effectiveSaltLen = pairedLen + (leftPaired > 0 ? 1 : 0) + (rightPaired < n - 1 ? 1 : 0)
        let naMolar = max(0.001, naConcentration / 1000.0)
        let mgMolar = max(0.0, mgConcentration / 1000.0)
        let dntpMolar = max(0.0, dntpConcentration / 1000.0)
        let primerMolar = max(1e-9, primerConcNanoMolar * 1e-9)
        let r = 1.9872

        let effectiveMode: SaltCorrectionMode = (mgMolar > 0.0 && saltCorrection == .santaLucia2004)
            ? .owczarzy2008
            : saltCorrection

        let tmC: Double
        if effectiveMode == .santaLucia2004 {
            let dsSalt = totalDS + 0.368 * Double(effectiveSaltLen - 1) * log(naMolar)
            tmC = (1000.0 * totalDH) / (dsSalt + r * log(primerMolar)) - 273.15
        } else {
            let tm1MK = (1000.0 * totalDH) / (totalDS + r * log(primerMolar))
            let fGC = computeGCPercent(String(pChars[leftPaired...rightPaired])) / 100.0
            let freeMg = freeMgMolar(mgMolar: mgMolar, dntpMolar: dntpMolar)
            let tmK = applyOwczarzySaltCorrection(
                tm1MKelvin: tm1MK,
                length: effectiveSaltLen,
                gcFraction: fGC,
                monovalentMolar: naMolar,
                freeMgMolar: freeMg,
                mode: effectiveMode
            )
            tmC = tmK - 273.15
        }

        let gc = computeGCPercent(pClean)
        let roundedTm = (tmC * 10).rounded() / 10.0
        return Result(
            length: n,
            gcPercent: (gc * 10).rounded() / 10.0,
            tm: roundedTm,
            snapGeneIntegerTm: Int(tmC.rounded()),
            recommendedTa: roundedTm
        )
    }

    /// SantaLucia & Hicks (2004) + Bommarito et al. (2000) + Owczarzy (2004/2008) 核心近邻热力学实现
    public static func calculateNearestNeighbor(
        _ seq: String,
        fivePrimeOverhang: String = "",
        threePrimeOverhang: String = "",
        naMolar: Double = 0.05,
        primerConc: Double = 250e-9,
        mgMolar: Double = 0.0,
        dntpMolar: Double = 0.0,
        saltCorrection: SaltCorrectionMode = .santaLucia2004,
        concentrationMode: ConcentrationMode = .asymmetricExcess
    ) -> Double {
        let clean = normalizeOligo(seq)
        let chars = Array(clean)
        let n = chars.count
        guard n >= 2 else { return 0.0 }

        var totalDH = 0.2
        var totalDS = -5.7

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

        let isSelfComp = fivePrimeOverhang.isEmpty
            && threePrimeOverhang.isEmpty
            && isSelfComplementary(chars)
        if isSelfComp {
            totalDS += -1.4
        }

        for i in 0..<(n - 1) {
            let (dh, ds) = lookupDinucleotide(chars[i], chars[i + 1])
            totalDH += dh
            totalDS += ds
        }

        if let dangle5 = fivePrimeOverhang.last, let firstPaired = chars.first {
            let (dh, ds) = lookupFivePrimeDangle(dangleBase: dangle5, firstPairedBase: firstPaired)
            totalDH += dh
            totalDS += ds
        }

        if let dangle3 = threePrimeOverhang.first, let lastPaired = chars.last {
            let (dh, ds) = lookupThreePrimeDangle(lastPairedBase: lastPaired, dangleBase: dangle3)
            totalDH += dh
            totalDS += ds
        }

        let r = 1.9872
        let cEff: Double
        switch concentrationMode {
        case .asymmetricExcess:
            cEff = primerConc
        case .equimolar:
            cEff = isSelfComp ? primerConc : (primerConc / 4.0)
        }

        if saltCorrection == .santaLucia2004 && mgMolar <= 0.0 {
            let saltAdj = 0.368 * Double(n - 1) * log(naMolar)
            let tmKelvin = (1000.0 * totalDH) / ((totalDS + saltAdj) + r * log(cEff))
            return tmKelvin - 273.15
        } else {
            let tm1MK = (1000.0 * totalDH) / (totalDS + r * log(cEff))
            let fGC = computeGCPercent(clean) / 100.0
            let freeMg = freeMgMolar(mgMolar: mgMolar, dntpMolar: dntpMolar)
            let mode: SaltCorrectionMode = (saltCorrection == .santaLucia2004) ? .owczarzy2008 : saltCorrection
            let tmKelvin = applyOwczarzySaltCorrection(
                tm1MKelvin: tm1MK,
                length: n,
                gcFraction: fGC,
                monovalentMolar: naMolar,
                freeMgMolar: freeMg,
                mode: mode
            )
            return tmKelvin - 273.15
        }
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

    /// 末端 A·T 罚分（修复：肌苷 'I' 与 C 配对，不再误施 A·T 末端罚分）
    private static func terminalATContribution(for base: Character) -> (dH: Double, dS: Double) {
        let expanded = iupacExpansion[base] ?? ["A"]
        var sumDH = 0.0
        var sumDS = 0.0
        for b in expanded {
            if b == "A" || b == "T" {
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
