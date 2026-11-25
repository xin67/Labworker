import SwiftUI
import CloneStudioCore

/// 在线数据库一键拉取质粒弹窗 (支持 Addgene ID 与 NCBI GenBank / RefSeq Accession)
public struct OnlineDatabaseFetchSheet: View {
    public enum DatabaseSource: String, CaseIterable, Identifiable {
        case addgene = "Addgene 质粒 ID"
        case ncbi = "NCBI GenBank / RefSeq"

        public var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var pool = PlasmidPoolManager.shared

    @State private var source: DatabaseSource = .ncbi
    @State private var queryID: String = ""
    @State private var isFetching: Bool = false
    @State private var errorMessage: String? = nil
    @State private var fetchedResult: BioDatabaseFetchService.FetchedPlasmidResult? = nil

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("在线数据库直拉质粒 / 基因序列")
                        .font(.system(size: 16, weight: .bold))
                    Text("支持直接输入 Addgene 质粒编号或 NCBI GenBank / RefSeq 登录号，解析后一键入库本地质粒池")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            StudioCard(title: "选择数据源与登录号") {
                VStack(alignment: .leading, spacing: 10) {
                    StudioSegmentedPicker(
                        selection: $source,
                        options: [
                            StudioSegmentedOption(value: DatabaseSource.ncbi, title: DatabaseSource.ncbi.rawValue, tint: .blue),
                            StudioSegmentedOption(value: DatabaseSource.addgene, title: DatabaseSource.addgene.rawValue, tint: .purple)
                        ]
                    )

                    HStack(spacing: 8) {
                        TextField(
                            source == .ncbi ? "输入 NCBI 登录号 (如 L09137 / NM_000546)" : "输入 Addgene 编号 (如 52961)",
                            text: $queryID
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))

                        StudioCompactPillButton(title: "填入示例", icon: "sparkles", tint: .blue) {
                            queryID = (source == .ncbi) ? "L09137" : "52961"
                        }
                    }

                    StudioActionBar {
                        StudioPrimaryActionButton(
                            title: isFetching ? "正在在线拉取..." : "拉取并解析序列与特征",
                            icon: "arrow.down.circle.fill",
                            tint: source == .ncbi ? .blue : .purple,
                            isLoading: isFetching,
                            isDisabled: queryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetching,
                            action: startFetch
                        )
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .studioInnerBox(tint: .red, paddingH: 10, paddingV: 8)
                    }
                }
            }

            if let res = fetchedResult {
                StudioCard(title: "解析结果预览 (\(res.source) \(res.identifier))") {
                    StudioActionPillButton(
                        title: "写入本地质粒池",
                        icon: "tray.and.arrow.down.fill",
                        tint: .green,
                        isProminent: true
                    ) {
                        let item = pool.importFetchedDNAInfo(res.dnaInfo, displayName: res.dnaInfo.fileName.replacingOccurrences(of: ".gb", with: ""))
                        appState.showToast("已将 \(item.name) (\(res.dnaInfo.length) bp, \(res.dnaInfo.featuresCount) 特征) 入库！")
                        dismiss()
                    }
                } content: {
                    VStack(alignment: .leading, spacing: 8) {
                        StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            StudioMetricBadge(label: "名称", value: res.dnaInfo.fileName, color: .blue)
                            StudioMetricBadge(label: "长度", value: "\(res.dnaInfo.length) bp", color: .teal)
                            StudioMetricBadge(label: "拓扑", value: res.dnaInfo.isCircular ? "环状质粒" : "线性序列", color: .purple)
                            StudioMetricBadge(label: "特征注释", value: "\(res.dnaInfo.featuresCount) 条", color: .green)
                            if res.autoAnnotatedCount > 0 {
                                StudioMetricBadge(label: "自动补全", value: "+\(res.autoAnnotatedCount) 元件", color: .indigo)
                            }
                        }

                        if !res.dnaInfo.features.isEmpty {
                            ScrollView {
                                VStack(spacing: 4) {
                                    ForEach(res.dnaInfo.features.prefix(16)) { f in
                                        HStack {
                                            Text(f.name)
                                                .font(.system(size: 11.5, weight: .semibold))
                                            Text(f.type)
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            if let seg = f.segments.first {
                                                Text("\(seg.start)..\(f.segments.last?.end ?? seg.end) bp")
                                                    .font(.system(size: 11))
                                                    .monospacedDigit()
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .studioInnerBox(paddingH: 8, paddingV: 5)
                                    }
                                }
                            }
                            .frame(maxHeight: 170)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 660, idealWidth: 740, minHeight: 460, idealHeight: 540)
    }

    private func startFetch() {
        isFetching = true
        errorMessage = nil
        fetchedResult = nil
        let targetID = queryID
        let targetSource = source
        Task {
            do {
                let res: BioDatabaseFetchService.FetchedPlasmidResult
                if targetSource == .ncbi {
                    res = try await BioDatabaseFetchService.fetchNCBIGenBank(accession: targetID)
                } else {
                    res = try await BioDatabaseFetchService.fetchAddgenePlasmid(id: targetID)
                }
                await MainActor.run {
                    self.fetchedResult = res
                    self.isFetching = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isFetching = false
                }
            }
        }
    }
}
