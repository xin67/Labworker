import SwiftUI
import CloneStudioCore

/// 全局序列缩略导航条 (支持全质粒 1..N bp 任意位置点击跳转与按住连续滑动浏览)
public struct SequenceMinimapView: View {
    @ObservedObject private var appState = AppState.shared
    
    public let totalLengthBp: Int
    public let features: [PlasmidFeatureItem]
    public let enzymes: [PlasmidEnzymeMarker]
    public let windows: [MicroscopicSequenceWindow]
    @Binding public var selectedWindowIndex: Int
    public var viewportRangeBp: ClosedRange<Int>? = nil
    public var onNavigateToBp: ((Int) -> Void)? = nil
    
    private var isDark: Bool {
        appState.resolvedCanvasIsDark()
    }
    
    public init(
        totalLengthBp: Int,
        features: [PlasmidFeatureItem],
        enzymes: [PlasmidEnzymeMarker],
        windows: [MicroscopicSequenceWindow],
        selectedWindowIndex: Binding<Int>,
        viewportRangeBp: ClosedRange<Int>? = nil,
        onNavigateToBp: ((Int) -> Void)? = nil
    ) {
        self.totalLengthBp = max(totalLengthBp, 1)
        self.features = features
        self.enzymes = enzymes
        self.windows = windows
        self._selectedWindowIndex = selectedWindowIndex
        self.viewportRangeBp = viewportRangeBp
        self.onNavigateToBp = onNavigateToBp
    }
    
    private var resolvedViewportText: String? {
        if let vp = viewportRangeBp {
            let span = max(1, vp.upperBound - vp.lowerBound + 1)
            return L10n.tr(
                L10n.tr("当前视口: \(vp.lowerBound)..\(vp.upperBound) bp (\(span) bp)", "Viewport: \(vp.lowerBound)..\(vp.upperBound) bp (\(span) bp)"),
                "Viewport: \(vp.lowerBound)..\(vp.upperBound) bp (\(span) bp)"
            )
        }
        if windows.indices.contains(selectedWindowIndex) {
            let activeWin = windows[selectedWindowIndex]
            return L10n.tr(
                L10n.tr("当前视口: \(activeWin.startBp)..\(activeWin.endBp) bp (\(activeWin.sequence.count) bp)", "Viewport: \(activeWin.startBp)..\(activeWin.endBp) bp (\(activeWin.sequence.count) bp)"),
                "Viewport: \(activeWin.startBp)..\(activeWin.endBp) bp (\(activeWin.sequence.count) bp)"
            )
        }
        return nil
    }
    
    public var body: some View {
        let primaryText: Color = .secondary
        let accentCyan = isDark ? Color.cyan : Color(red: 0.02, green: 0.48, blue: 0.72)
        let trackFill = StudioPalette.trackBg(isLight: !isDark)
        let trackStroke = StudioPalette.cardBorder(isLight: !isDark)
        let centerLineColor = isDark ? Color.white.opacity(0.20) : Color.black.opacity(0.20)
        
        VStack(alignment: .leading, spacing: 3) {
            // 顶栏微标签：全长刻度与当前激活视口坐标
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 8.5))
                            .foregroundColor(accentCyan)
                        Text(L10n.tr(
                            L10n.tr("全长缩略导航 (1 .. \(totalLengthBp) bp · 点击或滑动跳转)", "Full-Length Minimap (1 .. \(totalLengthBp) bp · Click or drag to navigate)"),
                            "Full-Plasmid Minimap (1 .. \(totalLengthBp) bp · Click or Drag)"
                        ))
                            .font(.system(size: 9.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(primaryText)
                            .lineLimit(1)
                    }
                    
                    Spacer(minLength: 4)
                    
                    if let vpText = resolvedViewportText {
                        Text(vpText)
                            .font(.system(size: 9.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(accentCyan)
                            .lineLimit(1)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 8.5))
                            .foregroundColor(accentCyan)
                        Text(L10n.tr(
                            L10n.tr("全长导航 (1 .. \(totalLengthBp) bp)", "Full Map (1 .. \(totalLengthBp) bp)"),
                            "Minimap (1 .. \(totalLengthBp) bp)"
                        ))
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(primaryText)
                    }
                    if let vpText = resolvedViewportText {
                        Text(vpText)
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(accentCyan)
                    }
                }
            }
            
            // 24pt 缩略条画布
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let height = geo.size.height
                
                ZStack(alignment: .leading) {
                    // 1. 轨道底板
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(trackFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(trackStroke, lineWidth: 0.8)
                        )
                    
                    // 2. 质粒骨架基准中轴线
                    Path { p in
                        p.move(to: CGPoint(x: 4, y: height / 2.0))
                        p.addLine(to: CGPoint(x: width - 4, y: height / 2.0))
                    }
                    .stroke(centerLineColor, lineWidth: 1.0)
                    
                    // 3. 绘制所有 Feature 比例色块
                    ForEach(features) { feat in
                        let sRatio = min(max(feat.startRatio, 0.0), 1.0)
                        let eRatio = feat.endRatio >= feat.startRatio
                            ? min(max(feat.endRatio, 0.0), 1.0)
                            : 1.0
                        let xStart = CGFloat(sRatio) * width
                        let blockW = max(4.0, CGFloat(eRatio - sRatio) * width)
                        
                        ZStack {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(feat.color.opacity(feat.isHighlight ? 0.90 : 0.72))
                            if blockW > 38 {
                                Text(feat.name)
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 2)
                            }
                        }
                        .frame(width: blockW, height: height - 8)
                        .offset(x: xStart)
                    }
                    
                    // 4. 酶切位点竖线标记
                    ForEach(enzymes) { enz in
                        let xPos = CGFloat(min(max(enz.ratioPosition, 0.0), 1.0)) * width
                        Rectangle()
                            .fill(enz.color)
                            .frame(width: 1.5, height: height - 4)
                            .offset(x: xPos)
                    }
                    
                    // 5. 微观接头窗口虚线参考框
                    ForEach(Array(windows.enumerated()), id: \.element.id) { idx, win in
                        let sRatio = min(max(Double(win.startBp - 1) / Double(totalLengthBp), 0.0), 0.96)
                        let spanRatio = max(0.03, Double(win.sequence.count) / Double(totalLengthBp))
                        let boxX = CGFloat(sRatio) * width
                        let boxW = max(14.0, min(width - boxX, CGFloat(spanRatio) * width))
                        let isActive = (idx == selectedWindowIndex)
                        
                        RoundedRectangle(cornerRadius: 3.5)
                            .fill(isActive ? Color.purple.opacity(0.22) : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3.5)
                                    .stroke(
                                        isActive ? Color.purple : (isDark ? Color.white.opacity(0.32) : Color.black.opacity(0.25)),
                                        style: StrokeStyle(lineWidth: isActive ? 1.6 : 0.9, dash: isActive ? [] : [2, 2])
                                    )
                            )
                            .frame(width: boxW, height: height - 2)
                            .offset(x: boxX)
                    }
                    
                    // 6. 全长可滑动的实时视口滑块框 (支持拖拽与点击任意位置定位)
                    if let vp = viewportRangeBp {
                        let sRatio = min(max(Double(vp.lowerBound - 1) / Double(totalLengthBp), 0.0), 0.96)
                        let spanRatio = max(0.04, Double(vp.upperBound - vp.lowerBound + 1) / Double(totalLengthBp))
                        let boxX = CGFloat(sRatio) * width
                        let boxW = max(20.0, min(width - boxX, CGFloat(spanRatio) * width))
                        
                        RoundedRectangle(cornerRadius: 3.5)
                            .fill(accentCyan.opacity(0.26))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3.5)
                                    .stroke(accentCyan, lineWidth: 1.8)
                            )
                            .frame(width: boxW, height: height - 2)
                            .offset(x: boxX)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clickRatio = min(max(Double(value.location.x / width), 0.0), 1.0)
                            let targetBp = max(1, min(totalLengthBp, Int(round(clickRatio * Double(max(1, totalLengthBp - 1)))) + 1))
                            if let onNavigateToBp = onNavigateToBp {
                                onNavigateToBp(targetBp)
                            } else if !windows.isEmpty {
                                if let bestIdx = windows.enumerated().min(by: { a, b in
                                    let midA = (a.element.startBp + a.element.endBp) / 2
                                    let midB = (b.element.startBp + b.element.endBp) / 2
                                    return abs(midA - targetBp) < abs(midB - targetBp)
                                })?.offset {
                                    if selectedWindowIndex != bestIdx {
                                        selectedWindowIndex = bestIdx
                                    }
                                }
                            }
                        }
                )
            }
            .frame(height: 24)
        }
    }
}
