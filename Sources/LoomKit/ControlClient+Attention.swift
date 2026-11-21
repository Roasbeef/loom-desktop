import Foundation

// The control commands behind the attention inbox (loom docs/client-protocol.md
// sections 3.34 and 3.35). All of them take the current epoch, and all are reads
// except `attention.close_find`, which settles one record and sends nothing to any
// strand, and `attention.answer`, which delivers one prompt to the asking strand and
// settles the ask. Each reply is one fresh observation: the daemon caches nothing and
// pushes nothing, so the caller decides how often to ask.
//
// Cadence is the caller's, and three of the reads are rate limited:
// `sessions.attention` and `sessions.saved_attention` take at most 24 ids, `session.brief` is six reads in four
// seconds per credential, and `sessions.review` runs Git in the session's sandbox
// and may wait up to 14 seconds.

extension ControlClient {
    /// The attention rows of `sessions`, batched at the server's bound of 24.
    ///
    /// Only a row the daemon read is returned. A session it did not read in time,
    /// or that is not resident, has no entry, which a caller must treat as "not
    /// checked" and never as "nothing waits".
    public func attention(sessions: [String]) async throws -> [String: AttentionRow] {
        let epoch = try currentEpoch()
        var rows: [String: AttentionRow] = [:]
        for start in stride(from: 0, to: sessions.count, by: Self.activityBatch) {
            let batch = sessions[start..<min(start + Self.activityBatch, sessions.count)]
            let body = try await request("sessions.attention", body: [
                "sessions": .array(batch.map { .string($0) }),
                "epoch": .string(epoch),
            ])
            for row in (body["attention"]?.array ?? []).compactMap(AttentionRow.init) {
                rows[row.sessionID] = row
            }
        }
        return rows
    }

    /// One ask or find in full. `not_resident` is a saved session.
    public func attentionRecord(sessionID: String, id: String) async throws -> AttentionRecord {
        let body = try await request("attention.read", body: [
            "session": .string(sessionID),
            "id": .string(id),
            "epoch": .string(try currentEpoch()),
        ])
        guard let record = AttentionRecord(body) else {
            throw LoomError.protocolViolation("attention.read returned no record")
        }
        return record
    }

    /// Delivers an answer to an open ask at the revision it was read at, and settles
    /// the ask. The daemon refuses a stale epoch (`stale_epoch`), a record that
    /// moved or was answered (`conflict`), an answer that fails its check
    /// (`bad_request`, naming the first failing key), a saved session
    /// (`not_resident`) and an observer (`forbidden`). A `conflict` or `unavailable`
    /// whose message says `delivered` means the prompt arrived, so the caller reads
    /// the record again before offering another answer. A daemon that predates the
    /// command is `LoomError.isUnknownCommand`.
    public func answerAsk(sessionID: String, ask: String, revision: Int, answer: AttentionAnswerBody) async throws -> AnswerReceipt {
        let body = try await request("attention.answer", body: AttentionWire.answerBody(
            session: sessionID, ask: ask, revision: revision, answer: answer, epoch: try currentEpoch()
        ))
        guard let receipt = AnswerReceipt(body) else {
            throw LoomError.protocolViolation("attention.answer returned no receipt")
        }
        return receipt
    }

    /// What the catalogue keeps of the attention of `sessions`, batched at the
    /// server's bound of 24. A session with no entry was not read, and the daemon
    /// gives the same absence for one this credential does not hold, so a caller
    /// treats it as "not checked" and never as "nothing waits". The rows are a cache
    /// that can lag the session's own records.
    public func savedAttention(sessions: [String]) async throws -> [String: SavedAttention] {
        let epoch = try currentEpoch()
        var rows: [String: SavedAttention] = [:]
        for start in stride(from: 0, to: sessions.count, by: AttentionWire.savedBatch) {
            let batch = Array(sessions[start..<min(start + AttentionWire.savedBatch, sessions.count)])
            let body = try await request("sessions.saved_attention", body: AttentionWire.savedBody(sessions: batch, epoch: epoch))
            rows.merge(AttentionWire.savedRows(body)) { _, new in new }
        }
        return rows
    }

    /// Settles a find at the revision it was read at, and answers the new revision.
    /// The daemon refuses a find already closed, or one whose revision moved, with
    /// `conflict`, and an observer with `forbidden`.
    @discardableResult
    public func closeFind(sessionID: String, find: String, revision: Int, outcome: FindOutcome) async throws -> Int {
        let body = try await request("attention.close_find", body: [
            "session": .string(sessionID),
            "find": .string(find),
            "revision": .int(Int64(revision)),
            "outcome": .string(outcome.rawValue),
            "epoch": .string(try currentEpoch()),
        ])
        guard let settled = body["revision"]?.natural else {
            throw LoomError.protocolViolation("attention.close_find returned no revision")
        }
        return settled
    }

    /// A session's pending approvals as evidence. It never decides one: the
    /// decision stays on the session's own lane.
    public func approvalEvidence(sessionID: String) async throws -> ApprovalEvidence {
        let body = try await request("approval.read", body: [
            "session": .string(sessionID),
            "epoch": .string(try currentEpoch()),
        ])
        guard let evidence = ApprovalEvidence(body) else {
            throw LoomError.protocolViolation("approval.read returned no approvals")
        }
        return evidence
    }

    /// A bounded account of a session's recent work. `since` is the time after
    /// which peer messages are wanted, in Unix milliseconds. A credential past six
    /// reads in four seconds is answered `unavailable`.
    public func brief(sessionID: String, since: Int = 0) async throws -> SessionBrief {
        let body = try await request("session.brief", body: [
            "session": .string(sessionID),
            "since": .int(Int64(since)),
            "epoch": .string(try currentEpoch()),
        ])
        guard let brief = SessionBrief(body) else {
            throw LoomError.protocolViolation("session.brief returned no brief")
        }
        return brief
    }

    /// A session's worktree as a review. The owner and an Operator member read; an
    /// observer is `forbidden`.
    public func review(sessionID: String) async throws -> ReviewRead {
        let body = try await request("sessions.review", body: [
            "session": .string(sessionID),
            "epoch": .string(try currentEpoch()),
        ])
        guard let review = ReviewRead(body) else {
            throw LoomError.protocolViolation("sessions.review returned no review")
        }
        return review
    }
}
