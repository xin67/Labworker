import Foundation
import CoreGraphics
import ImageIO
import AppKit

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
        isPrimary: Bool = true
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
    }
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
        saturationRatioThreshold: Double = 0.01
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
    }
}

public struct WBAnalysisResult: Codable, Equatable, Sendable {
    public var imagePath: String
    public var width: Int
    public var height: Int
    public var bitDepth: Int
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
        params: WBAnalysisParams
    ) {
        self.imagePath = imagePath
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.invertedPolarity = invertedPolarity
        self.skewAngle = skewAngle
        self.stripROI = stripROI
        self.lanes = lanes
        self.bands = bands
        self.params = params
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
            list.append(("raw_chemi", "16-bit 原图", "sparkles.rectangle.stack.fill", p))
        }
        if let p = chemi {
            list.append(("chemi", "发光图层", "rays", p))
        }
        if let p = brightfield {
            list.append(("brightfield", "明场图层", "camera.aperture", p))
        }
        if let p = overlay {
            list.append(("overlay", "合成叠加", "square.3.layers.3d.down.right", p))
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
    public let meanFold: Double
    public let sdFold: Double?
    public let semFold: Double?
    public let pValue: Double?
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
        self.isControl = isControl
        self.values = values
    }
    
    public var significanceText: String {
        guard let p = pValue else { return isControl ? "Ref" : "—" }
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
    
    public init(
        laneRows: [BlotLaneQuantRow],
        groupStats: [BlotGroupStatSummary],
        groups: [String],
        controlGroup: String,
        globalBackground: Double,
        saturationPolicy: WBSaturationPolicy = .excludeFromStats,
        excludedBands: [WBExcludedBandRecord] = []
    ) {
        self.laneRows = laneRows
        self.groupStats = groupStats
        self.groups = groups
        self.controlGroup = controlGroup
        self.globalBackground = globalBackground
        self.saturationPolicy = saturationPolicy
        self.excludedBands = excludedBands
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
            saturated: [Bool]
        ) {
            self.width = width
            self.height = height
            self.bitDepth = bitDepth
            self.invertedPolarity = invertedPolarity
            self.signal = signal
            self.saturated = saturated
        }
    }
    
    /// 无损读取 16-bit 或 8-bit 原始 TIFF/PNG 灰度数据并标准化极性
    public static func loadRawGrayBuffer(at path: String) -> RawGrayBuffer16? {
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
            return buildStandardizedBuffer(rawValues: buf16.map { Double($0) }, width: w, height: h, bitDepth: 16)
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
            return buildStandardizedBuffer(rawValues: buf8.map { Double($0) }, width: w, height: h, bitDepth: 8)
        }
    }
    
    /// 从内存 `BioImagePlane` 构建标准化定量缓冲（用于内置示范膜或直接拖入图像）
    public static func bufferFromBioImagePlane(_ plane: BioImagePlane) -> RawGrayBuffer16 {
        let rawVals = plane.gray.map { Double($0) }
        return buildStandardizedBuffer(rawValues: rawVals, width: plane.width, height: plane.height, bitDepth: 8)
    }
    
    private static func buildStandardizedBuffer(
        rawValues: [Double],
        width: Int,
        height: Int,
        bitDepth: Int
    ) -> RawGrayBuffer16 {
        let n = rawValues.count
        guard n > 0 else {
            return RawGrayBuffer16(width: width, height: height, bitDepth: bitDepth, invertedPolarity: false, signal: [], saturated: [])
        }
        var minVal = Double.greatestFiniteMagnitude
        var maxVal = -Double.greatestFiniteMagnitude
        let step = max(1, n / 4096)
        var sampleVals: [Double] = []
        sampleVals.reserveCapacity(4096)
        for i in stride(from: 0, to: n, by: step) {
            let v = rawValues[i]
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
            sampleVals.append(v)
        }
        for v in rawValues {
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
        }
        let med = median(sampleVals)
        let mid = 0.5 * (minVal + maxVal)
        let inverted = med > mid
        let ceiling = max(maxVal, Double((1 << bitDepth) - 1))
        
        var signal = [Double](repeating: 0, count: n)
        var sat = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let v = rawValues[i]
            signal[i] = inverted ? max(0.0, ceiling - v) : max(0.0, v)
            if bitDepth == 16 {
                sat[i] = inverted ? (v <= 15.0) : (v >= 65400.0)
            } else {
                sat[i] = inverted ? (v <= 1.0) : (v >= 254.0)
            }
        }
        return RawGrayBuffer16(
            width: width,
            height: height,
            bitDepth: bitDepth,
            invertedPolarity: inverted,
            signal: signal,
            saturated: sat
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
                "--control-lane", "\(params.controlLaneIndex)"
            ]
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
    
    /// 纯 Swift 原生 16-bit 自动圈定管线（1:1 复刻 wbquant 的有效膜条定位、下采样形态学背景扣除、波谷分泳道与四边收紧圈定）
    public static func analyzeNative16Bit(
        imagePath: String,
        params: WBAnalysisParams = WBAnalysisParams(),
        customROI: WBRect? = nil
    ) -> WBAnalysisResult? {
        guard let buf = loadRawGrayBuffer(at: imagePath) else { return nil }
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
        
        // 1. 下采样 Rolling-ball / 形态学大核开运算背景曲面扣除
        let corrected = subtractRollingBallNative(signal: buf.signal, width: w, height: h, radius: params.rollingBallRadius)
        
        // 2. 有效膜条区域（Active Strip ROI）自适应定位
        let stripROI = customROI ?? detectStripROINative(signal: corrected, width: w, height: h, thresholdRatio: params.stripThreshold)
        
        // 3. 波谷列投影划分泳道并计算高斯加权行剖面
        let lanes = detectLanesNative(signal: corrected, width: w, height: h, stripROI: stripROI, expectedLanes: params.expectedLanes)
        
        // 4. 在每条泳道内寻峰并执行上下左右四边自适应收紧与跨泳道同行聚类对齐
        let rawDetections = detectBandsInLanesNative(signal: corrected, width: w, height: h, lanes: lanes, params: params)
        let aligned = alignBandRowsNative(detections: rawDetections, rowTolerance: max(12, stripROI.height / 14))
        
        // 5. 计算 IOD、局部基线扣除、过曝占比与相对对照 Fold Change
        let bands = quantifyAlignedBandsNative(
            rawSignal: buf.signal,
            correctedSignal: corrected,
            saturatedMask: buf.saturated,
            width: w,
            height: h,
            alignedBoxes: aligned,
            controlLaneIndex: params.controlLaneIndex,
            saturationRatioThreshold: params.saturationRatioThreshold
        )
        
        return WBAnalysisResult(
            imagePath: imagePath,
            width: w,
            height: h,
            bitDepth: buf.bitDepth,
            invertedPolarity: buf.invertedPolarity,
            skewAngle: 0.0,
            stripROI: stripROI,
            lanes: lanes,
            bands: bands,
            params: params
        )
    }
    
    /// 手动拖拽平移或拉伸圈定框后毫秒级重算精确 IOD
    public static func requantify(
        imagePath: String,
        bands: [WBBand],
        params: WBAnalysisParams,
        fallbackBuffer: RawGrayBuffer16? = nil
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
                let args = [
                    "requantify",
                    imagePath,
                    "--boxes-json", jsonStr,
                    "--radius", "\(params.rollingBallRadius)",
                    "--control-lane", "\(params.controlLaneIndex)"
                ]
                if let data = runPythonCLI(arguments: args),
                   let updated = try? JSONDecoder().decode([WBBand].self, from: data) {
                    return updated
                }
            }
        }
        
        guard let buf = loadRawGrayBuffer(at: imagePath) ?? fallbackBuffer else {
            return bands
        }
        let corrected = subtractRollingBallNative(signal: buf.signal, width: buf.width, height: buf.height, radius: params.rollingBallRadius)
        let aligned = bands.map { b in
            (b.laneIndex, b.rowIndex, b.x, b.y, b.width, b.height, b.peakY)
        }
        return quantifyAlignedBandsNative(
            rawSignal: buf.signal,
            correctedSignal: corrected,
            saturatedMask: buf.saturated,
            width: buf.width,
            height: buf.height,
            alignedBoxes: aligned,
            controlLaneIndex: params.controlLaneIndex,
            saturationRatioThreshold: params.saturationRatioThreshold
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
    
    // MARK: - 3.5 原生 16-bit Rolling-Ball 背景扣除、膜区定位与四边收紧实现
    
    private static func subtractRollingBallNative(
        signal: [Double],
        width: Int,
        height: Int,
        radius: Int
    ) -> [Double] {
        guard width > 0, height > 0, signal.count == width * height else { return signal }
        if radius <= 0 {
            let bgMed = median(signal)
            return signal.map { max(0.0, $0 - bgMed) }
        }
        // 下采样 4x 计算形态学灰度开运算背景曲面并双线性插值回原图（耗时 < 8ms）
        let scale = min(width, height) > 360 ? 4 : (min(width, height) > 180 ? 2 : 1)
        let sw = max(4, width / scale)
        let sh = max(4, height / scale)
        var small = [Double](repeating: 0, count: sw * sh)
        for sy in 0..<sh {
            let oy = min(height - 1, sy * scale)
            for sx in 0..<sw {
                let ox = min(width - 1, sx * scale)
                small[sy * sw + sx] = signal[oy * width + ox]
            }
        }
        let rSmall = max(2, radius / scale)
        let eroded = grayscaleMorphStep1D(small, width: sw, height: sh, radius: rSmall, isErode: true)
        let opened = grayscaleMorphStep1D(eroded, width: sw, height: sh, radius: rSmall, isErode: false)
        
        var corrected = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let fy = Double(y) / Double(scale)
            let y0 = min(sh - 1, Int(floor(fy)))
            let y1 = min(sh - 1, y0 + 1)
            let wy = fy - Double(y0)
            for x in 0..<width {
                let fx = Double(x) / Double(scale)
                let x0 = min(sw - 1, Int(floor(fx)))
                let x1 = min(sw - 1, x0 + 1)
                let wx = fx - Double(x0)
                let top = opened[y0 * sw + x0] * (1.0 - wx) + opened[y0 * sw + x1] * wx
                let bot = opened[y1 * sw + x0] * (1.0 - wx) + opened[y1 * sw + x1] * wx
                let bg = top * (1.0 - wy) + bot * wy
                corrected[y * width + x] = max(0.0, signal[y * width + x] - bg)
            }
        }
        return corrected
    }
    
    private static func grayscaleMorphStep1D(
        _ input: [Double],
        width: Int,
        height: Int,
        radius: Int,
        isErode: Bool
    ) -> [Double] {
        var temp = [Double](repeating: 0, count: width * height)
        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                var best = input[row + x]
                for nx in x0...x1 {
                    let v = input[row + nx]
                    if isErode ? (v < best) : (v > best) { best = v }
                }
                temp[row + x] = best
            }
        }
        for y in 0..<height {
            let y0 = max(0, y - radius)
            let y1 = min(height - 1, y + radius)
            for x in 0..<width {
                var best = temp[y * width + x]
                for ny in y0...y1 {
                    let v = temp[ny * width + x]
                    if isErode ? (v < best) : (v > best) { best = v }
                }
                out[y * width + x] = best
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
        let vmax = signal.max() ?? 0.0
        guard vmax > 1e-6 else {
            return WBRect(x: 0, y: 0, width: width, height: height)
        }
        var posVals: [Double] = []
        let step = max(1, (width * height) / 8192)
        for i in stride(from: 0, to: signal.count, by: step) where signal[i] > vmax * 0.01 {
            posVals.append(signal[i])
        }
        posVals.sort()
        let robustRef = posVals.count > 20 ? posVals[min(posVals.count - 1, Int(Double(posVals.count) * 0.92))] : vmax
        let refPeak = min(vmax, max(robustRef * 1.25, vmax * 0.25))
        let cutoff = refPeak * max(0.03, min(0.45, thresholdRatio))
        
        // 计算行/列能量分布以稳健锁定膜条边界（自动剔除边缘孤立噪点）
        var colActive = [Int](repeating: 0, count: width)
        var rowActive = [Int](repeating: 0, count: height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where signal[row + x] > cutoff {
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
        for ry in 0..<lh {
            let row = (y0 + ry) * width
            var acc = 0.0
            for rx in 0..<lw {
                acc += signal[row + x0 + rx] * weights[rx]
            }
            prof[ry] = acc
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
        for x in 0..<stripW {
            var s = 0.0
            for y in stripROI.y..<stripROI.y2 {
                s += signal[y * width + (stripROI.x + x)]
            }
            colMean[x] = s / Double(stripH)
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
    
    private static func quantifyAlignedBandsNative(
        rawSignal: [Double],
        correctedSignal: [Double],
        saturatedMask: [Bool],
        width: Int,
        height: Int,
        alignedBoxes: [(Int, Int, Int, Int, Int, Int, Int)],
        controlLaneIndex: Int,
        saturationRatioThreshold: Double = 0.01
    ) -> [WBBand] {
        var prelim: [WBBand] = []
        for (laneIdx, rowIdx, bx, by, bw, bh, peakY) in alignedBoxes {
            let x0 = max(0, min(width - 1, bx))
            let y0 = max(0, min(height - 1, by))
            let x1 = max(x0 + 1, min(width, bx + bw))
            let y1 = max(y0 + 1, min(height, by + bh))
            
            // 取上下外侧各 2px 边缘中位数作为残余局部基线（等效 ImageJ 峰底连线闭合扣除）
            var borderVals: [Double] = []
            for ty in max(0, y0 - 2)..<y0 {
                for tx in x0..<x1 { borderVals.append(correctedSignal[ty * width + tx]) }
            }
            for by2 in y1..<min(height, y1 + 2) {
                for tx in x0..<x1 { borderVals.append(correctedSignal[by2 * width + tx]) }
            }
            let localBase = borderVals.isEmpty ? 0.0 : median(borderVals)
            
            var rawIOD = 0.0
            var netIOD = 0.0
            var patchMax = 0.0
            for y in y0..<y1 {
                let row = y * width
                for x in x0..<x1 {
                    let cVal = correctedSignal[row + x]
                    if cVal > patchMax { patchMax = cVal }
                    rawIOD += rawSignal[row + x]
                    netIOD += max(0.0, cVal - localBase)
                }
            }
            let bgIOD = max(0.0, rawIOD - netIOD)
            
            var coreCount = 0
            var satCoreCount = 0
            let coreCutoff = patchMax * 0.25
            for y in y0..<y1 {
                let row = y * width
                for x in x0..<x1 {
                    if patchMax <= 0 || correctedSignal[row + x] >= coreCutoff {
                        coreCount += 1
                        if saturatedMask[row + x] { satCoreCount += 1 }
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
                    height: y1 - y0,
                    peakY: peakY,
                    rawIOD: rawIOD,
                    backgroundIOD: bgIOD,
                    netIOD: netIOD,
                    normalizedRatio: 1.0,
                    foldChange: 1.0,
                    saturatedRatio: satRatio,
                    isSaturated: satRatio >= max(0.001, saturationRatioThreshold),
                    isPrimary: (rowIdx == 0)
                )
            )
        }
        
        // 按行计算相对 controlLaneIndex 的 Fold Change；若同膜包含 >=2 行（目的蛋白 Row 0 + 内参蛋白 Row 1），支持跨行比值
        let byRow = Dictionary(grouping: prelim, by: \.rowIndex)
        var finalBands: [WBBand] = []
        for rIdx in byRow.keys.sorted() {
            guard let rowBands = byRow[rIdx], !rowBands.isEmpty else { continue }
            let ctrl = rowBands.first(where: { $0.laneIndex == controlLaneIndex }) ?? rowBands[0]
            let baseIOD = max(1e-6, ctrl.netIOD)
            for var b in rowBands {
                let fc = b.netIOD / baseIOD
                b.normalizedRatio = fc
                b.foldChange = fc
                b.isPrimary = (rIdx == 0)
                finalBands.append(b)
            }
        }
        return finalBands
    }
    
    /// 将 `WBAnalysisResult` 中的泳道与条带按生物学重复分组汇总，支持按 `WBSaturationPolicy` 阻断过曝条带参与统计 (P03)
    public static func computeGroupStatistics(
        from result: WBAnalysisResult,
        laneGroups: [Int: String],
        controlGroup: String = "WT",
        normalizeBySecondRowIfPresent: Bool = true,
        saturationPolicy: WBSaturationPolicy? = nil
    ) -> BlotQuantificationOut {
        let policy = saturationPolicy ?? result.params.saturationPolicy
        let satThresh = max(0.001, result.params.saturationRatioThreshold)
        let row0Bands = result.bands.filter { $0.rowIndex == 0 }
        let row1ByLane = Dictionary(uniqueKeysWithValues: result.bands.filter { $0.rowIndex == 1 }.map { ($0.laneIndex, $0) })
        let hasLoadingRow = normalizeBySecondRowIfPresent && !row1ByLane.isEmpty
        
        var groupsOrder: [String] = []
        var excludedBands: [WBExcludedBandRecord] = []
        var rawRows: [(bandID: String, laneIdx: Int, sample: String, group: String, targetVol: Double, loadingVol: Double, bg: Double, ratio: Double, sat: Bool, satPct: Double, reason: String)] = []
        
        for b in row0Bands.sorted(by: { $0.laneIndex < $1.laneIndex }) {
            let defaultGrp = (b.laneIndex < 2) ? "WT" : ((b.laneIndex < 4) ? "Group-2" : "Group-3")
            let grp = laneGroups[b.laneIndex] ?? defaultGrp
            if !groupsOrder.contains(grp) { groupsOrder.append(grp) }
            let loadingBand = row1ByLane[b.laneIndex]
            let loadVol = loadingBand?.netIOD ?? 1.0
            let ratio = hasLoadingRow && loadVol > 1e-6 ? (b.netIOD / loadVol) : b.netIOD
            let targetSat = b.isSaturated || (b.saturatedRatio >= satThresh)
            let loadingSat = (loadingBand?.isSaturated ?? false) || ((loadingBand?.saturatedRatio ?? 0.0) >= satThresh)
            let isSat = targetSat || loadingSat
            let maxSatPct = max(b.saturatedRatio, loadingBand?.saturatedRatio ?? 0.0) * 100.0
            let satReason: String = {
                if targetSat && loadingSat {
                    return String(format: "目的条带与内参条带均过曝 (饱和像素占比 %.1f%%)", maxSatPct)
                } else if targetSat {
                    return String(format: "目的条带 (%@) 信号过曝 (饱和像素占比 %.1f%%)", b.id, b.saturatedRatio * 100.0)
                } else if loadingSat, let lb = loadingBand {
                    return String(format: "内参条带 (%@) 信号过曝 (饱和像素占比 %.1f%%)", lb.id, lb.saturatedRatio * 100.0)
                }
                return ""
            }()
            if policy == .excludeFromStats && isSat {
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
                reason: satReason
            ))
        }
        
        let resolvedCtrl = groupsOrder.first(where: { $0.caseInsensitiveCompare(controlGroup) == .orderedSame }) ?? (groupsOrder.first ?? "WT")
        let ctrlValidVals = rawRows.filter {
            $0.group.caseInsensitiveCompare(resolvedCtrl) == .orderedSame && !(policy == .excludeFromStats && $0.sat)
        }.map(\.ratio)
        let fallbackCtrlVals = rawRows.filter { $0.group.caseInsensitiveCompare(resolvedCtrl) == .orderedSame }.map(\.ratio)
        let activeCtrlVals = ctrlValidVals.isEmpty ? fallbackCtrlVals : ctrlValidVals
        let ctrlMean = activeCtrlVals.isEmpty ? 1.0 : max(1e-9, QPCRStatistics.mean(activeCtrlVals))
        
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
                foldChange: r.ratio / ctrlMean,
                isSaturated: r.sat,
                clippedPct: r.satPct
            )
        }
        
        let ctrlFolds = laneRows.filter {
            $0.groupName.caseInsensitiveCompare(resolvedCtrl) == .orderedSame && !(policy == .excludeFromStats && $0.isSaturated)
        }.map(\.foldChange)
        
        let groupStats: [BlotGroupStatSummary] = groupsOrder.map { grp in
            let allGroupRows = laneRows.filter { $0.groupName == grp }
            let excludedInGrp = (policy == .excludeFromStats) ? allGroupRows.filter(\.isSaturated).count : 0
            let validRows = (policy == .excludeFromStats) ? allGroupRows.filter { !$0.isSaturated } : allGroupRows
            let folds = validRows.map(\.foldChange)
            let isCtrl = (grp.caseInsensitiveCompare(resolvedCtrl) == .orderedSame)
            let pVal: Double? = (!isCtrl && folds.count >= 2 && ctrlFolds.count >= 2)
                ? QPCRStatistics.welchTTest(folds, ctrlFolds)?.p
                : nil
            return BlotGroupStatSummary(
                groupName: grp,
                n: folds.count,
                nExcludedSaturated: excludedInGrp,
                meanFold: folds.isEmpty ? 0.0 : QPCRStatistics.mean(folds),
                sdFold: QPCRStatistics.sampleSd(folds),
                semFold: QPCRStatistics.sem(folds),
                pValue: pVal,
                isControl: isCtrl,
                values: folds
            )
        }
        
        return BlotQuantificationOut(
            laneRows: laneRows,
            groupStats: groupStats,
            groups: groupsOrder,
            controlGroup: resolvedCtrl,
            globalBackground: 0.0,
            saturationPolicy: policy,
            excludedBands: excludedBands
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
        globalBackground: Double
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
        
        var net = 0.0
        var clipped = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let normGray = Double(plane.gray[y * w + x]) / 255.0
                if normGray <= 0.006 || normGray >= 0.994 {
                    clipped += 1
                }
                let signal = 1.0 - normGray
                let corrected = signal - bg
                if corrected > 0 {
                    net += corrected
                }
            }
        }
        return (net, bg, Double(clipped) / Double(area))
    }
    
    public static func quantifyBlot(
        plane: BioImagePlane,
        lanes: [BlotLaneModel],
        backgroundMode: BlotBackgroundMode,
        manualBackground: Double = 0.08,
        normalizationMode: BlotNormalizationMode = .loadingControl,
        controlGroup: String = "WT"
    ) -> BlotQuantificationOut {
        var allInverted: [Double] = []
        let step = max(1, (plane.width * plane.height) / 2000)
        for idx in stride(from: 0, to: plane.gray.count, by: step) {
            allInverted.append(1.0 - Double(plane.gray[idx]) / 255.0)
        }
        let globalBg = median(allInverted)
        
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
                    globalBackground: globalBg
                )
            } ?? (netVolume: 0.0, background: globalBg, clippedFraction: 0.0)
            
            let lRes = loadingBand.map {
                measureBandROI(
                    plane: plane,
                    lane: lane,
                    band: $0,
                    backgroundMode: backgroundMode,
                    manualBackground: manualBackground,
                    globalBackground: globalBg
                )
            } ?? (netVolume: 1.0, background: globalBg, clippedFraction: 0.0)
            
            let normVal: Double = {
                switch normalizationMode {
                case .loadingControl:
                    return lRes.netVolume > 1e-6 ? (tRes.netVolume / lRes.netVolume) : tRes.netVolume
                case .totalLane:
                    let total = tRes.netVolume + lRes.netVolume
                    return total > 1e-6 ? (tRes.netVolume / total) : 0.0
                case .rawVolume:
                    return tRes.netVolume
                }
            }()
            
            rawMeasures.append(
                RawLaneMeasure(
                    lane: lane,
                    targetVol: tRes.netVolume,
                    loadingVol: lRes.netVolume,
                    targetBg: tRes.background,
                    normVal: normVal,
                    clippedFraction: max(tRes.clippedFraction, lRes.clippedFraction)
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
        let ctrlMean = ctrlVals.isEmpty ? 1.0 : max(1e-9, QPCRStatistics.mean(ctrlVals))
        
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
                foldChange: m.normVal / ctrlMean,
                isSaturated: m.clippedFraction > 0.005,
                clippedPct: m.clippedFraction * 100.0
            )
        }
        
        let ctrlFolds = laneRows
            .filter { $0.groupName.caseInsensitiveCompare(resolvedCtrlGroup) == .orderedSame }
            .map(\.foldChange)
        
        let groupStats: [BlotGroupStatSummary] = groupsOrder.map { grp in
            let rows = laneRows.filter { $0.groupName == grp }
            let folds = rows.map(\.foldChange)
            let isCtrl = (grp.caseInsensitiveCompare(resolvedCtrlGroup) == .orderedSame)
            let pVal: Double? = (!isCtrl && folds.count >= 2 && ctrlFolds.count >= 2)
                ? QPCRStatistics.welchTTest(folds, ctrlFolds)?.p
                : nil
            return BlotGroupStatSummary(
                groupName: grp,
                n: folds.count,
                meanFold: folds.isEmpty ? 0.0 : QPCRStatistics.mean(folds),
                sdFold: QPCRStatistics.sampleSd(folds),
                semFold: QPCRStatistics.sem(folds),
                pValue: pVal,
                isControl: isCtrl,
                values: folds
            )
        }
        
        return BlotQuantificationOut(
            laneRows: laneRows,
            groupStats: groupStats,
            groups: groupsOrder,
            controlGroup: resolvedCtrlGroup,
            globalBackground: globalBg
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

        for baseBand in anchorBands {
            let pts = bandPointsMap[baseBand.id] ?? []
            guard pts.count >= 2 else { continue }
            let regPoints = pts.map { (x: $0.exposureSeconds, y: $0.netIOD) }
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
            reason = "推荐 \(Int(bestSafe.exposureSeconds))s 曝光：所有条带处于线性动态响应区间且未过曝 (信噪比最高)"
        } else {
            recommendedFrame = frameSummaries.first!
            reason = "全部曝光帧均存在过曝条带；自动回退最短曝光 (\(Int(recommendedFrame.exposureSeconds))s) 以减小失真"
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
