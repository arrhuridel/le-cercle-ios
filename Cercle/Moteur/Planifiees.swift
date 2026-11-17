import Foundation

/// Virements programmés (règle 9) : mêmes calculs que le site (`echeances_dues` dans app.py) et la web app (`echeancesDues`,
/// `prochaineEcheance` dans epargne.js). Fonctions pures, sans la base : testées par CercleTests.
extension Calc {
    /// Échéances arrivées à terme (jusqu'à `jusqua` inclus) et pas encore enregistrées : [(date, clé)].
    /// La première tombe au jour prévu du mois de départ, jamais avant la date de départ (décision d'Arthur du 17/11/2026).
    /// Le jour 30 tombe le 28 ou le 29 en février. Une échéance est déjà là si une opération porte sa clé
    /// « plan:<id>:<AAAA-MM> », ou si son mois contient la même opération saisie à la main
    /// (même thème, même compte d'arrivée, montant à ±20 %).
    static func echeancesDues(_ p: Planifiee, _ ops: [Operation], jusqua: String) -> [(date: String, cle: String)] {
        let depuis = String(p.depuis.prefix(10)), vers = p.vers ?? ""
        let cles = Set(ops.compactMap(\.idBanque))
        let moisPris = Set(ops.filter { o in
            o.sc == p.sc && (vers.isEmpty || (o.vers ?? "") == vers) && abs(o.montant - p.montant) <= max(p.montant * 0.2, 1)
        }.map { String($0.date.prefix(7)) })
        let c = J.comp(J.date(depuis))
        var res: [(date: String, cle: String)] = []
        for k in 0..<24 {
            let d = J.iso(J.faire(c.a, c.m + k, p.jour))
            if d > jusqua { break }
            let mois = String(d.prefix(7)), cle = "plan:\(p.id):\(mois)"
            if d >= depuis && !cles.contains(cle) && !moisPris.contains(mois) { res.append((d, cle)) }
        }
        return res
    }

    /// La prochaine échéance strictement après `apres` (pour la fin de cycle prévue), ou nil dans les 3 mois.
    static func prochaineEcheance(_ p: Planifiee, apres: String) -> String? {
        let depuis = String(p.depuis.prefix(10)), c = J.comp(J.date(apres))
        for k in 0..<3 {
            let d = J.iso(J.faire(c.a, c.m + k, p.jour))
            if d > apres && d >= depuis { return d }
        }
        return nil
    }
}
