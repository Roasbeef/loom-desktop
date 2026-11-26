import LoomKit

/// One attached session as a value: the lane, the conversation it feeds, the drafts
/// in flight, and when the observed projections are due.
///
/// This is the desktop's counterpart of Loom's `session_view/step.gleam`. It reads no
/// clock and performs no effect. The host (`SessionController` in the app, the harness
/// in the simulation) feeds it a received frame, a close, a tick or an intent, each
/// with `now`, and performs the `Effect`s it returns in order. `nextDue` names the one
/// instant the host must wake for, which covers the lane's deadline and refresh and the
/// stream flush.
///
/// ## What lives here and why
///
/// The lane decides the wire. The conversation folds cuts and pushes into rows. This
/// value decides what the person sees when, and what becomes of what they sent:
///
/// - **Projection timing.** A streamed token changes only the live stream, and the
///   stream is observed at most once per flush window, 33, 60 or 100 ms by reply length,
///   however many other pushes arrive in it. A push that is not a token asks for the
///   cheap projection, which never writes the stream. A cut asks for the full one.
/// - **Draft custody.** A sent message is a line in the ledger until the daemon answers.
///   A refusal, or a command that never reached the wire, returns the text to the
///   editor. A lost reply does not: the line is marked unknown, the text stays out of
///   the editor, and the next transcript read settles it, either by showing the prompt
///   or by offering the text back. A session that replaces another inherits its lines.
///
/// ## Invariants
///
/// `SessionModelTests` checks these after every step, under tags that continue the
/// lane's:
///
/// - T1 for a strand, the durable rows before a step are a subsequence of the rows after
///   it, unless the step was `/clear`, a strand change or a new attachment.
/// - T3 a reply's text is in the live stream or in a durable row, never neither, from its
///   first delta until its entry lands.
/// - T4 a token changes nothing a view reads but the stream.
/// - T5 the stream is projected at most once per flush window.
/// - T6 an identical cut changes nothing observed.
/// - O1 text the person sent is in exactly one place: the editor, a pending line, a
///   notice that says it may have been sent, or the transcript.
/// - O2 one `prompt` or `steer` crosses the wire per ledger line.
public struct Session: Sendable, Equatable {
    /// How much of the view a host should rebuild.
    public enum Projection: Sendable, Equatable {
        /// Everything a cut can change: the rows, the strands, the panels and the stream.
        /// `forced` rebuilds the rows although the conversation's revision did not move.
        case all(forced: Rebuild)
        /// The panels and surfaces a push changes. It never writes the stream.
        case pushed
        /// The live stream only.
        case stream
    }

    /// Whether a projection must rebuild what an unchanged revision would keep.
    public enum Rebuild: Sendable, Equatable {
        case ifChanged
        case always
    }

    /// How a caller's command ended.
    public enum Settlement: Sendable, Equatable {
        case reply(EventEnvelope)
        case cut(Cut)
        case refused(code: String, message: String, details: JSONValue?)
        /// The reply was lost. The command may have taken effect.
        case unknown(command: String)
        case failed(LoomError)
    }

    /// Whether a notice is information or a warning.
    public enum Tone: Sendable, Equatable {
        case info
        case warning
    }

    /// What the host performs, in order.
    public enum Effect: Sendable, Equatable {
        case transmit(String)
        case shut
        case project(Projection)
        /// A command the host submitted with a tag has ended.
        case settled(tag: Int, Settlement)
        /// Put this text back in the editor.
        case restoreDraft(String)
        /// Say this above the composer.
        case notice(String, Tone)
        /// A message was taken or refused for good, so whatever the composer kept for it can go.
        case forgetImages(text: String)
        /// A draining daemon returned a held prompt.
        case restoreReturned(text: String, strand: String, attachments: Int)
        /// The lane ended. A nil error is a close this client asked for.
        case ended(LoomError?)
        /// A frame of this kind was pushed, for a host that counts them.
        case pushedEvent(String)
    }

    /// What a host asks of the session.
    public enum Intent: Sendable, Equatable {
        /// Any command, settled by `tag`.
        case submit(Lane.Command, tag: Int)
        /// A message from the composer. The ledger holds it until the daemon answers.
        /// `confirming` is what to say when the daemon accepts it, for a command whose acceptance is news.
        case send(text: String, delivery: Delivery, command: Lane.Command, confirming: String? = nil)
        /// Choose a strand, which rebuilds the transcript.
        case focus(String)
        /// Hide what this window has drawn on the focused strand.
        case clear
        /// Cancel the commands that have not been written.
        case cancelWaiting
        /// Start reading a page of a subagent on another orchestrator.
        case beginPeek(child: String)
        /// Stop reading it.
        case endPeek
    }

    /// The shortest and longest wait between stream projections, by reply length.
    public static func flushMs(replyBytes: Int) -> Int {
        replyBytes > 16_000 ? 100 : replyBytes > 4_000 ? 60 : 33
    }

    public private(set) var lane: Lane
    public private(set) var conversation: Conversation
    public private(set) var ledger = DraftLedger()
    public private(set) var focusedStrand = "main"
    public private(set) var clearedThrough: [String: Int] = [:]
    public private(set) var isLive = true
    public private(set) var ended: LoomError?
    /// The reading at which the stream is next projected, while tokens have arrived.
    public private(set) var flushAt: Int?

    private enum Owner: Sendable, Equatable {
        case caller(Int)
        /// `id` is nil for a message with no words, an image alone, which the ledger does not show.
        case draft(id: Int?, text: String, delivery: Delivery, strand: String, confirming: String?)
    }

    private var owners: [Lane.Ticket: Owner] = [:]

    /// Opens a session by subscribing, writing the lane's first frame.
    public static func start(sessionID: String, inheriting previous: Session? = nil, now: Int) -> (session: Session, effects: [Effect]) {
        var session = Session(
            lane: Lane.start(sessionID: sessionID, admission: .daemonDecides, now: now),
            conversation: Conversation(sessionID: sessionID)
        )
        if let previous { session.inherit(from: previous) }
        let effects = session.drainOutputs()
        return (session, effects)
    }

    /// Takes over what the session this one replaces had in flight. The strand being
    /// drawn and the ledger carry over. A line still waiting is marked unknown, because the
    /// lane that sent it is gone and its reply can no longer arrive.
    public mutating func inherit(from previous: Session) {
        focusedStrand = previous.focusedStrand
        ledger = previous.ledger
        let rows = previous.conversation
        ledger.loseWaiting { rows.newestSeq(strand: $0.strand) ?? 0 }
    }

    private init(lane: Lane, conversation: Conversation) {
        self.lane = lane
        self.conversation = conversation
    }

    /// The instant the host must wake for, if any.
    public var nextDue: Int? {
        [lane.nextDue, flushAt].compactMap { $0 }.min()
    }

    /// Whether the focused strand has a turn running.
    public var isBusy: Bool {
        conversation.strands.first { $0.id == focusedStrand }?.isBusy ?? false
    }

    // MARK: Events

    /// Reduces one text frame from the socket.
    public mutating func receive(_ text: String, now: Int) -> [Effect] {
        route(lane.receive(text, now: now), now: now)
    }

    /// Reduces the transport's report that the socket ended or failed.
    public mutating func receive(failed error: LoomError, now: Int) -> [Effect] {
        route(lane.receive(failed: error), now: now)
    }

    /// Acts on whatever has come due: the lane's deadline and refresh, and the stream flush.
    public mutating func tick(now: Int) -> [Effect] {
        var effects = route(lane.tick(now: now), now: now)
        if let due = flushAt, due <= now {
            flushAt = nil
            effects.append(.project(.stream))
        }
        return effects
    }

    /// Ends the attachment because this client asked to.
    public mutating func close(now: Int) -> [Effect] {
        route(lane.close(), now: now)
    }

    /// Carries out what the person asked.
    public mutating func apply(_ intent: Intent, now: Int) -> [Effect] {
        switch intent {
        case .submit(let command, let tag):
            let admitted = lane.submit(command, now: now)
            owners[admitted.ticket] = .caller(tag)
            var updates = admitted.updates
            if case .notSent(let reason) = admitted.disposition { updates.append(.notSent(admitted.ticket, reason: reason)) }
            return route(updates, now: now)

        case .send(let text, let delivery, let command, let confirming):
            let strand = command.body["strand"]?.string ?? focusedStrand
            let id = ledger.sent(text, delivery: delivery, strand: strand)
            let admitted = lane.submit(command, now: now)
            owners[admitted.ticket] = .draft(id: id, text: text, delivery: delivery, strand: strand, confirming: confirming)
            var updates = admitted.updates
            if case .notSent(let reason) = admitted.disposition { updates.append(.notSent(admitted.ticket, reason: reason)) }
            return route(updates, now: now)

        case .focus(let strand):
            guard strand != focusedStrand else { return [] }
            focusedStrand = strand
            return [.project(.all(forced: .always))]

        case .clear:
            guard let newest = conversation.newestSeq(strand: focusedStrand) else { return [] }
            clearedThrough[focusedStrand] = newest
            return [.project(.all(forced: .always))]

        case .cancelWaiting:
            return route(lane.cancelWaiting(reason: "cancelled"), now: now)

        case .beginPeek(let child):
            conversation.beginPeek(child: child)
            return [.project(.pushed)]

        case .endPeek:
            conversation.endPeek()
            return [.project(.pushed)]
        }
    }

    // MARK: Updates

    private mutating func route(_ updates: [Lane.Update], now: Int) -> [Effect] {
        var effects = drainOutputs()
        for update in updates {
            effects += handle(update, now: now)
        }
        return effects
    }

    private mutating func drainOutputs() -> [Effect] {
        lane.takeOutputs().map { output in
            switch output {
            case .transmit(let text): return .transmit(text)
            case .shut: return .shut
            }
        }
    }

    private mutating func handle(_ update: Lane.Update, now: Int) -> [Effect] {
        switch update {
        case .sent, .noticed:
            return []
        case .cut(let ticket, let cut, _):
            return cutLanded(cut, ticket: ticket, now: now)
        case .pushed(let frame):
            return pushed(frame, now: now)
        case .replied(let ticket, let reply):
            var effects: [Effect] = []
            if reply.event == "snapshot" {
                conversation.apply(push: reply, now: now)
                effects.append(.project(.pushed))
            }
            return effects + settle(ticket, .reply(reply))
        case .refused(let ticket, let code, let message, let details):
            return settle(ticket, .refused(code: code, message: message, details: details))
        case .unknown(let ticket, let command, _):
            return settle(ticket, .unknown(command: command))
        case .failed(let ticket, _, let error):
            return settle(ticket, .failed(error))
        case .notSent(let ticket, let reason):
            return settle(ticket, .failed(.closed(reason)))
        case .closed(let error):
            isLive = false
            ended = error ?? .closed("the lane has ended")
            flushAt = nil
            return [.ended(error)]
        }
    }

    private mutating func cutLanded(_ cut: Cut, ticket: Lane.Ticket?, now: Int) -> [Effect] {
        let changed = conversation.apply(cut: cut)
        var effects: [Effect] = []
        if ticket != nil {
            effects.append(.project(.all(forced: .always)))
        } else if changed {
            effects.append(.project(.all(forced: .ifChanged)))
        }

        // A catch-up or the first cut is a read of the transcript, which settles any
        // draft whose reply was lost.
        if ["recent", "catch_up"].contains(cut.window) { effects += settleLost() }
        if let ticket { effects += settle(ticket, .cut(cut)) }
        return effects
    }

    private mutating func pushed(_ frame: EventEnvelope, now: Int) -> [Effect] {
        conversation.apply(push: frame, now: now)
        var effects: [Effect] = [.pushedEvent(frame.event)]
        if frame.event == "stream_delta" {
            if flushAt == nil {
                let length = conversation.streams[focusedStrand]?.text.utf8.count ?? 0
                flushAt = now + Self.flushMs(replyBytes: length)
            }
        } else {
            effects.append(.project(.pushed))
        }
        if frame.event == "held_input_returned" {
            for draft in conversation.takeReturnedDrafts() {
                effects.append(.restoreReturned(text: draft.text, strand: draft.strand, attachments: draft.attachmentCount))
            }
        }
        return effects
    }

    /// Ends one ticket's wait and applies what it means for a draft.
    private mutating func settle(_ ticket: Lane.Ticket, _ settlement: Settlement) -> [Effect] {
        guard let owner = owners.removeValue(forKey: ticket) else { return [] }
        switch owner {
        case .caller(let tag):
            return [.settled(tag: tag, settlement)]
        case .draft(let id, let text, let delivery, let strand, let confirming):
            switch settlement {
            case .reply(let reply):
                if let id { ledger.taken(id) }
                if delivery == .queue, reply.body["status"]?.string == "queued" {
                    return [.forgetImages(text: text), .notice("Queued. It runs after this turn.", .info)]
                }
                if let confirming { return [.forgetImages(text: text), .notice(confirming, .info)] }
                return [.forgetImages(text: text)]
            case .unknown:
                // An image alone has no words to match against the transcript, so nothing later can
                // settle it. Its images go back, with a warning that it may have been sent.
                guard let id else { return [.restoreDraft(text), .notice(Self.maybeSentImagesWords, .warning)] }
                ledger.lost(id, afterSeq: conversation.newestSeq(strand: strand) ?? 0)
                return [.notice(Self.maybeSentWords, .warning)]
            case .refused(_, let message, _):
                return refused(id, text: text, words: message.isEmpty ? "The daemon refused the message." : message)
            case .failed(let error):
                return refused(id, text: text, words: error.localizedDescription)
            case .cut:
                return []
            }
        }
    }

    private mutating func refused(_ id: Int?, text: String, words: String) -> [Effect] {
        var effects: [Effect] = []

        // An image alone has no ledger line and no words, but the images still go back.
        if let id { if let restored = ledger.refused(id) { effects.append(.restoreDraft(restored)) } } else { effects.append(.restoreDraft(text)) }
        effects.append(.notice(words, .warning))
        return effects
    }

    /// The transcript has been read, so each draft with an unknown outcome has an answer.
    private mutating func settleLost() -> [Effect] {
        guard ledger.lines.contains(where: \.isUnknown) else { return [] }
        let held = conversation
        let offered = ledger.settleUnknown { line in
            guard case .unknown(let afterSeq) = line.outcome else { return .undecided }
            let arrived = held.rows(strand: line.strand).contains { row in
                guard let seq = row.seq, seq > afterSeq, case .user(let body, _) = row.kind else { return false }
                return body == line.text
            }
            if arrived || held.pendingInputs.contains(where: { $0.text == line.text && $0.strand == line.strand }) { return .delivered }

            // Absence proves something only if this window reaches back to what the sender held.
            guard let oldest = held.oldestSeq, oldest <= afterSeq + 1 else { return .undecided }
            return .absent
        }
        var effects: [Effect] = []
        for text in offered {
            effects.append(.restoreDraft(text))
            effects.append(.notice(Self.offeredBackWords, .warning))
        }
        return effects
    }

    /// The reasoning blocks in `rows` that have no label and no read in flight. Asking marks
    /// them, so each is asked once.
    public mutating func takeWantedSummaries(in rows: [TranscriptRow]) -> [(entry: String, block: Int)] {
        conversation.takeWantedSummaries(in: rows)
    }

    /// How many user rows on the strand carry exactly this text.
    static func occurrences(of text: String, in conversation: Conversation, strand: String) -> Int {
        conversation.rows(strand: strand).filter { row in
            if case .user(let body, _) = row.kind { return body == text }
            return false
        }.count
    }

    public static let maybeSentWords = "No reply came, so this message may have been sent. It is not back in the editor; the next read of the transcript shows whether it arrived."
    public static let maybeSentImagesWords = "No reply came, so this message may have been sent. Its images are back in the editor; send them again only if it did not arrive."
    public static let offeredBackWords = "That message did not arrive, so its text is back in the editor."
}
