import AppKit
import CloneStudioCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 1. 质粒片段同源重组 PCR 凝胶电泳模拟视图卡片

/// 嵌入分子克隆页面的同源重组 PCR 扩增琼脂糖凝胶模拟组件（自适应窄分栏与独立大窗）
public struct HomologousPCRGelSectionCard: View {
    public let title: String
    public let accentTint: Color
    public let compareLaneTitle: String
    public let buildSimulation: (AgaroseGelConcentration?, String?, Bool) -> HomologousPCRGelSimulationResult

    @State private var concentrationOverride: AgaroseGelConcentration? = nil
    @State private var ladderIDOverride: String? = nil
    @State private var includeMixControlLane: Bool = true
    @State private var selectedBandID: String? = nil
    @State private var isExpanded: Bool = true

    public init(
        title: String = "同源重组 PCR 凝胶电泳模拟",
        accentTint: Color = .cyan,
        compareLaneTitle: String = "显示共泳道对照",
        buildSimulation: @escaping (AgaroseGelConcentration?, String?, Bool) -> HomologousPCRGelSimulationResult
    ) {
        self.title = title
        self.accentTint = accentTint
        self.compareLaneTitle = compareLaneTitle
        self.buildSimulation = buildSimulation
    }

    public var body: some View {
        let result = buildSimulation(concentrationOverride, ladderIDOverride, includeMixControlLane)

        StudioCard(title: title) {
            if result.hasSampleBands {
                StudioCompactPillButton(
                    title: "大窗预览",
                    icon: "macwindow.badge.plus",
                    tint: accentTint,
                    help: "在独立窗口中放大检视模拟凝胶图谱与详细迁移对比"
                ) {
                    GelSimulationWindowPresenter.shared.openWindow(
                        title: title,
                        accentTint: accentTint,
                        compareLaneTitle: compareLaneTitle,
                        buildSimulation: buildSimulation
                    )
                }
            }
            StudioCompactPillButton(
                title: isExpanded ? "收起" : "展开",
                icon: isExpanded ? "chevron.up" : "chevron.down"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            }
        } content: {
            if !isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if result.hasSampleBands {
                        StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            StudioMetricBadge(
                                label: concentrationOverride == nil ? "推荐胶浓度" : "当前胶浓度",
                                value: result.concentration.rawValue,
                                color: accentTint
                            )
                            StudioMetricBadge(
                                label: "Marker",
                                value: result.ladder.name,
                                color: .orange
                            )
                            if !result.warnings.isEmpty {
                                StudioMetricBadge(
                                    label: "提示",
                                    value: "\(result.warnings.count) 项",
                                    color: .orange
                                )
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .foregroundColor(accentTint)
                        Text(
                            result.hasSampleBands
                                ? "已就绪（点击「展开」或「大窗预览」查看各泳道预期条带分布）"
                                : "载入载体或输入待扩增序列后，将实时模拟同源重组 PCR 条带电泳图谱。"
                        )
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                        Spacer()
                    }
                }
                .padding(.vertical, 2)
            } else if !result.hasSampleBands {
                VStack(alignment: .leading, spacing: 6) {
                    if let infoNotice = result.infoNotice {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.top, 1)
                            Text(infoNotice)
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .studioInnerBox(tint: .secondary, paddingH: 10, paddingV: 7)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(accentTint)
                        Text("输入 ≥ 50 bp 插入序列或载入载体质粒后，此处将实时按实际同源臂/接头与线性化长度模拟琼脂糖凝胶电泳条带。")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                    .studioInnerBox(tint: accentTint, paddingH: 10, paddingV: 8)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        StudioMetricBadge(
                            label: concentrationOverride == nil ? "推荐胶浓度" : "当前胶浓度",
                            value: result.concentration.rawValue,
                            color: accentTint
                        )
                        if !result.warnings.isEmpty {
                            StudioMetricBadge(
                                label: "分辨提示",
                                value: "\(result.warnings.count) 项",
                                color: .orange
                            )
                        }
                    }

                    HomologousPCRGelInteractiveBody(
                        result: result,
                        accentTint: accentTint,
                        compareLaneTitle: compareLaneTitle,
                        plateHeight: 270,
                        concentrationOverride: $concentrationOverride,
                        ladderIDOverride: $ladderIDOverride,
                        includeMixControlLane: $includeMixControlLane,
                        selectedBandID: $selectedBandID
                    )
                }
            }
        }
    }
}

// MARK: - 2. 交互式凝胶模拟核心面板（复用在页内卡片与独立大窗）

public struct HomologousPCRGelInteractiveBody: View {
    public let result: HomologousPCRGelSimulationResult
    public let accentTint: Color
    public let compareLaneTitle: String
    public let plateHeight: CGFloat

    @Binding public var concentrationOverride: AgaroseGelConcentration?
    @Binding public var ladderIDOverride: String?
    @Binding public var includeMixControlLane: Bool
    @Binding public var selectedBandID: String?

    @ObservedObject private var appState = AppState.shared

    public init(
        result: HomologousPCRGelSimulationResult,
        accentTint: Color,
        compareLaneTitle: String,
        plateHeight: CGFloat,
        concentrationOverride: Binding<AgaroseGelConcentration?>,
        ladderIDOverride: Binding<String?>,
        includeMixControlLane: Binding<Bool>,
        selectedBandID: Binding<String?>
    ) {
        self.result = result
        self.accentTint = accentTint
        self.compareLaneTitle = compareLaneTitle
        self.plateHeight = plateHeight
        self._concentrationOverride = concentrationOverride
        self._ladderIDOverride = ladderIDOverride
        self._includeMixControlLane = includeMixControlLane
        self._selectedBandID = selectedBandID
    }

    private var activeConcentrationBinding: Binding<AgaroseGelConcentration> {
        Binding(
            get: { concentrationOverride ?? result.concentration },
            set: { concentrationOverride = $0 }
        )
    }

    private var activeLadderIDBinding: Binding<String> {
        Binding(
            get: { ladderIDOverride ?? result.ladder.id },
            set: { ladderIDOverride = $0 }
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. 响应式参数调控工具条
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text("胶浓度:")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize()
                        StudioSegmentedPicker(
                            selection: activeConcentrationBinding,
                            options: AgaroseGelConcentration.allCases.map { conc in
                                StudioSegmentedOption(value: conc, title: conc.title, tint: accentTint)
                            }
                        )
                    }

                    StudioMenuPicker(
                        selection: activeConcentrationBinding,
                        options: AgaroseGelConcentration.allCases.map { conc in
                            StudioMenuPickerOption(value: conc, title: "\(conc.rawValue) · \(conc.optimalRangeText)")
                        },
                        prefix: "胶浓度",
                        icon: "dial.low",
                        tint: accentTint,
                        compact: true,
                        help: "切换琼脂糖凝胶百分比浓度，实时观察条带迁移距离变化"
                    )
                }

                if concentrationOverride != nil && concentrationOverride != result.recommendedConcentration {
                    StudioCompactPillButton(
                        title: "恢复推荐 \(result.recommendedConcentration.rawValue)",
                        icon: "wand.and.stars",
                        tint: accentTint
                    ) {
                        concentrationOverride = nil
                    }
                }

                StudioMenuPicker(
                    selection: activeLadderIDBinding,
                    options: HomologousPCRGelSimulator.availableDNALadders.map { preset in
                        StudioMenuPickerOption(value: preset.id, title: preset.name)
                    },
                    prefix: "Marker",
                    icon: "ruler",
                    tint: .orange,
                    compact: true,
                    help: "选择 DNA 分子量标准品 Marker"
                )

                Toggle(compareLaneTitle, isOn: $includeMixControlLane)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5, weight: .medium))
            }

            // 2. 分辨率与量程智能提示横幅（支持一键应用修复）
            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.warnings) { warn in
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                warningMessageView(warn)
                                Spacer(minLength: 6)
                                warningActionView(warn)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                warningMessageView(warn)
                                warningActionView(warn)
                            }
                        }
                        .studioInnerBox(tint: .orange, paddingH: 10, paddingV: 7)
                    }
                }
            }

            // 2.5 短侧翼模板提示（仅在未载入完整质粒时温和说明）
            if let infoNotice = result.infoNotice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(accentTint)
                        .padding(.top, 1)
                    Text(infoNotice)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .studioInnerBox(tint: accentTint, paddingH: 10, paddingV: 6)
            }

            // 3. 高仿真紫外/SYBR 琼脂糖电泳暗胶板画布
            AgaroseSimulatedSlabCanvas(
                result: result,
                plateHeight: plateHeight,
                selectedBandID: $selectedBandID
            )

            // 4. 条带角色色标图例（仅展示当前胶图实际含有的角色）
            roleLegendRow

            // 5. 各泳道预期条带数值卡片网格（自适应折行，绝不写死固定列数）
            let summaryItems = nonMarkerBandItems
            if !summaryItems.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 185, maximum: 320), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(summaryItems, id: \.band.id) { entry in
                        let roleColor = Self.color(for: entry.band.role, isLightSurface: appState.isLightAppearance)
                        let isSel = selectedBandID == entry.band.id
                        Button {
                            selectedBandID = (isSel ? nil : entry.band.id)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(roleColor)
                                    .frame(width: 4, height: 34)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(entry.lane.shortLabel)
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundColor(roleColor)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Capsule().fill(roleColor.opacity(0.14)))
                                        Spacer(minLength: 4)
                                        Text("\(entry.band.sizeBp) bp")
                                            .font(.system(size: 12.5, weight: .bold))
                                            .monospacedDigit()
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                        Text("(\(String(format: "%.2f", Double(entry.band.sizeBp) / 1000.0)) kb)")
                                            .font(.system(size: 10.5))
                                            .monospacedDigit()
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    Text(entry.band.detail.isEmpty ? entry.band.role.roleTitle : entry.band.detail)
                                        .font(.system(size: 10.5))
                                        .monospacedDigit()
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .studioInnerBox(
                                tint: isSel ? roleColor : nil,
                                paddingH: 9,
                                paddingV: 7
                            )
                        }
                        .buttonStyle(.plain)
                        .help("点击在凝胶画布中高亮此条带")
                    }
                }
            }

            // 6. 底部参考信息与 CSV 导出条
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                Text(result.suggestedExtensionNote)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                StudioCompactPillButton(title: "复制条带表", icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.exportCSV(), forType: .string)
                    AppState.shared.showToast("已复制模拟电泳条带数据 (CSV)")
                }

                StudioCompactPillButton(title: "导出 CSV", icon: "square.and.arrow.up", tint: accentTint) {
                    exportCSVFile(result.exportCSV())
                }
            }
        }
    }

    @ViewBuilder
    private func warningMessageView(_ warn: GelResolutionWarning) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.orange)
                .padding(.top, 1)
            Text(warn.message)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func warningActionView(_ warn: GelResolutionWarning) -> some View {
        HStack(spacing: 6) {
            if let conc = warn.suggestedConcentration {
                StudioCompactPillButton(title: "切换 \(conc.rawValue)", icon: "arrow.triangle.2.circlepath", tint: .orange) {
                    concentrationOverride = conc
                }
            }
            if let lid = warn.suggestedLadderID {
                StudioCompactPillButton(title: "换用 NEB 1 kb+", icon: "ruler", tint: .orange) {
                    ladderIDOverride = lid
                }
            }
        }
    }

    @ViewBuilder
    private var roleLegendRow: some View {
        let presentRoles = OrderedRoleList.rolesPresent(in: result.lanes)
        if !presentRoles.isEmpty {
            StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 4) {
                Text("胶浓度范围: \(result.concentration.optimalRangeText)")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.secondary)

                ForEach(presentRoles, id: \.self) { role in
                    let swatchColor = Self.color(for: role, isLightSurface: appState.isLightAppearance)
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(swatchColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .stroke(Color.primary.opacity(role == .marker ? 0.25 : 0.12), lineWidth: 0.6)
                            )
                            .frame(width: 14, height: 5)
                        Text(role.roleTitle)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private struct BandEntry {
        let lane: SimulatedGelLane
        let band: SimulatedGelBand
    }

    private var nonMarkerBandItems: [BandEntry] {
        var out: [BandEntry] = []
        for lane in result.lanes where !lane.isMarker && !lane.isMixedControl {
            for band in lane.bands.sorted(by: { $0.sizeBp > $1.sizeBp }) {
                out.append(BandEntry(lane: lane, band: band))
            }
        }
        return out
    }

    private func exportCSVFile(_ csv: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Labworker_HomologousPCR_Gel_\(result.concentration.rawValue.replacingOccurrences(of: "%", with: "pct")).csv"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                AppState.shared.showToast("已导出模拟电泳数据至 \(url.lastPathComponent)")
            } catch {
                AppState.shared.showToast("导出 CSV 失败: \(error.localizedDescription)")
            }
        }
    }

    public static func color(for role: SimulatedGelBandRole, isLightSurface: Bool = false) -> Color {
        switch role {
        case .marker:
            return isLightSurface ? Color(red: 0.36, green: 0.43, blue: 0.54) : Color(red: 0.93, green: 0.95, blue: 0.98)
        case .linearVector:
            return isLightSurface ? Color(red: 0.02, green: 0.54, blue: 0.82) : Color(red: 0.25, green: 0.78, blue: 0.98)
        case .excisedDropout:
            return isLightSurface ? Color(red: 0.88, green: 0.44, blue: 0.06) : Color(red: 0.99, green: 0.62, blue: 0.24)
        case .pcrAmplicon:
            return isLightSurface ? Color(red: 0.10, green: 0.64, blue: 0.34) : Color(red: 0.29, green: 0.90, blue: 0.54)
        case .parentalPlasmid:
            return isLightSurface ? Color(red: 0.35, green: 0.42, blue: 0.86) : Color(red: 0.65, green: 0.72, blue: 0.99)
        case .deletionAmplicon:
            return isLightSurface ? Color(red: 0.06, green: 0.58, blue: 0.48) : Color(red: 0.22, green: 0.87, blue: 0.68)
        }
    }
}

private enum OrderedRoleList {
    static func rolesPresent(in lanes: [SimulatedGelLane]) -> [SimulatedGelBandRole] {
        let order: [SimulatedGelBandRole] = [
            .marker, .linearVector, .pcrAmplicon, .excisedDropout, .parentalPlasmid, .deletionAmplicon
        ]
        let set = Set(lanes.flatMap { $0.bands.map(\.role) })
        return order.filter { set.contains($0) }
    }
}

// MARK: - 3. 高对比度 SYBR/UV 模拟琼脂糖凝胶画布 (防碰撞标签松弛算法)

private struct AgaroseSimulatedSlabCanvas: View {
    let result: HomologousPCRGelSimulationResult
    let plateHeight: CGFloat
    @Binding var selectedBandID: String?

    @ObservedObject private var appState = AppState.shared
    @State private var containerWidth: CGFloat = 0

    private let gutterWidth: CGFloat = 46
    private let rightPad: CGFloat = 12
    private let headerHeight: CGFloat = 28

    var body: some View {
        let laneCount = max(1, result.lanes.count)
        let effectiveContainerW = containerWidth > 20 ? containerWidth : 480
        let minLaneWidth: CGFloat = effectiveContainerW < 460 ? 48 : 62
        let minContentWidth = gutterWidth + rightPad + minLaneWidth * CGFloat(laneCount)
        let needsHorizontalScroll = containerWidth > 20 && (minContentWidth > containerWidth + 2)
        let activePerLaneWidth = needsHorizontalScroll
            ? minLaneWidth
            : max(1, (effectiveContainerW - gutterWidth - rightPad) / CGFloat(laneCount))
        let laneHeaderFontSize: CGFloat = activePerLaneWidth < 56 ? 10 : 11

        let plateView = VStack(spacing: 0) {
            // 顶部泳道标题栏
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Text("bp ")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.65))
                        .frame(width: gutterWidth, height: headerHeight, alignment: .trailing)

                    ForEach(result.lanes) { lane in
                        Text(lane.shortLabel)
                            .font(.system(size: laneHeaderFontSize, weight: lane.isMarker ? .bold : .semibold))
                            .foregroundColor(lane.isMarker ? Color(red: 1.0, green: 0.84, blue: 0.42) : Color.white.opacity(0.92))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight)
                    }
                }
                .padding(.trailing, rightPad)
            }
            .frame(maxWidth: .infinity)
            .background(Color(red: 0.085, green: 0.105, blue: 0.145))

            Divider()
                .background(Color.white.opacity(0.10))

            // 电泳胶板正文
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let gelTop: CGFloat = 12
                    let gelBottom: CGFloat = max(gelTop + 40, size.height - 22)
                    let gelSpan = gelBottom - gelTop
                    let livePerLaneWidth = max(1, (size.width - gutterWidth - rightPad) / CGFloat(laneCount))

                    // 1. 胶板暗色 UV 透射渐变底面
                    let bgRect = CGRect(origin: .zero, size: size)
                    context.fill(
                        Path(bgRect),
                        with: .linearGradient(
                            Gradient(colors: [
                                Color(red: 0.055, green: 0.072, blue: 0.102),
                                Color(red: 0.075, green: 0.098, blue: 0.138),
                                Color(red: 0.050, green: 0.068, blue: 0.096)
                            ]),
                            startPoint: .zero,
                            endPoint: CGPoint(x: 0, y: size.height)
                        )
                    )

                    // 2. 溴酚蓝前缘指示线（置於条带有效迁移底界之下，"前缘"标签置於虚线下方避免与 100/200 bp Marker 刻度重叠）
                    let dyeY = gelTop + 0.96 * gelSpan
                    var dyePath = Path()
                    dyePath.move(to: CGPoint(x: gutterWidth, y: dyeY))
                    dyePath.addLine(to: CGPoint(x: size.width - rightPad, y: dyeY))
                    context.stroke(
                        dyePath,
                        with: .color(Color.cyan.opacity(0.24)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
                    context.draw(
                        Text("前缘")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(Color.cyan.opacity(0.65)),
                        at: CGPoint(x: gutterWidth - 6, y: min(size.height - 2, dyeY + 2)),
                        anchor: .topTrailing
                    )

                    // 3. 计算 Marker 标尺标签的防重叠垂直坐标
                    if let markerLane = result.lanes.first(where: \.isMarker) {
                        let sortedMarker = markerLane.bands.sorted { $0.yFraction < $1.yFraction }
                        let rawYs = sortedMarker.map { gelTop + CGFloat($0.yFraction) * gelSpan }
                        let markerGap: CGFloat = sortedMarker.count > 12 ? 11.2 : 12.5
                        let relaxedYs = relaxLabelYPositions(rawYs, minGap: markerGap, minY: 10, maxY: dyeY - 6)
                        for (idx, band) in sortedMarker.enumerated() {
                            let labelY = relaxedYs[idx]
                            let tickY = rawYs[idx]
                            var tick = Path()
                            tick.move(to: CGPoint(x: gutterWidth - 4, y: tickY))
                            tick.addLine(to: CGPoint(x: gutterWidth + 2, y: tickY))
                            context.stroke(tick, with: .color(Color.white.opacity(0.28)), lineWidth: 1)

                            let isHighlight = band.relativeBrightness > 0.85
                            let text = Text(band.label)
                                .font(.system(size: isHighlight ? 9.5 : 8.5, weight: isHighlight ? .bold : .medium))
                                .monospacedDigit()
                                .foregroundColor(
                                    isHighlight
                                        ? Color(red: 1.0, green: 0.84, blue: 0.42)
                                        : Color.white.opacity(0.70)
                                )
                            context.draw(text, at: CGPoint(x: gutterWidth - 6, y: labelY), anchor: .trailing)
                        }
                    }

                    // 4. 逐泳道绘制点样孔、泳道分隔线与荧光 DNA 条带
                    for (laneIdx, lane) in result.lanes.enumerated() {
                        let laneMinX = gutterWidth + CGFloat(laneIdx) * livePerLaneWidth
                        let laneCenterX = laneMinX + livePerLaneWidth * 0.5
                        let bandW = min(livePerLaneWidth * 0.64, 52)
                        let bandX = laneCenterX - bandW * 0.5

                        // 泳道轻分隔线
                        if laneIdx > 0 {
                            var sep = Path()
                            sep.move(to: CGPoint(x: laneMinX, y: 4))
                            sep.addLine(to: CGPoint(x: laneMinX, y: size.height - 4))
                            context.stroke(sep, with: .color(Color.white.opacity(0.06)), lineWidth: 1)
                        }

                        // 胶孔 (Sample Well)
                        let wellRect = CGRect(x: bandX, y: 5, width: bandW, height: 6)
                        context.fill(
                            Path(roundedRect: wellRect, cornerRadius: 1.5),
                            with: .color(Color.black.opacity(0.65))
                        )
                        context.stroke(
                            Path(roundedRect: wellRect, cornerRadius: 1.5),
                            with: .color(Color.white.opacity(0.18)),
                            lineWidth: 0.7
                        )

                        // 绘制条带并为其非 Marker 条带计算防碰撞数值位置
                        let sortedBands = lane.bands.sorted { $0.yFraction < $1.yFraction }
                        let bandRawYs = sortedBands.map { gelTop + CGFloat($0.yFraction) * gelSpan }
                        let desiredLabelYs: [CGFloat] = bandRawYs.enumerated().map { bIdx, bY in
                            let closeAbove = bIdx > 0 && abs(bY - bandRawYs[bIdx - 1]) < 26
                            let closeBelow = (bIdx + 1) < bandRawYs.count && abs(bandRawYs[bIdx + 1] - bY) < 26
                            if closeAbove && !closeBelow {
                                return bY + 11.5
                            }
                            if bY < gelTop + 26 {
                                return bY + 11.5
                            }
                            return bY - 10.5
                        }
                        let labelYs = lane.isMarker
                            ? bandRawYs
                            : relaxLabelYPositions(desiredLabelYs, minGap: 15.0, minY: gelTop + 10, maxY: dyeY - 10)

                        for (bIdx, band) in sortedBands.enumerated() {
                            let bY = bandRawYs[bIdx]
                            let isSelected = (selectedBandID == band.id)
                            let baseColor: Color = {
                                if lane.isMarker && band.relativeBrightness > 0.85 {
                                    return Color(red: 1.0, green: 0.84, blue: 0.42)
                                }
                                return HomologousPCRGelInteractiveBody.color(for: band.role)
                            }()

                            let coreH: CGFloat = isSelected
                                ? 4.8
                                : (lane.isMarker ? (band.relativeBrightness > 0.85 ? 3.8 : 2.5) : 3.6)

                            // 荧光扩散光晕
                            let bloomRect = CGRect(
                                x: bandX - 2.5,
                                y: bY - coreH * 0.5 - 3.0,
                                width: bandW + 5.0,
                                height: coreH + 6.0
                            )
                            context.fill(
                                Path(roundedRect: bloomRect, cornerRadius: 3.5),
                                with: .color(baseColor.opacity(isSelected ? 0.42 : 0.24 * band.relativeBrightness))
                            )

                            // 高亮锐利核心条带
                            let coreRect = CGRect(
                                x: bandX,
                                y: bY - coreH * 0.5,
                                width: bandW,
                                height: coreH
                            )
                            context.fill(
                                Path(roundedRect: coreRect, cornerRadius: 1.5),
                                with: .color(baseColor.opacity(min(1.0, 0.78 + 0.22 * band.relativeBrightness)))
                            )

                            if isSelected {
                                let ring = coreRect.insetBy(dx: -3, dy: -2.5)
                                context.stroke(
                                    Path(roundedRect: ring, cornerRadius: 2.5),
                                    with: .color(Color.white.opacity(0.92)),
                                    lineWidth: 1.2
                                )
                            }

                            // 非 Marker 泳道条带紧贴绘制清晰 bp 读数（带暗底衬托，确保多带泳道也零遮挡可读）
                            if !lane.isMarker {
                                let drawY = labelYs[bIdx]
                                if abs(drawY - bY) > 12.0 {
                                    var leader = Path()
                                    leader.move(to: CGPoint(x: bandX + bandW * 0.5, y: bY))
                                    leader.addLine(to: CGPoint(x: bandX + bandW * 0.5, y: drawY))
                                    context.stroke(leader, with: .color(baseColor.opacity(0.45)), lineWidth: 0.75)
                                }
                                let badgeStr = "\(band.sizeBp)"
                                let estPillW = CGFloat(badgeStr.count) * 6.2 + 8.0
                                let pillRect = CGRect(
                                    x: laneCenterX - estPillW * 0.5,
                                    y: drawY - 6.0,
                                    width: estPillW,
                                    height: 12.0
                                )
                                context.fill(
                                    Path(roundedRect: pillRect, cornerRadius: 3.0),
                                    with: .color(Color(red: 0.055, green: 0.072, blue: 0.102).opacity(0.84))
                                )
                                let txt = Text(badgeStr)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundColor(Color.white.opacity(0.96))
                                context.draw(txt, at: CGPoint(x: laneCenterX, y: drawY), anchor: .center)
                            }
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: plateHeight)
                .background(Color(red: 0.055, green: 0.072, blue: 0.102))
                .contentShape(Rectangle())
                .onTapGesture { loc in
                    handleTap(at: loc, perLaneWidth: activePerLaneWidth, sizeHeight: plateHeight)
                }
            }
        }
        .background(Color(red: 0.055, green: 0.072, blue: 0.102))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    appState.isLightAppearance
                        ? Color.black.opacity(0.14)
                        : Color.white.opacity(0.16),
                    lineWidth: 1
                )
        )

        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { w in
                    if w > 10 && abs(containerWidth - w) > 1 {
                        containerWidth = w
                    }
                }

            if needsHorizontalScroll {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        plateView
                            .frame(width: minContentWidth)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    Text("← 左右滑动查看全部 \(laneCount) 条泳道 →")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                plateView
                    .frame(minWidth: 0, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private func handleTap(at loc: CGPoint, perLaneWidth: CGFloat, sizeHeight: CGFloat) {
        let relX = loc.x - gutterWidth
        guard relX >= 0 else { return }
        let laneIdx = Int(relX / perLaneWidth)
        guard result.lanes.indices.contains(laneIdx) else { return }
        let lane = result.lanes[laneIdx]
        guard !lane.isMarker, !lane.bands.isEmpty else {
            selectedBandID = nil
            return
        }
        let gelTop: CGFloat = 12
        let gelBottom: CGFloat = max(gelTop + 40, sizeHeight - 14)
        let gelSpan = gelBottom - gelTop
        let nearest = lane.bands.min { lhs, rhs in
            abs((gelTop + CGFloat(lhs.yFraction) * gelSpan) - loc.y)
                < abs((gelTop + CGFloat(rhs.yFraction) * gelSpan) - loc.y)
        }
        selectedBandID = nearest?.id
    }

    /// 1D 标签纵坐标最小间距松弛解算，防止相邻 Marker 或混样条带文字重叠
    private func relaxLabelYPositions(
        _ sortedInputY: [CGFloat],
        minGap: CGFloat,
        minY: CGFloat,
        maxY: CGFloat
    ) -> [CGFloat] {
        guard !sortedInputY.isEmpty else { return [] }
        var ys = sortedInputY.map { min(maxY, max(minY, $0)) }
        for _ in 0..<8 {
            for i in 1..<ys.count {
                let deficit = minGap - (ys[i] - ys[i - 1])
                if deficit > 0 {
                    ys[i - 1] -= deficit * 0.45
                    ys[i] += deficit * 0.55
                }
            }
            // 回钳上下边界
            ys[0] = max(minY, ys[0])
            for i in 1..<ys.count {
                ys[i] = max(ys[i - 1] + minGap, ys[i])
            }
            if let last = ys.last, last > maxY {
                ys[ys.count - 1] = maxY
                for i in stride(from: ys.count - 2, through: 0, by: -1) {
                    ys[i] = min(ys[i], ys[i + 1] - minGap)
                }
            }
        }
        return ys
    }
}

// MARK: - 4. 独立放大电泳模拟窗口管理

@MainActor
public final class GelSimulationWindowPresenter: NSObject, NSWindowDelegate {
    public static let shared = GelSimulationWindowPresenter()
    private var activeWindows: [NSWindow] = []

    public func openWindow(
        title: String,
        accentTint: Color,
        compareLaneTitle: String,
        buildSimulation: @escaping (AgaroseGelConcentration?, String?, Bool) -> HomologousPCRGelSimulationResult
    ) {
        let contentRect = NSRect(x: 0, y: 0, width: 920, height: 640)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 680, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let rootView = StandaloneGelSimulationWindowView(
            title: title,
            accentTint: accentTint,
            compareLaneTitle: compareLaneTitle,
            buildSimulation: buildSimulation
        )
        window.appearance = NSApplication.shared.appearance
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        activeWindows.append(window)
    }

    public func windowWillClose(_ notification: Notification) {
        if let closedWin = notification.object as? NSWindow {
            activeWindows.removeAll { $0 === closedWin }
        }
    }
}

private struct StandaloneGelSimulationWindowView: View {
    @ObservedObject private var appState = AppState.shared
    let title: String
    let accentTint: Color
    let compareLaneTitle: String
    let buildSimulation: (AgaroseGelConcentration?, String?, Bool) -> HomologousPCRGelSimulationResult

    @State private var concentrationOverride: AgaroseGelConcentration? = nil
    @State private var ladderIDOverride: String? = nil
    @State private var includeMixControlLane: Bool = true
    @State private var selectedBandID: String? = nil

    private var isDark: Bool {
        appState.resolvedCanvasIsDark()
    }

    var body: some View {
        let result = buildSimulation(concentrationOverride, ladderIDOverride, includeMixControlLane)

        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.doc.horizontal.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(accentTint)
                        Text(title)
                            .font(.system(size: 16, weight: .bold))
                    }
                    StudioMetricBadge(label: "凝胶浓度", value: result.concentration.rawValue, color: accentTint)
                    StudioMetricBadge(label: "Marker", value: result.ladder.name, color: .orange)
                }

                if result.hasSampleBands {
                    HomologousPCRGelInteractiveBody(
                        result: result,
                        accentTint: accentTint,
                        compareLaneTitle: compareLaneTitle,
                        plateHeight: 360,
                        concentrationOverride: $concentrationOverride,
                        ladderIDOverride: $ladderIDOverride,
                        includeMixControlLane: $includeMixControlLane,
                        selectedBandID: $selectedBandID
                    )
                } else {
                    Text("当前主工作区尚未输入有效长度（≥ 50 bp）的序列或载体，请先输入片段后查看模拟电泳。")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .studioInnerBox(tint: accentTint, paddingH: 14, paddingV: 14)
                }
            }
            .padding(.top, 36)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(minWidth: 680, minHeight: 480)
        .background(StudioPalette.workspaceBg(isLight: !isDark))
        .ignoresSafeArea(.container, edges: .top)
    }
}
