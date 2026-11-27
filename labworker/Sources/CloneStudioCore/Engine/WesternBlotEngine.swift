import Foundation
import CoreGraphics
import ImageIO
import AppKit
import Accelerate

// MARK: - 1. WBStudio 16-bit 自动圈定与曝光组模型 (与 Python wbquant JSON 协议 1:1 对齐)

public struct WBRect: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(1, width)
        self.height = max(1, height)
    }

    public var x2: Int { x + width }
    public var y2: Int { y + height }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct WBLane: Codable, Identifiable, Equatable, Sendable {
    public var index: Int
    public var xStart: Int
    public var xEnd: Int
    public var yStart: Int
    public var yEnd: Int
    public var profile: [Double]

    public var id: Int { index }
    public var width: Int { xEnd - xStart }
    public var xCenter: Double { Double(xStart + xEnd) * 0.5 }

    enum CodingKeys: String, CodingKey {
        case index
        case xStart = "x_start"
        case xEnd = "x_end"
        case yStart = "y_start"
        case yEnd = "y_end"
        case profile
    }

    public init(
        index: Int,
        xStart: Int,
        xEnd: Int,
        yStart: Int,
        yEnd: Int,
        profile: [Double]
    ) {
        self.index = index
        self.xStart = xStart
        self.xEnd = xEnd
        self.yStart = yStart
        self.yEnd = yEnd
        self.profile = profile
    }
}

public struct WBBand: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var laneIndex: Int
    public var rowIndex: Int
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var peakY: Int
    public var rawIOD: Double
    public var backgroundIOD: Double
    public var netIOD: Double
    public var normalizedRatio: Double
    public var foldChange: Double
    public var saturatedRatio: Double
    public var isSaturated: Bool
    public var isPrimary: Bool
    public var snr: Double

    enum CodingKeys: String, CodingKey {
        case id
        case laneIndex = "lane_index"
        case rowIndex = "row_index"
        case x, y, width, height
        case peakY = "peak_y"
        case rawIOD = "raw_iod"
        case backgroundIOD = "background_iod"
        case netIOD = "net_iod"
        case normalizedRatio = "normalized_ratio"
        case foldChange = "fold_change"
        case saturatedRatio = "saturated_ratio"
        case isSaturated = "is_saturated"
        case isPrimary = "is_primary"
        case snr
    }

    public init(
        id: String,
        laneIndex: Int,
        rowIndex: Int = 0,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        peakY: Int,
        rawIOD: Double,
        backgroundIOD: Double,
        netIOD: Double,
        normalizedRatio: Double = 1.0,
        foldChange: Double = 1.0,
        saturatedRatio: Double = 0.0,
        isSaturated: Bool = false,
        isPrimary: Bool = true,
        snr: Double = 0.0
    ) {
        self.id = id
        self.laneIndex = laneIndex
        self.rowIndex = rowIndex
        self.x = x
        self.y = y
        self.width = max(4, width)
        self.height = max(4, height)
        self.peakY = peakY
        self.rawIOD = rawIOD
        self.backgroundIOD = backgroundIOD
        self.netIOD = netIOD
        self.normalizedRatio = normalizedRatio
        self.foldChange = foldChange
        self.saturatedRatio = saturatedRatio
        self.isSaturated = isSaturated
        self.isPrimary = isPrimary
        self.snr = snr
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.laneIndex = try c.decode(Int.self, forKey: .laneIndex)
        self.rowIndex = try c.decodeIfPresent(Int.self, forKey: .rowIndex) ?? 0
        self.x = try c.decode(Int.self, forKey: .x)
        self.y = try c.decode(Int.self, forKey: .y)
        self.width = max(4, try c.decode(Int.self, forKey: .width))
        self.height = max(4, try c.decode(Int.self, forKey: .height))
        self.peakY = try c.decode(Int.self, forKey: .peakY)
        self.rawIOD = try c.decode(Double.self, forKey: .rawIOD)
        self.backgroundIOD = try c.decode(Double.self, forKey: .backgroundIOD)
        self.netIOD = try c.decode(Double.self, forKey: .netIOD)
        self.normalizedRatio = try c.decodeIfPresent(Double.self, forKey: .normalizedRatio) ?? 1.0
        self.foldChange = try c.decodeIfPresent(Double.self, forKey: .foldChange) ?? 1.0
        self.saturatedRatio = try c.decodeIfPresent(Double.self, forKey: .saturatedRatio) ?? 0.0
        self.isSaturated = try c.decodeIfPresent(Bool.self, forKey: .isSaturated) ?? false
        self.isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? true
        self.snr = try c.decodeIfPresent(Double.self, forKey: .snr) ?? 0.0
    }
}

public enum WBBgSubtractionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case globalRollingBall = "globalRollingBall"
    case localTrapezoid = "localTrapezoid"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .globalRollingBall: return L10n.t("全局 2D 滚动球去背景 (无二次叠加)")
        case .localTrapezoid:    return L10n.t("局部梯形基线扣除")
        }
    }
}

public struct WBGaussianPeakComponent: Sendable, Equatable {
    public let amplitude: Double
    public let center: Double
    public let sigma: Double
    public let area: Double
    public let fraction: Double
}

public enum WBSaturationPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    case warnOnly = "warnOnly"
    case excludeFromStats = "excludeFromStats"
    
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .warnOnly:         return "仅告警不剔除 (warnOnly)"
        case .excludeFromStats: return "从统计中剔除过曝条带 (excludeFromStats)"
        }
    }
}

public struct WBExcludedBandRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(bandID)|\(laneIndex)" }
    public let bandID: String
    public let laneIndex: Int
    public let groupName: String
    public let reason: String
    
    public init(bandID: String, laneIndex: Int, groupName: String, reason: String) {
        self.bandID = bandID
        self.laneIndex = laneIndex
        self.groupName = groupName
        self.reason = reason
    }
}

public struct WBAnalysisParams: Codable, Equatable, Sendable {
    public var rollingBallRadius: Int
    public var expectedLanes: Int
    public var bandProminence: Double
    public var stripThreshold: Double
    public var autoDeskew: Bool
    public var controlLaneIndex: Int
    public var primaryBandOnly: Bool
    public var saturationPolicy: WBSaturationPolicy
    public var saturationRatioThreshold: Double
    public var backgroundMode: WBBgSubtractionMode
    public var effectiveBitDepthOverride: Int?
    public var linearizeSRGB: Bool

    enum CodingKeys: String, CodingKey {
        case rollingBallRadius = "rolling_ball_radius"
        case expectedLanes = "expected_lanes"
        case bandProminence = "band_prominence"
        case stripThreshold = "strip_threshold"
        case autoDeskew = "auto_deskew"
        case controlLaneIndex = "control_lane_index"
        case primaryBandOnly = "primary_band_only"
        case saturationPolicy = "saturation_policy"
        case saturationRatioThreshold = "saturation_ratio_threshold"
        case backgroundMode = "background_mode"
        case effectiveBitDepthOverride = "effective_bit_depth"
        case linearizeSRGB = "linearize_srgb"
    }

    public init(
        rollingBallRadius: Int = 50,
        expectedLanes: Int = 0,
        bandProminence: Double = 0.12,
        stripThreshold: Double = 0.08,
        autoDeskew: Bool = false,
        controlLaneIndex: Int = 0,
        primaryBandOnly: Bool = true,
        saturationPolicy: WBSaturationPolicy = .excludeFromStats,
        saturationRatioThreshold: Double = 0.01,
        backgroundMode: WBBgSubtractionMode = .globalRollingBall,
        effectiveBitDepthOverride: Int? = nil,
        linearizeSRGB: Bool = false
    ) {
        self.rollingBallRadius = rollingBallRadius
        self.expectedLanes = expectedLanes
        self.bandProminence = bandProminence
        self.stripThreshold = stripThreshold
        self.autoDeskew = autoDeskew
        self.controlLaneIndex = controlLaneIndex
        self.primaryBandOnly = primaryBandOnly
        self.saturationPolicy = saturationPolicy
        self.saturationRatioThreshold = saturationRatioThreshold
        self.backgroundMode = backgroundMode
        self.effectiveBitDepthOverride = effectiveBitDepthOverride
        self.linearizeSRGB = linearizeSRGB
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.rollingBallRadius = try c.decodeIfPresent(Int.self, forKey: .rollingBallRadius) ?? 50
        self.expectedLanes = try c.decodeIfPresent(Int.self, forKey: .expectedLanes) ?? 0
        self.bandProminence = try c.decodeIfPresent(Double.self, forKey: .bandProminence) ?? 0.12
        self.stripThreshold = try c.decodeIfPresent(Double.self, forKey: .stripThreshold) ?? 0.08
        self.autoDeskew = try c.decodeIfPresent(Bool.self, forKey: .autoDeskew) ?? false
        self.controlLaneIndex = try c.decodeIfPresent(Int.self, forKey: .controlLaneIndex) ?? 0
        self.primaryBandOnly = try c.decodeIfPresent(Bool.self, forKey: .primaryBandOnly) ?? true
        self.saturationPolicy = try c.decodeIfPresent(WBSaturationPolicy.self, forKey: .saturationPolicy) ?? .excludeFromStats
        self.saturationRatioThreshold = try c.decodeIfPresent(Double.self, forKey: .saturationRatioThreshold) ?? 0.01
        self.backgroundMode = try c.decodeIfPresent(WBBgSubtractionMode.self, forKey: .backgroundMode) ?? .globalRollingBall
        self.effectiveBitDepthOverride = try c.decodeIfPresent(Int.self, forKey: .effectiveBitDepthOverride)
        self.linearizeSRGB = try c.decodeIfPresent(Bool.self, forKey: .linearizeSRGB) ?? false
    }
}

public struct WBAnalysisResult: Codable, Equatable, Sendable {
    public var imagePath: String
    public var width: Int
    public var height: Int
    public var bitDepth: Int
    public var effectiveBitDepth: Int
    public var isNonlinear8BitWarning: Bool
    public var warnings: [String]
    public var invertedPolarity: Bool
    public var skewAngle: Double
    public var stripROI: WBRect
    public var lanes: [WBLane]
    public var bands: [WBBand]
    public var params: WBAnalysisParams

    enum CodingKeys: String, CodingKey {
        case imagePath = "image_path"
        case width, height
        case bitDepth = "bit_depth"
        case effectiveBitDepth = "effective_bit_depth"
        case isNonlinear8BitWarning = "is_nonlinear_8bit_warning"
        case warnings
        case invertedPolarity = "inverted_polarity"
        case skewAngle = "skew_angle"
        case stripROI = "strip_roi"
        case lanes, bands, params
    }

    public init(
        imagePath: String,
        width: Int,
        height: Int,
        bitDepth: Int,
        invertedPolarity: Bool,
        skewAngle: Double,
        stripROI: WBRect,
        lanes: [WBLane],
        bands: [WBBand],
        params: WBAnalysisParams,
        effectiveBitDepth: Int? = nil,
        isNonlinear8BitWarning: Bool = false,
        warnings: [String] = []
    ) {
        self.imagePath = imagePath
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.effectiveBitDepth = effectiveBitDepth ?? bitDepth
        self.isNonlinear8BitWarning = isNonlinear8BitWarning
        self.warnings = warnings
        self.invertedPolarity = invertedPolarity
        self.skewAngle = skewAngle
        self.stripROI = stripROI
        self.lanes = lanes
        self.bands = bands
        self.params = params
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.imagePath = try c.decode(String.self, forKey: .imagePath)
        self.width = try c.decode(Int.self, forKey: .width)
        self.height = try c.decode(Int.self, forKey: .height)
        self.bitDepth = try c.decode(Int.self, forKey: .bitDepth)
        self.effectiveBitDepth = try c.decodeIfPresent(Int.self, forKey: .effectiveBitDepth) ?? self.bitDepth
        self.isNonlinear8BitWarning = try c.decodeIfPresent(Bool.self, forKey: .isNonlinear8BitWarning) ?? (self.effectiveBitDepth <= 8)
        self.warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        self.invertedPolarity = try c.decode(Bool.self, forKey: .invertedPolarity)
        self.skewAngle = try c.decodeIfPresent(Double.self, forKey: .skewAngle) ?? 0.0
        self.stripROI = try c.decode(WBRect.self, forKey: .stripROI)
        self.lanes = try c.decode([WBLane].self, forKey: .lanes)
        self.bands = try c.decode([WBBand].self, forKey: .bands)
        self.params = try c.decodeIfPresent(WBAnalysisParams.self, forKey: .params) ?? WBAnalysisParams()
    }
}

/// 同批次 WB 曝光样本组 (16-bit 原图 / 发光图 / 明场图 / 叠加图)
public struct WBSampleGroup: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var rawChemi: String?
    public var chemi: String?
    public var brightfield: String?
    public var overlay: String?
    public var primaryQuantPath: String

    enum CodingKeys: String, CodingKey {
        case id, title
        case rawChemi = "raw_chemi"
        case chemi
        case brightfield
        case overlay
        case primaryQuantPath = "primary_quant_path"
    }

    public init(
        id: String,
        title: String,
        rawChemi: String? = nil,
        chemi: String? = nil,
        brightfield: String? = nil,
        overlay: String? = nil,
        primaryQuantPath: String
    ) {
        self.id = id
        self.title = title
        self.rawChemi = rawChemi
        self.chemi = chemi
        self.brightfield = brightfield
        self.overlay = overlay
        self.primaryQuantPath = primaryQuantPath
    }

    public var availableLayers: [(role: String, label: String, icon: String, path: String)] {
        var list: [(String, String, String, String)] = []
        if let p = rawChemi {
            list.append(("raw_chemi", L10n.t("16-bit 原图"), "sparkles.rectangle.stack.fill", p))
        }
        if let p = chemi {
            list.append(("chemi", L10n.t("发光图层"), "rays", p))
        }
        if let p = brightfield {
            list.append(("brightfield", L10n.t("明场图层"), "camera.aperture", p))
        }
        if let p = overlay {
            list.append(("overlay", L10n.t("合成叠加"), "square.3.layers.3d.down.right", p))
        }
        return list
    }
}

// MARK: - 2. 兼容 SPICE_GUI / 分组显著性统计模型 (Target/Loading 双行归一化 + Welch's t 检验)

public enum BlotBackgroundMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case rollingBall = "rollingBall"
    case roiRing = "roiRing"
    case laneMedian = "laneMedian"
    case globalMedian = "globalMedian"
    case manual = "manual"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .rollingBall:  return "Rolling-Ball 曲面扣除"
        case .roiRing:      return "ROI 外环中位数"
        case .laneMedian:   return "泳道背景中位数"
        case .globalMedian: return "整膜全局中位数"
        case .manual:       return "手动指定背景"
        }
    }
}

public enum BlotNormalizationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case loadingControl = "loadingControl"
    case totalLane = "totalLane"
    case rawVolume = "rawVolume"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .loadingControl: return "内参比值 (Target/Loading)"
        case .totalLane:      return "泳道总蛋白"
        case .rawVolume:      return "原始净灰度 (Net IOD)"
        }
    }
}

public struct BlotBandROI: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var proteinName: String
    public var isLoadingControl: Bool
    public var centerY: Double
    public var widthFrac: Double
    public var heightFrac: Double
    
    public init(
        id: String = UUID().uuidString,
        proteinName: String,
        isLoadingControl: Bool,
        centerY: Double,
        widthFrac: Double = 0.085,
        heightFrac: Double = 0.11
    ) {
        self.id = id
        self.proteinName = proteinName
        self.isLoadingControl = isLoadingControl
        self.centerY = centerY
        self.widthFrac = widthFrac
        self.heightFrac = heightFrac
    }
}

public struct BlotLaneModel: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var index: Int
    public var sampleName: String
    public var groupName: String
    public var centerX: Double
    public var widthFrac: Double
    public var bands: [BlotBandROI]
    public var included: Bool
    
    public init(
        id: String = UUID().uuidString,
        index: Int,
        sampleName: String,
        groupName: String,
        centerX: Double,
        widthFrac: Double = 0.09,
        bands: [BlotBandROI],
        included: Bool = true
    ) {
        self.id = id
        self.index = index
        self.sampleName = sampleName
        self.groupName = groupName
        self.centerX = centerX
        self.widthFrac = widthFrac
        self.bands = bands
        self.included = included
    }
}

public struct BlotLaneQuantRow: Identifiable, Sendable {
    public var id: String { laneID }
    public let laneID: String
    public let laneIndex: Int
    public let sampleName: String
    public let groupName: String
    public let targetNetVolume: Double
    public let loadingNetVolume: Double
    public let targetBackground: Double
    public let normalizedRatio: Double
    public let foldChange: Double
    public let isSaturated: Bool
    public let clippedPct: Double
}

public struct BlotGroupStatSummary: Identifiable, Sendable {
    public var id: String { groupName }
    public let groupName: String
    public let n: Int
    public let nExcludedSaturated: Int
    /// 几何均值倍数 2^(mean(log2(fold)))，与 log2 空间检验严格一致
    public let meanFold: Double
    public let sdFold: Double?
    public let semFold: Double?
    public let pValue: Double?
    public let pAdjusted: Double?
    public let log2MeanFold: Double?
    public let foldCI95Low: Double?
    public let foldCI95High: Double?
    public let isControl: Bool
    public let values: [Double]
    
    public init(
        groupName: String,
        n: Int,
        nExcludedSaturated: Int = 0,
        meanFold: Double,
        sdFold: Double?,
        semFold: Double?,
        pValue: Double?,
        pAdjusted: Double? = nil,
        log2MeanFold: Double? = nil,
        foldCI95Low: Double? = nil,
        foldCI95High: Double? = nil,
        isControl: Bool,
        values: [Double]
    ) {
        self.groupName = groupName
        self.n = n
        self.nExcludedSaturated = nExcludedSaturated
        self.meanFold = meanFold
        self.sdFold = sdFold
        self.semFold = semFold
        self.pValue = pValue
        self.pAdjusted = pAdjusted
        self.log2MeanFold = log2MeanFold
        self.foldCI95Low = foldCI95Low
        self.foldCI95High = foldCI95High
        self.isControl = isControl
        self.values = values
    }
    
    public var significanceText: String {
        guard let p = pAdjusted ?? pValue else { return isControl ? "Ref" : "—" }
        if p < 0.001 { return "***" }
        if p < 0.01  { return "**" }
        if p < 0.05  { return "*" }
        return "ns"
    }
}

public struct BlotQuantificationOut: Sendable {
    public let laneRows: [BlotLaneQuantRow]
    public let groupStats: [BlotGroupStatSummary]
    public let groups: [String]
    public let controlGroup: String
    public let globalBackground: Double
    public let saturationPolicy: WBSaturationPolicy
    public let excludedBands: [WBExcludedBandRecord]
    public let anovaLog2: PlateReaderAssayEngine.OneWayANOVAResult?
    public let postHocMethod: ViabilityPostHocMethod
    
    public init(
        laneRows: [BlotLaneQuantRow],
        groupStats: [BlotGroupStatSummary],
        groups: [String],
        controlGroup: String,
        globalBackground: Double,
        saturationPolicy: WBSaturationPolicy = .excludeFromStats,
        excludedBands: [WBExcludedBandRecord] = [],
        anovaLog2: PlateReaderAssayEngine.OneWayANOVAResult? = nil,
        postHocMethod: ViabilityPostHocMethod = .welchHolm
    ) {
        self.laneRows = laneRows
        self.groupStats = groupStats
        self.groups = groups
        self.controlGroup = controlGroup
        self.globalBackground = globalBackground
        self.saturationPolicy = saturationPolicy
        self.excludedBands = excludedBands
        self.anovaLog2 = anovaLog2
        self.postHocMethod = postHocMethod
    }
}

// MARK: - 3. Western Blot 双引擎核心算法 (原生 16-bit Rolling-Ball 圈定 + Python wbquant / pyqtgraph 协同)

public enum WesternBlotEngine {
    
    // MARK: 3.1 路径解析与双引擎探测
    
    public static var defaultSamplesDirectory: URL {
        let projRoot = CloneStudioResourceLocator.projectRootDirectory
        let candidates = [
            projRoot.appendingPathComponent("Samples/WB").path,
            projRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wb").path
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
    
    public static var wbquantPythonRoot: URL {
        let projRoot = CloneStudioResourceLocator.projectRootDirectory
        let siblingWB = projRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wb")
        let candidates = [
            projRoot.path,
            siblingWB.path
        ]
        for path in candidates {
            let cli = URL(fileURLWithPath: path).appendingPathComponent("python/wbquant/cli.py")
            if FileManager.default.fileExists(atPath: cli.path) {
                return URL(fileURLWithPath: path)
            }
        }
        return projRoot
    }
    
    public static var pythonExecutablePath: String {
        let projRoot = CloneStudioResourceLocator.projectRootDirectory
        let siblingWB = projRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wb")
        let venvCandidates = [
            siblingWB.appendingPathComponent(".venv/bin/python3").path,
            wbquantPythonRoot.appendingPathComponent(".venv/bin/python3").path,
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3"
        ]
        for py in venvCandidates where FileManager.default.isExecutableFile(atPath: py) {
            return py
        }
        return "/usr/bin/python3"
    }
    
    public static var isPythonEngineReady: Bool {
        let cliPath = wbquantPythonRoot.appendingPathComponent("python/wbquant/cli.py").path
        let siblingWB = CloneStudioResourceLocator.projectRootDirectory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wb")
        let venvPy = siblingWB.appendingPathComponent(".venv/bin/python3").path
        return FileManager.default.fileExists(atPath: cliPath)
            && FileManager.default.isExecutableFile(atPath: venvPy)
    }
    
    // MARK: 3.2 扫描目录并自动配对同批次曝光图像 (16-bit 原图 / 发光图 / 明场图 / 叠加图)
    
    public static func discoverSampleGroups(in directory: URL? = nil) -> [WBSampleGroup] {
        let targetDir = directory ?? defaultSamplesDirectory
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: targetDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        let validExts: Set<String> = ["tif", "tiff", "png", "jpg", "jpeg"]
        let files = urls
            .filter { validExts.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("参考") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        
        let rolePatterns: [(role: String, suffix: String)] = [
            ("raw_chemi", "_原始文件_发光图"),
            ("chemi", "_发光图"),
            ("brightfield", "_明场图"),
            ("overlay", "_叠加图")
        ]
        
        var dict: [String: (title: String, raw: String?, chemi: String?, bf: String?, ov: String?)] = [:]
        var orderedKeys: [String] = []
        
        for url in files {
            let stem = url.deletingPathExtension().lastPathComponent
            var matchedRole = "chemi"
            var baseKey = stem
            for (role, suffix) in rolePatterns where stem.hasSuffix(suffix) {
                matchedRole = role
                baseKey = String(stem.dropLast(suffix.count))
                break
            }
            if dict[baseKey] == nil {
                orderedKeys.append(baseKey)
                dict[baseKey] = (formatGroupTitle(baseKey), nil, nil, nil, nil)
            }
            var entry = dict[baseKey]!
            switch matchedRole {
            case "raw_chemi": entry.raw = url.path
            case "chemi": entry.chemi = url.path
            case "brightfield": entry.bf = url.path
            case "overlay": entry.ov = url.path
            default: entry.chemi = url.path
            }
            dict[baseKey] = entry
        }
        
        return orderedKeys.compactMap { key -> WBSampleGroup? in
            guard let item = dict[key],
                  let primary = item.raw ?? item.chemi ?? item.ov ?? item.bf else { return nil }
            return WBSampleGroup(
                id: key,
                title: item.title,
                rawChemi: item.raw,
                chemi: item.chemi,
                brightfield: item.bf,
                overlay: item.ov,
                primaryQuantPath: primary
            )
        }
    }
    
    private static func formatGroupTitle(_ baseKey: String) -> String {
        let parts = baseKey.split(separator: "_")
        if parts.count >= 3 {
            let target = parts[0].uppercased()
            let dateStr = String(parts[1])
            let timeStr = String(parts[2])
            if dateStr.count == 8, timeStr.count >= 4 {
                let mm = dateStr.dropFirst(4).prefix(2)
                let dd = dateStr.dropFirst(6).prefix(2)
                let hh = timeStr.prefix(2)
                let min = timeStr.dropFirst(2).prefix(2)
                return "\(target) · \(mm)/\(dd) \(hh):\(min)"
            }
        }
        return baseKey
    }
    
    // MARK: 3.3 16-bit / 8-bit 原始图像无损读取与独立显影映射
    
    public struct RawGrayBuffer16: Sendable {
        public let width: Int
        public let height: Int
        public let bitDepth: Int
        public let effectiveBitDepth: Int
        public let saturationCeiling: Double
        public let isNonlinear8BitWarning: Bool
        public let invertedPolarity: Bool
        /// 已统一为暗背景亮信号的浮点信号强度矩阵 (height * width)
        public let signal: [Double]
        /// 过曝/截断掩膜 (height * width)
        public let saturated: [Bool]
        
        public init(
            width: Int,
            height: Int,
            bitDepth: Int,
            invertedPolarity: Bool,
            signal: [Double],
            saturated: [Bool],
            effectiveBitDepth: Int? = nil,
            saturationCeiling: Double? = nil,
            isNonlinear8BitWarning: Bool? = nil
        ) {
            self.width = width
            self.height = height
            self.bitDepth = bitDepth
            let eff = effectiveBitDepth ?? bitDepth
            self.effectiveBitDepth = eff
            self.saturationCeiling = saturationCeiling ?? Double((1 << eff) - 1)
            self.isNonlinear8BitWarning = isNonlinear8BitWarning ?? (eff <= 8)
            self.invertedPolarity = invertedPolarity
            self.signal = signal
            self.saturated = saturated
        }
    }
    
    /// 识别真实有效位深与饱和天花板（严格遵循 TIFF 元数据/显式覆盖，严禁将 uint16 降级为 8-bit，仅在多像素精准钉死 4095/16383 时推断 12/14-bit）
    public static func detectEffectiveBitDepth(
        rawValues: [Double],
        containerBitDepth: Int,
        override: Int? = nil,
        metadataMaxSampleValue: Int? = nil
    ) -> (effectiveBitDepth: Int, ceiling: Double) {
        if let ov = override, [8, 12, 14, 16].contains(ov) {
            return (ov, Double((1 << ov) - 1))
        }
        if containerBitDepth <= 8 {
            return (8, 255.0)
        }
        if let maxTag = metadataMaxSampleValue {
            if maxTag == 4095 { return (12, 4095.0) }
            if maxTag == 16383 { return (14, 16383.0) }
            if maxTag >= 65535 { return (16, 65535.0) }
        }
        // 绝不将 16-bit 容器降级为 8-bit 非线性 sRGB；仅当多像素精准钉死在 4095 或 16383 硬截断边界时推断 12/14-bit
        let vmax = rawValues.max() ?? 0.0
        if abs(vmax - 4095.0) <= 0.5 {
            let pinned = rawValues.reduce(0) { $0 + ((abs($1 - 4095.0) <= 0.5) ? 1 : 0) }
            if pinned >= 3 { return (12, 4095.0) }
        }
        if abs(vmax - 16383.0) <= 0.5 {
            let pinned = rawValues.reduce(0) { $0 + ((abs($1 - 16383.0) <= 0.5) ? 1 : 0) }
            if pinned >= 3 { return (14, 16383.0) }
        }
        return (16, 65535.0)
    }
    
    /// IEC 61966-2-1 标准 8-bit sRGB 反 Gamma 线性化（输出仍在 0..255 量纲）
    public static func linearizeSRGBValue(_ v: Double) -> Double {
        let u = min(1.0, max(0.0, v / 255.0))
        let lin = (u <= 0.04045) ? (u / 12.92) : pow((u + 0.055) / 1.055, 2.4)
        return lin * 255.0
    }
    
    /// 无损读取 16-bit 或 8-bit 原始 TIFF/PNG 灰度数据并识别真实位深、可选反 sRGB 线性化与稳健极性标准化
    public static func loadRawGrayBuffer(
        at path: String,
        effectiveBitDepthOverride: Int? = nil,
        linearizeSRGB: Bool = false
    ) -> RawGrayBuffer16? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        let w = cgImg.width
        let h = cgImg.height
        guard w > 0, h > 0 else { return nil }
        let bpc = cgImg.bitsPerComponent
        let is16Bit = (bpc > 8)
        var metaMaxSample: Int? = nil
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any], 
           let tiff = props[kCGImagePropertyTIFFDictionary] as? [String: Any] {
            if let mv = tiff["MaxSampleValue"] as? Int { metaMaxSample = mv }
        }
        
        if is16Bit {
            var buf16 = [UInt16](repeating: 0, count: w * h)
            let graySpace = CGColorSpaceCreateDeviceGray()
            let bitmapInfo = CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            let ok = buf16.withUnsafeMutableBytes { ptr -> Bool in
                guard let ctx = CGContext(
                    data: ptr.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 16,
                    bytesPerRow: w * 2,
                    space: graySpace,
                    bitmapInfo: bitmapInfo
                ) else { return false }
                ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            return buildStandardizedBuffer(
                rawValues: buf16.map { Double($0) },
                width: w,
                height: h,
                bitDepth: 16,
                effectiveBitDepthOverride: effectiveBitDepthOverride,
                linearizeSRGB: linearizeSRGB,
                metadataMaxSampleValue: metaMaxSample
            )
        } else {
            var buf8 = [UInt8](repeating: 0, count: w * h)
            let graySpace = CGColorSpaceCreateDeviceGray()
            let bitmapInfo = CGImageAlphaInfo.none.rawValue
            let ok = buf8.withUnsafeMutableBytes { ptr -> Bool in
                guard let ctx = CGContext(
                    data: ptr.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w,
                    space: graySpace,
                    bitmapInfo: bitmapInfo
                ) else { return false }
                ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            return buildStandardizedBuffer(
                rawValues: buf8.map { Double($0) },
                width: w,
                height: h,
                bitDepth: 8,
                effectiveBitDepthOverride: effectiveBitDepthOverride,
                linearizeSRGB: linearizeSRGB,
                metadataMaxSampleValue: metaMaxSample
            )
        }
    }
    
    /// 从内存 `BioImagePlane` 构建标准化定量缓冲（用于内置示范膜或直接拖入图像）
    public static func bufferFromBioImagePlane(_ plane: BioImagePlane, linearizeSRGB: Bool = false) -> RawGrayBuffer16 {
        let rawVals = plane.gray.map { Double($0) }
        return buildStandardizedBuffer(
            rawValues: rawVals,
            width: plane.width,
            height: plane.height,
            bitDepth: 8,
            effectiveBitDepthOverride: nil,
            linearizeSRGB: linearizeSRGB
        )
    }
    
    /// 从原始灰度数组构建标准化缓冲（先在原始像素空间完成极性判定，再执行可选 8-bit 反 sRGB 线性化）
    public static func buildStandardizedBuffer(
        rawValues: [Double],
        width: Int,
        height: Int,
        bitDepth: Int,
        effectiveBitDepthOverride: Int? = nil,
        linearizeSRGB: Bool = false,
        metadataMaxSampleValue: Int? = nil
    ) -> RawGrayBuffer16 {
        let n = rawValues.count
        guard n > 0 else {
            return RawGrayBuffer16(width: width, height: height, bitDepth: bitDepth, invertedPolarity: false, signal: [], saturated: [])
        }
        let (effBD, nominalCeiling) = detectEffectiveBitDepth(
            rawValues: rawValues,
            containerBitDepth: bitDepth,
            override: effectiveBitDepthOverride,
            metadataMaxSampleValue: metadataMaxSampleValue
        )
        let isNonlinear8 = (effBD <= 8)
        
        // 在原始像素空间判定明/暗底极性（避免 sRGB 反 Gamma 压缩白底背景后误判；且外框全零时不以高亮带中位数冒充背景）
        let bw = max(2, Int(round(Double(width) * 0.08)))
        let bh = max(2, Int(round(Double(height) * 0.08)))
        var borderNZ: [Double] = []
        for y in 0..<height {
            let edgeY = (y < bh || y >= height - bh)
            for x in 0..<width {
                if edgeY || x < bw || x >= width - bw {
                    let v = rawValues[y * width + x]
                    if v > 0.0 { borderNZ.append(v) }
                }
            }
        }
        let inverted: Bool = {
            // 若外框 8% 几乎全零（zero-padded 暗场膜），外框背景为暗底 0，直接判为暗底亮带（不翻转）
            guard borderNZ.count >= 8 else { return false }
            var nzVals: [Double] = []
            let sampleStep = max(1, n / 8192)
            nzVals.reserveCapacity(min(n, 8192))
            for i in stride(from: 0, to: n, by: sampleStep) where rawValues[i] > 0.0 {
                nzVals.append(rawValues[i])
            }
            if nzVals.count < 16 {
                nzVals = rawValues.filter { $0 > 0.0 }
            }
            guard nzVals.count >= 16 else { return false }
            let sortedNZ = nzVals.sorted()
            let p01 = sortedNZ[Int(Double(sortedNZ.count - 1) * 0.01)]
            let p99 = sortedNZ[Int(Double(sortedNZ.count - 1) * 0.99)]
            let span = p99 - p01
            guard span > 1e-9 else { return false }
            
            let borderMed = median(borderNZ)
            var hist = [Int](repeating: 0, count: 256)
            for v in sortedNZ where v >= p01 && v <= p99 {
                let bin = min(255, max(0, Int(((v - p01) / span) * 255.0)))
                hist[bin] += 1
            }
            var modeBin = 0
            var modeCnt = -1
            for b in 0..<256 where hist[b] > modeCnt {
                modeCnt = hist[b]
                modeBin = b
            }
            let modeVal = p01 + (Double(modeBin) + 0.5) / 256.0 * span
            let mid = p01 + 0.5 * span
            return (modeVal > mid) && (borderMed > mid)
        }()
        
        // 仅对 8-bit 图像在极性判定之后执行 IEC 61966-2-1 反 sRGB 线性化
        let workingVals: [Double] = (isNonlinear8 && linearizeSRGB) ? rawValues.map { linearizeSRGBValue($0) } : rawValues
        let maxRaw = workingVals.max() ?? 0.0
        let ceiling = maxRaw <= nominalCeiling ? nominalCeiling : maxRaw
        
        // 依据真实有效位深设定精准饱和阈值（12/14-bit 严禁放宽至 4085/16350）
        let loCut: Double
        let hiCut: Double
        switch effBD {
        case 16: loCut = 15.0; hiCut = 65400.0
        case 14: loCut = 1.0;  hiCut = 16382.5
        case 12: loCut = 1.0;  hiCut = 4094.5
        default: loCut = 1.0;  hiCut = 254.0
        }
        
        var signal = [Double](repeating: 0, count: n)
        var sat = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let wv = workingVals[i]
            let rv = rawValues[i]
            signal[i] = inverted ? max(0.0, ceiling - wv) : max(0.0, wv)
            sat[i] = inverted ? (rv <= loCut) : (rv >= min(hiCut, nominalCeiling))
        }
        return RawGrayBuffer16(
            width: width,
            height: height,
            bitDepth: bitDepth,
            invertedPolarity: inverted,
            signal: signal,
            saturated: sat,
            effectiveBitDepth: effBD,
            saturationCeiling: nominalCeiling,
            isNonlinear8BitWarning: isNonlinear8
        )
    }
    
    /// 16-bit / 8-bit 图像归一化渲染（供 SwiftUI 画布显示，绝不修改底层定量原图）
    /// 统计 `RawGrayBuffer16` 中饱和像素数量（以及启用遮罩时着色的红色饱和像素数）
    public static func countSaturatedMaskPixels(in buf: RawGrayBuffer16) -> Int {
        buf.saturated.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
    
    public static func renderDisplayImage(
        at path: String,
        invertToWhiteBackground: Bool = true,
        contrastBoost: Double = 1.0,
        gamma: Double = 1.0,
        showSaturatedMask: Bool = false
    ) -> NSImage? {
        guard let buf = loadRawGrayBuffer(at: path) else {
            return NSImage(contentsOfFile: path)
        }
        return renderDisplayImage(
            from: buf,
            invertToWhiteBackground: invertToWhiteBackground,
            contrastBoost: contrastBoost,
            gamma: gamma,
            showSaturatedMask: showSaturatedMask
        )
    }
    
    public static func renderDisplayImage(
        from buf: RawGrayBuffer16,
        invertToWhiteBackground: Bool = true,
        contrastBoost: Double = 1.0,
        gamma: Double = 1.0,
        showSaturatedMask: Bool = false
    ) -> NSImage? {
        let w = buf.width
        let h = buf.height
        guard w > 0, h > 0, buf.signal.count == w * h else { return nil }
        let maxSig = max(1.0, buf.signal.max() ?? 1.0)
        let effGamma = max(0.25, min(3.0, gamma))
        let effContrast = max(0.5, min(4.0, contrastBoost))
        
        if showSaturatedMask && buf.saturated.count == w * h {
            var outRGBA = [UInt8](repeating: 255, count: w * h * 4)
            for i in 0..<(w * h) {
                let normSig = min(1.0, max(0.0, buf.signal[i] / maxSig))
                let boosted = min(1.0, max(0.0, pow(normSig * effContrast, effGamma)))
                let displayVal = invertToWhiteBackground ? (1.0 - boosted) : boosted
                let gray = UInt8(clamping: Int((displayVal * 255.0).rounded()))
                let baseIdx = i * 4
                if buf.saturated[i] {
                    // 在图像渲染层直接将饱和像素合成为半透明鲜红色 (65% Red + 35% Gray)
                    outRGBA[baseIdx]     = UInt8(clamping: Int(Double(gray) * 0.35 + 255.0 * 0.65))
                    outRGBA[baseIdx + 1] = UInt8(clamping: Int(Double(gray) * 0.35 + 36.0 * 0.65))
                    outRGBA[baseIdx + 2] = UInt8(clamping: Int(Double(gray) * 0.35 + 48.0 * 0.65))
                    outRGBA[baseIdx + 3] = 255
                } else {
                    outRGBA[baseIdx]     = gray
                    outRGBA[baseIdx + 1] = gray
                    outRGBA[baseIdx + 2] = gray
                    outRGBA[baseIdx + 3] = 255
                }
            }
            let rgbSpace = CGColorSpaceCreateDeviceRGB()
            guard let provider = CGDataProvider(data: Data(outRGBA) as CFData),
                  let outCG = CGImage(
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: w * 4,
                    space: rgbSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) else {
                return nil
            }
            return NSImage(cgImage: outCG, size: NSSize(width: w, height: h))
        }
        
        var outU8 = [UInt8](repeating: 255, count: w * h)
        for i in 0..<(w * h) {
            let normSig = min(1.0, max(0.0, buf.signal[i] / maxSig))
            let boosted = min(1.0, max(0.0, pow(normSig * effContrast, effGamma)))
            let displayVal = invertToWhiteBackground ? (1.0 - boosted) : boosted
            outU8[i] = UInt8(clamping: Int((displayVal * 255.0).rounded()))
        }
        let graySpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(outU8) as CFData),
              let outCG = CGImage(
                width: w,
                height: h,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: w,
                space: graySpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return NSImage(cgImage: outCG, size: NSSize(width: w, height: h))
    }
    
    // MARK: 3.4 原生 + Python 双引擎自动圈定与光密度积分管线
    
    /// 自动分析指定路径的 WB 图像（优先使用 Python wbquant 科学引擎，若环境未就绪则无缝切换至纯 Swift 16-bit 原生圈定引擎）
    public static func analyze(
        imagePath: String,
        params: WBAnalysisParams = WBAnalysisParams(),
        customROI: WBRect? = nil,
        preferNative: Bool = false,
        outCSV: String? = nil,
        outJSON: String? = nil,
        outPNG: String? = nil
    ) -> WBAnalysisResult? {
        if !preferNative && isPythonEngineReady {
            var args: [String] = [
                "analyze",
                imagePath,
                "--lanes", "\(params.expectedLanes)",
                "--radius", "\(params.rollingBallRadius)",
                "--prominence", String(format: "%.3f", params.bandProminence),
                "--threshold", String(format: "%.3f", params.stripThreshold),
                "--control-lane", "\(params.controlLaneIndex)",
                "--bg-mode", params.backgroundMode.rawValue,
                "--saturation-threshold", String(format: "%.4f", params.saturationRatioThreshold)
            ]
            if let bd = params.effectiveBitDepthOverride {
                args.append(contentsOf: ["--bit-depth", "\(bd)"])
            }
            if params.linearizeSRGB {
                args.append("--linearize-srgb")
            }
            if !params.primaryBandOnly {
                args.append("--all-bands")
            }
            if params.autoDeskew {
                args.append("--deskew")
            }
            if let roi = customROI {
                args.append(contentsOf: ["--roi", "\(roi.x),\(roi.y),\(roi.width),\(roi.height)"])
            }
            if let csv = outCSV {
                args.append(contentsOf: ["--out-csv", csv])
            }
            if let js = outJSON {
                args.append(contentsOf: ["--out-json", js])
            }
            if let png = outPNG {
                args.append(contentsOf: ["--out-png", png])
            }
            if let data = runPythonCLI(arguments: args),
               let result = try? JSONDecoder().decode(WBAnalysisResult.self, from: data) {
                return result
            }
        }
        return analyzeNative16Bit(imagePath: imagePath, params: params, customROI: customROI)
    }
    
    /// 纯 Swift 原生 16-bit 自动圈定管线（真 2D 半球面滚动球、同步饱和掩膜倾斜校正、单次去背景与四边收紧圈定）
    public static func analyzeNative16Bit(
        imagePath: String,
        params: WBAnalysisParams = WBAnalysisParams(),
        customROI: WBRect? = nil
    ) -> WBAnalysisResult? {
        guard let buf = loadRawGrayBuffer(
            at: imagePath,
            effectiveBitDepthOverride: params.effectiveBitDepthOverride,
            linearizeSRGB: params.linearizeSRGB
        ) else { return nil }
        return analyzeNativeBuffer(buf, imagePath: imagePath, params: params, customROI: customROI)
    }
    
    public static func analyzeNativeBuffer(
        _ buf: RawGrayBuffer16,
        imagePath: String = "Synthetic_WB_Membrane.tif",
        params: WBAnalysisParams = WBAnalysisParams(),
        customROI: WBRect? = nil
    ) -> WBAnalysisResult {
        let w = buf.width
        let h = buf.height
        
        var warnings: [String] = []
        if buf.isNonlinear8BitWarning {
            if params.linearizeSRGB {
                warnings.append(L10n.tr(
                    "已对 8-bit 图像执行 sRGB 反 Gamma 线性化；发表级科研定量仍建议优先导出原始 16-bit 线性 TIFF。",
                    "Applied inverse sRGB gamma linearization to 8-bit image; raw 16-bit linear TIFF is recommended for publication-grade quantification."
                ))
            } else {
                warnings.append(L10n.tr(
                    "检测到 8-bit 非线性潜在 sRGB/Gamma 编码图像，定量线性度受限；建议使用原始 16-bit TIFF 或开启反 Gamma 线性化。",
                    "Detected 8-bit potentially gamma-encoded (sRGB) image with limited linearity; use raw 16-bit TIFF or enable inverse sRGB linearization."
                ))
            }
        }
        
        var workingSignal = buf.signal
        var workingSat = buf.saturated
        
        // 1. 去背景模式二选一（严禁全局 Rolling-Ball 与局部基线双重叠加）：返回有符号净信号消除噪声整流偏置
        var correctedSigned: [Double]
        if params.backgroundMode == .localTrapezoid {
            correctedSigned = workingSignal
        } else {
            correctedSigned = subtractRollingBallNative(signal: workingSignal, width: w, height: h, radius: params.rollingBallRadius, intensityRange: nil).signedNet
        }
        var correctedDetect = correctedSigned.map { max(0.0, $0) }
        
        // 2. 有效膜条区域（Active Strip ROI）自适应定位
        var stripROI = customROI ?? detectStripROINative(signal: correctedDetect, width: w, height: h, thresholdRatio: params.stripThreshold)
        
        // 3. 可选倾斜校正：同步旋转原信号、去背景信号与饱和像素掩膜（避免过曝坐标错位）
        var skewAngle = 0.0
        if params.autoDeskew {
            skewAngle = estimateSkewAngleNative(signal: correctedDetect, width: w, height: h, roi: stripROI)
            if abs(skewAngle) >= 0.25 {
                workingSignal = deskewImageNative(workingSignal, width: w, height: h, angleDegrees: skewAngle, clipNegative: true)
                correctedSigned = deskewImageNative(correctedSigned, width: w, height: h, angleDegrees: skewAngle, clipNegative: false)
                correctedDetect = correctedSigned.map { max(0.0, $0) }
                workingSat = deskewMaskNative(workingSat, width: w, height: h, angleDegrees: skewAngle)
                if customROI == nil {
                    stripROI = detectStripROINative(signal: correctedDetect, width: w, height: h, thresholdRatio: params.stripThreshold)
                }
            }
        }
        
        // 4. 波谷列投影划分泳道并计算高斯加权行剖面
        let lanes = detectLanesNative(signal: correctedDetect, width: w, height: h, stripROI: stripROI, expectedLanes: params.expectedLanes)
        
        // 5. 在每条泳道内寻峰并执行上下左右四边自适应收紧与跨泳道同行聚类对齐
        let rawDetections = detectBandsInLanesNative(signal: correctedDetect, width: w, height: h, lanes: lanes, params: params)
        let aligned = alignBandRowsNative(detections: rawDetections, rowTolerance: max(12, stripROI.height / 14))
        
        // 6. 单次去背景有符号净积分、信噪比、过曝占比与相对对照 Fold Change
        let bands = quantifyAlignedBandsNative(
            rawSignal: workingSignal,
            correctedSignal: correctedSigned,
            saturatedMask: workingSat,
            width: w,
            height: h,
            alignedBoxes: aligned,
            controlLaneIndex: params.controlLaneIndex,
            saturationRatioThreshold: params.saturationRatioThreshold,
            backgroundMode: params.backgroundMode
        )
        
        return WBAnalysisResult(
            imagePath: imagePath,
            width: w,
            height: h,
            bitDepth: buf.bitDepth,
            invertedPolarity: buf.invertedPolarity,
            skewAngle: skewAngle,
            stripROI: stripROI,
            lanes: lanes,
            bands: bands,
            params: params,
            effectiveBitDepth: buf.effectiveBitDepth,
            isNonlinear8BitWarning: buf.isNonlinear8BitWarning,
            warnings: warnings
        )
    }
    
    /// 手动拖拽平移或拉伸圈定框后毫秒级重算精确 IOD（与主分析共享同一倾斜角与饱和掩膜变换）
    public static func requantify(
        imagePath: String,
        bands: [WBBand],
        params: WBAnalysisParams,
        fallbackBuffer: RawGrayBuffer16? = nil,
        skewAngle: Double = 0.0
    ) -> [WBBand] {
        if isPythonEngineReady && FileManager.default.fileExists(atPath: imagePath) {
            let payload = bands.map { b -> [String: Int] in
                [
                    "lane_index": b.laneIndex,
                    "row_index": b.rowIndex,
                    "x": b.x,
                    "y": b.y,
                    "width": b.width,
                    "height": b.height,
                    "peak_y": b.peakY
                ]
            }
            if let jsonBytes = try? JSONSerialization.data(withJSONObject: payload),
               let jsonStr = String(data: jsonBytes, encoding: .utf8) {
                var args = [
                    "requantify",
                    imagePath,
                    "--boxes-json", jsonStr,
                    "--radius", "\(params.rollingBallRadius)",
                    "--control-lane", "\(params.controlLaneIndex)",
                    "--bg-mode", params.backgroundMode.rawValue,
                    "--saturation-threshold", String(format: "%.4f", params.saturationRatioThreshold),
                    "--skew-angle", String(format: "%.3f", skewAngle)
                ]
                if params.autoDeskew { args.append("--deskew") }
                if let bd = params.effectiveBitDepthOverride { args.append(contentsOf: ["--bit-depth", "\(bd)"]) }
                if params.linearizeSRGB { args.append("--linearize-srgb") }
                if let data = runPythonCLI(arguments: args),
                   let updated = try? JSONDecoder().decode([WBBand].self, from: data) {
                    return updated
                }
            }
        }
        
        guard let buf = loadRawGrayBuffer(
            at: imagePath,
            effectiveBitDepthOverride: params.effectiveBitDepthOverride,
            linearizeSRGB: params.linearizeSRGB
        ) ?? fallbackBuffer else {
            return bands
        }
        var workingSignal = buf.signal
        var workingSat = buf.saturated
        var correctedSigned = (params.backgroundMode == .localTrapezoid)
            ? workingSignal
            : subtractRollingBallNative(signal: workingSignal, width: buf.width, height: buf.height, radius: params.rollingBallRadius, intensityRange: nil).signedNet
        
        var effAngle = skewAngle
        if abs(effAngle) < 0.25 && params.autoDeskew {
            let det = correctedSigned.map { max(0.0, $0) }
            let roi = detectStripROINative(signal: det, width: buf.width, height: buf.height, thresholdRatio: params.stripThreshold)
            effAngle = estimateSkewAngleNative(signal: det, width: buf.width, height: buf.height, roi: roi)
        }
        if abs(effAngle) >= 0.25 {
            workingSignal = deskewImageNative(workingSignal, width: buf.width, height: buf.height, angleDegrees: effAngle, clipNegative: true)
            correctedSigned = deskewImageNative(correctedSigned, width: buf.width, height: buf.height, angleDegrees: effAngle, clipNegative: false)
            workingSat = deskewMaskNative(workingSat, width: buf.width, height: buf.height, angleDegrees: effAngle)
        }
        
        let aligned = bands.map { b in
            (b.laneIndex, b.rowIndex, b.x, b.y, b.width, b.height, b.peakY)
        }
        return quantifyAlignedBandsNative(
            rawSignal: workingSignal,
            correctedSignal: correctedSigned,
            saturatedMask: workingSat,
            width: buf.width,
            height: buf.height,
            alignedBoxes: aligned,
            controlLaneIndex: params.controlLaneIndex,
            saturationRatioThreshold: params.saturationRatioThreshold,
            backgroundMode: params.backgroundMode
        )
    }
    
    /// 启动独立 PySide6 + pyqtgraph 科学密度视窗
    public static func launchPyQtGraphWorkbench(imagePath: String, params: WBAnalysisParams) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonExecutablePath)
        proc.currentDirectoryURL = wbquantPythonRoot
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = wbquantPythonRoot.appendingPathComponent("python").path
        proc.environment = env
        proc.arguments = [
            "-m", "wbquant.cli",
            "qt", imagePath,
            "--lanes", "\(params.expectedLanes)",
            "--radius", "\(params.rollingBallRadius)"
        ]
        try? proc.run()
    }
    
    // MARK: - 3.5 原生 16-bit 真 2D 半球面 Rolling-Ball (Sternberg 1983)、抗混叠降采样与同步倾斜校正
    
    /// 线性插值百分位计算（大图像采用确定性等步长采样，与 numpy.percentile 严格对齐）
    private static func sampledPercentile(_ values: [Double], q: Double) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted: [Double]
        if values.count <= 250_000 {
            sorted = values.sorted()
        } else {
            let step = max(1, values.count / 100_000)
            var sample: [Double] = []
            sample.reserveCapacity(values.count / step + 1)
            for idx in stride(from: 0, to: values.count, by: step) {
                sample.append(values[idx])
            }
            sorted = sample.sorted()
        }
        let pos = min(1.0, max(0.0, q)) * Double(sorted.count - 1)
        let lo = Int(floor(pos))
        let hi = min(sorted.count - 1, lo + 1)
        let frac = pos - Double(lo)
        return sorted[lo] * (1.0 - frac) + sorted[hi] * frac
    }

    /// 盒式/区域平均抗混叠降采样（消除点采样混叠，与 wbquant/preprocess.py 严格一致）
    private static func downsampleAreaAverage(_ signal: [Double], width: Int, height: Int, factor: Int) -> (data: [Double], sw: Int, sh: Int) {
        guard factor > 1 else { return (signal, width, height) }
        let sw = max(4, width / factor)
        let sh = max(4, height / factor)
        var small = [Double](repeating: 0.0, count: sw * sh)
        let invArea = 1.0 / Double(factor * factor)
        for sy in 0..<sh {
            let y0 = sy * factor
            for sx in 0..<sw {
                let x0 = sx * factor
                var sum = 0.0
                for dy in 0..<factor {
                    let row = min(height - 1, y0 + dy) * width
                    for dx in 0..<factor {
                        sum += signal[row + min(width - 1, x0 + dx)]
                    }
                }
                small[sy * sw + sx] = sum * invArea
            }
        }
        return (small, sw, sh)
    }
    
    /// 真 2D 椭球面滚动球背景扣除（Sternberg 1983 / ImageJ & skimage.restoration.ellipsoid_kernel 等价）：
    /// 空间半轴 r_xy = radius / scale，强度半轴 R_z = radius * (intensityRange / 255.0) 与降采样因子完全解耦；
    /// 等价核 k(dx, dy) = R_z * (1 - sqrt(1 - (dx² + dy²) / r_xy²)) >= 0。
    public static func subtractRollingBallNative(
        signal: [Double],
        width: Int,
        height: Int,
        radius: Int,
        intensityRange: Double? = nil
    ) -> (signedNet: [Double], background: [Double]) {
        guard width > 0, height > 0, signal.count == width * height else { return (signal, Array(repeating: 0.0, count: signal.count)) }
        if radius <= 0 {
            let bgMed = median(signal)
            let bg = Array(repeating: bgMed, count: signal.count)
            return (signal.map { $0 - bgMed }, bg)
        }
        let effRange: Double = {
            if let explicit = intensityRange, explicit > 0 { return explicit }
            // 按图像自身实际稳健动态范围 [P0.2, P99.8] 缩放（确保 RB(c*I) == c*RB(I) 严格缩放齐次性，并对孤立 65535 热像素免疫）
            guard !signal.isEmpty else { return 1.0 }
            let robustSpan = sampledPercentile(signal, q: 0.998) - sampledPercentile(signal, q: 0.002)
            if robustSpan > 1e-6 { return robustSpan }
            if let lo = signal.min(), let hi = signal.max(), (hi - lo) > 1e-6 {
                return hi - lo
            }
            return 1.0
        }()
        let scale = (min(width, height) > 360 && radius >= 24) ? 4 : ((min(width, height) > 180 && radius >= 12) ? 2 : 1)
        let (small, sw, sh) = downsampleAreaAverage(signal, width: width, height: height, factor: scale)
        let rSmall = max(2, Int(round(Double(radius) / Double(scale))))
        // 强度半轴 R_z 严格按图像动态范围缩放且与降采样因子 scale 解耦
        let radiusZ = Double(radius) * (effRange / 255.0)
        
        let opened = rollingBallOpening2D(small, width: sw, height: sh, radiusXY: rSmall, radiusZ: radiusZ)
        
        var bgFull = [Double](repeating: 0.0, count: width * height)
        var signedNet = [Double](repeating: 0.0, count: width * height)
        let scaleX = Double(sw - 1) / Double(max(1, width - 1))
        let scaleY = Double(sh - 1) / Double(max(1, height - 1))
        for y in 0..<height {
            let fy = Double(y) * scaleY
            let y0 = min(sh - 1, Int(floor(fy)))
            let y1 = min(sh - 1, y0 + 1)
            let wy = fy - Double(y0)
            let rowOut = y * width
            for x in 0..<width {
                let fx = Double(x) * scaleX
                let x0 = min(sw - 1, Int(floor(fx)))
                let x1 = min(sw - 1, x0 + 1)
                let wx = fx - Double(x0)
                let top = opened[y0 * sw + x0] * (1.0 - wx) + opened[y0 * sw + x1] * wx
                let bot = opened[y1 * sw + x0] * (1.0 - wx) + opened[y1 * sw + x1] * wx
                let bg = top * (1.0 - wy) + bot * wy
                bgFull[rowOut + x] = bg
                signedNet[rowOut + x] = signal[rowOut + x] - bg
            }
        }
        return (signedNet, bgFull)
    }
    
    /// 2D 椭球面结构元素灰阶形态学开运算（空间半轴 radiusXY 与强度半轴 radiusZ 解耦）
    private static func rollingBallOpening2D(
        _ input: [Double],
        width: Int,
        height: Int,
        radiusXY: Int,
        radiusZ: Double
    ) -> [Double] {
        let r = max(1, radiusXY)
        let rD = Double(r)
        let r2 = rD * rD
        var offsets: [(dx: Int, dy: Int, k: Double)] = []
        offsets.reserveCapacity((2 * r + 1) * (2 * r + 1))
        for dy in -r...r {
            let dy2 = Double(dy * dy)
            for dx in -r...r {
                let d2 = Double(dx * dx) + dy2
                if d2 <= r2 {
                    let u2 = d2 / r2
                    let k = radiusZ * (1.0 - sqrt(max(0.0, 1.0 - u2)))
                    offsets.append((dx, dy, k))
                }
            }
        }
        let n = width * height
        var eroded = [Double](repeating: 0.0, count: n)
        for y in 0..<height {
            for x in 0..<width {
                var minVal = Double.greatestFiniteMagnitude
                for off in offsets {
                    let nx = x + off.dx
                    let ny = y + off.dy
                    if nx >= 0 && nx < width && ny >= 0 && ny < height {
                        let cand = input[ny * width + nx] + off.k
                        if cand < minVal { minVal = cand }
                    }
                }
                eroded[y * width + x] = minVal
            }
        }
        var opened = [Double](repeating: 0.0, count: n)
        for y in 0..<height {
            for x in 0..<width {
                var maxVal = -Double.greatestFiniteMagnitude
                for off in offsets {
                    let nx = x + off.dx
                    let ny = y + off.dy
                    if nx >= 0 && nx < width && ny >= 0 && ny < height {
                        let cand = eroded[ny * width + nx] - off.k
                        if cand > maxVal { maxVal = cand }
                    }
                }
                opened[y * width + x] = maxVal
            }
        }
        return opened
    }
    
    /// 基于行投影梯度能量最大化估计条带微倾斜角度（度，与 wbquant/preprocess.py 对齐）
    public static func estimateSkewAngleNative(
        signal: [Double],
        width: Int,
        height: Int,
        roi: WBRect? = nil,
        maxAngle: Double = 4.0
    ) -> Double {
        let rx = roi?.x ?? 0
        let ry = roi?.y ?? 0
        let rw = roi?.width ?? width
        let rh = roi?.height ?? height
        guard min(rw, rh) >= 20 else { return 0.0 }
        
        var sub = [Double](repeating: 0.0, count: rw * rh)
        for y in 0..<rh {
            for x in 0..<rw {
                sub[y * rw + x] = max(0.0, signal[(ry + y) * width + (rx + x)])
            }
        }
        let steps = 32
        var bestAngle = 0.0
        var bestScore = -1.0
        for s in 0...steps {
            let ang = -maxAngle + (2.0 * maxAngle) * Double(s) / Double(steps)
            let rot = deskewImageNative(sub, width: rw, height: rh, angleDegrees: ang, clipNegative: true)
            var rowSum = [Double](repeating: 0.0, count: rh)
            for y in 0..<rh {
                var acc = 0.0
                let base = y * rw
                for x in 0..<rw { acc += rot[base + x] }
                rowSum[y] = acc
            }
            var gradE = 0.0
            for y in 1..<rh {
                let d = rowSum[y] - rowSum[y - 1]
                gradE += d * d
            }
            if gradE > bestScore {
                bestScore = gradE
                bestAngle = ang
            }
        }
        return abs(bestAngle) >= 0.25 ? bestAngle : 0.0
    }
    
    /// 按指定角度逆时针旋转双线性插值校正图像（与 scipy.ndimage.rotate(..., reshape=False, order=1) 对齐）
    public static func deskewImageNative(
        _ img: [Double],
        width: Int,
        height: Int,
        angleDegrees: Double,
        clipNegative: Bool = false
    ) -> [Double] {
        guard abs(angleDegrees) >= 0.1, width > 0, height > 0, img.count == width * height else { return img }
        let rad = angleDegrees * Double.pi / 180.0
        let cosA = cos(rad)
        let sinA = sin(rad)
        let cx = Double(width - 1) * 0.5
        let cy = Double(height - 1) * 0.5
        var out = [Double](repeating: 0.0, count: width * height)
        for y in 0..<height {
            let dy = Double(y) - cy
            for x in 0..<width {
                let dx = Double(x) - cx
                // 逆映射源坐标（与 scipy.ndimage.rotate 方向一致）
                let sx = cosA * dx - sinA * dy + cx
                let sy = sinA * dx + cosA * dy + cy
                if sx < 0.0 || sx > Double(width - 1) || sy < 0.0 || sy > Double(height - 1) {
                    out[y * width + x] = 0.0
                    continue
                }
                let x0 = Int(floor(sx))
                let y0 = Int(floor(sy))
                let x1 = min(width - 1, x0 + 1)
                let y1 = min(height - 1, y0 + 1)
                let wx = sx - Double(x0)
                let wy = sy - Double(y0)
                let top = img[y0 * width + x0] * (1.0 - wx) + img[y0 * width + x1] * wx
                let bot = img[y1 * width + x0] * (1.0 - wx) + img[y1 * width + x1] * wx
                let val = top * (1.0 - wy) + bot * wy
                out[y * width + x] = clipNegative ? max(0.0, val) : val
            }
        }
        return out
    }
    
    /// 使用完全相同的旋转角度与最近邻插值同步旋转布尔饱和掩膜，防止饱和像素坐标与旋转后条带错位
    public static func deskewMaskNative(
        _ mask: [Bool],
        width: Int,
        height: Int,
        angleDegrees: Double
    ) -> [Bool] {
        guard abs(angleDegrees) >= 0.1, width > 0, height > 0, mask.count == width * height else { return mask }
        let rad = angleDegrees * Double.pi / 180.0
        let cosA = cos(rad)
        let sinA = sin(rad)
        let cx = Double(width - 1) * 0.5
        let cy = Double(height - 1) * 0.5
        var out = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let dy = Double(y) - cy
            for x in 0..<width {
                let dx = Double(x) - cx
                let sx = Int(round(cosA * dx - sinA * dy + cx))
                let sy = Int(round(sinA * dx + cosA * dy + cy))
                if sx >= 0 && sx < width && sy >= 0 && sy < height {
                    out[y * width + x] = mask[sy * width + sx]
                }
            }
        }
        return out
    }
    
    /// 可分离 2D 高斯平滑（sigma=1.5，与 wbquant/preprocess.py gaussian_filter 等价，压制孤立热像素而不损失真实条带峰值）
    private static func smooth2DGaussian(_ input: [Double], width: Int, height: Int, sigma: Double = 1.5) -> [Double] {
        guard width > 0, height > 0, input.count == width * height, sigma > 0 else { return input }
        let r = max(1, Int(ceil(3.0 * sigma)))
        var kernel = [Double](repeating: 0.0, count: 2 * r + 1)
        var kSum = 0.0
        for d in -r...r {
            let w = exp(-0.5 * Double(d * d) / (sigma * sigma))
            kernel[d + r] = w
            kSum += w
        }
        for i in 0..<kernel.count { kernel[i] /= max(1e-12, kSum) }

        var horiz = [Double](repeating: 0.0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var acc = 0.0
                for d in -r...r {
                    let sx = min(width - 1, max(0, x + d))
                    acc += input[row + sx] * kernel[d + r]
                }
                horiz[row + x] = acc
            }
        }
        var out = [Double](repeating: 0.0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var acc = 0.0
                for d in -r...r {
                    let sy = min(height - 1, max(0, y + d))
                    acc += horiz[sy * width + x] * kernel[d + r]
                }
                out[y * width + x] = acc
            }
        }
        return out
    }

    private static func detectStripROINative(
        signal: [Double],
        width: Int,
        height: Int,
        thresholdRatio: Double
    ) -> WBRect {
        let smoothed = smooth2DGaussian(signal, width: width, height: height, sigma: 1.5)
        let vmax = smoothed.max() ?? 0.0
        guard vmax > 1e-6 else {
            return WBRect(x: 0, y: 0, width: width, height: height)
        }
        var posVals: [Double] = []
        let step = max(1, (width * height) / 8192)
        for i in stride(from: 0, to: smoothed.count, by: step) where smoothed[i] > vmax * 0.01 {
            posVals.append(smoothed[i])
        }
        posVals.sort()
        let refPeak: Double = posVals.count > 20
            ? min(vmax, posVals[min(posVals.count - 1, Int(Double(posVals.count) * 0.92))] * 1.25)
            : vmax
        let cutoff = refPeak * max(0.03, min(0.45, thresholdRatio))
        
        // 计算行/列能量分布以稳健锁定膜条边界（自动剔除边缘孤立噪点）
        var colActive = [Int](repeating: 0, count: width)
        var rowActive = [Int](repeating: 0, count: height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where smoothed[row + x] > cutoff {
                colActive[x] += 1
                rowActive[y] += 1
            }
        }
        let minColHits = max(2, height / 90)
        let minRowHits = max(3, width / 60)
        let xs = (0..<width).filter { colActive[$0] >= minColHits }
        let ys = (0..<height).filter { rowActive[$0] >= minRowHits }
        guard let minX = xs.first, let maxX = xs.last,
              let minY = ys.first, let maxY = ys.last else {
            return WBRect(x: 0, y: 0, width: width, height: height)
        }
        let x0 = max(0, minX - 2)
        let x1 = min(width, maxX + 3)
        let y0 = max(0, minY - 14)
        let y1 = min(height, maxY + 15)
        return WBRect(x: x0, y: y0, width: max(16, x1 - x0), height: max(16, y1 - y0))
    }
    
    private static func smooth1D(_ values: [Double], radius: Int = 2) -> [Double] {
        let n = values.count
        guard n > 2, radius > 0 else { return values }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - radius)
            let hi = min(n - 1, i + radius)
            var sum = 0.0
            var wSum = 0.0
            for j in lo...hi {
                let d = Double(j - i)
                let w = exp(-0.5 * (d * d) / Double(max(1, radius * radius)))
                sum += values[j] * w
                wSum += w
            }
            out[i] = sum / max(1e-9, wSum)
        }
        return out
    }
    
    private static func computeGaussianWeightedLaneProfile(
        signal: [Double],
        width: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int
    ) -> [Double] {
        let lw = max(1, x1 - x0)
        let lh = max(1, y1 - y0)
        var weights = [Double](repeating: 1.0, count: lw)
        if lw > 2 {
            var wSum = 0.0
            for i in 0..<lw {
                let u = -1.5 + 3.0 * Double(i) / Double(lw - 1)
                let w = exp(-0.5 * u * u)
                weights[i] = w
                wSum += w
            }
            for i in 0..<lw { weights[i] /= max(1e-9, wSum) }
        }
        var prof = [Double](repeating: 0, count: lh)
        signal.withUnsafeBufferPointer { sBuf in
            weights.withUnsafeBufferPointer { wBuf in
                guard let sPtr = sBuf.baseAddress, let wPtr = wBuf.baseAddress else { return }
                let len = vDSP_Length(lw)
                for ry in 0..<lh {
                    let row = (y0 + ry) * width
                    var acc = 0.0
                    vDSP_dotprD(sPtr + row + x0, 1, wPtr, 1, &acc, len)
                    prof[ry] = acc
                }
            }
        }
        return prof
    }
    
    private static func detectLanesNative(
        signal: [Double],
        width: Int,
        height: Int,
        stripROI: WBRect,
        expectedLanes: Int
    ) -> [WBLane] {
        let stripW = stripROI.width
        let stripH = stripROI.height
        guard stripW >= 16, stripH >= 8 else {
            let prof = computeGaussianWeightedLaneProfile(
                signal: signal,
                width: width,
                x0: stripROI.x,
                x1: stripROI.x2,
                y0: stripROI.y,
                y1: stripROI.y2
            )
            return [WBLane(index: 0, xStart: stripROI.x, xEnd: stripROI.x2, yStart: stripROI.y, yEnd: stripROI.y2, profile: prof)]
        }
        
        var colMean = [Double](repeating: 0, count: stripW)
        signal.withUnsafeBufferPointer { sBuf in
            colMean.withUnsafeMutableBufferPointer { cBuf in
                guard let sPtr = sBuf.baseAddress, let cPtr = cBuf.baseAddress else { return }
                let len = vDSP_Length(stripW)
                for y in stripROI.y..<stripROI.y2 {
                    vDSP_vaddD(sPtr + y * width + stripROI.x, 1, cPtr, 1, cPtr, 1, len)
                }
                var divisor = Double(stripH)
                vDSP_vsdivD(cPtr, 1, &divisor, cPtr, 1, len)
            }
        }
        let colProf = smooth1D(colMean, radius: 3)
        let cmax = colProf.max() ?? 0.0
        guard cmax > 1e-6 else {
            return []
        }
        
        let inv = colProf.map { (cmax - $0) / cmax }
        let minDist = max(24, stripW / (max(expectedLanes, 8) + 1))
        let rawValleyPeaks = BioImageProcessor.findPeaks(
            profile: inv,
            minProminence: 0.06,
            minGap: minDist,
            smoothWindow: 3
        )
        let edgeMargin = max(16, Int(Double(stripW) * 0.09))
        var valleys = rawValleyPeaks.map(\.index).filter { $0 > edgeMargin && $0 < (stripW - edgeMargin) }
        
        if expectedLanes > 1 {
            let targetSplits = expectedLanes - 1
            if valleys.count != targetSplits {
                var snapped: [Int] = []
                let step = Double(stripW) / Double(expectedLanes)
                let searchR = max(6, Int(step * 0.28))
                for k in 1..<expectedLanes {
                    let ideal = Int(round(Double(k) * step))
                    let lo = max(edgeMargin, ideal - searchR)
                    let hi = min(stripW - edgeMargin - 1, ideal + searchR)
                    if hi > lo {
                        var bestIdx = ideal
                        var bestVal = Double.greatestFiniteMagnitude
                        for idx in lo...hi where colProf[idx] < bestVal {
                            bestVal = colProf[idx]
                            bestIdx = idx
                        }
                        snapped.append(bestIdx)
                    } else {
                        snapped.append(ideal)
                    }
                }
                valleys = Array(Set(snapped)).sorted()
            }
        }
        
        let boundaries = [0] + valleys + [stripW]
        var lanes: [WBLane] = []
        for idx in 0..<(boundaries.count - 1) {
            let xs0 = boundaries[idx]
            let xs1 = boundaries[idx + 1]
            if xs1 - xs0 < 8 { continue }
            let prof = computeGaussianWeightedLaneProfile(
                signal: signal,
                width: width,
                x0: stripROI.x + xs0,
                x1: stripROI.x + xs1,
                y0: stripROI.y,
                y1: stripROI.y2
            )
            lanes.append(
                WBLane(
                    index: lanes.count,
                    xStart: stripROI.x + xs0,
                    xEnd: stripROI.x + xs1,
                    yStart: stripROI.y,
                    yEnd: stripROI.y2,
                    profile: prof
                )
            )
        }
        return lanes
    }
    
    private static func refineSingleBandBoxNative(
        signal: [Double],
        width: Int,
        lane: WBLane,
        profSmooth: [Double],
        peakIdx: Int
    ) -> (x: Int, y: Int, width: Int, height: Int) {
        let hLane = profSmooth.count
        let peakVal = profSmooth[peakIdx]
        let cutoffY = peakVal * 0.16
        
        var top = peakIdx
        while top > 0 && profSmooth[top - 1] > cutoffY {
            if top < peakIdx - 2 && profSmooth[top - 1] > profSmooth[top] { break }
            top -= 1
        }
        var bot = peakIdx
        while bot < hLane - 1 && profSmooth[bot + 1] > cutoffY {
            if bot > peakIdx + 2 && profSmooth[bot + 1] > profSmooth[bot] { break }
            bot += 1
        }
        top = max(0, top - 2)
        bot = min(hLane - 1, bot + 2)
        if bot - top < 8 {
            top = max(0, peakIdx - 4)
            bot = min(hLane - 1, peakIdx + 4)
        }
        
        let yAbs = lane.yStart + top
        let hAbs = max(6, bot - top + 1)
        let lw = lane.width
        var colMax = [Double](repeating: 0, count: lw)
        for rx in 0..<lw {
            var m = 0.0
            for ry in yAbs..<(yAbs + hAbs) {
                let v = signal[ry * width + (lane.xStart + rx)]
                if v > m { m = v }
            }
            colMax[rx] = m
        }
        let colEnergy = smooth1D(colMax, radius: 1)
        let cmax = colEnergy.max() ?? 0.0
        if cmax > 1e-6 && lw > 6 {
            let activeCols = (0..<lw).filter { colEnergy[$0] >= cmax * 0.18 }
            if let firstCol = activeCols.first, let lastCol = activeCols.last, activeCols.count >= 4 {
                let lx = max(0, firstCol - 1)
                let rx = min(lw, lastCol + 2)
                if rx - lx >= max(8, Int(Double(lw) * 0.45)) {
                    return (lane.xStart + lx, yAbs, rx - lx, hAbs)
                }
            }
        }
        let padX = max(1, Int(Double(lw) * 0.05))
        return (lane.xStart + padX, yAbs, max(6, lw - 2 * padX), hAbs)
    }
    
    private static func detectBandsInLanesNative(
        signal: [Double],
        width: Int,
        height: Int,
        lanes: [WBLane],
        params: WBAnalysisParams
    ) -> [(laneIndex: Int, x: Int, y: Int, width: Int, height: Int, peakY: Int)] {
        let globalPeak = lanes.compactMap { $0.profile.max() }.max() ?? 0.0
        guard globalPeak > 1e-6 else { return [] }
        
        var detections: [(Int, Int, Int, Int, Int, Int)] = []
        for lane in lanes {
            let profSmooth = smooth1D(lane.profile, radius: 2)
            let lmax = profSmooth.max() ?? 0.0
            guard lmax >= globalPeak * 0.04, profSmooth.count >= 6 else { continue }
            
            let normProf = profSmooth.map { $0 / lmax }
            let rawPeaks = BioImageProcessor.findPeaks(
                profile: normProf,
                minProminence: max(0.05, params.bandProminence),
                minGap: 12,
                smoothWindow: 3
            )
            var peakIndices = rawPeaks.map(\.index)
            if peakIndices.isEmpty, let argMax = profSmooth.enumerated().max(by: { $0.element < $1.element })?.offset {
                peakIndices = [argMax]
            }
            if params.primaryBandOnly && peakIndices.count > 1 {
                if let best = peakIndices.max(by: { profSmooth[$0] < profSmooth[$1] }) {
                    peakIndices = [best]
                }
            }
            for pIdx in peakIndices {
                let box = refineSingleBandBoxNative(
                    signal: signal,
                    width: width,
                    lane: lane,
                    profSmooth: profSmooth,
                    peakIdx: pIdx
                )
                detections.append((lane.index, box.x, box.y, box.width, box.height, lane.yStart + pIdx))
            }
        }
        return detections
    }
    
    private static func alignBandRowsNative(
        detections: [(laneIndex: Int, x: Int, y: Int, width: Int, height: Int, peakY: Int)],
        rowTolerance: Int = 18
    ) -> [(laneIndex: Int, rowIndex: Int, x: Int, y: Int, width: Int, height: Int, peakY: Int)] {
        guard !detections.isEmpty else { return [] }
        let sortedByY = detections.sorted { $0.peakY < $1.peakY }
        var rowCenters: [Double] = []
        var rowCounts: [Int] = []
        var assignedRows: [Int] = []
        
        for det in sortedByY {
            let py = Double(det.peakY)
            if let lastCenter = rowCenters.last, abs(py - lastCenter) <= Double(rowTolerance) {
                let rIdx = rowCenters.count - 1
                let n = rowCounts[rIdx]
                rowCenters[rIdx] = (rowCenters[rIdx] * Double(n) + py) / Double(n + 1)
                rowCounts[rIdx] = n + 1
                assignedRows.append(rIdx)
            } else {
                rowCenters.append(py)
                rowCounts.append(1)
                assignedRows.append(rowCenters.count - 1)
            }
        }
        var aligned: [(Int, Int, Int, Int, Int, Int, Int)] = []
        for (det, rIdx) in zip(sortedByY, assignedRows) {
            aligned.append((det.laneIndex, rIdx, det.x, det.y, det.width, det.height, det.peakY))
        }
        aligned.sort { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            return a.0 < b.0
        }
        return aligned
    }
    
    /// 单次去背景有符号净积分定量（严格禁止全局 Rolling-Ball 与局部基线双重叠加，消除 max(0, ...) 噪声整流偏置）
    private static func quantifyAlignedBandsNative(
        rawSignal: [Double],
        correctedSignal: [Double],
        saturatedMask: [Bool],
        width: Int,
        height: Int,
        alignedBoxes: [(Int, Int, Int, Int, Int, Int, Int)],
        controlLaneIndex: Int,
        saturationRatioThreshold: Double = 0.01,
        backgroundMode: WBBgSubtractionMode = .globalRollingBall
    ) -> [WBBand] {
        var prelim: [WBBand] = []
        for (laneIdx, rowIdx, bx, by, bw, bh, peakY) in alignedBoxes {
            let x0 = max(0, min(width - 1, bx))
            let y0 = max(0, min(height - 1, by))
            let x1 = max(x0 + 1, min(width, bx + bw))
            let y1 = max(y0 + 1, min(height, by + bh))
            let boxH = y1 - y0
            
            var topBorder: [Double] = []
            var botBorder: [Double] = []
            let refSrc = (backgroundMode == .localTrapezoid) ? rawSignal : correctedSignal
            for ty in max(0, y0 - 2)..<y0 {
                for tx in x0..<x1 { topBorder.append(refSrc[ty * width + tx]) }
            }
            for by2 in y1..<min(height, y1 + 2) {
                for tx in x0..<x1 { botBorder.append(refSrc[by2 * width + tx]) }
            }
            let topMed = topBorder.isEmpty ? (botBorder.isEmpty ? 0.0 : median(botBorder)) : median(topBorder)
            let botMed = botBorder.isEmpty ? topMed : median(botBorder)
            let allBorder = topBorder + botBorder
            let noiseSd = allBorder.count >= 2 ? (QPCRStatistics.sampleSd(allBorder) ?? 0.0) : 0.0
            
            var rawIOD = 0.0
            var signedNetIOD = 0.0
            var patchMax = 0.0
            var netPatch = [Double](repeating: 0.0, count: (x1 - x0) * boxH)
            
            for ry in 0..<boxH {
                let y = y0 + ry
                let row = y * width
                let t = boxH > 1 ? Double(ry) / Double(boxH - 1) : 0.5
                let trapBase = topMed * (1.0 - t) + botMed * t
                for rx in 0..<(x1 - x0) {
                    let x = x0 + rx
                    let rawVal = rawSignal[row + x]
                    rawIOD += rawVal
                    let netVal = (backgroundMode == .localTrapezoid)
                        ? (rawVal - trapBase)
                        : correctedSignal[row + x]
                    netPatch[ry * (x1 - x0) + rx] = netVal
                    signedNetIOD += netVal
                    if netVal > patchMax { patchMax = netVal }
                }
            }
            let netIOD = max(0.0, signedNetIOD)
            let bgIOD = max(0.0, rawIOD - netIOD)
            let snr = noiseSd > 1e-9 ? (patchMax / noiseSd) : (patchMax > 0 ? 100.0 : 0.0)
            
            var coreCount = 0
            var satCoreCount = 0
            let coreCutoff = patchMax * 0.25
            for ry in 0..<boxH {
                let row = (y0 + ry) * width
                for rx in 0..<(x1 - x0) {
                    let nv = netPatch[ry * (x1 - x0) + rx]
                    if patchMax <= 0 || nv >= coreCutoff {
                        coreCount += 1
                        if saturatedMask[row + (x0 + rx)] { satCoreCount += 1 }
                    }
                }
            }
            let satRatio = Double(satCoreCount) / Double(max(1, coreCount))
            
            prelim.append(
                WBBand(
                    id: "L\(laneIdx + 1)_R\(rowIdx + 1)",
                    laneIndex: laneIdx,
                    rowIndex: rowIdx,
                    x: x0,
                    y: y0,
                    width: x1 - x0,
                    height: boxH,
                    peakY: peakY,
                    rawIOD: rawIOD,
                    backgroundIOD: bgIOD,
                    netIOD: netIOD,
                    normalizedRatio: 1.0,
                    foldChange: 1.0,
                    saturatedRatio: satRatio,
                    isSaturated: satRatio >= max(0.001, saturationRatioThreshold),
                    isPrimary: (rowIdx == 0),
                    snr: snr
                )
            )
        }
        
        let byRow = Dictionary(grouping: prelim, by: \.rowIndex)
        var finalBands: [WBBand] = []
        for rIdx in byRow.keys.sorted() {
            guard let rowBands = byRow[rIdx], !rowBands.isEmpty else { continue }
            let sortedRow = rowBands.sorted { $0.laneIndex < $1.laneIndex }
            let ctrl = sortedRow.first(where: { $0.laneIndex == controlLaneIndex }) ?? sortedRow[0]
            let baseIOD = max(1e-6, ctrl.netIOD)
            for var b in sortedRow {
                let fc = b.netIOD / baseIOD
                b.normalizedRatio = fc
                b.foldChange = fc
                b.isPrimary = (rIdx == 0)
                finalBands.append(b)
            }
        }
        return finalBands
    }
    
    /// 全蛋白通道（Ponceau S / Stain-Free / Revert 700）整泳道垂直积分净信号计算（TPN 分母，对标 Nature Portfolio / JBC / Cell Press）
    public static func computeTotalLaneProteinIODs(
        correctedSignal: [Double],
        width: Int,
        height: Int,
        lanes: [WBLane]
    ) -> [Int: Double] {
        guard width > 0, height > 0, correctedSignal.count == width * height else { return [:] }
        var totals: [Int: Double] = [:]
        for lane in lanes {
            let x0 = max(0, min(width - 1, lane.xStart))
            let x1 = max(x0 + 1, min(width, lane.xEnd))
            let y0 = max(0, min(height - 1, lane.yStart))
            let y1 = max(y0 + 1, min(height, lane.yEnd))
            var sum = 0.0
            for y in y0..<y1 {
                let row = y * width
                for x in x0..<x1 { sum += correctedSignal[row + x] }
            }
            totals[lane.index] = max(0.0, sum)
        }
        return totals
    }
    
    /// 使用全泳道总蛋白净信号（TPN）对目的蛋白条带执行归一化（按 rowIndex 分行独立计算对照锚点，杜绝多行条带按 laneIndex 互相覆写）
    public static func normalizeToTotalProtein(
        targetBands: [WBBand],
        totalProteinLaneIODs: [Int: Double],
        controlLaneIndex: Int = 0
    ) -> [WBBand] {
        // 按 (rowIndex, laneIndex) 独立保存每行每泳道的比值与各行对照锚点
        var rowCtrlRatio: [Int: Double] = [:]
        let byRow = Dictionary(grouping: targetBands, by: \.rowIndex)
        for (rIdx, rowBands) in byRow {
            let rowRatios: [(lane: Int, ratio: Double)] = rowBands.map { b in
                let tpn = totalProteinLaneIODs[b.laneIndex] ?? 0.0
                return (b.laneIndex, tpn > 1e-6 ? (b.netIOD / tpn) : 0.0)
            }
            if let ctrl = rowRatios.first(where: { $0.lane == controlLaneIndex && $0.ratio > 1e-9 }) {
                rowCtrlRatio[rIdx] = ctrl.ratio
            } else if let firstPos = rowRatios.first(where: { $0.ratio > 1e-9 }) {
                rowCtrlRatio[rIdx] = firstPos.ratio
            } else {
                rowCtrlRatio[rIdx] = 1.0
            }
        }
        return targetBands.map { b in
            var copy = b
            let tpn = totalProteinLaneIODs[b.laneIndex] ?? 0.0
            let r = tpn > 1e-6 ? (b.netIOD / tpn) : 0.0
            let ctrlAnchor = rowCtrlRatio[b.rowIndex] ?? 1.0
            copy.normalizedRatio = r
            copy.foldChange = r / ctrlAnchor
            return copy
        }
    }
    
    /// 重叠双带/多带（如 LC3-I / LC3-II、磷酸化/非磷酸化双带）1D 多峰高斯混合非线性最小二乘去卷积（Levenberg–Marquardt）
    public static func deconvolveOverlappingBandsGaussian(
        profile: [Double],
        peakIndices: [Int]
    ) -> [WBGaussianPeakComponent] {
        let n = profile.count
        let k = peakIndices.count
        guard n >= 3, k >= 1 else { return [] }
        let ymax = max(1e-6, profile.max() ?? 1.0)
        
        // 参数向量 theta = [A_0, mu_0, sigma_0, ..., A_{k-1}, mu_{k-1}, sigma_{k-1}]
        let p = 3 * k
        var theta = [Double](repeating: 0.0, count: p)
        var lo = [Double](repeating: 0.0, count: p)
        var hi = [Double](repeating: 0.0, count: p)
        for j in 0..<k {
            let mu0 = Double(max(0, min(n - 1, peakIndices[j])))
            let amp0 = max(1e-3 * ymax, profile[Int(round(mu0))])
            let sig0 = max(1.5, min(Double(n) * 0.15, 3.0))
            theta[3 * j] = amp0
            theta[3 * j + 1] = mu0
            theta[3 * j + 2] = sig0
            lo[3 * j] = 0.0
            lo[3 * j + 1] = max(0.0, mu0 - 8.0)
            lo[3 * j + 2] = 0.5
            hi[3 * j] = ymax * 2.5
            hi[3 * j + 1] = min(Double(n - 1), mu0 + 8.0)
            hi[3 * j + 2] = Double(n) * 0.5
        }
        
        func evalModel(_ th: [Double], _ x: Double) -> Double {
            var s = 0.0
            for j in 0..<k {
                let a = th[3 * j]
                let mu = th[3 * j + 1]
                let sig = max(0.5, th[3 * j + 2])
                let z = (x - mu) / sig
                s += a * exp(-0.5 * z * z)
            }
            return s
        }
        func computeSSE(_ th: [Double]) -> Double {
            var sse = 0.0
            for i in 0..<n {
                let r = profile[i] - evalModel(th, Double(i))
                sse += r * r
            }
            return sse
        }
        
        var curSSE = computeSSE(theta)
        var lambda = 1e-2
        for _ in 0..<100 {
            var jtj = Array(repeating: Array(repeating: 0.0, count: p), count: p)
            var jtr = Array(repeating: 0.0, count: p)
            for i in 0..<n {
                let x = Double(i)
                var f0 = 0.0
                var grad = [Double](repeating: 0.0, count: p)
                for j in 0..<k {
                    let a = theta[3 * j]
                    let mu = theta[3 * j + 1]
                    let sig = max(0.5, theta[3 * j + 2])
                    let z = (x - mu) / sig
                    let e = exp(-0.5 * z * z)
                    f0 += a * e
                    grad[3 * j] = e
                    grad[3 * j + 1] = a * e * (z / sig)
                    grad[3 * j + 2] = a * e * (z * z / sig)
                }
                let res = profile[i] - f0
                for r in 0..<p {
                    jtr[r] += grad[r] * res
                    for c in 0..<p { jtj[r][c] += grad[r] * grad[c] }
                }
            }
            for r in 0..<p { jtj[r][r] += lambda * max(1e-6, jtj[r][r]) + 1e-9 }
            
            // 高斯消元求解 (J^T J + λI) δ = J^T r
            var mat = jtj
            var rhs = jtr
            var singular = false
            for col in 0..<p {
                var pivRow = col
                var maxV = abs(mat[col][col])
                for r in (col + 1)..<p where abs(mat[r][col]) > maxV {
                    maxV = abs(mat[r][col]); pivRow = r
                }
                if maxV < 1e-14 { singular = true; break }
                if pivRow != col { mat.swapAt(col, pivRow); rhs.swapAt(col, pivRow) }
                let piv = mat[col][col]
                for r in (col + 1)..<p {
                    let fac = mat[r][col] / piv
                    for c in col..<p { mat[r][c] -= fac * mat[col][c] }
                    rhs[r] -= fac * rhs[col]
                }
            }
            if singular {
                lambda = min(1e8, lambda * 10.0)
                if lambda >= 1e7 { break }
                continue
            }
            var delta = [Double](repeating: 0.0, count: p)
            for r in stride(from: p - 1, through: 0, by: -1) {
                var sum = rhs[r]
                for c in (r + 1)..<p { sum -= mat[r][c] * delta[c] }
                delta[r] = sum / mat[r][r]
            }
            var cand = theta
            for j in 0..<p { cand[j] = min(hi[j], max(lo[j], theta[j] + delta[j])) }
            let candSSE = computeSSE(cand)
            if candSSE < curSSE {
                let rel = abs(curSSE - candSSE) / max(1e-12, curSSE)
                theta = cand
                curSSE = candSSE
                lambda = max(1e-7, lambda * 0.3)
                if rel < 1e-10 { break }
            } else {
                lambda = min(1e8, lambda * 5.0)
                if lambda >= 1e7 { break }
            }
        }
        
        let sqrt2Pi = sqrt(2.0 * Double.pi)
        var areas: [Double] = []
        for j in 0..<k {
            areas.append(theta[3 * j] * theta[3 * j + 2] * sqrt2Pi)
        }
        let totalArea = areas.reduce(0.0, +)
        return (0..<k).map { j in
            WBGaussianPeakComponent(
                amplitude: theta[3 * j],
                center: theta[3 * j + 1],
                sigma: theta[3 * j + 2],
                area: areas[j],
                fraction: totalArea > 1e-12 ? (areas[j] / totalArea) : (1.0 / Double(k))
            )
        }
    }
    
    /// 将 `WBAnalysisResult` 中的泳道与条带按生物学重复分组汇总：支持 TPN/内参双模式、饱和剔除 (P03)、log2 空间统计检验与多重校正
    public static func computeGroupStatistics(
        from result: WBAnalysisResult,
        laneGroups: [Int: String],
        controlGroup: String = "WT",
        normalizeBySecondRowIfPresent: Bool = true,
        saturationPolicy: WBSaturationPolicy? = nil,
        totalProteinLaneIODs: [Int: Double]? = nil,
        postHocMethod: ViabilityPostHocMethod = .welchHolm
    ) -> BlotQuantificationOut {
        let policy = saturationPolicy ?? result.params.saturationPolicy
        let satThresh = max(0.001, result.params.saturationRatioThreshold)
        let row0Bands = result.bands.filter { $0.rowIndex == 0 }
        let row1ByLane = Dictionary(uniqueKeysWithValues: result.bands.filter { $0.rowIndex == 1 }.map { ($0.laneIndex, $0) })
        let useTPN = (totalProteinLaneIODs != nil && !(totalProteinLaneIODs?.isEmpty ?? true))
        let hasLoadingRow = !useTPN && normalizeBySecondRowIfPresent && !row1ByLane.isEmpty
        
        var groupsOrder: [String] = []
        var excludedBands: [WBExcludedBandRecord] = []
        var rawRows: [(bandID: String, laneIdx: Int, sample: String, group: String, targetVol: Double, loadingVol: Double, bg: Double, ratio: Double, sat: Bool, satPct: Double, reason: String, excludedForMissingDenom: Bool)] = []
        
        for b in row0Bands.sorted(by: { $0.laneIndex < $1.laneIndex }) {
            let defaultGrp = (b.laneIndex < 2) ? "WT" : ((b.laneIndex < 4) ? "Group-2" : "Group-3")
            let grp = laneGroups[b.laneIndex] ?? defaultGrp
            if !groupsOrder.contains(grp) { groupsOrder.append(grp) }
            let loadingBand = row1ByLane[b.laneIndex]
            let loadVol: Double
            let ratio: Double
            var missingDenom = false
            if useTPN {
                if let tpnVal = totalProteinLaneIODs?[b.laneIndex], tpnVal > 1e-6 {
                    loadVol = tpnVal
                    ratio = b.netIOD / tpnVal
                } else {
                    loadVol = 0.0
                    ratio = 0.0
                    missingDenom = true
                }
            } else if hasLoadingRow {
                if let lb = loadingBand, lb.netIOD > 1e-6 {
                    loadVol = lb.netIOD
                    ratio = b.netIOD / lb.netIOD
                } else {
                    loadVol = loadingBand?.netIOD ?? 0.0
                    ratio = 0.0
                    missingDenom = true
                }
            } else {
                loadVol = loadingBand?.netIOD ?? 1.0
                ratio = b.netIOD
            }
            let targetSat = b.isSaturated || (b.saturatedRatio >= satThresh)
            let loadingSat = !useTPN && ((loadingBand?.isSaturated ?? false) || ((loadingBand?.saturatedRatio ?? 0.0) >= satThresh))
            let isSat = targetSat || loadingSat
            let maxSatPct = max(b.saturatedRatio, loadingSat ? (loadingBand?.saturatedRatio ?? 0.0) : 0.0) * 100.0
            let satReason: String = {
                if targetSat && loadingSat {
                    return String(format: L10n.tr("目的条带与内参条带均过曝 (饱和像素占比 %.1f%%)", "Both target & loading-control bands saturated (%.1f%% core pixels)"), maxSatPct)
                } else if targetSat {
                    return String(format: L10n.tr("目的条带 (%@) 信号过曝 (饱和像素占比 %.1f%%)", "Target band (%@) saturated (%.1f%% core pixels)"), b.id, b.saturatedRatio * 100.0)
                } else if loadingSat, let lb = loadingBand {
                    return String(format: L10n.tr("内参条带 (%@) 信号过曝 (饱和像素占比 %.1f%%)", "Loading-control band (%@) saturated (%.1f%% core pixels)"), lb.id, lb.saturatedRatio * 100.0)
                }
                return ""
            }()
            if missingDenom {
                excludedBands.append(
                    WBExcludedBandRecord(
                        bandID: b.id,
                        laneIndex: b.laneIndex + 1,
                        groupName: grp,
                        reason: L10n.tr("缺少有效总蛋白/内参归一化分母，已从统计中剔除（严禁回退原始 IOD）", "Missing valid TPN/loading-control denominator; excluded from statistics (raw IOD fallback prohibited)")
                    )
                )
            } else if policy == .excludeFromStats && isSat {
                excludedBands.append(
                    WBExcludedBandRecord(
                        bandID: b.id,
                        laneIndex: b.laneIndex + 1,
                        groupName: grp,
                        reason: satReason
                    )
                )
            }
            rawRows.append((
                bandID: b.id,
                laneIdx: b.laneIndex + 1,
                sample: "L\(b.laneIndex + 1)",
                group: grp,
                targetVol: b.netIOD,
                loadingVol: loadVol,
                bg: b.backgroundIOD,
                ratio: ratio,
                sat: isSat,
                satPct: maxSatPct,
                reason: satReason,
                excludedForMissingDenom: missingDenom
            ))
        }
        
        let resolvedCtrl = groupsOrder.first(where: { $0.caseInsensitiveCompare(controlGroup) == .orderedSame }) ?? (groupsOrder.first ?? "WT")
        let ctrlValidVals = rawRows.filter {
            $0.group.caseInsensitiveCompare(resolvedCtrl) == .orderedSame && !$0.excludedForMissingDenom && !(policy == .excludeFromStats && $0.sat)
        }.map(\.ratio)
        let fallbackCtrlVals = rawRows.filter { $0.group.caseInsensitiveCompare(resolvedCtrl) == .orderedSame && !$0.excludedForMissingDenom }.map(\.ratio)
        let activeCtrlVals = ctrlValidVals.isEmpty ? fallbackCtrlVals : ctrlValidVals
        // 在 log2 空间以对照组几何均值作为基准锚点（避免乘法分布的 Jensen 上偏）
        let posCtrl = activeCtrlVals.filter { $0 > 1e-12 }
        let ctrlAnchor: Double = {
            if !posCtrl.isEmpty {
                let meanLog = posCtrl.reduce(0.0) { $0 + log2($1) } / Double(posCtrl.count)
                return pow(2.0, meanLog)
            }
            return activeCtrlVals.isEmpty ? 1.0 : max(1e-9, QPCRStatistics.mean(activeCtrlVals))
        }()
        
        let laneRows: [BlotLaneQuantRow] = rawRows.map { r in
            BlotLaneQuantRow(
                laneID: "L\(r.laneIdx)",
                laneIndex: r.laneIdx,
                sampleName: r.sample,
                groupName: r.group,
                targetNetVolume: r.targetVol,
                loadingNetVolume: r.loadingVol,
                targetBackground: r.bg,
                normalizedRatio: r.ratio,
                foldChange: r.excludedForMissingDenom ? 0.0 : (r.ratio / ctrlAnchor),
                isSaturated: r.sat,
                clippedPct: r.satPct
            )
        }
        let excludedLaneIndices = Set(rawRows.filter(\.excludedForMissingDenom).map(\.laneIdx))
        
        return summarizeBlotGroupsInLog2Space(
            laneRows: laneRows,
            groupsOrder: groupsOrder,
            controlGroup: resolvedCtrl,
            globalBackground: 0.0,
            saturationPolicy: policy,
            excludedBands: excludedBands,
            postHocMethod: postHocMethod,
            alwaysExcludedLaneIndices: excludedLaneIndices
        )
    }
    
    /// 多张重复膜（Replicate Blots）跨膜合并统计：先逐膜归一化至各自对照锚点，再在 log2 空间跨膜汇总检验
    public static func combineReplicateBlots(
        blots: [BlotQuantificationOut],
        controlGroup: String? = nil,
        postHocMethod: ViabilityPostHocMethod = .welchHolm
    ) -> BlotQuantificationOut {
        var allRows: [BlotLaneQuantRow] = []
        var groupsOrder: [String] = []
        var excluded: [WBExcludedBandRecord] = []
        let policy = blots.first?.saturationPolicy ?? .excludeFromStats
        let resolvedCtrl = controlGroup ?? blots.first?.controlGroup ?? "WT"
        
        for (bIdx, blot) in blots.enumerated() {
            for g in blot.groups where !groupsOrder.contains(g) { groupsOrder.append(g) }
            excluded.append(contentsOf: blot.excludedBands)
            // 若合并时切换了 controlGroup，则按新对照组在单张膜内重新锚定 foldChange
            let needsReanchor = (blot.controlGroup.caseInsensitiveCompare(resolvedCtrl) != .orderedSame)
            let blotReanchorFactor: Double = {
                guard needsReanchor else { return 1.0 }
                let ctrlRows = blot.laneRows.filter {
                    $0.groupName.caseInsensitiveCompare(resolvedCtrl) == .orderedSame
                        && !(policy == .excludeFromStats && $0.isSaturated)
                        && $0.foldChange > 1e-12
                }
                guard !ctrlRows.isEmpty else { return 1.0 }
                let meanLog = ctrlRows.reduce(0.0) { $0 + log2($1.foldChange) } / Double(ctrlRows.count)
                return pow(2.0, meanLog)
            }()
            for r in blot.laneRows {
                allRows.append(BlotLaneQuantRow(
                    laneID: "B\(bIdx + 1)_\(r.laneID)",
                    laneIndex: allRows.count + 1,
                    sampleName: "Blot\(bIdx + 1)-\(r.sampleName)",
                    groupName: r.groupName,
                    targetNetVolume: r.targetNetVolume,
                    loadingNetVolume: r.loadingNetVolume,
                    targetBackground: r.targetBackground,
                    normalizedRatio: r.normalizedRatio,
                    foldChange: r.foldChange / max(1e-12, blotReanchorFactor),
                    isSaturated: r.isSaturated,
                    clippedPct: r.clippedPct
                ))
            }
        }
        return summarizeBlotGroupsInLog2Space(
            laneRows: allRows,
            groupsOrder: groupsOrder,
            controlGroup: resolvedCtrl,
            globalBackground: 0.0,
            saturationPolicy: policy,
            excludedBands: excluded,
            postHocMethod: postHocMethod
        )
    }
    
    /// 在 log2(Normalized Intensity) 空间计算几何均值、两样本 Welch 95% CI、One-Way ANOVA 与 Holm/Dunnett/Tukey/Kruskal-Dunn 校正
    private static func summarizeBlotGroupsInLog2Space(
        laneRows: [BlotLaneQuantRow],
        groupsOrder: [String],
        controlGroup: String,
        globalBackground: Double,
        saturationPolicy: WBSaturationPolicy,
        excludedBands: [WBExcludedBandRecord],
        postHocMethod: ViabilityPostHocMethod,
        alwaysExcludedLaneIndices: Set<Int> = []
    ) -> BlotQuantificationOut {
        let ctrlIdx = groupsOrder.firstIndex(where: { $0.caseInsensitiveCompare(controlGroup) == .orderedSame }) ?? 0
        var log2ByGroup: [[Double]] = []
        var foldsByGroup: [[Double]] = []
        var excludedCounts: [Int] = []
        
        for grp in groupsOrder {
            let allGroupRows = laneRows.filter { $0.groupName == grp }
            let exSatCnt = (saturationPolicy == .excludeFromStats) ? allGroupRows.filter(\.isSaturated).count : 0
            let validRows = allGroupRows.filter { row in
                if alwaysExcludedLaneIndices.contains(row.laneIndex) { return false }
                if saturationPolicy == .excludeFromStats && row.isSaturated { return false }
                return true
            }
            let folds = validRows.map(\.foldChange)
            let logs = folds.map { log2(max(1e-9, $0)) }
            foldsByGroup.append(folds)
            log2ByGroup.append(logs)
            excludedCounts.append(exSatCnt)
        }
        
        let ctrlLogs = log2ByGroup.indices.contains(ctrlIdx) ? log2ByGroup[ctrlIdx] : []
        let ctrlMeanLog = ctrlLogs.isEmpty ? 0.0 : QPCRStatistics.mean(ctrlLogs)
        let ctrlSdLog = QPCRStatistics.sampleSd(ctrlLogs) ?? 0.0
        // 检测跨膜归一化后的零方差对照组（例如每张膜对照组均被锚定为 1.0 -> log2 == 0）
        let isZeroVarCtrl = (ctrlLogs.count >= 2 && ctrlSdLog < 1e-12)
        
        let anovaLog2: PlateReaderAssayEngine.OneWayANOVAResult? = {
            if isZeroVarCtrl {
                let treatOnly = log2ByGroup.enumerated().filter { $0.offset != ctrlIdx && $0.element.count >= 2 }.map(\.element)
                return treatOnly.count >= 2 ? PlateReaderAssayEngine.computeOneWayANOVA(groups: treatOnly) : nil
            }
            let validGroups = log2ByGroup.filter { $0.count >= 2 }
            return PlateReaderAssayEngine.computeOneWayANOVA(groups: validGroups)
        }()
        
        // 1) 两样本 Welch t 检验（若对照组零方差则改用对 0 的单样本 t 检验，防止人为压缩 MS_within）
        var rawWelchPs: [Double?] = []
        for idx in 0..<groupsOrder.count {
            if idx == ctrlIdx || log2ByGroup[idx].count < 2 {
                rawWelchPs.append(nil)
            } else if isZeroVarCtrl {
                let logs = log2ByGroup[idx]
                let m = QPCRStatistics.mean(logs)
                let se = QPCRStatistics.sem(logs) ?? 0.0
                if se > 1e-15 {
                    let tStat = (m - ctrlMeanLog) / se
                    rawWelchPs.append(QPCRStatistics.studentTTwoSidedP(t: abs(tStat), df: Double(logs.count - 1)))
                } else {
                    rawWelchPs.append(abs(m - ctrlMeanLog) > 1e-12 ? 0.0 : 1.0)
                }
            } else if ctrlLogs.count < 2 {
                rawWelchPs.append(nil)
            } else {
                rawWelchPs.append(QPCRStatistics.welchTTest(log2ByGroup[idx], ctrlLogs)?.p)
            }
        }
        let holmAdjPs = QPCRStatistics.holmAdjustOptional(rawWelchPs)
        
        // 2) Dunnett / Tukey / Dunn（均过滤 count >= 2 且在零方差对照组下回退至单样本 t + Holm 避免池化方差膨胀）
        var dunnettMap: [Int: (tStat: Double, pValue: Double)] = [:]
        var tukeyPairs: [PlateReaderAssayEngine.PairwiseComparisonResult] = []
        var dunnMap: [Int: Double] = [:]
        if !isZeroVarCtrl {
            let validEntries = log2ByGroup.enumerated().filter { $0.element.count >= 2 }
            let validArrays = validEntries.map(\.element)
            if let localCtrl = validEntries.firstIndex(where: { $0.offset == ctrlIdx }) {
                let localDunnett = PlateReaderAssayEngine.computeDunnettVsControl(groups: validArrays, controlIndex: localCtrl)
                for (locIdx, val) in localDunnett { dunnettMap[validEntries[locIdx].offset] = val }
                let localDunn = PlateReaderAssayEngine.computeDunnVsControl(groups: validArrays, controlIndex: localCtrl)
                for (locIdx, pVal) in localDunn { dunnMap[validEntries[locIdx].offset] = pVal }
            }
            tukeyPairs = PlateReaderAssayEngine.computeTukeyKramerHSD(
                namedGroups: validEntries.map { (groupsOrder[$0.offset], $0.element) }
            )
        }
        
        let groupStats: [BlotGroupStatSummary] = groupsOrder.enumerated().map { idx, grp in
            let folds = foldsByGroup[idx]
            let logs = log2ByGroup[idx]
            let isCtrl = (idx == ctrlIdx)
            let meanLog = logs.isEmpty ? nil : QPCRStatistics.mean(logs)
            let geomMeanFold = meanLog.map { pow(2.0, $0) } ?? 0.0
            
            // log2 空间 95% 置信区间：非对照组采用两样本 Welch CI（计入对照组方差，与 Welch t 检验及 Python MCP 严格一致）
            var ciLo: Double? = nil
            var ciHi: Double? = nil
            if let ml = meanLog, logs.count >= 2 {
                if !isCtrl && ctrlLogs.count >= 2 && !isZeroVarCtrl {
                    let s1 = QPCRStatistics.sampleSd(logs) ?? 0.0
                    let s0 = ctrlSdLog
                    let v1 = (s1 * s1) / Double(logs.count)
                    let v0 = (s0 * s0) / Double(ctrlLogs.count)
                    let se = sqrt(v1 + v0)
                    let diff = ml - ctrlMeanLog
                    if se > 1e-15 {
                        let denom = (v1 * v1) / Double(logs.count - 1) + (v0 * v0) / Double(ctrlLogs.count - 1)
                        let dfW = denom > 1e-30 ? ((v1 + v0) * (v1 + v0) / denom) : Double(logs.count + ctrlLogs.count - 2)
                        if let tCrit = QPCRStatistics.studentTQuantileTwoSided(alpha: 0.05, df: max(1.0, dfW)) {
                            ciLo = pow(2.0, diff - tCrit * se)
                            ciHi = pow(2.0, diff + tCrit * se)
                        }
                    } else {
                        ciLo = pow(2.0, diff)
                        ciHi = pow(2.0, diff)
                    }
                } else if let semLog = QPCRStatistics.sem(logs),
                          let tCrit = QPCRStatistics.studentTQuantileTwoSided(alpha: 0.05, df: Double(logs.count - 1)) {
                    let center = isCtrl ? ml : (ml - ctrlMeanLog)
                    ciLo = pow(2.0, center - tCrit * semLog)
                    ciHi = pow(2.0, center + tCrit * semLog)
                }
            }
            
            let pRaw: Double?
            let pAdj: Double?
            if isZeroVarCtrl {
                pRaw = rawWelchPs[idx]
                pAdj = holmAdjPs[idx]
            } else {
                switch postHocMethod {
                case .dunnett:
                    pRaw = dunnettMap[idx]?.pValue
                    pAdj = dunnettMap[idx]?.pValue
                case .tukeyHSD:
                    let ctrlName = groupsOrder[ctrlIdx]
                    let pair = tukeyPairs.first { ($0.groupA == grp && $0.groupB == ctrlName) || ($0.groupB == grp && $0.groupA == ctrlName) }
                    pRaw = pair?.pAdjusted
                    pAdj = pair?.pAdjusted
                case .welchHolm:
                    pRaw = rawWelchPs[idx]
                    pAdj = holmAdjPs[idx]
                case .kruskalDunn:
                    pRaw = dunnMap[idx]
                    pAdj = dunnMap[idx]
                }
            }
            
            return BlotGroupStatSummary(
                groupName: grp,
                n: folds.count,
                nExcludedSaturated: excludedCounts[idx],
                meanFold: geomMeanFold,
                sdFold: QPCRStatistics.sampleSd(folds),
                semFold: QPCRStatistics.sem(folds),
                pValue: isCtrl ? nil : pRaw,
                pAdjusted: isCtrl ? nil : pAdj,
                log2MeanFold: meanLog,
                foldCI95Low: ciLo,
                foldCI95High: ciHi,
                isControl: isCtrl,
                values: folds
            )
        }
        
        return BlotQuantificationOut(
            laneRows: laneRows,
            groupStats: groupStats,
            groups: groupsOrder,
            controlGroup: controlGroup,
            globalBackground: globalBackground,
            saturationPolicy: saturationPolicy,
            excludedBands: excludedBands,
            anovaLog2: anovaLog2,
            postHocMethod: postHocMethod
        )
    }
    
    private static func runPythonCLI(arguments: [String]) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonExecutablePath)
        proc.currentDirectoryURL = wbquantPythonRoot
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = wbquantPythonRoot.appendingPathComponent("python").path
        proc.environment = env
        proc.arguments = ["-m", "wbquant.cli"] + arguments
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            // 必须在 waitUntilExit() 之前并发排空 stdout/stderr 管道，避免子进程日志超过 64KB 造成死锁
            let errGroup = DispatchGroup()
            errGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = errPipe.fileHandleForReading.readDataToEndOfFile()
                errGroup.leave()
            }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.wait()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }
    
    // MARK: - 4. 兼容原有 BioImagePlane 双排条带 ROI 积分接口
    
    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : 0.5 * (sorted[mid - 1] + sorted[mid])
    }
    
    public static func autoDetectLanesAndBands(plane: BioImagePlane) -> [BlotLaneModel] {
        let w = plane.width
        let h = plane.height
        let colProf = BioImageProcessor.columnProfile(
            gray: plane.gray,
            width: w,
            height: h,
            y0: Int(Double(h) * 0.12),
            y1: Int(Double(h) * 0.88),
            invert: true
        )
        let lanePeaks = BioImageProcessor.findPeaks(
            profile: colProf,
            minProminence: 0.03,
            minGap: max(8, w / 14),
            smoothWindow: 5
        )
        
        let rowProf = BioImageProcessor.rowProfile(
            gray: plane.gray,
            width: w,
            height: h,
            x0: Int(Double(w) * 0.08),
            x1: Int(Double(w) * 0.92),
            invert: true
        )
        let bandPeaks = BioImageProcessor.findPeaks(
            profile: rowProf,
            minProminence: 0.03,
            minGap: max(10, h / 6),
            smoothWindow: 5
        )
        
        let laneXs: [Double] = lanePeaks.count >= 2
            ? lanePeaks.map(\.fraction)
            : [0.14, 0.28, 0.42, 0.58, 0.72, 0.86]
        let targetY = bandPeaks.first?.fraction ?? 0.36
        let loadingY = bandPeaks.count >= 2 ? bandPeaks[1].fraction : 0.70
        
        let defaultGroups = ["WT", "WT", "TP53-OE", "TP53-OE", "TP53-KO", "TP53-KO"]
        var lanes: [BlotLaneModel] = []
        for (idx, cx) in laneXs.enumerated() {
            let grp = idx < defaultGroups.count ? defaultGroups[idx] : "Group \((idx / 2) + 1)"
            let rep = (idx % 2) + 1
            let bands = [
                BlotBandROI(proteinName: "TP53", isLoadingControl: false, centerY: targetY, widthFrac: 0.085, heightFrac: 0.12),
                BlotBandROI(proteinName: "GAPDH", isLoadingControl: true, centerY: loadingY, widthFrac: 0.085, heightFrac: 0.12)
            ]
            lanes.append(
                BlotLaneModel(
                    index: idx + 1,
                    sampleName: "\(grp)-\(rep)",
                    groupName: grp,
                    centerX: cx,
                    widthFrac: 0.09,
                    bands: bands,
                    included: true
                )
            )
        }
        return lanes
    }
    
    public static func measureBandROI(
        plane: BioImagePlane,
        lane: BlotLaneModel,
        band: BlotBandROI,
        backgroundMode: BlotBackgroundMode,
        manualBackground: Double,
        globalBackground: Double,
        rollingBallSurface: (signedNet: [Double], background: [Double])? = nil
    ) -> (netVolume: Double, background: Double, clippedFraction: Double) {
        let w = plane.width
        let h = plane.height
        let halfW = max(2.0, band.widthFrac * Double(w) * 0.5)
        let halfH = max(2.0, band.heightFrac * Double(h) * 0.5)
        let cx = lane.centerX * Double(w)
        let cy = band.centerY * Double(h)
        
        let x0 = max(0, min(w - 1, Int(round(cx - halfW))))
        let x1 = max(x0 + 1, min(w, Int(round(cx + halfW))))
        let y0 = max(0, min(h - 1, Int(round(cy - halfH))))
        let y1 = max(y0 + 1, min(h, Int(round(cy + halfH))))
        let area = max(1, (x1 - x0) * (y1 - y0))
        
        // 白底黑带模式：仅极暗条带像素 normGray <= 0.006 才属于条带饱和；亮白背景 >= 0.994 为零信号，绝非饱和！
        if backgroundMode == .rollingBall {
            let rb = rollingBallSurface ?? subtractRollingBallNative(
                signal: plane.gray.map { 1.0 - Double($0) / 255.0 },
                width: w,
                height: h,
                radius: max(12, min(w, h) / 6),
                intensityRange: nil
            )
            var signedNet = 0.0
            var bgSum = 0.0
            var clipped = 0
            for y in y0..<y1 {
                let row = y * w
                for x in x0..<x1 {
                    let normGray = Double(plane.gray[row + x]) / 255.0
                    if normGray <= 0.006 { clipped += 1 }
                    signedNet += rb.signedNet[row + x]
                    bgSum += rb.background[row + x]
                }
            }
            return (max(0.0, signedNet), bgSum / Double(area), Double(clipped) / Double(area))
        }
        
        let bg: Double = {
            switch backgroundMode {
            case .manual:
                return min(1.0, max(0.0, manualBackground))
            case .globalMedian:
                return globalBackground
            case .laneMedian:
                var laneSignals: [Double] = []
                for y in 0..<h where y < y0 || y >= y1 {
                    for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 8)) {
                        laneSignals.append(1.0 - Double(plane.gray[y * w + x]) / 255.0)
                    }
                }
                return median(laneSignals)
            case .roiRing, .rollingBall:
                let ring = max(1, Int(round(Double(min(x1 - x0, y1 - y0)) * 0.18)))
                var ringSignals: [Double] = []
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        if x < x0 + ring || x >= x1 - ring || y < y0 + ring || y >= y1 - ring {
                            ringSignals.append(1.0 - Double(plane.gray[y * w + x]) / 255.0)
                        }
                    }
                }
                return median(ringSignals)
            }
        }()
        
        var signedNet = 0.0
        var clipped = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let normGray = Double(plane.gray[y * w + x]) / 255.0
                if normGray <= 0.006 {
                    clipped += 1
                }
                let signal = 1.0 - normGray
                signedNet += (signal - bg)
            }
        }
        return (max(0.0, signedNet), bg, Double(clipped) / Double(area))
    }
    
    public static func quantifyBlot(
        plane: BioImagePlane,
        lanes: [BlotLaneModel],
        backgroundMode: BlotBackgroundMode,
        manualBackground: Double = 0.08,
        normalizationMode: BlotNormalizationMode = .loadingControl,
        controlGroup: String = "WT",
        totalProteinLaneVolumes: [Int: Double]? = nil,
        postHocMethod: ViabilityPostHocMethod = .welchHolm
    ) -> BlotQuantificationOut {
        let invSignal = plane.gray.map { 1.0 - Double($0) / 255.0 }
        var allInverted: [Double] = []
        let step = max(1, (plane.width * plane.height) / 2000)
        for idx in stride(from: 0, to: invSignal.count, by: step) {
            allInverted.append(invSignal[idx])
        }
        let globalBg = median(allInverted)
        
        // 真 2D 椭球面滚动球表面（按图像实际稳健动态范围缩放，确保缩放齐次性且不钻入条带内部）
        let rbSurface: (signedNet: [Double], background: [Double])? = (backgroundMode == .rollingBall || normalizationMode == .totalLane)
            ? subtractRollingBallNative(signal: invSignal, width: plane.width, height: plane.height, radius: max(12, min(plane.width, plane.height) / 6), intensityRange: nil)
            : nil
        
        struct RawLaneMeasure {
            let lane: BlotLaneModel
            let targetVol: Double
            let loadingVol: Double
            let targetBg: Double
            let normVal: Double
            let clippedFraction: Double
        }
        
        var rawMeasures: [RawLaneMeasure] = []
        var groupsOrder: [String] = []
        
        for lane in lanes where lane.included {
            let grp = lane.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !grp.isEmpty && !groupsOrder.contains(grp) {
                groupsOrder.append(grp)
            }
            let targetBand = lane.bands.first(where: { !$0.isLoadingControl }) ?? lane.bands.first
            let loadingBand = lane.bands.first(where: { $0.isLoadingControl })
            
            let tRes = targetBand.map {
                measureBandROI(
                    plane: plane,
                    lane: lane,
                    band: $0,
                    backgroundMode: backgroundMode,
                    manualBackground: manualBackground,
                    globalBackground: globalBg,
                    rollingBallSurface: rbSurface
                )
            } ?? (netVolume: 0.0, background: globalBg, clippedFraction: 0.0)
            
            let lRes = loadingBand.map {
                measureBandROI(
                    plane: plane,
                    lane: lane,
                    band: $0,
                    backgroundMode: backgroundMode,
                    manualBackground: manualBackground,
                    globalBackground: globalBg,
                    rollingBallSurface: rbSurface
                )
            } ?? (netVolume: 1.0, background: globalBg, clippedFraction: 0.0)
            
            // 全泳道总蛋白净积分（TPN，彻底修复旧版误算 target / (target + loading) 的自稀释错误）
            let fullLaneIntegral: Double = {
                if let extTPN = totalProteinLaneVolumes?[lane.index], extTPN > 1e-6 {
                    return extTPN
                }
                let w = plane.width
                let h = plane.height
                let halfW = max(2.0, lane.widthFrac * Double(w) * 0.5)
                let cx = lane.centerX * Double(w)
                let lx0 = max(0, min(w - 1, Int(round(cx - halfW))))
                let lx1 = max(lx0 + 1, min(w, Int(round(cx + halfW))))
                let yPad = max(2, Int(round(Double(h) * 0.04)))
                var sum = 0.0
                for y in yPad..<max(yPad + 1, h - yPad) {
                    let row = y * w
                    for x in lx0..<lx1 {
                        if let rb = rbSurface {
                            sum += rb.signedNet[row + x]
                        } else {
                            sum += (invSignal[row + x] - globalBg)
                        }
                    }
                }
                return max(0.0, sum)
            }()
            
            let normVal: Double = {
                switch normalizationMode {
                case .loadingControl:
                    return lRes.netVolume > 1e-6 ? (tRes.netVolume / lRes.netVolume) : tRes.netVolume
                case .totalLane:
                    return fullLaneIntegral > 1e-6 ? (tRes.netVolume / fullLaneIntegral) : 0.0
                case .rawVolume:
                    return tRes.netVolume
                }
            }()
            
            rawMeasures.append(
                RawLaneMeasure(
                    lane: lane,
                    targetVol: tRes.netVolume,
                    loadingVol: (normalizationMode == .totalLane) ? fullLaneIntegral : lRes.netVolume,
                    targetBg: tRes.background,
                    normVal: normVal,
                    clippedFraction: max(tRes.clippedFraction, normalizationMode == .loadingControl ? lRes.clippedFraction : 0.0)
                )
            )
        }
        
        let resolvedCtrlGroup: String = {
            if groupsOrder.contains(where: { $0.caseInsensitiveCompare(controlGroup) == .orderedSame }) {
                return groupsOrder.first { $0.caseInsensitiveCompare(controlGroup) == .orderedSame }!
            }
            return groupsOrder.first ?? ""
        }()
        
        let ctrlVals = rawMeasures
            .filter { $0.lane.groupName.caseInsensitiveCompare(resolvedCtrlGroup) == .orderedSame }
            .map(\.normVal)
        let posCtrl = ctrlVals.filter { $0 > 1e-12 }
        let ctrlAnchor: Double = {
            if !posCtrl.isEmpty {
                return pow(2.0, posCtrl.reduce(0.0) { $0 + log2($1) } / Double(posCtrl.count))
            }
            return ctrlVals.isEmpty ? 1.0 : max(1e-9, QPCRStatistics.mean(ctrlVals))
        }()
        
        let laneRows: [BlotLaneQuantRow] = rawMeasures.map { m in
            BlotLaneQuantRow(
                laneID: m.lane.id,
                laneIndex: m.lane.index,
                sampleName: m.lane.sampleName,
                groupName: m.lane.groupName,
                targetNetVolume: m.targetVol,
                loadingNetVolume: m.loadingVol,
                targetBackground: m.targetBg,
                normalizedRatio: m.normVal,
                foldChange: m.normVal / ctrlAnchor,
                isSaturated: m.clippedFraction > 0.005,
                clippedPct: m.clippedFraction * 100.0
            )
        }
        
        return summarizeBlotGroupsInLog2Space(
            laneRows: laneRows,
            groupsOrder: groupsOrder,
            controlGroup: resolvedCtrlGroup,
            globalBackground: globalBg,
            saturationPolicy: .warnOnly,
            excludedBands: [],
            postHocMethod: postHocMethod
        )
    }
    
    public static func exportBlotCSV(_ out: BlotQuantificationOut) -> String {
        var lines = [
            "# Saturation_Policy: \(out.saturationPolicy.rawValue)",
            "Lane,Sample,Group,Target_Net_IOD,Loading_Net_IOD,Target_Bg,Normalized_Ratio,Fold_Change,Saturated,Clipped_Pct,Excluded_From_Stats"
        ]
        let excludedSet = Set(out.excludedBands.map(\.laneIndex))
        for r in out.laneRows {
            let isEx = excludedSet.contains(r.laneIndex)
            lines.append(
                "\(r.laneIndex),\(r.sampleName),\(r.groupName),\(String(format: "%.2f", r.targetNetVolume)),\(String(format: "%.2f", r.loadingNetVolume)),\(String(format: "%.4f", r.targetBackground)),\(String(format: "%.4f", r.normalizedRatio)),\(String(format: "%.4f", r.foldChange)),\(r.isSaturated ? "YES" : "NO"),\(String(format: "%.2f", r.clippedPct)),\(isEx ? "YES" : "NO")"
            )
        }
        if !out.excludedBands.isEmpty {
            lines.append("# Excluded_Saturated_Bands:")
            for ex in out.excludedBands {
                lines.append("# \(ex.bandID),Lane=L\(ex.laneIndex),Group=\(ex.groupName),Reason=\(ex.reason)")
            }
        }
        return lines.joined(separator: "\n")
    }
    
    public static func exportWBAnalysisCSV(_ res: WBAnalysisResult, quantOut: BlotQuantificationOut? = nil) -> String {
        let policy = quantOut?.saturationPolicy ?? res.params.saturationPolicy
        var lines = [
            "# Saturation_Policy: \(policy.rawValue) (threshold=\(String(format: "%.1f%%", res.params.saturationRatioThreshold * 100.0)))",
            "Band_ID,Lane,Row,X,Y,Width,Height,Peak_Y,Raw_IOD,Background_IOD,Net_IOD,Normalized_Ratio,Fold_Change,Saturated,Saturated_Pct,Excluded_From_Stats"
        ]
        let excludedLaneSet = Set((quantOut?.excludedBands ?? []).map(\.laneIndex))
        for b in res.bands {
            let isEx = (policy == .excludeFromStats) && (b.isSaturated || excludedLaneSet.contains(b.laneIndex + 1))
            lines.append(
                "\(b.id),\(b.laneIndex + 1),\(b.rowIndex + 1),\(b.x),\(b.y),\(b.width),\(b.height),\(b.peakY),\(String(format: "%.1f", b.rawIOD)),\(String(format: "%.1f", b.backgroundIOD)),\(String(format: "%.1f", b.netIOD)),\(String(format: "%.4f", b.normalizedRatio)),\(String(format: "%.4f", b.foldChange)),\(b.isSaturated ? "YES" : "NO"),\(String(format: "%.2f", b.saturatedRatio * 100.0)),\(isEx ? "YES" : "NO")"
            )
        }
        if let exList = quantOut?.excludedBands, !exList.isEmpty {
            lines.append("# Excluded_Saturated_Bands:")
            for ex in exList {
                lines.append("# \(ex.bandID),Lane=L\(ex.laneIndex),Group=\(ex.groupName),Reason=\(ex.reason)")
            }
        }
        return lines.joined(separator: "\n")
    }
    
    /// 构建 Western Blot 定量分析的 AnalysisRun 机器可读溯源记录 (P09 / P14 / P15)
    public static func buildWBAnalysisRun(
        result: WBAnalysisResult,
        quantOut: BlotQuantificationOut? = nil,
        exposureRecommendation: WBExposureRecommendation? = nil,
        backgroundMode: String = "rollingBall",
        normalizeByLoadingControl: Bool = true,
        manualEdits: [AnalysisRun.ManualEdit] = [],
        outputs: [String] = [],
        exportDirectoryURL: URL? = nil,
        engine: String = "swift-native",
        linkedPlasmidIDs: [String] = []
    ) -> AnalysisRun {
        var inputs: [AnalysisRun.InputFile] = []
        let imgURL = URL(fileURLWithPath: result.imagePath)
        if let inputRec = AnalysisRun.makeInputFile(at: imgURL, relativeTo: exportDirectoryURL) {
            inputs.append(inputRec)
        }
        let policy = quantOut?.saturationPolicy ?? result.params.saturationPolicy
        var paramsDict: [String: AnyCodableValue] = [
            "backgroundMode": .string(backgroundMode),
            "rollingBallRadius": .int(result.params.rollingBallRadius),
            "expectedLanes": .int(result.params.expectedLanes),
            "bandProminence": .double(result.params.bandProminence),
            "stripThreshold": .double(result.params.stripThreshold),
            "primaryBandOnly": .bool(result.params.primaryBandOnly),
            "controlLaneIndex": .int(result.params.controlLaneIndex),
            "normalizeByLoadingControl": .bool(normalizeByLoadingControl),
            "saturationPolicy": .string(policy.rawValue),
            "saturationRatioThreshold": .double(result.params.saturationRatioThreshold),
            "bitDepth": .int(result.bitDepth)
        ]
        if let expRec = exposureRecommendation {
            paramsDict["recommendedExposureSeconds"] = .double(expRec.recommendedExposureSeconds)
            paramsDict["recommendedImagePath"] = .string(expRec.recommendedImagePath)
            paramsDict["allBandsLinear"] = .bool(expRec.allBandsLinear)
        }
        let exclusions: [AnalysisRun.Exclusion] = (quantOut?.excludedBands ?? []).map {
            AnalysisRun.Exclusion(itemID: $0.bandID, reason: $0.reason)
        }
        return AnalysisRun(
            schemaVersion: 2,
            module: NavItem.westernBlot.rawValue,
            engine: engine,
            inputs: inputs,
            parameters: paramsDict,
            manualEdits: manualEdits,
            exclusions: exclusions,
            outputs: outputs,
            linkedPlasmidIDs: linkedPlasmidIDs
        )
    }
    
    /// 导出 WB CSV 并同目录生成 <basename>.run.json 溯源伴随文件（绝不修改原始图像文件）(P09 / P15)
    @discardableResult
    public static func exportWBAnalysisCSVWithProvenance(
        _ res: WBAnalysisResult,
        quantOut: BlotQuantificationOut? = nil,
        exposureRecommendation: WBExposureRecommendation? = nil,
        to outputCSVURL: URL,
        backgroundMode: String = "rollingBall",
        normalizeByLoadingControl: Bool = true,
        manualEdits: [AnalysisRun.ManualEdit] = [],
        engine: String = "swift-native",
        linkedPlasmidIDs: [String] = []
    ) throws -> (csvURL: URL, sidecarURL: URL, run: AnalysisRun) {
        let csvText = exportWBAnalysisCSV(res, quantOut: quantOut)
        try csvText.write(to: outputCSVURL, atomically: true, encoding: .utf8)
        let run = buildWBAnalysisRun(
            result: res,
            quantOut: quantOut,
            exposureRecommendation: exposureRecommendation,
            backgroundMode: backgroundMode,
            normalizeByLoadingControl: normalizeByLoadingControl,
            manualEdits: manualEdits,
            outputs: [outputCSVURL.lastPathComponent],
            exportDirectoryURL: outputCSVURL.deletingLastPathComponent(),
            engine: engine,
            linkedPlasmidIDs: linkedPlasmidIDs
        )
        let sidecarURL = try run.writeSidecarJSON(alongsideOutputURL: outputCSVURL)
        return (outputCSVURL, sidecarURL, run)
    }

    // MARK: - 5. WB 多曝光线性范围检查与最佳定量曝光推荐 (P14)

    public struct WBExposurePoint: Codable, Equatable, Sendable {
        public let exposureSeconds: Double
        public let netIOD: Double
        
        public init(exposureSeconds: Double, netIOD: Double) {
            self.exposureSeconds = exposureSeconds
            self.netIOD = netIOD
        }
    }

    public struct WBBandLinearityResult: Codable, Identifiable, Equatable, Sendable {
        public var id: String { bandID }
        public let bandID: String
        public let laneIndex: Int
        public let rowIndex: Int
        public let points: [WBExposurePoint]
        public let slope: Double
        public let intercept: Double
        public let r2: Double
        public let isSaturatedInMaxExposure: Bool
        public let isLinear: Bool

        public init(
            bandID: String,
            laneIndex: Int,
            rowIndex: Int,
            points: [WBExposurePoint],
            slope: Double,
            intercept: Double,
            r2: Double,
            isSaturatedInMaxExposure: Bool,
            isLinear: Bool
        ) {
            self.bandID = bandID
            self.laneIndex = laneIndex
            self.rowIndex = rowIndex
            self.points = points
            self.slope = slope
            self.intercept = intercept
            self.r2 = r2
            self.isSaturatedInMaxExposure = isSaturatedInMaxExposure
            self.isLinear = isLinear
        }
    }

    public struct WBExposureSeriesFrame: Codable, Identifiable, Equatable, Sendable {
        public var id: String { imagePath }
        public let imagePath: String
        public let exposureSeconds: Double
        public let isSaturated: Bool
        public let maxSignal: Double
        public let bandNetIODs: [String: Double]
        
        public init(
            imagePath: String,
            exposureSeconds: Double,
            isSaturated: Bool,
            maxSignal: Double,
            bandNetIODs: [String: Double]
        ) {
            self.imagePath = imagePath
            self.exposureSeconds = exposureSeconds
            self.isSaturated = isSaturated
            self.maxSignal = maxSignal
            self.bandNetIODs = bandNetIODs
        }
    }

    public struct WBExposureRecommendation: Codable, Equatable, Sendable {
        public let recommendedImagePath: String
        public let recommendedExposureSeconds: Double
        public let reason: String
        public let allBandsLinear: Bool
        public let bandLinearities: [WBBandLinearityResult]
        public let frames: [WBExposureSeriesFrame]
        
        public init(
            recommendedImagePath: String,
            recommendedExposureSeconds: Double,
            reason: String,
            allBandsLinear: Bool,
            bandLinearities: [WBBandLinearityResult],
            frames: [WBExposureSeriesFrame]
        ) {
            self.recommendedImagePath = recommendedImagePath
            self.recommendedExposureSeconds = recommendedExposureSeconds
            self.reason = reason
            self.allBandsLinear = allBandsLinear
            self.bandLinearities = bandLinearities
            self.frames = frames
        }
    }

    /// 从文件名或描述文本自动提取曝光秒数（支持 _10s、30sec、500ms、exposure=15 等格式）(P14)
    public static func parseExposureSeconds(from filePathOrName: String) -> Double? {
        let name = URL(fileURLWithPath: filePathOrName).deletingPathExtension().lastPathComponent
        let pattern = #"(?i)(?:^|[_\-\s]|exp(?:osure)?[=_\-\s]?)(\d+(?:\.\d+)?)\s*(ms|sec|s)\b"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let valRange = Range(match.range(at: 1), in: name),
           let unitRange = Range(match.range(at: 2), in: name),
           let val = Double(name[valRange]) {
            let unit = name[unitRange].lowercased()
            return unit == "ms" ? (val / 1000.0) : val
        }
        return nil
    }

    /// 按曝光倍数缩放 `RawGrayBuffer16` 信号并在 `clampCeiling` (默认 65535) 截断标记过曝像素 (P14)
    public static func scaleBufferForExposure(
        _ base: RawGrayBuffer16,
        factor: Double,
        clampCeiling: Double = 65535.0,
        saturationCutoff: Double = 65400.0
    ) -> RawGrayBuffer16 {
        let n = base.signal.count
        var sig = [Double](repeating: 0, count: n)
        var sat = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let v = min(clampCeiling, max(0.0, base.signal[i] * factor))
            sig[i] = v
            sat[i] = (v >= saturationCutoff) || (base.saturated.indices.contains(i) && base.saturated[i] && factor >= 1.0)
        }
        return RawGrayBuffer16(
            width: base.width,
            height: base.height,
            bitDepth: 16,
            invertedPolarity: base.invertedPolarity,
            signal: sig,
            saturated: sat
        )
    }

    /// 对同张膜的多张不同曝光时间图像序列执行全条带线性动态范围核验与最佳定量曝光推荐 (P14)
    public static func analyzeExposureSeries(
        series: [(imagePath: String, exposureSeconds: Double, buffer: RawGrayBuffer16?)],
        params: WBAnalysisParams = WBAnalysisParams(),
        referenceBands: [WBBand]? = nil,
        r2LinearityThreshold: Double = 0.98
    ) -> WBExposureRecommendation? {
        let sortedSeries = series.filter { $0.exposureSeconds > 0 }.sorted { $0.exposureSeconds < $1.exposureSeconds }
        guard sortedSeries.count >= 2 else { return nil }

        var loadedFrames: [(imagePath: String, exposureSeconds: Double, buffer: RawGrayBuffer16)] = []
        for item in sortedSeries {
            let buf = item.buffer ?? loadRawGrayBuffer(at: item.imagePath)
            if let buf = buf {
                loadedFrames.append((item.imagePath, item.exposureSeconds, buf))
            }
        }
        guard loadedFrames.count >= 2 else { return nil }

        // 以最长曝光的检测结果作为统一泳道/条带 ROI（若调用方传入 referenceBands 则直接使用；若最长曝光因严重过曝检出条带不足则回退次长曝光）
        let longestFrame = loadedFrames.last!
        let longestResult = analyzeNativeBuffer(longestFrame.buffer, imagePath: longestFrame.imagePath, params: params)
        let anchorBands: [WBBand] = {
            if let explicit = referenceBands, !explicit.isEmpty {
                return explicit
            }
            if loadedFrames.count >= 2 {
                let prevFrame = loadedFrames[loadedFrames.count - 2]
                let prevResult = analyzeNativeBuffer(prevFrame.buffer, imagePath: prevFrame.imagePath, params: params)
                if prevResult.bands.count > longestResult.bands.count {
                    return prevResult.bands
                }
            }
            return longestResult.bands
        }()
        guard !anchorBands.isEmpty else { return nil }

        var frameSummaries: [WBExposureSeriesFrame] = []
        var bandPointsMap: [String: [WBExposurePoint]] = [:]
        var bandSaturatedInMax: [String: Bool] = [:]

        for (fIdx, frame) in loadedFrames.enumerated() {
            let requantBands = requantify(
                imagePath: frame.imagePath,
                bands: anchorBands,
                params: params,
                fallbackBuffer: frame.buffer
            )
            var iodMap: [String: Double] = [:]
            var frameAnySaturated = false
            for b in requantBands {
                iodMap[b.id] = b.netIOD
                if b.isSaturated {
                    frameAnySaturated = true
                }
                bandPointsMap[b.id, default: []].append(
                    WBExposurePoint(exposureSeconds: frame.exposureSeconds, netIOD: b.netIOD)
                )
                if fIdx == loadedFrames.count - 1 {
                    bandSaturatedInMax[b.id] = b.isSaturated
                }
            }
            frameSummaries.append(
                WBExposureSeriesFrame(
                    imagePath: frame.imagePath,
                    exposureSeconds: frame.exposureSeconds,
                    isSaturated: frameAnySaturated,
                    maxSignal: frame.buffer.signal.max() ?? 0.0,
                    bandNetIODs: iodMap
                )
            )
        }

        var bandLinearities: [WBBandLinearityResult] = []
        var allLinear = true
        let unsatFrameExposureSet = Set(frameSummaries.filter { !$0.isSaturated }.map(\.exposureSeconds))

        for baseBand in anchorBands {
            let pts = bandPointsMap[baseBand.id] ?? []
            guard pts.count >= 2 else { continue }
            // 自动剔除已触发饱和上限的帧，再对其余未饱和帧执行 OLS 线性拟合（避免过饱和平台扭曲未饱和区线性斜率）
            let unsatPts = pts.filter { unsatFrameExposureSet.contains($0.exposureSeconds) }
            let fitPts = unsatPts.count >= 2 ? unsatPts : pts
            let regPoints = fitPts.map { (x: $0.exposureSeconds, y: $0.netIOD) }
            let reg = QPCRStatistics.linearRegression(regPoints)
            let slope = reg?.slope ?? 0.0
            let intercept = reg?.intercept ?? 0.0
            let r2 = reg?.r2 ?? 0.0
            let satMax = bandSaturatedInMax[baseBand.id] ?? false
            let isLin = (slope > 0) && (r2 >= r2LinearityThreshold) && !satMax
            if !isLin {
                allLinear = false
            }
            bandLinearities.append(
                WBBandLinearityResult(
                    bandID: baseBand.id,
                    laneIndex: baseBand.laneIndex,
                    rowIndex: baseBand.rowIndex,
                    points: pts,
                    slope: (slope * 1000.0).rounded() / 1000.0,
                    intercept: (intercept * 100.0).rounded() / 100.0,
                    r2: (r2 * 10000.0).rounded() / 10000.0,
                    isSaturatedInMaxExposure: satMax,
                    isLinear: isLin
                )
            )
        }

        let nonSaturatedFrames = frameSummaries.filter { !$0.isSaturated }
        let recommendedFrame: WBExposureSeriesFrame
        let reason: String

        if let bestSafe = nonSaturatedFrames.last {
            recommendedFrame = bestSafe
            reason = L10n.tr("推荐 \(Int(bestSafe.exposureSeconds))s 曝光：所有条带处于线性动态响应区间且未过曝 (信噪比最高)", "Recommended \(Int(bestSafe.exposureSeconds))s exposure: all bands within linear dynamic range (best SNR)")
        } else {
            recommendedFrame = frameSummaries.first!
            reason = L10n.tr("全部曝光帧均存在过曝条带；自动回退最短曝光 (\(Int(recommendedFrame.exposureSeconds))s) 以减小失真", "All exposures saturated; falling back to shortest frame (\(Int(recommendedFrame.exposureSeconds))s)")
        }

        return WBExposureRecommendation(
            recommendedImagePath: recommendedFrame.imagePath,
            recommendedExposureSeconds: recommendedFrame.exposureSeconds,
            reason: reason,
            allBandsLinear: allLinear,
            bandLinearities: bandLinearities,
            frames: frameSummaries
        )
    }
}
