import CloneStudioCore
import SwiftUI

/// 单片段无缝克隆引物设计界面 (载入质粒即完整解析：支持按特征、按已有引物对、按载体真实酶切位点、按自定义坐标自由选择)
public struct SingleFragmentCloneView: View {
    @ObservedObject private var vm = WorkspaceSessionManager.shared.singleFragmentVM
    @ObservedObject private var appState = AppState.shared
    
    public init() {}
    
    private var previewData: PlasmidConstructPreviewData? {
        let effInsert = vm.effectiveInsertSeq
        if let vecInfo = vm.vectorDNAInfo {
            if let recomb = PlasmidMapBuilder.forSnapGeneRecombinant(
                vectorInfo: vecInfo,
                insertSeq: effInsert,
                insertName: vm.insertGeneName,
                cutStart: vm.cutStart,
                cutEnd: vm.cutEnd,
                primers: vm.primers
            ) {
                return recomb
            }
            // 单独载入载体（尚未载入供体或输入插入序列）时，直接展示原始载体环图、特征注释与当前切点区间
            let safeEnd = max(vm.cutStart, vm.cutEnd)
            return PlasmidMapBuilder.forRawSnapGeneFile(
                info: vecInfo,
                highlightRange: vm.cutStart...safeEnd
            )
        }
        if let insInfo = vm.insertSourceDNAInfo {
            let safeEnd = max(vm.baseInsertStartBp, vm.baseInsertEndBp)
            return PlasmidMapBuilder.forRawSnapGeneFile(
                info: insInfo,
                highlightRange: vm.baseInsertStartBp...safeEnd
            )
        }
        return PlasmidMapBuilder.forSingleFragment(
            mode: vm.mode,
            vectorSeq: vm.vectorSeq,
            vectorSeqU: vm.vectorSeqU,
            vectorSeqD: vm.vectorSeqD,
            insertSeq: effInsert,
            enzymeSingle: vm.enzymeSingle,
            enzyme5: vm.enzyme5,
            enzyme3: vm.enzyme3,
            primers: vm.primers
        )
    }
    
    public var body: some View {
        StudioPageLayout(title: "单片段无缝克隆") {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                PlasmidPreviewToggle(isOn: $appState.showPlasmidPreview, isAvailable: previewData != nil)
                
                PlasmidFileToolbarGroup(
                    roleTitle: "载体",
                    tint: .blue,
                    info: vm.vectorDNAInfo,
                    onLoadURL: { url in Task { await vm.loadVectorDNA(url: url) } },
                    onPreview: {
                        if let vec = vm.vectorDNAInfo {
                            PlasmidWindowPresenter.shared.openPreviewWindow(for: vec, roleLabel: "原始载体质粒预览", highlightRange: nil)
                        }
                    }
                )
                
                PlasmidFileToolbarGroup(
                    roleTitle: "供体",
                    tint: .green,
                    info: vm.insertSourceDNAInfo,
                    onLoadURL: { url in Task { await vm.loadInsertSourceDNA(url: url) } },
                    onPreview: {
                        if let ins = vm.insertSourceDNAInfo {
                            PlasmidWindowPresenter.shared.openPreviewWindow(for: ins, roleLabel: "原始供体质粒预览", highlightRange: nil)
                        }
                    }
                )
                
                StudioSegmentedPillGroup(items: [
                    StudioPillGroupItem(title: "算用量", icon: "function", tint: .purple, help: "将载体与插入长度送入用量计算") {
                        vm.sendLengthsToCalculator(navigate: true)
                    },
                    StudioPillGroupItem(title: "示例", icon: "sparkles", help: "载入标准单片段重组示例", action: loadSampleData),
                    StudioPillGroupItem(title: "", icon: "trash", tint: .red, help: "清空当前克隆配置", action: vm.clear)
                ])
            }
        } content: {
            AdaptiveTwoColumnWorkspace(hasRight: previewData != nil && appState.showPlasmidPreview) {
                VStack(alignment: .leading, spacing: 12) {
                    // 0. 同源重组载体长度与插入基因长度实时汇总栏（方便一键添加用量计算）
                    homologousLengthSummaryBar
                    
                    // 载体解析与四维克隆位点选择面板 (载入载体 .dna 后立即展示所有解析出的可选项)
                    if let vec = vm.vectorDNAInfo {
                        vectorTargetSelectorCard(vec: vec)
                    }
                    
                    // 1. 线性化方式与载体配置
                    StudioCard(title: "载体线性化方式与侧翼同源序列") {
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            if vm.effectiveVectorBackboneLengthBp > 0 {
                                StudioMetricBadge(
                                    label: "载体长度",
                                    value: "\(vm.effectiveVectorBackboneLengthBp) bp (\(String(format: "%.2f", Double(vm.effectiveVectorBackboneLengthBp) / 1000.0)) kb)",
                                    color: .blue
                                )
                            }
                            StudioSegmentedPicker(
                                selection: $vm.mode,
                                options: [
                                    StudioSegmentedOption(value: .pcr, title: "反向 PCR 载体", tint: .purple),
                                    StudioSegmentedOption(value: .single, title: "单酶切", tint: .teal),
                                    StudioSegmentedOption(value: .double, title: "双酶切", tint: .blue)
                                ]
                            )
                            StudioSectionClearButton(label: "一键清除载体", action: vm.clearVectorSection)
                        }
                    } content: {
                            switch vm.mode {
                            case .pcr:
                                pcrForm
                            case .single:
                                singleEnzymeForm
                            case .double:
                                doubleEnzymeForm
                            }
                        }
                        
                        // 2. 重组同源臂长度选择
                        StudioCard(title: "重组同源臂长度") {
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                ForEach([15, 18, 20, 25], id: \.self) { len in
                                    Button(action: {
                                        vm.homologyLength = len
                                    }) {
                                        Text("\(len) bp")
                                            .font(.system(size: 11.5, weight: vm.homologyLength == len ? .bold : .medium))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(vm.homologyLength == len ? Color.accentColor : Color.primary.opacity(0.06))
                                            .foregroundColor(vm.homologyLength == len ? .white : .primary)
                                            .cornerRadius(5)
                                    }
                                    .buttonStyle(.plain)
                                }
                                StudioSectionClearButton(label: "一键重置") {
                                    vm.homologyLength = 20
                                }
                            }
                        } content: {
                            HStack {
                                Text("当前同源臂: \(vm.homologyLength) bp")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("目标 Tm: \(String(format: "%.1f", appState.cloningTargetTm)) ± \(String(format: "%.1f", appState.tmTolerance)) ℃")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // 供体解析与三维片段提取面板 (载入供体 .dna 后立即展示所有解析出的可选项)
                        let cleanInsertLen = BioSequence.clean(vm.insertSeq).count
                        if let ins = vm.insertSourceDNAInfo {
                            donorInsertSelectorCard(ins: ins, cleanInsertLen: cleanInsertLen)
                        }
                        
                        // 3. 插入片段序列
                        StudioCard(title: "插入片段序列 (5' → 3')") {
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                TextField("片段名称", text: $vm.insertGeneName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                                    .frame(width: 120)
                                StudioMetricBadge(
                                    label: "插入基因长度",
                                    value: "\(cleanInsertLen) bp (\(String(format: "%.2f", Double(cleanInsertLen) / 1000.0)) kb)",
                                    color: cleanInsertLen >= 50 ? .green : .orange
                                )
                                if cleanInsertLen > 0 {
                                    StudioMetricBadge(
                                        label: "GC",
                                        value: "\(String(format: "%.0f", BioSequence.gcContent(vm.insertSeq)))%",
                                        color: .purple
                                    )
                                }
                                StudioSectionClearButton(label: "一键清除片段", action: vm.clearInsertSection)
                            }
                        } content: {
                            VStack(alignment: .leading, spacing: 8) {
                                SequenceEditorBox(
                                    text: $vm.insertSeq,
                                    placeholder: "输入或拖入插入片段序列 (≥ 50 bp)",
                                    minHeight: 95
                                )
                                extraBasesAndReadingFrameCard
                            }
                        }
                        
                        // 4. 参考图2对称全宽主操作栏
                        VStack(alignment: .leading, spacing: 10) {
                            if vm.mode == .pcr {
                                Toggle("同时生成载体反向 PCR 扩增引物", isOn: $vm.includeVectorPCRPrimers)
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            
                            HStack(spacing: 10) {
                                StudioPrimaryActionButton(
                                    title: "设计单片段引物",
                                    icon: "sparkles",
                                    tint: .teal,
                                    isLoading: vm.isDesigning,
                                    isDisabled: cleanInsertLen < 50,
                                    fillWidth: true
                                ) {
                                    Task { await vm.design() }
                                }
                                
                                if !vm.primers.isEmpty {
                                    StudioPrimaryActionButton(
                                        title: "加入引物池",
                                        icon: "cart.badge.plus",
                                        tint: .green,
                                        fillWidth: true,
                                        action: vm.addAllToCart
                                    )
                                }
                            }
                        }
                        
                        // 5. 生成的引物结果
                        if !vm.primers.isEmpty {
                            StudioCard(title: "生成的引物结果") {
                                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                    StudioMetricBadge(label: "数量", value: "\(vm.primers.count) 条", color: .green)
                                    snapGeneRecombinantButtons
                                    StudioSectionClearButton(label: "一键清除引物", action: vm.clearPrimersSection)
                                }
                            } content: {
                                VStack(spacing: 10) {
                                    if vm.primers.count >= 2 {
                                        PrimerPairQuickRenameBar(
                                            pairLabel: "插入片段引物对",
                                            currentPrefix: PrimerItem.extractPairPrefix(from: vm.primers[0].name),
                                            suggestedPrefix: vm.insertGeneName.trimmingCharacters(in: .whitespacesAndNewlines)
                                        ) { prefix in
                                            vm.renamePrimerPair(pairIndex: 0, prefix: prefix)
                                        }
                                        PrimerPairDimerSummaryBar(
                                            forwardPrimer: vm.primers[0],
                                            reversePrimer: vm.primers[1]
                                        )
                                    }
                                    if vm.primers.count >= 4 {
                                        PrimerPairQuickRenameBar(
                                            pairLabel: "载体反向PCR引物对",
                                            currentPrefix: PrimerItem.extractPairPrefix(from: vm.primers[2].name),
                                            suggestedPrefix: "Vector-PCR"
                                        ) { prefix in
                                            vm.renamePrimerPair(pairIndex: 1, prefix: prefix)
                                        }
                                        PrimerPairDimerSummaryBar(
                                            forwardPrimer: vm.primers[2],
                                            reversePrimer: vm.primers[3]
                                        )
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
        .alert("提示", isPresented: $vm.showAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.alertMessage ?? "")
        }
        .onAppear {
            if let chained = AppState.shared.pendingChainedNode {
                let seq = BioSequence.clean(chained.productSequence)
                if seq.count >= 60 {
                    vm.vectorSeq = seq
                    vm.vectorSeqU = String(seq.prefix(36))
                    vm.vectorSeqD = String(seq.suffix(36))
                    vm.primers = []
                }
                AppState.shared.pendingChainedNode = nil
            }
        }
    }
    
    // MARK: - 5'/3' 接头附加碱基（Linker/补码）与阅读框 (3n) 移码自动检测面板
    @ViewBuilder
    private var extraBasesAndReadingFrameCard: some View {
        let effLen = vm.effectiveInsertSeq.count
        let rem = vm.readingFrameRemainder
        let needPad = vm.neededPaddingBasesCount
        let padSeq = vm.suggestedPaddingBases
        let ex5Len = BioSequence.clean(vm.extra5Bases).count
        let ex3Len = BioSequence.clean(vm.extra3Bases).count
        
        VStack(alignment: .leading, spacing: 10) {
            // 第一行：标题 + 阅读框状态徽章 + 清空按钮
            HStack(spacing: 8) {
                Image(systemName: rem == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(rem == 0 ? .green : .orange)
                    .font(.system(size: 13))
                Text("接头附加碱基 & 阅读框")
                    .font(.system(size: 13, weight: .bold))
                
                if effLen > 0 {
                    StudioMetricBadge(
                        label: "",
                        value: rem == 0 ? "3n 对齐 (\(effLen / 3) aa)" : "余 \(rem) bp (差 \(needPad) bp)",
                        color: rem == 0 ? .green : .orange
                    )
                }
                
                Spacer()
                
                if ex5Len > 0 || ex3Len > 0 {
                    StudioSectionClearButton(label: "清除", action: vm.clearExtraBasesSection)
                }
            }
            
            // 第二行：采用声明式 StudioFlowLayout 自动换行展示连体分段胶囊快捷按钮组
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                if effLen > 0 && rem != 0 {
                    StudioSegmentedPillGroup(items: [
                        StudioPillGroupItem(title: "5' 补 +\(padSeq)", tint: .orange) {
                            vm.extra5Bases = BioSequence.clean(vm.extra5Bases) + padSeq
                        },
                        StudioPillGroupItem(title: "3' 补 +\(padSeq)", tint: .orange) {
                            vm.extra3Bases = BioSequence.clean(vm.extra3Bases) + padSeq
                        }
                    ])
                }
                
                StudioSegmentedPillGroup(items: [
                    StudioPillGroupItem(title: "5' GGGGS") { vm.extra5Bases = StandardLinkerPreset.ggggs15Bp },
                    StudioPillGroupItem(title: "3' GGGGS") { vm.extra3Bases = StandardLinkerPreset.ggggs15Bp }
                ])
                
                StudioSegmentedPillGroup(items: [
                    StudioPillGroupItem(title: "5' GS") { vm.extra5Bases = StandardLinkerPreset.gs6Bp },
                    StudioPillGroupItem(title: "3' GS") { vm.extra3Bases = StandardLinkerPreset.gs6Bp },
                    StudioPillGroupItem(title: "5' Kozak") { vm.extra5Bases = StandardLinkerPreset.kozak6Bp }
                ])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // 第三行：5' 与 3' 附加碱基输入框（自适应双列/单列切换）
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("5' 附加:")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize()
                        TextField("正向 5'→3'", text: $vm.extra5Bases)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(minWidth: 110)
                        if ex5Len > 0 {
                            Text("+\(ex5Len)bp")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.blue)
                        }
                    }
                    
                    HStack(spacing: 6) {
                        Text("3' 附加:")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize()
                        TextField("正向 5'→3' (R自动反补)", text: $vm.extra3Bases)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(minWidth: 110)
                        if ex3Len > 0 {
                            Text("+\(ex3Len)bp")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.purple)
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("5' 附加:")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 56, alignment: .leading)
                        TextField("正向 5'→3'", text: $vm.extra5Bases)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                        if ex5Len > 0 {
                            Text("+\(ex5Len)bp")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.blue)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("3' 附加:")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 56, alignment: .leading)
                        TextField("正向 5'→3' (R自动反补)", text: $vm.extra3Bases)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                        if ex3Len > 0 {
                            Text("+\(ex3Len)bp")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.purple)
                        }
                    }
                }
            }
            
            if let stopWarn = vm.junctionInFrameStopCodonWarning {
                Text(stopWarn)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill((effLen > 0 && rem != 0) ? Color.orange.opacity(0.08) : Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke((effLen > 0 && rem != 0) ? Color.orange.opacity(0.32) : Color.primary.opacity(0.08), lineWidth: 0.9)
                )
        )
    }
    
    // MARK: - 载体解析与四维目标位点选择卡片
    private func vectorTargetSelectorCard(vec: SnapGeneFileInfo) -> some View {
        let uniqueCutCount = vm.availableVectorCutSites.filter { $0.isUnique }.count
        let boundPrimerCount = vm.vectorBoundPrimers.count
        let delLen = max(0, vm.cutEnd - vm.cutStart + 1)
        
        return VStack(alignment: .leading, spacing: 9) {
            // 顶部解析概览栏 (ViewThatFits 杜绝截断与挤压)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundColor(.blue)
                    Text("已解析载体: \(vec.fileName)")
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("(\(vec.length) bp · \(vec.featuresCount) 特征 · \(boundPrimerCount) 引物 · \(uniqueCutCount) 唯一切点)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    targetRangeBadge(delLen: delLen)
                    closeVectorButton
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundColor(.blue)
                        Text("已解析载体: \(vec.fileName)")
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("(\(vec.length) bp · \(vec.featuresCount) 特征)")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        closeVectorButton
                    }
                    targetRangeBadge(delLen: delLen)
                }
            }
            
            // 四种载体定位方式切换 (自适应长短标题与自动折行)
            ViewThatFits(in: .horizontal) {
                StudioSegmentedPicker(
                    selection: $vm.vectorTargetSource,
                    options: SingleFragmentViewModel.VectorTargetSource.allCases.map {
                        StudioSegmentedOption(value: $0, title: $0.rawValue, tint: .blue)
                    }
                )
                StudioSegmentedPicker(
                    selection: $vm.vectorTargetSource,
                    options: SingleFragmentViewModel.VectorTargetSource.allCases.map {
                        StudioSegmentedOption(value: $0, title: $0.shortTitle, tint: .blue)
                    }
                )
            }
            
            // 根据用户所选的定位方式展示对应解析选项
            switch vm.vectorTargetSource {
            case .byFeature:
                VStack(alignment: .leading, spacing: 6) {
                    featureFilterBar(selection: $vm.vectorFeatureFilter)
                    
                    let vecFeats = vm.sortedVectorFeatures
                    if !vecFeats.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text("选择载体特征:")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .fixedSize()
                                vectorFeaturePicker(vecFeats: vecFeats)
                                    .frame(maxWidth: 340)
                                vectorActionPicker
                                    .frame(minWidth: 165, maxWidth: 200)
                                Spacer()
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text("选择载体特征:")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .fixedSize()
                                    vectorFeaturePicker(vecFeats: vecFeats)
                                        .frame(maxWidth: .infinity)
                                }
                                HStack(spacing: 6) {
                                    Text("操作方式:")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .fixedSize()
                                    vectorActionPicker
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button("按酶切位点") { vm.vectorTargetSource = .byCutSites }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("按自定义坐标") { vm.vectorTargetSource = .byCoordinates }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                
            case .byPrimers:
                let bps = vm.vectorBoundPrimers
                if bps.count >= 2 {
                    VStack(alignment: .leading, spacing: 6) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text("上游反向引物 (←):")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                vectorRevPrimerPicker(bps: bps)
                                    .frame(maxWidth: 240)
                                
                                Text("下游正向引物 (→):")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                vectorFwdPrimerPicker(bps: bps)
                                    .frame(maxWidth: 240)
                                
                                Button("定位区域") {
                                    vm.applyVectorPrimerPair()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text("上游反向 (←):")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                        .fixedSize()
                                    vectorRevPrimerPicker(bps: bps)
                                        .frame(maxWidth: .infinity)
                                }
                                HStack(spacing: 6) {
                                    Text("下游正向 (→):")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                        .fixedSize()
                                    vectorFwdPrimerPicker(bps: bps)
                                        .frame(maxWidth: .infinity)
                                    Button("定位区域") {
                                        vm.applyVectorPrimerPair()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("按特征定位") { vm.vectorTargetSource = .byFeature }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("按酶切位点") { vm.vectorTargetSource = .byCutSites }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                
            case .byCutSites:
                let cuts = vm.displayedVectorCutSites
                VStack(alignment: .leading, spacing: 6) {
                    StudioFlowLayout(horizontalSpacing: 10, verticalSpacing: 6) {
                        Toggle("仅显示唯一内切酶 (1 切点)", isOn: $vm.onlyShowUniqueVectorCutters)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11.5))
                        
                        StudioSegmentedPicker(
                            selection: $vm.mode,
                            options: [
                                StudioSegmentedOption(value: .single, title: "单酶切线性化", tint: .teal),
                                StudioSegmentedOption(value: .double, title: "双酶切线性化", tint: .blue)
                            ]
                        )
                    }
                    
                    if !cuts.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text(vm.mode == .double ? "5' 酶切位点:" : "选择载体酶切位点:")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .fixedSize()
                                vectorCut5Picker(cuts: cuts)
                                    .frame(maxWidth: 280)
                                
                                if vm.mode == .double {
                                    Text("3' 酶切位点:")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .fixedSize()
                                    vectorCut3Picker(cuts: cuts)
                                        .frame(maxWidth: 280)
                                }
                                Spacer()
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(vm.mode == .double ? "5' 酶切位点:" : "选择位点:")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .fixedSize()
                                    vectorCut5Picker(cuts: cuts)
                                        .frame(maxWidth: .infinity)
                                }
                                if vm.mode == .double {
                                    HStack(spacing: 6) {
                                        Text("3' 酶切位点:")
                                            .font(.system(size: 11.5, weight: .medium))
                                            .fixedSize()
                                        vectorCut3Picker(cuts: cuts)
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    } else {
                        Text("未在载体中扫描到符合条件的内切酶位点。")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
            case .byCoordinates:
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("载体目标起止坐标 (1-based):")
                            .font(.system(size: 11.5, weight: .medium))
                            .fixedSize()
                        TextField("起点", text: $vm.cutStartText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 78)
                        Text("~").foregroundColor(.secondary)
                        TextField("终点", text: $vm.cutEndText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 78)
                        Button("应用坐标") {
                            let s = Int(vm.cutStartText.trimmingCharacters(in: .whitespaces)) ?? 1
                            let e = Int(vm.cutEndText.trimmingCharacters(in: .whitespaces)) ?? s
                            vm.applyVectorTargetRange(start: s, end: e)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Text("(终点 = 起点 - 1 为纯插入)")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("目标坐标 (1-based):")
                                .font(.system(size: 11.5, weight: .medium))
                                .fixedSize()
                            TextField("起点", text: $vm.cutStartText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                                .frame(width: 68)
                            Text("~").foregroundColor(.secondary)
                            TextField("终点", text: $vm.cutEndText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11.5, design: .monospaced))
                                .frame(width: 68)
                            Button("应用坐标") {
                                let s = Int(vm.cutStartText.trimmingCharacters(in: .whitespaces)) ?? 1
                                let e = Int(vm.cutEndText.trimmingCharacters(in: .whitespaces)) ?? s
                                vm.applyVectorTargetRange(start: s, end: e)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        Text("(提示：若终点 = 起点 - 1 则为纯插入不删碱基)")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.07))
        .cornerRadius(8)
    }
    
    // MARK: - 供体质粒解析与三维片段提取卡片
    private func donorInsertSelectorCard(ins: SnapGeneFileInfo, cleanInsertLen: Int) -> some View {
        let boundPrimerCount = vm.donorBoundPrimers.count
        
        return VStack(alignment: .leading, spacing: 9) {
            // 顶部解析概览栏 (ViewThatFits 杜绝截断与挤压)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.pull")
                        .foregroundColor(.green)
                    Text("已解析供体: \(ins.fileName)")
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("(\(ins.length) bp · \(ins.featuresCount) 特征 · \(boundPrimerCount) 引物)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    donorExtractionBadge(cleanInsertLen: cleanInsertLen)
                    closeDonorButton
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.pull")
                            .foregroundColor(.green)
                        Text("已解析供体: \(ins.fileName)")
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("(\(ins.length) bp · \(ins.featuresCount) 特征)")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer()
                        closeDonorButton
                    }
                    donorExtractionBadge(cleanInsertLen: cleanInsertLen)
                }
            }
            
            // 三种供体提取方式切换 (自适应长短标题与自动折行)
            ViewThatFits(in: .horizontal) {
                StudioSegmentedPicker(
                    selection: $vm.donorExtractSource,
                    options: SingleFragmentViewModel.DonorExtractSource.allCases.map {
                        StudioSegmentedOption(value: $0, title: $0.rawValue, tint: .green)
                    }
                )
                StudioSegmentedPicker(
                    selection: $vm.donorExtractSource,
                    options: SingleFragmentViewModel.DonorExtractSource.allCases.map {
                        StudioSegmentedOption(value: $0, title: $0.shortTitle, tint: .green)
                    }
                )
            }
            
            switch vm.donorExtractSource {
            case .byFeature:
                VStack(alignment: .leading, spacing: 6) {
                    featureFilterBar(selection: $vm.donorFeatureFilter)
                    
                    let insFeats = vm.sortedInsertFeatures
                    if !insFeats.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text("主特征 (起点):")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .fixedSize()
                                donorMainFeaturePicker(insFeats: insFeats)
                                    .frame(maxWidth: 290)
                                
                                Text("合并至:")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                donorMergeFeaturePicker(insFeats: insFeats)
                                    .frame(maxWidth: 230)
                                Spacer()
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text("主特征 (起点):")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .fixedSize()
                                    donorMainFeaturePicker(insFeats: insFeats)
                                        .frame(maxWidth: .infinity)
                                }
                                HStack(spacing: 6) {
                                    Text("合并相邻 (可选):")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                        .fixedSize()
                                    donorMergeFeaturePicker(insFeats: insFeats)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
                
            case .byPrimers:
                let bps = vm.donorBoundPrimers
                if bps.count >= 2 {
                    VStack(alignment: .leading, spacing: 6) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                Text("正向引物 (5'):")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                donorFwdPrimerPicker(bps: bps)
                                    .frame(maxWidth: 240)
                                
                                Text("反向引物 (3'):")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                donorRevPrimerPicker(bps: bps)
                                    .frame(maxWidth: 240)
                                
                                Button("提取区间") {
                                    vm.applyDonorPrimerPair()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .controlSize(.small)
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text("正向引物 (5'):")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                        .fixedSize()
                                    donorFwdPrimerPicker(bps: bps)
                                        .frame(maxWidth: .infinity)
                                }
                                HStack(spacing: 6) {
                                    Text("反向引物 (3'):")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                        .fixedSize()
                                    donorRevPrimerPicker(bps: bps)
                                        .frame(maxWidth: .infinity)
                                    Button("提取区间") {
                                        vm.applyDonorPrimerPair()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("按特征提取") { vm.donorExtractSource = .byFeature }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("按坐标提取") { vm.donorExtractSource = .byCoordinates }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                
            case .byCoordinates:
                EmptyView()
            }
            
            // 底部常驻坐标微调与自动终止子解析栏（自动识别 3' 端是否含 TAA/TAG/TGA，支持一键去除与无损恢复，绝不重复误删序列）
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("提取坐标 (bp):")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize()
                    TextField("起点", text: $vm.insertStartText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 68)
                    Text("~").foregroundColor(.secondary)
                    TextField("终点", text: $vm.insertEndText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 68)
                    
                    Button("按坐标截取") {
                        vm.extractInsertFromDonorCoordinates()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    stopCodonSmartButton
                    
                    if !vm.terminalCodonStatusText.isEmpty {
                        Text(vm.terminalCodonStatusText)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(vm.detectedTerminalStopCodon != nil ? (vm.removeTerminalStopCodon ? .orange : .blue) : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill((vm.detectedTerminalStopCodon != nil ? Color.blue : Color.secondary).opacity(0.10))
                            )
                    }
                    
                    Toggle("反向互补 (负链)", isOn: Binding(
                        get: { vm.insertUseReverseComplement },
                        set: { val in
                            vm.insertUseReverseComplement = val
                            vm.syncDonorExtractWithStopCodonRule()
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    Spacer()
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("提取坐标 (bp):")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                            .fixedSize()
                        TextField("起点", text: $vm.insertStartText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 65)
                        Text("~").foregroundColor(.secondary)
                        TextField("终点", text: $vm.insertEndText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 65)
                        
                        Button("按坐标截取") {
                            vm.extractInsertFromDonorCoordinates()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    HStack(spacing: 8) {
                        stopCodonSmartButton
                        
                        if !vm.terminalCodonStatusText.isEmpty {
                            Text(vm.terminalCodonStatusText)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(vm.detectedTerminalStopCodon != nil ? (vm.removeTerminalStopCodon ? .orange : .blue) : .secondary)
                        }
                        
                        Toggle("反向互补 (负链)", isOn: Binding(
                            get: { vm.insertUseReverseComplement },
                            set: { val in
                                vm.insertUseReverseComplement = val
                                vm.syncDonorExtractWithStopCodonRule()
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                    }
                }
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.07))
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private var stopCodonSmartButton: some View {
        if let stop = vm.detectedTerminalStopCodon {
            Button(action: {
                vm.toggleTerminalStopCodon()
            }) {
                HStack(spacing: 3) {
                    Image(systemName: vm.removeTerminalStopCodon ? "arrow.uturn.backward.circle.fill" : "scissors")
                    Text(vm.removeTerminalStopCodon ? "恢复终止子 (\(stop))" : "去除终止子 (\(stop))")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.removeTerminalStopCodon ? .orange : .blue)
            .controlSize(.small)
            .help(vm.removeTerminalStopCodon ? "点击恢复已去除的 3' 末端终止密码子 \(stop) (+3 bp)" : "检测到 3' 末端含终止密码子 \(stop)，点击一键去除 (-3 bp)")
        } else {
            Button(action: {}) {
                Text("末端无终止子")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(true)
            .help("当前提取片段 3' 末端非终止密码子 (TAA/TAG/TGA)，无需去除，避免误删编码序列")
        }
    }
    
    // MARK: - 载体与供体子控件抽取 (确保全场景响应式复用)
    private func targetRangeBadge(delLen: Int) -> some View {
        Text(delLen > 0 ? "目标替换区间: \(vm.cutStart)..\(vm.cutEnd) (切除 \(delLen) bp)" : "目标插入位点: @\(vm.cutStart) bp (无缝纯插入)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.14))
            .cornerRadius(4)
    }
    
    private var closeVectorButton: some View {
        HStack(spacing: 5) {
            if let vec = vm.vectorDNAInfo {
                FinderRevealButton(filePath: vec.filePath, label: "")
                Button(action: {
                    PlasmidWindowPresenter.shared.openPreviewWindow(
                        for: vec,
                        roleLabel: "原始载体质粒预览",
                        highlightRange: nil
                    )
                }) {
                    HStack(spacing: 2.5) {
                        Image(systemName: "eye.fill")
                        Text("预览")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.mini)
                .help("弹出一个独立新窗口预览当前原始载体质粒")
            }
            
            StudioSectionClearButton(label: "一键清除载体", action: vm.clearVectorSection)
        }
    }
    
    private func donorExtractionBadge(cleanInsertLen: Int) -> some View {
        Text("\(vm.insertGeneName) [\(vm.insertStartText)..\(vm.insertEndText), \(cleanInsertLen)bp\(vm.insertUseReverseComplement ? " 反补" : "")]")
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundColor(.green)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.14))
            .cornerRadius(4)
    }
    
    private var closeDonorButton: some View {
        HStack(spacing: 5) {
            if let ins = vm.insertSourceDNAInfo {
                FinderRevealButton(filePath: ins.filePath, label: "")
                Button(action: {
                    PlasmidWindowPresenter.shared.openPreviewWindow(
                        for: ins,
                        roleLabel: "原始供体质粒预览",
                        highlightRange: nil
                    )
                }) {
                    HStack(spacing: 2.5) {
                        Image(systemName: "eye.fill")
                        Text("预览")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.mini)
                .help("弹出一个独立新窗口预览当前原始供体质粒")
            }
            
            StudioSectionClearButton(label: "一键清除供体", action: vm.clearInsertSection)
        }
    }
    
    // MARK: - 特征分类选择器 (自适应排版，杜绝文字挤压与重叠)
    private func featureFilterBar(selection: Binding<PlasmidFeatureFilter>) -> some View {
        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
            Text("特征筛选:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            ViewThatFits(in: .horizontal) {
                StudioSegmentedPicker(
                    selection: selection,
                    options: PlasmidFeatureFilter.allCases.map {
                        StudioSegmentedOption(value: $0, title: $0.rawValue, tint: .blue)
                    }
                )
                StudioSegmentedPicker(
                    selection: selection,
                    options: PlasmidFeatureFilter.allCases.map {
                        StudioSegmentedOption(value: $0, title: $0.shortTitle, tint: .blue)
                    }
                )
            }
        }
    }
    
    private func vectorFeaturePicker(vecFeats: [SnapGeneFeature]) -> some View {
        Picker("", selection: Binding(
            get: { vm.selectedVectorFeatureID },
            set: { newID in vm.selectVectorFeature(id: newID) }
        )) {
            ForEach(vecFeats) { f in
                let s = f.segments.first?.start ?? 1
                let e = f.segments.last?.end ?? 1
                let strandTag = f.directionality == "2" ? "← 反义" : "→ 正义"
                Text("\(f.name) [\(s)..\(e), \(e - s + 1) bp \(strandTag)] (\(f.type))").tag(f.id)
            }
        }
        .labelsHidden()
    }
    
    private var vectorActionPicker: some View {
        Picker("", selection: Binding(
            get: { vm.vectorInsertAction },
            set: { act in vm.selectVectorFeature(id: vm.selectedVectorFeatureID, action: act) }
        )) {
            ForEach(SingleFragmentViewModel.VectorInsertAction.allCases) { act in
                Text(act.rawValue).tag(act)
            }
        }
        .labelsHidden()
    }
    
    private func vectorRevPrimerPicker(bps: [SnapGenePrimer]) -> some View {
        Picker("", selection: Binding(
            get: { vm.selectedVectorRevPrimerID },
            set: { id in
                vm.selectedVectorRevPrimerID = id
                vm.applyVectorPrimerPair()
            }
        )) {
            ForEach(bps) { p in
                Text(p.displayLabel).tag(p.id)
            }
        }
        .labelsHidden()
    }
    
    private func vectorFwdPrimerPicker(bps: [SnapGenePrimer]) -> some View {
        Picker("", selection: Binding(
            get: { vm.selectedVectorFwdPrimerID },
            set: { id in
                vm.selectedVectorFwdPrimerID = id
                vm.applyVectorPrimerPair()
            }
        )) {
            ForEach(bps) { p in
                Text(p.displayLabel).tag(p.id)
            }
        }
        .labelsHidden()
    }
    
    private func vectorCut5Picker(cuts: [VectorCutSiteOption]) -> some View {
        Picker("", selection: Binding(
            get: { vm.selectedVectorCutSite5ID },
            set: { id in vm.selectVectorCutSite5(id: id) }
        )) {
            ForEach(cuts) { opt in
                Text(opt.displayTitle).tag(opt.id)
            }
        }
        .labelsHidden()
    }
    
    private func vectorCut3Picker(cuts: [VectorCutSiteOption]) -> some View {
        Picker("", selection: Binding(
            get: { vm.selectedVectorCutSite3ID },
            set: { id in vm.selectVectorCutSite3(id: id) }
        )) {
            ForEach(cuts) { opt in
                Text(opt.displayTitle).tag(opt.id)
            }
        }
        .labelsHidden()
    }
    
    private func donorMainFeaturePicker(insFeats: [SnapGeneFeature]) -> some View {
        Picker("", selection: Binding(
            get: { vm.selectedInsertFeatureID },
            set: { newID in vm.selectInsertFeature(id: newID, mergeEndID: "") }
        )) {
            ForEach(insFeats) { f in
                let s = f.segments.first?.start ?? 1
                let e = f.segments.last?.end ?? 1
                let strandTag = f.directionality == "2" ? "← 反义链" : "→ 正义链"
                Text("\(f.name) [\(s)..\(e), \(e - s + 1) bp \(strandTag)] (\(f.type))").tag(f.id)
            }
        }
        .labelsHidden()
    }
    
    private func donorMergeFeaturePicker(insFeats: [SnapGeneFeature]) -> some View {
        Picker("", selection: Binding(
            get: { vm.selectedInsertMergeEndFeatureID },
            set: { endID in vm.selectInsertFeature(id: vm.selectedInsertFeatureID, mergeEndID: endID) }
        )) {
            Text("不合并 (仅提取主特征)").tag("")
            ForEach(insFeats) { f in
                let s = f.segments.first?.start ?? 1
                let e = f.segments.last?.end ?? 1
                Text("合并至 \(f.name) [\(s)..\(e)]").tag(f.id)
            }
        }
        .labelsHidden()
    }
    
    private func donorFwdPrimerPicker(bps: [SnapGenePrimer]) -> some View {
        Picker("", selection: Binding(
            get: { vm.selectedDonorFwdPrimerID },
            set: { id in
                vm.selectedDonorFwdPrimerID = id
                vm.applyDonorPrimerPair()
            }
        )) {
            ForEach(bps) { p in
                Text(p.displayLabel).tag(p.id)
            }
        }
        .labelsHidden()
    }
    
    private func donorRevPrimerPicker(bps: [SnapGenePrimer]) -> some View {
        Picker("", selection: Binding(
            get: { vm.selectedDonorRevPrimerID },
            set: { id in
                vm.selectedDonorRevPrimerID = id
                vm.applyDonorPrimerPair()
            }
        )) {
            ForEach(bps) { p in
                Text(p.displayLabel).tag(p.id)
            }
        }
        .labelsHidden()
    }
    
    @ViewBuilder
    private var snapGeneRecombinantButtons: some View {
        if let vec = vm.vectorDNAInfo {
            HStack(spacing: 6) {
                Button(action: {
                    Task { await vm.generateRecombinantDNAAndOpen() }
                }) {
                    HStack(spacing: 3) {
                        if vm.isSnapGeneBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text("导出重组 .dna")
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
                .disabled(vm.isSnapGeneBusy)
                .help("生成重组质粒 .dna 文件并在 SnapGene 中打开")
                
                Menu {
                    Button("仅向原载体写入引物 (自动留备份)") {
                        Task { await vm.injectPrimersToVectorDNA() }
                    }
                    Button("在 Finder 中定位载体 .dna") {
                        FinderFileDropHelper.revealInFinder(path: vec.filePath)
                    }
                } label: {
                    Text("更多")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .frame(width: 58)
            }
        } else {
            Button(action: {
                selectDNAFile { url in
                    Task {
                        await vm.loadVectorDNA(url: url)
                        await vm.injectPrimersToVectorDNA()
                    }
                }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                    Text("写入 .dna")
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.small)
            .disabled(vm.isSnapGeneBusy)
            .help("从 Finder 选择 .dna 质粒并将生成的引物写入（自动创建备份）")
        }
    }
    
    private var singleEnzymeForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("酶切位点：").font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                if vm.vectorDNAInfo != nil && !vm.displayedVectorCutSites.isEmpty {
                    Picker("", selection: Binding(
                        get: { vm.selectedVectorCutSite5ID },
                        set: { id in vm.selectVectorCutSite5(id: id) }
                    )) {
                        ForEach(vm.displayedVectorCutSites) { opt in
                            Text(opt.displayTitle).tag(opt.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                } else {
                    Picker("", selection: $vm.enzymeSingle) {
                        ForEach(RestrictionEnzymeDatabase.shared.enzymes) { enzyme in
                            Text("\(enzyme.name) (\(enzyme.site))").tag(Optional(enzyme))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
            SequenceEditorBox(text: $vm.vectorSeq, placeholder: "输入包含所选位点上下游至少各 20 bp 的载体序列...", minHeight: 65)
        }
    }
    
    private var doubleEnzymeForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            if vm.vectorDNAInfo != nil && !vm.displayedVectorCutSites.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Text("5'端位点：").font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                        Picker("", selection: Binding(
                            get: { vm.selectedVectorCutSite5ID },
                            set: { id in vm.selectVectorCutSite5(id: id) }
                        )) {
                            ForEach(vm.displayedVectorCutSites) { opt in
                                Text(opt.displayTitle).tag(opt.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                        
                        Text("3'端位点：").font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                        Picker("", selection: Binding(
                            get: { vm.selectedVectorCutSite3ID },
                            set: { id in vm.selectVectorCutSite3(id: id) }
                        )) {
                            ForEach(vm.displayedVectorCutSites) { opt in
                                Text(opt.displayTitle).tag(opt.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("5'端位点：").font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                            Picker("", selection: Binding(
                                get: { vm.selectedVectorCutSite5ID },
                                set: { id in vm.selectVectorCutSite5(id: id) }
                            )) {
                                ForEach(vm.displayedVectorCutSites) { opt in
                                    Text(opt.displayTitle).tag(opt.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                        HStack(spacing: 6) {
                            Text("3'端位点：").font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                            Picker("", selection: Binding(
                                get: { vm.selectedVectorCutSite3ID },
                                set: { id in vm.selectVectorCutSite3(id: id) }
                            )) {
                                ForEach(vm.displayedVectorCutSites) { opt in
                                    Text(opt.displayTitle).tag(opt.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text("5'端位点：").font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                            Picker("", selection: $vm.enzyme5) {
                                ForEach(RestrictionEnzymeDatabase.shared.enzymes) { enzyme in
                                    Text("\(enzyme.name) (\(enzyme.site))").tag(Optional(enzyme))
                                }
                            }
                            .labelsHidden()
                        }
                        HStack(spacing: 6) {
                            Text("3'端位点：").font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                            Picker("", selection: $vm.enzyme3) {
                                ForEach(RestrictionEnzymeDatabase.shared.enzymes) { enzyme in
                                    Text("\(enzyme.name) (\(enzyme.site))").tag(Optional(enzyme))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("5'端位点：").font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                            Picker("", selection: $vm.enzyme5) {
                                ForEach(RestrictionEnzymeDatabase.shared.enzymes) { enzyme in
                                    Text("\(enzyme.name) (\(enzyme.site))").tag(Optional(enzyme))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                        HStack(spacing: 6) {
                            Text("3'端位点：").font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                            Picker("", selection: $vm.enzyme3) {
                                ForEach(RestrictionEnzymeDatabase.shared.enzymes) { enzyme in
                                    Text("\(enzyme.name) (\(enzyme.site))").tag(Optional(enzyme))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            SequenceEditorBox(text: $vm.vectorSeq, placeholder: "输入包含双酶切位点上下游至少各 20 bp 的载体序列...", minHeight: 65)
        }
    }
    
    private var pcrForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("上游保留载体序列 (紧邻 \(vm.cutStart) bp 左侧，≥20bp)：").font(.system(size: 11.5)).foregroundColor(.secondary)
                Spacer()
                if vm.vectorDNAInfo != nil {
                    Text("已同步自载体 \(max(1, vm.cutStart - 60))..\(max(1, vm.cutStart - 1)) bp")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.blue)
                }
            }
            SequenceEditorBox(text: $vm.vectorSeqU, placeholder: "输入克隆位点 5' 上游保留载体序列...", minHeight: 55)
            HStack {
                Text("下游保留载体序列 (紧邻 \(vm.cutEnd) bp 右侧，≥20bp)：").font(.system(size: 11.5)).foregroundColor(.secondary)
                Spacer()
                if vm.vectorDNAInfo != nil {
                    Text("已同步自载体 \(vm.cutEnd + 1)..\(min(vm.vectorDNAInfo?.length ?? 9999, vm.cutEnd + 60)) bp")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.blue)
                }
            }
            SequenceEditorBox(text: $vm.vectorSeqD, placeholder: "输入克隆位点 3' 下游保留载体序列...", minHeight: 55)
        }
    }
    
    /// 同源重组载体长度与插入基因长度实时汇总栏（支持一键送入 DNA 用量计算器）
    private var homologousLengthSummaryBar: some View {
        let vecBp = vm.effectiveVectorBackboneLengthBp
        let rawVecBp = vm.rawVectorLengthBp
        let delBp = vm.deletedVectorBp
        let insBp = vm.cleanInsertLengthBp
        let pcrBp = vm.pcrAmpliconInsertLengthBp
        
        return StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
            StudioMetricBadge(
                label: "载体长度",
                value: vecBp > 0
                    ? "\(vecBp) bp (\(String(format: "%.2f", Double(vecBp) / 1000.0)) kb)" + (delBp > 0 && rawVecBp > vecBp ? " · 切除 \(delBp)bp" : "")
                    : "未载入",
                color: .blue
            )
            
            StudioMetricBadge(
                label: "插入基因 (\(vm.insertGeneName.isEmpty ? "Insert" : vm.insertGeneName))",
                value: insBp > 0
                    ? "\(insBp) bp (\(String(format: "%.2f", Double(insBp) / 1000.0)) kb)" + (pcrBp > insBp ? " · 扩增子 \(pcrBp)bp" : "")
                    : "未输入",
                color: .green
            )
            
            StudioActionPillButton(
                title: "算用量",
                icon: "function",
                tint: .purple,
                isProminent: true,
                help: "将载体与插入片段长度送入重组用量计算"
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
    
    private func loadSampleData() {
        vm.vectorSeq = "TATAGGGAGACCCAAGCTTGGTACCGAGCTCGGATCCACTAGTAACGGCCGCCAGTGTGCTGGAATTCCTGCAGATATCCAGCACAGTGGCGGCCGCTCGAG"
        vm.vectorSeqU = "TATAGGGAGACCCAAGCTTGGTACCGAGCTC"
        vm.vectorSeqD = "ACTAGTAACGGCCGCCAGTGTGCTGGAATTCCTGCAGATATCCAGCACAGTGGCGGCCGCTCGAG"
        vm.insertSeq = "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTGACCTACGGCGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAGGACGGCAACATCCTGGGGCACAAGCTGGAGTACAACTACAACAGCCACAACGTCTATATCATGGCCGACAAGCAGAAGAACGGCATCAAGGTGAACTTCAAGATCCGCCACAACATCGAGGACGGCAGCGTGCAGCTCGCCGACCACTACCAGCAGAACACCCCCATCGGCGACGGCCCCGTGCTGCTGCCCGACAACCACTACCTGAGCACCCAGTCCGCCCTGAGCAAAGACCCCAACGAGAAGCGCGATCACATGGTCCTGCTGGAGTTCGTGACCGCCGCCGGGATCACTCTCGGCATGGACGAGCTGTACAAGTAA"
    }
    
    private func selectDNAFile(completion: @escaping (URL) -> Void) {
        FinderFileDropHelper.selectDNAFile(completion: completion)
    }
}
