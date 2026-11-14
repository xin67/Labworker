import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// 科研多图拼版、RGB 荧光通道合成与像素强度剖面标注器主视图 (纯声明式响应式 UI：任意拉动窗口自动折行与自适应多图网格)
public struct FigureAnnotatorView: View {
    @ObservedObject private var appState = AppState.shared
    
    @State private var panels: [FigurePanelItem] = FigureAnnotatorEngine.generateDemoFluorescencePanels()
    @State private var selectedPanelID: String = ""
    @State private var columnsCount: Int = 2
    @State private var labelStyle: FigureLabelStyle = .upperABC
    @State private var showProfileOverlay: Bool = true
    @State private var showScaleBars: Bool = true
    
    public init() {}
    
    private var selectedIndex: Int {
        panels.firstIndex { $0.id == selectedPanelID } ?? 0
    }
    
    private var labelStyleOptions: [StudioSegmentedOption<FigureLabelStyle>] {
        FigureLabelStyle.allCases.map { style in
            StudioSegmentedOption(value: style, title: style.title, tint: .pink)
        }
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "科研多图拼版与荧光共定位剖面分析",
            trailing: {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    StudioSegmentedPicker(selection: $labelStyle, options: labelStyleOptions)
                    
                    StudioSegmentedPillGroup(items: [
                        StudioPillGroupItem(title: "添加面板图像", icon: "photo.badge.plus", tint: .pink) {
                            importPanelImage()
                        },
                        StudioPillGroupItem(title: "共聚焦四通道示范", icon: "sparkles") {
                            panels = FigureAnnotatorEngine.generateDemoFluorescencePanels()
                            selectedPanelID = panels.last?.id ?? ""
                            appState.showToast("已载入 DAPI / TP53-EGFP / MitoTracker 四通道共定位示范图")
                        },
                        StudioPillGroupItem(title: "导出剖面 CSV", icon: "square.and.arrow.up", tint: .teal) {
                            exportProfileCSV()
                        }
                    ])
                }
            }
        ) {
            StudioResponsiveSplitLayout(breakpoint: 860, spacing: 14, leftRatio: 0.38) {
                leftColumn
                rightColumn
            }
        }
        .onAppear {
            if selectedPanelID.isEmpty, let last = panels.last {
                selectedPanelID = last.id
            }
        }
    }
    
    // MARK: - 左栏：网格排版设置 + 选中面板 RGB 通道增益 + 像素强度剖面图
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            layoutAndChannelCard
            intensityProfileCard
        }
    }
    
    private var layoutAndChannelCard: some View {
        let idx = min(max(0, selectedIndex), max(0, panels.count - 1))
        return StudioCard(title: "多面板网格排版与 RGB 荧光伪彩通道调节") {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 14, verticalSpacing: 8) {
                    Stepper(value: $columnsCount, in: 1...4) {
                        HStack(spacing: 4) {
                            Text("每行面板列数:")
                                .font(.system(size: 12.5))
                                .foregroundColor(.secondary)
                            Text("\(columnsCount)")
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                        }
                    }
                    .fixedSize()
                    
                    Toggle("显示比例尺 (20 μm)", isOn: $showScaleBars)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                    
                    Toggle("显示共定位采样线", isOn: $showProfileOverlay)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                }
                
                if !panels.isEmpty {
                    Divider()
                    
                    Text("当前选中面板：\(labelStyle.label(for: idx)) — \(panels[idx].title)")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.pink)
                    
                    HStack(spacing: 6) {
                        TextField("面板标题", text: $panels[idx].title)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        
                        TextField("副标题/激光波长", text: $panels[idx].subtitle)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                    
                    // 物理像素尺寸与自动比例尺来源 (P13)
                    HStack(spacing: 8) {
                        Text("比例尺来源:")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                        
                        Text(panels[idx].scaleBarSource.rawValue)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(panels[idx].scaleBarSource == .manual ? .orange : .pink)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill((panels[idx].scaleBarSource == .manual ? Color.orange : Color.pink).opacity(0.12))
                            )
                        
                        if let px = panels[idx].pixelSizeMicrons ?? panels[idx].rawPlane.effectivePixelSizeUM {
                            Text("(\(String(format: "%.3f", px)) µm/px)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        } else {
                            Text("(未校准)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        HStack(spacing: 4) {
                            Text("标尺:")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                            TextField("标尺长度", value: $panels[idx].scaleBarMicrons, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 48)
                                .onChange(of: panels[idx].scaleBarMicrons) { _, _ in
                                    panels[idx].scaleBarSource = .manual
                                }
                            Text("μm")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 6) {
                        Toggle("Red 通道", isOn: $panels[idx].channels.showRed)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                        Toggle("Green 通道", isOn: $panels[idx].channels.showGreen)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                        Toggle("Blue 通道", isOn: $panels[idx].channels.showBlue)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                        Toggle("反相 (Invert)", isOn: $panels[idx].channels.invert)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                    }
                    
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Text("R 增益 (\(String(format: "%.1f", panels[idx].channels.redGain))×):")
                                .font(.system(size: 11.5))
                                .foregroundColor(.red)
                                .frame(width: 92, alignment: .leading)
                            Slider(value: $panels[idx].channels.redGain, in: 0.1...2.5, step: 0.1)
                        }
                        HStack(spacing: 6) {
                            Text("G 增益 (\(String(format: "%.1f", panels[idx].channels.greenGain))×):")
                                .font(.system(size: 11.5))
                                .foregroundColor(.green)
                                .frame(width: 92, alignment: .leading)
                            Slider(value: $panels[idx].channels.greenGain, in: 0.1...2.5, step: 0.1)
                        }
                        HStack(spacing: 6) {
                            Text("B 增益 (\(String(format: "%.1f", panels[idx].channels.blueGain))×):")
                                .font(.system(size: 11.5))
                                .foregroundColor(.blue)
                                .frame(width: 92, alignment: .leading)
                            Slider(value: $panels[idx].channels.blueGain, in: 0.1...2.5, step: 0.1)
                        }
                    }
                }
            }
        }
    }
    
    private var intensityProfileCard: some View {
        let idx = min(max(0, selectedIndex), max(0, panels.count - 1))
        let pts = panels.isEmpty ? [] : FigureAnnotatorEngine.sampleLineProfile(for: panels[idx])
        
        return StudioCard(title: "选中面板荧光共定位像素强度剖面图 (Line Intensity Profile)") {
            VStack(alignment: .leading, spacing: 8) {
                if pts.isEmpty {
                    Text("暂无面板数据")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                } else {
                    Chart {
                        ForEach(pts) { pt in
                            if panels[idx].channels.showRed {
                                LineMark(
                                    x: .value("Distance", pt.distanceFraction * 100.0),
                                    y: .value("Intensity", pt.redIntensity),
                                    series: .value("Channel", "Red")
                                )
                                .foregroundStyle(Color.red)
                            }
                            if panels[idx].channels.showGreen {
                                LineMark(
                                    x: .value("Distance", pt.distanceFraction * 100.0),
                                    y: .value("Intensity", pt.greenIntensity),
                                    series: .value("Channel", "Green")
                                )
                                .foregroundStyle(Color.green)
                            }
                            if panels[idx].channels.showBlue {
                                LineMark(
                                    x: .value("Distance", pt.distanceFraction * 100.0),
                                    y: .value("Intensity", pt.blueIntensity),
                                    series: .value("Channel", "Blue")
                                )
                                .foregroundStyle(Color.blue)
                            }
                        }
                    }
                    .chartXAxisLabel("Normalized Profile Position (%)")
                    .chartYAxisLabel("Intensity (0–255)")
                    .frame(height: 195)
                    
                    Text("说明：绿线 (TP53-EGFP) 与红线 (MitoTracker) 波峰高度重合，直观验证线粒体共定位；蓝线 (DAPI) 位于中心核区。")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    
    // MARK: - 右栏：响应式科研多面板拼版画布
    private var rightColumn: some View {
        let minItemWidth: CGFloat = columnsCount <= 1 ? 640 : max(200, CGFloat(820 / max(1, columnsCount)))
        let gridCols = [GridItem(.adaptive(minimum: minItemWidth, maximum: 640), spacing: 12)]
        
        return StudioCard(
            title: "出版级多面板复合组图画布 (\(panels.count) 个子图面板)",
            headerTrailing: {
                StudioMetricBadge(label: "编号样式", value: labelStyle.title, color: .pink)
            }
        ) {
            LazyVGrid(columns: gridCols, spacing: 12) {
                ForEach(Array(panels.enumerated()), id: \.element.id) { idx, panel in
                    panelCellView(index: idx, panel: panel)
                }
            }
            .padding(6)
        }
    }
    
    private func panelCellView(index: Int, panel: FigurePanelItem) -> some View {
        let isSelected = (panel.id == selectedPanelID)
        let composite = FigureAnnotatorEngine.renderCompositePlane(for: panel)
        
        return Button(action: {
            selectedPanelID = panel.id
        }) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if let nsImg = composite.toNSImage() {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(CGFloat(composite.width) / CGFloat(max(1, composite.height)), contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    
                    // 左上角出版级面板编号 A / B / C / D
                    Text(labelStyle.label(for: index))
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.black.opacity(0.65))
                        )
                        .padding(8)
                    
                    // 叠加采样剖面线与右下角比例尺
                    GeometryReader { geo in
                        Canvas { context, size in
                            if showProfileOverlay {
                                let p1 = CGPoint(x: CGFloat(panel.profileStart.x) * size.width, y: CGFloat(panel.profileStart.y) * size.height)
                                let p2 = CGPoint(x: CGFloat(panel.profileEnd.x) * size.width, y: CGFloat(panel.profileEnd.y) * size.height)
                                var line = Path()
                                line.move(to: p1)
                                line.addLine(to: p2)
                                context.stroke(
                                    line,
                                    with: .color(.yellow.opacity(0.9)),
                                    style: StrokeStyle(lineWidth: 1.6, dash: [4, 3])
                                )
                            }
                            if showScaleBars && panel.showScaleBar {
                                let barFraction = FigureAnnotatorEngine.computeScaleBarWidthFraction(for: panel)
                                let barW = size.width * barFraction
                                let x1 = size.width - 12
                                let x0 = x1 - barW
                                let y = size.height - 12
                                var bar = Path()
                                bar.move(to: CGPoint(x: x0, y: y))
                                bar.addLine(to: CGPoint(x: x1, y: y))
                                context.stroke(bar, with: .color(.white), lineWidth: 2.5)
                                let txt = Text("\(Int(panel.scaleBarMicrons)) μm")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                context.draw(txt, at: CGPoint(x: 0.5 * (x0 + x1), y: y - 9))
                            }
                        }
                    }
                }
                
                HStack(spacing: 6) {
                    Text(panel.title)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(panel.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? Color.pink : Color.primary.opacity(0.10), lineWidth: isSelected ? 2.0 : 1.0)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 辅助动作
    
    private func importPanelImage() {
        FinderFileDropHelper.presentOpenPanel { url in
            if let loadedPlane = BioImagePlane.fromImageURL(url, maxDimension: 360) {
                let autoChannels = FigureAnnotatorEngine.autoMapChannelConfig(from: loadedPlane.channelNames)
                let newPanel = FigurePanelItem(
                    title: url.deletingPathExtension().lastPathComponent,
                    subtitle: "\(loadedPlane.width)×\(loadedPlane.height) px",
                    rawPlane: loadedPlane,
                    channels: autoChannels ?? FigurePanelChannelConfig()
                )
                panels.append(newPanel)
                selectedPanelID = newPanel.id
                let srcNote = (newPanel.scaleBarSource != .manual) ? " (已读取\(newPanel.scaleBarSource.rawValue))" : ""
                appState.showToast("已添加图版面板：\(newPanel.title)\(srcNote)")
            }
        }
    }
    
    private func exportProfileCSV() {
        let idx = min(max(0, selectedIndex), max(0, panels.count - 1))
        guard !panels.isEmpty else { return }
        let selected = panels[idx]
        let pts = FigureAnnotatorEngine.sampleLineProfile(for: selected)
        let csv = FigureAnnotatorEngine.exportProfileCSV(points: pts, panelTitle: selected.title)
        FinderFileDropHelper.saveTextToFile(
            content: csv,
            defaultFileName: "\(selected.title)_Line_Intensity_Profile.csv",
            contentType: .commaSeparatedText,
            toastPrefix: "已导出共定位剖面 CSV",
            onSavedURL: { outURL in
                do {
                    _ = try FigureAnnotatorEngine.exportProfileCSVWithProvenance(
                        points: pts,
                        panels: panels,
                        selectedPanel: selected,
                        to: outURL
                    )
                } catch {
                    print("Provenance export error: \(error)")
                }
            }
        )
    }
}
