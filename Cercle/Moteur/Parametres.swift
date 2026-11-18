import Foundation

/// Fiche de réglages d'un profil (`profils.reglages`, réponses du questionnaire de la web app, partie 2 du 18/11/2026).
/// Seuls les champs utiles aux calculs sont lus ; lecture tolérante : une fiche incomplète ou mal formée ne bloque rien.
struct Reglages: Codable, Hashable {
    struct Logement: Codable, Hashable { var type: String?; var loyer_partage: Bool? }
    struct Regle: Codable, Hashable { var besoins: Double; var envies: Double; var epargne: Double }
    struct Banque: Codable, Hashable { var banque: String?; var nom: String?; var role: String? }
    var questionnaire_fait: Bool?
    var logement: Logement?
    var regle: Regle?
    var banques: [Banque]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionnaire_fait = try? c.decodeIfPresent(Bool.self, forKey: .questionnaire_fait)
        logement = try? c.decodeIfPresent(Logement.self, forKey: .logement)
        regle = try? c.decodeIfPresent(Regle.self, forKey: .regle)
        banques = try? c.decodeIfPresent([Banque].self, forKey: .banques)
    }
    init(logement: Logement? = nil, regle: Regle? = nil, banques: [Banque]? = nil) {
        self.logement = logement; self.regle = regle; self.banques = banques
    }
}

/// Paramètres de calcul de la personne connectée (partie 3 du 18/11/2026), mêmes règles que `parametres_de` du site (app.py)
/// et `parametresDe` de la web app (parametres.js). Ce qui manque garde la règle actuelle : loyer partagé, 50-30-20,
/// tolérance de 5 points, Trade Republic en compte de placement.
struct Parametres: Hashable {
    var loyerPartage = true
    var cibles: [Cat: Double] = [.besoins: 50, .envies: 30, .epargne: 20]
    var tolerance = 5.0
    var comptesPlacement: Set<String> = ["Trade Republic"]

    static let defaut = Parametres()

    init() {}
    init(_ r: Reglages?) {
        guard let r else { return }
        if let l = r.logement { loyerPartage = l.loyer_partage == true }
        if let g = r.regle { cibles = [.besoins: g.besoins, .envies: g.envies, .epargne: g.epargne] }
        if let b = r.banques { comptesPlacement = Set(b.filter { $0.role == "placements" }.map { $0.nom ?? "" }) }
    }

    /// « 50-30-20 », « 60-20-20 »…
    var nom: String { [Cat.besoins, .envies, .epargne].map { String(Int((cibles[$0] ?? 0).rounded())) }.joined(separator: "-") }
}
