// mFONTS — pont local pour les extensions Adobe : petit serveur HTTP sur 127.0.0.1 (jeton obligatoire),
// décrit dans ~/Library/Application Support/<mFONTS>/bridge.json que lisent les extensions.
import Foundation
import Network

@MainActor
final class Bridge {
    static let shared = Bridge()
    private var listener: NWListener?
    private let token = UUID().uuidString + UUID().uuidString
    private var file: URL { Catalog.dataDir.appendingPathComponent("bridge.json") }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { c in Task { @MainActor in Bridge.shared.accept(c) } }
        l.stateUpdateHandler = { st in
            if case .ready = st, let p = l.port?.rawValue {
                Task { @MainActor in Bridge.shared.publish(port: p) }
            }
        }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel(); listener = nil
        try? FileManager.default.removeItem(at: file)
    }

    private func publish(port: UInt16) {
        let d = try? JSONSerialization.data(withJSONObject: ["port": Int(port), "token": token, "version": 1])
        try? d?.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: requêtes

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
            var buf = acc; if let data { buf.append(data) }
            Task { @MainActor in
                if let req = Self.parse(buf) { self.route(req, c) }
                else if done || err != nil || buf.count > 1_000_000 { c.cancel() }
                else { self.read(c, buf) }
            }
        }
    }

    struct Req { var method = "", path = "", headers: [String: String] = [:], body = Data() }

    nonisolated private static func parse(_ d: Data) -> Req? {
        guard let r = d.range(of: Data("\r\n\r\n".utf8)), let head = String(data: d[..<r.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var req = Req(method: String(first[0]), path: String(first[1]))
        for l in lines { if let i = l.firstIndex(of: ":") { req.headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
        let need = Int(req.headers["content-length"] ?? "0") ?? 0
        let body = d[r.upperBound...]
        guard body.count >= need else { return nil }
        req.body = Data(body.prefix(need))
        return req
    }

    private func reply(_ c: NWConnection, _ code: Int, _ obj: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        let status = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][code] ?? "Error"
        var out = Data("HTTP/1.1 \(code) \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func route(_ r: Req, _ c: NWConnection) {
        // Jeton obligatoire ; une page web (en-tête Origin http/https) n'a jamais accès.
        guard r.headers["authorization"] == "Bearer " + token, !(r.headers["origin"] ?? "").lowercased().hasPrefix("http") else { return reply(c, 401, ["error": "unauthorized"]) }
        switch (r.method, r.path) {
        case ("GET", "/v1/ping"): reply(c, 200, ["ok": true])
        case ("POST", "/v1/activate"):
            guard let j = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let p = j["path"] as? String, p.hasPrefix("/") else { return reply(c, 400, ["error": "path"]) }
            let url = URL(fileURLWithPath: p)
            guard DocFonts.extensions.contains(url.pathExtension.lowercased()), FileManager.default.fileExists(atPath: p) else { return reply(c, 400, ["error": "document"]) }
            AutoActivator.shared.activateFromPlugin(url, app: (j["app"] as? String) ?? "") { n, missing in
                self.reply(c, 200, ["activated": n, "missing": missing])
            }
        default: reply(c, 404, ["error": "not found"])
        }
    }
}
