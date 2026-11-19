import SwiftUI
import AppKit
import CloneStudioCore

private final class SequenceSliceMemoBox {
    var signature: String = ""
    var activeWindow: MicroscopicSequenceWindow? = nil
    var slices: [SequenceRowSlice] = []
    var allCodons: [TranslatedCodonItem] = []
}

/// 1:1 复刻 CloneCanvas `DnaViewer.svelte` + `SequenceToolbar.svelte` + `SequenceRow.svelte`
/// 采用「LazyVStack 视口虚拟化 + 静态序列层 (.equatable) 与轻量选区浮层分离 + 拖拽期本地选区隔离」架构，实现 120Hz 零延迟丝滑选区
public struct SequenceRowCanvasView: View {
    @ObservedObject private var appState = AppState.shared
    
    public let totalLengthBp: Int
    public let fullSequence: String
    public let gcPercent: Double
    public let features: [PlasmidFeatureItem]
    public let enzymes: [PlasmidEnzymeMarker]
    public let detectedCutsites: [ConstructCutsite]
    public let windows: [MicroscopicSequenceWindow]
    public let fallbackJunctions: [PlasmidJunctionBlock]
    
    @Binding public var selectedRangeBp: ClosedRange<Int>?
    @Binding public var showEnzymeInspector: Bool
    public var onMutateCodon: ((InteractiveCodonMutationPayload) -> Void)? = nil
    
    /// -1 表示“全长序列模式 (Full Sequence Map)”，0..<windows.count 表示特定微观接头焦点窗口
    @State private var selectedWindowIndex: Int = -1
    @State private var showComplement: Bool = AppState.shared.defaultShowComplement
    @State private var showTranslation: Bool = AppState.shared.defaultShowTranslation
    @State private var showFeatures: Bool = AppState.shared.defaultShowFeatures
    @State private var showPrimers: Bool = AppState.shared.defaultShowPrimers
    @State private var showEnzymes: Bool = AppState.shared.defaultShowEnzymes
    @State private var colorizeBases: Bool = AppState.shared.defaultColorizeBases
    @State private var snapToCodonMode: Bool = AppState.shared.defaultSnapToCodonMode
    @State private var isUserDraggingSelection: Bool = false
    @State private var dragAnchorBp: Int? = nil
    @State private var dragStartedInCodonBand: Bool = false
    /// 拖拽过程中仅更新本地选区状态，松开鼠标时才同步给父视图 Binding，避免拖拽期间触发环形图和外部页面每帧重算
    @State private var liveDragRangeBp: ClosedRange<Int>? = nil
    @State private var customMutCodonText: String = ""
    
    /// 缩略图实时导航中心位点与滚动触发计数
    @State private var minimapCenterBp: Int = 1
    @State private var minimapScrubVersion: Int = 0
    
    /// 非 @State 引用缓存盒子（避免在 .onAppear / .onChange 中修改 @State 触发二级布局重绘）
    private let sliceMemo = SequenceSliceMemoBox()
    
    private var isDark: Bool {
        appState.resolvedCanvasIsDark()
    }
    
    /// 当前生效的选区（拖拽期间优先使用本地高频状态）
    private var effectiveSelectedRangeBp: ClosedRange<Int>? {
        liveDragRangeBp ?? selectedRangeBp
    }
    
    public init(
        totalLengthBp: Int,
        fullSequence: String = "",
        gcPercent: Double = 50.0,
        features: [PlasmidFeatureItem],
        enzymes: [PlasmidEnzymeMarker],
        detectedCutsites: [ConstructCutsite] = [],
        windows: [MicroscopicSequenceWindow],
        fallbackJunctions: [PlasmidJunctionBlock] = [],
        selectedRangeBp: Binding<ClosedRange<Int>?> = .constant(nil),
        showEnzymeInspector: Binding<Bool> = .constant(false),
        onMutateCodon: ((InteractiveCodonMutationPayload) -> Void)? = nil
    ) {
        self.totalLengthBp = totalLengthBp
        self.fullSequence = fullSequence
        self.gcPercent = gcPercent
        self.features = features
        self.enzymes = enzymes
        self.detectedCutsites = detectedCutsites
        self.windows = windows
        self.fallbackJunctions = fallbackJunctions
        self._selectedRangeBp = selectedRangeBp
        self._showEnzymeInspector = showEnzymeInspector
        self.onMutateCodon = onMutateCodon
    }
    
    // MARK: - 窗口与切片构建（仅在序列/窗口切换/列宽变化时执行，拖拽选区时 0 开销）
    private func buildFullSequenceWindow() -> MicroscopicSequenceWindow? {
        let clean = BioSequence.clean(fullSequence)
        guard !clean.isEmpty else { return nil }
        let displaySeq = String(clean.prefix(15000))
        let maxOff = displaySeq.count
        
        var cuts: [MicroscopicEnzymeCut] = []
        cuts.reserveCapacity(detectedCutsites.count)
        for c in detectedCutsites where c.recognitionStart0Based < maxOff {
            cuts.append(
                MicroscopicEnzymeCut(
                    name: c.name,
                    topSnipOffset: min(maxOff, max(0, c.topSnip0Based)),
                    bottomSnipOffset: min(maxOff, max(0, c.bottomSnip0Based)),
                    recognitionRange: max(0, c.recognitionStart0Based)..<min(maxOff, c.recognitionEnd0Based),
                    colorHex: c.colorHex
                )
            )
        }
        
        let firstWin = windows.first
        let homRange: Range<Int>? = {
            guard let fw = firstWin, fw.startBp <= 60, let hr = fw.homologyHighlightRange else { return nil }
            let s = max(0, fw.startBp - 1 + hr.lowerBound)
            let e = min(maxOff, fw.startBp - 1 + hr.upperBound)
            return s < e ? (s..<e) : nil
        }()
        let focRange: Range<Int>? = {
            guard let fw = firstWin, fw.startBp <= 60, let fr = fw.focalHighlightRange else { return nil }
            let s = max(0, fw.startBp - 1 + fr.lowerBound)
            let e = min(maxOff, fw.startBp - 1 + fr.upperBound)
            return s < e ? (s..<e) : nil
        }()
        
        var fullPrimers: [MicroscopicPrimerOverlay] = []
        var seenPrimerKeys: Set<String> = []
        for win in windows {
            let baseShift = max(0, win.startBp - 1)
            for p in win.primers {
                let gStart = min(maxOff, max(0, baseShift + p.startOffset))
                let gEnd = min(maxOff, max(gStart, baseShift + p.endOffset))
                guard gStart < gEnd else { continue }
                let key = "\(p.name)_\(gStart)_\(gEnd)"
                if !seenPrimerKeys.contains(key) {
                    seenPrimerKeys.insert(key)
                    fullPrimers.append(
                        MicroscopicPrimerOverlay(
                            name: p.name,
                            isForward: p.isForward,
                            startOffset: gStart,
                            endOffset: gEnd,
                            homologyArmLength: p.homologyArmLength,
                            tmText: p.tmText,
                            sequence: p.sequence
                        )
                    )
                }
            }
        }
        
        return MicroscopicSequenceWindow(
            title: "全长图谱序列",
            subtitle: "1..\(displaySeq.count) bp 全景双链与内切酶图谱",
            startBp: 1,
            sequence: displaySeq,
            homologyHighlightRange: homRange,
            homologyLabel: firstWin?.homologyLabel ?? "18 bp 同源臂",
            focalHighlightRange: focRange,
            focalLabel: firstWin?.focalLabel ?? "核心重组区",
            enzymeCuts: cuts,
            primers: fullPrimers,
            readingFrameOffset: 0
        )
    }
    
    private func resolveActiveWindow() -> MicroscopicSequenceWindow? {
        if selectedWindowIndex == -1 {
            if let fullWin = buildFullSequenceWindow() {
                return fullWin
            }
            return windows.first
        }
        if windows.indices.contains(selectedWindowIndex) {
            let baseWin = windows[selectedWindowIndex]
            let winStart0 = max(0, baseWin.startBp - 1)
            let winEnd0 = winStart0 + baseWin.sequence.count
            var mergedCuts = baseWin.enzymeCuts
            for c in detectedCutsites {
                if c.topSnip0Based >= winStart0 && c.topSnip0Based <= winEnd0 {
                    let localTop = c.topSnip0Based - winStart0
                    let localBot = min(baseWin.sequence.count, max(0, c.bottomSnip0Based - winStart0))
                    if !mergedCuts.contains(where: { $0.name == c.name && abs($0.topSnipOffset - localTop) <= 2 }) {
                        mergedCuts.append(
                            MicroscopicEnzymeCut(
                                name: c.name,
                                topSnipOffset: localTop,
                                bottomSnipOffset: localBot,
                                recognitionRange: max(0, c.recognitionStart0Based - winStart0)..<min(baseWin.sequence.count, c.recognitionEnd0Based - winStart0),
                                colorHex: c.colorHex
                            )
                        )
                    }
                }
            }
            return MicroscopicSequenceWindow(
                id: baseWin.id,
                title: baseWin.title,
                subtitle: baseWin.subtitle,
                startBp: baseWin.startBp,
                sequence: baseWin.sequence,
                homologyHighlightRange: baseWin.homologyHighlightRange,
                homologyLabel: baseWin.homologyLabel,
                focalHighlightRange: baseWin.focalHighlightRange,
                focalLabel: baseWin.focalLabel,
                enzymeCuts: mergedCuts,
                primers: baseWin.primers,
                readingFrameOffset: baseWin.readingFrameOffset
            )
        }
        return windows.first
    }
    
    private func ensureSlicesMemo(basesPerRow: Int) -> SequenceSliceMemoBox {
        let sig = "\(selectedWindowIndex)_\(basesPerRow)_\(totalLengthBp)_\(fullSequence.count)_\(windows.count)_\(detectedCutsites.count)"
        if sliceMemo.signature == sig, sliceMemo.activeWindow != nil {
            return sliceMemo
        }
        sliceMemo.signature = sig
        if let win = resolveActiveWindow() {
            sliceMemo.activeWindow = win
            sliceMemo.slices = SequenceRowLayout.sliceWindow(win, basesPerRow: basesPerRow)
            sliceMemo.allCodons = CodonTranslator.translateSequence(win.sequence, readingFrameOffset: win.readingFrameOffset)
        } else {
            sliceMemo.activeWindow = nil
            sliceMemo.slices = []
            sliceMemo.allCodons = []
        }
        return sliceMemo
    }
    
    // MARK: - 颜色主题（对齐系统设置浅色白底/深色黑灰底）
    private var canvasBgColor: Color {
        StudioPalette.cardBg(isLight: !isDark)
    }
    private var headerBgColor: Color {
        StudioPalette.trackBg(isLight: !isDark)
    }
    private var subBarBgColor: Color {
        StudioPalette.controlSubtleBg(isLight: !isDark)
    }
    private var primaryTextColor: Color {
        isDark ? .white : .primary
    }
    private var secondaryTextColor: Color {
        .secondary
    }
    private var borderStrokeColor: Color {
        StudioPalette.cardBorder(isLight: !isDark)
    }
    
    private var minimapViewportRangeBp: ClosedRange<Int> {
        let maxBp = max(1, totalLengthBp)
        if selectedWindowIndex >= 0, windows.indices.contains(selectedWindowIndex) {
            let w = windows[selectedWindowIndex]
            return max(1, min(w.startBp, maxBp))...max(1, min(w.endBp, maxBp))
        }
        let center = effectiveSelectedRangeBp?.lowerBound ?? minimapCenterBp
        let halfSpan = max(90, min(220, maxBp / 20))
        let s = max(1, min(center - halfSpan, max(1, maxBp - halfSpan * 2)))
        let e = min(maxBp, s + halfSpan * 2)
        return s...max(s, e)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sequenceTopBar
            sequenceMinimapBar
            sequenceMainWorkspace
            
            if onMutateCodon != nil,
               let activeWin = sliceMemo.activeWindow ?? resolveActiveWindow(),
               let codonHit = resolvedSelectedCodon(in: activeWin) {
                interactiveCodonMutatorBar(win: activeWin, codonItem: codonHit.item, residueNumber: codonHit.residueNumber)
            }
            
            sequenceBottomStatusBar
        }
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                .fill(canvasBgColor)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                        .stroke(borderStrokeColor, lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous))
        .environment(\.colorScheme, isDark ? .dark : .light)
    }
    
    private var sequenceMinimapBar: some View {
        SequenceMinimapView(
            totalLengthBp: totalLengthBp,
            features: features,
            enzymes: enzymes,
            windows: windows,
            selectedWindowIndex: $selectedWindowIndex,
            viewportRangeBp: minimapViewportRangeBp,
            onNavigateToBp: { targetBp in
                if !fullSequence.isEmpty && selectedWindowIndex != -1 {
                    selectedWindowIndex = -1
                }
                minimapCenterBp = targetBp
                minimapScrubVersion &+= 1
            }
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(subBarBgColor)
    }
    
    private var sequenceMainWorkspace: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                leftVerticalToolbar
                
                Divider().background(borderStrokeColor)
                
                GeometryReader { geo in
                    let rawWidth = geo.size.width
                    let effectiveWidth = rawWidth >= 180.0 ? rawWidth : 440.0
                    let rowViewportWidth = max(220.0, effectiveWidth - 16.0)
                    let rawPerRow = SequenceRowLayout.optimalBasesPerRow(
                        forWidth: Double(rowViewportWidth),
                        leftMargin: 28.0,
                        rightMargin: 36.0,
                        charWidth: 8.8
                    )
                    // 量化每行碱基数步进为 10，彻底避免滚动条显隐微调宽度引起 perRow 振荡
                    let perRow = max(30, min(100, (rawPerRow / 10) * 10))
                    sequenceScrollContent(rowViewportWidth: rowViewportWidth, perRow: perRow)
                }
            }
            
            if showEnzymeInspector {
                RestrictionEnzymeInspectorView(
                    detectedCutsites: detectedCutsites,
                    onSelectCutsite: { cut in
                        isUserDraggingSelection = false
                        liveDragRangeBp = nil
                        selectedWindowIndex = -1
                        let s = max(1, cut.recognitionStart0Based + 1)
                        let e = max(s, cut.recognitionEnd0Based)
                        selectedRangeBp = s...e
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showEnzymeInspector = false
                        }
                    }
                )
                .padding(.top, 6)
                .padding(.trailing, 10)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(minHeight: 280, idealHeight: 380, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func sequenceScrollContent(rowViewportWidth: CGFloat, perRow: Int) -> some View {
        let memo = ensureSlicesMemo(basesPerRow: perRow)
        let activeWin = memo.activeWindow
        let slicesToRender = memo.slices
        let currentSel = effectiveSelectedRangeBp
        
        if let activeWin = activeWin {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        microLegendBar(for: activeWin)
                        
                        ForEach(slicesToRender) { slice in
                            let low = currentSel.map { max($0.lowerBound, slice.startBp) } ?? 1
                            let high = currentSel.map { min($0.upperBound, slice.endBp) } ?? 0
                            let rowSel: ClosedRange<Int>? = (currentSel != nil && low <= high) ? (low...high) : nil
                            let showBadgeHere = currentSel.map { $0.lowerBound >= slice.startBp && $0.lowerBound <= slice.endBp } ?? false
                            
                            SequenceSingleRowBlock(
                                window: activeWin,
                                slice: slice,
                                basesPerRow: perRow,
                                rowWidth: rowViewportWidth,
                                totalPlasmidBp: max(totalLengthBp, activeWin.sequence.count),
                                features: showFeatures ? features : [],
                                showComplement: showComplement,
                                showTranslation: showTranslation,
                                showPrimers: showPrimers,
                                showEnzymes: showEnzymes,
                                colorizeBases: colorizeBases,
                                snapToCodonMode: snapToCodonMode,
                                isDark: isDark,
                                rowSelectedRange: rowSel,
                                fullSelectedRange: showBadgeHere ? currentSel : nil,
                                onDragUpdate: { newRange in
                                    isUserDraggingSelection = true
                                    if liveDragRangeBp != newRange {
                                        liveDragRangeBp = newRange
                                    }
                                },
                                onDragCommit: { finalRange in
                                    liveDragRangeBp = nil
                                    minimapCenterBp = finalRange.lowerBound
                                    if selectedRangeBp != finalRange {
                                        selectedRangeBp = finalRange
                                    }
                                    DispatchQueue.main.async {
                                        isUserDraggingSelection = false
                                    }
                                },
                                dragAnchorBp: $dragAnchorBp,
                                dragStartedInCodonBand: $dragStartedInCodonBand
                            )
                            .id(slice.rowIndex)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(canvasBgColor)
                .onChange(of: selectedWindowIndex) { _, newIdx in
                    if newIdx >= 0, windows.indices.contains(newIdx) {
                        minimapCenterBp = windows[newIdx].startBp
                    }
                }
                .onChange(of: minimapScrubVersion) { _, _ in
                    let activeSlices = ensureSlicesMemo(basesPerRow: perRow).slices
                    guard !activeSlices.isEmpty else { return }
                    let target = minimapCenterBp
                    if let hit = activeSlices.first(where: { target >= $0.startBp && target <= $0.endBp })
                        ?? activeSlices.min(by: { abs($0.startBp - target) < abs($1.startBp - target) }) {
                        proxy.scrollTo(hit.rowIndex, anchor: .center)
                    }
                }
                .onChange(of: selectedRangeBp) { _, newRange in
                    guard !isUserDraggingSelection, liveDragRangeBp == nil, let r = newRange else { return }
                    minimapCenterBp = r.lowerBound
                    if let targetSlice = slicesToRender.first(where: { r.lowerBound >= $0.startBp && r.lowerBound <= $0.endBp }) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(targetSlice.rowIndex, anchor: .center)
                        }
                    }
                }
            }
        } else if !fallbackJunctions.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(fallbackJunctions) { junc in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(junc.title).font(.system(size: 10.5, weight: .bold)).foregroundColor(primaryTextColor)
                            HStack(spacing: 0) {
                                Text("5'- ").foregroundColor(.secondary)
                                Text(junc.leftSeq).foregroundColor(.cyan)
                                Text(junc.midSeq).foregroundColor(.red).bold()
                                Text(junc.rightSeq).foregroundColor(.green)
                                Text(" -3'").foregroundColor(.secondary)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                        }
                        .studioInnerBox(paddingH: 8, paddingV: 6)
                    }
                }
                .padding(8)
            }
            .background(canvasBgColor)
        }
    }
    
    // MARK: - 顶部 Sequence Map 标题栏
    private var sequenceTopBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Sequence Map")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(primaryTextColor)
                            .fixedSize(horizontal: true, vertical: false)
                        Text("Length: \(totalLengthBp) bp")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(secondaryTextColor)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Spacer(minLength: 4)

                    codonSnapModeToggleBtn
                    enzymeInspectorToggleBtn
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Sequence Map")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(primaryTextColor)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 4)
                        Text("Length: \(totalLengthBp) bp")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(secondaryTextColor)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    HStack(spacing: 6) {
                        codonSnapModeToggleBtn
                        enzymeInspectorToggleBtn
                        Spacer(minLength: 0)
                    }
                }
            }

            if !fullSequence.isEmpty || !windows.isEmpty {
                viewportSwitcherCapsules
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(headerBgColor)
    }
    
    private var codonSnapModeToggleBtn: some View {
        StudioCompactPillButton(
            title: snapToCodonMode ? "密码子滑选(3bp)" : "单碱基滑选(1bp)",
            icon: snapToCodonMode ? "character.textbox" : "textformat.abc.dottedunderline",
            tint: snapToCodonMode ? .pink : (isDark ? .cyan : .blue),
            isProminent: snapToCodonMode,
            isSelected: snapToCodonMode,
            help: "切换「按 3bp 密码子连续拉取选择」与「按 1bp 单碱基拉取选择」（在氨基酸密码子带上直接拉取始终按 3bp 对齐）"
        ) {
            snapToCodonMode.toggle()
        }
    }
    
    private var enzymeInspectorToggleBtn: some View {
        let accentCol = isDark ? Color.cyan : appState.accentTheme.color
        return StudioCompactPillButton(
            title: "Enzymes (\(detectedCutsites.count))",
            icon: "scissors",
            tint: accentCol,
            isProminent: showEnzymeInspector,
            isSelected: showEnzymeInspector,
            help: "打开/关闭限制性内切酶选择器与 NEB Buffer 活性矩阵"
        ) {
            withAnimation(.easeInOut(duration: 0.18)) {
                showEnzymeInspector.toggle()
            }
        }
    }
    
    @ViewBuilder
    private var viewportSwitcherCapsules: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    if !fullSequence.isEmpty {
                        let isFull = (selectedWindowIndex == -1)
                        let fullAccent: Color = isDark ? .cyan : .blue
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedWindowIndex = -1
                            }
                        }) {
                            Text("全长序列")
                                .font(.system(size: 10, weight: isFull ? .semibold : .medium))
                                .studioOptionalForeground(isFull ? nil : primaryTextColor.opacity(0.84))
                        }
                        .studioGlassButton(
                            tint: isFull ? fullAccent : nil,
                            isProminent: isFull,
                            isSelected: isFull,
                            controlSize: .small
                        )
                    }
                    
                    ForEach(Array(windows.enumerated()), id: \.element.id) { idx, win in
                        let isSel = (idx == selectedWindowIndex) || (fullSequence.isEmpty && idx == 0 && selectedWindowIndex == -1)
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedWindowIndex = idx
                            }
                        }) {
                            Text(win.title)
                                .font(.system(size: 10, weight: isSel ? .semibold : .medium))
                                .studioOptionalForeground(isSel ? nil : primaryTextColor.opacity(0.84))
                        }
                        .studioGlassButton(
                            tint: isSel ? .purple : nil,
                            isProminent: isSel,
                            isSelected: isSel,
                            controlSize: .small
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - 左侧垂直工具栏
    private var leftVerticalToolbar: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: 6) {
            toolbarIconBtn(
                icon: "cursorarrow.rays",
                isActive: effectiveSelectedRangeBp != nil,
                activeColor: isDark ? .cyan : .blue,
                tooltip: "拖拽碱基或密码子进行选区测量 (点击清除当前选区)"
            ) {
                liveDragRangeBp = nil
                selectedRangeBp = nil
            }
            
            toolbarIconBtn(
                icon: "tag.fill",
                isActive: showFeatures,
                activeColor: .blue,
                tooltip: "显示/隐藏基因功能元件方向条带 (Features)"
            ) {
                showFeatures.toggle()
            }
            
            toolbarIconBtn(
                icon: "scissors",
                isActive: showEnzymeInspector || showEnzymes,
                activeColor: .pink,
                tooltip: "打开限制性内切酶选择器与 NEB Buffer 矩阵"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showEnzymeInspector.toggle()
                }
            }
            
            toolbarIconBtn(
                icon: "arrow.left.and.right.square",
                isActive: showPrimers,
                activeColor: .purple,
                tooltip: "显示/隐藏 PCR 引物与 18bp 同源臂胶囊"
            ) {
                showPrimers.toggle()
            }
            
            toolbarIconBtn(
                icon: "character.textbox",
                isActive: showTranslation,
                activeColor: .green,
                tooltip: "显示/隐藏氨基酸三联体密码子翻译带 (AA Codons)"
            ) {
                showTranslation.toggle()
            }
            
            toolbarIconBtn(
                icon: "arrow.up.and.down.text.horizontal",
                isActive: showComplement,
                activeColor: .teal,
                tooltip: "显示/隐藏 3' 互补反义链"
            ) {
                showComplement.toggle()
            }
            
            toolbarIconBtn(
                icon: "paintpalette.fill",
                isActive: colorizeBases,
                activeColor: .orange,
                tooltip: "切换彩色/单色碱基配色"
            ) {
                colorizeBases.toggle()
            }
            
            Spacer()
            
            toolbarIconBtn(
                icon: "doc.on.doc",
                isActive: false,
                activeColor: .cyan,
                tooltip: "复制当前选中序列或窗口序列至剪贴板"
            ) {
                copyActiveSequence()
            }
        }
        }
        .padding(.vertical, 8)
        .frame(width: 30)
        .background(subBarBgColor)
    }
    
    private func toolbarIconBtn(
        icon: String,
        isActive: Bool,
        activeColor: Color,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: isActive ? .bold : .medium))
                .studioOptionalForeground(isActive ? nil : secondaryTextColor)
        }
        .studioGlassButton(
            tint: isActive ? activeColor : nil,
            isProminent: isActive,
            isSelected: isActive,
            isCircle: true,
            controlSize: .small
        )
        .help(tooltip)
    }
    
    private func copyActiveSequence() {
        guard let win = sliceMemo.activeWindow ?? resolveActiveWindow() else { return }
        let seqToCopy: String = {
            if let range = effectiveSelectedRangeBp {
                let s0 = max(0, range.lowerBound - win.startBp)
                let e0 = min(win.sequence.count, range.upperBound - win.startBp + 1)
                if s0 < e0 {
                    let sIdx = win.sequence.index(win.sequence.startIndex, offsetBy: s0)
                    let eIdx = win.sequence.index(win.sequence.startIndex, offsetBy: e0)
                    return String(win.sequence[sIdx..<eIdx])
                }
            }
            return win.sequence
        }()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(seqToCopy, forType: .string)
        appState.showToast("已复制 \(seqToCopy.count) bp 序列至剪贴板")
    }
    
    // MARK: - 底部状态栏
    private var sequenceBottomStatusBar: some View {
        let activeWin = sliceMemo.activeWindow ?? resolveActiveWindow()
        let selColor = isDark ? Color.cyan : Color(red: 0.02, green: 0.45, blue: 0.78)
        return HStack(spacing: 8) {
            if let sel = effectiveSelectedRangeBp, let win = activeWin {
                let len = sel.upperBound - sel.lowerBound + 1
                let tm = selectedSubsequenceTm(in: win, range: sel)
                let aaStr = selectedAminoAcidString(in: win, range: sel)
                let aaDisplay = aaStr.isEmpty ? "" : " · \(aaStr.count) aa (\(String(aaStr.prefix(16)))\(aaStr.count > 16 ? "..." : ""))"
                Text("Selected: \(sel.lowerBound) .. \(sel.upperBound) (\(len) bp\(aaDisplay) · Tm ≈ \(tm)°C)")
                    .font(.system(size: 9.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(selColor)
            } else {
                Text("直接按住密码子/氨基酸或碱基滑动拉取选区 · Length: \(totalLengthBp) bp · GC: \(String(format: "%.1f", gcPercent))%")
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundColor(secondaryTextColor)
            }
            
            Spacer()
            
            Text("\(detectedCutsites.count) cut sites | \(features.count) features")
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .foregroundColor(secondaryTextColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(headerBgColor)
    }
    
    private func selectedAminoAcidString(in win: MicroscopicSequenceWindow, range: ClosedRange<Int>) -> String {
        let codons = sliceMemo.allCodons.isEmpty
            ? CodonTranslator.translateSequence(win.sequence, readingFrameOffset: win.readingFrameOffset)
            : sliceMemo.allCodons
        guard !codons.isEmpty else { return "" }
        let sOff = max(0, range.lowerBound - win.startBp)
        let eOff = max(sOff, range.upperBound - win.startBp)
        let firstIdx = max(0, (sOff - win.readingFrameOffset) / 3)
        let lastIdx = min(codons.count - 1, (eOff - win.readingFrameOffset) / 3)
        guard firstIdx <= lastIdx, firstIdx < codons.count else { return "" }
        var out = ""
        out.reserveCapacity(lastIdx - firstIdx + 1)
        for i in firstIdx...lastIdx {
            out.append(codons[i].aminoAcid)
        }
        return out
    }
    
    private func selectedSubsequenceTm(in win: MicroscopicSequenceWindow, range: ClosedRange<Int>) -> Int {
        let s0 = max(0, range.lowerBound - win.startBp)
        let e0 = min(win.sequence.count, range.upperBound - win.startBp + 1)
        guard s0 < e0 else { return 0 }
        let startIdx = win.sequence.index(win.sequence.startIndex, offsetBy: s0)
        let endIdx = win.sequence.index(win.sequence.startIndex, offsetBy: e0)
        return SequenceRowLayout.estimateSelectionTm(String(win.sequence[startIdx..<endIdx]))
    }
    
    /// 根据当前选区 O(1) 定位对应的三联体密码子与氨基酸序号
    private func resolvedSelectedCodon(in win: MicroscopicSequenceWindow) -> (item: TranslatedCodonItem, residueNumber: Int)? {
        guard let sel = effectiveSelectedRangeBp else { return nil }
        let allCodons = sliceMemo.allCodons.isEmpty
            ? CodonTranslator.translateSequence(win.sequence, readingFrameOffset: win.readingFrameOffset)
            : sliceMemo.allCodons
        guard !allCodons.isEmpty else { return nil }
        let targetOffset0 = max(0, sel.lowerBound - win.startBp)
        let idx = (targetOffset0 - win.readingFrameOffset) / 3
        if idx >= 0 && idx < allCodons.count {
            return (allCodons[idx], idx + 1)
        }
        return nil
    }
    
    /// 预览内交互式密码子/氨基酸定点突变选择栏
    @ViewBuilder
    private func interactiveCodonMutatorBar(
        win: MicroscopicSequenceWindow,
        codonItem: TranslatedCodonItem,
        residueNumber: Int
    ) -> some View {
        let codonStartBp = win.startBp + codonItem.baseOffset
        let codonEndBp = codonStartBp + 2
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.pink)
                Text("定点突变选择: 第 \(residueNumber) 位氨基酸 \(codonItem.threeLetterCode) (\(String(codonItem.aminoAcid))) · 密码子 \(codonItem.codon) (@\(codonStartBp)..\(codonEndBp) bp)")
                    .font(.system(size: 10.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(primaryTextColor)
                Spacer()
                HStack(spacing: 4) {
                    TextField("自定义密码子/碱基", text: $customMutCodonText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .frame(width: 105)
                    StudioCompactPillButton(title: "应用自定义突变", tint: .pink, isProminent: true) {
                        let cleanCustom = BioSequence.clean(customMutCodonText)
                        let label = cleanCustom.isEmpty ? "Δ" : cleanCustom
                        triggerCodonMutation(win: win, codonItem: codonItem, residueNumber: residueNumber, targetCodon: cleanCustom, targetAA: label)
                    }
                }
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Text("突变为氨基酸:")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(secondaryTextColor)
                    ForEach(CodonTranslator.aminoAcidOptions) { opt in
                        let isWT = (opt.singleLetter == codonItem.aminoAcid)
                        Button(action: {
                            customMutCodonText = opt.preferredCodon
                            triggerCodonMutation(
                                win: win,
                                codonItem: codonItem,
                                residueNumber: residueNumber,
                                targetCodon: opt.preferredCodon,
                                targetAA: String(opt.singleLetter)
                            )
                        }) {
                            VStack(spacing: 1) {
                                Text("\(String(opt.singleLetter)) (\(opt.threeLetter))")
                                    .font(.system(size: 9.5, weight: .bold))
                                Text(opt.preferredCodon)
                                    .font(.system(size: 8.0))
                                    .opacity(0.85)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous)
                                    .fill(isWT ? Color.gray.opacity(0.45) : Color.pink.opacity(0.82))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("将 \(String(codonItem.aminoAcid))\(residueNumber) (\(codonItem.codon)) 突变为 \(opt.chineseName) \(String(opt.singleLetter)) (\(opt.preferredCodon))")
                    }
                    
                    Button(action: {
                        customMutCodonText = ""
                        triggerCodonMutation(
                            win: win,
                            codonItem: codonItem,
                            residueNumber: residueNumber,
                            targetCodon: "",
                            targetAA: "Δ缺失"
                        )
                    }) {
                        VStack(spacing: 1) {
                            Text("Δ 缺失")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("删除3bp")
                                .font(.system(size: 8.0))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: StudioRadius.inner, style: .continuous).fill(Color.orange.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isDark ? Color(red: 0.16, green: 0.06, blue: 0.14) : Color.pink.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.pink.opacity(0.45)), alignment: .top)
    }
    
    private func triggerCodonMutation(
        win: MicroscopicSequenceWindow,
        codonItem: TranslatedCodonItem,
        residueNumber: Int,
        targetCodon: String,
        targetAA: String
    ) {
        let codonStartBp = win.startBp + codonItem.baseOffset
        let codonEndBp = codonStartBp + 2
        let cleanFull = BioSequence.clean(fullSequence.isEmpty ? win.sequence : fullSequence)
        let sourceSeq = cleanFull.count >= (win.sequence.count) ? cleanFull : win.sequence
        let seqLen = max(1, sourceSeq.count)
        let doubled = sourceSeq + sourceSeq
        let flankLen = min(60, max(50, seqLen / 3))
        
        let start0 = fullSequence.isEmpty ? codonItem.baseOffset : max(0, min(seqLen - 1, codonStartBp - 1))
        let end0 = min(seqLen, start0 + 3)
        
        let upStart0 = (start0 - flankLen + seqLen) % seqLen
        let uSIdx = doubled.index(doubled.startIndex, offsetBy: upStart0)
        let uEIdx = doubled.index(uSIdx, offsetBy: flankLen)
        let up60 = String(doubled[uSIdx..<uEIdx])
        
        let downStart0 = end0 % seqLen
        let dSIdx = doubled.index(doubled.startIndex, offsetBy: downStart0)
        let dEIdx = doubled.index(dSIdx, offsetBy: flankLen)
        let down60 = String(doubled[dSIdx..<dEIdx])
        
        let payload = InteractiveCodonMutationPayload(
            windowTitle: win.title,
            startBp: codonStartBp,
            endBp: codonEndBp,
            residueIndex1Based: residueNumber,
            wildTypeCodon: codonItem.codon,
            wildTypeAA: codonItem.aminoAcid,
            targetCodon: targetCodon,
            targetAA: targetAA,
            upstreamFlank60Bp: up60,
            downstreamFlank60Bp: down60
        )
        if let callback = onMutateCodon {
            callback(payload)
        } else {
            appState.showToast("已选中突变 \(String(codonItem.aminoAcid))\(residueNumber)→\(targetAA) (\(codonItem.codon)→\(targetCodon.isEmpty ? "Δ" : targetCodon))")
        }
    }
    
    @ViewBuilder
    private func microLegendBar(for win: MicroscopicSequenceWindow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                microLegendBadges(for: win)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                microLegendBadges(for: win)
            }
        }
    }
    
    @ViewBuilder
    private func microLegendBadges(for win: MicroscopicSequenceWindow) -> some View {
        if win.homologyHighlightRange != nil {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.cyan.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.cyan, lineWidth: 1))
                    .frame(width: 10, height: 8)
                Text(win.homologyLabel.isEmpty ? "18 bp 同源重叠臂" : win.homologyLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isDark ? .cyan : .blue)
            }
        }
        
        if win.focalHighlightRange != nil {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.pink.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.pink, lineWidth: 1))
                    .frame(width: 10, height: 8)
                Text(win.focalLabel.isEmpty ? "目标突变/插入焦点" : win.focalLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.pink)
            }
        }
        
        if !win.enzymeCuts.isEmpty {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color(red: 0.92, green: 0.25, blue: 0.35))
                    .frame(width: 8, height: 2)
                Text("5'/3' 交错酶切线 (\(win.enzymeCuts.count))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(red: 0.90, green: 0.22, blue: 0.32))
            }
        }
    }
}

// MARK: - 静态底图与动态选区双层分离行组件 (拖拽期间静态文字层 0 重绘，选区浮层仅重绘当前激活行)
private struct SequenceSingleRowBlock: View {
    let window: MicroscopicSequenceWindow
    let slice: SequenceRowSlice
    let basesPerRow: Int
    let rowWidth: CGFloat
    let totalPlasmidBp: Int
    let features: [PlasmidFeatureItem]
    let showComplement: Bool
    let showTranslation: Bool
    let showPrimers: Bool
    let showEnzymes: Bool
    let colorizeBases: Bool
    let snapToCodonMode: Bool
    let isDark: Bool
    
    /// 当前行与选区的交集 (若未落在本行则为 nil，避免无关行重绘)
    let rowSelectedRange: ClosedRange<Int>?
    /// 若选区起点落在本行，则传入完整选区以绘制顶部统计胶囊
    let fullSelectedRange: ClosedRange<Int>?
    let onDragUpdate: (ClosedRange<Int>) -> Void
    let onDragCommit: (ClosedRange<Int>) -> Void
    
    @Binding var dragAnchorBp: Int?
    @Binding var dragStartedInCodonBand: Bool
    
    private let leftGutter: CGFloat = 26.0
    private let rightGutter: CGFloat = 38.0
    
    private var rowEnzymeCuts: [MicroscopicEnzymeCut] {
        guard showEnzymes else { return [] }
        return window.enzymeCuts.filter { cut in
            (cut.topSnipOffset >= slice.windowOffsetStart && cut.topSnipOffset <= slice.windowOffsetEnd) ||
            (cut.bottomSnipOffset >= slice.windowOffsetStart && cut.bottomSnipOffset <= slice.windowOffsetEnd)
        }
    }
    
    private var rowPrimers: [MicroscopicPrimerOverlay] {
        guard showPrimers else { return [] }
        return window.primers.filter { p in
            max(p.startOffset, slice.windowOffsetStart) < min(p.endOffset, slice.windowOffsetEnd)
        }
    }
    
    private var rowFeatures: [(feature: PlasmidFeatureItem, startBp: Int, endBp: Int)] {
        guard !features.isEmpty else { return [] }
        let total = max(1, totalPlasmidBp)
        var list: [(PlasmidFeatureItem, Int, Int)] = []
        for f in features {
            let fStart = max(1, Int((f.startRatio * Double(total)).rounded()) + 1)
            let fEnd = max(fStart, Int((f.endRatio * Double(total)).rounded()))
            if fEnd >= slice.startBp && fStart <= slice.endBp {
                list.append((f, max(fStart, slice.startBp), min(fEnd, slice.endBp)))
            }
        }
        return list
    }
    
    private var rowHeight: CGFloat {
        var h: CGFloat = 48.0
        if !rowEnzymeCuts.isEmpty { h += 28.0 }
        if !rowPrimers.isEmpty { h += 16.0 }
        if showComplement { h += 22.0 }
        if showTranslation && !slice.codons.isEmpty { h += 20.0 }
        if !rowFeatures.isEmpty { h += 20.0 }
        return h
    }
    
    private var codonBandStartY: CGFloat {
        var y: CGFloat = 2.0
        if !rowEnzymeCuts.isEmpty { y += 28.0 }
        y += 16.0
        if !rowPrimers.isEmpty { y += 16.0 }
        y += (showComplement ? 35.0 : 15.0)
        return y - 4.0
    }
    
    private func snapBpToCodonRange(_ bp: Int) -> ClosedRange<Int> {
        let minBp = window.startBp
        let maxBp = max(minBp, window.startBp + window.sequence.count - 1)
        let clamped = max(minBp, min(maxBp, bp))
        let offsetFromFrame = max(0, (clamped - window.startBp) - window.readingFrameOffset)
        let codonStart0 = window.readingFrameOffset + (offsetFromFrame / 3) * 3
        let cStartBp = max(minBp, min(maxBp, window.startBp + codonStart0))
        let cEndBp = max(cStartBp, min(maxBp, cStartBp + 2))
        return cStartBp...cEndBp
    }
    
    private func computeDraggedRange(at location: CGPoint, startLocation: CGPoint, cellW: CGFloat) -> ClosedRange<Int> {
        let colIdx = max(0, min(basesPerRow - 1, Int(floor((location.x - leftGutter) / cellW))))
        let effectiveRowStride = max(44.0, rowHeight + 6.0)
        let rowDelta = Int(floor(location.y / effectiveRowStride))
        let minWinBp = window.startBp
        let maxWinBp = max(minWinBp, window.startBp + window.sequence.count - 1)
        let rawTargetBp = max(minWinBp, min(maxWinBp, slice.startBp + rowDelta * basesPerRow + colIdx))
        
        if dragAnchorBp == nil {
            dragAnchorBp = rawTargetBp
            dragStartedInCodonBand = showTranslation && (startLocation.y >= codonBandStartY)
        }
        let anchor = dragAnchorBp ?? rawTargetBp
        let useCodonSnap = showTranslation && (snapToCodonMode || dragStartedInCodonBand)
        
        if useCodonSnap {
            let anchorCodon = snapBpToCodonRange(anchor)
            let currentCodon = snapBpToCodonRange(rawTargetBp)
            return min(anchorCodon.lowerBound, currentCodon.lowerBound)...max(anchorCodon.upperBound, currentCodon.upperBound)
        } else {
            return min(anchor, rawTargetBp)...max(anchor, rawTargetBp)
        }
    }
    
    var body: some View {
        let usableW = max(120.0, rowWidth - leftGutter - rightGutter)
        let baseCount = max(slice.topStrand.count, 1)
        let cellW = max(8.0, usableW / CGFloat(max(baseCount, basesPerRow)))
        
        ZStack(alignment: .topLeading) {
            // Layer 1: 静态 DNA 序列、标尺、内切酶与密码子底图 (.equatable() 保证拖拽选区时 0 重绘！)
            StaticSequenceRowCanvas(
                window: window,
                slice: slice,
                basesPerRow: basesPerRow,
                rowWidth: rowWidth,
                rowHeight: rowHeight,
                cellW: cellW,
                rowEnzymeCuts: rowEnzymeCuts,
                rowPrimers: rowPrimers,
                rowFeatures: rowFeatures,
                showComplement: showComplement,
                showTranslation: showTranslation,
                colorizeBases: colorizeBases,
                isDark: isDark
            )
            .equatable()
            
            // Layer 2: 轻量级选区高亮与密码子高亮浮层 (仅在当前行与选区有交集时绘制，耗时 < 0.1ms)
            if let rowSel = rowSelectedRange {
                SelectionOverlayCanvas(
                    window: window,
                    slice: slice,
                    rowWidth: rowWidth,
                    rowHeight: rowHeight,
                    cellW: cellW,
                    hasEnzymesInRow: !rowEnzymeCuts.isEmpty,
                    hasPrimersInRow: !rowPrimers.isEmpty,
                    showComplement: showComplement,
                    showTranslation: showTranslation,
                    isDark: isDark,
                    rowSelectedRange: rowSel,
                    fullSelectedRange: fullSelectedRange
                )
                .allowsHitTesting(false)
            }
        }
        .frame(width: rowWidth, height: rowHeight)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let newRange = computeDraggedRange(
                        at: value.location,
                        startLocation: value.startLocation,
                        cellW: cellW
                    )
                    onDragUpdate(newRange)
                }
                .onEnded { value in
                    let finalRange = computeDraggedRange(
                        at: value.location,
                        startLocation: value.startLocation,
                        cellW: cellW
                    )
                    dragAnchorBp = nil
                    dragStartedInCodonBand = false
                    onDragCommit(finalRange)
                }
        )
    }
}

// MARK: - Layer 1: 静态单行序列底图 (实现 Equatable，拖拽选区期间绝不触发重绘)
private struct StaticSequenceRowCanvas: View, Equatable {
    let window: MicroscopicSequenceWindow
    let slice: SequenceRowSlice
    let basesPerRow: Int
    let rowWidth: CGFloat
    let rowHeight: CGFloat
    let cellW: CGFloat
    let rowEnzymeCuts: [MicroscopicEnzymeCut]
    let rowPrimers: [MicroscopicPrimerOverlay]
    let rowFeatures: [(feature: PlasmidFeatureItem, startBp: Int, endBp: Int)]
    let showComplement: Bool
    let showTranslation: Bool
    let colorizeBases: Bool
    let isDark: Bool
    
    static func == (lhs: StaticSequenceRowCanvas, rhs: StaticSequenceRowCanvas) -> Bool {
        lhs.slice.rowIndex == rhs.slice.rowIndex &&
        lhs.slice.startBp == rhs.slice.startBp &&
        lhs.slice.endBp == rhs.slice.endBp &&
        lhs.rowWidth == rhs.rowWidth &&
        lhs.rowHeight == rhs.rowHeight &&
        lhs.showComplement == rhs.showComplement &&
        lhs.showTranslation == rhs.showTranslation &&
        lhs.colorizeBases == rhs.colorizeBases &&
        lhs.isDark == rhs.isDark &&
        lhs.rowEnzymeCuts.count == rhs.rowEnzymeCuts.count &&
        lhs.rowPrimers.count == rhs.rowPrimers.count &&
        lhs.rowFeatures.count == rhs.rowFeatures.count
    }
    
    private let leftGutter: CGFloat = 26.0
    private let rightGutter: CGFloat = 38.0
    
    var body: some View {
        let baseCount = max(slice.topStrand.count, 1)
        let subLabelColor = isDark ? Color.white.opacity(0.48) : Color(red: 0.38, green: 0.44, blue: 0.54)
        let rulerColor = isDark ? Color.teal : Color(red: 0.04, green: 0.48, blue: 0.56)
        
        Canvas { context, size in
            var currentY: CGFloat = 2.0
            
            // --- Track 1: 限制性内切酶名称与垂直引导虚线 ---
            if !rowEnzymeCuts.isEmpty {
                let labelItems = rowEnzymeCuts.enumerated().map { idx, cut -> (id: String, x0: Double, x1: Double, text: String) in
                    let x = Double(leftGutter + CGFloat(cut.topSnipOffset - slice.windowOffsetStart) * cellW)
                    let halfW = max(18.0, Double(cut.name.count) * 2.8 + 4.0)
                    return ("\(cut.name)_\(idx)", x - halfW, x + halfW, cut.name)
                }
                let yLevels = SequenceRowLayout.calculateLabelYOffsets(items: labelItems)
                
                for (idx, cut) in rowEnzymeCuts.enumerated() {
                    let key = "\(cut.name)_\(idx)"
                    let level = min(2, yLevels[key] ?? 0)
                    let cutX = leftGutter + CGFloat(cut.topSnipOffset - slice.windowOffsetStart) * cellW
                    let labelX = min(size.width - rightGutter - 18.0, max(leftGutter + 18.0, cutX))
                    let labelY = currentY + CGFloat(level) * 8.5 + 5.0
                    let enzCol = isDark ? Color(hexString: cut.colorHex) : Color(red: 0.82, green: 0.14, blue: 0.24)
                    
                    var guide = Path()
                    guide.move(to: CGPoint(x: cutX, y: labelY + 4.0))
                    guide.addLine(to: CGPoint(x: cutX, y: currentY + 28.0))
                    context.stroke(guide, with: .color(enzCol.opacity(0.60)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 1.5]))
                    
                    let badge = context.resolve(
                        Text(cut.name)
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(enzCol)
                    )
                    context.draw(badge, at: CGPoint(x: labelX, y: labelY), anchor: .center)
                }
                currentY += 28.0
            }
            
            // --- Track 2: 标尺轨道 ---
            let rulerY = currentY + 11.0
            var rulerBase = Path()
            rulerBase.move(to: CGPoint(x: leftGutter, y: rulerY))
            rulerBase.addLine(to: CGPoint(x: leftGutter + CGFloat(baseCount) * cellW, y: rulerY))
            context.stroke(rulerBase, with: .color(rulerColor.opacity(0.45)), lineWidth: 0.8)
            
            for i in 0..<baseCount {
                let globalBp = slice.startBp + i
                let xCenter = leftGutter + (CGFloat(i) + 0.5) * cellW
                let isMajor = (globalBp == 1) || (globalBp % 10 == 0)
                let isMinor = (globalBp % 5 == 0)
                
                if isMajor || isMinor {
                    var tick = Path()
                    tick.move(to: CGPoint(x: xCenter, y: rulerY))
                    tick.addLine(to: CGPoint(x: xCenter, y: rulerY - (isMajor ? 4.5 : 2.5)))
                    context.stroke(tick, with: .color(rulerColor.opacity(isMajor ? 0.85 : 0.45)), lineWidth: isMajor ? 1.0 : 0.7)
                }
                
                if isMajor {
                    let lbl = context.resolve(
                        Text("\(globalBp)")
                            .font(.system(size: 8.0, weight: .semibold))
                            .monospacedDigit()
                            .foregroundColor(rulerColor)
                    )
                    context.draw(lbl, at: CGPoint(x: xCenter, y: rulerY - 8.0), anchor: .center)
                }
            }
            currentY += 16.0
            
            // --- Track 3: 引物箭头 & 18bp 同源臂胶囊 ---
            if !rowPrimers.isEmpty {
                let primerY = currentY + 7.0
                for primer in rowPrimers {
                    let rowStartOff = slice.windowOffsetStart
                    let rowEndOff = slice.windowOffsetEnd
                    let pStart = max(primer.startOffset, rowStartOff)
                    let pEnd = min(primer.endOffset, rowEndOff)
                    if pStart < pEnd {
                        let x1 = leftGutter + CGFloat(pStart - rowStartOff) * cellW
                        let x2 = leftGutter + CGFloat(pEnd - rowStartOff) * cellW
                        let barRect = CGRect(x: x1, y: primerY - 5.0, width: max(6, x2 - x1), height: 10)
                        context.fill(Path(roundedRect: barRect, cornerRadius: 2.5), with: .color(Color.blue.opacity(isDark ? 0.28 : 0.18)))
                        context.stroke(Path(roundedRect: barRect, cornerRadius: 2.5), with: .color(primer.isForward ? Color.cyan : Color.orange), lineWidth: 0.9)
                        
                        let homRange: Range<Int> = primer.isForward
                            ? primer.startOffset..<min(primer.endOffset, primer.startOffset + primer.homologyArmLength)
                            : max(primer.startOffset, primer.endOffset - primer.homologyArmLength)..<primer.endOffset
                        let hStart = max(homRange.lowerBound, rowStartOff)
                        let hEnd = min(homRange.upperBound, rowEndOff)
                        if hStart < hEnd {
                            let hx1 = leftGutter + CGFloat(hStart - rowStartOff) * cellW
                            let hx2 = leftGutter + CGFloat(hEnd - rowStartOff) * cellW
                            let hRect = CGRect(x: hx1, y: primerY - 5.0, width: max(4, hx2 - hx1), height: 10)
                            context.fill(Path(roundedRect: hRect, cornerRadius: 2.5), with: .color(Color.purple.opacity(0.65)))
                        }
                        
                        let arrowSym = primer.isForward ? "▸" : "◂"
                        let pTxt = context.resolve(
                            Text("\(primer.isForward ? "" : arrowSym)\(primer.name)\(primer.isForward ? arrowSym : "")")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundColor(isDark ? .white : Color(red: 0.10, green: 0.14, blue: 0.24))
                        )
                        context.draw(pTxt, at: CGPoint(x: (x1 + x2) / 2.0, y: primerY), anchor: .center)
                    }
                }
                currentY += 16.0
            }
            
            // --- Track 4: 双链 DNA 碱基 + 同源臂高亮 + 5'/3' 交错酶切线 ---
            let topStrandY = currentY + 8.0
            let plusStrandY = topStrandY + 10.5
            let botStrandY = showComplement ? (topStrandY + 21.0) : topStrandY
            let boxH: CGFloat = showComplement ? 32.0 : 14.0
            
            let fivePrimeLbl = context.resolve(Text("5'").font(.system(size: 8.5, weight: .semibold)).monospacedDigit().foregroundColor(subLabelColor))
            let threePrimeLbl = context.resolve(Text("3'").font(.system(size: 8.5, weight: .semibold)).monospacedDigit().foregroundColor(subLabelColor))
            context.draw(fivePrimeLbl, at: CGPoint(x: 11, y: topStrandY), anchor: .center)
            if showComplement {
                context.draw(threePrimeLbl, at: CGPoint(x: 11, y: botStrandY), anchor: .center)
            }
            
            if let homRange = window.homologyHighlightRange {
                let hStart = max(homRange.lowerBound, slice.windowOffsetStart)
                let hEnd = min(homRange.upperBound, slice.windowOffsetEnd)
                if hStart < hEnd {
                    let x1 = leftGutter + CGFloat(hStart - slice.windowOffsetStart) * cellW
                    let x2 = leftGutter + CGFloat(hEnd - slice.windowOffsetStart) * cellW
                    let rect = CGRect(x: x1, y: topStrandY - 6.5, width: x2 - x1, height: boxH)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3.0), with: .color(Color.cyan.opacity(0.14)))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3.0), with: .color(Color.cyan.opacity(0.65)), lineWidth: 1.0)
                }
            }
            
            if let focalRange = window.focalHighlightRange {
                let fStart = max(focalRange.lowerBound, slice.windowOffsetStart)
                let fEnd = min(focalRange.upperBound, slice.windowOffsetEnd)
                if fStart < fEnd {
                    let x1 = leftGutter + CGFloat(fStart - slice.windowOffsetStart) * cellW
                    let x2 = leftGutter + CGFloat(fEnd - slice.windowOffsetStart) * cellW
                    let rect = CGRect(x: x1, y: topStrandY - 6.5, width: x2 - x1, height: boxH)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3.0), with: .color(Color.pink.opacity(0.18)))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 3.0), with: .color(Color.pink.opacity(0.85)), lineWidth: 1.1)
                }
            }
            
            let topChars = Array(slice.topStrand)
            let botChars = Array(slice.bottomStrand)
            let monoFallback = isDark ? Color.white.opacity(0.92) : Color(red: 0.10, green: 0.14, blue: 0.22)
            
            for i in 0..<topChars.count {
                let xCenter = leftGutter + (CGFloat(i) + 0.5) * cellW
                let topCh = topChars[i]
                let topColor = colorizeBases ? baseColor(for: topCh) : monoFallback
                
                let tResolved = context.resolve(
                    Text(String(topCh))
                        .font(.system(size: 10.0, weight: .bold, design: .monospaced))
                        .foregroundColor(topColor)
                )
                context.draw(tResolved, at: CGPoint(x: xCenter, y: topStrandY), anchor: .center)
                
                if showComplement && i < botChars.count {
                    if (i + 1) % 5 == 0 {
                        let plusRes = context.resolve(
                            Text("+")
                                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                .foregroundColor(subLabelColor.opacity(0.75))
                        )
                        context.draw(plusRes, at: CGPoint(x: xCenter, y: plusStrandY), anchor: .center)
                    }
                    
                    let botCh = botChars[i]
                    let botColor = colorizeBases ? baseColor(for: botCh).opacity(isDark ? 0.78 : 0.85) : monoFallback.opacity(0.68)
                    let bResolved = context.resolve(
                        Text(String(botCh))
                            .font(.system(size: 10.0, weight: .regular, design: .monospaced))
                            .foregroundColor(botColor)
                    )
                    context.draw(bResolved, at: CGPoint(x: xCenter, y: botStrandY), anchor: .center)
                }
            }
            
            let endX = leftGutter + CGFloat(topChars.count) * cellW + 17.0
            let rightLabel = context.resolve(
                Text("\(slice.endBp)")
                    .font(.system(size: 8.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(subLabelColor)
            )
            context.draw(rightLabel, at: CGPoint(x: endX, y: (topStrandY + botStrandY) / 2.0), anchor: .center)
            
            for cut in rowEnzymeCuts {
                let topInRow = cut.topSnipOffset >= slice.windowOffsetStart && cut.topSnipOffset <= slice.windowOffsetEnd
                let botInRow = cut.bottomSnipOffset >= slice.windowOffsetStart && cut.bottomSnipOffset <= slice.windowOffsetEnd
                
                let topX = leftGutter + CGFloat(cut.topSnipOffset - slice.windowOffsetStart) * cellW
                let botX = leftGutter + CGFloat(cut.bottomSnipOffset - slice.windowOffsetStart) * cellW
                let snipColor = isDark ? Color(hexString: cut.colorHex) : Color(red: 0.85, green: 0.14, blue: 0.24)
                
                if topInRow {
                    var vTop = Path()
                    vTop.move(to: CGPoint(x: topX, y: topStrandY - 6.5))
                    vTop.addLine(to: CGPoint(x: topX, y: plusStrandY))
                    context.stroke(vTop, with: .color(snipColor), lineWidth: 1.7)
                }
                
                if showComplement && botInRow {
                    var vBot = Path()
                    vBot.move(to: CGPoint(x: botX, y: plusStrandY))
                    vBot.addLine(to: CGPoint(x: botX, y: botStrandY + 6.5))
                    context.stroke(vBot, with: .color(snipColor), lineWidth: 1.7)
                }
                
                if showComplement && topInRow && botInRow && cut.topSnipOffset != cut.bottomSnipOffset {
                    var hConn = Path()
                    hConn.move(to: CGPoint(x: min(topX, botX), y: plusStrandY))
                    hConn.addLine(to: CGPoint(x: max(topX, botX), y: plusStrandY))
                    context.stroke(hConn, with: .color(snipColor), lineWidth: 1.7)
                }
            }
            
            currentY += (showComplement ? 35.0 : 15.0)
            
            // --- Track 5: 静态氨基酸密码子翻译带 ---
            if showTranslation && !slice.codons.isEmpty {
                let aaY = currentY + 7.0
                for (cIdx, codon) in slice.codons.enumerated() {
                    let localOffset = codon.baseOffset - slice.windowOffsetStart
                    guard localOffset >= 0 && localOffset + 3 <= topChars.count else { continue }
                    
                    let boxX = leftGutter + CGFloat(localOffset) * cellW + 0.8
                    let boxW = max(12.0, cellW * 3.0 - 1.6)
                    let boxRect = CGRect(x: boxX, y: aaY - 6.5, width: boxW, height: 13.0)
                    
                    let bgColor: Color = {
                        if codon.isStartCodon { return Color(red: 0.12, green: 0.58, blue: 0.38) }
                        if codon.isStopCodon { return Color(red: 0.78, green: 0.18, blue: 0.26) }
                        if isDark {
                            return (cIdx % 2 == 0)
                                ? Color(red: 0.44, green: 0.16, blue: 0.32).opacity(0.85)
                                : Color(red: 0.35, green: 0.15, blue: 0.38).opacity(0.85)
                        } else {
                            return (cIdx % 2 == 0)
                                ? Color(red: 0.58, green: 0.22, blue: 0.44).opacity(0.88)
                                : Color(red: 0.46, green: 0.22, blue: 0.52).opacity(0.88)
                        }
                    }()
                    
                    let strokeColor: Color = {
                        if codon.isStartCodon { return Color.green.opacity(0.85) }
                        if codon.isStopCodon { return Color.red.opacity(0.85) }
                        return Color(red: 0.72, green: 0.32, blue: 0.52).opacity(0.65)
                    }()
                    
                    context.fill(Path(roundedRect: boxRect, cornerRadius: 2.5), with: .color(bgColor))
                    context.stroke(Path(roundedRect: boxRect, cornerRadius: 2.5), with: .color(strokeColor), lineWidth: 0.7)
                    
                    let aaResolved = context.resolve(
                        Text(String(codon.aminoAcid))
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                    )
                    context.draw(aaResolved, at: CGPoint(x: boxX + boxW / 2.0, y: aaY), anchor: .center)
                }
                currentY += 19.0
            }
            
            // --- Track 6: 底部功能元件方向条带 + 蓝色胶囊标签 ---
            if !rowFeatures.isEmpty {
                let featY = currentY + 8.0
                for (idx, item) in rowFeatures.prefix(2).enumerated() {
                    let y = featY + CGFloat(idx) * 9.0
                    let x1 = leftGutter + CGFloat(item.startBp - slice.startBp) * cellW
                    let x2 = leftGutter + CGFloat(item.endBp - slice.startBp + 1) * cellW
                    let barRect = CGRect(x: x1, y: y - 4.0, width: max(8, x2 - x1), height: 8.0)
                    
                    context.fill(Path(roundedRect: barRect, cornerRadius: 2.0), with: .color(isDark ? Color.white.opacity(0.82) : Color(red: 0.78, green: 0.84, blue: 0.92)))
                    
                    let pillW = min(max(44.0, CGFloat(item.feature.name.count) * 5.8 + 14.0), max(44.0, x2 - x1))
                    let pillX = min(max(x1, (x1 + x2 - pillW) / 2.0), max(x1, x2 - pillW))
                    let pillRect = CGRect(x: pillX, y: y - 5.0, width: pillW, height: 10.0)
                    context.fill(Path(roundedRect: pillRect, cornerRadius: 3.0), with: .color(Color(red: 0.15, green: 0.39, blue: 0.92)))
                    
                    let dirArrow = item.feature.direction == .counterClockwise ? "◂ " : ""
                    let dirTail = item.feature.direction == .clockwise ? " ▸" : ""
                    let fTxt = context.resolve(
                        Text("\(dirArrow)\(item.feature.name)\(dirTail)")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(.white)
                    )
                    context.draw(fTxt, at: CGPoint(x: pillRect.midX, y: pillRect.midY), anchor: .center)
                }
            }
        }
        .frame(width: rowWidth, height: rowHeight)
    }
    
    private func baseColor(for base: Character) -> Color {
        if isDark {
            switch base.uppercased() {
            case "A": return Color(red: 0.30, green: 0.90, blue: 0.50)
            case "T": return Color(red: 1.00, green: 0.42, blue: 0.48)
            case "G": return Color(red: 0.98, green: 0.76, blue: 0.22)
            case "C": return Color(red: 0.35, green: 0.78, blue: 1.00)
            default:  return Color.white
            }
        } else {
            switch base.uppercased() {
            case "A": return Color(red: 0.06, green: 0.58, blue: 0.26)
            case "T": return Color(red: 0.82, green: 0.16, blue: 0.24)
            case "G": return Color(red: 0.76, green: 0.44, blue: 0.02)
            case "C": return Color(red: 0.08, green: 0.42, blue: 0.82)
            default:  return Color(red: 0.10, green: 0.14, blue: 0.22)
            }
        }
    }
}

// MARK: - Layer 2: 极轻量动态选区高亮浮层 (仅在当前选中行绘制 1 个高亮框 + 被选中的密码子方块)
private struct SelectionOverlayCanvas: View {
    let window: MicroscopicSequenceWindow
    let slice: SequenceRowSlice
    let rowWidth: CGFloat
    let rowHeight: CGFloat
    let cellW: CGFloat
    let hasEnzymesInRow: Bool
    let hasPrimersInRow: Bool
    let showComplement: Bool
    let showTranslation: Bool
    let isDark: Bool
    let rowSelectedRange: ClosedRange<Int>
    let fullSelectedRange: ClosedRange<Int>?
    
    private let leftGutter: CGFloat = 26.0
    
    var body: some View {
        Canvas { context, size in
            var currentY: CGFloat = 2.0
            if hasEnzymesInRow {
                currentY += 28.0
            }
            let rulerY = currentY + 11.0
            
            // 1. 若选区起点在本行，绘制顶部实时坐标/氨基酸数/Tm 胶囊
            if let fullSel = fullSelectedRange {
                let localIdx = max(0, fullSel.lowerBound - slice.startBp)
                let len = fullSel.upperBound - fullSel.lowerBound + 1
                let subSeq: String = {
                    let s0 = max(0, fullSel.lowerBound - window.startBp)
                    let e0 = min(window.sequence.count, fullSel.upperBound - window.startBp + 1)
                    guard s0 < e0 else { return "" }
                    let sIdx = window.sequence.index(window.sequence.startIndex, offsetBy: s0)
                    let eIdx = window.sequence.index(window.sequence.startIndex, offsetBy: e0)
                    return String(window.sequence[sIdx..<eIdx])
                }()
                let tm = SequenceRowLayout.estimateSelectionTm(subSeq)
                let aaInfo = len >= 3 && len % 3 == 0 ? " · \(len / 3) aa" : ""
                let badgeText = "\(fullSel.lowerBound)..\(fullSel.upperBound) (\(len) bp\(aaInfo) | Tm=\(tm)°C)"
                let badgeW = max(148.0, CGFloat(badgeText.count) * 5.6 + 14.0)
                let badgeX = min(size.width - badgeW / 2 - 8, max(leftGutter + badgeW / 2, leftGutter + CGFloat(localIdx) * cellW + badgeW / 2))
                let badgeRect = CGRect(x: badgeX - badgeW / 2, y: max(0.5, rulerY - 12.5), width: badgeW, height: 13.5)
                let pillBg = isDark ? Color(red: 0.04, green: 0.16, blue: 0.28).opacity(0.96) : Color(red: 0.90, green: 0.96, blue: 1.0)
                let pillStroke = isDark ? Color.cyan : Color(red: 0.02, green: 0.48, blue: 0.85)
                context.fill(Path(roundedRect: badgeRect, cornerRadius: 3.5), with: .color(pillBg))
                context.stroke(Path(roundedRect: badgeRect, cornerRadius: 3.5), with: .color(pillStroke), lineWidth: 1.0)
                
                let txt = context.resolve(
                    Text(badgeText)
                        .font(.system(size: 8.2, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(pillStroke)
                )
                context.draw(txt, at: CGPoint(x: badgeRect.midX, y: badgeRect.midY), anchor: .center)
            }
            
            currentY += 16.0
            if hasPrimersInRow {
                currentY += 16.0
            }
            
            // 2. 双链 DNA 选区半透明高亮框
            let topStrandY = currentY + 8.0
            let boxH: CGFloat = showComplement ? 32.0 : 14.0
            let x1 = leftGutter + CGFloat(rowSelectedRange.lowerBound - slice.startBp) * cellW
            let x2 = leftGutter + CGFloat(rowSelectedRange.upperBound - slice.startBp + 1) * cellW
            let selRect = CGRect(x: x1, y: topStrandY - 6.5, width: max(cellW, x2 - x1), height: boxH)
            context.fill(Path(roundedRect: selRect, cornerRadius: 3.0), with: .color(isDark ? Color.blue.opacity(0.28) : Color.cyan.opacity(0.20)))
            context.stroke(Path(roundedRect: selRect, cornerRadius: 3.0), with: .color(isDark ? Color.cyan : Color(red: 0.02, green: 0.50, blue: 0.88)), lineWidth: 1.5)
            
            currentY += (showComplement ? 35.0 : 15.0)
            
            // 3. 高亮被选中的密码子方块
            if showTranslation && !slice.codons.isEmpty {
                let aaY = currentY + 7.0
                let baseCount = slice.topStrand.count
                for codon in slice.codons {
                    let localOffset = codon.baseOffset - slice.windowOffsetStart
                    guard localOffset >= 0 && localOffset + 3 <= baseCount else { continue }
                    let codonStartBp = window.startBp + codon.baseOffset
                    let codonEndBp = codonStartBp + 2
                    guard max(rowSelectedRange.lowerBound, codonStartBp) <= min(rowSelectedRange.upperBound, codonEndBp) else { continue }
                    
                    let boxX = leftGutter + CGFloat(localOffset) * cellW + 0.8
                    let boxW = max(12.0, cellW * 3.0 - 1.6)
                    let boxRect = CGRect(x: boxX, y: aaY - 6.5, width: boxW, height: 13.0)
                    let bgCol = isDark ? Color.cyan.opacity(0.95) : Color(red: 0.02, green: 0.52, blue: 0.90)
                    let strokeCol = isDark ? Color.white : Color(red: 0.01, green: 0.28, blue: 0.58)
                    
                    context.fill(Path(roundedRect: boxRect, cornerRadius: 2.5), with: .color(bgCol))
                    context.stroke(Path(roundedRect: boxRect, cornerRadius: 2.5), with: .color(strokeCol), lineWidth: 1.5)
                    
                    let aaResolved = context.resolve(
                        Text(String(codon.aminoAcid))
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundColor(isDark ? .black : .white)
                    )
                    context.draw(aaResolved, at: CGPoint(x: boxX + boxW / 2.0, y: aaY), anchor: .center)
                }
            }
        }
        .frame(width: rowWidth, height: rowHeight)
    }
}
