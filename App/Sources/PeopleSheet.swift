import LoomKit
import SwiftUI

/// The daemon's people: the owner and everyone invited, with each one's credential
/// and where they can sign in. These are owner commands on the first daemon, and a
/// person can also rename themselves. Rotating a credential or revoking access
/// asks first, because each ends sessions someone may be using.
struct PeopleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var people: [Principal] = []
    @State private var selection: String?
    @State private var memberships: [Membership] = []
    @State private var signins: [Signin] = []
    @State private var ownName = ""
    @State private var newName = ""
    @State private var invitation: Invitation?
    @State private var confirming: Confirmation?
    @State private var error: String?

    private enum Confirmation: Identifiable {
        case rotate(Principal)
        case revoke(Principal)
        var id: String {
            switch self {
            case .rotate(let person): return "rotate-\(person.id)"
            case .revoke(let person): return "revoke-\(person.id)"
            }
        }
    }

    private var daemon: DaemonConnection? { model.daemons.first { !$0.isRemote } ?? model.daemons.first }
    private var control: ControlClient? { daemon?.control }
    private var selected: Principal? { people.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("People").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            HSplitView {
                list.frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
                detail.frame(minWidth: 300)
            }
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.failure).padding(12).textSelection(.enabled)
            }
        }
        .frame(width: 640, height: 460)
        .task { await reload() }
        .onChange(of: selection) { Task { await loadDetail() } }
        .confirmationDialog(
            confirming.map(title) ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { item in
            switch item {
            case .rotate(let person):
                Button("Rotate Credential", role: .destructive) { rotate(person) }
            case .revoke(let person):
                Button("Revoke Access", role: .destructive) { revoke(person) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            switch item {
            case .rotate: Text("Their current credential stops working and a new claim is made for them to redeem.")
            case .revoke: Text("They are signed out everywhere and can no longer open any session.")
            }
        }
    }

    private func title(_ item: Confirmation) -> String {
        switch item {
        case .rotate(let person): return "Rotate \(person.name)’s credential?"
        case .revoke(let person): return "Revoke \(person.name)’s access?"
        }
    }

    /// Buttons rather than a table, because a table's rows are not in the
    /// accessibility tree, and a person who uses VoiceOver needs them there.
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(people) { person in
                    Button {
                        selection = person.id
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(person.name + (person.isOwner ? " (you)" : ""))
                            Text(person.credential.words).font(Theme.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(selection == person.id ? Theme.tintStrong : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusInner))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Person \(person.name)")
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let invitation, let address = daemon?.claimAddress {
                HandoverView(invitation: invitation, address: address) { self.invitation = nil }
            } else if let person = selected {
                Text(person.name).font(.title3)
                Text(person.id).font(Theme.meta).foregroundStyle(.tertiary)
                HStack {
                    TextField("Name", text: $newName).accessibilityLabel("Person name")
                    Button("Save Name") { saveName(person) }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newName == person.name)
                }
                Text("Credential: \(person.credential.words)").foregroundStyle(.secondary)
                if !person.isOwner {
                    HStack {
                        Button("Rotate Credential…") { confirming = .rotate(person) }
                        Button("Revoke Access…", role: .destructive) { confirming = .revoke(person) }
                    }
                }
                section("Sessions") {
                    if memberships.isEmpty { Text(person.isOwner ? "Every session." : "None.").foregroundStyle(.secondary) }
                    ForEach(memberships) { Text("\($0.name.isEmpty ? $0.sessionID : $0.name) · \($0.role)") }
                }
                section("Browser sign-ins") {
                    if signins.isEmpty { Text("None.").foregroundStyle(.secondary) }
                    ForEach(signins) { signin in
                        HStack {
                            Text(signin.fingerprint).font(Theme.meta)
                            Text(signin.issuedAt.formatted(date: .abbreviated, time: .shortened)).font(Theme.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Revoke") { revokeLogin(person, signin) }
                                .accessibilityLabel("Revoke sign-in \(signin.fingerprint)")
                        }
                    }
                }
            } else {
                Text("Choose a person.").foregroundStyle(.secondary)
            }
            Spacer()
            Divider()
            HStack {
                TextField("Your name", text: $ownName).accessibilityLabel("Your name")
                Button("Rename Me", action: renameSelf)
                    .disabled(ownName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.label)
            content()
        }
    }

    // MARK: Commands

    private func reload() async {
        guard let control else { return }
        do {
            people = try await control.principals()
            ownName = people.first { $0.isOwner }?.name ?? ""
            if selection == nil { selection = people.first { !$0.isOwner }?.id ?? people.first?.id }
            await loadDetail()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadDetail() async {
        guard let control, let person = selected else { return }
        newName = person.name
        memberships = (try? await control.memberships(principalID: person.id)) ?? []
        signins = (try? await control.signins(principalID: person.id)) ?? []
    }

    private func run(_ command: @escaping (ControlClient) async throws -> Void) {
        guard let control else { return }
        error = nil
        Task {
            do {
                try await command(control)
                await reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func saveName(_ person: Principal) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        run { try await $0.renamePrincipal(principalID: person.id, name: name) }
    }

    private func renameSelf() {
        let name = ownName.trimmingCharacters(in: .whitespaces)
        run { try await $0.renamePrincipal(principalID: nil, name: name) }
    }

    private func revoke(_ person: Principal) {
        run { try await $0.revokeCredentials(principalID: person.id) }
    }

    private func revokeLogin(_ person: Principal, _ signin: Signin) {
        run { try await $0.revokeLogin(principalID: person.id, fingerprint: signin.fingerprint) }
    }

    private func rotate(_ person: Principal) {
        guard let control else { return }
        Task {
            do {
                invitation = try await control.rotateCredential(principalID: person.id)
                await reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
