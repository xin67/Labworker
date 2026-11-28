import Foundation

// MARK: - 1. 琼脂糖凝胶浓度与电泳迁移物理模型

/// 质粒同源重组 PCR 扩增琼脂糖凝胶电泳常用浓度档位
public enum AgaroseGelConcentration: String, CaseIterable, Identifiable, Codable, Sendable {
    case c0_8 = "0.8%"
    case c1_0 = "1.0%"
    case c1_2 = "1.2%"
    case c1_5 = "1.5%"
    case c2_0 = "2.0%"

    public var id: String { rawValue }
    public var title: String { rawValue }

    /// 数值百分比 (0.8 ~ 2.0)
    public var percentValue: Double {
        switch self {
        case .c0_8: return 0.8
        case .c1_0: return 1.0
        case .c1_2: return 1.2
        case .c1_5: return 1.5
        case .c2_0: return 2.0
        }
    }

    /// 最佳线性分辨区间说明
    public var optimalRangeText: String {
        switch self {
        case .c0_8: return "1.0–12 kb (大载体骨架优选)"
        case .c1_0: return "0.4–8.0 kb (通用标准浓度)"
        case .c1_2: return "0.3–4.5 kb (常规 PCR/双切)"
        case .c1_5: return "0.15–2.5 kb (中等/短片段)"
        case .c2_0: return "0.1–1.2 kb (短片段高分辨)"
        }
    }

    /// 经验半迁移中心片段长度 (bp)，体现不同浓度琼脂糖凝胶的孔径筛分效应
    private var midpointBp: Double {
        switch self {
        case .c0_8: return 2400.0
        case .c1_0: return 1250.0
        case .c1_2: return 900.0
        case .c1_5: return 620.0
        case .c2_0: return 380.0
        }
    }

    /// log10(bp) 迁移曲线陡度斜率
    private var slopeK: Double {
        switch self {
        case .c0_8: return 2.02
        case .c1_0: return 2.12
        case .c1_2: return 2.20
        case .c1_5: return 2.30
        case .c2_0: return 2.42
        }
    }

    /// 计算给定片段大小 (bp) 在胶孔 (0.0) 到指示剂前缘 (1.0) 间的归一化迁移距离 yFraction ∈ [0.06, 0.94]
    public func migrationY(sizeBp: Int) -> Double {
        migrationY(sizeBp: Double(sizeBp))
    }

    public func migrationY(sizeBp: Double) -> Double {
        let clamped = max(25.0, min(50000.0, sizeBp))
        let u = log10(clamped)
        let uMid = log10(midpointBp)
        let y = 0.06 + 0.88 / (1.0 + exp(slopeK * (u - uMid)))
        return min(0.94, max(0.06, y))
    }

    /// 根据所有待分离条带尺寸自动推荐最佳琼脂糖浓度
    public static func recommendedConcentration(forSizesBp sizes: [Int]) -> AgaroseGelConcentration {
        let valid = sizes.filter { $0 >= 30 }
        guard !valid.isEmpty else { return .c1_0 }
        let minBp = valid.min() ?? 500
        let maxBp = valid.max() ?? 3000

        // 若全为极短片段且无大载体，选高浓度 2.0% 或 1.5%
        if maxBp <= 1100 {
            return minBp < 250 ? .c2_0 : .c1_5
        }
        if minBp < 220 && maxBp <= 3000 {
            return .c1_5
        }
        // 若最大载体骨架很大 (>= 6000 bp) 且短片段不低于 500 bp，选 0.8% 拉开大片段及邻近大小差异
        if maxBp >= 6000 && minBp >= 450 {
            return .c0_8
        }
        // 若存在中等片段组合 (300–4500 bp)
        if maxBp <= 4500 && minBp >= 250 {
            return .c1_2
        }
        return .c1_0
    }
}

// MARK: - 2. 模拟凝胶条带、泳道与诊断报告数据模型

/// 模拟电泳条带功能分类
public enum SimulatedGelBandRole: String, Codable, Sendable {
    case marker = "marker"
    case linearVector = "linearVector"
    case excisedDropout = "excisedDropout"
    case pcrAmplicon = "pcrAmplicon"
    case parentalPlasmid = "parentalPlasmid"
    case deletionAmplicon = "deletionAmplicon"

    public var roleTitle: String {
        switch self {
        case .marker:           return "DNA Marker 标准带"
        case .linearVector:     return "线性化载体骨架"
        case .excisedDropout:   return "切落/丢弃载体片段"
        case .pcrAmplicon:      return "同源重组 PCR 扩增产物"
        case .parentalPlasmid:  return "原始亲本质粒参考"
        case .deletionAmplicon: return "反向 PCR 缺失扩增产物"
        }
    }
}

/// 模拟凝胶上的单个 DNA 条带
public struct SimulatedGelBand: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let sizeBp: Int
    public let yFraction: Double
    public let role: SimulatedGelBandRole
    public let relativeBrightness: Double
    public let label: String
    public let detail: String

    public init(
        id: String,
        sizeBp: Int,
        yFraction: Double,
        role: SimulatedGelBandRole,
        relativeBrightness: Double = 0.90,
        label: String? = nil,
        detail: String = ""
    ) {
        self.id = id
        self.sizeBp = sizeBp
        self.yFraction = yFraction
        self.role = role
        self.relativeBrightness = relativeBrightness
        self.label = label ?? "\(sizeBp) bp"
        self.detail = detail
    }
}

/// 模拟凝胶中的单条泳道
public struct SimulatedGelLane: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let index: Int
    public let shortLabel: String
    public let fullTitle: String
    public let subtitle: String
    public let isMarker: Bool
    public let isMixedControl: Bool
    public let bands: [SimulatedGelBand]

    public init(
        id: String,
        index: Int,
        shortLabel: String,
        fullTitle: String,
        subtitle: String = "",
        isMarker: Bool = false,
        isMixedControl: Bool = false,
        bands: [SimulatedGelBand]
    ) {
        self.id = id
        self.index = index
        self.shortLabel = shortLabel
        self.fullTitle = fullTitle
        self.subtitle = subtitle
        self.isMarker = isMarker
        self.isMixedControl = isMixedControl
        self.bands = bands
    }
}

/// 分辨率与共迁移诊断告警
public struct GelResolutionWarning: Identifiable, Hashable, Codable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case warning
        case info
    }

    public let id: String
    public let severity: Severity
    public let message: String
    public let suggestedConcentration: AgaroseGelConcentration?
    public let suggestedLadderID: String?

    public init(
        id: String,
        severity: Severity = .warning,
        message: String,
        suggestedConcentration: AgaroseGelConcentration? = nil,
        suggestedLadderID: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.suggestedConcentration = suggestedConcentration
        self.suggestedLadderID = suggestedLadderID
    }
}

/// 同源重组扩增模拟凝胶完整输出包
public struct HomologousPCRGelSimulationResult: Hashable, Codable, Sendable {
    public let title: String
    public let concentration: AgaroseGelConcentration
    public let recommendedConcentration: AgaroseGelConcentration
    public let ladder: GelMarkerLadderPreset
    public let recommendedLadderID: String
    public let lanes: [SimulatedGelLane]
    public let warnings: [GelResolutionWarning]
    public let longestAmpliconBp: Int
    public let suggestedExtensionNote: String
    public let infoNotice: String?

    public init(
        title: String,
        concentration: AgaroseGelConcentration,
        recommendedConcentration: AgaroseGelConcentration,
        ladder: GelMarkerLadderPreset,
        recommendedLadderID: String,
        lanes: [SimulatedGelLane],
        warnings: [GelResolutionWarning],
        longestAmpliconBp: Int,
        suggestedExtensionNote: String,
        infoNotice: String? = nil
    ) {
        self.title = title
        self.concentration = concentration
        self.recommendedConcentration = recommendedConcentration
        self.ladder = ladder
        self.recommendedLadderID = recommendedLadderID
        self.lanes = lanes
        self.warnings = warnings
        self.longestAmpliconBp = longestAmpliconBp
        self.suggestedExtensionNote = suggestedExtensionNote
        self.infoNotice = infoNotice
    }

    /// 是否存在可用于渲染的非 Marker 条带
    public var hasSampleBands: Bool {
        lanes.contains { !$0.isMarker && !$0.bands.isEmpty }
    }

    /// 导出全部泳道条带预测表 CSV
    public func exportCSV() -> String {
        var lines = [
            "# Labworker Homologous Recombination Agarose Gel Simulation",
            "# Gel_Concentration: \(concentration.rawValue), Ladder: \(ladder.name)",
            "Lane_Index,Lane_Name,Role,Size_bp,Normalized_Migration_Y,Detail"
        ]
        for lane in lanes {
            for band in lane.bands.sorted(by: { $0.sizeBp > $1.sizeBp }) {
                let escapedDetail = band.detail.replacingOccurrences(of: "\"", with: "\"\"")
                lines.append(
                    "\(lane.index),\"\(lane.fullTitle)\",\"\(band.role.roleTitle)\",\(band.sizeBp),\(String(format: "%.4f", band.yFraction)),\"\(escapedDetail)\""
                )
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 3. 同源重组扩增电泳片段模拟核心引擎

public enum HomologousPCRGelSimulator {
    /// 全部可用于琼脂糖电泳模拟的 DNA Marker 预设
    public static var availableDNALadders: [GelMarkerLadderPreset] {
        GelMarkerLadderPreset.builtinPresets.filter { $0.kind == .dna }
    }

    /// 根据最大预期条带选择量程覆盖最佳的 DNA Marker
    public static func recommendedLadder(forMaxSizeBp maxBp: Int) -> GelMarkerLadderPreset {
        let dnaLadders = availableDNALadders
        if maxBp <= 1900, let dl2k = dnaLadders.first(where: { $0.id == "dl2000" }) {
            return dl2k
        }
        if maxBp <= 4900, let dl5k = dnaLadders.first(where: { $0.id == "dl5000" }) {
            return dl5k
        }
        return dnaLadders.first(where: { $0.id == "neb1kbplus" })
            ?? dnaLadders.first
            ?? GelMarkerLadderPreset.builtinPresets[0]
    }

    public static func resolveLadder(
        preferredID: String?,
        forMaxSizeBp maxBp: Int
    ) -> (selected: GelMarkerLadderPreset, recommendedID: String) {
        let rec = recommendedLadder(forMaxSizeBp: maxBp)
        if let pid = preferredID,
           let matched = availableDNALadders.first(where: { $0.id == pid }) {
            return (matched, rec.id)
        }
        return (rec, rec.id)
    }

    // MARK: 3.1 单片段无缝克隆模拟

    /// 计算单片段无缝克隆 PCR 产物及线性化载体在琼脂糖凝胶中的预期泳道与条带分布
    public static func simulateSingleFragment(
        rawVectorLengthBp: Int,
        effectiveVectorBackboneLengthBp: Int,
        deletedVectorBp: Int,
        linearizationMode: SingleFragmentViewModel.Mode,
        cleanInsertCoreLengthBp: Int,
        extra5LengthBp: Int = 0,
        extra3LengthBp: Int = 0,
        homologyLength: Int = 20,
        insertGeneName: String = "TargetGene",
        includeVectorPCRPrimers: Bool = false,
        primers: [PrimerItem] = [],
        omittedShortVectorBp: Int = 0,
        concentrationOverride: AgaroseGelConcentration? = nil,
        ladderIDOverride: String? = nil,
        includeMixControlLane: Bool = true
    ) -> HomologousPCRGelSimulationResult {
        let geneLabel = cleanLaneTitle(insertGeneName, fallback: "Insert")
        let armLen = max(0, homologyLength)
        let effCore = max(0, cleanInsertCoreLengthBp)
        let effInsertNoArms = effCore + max(0, extra5LengthBp) + max(0, extra3LengthBp)

        // 严格对齐 HomologyArmDesigner 产出的实测引物 overhang 长度，无已设计引物时按同源臂+附加碱基实时预测
        let (fOverhangLen, rOverhangLen): (Int, Int) = {
            if primers.count >= 2 {
                let fOv = primers[0].homologyArm.count + (primers[0].enzymeSite?.count ?? 0)
                let rOv = primers[1].homologyArm.count + (primers[1].enzymeSite?.count ?? 0)
                if fOv > 0 || rOv > 0 {
                    return (fOv, rOv)
                }
            }
            return (armLen + max(0, extra5LengthBp), armLen + max(0, extra3LengthBp))
        }()

        // 注：若已设计引物，primers[0/1].enzymeSite 已经包含 extra5/extra3；无引物时 effInsertNoArms 已含 extra5/extra3
        let insertAmpliconBp: Int = {
            guard effCore > 0 else { return 0 }
            if primers.count >= 2, (primers[0].homologyArm.count + primers[1].homologyArm.count) > 0 {
                return effCore + fOverhangLen + rOverhangLen
            }
            return effInsertNoArms + 2 * armLen
        }()

        let validVectorBp = effectiveVectorBackboneLengthBp > 0 ? effectiveVectorBackboneLengthBp : 0
        let excisedBp = (linearizationMode == .double && deletedVectorBp >= 50 && rawVectorLengthBp > validVectorBp)
            ? deletedVectorBp
            : 0

        var allSizes: [Int] = []
        if validVectorBp > 0 { allSizes.append(validVectorBp) }
        if excisedBp > 0 { allSizes.append(excisedBp) }
        if insertAmpliconBp > 0 { allSizes.append(insertAmpliconBp) }

        let recConc = AgaroseGelConcentration.recommendedConcentration(forSizesBp: allSizes)
        let conc = concentrationOverride ?? recConc
        let maxBp = allSizes.max() ?? 2000
        let ladderResolved = resolveLadder(preferredID: ladderIDOverride, forMaxSizeBp: maxBp)

        var lanes: [SimulatedGelLane] = [
            makeMarkerLane(preset: ladderResolved.selected, concentration: conc)
        ]

        var vecLaneBands: [SimulatedGelBand] = []
        if validVectorBp > 0 {
            let vecSubtitle: String = {
                switch linearizationMode {
                case .pcr:
                    return L10n.t(includeVectorPCRPrimers ? "反向 PCR 线性化载体" : "线性化载体骨架")
                case .single:
                    return L10n.t("单酶切线性化载体")
                case .double:
                    return deletedVectorBp >= 50
                        ? L10n.tr("双酶切骨架（另切下 \(deletedVectorBp) bp 片段）", "Double-Digest Backbone (excises \(deletedVectorBp) bp)")
                        : L10n.t("双酶切线性化载体")
                }
            }()
            vecLaneBands.append(
                SimulatedGelBand(
                    id: "vec-backbone-\(validVectorBp)",
                    sizeBp: validVectorBp,
                    yFraction: conc.migrationY(sizeBp: validVectorBp),
                    role: .linearVector,
                    relativeBrightness: 0.94,
                    label: "\(validVectorBp) bp",
                    detail: vecSubtitle
                )
            )
            if excisedBp > 0 {
                vecLaneBands.append(
                    SimulatedGelBand(
                        id: "vec-excised-\(excisedBp)",
                        sizeBp: excisedBp,
                        yFraction: conc.migrationY(sizeBp: excisedBp),
                        role: .excisedDropout,
                        relativeBrightness: 0.62,
                        label: "\(excisedBp) bp",
                        detail: L10n.tr("双酶切切落旧序列（胶回收时需避开此带，仅回收 \(validVectorBp) bp 主骨架）", "Excised stuffer fragment (avoid during gel extraction; recover \(validVectorBp) bp backbone)")
                    )
                )
            }
            lanes.append(
                SimulatedGelLane(
                    id: "lane-vector",
                    index: lanes.count + 1,
                    shortLabel: L10n.t(linearizationMode == .pcr ? "载体PCR" : "酶切载体"),
                    fullTitle: vecSubtitle,
                    subtitle: validVectorBp > 0 ? "\(validVectorBp) bp" : "",
                    bands: vecLaneBands
                )
            )
        }

        var insertBand: SimulatedGelBand? = nil
        if insertAmpliconBp > 0 {
            let overTotal = insertAmpliconBp - effCore
            let detailStr = L10n.tr("模板 \(effCore) bp + 5'/3' 同源臂及附加接头 \(overTotal) bp = \(insertAmpliconBp) bp", "Template \(effCore) bp + 5'/3' arms/linkers \(overTotal) bp = \(insertAmpliconBp) bp")
            let band = SimulatedGelBand(
                id: "insert-pcr-\(insertAmpliconBp)",
                sizeBp: insertAmpliconBp,
                yFraction: conc.migrationY(sizeBp: insertAmpliconBp),
                role: .pcrAmplicon,
                relativeBrightness: 0.98,
                label: "\(insertAmpliconBp) bp",
                detail: detailStr
            )
            insertBand = band
            lanes.append(
                SimulatedGelLane(
                    id: "lane-insert",
                    index: lanes.count + 1,
                    shortLabel: geneLabel.count <= 8 ? geneLabel : L10n.t("目的PCR"),
                    fullTitle: L10n.tr("\(geneLabel) 同源重组 PCR 产物", "\(geneLabel) Homologous Recombination PCR Amplicon"),
                    subtitle: "\(insertAmpliconBp) bp",
                    bands: [band]
                )
            )
        }

        if includeMixControlLane, validVectorBp > 0, let insB = insertBand {
            var mixBands = vecLaneBands
            mixBands.append(
                SimulatedGelBand(
                    id: "mix-\(insB.id)",
                    sizeBp: insB.sizeBp,
                    yFraction: insB.yFraction,
                    role: insB.role,
                    relativeBrightness: 0.92,
                    label: insB.label,
                    detail: L10n.tr("同泳道共迁移对照：\(insB.detail)", "Co-migration control: \(insB.detail)")
                )
            )
            lanes.append(
                SimulatedGelLane(
                    id: "lane-mix",
                    index: lanes.count + 1,
                    shortLabel: L10n.t("混合对照"),
                    fullTitle: L10n.t("载体 + 插入产物同泳道对照"),
                    subtitle: L10n.t("切胶分离检查"),
                    isMixedControl: true,
                    bands: mixBands.sorted { $0.sizeBp > $1.sizeBp }
                )
            )
        }

        let warnings = detectResolutionWarnings(
            lanes: lanes,
            currentConcentration: conc,
            ladder: ladderResolved.selected,
            extraSizesToCompare: allSizes
        )

        let longestPCR = linearizationMode == .pcr && includeVectorPCRPrimers
            ? max(validVectorBp, insertAmpliconBp)
            : insertAmpliconBp
        let shortNotice: String? = (validVectorBp == 0 && omittedShortVectorBp > 0)
            ? L10n.tr("当前仅输入 \(omittedShortVectorBp) bp 侧翼同源接头片段（未载入完整载体），仅模拟插入基因 PCR 条带；载入 .dna 或 ≥300 bp 载体后自动显示线性化载体泳道。", "Only \(omittedShortVectorBp) bp flanking junctions entered; simulating insert PCR only. Load .dna or vector >= 300 bp to show vector lane.")
            : nil

        return HomologousPCRGelSimulationResult(
            title: L10n.t("单片段同源重组 PCR 模拟电泳"),
            concentration: conc,
            recommendedConcentration: recConc,
            ladder: ladderResolved.selected,
            recommendedLadderID: ladderResolved.recommendedID,
            lanes: lanes,
            warnings: warnings,
            longestAmpliconBp: longestPCR,
            suggestedExtensionNote: makeExtensionHint(longestBp: longestPCR),
            infoNotice: shortNotice
        )
    }

    // MARK: 3.2 多片段无缝克隆模拟

    /// 计算多片段 Gibson/In-Fusion 同源组装各独立 PCR 扩增子及载体骨架的凝胶电泳模拟图谱
    public static func simulateMultiFragment(
        effectiveVectorBackboneLengthBp: Int,
        deletedVectorBp: Int,
        rawVectorLengthBp: Int,
        fragments: [String],
        fragmentExtra5Bases: [Int: String] = [:],
        terminalExtra3Bases: String = "",
        homologyLength: Int = 20,
        primers: [PrimerItem] = [],
        omittedShortVectorBp: Int = 0,
        concentrationOverride: AgaroseGelConcentration? = nil,
        ladderIDOverride: String? = nil,
        includeMixControlLane: Bool = true
    ) -> HomologousPCRGelSimulationResult {
        let validFrags = fragments.map { BioSequence.clean($0) }.filter { $0.count >= 50 }
        let fragCount = validFrags.count
        let armLen = max(0, homologyLength)
        let validVectorBp = effectiveVectorBackboneLengthBp > 0 ? effectiveVectorBackboneLengthBp : 0
        let excisedBp = (deletedVectorBp >= 50 && rawVectorLengthBp > validVectorBp) ? deletedVectorBp : 0

        var fragAmplicons: [(index: Int, coreBp: Int, ampliconBp: Int, overhangNote: String)] = []
        for i in 0..<fragCount {
            let coreBp = validFrags[i].count
            let ex5 = BioSequence.clean(fragmentExtra5Bases[i] ?? "").count
            let ex3 = (i == fragCount - 1) ? BioSequence.clean(terminalExtra3Bases).count : 0

            let fIdx = i * 2
            let rIdx = i * 2 + 1
            let fOv: Int
            let rOv: Int
            if primers.indices.contains(fIdx) && primers.indices.contains(rIdx) {
                fOv = primers[fIdx].homologyArm.count + (primers[fIdx].enzymeSite?.count ?? 0)
                rOv = primers[rIdx].homologyArm.count + (primers[rIdx].enzymeSite?.count ?? 0)
            } else {
                // 严格对齐 HomologyArmDesigner.designMultiFragmentClone：
                // 除最后一个片段同时带 5'+3' 臂外，其余片段仅在 5' 端带前接同源臂 (+extra5)
                fOv = armLen + ex5
                rOv = (i == fragCount - 1) ? (armLen + ex3) : 0
            }
            let ampBp = coreBp + fOv + rOv
            let note = rOv > 0
                ? L10n.tr("模板 \(coreBp) bp + 5'接头 \(fOv) bp + 3'接头 \(rOv) bp = \(ampBp) bp", "Template \(coreBp) bp + 5' \(fOv) bp + 3' \(rOv) bp = \(ampBp) bp")
                : L10n.tr("模板 \(coreBp) bp + 5'单端同源臂 \(fOv) bp = \(ampBp) bp", "Template \(coreBp) bp + 5' arm \(fOv) bp = \(ampBp) bp")
            fragAmplicons.append((i, coreBp, ampBp, note))
        }

        var allSizes: [Int] = []
        if validVectorBp > 0 { allSizes.append(validVectorBp) }
        if excisedBp > 0 { allSizes.append(excisedBp) }
        allSizes.append(contentsOf: fragAmplicons.map(\.ampliconBp))

        let recConc = AgaroseGelConcentration.recommendedConcentration(forSizesBp: allSizes)
        let conc = concentrationOverride ?? recConc
        let maxBp = allSizes.max() ?? 2000
        let ladderResolved = resolveLadder(preferredID: ladderIDOverride, forMaxSizeBp: maxBp)

        var lanes: [SimulatedGelLane] = [
            makeMarkerLane(preset: ladderResolved.selected, concentration: conc)
        ]

        var vectorBand: SimulatedGelBand? = nil
        if validVectorBp > 0 {
            var vecBands = [
                SimulatedGelBand(
                    id: "multi-vec-\(validVectorBp)",
                    sizeBp: validVectorBp,
                    yFraction: conc.migrationY(sizeBp: validVectorBp),
                    role: .linearVector,
                    relativeBrightness: 0.94,
                    label: "\(validVectorBp) bp",
                    detail: L10n.tr("线性化载体骨架 (\(validVectorBp) bp)", "Linearized vector backbone (\(validVectorBp) bp)")
                )
            ]
            vectorBand = vecBands[0]
            if excisedBp > 0 {
                vecBands.append(
                    SimulatedGelBand(
                        id: "multi-vec-excised-\(excisedBp)",
                        sizeBp: excisedBp,
                        yFraction: conc.migrationY(sizeBp: excisedBp),
                        role: .excisedDropout,
                        relativeBrightness: 0.62,
                        label: "\(excisedBp) bp",
                        detail: L10n.tr("载体切除旧序列 (\(excisedBp) bp)", "Excised vector stuffer (\(excisedBp) bp)")
                    )
                )
            }
            lanes.append(
                SimulatedGelLane(
                    id: "multi-lane-vec",
                    index: lanes.count + 1,
                    shortLabel: L10n.t("载体"),
                    fullTitle: L10n.t("线性化载体"),
                    subtitle: "\(validVectorBp) bp",
                    bands: vecBands
                )
            )
        }

        var fragBands: [SimulatedGelBand] = []
        for item in fragAmplicons {
            let b = SimulatedGelBand(
                id: "multi-frag-\(item.index + 1)",
                sizeBp: item.ampliconBp,
                yFraction: conc.migrationY(sizeBp: item.ampliconBp),
                role: .pcrAmplicon,
                relativeBrightness: 0.96,
                label: "\(item.ampliconBp) bp",
                detail: L10n.tr("片段 \(item.index + 1): \(item.overhangNote)", "Fragment \(item.index + 1): \(item.overhangNote)")
            )
            fragBands.append(b)
            lanes.append(
                SimulatedGelLane(
                    id: "multi-lane-f\(item.index + 1)",
                    index: lanes.count + 1,
                    shortLabel: "F\(item.index + 1)",
                    fullTitle: L10n.tr("片段 \(item.index + 1) PCR 扩增产物", "Fragment \(item.index + 1) PCR Amplicon"),
                    subtitle: "\(item.ampliconBp) bp",
                    bands: [b]
                )
            )
        }

        if includeMixControlLane, (fragBands.count >= 2 || (vectorBand != nil && !fragBands.isEmpty)) {
            var mixBands: [SimulatedGelBand] = []
            if let vb = vectorBand { mixBands.append(vb) }
            mixBands.append(contentsOf: fragBands.map {
                SimulatedGelBand(
                    id: "mix-\($0.id)",
                    sizeBp: $0.sizeBp,
                    yFraction: $0.yFraction,
                    role: $0.role,
                    relativeBrightness: 0.88,
                    label: $0.label,
                    detail: L10n.tr("同泳道组装混合参考 · \($0.detail)", "Co-migration mix reference · \($0.detail)")
                )
            })
            lanes.append(
                SimulatedGelLane(
                    id: "multi-lane-mix",
                    index: lanes.count + 1,
                    shortLabel: L10n.t("混合"),
                    fullTitle: L10n.t("组装体系全组分共电泳对照"),
                    subtitle: L10n.tr("\(mixBands.count) 条带", "\(mixBands.count) bands"),
                    isMixedControl: true,
                    bands: mixBands.sorted { $0.sizeBp > $1.sizeBp }
                )
            )
        }

        let warnings = detectResolutionWarnings(
            lanes: lanes,
            currentConcentration: conc,
            ladder: ladderResolved.selected,
            extraSizesToCompare: fragAmplicons.map(\.ampliconBp) + (validVectorBp > 0 ? [validVectorBp] : [])
        )
        let longestPCR = fragAmplicons.map(\.ampliconBp).max() ?? 0

        let shortNotice: String? = (validVectorBp == 0 && omittedShortVectorBp > 0)
            ? L10n.tr("当前仅输入 \(omittedShortVectorBp) bp 侧翼同源接头片段（未载入完整载体），仅模拟各插入片段 PCR 扩增条带；载入 .dna 或 ≥300 bp 载体后自动显示线性化载体泳道。", "Only \(omittedShortVectorBp) bp flanking junctions entered; simulating insert PCR lanes only. Load .dna or vector >= 300 bp to show vector lane.")
            : nil

        return HomologousPCRGelSimulationResult(
            title: L10n.t("多片段同源组装 PCR 模拟电泳"),
            concentration: conc,
            recommendedConcentration: recConc,
            ladder: ladderResolved.selected,
            recommendedLadderID: ladderResolved.recommendedID,
            lanes: lanes,
            warnings: warnings,
            longestAmpliconBp: longestPCR,
            suggestedExtensionNote: makeExtensionHint(longestBp: longestPCR),
            infoNotice: shortNotice
        )
    }

    // MARK: 3.3 片段删除（反向 PCR）模拟

    /// 计算质粒片段删除前后（原始亲本质粒线性参考 vs 反向 PCR 缺失扩增产物）迁移对比电泳图谱
    public static func simulateFragmentDeletion(
        parentalLengthBp: Int,
        deletedLengthBp: Int,
        homologyLength: Int = 18,
        primers: [PrimerItem] = [],
        concentrationOverride: AgaroseGelConcentration? = nil,
        ladderIDOverride: String? = nil,
        includeCompareLane: Bool = true
    ) -> HomologousPCRGelSimulationResult {
        let validParental = parentalLengthBp >= 100 ? parentalLengthBp : 0
        let clampedDel = max(0, min(deletedLengthBp, max(0, validParental - 40)))
        let coreRetained = max(0, validParental - clampedDel)
        let fArmLen: Int = {
            if let first = primers.first, !first.homologyArm.isEmpty {
                return first.homologyArm.count
            }
            return clampedDel > 0 ? min(homologyLength, max(15, coreRetained)) : homologyLength
        }()
        // 反向 PCR 删除时正向引物携带上游 fArm 同源臂 (rPrimer 为 0 overhang)
        let deletionAmpliconBp = (validParental > 0 && clampedDel > 0) ? (coreRetained + fArmLen) : 0

        var allSizes: [Int] = []
        if validParental > 0 { allSizes.append(validParental) }
        if deletionAmpliconBp > 0 { allSizes.append(deletionAmpliconBp) }

        let recConc = AgaroseGelConcentration.recommendedConcentration(forSizesBp: allSizes)
        let conc = concentrationOverride ?? recConc
        let maxBp = allSizes.max() ?? 5000
        let ladderResolved = resolveLadder(preferredID: ladderIDOverride, forMaxSizeBp: maxBp)

        var lanes: [SimulatedGelLane] = [
            makeMarkerLane(preset: ladderResolved.selected, concentration: conc)
        ]

        var parentBand: SimulatedGelBand? = nil
        var delBand: SimulatedGelBand? = nil

        if validParental > 0 {
            let pb = SimulatedGelBand(
                id: "del-parent-\(validParental)",
                sizeBp: validParental,
                yFraction: conc.migrationY(sizeBp: validParental),
                role: .parentalPlasmid,
                relativeBrightness: 0.86,
                label: "\(validParental) bp",
                detail: L10n.tr("删除前原始亲本模板线性质粒参比 (\(validParental) bp)", "Linearized parental plasmid reference before deletion (\(validParental) bp)")
            )
            parentBand = pb
            lanes.append(
                SimulatedGelLane(
                    id: "lane-parent",
                    index: lanes.count + 1,
                    shortLabel: L10n.t("原质粒"),
                    fullTitle: L10n.t("原始亲本质粒参比"),
                    subtitle: "\(validParental) bp",
                    bands: [pb]
                )
            )
        }

        if deletionAmpliconBp > 0 {
            let db = SimulatedGelBand(
                id: "del-amplicon-\(deletionAmpliconBp)",
                sizeBp: deletionAmpliconBp,
                yFraction: conc.migrationY(sizeBp: deletionAmpliconBp),
                role: .deletionAmplicon,
                relativeBrightness: 0.98,
                label: "\(deletionAmpliconBp) bp",
                detail: L10n.tr("保留骨架 \(coreRetained) bp + 5' 桥接同源臂 \(fArmLen) bp（较亲本净缩短 Δ\(validParental - deletionAmpliconBp) bp）", "Retained \(coreRetained) bp + 5' bridging arm \(fArmLen) bp (net -Δ\(validParental - deletionAmpliconBp) bp vs parental)")
            )
            delBand = db
            lanes.append(
                SimulatedGelLane(
                    id: "lane-del-pcr",
                    index: lanes.count + 1,
                    shortLabel: L10n.t("缺失PCR"),
                    fullTitle: L10n.t("反向 PCR 缺失扩增产物"),
                    subtitle: "Δ-\(clampedDel) bp",
                    bands: [db]
                )
            )
        }

        if includeCompareLane, let pb = parentBand, let db = delBand {
            lanes.append(
                SimulatedGelLane(
                    id: "lane-del-compare",
                    index: lanes.count + 1,
                    shortLabel: L10n.t("大小对比"),
                    fullTitle: L10n.t("亲本模板 vs 缺失产物同泳道对照"),
                    subtitle: L10n.t("差异辨识检查"),
                    isMixedControl: true,
                    bands: [
                        SimulatedGelBand(
                            id: "cmp-parent",
                            sizeBp: pb.sizeBp,
                            yFraction: pb.yFraction,
                            role: .parentalPlasmid,
                            relativeBrightness: 0.78,
                            label: pb.label,
                            detail: pb.detail
                        ),
                        SimulatedGelBand(
                            id: "cmp-del",
                            sizeBp: db.sizeBp,
                            yFraction: db.yFraction,
                            role: .deletionAmplicon,
                            relativeBrightness: 0.96,
                            label: db.label,
                            detail: db.detail
                        )
                    ]
                )
            )
        }

        let warnings = detectResolutionWarnings(
            lanes: lanes,
            currentConcentration: conc,
            ladder: ladderResolved.selected,
            extraSizesToCompare: allSizes
        )

        return HomologousPCRGelSimulationResult(
            title: L10n.t("片段删除反向 PCR 迁移对比模拟"),
            concentration: conc,
            recommendedConcentration: recConc,
            ladder: ladderResolved.selected,
            recommendedLadderID: ladderResolved.recommendedID,
            lanes: lanes,
            warnings: warnings,
            longestAmpliconBp: deletionAmpliconBp,
            suggestedExtensionNote: makeExtensionHint(longestBp: deletionAmpliconBp)
        )
    }

    // MARK: 3.4 入门克隆模拟 (pCE2-TA/Blunt + URS/DRS PCR)

    public static func simulateEntryClone(
        cleanInsertLengthBp: Int,
        hasEnzymes: Bool,
        enzyme5: RestrictionEnzyme?,
        enzyme3: RestrictionEnzyme?,
        primerF: PrimerItem?,
        primerR: PrimerItem?,
        vectorLengthBp: Int = 3957,
        concentrationOverride: AgaroseGelConcentration? = nil,
        ladderIDOverride: String? = nil,
        includeMixControlLane: Bool = true
    ) -> HomologousPCRGelSimulationResult {
        let fOv = primerF.map { $0.homologyArm.count + ($0.enzymeSite?.count ?? 0) }
            ?? (15 + (hasEnzymes ? (enzyme5?.site.count ?? 0) : 0))
        let rOv = primerR.map { $0.homologyArm.count + ($0.enzymeSite?.count ?? 0) }
            ?? (15 + (hasEnzymes ? (enzyme3?.site.count ?? 0) : 0))
        let insertAmpliconBp = cleanInsertLengthBp >= 50 ? (cleanInsertLengthBp + fOv + rOv) : 0

        var allSizes = [vectorLengthBp]
        if insertAmpliconBp > 0 { allSizes.append(insertAmpliconBp) }

        let recConc = AgaroseGelConcentration.recommendedConcentration(forSizesBp: allSizes)
        let conc = concentrationOverride ?? recConc
        let ladderResolved = resolveLadder(preferredID: ladderIDOverride, forMaxSizeBp: allSizes.max() ?? vectorLengthBp)

        var lanes: [SimulatedGelLane] = [
            makeMarkerLane(preset: ladderResolved.selected, concentration: conc)
        ]

        let vecBand = SimulatedGelBand(
            id: "entry-vec-\(vectorLengthBp)",
            sizeBp: vectorLengthBp,
            yFraction: conc.migrationY(sizeBp: vectorLengthBp),
            role: .linearVector,
            relativeBrightness: 0.90,
            label: "\(vectorLengthBp) bp",
            detail: L10n.tr("pCE2-TA/Blunt 预线性化入门载体 (\(vectorLengthBp) bp)", "pCE2-TA/Blunt pre-linearized entry vector (\(vectorLengthBp) bp)")
        )
        lanes.append(
            SimulatedGelLane(
                id: "entry-lane-vec",
                index: 2,
                shortLabel: "pCE2",
                fullTitle: L10n.t("pCE2-TA/Blunt 线性载体"),
                subtitle: "\(vectorLengthBp) bp",
                bands: [vecBand]
            )
        )

        var insertBand: SimulatedGelBand? = nil
        if insertAmpliconBp > 0 {
            let enzNote = hasEnzymes
                ? L10n.tr(" + \(enzyme5?.name ?? "5'酶")/\(enzyme3?.name ?? "3'酶")位点", " + \(enzyme5?.name ?? "5' Enz")/\(enzyme3?.name ?? "3' Enz") sites")
                : ""
            let ib = SimulatedGelBand(
                id: "entry-insert-\(insertAmpliconBp)",
                sizeBp: insertAmpliconBp,
                yFraction: conc.migrationY(sizeBp: insertAmpliconBp),
                role: .pcrAmplicon,
                relativeBrightness: 0.98,
                label: "\(insertAmpliconBp) bp",
                detail: L10n.tr("目的基因 \(cleanInsertLengthBp) bp + 5' URS/3' DRS 同源臂(\(fOv)+\(rOv) bp)\(enzNote)", "Insert \(cleanInsertLengthBp) bp + 5' URS/3' DRS arms (\(fOv)+\(rOv) bp)\(enzNote)")
            )
            insertBand = ib
            lanes.append(
                SimulatedGelLane(
                    id: "entry-lane-insert",
                    index: lanes.count + 1,
                    shortLabel: L10n.t("目的PCR"),
                    fullTitle: L10n.t("入门克隆 PCR 扩增产物"),
                    subtitle: "\(insertAmpliconBp) bp",
                    bands: [ib]
                )
            )
        }

        if includeMixControlLane, let ib = insertBand {
            lanes.append(
                SimulatedGelLane(
                    id: "entry-lane-mix",
                    index: lanes.count + 1,
                    shortLabel: L10n.t("混合对照"),
                    fullTitle: L10n.t("pCE2 载体 + 目的 PCR 共电泳对照"),
                    subtitle: L10n.t("重组大小对比"),
                    isMixedControl: true,
                    bands: [vecBand, ib].sorted { $0.sizeBp > $1.sizeBp }
                )
            )
        }

        let warnings = detectResolutionWarnings(
            lanes: lanes,
            currentConcentration: conc,
            ladder: ladderResolved.selected,
            extraSizesToCompare: allSizes
        )

        return HomologousPCRGelSimulationResult(
            title: L10n.t("入门克隆 PCR 扩增模拟电泳"),
            concentration: conc,
            recommendedConcentration: recConc,
            ladder: ladderResolved.selected,
            recommendedLadderID: ladderResolved.recommendedID,
            lanes: lanes,
            warnings: warnings,
            longestAmpliconBp: insertAmpliconBp,
            suggestedExtensionNote: makeExtensionHint(longestBp: insertAmpliconBp)
        )
    }

    // MARK: 3.5 内部辅助工具

    private static func makeMarkerLane(
        preset: GelMarkerLadderPreset,
        concentration: AgaroseGelConcentration
    ) -> SimulatedGelLane {
        let bands = preset.sizes.map { sz in
            let isHL = preset.highlightSizes.contains(sz)
            let bp = Int(sz.rounded())
            return SimulatedGelBand(
                id: "marker-\(preset.id)-\(bp)",
                sizeBp: bp,
                yFraction: concentration.migrationY(sizeBp: sz),
                role: .marker,
                relativeBrightness: isHL ? 1.0 : 0.64,
                label: formatShortBp(bp),
                detail: isHL ? L10n.tr("\(preset.name) · 加亮指示带 (\(bp) bp)", "\(preset.name) · Bright reference band (\(bp) bp)") : "\(preset.name) (\(bp) bp)"
            )
        }
        return SimulatedGelLane(
            id: "lane-marker",
            index: 1,
            shortLabel: "M",
            fullTitle: preset.name,
            subtitle: "DNA Marker",
            isMarker: true,
            bands: bands
        )
    }

    /// 检测条带超出 Marker 量程或条带距离过近可能共迁移的问题
    private static func detectResolutionWarnings(
        lanes: [SimulatedGelLane],
        currentConcentration: AgaroseGelConcentration,
        ladder: GelMarkerLadderPreset,
        extraSizesToCompare: [Int]
    ) -> [GelResolutionWarning] {
        var warnings: [GelResolutionWarning] = []
        let ladderMaxBp = Int((ladder.sizes.max() ?? 2000).rounded())
        let maxBandBp = extraSizesToCompare.max() ?? 0

        if maxBandBp > ladderMaxBp, ladder.id != "neb1kbplus" {
            warnings.append(
                GelResolutionWarning(
                    id: "warn-ladder-overflow",
                    severity: .warning,
                    message: L10n.tr("最大条带 (\(maxBandBp) bp) 超出当前 Marker 上限 (\(ladderMaxBp) bp)，建议切换至 NEB 1 kb Plus 准确判读条带大小。", "Largest band (\(maxBandBp) bp) exceeds Marker upper limit (\(ladderMaxBp) bp); switch to NEB 1 kb Plus."),
                    suggestedConcentration: nil,
                    suggestedLadderID: "neb1kbplus"
                )
            )
        }

        // 检查各泳道内任意两条不同条带的实际胶迁移间距是否过近 (|dy| < 0.032)
        for lane in lanes where !lane.isMarker && lane.bands.count >= 2 {
            let sorted = lane.bands.sorted { $0.sizeBp > $1.sizeBp }
            for idx in 0..<(sorted.count - 1) {
                let b1 = sorted[idx]
                let b2 = sorted[idx + 1]
                let dy = abs(b1.yFraction - b2.yFraction)
                if b1.sizeBp == b2.sizeBp {
                    warnings.append(
                        GelResolutionWarning(
                            id: "warn-overlap-\(lane.id)-\(b1.sizeBp)-\(idx)",
                            severity: .warning,
                            message: L10n.tr("「\(lane.fullTitle)」中存在两条长度完全相同 (\(b1.sizeBp) bp) 的条带，混合点样会完全重合，请分别单管 PCR 并在独立泳道上样验证。", "\"\(lane.fullTitle)\" contains two identical-length bands (\(b1.sizeBp) bp); amplify separately and load in distinct lanes."),
                            suggestedConcentration: nil,
                            suggestedLadderID: nil
                        )
                    )
                } else if dy < 0.032 {
                    let bestConc = AgaroseGelConcentration.allCases.max { lhs, rhs in
                        abs(lhs.migrationY(sizeBp: b1.sizeBp) - lhs.migrationY(sizeBp: b2.sizeBp))
                            < abs(rhs.migrationY(sizeBp: b1.sizeBp) - rhs.migrationY(sizeBp: b2.sizeBp))
                    }
                    let suggest = (bestConc != currentConcentration) ? bestConc : nil
                    let concHint = suggest.map { L10n.tr("建议改用 \($0.rawValue) 琼脂糖凝胶以提高分离度。", "Switch to \($0.rawValue) agarose gel for better separation.") } ?? L10n.t("条带尺寸极为接近，建议单管独立 PCR 并在不同泳道点样。")
                    warnings.append(
                        GelResolutionWarning(
                            id: "warn-comigrate-\(lane.id)-\(b1.sizeBp)-\(b2.sizeBp)-\(idx)",
                            severity: .warning,
                            message: L10n.tr("「\(lane.fullTitle)」中 \(b1.sizeBp) bp 与 \(b2.sizeBp) bp 条带在 \(currentConcentration.rawValue) 胶中迁移接近，\(concHint)", "In \"\(lane.fullTitle)\", \(b1.sizeBp) bp and \(b2.sizeBp) bp migrate closely on \(currentConcentration.rawValue) gel; \(concHint)"),
                            suggestedConcentration: suggest,
                            suggestedLadderID: nil
                        )
                    )
                }
            }
        }

        // 若泳道中含环状质粒对照，补充超螺旋 (cccDNA) / 开环 (ocDNA) / 线性拓扑迁移差异说明
        let hasCircularVector = lanes.contains { l in l.bands.contains { $0.role == .linearVector } }
        if hasCircularVector {
            warnings.append(
                GelResolutionWarning(
                    id: "info-plasmid-topology-ccc-oc",
                    severity: .info,
                    message: L10n.t("拓扑迁移提示：未酶切环状质粒在琼脂糖胶上以超螺旋 (cccDNA，表观迁移率约为线性长度 0.65–0.75×) 与开环切刻态 (ocDNA，迁移慢于线性态) 双带呈现；仅线性化载体与线性 DNA Marker 具有直接长度可比性。"),
                    suggestedConcentration: nil,
                    suggestedLadderID: nil
                )
            )
        }

        return warnings
    }

    private static func makeExtensionHint(longestBp: Int) -> String {
        guard longestBp > 0 else { return L10n.t("输入序列并选择同源臂后自动评估") }
        let kb = Double(longestBp) / 1000.0
        let lowSec = max(10, Int((kb * 15.0).rounded()))
        let highSec = max(15, Int((kb * 30.0).rounded()))
        return L10n.tr("最长扩增 \(longestBp) bp (\(String(format: "%.2f", kb)) kb) · 参考延伸时间 ~\(lowSec)–\(highSec) s (按 15–30 s/kb 高保真酶估算)", "Max amplicon \(longestBp) bp (\(String(format: "%.2f", kb)) kb) · Est. extension ~\(lowSec)–\(highSec) s (15–30 s/kb Hi-Fi Pol)")
    }

    private static func cleanLaneTitle(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func formatShortBp(_ bp: Int) -> String {
        if bp >= 1000 && bp % 500 == 0 {
            let kb = Double(bp) / 1000.0
            if kb.rounded() == kb {
                return "\(Int(kb))k"
            }
            return String(format: "%.1fk", kb)
        }
        return "\(bp)"
    }
}
