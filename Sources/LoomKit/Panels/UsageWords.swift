import Foundation

/// The words for a usage estimate, following `session_view/usage_display`.
///
/// A cost reads as an estimate everywhere, qualified by its rate basis and by
/// how much of the usage it covers, so a subscription's reference rate or a
/// partial total is never shown as a billed price. An unavailable price reads
/// as a dash, never as zero.
public enum UsageWords {
    /// The evidence the daemon attaches to usage, decoded totally. An absent
    /// or unrecognized claim reads as unreported, which is the safe reading.
    public enum Evidence: Sendable, Equatable {
        /// No provider was contacted, so there is no expense.
        case noProvider
        /// Tokens were not reported, so nothing can be priced.
        case unreported
        /// Tokens were reported but have no price.
        case unpriced
        /// A dollar estimate with its coverage and rate basis.
        case priced(partial: Bool, basis: String)

        public init(_ value: JSONValue?) {
            guard let value, value["version"]?.int == 1 else {
                self = .unreported
                return
            }
            let cost = value["cost"]
            switch cost?["kind"]?.string {
            case "no-expense":
                self = .noProvider
            case "estimated":
                self = .priced(
                    partial: cost?["coverage"]?.string == "partial" || value["tokens"]?.string == "partial",
                    basis: cost?["basis"]?.string ?? "api-rates"
                )
            case "unavailable":
                self = value["tokens"]?.string == "unknown" ? .unreported : .unpriced
            default:
                self = .unreported
            }
        }
    }

    /// The estimate with its `est` marker, for a surface that stands alone.
    public static func estimate(_ amount: Double, _ evidence: Evidence) -> String {
        words(amount, evidence, marker: "est ")
    }

    /// The estimate without the marker, for a row whose label says estimate.
    public static func figure(_ amount: Double, _ evidence: Evidence) -> String {
        words(amount, evidence, marker: "")
    }

    /// Words a session's usage object: the total cost and its evidence.
    public static func estimate(usage: JSONValue) -> String {
        estimate(usage["cost"]?["total"]?.double ?? 0, Evidence(usage["evidence"]))
    }

    public static func figure(usage: JSONValue) -> String {
        figure(usage["cost"]?["total"]?.double ?? 0, Evidence(usage["evidence"]))
    }

    private static func words(_ amount: Double, _ evidence: Evidence, marker: String) -> String {
        switch evidence {
        case .noProvider:
            return marker + "$0.00"
        case .unreported, .unpriced:
            return marker + "—"
        case .priced(let partial, let basis):
            let prefix: String
            switch basis {
            case "chatgpt-reference-rates": prefix = "API ref "
            case "mixed-rates": prefix = "mixed rates "
            default: prefix = ""
            }
            return prefix + (partial ? "partial " : "") + marker + "$" + money(amount)
        }
    }

    /// Rounds once to cents so a binary floating-point tail never reaches a
    /// panel. A negative amount reads as zero.
    public static func money(_ value: Double) -> String {
        let cents = max(0, Int((value * 100).rounded()))
        return "\(cents / 100)." + String(format: "%02d", cents % 100)
    }
}
