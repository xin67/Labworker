import Foundation

// MARK: - 1. 凝胶电泳标准品 (Marker Ladder) 与条带模型 (对应 SPICE_GUI `/tools/gel`)

public enum GelKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case dna = "dna"
    case protein = "protein"
    
    public var id: String { rawValue }
    
    public var title: String {
        switch self {
        case .dna:     return "DNA 琼脂糖电泳 (bp)"
        case .protein: return "蛋白质 SDS-PAGE (kDa)"
        }
    }
    
    public var unit: String {
        self == .dna ? "bp" : "kDa"
    }
}

public struct GelMarkerLadderPreset: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let kind: GelKind
    /// 从大到小排列的标准条带分子量
    public let sizes: [Double]
    /// 加亮指示带
    public let highlightSizes: [Double]
    
    public static let builtinPresets: [GelMarkerLadderPreset] = [
        GelMarkerLadderPreset(
            id: "dl2000",
            name: "Takara DL2000 (100–2000 bp)",
            kind: .dna,
            sizes: [2000, 1000, 750, 500, 250, 100],
            highlightSizes: [750]
        ),
        GelMarkerLadderPreset(
            id: "dl5000",
            name: "Takara DL5000 (100–5000 bp)",
            kind: .dna,
            sizes: [5000, 3000, 2000, 1500, 1000, 750, 500, 250, 100],
            highlightSizes: [1000]
        ),
        GelMarkerLadderPreset(
            id: "neb1kbplus",
            name: "NEB 1 kb Plus (100–10000 bp)",
            kind: .dna,
            sizes: [10000, 8000, 6000, 5000, 4000, 3000, 2000, 1500, 1200, 1000, 800, 600, 500, 400, 300, 200, 100],
            highlightSizes: [3000, 1000, 500]
        ),
        GelMarkerLadderPreset(
            id: "trans2kplus",
            name: "TransGen Trans2K Plus (100–5000 bp)",
            kind: .dna,
            sizes: [5000, 3000, 2000, 1000, 750, 500, 250, 100],
            highlightSizes: [750]
        ),
        GelMarkerLadderPreset(
            id: "pageruler180",
            name: "Thermo PageRuler Prestained (10–180 kDa)",
            kind: .protein,
            sizes: [180, 130, 100, 70, 55, 40, 35, 25, 15, 10],
            highlightSizes: [70, 25]
        ),
        GelMarkerLadderPreset(
            id: "biorad250",
            name: "Bio-Rad Precision Plus Dual Color (10–250 kDa)",
            kind: .protein,
            sizes: [250, 150, 100, 75, 50, 37, 25, 20, 15, 10],
            highlightSizes: [75, 25]
        )
    ]
}

public struct GelBandItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    /// 归一化迁移距离 (0..1，从上到下)
    public var yFraction: Double
    public var prominence: Double
    /// 若该泳道为 Marker 泳道，则绑定标准品已知分子量；否则为拟合推算出的分子量
    public var knownSize: Double?
    public var estimatedSize: Double?
    public var isVirtualDigestBand: Bool
    
    public init(
        id: String = UUID().uuidString,
        yFraction: Double,
        prominence: Double = 0.5,
        knownSize: Double? = nil,
        estimatedSize: Double? = nil,
        isVirtualDigestBand: Bool = false
    ) {
        self.id = id
        self.yFraction = yFraction
        self.prominence = prominence
        self.knownSize = knownSize
        self.estimatedSize = estimatedSize
        self.isVirtualDigestBand = isVirtualDigestBand
    }
}

public struct GelLaneItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var index: Int
    public var name: String
    public var isLadderLane: Bool
    public var isVirtualDigestLane: Bool
    /// 归一化中心横坐标 (0..1)
    public var centerX: Double
    public var widthFrac: Double
    public var bands: [GelBandItem]
    
    public init(
        id: String = UUID().uuidString,
        index: Int,
        name: String,
        isLadderLane: Bool = false,
        isVirtualDigestLane: Bool = false,
        centerX: Double,
        widthFrac: Double = 0.09,
        bands: [GelBandItem] = []
    ) {
        self.id = id
        self.index = index
        self.name = name
        self.isLadderLane = isLadderLane
        self.isVirtualDigestLane = isVirtualDigestLane
        self.centerX = centerX
        self.widthFrac = widthFrac
        self.bands = bands
    }
}

public struct GelLadderCalibrationFit: Sendable {
    /// 全局对数线性参考回归：log10(size) = slope * y + intercept
    public let slope: Double
    public let intercept: Double
    public let r2: Double
    public let n: Int
    public let points: [(y: Double, log10Size: Double, size: Double)]
    /// 自然三次样条分段系数（按 y 升序排列，用于琼脂糖凝胶非对数线性两端的精确插值）
    public let splineKnotsY: [Double]
    public let splineA: [Double]
    public let splineB: [Double]
    public let splineC: [Double]
    public let splineD: [Double]
    /// 凝胶泳道顶部起点与前沿终点（用于计算规范相对迁移率 Rf）
    public let wellOriginY: Double
    public let dyeFrontY: Double

    public init(
        slope: Double,
        intercept: Double,
        r2: Double,
        n: Int,
        points: [(y: Double, log10Size: Double, size: Double)],
        wellOriginY: Double = 0.05,
        dyeFrontY: Double = 0.95
    ) {
        self.slope = slope
        self.intercept = intercept
        self.r2 = r2
        self.n = n
        self.points = points
        self.wellOriginY = wellOriginY
        self.dyeFrontY = max(wellOriginY + 0.1, dyeFrontY)

        // 构建单调保形 Fritsch-Carlson PCHIP 三次 Hermite 样条拟合 y -> log10(size)（杜绝龙格过冲与边界跳变）
        let sorted = points.sorted { $0.y < $1.y }
        var uniqY: [Double] = []
        var uniqLog: [Double] = []
        for p in sorted {
            if let lastY = uniqY.last, abs(p.y - lastY) < 1e-6 { continue }
            uniqY.append(p.y)
            uniqLog.append(p.log10Size)
        }
        let m = uniqY.count
        if m >= 3 {
            let k = m - 1
            var h = Array(repeating: 0.0, count: k)
            var delta = Array(repeating: 0.0, count: k)
            for i in 0..<k {
                h[i] = uniqY[i + 1] - uniqY[i]
                delta[i] = (uniqLog[i + 1] - uniqLog[i]) / max(1e-12, h[i])
            }
            var dSlope = Array(repeating: 0.0, count: m)
            // 内部节点使用 Fritsch-Carlson 加权调和均值保证严格单调性
            for i in 1..<k {
                if delta[i - 1] * delta[i] <= 0.0 {
                    dSlope[i] = 0.0
                } else {
                    let w1 = 2.0 * h[i] + h[i - 1]
                    let w2 = h[i] + 2.0 * h[i - 1]
                    dSlope[i] = (w1 + w2) / (w1 / delta[i - 1] + w2 / delta[i])
                }
            }
            // 端点单侧保形切线（Fritsch-Carlson / SciPy PchipInterpolator 标准公式）
            func endpointSlope(_ h0: Double, _ h1: Double, _ del0: Double, _ del1: Double) -> Double {
                var d0 = ((2.0 * h0 + h1) * del0 - h0 * del1) / max(1e-12, h0 + h1)
                if d0 * del0 <= 0.0 {
                    d0 = 0.0
                } else if del0 * del1 <= 0.0 && abs(d0) > abs(3.0 * del0) {
                    d0 = 3.0 * del0
                }
                return d0
            }
            dSlope[0] = endpointSlope(h[0], h[1], delta[0], delta[1])
            dSlope[m - 1] = endpointSlope(h[k - 1], h[k - 2], delta[k - 1], delta[k - 2])

            var a = Array(repeating: 0.0, count: k)
            var b = Array(repeating: 0.0, count: k)
            var c = Array(repeating: 0.0, count: k)
            var d = Array(repeating: 0.0, count: k)
            for j in 0..<k {
                a[j] = uniqLog[j]
                b[j] = dSlope[j]
                c[j] = (3.0 * delta[j] - 2.0 * dSlope[j] - dSlope[j + 1]) / max(1e-12, h[j])
                d[j] = (dSlope[j] + dSlope[j + 1] - 2.0 * delta[j]) / max(1e-12, h[j] * h[j])
            }
            self.splineKnotsY = uniqY
            self.splineA = a
            self.splineB = b
            self.splineC = c
            self.splineD = d
        } else {
            self.splineKnotsY = []
            self.splineA = []
            self.splineB = []
            self.splineC = []
            self.splineD = []
        }
    }

    /// 规范相对迁移率 Rf = (y - wellOriginY) / (dyeFrontY - wellOriginY)
    public func relativeMobility(atY y: Double) -> Double {
        max(0.0, min(1.0, (y - wellOriginY) / (dyeFrontY - wellOriginY)))
    }

    /// 使用 Fritsch-Carlson PCHIP 单调样条内插；超出 Marker 范围时沿端点切线执行 C¹ 连续线性外推（消除边界跳变）
    public func log10Size(atY y: Double) -> Double {
        if splineKnotsY.count >= 3, let yFirst = splineKnotsY.first, let yLast = splineKnotsY.last {
            if y < yFirst {
                let endSlope = abs(splineB[0]) > 1e-6 ? splineB[0] : slope
                return splineA[0] + endSlope * (y - yFirst)
            }
            if y > yLast {
                let lastSeg = splineKnotsY.count - 2
                let hLast = splineKnotsY[lastSeg + 1] - splineKnotsY[lastSeg]
                let yEndVal = splineA[lastSeg] + splineB[lastSeg] * hLast + splineC[lastSeg] * hLast * hLast + splineD[lastSeg] * hLast * hLast * hLast
                let dEnd = splineB[lastSeg] + 2.0 * splineC[lastSeg] * hLast + 3.0 * splineD[lastSeg] * hLast * hLast
                let endSlope = abs(dEnd) > 1e-6 ? dEnd : slope
                return yEndVal + endSlope * (y - yLast)
            }
            var seg = splineKnotsY.count - 2
            for i in 0..<(splineKnotsY.count - 1) {
                if y >= splineKnotsY[i] && y <= splineKnotsY[i + 1] {
                    seg = i
                    break
                }
            }
            let dy = y - splineKnotsY[seg]
            return splineA[seg] + splineB[seg] * dy + splineC[seg] * dy * dy + splineD[seg] * dy * dy * dy
        }
        return slope * y + intercept
    }

    public func size(atY y: Double) -> Double {
        pow(10.0, log10Size(atY: y))
    }

    public func yPosition(forSize size: Double) -> Double {
        guard size > 0, abs(slope) > 1e-9 else { return 0.5 }
        let targetLog = log10(size)
        // 若在样条覆盖的分子量区间内，使用二分法反求三次样条精确迁移位置 y
        if splineKnotsY.count >= 3, let yFirst = splineKnotsY.first, let yLast = splineKnotsY.last {
            let logFirst = log10Size(atY: yFirst)
            let logLast = log10Size(atY: yLast)
            let loLog = min(logFirst, logLast)
            let hiLog = max(logFirst, logLast)
            if targetLog >= loLog && targetLog <= hiLog {
                var loY = yFirst
                var hiY = yLast
                let decreasing = logFirst > logLast
                for _ in 0..<32 {
                    let mid = 0.5 * (loY + hiY)
                    let val = log10Size(atY: mid)
                    if (decreasing && val > targetLog) || (!decreasing && val < targetLog) {
                        loY = mid
                    } else {
                        hiY = mid
                    }
                }
                return min(0.92, max(0.08, 0.5 * (loY + hiY)))
            }
        }
        return min(0.92, max(0.08, (targetLog - intercept) / slope))
    }
}

public enum GelVirtualPredictionSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case plasmidDigest = "plasmidDigest"
    case singleFragment = "singleFragment"
    case multiFragment = "multiFragment"
    case entryClone = "entryClone"
    case fragmentDeletion = "fragmentDeletion"
    case mutagenesis = "mutagenesis"
    case customSizes = "customSizes"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plasmidDigest:    return "质粒酶切"
        case .singleFragment:   return "单片段克隆"
        case .multiFragment:    return "多片段组装"
        case .entryClone:       return "入门克隆"
        case .fragmentDeletion: return "片段删除"
        case .mutagenesis:      return "定点突变"
        case .customSizes:      return "自定义条带"
        }
    }

    public var icon: String {
        switch self {
        case .plasmidDigest:    return "scissors"
        case .singleFragment:   return "link"
        case .multiFragment:    return "square.stack.3d.up"
        case .entryClone:       return "arrow.right.doc.on.clipboard"
        case .fragmentDeletion: return "scissors.badge.ellipsis"
        case .mutagenesis:      return "wand.and.stars"
        case .customSizes:      return "slider.horizontal.3"
        }
    }
}

// MARK: - 2. 凝胶电泳泳道识别、标准曲线回归与多模块虚拟电泳联动引擎

public enum GelAnalysisEngine {
    
    /// 自动从胶图检测泳道与条带，并将首个泳道配准到指定 Marker Ladder
    public static func autoDetectAndCalibrate(
        plane: BioImagePlane,
        ladder: GelMarkerLadderPreset
    ) -> (lanes: [GelLaneItem], fit: GelLadderCalibrationFit?) {
        let w = plane.width
        let h = plane.height
        let (_, isBright) = BioImageProcessor.adaptiveBinarizeGel(gray: plane.gray, width: w, height: h)
        let invert = !isBright
        
        let colProf = BioImageProcessor.columnProfile(
            gray: plane.gray,
            width: w,
            height: h,
            y0: Int(Double(h) * 0.08),
            y1: Int(Double(h) * 0.92),
            invert: invert
        )
        let lanePeaks = BioImageProcessor.findPeaks(
            profile: colProf,
            minProminence: 0.025,
            minGap: max(8, w / 12),
            smoothWindow: 5
        )
        let laneXs: [Double] = lanePeaks.count >= 2
            ? lanePeaks.map(\.fraction)
            : [0.15, 0.33, 0.51, 0.69, 0.85]
        
        var lanes: [GelLaneItem] = []
        let sampleLabels = ["Marker", "pETDuet-DoubleDigest", "TP53-PCR", "MYC-Insert", "Neg-Ctrl"]
        
        for (idx, cx) in laneXs.enumerated() {
            let x0 = max(0, Int(round((cx - 0.035) * Double(w))))
            let x1 = min(w, Int(round((cx + 0.035) * Double(w))))
            let rProf = BioImageProcessor.rowProfile(
                gray: plane.gray,
                width: w,
                height: h,
                x0: x0,
                x1: x1,
                invert: invert
            )
            let bPeaks = BioImageProcessor.findPeaks(
                profile: rProf,
                minProminence: 0.03,
                minGap: max(5, h / 28),
                smoothWindow: 3
            )
            let isLadder = (idx == 0)
            var bands: [GelBandItem] = []
            for (bIdx, pk) in bPeaks.enumerated() {
                let known: Double? = (isLadder && bIdx < ladder.sizes.count) ? ladder.sizes[bIdx] : nil
                bands.append(
                    GelBandItem(
                        yFraction: pk.fraction,
                        prominence: pk.prominence,
                        knownSize: known
                    )
                )
            }
            let laneName = idx < sampleLabels.count ? sampleLabels[idx] : "Lane \(idx + 1)"
            lanes.append(
                GelLaneItem(
                    index: idx + 1,
                    name: laneName,
                    isLadderLane: isLadder,
                    isVirtualDigestLane: false,
                    centerX: cx,
                    widthFrac: 0.085,
                    bands: bands
                )
            )
        }
        
        let calibrated = recalibrateLanes(lanes: lanes, ladder: ladder)
        return calibrated
    }
    
    /// 根据 Marker 泳道的条带迁移位置执行最小二乘对数分子量拟合，自动推算所有实测条带大小并同步重算所有虚拟预测条带的迁移位置
    public static func recalibrateLanes(
        lanes: [GelLaneItem],
        ladder: GelMarkerLadderPreset
    ) -> (lanes: [GelLaneItem], fit: GelLadderCalibrationFit?) {
        var updated = lanes
        var calibrationPoints: [(y: Double, log10Size: Double, size: Double)] = []
        
        if let ladderIdx = updated.firstIndex(where: \.isLadderLane) {
            let sortedBands = updated[ladderIdx].bands.sorted { $0.yFraction < $1.yFraction }
            var assignedBands = sortedBands
            var sizeAssignment = Array<Double?>(repeating: nil, count: sortedBands.count)
            if sortedBands.count == ladder.sizes.count {
                for i in 0..<sortedBands.count { sizeAssignment[i] = ladder.sizes[i] }
            } else if !ladder.highlightSizes.isEmpty && sortedBands.count >= 2 {
                // 使用 Marker 高亮指示条带 (highlightSizes) 与实测最高显著度峰锚定对齐，避免漏检条带引发全列错位
                if let anchorSize = ladder.highlightSizes.first,
                   let anchorSizeIdx = ladder.sizes.firstIndex(of: anchorSize),
                   let bestBandIdx = sortedBands.indices.max(by: { sortedBands[$0].prominence < sortedBands[$1].prominence }) {
                    for i in 0..<sortedBands.count {
                        let targetIdx = anchorSizeIdx + (i - bestBandIdx)
                        if targetIdx >= 0 && targetIdx < ladder.sizes.count {
                            sizeAssignment[i] = ladder.sizes[targetIdx]
                        }
                    }
                }
            }
            for i in 0..<assignedBands.count {
                let sz = sizeAssignment[i] ?? (i < ladder.sizes.count ? ladder.sizes[i] : nil)
                if let sz = sz {
                    assignedBands[i].knownSize = sz
                    assignedBands[i].estimatedSize = sz
                    calibrationPoints.append((y: assignedBands[i].yFraction, log10Size: log10(sz), size: sz))
                }
            }
            updated[ladderIdx].bands = assignedBands
        }
        
        let regInput = calibrationPoints.map { (x: $0.y, y: $0.log10Size) }
        guard let reg = QPCRStatistics.linearRegression(regInput) else {
            return (updated, nil)
        }
        let fit = GelLadderCalibrationFit(
            slope: reg.slope,
            intercept: reg.intercept,
            r2: reg.r2,
            n: calibrationPoints.count,
            points: calibrationPoints
        )
        
        for lIdx in updated.indices {
            for bIdx in updated[lIdx].bands.indices {
                if updated[lIdx].bands[bIdx].isVirtualDigestBand, let known = updated[lIdx].bands[bIdx].knownSize {
                    updated[lIdx].bands[bIdx].yFraction = fit.yPosition(forSize: known)
                    updated[lIdx].bands[bIdx].estimatedSize = known
                } else if let known = updated[lIdx].bands[bIdx].knownSize {
                    updated[lIdx].bands[bIdx].estimatedSize = known
                } else {
                    let est = fit.size(atY: updated[lIdx].bands[bIdx].yFraction)
                    updated[lIdx].bands[bIdx].estimatedSize = est
                }
            }
        }
        return (updated, fit)
    }

    /// 对所有泳道重新编号，并为多条虚拟预测泳道分配不重叠的横向坐标与带宽
    public static func layoutVirtualLanes(_ lanes: [GelLaneItem]) -> [GelLaneItem] {
        var updated = lanes
        for idx in updated.indices {
            updated[idx].index = idx + 1
        }
        let virtualIndices = updated.indices.filter { updated[$0].isVirtualDigestLane }
        guard !virtualIndices.isEmpty else { return updated }

        if virtualIndices.count == 1 {
            let vIdx = virtualIndices[0]
            updated[vIdx].centerX = 0.92
            updated[vIdx].widthFrac = 0.08
            return updated
        }

        let count = virtualIndices.count
        let rightBound = 0.95
        let desiredSpan = Double(count - 1) * 0.09
        let leftBound = max(0.54, rightBound - min(0.41, desiredSpan))
        let step = (rightBound - leftBound) / Double(max(1, count - 1))
        let widthFrac = min(0.075, max(0.042, step * 0.72))

        for (offset, laneIdx) in virtualIndices.enumerated() {
            updated[laneIdx].centerX = leftBound + Double(offset) * step
            updated[laneIdx].widthFrac = widthFrac
        }
        return updated
    }
    
    /// 从质粒序列与指定限制性内切酶直接模拟计算理论酶切片段大小，并映射为虚拟电泳参照泳道
    public static func buildVirtualDigestLane(
        plasmidName: String,
        sequence: String,
        isCircular: Bool,
        enzymeNames: [String],
        fit: GelLadderCalibrationFit?,
        laneIndex: Int
    ) -> GelLaneItem {
        let cleanSeq = BioSequence.clean(sequence)
        let totalLen = max(1, cleanSeq.count)
        let cuts = RestrictionEnzymeDatabase.shared.scanConstructCutsites(
            sequence: cleanSeq,
            circular: isCircular,
            enzymeNames: enzymeNames
        )
        let positions = Array(Set(cuts.map(\.topSnip0Based))).sorted()
        
        var fragmentSizes: [Int] = []
        if positions.isEmpty {
            fragmentSizes = [totalLen]
        } else if isCircular {
            if positions.count == 1 {
                fragmentSizes = [totalLen]
            } else {
                for i in 0..<positions.count {
                    let nextPos = (i + 1 < positions.count) ? positions[i + 1] : (positions[0] + totalLen)
                    let frag = max(1, nextPos - positions[i])
                    fragmentSizes.append(frag)
                }
            }
        } else {
            var prev = 0
            for p in positions {
                if p > prev { fragmentSizes.append(p - prev) }
                prev = p
            }
            if totalLen > prev { fragmentSizes.append(totalLen - prev) }
        }
        fragmentSizes.sort(by: >)
        
        let bands: [GelBandItem] = fragmentSizes.map { sz in
            let sizeD = Double(sz)
            let yPos = fit?.yPosition(forSize: sizeD) ?? min(0.88, max(0.12, 0.85 - log10(sizeD) * 0.16))
            return GelBandItem(
                yFraction: yPos,
                prominence: 0.9,
                knownSize: sizeD,
                estimatedSize: sizeD,
                isVirtualDigestBand: true
            )
        }
        
        let enzTitle = enzymeNames.joined(separator: "+")
        return GelLaneItem(
            index: laneIndex,
            name: L10n.tr("酶切:\(plasmidName)(\(enzTitle))", "Digest:\(plasmidName)(\(enzTitle))"),
            isLadderLane: false,
            isVirtualDigestLane: true,
            centerX: 0.92,
            widthFrac: 0.08,
            bands: bands
        )
    }

    /// 将同源重组/片段删除/入门克隆模拟结果映射为凝胶画布上的虚拟预测泳道
    public static func buildVirtualLanesFromSimulation(
        _ simulation: HomologousPCRGelSimulationResult,
        sourceTag: String,
        fit: GelLadderCalibrationFit?,
        startingLaneIndex: Int,
        includeMixedControl: Bool = false
    ) -> [GelLaneItem] {
        let candidateLanes = simulation.lanes.filter { simLane in
            !simLane.isMarker
                && (includeMixedControl || !simLane.isMixedControl)
                && !simLane.bands.isEmpty
        }
        var results: [GelLaneItem] = []
        for (offset, simLane) in candidateLanes.enumerated() {
            let mappedBands: [GelBandItem] = simLane.bands
                .filter { $0.sizeBp > 0 }
                .sorted { $0.sizeBp > $1.sizeBp }
                .map { simBand in
                    let sizeD = Double(simBand.sizeBp)
                    let yPos = fit?.yPosition(forSize: sizeD) ?? simBand.yFraction
                    return GelBandItem(
                        yFraction: yPos,
                        prominence: max(0.65, simBand.relativeBrightness),
                        knownSize: sizeD,
                        estimatedSize: sizeD,
                        isVirtualDigestBand: true
                    )
                }
            guard !mappedBands.isEmpty else { continue }
            let cleanTag = sourceTag.trimmingCharacters(in: .whitespacesAndNewlines)
            let laneTitle = cleanTag.isEmpty ? simLane.shortLabel : "\(cleanTag):\(simLane.shortLabel)"
            results.append(
                GelLaneItem(
                    index: startingLaneIndex + offset,
                    name: laneTitle,
                    isLadderLane: false,
                    isVirtualDigestLane: true,
                    centerX: 0.92,
                    widthFrac: 0.08,
                    bands: mappedBands
                )
            )
        }
        return results
    }

    /// 构造定点突变全质粒反向 PCR 扩增产物虚拟预测泳道
    public static func buildMutagenesisVirtualLane(
        plasmidName: String,
        parentalLengthBp: Int,
        mutatedLengthBp: Int,
        homologyLength: Int = 18,
        mutationLabel: String = "",
        fit: GelLadderCalibrationFit?,
        laneIndex: Int
    ) -> GelLaneItem {
        let baseLen = mutatedLengthBp > 0 ? mutatedLengthBp : max(100, parentalLengthBp)
        let ampliconBp = Double(baseLen + max(0, homologyLength))
        var sizes: [Double] = [ampliconBp]
        if parentalLengthBp > 0 && abs(parentalLengthBp - baseLen) >= 50 {
            sizes.append(Double(parentalLengthBp))
        }
        sizes.sort(by: >)
        let suffix = mutationLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let laneName = suffix.isEmpty ? L10n.tr("突变:\(plasmidName)", "Mut:\(plasmidName)") : L10n.tr("突变:\(suffix)", "Mut:\(suffix)")
        return buildCustomVirtualLane(
            laneName: laneName,
            sizes: sizes,
            fit: fit,
            laneIndex: laneIndex
        )
    }

    /// 按用户自定义分子量/片段长度数组生成虚拟预测泳道（同时支持 DNA bp 与 SDS-PAGE 蛋白质 kDa）
    public static func buildCustomVirtualLane(
        laneName: String,
        sizes: [Double],
        fit: GelLadderCalibrationFit?,
        laneIndex: Int
    ) -> GelLaneItem {
        let sortedSizes = sizes.filter { $0 > 0 }.sorted(by: >)
        let bands: [GelBandItem] = sortedSizes.map { sz in
            let yPos = fit?.yPosition(forSize: sz) ?? min(0.88, max(0.12, 0.85 - log10(max(1.0, sz)) * 0.16))
            return GelBandItem(
                yFraction: yPos,
                prominence: 0.9,
                knownSize: sz,
                estimatedSize: sz,
                isVirtualDigestBand: true
            )
        }
        let title = laneName.trimmingCharacters(in: .whitespacesAndNewlines)
        return GelLaneItem(
            index: laneIndex,
            name: title.isEmpty ? L10n.t("自定义预测") : title,
            isLadderLane: false,
            isVirtualDigestLane: true,
            centerX: 0.92,
            widthFrac: 0.08,
            bands: bands
        )
    }

    /// 解析用户输入的条带大小文本（支持逗号/空格/分号分隔，自动识别 kb 与 kDa 单位后缀）
    public static func parseCustomBandSizes(_ rawText: String) -> [Double] {
        let separators = CharacterSet(charactersIn: ",，;；\n\t ")
        let tokens = rawText
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var values: [Double] = []
        for token in tokens {
            let lower = token.lowercased()
            if lower.hasSuffix("kb"), let num = Double(lower.dropLast(2)), num > 0 {
                values.append(num * 1000.0)
            } else if lower.hasSuffix("bp"), let num = Double(lower.dropLast(2)), num > 0 {
                values.append(num)
            } else if lower.hasSuffix("kda"), let num = Double(lower.dropLast(3)), num > 0 {
                values.append(num)
            } else if let num = Double(lower), num > 0 {
                values.append(num)
            }
        }
        return values.sorted(by: >)
    }
    
    public static func exportGelBandsCSV(lanes: [GelLaneItem], unit: String) -> String {
        var lines = ["Lane_Index,Lane_Name,Is_Ladder,Is_Virtual_Digest,Band_Y_Fraction,Estimated_Size_\(unit)"]
        for lane in lanes {
            for band in lane.bands {
                let sz = band.estimatedSize.map { String(format: "%.1f", $0) } ?? ""
                lines.append(
                    "\(lane.index),\(lane.name),\(lane.isLadderLane),\(lane.isVirtualDigestLane),\(String(format: "%.4f", band.yFraction)),\(sz)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 构造凝胶电泳分子量回归与多模块虚拟电泳对比的 AnalysisRun v2 溯源记录
    public static func buildGelAnalysisRun(
        lanes: [GelLaneItem],
        ladder: GelMarkerLadderPreset,
        fit: GelLadderCalibrationFit?,
        sourceImageURL: URL? = nil,
        virtualDigestEnzymes: [String] = [],
        virtualPredictionSources: [String] = [],
        manualEdits: [AnalysisRun.ManualEdit] = [],
        outputs: [String] = [],
        exportDirectoryURL: URL? = nil,
        linkedPlasmidIDs: [String] = []
    ) -> AnalysisRun {
        var inputs: [AnalysisRun.InputFile] = []
        if let srcURL = sourceImageURL,
           let inputItem = AnalysisRun.makeInputFile(at: srcURL, relativeTo: exportDirectoryURL) {
            inputs.append(inputItem)
        }

        var paramsDict: [String: AnyCodableValue] = [
            "ladderID": .string(ladder.id),
            "ladderName": .string(ladder.name),
            "unit": .string(ladder.kind.unit),
            "laneCount": .int(lanes.count),
            "totalBands": .int(lanes.reduce(0) { $0 + $1.bands.count }),
            "hasVirtualDigestLane": .bool(lanes.contains(where: \.isVirtualDigestLane))
        ]
        if let f = fit {
            paramsDict["fitSlope"] = .double(f.slope)
            paramsDict["fitIntercept"] = .double(f.intercept)
            paramsDict["fitR2"] = .double(f.r2)
            paramsDict["calibrationPointCount"] = .int(f.n)
        }
        if !virtualDigestEnzymes.isEmpty {
            paramsDict["virtualDigestEnzymes"] = .array(virtualDigestEnzymes.map { .string($0) })
        }
        if !virtualPredictionSources.isEmpty {
            paramsDict["virtualPredictionSources"] = .array(virtualPredictionSources.map { .string($0) })
        }

        return AnalysisRun(
            schemaVersion: 2,
            module: NavItem.gelFigure.rawValue,
            engine: "swift-native",
            inputs: inputs,
            parameters: paramsDict,
            manualEdits: manualEdits,
            exclusions: [],
            outputs: outputs,
            linkedPlasmidIDs: linkedPlasmidIDs
        )
    }

    /// 导出电泳条带分子量 CSV 并同步写出 `<basename>.run.json` 溯源伴随文件
    @discardableResult
    public static func exportGelBandsCSVWithProvenance(
        lanes: [GelLaneItem],
        ladder: GelMarkerLadderPreset,
        fit: GelLadderCalibrationFit?,
        sourceImageURL: URL? = nil,
        virtualDigestEnzymes: [String] = [],
        virtualPredictionSources: [String] = [],
        manualEdits: [AnalysisRun.ManualEdit] = [],
        linkedPlasmidIDs: [String] = [],
        to outputCSVURL: URL,
        indexURL: URL? = nil
    ) throws -> (csvURL: URL, sidecarURL: URL, run: AnalysisRun) {
        let csvText = exportGelBandsCSV(lanes: lanes, unit: ladder.kind.unit)
        try csvText.write(to: outputCSVURL, atomically: true, encoding: .utf8)

        let run = buildGelAnalysisRun(
            lanes: lanes,
            ladder: ladder,
            fit: fit,
            sourceImageURL: sourceImageURL,
            virtualDigestEnzymes: virtualDigestEnzymes,
            virtualPredictionSources: virtualPredictionSources,
            manualEdits: manualEdits,
            outputs: [outputCSVURL.lastPathComponent],
            exportDirectoryURL: outputCSVURL.deletingLastPathComponent(),
            linkedPlasmidIDs: linkedPlasmidIDs
        )
        let sidecarURL = try run.writeSidecarJSON(
            alongsideOutputURL: outputCSVURL,
            indexURL: indexURL,
            summary: L10n.tr("凝胶条带分子量分析 · \(ladder.name) (\(lanes.count) 泳道)", "Gel Band MW Analysis · \(ladder.name) (\(lanes.count) lanes)")
        )
        return (outputCSVURL, sidecarURL, run)
    }
}
