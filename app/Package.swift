// swift-tools-version: 5.9
import PackageDescription

// usage-lens menu bar app.
// 约束：只用 SwiftUI / AppKit / Foundation，不引入任何第三方包。
let package = Package(
    name: "UsageLens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageLens", targets: ["UsageLens"]),
        .library(name: "UsageLensKit", targets: ["UsageLensKit"]),
        .library(name: "UsageLensUI", targets: ["UsageLensUI"]),
    ],
    targets: [
        // 契约解析、状态归约、格式化：纯逻辑，便于单测。
        .target(name: "UsageLensKit"),
        // SwiftUI 视图与状态容器：独立成 target，方便离屏渲染验证。
        .target(name: "UsageLensUI", dependencies: ["UsageLensKit"]),
        // 只放菜单栏入口。
        .executableTarget(name: "UsageLens", dependencies: ["UsageLensKit", "UsageLensUI"]),
        .testTarget(name: "UsageLensKitTests", dependencies: ["UsageLensKit"]),
        .testTarget(name: "UsageLensUITests", dependencies: ["UsageLensKit", "UsageLensUI"]),
    ]
)
