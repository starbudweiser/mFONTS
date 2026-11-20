// mFONTS — catalogue des portails de polices gratuites : liste livrée avec l'appli + moteur de mise à jour automatique.
// La liste à jour est publiée dans le dépôt GitHub de mFONTS (Resources/portals.json) ; l'appli la lit une fois par jour.
import Foundation

struct Portal: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: String
    let kind: String          // « api » : recherche intégrée ; « web » : navigateur seulement
    let license: String       // ofl · commercial · mixed · personal
    var licenseKey: String { "lic." + license }
    var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
}

struct PortalFile: Codable, Sendable { let version: Int; let updated: String; let portals: [Portal] }

@MainActor
final class PortalCatalog: ObservableObject {
    static let shared = PortalCatalog()
    static let remote = URL(string: "https://raw.githubusercontent.com/starbudweiser/mFONTS/main/Resources/portals.json")!

    enum State: Equatable { case idle, updating, upToDate, updated(Int), failed }
    @Published private(set) var portals: [Portal] = []
    @Published private(set) var version = 0
    @Published private(set) var updated = ""
    @Published private(set) var state: State = .idle

    private var cacheURL: URL { Catalog.dataDir.appendingPathComponent("portals.json") }
    private var lastCheck: Date { get { UserDefaults.standard.object(forKey: "portalsCheck") as? Date ?? .distantPast } set { UserDefaults.standard.set(newValue, forKey: "portalsCheck") } }

    private init() {
        // Liste livrée avec l'appli, puis liste mise en cache si elle est plus récente.
        if let u = Bundle.main.url(forResource: "portals", withExtension: "json"), let f = Self.read(u) { apply(f) }
        if let f = Self.read(cacheURL), f.version > version { apply(f) }
    }

    private static func read(_ u: URL) -> PortalFile? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(PortalFile.self, from: d)
    }
    private func apply(_ f: PortalFile) { portals = f.portals; version = f.version; updated = f.updated }

    var apiPortals: [Portal] { portals.filter { $0.kind == "api" } }

    /// Recherche quotidienne (appelée au lancement et par la minuterie de l'appli).
    func tick() { if Date().timeIntervalSince(lastCheck) > 86_400 { Task { await update() } } }

    func update() async {
        guard state != .updating else { return }
        state = .updating
        do {
            var req = URLRequest(url: Self.remote); req.cachePolicy = .reloadIgnoringLocalCacheData; req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let f = try JSONDecoder().decode(PortalFile.self, from: data)
            // Une liste valide : au moins un portail, adresses https, identifiants uniques.
            guard !f.portals.isEmpty, f.portals.allSatisfy({ $0.url.hasPrefix("https://") }), Set(f.portals.map(\.id)).count == f.portals.count else { throw URLError(.cannotParseResponse) }
            lastCheck = Date()
            if f.version > version { try data.write(to: cacheURL, options: .atomic); apply(f); state = .updated(f.version) }
            else { state = .upToDate }
        } catch { state = .failed }
    }
}
