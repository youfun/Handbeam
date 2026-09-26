import XCTest
@testable import HandbeamCore

final class DesktopConfigTests: XCTestCase {
    func testHealthCheckUsesAStaticAsset() {
        XCTAssertEqual(
            DesktopConfig.healthURL(port: 5008).absoluteString,
            "http://127.0.0.1:5008/assets/default.css"
        )
    }

    func testSpawnedPageUsesIPv4Loopback() {
        let url = DesktopConfig.pageURL(port: 5008, spawnedByApp: true, discoveredHost: "localhost")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:5008/")
    }

    func testAttachedPageUsesDiscoveredLoopbackHost() {
        XCTAssertEqual(
            DesktopConfig.pageURL(port: 5008, spawnedByApp: false, discoveredHost: "127.0.0.1").host,
            "127.0.0.1"
        )
        XCTAssertEqual(
            DesktopConfig.pageURL(port: 5008, spawnedByApp: false, discoveredHost: nil).host,
            "localhost"
        )
        XCTAssertEqual(
            DesktopConfig.pageURL(port: 5008, spawnedByApp: false, discoveredHost: "evil.example").host,
            "localhost"
        )
    }

    func testExistingListenerIsNeverClaimed() {
        XCTAssertFalse(
            BackendPlanner.claimsExistingListener(
                command: "/Applications/Handbeam.app/Contents/Resources/handbeam-web/erts/bin/beam.smp",
                managedRoot: "/Applications/Handbeam.app/Contents/Resources/handbeam-web"
            )
        )
    }

    func testKernelAllocatesAValidLoopbackPort() throws {
        let port = try XCTUnwrap(DesktopConfig.availableLoopbackPort())
        XCTAssertTrue((1...65535).contains(port))
    }

    func testLaunchOverridesHostPortAndNode() {
        let launch = BackendPlanner.launch(
            releaseRoot: "/tmp/handbeam web",
            port: 5008,
            secret: "secret",
            databasePath: "/Users/me/.handbeam/sigil.db",
            runtimeDir: "/Users/me/.handbeam/runtime",
            inherited: [
                "PORT": "9",
                "PHX_HOST": "localhost",
                "PATH": "/usr/bin",
                "HOME": "/Users/me",
            ]
        )
        XCTAssertEqual(launch.executable, "/bin/sh")
        XCTAssertEqual(launch.arguments, ["/tmp/handbeam web/bin/handbeam", "start"])
        XCTAssertEqual(launch.environment["PHX_HOST"], "127.0.0.1")
        XCTAssertEqual(launch.environment["PORT"], "5008")
        XCTAssertEqual(launch.environment["PHX_SERVER"], "true")
        XCTAssertEqual(launch.environment["DATABASE_PATH"], "/Users/me/.handbeam/sigil.db")
        XCTAssertEqual(launch.environment["RELEASE_DISTRIBUTION"], "none")
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin")
        XCTAssertEqual(launch.pageURL.absoluteString, "http://127.0.0.1:5008/")
    }
}
