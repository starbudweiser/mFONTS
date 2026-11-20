// mFONTS — identifiants des portails : mots de passe dans le Trousseau macOS (jamais dans mFONTS), capture, remplissage, sessions.
import Foundation
import Security
import LocalAuthentication
import WebKit

struct VaultAccount: Identifiable, Hashable {
    let host: String, user: String, label: String, date: Date?
    var id: String { host + "|" + user }
}

/// Trousseau de connexion (éléments « mot de passe Internet »). Le mot de passe n'est lu qu'au moment de remplir.
enum PortalVault {
    private static var domain: String { Bundle.main.bundleIdentifier ?? "fr.stephan.mfonts" }     // sépare la version de dev de la version installée

    static func normal(_ host: String) -> String { host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)).lowercased() : host.lowercased() }

    private static func base(_ host: String? = nil, _ user: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassInternetPassword, kSecAttrSecurityDomain as String: domain,
                                kSecAttrSynchronizable as String: false, kSecAttrProtocol as String: kSecAttrProtocolHTTPS]
        if let host { q[kSecAttrServer as String] = host }
        if let user { q[kSecAttrAccount as String] = user }
        return q
    }

    static func list(host: String? = nil) -> [VaultAccount] {
        var q = base(host); q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let arr = out as? [[String: Any]] else { return [] }
        return arr.compactMap { a in
            guard let h = a[kSecAttrServer as String] as? String, let u = a[kSecAttrAccount as String] as? String else { return nil }
            return VaultAccount(host: h, user: u, label: a[kSecAttrLabel as String] as? String ?? h, date: a[kSecAttrModificationDate as String] as? Date)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    @discardableResult
    static func save(host: String, user: String, password: String, label: String) -> Bool {
        guard !host.isEmpty, !password.isEmpty, let data = password.data(using: .utf8) else { return false }
        let q = base(host, user)
        let upd = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data, kSecAttrLabel as String: label] as CFDictionary)
        if upd == errSecSuccess { return true }
        var add = q; add[kSecValueData as String] = data; add[kSecAttrLabel as String] = label
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Lit le mot de passe ; avec « exiger Touch ID », l'utilisateur s'authentifie d'abord (Touch ID ou mot de passe du Mac).
    static func password(host: String, user: String, reason: String) async -> String? {
        if Prefs.vaultTouch {
            let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in c.resume(returning: ok) }
            }
            if !ok { return nil }
        }
        var q = base(host, user); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func forget(host: String, user: String) { SecItemDelete(base(host, user) as CFDictionary) }

    // Sites pour lesquels l'utilisateur a choisi « Jamais ».
    static var never: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "vaultNever") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "vaultNever") }
    }
}

extension Prefs {
    static var vaultOffer: Bool { UserDefaults.standard.object(forKey: "vaultOffer") as? Bool ?? true }
    static var vaultTouch: Bool { UserDefaults.standard.object(forKey: "vaultTouch") as? Bool ?? true }
}

/// Sessions conservées par portail : magasin de données persistant propre au portail, sinon navigation isolée.
enum PortalSession {
    static func keeps(_ id: String) -> Bool { UserDefaults.standard.bool(forKey: "keepSession_" + id) }
    static func setKeeps(_ id: String, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "keepSession_" + id)
        if !on { clear(id) }
    }
    private static func uuid(_ id: String) -> UUID {
        let k = "sessionUUID_" + id
        if let s = UserDefaults.standard.string(forKey: k), let u = UUID(uuidString: s) { return u }
        let u = UUID(); UserDefaults.standard.set(u.uuidString, forKey: k); return u
    }
    @MainActor static func store(_ id: String) -> WKWebsiteDataStore { keeps(id) ? WKWebsiteDataStore(forIdentifier: uuid(id)) : .nonPersistent() }
    static func clear(_ id: String) {
        guard let s = UserDefaults.standard.string(forKey: "sessionUUID_" + id), let u = UUID(uuidString: s) else { return }
        Task { @MainActor in
            let st = WKWebsiteDataStore(forIdentifier: u)
            await st.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }
}

/// Script injecté dans la page (monde isolé, cadre principal) : repère le formulaire de connexion, capte l'envoi, remplit.
enum CredentialScript {
    static let source = """
    (function(){
      if (window.__mfCred) return; window.__mfCred = true;
      var post = function(o){ try { window.webkit.messageHandlers.mfCred.postMessage(o); } catch(e) {} };
      var vis = function(e){ var r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      function pwFields(){ return Array.prototype.filter.call(document.querySelectorAll('input[type=password]'), vis); }
      function userFor(p){
        var scope = p.form || document, best = null;
        var all = scope.querySelectorAll('input[type=email],input[type=text],input[type=tel],input:not([type])');
        for (var i = 0; i < all.length; i++) { var e = all[i]; if (vis(e) && (e.compareDocumentPosition(p) & 4)) best = e; }
        return best;
      }
      function grab(){
        var p = pwFields().filter(function(x){ return x.value; })[0]; if (!p) return null;
        var u = userFor(p); return { user: u ? u.value : '', pass: p.value };
      }
      function send(){ var g = grab(); if (g && g.pass) post({kind:'submit', user:g.user, pass:g.pass}); }
      document.addEventListener('submit', send, true);
      document.addEventListener('click', function(e){
        var t = e.target && e.target.closest ? e.target.closest('button,input[type=submit],[role=button],a') : null;
        if (t && pwFields().length) send();
      }, true);
      document.addEventListener('keydown', function(e){ if (e.key === 'Enter' && e.target && e.target.type === 'password') send(); }, true);
      var last = null, timer = null;
      function report(){ var h = pwFields().length > 0; if (h !== last) { last = h; post({kind:'form', has:h}); } }
      new MutationObserver(function(){ clearTimeout(timer); timer = setTimeout(report, 250); }).observe(document.documentElement, {childList:true, subtree:true});
      report();
      window.__mfFill = function(u, p){
        var pe = pwFields()[0]; if (!pe) return false;
        var set = function(el, v){
          var d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value'); d.set.call(el, v);
          el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true}));
        };
        var ue = userFor(pe); if (ue && u) set(ue, u); set(pe, p); return true;
      };
      window.__mfGrab = grab;
    })();
    """
}
