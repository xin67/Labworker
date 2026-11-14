import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CloneStudioCore

/// 系统发育树多布局交互画布与拓扑对比主视图 (纯声明式响应式 UI：任意拉动窗口自动折行与自适应画布宽度缩放)
public struct PhylogeneticTreeView: View {
    @ObservedObject private var appState = AppState.shared
    
    @State private var newickText: String = PhylogeneticTreeEngine.defaultExampleNewick
    @State private var metadataCSVText: String = PhylogeneticTreeEngine.defaultExampleMetadataCSV
    @State private var compareNewickText: String = PhylogeneticTreeEngine.defaultComparisonNewick
    
    @State private var rootNode: PhyloTreeNode = (try? PhylogeneticTreeEngine.parseNewick(PhylogeneticTreeEngine.defaultExampleNewick)) ?? PhyloTreeNode(id: "root", name: "Root")
    @State private var parseError: String? = nil
    
    @State private var layoutMode: PhyloLayoutMode = .phylogram
    @State private var collapsedIDs: Set<String> = []
    @State private var selectedNodeID: String? = nil
    @State private var searchQuery: String = ""
    @State private var supportThreshold: Double = 70.0
    @State private var showSupport: Bool = true
    @State private var showBranchLengths: Bool = false
    @State private var showScaleBar: Bool = true
    @State private var showMetadataEditor: Bool = false
    @State private var showComparePanel: Bool = false
    @State private var canvasAvailableWidth: CGFloat = 680
    
    public init() {}
    
    private var resolvedMetadata: PhyloResolvedMetadata {
        PhylogeneticTreeEngine.parseMetadataCSV(metadataCSVText)
    }
    
    private var treeLayout: PhyloTreeLayout {
        PhylogeneticTreeEngine.computeLayout(
            root: rootNode,
            mode: layoutMode,
            fontSize: 12.0,
            collapsedIDs: collapsedIDs,
            metadata: resolvedMetadata,
            showScaleBar: showScaleBar
        )
    }
    
    private var highlightedPathIDs: Set<String> {
        var ids = Set<String>()
        if let selID = selectedNodeID {
            ids.formUnion(PhylogeneticTreeEngine.ancestorPath(root: rootNode, targetID: selID))
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            for leaf in PhylogeneticTreeEngine.collectLeafNodes(rootNode) where leaf.name.lowercased().contains(q) {
                ids.formUnion(PhylogeneticTreeEngine.ancestorPath(root: rootNode, targetID: leaf.id))
            }
        }
        return ids
    }
    
    private var modeOptions: [StudioSegmentedOption<PhyloLayoutMode>] {
        PhyloLayoutMode.allCases.map { mode in
            StudioSegmentedOption(value: mode, title: mode.shortTitle, tint: .green)
        }
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "进化树",
            trailing: {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    StudioSegmentedPicker(selection: $layoutMode, options: modeOptions)
                    
                    StudioSegmentedPillGroup(items: [
                        StudioPillGroupItem(title: "阶梯", icon: "list.number", tint: .blue, help: "完成进化树阶梯化排序 (Ladderize)") {
                            rootNode = PhylogeneticTreeEngine.ladderize(rootNode, descending: false)
                            appState.showToast("已完成进化树阶梯化排序 (Ladderize)")
                        },
                        StudioPillGroupItem(title: "定根", icon: "arrow.triangle.branch", tint: .teal, help: "按最长路径中点重新定根 (Midpoint Rooting)") {
                            if let rerooted = PhylogeneticTreeEngine.midpointRoot(rootNode) {
                                rootNode = rerooted
                                appState.showToast("已按最长路径中点重新定根 (Midpoint Rooting)")
                            } else {
                                appState.showToast("当前进化树无有效正枝长，无法执行中点定根")
                            }
                        },
                        StudioPillGroupItem(title: "导出", icon: "square.and.arrow.up", tint: .green, help: "导出编辑后的 Newick 树文件") {
                            exportEditedNewick()
                        }
                    ])
                }
            }
        ) {
            StudioResponsiveSplitLayout(breakpoint: 860, spacing: 14, leftRatio: 0.37) {
                leftColumn
                rightColumn
            }
        }
        .onAppear {
            consumePendingFinderTreeFileIfNeeded()
        }
        .onChange(of: appState.pendingFinderOpenedFileURL) { _, _ in
            consumePendingFinderTreeFileIfNeeded()
        }
    }
    
    private func consumePendingFinderTreeFileIfNeeded() {
        guard let url = appState.pendingFinderOpenedFileURL,
              ["nwk", "newick", "tree", "tre"].contains(url.pathExtension.lowercased()),
              let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .ascii)) else { return }
        appState.pendingFinderOpenedFileURL = nil
        newickText = text
        parseCurrentNewick()
    }
    
    // MARK: - 左栏：Newick 与元数据输入 + 节点操作 + Robinson-Foulds 对比
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            newickInputCard
            beautifyAndInspectorCard
            rfComparisonCard
        }
    }
    
    private var newickInputCard: some View {
        StudioCard(
            title: "Newick 序列树与分类着色元数据",
            headerTrailing: {
                StudioSegmentedPillGroup(items: [
                    StudioPillGroupItem(title: "示范树", icon: "sparkles") {
                        newickText = PhylogeneticTreeEngine.defaultExampleNewick
                        metadataCSVText = PhylogeneticTreeEngine.defaultExampleMetadataCSV
                        parseCurrentNewick()
                        appState.showToast("已载入哺乳动物系统发育示范树")
                    },
                    StudioPillGroupItem(title: "导入文件", icon: "folder") {
                        importNewickFile()
                    },
                    StudioPillGroupItem(title: showMetadataEditor ? "收起分组表" : "分组配色 CSV", icon: "paintpalette") {
                        showMetadataEditor.toggle()
                    }
                ])
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SequenceEditorBox(text: $newickText, placeholder: "粘贴 Newick 格式进化树 ((A:0.1,B:0.2)95:0.05,C:0.3);...", minHeight: 82)
                
                if let err = parseError {
                    Text(err)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                if showMetadataEditor {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("物种分组与颜色映射 CSV (leaf,group,color)：")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        SequenceEditorBox(text: $metadataCSVText, placeholder: "leaf,group,color...", minHeight: 74)
                    }
                }
                
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    StudioActionPillButton(title: "解析并渲染进化树", icon: "checkmark.circle.fill", tint: .green, isProminent: true) {
                        parseCurrentNewick()
                    }
                    
                    StudioActionPillButton(title: "字母序排列", icon: "textformat.abc") {
                        rootNode = PhylogeneticTreeEngine.sortAlphabetically(rootNode)
                    }
                    
                    if !collapsedIDs.isEmpty {
                        StudioActionPillButton(title: "展开全部 (\(collapsedIDs.count))", icon: "arrow.up.left.and.arrow.down.right") {
                            collapsedIDs.removeAll()
                        }
                    }
                }
            }
        }
    }
    
    private var beautifyAndInspectorCard: some View {
        let layout = treeLayout
        return StudioCard(title: "画布显示控制与节点拓扑操作") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索物种/叶节点名称并高亮溯源路径...", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                }
                
                StudioFlowLayout(horizontalSpacing: 14, verticalSpacing: 8) {
                    Toggle("显示 Bootstrap 支持率", isOn: $showSupport)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                    
                    Toggle("显示分支长度数值", isOn: $showBranchLengths)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                    
                    Toggle("显示进化距离比例尺", isOn: $showScaleBar)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12.5))
                }
                
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("支持率显示阈值 (\(Int(supportThreshold))%):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize()
                        Slider(value: $supportThreshold, in: 0...100, step: 5)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("支持率显示阈值 (\(Int(supportThreshold))%):")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Slider(value: $supportThreshold, in: 0...100, step: 5)
                    }
                }
                
                if let selID = selectedNodeID, let selNode = layout.byId[selID] {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                            StudioMetricBadge(label: "选中节点", value: selNode.name.isEmpty ? selNode.id : selNode.name, color: .green)
                            StudioMetricBadge(label: "下属物种数", value: "\(selNode.leafCount)", color: .blue)
                            if let len = selNode.length {
                                StudioMetricBadge(label: "枝长", value: String(format: "%.4f", len), color: .teal)
                            }
                            if let sup = selNode.support {
                                StudioMetricBadge(label: "支持率", value: String(format: "%.0f%%", sup), color: .purple)
                            }
                        }
                        
                        if !selNode.isLeaf {
                            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                StudioActionPillButton(title: "旋转子树分支", icon: "arrow.up.and.down.square", tint: .blue) {
                                    rootNode = PhylogeneticTreeEngine.rotateChildren(in: rootNode, nodeID: selID)
                                }
                                StudioActionPillButton(
                                    title: collapsedIDs.contains(selID) ? "展开此演化支" : "折叠此演化支",
                                    icon: collapsedIDs.contains(selID) ? "plus.square.on.square" : "minus.square",
                                    tint: .orange
                                ) {
                                    if collapsedIDs.contains(selID) {
                                        collapsedIDs.remove(selID)
                                    } else {
                                        collapsedIDs.insert(selID)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var rfComparisonCard: some View {
        StudioCard(
            title: "Robinson-Foulds (RF) 双树拓扑距离比对",
            headerTrailing: {
                StudioActionPillButton(title: showComparePanel ? "收起比对" : "展开双树比对", icon: "arrow.left.arrow.right") {
                    showComparePanel.toggle()
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if showComparePanel {
                    Text("输入第二棵 Newick 树以计算共享二分切割 (Bipartition Splits) 与 RF 拓扑距离：")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    SequenceEditorBox(text: $compareNewickText, placeholder: "粘贴对比树 Newick...", minHeight: 68)
                }
                
                if let otherTree = try? PhylogeneticTreeEngine.parseNewick(compareNewickText) {
                    let cmp = PhylogeneticTreeEngine.compareTrees(current: rootNode, other: otherTree)
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        StudioMetricBadge(label: "共享物种", value: "\(cmp.sharedLeaves.count)", color: .blue)
                        StudioMetricBadge(label: "RF 距离", value: "\(cmp.rfDistance) / \(cmp.maxRfDistance)", color: cmp.rfDistance == 0 ? .green : .orange)
                        StudioMetricBadge(label: "归一化 nRF", value: String(format: "%.1f%%", cmp.normalizedRf * 100.0), color: .purple)
                        StudioMetricBadge(label: "共享 Splits", value: "\(cmp.sharedSplits)", color: .teal)
                    }
                } else {
                    Text("对比树 Newick 语法待完善")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - 右栏：系统发育树交互矢量画布
    private var rightColumn: some View {
        let layout = treeLayout
        let meta = resolvedMetadata
        let renderWidth = max(CGFloat(layout.width), canvasAvailableWidth - 16)
        let scaleX = renderWidth / max(1.0, CGFloat(layout.width))
        
        return StudioCard(
            title: "进化树矢量渲染画布 (\(layout.leafCount) 个物种 · \(layout.nodeCount) 个节点)",
            headerTrailing: {
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                    ForEach(meta.groupOrder, id: \.self) { grp in
                        if let hex = meta.groupColors[grp] {
                            StudioMetricBadge(
                                label: grp,
                                value: "\(meta.groupCounts[grp] ?? 0)",
                                color: PlateColorPalette.color(fromHex: hex)
                            )
                        }
                    }
                }
            }
        ) {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    phyloVectorCanvas(layout: layout, horizontalScale: layout.mode == .circular ? 1.0 : scaleX)
                        .frame(
                            width: layout.mode == .circular ? CGFloat(layout.width) : renderWidth,
                            height: CGFloat(layout.height)
                        )
                }
                .padding(8)
            }
            .frame(minHeight: 460, maxHeight: 680)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            if geo.size.width > 160 {
                                canvasAvailableWidth = geo.size.width
                            }
                        }
                        .onChange(of: geo.size.width) { _, newW in
                            if newW > 160 && abs(newW - canvasAvailableWidth) > 2 {
                                canvasAvailableWidth = newW
                            }
                        }
                }
            )
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }
    
    private func phyloVectorCanvas(layout: PhyloTreeLayout, horizontalScale: CGFloat) -> some View {
        let highlighted = highlightedPathIDs
        let sx = Double(max(0.85, min(1.8, horizontalScale)))
        
        return Canvas { context, _ in
            // 1. 绘制分支连线
            for node in layout.nodes where node.parentId != nil {
                let isHighlighted = highlighted.contains(node.id)
                let strokeColor: Color = isHighlighted
                    ? .accentColor
                    : (node.colorHex.map { PlateColorPalette.color(fromHex: $0) } ?? Color.primary.opacity(0.68))
                let lineW: CGFloat = isHighlighted ? 2.6 : 1.6
                
                if layout.mode == .circular, let pid = node.parentId, let pNode = layout.byId[pid] {
                    var arcPath = Path()
                    let clockwise = node.angle < pNode.angle
                    arcPath.addArc(
                        center: CGPoint(x: layout.centerX, y: layout.centerY),
                        radius: CGFloat(node.parentRadius),
                        startAngle: .radians(pNode.angle),
                        endAngle: .radians(node.angle),
                        clockwise: clockwise
                    )
                    context.stroke(arcPath, with: .color(strokeColor), lineWidth: lineW)
                    
                    var radialPath = Path()
                    radialPath.move(to: CGPoint(x: node.parentX, y: node.parentY))
                    radialPath.addLine(to: CGPoint(x: node.x, y: node.y))
                    context.stroke(radialPath, with: .color(strokeColor), lineWidth: lineW)
                } else {
                    var elbow = Path()
                    elbow.move(to: CGPoint(x: node.parentX * sx, y: node.parentY))
                    elbow.addLine(to: CGPoint(x: node.parentX * sx, y: node.y))
                    elbow.addLine(to: CGPoint(x: node.x * sx, y: node.y))
                    context.stroke(elbow, with: .color(strokeColor), style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round))
                }
                
                if showBranchLengths, let len = node.length, layout.mode != .circular {
                    let midX = 0.5 * (node.parentX + node.x) * sx
                    let lenText = Text(String(format: "%.3f", len))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(.secondary)
                    context.draw(lenText, at: CGPoint(x: midX, y: node.y - 8))
                }
            }
            
            // 2. 绘制节点圆点、支持率与末端物种标签
            for node in layout.nodes {
                let nx = layout.mode == .circular ? node.x : (node.x * sx)
                let ny = node.y
                let isSelected = (selectedNodeID == node.id)
                let isHighlighted = highlighted.contains(node.id)
                let dotColor: Color = isSelected
                    ? .pink
                    : (node.colorHex.map { PlateColorPalette.color(fromHex: $0) } ?? (isHighlighted ? .accentColor : .secondary))
                let dotRadius: CGFloat = isSelected ? 5.0 : (node.isLeaf ? 3.5 : 3.0)
                let dotRect = CGRect(
                    x: CGFloat(nx) - dotRadius,
                    y: CGFloat(ny) - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                )
                context.fill(Path(ellipseIn: dotRect), with: .color(dotColor))
                
                if showSupport, !node.isLeaf, let sup = node.support, sup >= supportThreshold {
                    let supText = Text(String(format: "%.0f", sup))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(sup >= 90 ? .green : .orange)
                    context.draw(supText, at: CGPoint(x: nx - 10, y: ny - 9))
                }
                
                if node.terminalIndex != nil {
                    let displayLabel = node.isCollapsed
                        ? "▸ \(node.name.isEmpty ? "Clade" : node.name) (\(node.leafCount) 物种)"
                        : (node.name.isEmpty ? node.id : node.name).replacingOccurrences(of: "_", with: " ")
                    let labelColor: Color = isSelected || isHighlighted
                        ? .accentColor
                        : (node.colorHex.map { PlateColorPalette.color(fromHex: $0) } ?? .primary)
                    let text = Text(displayLabel)
                        .font(.system(size: 12, weight: (isSelected || isHighlighted) ? .bold : .medium))
                        .foregroundColor(labelColor)
                    
                    if layout.mode == .circular {
                        let offsetR = node.radius + 10.0
                        let lx = layout.centerX + offsetR * cos(node.angle)
                        let ly = layout.centerY + offsetR * sin(node.angle)
                        let anchor: UnitPoint = cos(node.angle) >= 0 ? .leading : .trailing
                        context.draw(text, at: CGPoint(x: lx, y: ly), anchor: anchor)
                    } else {
                        context.draw(text, at: CGPoint(x: nx + 8.0, y: ny), anchor: .leading)
                    }
                }
            }
            
            // 3. 绘制底部进化距离比例尺 (Scale Bar)
            if let sb = layout.scaleBar {
                var barPath = Path()
                let x0 = CGFloat(sb.x)
                let x1 = CGFloat(sb.x + sb.lengthPx * (layout.mode == .circular ? 1.0 : sx))
                let y = CGFloat(sb.y)
                barPath.move(to: CGPoint(x: x0, y: y - 4))
                barPath.addLine(to: CGPoint(x: x0, y: y + 4))
                barPath.move(to: CGPoint(x: x0, y: y))
                barPath.addLine(to: CGPoint(x: x1, y: y))
                barPath.move(to: CGPoint(x: x1, y: y - 4))
                barPath.addLine(to: CGPoint(x: x1, y: y + 4))
                context.stroke(barPath, with: .color(.secondary), lineWidth: 1.5)
                
                let unitText = Text(String(format: "%g substitutions/site", sb.unit))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                context.draw(unitText, at: CGPoint(x: 0.5 * (x0 + x1), y: y - 10))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tapLocation in
            var closestID: String? = nil
            var bestDist = 28.0
            for node in layout.nodes {
                let nx = layout.mode == .circular ? node.x : (node.x * sx)
                let dx = Double(tapLocation.x) - nx
                let dy = Double(tapLocation.y) - node.y
                let dist = hypot(dx, dy)
                if dist < bestDist {
                    bestDist = dist
                    closestID = node.id
                }
            }
            selectedNodeID = closestID
        }
    }
    
    // MARK: - 辅助动作
    
    private func parseCurrentNewick() {
        do {
            let parsed = try PhylogeneticTreeEngine.parseNewick(newickText)
            rootNode = parsed
            parseError = nil
            collapsedIDs.removeAll()
            selectedNodeID = parsed.id
        } catch {
            parseError = error.localizedDescription
        }
    }
    
    private func importNewickFile() {
        FinderFileDropHelper.presentOpenPanel { url in
            if let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .ascii)) {
                newickText = text
                parseCurrentNewick()
                appState.showToast("已导入进化树文件：\(url.lastPathComponent)")
            }
        }
    }
    
    private func exportEditedNewick() {
        let serialized = PhylogeneticTreeEngine.toNewick(rootNode, collapsedIDs: collapsedIDs)
        FinderFileDropHelper.saveTextToFile(
            content: serialized,
            defaultFileName: "Edited_Phylogenetic_Tree.nwk",
            contentType: .plainText,
            toastPrefix: "已导出 Newick 进化树"
        )
    }
}
