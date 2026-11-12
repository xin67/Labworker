import Foundation

// MARK: - 1. 环形区间与极角数据结构 (Ported from CloneCanvas utils/circularOve.ts)

public struct CircularRange: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// 0-based inclusive start (支持跨零点: start > end 代表跨越 Origin)
    public let start: Int
    /// 0-based inclusive end
    public let end: Int
    
    public init(id: UUID = UUID(), start: Int, end: Int) {
        self.id = id
        self.start = start
        self.end = end
    }
}

public struct RangeAngles: Sendable, Equatable {
    public let startAngle: Double
    public let endAngle: Double
    public let totalAngle: Double
    public let centerAngle: Double
    
    public init(startAngle: Double, endAngle: Double, totalAngle: Double, centerAngle: Double) {
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.totalAngle = totalAngle
        self.centerAngle = centerAngle
    }
}

/// 有向扇形环几何解算结果（纯数学，供 SwiftUI Canvas / Path 直接绘制）
public struct DirectedArcGeometry: Sendable, Equatable {
    public let startCanvasRad: Double
    public let endCanvasRad: Double
    public let bodyStartCanvasRad: Double
    public let bodyEndCanvasRad: Double
    public let tipCanvasRad: Double
    public let midCanvasRad: Double
    public let outerShoulderRadius: Double
    public let innerShoulderRadius: Double
    public let tipRadius: Double
    public let hasArrowhead: Bool
    public let isClockwise: Bool
}

// MARK: - 2. OVE 环形布局与同心轨道防重叠解算器

public enum CircularOVELayout {
    
    /// 1:1 OVE getRangeAnglesSpecial：将 0-based 闭区间映射为 12 点钟顺时针极角
    public static func getRangeAnglesSpecial(
        range: CircularRange,
        sequenceLength: Int
    ) -> RangeAngles {
        let len = max(sequenceLength, 1)
        let rawDiff = range.end - range.start + 1
        let rangeLength = ((rawDiff % len) + len) % len
        let effectiveLen = (rangeLength == 0 && rawDiff > 0) ? len : rangeLength
        
        let twoPi = 2.0 * Double.pi
        let startAngle = twoPi * (Double(range.start) / Double(len))
        let totalAngle = max(0.0001, (Double(effectiveLen) / Double(len)) * twoPi - 0.00001)
        let endAngle = twoPi * (Double(range.end + 1) / Double(len)) - 0.00001
        let centerAngle = CircularGeometry.normalizeAngle(startAngle + totalAngle / 2.0)
        
        return RangeAngles(
            startAngle: startAngle,
            endAngle: endAngle,
            totalAngle: totalAngle,
            centerAngle: centerAngle
        )
    }
    
    /// 从比例区间 [startRatio, endRatio] (0.0~1.0) 计算 12 点钟顺时针极角
    public static func getRatioRangeAngles(
        startRatio: Double,
        endRatio: Double
    ) -> RangeAngles {
        let twoPi = 2.0 * Double.pi
        let sAng = startRatio * twoPi
        var eAng = endRatio * twoPi
        if eAng <= sAng {
            eAng += twoPi
        }
        let total = max(0.02, eAng - sAng)
        let center = CircularGeometry.normalizeAngle(sAng + total / 2.0)
        return RangeAngles(
            startAngle: CircularGeometry.normalizeAngle(sAng),
            endAngle: eAng,
            totalAngle: total,
            centerAngle: center
        )
    }
    
    /// 判定两个环状区间是否重叠（支持跨零点 Origin 拆分检测）
    public static func circularRangesOverlap(
        _ r1: CircularRange,
        _ r2: CircularRange,
        sequenceLength: Int
    ) -> Bool {
        let len = max(sequenceLength, 1)
        let split1: [(Int, Int)] = r1.start > r1.end
            ? [(r1.start, len - 1), (0, r1.end)]
            : [(r1.start, r1.end)]
        let split2: [(Int, Int)] = r2.start > r2.end
            ? [(r2.start, len - 1), (0, r2.end)]
            : [(r2.start, r2.end)]
        
        for s1 in split1 {
            for s2 in split2 {
                if max(s1.0, s2.0) <= min(s1.1, s2.1) {
                    return true
                }
            }
        }
        return false
    }
    
    /// 1:1 OVE 同心圆轨道堆叠解算器 (calculateYOffsets)
    /// 将重叠的环状元件分配到不同的同心轨道层级 (0 为基准内轨，1, 2... 向外扩展)
    public static func calculateConcentricYOffsets(
        features ranges: [CircularRange],
        sequenceLength: Int
    ) -> [UUID: Int] {
        guard !ranges.isEmpty else { return [:] }
        let len = max(sequenceLength, 1)
        
        // 按跨度从长到短排序：长骨架特征居内，短局部特征居外
        let sorted = ranges.sorted { a, b in
            let lenA = ((a.end - a.start + 1) % len + len) % len
            let lenB = ((b.end - b.start + 1) % len + len) % len
            return lenA > lenB
        }
        
        var levels: [[CircularRange]] = []
        var offsetMap: [UUID: Int] = [:]
        
        for item in sorted {
            var yOffset = 0
            while yOffset < levels.count {
                let hasConflict = levels[yOffset].contains { existing in
                    circularRangesOverlap(item, existing, sequenceLength: len)
                }
                if !hasConflict { break }
                yOffset += 1
            }
            if yOffset == levels.count {
                levels.append([])
            }
            levels[yOffset].append(item)
            offsetMap[item.id] = yOffset
        }
        return offsetMap
    }
    
    /// 判断圆弧上的文字是否位于下半圆 (π/2 < θ < 3π/2)，若在下半圆则需翻转 180° 防止倒置
    public static func shouldFlipText(angleRadians: Double) -> Bool {
        let a = CircularGeometry.normalizeAngle(angleRadians)
        return a > Double.pi * 0.5 && a < Double.pi * 1.5
    }
    
    /// 1:1 OVE 弧内文本省略截断计算 (getEllipsizedName)
    public static func ellipsizedName(
        _ name: String,
        radius: Double,
        annotationHeight: Double,
        totalAngle: Double
    ) -> String? {
        guard !name.isEmpty else { return nil }
        let arcLength = 2.0 * Double.pi * max(10.0, radius - annotationHeight) * totalAngle
        let maxChars = max(0, Int(floor(arcLength / 18.0)) - 2)
        guard maxChars > 2 else { return nil }
        if name.count <= maxChars { return name }
        let prefixStr = String(name.prefix(max(2, maxChars - 2)))
        return prefixStr + ".."
    }
    
    /// 解算有向扇形弧段的几何参数（输入比例 [0, 1] 与旋转弧度）
    public static func computeDirectedArc(
        startRatio: Double,
        endRatio: Double,
        rInner: Double,
        rOuter: Double,
        isClockwise: Bool?,
        rotationRadians: Double = 0
    ) -> DirectedArcGeometry {
        let rotCanvasRad = rotationRadians - (Double.pi / 2.0)
        let sAng = startRatio * 2.0 * Double.pi + rotCanvasRad
        var eAng = endRatio * 2.0 * Double.pi + rotCanvasRad
        if eAng <= sAng {
            eAng += 2.0 * Double.pi
        }
        
        let span = max(0.045, eAng - sAng)
        let actualEnd = sAng + span
        let arrowSpan = min(0.13, span * 0.32)
        let overhang = (rOuter - rInner) * 0.26
        let rMid = (rOuter + rInner) / 2.0
        let midRad = (sAng + actualEnd) / 2.0
        
        guard let cw = isClockwise else {
            return DirectedArcGeometry(
                startCanvasRad: sAng,
                endCanvasRad: actualEnd,
                bodyStartCanvasRad: sAng,
                bodyEndCanvasRad: actualEnd,
                tipCanvasRad: actualEnd,
                midCanvasRad: midRad,
                outerShoulderRadius: rOuter,
                innerShoulderRadius: rInner,
                tipRadius: rMid,
                hasArrowhead: false,
                isClockwise: true
            )
        }
        
        if cw {
            let bodyEnd = actualEnd - arrowSpan
            return DirectedArcGeometry(
                startCanvasRad: sAng,
                endCanvasRad: actualEnd,
                bodyStartCanvasRad: sAng,
                bodyEndCanvasRad: bodyEnd,
                tipCanvasRad: actualEnd,
                midCanvasRad: midRad,
                outerShoulderRadius: rOuter + overhang,
                innerShoulderRadius: rInner - overhang,
                tipRadius: rMid,
                hasArrowhead: true,
                isClockwise: true
            )
        } else {
            let bodyStart = sAng + arrowSpan
            return DirectedArcGeometry(
                startCanvasRad: sAng,
                endCanvasRad: actualEnd,
                bodyStartCanvasRad: bodyStart,
                bodyEndCanvasRad: actualEnd,
                tipCanvasRad: sAng,
                midCanvasRad: midRad,
                outerShoulderRadius: rOuter + overhang,
                innerShoulderRadius: rInner - overhang,
                tipRadius: rMid,
                hasArrowhead: true,
                isClockwise: false
            )
        }
    }
}
