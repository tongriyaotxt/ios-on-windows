import Testing
@testable import AppCore

@Suite("AppCore")
struct AppCoreTests {
    @Test("AppInfo 从 Info.plist 字典解析")
    func appInfoParsing() {
        let info = AppInfo(infoDictionary: [
            "CFBundleDisplayName": "装机测试",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45",
        ])
        #expect(info.name == "装机测试")
        #expect(info.version == "1.2.3")
        #expect(info.build == "45")
        #expect(info.displayString == "装机测试 1.2.3 (45)")
    }

    @Test("AppInfo 缺字段时回落")
    func appInfoFallback() {
        let info = AppInfo(infoDictionary: [:])
        #expect(info.version == "0.0.0")
        #expect(info.build == "0")
    }

    @Test("计数器不会为负")
    func counter() {
        var c = Counter()
        c.increment(by: 3)
        #expect(c.value == 3)
        c.increment(by: -10)
        #expect(c.value == 0)
        c.reset()
        #expect(c.value == 0)
    }

    @Test("版本比较", arguments: [
        ("1.0.0", "1.0.0", 0),
        ("1.0.1", "1.0.0", 1),
        ("1.0", "1.0.0", 0),
        ("2.0", "1.9.9", 1),
        ("1.2.9", "1.10.0", -1),
    ])
    func versioning(lhs: String, rhs: String, expected: Int) {
        #expect(VersionComparator.compare(lhs, rhs) == expected)
    }
}
