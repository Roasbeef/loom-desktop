import Foundation

/// What one provider request read and wrote of the prompt cache.
///
/// It is the part of an assistant message's usage that decides whether a pause
/// cost anything. The cost fields are the daemon's own pricing of those counts,
/// so an unpriced model has all zeros and the money is left out.
public struct CacheUse: Sendable, Equatable {
    public let input: Int
    public let cacheRead: Int
    public let cacheWrite: Int
    public let costInput: Double
    public let costCacheRead: Double
    public let costCacheWrite: Double

    public init(
        input: Int, cacheRead: Int, cacheWrite: Int,
        costInput: Double = 0, costCacheRead: Double = 0, costCacheWrite: Double = 0
    ) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.costInput = costInput
        self.costCacheRead = costCacheRead
        self.costCacheWrite = costCacheWrite
    }

    /// Reads the durable usage shape (client protocol section 5.9).
    public init?(_ usage: JSONValue?) {
        guard let usage, case .object = usage else { return nil }
        self.init(
            input: usage["input"]?.int ?? 0,
            cacheRead: usage["cacheRead"]?.int ?? 0,
            cacheWrite: usage["cacheWrite"]?.int ?? 0,
            costInput: usage["cost"]?["input"]?.double ?? 0,
            costCacheRead: usage["cost"]?["cacheRead"]?.double ?? 0,
            costCacheWrite: usage["cost"]?["cacheWrite"]?.double ?? 0
        )
    }

    /// Whether this describes a provider request, as opposed to an adjustment
    /// that read and wrote nothing, which must not become a baseline.
    public var readsContext: Bool { input + cacheRead + cacheWrite > 0 }
}

/// The newest request on a strand and when the daemon recorded it.
public struct CacheStamp: Sendable, Equatable {
    public let use: CacheUse
    public let at: Int

    public init(use: CacheUse, at: Int) {
        self.use = use
        self.at = at
    }

    /// The newest stamp among rows in order.
    public static func newest(_ rows: [TranscriptRow]) -> CacheStamp? {
        for row in rows.reversed() {
            if let use = row.cache, let at = row.at { return CacheStamp(use: use, at: at) }
        }
        return nil
    }
}

/// A prompt-cache miss, reconstructed from two requests on one strand.
public struct CacheMiss: Sendable, Equatable {
    public let idleMs: Int
    public let tokens: Int
    /// The extra dollars the re-read cost, or nil when either request was unpriced.
    public let estimate: Double?

    /// The row's words: how long the strand sat, what was billed again, and the cost.
    public var words: String {
        var text = "Cache missed after \(CacheWatch.idleLabel(idleMs)) idle. \(tokens.formatted()) tokens were read again"
        if let estimate, estimate >= 0.005 {
            text += ", about " + estimate.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        }
        return text + "."
    }
}

/// The prompt cache as the daemon's rows reveal it.
///
/// A provider keeps a prompt prefix for a bounded time. Nothing on the wire names a
/// miss, so it is reconstructed from two consecutive requests: the idle gap was a
/// pause and not a turn boundary, the earlier request read a worthwhile prefix, the
/// later one's cached read collapsed, and the lost prefix reappeared as uncached
/// tokens. The thresholds are the ones `session_view/cache_miss` uses, so this client
/// states a miss when the web page does. The outlook never claims an expiry: it says
/// how long the strand has been idle, because only a one-hour cache write proves a
/// provider's lifetime and the OpenAI dialect never reports one.
public enum CacheWatch {
    /// The shortest idle gap that can produce a miss row or an outlook label.
    public static let idleFloorMs = 60_000
    /// The smallest cached prefix whose loss is worth a row.
    public static let prefixFloor = 10_000

    /// Decides whether `current` is a miss relative to `previous`.
    public static func detect(previous: CacheUse, previousAt: Int, current: CacheUse, currentAt: Int) -> CacheMiss? {
        let idle = currentAt - previousAt
        guard idle >= idleFloorMs, previous.cacheRead >= prefixFloor else { return nil }
        let held = previous.cacheRead
        guard current.cacheRead * 4 < held else { return nil }
        let reread = current.cacheWrite + current.input
        guard reread * 2 >= held else { return nil }
        let tokens = min(reread, held)
        return CacheMiss(idleMs: idle, tokens: tokens, estimate: estimate(previous, current, tokens))
    }

    /// The footer label for a strand whose last request held a prefix, or nil when
    /// there is nothing worth saying.
    public static func outlook(last: CacheUse?, lastAt: Int?, now: Int) -> String? {
        guard let last, let lastAt, max(last.cacheRead, last.cacheWrite) >= prefixFloor else { return nil }
        let idle = now - lastAt
        return idle > idleFloorMs ? "cache idle \(idleLabel(idle))" : nil
    }

    /// An idle gap as a clock reads it: `45s`, `7m`, `1h 12m`.
    public static func idleLabel(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        let minutes = seconds / 60
        let hours = minutes / 60
        if hours > 0 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    private static func estimate(_ previous: CacheUse, _ current: CacheUse, _ tokens: Int) -> Double? {
        let fresh: Double?
        if current.cacheWrite > current.input {
            fresh = rate(current.costCacheWrite, current.cacheWrite)
        } else {
            fresh = rate(current.costInput, current.input)
        }
        guard let fresh, let cached = rate(previous.costCacheRead, previous.cacheRead) else { return nil }
        return max(0, Double(tokens) * (fresh - cached))
    }

    private static func rate(_ cost: Double, _ tokens: Int) -> Double? {
        cost > 0 && tokens > 0 ? cost / Double(tokens) : nil
    }
}
