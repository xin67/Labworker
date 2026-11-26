import Foundation
import SwiftUI

/// 应用界面语言（简体中文 / 学术英文）
public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case zhHans = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .english: return "English"
        }
    }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public var isEnglish: Bool {
        self == .english
    }
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .zhHans
}

public extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

/// 全局双语本地化调度中心（线程安全，基于 `Resources/en_translations.json` 学术英文字典与动态模式规则）
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _currentLanguage: AppLanguage = .zhHans
    nonisolated(unsafe) private static var _cachedExactMap: [String: String]? = nil

    public static var currentLanguage: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return _currentLanguage
    }

    public static func setLanguage(_ language: AppLanguage) {
        lock.lock()
        _currentLanguage = language
        lock.unlock()
    }

    public static var isEnglish: Bool {
        currentLanguage == .english
    }

    /// 懒加载学术英文映射词典
    private static var exactMap: [String: String] {
        lock.lock()
        if let cached = _cachedExactMap {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var loaded: [String: String] = [:]
        if let url = CloneStudioResourceLocator.url(forResource: "en_translations", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            loaded = dict
        }

        lock.lock()
        if _cachedExactMap == nil {
            _cachedExactMap = loaded
        }
        let result = _cachedExactMap ?? loaded
        lock.unlock()
        return result
    }

    public static var loadedTranslationCount: Int {
        exactMap.count
    }

    public static var allExactTranslations: [String: String] {
        exactMap
    }

    public static func lookupEnglishExact(_ zh: String) -> String? {
        exactMap[zh]
    }

    /// 将静态中文文案按当前语言切换为学术英文；简体中文模式下零开销直接返回原文
    public static func t(_ zh: String) -> String {
        guard isEnglish, !zh.isEmpty else { return zh }
        if let hit = exactMap[zh] {
            return hit
        }
        if let dyn = translateDynamic(zh) {
            return dyn
        }
        return zh
    }

    /// 针对带插值或动态组装的中英双语直出辅助函数
    public static func tr(_ zh: @autoclosure () -> String, _ en: @autoclosure () -> String) -> String {
        isEnglish ? en() : zh()
    }

    /// 针对经组件透传的常见动态拼接文案（如孔板规格、计数徽章、片段数、工具提示前缀）执行兜底映射
    private static func translateDynamic(_ zh: String) -> String? {
        // 1. "显示全部功能 (18)" / "全部 (18)" / "96 孔" / "96孔" / "96 孔板"
        if let m = matchFirst(#"^显示全部功能 \((\d+)\)$"#, in: zh) {
            return "Show All Modules (\(m[1]))"
        }
        if let m = matchFirst(#"^全部 \((\d+)\)$"#, in: zh) {
            return "All (\(m[1]))"
        }
        if let m = matchFirst(#"^(\d+)\s*孔板$"#, in: zh) {
            return "\(m[1])-Well Plate"
        }
        if let m = matchFirst(#"^(\d+)\s*孔$"#, in: zh) {
            return "\(m[1])-Well"
        }
        if let m = matchFirst(#"^共\s*(\d+)\s*项$"#, in: zh) {
            return "\(m[1]) items"
        }
        if let m = matchFirst(#"^(\d+)\s*项$"#, in: zh) {
            return "\(m[1]) items"
        }
        if let m = matchFirst(#"^共\s*(\d+)\s*步改造记录$"#, in: zh) {
            return "\(m[1]) construct steps"
        }
        if let m = matchFirst(#"^(\d+)\s*步$"#, in: zh) {
            return "\(m[1]) steps"
        }
        if let m = matchFirst(#"^(\d+)\s*列$"#, in: zh) {
            return "\(m[1]) cols"
        }
        if let m = matchFirst(#"^(\d+)\s*条$"#, in: zh) {
            return "\(m[1]) items"
        }
        if let m = matchFirst(#"^(\d+)\s*泳道 · (.+)$"#, in: zh) {
            return "\(m[1]) Lanes · \(m[2])"
        }
        if let m = matchFirst(#"^第\s*(\d+)\s*段$"#, in: zh) {
            return "Fragment \(m[1])"
        }
        if let m = matchFirst(#"^在 Finder 中定位:\s*(.+)$"#, in: zh) {
            return "Reveal in Finder: \(m[1])"
        }
        if let m = matchFirst(#"^跟随系统（当前：(.+)）$"#, in: zh) {
            let colorName = exactMap[m[1]] ?? m[1]
            return "Match System (\(colorName))"
        }
        if let m = matchFirst(#"^手动：(.+)$"#, in: zh) {
            let colorName = exactMap[m[1]] ?? m[1]
            return "Custom: \(colorName)"
        }
        if let m = matchFirst(#"^跟随系统 · (.+)$"#, in: zh) {
            return "System · \(m[1])"
        }
        if let m = matchFirst(#"^跳转到「(.+)」工作台$"#, in: zh) {
            let nav = exactMap[m[1]] ?? m[1]
            return "Open \(nav)"
        }
        if matchFirst(#"^选择 SnapGene \(\.dna\) 质粒文件$"#, in: zh) != nil {
            return "Select SnapGene (.dna) Plasmid File"
        }
        return nil
    }

    private static func matchFirst(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        var groups: [String] = []
        for idx in 0..<match.numberOfRanges {
            if let r = Range(match.range(at: idx), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
