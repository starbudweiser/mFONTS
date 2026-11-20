// mFONTS — téléchargement et installation automatique d'une famille : archive → polices → bibliothèque « Téléchargées » → activation.
import Foundation
import AppKit

struct DownloadItem: Identifiable {
    enum State { case downloading, unpacking, done(count: Int), failed(String) }
    let id = UUID()
    var name: String
    var source: String
    var license: String
    var state: State
    var fontIDs: [String] = []
    var activated = false
}

@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()
    @Published private(set) var items: [DownloadItem] = []
    @Published var caught: (file: URL, host: String)?           // fichier téléchargé dans le navigateur, en attente d'un clic

    static var libraryRec: LibRec { LibRec(id: "downloaded", name: L.t("lib.downloaded"), color: "#34d399") }
    static var folder: URL {
        let u = Catalog.dataDir.appendingPathComponent("Téléchargements"); try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    var running: Int { items.filter { if case .downloading = $0.state { return true }; if case .unpacking = $0.state { return true }; return false }.count }

    func isBusy(_ id: String) -> Bool { items.contains { $0.name == id && ($0.state.isRunning) } }

    // MARK: depuis une source à API

    func install(_ f: RemoteFamily) {
        let item = DownloadItem(name: f.name, source: f.portal, license: f.license, state: .downloading)
        items.insert(item, at: 0)
        let id = item.id
        Task {
            do {
                let (tmp, r) = try await URLSession.shared.download(from: f.download)
                guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                update(id) { $0.state = .unpacking }
                try await finish(id, file: tmp, suggestedName: f.slug + ".zip", family: f.name, source: f.portal, license: f.license, page: f.download)
            } catch { update(id) { $0.state = .failed(error.localizedDescription) } }
        }
    }

    // MARK: depuis le navigateur (fichier déjà téléchargé)

    func installCaught(_ file: URL, host: String) {
        let name = file.deletingPathExtension().lastPathComponent
        let item = DownloadItem(name: name, source: host, license: "mixed", state: .unpacking)
        items.insert(item, at: 0)
        let id = item.id
        caught = nil
        Task { do { try await finish(id, file: file, suggestedName: file.lastPathComponent, family: name, source: host, license: "mixed", page: nil) }
               catch { update(id) { $0.state = .failed(error.localizedDescription) } } }
    }

    // MARK: cœur

    func update(_ id: UUID, _ f: (inout DownloadItem) -> Void) { if let i = items.firstIndex(where: { $0.id == id }) { f(&items[i]) } }

    private func finish(_ id: UUID, file: URL, suggestedName: String, family: String, source: String, license: String, page: URL?) async throws {
        let safe = family.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dest = Self.folder.appendingPathComponent(safe, isDirectory: true)
        let found = try await Task.detached(priority: .userInitiated) { try Self.unpack(file, suggestedName: suggestedName, into: dest) }.value
        guard found > 0 else { throw NSError(domain: "mFONTS", code: 1, userInfo: [NSLocalizedDescriptionKey: L.t("find.dl.nofont")]) }
        var x = FontExtra(); x.license = L.t("lic." + license); x.licenseURL = page?.absoluteString ?? ""; x.notes = L.t("find.dl.source", source)
        let cat = Catalog.shared
        let n = cat.addFiles([dest], library: Self.libraryRec, extra: x)
        let ids = cat.fonts.filter { $0.path.hasPrefix(dest.path) }
        update(id) { $0.state = .done(count: n); $0.fontIDs = ids.map(\.id) }
        if UserDefaults.standard.object(forKey: "dlActivate") as? Bool ?? true, !ids.isEmpty {
            cat.setActive(ids, on: true)
            update(id) { $0.activated = true }
        }
    }

    /// Décompresse une archive (ou copie un fichier de police) et ne garde que les polices valides. Renvoie leur nombre.
    nonisolated private static func unpack(_ file: URL, suggestedName: String, into dest: URL) throws -> Int {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mfonts-dl-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let ext = (suggestedName as NSString).pathExtension.lowercased()
        let isZip = ext == "zip" || ((try? Data(contentsOf: file, options: .mappedIfSafe).prefix(4)) == Data([0x50, 0x4B, 0x03, 0x04]))
        if isZip {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-o", "-q", file.path, "-d", work.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 || p.terminationStatus == 1 else { throw URLError(.cannotDecodeContentData) }
        } else {
            try fm.copyItem(at: file, to: work.appendingPathComponent(suggestedName))
        }
        try? fm.removeItem(at: dest); try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var n = 0
        let root = work.resolvingSymlinksInPath().path
        for case let u as URL in fm.enumerator(at: work, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])! {
            guard u.resolvingSymlinksInPath().path.hasPrefix(root), ["ttf", "otf", "ttc", "otc"].contains(u.pathExtension.lowercased()),
                  (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }) ?? 0 < 60_000_000, isFontFile(u) else { continue }
            var target = dest.appendingPathComponent(u.lastPathComponent)
            if fm.fileExists(atPath: target.path) { target = dest.appendingPathComponent(UUID().uuidString.prefix(6) + "-" + u.lastPathComponent) }
            try fm.copyItem(at: u, to: target); n += 1
        }
        return n
    }

    /// Signature d'un vrai fichier de police (TrueType, OpenType, collection) : jamais un autre contenu renommé.
    nonisolated private static func isFontFile(_ u: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: u), let d = try? h.read(upToCount: 4) else { return false }
        try? h.close()
        return d == Data([0, 1, 0, 0]) || d == Data("OTTO".utf8) || d == Data("true".utf8) || d == Data("ttcf".utf8)
    }
}

extension DownloadItem.State {
    var isRunning: Bool { if case .downloading = self { return true }; if case .unpacking = self { return true }; return false }
}

extension Downloads {
    func activate(_ id: UUID) {
        guard let it = items.first(where: { $0.id == id }) else { return }
        let ids = Set(it.fontIDs)
        Catalog.shared.setActive(Catalog.shared.fonts.filter { ids.contains($0.id) }, on: true)
        update(id) { $0.activated = true }
    }
}
