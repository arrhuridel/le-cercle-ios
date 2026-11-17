import XCTest
@testable import Cercle

/// Le moteur de l'app doit retrouver les chiffres du site Python, qui est la référence (décision d'Arthur du 17/11/2026).
///
/// Données INVENTÉES : `donnees_python.json` est fabriqué par `site_web/fabriquer_reference.py`. Ne jamais le modifier à la main :
/// changer la règle dans `app.py`, relancer le script, puis corriger l'app jusqu'à ce que ces tests passent.
///
/// Mêmes vérifications que `web_app/tests/test_moteur.html`, pour chaque chiffre qui a un équivalent dans l'app :
/// loyers partagés, bilans (total et mois par mois), soldes, comptes, jours de paie, répartition du dernier mois,
/// totaux par thème (total et mois par mois), noms de marchands, dépenses par marchand.
/// Non repris ici (propres à la web app) : flux, liens entre opérations, statistiques, export CSV.
///
/// Un `XCTExpectFailure` marque un écart déjà connu avec le site, à corriger à l'étape 3 de la piste A.
/// Quand l'écart est corrigé, le test le signale (« attendu en échec, mais passe ») : retirer alors la ligne.
final class ReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        let auj: String
        let operations: [Cercle.Operation]
        let loyer_partage: [String: Bool]
        let bilan_total: [String: Double]
        let bilans_mois: [String: [String: Double]]
        let solde_courant: Double
        let solde_revolut: Double
        let jours_de_paie: [String]
        let repartition_mois_courant: [String: Double]
        let comptes: [String]
        let theme_total: [String: Double]
        let theme_mois: [String: [String: Double]]
        let marchands: [String: String]
        let marchand_depenses: [String: Double]
    }

    private var ref: Reference!
    private var ops: [Cercle.Operation] = []
    private let tolerance = 0.006
    private static let ecartMarchands = "Étape 3 : l'app n'a pas les alias de marchands du site (ex. « mcdo » devient « McDonald's » sur le site)."
    private static let ecartCarteTR = "Étape 3 (piste B) : le site retire de l'épargne « Investissement » ce qui est payé avec la carte Trade Republic ; l'app ne le fait que dans le bilan."

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: ReferenceTests.self).url(forResource: "donnees_python", withExtension: "json"),
                                "donnees_python.json absent des ressources de test")
        ref = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        J.fixe = J.date(ref.auj)
        ops = Calc.marquerLoyers(ref.operations)
    }

    override func tearDown() {
        J.fixe = nil
        super.tearDown()
    }

    // MARK: Outils

    private func proche(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }

    /// Les écarts entre deux tableaux de montants (une clé absente vaut 0).
    private func ecarts(_ obtenu: [String: Double], _ attendu: [String: Double], prefixe: String = "") -> [String] {
        Set(obtenu.keys).union(attendu.keys).sorted().compactMap { k in
            let a = obtenu[k] ?? 0, b = attendu[k] ?? 0
            return proche(a, b) ? nil : "\(prefixe)\(k) : \(String(format: "%.2f", a)) au lieu de \(String(format: "%.2f", b))"
        }
    }

    private func verifier(_ e: [String], _ quoi: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.isEmpty, "\(quoi) : \(e.count) écart(s), ex. " + e.prefix(5).joined(separator: " | "), file: file, line: line)
    }

    private func versTableau(_ b: Calc.Bilan) -> [String: Double] {
        [Cat.revenu.rawValue: b.rev, Cat.besoins.rawValue: b.bes, Cat.envies.rawValue: b.env, Cat.epargne.rawValue: b.epa,
         "depenses": b.dep, "reste": b.reste, "reference": b.ref]
    }

    private func duMois(_ mois: String) -> [Cercle.Operation] { Calc.entre(ops, mois + "-01", mois + "-31") }

    /// Total de chaque thème après compensation, comme `compenser` du site puis un regroupement par thème.
    private func parTheme(_ l: [Cercle.Operation]) -> [String: Double] {
        var m: [String: Double] = [:]
        for o in l { let c = Calc.compense(o); m[c.sc, default: 0] += c.montant }
        return m
    }

    private func sans(_ t: [String: Double], _ cle: String) -> [String: Double] { t.filter { $0.key != cle } }

    // MARK: Règles

    func testLoyersPartages() {
        let diff = ops.filter { $0.loyerPartage != (ref.loyer_partage[$0.id] ?? false) }
        XCTAssertTrue(diff.isEmpty, "\(diff.count) loyer(s) marqué(s) autrement que sur le site, ex. \(diff.prefix(3).map(\.date))")
    }

    func testBilanTotal() {
        verifier(ecarts(versTableau(Calc.bilan(ops)), ref.bilan_total), "bilan sur tout l'historique")
    }

    func testBilansMoisParMois() {
        let e = ref.bilans_mois.keys.sorted().flatMap { m in ecarts(versTableau(Calc.bilan(duMois(m))), ref.bilans_mois[m]!, prefixe: "\(m) ") }
        verifier(e, "bilans de \(ref.bilans_mois.count) mois")
    }

    func testSoldes() {
        XCTAssertEqual(Calc.solde(ops, "", jusqua: ref.auj), ref.solde_courant, accuracy: tolerance, "solde du compte courant")
        XCTAssertEqual(Calc.solde(ops, "Revolut", jusqua: ref.auj), ref.solde_revolut, accuracy: tolerance, "solde Revolut")
    }

    func testComptes() {
        XCTAssertEqual(Calc.comptes(ops), ref.comptes)
    }

    func testJoursDePaie() {
        XCTAssertEqual(Calc.joursDePaie(ops), ref.jours_de_paie)
    }

    func testRepartitionDuDernierMois() throws {
        let mois = try XCTUnwrap(ref.bilans_mois.keys.max())
        let rep = Dictionary(Calc.repartition(duMois(mois)).map { ($0.sc, $0.v) }, uniquingKeysWith: +)
        verifier(ecarts(rep, ref.repartition_mois_courant), "répartition des dépenses (\(mois))")
    }

    func testThemesSurToutLHistorique() {
        verifier(ecarts(sans(parTheme(ops), "Investissement"), sans(ref.theme_total, "Investissement")), "total par thème")
    }

    func testThemesMoisParMois() {
        let e = ref.theme_mois.keys.sorted().flatMap { m in
            ecarts(sans(parTheme(duMois(m)), "Investissement"), sans(ref.theme_mois[m]!, "Investissement"), prefixe: "\(m) ")
        }
        verifier(e, "thèmes de \(ref.theme_mois.count) mois")
    }

    func testThemeInvestissement() {
        XCTExpectFailure(Self.ecartCarteTR)
        verifier(ecarts(["Investissement": parTheme(ops)["Investissement"] ?? 0], ["Investissement": ref.theme_total["Investissement"] ?? 0]),
                 "thème Investissement")
    }

    func testNomsDeMarchands() {
        XCTExpectFailure(Self.ecartMarchands)
        let mauvais = ops.filter { Analyse.marchand($0) != ref.marchands[$0.id] }
        XCTAssertTrue(mauvais.isEmpty, "\(mauvais.count) nom(s) différent(s), ex. " +
                      Set(mauvais.map { "\(Analyse.marchand($0)) au lieu de \(ref.marchands[$0.id] ?? "?")" }).sorted().prefix(3).joined(separator: " | "))
    }

    func testDepensesParMarchand() {
        XCTExpectFailure(Self.ecartMarchands)
        var pm: [String: Double] = [:]
        for o in ops { let c = Calc.compense(o); if c.cat.estDepense { pm[Analyse.marchand(o), default: 0] += c.montant } }
        verifier(ecarts(pm.filter { ref.marchand_depenses[$0.key] != nil }, ref.marchand_depenses), "dépenses par marchand")
    }
}
