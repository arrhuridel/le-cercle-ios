import Foundation
import WidgetKit

/// Côté app : calcule les chiffres des widgets (mêmes règles que l'aperçu du 08/11) et les dépose dans l'espace partagé.
extension Magasin {
    func publierWidgets() {
        guard etat == .connecte || etat == .demo else { return }
        let t = tableau(mode: .paie)
        let debut = t.per.debut, fin = t.per.finBudget, auj = J.auj
        let cc = toutes.filter { $0.date <= auj }
        // Solde réel du compte courant (comme la banque)
        let solde = Calc.solde(cc, "", jusqua: auj, initial: soldesInitiaux[""] ?? 0)
        let avant = Calc.solde(cc, "", jusqua: J.plus(debut, jours: -1), initial: soldesInitiaux[""] ?? 0)
        let cycle = cc.filter { $0.date >= debut }
        let entrees = cycle.map { Calc.effet($0, "") }.filter { $0 > 0 }.reduce(0, +)
        let dispo = avant + entrees
        // Prélèvements du compte courant encore à venir avant la fin du cycle (pas encore payés depuis la paie)
        var aVenir: [(nom: String, montant: Double, date: String)] = []
        for p in Prelevements.liste(toutes) where p.compte.isEmpty || p.compte == "Compte courant" {
            let dejaPaye = cycle.contains { $0.sc == p.sc && (abs($0.montant - p.montant) < 1 || abs($0.montant - 2 * p.montant) < 1) }
            if dejaPaye { continue }
            let c = J.comp(J.aujourdhui)
            var d = J.iso(J.faire(c.a, c.m, p.jour))
            if d <= auj { d = J.iso(J.faire(c.a, c.m + 1, p.jour)) }
            if d <= fin { aVenir.append((p.nom, p.montant, d)) }
        }
        aVenir.sort { $0.date < $1.date }
        let totalAVenir = aVenir.reduce(0) { $0 + $1.montant }
        // Dépenses courantes (hors charges fixes) au rythme actuel, sur les jours qui restent après aujourd'hui
        let passes = max(J.ecart(debut, auj) + 1, 1), restants = max(J.ecart(auj, fin) + 1, 1)
        let courantes = cycle.filter { $0.cat.estDepense && !Ref.chargesFixes.contains($0.sc) && $0.compte.isEmpty }.reduce(0) { $0 + $1.montant }
        let rythme = courantes / Double(passes)
        let ref = max(t.b.ref, 1)
        let d = Partage.Donnees(
            solde: solde,
            parJour: (solde - totalAVenir) / Double(restants),
            joursRestants: restants,
            finMois: solde - totalAVenir - rythme * Double(restants - 1),
            finTexte: J.court(fin),
            part: dispo > 0 ? min(100, max(0, (dispo - solde) / dispo * 100)) : 0,
            besoins: t.b.bes / ref * 100, envies: t.b.env / ref * 100, epargne: t.b.epa / ref * 100,
            prochains: aVenir.prefix(3).map { .init(nom: $0.nom, montant: $0.montant, date: J.court($0.date)) },
            misAJour: Date())
        Partage.ecrire(d)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
