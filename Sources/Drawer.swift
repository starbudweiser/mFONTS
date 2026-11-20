// mFONTS — tiroir « Trouver des polices » : recherche dans les sources à API, navigateur de portails, suivi des installations.
// Il glisse depuis la droite par-dessus toute la zone principale, jusqu'à la barre latérale.
import SwiftUI
import AppKit
import WebKit
import Combine

// MARK: navigateur

@MainActor
final class WebHandle: ObservableObject {
    weak var web: WKWebView?
    @Published var canBack = false
    @Published var canForward = false
    @Published var address = ""
    // Identifiants (Trousseau)
    @Published var hasForm = false                       // la page affiche un formulaire de mot de passe
    @Published var accounts: [VaultAccount] = []         // comptes enregistrés pour le site affiché
    @Published var fillHidden = false
    @Published var pending: PendingLogin?                // identifiant capté, en attente d'un clic sur « Enregistrer »
    var candidate: PendingLogin?
    var portalName = ""
    var bag = Set<AnyCancellable>()

    struct PendingLogin { let host: String, user: String, pass: String }

    var pageHost: String? {
        guard let u = web?.url, u.scheme == "https", let h = u.host else { return nil }
        return PortalVault.normal(h)
    }

    func attach(_ w: WKWebView) {
        bag.removeAll(); web = w; hasForm = false; accounts = []; pending = nil; candidate = nil; fillHidden = false
        w.publisher(for: \.canGoBack).receive(on: DispatchQueue.main).sink { [weak self] in self?.canBack = $0 }.store(in: &bag)
        w.publisher(for: \.canGoForward).receive(on: DispatchQueue.main).sink { [weak self] in self?.canForward = $0 }.store(in: &bag)
        w.publisher(for: \.url).receive(on: DispatchQueue.main).sink { [weak self] in
            self?.address = $0?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
            self?.refreshAccounts()
        }.store(in: &bag)
    }

    func refreshAccounts() { accounts = pageHost.map { PortalVault.list(host: $0) } ?? [] }

    /// Message du script de la page (formulaire présent ou absent, envoi d'un identifiant).
    func formChanged(_ has: Bool) {
        let was = hasForm; hasForm = has
        if has { if !was { fillHidden = false }; refreshAccounts() }
        if let c = candidate {
            if c.host != pageHost { candidate = nil }
            else if !has { candidate = nil; offer(c) }          // le formulaire a disparu : la connexion a réussi
            else if !was { candidate = nil }                    // page rechargée avec le formulaire : échec probable
        }
    }
    func submitted(user: String, pass: String) { if let h = pageHost { candidate = PendingLogin(host: h, user: user, pass: pass) } }
    private func offer(_ c: PendingLogin) {
        guard Prefs.vaultOffer, !PortalVault.never.contains(c.host), !PortalVault.list(host: c.host).contains(where: { $0.user == c.user }) else { return }
        pending = c
    }
    func savePending() {
        guard let c = pending else { return }
        PortalVault.save(host: c.host, user: c.user, password: c.pass, label: "mFONTS — " + (portalName.isEmpty ? c.host : portalName))
        pending = nil; refreshAccounts()
    }
    func dismissPending(never: Bool = false) { if never, let c = pending { PortalVault.never.insert(c.host) }; pending = nil }

    /// Bouton de secours : capte les valeurs saisies maintenant (sites à connexion sans envoi de formulaire).
    func saveManually() {
        guard let w = web, pageHost != nil else { return }
        w.callAsyncJavaScript("return window.__mfGrab ? window.__mfGrab() : null", arguments: [:], in: nil, in: .defaultClient) { [weak self] r in
            guard case .success(let v) = r, let d = v as? [String: Any], let p = d["pass"] as? String, !p.isEmpty, let h = self?.pageHost else { return }
            DispatchQueue.main.async { self?.pending = PendingLogin(host: h, user: d["user"] as? String ?? "", pass: p) }
        }
    }

    func fill(_ a: VaultAccount) {
        guard let w = web, a.host == pageHost else { return }
        fillHidden = true
        Task {
            guard let pw = await PortalVault.password(host: a.host, user: a.user, reason: L.t("vault.auth", a.host)) else { return }
            _ = try? await w.callAsyncJavaScript("return window.__mfFill ? window.__mfFill(u, p) : false", arguments: ["u": a.user, "p": pw], in: nil, contentWorld: .defaultClient)
        }
    }
}

/// Reçoit les messages du script d'identifiants : cadre principal, https, hôte identique à celui de la page.
@MainActor
final class CredHandler: NSObject, WKScriptMessageHandler {
    weak var handle: WebHandle?
    init(_ h: WebHandle) { handle = h }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard m.frameInfo.isMainFrame, let wv = m.webView, wv.url?.scheme == "https", m.frameInfo.securityOrigin.host == wv.url?.host,
              let d = m.body as? [String: Any], let kind = d["kind"] as? String else { return }
        if kind == "form" { handle?.formChanged(d["has"] as? Bool ?? false) }
        else if kind == "submit", let p = d["pass"] as? String { handle?.submitted(user: d["user"] as? String ?? "", pass: p) }
    }
}

struct PortalWebView: NSViewRepresentable {
    let url: URL
    let portalID: String
    let handle: WebHandle
    let onFile: (URL, String) -> Void

    func makeCoordinator() -> Coord { Coord(onFile) }
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = PortalSession.store(portalID)     // isolé par défaut ; session conservée seulement si le portail le demande
        cfg.userContentController.addUserScript(WKUserScript(source: CredentialScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        cfg.userContentController.add(CredHandler(handle), contentWorld: .defaultClient, name: "mfCred")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = context.coordinator; w.uiDelegate = context.coordinator
        w.allowsBackForwardNavigationGestures = true
        context.coordinator.loaded = url
        handle.attach(w)
        w.load(URLRequest(url: url))
        return w
    }
    func updateNSView(_ w: WKWebView, context: Context) {
        context.coordinator.onFile = onFile
        if context.coordinator.loaded != url { context.coordinator.loaded = url; w.load(URLRequest(url: url)) }
    }

    final class Coord: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var onFile: (URL, String) -> Void
        var loaded: URL?
        private var targets: [ObjectIdentifier: (URL, String)] = [:]
        init(_ f: @escaping (URL, String) -> Void) { onFile = f }

        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(a.shouldPerformDownload ? .download : .allow)
        }
        func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let m = (r.response.mimeType ?? "").lowercased()
            let disp = ((r.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
            decisionHandler(!r.canShowMIMEType || m.contains("zip") || m.contains("font") || m == "application/octet-stream" || disp.contains("attachment") ? .download : .allow)
        }
        func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
        func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }
        // Les liens qui s'ouvrent dans une nouvelle fenêtre restent dans le navigateur du tiroir.
        func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if a.targetFrame == nil, let u = a.request.url { w.load(URLRequest(url: u)) }
            return nil
        }
        func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mfonts-web-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(suggestedFilename.isEmpty ? "police.zip" : suggestedFilename)
            targets[ObjectIdentifier(d)] = (dest, r.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "")
            completionHandler(dest)
        }
        func downloadDidFinish(_ d: WKDownload) {
            guard let (f, host) = targets.removeValue(forKey: ObjectIdentifier(d)) else { return }
            let e = f.pathExtension.lowercased()
            if ["zip", "ttf", "otf", "ttc", "otc"].contains(e) { DispatchQueue.main.async { self.onFile(f, host) } }
        }
        func download(_ d: WKDownload, didFailWithError error: Error, resumeData: Data?) { targets[ObjectIdentifier(d)] = nil }
    }
}

// MARK: tiroir

struct FindDrawer: View {
    @Binding var isPresented: Bool
    @ObservedObject var remote = RemoteCatalog.shared
    @ObservedObject var dl = Downloads.shared
    @ObservedObject var portals = PortalCatalog.shared
    @ObservedObject var cat = Catalog.shared
    @StateObject var web = WebHandle()
    @State var tab = 0
    @State var query = ""
    @State var catFilter = "all"
    @State var installedKeys = Set<String>()
    @State var portal: Portal?
    @State var webStarted = false
    @AppStorage("dlHideInstalled") var hideInstalled = true
    @AppStorage("src_fontsource") var srcFontsource = true
    @AppStorage("src_fontshare") var srcFontshare = true
    @AppStorage("src_squirrel") var srcSquirrel = false

    func on(_ s: String) -> Bool { s == "fontsource" ? srcFontsource : s == "fontshare" ? srcFontshare : srcSquirrel }

    var results: [RemoteFamily] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>(), out: [RemoteFamily] = []
        for f in remote.families where on(f.source) {
            if !q.isEmpty, !f.name.lowercased().contains(q) { continue }
            if catFilter != "all", f.category != catFilter { continue }
            if hideInstalled, installedKeys.contains(f.key) { continue }
            if seen.insert(f.key).inserted { out.append(f) }
            if out.count >= 300 { break }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe").foregroundStyle(Theme.acc)
                Text(L.t("find.title")).font(.system(size: 15, weight: .bold))
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.25)) { isPresented = false } } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.t2).frame(width: 28, height: 28)
                        .background(Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r))
                }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
            }.padding(.horizontal, 16).frame(height: 52)

            HStack(spacing: 4) {
                tabButton(0, "find.tab.search"); tabButton(1, "find.tab.web"); tabButton(2, "find.tab.dl", badge: dl.running)
            }.padding(3).background(Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r)).padding(.horizontal, 16).padding(.bottom, 10)

            ZStack {
                if tab == 0 { searchTab }
                webTab.opacity(tab == 1 ? 1 : 0).allowsHitTesting(tab == 1)
                if tab == 2 { installsTab }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .onAppear { remote.load(); refreshInstalled() }
        .onChange(of: cat.fonts.count) { _, _ in refreshInstalled() }
        .onChange(of: tab) { _, t in if t == 1 { startWeb() } }
        .onReceive(dl.$caught) { c in if c != nil { tab = 1; startWeb() } }
    }

    func refreshInstalled() { installedKeys = Set(cat.fonts.map { FontIndex.compact($0.family) }) }
    func startWeb() { if portal == nil { portal = portals.portals.first(where: { $0.id == "dafont" }) ?? portals.portals.first }; webStarted = true }

    func tabButton(_ i: Int, _ key: String, badge: Int = 0) -> some View {
        HStack(spacing: 6) {
            Text(L.t(key))
            if badge > 0 { Text("\(badge)").font(.system(size: 10.5, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 1).background(Theme.acc, in: Capsule()).foregroundStyle(.white) }
        }
        .font(.system(size: 13)).frame(maxWidth: .infinity).padding(.vertical, 6)
        .foregroundStyle(tab == i ? Color.white : Theme.t2)
        .background(tab == i ? Theme.acc : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle()).onTapGesture { tab = i }
    }

    // MARK: recherche

    var searchTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.t2)
                    TextField(L.t("find.search"), text: $query).textFieldStyle(.plain)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.t2) }.buttonStyle(.plain) }
                }.padding(.horizontal, 10).padding(.vertical, 7).background(Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r))
                Menu {
                    Button { catFilter = "all" } label: { checked(L.t("st.all"), catFilter == "all") }
                    Divider()
                    ForEach(["serif", "sans", "script", "mono", "display", "other"], id: \.self) { c in Button { catFilter = c } label: { checked(L.t("cls." + c), catFilter == c) } }
                } label: { chip(catFilter == "all" ? L.t("find.cat") : L.t("cls." + catFilter), on: catFilter != "all", menu: true) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }.padding(.horizontal, 16).padding(.bottom, 8)
            HStack(spacing: 6) {
                srcChip(.fontsource, $srcFontsource); srcChip(.fontshare, $srcFontshare); srcChip(.squirrel, $srcSquirrel)
                Button { hideInstalled.toggle() } label: { chip(L.t("find.hideInstalled"), on: hideInstalled) }.buttonStyle(.plain)
                Spacer()
                Button { remote.load(force: true) } label: { Image(systemName: "arrow.clockwise").foregroundStyle(Theme.t2).frame(width: 26, height: 26) }.buttonStyle(.plain).help(L.t("find.refresh"))
            }.padding(.horizontal, 16).padding(.bottom, 8)
            ZStack {
                let list = results
                if remote.loading && remote.families.isEmpty {
                    VStack(spacing: 10) { ProgressView(); Text(L.t("find.loading")).foregroundStyle(Theme.t2) }
                } else if list.isEmpty {
                    Text(L.t("find.empty")).foregroundStyle(Theme.t2)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: .infinity), spacing: 10)], spacing: 10) {
                            ForEach(list) { f in RemoteCard(f: f, installed: installedKeys.contains(f.key), sample: Prefs.previewText) }
                        }.padding(.horizontal, 16).padding(.bottom, 12)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            HStack {
                Text(L.t("find.count", results.count, remote.families.count)).monospacedDigit()
                if !remote.failed.isEmpty { Text("· " + L.t("find.sources.failed", remote.failed.sorted().joined(separator: ", "))).foregroundStyle(.orange) }
                Spacer()
                Text(L.t("find.dest", L.t("lib.downloaded")))
            }.font(.system(size: 12)).foregroundStyle(Theme.t2).padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    func checked(_ t: String, _ on: Bool) -> AnyView { on ? AnyView(Label(t, systemImage: "checkmark")) : AnyView(Text(t)) }
    func chip(_ t: String, on: Bool = false, menu: Bool = false) -> some View {
        HStack(spacing: 4) { Text(t); if menu { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) } }
            .font(.system(size: 12)).foregroundStyle(on ? Theme.acc : Theme.t2)
            .padding(.horizontal, 10).padding(.vertical, 5).background(on ? Theme.acc.opacity(0.18) : Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r))
    }
    func srcChip(_ s: RemoteSource, _ b: Binding<Bool>) -> some View {
        Button { b.wrappedValue.toggle(); remote.load() } label: { chip((b.wrappedValue ? "✓ " : "") + s.title, on: b.wrappedValue) }.buttonStyle(.plain)
    }

    // MARK: navigateur

    var webTab: some View {
        VStack(spacing: 0) {
            FlowLayout(spacing: 6) {
                ForEach(portals.portals) { p in
                    Button { portal = p; webStarted = true } label: { chip(p.name, on: portal?.id == p.id) }.buttonStyle(.plain)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            HStack(spacing: 8) {
                navButton("chevron.left", web.canBack) { web.web?.goBack() }
                navButton("chevron.right", web.canForward) { web.web?.goForward() }
                navButton("arrow.clockwise", true) { web.web?.reload() }
                HStack(spacing: 6) { Image(systemName: "lock.fill").font(.system(size: 10)); Text(web.address.isEmpty ? (portal?.host ?? "") : web.address).lineLimit(1); Spacer()
                    if let p = portal { Text(L.t(p.licenseKey)).font(.system(size: 11)).foregroundStyle(p.license == "ofl" || p.license == "commercial" ? Theme.ok : Color.orange) } }
                    .font(.system(size: 12)).foregroundStyle(Theme.t2).padding(.horizontal, 10).padding(.vertical, 6).background(Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r))
                if web.hasForm {
                    Button { if web.accounts.isEmpty { web.saveManually() } else { web.fillHidden = false } } label: {
                        HStack(spacing: 5) { Image(systemName: "key.fill"); if !web.accounts.isEmpty { Text("\(web.accounts.count)").font(.system(size: 11, weight: .semibold)) } }
                            .font(.system(size: 12)).foregroundStyle(web.accounts.isEmpty ? Theme.t2 : Theme.ok).padding(.horizontal, 9).frame(height: 28)
                            .background(web.accounts.isEmpty ? Theme.ctl : Theme.ok.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.r))
                    }.buttonStyle(.plain).help(L.t(web.accounts.isEmpty ? "vault.manual" : "vault.key.help"))
                }
            }.padding(.horizontal, 16).padding(.bottom, 8)
            ZStack(alignment: .bottom) {
                if webStarted, let p = portal, let u = URL(string: p.url) {
                    PortalWebView(url: u, portalID: p.id, handle: web) { file, host in dl.caught = (file, host) }
                        .id(p.id + (PortalSession.keeps(p.id) ? "-k" : ""))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
                        .onAppear { web.portalName = p.name }
                } else { Color.clear }
                VStack(spacing: 8) {
                    if let c = web.pending { saveBanner(c) }
                    else if web.hasForm, !web.fillHidden, let a = web.accounts.first { fillBanner(a) }
                    if let c = dl.caught { caughtBanner(c) }
                }
            }.padding(.horizontal, 16).frame(maxHeight: .infinity)
            Text(L.t("find.web.note")).font(.system(size: 11.5)).foregroundStyle(Theme.t2).padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    func keyBanner<C: View>(_ title: String, _ sub: String, @ViewBuilder _ buttons: () -> C) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").font(.system(size: 20)).foregroundStyle(Theme.acc)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.t2).lineLimit(1)
            }
            Spacer()
            buttons()
        }.padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line)).padding(.horizontal, 12)
    }
    func saveBanner(_ c: WebHandle.PendingLogin) -> some View {
        keyBanner(L.t("vault.save.title"), c.host + (c.user.isEmpty ? "" : " · " + c.user) + (Prefs.vaultTouch ? " · " + L.t("vault.touchBadge") : "")) {
            Button(L.t("vault.never")) { web.dismissPending(never: true) }.fixedSize()
            Button(L.t("vault.later")) { web.dismissPending() }.fixedSize()
            Button(L.t("vault.save")) { web.savePending() }.buttonStyle(.borderedProminent).tint(Theme.acc).fixedSize()
        }
    }
    func fillBanner(_ a: VaultAccount) -> some View {
        keyBanner(L.t("vault.fill.title", a.user), L.t("vault.fill.sub", a.host)) {
            Button { web.fillHidden = true } label: { Image(systemName: "xmark").foregroundStyle(Theme.t2) }.buttonStyle(.plain)
            if web.accounts.count > 1 {
                Menu(L.t("vault.fill")) { ForEach(web.accounts) { x in Button(x.user) { web.fill(x) } } }.fixedSize()
            } else { Button(L.t("vault.fill")) { web.fill(a) }.buttonStyle(.borderedProminent).tint(Theme.acc).fixedSize() }
        }
    }
    func caughtBanner(_ c: (file: URL, host: String)) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.acc)
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t("find.web.detected", c.file.lastPathComponent)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(L.t("find.web.license")).font(.system(size: 11.5)).foregroundStyle(Theme.t2)
            }
            Spacer()
            Button(L.t("find.web.ignore")) { dl.caught = nil }.fixedSize()
            Button(L.t("find.web.install")) { dl.installCaught(c.file, host: c.host); tab = 2 }.buttonStyle(.borderedProminent).tint(Theme.acc).fixedSize()
        }.padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line)).padding(.horizontal, 12)
    }

    func navButton(_ icon: String, _ enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28).background(Theme.ctl, in: RoundedRectangle(cornerRadius: Theme.r)) }
            .buttonStyle(.plain).foregroundStyle(enabled ? Color.primary : Theme.t2).disabled(!enabled)
    }

    // MARK: installations

    var installsTab: some View {
        VStack(spacing: 0) {
            if dl.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 28)).foregroundStyle(Theme.t2)
                    Text(L.t("find.dl.none")).foregroundStyle(Theme.t2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(dl.items.enumerated()), id: \.element.id) { i, it in
                            if i > 0 { Divider().opacity(0.4) }
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(it.name).font(.system(size: 13, weight: .medium))
                                    Text(status(it)).font(.system(size: 11.5)).foregroundStyle(failedColor(it)).lineLimit(2)
                                }
                                Spacer()
                                if it.state.isRunning { ProgressView().controlSize(.small) }
                                if case .done = it.state {
                                    if it.activated { Text(L.t("find.dl.activated")).font(.system(size: 11)).foregroundStyle(Theme.ok) }
                                    else { Button(L.t("find.dl.activate")) { dl.activate(it.id) }.buttonStyle(.borderedProminent).tint(Theme.acc).fixedSize() }
                                    Button(L.t("find.dl.show")) { cat.selection = .library("downloaded"); cat.selectedFamily = nil; withAnimation(.easeOut(duration: 0.25)) { isPresented = false } }.fixedSize()
                                }
                            }.padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 52)
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.r))
                    .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
                    .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
            Divider().opacity(0.5)
            HStack {
                Text(Downloads.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L.t("find.dl.openFolder")) { NSWorkspace.shared.open(Downloads.folder) }.buttonStyle(.plain).foregroundStyle(Theme.acc)
            }.font(.system(size: 12)).foregroundStyle(Theme.t2).padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    func status(_ it: DownloadItem) -> String {
        switch it.state {
        case .downloading: return it.source + " · " + L.t("find.dl.downloading")
        case .unpacking: return it.source + " · " + L.t("find.dl.unpacking")
        case .done(let n): return it.source + " · " + L.t("find.dl.added", n, L.t("lib.downloaded"))
        case .failed(let m): return L.t("find.dl.failed", m)
        }
    }
    func failedColor(_ it: DownloadItem) -> Color { if case .failed = it.state { return .red }; return Theme.t2 }
}

struct RemoteCard: View {
    let f: RemoteFamily
    let installed: Bool
    let sample: String
    @ObservedObject var dl = Downloads.shared
    @State var font: Font?

    var body: some View {
        let busy = dl.isBusy(f.name)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(f.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("· " + (f.styles == 1 ? L.t("card.style") : L.t("card.styles", f.styles))).font(.system(size: 12)).foregroundStyle(Theme.t2).lineLimit(1)
                Spacer()
            }
            Group {
                if let font { Text(sample).font(font) } else { Text(f.preview == nil ? L.t("find.preview.none") : sample).font(.system(size: f.preview == nil ? 12 : 24)).foregroundStyle(Theme.t2) }
            }.lineLimit(1).minimumScaleFactor(0.4).frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading).clipped()
            HStack(spacing: 8) {
                Text(L.t("lic." + f.license)).font(.system(size: 10.5)).padding(.horizontal, 7).padding(.vertical, 2).background(Theme.ok.opacity(0.15), in: Capsule()).foregroundStyle(Theme.ok).lineLimit(1)
                Text(f.portal).font(.system(size: 11)).foregroundStyle(Theme.t2).lineLimit(1)
                Spacer(minLength: 4)
                if installed { Label(L.t("find.installed"), systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(Theme.ok) }
                else if busy { ProgressView().controlSize(.small) }
                else { Button(L.t("find.install")) { dl.install(f) }.buttonStyle(.borderedProminent).tint(Theme.acc).controlSize(.small) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.r))
        .overlay(RoundedRectangle(cornerRadius: Theme.r).stroke(Theme.line, lineWidth: 1))
        .task { font = await RemotePreview.font(for: f, size: 26) }
    }
}

/// Disposition qui passe à la ligne : tous les portails restent visibles et cliquables.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 600, subviews).size
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(b.width, subviews)
        for (i, f) in r.frames.enumerated() { subviews[i].place(at: CGPoint(x: b.minX + f.minX, y: b.minY + f.minY), proposal: .unspecified) }
    }
    private func arrange(_ w: CGFloat, _ subs: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0, fr: [CGRect] = []
        for v in subs {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            fr.append(CGRect(x: x, y: y, width: s.width, height: s.height))
            x += s.width + spacing; rowH = max(rowH, s.height); maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), fr)
    }
}
