// swift-tools-version:5.9
// Open this folder in Xcode (File > Open) to work on the app, or run scripts/build.sh to get dist/FlashEdit.app.
import PackageDescription

let package = Package(
    name: "FlashEdit",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "FlashEdit", resources: [.copy("Presets")])]
)
