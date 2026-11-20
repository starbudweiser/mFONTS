// mFONTS — activation à la demande : « Ouvrir via mFONTS », surveillance des documents ouverts, notification.
import Foundation
import AppKit
import ApplicationServices
import UserNotifications

@MainActor
final class AutoActivator {
    static let shared = AutoActivator()

    /// Applis surveillées (morceau du identifiant de paquet → nom affiché).
    static let watched: [(key: String, name: String)] = [
        ("iwork.pages", "Pages"), ("iwork.keynote", "Keynote"), ("iwork.numbers", "Numbers"),
        ("adobe.photoshop", "Photoshop"), ("adobe.illustrator", "Illustrator"), ("adobe.indesign", "InDesign"),
        ("adobe.aftereffects", "After Effects"), ("adobe.premierepro", "Premiere Pro"),
        ("microsoft.word", "Word"), ("microsoft.powerpoint", "PowerPoint"), ("microsoft.excel", "Excel"),
        ("blackmagic", "DaVinci Resolve"), ("bohemiancoding.sketch", "Sketch"),
    ]

    private var timer: Timer?
    private var seen: [String: Date] = [:]          // chemin → date de modification déjà analysée
    private var notifAsked = false

    static var watchEnabled: Bool { !(UserDefaults.standard.stringArray(forKey: "autoApps") ?? []).isEmpty }
    static var notifyMode: String { UserDefaults.standard.string(forKey: "autoNotify") ?? "missing" }

    // MARK: ouvrir via mFONTS

    /// Active les polices du document puis l'ouvre dans l'application qui le gère d'habitude.
    func openViaMFonts(_ urls: [URL]) {
        for url in urls {
            let target = NSWorkspace.shared.urlsForApplications(toOpen: url).first { Bundle(url: $0)?.bundleIdentifier != Bundle.main.bundleIdentifier }
            let appName = target.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? ""
            Catalog.shared.activateFor(document: url, app: appName) { [weak self] n, missing in
                self?.whenIdle {
                    if let target {
                        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
                        NSWorkspace.shared.open([url], withApplicationAt: target, configuration: cfg)
                    } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    self?.notify(doc: url.lastPathComponent, activated: n, missing: missing)
                }
            }
        }
    }

    /// Choisir un document à ouvrir via mFONTS (menu Fichier).
    func chooseDocument() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        if p.runModal() == .OK { openViaMFonts(p.urls) }
    }

    private func whenIdle(_ block: @escaping () -> Void) {
        if Catalog.shared.activating == nil { block() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.whenIdle(block) } }
    }

    // MARK: surveillance

    func applyWatch() {
        timer?.invalidate(); timer = nil
        guard Self.watchEnabled else { return }
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in AutoActivator.shared.scan() } }
    }

    private func scan() {
        guard AXIsProcessTrusted() else { return }
        let enabledKeys = Set(UserDefaults.standard.stringArray(forKey: "autoApps") ?? [])
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier?.lowercased(), let w = Self.watched.first(where: { id.contains($0.key) }), enabledKeys.contains(w.key) else { continue }
            for url in documents(of: app) { analyse(url, app: w.name) }
        }
    }

    /// Fichiers des fenêtres ouvertes d'une appli (attribut AXDocument).
    private func documents(of app: NSRunningApplication) -> [URL] {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &ref) == .success, let wins = ref as? [AXUIElement] else { return [] }
        var out: [URL] = []
        for w in wins {
            var d: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXDocumentAttribute as CFString, &d) == .success, let s = d as? String, let u = URL(string: s), u.isFileURL { out.append(u) }
        }
        return out
    }

    private func analyse(_ url: URL, app: String) {
        guard DocFonts.extensions.contains(url.pathExtension.lowercased()) else { return }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let s = seen[url.path], s >= mod { return }
        seen[url.path] = mod
        Catalog.shared.activateFor(document: url, app: app) { [weak self] n, missing in self?.notify(doc: url.lastPathComponent, activated: n, missing: missing) }
    }

    // MARK: notification

    private func notify(doc: String, activated: Int, missing: [String]) {
        let mode = Self.notifyMode
        guard mode != "never", activated > 0 && mode == "always" || !missing.isEmpty else { return }
        let c = UNUserNotificationCenter.current()
        if !notifAsked { notifAsked = true; c.requestAuthorization(options: [.alert]) { _, _ in } }
        let m = UNMutableNotificationContent()
        m.title = L.t("auto.notif.title", activated)
        var body = L.t("auto.notif.doc", doc)
        if !missing.isEmpty { body += "\n" + L.t("auto.notif.missing", missing.prefix(4).joined(separator: ", ") + (missing.count > 4 ? "…" : "")) }
        m.body = body
        c.add(UNNotificationRequest(identifier: UUID().uuidString, content: m, trigger: nil))
    }
}
