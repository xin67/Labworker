import Foundation

/// 引擎运行模式
public enum EngineMode: String, CaseIterable, Identifiable {
    case smartDual = "smartDual"
    case onlineOnly = "onlineOnly"
    case offlineOnly = "offlineOnly"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .smartDual:   return "⚡️ 双引擎协同"
        case .onlineOnly:  return "🌐 官方在线引擎"
        case .offlineOnly: return "💻 本地离线引擎"
        }
    }
    
    public var subtitle: String {
        switch self {
        case .smartDual:   return "优先使用本地自定义参数或官方 API，断网自动切换本地算法"
        case .onlineOnly:  return "通过诺唯赞在线接口计算"
        case .offlineOnly: return "完全基于本地热力学算法计算"
        }
    }
}

/// 双引擎调度中控 (Dual-Engine Coordinator)
/// 所有引物退火温度与熔解温度 (Tm) 统一强制使用 SnapGene 热力学算法 (TmCalculator) 计算
public final class DualEngineCoordinator {
    public static let shared = DualEngineCoordinator()
    
    public var currentMode: EngineMode = .smartDual
    
    // MARK: - HTML 标签清洗辅助 (官方 API 会返回 <span style="color: red;">等)
    public static func stripHTMLTags(_ str: String) -> String {
        return str.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
    
    /// 根据完整引物序列与已知 5' 同源臂/酶切位点前缀，按 SnapGene 算法计算退火区（含 5' 悬垂端）的 Tm
    public static func computeSnapGenePrimerMetrics(
        fullSequence: String,
        homologyArm: String = "",
        enzymeSite: String = ""
    ) -> (specificSeq: String, tm: Double) {
        let cleanFull = BioSequence.clean(fullSequence)
        let prefixLen = homologyArm.count + enzymeSite.count
        guard cleanFull.count > prefixLen && prefixLen > 0 else {
            let tm = TmCalculator.calculate(sequence: cleanFull).tm
            return (cleanFull, tm)
        }
        let splitIdx = cleanFull.index(cleanFull.startIndex, offsetBy: prefixLen)
        let overhang = String(cleanFull[..<splitIdx])
        let spec = String(cleanFull[splitIdx...])
        let tm = TmCalculator.calculate(sequence: spec, fivePrimeOverhang: overhang).tm
        return (spec, tm)
    }
    
    // MARK: - 入门克隆引物调度
    public func designEntryClone(
        sequence: String,
        hasEnzymes: Bool,
        enzyme5: RestrictionEnzyme?,
        enzyme3: RestrictionEnzyme?,
        targetTm: Double = 60.0,
        tolerance: Double = 1.0
    ) async throws -> HomologyArmDesigner.DesignResult {
        let cleanSeq = BioSequence.clean(sequence)
        guard cleanSeq.count >= 50 else {
            throw NSError(domain: "Coord", code: -1, userInfo: [NSLocalizedDescriptionKey: "插入片段长度必须大于等于 50 bp"])
        }
        
        // 1. 离线模式或用户自定义了非 60℃ 的目标退火温度时，优先使用本地算法以精确匹配自定义 Tm 与浮动区间
        if currentMode == .offlineOnly || abs(targetTm - 60.0) > 0.1 {
            return HomologyArmDesigner.designEntryClone(
                insertSeq: cleanSeq,
                hasEnzymes: hasEnzymes,
                enzyme5: enzyme5,
                enzyme3: enzyme3,
                targetTm: targetTm,
                tolerance: tolerance
            )
        }
        
        // 2. 在线或双引擎模式（序列从在线接口获取后，Tm 统一按 SnapGene 算法计算）
        do {
            let res = try await CloneOnlineAPIClient.shared.requestEntryClone(
                sequence: cleanSeq,
                hasEnzymes: hasEnzymes,
                enzyme5Name: enzyme5?.name ?? "",
                enzyme5Site: enzyme5?.site ?? "",
                enzyme3Name: enzyme3?.name ?? "",
                enzyme3Site: enzyme3?.site ?? ""
            )
            
            let rawF = Self.stripHTMLTags(res.PrimerFvalue ?? "")
            let rawR = Self.stripHTMLTags(res.PrimerRvalue ?? "")
            let e5Site = hasEnzymes ? (enzyme5?.site.lowercased() ?? "") : ""
            let e3Site = hasEnzymes ? (enzyme3?.site.lowercased() ?? "") : ""
            
            let (fSpec, fTm) = Self.computeSnapGenePrimerMetrics(
                fullSequence: rawF,
                homologyArm: HomologyArmDesigner.entryURS,
                enzymeSite: e5Site
            )
            let (rSpec, rTm) = Self.computeSnapGenePrimerMetrics(
                fullSequence: rawR,
                homologyArm: HomologyArmDesigner.entryDRS,
                enzymeSite: e3Site
            )
            
            let primerF = PrimerItem(
                name: "CE-Entry-F",
                fullSequence: rawF,
                homologyArm: HomologyArmDesigner.entryURS,
                enzymeName: hasEnzymes ? enzyme5?.name : nil,
                enzymeSite: hasEnzymes ? e5Site : nil,
                specificSequence: fSpec,
                tm: fTm,
                targetPurpose: "ClonExpress 入门克隆正向引物",
                notes: "5' URS (15bp)" + (hasEnzymes ? " + \(enzyme5?.name ?? "")" : "") + " + 特异序列 (Tm: \(fTm)℃)",
                sourceTool: "入门克隆"
            )
            
            let primerR = PrimerItem(
                name: "CE-Entry-R",
                fullSequence: rawR,
                homologyArm: HomologyArmDesigner.entryDRS,
                enzymeName: hasEnzymes ? enzyme3?.name : nil,
                enzymeSite: hasEnzymes ? e3Site : nil,
                specificSequence: rSpec,
                tm: rTm,
                targetPurpose: "ClonExpress 入门克隆反向引物",
                notes: "5' DRS (15bp)" + (hasEnzymes ? " + \(enzyme3?.name ?? "")" : "") + " + 特异序列 (Tm: \(rTm)℃)",
                sourceTool: "入门克隆"
            )
            
            return HomologyArmDesigner.DesignResult(
                primerF: primerF,
                primerR: primerR,
                promptMessage: res.promptMessage
            )
        } catch {
            // 在线失败：若是双引擎模式，自动降级为本地算法
            if currentMode == .smartDual {
                let localResult = HomologyArmDesigner.designEntryClone(
                    insertSeq: cleanSeq,
                    hasEnzymes: hasEnzymes,
                    enzyme5: enzyme5,
                    enzyme3: enzyme3,
                    targetTm: targetTm,
                    tolerance: tolerance
                )
                return HomologyArmDesigner.DesignResult(
                    primerF: localResult.primerF,
                    primerR: localResult.primerR,
                    promptMessage: "在线接口未响应，已切换为本地算法生成。"
                )
            } else {
                throw error
            }
        }
    }
    
    // MARK: - 引物 Tm 快速测算（100% 遵循 SnapGene 算法）
    public func calculateTm(sequence: String) async -> TmCalculator.Result {
        let clean = TmCalculator.normalizeOligo(sequence)
        guard !clean.isEmpty else {
            return TmCalculator.Result(length: 0, gcPercent: 0, tm: 0, snapGeneIntegerTm: 0, recommendedTa: 0)
        }
        return TmCalculator.calculate(sequence: clean)
    }
}
