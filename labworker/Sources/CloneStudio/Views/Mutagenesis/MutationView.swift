import CloneStudioCore
import SwiftUI

/// 定点突变引物设计界面 (全响应式布局杜绝截断 + 支持载入 .dna 质粒 + 独立新窗口预览质粒 + 预览内或氨基酸网格点选突变)
public struct MutationView: View {
    @ObservedObject private var vm = WorkspaceSessionManager.shared.mutagenesisVM
    @ObservedObject private var appState = AppState.shared
    
    public init() {}
    
    private var previewData: PlasmidConstructPreviewData? {
        if let mutData = PlasmidMapBuilder.forMutagenesis(
            mutUp: vm.mutUp,
            mutSite: vm.mutSite,
            mutDown: vm.mutDown,
            primers: vm.primers
        ) {
            if let info = vm.plasmidDNAInfo {
                let raw = PlasmidMapBuilder.forRawSnapGeneFile(
                    info: info,
                    highlightRange: vm.mutTargetStartBp...max(vm.mutTargetStartBp, vm.mutTargetEndBp)
                )
                return PlasmidConstructPreviewData(
                    constructTitle: info.fileName.replacingOccurrences(of: ".dna", with: ""),
                    vectorName: "Mutagenesis",
                    totalLengthBp: raw.totalLengthBp,
                    insertLengthBp: BioSequence.clean(vm.mutSite).count,
                    gcPercent: raw.gcPercent,
                    fullSequence: raw.fullSequence,
                    features: raw.features,
                    enzymes: raw.enzymes,
                    primers: mutData.primers.isEmpty ? raw.primers : mutData.primers,
                    junctions: mutData.junctions,
                    linearSummarySteps: raw.linearSummarySteps,
                    microscopicWindows: mutData.microscopicWindows + raw.microscopicWindows
                )
            }
            return mutData
        }
        if let info = vm.plasmidDNAInfo {
            return PlasmidMapBuilder.forRawSnapGeneFile(
                info: info,
                highlightRange: vm.mutTargetStartBp...max(vm.mutTargetStartBp, vm.mutTargetEndBp)
            )
        }
        return nil
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "定点突变",
            toolbar: [
                .plasmidToggle(isOn: $appState.showPlasmidPreview, isAvailable: previewData != nil),
                .plasmidFile(
                    id: "mutation_plasmid_file",
                    roleTitle: "质粒",
                    tint: .pink,
                    info: vm.plasmidDNAInfo,
                    onLoadURL: { url in Task { await vm.loadDNAFile(url: url) } },
                    onPreview: {
                        if let info = vm.plasmidDNAInfo {
                            PlasmidWindowPresenter.shared.openPreviewWindow(
                                for: info,
                                roleLabel: "原始质粒预览",
                                highlightRange: nil,
                                onMutateCodon: { payload in vm.applyInteractiveCodonPayload(payload) }
                            )
                        }
                    }
                ),
                .action(title: "示例", icon: "sparkles", help: "载入定点突变示例", action: loadSampleMutation),
                .action(id: "clear_mutation", title: "", icon: "trash", tint: .red, help: "清空当前突变配置", action: vm.clear)
            ]
        ) {
                
                AdaptiveTwoColumnWorkspace(hasRight: previewData != nil && appState.showPlasmidPreview) {
                    VStack(alignment: .leading, spacing: 12) {
                        // 若已载入质粒 .dna，展示质粒特征与交互式密码子/氨基酸点选突变面板
                        if let info = vm.plasmidDNAInfo {
                            plasmidCodonSelectorCard(info: info)
                        }
                        
                        let upCount = BioSequence.clean(vm.mutUp).count
                        let downCount = BioSequence.clean(vm.mutDown).count
                        let siteCount = BioSequence.clean(vm.mutSite).count
                        
                        // 1. 上游序列
                        StudioCard(title: "5' 上游序列") {
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                if !vm.mutationSummaryLabel.isEmpty {
                                    Text(vm.mutationSummaryLabel)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundColor(.pink)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2.5)
                                        .background(Capsule().fill(Color.pink.opacity(0.12)))
                                }
                                StudioMetricBadge(label: "上游", value: "\(upCount) bp", color: upCount >= 50 ? .green : .orange)
                                StudioSectionClearButton(label: "一键清除", action: vm.clearUpstreamSection)
                            }
                        } content: {
                            SequenceEditorBox(text: $vm.mutUp, placeholder: "5' 上游序列 (≥ 50 bp)", minHeight: 60)
                        }
                        
                        // 2. 目标突变序列
                        StudioCard(title: "突变位点碱基") {
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                StudioMetricBadge(label: "", value: siteCount == 0 ? "缺失 (Δ)" : "\(siteCount) bp", color: .pink)
                                StudioSectionClearButton(label: "一键清除", action: vm.clearMutationSiteSection)
                            }
                        } content: {
                            HStack(spacing: 10) {
                                TextField("目标碱基 (留空为缺失 Δ)", text: $vm.mutSite)
                                    .font(.system(size: 13, weight: .bold))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 220)
                                
                                if siteCount == 3 {
                                    let (aa, three) = CodonTranslator.translateTriplet(vm.mutSite)
                                    StudioMetricBadge(label: "氨基酸", value: "\(three) (\(String(aa)))", color: .pink)
                                }
                                Spacer()
                            }
                        }
                        
                        // 3. 下游序列
                        StudioCard(title: "3' 下游序列") {
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                StudioMetricBadge(label: "下游", value: "\(downCount) bp", color: downCount >= 50 ? .green : .orange)
                                StudioSectionClearButton(label: "一键清除", action: vm.clearDownstreamSection)
                            }
                        } content: {
                            SequenceEditorBox(text: $vm.mutDown, placeholder: "3' 下游序列 (≥ 50 bp)", minHeight: 60)
                        }
                        
                        // 4. 突变重叠同源臂长度
                        StudioCard(title: "重叠同源臂") {
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                StudioSegmentedPicker(
                                    selection: $vm.homologyLength,
                                    options: [15, 18, 20, 25].map {
                                        StudioSegmentedOption(value: $0, title: "\($0) bp", tint: .pink)
                                    }
                                )
                                StudioSectionClearButton(label: "一键重置") {
                                    vm.homologyLength = 20
                                }
                            }
                        } content: {
                            HStack {
                                Text("当前突变重叠臂: \(vm.homologyLength) bp")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("目标 Tm: \(String(format: "%.1f", appState.mutationTargetTm)) ± \(String(format: "%.1f", appState.tmTolerance)) ℃")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // 5. 参考图2对称全宽主操作栏
                        HStack(spacing: 10) {
                            StudioPrimaryActionButton(
                                title: "设计突变引物",
                                icon: "wand.and.stars",
                                tint: .pink,
                                isLoading: vm.isDesigning,
                                isDisabled: upCount < 50 || downCount < 50,
                                fillWidth: true
                            ) {
                                Task { await vm.design() }
                            }
                            
                            if !vm.primers.isEmpty {
                                if vm.plasmidDNAInfo != nil {
                                    StudioPrimaryActionButton(
                                        title: "导出突变质粒 .dna",
                                        icon: "bolt.fill",
                                        tint: .purple,
                                        fillWidth: true
                                    ) {
                                        Task { await vm.generateMutantDNAAndOpen() }
                                    }
                                }
                                
                                StudioPrimaryActionButton(
                                    title: "加入引物池",
                                    icon: "cart.badge.plus",
                                    tint: .green,
                                    fillWidth: true,
                                    action: vm.addAllToCart
                                )
                            }
                        }
                        
                        // 6. 结果展示
                        if !vm.primers.isEmpty {
                            StudioCard(title: "生成的引物结果") {
                                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                    StudioMetricBadge(label: "数量", value: "\(vm.primers.count) 条", color: .green)
                                    injectPrimersButton
                                    StudioSectionClearButton(label: "一键清除引物", action: vm.clearPrimersSection)
                                }
                            } content: {
                                VStack(spacing: 10) {
                                    if vm.primers.count >= 2 {
                                        PrimerPairQuickRenameBar(
                                            pairLabel: "定点突变引物对",
                                            currentPrefix: PrimerItem.extractPairPrefix(from: vm.primers[0].name),
                                            suggestedPrefix: vm.mutationSummaryLabel.isEmpty ? "Mutation" : vm.mutationSummaryLabel
                                        ) { prefix in
                                            vm.renamePrimerPair(pairIndex: 0, prefix: prefix)
                                        }
                                        PrimerPairDimerSummaryBar(
                                            forwardPrimer: vm.primers[0],
                                            reversePrimer: vm.primers[1]
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
                        PlasmidPreviewPanel(
                            data: pData,
                            onClose: {
                                appState.showPlasmidPreview = false
                            },
                            onMutateCodon: { payload in
                                vm.applyInteractiveCodonPayload(payload)
                            }
                        )
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
                if seq.count >= 120 {
                    let mid = seq.count / 2
                    let midIdx = seq.index(seq.startIndex, offsetBy: mid)
                    vm.mutUp = String(seq[..<midIdx])
                    vm.mutDown = String(seq[midIdx...])
                    vm.mutSite = "AAG"
                    vm.primers = []
                }
                AppState.shared.pendingChainedNode = nil
            }
        }
    }
    
    // MARK: - 底部主操作复用按钮
    
    private func designPrimersButton(upCount: Int, downCount: Int) -> some View {
        StudioPrimaryActionButton(
            title: "设计突变引物",
            icon: "wand.and.stars",
            tint: .pink,
            isLoading: vm.isDesigning,
            isDisabled: upCount < 50 || downCount < 50
        ) {
            Task { await vm.design() }
        }
    }
    
    @ViewBuilder
    private var exportSnapGeneButton: some View {
        if vm.plasmidDNAInfo != nil {
            StudioPrimaryActionButton(
                title: "导出突变质粒 .dna",
                icon: "bolt.fill",
                tint: .purple
            ) {
                Task { await vm.generateMutantDNAAndOpen() }
            }
        }
    }
    
    private var addToCartButton: some View {
        StudioPrimaryActionButton(
            title: "加入引物池",
            icon: "cart.badge.plus",
            tint: .green,
            action: vm.addAllToCart
        )
    }
    
    private var injectPrimersButton: some View {
        StudioActionPillButton(
            title: "写入原质粒",
            icon: "arrow.down.doc.fill",
            tint: .orange,
            help: "向原质粒 .dna 写入定点突变引物（自动留备份）"
        ) {
            if let info = vm.plasmidDNAInfo {
                let url = URL(fileURLWithPath: info.filePath)
                Task {
                    do {
                        _ = try await SnapGeneService.shared.injectPrimers(vm.primers, into: url, createBackup: true)
                        AppState.shared.showToast("已成功向原质粒写入定点突变引物（已备份）")
                        SnapGeneService.shared.openInSnapGene(url: url)
                    } catch {
                        AppState.shared.showToast("写入失败: \(error.localizedDescription)")
                    }
                }
            } else {
                selectDNAFile { url in
                    Task {
                        do {
                            _ = try await SnapGeneService.shared.injectPrimers(vm.primers, into: url, createBackup: true)
                            AppState.shared.showToast("已成功向质粒写入定点突变引物（已备份）")
                            SnapGeneService.shared.openInSnapGene(url: url)
                        } catch {
                            AppState.shared.showToast("写入失败: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 载入质粒后的特征选择与交互式密码子/氨基酸点选卡片 (全响应式布局，彻底解决截断与拥挤)
    private func plasmidCodonSelectorCard(info: SnapGeneFileInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. 顶部质粒概览行 (ViewThatFits 自适应单行/双行，文件名中间省略不折行)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundColor(.pink)
                    Text("已载入质粒: \(info.fileName)")
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("(\(info.length) bp · \(info.featuresCount) 个特征)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 4)
                    cardPopoutWindowButton(info: info)
                    closePlasmidCardButton
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundColor(.pink)
                        Text("已载入质粒: \(info.fileName)")
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        closePlasmidCardButton
                    }
                    HStack(spacing: 8) {
                        Text("\(info.length) bp · \(info.featuresCount) 个特征")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        cardPopoutWindowButton(info: info)
                    }
                }
            }
            
            // 2. 选择要翻译并突变的基因/CDS特征 + 阅读框切换 (ViewThatFits 杜绝 Frame +3 被右侧截断)
            let feats = vm.sortedFeatures
            if !feats.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("选择目标基因/特征:")
                            .font(.system(size: 11.5, weight: .medium))
                            .fixedSize()
                        featurePicker(feats: feats)
                            .frame(minWidth: 160, maxWidth: 260)
                        
                        Spacer(minLength: 4)
                        
                        Text("阅读框:")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.secondary)
                            .fixedSize()
                        readingFrameSegmentedBar
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("选择目标基因/特征:")
                                .font(.system(size: 11.5, weight: .medium))
                                .fixedSize()
                            featurePicker(feats: feats)
                                .frame(maxWidth: .infinity)
                        }
                        HStack(spacing: 8) {
                            Text("阅读框切换:")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.secondary)
                                .fixedSize()
                            readingFrameSegmentedBar
                            Spacer()
                        }
                    }
                }
            }
            
            // 3. 氨基酸 / 密码子点选矩阵（支持按位点号搜索如 "42" 或 "K42"，自适应不折行）
            if !vm.translatedResidues.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("待突变氨基酸/密码子 (共 \(vm.translatedResidues.count) aa):")
                            .font(.system(size: 11.5, weight: .semibold))
                            .fixedSize()
                        TextField("搜索位点如 42 / K42 / AAG...", text: $vm.residueSearchText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(width: 175)
                        Spacer(minLength: 4)
                        currentResidueBadge
                    }
                    
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("点击选择待突变的氨基酸/密码子 (共 \(vm.translatedResidues.count) aa):")
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            currentResidueBadge
                        }
                        TextField("搜索位点如 42 / K42 / AAG...", text: $vm.residueSearchText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .frame(maxWidth: 260)
                    }
                }
                
                // 留足内边距与 54pt 高度，避免首尾按钮被裁切以及底部滚动条遮挡密码子文字
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(spacing: 6) {
                            ForEach(vm.filteredResidues) { item in
                                let isSelected = (item.residueIndex1Based == vm.selectedResidueIndex)
                                Button(action: {
                                    vm.selectResidueAndMutate(residueIndex1Based: item.residueIndex1Based)
                                }) {
                                    VStack(spacing: 1.5) {
                                        Text("\(String(item.aminoAcid))\(item.residueIndex1Based)")
                                            .font(.system(size: 10.5, weight: .bold))
                                            .monospacedDigit()
                                        Text(item.codon)
                                            .font(.system(size: 9.0))
                                            .opacity(0.88)
                                    }
                                    .foregroundColor(isSelected ? .white : .primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                            .fill(isSelected ? Color.pink : StudioPalette.controlBg(isLight: appState.isLightAppearance))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                                    .stroke(isSelected ? Color.pink.opacity(0.45) : StudioPalette.controlBorder(isLight: appState.isLightAppearance), lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(item.residueIndex1Based)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                    }
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                            .fill(StudioPalette.controlSubtleBg(isLight: appState.isLightAppearance))
                    )
                    .onChange(of: vm.selectedResidueIndex) { _, newIdx in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
                
                // 4. 选择目标突变氨基酸或密码子 — 采用自适应多行网格 (LazyVGrid)，全量展示 20 种氨基酸 + 终止子 + Δ缺失，彻底告别右侧截断！
                VStack(alignment: .leading, spacing: 5) {
                    Text("突变为目标氨基酸 (点击直接替换):")
                        .font(.system(size: 11.5, weight: .semibold))
                    
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 64, maximum: 82), spacing: 5)],
                        alignment: .leading,
                        spacing: 5
                    ) {
                        ForEach(CodonTranslator.aminoAcidOptions) { opt in
                            let isChosen = (vm.selectedTargetAA == String(opt.singleLetter))
                            Button(action: {
                                vm.selectResidueAndMutate(
                                    residueIndex1Based: vm.selectedResidueIndex,
                                    targetAA: String(opt.singleLetter)
                                )
                            }) {
                                VStack(spacing: 1) {
                                    Text("\(String(opt.singleLetter)) (\(opt.threeLetter))")
                                        .font(.system(size: 10, weight: .bold))
                                        .lineLimit(1)
                                    Text(opt.preferredCodon)
                                        .font(.system(size: 8.5))
                                        .opacity(0.9)
                                }
                                .frame(maxWidth: .infinity)
                                .foregroundColor(isChosen ? .white : .primary)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                        .fill(isChosen ? Color.purple : StudioPalette.controlBg(isLight: appState.isLightAppearance))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                                .stroke(isChosen ? Color.purple.opacity(0.45) : StudioPalette.controlBorder(isLight: appState.isLightAppearance), lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .help("\(opt.chineseName) (\(opt.allCodons.joined(separator: "/")))")
                        }
                        
                        Button(action: {
                            vm.selectResidueAndMutate(
                                residueIndex1Based: vm.selectedResidueIndex,
                                targetAA: "Δ"
                            )
                        }) {
                            VStack(spacing: 1) {
                                Text("Δ 缺失")
                                    .font(.system(size: 10, weight: .bold))
                                    .lineLimit(1)
                                Text("删除3bp")
                                    .font(.system(size: 8.5))
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundColor(vm.selectedTargetAA == "Δ" ? .white : .red)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                    .fill(vm.selectedTargetAA == "Δ" ? Color.red : Color.red.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // 5. 若选中了某个目标氨基酸，展示其所有同义密码子可选项供切换
                if let chosenOpt = CodonTranslator.aminoAcidOptions.first(where: { String($0.singleLetter) == vm.selectedTargetAA }),
                   chosenOpt.allCodons.count > 1 {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text("\(chosenOpt.chineseName) (\(chosenOpt.threeLetter)) 同义密码子切换:")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize()
                            ForEach(chosenOpt.allCodons, id: \.self) { synCodon in
                                synonymousCodonButton(synCodon: synCodon, chosenOpt: chosenOpt)
                            }
                            Spacer()
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(chosenOpt.chineseName) (\(chosenOpt.threeLetter)) 同义密码子切换:")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            HStack(spacing: 6) {
                                ForEach(chosenOpt.allCodons, id: \.self) { synCodon in
                                    synonymousCodonButton(synCodon: synCodon, chosenOpt: chosenOpt)
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .studioInnerBox(tint: .pink, paddingH: 10, paddingV: 10)
    }

    private func cardPopoutWindowButton(info: SnapGeneFileInfo) -> some View {
        HStack(spacing: 5) {
            FinderRevealButton(filePath: info.filePath, label: "")
            StudioActionPillButton(
                title: "选位点",
                icon: "eye.fill",
                tint: .purple,
                isProminent: true,
                help: "打开质粒图谱预览，点选密码子直接定位突变"
            ) {
                PlasmidWindowPresenter.shared.openPreviewWindow(
                    for: info,
                    roleLabel: "原始质粒预览 · 按住拉取密码子可直接突变",
                    highlightRange: vm.mutTargetStartBp...max(vm.mutTargetStartBp, vm.mutTargetEndBp),
                    onMutateCodon: { payload in
                        vm.applyInteractiveCodonPayload(payload)
                    }
                )
            }
        }
    }
    
    private var closePlasmidCardButton: some View {
        StudioSectionClearButton(label: "一键清除质粒", action: vm.clearPlasmidSection)
    }
    
    private func featurePicker(feats: [SnapGeneFeature]) -> some View {
        Picker("", selection: Binding(
            get: { vm.selectedFeatureID },
            set: { id in vm.selectFeatureForTranslation(id: id) }
        )) {
            ForEach(feats) { f in
                let s = f.segments.first?.start ?? 1
                let e = f.segments.last?.end ?? 1
                let dir = f.directionality == "2" ? "← 反义链" : "→ 正义链"
                Text("\(f.name) [\(s)..\(e), \(e - s + 1) bp \(dir)] (\(f.type))").tag(f.id)
            }
        }
        .labelsHidden()
    }
    
    private var readingFrameSegmentedBar: some View {
        StudioSegmentedPicker(
            selection: Binding(
                get: { vm.readingFrameOffset },
                set: { fo in vm.selectFeatureForTranslation(id: vm.selectedFeatureID, frameOffset: fo) }
            ),
            options: [
                StudioSegmentedOption(value: 0, title: "Frame +1 (0)", tint: .blue),
                StudioSegmentedOption(value: 1, title: "Frame +2 (+1)", tint: .blue),
                StudioSegmentedOption(value: 2, title: "Frame +3 (+2)", tint: .blue)
            ]
        )
    }
    
    @ViewBuilder
    private var currentResidueBadge: some View {
        if let cur = vm.currentSelectedResidue {
            Text("当前选中: \(cur.threeLetter)\(cur.residueIndex1Based) (\(cur.codon), @\(cur.plasmidStartBp)..\(cur.plasmidEndBp) bp)")
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
                .foregroundColor(.pink)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.pink.opacity(0.12)))
        }
    }

    private func synonymousCodonButton(synCodon: String, chosenOpt: CodonTranslator.AminoAcidOption) -> some View {
        let isCurrentCodon = (BioSequence.clean(vm.mutSite) == synCodon)
        return StudioCompactPillButton(
            title: synCodon,
            tint: .pink,
            isProminent: isCurrentCodon
        ) {
            vm.selectResidueAndMutate(
                residueIndex1Based: vm.selectedResidueIndex,
                targetAA: String(chosenOpt.singleLetter),
                customCodon: synCodon
            )
        }
    }
    
    private func loadSampleMutation() {
        vm.mutUp = "ATGGTGAGCAAGGGCGAGGAGCTGTTCACCGGGGTGGTGCCCATCCTGGTCGAGCTGGACGGCGACGTAAACGGCCACAAGTTCAGCGTGTCCGGCGAGGGCGAGGGCGATGCCACCTACGGCAAGCTGACCCTGAAGTTCATCTGCACCACCGGCAAGCTGCCCGTGCCCTGGCCCACCCTCGTGACCACCCTG"
        vm.mutSite = "AAG"
        vm.mutDown = "CGTGCAGTGCTTCAGCCGCTACCCCGACCACATGAAGCAGCACGACTTCTTCAAGTCCGCCATGCCCGAAGGCTACGTCCAGGAGCGCACCATCTTCTTCAAGGACGACGGCAACTACAAGACCCGCGCCGAGGTGAAGTTCGAGGGCGACACCCTGGTGAACCGCATCGAGCTGAAGGGCATCGACTTCAAGGAG"
    }
    
    private func selectDNAFile(completion: @escaping (URL) -> Void) {
        FinderFileDropHelper.selectDNAFile(prompt: "选择质粒", completion: completion)
    }
}
