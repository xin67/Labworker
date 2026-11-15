import SwiftUI
import AppKit
import CloneStudioCore

/// Labworker 系统设置面板（四段式极简响应式布局：① 参数与外观 ② 侧边栏定制 ③ MCP 服务 ④ 全局说明书）
public struct SettingsView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var pool = PlasmidPoolManager.shared

    @State private var activeTab: SettingsSubTab = .preferences
    @State private var manualSearchQuery: String = ""
    @State private var selectedManualSection: SidebarSectionKind? = nil

    public enum SettingsSubTab: String, CaseIterable, Identifiable {
        case preferences = "preferences"
        case sidebarCustomization = "sidebarCustomization"
        case mcpService = "mcpService"
        case featureManual = "featureManual"

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .preferences:          return "参数与外观"
            case .sidebarCustomization: return "侧边栏定制"
            case .mcpService:           return "MCP 服务"
            case .featureManual:        return "全局说明书"
            }
        }
    }

    public init() {}

    public var body: some View {
        StudioPageLayout(
            title: "系统设置与功能说明书",
            toolbar: [
                .picker(
                    id: "settings_tab",
                    label: "设置分页",
                    options: SettingsSubTab.allCases.map { tab in
                        StudioToolbarPickerOption(
                            id: tab.title,
                            title: tab.title,
                            tint: .blue,
                            isSelected: activeTab == tab
                        ) {
                            activeTab = tab
                        }
                    }
                ),
                .action(
                    groupKey: nil,
                    title: "恢复默认",
                    icon: "arrow.counterclockwise",
                    help: "将全部外观与实验默认参数恢复为出厂默认值",
                    action: appState.resetSettingsToDefaults
                )
            ]
        ) {
            switch activeTab {
            case .preferences:
                preferencesWorkspaceView
            case .sidebarCustomization:
                sidebarCustomizationWorkspaceView
            case .mcpService:
                mcpServiceWorkspaceView
            case .featureManual:
                featureManualWorkspaceView
            }
        }
        .onAppear {
            appState.refreshSystemAppearancePreferences()
        }
    }

    // MARK: - 子页面 ①：默认参数与外观（保持极简双栏响应式布局）

    private var preferencesWorkspaceView: some View {
        AdaptiveTwoColumnWorkspace(breakpoint: 820) {
            VStack(alignment: .leading, spacing: 12) {
                appearanceCard
                cloningDefaultsCard
                benchAndImagingDefaultsCard
                engineAndSnapGeneCard
            }
        } right: {
            VStack(alignment: .leading, spacing: 12) {
                plasmidAndSequenceMapCard
                proteinWorkbenchDefaultsCard
                labOrderProfileCard
            }
        }
    }

    // MARK: - 子页面 ②：侧边栏功能自定义显隐（自适应网格 + 快捷预设）

    private var sidebarCustomizationWorkspaceView: some View {
        let visibleCount = NavItem.allCases.filter { appState.isNavItemVisible($0) }.count
        let hiddenCount = appState.hiddenSidebarItems.count
        return VStack(alignment: .leading, spacing: 12) {
            StudioCard(title: "侧边栏模块可见性快捷方案") {
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                    StudioMetricBadge(
                        label: "侧边栏显示",
                        value: "\(visibleCount) / \(NavItem.allCases.count)",
                        color: visibleCount == NavItem.allCases.count ? .green : .orange
                    )
                    StudioMetricBadge(
                        label: "当前已隐藏",
                        value: "\(hiddenCount) 项",
                        color: hiddenCount == 0 ? .green : .orange
                    )
                }
            } content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("勾选需要在左侧导航栏常驻显示的工具模块；取消勾选即可隐藏不常用的功能（注：即使隐藏，仍可通过侧边栏搜索框、Finder 文件快导或「全局功能说明书」随时直达）。")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        ForEach(SidebarVisibilityPreset.allCases) { preset in
                            StudioActionPillButton(
                                title: preset.title,
                                icon: preset == .all ? "eye.fill" : "slider.horizontal.3",
                                tint: preset == .all ? .blue : .teal,
                                isProminent: preset == .all && hiddenCount > 0
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    appState.applySidebarVisibilityPreset(preset)
                                }
                            }
                        }
                    }
                }
            }

            // 按 5 大直觉分类展示自适应开关网格
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 620), spacing: 12)], spacing: 12) {
                ForEach(SidebarSectionKind.allCases) { section in
                    let sectionItems = NavItem.allCases.filter { $0.section == section }
                    let visibleInSec = sectionItems.filter { appState.isNavItemVisible($0) }.count

                    StudioCard(title: section.title) {
                        StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                            StudioMetricBadge(
                                label: "可见",
                                value: "\(visibleInSec)/\(sectionItems.count)",
                                color: visibleInSec > 0 ? .blue : .secondary
                            )
                            StudioCompactPillButton(title: "全选") {
                                for item in sectionItems {
                                    appState.setNavItemVisible(item, visible: true)
                                }
                            }

                            if section != .orderAndSettings {
                                StudioCompactPillButton(title: "全隐") {
                                    for item in sectionItems where item.canBeHiddenInSidebar {
                                        appState.setNavItemVisible(item, visible: false)
                                    }
                                }
                            }
                        }
                    } content: {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 240), spacing: 8)], spacing: 8) {
                            ForEach(sectionItems) { item in
                                let isVis = appState.isNavItemVisible(item)
                                HStack(spacing: 8) {
                                    Toggle(
                                        isOn: Binding(
                                            get: { appState.isNavItemVisible(item) },
                                            set: { newVal in
                                                withAnimation(.easeInOut(duration: 0.14)) {
                                                    appState.setNavItemVisible(item, visible: newVal)
                                                }
                                            }
                                        )
                                    ) {
                                        HStack(spacing: 6) {
                                            Image(systemName: item.systemImage)
                                                .font(.system(size: 11.5, weight: .semibold))
                                                .foregroundColor(isVis ? .accentColor : .secondary)
                                                .frame(width: 16)
                                            Text(item.title)
                                                .font(.system(size: 12, weight: isVis ? .semibold : .regular))
                                                .foregroundColor(isVis ? .primary : .secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .disabled(!item.canBeHiddenInSidebar)

                                    Spacer(minLength: 2)

                                    if !item.canBeHiddenInSidebar {
                                        Text("常驻")
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                        .fill(isVis ? Color.accentColor.opacity(0.08) : StudioPalette.controlSubtleBg(isLight: appState.isLightAppearance))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                                .stroke(StudioPalette.cardBorder(isLight: appState.isLightAppearance), lineWidth: 1)
                                        )
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 子页面 ③：MCP 智能体服务配置中心（集中式控制，不再散落于其他页面）

    private var mcpServiceWorkspaceView: some View {
        let tools = PlasmidPoolManager.mcpToolsCatalog
        return VStack(alignment: .leading, spacing: 12) {
            StudioResponsiveSplitLayout(breakpoint: 820, spacing: 12, leftRatio: 0.48) {
                StudioCard(title: "Labworker MCP Server 20261115 控制中心") {
                    StudioMetricBadge(label: "协议状态", value: "JSON-RPC 2.0 就绪", color: .green)
                } content: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("通过 Model Context Protocol (MCP) 标准协议，允许 Claude Desktop、Cursor、Windsurf、Cline 等外部 AI 客户端直接调用本机的全栈生物实验引擎，并将生成的引物、重组质粒、WB 定量或对接盒子实时回写至 Labworker 对应工作台画布。")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            StudioActionPillButton(
                                title: "一键注入 Claude / Cursor / Windsurf",
                                icon: "bolt.horizontal.circle.fill",
                                tint: .teal,
                                isProminent: true,
                                action: pool.installMCPToLocalAIClients
                            )
                            StudioActionPillButton(
                                title: "复制 MCP 配置 JSON",
                                icon: "doc.on.doc",
                                tint: .blue,
                                action: pool.copyMCPConfigToClipboard
                            )
                            StudioActionPillButton(
                                title: "手动刷新跨进程同步",
                                icon: "arrow.triangle.2.circlepath",
                                tint: .indigo,
                                action: pool.handleExternalMCPUpdate
                            )
                        }

                        if !pool.recentMCPSyncRecords.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("跨进程同步记录 (mcp_sync/done/ · 共 \(pool.recentMCPSyncRecords.count) 条)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                ForEach(pool.recentMCPSyncRecords.prefix(5)) { rec in
                                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 3) {
                                        StudioMetricBadge(label: "run_id", value: String(rec.runID.prefix(8)), color: .teal)
                                        StudioMetricBadge(label: "工具", value: rec.toolName, color: .blue)
                                        Text(rec.actionSummary)
                                            .font(.system(size: 11))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(rec.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.system(size: 10.5))
                                            .monospacedDigit()
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .studioInnerBox(paddingH: 8, paddingV: 6)
                                }
                            }
                        } else if let lastSync = pool.lastMCPActivitySummary {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("最近外部调用同步：\(lastSync)")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .studioInnerBox(tint: .green, paddingH: 10, paddingV: 8)
                        }
                    }
                }

                StudioCard(title: "标准客户端配置 JSON (mcpServers.labworker)") {
                    StudioMetricBadge(label: "工具总数", value: "\(tools.count) 项", color: .blue)
                } content: {
                    Text(pool.mcpConfigJSONString)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                .fill(StudioPalette.controlBg(isLight: appState.isLightAppearance))
                                .overlay(
                                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                        .stroke(StudioPalette.controlBorder(isLight: appState.isLightAppearance), lineWidth: 1)
                                )
                        )
                }
            }

            StudioCard(title: "已注册的 \(tools.count) 大全栈 MCP 实验工具清单") {
                StudioMetricBadge(label: "版本", value: "labworker-mcp 20261115", color: .teal)
            } content: {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 460), spacing: 10)], spacing: 10) {
                    ForEach(tools) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(t.name)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.accentColor)
                                    .lineLimit(1)
                                Spacer()
                                StudioMetricBadge(label: "", value: t.category, color: .secondary)
                            }
                            Text(t.summary)
                                .font(.system(size: 11.5))
                                .foregroundColor(.primary.opacity(0.88))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .studioInnerBox(paddingH: 10, paddingV: 9)
                    }
                }
            }
        }
    }

    // MARK: - 子页面 ④：全局功能说明书（支持检索、分类过滤、格式速查与一键直达）

    private var filteredManualItems: [NavItem] {
        NavItem.allCases.filter { item in
            if let sec = selectedManualSection, item.section != sec {
                return false
            }
            return item.matchesSearch(manualSearchQuery)
        }
    }

    private var featureManualWorkspaceView: some View {
        let items = filteredManualItems
        return VStack(alignment: .leading, spacing: 12) {
            StudioCard(title: "Labworker 全局功能说明书与文件格式速查") {
                StudioMetricBadge(
                    label: "匹配模块",
                    value: "\(items.count) / \(NavItem.allCases.count)",
                    color: .teal
                )
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    // 响应式检索与分类筛选条
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            TextField("搜索功能名称、算法关键词或文件格式 (如 .tif / .pdb / .dna / LIGSITE / ΔΔCt)...", text: $manualSearchQuery)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                            if !manualSearchQuery.isEmpty {
                                Button {
                                    manualSearchQuery = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .frame(minWidth: 240, maxWidth: 420)
                        .background(
                            Capsule(style: .continuous)
                                .fill(StudioPalette.controlBg(isLight: appState.isLightAppearance))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(StudioPalette.controlBorder(isLight: appState.isLightAppearance), lineWidth: 1)
                                )
                        )

                        categoryFilterPill(title: "全部 (\(NavItem.allCases.count))", section: nil)
                        ForEach(SidebarSectionKind.allCases) { sec in
                            categoryFilterPill(title: sec.title, section: sec)
                        }
                    }
                }
            }

            // 响应式说明书卡片网格（宽屏双列/三列，窄屏单列）
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 540), spacing: 12)], spacing: 12) {
                ForEach(items) { item in
                    let isVis = appState.isNavItemVisible(item)
                    VStack(alignment: .leading, spacing: 8) {
                        // 1. 卡片头部：图标 + 标题 + 所属分组徽章 + 操作按钮
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            HStack(spacing: 7) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.15))
                                        .frame(width: 24, height: 24)
                                    Image(systemName: item.systemImage)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }
                                Text(item.title)
                                    .font(.system(size: 13.5, weight: .bold))
                            }

                            StudioMetricBadge(label: "", value: item.section.title, color: .secondary)

                            if !isVis {
                                StudioMetricBadge(label: "", value: "已隐藏", color: .orange)
                            }

                            if item != .settings {
                                StudioCompactPillButton(
                                    title: "直达",
                                    icon: "arrow.up.right",
                                    tint: appState.accentTheme.color,
                                    help: "跳转到「\(item.title)」工作台"
                                ) {
                                    appState.selectedNav = item
                                }
                            }

                            if !isVis && item.canBeHiddenInSidebar {
                                StudioCompactPillButton(title: "恢复显示", tint: .orange) {
                                    appState.setNavItemVisible(item, visible: true)
                                }
                            }
                        }

                        // 2. 核心功能定位与算法说明
                        Text(item.summaryDescription)
                            .font(.system(size: 12))
                            .foregroundColor(.primary.opacity(0.90))
                            .fixedSize(horizontal: false, vertical: true)

                        // 3. 支持格式与实操提示
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top, spacing: 5) {
                                Text("支持格式:")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Text(item.supportedFormats)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.teal)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            HStack(alignment: .top, spacing: 5) {
                                Text("实操提示:")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Text(item.workflowTip)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .studioInnerBox(paddingH: 10, paddingV: 8)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                            .fill(StudioPalette.controlBg(isLight: appState.isLightAppearance))
                            .overlay(
                                RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                    .stroke(StudioPalette.cardBorder(isLight: appState.isLightAppearance), lineWidth: 1)
                            )
                    )
                }
            }
        }
    }

    private func categoryFilterPill(title: String, section: SidebarSectionKind?) -> some View {
        let isSelected = (selectedManualSection == section)
        return StudioCompactPillButton(
            title: title,
            tint: appState.accentTheme.color,
            isProminent: isSelected
        ) {
            selectedManualSection = section
        }
    }

    // MARK: - 原有 7 张默认参数配置卡片

    private var appearanceCard: some View {
        StudioCard(title: "1. 外观与主题") {
            StudioCompactPillButton(
                title: appState.isFollowingAllSystemAppearance ? "已跟随系统" : "跟随系统设置",
                icon: "desktopcomputer",
                tint: appState.accentTheme.color,
                isProminent: appState.isFollowingAllSystemAppearance
            ) {
                appState.followAllSystemAppearanceSettings()
            }
            .help("将应用外观、Liquid Glass 强度与主题颜色一键恢复为跟随 macOS 系统设置")
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("应用外观:")
                            .font(.system(size: 11.5, weight: .medium))
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        StudioSegmentedPicker(
                            selection: $appState.appearanceMode,
                            options: AppAppearanceMode.allCases.map {
                                StudioSegmentedOption(value: $0, title: $0.shortTitle)
                            }
                        )
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("应用外观:")
                            .font(.system(size: 11.5, weight: .medium))
                        StudioSegmentedPicker(
                            selection: $appState.appearanceMode,
                            options: AppAppearanceMode.allCases.map {
                                StudioSegmentedOption(value: $0, title: $0.shortTitle)
                            }
                        )
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("画布底色:")
                            .font(.system(size: 11.5, weight: .medium))
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        StudioSegmentedPicker(
                            selection: $appState.canvasThemeOverride,
                            options: CanvasThemeOverride.allCases.map {
                                StudioSegmentedOption(value: $0, title: $0.shortTitle)
                            }
                        )
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("画布底色:")
                            .font(.system(size: 11.5, weight: .medium))
                        StudioSegmentedPicker(
                            selection: $appState.canvasThemeOverride,
                            options: CanvasThemeOverride.allCases.map {
                                StudioSegmentedOption(value: $0, title: $0.shortTitle)
                            }
                        )
                    }
                }

                Divider().opacity(0.45)

                // macOS 27 系统设置风格：Liquid Glass 实时折射预览窗格 + 强度滑块 + 跟随系统设置按钮
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        liquidGlassControlSidebar
                            .frame(width: 146, alignment: .leading)
                        liquidGlassPreviewAndSlider
                            .frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 8) {
                            Text("Liquid Glass")
                                .font(.system(size: 12, weight: .semibold))
                            Text(liquidGlassStatusText)
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                            Spacer(minLength: 4)
                            followSystemGlassButton
                        }
                        liquidGlassPreviewAndSlider
                    }
                }

                Divider().opacity(0.45)

                // macOS 27 系统设置风格：主题颜色圆形色卡阵列（多色/跟随系统 + 单色点选 + 跟随系统按钮）
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("主题颜色:")
                            .font(.system(size: 11.5, weight: .medium))
                        Text(
                            appState.accentTheme == .system
                            ? "跟随系统（当前：\(appState.systemAccentTitle)）"
                            : "手动：\(appState.accentTheme.title)"
                        )
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                        Spacer(minLength: 4)

                        StudioCompactPillButton(
                            title: appState.accentTheme == .system ? "已跟随系统" : "跟随系统设置",
                            icon: "paintpalette",
                            tint: appState.accentTheme.color,
                            isProminent: appState.accentTheme == .system
                        ) {
                            appState.refreshSystemAppearancePreferences()
                            appState.accentTheme = .system
                        }
                    }

                    StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                        ForEach(AppAccentTheme.allCases) { theme in
                            themeSwatchButton(for: theme)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Divider().opacity(0.45)

                Toggle("启用 HDR 液态玻璃动态高光 (macOS 27 XDR 广色域辉光)", isOn: $appState.enableAmbientGlassGlow)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5, weight: .medium))

                Divider().opacity(0.45)

                Toggle("在 macOS 顶部菜单栏显示 Labworker 快捷图标", isOn: $appState.showStatusBarIcon)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5, weight: .medium))
            }
        }
    }

    private var liquidGlassStatusText: String {
        let pct = Int(round(appState.effectiveLiquidGlassStrength * 100))
        if appState.followSystemLiquidGlass {
            return "跟随系统 · \(pct)%"
        }
        return "\(appState.effectiveLiquidGlassStyle.shortTitle) · \(pct)%"
    }

    private var followSystemGlassButton: some View {
        StudioCompactPillButton(
            title: appState.followSystemLiquidGlass ? "已跟随系统" : "跟随系统设置",
            icon: "arrow.trianglehead.2.clockwise",
            tint: appState.accentTheme.color,
            isProminent: appState.followSystemLiquidGlass
        ) {
            appState.refreshSystemAppearancePreferences()
            appState.followSystemLiquidGlass = true
        }
    }

    private var liquidGlassControlSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Liquid Glass")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.primary)
            Text(liquidGlassStatusText)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
            followSystemGlassButton
                .padding(.top, 2)
        }
    }

    private var liquidGlassPreviewAndSlider: some View {
        let strength = appState.effectiveLiquidGlassStrength
        let isLight = appState.isLightAppearance
        let strengthBinding = Binding<Double>(
            get: { appState.effectiveLiquidGlassStrength },
            set: { newVal in
                appState.followSystemLiquidGlass = false
                appState.liquidGlassStrength = min(1.0, max(0.0, newVal))
            }
        )

        return VStack(alignment: .leading, spacing: 8) {
            // 实时折射预览框（仿 macOS 27 系统设置 Apple Park 玻璃预览卡片）
            ZStack(alignment: .top) {
                liquidGlassScenicBackdrop

                // 顶部悬浮 Liquid Glass 预览控件组（实时响应强度滑块与系统同步值）
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12.5, weight: .medium))
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12.5, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .glassEffect(
                            StudioGlassSupport.glassWithStrength(
                                strength,
                                appState: appState,
                                interactive: false
                            ),
                            in: Capsule(style: .continuous)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.32), lineWidth: 0.75)
                        )

                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .glassEffect(
                                StudioGlassSupport.glassWithStrength(
                                    strength,
                                    appState: appState,
                                    interactive: false
                                ),
                                in: Circle()
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.32), lineWidth: 0.75)
                            )

                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11, weight: .medium))
                            Text("搜索")
                                .font(.system(size: 11.5, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .glassEffect(
                            StudioGlassSupport.glassWithStrength(
                                strength,
                                appState: appState,
                                interactive: false
                            ),
                            in: Capsule(style: .continuous)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.32), lineWidth: 0.75)
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 9)
                .allowedDynamicRange(StudioGlassSupport.dynamicRange(for: appState))
            }
            .frame(height: 122)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.14),
                        lineWidth: 0.9
                    )
            )

            // 清透 <-> 浸染 连续强度滑块 + 刻度点（参考系统设置布局）
            HStack(spacing: 10) {
                Button {
                    appState.followSystemLiquidGlass = false
                    appState.liquidGlassStrength = 0.0
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(strength < 0.25 ? appState.accentTheme.color : .secondary)
                }
                .buttonStyle(.plain)
                .help("调至清透 (Clear · 0%)")

                VStack(spacing: 2) {
                    Slider(value: strengthBinding, in: 0.0...1.0)
                        .tint(appState.accentTheme.color)
                    HStack {
                        ForEach(0..<4, id: \.self) { idx in
                            if idx > 0 { Spacer() }
                            Circle()
                                .fill(Color.secondary.opacity(0.45))
                                .frame(width: 2.5, height: 2.5)
                        }
                    }
                    .padding(.horizontal, 7)
                }

                Button {
                    appState.followSystemLiquidGlass = false
                    appState.liquidGlassStrength = 0.88
                } label: {
                    Image(systemName: "rectangle.fill.on.rectangle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(strength >= 0.62 ? appState.accentTheme.color : .secondary)
                }
                .buttonStyle(.plain)
                .help("调至高雾度浸染 (Tinted · 88%)")
            }
        }
    }

    private var liquidGlassScenicBackdrop: some View {
        ZStack(alignment: .bottomLeading) {
            // 晴空蓝渐变底图
            LinearGradient(
                colors: [
                    Color(red: 0.28, green: 0.62, blue: 0.95),
                    Color(red: 0.56, green: 0.80, blue: 0.98),
                    Color(red: 0.78, green: 0.89, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 右侧玻璃建筑曲面弧线（强化顶部搜索胶囊的真实折射条纹感）
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack {
                    // 远山绿植剪影
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h * 0.56))
                        p.addCurve(
                            to: CGPoint(x: w * 0.58, y: h * 0.68),
                            control1: CGPoint(x: w * 0.22, y: h * 0.36),
                            control2: CGPoint(x: w * 0.42, y: h * 0.54)
                        )
                        p.addLine(to: CGPoint(x: w * 0.58, y: h))
                        p.addLine(to: CGPoint(x: 0, y: h))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.16, green: 0.50, blue: 0.22),
                                Color(red: 0.08, green: 0.31, blue: 0.14)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // 右侧玻璃幕墙弧光带
                    Path { p in
                        p.move(to: CGPoint(x: w * 0.48, y: h * 0.82))
                        p.addQuadCurve(
                            to: CGPoint(x: w, y: -6),
                            control: CGPoint(x: w * 0.64, y: h * 0.24)
                        )
                        p.addLine(to: CGPoint(x: w, y: h * 0.85))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.94, green: 0.92, blue: 0.86),
                                Color(red: 0.20, green: 0.46, blue: 0.74),
                                Color(red: 0.14, green: 0.24, blue: 0.34)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // 幕墙水平金属挑檐高光条纹，经过顶部玻璃控件可看到明显透镜折射
                    ForEach(0..<3, id: \.self) { idx in
                        Path { p in
                            let yOffset = CGFloat(idx) * 20
                            p.move(to: CGPoint(x: w * 0.56, y: 24 + yOffset))
                            p.addQuadCurve(
                                to: CGPoint(x: w, y: 4 + yOffset * 0.65),
                                control: CGPoint(x: w * 0.76, y: 12 + yOffset)
                            )
                        }
                        .stroke(Color.white.opacity(0.85 - Double(idx) * 0.18), lineWidth: 3.5)
                    }
                }
            }

            // 底部深色字幕条
            HStack {
                Text("欢迎来到 Labworker")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.76))
        }
    }

    private func themeSwatchButton(for theme: AppAccentTheme) -> some View {
        let isSelected = (appState.accentTheme == theme)
        let isLight = appState.isLightAppearance
        return Button {
            if theme == .system {
                appState.refreshSystemAppearancePreferences()
            }
            appState.accentTheme = theme
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    if isSelected {
                        Circle()
                            .stroke(
                                theme == .system ? appState.systemAccentColor : theme.color,
                                lineWidth: 2
                            )
                            .frame(width: 28, height: 28)
                    }

                    if theme == .system {
                        Circle()
                            .fill(
                                AngularGradient(
                                    gradient: Gradient(colors: [
                                        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red
                                    ]),
                                    center: .center
                                )
                            )
                            .frame(width: 21, height: 21)
                            .overlay(
                                Circle()
                                    .stroke(isLight ? Color.black.opacity(0.16) : Color.white.opacity(0.32), lineWidth: 0.75)
                            )
                            .overlay(
                                Circle()
                                    .fill(appState.systemAccentColor)
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 0.8))
                            )
                    } else {
                        Circle()
                            .fill(theme.color)
                            .frame(width: 21, height: 21)
                            .overlay(
                                Circle()
                                    .stroke(isLight ? Color.black.opacity(0.14) : Color.white.opacity(0.28), lineWidth: 0.75)
                            )
                    }
                }
                .frame(width: 29, height: 29)

                if theme == .system {
                    Text("多色")
                        .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .primary : .secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(theme == .system ? "多色（跟随 macOS 系统主题色）" : theme.title)
    }

    private var cloningDefaultsCard: some View {
        StudioCard(title: "2. 分子克隆与引物设计默认参数") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("默认同源臂长度:")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        StudioSegmentedPicker(
                            selection: $appState.defaultHomologyLength,
                            options: [15, 18, 20, 25].map {
                                StudioSegmentedOption(value: $0, title: "\($0) bp")
                            }
                        )
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("默认同源臂长度:")
                            .font(.system(size: 11.5, weight: .medium))
                        StudioSegmentedPicker(
                            selection: $appState.defaultHomologyLength,
                            options: [15, 18, 20, 25].map {
                                StudioSegmentedOption(value: $0, title: "\($0) bp")
                            }
                        )
                    }
                }

                HStack(spacing: 8) {
                    Text("同源重组目标 Tm:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.cloningTargetTm, in: 52.0...68.0, step: 0.5)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f ℃", appState.cloningTargetTm))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("定点突变目标 Tm:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.mutationTargetTm, in: 58.0...72.0, step: 0.5)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f ℃", appState.mutationTargetTm))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("允许 Tm 浮动容差:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.tmTolerance, in: 0.5...3.0, step: 0.5)
                        .frame(maxWidth: 130)
                    Text(String(format: "±%.1f ℃", appState.tmTolerance))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }

                Toggle("PCR 线性化载体时默认附带载体反向扩增引物", isOn: $appState.defaultIncludeVectorPCRPrimers)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5))

                Divider().opacity(0.5)

                HStack {
                    Text("二级结构热力学质检 (primer3 二聚体/发夹)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    let eqMm = appState.primerThermoConditions.equivalentMonovalentMolar * 1000.0
                    StudioMetricBadge(
                        label: "等效 [Na+]",
                        value: String(format: "%.0f mM", eqMm),
                        color: .teal
                    )
                }

                HStack(spacing: 8) {
                    Text("二价 Mg²⁺ 浓度:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.primerMgConc, in: 0.0...6.0, step: 0.1)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f mM", appState.primerMgConc))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("dNTP 总浓度:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.primerDntpConc, in: 0.0...4.0, step: 0.1)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f mM", appState.primerDntpConc))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("发夹告警阈值 ΔG:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.primerHairpinAlertDg, in: -8.0...(-1.0), step: 0.5)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f", appState.primerHairpinAlertDg))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("二聚体告警阈值 ΔG:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.primerDimerAlertDg, in: -12.0...(-3.0), step: 0.5)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f", appState.primerDimerAlertDg))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    private var benchAndImagingDefaultsCard: some View {
        StudioCard(title: "3. 电泳图像、微孔板与 qPCR 默认参数") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("WB 滚球背景扣除半径:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { Double(appState.defaultWBRollingBallRadius) },
                            set: { appState.defaultWBRollingBallRadius = Int($0.rounded()) }
                        ),
                        in: 15...120,
                        step: 5
                    )
                    .frame(maxWidth: 120)
                    Text("\(appState.defaultWBRollingBallRadius) px")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }

                Toggle("WB 条带默认白底黑带模式 (Inverted Polarity)", isOn: $appState.defaultWBWhiteBackground)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5))

                Divider().opacity(0.5)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("微孔板默认孔数规格:")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        StudioSegmentedPicker(
                            selection: $appState.defaultPlateFormatRaw,
                            options: [
                                StudioSegmentedOption(value: 96, title: "96 孔板"),
                                StudioSegmentedOption(value: 384, title: "384 孔板")
                            ]
                        )
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("微孔板默认孔数规格:")
                            .font(.system(size: 11.5, weight: .medium))
                        StudioSegmentedPicker(
                            selection: $appState.defaultPlateFormatRaw,
                            options: [
                                StudioSegmentedOption(value: 96, title: "96 孔板"),
                                StudioSegmentedOption(value: 384, title: "384 孔板")
                            ]
                        )
                    }
                }

                Toggle("微孔板自动排布默认避开最外圈孔 (防边缘蒸发效应)", isOn: $appState.defaultPlateAvoidOuterEdge)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5))

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    Text("qPCR 默认内参基因:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    TextField("如 ACTB / GAPDH", text: $appState.defaultQPCRReferenceGene)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                        .frame(width: 110)
                }

                HStack(spacing: 8) {
                    Text("qPCR 复孔 SD 告警阈值:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultQPCRSdThreshold, in: 0.10...1.00, step: 0.05)
                        .frame(maxWidth: 120)
                    Text(String(format: "%.2f", appState.defaultQPCRSdThreshold))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("qPCR NTC 污染阈值 (Ct):")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultQPCRNtcCtThreshold, in: 28.0...40.0, step: 0.5)
                        .frame(maxWidth: 120)
                    Text(String(format: "%.1f", appState.defaultQPCRNtcCtThreshold))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("qPCR no-RT 最小 ΔCt 阈值:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultQPCRNoRTDeltaCt, in: 2.0...10.0, step: 0.5)
                        .frame(maxWidth: 120)
                    Text(String(format: "%.1f", appState.defaultQPCRNoRTDeltaCt))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("qPCR 熔解曲线 Tm 容差:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultQPCRMeltTolerance, in: 0.3...3.0, step: 0.1)
                        .frame(maxWidth: 120)
                    Text(String(format: "±%.1f℃", appState.defaultQPCRMeltTolerance))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    Text("Sanger 克隆分组后缀正则:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    TextField(SangerBatchEngine.defaultPrimerSuffixRegex, text: $appState.defaultSangerCloneGroupingPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 175)
                }
            }
        }
    }

    private var engineAndSnapGeneCard: some View {
        StudioCard(title: "4. 计算引擎与构建产物") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("引擎协同策略:")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        StudioSegmentedPicker(
                            selection: $appState.engineMode,
                            options: EngineMode.allCases.map {
                                StudioSegmentedOption(value: $0, title: $0.displayName)
                            }
                        )
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("引擎协同策略:")
                            .font(.system(size: 11.5, weight: .medium))
                        StudioSegmentedPicker(
                            selection: $appState.engineMode,
                            options: EngineMode.allCases.map {
                                StudioSegmentedOption(value: $0, title: $0.displayName)
                            }
                        )
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("构建产物默认保存位置:")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        StudioSegmentedPicker(
                            selection: $appState.exportSaveLocation,
                            options: ExportSaveLocation.allCases.map {
                                StudioSegmentedOption(value: $0, title: $0.title)
                            }
                        )
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("构建产物默认保存位置:")
                            .font(.system(size: 11.5, weight: .medium))
                        StudioSegmentedPicker(
                            selection: $appState.exportSaveLocation,
                            options: ExportSaveLocation.allCases.map {
                                StudioSegmentedOption(value: $0, title: $0.title)
                            }
                        )
                    }
                }

                Toggle("写入引物或重组构建前自动备份原 .dna 文件", isOn: $appState.autoCreateSnapGeneBackup)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5))

                Toggle("生成重组 .dna 后自动调用 SnapGene 打开验证", isOn: $appState.autoOpenInSnapGene)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5))
            }
        }
    }

    private var plasmidAndSequenceMapCard: some View {
        StudioCard(title: "5. 质粒环图与微观序列视图") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("微观序列字号:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.sequenceFontSize, in: 9.0...13.0, step: 0.5)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f pt", appState.sequenceFontSize))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8)], spacing: 6) {
                    Toggle("默认开启密码子对齐", isOn: $appState.defaultSnapToCodonMode)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                    Toggle("显示互补链 (3'→5')", isOn: $appState.defaultShowComplement)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                    Toggle("显示氨基酸翻译条", isOn: $appState.defaultShowTranslation)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                    Toggle("显示质粒图谱特征", isOn: $appState.defaultShowFeatures)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                    Toggle("显示已绑定引物轨迹", isOn: $appState.defaultShowPrimers)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                    Toggle("显示限制性内切酶切点", isOn: $appState.defaultShowEnzymes)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                }
            }
        }
    }

    private var proteinWorkbenchDefaultsCard: some View {
        StudioCard(title: "6. 蛋白质工作台默认生理环境") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("默认生理溶液 pH:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultProteinPH, in: 4.5...9.5, step: 0.1)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f", appState.defaultProteinPH))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("默认环境温度 (K):")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultProteinTempK, in: 275.0...350.0, step: 5.0)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.0f K", appState.defaultProteinTempK))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }

    private var labOrderProfileCard: some View {
        StudioCard(title: "7. 引物合成与测序订购人默认档案") {
            EmptyView()
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 8)], spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("订购人姓名")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    TextField("姓名", text: $appState.profile.customerName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("课题组 / 导师")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    TextField("PI / 实验室", text: $appState.profile.piName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("联系电话")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    TextField("手机号", text: $appState.profile.phone)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("电子邮箱")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    TextField("邮箱", text: $appState.profile.email)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                }
            }
        }
    }
}
