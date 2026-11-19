import Foundation
import SwiftUI
import AppKit
import Combine

// MARK: - 5. 重组反应 DNA 使用量计算器 ViewModel
@MainActor
public final class CalculatorViewModel: ObservableObject {
    @Published public var cloneType: DNAMolarCalculator.CloneType = .single
    @Published public var vectorName: String = ""
    @Published public var vectorLengthKb: String = "5.0"
    @Published public var vectorConcentration: String = "50"
    /// 载体自定义投入量 (ng)，留空时默认采用公式推荐值
    @Published public var vectorCustomNg: String = ""
    
    @Published public var insertNames: [String] = ["片段 1", "片段 2"]
    @Published public var insertLengths: [String] = ["1.0", "1.0"]
    @Published public var insertConcs: [String] = ["20", "20"]
    /// 插入片段自定义投入量 (ng)，留空时默认采用公式推荐值
    @Published public var insertCustomNgs: [String] = ["", ""]

    /// 经典摩尔比模式参数（默认 0.03 pmol 载体 + 1:3 载体:片段摩尔比）
    @Published public var ligationVectorPmol: String = "0.03"
    @Published public var ligationMolarRatio: DNAMolarCalculator.LigationMolarRatio = .r1_3
    
    public init() {}

    public var parsedLigationVectorPmol: Double {
        let val = Double(ligationVectorPmol.trimmingCharacters(in: .whitespaces)) ?? 0.03
        return max(0.0001, val)
    }

    public var ligationRatioResult: DNAMolarCalculator.LigationRatioResult? {
        let vecBp = parsedVectorLengthBp
        let insBp = parsedInsertLengthBp(at: 0)
        let vecConc = Double(vectorConcentration.trimmingCharacters(in: .whitespaces))
        let insConc = Double((insertConcs.first ?? "").trimmingCharacters(in: .whitespaces))
        return DNAMolarCalculator.calculateLigationByMolarRatio(
            vectorLengthBp: vecBp,
            vectorConcNgPerUl: vecConc,
            vectorPmol: parsedLigationVectorPmol,
            insertLengthBp: insBp,
            insertConcNgPerUl: insConc,
            molarRatio: ligationMolarRatio
        )
    }
    
    /// 解析载体长度 (bp)
    public var parsedVectorLengthBp: Int {
        let raw = Double(vectorLengthKb.trimmingCharacters(in: .whitespaces)) ?? 5.0
        let kb = DNAMolarCalculator.normalizeLengthToKb(raw)
        return max(0, Int((kb * 1000.0).rounded()))
    }
    
    /// 解析指定插入片段长度 (bp)
    public func parsedInsertLengthBp(at index: Int) -> Int {
        let lenStr = index < insertLengths.count ? insertLengths[index] : "1.0"
        let raw = Double(lenStr.trimmingCharacters(in: .whitespaces)) ?? 1.0
        let kb = DNAMolarCalculator.normalizeLengthToKb(raw)
        return max(0, Int((kb * 1000.0).rounded()))
    }
    
    public var vectorResult: DNAMolarCalculator.CalculationResult {
        let len = Double(vectorLengthKb.trimmingCharacters(in: .whitespaces)) ?? 5.0
        let conc = Double(vectorConcentration.trimmingCharacters(in: .whitespaces)) ?? 50.0
        let custom = Double(vectorCustomNg.trimmingCharacters(in: .whitespaces))
        return DNAMolarCalculator.calculate(
            cloneType: cloneType,
            isVector: true,
            lengthKb: max(0.05, len),
            concentrationNgPerUl: max(0.1, conc),
            customNg: custom
        )
    }
    
    public func insertResult(at index: Int) -> DNAMolarCalculator.CalculationResult {
        let lenStr = index < insertLengths.count ? insertLengths[index] : "1.0"
        let concStr = index < insertConcs.count ? insertConcs[index] : "20"
        let ngStr = index < insertCustomNgs.count ? insertCustomNgs[index] : ""
        let len = Double(lenStr.trimmingCharacters(in: .whitespaces)) ?? 1.0
        let conc = Double(concStr.trimmingCharacters(in: .whitespaces)) ?? 20.0
        let custom = Double(ngStr.trimmingCharacters(in: .whitespaces))
        return DNAMolarCalculator.calculate(
            cloneType: cloneType,
            isVector: false,
            lengthKb: max(0.05, len),
            concentrationNgPerUl: max(0.1, conc),
            customNg: custom
        )
    }
    
    /// 计算 20 μL 反应体系中除 10 μL 2× Mix 与 DNA 外的剩余 ddH₂O 体积 (μL)
    public var remainingWaterVolumeUl: Double {
        var dnaVol = 0.0
        if cloneType == .ligationRatio {
            if let lig = ligationRatioResult {
                dnaVol += (lig.vectorVolUl ?? 0) + (lig.insertVolUl ?? 0)
            }
            return max(0.0, 20.0 - 10.0 - dnaVol)
        }
        if cloneType != .simple {
            dnaVol += (vectorResult.recommendedVol ?? 0)
        }
        let count = (cloneType == .multi) ? insertLengths.count : 1
        for idx in 0..<count {
            dnaVol += (insertResult(at: idx).recommendedVol ?? 0)
        }
        return max(0.0, 20.0 - 10.0 - dnaVol)
    }
    
    public var remainingWaterFormatted: String {
        let w = remainingWaterVolumeUl
        return String(format: "%.2f μL (补齐至 20 μL)", w)
    }
    
    public func addInsertSlot() {
        guard insertLengths.count < 11 else { return }
        let nextIdx = insertLengths.count + 1
        insertNames.append("片段 \(nextIdx)")
        insertLengths.append("1.0")
        insertConcs.append("20")
        insertCustomNgs.append("")
    }
    
    public func removeInsertSlot(at index: Int) {
        guard insertLengths.count > 1, index < insertLengths.count else { return }
        insertLengths.remove(at: index)
        if index < insertNames.count { insertNames.remove(at: index) }
        if index < insertConcs.count { insertConcs.remove(at: index) }
        if index < insertCustomNgs.count { insertCustomNgs.remove(at: index) }
    }
    
    /// 一键从同源重组克隆模块同步载体长度与插入片段长度
    public func syncFromHomologousCloning(
        type: DNAMolarCalculator.CloneType,
        vectorName: String = "",
        vectorLengthBp: Int,
        inserts: [(name: String, lengthBp: Int)],
        navigate: Bool = true
    ) {
        self.cloneType = type
        self.vectorName = vectorName
        if vectorLengthBp > 0 {
            self.vectorLengthKb = String(format: "%.3f", Double(vectorLengthBp) / 1000.0)
        }
        if !inserts.isEmpty {
            self.insertNames = inserts.enumerated().map { idx, item in
                item.name.isEmpty ? "片段 \(idx + 1)" : item.name
            }
            self.insertLengths = inserts.map { item in
                let bp = max(50, item.lengthBp)
                return String(format: "%.3f", Double(bp) / 1000.0)
            }
            while self.insertConcs.count < inserts.count {
                self.insertConcs.append("20")
            }
            while self.insertCustomNgs.count < inserts.count {
                self.insertCustomNgs.append("")
            }
        }
        if navigate {
            WorkspaceSessionManager.shared.bioCalculatorVM.selectedCategory = .cloningAndLigation
            AppState.shared.selectedNav = .dnaCalculator
        }
        let vecDesc = vectorLengthBp > 0 ? "载体 \(vectorLengthBp) bp" : "载体未设"
        let insDesc = inserts.map { "\($0.name.isEmpty ? "片段" : $0.name) \($0.lengthBp) bp" }.joined(separator: " + ")
        AppState.shared.showToast("已同步至用量计算：\(vecDesc)，\(insDesc)")
    }
}

// MARK: - 6. 序列工具与 Tm 测算 ViewModel
@MainActor
public final class SequenceToolViewModel: ObservableObject {
    @Published public var inputSeq: String = ""
    @Published public var outputSeq: String = ""
    @Published public var tmResult: TmCalculator.Result? = nil
    @Published public var isCalculating: Bool = false
    
    public init() {}
    
    public var cleanLength: Int {
        BioSequence.clean(inputSeq).count
    }
    
    public var cleanGC: Double {
        BioSequence.gcContent(inputSeq)
    }
    
    public func doReverseComplement() {
        outputSeq = BioSequence.reverseComplement(BioSequence.clean(inputSeq))
    }
    
    public func doReverse() {
        outputSeq = BioSequence.reverse(BioSequence.clean(inputSeq))
    }
    
    public func doComplement() {
        outputSeq = BioSequence.complement(BioSequence.clean(inputSeq))
    }
    
    public func calculateTm() async {
        let clean = BioSequence.clean(inputSeq)
        guard !clean.isEmpty else { return }
        isCalculating = true
        defer { isCalculating = false }
        tmResult = await DualEngineCoordinator.shared.calculateTm(sequence: clean)
    }
    
    public func copyOutput() {
        guard !outputSeq.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(outputSeq, forType: .string)
        AppState.shared.showToast("已复制到剪贴板")
    }
}

// MARK: - 7. 综合生物科研换算工作台 ViewModel (DNA / 蛋白 / 生理生化公式)

public enum BioCalculatorCategory: String, CaseIterable, Identifiable, Sendable {
    case cloningAndLigation = "cloningAndLigation"
    case dnaConversion = "dnaConversion"
    case proteinConversion = "proteinConversion"
    case biochemFormula = "biochemFormula"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cloningAndLigation: return "克隆与连接"
        case .dnaConversion:      return "DNA 换算"
        case .proteinConversion:  return "蛋白质换算"
        case .biochemFormula:     return "生理生化公式"
        }
    }
}

public enum DNAConversionSubtool: String, CaseIterable, Identifiable, Sendable {
    case dsDNA = "dsDNA"
    case ssDNA = "ssDNA"
    case linearDNA = "linearDNA"
    case nucleicAcid = "nucleicAcid"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dsDNA:       return "dsDNA（双链 DNA）"
        case .ssDNA:       return "ssDNA（单链 DNA）"
        case .linearDNA:   return "Linear DNA（线性 DNA）"
        case .nucleicAcid: return "Nucleic Acid（核酸 OD260）"
        }
    }
}

public enum ProteinConversionSubtool: String, CaseIterable, Identifiable, Sendable {
    case molar = "molar"
    case codingCapacity = "codingCapacity"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .molar:          return "蛋白质摩尔转换"
        case .codingCapacity: return "DNA 编码容量"
        }
    }
}

public enum BiochemFormulaSubtool: String, CaseIterable, Identifiable, Sendable {
    case molarityMass = "molarityMass"
    case dilution = "dilution"
    case temperature = "temperature"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .molarityMass: return "摩尔浓度计算"
        case .dilution:     return "稀释度计算"
        case .temperature:  return "温度转换"
        }
    }
}

public struct BioCalculationHistoryItem: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let category: String
    public let expression: String
    public let resultText: String
    public let timestamp: Date
}

@MainActor
public final class BioCalculatorSuiteViewModel: ObservableObject {
    @Published public var selectedCategory: BioCalculatorCategory = .cloningAndLigation
    @Published public var dnaSubtool: DNAConversionSubtool = .dsDNA
    @Published public var proteinSubtool: ProteinConversionSubtool = .molar
    @Published public var biochemSubtool: BiochemFormulaSubtool = .molarityMass

    // MARK: DNA 换算状态
    @Published public var dsdnaDirection: LabDNAConverter.DSDNADirection = .ugToPmol
    @Published public var dsdnaLengthBp: String = "5000"
    @Published public var dsdnaInputValue: String = "1"

    @Published public var ssdnaDirection: LabDNAConverter.SSDNADirection = .ugPerMlToPmolPerUl
    @Published public var ssdnaLengthNt: String = "20"
    @Published public var ssdnaInputValue: String = "100"

    @Published public var linearLengthKb: String = "5"
    @Published public var linearMassUg: String = "1"

    @Published public var od260Reading: String = "0.5"
    @Published public var od260SampleType: LabDNAConverter.NucleicAcidSampleType = .dsDNA
    @Published public var od260DilutionFactor: String = "1"

    // MARK: 蛋白质换算状态
    @Published public var proteinTarget: LabProteinConverter.ProteinMolarTarget = .sizeKDa
    @Published public var proteinInputA: String = "50"
    @Published public var proteinInputB: String = "1000"

    @Published public var codingBP: String = "900"
    @Published public var codingAA: String = "300"
    @Published public var codingKDa: String = "33"
    @Published public var codingLastEdited: String = "bp"

    // MARK: 生理生化公式换算状态
    @Published public var molarityMW: String = "58.44"
    @Published public var molarityConc: String = "100"
    @Published public var molarityConcUnit: LabBiochemCalculator.MolarUnit = .millimolar
    @Published public var molarityVol: String = "500"
    @Published public var molarityVolUnit: LabBiochemCalculator.VolumeUnit = .milliliter

    @Published public var dilutionStockConc: String = "1"
    @Published public var dilutionStockUnit: LabBiochemCalculator.MolarUnit = .molar
    @Published public var dilutionFinalConc: String = "10"
    @Published public var dilutionFinalUnit: LabBiochemCalculator.MolarUnit = .millimolar
    @Published public var dilutionFinalVol: String = "50"
    @Published public var dilutionFinalVolUnit: LabBiochemCalculator.VolumeUnit = .milliliter

    @Published public var tempF: String = "98.6"
    @Published public var tempC: String = "37"
    @Published public var tempK: String = "310.16"
    @Published public var tempLastEdited: String = "c"

    @Published public var history: [BioCalculationHistoryItem] = []

    public init() {}

    // MARK: 计算输出视图属性
    public var dsdnaComputedValue: Double? {
        guard let bp = parsePositive(dsdnaLengthBp), let v = parseNonNegative(dsdnaInputValue) else { return nil }
        switch dsdnaDirection {
        case .ugToPmol: return LabDNAConverter.dsdnaUgToPmol(lengthBp: bp, massUg: v)
        case .pmolToUg: return LabDNAConverter.dsdnaPmolToUg(lengthBp: bp, pmol: v)
        }
    }

    public var ssdnaComputedValue: Double? {
        guard let nt = parsePositive(ssdnaLengthNt), let v = parseNonNegative(ssdnaInputValue) else { return nil }
        switch ssdnaDirection {
        case .ugPerMlToPmolPerUl: return LabDNAConverter.ssdnaUgPerMlToPmolPerUl(lengthNt: nt, concUgPerMl: v)
        case .pmolPerUlToUgPerMl: return LabDNAConverter.ssdnaPmolPerUlToUgPerMl(lengthNt: nt, concPmolPerUl: v)
        }
    }

    public var linearEndsComputedValue: Double? {
        guard let kb = parsePositive(linearLengthKb), let ug = parseNonNegative(linearMassUg) else { return nil }
        return LabDNAConverter.linearDNAUgToPmolEnds(lengthKb: kb, massUg: ug)
    }

    public var od260Result: LabDNAConverter.OD260Result? {
        guard let od = parseNonNegative(od260Reading) else { return nil }
        let dil = parsePositive(od260DilutionFactor) ?? 1.0
        return LabDNAConverter.od260ToConcentration(od260: od, sampleType: od260SampleType, dilutionFactor: dil)
    }

    public var proteinMolarResult: LabProteinConverter.ProteinMolarResult? {
        guard let a = parseNonNegative(proteinInputA), let b = parseNonNegative(proteinInputB) else { return nil }
        return LabProteinConverter.proteinMolar(target: proteinTarget, inputA: a, inputB: b)
    }

    public var molarityMassResult: LabBiochemCalculator.MolarityMassResult? {
        guard let mw = parsePositive(molarityMW),
              let c = parsePositive(molarityConc),
              let v = parsePositive(molarityVol) else { return nil }
        return LabBiochemCalculator.molarityMass(
            mwGPerMol: mw,
            concentration: c,
            concUnit: molarityConcUnit,
            volume: v,
            volUnit: molarityVolUnit
        )
    }

    public var dilutionResult: LabBiochemCalculator.DilutionResult? {
        guard let c1 = parsePositive(dilutionStockConc),
              let c2 = parsePositive(dilutionFinalConc),
              let v2 = parsePositive(dilutionFinalVol) else { return nil }
        return LabBiochemCalculator.dilution(
            stockConc: c1,
            stockUnit: dilutionStockUnit,
            finalConc: c2,
            finalUnit: dilutionFinalUnit,
            finalVolume: v2,
            volUnit: dilutionFinalVolUnit
        )
    }

    public var temperatureValidationError: String? {
        switch tempLastEdited {
        case "f":
            guard let f = Double(tempF.trimmingCharacters(in: .whitespaces)) else { return nil }
            return LabBiochemCalculator.convertTemperature(from: .fahrenheit(f)).errorMessage
        case "k":
            guard let k = Double(tempK.trimmingCharacters(in: .whitespaces)) else { return nil }
            return LabBiochemCalculator.convertTemperature(from: .kelvin(k)).errorMessage
        default:
            guard let c = Double(tempC.trimmingCharacters(in: .whitespaces)) else { return nil }
            return LabBiochemCalculator.convertTemperature(from: .celsius(c)).errorMessage
        }
    }

    // MARK: 三栏联动方法
    public func updateCodingBP(_ newValue: String) {
        codingBP = newValue
        codingLastEdited = "bp"
        guard let bp = parseNonNegative(newValue),
              let res = LabProteinConverter.dnaCodingCapacity(from: .dnaBp(bp)) else {
            codingAA = ""
            codingKDa = ""
            return
        }
        codingAA = BioMathFormatter.format(res.aminoAcids)
        codingKDa = BioMathFormatter.format(res.proteinKDa)
    }

    public func updateCodingAA(_ newValue: String) {
        codingAA = newValue
        codingLastEdited = "aa"
        guard let aa = parseNonNegative(newValue),
              let res = LabProteinConverter.dnaCodingCapacity(from: .proteinAA(aa)) else {
            codingBP = ""
            codingKDa = ""
            return
        }
        codingBP = BioMathFormatter.format(res.dnaBp)
        codingKDa = BioMathFormatter.format(res.proteinKDa)
    }

    public func updateCodingKDa(_ newValue: String) {
        codingKDa = newValue
        codingLastEdited = "kda"
        guard let kda = parseNonNegative(newValue),
              let res = LabProteinConverter.dnaCodingCapacity(from: .proteinKDa(kda)) else {
            codingBP = ""
            codingAA = ""
            return
        }
        codingBP = BioMathFormatter.format(res.dnaBp)
        codingAA = BioMathFormatter.format(res.aminoAcids)
    }

    public func updateTempF(_ newValue: String) {
        tempF = newValue
        tempLastEdited = "f"
        guard let f = Double(newValue.trimmingCharacters(in: .whitespaces)) else {
            tempC = ""
            tempK = ""
            return
        }
        let res = LabBiochemCalculator.convertTemperature(from: .fahrenheit(f))
        if res.isBelowAbsoluteZero {
            tempC = ""
            tempK = ""
        } else {
            tempC = BioMathFormatter.format(res.celsius)
            tempK = BioMathFormatter.format(res.kelvin)
        }
    }

    public func updateTempC(_ newValue: String) {
        tempC = newValue
        tempLastEdited = "c"
        guard let c = Double(newValue.trimmingCharacters(in: .whitespaces)) else {
            tempF = ""
            tempK = ""
            return
        }
        let res = LabBiochemCalculator.convertTemperature(from: .celsius(c))
        if res.isBelowAbsoluteZero {
            tempF = ""
            tempK = ""
        } else {
            tempF = BioMathFormatter.format(res.fahrenheit)
            tempK = BioMathFormatter.format(res.kelvin)
        }
    }

    public func updateTempK(_ newValue: String) {
        tempK = newValue
        tempLastEdited = "k"
        guard let k = Double(newValue.trimmingCharacters(in: .whitespaces)) else {
            tempF = ""
            tempC = ""
            return
        }
        let res = LabBiochemCalculator.convertTemperature(from: .kelvin(k))
        if res.isBelowAbsoluteZero {
            tempF = ""
            tempC = ""
        } else {
            tempF = BioMathFormatter.format(res.fahrenheit)
            tempC = BioMathFormatter.format(res.celsius)
        }
    }

    // MARK: 快捷交互动作
    public func appendHistory(category: String, expression: String, resultText: String) {
        let entry = BioCalculationHistoryItem(
            category: category,
            expression: expression,
            resultText: resultText,
            timestamp: Date()
        )
        history.insert(entry, at: 0)
        if history.count > 10 {
            history = Array(history.prefix(10))
        }
    }

    public func clearCurrentSubtool() {
        switch selectedCategory {
        case .cloningAndLigation:
            let calc = WorkspaceSessionManager.shared.calculatorVM
            calc.vectorCustomNg = ""
            calc.vectorLengthKb = ""
            calc.vectorConcentration = ""
            calc.ligationVectorPmol = "0.03"
            calc.insertLengths = ["", ""]
            calc.insertConcs = ["", ""]
            calc.insertCustomNgs = ["", ""]
        case .dnaConversion:
            switch dnaSubtool {
            case .dsDNA:       dsdnaLengthBp = ""; dsdnaInputValue = ""
            case .ssDNA:       ssdnaLengthNt = ""; ssdnaInputValue = ""
            case .linearDNA:   linearLengthKb = ""; linearMassUg = ""
            case .nucleicAcid: od260Reading = ""; od260DilutionFactor = "1"
            }
        case .proteinConversion:
            switch proteinSubtool {
            case .molar:          proteinInputA = ""; proteinInputB = ""
            case .codingCapacity: codingBP = ""; codingAA = ""; codingKDa = ""
            }
        case .biochemFormula:
            switch biochemSubtool {
            case .molarityMass: molarityMW = ""; molarityConc = ""; molarityVol = ""
            case .dilution:     dilutionStockConc = ""; dilutionFinalConc = ""; dilutionFinalVol = ""
            case .temperature:  tempF = ""; tempC = ""; tempK = ""
            }
        }
    }

    public func loadExampleForCurrentSubtool() {
        switch selectedCategory {
        case .cloningAndLigation:
            let calc = WorkspaceSessionManager.shared.calculatorVM
            calc.vectorName = "pET-28a 线性化"
            calc.vectorLengthKb = "5.369"
            calc.vectorConcentration = "50"
            calc.ligationVectorPmol = "0.03"
            calc.ligationMolarRatio = .r1_3
            calc.insertNames = ["EGFP", "mCherry"]
            calc.insertLengths = ["0.720", "0.711"]
            calc.insertConcs = ["25", "25"]
            calc.insertCustomNgs = ["", ""]
        case .dnaConversion:
            switch dnaSubtool {
            case .dsDNA:
                dsdnaLengthBp = "5000"
                dsdnaInputValue = dsdnaDirection == .ugToPmol ? "1" : "0.303"
            case .ssDNA:
                ssdnaLengthNt = "20"
                ssdnaInputValue = ssdnaDirection == .ugPerMlToPmolPerUl ? "100" : "15.15"
            case .linearDNA:
                linearLengthKb = "5.0"
                linearMassUg = "1.0"
            case .nucleicAcid:
                od260Reading = "0.65"
                od260SampleType = .dsDNA
                od260DilutionFactor = "1"
            }
        case .proteinConversion:
            switch proteinSubtool {
            case .molar:
                proteinTarget = .sizeKDa
                proteinInputA = "50"
                proteinInputB = "1000"
            case .codingCapacity:
                updateCodingBP("1080")
            }
        case .biochemFormula:
            switch biochemSubtool {
            case .molarityMass:
                molarityMW = "121.14"
                molarityConc = "50"
                molarityConcUnit = .millimolar
                molarityVol = "1000"
                molarityVolUnit = .milliliter
            case .dilution:
                dilutionStockConc = "1"
                dilutionStockUnit = .molar
                dilutionFinalConc = "20"
                dilutionFinalUnit = .millimolar
                dilutionFinalVol = "50"
                dilutionFinalVolUnit = .milliliter
            case .temperature:
                updateTempC("37")
            }
        }
    }

    private func parsePositive(_ text: String) -> Double? {
        guard let val = Double(text.trimmingCharacters(in: .whitespaces)), val > 0, val.isFinite else { return nil }
        return val
    }

    private func parseNonNegative(_ text: String) -> Double? {
        guard let val = Double(text.trimmingCharacters(in: .whitespaces)), val >= 0, val.isFinite else { return nil }
        return val
    }
}
