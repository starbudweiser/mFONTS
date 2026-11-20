// mFONTS — fenêtre de Réglages : barre latérale d'onglets et cartes de lignes (design Flat Round, comme la fenêtre principale).
import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, auto, sources, display, update
    var id: String { rawValue }
    var icon: String { ["general": "gearshape", "auto": "sparkles", "sources": "globe", "display": "textformat", "update": "arrow.down.circle"][rawValue]! }
}

/// Carte de lignes : titre de section au-dessus, lignes séparées par un filet.
struct SCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    init(_ title: String? = nil, @ViewBuilder _ content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title { Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.t2).padding(.leading, 4) }
            VStack(spacing: 0) { content }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.r))
                .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
        }
    }
}

/// Une ligne : libellé (et aide) à gauche, contrôle à droite, centrés verticalement.
struct SRow<Control: View>: View {
    let title: String; let help: String?; let divider: Bool
    @ViewBuilder let control: Control
    init(_ title: String, help: String? = nil, divider: Bool = true, @ViewBuilder _ control: () -> Control) {
        self.title = title; self.help = help; self.divider = divider; self.control = control()
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13))
                    if let help { Text(help).font(.system(size: 11.5)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                control
            }.padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
            if divider { Divider().opacity(0.4) }
        }
    }
}

struct SettingsView: View {
    @State var tab: SettingsTab = .general
    var scrolling = true
    init(tab: SettingsTab = .general, scrolling: Bool = true) { _tab = State(initialValue: tab); self.scrolling = scrolling }
    @AppStorage("persistentActivation") var persistent = true
    @AppStorage("presence") var presence = "both"
    @AppStorage("autoUpdate") var autoUpdate = true
    @AppStorage("autoNotify") var autoNotify = "missing"
    @AppStorage("previewText") var previewText = ""
    @AppStorage("previewScale") var scale = 100.0
    @State var bgOn = BackgroundService.isEnabled
    @State var bgError: String?
    @ObservedObject var up = Updater.shared
    @ObservedObject var portals = PortalCatalog.shared
    @AppStorage("dlActivate") var dlActivate = true
    @AppStorage("dlHideInstalled") var dlHide = true
    @AppStorage("src_fontsource") var srcFS = true
    @AppStorage("src_fontshare") var srcFSH = true
    @AppStorage("src_squirrel") var srcSQ = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { t in
                    HStack(spacing: 9) {
                        Image(systemName: t.icon).frame(width: 18)
                        Text(L.t("tab." + t.rawValue)).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .foregroundStyle(tab == t ? Color.white : Color.primary)
                    .background(tab == t ? Theme.acc : Color.clear, in: RoundedRectangle(cornerRadius: Theme.r))
                    .contentShape(Rectangle()).onTapGesture { tab = t }
                }
                Spacer()
            }
            .font(.system(size: 13)).padding(10).frame(width: 190).background(Theme.side)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                if scrolling { ScrollView { content } } else { content }
            }.background(Theme.bg)
        }
        .tint(Theme.acc)
        .frame(width: 780, height: 600)
        .onChange(of: presence) { _, _ in AppDelegate.applyPresence() }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 18) { page }.padding(24).frame(maxWidth: .infinity, maxHeight: scrolling ? nil : .infinity, alignment: .topLeading)
    }

    @ViewBuilder var page: some View {
        switch tab {
        case .general:
            SCard(L.t("set.activation")) {
                SRow(L.t("set.persistent"), help: L.t("set.persistent.help"), divider: false) { Toggle("", isOn: $persistent).labelsHidden().toggleStyle(.switch) }
            }
            SCard(L.t("set.presence")) {
                SRow(L.t("set.presence.row"), help: L.t("set.presence.help"), divider: false) {
                    Picker("", selection: $presence) {
                        Text(L.t("presence.both")).tag("both"); Text(L.t("presence.dock")).tag("dock"); Text(L.t("presence.menubar")).tag("menubar")
                    }.labelsHidden().fixedSize()
                }
            }
            SCard(L.t("svc.title")) {
                SRow(L.t("svc.toggle"), help: L.t(BackgroundService.available ? "svc.help" : "svc.unavailable"), divider: BackgroundService.needsApproval) {
                    Toggle("", isOn: Binding(get: { bgOn }, set: { v in bgError = BackgroundService.set(v); bgOn = BackgroundService.isEnabled || BackgroundService.needsApproval }))
                        .labelsHidden().toggleStyle(.switch).disabled(!BackgroundService.available)
                }
                if BackgroundService.needsApproval {
                    SRow(L.t("svc.approve.help"), divider: false) { Button(L.t("svc.approve")) { BackgroundService.openLoginItems() }.fixedSize() }
                }
            }
            if let bgError { Text(bgError).font(.system(size: 11.5)).foregroundStyle(.red) }
        case .auto:
            Text(L.t("auto.set.intro") + " " + L.t("auto.set.open.help")).font(.system(size: 12)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
            let apps = Integrations.detect()
            SCard(L.t("auto.set.apps")) {
                if apps.isEmpty { SRow(L.t("int.none"), divider: false) { EmptyView() } }
                else { IntegrationsList(items: apps, framed: false) }
            }
            SCard {
                SRow(L.t("auto.set.notify"), divider: false) {
                    Picker("", selection: $autoNotify) {
                        Text(L.t("auto.notify.missing")).tag("missing"); Text(L.t("auto.notify.always")).tag("always"); Text(L.t("auto.notify.never")).tag("never")
                    }.labelsHidden().fixedSize()
                }
            }
        case .sources:
            SCard(L.t("set.src.title")) {
                SRow(RemoteSource.fontsource.title, help: L.t("set.src.fontsource.help")) { Toggle("", isOn: $srcFS).labelsHidden().toggleStyle(.switch) }
                SRow(RemoteSource.fontshare.title, help: L.t("set.src.fontshare.help")) { Toggle("", isOn: $srcFSH).labelsHidden().toggleStyle(.switch) }
                SRow(RemoteSource.squirrel.title, help: L.t("set.src.squirrel.help"), divider: false) { Toggle("", isOn: $srcSQ).labelsHidden().toggleStyle(.switch) }
            }
            SCard(L.t("set.src.install")) {
                SRow(L.t("set.src.activate"), help: L.t("set.src.activate.help")) { Toggle("", isOn: $dlActivate).labelsHidden().toggleStyle(.switch) }
                SRow(L.t("set.src.hide"), divider: false) { Toggle("", isOn: $dlHide).labelsHidden().toggleStyle(.switch) }
            }
            SCard(L.t("set.portals.title")) {
                SRow(L.t("set.portals.version", portals.version, portals.updated), help: portalStatus, divider: false) {
                    Button(L.t("set.portals.update")) { Task { await portals.update() } }.fixedSize().disabled(portals.state == .updating)
                }
            }
            Text(portals.portals.map(\.name).joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
        case .display:
            SCard(L.t("set.display")) {
                SRow(L.t("set.sample"), help: L.t("set.sample.help")) {
                    TextField(L.t("prefs.sample"), text: $previewText).textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(width: 260).background(Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r))
                }
                SRow(L.t("set.scale.title"), divider: false) {
                    HStack(spacing: 10) {
                        Slider(value: $scale, in: 50...200).frame(width: 200)
                        Text("\(Int(scale))").monospacedDigit().foregroundStyle(Theme.t2).frame(width: 30, alignment: .trailing)
                    }
                }
            }
        case .update:
            SCard(L.t("upd.title")) {
                SRow(L.t("upd.auto"), help: L.t("upd.version", up.currentVersion)) { Toggle("", isOn: $autoUpdate).labelsHidden().toggleStyle(.switch) }
                SRow(statusText.isEmpty ? L.t("upd.title") : statusText, divider: false) {
                    HStack(spacing: 8) {
                        Button(L.t("upd.check")) { Task { await up.check() } }.fixedSize()
                        if case .available(let v) = up.state { Button(L.t("upd.install", v)) { Task { await up.install() } }.buttonStyle(.borderedProminent).fixedSize() }
                    }
                }
            }
        }
    }

    var portalStatus: String {
        switch portals.state {
        case .idle: return L.t("set.portals.auto")
        case .updating: return L.t("set.portals.updating")
        case .upToDate: return L.t("set.portals.uptodate")
        case .updated(let v): return L.t("set.portals.updated", v)
        case .failed: return L.t("set.portals.failed")
        }
    }

    var statusText: String {
        switch up.state {
        case .idle: return ""
        case .checking: return L.t("upd.checking")
        case .upToDate: return L.t("upd.uptodate", up.currentVersion)
        case .available(let v): return L.t("upd.available", v)
        case .downloading: return L.t("upd.downloading")
        case .failed(let e): return L.t("upd.failed", e)
        }
    }
}
