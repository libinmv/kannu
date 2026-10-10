//
//  HTTPOutcomeTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

/// What each status code and network error means to Kannu, and how a `Retry-After` is read.
final class HTTPOutcomeTests: XCTestCase {
    /// Sun, 06 Nov 1994 08:49:37 GMT, the example date of RFC 9110.
    private let now = Date(timeIntervalSince1970: 784_111_777)

    private func outcome(_ status: Int, retryAfter: String? = nil) -> HTTPOutcome {
        HTTPOutcome.classify(status: status, retryAfter: retryAfter, now: now)
    }

    func testStatusCodes() {
        XCTAssertEqual(outcome(200), .ok(200))
        XCTAssertEqual(outcome(204), .ok(204))
        XCTAssertEqual(outcome(301), .redirected(301))
        XCTAssertEqual(outcome(302), .redirected(302))
        XCTAssertEqual(outcome(307), .redirected(307))
        XCTAssertEqual(outcome(401), .auth(401))
        XCTAssertEqual(outcome(400), .rejected(400))
        XCTAssertEqual(outcome(403), .rejected(403))
        XCTAssertEqual(outcome(404), .rejected(404))
        XCTAssertEqual(outcome(410), .rejected(410))
        XCTAssertEqual(outcome(429), .rateLimited(retryAfter: 60), "no Retry-After: a minute")
        XCTAssertEqual(outcome(429, retryAfter: "30"), .rateLimited(retryAfter: 30))
        XCTAssertEqual(outcome(503, retryAfter: "120"), .rateLimited(retryAfter: 120), "a 503 that says when is a rate limit")
        XCTAssertEqual(outcome(503), .ambiguous(503), "a bare 503 may have done the work")
        XCTAssertEqual(outcome(500), .ambiguous(500))
        XCTAssertEqual(outcome(502), .ambiguous(502))
        XCTAssertEqual(outcome(504), .ambiguous(504))
        XCTAssertEqual(outcome(100), .ambiguous(100))
    }

    func testNetworkErrors() {
        func classify(_ code: URLError.Code) -> HTTPOutcome { HTTPOutcome.classify(URLError(code)) }
        XCTAssertEqual(classify(.notConnectedToInternet), .offline)
        XCTAssertEqual(classify(.dataNotAllowed), .offline)
        for code: URLError.Code in [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .secureConnectionFailed,
                                    .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                                    .serverCertificateNotYetValid, .appTransportSecurityRequiresSecureConnection, .badURL] {
            XCTAssertEqual(classify(code), .failedBeforeSend, "\(code)")
        }
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .cancelled, .badServerResponse] {
            XCTAssertEqual(classify(code), .ambiguous(nil), "\(code): it may have arrived")
        }
    }

    func testRetryAfterSeconds() {
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("120", now: now), 120)
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds(" 30 ", now: now), 30)
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds(nil, now: now), 60)
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("", now: now), 60)
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("soon", now: now), 60)
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("Sun, 06 Nov 1994 08:51:07 GMT", now: now), 90, "an HTTP-date")
    }

    func testRetryAfterIsClamped() {
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("0", now: now), 1)
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("-5", now: now), 1)
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("999999", now: now), 3600, "a hostile header cannot lock Refresh out for days")
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("Sun, 06 Nov 1994 08:00:00 GMT", now: now), 1, "a date in the past")
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("Mon, 07 Nov 1994 08:49:37 GMT", now: now), 3600)
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("nan", now: now), 60)
        XCTAssertEqual(HTTPOutcome.retryAfterSeconds("inf", now: now), 60)
    }
}
