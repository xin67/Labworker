import CloneStudioCore
import SwiftUI
import AppKit

/// 质粒大片段删除与敲除设计界面 (载入 .dna 后直接支持按特征、按已有引物对、按起止坐标、按序列定位删除区)
public struct FragmentDeletionView: View {
    @ObservedObject private var vm = WorkspaceSessionManager.shared.fragmentDeletionVM
    @ObservedObject private var appState = AppState.shared
    
    public init() {}
    
    private var previewData: PlasmidConstructPreviewData? {
        if let res = vm.designResult, !vm.primers.isEmpty,
           let delPreview = PlasmidMapBuilder.forFragmentDeletion(
               plasmidName: vm.selectedDNAFileName.isEmpty ? "Target-Plasmid" : vm.selectedDNAFileName,
               originalLength: BioSequence.clean(vm.plasmidSeq).count,
               delStart: res.delStart,
               delEnd: res.delEnd,
               newPlasmidSeq: res.newPlasmidSeq,
               primers: vm.primers
           ) {
            return delPreview
        }
        if let info = vm.plasmidDNAInfo {
            let s = max(1, Int(vm.delStartText.trimmingCharacters(in: .whitespaces)) ?? 1)
            let e = max(s, Int(vm.delEndText.trimmingCharacters(in: .whitespaces)) ?? s)
            return PlasmidMapBuilder.forRawSnapGeneFile(
                info: info,
                highlightRange: s...min(max(1, info.length), e)
            )
        }
        return nil
    }
    
    public var body: some View {
        StudioPageLayout(
            title: "质粒片段删除",
            toolbar: [
                .plasmidToggle(isOn: $appState.showPlasmidPreview, isAvailable: previewData != nil),
                .plasmidFile(
                    id: "deletion_plasmid_file",
                    roleTitle: "质粒",
                    tint: .purple,
                    info: vm.plasmidDNAInfo,
                    onLoadURL: { url in Task { await vm.loadDNAFile(url: url) } },
                    onPreview: {
                        if let info = vm.plasmidDNAInfo {
                            PlasmidWindowPresenter.shared.openPreviewWindow(for: info, roleLabel: "原始质粒预览", highlightRange: nil)
                        }
                    }
                ),
                .action(title: "示例", icon: "sparkles", help: "载入质粒片段删除示例", action: vm.loadSampleData),
                .action(id: "clear_deletion", title: "", icon: "trash", tint: .red, help: "清空当前删除配置", action: vm.clear)
            ]
        ) {
                
                // 2. 主体区
                AdaptiveTwoColumnWorkspace(hasRight: previewData != nil && appState.showPlasmidPreview) {
                    VStack(alignment: .leading, spacing: 12) {
                        let cleanPlasmid = BioSequence.clean(vm.plasmidSeq)
                        let plasmidBp = cleanPlasmid.count
                        
                        // 1. 质粒原始序列
                        StudioCard(title: "1. 质粒序列") {
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                if !vm.selectedDNAFileName.isEmpty {
                                    Text(vm.selectedDNAFileName)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .monospacedDigit()
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                                        .foregroundColor(.purple)
                                }
                                if let info = vm.plasmidDNAInfo {
                                    FinderRevealButton(filePath: info.filePath, label: "")
                                    StudioActionPillButton(
                                        title: "预览",
                                        icon: "eye.fill",
                                        tint: .purple,
                                        isProminent: true,
                                        help: "打开质粒图谱预览"
                                    ) {
                                        PlasmidWindowPresenter.shared.openPreviewWindow(
                                            for: info,
                                            roleLabel: "原始质粒预览",
                                            highlightRange: nil
                                        )
                                    }
                                }
                                StudioMetricBadge(label: "全长", value: "\(plasmidBp) bp", color: plasmidBp >= 100 ? .green : .orange)
                                StudioSectionClearButton(label: "一键清除质粒", action: vm.clearPlasmidSection)
                            }
                        } content: {
                            SequenceEditorBox(
                                text: $vm.plasmidSeq,
                                placeholder: "输入或拖入质粒序列",
                                minHeight: 85
                            )
                        }
                        
                        // 2. 待删除片段四维定位方式
                        StudioCard(title: "删除区间定位") {
                            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                ViewThatFits(in: .horizontal) {
                                    StudioSegmentedPicker(
                                        selection: $vm.selectionMode,
                                        options: FragmentDeletionViewModel.SelectionMode.allCases.map {
                                            StudioSegmentedOption(value: $0, title: $0.rawValue, tint: .purple)
                                        }
                                    )
                                    StudioSegmentedPicker(
                                        selection: $vm.selectionMode,
                                        options: FragmentDeletionViewModel.SelectionMode.allCases.map {
                                            StudioSegmentedOption(value: $0, title: $0.shortTitle, tint: .purple)
                                        }
                                    )
                                }
                                StudioSectionClearButton(label: "一键清除定位", action: vm.clearDeletionTargetSection)
                            }
                        } content: {
                            VStack(alignment: .leading, spacing: 10) {
                                switch vm.selectionMode {
                                case .byFeature:
                                    let feats = vm.sortedFeatures
                                    if !feats.isEmpty {
                                        ViewThatFits(in: .horizontal) {
                                            HStack(spacing: 8) {
                                                Text("选择要敲除/删除的特征:")
                                                    .font(.system(size: 11.5, weight: .medium))
                                                    .fixedSize()
                                                Picker("", selection: Binding(
                                                    get: { vm.selectedDeleteFeatureID },
                                                    set: { id in vm.selectDeleteFeature(id: id) }
                                                )) {
                                                    ForEach(feats) { f in
                                                        let s = f.segments.first?.start ?? 1
                                                        let e = f.segments.last?.end ?? 1
                                                        let dir = f.directionality == "2" ? "←" : "→"
                                                        Text("\(f.name) [\(s)..\(e), \(e - s + 1) bp \(dir)] (\(f.type))").tag(f.id)
                                                    }
                                                }
                                                .labelsHidden()
                                                .frame(maxWidth: 360)
                                                Spacer()
                                            }
                                            
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text("选择要敲除/删除的特征:")
                                                    .font(.system(size: 11.5, weight: .medium))
                                                Picker("", selection: Binding(
                                                    get: { vm.selectedDeleteFeatureID },
                                                    set: { id in vm.selectDeleteFeature(id: id) }
                                                )) {
                                                    ForEach(feats) { f in
                                                        let s = f.segments.first?.start ?? 1
                                                        let e = f.segments.last?.end ?? 1
                                                        let dir = f.directionality == "2" ? "←" : "→"
                                                        Text("\(f.name) [\(s)..\(e), \(e - s + 1) bp \(dir)] (\(f.type))").tag(f.id)
                                                    }
                                                }
                                                .labelsHidden()
                                                .frame(maxWidth: .infinity)
                                            }
                                        }
                                    } else {
                                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                            StudioActionPillButton(
                                                title: "载入 .dna",
                                                icon: "folder.badge.plus",
                                                tint: .purple,
                                                isProminent: true,
                                                help: "从 Finder 载入质粒 .dna 文件"
                                            ) {
                                                FinderFileDropHelper.selectDNAFile(prompt: "载入质粒") { url in
                                                    Task { await vm.loadDNAFile(url: url) }
                                                }
                                            }

                                            StudioActionPillButton(title: "按坐标定位", icon: "number") {
                                                vm.selectionMode = .byCoordinates
                                            }

                                            StudioActionPillButton(title: "按序列定位", icon: "textformat") {
                                                vm.selectionMode = .bySequence
                                            }
                                        }
                                    }
                                    
                                case .byPrimers:
                                    let bps = vm.boundPrimers
                                    if bps.count >= 2 {
                                        ViewThatFits(in: .horizontal) {
                                            HStack(spacing: 8) {
                                                Text("上游反向 (←):")
                                                    .font(.system(size: 11.5))
                                                    .fixedSize()
                                                Picker("", selection: Binding(
                                                    get: { vm.selectedDelRevPrimerID },
                                                    set: { id in
                                                        vm.selectedDelRevPrimerID = id
                                                        vm.applyDeletePrimerPair()
                                                    }
                                                )) {
                                                    ForEach(bps) { p in
                                                        Text(p.displayLabel).tag(p.id)
                                                    }
                                                }
                                                .labelsHidden()
                                                .frame(maxWidth: 200)
                                                
                                                Text("下游正向 (→):")
                                                    .font(.system(size: 11.5))
                                                    .fixedSize()
                                                Picker("", selection: Binding(
                                                    get: { vm.selectedDelFwdPrimerID },
                                                    set: { id in
                                                        vm.selectedDelFwdPrimerID = id
                                                        vm.applyDeletePrimerPair()
                                                    }
                                                )) {
                                                    ForEach(bps) { p in
                                                        Text(p.displayLabel).tag(p.id)
                                                    }
                                                }
                                                .labelsHidden()
                                                .frame(maxWidth: 200)
                                                Spacer()
                                            }
                                            
                                            VStack(alignment: .leading, spacing: 6) {
                                                HStack(spacing: 8) {
                                                    Text("上游反向 (←):")
                                                        .font(.system(size: 11.5))
                                                        .frame(width: 85, alignment: .leading)
                                                    Picker("", selection: Binding(
                                                        get: { vm.selectedDelRevPrimerID },
                                                        set: { id in
                                                            vm.selectedDelRevPrimerID = id
                                                            vm.applyDeletePrimerPair()
                                                        }
                                                    )) {
                                                        ForEach(bps) { p in
                                                            Text(p.displayLabel).tag(p.id)
                                                        }
                                                    }
                                                    .labelsHidden()
                                                    .frame(maxWidth: .infinity)
                                                }
                                                
                                                HStack(spacing: 8) {
                                                    Text("下游正向 (→):")
                                                        .font(.system(size: 11.5))
                                                        .frame(width: 85, alignment: .leading)
                                                    Picker("", selection: Binding(
                                                        get: { vm.selectedDelFwdPrimerID },
                                                        set: { id in
                                                            vm.selectedDelFwdPrimerID = id
                                                            vm.applyDeletePrimerPair()
                                                        }
                                                    )) {
                                                        ForEach(bps) { p in
                                                            Text(p.displayLabel).tag(p.id)
                                                        }
                                                    }
                                                    .labelsHidden()
                                                    .frame(maxWidth: .infinity)
                                                }
                                            }
                                        }
                                    } else {
                                        HStack(spacing: 8) {
                                            StudioActionPillButton(title: "按特征定位", icon: "tag") {
                                                vm.selectionMode = .byFeature
                                            }
                                            StudioActionPillButton(title: "按坐标定位", icon: "number") {
                                                vm.selectionMode = .byCoordinates
                                            }
                                        }
                                    }
                                    
                                case .byCoordinates:
                                    EmptyView()
                                    
                                case .bySequence:
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("粘贴待删除子片段序列 (支持正向或反向互补自动搜索)")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.secondary)
                                        SequenceEditorBox(
                                            text: $vm.targetDelSeq,
                                            placeholder: "粘贴待敲除的结构域、标签或特定片段序列...",
                                            minHeight: 65
                                        )
                                        
                                        let cleanDel = BioSequence.clean(vm.targetDelSeq)
                                        if !cleanDel.isEmpty {
                                            if let range = cleanPlasmid.range(of: cleanDel) {
                                                let s = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.lowerBound) + 1
                                                let e = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.upperBound)
                                                Label("已正向匹配: 第 \(s) ~ \(e) bp (共 \(cleanDel.count) bp)", systemImage: "checkmark.circle.fill")
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                    .foregroundColor(.green)
                                            } else {
                                                let rc = BioSequence.reverseComplement(cleanDel)
                                                if let range = cleanPlasmid.range(of: rc) {
                                                    let s = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.lowerBound) + 1
                                                    let e = cleanPlasmid.distance(from: cleanPlasmid.startIndex, to: range.upperBound)
                                                    Label("已反向互补匹配: 第 \(s) ~ \(e) bp (共 \(cleanDel.count) bp)", systemImage: "checkmark.circle.fill")
                                                        .font(.system(size: 11.5, weight: .semibold))
                                                        .foregroundColor(.green)
                                                } else {
                                                    Label("质粒中未找到该序列片段，请核对输入", systemImage: "exclamationmark.triangle.fill")
                                                        .font(.system(size: 11))
                                                        .foregroundColor(.orange)
                                                }
                                            }
                                        }
                                    }
                                }
                                
                                if vm.selectionMode != .bySequence {
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 16) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("起始坐标 (1-based)")
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(.secondary)
                                                TextField("例如 3382", text: $vm.delStartText)
                                                    .textFieldStyle(.roundedBorder)
                                                    .font(.system(size: 12.5, weight: .semibold))
                                                    .monospacedDigit()
                                                    .frame(width: 130)
                                            }
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("终止坐标 (1-based)")
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(.secondary)
                                                TextField("例如 4371", text: $vm.delEndText)
                                                    .textFieldStyle(.roundedBorder)
                                                    .font(.system(size: 12.5, weight: .semibold))
                                                    .monospacedDigit()
                                                    .frame(width: 130)
                                            }
                                            
                                            if let s = Int(vm.delStartText), let e = Int(vm.delEndText), s >= 1, e <= plasmidBp, s <= e {
                                                let delLen = e - s + 1
                                                let newLen = plasmidBp - delLen
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Label("待删除长度: \(delLen) bp", systemImage: "scissors")
                                                        .font(.system(size: 11.5, weight: .semibold))
                                                        .foregroundColor(.purple)
                                                    Text("敲除后预计质粒: \(newLen) bp")
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            Spacer()
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(spacing: 12) {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text("起始坐标 (1-based)")
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundColor(.secondary)
                                                    TextField("例如 3382", text: $vm.delStartText)
                                                        .textFieldStyle(.roundedBorder)
                                                        .font(.system(size: 12.5, weight: .semibold))
                                                        .monospacedDigit()
                                                        .frame(maxWidth: .infinity)
                                                }
                                                
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text("终止坐标 (1-based)")
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundColor(.secondary)
                                                    TextField("例如 4371", text: $vm.delEndText)
                                                        .textFieldStyle(.roundedBorder)
                                                        .font(.system(size: 12.5, weight: .semibold))
                                                        .monospacedDigit()
                                                        .frame(maxWidth: .infinity)
                                                }
                                            }
                                            
                                            if let s = Int(vm.delStartText), let e = Int(vm.delEndText), s >= 1, e <= plasmidBp, s <= e {
                                                let delLen = e - s + 1
                                                let newLen = plasmidBp - delLen
                                                HStack(spacing: 12) {
                                                    Label("待删除: \(delLen) bp", systemImage: "scissors")
                                                        .font(.system(size: 11.5, weight: .semibold))
                                                        .foregroundColor(.purple)
                                                    Text("敲除后: \(newLen) bp")
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        // 3. 重组同源臂长度配置
                        StudioCard(title: "3. 同源臂长度") {
                            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                StudioSegmentedPicker(
                                    selection: $vm.homologyLength,
                                    options: [15, 18, 20, 25].map {
                                        StudioSegmentedOption(value: $0, title: "\($0) bp", tint: .purple)
                                    }
                                )
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
                                Text("目标 Tm: \(String(format: "%.1f", appState.mutationTargetTm)) ± \(String(format: "%.1f", appState.tmTolerance)) ℃")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // 4. 参考图2对称全宽主操作栏
                        HStack(spacing: 10) {
                            StudioPrimaryActionButton(
                                title: "设计反向 PCR 缺失引物",
                                icon: "scissors",
                                tint: .purple,
                                isLoading: vm.isDesigning,
                                isDisabled: plasmidBp < 100,
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
                        
                        // 5. 生成的反向 PCR 缺失引物
                        if !vm.primers.isEmpty {
                            StudioCard(title: "生成的反向 PCR 缺失引物") {
                                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                                    StudioMetricBadge(label: "数量", value: "\(vm.primers.count) 条", color: .purple)
                                    if let res = vm.designResult {
                                        StudioMetricBadge(label: "删除长度", value: "\(res.deletedLength) bp", color: .red)
                                        StudioMetricBadge(label: "产物全长", value: "\(res.newPlasmidSeq.count) bp", color: .green)
                                    }
                                    StudioSectionClearButton(label: "一键清除引物", action: vm.clearPrimersSection)
                                }
                            } content: {
                                VStack(alignment: .leading, spacing: 10) {
                                    if vm.primers.count >= 2 {
                                        PrimerPairQuickRenameBar(
                                            pairLabel: "质粒缺失引物对",
                                            currentPrefix: PrimerItem.extractPairPrefix(from: vm.primers[0].name),
                                            suggestedPrefix: "Deletion"
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
                    if let preview = previewData {
                        VStack(alignment: .leading, spacing: 12) {
                            PlasmidPreviewPanel(data: preview, onClose: {
                                appState.showPlasmidPreview = false
                            })
                            
                            StudioCard(title: "SnapGene 联动与导出") {
                                if !vm.selectedDNAFileName.isEmpty {
                                    StudioMetricBadge(label: "模板", value: vm.selectedDNAFileName, color: .purple)
                                }
                            } content: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 10) {
                                        StudioPrimaryActionButton(
                                            title: "导出并在 SnapGene 打开",
                                            icon: "arrow.up.forward.app",
                                            tint: .blue,
                                            isLoading: vm.isExporting,
                                            isDisabled: vm.selectedDNAFileURL == nil
                                        ) {
                                            Task { await vm.exportToSnapGene(openAfterExport: true) }
                                        }

                                        if vm.selectedDNAFileURL == nil {
                                            StudioActionPillButton(
                                                title: "载入 .dna",
                                                icon: "folder.badge.plus",
                                                help: "载入原始质粒 .dna 以导出产物"
                                            ) {
                                                FinderFileDropHelper.selectDNAFile(prompt: "载入质粒") { url in
                                                    Task { await vm.loadDNAFile(url: url) }
                                                }
                                            }
                                        }

                                        Spacer()
                                    }

                                    if let url = vm.lastExportedURL {
                                        HStack(spacing: 6) {
                                            Text("✅ 已导出: \(url.lastPathComponent)")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(.green)
                                            FinderRevealButton(filePath: url.path, label: "在 Finder 中显示")
                                        }
                                    }
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
        }
        .alert("提示", isPresented: $vm.showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(vm.alertMessage ?? "")
        }
        .onAppear {
            if let chained = AppState.shared.pendingChainedNode {
                let seq = BioSequence.clean(chained.productSequence)
                if seq.count >= 100 {
                    vm.plasmidSeq = seq
                    vm.selectedDNAFileName = chained.constructName
                    vm.selectionMode = .byCoordinates
                    vm.delStartText = "\(max(1, seq.count / 4))"
                    vm.delEndText = "\(max(10, seq.count / 2))"
                    vm.primers = []
                    vm.designResult = nil
                }
                AppState.shared.pendingChainedNode = nil
            }
        }
    }
}
