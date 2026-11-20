import Foundation

// Times of day for the session page: the clock in the transcript's gutter and the
// age of a running turn in the stream head. Both are drawn once per row or once
// per tick, so the formatting is plain arithmetic. It allocates no formatter and
// reads no clock: a caller passes the instant, and the zone, so a test states both.

/// A time of day in a zone and the words for a span.
public enum ClockTime {
    /// An instant in Unix milliseconds as a 24-hour time of day in `zone`, "13:40".
    /// The zone's offset is read at that instant, so a time across a change of
    /// daylight saving is the one the wall clock showed then.
    public static func words(_ ms: Int, in zone: TimeZone = .current) -> String {
        let seconds = ms / 1000
        let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(seconds)))

        // A zone west of UTC can put an instant near the epoch before midnight, so
        // the remainder is folded into a day and never read as negative.
        let day = 86_400
        let local = ((seconds + offset) % day + day) % day
        let minutes = local / 60
        return pad(minutes / 60) + ":" + pad(minutes % 60)
    }

    /// An instant in the reader's own zone, as a function a rule can take as its
    /// default clock.
    public static func local(_ ms: Int) -> String {
        words(ms, in: .current)
    }

    /// How long a turn has run, as the stream head says it: "under a minute", "14m",
    /// "1h 02m", then days. A negative span, which a clock that moved back gives,
    /// reads as no time at all.
    public static func turn(_ spanMs: Int) -> String {
        let span = max(spanMs, 0)
        let minutes = span / 60_000
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes)m" }
        if span < 86_400_000 { return "\(minutes / 60)h " + pad(minutes % 60) + "m" }
        return "\(span / 86_400_000)d"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
