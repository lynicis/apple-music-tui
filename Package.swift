// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "apple-music-tui",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "apple-music-tui", targets: ["MusicTUI"])
  ],
  dependencies: [
    .package(url: "https://github.com/ejbills/mediaremote-adapter.git", branch: "master")
  ],
  targets: [
    .target(
      name: "MusicTUICore",
      dependencies: [
        .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter")
      ]),
    .executableTarget(name: "MusicTUI", dependencies: ["MusicTUICore"]),
    .testTarget(name: "MusicTUICoreTests", dependencies: ["MusicTUICore"]),
  ]
)
