// mFONTS — activation des polices (CoreText) et création des polices d'aperçu sans les activer.
import Foundation
import CoreText
import SwiftUI

enum Activation {
    static func set(_ f: FontRec, on: Bool, persistent: Bool) -> Bool {
        var err: Unmanaged<CFError>?
        let scope: CTFontManagerScope = persistent ? .persistent : .session
        let ok = on ? CTFontManagerRegisterFontsForURL(f.url as CFURL, scope, &err) : CTFontManagerUnregisterFontsForURL(f.url as CFURL, scope, &err)
        if ok { return true }
        let code = (err?.takeRetainedValue() as Error? as NSError?)?.code ?? 0
        return code == 105 || code == 201          // déjà activée / déjà désactivée
    }

    /// Activation en lot ; renvoie les polices réellement actives.
    static func setMany(_ list: [FontRec], persistent: Bool) -> [FontRec] {
        list.filter { set($0, on: true, persistent: persistent) }
    }
}

/// Polices d'aperçu créées depuis le fichier, sans activation.
@MainActor
enum FontCache {
    private static var cache: [String: CTFontDescriptor] = [:]
    private static var missing: Set<String> = []

    static func exists(_ f: FontRec) -> Bool { descriptor(f) != nil }

    private static func descriptor(_ f: FontRec) -> CTFontDescriptor? {
        if let d = cache[f.id] { return d }
        if missing.contains(f.id) { return nil }
        guard let ds = CTFontManagerCreateFontDescriptorsFromURL(f.url as CFURL) as? [CTFontDescriptor], !ds.isEmpty else { missing.insert(f.id); return nil }
        let d = ds.first { (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String) == f.ps } ?? ds[0]
        cache[f.id] = d
        return d
    }

    static func font(_ f: FontRec, size: CGFloat) -> Font {
        guard let d = descriptor(f) else { return .system(size: size) }
        return Font(CTFontCreateWithFontDescriptor(d, size, nil))
    }

    static func nsFont(_ f: FontRec, size: CGFloat) -> NSFont {
        guard let d = descriptor(f) else { return .systemFont(ofSize: size) }
        return unsafeBitCast(CTFontCreateWithFontDescriptor(d, size, nil), to: NSFont.self)
    }

    static func reset() { cache = [:]; missing = [] }
}
