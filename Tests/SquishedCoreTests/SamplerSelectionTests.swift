import XCTest
@testable import SquishedCore

final class SamplerSelectionTests: XCTestCase {
    func testBucketSelectionMatchesFullScanByteForByte() throws {
        let program = RemoteSampler.program
        let start = try XCTUnwrap(program.range(of: "split(\"\", selected)"))
        let end = try XCTUnwrap(program.range(of: "previousTime = now", range: start.upperBound..<program.endIndex))
        let selection = String(program[start.lowerBound..<end.lowerBound])
        var reference = selection.replacingOccurrences(
            of: "for (pid = head[key]; pid != \"\"; pid = nextpid[pid]) if (!(pid in sent))",
            with: "for (pid in seen) if (keys[pid] == key && !(pid in sent))"
        )
        let rankingStart = try XCTUnwrap(reference.range(of: "split(\"\", topkeys)"))
        let rankingEnd = try XCTUnwrap(reference.range(of: "count = 0", range: rankingStart.upperBound..<reference.endIndex))
        reference.replaceSubrange(rankingStart.lowerBound..<rankingEnd.lowerBound, with: #"""
            split("", ranked)
            for (rank = 1; rank <= 8; rank++) {
                winner = ""; score = -1
                for (key in gn) if (!(key in ranked)) {
                    value = metric == 1 ? gcpu[key] : grss[key]
                    if (value > score || (value == score && key < winner)) { score = value; winner = key }
                }
                if (winner == "") break
                ranked[winner] = 1
                selected[winner] = 1
                if (rank <= 3) wanted[winner] = metric
            }
        }
        """# + "\n")
        XCTAssertNotEqual(selection, reference)
        // Repeated ticks, CPU/RSS ties, unequal bucket sizes, long keys and
        // crowded frames exercise ranking, numeric PID tie breaks and the cap.
        let fixture = #"""
        function emit(line) { print line; wireBytes += length(line) + 1 }
        BEGIN {
            for (tick = 1; tick <= 3; tick++) {
                split("", seen); split("", gcpu); split("", grss); split("", gn)
                for (p = 1; p <= 430; p++) {
                    pid = "" (p + 9)
                    key = "p group " (p % (tick == 3 ? 2 : 29)) " with a long key for wire truncation"
                    seen[pid] = 1; keys[pid] = key
                    pcpu[pid] = p % 7; prss[pid] = p % 11
                    pname[pid] = "worker " p
                    gcpu[key] += pcpu[pid]; grss[key] += prss[pid]; gn[key]++
                }
                wireBytes = tick == 2 ? 1100 : 700; seq = tick
        """#
        for command in [["/usr/bin/mawk"], ["/usr/bin/gawk"], ["/usr/bin/busybox", "awk"]]
        where FileManager.default.isExecutableFile(atPath: command[0]) {
            func run(_ code: String) throws -> Data {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: command[0])
                process.arguments = Array(command.dropFirst()) + [fixture + "\n" + code + "\n} }\n"]
                process.standardOutput = pipe
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, command.joined(separator: " "))
                return output
            }
            let actual = try run(selection)
            XCTAssertFalse(actual.isEmpty)
            XCTAssertEqual(actual, try run(reference), command.joined(separator: " "))
        }
    }
}
