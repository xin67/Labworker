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
    public var splitTouchingColonies: Bool
    public var dilutionFactor: Double
    public var platedVolumeMl: Double

    enum CodingKeys: String, CodingKey {
        case manualThreshold, polarity, blurRadius, minArea, maxArea, minCircularity
        case classifyBlueWhite, splitTouchingColonies, dilutionFactor, platedVolumeMl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.manualThreshold = try c.decodeIfPresent(Double.self, forKey: .manualThreshold)
        self.polarity = try c.decodeIfPresent(ColonyPolarityMode.self, forKey: .polarity) ?? .auto
        self.blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 1.2
        self.minArea = try c.decodeIfPresent(Int.self, forKey: .minArea) ?? 4
        self.maxArea = try c.decodeIfPresent(Int.self, forKey: .maxArea) ?? 6000
        self.minCircularity = try c.decodeIfPresent(Double.self, forKey: .minCircularity) ?? 0.35
        self.classifyBlueWhite = try c.decodeIfPresent(Bool.self, forKey: .classifyBlueWhite) ?? true
        self.splitTouchingColonies = try c.decodeIfPresent(Bool.self, forKey: .splitTouchingColonies) ?? true
        self.dilutionFactor = try c.decodeIfPresent(Double.self, forKey: .dilutionFactor) ?? 1000.0
        self.platedVolumeMl = try c.decodeIfPresent(Double.self, forKey: .platedVolumeMl) ?? 0.1
    }

    public init(
        manualThreshold: Double? = nil,
        polarity: ColonyPolarityMode = .auto,
        blurRadius: Double = 1.2,
        minArea: Int = 4,
        maxArea: Int = 6000,
        minCircularity: Double = 0.35,
        classifyBlueWhite: Bool = true,
        splitTouchingColonies: Bool = true,
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
        self.splitTouchingColonies = splitTouchingColonies
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
    
    /// 执行菌落分割、照明平坦化增强、分水岭粘连拆分与蓝白斑分类
    public static func segmentPlate(
        plane: BioImagePlane,
        params: ColonySegmentationParams
    ) -> (markers: [ColonyMarkerItem], otsu: Double, appliedThreshold: Double) {
        let w = plane.width
        let h = plane.height
        guard w > 0, h > 0, plane.gray.count == w * h else {
            return ([], 128.0, 128.0)
        }

        // 1. 自适应识别培养皿有效检测区域 (ROI)：兼容有深/浅边框圆皿与紧密裁剪琼脂块
        let roiMask = buildDishROI(gray: plane.gray, width: w, height: h)

        // 2. 保边轻度去噪，避免固定大核模糊吞噬微小菌落或粘连窄缝
        let detectGray: [Float]
        if params.blurRadius <= 0.05 {
            detectGray = plane.gray
        } else if params.blurRadius <= 1.35 {
            detectGray = lightDenoise3x3(gray: plane.gray, width: w, height: h)
        } else {
            detectGray = BioImageProcessor.gaussianBlur(
                gray: plane.gray,
                width: w,
                height: h,
                radius: params.blurRadius
            )
        }

        var roiPixels: [Float] = []
        roiPixels.reserveCapacity(w * h)
        for i in 0..<(w * h) where roiMask[i] {
            roiPixels.append(detectGray[i])
        }
        let activePixels = roiPixels.isEmpty ? detectGray : roiPixels
        let otsu = BioImageProcessor.otsuThreshold(gray: activePixels)
        let sortedROI = activePixels.sorted()
        let bgMed = Double(sortedROI[sortedROI.count / 2])

        let isDarkColony: Bool = {
            switch params.polarity {
            case .dark: return true
            case .bright: return false
            case .auto: return bgMed >= otsu
            }
        }()

        var mask = [UInt8](repeating: 0, count: w * h)
        let appliedThreshold: Double

        if let manualT = params.manualThreshold {
            let threshold = min(255.0, max(0.0, manualT))
            appliedThreshold = threshold
            for i in 0..<(w * h) where roiMask[i] {
                let v = Double(detectGray[i])
                mask[i] = isDarkColony ? (v <= threshold ? 1 : 0) : (v >= threshold ? 1 : 0)
            }
        } else {
            // 3. 局部照明平坦化背景表面估计 + 双阈值滞后促进微弱小菌落
            let bgField = estimateAgarBackgroundField(
                gray: detectGray,
                roiMask: roiMask,
                width: w,
                height: h,
                isDarkColony: isDarkColony,
                fallbackMedian: bgMed
            )

            var signedROI: [Double] = []
            signedROI.reserveCapacity(activePixels.count)
            var contrast = [Float](repeating: 0, count: w * h)
            var roiContrast: [Float] = []
            roiContrast.reserveCapacity(activePixels.count)
            for i in 0..<(w * h) where roiMask[i] {
                let signedC = isDarkColony ? (bgField[i] - Double(detectGray[i])) : (Double(detectGray[i]) - bgField[i])
                signedROI.append(signedC)
                let clamped = Float(max(0.0, signedC))
                contrast[i] = clamped
                roiContrast.append(clamped)
            }

            let contrastOtsu = BioImageProcessor.otsuThreshold(gray: roiContrast.isEmpty ? contrast : roiContrast)
            let roughCut = max(12.0, contrastOtsu * 0.50)
            let bgSamples = signedROI.filter { $0 < roughCut && $0 > -roughCut * 2.0 }.sorted()
            let bgNoiseStats: (med: Double, sigma: Double) = {
                guard !bgSamples.isEmpty else { return (0.0, 0.0) }
                let med = bgSamples[bgSamples.count / 2]
                let devs = bgSamples.map { abs($0 - med) }.sorted()
                let mad = devs[devs.count / 2]
                return (med, 1.4826 * mad)
            }()

            let baseOffset = max(0.0, bgNoiseStats.med)
            let noiseFloor = baseOffset + max(14.0, 5.5 * bgNoiseStats.sigma)
            let tLow = baseOffset + max(13.0, 5.0 * bgNoiseStats.sigma)
            let tHigh = max(noiseFloor, contrastOtsu * 0.76)

            appliedThreshold = isDarkColony
                ? max(0.0, min(255.0, bgMed - tHigh))
                : max(0.0, min(255.0, bgMed + tHigh))

            var highMask = [UInt8](repeating: 0, count: w * h)
            var lowMask = [UInt8](repeating: 0, count: w * h)
            for i in 0..<(w * h) where roiMask[i] {
                let c = Double(contrast[i])
                if c >= tHigh {
                    highMask[i] = 1
                    mask[i] = 1
                } else if c >= tLow {
                    lowMask[i] = 1
                }
            }

            // 统一滞后扩展微弱小菌落与仅 1..22 px 尖端过 threshold 的超小菌落核 (FWHM)，同时严格隔离大菌落外晕
            promoteSmallAndFaintColonies(
                into: &mask,
                highMask: highMask,
                lowMask: lowMask,
                contrast: contrast,
                width: w,
                height: h,
                tLow: tLow,
                contrastOtsu: contrastOtsu,
                minArea: max(1, params.minArea)
            )
        }

        let components = BioImageProcessor.extractSplitColonyComponents(
            mask: mask,
            plane: plane,
            splitTouching: params.splitTouchingColonies,
            colorAwareSplitting: params.classifyBlueWhite
        )
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
                    radius: max(2.0, comp.radius),
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
        return (markers, otsu, appliedThreshold)
    }

    // MARK: - 分割前置辅助管线 (ROI 检测 / 3x3 轻柔去噪 / 局部琼脂照明估计 / 微小菌落滞后提升)

    private static func buildDishROI(gray: [Float], width: Int, height: Int) -> [Bool] {
        let minDim = min(width, height)
        let borderMed = BioImageProcessor.estimateBorderBackground(gray: gray, width: width, height: height)
        let cxDefault = Double(width) / 2.0
        let cyDefault = Double(height) / 2.0
        let coreR = Double(minDim) * 0.30

        var coreSamples: [Float] = []
        coreSamples.reserveCapacity(width * height / 3)
        for y in 0..<height {
            for x in 0..<width where hypot(Double(x) - cxDefault, Double(y) - cyDefault) <= coreR {
                coreSamples.append(gray[y * width + x])
            }
        }
        let sortedCore = coreSamples.sorted()
        let centerMed = sortedCore.isEmpty ? borderMed : Double(sortedCore[sortedCore.count / 2])

        var roi = [Bool](repeating: false, count: width * height)
        if abs(borderMed - centerMed) >= 22.0 {
            // 有明显皿外桌台/深色背景框：自动对齐培养皿质心并向内收缩皿壁厚度
            let midThresh = abs(centerMed - borderMed) * 0.45
            var sumX = 0.0, sumY = 0.0, count = 0.0
            var minX = width, maxX = 0, minY = height, maxY = 0
            for y in 0..<height {
                for x in 0..<width {
                    let v = Double(gray[y * width + x])
                    if abs(v - borderMed) > midThresh {
                        sumX += Double(x)
                        sumY += Double(y)
                        count += 1.0
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
            }
            let estCX = count > 20 ? (sumX / count + 0.5) : cxDefault
            let estCY = count > 20 ? (sumY / count + 0.5) : cyDefault
            let bboxR = 0.5 * Double(min(maxX - minX + 1, maxY - minY + 1))
            let areaR = sqrt(count / Double.pi)
            let estR = min(bboxR, areaR * 1.04)
            let fallbackR = Double(minDim) * 0.432
            let dishR: Double = (estR >= Double(minDim) * 0.25 && estR <= Double(max(width, height)) * 0.55)
                ? max(8.0, estR - max(4.5, estR * 0.038))
                : fallbackR

            let finalCX = (estR >= Double(minDim) * 0.25 && estR <= Double(max(width, height)) * 0.55) ? estCX : cxDefault
            let finalCY = (estR >= Double(minDim) * 0.25 && estR <= Double(max(width, height)) * 0.55) ? estCY : cyDefault

            for y in 0..<height {
                for x in 0..<width {
                    if hypot(Double(x) - finalCX, Double(y) - finalCY) <= dishR {
                        roi[y * width + x] = true
                    }
                }
            }
        } else {
            // 紧密裁剪的琼脂图像：保留全部内区，仅避开 2px 最外像素边界
            let margin = min(2, minDim / 10)
            for y in margin..<(height - margin) {
                for x in margin..<(width - margin) {
                    roi[y * width + x] = true
                }
            }
        }
        return roi
    }

    private static func lightDenoise3x3(gray: [Float], width: Int, height: Int) -> [Float] {
        guard width > 2, height > 2 else { return gray }
        var tmp = [Float](repeating: 0, count: width * height)
        var out = [Float](repeating: 0, count: width * height)
        let wEdge: Float = 0.12
        let wCenter: Float = 0.76
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let xl = max(0, x - 1)
                let xr = min(width - 1, x + 1)
                tmp[row + x] = wEdge * gray[row + xl] + wCenter * gray[row + x] + wEdge * gray[row + xr]
            }
        }
        for y in 0..<height {
            let yu = max(0, y - 1) * width
            let yd = min(height - 1, y + 1) * width
            let ym = y * width
            for x in 0..<width {
                out[ym + x] = wEdge * tmp[yu + x] + wCenter * tmp[ym + x] + wEdge * tmp[yd + x]
            }
        }
        return out
    }

    private static func estimateAgarBackgroundField(
        gray: [Float],
        roiMask: [Bool],
        width: Int,
        height: Int,
        isDarkColony: Bool,
        fallbackMedian: Double
    ) -> [Double] {
        let blockSize = max(12, min(width, height) / 14)
        let gw = max(1, (width + blockSize - 1) / blockSize)
        let gh = max(1, (height + blockSize - 1) / blockSize)
        var grid = [Double](repeating: fallbackMedian, count: gw * gh)
        var valid = [Bool](repeating: false, count: gw * gh)
        var roiVals: [Double] = []
        roiVals.reserveCapacity(width * height / 2)

        for gy in 0..<gh {
            let y0 = gy * blockSize
            let y1 = min(height, y0 + blockSize)
            for gx in 0..<gw {
                let x0 = gx * blockSize
                let x1 = min(width, x0 + blockSize)
                var vals: [Double] = []
                vals.reserveCapacity(blockSize * blockSize)
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let idx = y * width + x
                        if roiMask[idx] {
                            let v = Double(gray[idx])
                            vals.append(v)
                            roiVals.append(v)
                        }
                    }
                }
                if vals.count >= 6 {
                    vals.sort()
                    let qIdx = isDarkColony ? min(vals.count - 1, Int(Double(vals.count - 1) * 0.78))
                                            : max(0, Int(Double(vals.count - 1) * 0.22))
                    grid[gy * gw + gx] = vals[qIdx]
                    valid[gy * gw + gx] = true
                }
            }
        }

        // 仅依据局部 3×3 邻域中位判定极端浓菌落遮盖块，绝不用单一全局值否定渐暗照明区；并在外推边界保留线性光照斜率
        let originalGrid = grid
        let originalValid = valid
        for gy in 0..<gh {
            for gx in 0..<gw {
                let gi = gy * gw + gx
                guard originalValid[gi] else { continue }
                var neigh: [Double] = []
                for dy in -1...1 {
                    let ny = gy + dy
                    if ny < 0 || ny >= gh { continue }
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = gx + dx
                        if nx < 0 || nx >= gw { continue }
                        let ni = ny * gw + nx
                        if originalValid[ni] { neigh.append(originalGrid[ni]) }
                    }
                }
                if neigh.count >= 3 {
                    neigh.sort()
                    let nMed = neigh[neigh.count / 2]
                    if (isDarkColony && originalGrid[gi] < nMed - 32.0) || (!isDarkColony && originalGrid[gi] > nMed + 32.0) {
                        valid[gi] = false
                    }
                }
            }
        }

        // 多轮邻域外推填补空网格（当有同轴向两格时优先按线性斜率外推，消除倾斜光照边缘阶跃）
        var filled = grid
        for _ in 0..<max(gw, gh) {
            var changed = false
            var next = filled
            for gy in 0..<gh {
                for gx in 0..<gw {
                    let gi = gy * gw + gx
                    if valid[gi] { continue }
                    var estimates: [Double] = []
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)] {
                        let nx1 = gx + dx, ny1 = gy + dy
                        if nx1 < 0 || nx1 >= gw || ny1 < 0 || ny1 >= gh { continue }
                        let ni1 = ny1 * gw + nx1
                        guard valid[ni1] else { continue }
                        let nx2 = gx + 2 * dx, ny2 = gy + 2 * dy
                        if nx2 >= 0 && nx2 < gw && ny2 >= 0 && ny2 < gh && valid[ny2 * gw + nx2] {
                            let extrap = 2.0 * filled[ni1] - filled[ny2 * gw + nx2]
                            estimates.append(min(255.0, max(0.0, extrap)))
                        } else {
                            estimates.append(filled[ni1])
                        }
                    }
                    if !estimates.isEmpty {
                        next[gi] = estimates.reduce(0, +) / Double(estimates.count)
                        valid[gi] = true
                        changed = true
                    }
                }
            }
            filled = next
            if !changed { break }
        }

        var smoothed = filled
        for gy in 0..<gh {
            for gx in 0..<gw {
                var sum = 0.0, wSum = 0.0
                for dy in -1...1 {
                    let ny = min(gh - 1, max(0, gy + dy))
                    for dx in -1...1 {
                        let nx = min(gw - 1, max(0, gx + dx))
                        let wt = (dx == 0 && dy == 0) ? 4.0 : 1.0
                        sum += filled[ny * gw + nx] * wt
                        wSum += wt
                    }
                }
                smoothed[gy * gw + gx] = sum / wSum
            }
        }

        // 双线性插值还原全分辨率平坦背景表面
        var field = [Double](repeating: fallbackMedian, count: width * height)
        for y in 0..<height {
            let fy = (Double(y) + 0.5) / Double(blockSize) - 0.5
            let gy0 = min(gh - 1, max(0, Int(floor(fy))))
            let gy1 = min(gh - 1, max(0, gy0 + 1))
            let wy = min(1.0, max(0.0, fy - Double(gy0)))
            for x in 0..<width {
                let fx = (Double(x) + 0.5) / Double(blockSize) - 0.5
                let gx0 = min(gw - 1, max(0, Int(floor(fx))))
                let gx1 = min(gw - 1, max(0, gx0 + 1))
                let wx = min(1.0, max(0.0, fx - Double(gx0)))
                let v00 = smoothed[gy0 * gw + gx0]
                let v10 = smoothed[gy0 * gw + gx1]
                let v01 = smoothed[gy1 * gw + gx0]
                let v11 = smoothed[gy1 * gw + gx1]
                let top = v00 * (1.0 - wx) + v10 * wx
                let bot = v01 * (1.0 - wx) + v11 * wx
                field[y * width + x] = top * (1.0 - wy) + bot * wy
            }
        }
        return field
    }

    private static func promoteSmallAndFaintColonies(
        into mask: inout [UInt8],
        highMask: [UInt8],
        lowMask: [UInt8],
        contrast: [Float],
        width: Int,
        height: Int,
        tLow: Double,
        contrastOtsu: Double,
        minArea: Int
    ) {
        let total = width * height
        var visited = [Bool](repeating: false, count: total)
        var stack: [Int] = []
        stack.reserveCapacity(128)
        let peakMin = max(18.0, tLow * 1.32, min(26.0, contrastOtsu * 0.25))

        for seed in 0..<total {
            if (highMask[seed] == 0 && lowMask[seed] == 0) || visited[seed] { continue }
            visited[seed] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)

            var pixels: [Int] = []
            var highCount = 0
            var maxC = 0.0
            var sumC = 0.0

            while let p = stack.popLast() {
                pixels.append(p)
                if highMask[p] > 0 { highCount += 1 }
                let c = Double(contrast[p])
                if c > maxC { maxC = c }
                sumC += c
                let x = p % width
                let y = p / width
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= height { continue }
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = x + dx
                        if nx < 0 || nx >= width { continue }
                        let ni = ny * width + nx
                        if (highMask[ni] > 0 || lowMask[ni] > 0) && !visited[ni] {
                            visited[ni] = true
                            stack.append(ni)
                        }
                    }
                }
            }

            if highCount == 0 {
                // 纯低对比度独立微弱小菌落
                if pixels.count >= minArea && maxC >= peakMin && (sumC / Double(pixels.count)) >= tLow * 1.04 {
                    for p in pixels { mask[p] = 1 }
                }
            } else if highCount <= 22 && maxC >= peakMin {
                // 仅核心几个像素穿过 tHigh 的微小菌落：按半峰全宽 FWHM 向下收拢还原完整微小菌体，避免小于 4px² 漏检
                let fwhmCutoff = max(tLow, maxC * 0.50)
                let expanded = pixels.filter { Double(contrast[$0]) >= fwhmCutoff }
                if expanded.count >= minArea {
                    for p in expanded { mask[p] = 1 }
                }
            }
        }
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

    /// 构造菌落计数与蓝白斑筛选的 AnalysisRun v2 溯源记录
    public static func buildColonyAnalysisRun(
        markers: [ColonyMarkerItem],
        otsu: Double,
        appliedThreshold: Double,
        params: ColonySegmentationParams,
        sourceImageURL: URL? = nil,
        planeWidth: Int? = nil,
        planeHeight: Int? = nil,
        manualEdits: [AnalysisRun.ManualEdit] = [],
        outputs: [String] = [],
        exportDirectoryURL: URL? = nil,
        linkedPlasmidIDs: [String] = []
    ) -> AnalysisRun {
        let summary = summarize(
            markers: markers,
            otsu: otsu,
            appliedThreshold: appliedThreshold,
            params: params
        )

        var inputs: [AnalysisRun.InputFile] = []
        if let srcURL = sourceImageURL,
           let inputItem = AnalysisRun.makeInputFile(at: srcURL, relativeTo: exportDirectoryURL) {
            inputs.append(inputItem)
        }

        var paramsDict: [String: AnyCodableValue] = [
            "polarity": .string(params.polarity.rawValue),
            "blurRadius": .double(params.blurRadius),
            "minArea": .int(params.minArea),
            "maxArea": .int(params.maxArea),
            "minCircularity": .double(params.minCircularity),
            "classifyBlueWhite": .bool(params.classifyBlueWhite),
            "dilutionFactor": .double(params.dilutionFactor),
            "platedVolumeMl": .double(params.platedVolumeMl),
            "otsuThreshold": .double(otsu),
            "appliedThreshold": .double(appliedThreshold),
            "totalDetected": .int(summary.totalDetected),
            "includedCount": .int(summary.includedCount),
            "blueCount": .int(summary.blueCount),
            "whiteCount": .int(summary.whiteCount),
            "whitePositiveRatePct": .double(summary.whitePositiveRatePct)
        ]
        if let w = planeWidth, let h = planeHeight {
            paramsDict["imageWidth"] = .int(w)
            paramsDict["imageHeight"] = .int(h)
        }
        if let cfu = summary.cfuPerMl {
            paramsDict["cfuPerMl"] = .double(cfu)
        }

        var allEdits = manualEdits
        let recordedManualKeys = Set(manualEdits.map(\.what))
        for m in markers where m.isManual {
            let key = "manual_add_marker:#\(m.id)"
            if !recordedManualKeys.contains(key) {
                allEdits.append(
                    AnalysisRun.ManualEdit(
                        what: key,
                        before: "absent",
                        after: "x=\(String(format: "%.1f", m.x)),y=\(String(format: "%.1f", m.y)),class=\(m.colonyClass.rawValue)"
                    )
                )
            }
        }

        let exclusions = markers.filter { !$0.included }.map { m in
            AnalysisRun.Exclusion(itemID: "marker:#\(m.id)", reason: "手动排除菌落点")
        }

        return AnalysisRun(
            schemaVersion: 2,
            module: NavItem.colonyCounter.rawValue,
            engine: "swift-native",
            inputs: inputs,
            parameters: paramsDict,
            manualEdits: allEdits,
            exclusions: exclusions,
            outputs: outputs,
            linkedPlasmidIDs: linkedPlasmidIDs
        )
    }

    /// 导出菌落计数 CSV 并同步写出 `<basename>.run.json` 溯源伴随文件
    @discardableResult
    public static func exportMarkersCSVWithProvenance(
        markers: [ColonyMarkerItem],
        otsu: Double,
        appliedThreshold: Double,
        params: ColonySegmentationParams,
        sourceImageURL: URL? = nil,
        planeWidth: Int? = nil,
        planeHeight: Int? = nil,
        manualEdits: [AnalysisRun.ManualEdit] = [],
        linkedPlasmidIDs: [String] = [],
        to outputCSVURL: URL,
        indexURL: URL? = nil
    ) throws -> (csvURL: URL, sidecarURL: URL, run: AnalysisRun) {
        let csvText = exportMarkersCSV(markers: markers)
        try csvText.write(to: outputCSVURL, atomically: true, encoding: .utf8)

        let run = buildColonyAnalysisRun(
            markers: markers,
            otsu: otsu,
            appliedThreshold: appliedThreshold,
            params: params,
            sourceImageURL: sourceImageURL,
            planeWidth: planeWidth,
            planeHeight: planeHeight,
            manualEdits: manualEdits,
            outputs: [outputCSVURL.lastPathComponent],
            exportDirectoryURL: outputCSVURL.deletingLastPathComponent(),
            linkedPlasmidIDs: linkedPlasmidIDs
        )
        let includedCount = run.parameters["includedCount"]?.intValue ?? 0
        let blueCount = run.parameters["blueCount"]?.intValue ?? 0
        let whiteCount = run.parameters["whiteCount"]?.intValue ?? 0
        let sidecarURL = try run.writeSidecarJSON(
            alongsideOutputURL: outputCSVURL,
            indexURL: indexURL,
            summary: "菌落计数 \(includedCount) 个 (蓝=\(blueCount), 白=\(whiteCount))"
        )
        return (outputCSVURL, sidecarURL, run)
    }
}
