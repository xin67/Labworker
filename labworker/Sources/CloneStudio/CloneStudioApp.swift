import CloneStudioCore
import SwiftUI
import AppKit

/// macOS 应用生命周期代理：基于系统主题广播实现零延迟图标切换，并提供轻量级原生 NSStatusItem 状态栏入口
@MainActor
final class CloneStudioAppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: CloneStudioAppDelegate?
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        _ = PlasmidPoolManager.shared
        AppState.shared.systemIsLightAppearance = CloneStudioIconProvider.resolveIsLightAppearance(mode: .system)
        // 首屏窗口完成挂载后再异步恢复会话与同步图标，确保主窗口秒开零卡顿
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            WorkspaceSessionManager.shared.restoreSessionOnLaunchIfNeeded()
            CloneStudioApp.syncAppKitAppearance(mode: AppState.shared.appearanceMode, forceIconRefresh: false)
            self.syncStatusBarVisibility(isVisible: AppState.shared.showStatusBarIcon)
        }
        
        // 监听 macOS WindowServer 广播的全局主题切换通知
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSystemThemeChanged(_:)),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }
    
    @objc private func handleSystemThemeChanged(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            AppState.shared.systemIsLightAppearance = CloneStudioIconProvider.resolveIsLightAppearance(mode: .system)
            CloneStudioIconProvider.syncApplicationIcon(mode: AppState.shared.appearanceMode, force: false)
        }
    }
    
    func syncStatusBarVisibility(isVisible: Bool) {
        if isVisible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let btn = item.button {
                    btn.image = CloneStudioIconProvider.statusBarTemplateImage
                    btn.target = self
                    btn.action = #selector(toggleStatusPopover(_:))
                    btn.toolTip = "Labworker 实验随手算与快捷入口"
                }
                statusItem = item
            }
            statusItem?.isVisible = true
        } else {
            statusPopover?.performClose(nil)
            statusItem?.isVisible = false
        }
    }
    
    @objc private func toggleStatusPopover(_ sender: AnyObject?) {
        guard let btn = statusItem?.button else { return }
        if let pop = statusPopover, pop.isShown {
            pop.performClose(sender)
            return
        }
        let pop = statusPopover ?? {
            let p = NSPopover()
            p.behavior = .transient
            p.contentSize = NSSize(width: 340, height: 360)
            p.contentViewController = NSHostingController(
                rootView: CloneStudioStatusBarPopoverView(onImportFromFinder: {
                    CloneStudioApp.presentOpenDNAFilesPanel()
                })
            )
            self.statusPopover = p
            return p
        }()
        pop.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
    }
    
    /// 响应从 macOS Finder 双击、「打开方式 -> Labworker」或拖入 Dock 图标的文件列表
    func application(_ application: NSApplication, open urls: [URL]) {
        WorkspaceSessionManager.shared.handleFinderOpenURLs(urls)
        Task {
            await PlasmidPoolManager.shared.importFilesOrFolders(urls: urls, silent: true)
        }
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        WorkspaceSessionManager.shared.handleFinderOpenURLs([url])
        Task {
            await PlasmidPoolManager.shared.importFilesOrFolders(urls: [url], silent: true)
        }
        return true
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let session = WorkspaceSessionManager.shared
        guard session.hasActiveWorkspaceContent else {
            session.discardSnapshotOnCleanExit()
            return .terminateNow
        }
        
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "退出前是否保存当前工作进度？"
        alert.informativeText = "选择「保存并退出」，下次打开 Labworker 时将自动恢复当前各模块的质粒、序列与引物设计进度；若选择「不保存退出」，将清空本次临时进度。"
        alert.addButton(withTitle: "保存并退出")
        alert.addButton(withTitle: "不保存退出")
        alert.addButton(withTitle: "取消")
        
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            session.saveSnapshotOnCleanExit()
            return .terminateNow
        case .alertSecondButtonReturn:
            session.discardSnapshotOnCleanExit()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}

@main
struct CloneStudioApp: App {
    @NSApplicationDelegateAdaptor(CloneStudioAppDelegate.self) private var appDelegate
    
    init() {
        ProcessInfo.processInfo.processName = "Labworker"
    }
    
    var body: some Scene {
        WindowGroup("Labworker") {
            ContentView()
                .onOpenURL { url in
                    WorkspaceSessionManager.shared.handleFinderOpenURLs([url])
                    Task {
                        await PlasmidPoolManager.shared.importFilesOrFolders(urls: [url], silent: true)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("从 Finder 智能打开实验文件 (.dna / .tif / .pdb / .nwk / .csv)...") {
                    Self.presentOpenDNAFilesPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
                
                Button("保存当前工作进度") {
                    WorkspaceSessionManager.shared.autoSaveInBackground()
                    AppState.shared.showToast("已保存当前工作区进度")
                }
                .keyboardShortcut("s", modifiers: [.command])
                
                Divider()
                
                Button("清空当前模块") {
                    clearCurrentActiveModule()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
            
            CommandGroup(after: .toolbar) {
                Button("显示 / 隐藏质粒图谱") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        AppState.shared.showPlasmidPreview.toggle()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command])
                
                Button("切换 3bp 密码子吸附") {
                    AppState.shared.defaultSnapToCodonMode.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            
            CommandMenu("功能模块") {
                Section("分子克隆与质粒") {
                    Button("质粒池 & 载体库") { AppState.shared.selectedNav = .plasmidPool }
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                    Button("入门克隆设计") { AppState.shared.selectedNav = .entryClone }
                        .keyboardShortcut("1", modifiers: [.command])
                    Button("单片段同源重组/酶切") { AppState.shared.selectedNav = .singleFragment }
                        .keyboardShortcut("2", modifiers: [.command])
                    Button("多片段无缝组装") { AppState.shared.selectedNav = .multiFragment }
                        .keyboardShortcut("3", modifiers: [.command])
                    Button("定点突变设计") { AppState.shared.selectedNav = .mutagenesis }
                        .keyboardShortcut("4", modifiers: [.command])
                    Button("质粒片段删除") { AppState.shared.selectedNav = .fragmentDeletion }
                        .keyboardShortcut("5", modifiers: [.command])
                    Button("Sanger 测序比对验证") { AppState.shared.selectedNav = .sangerVerify }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }
                
                Divider()
                
                Section("基因编辑与靶点") {
                    Button("sgRNA (CRISPR) 设计") { AppState.shared.selectedNav = .sgRNADesign }
                        .keyboardShortcut("6", modifiers: [.command])
                    Button("shRNA (RNAi) 设计") { AppState.shared.selectedNav = .shRNADesign }
                        .keyboardShortcut("7", modifiers: [.command])
                    Button("CHOPCHOP 靶点对比") { AppState.shared.selectedNav = .chopchopCompare }
                }
                
                Divider()
                
                Section("电泳与图像定量") {
                    Button("WB 灰度定量 (16-bit)") { AppState.shared.selectedNav = .westernBlot }
                        .keyboardShortcut("w", modifiers: [.command, .shift])
                    Button("凝胶分子量回归") { AppState.shared.selectedNav = .gelFigure }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                    Button("菌落计数器 (CFU)") { AppState.shared.selectedNav = .colonyCounter }
                    Button("科研多图拼版") { AppState.shared.selectedNav = .figureAnnotator }
                }
                
                Divider()
                
                Section("定量、进化与蛋白") {
                    Button("微孔板布局设计") { AppState.shared.selectedNav = .plateDesigner }
                    Button("qPCR 荧光定量") { AppState.shared.selectedNav = .qpcrAnalysis }
                        .keyboardShortcut("q", modifiers: [.command, .shift])
                    Button("系统发育树") { AppState.shared.selectedNav = .phylogeneticTree }
                    Button("蛋白质工作台 (3D/理化)") { AppState.shared.selectedNav = .proteinWorkbench }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                    Button("DNA 摩尔/体系计算器") { AppState.shared.selectedNav = .dnaCalculator }
                        .keyboardShortcut("8", modifiers: [.command])
                    Button("序列与 Tm 工具") { AppState.shared.selectedNav = .sequenceTools }
                        .keyboardShortcut("9", modifiers: [.command])
                }
                
                Divider()
                
                Section("合成订购与设置") {
                    Button("商业订购中心") { AppState.shared.selectedNav = .orderCenter }
                        .keyboardShortcut("0", modifiers: [.command])
                    Button("系统设置") { AppState.shared.selectedNav = .settings }
                }
            }
        }
        
        Settings {
            SettingsView()
                .frame(minWidth: 820, minHeight: 560)
        }
    }
    
    @MainActor
    public static func presentOpenDNAFilesPanel() {
        FinderFileDropHelper.presentOpenPanel { url in
            WorkspaceSessionManager.shared.handleFinderOpenURLs([url])
            Task {
                await PlasmidPoolManager.shared.importFilesOrFolders(urls: [url], silent: true)
            }
        }
    }
    
    @MainActor
    private func clearCurrentActiveModule() {
        let session = WorkspaceSessionManager.shared
        switch AppState.shared.selectedNav {
        case .plasmidPool:
            PlasmidPoolManager.shared.clearAll()
        case .entryClone:
            session.entryCloneVM.clear()
        case .singleFragment:
            session.singleFragmentVM.clear()
        case .multiFragment:
            session.multiFragmentVM.clear()
        case .mutagenesis:
            session.mutagenesisVM.clear()
        case .fragmentDeletion:
            session.fragmentDeletionVM.clear()
        case .sgRNADesign:
            session.sgRNAVM.clear()
        case .shRNADesign:
            session.shRNAVM.clear()
        case .chopchopCompare:
            session.chopchopVM.clear()
        default:
            break
        }
    }
    
    @MainActor
    public static func syncAppKitAppearance(mode: AppAppearanceMode, forceIconRefresh: Bool = false) {
        let targetAppearance: NSAppearance?
        switch mode {
        case .system:
            targetAppearance = nil
        case .light:
            targetAppearance = NSAppearance(named: .aqua)
        case .dark:
            targetAppearance = NSAppearance(named: .darkAqua)
        }
        if NSApplication.shared.appearance?.name != targetAppearance?.name {
            NSApplication.shared.appearance = targetAppearance
        }
        CloneStudioIconProvider.syncApplicationIcon(mode: mode, force: forceIconRefresh)
    }
}
