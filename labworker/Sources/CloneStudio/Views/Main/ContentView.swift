import CloneStudioCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 沉浸式窗口配置器：开启全尺寸内容视图，安全清理右侧工作区上方的系统标题栏装饰并消除布局反馈环与空闲重绘闪烁
private struct ImmersiveWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowConfigNSView()
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowConfigNSView)?.scheduleTitlebarSanitization()
    }
    
    private final class WindowConfigNSView: NSView {
        private weak var configuredWindow: NSWindow?
        private var isSanitizeScheduled: Bool = false
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindowIfNeeded()
        }
        
        private func configureWindowIfNeeded() {
            guard let window = self.window else { return }
            if configuredWindow !== window {
                configuredWindow = window
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
                window.titlebarAppearsTransparent = true
                window.titlebarSeparatorStyle = .none
                window.titleVisibility = .hidden
                window.toolbar = nil
                window.isOpaque = false
                window.backgroundColor = .clear
                window.isMovableByWindowBackground = false
                // 确保新开/恢复窗口时默认不存在被自动强抢的 TextField 光标闪烁
                window.autorecalculatesKeyViewLoop = false
                if window.firstResponder is NSText || window.firstResponder is NSTextField {
                    window.makeFirstResponder(nil)
                }
                
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleWindowEvent(_:)),
                    name: NSWindow.didResizeNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(handleWindowEvent(_:)),
                    name: NSWindow.didBecomeKeyNotification,
                    object: window
                )
            }
            scheduleTitlebarSanitization()
        }
        
        @objc private func handleWindowEvent(_ notification: Notification) {
            scheduleTitlebarSanitization()
        }
        
        func scheduleTitlebarSanitization() {
            guard !isSanitizeScheduled else { return }
            isSanitizeScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isSanitizeScheduled = false
                self.sanitizeTitlebarIfNeeded()
            }
        }
        
        private func sanitizeTitlebarIfNeeded() {
            guard let window = self.window,
                  let closeBtn = window.standardWindowButton(.closeButton),
                  let titlebarView = closeBtn.superview else { return }
            
            if !titlebarView.wantsLayer {
                titlebarView.wantsLayer = true
            }
            if titlebarView.layer?.backgroundColor != NSColor.clear.cgColor {
                titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
            }
            
            // 仅在状态未就绪时隐藏装饰/毛玻璃子视图，避免重复标脏图层
            for sub in titlebarView.subviews where !(sub is NSButton) {
                if !sub.isHidden { sub.isHidden = true }
                if sub.alphaValue != 0 { sub.alphaValue = 0 }
            }
            
            if let container = titlebarView.superview {
                if !container.wantsLayer {
                    container.wantsLayer = true
                }
                if container.layer?.backgroundColor != NSColor.clear.cgColor {
                    container.layer?.backgroundColor = NSColor.clear.cgColor
                }
                for sub in container.subviews where sub !== titlebarView {
                    if !sub.isHidden { sub.isHidden = true }
                    if sub.alphaValue != 0 { sub.alphaValue = 0 }
                }
                // 异步一次将标题栏容器限制在左侧红黄绿按钮区域 (100pt)，绝不在 layout() 中同步改帧引起抖动
                if abs(container.frame.width - 100) > 1.0 && container.frame.width > 110 {
                    var f = container.frame
                    f.size.width = 100
                    container.frame = f
                }
            }
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

/// 主窗口视图 (macOS 系统磨砂侧边栏 + macOS 27 Liquid Glass HDR 搜索框与按钮 + 静态黑白工作区)
public struct ContentView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var plasmidPool = PlasmidPoolManager.shared
    @State private var isWindowDropTargeted: Bool = false
    @State private var searchFocusTrigger: Int = 0
    @State private var liveSidebarWidth: CGFloat = AppState.shared.sidebarWidth
    @State private var dragStartSidebarWidth: CGFloat? = nil
    @State private var isHoveringSplitter: Bool = false
    @State private var isResizeCursorActive: Bool = false
    
    public init() {}
    
    @ViewBuilder
    private var mainWorkspaceBackground: some View {
        StudioPalette.workspaceBg(isLight: appState.isLightAppearance)
            .ignoresSafeArea(.container, edges: .top)
    }
    
    private var subtleHairlineColor: Color {
        Color(nsColor: .separatorColor)
    }

    private func setResizeCursorActive(_ active: Bool) {
        if active && !isResizeCursorActive {
            NSCursor.resizeLeftRight.push()
            isResizeCursorActive = true
        } else if !active && isResizeCursorActive {
            NSCursor.pop()
            isResizeCursorActive = false
        }
    }
    
    public var body: some View {
        GeometryReader { proxy in
            let minSidebarW: CGFloat = 188
            let minDetailW: CGFloat = 460
            let maxSidebarW: CGFloat = max(minSidebarW, min(380, proxy.size.width - minDetailW))
            let resolvedSidebarWidth = min(maxSidebarW, max(minSidebarW, liveSidebarWidth))

            HStack(spacing: 0) {
                sidebarContent
                    .frame(width: resolvedSidebarWidth)
                    .background(
                        VisualEffectBlurView(
                            material: .sidebar,
                            blendingMode: .behindWindow,
                            state: .active
                        )
                        .ignoresSafeArea(.container, edges: .top)
                    )

                // 右侧主工作区：自适应剩余宽度（侧边栏拖拽拉伸绝不挤压/裁剪内容）+ 单一像素级对齐分割线
                VStack(spacing: 0) {
                    detailContent
                        .animation(nil, value: appState.selectedNav)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(mainWorkspaceBackground)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(
                            (isHoveringSplitter || dragStartSidebarWidth != nil)
                            ? appState.accentTheme.color.opacity(0.65)
                            : subtleHairlineColor
                        )
                        .frame(width: (isHoveringSplitter || dragStartSidebarWidth != nil) ? 2.0 : 1.0)
                        .animation(.easeOut(duration: 0.12), value: isHoveringSplitter)
                        .allowsHitTesting(false)
                        .ignoresSafeArea(.container, edges: .top)
                        .overlay(alignment: .leading) {
                            Color.clear
                                .frame(width: 9)
                                .contentShape(Rectangle())
                                .offset(x: -4)
                                .onHover { hovering in
                                    isHoveringSplitter = hovering
                                    if dragStartSidebarWidth == nil {
                                        setResizeCursorActive(hovering)
                                    }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { value in
                                            let base = dragStartSidebarWidth ?? resolvedSidebarWidth
                                            if dragStartSidebarWidth == nil {
                                                dragStartSidebarWidth = resolvedSidebarWidth
                                            }
                                            setResizeCursorActive(true)
                                            let next = min(maxSidebarW, max(minSidebarW, base + value.translation.width))
                                            liveSidebarWidth = next
                                        }
                                        .onEnded { value in
                                            let base = dragStartSidebarWidth ?? resolvedSidebarWidth
                                            let finalW = min(maxSidebarW, max(minSidebarW, base + value.translation.width))
                                            liveSidebarWidth = finalW
                                            appState.sidebarWidth = finalW
                                            dragStartSidebarWidth = nil
                                            setResizeCursorActive(isHoveringSplitter)
                                        }
                                )
                                .onTapGesture(count: 2) {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        liveSidebarWidth = 232
                                        appState.sidebarWidth = 232
                                    }
                                }
                                .help("左右拖拽调整侧边栏宽度 · 双击恢复默认宽度")
                        }
                }
                .overlay(alignment: .top) {
                    if isWindowDropTargeted {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill.badge.plus")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                            Text("松开智能导入 (.dna / .ab1 / .tif / .pdb / .csv / .fasta) 直达对应工作台")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(appState.accentTheme.color.opacity(0.95))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        )
                        .shadow(color: appState.accentTheme.color.opacity(0.26), radius: 10, x: 0, y: 4)
                        .padding(.top, 18)
                    }
                }
                .overlay(alignment: .bottom) {
                    if appState.isShowingToast, let msg = appState.toastMessage {
                        toastBanner(message: msg)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isWindowDropTargeted) { providers in
                    FinderFileDropHelper.extractAllFileURLs(from: providers) { urls in
                        WorkspaceSessionManager.shared.handleFinderOpenURLs(urls)
                        Task {
                            await PlasmidPoolManager.shared.importFilesOrFolders(urls: urls, silent: true)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 740, minHeight: 460)
        .background(ImmersiveWindowConfigurator())
        .tint(appState.accentTheme.color)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
        .onChange(of: appState.sidebarWidth) { _, newWidth in
            if dragStartSidebarWidth == nil {
                liveSidebarWidth = newWidth
            }
        }
        .onChange(of: appState.appearanceMode) { _, newMode in
            CloneStudioApp.syncAppKitAppearance(mode: newMode, forceIconRefresh: false)
        }
        .onChange(of: appState.showStatusBarIcon) { _, isVisible in
            CloneStudioAppDelegate.shared?.syncStatusBarVisibility(isVisible: isVisible)
        }
        .onDisappear {
            setResizeCursorActive(false)
        }
    }
    
    // MARK: - 侧边栏列表（极简上移 + 原生 Liquid Glass 折射搜索框 + 顶部渐隐模糊 + 独立 Sanger 测序与 5 大分类）
    private var sidebarContent: some View {
        let isLight = appState.isLightAppearance
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 13) {
                sidebarCollapsibleSection(.cloning) {
                    sidebarRow(
                        item: .plasmidPool,
                        tint: .cyan,
                        badgeText: plasmidPool.items.isEmpty ? nil : "\(plasmidPool.items.count)"
                    )
                    sidebarRow(item: .entryClone, tint: .blue)
                    sidebarRow(item: .singleFragment, tint: .teal)
                    sidebarRow(item: .multiFragment, tint: .green)
                    sidebarRow(item: .mutagenesis, tint: .pink)
                    sidebarRow(item: .fragmentDeletion, tint: .purple)
                    sidebarRow(item: .sangerVerify, tint: .indigo)
                }

                sidebarCollapsibleSection(.targeting) {
                    sidebarRow(item: .sgRNADesign, tint: .cyan)
                    sidebarRow(item: .shRNADesign, tint: .indigo)
                    sidebarRow(item: .chopchopCompare, tint: .orange)
                }

                sidebarCollapsibleSection(.bioImaging) {
                    sidebarRow(item: .westernBlot, tint: .indigo)
                    sidebarRow(item: .gelFigure, tint: .cyan)
                }

                sidebarCollapsibleSection(.benchTools) {
                    sidebarRow(item: .plateDesigner, tint: .blue)
                    sidebarRow(item: .qpcrAnalysis, tint: .teal)
                    sidebarRow(item: .proteinWorkbench, tint: .blue)
                    sidebarRow(item: .dnaCalculator, tint: .purple)
                    sidebarRow(item: .sequenceTools, tint: .mint)
                }

                sidebarCollapsibleSection(.orderAndSettings) {
                    sidebarRow(
                        item: .orderCenter,
                        tint: .green,
                        badgeText: appState.primersCart.isEmpty ? nil : "\(appState.primersCart.count)"
                    )
                    sidebarRow(item: .settings, tint: .gray)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaBar(edge: .top, spacing: 0) {
            // 顶部原生 macOS 27 Liquid Glass 搜索胶囊 + 等高 30pt 快导圆形按钮（无默认抢焦闪烁光标）
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(
                                isLight
                                ? Color.primary.opacity(0.62)
                                : Color.white.opacity(0.76)
                            )

                        StudioNoAutoFocusSearchField(
                            placeholder: "搜索",
                            text: $appState.sidebarSearchText,
                            focusTrigger: $searchFocusTrigger
                        )

                        if !appState.sidebarSearchText.isEmpty {
                            Button(action: {
                                appState.sidebarSearchText = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity)
                    .contentShape(Capsule(style: .continuous))
                    .onTapGesture {
                        searchFocusTrigger &+= 1
                    }
                    .glassEffect(
                        StudioGlassSupport.buttonGlass(
                            appState: appState,
                            tint: nil,
                            selected: false,
                            interactive: true
                        ),
                        in: Capsule(style: .continuous)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                StudioGlassSupport.specularRimColor(
                                    isLight: isLight,
                                    tint: nil,
                                    selected: false,
                                    appState: appState
                                ),
                                lineWidth: 0.9
                            )
                            .allowsHitTesting(false)
                    )

                    Button(action: {
                        CloneStudioApp.presentOpenDNAFilesPanel()
                    }) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .studioGlassButton(
                        tint: nil,
                        isCircle: true,
                        controlSize: .large
                    )
                    .help("导入实验文件 (.dna / .ab1 / .tif / .pdb / .csv / .fasta)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 38)
            .padding(.bottom, 8)
            .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
        }
        .ignoresSafeArea(.container, edges: .top)
    }
    
    @ViewBuilder
    private func sidebarCollapsibleSection<Content: View>(
        _ section: SidebarSectionKind,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let query = appState.sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !query.isEmpty
        let hasMatches = NavItem.allCases.contains { item in
            item.section == section && (isSearching ? item.matchesSearch(query) : appState.isNavItemVisible(item))
        }
        
        if hasMatches {
            let isExpanded = appState.isSidebarSectionExpanded(section)
            VStack(alignment: .leading, spacing: 3) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        appState.toggleSidebarSection(section)
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.78))
                            .frame(width: 12, alignment: .center)
                        
                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                if isExpanded {
                    content()
                }
            }
        }
    }
    
    @ViewBuilder
    private func sidebarRow(
        item: NavItem,
        tint: Color,
        badgeText: String? = nil
    ) -> some View {
        let query = appState.sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldShow = !query.isEmpty ? item.matchesSearch(query) : appState.isNavItemVisible(item)
        if shouldShow {
            let isSelected = (appState.selectedNav == item)
            Button(action: {
                appState.selectedNav = item
            }) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(0.94))
                            .frame(width: 23, height: 23)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(isSelected ? 0.45 : 0.16), lineWidth: 0.75)
                            )
                        Image(systemName: item.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    
                    Text(item.title)
                        .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Spacer(minLength: 4)
                    
                    if let badge = badgeText {
                        Text(badge)
                            .font(.system(size: 11, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(isSelected ? appState.accentTheme.color : .secondary)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(isSelected ? Color.white : Color.primary.opacity(0.09))
                            )
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? appState.accentTheme.color : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - 主内容展示区
    @ViewBuilder
    private var detailContent: some View {
        switch appState.selectedNav {
        case .plasmidPool:
            PlasmidPoolView()
        case .entryClone:
            EntryCloneView()
        case .singleFragment:
            SingleFragmentCloneView()
        case .multiFragment:
            MultiFragmentCloneView()
        case .mutagenesis:
            MutationView()
        case .fragmentDeletion:
            FragmentDeletionView()
        case .sangerVerify:
            SangerVerificationView()
        case .sgRNADesign:
            SgRNADesignView()
        case .shRNADesign:
            ShRNADesignView()
        case .chopchopCompare:
            CHOPCHOPWebView()
        case .dnaCalculator:
            RestructureCalculatorView()
        case .sequenceTools:
            SequenceToolsView()
        case .plateDesigner:
            PlateDesignerView()
        case .qpcrAnalysis:
            QPCRAnalysisView()
        case .westernBlot:
            WesternBlotView()
        case .gelFigure:
            GelFigureEditorView()
        case .proteinWorkbench:
            ProteinWorkbenchView()
        case .orderCenter:
            OrderExportView()
        case .settings:
            SettingsView()
        }
    }
    
    // MARK: - 浮动提示通知
    private func toastBanner(message: String) -> some View {
        let isLight = appState.isLightAppearance
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(StudioGlassSupport.hdrColor(.green, exposure: 0.32, appState: appState))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(
            StudioGlassSupport.buttonGlass(
                appState: appState,
                tint: .green,
                selected: true,
                interactive: true
            ),
            in: Capsule(style: .continuous)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    StudioGlassSupport.specularRimColor(
                        isLight: isLight,
                        tint: .green,
                        selected: true,
                        appState: appState
                    ),
                    lineWidth: 0.75
                )
        )
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 4)
        .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
        .padding(.bottom, 20)
    }
}
