import Foundation

/// How often and how fast `HelperConnection` retries a failed connection.
///
/// Delays grow exponentially (0.5 s, 1 s, 2 s with the defaults). Retrying instantly would
/// burn every attempt in a few milliseconds, often while launchd is still restarting the
/// helper and the socket does not exist yet. Waiting longer each time gives a restart a
/// real chance to finish.
///
/// Jitter adds a small random amount to each delay. When several clients lose the helper
/// at the same moment, the randomness spreads out their reconnects instead of having all
/// of them arrive together.
public struct RetryPolicy: Sendable, Equatable {
    /// Retries after the first attempt fails. The default 3 means up to 4 attempts in total.
    public var maxRetries: Int
    public var initialDelay: Duration
    public var multiplier: Double
    public var maxDelay: Duration
    /// Fraction of each delay added or removed at random. 0.2 means ±20%.
    public var jitter: Double

    public init(maxRetries: Int = 3,
                initialDelay: Duration = .milliseconds(500),
                multiplier: Double = 2,
                maxDelay: Duration = .seconds(4),
                jitter: Double = 0.2) {
        self.maxRetries = max(0, maxRetries)
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.jitter = min(max(jitter, 0), 1)
    }

    public var maxAttempts: Int { maxRetries + 1 }

    /// Delay before retry number `retry` (1-based).
    /// - Parameter random: a value in -1...1 that scales the jitter. Tests pass 0.
    public func delay(beforeRetry retry: Int, random: Double = .random(in: -1...1)) -> Duration {
        let exponent = Double(max(retry, 1) - 1)
        let base = min(initialDelay * pow(multiplier, exponent), maxDelay)
        return base * (1 + jitter * min(max(random, -1), 1))
    }
}

extension Duration {
    /// The duration as fractional seconds, for logs and messages.
    public var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
