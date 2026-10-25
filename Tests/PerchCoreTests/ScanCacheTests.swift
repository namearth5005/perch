import Testing
import Foundation
@testable import PerchCore

@Suite struct ScanCacheTests {
    struct H: Equatable { let pid: Int32, agent: String }
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let a = H(pid: 10, agent: "claude"), b = H(pid: 20, agent: "codex")

    private func find(_ c: ScanCache<H>, pid: Int32, at: Date, alive: @escaping (H) -> Bool = { _ in true }, scans: Counter, result: [H]) -> (hit: H?, hits: [H], cached: Bool) {
        c.find(maxAge: 5, at: at, matching: [{ $0.pid == pid }], isAlive: alive, scan: { scans.n += 1; return result })
    }
    final class Counter { var n = 0 }

    @Test func emptyCacheScansAndStores() {
        let c = ScanCache<H>(), n = Counter()
        let r = find(c, pid: 10, at: t0, scans: n, result: [a, b])
        #expect(r.hit == a); #expect(!r.cached); #expect(n.n == 1)
        #expect(c.age(at: t0) == 0)
    }

    @Test func freshCacheAnswersWithoutScanning() {
        let c = ScanCache<H>(), n = Counter()
        c.store([a, b], at: t0)
        let r = find(c, pid: 20, at: t0.addingTimeInterval(2), scans: n, result: [])
        #expect(r.hit == b); #expect(r.cached); #expect(n.n == 0)
    }

    @Test func staleCacheIsScannedAgain() {
        let c = ScanCache<H>(), n = Counter()
        c.store([a], at: t0)
        let r = find(c, pid: 10, at: t0.addingTimeInterval(6), scans: n, result: [a])
        #expect(r.hit == a); #expect(!r.cached); #expect(n.n == 1)
        #expect(c.age(at: t0.addingTimeInterval(6)) == 0)   // the new scan replaced the old one
    }

    @Test func aSessionThatIsNotInTheCacheTriggersAFreshScan() {
        let c = ScanCache<H>(), n = Counter()
        c.store([a], at: t0)
        let r = find(c, pid: 20, at: t0.addingTimeInterval(1), scans: n, result: [a, b])
        #expect(r.hit == b); #expect(!r.cached); #expect(n.n == 1)
        // and now it is cached
        let again = find(c, pid: 20, at: t0.addingTimeInterval(2), scans: n, result: [])
        #expect(again.cached); #expect(n.n == 1)
    }

    @Test func aDeadProcessIsNotAnswerFromTheCache() {
        let c = ScanCache<H>(), n = Counter()
        c.store([a, b], at: t0)
        let r = find(c, pid: 10, at: t0.addingTimeInterval(1), alive: { $0.pid != 10 }, scans: n, result: [b])
        #expect(r.hit == nil); #expect(!r.cached); #expect(n.n == 1)
    }

    @Test func invalidateForcesARescan() {
        let c = ScanCache<H>(), n = Counter()
        c.store([a], at: t0)
        c.invalidate()
        #expect(c.age(at: t0) == nil)
        let r = find(c, pid: 10, at: t0, scans: n, result: [a])
        #expect(!r.cached); #expect(n.n == 1)
    }

    @Test func notFoundAnywhereStillReportsTheFreshScan() {
        let c = ScanCache<H>(), n = Counter()
        let r = find(c, pid: 99, at: t0, scans: n, result: [a, b])
        #expect(r.hit == nil); #expect(r.hits == [a, b])
    }
}
