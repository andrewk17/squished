import Foundation

public struct SimulatorDevice: Sendable, Equatable, Identifiable {
    public var id, name, runtime: String
    public static func parse(id: String, data: Data) -> SimulatorDevice? {
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return parse(id: id, dictionary: dict)
    }
    public static func parse(id: String, dictionary: [String: Any]) -> SimulatorDevice? {
        guard (dictionary["state"] as? NSNumber)?.intValue == 3, let name = dictionary["name"] as? String,
              let runtime = dictionary["runtime"] as? String else { return nil }
        let raw = runtime.components(separatedBy: "SimRuntime.").last ?? runtime
        let parts = raw.split(separator: "-").map(String.init)
        let version = parts.dropFirst().joined(separator: ".")
        return SimulatorDevice(id: id, name: name, runtime: (parts.first ?? "iOS") + (version.isEmpty ? "" : " " + version))
    }
}
