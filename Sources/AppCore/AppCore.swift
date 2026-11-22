import Foundation

/// 应用元信息。纯 Foundation 实现，Windows / Linux / iOS 都能编译与单测。
public struct AppInfo: Sendable, Equatable {
    public let name: String
    public let version: String
    public let build: String

    public init(name: String, version: String, build: String) {
        self.name = name
        self.version = version
        self.build = build
    }

    /// 从 Bundle 风格的字典解析，避免直接依赖 Bundle（Windows 上没有 Bundle.main 的 Info.plist）。
    public init(infoDictionary: [String: Any]) {
        self.name = infoDictionary["CFBundleDisplayName"] as? String
            ?? infoDictionary["CFBundleName"] as? String
            ?? "Untitled"
        self.version = infoDictionary["CFBundleShortVersionString"] as? String ?? "0.0.0"
        self.build = infoDictionary["CFBundleVersion"] as? String ?? "0"
    }

    public var displayString: String { "\(name) \(version) (\(build))" }
}

/// 一个可持久化的计数器，验证状态层在真机上正常。
public struct Counter: Sendable, Equatable {
    public private(set) var value: Int

    public init(value: Int = 0) {
        self.value = value
    }

    public mutating func increment(by delta: Int = 1) {
        value = max(0, value + delta)
    }

    public mutating func reset() {
        value = 0
    }
}

/// 版本号比较：用于「有新版本」提示，纯逻辑，方便在 Windows 上跑测试。
public enum VersionComparator {
    /// 语义化版本比较，返回 -1 / 0 / 1。非法片段按 0 处理。
    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(l.count, r.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) > 0
    }
}
