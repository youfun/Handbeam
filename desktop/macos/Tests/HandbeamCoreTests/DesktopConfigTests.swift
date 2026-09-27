import XCTest
@testable import HandbeamCore

final class DesktopConfigTests: XCTestCase {
    func testHealthCheckUsesTheDesktopIdentityEndpoint() {
        XCTAssertEqual(
            DesktopConfig.healthURL(port: 5008).absoluteString,
            "http://127.0.0.1:5008/desktop-health"
        )
    }

    func testLoopbackListenerPortsParsesLsofFieldOutput() {
        let output = """
        p100
        f39
        n127.0.0.1:56243
        f54
        n127.0.0.1:5002
        p200
        f10
        n[::1]:60302
        f11
        n*:4369
        f12
        n10.0.0.8:9999
        f13
        n127.0.0.1:not-a-port
        f14
        n127.0.0.1:5002
        """

        XCTAssertEqual(
            DesktopConfig.loopbackListenerPorts(lsofOutput: output),
            [5002, 56243, 60302]
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

    func testPreferredPortKeepsTheDesktopOriginStable() {
        XCTAssertEqual(
            DesktopConfig.preferredPort(
                environment: nil,
                stored: "51234",
                availablePort: { 54321 }
            ),
            51234
        )
        XCTAssertEqual(
            DesktopConfig.preferredPort(
                environment: "5008",
                stored: "51234",
                availablePort: { 54321 }
            ),
            5008
        )
        XCTAssertEqual(
            DesktopConfig.preferredPort(
                environment: nil,
                stored: "invalid",
                availablePort: { 54321 }
            ),
            54321
        )
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
