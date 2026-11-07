import Foundation

/// Prélèvements qui reviennent chaque mois, comme l'aperçu v3 validé par Arthur le 07/11/2026 :
/// - un même service noté de plusieurs façons ne compte qu'une fois (noms unifiés) ;
/// - actif s'il a été payé il y a moins de 45 jours ; montant = dernier paiement (les prix changent) ;
/// - facture variable (électricité) : moyenne des 3 derniers ; loyer partagé : ta moitié ;
/// - certains abonnements ont une date de fin connue (la salle s'arrête en décembre 2026).
enum Prelevements {
    struct Prelevement: Identifiable, Hashable {
        var nom: String, montant: Double, jour: Int, sc: String, compte: String
        var estAbonnement: Bool       // « Abonnements » ; le reste (loyer, factures, assurances, frais) est une charge
        var infos: String
        var id: String { nom }
    }

    /// Un même service écrit de plusieurs façons dans les notes (relevé lors de l'audit du 07/11).
    static let alias: [String: String] = [
        "icloud+": "iCloud+", "icloud": "iCloud+",
        "apple music": "Apple Music", "apple musique": "Apple Music",
        "google one": "Google One (Gemini)", "paiement cb google one": "Google One (Gemini)", "gemini pro": "Google One (Gemini)",
        "claude": "Claude (Anthropic)", "anthropic": "Claude (Anthropic)",
        "gmf": "GMF assurance auto", "gmf (assurance auto)": "GMF assurance auto", "auto": "GMF assurance auto",
        "uber eat": "Uber One", "uber one": "Uber One",
        "cap residentiel": "Loyer", "loyer": "Loyer",
        "cotisation eurocompte jeune": "Cotisation bancaire", "frais cotisation banque": "Cotisation bancaire",
    ]
    /// Abonnements qui s'arrêtent à une date connue : (année, mois) du dernier paiement.
    static let fins: [String: (Int, Int)] = ["Fitness Océane": (2026, 12)]

    static func service(_ o: Operation) -> String {
        let brut = Analyse.marchand(o)
        return alias[brut.sansAccents.lowercased().trimmingCharacters(in: .whitespaces)] ?? brut
    }

    static func liste(_ ops: [Operation]) -> [Prelevement] {
        let a = J.auj, limite = J.plus(a, jours: -400), c = J.comp(J.aujourdhui)
        var groupes: [String: [Operation]] = [:]
        for o in ops where Ref.chargesFixes.contains(o.sc) && o.date <= a && o.date > limite && o.partage == nil {
            groupes[service(o), default: []].append(o)
        }
        var res: [Prelevement] = []
        for (nom, l0) in groupes {
            let l = l0.sorted { $0.date < $1.date }
            guard let der = l.last, J.ecart(der.date, a) <= 45 else { continue }   // arrêté
            if let f = fins[nom], (c.a, c.m) > f { continue }                      // terminé
            let sc = Dictionary(grouping: l, by: \.sc).max { $0.value.count < $1.value.count }?.key ?? der.sc
            var montant = der.montant, affiche = nom
            if sc == "Factures" && Set(l.map(\.montant)).count > 2 { montant = l.suffix(3).map(\.montant).reduce(0, +) / Double(min(l.count, 3)) }
            if sc == "Loyer" && der.loyerPartage { affiche = "Loyer (ta part)"; montant = der.montant / 2 }
            let prix = l.map { ($0.montant * 100).rounded() / 100 }
            // Ancien prix : un prix différent payé au moins deux fois (évite les frais ponctuels)
            let dernierPrix = prix.last ?? 0
            let avant = prix.dropLast().reversed().first { candidat in abs(candidat - dernierPrix) > 0.01 && prix.filter { $0 == candidat }.count >= 2 }
            let premier = J.comp(J.date(l[0].date))
            var infos = "depuis \(J.moisCourts[premier.m - 1]) \(premier.a) · \(l.count) paiement\(l.count > 1 ? "s" : "")"
            if let avant, sc != "Factures", sc != "Loyer" { infos += " · avant \(Fmt.eur(avant))" }
            if l.count == 1 { infos += " · nouveau" }
            if let f = fins[nom] { infos += " · s'arrête en \(J.mois[f.1 - 1]) \(f.0)" }
            res.append(Prelevement(nom: affiche, montant: (montant * 100).rounded() / 100, jour: J.comp(J.date(der.date)).j, sc: sc,
                                   compte: der.compte, estAbonnement: sc == "Abonnements", infos: infos))
        }
        return res.sorted { ($0.jour, $0.nom) < ($1.jour, $1.nom) }
    }
}
