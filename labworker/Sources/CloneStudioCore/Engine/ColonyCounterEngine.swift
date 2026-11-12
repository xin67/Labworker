import Foundation

// MARK: - 1. 菌落计数器数据模型 (Colony Counter Models)

public enum ColonyPolarityMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "auto"
    case dark = "dark"
    case bright = "bright"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .auto:   return "自动极性"
        case .dark:   return "深色菌落"
        case .bright: return "浅色菌落"
        }
    }
}

public enum ColonyColorClass: String, CaseIterable, Identifiable, Codable, Sendable {
    case blue = "blue"
    case white = "white"
    case unclassified = "unclassified"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .blue:         return "蓝斑 (LacZ+)"
        case .white:        return "白斑 (阳性克隆)"
        case .unclassified: return "常规菌落"
        }
    }
}

public struct ColonyMarkerItem: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var x: Double
    public var y: Double
    public var area: Double
    public var radius: Double
    public var meanIntensity: Double
    public var circularity: Double
    public var included: Bool
    public var isManual: Bool
    public var colonyClass: ColonyColorClass
    public var hueDegrees: Double
    public var saturation: Double
    
    public init(
        id: Int,
        x: Double,
        y: Double,
        area: Double,
        radius: Double,
        meanIntensity: Double = 128.0,
        circularity: Double = 0.85,
        included: Bool = true,
        isManual: Bool = false,
        colonyClass: ColonyColorClass = .unclassified,
        hueDegrees: Double = 0.0,
        saturation: Double = 0.0
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.area = area
        self.radius = radius
        self.meanIntensity = meanIntensity
        self.circularity = circularity
        self.included = included
        self.isManual = isManual
        self.colonyClass = colonyClass
        self.hueDegrees = hueDegrees
        self.saturation = saturation
    }
}

public struct ColonySegmentationParams: Hashable, Codable, Sendable {
    public var manualThreshold: Double?
    public var polarity: ColonyPolarityMode
    public var blurRadius: Double
    public var minArea: Int
    public var maxArea: Int
    public var minCircularity: Double
    public var classifyBlueWhite: Bool
    public var dilutionFactor: Double
    public var platedVolumeMl: Double
    
    public init(
        manualThreshold: Double? = nil,
        polarity: ColonyPolarityMode = .auto,
        blurRadius: Double = 1.2,
        minArea: Int = 12,
        maxArea: Int = 2500,
        minCircularity: Double = 0.35,
        classifyBlueWhite: Bool = true,
        dilutionFactor: Double = 1000.0,
        platedVolumeMl: Double = 0.1
    ) {
        self.manualThreshold = manualThreshold
        self.polarity = polarity
        self.blurRadius = blurRadius
        self.minArea = minArea
        self.maxArea = maxArea
        self.minCircularity = minCircularity
        self.classifyBlueWhite = classifyBlueWhite
        self.dilutionFactor = dilutionFactor
        self.platedVolumeMl = platedVolumeMl
    }
}

public struct ColonyStatisticsSummary: Sendable {
    public let totalDetected: Int
    public let includedCount: Int
    public let excludedCount: Int
    public let manualCount: Int
    public let blueCount: Int
    public let whiteCount: Int
    public let unclassifiedCount: Int
    public let whitePositiveRatePct: Double
    public let meanArea: Double
    public let medianArea: Double
    public let meanCircularity: Double
    public let otsuThreshold: Double
    public let appliedThreshold: Double
    public let poissonLow: Double
    public let poissonHigh: Double
    public let cfuPerMl: Double?
    public let cfuLow: Double?
    public let cfuHigh: Double?
}

// MARK: - 2. 菌落自动分割、蓝白斑色相判别与 Garwood 精确泊松区间引擎

public enum ColonyCounterEngine {
    
    /// 执行菌落分割与蓝白斑分类 (对应 SPICE_GUI `/tools/colony`)
    public static func segmentPlate(
        plane: BioImagePlane,
        params: ColonySegmentationParams
    ) -> (markers: [ColonyMarkerItem], otsu: Double, appliedThreshold: Double) {
        let blurred = BioImageProcessor.gaussianBlur(
            gray: plane.gray,
            width: plane.width,
            height: plane.height,
            radius: params.blurRadius
        )
        // 仅在培养皿内圈统计 Otsu 阈值以避免深色皿外背景干扰
        let cx = Double(plane.width) / 2.0
        let cy = Double(plane.height) / 2.0
        let dishR = Double(min(plane.width, plane.height)) * 0.43
        var dishPixels: [Float] = []
        dishPixels.reserveCapacity(plane.width * plane.height)
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                if hypot(Double(x) - cx, Double(y) - cy) <= dishR {
                    dishPixels.append(blurred[y * plane.width + x])
                }
            }
        }
        let otsu = BioImageProcessor.otsuThreshold(gray: dishPixels.isEmpty ? blurred : dishPixels)
        let threshold = params.manualThreshold.map { min(255.0, max(0.0, $0)) } ?? otsu
        let bgMed = dishPixels.isEmpty
            ? BioImageProcessor.estimateBorderBackground(gray: blurred, width: plane.width, height: plane.height)
            : Double(dishPixels.sorted()[dishPixels.count / 2])
        
        let isDarkColony: Bool = {
            switch params.polarity {
            case .dark:   return true
            case .bright: return false
            case .auto:   return bgMed >= threshold
            }
        }()
        
        var mask = [UInt8](repeating: 0, count: plane.width * plane.height)
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                let d = hypot(Double(x) - cx, Double(y) - cy)
                guard d <= dishR else { continue }
                let idx = y * plane.width + x
                let v = Double(blurred[idx])
                if isDarkColony {
                    mask[idx] = v <= threshold ? 1 : 0
                } else {
                    mask[idx] = v >= threshold ? 1 : 0
                }
            }
        }
        
        let components = BioImageProcessor.extractConnectedComponents(mask: mask, plane: plane)
        var markers: [ColonyMarkerItem] = []
        var nextID = 1
        
        for comp in components {
            if comp.area < max(1, params.minArea) { continue }
            if params.maxArea > 0 && comp.area > params.maxArea { continue }
            if comp.circularity < params.minCircularity { continue }
            
            let colorClass: ColonyColorClass = {
                guard params.classifyBlueWhite else { return .unclassified }
                // X-gal 蓝斑典型色相在 175°..260° 且具有一定饱和度；白斑饱和度较低或偏暖米色
                if comp.saturation >= 0.22 && comp.hueDegrees >= 170.0 && comp.hueDegrees <= 265.0 {
                    return .blue
                }
                return .white
            }()
            
            markers.append(
                ColonyMarkerItem(
                    id: nextID,
                    x: comp.centroidX,
                    y: comp.centroidY,
                    area: Double(comp.area),
                    radius: max(3.5, comp.radius),
                    meanIntensity: comp.meanIntensity,
                    circularity: comp.circularity,
                    included: true,
                    isManual: false,
                    colonyClass: colorClass,
                    hueDegrees: comp.hueDegrees,
                    saturation: comp.saturation
                )
            )
            nextID += 1
        }
        return (markers, otsu, threshold)
    }
    
    // MARK: - Garwood 精确泊松 95% 置信区间与 CFU/mL 计算
    
    private static func regularizedGammaP(a: Double, x: Double) -> Double {
        if x <= 0.0 { return 0.0 }
        if x < a + 1.0 {
            var ap = a
            var sum = 1.0 / a
            var del = sum
            for _ in 1..<200 {
                ap += 1.0
                del *= x / ap
                sum += del
                if abs(del) < abs(sum) * 1e-12 { break }
            }
            return sum * exp(-x + a * log(x) - QPCRStatistics.logGamma(a))
        } else {
            let tiny = 1e-300
            var b = x + 1.0 - a
            var c = 1.0 / tiny
            var d = 1.0 / b
            var h = d
            for i in 1..<200 {
                let iD = Double(i)
                let an = -iD * (iD - a)
                b += 2.0
                d = an * d + b
                if abs(d) < tiny { d = tiny }
                c = b + an / c
                if abs(c) < tiny { c = tiny }
                d = 1.0 / d
                let del = d * c
                h *= del
                if abs(del - 1.0) < 1e-12 { break }
            }
            return 1.0 - exp(-x + a * log(x) - QPCRStatistics.logGamma(a)) * h
        }
    }
    
    private static func chiSquareQuantile(p: Double, df: Double) -> Double {
        guard df > 0 else { return 0.0 }
        var low = 0.0
        var high = max(1.0, df + 10.0 * sqrt(2.0 * df) + 20.0)
        while regularizedGammaP(a: df / 2.0, x: high / 2.0) < p {
            high *= 2.0
        }
        for _ in 0..<70 {
            let mid = 0.5 * (low + high)
            if regularizedGammaP(a: df / 2.0, x: mid / 2.0) < p {
                low = mid
            } else {
                high = mid
            }
        }
        return 0.5 * (low + high)
    }
    
    public static func poissonCI95(count: Int) -> (low: Double, high: Double) {
        let k = max(0, count)
        let low = k == 0 ? 0.0 : 0.5 * chiSquareQuantile(p: 0.025, df: Double(2 * k))
        let high = 0.5 * chiSquareQuantile(p: 0.975, df: Double(2 * k + 2))
        return (low, high)
    }
    
    public static func summarize(
        markers: [ColonyMarkerItem],
        otsu: Double,
        appliedThreshold: Double,
        params: ColonySegmentationParams
    ) -> ColonyStatisticsSummary {
        let included = markers.filter(\.included)
        let areas = included.map(\.area).sorted()
        let meanArea = areas.isEmpty ? 0.0 : (areas.reduce(0, +) / Double(areas.count))
        let medianArea: Double = {
            guard !areas.isEmpty else { return 0.0 }
            let mid = areas.count / 2
            return areas.count % 2 == 1 ? areas[mid] : 0.5 * (areas[mid - 1] + areas[mid])
        }()
        let meanCirc = included.isEmpty ? 0.0 : (included.map(\.circularity).reduce(0, +) / Double(included.count))
        
        let blueCount = included.filter { $0.colonyClass == .blue }.count
        let whiteCount = included.filter { $0.colonyClass == .white }.count
        let unclassCount = included.filter { $0.colonyClass == .unclassified }.count
        let bwTotal = blueCount + whiteCount
        let whiteRate = bwTotal > 0 ? (Double(whiteCount) / Double(bwTotal) * 100.0) : 0.0
        
        let ci = poissonCI95(count: included.count)
        let validDilution = params.dilutionFactor > 0 && params.platedVolumeMl > 0
        let factor = validDilution ? (params.dilutionFactor / params.platedVolumeMl) : 0.0
        
        return ColonyStatisticsSummary(
            totalDetected: markers.count,
            includedCount: included.count,
            excludedCount: markers.count - included.count,
            manualCount: markers.filter(\.isManual).count,
            blueCount: blueCount,
            whiteCount: whiteCount,
            unclassifiedCount: unclassCount,
            whitePositiveRatePct: whiteRate,
            meanArea: meanArea,
            medianArea: medianArea,
            meanCircularity: meanCirc,
            otsuThreshold: otsu,
            appliedThreshold: appliedThreshold,
            poissonLow: ci.low,
            poissonHigh: ci.high,
            cfuPerMl: validDilution ? Double(included.count) * factor : nil,
            cfuLow: validDilution ? ci.low * factor : nil,
            cfuHigh: validDilution ? ci.high * factor : nil
        )
    }
    
    public static func exportMarkersCSV(markers: [ColonyMarkerItem]) -> String {
        var lines = ["id,x,y,area_px2,radius_px,mean_intensity,circularity,included,is_manual,colony_class,hue_deg,saturation"]
        for m in markers {
            lines.append(
                "\(m.id),\(String(format: "%.2f", m.x)),\(String(format: "%.2f", m.y)),\(String(format: "%.1f", m.area)),\(String(format: "%.2f", m.radius)),\(String(format: "%.1f", m.meanIntensity)),\(String(format: "%.3f", m.circularity)),\(m.included ? 1 : 0),\(m.isManual ? 1 : 0),\(m.colonyClass.rawValue),\(String(format: "%.1f", m.hueDegrees)),\(String(format: "%.3f", m.saturation))"
            )
        }
        return lines.joined(separator: "\n")
    }
}
