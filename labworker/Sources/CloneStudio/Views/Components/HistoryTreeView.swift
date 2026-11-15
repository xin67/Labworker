import SwiftUI
import CloneStudioCore

// MARK: - 质粒构建谱系树与多步连续改造对比视图 (借鉴 CloneCanvas HistoryTree.svelte)
public struct HistoryTreeView: View {
    @ObservedObject private var historyManager = ConstructHistoryManager.shared
    @State private var expandedShiftNodeIDs: Set<UUID> = []
    @State private var expandedOverhangNodeIDs: Set<UUID> = []

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topToolbar

            if historyManager.nodes.isEmpty {
                emptyStateView
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(historyManager.nodes.enumerated()), id: \.element.id) { idx, node in
                            let isSelected = (historyManager.activeNodeID == node.id)
                            let isShiftExpanded = expandedShiftNodeIDs.contains(node.id)
                            let isOverhangExpanded = expandedOverhangNodeIDs.contains(node.id)
                            let parentNode = historyManager.nodes.first(where: { $0.id == node.parentNodeID })

                            HistoryNodeCard(
                                stepNumber: idx + 1,
                                node: node,
                                parentNode: parentNode,
                                isSelected: isSelected,
                                isShiftExpanded: isShiftExpanded,
                                isOverhangExpanded: isOverhangExpanded,
                                onSelect: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        historyManager.activeNodeID = node.id
                                    }
                                },
                                onToggleShifts: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if isShiftExpanded {
                                            expandedShiftNodeIDs.remove(node.id)
                                        } else {
                                            expandedShiftNodeIDs.insert(node.id)
                                        }
                                    }
                                },
                                onToggleOverhangs: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if isOverhangExpanded {
                                            expandedOverhangNodeIDs.remove(node.id)
                                        } else {
                                            expandedOverhangNodeIDs.insert(node.id)
                                        }
                                    }
                                },
                                onChainToItem: { targetNav in
                                    AppState.shared.chainProductConstruct(node, to: targetNav)
                                }
                            )

                            if idx < historyManager.nodes.count - 1 {
                                HStack(spacing: 6) {
                                    Spacer().frame(width: 24)
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.teal)
                                    Text("连续改造链路 (Step \(idx + 1) → Step \(idx + 2))")
                                        .font(.system(size: 9, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var topToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Label("质粒构建谱系树 (Construct Lineage)", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)

                Spacer()

                Text("共 \(historyManager.nodes.count) 步改造记录")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if !historyManager.nodes.isEmpty {
                    clearHistoryButton
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("质粒构建谱系树", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption.bold())
                        .foregroundStyle(.primary)
                    Spacer()
                    if !historyManager.nodes.isEmpty {
                        clearHistoryButton
                    }
                }
                Text("共 \(historyManager.nodes.count) 步改造记录")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var clearHistoryButton: some View {
        StudioCompactPillButton(title: "清空谱系", icon: "trash", tint: .red) {
            withAnimation {
                historyManager.clearHistory()
                expandedShiftNodeIDs.removeAll()
                expandedOverhangNodeIDs.removeAll()
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("当前尚无质粒改造谱系记录")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("当您在克隆、定点突变或片段删除模块点击「生成方案」后，系统将自动在此记录多步改造链路与特征元件坐标位移对比。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .studioInnerBox(paddingH: 12, paddingV: 12)
    }
}

// MARK: - 单个构建步骤谱系卡片
private struct HistoryNodeCard: View {
    let stepNumber: Int
    let node: ConstructHistoryNode
    let parentNode: ConstructHistoryNode?
    let isSelected: Bool
    let isShiftExpanded: Bool
    let isOverhangExpanded: Bool
    let onSelect: () -> Void
    let onToggleShifts: () -> Void
    let onToggleOverhangs: () -> Void
    let onChainToItem: (NavItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerBar
            genealogyFlowRow
            Text(node.insertOrActionSummary)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            expandToggleButtons
            if isOverhangExpanded {
                overhangSection
            }
            if isShiftExpanded {
                featureShiftSection
            }
        }
        .studioInnerBox(
            tint: isSelected ? .teal : nil,
            isHighlighted: isSelected,
            paddingH: 10,
            paddingV: 10
        )
        .contentShape(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous))
        .onTapGesture {
            onSelect()
        }
    }

    private func operationIcon(_ op: ConstructOperationType) -> String {
        switch op {
        case .entryClone: return "arrow.triangle.merge"
        case .singleFragment: return "scissors"
        case .multiFragment: return "square.stack.3d.forward.dottedline"
        case .mutagenesis: return "wand.and.stars"
        case .fragmentDeletion: return "scissors.badge.ellipsis"
        case .crisprSgRNA: return "scope"
        case .shRNA: return "waveform.path.badge.plus"
        }
    }

    private var headerBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("STEP \(stepNumber)")
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.teal.opacity(0.18), in: Capsule())
                    .foregroundStyle(.teal)

                Label(node.operationType.rawValue, systemImage: operationIcon(node.operationType))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)

                if let parent = parentNode {
                    Text("继承自: \(parent.constructName)")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.purple.opacity(0.14), in: Capsule())
                        .foregroundStyle(.purple)
                }

                Spacer()

                chainMenu
            }
            
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("STEP \(stepNumber)")
                        .font(.system(size: 9, weight: .bold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.teal.opacity(0.18), in: Capsule())
                        .foregroundStyle(.teal)

                    Label(node.operationType.rawValue, systemImage: operationIcon(node.operationType))
                        .font(.system(size: 10.5, weight: .bold))

                    Spacer()

                    chainMenu
                }
                if let parent = parentNode {
                    Text("继承自: \(parent.constructName)")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.purple.opacity(0.14), in: Capsule())
                        .foregroundStyle(.purple)
                }
            }
        }
    }
    
    private var chainMenu: some View {
        StudioMenuPillButton(
            title: "继续改造",
            icon: "arrow.triangle.branch",
            tint: .teal,
            compact: true,
            help: "以此产物继续下游改造"
        ) {
            Button {
                onChainToItem(.mutagenesis)
            } label: {
                Label("送入「定点突变设计」继续改造", systemImage: "wand.and.stars")
            }
            Button {
                onChainToItem(.fragmentDeletion)
            } label: {
                Label("送入「质粒片段删除」继续敲除", systemImage: "scissors.badge.ellipsis")
            }
            Button {
                onChainToItem(.singleFragment)
            } label: {
                Label("作为载体送入「单片段克隆」", systemImage: "scissors")
            }
        }
    }

    private var genealogyFlowRow: some View {
        let deltaBp = node.deltaBp
        let deltaStr = deltaBp >= 0 ? "+\(deltaBp) bp" : "\(deltaBp) bp"
        let deltaColor: Color = deltaBp >= 0 ? .green : .orange

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("父本载体")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text("\(node.parentVectorName) (\(node.parentLengthBp) bp)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                }
                .studioInnerBox(tint: .blue, paddingH: 8, paddingV: 5)

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("改造输入/靶点")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text(node.insertOrActionSummary)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .studioInnerBox(tint: .orange, paddingH: 8, paddingV: 5)

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.teal)

                VStack(alignment: .leading, spacing: 1) {
                    Text("重组产物")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("\(node.constructName) (\(node.productLengthBp) bp)")
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.teal)
                        Text("(\(deltaStr))")
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(deltaColor)
                    }
                }
                .studioInnerBox(tint: .teal, paddingH: 8, paddingV: 5)
            }
        }
    }

    private var expandToggleButtons: some View {
        HStack(spacing: 10) {
            if !node.junctionOverhangs.isEmpty {
                Button(action: onToggleOverhangs) {
                    HStack(spacing: 4) {
                        Image(systemName: isOverhangExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("粘性末端 / 同源臂配对 (\(node.junctionOverhangs.count))")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.teal)
            }

            if !node.featureShifts.isEmpty {
                Button(action: onToggleShifts) {
                    HStack(spacing: 4) {
                        Image(systemName: isShiftExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("改造前后 Feature 坐标位移对比 (\(node.featureShifts.count))")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }

            Spacer()
        }
    }

    private var overhangSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(node.junctionOverhangs) { item in
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 9.5, weight: .bold))
                            .frame(width: 110, alignment: .leading)
                        Text("5'-\(item.topStrandSnippet)-3'")
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .foregroundStyle(.green)
                        Image(systemName: "link")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text("3'-\(item.bottomStrandSnippet)-5'")
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .foregroundStyle(.cyan)
                        Spacer()
                        Text("\(item.homologyLength) bp (\(item.enzymeOrArmName))")
                            .font(.system(size: 9, weight: .bold))
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.teal.opacity(0.15), in: Capsule())
                    }
                    .studioInnerBox(paddingH: 8, paddingV: 4)
                }
            }
        }
    }

    private var featureShiftSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("元件名称")
                        .frame(width: 110, alignment: .leading)
                    Text("改造前区间 (Parent)")
                        .frame(width: 115, alignment: .leading)
                    Text("改造后区间 (Product)")
                        .frame(width: 115, alignment: .leading)
                    Text("位移量 (Δbp)")
                        .frame(width: 80, alignment: .trailing)
                    Spacer()
                    Text("状态")
                        .frame(width: 72, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)

                Divider()

                ForEach(node.featureShifts) { shift in
                    FeatureShiftRowView(shift: shift)
                }
            }
            .frame(minWidth: 500)
        }
        .studioInnerBox(paddingH: 6, paddingV: 6)
    }
}

private struct FeatureShiftRowView: View {
    let shift: FeatureShiftItem

    var body: some View {
        let deltaStr: String = {
            if shift.status == .deleted { return "DEL" }
            if shift.status == .inserted { return "NEW" }
            if shift.deltaBp == 0 { return "0 bp" }
            return shift.deltaBp > 0 ? "+\(shift.deltaBp) bp" : "\(shift.deltaBp) bp"
        }()

        HStack {
            Text(shift.featureName)
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            Text(shift.oldRangeText)
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 115, alignment: .leading)

            Text(shift.newRangeText)
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(shift.status == .deleted ? .red : .primary)
                .frame(width: 115, alignment: .leading)

            Text(deltaStr)
                .font(.system(size: 9.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(statusColor(shift.status))
                .frame(width: 80, alignment: .trailing)

            Spacer()

            Text(shift.status.rawValue)
                .font(.system(size: 8.5, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(statusColor(shift.status).opacity(0.16), in: Capsule())
                .foregroundStyle(statusColor(shift.status))
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private func statusColor(_ status: FeatureShiftStatus) -> Color {
        switch status {
        case .unchanged: return .secondary
        case .shifted: return .orange
        case .inserted: return .green
        case .deleted: return .red
        case .mutated: return .purple
        }
    }
}
