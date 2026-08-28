@testable import FluidVoice_Debug
import XCTest

@MainActor
final class GrokSTTRetryStoreTests: XCTestCase {
    func testRetainConsumeClear() {
        let store = GrokSTTRetryStore()
        XCTAssertFalse(store.hasPending)
        store.retain(samples: [0.1, 0.2], error: .offline, languageCode: "en")
        XCTAssertTrue(store.hasPending)
        let pending = store.consume()
        XCTAssertEqual(pending?.samples.count, 2)
        XCTAssertEqual(pending?.error, .offline)
        XCTAssertEqual(pending?.languageCode, "en")
        XCTAssertEqual(pending?.keyterms, [])
        XCTAssertFalse(store.hasPending)
        XCTAssertNil(store.consume())

        store.retain(samples: [1], error: .timeout, languageCode: nil, keyterms: ["FluidVoice"])
        XCTAssertEqual(store.pending?.keyterms, ["FluidVoice"])
        store.clear()
        XCTAssertFalse(store.hasPending)
    }

    func testTTLExpiresPending() {
        var now = Date(timeIntervalSince1970: 1_000)
        let store = GrokSTTRetryStore(now: { now })
        store.retain(samples: [0.1], error: .offline, languageCode: nil)
        XCTAssertTrue(store.hasPending)
        now = now.addingTimeInterval(GrokSTTRetryStore.ttl + 1)
        XCTAssertFalse(store.hasPending)
        XCTAssertNil(store.consume())
    }

    func testTenMinuteTruncation() {
        let store = GrokSTTRetryStore()
        let tooLong = [Float](repeating: 0.1, count: 16_000 * 600 + 50)
        store.retain(samples: tooLong, error: .timeout, languageCode: nil)
        XCTAssertEqual(store.pending?.samples.count, 16_000 * 600)
    }

    func testCancelClears() {
        let store = GrokSTTRetryStore()
        store.retain(samples: [0.2], error: .offline, languageCode: nil)
        store.clear()
        XCTAssertFalse(store.hasPending)
    }
}
