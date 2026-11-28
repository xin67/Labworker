import Foundation

// MARK: - 1. 蛋白质理化性质、三维结构、DSSP、LIGSITE 口袋、Vina 对接盒子与结构体检模型

/// 等电点与净电荷计算 pKa 量表（对标 ExPASy ProtParam Bjellqvist 1993/1994、EMBOSS 与 Lehninger）
public enum ProteinPKaScale: String, Codable, CaseIterable, Sendable, Identifiable {
    case bjellqvist = "bjellqvist"
    case emboss = "emboss"
    case lehninger = "lehninger"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .bjellqvist: return "Bjellqvist (ExPASy)"
        case .emboss:     return "EMBOSS"
        case .lehninger:  return "Lehninger"
        }
    }
}

/// 温度因子 / 置信度列语义（严格区分 AlphaFold pLDDT 与 X-ray/Cryo-EM B-factor）
public enum TemperatureFactorMetric: String, Codable, Sendable {
    case pLDDT = "pLDDT"
    case bFactor = "B-factor"
    case syntheticHeuristic = "Synthetic"

    public var displayTitle: String {
        switch self {
        case .pLDDT:              return "pLDDT (0–100)"
        case .bFactor:            return "B-factor (Å²)"
        case .syntheticHeuristic: return L10n.t("虚拟几何置信度 (教学模型)")
        }
    }
}

public struct ProteinEnvironmentParams: Codable, Equatable, Sendable {
    public var ph: Double
    public var temperatureK: Double
    public var pressureBar: Double
    public var ionicStrengthM: Double
    public var pkaScale: ProteinPKaScale

    public init(
        ph: Double = 7.0,
        temperatureK: Double = 310.0,
        pressureBar: Double = 1.0,
        ionicStrengthM: Double = 0.15,
        pkaScale: ProteinPKaScale = .bjellqvist
    ) {
        self.ph = ph
        self.temperatureK = temperatureK
        self.pressureBar = pressureBar
        self.ionicStrengthM = ionicStrengthM
        self.pkaScale = pkaScale
    }
}

public enum ProteinSecondaryType: String, Codable, Sendable {
    case helix = "H"
    case sheet = "E"
    case coil  = "C"

    public var title: String {
        switch self {
        case .helix: return L10n.tr("α-螺旋 (Helix)", "α-Helix")
        case .sheet: return L10n.tr("β-折叠 (Sheet)", "β-Sheet")
        case .coil:  return L10n.tr("无规卷曲 (Coil)", "Random Coil")
        }
    }
}

public struct ProteinVec3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct ProteinLigandInstance: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(resName):\(chainID):\(resSeq)\(insertionCode)" }
    public let resName: String
    public let chainID: String
    public let resSeq: Int
    public let insertionCode: String
    public let heavyAtomCount: Int
    public let centerX: Double
    public let centerY: Double
    public let centerZ: Double
}

public struct ProteinResidue3D: Identifiable, Codable, Equatable, Sendable {
    public var id: Int { index }
    /// 1-based 顺序残基序号
    public let index: Int
    public let oneLetter: String
    public let threeLetter: String
    /// 链标识符与原始 PDB/mmCIF 残基编号、插入码
    public let chainID: String
    public let resSeq: Int
    public let insertionCode: String
    /// Cα 空间坐标 (Å)
    public var x: Double
    public var y: Double
    public var z: Double
    /// 完整主链原子坐标（用于精确 φ/ψ/ω 与 Kabsch–Sander DSSP）
    public var backboneN: ProteinVec3?
    public var backboneC: ProteinVec3?
    public var backboneO: ProteinVec3?
    /// 原始温度因子列值：AlphaFold/Boltz 为 pLDDT (0..100)，晶体/电镜为 B-factor (Å²)
    public var plddt: Double
    /// 原始未钳制温度因子/置信度值
    public var temperatureFactor: Double
    /// 二级结构类型
    public var secondary: ProteinSecondaryType
    /// Kyte-Doolittle 疏水值 (-4.5 .. +4.5)
    public var hydropathy: Double
    /// Ramachandran 二面角与肽键 ω 角 (度，-180..180)
    public var phi: Double?
    public var psi: Double?
    public var omega: Double?
    /// 估算相对溶剂可及表面积 (0..1，越小越埋藏于疏水核心)
    public var relativeSASA: Double?
    /// 是否位于结合口袋或疏水核心
    public var isPocketResidue: Bool

    public init(
        index: Int,
        oneLetter: String,
        threeLetter: String,
        chainID: String = "A",
        resSeq: Int? = nil,
        insertionCode: String = "",
        x: Double,
        y: Double,
        z: Double,
        backboneN: ProteinVec3? = nil,
        backboneC: ProteinVec3? = nil,
        backboneO: ProteinVec3? = nil,
        plddt: Double,
        temperatureFactor: Double? = nil,
        secondary: ProteinSecondaryType,
        hydropathy: Double,
        phi: Double? = nil,
        psi: Double? = nil,
        omega: Double? = nil,
        relativeSASA: Double? = nil,
        isPocketResidue: Bool = false
    ) {
        self.index = index
        self.oneLetter = oneLetter
        self.threeLetter = threeLetter
        self.chainID = chainID
        self.resSeq = resSeq ?? index
        self.insertionCode = insertionCode
        self.x = x
        self.y = y
        self.z = z
        self.backboneN = backboneN
        self.backboneC = backboneC
        self.backboneO = backboneO
        self.plddt = plddt
        self.temperatureFactor = temperatureFactor ?? plddt
        self.secondary = secondary
        self.hydropathy = hydropathy
        self.phi = phi
        self.psi = psi
        self.omega = omega
        self.relativeSASA = relativeSASA
        self.isPocketResidue = isPocketResidue
    }
}

public struct ProteinPocketInfo: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let centerX: Double
    public let centerY: Double
    public let centerZ: Double
    public let sizeX: Double
    public let sizeY: Double
    public let sizeZ: Double
    public let volumeA3: Double
    /// LIGSITE 综合评分 (0.45*包埋度 + 0.20*体积 + 0.15*球形紧密度 + 0.10*深度 + 0.10*疏水性)
    public let druggabilityScore: Double
    /// 平均 P-S-P 七方向包埋比例 (0..1)
    public let enclosureRatio: Double
    /// 几何球形紧密度 Ψ = π^(1/3)(6V)^(2/3) / A_surf (0..1)
    public let compactness: Double
    /// 平均表面埋藏深度 (Å)
    public let meanDepthA: Double
    public let hydrophobicRatio: Double
    public let netChargeAtPh: Double
    public let evidenceSource: String
    public let residueIndices: [Int]

    public init(
        id: Int,
        name: String,
        centerX: Double,
        centerY: Double,
        centerZ: Double,
        sizeX: Double = 22.0,
        sizeY: Double = 22.0,
        sizeZ: Double = 22.0,
        volumeA3: Double,
        druggabilityScore: Double,
        enclosureRatio: Double = 0.72,
        compactness: Double = 0.72,
        meanDepthA: Double = 1.8,
        hydrophobicRatio: Double,
        netChargeAtPh: Double,
        evidenceSource: String = L10n.t("LIGSITE P-S-P 七方向扫描"),
        residueIndices: [Int]
    ) {
        self.id = id
        self.name = name
        self.centerX = centerX
        self.centerY = centerY
        self.centerZ = centerZ
        self.sizeX = sizeX
        self.sizeY = sizeY
        self.sizeZ = sizeZ
        self.volumeA3 = volumeA3
        self.druggabilityScore = druggabilityScore
        self.enclosureRatio = enclosureRatio
        self.compactness = compactness
        self.meanDepthA = meanDepthA
        self.hydrophobicRatio = hydrophobicRatio
        self.netChargeAtPh = netChargeAtPh
        self.evidenceSource = evidenceSource
        self.residueIndices = residueIndices
    }
}

/// 借鉴 DockFlowLab 的「证据优先」对接搜索盒子与柔性侧链 (`--flex`) 推荐模型
public struct ProteinDockingBoxRecommendation: Codable, Equatable, Sendable {
    public let sourceTitle: String
    public let sourceNote: String
    public let centerX: Double
    public let centerY: Double
    public let centerZ: Double
    public let sizeX: Double
    public let sizeY: Double
    public let sizeZ: Double
    public let volumeA3: Double
    public let recommendedExhaustiveness: Int
    /// 距离盒子中心 6–7.8 Å 内的可旋转侧链残基标签（供 Vina/Smina `--flex` 使用）
    public let recommendedFlexResidues: [String]
    public let runtimeEstimateNote: String

    /// 生成可直接用于 AutoDock Vina / Smina 的配置文件文本 (`vina_config.txt`)
    public var vinaConfigText: String {
        let flexLine = recommendedFlexResidues.isEmpty
            ? "# flex_residues = (rigid receptor mode)"
            : "# Recommended --flex sidechains (<= 6 Å): \(recommendedFlexResidues.joined(separator: ", "))"
        return """
        # AutoDock Vina / Smina Configuration (Generated by Labworker)
        # Box Source: \(sourceTitle) — \(sourceNote)
        receptor = receptor.pdbqt
        ligand = ligand.pdbqt

        center_x = \(String(format: "%.3f", centerX))
        center_y = \(String(format: "%.3f", centerY))
        center_z = \(String(format: "%.3f", centerZ))

        size_x = \(String(format: "%.1f", sizeX))
        size_y = \(String(format: "%.1f", sizeY))
        size_z = \(String(format: "%.1f", sizeZ))

        exhaustiveness = \(recommendedExhaustiveness)
        num_modes = 9
        energy_range = 3
        seed = 42
        \(flexLine)
        """
    }
}

/// 借鉴 DockFlowLab 的「结构体检与可信度卡」（所有降级可见、实验证据与几何启发式严格区分）
public struct ProteinStructureHealthCard: Codable, Equatable, Sendable {
    public let coordinateSource: String
    public let isExperimentalOrAlphaFoldPDB: Bool
    public let isSyntheticTeachingModel: Bool
    public let temperatureFactorMetric: TemperatureFactorMetric
    public let hasAllAtomBackbone: Bool
    public let chainIDs: [String]
    public let missingResidueGapCount: Int
    public let nonStandardResidues: [String]
    public let metalIons: [String]
    public let coCrystalLigands: [String]
    public let ligandInstances: [ProteinLigandInstance]
    public let pdbSiteResidues: [Int]
    public let hasAltLocWarning: Bool
    public let warnings: [String]
    public let credibilitySummary: String
}

public struct ProteinContactPair: Identifiable, Sendable {
    public var id: String { "\(resI)-\(resJ)" }
    public let resI: Int
    public let resJ: Int
    public let distanceA: Double
}

public struct ProteinBiophysicsReport: Sendable {
    public let sequence: String
    public let length: Int
    public let chainCount: Int
    public let molecularWeightDa: Double
    public let isoelectricPoint: Double
    public let pkaScale: ProteinPKaScale
    public let netChargeAtEnvPh: Double
    public let extinctionReduced: Int
    public let extinctionOxidized: Int
    public let abs01PctReduced: Double
    public let gravy: Double
    public let aliphaticIndex: Double
    public let instabilityIndex: Double
    public let isStable: Bool
    public let helixPct: Double
    public let sheetPct: Double
    public let coilPct: Double
    public let dsspComputed: Bool
    public let disorderPct: Double
    public let topIDPMeanScore: Double
    public let uverskyDisorderDistance: Double
    public let debyeLengthA: Double
    public let ionicStrengthNote: String
    public let radiusOfGyrationA: Double
    public let endToEndDistanceA: Double
    public let meanPlddt: Double
    public let meanTemperatureFactor: Double
    public let temperatureFactorMetric: TemperatureFactorMetric
    public let isSyntheticTeachingModel: Bool
    /// SPICE 五维折叠与动力学质量评分 (0..100)
    public let metricM1Packing: Double
    public let metricM2HBond: Double
    public let metricM3Ramachandran: Double
    public let metricM4Solvation: Double
    public let metricM5Electrostatics: Double
    public let compositeQScore: Double
    public let residues: [ProteinResidue3D]
    public let contacts: [ProteinContactPair]
    public let pockets: [ProteinPocketInfo]
    public let dockingBox: ProteinDockingBoxRecommendation
    public let healthCard: ProteinStructureHealthCard
    public let hydropathyProfile: [(index: Int, value: Double)]
}

public struct ProteinMutantEvaluation: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let mutationSpec: String
    public let mutatedSequence: String
    /// 预测自由能变化 ΔΔG (kcal/mol，负值表示稳定化倾向，正值表示去稳定化风险)
    public let ddgKcalMol: Double
    public let deltaGravy: Double
    public let deltaCharge: Double
    public let compositeScore: Double
    public let stabilityVerdict: String
    /// 模型语义标识（基于疏水性、位阻、脯氨酸罚分与 3D 埋藏度 rASA 的经验启发式初筛）
    public let modelType: String
    /// 野生型残基校验是否通过
    public let isValidWildType: Bool
    /// 校验失败或模型局限说明
    public let validationWarning: String?
    /// 埋藏区分类（core / surface / sequence_only）
    public let burialClass: String

    public init(
        id: String,
        mutationSpec: String,
        mutatedSequence: String,
        ddgKcalMol: Double,
        deltaGravy: Double,
        deltaCharge: Double,
        compositeScore: Double,
        stabilityVerdict: String,
        modelType: String = "empirical_heuristic",
        isValidWildType: Bool = true,
        validationWarning: String? = nil,
        burialClass: String = "sequence_only"
    ) {
        self.id = id
        self.mutationSpec = mutationSpec
        self.mutatedSequence = mutatedSequence
        self.ddgKcalMol = ddgKcalMol
        self.deltaGravy = deltaGravy
        self.deltaCharge = deltaCharge
        self.compositeScore = compositeScore
        self.stabilityVerdict = stabilityVerdict
        self.modelType = modelType
        self.isValidWildType = isValidWildType
        self.validationWarning = validationWarning
        self.burialClass = burialClass
    }
}

public struct ProteinPresetExample: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let subtitle: String
    public let sequence: String
}

// MARK: - 2. 蛋白质生物物理、DSSP、LIGSITE 连通分量口袋扫描、Vina 盒子决策与突变评估引擎

public enum ProteinBiophysicsEngine {

    /// 真实野生型基准序列（修正原 tp53_core 误填 EGFP 序列的错误，替换为 UniProt P04637 94–292 人类 TP53 核心 DNA 结合域）
    public static var builtinExamples: [ProteinPresetExample] { [
        ProteinPresetExample(
            id: "tp53_core",
            name: L10n.t("TP53 (人类肿瘤抑制蛋白核心 DNA 结合域)"),
            subtitle: L10n.t("199 aa · 免疫球蛋白样 β-三明治 DNA 结合域 (UniProt P04637: 94–292)"),
            sequence: "SSSVPSQKTYQGSYGFRLGFLHSGTAKSVTCTYSPALNKMFCQLAKTCPVQLWVDSTPPPGTRVRAMAIYKQSQHMTEVVRRCPHHERCSDSDGLAPPQHLIRVEGNLRVEYLDDRNTFRHSVVVPYEPPEVGSDCTTIHYNYMCNSSCMGGMNRRPILTIITLEDSSGNLLGRNSFEVRVCACPGRDRRTEEENLRKK"
        ),
        ProteinPresetExample(
            id: "ubic_core",
            name: L10n.t("Ubiquitin (泛素标准球状折叠蛋白 1UBQ)"),
            subtitle: L10n.t("76 aa · 经典 β-grasp 折叠基准结构"),
            sequence: "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG"
        ),
        ProteinPresetExample(
            id: "trpcage",
            name: L10n.t("Trp-Cage (微蛋白快速折叠模型 1L2Y)"),
            subtitle: L10n.t("20 aa · 分子动力学温度/pH 相变经典序列"),
            sequence: "NLYIQWLKDGGPSSGRPPPS"
        )
    ] }

    /// 平均脱水残基分子量 (Da)，与 ExPASy ProtParam / BioPython 一致
    public static let aaMasses: [Character: Double] = [
        "A": 71.0788, "R": 156.1875, "N": 114.1038, "D": 115.0886,
        "C": 103.1388, "E": 129.1155, "Q": 128.1307, "G": 57.0519,
        "H": 137.1411, "I": 113.1594, "L": 113.1594, "K": 128.1741,
        "M": 131.1926, "F": 147.1766, "P": 97.1167, "S": 87.0782,
        "T": 101.1051, "W": 186.2132, "Y": 163.1760, "V": 99.1326
    ]

    public static let waterMassDa: Double = 18.01528

    private static let threeLetterMap: [Character: String] = [
        "A": "ALA", "R": "ARG", "N": "ASN", "D": "ASP",
        "C": "CYS", "E": "GLU", "Q": "GLN", "G": "GLY",
        "H": "HIS", "I": "ILE", "L": "LEU", "K": "LYS",
        "M": "MET", "F": "PHE", "P": "PRO", "S": "SER",
        "T": "THR", "W": "TRP", "Y": "TYR", "V": "VAL"
    ]

    private static let oneLetterFromThree: [String: Character] = {
        var dict = Dictionary(uniqueKeysWithValues: threeLetterMap.map { ($0.value, $0.key) })
        dict["MSE"] = "M" // 硒代甲硫氨酸自动映射为 M 并在体检卡提示
        return dict
    }()

    /// Kyte-Doolittle 疏水性标度
    public static let kyteDoolittle: [Character: Double] = [
        "I": 4.5, "V": 4.2, "L": 3.8, "F": 2.8, "C": 2.5,
        "M": 1.9, "A": 1.8, "G": -0.4, "T": -0.7, "S": -0.8,
        "W": -0.9, "Y": -1.3, "P": -1.6, "H": -3.2, "E": -3.5,
        "Q": -3.5, "D": -3.5, "N": -3.5, "K": -3.9, "R": -4.5
    ]

    /// Campen et al. (2008) TOP-IDP 内在无序倾向标度 (Protein Pept. Lett. 15:956-963)
    public static let topIDPScale: [Character: Double] = [
        "W": -0.884, "F": -0.697, "Y": -0.510, "I": -0.486, "M": -0.397,
        "L": -0.326, "V": -0.121, "N": 0.007,  "C": 0.020,  "T": 0.059,
        "A": 0.060,  "G": 0.166,  "R": 0.180,  "D": 0.192,  "H": 0.303,
        "Q": 0.318,  "S": 0.341,  "K": 0.586,  "E": 0.736,  "P": 0.987
    ]

    /// Guruprasad, Reddy & Pandit (1990) 完整 20×20 二肽不稳定性权重矩阵 (DIWV, Protein Eng. 4:155–161)
    /// 与 ExPASy ProtParam / BioPython ProtParamData.DIWV 逐项严格一致
    public static let guruprasadDIWV: [Character: [Character: Double]] = [
        "A": ["A": 1.0, "C": 44.94, "D": -7.49, "E": 1.0, "F": 1.0, "G": 1.0, "H": -7.49, "I": 1.0, "K": 1.0, "L": 1.0, "M": 1.0, "N": 1.0, "P": 20.26, "Q": 1.0, "R": 1.0, "S": 1.0, "T": 1.0, "V": 1.0, "W": 1.0, "Y": 1.0],
        "C": ["A": 1.0, "C": 1.0, "D": 20.26, "E": 1.0, "F": 1.0, "G": 1.0, "H": 33.60, "I": 1.0, "K": 1.0, "L": 20.26, "M": 33.60, "N": 1.0, "P": 20.26, "Q": -6.54, "R": 1.0, "S": 1.0, "T": 33.60, "V": -6.54, "W": 24.68, "Y": 1.0],
        "D": ["A": 1.0, "C": 1.0, "D": 1.0, "E": 1.0, "F": -6.54, "G": 1.0, "H": 1.0, "I": 1.0, "K": -7.49, "L": 1.0, "M": 1.0, "N": 1.0, "P": 1.0, "Q": 1.0, "R": -6.54, "S": 20.26, "T": -14.03, "V": 1.0, "W": 1.0, "Y": 1.0],
        "E": ["A": 1.0, "C": 44.94, "D": 20.26, "E": 33.60, "F": 1.0, "G": 1.0, "H": -6.54, "I": 20.26, "K": 1.0, "L": 1.0, "M": 1.0, "N": 1.0, "P": 20.26, "Q": 20.26, "R": 1.0, "S": 20.26, "T": 1.0, "V": 1.0, "W": -14.03, "Y": 1.0],
        "F": ["A": 1.0, "C": 1.0, "D": 13.34, "E": 1.0, "F": 1.0, "G": 1.0, "H": 1.0, "I": 1.0, "K": -14.03, "L": 1.0, "M": 1.0, "N": 1.0, "P": 20.26, "Q": 1.0, "R": 1.0, "S": 1.0, "T": 1.0, "V": 1.0, "W": 1.0, "Y": 33.60],
        "G": ["A": -7.49, "C": 1.0, "D": 1.0, "E": -6.54, "F": 1.0, "G": 13.34, "H": 1.0, "I": -7.49, "K": -7.49, "L": 1.0, "M": 1.0, "N": -7.49, "P": 1.0, "Q": 1.0, "R": 1.0, "S": 1.0, "T": -7.49, "V": 1.0, "W": 13.34, "Y": -7.49],
        "H": ["A": 1.0, "C": 1.0, "D": 1.0, "E": 1.0, "F": -9.37, "G": -9.37, "H": 1.0, "I": 44.94, "K": 24.68, "L": 1.0, "M": 1.0, "N": 24.68, "P": -1.88, "Q": 1.0, "R": 1.0, "S": 1.0, "T": -6.54, "V": 1.0, "W": -1.88, "Y": 44.94],
        "I": ["A": 1.0, "C": 1.0, "D": 1.0, "E": 44.94, "F": 1.0, "G": 1.0, "H": 13.34, "I": 1.0, "K": -7.49, "L": 20.26, "M": 1.0, "N": 1.0, "P": -1.88, "Q": 1.0, "R": 1.0, "S": 1.0, "T": 1.0, "V": -7.49, "W": 1.0, "Y": 1.0],
        "K": ["A": 1.0, "C": 1.0, "D": 1.0, "E": 1.0, "F": 1.0, "G": -7.49, "H": 1.0, "I": -7.49, "K": 1.0, "L": -7.49, "M": 33.60, "N": 1.0, "P": -6.54, "Q": 24.68, "R": 33.60, "S": 1.0, "T": 1.0, "V": -7.49, "W": 1.0, "Y": 1.0],
        "L": ["A": 1.0, "C": 1.0, "D": 1.0, "E": 1.0, "F": 1.0, "G": 1.0, "H": 1.0, "I": 1.0, "K": -7.49, "L": 1.0, "M": 1.0, "N": 1.0, "P": 20.26, "Q": 33.60, "R": 20.26, "S": 1.0, "T": 1.0, "V": 1.0, "W": 24.68, "Y": 1.0],
        "M": ["A": 13.34, "C": 1.0, "D": 1.0, "E": 1.0, "F": 1.0, "G": 1.0, "H": 58.28, "I": 1.0, "K": 1.0, "L": 1.0, "M": -1.88, "N": 1.0, "P": 44.94, "Q": -6.54, "R": -6.54, "S": 44.94, "T": -1.88, "V": 1.0, "W": 1.0, "Y": 24.68],
        "N": ["A": 1.0, "C": -1.88, "D": 1.0, "E": 1.0, "F": -14.03, "G": -14.03, "H": 1.0, "I": 44.94, "K": 24.68, "L": 1.0, "M": 1.0, "N": 1.0, "P": -1.88, "Q": -6.54, "R": 1.0, "S": 1.0, "T": -7.49, "V": 1.0, "W": -9.37, "Y": 1.0],
        "P": ["A": 20.26, "C": -6.54, "D": -6.54, "E": 18.38, "F": 20.26, "G": 1.0, "H": 1.0, "I": 1.0, "K": 1.0, "L": 1.0, "M": -6.54, "N": 1.0, "P": 20.26, "Q": 20.26, "R": -6.54, "S": 20.26, "T": 1.0, "V": 20.26, "W": -1.88, "Y": 1.0],
        "Q": ["A": 1.0, "C": -6.54, "D": 20.26, "E": 20.26, "F": -6.54, "G": 1.0, "H": 1.0, "I": 1.0, "K": 1.0, "L": 1.0, "M": 1.0, "N": 1.0, "P": 20.26, "Q": 20.26, "R": 1.0, "S": 44.94, "T": 1.0, "V": -6.54, "W": 1.0, "Y": -6.54],
        "R": ["A": 1.0, "C": 1.0, "D": 1.0, "E": 1.0, "F": 1.0, "G": -7.49, "H": 20.26, "I": 1.0, "K": 1.0, "L": 1.0, "M": 1.0, "N": 13.34, "P": 20.26, "Q": 20.26, "R": 58.28, "S": 44.94, "T": 1.0, "V": 1.0, "W": 58.28, "Y": -6.54],
        "S": ["A": 1.0, "C": 33.60, "D": 1.0, "E": 20.26, "F": 1.0, "G": 1.0, "H": 1.0, "I": 1.0, "K": 1.0, "L": 1.0, "M": 1.0, "N": 1.0, "P": 44.94, "Q": 20.26, "R": 20.26, "S": 20.26, "T": 1.0, "V": 1.0, "W": 1.0, "Y": 1.0],
        "T": ["A": 1.0, "C": 1.0, "D": 1.0, "E": 20.26, "F": 13.34, "G": -7.49, "H": 1.0, "I": 1.0, "K": 1.0, "L": 1.0, "M": 1.0, "N": -14.03, "P": 1.0, "Q": -6.54, "R": 1.0, "S": 1.0, "T": 1.0, "V": 1.0, "W": -14.03, "Y": 1.0],
        "V": ["A": 1.0, "C": 1.0, "D": -14.03, "E": 1.0, "F": 1.0, "G": -7.49, "H": 1.0, "I": 1.0, "K": -1.88, "L": 1.0, "M": 1.0, "N": 1.0, "P": 20.26, "Q": 1.0, "R": 1.0, "S": 1.0, "T": -7.49, "V": 1.0, "W": 1.0, "Y": -6.54],
        "W": ["A": -14.03, "C": 1.0, "D": 1.0, "E": 1.0, "F": 1.0, "G": -9.37, "H": 24.68, "I": 1.0, "K": 1.0, "L": 13.34, "M": 24.68, "N": 13.34, "P": 1.0, "Q": 1.0, "R": 1.0, "S": 1.0, "T": -14.03, "V": -7.49, "W": 1.0, "Y": 1.0],
        "Y": ["A": 24.68, "C": 1.0, "D": 24.68, "E": -6.54, "F": 1.0, "G": -7.49, "H": 13.34, "I": 1.0, "K": 1.0, "L": 1.0, "M": 44.94, "N": 1.0, "P": 13.34, "Q": 1.0, "R": -15.91, "S": 1.0, "T": -7.49, "V": 1.0, "W": -9.37, "Y": 13.34]
    ]

    /// 可作为 Vina/Smina `--flex` 柔性侧链采样的氨基酸类型（剔除 Gly/Ala/Pro 等刚性或极小侧链）
    private static let rotatableSidechainOneLetters: Set<String> = [
        "R", "K", "E", "Q", "M", "F", "Y", "W", "H", "D", "N", "L", "I", "S", "T", "C", "V"
    ]

    /// 清洗氨基酸序列（保留 20 种标准氨基酸大写字母）
    public static func cleanProteinSequence(_ raw: String) -> String {
        let valid = Set("ACDEFGHIKLMNPQRSTVWY")
        let lines = raw.components(separatedBy: .newlines)
        let bodyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        return String(bodyLines.joined().uppercased().filter { valid.contains($0) })
    }

    /// 拆分多肽链输入（支持 `/` 或 `:` 分隔的多链序列，或 FASTA 多条记录）
    public static func splitProteinChains(_ raw: String) -> [String] {
        let valid = Set("ACDEFGHIKLMNPQRSTVWY")
        let lines = raw.components(separatedBy: .newlines)
        let hasFastaHeaders = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        if hasFastaHeaders {
            var chains: [String] = []
            var current = ""
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(">") {
                    if !current.isEmpty { chains.append(current); current = "" }
                } else {
                    current += String(t.uppercased().filter { valid.contains($0) })
                }
            }
            if !current.isEmpty { chains.append(current) }
            return chains
        }
        if raw.contains("/") || raw.contains(":") {
            let parts = raw.components(separatedBy: CharacterSet(charactersIn: "/:"))
                .map { String($0.uppercased().filter { valid.contains($0) }) }
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts }
        }
        let single = cleanProteinSequence(raw)
        return single.isEmpty ? [] : [single]
    }

    /// 计算多肽链复合物分子量 (Da)：每条链各自保留 1 个完整水分子末端 (18.01528 Da)，链内每个肽键自动扣除 1 分子水
    public static func molecularWeight(chains: [String]) -> Double {
        let nonEmpty = chains.map { cleanProteinSequence($0) }.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return 0.0 }
        return nonEmpty.reduce(0.0) { total, chain in
            let resMass = chain.reduce(0.0) { $0 + (aaMasses[$1] ?? 110.0) }
            return total + resMass + waterMassDa
        }
    }

    /// Guruprasad et al. (1990) 精确 20×20 DIWV 不稳定性指数：II = (10 / L) * Σ DIWV(x_i, x_{i+1})
    public static func calculateInstabilityIndex(sequence: String) -> Double {
        let seq = cleanProteinSequence(sequence)
        let chars = Array(seq)
        guard chars.count >= 2 else { return 0.0 }
        var sum = 0.0
        for i in 0..<(chars.count - 1) {
            sum += guruprasadDIWV[chars[i]]?[chars[i + 1]] ?? 1.0
        }
        return (10.0 / Double(chars.count)) * sum
    }

    /// 多链 Guruprasad 不稳定性指数（按链长加权，不跨链拼接伪二肽）
    public static func calculateInstabilityIndex(chains: [String]) -> Double {
        let nonEmpty = chains.map { cleanProteinSequence($0) }.filter { !$0.isEmpty }
        let totalLen = nonEmpty.reduce(0) { $0 + $1.count }
        guard totalLen >= 2 else { return 0.0 }
        var sum = 0.0
        for ch in nonEmpty {
            let arr = Array(ch)
            if arr.count < 2 { continue }
            for i in 0..<(arr.count - 1) {
                sum += guruprasadDIWV[arr[i]]?[arr[i + 1]] ?? 1.0
            }
        }
        return (10.0 / Double(totalLen)) * sum
    }

    /// 基于 Campen (2008) TOP-IDP 滑动窗与 Uversky (2000) 电荷-疏水相图的连续无序倾向评估
    public static func evaluateDisorderPropensity(sequence: String, windowSize: Int = 15) -> (disorderPct: Double, meanTopIDP: Double, uverskyDistance: Double) {
        let seq = cleanProteinSequence(sequence)
        let chars = Array(seq)
        guard !chars.isEmpty else { return (0.0, 0.0, 0.0) }
        let n = chars.count
        let halfW = max(1, min(windowSize, n) / 2)
        var disorderedCount = 0
        var rawTopSum = 0.0
        var normHydroSum = 0.0

        for i in 0..<n {
            rawTopSum += topIDPScale[chars[i]] ?? 0.0
            normHydroSum += ((kyteDoolittle[chars[i]] ?? 0.0) + 4.5) / 9.0
            let lo = max(0, i - halfW)
            let hi = min(n - 1, i + halfW)
            var winSum = 0.0
            for k in lo...hi { winSum += topIDPScale[chars[k]] ?? 0.0 }
            let winMean = winSum / Double(hi - lo + 1)
            if winMean > 0.15 {
                disorderedCount += 1
            }
        }
        let meanTopIDP = rawTopSum / Double(n)
        let meanNormH = normHydroSum / Double(n)
        let meanAbsNetCharge = abs(netCharge(sequence: seq, atPH: 7.0, scale: .bjellqvist)) / Double(n)
        // Uversky et al. (2000) 边界: <H>_boundary = (|<R>| + 1.151) / 2.785
        // uverskyDistance < 0 表示落在无序区 (IDP)，> 0 表示落在紧凑折叠区
        let boundaryH = (meanAbsNetCharge + 1.151) / 2.785
        let uverskyDist = meanNormH - boundaryH
        let disorderPct = Double(disorderedCount) * 100.0 / Double(n)
        return (disorderPct, meanTopIDP, uverskyDist)
    }

    /// 计算 Debye–Hückel 静电屏蔽长度 κ⁻¹ (Å) 与离子强度效应说明
    /// κ⁻¹(Å) = 3.04 / sqrt(I) * sqrt(T / 298.15)（298.15 K 水溶液 1:1 电解质）
    public static func debyeScreeningLengthA(ionicStrengthM: Double, temperatureK: Double = 298.15) -> (lengthA: Double, note: String) {
        let clampedI = max(0.0005, ionicStrengthM)
        let tempFactor = sqrt(max(250.0, temperatureK) / 298.15)
        let kappaInv = (3.04 / sqrt(clampedI)) * tempFactor
        let note: String
        if ionicStrengthM < 0.02 {
            note = L10n.tr(
                "极低离子强度 (κ⁻¹=\(String(format: "%.1f", kappaInv)) Å)：静电排斥/吸引屏蔽弱，等电点附近易发静电聚集",
                "Very low ionic strength (κ⁻¹=\(String(format: "%.1f", kappaInv)) Å): weak Debye screening; electrostatic aggregation risk near pI"
            )
        } else if ionicStrengthM >= 0.50 {
            note = L10n.tr(
                "高离子强度 (κ⁻¹=\(String(format: "%.1f", kappaInv)) Å)：双电层强烈压缩，疏水相互作用增强并具盐析 (salting-out) 风险",
                "High ionic strength (κ⁻¹=\(String(format: "%.1f", kappaInv)) Å): strong Debye screening; enhanced hydrophobic attraction / salting-out risk"
            )
        } else {
            note = L10n.tr(
                "生理离子强度区间 (κ⁻¹=\(String(format: "%.1f", kappaInv)) Å)：静电屏蔽与水化层处于平衡状态",
                "Physiological ionic strength (κ⁻¹=\(String(format: "%.1f", kappaInv)) Å): balanced Debye screening and hydration"
            )
        }
        return (kappaInv, note)
    }

    /// 计算单链或多链在指定 pH 与 pKa 量表下的蛋白质净电荷 (Henderson-Hasselbalch 方程)
    public static func netCharge(
        chains: [String],
        atPH ph: Double,
        scale: ProteinPKaScale = .bjellqvist
    ) -> Double {
        let nonEmpty = chains.map { cleanProteinSequence($0) }.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return 0.0 }

        var totalPos = 0.0
        var totalNeg = 0.0

        for seq in nonEmpty {
            let chars = Array(seq)
            guard let firstAA = chars.first, let lastAA = chars.last else { continue }
            var counts: [Character: Int] = [:]
            for c in chars { counts[c, default: 0] += 1 }

            let pkN: Double
            let pkC: Double
            let pkK: Double, pkR: Double, pkH: Double
            let pkD: Double, pkE: Double, pkCys: Double, pkY: Double

            switch scale {
            case .bjellqvist:
                // Bjellqvist et al. (Electrophoresis 1993, 14:1023–1031; 1994, 15:529–539) — ExPASy ProtParam 标准
                let nTermOverrides: [Character: Double] = [
                    "M": 7.00, "S": 6.93, "P": 8.36, "A": 7.59,
                    "V": 7.44, "E": 7.70, "T": 6.82
                ]
                let cTermOverrides: [Character: Double] = [
                    "D": 4.55, "E": 4.75
                ]
                pkN = nTermOverrides[firstAA] ?? 7.50
                pkC = cTermOverrides[lastAA] ?? 3.55
                pkK = 10.00; pkR = 12.00; pkH = 5.98
                pkD = 4.05;  pkE = 4.45;  pkCys = 9.00; pkY = 10.00

            case .emboss:
                pkN = 8.60; pkC = 3.60
                pkK = 10.80; pkR = 12.50; pkH = 6.50
                pkD = 3.90;  pkE = 4.10;  pkCys = 8.50; pkY = 10.10

            case .lehninger:
                pkN = 9.69; pkC = 2.34
                pkK = 10.54; pkR = 12.48; pkH = 6.00
                pkD = 3.86;  pkE = 4.25;  pkCys = 8.33; pkY = 10.07
            }

            totalPos += 1.0 / (1.0 + pow(10.0, ph - pkN))
            totalPos += Double(counts["K"] ?? 0) / (1.0 + pow(10.0, ph - pkK))
            totalPos += Double(counts["R"] ?? 0) / (1.0 + pow(10.0, ph - pkR))
            totalPos += Double(counts["H"] ?? 0) / (1.0 + pow(10.0, ph - pkH))

            totalNeg += 1.0 / (1.0 + pow(10.0, pkC - ph))
            totalNeg += Double(counts["D"] ?? 0) / (1.0 + pow(10.0, pkD - ph))
            totalNeg += Double(counts["E"] ?? 0) / (1.0 + pow(10.0, pkE - ph))
            totalNeg += Double(counts["C"] ?? 0) / (1.0 + pow(10.0, pkCys - ph))
            totalNeg += Double(counts["Y"] ?? 0) / (1.0 + pow(10.0, pkY - ph))
        }
        return totalPos - totalNeg
    }

    /// 兼容旧签名的单序列净电荷入口
    public static func netCharge(
        sequence: String,
        atPH ph: Double,
        scale: ProteinPKaScale = .bjellqvist
    ) -> Double {
        let chains = splitProteinChains(sequence)
        return netCharge(chains: chains, atPH: ph, scale: scale)
    }

    /// 二分法求解理论等电点 (pI)，支持多链与 Bjellqvist / EMBOSS / Lehninger 量表
    public static func calculateIsoelectricPoint(
        chains: [String],
        scale: ProteinPKaScale = .bjellqvist
    ) -> Double {
        var lo = 0.5
        var hi = 13.5
        for _ in 0..<40 {
            let mid = 0.5 * (lo + hi)
            if netCharge(chains: chains, atPH: mid, scale: scale) > 0 {
                lo = mid
            } else {
                hi = mid
            }
        }
        return 0.5 * (lo + hi)
    }

    public static func calculateIsoelectricPoint(
        sequence: String,
        scale: ProteinPKaScale = .bjellqvist
    ) -> Double {
        calculateIsoelectricPoint(chains: splitProteinChains(sequence), scale: scale)
    }

    /// 综合分析蛋白质序列与三维构象（支持 PDB / mmCIF 全主链 DSSP 与严格 B-factor/pLDDT 分离）
    public static func analyzeProtein(
        sequence rawSeq: String,
        pdbText: String? = nil,
        env: ProteinEnvironmentParams = ProteinEnvironmentParams()
    ) -> ProteinBiophysicsReport {
        var residues: [ProteinResidue3D] = []
        var pdbMeta = ParsedPDBMetadata()
        let trimmedPDB = pdbText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedPDB.isEmpty {
            let parsed = parseStructureWithMetadata(trimmedPDB)
            residues = parsed.residues
            pdbMeta = parsed.meta
        }
        let hasValidPDB = !residues.isEmpty
        let isSynthetic = !hasValidPDB

        let chainSequences: [String]
        let cleanedSeq: String
        if hasValidPDB {
            var order: [String] = []
            var byChain: [String: String] = [:]
            for r in residues {
                if byChain[r.chainID] == nil { order.append(r.chainID) }
                byChain[r.chainID, default: ""] += r.oneLetter
            }
            chainSequences = order.compactMap { byChain[$0] }.filter { !$0.isEmpty }
            cleanedSeq = chainSequences.joined()
        } else {
            let split = splitProteinChains(rawSeq)
            if split.isEmpty {
                chainSequences = [builtinExamples[0].sequence]
                cleanedSeq = builtinExamples[0].sequence
            } else {
                chainSequences = split
                cleanedSeq = split.joined()
            }
        }

        if isSynthetic {
            residues = generateFoldedResidues(sequence: cleanedSeq, env: env)
        }

        // 计算真实主链二面角 (φ, ψ, ω) 与 Kabsch–Sander (1983) DSSP 二级结构
        let dsspApplied = populateRamachandranAndDSSP(&residues, isSynthetic: isSynthetic)
        // 计算 3D 相对溶剂可及表面积近似 (rASA)
        populateApproximateRASA(&residues)

        let n = max(1, cleanedSeq.count)
        let chars = Array(cleanedSeq)

        // 1. 分子量、pI、消光系数、GRAVY、脂肪族指数、Guruprasad 20×20 DIWV、TOP-IDP & Uversky 无序评估、Debye 屏蔽
        let mw = molecularWeight(chains: chainSequences)
        let pI = calculateIsoelectricPoint(chains: chainSequences, scale: env.pkaScale)
        let charge = netCharge(chains: chainSequences, atPH: env.ph, scale: env.pkaScale)

        let nW = chars.filter { $0 == "W" }.count
        let nY = chars.filter { $0 == "Y" }.count
        let nC = chars.filter { $0 == "C" }.count
        let extRed = nW * 5500 + nY * 1490
        let extOx = extRed + (nC / 2) * 125
        let abs01 = mw > 0 ? Double(extRed) / mw : 0.0

        let hydroSum = chars.reduce(0.0) { $0 + (kyteDoolittle[$1] ?? 0.0) }
        let gravy = hydroSum / Double(n)

        let pctA = Double(chars.filter { $0 == "A" }.count) * 100.0 / Double(n)
        let pctV = Double(chars.filter { $0 == "V" }.count) * 100.0 / Double(n)
        let pctI = Double(chars.filter { $0 == "I" }.count) * 100.0 / Double(n)
        let pctL = Double(chars.filter { $0 == "L" }.count) * 100.0 / Double(n)
        let aliphatic = pctA + 2.9 * pctV + 3.9 * (pctI + pctL)

        let instability = calculateInstabilityIndex(chains: chainSequences)
        let disorderEval = evaluateDisorderPropensity(sequence: cleanedSeq)
        let debye = debyeScreeningLengthA(ionicStrengthM: env.ionicStrengthM, temperatureK: env.temperatureK)

        // 2. 二级结构占比（仅当真实全主链 DSSP 可用时报告实测 DSSP 占比；无 3D 主链/教学虚拟模型不伪造二级结构百分比）
        let helixCount = dsspApplied ? residues.filter { $0.secondary == .helix }.count : 0
        let sheetCount = dsspApplied ? residues.filter { $0.secondary == .sheet }.count : 0
        let coilCount = dsspApplied ? max(0, residues.count - helixCount - sheetCount) : 0
        let hPct = dsspApplied ? (Double(helixCount) * 100.0 / Double(n)) : 0.0
        let sPct = dsspApplied ? (Double(sheetCount) * 100.0 / Double(n)) : 0.0
        let cPct = dsspApplied ? (Double(coilCount) * 100.0 / Double(n)) : 0.0

        // 3. 回旋半径 Rg 与首尾距离
        let cx = residues.reduce(0.0) { $0 + $1.x } / Double(n)
        let cy = residues.reduce(0.0) { $0 + $1.y } / Double(n)
        let cz = residues.reduce(0.0) { $0 + $1.z } / Double(n)
        let rgSq = residues.reduce(0.0) { acc, r in
            let dx = r.x - cx, dy = r.y - cy, dz = r.z - cz
            return acc + (dx * dx + dy * dy + dz * dz)
        } / Double(n)
        let rg = sqrt(max(0.0, rgSq))

        let endToEnd: Double = {
            guard let first = residues.first, let last = residues.last else { return 0.0 }
            let dx = last.x - first.x, dy = last.y - first.y, dz = last.z - first.z
            return sqrt(dx * dx + dy * dy + dz * dz)
        }()

        let tfMetric: TemperatureFactorMetric = isSynthetic ? .syntheticHeuristic : pdbMeta.temperatureFactorMetric
        let meanTF = residues.reduce(0.0) { $0 + $1.temperatureFactor } / Double(n)
        let meanPlddt = (tfMetric == .bFactor) ? meanTF : (residues.reduce(0.0) { $0 + $1.plddt } / Double(n))

        // 4. 残基接触图 (< 8.5 Å 且同链序列间隔 >= 3 或跨链)
        var contacts: [ProteinContactPair] = []
        for i in 0..<residues.count {
            for j in (i + 1)..<residues.count {
                if residues[i].chainID == residues[j].chainID && (j - i) < 3 { continue }
                let dx = residues[i].x - residues[j].x
                let dy = residues[i].y - residues[j].y
                let dz = residues[i].z - residues[j].z
                let dist = sqrt(dx * dx + dy * dy + dz * dz)
                if dist <= 8.5 {
                    contacts.append(
                        ProteinContactPair(
                            resI: residues[i].index,
                            resJ: residues[j].index,
                            distanceA: dist
                        )
                    )
                }
            }
        }

        // 5. 执行 LIGSITE 3D 连通分量 BFS 口袋扫描与证据优先盒子决策
        let (pockets, dockingBox) = detectPocketsAndDockingBox(
            residues: &residues,
            env: env,
            pdbMeta: pdbMeta
        )
        let healthCard = buildStructureHealthCard(
            hasValidPDB: hasValidPDB,
            dsspComputed: dsspApplied,
            tfMetric: tfMetric,
            residues: residues,
            pdbMeta: pdbMeta,
            dockingBox: dockingBox
        )

        // 6. 滑动窗口疏水剖面 (窗口宽度 = 7)
        var hydroProfile: [(index: Int, value: Double)] = []
        let halfW = 3
        for i in 0..<chars.count {
            let lo = max(0, i - halfW)
            let hi = min(chars.count - 1, i + halfW)
            var s = 0.0
            for k in lo...hi { s += kyteDoolittle[chars[k]] ?? 0.0 }
            hydroProfile.append((index: i + 1, value: s / Double(hi - lo + 1)))
        }

        // 7. SPICE 五维质量评分 (M1..M5，真实接入 Debye–Hückel 离子强度静电屏蔽效应)
        let tempPenalty = abs(env.temperatureK - 310.0) * 0.18
        let phPenalty = abs(env.ph - 7.2) * 2.1
        let screeningFactor = exp(-3.5 / max(1.0, debye.lengthA)) // 离子强度越高，表面净电荷排斥被屏蔽越强
        let saltingOutPenalty = env.ionicStrengthM > 0.50 ? (env.ionicStrengthM - 0.50) * 14.0 : 0.0
        let m1Packing = min(99.0, max(45.0, 82.0 + Double(contacts.count) / Double(max(1, n)) * 5.2 - tempPenalty))
        let m2HBond = min(99.0, max(48.0, 74.0 + (hPct + sPct) * 0.24 - tempPenalty))
        let ramaValid = residues.filter { $0.phi != nil && $0.psi != nil }
        let ramaFavored = ramaValid.filter { r in
            guard let phi = r.phi, let psi = r.psi else { return false }
            let inAlpha = (phi >= -140 && phi <= -30 && psi >= -80 && psi <= 25)
            let inBeta  = (phi >= -175 && phi <= -55 && psi >= 75 && psi <= 180)
            let inLeftAlpha = (r.oneLetter == "G" && phi >= 35 && phi <= 110 && psi >= -20 && psi <= 75)
            return inAlpha || inBeta || inLeftAlpha
        }.count
        let m3Ramachandran = ramaValid.isEmpty ? 0.0 : (Double(ramaFavored) * 100.0 / Double(ramaValid.count))
        let m4Solvation = min(99.0, max(42.0, 84.0 - abs(gravy) * 5.0 - phPenalty - saltingOutPenalty * 0.5))
        let effectiveElectroPenalty = abs(charge) * 1.15 * (1.0 - 0.55 * screeningFactor) + saltingOutPenalty
        let m5Electro = min(99.0, max(40.0, 88.0 - effectiveElectroPenalty - phPenalty))
        let qScore = (m1Packing + m2HBond + m3Ramachandran + m4Solvation + m5Electro) / 5.0

        return ProteinBiophysicsReport(
            sequence: cleanedSeq,
            length: n,
            chainCount: chainSequences.count,
            molecularWeightDa: mw,
            isoelectricPoint: pI,
            pkaScale: env.pkaScale,
            netChargeAtEnvPh: charge,
            extinctionReduced: extRed,
            extinctionOxidized: extOx,
            abs01PctReduced: abs01,
            gravy: gravy,
            aliphaticIndex: aliphatic,
            instabilityIndex: instability,
            isStable: instability < 40.0,
            helixPct: hPct,
            sheetPct: sPct,
            coilPct: cPct,
            dsspComputed: dsspApplied,
            disorderPct: disorderEval.disorderPct,
            topIDPMeanScore: disorderEval.meanTopIDP,
            uverskyDisorderDistance: disorderEval.uverskyDistance,
            debyeLengthA: debye.lengthA,
            ionicStrengthNote: debye.note,
            radiusOfGyrationA: rg,
            endToEndDistanceA: endToEnd,
            meanPlddt: meanPlddt,
            meanTemperatureFactor: meanTF,
            temperatureFactorMetric: tfMetric,
            isSyntheticTeachingModel: isSynthetic,
            metricM1Packing: m1Packing,
            metricM2HBond: m2HBond,
            metricM3Ramachandran: m3Ramachandran,
            metricM4Solvation: m4Solvation,
            metricM5Electrostatics: m5Electro,
            compositeQScore: qScore,
            residues: residues,
            contacts: contacts,
            pockets: pockets,
            dockingBox: dockingBox,
            healthCard: healthCard,
            hydropathyProfile: hydroProfile
        )
    }

    // MARK: - 3. 批量点突变 ΔΔG 热力学稳定性评估（强制 WT 校验、自突变 ΔΔG = 0.0、基于 3D rASA 区分核心/表面）

    public static func evaluateMutantsBatch(
        wildTypeSequence: String,
        mutationSpecs: [String],
        env: ProteinEnvironmentParams = ProteinEnvironmentParams(),
        residues3D: [ProteinResidue3D]? = nil
    ) -> [ProteinMutantEvaluation] {
        let wtClean = cleanProteinSequence(wildTypeSequence)
        let wtChars = Array(wtClean)
        guard !wtChars.isEmpty else { return [] }
        let wtGravy = wtChars.reduce(0.0) { $0 + (kyteDoolittle[$1] ?? 0.0) } / Double(wtChars.count)
        let wtCharge = netCharge(sequence: wtClean, atPH: env.ph, scale: env.pkaScale)

        let has3D = (residues3D?.count == wtChars.count)

        var results: [ProteinMutantEvaluation] = []
        for rawSpec in mutationSpecs {
            let trimmed = rawSpec.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var mutChars = wtChars
            var ddgSum = 0.0
            let tokens = trimmed.components(separatedBy: CharacterSet(charactersIn: "+,; ")).filter { !$0.isEmpty }
            var validTokens: [String] = []
            var mismatchWarnings: [String] = []
            var anyCore = false
            var anySurface = false

            for tok in tokens {
                let up = tok.uppercased()
                guard up.count >= 3,
                      let fromAA = up.first,
                      let toAA = up.last,
                      let pos1 = Int(up.dropFirst().dropLast()),
                      pos1 >= 1 && pos1 <= wtChars.count else {
                    mismatchWarnings.append(L10n.tr("无法解析突变格式或位点越界：\(tok)", "Invalid mutation syntax or out-of-range position: \(tok)"))
                    continue
                }
                let actualWT = wtChars[pos1 - 1]
                if actualWT != fromAA {
                    mismatchWarnings.append(
                        L10n.tr(
                            "野生型残基不匹配：第 \(pos1) 位实际为 \(actualWT)，而非 \(fromAA)（输入 \(tok)）",
                            "Wild-type residue mismatch at pos \(pos1): expected \(actualWT), got \(fromAA) (\(tok))"
                        )
                    )
                    continue
                }

                validTokens.append("\(fromAA)\(pos1)\(toAA)")
                if fromAA == toAA {
                    // 自突变 (如 A10A) 严格 ΔΔG = 0.0 kcal/mol（消除历史 -0.55 幽灵偏置）
                    continue
                }

                mutChars[pos1 - 1] = toAA
                let hFrom = kyteDoolittle[fromAA] ?? 0.0
                let hTo = kyteDoolittle[toAA] ?? 0.0
                let mFrom = aaMasses[fromAA] ?? 110.0
                let mTo = aaMasses[toAA] ?? 110.0

                let buriedFactor: Double
                if has3D, let rasa = residues3D?[pos1 - 1].relativeSASA {
                    if rasa < 0.25 {
                        buriedFactor = 1.0
                        anyCore = true
                    } else {
                        buriedFactor = 0.35
                        anySurface = true
                    }
                } else {
                    buriedFactor = (pos1 > 4 && pos1 < wtChars.count - 4) ? 1.0 : 0.45
                }

                let dHydro = (hFrom - hTo) * 0.38 * buriedFactor
                let dSteric = abs(mTo - mFrom) / 95.0 * 0.45 * (has3D ? (0.4 + 0.6 * buriedFactor) : 1.0)
                let prolinePenalty = (toAA == "P") ? (1.45 * (0.5 + 0.5 * buriedFactor)) : 0.0
                ddgSum += (dHydro + dSteric + prolinePenalty)
            }

            let isValidWT = mismatchWarnings.isEmpty && !validTokens.isEmpty
            let mutSeq = String(mutChars)
            let mutGravy = mutChars.reduce(0.0) { $0 + (kyteDoolittle[$1] ?? 0.0) } / Double(mutChars.count)
            let mutCharge = netCharge(sequence: mutSeq, atPH: env.ph, scale: env.pkaScale)
            let burialLabel: String = {
                if !has3D { return "sequence_only" }
                if anyCore && anySurface { return "mixed" }
                if anyCore { return "core" }
                if anySurface { return "surface" }
                return "neutral"
            }()

            if !isValidWT {
                let warnText = mismatchWarnings.joined(separator: "; ")
                results.append(
                    ProteinMutantEvaluation(
                        id: trimmed,
                        mutationSpec: trimmed,
                        mutatedSequence: wtClean,
                        ddgKcalMol: 0.0,
                        deltaGravy: 0.0,
                        deltaCharge: 0.0,
                        compositeScore: 0.0,
                        stabilityVerdict: L10n.t("野生型位点不匹配 (Invalid WT)"),
                        modelType: "empirical_heuristic",
                        isValidWildType: false,
                        validationWarning: warnText,
                        burialClass: burialLabel
                    )
                )
                continue
            }

            let score = min(99.0, max(20.0, 82.0 - ddgSum * 9.5))
            let verdict: String = {
                if ddgSum <= -0.4 { return L10n.t("经验稳定化倾向 (Empirical Stabilizing)") }
                if ddgSum <= 0.5  { return L10n.t("经验中性耐受 (Empirical Neutral)") }
                return L10n.t("经验去稳定化风险 (Empirical Destabilizing)")
            }()
            let label = validTokens.joined(separator: " + ")
            results.append(
                ProteinMutantEvaluation(
                    id: label,
                    mutationSpec: label,
                    mutatedSequence: mutSeq,
                    ddgKcalMol: ddgSum,
                    deltaGravy: mutGravy - wtGravy,
                    deltaCharge: mutCharge - wtCharge,
                    compositeScore: score,
                    stabilityVerdict: verdict,
                    modelType: "empirical_heuristic",
                    isValidWildType: true,
                    validationWarning: nil,
                    burialClass: burialLabel
                )
            )
        }
        return results
    }

    // MARK: - 4. 完整主链 PDB/mmCIF 解析、Kabsch–Sander DSSP、LIGSITE 3D BFS 多口袋与证据优先盒子决策

    public enum DockFlowBoxConstants {
        public static let ligandMargin: Double = 4.0
        public static let sitePadding: Double = 6.0
        public static let pocketMargin: Double = 4.0
        public static let evidencePocketReach: Double = 4.0
        public static let minPocketScore: Double = 0.50
        public static let minPocketVolume: Double = 120.0
        public static let consensusCoverage: Double = 0.35
        public static let siteConsensusCoverage: Double = 0.50
        public static let maxVolumeWarning: Double = 40_000.0
        public static let minVolumeWarning: Double = 1_500.0
        public static let boxMinSize: Double = 18.0
        public static let boxMaxSize: Double = 60.0
    }

    private struct LigandInstanceCoords {
        let resName: String
        let chainID: String
        let resSeq: Int
        let insertionCode: String
        var coords: [(x: Double, y: Double, z: Double)]
    }

    private struct ParsedPDBMetadata {
        var chainIDs: [String] = []
        var missingResidueGapCount: Int = 0
        var nonStandardResidues: [String] = []
        var metalIons: [String] = []
        var coCrystalLigands: [String] = []
        var ligandInstanceCoords: [LigandInstanceCoords] = []
        var coCrystalCoords: [(x: Double, y: Double, z: Double)] = []
        var heavyAtomCoords: [(x: Double, y: Double, z: Double)] = []
        var siteSeqNums: [Int] = []
        var seqKeyToIndex: [String: Int] = [:]
        var seqNumToIndex: [Int: Int] = [:]
        var hasAltLoc: Bool = false
        var stoppedAtFirstModel: Bool = false
        var temperatureFactorMetric: TemperatureFactorMetric = .bFactor
        var hasFullBackbone: Bool = false
    }

    private static let waterAndBufferSet: Set<String> = [
        "HOH", "WAT", "DOD", "SO4", "PO4", "GOL", "EDO", "PEG", "DMS", "ACT", "CL", "NA", "K", "IOD", "TRS", "MES", "HEP"
    ]
    private static let metalSet: Set<String> = [
        "ZN", "MG", "FE", "MN", "CU", "CA", "CO", "NI", "NA", "K"
    ]

    private static func isHydrogenAtomLine(chars: [Character], atomName: String) -> Bool {
        if chars.count >= 78 {
            let elem = String(chars[76..<78]).trimmingCharacters(in: .whitespaces).uppercased()
            if elem == "H" || elem == "D" { return true }
        }
        let upper = atomName.uppercased()
        if upper.hasPrefix("H") || upper.hasPrefix("1H") || upper.hasPrefix("2H") || upper.hasPrefix("3H") || upper.hasPrefix("D") {
            return true
        }
        return false
    }

    private static func detectTemperatureFactorMetric(headerText: String, rawValues: [Double]) -> TemperatureFactorMetric {
        let up = headerText.uppercased()
        if up.contains("LABWORKER_SPICE_FOLD") {
            return .syntheticHeuristic
        }
        // 优先判定实验结构头标签，避免蛋白名如 RAF-1 / BRAF-V600E 误触发 AF- 预测模型判定
        if up.contains("EXPDTA") ||
            up.contains("X-RAY") ||
            up.contains("CRYO-EM") ||
            up.contains("ELECTRON MICROSCOPY") ||
            up.contains("SOLUTION NMR") ||
            up.contains("_EXPTL.METHOD") ||
            up.contains("_REFINE.") {
            return .bFactor
        }
        let hasAFPrefix = up.hasPrefix("AF-") || up.contains("DATA_AF-") || up.contains(" AF-") || up.contains("\nAF-") || up.contains("/AF-")
        if up.contains("_MA_QA_METRIC_GLOBAL") ||
            up.contains("_MA_QA_METRIC_LOCAL") ||
            up.contains("ALPHAFOLD") ||
            up.contains("ESMFOLD") ||
            up.contains("BOLTZ") ||
            hasAFPrefix ||
            up.contains("PLDDT") ||
            up.contains("MODEL_V") {
            return .pLDDT
        }
        return .bFactor
    }

    private static func sanitizeDockingBox(
        centerX: Double, centerY: Double, centerZ: Double,
        sizeX: Double, sizeY: Double, sizeZ: Double
    ) -> (cx: Double, cy: Double, cz: Double, sx: Double, sy: Double, sz: Double, vol: Double) {
        let lo = max(6.0, DockFlowBoxConstants.boxMinSize)
        let hi = max(lo, DockFlowBoxConstants.boxMaxSize)
        let clampedX = min(hi, max(lo, sizeX))
        let clampedY = min(hi, max(lo, sizeY))
        let clampedZ = min(hi, max(lo, sizeZ))
        let rx = (centerX * 1000.0).rounded() / 1000.0
        let ry = (centerY * 1000.0).rounded() / 1000.0
        let rz = (centerZ * 1000.0).rounded() / 1000.0
        let sx = (clampedX * 100.0).rounded() / 100.0
        let sy = (clampedY * 100.0).rounded() / 100.0
        let sz = (clampedZ * 100.0).rounded() / 100.0
        return (rx, ry, rz, sx, sy, sz, sx * sy * sz)
    }

    public static func isMMCIFFormat(_ text: String) -> Bool {
        let head = text.prefix(16000)
        return head.contains("_atom_site.") || (text.contains("data_") && text.contains("_atom_site."))
    }

    private static func tokenizeMMCIFLine(_ line: String) -> [String] {
        var tokens: [String] = []
        let chars = Array(line)
        var i = 0
        let n = chars.count
        while i < n {
            while i < n && (chars[i] == " " || chars[i] == "\t") { i += 1 }
            if i >= n { break }
            let ch = chars[i]
            if ch == "#" { break }
            if ch == "'" || ch == "\"" {
                let quote = ch
                i += 1
                let start = i
                while i < n && chars[i] != quote { i += 1 }
                tokens.append(String(chars[start..<i]))
                if i < n { i += 1 }
            } else {
                let start = i
                while i < n && chars[i] != " " && chars[i] != "\t" { i += 1 }
                tokens.append(String(chars[start..<i]))
            }
        }
        return tokens
    }

    /// 统一结构解析入口：同时提取完整主链 (N, CA, C, O)、分实例配体 (resName, chain, resSeq, iCode)、SITE/_struct_site_gen 及温度因子语义
    private static func parseStructureWithMetadata(_ text: String) -> (residues: [ProteinResidue3D], meta: ParsedPDBMetadata) {
        if isMMCIFFormat(text) {
            return parseMMCIFCore(text)
        }
        return parsePDBCore(text)
    }

    private struct ResidueBuilder {
        let chainID: String
        let resSeq: Int
        let iCode: String
        let resName: String
        var ca: ProteinVec3?
        var n: ProteinVec3?
        var c: ProteinVec3?
        var o: ProteinVec3?
        var tfVal: Double = 0.0
        var hasTF: Bool = false
    }

    private static func parseMMCIFCore(_ cifText: String) -> (residues: [ProteinResidue3D], meta: ParsedPDBMetadata) {
        var meta = ParsedPDBMetadata()
        var chains = Set<String>()
        var nonStd = Set<String>()
        var metals = Set<String>()
        var ligandMap: [String: LigandInstanceCoords] = [:]
        var ligandOrder: [String] = []
        var siteKeys: [(chain: String, seq: Int, iCode: String)] = []

        var builderOrder: [String] = []
        var builders: [String: ResidueBuilder] = [:]
        var firstModelTag: String? = nil

        let lines = cifText.components(separatedBy: .newlines)
        var idx = 0
        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed == "loop_" {
                idx += 1
                var colNames: [String] = []
                while idx < lines.count {
                    let t = lines[idx].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("_") {
                        colNames.append(t)
                        idx += 1
                    } else if t.isEmpty || t.hasPrefix("#") {
                        idx += 1
                    } else {
                        break
                    }
                }

                if colNames.contains(where: { $0.hasPrefix("_atom_site.") }) {
                    var colIdx: [String: Int] = [:]
                    for (cIndex, cName) in colNames.enumerated() { colIdx[cName] = cIndex }
                    let cGroup = colIdx["_atom_site.group_PDB"]
                    let cAtom = colIdx["_atom_site.label_atom_id"] ?? colIdx["_atom_site.auth_atom_id"]
                    let cComp = colIdx["_atom_site.auth_comp_id"] ?? colIdx["_atom_site.label_comp_id"]
                    let cChain = colIdx["_atom_site.auth_asym_id"] ?? colIdx["_atom_site.label_asym_id"]
                    let cSeq = colIdx["_atom_site.auth_seq_id"] ?? colIdx["_atom_site.label_seq_id"]
                    let cICode = colIdx["_atom_site.pdbx_PDB_ins_code"]
                    let cAlt = colIdx["_atom_site.label_alt_id"]
                    let cX = colIdx["_atom_site.Cartn_x"]
                    let cY = colIdx["_atom_site.Cartn_y"]
                    let cZ = colIdx["_atom_site.Cartn_z"]
                    let cB = colIdx["_atom_site.B_iso_or_equiv"]
                    let cElem = colIdx["_atom_site.type_symbol"]
                    let cModel = colIdx["_atom_site.pdbx_PDB_model_num"]

                    while idx < lines.count {
                        let rowRaw = lines[idx].trimmingCharacters(in: .whitespaces)
                        if rowRaw.isEmpty || rowRaw.hasPrefix("#") { idx += 1; continue }
                        if rowRaw == "loop_" || rowRaw.hasPrefix("_") || rowRaw.hasPrefix("data_") { break }
                        let toks = tokenizeMMCIFLine(rowRaw)
                        idx += 1
                        guard toks.count >= 6 else { continue }

                        func tok(_ pos: Int?) -> String {
                            guard let p = pos, p >= 0, p < toks.count else { return "" }
                            return toks[p]
                        }

                        let modelTag = tok(cModel)
                        if !modelTag.isEmpty && modelTag != "." && modelTag != "?" {
                            if firstModelTag == nil { firstModelTag = modelTag }
                            else if modelTag != firstModelTag { meta.stoppedAtFirstModel = true; continue }
                        }

                        let alt = tok(cAlt)
                        if !alt.isEmpty && alt != "." && alt != "?" && alt != "A" && alt != "1" {
                            meta.hasAltLoc = true
                            continue
                        }

                        let group = tok(cGroup).uppercased()
                        let atomName = tok(cAtom).uppercased()
                        let elem = tok(cElem).uppercased()
                        if elem == "H" || elem == "D" || atomName.hasPrefix("H") || atomName.hasPrefix("1H") || atomName.hasPrefix("2H") {
                            continue
                        }

                        guard let x = Double(tok(cX)), let y = Double(tok(cY)), let z = Double(tok(cZ)) else { continue }
                        let resName = tok(cComp).uppercased()
                        let chainID = {
                            let c = tok(cChain)
                            return (c.isEmpty || c == "." || c == "?") ? "A" : c
                        }()
                        let seqStr = tok(cSeq)
                        let seqNum = Int(seqStr) ?? 0
                        let rawIC = tok(cICode)
                        let iCode = (rawIC == "." || rawIC == "?") ? "" : rawIC

                        if group == "HETATM" && resName != "MSE" {
                            guard !waterAndBufferSet.contains(resName) else { continue }
                            if metalSet.contains(resName) {
                                metals.insert(resName)
                            } else if !resName.isEmpty {
                                let lKey = "\(resName):\(chainID):\(seqNum)\(iCode)"
                                if ligandMap[lKey] == nil {
                                    ligandOrder.append(lKey)
                                    ligandMap[lKey] = LigandInstanceCoords(resName: resName, chainID: chainID, resSeq: seqNum, insertionCode: iCode, coords: [])
                                }
                                ligandMap[lKey]?.coords.append((x, y, z))
                            }
                        } else if group == "ATOM" || group.isEmpty || resName == "MSE" {
                            chains.insert(chainID)
                            if !resName.isEmpty && threeLetterMap.values.contains(resName) == false {
                                nonStd.insert(resName)
                            }
                            meta.heavyAtomCoords.append((x, y, z))

                            let rKey = "\(chainID):\(seqStr):\(iCode)"
                            if builders[rKey] == nil {
                                builderOrder.append(rKey)
                                builders[rKey] = ResidueBuilder(chainID: chainID, resSeq: seqNum, iCode: iCode, resName: resName.isEmpty ? "ALA" : resName)
                            }
                            let vec = ProteinVec3(x, y, z)
                            if atomName == "CA" {
                                builders[rKey]?.ca = vec
                                if let bVal = Double(tok(cB)) {
                                    builders[rKey]?.tfVal = bVal
                                    builders[rKey]?.hasTF = true
                                }
                            } else if atomName == "N" {
                                builders[rKey]?.n = vec
                            } else if atomName == "C" {
                                builders[rKey]?.c = vec
                            } else if atomName == "O" {
                                builders[rKey]?.o = vec
                            }
                        }
                    }
                } else if colNames.contains(where: { $0.hasPrefix("_struct_site_gen.") }) {
                    var colIdx: [String: Int] = [:]
                    for (cIndex, cName) in colNames.enumerated() { colIdx[cName] = cIndex }
                    let cChain = colIdx["_struct_site_gen.auth_asym_id"] ?? colIdx["_struct_site_gen.label_asym_id"]
                    let cSeq = colIdx["_struct_site_gen.auth_seq_id"] ?? colIdx["_struct_site_gen.label_seq_id"]
                    let cIC = colIdx["_struct_site_gen.pdbx_auth_ins_code"]
                    while idx < lines.count {
                        let rowRaw = lines[idx].trimmingCharacters(in: .whitespaces)
                        if rowRaw.isEmpty || rowRaw.hasPrefix("#") { idx += 1; continue }
                        if rowRaw == "loop_" || rowRaw.hasPrefix("_") || rowRaw.hasPrefix("data_") { break }
                        let toks = tokenizeMMCIFLine(rowRaw)
                        idx += 1
                        func tok(_ pos: Int?) -> String {
                            guard let p = pos, p >= 0, p < toks.count else { return "" }
                            return toks[p]
                        }
                        if let sNum = Int(tok(cSeq)) {
                            let ch = tok(cChain)
                            let rawIC = tok(cIC)
                            let ic = (rawIC == "." || rawIC == "?") ? "" : rawIC
                            siteKeys.append((ch.isEmpty || ch == "." || ch == "?" ? "A" : ch, sNum, ic))
                        }
                    }
                }
            } else {
                idx += 1
            }
        }

        let headerSlice = cifText.count > 48000
            ? (String(cifText.prefix(24000)) + "\n" + String(cifText.suffix(24000)))
            : cifText
        return finalizeParsedStructure(
            headerText: headerSlice,
            builderOrder: builderOrder,
            builders: builders,
            chains: chains,
            nonStd: nonStd,
            metals: metals,
            ligandOrder: ligandOrder,
            ligandMap: ligandMap,
            siteKeys: siteKeys,
            baseMeta: meta
        )
    }

    private static func parsePDBCore(_ pdbText: String) -> (residues: [ProteinResidue3D], meta: ParsedPDBMetadata) {
        var meta = ParsedPDBMetadata()
        var chains = Set<String>()
        var nonStd = Set<String>()
        var metals = Set<String>()
        var ligandMap: [String: LigandInstanceCoords] = [:]
        var ligandOrder: [String] = []
        var siteKeys: [(chain: String, seq: Int, iCode: String)] = []

        var builderOrder: [String] = []
        var builders: [String: ResidueBuilder] = [:]
        var headerLines: [String] = []

        for line in pdbText.components(separatedBy: .newlines) {
            if line.hasPrefix("ENDMDL") {
                meta.stoppedAtFirstModel = true
                break
            }
            if line.hasPrefix("HEADER") || line.hasPrefix("EXPDTA") || line.hasPrefix("REMARK") || line.hasPrefix("TITLE") {
                if headerLines.count < 80 { headerLines.append(line) }
                continue
            }
            if line.hasPrefix("SITE  ") && line.count >= 22 {
                // 标准 PDB SITE 固定列宽：每行最多 4 组，起始列 18, 29, 40, 51 (各占 10 列: resName[0..3] + space + chain[4] + resSeq[5..9] + iCode[9])
                let chars = Array(line)
                var parsedFixed = false
                for slot in 0..<4 {
                    let base = 18 + slot * 11
                    if base + 9 <= chars.count {
                        let resStr = String(chars[base..<(base + 3)]).trimmingCharacters(in: .whitespaces)
                        let chStr = String(chars[base + 4]).trimmingCharacters(in: .whitespaces)
                        let seqEnd = min(chars.count, base + 9)
                        let seqStr = String(chars[(base + 5)..<seqEnd]).trimmingCharacters(in: .whitespaces)
                        let icStr = (base + 9 < chars.count) ? String(chars[base + 9]).trimmingCharacters(in: .whitespaces) : ""
                        if !resStr.isEmpty, let num = Int(seqStr) {
                            siteKeys.append((chStr.isEmpty ? "A" : chStr, num, icStr))
                            parsedFixed = true
                        }
                    }
                }
                if !parsedFixed {
                    // 兼容非严格定宽简写 SITE 行
                    let tokens = line.dropFirst(18).split(separator: " ")
                    for tok in tokens {
                        let s = String(tok)
                        if let num = Int(s) {
                            siteKeys.append(("A", num, ""))
                        } else if s.count >= 2, let first = s.first, first.isLetter, let num = Int(s.dropFirst()) {
                            siteKeys.append((String(first), num, ""))
                        }
                    }
                }
                continue
            }

            let isAtom = line.hasPrefix("ATOM  ")
            let isHet = line.hasPrefix("HETATM")
            guard (isAtom || isHet) && line.count >= 54 else { continue }
            let chars = Array(line)
            let altLoc = chars[16]
            if altLoc != " " && altLoc != "A" && altLoc != "1" {
                meta.hasAltLoc = true
                continue
            }
            let atomName = String(chars[12..<16]).trimmingCharacters(in: .whitespaces).uppercased()
            if isHydrogenAtomLine(chars: chars, atomName: atomName) { continue }

            let resName = String(chars[17..<20]).trimmingCharacters(in: .whitespaces).uppercased()
            let chainRaw = String(chars[21]).trimmingCharacters(in: .whitespaces)
            let chainID = chainRaw.isEmpty ? "A" : chainRaw
            let seqStr = String(chars[22..<26]).trimmingCharacters(in: .whitespaces)
            let seqNum = Int(seqStr) ?? 0
            let iCode = chars.count > 26 ? String(chars[26]).trimmingCharacters(in: .whitespaces) : ""
            let xStr = String(chars[30..<38]).trimmingCharacters(in: .whitespaces)
            let yStr = String(chars[38..<46]).trimmingCharacters(in: .whitespaces)
            let zStr = String(chars[46..<54]).trimmingCharacters(in: .whitespaces)
            guard let x = Double(xStr), let y = Double(yStr), let z = Double(zStr) else { continue }

            if isHet && resName != "MSE" {
                guard !waterAndBufferSet.contains(resName) else { continue }
                if metalSet.contains(resName) {
                    metals.insert(resName)
                } else if !resName.isEmpty {
                    let lKey = "\(resName):\(chainID):\(seqNum)\(iCode)"
                    if ligandMap[lKey] == nil {
                        ligandOrder.append(lKey)
                        ligandMap[lKey] = LigandInstanceCoords(resName: resName, chainID: chainID, resSeq: seqNum, insertionCode: iCode, coords: [])
                    }
                    ligandMap[lKey]?.coords.append((x, y, z))
                }
                continue
            }

            chains.insert(chainID)
            if threeLetterMap.values.contains(resName) == false {
                nonStd.insert(resName)
            }
            meta.heavyAtomCoords.append((x, y, z))

            let rKey = "\(chainID):\(seqStr):\(iCode)"
            if builders[rKey] == nil {
                builderOrder.append(rKey)
                builders[rKey] = ResidueBuilder(chainID: chainID, resSeq: seqNum, iCode: iCode, resName: resName)
            }
            let vec = ProteinVec3(x, y, z)
            if atomName == "CA" {
                builders[rKey]?.ca = vec
                if chars.count >= 66, let bVal = Double(String(chars[60..<66]).trimmingCharacters(in: .whitespaces)) {
                    builders[rKey]?.tfVal = bVal
                    builders[rKey]?.hasTF = true
                }
            } else if atomName == "N" {
                builders[rKey]?.n = vec
            } else if atomName == "C" {
                builders[rKey]?.c = vec
            } else if atomName == "O" {
                builders[rKey]?.o = vec
            }
        }

        return finalizeParsedStructure(
            headerText: headerLines.joined(separator: "\n"),
            builderOrder: builderOrder,
            builders: builders,
            chains: chains,
            nonStd: nonStd,
            metals: metals,
            ligandOrder: ligandOrder,
            ligandMap: ligandMap,
            siteKeys: siteKeys,
            baseMeta: meta
        )
    }

    private static func finalizeParsedStructure(
        headerText: String,
        builderOrder: [String],
        builders: [String: ResidueBuilder],
        chains: Set<String>,
        nonStd: Set<String>,
        metals: Set<String>,
        ligandOrder: [String],
        ligandMap: [String: LigandInstanceCoords],
        siteKeys: [(chain: String, seq: Int, iCode: String)],
        baseMeta: ParsedPDBMetadata
    ) -> (residues: [ProteinResidue3D], meta: ParsedPDBMetadata) {
        var meta = baseMeta
        var residues: [ProteinResidue3D] = []
        var rawTFs: [Double] = []
        var prevChain: String? = nil
        var prevSeq: Int? = nil
        var fullBackboneCount = 0

        for key in builderOrder {
            guard let b = builders[key], let ca = b.ca else { continue }
            let oneChar = oneLetterFromThree[b.resName] ?? "A"
            let tf = b.hasTF ? b.tfVal : 0.0
            rawTFs.append(tf)
            if b.n != nil && b.c != nil && b.o != nil {
                fullBackboneCount += 1
            }
            let resIndex = residues.count + 1
            residues.append(
                ProteinResidue3D(
                    index: resIndex,
                    oneLetter: String(oneChar),
                    threeLetter: b.resName,
                    chainID: b.chainID,
                    resSeq: b.resSeq,
                    insertionCode: b.iCode,
                    x: ca.x,
                    y: ca.y,
                    z: ca.z,
                    backboneN: b.n,
                    backboneC: b.c,
                    backboneO: b.o,
                    plddt: tf,
                    temperatureFactor: tf,
                    secondary: .coil,
                    hydropathy: kyteDoolittle[oneChar] ?? 0.0,
                    phi: nil,
                    psi: nil,
                    omega: nil,
                    relativeSASA: nil,
                    isPocketResidue: false
                )
            )
            meta.seqKeyToIndex["\(b.chainID):\(b.resSeq):\(b.iCode)"] = resIndex
            meta.seqKeyToIndex["\(b.chainID):\(b.resSeq)"] = resIndex
            if meta.seqNumToIndex[b.resSeq] == nil {
                meta.seqNumToIndex[b.resSeq] = resIndex
            }
            if prevChain == b.chainID, let ps = prevSeq, b.resSeq - ps > 1 {
                meta.missingResidueGapCount += 1
            }
            prevChain = b.chainID
            prevSeq = b.resSeq
        }

        meta.temperatureFactorMetric = detectTemperatureFactorMetric(headerText: headerText, rawValues: rawTFs)
        meta.hasFullBackbone = !residues.isEmpty && (Double(fullBackboneCount) / Double(residues.count) >= 0.6)
        meta.chainIDs = chains.sorted()
        meta.nonStandardResidues = nonStd.sorted()
        meta.metalIons = metals.sorted()
        meta.ligandInstanceCoords = ligandOrder.compactMap { ligandMap[$0] }
        meta.coCrystalLigands = Array(Set(meta.ligandInstanceCoords.map(\.resName))).sorted()
        // 主配体坐标取重原子数最多的首个独立配体实例，避免跨链多拷贝配体中心被盲目平均
        if let primaryLig = meta.ligandInstanceCoords.max(by: { $0.coords.count < $1.coords.count }) {
            meta.coCrystalCoords = primaryLig.coords
        }

        var resolvedSites = Set<Int>()
        for sk in siteKeys {
            if let idx = meta.seqKeyToIndex["\(sk.chain):\(sk.seq):\(sk.iCode)"] ?? meta.seqKeyToIndex["\(sk.chain):\(sk.seq)"] ?? meta.seqNumToIndex[sk.seq] {
                resolvedSites.insert(idx)
            }
        }
        meta.siteSeqNums = resolvedSites.sorted()
        return (residues, meta)
    }

    public static func parsePDBResidues(_ pdbText: String) -> [ProteinResidue3D] {
        parseStructureWithMetadata(pdbText).residues
    }

    // MARK: - 4.1 3D 向量几何与平移/旋转不变的二面角 (φ, ψ, ω) + Kabsch & Sander (1983) DSSP

    private static func vSub(_ a: ProteinVec3, _ b: ProteinVec3) -> ProteinVec3 {
        ProteinVec3(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    private static func vAdd(_ a: ProteinVec3, _ b: ProteinVec3) -> ProteinVec3 {
        ProteinVec3(a.x + b.x, a.y + b.y, a.z + b.z)
    }

    private static func vScale(_ a: ProteinVec3, _ s: Double) -> ProteinVec3 {
        ProteinVec3(a.x * s, a.y * s, a.z * s)
    }

    private static func vDot(_ a: ProteinVec3, _ b: ProteinVec3) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func vCross(_ a: ProteinVec3, _ b: ProteinVec3) -> ProteinVec3 {
        ProteinVec3(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }

    private static func vNorm(_ a: ProteinVec3) -> Double {
        sqrt(max(0.0, vDot(a, a)))
    }

    private static func vDist(_ a: ProteinVec3, _ b: ProteinVec3) -> Double {
        vNorm(vSub(a, b))
    }

    /// 精确 IUPAC 4 点二面角计算（度，[-180, 180]，严格满足 SE(3) 平移与旋转不变性）
    public static func dihedralDegrees(_ p1: ProteinVec3, _ p2: ProteinVec3, _ p3: ProteinVec3, _ p4: ProteinVec3) -> Double? {
        let b1 = vSub(p2, p1)
        let b2 = vSub(p3, p2)
        let b3 = vSub(p4, p3)
        let b2Len = vNorm(b2)
        guard b2Len > 1e-6 else { return nil }
        let b2Unit = vScale(b2, 1.0 / b2Len)
        let n1 = vCross(b1, b2)
        let n2 = vCross(b2, b3)
        guard vNorm(n1) > 1e-6 && vNorm(n2) > 1e-6 else { return nil }
        let m1 = vCross(b2Unit, n1)
        let x = vDot(n1, n2)
        let y = vDot(m1, n2)
        return atan2(y, x) * 180.0 / Double.pi
    }

    /// 结合完整主链 (N, CA, C, O) 计算 (φ, ψ, ω) 并运行 Kabsch & Sander (1983) DSSP 静电氢键二级结构指认
    /// 返回是否运行了真实主链 DSSP
    private static func populateRamachandranAndDSSP(_ residues: inout [ProteinResidue3D], isSynthetic: Bool) -> Bool {
        let n = residues.count
        guard n >= 3 else { return false }

        let fullBackboneCount = residues.filter { $0.backboneN != nil && $0.backboneC != nil && $0.backboneO != nil }.count
        let hasFullBackbone = !isSynthetic && (Double(fullBackboneCount) / Double(n) >= 0.5)

        if !hasFullBackbone {
            // 无真实完整主链原子（含教学虚拟 Cα 模型与 CA-only PDB）均不伪造 φ/ψ 二面角与 Ramachandran 允许区占比
            return false
        }

        // 1. 精确主链 (φ, ψ, ω) 二面角计算
        func isPeptideBonded(_ prevIdx: Int, _ currIdx: Int) -> Bool {
            guard residues[prevIdx].chainID == residues[currIdx].chainID,
                  let cPrev = residues[prevIdx].backboneC,
                  let nCurr = residues[currIdx].backboneN else { return false }
            return vDist(cPrev, nCurr) < 2.5
        }

        for i in 0..<n {
            let ca = ProteinVec3(residues[i].x, residues[i].y, residues[i].z)
            if i > 0 && isPeptideBonded(i - 1, i),
               let cPrev = residues[i - 1].backboneC,
               let nCurr = residues[i].backboneN,
               let cCurr = residues[i].backboneC {
                residues[i].phi = dihedralDegrees(cPrev, nCurr, ca, cCurr)
                let caPrev = ProteinVec3(residues[i - 1].x, residues[i - 1].y, residues[i - 1].z)
                residues[i].omega = dihedralDegrees(caPrev, cPrev, nCurr, ca)
            }
            if i + 1 < n && isPeptideBonded(i, i + 1),
               let nCurr = residues[i].backboneN,
               let cCurr = residues[i].backboneC,
               let nNext = residues[i + 1].backboneN {
                residues[i].psi = dihedralDegrees(nCurr, ca, cCurr, nNext)
            }
        }

        // 2. Kabsch & Sander (1983) DSSP：由前驱肽键 C=O 方向几何重构酰胺氢 H_i (N-H = 1.01 Å)
        var amideH: [ProteinVec3?] = Array(repeating: nil, count: n)
        for i in 1..<n {
            guard residues[i].oneLetter != "P",
                  isPeptideBonded(i - 1, i),
                  let nCurr = residues[i].backboneN,
                  let cPrev = residues[i - 1].backboneC,
                  let oPrev = residues[i - 1].backboneO else { continue }
            let co = vSub(oPrev, cPrev)
            let coLen = vNorm(co)
            guard coLen > 0.5 else { continue }
            // 肽平面内 N-H 方向与前驱 C=O 反平行
            amideH[i] = vSub(nCurr, vScale(co, 1.01 / coLen))
        }

        // 3. 计算主链静电氢键矩阵：E(acceptor i [C=O], donor j [N-H]) < -0.5 kcal/mol
        // Kabsch & Sander 常数: q1*q2*f = 0.42 * 0.20 * 332 = 27.888 kcal*Å/mol
        let kabschConst = 27.888
        var hbondAccToDon: [Set<Int>] = Array(repeating: [], count: n)
        for i in 0..<n {
            guard let cI = residues[i].backboneC, let oI = residues[i].backboneO else { continue }
            let caI = ProteinVec3(residues[i].x, residues[i].y, residues[i].z)
            for j in 0..<n {
                if abs(i - j) < 2 { continue }
                guard let nJ = residues[j].backboneN, let hJ = amideH[j] else { continue }
                let caJ = ProteinVec3(residues[j].x, residues[j].y, residues[j].z)
                // 快速 Cα 预筛 (12 Å)
                if vDist(caI, caJ) > 12.0 { continue }
                let rON = vDist(oI, nJ)
                let rCH = vDist(cI, hJ)
                let rOH = vDist(oI, hJ)
                let rCN = vDist(cI, nJ)
                guard rON > 0.5 && rCH > 0.5 && rOH > 0.5 && rCN > 0.5 else { continue }
                let energy = kabschConst * (1.0 / rON + 1.0 / rCH - 1.0 / rOH - 1.0 / rCN)
                if energy < -0.5 {
                    hbondAccToDon[i].insert(j)
                }
            }
        }

        func hasHB(_ acc: Int, _ don: Int) -> Bool {
            acc >= 0 && acc < n && don >= 0 && don < n && hbondAccToDon[acc].contains(don)
        }

        // 4. DSSP 二级结构指认
        var assigned: [ProteinSecondaryType] = Array(repeating: .coil, count: n)

        // 4A. α-螺旋 (H): 连续两个 4-turn (i -> i+4) 标记 i+1..i+4 (标准 DSSP 规则)
        var turn4 = Array(repeating: false, count: n)
        if n >= 5 {
            for i in 0..<(n - 4) {
                if residues[i].chainID == residues[i + 4].chainID && hasHB(i, i + 4) {
                    turn4[i] = true
                }
            }
        }
        if n >= 6 {
            for i in 1..<(n - 4) {
                if turn4[i - 1] && turn4[i] {
                    for k in i...(i + 3) {
                        assigned[k] = .helix
                    }
                }
            }
        }

        // 4B. β-折叠 (E): 平行与反平行 β-bridge 构成的连续 ladder
        var isBridge = Array(repeating: false, count: n)
        if n >= 5 {
            for i in 1..<(n - 1) {
                guard i + 3 < n - 1 else { continue }
                for j in (i + 3)..<(n - 1) {
                    let parallel = (hasHB(i - 1, j) && hasHB(j, i + 1)) || (hasHB(j - 1, i) && hasHB(i, j + 1))
                    let antiparallel = (hasHB(i, j) && hasHB(j, i)) || (hasHB(i - 1, j + 1) && hasHB(j - 1, i + 1))
                    if parallel || antiparallel {
                        isBridge[i] = true
                        isBridge[j] = true
                    }
                }
            }
        }
        // 连续 >=2 个 β-bridge 组成 β-strand (.sheet)；不覆盖已判定的 α-helix
        for i in 0..<n {
            if isBridge[i] && assigned[i] != .helix {
                let adjBridge = (i > 0 && isBridge[i - 1]) || (i + 1 < n && isBridge[i + 1])
                if adjBridge {
                    assigned[i] = .sheet
                }
            }
        }

        for i in 0..<n {
            residues[i].secondary = assigned[i]
        }
        return true
    }

    /// 基于 10 Å 半球邻居数估算相对溶剂可及表面积 rASA (0..1)，用于区分突变位点核心埋藏区 vs 表面区
    private static func populateApproximateRASA(_ residues: inout [ProteinResidue3D]) {
        let n = residues.count
        guard n > 0 else { return }
        for i in 0..<n {
            var neighbors = 0
            for j in 0..<n where i != j {
                let dx = residues[i].x - residues[j].x
                let dy = residues[i].y - residues[j].y
                let dz = residues[i].z - residues[j].z
                if (dx * dx + dy * dy + dz * dz) <= 100.0 {
                    neighbors += 1
                }
            }
            // 典型球状蛋白疏水核心 10 Å 内约 18–24 个 Cα 邻居，表面约 4–10 个
            let rasa = max(0.0, min(1.0, 1.0 - Double(neighbors) / 22.0))
            residues[i].relativeSASA = rasa
        }
    }

    private static func generateFoldedResidues(
        sequence: String,
        env: ProteinEnvironmentParams
    ) -> [ProteinResidue3D] {
        let chars = Array(sequence)
        let helixFavored = Set("AELMQRK")
        let sheetFavored = Set("VIFYWT")
        var residues: [ProteinResidue3D] = []

        var x = 0.0, y = 0.0, z = 0.0
        let thermalJitter = max(0.0, (env.temperatureK - 295.0) * 0.008)

        for (i, ch) in chars.enumerated() {
            let sec: ProteinSecondaryType = {
                if ch == "P" || ch == "G" { return .coil }
                let segment = (i / 11) % 3
                if segment == 0 && helixFavored.contains(ch) { return .helix }
                if segment == 1 && sheetFavored.contains(ch) { return .sheet }
                if helixFavored.contains(ch) { return .helix }
                if sheetFavored.contains(ch) { return .sheet }
                return .coil
            }()

            let foldBlock = i / 16
            let localIdx = Double(i % 16)
            let dir = (foldBlock % 2 == 0) ? 1.0 : -1.0
            switch sec {
            case .helix:
                let angle = localIdx * (100.0 * Double.pi / 180.0)
                x = Double(foldBlock) * 9.2 + 2.3 * cos(angle)
                y = dir * (localIdx * 1.5 - 11.0)
                z = 2.3 * sin(angle) + sin(Double(i) * 0.37) * thermalJitter
            case .sheet:
                x = Double(foldBlock) * 9.2 + 0.8 * ((i % 2 == 0) ? 1.0 : -1.0)
                y = dir * (localIdx * 2.8 - 18.0)
                z = 4.2 * ((foldBlock % 2 == 0) ? 1.0 : -1.0) + cos(Double(i) * 0.41) * thermalJitter
            case .coil:
                x += 2.6 * cos(Double(i) * 0.65)
                y += dir * 2.1 * sin(Double(i) * 0.52)
                z += 1.9 * sin(Double(i) * 0.78)
            }

            let hydro = kyteDoolittle[ch] ?? 0.0
            let baseConf = (sec == .coil) ? 78.5 : 92.4
            let plddt = min(98.8, max(52.0, baseConf + hydro * 1.1 - thermalJitter * 12.0))

            residues.append(
                ProteinResidue3D(
                    index: i + 1,
                    oneLetter: String(ch),
                    threeLetter: threeLetterMap[ch] ?? "ALA",
                    chainID: "A",
                    resSeq: i + 1,
                    x: x,
                    y: y,
                    z: z,
                    plddt: plddt,
                    temperatureFactor: plddt,
                    secondary: sec,
                    hydropathy: hydro,
                    isPocketResidue: false
                )
            )
        }
        return residues
    }

    /// 升级版 LIGSITE P-S-P 七方向扫描 + 3D 26-邻域 BFS 连通分量多口袋聚类 + 真实球形紧密度 + 证据优先共识盒
    private static func detectPocketsAndDockingBox(
        residues: inout [ProteinResidue3D],
        env: ProteinEnvironmentParams,
        pdbMeta: ParsedPDBMetadata
    ) -> ([ProteinPocketInfo], ProteinDockingBoxRecommendation) {
        guard !residues.isEmpty else {
            let emptyBox = ProteinDockingBoxRecommendation(
                sourceTitle: L10n.t("无可用结构"),
                sourceNote: L10n.t("未检测到有效残基坐标"),
                centerX: 0, centerY: 0, centerZ: 0,
                sizeX: 20, sizeY: 20, sizeZ: 20,
                volumeA3: 8000,
                recommendedExhaustiveness: 8,
                recommendedFlexResidues: [],
                runtimeEstimateNote: L10n.t("标准刚性对接耗时 1.0×")
            )
            return ([], emptyBox)
        }

        let atomCoords: [(x: Double, y: Double, z: Double)] = pdbMeta.heavyAtomCoords.count >= 30
            ? pdbMeta.heavyAtomCoords
            : residues.map { ($0.x, $0.y, $0.z) }
        let isFullHeavyAtom = pdbMeta.heavyAtomCoords.count >= 30
        let vdwCutoff = isFullHeavyAtom ? 3.1 : 3.6

        // 1. 动态无截断网格：支持 >77 Å 的大型复合物完整覆盖
        let xs = atomCoords.map(\.x), ys = atomCoords.map(\.y), zs = atomCoords.map(\.z)
        let minX = (xs.min() ?? 0.0) - 3.0, maxX = (xs.max() ?? 0.0) + 3.0
        let minY = (ys.min() ?? 0.0) - 3.0, maxY = (ys.max() ?? 0.0) + 3.0
        let minZ = (zs.min() ?? 0.0) - 3.0, maxZ = (zs.max() ?? 0.0) + 3.0

        let maxSpan = max(maxX - minX, max(maxY - minY, maxZ - minZ))
        let maxGridDim = 48
        let step = max(1.5, maxSpan / Double(maxGridDim - 4))
        let nx = max(3, min(maxGridDim, Int(((maxX - minX) / step).rounded(.up)) + 1))
        let ny = max(3, min(maxGridDim, Int(((maxY - minY) / step).rounded(.up)) + 1))
        let nz = max(3, min(maxGridDim, Int(((maxZ - minZ) / step).rounded(.up)) + 1))

        let directions: [(Int, Int, Int)] = [
            (1, 0, 0), (0, 1, 0), (0, 0, 1),
            (1, 1, 1), (1, 1, -1), (1, -1, 1), (-1, 1, 1)
        ]

        var occupied = Array(repeating: false, count: nx * ny * nz)
        func gridIdx(_ ix: Int, _ iy: Int, _ iz: Int) -> Int {
            (ix * ny + iy) * nz + iz
        }

        // 精确 ±ceil(r_vdW / step) 球面光栅化 + 空间哈希桶用于 O(1) 全重原子表面距离查询
        let vdwVoxelSpan = max(1, Int(ceil(vdwCutoff / step)))
        let bucketSize = 4.0
        var spatialBuckets: [Int: [(x: Double, y: Double, z: Double)]] = [:]
        func bucketHash(_ bx: Int, _ by: Int, _ bz: Int) -> Int {
            ((bx &* 73856093) ^ (by &* 19349663) ^ (bz &* 83492791))
        }

        for a in atomCoords {
            let bx = Int(floor(a.x / bucketSize))
            let by = Int(floor(a.y / bucketSize))
            let bz = Int(floor(a.z / bucketSize))
            spatialBuckets[bucketHash(bx, by, bz), default: []].append(a)

            let gx = Int(((a.x - minX) / step).rounded())
            let gy = Int(((a.y - minY) / step).rounded())
            let gz = Int(((a.z - minZ) / step).rounded())
            for dx in -vdwVoxelSpan...vdwVoxelSpan {
                let ux = gx + dx
                guard ux >= 0 && ux < nx else { continue }
                for dy in -vdwVoxelSpan...vdwVoxelSpan {
                    let uy = gy + dy
                    guard uy >= 0 && uy < ny else { continue }
                    for dz in -vdwVoxelSpan...vdwVoxelSpan {
                        let uz = gz + dz
                        guard uz >= 0 && uz < nz else { continue }
                        let wx = minX + Double(ux) * step
                        let wy = minY + Double(uy) * step
                        let wz = minZ + Double(uz) * step
                        let d2 = (wx - a.x)*(wx - a.x) + (wy - a.y)*(wy - a.y) + (wz - a.z)*(wz - a.z)
                        if d2 <= vdwCutoff * vdwCutoff {
                            occupied[gridIdx(ux, uy, uz)] = true
                        }
                    }
                }
            }
        }

        func nearestHeavyAtomDist(_ wx: Double, _ wy: Double, _ wz: Double) -> Double {
            let bx = Int(floor(wx / bucketSize))
            let by = Int(floor(wy / bucketSize))
            let bz = Int(floor(wz / bucketSize))
            var best2 = Double.greatestFiniteMagnitude
            for dx in -2...2 {
                for dy in -2...2 {
                    for dz in -2...2 {
                        if let list = spatialBuckets[bucketHash(bx + dx, by + dy, bz + dz)] {
                            for a in list {
                                let d2 = (wx - a.x)*(wx - a.x) + (wy - a.y)*(wy - a.y) + (wz - a.z)*(wz - a.z)
                                if d2 < best2 { best2 = d2 }
                            }
                        }
                    }
                }
            }
            return best2 < Double.greatestFiniteMagnitude ? sqrt(best2) : 999.0
        }

        struct PSPVoxel {
            let ix: Int
            let iy: Int
            let iz: Int
            let x: Double
            let y: Double
            let z: Double
            let pspCount: Int
            let minSurfDist: Double
        }

        var pspVoxels: [PSPVoxel] = []
        var voxelIndexByGrid: [Int: Int] = [:]
        let maxRaySteps = max(5, Int(ceil(12.0 / step)))
        let surfMinDist = isFullHeavyAtom ? 2.4 : 3.0
        let surfMaxDist = isFullHeavyAtom ? 6.8 : 7.5

        for ix in 1..<(nx - 1) {
            for iy in 1..<(ny - 1) {
                for iz in 1..<(nz - 1) {
                    let gIdx = gridIdx(ix, iy, iz)
                    if occupied[gIdx] { continue }
                    let wx = minX + Double(ix) * step
                    let wy = minY + Double(iy) * step
                    let wz = minZ + Double(iz) * step

                    let nearestDist = nearestHeavyAtomDist(wx, wy, wz)
                    guard nearestDist >= surfMinDist && nearestDist <= surfMaxDist else { continue }

                    var pspHits = 0
                    for (dx, dy, dz) in directions {
                        var hitPos = false
                        var hitNeg = false
                        for s in 1...maxRaySteps {
                            let px = ix + dx * s, py = iy + dy * s, pz = iz + dz * s
                            if px >= 0 && px < nx && py >= 0 && py < ny && pz >= 0 && pz < nz {
                                if occupied[gridIdx(px, py, pz)] { hitPos = true; break }
                            } else { break }
                        }
                        for s in 1...maxRaySteps {
                            let nx0 = ix - dx * s, ny0 = iy - dy * s, nz0 = iz - dz * s
                            if nx0 >= 0 && nx0 < nx && ny0 >= 0 && ny0 < ny && nz0 >= 0 && nz0 < nz {
                                if occupied[gridIdx(nx0, ny0, nz0)] { hitNeg = true; break }
                            } else { break }
                        }
                        if hitPos && hitNeg { pspHits += 1 }
                    }
                    if pspHits >= 3 {
                        voxelIndexByGrid[gIdx] = pspVoxels.count
                        pspVoxels.append(
                            PSPVoxel(
                                ix: ix, iy: iy, iz: iz,
                                x: wx, y: wy, z: wz,
                                pspCount: pspHits,
                                minSurfDist: max(0.2, nearestDist - surfMinDist)
                            )
                        )
                    }
                }
            }
        }

        // 2. 3D 26-邻域 BFS 连通分量聚类：将空间独立的多个口袋拆分为独立候选口袋
        struct PocketCluster {
            let voxels: [PSPVoxel]
            let cx: Double
            let cy: Double
            let cz: Double
            let volumeA3: Double
            let enclosure: Double
            let compactness: Double
            let meanDepth: Double
            let score: Double
        }

        var visited = Array(repeating: false, count: pspVoxels.count)
        var clusters: [PocketCluster] = []
        let voxelVol = pow(step, 3)

        for startIdx in 0..<pspVoxels.count where !visited[startIdx] {
            var queue: [Int] = [startIdx]
            visited[startIdx] = true
            var head = 0
            while head < queue.count {
                let cur = pspVoxels[queue[head]]
                head += 1
                for dx in -1...1 {
                    for dy in -1...1 {
                        for dz in -1...1 where !(dx == 0 && dy == 0 && dz == 0) {
                            let ux = cur.ix + dx, uy = cur.iy + dy, uz = cur.iz + dz
                            if ux >= 0 && ux < nx && uy >= 0 && uy < ny && uz >= 0 && uz < nz {
                                if let nbIdx = voxelIndexByGrid[gridIdx(ux, uy, uz)], !visited[nbIdx] {
                                    visited[nbIdx] = true
                                    queue.append(nbIdx)
                                }
                            }
                        }
                    }
                }
            }
            let compVoxels = queue.map { pspVoxels[$0] }
            guard compVoxels.count >= 4 || (pspVoxels.count < 8 && !compVoxels.isEmpty) else { continue }

            let cnt = Double(compVoxels.count)
            let ccx = compVoxels.reduce(0.0) { $0 + $1.x } / cnt
            let ccy = compVoxels.reduce(0.0) { $0 + $1.y } / cnt
            let ccz = compVoxels.reduce(0.0) { $0 + $1.z } / cnt
            let mPSP = compVoxels.reduce(0.0) { $0 + Double($1.pspCount) } / cnt
            let mDepth = compVoxels.reduce(0.0) { $0 + $1.minSurfDist } / cnt
            let vol = cnt * voxelVol
            let encl = min(1.0, max(0.35, mPSP / 7.0))

            // 真实几何球形紧密度 Ψ = π^(1/3)(6V)^(2/3) / A_surf (统计 6-邻域暴露面面积)
            let compGridSet = Set(compVoxels.map { gridIdx($0.ix, $0.iy, $0.iz) })
            var exposedFaces = 0
            let faceDirs = [(1,0,0), (-1,0,0), (0,1,0), (0,-1,0), (0,0,1), (0,0,-1)]
            for v in compVoxels {
                for (dx, dy, dz) in faceDirs {
                    let ux = v.ix + dx, uy = v.iy + dy, uz = v.iz + dz
                    if ux < 0 || ux >= nx || uy < 0 || uy >= ny || uz < 0 || uz >= nz || !compGridSet.contains(gridIdx(ux, uy, uz)) {
                        exposedFaces += 1
                    }
                }
            }
            let surfArea = max(1e-6, Double(exposedFaces) * step * step)
            let sphericity = min(1.0, max(0.15, (pow(Double.pi, 1.0 / 3.0) * pow(6.0 * vol, 2.0 / 3.0)) / surfArea))
            let volScore = min(1.0, max(0.20, log(1.0 + cnt / 25.0) / log(11.0)))
            let depthScore = min(1.0, max(0.25, mDepth / 2.5))
            let prelimScore = 0.45 * encl + 0.25 * volScore + 0.15 * sphericity + 0.15 * depthScore

            clusters.append(
                PocketCluster(
                    voxels: compVoxels,
                    cx: ccx, cy: ccy, cz: ccz,
                    volumeA3: vol,
                    enclosure: encl,
                    compactness: sphericity,
                    meanDepth: mDepth,
                    score: prelimScore
                )
            )
        }

        clusters.sort {
            if abs($0.score - $1.score) > 1e-6 { return $0.score > $1.score }
            return $0.volumeA3 > $1.volumeA3
        }

        // 若未检出任何 P-S-P 格点（极小肽段），回退疏水核心种子点
        var fallbackPts: [(x: Double, y: Double, z: Double)] = []
        if clusters.isEmpty {
            let sortedByHydro = residues.enumerated().sorted { $0.element.hydropathy > $1.element.hydropathy }
            let seedIndices = sortedByHydro.prefix(max(4, min(12, residues.count / 3))).map(\.offset)
            for idx in seedIndices {
                fallbackPts.append((residues[idx].x, residues[idx].y, residues[idx].z))
            }
        }

        let topClusters = Array(clusters.prefix(5))
        let allPocketPts: [(x: Double, y: Double, z: Double)] = topClusters.isEmpty
            ? fallbackPts
            : topClusters[0].voxels.map { ($0.x, $0.y, $0.z) }

        func evaluateEvidencePocketOverlap(
            evidenceCoords: [(x: Double, y: Double, z: Double)],
            candidatePts: [(x: Double, y: Double, z: Double)]
        ) -> (coverage: Double, nearbyPocketPts: [(x: Double, y: Double, z: Double)]) {
            guard !evidenceCoords.isEmpty && !candidatePts.isEmpty else { return (0.0, []) }
            let reach2 = DockFlowBoxConstants.evidencePocketReach * DockFlowBoxConstants.evidencePocketReach
            var coveredCount = 0
            for ev in evidenceCoords {
                if candidatePts.contains(where: {
                    let dx = ev.x - $0.x, dy = ev.y - $0.y, dz = ev.z - $0.z
                    return dx*dx + dy*dy + dz*dz <= reach2
                }) { coveredCount += 1 }
            }
            let nearPts = candidatePts.filter { pt in
                evidenceCoords.contains { ev in
                    let dx = ev.x - pt.x, dy = ev.y - pt.y, dz = ev.z - pt.z
                    return dx*dx + dy*dy + dz*dz <= reach2
                }
            }
            return (Double(coveredCount) / Double(evidenceCoords.count), nearPts)
        }

        func boundingBoxFromCoords(
            _ coords: [(x: Double, y: Double, z: Double)],
            margin: Double
        ) -> (cx: Double, cy: Double, cz: Double, sx: Double, sy: Double, sz: Double) {
            let xs = coords.map(\.x), ys = coords.map(\.y), zs = coords.map(\.z)
            let loX = xs.min() ?? 0.0, hiX = xs.max() ?? 0.0
            let loY = ys.min() ?? 0.0, hiY = ys.max() ?? 0.0
            let loZ = zs.min() ?? 0.0, hiZ = zs.max() ?? 0.0
            return (
                cx: (loX + hiX) * 0.5,
                cy: (loY + hiY) * 0.5,
                cz: (loZ + hiZ) * 0.5,
                sx: (hiX - loX) + margin * 2.0,
                sy: (hiY - loY) + margin * 2.0,
                sz: (hiZ - loZ) + margin * 2.0
            )
        }

        // 3. 证据优先 + 共识融合盒决策（跨所有检测到的口袋分量寻找与配体/SITE 最佳重叠口袋）
        let allClusterPtsCombined: [(x: Double, y: Double, z: Double)] = topClusters.isEmpty
            ? fallbackPts
            : topClusters.flatMap { $0.voxels.map { ($0.x, $0.y, $0.z) } }

        var rawCX = topClusters.first?.cx ?? (fallbackPts.reduce(0.0) { $0 + $1.x } / Double(max(1, fallbackPts.count)))
        var rawCY = topClusters.first?.cy ?? (fallbackPts.reduce(0.0) { $0 + $1.y } / Double(max(1, fallbackPts.count)))
        var rawCZ = topClusters.first?.cz ?? (fallbackPts.reduce(0.0) { $0 + $1.z } / Double(max(1, fallbackPts.count)))
        var rawSX = 22.0, rawSY = 22.0, rawSZ = 22.0
        var boxSourceTitle = L10n.t("LIGSITE P-S-P 几何口袋")
        var boxSourceNote = L10n.tr(
            "基于七方向蛋白质–溶剂–蛋白质包埋度扫描与 3D 连通分量聚类 (边距 ±\(String(format: "%.1f", DockFlowBoxConstants.pocketMargin)) Å) 自动定位",
            "7-direction LIGSITE P-S-P scan with 3D BFS pocket clustering (padding ±\(String(format: "%.1f", DockFlowBoxConstants.pocketMargin)) Å)"
        )

        if !allPocketPts.isEmpty {
            let pBox = boundingBoxFromCoords(allPocketPts, margin: DockFlowBoxConstants.pocketMargin)
            rawCX = pBox.cx; rawCY = pBox.cy; rawCZ = pBox.cz
            rawSX = pBox.sx; rawSY = pBox.sy; rawSZ = pBox.sz
        }

        let pocketQualifies = (topClusters.first?.volumeA3 ?? 0.0) >= DockFlowBoxConstants.minPocketVolume || !allClusterPtsCombined.isEmpty

        if !pdbMeta.coCrystalCoords.isEmpty {
            let primaryInst = pdbMeta.ligandInstanceCoords.max(by: { $0.coords.count < $1.coords.count })
            let ligName = primaryInst.map { "\($0.resName) (\($0.chainID):\($0.resSeq))" } ?? pdbMeta.coCrystalLigands.joined(separator: "/")
            let overlap = evaluateEvidencePocketOverlap(evidenceCoords: pdbMeta.coCrystalCoords, candidatePts: allClusterPtsCombined)
            if pocketQualifies && overlap.coverage >= DockFlowBoxConstants.consensusCoverage && !overlap.nearbyPocketPts.isEmpty {
                let merged = pdbMeta.coCrystalCoords + overlap.nearbyPocketPts
                let cBox = boundingBoxFromCoords(merged, margin: DockFlowBoxConstants.ligandMargin)
                rawCX = cBox.cx; rawCY = cBox.cy; rawCZ = cBox.cz
                rawSX = cBox.sx; rawSY = cBox.sy; rawSZ = cBox.sz
                boxSourceTitle = L10n.tr("共晶配体 (\(ligName)) + LIGSITE 共识融合盒", "Co-crystal Ligand (\(ligName)) + LIGSITE Consensus")
                boxSourceNote = L10n.tr(
                    "配体与高分口袋重叠率 \(String(format: "%.0f%%", overlap.coverage * 100)) (≥35% 阈值)，已合并配体与邻近 4.0 Å 口袋点并外扩 ±\(String(format: "%.1f", DockFlowBoxConstants.ligandMargin)) Å",
                    "Ligand-pocket overlap \(String(format: "%.0f%%", overlap.coverage * 100)) (>=35%); merged with pocket points within 4.0 Å ± \(String(format: "%.1f", DockFlowBoxConstants.ligandMargin)) Å padding"
                )
            } else {
                let lBox = boundingBoxFromCoords(pdbMeta.coCrystalCoords, margin: DockFlowBoxConstants.ligandMargin)
                rawCX = lBox.cx; rawCY = lBox.cy; rawCZ = lBox.cz
                rawSX = lBox.sx; rawSY = lBox.sy; rawSZ = lBox.sz
                boxSourceTitle = L10n.tr("实验共晶配体 (\(ligName)) 优先", "Co-crystal Ligand (\(ligName)) Priority")
                boxSourceNote = L10n.tr(
                    "直接基于实验共晶配体重原子包围盒外扩 ±\(String(format: "%.1f", DockFlowBoxConstants.ligandMargin)) Å (口袋重叠率 \(String(format: "%.0f%%", overlap.coverage * 100)))",
                    "Heavy-atom bounding box of co-crystal ligand ± \(String(format: "%.1f", DockFlowBoxConstants.ligandMargin)) Å (pocket overlap \(String(format: "%.0f%%", overlap.coverage * 100)))"
                )
            }
        } else if !pdbMeta.siteSeqNums.isEmpty {
            let siteRes = residues.filter { pdbMeta.siteSeqNums.contains($0.index) }
            if !siteRes.isEmpty {
                let siteCoords = siteRes.map { (x: $0.x, y: $0.y, z: $0.z) }
                let overlap = evaluateEvidencePocketOverlap(evidenceCoords: siteCoords, candidatePts: allClusterPtsCombined)
                if pocketQualifies && overlap.coverage >= DockFlowBoxConstants.siteConsensusCoverage && !overlap.nearbyPocketPts.isEmpty {
                    let merged = siteCoords + overlap.nearbyPocketPts
                    let sBox = boundingBoxFromCoords(merged, margin: DockFlowBoxConstants.pocketMargin)
                    rawCX = sBox.cx; rawCY = sBox.cy; rawCZ = sBox.cz
                    rawSX = sBox.sx; rawSY = sBox.sy; rawSZ = sBox.sz
                    boxSourceTitle = L10n.t("PDB SITE + LIGSITE 共识融合盒")
                    boxSourceNote = L10n.tr(
                        "PDB SITE 位点 (\(siteRes.count) 残基) 与几何口袋重叠率 \(String(format: "%.0f%%", overlap.coverage * 100)) (≥50% 阈值)，已合并邻近口袋点并外扩 ±\(String(format: "%.1f", DockFlowBoxConstants.pocketMargin)) Å",
                        "PDB SITE (\(siteRes.count) residues) + pocket overlap \(String(format: "%.0f%%", overlap.coverage * 100)) (>=50%) ± \(String(format: "%.1f", DockFlowBoxConstants.pocketMargin)) Å"
                    )
                } else {
                    let sBox = boundingBoxFromCoords(siteCoords, margin: DockFlowBoxConstants.sitePadding)
                    rawCX = sBox.cx; rawCY = sBox.cy; rawCZ = sBox.cz
                    rawSX = sBox.sx; rawSY = sBox.sy; rawSZ = sBox.sz
                    boxSourceTitle = L10n.t("PDB SITE 记录优先")
                    boxSourceNote = L10n.tr(
                        "依据 PDB SITE 活性位点残基 (\(siteRes.count) 个) 包围盒外扩 ±\(String(format: "%.1f", DockFlowBoxConstants.sitePadding)) Å",
                        "PDB SITE active-site residues (\(siteRes.count)) bounding box ± \(String(format: "%.1f", DockFlowBoxConstants.sitePadding)) Å"
                    )
                }
            }
        }

        // 4. 规范化主对接盒子
        let sanitized = sanitizeDockingBox(
            centerX: rawCX, centerY: rawCY, centerZ: rawCZ,
            sizeX: rawSX, sizeY: rawSY, sizeZ: rawSZ
        )
        let cx = sanitized.cx, cy = sanitized.cy, cz = sanitized.cz
        let boxSizeX = sanitized.sx, boxSizeY = sanitized.sy, boxSizeZ = sanitized.sz
        let boxVol = sanitized.vol

        // 5. 为每个独立 BFS 口袋分量构建独立的 ProteinPocketInfo（不再把全蛋白所有口袋平均成一个中心）
        var builtPockets: [ProteinPocketInfo] = []
        if !topClusters.isEmpty {
            for (cIdx, cl) in topClusters.enumerated() {
                let pts = cl.voxels.map { ($0.x, $0.y, $0.z) }
                let bb = boundingBoxFromCoords(pts, margin: DockFlowBoxConstants.pocketMargin)
                let san = sanitizeDockingBox(centerX: cl.cx, centerY: cl.cy, centerZ: cl.cz, sizeX: bb.sx, sizeY: bb.sy, sizeZ: bb.sz)
                var liningIdx: [Int] = []
                var liningSeq = ""
                var hydroHits = 0
                for i in 0..<residues.count {
                    let d = sqrt(pow(residues[i].x - cl.cx, 2) + pow(residues[i].y - cl.cy, 2) + pow(residues[i].z - cl.cz, 2))
                    if d <= 10.5 {
                        if cIdx == 0 { residues[i].isPocketResidue = true }
                        liningIdx.append(residues[i].index)
                        liningSeq += residues[i].oneLetter
                        if residues[i].hydropathy > 0.5 { hydroHits += 1 }
                    }
                }
                let hRatio = Double(hydroHits) / Double(max(1, liningIdx.count))
                let volScore = min(1.0, max(0.20, log(1.0 + Double(cl.voxels.count) / 25.0) / log(11.0)))
                let depthScore = min(1.0, max(0.25, cl.meanDepth / 2.5))
                let finalScore = min(0.98, max(0.25, 0.45 * cl.enclosure + 0.20 * volScore + 0.15 * cl.compactness + 0.10 * depthScore + 0.10 * hRatio))
                let pCharge = netCharge(sequence: liningSeq, atPH: env.ph, scale: env.pkaScale)
                let srcLabel = (cIdx == 0) ? boxSourceTitle : L10n.t("LIGSITE P-S-P 几何口袋")
                builtPockets.append(
                    ProteinPocketInfo(
                        id: cIdx + 1,
                        name: "Pocket #\(cIdx + 1) (\(srcLabel))",
                        centerX: san.cx, centerY: san.cy, centerZ: san.cz,
                        sizeX: san.sx, sizeY: san.sy, sizeZ: san.sz,
                        volumeA3: cl.volumeA3,
                        druggabilityScore: finalScore,
                        enclosureRatio: cl.enclosure,
                        compactness: cl.compactness,
                        meanDepthA: cl.meanDepth,
                        hydrophobicRatio: hRatio,
                        netChargeAtPh: pCharge,
                        evidenceSource: srcLabel,
                        residueIndices: liningIdx
                    )
                )
            }
        } else {
            // 兜底单口袋
            var liningIdx: [Int] = []
            var liningSeq = ""
            var hydroHits = 0
            for i in 0..<residues.count {
                let d = sqrt(pow(residues[i].x - cx, 2) + pow(residues[i].y - cy, 2) + pow(residues[i].z - cz, 2))
                if d <= 10.5 {
                    residues[i].isPocketResidue = true
                    liningIdx.append(residues[i].index)
                    liningSeq += residues[i].oneLetter
                    if residues[i].hydropathy > 0.5 { hydroHits += 1 }
                }
            }
            let hRatio = Double(hydroHits) / Double(max(1, liningIdx.count))
            builtPockets.append(
                ProteinPocketInfo(
                    id: 1,
                    name: "Pocket #1 (\(boxSourceTitle))",
                    centerX: cx, centerY: cy, centerZ: cz,
                    sizeX: boxSizeX, sizeY: boxSizeY, sizeZ: boxSizeZ,
                    volumeA3: max(180.0, Double(fallbackPts.count) * pow(step, 3)),
                    druggabilityScore: 0.55,
                    enclosureRatio: 0.50,
                    compactness: 0.65,
                    meanDepthA: 1.2,
                    hydrophobicRatio: hRatio,
                    netChargeAtPh: netCharge(sequence: liningSeq, atPH: env.ph, scale: env.pkaScale),
                    evidenceSource: boxSourceTitle,
                    residueIndices: liningIdx
                )
            )
        }

        // 标注主对接盒子周边衬里残基与近端柔性侧链 (`--flex`)
        var flexCandidates: [(dist: Double, label: String)] = []
        for i in 0..<residues.count {
            let d = sqrt(pow(residues[i].x - cx, 2) + pow(residues[i].y - cy, 2) + pow(residues[i].z - cz, 2))
            if d <= 10.5 {
                residues[i].isPocketResidue = true
                if d <= 7.8 && rotatableSidechainOneLetters.contains(residues[i].oneLetter) {
                    flexCandidates.append((dist: d, label: "\(residues[i].chainID):\(residues[i].threeLetter)\(residues[i].resSeq)"))
                }
            }
        }

        let topFlex = flexCandidates.sorted { $0.dist < $1.dist }.prefix(4).map(\.label)
        let exhaustiveness = boxVol > 12000 ? 12 : 8
        let flexMult = max(1, topFlex.count) * exhaustiveness
        let runtimeNote = topFlex.isEmpty
            ? L10n.tr("刚性受体模式 (exhaustiveness=\(exhaustiveness))，单配体约 3–8 秒", "Rigid receptor (exhaustiveness=\(exhaustiveness)), ~3–8 s/ligand")
            : L10n.tr("推荐保留 \(topFlex.count) 个近端柔性侧链 (--flex)，搜索空间约为刚性模式的 \(flexMult / 8)×（QuickVina 2 不支持 --flex，请使用 Vina 1.2.7 或 Smina）", "Include \(topFlex.count) proximal --flex residues (~\(flexMult / 8)x search space; requires Vina 1.2.7/Smina)")

        let boxRec = ProteinDockingBoxRecommendation(
            sourceTitle: boxSourceTitle,
            sourceNote: boxSourceNote,
            centerX: cx, centerY: cy, centerZ: cz,
            sizeX: boxSizeX, sizeY: boxSizeY, sizeZ: boxSizeZ,
            volumeA3: boxVol,
            recommendedExhaustiveness: exhaustiveness,
            recommendedFlexResidues: topFlex,
            runtimeEstimateNote: runtimeNote
        )

        return (builtPockets, boxRec)
    }

    private static func buildStructureHealthCard(
        hasValidPDB: Bool,
        dsspComputed: Bool,
        tfMetric: TemperatureFactorMetric,
        residues: [ProteinResidue3D],
        pdbMeta: ParsedPDBMetadata,
        dockingBox: ProteinDockingBoxRecommendation
    ) -> ProteinStructureHealthCard {
        var warnings: [String] = []
        if !hasValidPDB {
            warnings.append(L10n.t("当前为教学用虚拟几何坐标（非物理全原子结构），仅用于序列理化趋势演示；严禁将其用于 DSSP 二级结构占比声明或 AutoDock Vina 分子对接，请导入实验 PDB/mmCIF 或 AlphaFold 结构。"))
        } else if !dsspComputed {
            warnings.append(L10n.t("当前导入结构缺失完整主链重原子 (N, CA, C, O)，无法执行 Kabsch–Sander DSSP 二级结构与精确 (φ, ψ) 二面角计算。"))
        }
        if hasValidPDB {
            if tfMetric == .bFactor {
                warnings.append(L10n.t("温度因子列已识别为实验晶体/电镜 B-factor (Å²，越低越刚性稳定)，与 AlphaFold pLDDT 置信度严格区分。"))
            } else if tfMetric == .pLDDT {
                warnings.append(L10n.t("温度因子列已识别为预测置信度 pLDDT (0–100，越高越可信)。"))
            }
        }
        if pdbMeta.stoppedAtFirstModel {
            warnings.append(L10n.t("检测到多构象/多模型记录 (MODEL/ENDMDL)，已按 DockFlowLab 规范自动仅提取第 1 个构象模型 (first_model=True)。"))
        }
        if pdbMeta.missingResidueGapCount > 0 {
            warnings.append(L10n.tr("检测到 \(pdbMeta.missingResidueGapCount) 处残基编号断链（缺失残基），对接前建议用 PDBFixer 补全。", "Detected \(pdbMeta.missingResidueGapCount) missing-residue backbone break(s); consider completing with PDBFixer."))
        }
        if !pdbMeta.nonStandardResidues.isEmpty {
            warnings.append(L10n.tr("含非标准残基 (\(pdbMeta.nonStandardResidues.joined(separator: ", ")))，已自动映射为标准氨基酸。", "Non-standard residues (\(pdbMeta.nonStandardResidues.joined(separator: ", "))) mapped to standard amino acids."))
        }
        if !pdbMeta.metalIons.isEmpty {
            warnings.append(L10n.tr("检测到金属离子 (\(pdbMeta.metalIons.joined(separator: ", ")))，Vina 标准评分无专门金属配位项，若金属参与催化请保留离子并谨慎解读打分。", "Metal ions detected (\(pdbMeta.metalIons.joined(separator: ", "))); interpret standard Vina scoring cautiously."))
        }
        if pdbMeta.hasAltLoc {
            warnings.append(L10n.t("检测到多构象原子记录 (altloc)，已自动保留 A 主构象。"))
        }
        if dockingBox.volumeA3 > DockFlowBoxConstants.maxVolumeWarning {
            warnings.append(L10n.tr("对接盒子体积 (\(String(format: "%.0f", dockingBox.volumeA3)) Å³) 超过 40,000 Å³ 告警阈值，盲对接搜索空间过大可能降低命中率，建议缩小盒子或增加 exhaustiveness。", "Docking box volume (\(String(format: "%.0f", dockingBox.volumeA3)) Å³) exceeds 40,000 Å³; reduce box size or raise exhaustiveness."))
        } else if dockingBox.volumeA3 < DockFlowBoxConstants.minVolumeWarning {
            warnings.append(L10n.tr("对接盒子体积 (\(String(format: "%.0f", dockingBox.volumeA3)) Å³) 小于 1,500 Å³ 告警阈值，可能限制配体构象翻转。", "Docking box volume (\(String(format: "%.0f", dockingBox.volumeA3)) Å³) is below 1,500 Å³ and may constrain ligand rotation."))
        }
        if warnings.isEmpty {
            warnings.append(L10n.t("结构完整性良好：主链连续无断点，盒子体积处于理想区间 (1,500–40,000 Å³)。"))
        }

        let ligandInstModels = pdbMeta.ligandInstanceCoords.map { inst -> ProteinLigandInstance in
            let cnt = Double(max(1, inst.coords.count))
            let lcx = inst.coords.reduce(0.0) { $0 + $1.x } / cnt
            let lcy = inst.coords.reduce(0.0) { $0 + $1.y } / cnt
            let lcz = inst.coords.reduce(0.0) { $0 + $1.z } / cnt
            return ProteinLigandInstance(
                resName: inst.resName,
                chainID: inst.chainID,
                resSeq: inst.resSeq,
                insertionCode: inst.insertionCode,
                heavyAtomCount: inst.coords.count,
                centerX: lcx, centerY: lcy, centerZ: lcz
            )
        }

        let coordSource = L10n.t(hasValidPDB ? "外部实验 / AlphaFold PDB 坐标" : "教学用虚拟几何坐标 (非全原子)")
        let summary = "\(coordSource) · \(tfMetric.displayTitle) · \(L10n.t("盒子依据"))：\(dockingBox.sourceTitle)"
        return ProteinStructureHealthCard(
            coordinateSource: coordSource,
            isExperimentalOrAlphaFoldPDB: hasValidPDB,
            isSyntheticTeachingModel: !hasValidPDB,
            temperatureFactorMetric: tfMetric,
            hasAllAtomBackbone: pdbMeta.hasFullBackbone,
            chainIDs: pdbMeta.chainIDs.isEmpty ? ["A"] : pdbMeta.chainIDs,
            missingResidueGapCount: pdbMeta.missingResidueGapCount,
            nonStandardResidues: pdbMeta.nonStandardResidues,
            metalIons: pdbMeta.metalIons,
            coCrystalLigands: pdbMeta.coCrystalLigands,
            ligandInstances: ligandInstModels,
            pdbSiteResidues: pdbMeta.siteSeqNums,
            hasAltLocWarning: pdbMeta.hasAltLoc,
            warnings: warnings,
            credibilitySummary: summary
        )
    }

    public static func exportPDB(report: ProteinBiophysicsReport, title: String = "LABWORKER_SPICE_FOLD") -> String {
        var lines: [String] = [
            "HEADER    \(title)",
            "REMARK   1 GENERATED BY LABWORKER NATIVE SPICE & DOCKFLOW WORKBENCH",
            "REMARK   2 COMPOSITE Q-SCORE: \(String(format: "%.2f", report.compositeQScore)) METRIC: \(report.temperatureFactorMetric.rawValue) MEAN: \(String(format: "%.2f", report.meanTemperatureFactor))",
            "REMARK   3 DOCKING BOX CENTER: (\(String(format: "%.2f", report.dockingBox.centerX)), \(String(format: "%.2f", report.dockingBox.centerY)), \(String(format: "%.2f", report.dockingBox.centerZ))) SIZE: (\(String(format: "%.1f", report.dockingBox.sizeX)), \(String(format: "%.1f", report.dockingBox.sizeY)), \(String(format: "%.1f", report.dockingBox.sizeZ)))"
        ]
        if let pocket = report.pockets.first, !pocket.residueIndices.isEmpty {
            let firstGroup = pocket.residueIndices.prefix(4).map { idx -> String in
                let r = report.residues[min(max(0, idx - 1), report.residues.count - 1)]
                let res3Str = r.threeLetter.isEmpty ? "ALA" : String(r.threeLetter.prefix(3))
                let chStr = r.chainID.isEmpty ? "A" : String(r.chainID.prefix(1))
                return String(format: "%3s %1s%4d ", (res3Str as NSString).utf8String!, (chStr as NSString).utf8String!, r.resSeq)
            }.joined(separator: " ")
            lines.append("SITE     1 AC1  \(min(4, pocket.residueIndices.count)) \(firstGroup)")
        }
        var atomSerial = 1
        for r in report.residues {
            let chStr = r.chainID.isEmpty ? "A" : String(r.chainID.prefix(1))
            let res3Str = r.threeLetter.isEmpty ? "ALA" : String(r.threeLetter.prefix(3))
            let ch = (chStr as NSString).utf8String!
            let res3 = (res3Str as NSString).utf8String!
            let tf = r.temperatureFactor
            if let bn = r.backboneN {
                lines.append(String(format: "ATOM  %5d  N   %-3s %1s%4d    %8.3f%8.3f%8.3f  1.00%6.2f           N", atomSerial, res3, ch, r.resSeq, bn.x, bn.y, bn.z, tf))
                atomSerial += 1
            }
            lines.append(String(format: "ATOM  %5d  CA  %-3s %1s%4d    %8.3f%8.3f%8.3f  1.00%6.2f           C", atomSerial, res3, ch, r.resSeq, r.x, r.y, r.z, tf))
            atomSerial += 1
            if let bc = r.backboneC {
                lines.append(String(format: "ATOM  %5d  C   %-3s %1s%4d    %8.3f%8.3f%8.3f  1.00%6.2f           C", atomSerial, res3, ch, r.resSeq, bc.x, bc.y, bc.z, tf))
                atomSerial += 1
            }
            if let bo = r.backboneO {
                lines.append(String(format: "ATOM  %5d  O   %-3s %1s%4d    %8.3f%8.3f%8.3f  1.00%6.2f           O", atomSerial, res3, ch, r.resSeq, bo.x, bo.y, bo.z, tf))
                atomSerial += 1
            }
        }
        lines.append("END")
        return lines.joined(separator: "\n")
    }
}
