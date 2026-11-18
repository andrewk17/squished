import XCTest
@testable import SquishedCore

final class FileFeedIntegrationTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("squished-feeds-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }
    func testJobsFolderReadsRealFilesAndIgnoresMalformedEntries() throws {
        let root = try temporaryDirectory(), jobs = root.appendingPathComponent("jobs")
        XCTAssertTrue(FileFeeds.read(root: root).jobs.isEmpty)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try write(#"{"name":"Nightly task","status":"ok","finishedAt":"2026-11-14T22:10:00.000Z","durationSeconds":49,"message":"Completed","expectedEverySeconds":3600,"logPath":"/tmp/task.log"}"#, to: jobs.appendingPathComponent("a.json"))
        for status in ["warning", "failed", "running"] {
            try write("{\"name\":\"\(status)\",\"status\":\"\(status)\"}", to: jobs.appendingPathComponent(status + ".json"))
        }
        try write(#"{"name":"Optional fields","status":"ok","finishedAt":false,"durationSeconds":-1,"expectedEverySeconds":true}"#, to: jobs.appendingPathComponent("optional.json"))
        for (name, text) in ["bad.json": "{", "unknown.json": #"{"name":"Unknown","status":"other"}"#,
                             "missing.json": #"{"name":"Missing"}"#, "ignore.txt": #"{"name":"Ignored","status":"ok"}"#] {
            try write(text, to: jobs.appendingPathComponent(name))
        }
        let feeds = FileFeeds.read(root: root)
        XCTAssertEqual(feeds.jobs.count, 5)
        let job = try XCTUnwrap(feeds.jobs.first)
        XCTAssertEqual(job.name, "Nightly task")
        XCTAssertEqual(job.durationSeconds, 49)
        XCTAssertEqual(job.message, "Completed")
        XCTAssertEqual(job.logPath, "/tmp/task.log")
        let finished = try XCTUnwrap(job.finishedAt)
        XCTAssertEqual(job.title(at: finished.addingTimeInterval(7200)), "Healthy")
        XCTAssertEqual(job.title(at: finished.addingTimeInterval(7201)), "Overdue")
        XCTAssertTrue(job.showsMenuBarWarning(at: finished.addingTimeInterval(7201)))
        // A run in progress is judged by when it was last heard from, not by the previous finish.
        try write(#"{"name":"Slow run","status":"running","finishedAt":"2026-11-14T10:00:00Z","updatedAt":"2026-11-14T13:00:00Z","durationSeconds":8000,"expectedEverySeconds":3600}"#, to: jobs.appendingPathComponent("slow.json"))
        let slow = try XCTUnwrap(FileFeeds.read(root: root).jobs.first { $0.name == "Slow run" })
        let started = try XCTUnwrap(slow.updatedAt)
        XCTAssertEqual(slow.title(at: started.addingTimeInterval(16000)), "Running")
        XCTAssertFalse(slow.showsMenuBarWarning(at: started.addingTimeInterval(16000)))
        XCTAssertEqual(slow.title(at: started.addingTimeInterval(16001)), "Overdue")
        XCTAssertTrue(slow.showsMenuBarWarning(at: started.addingTimeInterval(16001)))
        try FileManager.default.removeItem(at: jobs.appendingPathComponent("slow.json"))
        // With no updatedAt field, the file's modification time stands in.
        XCTAssertNotNil(feeds.jobs.first { $0.name == "running" }?.updatedAt)
        let optional = try XCTUnwrap(feeds.jobs.first { $0.name == "Optional fields" })
        XCTAssertNil(optional.finishedAt)
        XCTAssertNil(optional.durationSeconds)
        XCTAssertNil(optional.expectedEverySeconds)
        for entry in feeds.jobs where entry.status != .ok {
            XCTAssertEqual(entry.title(at: finished), entry.name.capitalized)
            XCTAssertEqual(entry.showsMenuBarWarning(at: finished), entry.status == .failed)
        }
        try write(#"{"name":"Replaced","status":"running"}"#, to: jobs.appendingPathComponent("a.json"))
        XCTAssertEqual(FileFeeds.read(root: root).jobs.first?.name, "Replaced")
        try FileManager.default.removeItem(at: jobs)
        XCTAssertTrue(FileFeeds.read(root: root).jobs.isEmpty)
    }
    func testDeviceLabelsReadOptionalFieldsAndFileReplacement() throws {
        let root = try temporaryDirectory(), file = root.appendingPathComponent("devices.json")
        XCTAssertEqual(FileFeeds.read(root: root).deviceLabels, DeviceLabels())
        try write(#"{"updatedAt":"2026-11-14T22:10:00Z","unlabeledText":"Available","devices":[{"id":"4F37EC79-58E8-4BDF-916E-D03CA96B5ACA","label":"project: capture","group":"stable","detail":"slot 1","since":"2026-11-14T22:02:00.123Z"},{"id":"AVD","label":"project: run"},{}],"notes":[{"text":"Two sessions","level":"info"},{"text":"Waiting","level":"warning"},{}]}"#, to: file)
        let labels = FileFeeds.read(root: root).deviceLabels
        XCTAssertNotNil(labels.updatedAt)
        XCTAssertEqual(labels.unlabeledText, "Available")
        let entry = try XCTUnwrap(labels.entry(for: "4f37ec79-58e8-4bdf-916e-d03ca96b5aca"))
        XCTAssertEqual(entry.colorKey, "stable")
        XCTAssertEqual(entry.detail, "slot 1")
        XCTAssertNotNil(entry.since)
        XCTAssertTrue(entry.tooltip.contains("slot 1"))
        XCTAssertEqual(labels.entry(for: "AVD")?.colorKey, "project")
        XCTAssertNil(labels.entry(for: "avd"))
        XCTAssertEqual(labels.notes.map(\.isWarning), [false, true])
        try write("{}", to: file)
        XCTAssertEqual(FileFeeds.read(root: root).deviceLabels, DeviceLabels())
        try write("malformed", to: file)
        XCTAssertEqual(FileFeeds.read(root: root).deviceLabels, DeviceLabels())
    }
    #if os(macOS)
    func testFileSystemEventsFollowMissingFoldersAndAtomicReplacements() throws {
        let parent = try temporaryDirectory(), root = parent.appendingPathComponent("feeds")
        let initial = expectation(description: "missing folder"), job = expectation(description: "created job")
        let replaced = expectation(description: "atomic replacement"), edited = expectation(description: "in-place edit")
        let removed = expectation(description: "deleted folder"), recreated = expectation(description: "recreated folder")
        let labeled = expectation(description: "device file created"), relabeled = expectation(description: "device file replaced")
        for item in [initial, job, replaced, edited, removed, recreated, labeled, relabeled] { item.assertForOverFulfill = false }
        let watcher = FileFeedWatcher(root: root) { feeds in
            if feeds.deviceLabels.unlabeledText == "First" { labeled.fulfill() }
            if feeds.deviceLabels.unlabeledText == "Second" { relabeled.fulfill() }
            switch feeds.jobs.first?.name {
            case "Created": job.fulfill()
            case "Replaced": replaced.fulfill()
            case "Edited": edited.fulfill()
            case "Recreated": recreated.fulfill()
            default:
                if FileManager.default.fileExists(atPath: root.path) { removed.fulfill() }
                else { initial.fulfill() }
            }
        }
        watcher.start()
        defer { watcher.stop() }
        wait(for: [initial], timeout: 5)
        let jobs = root.appendingPathComponent("jobs"), file = jobs.appendingPathComponent("task.json")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try write(#"{"name":"Created","status":"ok"}"#, to: file)
        wait(for: [job], timeout: 5)
        try write(#"{"name":"Replaced","status":"failed"}"#, to: file)
        wait(for: [replaced], timeout: 5)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"name":"Edited","status":"ok"}"#.utf8))
        try handle.close()
        wait(for: [edited], timeout: 5)
        try FileManager.default.removeItem(at: jobs)
        wait(for: [removed], timeout: 5)
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try write(#"{"name":"Recreated","status":"ok"}"#, to: file)
        wait(for: [recreated], timeout: 5)
        let deviceFile = root.appendingPathComponent("devices.json")
        try write(#"{"unlabeledText":"First"}"#, to: deviceFile)
        wait(for: [labeled], timeout: 5)
        try write(#"{"unlabeledText":"Second"}"#, to: deviceFile)
        wait(for: [relabeled], timeout: 5)
    }
    func testLocalSamplerReadsRealProcessResources() throws {
        let sample = expectation(description: "real process census")
        let retained = expectation(description: "light sample retains known groups")
        sample.assertForOverFulfill = false
        retained.assertForOverFulfill = false
        let sampler = LocalMacSampler(interval: 1) { _, snapshot in
            if !snapshot.hasSimulatorSample {
                XCTAssertFalse(snapshot.groups.isEmpty)
                retained.fulfill()
                return
            }
            XCTAssertFalse(snapshot.groups.isEmpty)
            let ownGroup = snapshot.groups.first { $0.processes.contains { $0.pid == ProcessInfo.processInfo.processIdentifier } }
            XCTAssertGreaterThan(ownGroup?.memoryBytes ?? 0, 0)
            // Existing running devices are observed read-only; never boot or stop one.
            for device in snapshot.simulatorDevices where device.platform == .ios {
                XCTAssertGreaterThan(snapshot.groups.first { "sim:" + ($0.deviceID?.uppercased() ?? "") == device.id }?.memoryBytes ?? 0, 0,
                                     "Running local device must retain its process group's resources")
            }
            sample.fulfill()
        }
        let devicesRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        let devices = ((try? FileManager.default.contentsOfDirectory(at: devicesRoot, includingPropertiesForKeys: nil)) ?? []).compactMap { url -> SimulatorDevice? in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("device.plist")) else { return nil }
            return SimulatorDevice.parse(id: url.lastPathComponent, data: data)
        }
        sampler.setDevices(devices)
        sampler.setIncludesProcesses(true)
        sampler.start()
        defer { sampler.stop() }
        wait(for: [sample], timeout: 10)
        sampler.setIncludesProcesses(false)
        wait(for: [retained], timeout: 5)
    }
    #endif
}
