// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BoostyCore",
    defaultLocalization: "en",
    platforms: [.tvOS(.v17), .macOS(.v13)],
    products: [.library(name: "BoostyCore", targets: ["BoostyCore"])],
    targets: [
        .target(name: "BoostyCore"),
        .testTarget(name: "BoostyCoreTests", dependencies: ["BoostyCore"]),
        .target(name: "BoostyAppState", dependencies: ["BoostyCore"], path: "App",
                exclude: ["BoostyApp.swift", "LibraryView.swift", "PlaybackScreen.swift", "PostView.swift", "RootView.swift", "PhoneLinkView.swift", "RemoteImage.swift", "Assets.xcassets"],
                sources: ["AppModel.swift", "SessionStore.swift", "PlaybackProgress.swift", "PlaybackController.swift", "AppLanguage.swift", "FramePreview.swift", "PlaybackTimeline.swift", "ReadingSections.swift"],
                resources: [.process("Resources")]),
        .testTarget(name: "BoostyAppStateTests", dependencies: ["BoostyCore", "BoostyAppState"])
    ]
)
