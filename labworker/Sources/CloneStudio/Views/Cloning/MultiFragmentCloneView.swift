import CloneStudioCore
import SwiftUI

/// 多片段无缝克隆引物设计界面 (支持载体与每个片段分别载入 .dna 解析特征/酶切位点供选择，并支持 Type IIS Golden Gate 模式)
public struct MultiFragmentCloneView: View {
    private enum MultiAssemblyMode: String, CaseIterable {
        case gibson = "同源重组 (Gibson / In-Fusion)"
        case goldenGate = "Golden Gate (Type IIS)"
    }

    @ObservedObject private var vm = WorkspaceSessionManager.shared.multiFragmentVM
    @ObservedObject private var appState = AppState.shared
    @State private var assemblyMode: MultiAssemblyMode = .gibson
    
    public init() {}
    
    private var previewData: PlasmidConstructPreviewData? {
        let effFrags = vm.effectiveFragments
        if let vecInfo = vm.vectorDNAInfo {
            let combinedIns = effFrags.joined()
            if let recomb = PlasmidMapBuilder.forSnapGeneRecombinant(
                vectorInfo: vecInfo,
                insertSeq: combinedIns,
                insertName: "Multi-\(vm.fragments.count)Frags",
                cutStart: vm.cutStart,
                cutEnd: vm.cutEnd,
                primers: vm.primers
            ) {
                return recomb
            }
            let safeEnd = max(vm.cutStart, vm.cutEnd)
            return PlasmidMapBuilder.forRawSnapGeneFile(
                info: vecInfo,
                highlightRange: vm.cutStart...safeEnd
            )
        }
        if let firstDonor = vm.fragmentDonorInfos.sorted(by: { $0.key < $1.key }).first?.value {
            return PlasmidMapBuilder.forRawSnapGeneFile(info: firstDonor, highlightRange: nil)
        }
        return PlasmidMapBuilder.forMultiFragment(
            fragments: effFrags,
            vectorSeq: vm.vectorSeq,
            enzymeSingle: vm.enzymeSingle,
            primers: vm.primers
        )
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "多片段无缝克隆",
            toolbar: [
                .plasmidToggle(isOn: $appState.showPlasmidPreview, isAvailable: previewData != nil),
                .plasmidFile(
                    id: "multi_vector_file",
                    roleTitle: "载体",
                    tint: .blue,
                    info: vm.vectorDNAInfo,
                    onLoadURL: { url in Task { await vm.loadVectorDNA(url: url) } },
                    onPreview: {
                        if let vec = vm.vectorDNAInfo {
                            PlasmidWindowPresenter.shared.openPreviewWindow(for: vec, roleLabel: "原始载体质粒预览", highlightRange: nil)
                        }
                    }
                ),
                .action(title: "算用量", icon: "function", tint: .purple, help: "将多片段与载体长度送入用量计算") {
                    vm.sendLengthsToCalculator(navigate: true)
                },
                .action(title: "电泳模拟", icon: "chart.bar.doc.horizontal", tint: .green, help: "在独立窗口放大检视多片段同源组装 PCR 模拟电泳") {
                    GelSimulationWindowPresenter.shared.openWindow(
                        title: "多片段同源组装 PCR 模拟电泳",
                        accentTint: .green,
                        compareLaneTitle: "显示组装体系混合对照",
                        buildSimulation: multiGelSimulation
                    )
                },
                .action(title: "示例", icon: "sparkles", help: "载入多片段组装示例", action: loadSampleMultiFragments),
                .action(id: "clear_multi", title: "", icon: "trash", tint: .red, help: "清空当前多片段配置", action: vm.clear)
            ]
        ) {
            AdaptiveTwoColumnWorkspace(hasRight: assemblyMode == .gibson && previewData != nil && appState.showPlasmidPreview) {
                VStack(alignment: .leading, spacing: 12) {
                    StudioSegmentedPicker(
                        selection: $assemblyMode,
                        options: [
                            StudioSegmentedOption(value: MultiAssemblyMode.gibson, title: MultiAssemblyMode.gibson.rawValue, tint: .green),
                            StudioSegmentedOption(value: MultiAssemblyMode.goldenGate, title: MultiAssemblyMode.goldenGate.rawValue, tint: .orange)
                        ]
                    )

                    if assemblyMode == .goldenGate {
                        GoldenGatePanelView(vm: vm)
                    } else {
                    // 0. 多片段同源重组载体长度与各插入片段长度汇总栏
                    multiHomologousLengthSummaryBar
                        // 1. 载体解析与克隆位点选择面板
                        if let vec = vm.vectorDNAInfo {
                            let delLen = max(0, vm.cutEnd - vm.cutStart + 1)
                            VStack(alignment: .leading, spacing: 8) {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text.magnifyingglass")
                                            .foregroundColor(.blue)
                                        Text(L10n.tr("已解析载体: \(vec.fileName)", "Parsed Vector: \(vec.fileName)"))
                                            .font(.system(size: 12, weight: .bold))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(L10n.tr("(\(vec.length) bp · \(vec.featuresCount) 特征)", "(\(vec.length) bp · \(vec.featuresCount) features)"))
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(delLen > 0 ? L10n.tr("替换区间: \(vm.cutStart)..\(vm.cutEnd) (Δ\(delLen)bp)", "Replace Range: \(vm.cutStart)..\(vm.cutEnd) (Δ\(delLen) bp)") : L10n.tr("插入位点: @\(vm.cutStart) bp", "Insertion Site: @\(vm.cutStart) bp"))
                                            .font(.system(size: 11, weight: .semibold))
                                            .monospacedDigit()
                                            .foregroundColor(.blue)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2.5)
                                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                                        FinderRevealButton(filePath: vec.filePath, label: "")
                                        StudioActionPillButton(
                                            title: "预览",
                                            icon: "eye.fill",
                                            tint: .blue,
                                            isProminent: true,
                                            help: "预览载体质粒图谱"
                                        ) {
                                            PlasmidWindowPresenter.shared.openPreviewWindow(
                                                for: vec,
                                                roleLabel: "原始载体质粒预览",
                                                highlightRange: nil
                                            )
                                        }
                                        StudioSectionClearButton(label: L10n.t("一键清除载体"), action: vm.clearVectorSection)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "doc.text.magnifyingglass")
                                                .foregroundColor(.blue)
                                            Text(L10n.tr("已解析载体: \(vec.fileName)", "Parsed Vector: \(vec.fileName)"))
                                                .font(.system(size: 12, weight: .bold))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer()
                                            FinderRevealButton(filePath: vec.filePath, label: "")
                                            StudioSectionClearButton(label: L10n.t("一键清除载体"), action: vm.clearVectorSection)
                                        }
                                        HStack(spacing: 6) {
                                            Text(delLen > 0 ? L10n.tr("替换区间: \(vm.cutStart)..\(vm.cutEnd) (Δ\(delLen)bp)", "Replace Range: \(vm.cutStart)..\(vm.cutEnd) (Δ\(delLen) bp)") : L10n.tr("插入位点: @\(vm.cutStart) bp", "Insertion Site: @\(vm.cutStart) bp"))
                                                .font(.system(size: 11, weight: .semibold))
                                                .monospacedDigit()
                                                .foregroundColor(.blue)
                                            Spacer()
                                            StudioCompactPillButton(
                                                title: "预览",
                                                icon: "eye.fill",
                                                tint: .blue,
                                                isProminent: true
                                            ) {
                                                PlasmidWindowPresenter.shared.openPreviewWindow(
                                                    for: vec,
                                                    roleLabel: "原始载体质粒预览",
                                                    highlightRange: nil
                                                )
                                            }
                                        }
                                    }
                                }
                                
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 8) {
                                        Text(L10n.t("定位至载体特征:"))
                                            .font(.system(size: 11.5))
                                            .foregroundColor(.secondary)
                                            .fixedSize()
                                        Picker("", selection: Binding(
                                            get: { vm.selectedVectorFeatureID },
                                            set: { id in vm.selectVectorFeature(id: id) }
                                        )) {
                                            ForEach(vm.sortedVectorFeatures) { f in
                                                let s = f.segments.first?.start ?? 1
                                                let e = f.segments.last?.end ?? 1
                                                Text("\(f.name) [\(s)..\(e), \(e - s + 1) bp] (\(f.type))").tag(f.id)
                                            }
                                        }
                                        .labelsHidden()
                                        .frame(maxWidth: 320)
                                        
                                        Picker("", selection: Binding(
                                            get: { vm.vectorInsertAction },
                                            set: { act in vm.selectVectorFeature(id: vm.selectedVectorFeatureID, action: act) }
                                        )) {
                                            ForEach(SingleFragmentViewModel.VectorInsertAction.allCases) { act in
                                                Text(L10n.t(act.rawValue)).tag(act)
                                            }
                                        }
                                        .labelsHidden()
                                        .frame(width: 175)
                                        Spacer()
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 6) {
                                            Text(L10n.t("定位至载体特征:"))
                                                .font(.system(size: 11.5))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            Picker("", selection: Binding(
                                                get: { vm.selectedVectorFeatureID },
                                                set: { id in vm.selectVectorFeature(id: id) }
                                            )) {
                                                ForEach(vm.sortedVectorFeatures) { f in
                                                    let s = f.segments.first?.start ?? 1
                                                    let e = f.segments.last?.end ?? 1
                                                    Text("\(f.name) [\(s)..\(e), \(e - s + 1) bp] (\(f.type))").tag(f.id)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(maxWidth: .infinity)
                                        }
                                        Picker("", selection: Binding(
                                            get: { vm.vectorInsertAction },
                                            set: { act in vm.selectVectorFeature(id: vm.selectedVectorFeatureID, action: act) }
                                        )) {
                                            ForEach(SingleFragmentViewModel.VectorInsertAction.allCases) { act in
                                                Text(L10n.t(act.rawValue)).tag(act)
                                            }
                                        }
                                        .labelsHidden()
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                                
                                if !vm.availableVectorCutSites.isEmpty {
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 8) {
                                            Text(L10n.t("或按载体真实酶切位点:"))
                                                .font(.system(size: 11.5))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            Picker("", selection: Binding(
                                                get: { vm.selectedVectorCutSiteID },
                                                set: { id in vm.selectVectorCutSite(id: id) }
                                            )) {
                                                ForEach(vm.availableVectorCutSites) { opt in
                                                    Text(opt.displayTitle).tag(opt.id)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(maxWidth: 320)
                                            Spacer()
                                        }
                                        
                                        HStack(spacing: 6) {
                                            Text(L10n.t("真实酶切位点:"))
                                                .font(.system(size: 11.5))
                                                .foregroundColor(.secondary)
                                                .fixedSize()
                                            Picker("", selection: Binding(
                                                get: { vm.selectedVectorCutSiteID },
                                                set: { id in vm.selectVectorCutSite(id: id) }
                                            )) {
                                                ForEach(vm.availableVectorCutSites) { opt in
                                                    Text(opt.displayTitle).tag(opt.id)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                            }
                            .studioInnerBox(tint: .blue, paddingH: 10, paddingV: 10)
                        }
                        
                        // 2. 载体与线性化配置
                        StudioCard(title: "载体与线性化位点") {
                            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                if vm.effectiveVectorBackboneLengthBp > 0 {
                                    StudioMetricBadge(
                                        label: L10n.t("载体长度"),
                                        value: "\(vm.effectiveVectorBackboneLengthBp) bp (\(String(format: "%.2f", Double(vm.effectiveVectorBackboneLengthBp) / 1000.0)) kb)",
                                        color: .blue
                                    )
                                }
                                HStack(spacing: 4) {
                                    Text(L10n.t("酶切位点：")).font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                                    Picker("", selection: $vm.enzymeSingle) {
                                        ForEach(RestrictionEnzymeDatabase.shared.enzymes) { enzyme in
                                            Text("\(enzyme.name) (\(enzyme.site))").tag(Optional(enzyme))
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 180)
                                }
                                StudioSectionClearButton(label: L10n.t("一键清除载体"), action: vm.clearVectorSection)
                            }
                        } content: {
                            SequenceEditorBox(text: $vm.vectorSeq, placeholder: L10n.t("输入或拖入载体序列"), minHeight: 60)
                        }
                        
                        // 3. 插入片段列表 (每个片段均支持独立载入供体 .dna 并选择特征/坐标)
                        StudioCard(title: L10n.tr("插入片段 (\(vm.fragments.count))", "Insert Fragments (\(vm.fragments.count))")) {
                            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                if vm.totalInsertLengthBp > 0 {
                                    StudioMetricBadge(
                                        label: L10n.t("插入总长"),
                                        value: "\(vm.totalInsertLengthBp) bp (\(String(format: "%.2f", Double(vm.totalInsertLengthBp) / 1000.0)) kb)",
                                        color: .green
                                    )
                                }
                                StudioActionPillButton(
                                    title: "增加片段",
                                    icon: "plus",
                                    tint: .green,
                                    isDisabled: vm.fragments.count >= 10,
                                    action: vm.addFragment
                                )
                                StudioSectionClearButton(label: L10n.t("一键清除全部片段"), action: vm.clearAllFragmentsSection)
                            }
                        } content: {
                            VStack(spacing: 10) {
                                ForEach(0..<vm.fragments.count, id: \.self) { idx in
                                    let count = BioSequence.clean(vm.fragments[idx]).count
                                    VStack(alignment: .leading, spacing: 6) {
                                        ViewThatFits(in: .horizontal) {
                                            HStack(spacing: 8) {
                                                Text(L10n.tr("片段 \(idx + 1)", "Fragment \(idx + 1)")).font(.system(size: 12, weight: .bold))
                                                StudioMetricBadge(label: L10n.t("长度"), value: "\(count) bp", color: count >= 50 ? .green : .orange)
                                                
                                                StudioActionPillButton(
                                                    title: "载入 .dna",
                                                    icon: "folder.badge.plus",
                                                    help: "从 .dna 供体质粒载入并选择特征"
                                                ) {
                                                    selectDNAFile { url in
                                                        Task { await vm.loadFragmentDonorDNA(at: idx, url: url) }
                                                    }
                                                }

                                                Spacer()
                                                StudioSectionClearButton(label: L10n.t("一键清除本片段")) {
                                                    vm.clearFragment(at: idx)
                                                }
                                                if vm.fragments.count > 2 {
                                                    StudioCompactPillButton(title: "移除", icon: "minus.circle", tint: .red) {
                                                        vm.removeFragment(at: idx)
                                                    }
                                                }
                                            }
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack {
                                                    Text(L10n.tr("片段 \(idx + 1)", "Fragment \(idx + 1)")).font(.system(size: 12, weight: .bold))
                                                    StudioMetricBadge(label: L10n.t("长度"), value: "\(count) bp", color: count >= 50 ? .green : .orange)
                                                    Spacer()
                                                    StudioSectionClearButton(label: L10n.t("一键清除本片段")) {
                                                        vm.clearFragment(at: idx)
                                                    }
                                                    if vm.fragments.count > 2 {
                                                        StudioCompactPillButton(title: "移除", icon: "minus.circle", tint: .red) {
                                                            vm.removeFragment(at: idx)
                                                        }
                                                    }
                                                }
                                                StudioActionPillButton(
                                                    title: "载入 .dna",
                                                    icon: "folder.badge.plus",
                                                    help: "从 .dna 载入并选特征"
                                                ) {
                                                    selectDNAFile { url in
                                                        Task { await vm.loadFragmentDonorDNA(at: idx, url: url) }
                                                    }
                                                }
                                            }
                                        }
                                        
                                        // 若该片段已载入供体 .dna，展示特征下拉框与坐标提取器
                                        if let donorInfo = vm.fragmentDonorInfos[idx] {
                                            let donorFeats = donorInfo.features.filter { !$0.segments.isEmpty }
                                            ViewThatFits(in: .horizontal) {
                                                HStack(spacing: 8) {
                                                    Text(L10n.tr("供体: \(donorInfo.fileName)", "Donor: \(donorInfo.fileName)"))
                                                        .font(.system(size: 11, weight: .semibold))
                                                        .foregroundColor(.green)
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)
                                                    if !donorFeats.isEmpty {
                                                        Picker("", selection: Binding(
                                                            get: { vm.fragmentSelectedFeatureIDs[idx] ?? "" },
                                                            set: { fid in vm.selectFragmentFeature(at: idx, featureID: fid) }
                                                        )) {
                                                            ForEach(donorFeats) { f in
                                                                let s = f.segments.first?.start ?? 1
                                                                let e = f.segments.last?.end ?? 1
                                                                Text("\(f.name) [\(s)..\(e), \(e - s + 1)bp]").tag(f.id)
                                                            }
                                                        }
                                                        .labelsHidden()
                                                        .frame(maxWidth: 240)
                                                    }
                                                    TextField(L10n.t("起"), text: Binding(
                                                        get: { vm.fragmentStartTexts[idx] ?? "1" },
                                                        set: { vm.fragmentStartTexts[idx] = $0 }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    .frame(width: 55)
                                                    Text("~")
                                                    TextField(L10n.t("止"), text: Binding(
                                                        get: { vm.fragmentEndTexts[idx] ?? "1" },
                                                        set: { vm.fragmentEndTexts[idx] = $0 }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    .frame(width: 55)
                                                    StudioCompactPillButton(title: "截取", icon: "scissors") {
                                                        vm.extractFragmentFromCoordinates(at: idx)
                                                    }
                                                    StudioCompactPillButton(
                                                        title: "预览",
                                                        icon: "eye.fill",
                                                        tint: .green,
                                                        isProminent: true,
                                                        help: "预览供体原图谱"
                                                    ) {
                                                        PlasmidWindowPresenter.shared.openPreviewWindow(
                                                            for: donorInfo,
                                                            roleLabel: L10n.tr("片段\(idx + 1)原始供体质粒预览", "Fragment \(idx + 1) Source Donor Preview"),
                                                            highlightRange: nil
                                                        )
                                                    }
                                                    Spacer()
                                                }
                                                
                                                VStack(alignment: .leading, spacing: 6) {
                                                    HStack(spacing: 6) {
                                                        Text(L10n.tr("供体: \(donorInfo.fileName)", "Donor: \(donorInfo.fileName)"))
                                                            .font(.system(size: 11, weight: .semibold))
                                                            .foregroundColor(.green)
                                                            .lineLimit(1)
                                                            .truncationMode(.middle)
                                                        if !donorFeats.isEmpty {
                                                            Picker("", selection: Binding(
                                                                get: { vm.fragmentSelectedFeatureIDs[idx] ?? "" },
                                                                set: { fid in vm.selectFragmentFeature(at: idx, featureID: fid) }
                                                            )) {
                                                                ForEach(donorFeats) { f in
                                                                    let s = f.segments.first?.start ?? 1
                                                                    let e = f.segments.last?.end ?? 1
                                                                    Text("\(f.name) [\(s)..\(e), \(e - s + 1)bp]").tag(f.id)
                                                                }
                                                            }
                                                            .labelsHidden()
                                                            .frame(maxWidth: .infinity)
                                                        }
                                                    }
                                                    HStack(spacing: 6) {
                                                        Text(L10n.t("起止坐标:"))
                                                            .font(.system(size: 11))
                                                            .foregroundColor(.secondary)
                                                        TextField(L10n.t("起"), text: Binding(
                                                            get: { vm.fragmentStartTexts[idx] ?? "1" },
                                                            set: { vm.fragmentStartTexts[idx] = $0 }
                                                        ))
                                                        .textFieldStyle(.roundedBorder)
                                                        .frame(width: 55)
                                                        Text("~")
                                                        TextField(L10n.t("止"), text: Binding(
                                                            get: { vm.fragmentEndTexts[idx] ?? "1" },
                                                            set: { vm.fragmentEndTexts[idx] = $0 }
                                                        ))
                                                        .textFieldStyle(.roundedBorder)
                                                        .frame(width: 55)
                                                        StudioCompactPillButton(title: "截取", icon: "scissors") {
                                                            vm.extractFragmentFromCoordinates(at: idx)
                                                        }
                                                    }
                                                }
                                            }
                                            .studioInnerBox(tint: .green, paddingH: 8, paddingV: 6)
                                        }
                                        
                                        SequenceEditorBox(text: $vm.fragments[idx], placeholder: L10n.tr("第 \(idx + 1) 个片段序列 (≥ 50 bp)...", "Fragment #\(idx + 1) sequence (>= 50 bp)..."), minHeight: 55)
                                        
                                        fragmentExtraBasesRow(at: idx)
                                    }
                                    .studioInnerBox(paddingH: 10, paddingV: 8)
                                }
                                
                                multiTotalReadingFrameBar
                            }
                        }
                        
                        // 4. 居左紧凑主操作栏（Plan A）
                        StudioActionBar {
                            StudioPrimaryActionButton(
                                title: "设计多片段引物",
                                icon: "sparkles",
                                tint: .green,
                                isLoading: vm.isDesigning
                            ) {
                                Task { await vm.design() }
                            }
                            
                            if vm.vectorDNAInfo != nil && !vm.primers.isEmpty {
                                StudioActionPillButton(
                                    title: "导出重组质粒 .dna",
                                    icon: "bolt.fill",
                                    tint: .purple
                                ) {
                                    Task { await vm.generateRecombinantDNAAndOpen() }
                                }
                            }
                            
                            if !vm.primers.isEmpty {
                                StudioActionPillButton(
                                    title: "加入引物池",
                                    icon: "cart.badge.plus",
                                    tint: .teal,
                                    action: vm.addAllToCart
                                )
                            }
                        }
                        
                        if !vm.primers.isEmpty {
                            StudioCard(title: "生成的引物结果") {
                                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                    StudioMetricBadge(label: L10n.t("数量"), value: L10n.tr("\(vm.primers.count) 条", "\(vm.primers.count)"), color: .green)
                                    StudioSectionClearButton(label: L10n.t("一键清除引物"), action: vm.clearPrimersSection)
                                }
                            } content: {
                                VStack(spacing: 10) {
                                    ForEach(0..<(vm.primers.count / 2), id: \.self) { pairIdx in
                                        let fIndex = pairIdx * 2
                                        if fIndex + 1 < vm.primers.count {
                                            PrimerPairQuickRenameBar(
                                                pairLabel: L10n.tr("片段 \(pairIdx + 1) 引物对", "Fragment \(pairIdx + 1) Primer Pair"),
                                                currentPrefix: PrimerItem.extractPairPrefix(from: vm.primers[fIndex].name),
                                                suggestedPrefix: "Multi-Frag\(pairIdx + 1)"
                                            ) { prefix in
                                                vm.renamePrimerPair(pairIndex: pairIdx, prefix: prefix)
                                            }
                                            PrimerPairDimerSummaryBar(
                                                forwardPrimer: vm.primers[fIndex],
                                                reversePrimer: vm.primers[fIndex + 1]
                                            )
                                        }
                                    }
                                    ForEach(Array(vm.primers.enumerated()), id: \.element.id) { idx, primer in
                                        let partnerIdx = (idx % 2 == 0) ? (idx + 1) : (idx - 1)
                                        let partner = (partnerIdx >= 0 && partnerIdx < vm.primers.count) ? vm.primers[partnerIdx] : nil
                                        PrimerCardView(
                                            primer: primer,
                                            partnerPrimer: partner,
                                            onPairedRename: { prefix in
                                                vm.renamePrimerPair(pairIndex: idx / 2, prefix: prefix)
                                            },
                                            onSingleRename: { newName in
                                                vm.renameSinglePrimer(at: idx, newName: newName)
                                            }
                                        )
                                    }
                                }
                            }
                        }

                        // 6. 多片段同源重组扩增凝胶电泳片段模拟
                        HomologousPCRGelSectionCard(
                            title: "多片段同源重组 PCR 凝胶电泳模拟",
                            accentTint: .green,
                            compareLaneTitle: "显示组装体系混合对照",
                            buildSimulation: multiGelSimulation
                        )
                    }
                    }
                } right: {
                    if let pData = previewData {
                        PlasmidPreviewPanel(data: pData, onClose: {
                            appState.showPlasmidPreview = false
                        })
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(vm.alertMessage ?? "")
        }
    }
    
    // MARK: - 多片段各接头附加碱基（参考图2：清晰输入框 + 连体分段胶囊按钮组）
    @ViewBuilder
    private func fragmentExtraBasesRow(at idx: Int) -> some View {
        let cleanFrag = BioSequence.clean(vm.fragments[idx])
        let ex5 = BioSequence.clean(vm.fragmentExtra5Bases[idx] ?? "")
        let isLast = (idx == vm.fragments.count - 1)
        let ex3 = isLast ? BioSequence.clean(vm.terminalExtra3Bases) : ""
        let effCount = ex5.count + cleanFrag.count + ex3.count
        let rem = effCount % 3
        let padNeeded = rem == 0 ? 0 : (3 - rem)
        let padSeq = padNeeded == 1 ? "G" : (padNeeded == 2 ? "GC" : "")
        
        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
            HStack(spacing: 6) {
                Text(L10n.t("5' 附加:"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize()
                TextField(L10n.t("正向 5'→3'"), text: Binding(
                    get: { vm.fragmentExtra5Bases[idx] ?? "" },
                    set: { vm.fragmentExtra5Bases[idx] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
                .frame(width: 135)
            }
            
            if isLast {
                HStack(spacing: 6) {
                    Text(L10n.t("3' 附加:"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .fixedSize()
                    TextField(L10n.t("正向 5'→3'"), text: $vm.terminalExtra3Bases)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                        .frame(width: 125)
                }
            }
            
            if effCount > 0 {
                StudioMetricBadge(
                    label: "",
                    value: rem == 0 ? L10n.tr("3n (\(effCount / 3) aa)", "3n (\(effCount / 3) aa)") : L10n.tr("余 \(rem) bp", "Rem \(rem) bp"),
                    color: rem == 0 ? .green : .orange
                )
            }
            
            StudioSegmentedPillGroup(items: {
                var items: [StudioPillGroupItem] = []
                if effCount > 0 && rem != 0 {
                    items.append(
                        StudioPillGroupItem(title: L10n.tr("补 +\(padSeq)", "Pad +\(padSeq)"), tint: .orange) {
                            vm.fragmentExtra5Bases[idx] = ex5 + padSeq
                        }
                    )
                }
                items.append(
                    StudioPillGroupItem(title: "+GGGGS") {
                        vm.fragmentExtra5Bases[idx] = StandardLinkerPreset.ggggs15Bp
                    }
                )
                items.append(
                    StudioPillGroupItem(title: "+GS") {
                        vm.fragmentExtra5Bases[idx] = StandardLinkerPreset.gs6Bp
                    }
                )
                if !(vm.fragmentExtra5Bases[idx] ?? "").isEmpty || (isLast && !vm.terminalExtra3Bases.isEmpty) {
                    items.append(
                        StudioPillGroupItem(title: "清空", tint: .red) {
                            vm.fragmentExtra5Bases[idx] = ""
                            if isLast { vm.terminalExtra3Bases = "" }
                        }
                    )
                }
                return items
            }())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    @ViewBuilder
    private var multiTotalReadingFrameBar: some View {
        let totalLen = vm.totalEffectiveInsertLength
        let rem = vm.totalReadingFrameRemainder
        let padSeq = vm.suggestedTotalPaddingBases
        if totalLen > 0 {
            HStack(spacing: 8) {
                StudioMetricBadge(label: L10n.t("拼接总长"), value: "\(totalLen) bp", color: .blue)
                StudioMetricBadge(
                    label: L10n.t("阅读框"),
                    value: rem == 0 ? "3n (\(totalLen / 3) aa)" : L10n.tr("非 3n (余 \(rem) bp)", "Non-3n (rem \(rem) bp)"),
                    color: rem == 0 ? .green : .orange
                )
                Spacer()
                if rem != 0 {
                    StudioCompactPillButton(title: L10n.tr("+5' 补 \(padSeq)", "+5' Pad \(padSeq)"), tint: .orange, isProminent: true) {
                        vm.fragmentExtra5Bases[0] = BioSequence.clean(vm.fragmentExtra5Bases[0] ?? "") + padSeq
                    }
                    StudioCompactPillButton(title: L10n.tr("+3' 补 \(padSeq)", "+3' Pad \(padSeq)")) {
                        vm.terminalExtra3Bases = BioSequence.clean(vm.terminalExtra3Bases) + padSeq
                    }
                }
            }
            .studioInnerBox(tint: rem == 0 ? .green : .orange, paddingH: 10, paddingV: 8)
        }
    }
    
    /// 多片段同源重组载体长度与各插入片段长度实时汇总栏（支持一键送入 DNA 用量计算器）
    private var multiHomologousLengthSummaryBar: some View {
        let vecBp = vm.effectiveVectorBackboneLengthBp
        let rawVecBp = vm.rawVectorLengthBp
        let delBp = vm.deletedVectorBp
        let fragLens = vm.fragmentLengthsBp
        let totalInsBp = vm.totalInsertLengthBp
        
        return StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
            StudioMetricBadge(
                label: L10n.t("载体长度"),
                value: vecBp > 0
                    ? "\(vecBp) bp (\(String(format: "%.2f", Double(vecBp) / 1000.0)) kb)" + (delBp > 0 && rawVecBp > vecBp ? L10n.tr(" · 切除 \(delBp)bp", " · Δ\(delBp) bp") : "")
                    : L10n.t("未载入"),
                color: .blue
            )
            
            StudioMetricBadge(
                label: L10n.tr("插入片段 (\(fragLens.count))", "Inserts (\(fragLens.count))"),
                value: totalInsBp > 0
                    ? "\(fragLens.enumerated().map { "F\($0.offset + 1):\($0.element)bp" }.joined(separator: "+")) = \(totalInsBp) bp (\(String(format: "%.2f", Double(totalInsBp) / 1000.0)) kb)"
                    : L10n.t("未输入"),
                color: .green
            )
            
            StudioActionPillButton(
                title: "算用量",
                icon: "function",
                tint: .purple,
                isProminent: true,
                help: "将多片段与载体长度送入重组用量计算"
            ) {
                vm.sendLengthsToCalculator(navigate: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.purple.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.purple.opacity(0.18), lineWidth: 1)
                )
        )
    }
    
    private func loadSampleMultiFragments() {
        vm.vectorSeq = "TATAGGGAGACCCAAGCTTGGTACCGAGCTCGGATCCACTAGTAACGGCCGCCAGTGTGCTGGAATTCCTGCAGATATCCAGCACAGTGGCGGCCGCTCGAG"
        vm.fragments = [
            "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAG",
            "GAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA"
        ]
    }
    
    private func selectDNAFile(completion: @escaping (URL) -> Void) {
        FinderFileDropHelper.selectDNAFile(completion: completion)
    }

    private func multiGelSimulation(
        concOverride: AgaroseGelConcentration?,
        ladderOverride: String?,
        includeMixLane: Bool
    ) -> HomologousPCRGelSimulationResult {
        let hasFullVector = vm.vectorDNAInfo != nil || vm.rawVectorLengthBp >= 300
        return HomologousPCRGelSimulator.simulateMultiFragment(
            effectiveVectorBackboneLengthBp: hasFullVector ? vm.effectiveVectorBackboneLengthBp : 0,
            deletedVectorBp: hasFullVector ? vm.deletedVectorBp : 0,
            rawVectorLengthBp: hasFullVector ? vm.rawVectorLengthBp : 0,
            fragments: vm.fragments,
            fragmentExtra5Bases: vm.fragmentExtra5Bases,
            terminalExtra3Bases: vm.terminalExtra3Bases,
            homologyLength: vm.homologyLength,
            primers: vm.primers,
            omittedShortVectorBp: hasFullVector ? 0 : vm.effectiveVectorBackboneLengthBp,
            concentrationOverride: concOverride,
            ladderIDOverride: ladderOverride,
            includeMixControlLane: includeMixLane
        )
    }
}
