import SwiftUI
import CloneStudioCore

// MARK: - 1. sgRNA 内嵌三源在线靶点对比面板（VBC-Score + UCSC CRISPOR + CHOPCHOP）

/// 内嵌于 `SgRNADesignView` 的三源在线靶点并发对比面板
public struct SgRNAOnlineComparePanel: View {
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject private var vm = WorkspaceSessionManager.shared.chopchopVM
    public let species: TargetSpecies
    public let vectorOverhang: CRISPRDesigner.VectorOverhang
    public let customPrefix: String
    
    public init(
        species: TargetSpecies,
        vectorOverhang: CRISPRDesigner.VectorOverhang,
        customPrefix: String
    ) {
        self.species = species
        self.vectorOverhang = vectorOverhang
        self.customPrefix = customPrefix
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. 数据源开关与实时状态点
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(TargetCompareSource.allCases) { src in
                    let isEnabled = vm.enabledSources.contains(src)
                    let state = vm.sourceStates[src] ?? .idle
                    let dotCol: Color? = {
                        switch state {
                        case .idle: return nil
                        case .loading: return .orange
                        case .loaded: return .green
                        case .failed: return .red
                        }
                    }()
                    let chipTitle: String = {
                        if let cnt = state.loadedCount {
                            return "\(src.rawValue) (\(cnt))"
                        }
                        return src.rawValue
                    }()
                    let helpText: String = {
                        var desc = "\(src.rawValue) · \(src.subtitle)"
                        switch state {
                        case .idle:
                            desc += isEnabled ? L10n.t("（已启用，等待检索）") : L10n.t("（未启用，点击开启）")
                        case .loading(let msg):
                            desc += " — \(msg)"
                        case .loaded(let cnt):
                            desc += L10n.tr(" — 已获取 \(cnt) 条候选", " — \(cnt) candidates fetched")
                        case .failed(let err):
                            desc += L10n.tr(" — 查询失败：\(err)", " — Query failed: \(err)")
                        }
                        return desc
                    }()
                    StudioCompactPillButton(
                        title: chipTitle,
                        icon: src.icon,
                        dotColor: dotCol,
                        tint: isEnabled ? .teal : nil,
                        isSelected: isEnabled,
                        help: helpText
                    ) {
                        vm.toggleSource(src)
                    }
                }
            }
            
            // 2. 基因检索栏（L 档 28pt 等高对齐）
            HStack(spacing: 8) {
                TextField(L10n.t("输入基因名 (如 TP53, Trp53, CDH17)"), text: $vm.gene)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.system(size: 12.5))
                    .onSubmit {
                        vm.species = species
                        vm.fetchTargets()
                    }
                
                StudioActionPillButton(
                    title: vm.isLoading ? "检索中" : "在线检索",
                    icon: "magnifyingglass",
                    tint: .orange,
                    isProminent: true,
                    isDisabled: vm.gene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    help: "并发检索所选在线数据库并按 20bp Spacer 合并交叉比对"
                ) {
                    vm.species = species
                    vm.fetchTargets(forceRefresh: false)
                }
                
                if !vm.targets.isEmpty {
                    StudioActionPillButton(
                        title: "",
                        icon: "arrow.clockwise",
                        isDisabled: vm.isLoading,
                        help: "忽略本地缓存重新并发查询全部已选在线数据库"
                    ) {
                        vm.species = species
                        vm.fetchTargets(forceRefresh: true)
                    }
                }
            }
            
            // 3. 本地 sgRNA 序列对比栏
            LocalCompareSequenceBar(
                placeholder: L10n.t("粘贴本地 20bp sgRNA 序列高亮比对（支持空格/逗号分隔多条）"),
                inputText: $vm.manualCompareInput,
                activeTargets: vm.activeUserLocalTargets,
                hitRankForTarget: { item in
                    vm.bestHitForLocalTarget(item).map { "✓ #\($0.rank)" }
                },
                hasResults: !vm.targets.isEmpty,
                onAdd: vm.addManualCompareSequence,
                onClearAll: vm.clearUserLocalCompareTargets,
                onRemoveItem: vm.removeLocalCompareTarget
            )
            
            // 4. 非阻塞多源进度与单源重试条
            statusSummaryBar
            
            // 5. 筛选 / 排序 / 结果清单
            if !vm.targets.isEmpty {
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        StudioCompactPillButton(
                            title: L10n.tr("全部 (\(vm.targets.count))", "All (\(vm.targets.count))"),
                            tint: vm.activeSourceFilter == .all ? .blue : nil,
                            isSelected: vm.activeSourceFilter == .all
                        ) {
                            vm.activeSourceFilter = .all
                        }
                        
                        if vm.consensusTargetsCount > 0 {
                            StudioCompactPillButton(
                                title: L10n.tr("共识 (\(vm.consensusTargetsCount))", "Consensus (\(vm.consensusTargetsCount))"),
                                icon: "checkmark.seal",
                                tint: vm.activeSourceFilter == .consensus ? .teal : nil,
                                isSelected: vm.activeSourceFilter == .consensus,
                                help: "仅显示同时被 2 个及以上在线数据库命中的靶点"
                            ) {
                                vm.activeSourceFilter = .consensus
                            }
                        }
                        
                        ForEach(TargetCompareSource.allCases) { src in
                            let cnt = vm.targetCount(for: src)
                            if cnt > 0 {
                                let filterTarget: CHOPCHOPCompareViewModel.SourceFilter = {
                                    switch src {
                                    case .vbcScore: return .vbcScore
                                    case .ucscCrispor: return .ucscCrispor
                                    case .chopchop: return .chopchop
                                    }
                                }()
                                StudioCompactPillButton(
                                    title: "\(src.shortTitle) (\(cnt))",
                                    tint: vm.activeSourceFilter == filterTarget ? .teal : nil,
                                    isSelected: vm.activeSourceFilter == filterTarget
                                ) {
                                    vm.activeSourceFilter = filterTarget
                                }
                            }
                        }
                        
                        StudioCompactPillButton(
                            title: "置顶命中",
                            icon: "pin",
                            tint: vm.pinLocalMatchesFirst ? .teal : nil,
                            isSelected: vm.pinLocalMatchesFirst,
                            help: "将命中本地 sgRNA 序列的靶点置顶"
                        ) {
                            vm.pinLocalMatchesFirst.toggle()
                        }
                        
                        if vm.totalMatchedTargetsCount > 0 {
                            StudioCompactPillButton(
                                title: L10n.tr("仅看命中 (\(vm.totalMatchedTargetsCount))", "Hits Only (\(vm.totalMatchedTargetsCount))"),
                                icon: "line.3.horizontal.decrease.circle",
                                tint: .green,
                                isSelected: vm.showOnlyLocalMatches
                            ) {
                                vm.showOnlyLocalMatches.toggle()
                            }
                            
                            StudioCompactPillButton(
                                title: "勾选命中",
                                icon: "checkmark.circle",
                                tint: .green,
                                action: vm.selectLocalHitsOnly
                            )
                        }
                    }
                    
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        StudioMetricBadge(label: L10n.t("已选"), value: "\(vm.selectedTargetIDs.count)", color: .orange)
                        
                        StudioMenuPicker(
                            selection: $vm.sortMode,
                            options: CHOPCHOPCompareViewModel.CHOPCHOPSortMode.allCases.map {
                                StudioMenuPickerOption(value: $0, title: $0.rawValue)
                            },
                            compact: true,
                            help: vm.sortMode.ruleExplanation
                        )
                        
                        StudioCompactPillButton(title: "全选", action: vm.selectAll)
                        StudioCompactPillButton(title: "清空", tint: .red, action: vm.deselectAll)
                        StudioCompactPillButton(
                            title: L10n.tr("直接加池 (\(vm.selectedTargetIDs.count))", "Add Selected (\(vm.selectedTargetIDs.count))"),
                            icon: "cart.badge.plus",
                            tint: .green,
                            isProminent: !vm.selectedTargetIDs.isEmpty,
                            isDisabled: vm.selectedTargetIDs.isEmpty
                        ) {
                            vm.addSelectedToCart(vector: vectorOverhang, prefix: customPrefix)
                        }
                    }
                    
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(vm.sortedTargets) { target in
                                sgTargetRow(target, localMatch: vm.matchMap[target.id])
                            }
                        }
                    }
                    .frame(height: min(max(180, CGFloat(vm.sortedTargets.count) * 62), 360))
                }
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showErrorAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(verbatim: vm.errorMessage ?? "")
        }
    }
    
    @ViewBuilder
    private var statusSummaryBar: some View {
        let failedSources = TargetCompareSource.allCases.filter {
            vm.enabledSources.contains($0) && (vm.sourceStates[$0]?.isFailed == true)
        }
        if vm.isLoading || !failedSources.isEmpty {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                if vm.isLoading {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(verbatim: vm.progressMessage)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.orange)
                    }
                }
                
                ForEach(failedSources) { src in
                    let errMsg = vm.sourceStates[src]?.errorMessage ?? L10n.t("查询失败")
                    StudioCompactPillButton(
                        title: L10n.tr("重试 \(src.shortTitle)", "Retry \(src.shortTitle)"),
                        icon: "arrow.clockwise",
                        dotColor: .red,
                        tint: .orange,
                        help: L10n.tr("\(src.rawValue) 暂未返回：\(errMsg)", "\(src.rawValue) unavailable: \(errMsg)")
                    ) {
                        vm.species = species
                        vm.retrySource(src)
                    }
                }
            }
            .studioInnerBox(tint: vm.isLoading ? .orange : .red, paddingH: 10, paddingV: 6)
        }
    }
    
    private func sgTargetRow(_ target: CHOPCHOPTarget, localMatch: CHOPCHOPLocalMatchResult?) -> some View {
        let isChecked = vm.selectedTargetIDs.contains(target.id)
        let isPrimaryHit = (localMatch?.isPrimaryUserSelection == true)
        let isAnyLocalHit = (localMatch != nil)
        let sourceHelp = L10n.t("命中数据源：") + target.sources.map(\.rawValue).joined(separator: " + ")
        let sourceBadgeText = target.sources.count >= 2
            ? L10n.tr("\(target.sources.count)/3 共识", "\(target.sources.count)/3 Consensus")
            : (target.sources.first?.shortTitle ?? "CHOP")
        let sourceBadgeColor: Color = target.sources.count >= 3 ? .green : (target.sources.count == 2 ? .teal : .secondary)
        
        return OnlineCompareRowContainer(
            isPrimaryHit: isPrimaryHit,
            isAnyLocalHit: isAnyLocalHit,
            isChecked: isChecked,
            checkedAccent: .cyan
        ) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { isChecked },
                        set: { _ in vm.toggleTarget(target) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    
                    Text(verbatim: "#\(target.rank)")
                        .font(.system(size: 10.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    
                    HStack(spacing: 1) {
                        Text(verbatim: target.spacer)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(isPrimaryHit ? .green : (isChecked ? .cyan : .primary))
                        Text(verbatim: target.pam)
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(.orange)
                    }
                    .lineLimit(1)
                    .textSelection(.enabled)
                    
                    Button(action: { vm.copySpacer(target) }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("复制 20bp Spacer"))
                    
                    Text(verbatim: sourceBadgeText)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(sourceBadgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(sourceBadgeColor.opacity(0.14)))
                        .help(sourceHelp)
                    
                    if let match = localMatch {
                        LocalMatchPillBadge(match: match)
                    }
                    
                    Spacer(minLength: 4)
                    
                    TargetScoreBadge(score: target.combinedScore, compact: true)
                        .help(target.combinedScore.summary)
                    
                    StudioCompactPillButton(
                        title: "",
                        icon: "cart.badge.plus",
                        tint: .green,
                        help: "按当前载体骨架生成并加入引物池"
                    ) {
                        vm.addPairToCart(target, vector: vectorOverhang, prefix: customPrefix)
                    }
                }
                
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                    let exonSuffix = target.vbcExon.map { " · \($0)" } ?? ""
                    Text(verbatim: "\(target.genomicLocation) (\(target.strand))\(exonSuffix)")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                    
                    Text(verbatim: "GC \(String(format: "%.0f", target.gcContent))%")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                    
                    if target.hasCHOPCHOPOffTargets {
                        StudioMetricBadge(
                            label: L10n.t("脱靶"),
                            value: target.offTargetSummary,
                            color: target.isHighlySpecific ? .green : .orange
                        )
                        .help(L10n.t("CHOPCHOP Bowtie 全基因组错配 MM0/MM1/MM2/MM3"))
                    }
                    
                    if let vbc = target.vbcScore {
                        let act = target.vbcActivity.map { String(format: "%.2f", $0) } ?? "—"
                        let fs = target.vbcFrameshift.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
                        let bio = target.vbcBioscore.map { String(format: "%.2f", $0) } ?? "—"
                        let vl = target.vbcVeryLikelyOT ?? 0
                        let lk = target.vbcLikelyOT ?? 0
                        StudioMetricBadge(
                            label: "VBC",
                            value: String(format: "%.2f", vbc),
                            color: vbc >= 0.65 ? .green : .blue
                        )
                        .help(L10n.tr("VBC-Score 敲除综合分 | 活性 \(act) · inDelphi移码 \(fs) · Bioscore \(bio) · 高危脱靶 \(vl)/\(lk)", "VBC-Score | Activity \(act) · inDelphi Frameshift \(fs) · Bioscore \(bio) · High-Risk Off-targets \(vl)/\(lk)"))
                    }
                    
                    if let mit = target.mitSpecificity {
                        let doenchTxt = target.crisporDoenchPerc.map { String(format: "%.0f%%", $0) } ?? "—"
                        let scanTxt = target.crisporScanScore.map { String(format: "%.0f%%", $0) } ?? "—"
                        let oofTxt = target.crisporOutOfFrame.map { String(format: "%.0f", $0) } ?? "—"
                        StudioMetricBadge(
                            label: "MIT",
                            value: "\(mit)",
                            color: mit >= 65 ? .green : .orange
                        )
                        .help(L10n.tr("UCSC CRISPOR MIT 特异性分 | Doench2016 \(doenchTxt) · CRISPRscan \(scanTxt) · 移码分 \(oofTxt)", "UCSC CRISPOR MIT Specificity | Doench 2016 \(doenchTxt) · CRISPRscan \(scanTxt) · Out-of-Frame \(oofTxt)"))
                    }
                    
                    StudioMetricBadge(
                        label: L10n.t("效率"),
                        value: String(format: "%.1f", target.efficiency),
                        color: .blue
                    )
                    .help(L10n.t("切割活性/百分位评分"))
                }
                .padding(.leading, 26)
            }
        }
    }
}

// MARK: - 2. shRNA 内嵌 Broad GPP Public Portal 在线对比面板

/// 内嵌于 `ShRNADesignView` 的 Broad GPP Public Portal (TRC shRNA) 在线对比面板
public struct ShRNABroadGPPComparePanel: View {
    @Environment(\.appLanguage) private var appLanguage
    @ObservedObject private var vm = WorkspaceSessionManager.shared.broadGPPVM
    public let species: TargetSpecies
    public let loopSequence: String
    public let customPrefix: String
    
    public init(
        species: TargetSpecies,
        loopSequence: String,
        customPrefix: String
    ) {
        self.species = species
        self.loopSequence = loopSequence
        self.customPrefix = customPrefix
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. 基因检索栏（L 档 28pt 等高对齐）
            HStack(spacing: 8) {
                TextField(L10n.t("基因名 / NCBI Gene ID / RefSeq (如 TP53, Trp53, CDH17)"), text: $vm.gene)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.system(size: 12.5))
                    .onSubmit {
                        vm.species = species
                        vm.fetchTargets()
                    }
                
                StudioActionPillButton(
                    title: vm.isLoading ? "检索中" : "检索 Broad GPP",
                    icon: "magnifyingglass",
                    tint: .orange,
                    isProminent: true,
                    isDisabled: vm.gene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isLoading,
                    help: "从 Broad Institute GPP Public Portal 拉取官方 TRC shRNA 克隆与评分"
                ) {
                    vm.species = species
                    vm.fetchTargets(forceRefresh: false)
                }
                
                if !vm.targets.isEmpty {
                    StudioActionPillButton(
                        title: "",
                        icon: "arrow.clockwise",
                        isDisabled: vm.isLoading,
                        help: "忽略本地缓存重新查询 Broad GPP Public Portal"
                    ) {
                        vm.species = species
                        vm.fetchTargets(forceRefresh: true)
                    }
                }
            }
            
            // 2. 已解析基因摘要条
            if let sym = vm.resolvedGeneSymbol, let gid = vm.resolvedGeneID {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(sym) (NCBI: \(gid))")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(.indigo)
                        if !vm.resolvedGeneDescription.isEmpty {
                            Text(verbatim: vm.resolvedGeneDescription)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    if vm.wtTranscriptCount > 0 {
                        StudioMetricBadge(label: L10n.t("WT转录本"), value: "\(vm.wtTranscriptCount)", color: .blue)
                    }
                    
                    if vm.isNearMatchFallback {
                        Text(L10n.t("仅匹配到近源同源 TRC (≥84% SDR)"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.orange)
                    }
                    
                    StudioCompactPillButton(
                        title: "打开 GPP 基因页",
                        icon: "safari",
                        tint: .blue,
                        help: "在 Safari 中打开 Broad GPP Public Portal 基因详情页"
                    ) {
                        vm.openGeneInSafari()
                    }
                }
                .studioInnerBox(tint: .indigo, paddingH: 10, paddingV: 6)
            }
            
            // 3. 本地 shRNA 序列高亮对比栏
            LocalCompareSequenceBar(
                placeholder: L10n.t("粘贴本地 19–21bp shRNA 靶点序列与 TRC 克隆对比"),
                inputText: $vm.manualCompareInput,
                activeTargets: vm.activeUserLocalTargets,
                hitRankForTarget: { item in
                    vm.bestHitForLocalTarget(item).map { "✓ \($0.primaryCloneID)" }
                },
                hasResults: !vm.targets.isEmpty,
                onAdd: vm.addManualCompareSequence,
                onClearAll: vm.clearUserLocalCompareTargets,
                onRemoveItem: vm.removeLocalCompareTarget
            )
            
            // 4. 检索进度与错误重试提示条
            if vm.isLoading || (vm.errorMessage != nil) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    if vm.isLoading {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(verbatim: vm.progressMessage)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.orange)
                        }
                    } else if let err = vm.errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                            Text(verbatim: err)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        }
                        
                        StudioCompactPillButton(
                            title: "重试检索",
                            icon: "arrow.clockwise",
                            dotColor: .red,
                            tint: .orange
                        ) {
                            vm.species = species
                            vm.fetchTargets(forceRefresh: true)
                        }
                    }
                }
                .studioInnerBox(tint: vm.isLoading ? .orange : .red, paddingH: 10, paddingV: 6)
            }
            
            // 5. 筛选 / 排序 / 克隆列表
            if !vm.targets.isEmpty {
                Divider()
                
                VStack(alignment: .leading, spacing: 8) {
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        StudioCompactPillButton(
                            title: L10n.tr("全部 (\(vm.targets.count))", "All (\(vm.targets.count))"),
                            tint: vm.regionFilter == .all ? .blue : nil,
                            isSelected: vm.regionFilter == .all
                        ) {
                            vm.regionFilter = .all
                        }
                        
                        if vm.cdsCount > 0 {
                            StudioCompactPillButton(
                                title: "CDS (\(vm.cdsCount))",
                                tint: vm.regionFilter == .cds ? .indigo : nil,
                                isSelected: vm.regionFilter == .cds
                            ) {
                                vm.regionFilter = .cds
                            }
                        }
                        
                        if vm.utr3Count > 0 {
                            StudioCompactPillButton(
                                title: "3'UTR (\(vm.utr3Count))",
                                tint: vm.regionFilter == .utr3 ? .purple : nil,
                                isSelected: vm.regionFilter == .utr3
                            ) {
                                vm.regionFilter = .utr3
                            }
                        }
                        
                        StudioCompactPillButton(
                            title: L10n.tr("零他基因脱靶 (\(vm.specificCount))", "Gene-Specific (\(vm.specificCount))"),
                            icon: "checkmark.shield",
                            tint: vm.onlySpecific ? .green : nil,
                            isSelected: vm.onlySpecific,
                            help: "过滤掉 Matches Other Gene in Same Taxon = Y 的克隆"
                        ) {
                            vm.onlySpecific.toggle()
                        }
                        
                        StudioCompactPillButton(
                            title: "置顶命中",
                            icon: "pin",
                            tint: vm.pinLocalMatchesFirst ? .teal : nil,
                            isSelected: vm.pinLocalMatchesFirst
                        ) {
                            vm.pinLocalMatchesFirst.toggle()
                        }
                        
                        if vm.totalMatchedTargetsCount > 0 {
                            StudioCompactPillButton(
                                title: L10n.tr("仅看命中 (\(vm.totalMatchedTargetsCount))", "Hits Only (\(vm.totalMatchedTargetsCount))"),
                                icon: "line.3.horizontal.decrease.circle",
                                tint: .green,
                                isSelected: vm.showOnlyLocalMatches
                            ) {
                                vm.showOnlyLocalMatches.toggle()
                            }
                            
                            StudioCompactPillButton(
                                title: "勾选命中",
                                icon: "checkmark.circle",
                                tint: .green,
                                action: vm.selectLocalHitsOnly
                            )
                        }
                    }
                    
                    StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        StudioMetricBadge(label: L10n.t("已选"), value: "\(vm.selectedTargetIDs.count)", color: .orange)
                        
                        StudioMenuPicker(
                            selection: $vm.sortMode,
                            options: BroadGPPCompareViewModel.BroadGPPSortMode.allCases.map {
                                StudioMenuPickerOption(value: $0, title: $0.rawValue)
                            },
                            compact: true,
                            help: vm.sortMode.ruleExplanation
                        )
                        
                        StudioCompactPillButton(title: "全选", action: vm.selectAll)
                        StudioCompactPillButton(title: "清空", tint: .red, action: vm.deselectAll)
                        StudioCompactPillButton(
                            title: L10n.tr("直接加池 (\(vm.selectedTargetIDs.count))", "Add Selected (\(vm.selectedTargetIDs.count))"),
                            icon: "cart.badge.plus",
                            tint: .green,
                            isProminent: !vm.selectedTargetIDs.isEmpty,
                            isDisabled: vm.selectedTargetIDs.isEmpty
                        ) {
                            vm.addSelectedToCart(loop: loopSequence, prefix: customPrefix)
                        }
                    }
                    
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(vm.sortedTargets) { target in
                                gppTargetRow(target, localMatch: vm.matchMap[target.id])
                            }
                        }
                    }
                    .frame(height: min(max(180, CGFloat(vm.sortedTargets.count) * 62), 360))
                }
            }
        }
        .alert(L10n.t("提示"), isPresented: $vm.showErrorAlert) {
            Button(L10n.t("好的"), role: .cancel) {}
        } message: {
            Text(verbatim: vm.errorMessage ?? "")
        }
    }
    
    private func gppTargetRow(_ target: BroadGPPShRNATarget, localMatch: CHOPCHOPLocalMatchResult?) -> some View {
        let isChecked = vm.selectedTargetIDs.contains(target.id)
        let isPrimaryHit = (localMatch?.isPrimaryUserSelection == true)
        let isAnyLocalHit = (localMatch != nil)
        let cloneHelp = L10n.tr("打开 Broad GPP 克隆详情页 | 全部 TRC: \(target.allCloneIDs.joined(separator: ", "))", "Open Broad GPP Clone Page | All TRC: \(target.allCloneIDs.joined(separator: ", "))")
            + (target.legacyCloneName.isEmpty ? "" : L10n.tr(" | 编号: \(target.legacyCloneName)", " | Legacy: \(target.legacyCloneName)"))
        
        return OnlineCompareRowContainer(
            isPrimaryHit: isPrimaryHit,
            isAnyLocalHit: isAnyLocalHit,
            isChecked: isChecked,
            checkedAccent: .indigo
        ) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { isChecked },
                        set: { _ in vm.toggleTarget(target) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    
                    Text(verbatim: "#\(target.rank)")
                        .font(.system(size: 10.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    
                    Button(action: { vm.openCloneInSafari(target) }) {
                        HStack(spacing: 3) {
                            Text(verbatim: target.primaryCloneID)
                                .font(.system(size: 10, weight: .bold))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8.5, weight: .bold))
                        }
                        .foregroundColor(.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.indigo.opacity(0.13)))
                    }
                    .buttonStyle(.plain)
                    .help(cloneHelp)
                    
                    Text(verbatim: target.targetSequence)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(isPrimaryHit ? .green : (isChecked ? .indigo : .primary))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    
                    Button(action: { vm.copyTargetSequence(target) }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("复制 21bp 靶点序列"))
                    
                    if let match = localMatch {
                        LocalMatchPillBadge(match: match)
                    }
                    
                    Spacer(minLength: 4)
                    
                    TargetScoreBadge(score: target.combinedScore, compact: true)
                        .help(target.combinedScore.summary)
                    
                    StudioCompactPillButton(
                        title: "",
                        icon: "doc.on.clipboard",
                        tint: .blue,
                        help: "复制 Broad GPP 官方 pLKO 正反向克隆 Oligo"
                    ) {
                        vm.copyOfficialBroadOligos(target)
                    }
                    
                    StudioCompactPillButton(
                        title: "",
                        icon: "cart.badge.plus",
                        tint: .green,
                        help: "按当前 Loop 与前缀生成并加入引物池"
                    ) {
                        vm.addPairToCart(target, loop: loopSequence, prefix: customPrefix)
                    }
                }
                
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                    StudioMetricBadge(
                        label: L10n.t("载体"),
                        value: target.vectors.joined(separator: "/"),
                        color: .indigo
                    )
                    
                    StudioMetricBadge(
                        label: L10n.t("区域"),
                        value: target.matchRegions,
                        color: target.isCDS ? .blue : .purple
                    )
                    
                    if let adj = target.adjustedScore {
                        StudioMetricBadge(
                            label: "Adj",
                            value: String(format: "%.2f", adj),
                            color: adj >= 3.0 ? .green : .blue
                        )
                        .help(L10n.t("Broad GPP Adjusted Score（特异性校正后效价）"))
                    }
                    
                    if let intr = target.intrinsicScore {
                        StudioMetricBadge(
                            label: "Intr",
                            value: String(format: "%.2f", intr),
                            color: .teal
                        )
                        .help(L10n.t("Broad GPP Intrinsic Score（原始沉默效价）"))
                    }
                    
                    StudioMetricBadge(
                        label: "SDR",
                        value: "\(target.sdrMatchPercent)%",
                        color: target.sdrMatchPercent >= 100 ? .green : .orange
                    )
                    
                    if target.transcriptCount > 0 {
                        StudioMetricBadge(
                            label: L10n.t("转录本"),
                            value: "\(target.transcriptCount)",
                            color: .secondary
                        )
                        .help(L10n.t("匹配转录本：") + target.matchingTranscripts.joined(separator: ", "))
                    }
                    
                    Text(verbatim: L10n.t(target.matchesOtherGene ? "⚠️ 匹配他基因" : "单基因特异"))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(target.matchesOtherGene ? .red : .green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((target.matchesOtherGene ? Color.red : Color.green).opacity(0.13)))
                    
                    Text(verbatim: "GC \(String(format: "%.0f", target.gcContent))%")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                    
                    if let addgene = target.addgeneID {
                        StudioMetricBadge(label: "Addgene", value: addgene, color: .orange)
                    }
                }
                .padding(.leading, 26)
            }
        }
    }
}

// MARK: - 3. 共享 UI 辅助组件（无重复逻辑）

private struct LocalCompareSequenceBar: View {
    @Environment(\.appLanguage) private var appLanguage
    let placeholder: String
    @Binding var inputText: String
    let activeTargets: [LocalCompareTarget]
    let hitRankForTarget: (LocalCompareTarget) -> String?
    let hasResults: Bool
    let onAdd: () -> Void
    let onClearAll: () -> Void
    let onRemoveItem: (LocalCompareTarget) -> Void
    
    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.system(size: 12))
                    .onSubmit(onAdd)
                
                StudioActionPillButton(
                    title: "添加比对",
                    icon: "plus.circle.fill",
                    isDisabled: inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: onAdd
                )
                
                if !activeTargets.isEmpty {
                    StudioActionPillButton(
                        title: "清空比对",
                        icon: "trash",
                        tint: .red,
                        action: onClearAll
                    )
                }
            }
            
            if !activeTargets.isEmpty {
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(activeTargets) { item in
                        let hitText = hitRankForTarget(item)
                        HStack(spacing: 5) {
                            Text(verbatim: item.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(hitText != nil ? .green : .secondary)
                            Text(verbatim: item.cleanSequence)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.primary)
                            if let hitText {
                                Text(verbatim: hitText)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.green))
                            } else if hasResults {
                                Text(L10n.t("未命中"))
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            }
                            Button(action: { onRemoveItem(item) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .studioInnerBox(tint: hitText != nil ? .green : nil, isHighlighted: hitText != nil, paddingH: 8, paddingV: 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct LocalMatchPillBadge: View {
    @Environment(\.appLanguage) private var appLanguage
    let match: CHOPCHOPLocalMatchResult
    
    var body: some View {
        let _ = appLanguage
        Text(verbatim: match.badgeText)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(match.isPrimaryUserSelection ? .white : .teal)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    match.isPrimaryUserSelection
                        ? Color.green
                        : Color.teal.opacity(0.16)
                )
            )
            .lineLimit(1)
    }
}

private struct OnlineCompareRowContainer<Content: View>: View {
    @Environment(\.appLanguage) private var appLanguage
    let isPrimaryHit: Bool
    let isAnyLocalHit: Bool
    let isChecked: Bool
    let checkedAccent: Color
    let content: Content
    
    init(
        isPrimaryHit: Bool,
        isAnyLocalHit: Bool,
        isChecked: Bool,
        checkedAccent: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.isPrimaryHit = isPrimaryHit
        self.isAnyLocalHit = isAnyLocalHit
        self.isChecked = isChecked
        self.checkedAccent = checkedAccent
        self.content = content()
    }
    
    var body: some View {
        let _ = appLanguage
        let rowBg: Color = {
            if isPrimaryHit { return Color.green.opacity(0.13) }
            if isAnyLocalHit { return Color.teal.opacity(0.09) }
            if isChecked { return checkedAccent.opacity(0.08) }
            return Color(NSColor.textBackgroundColor).opacity(0.55)
        }()
        let rowBorder: Color = {
            if isPrimaryHit { return Color.green.opacity(0.65) }
            if isAnyLocalHit { return Color.teal.opacity(0.42) }
            if isChecked { return checkedAccent.opacity(0.35) }
            return Color.primary.opacity(0.06)
        }()
        
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                    .fill(rowBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                    .stroke(rowBorder, lineWidth: isPrimaryHit ? 1.5 : 1.0)
            )
    }
}

/// sgRNA / shRNA 共用本地文库候选行
public struct LocalLibraryTargetRow: View {
    @Environment(\.appLanguage) private var appLanguage
    public let target: GenomicTarget
    public let isChecked: Bool
    public let accentColor: Color
    public let copyToastPrefix: String
    public let polyTHelp: String
    public let onToggle: () -> Void
    
    public init(
        target: GenomicTarget,
        isChecked: Bool,
        accentColor: Color,
        copyToastPrefix: String,
        polyTHelp: String,
        onToggle: @escaping () -> Void
    ) {
        self.target = target
        self.isChecked = isChecked
        self.accentColor = accentColor
        self.copyToastPrefix = copyToastPrefix
        self.polyTHelp = polyTHelp
        self.onToggle = onToggle
    }
    
    public var body: some View {
        let _ = appLanguage
        let scoreRes = target.scoreResult
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isChecked },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            
            TargetScoreBadge(score: scoreRes, compact: true)
            
            Text(verbatim: target.gene)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            
            Text(verbatim: target.sequence)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(isChecked ? accentColor : .primary)
                .lineLimit(1)
                .textSelection(.enabled)
            
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(target.sequence, forType: .string)
                AppState.shared.showToast("\(L10n.t(copyToastPrefix)): \(target.sequence)")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.t("复制靶点序列"))
            
            Spacer(minLength: 4)
            
            if scoreRes.hasFatalIssue {
                Text("⚠️TTTT")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .help(L10n.t(polyTHelp))
            }
            
            Text(verbatim: "GC \(String(format: "%.0f", target.gcPercent))%")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .studioInnerBox(tint: isChecked ? accentColor : nil, isHighlighted: isChecked, paddingH: 10, paddingV: 6)
    }
}

/// sgRNA / shRNA 共用响应式手动输入面板
public struct LocalCustomTargetInputSection: View {
    @Environment(\.appLanguage) private var appLanguage
    @Binding public var geneName: String
    @Binding public var sequence: String
    public let sequencePlaceholder: String
    public let score: TargetScore?
    
    public init(
        geneName: Binding<String>,
        sequence: Binding<String>,
        sequencePlaceholder: String,
        score: TargetScore?
    ) {
        self._geneName = geneName
        self._sequence = sequence
        self.sequencePlaceholder = sequencePlaceholder
        self.score = score
    }
    
    public var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    TextField(L10n.t("基因名"), text: $geneName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .frame(minWidth: 96, idealWidth: 120, maxWidth: 140)
                    
                    TextField(L10n.t(sequencePlaceholder), text: $sequence)
                        .font(.system(size: 12))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                    
                    if let sc = score {
                        TargetScoreBadge(score: sc, compact: false)
                    }
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L10n.t("基因名"), text: $geneName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                    
                    HStack(spacing: 8) {
                        TextField(L10n.t(sequencePlaceholder), text: $sequence)
                            .font(.system(size: 12))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                        
                        if let sc = score {
                            TargetScoreBadge(score: sc, compact: true)
                        }
                    }
                }
            }
            
            if let sc = score, sc.hasFatalIssue, let warning = sc.fatalWarning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                .studioInnerBox(tint: .red, paddingH: 10, paddingV: 5)
            }
        }
    }
}
