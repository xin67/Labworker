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
    
    public init() {}
    
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
