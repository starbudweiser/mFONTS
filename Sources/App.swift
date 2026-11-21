// mFONTS — point d'entrée : fenêtre principale, menus, icône de barre de menus, présence Dock / barre.
import SwiftUI
import AppKit
import WebKit

@main
struct MFontsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!
    var window: NSWindow?
    var settingsWindow: NSWindow?
    var statusItem: NSStatusItem?
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        Self.shared = self
        if CommandLine.arguments.contains("--selftest-import") { selfTest(); return }
        DemoData.loadIfNeeded()
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-settings"), i + 1 < CommandLine.arguments.count {
            let dir = CommandLine.arguments[i + 1]
            for t in SettingsTab.allCases {
                let r = ImageRenderer(content: SettingsView(tab: t, scrolling: false).environment(\.colorScheme, .dark).background(Color.black))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir + "/settings-\(t.rawValue).png"))
                }
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-find") {
            let want = Array(CommandLine.arguments.dropFirst(i + 1))
            Task { @MainActor in
                let r = RemoteCatalog.shared; r.load(force: true)
                while r.loading || r.families.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
                var by: [String: Int] = [:]; for f in r.families { by[f.source, default: 0] += 1 }
                print("index :", by, "· échecs", r.failed)
                for w in want {
                    guard let f = r.families.first(where: { $0.name.lowercased() == w.lowercased() }) else { print("introuvable :", w); continue }
                    Downloads.shared.install(f)
                }
                while Downloads.shared.running > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                for it in Downloads.shared.items { print(it.name, "·", it.source, "→", it.state, "· activée", it.activated, "·", it.fontIDs.count, "ids") }
                print("polices du catalogue après :", Catalog.shared.fonts.filter { $0.lib == "downloaded" }.map { $0.ps })
                exit(0)
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-web"), i + 1 < CommandLine.arguments.count, let u = URL(string: CommandLine.arguments[i + 1]) {
            NSApp.setActivationPolicy(.accessory)
            let h = WebHandle()
            let host = NSHostingView(rootView: PortalWebView(url: u, portalID: "selftest", handle: h) { f, hst in print("capté :", f.lastPathComponent, "depuis", hst); Downloads.shared.installCaught(f, host: hst) }.frame(width: 600, height: 400))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = host; w.orderBack(nil)
            Task { @MainActor in
                for _ in 0..<40 { try? await Task.sleep(nanoseconds: 500_000_000); if Downloads.shared.items.first.map({ !$0.state.isRunning }) == true { break } }
                for it in Downloads.shared.items { print(it.name, "→", it.state) }
                print("polices :", Catalog.shared.fonts.filter { $0.lib == "downloaded" }.map(\.ps))
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--selftest-login") {
            // Page de connexion simulée (origine https sans réseau) : capture, bandeau, enregistrement Trousseau, remplissage.
            NSApp.setActivationPolicy(.accessory)
            UserDefaults.standard.set(false, forKey: "vaultTouch")
            let h = WebHandle(); h.portalName = "Test"
            let cfg = WKWebViewConfiguration(); cfg.websiteDataStore = .nonPersistent()
            cfg.userContentController.addUserScript(WKUserScript(source: CredentialScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
            cfg.userContentController.add(CredHandler(h), contentWorld: .defaultClient, name: "mfCred")
            let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: cfg)
            let win = NSWindow(contentRect: w.frame, styleMask: [.titled], backing: .buffered, defer: false); win.contentView = w; win.orderBack(nil)
            h.attach(w)
            let form = "<form id=f onsubmit='return false'><input id=u type=email><input id=p type=password><button id=b type=submit>Go</button></form>"
            let host = "login.mfonts-test.example"
            Task { @MainActor in
                func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
                func js(_ c: String) async -> Any? { try? await w.evaluateJavaScript(c, in: nil, contentWorld: .defaultClient) }
                for a in PortalVault.list(host: host) { PortalVault.forget(host: a.host, user: a.user) }
                w.loadHTMLString(form, baseURL: URL(string: "https://" + host + "/login")); await wait(1.2)
                print("1 formulaire détecté :", h.hasForm, "· hôte :", h.pageHost ?? "nil")
                _ = await js("document.getElementById('u').value='a@b.fr';document.getElementById('p').value='s3cret';document.getElementById('b').click()"); await wait(0.5)
                print("2 identifiant capté :", h.candidate?.user ?? "nil", "· mot de passe de", h.candidate?.pass.count ?? 0, "car.")
                _ = await js("document.getElementById('f').remove()"); await wait(0.8)
                print("3 bandeau d'enregistrement :", h.pending?.user ?? "absent")
                h.savePending()
                print("4 Trousseau :", PortalVault.list(host: host).map { $0.user + " · " + $0.label })
                w.loadHTMLString(form, baseURL: URL(string: "https://" + host + "/login")); await wait(1.2)
                h.refreshAccounts()
                print("5 comptes proposés :", h.accounts.map(\.user), "· bandeau de remplissage :", h.hasForm && !h.fillHidden)
                if let a = h.accounts.first { h.fill(a) }; await wait(1.0)
                let r = await js("document.getElementById('u').value + '|' + document.getElementById('p').value")
                print("6 champs remplis :", r as? String ?? "nil")
                // garde-fou : autre hôte, pas de remplissage
                w.loadHTMLString(form, baseURL: URL(string: "https://evil.example/login")); await wait(1.2)
                h.refreshAccounts(); print("7 autre site, comptes proposés :", h.accounts.count)
                for a in PortalVault.list(host: host) { PortalVault.forget(host: a.host, user: a.user) }
                print("8 nettoyé :", PortalVault.list(host: host).count)
                UserDefaults.standard.removeObject(forKey: "vaultTouch"); exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--selftest-undo") {
            Catalog.shared.setActive(Catalog.shared.fonts.filter { $0.lib == "downloaded" && $0.enabled }, on: false)
            RunLoop.main.run(until: Date().addingTimeInterval(2)); print("téléchargées désactivées"); exit(0)
        }
        if CommandLine.arguments.contains("--selftest-clean") { Catalog.shared.deactivateAuto(); RunLoop.main.run(until: Date().addingTimeInterval(2)); print("auto désactivées"); exit(0) }
        if CommandLine.arguments.contains("--selftest-plugins") {
            for p in PluginInstaller.all { do { try PluginInstaller.install(p); print("installé", p.id, PluginInstaller.isInstalled(p)) } catch { print("erreur", p.id, error) } }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5)); exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-doc"), i + 1 < CommandLine.arguments.count { selfTestDoc(CommandLine.arguments[i + 1]); return }
        // Une seule instance : si mFONTS tourne déjà (par exemple lancé en service), on la réveille et on s'efface.
        if let me = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: me).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(); NSApp.terminate(nil); return
        }
        let background = CommandLine.arguments.contains("--background")
        buildMainMenu()
        makeWindow()
        Self.applyPresence()
        if background { window?.orderOut(nil); NSApp.setActivationPolicy(.accessory); installStatusItem() }
        AutoActivator.shared.applyWatch()
        if PluginInstaller.anyInstalled { Bridge.shared.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in Task { @MainActor in Updater.shared.tick(); PortalCatalog.shared.tick() } }
        Task { @MainActor in Updater.shared.tick(); PortalCatalog.shared.tick() }
        window?.centerOnScreen()
        if !background { window?.present() }
    }

    func application(_ app: NSApplication, open urls: [URL]) { AutoActivator.shared.openViaMFonts(urls) }
    @objc func toggleFinder() { showMain(); NotificationCenter.default.post(name: .toggleFinder, object: nil) }
    @objc func openDocument() { AutoActivator.shared.chooseDocument() }
    func applicationWillTerminate(_ n: Notification) {
        Bridge.shared.stop()
        saveWindowSize()
    }
    /// Taille de la fenêtre retenue à la fermeture de l'appli (la position, elle, est recentrée à chaque lancement).
    func saveWindowSize() {
        guard let w = window, !w.styleMask.contains(.fullScreen) else { return }
        let sz = w.contentLayoutRect.size
        guard sz.width >= 1100, sz.height >= 640 else { return }
        UserDefaults.standard.set(Double(sz.width), forKey: "winW"); UserDefaults.standard.set(Double(sz.height), forKey: "winH")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return true }

    // MARK: fenêtres

    func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 767), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = false
        w.title = "mFONTS"
        w.titleVisibility = .hidden
        let label = NSTextField(labelWithAttributedString: {
            let a = NSMutableAttributedString(string: "mFONTS", attributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
            a.addAttribute(.foregroundColor, value: NSColor(srgbRed: 0x2C / 255, green: 0x9E / 255, blue: 0xD6 / 255, alpha: 1), range: NSRange(location: 0, length: 1))
            return a }())
        if let close = w.standardWindowButton(.closeButton), let zoom = w.standardWindowButton(.zoomButton), let bar = close.superview {
            label.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(label)
            NSLayoutConstraint.activate([label.centerYAnchor.constraint(equalTo: close.centerYAnchor),
                                         label.leadingAnchor.constraint(equalTo: zoom.trailingAnchor, constant: 14)])
        }
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: MainView())
        w.minSize = NSSize(width: 1100, height: 640)
        // Taille retenue d'un lancement à l'autre (limitée à l'écran) ; la position, elle, est toujours recentrée.
        let d = UserDefaults.standard
        let sw = CGFloat(d.double(forKey: "winW")), sh = CGFloat(d.double(forKey: "winH"))
        w.setContentSize(NSSize(width: sw >= 1100 ? sw : 1180, height: sh >= 640 ? sh : 767))
        NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: w, queue: .main) { n in
            if let win = n.object as? NSWindow { let sz = win.contentLayoutRect.size; UserDefaults.standard.set(Double(sz.width), forKey: "winW"); UserDefaults.standard.set(Double(sz.height), forKey: "winH") }
        }
        w.centerOnScreen()
        window = w
    }

    @objc func showMain() { Self.applyPresence(); window?.present() }

    /// Iconifier : la fenêtre disparaît, mFONTS continue dans la barre de menus (activation automatique et extensions Adobe comprises).
    @objc func hideToMenuBar() {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L.t("menu.settings"); w.isReleasedWhenClosed = false; w.backgroundColor = Theme.nsBg
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.setContentSize(NSSize(width: 780, height: 600)); w.centerOnScreen(); settingsWindow = w
        }
        settingsWindow?.present()
    }

    @objc func showAbout() { About.show() }

    // MARK: menus

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: L.t("menu.about"), action: #selector(showAbout), keyEquivalent: "").target = self
        app.addItem(.separator())
        let s = app.addItem(withTitle: L.t("menu.settings"), action: #selector(showSettings), keyEquivalent: ","); s.target = self
        app.addItem(.separator())
        app.addItem(withTitle: L.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: L.t("menu.file"))
        let find = file.addItem(withTitle: L.t("menu.find"), action: #selector(toggleFinder), keyEquivalent: "f"); find.keyEquivalentModifierMask = [.command, .shift]; find.target = self
        file.addItem(withTitle: L.t("menu.openDoc"), action: #selector(openDocument), keyEquivalent: "o").target = self
        fileItem.submenu = file
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let hide = win.addItem(withTitle: L.t("menu.hideToBar"), action: #selector(hideToMenuBar), keyEquivalent: "m"); hide.keyEquivalentModifierMask = [.command, .option]; hide.target = self
        winItem.submenu = win
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    // MARK: présence (Dock / barre de menus)

    static func applyPresence() {
        let mode = UserDefaults.standard.string(forKey: "presence") ?? "both"
        NSApp.setActivationPolicy(mode == "menubar" ? .accessory : .regular)
        if mode == "dock" { shared.removeStatusItem() } else { shared.installStatusItem() }
        if mode != "menubar" { NSApp.activate() }
    }

    func removeStatusItem() { if let s = statusItem { NSStatusBar.system.removeStatusItem(s); statusItem = nil } }

    func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            let img = NSImage(systemSymbolName: "textformat", accessibilityDescription: "mFONTS")
            img?.isTemplate = true
            b.image = img
            b.target = self; b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    /// Le menu s'ouvre nous-mêmes sous l'icône (jamais `statusItem.menu`, qui l'ouvre mal sur plusieurs écrans).
    @objc func statusClicked() {
        guard let b = statusItem?.button else { return }
        let cat = Catalog.shared
        let m = NSMenu()
        m.addItem(withTitle: L.t("menu.active", cat.activeCount), action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(.separator())
        m.addItem(withTitle: L.t("menu.recent"), action: nil, keyEquivalent: "").isEnabled = false
        let rec = cat.recents
        if rec.isEmpty { m.addItem(withTitle: L.t("menu.none"), action: nil, keyEquivalent: "").isEnabled = false }
        for f in rec {
            let it = NSMenuItem(title: f.full, action: #selector(toggleFont(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = f.id; it.state = f.enabled ? .on : .off
            it.attributedTitle = NSAttributedString(string: f.full, attributes: [.font: FontCache.nsFont(f, size: 15)])
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(withTitle: L.t("menu.deactivateAll"), action: #selector(deactivateAll), keyEquivalent: "").target = self
        m.addItem(withTitle: L.t("menu.open"), action: #selector(showMain), keyEquivalent: "").target = self
        m.addItem(withTitle: L.t("menu.settings"), action: #selector(showSettings), keyEquivalent: "").target = self
        m.addItem(withTitle: L.t("menu.about"), action: #selector(showAbout), keyEquivalent: "").target = self
        m.addItem(withTitle: L.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.isFlipped ? b.bounds.maxY + 4 : -4), in: b)
    }

    @objc func toggleFont(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let f = Catalog.shared.fonts.first(where: { $0.id == id }) else { return }
        Catalog.shared.setActive([f], on: !f.enabled)
    }
    @objc func deactivateAll() { Catalog.shared.deactivateAll() }
}

extension AppDelegate {
    /// Essai sans interface : analyse un document et affiche les polices trouvées dans le catalogue.
    func selfTestDoc(_ path: String) {
        let c = Catalog.shared
        let idx = FontIndex(c.fonts)
        let t0 = Date()
        let r = DocFonts.resolve(URL(fileURLWithPath: path), index: idx, systemNames: DocFonts.systemFontNames())
        let names = r.ids.compactMap { id in c.fonts.first { $0.id == id }?.ps }
        print("\(path)\n  trouvées (\(names.count)) : \(names.prefix(25).joined(separator: ", "))\n  introuvables : \(r.missing.prefix(15))\n  durée : \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        exit(0)
    }

    /// Essai sans interface : importe les bibliothèques Right Fonts détectées, affiche le rapport puis quitte (sans activation).
    func selfTest() {
        guard let folder = RightFontImporter.defaultFolder() else { print("aucun dossier Right Fonts"); exit(1) }
        let libs = RightFontImporter.detect(in: folder)
        var o = ImportOptions(); o.libs = Set(libs.map(\.id)); o.activate = false; o.prefs = false
        Task.detached {
            let p = RightFontImporter.read(libs, options: o) { _, _ in }
            await MainActor.run {
                let r = Catalog.shared.apply(p, options: o)
                let c = Catalog.shared
                print("bibliothèques \(libs.count) · polices \(r.fonts) · familles \(c.familyCount) · collections \(r.collections) · étiquettes \(r.tags) · ignorées \(r.skipped) · doublons \(r.duplicates) · erreurs \(r.errors)")
                let missing = c.fonts.filter { !FileManager.default.fileExists(atPath: $0.path) }.count
                print("fichiers introuvables : \(missing)")
                exit(0)
            }
        }
    }
}
