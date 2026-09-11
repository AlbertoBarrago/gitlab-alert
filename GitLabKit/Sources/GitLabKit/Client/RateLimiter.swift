import Foundation

/// Rate-limit metadata emitted by GitLab REST endpoints when rate limiting is
/// enabled for an instance.
public struct RateLimitHeaders: Sendable, Hashable {
    public var remaining: Int?
    public var limit: Int?
    public var resetAt: Date?

    public var status: RateLimitStatus? {
        guard let remaining, let limit, let resetAt else { return nil }
        return RateLimitStatus(remaining: remaining, limit: limit, resetAt: resetAt)
    }

    public init(response: HTTPResponse) {
        remaining = response.header("ratelimit-remaining").flatMap(Int.init)
            ?? response.header("x-ratelimit-remaining").flatMap(Int.init)
        limit = response.header("ratelimit-limit").flatMap(Int.init)
            ?? response.header("x-ratelimit-limit").flatMap(Int.init)
        resetAt = response.header("ratelimit-reset").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            ?? response.header("x-ratelimit-reset").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }
}

/// Decides how long to wait before the next poll.
///
/// A value type on purpose: every input (headers, the `rateLimit` field, a
/// failure, the clock, the jitter) is passed in, so the whole policy is unit
/// testable without a network, a timer or a random number generator.
public struct RateLimiter: Sendable {
    /// Backoff constants, split by cause. Secondary limits need a far longer
    /// wait than a flaky connection, and mixing the two is how an app gets its
    /// token throttled for the rest of the hour.
    public struct Policy: Sendable, Hashable {
        public var transientBase: TimeInterval
        public var transientCap: TimeInterval
        public var secondaryBase: TimeInterval
        public var secondaryCap: TimeInterval

        public init(
            transientBase: TimeInterval = 2,
            transientCap: TimeInterval = 300,
            secondaryBase: TimeInterval = 60,
            secondaryCap: TimeInterval = 1800
        ) {
            self.transientBase = transientBase
            self.transientCap = transientCap
            self.secondaryBase = secondaryBase
            self.secondaryCap = secondaryCap
        }

        public static let `default` = Policy()
    }

    /// Latest known budget, from whichever source reported most recently.
    public private(set) var status: RateLimitStatus?
    /// Hard floor: never send a request before this instant.
    public private(set) var notBefore: Date?
    public private(set) var transientFailureCount: Int = 0
    public private(set) var secondaryLimitCount: Int = 0

    public let policy: Policy

    /// Full jitter source: given an upper bound, returns a wait in `0...bound`.
    /// Injected so the backoff sequence is reproducible in tests — the type
    /// never reaches for `Double.random` itself.
    private let jitter: @Sendable (TimeInterval) -> TimeInterval

    public init(
        policy: Policy = .default,
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { bound in
            bound <= 0 ? 0 : Double.random(in: 0...bound)
        }
    ) {
        self.policy = policy
        self.jitter = jitter
    }

    /// Jitter that always returns the full ceiling. Deterministic, and the
    /// worst case, which is what a backoff test wants to pin down.
    public static let ceilingJitter: @Sendable (TimeInterval) -> TimeInterval = { $0 }

    // MARK: Ingest

    /// Records `x-ratelimit-*`. Only applied when the headers carried the full
    /// triple; a partial set would produce a nonsense `fraction`.
    public mutating func ingest(headers: RateLimitHeaders) {
        if let headerStatus = headers.status {
            status = headerStatus
        }
    }

    /// A completed request. Clears the failure backoff, but leaves `notBefore`
    /// alone when it was set by a rate limit reset that has not passed yet.
    public mutating func noteSuccess(now: Date = Date()) {
        transientFailureCount = 0
        secondaryLimitCount = 0
        if let notBefore, notBefore <= now {
            self.notBefore = nil
        }
    }

    /// Offline, DNS, TLS or 5xx: exponential backoff with full jitter.
    public mutating func noteTransientFailure(now: Date = Date()) {
        transientFailureCount += 1
        let wait = backoff(
            attempt: transientFailureCount,
            base: policy.transientBase,
            cap: policy.transientCap
        )
        pushFloor(now.addingTimeInterval(wait))
    }

    /// A classified `.rateLimited`.
    ///
    /// `retryAfter` is honoured exactly — GitLab told us the number, jittering
    /// it either wastes budget or gets the request refused again. A reset time
    /// in the future is a hard floor for the same reason.
    public mutating func noteRateLimited(
        retryAfter: TimeInterval?,
        resetAt: Date?,
        secondary: Bool,
        now: Date = Date()
    ) {
        if secondary { secondaryLimitCount += 1 }

        if let retryAfter, retryAfter > 0 {
            pushFloor(now.addingTimeInterval(retryAfter))
        } else if let resetAt, resetAt > now {
            pushFloor(resetAt)
        } else {
            // Rate limited with no usable timing hint. Backing off on the
            // secondary schedule is the safe read: polling again straight away
            // is what escalates a soft throttle into a hard one.
            let attempt = secondary ? secondaryLimitCount : max(1, secondaryLimitCount + 1)
            let wait = backoff(attempt: attempt, base: policy.secondaryBase, cap: policy.secondaryCap)
            pushFloor(now.addingTimeInterval(wait))
        }
        // `resetAt` is deliberately not also folded in here: a secondary limit
        // with `retry-after: 60` while the primary budget is untouched must wait
        // one minute, not until the hourly reset. Exhaustion of the budget
        // itself is already a floor via `status` in `nextAllowedRequest`.
    }

    // MARK: Query

    /// The interval the poller should actually use.
    ///
    /// Three effects stack, strongest wins: an outstanding backoff or reset
    /// floor, an exhausted budget, and progressive widening once the budget
    /// drops under 15%.
    public func recommendedInterval(desired: TimeInterval, now: Date = Date()) -> TimeInterval {
        var interval = widened(desired)

        if let status, status.remaining <= 0, status.resetAt > now {
            interval = max(interval, status.resetAt.timeIntervalSince(now))
        }
        if let notBefore, notBefore > now {
            interval = max(interval, notBefore.timeIntervalSince(now))
        }
        return max(0, interval)
    }

    /// The earliest instant a request may be sent, or `nil` when unrestricted.
    public func nextAllowedRequest(now: Date = Date()) -> Date? {
        var floor: Date?
        if let notBefore, notBefore > now { floor = notBefore }
        if let status, status.remaining <= 0, status.resetAt > now {
            floor = floor.map { max($0, status.resetAt) } ?? status.resetAt
        }
        return floor
    }

    public func isBlocked(now: Date = Date()) -> Bool {
        nextAllowedRequest(now: now) != nil
    }

    /// Progressive widening. The steps are coarse deliberately: the point is to
    /// stretch the budget until reset, not to model it precisely.
    private func widened(_ desired: TimeInterval) -> TimeInterval {
        guard let status, status.isRunningLow else { return desired }
        let fraction = status.fraction
        let multiplier: Double
        if fraction < 0.05 {
            multiplier = 8
        } else if fraction < 0.10 {
            multiplier = 4
        } else {
            multiplier = 2
        }
        return desired * multiplier
    }

    private func backoff(attempt: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let ceiling = min(cap, base * pow(2, exponent))
        return jitter(ceiling)
    }

    /// Floors only ever move forward: a short transient backoff must not undo a
    /// long rate-limit reset we already committed to.
    private mutating func pushFloor(_ date: Date) {
        if let existing = notBefore {
            notBefore = max(existing, date)
        } else {
            notBefore = date
        }
    }
}

/// Serialises access to a ``RateLimiter`` so the client (a value type shared
/// across tasks) can record every response it sees.
public actor RateLimitTracker {
    private var limiter: RateLimiter

    public init(limiter: RateLimiter = RateLimiter()) {
        self.limiter = limiter
    }

    public var status: RateLimitStatus? { limiter.status }
    public var notBefore: Date? { limiter.notBefore }

    public func recommendedInterval(desired: TimeInterval, now: Date = Date()) -> TimeInterval {
        limiter.recommendedInterval(desired: desired, now: now)
    }

    public func nextAllowedRequest(now: Date = Date()) -> Date? {
        limiter.nextAllowedRequest(now: now)
    }

    public func ingest(headers: RateLimitHeaders) {
        limiter.ingest(headers: headers)
    }

    public func noteSuccess(now: Date = Date()) {
        limiter.noteSuccess(now: now)
    }

    public func noteTransientFailure(now: Date = Date()) {
        limiter.noteTransientFailure(now: now)
    }

    public func noteRateLimited(
        retryAfter: TimeInterval?,
        resetAt: Date?,
        secondary: Bool,
        now: Date = Date()
    ) {
        limiter.noteRateLimited(retryAfter: retryAfter, resetAt: resetAt, secondary: secondary, now: now)
    }

    /// Read-only copy, for tests and for a status view that wants the counters.
    public func snapshot() -> RateLimiter { limiter }
}
