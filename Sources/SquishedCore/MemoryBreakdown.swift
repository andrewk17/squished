import Foundation

public struct MemorySegment: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var bytes: UInt64
}
public struct MemoryBreakdown: Sendable, Equatable {
    public var segments: [MemorySegment]
    public var total: UInt64
    public var swapUsed: UInt64
    public static func mac(total: UInt64, internalBytes: UInt64, purgeable: UInt64, wired: UInt64,
                           compressed: UInt64, external: UInt64, free: UInt64, swapUsed: UInt64) -> MemoryBreakdown {
        MemoryBreakdown(segments: [MemorySegment(name: "Apps", bytes: internalBytes > purgeable ? internalBytes - purgeable : 0),
                                  MemorySegment(name: "Wired", bytes: wired), MemorySegment(name: "Compressed", bytes: compressed),
                                  MemorySegment(name: "Cached files", bytes: external &+ purgeable), MemorySegment(name: "Free", bytes: free)], total: total, swapUsed: swapUsed)
    }
    public static func linux(_ text: String) -> MemoryBreakdown? {
        var values: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(whereSeparator: \.isWhitespace)
            if f.count >= 2, let n = UInt64(f[1]), n <= UInt64.max / 1024 { values[String(f[0].dropLast())] = n * 1024 }
        }
        guard let total = values["MemTotal"], total > 0 else { return nil }
        let free = values["MemFree", default: 0], shared = values["Shmem", default: 0]
        let cache = values["Buffers", default: 0] &+ values["Cached", default: 0] &+ values["SReclaimable", default: 0]
        let apps = max(0, Double(total) - Double(free) - Double(cache))
        return MemoryBreakdown(segments: [MemorySegment(name: "Apps", bytes: UInt64(min(Double(total), apps))),
                                         MemorySegment(name: "Shared/tmpfs", bytes: shared),
                                         MemorySegment(name: "Cache", bytes: cache > shared ? cache - shared : 0),
                                         MemorySegment(name: "Free", bytes: free)], total: total,
                               swapUsed: values["SwapTotal", default: 0] > values["SwapFree", default: 0] ? values["SwapTotal", default: 0] - values["SwapFree", default: 0] : 0)
    }
}
