// mFONTS — service d'arrière-plan : lancement à l'ouverture de session, sans fenêtre, dans la barre de menus.
// Agent de lancement utilisateur (SMAppService) : aucun droit administrateur, désactivable dans Réglages Système > Éléments de connexion.
import Foundation
import ServiceManagement

enum BackgroundService {
    static var plistName: String { (Bundle.main.bundleIdentifier ?? "fr.stephan.mfonts") + ".agent.plist" }
    static var service: SMAppService { SMAppService.agent(plistName: plistName) }

    static var isEnabled: Bool { service.status == .enabled }
    static var needsApproval: Bool { service.status == .requiresApproval }
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/" + plistName).path) }

    @discardableResult static func set(_ on: Bool) -> String? {
        do { if on { try service.register() } else { try service.unregister() }; return nil }
        catch { return error.localizedDescription }
    }
    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
