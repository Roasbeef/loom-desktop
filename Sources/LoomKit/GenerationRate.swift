import Foundation

/// The output speed of the last timed generation on each strand, in tokens a second.
///
/// A request is timed from the first fragment this client saw of it to the moment its
/// usage reading arrives. The daemon pushes no phase transitions to a session lane, so
/// the first fragment is the earliest sign a request has begun. A request already
/// running when the lane attached is never timed, because its first fragment arrives
/// part way through it. A window shorter than a second is dominated by request latency
/// and how the provider batches its stream, so it reports nothing and the last
/// measured rate stands. The clock is this client's own observation, as it is on the
/// web page.
public struct GenerationRate: Sendable, Equatable {
    /// The shortest window a rate is reported for.
    public static let minimumWindowMs = 1000

    private var started: [String: Int] = [:]
    private var generation: [String: String] = [:]
    private var inFlightAtAttach: Set<String> = []
    private var rates: [String: Int] = [:]

    public init() {}

    /// Notes strands that were mid-request when the lane attached, whose next
    /// generation identity is therefore one this client saw only the end of.
    public mutating func attached(busy strands: [String]) {
        inFlightAtAttach = Set(strands)
    }

    /// Notes a streamed fragment. The first fragment of a new generation starts a clock.
    public mutating func fragment(strand: String, generation id: String, now: Int) {
        guard generation[strand] != id else { return }
        generation[strand] = id
        if inFlightAtAttach.remove(strand) != nil {
            started[strand] = nil
        } else {
            started[strand] = now
        }
    }

    /// Settles the running request with the output tokens its usage reading reports.
    public mutating func settle(strand: String, output: Int, now: Int) {
        guard let began = started.removeValue(forKey: strand) else { return }
        let elapsed = now - began
        if elapsed >= Self.minimumWindowMs { rates[strand] = output * 1000 / elapsed }
    }

    public func rate(strand: String) -> Int? {
        rates[strand]
    }
}
