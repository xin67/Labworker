import SwiftUI
import CloneStudioCore

/// 多源在线靶点与脱靶对比工作台（CHOPCHOP + VBC-Score + UCSC CRISPOR 三源并发对比）
public struct CHOPCHOPWebView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var vm = WorkspaceSessionManager.shared.chopchopVM
    
    public init() {}
    
    public var body: some View {
        StudioPageLayout(
            title: "多源靶点对比",
            toolbar: [
                .picker(
                    id: "chopchop_species",
                    label: "物种",
                    options: TargetSpecies.allCases.map { spec in
                        StudioToolbarPickerOption(
                            id: spec.rawValue,
                            title: spec == .human ? "人源 (hg38)" : "鼠源 (mm39)",
                            tint: spec == .human ? .blue : .orange,
                            isSelected: vm.species == spec
                        ) {
                            if vm.species != spec {
                                vm.species = spec
                                if !vm.targets.isEmpty {
                                    vm.fetchTargets()
                                }
                            }
                        }
                    }
                ),
                .action(
                    id: "compare_web_menu",
                    groupKey: nil,
                    title: "网页版",
                    icon: "safari",
                    help: "在 Safari 中打开对应在线靶点数据库",
                    menuItems: [
                        StudioToolbarMenuItem(title: "打开 VBC-Score", icon: "bolt.shield.fill") {
                            vm.openSourceInSafari(.vbcScore)
                        },
                        StudioToolbarMenuItem(title: "打开 CRISPOR (UCSC)", icon: "waveform.path.ecg") {
                            vm.openSourceInSafari(.ucscCrispor)
                        },
                        StudioToolbarMenuItem(title: "打开 CHOPCHOP", icon: "globe") {
                            vm.openSourceInSafari(.chopchop)
                        }
                    ]
                ),
                .action(
                    id: "clear_chopchop",
                    groupKey: nil,
                    title: "",
                    icon: "trash",
                    tint: .red,
                    isDisabled: vm.gene.isEmpty && vm.targets.isEmpty && vm.activeUserLocalTargets.isEmpty,
                    help: "清空靶点检索结果",
                    action: vm.clear
                )
            ]
        ) {
            StudioCard(title: "靶点检索与比对") {
                if !vm.targets.isEmpty {
                    StudioCompactPillButton(
                        title: "刷新",
                        icon: "arrow.clockwise",
                        isDisabled: vm.isLoading,
                        help: "忽略本地缓存重新查询全部已选在线数据库"
                    ) {
                        vm.fetchTargets(forceRefresh: true)
                    }
                }
            } content: {
                VStack(alignment: .leading, spacing: 10) {
                    // 1. 数据源勾选栏（S 档 24pt 胶囊 + 状态指示圆点）
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
                                    desc += isEnabled ? "（已启用，等待检索）" : "（未启用，点击开启）"
                                case .loading(let msg):
                                    desc += " — \(msg)"
                                case .loaded(let cnt):
                                    desc += " — 已获取 \(cnt) 条候选"
                                case .failed(let err):
                                    desc += " — 查询失败：\(err)"
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
                        TextField("基因名 (如 TP53, Trp53, CDH17)", text: $vm.gene)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .font(.system(size: 12.5))
                            .onSubmit {
                                vm.fetchTargets()
                            }
                        
                        StudioActionPillButton(
                            title: vm.isLoading ? "检索中" : "检索",
                            icon: "magnifyingglass",
                            tint: .orange,
                            isProminent: true,
                            isDisabled: vm.gene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            help: "并发检索所选在线数据库并按 20bp Spacer 合并交叉比对"
                        ) {
                            vm.fetchTargets(forceRefresh: false)
                        }
                    }
                    
                    // 3. 本地 SG/SH 序列比对栏
                    localSequenceCompareSection
                    
                    // 4. 非阻塞实时状态与单源失败重试条
                    statusSummaryBar
                }
            }
            
            if !vm.targets.isEmpty {
                resultsListCard
            }
        }
        .alert("提示", isPresented: $vm.showErrorAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(verbatim: vm.errorMessage ?? "")
        }
        .onAppear {
            handleNavigationTrigger()
        }
        .onChange(of: appState.shouldAutoQueryCHOPCHOP) { _, shouldQuery in
            if shouldQuery {
                handleNavigationTrigger()
            }
        }
    }
    
    // MARK: - 非阻塞多源进度与失败重试条
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
                    let errMsg = vm.sourceStates[src]?.errorMessage ?? "查询失败"
                    StudioCompactPillButton(
                        title: "重试 \(src.shortTitle)",
                        icon: "arrow.clockwise",
                        dotColor: .red,
                        tint: .orange,
                        help: "\(src.rawValue) 暂未返回：\(errMsg)"
                    ) {
                        vm.retrySource(src)
                    }
                }
            }
            .studioInnerBox(tint: vm.isLoading ? .orange : .red, paddingH: 10, paddingV: 6)
        }
    }
    
    // MARK: - 本地 SG / SH 序列比对区
    private var localSequenceCompareSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField("粘贴本地 sgRNA / shRNA 序列比对", text: $vm.manualCompareInput)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.system(size: 12))
                    .onSubmit {
                        vm.addManualCompareSequence()
                    }
                
                StudioActionPillButton(
                    title: "添加比对",
                    icon: "plus.circle.fill",
                    isDisabled: vm.manualCompareInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: vm.addManualCompareSequence
                )

                if !vm.activeUserLocalTargets.isEmpty {
                    StudioActionPillButton(
                        title: "清空比对",
                        icon: "trash",
                        tint: .red,
                        action: vm.clearUserLocalCompareTargets
                    )
                }
            }

            if !vm.activeUserLocalTargets.isEmpty {
                StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(vm.activeUserLocalTargets) { item in
                        let hit = vm.bestHitForLocalTarget(item)
                        HStack(spacing: 5) {
                            Text(item.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(hit != nil ? .green : .secondary)
                            Text(item.cleanSequence)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary)
                            if let hitTarget = hit {
                                Text(verbatim: "✓ #\(hitTarget.rank)")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.green))
                            } else if !vm.targets.isEmpty {
                                Text("未命中")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            }
                            Button(action: { vm.removeLocalCompareTarget(item) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .studioInnerBox(tint: hit != nil ? .green : nil, isHighlighted: hit != nil, paddingH: 8, paddingV: 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 预测结果列表卡片
    private var resultsListCard: some View {
        StudioCard(title: "靶点列表 (\(vm.sortedTargets.count))") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                StudioCompactPillButton(
                    title: "全部",
                    tint: vm.activeSourceFilter == .all ? .blue : nil,
                    isSelected: vm.activeSourceFilter == .all
                ) {
                    vm.activeSourceFilter = .all
                }
                
                if vm.consensusTargetsCount > 0 {
                    StudioCompactPillButton(
                        title: "共识 (\(vm.consensusTargetsCount))",
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
                    help: "将命中本地 sgRNA / shRNA 序列的靶点置顶"
                ) {
                    vm.pinLocalMatchesFirst.toggle()
                }

                if vm.totalMatchedTargetsCount > 0 {
                    StudioCompactPillButton(
                        title: "仅看命中 (\(vm.totalMatchedTargetsCount))",
                        icon: "line.3.horizontal.decrease.circle",
                        tint: .green,
                        isSelected: vm.showOnlyLocalMatches
                    ) {
                        vm.showOnlyLocalMatches.toggle()
                    }

                    StudioCompactPillButton(title: "勾选命中", icon: "checkmark.circle", tint: .green, action: vm.selectLocalHitsOnly)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    StudioMetricBadge(label: "已选", value: "\(vm.selectedTargetIDs.count)", color: .orange)

                    StudioMenuPicker(
                        selection: $vm.sortMode,
                        options: CHOPCHOPCompareViewModel.CHOPCHOPSortMode.allCases.map {
                            StudioMenuPickerOption(value: $0, title: $0.rawValue)
                        },
                        help: vm.sortMode.ruleExplanation
                    )

                    StudioActionPillButton(title: "全选", action: vm.selectAll)
                    StudioActionPillButton(title: "清空", tint: .red, action: vm.deselectAll)

                    StudioActionPillButton(
                        title: "加入引物池",
                        icon: "cart.badge.plus",
                        tint: .green,
                        isProminent: true,
                        isDisabled: vm.selectedTargetIDs.isEmpty,
                        action: vm.addSelectedToCart
                    )
                }
                
                LazyVStack(spacing: 6) {
                    ForEach(vm.sortedTargets) { target in
                        targetRow(target, localMatch: vm.matchMap[target.id])
                    }
                }
            }
        }
    }
    
    private func handleNavigationTrigger() {
        if appState.shouldAutoQueryCHOPCHOP {
            appState.shouldAutoQueryCHOPCHOP = false
            let targetGene = appState.chopchopGene.trimmingCharacters(in: .whitespacesAndNewlines)
            if !targetGene.isEmpty {
                vm.updateTarget(gene: targetGene, species: appState.chopchopSpecies)
                vm.fetchTargets()
            }
        }
    }
    
    private func targetRow(_ target: CHOPCHOPTarget, localMatch: CHOPCHOPLocalMatchResult?) -> some View {
        let isChecked = vm.selectedTargetIDs.contains(target.id)
        let isPrimaryHit = (localMatch?.isPrimaryUserSelection == true)
        let isAnyLocalHit = (localMatch != nil)
        
        let rowBg: Color = {
            if isPrimaryHit {
                return Color.green.opacity(0.13)
            } else if isAnyLocalHit {
                return Color.teal.opacity(0.09)
            } else if isChecked {
                return Color.orange.opacity(0.08)
            } else {
                return Color(NSColor.textBackgroundColor).opacity(0.55)
            }
        }()
        
        let rowBorder: Color = {
            if isPrimaryHit {
                return Color.green.opacity(0.65)
            } else if isAnyLocalHit {
                return Color.teal.opacity(0.42)
            } else if isChecked {
                return Color.orange.opacity(0.35)
            } else {
                return Color.primary.opacity(0.06)
            }
        }()
        
        let sourceHelp = "命中数据源：" + target.sources.map(\.rawValue).joined(separator: " + ")
        let sourceBadgeText = target.sources.count >= 2
            ? "\(target.sources.count)/3 共识"
            : (target.sources.first?.shortTitle ?? "CHOP")
        let sourceBadgeColor: Color = target.sources.count >= 3 ? .green : (target.sources.count == 2 ? .teal : .secondary)
        
        return VStack(alignment: .leading, spacing: 5) {
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
                    .frame(minWidth: 32, alignment: .leading)
                
                HStack(spacing: 1) {
                    Text(verbatim: target.spacer)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(isPrimaryHit ? .green : (isChecked ? .orange : .primary))
                    Text(verbatim: target.pam)
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
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
                .help("复制 20bp Spacer")
                
                Text(verbatim: sourceBadgeText)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(sourceBadgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(sourceBadgeColor.opacity(0.14)))
                    .help(sourceHelp)
                
                if let match = localMatch {
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
                
                Spacer(minLength: 4)
                
                TargetScoreBadge(score: target.combinedScore, compact: true)
                    .help(target.combinedScore.summary)
                
                StudioCompactPillButton(
                    title: "",
                    icon: "cart.badge.plus",
                    tint: .green,
                    help: "加入引物池"
                ) {
                    vm.addPairToCart(target)
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
                        label: "脱靶",
                        value: target.offTargetSummary,
                        color: target.isHighlySpecific ? .green : .orange
                    )
                    .help("CHOPCHOP Bowtie 全基因组错配 MM0/MM1/MM2/MM3")
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
                    .help("VBC-Score 敲除综合分 | 活性 \(act) · inDelphi移码 \(fs) · Bioscore \(bio) · 高危脱靶 \(vl)/\(lk)")
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
                    .help("UCSC CRISPOR MIT 特异性分 | Doench2016 \(doenchTxt) · CRISPRscan \(scanTxt) · 移码分 \(oofTxt)")
                }
                
                StudioMetricBadge(
                    label: "效率",
                    value: String(format: "%.1f", target.efficiency),
                    color: .blue
                )
                .help("切割活性/百分位评分")
            }
            .padding(.leading, 26)
        }
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
