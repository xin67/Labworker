import CloneStudioCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 沉浸式窗口配置器：开启全尺寸内容视图，彻底移除右侧工作区上方的系统标题栏背景与悬停遮挡，仅保留左侧边栏顶部的原生红黄绿窗口按钮
private struct ImmersiveWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowConfigNSView()
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowConfigNSView)?.sanitizeTitlebarIfNeeded()
    }
    
    private final class WindowConfigNSView: NSView {
        private weak var configuredWindow: NSWindow?
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindowIfNeeded()
        }
        
        override func layout() {
            super.layout()
            sanitizeTitlebarIfNeeded()
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
                window.backgroundColor = .windowBackgroundColor
                window.isMovableByWindowBackground = false
                
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
            sanitizeTitlebarIfNeeded()
        }
        
        @objc private func handleWindowEvent(_ notification: Notification) {
            sanitizeTitlebarIfNeeded()
        }
        
        func sanitizeTitlebarIfNeeded() {
            guard let window = self.window,
                  let closeBtn = window.standardWindowButton(.closeButton),
                  let titlebarView = closeBtn.superview else { return }
            
            titlebarView.wantsLayer = true
            titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
            
            // 隐藏标题栏内部除红黄绿标准按钮以外的所有装饰/毛玻璃背景视图，彻底消除鼠标悬停在上方时的黑条遮挡
            for sub in titlebarView.subviews where !(sub is NSButton) {
                sub.isHidden = true
                sub.alphaValue = 0
            }
            
            if let container = titlebarView.superview {
                container.wantsLayer = true
                container.layer?.backgroundColor = NSColor.clear.cgColor
                for sub in container.subviews where sub !== titlebarView {
                    sub.isHidden = true
                    sub.alphaValue = 0
                }
                // 将标题栏容器宽度限制在左侧红黄绿按钮区域 (100pt)，确保右侧主工作区上方零遮挡、零事件拦截
                if container.frame.width > 110 {
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

/// 主窗口视图 (macOS 系统磨砂侧边栏 + 顶部胶囊搜索框 + 静态黑白高对比右栏工作区)
public struct ContentView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var plasmidPool = PlasmidPoolManager.shared
    @State private var isWindowDropTargeted: Bool = false
    
    public init() {}
    
    @ViewBuilder
    private var mainWorkspaceBackground: some View {
        StudioPalette.workspaceBg(isLight: appState.isLightAppearance)
            .ignoresSafeArea(.container, edges: .top)
    }
    
    private var subtleHairlineColor: Color {
        appState.isLightAppearance
            ? Color.black.opacity(0.08)
            : Color.white.opacity(0.10)
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            sidebarContent
                .frame(width: 232)
                .background(
                    ZStack {
                        VisualEffectBlurView(
                            material: .sidebar,
                            blendingMode: .behindWindow,
                            state: .active
                        )
                        Color.primary.opacity(appState.isLightAppearance ? 0.015 : 0.03)
                    }
                    .ignoresSafeArea(.container, edges: .top)
                )
            
            // 右侧主工作区：纯净静态白/黑渲染 + 系统级顶部模糊栏
            VStack(spacing: 0) {
                detailContent
                    .animation(nil, value: appState.selectedNav)
                    .frame(minWidth: 540, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
            }
            .background(mainWorkspaceBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(subtleHairlineColor)
                    .frame(width: 1)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .overlay(alignment: .top) {
                if isWindowDropTargeted {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill.badge.plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                        Text("松开智能导入 (.dna / .ab1 / .tif / .pdb / .nwk / .csv / .fasta) 直达对应工作台")
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
        .background(ImmersiveWindowConfigurator())
        .tint(appState.accentTheme.color)
        .onChange(of: appState.appearanceMode) { _, newMode in
            CloneStudioApp.syncAppKitAppearance(mode: newMode, forceIconRefresh: false)
        }
        .onChange(of: appState.showStatusBarIcon) { _, isVisible in
            CloneStudioAppDelegate.shared?.syncStatusBarVisibility(isVisible: isVisible)
        }
    }
    
    // MARK: - 侧边栏列表（极简上移 + 滚动穿透系统设置风格模糊搜索框 + 独立 Sanger 测序与 5 大分类）
    private var sidebarContent: some View {
        let isLight = appState.isLightAppearance
        return ZStack(alignment: .top) {
            ScrollView(.vertical, showsIndicators: false) {
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
                        sidebarRow(item: .colonyCounter, tint: .orange)
                        sidebarRow(item: .figureAnnotator, tint: .pink)
                    }
                    
                    sidebarCollapsibleSection(.benchTools) {
                        sidebarRow(item: .plateDesigner, tint: .blue)
                        sidebarRow(item: .qpcrAnalysis, tint: .teal)
                        sidebarRow(item: .phylogeneticTree, tint: .green)
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
                .padding(.top, 78)
                .padding(.bottom, 12)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)

            // 顶部系统设置风格羽化毛玻璃帘（仅模糊红黄绿灯区并令滚动列表条目柔和穿透搜索框下方）
            VisualEffectBlurView(
                material: .sidebar,
                blendingMode: .withinWindow,
                state: .active
            )
            .frame(height: 80)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.92), location: 0.0),
                        .init(color: .black.opacity(0.76), location: 0.36),
                        .init(color: .black.opacity(0.24), location: 0.68),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)

            // 顶部上移胶囊搜索框 + 等高 30pt 快导圆形按钮
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.9))

                    TextField("搜索", text: $appState.sidebarSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))

                    if !appState.sidebarSearchText.isEmpty {
                        Button(action: {
                            appState.sidebarSearchText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: 30)
                .frame(maxWidth: .infinity)
                .background(
                    ZStack {
                        VisualEffectBlurView(
                            material: .headerView,
                            blendingMode: .withinWindow,
                            state: .active
                        )
                        Color.primary.opacity(isLight ? 0.045 : 0.085)
                    }
                    .clipShape(Capsule(style: .continuous))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            isLight ? Color.white.opacity(0.65) : Color.white.opacity(0.18),
                            lineWidth: 1
                        )
                )

                Button(action: {
                    CloneStudioApp.presentOpenDNAFilesPanel()
                }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(appState.accentTheme.color)
                        .frame(width: 30, height: 30)
                        .background(
                            ZStack {
                                VisualEffectBlurView(
                                    material: .headerView,
                                    blendingMode: .withinWindow,
                                    state: .active
                                )
                                appState.accentTheme.color.opacity(isLight ? 0.12 : 0.22)
                            }
                            .clipShape(Circle())
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    appState.accentTheme.color.opacity(isLight ? 0.30 : 0.38),
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("导入实验文件 (.dna / .ab1 / .tif / .pdb / .nwk / .csv / .fasta)")
            }
            .padding(.horizontal, 12)
            .padding(.top, 38)
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
                    
                    Spacer(minLength: 4)
                    
                    if let badge = badgeText {
                        Text(badge)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(isSelected ? appState.accentTheme.color : .secondary)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(isSelected ? Color.white : Color.primary.opacity(0.09))
                            )
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
        case .phylogeneticTree:
            PhylogeneticTreeView()
        case .colonyCounter:
            ColonyCounterView()
        case .westernBlot:
            WesternBlotView()
        case .gelFigure:
            GelFigureEditorView()
        case .figureAnnotator:
            FigureAnnotatorView()
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
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(appState.isLightAppearance ? Color.white : Color(red: 0.16, green: 0.17, blue: 0.18))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.green.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 4)
        .padding(.bottom, 20)
    }
}
