import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// 凝胶电泳分子量拟合、虚拟酶切联动与拼图编辑器主视图 (纯声明式响应式 UI：任意拉动窗口自动折行与自适应胶图画布)
public struct GelFigureEditorView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var plasmidPool = PlasmidPoolManager.shared
    
    @State private var plane: BioImagePlane = BioImageProcessor.generateDemoAgaroseGelPlane()
    @State private var selectedLadderID: String = "dl2000"
    @State private var lanes: [GelLaneItem] = []
    @State private var calibrationFit: GelLadderCalibrationFit? = nil
    @State private var selectedEnzyme1: String = "BamHI"
    @State private var selectedEnzyme2: String = "EcoRI"
    @State private var showBandSizeOverlay: Bool = true
    @State private var showLadderRuler: Bool = true
    @State private var sourceImageURL: URL? = nil
    
    public init() {}
    
    private var activeLadder: GelMarkerLadderPreset {
        GelMarkerLadderPreset.builtinPresets.first { $0.id == selectedLadderID }
            ?? GelMarkerLadderPreset.builtinPresets[0]
    }
    
    private var commonDigestEnzymes: [String] {
        ["BamHI", "EcoRI", "HindIII", "XhoI", "NdeI", "SalI", "KpnI", "XbaI", "NotI", "BsaI"]
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "凝胶定量",
            toolbar: [
                .action(title: "导入", icon: "photo.badge.plus", tint: .cyan, help: "导入电泳胶图", action: importGelImage),
                .action(title: "拟合", icon: "wand.and.stars", tint: .blue, help: "自动寻道并拟合 Ladder 标准曲线") {
                    runAutoDetection()
                    appState.showToast("已完成泳道寻峰与 \(activeLadder.name) 标准曲线拟合")
                },
                .action(title: "酶切道", icon: "scissors", tint: .teal, help: "从质粒池插入虚拟酶切对照道", action: injectVirtualDigestLaneFromPool),
                .action(title: "导出", icon: "square.and.arrow.up", help: "导出条带分子量回归 CSV", action: exportGelCSV)
            ]
        ) {
            StudioResponsiveSplitLayout(breakpoint: 860, spacing: 14, leftRatio: 0.40) {
                leftColumn
                rightColumn
            }
        }
        .onAppear {
            selectedLadderID = appState.defaultGelLadderID
            if lanes.isEmpty {
                runAutoDetection()
            }
            if let url = appState.pendingFinderOpenedFileURL,
               ["tif", "tiff", "png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
               let img = NSImage(contentsOf: url),
               let loadedPlane = BioImagePlane.fromNSImage(img, maxDimension: 520) {
                appState.pendingFinderOpenedFileURL = nil
                sourceImageURL = url
                plane = loadedPlane
                runAutoDetection()
            }
        }
        .onChange(of: appState.defaultGelLadderID) { _, newLadder in
            selectedLadderID = newLadder
        }
    }
    
    // MARK: - 左栏：Marker 标准曲线拟合 + 质粒虚拟酶切对照与条带明细
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            ladderCalibrationCard
            virtualDigestAndLanesCard
        }
    }
    
    private var ladderCalibrationCard: some View {
        StudioCard(title: "Marker 标准品选择与对数迁移率回归曲线") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("选择 DNA / 蛋白质 Marker 标准品:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Picker("Marker 标准品", selection: $selectedLadderID) {
                        ForEach(GelMarkerLadderPreset.builtinPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedLadderID) { _, _ in
                        let res = GelAnalysisEngine.recalibrateLanes(lanes: lanes, ladder: activeLadder)
                        lanes = res.lanes
                        calibrationFit = res.fit
                    }
                }
                
                if let fit = calibrationFit {
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        StudioMetricBadge(label: "拟合优度 R²", value: String(format: "%.4f", fit.r2), color: fit.r2 >= 0.98 ? .green : .orange)
                        StudioMetricBadge(label: "斜率 Slope", value: String(format: "%.3f", fit.slope), color: .blue)
                        StudioMetricBadge(label: "截距 Intercept", value: String(format: "%.2f", fit.intercept), color: .teal)
                        StudioMetricBadge(label: "校准点数", value: "\(fit.n)", color: .secondary)
                    }
                    
                    Chart {
                        ForEach(Array(fit.points.enumerated()), id: \.offset) { _, pt in
                            PointMark(
                                x: .value("迁移率 Y", pt.y),
                                y: .value("log10(\(activeLadder.kind.unit))", pt.log10Size)
                            )
                            .foregroundStyle(Color.cyan)
                            .symbolSize(50)
                        }
                        
                        LineMark(
                            x: .value("迁移率 Y", 0.15),
                            y: .value("log10(\(activeLadder.kind.unit))", fit.slope * 0.15 + fit.intercept)
                        )
                        .foregroundStyle(Color.blue)
                        
                        LineMark(
                            x: .value("迁移率 Y", 0.85),
                            y: .value("log10(\(activeLadder.kind.unit))", fit.slope * 0.85 + fit.intercept)
                        )
                        .foregroundStyle(Color.blue)
                    }
                    .chartXAxisLabel("Normalized Migration Distance (Y)")
                    .chartYAxisLabel("log10(\(activeLadder.kind.unit))")
                    .frame(height: 155)
                }
            }
        }
    }
    
    private var virtualDigestAndLanesCard: some View {
        StudioCard(title: "质粒酶切虚拟电泳联动 & 泳道条带分子量明细") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("从本地质粒池生成理论酶切条带（叠加至胶图右侧比对阳性克隆）：")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        Picker("内切酶 1", selection: $selectedEnzyme1) {
                            ForEach(commonDigestEnzymes, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 115)
                        
                        Picker("内切酶 2", selection: $selectedEnzyme2) {
                            ForEach(commonDigestEnzymes, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 115)
                        
                        StudioActionPillButton(title: "生成虚拟对照道", icon: "plus.Viewfinder", tint: .teal, isProminent: true) {
                            injectVirtualDigestLaneFromPool()
                        }
                    }
                }
                
                Divider()
                
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 6) {
                        ForEach(Array(lanes.enumerated()), id: \.element.id) { idx, lane in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text("L\(lane.index)")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(lane.isLadderLane ? .orange : (lane.isVirtualDigestLane ? .cyan : .blue))
                                    
                                    TextField("泳道名称", text: $lanes[idx].name)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 12))
                                    
                                    if lane.isVirtualDigestLane {
                                        Button(action: {
                                            lanes.remove(at: idx)
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 11))
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                
                                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                                    ForEach(lane.bands) { band in
                                        let valStr = band.estimatedSize.map {
                                            activeLadder.kind == .dna ? String(format: "%.0f bp", $0) : String(format: "%.1f kDa", $0)
                                        } ?? "—"
                                        StudioMetricBadge(
                                            label: lane.isLadderLane ? "Std" : "Band",
                                            value: valStr,
                                            color: lane.isLadderLane ? .orange : (band.isVirtualDigestBand ? .cyan : .teal)
                                        )
                                    }
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.primary.opacity(0.035))
                            )
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 340)
            }
        }
    }
    
    // MARK: - 右栏：响应式凝胶电泳拼图与分子量标尺画布
    private var rightColumn: some View {
        StudioCard(
            title: "出版级电泳标注画布 (\(lanes.count) 个泳道 · 单位 \(activeLadder.kind.unit))",
            headerTrailing: {
                StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 6) {
                    Toggle("显示左侧 Marker 标尺", isOn: $showLadderRuler)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    
                    Toggle("显示条带推算分子量", isOn: $showBandSizeOverlay)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    let aspect = CGFloat(plane.width) / CGFloat(max(1, plane.height))
                    let drawW = max(260, min(geo.size.width - 16, geo.size.height * aspect))
                    let drawH = drawW / max(0.2, aspect)
                    
                    ZStack {
                        if let nsImg = plane.toNSImage() {
                            Image(nsImage: nsImg)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: drawW, height: drawH)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        
                        Canvas { context, _ in
                            for lane in lanes {
                                let lx = CGFloat(lane.centerX) * drawW
                                let bw = CGFloat(lane.widthFrac) * drawW
                                
                                // 泳道顶部名称标签
                                let headerText = Text(lane.name)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(lane.isVirtualDigestLane ? .cyan : .white)
                                context.draw(headerText, at: CGPoint(x: lx, y: 14))
                                
                                for band in lane.bands {
                                    let by = CGFloat(band.yFraction) * drawH
                                    var line = Path()
                                    line.move(to: CGPoint(x: lx - bw * 0.45, y: by))
                                    line.addLine(to: CGPoint(x: lx + bw * 0.45, y: by))
                                    
                                    let strokeColor: Color = lane.isLadderLane
                                        ? .orange
                                        : (band.isVirtualDigestBand ? .cyan : .green)
                                    context.stroke(
                                        line,
                                        with: .color(strokeColor),
                                        style: StrokeStyle(
                                            lineWidth: band.isVirtualDigestBand ? 2.4 : 1.8,
                                            dash: band.isVirtualDigestBand ? [4, 2] : []
                                        )
                                    )
                                    
                                    if lane.isLadderLane && showLadderRuler, let sz = band.knownSize {
                                        let rulerTxt = Text(activeLadder.kind == .dna ? "\(Int(sz))" : String(format: "%.0f", sz))
                                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(.orange)
                                        context.draw(rulerTxt, at: CGPoint(x: max(22, lx - bw * 0.65), y: by), anchor: .trailing)
                                    } else if !lane.isLadderLane && showBandSizeOverlay, let est = band.estimatedSize {
                                        let szTxt = Text(activeLadder.kind == .dna ? "\(Int(round(est)))" : String(format: "%.1f", est))
                                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                            .foregroundColor(band.isVirtualDigestBand ? .cyan : .yellow)
                                        context.draw(szTxt, at: CGPoint(x: lx, y: by - 9))
                                    }
                                }
                            }
                        }
                        .frame(width: drawW, height: drawH)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(minHeight: 360, maxHeight: 520)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                
                Text("提示：橙色标尺为 Marker 标准品校准带，绿色实线为实测样品条带及回归推算分子量，青色虚线为从质粒池计算的理论双酶切虚拟对照带。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    // MARK: - 交互动作
    
    private func runAutoDetection() {
        let res = GelAnalysisEngine.autoDetectAndCalibrate(plane: plane, ladder: activeLadder)
        lanes = res.lanes
        calibrationFit = res.fit
    }
    
    private func injectVirtualDigestLaneFromPool() {
        let targetPlasmid = plasmidPool.selectedItem ?? plasmidPool.items.first
        let seq = targetPlasmid?.dnaInfo.sequence ?? "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGGAATTCACTAGTAACGGCCGCCAGTGTGCTGG" + String(repeating: "ATGCGATCGATCGATC", count: 80) + "GGATCCGAGCTCCAGCTTTTGTTCCCTTTAGTGAGGGTTAATTGCGCGCTTGGCGTAATCATGGTCATAGCTGTTTCCTGTGTGAAATTGTTATCCGCTCACAATTCCACACAACATACGAGCCGGAAGCATAAAGTGTAAAGCCTGGGGTGCCTAATGAGTGAGCTAACTCACATTAATTGCGTTGCGCTCACTGCCCGCTTTCCAGTCGGGAAACCTGTCGTGCCAGCTGCATTAATGAATCGGCCAACGCGCGGGGAGAGGCGGTTTGCGTATTGGGCGCTCTTCCGCTTCCTCGCTCACTGACTCGCTGCGCTCGGTCGTTCGGCTGCGGCGAGCGGTATCAGCTCACTCAAAGGCGGTAATACGGTTATCCACAGAATCAGGGGATAACGCAGGAAAGAACATGTGAGCAAAAGGCCAGCAAAAGGCCAGGAACCGTAAAAAGGCCGCGTTGCTGGCGTTTTTCCATAGGCTCCGCCCCCCTGACGAGCATCACAAAAATCGACGCTCAAGTCAGAGGTGGCGAAACCCGACAGGACTATAAAGATACCAGGCGTTTCCCCCTGGAAGCTCCCTCGTGCGCTCTCCTGTTCCGACCCTGCCGCTTACCGGATACCTGTCCGCCTTTCTCCCTTCGGGAAGCGTGGCGCTTTCTCATAGCTCACGCTGTAGGTATCTCAGTTCGGTGTAGGTCGTTCGCTCCAAGCTGGGCTGTGTGCACGAACCCCCCGTTCAGCCCGACCGCTGCGCCTTATCCGGTAACTATCGGTCTTGAGTCCAACCCGGTAAGACACGACTTATCGCCACTGGCAGCAGCCACTGGTAACAGGATTAGCAGAGCGAGGTATGTAGGCGGTGCTACAGAGTTCTTGAAGTGGTGGCCTAACTACGGCTACACTAGAAGAACAGTATTTGGTATCTGCGCTCTGCTGAAGCCAGTTACCTTCGGAAAAAGAGTTGGTAGCTCTTGATCCGGCAAACAAACCACCGCTGGTAGCGGTGGTTTTTTTGTTTGCAAGCAGCAGATTACGCGCAGAAAAAAAGGATCTCAAGAAGATCCTTTGATCTTTTCTACGGGGTCTGACGCTCAGTGGAACGAAAACTCACGTTAAGGGATTTTGGTCATGAGATTATCAAAAAGGATCTTCACCTAGATCCTTTTAAATTAAAAATGAAGTTTTAAATCAATCTAAAGTATATATGAGTAAACTTGGTCTGACAGTTACCAATGCTTAATCAGTGAGGCACCTATCTCAGCGATCTGTCTATTTCGTTCATCCATAGTTGCCTGACTCCCCGTCGTGTAGATAACTACGATACGGGAGGGCTTACCATCTGGCCCCAGTGCTGCAATGATACCGCGAGACCCACGCTCACCGGCTCCAGATTTATCAGCAATAAACCAGCCAGCCGGAAGGGCCGAGCGCAGAAGTGGTCCTGCAACTTTATCCGCCTCCATCCAGTCTATTAATTGTTGCCGGGAAGCTAGAGTAAGTAGTTCGCCAGTTAATAGTTTGCGCAACGTTGTTGCCATTGCTACAGGCATCGTGGTGTCACGCTCGTCGTTTGGTATGGCTTCATTCAGCTCCGGTTCCCAACGATCAAGGCGAGTTACATGATCCCCCATGTTGTGCAAAAAAGCGGTTAGCTCCTTCGGTCCTCCGATCGTTGTCAGAAGTAAGTTGGCCGCAGTGTTATCACTCATGGTTATGGCAGCACTGCATAATTCTCTTACTGTCATGCCATCCGTAAGATGCTTTTCTGTGACTGGTGAGTACTCAACCAAGTCATTCTGAGAATAGTGTATGCGGCGACCGAGTTGCTCTTGCCCGGCGTCAATACGGGATAATACCGCGCCACATAGCAGAACTTTAAAAGTGCTCATCATTGGAAAACGTTCTTCGGGGCGAAAACTCTCAAGGATCTTACCGCTGTTGAGATCCAGTTCGATGTAACCCACTCGTGCACCCAACTGATCTTCAGCATCTTTTACTTTCACCAGCGTTTCTGGGTGAGCAAAAACAGGAAGGCAAAATGCCGCAAAAAAGGGAATAAGGGCGACACGGAAATGTTGAATACTCATACTCTTCCTTTTTCAATATTATTGAAGCATTTATCAGGGTTATTGTCTCATGAGCGGATACATATTTGAATGTATTTAGAAAAATAAACAAATAGGGGTTCCGCGCACATTTCCCCGAAAAGTGCCACCTGACGTCTAAGAAACCATTATTATCATGACATTAACCTATAAAAATAGGCGTATCACGAGGCCCTTTCGTCTCGCGCGTTTCGGTGATGACGGTGAAAACCTCTGACACATGCAGCTCCCGGAGACGGTCACAGCTTGTCTGTAAGCGGATGCCGGGAGCAGACAAGCCCGTCAGGGCGCGTCAGCGGGTGTTGGCGGGTGTCGGGGCTGGCTTAACTATGCGGCATCAGAGCAGATTGTACTGAGAGTGCACCATATGCGGTGTGAAATACCGCACAGATGCGTAAGGAGAAAATACCGCATCAGGCGCCATTCGCCATTCAGGCTGCGCAACTGTTGGGAAGGGCGATCGGTGCGGGCCTCTTCGCTATTACGCCAGCTGGCGAAAGGGGGATGTGCTGCAAGGCGATTAAGTTGGGTAACGCCAGGGTTTTCCCAGTCACGACGTTGTAAAACGACGGCCAGT"
        let name = targetPlasmid?.name ?? "pETDuet-Demo"
        let isCirc = targetPlasmid?.dnaInfo.isCircular ?? true
        
        lanes.removeAll(where: \.isVirtualDigestLane)
        let vLane = GelAnalysisEngine.buildVirtualDigestLane(
            plasmidName: name,
            sequence: seq,
            isCircular: isCirc,
            enzymeNames: [selectedEnzyme1, selectedEnzyme2],
            fit: calibrationFit,
            laneIndex: lanes.count + 1
        )
        lanes.append(vLane)
        appState.showToast("已生成「\(name)」(\(selectedEnzyme1)+\(selectedEnzyme2)) 虚拟酶切对照道")
    }
    
    private func importGelImage() {
        FinderFileDropHelper.presentOpenPanel { url in
            if let img = NSImage(contentsOf: url),
               let loadedPlane = BioImagePlane.fromNSImage(img, maxDimension: 520) {
                sourceImageURL = url
                plane = loadedPlane
                runAutoDetection()
                appState.showToast("已导入电泳胶图并完成自动寻道与分子量拟合")
            }
        }
    }
    
    private func exportGelCSV() {
        let curLanes = lanes
        let curLadder = activeLadder
        let curFit = calibrationFit
        let curSourceURL = sourceImageURL
        let hasVirtual = curLanes.contains(where: \.isVirtualDigestLane)
        let enzymes = hasVirtual ? [selectedEnzyme1, selectedEnzyme2] : []
        let linkedIDs = hasVirtual ? [plasmidPool.selectedItem?.id ?? plasmidPool.items.first?.id].compactMap { $0 } : []
        let csv = GelAnalysisEngine.exportGelBandsCSV(lanes: curLanes, unit: curLadder.kind.unit)
        FinderFileDropHelper.saveTextToFile(
            content: csv,
            defaultFileName: "Gel_Electrophoresis_MolecularWeight_Fit.csv",
            contentType: .commaSeparatedText,
            toastPrefix: "已导出电泳条带分子量 CSV",
            onSavedURL: { savedURL in
                _ = try? GelAnalysisEngine.exportGelBandsCSVWithProvenance(
                    lanes: curLanes,
                    ladder: curLadder,
                    fit: curFit,
                    sourceImageURL: curSourceURL,
                    virtualDigestEnzymes: enzymes,
                    linkedPlasmidIDs: linkedIDs,
                    to: savedURL
                )
            }
        )
    }
}
