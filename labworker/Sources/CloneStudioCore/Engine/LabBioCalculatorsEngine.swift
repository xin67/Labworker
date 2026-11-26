import Foundation

// MARK: - 生物科研换算高精度格式化器

/// 提供与生物科研在线计算器对齐的自适应小数舍入与千分位格式化工具
public enum BioMathFormatter {
    /// 自适应有效精度舍入（>=0.1 保留2位，>=0.01 保留3位，>=0.001 保留4位，>=1e-4 保留5位；极小正数保留3位有效数字）
    public static func roundAdaptive(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        if value == 0 { return 0 }
        let absVal = abs(value)
        let factor: Double
        if absVal >= 0.1 {
            factor = 100.0
        } else if absVal >= 0.01 {
            factor = 1_000.0
        } else if absVal >= 0.001 {
            factor = 10_000.0
        } else if absVal >= 1e-4 {
            factor = 100_000.0
        } else {
            let exp = Int(floor(log10(absVal)))
            let p = pow(10.0, Double(2 - exp))
            return (value * p).rounded() / p
        }
        return (value * factor).rounded() / factor
    }

    /// 格式化数值为带千分位与合理小数位的字符串（无多余尾随 0）
    public static func format(_ value: Double, fixedDecimals: Int? = nil) -> String {
        guard value.isFinite else { return "--" }
        let val = fixedDecimals != nil ? value : roundAdaptive(value)
        if val == 0 { return "0" }
        let absVal = abs(val)
        if absVal > 0 && absVal < 1e-6 && fixedDecimals == nil {
            return String(format: "%.3e", val)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        if let fixed = fixedDecimals {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = max(0, fixed)
        } else if absVal >= 0.1 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
        } else if absVal >= 0.01 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 3
        } else if absVal >= 0.001 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 4
        } else if absVal >= 1e-4 {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 5
        } else {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 6
        }
        return formatter.string(from: NSNumber(value: val)) ?? "\(val)"
    }
}

// MARK: - 1. DNA 换算引擎 (dsDNA / ssDNA / Linear DNA / Nucleic Acid OD260)

public enum LabDNAConverter {

    public enum DSDNADirection: String, CaseIterable, Identifiable, Sendable {
        case ugToPmol = "ugToPmol"
        case pmolToUg = "pmolToUg"

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .ugToPmol: return "µg → pmol"
            case .pmolToUg: return "pmol → µg"
            }
        }
    }

    public enum SSDNADirection: String, CaseIterable, Identifiable, Sendable {
        case ugPerMlToPmolPerUl = "ugPerMlToPmolPerUl"
        case pmolPerUlToUgPerMl = "pmolPerUlToUgPerMl"

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .ugPerMlToPmolPerUl: return "µg/mL → pmol/µL"
            case .pmolPerUlToUgPerMl: return "pmol/µL → µg/mL"
            }
        }
    }

    public enum NucleicAcidSampleType: String, CaseIterable, Identifiable, Sendable {
        case dsDNA = "DNA"
        case rna = "RNA"
        case ssDNA = "Single-stranded DNA"
        case ssOligo = "Single-stranded Oligo"

        public var id: String { rawValue }

        /// 分光光度计 OD260 = 1.0 对应的标准质量浓度换算系数 (µg/mL)
        public var factor: Double {
            switch self {
            case .dsDNA:   return 50.0
            case .rna:     return 40.0
            case .ssDNA:   return 35.0
            case .ssOligo: return 20.0
            }
        }

        public var displayTitle: String {
            switch self {
            case .dsDNA:   return "DNA (双链 DNA · ×50)"
            case .rna:     return "RNA (单链 RNA · ×40)"
            case .ssDNA:   return "Single-stranded DNA (×35)"
            case .ssOligo: return "Single-stranded Oligo (×20)"
            }
        }
    }

    public struct OD260Result: Equatable, Sendable {
        public let od260: Double
        public let sampleType: NucleicAcidSampleType
        public let dilutionFactor: Double
        public let concentrationUgPerMl: Double
        public let concentrationNgPerUl: Double
        public let isOutOfLinearRange: Bool
        public let rangeWarning: String?
    }

    /// dsDNA: 质量 (µg) → 摩尔数 (pmol)
    /// 公式: pmol = (µg / bp) × 1515.1  (基于平均碱基对分子量 660 pg/pmol)
    public static func dsdnaUgToPmol(lengthBp: Double, massUg: Double) -> Double? {
        guard lengthBp > 0, massUg >= 0 else { return nil }
        return (massUg / lengthBp) * 1515.1
    }

    /// dsDNA: 摩尔数 (pmol) → 质量 (µg)
    /// 公式: µg = pmol × bp × 660 × 10^-6
    public static func dsdnaPmolToUg(lengthBp: Double, pmol: Double) -> Double? {
        guard lengthBp > 0, pmol >= 0 else { return nil }
        return pmol * lengthBp * 0.00066
    }

    /// ssDNA: 质量浓度 (µg/mL) → 摩尔浓度 (pmol/µL)
    /// 公式: pmol/µL = (µg/mL × 3.03) / nt
    public static func ssdnaUgPerMlToPmolPerUl(lengthNt: Double, concUgPerMl: Double) -> Double? {
        guard lengthNt > 0, concUgPerMl >= 0 else { return nil }
        return (concUgPerMl * 3.03) / lengthNt
    }

    /// ssDNA: 摩尔浓度 (pmol/µL) → 质量浓度 (µg/mL)
    /// 公式: µg/mL = (pmol/µL) × 0.33 × nt
    public static func ssdnaPmolPerUlToUgPerMl(lengthNt: Double, concPmolPerUl: Double) -> Double? {
        guard lengthNt > 0, concPmolPerUl >= 0 else { return nil }
        return concPmolPerUl * 0.33 * lengthNt
    }

    /// Linear DNA: 质量 (µg) → 线性双链 DNA 末端摩尔数 (pmol Ends)
    /// 公式: pmol Ends = (µg × 3.03) / kb (每条线性 dsDNA 含有 2 个末端)
    public static func linearDNAUgToPmolEnds(lengthKb: Double, massUg: Double) -> Double? {
        guard lengthKb > 0, massUg >= 0 else { return nil }
        return (massUg * 3.03) / lengthKb
    }

    /// Nucleic Acid: OD260 → 浓度 (µg/mL 与 ng/µL 等值)
    public static func od260ToConcentration(
        od260: Double,
        sampleType: NucleicAcidSampleType,
        dilutionFactor: Double = 1.0
    ) -> OD260Result? {
        guard od260 >= 0, dilutionFactor > 0 else { return nil }
        let concUgMl = od260 * sampleType.factor * dilutionFactor
        let outOfRange = od260 > 0 && (od260 < 0.1 || od260 > 1.0)
        let warn: String? = outOfRange
            ? L10n.t("大多数分光光度计在低于 0.1 OD 单位或高于 1.0 OD 单位时精度下降，建议调整稀释倍数重新测读。")
            : nil
        return OD260Result(
            od260: od260,
            sampleType: sampleType,
            dilutionFactor: dilutionFactor,
            concentrationUgPerMl: concUgMl,
            concentrationNgPerUl: concUgMl,
            isOutOfLinearRange: outOfRange,
            rangeWarning: warn
        )
    }
}

// MARK: - 2. 蛋白质换算引擎 (摩尔互算 / DNA 编码容量)

public enum LabProteinConverter {

    public enum ProteinMolarTarget: String, CaseIterable, Identifiable, Sendable {
        case sizeKDa = "0"
        case massUg = "1"
        case amountPmol = "2"

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .sizeKDa:    return "Protein Size (kDa)"
            case .massUg:     return "µg of Protein"
            case .amountPmol: return "pmol of Protein"
            }
        }
        public var unitSuffix: String {
            switch self {
            case .sizeKDa:    return "kDa"
            case .massUg:     return "µg of protein"
            case .amountPmol: return "pmol of protein"
            }
        }
    }

    public struct ProteinMolarResult: Equatable, Sendable {
        public let target: ProteinMolarTarget
        public let value: Double
        public let formattedValueWithUnit: String
    }

    public enum CodingCapacitySource: Equatable, Sendable {
        case dnaBp(Double)
        case proteinAA(Double)
        case proteinKDa(Double)
    }

    public struct CodingCapacityResult: Equatable, Sendable {
        public let dnaBp: Double
        public let aminoAcids: Double
        public let proteinKDa: Double
    }

    /// 蛋白质大小 (kDa)、质量 (µg) 与摩尔数 (pmol) 三角互算
    /// 核心关系: 1000 × µg = pmol × kDa
    public static func proteinMolar(
        target: ProteinMolarTarget,
        inputA: Double,
        inputB: Double
    ) -> ProteinMolarResult? {
        guard inputA >= 0, inputB >= 0 else { return nil }
        let val: Double
        switch target {
        case .sizeKDa:
            // inputA = µg, inputB = pmol
            guard inputB > 0 else { return nil }
            val = (1000.0 * inputA) / inputB
        case .massUg:
            // inputA = kDa, inputB = pmol
            val = inputA * inputB * 0.001
        case .amountPmol:
            // inputA = kDa, inputB = µg
            guard inputA > 0 else { return nil }
            val = (1000.0 * inputB) / inputA
        }
        let formatted = "\(BioMathFormatter.format(val)) \(target.unitSuffix)"
        return ProteinMolarResult(target: target, value: val, formattedValueWithUnit: formatted)
    }

    /// DNA 编码容量三向互算 (1 氨基酸 = 3 bp ≈ 0.11 kDa)
    public static func dnaCodingCapacity(from source: CodingCapacitySource) -> CodingCapacityResult? {
        switch source {
        case .dnaBp(let bp):
            guard bp >= 0 else { return nil }
            let aa = floor(bp / 3.0)
            let kda = aa * 0.11
            return CodingCapacityResult(dnaBp: bp, aminoAcids: aa, proteinKDa: kda)
        case .proteinAA(let aa):
            guard aa >= 0 else { return nil }
            let bp = aa * 3.0
            let kda = aa * 0.11
            return CodingCapacityResult(dnaBp: bp, aminoAcids: aa, proteinKDa: kda)
        case .proteinKDa(let kda):
            guard kda >= 0 else { return nil }
            let aa = (kda / 0.11).rounded()
            let bp = aa * 3.0
            return CodingCapacityResult(dnaBp: bp, aminoAcids: aa, proteinKDa: kda)
        }
    }
}

// MARK: - 3. 生理生化公式换算引擎 (摩尔配制 / C1V1=C2V2 稀释 / 温度转换)

public enum LabBiochemCalculator {

    public enum MolarUnit: Int, CaseIterable, Identifiable, Sendable {
        case molar = 0
        case millimolar = -3
        case micromolar = -6
        case nanomolar = -9
        case picomolar = -12

        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .molar:      return "M"
            case .millimolar: return "mM"
            case .micromolar: return "µM"
            case .nanomolar:  return "nM"
            case .picomolar:  return "pM"
            }
        }
        public var multiplierToMolar: Double { pow(10.0, Double(rawValue)) }

        /// 摩尔浓度计算器支持的标准浓度单位（M / mM / µM）
        public static var molarityMassCases: [MolarUnit] { [.molar, .millimolar, .micromolar] }
    }

    public enum VolumeUnit: Int, CaseIterable, Identifiable, Sendable {
        case liter = 0
        case milliliter = -3
        case microliter = -6

        public var id: Int { rawValue }
        public var title: String {
            switch self {
            case .liter:      return "L"
            case .milliliter: return "mL"
            case .microliter: return "µL"
            }
        }
        public var multiplierToLiter: Double { pow(10.0, Double(rawValue)) }
    }

    public struct MolarityMassResult: Equatable, Sendable {
        public let massInGrams: Double
        public let displayValue: Double
        public let displayUnit: String
        public let formattedMass: String
        public let warningMessage: String?
        public let exceedsDisplayLimit: Bool
    }

    public struct DilutionResult: Equatable, Sendable {
        public let stockVolumeInLiters: Double
        public let diluentVolumeInLiters: Double
        public let dilutionFold: Double
        public let displayValue: Double
        public let displayUnit: String
        public let formattedStockVolume: String
        public let formattedDiluentVolume: String
        public let warningMessage: String?
        public let errorMessage: String?
        public let isValid: Bool
    }

    public enum TemperatureSource: Equatable, Sendable {
        case fahrenheit(Double)
        case celsius(Double)
        case kelvin(Double)
    }

    public struct TemperatureResult: Equatable, Sendable {
        public let fahrenheit: Double
        public let celsius: Double
        public let kelvin: Double
        public let isBelowAbsoluteZero: Bool
        public let errorMessage: String?
    }

    /// 摩尔浓度配制质量计算: mass(g) = V(L) × C(mol/L) × MW(g/mol)
    public static func molarityMass(
        mwGPerMol: Double,
        concentration: Double,
        concUnit: MolarUnit,
        volume: Double,
        volUnit: VolumeUnit
    ) -> MolarityMassResult? {
        guard mwGPerMol > 0, concentration > 0, volume > 0 else { return nil }
        let massG = volume * volUnit.multiplierToLiter * concentration * concUnit.multiplierToMolar * mwGPerMol
        if massG > 1_000_000.0 {
            return MolarityMassResult(
                massInGrams: massG,
                displayValue: massG,
                displayUnit: "g",
                formattedMass: "--",
                warningMessage: L10n.t("超出质量可显示上限（> 10⁶ g）。"),
                exceedsDisplayLimit: true
            )
        }
        if massG >= 1.0 {
            let scaled = (massG * 1000.0).rounded() / 1000.0
            return MolarityMassResult(
                massInGrams: massG,
                displayValue: scaled,
                displayUnit: "g",
                formattedMass: "\(BioMathFormatter.format(scaled, fixedDecimals: 3)) g",
                warningMessage: nil,
                exceedsDisplayLimit: false
            )
        } else if massG >= 1e-3 {
            let scaled = ((massG * 1e3) * 100.0).rounded() / 100.0
            return MolarityMassResult(
                massInGrams: massG,
                displayValue: scaled,
                displayUnit: "mg",
                formattedMass: "\(BioMathFormatter.format(scaled, fixedDecimals: 2)) mg",
                warningMessage: nil,
                exceedsDisplayLimit: false
            )
        } else {
            let rawUg = massG * 1e6
            let scaled = rawUg >= 0.1 ? ((rawUg * 10.0).rounded() / 10.0) : BioMathFormatter.roundAdaptive(rawUg)
            return MolarityMassResult(
                massInGrams: massG,
                displayValue: scaled,
                displayUnit: "µg",
                formattedMass: "\(BioMathFormatter.format(scaled)) µg",
                warningMessage: L10n.t("请考虑配置浓度更高的母液，然后稀释到您所需的最终浓度。"),
                exceedsDisplayLimit: false
            )
        }
    }

    /// 溶液稀释计算: C₁V₁ = C₂V₂
    public static func dilution(
        stockConc: Double,
        stockUnit: MolarUnit,
        finalConc: Double,
        finalUnit: MolarUnit,
        finalVolume: Double,
        volUnit: VolumeUnit
    ) -> DilutionResult? {
        guard stockConc > 0, finalConc > 0, finalVolume > 0 else { return nil }
        let c1 = stockConc * stockUnit.multiplierToMolar
        let c2 = finalConc * finalUnit.multiplierToMolar
        let v2L = finalVolume * volUnit.multiplierToLiter
        let fold = c1 / c2

        if c2 > c1 {
            let neededConcentrate = c2 / c1
            return DilutionResult(
                stockVolumeInLiters: 0,
                diluentVolumeInLiters: 0,
                dilutionFold: fold,
                displayValue: 0,
                displayUnit: volUnit.title,
                formattedStockVolume: "--",
                formattedDiluentVolume: "--",
                warningMessage: nil,
                errorMessage: L10n.tr("您输入的母液浓度低于稀释液浓度，需要将母液浓缩 \(BioMathFormatter.format(neededConcentrate)) 倍。", "Stock concentration is below target; concentrate stock by \(BioMathFormatter.format(neededConcentrate))x."),
                isValid: false
            )
        }

        let v1L = v2L / fold
        let diluentL = max(0.0, v2L - v1L)
        let diluentFormatted = formatVolumeFromLiters(diluentL, preferredUnit: volUnit)

        if v1L >= 1.0 {
            let scaled = (v1L * 1000.0).rounded() / 1000.0
            return DilutionResult(
                stockVolumeInLiters: v1L,
                diluentVolumeInLiters: diluentL,
                dilutionFold: fold,
                displayValue: scaled,
                displayUnit: "L",
                formattedStockVolume: "\(BioMathFormatter.format(scaled, fixedDecimals: 3)) L",
                formattedDiluentVolume: diluentFormatted,
                warningMessage: nil,
                errorMessage: nil,
                isValid: true
            )
        } else if v1L >= 1e-3 {
            let scaled = ((v1L * 1e3) * 100.0).rounded() / 100.0
            return DilutionResult(
                stockVolumeInLiters: v1L,
                diluentVolumeInLiters: diluentL,
                dilutionFold: fold,
                displayValue: scaled,
                displayUnit: "mL",
                formattedStockVolume: "\(BioMathFormatter.format(scaled, fixedDecimals: 2)) mL",
                formattedDiluentVolume: diluentFormatted,
                warningMessage: nil,
                errorMessage: nil,
                isValid: true
            )
        } else if v1L >= 1e-6 {
            let scaled = ((v1L * 1e6) * 10.0).rounded() / 10.0
            return DilutionResult(
                stockVolumeInLiters: v1L,
                diluentVolumeInLiters: diluentL,
                dilutionFold: fold,
                displayValue: scaled,
                displayUnit: "µL",
                formattedStockVolume: "\(BioMathFormatter.format(scaled, fixedDecimals: 1)) µL",
                formattedDiluentVolume: diluentFormatted,
                warningMessage: nil,
                errorMessage: nil,
                isValid: true
            )
        } else if v1L >= 1e-9 {
            let scaled = (v1L * 1e9).rounded()
            return DilutionResult(
                stockVolumeInLiters: v1L,
                diluentVolumeInLiters: diluentL,
                dilutionFold: fold,
                displayValue: scaled,
                displayUnit: "nL",
                formattedStockVolume: "\(BioMathFormatter.format(scaled, fixedDecimals: 0)) nL",
                formattedDiluentVolume: diluentFormatted,
                warningMessage: L10n.t("通常，移液器很难准确移取该体积，您需要考虑将母液预稀释。"),
                errorMessage: nil,
                isValid: true
            )
        } else if v1L >= 1e-12 {
            let scaled = (v1L * 1e12).rounded()
            return DilutionResult(
                stockVolumeInLiters: v1L,
                diluentVolumeInLiters: diluentL,
                dilutionFold: fold,
                displayValue: scaled,
                displayUnit: "pL",
                formattedStockVolume: "\(BioMathFormatter.format(scaled, fixedDecimals: 0)) pL",
                formattedDiluentVolume: diluentFormatted,
                warningMessage: L10n.t("通常，移液器很难准确移取该体积，您需要考虑将母液预稀释。"),
                errorMessage: nil,
                isValid: true
            )
        } else {
            return DilutionResult(
                stockVolumeInLiters: v1L,
                diluentVolumeInLiters: diluentL,
                dilutionFold: fold,
                displayValue: 0,
                displayUnit: "pL",
                formattedStockVolume: "< 1 pL",
                formattedDiluentVolume: diluentFormatted,
                warningMessage: nil,
                errorMessage: L10n.t("所需体积小于 1 pL，请确保输入正确；建议将母液大幅预稀释后再制备所需工作液。"),
                isValid: false
            )
        }
    }

    private static func formatVolumeFromLiters(_ liters: Double, preferredUnit: VolumeUnit) -> String {
        let scaled = liters / preferredUnit.multiplierToLiter
        return "\(BioMathFormatter.format(scaled, fixedDecimals: 2)) \(preferredUnit.title)"
    }

    /// 温度转换计算: °F ↔ °C ↔ K (遵循 °K = °C + 273.16，并拦截 < 0 K 非法输入)
    public static func convertTemperature(from source: TemperatureSource) -> TemperatureResult {
        let f: Double
        let c: Double
        let k: Double
        switch source {
        case .fahrenheit(let valF):
            f = valF
            c = (5.0 / 9.0) * (valF - 32.0)
            k = c + 273.16
        case .celsius(let valC):
            c = valC
            f = (9.0 / 5.0) * valC + 32.0
            k = valC + 273.16
        case .kelvin(let valK):
            k = valK
            c = valK - 273.16
            f = (9.0 / 5.0) * c + 32.0
        }
        let round2: (Double) -> Double = { ($0 * 100.0).rounded() / 100.0 }
        if k < 0 {
            return TemperatureResult(
                fahrenheit: round2(f),
                celsius: round2(c),
                kelvin: round2(k),
                isBelowAbsoluteZero: true,
                errorMessage: L10n.t("温度低于绝对零度（0 K / -273.16 °C），请检查输入值。")
            )
        }
        return TemperatureResult(
            fahrenheit: round2(f),
            celsius: round2(c),
            kelvin: round2(k),
            isBelowAbsoluteZero: false,
            errorMessage: nil
        )
    }
}
