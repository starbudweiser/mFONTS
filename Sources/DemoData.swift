// mFONTS — données de démonstration (MFONTS_DEMO=1, avec un dossier personnel isolé : CFFIXED_USER_HOME).
// Bibliothèques faites des polices du système et collections aux noms neutres : sert aux captures publiques.
import Foundation
import CoreText

@MainActor
enum DemoData {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MFONTS_DEMO"] != nil }

    static func loadIfNeeded() {
        let c = Catalog.shared
        guard enabled, c.fonts.isEmpty else { return }
        let sys = "/System/Library/Fonts"
        // polices visibles seulement (les familles « .xxx » sont des polices internes du système)
        let dir = sys + "/Supplemental"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).map { URL(fileURLWithPath: dir + "/" + $0) }.filter { u in
            guard let ds = CTFontManagerCreateFontDescriptorsFromURL(u as CFURL) as? [CTFontDescriptor], let d = ds.first,
                  let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String else { return false }
            return !fam.hasPrefix(".")
        }
        _ = c.addFiles(files, library: LibRec(id: "demo-supplemental", name: "Mac Supplemental", color: "#2C9ED6"))
        func pick(_ families: [String]) -> [FontRec] { c.fonts.filter { families.contains($0.family) } }
        c.createCollection("Brand guidelines", adding: pick(["Futura", "Baskerville", "Avenir Next"]))
        c.createCollection("Editorial", adding: pick(["Georgia", "Didot", "Hoefler Text", "Charter"]))
        c.createCollection("Posters", adding: pick(["Impact", "Copperplate", "Rockwell", "Bodoni 72", "Herculanum", "Chalkduster", "Zapfino", "Trattatello", "Snell Roundhand", "Apple Chancery", "Futura", "Didot", "Phosphate", "Luminari", "Party LET", "Bradley Hand"]))
        c.createCollection("Web UI", adding: pick(["Helvetica Neue", "Verdana", "Trebuchet MS", "Gill Sans"]))
    
        if let posters = c.collections.first(where: { $0.name == "Posters" }) { c.selection = .collection(posters.id) }
    }
}
