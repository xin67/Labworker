import Foundation
import AppKit

// MARK: - 1. 科研多图拼版与荧光通道合成数据模型 (对应 SPICE_GUI `/tools/annotate`)

public enum FigureLabelStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case upperABC = "upperABC"
    case lowerABC = "lowerABC"
    case numeric = "numeric"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .upperABC: return "A / B / C"
        case .lowerABC: return "a / b / c"
        case .numeric:  return "1 / 2 / 3"
        }
    }
    
    public func label(for index: Int) -> String {
        switch self {
        case .upperABC: return PlateFormat.rowLabel(for: index)
        case .lowerABC: return PlateFormat.rowLabel(for: index).lowercased()
        case .numeric:  return "\(index + 1)"
        }
    }
}

public struct FigurePanelChannelConfig: Hashable, Codable, Sendable {
    public var showRed: Bool
    public var showGreen: Bool
    public var showBlue: Bool
    public var redGain: Double
    public var greenGain: Double
    public var blueGain: Double
    public var invert: Bool
    
    public init(
        showRed: Bool = true,
        showGreen: Bool = true,
        showBlue: Bool = true,
        redGain: Double = 1.0,
        greenGain: Double = 1.0,
        blueGain: Double = 1.0,
        invert: Bool = false
    ) {
        self.showRed = showRed
        self.showGreen = showGreen
        self.showBlue = showBlue
        self.redGain = redGain
        self.greenGain = greenGain
        self.blueGain = blueGain
        self.invert = invert
    }
}

public enum FigureScaleBarSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case omeMetadata = "OME 元数据"
    case imageJMetadata = "ImageJ 元数据"
    case tiffResolution = "TIFF 分辨率"
    case manual = "手动"
    
    public var id: String { rawValue }
}

public struct FigurePanelItem: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var rawPlane: BioImagePlane
    public var channels: FigurePanelChannelConfig
    public var showScaleBar: Bool
    public var scaleBarMicrons: Double
    /// 每像素物理尺寸 (µm/px)
    public var pixelSizeMicrons: Double?
    /// 比例尺尺寸来源
    public var scaleBarSource: FigureScaleBarSource
    /// 自动提取的通道列表 (OME-XML 等)
    public var detectedChannelNames: [String]?
    /// 像素强度剖面采样线段 (归一化坐标 0..1)
    public var profileStart: (x: Double, y: Double)
    public var profileEnd: (x: Double, y: Double)
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String = "",
        rawPlane: BioImagePlane,
        channels: FigurePanelChannelConfig = FigurePanelChannelConfig(),
        showScaleBar: Bool = true,
        scaleBarMicrons: Double = 20.0,
        pixelSizeMicrons: Double? = nil,
        scaleBarSource: FigureScaleBarSource? = nil,
        detectedChannelNames: [String]? = nil,
        profileStart: (x: Double, y: Double) = (0.18, 0.50),
        profileEnd: (x: Double, y: Double) = (0.82, 0.50)
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.rawPlane = rawPlane
        self.channels = channels
        self.showScaleBar = showScaleBar
        self.scaleBarMicrons = scaleBarMicrons
        
        let resolvedPx = pixelSizeMicrons ?? rawPlane.effectivePixelSizeUM
        self.pixelSizeMicrons = resolvedPx
        if let explicitSrc = scaleBarSource {
            self.scaleBarSource = explicitSrc
        } else if let pSrc = rawPlane.physicalSizeSource {
            if pSrc == "OME-XML" {
                self.scaleBarSource = .omeMetadata
            } else if pSrc == "ImageJ" {
                self.scaleBarSource = .imageJMetadata
            } else if pSrc == "TIFF-Resolution" {
                self.scaleBarSource = .tiffResolution
            } else {
                self.scaleBarSource = .manual
            }
        } else {
            self.scaleBarSource = .manual
        }
        self.detectedChannelNames = detectedChannelNames ?? rawPlane.channelNames
        self.profileStart = profileStart
        self.profileEnd = profileEnd
    }
}

public struct FigureIntensityProfilePoint: Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let distanceFraction: Double
    public let redIntensity: Double
    public let greenIntensity: Double
    public let blueIntensity: Double
    public let luminance: Double
}

// MARK: - 2. 荧光多通道伪彩合成与线段像素强度剖面采样引擎

public enum FigureAnnotatorEngine {
    
    /// 根据 RGB 通道开关与增益合成单张面板图像
    public static func renderCompositePlane(for panel: FigurePanelItem) -> BioImagePlane {
        let src = panel.rawPlane
        let cfg = panel.channels
        let n = src.width * src.height
        var outRGBA = [UInt8](repeating: 255, count: n * 4)
        var outGray = [Float](repeating: 0, count: n)
        
        for i in 0..<n {
            var r = cfg.showRed ? Double(src.rgba[i * 4]) * cfg.redGain : 0.0
            var g = cfg.showGreen ? Double(src.rgba[i * 4 + 1]) * cfg.greenGain : 0.0
            var b = cfg.showBlue ? Double(src.rgba[i * 4 + 2]) * cfg.blueGain : 0.0
            r = min(255.0, max(0.0, r))
            g = min(255.0, max(0.0, g))
            b = min(255.0, max(0.0, b))
            if cfg.invert {
                r = 255.0 - r
                g = 255.0 - g
                b = 255.0 - b
            }
            let ru = UInt8(round(r))
            let gu = UInt8(round(g))
            let bu = UInt8(round(b))
            outRGBA[i * 4] = ru
            outRGBA[i * 4 + 1] = gu
            outRGBA[i * 4 + 2] = bu
            outRGBA[i * 4 + 3] = 255
            outGray[i] = Float(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        return BioImagePlane(width: src.width, height: src.height, gray: outGray, rgba: outRGBA)
    }
    
    /// 沿面板内指定线段均匀采样 RGB 与亮度剖面曲线 (Line Intensity Profile)
    public static func sampleLineProfile(
        for panel: FigurePanelItem,
        sampleCount: Int = 96
    ) -> [FigureIntensityProfilePoint] {
        let comp = renderCompositePlane(for: panel)
        let w = comp.width
        let h = comp.height
        let count = max(16, min(512, sampleCount))
        var pts: [FigureIntensityProfilePoint] = []
        pts.reserveCapacity(count)
        
        let x1 = panel.profileStart.x * Double(w - 1)
        let y1 = panel.profileStart.y * Double(h - 1)
        let x2 = panel.profileEnd.x * Double(w - 1)
        let y2 = panel.profileEnd.y * Double(h - 1)
        
        for idx in 0..<count {
            let t = Double(idx) / Double(max(1, count - 1))
            let px = min(w - 1, max(0, Int(round(x1 + (x2 - x1) * t))))
            let py = min(h - 1, max(0, Int(round(y1 + (y2 - y1) * t))))
            let offset = (py * w + px) * 4
            let r = Double(comp.rgba[offset])
            let g = Double(comp.rgba[offset + 1])
            let b = Double(comp.rgba[offset + 2])
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            pts.append(
                FigureIntensityProfilePoint(
                    index: idx,
                    distanceFraction: t,
                    redIntensity: r,
                    greenIntensity: g,
                    blueIntensity: b,
                    luminance: lum
                )
            )
        }
        return pts
    }
    
    /// 生成共聚焦荧光显微镜 4 通道示范面板组 (DAPI / EGFP-TP53 / MitoTracker-Red / Merged)
    public static func generateDemoFluorescencePanels(width: Int = 260, height: Int = 220) -> [FigurePanelItem] {
        var baseRGBA = [UInt8](repeating: 0, count: width * height * 4)
        var baseGray = [Float](repeating: 0, count: width * height)
        
        let cells: [(cx: Double, cy: Double, nucR: Double, cellR: Double)] = [
            (0.32, 0.44, 0.11, 0.23),
            (0.68, 0.56, 0.12, 0.25)
        ]
        
        for y in 0..<height {
            let yn = Double(y) / Double(height)
            for x in 0..<width {
                let xn = Double(x) / Double(width)
                var rVal = 6.0
                var gVal = 8.0
                var bVal = 12.0
                
                for cell in cells {
                    let d = hypot(xn - cell.cx, yn - cell.cy)
                    // 细胞核 DAPI (Blue)
                    if d <= cell.nucR {
                        let nucProfile = cos((d / cell.nucR) * (Double.pi / 2.0))
                        bVal += 225.0 * nucProfile
                    }
                    // 线粒体环状网络 EGFP-TP53 (Green) & MitoTracker (Red) 共定位
                    if d >= cell.nucR * 0.75 && d <= cell.cellR {
                        let ring = sin(((d - cell.nucR * 0.75) / (cell.cellR - cell.nucR * 0.75)) * Double.pi)
                        let texture = 0.65 + 0.35 * cos(xn * 42.0) * sin(yn * 38.0)
                        gVal += 215.0 * ring * texture
                        rVal += 205.0 * ring * texture
                    }
                }
                
                let idx = y * width + x
                let ru = UInt8(min(255, max(0, Int(round(rVal)))))
                let gu = UInt8(min(255, max(0, Int(round(gVal)))))
                let bu = UInt8(min(255, max(0, Int(round(bVal)))))
                baseRGBA[idx * 4] = ru
                baseRGBA[idx * 4 + 1] = gu
                baseRGBA[idx * 4 + 2] = bu
                baseRGBA[idx * 4 + 3] = 255
                baseGray[idx] = Float(0.2126 * Double(ru) + 0.7152 * Double(gu) + 0.0722 * Double(bu))
            }
        }
        
        let masterPlane = BioImagePlane(width: width, height: height, gray: baseGray, rgba: baseRGBA)
        return [
            FigurePanelItem(
                title: "DAPI (Nuclei)",
                subtitle: "405 nm Excitation",
                rawPlane: masterPlane,
                channels: FigurePanelChannelConfig(showRed: false, showGreen: false, showBlue: true)
            ),
            FigurePanelItem(
                title: "TP53-EGFP",
                subtitle: "488 nm Excitation",
                rawPlane: masterPlane,
                channels: FigurePanelChannelConfig(showRed: false, showGreen: true, showBlue: false)
            ),
            FigurePanelItem(
                title: "MitoTracker Red",
                subtitle: "561 nm Excitation",
                rawPlane: masterPlane,
                channels: FigurePanelChannelConfig(showRed: true, showGreen: false, showBlue: false)
            ),
            FigurePanelItem(
                title: "Merge + Line Profile",
                subtitle: "Colocalization Overlay",
                rawPlane: masterPlane,
                channels: FigurePanelChannelConfig(showRed: true, showGreen: true, showBlue: true)
            )
        ]
    }
    
    public static func exportProfileCSV(points: [FigureIntensityProfilePoint], panelTitle: String) -> String {
        var lines = ["Panel,Index,Distance_Fraction,Red_0_255,Green_0_255,Blue_0_255,Luminance"]
        for pt in points {
            lines.append(
                "\(panelTitle),\(pt.index),\(String(format: "%.4f", pt.distanceFraction)),\(String(format: "%.1f", pt.redIntensity)),\(String(format: "%.1f", pt.greenIntensity)),\(String(format: "%.1f", pt.blueIntensity)),\(String(format: "%.1f", pt.luminance))"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// 根据通道名称推测最佳的荧光伪彩通道开关 (P13)
    public static func autoMapChannelConfig(from channelNames: [String]?) -> FigurePanelChannelConfig? {
        guard let list = channelNames, !list.isEmpty else { return nil }
        var showR = false
        var showG = false
        var showB = false
        for name in list {
            let l = name.lowercased()
            if l.contains("dapi") || l.contains("hoechst") || l.contains("405") || l.contains("blue") {
                showB = true
            }
            if l.contains("gfp") || l.contains("egfp") || l.contains("fitc") || l.contains("488") || l.contains("green") || l.contains("alexa 488") {
                showG = true
            }
            if l.contains("rfp") || l.contains("mcherry") || l.contains("tritc") || l.contains("cy3") || l.contains("mitotracker") || l.contains("561") || l.contains("594") || l.contains("red") {
                showR = true
            }
        }
        if !showR && !showG && !showB {
            return nil
        }
        return FigurePanelChannelConfig(showRed: showR, showGreen: showG, showBlue: showB)
    }

    /// 根据物理像素尺寸 (µm/px) 与当前面板显示尺寸计算比例尺的精确宽度占比 (P13)
    public static func computeScaleBarWidthFraction(for panel: FigurePanelItem) -> Double {
        let pxUM = panel.pixelSizeMicrons ?? panel.rawPlane.effectivePixelSizeUM
        let planeW = Double(max(8, panel.rawPlane.width))
        if let umPerPx = pxUM, umPerPx > 0 {
            let barPx = panel.scaleBarMicrons / umPerPx
            let frac = barPx / planeW
            // 钳制在 2% 到 95% 之间
            return min(0.95, max(0.02, frac))
        }
        // 未提供物理像素尺寸时，回退到默认宽度比例 22%
        return 0.22
    }

    /// 构造科研拼版与共定位分析的 AnalysisRun 机器可读溯源记录 (P13)
    public static func buildFigureAnnotatorAnalysisRun(
        panels: [FigurePanelItem],
        selectedPanel: FigurePanelItem,
        points: [FigureIntensityProfilePoint],
        manualEdits: [AnalysisRun.ManualEdit] = [],
        outputs: [String] = [],
        exportDirectoryURL: URL? = nil
    ) -> AnalysisRun {
        var paramsDict: [String: AnyCodableValue] = [
            "panelCount": .int(panels.count),
            "selectedPanelTitle": .string(selectedPanel.title),
            "selectedPanelScaleBarMicrons": .double(selectedPanel.scaleBarMicrons),
            "selectedPanelScaleBarSource": .string(selectedPanel.scaleBarSource.rawValue),
            "selectedPanelShowScaleBar": .bool(selectedPanel.showScaleBar)
        ]
        if let px = selectedPanel.pixelSizeMicrons {
            paramsDict["selectedPanelPixelSizeUM"] = .double(px)
        }
        if let chs = selectedPanel.detectedChannelNames {
            paramsDict["selectedPanelChannels"] = .array(chs.map { .string($0) })
        }

        var inputs: [AnalysisRun.InputFile] = []
        for p in panels {
            let descBytes = Data((p.title + ":" + p.subtitle).utf8)
            inputs.append(
                AnalysisRun.InputFile(
                    path: "\(p.title).panel",
                    sha256: AnalysisRun.sha256Hex(ofData: descBytes),
                    byteSize: Int64(p.rawPlane.width * p.rawPlane.height * 4)
                )
            )
        }

        return AnalysisRun(
            schemaVersion: 1,
            module: NavItem.figureAnnotator.rawValue,
            engine: "swift-native",
            inputs: inputs,
            parameters: paramsDict,
            manualEdits: manualEdits,
            exclusions: [],
            outputs: outputs
        )
    }

    /// 导出共定位像素强度剖面 CSV 并同步写入 <basename>.run.json 溯源记录伴随文件 (P13)
    @discardableResult
    public static func exportProfileCSVWithProvenance(
        points: [FigureIntensityProfilePoint],
        panels: [FigurePanelItem],
        selectedPanel: FigurePanelItem,
        manualEdits: [AnalysisRun.ManualEdit] = [],
        to outputCSVURL: URL
    ) throws -> (csvURL: URL, sidecarURL: URL, run: AnalysisRun) {
        let csvText = exportProfileCSV(points: points, panelTitle: selectedPanel.title)
        try csvText.write(to: outputCSVURL, atomically: true, encoding: .utf8)

        let run = buildFigureAnnotatorAnalysisRun(
            panels: panels,
            selectedPanel: selectedPanel,
            points: points,
            manualEdits: manualEdits,
            outputs: [outputCSVURL.lastPathComponent],
            exportDirectoryURL: outputCSVURL.deletingLastPathComponent()
        )
        let sidecarURL = try run.writeSidecarJSON(alongsideOutputURL: outputCSVURL)
        return (outputCSVURL, sidecarURL, run)
    }
}
