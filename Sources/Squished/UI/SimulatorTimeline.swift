import SwiftUI
import SquishedCore

struct SimulatorTimeline: View {
    let sessions: [SimulatorSession]
    let hosts: [HostConfig]
    let now: Date
    @Environment(\.colorScheme) private var scheme
    private var windowStart: Date { now.addingTimeInterval(-12 * 60 * 60) }
    private struct Lane: Identifiable {
        var id, name: String
        var sessions: [SimulatorSession]
        var lastUse: Date
    }
    private var lanes: [Lane] {
        let visible = sessions.filter { $0.start <= now && ($0.end ?? now) > windowStart }
        return Dictionary(grouping: visible, by: \.laneID).map { id, sessions in
            let ordered = sessions.sorted { $0.start < $1.start }
            return Lane(id: id, name: ordered.last?.name ?? "", sessions: ordered,
                        lastUse: ordered.map { min($0.end ?? now, now) }.max() ?? .distantPast)
        }.sorted { $0.lastUse == $1.lastUse ? $0.id < $1.id : $0.lastUse > $1.lastUse }.prefix(6).map { $0 }
    }

    var body: some View {
        if !lanes.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                SectionCaption(title: "LAST 12 HOURS")
                VStack(spacing: 0) {
                    ForEach(lanes) { lane in
                        HStack(spacing: 7) {
                            Text(lane.name).font(Theme.fine).lineLimit(1).truncationMode(.tail)
                                .frame(width: 130, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2).fill(Theme.control(scheme))
                                    ForEach(lane.sessions) { session in
                                        segment(session, width: geometry.size.width)
                                    }
                                }
                            }.frame(height: 6)
                        }.frame(height: 14)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(0..<4) { index in
                        Text(index == 3 ? "now" : windowStart.addingTimeInterval(Double(index) * 4 * 60 * 60)
                            .formatted(.dateTime.hour().minute()))
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        if index < 3 { Spacer(minLength: 0) }
                    }
                }.padding(.leading, 137)
            }
        }
    }

    private func segment(_ session: SimulatorSession, width: CGFloat) -> some View {
        let start = max(0, session.start.timeIntervalSince(windowStart) / (12 * 60 * 60))
        let end = min(1, (session.end ?? now).timeIntervalSince(windowStart) / (12 * 60 * 60))
        let left = min(max(0, width - 1.5), width * start)
        let length = max(1.5, width * end - left)
        let color: Color = session.platform == .ios ? .blue : .green
        return RoundedRectangle(cornerRadius: 2).fill(color.opacity(session.end == nil ? 1 : 0.85))
            .overlay {
                if session.end == nil { RoundedRectangle(cornerRadius: 2).stroke(.primary, lineWidth: 1) }
            }
            .frame(width: length).offset(x: left)
            .help(tooltip(session)).accessibilityLabel(tooltip(session))
    }

    private func tooltip(_ session: SimulatorSession) -> String {
        let host = hosts.first { $0.id.uuidString == session.hostID }?.displayName ?? "Removed machine"
        let start = session.start.formatted(date: .abbreviated, time: .shortened)
        let end = session.end?.formatted(date: .abbreviated, time: .shortened) ?? "now"
        let duration = FleetFormat.duration(max(0, (session.end ?? now).timeIntervalSince(session.start)))
        return "\(session.name)\n\(host)\n\(start) – \(end)\n\(duration)"
    }
}
