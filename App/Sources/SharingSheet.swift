import LoomKit
import SwiftUI

/// Who can use a session, and the way to add someone. Everything here is an owner
/// command on the daemon holding the session. A session shares what is already in
/// its transcript with anyone invited, so a private session first has to be made
/// shareable, which the daemon does by stopping it, giving it a memory of its own
/// and opening it again.
struct SharingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: SessionRecord

    @State private var members: SessionMembers?
    @State private var removing: SessionMember?
    @State private var isConfirmingShareable = false
    @State private var inviteeName = ""
    @State private var role = MemberRole.operator_
    @State private var invitation: Invitation?
    @State private var error: String?
    @State private var isWorking = false

    private var daemon: DaemonConnection? { model.daemon(holding: record.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share “\(record.title)”").font(.headline)

            if let invitation, let address = daemon?.claimAddress {
                HandoverView(invitation: invitation, address: address) {
                    self.invitation = nil
                    Task { await load() }
                }
            } else if let members {
                if members.isShareable {
                    memberList(members)
                    Divider()
                    inviteForm
                } else {
                    privateNotice
                }
            } else {
                ProgressView().controlSize(.small)
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
        .frame(width: 460)
        .task { await load() }
        .confirmationDialog(
            "Remove \(removing?.name ?? "this person")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { member in
            Button("Remove Access", role: .destructive) { change { try await $0.revokeMembership(sessionID: record.id, principalID: member.principalID) } }
            Button("Cancel", role: .cancel) {}
        } message: { member in
            Text("\(member.name) can no longer open this session. Their connection ends now.")
        }
        .confirmationDialog("Make this session shareable?", isPresented: $isConfirmingShareable, titleVisibility: .visible) {
            Button("Make Shareable", action: makeShareable)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone you invite will see everything already said in it. The session is stopped and opened again, so a run in progress ends.")
        }
    }

    private func memberList(_ members: SessionMembers) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People with access").font(Theme.label)
            if members.members.isEmpty {
                Text("Only you.").foregroundStyle(.secondary)
            }
            ForEach(members.members) { member in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.name)
                        Text(member.principalID).font(Theme.meta).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(member.role == "operator" ? "Operator" : "Observer").foregroundStyle(.secondary)
                    Button(member.role == "operator" ? "Make Observer" : "Make Operator") {
                        let next: MemberRole = member.role == "operator" ? .observer : .operator_
                        change { try await $0.setRole(sessionID: record.id, principalID: member.principalID, role: next) }
                    }
                    .accessibilityLabel(member.role == "operator" ? "Make \(member.name) an observer" : "Make \(member.name) an operator")
                    Button("Remove") { removing = member }
                        .accessibilityLabel("Remove \(member.name)")
                }
            }
        }
    }

    private var inviteForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Invite someone").font(Theme.label)
            TextField("Their name", text: $inviteeName)
                .accessibilityLabel("Invitee name")
            Picker("Role", selection: $role) {
                ForEach(MemberRole.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Invitee role")
            Text(role.summary).font(Theme.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Invite", action: invite)
                    .buttonStyle(.borderedProminent)
                    .disabled(inviteeName.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
        }
    }

    private var privateNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This session is private.").font(Theme.label)
            Text("Its memory is shared with other sessions in the same folder, so inviting someone would show them more than this conversation. Make it shareable first.")
                .foregroundStyle(.secondary)
            Button("Make Shareable…") { isConfirmingShareable = true }
        }
    }

    // MARK: Commands

    private func load() async {
        guard let control = daemon?.control else { return }
        do {
            members = try await control.sessionMembers(sessionID: record.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Runs one command, then reads the member list again so the sheet states what
    /// the daemon now holds rather than what was asked for.
    private func change(_ command: @escaping (ControlClient) async throws -> Void) {
        guard let control = daemon?.control else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await command(control)
                removing = nil
                members = try await control.sessionMembers(sessionID: record.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func makeShareable() {
        guard let daemon else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await daemon.makeShareable(record.id)
                members = try await daemon.control?.sessionMembers(sessionID: record.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func invite() {
        guard let control = daemon?.control else { return }
        let name = inviteeName.trimmingCharacters(in: .whitespaces)
        let principalID = "guest-" + UUID().uuidString.prefix(8).lowercased()
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                invitation = try await control.invite(sessionID: record.id, principalID: principalID, name: name, role: role)
                inviteeName = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The one place a claim token is drawn: the owner just asked for it, and it is
/// never stored. It is a bearer for one redemption, so the sheet says to send it
/// outside the session, since text sent in the session becomes transcript the
/// agent can read and use first.
struct HandoverView: View {
    let invitation: Invitation
    let address: String
    let done: () -> Void
    @State private var showsToken = true

    private var minutes: Int { max(1, invitation.expiresInMs / 60_000) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hand this to \(invitation.name)").font(Theme.label)
            Text("Send it over a channel outside Loom, never through the session: text sent there becomes transcript, and the agent could use the claim first. It works once, for \(minutes) minutes.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            field("Claim address", value: address, copy: "Copy Address")
            field("Command", value: invitation.command(address: address), copy: "Copy Command")
            VStack(alignment: .leading, spacing: 3) {
                Text("Claim token").font(Theme.caption).foregroundStyle(.secondary)
                HStack {
                    Text(showsToken ? invitation.claim : String(repeating: "•", count: 24))
                        .font(Theme.code)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .accessibilityLabel(showsToken ? "Claim token \(invitation.claim)" : "Claim token hidden")
                    Spacer()
                    Button(showsToken ? "Hide Token" : "Show Token") { showsToken.toggle() }
                    Button("Copy Token") { copy(invitation.claim) }
                }
            }
            Text("`loom claim` prints a fingerprint when they use it. Compare it with theirs before you rely on the new member.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("I've Sent It", action: done).buttonStyle(.borderedProminent)
            }
        }
    }

    private func field(_ title: String, value: String, copy label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary)
            HStack {
                Text(value).font(Theme.code).textSelection(.enabled).lineLimit(2)
                Spacer()
                Button(label) { copy(value) }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
