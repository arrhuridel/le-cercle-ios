import Foundation

/// « Il te reste » = SOLDE RÉEL du compte courant, comme la banque (choix d'Arthur du 08/11/2026).
/// Le détail retrace ce solde depuis la paie, au centime : solde la veille de la paie + salaire et CAF + autres entrées
/// − dépenses (loyer en entier : c'est ce qui sort du compte) − épargne sortie du compte = solde d'aujourd'hui.
/// Fin du mois = solde − prélèvements encore à venir − dépenses courantes au rythme actuel sur les jours restants.
struct ResteReel {
    struct Ligne: Hashable, Identifiable { var nom: String; var montant: Double; var detail = ""; var id: String { nom + detail } }
    struct Famille: Hashable, Identifiable { var nom: String; var total: Double; var cats: [Ligne]; var id: String { nom } }

    var debut: String, fin: String
    var solde = 0.0, avant = 0.0
    var recus: [Ligne] = [], autres: [Ligne] = [], depenses: [Famille] = [], epargne: [Ligne] = []
    var aVenir: [Ligne] = []          // detail = date « 11 nov. »
    var rythme = 0.0, joursApres = 0, restants = 1, nbDepenses = 0
    var objectifEpargne = 0.0

    var totalRecus: Double { recus.reduce(0) { $0 + $1.montant } }
    var totalAutres: Double { autres.reduce(0) { $0 + $1.montant } }
    var totalDepenses: Double { depenses.reduce(0) { $0 + $1.total } }
    var totalEpargne: Double { epargne.reduce(0) { $0 + $1.montant } }
    var totalAVenir: Double { aVenir.reduce(0) { $0 + $1.montant } }
    var courantesAVenir: Double { rythme * Double(joursApres) }
    var finMois: Double { solde - totalAVenir - courantesAVenir }
    /// Ce que tu peux vraiment dépenser par jour : solde moins les prélèvements à venir, sur les jours restants.
    var parJour: Double { (solde - totalAVenir) / Double(max(restants, 1)) }
    /// Part de l'argent du mois déjà sortie (solde d'avant + entrées).
    var part: Double { let dispo = avant + recus.reduce(0) { $0 + max($1.montant, 0) } + autres.reduce(0) { $0 + max($1.montant, 0) }; return dispo > 0 ? min(100, max(0, (dispo - solde) / dispo * 100)) : 0 }

    static let libellesAutres = ["Remboursement loyer": "Remboursement du loyer (coloc)", "Retrait d'épargne": "Retrait d'un livret",
                                 "Virement interne": "Virements entre tes comptes", "Remboursement": "Remboursements", "Cadeau reçu": "Cadeaux reçus"]

    init(ops: [Operation], periode: Calc.Periode, revenusDuMois: Double, soldeInitial: Double) {
        debut = periode.debut; fin = periode.finBudget
        let auj = J.auj
        let cc = ops.filter { $0.date <= auj }.map { (o: $0, e: (Calc.effet($0, "") * 100).rounded() / 100) }.filter { abs($0.e) > 0.004 }
        avant = soldeInitial + cc.filter { $0.o.date < debut }.reduce(0) { $0 + $1.e }
        let cycle = cc.filter { $0.o.date >= debut }
        solde = avant + cycle.reduce(0) { $0 + $1.e }

        let estRef = { (o: Operation) in o.cat == .revenu && Ref.revenusReference.contains(o.sc) }
        let ref = cycle.filter { estRef($0.o) && $0.e > 0 }
        var parSource: [String: (Double, String)] = [:]
        for x in ref {
            let nom = x.o.sc == "Bourse & aides" ? "CAF" : x.o.sc == "Salaire" ? "Salaire · \(Calc.source(x.o))" : x.o.sc
            parSource[nom] = ((parSource[nom]?.0 ?? 0) + x.e, max(parSource[nom]?.1 ?? "", x.o.date))
        }
        recus = parSource.map { Ligne(nom: $0.key, montant: $0.value.0, detail: J.court($0.value.1)) }.sorted { ($0.nom == "CAF" ? 1 : 0, -$0.montant) < ($1.nom == "CAF" ? 1 : 0, -$1.montant) }

        let dep = cycle.filter { $0.o.cat == .besoins || $0.o.cat == .envies }
        nbDepenses = dep.count
        depenses = [(Cat.besoins, "Besoins"), (.envies, "Envies")].map { cat, nom in
            let l = dep.filter { $0.o.cat == cat }
            let parSc = Dictionary(grouping: l, by: { $0.o.sc }).mapValues { -$0.reduce(0) { $0 + $1.e } }
            return Famille(nom: nom, total: -l.reduce(0) { $0 + $1.e }, cats: parSc.filter { abs($0.value) >= 0.005 }.map { Ligne(nom: $0.key, montant: $0.value) }.sorted { $0.montant > $1.montant })
        }
        let epa = cycle.filter { $0.o.cat == .epargne }
        epargne = Dictionary(grouping: epa, by: { $0.o.sc }).mapValues { -$0.reduce(0) { $0 + $1.e } }.filter { abs($0.value) >= 0.005 }
            .map { Ligne(nom: $0.key == "Investissement" ? "Trade Republic" : $0.key, montant: $0.value) }.sorted { $0.montant > $1.montant }
        let resteOps = cycle.filter { !(estRef($0.o) && $0.e > 0) && $0.o.cat != .besoins && $0.o.cat != .envies && $0.o.cat != .epargne }
        autres = Dictionary(grouping: resteOps, by: { $0.o.sc }).mapValues { $0.reduce(0) { $0 + $1.e } }.filter { abs($0.value) >= 0.005 }
            .map { Ligne(nom: Self.libellesAutres[$0.key] ?? $0.key, montant: $0.value) }.sorted { $0.montant > $1.montant }

        // Prélèvements du compte courant encore à venir avant la fin du cycle (pas encore payés depuis la paie)
        let c = J.comp(J.aujourdhui)
        for p in Prelevements.liste(ops) where p.compte.isEmpty {
            let deja = cycle.contains { $0.o.sc == p.sc && (abs($0.o.montant - p.montant) < 1 || abs($0.o.montant - 2 * p.montant) < 1) }
            if deja { continue }
            var d = J.iso(J.faire(c.a, c.m, p.jour))
            if d <= auj { d = J.iso(J.faire(c.a, c.m + 1, p.jour)) }
            if d <= fin { aVenir.append(Ligne(nom: p.nom, montant: p.montant, detail: d)) }
        }
        aVenir = aVenir.sorted { $0.detail < $1.detail }.map { Ligne(nom: $0.nom, montant: $0.montant, detail: J.court($0.detail)) }
        let passes = max(J.ecart(debut, auj) + 1, 1)
        restants = max(J.ecart(auj, fin) + 1, 1); joursApres = max(J.ecart(auj, fin), 0)
        let courantes = dep.filter { !Ref.chargesFixes.contains($0.o.sc) }.reduce(0) { $0 - $1.e }
        rythme = courantes / Double(passes)
        // 20 % des revenus de référence du mois : salaire, CAF, aide familiale (demande du 12/11, même base que besoins et envies)
        objectifEpargne = (revenusDuMois * 0.20 * 100).rounded() / 100
    }
}

extension Magasin {
    /// Toujours sur le cycle de paie. Gardé en mémoire tant que les données ne changent pas
    /// (il est lu par le Résumé à chaque affichage).
    var resteReel: ResteReel {
        memo("resteReel") {
            let t = tableau(mode: .paie)
            return ResteReel(ops: ops, periode: t.per, revenusDuMois: t.b.ref, soldeInitial: soldesInitiaux[""] ?? 0)
        }
    }
}
