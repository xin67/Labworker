import SwiftUI
import AppKit
import CoreGraphics

/// 遵循 Apple Human Interface Guidelines 与 AppKit 标准的动态深浅色应用图标提供器
/// 采用 `NSApp.effectiveAppearance` + SwiftUI `@Environment(\.colorScheme)` 双通道零延迟触发，并强制刷新 `NSDockTile`
public enum CloneStudioIconProvider {
    private static var cachedLightIcon: NSImage?
    private static var cachedDarkIcon: NSImage?
    private static var cachedStatusBarIcon: NSImage?
    private static var lastAppliedIsLight: Bool?
    
    /// 遵循 Apple AppKit 标准判断当前是否应显示浅色样式图标（零阻塞，不调用 CFPreferencesAppSynchronize）
    @MainActor
    public static func resolveIsLightAppearance(
        mode: AppAppearanceMode,
        systemColorScheme: ColorScheme? = nil
    ) -> Bool {
        switch mode {
        case .light:
            return true
        case .dark:
            return false
        case .system:
            if let scheme = systemColorScheme {
                return scheme == .light
            }
            if let app = NSApp {
                let match = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
                return match != .darkAqua
            }
            let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? "Light"
            return style.caseInsensitiveCompare("Dark") != .orderedSame
        }
    }
    
    /// 遵循 Apple AppKit 标准即时切换应用图标（带去重保护，不调用同步 dockTile.display() 避免主线程 IPC 死锁）
    @MainActor
    public static func syncApplicationIcon(
        mode: AppAppearanceMode,
        systemColorScheme: ColorScheme? = nil,
        force: Bool = false
    ) {
        let isLight = resolveIsLightAppearance(mode: mode, systemColorScheme: systemColorScheme)
        if let last = lastAppliedIsLight, last == isLight, NSApp?.applicationIconImage != nil {
            return
        }
        lastAppliedIsLight = isLight
        
        guard let app = NSApp, app.isRunning else { return }
        let baseIcon = iconImage(isLight: isLight)
        app.applicationIconImage = baseIcon
    }
    
    /// 获取符合 Apple HIG 规范的极简双弧段质粒图标（优先读取预构建 .icns/.png，避免主线程实时光栅化卡顿）
    public static func iconImage(isLight: Bool) -> NSImage {
        if isLight, let cached = cachedLightIcon {
            return cached
        }
        if !isLight, let cached = cachedDarkIcon {
            return cached
        }
        
        let resourceNames = isLight
            ? [("AppIcon_Light", "icns"), ("AppIcon_Light_1024", "png")]
            : [("AppIcon_Dark", "icns"), ("AppIcon_Dark_1024", "png")]
        for (name, ext) in resourceNames {
            if let path = CloneStudioResourceLocator.path(forResource: name, ofType: ext),
               let diskImg = NSImage(contentsOfFile: path) {
                if isLight {
                    cachedLightIcon = diskImg
                } else {
                    cachedDarkIcon = diskImg
                }
                return diskImg
            }
        }
        
        let rendered = renderAppleHIGPlasmidIcon(pixelSize: 256, isLight: isLight)
        if isLight {
            cachedLightIcon = rendered
        } else {
            cachedDarkIcon = rendered
        }
        return rendered
    }
    
    /// 获取 macOS 状态栏专用的单色模板图标 (`isTemplate = true`，由 macOS 自动根据浅色/深色壁纸与菜单栏反色)
    public static var statusBarTemplateImage: NSImage {
        if let cached = cachedStatusBarIcon {
            return cached
        }
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            
            let size = min(rect.width, rect.height)
            let cx = rect.midX
            let cy = rect.midY
            let r = size * 0.35
            let lw = size * 0.145
            
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            
            // 载体骨架弧段 (112° -> 338°)
            ctx.addArc(
                center: CGPoint(x: cx, y: cy),
                radius: r,
                startAngle: 112.0 * .pi / 180.0,
                endAngle: 338.0 * .pi / 180.0,
                clockwise: false
            )
            ctx.strokePath()
            
            // 插入片段弧段 (16° -> 74°)
            ctx.addArc(
                center: CGPoint(x: cx, y: cy),
                radius: r,
                startAngle: 16.0 * .pi / 180.0,
                endAngle: 74.0 * .pi / 180.0,
                clockwise: false
            )
            ctx.strokePath()
            
            // 同源重组连接节点 (-3° 与 +93°)
            let dotR = size * 0.052
            ctx.setFillColor(NSColor.black.cgColor)
            for deg in [-3.0, 93.0] {
                let rad = CGFloat(deg * .pi / 180.0)
                let dx = cx + r * cos(rad)
                let dy = cy + r * sin(rad)
                ctx.fillEllipse(in: CGRect(x: dx - dotR, y: dy - dotR, width: dotR * 2, height: dotR * 2))
            }
            return true
        }
        img.isTemplate = true
        cachedStatusBarIcon = img
        return img
    }
    
    /// 严格遵循 Apple macOS Human Interface Guidelines (1024 画布内嵌 824 Squircle) 的内存级高速渲染器
    public static func renderAppleHIGPlasmidIcon(pixelSize: Int = 512, isLight: Bool) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        }
        rep.size = NSSize(width: pixelSize, height: pixelSize)
        let ctx = nsCtx.cgContext
        let size = CGFloat(pixelSize)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        
        let cx = size * 0.5
        let cy = size * 0.5
        let pad = size * (100.0 / 1024.0)
        let sqSize = size - pad * 2.0
        let cornerRadius = sqSize * 0.225
        let sqRect = CGRect(x: pad, y: pad, width: sqSize, height: sqSize)
        let sqPath = CGPath(roundedRect: sqRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        
        // 1. Apple HIG 标准投影
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * (12.0 / 1024.0)),
            blur: size * (28.0 / 1024.0),
            color: CGColor(gray: 0.0, alpha: isLight ? 0.20 : 0.42)
        )
        ctx.addPath(sqPath)
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()
        
        ctx.saveGState()
        ctx.addPath(sqPath)
        ctx.clip()
        
        // 2. 背板渐变
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bgTop = isLight
            ? CGColor(srgbRed: 0.995, green: 0.998, blue: 1.000, alpha: 1.0)
            : CGColor(srgbRed: 0.105, green: 0.148, blue: 0.245, alpha: 1.0)
        let bgBot = isLight
            ? CGColor(srgbRed: 0.898, green: 0.935, blue: 0.985, alpha: 1.0)
            : CGColor(srgbRed: 0.045, green: 0.065, blue: 0.122, alpha: 1.0)
        if let grad = CGGradient(colorsSpace: colorSpace, colors: [bgTop, bgBot] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: cx, y: size - pad), end: CGPoint(x: cx, y: pad), options: [])
        }
        
        // 3. 中心柔光晕
        let glowCenter = isLight
            ? CGColor(srgbRed: 0.14, green: 0.58, blue: 0.96, alpha: 0.12)
            : CGColor(srgbRed: 0.18, green: 0.72, blue: 0.98, alpha: 0.22)
        let glowEdge = CGColor(srgbRed: 0.14, green: 0.58, blue: 0.96, alpha: 0.0)
        if let radGrad = CGGradient(colorsSpace: colorSpace, colors: [glowCenter, glowEdge] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(radGrad, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: size * 0.34, options: [])
        }
        
        // 4. 环形底轨
        let ringRadius = size * 0.245
        let ringWidth = size * 0.074
        ctx.saveGState()
        ctx.addArc(center: CGPoint(x: cx, y: cy), radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.setLineWidth(size * 0.014)
        ctx.setStrokeColor(
            isLight
                ? CGColor(srgbRed: 0.15, green: 0.35, blue: 0.72, alpha: 0.10)
                : CGColor(srgbRed: 0.58, green: 0.78, blue: 1.00, alpha: 0.12)
        )
        ctx.strokePath()
        ctx.restoreGState()
        
        func drawArc(startDeg: CGFloat, endDeg: CGFloat, c1: CGColor, c2: CGColor) {
            let sRad = startDeg * .pi / 180.0
            let eRad = endDeg * .pi / 180.0
            
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: -size * 0.011),
                blur: size * 0.020,
                color: CGColor(gray: 0.0, alpha: isLight ? 0.16 : 0.45)
            )
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: ringRadius, startAngle: sRad, endAngle: eRad, clockwise: false)
            ctx.setLineWidth(ringWidth)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(c1)
            ctx.strokePath()
            ctx.restoreGState()
            
            ctx.saveGState()
            ctx.addArc(center: CGPoint(x: cx, y: cy), radius: ringRadius, startAngle: sRad, endAngle: eRad, clockwise: false)
            ctx.setLineWidth(ringWidth)
            ctx.setLineCap(.round)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            
            let pStart = CGPoint(x: cx + ringRadius * cos(sRad), y: cy + ringRadius * sin(sRad))
            let pEnd = CGPoint(x: cx + ringRadius * cos(eRad), y: cy + ringRadius * sin(eRad))
            if let arcGrad = CGGradient(colorsSpace: colorSpace, colors: [c1, c2] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(arcGrad, start: pStart, end: pEnd, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }
        
        // 5. 载体骨架弧 + 重组插入弧
        let bbC1 = isLight ? CGColor(srgbRed: 0.11, green: 0.39, blue: 0.95, alpha: 1.0) : CGColor(srgbRed: 0.22, green: 0.52, blue: 0.98, alpha: 1.0)
        let bbC2 = isLight ? CGColor(srgbRed: 0.05, green: 0.65, blue: 0.91, alpha: 1.0) : CGColor(srgbRed: 0.22, green: 0.78, blue: 0.98, alpha: 1.0)
        drawArc(startDeg: 108, endDeg: 342, c1: bbC1, c2: bbC2)
        
        let insC1 = isLight ? CGColor(srgbRed: 0.06, green: 0.73, blue: 0.51, alpha: 1.0) : CGColor(srgbRed: 0.20, green: 0.85, blue: 0.62, alpha: 1.0)
        let insC2 = isLight ? CGColor(srgbRed: 0.02, green: 0.59, blue: 0.41, alpha: 1.0) : CGColor(srgbRed: 0.06, green: 0.72, blue: 0.50, alpha: 1.0)
        drawArc(startDeg: 12, endDeg: 78, c1: insC1, c2: insC2)
        
        // 6. 同源臂连接圆点
        let dotR = size * 0.015
        for deg in [-3.0, 93.0] {
            let rad = CGFloat(deg * .pi / 180.0)
            let dx = cx + ringRadius * cos(rad)
            let dy = cy + ringRadius * sin(rad)
            ctx.setFillColor(
                isLight
                    ? CGColor(srgbRed: 0.08, green: 0.62, blue: 0.88, alpha: 0.95)
                    : CGColor(srgbRed: 0.35, green: 0.85, blue: 0.98, alpha: 0.95)
            )
            ctx.fillEllipse(in: CGRect(x: dx - dotR, y: dy - dotR, width: dotR * 2, height: dotR * 2))
        }
        
        // 7. Apple HIG 高光内边框
        let insetRect = sqRect.insetBy(dx: size * 0.002, dy: size * 0.002)
        let rimPath = CGPath(roundedRect: insetRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.addPath(rimPath)
        ctx.setLineWidth(size * 0.004)
        ctx.setStrokeColor(
            isLight
                ? CGColor(srgbRed: 0.62, green: 0.71, blue: 0.84, alpha: 0.52)
                : CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.16)
        )
        ctx.strokePath()
        ctx.restoreGState()
        
        let outImage = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        outImage.addRepresentation(rep)
        return outImage
    }
}

/// 自适应深浅色模式的 CloneStudio 图标组件（用于侧边栏顶部、设置面板预览与状态栏弹窗）
public struct AdaptiveCloneStudioAppIconView: View {
    @ObservedObject private var appState = AppState.shared
    public var size: CGFloat = 24
    
    public init(size: CGFloat = 24) {
        self.size = size
    }
    
    public var body: some View {
        Image(nsImage: CloneStudioIconProvider.iconImage(isLight: appState.isLightAppearance))
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: size, height: size)
    }
}

/// macOS 右上角系统状态栏极简快捷工作台视图 (`NSStatusItem` Popover)
/// 遵循「已在设置面板中的功能不再重复堆叠」原则，仅保留高频「序列随手算」「核心工作台直达」「Finder 智能快导」
public struct CloneStudioStatusBarPopoverView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var quickSequence: String = ""
    @State private var copiedFeedback: String? = nil
    public var onImportFromFinder: (() -> Void)?
    
    public init(onImportFromFinder: (() -> Void)? = nil) {
        self.onImportFromFinder = onImportFromFinder
    }
    
    private var cleanedSeq: String {
        BioSequence.clean(quickSequence)
    }
    
    private var quickTm: Double {
        guard !cleanedSeq.isEmpty else { return 0 }
        return TmCalculator.calculate(sequence: cleanedSeq).tm
    }
    
    private var quickGC: Double {
        guard !cleanedSeq.isEmpty else { return 0 }
        return BioSequence.gcContent(cleanedSeq)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. 极简品牌顶栏 + Finder 智能快导入口
            HStack(spacing: 9) {
                AdaptiveCloneStudioAppIconView(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Labworker")
                        .font(.system(size: 13.5, weight: .bold))
                    Text("实验随手算与工作台直达")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                Button(action: {
                    activateMainWindow()
                    onImportFromFinder?()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.plus")
                        Text("导入文件")
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .help("从 Finder 导入 .dna / .tif / .pdb / .nwk / .csv / .fasta 并自动直达对应模块")
            }
            
            Divider().opacity(0.5)
            
            // 2. 状态栏随手算：引物/序列 Tm、GC% 与反向互补
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("序列随手算 (Tm / GC / 反向互补)", systemImage: "function")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            Button("粘贴") {
                                if let str = NSPasteboard.general.string(forType: .string) {
                                    quickSequence = BioSequence.clean(str)
                                }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                            
                            if !quickSequence.isEmpty {
                                Button("清空") {
                                    quickSequence = ""
                                }
                                .buttonStyle(.glass)
                                .controlSize(.mini)
                            }
                        }
                    }
                }
                
                TextField("粘贴引物或 DNA 序列即刻计算...", text: $quickSequence)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                
                HStack(spacing: 7) {
                    statusMetricPill(label: "长度", value: "\(cleanedSeq.count)bp", tint: .blue)
                    statusMetricPill(
                        label: "GC",
                        value: cleanedSeq.isEmpty ? "--" : String(format: "%.0f%%", quickGC),
                        tint: .teal
                    )
                    statusMetricPill(
                        label: "Tm",
                        value: cleanedSeq.isEmpty ? "--" : String(format: "%.1f℃", quickTm),
                        tint: .orange
                    )
                    Spacer()
                    Button(action: {
                        guard !cleanedSeq.isEmpty else { return }
                        let rc = BioSequence.reverseComplement(cleanedSeq)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(rc, forType: .string)
                        copiedFeedback = "已复制"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedFeedback = nil
                        }
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: copiedFeedback != nil ? "checkmark" : "arrow.left.arrow.right")
                            Text(copiedFeedback ?? "反向互补")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.mini)
                    .disabled(cleanedSeq.isEmpty)
                }
            }
            .padding(9)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            
            // 3. 高频工作台直达（语义化图标，去除旧数字编号）
            GlassEffectContainer(spacing: 6) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    quickModuleButton(.plasmidPool, title: "质粒池", icon: "tray.2.fill", tint: .cyan)
                    quickModuleButton(.singleFragment, title: "单片段", icon: "scissors", tint: .teal)
                    quickModuleButton(.mutagenesis, title: "定点突变", icon: "wand.and.stars", tint: .pink)
                    quickModuleButton(.westernBlot, title: "WB定量", icon: "slider.horizontal.below.rectangle", tint: .indigo)
                    quickModuleButton(.qpcrAnalysis, title: "qPCR", icon: "chart.bar.xaxis", tint: .teal)
                    quickModuleButton(.gelFigure, title: "凝胶电泳", icon: "chart.bar.doc.horizontal.fill", tint: .cyan)
                    quickModuleButton(.proteinWorkbench, title: "蛋白质台", icon: "atom", tint: .blue)
                    quickModuleButton(
                        .orderCenter,
                        title: appState.primersCart.isEmpty ? "订购单" : "订购(\(appState.primersCart.count))",
                        icon: "cart.fill",
                        tint: .green
                    )
                }
            }
            
            Divider().opacity(0.5)
            
            // 4. 极简底栏：主窗口、系统设置、退出
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: {
                        activateMainWindow()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "macwindow")
                            Text("主窗口")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    
                    Button(action: {
                        appState.selectedNav = .settings
                        activateMainWindow()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape")
                            Text("设置")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    
                    Spacer()
                    
                    Button(action: {
                        NSApplication.shared.terminate(nil)
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "power")
                            Text("退出")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("退出 Labworker (⌘Q)")
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }
    
    private func statusMetricPill(label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .bold))
                .monospacedDigit()
                .foregroundColor(tint)
        }
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2.5)
        .glassEffect(.clear.tint(tint.opacity(0.24)), in: .capsule)
    }
    
    private func quickModuleButton(_ nav: NavItem, title: String, icon: String, tint: Color) -> some View {
        let isSelected = (appState.selectedNav == nav)
        return Button(action: {
            appState.selectedNav = nav
            activateMainWindow()
        }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isSelected ? .white : tint)
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .glassEffect(
                isSelected
                    ? .regular.tint(tint.opacity(0.82)).interactive()
                    : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
    
    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
