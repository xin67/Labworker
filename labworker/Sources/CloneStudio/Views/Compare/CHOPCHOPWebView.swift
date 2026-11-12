import SwiftUI
import CloneStudioCore

/// CHOPCHOP 靶点与脱靶对比工作台（极简按钮驱动界面，无冗余说明段落）
public struct CHOPCHOPWebView: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var vm = WorkspaceSessionManager.shared.chopchopVM
    
    public init() {}
    
    public var body: some View {
        StudioPageLayout(title: "CHOPCHOP 靶点对比") {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                SpeciesSwitchBar(species: $vm.species) {
                    if !vm.targets.isEmpty {
                        vm.fetchTargets()
                    }
                }
                
                StudioSegmentedPillGroup(items: [
                    StudioPillGroupItem(title: "网页版", icon: "safari", action: vm.openInSafari),
                    StudioPillGroupItem(
                        title: "清空",
                        icon: "trash",
                        tint: .red,
                        isDisabled: vm.gene.isEmpty && vm.targets.isEmpty && vm.activeUserLocalTargets.isEmpty,
                        action: vm.clear
                    )
                ])
            }
        } content: {
                
                StudioCard(title: "靶点检索与比对") {
                    HStack(spacing: 6) {
                        ForEach(["TP53", "BRCA1", "MYC", "EGFR"], id: \.self) { sampleGene in
                            Button(sampleGene) {
                                vm.gene = sampleGene
                                vm.fetchTargets(forceRefresh: false)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        
                        if !vm.targets.isEmpty {
                            Button(action: { vm.fetchTargets(forceRefresh: true) }) {
                                Label("刷新", systemImage: "arrow.clockwise")
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(vm.isLoading)
                        }
                    }
                } content: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            TextField("基因名 (如 TP53, Trp53, CDH17)", text: $vm.gene)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                                .onSubmit {
                                    vm.fetchTargets()
                                }
                            
                            StudioPrimaryActionButton(
                                title: vm.isLoading ? "检索中..." : "检索靶点",
                                icon: "magnifyingglass",
                                tint: .orange,
                                isLoading: vm.isLoading,
                                isDisabled: vm.gene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ) {
                                vm.fetchTargets(forceRefresh: false)
                            }
                        }
                        
                        localSequenceCompareSection
                    }
                }
                
                if vm.isLoading {
                    StudioCard(title: "") {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text(verbatim: vm.progressMessage)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.orange)
                            Spacer()
                        }
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
    
    // MARK: - 本地 SG / SH 序列比对区
    private var localSequenceCompareSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                TextField("粘贴本地 sgRNA / shRNA 序列比对", text: $vm.manualCompareInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .onSubmit {
                        vm.addManualCompareSequence()
                    }
                
                Button(action: vm.addManualCompareSequence) {
                    Label("添加比对", systemImage: "plus.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.manualCompareInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                
                if !vm.activeUserLocalTargets.isEmpty {
                    Button("清空比对", role: .destructive, action: vm.clearUserLocalCompareTargets)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(hit != nil ? Color.green.opacity(0.12) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(hit != nil ? Color.green.opacity(0.55) : Color.primary.opacity(0.10), lineWidth: 1)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    // MARK: - 预测结果列表卡片
    private var resultsListCard: some View {
        StudioCard(title: "靶点列表 (\(vm.sortedTargets.count))") {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                Toggle("本地命中置顶", isOn: $vm.pinLocalMatchesFirst)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .medium))
                
                if vm.totalMatchedTargetsCount > 0 {
                    Toggle("仅看命中 (\(vm.totalMatchedTargetsCount))", isOn: $vm.showOnlyLocalMatches)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.green)
                    
                    Button("勾选命中", action: vm.selectLocalHitsOnly)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    StudioMetricBadge(label: "已选", value: "\(vm.selectedTargetIDs.count)", color: .orange)
                    
                    Picker("", selection: $vm.sortMode) {
                        ForEach(CHOPCHOPCompareViewModel.CHOPCHOPSortMode.allCases) { m in
                            Text(verbatim: m.rawValue).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 220)
                    
                    Button("全选", action: vm.selectAll)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("清空", action: vm.deselectAll)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    
                    Button(action: vm.addSelectedToCart) {
                        Label("加入引物池", systemImage: "cart.badge.plus")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                    .disabled(vm.selectedTargetIDs.isEmpty)
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
        
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { isChecked },
                set: { _ in vm.toggleTarget(target) }
            ))
            .labelsHidden()
            
            Text(verbatim: "#\(target.rank)")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .leading)
            
            HStack(spacing: 1) {
                Text(verbatim: target.spacer)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(isPrimaryHit ? .green : (isChecked ? .orange : .primary))
                Text(verbatim: target.pam)
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange)
            }
            .textSelection(.enabled)
            
            Button(action: { vm.copySpacer(target) }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            
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
            }
            
            Spacer()
            
            Text(verbatim: "\(target.genomicLocation) (\(target.strand))")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
            
            Text(verbatim: "GC \(String(format: "%.0f", target.gcContent))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            
            StudioMetricBadge(
                label: "脱靶",
                value: target.offTargetSummary,
                color: target.isHighlySpecific ? .green : .orange
            )
            
            StudioMetricBadge(
                label: "效率",
                value: String(format: "%.1f", target.efficiency),
                color: .blue
            )
            
            TargetScoreBadge(score: target.combinedScore, compact: true)
            
            Button(action: { vm.addPairToCart(target) }) {
                Image(systemName: "cart.badge.plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(rowBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(rowBorder, lineWidth: isPrimaryHit ? 1.5 : 1.0)
        )
    }
}
