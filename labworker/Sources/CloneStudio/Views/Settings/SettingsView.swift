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
        let visibleCount = NavItem.allCases.filter { appState.isNavItemVisible($0) }.count
        StudioPageLayout(title: "系统设置与功能说明书") {
            StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 6) {
                StudioSegmentedPicker(
                    selection: $activeTab,
                    options: SettingsSubTab.allCases.map {
                        StudioSegmentedOption(value: $0, title: $0.title, tint: .blue)
                    }
                )
                StudioMetricBadge(
                    label: "侧边栏显示",
                    value: "\(visibleCount) / \(NavItem.allCases.count)",
                    color: visibleCount == NavItem.allCases.count ? .green : .orange
                )
                StudioActionPillButton(
                    title: "恢复默认",
                    icon: "arrow.counterclockwise",
                    action: appState.resetSettingsToDefaults
                )
            }
        } content: {
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
        let hiddenCount = appState.hiddenSidebarItems.count
        return VStack(alignment: .leading, spacing: 12) {
            StudioCard(title: "侧边栏模块可见性快捷方案") {
                StudioMetricBadge(
                    label: "当前已隐藏",
                    value: "\(hiddenCount) 项",
                    color: hiddenCount == 0 ? .green : .orange
                )
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
                            Button("全选") {
                                for item in sectionItems {
                                    appState.setNavItemVisible(item, visible: true)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            if section != .orderAndSettings {
                                Button("全隐") {
                                    for item in sectionItems where item.canBeHiddenInSidebar {
                                        appState.setNavItemVisible(item, visible: false)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
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
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isVis ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.03))
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
                StudioCard(title: "Labworker MCP Server v3.0 控制中心") {
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
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
                                }
                            }
                        } else if let lastSync = pool.lastMCPActivitySummary {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("最近外部调用同步：\(lastSync)")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.green.opacity(0.08)))
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
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(NSColor.textBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                                )
                        )
                }
            }

            StudioCard(title: "已注册的 \(tools.count) 大全栈 MCP 实验工具清单") {
                StudioMetricBadge(label: "版本", value: "labworker-mcp 3.0.0", color: .teal)
            } content: {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 460), spacing: 10)], spacing: 10) {
                    ForEach(tools) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(t.name)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
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
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        )
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .frame(minWidth: 240, maxWidth: 420)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(NSColor.textBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
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
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                                Button {
                                    appState.selectedNav = item
                                } label: {
                                    HStack(spacing: 3) {
                                        Text("直达功能")
                                        Image(systemName: "arrow.up.right.circle.fill")
                                    }
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                    .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                            }

                            if !isVis && item.canBeHiddenInSidebar {
                                Button {
                                    appState.setNavItemVisible(item, visible: true)
                                } label: {
                                    Text("恢复显示")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3.5)
                                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
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
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
                }
            }
        }
    }

    private func categoryFilterPill(title: String, section: SidebarSectionKind?) -> some View {
        let isSelected = (selectedManualSection == section)
        return Button {
            selectedManualSection = section
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 原有 7 张默认参数配置卡片

    private var appearanceCard: some View {
        StudioCard(title: "1. 外观与主题") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 10) {
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

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("主题强调色:")
                            .font(.system(size: 11.5, weight: .medium))
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        StudioSegmentedPicker(
                            selection: $appState.accentTheme,
                            options: AppAccentTheme.allCases.map {
                                StudioSegmentedOption(value: $0, title: $0.title, tint: $0.color)
                            }
                        )
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("主题强调色:")
                            .font(.system(size: 11.5, weight: .medium))
                        StudioSegmentedPicker(
                            selection: $appState.accentTheme,
                            options: AppAccentTheme.allCases.map {
                                StudioSegmentedOption(value: $0, title: $0.title, tint: $0.color)
                            }
                        )
                    }
                }

                Divider().opacity(0.5)

                Toggle("在 macOS 顶部菜单栏显示 Labworker 快捷图标", isOn: $appState.showStatusBarIcon)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5, weight: .medium))
            }
        }
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
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("定点突变目标 Tm:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.mutationTargetTm, in: 58.0...72.0, step: 0.5)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f ℃", appState.mutationTargetTm))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("允许 Tm 浮动容差:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.tmTolerance, in: 0.5...3.0, step: 0.5)
                        .frame(maxWidth: 130)
                    Text(String(format: "±%.1f ℃", appState.tmTolerance))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
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
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("dNTP 总浓度:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.primerDntpConc, in: 0.0...4.0, step: 0.1)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f mM", appState.primerDntpConc))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("发夹告警阈值 ΔG:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.primerHairpinAlertDg, in: -8.0...(-1.0), step: 0.5)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f", appState.primerHairpinAlertDg))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 56, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("二聚体告警阈值 ΔG:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.primerDimerAlertDg, in: -12.0...(-3.0), step: 0.5)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.1f", appState.primerDimerAlertDg))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
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
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
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
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 110)
                }

                HStack(spacing: 8) {
                    Text("qPCR 复孔 SD 告警阈值:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultQPCRSdThreshold, in: 0.10...1.00, step: 0.05)
                        .frame(maxWidth: 120)
                    Text(String(format: "%.2f", appState.defaultQPCRSdThreshold))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("qPCR NTC 污染阈值 (Ct):")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultQPCRNtcCtThreshold, in: 28.0...40.0, step: 0.5)
                        .frame(maxWidth: 120)
                    Text(String(format: "%.1f", appState.defaultQPCRNtcCtThreshold))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("qPCR no-RT 最小 ΔCt 阈值:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultQPCRNoRTDeltaCt, in: 2.0...10.0, step: 0.5)
                        .frame(maxWidth: 120)
                    Text(String(format: "%.1f", appState.defaultQPCRNoRTDeltaCt))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("qPCR 熔解曲线 Tm 容差:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultQPCRMeltTolerance, in: 0.3...3.0, step: 0.1)
                        .frame(maxWidth: 120)
                    Text(String(format: "±%.1f℃", appState.defaultQPCRMeltTolerance))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 48, alignment: .trailing)
                }

                Divider().opacity(0.5)

                HStack(spacing: 8) {
                    Text("Sanger 克隆分组后缀正则:")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    TextField(SangerBatchEngine.defaultPrimerSuffixRegex, text: $appState.defaultSangerCloneGroupingPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
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
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }

                HStack(spacing: 8) {
                    Text("默认环境温度 (K):")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                    Slider(value: $appState.defaultProteinTempK, in: 275.0...350.0, step: 5.0)
                        .frame(maxWidth: 130)
                    Text(String(format: "%.0f K", appState.defaultProteinTempK))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
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
