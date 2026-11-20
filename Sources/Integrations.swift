// mFONTS — applications du Mac compatibles avec l'activation à la demande : détection, réglage par appli, proposition au premier lancement.
import SwiftUI
import AppKit

struct Integration: Identifiable {
    enum Kind { case watch, adobe }           // surveillance (accessibilité) / extension dans l'appli
    let id: String                            // clé de AutoActivator.watched
    let name: String
    let kind: Kind
    let url: URL
}

@MainActor
enum Integrations {
    /// Applis de la liste surveillée réellement installées sur ce Mac.
    static func detect() -> [Integration] {
        let fm = FileManager.default
        var apps: [URL] = []
        for root in ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"] {
            for e in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let u = URL(fileURLWithPath: root).appendingPathComponent(e)
                if e.hasSuffix(".app") { apps.append(u) }
                else if e.hasPrefix("Adobe") || e.hasPrefix("DaVinci") || e.hasPrefix("Microsoft") {
                    for s in (try? fm.contentsOfDirectory(atPath: u.path)) ?? [] where s.hasSuffix(".app") { apps.append(u.appendingPathComponent(s)) }
                }
            }
        }
        var out: [Integration] = []
        for (key, name) in AutoActivator.watched {
            let hit = apps.first { a in
                guard let b = Bundle(url: a)?.bundleIdentifier?.lowercased() else { return false }
                return b.contains(key)
            }
            if let hit { out.append(Integration(id: key, name: name, kind: key.hasPrefix("adobe") ? .adobe : .watch, url: hit)) }
        }
        return out
    }

    static var enabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "autoApps") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "autoApps"); AutoActivator.shared.applyWatch() }
    }
}

/// Liste des applis détectées, un interrupteur par appli (même composant dans les Réglages et au premier lancement).
struct IntegrationsList: View {
    let items: [Integration]
    @State private var on = Integrations.enabled
    @State private var tick = 0
    @State private var failure: String?
    var framed = true
    var onChange: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                if i > 0 { Divider().opacity(0.4) }
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: it.url.path)).resizable().frame(width: 28, height: 28)
                    let plug = PluginInstaller.plugin(for: it.id)
                    let installed = plug.map { PluginInstaller.isInstalled($0) } ?? false
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.name).font(.system(size: 13, weight: .medium))
                        Text(L.t(plug == nil ? (it.kind == .adobe ? "int.adobe" : "int.watch") : (installed ? "int.plugin.installed" : "int.plugin"))).font(.system(size: 11.5)).foregroundStyle(Theme.t2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let plug {
                        if installed { Button(L.t("int.remove")) { PluginInstaller.uninstall(plug); tick += 1 }.fixedSize() }
                        Button(L.t(installed ? "int.reinstall" : "int.install")) {
                            do { try PluginInstaller.install(plug); failure = nil } catch { failure = error.localizedDescription }
                            tick += 1
                        }.buttonStyle(.borderedProminent).tint(Theme.acc).fixedSize()
                    } else {
                        Toggle("", isOn: Binding(get: { on.contains(it.id) }, set: { v in
                            if v { on.insert(it.id) } else { on.remove(it.id) }
                            Integrations.enabled = on; onChange?()
                        })).labelsHidden().toggleStyle(.switch).tint(Theme.acc)
                    }
                }.padding(.vertical, 8).padding(.horizontal, 14).frame(minHeight: 48)
            }
        }
        .background(framed ? Theme.card : Color.clear, in: RoundedRectangle(cornerRadius: Theme.r))
        .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(framed ? Theme.line : Color.clear, lineWidth: 1))
        .id(tick)
        if let failure { Text(failure).font(.system(size: 11.5)).foregroundStyle(.red).padding(.top, 6) }
    }
}

/// Proposition au premier lancement.
struct IntegrationsWelcome: View {
    @Binding var isPresented: Bool
    let items: [Integration]
    @State private var bg = BackgroundService.isEnabled
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(Theme.acc)
            Text(L.t("int.welcome.title")).font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
            Text(L.t("int.welcome.text")).font(.system(size: 12.5)).foregroundStyle(Theme.t2).multilineTextAlignment(.center)
            ScrollView { IntegrationsList(items: items) }.frame(maxHeight: 300)
            if BackgroundService.available {
                Toggle(L.t("svc.welcome"), isOn: Binding(get: { bg }, set: { v in BackgroundService.set(v); bg = BackgroundService.isEnabled || BackgroundService.needsApproval }))
                    .toggleStyle(.switch).tint(Theme.acc).font(.system(size: 12.5))
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.r))
                    .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
            }
            Text(L.t("int.welcome.note")).font(.system(size: 11.5)).foregroundStyle(Theme.t2).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Spacer()
                Button(L.t("int.later")) { isPresented = false }
                Button(L.t("int.done")) { isPresented = false }.buttonStyle(.borderedProminent).tint(Theme.acc).keyboardShortcut(.defaultAction)
                Spacer()
            }
        }
        .padding(24).frame(width: 520).background(Theme.bg)
        .onDisappear { UserDefaults.standard.set(true, forKey: "integrationsAsked") }
    }
}
