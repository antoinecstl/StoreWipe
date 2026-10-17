// swift-tools-version: 6.0
import PackageDescription

// PhotoSwipeKit contient toute la logique indépendante de l'interface et de PhotoKit.
// Le paquet compile sur iOS/macOS (SQLite système via le module `SQLite3`) et sur
// Linux (module système `CSQLite`), ce qui permet d'exécuter les tests hors Xcode.

var storeDependencies: [Target.Dependency] = ["PhotoSwipeCore"]
var extraTargets: [Target] = []

#if os(Linux)
storeDependencies.append("CSQLite")
extraTargets.append(.systemLibrary(name: "CSQLite", path: "Sources/CSQLite"))
#endif

let package = Package(
    name: "PhotoSwipeKit",
    defaultLocalization: "fr",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "PhotoSwipeCore", targets: ["PhotoSwipeCore"]),
        .library(name: "PhotoSwipeStore", targets: ["PhotoSwipeStore"]),
        .library(name: "PhotoSwipeFeatures", targets: ["PhotoSwipeFeatures"]),
    ],
    targets: extraTargets + [
        .target(name: "PhotoSwipeCore"),
        .target(name: "PhotoSwipeStore", dependencies: storeDependencies),
        .target(name: "PhotoSwipeFeatures", dependencies: ["PhotoSwipeCore", "PhotoSwipeStore"]),
        .testTarget(name: "PhotoSwipeCoreTests", dependencies: ["PhotoSwipeCore"]),
        .testTarget(name: "PhotoSwipeStoreTests", dependencies: ["PhotoSwipeStore", "PhotoSwipeCore"]),
        .testTarget(
            name: "PhotoSwipeFeaturesTests",
            dependencies: ["PhotoSwipeFeatures", "PhotoSwipeStore", "PhotoSwipeCore"]
        ),
    ]
)
