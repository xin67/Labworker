import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

// MARK: - 00. 全局统一三层连续圆角规范 (macOS 26/27 Liquid Glass Hierarchy)
public enum StudioRadius {
    /// Level 1：主浮层面板、模块卡片 (`StudioCard`)
    public static let card: CGFloat = 16
    /// Level 3：卡片内部嵌套数据行、代码/序列编辑器 (`SequenceEditorBox`)
    public static let inner: CGFloat = 10
}

// MARK: - 0. 原生 macOS 毛玻璃高斯模糊视图 (NSVisualEffectView 封装)
public struct VisualEffectBlurView: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    public var state: NSVisualEffectView.State
    
    public init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }
    
    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        return view
    }
    
    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material { nsView.material = material }
        if nsView.blendingMode != blendingMode { nsView.blendingMode = blendingMode }
        if nsView.state != state { nsView.state = state }
    }
}

// MARK: - 0B. 图2风格层次化分段胶囊按钮组与全宽/双列胶囊按钮 (Inspector Pill Hierarchy)

/// 单个胶囊内嵌按钮项（用于 `StudioSegmentedPillGroup` 内部，自带竖向分割线）
public struct StudioPillGroupItem: Identifiable {
    public let id: String
    public let title: String
    public let icon: String?
    public let tint: Color?
    public let isDisabled: Bool
    public let help: String?
    public let action: () -> Void
    
    public init(
        id: String? = nil,
        title: String,
        icon: String? = nil,
        tint: Color? = nil,
        isDisabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id ?? title
        self.title = title
        self.icon = icon
        self.tint = tint
        self.isDisabled = isDisabled
        self.help = help
        self.action = action
    }
}

/// 连体分段胶囊按钮组（统一 Capsule 形状 + 内部竖向 1px 分割线，macOS 26/27 原生 Liquid Glass）
public struct StudioSegmentedPillGroup: View {
    @ObservedObject private var appState = AppState.shared
    public let items: [StudioPillGroupItem]
    public var expandEqually: Bool = false
    
    public init(items: [StudioPillGroupItem], expandEqually: Bool = false) {
        self.items = items
        self.expandEqually = expandEqually
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: 1, height: 15)
                }
                
                Button(action: item.action) {
                    HStack(spacing: 4) {
                        if let icon = item.icon, !icon.isEmpty {
                            Image(systemName: icon)
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        if !item.title.isEmpty {
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                    .foregroundColor(
                        item.isDisabled
                            ? .secondary.opacity(0.45)
                            : (item.tint ?? .primary)
                    )
                    .padding(.horizontal, item.title.isEmpty ? 10 : 11)
                    .frame(height: 28)
                    .frame(maxWidth: expandEqually ? .infinity : nil)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.isDisabled)
                .help(item.help ?? item.title)
            }
        }
        .glassEffect(
            appState.liquidGlassStyle.resolvedGlass(accentColor: appState.accentTheme.color, interactive: true),
            in: Capsule(style: .continuous)
        )
    }
}

/// 独立饱满胶囊按钮（统一 Capsule 形状，支持图标纯享、工具栏内联或通栏操作，macOS 26/27 原生 Liquid Glass）
public struct StudioActionPillButton: View {
    @ObservedObject private var appState = AppState.shared
    public let title: String
    public var icon: String? = nil
    public var tint: Color? = nil
    public var isProminent: Bool = false
    public var fillWidth: Bool = false
    public var isDisabled: Bool = false
    public var help: String? = nil
    public let action: () -> Void
    
    public init(
        title: String,
        icon: String? = nil,
        tint: Color? = nil,
        isProminent: Bool = false,
        fillWidth: Bool = false,
        isDisabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.isProminent = isProminent
        self.fillWidth = fillWidth
        self.isDisabled = isDisabled
        self.help = help
        self.action = action
    }
    
    public var body: some View {
        let resolvedTint = tint ?? appState.accentTheme.color
        let isIconOnly = title.isEmpty && (icon?.isEmpty == false)
        let buttonGlass: Glass = {
            if isDisabled {
                return appState.liquidGlassStyle.resolvedGlass(accentColor: resolvedTint, interactive: false)
            } else if isProminent {
                return .regular.tint(resolvedTint.opacity(0.82)).interactive()
            } else if let customTint = tint {
                return .regular.tint(customTint.opacity(0.22)).interactive()
            } else {
                return appState.liquidGlassStyle.resolvedGlass(accentColor: resolvedTint, interactive: true)
            }
        }()
        let btn = Button(action: action) {
            HStack(spacing: isIconOnly ? 0 : 5) {
                if let icon = icon, !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundColor(
                isDisabled
                    ? .secondary.opacity(0.45)
                    : (isProminent ? .white : (tint ?? .primary))
            )
            .padding(.horizontal, isIconOnly ? 0 : 12)
            .frame(minWidth: isIconOnly ? 28 : nil, maxWidth: fillWidth ? .infinity : nil)
            .frame(height: 28)
            .glassEffect(
                buttonGlass,
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        
        if let helpText = help, !helpText.isEmpty {
            btn.help(helpText)
        } else {
            btn
        }
    }
}

// MARK: - 1. 页面吸顶导航栏与滚动容器 (参考图1默认平铺无框 + 图2向上滚动自动毛玻璃吸顶与1px底部分割线)

private struct StudioScrollContentTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 10000
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 全局标准页面滚动容器：默认状态如系统设置图1（无框平铺、零顶部遮挡），滚动状态如系统设置图2（自动浮现毛玻璃底板与1px底部分割线，内容从下方平滑穿过）
public struct StudioPageLayout<TrailingContent: View, BodyContent: View>: View {
    @ObservedObject private var appState = AppState.shared
    public let title: String
    public let trailingContent: TrailingContent
    public let bodyContent: BodyContent
    
    @State private var isScrolled: Bool = false
    
    public init(
        title: String,
        @ViewBuilder trailing: () -> TrailingContent,
        @ViewBuilder content: () -> BodyContent
    ) {
        self.title = title
        self.trailingContent = trailing()
        self.bodyContent = content()
    }
    
    private var workspaceBackgroundColor: Color {
        appState.isLightAppearance
            ? Color(red: 0.957, green: 0.960, blue: 0.969)
            : Color(red: 0.118, green: 0.122, blue: 0.135)
    }
    
    private var subtleHairlineColor: Color {
        appState.isLightAppearance
            ? Color.black.opacity(0.09)
            : Color.white.opacity(0.11)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(title)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        
                        Spacer(minLength: 8)
                        
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                trailingContent
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                trailingContent
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 10)
                
                Rectangle()
                    .fill(isScrolled ? subtleHairlineColor : Color.clear)
                    .frame(height: 1)
            }
            .background {
                Color.clear
                    .glassEffect(
                        isScrolled
                            ? appState.liquidGlassStyle.resolvedGlass(accentColor: appState.accentTheme.color)
                            : .identity,
                        in: Rectangle()
                    )
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: StudioScrollContentTopKey.self,
                            value: geo.frame(in: .named("StudioPageScroll")).minY
                        )
                    }
                    .frame(height: 0)
                    
                    bodyContent
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
            .coordinateSpace(name: "StudioPageScroll")
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onPreferenceChange(StudioScrollContentTopKey.self) { contentTopY in
                let scrolledNow = contentTopY < -4.0
                if scrolledNow != isScrolled {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isScrolled = scrolledNow
                    }
                }
            }
        }
    }
}

extension StudioPageLayout where TrailingContent == EmptyView {
    public init(
        title: String,
        @ViewBuilder content: () -> BodyContent
    ) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

public struct StudioPageHeader<TrailingContent: View>: View {
    public let title: String
    public let trailingContent: TrailingContent
    
    public init(
        title: String,
        @ViewBuilder trailing: () -> TrailingContent
    ) {
        self.title = title
        self.trailingContent = trailing()
    }
    
    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            
            Spacer(minLength: 8)
            
            trailingContent
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }
}

extension StudioPageHeader where TrailingContent == EmptyView {
    public init(title: String) {
        self.init(title: title) {
            EmptyView()
        }
    }
}

// MARK: - 2. 现代卡片容器 (参考图2：清晰分区标题 + 柔和分割线 + 充足内边距)
public struct StudioCard<HeaderTrailing: View, Content: View>: View {
    @ObservedObject private var appState = AppState.shared
    public let title: String
    public let headerTrailing: HeaderTrailing
    public let content: Content
    
    public init(
        title: String,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.headerTrailing = headerTrailing()
        self.content = content()
    }
    
    private var cardFillColor: Color {
        appState.isLightAppearance
            ? Color.white
            : Color(red: 0.155, green: 0.162, blue: 0.185)
    }
    
    private var cardFillOpacity: Double {
        if appState.liquidGlassStyle == .clear {
            return appState.isLightAppearance ? 0.34 : 0.30
        }
        return appState.isLightAppearance ? 0.56 : 0.48
    }

    public var body: some View {
        let cardShape = RoundedRectangle(cornerRadius: StudioRadius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 11) {
            if !title.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        
                        Spacer(minLength: 6)
                        
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                headerTrailing
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) {
                                headerTrailing
                            }
                        }
                    }
                }
                
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
            }
            
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            cardShape
                .fill(cardFillColor.opacity(cardFillOpacity))
                .glassEffect(
                    appState.liquidGlassStyle.resolvedGlass(accentColor: appState.accentTheme.color),
                    in: cardShape
                )
        }
        .overlay(
            cardShape
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(appState.isLightAppearance ? 0.65 : 0.24),
                            appState.accentTheme.color.opacity(0.18),
                            Color.primary.opacity(appState.isLightAppearance ? 0.06 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(appState.isLightAppearance ? 0.05 : 0.14), radius: 6, x: 0, y: 2)
    }
}

extension StudioCard where HeaderTrailing == EmptyView {
    public init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            headerTrailing: { EmptyView() },
            content: content
        )
    }
}

// MARK: - 3. 图2风格分段胶囊选择器 (StudioSegmentedPicker)
public struct StudioSegmentedOption<T: Hashable>: Identifiable {
    public var id: T { value }
    public let value: T
    public let title: String
    public let tint: Color
    
    public init(value: T, title: String, tint: Color = .blue) {
        self.value = value
        self.title = title
        self.tint = tint
    }
}

public struct StudioSegmentedPicker<T: Hashable>: View {
    @ObservedObject private var appState = AppState.shared
    @Namespace private var pickerGlassNS
    @Binding public var selection: T
    public let options: [StudioSegmentedOption<T>]
    
    public init(selection: Binding<T>, options: [StudioSegmentedOption<T>]) {
        self._selection = selection
        self.options = options
    }
    
    public var body: some View {
        GlassEffectContainer(spacing: 4) {
            StudioFlowLayout(horizontalSpacing: 3, verticalSpacing: 4) {
                ForEach(options) { opt in
                    let isSelected = (selection == opt.value)
                    Button(action: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            selection = opt.value
                        }
                    }) {
                        Text(opt.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 11)
                            .frame(height: 24)
                            .foregroundColor(isSelected ? .white : .primary.opacity(0.88))
                            .modifier(
                                SegmentedPillGlassModifier(
                                    isSelected: isSelected,
                                    tint: opt.tint,
                                    namespace: pickerGlassNS
                                )
                            )
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(2)
        .glassEffect(
            appState.liquidGlassStyle.resolvedGlass(accentColor: appState.accentTheme.color),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

private struct SegmentedPillGlassModifier: ViewModifier {
    let isSelected: Bool
    let tint: Color
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content
                .glassEffect(
                    .regular.tint(tint.opacity(0.85)).interactive(),
                    in: Capsule(style: .continuous)
                )
                .glassEffectID("seg_active", in: namespace)
        } else {
            content
        }
    }
}

// MARK: - 4. 物种切换胶囊 (SpeciesSwitchBar)
public struct SpeciesSwitchBar: View {
    @ObservedObject private var appState = AppState.shared
    @Namespace private var speciesGlassNS
    @Binding public var species: TargetSpecies
    public var onChanged: (() -> Void)? = nil
    
    public init(species: Binding<TargetSpecies>, onChanged: (() -> Void)? = nil) {
        self._species = species
        self.onChanged = onChanged
    }
    
    public var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 3) {
                ForEach(TargetSpecies.allCases) { spec in
                    let isSelected = (species == spec)
                    let color: Color = (spec == .human) ? .blue : .orange
                    Button(action: {
                        if species != spec {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                species = spec
                            }
                            onChanged?()
                        }
                    }) {
                        Text(spec == .human ? "人源 (hg38)" : "鼠源 (mm39)")
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .padding(.horizontal, 11)
                            .frame(height: 24)
                            .foregroundColor(isSelected ? .white : .primary.opacity(0.85))
                            .modifier(
                                SegmentedPillGlassModifier(
                                    isSelected: isSelected,
                                    tint: color,
                                    namespace: speciesGlassNS
                                )
                            )
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(2)
        .glassEffect(
            appState.liquidGlassStyle.resolvedGlass(accentColor: appState.accentTheme.color),
            in: Capsule(style: .continuous)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - 5. 参数微徽章 (放大字号至 12pt，清晰易读)
public struct StudioMetricBadge: View {
    public let label: String
    public let value: String
    public let color: Color
    
    public init(label: String, value: String, color: Color = .blue) {
        self.label = label
        self.value = value
        self.color = color
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8.5)
        .padding(.vertical, 3.5)
        .glassEffect(.clear.tint(color.opacity(0.28)), in: .capsule)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - 6. 序列编辑器 (13pt 等宽大字号 + 图2风格内嵌粘贴/导入连体胶囊按钮)
public struct SequenceEditorBox: View {
    @Binding public var text: String
    public let placeholder: String
    public var minHeight: CGFloat = 84
    public var onDropDNAFile: ((URL) -> Void)? = nil
    
    @State private var isDropTargeted: Bool = false
    
    public init(
        text: Binding<String>,
        placeholder: String,
        minHeight: CGFloat = 84,
        onDropDNAFile: ((URL) -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
        self.onDropDNAFile = onDropDNAFile
    }
    
    public var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: minHeight)
                .background(Color(NSColor.textBackgroundColor).opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                        .stroke(
                            isDropTargeted ? Color.accentColor : Color.primary.opacity(0.14),
                            style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: isDropTargeted ? [5, 3] : [])
                        )
                )
            
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 8) {
                    Text(placeholder)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary.opacity(0.60))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                    
                    Spacer()
                    
                    StudioSegmentedPillGroup(items: [
                        StudioPillGroupItem(title: "粘贴", icon: "doc.on.clipboard") {
                            if let str = NSPasteboard.general.string(forType: .string) {
                                let cleaned = BioSequence.clean(str)
                                if !cleaned.isEmpty {
                                    text = cleaned
                                }
                            }
                        },
                        StudioPillGroupItem(title: "导入", icon: "folder") {
                            FinderFileDropHelper.presentOpenPanel { url in
                                if let customHandler = onDropDNAFile, url.pathExtension.lowercased() == "dna" {
                                    customHandler(url)
                                } else {
                                    Task { @MainActor in
                                        await FinderFileDropHelper.loadSequence(from: url) { extractedSeq, fileName in
                                            self.text = extractedSeq
                                            AppState.shared.showToast("已导入 \(fileName) (\(BioSequence.clean(extractedSeq).count) bp)")
                                        }
                                    }
                                }
                            }
                        }
                    ])
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            
            if isDropTargeted {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill.badge.plus")
                        .foregroundColor(.accentColor)
                    Text("松开导入序列或 .dna 质粒")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
                .clipShape(Capsule(style: .continuous))
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            FinderFileDropHelper.extractFirstFileURL(from: providers) { url in
                if let customHandler = onDropDNAFile, url.pathExtension.lowercased() == "dna" {
                    customHandler(url)
                } else {
                    Task { @MainActor in
                        await FinderFileDropHelper.loadSequence(from: url) { extractedSeq, fileName in
                            self.text = extractedSeq
                            AppState.shared.showToast("已导入 \(fileName) (\(BioSequence.clean(extractedSeq).count) bp)")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 7. 纯声明式流式自动换行布局 (StudioFlowLayout) 与精确双列响应式布局 (AdaptiveTwoColumnWorkspace)

/// 原生 SwiftUI `Layout` 协议实现的自适应流式自动换行容器：当窗口或父卡片变窄时自动将内部徽章/胶囊按钮折行，彻底消除横向溢出与截断
public struct StudioFlowLayout: Layout {
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat
    
    public init(horizontalSpacing: CGFloat = 6, verticalSpacing: CGFloat = 6) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }
    
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        return result.totalSize
    }
    
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(maxWidth: bounds.width > 0 ? bounds.width : (proposal.width ?? .infinity), subviews: subviews)
        for (index, subview) in subviews.enumerated() where index < result.frames.count {
            let frame = result.frames[index]
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
    
    private struct FlowResult {
        var frames: [CGRect]
        var totalSize: CGSize
    }
    
    private func computeLayout(maxWidth: CGFloat, subviews: Subviews) -> FlowResult {
        guard !subviews.isEmpty else {
            return FlowResult(frames: [], totalSize: .zero)
        }
        let effectiveMaxW = maxWidth.isFinite && maxWidth > 20 ? maxWidth : 10000
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        
        for subview in subviews {
            let idealSize = subview.sizeThatFits(.unspecified)
            let itemW = min(idealSize.width, effectiveMaxW)
            let itemSize = itemW < idealSize.width
                ? subview.sizeThatFits(ProposedViewSize(width: effectiveMaxW, height: nil))
                : idealSize
            
            if currentX > 0 && (currentX + itemSize.width > effectiveMaxW + 0.5) {
                maxRowWidth = max(maxRowWidth, currentX - horizontalSpacing)
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            
            let rect = CGRect(x: currentX, y: currentY, width: min(itemSize.width, effectiveMaxW), height: itemSize.height)
            frames.append(rect)
            
            currentX += rect.width + horizontalSpacing
            rowHeight = max(rowHeight, rect.height)
        }
        
        maxRowWidth = max(maxRowWidth, max(0, currentX - horizontalSpacing))
        let finalWidth = maxWidth.isFinite ? min(maxRowWidth, maxWidth) : maxRowWidth
        let finalHeight = currentY + rowHeight
        return FlowResult(frames: frames, totalSize: CGSize(width: finalWidth, height: finalHeight))
    }
}

/// 原生 SwiftUI `Layout` 协议实现的精确双列/单列响应式工作台：向左右两栏直接施加精确列宽提案，彻底杜绝子视图 `.fixedSize()` 撑破外层卡片
public struct StudioResponsiveSplitLayout: Layout {
    public var breakpoint: CGFloat
    public var spacing: CGFloat
    public var leftRatio: CGFloat
    
    public init(breakpoint: CGFloat = 820, spacing: CGFloat = 14, leftRatio: CGFloat = 0.50) {
        self.breakpoint = breakpoint
        self.spacing = spacing
        self.leftRatio = leftRatio
    }
    
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let totalW = proposal.width ?? 960
        
        if subviews.count >= 2 && totalW >= breakpoint {
            let avail = max(200, totalW - spacing)
            let leftW = floor(avail * leftRatio)
            let rightW = avail - leftW
            let leftSize = subviews[0].sizeThatFits(ProposedViewSize(width: leftW, height: nil))
            let rightSize = subviews[1].sizeThatFits(ProposedViewSize(width: rightW, height: nil))
            return CGSize(width: totalW, height: max(leftSize.height, rightSize.height))
        } else {
            var totalH: CGFloat = 0
            for (idx, subview) in subviews.enumerated() {
                if idx > 0 { totalH += spacing }
                let sz = subview.sizeThatFits(ProposedViewSize(width: totalW, height: nil))
                totalH += sz.height
            }
            return CGSize(width: totalW, height: totalH)
        }
    }
    
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let totalW = bounds.width > 0 ? bounds.width : (proposal.width ?? 960)
        
        if subviews.count >= 2 && totalW >= breakpoint {
            let avail = max(200, totalW - spacing)
            let leftW = floor(avail * leftRatio)
            let rightW = avail - leftW
            let leftSize = subviews[0].sizeThatFits(ProposedViewSize(width: leftW, height: nil))
            let rightSize = subviews[1].sizeThatFits(ProposedViewSize(width: rightW, height: nil))
            
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: leftW, height: leftSize.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + leftW + spacing, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: rightW, height: rightSize.height)
            )
        } else {
            var curY = bounds.minY
            for subview in subviews {
                let sz = subview.sizeThatFits(ProposedViewSize(width: totalW, height: nil))
                subview.place(
                    at: CGPoint(x: bounds.minX, y: curY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: totalW, height: sz.height)
                )
                curY += sz.height + spacing
            }
        }
    }
}

public struct AdaptiveTwoColumnWorkspace<Left: View, Right: View>: View {
    public let minDualColumnWidth: CGFloat
    public let hasRight: Bool
    public let left: Left
    public let right: Right
    @ObservedObject private var appState = AppState.shared
    
    public init(
        breakpoint: CGFloat = 780,
        hasRight: Bool = true,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        self.minDualColumnWidth = breakpoint
        self.hasRight = hasRight
        self.left = left()
        self.right = right()
    }
    
    public init(
        breakpoint: CGFloat = 780,
        @ViewBuilder left: () -> Left
    ) where Right == EmptyView {
        self.minDualColumnWidth = breakpoint
        self.hasRight = false
        self.left = left()
        self.right = EmptyView()
    }
    
    public var body: some View {
        Group {
            if hasRight {
                if appState.isPreviewExpanded {
                    right
                        .frame(maxWidth: .infinity)
                } else {
                    StudioResponsiveSplitLayout(breakpoint: minDualColumnWidth, spacing: 14, leftRatio: 0.50) {
                        left
                        right
                    }
                }
            } else {
                left
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 8. 质粒预览开关 (统一 28pt 胶囊)
public struct PlasmidPreviewToggle: View {
    @ObservedObject private var appState = AppState.shared
    @Binding public var isOn: Bool
    public let isAvailable: Bool
    
    public init(isOn: Binding<Bool>, isAvailable: Bool = true) {
        self._isOn = isOn
        self.isAvailable = isAvailable
    }
    
    public var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                isOn.toggle()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: (isOn && isAvailable) ? "circle.circle.fill" : "circle.circle")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor((isOn && isAvailable) ? .cyan : (isAvailable ? .primary : .secondary))
                
                Text("图谱")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor((isOn && isAvailable) ? .primary : .secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .glassEffect(
                (isOn && isAvailable)
                    ? .regular.tint(Color.cyan.opacity(0.26)).interactive()
                    : appState.liquidGlassStyle.resolvedGlass(accentColor: appState.accentTheme.color, interactive: true),
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 1.0 : 0.78)
        .help("切换质粒图谱预览抽屉")
    }
}

// MARK: - 9. 模块分区清除按钮 (28×28 圆形图标胶囊 + 悬停 Tooltip)
public struct StudioSectionClearButton: View {
    @ObservedObject private var appState = AppState.shared
    public let title: String
    public let isDisabled: Bool
    public let action: () -> Void
    
    public init(
        title: String = "清除",
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isDisabled = isDisabled
        self.action = action
    }
    
    public init(
        label: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = label
        self.isDisabled = isDisabled
        self.action = action
    }
    
    private var isResetIcon: Bool {
        title.contains("重置")
    }
    
    public var body: some View {
        Button(action: action) {
            Image(systemName: isResetIcon ? "arrow.counterclockwise" : "trash")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isDisabled ? .secondary.opacity(0.40) : .red.opacity(0.90))
                .frame(width: 28, height: 28)
                .glassEffect(
                    isDisabled
                        ? appState.liquidGlassStyle.resolvedGlass(accentColor: .red, interactive: false)
                        : .regular.tint(Color.red.opacity(0.18)).interactive(),
                    in: Capsule(style: .continuous)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
    }
}

// MARK: - 10. Finder 快捷交互组件 (28×28 圆形图标胶囊 + Tooltip)
public struct FinderRevealButton: View {
    @ObservedObject private var appState = AppState.shared
    public let filePath: String
    public var label: String = "Finder"
    
    public init(filePath: String, label: String = "Finder") {
        self.filePath = filePath
        self.label = label
    }
    
    public var body: some View {
        let iconOnly = label.isEmpty || label == "Finder"
        Button(action: {
            FinderFileDropHelper.revealInFinder(path: filePath)
        }) {
            HStack(spacing: iconOnly ? 0 : 4) {
                Image(systemName: "folder")
                    .font(.system(size: 11.5, weight: .semibold))
                if !iconOnly {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, iconOnly ? 0 : 10)
            .frame(minWidth: iconOnly ? 28 : nil)
            .frame(height: 28)
            .glassEffect(
                appState.liquidGlassStyle.resolvedGlass(accentColor: appState.accentTheme.color, interactive: true),
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("在 Finder 中定位: \(filePath)")
    }
}

// MARK: - 10B. 高辨识度主操作按钮 (34pt 全胶囊主按钮，macOS 26/27 原生 Liquid Glass)
public struct StudioPrimaryActionButton: View {
    public let title: String
    public var icon: String = "sparkles"
    public var tint: Color = .blue
    public var isLoading: Bool = false
    public var isDisabled: Bool = false
    public var fillWidth: Bool = false
    public let action: () -> Void
    
    @State private var isHovered: Bool = false
    
    public init(
        title: String,
        icon: String = "sparkles",
        tint: Color = .blue,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        fillWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.fillWidth = fillWidth
        self.action = action
    }
    
    public var body: some View {
        let inactive = isDisabled || isLoading
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .glassEffect(
                .regular.tint(tint.opacity(isDisabled ? 0.25 : (isHovered ? 0.90 : 0.82))).interactive(!inactive),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDisabled ? 0.10 : 0.45),
                                tint.opacity(isDisabled ? 0.10 : 0.30)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isDisabled ? .clear : tint.opacity(isHovered ? 0.36 : 0.24),
                radius: isHovered ? 7 : 5,
                x: 0,
                y: 2
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(inactive)
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
    }
}

/// 顶栏合并式质粒文件胶囊（统一 28pt Capsule 高度 + 精简图标操作）
public struct PlasmidFileToolbarGroup: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var poolManager = PlasmidPoolManager.shared
    public let roleTitle: String
    public let tint: Color
    public let info: SnapGeneFileInfo?
    public let onLoadURL: (URL) -> Void
    public let onPreview: () -> Void
    
    @State private var isDropTargeted: Bool = false
    
    public init(
        roleTitle: String,
        tint: Color = .blue,
        info: SnapGeneFileInfo?,
        onLoadURL: @escaping (URL) -> Void,
        onPreview: @escaping () -> Void
    ) {
        self.roleTitle = roleTitle
        self.tint = tint
        self.info = info
        self.onLoadURL = onLoadURL
        self.onPreview = onPreview
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            Button(action: {
                FinderFileDropHelper.presentOpenPanel { url in
                    AppState.shared.showPlasmidPreview = true
                    onLoadURL(url)
                    Task {
                        await PlasmidPoolManager.shared.importFilesOrFolders(urls: [url], silent: true)
                    }
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: info != nil ? "checkmark.circle.fill" : "folder.badge.plus")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(info != nil ? tint : .primary)
                    Text(info != nil ? info!.fileName.replacingOccurrences(of: ".dna", with: "") : roleTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 11)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(info != nil ? "更换\(roleTitle)文件 (当前: \(info!.fileName))" : "从 Finder 选择或拖入\(roleTitle) .dna 文件")
            
            if !poolManager.items.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1, height: 14)
                
                Menu {
                    Text("从质粒池选择\(roleTitle)")
                    Divider()
                    ForEach(poolManager.items) { item in
                        Button("\(item.name) (\(item.dnaInfo.length) bp)") {
                            AppState.shared.showPlasmidPreview = true
                            let url = URL(fileURLWithPath: item.dnaInfo.filePath)
                            onLoadURL(url)
                        }
                    }
                    Divider()
                    Button("打开质粒池...") {
                        AppState.shared.selectedNav = .plasmidPool
                    }
                } label: {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 11))
                        .foregroundColor(tint)
                        .padding(.horizontal, 7)
                        .frame(height: 28)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("从质粒池选择\(roleTitle)")
            }
            
            if let loaded = info {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1, height: 14)
                
                Button(action: onPreview) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 11))
                        .foregroundColor(tint)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("预览\(roleTitle)质粒图谱")
                
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1, height: 14)
                
                Button(action: {
                    FinderFileDropHelper.revealInFinder(path: loaded.filePath)
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("在 Finder 中定位: \(loaded.filePath)")
            }
        }
        .glassEffect(
            isDropTargeted
                ? .regular.tint(tint.opacity(0.32)).interactive()
                : (info != nil
                    ? .regular.tint(tint.opacity(0.20)).interactive()
                    : appState.liquidGlassStyle.resolvedGlass(accentColor: appState.accentTheme.color, interactive: true)),
            in: Capsule(style: .continuous)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(isDropTargeted ? tint : Color.clear, lineWidth: isDropTargeted ? 1.5 : 0)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            FinderFileDropHelper.extractFirstFileURL(from: providers) { url in
                AppState.shared.showPlasmidPreview = true
                onLoadURL(url)
                Task {
                    await PlasmidPoolManager.shared.importFilesOrFolders(urls: [url], silent: true)
                }
            }
        }
    }
}

/// 常用分子克隆接头与 Kozak 序列预设常量（单片段与多片段共享）
public enum StandardLinkerPreset {
    public static let ggggs15Bp = "GGTGGAGGCGGTTCA"
    public static let gs6Bp = "GGATCC"
    public static let kozak6Bp = "GCCACC"
}

/// macOS Finder 文件选择、拖放解析与定位工具
public enum FinderFileDropHelper {
    @MainActor
    public static func revealInFinder(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = URL(fileURLWithPath: trimmed)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let parent = url.deletingLastPathComponent()
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: parent.path)
        }
    }
    
    /// 统一的 SnapGene (.dna) 质粒文件选择器（合并各视图重复的 selectDNAFile 实现）
    @MainActor
    public static func selectDNAFile(
        message: String = "选择 SnapGene (.dna) 质粒文件",
        prompt: String = "打开质粒",
        completion: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dna") ?? .data]
        panel.message = message
        panel.prompt = prompt
        panel.begin { response in
            if response == .OK, let url = panel.url {
                completion(url)
            }
        }
    }
    
    @MainActor
    public static func presentOpenPanel(
        allowSequenceTextFiles: Bool = true,
        onSelected: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "从 Finder 选择实验文件 (.dna / .ab1 / .tif / .pdb / .nwk / .csv / .fasta)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.tiff, .png, .jpeg, .commaSeparatedText]
        if let dnaType = UTType(filenameExtension: "dna") {
            types.append(dnaType)
        }
        if allowSequenceTextFiles {
            for ext in ["ab1", "abi", "fa", "fasta", "gb", "gbk", "seq", "txt", "pdb", "cif", "ent", "nwk", "newick", "tree", "tre", "csv", "tsv", "tif", "tiff"] {
                if let t = UTType(filenameExtension: ext) {
                    types.append(t)
                }
            }
            types.append(.plainText)
            types.append(.data)
        }
        panel.allowedContentTypes = types.isEmpty ? [.data] : types
        if panel.runModal() == .OK, let url = panel.url {
            onSelected(url)
        }
    }
    
    public static func extractFirstFileURL(
        from providers: [NSItemProvider],
        onExtracted: @escaping @MainActor (URL) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var resolvedURL: URL? = nil
            if let data = item as? Data {
                resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                resolvedURL = url
            } else if let str = item as? String {
                resolvedURL = URL(string: str) ?? URL(fileURLWithPath: str)
            }
            if let finalURL = resolvedURL {
                Task { @MainActor in
                    onExtracted(finalURL)
                }
            }
        }
        return true
    }
    
    public static func extractAllFileURLs(
        from providers: [NSItemProvider],
        onExtracted: @escaping @MainActor ([URL]) -> Void
    ) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in matching {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var resolvedURL: URL? = nil
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else if let str = item as? String {
                    resolvedURL = URL(string: str) ?? URL(fileURLWithPath: str)
                }
                if let u = resolvedURL {
                    lock.lock()
                    urls.append(u)
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            Task { @MainActor in
                onExtracted(urls)
            }
        }
        return true
    }
    
    @MainActor
    public static func loadSequence(
        from url: URL,
        onLoaded: @escaping (String, String) -> Void
    ) async {
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent
        if ext == "dna" {
            if let info = try? await SnapGeneService.shared.parseDNAFile(at: url) {
                onLoaded(info.sequence, fileName)
                return
            }
        }
        if let rawText = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .ascii)) {
            let lines = rawText.components(separatedBy: .newlines)
            let seqLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            let cleaned = BioSequence.clean(seqLines.joined())
            if !cleaned.isEmpty {
                onLoaded(cleaned, fileName)
            }
        }
    }
    
    /// 通用文本文件保存面板（统一收口各实验台 CSV / TSV / SVG / Newick 导出逻辑，支持导出后回调 URL 以写出 .run.json 溯源伴随文件）
    @MainActor
    public static func saveTextToFile(
        content: String,
        defaultFileName: String,
        contentType: UTType = .commaSeparatedText,
        toastPrefix: String = "已导出文件",
        onSavedURL: ((URL) -> Void)? = nil
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultFileName
        panel.allowedContentTypes = [contentType, .plainText]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                onSavedURL?(url)
                AppState.shared.showToast("\(toastPrefix): \(url.lastPathComponent)")
            } catch {
                AppState.shared.showToast("导出失败: \(error.localizedDescription)")
            }
        }
    }
    
    /// 借鉴 DockFlowLab 的单文件自包含离线中文 HTML 科学实验汇报单构建器（包含可复现参数、可信度与科学边界说明、数据表与 AnalysisRun 溯源签名）
    public static func buildOfflineHTMLReport(
        title: String,
        subtitle: String,
        credibilityBadge: String,
        warnings: [String],
        metrics: [(label: String, value: String)],
        tableHeaders: [String],
        tableRows: [[String]],
        extraPreBlockTitle: String? = nil,
        extraPreBlockContent: String? = nil,
        provenanceFooter: String? = nil
    ) -> String {
        let nowStr = ISO8601DateFormatter().string(from: Date())
        let metricsHTML = metrics.map { item in
            """
            <div class="metric-card">
              <div class="metric-label">\(item.label)</div>
              <div class="metric-val">\(item.value)</div>
            </div>
            """
        }.joined(separator: "\n")
        
        let warnHTML = warnings.map { w in
            "<li>\(w)</li>"
        }.joined(separator: "\n")
        
        let thHTML = tableHeaders.map { "<th>\($0)</th>" }.joined()
        let trHTML = tableRows.map { row in
            "<tr>" + row.map { "<td>\($0)</td>" }.joined() + "</tr>"
        }.joined(separator: "\n")
        
        let preSection: String = {
            guard let t = extraPreBlockTitle, let c = extraPreBlockContent, !c.isEmpty else { return "" }
            return """
            <h2>\(t)</h2>
            <pre class="code-box">\(c)</pre>
            """
        }()
        
        let provLine: String = {
            guard let pf = provenanceFooter, !pf.isEmpty else { return "" }
            return "<div class=\"prov-line\">\(pf)</div>"
        }()
        
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="UTF-8">
          <title>\(title) — Labworker 离线实验报告</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; margin: 32px auto; max-width: 980px; color: #1d1d1f; background: #f5f6f8; line-height: 1.55; padding: 0 20px; }
            .report-box { background: #ffffff; border-radius: 14px; padding: 28px 32px; box-shadow: 0 4px 18px rgba(0,0,0,0.06); }
            h1 { font-size: 22px; margin: 0 0 6px 0; color: #0f172a; }
            .sub { font-size: 13px; color: #64748b; margin-bottom: 18px; }
            .badge { display: inline-block; background: #e0f2fe; color: #0369a1; font-weight: 600; font-size: 12px; padding: 4px 10px; border-radius: 999px; margin-bottom: 16px; }
            h2 { font-size: 15px; margin: 22px 0 10px 0; color: #1e293b; border-bottom: 1px solid #e2e8f0; padding-bottom: 6px; }
            .metrics-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 10px; margin-bottom: 18px; }
            .metric-card { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 8px; padding: 10px 12px; }
            .metric-label { font-size: 11px; color: #64748b; }
            .metric-val { font-size: 14px; font-weight: 700; color: #0f172a; font-family: ui-monospace, SFMono-Regular, monospace; margin-top: 2px; }
            .warn-box { background: #fffbeb; border: 1px solid #fde68a; border-radius: 8px; padding: 10px 16px; font-size: 12.5px; color: #92400e; }
            table { width: 100%; border-collapse: collapse; font-size: 12.5px; margin-top: 8px; }
            th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #e2e8f0; font-family: ui-monospace, SFMono-Regular, monospace; }
            th { background: #f1f5f9; color: #334155; font-weight: 600; }
            .code-box { background: #0f172a; color: #e2e8f0; padding: 14px; border-radius: 8px; font-size: 12px; overflow-x: auto; }
            .prov-line { margin-top: 18px; padding-top: 10px; border-top: 1px dashed #cbd5e1; font-size: 11.5px; font-family: ui-monospace, SFMono-Regular, monospace; color: #475569; }
            .footer { margin-top: 8px; font-size: 11.5px; color: #94a3b8; text-align: right; }
          </style>
        </head>
        <body>
          <div class="report-box">
            <h1>\(title)</h1>
            <div class="sub">\(subtitle) · 生成时间: \(nowStr) · Labworker v3.0 (Offline Scientific Report)</div>
            <div class="badge">\(credibilityBadge)</div>
            <h2>1. 核心实验与构象指标汇总</h2>
            <div class="metrics-grid">
              \(metricsHTML)
            </div>
            <h2>2. 结构/数据体检与科学可信度说明（所有降级可见）</h2>
            <ul class="warn-box">
              \(warnHTML)
            </ul>
            <h2>3. 定量与构象明细数据表</h2>
            <table>
              <thead><tr>\(thHTML)</tr></thead>
              <tbody>\(trHTML)</tbody>
            </table>
            \(preSection)
            \(provLine)
            <div class="footer">Generated locally by Labworker macOS Native Workbench · 数据100%留在本机</div>
          </div>
        </body>
        </html>
        """
    }
    
    @MainActor
    public static func saveHTMLReport(
        htmlContent: String,
        defaultFileName: String,
        onSavedURL: ((URL) -> Void)? = nil
    ) {
        saveTextToFile(
            content: htmlContent,
            defaultFileName: defaultFileName,
            contentType: .html,
            toastPrefix: "已导出离线中文 HTML 报告",
            onSavedURL: onSavedURL
        )
    }
}
