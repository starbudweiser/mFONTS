// mFONTS — installation des extensions Adobe (UXP) pour Photoshop et InDesign, sans Creative Cloud : copie dans le dossier
// utilisateur d'Adobe et inscription dans PluginsInfo, comme le font les plugins installés à la main.
import Foundation

struct AdobePlugin {
    let key: String          // clé de AutoActivator.watched
    let folder: String       // dossier dans Resources/plugins
    let id: String
    let code: String         // code d'appli UXP (nom du fichier de registre)
    let minVersion: String
    let version = "1.0.0"
}

@MainActor
enum PluginInstaller {
    static let all = [
        AdobePlugin(key: "adobe.photoshop", folder: "photoshop", id: "fr.stephan.mfonts.photoshop", code: "PS", minVersion: "23.3.0"),
        AdobePlugin(key: "adobe.indesign", folder: "indesign", id: "fr.stephan.mfonts.indesign", code: "ID", minVersion: "18.5.0"),
    ]
    static func plugin(for key: String) -> AdobePlugin? { all.first { $0.key == key } }

    private static var base: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MFONTS_UXP_BASE"] ?? (NSHomeDirectory() + "/Library/Application Support/Adobe/UXP")) }
    private static func dest(_ p: AdobePlugin) -> URL { base.appendingPathComponent("Plugins/External/\(p.id)_\(p.version)") }
    private static func registry(_ p: AdobePlugin) -> URL { base.appendingPathComponent("PluginsInfo/v1/\(p.code).json") }

    static func isInstalled(_ p: AdobePlugin) -> Bool {
        FileManager.default.fileExists(atPath: dest(p).appendingPathComponent("manifest.json").path)
    }
    static var anyInstalled: Bool { all.contains(where: isInstalled) }

    static func install(_ p: AdobePlugin) throws {
        let fm = FileManager.default
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("plugins") else { throw CocoaError(.fileNoSuchFile) }
        let src = res.appendingPathComponent(p.folder), core = res.appendingPathComponent("common/core.js")
        let ext = base.appendingPathComponent("Plugins/External")
        try fm.createDirectory(at: ext, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(atPath: ext.path)) ?? [] where old.hasPrefix(p.id + "_") { try? fm.removeItem(at: ext.appendingPathComponent(old)) }
        try fm.copyItem(at: src, to: dest(p))
        try fm.copyItem(at: core, to: dest(p).appendingPathComponent("core.js"))
        try register(p, add: true)
        Bridge.shared.start()
    }

    static func uninstall(_ p: AdobePlugin) {
        try? FileManager.default.removeItem(at: dest(p))
        try? register(p, add: false)
        if !anyInstalled { Bridge.shared.stop() }
    }

    private static func register(_ p: AdobePlugin, add: Bool) throws {
        let fm = FileManager.default, f = registry(p)
        try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        var root = ((try? Data(contentsOf: f)).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        var list = (root["plugins"] as? [[String: Any]] ?? []).filter { ($0["pluginId"] as? String) != p.id }
        if add {
            list.append(["hostMinVersion": p.minVersion, "name": "mFONTS", "path": "$localPlugins/External/\(p.id)_\(p.version)",
                         "pluginId": p.id, "status": "enabled", "type": "uxp", "versionString": p.version])
        }
        root["plugins"] = list
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: f, options: .atomic)
    }
}
