import SwiftUI
import AppKit
import WebKit
import CloneStudioCore

public enum MolstarRenderStyle: String, CaseIterable, Identifiable, Hashable {
    case cartoon = "cartoon"
    case cartoonSurface = "cartoon_surface"
    case surfaceElectrostatic = "surface_electrostatic"
    case ballAndStick = "ball_and_stick"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cartoon:              return L10n.t("Cartoon 飘带")
        case .cartoonSurface:       return L10n.t("飘带 + 表面")
        case .surfaceElectrostatic: return L10n.t("表面静电势")
        case .ballAndStick:         return L10n.t("全原子球棍")
        }
    }
}

public enum MolstarColorPreset: String, CaseIterable, Identifiable, Hashable {
    case plddt = "plddt"
    case secondary = "secondary"
    case hydrophobicity = "hydrophobicity"
    case chain = "chain"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .plddt:          return L10n.t("pLDDT / B因子")
        case .secondary:      return L10n.t("二级结构")
        case .hydrophobicity: return L10n.t("疏水性")
        case .chain:          return L10n.t("链编号")
        }
    }
}

public struct MolstarRenderPayload: Equatable {
    public let receptorData: String
    public let receptorFormat: String
    public let receptorLabel: String
    public let ligandData: String?
    public let ligandFormat: String?
    public let ligandLabel: String?
    public let style: MolstarRenderStyle
    public let colorMode: MolstarColorPreset
    public let showInteractions: Bool
    public let showControls: Bool
    public let darkBackground: Bool

    public init(
        receptorData: String,
        receptorFormat: String,
        receptorLabel: String,
        ligandData: String? = nil,
        ligandFormat: String? = nil,
        ligandLabel: String? = nil,
        style: MolstarRenderStyle = .cartoon,
        colorMode: MolstarColorPreset = .plddt,
        showInteractions: Bool = true,
        showControls: Bool = false,
        darkBackground: Bool = true
    ) {
        self.receptorData = receptorData
        self.receptorFormat = receptorFormat
        self.receptorLabel = receptorLabel
        self.ligandData = ligandData
        self.ligandFormat = ligandFormat
        self.ligandLabel = ligandLabel
        self.style = style
        self.colorMode = colorMode
        self.showInteractions = showInteractions
        self.showControls = showControls
        self.darkBackground = darkBackground
    }

    var structureAndThemeKey: String {
        [
            receptorFormat,
            receptorLabel,
            "\(receptorData.hashValue)",
            ligandFormat ?? "",
            ligandLabel ?? "",
            "\(ligandData?.hashValue ?? 0)",
            style.rawValue,
            colorMode.rawValue,
            showInteractions ? "1" : "0",
            darkBackground ? "1" : "0"
        ].joined(separator: "|")
    }
}

/// 离线嵌入式 Mol* 3D 蛋白与复合物交互视窗（纯本地 Resources/molstar.js + molstar_host.html，零外部网络请求）
public struct MolstarWebView: NSViewRepresentable {
    public let payload: MolstarRenderPayload
    public let resetCameraTrigger: Int
    public var onStatusChange: ((String?, Bool) -> Void)? = nil

    public init(
        payload: MolstarRenderPayload,
        resetCameraTrigger: Int = 0,
        onStatusChange: ((String?, Bool) -> Void)? = nil
    ) {
        self.payload = payload
        self.resetCameraTrigger = resetCameraTrigger
        self.onStatusChange = onStatusChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "labworkerMolstar")

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.pendingPayload = payload

        if let hostURL = CloneStudioResourceLocator.url(forResource: "molstar_host", withExtension: "html") {
            webView.loadFileURL(hostURL, allowingReadAccessTo: hostURL.deletingLastPathComponent())
        } else {
            let errHeading = L10n.tr("未找到离线 Mol* 资源 (molstar_host.html)", "Offline Mol* Resource Not Found (molstar_host.html)")
            let errBody = L10n.tr(
                L10n.t("请确认 Sources/CloneStudioCore/Resources 中已包含 molstar_host.html 与 molstar.js，或切换回原生 Canvas 模式。"),
                "Verify molstar_host.html and molstar.js exist in Resources, or switch to Fast Canvas mode."
            )
            let fallbackHTML = """
            <!DOCTYPE html><html><body style="background:#111827;color:#fca5a5;font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;padding:24px;">
            <h3>\(errHeading)</h3>
            <p>\(errBody)</p>
            </body></html>
            """
            webView.loadHTMLString(fallbackHTML, baseURL: nil)
            DispatchQueue.main.async {
                onStatusChange?(L10n.t("未找到离线 molstar_host.html 资源包"), false)
            }
        }
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyPayload(payload, resetTrigger: resetCameraTrigger)
    }

    public static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "labworkerMolstar")
    }

    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MolstarWebView
        weak var webView: WKWebView?
        var isReady: Bool = false
        var pendingPayload: MolstarRenderPayload?
        var lastRenderedKey: String?
        var lastControlsVisible: Bool?
        var lastResetTrigger: Int = 0

        init(parent: MolstarWebView) {
            self.parent = parent
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "labworkerMolstar",
                  let dict = message.body as? [String: Any],
                  let eventType = dict["type"] as? String else { return }

            switch eventType {
            case "ready":
                isReady = true
                if let p = pendingPayload {
                    pushToJS(p, forceReload: true)
                }
            case "loaded":
                let note = dict["message"] as? String
                DispatchQueue.main.async {
                    self.parent.onStatusChange?(note, false)
                }
            case "error":
                let msg = (dict["message"] as? String) ?? L10n.t("Mol* 渲染失败")
                DispatchQueue.main.async {
                    self.parent.onStatusChange?(msg, false)
                }
            default:
                break
            }
        }

        func applyPayload(_ payload: MolstarRenderPayload, resetTrigger: Int) {
            pendingPayload = payload
            guard isReady else { return }
            pushToJS(payload, forceReload: false)
            if resetTrigger != lastResetTrigger {
                lastResetTrigger = resetTrigger
                webView?.evaluateJavaScript("window.LabworkerMolstar && window.LabworkerMolstar.resetCamera();", completionHandler: nil)
            }
        }

        private func pushToJS(_ payload: MolstarRenderPayload, forceReload: Bool) {
            guard let webView else { return }
            if lastControlsVisible != payload.showControls || forceReload {
                lastControlsVisible = payload.showControls
                let ctrlFlag = payload.showControls ? "true" : "false"
                webView.evaluateJavaScript("window.LabworkerMolstar && window.LabworkerMolstar.setControlsVisible(\(ctrlFlag));", completionHandler: nil)
            }

            let key = payload.structureAndThemeKey
            guard forceReload || key != lastRenderedKey else { return }
            lastRenderedKey = key

            let recB64 = Data(payload.receptorData.utf8).base64EncodedString()
            var dict: [String: Any] = [
                "receptorData": recB64,
                "receptorFormat": payload.receptorFormat,
                "receptorLabel": payload.receptorLabel,
                "style": payload.style.rawValue,
                "colorMode": payload.colorMode.rawValue,
                "showInteractions": payload.showInteractions,
                "darkBackground": payload.darkBackground
            ]
            if let lig = payload.ligandData, !lig.isEmpty {
                dict["ligandData"] = Data(lig.utf8).base64EncodedString()
                dict["ligandFormat"] = payload.ligandFormat ?? "pdb"
                dict["ligandLabel"] = payload.ligandLabel ?? "Docked_Pose"
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else { return }

            DispatchQueue.main.async {
                self.parent.onStatusChange?(nil, true)
            }
            webView.evaluateJavaScript("window.LabworkerMolstar && window.LabworkerMolstar.loadComplex(\(jsonStr));", completionHandler: nil)
        }
    }
}
