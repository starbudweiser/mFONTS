// mFONTS — import depuis Right Fonts : bibliothèques (.rightfontlibrary), collections et étiquettes (core-v10.db), préférences.
// Les sources de Right Fonts ne sont jamais modifiées ; les polices sont référencées à leur emplacement.
import Foundation

struct RFLibrary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let count: Int
}

struct ImportOptions: Sendable {
    var libs: Set<String> = []
    var collections = true, tags = true, favorites = true, activate = true, prefs = true
}

struct ImportPayload: Sendable {
    var libs: [LibRec]
    var fonts: [FontRec]
    var extras: [String: FontExtra]
    var collections: [CollRec]
    var fontCollections: [(String, String)]
    var tags: [TagRec]
    var fontTags: [(String, String)]
    var activeIDs: Set<String>
    var skipped: Int
    var errors: [String]
}

struct ImportReport: Sendable {
    var fonts = 0, skipped = 0, collections = 0, tags = 0, activated = 0, duplicates = 0
    var errors: [String] = []
}

enum RightFontImporter {
    static let candidates = [
        "/Volumes/OWC 6To/RESSOURCES/GFX/FONTS/Libraries",
        NSHomeDirectory() + "/RightFont",
    ]
    static let coreDB = NSHomeDirectory() + "/Library/Application Support/RightFont/Data/core-v10.db"
    static let palette = ["#f59e0b", "#38bdf8", "#a78bfa", "#34d399", "#f472b6", "#fb923c", "#94a3b8", "#facc15", "#2dd4bf", "#f87171"]

    static func defaultFolder() -> URL? {
        candidates.map { URL(fileURLWithPath: $0) }.first { !detect(in: $0).isEmpty }
    }

    /// Les bibliothèques Right Fonts d'un dossier (dossier contenant les .rightfontlibrary, ou une bibliothèque seule).
    static func detect(in folder: URL) -> [RFLibrary] {
        let fm = FileManager.default
        var dirs: [URL] = []
        if folder.pathExtension == "rightfontlibrary" { dirs = [folder] }
        else { dirs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "rightfontlibrary" } }
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("manifest.rightfontmetadata")),
                  let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = m["uuid"] as? String else { return nil }
            let name = (m["name"] as? String) ?? d.deletingPathExtension().lastPathComponent
            let n = ((try? fm.contentsOfDirectory(atPath: d.appendingPathComponent("metadata/fonts").path)) ?? []).count
            return RFLibrary(id: id, name: name, url: d, count: n)
        }.sorted { $0.count > $1.count }
    }

    /// Lecture complète, hors du fil principal.
    static func read(_ libs: [RFLibrary], options o: ImportOptions, progress: @Sendable (Double, String) -> Void) -> ImportPayload {
        var p = ImportPayload(libs: [], fonts: [], extras: [:], collections: [], fontCollections: [], tags: [], fontTags: [], activeIDs: [], skipped: 0, errors: [])
        let fm = FileManager.default
        let chosen = libs.filter { o.libs.contains($0.id) }
        let total = max(1, chosen.reduce(0) { $0 + $1.count })
        var done = 0
        var fontIDs = Set<String>()
        for (i, lib) in chosen.enumerated() {
            p.libs.append(LibRec(id: lib.id, name: lib.name, color: palette[i % palette.count]))
            let dir = lib.url.appendingPathComponent("metadata/fonts")
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "rightfontmetadata" }
            for f in files {
                done += 1
                if done % 100 == 0 { progress(Double(done) / Double(total), lib.name) }
                guard let data = try? Data(contentsOf: f), let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let uuid = d["uuid"] as? String, let loc = d["location"] as? String, let family = d["family"] as? String else { p.skipped += 1; continue }
                let path = lib.url.appendingPathComponent("fonts/" + loc).path
                let style = (d["style"] as? String) ?? "Regular"
                let rec = FontRec(id: uuid, lib: lib.id, family: family, style: style, full: (d["fullName"] as? String) ?? family + " " + style,
                                  ps: (d["postscriptName"] as? String) ?? uuid, path: path, type: (d["fileType"] as? String) ?? "",
                                  designer: (d["designer"] as? String) ?? "", weight: (d["weight"] as? Int) ?? 5,
                                  italic: (d["isItalicStyle"] as? Bool) ?? false, enabled: false, starred: (d["starred"] as? Bool) ?? false, lastUsed: 0)
                p.fonts.append(rec); fontIDs.insert(uuid)
                p.extras[uuid] = FontExtra(license: (d["license"] as? String) ?? "", licenseURL: (d["licenseURL"] as? String) ?? "",
                                           langs: (d["supportedLanguages"] as? String) ?? "", notes: (d["notes"] as? String) ?? "",
                                           version: (d["version"] as? String) ?? "", copyright: (d["copyright"] as? String) ?? "")
            }
        }
        progress(0.9, "Right Fonts")
        // Base de Right Fonts : copiée (avec son journal) pour être lue sans rien toucher à l'original.
        if (o.collections || o.tags || o.activate), fm.fileExists(atPath: coreDB) {
            let tmp = fm.temporaryDirectory.appendingPathComponent("mfonts-rf-" + UUID().uuidString)
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            for ext in ["", "-wal", "-shm"] { try? fm.copyItem(atPath: coreDB + ext, toPath: tmp.appendingPathComponent("core-v10.db" + ext).path) }
            do {
                let db = try DB(path: tmp.appendingPathComponent("core-v10.db").path, readOnly: true)
                let libIDs = Set(chosen.map(\.id))
                if o.collections {
                    var cids = Set<String>()
                    try db.query("SELECT id,library_id,name FROM collection WHERE deleted=0 AND type=0") { r in
                        if libIDs.contains(r.text(1)) { p.collections.append(CollRec(id: r.text(0), name: r.text(2))); cids.insert(r.text(0)) }
                    }
                    try db.query("SELECT font_id,collection_id FROM fontCollection") { r in
                        if cids.contains(r.text(1)), fontIDs.contains(r.text(0)) { p.fontCollections.append((r.text(0), r.text(1))) }
                    }
                }
                if o.tags {
                    var tids = Set<String>()
                    try db.query("SELECT id,name FROM tag WHERE deleted=0 AND type=1") { r in p.tags.append(TagRec(id: r.text(0), name: r.text(1))); tids.insert(r.text(0)) }
                    try db.query("SELECT font_id,tag_id FROM fontTag") { r in
                        if tids.contains(r.text(1)), fontIDs.contains(r.text(0)) { p.fontTags.append((r.text(0), r.text(1))) }
                    }
                    let used = Set(p.fontTags.map(\.1)); p.tags = p.tags.filter { used.contains($0.id) }
                }
                if o.activate {
                    try db.query("SELECT id FROM font WHERE enabled=1 AND deleted=0") { r in if fontIDs.contains(r.text(0)) { p.activeIDs.insert(r.text(0)) } }
                }
            } catch { p.errors.append("Right Fonts : " + error.localizedDescription) }
        }
        if o.prefs, let rf = UserDefaults.standard.persistentDomain(forName: "com.rightfontapp.RightFont5") {
            if let s = rf["FontPreviewStyleFontSize"] as? Double ?? (rf["FontPreviewStyleFontSize"] as? Int).map(Double.init) { UserDefaults.standard.set(s, forKey: "previewScale") }
            if let v = rf["FontPreviewStyleViewType"] as? Int { UserDefaults.standard.set(v != 2, forKey: "viewGrid") }
        }
        progress(1, "")
        return p
    }
}
