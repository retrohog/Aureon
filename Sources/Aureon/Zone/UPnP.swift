import Foundation
import Darwin

// UPnP / DLNA control: discovery (SSDP), device descriptions, and the SOAP calls a player needs to tell a renderer to play a URL.
// Sonos speakers are UPnP renderers too (plus their own group extension, see Zone.swift).

/// A minimal XML tree (namespace prefixes dropped from names).
final class XMLNode {
    let name: String
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String) { self.name = name }
    func child(_ n: String) -> XMLNode? { children.first { $0.name == n } }
    func find(_ n: String) -> XMLNode? {
        if name == n { return self }
        for c in children { if let f = c.find(n) { return f } }
        return nil
    }
    func all(_ n: String) -> [XMLNode] { (name == n ? [self] : []) + children.flatMap { $0.all(n) } }
    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum XMLTree {
    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String]) {
            let n = XMLNode(e.split(separator: ":").last.map(String.init) ?? e)
            if let top = stack.last { top.children.append(n) } else { root = n }
            stack.append(n)
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { stack.last?.text += s }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) { _ = stack.popLast() }
    }
    static func parse(_ d: Data) -> XMLNode? {
        let b = Builder(), p = XMLParser(data: d)
        p.delegate = b; p.shouldProcessNamespaces = false
        return p.parse() ? b.root : nil
    }
}

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
}

struct UPnPDevice: Identifiable, Equatable, Sendable {
    var id: String                    // UDN, e.g. uuid:RINCON_000E58...
    var name: String
    var manufacturer: String
    var model: String
    var host: String
    var avTransport: URL
    var renderingControl: URL?
    var isSonos: Bool { manufacturer.localizedCaseInsensitiveContains("sonos") || id.contains("RINCON_") }
    /// The id Sonos groups use: the UDN without its "uuid:" prefix.
    var rincon: String { id.hasPrefix("uuid:") ? String(id.dropFirst(5)) : id }

    static let avTransportType = "urn:schemas-upnp-org:service:AVTransport:1"
    static let renderingType = "urn:schemas-upnp-org:service:RenderingControl:1"

    /// Parses a device description. Returns nil for anything that cannot play media (no AVTransport service).
    static func parse(xml: Data, location: URL) -> UPnPDevice? {
        guard let root = XMLTree.parse(xml), let dev = root.find("device") else { return nil }
        var av: URL?, rc: URL?
        for s in root.all("service") {
            let type = s.child("serviceType")?.trimmed ?? "", ctl = s.child("controlURL")?.trimmed ?? ""
            guard !ctl.isEmpty, let u = URL(string: ctl, relativeTo: location)?.absoluteURL else { continue }
            if type.contains("AVTransport") { av = av ?? u } else if type.contains("RenderingControl") { rc = rc ?? u }
        }
        guard let av else { return nil }
        let udn = dev.child("UDN")?.trimmed ?? location.absoluteString
        return UPnPDevice(id: udn, name: dev.child("friendlyName")?.trimmed ?? location.host ?? "Renderer", manufacturer: dev.child("manufacturer")?.trimmed ?? "",
                          model: dev.child("modelName")?.trimmed ?? "", host: location.host ?? "", avTransport: av, renderingControl: rc)
    }
}

enum SSDP {
    static func request(st: String) -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(st)\r\n\r\n"
    }

    static func location(in response: String) -> URL? {
        for line in response.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("location:") {
            return URL(string: line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Multicasts an M-SEARCH and collects the description URLs that answer within `timeout`.
    static func search(st: String = UPnPDevice.avTransportType, timeout: TimeInterval = 2, target: String = "239.255.255.250", port: UInt16 = 1900) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var dest = sockaddr_in(); dest.sin_family = sa_family_t(AF_INET); dest.sin_port = port.bigEndian
        guard inet_pton(AF_INET, target, &dest.sin_addr) == 1 else { return [] }
        let msg = Array(request(st: st).utf8)
        for _ in 0..<2 {
            _ = withUnsafePointer(to: &dest) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        var found: [URL] = [], buf = [UInt8](repeating: 0, count: 4096)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { continue }
            if let u = location(in: String(decoding: buf[0..<n], as: UTF8.self)), !found.contains(u) { found.append(u) }
        }
        return found
    }

    /// Everything on the network that can play audio.
    static func renderers(timeout: TimeInterval = 2, http: HTTPClient = S3HTTP.shared) async -> [UPnPDevice] {
        let urls = search(timeout: timeout)
        var out: [UPnPDevice] = []
        for u in urls {
            var req = URLRequest(url: u); req.timeoutInterval = 4
            if let (d, status) = try? await http.send(req), status == 200, let dev = UPnPDevice.parse(xml: d, location: u), !out.contains(where: { $0.id == dev.id }) { out.append(dev) }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum SOAPError: LocalizedError {
    case fault(String)
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .fault(let m): "The speaker refused: \(m)"
        case .http(let s): "The speaker answered HTTP \(s)."
        }
    }
}

enum SOAP {
    static func envelope(service: String, action: String, args: [(String, String)]) -> Data {
        let body = args.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        return Data("""
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service)">\(body)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
    }

    @discardableResult
    static func call(_ http: HTTPClient, url: URL, service: String, action: String, _ args: [(String, String)] = []) async throws -> [String: String] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 8
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = envelope(service: service, action: action, args: args)
        let (d, status) = try await http.send(req)
        let root = XMLTree.parse(d)
        if status != 200 {
            if let f = root?.find("UPnPError") { throw SOAPError.fault("error \(f.child("errorCode")?.trimmed ?? "?") \(f.child("errorDescription")?.trimmed ?? "")") }
            throw SOAPError.http(status)
        }
        var out: [String: String] = [:]
        for n in root?.find("\(action)Response")?.children ?? [] { out[n.name] = n.trimmed }
        return out
    }

    /// Metadata a renderer shows (and some require) when given a URL.
    static func didl(title: String, url: String, contentType: String = "audio/flac") -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"aureon\" parentID=\"0\" restricted=\"1\"><dc:title>\(xmlEscape(title))</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(contentType):*\">\(xmlEscape(url))</res></item></DIDL-Lite>"
    }

    /// "0:01:23" or "0:01:23.456" → seconds; nil for NOT_IMPLEMENTED and the like.
    static func parseTime(_ s: String) -> (seconds: Double, exact: Bool)? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return (h * 3600 + m * 60 + sec, parts[2].contains("."))
    }
}

enum LocalNet {
    /// This Mac's address on the network that reaches `host` (what a speaker there needs to fetch our stream from).
    static func address(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var dest = sockaddr_in(); dest.sin_family = sa_family_t(AF_INET); dest.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, host, &dest.sin_addr) == 1 else { return nil }
        let ok = withUnsafePointer(to: &dest) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return nil }
        var me = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let r = withUnsafeMutablePointer(to: &me) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard r == 0 else { return nil }
        var a = me.sin_addr, buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}
