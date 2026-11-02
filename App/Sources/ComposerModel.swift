import AppKit
import LoomKit
import Observation
import UniformTypeIdentifiers

/// Everything the composer remembers between keystrokes.
///
/// The draft, the lines for what was sent and not yet answered, the notice after a
/// command, and an edit of a held input all live here and not in the view. A
/// refusal arrives after the editor was emptied, and it must be able to put the
/// text back even if the view has been rebuilt since.
@MainActor
@Observable
final class ComposerModel {
    struct Notice: Equatable {
        enum Tone { case info, warning }
        let text: String
        let tone: Tone
    }

    /// A held input being edited, and whether its full text has arrived yet.
    struct HeldEdit: Equatable {
        let id: String
        let strand: String
        var text: String
        var revision: Int
        var isLoading: Bool
    }

    var draft = "" {
        didSet {
            if draft != oldValue { selection = 0 }
        }
    }
    /// The highlighted row of the command list.
    var selection = 0
    /// The draft for which the person closed the list, so typing brings it back.
    var dismissedFor: String?
    var editing: HeldEdit?

    private(set) var images: [ImageAttachment] = []
    private(set) var ledger = DraftLedger()
    private(set) var notice: Notice?
    /// The side-question panel's board, shown until the person closes it.
    private(set) var btw: JSONValue?
    @ObservationIgnored private var catalogueRequested = false
    @ObservationIgnored private var btwPoll: Task<Void, Never>?

    #if DEBUG
    /// A delay before a send reaches the lane, which lets a test see the pending
    /// line a real daemon answers too quickly to catch.
    nonisolated(unsafe) static var debugSendDelay: Duration?
    #endif

    // MARK: The command list

    func suggestions(catalogue: SlashCommand.Catalogue) -> [SlashCommand.Suggestion] {
        guard dismissedFor != draft else { return [] }
        return SlashCommand.suggestions(for: draft, catalogue: catalogue)
    }

    func move(by step: Int, count: Int) {
        selection = SlashCommand.move(selection, by: step, count: count)
    }

    func dismissList() {
        dismissedFor = draft
    }

    func accept(_ suggestion: SlashCommand.Suggestion) {
        draft = suggestion.insertion
    }

    /// Asks the daemon once for the names the list completes. A failure is not
    /// worth a notice: the list just offers fewer rows.
    func loadCatalogue(_ controller: SessionController) {
        guard !catalogueRequested else { return }
        catalogueRequested = true
        Task {
            do {
                _ = try await controller.request("models")
                _ = try await controller.request("profile_get")
            } catch {
                catalogueRequested = false
            }
        }
    }

    // MARK: Images

    func attach(_ data: Data, name: String) {
        switch ImageAttachment.vet(data, name: name, already: images.count) {
        case .success(let image): images.append(image)
        case .failure(let refusal): notice = Notice(text: refusal.message, tone: .warning)
        }
    }

    func removeImage(_ id: UUID) {
        images.removeAll { $0.id == id }
    }

    /// Takes images from a paste or a drop. Files are read from disk, and an image
    /// on the pasteboard arrives as bytes in whichever format its owner offered.
    func ingest(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url) else { return }
                    let name = url.lastPathComponent
                    Task { @MainActor in self.attach(data, name: name) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    let png = Self.png(from: data)
                    Task { @MainActor in self.attach(png, name: "Pasted image") }
                }
            }
        }
    }

    /// A screenshot is often offered as TIFF, which no provider reads, so it is
    /// converted. Bytes already in a readable format pass through untouched.
    nonisolated private static func png(from data: Data) -> Data {
        if ImageAttachment.mimeType(of: data) != nil { return data }
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return data }
        return png
    }

    // MARK: Submitting

    /// What the composer does with the editor after a press.
    enum Outcome {
        /// The text was taken, so the editor is already empty.
        case taken
        /// Nothing was done, and the draft stays for the person to fix.
        case kept
    }

    /// Acts on the draft. `requested` is what the key asked for: a plain Return
    /// queues when the strand is busy, and the steer chord joins the running turn.
    @discardableResult
    func submit(requested: Delivery, controller: SessionController) -> Outcome {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = text.isEmpty && !images.isEmpty ? SlashCommand.prompt("") : SlashCommand.parse(text)
        switch command {
        case .empty:
            return .kept
        case .invalid(let words):
            notice = Notice(text: words, tone: .warning)
            return .kept
        case .prompt(let words):
            deliver(words, requested: requested, controller: controller)
            return .taken
        default:
            draft = ""
            notice = nil
            execute(command, controller: controller)
            return .taken
        }
    }

    private func deliver(_ text: String, requested: Delivery, controller: SessionController) {
        let delivery: Delivery = controller.isBusy ? (requested == .steer ? .steer : .queue) : .send
        if delivery == .steer, !images.isEmpty {
            notice = Notice(text: "Images go with a message that waits its turn, not with a steer.", tone: .warning)
            return
        }
        let sentImages = images
        let id = ledger.sent(text, delivery: delivery)
        draft = ""
        images = []
        notice = nil
        let strand = controller.focusedStrand
        Task {
            do {
                #if DEBUG
                if let delay = Self.debugSendDelay { try await Task.sleep(for: delay) }
                #endif
                let reply: EventEnvelope
                if delivery == .steer {
                    reply = try await controller.request("steer", body: ["strand": .string(strand), "text": .string(text)])
                } else if sentImages.isEmpty {
                    reply = try await controller.request("prompt", body: ["strand": .string(strand), "text": .string(text)])
                } else {
                    reply = try await controller.request("prompt_content", body: PromptContent.body(strand: strand, text: text, images: sentImages))
                }
                if let id { ledger.taken(id) }
                if delivery == .queue, reply.body["status"]?.string == "queued" {
                    notice = Notice(text: "Queued. It runs after this turn.", tone: .info)
                }
            } catch {
                if let id, let restored = ledger.refused(id) {
                    draft = DraftLedger.restoring(restored, into: draft)
                }
                images = sentImages + images
                notice = Notice(text: Self.words(error), tone: .warning)
            }
        }
    }

    /// A refusal in the daemon's own words, without the code.
    nonisolated static func words(_ error: Error) -> String {
        if case LoomError.server(_, let message, _) = error, !message.isEmpty { return message }
        return error.localizedDescription
    }

    // MARK: Commands

    private func execute(_ command: SlashCommand, controller: SessionController) {
        let strand = controller.focusedStrand
        let name = StrandName.display(strand)
        func say(_ text: String, _ tone: Notice.Tone = .info) { notice = Notice(text: text, tone: tone) }

        Task {
            do {
                switch command {
                case .models:
                    let reply = try await controller.request("models")
                    let rows = (reply.body["models"]?.array ?? []).map { model -> String in
                        let active = (model["active"]?.array ?? []).compactMap(\.string)
                        return "\(model["name"]?.string ?? "?")  \(model["model_id"]?.string ?? "")"
                            + (active.isEmpty ? "" : "  (in use: \(active.joined(separator: ", ")))")
                    }
                    say(rows.isEmpty ? "The daemon lists no models." : rows.joined(separator: "\n"))
                case .model(let model):
                    _ = try await controller.request("set_config", body: ["strand": .string(strand), "config": ["model_name": .string(model)]])
                    say("\(name) now uses \(model).")
                case .effort(let level):
                    _ = try await controller.request("set_config", body: ["strand": .string(strand), "config": ["thinking_level": .string(level)]])
                    say("Reasoning for \(name) is \(level).")
                case .profileShow:
                    let reply = try await controller.request("profile_get")
                    say(Self.profileWords(reply.body))
                case .profileSelect(let profile):
                    let body: JSONValue = profile.map { ["profile": .string($0)] } ?? .object([:])
                    let reply = try await controller.request("profile_set", body: body)
                    say(reply.body["moved"] != nil
                        ? "Profile is now \(profile ?? "the default roles"). The session is restarting."
                        : Self.profileWords(reply.body))
                case .compact:
                    _ = try await controller.request("compact", body: ["strand": .string(strand)])
                    say("Compacting \(name).")
                case .abort:
                    controller.abort()
                case .steer(let text):
                    _ = try await controller.request("steer", body: ["strand": .string(strand), "text": .string(text)])
                case .queue(let text):
                    let id = ledger.sent(text, delivery: .queue)
                    do {
                        _ = try await controller.request("follow_up", body: ["strand": .string(strand), "text": .string(text)])
                        if let id { ledger.taken(id) }
                        say("Queued. It runs after this turn.")
                    } catch {
                        if let id, let restored = ledger.refused(id) { draft = DraftLedger.restoring(restored, into: draft) }
                        throw error
                    }
                case .fork(let fork):
                    _ = try await controller.request("fork", body: ["strand": .string(strand), "scope": "branch", "name": .string(fork)])
                    say("Forked \(name) as \(fork). Choose it in the agent picker.")
                case .goalStatus:
                    say(Self.goalWords(try await controller.request("goal_get").body["board"]))
                case .goalSet(let objective, let budget):
                    let reply = try await controller.request("goal_set", body: ["objective": .string(objective), "token_budget": .int(Int64(budget))])
                    let defaulted = budget == SlashCommand.defaultGoalBudget ? " The budget is the default; set another with --budget." : ""
                    say(Self.goalWords(reply.body["board"]) + defaulted)
                case .goalCheck(let check):
                    let body: JSONValue = check.map { ["command": .string($0)] } ?? .object([:])
                    say(Self.goalWords(try await controller.request("goal_check", body: body).body["board"]))
                case .goalClear:
                    _ = try await controller.request("goal_clear")
                    say("Goal cleared.")
                case .goalPause:
                    say(Self.goalWords(try await controller.request("goal_pause").body["board"]))
                case .goalResume:
                    say(Self.goalWords(try await controller.request("goal_resume").body["board"]))
                case .btw(let action):
                    var body: [String: JSONValue] = ["strand": .string(strand), "action": .string(action.wire)]
                    if case .ask(let question) = action { body["text"] = .string(question) } else { body["text"] = "" }
                    let reply = try await controller.request("btw", body: .object(body))
                    showBtw(reply.body["board"], controller: controller)
                case .btwClose:
                    closeBtw()
                case .schedules:
                    let reply = try await controller.request("schedules")
                    let rows = (reply.body["schedules"]?.array ?? []).map {
                        "\($0["name"]?.string ?? "?")  on \(StrandName.display($0["target"]?.string ?? ""))  \($0["when"]?.string ?? "")"
                    }
                    say(rows.isEmpty ? "No schedules." : rows.joined(separator: "\n"))
                case .unschedule(let schedule, let target):
                    _ = try await controller.request("schedule_cancel", body: ["target": .string(target ?? strand), "name": .string(schedule)])
                    say("Retired \(schedule).")
                case .approve(let id), .deny(let id):
                    guard let record = controller.escalations.first(where: { $0.id.hasPrefix(id) }) else {
                        say("No pending request starts with \(id).", .warning)
                        return
                    }
                    if case .approve = command { controller.approve(record) } else { controller.deny(record) }
                case .peek(let child):
                    guard let found = controller.remoteChildren.first(where: { $0.id == child || $0.id.hasSuffix(child) }) else {
                        say("No subagent on another machine is called \(child).", .warning)
                        return
                    }
                    controller.peek(child: found)
                case .peekClose:
                    controller.endPeek()
                case .clear, .approvals:
                    say("That command is not available here yet.", .warning)
                case .empty, .prompt, .invalid:
                    break
                }
            } catch {
                say(Self.words(error), .warning)
            }
        }
    }

    // MARK: Words for replies

    nonisolated static func profileWords(_ body: JSONValue) -> String {
        let current = body["profile"]?.string ?? "the default roles"
        let available = (body["available"]?.array ?? []).compactMap(\.string)
        return "Profile: \(current)." + (available.isEmpty ? "" : " Available: \(available.joined(separator: ", ")).")
    }

    nonisolated static func goalWords(_ board: JSONValue?) -> String {
        guard let board, let status = board["status"]?.string, status != "none" else { return "No goal is pinned." }
        let objective = board["objective"]?.string ?? ""
        let used = board["tokens_used"]?.int ?? 0
        let budget = board["token_budget"]?.int ?? 0
        let compact = { (n: Int) in n.formatted(.number.notation(.compactName)) }
        var words = "Goal \(status.replacingOccurrences(of: "_", with: " ")): \(objective). \(compact(used)) of \(compact(budget)) tokens."
        if let because = board["because"]?.string, !because.isEmpty { words += " " + because }
        if let check = board["check"]?.string, !check.isEmpty { words += " Check: \(check)" }
        return words
    }

    // MARK: Side questions

    private func showBtw(_ board: JSONValue?, controller: SessionController) {
        btw = board
        btwPoll?.cancel()
        guard board?["status"]?.string == "running" else { return }

        // The answer arrives by polling the read, while the status says it runs.
        btwPoll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1200))
                guard let reply = try? await controller.request("btw", body: ["strand": .string(controller.focusedStrand), "action": "read", "text": ""]) else { return }
                btw = reply.body["board"]
                if btw?["status"]?.string != "running" { return }
            }
        }
    }

    // MARK: Held inputs

    /// Opens a held input for editing. The list row carries only an excerpt, so the
    /// full text is read first.
    func beginEdit(_ input: PendingInput, controller: SessionController) {
        editing = HeldEdit(id: input.id, strand: input.strand, text: input.text, revision: input.revision ?? 0, isLoading: true)
        Task {
            do {
                let reply = try await controller.request("queued_input", body: ["strand": .string(input.strand), "id": .string(input.id)])
                guard editing?.id == input.id, let board = reply.body["board"] else { return }
                editing?.text = board["text"]?.string ?? input.text
                editing?.revision = board["revision"]?.int ?? editing?.revision ?? 0
                editing?.isLoading = false
            } catch {
                editing = nil
                notice = Notice(text: Self.words(error), tone: .warning)
            }
        }
    }

    func saveEdit(controller: SessionController) {
        guard let edit = editing, !edit.isLoading else { return }
        Task {
            do {
                _ = try await controller.request("edit_queued_input", body: [
                    "strand": .string(edit.strand), "id": .string(edit.id),
                    "expected_revision": .int(Int64(edit.revision)), "text": .string(edit.text),
                ])
                editing = nil
                notice = Notice(text: "Saved. It keeps its place in the queue.", tone: .info)
            } catch {
                notice = Notice(text: Self.words(error), tone: .warning)
            }
        }
    }

    func remove(_ input: PendingInput, controller: SessionController) {
        let revision = editing?.id == input.id ? editing?.revision : input.revision
        Task {
            do {
                _ = try await controller.request("remove_queued_input", body: [
                    "strand": .string(input.strand), "id": .string(input.id),
                    "expected_revision": .int(Int64(revision ?? 0)),
                ])
                if editing?.id == input.id { editing = nil }
                notice = Notice(text: "Removed from the queue.", tone: .info)
            } catch {
                notice = Notice(text: Self.words(error), tone: .warning)
            }
        }
    }

    func closeBtw() {
        btw = nil
        btwPoll?.cancel()
    }

    func dismissNotice() {
        notice = nil
    }
}
