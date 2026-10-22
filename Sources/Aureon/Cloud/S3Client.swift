import Foundation
import CryptoKit

// Bring-your-own-cloud storage: any S3-compatible bucket (Amazon S3, Backblaze B2's S3 API, Cloudflare R2, MinIO, Wasabi …).
// Requests are signed with AWS Signature Version 4; only GETs and LISTs are needed to play music.

struct S3Credentials: Equatable, Sendable {
    var accessKey: String
    var secretKey: String
    var sessionToken: String? = nil
}

enum SigV4 {
    private static func hmac(_ key: Data, _ s: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: SymmetricKey(data: key))) }
    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ d: Data) -> String { hex(SHA256.hash(data: d)) }

    /// RFC 3986 encoding as AWS wants it: only A–Z a–z 0–9 - _ . ~ stay (and "/" when encoding a path).
    static func encode(_ s: String, keepSlash: Bool = false) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F, 0x2E, 0x7E: out.append(Character(UnicodeScalar(b)))
            case 0x2F where keepSlash: out.append("/")
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    static func stamps(_ date: Date) -> (amz: String, day: String) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        return (day + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!), day)
    }

    /// The canonical request (exposed for the published test vectors).
    static func canonicalRequest(method: String, path: String, query: [(String, String)], headers: [(String, String)], payloadHash: String) -> (text: String, signedHeaders: String) {
        var pairs: [(String, String)] = []
        for q in query { pairs.append((encode(q.0), encode(q.1))) }
        pairs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let canonQuery = pairs.map { $0.0 + "=" + $0.1 }.joined(separator: "&")
        var hs: [(String, String)] = []
        for h in headers { hs.append((h.0.lowercased(), h.1.trimmingCharacters(in: .whitespaces))) }
        hs.sort { $0.0 < $1.0 }
        var canonHeaders = ""
        for h in hs { canonHeaders += h.0 + ":" + h.1 + "\n" }
        let signed = hs.map { $0.0 }.joined(separator: ";")
        return ([method, path, canonQuery, canonHeaders, signed, payloadHash].joined(separator: "\n"), signed)
    }

    static func signature(canonical: String, region: String, service: String, secret: String, stamp: (amz: String, day: String)) -> (signature: String, scope: String) {
        let scope = "\(stamp.day)/\(region)/\(service)/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(stamp.amz)\n\(scope)\n\(sha256(Data(canonical.utf8)))"
        let k = hmac(hmac(hmac(hmac(Data("AWS4\(secret)".utf8), stamp.day), region), service), "aws4_request")
        return (hex(hmac(k, toSign)), scope)
    }

    /// Adds Host, x-amz-* and Authorization headers to a request whose URL is already percent-encoded the AWS way.
    static func sign(_ req: inout URLRequest, body: Data = Data(), region: String, service: String = "s3", credentials c: S3Credentials, date: Date = Date()) {
        guard let url = req.url, let host = url.host else { return }
        let stamp = stamps(date), payload = sha256(body)
        let hostHeader = url.port.map { ($0 == 80 && url.scheme == "http") || ($0 == 443 && url.scheme == "https") ? host : "\(host):\($0)" } ?? host
        req.setValue(hostHeader, forHTTPHeaderField: "Host")
        req.setValue(payload, forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue(stamp.amz, forHTTPHeaderField: "x-amz-date")
        if let t = c.sessionToken { req.setValue(t, forHTTPHeaderField: "x-amz-security-token") }
        let signedNames: Set<String> = ["host", "range", "x-amz-content-sha256", "x-amz-date", "x-amz-security-token", "content-type"]
        let headers = (req.allHTTPHeaderFields ?? [:]).filter { signedNames.contains($0.key.lowercased()) }.map { ($0.key, $0.value) }
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []).map { ($0.name.removingPercentEncoding ?? $0.name, ($0.value ?? "").removingPercentEncoding ?? "") }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        let canon = canonicalRequest(method: req.httpMethod ?? "GET", path: path.isEmpty ? "/" : path, query: query, headers: headers, payloadHash: payload)
        let sig = signature(canonical: canon.text, region: region, service: service, secret: c.secretKey, stamp: stamp)
        req.setValue("AWS4-HMAC-SHA256 Credential=\(c.accessKey)/\(sig.scope), SignedHeaders=\(canon.signedHeaders), Signature=\(sig.signature)", forHTTPHeaderField: "Authorization")
    }
}

struct S3Config: Codable, Equatable, Sendable {
    var endpoint: URL
    var region: String
    var bucket: String
    var pathStyle = true
    var prefix = ""
}

struct S3Object: Equatable, Sendable {
    var key: String
    var size: Int64
    var modified: Date?
    var etag: String?
}

struct S3Listing: Equatable, Sendable {
    var objects: [S3Object] = []
    var folders: [String] = []
    var nextToken: String?
}

enum S3Error: LocalizedError {
    case http(Int, code: String?, message: String?)
    case malformed(String)
    var errorDescription: String? {
        switch self {
        case .http(let s, let code, let m):
            switch (s, code) {
            case (403, "SignatureDoesNotMatch"): return "The bucket rejected the signature: check the secret key, the region and the endpoint."
            case (403, "InvalidAccessKeyId"), (403, "InvalidAccessKey"): return "The bucket does not know this access key."
            case (403, _): return "Access denied (\(code ?? "403")): the key may not be allowed to read this bucket."
            case (404, "NoSuchBucket"): return "There is no bucket with that name at this endpoint."
            case (404, _): return "Not found (\(code ?? "404"))."
            case (301, _), (400, "AuthorizationHeaderMalformed"), (400, "InvalidRegionName"): return "The bucket is in a different region than the one entered\(m.map { " (\($0))" } ?? "")."
            default: return "The storage service answered \(s)\(code.map { " (\($0))" } ?? "")\(m.map { ": \($0)" } ?? "")."
            }
        case .malformed(let m): return m
        }
    }
}

/// Reads an S3 error document or a ListObjectsV2 answer.
final class S3XML: NSObject, XMLParserDelegate {
    private var stack: [String] = [], text = ""
    private var obj = S3Object(key: "", size: 0)
    private(set) var listing = S3Listing()
    private(set) var errorCode: String?, errorMessage: String?
    private var truncated = false

    static func parse(_ d: Data) -> S3XML? {
        let h = S3XML(), p = XMLParser(data: d); p.delegate = h
        return p.parse() ? h : nil
    }
    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let iso2 = ISO8601DateFormatter()

    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(e); text = ""
        if e == "Contents" { obj = S3Object(key: "", size: 0) }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let parent = stack.dropLast().last
        switch (parent, e) {
        case ("Contents", "Key"): obj.key = text
        case ("Contents", "Size"): obj.size = Int64(text) ?? 0
        case ("Contents", "ETag"): obj.etag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case ("Contents", "LastModified"): obj.modified = Self.iso.date(from: text) ?? Self.iso2.date(from: text)
        case ("ListBucketResult", "Contents"): break
        case ("CommonPrefixes", "Prefix"): listing.folders.append(text)
        case ("ListBucketResult", "NextContinuationToken"): listing.nextToken = text
        case ("ListBucketResult", "IsTruncated"): truncated = text == "true"
        case ("Error", "Code"): errorCode = text
        case ("Error", "Message"): errorMessage = text
        default: break
        }
        if e == "Contents" { listing.objects.append(obj) }
        stack.removeLast(); text = ""
    }
    var isTruncated: Bool { truncated }
}

final class S3Client: @unchecked Sendable {
    let config: S3Config
    private let credentials: S3Credentials
    private let http: HTTPClient
    var now: @Sendable () -> Date = { Date() }

    init(config: S3Config, credentials: S3Credentials, http: HTTPClient = S3HTTP.shared) {
        self.config = config; self.credentials = credentials; self.http = http
    }

    func url(key: String?, query: [(String, String)] = []) -> URL {
        var comps = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)!
        let base = config.endpoint.path.hasSuffix("/") ? String(config.endpoint.path.dropLast()) : config.endpoint.path
        var path = base
        if config.pathStyle { path += "/" + SigV4.encode(config.bucket) } else { comps.host = "\(config.bucket).\(comps.host ?? "")" }
        path += key.map { "/" + SigV4.encode($0, keepSlash: true) } ?? (config.pathStyle ? "" : "/")
        if path.isEmpty { path = "/" }
        comps.percentEncodedPath = path
        if !query.isEmpty { comps.percentEncodedQuery = query.map { "\(SigV4.encode($0.0))=\(SigV4.encode($0.1))" }.joined(separator: "&") }
        return comps.url!
    }

    private func perform(_ url: URL, range: Range<Int64>? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if let r = range { req.setValue("bytes=\(r.lowerBound)-\(r.upperBound - 1)", forHTTPHeaderField: "Range") }
        SigV4.sign(&req, region: config.region, credentials: credentials, date: now())
        let (d, status) = try await http.send(req)
        if status == 200 || status == 206 { return d }
        if status == 416 { return Data() }
        let x = S3XML.parse(d)
        throw S3Error.http(status, code: x?.errorCode, message: x?.errorMessage)
    }

    /// One page of keys under `prefix`; with a delimiter the "folders" come back too.
    func list(prefix: String, delimiter: String? = "/", maxKeys: Int = 1000, token: String? = nil) async throws -> S3Listing {
        var q: [(String, String)] = [("list-type", "2"), ("max-keys", "\(maxKeys)"), ("prefix", prefix)]
        if let delimiter { q.append(("delimiter", delimiter)) }
        if let token { q.append(("continuation-token", token)) }
        let d = try await perform(url(key: nil, query: q))
        guard let x = S3XML.parse(d) else { throw S3Error.malformed("The storage service sent something that is not a listing.") }
        if let c = x.errorCode { throw S3Error.http(200, code: c, message: x.errorMessage) }
        var l = x.listing
        if !x.isTruncated { l.nextToken = nil }
        return l
    }

    /// Everything under the prefix, following continuation tokens.
    func listAll(prefix: String, recursive: Bool = true, limit: Int = 1_000_000) async throws -> [S3Object] {
        var out: [S3Object] = [], token: String?
        repeat {
            let page = try await list(prefix: prefix, delimiter: recursive ? nil : "/", token: token)
            out += page.objects
            token = page.nextToken
        } while token != nil && out.count < limit
        return out
    }

    func get(key: String, range: Range<Int64>? = nil) async throws -> Data { try await perform(url(key: key), range: range) }

    /// Size and modification time of one object, found through a listing (the HTTP layer returns no headers).
    func stat(key: String) async throws -> S3Object? {
        try await list(prefix: key, delimiter: nil, maxKeys: 5).objects.first { $0.key == key }
    }
}

/// A URLSession tuned for many parallel range requests to the same host.
final class S3HTTP: HTTPClient, @unchecked Sendable {
    static let shared = S3HTTP()
    private let session: URLSession
    init() {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 8; c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 300
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.urlCache = nil; c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (d, r) = try await session.data(for: request)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
