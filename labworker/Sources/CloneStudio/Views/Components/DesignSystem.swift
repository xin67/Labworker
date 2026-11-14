import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

// MARK: - 00. 全局统一三层连续圆角与静态黑白高对比调色板
public enum StudioRadius {
    /// Level 1：主浮层面板、模块卡片 (`StudioCard`)
    public static let card: CGFloat = 16
    /// Level 3：卡片内部嵌套数据行、代码/序列编辑器 (`SequenceEditorBox`)
    public static let inner: CGFloat = 10
}

public enum StudioPalette {
    /// 右栏主工作区纯静背景（浅色纯白系 #F5F5F7，深色纯黑系 #131315）
    public static func workspaceBg(isLight: Bool) -> Color {
        isLight
            ? Color(red: 0.961, green: 0.961, blue: 0.969)
            : Color(red: 0.075, green: 0.075, blue: 0.082)
    }

    /// 卡片纯静表面（浅色 #FFFFFF，深色 #202023）
    public static func cardBg(isLight: Bool) -> Color {
        isLight
            ? Color.white
            : Color(red: 0.125, green: 0.125, blue: 0.137)
    }

    /// 卡片细描边
    public static func cardBorder(isLight: Bool) -> Color {
        isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.10)
    }

    /// 顶部工具栏及卡片内静态控件背景（浅色 #FFFFFF，深色 #2C2C30）
    public static func controlBg(isLight: Bool) -> Color {
        isLight
            ? Color.white
            : Color(red: 0.173, green: 0.173, blue: 0.188)
    }

    /// 禁用态 / 次级浅底
    public static func controlSubtleBg(isLight: Bool) -> Color {
        isLight ? Color.black.opacity(0.045) : Color.white.opacity(0.075)
    }

    /// 控件清晰描边
    public static func controlBorder(isLight: Bool) -> Color {
        isLight ? Color.black.opacity(0.11) : Color.white.opacity(0.13)
    }

    /// 分段器外轨背景
    public static func trackBg(isLight: Bool) -> Color {
        isLight ? Color.black.opacity(0.055) : Color.white.opacity(0.08)
    }

    /// 1px 分割线
    public static func hairline(isLight: Bool) -> Color {
        isLight ? Color.black.opacity(0.085) : Color.white.opacity(0.11)
    }
}

// MARK: - 00B. macOS 26 / 27 原生 Liquid Glass 与 HDR 高动态范围光学辅助
public enum StudioGlassSupport {
    /// 支持 HDR 扩展动态范围的颜色暴露调节（开启 HDR 高光时提升高光余量，关闭时回归标准 SDR）
    public static func hdrColor(_ base: Color, exposure: Double = 0.28, appState: AppState) -> Color {
        guard appState.enableAmbientGlassGlow else { return base }
        return base.exposureAdjust(exposure)
    }

    /// 针对亮色/暗色工作区卡片优化的 HDR 玻璃高光描边（确保纯白/纯黑静卡上玻璃轮廓依然锐利通透）
    public static func specularRimColor(
        isLight: Bool,
        tint: Color? = nil,
        prominent: Bool = false,
        selected: Bool = false,
        disabled: Bool = false,
        appState: AppState
    ) -> Color {
        if disabled {
            return isLight ? Color.black.opacity(0.07) : Color.white.opacity(0.07)
        }
        if prominent {
            return hdrColor(.white, exposure: 0.45, appState: appState).opacity(isLight ? 0.52 : 0.38)
        }
        if selected, let tint {
            return hdrColor(tint, exposure: 0.36, appState: appState).opacity(isLight ? 0.52 : 0.62)
        }
        if let tint {
            return hdrColor(tint, exposure: 0.25, appState: appState).opacity(isLight ? 0.32 : 0.42)
        }
        return hdrColor(.white, exposure: 0.35, appState: appState).opacity(isLight ? 0.72 : 0.26)
    }

    /// 构建遵循设置项 (`LiquidGlassStyleMode`) 与 HDR 浸染规则的原生 SwiftUI `Glass`
    public static func buttonGlass(
        appState: AppState,
        tint: Color? = nil,
        prominent: Bool = false,
        selected: Bool = false,
        disabled: Bool = false,
        interactive: Bool = true
    ) -> Glass {
        let resolvedTint = tint ?? appState.accentTheme.color
        let isLight = appState.isLightAppearance
        let baseGlass: Glass
        switch appState.liquidGlassStyle {
        case .regular:
            baseGlass = .regular
        case .clear:
            baseGlass = .clear
        case .tinted:
            baseGlass = .regular.tint(
                hdrColor(appState.accentTheme.color, exposure: 0.20, appState: appState)
                    .opacity(isLight ? 0.14 : 0.22)
            )
        }

        let configured: Glass
        if disabled {
            configured = .regular
        } else if prominent {
            configured = .regular.tint(
                hdrColor(resolvedTint, exposure: 0.38, appState: appState)
                    .opacity(isLight ? 0.86 : 0.82)
            )
        } else if selected {
            configured = .regular.tint(
                hdrColor(resolvedTint, exposure: 0.32, appState: appState)
                    .opacity(isLight ? 0.28 : 0.44)
            )
        } else if let customTint = tint {
            configured = baseGlass.tint(
                hdrColor(customTint, exposure: 0.24, appState: appState)
                    .opacity(isLight ? 0.14 : 0.26)
            )
        } else {
            configured = baseGlass
        }
        return (interactive && !disabled) ? configured.interactive() : configured
    }

    public static func dynamicRange(for appState: AppState) -> Image.DynamicRange {
        appState.enableAmbientGlassGlow ? .high : .standard
    }
}

// MARK: - 00C. 防误聚焦玻璃搜索输入框（未点击时绝不自动获得焦点，彻底杜绝未点击光标闪烁）
public struct StudioNoAutoFocusSearchField: NSViewRepresentable {
    public let placeholder: String
    @Binding public var text: String
    @Binding public var focusTrigger: Int

    public init(
        placeholder: String,
        text: Binding<String>,
        focusTrigger: Binding<Int>
    ) {
        self.placeholder = placeholder
        self._text = text
        self._focusTrigger = focusTrigger
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> PassiveFocusSearchNSTextField {
        let field = PassiveFocusSearchNSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 13)
            ]
        )
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onExternalFocusReset = { [weak coordinator = context.coordinator] in
            coordinator?.installOutsideClickMonitor()
        }
        context.coordinator.textField = field
        context.coordinator.lastFocusTrigger = focusTrigger
        return field
    }

    public func updateNSView(_ nsView: PassiveFocusSearchNSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 13)
                ]
            )
        }
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            context.coordinator.activateFocus(on: nsView)
        }
    }

    public final class PassiveFocusSearchNSTextField: NSTextField {
        var allowUserFocus: Bool = false
        var onExternalFocusReset: (() -> Void)?

        public override var acceptsFirstResponder: Bool {
            allowUserFocus
        }

        public override func mouseDown(with event: NSEvent) {
            allowUserFocus = true
            window?.makeFirstResponder(self)
            onExternalFocusReset?()
            super.mouseDown(with: event)
        }
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: StudioNoAutoFocusSearchField
        weak var textField: PassiveFocusSearchNSTextField?
        var lastFocusTrigger: Int = 0
        nonisolated(unsafe) private var mouseMonitor: Any?

        init(parent: StudioNoAutoFocusSearchField) {
            self.parent = parent
        }

        deinit {
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
                mouseMonitor = nil
            }
        }

        @MainActor
        func activateFocus(on field: PassiveFocusSearchNSTextField) {
            field.allowUserFocus = true
            DispatchQueue.main.async { [weak self, weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                self?.installOutsideClickMonitor()
            }
        }

        @MainActor
        func installOutsideClickMonitor() {
            guard mouseMonitor == nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self,
                      let field = self.textField,
                      let window = field.window,
                      event.window === window else {
                    return event
                }
                let hitHost = field.superview ?? field
                let pt = hitHost.convert(event.locationInWindow, from: nil)
                let expanded = hitHost.bounds.insetBy(dx: -36, dy: -8)
                if !expanded.contains(pt) {
                    field.allowUserFocus = false
                    window.makeFirstResponder(nil)
                    self.removeOutsideClickMonitor()
                }
                return event
            }
        }

        @MainActor
        private func removeOutsideClickMonitor() {
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
                mouseMonitor = nil
            }
        }

        public func controlTextDidBeginEditing(_ obj: Notification) {
            MainActor.assumeIsolated {
                installOutsideClickMonitor()
            }
        }

        public func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let val = field.stringValue
            MainActor.assumeIsolated {
                if parent.text != val {
                    parent.text = val
                }
            }
        }

        public func controlTextDidEndEditing(_ obj: Notification) {
            MainActor.assumeIsolated {
                textField?.allowUserFocus = false
                removeOutsideClickMonitor()
            }
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                return MainActor.assumeIsolated {
                    if !parent.text.isEmpty {
                        parent.text = ""
                        textField?.stringValue = ""
                    } else {
                        textField?.allowUserFocus = false
                        textField?.window?.makeFirstResponder(nil)
                        removeOutsideClickMonitor()
                    }
                    return true
                }
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return MainActor.assumeIsolated {
                    textField?.allowUserFocus = false
                    textField?.window?.makeFirstResponder(nil)
                    removeOutsideClickMonitor()
                    return true
                }
            }
            return false
        }
    }
}

// MARK: - 0. 原生 macOS 毛玻璃高斯模糊视图 (NSVisualEffectView 封装，供窗口级侧边栏背板使用)
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

// MARK: - 0B. 层次化分段胶囊按钮组与全宽/双列胶囊按钮

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

/// 连体分段胶囊按钮组（统一 30pt Capsule 高度 + macOS 26/27 原生 Liquid Glass 与 HDR 支持）
public struct StudioSegmentedPillGroup: View {
    @ObservedObject private var appState = AppState.shared
    public let items: [StudioPillGroupItem]
    public var expandEqually: Bool = false
    
    public init(items: [StudioPillGroupItem], expandEqually: Bool = false) {
        self.items = items
        self.expandEqually = expandEqually
    }
    
    public var body: some View {
        let isLight = appState.isLightAppearance
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(StudioPalette.hairline(isLight: isLight))
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
                        .frame(height: 30)
                        .frame(maxWidth: expandEqually ? .infinity : nil)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(item.isDisabled)
                    .help(item.help ?? item.title)
                }
            }
            .glassEffect(
                StudioGlassSupport.buttonGlass(appState: appState, interactive: true),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        StudioGlassSupport.specularRimColor(isLight: isLight, appState: appState),
                        lineWidth: 0.75
                    )
            )
        }
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
    }
}

/// 独立饱满胶囊按钮（统一 30pt Capsule 高度 + macOS 26/27 原生 Liquid Glass 与 HDR 支持）
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
        let isLight = appState.isLightAppearance
        let isIconOnly = title.isEmpty && (icon?.isEmpty == false)
        let borderColor = StudioGlassSupport.specularRimColor(
            isLight: isLight,
            tint: tint,
            prominent: isProminent,
            disabled: isDisabled,
            appState: appState
        )
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
            .frame(minWidth: isIconOnly ? 30 : nil, maxWidth: fillWidth ? .infinity : nil)
            .frame(height: 30)
            .glassEffect(
                StudioGlassSupport.buttonGlass(
                    appState: appState,
                    tint: tint,
                    prominent: isProminent,
                    disabled: isDisabled,
                    interactive: !isDisabled
                ),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 0.75)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
        
        if let helpText = help, !helpText.isEmpty {
            btn.help(helpText)
        } else {
            btn
        }
    }
}

/// 紧凑内联胶囊按钮（统一 24pt Capsule 高度，专用于密集列表行、峰位跳转与卡片副操作 + Liquid Glass HDR）
public struct StudioCompactPillButton: View {
    @ObservedObject private var appState = AppState.shared
    public let title: String
    public var icon: String? = nil
    public var dotColor: Color? = nil
    public var tint: Color? = nil
    public var isProminent: Bool = false
    public var isSelected: Bool = false
    public var monospaced: Bool = false
    public var isDisabled: Bool = false
    public var help: String? = nil
    public let action: () -> Void

    public init(
        title: String,
        icon: String? = nil,
        dotColor: Color? = nil,
        tint: Color? = nil,
        isProminent: Bool = false,
        isSelected: Bool = false,
        monospaced: Bool = false,
        isDisabled: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.dotColor = dotColor
        self.tint = tint
        self.isProminent = isProminent
        self.isSelected = isSelected
        self.monospaced = monospaced
        self.isDisabled = isDisabled
        self.help = help
        self.action = action
    }

    public var body: some View {
        let isLight = appState.isLightAppearance
        let resolvedTint = tint ?? appState.accentTheme.color
        let isIconOnly = title.isEmpty && (icon?.isEmpty == false)
        let borderColor = StudioGlassSupport.specularRimColor(
            isLight: isLight,
            tint: isSelected ? resolvedTint : tint,
            prominent: isProminent,
            selected: isSelected,
            disabled: isDisabled,
            appState: appState
        )
        let fgColor: Color = {
            if isDisabled {
                return .secondary.opacity(0.45)
            } else if isProminent {
                return .white
            } else if isSelected {
                return tint ?? resolvedTint
            } else {
                return tint ?? .primary
            }
        }()
        let btn = Button(action: action) {
            HStack(spacing: isIconOnly ? 0 : 4) {
                if let dot = dotColor {
                    Circle()
                        .fill(dot)
                        .frame(width: 6, height: 6)
                }
                if let icon = icon, !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: monospaced ? .monospaced : .default))
                        .lineLimit(1)
                }
            }
            .foregroundColor(fgColor)
            .padding(.horizontal, isIconOnly ? 0 : 9)
            .frame(minWidth: isIconOnly ? 24 : nil)
            .frame(height: 24)
            .glassEffect(
                StudioGlassSupport.buttonGlass(
                    appState: appState,
                    tint: tint,
                    prominent: isProminent,
                    selected: isSelected,
                    disabled: isDisabled,
                    interactive: !isDisabled
                ),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 0.75)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))

        if let helpText = help, !helpText.isEmpty {
            btn.help(helpText)
        } else {
            btn
        }
    }
}

/// 统一胶囊下拉菜单按钮（支持 30pt 标准 / 24pt 紧凑 + macOS 26/27 原生 Liquid Glass 与 HDR）
public struct StudioMenuPillButton<MenuContent: View>: View {
    @ObservedObject private var appState = AppState.shared
    public let title: String
    public var icon: String? = nil
    public var tint: Color? = nil
    public var compact: Bool = false
    public var isDisabled: Bool = false
    public var help: String? = nil
    public let menuContent: MenuContent

    public init(
        title: String,
        icon: String? = nil,
        tint: Color? = nil,
        compact: Bool = false,
        isDisabled: Bool = false,
        help: String? = nil,
        @ViewBuilder content: () -> MenuContent
    ) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.compact = compact
        self.isDisabled = isDisabled
        self.help = help
        self.menuContent = content()
    }

    public var body: some View {
        let isLight = appState.isLightAppearance
        let pillHeight: CGFloat = compact ? 24 : 30
        let borderColor = StudioGlassSupport.specularRimColor(
            isLight: isLight,
            tint: tint,
            disabled: isDisabled,
            appState: appState
        )
        let menu = Menu {
            menuContent
        } label: {
            HStack(spacing: compact ? 4 : 5) {
                if let icon = icon, !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: compact ? 8 : 8.5, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundColor(isDisabled ? .secondary.opacity(0.45) : (tint ?? .primary))
            .padding(.horizontal, compact ? 9 : 11)
            .frame(height: pillHeight)
            .glassEffect(
                StudioGlassSupport.buttonGlass(
                    appState: appState,
                    tint: tint,
                    disabled: isDisabled,
                    interactive: !isDisabled
                ),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 0.75)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isDisabled)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))

        if let helpText = help, !helpText.isEmpty {
            menu.help(helpText)
        } else {
            menu
        }
    }
}

public struct StudioMenuPickerOption<Value: Hashable>: Identifiable {
    public let id: Value
    public let value: Value
    public let title: String

    public init(value: Value, title: String) {
        self.id = value
        self.value = value
        self.title = title
    }
}

/// 统一胶囊下拉选择器（替代样式错落的 `.pickerStyle(.menu)` + `.controlSize`）
public struct StudioMenuPicker<Value: Hashable>: View {
    @Binding public var selection: Value
    public let options: [StudioMenuPickerOption<Value>]
    public var prefix: String? = nil
    public var icon: String? = nil
    public var tint: Color? = nil
    public var compact: Bool = false
    public var help: String? = nil

    public init(
        selection: Binding<Value>,
        options: [StudioMenuPickerOption<Value>],
        prefix: String? = nil,
        icon: String? = nil,
        tint: Color? = nil,
        compact: Bool = false,
        help: String? = nil
    ) {
        self._selection = selection
        self.options = options
        self.prefix = prefix
        self.icon = icon
        self.tint = tint
        self.compact = compact
        self.help = help
    }

    public var body: some View {
        let activeTitle = options.first(where: { $0.value == selection })?.title ?? ""
        let label = (prefix != nil && !prefix!.isEmpty) ? "\(prefix!): \(activeTitle)" : activeTitle
        StudioMenuPillButton(
            title: label,
            icon: icon,
            tint: tint,
            compact: compact,
            help: help
        ) {
            ForEach(options) { opt in
                Button {
                    selection = opt.value
                } label: {
                    if selection == opt.value {
                        Label(opt.title, systemImage: "checkmark")
                    } else {
                        Text(opt.title)
                    }
                }
            }
        }
    }
}

/// 统一卡片内部子容器 / 数据行样式（严格 Level 3 连续圆角 StudioRadius.inner = 10 + 静态高对比边框）
private struct StudioInnerBoxModifier: ViewModifier {
    @ObservedObject private var appState = AppState.shared
    let tint: Color?
    let isHighlighted: Bool
    let paddingH: CGFloat
    let paddingV: CGFloat

    func body(content: Content) -> some View {
        let isLight = appState.isLightAppearance
        let resolvedTint = tint ?? appState.accentTheme.color
        let bg: Color = {
            if isHighlighted {
                return resolvedTint.opacity(isLight ? 0.10 : 0.18)
            } else if let t = tint {
                return t.opacity(isLight ? 0.06 : 0.12)
            } else {
                return StudioPalette.controlSubtleBg(isLight: isLight)
            }
        }()
        let border: Color = {
            if isHighlighted {
                return resolvedTint.opacity(0.42)
            } else if let t = tint {
                return t.opacity(0.24)
            } else {
                return StudioPalette.cardBorder(isLight: isLight)
            }
        }()
        content
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                    .fill(bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
    }
}

public extension View {
    func studioInnerBox(
        tint: Color? = nil,
        isHighlighted: Bool = false,
        paddingH: CGFloat = 10,
        paddingV: CGFloat = 7
    ) -> some View {
        modifier(
            StudioInnerBoxModifier(
                tint: tint,
                isHighlighted: isHighlighted,
                paddingH: paddingH,
                paddingV: paddingV
            )
        )
    }
}

// MARK: - 1. 顶部 Finder 自适应溢出工具栏与系统设置风格模糊吸顶容器

public struct StudioToolbarMenuItem: Identifiable {
    public let id: String
    public let title: String
    public let icon: String?
    public let isDisabled: Bool
    public let action: () -> Void
    
    public init(
        id: String? = nil,
        title: String,
        icon: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id ?? title
        self.title = title
        self.icon = icon
        self.isDisabled = isDisabled
        self.action = action
    }
}

public struct StudioToolbarPickerOption: Identifiable {
    public let id: String
    public let title: String
    public let tint: Color
    public let isSelected: Bool
    public let action: () -> Void
    
    public init(
        id: String? = nil,
        title: String,
        tint: Color = .blue,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.id = id ?? title
        self.title = title
        self.tint = tint
        self.isSelected = isSelected
        self.action = action
    }
}

public struct StudioToolbarItem: Identifiable {
    public enum Payload {
        case action(
            groupKey: String?,
            title: String,
            icon: String,
            tint: Color?,
            isProminent: Bool,
            isDisabled: Bool,
            help: String?,
            menuItems: [StudioToolbarMenuItem]?,
            action: () -> Void
        )
        case plasmidToggle(isOn: Binding<Bool>, isAvailable: Bool)
        case plasmidFile(
            roleTitle: String,
            tint: Color,
            info: SnapGeneFileInfo?,
            onLoadURL: (URL) -> Void,
            onPreview: () -> Void
        )
        case picker(label: String, options: [StudioToolbarPickerOption])
    }
    
    public let id: String
    public let payload: Payload
    
    public init(id: String, payload: Payload) {
        self.id = id
        self.payload = payload
    }
    
    public static func action(
        id: String? = nil,
        groupKey: String? = "main",
        title: String,
        icon: String,
        tint: Color? = nil,
        isProminent: Bool = false,
        isDisabled: Bool = false,
        help: String? = nil,
        menuItems: [StudioToolbarMenuItem]? = nil,
        action: @escaping () -> Void = {}
    ) -> StudioToolbarItem {
        let resolvedID = id ?? (title.isEmpty ? "icon_\(icon)" : "\(title)_\(icon)")
        return StudioToolbarItem(
            id: resolvedID,
            payload: .action(
                groupKey: isProminent ? nil : groupKey,
                title: title,
                icon: icon,
                tint: tint,
                isProminent: isProminent,
                isDisabled: isDisabled,
                help: help,
                menuItems: menuItems,
                action: action
            )
        )
    }
    
    public static func plasmidToggle(
        id: String = "plasmid_toggle",
        isOn: Binding<Bool>,
        isAvailable: Bool
    ) -> StudioToolbarItem {
        StudioToolbarItem(id: id, payload: .plasmidToggle(isOn: isOn, isAvailable: isAvailable))
    }
    
    public static func plasmidFile(
        id: String? = nil,
        roleTitle: String,
        tint: Color = .blue,
        info: SnapGeneFileInfo?,
        onLoadURL: @escaping (URL) -> Void,
        onPreview: @escaping () -> Void
    ) -> StudioToolbarItem {
        StudioToolbarItem(
            id: id ?? "plasmid_file_\(roleTitle)",
            payload: .plasmidFile(
                roleTitle: roleTitle,
                tint: tint,
                info: info,
                onLoadURL: onLoadURL,
                onPreview: onPreview
            )
        )
    }
    
    public static func picker(
        id: String,
        label: String,
        options: [StudioToolbarPickerOption]
    ) -> StudioToolbarItem {
        StudioToolbarItem(id: id, payload: .picker(label: label, options: options))
    }
    
    var isTextAction: Bool {
        if case let .action(_, title, _, _, _, _, _, _, _) = payload {
            return !title.isEmpty
        }
        return false
    }
    
    var isIconOnlyAction: Bool {
        if case let .action(_, title, _, _, _, _, _, _, _) = payload {
            return title.isEmpty
        }
        return false
    }
    
    var actionGroupKey: String? {
        if case let .action(groupKey, _, _, _, isProminent, _, _, _, _) = payload, !isProminent {
            return groupKey
        }
        return nil
    }
    
    var fallbackWidth: CGFloat {
        switch payload {
        case let .action(_, title, _, _, _, _, _, _, _):
            return title.isEmpty ? 30 : 76
        case .plasmidToggle:
            return 64
        case let .plasmidFile(roleTitle, _, info, _, _):
            return info != nil ? 160 : max(82, CGFloat(roleTitle.count * 14 + 46))
        case let .picker(_, options):
            let sum = options.reduce(CGFloat(0)) { $0 + max(44, CGFloat($1.title.count * 12 + 22)) }
            return max(92, sum + 6)
        }
    }
}

/// Finder 风格统一尺寸 + 窗口缩窄自动折叠至 `»` 菜单的顶部工具栏
public struct StudioOverflowToolbar: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var poolManager = PlasmidPoolManager.shared
    public let items: [StudioToolbarItem]
    
    @State private var availableWidth: CGFloat = 0
    @State private var measuredWidths: [String: CGFloat] = [:]
    
    public init(items: [StudioToolbarItem]) {
        self.items = items
    }
    
    private var isLight: Bool {
        appState.isLightAppearance
    }
    
    private var actionSlotWidth: CGFloat {
        let maxMeasured = items.compactMap { item -> CGFloat? in
            guard item.isTextAction else { return nil }
            return measuredWidths[item.id]
        }.max() ?? 72
        return max(70, ceil(maxMeasured))
    }
    
    private func joinsGroup(_ prev: StudioToolbarItem, _ curr: StudioToolbarItem) -> Bool {
        guard let k1 = prev.actionGroupKey, let k2 = curr.actionGroupKey else { return false }
        return k1 == k2
    }
    
    private func widthOf(_ item: StudioToolbarItem) -> CGFloat {
        if item.isTextAction {
            return actionSlotWidth
        }
        if item.isIconOnlyAction {
            return 30
        }
        return max(60, ceil(measuredWidths[item.id] ?? item.fallbackWidth))
    }
    
    private func totalWidth(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        var total: CGFloat = 0
        for idx in 0..<count {
            let item = items[idx]
            total += widthOf(item)
            if idx > 0 {
                total += joinsGroup(items[idx - 1], item) ? 1.0 : 8.0
            }
        }
        return total
    }
    
    private var visibleCount: Int {
        guard !items.isEmpty, availableWidth > 1 else { return 0 }
        if totalWidth(for: items.count) <= availableWidth + 0.5 {
            return items.count
        }
        for count in stride(from: items.count - 1, through: 1, by: -1) {
            if totalWidth(for: count) + 38.0 <= availableWidth + 0.5 {
                return count
            }
        }
        return 0
    }
    
    private func buildRuns(for slice: ArraySlice<StudioToolbarItem>) -> [[StudioToolbarItem]] {
        var runs: [[StudioToolbarItem]] = []
        for item in slice {
            if var lastRun = runs.last, let prev = lastRun.last, joinsGroup(prev, item) {
                lastRun.append(item)
                runs[runs.count - 1] = lastRun
            } else {
                runs.append([item])
            }
        }
        return runs
    }
    
    public var body: some View {
        let visCount = visibleCount
        let visibleSlice = items.prefix(visCount)
        let overflowSlice = items.dropFirst(visCount)
        let runs = buildRuns(for: visibleSlice)
        
        Color.clear
            .frame(minWidth: 34, maxWidth: .infinity, minHeight: 30, maxHeight: 30)
            .onGeometryChange(for: CGFloat.self) { proxy in
                ceil(proxy.size.width)
            } action: { newWidth in
                let clamped = max(0, newWidth)
                if abs(availableWidth - clamped) > 0.5 {
                    availableWidth = clamped
                }
            }
            .background {
                measurementOverlay
            }
            .overlay(alignment: .trailing) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                            renderRun(run)
                        }
                        
                        if !overflowSlice.isEmpty {
                            overflowMenu(items: Array(overflowSlice))
                        }
                    }
                }
                .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
                .opacity(availableWidth > 1 ? 1 : 0)
            }
    }
    
    @ViewBuilder
    private var measurementOverlay: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                intrinsicItemView(item)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        ceil(proxy.size.width)
                    } action: { w in
                        guard w > 1 else { return }
                        if abs((measuredWidths[item.id] ?? 0) - w) > 0.5 {
                            measuredWidths[item.id] = w
                        }
                    }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    
    @ViewBuilder
    private func intrinsicItemView(_ item: StudioToolbarItem) -> some View {
        switch item.payload {
        case let .action(_, title, icon, _, _, _, _, menuItems, _):
            HStack(spacing: title.isEmpty ? 0 : 4.5) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                if let menuItems, !menuItems.isEmpty {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                }
            }
            .padding(.horizontal, title.isEmpty ? 0 : 11)
            .frame(minWidth: title.isEmpty ? 30 : nil)
            .frame(height: 30)
        case let .plasmidToggle(isOn, isAvailable):
            PlasmidPreviewToggle(isOn: isOn, isAvailable: isAvailable)
        case let .plasmidFile(roleTitle, tint, info, onLoadURL, onPreview):
            PlasmidFileToolbarGroup(
                roleTitle: roleTitle,
                tint: tint,
                info: info,
                onLoadURL: onLoadURL,
                onPreview: onPreview
            )
        case let .picker(_, options):
            toolbarPickerView(options: options)
        }
    }
    
    @ViewBuilder
    private func renderRun(_ run: [StudioToolbarItem]) -> some View {
        if run.count == 1, let item = run.first {
            renderSingleItem(item)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(run.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Rectangle()
                            .fill(StudioPalette.hairline(isLight: isLight))
                            .frame(width: 1, height: 15)
                    }
                    renderGroupedActionItem(item)
                }
            }
            .glassEffect(
                StudioGlassSupport.buttonGlass(appState: appState, interactive: true),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        StudioGlassSupport.specularRimColor(isLight: isLight, appState: appState),
                        lineWidth: 0.75
                    )
            )
        }
    }
    
    @ViewBuilder
    private func renderSingleItem(_ item: StudioToolbarItem) -> some View {
        switch item.payload {
        case let .action(_, title, icon, tint, isProminent, isDisabled, help, menuItems, action):
            let isIconOnly = title.isEmpty
            let slotW: CGFloat = isIconOnly ? 30 : actionSlotWidth
            let borderColor = StudioGlassSupport.specularRimColor(
                isLight: isLight,
                tint: tint,
                prominent: isProminent,
                disabled: isDisabled,
                appState: appState
            )
            let fgColor: Color = isDisabled
                ? .secondary.opacity(0.45)
                : (isProminent ? .white : (tint ?? .primary))
            
            let labelView = actionLabel(
                title: title,
                icon: icon,
                hasMenu: (menuItems?.isEmpty == false),
                fgColor: fgColor,
                slotWidth: slotW
            )
            .glassEffect(
                StudioGlassSupport.buttonGlass(
                    appState: appState,
                    tint: tint,
                    prominent: isProminent,
                    disabled: isDisabled,
                    interactive: !isDisabled
                ),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 0.75)
            )
            .contentShape(Capsule(style: .continuous))
            
            if let menuItems, !menuItems.isEmpty {
                Menu {
                    ForEach(menuItems) { sub in
                        Button(action: sub.action) {
                            if let subIcon = sub.icon {
                                Label(sub.title, systemImage: subIcon)
                            } else {
                                Text(sub.title)
                            }
                        }
                        .disabled(sub.isDisabled)
                    }
                } label: {
                    labelView
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isDisabled)
                .help(help ?? title)
            } else {
                Button(action: action) {
                    labelView
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help(help ?? title)
            }
            
        case let .plasmidToggle(isOn, isAvailable):
            PlasmidPreviewToggle(isOn: isOn, isAvailable: isAvailable)
            
        case let .plasmidFile(roleTitle, tint, info, onLoadURL, onPreview):
            PlasmidFileToolbarGroup(
                roleTitle: roleTitle,
                tint: tint,
                info: info,
                onLoadURL: onLoadURL,
                onPreview: onPreview
            )
            
        case let .picker(_, options):
            toolbarPickerView(options: options)
        }
    }
    
    @ViewBuilder
    private func renderGroupedActionItem(_ item: StudioToolbarItem) -> some View {
        if case let .action(_, title, icon, tint, _, isDisabled, help, menuItems, action) = item.payload {
            let slotW: CGFloat = title.isEmpty ? 30 : actionSlotWidth
            let fgColor: Color = isDisabled
                ? .secondary.opacity(0.45)
                : (tint ?? .primary)
            let labelView = actionLabel(
                title: title,
                icon: icon,
                hasMenu: (menuItems?.isEmpty == false),
                fgColor: fgColor,
                slotWidth: slotW
            )
            .contentShape(Rectangle())
            
            if let menuItems, !menuItems.isEmpty {
                Menu {
                    ForEach(menuItems) { sub in
                        Button(action: sub.action) {
                            if let subIcon = sub.icon {
                                Label(sub.title, systemImage: subIcon)
                            } else {
                                Text(sub.title)
                            }
                        }
                        .disabled(sub.isDisabled)
                    }
                } label: {
                    labelView
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isDisabled)
                .help(help ?? title)
            } else {
                Button(action: action) {
                    labelView
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help(help ?? title)
            }
        }
    }
    
    @ViewBuilder
    private func actionLabel(
        title: String,
        icon: String,
        hasMenu: Bool,
        fgColor: Color,
        slotWidth: CGFloat
    ) -> some View {
        HStack(spacing: title.isEmpty ? 0 : 4.5) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            if hasMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
            }
        }
        .foregroundColor(fgColor)
        .frame(width: slotWidth, height: 30)
    }
    
    @ViewBuilder
    private func toolbarPickerView(options: [StudioToolbarPickerOption]) -> some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(options) { opt in
                    Button(action: opt.action) {
                        Text(opt.title)
                            .font(.system(size: 12, weight: opt.isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .foregroundColor(opt.isSelected ? .white : .primary.opacity(0.88))
                            .glassEffect(
                                opt.isSelected
                                    ? StudioGlassSupport.buttonGlass(
                                        appState: appState,
                                        tint: opt.tint,
                                        prominent: true,
                                        interactive: true
                                    )
                                    : .identity,
                                in: Capsule(style: .continuous)
                            )
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2.5)
            .frame(height: 30)
            .glassEffect(
                StudioGlassSupport.buttonGlass(appState: appState, interactive: true),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        StudioGlassSupport.specularRimColor(isLight: isLight, appState: appState),
                        lineWidth: 0.75
                    )
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    
    @ViewBuilder
    private func overflowMenu(items hiddenItems: [StudioToolbarItem]) -> some View {
        Menu {
            ForEach(hiddenItems) { item in
                overflowMenuItemView(item)
            }
        } label: {
            Image(systemName: "chevron.right.2")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 30, height: 30)
                .glassEffect(
                    StudioGlassSupport.buttonGlass(appState: appState, interactive: true),
                    in: Circle()
                )
                .overlay(
                    Circle()
                        .stroke(
                            StudioGlassSupport.specularRimColor(isLight: isLight, appState: appState),
                            lineWidth: 0.75
                        )
                )
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("展开其余工具按钮")
    }
    
    @ViewBuilder
    private func overflowMenuItemView(_ item: StudioToolbarItem) -> some View {
        switch item.payload {
        case let .action(_, title, icon, _, _, isDisabled, help, menuItems, action):
            let displayTitle = title.isEmpty ? (help ?? "操作") : title
            if let menuItems, !menuItems.isEmpty {
                Menu {
                    ForEach(menuItems) { sub in
                        Button(action: sub.action) {
                            if let subIcon = sub.icon {
                                Label(sub.title, systemImage: subIcon)
                            } else {
                                Text(sub.title)
                            }
                        }
                        .disabled(sub.isDisabled)
                    }
                } label: {
                    Label(displayTitle, systemImage: icon)
                }
                .disabled(isDisabled)
            } else {
                Button(action: action) {
                    Label(displayTitle, systemImage: icon)
                }
                .disabled(isDisabled)
            }
            
        case let .plasmidToggle(isOn, _):
            Button {
                isOn.wrappedValue.toggle()
            } label: {
                Label(
                    isOn.wrappedValue ? "隐藏质粒图谱" : "显示质粒图谱",
                    systemImage: isOn.wrappedValue ? "circle.circle.fill" : "circle.circle"
                )
            }
            
        case let .plasmidFile(roleTitle, _, info, onLoadURL, onPreview):
            Menu {
                Button {
                    FinderFileDropHelper.presentOpenPanel { url in
                        AppState.shared.showPlasmidPreview = true
                        onLoadURL(url)
                        Task {
                            await PlasmidPoolManager.shared.importFilesOrFolders(urls: [url], silent: true)
                        }
                    }
                } label: {
                    Label(
                        info != nil ? "更换\(roleTitle) (\(info!.fileName))" : "从 Finder 选择\(roleTitle)...",
                        systemImage: "folder.badge.plus"
                    )
                }
                
                if !poolManager.items.isEmpty {
                    Menu("从质粒池选择\(roleTitle)") {
                        ForEach(poolManager.items) { poolItem in
                            Button("\(poolItem.name) (\(poolItem.dnaInfo.length) bp)") {
                                AppState.shared.showPlasmidPreview = true
                                let url = URL(fileURLWithPath: poolItem.dnaInfo.filePath)
                                onLoadURL(url)
                            }
                        }
                        Divider()
                        Button("打开质粒池...") {
                            AppState.shared.selectedNav = .plasmidPool
                        }
                    }
                }
                
                if let loaded = info {
                    Divider()
                    Button(action: onPreview) {
                        Label("预览\(roleTitle)质粒图谱", systemImage: "eye.fill")
                    }
                    Button {
                        FinderFileDropHelper.revealInFinder(path: loaded.filePath)
                    } label: {
                        Label("在 Finder 中定位", systemImage: "folder")
                    }
                }
            } label: {
                Label(
                    info != nil
                        ? "\(roleTitle): \(info!.fileName.replacingOccurrences(of: ".dna", with: ""))"
                        : "载入\(roleTitle) (.dna)",
                    systemImage: info != nil ? "checkmark.circle.fill" : "folder.badge.plus"
                )
            }
            
        case let .picker(label, options):
            let activeTitle = options.first(where: \.isSelected)?.title ?? label
            Menu {
                ForEach(options) { opt in
                    Button(action: opt.action) {
                        if opt.isSelected {
                            Label(opt.title, systemImage: "checkmark")
                        } else {
                            Text(opt.title)
                        }
                    }
                }
            } label: {
                Label("\(label): \(activeTitle)", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

/// 全局标准页面滚动容器：macOS 26/27 原生 `.safeAreaBar` + `.scrollEdgeEffectStyle(.soft)` 渐进式模糊吸顶顶栏（参考系统设置）
public struct StudioPageLayout<TrailingContent: View, BodyContent: View>: View {
    @ObservedObject private var appState = AppState.shared
    public let title: String
    public let trailingContent: TrailingContent
    public let bodyContent: BodyContent
    
    public init(
        title: String,
        @ViewBuilder trailing: () -> TrailingContent,
        @ViewBuilder content: () -> BodyContent
    ) {
        self.title = title
        self.trailingContent = trailing()
        self.bodyContent = content()
    }
    
    public var body: some View {
        let isLight = appState.isLightAppearance
        let baseBg = StudioPalette.workspaceBg(isLight: isLight)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                bodyContent
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                
                trailingContent
                    .frame(minWidth: 34, maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: baseBg.opacity(isLight ? 0.65 : 0.72), location: 0.0),
                        .init(color: baseBg.opacity(isLight ? 0.28 : 0.34), location: 0.58),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            )
        }
        .background(baseBg)
        .ignoresSafeArea(.container, edges: .top)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
    }
}

extension StudioPageLayout where TrailingContent == StudioOverflowToolbar {
    public init(
        title: String,
        toolbar: [StudioToolbarItem],
        @ViewBuilder content: () -> BodyContent
    ) {
        self.init(
            title: title,
            trailing: { StudioOverflowToolbar(items: toolbar) },
            content: content
        )
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

// MARK: - 2. 现代卡片容器 (静态黑白高对比纯静卡片 + 清晰分区标题 + 1px 细分割线)
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
    
    public var body: some View {
        let isLight = appState.isLightAppearance
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
                        
                        HStack(spacing: 8) {
                            headerTrailing
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        HStack(spacing: 8) {
                            headerTrailing
                        }
                    }
                }
                
                Rectangle()
                    .fill(StudioPalette.hairline(isLight: isLight))
                    .frame(height: 1)
            }
            
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            cardShape
                .fill(StudioPalette.cardBg(isLight: isLight))
        )
        .overlay(
            cardShape
                .stroke(StudioPalette.cardBorder(isLight: isLight), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isLight ? 0.04 : 0.0), radius: 5, x: 0, y: 1.5)
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

// MARK: - 3. 分段胶囊选择器 (StudioSegmentedPicker - 静态高对比版)
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
    @Binding public var selection: T
    public let options: [StudioSegmentedOption<T>]
    @Namespace private var glassNS
    
    public init(selection: Binding<T>, options: [StudioSegmentedOption<T>]) {
        self._selection = selection
        self.options = options
    }
    
    public var body: some View {
        let isLight = appState.isLightAppearance
        GlassEffectContainer(spacing: 3) {
            StudioFlowLayout(horizontalSpacing: 3, verticalSpacing: 4) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, opt in
                    let isSelected = (selection == opt.value)
                    Button(action: {
                        withAnimation(.snappy(duration: 0.22)) {
                            selection = opt.value
                        }
                    }) {
                        Text(opt.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 11)
                            .frame(height: 24)
                            .foregroundColor(isSelected ? .white : .primary.opacity(0.88))
                            .glassEffect(
                                isSelected
                                    ? StudioGlassSupport.buttonGlass(
                                        appState: appState,
                                        tint: opt.tint,
                                        prominent: true,
                                        interactive: true
                                    )
                                    : .identity,
                                in: Capsule(style: .continuous)
                            )
                            .glassEffectID(isSelected ? "sel_\(index)" : "item_\(index)", in: glassNS)
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .glassEffect(
                StudioGlassSupport.buttonGlass(appState: appState, interactive: true),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(
                        StudioGlassSupport.specularRimColor(isLight: isLight, appState: appState),
                        lineWidth: 0.75
                    )
            )
        }
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
    }
}

// MARK: - 4. 物种切换胶囊 (SpeciesSwitchBar - macOS 26/27 原生 Liquid Glass HDR)
public struct SpeciesSwitchBar: View {
    @ObservedObject private var appState = AppState.shared
    @Binding public var species: TargetSpecies
    public var onChanged: (() -> Void)? = nil
    @Namespace private var glassNS
    
    public init(species: Binding<TargetSpecies>, onChanged: (() -> Void)? = nil) {
        self._species = species
        self.onChanged = onChanged
    }
    
    public var body: some View {
        let isLight = appState.isLightAppearance
        GlassEffectContainer(spacing: 3) {
            HStack(spacing: 3) {
                ForEach(TargetSpecies.allCases) { spec in
                    let isSelected = (species == spec)
                    let color: Color = (spec == .human) ? .blue : .orange
                    Button(action: {
                        if species != spec {
                            withAnimation(.snappy(duration: 0.22)) {
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
                            .glassEffect(
                                isSelected
                                    ? StudioGlassSupport.buttonGlass(
                                        appState: appState,
                                        tint: color,
                                        prominent: true,
                                        interactive: true
                                    )
                                    : .identity,
                                in: Capsule(style: .continuous)
                            )
                            .glassEffectID(spec.rawValue, in: glassNS)
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .frame(height: 30)
            .glassEffect(
                StudioGlassSupport.buttonGlass(appState: appState, interactive: true),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        StudioGlassSupport.specularRimColor(isLight: isLight, appState: appState),
                        lineWidth: 0.75
                    )
            )
        }
        .fixedSize(horizontal: true, vertical: false)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
    }
}

// MARK: - 5. 参数微徽章 (静态黑白高对比版)
public struct StudioMetricBadge: View {
    @ObservedObject private var appState = AppState.shared
    public let label: String
    public let value: String
    public let color: Color
    
    public init(label: String, value: String, color: Color = .blue) {
        self.label = label
        self.value = value
        self.color = color
    }
    
    public var body: some View {
        let isLight = appState.isLightAppearance
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
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(isLight ? 0.11 : 0.18))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(color.opacity(0.28), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - 6. 序列编辑器 (13pt 等宽大字号 + 内嵌粘贴/导入连体胶囊按钮)
public struct SequenceEditorBox: View {
    @ObservedObject private var appState = AppState.shared
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
        let isLight = appState.isLightAppearance
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: minHeight)
                .background(isLight ? Color.black.opacity(0.028) : Color.black.opacity(0.32))
                .clipShape(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                        .stroke(
                            isDropTargeted ? Color.accentColor : StudioPalette.controlBorder(isLight: isLight),
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

// MARK: - 8. 质粒预览开关 (统一 30pt 胶囊 + macOS 26/27 原生 Liquid Glass HDR)
public struct PlasmidPreviewToggle: View {
    @ObservedObject private var appState = AppState.shared
    @Binding public var isOn: Bool
    public let isAvailable: Bool
    
    public init(isOn: Binding<Bool>, isAvailable: Bool = true) {
        self._isOn = isOn
        self.isAvailable = isAvailable
    }
    
    public var body: some View {
        let isLight = appState.isLightAppearance
        let active = (isOn && isAvailable)
        let borderColor = StudioGlassSupport.specularRimColor(
            isLight: isLight,
            tint: active ? .cyan : nil,
            selected: active,
            appState: appState
        )
        Button(action: {
            isOn.toggle()
        }) {
            HStack(spacing: 4) {
                Image(systemName: active ? "circle.circle.fill" : "circle.circle")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(active ? StudioGlassSupport.hdrColor(.cyan, exposure: 0.30, appState: appState) : (isAvailable ? .primary : .secondary))
                
                Text("图谱")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(active ? .primary : .secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .glassEffect(
                StudioGlassSupport.buttonGlass(
                    appState: appState,
                    tint: active ? .cyan : nil,
                    selected: active,
                    interactive: true
                ),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 0.75)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 1.0 : 0.78)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
        .help("切换质粒图谱预览抽屉")
    }
}

// MARK: - 9. 模块分区清除按钮 (30×30 圆形图标胶囊 + Liquid Glass HDR)
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
        let isLight = appState.isLightAppearance
        let borderColor = StudioGlassSupport.specularRimColor(
            isLight: isLight,
            tint: .red,
            disabled: isDisabled,
            appState: appState
        )
        Button(action: action) {
            Image(systemName: isResetIcon ? "arrow.counterclockwise" : "trash")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isDisabled ? .secondary.opacity(0.40) : StudioGlassSupport.hdrColor(.red, exposure: 0.22, appState: appState).opacity(0.95))
                .frame(width: 30, height: 30)
                .glassEffect(
                    StudioGlassSupport.buttonGlass(
                        appState: appState,
                        tint: .red,
                        disabled: isDisabled,
                        interactive: !isDisabled
                    ),
                    in: Circle()
                )
                .overlay(
                    Circle()
                        .stroke(borderColor, lineWidth: 0.75)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
        .help(title)
    }
}

// MARK: - 10. Finder 快捷交互组件 (30×30 圆形图标胶囊 + Liquid Glass HDR)
public struct FinderRevealButton: View {
    @ObservedObject private var appState = AppState.shared
    public let filePath: String
    public var label: String = "Finder"
    
    public init(filePath: String, label: String = "Finder") {
        self.filePath = filePath
        self.label = label
    }
    
    public var body: some View {
        let isLight = appState.isLightAppearance
        let iconOnly = label.isEmpty || label == "Finder"
        let borderColor = StudioGlassSupport.specularRimColor(isLight: isLight, appState: appState)
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
            .frame(minWidth: iconOnly ? 30 : nil)
            .frame(height: 30)
            .glassEffect(
                StudioGlassSupport.buttonGlass(appState: appState, interactive: true),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 0.75)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
        .help("在 Finder 中定位: \(filePath)")
    }
}

// MARK: - 10B. 高辨识度主操作按钮 (34pt 全胶囊主按钮 + macOS 26/27 原生 Liquid Glass HDR)
public struct StudioPrimaryActionButton: View {
    @ObservedObject private var appState = AppState.shared
    public let title: String
    public var icon: String = "sparkles"
    public var tint: Color = .blue
    public var isLoading: Bool = false
    public var isDisabled: Bool = false
    public var fillWidth: Bool = false
    public let action: () -> Void
    
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
        let isLight = appState.isLightAppearance
        let inactive = isDisabled || isLoading
        let borderColor = StudioGlassSupport.specularRimColor(
            isLight: isLight,
            tint: tint,
            prominent: true,
            disabled: isDisabled,
            appState: appState
        )
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
            .foregroundColor(.white.opacity(isDisabled ? 0.55 : 1.0))
            .padding(.horizontal, 18)
            .frame(height: 34)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .glassEffect(
                StudioGlassSupport.buttonGlass(
                    appState: appState,
                    tint: tint,
                    prominent: true,
                    disabled: isDisabled,
                    interactive: !inactive
                ),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 0.75)
            )
            .shadow(
                color: isDisabled ? .clear : StudioGlassSupport.hdrColor(tint, exposure: 0.25, appState: appState).opacity(0.24),
                radius: 6,
                x: 0,
                y: 2
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(inactive)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
    }
}

/// 顶栏合并式质粒文件胶囊（统一 30pt Capsule 高度 + macOS 26/27 原生 Liquid Glass HDR）
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
        let isLight = appState.isLightAppearance
        let isLoaded = (info != nil || isDropTargeted)
        let borderColor = StudioGlassSupport.specularRimColor(
            isLight: isLight,
            tint: isLoaded ? tint : nil,
            selected: isDropTargeted,
            appState: appState
        )
        GlassEffectContainer(spacing: 0) {
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
                            .foregroundColor(info != nil ? StudioGlassSupport.hdrColor(tint, exposure: 0.25, appState: appState) : .primary)
                        Text(info != nil ? info!.fileName.replacingOccurrences(of: ".dna", with: "") : roleTitle)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(info != nil ? "更换\(roleTitle)文件 (当前: \(info!.fileName))" : "从 Finder 选择或拖入\(roleTitle) .dna 文件")
                
                if !poolManager.items.isEmpty {
                    Rectangle()
                        .fill(StudioPalette.hairline(isLight: isLight))
                        .frame(width: 1, height: 15)
                    
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
                            .frame(height: 30)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("从质粒池选择\(roleTitle)")
                }
                
                if let loaded = info {
                    Rectangle()
                        .fill(StudioPalette.hairline(isLight: isLight))
                        .frame(width: 1, height: 15)
                    
                    Button(action: onPreview) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 11))
                            .foregroundColor(tint)
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("预览\(roleTitle)质粒图谱")
                    
                    Rectangle()
                        .fill(StudioPalette.hairline(isLight: isLight))
                        .frame(width: 1, height: 15)
                    
                    Button(action: {
                        FinderFileDropHelper.revealInFinder(path: loaded.filePath)
                    }) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("在 Finder 中定位: \(loaded.filePath)")
                }
            }
            .glassEffect(
                StudioGlassSupport.buttonGlass(
                    appState: appState,
                    tint: isLoaded ? tint : nil,
                    selected: isDropTargeted,
                    interactive: true
                ),
                in: Capsule(style: .continuous)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: isDropTargeted ? 1.5 : 0.75)
            )
        }
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
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
