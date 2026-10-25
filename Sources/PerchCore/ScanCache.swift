import Foundation

/// The last process scan, kept so a reply does not walk the whole process table before it types. Generic over the hit so
/// it can be tested here; the app stores its `LiveSessions.Hit`s. A scan stores itself; a lookup answers only from a scan
/// younger than `maxAge`, and only with a hit whose process is still alive. Anything else is a miss and the caller scans.
public final class ScanCache<Hit>: @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [Hit] = []
    private var at: Date?

    public init() {}

    /// Remembers a fresh scan.
    public func store(_ hits: [Hit], at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        self.hits = hits; at = now
    }

    /// Forgets the scan: the next lookup misses.
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        hits = []; at = nil
    }

    /// How old the stored scan is, nil when there is none.
    public func age(at now: Date = Date()) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return at.map { now.timeIntervalSince($0) }
    }

    /// The first stored hit that `match` accepts and `isAlive` still confirms, when the scan is at most `maxAge` old.
    public func lookup(maxAge: TimeInterval, at now: Date = Date(), where match: (Hit) -> Bool, isAlive: (Hit) -> Bool) -> Hit? {
        lock.lock()
        let snapshot = hits, stamp = at
        lock.unlock()
        guard let stamp, now.timeIntervalSince(stamp) <= maxAge else { return nil }
        return snapshot.first { match($0) && isAlive($0) }
    }

    /// The hit the first matcher accepts, else the second, and so on: from the cache when it can answer, else from a new
    /// scan, which is stored. `scan` runs only on a miss (no scan, an old one, no match, or the match's process gone), so a
    /// session that started after the last scan is found by the rescan.
    public func find(maxAge: TimeInterval, at now: Date = Date(), matching matchers: [(Hit) -> Bool], isAlive: (Hit) -> Bool,
                     scan: () -> [Hit]) -> (hit: Hit?, hits: [Hit], cached: Bool) {
        for m in matchers {
            if let hit = lookup(maxAge: maxAge, at: now, where: m, isAlive: isAlive) {
                lock.lock(); let all = hits; lock.unlock()
                return (hit, all, true)
            }
        }
        let fresh = scan()
        store(fresh, at: now)
        for m in matchers { if let hit = fresh.first(where: m) { return (hit, fresh, false) } }
        return (nil, fresh, false)
    }
}
