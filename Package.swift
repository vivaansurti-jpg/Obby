// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Obby", platforms: [.macOS(.v13)], products: [.executable(name: "Obby", targets: ["Obby"])], targets: [.executableTarget(name: "Obby")])
