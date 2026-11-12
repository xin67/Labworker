import Foundation

// MARK: - 1. 笛卡尔与极坐标基础结构 (Ported from CloneCanvas utils/geometry.ts)

public struct CartesianPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// OVE 环形外围标签布局结构 (用于四象限松弛防碰撞与折线引线绘制)
public struct OveCircularLabel: Identifiable, Sendable {
    public let id: UUID
    public var text: String
    /// 原始极角 [0, 2π)，0 rad 为 12 点钟方向顺时针
    public var anchorAngle: Double
    /// 松弛调整后的极角 [0, 2π)
    public var angle: Double
    /// 特征外弧半径
    public var radius: Double
    public var colorHex: String
    public var isEnzyme: Bool
    public var priority: Int
    /// 引线内侧锚点（位于特征外弧表面）
    public var innerPoint: CartesianPoint
    /// 引线外侧锚点（经四象限垂直松弛防碰撞后的标签端点）
    public var outerPoint: CartesianPoint
    /// 是否位于左半圆 (π < angle < 2π)
    public var isLeftHalf: Bool
    /// 当标签密度过高合并时的子标签组
    public var sublabels: [OveCircularLabel]
    
    public init(
        id: UUID = UUID(),
        text: String,
        angle: Double,
        radius: Double,
        colorHex: String = "",
        isEnzyme: Bool = false,
        priority: Int = 5,
        innerPoint: CartesianPoint = CartesianPoint(x: 0, y: 0),
        outerPoint: CartesianPoint = CartesianPoint(x: 0, y: 0),
        isLeftHalf: Bool = false,
        sublabels: [OveCircularLabel] = []
    ) {
        let norm = CircularGeometry.normalizeAngle(angle)
        self.id = id
        self.text = text
        self.anchorAngle = norm
        self.angle = norm
        self.radius = radius
        self.colorHex = colorHex
        self.isEnzyme = isEnzyme
        self.priority = priority
        self.innerPoint = innerPoint
        self.outerPoint = outerPoint
        self.isLeftHalf = norm > Double.pi
        self.sublabels = sublabels
    }
}

// MARK: - 2. 纯数学几何与标签松弛解算器

public enum CircularGeometry {
    
    /// 将任意弧度归一化至 [0, 2π) 区间
    public static func normalizeAngle(_ radians: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        var val = radians.truncatingRemainder(dividingBy: twoPi)
        if val < 0 {
            val += twoPi
        }
        return val
    }
    
    /// 1:1 OVE 极坐标转笛卡尔坐标：0 弧度位于 12 点钟正上方，顺时针递增
    public static func polarToCartesian(
        radius: Double,
        angleRadians: Double,
        center: CartesianPoint = CartesianPoint(x: 0, y: 0)
    ) -> CartesianPoint {
        CartesianPoint(
            x: center.x + radius * cos(angleRadians - Double.pi / 2.0),
            y: center.y + radius * sin(angleRadians - Double.pi / 2.0)
        )
    }
    
    /// 笛卡尔坐标反解 12 点钟顺时针极角 [0, 2π)
    public static func cartesianToPolarAngle(
        point: CartesianPoint,
        center: CartesianPoint = CartesianPoint(x: 0, y: 0)
    ) -> Double {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let raw = atan2(dy, dx) + Double.pi / 2.0
        return normalizeAngle(raw)
    }
    
    /// 1:1 OVE 视觉文本宽度测算（合并空白符并对中文/全角字符加权）
    public static func visualTextLength(_ text: String, collapseWhiteSpace: Bool = true) -> Int {
        var displayText = text.isEmpty ? "Unlabeled" : text
        if collapseWhiteSpace {
            displayText = displayText.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
        }
        var len = displayText.count
        for scalar in displayText.unicodeScalars {
            if scalar.value > 0xFF {
                len += 1 // CJK / 双宽字符加权
            }
        }
        return len
    }
    
    /// 1:1 SnapGene / OVE 双栏垂直松弛防碰撞算法 (relaxLabelAngles)
    /// 将标签按左右两栏划分并沿垂直方向推开重叠标签，重映射外圈 X 坐标保证文字 100% 无碰撞
    public static func relaxLabelAngles(
        labels inputLabels: [OveCircularLabel],
        radius: Double,
        center: CartesianPoint,
        canvasWidth: Double,
        canvasHeight: Double,
        textVerticalOffset: Double = 14.0
    ) -> [OveCircularLabel] {
        guard !inputLabels.isEmpty else { return [] }
        let safeSpacing = max(textVerticalOffset, 12.0)
        let maxRadius = max(radius, 30.0)
        let maxLabelsPerSide = max(6, Int(floor((canvasHeight - 30.0) / safeSpacing)))
        
        var workingLabels = inputLabels.map { item -> OveCircularLabel in
            var copy = item
            copy.anchorAngle = normalizeAngle(item.anchorAngle)
            copy.angle = copy.anchorAngle
            copy.innerPoint = polarToCartesian(radius: item.radius, angleRadians: copy.anchorAngle, center: center)
            copy.outerPoint = polarToCartesian(radius: maxRadius, angleRadians: copy.anchorAngle, center: center)
            copy.isLeftHalf = copy.anchorAngle > Double.pi
            return copy
        }
        
        if workingLabels.count > maxLabelsPerSide * 2 {
            workingLabels = combineLabels(workingLabels, numberOfBuckets: max(16, maxLabelsPerSide * 2))
        }
        
        var rightSide: [OveCircularLabel] = []
        var leftSide: [OveCircularLabel] = []
        
        for label in workingLabels {
            if label.anchorAngle <= Double.pi {
                rightSide.append(label)
            } else {
                leftSide.append(label)
            }
        }
        
        // 沿 Y 轴自顶向下松弛单侧标签栏，确保每行标签有严格的 safeSpacing 间距
        func relaxColumn(_ arr: [OveCircularLabel], isLeft: Bool) -> [OveCircularLabel] {
            guard !arr.isEmpty else { return [] }
            var sorted = arr.sorted { $0.outerPoint.y < $1.outerPoint.y }
            
            // 首次自顶向下平推
            for i in 1..<sorted.count {
                if sorted[i].outerPoint.y < sorted[i - 1].outerPoint.y + safeSpacing {
                    sorted[i].outerPoint.y = sorted[i - 1].outerPoint.y + safeSpacing
                }
            }
            
            // 若底部越界，自底向上回缩
            let maxY = center.y + (canvasHeight / 2.0 - 12.0)
            if let lastY = sorted.last?.outerPoint.y, lastY > maxY {
                let overflow = lastY - maxY
                for i in 0..<sorted.count {
                    sorted[i].outerPoint.y -= overflow
                }
                for i in stride(from: sorted.count - 2, through: 0, by: -1) {
                    if sorted[i].outerPoint.y > sorted[i + 1].outerPoint.y - safeSpacing {
                        sorted[i].outerPoint.y = sorted[i + 1].outerPoint.y - safeSpacing
                    }
                }
            }
            
            // 重新解算 X 坐标：向外侧架设平整阅读架 (Shelf)，彻底避免在极轴附近向内塌陷导致重叠
            for i in 0..<sorted.count {
                let relY = sorted[i].outerPoint.y - center.y
                let rSq = maxRadius * maxRadius
                let ySq = relY * relY
                let rawArcX = rSq > ySq ? sqrt(rSq - ySq) : 0.0
                // 保底向外侧偏移至少 55% 半径，确保文本不挤在圆环垂直轴上
                let shelfX = max(rawArcX, maxRadius * 0.55) + 8.0
                let finalX = isLeft ? (center.x - shelfX) : (center.x + shelfX)
                
                sorted[i].outerPoint = CartesianPoint(x: finalX, y: sorted[i].outerPoint.y)
                sorted[i].isLeftHalf = isLeft
            }
            return sorted
        }
        
        var result: [OveCircularLabel] = []
        result.append(contentsOf: relaxColumn(rightSide, isLeft: false))
        result.append(contentsOf: relaxColumn(leftSide, isLeft: true))
        return result
    }
    
    /// 超高密度标签分桶合并 (combineLabels)
    public static func combineLabels(
        _ labels: [OveCircularLabel],
        numberOfBuckets: Int
    ) -> [OveCircularLabel] {
        let safeBuckets = max(1, numberOfBuckets)
        var buckets: [Int: OveCircularLabel] = [:]
        var orderedKeys: [Int] = []
        
        for label in labels {
            let bucket = Int(floor((CircularGeometry.normalizeAngle(label.anchorAngle) / (2.0 * Double.pi)) * Double(safeBuckets)))
            if var existing = buckets[bucket] {
                existing.sublabels.append(label)
                buckets[bucket] = existing
            } else {
                var head = label
                head.sublabels = [label]
                buckets[bucket] = head
                orderedKeys.append(bucket)
            }
        }
        return orderedKeys.compactMap { buckets[$0] }
    }
}
