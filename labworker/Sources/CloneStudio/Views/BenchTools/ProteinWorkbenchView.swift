import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers
import CloneStudioCore

// MARK: - 极简声明式窗口响应式蛋白质工作台视图 (SPICE + LIGSITE P-S-P 口袋 + Vina 对接盒)

public struct ProteinWorkbenchView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var plasmidPool = PlasmidPoolManager.shared

    @State private var selectedPresetID: String = ProteinBiophysicsEngine.builtinExamples[0].id
    @State private var rawSequence: String = ProteinBiophysicsEngine.builtinExamples[0].sequence
    @State private var importedPDBText: String? = nil
    @State private var env: ProteinEnvironmentParams = ProteinEnvironmentParams()

    // 极简折叠抽屉：默认收起序列编辑框与环境滑块，保持首屏清爽
    @State private var isShowingSourceEditor: Bool = false

    // 3D 视口旋转、缩放与着色模式（无画布遮挡浮层）
    @State private var yawAngle: Double = 0.45
    @State private var pitchAngle: Double = 0.25
    @State private var lastYaw: Double = 0.45
    @State private var lastPitch: Double = 0.25
    @State private var zoomScale: Double = 1.0
    @State private var colorSchemeMode: StructureColorMode = .plddt
    @State private var showContactLines: Bool = true
    @State private var showPocketHighlight: Bool = true
    @State private var focusPocketOnly: Bool = false
    @State private var showDockingBoxWireframe: Bool = true
    @State private var selectedResidueIndex: Int? = nil

    // 精简为 4 个短标签，消除窄窗口分段控件挤压
    @State private var analysisTab: ProteinAnalysisTab = .dockingBox
    @State private var mutantInputText: String = "V13A\nI15L + L19M\nK27R\nF42W\nT48P"

    public enum StructureColorMode: String, CaseIterable, Identifiable {
        case plddt = "plddt"
        case secondary = "secondary"
        case hydropathy = "hydropathy"
        case pocket = "pocket"

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .plddt:      return "pLDDT"
            case .secondary:  return "二级结构"
            case .hydropathy: return "疏水性"
            case .pocket:     return "结合口袋"
            }
        }
    }

    public enum ProteinAnalysisTab: String, CaseIterable, Identifiable {
        case dockingBox = "dockingBox"
        case ramachandran = "ramachandran"
        case contactAndHydro = "contactAndHydro"
        case mutants = "mutants"

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .dockingBox:      return "口袋与对接盒"
            case .ramachandran:    return "拉氏构象图"
            case .contactAndHydro: return "接触与疏水"
            case .mutants:         return "点突变 ΔΔG"
            }
        }
    }

    public init() {}

    private var report: ProteinBiophysicsReport {
        ProteinBiophysicsEngine.analyzeProtein(
            sequence: rawSequence,
            pdbText: importedPDBText,
            env: env
        )
    }

    private var mutantResults: [ProteinMutantEvaluation] {
        let lines = mutantInputText.components(separatedBy: .newlines)
        return ProteinBiophysicsEngine.evaluateMutantsBatch(
            wildTypeSequence: report.sequence,
            mutationSpecs: lines,
            env: env
        )
    }

    public var body: some View {
        let currentReport = report
        StudioPageLayout(
            title: "蛋白工作台",
            toolbar: [
                .action(title: "导入", icon: "folder.badge.plus", help: "导入 PDB / CIF / FASTA 文件", action: importStructureOrSequenceFile),
                .action(title: "Vina", icon: "cube.box.fill", tint: .orange, help: "复制 AutoDock Vina 结合口袋对接盒参数") {
                    copyVinaConfig(report: currentReport)
                },
                .action(title: "HTML", icon: "doc.richtext", tint: .teal, help: "导出离线 HTML 生物物理分析报告") {
                    exportHTMLReport(report: currentReport)
                },
                .action(title: "PDB", icon: "square.and.arrow.up", tint: .green, help: "导出带 B-factor 质控信息的 PDB 结构文件") {
                    exportPDBFile(report: currentReport)
                }
            ]
        ) {
            // 1. 极简样本切换与按需展开的序列/环境参数抽屉
            compactPresetAndSourceBar

            // 2. 声明式窗口响应式主工作区：宽屏左右双栏，窄屏 (<860pt) 自动切换为上下堆叠
            StudioResponsiveSplitLayout(breakpoint: 860, spacing: 14, leftRatio: 0.50) {
                VStack(spacing: 14) {
                    structure3DViewerCard(report: currentReport)
                    spiceQualityMetricsCard(report: currentReport)
                }

                VStack(spacing: 14) {
                    biophysicsSummaryCard(report: currentReport)
                    analysisChartsCard(report: currentReport)
                }
            }
        }
        .onAppear {
            env.ph = appState.defaultProteinPH
            env.temperatureK = appState.defaultProteinTempK
            consumePendingFinderProteinFileIfNeeded()
        }
        .onChange(of: appState.pendingFinderOpenedFileURL) { _, _ in
            consumePendingFinderProteinFileIfNeeded()
        }
        .onChange(of: appState.defaultProteinPH) { _, newPH in
            env.ph = newPH
        }
        .onChange(of: appState.defaultProteinTempK) { _, newT in
            env.temperatureK = newT
        }
    }

    private func consumePendingFinderProteinFileIfNeeded() {
        guard let url = appState.pendingFinderOpenedFileURL,
              let content = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .ascii)) else { return }
        let ext = url.pathExtension.lowercased()
        guard ["pdb", "cif", "ent", "fa", "fasta", "seq", "txt"].contains(ext) else { return }
        appState.pendingFinderOpenedFileURL = nil
        if ["pdb", "cif", "ent"].contains(ext) || content.contains("ATOM  ") {
            importedPDBText = content
            let parsed = ProteinBiophysicsEngine.parsePDBResidues(content)
            if !parsed.isEmpty {
                rawSequence = parsed.map(\.oneLetter).joined()
            }
        } else {
            importedPDBText = nil
            rawSequence = ProteinBiophysicsEngine.cleanProteinSequence(content)
        }
    }

    // MARK: - 1. 极简样本切换条 + 按需展开的序列/环境抽屉

    private var compactPresetAndSourceBar: some View {
        let currentReport = report
        return StudioCard(title: "样本选择与生理环境参数") {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
                StudioMetricBadge(
                    label: "",
                    value: "\(currentReport.length) aa · \(String(format: "%.1f kDa", currentReport.molecularWeightDa / 1000.0))",
                    color: .blue
                )
                StudioMetricBadge(
                    label: "pI / Q",
                    value: "\(String(format: "%.2f", currentReport.isoelectricPoint)) / \(String(format: "%.1f", currentReport.compositeQScore))",
                    color: .teal
                )
                StudioMetricBadge(
                    label: "坐标源",
                    value: importedPDBText != nil ? "外部实验/AlphaFold PDB" : "SPICE 启发式折叠",
                    color: importedPDBText != nil ? .green : .teal
                )
                StudioCompactPillButton(
                    title: isShowingSourceEditor ? "收起配置" : "编辑序列 (pH \(String(format: "%.1f", env.ph)) · \(String(format: "%.0fK", env.temperatureK)))",
                    icon: isShowingSourceEditor ? "chevron.up.circle.fill" : "slider.horizontal.3",
                    tint: .accentColor,
                    isSelected: isShowingSourceEditor
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isShowingSourceEditor.toggle()
                    }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(ProteinBiophysicsEngine.builtinExamples) { ex in
                        let isSel = (selectedPresetID == ex.id && importedPDBText == nil)
                        StudioCompactPillButton(
                            title: ex.name,
                            icon: "atom",
                            isProminent: isSel
                        ) {
                            selectedPresetID = ex.id
                            importedPDBText = nil
                            rawSequence = ex.sequence
                        }
                    }

                    if !plasmidPool.items.isEmpty {
                        StudioMenuPillButton(
                            title: "质粒池 CDS 导入",
                            icon: "tray.2.fill",
                            tint: .purple,
                            compact: true,
                            help: "从质粒池选区 CDS 翻译导入蛋白序列"
                        ) {
                            ForEach(plasmidPool.items) { item in
                                ForEach(item.cdsAndGeneFeatures) { feat in
                                    Button("\(item.name) → \(feat.name)") {
                                        loadCDSFromPlasmid(item: item, feature: feat)
                                    }
                                }
                            }
                        }
                    }
                }

                if isShowingSourceEditor {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $rawSequence)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 58)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.92))
                            .clipShape(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )

                        StudioFlowLayout(horizontalSpacing: 16, verticalSpacing: 8) {
                            HStack(spacing: 6) {
                                Text("溶液 pH")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                Slider(value: $env.ph, in: 4.0...10.0, step: 0.2)
                                    .frame(width: 95)
                                Text(String(format: "%.1f", env.ph))
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .frame(width: 32, alignment: .trailing)
                            }

                            HStack(spacing: 6) {
                                Text("温度 (K)")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                Slider(value: $env.temperatureK, in: 275.0...350.0, step: 5.0)
                                    .frame(width: 95)
                                Text(String(format: "%.0f K", env.temperatureK))
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .frame(width: 44, alignment: .trailing)
                            }

                            HStack(spacing: 6) {
                                Text("离子强度")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                Slider(value: $env.ionicStrengthM, in: 0.0...1.0, step: 0.05)
                                    .frame(width: 85)
                                Text(String(format: "%.2f M", env.ionicStrengthM))
                                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                    .frame(width: 46, alignment: .trailing)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: - 2. 无浮层遮挡的三维视窗 (自适应流式工具栏置顶)

    private func structure3DViewerCard(report: ProteinBiophysicsReport) -> some View {
        StudioCard(title: "三维 Cα 骨架与 Vina 对接盒视窗") {
            StudioSegmentedPicker(
                selection: $colorSchemeMode,
                options: StructureColorMode.allCases.map {
                    StudioSegmentedOption(value: $0, title: $0.title, tint: .blue)
                }
            )
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                // 响应式控制栏：脱离 3D 画布，窄窗自动换行，不遮挡三维结构
                StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 6) {
                    Toggle("聚焦口袋", isOn: $focusPocketOnly)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11, weight: .medium))
                    Toggle("Vina 对接盒", isOn: $showDockingBoxWireframe)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11, weight: .medium))
                    Toggle("接触虚线", isOn: $showContactLines)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11, weight: .medium))
                    Toggle("口袋光晕", isOn: $showPocketHighlight)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11, weight: .medium))

                    HStack(spacing: 4) {
                        Text("缩放")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Slider(value: $zoomScale, in: 0.65...2.2)
                            .frame(width: 72)
                    }

                    StudioCompactPillButton(title: "重置视角", icon: "arrow.counterclockwise") {
                        yawAngle = 0.45
                        pitchAngle = 0.25
                        lastYaw = 0.45
                        lastPitch = 0.25
                        zoomScale = 1.0
                    }
                }

                // 纯净 3D 画布（无右下角黑色胶囊浮层遮挡）
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.07, green: 0.09, blue: 0.14),
                                    Color(red: 0.11, green: 0.14, blue: 0.21)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Canvas { ctx, size in
                        drawProtein3DScene(
                            ctx: &ctx,
                            size: size,
                            report: report
                        )
                    }
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { val in
                                yawAngle = lastYaw + Double(val.translation.width) * 0.012
                                pitchAngle = max(-1.45, min(1.45, lastPitch + Double(val.translation.height) * 0.012))
                            }
                            .onEnded { _ in
                                lastYaw = yawAngle
                                lastPitch = pitchAngle
                            }
                    )

                    if let selIdx = selectedResidueIndex,
                       let res = report.residues.first(where: { $0.index == selIdx }) {
                        Text("\(res.threeLetter)\(res.index) (\(res.oneLetter)) · \(res.secondary.title) · pLDDT \(String(format: "%.1f", res.plddt))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                            .padding(8)
                    }
                }
                .frame(minHeight: 270, idealHeight: 310)

                // 底部轻量状态摘要行（自适应折行）
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
                    StudioMetricBadge(
                        label: "回旋半径 Rg",
                        value: String(format: "%.1f Å", report.radiusOfGyrationA),
                        color: .cyan
                    )
                    if let pocket = report.pockets.first {
                        StudioMetricBadge(
                            label: "主口袋评分",
                            value: String(format: "%.2f · 包埋 %.0f%%", pocket.druggabilityScore, pocket.enclosureRatio * 100.0),
                            color: .orange
                        )
                    }
                    StudioMetricBadge(
                        label: "盒子依据",
                        value: report.dockingBox.sourceTitle,
                        color: .indigo
                    )
                }
            }
        }
    }

    private func drawProtein3DScene(
        ctx: inout GraphicsContext,
        size: CGSize,
        report: ProteinBiophysicsReport
    ) {
        let residues = report.residues
        guard !residues.isEmpty else { return }

        let n = Double(residues.count)
        let cx = residues.reduce(0.0) { $0 + $1.x } / n
        let cy = residues.reduce(0.0) { $0 + $1.y } / n
        let cz = residues.reduce(0.0) { $0 + $1.z } / n

        let cosY = cos(yawAngle), sinY = sin(yawAngle)
        let cosP = cos(pitchAngle), sinP = sin(pitchAngle)

        func project(_ x: Double, _ y: Double, _ z: Double) -> (px: CGFloat, py: CGFloat, depth: Double) {
            let dx = x - cx
            let dy = y - cy
            let dz = z - cz
            let rx = dx * cosY + dz * sinY
            let rz1 = -dx * sinY + dz * cosY
            let ry = dy * cosP - rz1 * sinP
            let rz = dy * sinP + rz1 * cosP
            let baseScale = min(size.width, size.height) / max(26.0, report.radiusOfGyrationA * 2.5) * CGFloat(zoomScale)
            let perspective = 1.0 + rz * 0.012
            let px = size.width * 0.5 + CGFloat(rx * perspective) * baseScale
            let py = size.height * 0.5 + CGFloat(ry * perspective) * baseScale
            return (px, py, rz)
        }

        let projected = residues.map { r in
            (res: r, pt: project(r.x, r.y, r.z))
        }

        // 1. 绘制结合口袋半透明球形包络
        if showPocketHighlight {
            for pocket in report.pockets {
                let pCenter = project(pocket.centerX, pocket.centerY, pocket.centerZ)
                let radiusPx = CGFloat(max(24.0, min(68.0, cbrt(pocket.volumeA3) * 3.8 * zoomScale)))
                let rect = CGRect(
                    x: pCenter.px - radiusPx,
                    y: pCenter.py - radiusPx,
                    width: radiusPx * 2,
                    height: radiusPx * 2
                )
                ctx.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [Color.orange.opacity(0.30), Color.orange.opacity(0.02)]),
                        center: CGPoint(x: pCenter.px, y: pCenter.py),
                        startRadius: 2,
                        endRadius: radiusPx
                    )
                )
            }
        }

        // 2. 绘制三维 Vina 搜索盒子 12 棱线框
        if showDockingBoxWireframe {
            let b = report.dockingBox
            let hx = b.sizeX * 0.5, hy = b.sizeY * 0.5, hz = b.sizeZ * 0.5
            let corners: [(Double, Double, Double)] = [
                (b.centerX - hx, b.centerY - hy, b.centerZ - hz),
                (b.centerX + hx, b.centerY - hy, b.centerZ - hz),
                (b.centerX + hx, b.centerY + hy, b.centerZ - hz),
                (b.centerX - hx, b.centerY + hy, b.centerZ - hz),
                (b.centerX - hx, b.centerY - hy, b.centerZ + hz),
                (b.centerX + hx, b.centerY - hy, b.centerZ + hz),
                (b.centerX + hx, b.centerY + hy, b.centerZ + hz),
                (b.centerX - hx, b.centerY + hy, b.centerZ + hz)
            ]
            let pCorners = corners.map { project($0.0, $0.1, $0.2) }
            let edges: [(Int, Int)] = [
                (0, 1), (1, 2), (2, 3), (3, 0),
                (4, 5), (5, 6), (6, 7), (7, 4),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]
            var boxPath = Path()
            for (u, v) in edges {
                boxPath.move(to: CGPoint(x: pCorners[u].px, y: pCorners[u].py))
                boxPath.addLine(to: CGPoint(x: pCorners[v].px, y: pCorners[v].py))
            }
            ctx.stroke(
                boxPath,
                with: .color(Color.yellow.opacity(0.68)),
                style: StrokeStyle(lineWidth: 1.25, dash: [5, 3])
            )
        }

        // 3. 绘制长程非共价接触虚线 (< 8.5 Å)
        if showContactLines {
            for contact in report.contacts.prefix(120) {
                guard contact.resI >= 1 && contact.resI <= projected.count,
                      contact.resJ >= 1 && contact.resJ <= projected.count else { continue }
                let a = projected[contact.resI - 1]
                let b = projected[contact.resJ - 1]
                if focusPocketOnly && !(a.res.isPocketResidue || b.res.isPocketResidue) {
                    continue
                }
                var path = Path()
                path.move(to: CGPoint(x: a.pt.px, y: a.pt.py))
                path.addLine(to: CGPoint(x: b.pt.px, y: b.pt.py))
                ctx.stroke(
                    path,
                    with: .color(focusPocketOnly ? Color.yellow.opacity(0.55) : Color.cyan.opacity(0.24)),
                    style: StrokeStyle(lineWidth: focusPocketOnly ? 1.4 : 0.9, dash: [3, 3])
                )
            }
        }

        // 4. 绘制主链连续骨架丝带
        for i in 0..<(projected.count - 1) {
            let a = projected[i]
            let b = projected[i + 1]
            var seg = Path()
            seg.move(to: CGPoint(x: a.pt.px, y: a.pt.py))
            seg.addLine(to: CGPoint(x: b.pt.px, y: b.pt.py))
            let isPocketSeg = a.res.isPocketResidue && b.res.isPocketResidue
            let col = colorForResidue(a.res)
            let alpha: Double = focusPocketOnly ? (isPocketSeg ? 0.95 : 0.14) : 0.88
            let lineW: CGFloat = focusPocketOnly
                ? (isPocketSeg ? 3.2 : 1.1)
                : ((a.res.secondary == .helix) ? 3.6 : ((a.res.secondary == .sheet) ? 3.2 : 2.0))
            ctx.stroke(seg, with: .color(col.opacity(alpha)), style: StrokeStyle(lineWidth: lineW, lineCap: .round))
        }

        // 5. 按 Z 深度排序绘制 Cα 球体节点
        for item in projected.sorted(by: { $0.pt.depth < $1.pt.depth }) {
            if focusPocketOnly && !item.res.isPocketResidue {
                continue
            }
            let col = colorForResidue(item.res)
            let rad: CGFloat = item.res.isPocketResidue ? 5.4 : 4.0
            let rect = CGRect(
                x: item.pt.px - rad,
                y: item.pt.py - rad,
                width: rad * 2,
                height: rad * 2
            )
            ctx.fill(Path(ellipseIn: rect), with: .color(col))
            if item.res.isPocketResidue && showPocketHighlight {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(.orange), lineWidth: 1.2)
            }
        }
    }

    private func colorForResidue(_ r: ProteinResidue3D) -> Color {
        switch colorSchemeMode {
        case .plddt:
            if r.plddt >= 90 { return Color(red: 0.12, green: 0.48, blue: 0.96) }
            if r.plddt >= 70 { return Color(red: 0.25, green: 0.78, blue: 0.88) }
            if r.plddt >= 50 { return Color(red: 0.96, green: 0.80, blue: 0.18) }
            return Color(red: 0.95, green: 0.42, blue: 0.22)
        case .secondary:
            switch r.secondary {
            case .helix: return .pink
            case .sheet: return .yellow
            case .coil:  return .mint
            }
        case .hydropathy:
            if r.hydropathy >= 1.5 { return .orange }
            if r.hydropathy <= -1.5 { return .cyan }
            return .gray
        case .pocket:
            return r.isPocketResidue ? .orange : Color.white.opacity(0.35)
        }
    }

    // MARK: - 3. SPICE 五维折叠与热力学质量评分卡 (自适应网格)

    private func spiceQualityMetricsCard(report: ProteinBiophysicsReport) -> some View {
        StudioCard(title: "SPICE 五维构象与能量评估 (M1–M5)") {
            StudioMetricBadge(
                label: "综合 Q 分",
                value: String(format: "%.1f / 100", report.compositeQScore),
                color: report.compositeQScore >= 75 ? .green : .orange
            )
        } content: {
            let items: [(label: String, val: Double, color: Color)] = [
                ("M1 疏水核心堆积密度", report.metricM1Packing, .blue),
                ("M2 主链氢键网络饱和度", report.metricM2HBond, .teal),
                ("M3 拉氏构象允许区占比", report.metricM3Ramachandran, .green),
                ("M4 溶剂化自由能匹配度", report.metricM4Solvation, .indigo),
                ("M5 表面静电互补性", report.metricM5Electrostatics, .purple)
            ]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 360), spacing: 10)], spacing: 8) {
                ForEach(items, id: \.label) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.label)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f%%", item.val))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(item.color)
                        }
                        GeometryReader { barGeo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.08))
                                Capsule()
                                    .fill(item.color.gradient)
                                    .frame(width: barGeo.size.width * CGFloat(min(1.0, max(0.0, item.val / 100.0))))
                            }
                        }
                        .frame(height: 5)
                    }
                    .studioInnerBox(paddingH: 8, paddingV: 7)
                }
            }
        }
    }

    // MARK: - 4. 理化性质汇总卡片 (GridItem(.adaptive) 窗口缩放自适应列数)

    private func biophysicsSummaryCard(report: ProteinBiophysicsReport) -> some View {
        StudioCard(title: "蛋白质生物物理与溶液性质") {
            StudioMetricBadge(
                label: "稳定性判定",
                value: report.isStable ? "稳定 (II < 40)" : "易降解风险",
                color: report.isStable ? .green : .orange
            )
        } content: {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145, maximum: 260), spacing: 8)],
                spacing: 8
            ) {
                metricTile(
                    title: "分子量 (MW)",
                    value: String(format: "%.2f kDa", report.molecularWeightDa / 1000.0),
                    sub: "\(Int(report.molecularWeightDa)) Da"
                )
                metricTile(
                    title: "理论等电点 (pI)",
                    value: String(format: "%.2f", report.isoelectricPoint),
                    sub: "pH \(String(format: "%.1f", env.ph)) 电荷 \(String(format: "%+.1f", report.netChargeAtEnvPh))"
                )
                metricTile(
                    title: "消光系数 ε280",
                    value: "\(report.extinctionReduced)",
                    sub: "A0.1% = \(String(format: "%.2f", report.abs01PctReduced))"
                )
                metricTile(
                    title: "平均疏水性 GRAVY",
                    value: String(format: "%+.3f", report.gravy),
                    sub: "脂溶指数 \(String(format: "%.1f", report.aliphaticIndex))"
                )
                metricTile(
                    title: "不稳定指数 (II)",
                    value: String(format: "%.1f", report.instabilityIndex),
                    sub: "无序倾向 \(String(format: "%.1f%%", report.disorderPct))"
                )
                metricTile(
                    title: "二级结构分布",
                    value: "H \(Int(report.helixPct))% · E \(Int(report.sheetPct))%",
                    sub: "Coil \(Int(report.coilPct))%"
                )
            }
        }
    }

    private func metricTile(title: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(sub)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioInnerBox(paddingH: 9, paddingV: 9)
    }

    // MARK: - 5. 四合一结构、对接盒子与突变分析面板

    private func analysisChartsCard(report: ProteinBiophysicsReport) -> some View {
        StudioCard(title: "对接盒子、构象评估与点突变热力学") {
            StudioSegmentedPicker(
                selection: $analysisTab,
                options: ProteinAnalysisTab.allCases.map {
                    StudioSegmentedOption(value: $0, title: $0.title, tint: .indigo)
                }
            )
        } content: {
            switch analysisTab {
            case .dockingBox:
                dockingBoxAndHealthView(report: report)
            case .ramachandran:
                ramachandranPlotView(report: report)
            case .contactAndHydro:
                contactAndHydropathyCombinedView(report: report)
            case .mutants:
                mutantScreeningView
            }
        }
    }

    /// 响应式「证据优先 Vina 对接搜索盒子 + 柔性侧链推荐 + 结构体检卡」视图
    private func dockingBoxAndHealthView(report: ProteinBiophysicsReport) -> some View {
        let box = report.dockingBox
        let hc = report.healthCard
        return VStack(alignment: .leading, spacing: 10) {
            // 1. 证据来源与一键复制 Vina 配置（使用 StudioFlowLayout 自适应折行）
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                StudioMetricBadge(label: "决策来源", value: box.sourceTitle, color: .orange)
                StudioMetricBadge(label: "盒子体积", value: String(format: "%.0f Å³", box.volumeA3), color: .blue)
                StudioMetricBadge(label: "Exhaustiveness", value: "\(box.recommendedExhaustiveness)", color: .teal)
                StudioActionPillButton(title: "复制 vina_config.txt", icon: "doc.on.doc", tint: .blue, isProminent: true) {
                    copyVinaConfig(report: report)
                }
            }

            Text(box.sourceNote)
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 2. 中心坐标与尺寸自适应网格（窄窗单列，宽窗双列）
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 380), spacing: 8)], spacing: 8) {
                metricTile(
                    title: "对接盒子中心 (Center X, Y, Z)",
                    value: String(format: "(%.2f, %.2f, %.2f) Å", box.centerX, box.centerY, box.centerZ),
                    sub: "Vina center_x / center_y / center_z"
                )
                metricTile(
                    title: "对接盒子尺寸 (Size X × Y × Z)",
                    value: String(format: "%.1f × %.1f × %.1f Å", box.sizeX, box.sizeY, box.sizeZ),
                    sub: "已包含 ±4.0 Å 配体旋转安全边距"
                )
            }

            // 3. 柔性侧链 (--flex) 推荐与耗时提示（使用 ViewThatFits 适配窄窗）
            VStack(alignment: .leading, spacing: 5) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text("近端可旋转柔性侧链推荐 (≤ 6.0 Å):")
                            .font(.system(size: 11.5, weight: .semibold))
                        Spacer()
                        Text(box.recommendedFlexResidues.isEmpty ? "无" : box.recommendedFlexResidues.joined(separator: ", "))
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.indigo)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("近端可旋转柔性侧链推荐 (≤ 6.0 Å):")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(box.recommendedFlexResidues.isEmpty ? "无" : box.recommendedFlexResidues.joined(separator: ", "))
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.indigo)
                    }
                }
                Text(box.runtimeEstimateNote)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioInnerBox(paddingH: 9, paddingV: 9)

            // 4. 结构体检与可信度卡（流式徽章头 + 自动换行告警）
            VStack(alignment: .leading, spacing: 6) {
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: hc.isExperimentalOrAlphaFoldPDB ? "checkmark.shield.fill" : "info.circle.fill")
                            .foregroundColor(hc.isExperimentalOrAlphaFoldPDB ? .green : .orange)
                        Text("结构体检 (\(hc.coordinateSource))")
                            .font(.system(size: 12, weight: .bold))
                    }
                    StudioMetricBadge(label: "链", value: hc.chainIDs.joined(separator: ","), color: .secondary)
                    if !hc.coCrystalLigands.isEmpty {
                        StudioMetricBadge(label: "共晶配体", value: hc.coCrystalLigands.joined(separator: "/"), color: .green)
                    }
                    if !hc.metalIons.isEmpty {
                        StudioMetricBadge(label: "金属离子", value: hc.metalIons.joined(separator: "/"), color: .orange)
                    }
                }

                ForEach(hc.warnings, id: \.self) { warn in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundColor(.orange)
                        Text(warn)
                            .font(.system(size: 11.5))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioInnerBox(tint: .orange, paddingH: 10, paddingV: 10)
        }
    }

    private func ramachandranPlotView(report: ProteinBiophysicsReport) -> some View {
        let validResidues = report.residues.filter { $0.phi != nil && $0.psi != nil }
        return VStack(alignment: .leading, spacing: 6) {
            Text("主链二面角分布 (φ, ψ ∈ [-180°, +180°]) · 核心允许区占比 \(String(format: "%.1f%%", report.metricM3Ramachandran))")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)

            Chart {
                ForEach(validResidues) { r in
                    PointMark(
                        x: .value("Phi (φ)", r.phi ?? 0),
                        y: .value("Psi (ψ)", r.psi ?? 0)
                    )
                    .foregroundStyle(by: .value("二级结构", r.secondary.title))
                    .symbolSize(36)
                }
            }
            .chartXScale(domain: -180...180)
            .chartYScale(domain: -180...180)
            .frame(minHeight: 220)
        }
    }

    /// 合并「Cα 接触图」与「KD 疏水剖面」，宽屏双列并排、窄屏 (<500pt) 自动上下堆叠
    private func contactAndHydropathyCombinedView(report: ProteinBiophysicsReport) -> some View {
        StudioResponsiveSplitLayout(breakpoint: 500, spacing: 12, leftRatio: 0.48) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cα–Cα 接触图 (≤ 8.5 Å，\(report.contacts.count) 对)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.secondary)

                Chart {
                    ForEach(report.contacts) { c in
                        PointMark(
                            x: .value("残基 i", c.resI),
                            y: .value("残基 j", c.resJ)
                        )
                        .foregroundStyle(Color.teal.opacity(0.75))
                        .symbolSize(22)

                        PointMark(
                            x: .value("残基 i", c.resJ),
                            y: .value("残基 j", c.resI)
                        )
                        .foregroundStyle(Color.indigo.opacity(0.65))
                        .symbolSize(22)
                    }
                }
                .chartXScale(domain: 1...max(2, report.length))
                .chartYScale(domain: 1...max(2, report.length))
                .frame(minHeight: 200)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Kyte-Doolittle 疏水性剖面 (窗口 = 7 aa)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.secondary)

                Chart {
                    RuleMark(y: .value("中性线", 0.0))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                    ForEach(report.hydropathyProfile, id: \.index) { pt in
                        LineMark(
                            x: .value("残基位置", pt.index),
                            y: .value("KD 疏水指数", pt.value)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .frame(minHeight: 200)
            }
        }
    }

    private var mutantScreeningView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("输入单点或组合突变（每行一条，如 V13A 或 I15L + L19M），按疏水性/位阻/脯氨酸经验启发式模型 (empirical_heuristic) 进行快速初筛（不等同于 FoldX/Rosetta 全原子自由能计算）：")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)

            TextEditor(text: $mutantInputText)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 64)
                .background(Color(NSColor.textBackgroundColor).opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )

            ForEach(mutantResults) { m in
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(m.mutationSpec)
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .frame(minWidth: 80, alignment: .leading)
                        Text(String(format: "ΔΔG = %+.2f kcal/mol", m.ddgKcalMol))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(m.ddgKcalMol <= 0 ? .green : .orange)
                        Spacer()
                        StudioMetricBadge(
                            label: "",
                            value: m.stabilityVerdict,
                            color: m.ddgKcalMol <= -0.4 ? .green : (m.ddgKcalMol <= 0.5 ? .blue : .red)
                        )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(m.mutationSpec)
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            Spacer()
                            Text(String(format: "ΔΔG = %+.2f kcal/mol", m.ddgKcalMol))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(m.ddgKcalMol <= 0 ? .green : .orange)
                        }
                        StudioMetricBadge(
                            label: "",
                            value: m.stabilityVerdict,
                            color: m.ddgKcalMol <= -0.4 ? .green : (m.ddgKcalMol <= 0.5 ? .blue : .red)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioInnerBox(paddingH: 8, paddingV: 6)
            }
        }
    }

    // MARK: - 6. 导入与导出辅助函数

    private func loadCDSFromPlasmid(item: PlasmidPoolItem, feature: SnapGeneFeature) {
        let fullSeq = BioSequence.clean(item.dnaInfo.sequence)
        guard let seg = feature.segments.first,
              seg.start >= 1, seg.end <= fullSeq.count, seg.start <= seg.end else { return }
        let startIdx = fullSeq.index(fullSeq.startIndex, offsetBy: seg.start - 1)
        let endIdx = fullSeq.index(fullSeq.startIndex, offsetBy: seg.end)
        var subDNA = String(fullSeq[startIdx..<endIdx])
        if feature.directionality == "2" {
            subDNA = BioSequence.reverseComplement(subDNA)
        }
        let codons = CodonTranslator.translateSequence(subDNA, readingFrameOffset: 0)
        let aaSeq = String(codons.map(\.aminoAcid).filter { $0 != "*" })
        if !aaSeq.isEmpty {
            importedPDBText = nil
            rawSequence = aaSeq
            appState.showToast("已将「\(item.name) : \(feature.name)」翻译为 \(aaSeq.count) aa 蛋白质序列")
        }
    }

    private func importStructureOrSequenceFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 PDB 结构文件 (.pdb) 或 FASTA 氨基酸序列"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let content = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .ascii)) {
            if url.pathExtension.lowercased() == "pdb" || content.contains("ATOM  ") {
                importedPDBText = content
                let parsed = ProteinBiophysicsEngine.parsePDBResidues(content)
                if !parsed.isEmpty {
                    rawSequence = parsed.map(\.oneLetter).joined()
                }
                appState.showToast("已载入 PDB 三维结构：\(url.lastPathComponent) (\(parsed.count) 残基)")
            } else {
                importedPDBText = nil
                rawSequence = ProteinBiophysicsEngine.cleanProteinSequence(content)
                appState.showToast("已导入氨基酸序列：\(url.lastPathComponent)")
            }
        }
    }

    private func copyVinaConfig(report: ProteinBiophysicsReport) {
        let cfg = report.dockingBox.vinaConfigText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cfg, forType: .string)
        appState.showToast("已复制 AutoDock Vina / Smina 对接盒子配置 (vina_config.txt) 至剪贴板")
    }

    private func exportHTMLReport(report: ProteinBiophysicsReport) {
        let box = report.dockingBox
        let html = FinderFileDropHelper.buildOfflineHTMLReport(
            title: "蛋白质三维结构、LIGSITE 结合口袋与 Vina 对接盒子报告",
            subtitle: "序列长度 \(report.length) aa · 环境 pH \(String(format: "%.1f", env.ph)) · 温度 \(String(format: "%.0f K", env.temperatureK))",
            credibilityBadge: report.healthCard.credibilitySummary,
            warnings: report.healthCard.warnings + [
                box.sourceNote,
                box.runtimeEstimateNote,
                "点突变 ΔΔG 评估采用经验启发式模型 (empirical_heuristic：基于 Kyte-Doolittle 疏水性差异、残基质量位阻与脯氨酸罚分)，仅用于快速初筛，不等同于 FoldX / Rosetta 全原子能量函数。"
            ],
            metrics: [
                ("氨基酸长度", "\(report.length) aa"),
                ("分子量 (MW)", String(format: "%.2f kDa", report.molecularWeightDa / 1000.0)),
                ("理论等电点 (pI)", String(format: "%.2f", report.isoelectricPoint)),
                ("平均疏水性 GRAVY", String(format: "%+.3f", report.gravy)),
                ("回旋半径 Rg", String(format: "%.2f Å", report.radiusOfGyrationA)),
                ("综合折叠质量 Q", String(format: "%.1f / 100", report.compositeQScore)),
                ("口袋 LIGSITE 评分", String(format: "%.2f", report.pockets.first?.druggabilityScore ?? 0)),
                ("Vina 盒子中心", String(format: "(%.1f, %.1f, %.1f)", box.centerX, box.centerY, box.centerZ))
            ],
            tableHeaders: ["突变组合", "ΔΔG (kcal/mol)", "ΔGRAVY", "ΔCharge", "综合评分", "稳定性结论"],
            tableRows: mutantResults.map { m in
                [
                    m.mutationSpec,
                    String(format: "%+.2f", m.ddgKcalMol),
                    String(format: "%+.3f", m.deltaGravy),
                    String(format: "%+.2f", m.deltaCharge),
                    String(format: "%.1f", m.compositeScore),
                    m.stabilityVerdict
                ]
            },
            extraPreBlockTitle: "4. AutoDock Vina / Smina 对接配置文件 (vina_config.txt)",
            extraPreBlockContent: box.vinaConfigText
        )
        FinderFileDropHelper.saveHTMLReport(
            htmlContent: html,
            defaultFileName: "Labworker_Protein_DockingBox_Report_\(report.length)aa.html"
        )
    }

    private func exportPDBFile(report: ProteinBiophysicsReport) {
        let pdb = ProteinBiophysicsEngine.exportPDB(report: report)
        FinderFileDropHelper.saveTextToFile(
            content: pdb,
            defaultFileName: "Labworker_Folded_Structure_\(report.length)aa.pdb",
            contentType: .plainText,
            toastPrefix: "已导出三维结构 PDB"
        )
    }
}
