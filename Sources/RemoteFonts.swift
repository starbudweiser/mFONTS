// mFONTS — sources de polices gratuites à API ouverte : Fontsource (dont Google Fonts), Fontshare, Font Squirrel.
// Index mis en cache 24 h ; aperçu réel chargé à la demande (un seul fichier par famille).
import Foundation
import CoreText
import SwiftUI

struct RemoteFamily: Identifiable, Hashable, Sendable {
    let id: String              // source:slug
    let source: String          // fontsource · fontshare · squirrel
    let portal: String          // nom affiché (Google Fonts, Fontsource, Fontshare, Font Squirrel)
    let slug: String
    let name: String
    let category: String        // serif · sans · script · mono · display · other
    let license: String         // ofl · commercial
    let styles: Int
    let download: URL
    let preview: URL?           // un fichier TTF de la famille (aperçu), s'il existe
    var key: String { FontIndex.compact(name) }
}

enum RemoteSource: String, CaseIterable, Sendable {
    case fontsource, fontshare, squirrel
    var title: String { ["fontsource": "Google Fonts · Fontsource", "fontshare": "Fontshare", "squirrel": "Font Squirrel"][rawValue]! }
    var prefKey: String { "src_" + rawValue }
    var enabled: Bool { UserDefaults.standard.object(forKey: prefKey) as? Bool ?? (self != .squirrel) }   // Font Squirrel : API protégée par un défi anti-robot, désactivée par défaut
}

@MainActor
final class RemoteCatalog: ObservableObject {
    static let shared = RemoteCatalog()
    @Published private(set) var families: [RemoteFamily] = []
    @Published private(set) var loading = false
    @Published private(set) var failed: Set<String> = []

    private var dir: URL { let u = Catalog.dataDir.appendingPathComponent("Remote"); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u }

    func load(force: Bool = false) {
        guard !loading else { return }
        loading = true; failed = []
        Task {
            var all: [RemoteFamily] = []
            for s in RemoteSource.allCases where s.enabled {
                if let f = await fetch(s, force: force) { all += f } else { failed.insert(s.rawValue) }
                families = all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            loading = false
        }
    }

    private func fetch(_ s: RemoteSource, force: Bool) async -> [RemoteFamily]? {
        let cache = dir.appendingPathComponent(s.rawValue + ".json")
        let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap { Date().timeIntervalSince($0) } ?? .infinity
        var data: Data? = (!force && age < 86_400) ? try? Data(contentsOf: cache) : nil
        if data == nil {
            let url = ["fontsource": "https://api.fontsource.org/v1/fonts", "fontshare": "https://api.fontshare.com/v2/fonts?limit=200", "squirrel": "https://www.fontsquirrel.com/api/fontlist/all"][s.rawValue]!
            var req = URLRequest(url: URL(string: url)!); req.timeoutInterval = 30
            req.setValue("mFONTS/" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1"), forHTTPHeaderField: "User-Agent")
            // Un portail peut répondre par un défi anti-robot (code 202, corps vide) : 3 essais espacés, sinon dernier index connu.
            for attempt in 0..<3 {
                if let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200, !d.isEmpty { data = d; try? d.write(to: cache, options: .atomic); break }
                if attempt < 2 { try? await Task.sleep(nanoseconds: 2_500_000_000) }
            }
            if data == nil { data = try? Data(contentsOf: cache) }       // hors ligne ou bloqué : dernier index connu
        }
        guard let data else { return nil }
        return await Task.detached { Self.parse(s, data) }.value
    }

    nonisolated static func category(_ c: String) -> String {
        let l = c.lowercased()
        if l.contains("mono") { return "mono" }
        if l.contains("sans") { return "sans" }
        if l.contains("serif") || l.contains("slab") { return "serif" }
        if l.contains("hand") || l.contains("script") || l.contains("brush") || l.contains("calli") { return "script" }
        if l.contains("display") || l.contains("decor") || l.contains("fancy") { return "display" }
        return "other"
    }

    nonisolated static func parse(_ s: RemoteSource, _ data: Data) -> [RemoteFamily] {
        var out: [RemoteFamily] = []
        switch s {
        case .fontsource:
            guard let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
            for d in a {
                guard let id = d["id"] as? String, let fam = d["family"] as? String else { continue }
                let weights = (d["weights"] as? [Int]) ?? [400], styles = (d["styles"] as? [String]) ?? ["normal"], subsets = (d["subsets"] as? [String]) ?? ["latin"]
                let w = weights.contains(400) ? 400 : (weights.first ?? 400)
                let st = styles.contains("normal") ? "normal" : (styles.first ?? "normal")
                let sub = subsets.contains("latin") ? "latin" : (subsets.first ?? "latin")
                let type = (d["type"] as? String) ?? "google"
                out.append(RemoteFamily(id: "fontsource:" + id, source: "fontsource", portal: type == "google" ? "Google Fonts" : "Fontsource", slug: id, name: fam,
                                        category: category((d["category"] as? String) ?? ""), license: "ofl", styles: max(1, weights.count * styles.count),
                                        download: URL(string: "https://api.fontsource.org/v1/download/" + id)!,
                                        preview: URL(string: "https://cdn.jsdelivr.net/fontsource/fonts/\(id)@latest/\(sub)-\(w)-\(st).ttf")))
            }
        case .fontshare:
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let a = o["fonts"] as? [[String: Any]] else { return [] }
            for d in a {
                guard let slug = d["slug"] as? String, let name = d["name"] as? String else { continue }
                out.append(RemoteFamily(id: "fontshare:" + slug, source: "fontshare", portal: "Fontshare", slug: slug, name: name, category: category((d["category"] as? String) ?? ""),
                                        license: "commercial", styles: max(1, (d["styles"] as? [Any])?.count ?? 1),
                                        download: URL(string: "https://api.fontshare.com/v2/fonts/download/" + slug)!, preview: nil))
            }
        case .squirrel:
            guard let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
            for d in a {
                guard let slug = d["family_urlname"] as? String, let name = d["family_name"] as? String else { continue }
                let n = Int((d["family_count"] as? String) ?? "") ?? (d["family_count"] as? Int) ?? 1
                out.append(RemoteFamily(id: "squirrel:" + slug, source: "squirrel", portal: "Font Squirrel", slug: slug, name: name, category: category((d["classification"] as? String) ?? ""),
                                        license: "commercial", styles: max(1, n), download: URL(string: "https://www.fontsquirrel.com/fonts/download/" + slug)!, preview: nil))
            }
        }
        return out
    }
}

/// Aperçu réel d'une famille distante : un fichier téléchargé en cache, rendu par CoreText sans activation.
@MainActor
enum RemotePreview {
    private static var cache: [String: CTFontDescriptor] = [:]
    private static var failed: Set<String> = []
    private static var inflight = 0

    static func font(for f: RemoteFamily, size: CGFloat) async -> Font? {
        guard let url = f.preview, !failed.contains(f.id) else { return nil }
        if let d = cache[f.id] { return Font(CTFontCreateWithFontDescriptor(d, size, nil)) }
        while inflight >= 6 { try? await Task.sleep(nanoseconds: 120_000_000) }      // pas plus de 6 aperçus à la fois
        inflight += 1; defer { inflight -= 1 }
        let dir = Catalog.dataDir.appendingPathComponent("Remote/previews"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(f.id.replacingOccurrences(of: ":", with: "_") + ".ttf")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let (tmp, r) = try? await URLSession.shared.download(from: url), (r as? HTTPURLResponse)?.statusCode == 200,
                  (try? FileManager.default.moveItem(at: tmp, to: file)) != nil else { failed.insert(f.id); return nil }
        }
        guard let ds = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor], let d = ds.first else { failed.insert(f.id); return nil }
        cache[f.id] = d
        return Font(CTFontCreateWithFontDescriptor(d, size, nil))
    }
}
