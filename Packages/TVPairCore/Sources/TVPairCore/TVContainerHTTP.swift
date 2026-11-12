import Foundation

public struct TVContainerFile: Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let size: Int64
    public let contentType: String
    public var downloadPath: String { "/v1/files/" + id.uuidString }
    public init(id: UUID, name: String, size: Int64, contentType: String) {
        self.id = id; self.name = name; self.size = size; self.contentType = contentType
    }
}

/// Small, read-only HTTP/1.x contract shared with TVContainer. No filesystem paths on the wire.
public enum TVContainerHTTP {
    public static let serviceType = "_sidetvstore._tcp"
    public static let maximumHeaderBytes = 16_384
    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let range: String?
    }
    public enum Failure: Error { case invalidRequest, unsupportedMethod, invalidRange }

    public static func request(_ data: Data) throws -> Request {
        guard data.count <= maximumHeaderBytes, let text = String(data: data, encoding: .ascii),
              text.hasSuffix("\r\n\r\n") else { throw Failure.invalidRequest }
        let lines = text.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(start[2])),
              start[1].hasPrefix("/"), !start[1].contains("%"), !start[1].contains(".."),
              !start[1].contains("?"), !start[1].contains("#") else { throw Failure.invalidRequest }
        guard ["GET", "HEAD"].contains(String(start[0])) else { throw Failure.unsupportedMethod }
        var range: String?
        var seen = Set<String>()
        for line in lines.dropFirst() where !line.isEmpty {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw Failure.invalidRequest }
            let name = line[..<colon].lowercased()
            guard seen.insert(name).inserted else { throw Failure.invalidRequest }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard name != "transfer-encoding", name != "content-length" || value == "0" else { throw Failure.invalidRequest }
            if name == "range" { range = value }
        }
        return Request(method: String(start[0]), path: String(start[1]), range: range)
    }

    /// Half-open interval. Only a single byte range is supported.
    public static func byteRange(_ header: String?, size: Int64) throws -> Range<Int64> {
        guard size >= 0 else { throw Failure.invalidRange }
        guard let header else { return 0..<size }
        guard header.hasPrefix("bytes="), !header.contains(","), size > 0 else { throw Failure.invalidRange }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw Failure.invalidRange }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { throw Failure.invalidRange }
            return max(0, size - suffix)..<size
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { throw Failure.invalidRange }
        if parts[1].isEmpty { return start..<size }
        guard let end = Int64(parts[1]), end >= start else { throw Failure.invalidRange }
        return start..<(min(end, size - 1) + 1)
    }

    public static func catalog(_ files: [TVContainerFile]) throws -> Data {
        struct Entry: Encodable {
            let id: UUID; let name: String; let size: Int64; let contentType: String; let downloadPath: String
        }
        struct Catalog: Encodable { let version = 1; let files: [Entry] }
        return try JSONEncoder().encode(Catalog(files: files.map {
            Entry(id: $0.id, name: $0.name, size: $0.size, contentType: $0.contentType, downloadPath: $0.downloadPath)
        }))
    }
}
