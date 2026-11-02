import LoomKit
import SwiftUI

/// The reasoning effort and model profile of one running session. Effort applies to
/// the focused strand from its next turn. A profile applies to the whole session
/// and restarts it, so the daemon refuses the switch while any strand is working
/// and the sheet asks before sending it.
struct SessionSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: SessionRecord
    @State private var pendingProfile: String?

    /// The daemon's vocabulary, shown in the words a person would use.
    private static let levels: [(title: String, wire: String)] = [
        ("Off", "off"), ("Minimal", "minimal"), ("Low", "low"), ("Medium", "medium"),
        ("High", "high"), ("Extra High", "xhigh"), ("Max", "max"),
    ]

    private var controller: SessionController? { model.controller(for: record.id) }

    private var currentLevel: String { controller?.strand?.thinkingLevel ?? "off" }

    private var profileSnapshot: JSONValue? { controller?.surfaces["profile"] }
    private var currentProfile: String { profileSnapshot?["profile"]?.string ?? "" }
    private var availableProfiles: [String] { (profileSnapshot?["available"]?.array ?? []).compactMap(\.string) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings for “\(record.title)”").font(.headline)
            if let controller {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reasoning effort").font(Theme.label)
                    Picker("Reasoning effort", selection: Binding(
                        get: { currentLevel },
                        set: { level in
                            controller.run("set_config", body: ["strand": .string(controller.focusedStrand), "config": ["thinking_level": .string(level)]])
                        }
                    )) {
                        ForEach(Self.levels, id: \.wire) { Text($0.title).tag($0.wire) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Reasoning effort")
                    Text("How much a model may think before answering, from the next turn of “\(controller.focusedStrand)”. A model that cannot reason ignores it.")
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                }
                if !availableProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model profile").font(Theme.label)
                        Picker("Model profile", selection: Binding(
                            get: { currentProfile },
                            set: { pendingProfile = $0 }
                        )) {
                            Text("Default").tag("")
                            ForEach(availableProfiles, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Session profile")
                        Text("Changes which models fill each role. The session restarts, and the daemon refuses while a strand is working.")
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = controller.lastError {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.failure).textSelection(.enabled)
                }
            } else {
                Text("Open the session first. Settings change a running session.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        // A switch reopens the session, which makes a new controller to ask again.
        .task(id: controller.map { ObjectIdentifier($0) }) { controller?.run("profile_get") }
        .confirmationDialog(
            "Switch this session to \(pendingProfile.flatMap { $0.isEmpty ? nil : $0 } ?? "the default models")?",
            isPresented: Binding(get: { pendingProfile != nil }, set: { if !$0 { pendingProfile = nil } }),
            titleVisibility: .visible,
            presenting: pendingProfile
        ) { profile in
            Button("Switch Profile") {
                // An absent name is the default roles, and an empty one is refused.
                controller?.run("profile_set", body: profile.isEmpty ? .object([:]) : ["profile": .string(profile)])
                pendingProfile = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The session restarts so every role is built from the new profile.")
        }
    }
}
