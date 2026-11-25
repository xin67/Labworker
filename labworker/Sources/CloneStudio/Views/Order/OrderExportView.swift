import SwiftUI
import UniformTypeIdentifiers
import CloneStudioCore

/// 商业订购表单中心（支持擎科 / 生工 / IDT / Twist / GenScript / Eurofins / BGI 及自定义 JSON 列映射）
public struct OrderExportView: View {
    @ObservedObject private var appState = AppState.shared
    @StateObject private var vm = OrderExportViewModel()
    @State private var isEditingProfile: Bool = false
    @State private var showManualOligoInput: Bool = false
    @State private var showCustomTemplateSheet: Bool = false

    @State private var manualOligoName: String = "GeneFrag_1"
    @State private var manualOligoSeq: String = ""
    @State private var manualOligoPurity: String = "PAGE"
    @State private var manualOligoOD: String = "2.0"
    @State private var manualOligoPurpose: String = "合成订购"
    
    @State private var newSampleName: String = "pCE-Construct"
    @State private var newVectorName: String = "pCE-Entry"
    @State private var newPrimerName: String = "T7"
    @State private var newFragLen: String = "1000"
    
    public init() {}
    
    public var body: some View {
        StudioPageLayout(
            title: "订购中心",
            toolbar: [
                .picker(
                    id: "order_category",
                    label: "订购类别",
                    options: [
                        StudioToolbarPickerOption(
                            id: "primerSynthesis",
                            title: "引物合成 (\(appState.primersCart.count))",
                            tint: .blue,
                            isSelected: vm.selectedCategory == .primerSynthesis
                        ) {
                            vm.selectedCategory = .primerSynthesis
                        },
                        StudioToolbarPickerOption(
                            id: "dnaSequencing",
                            title: "DNA 测序 (\(appState.sangonSamples.count))",
                            tint: .purple,
                            isSelected: vm.selectedCategory == .dnaSequencing
                        ) {
                            vm.selectedCategory = .dnaSequencing
                        }
                    ]
                )
            ]
        ) {
                
                StudioCard(title: "订购信息") {
                    StudioActionPillButton(
                        title: isEditingProfile ? "完成" : "编辑",
                        icon: isEditingProfile ? "checkmark" : "pencil"
                    ) {
                        isEditingProfile.toggle()
                    }
                } content: {
                    if isEditingProfile {
                        profileEditView
                    } else {
                        profileDisplayView
                    }
                }
                
                if vm.selectedCategory == .primerSynthesis {
                    primerOrderSection
                } else {
                    sequencingOrderSection
                }
        }
        .alert("导出成功", isPresented: $vm.showSuccessAlert) {
            Button("在 Finder 中打开") { vm.revealLastExported() }
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.exportedFilePath ?? "")
        }
        .alert("导出失败", isPresented: $vm.showErrorAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .sheet(isPresented: $showCustomTemplateSheet) {
            CustomOrderTemplateEditorSheet(vm: vm)
        }
    }
    
    // MARK: - 订购人信息展示卡片
    private var profileDisplayView: some View {
        let p = appState.profile
        return VStack(alignment: .leading, spacing: 6) {
            StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 6) {
                Text("\(p.customerName) · \(p.piName) 课题组")
                    .font(.system(size: 12, weight: .semibold))
                Text(p.organization)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(p.phone)
                    .font(.system(size: 12))
                    .monospacedDigit()
                Text(p.email)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                StudioMetricBadge(label: "", value: "\(p.defaultPurity) · \(String(format: "%.1f", p.defaultOD)) OD", color: .blue)
            }
            
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text(p.address)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
    
    private var profileEditView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("客户姓名", text: $appState.profile.customerName)
                TextField("课题组PI", text: $appState.profile.piName)
                TextField("客户单位", text: $appState.profile.organization)
            }
            HStack(spacing: 10) {
                TextField("联系电话", text: $appState.profile.phone)
                TextField("电子邮箱", text: $appState.profile.email)
                TextField("发票抬头", text: $appState.profile.invoiceTitle)
            }
            TextField("收样地址", text: $appState.profile.address)
        }
        .textFieldStyle(.roundedBorder)
    }
    
    // MARK: - 1. 引物与基因合成订购区
    private var activePrimerTemplateLabel: String {
        if vm.selectedPrimerTemplate == .customJSON {
            return "自定义: \(vm.activeCustomTemplate?.name ?? "JSON")"
        }
        switch vm.selectedPrimerTemplate {
        case .tsingkePrimer: return "擎科引物 (.xlsx)"
        case .idtBulk:       return "IDT Bulk Input"
        case .twistBulk:     return "Twist Bioscience"
        case .genscriptBulk: return "GenScript 金斯瑞"
        case .eurofinsBulk:  return "Eurofins Genomics"
        case .bgiBulk:       return "华大基因 BGI"
        default:             return vm.selectedPrimerTemplate.displayName
        }
    }

    private var primerOrderSection: some View {
        let fmtExt = vm.selectedPrimerTemplate.requiresBundledXLSXTemplate ? "xlsx" : vm.selectedOutputFormat.rawValue
        return StudioCard(title: "引物与基因合成池 (\(appState.primersCart.count))") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                StudioMenuPillButton(
                    title: activePrimerTemplateLabel,
                    icon: "building.2.fill",
                    tint: .indigo,
                    compact: true,
                    help: "选择国内/国际合成商批量模板或自定义 JSON 映射"
                ) {
                    Section("常用合成商模板") {
                        ForEach([OrderFormTemplate.tsingkePrimer, .idtBulk, .twistBulk, .genscriptBulk, .eurofinsBulk, .bgiBulk]) { tpl in
                            Button {
                                vm.selectPrimerTemplate(tpl)
                            } label: {
                                HStack {
                                    Text(tpl.displayName)
                                    if vm.selectedPrimerTemplate == tpl {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    if !vm.customTemplates.isEmpty {
                        Section("自定义列映射模板 (.json)") {
                            ForEach(vm.customTemplates) { ct in
                                Button {
                                    vm.selectPrimerTemplate(.customJSON, customTemplateID: ct.id)
                                } label: {
                                    HStack {
                                        Text("\(ct.name) (\(ct.columns.count) 列)")
                                        if vm.selectedPrimerTemplate == .customJSON && vm.selectedCustomTemplateID == ct.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if !vm.selectedPrimerTemplate.requiresBundledXLSXTemplate {
                    StudioSegmentedPicker(
                        selection: $vm.selectedOutputFormat,
                        options: OrderOutputFileFormat.allCases.map {
                            StudioSegmentedOption(value: $0, title: ".\($0.rawValue.uppercased())", tint: .blue)
                        }
                    )
                }

                StudioCompactPillButton(
                    title: "自定义模板",
                    icon: "slider.horizontal.3",
                    tint: .indigo
                ) {
                    showCustomTemplateSheet = true
                }

                StudioCompactPillButton(
                    title: showManualOligoInput ? "收起手动添加" : "手动添加",
                    icon: "plus",
                    tint: .teal,
                    isSelected: showManualOligoInput
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showManualOligoInput.toggle()
                    }
                }

                StudioActionPillButton(
                    title: "复制 TSV",
                    icon: "doc.on.doc",
                    isDisabled: appState.primersCart.isEmpty,
                    action: vm.copyAsTSV
                )

                StudioActionPillButton(
                    title: "复制 FASTA",
                    icon: "text.alignleft",
                    isDisabled: appState.primersCart.isEmpty,
                    action: vm.copyAsFASTA
                )

                StudioActionPillButton(
                    title: "写入 .dna",
                    icon: "bolt.fill",
                    tint: .purple,
                    isProminent: true,
                    isDisabled: appState.primersCart.isEmpty
                ) {
                    selectDNAFile { url in
                        Task {
                            do {
                                let res = try await SnapGeneService.shared.injectPrimers(appState.primersCart, into: url, createBackup: true)
                                appState.showToast("已将 \(res.primersAdded) 条引物写入质粒")
                                SnapGeneService.shared.openInSnapGene(url: url)
                            } catch {
                                appState.showToast("写入失败: \(error.localizedDescription)")
                            }
                        }
                    }
                }

                StudioActionPillButton(
                    title: "导出 .\(fmtExt)",
                    icon: "arrow.down.doc.fill",
                    tint: .blue,
                    isProminent: true,
                    isDisabled: appState.primersCart.isEmpty || vm.isExporting,
                    help: "按所选供应商模板导出 .\(fmtExt) 批量订购文件",
                    action: vm.exportPrimersOrder
                )

                StudioSectionClearButton(
                    title: "清空引物",
                    isDisabled: appState.primersCart.isEmpty,
                    action: appState.clearPrimersCart
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if showManualOligoInput {
                    StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        TextField("名称 (如 EGF_opt)", text: $manualOligoName)
                            .frame(width: 130)
                        TextField("5'->3' DNA 序列 (引物或基因片段)", text: $manualOligoSeq)
                            .frame(minWidth: 220, maxWidth: 340)
                        TextField("纯化 (PAGE/HPLC)", text: $manualOligoPurity)
                            .frame(width: 95)
                        TextField("OD", text: $manualOligoOD)
                            .frame(width: 55)
                        TextField("用途备注", text: $manualOligoPurpose)
                            .frame(width: 110)

                        StudioCompactPillButton(title: "加入订购池", icon: "plus.circle.fill", tint: .teal) {
                            vm.addManualOligoOrGene(
                                name: manualOligoName,
                                sequence: manualOligoSeq,
                                purity: manualOligoPurity,
                                od: Double(manualOligoOD) ?? 2.0,
                                purpose: manualOligoPurpose
                            )
                            manualOligoSeq = ""
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5))
                    .studioInnerBox(tint: .teal, paddingH: 10, paddingV: 8)
                }

                if !appState.primersCart.isEmpty && !vm.sanitizationWarnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 11.5))
                            Text("供应商格式清洗提示（导出时自动处理）：")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        ForEach(vm.sanitizationWarnings, id: \.self) { warn in
                            Text("• \(warn)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .studioInnerBox(tint: .orange, paddingH: 10, paddingV: 8)
                }

                if appState.primersCart.isEmpty {
                    HStack {
                        Spacer()
                        Text("暂无待订引物或基因片段（可通过左侧克隆/密码子优化加入，或点击「手动添加」）")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 22)
                } else {
                    VStack(spacing: 5) {
                        ForEach(Array(appState.primersCart.enumerated()), id: \.element.id) { index, primer in
                            HStack(spacing: 8) {
                                Text("#\(index + 1)")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .frame(width: 24, alignment: .leading)
                                
                                Text(primer.name)
                                    .font(.system(size: 11.5, weight: .bold))
                                    .frame(width: 140, alignment: .leading)
                                
                                Text(primer.fullSequence)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                                
                                Spacer()
                                
                                Text("\(primer.length)bp")
                                    .font(.system(size: 10.5))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                
                                Text(primer.purity)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(.blue)
                                
                                Text("\(String(format: "%.1f", primer.od)) OD")
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                
                                StudioCompactPillButton(
                                    title: "",
                                    icon: "xmark",
                                    tint: .secondary,
                                    help: "移除引物"
                                ) {
                                    appState.removePrimer(at: index)
                                }
                            }
                            .studioInnerBox(paddingH: 10, paddingV: 6)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 2. DNA 测序订购区
    private var sequencingOrderSection: some View {
        StudioCard(title: "测序样品 (\(appState.sangonSamples.count))") {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                StudioMenuPicker(
                    selection: $vm.selectedSeqTemplate,
                    options: [
                        StudioMenuPickerOption(value: OrderFormTemplate.tsingkeSeq, title: "擎科测序专属单"),
                        StudioMenuPickerOption(value: OrderFormTemplate.sangonSeq, title: "生工测序专属版"),
                        StudioMenuPickerOption(value: OrderFormTemplate.sangonV9Seq, title: "生工通用 V9 版")
                    ],
                    icon: "doc.plaintext",
                    help: "选择测序送样表格模板"
                )

                StudioActionPillButton(
                    title: "导出 .xlsx",
                    icon: "arrow.down.doc.fill",
                    tint: .purple,
                    isProminent: true,
                    isDisabled: appState.sangonSamples.isEmpty || vm.isExporting,
                    help: "导出商业 DNA 测序送样表 (.xlsx)",
                    action: vm.exportSequencingOrder
                )

                StudioSectionClearButton(
                    title: "清空样品",
                    isDisabled: appState.sangonSamples.isEmpty,
                    action: vm.clearSamples
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    TextField("样品名", text: $newSampleName)
                        .frame(width: 130)
                    TextField("载体", text: $newVectorName)
                        .frame(width: 105)
                    TextField("引物", text: $newPrimerName)
                        .frame(width: 75)
                    TextField("长度bp", text: $newFragLen)
                        .frame(width: 70)

                    StudioCompactPillButton(title: "添加样品", icon: "plus") {
                        let len = Int(newFragLen) ?? 1000
                        vm.addSample(name: newSampleName, vector: newVectorName, primer: newPrimerName, fragmentLength: len)
                    }

                    StudioCompactPillButton(title: "双向 (T7/BGH)", icon: "plus.circle") {
                        vm.addPairSample(name: newSampleName, vector: newVectorName)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                
                if appState.sangonSamples.isEmpty {
                    HStack {
                        Spacer()
                        Text("暂无测序样品")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 5) {
                        ForEach(Array(appState.sangonSamples.enumerated()), id: \.element.id) { index, sample in
                            HStack(spacing: 8) {
                                Text("#\(index + 1)")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                    .frame(width: 24, alignment: .leading)
                                
                                Text(sample.sampleName)
                                    .font(.system(size: 11.5, weight: .bold))
                                    .frame(width: 140, alignment: .leading)
                                
                                Text(sample.sampleType)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule(style: .continuous).fill(Color.secondary.opacity(0.12)))
                                
                                Text(sample.vectorName)
                                    .font(.system(size: 11))
                                    .foregroundColor(.purple)
                                
                                Text("\(sample.fragmentLength)bp")
                                    .font(.system(size: 10.5))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                                
                                StudioMetricBadge(label: "引物", value: sample.primerName, color: .blue)
                                
                                Text(sample.requirement)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                StudioCompactPillButton(
                                    title: "",
                                    icon: "xmark",
                                    tint: .secondary,
                                    help: "移除样品"
                                ) {
                                    vm.removeSample(at: index)
                                }
                            }
                            .studioInnerBox(paddingH: 10, paddingV: 6)
                        }
                    }
                }
            }
        }
    }
    
    private func selectDNAFile(completion: @escaping (URL) -> Void) {
        FinderFileDropHelper.selectDNAFile(
            message: "选择待注入引物的 SnapGene (.dna) 质粒文件",
            prompt: "批量写入",
            completion: completion
        )
    }
}

// MARK: - 自定义列映射 JSON 模板编辑器弹窗

private struct CustomOrderTemplateEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appState = AppState.shared
    @ObservedObject var vm: OrderExportViewModel

    @State private var draft: CustomOrderTemplateSpec
    @State private var importExportError: String? = nil

    init(vm: OrderExportViewModel) {
        self.vm = vm
        _draft = State(initialValue: vm.activeCustomTemplate ?? OrderTemplateEngine.defaultCustomTemplate())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自定义订购表列映射模板 (.json)")
                        .font(.system(size: 15, weight: .bold))
                    Text("按需映射列标题与 Labworker 序列/孔板/规格字段，支持导出/导入团队共享 JSON 模板")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                if vm.customTemplates.count > 1 {
                    StudioMenuPicker(
                        selection: Binding(
                            get: { draft.id },
                            set: { newID in
                                if let found = vm.customTemplates.first(where: { $0.id == newID }) {
                                    draft = found
                                }
                            }
                        ),
                        options: vm.customTemplates.map { StudioMenuPickerOption(value: $0.id, title: $0.name) },
                        prefix: "已有模板",
                        icon: "doc.badge.gearshape",
                        compact: true
                    )
                }

                StudioCompactPillButton(title: "新建空白模板", icon: "plus", tint: .blue) {
                    draft = OrderTemplateEngine.defaultCustomTemplate()
                    draft.id = UUID().uuidString
                    draft.name = "新模板 \(vm.customTemplates.count + 1)"
                }

                StudioCompactPillButton(title: "导入 .json", icon: "square.and.arrow.down", tint: .teal) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    if panel.runModal() == .OK, let url = panel.url {
                        do {
                            let data = try Data(contentsOf: url)
                            var decoded = try JSONDecoder().decode(CustomOrderTemplateSpec.self, from: data)
                            if decoded.id.isEmpty { decoded.id = UUID().uuidString }
                            draft = decoded
                            importExportError = nil
                        } catch {
                            importExportError = "导入 JSON 失败：\(error.localizedDescription)"
                        }
                    }
                }

                StudioCompactPillButton(title: "导出 .json", icon: "square.and.arrow.up", tint: .indigo) {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.json]
                    panel.nameFieldStringValue = "\(draft.name.replacingOccurrences(of: " ", with: "_")).json"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? vm.exportCustomTemplateJSON(draft, to: url)
                    }
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("模板名称").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("模板名称", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("工作表名 / 供应商").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Sheet 名称", text: $draft.sheetName)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("默认格式").font(.system(size: 11)).foregroundStyle(.secondary)
                    StudioSegmentedPicker(
                        selection: $draft.preferredFormat,
                        options: OrderOutputFileFormat.allCases.map {
                            StudioSegmentedOption(value: $0, title: $0.rawValue.uppercased(), tint: .blue)
                        }
                    )
                }
            }

            if let err = importExportError {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(draft.columns.enumerated()), id: \.element.id) { idx, _ in
                        HStack(spacing: 8) {
                            Text("#\(idx + 1)")
                                .font(.system(size: 11, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            TextField("导出列标题", text: $draft.columns[idx].header)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)

                            StudioMenuPicker(
                                selection: $draft.columns[idx].field,
                                options: OrderColumnField.allCases.map {
                                    StudioMenuPickerOption(value: $0, title: $0.displayName)
                                },
                                icon: "arrow.left.arrow.right",
                                compact: true
                            )

                            TextField("默认值", text: $draft.columns[idx].defaultValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)

                            StudioCompactPillButton(title: "", icon: "arrow.up", isDisabled: idx == 0) {
                                draft.columns.swapAt(idx, idx - 1)
                            }
                            StudioCompactPillButton(title: "", icon: "arrow.down", isDisabled: idx >= draft.columns.count - 1) {
                                draft.columns.swapAt(idx, idx + 1)
                            }
                            StudioCompactPillButton(title: "", icon: "trash", tint: .red, isDisabled: draft.columns.count <= 1) {
                                draft.columns.remove(at: idx)
                            }
                        }
                        .studioInnerBox(paddingH: 8, paddingV: 6)
                    }
                }
            }
            .frame(maxHeight: 220)

            let samplePrimers = AppState.shared.primersCart.isEmpty
                ? [PrimerItem(name: "Demo_EGFP_F", fullSequence: "ggatccATGGTGAGCAAGGGCGAG", homologyArm: "ggatcc", specificSequence: "ATGGTGAGCAAGGGCGAG", tm: 60.2, purity: "PAGE", od: 2.0, targetPurpose: "克隆扩增")]
                : Array(AppState.shared.primersCart.prefix(3))
            VStack(alignment: .leading, spacing: 4) {
                Text("实时预览 (前 \(samplePrimers.count) 条)：")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(OrderTemplateEngine.renderCSVPreview(spec: draft, primers: samplePrimers, profile: AppState.shared.profile))
                    .font(.system(size: 10.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                            .stroke(StudioPalette.controlBorder(isLight: appState.isLightAppearance), lineWidth: 1)
                    )
            }

            StudioActionBar {
                StudioCompactPillButton(title: "新增映射列", icon: "plus.circle", tint: .teal) {
                    draft.columns.append(OrderColumnMapping(header: "Column_\(draft.columns.count + 1)", field: .notes))
                }
                StudioPrimaryActionButton(title: "保存并应用此模板", icon: "checkmark.circle.fill", tint: .indigo) {
                    vm.saveCustomTemplate(draft)
                    dismiss()
                }
            }
        }
        .padding(18)
        .frame(width: 680, height: 610)
    }
}
