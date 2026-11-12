import Foundation

/// 官方在线 API 响应通用结构体
public struct CloneOnlineAPIResponse<T: Codable>: Codable {
    public let resultCode: Int?
    public let resultMsg: String?
    public let result: T?
}

/// 诺唯赞官方 API 通信客户端 (URLSession async/await + 智能直连穿透)
public final class CloneOnlineAPIClient: NSObject, URLSessionDelegate {
    public static let shared = CloneOnlineAPIClient()
    
    public var primaryBaseURL = "https://tool.vazyme.com:18000"
    public var fallbackBaseURL = "https://180.101.225.66:18000"
    
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 4.0
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    // MARK: - SSL 校验代理 (支持直连 IP 证书匹配)
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }
    
    // MARK: - 通用请求执行器 (带自动回退)
    private func executeRequest<T: Codable>(
        path: String,
        method: String = "POST",
        jsonBody: Data? = nil,
        formBody: [String: String]? = nil
    ) async throws -> T {
        // 先试标准域名，若超时或异常则试直连 IP
        let bases = [primaryBaseURL, fallbackBaseURL]
        var lastError: Error?
        
        for base in bases {
            guard let url = URL(string: base + path) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("tool.vazyme.com:18000", forHTTPHeaderField: "Host")
            request.setValue("https://crm.vazyme.com", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
            
            if let json = jsonBody {
                request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = json
            } else if let form = formBody {
                request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
                let bodyString = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
                request.httpBody = bodyString.data(using: .utf8)
            }
            
            do {
                let (data, response) = try await session.data(for: request)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    let decoded = try JSONDecoder().decode(T.self, from: data)
                    return decoded
                }
            } catch {
                lastError = error
                // 自动尝试下一个基地址
            }
        }
        
        throw lastError ?? NSError(domain: "CloneOnlineAPIClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法连接到诺唯赞官方服务器"])
    }
    
    // MARK: - 1. 入门克隆 (Entry Clone)
    public struct EntryCloneResult: Codable {
        public let success: String?
        public let PrimerFvalue: String?
        public let PrimerRvalue: String?
        public let PrimerFabove1: String?
        public let PrimerFabove2: String?
        public let PrimerRabove1: String?
        public let PrimerRabove2: String?
        public let promptMessage: String?
    }
    
    public func requestEntryClone(
        sequence: String,
        hasEnzymes: Bool,
        enzyme5Name: String = "",
        enzyme5Site: String = "",
        enzyme3Name: String = "",
        enzyme3Site: String = ""
    ) async throws -> EntryCloneResult {
        let payload: [String: Any] = [
            "sequence": sequence,
            "enzymeLociFlag": hasEnzymes ? "Y" : "N",
            "fragment3RC": enzyme3Name,
            "fragment3Sites": enzyme3Site,
            "fragment5RC": enzyme5Name,
            "fragment5Sites": enzyme5Site
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let resp: CloneOnlineAPIResponse<EntryCloneResult> = try await executeRequest(
            path: "/bio-tool-web/api/simpleclone/entryclone",
            jsonBody: data
        )
        guard let res = resp.result else {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: resp.resultMsg ?? "未知错误"])
        }
        return res
    }
    
    // MARK: - 2. 单片段克隆 (Single Fragment Clone)
    public struct SingleCloneResult: Codable {
        public let success: String?
        public let PrimerFvalue: String?
        public let PrimerRvalue: String?
        public let PrimerFabove1: String?
        public let PrimerFabove2: String?
        public let PrimerRabove1: String?
        public let PrimerRabove2: String?
        public let ClonePrimerFvalue: String?
        public let ClonePrimerRvalue: String?
        public let ClonePrimerFabove2: String?
        public let ClonePrimerRabove2: String?
        public let promptMessage: String?
    }
    
    public func requestSingleFragmentClone(
        mode: String, // "Single", "Double", "PCR"
        vectorSeq: String = "",
        insertSeq: String = "",
        vectorSeqU: String = "",
        vectorSeqD: String = "",
        enzymeName: String = "",
        enzymeSite: String = "",
        enzyme5Name: String = "",
        enzyme5Site: String = "",
        enzyme3Name: String = "",
        enzyme3Site: String = ""
    ) async throws -> SingleCloneResult {
        var payload: [String: Any] = [
            "selectFlag": mode,
            "insertseq": insertSeq
        ]
        if mode == "Single" {
            payload["vectorseq"] = vectorSeq
            payload["fragmentRC"] = enzymeName
            payload["fragmentSites"] = enzymeSite
        } else if mode == "Double" {
            payload["vectorseq"] = vectorSeq
            payload["fragment5RC"] = enzyme5Name
            payload["fragment5Sites"] = enzyme5Site
            payload["fragment3RC"] = enzyme3Name
            payload["fragment3Sites"] = enzyme3Site
        } else if mode == "PCR" {
            payload["vectorseqU"] = vectorSeqU
            payload["vectorseqD"] = vectorSeqD
        }
        
        let data = try JSONSerialization.data(withJSONObject: payload)
        let resp: CloneOnlineAPIResponse<SingleCloneResult> = try await executeRequest(
            path: "/bio-tool-web/api/singlefragmentclone/singlefragmentclone",
            jsonBody: data
        )
        guard let res = resp.result else {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: resp.resultMsg ?? "未知错误"])
        }
        return res
    }
    
    // MARK: - 3. 多片段克隆 (Multi Fragment Clone, 2~11 fragments)
    public struct MultiCloneResult: Codable {
        public let success: String?
        public let promptMessage: String?
        public let RTB1Fvalue: String?
        public let RTB1Rvalue: String?
        public let RTB2Fvalue: String?
        public let RTB2Rvalue: String?
        public let RTB3Fvalue: String?
        public let RTB3Rvalue: String?
        public let RTB4Fvalue: String?
        public let RTB4Rvalue: String?
        public let RTB5Fvalue: String?
        public let RTB5Rvalue: String?
    }
    
    public func requestMultiFragmentClone(
        fragments: [String],
        mode: String = "Single", // "Single", "Double", "PCR"
        vectorSeq: String = "",
        vectorSeqU: String = "",
        vectorSeqD: String = "",
        enzyme5Name: String = "",
        enzyme5Site: String = "",
        enzyme3Name: String = "",
        enzyme3Site: String = "",
        enzymeName: String = "",
        enzymeSite: String = ""
    ) async throws -> MultiCloneResult {
        var payload: [String: Any] = [
            "selectFlag": mode,
            "fragmentFlag": "\(fragments.count)"
        ]
        if mode == "Single" {
            payload["vectorseq"] = vectorSeq
            payload["fragmentRC"] = enzymeName
            payload["fragmentSites"] = enzymeSite
        } else if mode == "Double" {
            payload["vectorseq"] = vectorSeq
            payload["fragment5RC"] = enzyme5Name
            payload["fragment5Sites"] = enzyme5Site
            payload["fragment3RC"] = enzyme3Name
            payload["fragment3Sites"] = enzyme3Site
        } else {
            payload["vectorseqU"] = vectorSeqU
            payload["vectorseqD"] = vectorSeqD
        }
        
        for (idx, seq) in fragments.enumerated() {
            payload["insertseq\(idx + 1)"] = seq
        }
        
        let data = try JSONSerialization.data(withJSONObject: payload)
        let resp: CloneOnlineAPIResponse<MultiCloneResult> = try await executeRequest(
            path: "/bio-tool-web/api/multifragmentclone/multiclone",
            jsonBody: data
        )
        guard let res = resp.result else {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: resp.resultMsg ?? "未知错误"])
        }
        return res
    }
    
    // MARK: - 4. 单点突变 (Single Mutagenesis)
    public struct MutationResult: Codable {
        public let success: String?
        public let PrimerFvalue: String?
        public let PrimerRvalue: String?
        public let PrimerFabove1: String?
        public let PrimerFabove2: String?
        public let PrimerRabove1: String?
        public let PrimerRabove2: String?
        public let promptMessage: String?
    }
    
    public func requestSingleMutation(
        mutUp: String,
        mutDown: String,
        mutSite: String
    ) async throws -> MutationResult {
        let payload: [String: Any] = [
            "mutUp": mutUp,
            "mutDown": mutDown,
            "mutSite": mutSite
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let resp: CloneOnlineAPIResponse<MutationResult> = try await executeRequest(
            path: "/bio-tool-web/api/singlepointmutation/singleMutation",
            jsonBody: data
        )
        guard let res = resp.result else {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: resp.resultMsg ?? "未知错误"])
        }
        return res
    }
    
    // MARK: - 5. 引物 Tm 值测算 (Tm Calculator)
    public struct TmResult: Codable {
        public let success: Bool?
        public let resultvalue2: String? // 长度
        public let resultvalue3: String? // GC
        public let resultvalue4: String? // Tm
        public let resultvalue5: String? // 推荐退火
    }
    
    public func requestTm(sequence: String) async throws -> TmResult {
        let form = ["sequence": sequence]
        let resp: CloneOnlineAPIResponse<TmResult> = try await executeRequest(
            path: "/bio-tool-web/api/tmcal",
            formBody: form
        )
        guard let res = resp.result else {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: resp.resultMsg ?? "未知错误"])
        }
        return res
    }
}
