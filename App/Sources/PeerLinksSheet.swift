import LoomKit
import SwiftUI

/// The peer links of one strand: which other sessions it may message, and which may
/// message it. A link is one direction, and a wake setting says whether a message
/// may start an idle recipient or waits for it to be busy. All of it is the owner's.
struct PeerLinksSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: SessionRecord

    @State private var links: [PeerLink] = []
    @State private var targetID = ""
    @State private var targetStrand = "main"
    @State private var wakes = false
    @State private var unlinking: PeerLink?
    @State private var error: String?
    @State private var hasLoaded = false

    private var daemon: DaemonConnection? { model.daemon(holding: record.id) }
    private var strand: String { model.controller(for: record.id)?.focusedStrand ?? "main" }

    /// Other running sessions on the same daemon, the only ones a link can reach.
    private var candidates: [SessionRecord] {
        (daemon?.sessions ?? []).filter { $0.id != record.id && $0.state.isResident }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Peers of “\(strand)” in “\(record.title)”").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                if hasLoaded && links.isEmpty {
                    Text("No links. This strand cannot message other sessions and none can message it.").foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    HStack {
                        Image(systemName: link.direction == .outgoing ? "arrow.right" : "arrow.left").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name(of: link))
                            Text("\(link.strand) · \(link.direction == .outgoing ? "this strand may message it" : "it may message this strand")\(wakeWords(link))")
                                .font(Theme.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if link.direction == .outgoing {
                            Button("Unlink…") { unlinking = link }
                                .accessibilityLabel("Unlink \(name(of: link))")
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Link to another session").font(Theme.label)
                if candidates.isEmpty {
                    Text("No other session is running.").foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { other in
                        Button {
                            targetID = other.id
                        } label: {
                            HStack {
                                Image(systemName: targetID == other.id ? "largecircle.fill.circle" : "circle")
                                Text(other.title).lineLimit(1)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Link target \(other.title)")
                    }
                    TextField("Their strand", text: $targetStrand).accessibilityLabel("Target strand")
                    Toggle("A message may wake it when it is idle", isOn: $wakes)
                        .accessibilityLabel("May wake")
                    HStack {
                        Spacer()
                        Button("Link", action: link)
                            .buttonStyle(.borderedProminent)
                            .disabled(targetID.isEmpty || targetStrand.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.failure).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await load() }
        .confirmationDialog(
            "Unlink \(unlinking.map(name) ?? "")?",
            isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }),
            titleVisibility: .visible,
            presenting: unlinking
        ) { target in
            Button("Remove Link", role: .destructive) { unlink(target) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This strand can no longer message that session. Its own link to this strand is revoked too, when it is running.")
        }
    }

    private func name(of link: PeerLink) -> String {
        if !link.sessionName.isEmpty { return link.sessionName }
        return daemon?.sessions.first { $0.id == link.sessionID }?.title ?? link.sessionID
    }

    private func wakeWords(_ link: PeerLink) -> String {
        switch link.wakes {
        case true?: return " · may wake it"
        case false?: return " · only when busy"
        case nil: return ""
        }
    }

    private func load() async {
        guard let control = daemon?.control else { return }
        do {
            links = try await control.peerLinks(sessionID: record.id, strand: strand)
            hasLoaded = true
        } catch {
            self.error = error.localizedDescription
            hasLoaded = true
        }
    }

    private func link() {
        guard let control = daemon?.control else { return }
        let target = targetStrand.trimmingCharacters(in: .whitespaces)
        error = nil
        Task {
            do {
                try await control.linkPeers(sessionID: record.id, strand: strand, targetSession: targetID, targetStrand: target, wakes: wakes)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func unlink(_ link: PeerLink) {
        guard let control = daemon?.control else { return }
        error = nil
        Task {
            do {
                try await control.unlinkPeers(sessionID: record.id, strand: strand, targetSession: link.sessionID, targetStrand: link.strand)
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
