// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PolevoyJournal",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "JournalCore", targets: ["JournalCore"])],
    targets: [.target(name: "JournalCore"), .testTarget(name: "JournalCoreTests", dependencies: ["JournalCore"])]
)
