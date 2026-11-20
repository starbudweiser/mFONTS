// mFONTS — modèle de données et catalogue en mémoire (SQLite sous ~/Library/Application Support).
import Foundation
import SwiftUI
import CoreText

struct FontRec: Identifiable, Hashable, Sendable {
    let id: String
    var lib: String
    var family: String
    var style: String
    var full: String
    var ps: String
    var path: String
    var type: String
    var designer: String
    var weight: Int
    var italic: Bool
    var enabled: Bool
    var starred: Bool
    var lastUsed: Double
    var url: URL { URL(fileURLWithPath: path) }
}

struct FontExtra: Sendable {
    var license = "", licenseURL = "", langs = "", notes = "", version = "", copyright = ""
}

struct LibRec: Identifiable, Hashable, Sendable { let id: String; var name: String; var color: String }
struct CollRec: Identifiable, Hashable, Sendable { let id: String; var name: String }
struct TagRec: Identifiable, Hashable, Sendable { let id: String; var name: String }

struct Family: Identifiable {
    let id: String
    let fonts: [FontRec]
    var rep: FontRec { fonts.first { $0.style.lowercased() == "regular" } ?? fonts.first { !$0.italic } ?? fonts[0] }
    var enabledCount: Int { fonts.filter(\.enabled).count }
    var allEnabled: Bool { enabledCount == fonts.count }
    var starred: Bool { fonts.contains(where: \.starred) }
    var libs: [String] { Array(Set(fonts.map(\.lib))) }
}

enum Sidebar: Hashable {
    case all, favorites, active, duplicates, recent
    case library(String), collection(String), tag(String)
}

@MainActor
final class Catalog: ObservableObject {
    static let shared = Catalog()

    @Published private(set) var fonts: [FontRec] = []
    @Published private(set) var libs: [LibRec] = []
    @Published private(set) var collections: [CollRec] = []
    @Published private(set) var tags: [TagRec] = []
    @Published private(set) var visible: [Family] = []
    @Published private(set) var counts: [String: Int] = [:]
    @Published var selection: Sidebar = .all { didSet { refresh() } }
    @Published var search = "" { didSet { refresh() } }
    @Published var selectedFamily: String?
    @Published var lastError: String?

    private(set) var collFonts: [String: Set<String>] = [:]
    private(set) var tagFonts: [String: Set<String>] = [:]
    private var dupPS: Set<String> = []
    private var db: DB!

    static var dataDir: URL {
        let name = (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "mFONTS"
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private init() {
        do {
            db = try DB(path: Self.dataDir.appendingPathComponent("mfonts.db").path)
            try db.exec("PRAGMA journal_mode=WAL")
            for sql in [
                "CREATE TABLE IF NOT EXISTS library(id TEXT PRIMARY KEY, name TEXT, color TEXT)",
                """
                CREATE TABLE IF NOT EXISTS font(id TEXT PRIMARY KEY, lib TEXT, family TEXT, style TEXT, full TEXT, ps TEXT, path TEXT,
                  type TEXT, designer TEXT, weight INT, italic INT, enabled INT DEFAULT 0, starred INT DEFAULT 0, lastUsed REAL DEFAULT 0,
                  license TEXT, licenseURL TEXT, langs TEXT, notes TEXT, version TEXT, copyright TEXT)
                """,
                "CREATE TABLE IF NOT EXISTS collection(id TEXT PRIMARY KEY, name TEXT)",
                "CREATE TABLE IF NOT EXISTS fontCollection(font TEXT, coll TEXT, PRIMARY KEY(font, coll))",
                "CREATE TABLE IF NOT EXISTS tag(id TEXT PRIMARY KEY, name TEXT)",
                "CREATE TABLE IF NOT EXISTS fontTag(font TEXT, tag TEXT, PRIMARY KEY(font, tag))",
            ] { try db.exec(sql) }
            reload()
        } catch { lastError = error.localizedDescription }
    }

    // MARK: chargement

    func reload() {
        var f: [FontRec] = []
        try? db.query("SELECT id,lib,family,style,full,ps,path,type,designer,weight,italic,enabled,starred,lastUsed FROM font") { r in
            f.append(FontRec(id: r.text(0), lib: r.text(1), family: r.text(2), style: r.text(3), full: r.text(4), ps: r.text(5), path: r.text(6),
                             type: r.text(7), designer: r.text(8), weight: r.int(9), italic: r.int(10) != 0, enabled: r.int(11) != 0,
                             starred: r.int(12) != 0, lastUsed: r.double(13)))
        }
        fonts = f
        var l: [LibRec] = []; try? db.query("SELECT id,name,color FROM library ORDER BY name COLLATE NOCASE") { l.append(LibRec(id: $0.text(0), name: $0.text(1), color: $0.text(2))) }
        libs = l
        var c: [CollRec] = []; try? db.query("SELECT id,name FROM collection ORDER BY name COLLATE NOCASE") { c.append(CollRec(id: $0.text(0), name: $0.text(1))) }
        collections = c
        var t: [TagRec] = []; try? db.query("SELECT id,name FROM tag ORDER BY name COLLATE NOCASE") { t.append(TagRec(id: $0.text(0), name: $0.text(1))) }
        tags = t
        collFonts = [:]; try? db.query("SELECT font,coll FROM fontCollection") { collFonts[$0.text(1), default: []].insert($0.text(0)) }
        tagFonts = [:]; try? db.query("SELECT font,tag FROM fontTag") { tagFonts[$0.text(1), default: []].insert($0.text(0)) }
        var seen: [String: Int] = [:]; for x in f { seen[x.ps, default: 0] += 1 }
        dupPS = Set(seen.filter { $0.value > 1 }.keys)
        refresh()
    }

    private func matches(_ f: FontRec) -> Bool {
        switch selection {
        case .all: return true
        case .favorites: return f.starred
        case .active: return f.enabled
        case .duplicates: return dupPS.contains(f.ps)
        case .recent: return f.lastUsed > 0
        case .library(let id): return f.lib == id
        case .collection(let id): return collFonts[id]?.contains(f.id) ?? false
        case .tag(let id): return tagFonts[id]?.contains(f.id) ?? false
        }
    }

    func refresh() {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var groups: [String: [FontRec]] = [:]
        for f in fonts where matches(f) {
            if !q.isEmpty, !(f.family.lowercased().contains(q) || f.full.lowercased().contains(q) || f.designer.lowercased().contains(q)) { continue }
            groups[f.family, default: []].append(f)
        }
        var fam = groups.map { Family(id: $0.key, fonts: $0.value.sorted { ($0.weight, $0.italic ? 1 : 0, $0.style) < ($1.weight, $1.italic ? 1 : 0, $1.style) }) }
        if selection == .recent { fam.sort { ($0.fonts.map(\.lastUsed).max() ?? 0) > ($1.fonts.map(\.lastUsed).max() ?? 0) } }
        else { fam.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending } }
        visible = fam
        var n: [String: Int] = ["all": fonts.count, "fav": 0, "act": 0, "dup": 0, "rec": 0]
        for f in fonts {
            n["lib:" + f.lib, default: 0] += 1
            if f.starred { n["fav", default: 0] += 1 }
            if f.enabled { n["act", default: 0] += 1 }
            if f.lastUsed > 0 { n["rec", default: 0] += 1 }
            if dupPS.contains(f.ps) { n["dup", default: 0] += 1 }
        }
        for (k, v) in collFonts { n["col:" + k] = v.count }
        for (k, v) in tagFonts { n["tag:" + k] = v.count }
        counts = n
    }

    var familyCount: Int { Set(fonts.map(\.family)).count }
    var activeCount: Int { counts["act"] ?? 0 }
    var recents: [FontRec] { Array(fonts.filter { $0.lastUsed > 0 }.sorted { $0.lastUsed > $1.lastUsed }.prefix(8)) }

    func libName(_ id: String) -> String { libs.first { $0.id == id }?.name ?? "" }
    func extra(_ id: String) -> FontExtra {
        var e = FontExtra()
        try? db.query("SELECT license,licenseURL,langs,notes,version,copyright FROM font WHERE id=?", [id]) {
            e = FontExtra(license: $0.text(0), licenseURL: $0.text(1), langs: $0.text(2), notes: $0.text(3), version: $0.text(4), copyright: $0.text(5))
        }
        return e
    }

    // MARK: actions

    func setActive(_ list: [FontRec], on: Bool) {
        let persistent = Prefs.persistent
        var failed = 0
        try? db.transaction {
            for f in list where f.enabled != on {
                if Activation.set(f, on: on, persistent: persistent) {
                    try? db.exec("UPDATE font SET enabled=?, lastUsed=? WHERE id=?", [on, on ? Date().timeIntervalSince1970 : f.lastUsed, f.id])
                } else { failed += 1 }
            }
        }
        if failed > 0 { lastError = L.t("err.activation", failed) }
        reload()
    }

    func deactivateAll() { setActive(fonts.filter(\.enabled), on: false) }

    func setStar(_ list: [FontRec], _ on: Bool) {
        try? db.transaction { for f in list { try? db.exec("UPDATE font SET starred=? WHERE id=?", [on, f.id]) } }
        reload()
    }

    func createCollection(_ name: String, adding list: [FontRec] = []) {
        let id = UUID().uuidString
        try? db.exec("INSERT INTO collection(id,name) VALUES(?,?)", [id, name])
        for f in list { try? db.exec("INSERT OR IGNORE INTO fontCollection(font,coll) VALUES(?,?)", [f.id, id]) }
        reload()
    }
    func renameCollection(_ id: String, _ name: String) { try? db.exec("UPDATE collection SET name=? WHERE id=?", [name, id]); reload() }
    func deleteCollection(_ id: String) {
        try? db.exec("DELETE FROM collection WHERE id=?", [id]); try? db.exec("DELETE FROM fontCollection WHERE coll=?", [id])
        if selection == .collection(id) { selection = .all }
        reload()
    }
    func add(_ list: [FontRec], toCollection id: String) {
        try? db.transaction { for f in list { try? db.exec("INSERT OR IGNORE INTO fontCollection(font,coll) VALUES(?,?)", [f.id, id]) } }
        reload()
    }
    func remove(_ list: [FontRec], fromCollection id: String) {
        try? db.transaction { for f in list { try? db.exec("DELETE FROM fontCollection WHERE font=? AND coll=?", [f.id, id]) } }
        reload()
    }
    func createTag(_ name: String, adding list: [FontRec] = []) {
        let id = tags.first { $0.name.lowercased() == name.lowercased() }?.id ?? UUID().uuidString
        try? db.exec("INSERT OR IGNORE INTO tag(id,name) VALUES(?,?)", [id, name])
        for f in list { try? db.exec("INSERT OR IGNORE INTO fontTag(font,tag) VALUES(?,?)", [f.id, id]) }
        reload()
    }
    func add(_ list: [FontRec], toTag id: String) {
        try? db.transaction { for f in list { try? db.exec("INSERT OR IGNORE INTO fontTag(font,tag) VALUES(?,?)", [f.id, id]) } }
        reload()
    }
    func remove(_ list: [FontRec], fromTag id: String) {
        try? db.transaction { for f in list { try? db.exec("DELETE FROM fontTag WHERE font=? AND tag=?", [f.id, id]) } }
        reload()
    }
    func fontTagsFor(_ f: FontRec) -> [TagRec] { tags.filter { tagFonts[$0.id]?.contains(f.id) ?? false } }
    func fontCollsFor(_ f: FontRec) -> [CollRec] { collections.filter { collFonts[$0.id]?.contains(f.id) ?? false } }

    // MARK: import

    func apply(_ p: ImportPayload, options o: ImportOptions) -> ImportReport {
        var rep = ImportReport()
        do {
            try db.transaction {
                for l in p.libs { try db.exec("INSERT INTO library(id,name,color) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name", [l.id, l.name, l.color]) }
                for f in p.fonts {
                    let x = p.extras[f.id] ?? FontExtra()
                    try db.exec("""
                        INSERT INTO font(id,lib,family,style,full,ps,path,type,designer,weight,italic,starred,license,licenseURL,langs,notes,version,copyright)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET lib=excluded.lib,family=excluded.family,style=excluded.style,full=excluded.full,ps=excluded.ps,
                          path=excluded.path,type=excluded.type,designer=excluded.designer,weight=excluded.weight,italic=excluded.italic,
                          license=excluded.license,licenseURL=excluded.licenseURL,langs=excluded.langs,notes=excluded.notes,version=excluded.version,copyright=excluded.copyright
                        """, [f.id, f.lib, f.family, f.style, f.full, f.ps, f.path, f.type, f.designer, f.weight, f.italic, f.starred,
                              x.license, x.licenseURL, x.langs, x.notes, x.version, x.copyright])
                    if o.favorites && f.starred { try db.exec("UPDATE font SET starred=1 WHERE id=?", [f.id]) }
                }
                for c in p.collections { try db.exec("INSERT INTO collection(id,name) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name", [c.id, c.name]) }
                for (fid, cid) in p.fontCollections { try db.exec("INSERT OR IGNORE INTO fontCollection(font,coll) VALUES(?,?)", [fid, cid]) }
                for t in p.tags { try db.exec("INSERT INTO tag(id,name) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name", [t.id, t.name]) }
                for (fid, tid) in p.fontTags { try db.exec("INSERT OR IGNORE INTO fontTag(font,tag) VALUES(?,?)", [fid, tid]) }
            }
        } catch { rep.errors.append(error.localizedDescription) }
        rep.fonts = p.fonts.count; rep.collections = p.collections.count; rep.tags = p.tags.count
        rep.skipped = p.skipped; rep.errors += p.errors
        reload()
        if o.activate {
            let want = fonts.filter { p.activeIDs.contains($0.id) && !$0.enabled }
            let ok = Activation.setMany(want, persistent: Prefs.persistent)
            try? db.transaction { for f in ok { try? db.exec("UPDATE font SET enabled=1 WHERE id=?", [f.id]) } }
            rep.activated = ok.count
            reload()
        }
        rep.duplicates = counts["dup"] ?? 0
        return rep
    }

    /// Ajoute des polices choisies à la main (fichiers ou dossiers).
    func addFiles(_ urls: [URL]) -> Int {
        var files: [URL] = []
        let exts: Set<String> = ["otf", "ttf", "ttc", "otc"]
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                if let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil) {
                    for case let x as URL in en where exts.contains(x.pathExtension.lowercased()) { files.append(x) }
                }
            } else if exts.contains(u.pathExtension.lowercased()) { files.append(u) }
        }
        let lib = LibRec(id: "local", name: L.t("lib.added"), color: "#2C9ED6")
        var recs: [FontRec] = []
        for u in files {
            guard let ds = CTFontManagerCreateFontDescriptorsFromURL(u as CFURL) as? [CTFontDescriptor] else { continue }
            for d in ds {
                let g: (CFString) -> String = { (CTFontDescriptorCopyAttribute(d, $0) as? String) ?? "" }
                let ps = g(kCTFontNameAttribute), fam = g(kCTFontFamilyNameAttribute)
                guard !ps.isEmpty, !fam.isEmpty else { continue }
                var st = g(kCTFontStyleNameAttribute); if st.isEmpty { st = "Regular" }
                let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any]
                let w = (traits?[kCTFontWeightTrait] as? Double) ?? 0
                let sym = (traits?[kCTFontSymbolicTrait] as? UInt32) ?? 0
                recs.append(FontRec(id: "local-" + ps, lib: lib.id, family: fam, style: st, full: g(kCTFontDisplayNameAttribute), ps: ps, path: u.path,
                                    type: u.pathExtension.uppercased(), designer: "", weight: Int(((w + 1) * 5).rounded()), italic: sym & UInt32(CTFontSymbolicTraits.traitItalic.rawValue) != 0,
                                    enabled: false, starred: false, lastUsed: 0))
            }
        }
        let payload = ImportPayload(libs: [lib], fonts: recs, extras: [:], collections: [], fontCollections: [], tags: [], fontTags: [], activeIDs: [], skipped: 0, errors: [])
        _ = apply(payload, options: ImportOptions())
        return recs.count
    }
}

enum Prefs {
    static var persistent: Bool { UserDefaults.standard.object(forKey: "persistentActivation") as? Bool ?? true }
    static var previewText: String { UserDefaults.standard.string(forKey: "previewText") ?? L.t("prefs.sample") }
    static var previewScale: Double { UserDefaults.standard.object(forKey: "previewScale") as? Double ?? 100 }
}
