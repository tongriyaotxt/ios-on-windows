import SwiftUI
import AppCore

/// SwiftUI 壳：这里只做「把 AppCore 的数据搬到屏幕上」。
/// 所有能端到端测试的逻辑都在 Sources/AppCore（Windows 上 `swift test` 反复跑），
/// 这个文件只在 macOS CI 上编译一次。
@main
struct AppCoreApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var counter = Counter()
    @State private var info = AppInfo(
        infoDictionary: Bundle.main.infoDictionary ?? [:]
    )

    var body: some View {
        VStack(spacing: 20) {
            Text(info.displayString)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("\(counter.value)")
                .font(.system(size: 72, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())

            HStack(spacing: 12) {
                Button("−") { counter.increment(by: -1) }
                Button("+") { counter.increment() }
                Button("reset") { counter.reset() }
            }
            .buttonStyle(.borderedProminent)

            Text(VersionComparator.isNewer("1.1.0", than: info.version)
                 ? "有新版本可用"
                 : "已是最新")
                .font(.caption)
        }
        .padding()
    }
}
