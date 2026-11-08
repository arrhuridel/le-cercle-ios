import Foundation
import WidgetKit

/// Côté app : dépose dans l'espace partagé les chiffres affichés par les widgets (mêmes calculs que l'accueil).
extension Magasin {
    func publierWidgets() {
        guard etat == .connecte || etat == .demo else { return }
        let r = resteReel, b = tableau(mode: .paie).b, ref = max(b.ref, 1)
        let d = Partage.Donnees(
            solde: r.solde, parJour: r.parJour, joursRestants: r.restants, finMois: r.finMois, finTexte: J.court(r.fin), part: r.part,
            besoins: b.bes / ref * 100, envies: b.env / ref * 100, epargne: b.epa / ref * 100,
            prochains: r.aVenir.prefix(3).map { .init(nom: $0.nom, montant: $0.montant, date: $0.detail) },
            misAJour: Date())
        Partage.ecrire(d)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
