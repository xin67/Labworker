import Foundation
import AppKit

/// CHOPCHOP 在线预测与全基因组脱靶后台服务 (通过 Python 后台引擎异步调度与解析)
public final class CHOPCHOPService {
    public static let shared = CHOPCHOPService()
    
    public static let baseURLString = "https://chopchop.cbu.uib.no/"
    
    /// 寻找 Python 爬取与查询脚本
    private func locateScript() -> String? {
        CloneStudioResourceLocator.path(forResource: "chopchop_query", ofType: "py")
    }
    
    /// 构建带有目标基因预置的 CHOPCHOP 访问 URL (保留外部浏览器直达)
    public func makeWebURL(gene: String, species: TargetSpecies) -> URL {
        let cleanGene = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: Self.baseURLString)!
        if !cleanGene.isEmpty {
            components.fragment = "target=\(cleanGene)&organism=\(species.chopchopGenome)"
        }
        return components.url ?? URL(string: Self.baseURLString)!
    }
    
    /// 在默认外部浏览器中打开 CHOPCHOP
    public func openInDefaultBrowser(gene: String, species: TargetSpecies) {
        let url = makeWebURL(gene: gene, species: species)
        NSWorkspace.shared.open(url)
    }
    
    /// 通过 Python 后台异步查询 CHOPCHOP 全基因组预测靶点与脱靶数据
    /// - Parameters:
    ///   - gene: 目标基因
    ///   - species: 人源(hg38) / 鼠源(mm39)
    ///   - timeout: 超时时间（秒）
    ///   - forceRefresh: 是否忽略本地缓存强制向云端重新发起检索
    ///   - progressHandler: 实时进度通知回调
    public func queryTargets(
        gene: String,
        species: TargetSpecies,
        timeout: Int = 55,
        forceRefresh: Bool = false,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> [CHOPCHOPTarget] {
        let cleanGene = gene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGene.isEmpty else {
            throw NSError(domain: "CHOPCHOP", code: -1, userInfo: [NSLocalizedDescriptionKey: "目标基因名称不能为空"])
        }
        
        guard let scriptPath = locateScript() else {
            throw NSError(domain: "CHOPCHOP", code: -2, userInfo: [NSLocalizedDescriptionKey: "未找到后台执行脚本 chopchop_query.py"])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                var args = [
                    scriptPath,
                    "--gene", cleanGene,
                    "--genome", species.chopchopGenome,
                    "--timeout", "\(timeout)"
                ]
                if forceRefresh {
                    args.append("--force-refresh")
                }
                process.arguments = args
                
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                
                // 实时监听 stderr 进度输出
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    for line in text.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("PROGRESS:") {
                            let msg = trimmed.replacingOccurrences(of: "PROGRESS:", with: "").trimmingCharacters(in: .whitespaces)
                            DispatchQueue.main.async {
                                progressHandler?(msg)
                            }
                        }
                    }
                }
                
                do {
                    try process.run()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    
                    guard process.terminationStatus == 0 else {
                        continuation.resume(throwing: NSError(domain: "CHOPCHOP", code: -3, userInfo: [NSLocalizedDescriptionKey: "Python 查询进程异常退出 (code: \(process.terminationStatus))"]))
                        return
                    }
                    
                    let decoder = JSONDecoder()
                    let resp = try decoder.decode(CHOPCHOPQueryResponse.self, from: outData)
                    
                    if resp.status == "success" {
                        let list = resp.targets ?? []
                        continuation.resume(returning: list)
                    } else {
                        let err = resp.message ?? "CHOPCHOP 查询未知错误"
                        continuation.resume(throwing: NSError(domain: "CHOPCHOP", code: -4, userInfo: [NSLocalizedDescriptionKey: err]))
                    }
                } catch {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
