import XCTest
@testable import TVPairCore

final class TVContainerHTTPTests: XCTestCase {
    func testReadOnlyRoutesRejectTraversalAndRequestSmuggling() throws {
        let request = try TVContainerHTTP.request(Data("GET /v1/files HTTP/1.1\r\nHost: iphone.local\r\n\r\n".utf8))
        XCTAssertEqual(request.path, "/v1/files")
        for text in [
            "POST /v1/files HTTP/1.1\r\n\r\n",
            "GET /../private HTTP/1.1\r\n\r\n",
            "GET /v1/files/%2e%2e HTTP/1.1\r\n\r\n",
            "GET http://example.com/v1/files HTTP/1.1\r\n\r\n",
            "GET /v1/files HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "GET /v1/files HTTP/1.1\r\nContent-Length: 2\r\n\r\n",
            "GET /v1/files HTTP/1.1\r\nRange: bytes=0-1\r\nRange: bytes=2-3\r\n\r\n",
            "GET /v1/files HTTP/1.1\r\n Folded: header\r\n\r\n"
        ] { XCTAssertThrowsError(try TVContainerHTTP.request(Data(text.utf8)), text) }
        XCTAssertThrowsError(try TVContainerHTTP.request(Data(repeating: 65, count: 16_385)))
    }
    func testResumableRangesIncludeBoundaryAndOverflowCases() throws {
        XCTAssertEqual(try TVContainerHTTP.byteRange(nil, size: 100), 0..<100)
        XCTAssertEqual(try TVContainerHTTP.byteRange("bytes=20-", size: 100), 20..<100)
        XCTAssertEqual(try TVContainerHTTP.byteRange("bytes=20-29", size: 100), 20..<30)
        XCTAssertEqual(try TVContainerHTTP.byteRange("bytes=-10", size: 100), 90..<100)
        XCTAssertEqual(try TVContainerHTTP.byteRange("bytes=-200", size: 100), 0..<100)
        XCTAssertEqual(try TVContainerHTTP.byteRange("bytes=0-9223372036854775807", size: 100), 0..<100)
        XCTAssertEqual(try TVContainerHTTP.byteRange(nil, size: 0), 0..<0)
        for value in ["bytes=100-", "bytes=-0", "bytes=3-2", "bytes=1-2,4-5", "bytes=9223372036854775808-", "garbage"] {
            XCTAssertThrowsError(try TVContainerHTTP.byteRange(value, size: 100))
        }
        XCTAssertThrowsError(try TVContainerHTTP.byteRange("bytes=0-", size: 0))
    }
    func testCatalogUsesOpaqueIDsAndEscapesUserFilenames() throws {
        let id = UUID()
        let entry = TVContainerFile(id: id, name: "App \"TV\"\n.ipa", size: 50_000_000, contentType: "application/octet-stream")
        let data = try TVContainerHTTP.catalog([entry])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let file = try XCTUnwrap((json["files"] as? [[String: Any]])?.first)
        XCTAssertEqual(file["name"] as? String, entry.name)
        XCTAssertEqual(file["downloadPath"] as? String, "/v1/files/" + id.uuidString)
        XCTAssertNil(file["url"])
        XCTAssertEqual(TVContainerHTTP.serviceType, "_sidetvstore._tcp")
    }
}
