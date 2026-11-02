import Foundation

/// A complete, validated snapshot transfer.
public struct Cut: Sendable, Equatable {
    public let window: String
    public let nextSeq: Int
    public let oldestSeq: Int?
    public let moreAfter: Int?
    public let identity: Identity
    public let metadata: JSONValue
    public let entries: [JSONValue]

    /// Who this attachment is, as the transfer header states it.
    public struct Identity: Sendable, Equatable {
        public let sessionID: String
        public let epoch: String
        public let incarnation: String
        public let connectionID: String
        public let role: String
    }
}

/// Assembles one snapshot transfer from its fragments.
///
/// This is a pure state machine so that every rule in protocol section 4.3 can
/// be tested without a socket. A cut becomes visible only from `finish`, which
/// is what stops a partial transfer reaching the view.
public struct TransferAssembler: Sendable {
    /// A record above this size is drained and kept as a placeholder, the same
    /// bound the reference terminal uses.
    public static let presentationLimit = 4_194_304
    /// The largest record this client is prepared to buffer.
    public static let recordLimit = 33_554_432

    public let snapshotID: String
    public private(set) var index = 0

    private let window: String
    private let nextSeq: Int
    private let oldestSeq: Int?
    private let identity: Cut.Identity

    private var metadata: JSONValue?
    private var entries: [JSONValue] = []
    private var currentRecord: String?
    private var currentSeq: Int?
    private var currentKind = ""
    private var currentTotal = 0
    private var received = 0
    private var buffer = Data()

    /// Validates a `snapshot_begin` body against the attachment selected.
    public init(begin body: JSONValue, expectedSession: String, expectedIdentity: Cut.Identity?) throws {
        guard
            let snapshotID = body["snapshot_id"]?.string,
            let nextSeq = body["next_seq"]?.int,
            let window = body["window"]?.string,
            let sessionID = body["session_id"]?.string,
            let epoch = body["epoch"]?.string,
            let incarnation = body["incarnation"]?.string
        else {
            throw LoomError.protocolViolation("snapshot_begin is missing a required field")
        }
        guard sessionID == expectedSession else {
            throw LoomError.protocolViolation("the transfer names another session")
        }
        guard body["complete_history"]?.bool == false else {
            throw LoomError.protocolViolation("complete_history must be false")
        }
        guard (body["record_bytes_limit"]?.int ?? .max) <= Self.recordLimit else {
            throw LoomError.protocolViolation("the declared record limit exceeds what this client buffers")
        }
        let identity = Cut.Identity(
            sessionID: sessionID,
            epoch: epoch,
            incarnation: incarnation,
            connectionID: body["connection_id"]?.string ?? "",
            role: body["role"]?.string ?? ""
        )

        // The attachment cannot change during a connection, so a changed
        // identity is evidence of a fault rather than something to adopt.
        if let expectedIdentity, expectedIdentity != identity {
            throw LoomError.protocolViolation("the transfer identity changed on one socket")
        }
        self.snapshotID = snapshotID
        self.nextSeq = nextSeq
        self.window = window
        self.oldestSeq = body["oldest_seq"]?.int
        self.identity = identity
    }

    /// Absorbs one `snapshot_chunk` answering the current index.
    public mutating func absorb(chunk body: JSONValue) throws {
        guard body["snapshot_id"]?.string == snapshotID, body["index"]?.int == index else {
            throw LoomError.protocolViolation("a chunk answers the wrong transfer or index")
        }
        guard
            let recordID = body["record_id"]?.string,
            let total = body["total_bytes"]?.int,
            let offset = body["offset"]?.int,
            let encoded = body["data"]?.string,
            let fragment = Data(base64Encoded: encoded)
        else {
            throw LoomError.protocolViolation("a chunk is malformed")
        }
        let kind = body["kind"]?.string ?? ""

        // Records are contiguous, and metadata comes first.
        if let currentRecord, currentRecord != recordID {
            throw LoomError.protocolViolation("a chunk interleaves two records")
        }
        if kind != "metadata" && metadata == nil {
            throw LoomError.protocolViolation("an entry arrived before metadata was complete")
        }
        guard offset == received, offset + fragment.count <= total, total <= Self.recordLimit else {
            throw LoomError.protocolViolation("a chunk's offset or size is inconsistent")
        }

        if currentRecord == nil {
            currentRecord = recordID
            currentSeq = body["record_seq"]?.int
            currentKind = kind
            currentTotal = total
            buffer = Data()
        }
        received += fragment.count
        if total <= Self.presentationLimit {
            buffer.append(fragment)
        }
        index += 1

        if received == total {
            try completeRecord()
        }
    }

    /// Validates `snapshot_end` and yields the cut for atomic adoption.
    public func finish(end body: JSONValue, metadataRequired: Bool = true) throws -> Cut {
        guard body["snapshot_id"]?.string == snapshotID, body["next_seq"]?.int == nextSeq else {
            throw LoomError.protocolViolation("snapshot_end does not match its header")
        }
        guard currentRecord == nil else {
            throw LoomError.protocolViolation("the transfer ended inside a record")
        }
        guard let metadata else {
            throw LoomError.protocolViolation("the transfer carried no metadata")
        }
        return Cut(
            window: window,
            nextSeq: nextSeq,
            oldestSeq: oldestSeq,
            moreAfter: body["more_after"]?.int,
            identity: identity,
            metadata: metadata,
            entries: entries
        )
    }

    private mutating func completeRecord() throws {
        if currentKind == "metadata" {
            metadata = try JSONValue.parse(buffer)
        } else if currentTotal > Self.presentationLimit {
            entries.append(.object([
                "id": .string(currentRecord ?? ""),
                "seq": .int(Int64(currentSeq ?? 0)),
                "type": "oversized",
                "size": .int(Int64(currentTotal)),
            ]))
        } else {
            entries.append(try JSONValue.parse(buffer))
        }
        currentRecord = nil
        currentSeq = nil
        received = 0
        buffer = Data()
    }
}
