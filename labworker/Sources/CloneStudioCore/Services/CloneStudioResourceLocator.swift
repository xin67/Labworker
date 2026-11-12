import Foundation

/// 零崩溃资源路径定位器（彻底替代 SwiftPM 自动生成的 `Bundle.module`，防止在 macOS `.app` 标准包结构下触发 `fatalError`）
public enum CloneStudioResourceLocator {
    /// 查找打包在 App Bundle `Contents/Resources`、SwiftPM `.bundle` 或开发目录中的资源文件路径
    public static func path(forResource name: String, ofType ext: String? = nil) -> String? {
        let fm = FileManager.default
        let fileName: String = {
            if let ext = ext, !ext.isEmpty {
                return "\(name).\(ext)"
            }
            return name
        }()
        
        // 1. 优先查找主 App Bundle 的 Contents/Resources 目录
        if let mainPath = Bundle.main.path(forResource: name, ofType: ext),
           fm.fileExists(atPath: mainPath) {
            return mainPath
        }
        if let resURL = Bundle.main.resourceURL {
            let direct = resURL.appendingPathComponent(fileName).path
            if fm.fileExists(atPath: direct) {
                return direct
            }
            // 2. 查找 Contents/Resources/CloneStudio_CloneStudioCore.bundle 内部
            let innerBundleURL = resURL.appendingPathComponent("CloneStudio_CloneStudioCore.bundle")
            for candidate in [
                innerBundleURL.appendingPathComponent(fileName).path,
                innerBundleURL.appendingPathComponent("Resources").appendingPathComponent(fileName).path,
                innerBundleURL.appendingPathComponent("Contents/Resources").appendingPathComponent(fileName).path
            ] {
                if fm.fileExists(atPath: candidate) {
                    return candidate
                }
            }
        }
        
        // 3. 兼容通过可执行文件相对路径 ../Resources 查找
        if let execPath = CommandLine.arguments.first {
            let execDir = (execPath as NSString).deletingLastPathComponent
            let relRes = ((execDir as NSString).appendingPathComponent("../Resources") as NSString).standardizingPath
            let relCandidate = (relRes as NSString).appendingPathComponent(fileName)
            if fm.fileExists(atPath: relCandidate) {
                return relCandidate
            }
            let siblingBundle = (execDir as NSString).appendingPathComponent("CloneStudio_CloneStudioCore.bundle")
            for sub in [fileName, "Resources/\(fileName)"] {
                let p = (siblingBundle as NSString).appendingPathComponent(sub)
                if fm.fileExists(atPath: p) {
                    return p
                }
            }
        }
        
        // 4. 开发目录与工程根目录兜底（支持 LABWORKER_PROJECT_DIR 环境变量与 #filePath 相对推导，零个人硬编码路径）
        var rootCandidates: [String] = [fm.currentDirectoryPath]
        if let envRoot = ProcessInfo.processInfo.environment["LABWORKER_PROJECT_DIR"], !envRoot.isEmpty {
            rootCandidates.insert(envRoot, at: 0)
        }
        let derivedRoot = projectRootDirectory.path
        if !rootCandidates.contains(derivedRoot) {
            rootCandidates.append(derivedRoot)
        }
        let parentRoot = projectRootDirectory.deletingLastPathComponent().path
        if !rootCandidates.contains(parentRoot) {
            rootCandidates.append(parentRoot)
        }
        
        for base in rootCandidates {
            for rel in [
                "Sources/CloneStudioCore/Resources/\(fileName)",
                "Resources/\(fileName)",
                fileName
            ] {
                let candidate = (base as NSString).appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate) {
                    return candidate
                }
            }
        }
        
        return nil
    }
    
    /// 动态推导工程根目录（优先读取环境变量 `LABWORKER_PROJECT_DIR`，否则由编译期源码相对路径向上定位 `Package.swift`，最后回退到当前工作目录）
    public static var projectRootDirectory: URL {
        let fm = FileManager.default
        if let envDir = ProcessInfo.processInfo.environment["LABWORKER_PROJECT_DIR"],
           !envDir.isEmpty,
           fm.fileExists(atPath: envDir) {
            return URL(fileURLWithPath: envDir)
        }
        // #filePath: .../labworker/Sources/CloneStudioCore/Services/CloneStudioResourceLocator.swift
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if fm.fileExists(atPath: sourceURL.appendingPathComponent("Package.swift").path) {
            return sourceURL
        }
        return URL(fileURLWithPath: fm.currentDirectoryPath)
    }
    
    public static func url(forResource name: String, withExtension ext: String? = nil) -> URL? {
        guard let p = path(forResource: name, ofType: ext) else { return nil }
        return URL(fileURLWithPath: p)
    }
}
