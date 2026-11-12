import SwiftUI
import CloneStudioCore

/// 1:1 复刻 CloneCanvas `EnzymeSelector.svelte` 的限制性内切酶选择器与 NEB 双酶切 Buffer 活性矩阵浮窗
public struct RestrictionEnzymeInspectorView: View {
    @ObservedObject private var appState = AppState.shared
    public let detectedCutsites: [ConstructCutsite]
    public var onSelectCutsite: ((ConstructCutsite) -> Void)? = nil
    public var onClose: (() -> Void)? = nil
    
    @State private var searchText: String = ""
    
    public init(
        detectedCutsites: [ConstructCutsite],
        onSelectCutsite: ((ConstructCutsite) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.detectedCutsites = detectedCutsites
        self.onSelectCutsite = onSelectCutsite
        self.onClose = onClose
    }
    
    private var matchingSearchEnzymes: [RestrictionEnzyme] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return Array(
            RestrictionEnzymeDatabase.shared.enzymes.filter { enz in
                enz.name.localizedCaseInsensitiveContains(q) ||
                enz.site.localizedCaseInsensitiveContains(q)
            }.prefix(8)
        )
    }
    
    private var activeEnzymesWithSites: [String] {
        var seen = Set<String>()
        var list: [String] = []
        for cut in detectedCutsites {
            if !seen.contains(cut.name) {
                seen.insert(cut.name)
                list.append(cut.name)
            }
        }
        if list.isEmpty {
            return Array(appState.selectedEnzymeNames.prefix(6))
        }
        return Array(list.prefix(8))
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            inspectorHeaderBar
            presetSelectorRow
            enzymeSearchBox
            selectedEnzymesSection
            Divider().background(Color.white.opacity(0.12))
            detectedCutsitesSection
            Divider().background(Color.white.opacity(0.12))
            nebBufferMatrixSection
        }
        .padding(10)
        .frame(width: 268)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(red: 0.06, green: 0.09, blue: 0.16).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.55), radius: 14, x: 0, y: 6)
        )
    }
    
    private var inspectorHeaderBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "scissors")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.cyan)
            Text("Restriction Enzymes")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
            
            Spacer()
            
            if let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var presetSelectorRow: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(RestrictionEnzymeDatabase.presetGroups) { group in
                    Button(action: {
                        appState.applyEnzymePreset(group)
                    }) {
                        Text("SET: \(group.name.uppercased())")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "flask.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.pink)
                    Text("SET: \(appState.selectedEnzymePreset.uppercased())")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.cyan.opacity(0.35), lineWidth: 0.8)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            
            Button(action: {
                appState.clearSelectedEnzymes()
            }) {
                Text("Clear")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
        }
    }
    
    private var enzymeSearchBox: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                TextField("Search 434+ restriction enzymes, press Enter...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundColor(.white)
                    .onSubmit {
                        if let first = matchingSearchEnzymes.first {
                            appState.addEnzymeName(first.name)
                            searchText = ""
                        }
                    }
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.black.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                    )
            )
            
            if !matchingSearchEnzymes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matchingSearchEnzymes) { enz in
                        Button(action: {
                            appState.addEnzymeName(enz.name)
                            searchText = ""
                        }) {
                            HStack {
                                Text(enz.name)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.cyan)
                                Text("(\(enz.site))")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                                Spacer()
                                Text("+ Add")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.green)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Color(red: 0.07, green: 0.10, blue: 0.18))
                .cornerRadius(5)
            }
        }
    }
    
    private var selectedEnzymesSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Selected Enzymes: (\(appState.selectedEnzymeNames.count))")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.65))
                Spacer()
                Toggle(isOn: $appState.uniqueCuttersOnly) {
                    Text("Unique Only")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.cyan.opacity(0.9))
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)
            }
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(appState.selectedEnzymeNames.prefix(30)), id: \.self) { name in
                        selectedEnzymeRow(name: name)
                    }
                }
            }
            .frame(height: 66)
        }
    }
    
    private func selectedEnzymeRow(name: String) -> some View {
        let site = RestrictionEnzymeDatabase.shared.find(name: name)?.site ?? ""
        return HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
            if !site.isEmpty {
                Text("(\(site))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer()
            Button(action: {
                appState.removeEnzymeName(name)
            }) {
                Image(systemName: "minus")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.red.opacity(0.85))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.03))
        .cornerRadius(3)
    }
    
    private var detectedCutsitesSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Detected Cut Sites (\(detectedCutsites.count))")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.cyan)
                Spacer()
                Text("Click to locate")
                    .font(.system(size: 8.5))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    if detectedCutsites.isEmpty {
                        Text("No cut sites found for selected enzymes.")
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.45))
                            .padding(.vertical, 8)
                    } else {
                        ForEach(detectedCutsites) { cut in
                            detectedCutsiteRow(cut: cut)
                        }
                    }
                }
            }
            .frame(height: 84)
        }
    }
    
    private func detectedCutsiteRow(cut: ConstructCutsite) -> some View {
        Button(action: {
            onSelectCutsite?(cut)
        }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hexString: cut.colorHex))
                    .frame(width: 5, height: 5)
                Text(cut.name)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 54, alignment: .leading)
                Text(cut.recognitionSite)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                Text("\(cut.position1Based) bp")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }
    
    private var nebBufferMatrixSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEB Double Digest Buffer Activity")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
            
            HStack(spacing: 2) {
                Text("Enzyme")
                    .frame(width: 54, alignment: .leading)
                Text("r1.1")
                    .frame(maxWidth: .infinity)
                Text("r2.1")
                    .frame(maxWidth: .infinity)
                Text("r3.1")
                    .frame(maxWidth: .infinity)
                Text("CutSmart")
                    .frame(width: 52, alignment: .trailing)
            }
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
            .padding(.horizontal, 4)
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(activeEnzymesWithSites, id: \.self) { enzName in
                        nebBufferRow(enzName: enzName)
                    }
                }
            }
            .frame(maxHeight: 66)
            
            if let firstEnz = activeEnzymesWithSites.first {
                let firstBuf = RestrictionEnzymeDatabase.shared.bufferCompatibility(for: firstEnz)
                HStack {
                    Text("Heat Inactivation (65°C, 20min):")
                        .font(.system(size: 8.5))
                        .foregroundColor(.white.opacity(0.55))
                    Text(firstBuf.heatInactivation ? "Yes" : "No")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(firstBuf.heatInactivation ? .green : .orange)
                    Spacer()
                    Text("Best: \(firstBuf.preferredBuffer)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                }
            }
        }
    }
    
    private func nebBufferRow(enzName: String) -> some View {
        let buf = RestrictionEnzymeDatabase.shared.bufferCompatibility(for: enzName)
        return HStack(spacing: 2) {
            Text(enzName)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 54, alignment: .leading)
                .lineLimit(1)
            bufferCell(buf.r1_1)
            bufferCell(buf.r2_1)
            bufferCell(buf.r3_1)
            bufferCell(buf.cutSmart, width: 52, align: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(Color.white.opacity(0.025))
        .cornerRadius(3)
    }
    
    @ViewBuilder
    private func bufferCell(_ pct: Int, width: CGFloat? = nil, align: Alignment = .center) -> some View {
        let color: Color = {
            if pct >= 100 { return Color(red: 0.20, green: 0.90, blue: 0.50) }
            if pct >= 50 { return Color(red: 0.98, green: 0.75, blue: 0.20) }
            if pct > 0 { return Color(red: 0.98, green: 0.40, blue: 0.40) }
            return Color.white.opacity(0.35)
        }()
        if let w = width {
            Text("\(pct)%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: w, alignment: align)
        } else {
            Text("\(pct)%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: align)
        }
    }
}
