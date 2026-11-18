import XCTest
@testable import Cercle

/// Le moteur de l'app doit retrouver les chiffres du site Python, qui est la référence (décision d'Arthur du 17/11/2026).
///
/// Données INVENTÉES : `donnees_python.json` est fabriqué par `site_web/fabriquer_reference.py`. Ne jamais le modifier à la main :
/// changer la règle dans `app.py`, relancer le script, puis corriger l'app jusqu'à ce que ces tests passent.
///
/// Mêmes vérifications que `web_app/tests/test_moteur.html`, pour chaque chiffre qui a un équivalent dans l'app :
/// loyers partagés, bilans (total et mois par mois), soldes, comptes, jours de paie, répartition du dernier mois,
/// totaux par thème (total et mois par mois), noms de marchands, dépenses par marchand,
/// et les cas pièges (loyer à 44, 46 et 45 jours avec changement d'heure ; virements programmés ; fin de cycle prévue).
/// Non repris ici (propres à la web app) : flux, liens entre opérations, statistiques, export CSV.
///
/// Un écart connu avec le site se marque par `XCTExpectFailure("raison")` en tête du test, en attendant sa correction.
final class ReferenceTests: XCTestCase {
    private struct CasLoyer: Decodable {
        let nom: String
        let phrase: String
        let operations: [Cercle.Operation]
        let attendu: [String: Bool]
    }
    private struct CasEcheance: Decodable {
        let nom: String
        let phrase: String
        let plan: Planifiee
        let operations: [Cercle.Operation]
        let auj: String
        let attendu: [String]
        let fin_cycle: String
        let a_venir: [String]
    }
    private struct Cas: Decodable {
        let loyers: [CasLoyer]
        let echeances: [CasEcheance]
    }
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
        let cas: Cas
        let regle_total: RegleRef
        let profil_b: ProfilB
    }
    private struct RegleRef: Decodable { let parts: [String: Double]; let alertes: [String] }
    /// Profil B (partie 3, 18/11/2026) : vit seul, règle 60-20-20, sans compte de placement.
    private struct ProfilB: Decodable {
        let reglages: Reglages
        let loyer_partage: [String: Bool]
        let bilan_total: [String: Double]
        let theme_total: [String: Double]
        let regle: RegleRef
    }

    private var ref: Reference!
    private var ops: [Cercle.Operation] = []
    private let tolerance = 0.006

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: ReferenceTests.self).url(forResource: "donnees_python", withExtension: "json"),
                                "donnees_python.json absent des ressources de test")
        ref = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        J.fixe = J.date(ref.auj)
        Calc.parametres = .defaut
        ops = Calc.marquerLoyers(ref.operations)
    }

    override func tearDown() {
        J.fixe = nil
        Calc.parametres = .defaut
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

    /// Total de chaque thème tel que les écrans le calculent (Calc.comptees), comme `compenser` du site puis un regroupement.
    private func parTheme(_ l: [Cercle.Operation]) -> [String: Double] {
        var m: [String: Double] = [:]
        for c in Calc.comptees(l) { m[c.sc, default: 0] += c.montant }
        return m
    }

    // MARK: Données de démo

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

    /// Comprend « Investissement » : la carte Trade Republic y est retirée de l'épargne (règle 8), comme sur le site.
    func testThemesSurToutLHistorique() {
        verifier(ecarts(parTheme(ops), ref.theme_total), "total par thème")
    }

    func testThemesMoisParMois() {
        let e = ref.theme_mois.keys.sorted().flatMap { m in ecarts(parTheme(duMois(m)), ref.theme_mois[m]!, prefixe: "\(m) ") }
        verifier(e, "thèmes de \(ref.theme_mois.count) mois")
    }

    func testNomsDeMarchands() {
        let mauvais = ops.filter { Analyse.nom($0) != ref.marchands[$0.id] }
        XCTAssertTrue(mauvais.isEmpty, "\(mauvais.count) nom(s) différent(s), ex. " +
                      Set(mauvais.map { "\(Analyse.nom($0)) au lieu de \(ref.marchands[$0.id] ?? "?")" }).sorted().prefix(3).joined(separator: " | "))
    }

    func testDepensesParMarchand() {
        var pm: [String: Double] = [:]
        for o in ops { let c = Calc.compense(o); if c.cat.estDepense { pm[Analyse.nom(o), default: 0] += c.montant } }
        verifier(ecarts(pm.filter { ref.marchand_depenses[$0.key] != nil }, ref.marchand_depenses), "dépenses par marchand")
    }

    // MARK: Calculs adaptés aux réponses (partie 3)

    private func partsEnTableau(_ rg: Calc.Regle) -> [String: Double] {
        [Cat.besoins.rawValue: rg.parts[.besoins] ?? 0, Cat.envies.rawValue: rg.parts[.envies] ?? 0, Cat.epargne.rawValue: rg.parts[.epargne] ?? 0]
    }

    func testRegleDuProfilPrincipal() {
        let rg = Calc.regle(Calc.bilan(ops))
        verifier(ecarts(partsEnTableau(rg), ref.regle_total.parts), "parts de la règle")
        XCTAssertEqual(rg.alertes, ref.regle_total.alertes)
    }

    func testProfilB() {
        let b = ref.profil_b
        Calc.parametres = Parametres(b.reglages)
        XCTAssertEqual(Calc.parametres.nom, "60-20-20")
        XCTAssertTrue(Calc.parametres.comptesPlacement.isEmpty, "aucun compte de placement")
        let opsB = Calc.marquerLoyers(ref.operations)
        XCTAssertFalse(opsB.contains { $0.loyerPartage }, "vit seul : aucun loyer partagé")
        XCTAssertTrue(opsB.allSatisfy { $0.loyerPartage == (b.loyer_partage[$0.id] ?? false) })
        verifier(ecarts(versTableau(Calc.bilan(opsB)), b.bilan_total), "profil B : bilan")
        verifier(ecarts(parTheme(opsB), b.theme_total), "profil B : thèmes")
        let rg = Calc.regle(Calc.bilan(opsB))
        verifier(ecarts(partsEnTableau(rg), b.regle.parts), "profil B : parts")
        XCTAssertEqual(rg.alertes, b.regle.alertes)
    }

    func testFichePartielleGardeLesDefauts() {
        let p = Parametres(Reglages(logement: .init(type: "seul", loyer_partage: false)))
        XCTAssertFalse(p.loyerPartage)
        XCTAssertEqual(p.nom, "50-30-20")
        XCTAssertEqual(p.comptesPlacement, ["Trade Republic"])
        XCTAssertTrue(Parametres(Reglages(banques: [])).comptesPlacement.isEmpty, "aucune banque : aucun placement")
        XCTAssertEqual(Parametres(nil), Parametres.defaut)
    }

    // MARK: Cas pièges

    func testCasLoyers() {
        for c in ref.cas.loyers {
            let faux = Calc.marquerLoyers(c.operations).filter { $0.loyerPartage != (c.attendu[$0.id] ?? false) }
            XCTAssertTrue(faux.isEmpty, "cas « \(c.nom) » : \(c.phrase)")
        }
    }

    func testCasEcheancesDues() {
        for c in ref.cas.echeances {
            let dues = Calc.echeancesDues(c.plan, c.operations, jusqua: c.auj).map { $0.date }
            XCTAssertEqual(dues, c.attendu, "cas « \(c.nom) » : \(c.phrase)")
        }
    }

    func testCasFinDeCyclePrevue() {
        for c in ref.cas.echeances {
            J.fixe = J.date(c.auj)
            let per = Calc.Periode(mode: .paie, debut: c.auj, fin: c.auj, finBudget: c.fin_cycle, precDebut: nil, precFin: nil, libelle: "")
            let rr = ResteReel(ops: c.operations, periode: per, revenusDuMois: 0, soldeInitial: 0, planifiees: [c.plan])
            let programmes = rr.aVenir.filter { $0.nom.hasPrefix("Virement vers") }
            XCTAssertEqual(programmes.count, c.a_venir.count, "cas « \(c.nom) » : virements programmés à venir avant la fin du cycle")
            XCTAssertEqual(programmes.reduce(0) { $0 + $1.montant }, Double(c.a_venir.count) * c.plan.montant, accuracy: tolerance)
            XCTAssertEqual(c.a_venir.compactMap { _ in Calc.prochaineEcheance(c.plan, apres: c.auj) }, c.a_venir,
                           "cas « \(c.nom) » : date de la prochaine échéance")
        }
    }
}
