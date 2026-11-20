// mFONTS — lecture des polices demandées par un document (Pages, PSD, PDF, DOCX…) et correspondance avec le catalogue.
import Foundation
import AppKit

/// Résultat d'une analyse : polices du catalogue à activer, noms introuvables.
struct DocFontResult: Sendable {
    var ids: [String] = []          // polices du catalogue demandées par le document
    var missing: [String] = []      // noms cités explicitement mais absents du catalogue et du système
}

/// Index de recherche du catalogue : nom compact (minuscules, sans espace ni tiret) → polices.
struct FontIndex: Sendable {
    var byPS: [String: [String]] = [:]       // PostScript et nom complet → une police
    var byFamily: [String: [String]] = [:]   // famille → tous ses styles
    var enabled: Set<String> = []

    static func compact(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    init(_ fonts: [FontRec]) {
        for f in fonts {
            byPS[Self.compact(f.ps), default: []].append(f.id)
            byPS[Self.compact(f.full), default: []].append(f.id)
            byFamily[Self.compact(f.family), default: []].append(f.id)
            if f.enabled { enabled.insert(f.id) }
        }
    }
}

enum DocFonts {
    static let extensions: Set<String> = ["psd", "psb", "ai", "indd", "idml", "pdf", "eps", "pages", "key", "numbers", "docx", "pptx", "xlsx", "aep", "aepx", "sketch", "svg", "odt", "rtf", "prproj", "mogrt", "drp", "comp", "setting"]
    private static let maxBytes = 400 * 1024 * 1024

    /// Noms de polices que cite un document, par format.
    /// - Returns: (noms certains : attributs de police ; noms possibles : chaînes de texte brut du fichier).
    static func names(in url: URL) -> (explicit: Set<String>, loose: Set<String>) {
        var explicit = Set<String>(), loose = Set<String>()
        let ext = url.pathExtension.lowercased()
        var chunks: [(Data, Bool)] = []                  // (contenu, c'est du XML/texte à attributs)
        if ["docx", "pptx", "xlsx", "idml", "odt", "sketch", "drp", "mogrt"].contains(ext) || isZip(url) && !["pages", "key", "numbers"].contains(ext) {
            for e in zipEntries(url) where isTextEntry(e) { if let d = zipRead(url, e) { chunks.append((d, true)) } }
        } else if ["pages", "key", "numbers"].contains(ext) {
            if isDirectory(url) {
                for f in walk(url) {
                    if f.pathExtension == "zip" {       // paquet iWork : Index.zip contient les .iwa
                        for e in zipEntries(f) { guard let d = zipRead(f, e) else { continue }
                            if e.hasSuffix(".iwa") { chunks.append((iwaDecode(d), false)) } else if isTextEntry(e) { chunks.append((d, true)) } }
                    } else if let d = readLimited(f) { chunks.append(f.pathExtension == "iwa" ? (iwaDecode(d), false) : (d, true)) }
                }
            } else {
                for e in zipEntries(url) {
                    guard let d = zipRead(url, e) else { continue }
                    if e.hasSuffix(".iwa") { chunks.append((iwaDecode(d), false)) } else if isTextEntry(e) { chunks.append((d, true)) }
                }
            }
        } else if ext == "prproj", let d = gunzip(url) {
            chunks.append((d, true))
        } else if let d = readLimited(url) {
            chunks.append((d, ["comp", "setting"].contains(ext)))
        }
        for (d, xml) in chunks {
            if xml { for n in xmlFontNames(d) { explicit.insert(n) } }
            for r in textRuns(d) { loose.insert(r) }
        }
        return (explicit, loose)
    }

    /// Analyse complète : noms → polices du catalogue.
    static func resolve(_ url: URL, index: FontIndex, systemNames: Set<String>) -> DocFontResult {
        let (explicit, loose) = names(in: url)
        var out = DocFontResult()
        var seen = Set<String>()
        func take(_ ids: [String]) { for id in ids where seen.insert(id).inserted { out.ids.append(id) } }
        func lookup(_ raw: String, family: Bool) -> Bool {
            var found = false
            for cand in variants(raw) {
                let k = FontIndex.compact(cand)
                guard k.count >= (family ? 4 : 6) else { continue }
                if systemNames.contains(k) { found = true; continue }      // le système fournit déjà cette police
                if let ids = index.byPS[k] { take(ids); found = true }
                else if family, let ids = index.byFamily[k] { take(ids); found = true }
            }
            return found
        }
        for n in explicit {
            if !lookup(n, family: true) {
                let k = FontIndex.compact(n)
                if !systemNames.contains(k), n.count >= 3, !genericNames.contains(k) { out.missing.append(n) }
            }
        }
        for n in loose where !explicit.contains(n) { _ = lookup(n, family: false) }
        out.missing = Array(Set(out.missing)).sorted()
        return out
    }

    static let genericNames: Set<String> = ["", "default", "theme", "minorhaenfonttheme", "majorhaenfonttheme", "times", "timesnewroman", "symbol", "unknown", "none", "auto", "inherit", "serif", "sansserif", "monospace", "cursive", "fantasy", "systemui", "applesystem", "sfpro", "sfprotext", "sfprodisplay", "helveticaneue"]

    /// Noms de police des fontes que le système connaît déjà (famille et PostScript, forme compacte).
    @MainActor static func systemFontNames() -> Set<String> {
        var s = Set<String>()
        for f in NSFontManager.shared.availableFontFamilies { s.insert(FontIndex.compact(f)) }
        for f in NSFontManager.shared.availableFonts { s.insert(FontIndex.compact(f)) }
        return s
    }

    // MARK: extraction

    /// Variantes d'un nom : sans préfixe de sous-ensemble PDF (« ABCDEF+Nom »), sans « #20 », sans suffixe de style.
    private static func variants(_ raw: String) -> [String] {
        var s = raw.replacingOccurrences(of: "#20", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 7, s[s.index(s.startIndex, offsetBy: 6)] == "+", s.prefix(6).allSatisfy({ $0.isUppercase }) { s = String(s.dropFirst(7)) }
        var v = [s]
        if let i = s.firstIndex(of: ",") { v.append(String(s[..<i])) }
        return v
    }

    /// Valeurs des attributs de police dans du XML (DOCX, PPTX, IDML, XLSX, SVG, ODT, XML iWork).
    private static let attrRegex: NSRegularExpression = {
        let keys = ["typeface", "w:ascii", "w:hAnsi", "w:cs", "w:eastAsia", "w:name", "AppliedFont", "PostScriptName", "FontName", "FontFamily", "font-family", "style:font-name", "fo:font-family", "face", "val", "Font"]
        let pat = "(?:" + keys.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\s*[=:]\\s*[\"']?([^\"'<>;,]{3,80})"
        return try! NSRegularExpression(pattern: pat)
    }()

    private static func xmlFontNames(_ d: Data) -> [String] {
        guard let s = String(data: d.prefix(8_000_000), encoding: .utf8) ?? String(data: d.prefix(8_000_000), encoding: .isoLatin1) else { return [] }
        var out: [String] = []
        let ns = s as NSString
        // « val » n'est pris que dans <name val="…"> (styles Excel) pour éviter les valeurs numériques ou de couleur.
        attrRegex.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 1 else { return }
            let whole = ns.substring(with: m.range)
            let v = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if whole.hasPrefix("val") { if m.range.location >= 6, ns.substring(with: NSRange(location: m.range.location - 6, length: 6)) == "<name " { out.append(v) }; return }
            if v.first == "+" || v.hasPrefix("#") || v.allSatisfy({ $0.isNumber }) { return }
            out.append(v)
        }
        return out
    }

    /// Suites de caractères de nom (lettres, chiffres, espace, - _ . + #) : ASCII, UTF-16 (zéros retirés) ou protobuf.
    private static func textRuns(_ d: Data) -> Set<String> {
        var out = Set<String>()
        var cur = [UInt8]()
        cur.reserveCapacity(96)
        func flush() {
            if cur.count >= 3, cur.count <= 80, let s = String(bytes: cur, encoding: .ascii) {
                let t = s.trimmingCharacters(in: .whitespaces)
                if t.count >= 3 { out.insert(t) }
            }
            cur.removeAll(keepingCapacity: true)
        }
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p {
                if b == 0 { continue }                       // UTF-16 : on ignore les octets nuls
                let ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 32 || b == 45 || b == 95 || b == 46 || b == 43 || b == 35
                if ok { if cur.count < 90 { cur.append(b) } else { cur.removeAll(keepingCapacity: true) } } else { flush() }
            }
            flush()
        }
        return out
    }

    // MARK: fichiers

    private static func readLimited(_ u: URL) -> Data? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path), (a[.size] as? Int ?? 0) < maxBytes else { return nil }
        return try? Data(contentsOf: u, options: .mappedIfSafe)
    }
    private static func isDirectory(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    private static func isZip(_ u: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }
    private static func walk(_ u: URL) -> [URL] {
        (FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { !isDirectory($0) }
    }
    private static func isTextEntry(_ e: String) -> Bool {
        let l = e.lowercased()
        return l.hasSuffix(".xml") || l.hasSuffix(".rels") || l.hasSuffix(".json") || l.hasSuffix(".svg") || l.hasSuffix(".fnt")
    }

    private static func gunzip(_ u: URL) -> Data? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip"); p.arguments = ["-c", u.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return d.isEmpty ? nil : d
    }

    private static func run(_ args: [String]) -> Data? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return d
    }
    private static func zipEntries(_ u: URL) -> [String] {
        guard let d = run(["-Z1", u.path]), let s = String(data: d, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init)
    }
    private static func zipRead(_ u: URL, _ entry: String) -> Data? {
        guard let d = run(["-p", u.path, entry]), d.count < maxBytes else { return nil }
        return d
    }

    // MARK: iWork (.iwa : blocs Snappy sans en-tête de flux)

    static func iwaDecode(_ d: Data) -> Data {
        var out = Data()
        let b = [UInt8](d)
        var i = 0
        while i + 4 <= b.count {
            guard b[i] == 0 else { break }
            let len = Int(b[i + 1]) | Int(b[i + 2]) << 8 | Int(b[i + 3]) << 16
            i += 4
            guard len > 0, i + len <= b.count else { break }
            out.append(snappy(b, i, i + len))
            i += len
        }
        return out
    }

    private static func snappy(_ b: [UInt8], _ start: Int, _ end: Int) -> Data {
        var i = start, n = 0, shift = 0
        while i < end { let c = Int(b[i]); i += 1; n |= (c & 0x7F) << shift; if c & 0x80 == 0 { break }; shift += 7 }
        var o = [UInt8](); o.reserveCapacity(min(n, 64_000_000))
        while i < end {
            let tag = b[i]; i += 1
            switch tag & 3 {
            case 0:
                var l = Int(tag >> 2)
                if l >= 60 { let k = l - 59; l = 0; for j in 0..<k where i + j < end { l |= Int(b[i + j]) << (8 * j) }; i += k }
                l += 1
                guard i + l <= end else { return Data(o) }
                o.append(contentsOf: b[i..<(i + l)]); i += l
            case 1:
                guard i < end else { return Data(o) }
                let l = Int((tag >> 2) & 7) + 4, off = Int(tag >> 5) << 8 | Int(b[i]); i += 1
                copy(&o, off, l)
            case 2:
                guard i + 2 <= end else { return Data(o) }
                let l = Int(tag >> 2) + 1, off = Int(b[i]) | Int(b[i + 1]) << 8; i += 2
                copy(&o, off, l)
            default:
                guard i + 4 <= end else { return Data(o) }
                let l = Int(tag >> 2) + 1, off = Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24; i += 4
                copy(&o, off, l)
            }
        }
        return Data(o)
    }

    private static func copy(_ o: inout [UInt8], _ off: Int, _ len: Int) {
        guard off > 0, off <= o.count else { return }
        var s = o.count - off
        for _ in 0..<len { o.append(o[s]); s += 1 }
    }
}
