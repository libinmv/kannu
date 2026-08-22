import XCTest

final class CursorUsageEventDecoderTests: XCTestCase {
    private func event(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("fixture is not a JSON object")
            return [:]
        }
        return object
    }

    // Token-based event exactly as the live endpoint returns it (values anonymized).
    // Note cacheWriteTokens can be absent — it must decode as 0, not fail.
    func testTokenBasedEventDecodesCounts() {
        let fixture = event(#"""
        {"timestamp":"1787334335464","model":"claude-4.5-opus","kind":"USAGE_EVENT_KIND_USAGE_BASED",
         "tokenUsage":{"inputTokens":223411,"outputTokens":488,"cacheReadTokens":222912,"totalCents":112.53},
         "usageBasedCosts":"$1.12","chargedCents":112,"isTokenBasedCall":true}
        """#)
        let counts = CursorUsageEventDecoder.tokenCounts(in: fixture)
        XCTAssertEqual(counts.input, 223411)
        XCTAssertEqual(counts.output, 488)
        XCTAssertEqual(counts.cacheWrite, 0)
        XCTAssertEqual(counts.cacheRead, 222912)
        XCTAssertEqual(counts.totalInput, 223411 + 222912)
        XCTAssertFalse(counts.isEmpty)
    }

    // Included-in-plan events carry no tokenUsage container at all — they must
    // decode to empty counts (skipped), never break the whole snapshot.
    func testIncludedInProEventWithoutTokenUsageIsEmpty() {
        let fixture = event(#"""
        {"timestamp":"1787334335464","model":"cursor-grok-4.5-high-fast",
         "kind":"USAGE_EVENT_KIND_INCLUDED_IN_PRO","usageBasedCosts":"$0.00",
         "isTokenBasedCall":false,"cursorTokenFee":0,"chargedCents":0}
        """#)
        XCTAssertNil(CursorUsageEventDecoder.tokenUsageDict(in: fixture))
        let counts = CursorUsageEventDecoder.tokenCounts(in: fixture)
        XCTAssertEqual(counts, CursorUsageEventDecoder.TokenCounts())
        XCTAssertTrue(counts.isEmpty)
    }

    func testZeroTokenUsageContainerIsEmpty() {
        let fixture = event(#"{"tokenUsage":{"inputTokens":0,"outputTokens":0,"cacheWriteTokens":0,"cacheReadTokens":0}}"#)
        XCTAssertTrue(CursorUsageEventDecoder.tokenCounts(in: fixture).isEmpty)
    }

    // Cursor mixes numbers and numeric strings across fields.
    func testNumericStringsParse() {
        let fixture = event(#"{"tokenUsage":{"inputTokens":"1200","outputTokens":"34","cacheWriteTokens":"5","cacheReadTokens":"600"}}"#)
        let counts = CursorUsageEventDecoder.tokenCounts(in: fixture)
        XCTAssertEqual(counts, CursorUsageEventDecoder.TokenCounts(input: 1200, output: 34, cacheWrite: 5, cacheRead: 600))
    }

    func testMalformedValuesDecodeToZero() {
        let fixture = event(#"{"tokenUsage":{"inputTokens":"abc","outputTokens":null,"cacheReadTokens":{"nested":1}}}"#)
        XCTAssertTrue(CursorUsageEventDecoder.tokenCounts(in: fixture).isEmpty)
    }
}
