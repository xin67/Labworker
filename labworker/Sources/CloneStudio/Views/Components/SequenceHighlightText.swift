import CloneStudioCore
import SwiftUI
import AppKit

/// 序列语法高亮组件（放大等宽字体至 13.5pt，精准区分同源臂、酶切位点与基因特异区）
public struct SequenceHighlightText: View {
    public let primer: PrimerItem
    
    public init(primer: PrimerItem) {
        self.primer = primer
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("5'-")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                formattedSequence
                    .textSelection(.enabled)
                
                Text("-3'")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                StudioActionPillButton(
                    title: "复制序列",
                    icon: "doc.on.doc",
                    action: copySequence
                )
            }
            .padding(10)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            
            HStack(spacing: 14) {
                if !primer.homologyArm.isEmpty {
                    HStack(spacing: 5) {
                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                        Text("同源臂 (\(primer.homologyArm.count) bp)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                if let e = primer.enzymeName, let site = primer.enzymeSite, !site.isEmpty {
                    HStack(spacing: 5) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text("\(e) (\(site))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(Color.primary).frame(width: 8, height: 8)
                    Text("特异结合区")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
    }
    
    @ViewBuilder
    private var formattedSequence: some View {
        let arm = primer.homologyArm.lowercased()
        let site = primer.enzymeSite?.lowercased() ?? ""
        let full = primer.fullSequence
        
        Text(buildAttributedString(arm: arm, site: site, full: full))
            .font(.system(size: 13.5, weight: .medium, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
    }
    
    private func buildAttributedString(arm: String, site: String, full: String) -> AttributedString {
        var str = AttributedString()
        let fullLower = full.lowercased()
        
        var currentIndex = fullLower.startIndex
        
        if !arm.isEmpty && fullLower.hasPrefix(arm) {
            var armAttr = AttributedString(arm)
            armAttr.foregroundColor = .blue
            str.append(armAttr)
            currentIndex = fullLower.index(currentIndex, offsetBy: arm.count)
        }
        
        if !site.isEmpty && fullLower[currentIndex...].hasPrefix(site) {
            var siteAttr = AttributedString(site)
            siteAttr.foregroundColor = .red
            str.append(siteAttr)
            currentIndex = fullLower.index(currentIndex, offsetBy: site.count)
        }
        
        let remaining = String(full[currentIndex...]).uppercased()
        var remainAttr = AttributedString(remaining)
        remainAttr.foregroundColor = .primary
        str.append(remainAttr)
        
        return str
    }
    
    private func copySequence() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(primer.formattedSequence, forType: .string)
        AppState.shared.showToast("已复制「\(primer.name)」引物序列")
    }
}

/// 成对引物快捷重命名工具条（放大字号与图2胶囊按钮层次）
public struct PrimerPairQuickRenameBar: View {
    public let pairTitle: String
    public let currentForwardName: String
    public let currentReverseName: String
    public let suggestedPrefix: String
    public let onApplyPrefix: (String) -> Void
    
    @State private var prefixText: String = ""
    
    public init(
        pairTitle: String = "成对引物改名",
        currentForwardName: String,
        currentReverseName: String,
        suggestedPrefix: String = "",
        onApplyPrefix: @escaping (String) -> Void
    ) {
        self.pairTitle = pairTitle
        self.currentForwardName = currentForwardName
        self.currentReverseName = currentReverseName
        self.suggestedPrefix = suggestedPrefix
        self.onApplyPrefix = onApplyPrefix
    }
    
    public init(
        pairLabel: String,
        currentPrefix: String,
        suggestedPrefix: String = "",
        onApplyPrefix: @escaping (String) -> Void
    ) {
        let cleanPrefix = PrimerItem.extractPairPrefix(from: currentPrefix)
        self.pairTitle = pairLabel
        self.currentForwardName = "\(cleanPrefix)-F"
        self.currentReverseName = "\(cleanPrefix)-R"
        self.suggestedPrefix = suggestedPrefix
        self.onApplyPrefix = onApplyPrefix
    }
    
    public var body: some View {
        HStack(spacing: 10) {
            Text("\(pairTitle):")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .fixedSize()
            
            TextField("引物前缀 (自动生成 -F / -R)", text: $prefixText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minWidth: 140, maxWidth: 220)
                .onSubmit {
                    applyRename()
                }
            
            StudioSegmentedPillGroup(items: {
                var arr: [StudioPillGroupItem] = [
                    StudioPillGroupItem(
                        title: "成对改名",
                        icon: "pencil",
                        tint: .accentColor,
                        isDisabled: prefixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        action: applyRename
                    )
                ]
                if !suggestedPrefix.isEmpty && PrimerItem.extractPairPrefix(from: currentForwardName) != suggestedPrefix {
                    arr.append(
                        StudioPillGroupItem(
                            title: "设为 \(suggestedPrefix)"
                        ) {
                            prefixText = suggestedPrefix
                            onApplyPrefix(suggestedPrefix)
                        }
                    )
                }
                return arr
            }())
            
            Spacer(minLength: 4)
            
            Text("\(currentForwardName) / \(currentReverseName)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 0.8)
                )
        )
        .onAppear {
            if prefixText.isEmpty {
                prefixText = PrimerItem.extractPairPrefix(from: currentForwardName)
            }
        }
        .onChange(of: currentForwardName) { _, newVal in
            prefixText = PrimerItem.extractPairPrefix(from: newVal)
        }
    }
    
    private func applyRename() {
        let clean = PrimerItem.extractPairPrefix(from: prefixText)
        guard !clean.isEmpty else { return }
        prefixText = clean
        onApplyPrefix(clean)
    }
}

/// 引物展示卡片（放大字号 + 图2风格胶囊操作栏 + primer3 二级结构风险徽章与可展开碱基配对示意图）
public struct PrimerCardView: View {
    public let primer: PrimerItem
    public var partnerPrimer: PrimerItem? = nil
    public var onPairedRename: ((String) -> Void)? = nil
    public var onSingleRename: ((String) -> Void)? = nil
    
    @ObservedObject private var appState = AppState.shared
    @State private var isAdded: Bool = false
    @State private var isEditingName: Bool = false
    @State private var draftNameText: String = ""
    @State private var isShowingStructureDiagram: Bool = false
    
    public init(
        primer: PrimerItem,
        partnerPrimer: PrimerItem? = nil,
        onPairedRename: ((String) -> Void)? = nil,
        onSingleRename: ((String) -> Void)? = nil
    ) {
        self.primer = primer
        self.partnerPrimer = partnerPrimer
        self.onPairedRename = onPairedRename
        self.onSingleRename = onSingleRename
    }
    
    private var fullLengthTm: Double? {
        guard !primer.homologyArm.isEmpty, primer.fullSequence.count > primer.homologyArm.count else {
            return nil
        }
        return TmCalculator.calculate(sequence: primer.fullSequence).tm
    }
    
    private var qualityReport: PrimerQualityEngine.SinglePrimerReport {
        appState.evaluatePrimerQuality(primer.fullSequence)
    }
    
    private var heterodimerResult: PrimerQualityEngine.StructureResult? {
        guard let partner = partnerPrimer else { return nil }
        return PrimerQualityEngine.calcDimer(
            primer.fullSequence,
            partner.fullSequence,
            conditions: appState.primerThermoConditions,
            dgAlertThreshold: appState.primerDimerAlertDg
        )
    }
    
    private var combinedRisk: PrimerQualityEngine.RiskLevel {
        if let het = heterodimerResult {
            return max(qualityReport.overallRisk, het.riskLevel)
        }
        return qualityReport.overallRisk
    }
    
    private func riskTint(_ risk: PrimerQualityEngine.RiskLevel) -> Color {
        switch risk {
        case .safe: return .green
        case .moderate: return .orange
        case .high: return .red
        }
    }
    
    public var body: some View {
        let qc = qualityReport
        let het = heterodimerResult
        let risk = combinedRisk
        return VStack(alignment: .leading, spacing: 10) {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                Text(primer.name)
                    .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                
                if onPairedRename != nil || onSingleRename != nil {
                    Button(action: {
                        draftNameText = onPairedRename != nil
                            ? PrimerItem.extractPairPrefix(from: primer.name)
                            : primer.name
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isEditingName.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                            Text("改名")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
                
                StudioMetricBadge(label: "", value: "\(primer.length) bp", color: .secondary)
                
                if let tm = primer.tm {
                    let labelPrefix = primer.homologyArm.isEmpty ? "Tm" : "退火"
                    StudioMetricBadge(label: labelPrefix, value: "\(String(format: "%.1f", tm))℃", color: .orange)
                }
                
                if let fullTm = fullLengthTm {
                    StudioMetricBadge(label: "全长", value: "\(String(format: "%.0f", fullTm.rounded()))℃", color: .blue)
                }
                
                if let gc = primer.gcPercent {
                    StudioMetricBadge(label: "GC", value: "\(String(format: "%.0f", gc))%", color: .purple)
                }
                
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isShowingStructureDiagram.toggle()
                    }
                } label: {
                    StudioMetricBadge(
                        label: "二级结构",
                        value: "\(risk.rawValue) (发夹 \(String(format: "%.1f", qc.hairpin.dg)) / 二聚 \(String(format: "%.1f", qc.homodimer.dg)))",
                        color: riskTint(risk)
                    )
                }
                .buttonStyle(.plain)
                .help("点击展开/收起 primer3 发夹与二聚体 ΔG、Tm 及碱基配对示意图")
            }
            
            if isEditingName {
                HStack(spacing: 8) {
                    TextField(onPairedRename != nil ? "输入成对前缀" : "输入新名称", text: $draftNameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(maxWidth: 220)
                        .onSubmit {
                            commitPairedOrSingleRename()
                        }
                    
                    StudioSegmentedPillGroup(items: {
                        var items: [StudioPillGroupItem] = []
                        if let pairedAction = onPairedRename {
                            items.append(
                                StudioPillGroupItem(title: "成对应用 (-F/-R)", tint: .accentColor) {
                                    let prefix = PrimerItem.extractPairPrefix(from: draftNameText)
                                    if !prefix.isEmpty {
                                        pairedAction(prefix)
                                        isEditingName = false
                                    }
                                }
                            )
                        }
                        if let singleAction = onSingleRename {
                            items.append(
                                StudioPillGroupItem(title: "仅改此条") {
                                    let clean = draftNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !clean.isEmpty {
                                        singleAction(clean)
                                        isEditingName = false
                                    }
                                }
                            )
                        }
                        items.append(
                            StudioPillGroupItem(title: "取消", tint: .secondary) {
                                isEditingName = false
                            }
                        )
                        return items
                    }())
                    
                    Spacer()
                }
            }
            
            SequenceHighlightText(primer: primer)
            
            if isShowingStructureDiagram {
                secondaryStructureDrawerView(qc: qc, het: het)
            }
            
            HStack(spacing: 8) {
                if !primer.targetPurpose.isEmpty {
                    Text(primer.targetPurpose)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                StudioActionPillButton(
                    title: isShowingStructureDiagram ? "收起配对图" : "配对示意图",
                    icon: isShowingStructureDiagram ? "chevron.up.circle" : "waveform.path.ecg",
                    tint: riskTint(risk),
                    isProminent: false
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isShowingStructureDiagram.toggle()
                    }
                }
                StudioActionPillButton(
                    title: isAdded ? "已加入引物池" : "加入引物池",
                    icon: isAdded ? "checkmark.circle.fill" : "cart.badge.plus",
                    tint: isAdded ? .green : .accentColor,
                    isProminent: true
                ) {
                    AppState.shared.addPrimerToCart(primer)
                    isAdded = true
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private func secondaryStructureDrawerView(
        qc: PrimerQualityEngine.SinglePrimerReport,
        het: PrimerQualityEngine.StructureResult?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 6) {
                Text("缓冲液离子条件:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 4) {
                    Text("Mg²⁺")
                        .font(.system(size: 11, weight: .medium))
                    Slider(value: $appState.primerMgConc, in: 0.0...6.0, step: 0.1)
                        .frame(width: 75)
                    Text(String(format: "%.1f mM", appState.primerMgConc))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                
                HStack(spacing: 4) {
                    Text("dNTP")
                        .font(.system(size: 11, weight: .medium))
                    Slider(value: $appState.primerDntpConc, in: 0.0...4.0, step: 0.1)
                        .frame(width: 75)
                    Text(String(format: "%.1f mM", appState.primerDntpConc))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                
                let eqMm = appState.primerThermoConditions.equivalentMonovalentMolar * 1000.0
                StudioMetricBadge(
                    label: "等效 [Na+]",
                    value: String(format: "%.0f mM", eqMm),
                    color: .teal
                )
            }
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 540), spacing: 8)], spacing: 8) {
                structureDetailCard(
                    title: "发夹结构 (calc_hairpin)",
                    result: qc.hairpin
                )
                structureDetailCard(
                    title: "自二聚体 (calc_homodimer)",
                    result: qc.homodimer
                )
                if let het = het, let partner = partnerPrimer {
                    structureDetailCard(
                        title: "异二聚体 (vs \(partner.name))",
                        result: het
                    )
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.8)
                )
        )
    }
    
    @ViewBuilder
    private func structureDetailCard(
        title: String,
        result: PrimerQualityEngine.StructureResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                Text(title)
                    .font(.system(size: 11.5, weight: .bold))
                StudioMetricBadge(
                    label: "",
                    value: result.riskLevel.rawValue,
                    color: riskTint(result.riskLevel)
                )
                if result.structureFound {
                    StudioMetricBadge(
                        label: "ΔG",
                        value: String(format: "%.2f kcal/mol", result.dg),
                        color: riskTint(result.riskLevel)
                    )
                    StudioMetricBadge(
                        label: "Tm",
                        value: String(format: "%.1f℃", result.tm),
                        color: .blue
                    )
                    if result.threePrimeAnchored {
                        StudioMetricBadge(
                            label: "告警",
                            value: "3'端参与配对",
                            color: .red
                        )
                    }
                }
            }
            
            if result.structureFound && !result.asciiStructure.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(result.asciiStructure)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.92))
                        .textSelection(.enabled)
                        .padding(7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(NSColor.textBackgroundColor))
                )
            } else {
                Text("未检出显著二级结构 (ΔG ≈ 0.0 kcal/mol)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
    
    private func commitPairedOrSingleRename() {
        let trimmed = draftNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let pairedAction = onPairedRename {
            pairedAction(PrimerItem.extractPairPrefix(from: trimmed))
        } else if let singleAction = onSingleRename {
            singleAction(trimmed)
        }
        isEditingName = false
    }
}

/// 成对引物 (Forward × Reverse) 异二聚体与配对质量摘要条（默认收起配对图）
public struct PrimerPairDimerSummaryBar: View {
    public let forwardPrimer: PrimerItem
    public let reversePrimer: PrimerItem
    
    @ObservedObject private var appState = AppState.shared
    @State private var isExpanded: Bool = false
    
    public init(forwardPrimer: PrimerItem, reversePrimer: PrimerItem) {
        self.forwardPrimer = forwardPrimer
        self.reversePrimer = reversePrimer
    }
    
    private var pairReport: PrimerQualityEngine.PrimerPairReport {
        appState.evaluatePrimerPairQuality(
            forward: forwardPrimer.fullSequence,
            reverse: reversePrimer.fullSequence
        )
    }
    
    private func riskTint(_ risk: PrimerQualityEngine.RiskLevel) -> Color {
        switch risk {
        case .safe: return .green
        case .moderate: return .orange
        case .high: return .red
        }
    }
    
    public var body: some View {
        let rep = pairReport
        let het = rep.heterodimer
        return VStack(alignment: .leading, spacing: 6) {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(riskTint(rep.overallRisk))
                    Text("F/R 对间异二聚体 (calc_dimer):")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                
                StudioMetricBadge(
                    label: "对间风险",
                    value: het.riskLevel.rawValue,
                    color: riskTint(het.riskLevel)
                )
                
                if het.structureFound {
                    StudioMetricBadge(
                        label: "ΔG",
                        value: String(format: "%.2f kcal/mol", het.dg),
                        color: riskTint(het.riskLevel)
                    )
                    StudioMetricBadge(
                        label: "二聚体 Tm",
                        value: String(format: "%.1f℃", het.tm),
                        color: .blue
                    )
                    if het.threePrimeAnchored {
                        StudioMetricBadge(
                            label: "注意",
                            value: "3'端交叉互补",
                            color: .red
                        )
                    }
                } else {
                    Text("无显著交叉二聚体")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
                
                if het.structureFound {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Text(isExpanded ? "收起 F×R 配对图" : "查看 F×R 配对图")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            if isExpanded && het.structureFound {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(het.asciiStructure)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.92))
                        .textSelection(.enabled)
                        .padding(7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(NSColor.textBackgroundColor))
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(riskTint(rep.overallRisk).opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(riskTint(rep.overallRisk).opacity(0.22), lineWidth: 0.8)
                )
        )
    }
}
