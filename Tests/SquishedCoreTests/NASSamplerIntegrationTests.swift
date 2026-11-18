import XCTest
@testable import SquishedCore

final class NASSamplerIntegrationTests: XCTestCase {
    /// Run the real sampler, frame decoder and grouping together, replacing only
    /// the remote filesystem boundary with sanitized Synology-shaped /proc data.
    func testSynologyNamesSurviveNetworkFrameBudgetAcrossAwks() throws {
        let fixture = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/Synology")
        let network = try String(contentsOf: fixture.appendingPathComponent("net-dev.txt"), encoding: .utf8)
        let stats = try String(contentsOf: fixture.appendingPathComponent("process-stat.txt"), encoding: .utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("stat", "cpu 1 0 1 100\ncpu0 1 0 1 100\nbtime 1700000000\n")
        try write("uptime", "1676096.68 5929855.52\n")
        try write("meminfo", "MemTotal: 3866680 kB\nMemAvailable: 1679796 kB\n")
        try write("loadavg", "0.49 0.43 0.45 3/1406 17578\n")
        // Exercise every excluded prefix too, so the awk and Swift filters
        // cannot silently diverge while their spelling lives in two languages.
        let excluded = ["lo", "docker", "veth", "br-", "virbr", "vnet", "tun", "tap", "wg", "zt",
                        "utun", "awdl", "llw", "bridge", "ap", "gif", "stf", "anpi", "ipsec"]
        let rawNetwork = network + excluded.map { "\($0)fixture: 999 0 0 0 0 0 0 0 888 0 0 0 0 0 0 0\n" }.joined()
        try write("net/dev", rawNetwork + "private0: 999 0 0 0 0 0 0 0 888 0 0 0 0 0 0 0\n")
        try write("sys/class/net/private0/tun_flags", "0x1001\n")
        for line in stats.split(separator: "\n") {
            let pid = try XCTUnwrap(line.split(separator: " ").first)
            try write("\(pid)/stat", String(line) + "\n")
        }
        let program = RemoteSampler.program.replacingOccurrences(of: "/proc", with: root.path)
            .replacingOccurrences(of: "/sys/class/net", with: root.appendingPathComponent("sys/class/net").path)
            .replacingOccurrences(of: "os = command(\"uname -s\")", with: "os = \"Linux\"")
        var checked = 0
        for variant in ["awk", "mawk", "gawk", "busybox awk"] {
            let lookup = Process()
            lookup.executableURL = URL(fileURLWithPath: "/bin/sh")
            lookup.arguments = ["-c", "command -v " + String(variant.split(separator: " ")[0]) + " >/dev/null"]
            try lookup.run(); lookup.waitUntilExit()
            guard lookup.terminationStatus == 0 else { continue }
            checked += 1
            let done = expectation(description: "Synology frames: \(variant)")
            let collector = FrameCollector(done)
            let session = SSHSession(onFrame: { collector.append($0) }, onExit: { _, _ in })
            let script = RemoteSampler.script(interval: 0.1, awkCommand: variant)
                .replacingOccurrences(of: SSHCommand.quote(RemoteSampler.program), with: SSHCommand.quote(program))
            session.launch(executable: "/bin/sh", arguments: ["-c", script])
            wait(for: [done], timeout: 10)
            session.terminateAndWait()
            XCTAssertGreaterThanOrEqual(collector.frames.count, 3, variant)
            for frame in collector.frames {
                let bytes = "@@FLEET 1 \(frame.sequence)\n@@END \(frame.sequence)\n".utf8.count
                    + frame.sections.reduce(0) { $0 + $1.key.utf8.count + 2 + $1.value.utf8.count }
                XCTAssertLessThan(bytes, 2048, variant)
                let emittedNetwork = try XCTUnwrap(frame.sections["net"])
                XCTAssertEqual(LinuxParser.networkInterfaces(emittedNetwork), LinuxParser.networkInterfaces(rawNetwork), variant)
                XCTAssertEqual(emittedNetwork.split(separator: "\n").count, 3, variant)
                let snapshot = frame.snapshot(previousCPU: nil)
                let app = try XCTUnwrap(snapshot.groups.first { $0.name == "app-one-worker0" }, variant)
                XCTAssertEqual(app.memoryBytes, 185641 * 4096, variant)
                XCTAssertTrue(snapshot.groups.contains { $0.name == "media worker 01" }, variant)
                XCTAssertTrue(snapshot.groups.contains { $0.name == "worker-entry000" }, variant)
                XCTAssertTrue(snapshot.groups.contains { $0.name == "Kernel workers" }, variant)
                XCTAssertTrue(app.processes.contains { $0.name == "app-one-worker0" }, variant)
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
