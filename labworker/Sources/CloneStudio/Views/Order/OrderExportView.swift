import SwiftUI
import CloneStudioCore

/// 商业订购表单中心（极简按钮驱动布局，去除冗长模板说明文案）
public struct OrderExportView: View {
    @ObservedObject private var appState = AppState.shared
    @StateObject private var vm = OrderExportViewModel()
    @State private var isEditingProfile: Bool = false
    
    @State private var newSampleName: String = "pCE-Construct"
    @State private var newVectorName: String = "pCE-Entry"
    @State private var newPrimerName: String = "T7"
    @State private var newFragLen: String = "1000"
    
    public init() {}
    
    public var body: some View {
        StudioPageLayout(title: "订购中心") {
            HStack(spacing: 8) {
                StudioSegmentedPicker(
                    selection: $vm.selectedCategory,
                    options: [
                        StudioSegmentedOption(value: .primerSynthesis, title: "引物合成 (\(appState.primersCart.count))", tint: .blue),
                        StudioSegmentedOption(value: .dnaSequencing, title: "DNA 测序 (\(appState.sangonSamples.count))", tint: .purple)
                    ]
                )
            }
        } content: {
                
                StudioCard(title: "订购信息") {
                    Button(isEditingProfile ? "完成" : "编辑") {
                        isEditingProfile.toggle()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } content: {
                    if isEditingProfile {
                        profileEditView
                    } else {
                        profileDisplayView
                    }
                }
                
                if vm.selectedCategory == .primerSynthesis {
                    primerOrderSection
                } else {
                    sequencingOrderSection
                }
        }
        .alert("导出成功", isPresented: $vm.showSuccessAlert) {
            Button("在 Finder 中打开") { vm.revealLastExported() }
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.exportedFilePath ?? "")
        }
        .alert("导出失败", isPresented: $vm.showErrorAlert) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
    
    // MARK: - 订购人信息展示卡片
    private var profileDisplayView: some View {
        let p = appState.profile
        return VStack(alignment: .leading, spacing: 6) {
            StudioFlowLayout(horizontalSpacing: 12, verticalSpacing: 6) {
                Text("\(p.customerName) · \(p.piName) 课题组")
                    .font(.system(size: 12, weight: .semibold))
                Text(p.organization)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(p.phone)
                    .font(.system(size: 12, design: .monospaced))
                Text(p.email)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                StudioMetricBadge(label: "", value: "\(p.defaultPurity) · \(String(format: "%.1f", p.defaultOD)) OD", color: .blue)
            }
            
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text(p.address)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
    
    private var profileEditView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("客户姓名", text: $appState.profile.customerName)
                TextField("课题组PI", text: $appState.profile.piName)
                TextField("客户单位", text: $appState.profile.organization)
            }
            HStack(spacing: 10) {
                TextField("联系电话", text: $appState.profile.phone)
                TextField("电子邮箱", text: $appState.profile.email)
                TextField("发票抬头", text: $appState.profile.invoiceTitle)
            }
            TextField("收样地址", text: $appState.profile.address)
        }
        .textFieldStyle(.roundedBorder)
    }
    
    // MARK: - 1. 引物合成订购区
    private var primerOrderSection: some View {
        StudioCard(title: "引物合成池 (\(appState.primersCart.count))") {
            StudioFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                Button("复制 TSV", action: vm.copyAsTSV)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.primersCart.isEmpty)
                
                Button("复制 FASTA", action: vm.copyAsFASTA)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.primersCart.isEmpty)
                
                Button(action: {
                    selectDNAFile { url in
                        Task {
                            do {
                                let res = try await SnapGeneService.shared.injectPrimers(appState.primersCart, into: url, createBackup: true)
                                appState.showToast("已将 \(res.primersAdded) 条引物写入质粒")
                                SnapGeneService.shared.openInSnapGene(url: url)
                            } catch {
                                appState.showToast("写入失败: \(error.localizedDescription)")
                            }
                        }
                    }
                }) {
                    Label("写入 .dna", systemImage: "bolt.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
                .disabled(appState.primersCart.isEmpty)
                
                Button(action: vm.exportPrimersOrder) {
                    Label("导出擎科订购表 (.xlsx)", systemImage: "arrow.down.doc.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)
                .disabled(appState.primersCart.isEmpty || vm.isExporting)
                
                StudioSectionClearButton(
                    title: "清空引物",
                    isDisabled: appState.primersCart.isEmpty,
                    action: appState.clearPrimersCart
                )
            }
        } content: {
            if appState.primersCart.isEmpty {
                HStack {
                    Spacer()
                    Text("暂无待订引物")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 22)
            } else {
                VStack(spacing: 5) {
                    ForEach(Array(appState.primersCart.enumerated()), id: \.element.id) { index, primer in
                        HStack(spacing: 8) {
                            Text("#\(index + 1)")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 24, alignment: .leading)
                            
                            Text(primer.name)
                                .font(.system(size: 11.5, weight: .bold))
                                .frame(width: 140, alignment: .leading)
                            
                            Text(primer.fullSequence)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .textSelection(.enabled)
                            
                            Spacer()
                            
                            Text("\(primer.length)bp")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.secondary)
                            
                            Text(primer.purity)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.blue)
                            
                            Text("\(String(format: "%.1f", primer.od)) OD")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            
                            Button(role: .destructive) {
                                appState.removePrimer(at: index)
                            } label: {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                        .cornerRadius(5)
                    }
                }
            }
        }
    }
    
    // MARK: - 2. DNA 测序订购区
    private var sequencingOrderSection: some View {
        StudioCard(title: "测序样品 (\(appState.sangonSamples.count))") {
            StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                Picker("", selection: $vm.selectedSeqTemplate) {
                    Text("擎科测序专属单").tag(OrderFormTemplate.tsingkeSeq)
                    Text("生工测序专属版").tag(OrderFormTemplate.sangonSeq)
                    Text("生工通用 V9 版").tag(OrderFormTemplate.sangonV9Seq)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 150)
                
                Button(action: vm.exportSequencingOrder) {
                    Label("导出测序表 (.xlsx)", systemImage: "arrow.down.doc.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
                .disabled(appState.sangonSamples.isEmpty || vm.isExporting)
                
                StudioSectionClearButton(
                    title: "清空样品",
                    isDisabled: appState.sangonSamples.isEmpty,
                    action: vm.clearSamples
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                StudioFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    TextField("样品名", text: $newSampleName)
                        .frame(width: 130)
                    TextField("载体", text: $newVectorName)
                        .frame(width: 105)
                    TextField("引物", text: $newPrimerName)
                        .frame(width: 75)
                    TextField("长度bp", text: $newFragLen)
                        .frame(width: 70)
                    
                    Button("＋ 添加样品") {
                        let len = Int(newFragLen) ?? 1000
                        vm.addSample(name: newSampleName, vector: newVectorName, primer: newPrimerName, fragmentLength: len)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button("＋ 双向 (T7/BGH)") {
                        vm.addPairSample(name: newSampleName, vector: newVectorName)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5))
                
                if appState.sangonSamples.isEmpty {
                    HStack {
                        Spacer()
                        Text("暂无测序样品")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 5) {
                        ForEach(Array(appState.sangonSamples.enumerated()), id: \.element.id) { index, sample in
                            HStack(spacing: 8) {
                                Text("#\(index + 1)")
                                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 24, alignment: .leading)
                                
                                Text(sample.sampleName)
                                    .font(.system(size: 11.5, weight: .bold))
                                    .frame(width: 140, alignment: .leading)
                                
                                Text(sample.sampleType)
                                    .font(.system(size: 10.5))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(3)
                                
                                Text(sample.vectorName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.purple)
                                
                                Text("\(sample.fragmentLength)bp")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                                
                                StudioMetricBadge(label: "引物", value: sample.primerName, color: .blue)
                                
                                Text(sample.requirement)
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                                
                                Spacer()
                                
                                Button(role: .destructive) {
                                    vm.removeSample(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                            .cornerRadius(5)
                        }
                    }
                }
            }
        }
    }
    
    private func selectDNAFile(completion: @escaping (URL) -> Void) {
        FinderFileDropHelper.selectDNAFile(
            message: "选择待注入引物的 SnapGene (.dna) 质粒文件",
            prompt: "批量写入",
            completion: completion
        )
    }
}
