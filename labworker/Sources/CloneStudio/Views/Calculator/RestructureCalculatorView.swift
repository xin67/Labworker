import AppKit
import CloneStudioCore
import SwiftUI

/// 生物计算与反应体系工作台（整合克隆/连接摩尔比配液、DNA 换算、蛋白质换算与生理生化公式）
public struct RestructureCalculatorView: View {
    @ObservedObject private var vm = WorkspaceSessionManager.shared.calculatorVM
    @ObservedObject private var bioVM = WorkspaceSessionManager.shared.bioCalculatorVM
    
    public init() {}
    
    public var body: some View {
        StudioPageLayout(
            title: "生物计算器",
            toolbar: activeToolbarItems
        ) {
            VStack(alignment: .leading, spacing: 14) {
                StudioSegmentedPicker(
                    selection: $bioVM.selectedCategory,
                    options: BioCalculatorCategory.allCases.map { cat in
                        StudioSegmentedOption(value: cat, title: cat.title, tint: tint(for: cat))
                    }
                )

                switch bioVM.selectedCategory {
                case .cloningAndLigation:
                    cloningAndLigationBody
                case .dnaConversion:
                    DNAConversionsWorkspaceView(bioVM: bioVM)
                case .proteinConversion:
                    ProteinConversionsWorkspaceView(bioVM: bioVM)
                case .biochemFormula:
                    BiochemFormulasWorkspaceView(bioVM: bioVM)
                }
            }
        }
    }

    private var activeToolbarItems: [StudioToolbarItem] {
        var items: [StudioToolbarItem] = []
        if bioVM.selectedCategory == .cloningAndLigation {
            items.append(
                .action(
                    title: "从单片段同步",
                    icon: "arrow.down.doc",
                    tint: .teal,
                    help: "从单片段无缝克隆模块同步载体与插入长度"
                ) {
                    WorkspaceSessionManager.shared.singleFragmentVM.sendLengthsToCalculator(navigate: false)
                }
            )
            items.append(
                .action(
                    title: "从多片段同步",
                    icon: "square.stack.3d.up",
                    tint: .indigo,
                    help: "从多片段无缝克隆模块同步载体与插入长度"
                ) {
                    WorkspaceSessionManager.shared.multiFragmentVM.sendLengthsToCalculator(navigate: false)
                }
            )
        }
        items.append(
            .action(
                title: "示例",
                icon: "wand.and.stars",
                tint: tint(for: bioVM.selectedCategory),
                help: "为当前计算面板填入常用科研示例参数"
            ) {
                bioVM.loadExampleForCurrentSubtool()
            }
        )
        items.append(
            .action(
                id: "clear_bio_calc",
                groupKey: nil,
                title: "",
                icon: "trash",
                tint: .red,
                help: "清空当前计算面板输入参数"
            ) {
                bioVM.clearCurrentSubtool()
            }
        )
        return items
    }

    private func tint(for category: BioCalculatorCategory) -> Color {
        switch category {
        case .cloningAndLigation: return .purple
        case .dnaConversion:      return .blue
        case .proteinConversion:  return .orange
        case .biochemFormula:     return .green
        }
    }

    private var cloningAndLigationBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            StudioSegmentedPicker(
                selection: $vm.cloneType,
                options: DNAMolarCalculator.CloneType.allCases.map { t in
                    StudioSegmentedOption(value: t, title: t.title, tint: .purple)
                }
            )

            if vm.cloneType == .ligationRatio {
                ligationMolarRatioWorkspace
            } else {
                AdaptiveTwoColumnWorkspace(breakpoint: 820) {
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. 载体参数（支持自定义 ng 投入量与快捷档位）
                        if vm.cloneType != .simple {
                            vectorCard
                        }
                        
                        // 2. 插入片段参数（支持自定义 ng 投入量与多片段扩展）
                        insertFragmentsCard
                    }
                } right: {
                    reactionSystemCard
                }
            }
        }
    }

    // MARK: - 0. 经典摩尔比模式 (载体 0.03 pmol + 载体:片段 1:1~1:5)
    private var ligationMolarRatioWorkspace: some View {
        let ligRes = vm.ligationRatioResult
        let vecBp = vm.parsedVectorLengthBp
        let insBp = vm.parsedInsertLengthBp(at: 0)
        return AdaptiveTwoColumnWorkspace(breakpoint: 800) {
            VStack(alignment: .leading, spacing: 14) {
                StudioCard(title: "经典连接 / 摩尔比投入量参数") {
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        StudioMetricBadge(label: "载体", value: "\(vecBp) bp", color: .blue)
                        StudioMetricBadge(label: "片段", value: "\(insBp) bp", color: .purple)
                        StudioMetricBadge(label: "比例", value: vm.ligationMolarRatio.title, color: .teal)
                    }
                } content: {
                    VStack(alignment: .leading, spacing: 12) {
                        StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                            labeledInputField(
                                label: "载体长度",
                                placeholder: "5000 (或 kb)",
                                text: $vm.vectorLengthKb,
                                unit: "kb (≥40按bp)",
                                width: 82
                            )
                            labeledInputField(
                                label: "载体浓度",
                                placeholder: "50",
                                text: $vm.vectorConcentration,
                                unit: "ng/μL",
                                width: 70
                            )
                            labeledInputField(
                                label: "载体摩尔量",
                                placeholder: "0.03",
                                text: $vm.ligationVectorPmol,
                                unit: "pmol",
                                width: 70,
                                highlightColor: .blue
                            )
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundColor(.teal)
                            Text("同源重组/连接推荐载体最适使用量为 0.03 pmol（约合 19.5 ng/kb）。")
                                .font(.system(size: 11.5))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }

                        Divider().opacity(0.4)

                        StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                            labeledInputField(
                                label: "片段长度",
                                placeholder: "1000 (或 kb)",
                                text: bindingForLength(at: 0),
                                unit: "kb (≥40按bp)",
                                width: 82
                            )
                            labeledInputField(
                                label: "片段浓度",
                                placeholder: "25",
                                text: bindingForConc(at: 0),
                                unit: "ng/μL",
                                width: 70
                            )
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("载体 : 插入片段 摩尔比")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.primary)
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                ForEach(DNAMolarCalculator.LigationMolarRatio.allCases) { r in
                                    StudioCompactPillButton(
                                        title: r.title,
                                        tint: .purple,
                                        isProminent: vm.ligationMolarRatio == r
                                    ) {
                                        vm.ligationMolarRatio = r
                                    }
                                }
                            }
                        }

                        if let lig = ligRes, lig.lowInsertSingleWarning {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 12.5))
                                    .padding(.top, 1)
                                Text(
                                    lig.lowInsertMultiWarning
                                        ? "当前插入片段计算投入量仅 \(BioMathFormatter.format(lig.insertNg)) ng：单片段插入推荐 > 20 ng，多片段组装推荐单个 > 10 ng，建议提高片段比例或载体用量。"
                                        : "当前插入片段计算投入量为 \(BioMathFormatter.format(lig.insertNg)) ng（< 20 ng）：若为单片段克隆/连接，推荐插入片段使用量 > 20 ng（多片段推荐 > 10 ng）。"
                                )
                                .font(.system(size: 11.5))
                                .monospacedDigit()
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .studioInnerBox(tint: .orange, paddingH: 10, paddingV: 8)
                        }
                    }
                }
            }
        } right: {
            VStack(alignment: .leading, spacing: 14) {
                StudioCard(title: "最适用量与体积测算表") {
                    StudioMetricBadge(label: "比例", value: vm.ligationMolarRatio.title, color: .purple)
                } content: {
                    if let lig = ligRes {
                        let vVolStr = lig.vectorVolUl.map { String(format: "%.2f μL", $0) } ?? "-- μL"
                        let iVolStr = lig.insertVolUl.map { String(format: "%.2f μL", $0) } ?? "-- μL"
                        let vNgStr = String(format: "%.2f ng", lig.vectorNg)
                        let iNgStr = String(format: "%.2f ng", lig.insertNg)
                        VStack(alignment: .leading, spacing: 8) {
                            pipetteRow(
                                name: "2× 重组预混液 (或连接酶+Buffer)",
                                detail: "按 20 μL 标准反应体系参考",
                                vol: "10.00 μL",
                                tint: .blue
                            )
                            pipetteRow(
                                name: vm.vectorName.isEmpty ? "线性化载体 (\(lig.vectorLengthBp) bp)" : "\(vm.vectorName) (\(lig.vectorLengthBp) bp)",
                                detail: "最适投入 \(vNgStr) (\(BioMathFormatter.format(lig.vectorPmol)) pmol)",
                                vol: vVolStr,
                                tint: .teal
                            )
                            pipetteRow(
                                name: "插入片段 (\(lig.insertLengthBp) bp)",
                                detail: "最适投入 \(iNgStr) (摩尔比 \(lig.molarRatio.title))",
                                vol: iVolStr,
                                tint: .purple
                            )
                            pipetteRow(
                                name: "ddH₂O",
                                detail: "无菌超纯水",
                                vol: vm.remainingWaterFormatted,
                                tint: .secondary
                            )
                            HStack {
                                Spacer()
                                StudioCompactPillButton(title: "复制加样表", icon: "doc.on.doc", tint: .purple) {
                                    let summary = "线性化载体(\(lig.vectorLengthBp)bp): \(vNgStr) / \(vVolStr); 插入片段(\(lig.insertLengthBp)bp, \(lig.molarRatio.title)): \(iNgStr) / \(iVolStr); ddH2O: \(vm.remainingWaterFormatted)"
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(summary, forType: .string)
                                    AppState.shared.showToast("已复制摩尔比配液表到剪贴板")
                                }
                            }
                        }
                    } else {
                        Text("请输入大于 0 的载体长度、载体摩尔量与插入片段长度。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                StudioCard(title: "经典摩尔比计算公式") {
                    EmptyView()
                } content: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("载体最适用量 (ng) = pmol载体 × 载体长度 (bp) × 0.65\n片段最适用量 (ng) = pmol载体 × 摩尔比 × 片段长度 (bp) × 0.65\n移液体积 (μL) = 最适使用量 (ng) ÷ 实测浓度 (ng/μL)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioInnerBox(tint: .purple, paddingH: 10, paddingV: 9)
                }
            }
        }
    }
    
    // MARK: - 1. 载体参数卡片
    private var vectorCard: some View {
        let res = vm.vectorResult
        return StudioCard(title: vm.vectorName.isEmpty ? "载体参数" : "载体参数 · \(vm.vectorName)") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                StudioMetricBadge(
                    label: "长度",
                    value: "\(vm.parsedVectorLengthBp) bp",
                    color: .blue
                )
                StudioMetricBadge(
                    label: "公式推荐",
                    value: "\(res.recommendedNgFormatted) ng",
                    color: .teal
                )
                if res.isCustomNg {
                    StudioSectionClearButton(title: "恢复推荐 ng") {
                        vm.vectorCustomNg = ""
                    }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        labeledInputField(
                            label: "长度",
                            placeholder: "5.0",
                            text: $vm.vectorLengthKb,
                            unit: "kb",
                            width: 72
                        )
                        
                        labeledInputField(
                            label: "浓度",
                            placeholder: "50",
                            text: $vm.vectorConcentration,
                            unit: "ng/μL",
                            width: 72
                        )
                        
                        labeledInputField(
                            label: "投入量",
                            placeholder: res.recommendedNgFormatted,
                            text: $vm.vectorCustomNg,
                            unit: "ng",
                            width: 76,
                            highlightColor: res.isCustomNg ? .orange : .blue
                        )
                        
                        Spacer(minLength: 4)
                        
                        HStack(spacing: 5) {
                            Text("移液体积:")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(.secondary)
                            Text("\(res.volFormatted) μL")
                                .font(.system(size: 14, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(.green)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.green.opacity(0.11))
                        )
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            labeledInputField(
                                label: "长度",
                                placeholder: "5.0",
                                text: $vm.vectorLengthKb,
                                unit: "kb",
                                width: 68
                            )
                            labeledInputField(
                                label: "浓度",
                                placeholder: "50",
                                text: $vm.vectorConcentration,
                                unit: "ng/μL",
                                width: 68
                            )
                            labeledInputField(
                                label: "投入量",
                                placeholder: res.recommendedNgFormatted,
                                text: $vm.vectorCustomNg,
                                unit: "ng",
                                width: 72,
                                highlightColor: res.isCustomNg ? .orange : .blue
                            )
                        }
                        HStack {
                            Spacer()
                            Text("移液体积: \(res.volFormatted) μL")
                                .font(.system(size: 13.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(.green)
                        }
                    }
                }
                
                // 载体投入量 ng 快捷选择胶囊条（采用 StudioFlowLayout 流式自动折行）
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    Text("快捷 ng:")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 3.5)
                    
                    ngPresetPill(
                        title: "推荐 (\(res.recommendedNgFormatted) ng)",
                        isSelected: !res.isCustomNg,
                        tint: .blue
                    ) {
                        vm.vectorCustomNg = ""
                    }
                    
                    ForEach([50, 100, 150, 200], id: \.self) { ngVal in
                        let isSel = (vm.vectorCustomNg.trimmingCharacters(in: .whitespaces) == "\(ngVal)")
                        ngPresetPill(
                            title: "\(ngVal) ng",
                            isSelected: isSel,
                            tint: .orange
                        ) {
                            vm.vectorCustomNg = "\(ngVal)"
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    // MARK: - 2. 插入片段参数卡片
    private var insertFragmentsCard: some View {
        StudioCard(title: "插入片段参数") {
            if vm.cloneType == .multi {
                StudioActionPillButton(
                    title: "增加片段",
                    icon: "plus",
                    tint: .purple,
                    isDisabled: vm.insertLengths.count >= 11,
                    action: vm.addInsertSlot
                )
            }
        } content: {
            let count = (vm.cloneType == .multi) ? vm.insertLengths.count : 1
            VStack(spacing: 10) {
                ForEach(0..<count, id: \.self) { idx in
                    insertFragmentRow(at: idx)
                }
            }
        }
    }
    
    private func insertFragmentRow(at idx: Int) -> some View {
        let res = vm.insertResult(at: idx)
        let bpLen = vm.parsedInsertLengthBp(at: idx)
        let rawName = (idx < vm.insertNames.count && !vm.insertNames[idx].isEmpty) ? vm.insertNames[idx] : "片段 \(idx + 1)"
        let displayTitle = (vm.cloneType == .multi) ? rawName : (rawName == "片段 1" ? "插入片段" : rawName)
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                Spacer()
                
                HStack(spacing: 5) {
                    Text("移液:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("\(res.volFormatted) μL")
                        .font(.system(size: 13.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.green.opacity(0.11))
                )
                .fixedSize(horizontal: true, vertical: false)
                
                if vm.cloneType == .multi && vm.insertLengths.count > 1 {
                    Button(role: .destructive) {
                        vm.removeInsertSlot(at: idx)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                StudioMetricBadge(
                    label: "长度",
                    value: "\(bpLen) bp",
                    color: .purple
                )
                
                StudioMetricBadge(
                    label: "公式推荐",
                    value: "\(res.recommendedNgFormatted) ng",
                    color: .teal
                )
                
                StudioMetricBadge(
                    label: "当前投入",
                    value: "\(res.actualNgFormatted) ng",
                    color: res.isCustomNg ? .orange : .purple
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 8) {
                labeledInputField(
                    label: "长度",
                    placeholder: "1.0",
                    text: bindingForLength(at: idx),
                    unit: "kb",
                    width: 68
                )
                
                labeledInputField(
                    label: "浓度",
                    placeholder: "20",
                    text: bindingForConc(at: idx),
                    unit: "ng/μL",
                    width: 68
                )
                
                labeledInputField(
                    label: "投入量",
                    placeholder: res.recommendedNgFormatted,
                    text: bindingForCustomNg(at: idx),
                    unit: "ng",
                    width: 72,
                    highlightColor: res.isCustomNg ? .orange : .purple
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                Text("快捷 ng:")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 3.5)
                
                ngPresetPill(
                    title: "推荐 (\(res.recommendedNgFormatted) ng)",
                    isSelected: !res.isCustomNg,
                    tint: .purple
                ) {
                    bindingForCustomNg(at: idx).wrappedValue = ""
                }
                
                ForEach([20, 40, 60, 100, 150], id: \.self) { ngVal in
                    let curStr = bindingForCustomNg(at: idx).wrappedValue.trimmingCharacters(in: .whitespaces)
                    ngPresetPill(
                        title: "\(ngVal) ng",
                        isSelected: curStr == "\(ngVal)",
                        tint: .orange
                    ) {
                        bindingForCustomNg(at: idx).wrappedValue = "\(ngVal)"
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .studioInnerBox(tint: .purple, paddingH: 11, paddingV: 11)
    }
    
    // MARK: - 3. 右侧：20 μL 推荐反应体系单
    private var reactionSystemCard: some View {
        StudioCard(title: "20 μL 推荐反应体系") {
            StudioMetricBadge(label: "条件", value: "50℃ · 15 min", color: .green)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                pipetteRow(
                    name: "2× ClonExpress Mix",
                    detail: "预混重组酶体系",
                    vol: "10.00 μL",
                    tint: .blue
                )
                
                if vm.cloneType != .simple {
                    let vRes = vm.vectorResult
                    pipetteRow(
                        name: vm.vectorName.isEmpty ? "线性化载体" : "载体 (\(vm.vectorName))",
                        detail: "\(vm.parsedVectorLengthBp) bp · 投入 \(vRes.actualNgFormatted) ng",
                        vol: "\(vRes.volFormatted) μL",
                        tint: .teal
                    )
                }
                
                let count = (vm.cloneType == .multi) ? vm.insertLengths.count : 1
                ForEach(0..<count, id: \.self) { idx in
                    let r = vm.insertResult(at: idx)
                    let bp = vm.parsedInsertLengthBp(at: idx)
                    let rawName = (idx < vm.insertNames.count && !vm.insertNames[idx].isEmpty) ? vm.insertNames[idx] : "片段 \(idx + 1)"
                    let title = (vm.cloneType == .multi) ? rawName : (rawName == "片段 1" ? "插入片段" : rawName)
                    pipetteRow(
                        name: title,
                        detail: "\(bp) bp · 投入 \(r.actualNgFormatted) ng",
                        vol: "\(r.volFormatted) μL",
                        tint: .purple
                    )
                }
                
                pipetteRow(
                    name: "ddH₂O",
                    detail: "无菌超纯水",
                    vol: vm.remainingWaterFormatted,
                    tint: .secondary
                )
            }
        }
    }
    
    // MARK: - 辅助组件
    private func labeledInputField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        unit: String,
        width: CGFloat,
        highlightColor: Color? = nil
    ) -> some View {
        HStack(spacing: 5) {
            Text("\(label):")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
                .frame(width: width)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(highlightColor?.opacity(0.45) ?? Color.clear, lineWidth: 1)
                )
            Text(unit)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private func ngPresetPill(
        title: String,
        isSelected: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        StudioCompactPillButton(
            title: title,
            tint: tint,
            isProminent: isSelected,
            action: action
        )
    }

    private func pipetteRow(name: String, detail: String, vol: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                Text(detail)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(vol)
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundColor(tint == .secondary ? .primary : tint)
        }
        .studioInnerBox(paddingH: 10, paddingV: 8)
    }
    
    private func bindingForLength(at index: Int) -> Binding<String> {
        Binding(
            get: { index < vm.insertLengths.count ? vm.insertLengths[index] : "" },
            set: { if index < vm.insertLengths.count { vm.insertLengths[index] = $0 } }
        )
    }
    
    private func bindingForConc(at index: Int) -> Binding<String> {
        Binding(
            get: { index < vm.insertConcs.count ? vm.insertConcs[index] : "" },
            set: { if index < vm.insertConcs.count { vm.insertConcs[index] = $0 } }
        )
    }
    
    private func bindingForCustomNg(at index: Int) -> Binding<String> {
        Binding(
            get: { index < vm.insertCustomNgs.count ? vm.insertCustomNgs[index] : "" },
            set: {
                while vm.insertCustomNgs.count <= index {
                    vm.insertCustomNgs.append("")
                }
                vm.insertCustomNgs[index] = $0
            }
        )
    }
}
