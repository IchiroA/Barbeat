// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MenuBarEQ",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "Barbeat", targets: ["MenuBarEQ"])],
    targets: [
        .executableTarget(
            name: "MenuBarEQ",
            path: "Sources/MenuBarEQ"
        )
    ]
)
