import Darwin
import Foundation

/// Pure decisions for the macOS shell. The app process owns a backend only when
/// it spawned that process in this lifetime. A server that is already listening
/// is attached to, never signalled on quit.
public enum DesktopConfig {
    public static let defaultPort = 5008
    public static let bundleIdentifier = "com.youfun.handbeam"
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    public static func healthURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/assets/default.css")!
    }

    /// Spawned servers use 127.0.0.1 so the page host matches `PHX_HOST` and does
    /// not depend on `localhost` resolving to `::1`. An attached `./start.sh`
    /// defaults to `PHX_HOST=localhost`; a non-loopback discovered host is ignored.
    public static func pageURL(port: Int, spawnedByApp: Bool, discoveredHost: String?) -> URL {
        let host: String
        if spawnedByApp {
            host = "127.0.0.1"
        } else if let discovered = sanitizeHost(discoveredHost) {
            host = discovered
        } else {
            host = "localhost"
        }
        return URL(string: "http://\(host):\(port)/")!
    }

    public static func sanitizeHost(_ raw: String?) -> String? {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty
        else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 {
            host = String(host.dropFirst().dropLast())
        }
        guard loopbackHosts.contains(host) else { return nil }
        return host
    }

    /// Ask the kernel for an unused loopback port. The listener is closed before
    /// the backend starts, so callers must still handle the unlikely bind race.
    public static func availableLoopbackPort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: 0,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

public struct BackendLaunch: Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var pageURL: URL
}

public enum BackendPlanner {
    /// Never claim a listener we did not spawn. `ppid == 1` is not proof the
    /// desktop app started it: a manual `bin/handbeam start` can be reparented too.
    public static func claimsExistingListener(command: String?, managedRoot: String?) -> Bool {
        _ = command
        _ = managedRoot
        return false
    }

    public static func launch(
        releaseRoot: String,
        port: Int,
        secret: String,
        databasePath: String,
        runtimeDir: String,
        inherited: [String: String]
    ) -> BackendLaunch {
        var env = inherited
        let overrides = [
            "PHX_SERVER": "true",
            "PORT": String(port),
            "PHX_HOST": "127.0.0.1",
            "DATABASE_PATH": databasePath,
            "SECRET_KEY_BASE": secret,
            "RELEASE_TMP": runtimeDir,
            "HANDBEAM_RUNTIME_DIR": runtimeDir,
            "RELEASE_DISTRIBUTION": "none",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "LC_ALL": inherited["LC_ALL"] ?? "en_US.UTF-8",
        ]
        for (key, value) in overrides {
            env[key] = value
        }
        let bin = (releaseRoot as NSString).appendingPathComponent("bin/handbeam")
        return BackendLaunch(
            executable: "/bin/sh",
            arguments: [bin, "start"],
            environment: env,
            workingDirectory: releaseRoot,
            pageURL: DesktopConfig.pageURL(port: port, spawnedByApp: true, discoveredHost: nil)
        )
    }
}
