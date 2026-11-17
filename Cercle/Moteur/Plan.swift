import Foundation

/// Plan de virements d'Arthur (validé le 15/11/2026) : un compte par rôle, un montant par mois, suivi depuis la paie.
///  - Crédit Mutuel = besoins, Revolut = envies, BoursoBank = voiture, Trade Republic = épargne (PEA), Livret Bleu = apport.
///  - Ce sont les THÈMES qui comptent, pas la carte utilisée : un achat payé avec la mauvaise carte reste dans la bonne poche.
///  - Tout repart à zéro à chaque paie (pas de report d'un mois sur l'autre).
/// Même règle que la web app (`site_web/web_app/js/enveloppes.js`) et l'aperçu validé (`imports/apercu_ios`).
enum Plan {
    struct Poche: Identifiable, Hashable {
        let id: String
        let nom: String
        let compte: String        // clé du compte en base ("" = compte courant Crédit Mutuel)
        let banque: String
        let logo: String          // image du catalogue (Assets.xcassets)
        let teinte: (Double, Double, Double)
        let defaut: Double
        let quoi: String
        let epargne: Bool
        static func == (a: Poche, b: Poche) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    static let poches: [Poche] = [
        Poche(id: "besoins", nom: "Besoins", compte: "", banque: "Crédit Mutuel", logo: "LogoCM", teinte: (0.55, 0.56, 0.84), defaut: 880,
              quoi: "loyer, assurance, abonnements, courses", epargne: false),
        Poche(id: "envies", nom: "Envies", compte: "Revolut", banque: "Revolut", logo: "LogoRevolut", teinte: (0.77, 0.80, 0.83), defaut: 300,
              quoi: "sorties, shopping, loisirs", epargne: false),
        Poche(id: "voiture", nom: "Voiture", compte: "Boursobank", banque: "BoursoBank", logo: "LogoBourso", teinte: (0.84, 0.53, 0.68), defaut: 150,
              quoi: "essence et réparations", epargne: false),
        Poche(id: "epargne", nom: "Épargne", compte: "Trade Republic", banque: "Trade Republic", logo: "LogoTR", teinte: (0.53, 0.79, 0.65), defaut: 120,
              quoi: "PEA et espèces", epargne: true),
    ]
    static let apport = Poche(id: "apport", nom: "Apport immobilier", compte: "", banque: "Crédit Mutuel", logo: "LogoCM", teinte: (0.79, 0.54, 0.57),
                              defaut: 250, quoi: "Livret Bleu + Livret Jeune", epargne: true)
    static let objectifDefaut = 13_000.0

    /// Montants du plan, modifiables dans les réglages (clés « plan.besoins », « plan.apport », « plan.objectif »…).
    static func montant(_ id: String) -> Double {
        let d = UserDefaults.standard, cle = "plan.\(id)"
        if d.object(forKey: cle) != nil { return max(d.double(forKey: cle), 0) }
        if id == "objectif" { return objectifDefaut }
        return (poches + [apport]).first { $0.id == id }?.defaut ?? 0
    }

    /// Essence : thème Transport payé à une station (pas le bus ni le train).
    static func estEssence(_ o: Operation, _ c: Operation) -> Bool {
        guard c.sc == "Transport" else { return false }
        if Analyse.marchand(o) == "Carburant" { return true }
        return o.note.range(of: #"carbu|essence|gazole|station|total ?energies|esso|shell|avia"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Dans quelle poche tombe une opération (avec son montant compensé : loyer à moitié, retrait de livret en négatif…).
    static func poche(_ o: Operation) -> (id: String, c: Operation)? {
        let c = Calc.compense(o)
        if c.cat == .epargne {
            if c.sc == "Livret" { return ("apport", c) }
            if c.sc == "Investissement" { return ("epargne", c) }
            return nil
        }
        guard c.cat.estDepense, abs(c.montant) > 0.004 else { return nil }
        if c.sc == "Voiture" || estEssence(o, c) { return ("voiture", c) }
        if c.sc == "Abonnements" || c.cat == .besoins { return ("besoins", c) }
        return ("envies", c)
    }

    struct Ligne: Identifiable, Hashable {
        let id: String, date: String, titre: String, sc: String, montant: Double
        let payeAvec: String?     // la carte utilisée, quand ce n'est pas celle prévue pour cette poche
        let moitie: Bool          // loyer partagé : ta moitié
        let op: Operation
    }
    struct Suivi: Identifiable {
        let poche: Poche
        let budget: Double
        let dep: Double           // dépensé (ou versé, pour l'épargne et l'apport) depuis la paie
        let lignes: [Ligne]
        var id: String { poche.id }
        var reste: Double { budget - dep }
        var depasse: Bool { !poche.epargne && reste < 0 }
        var fait: Bool { poche.epargne && dep >= budget - 0.005 }
        /// Jauge : ce qu'il reste (dépenses) ou ce qui est versé (épargne), de 0 à 1.
        var part: Double { budget <= 0 ? 0 : poche.epargne ? min(max(dep / budget, 0), 1) : min(max(reste / budget, 0), 1) }
    }

    /// Le suivi de chaque poche sur les opérations du cycle de paie en cours.
    static func suivi(_ opsP: [Operation], nomCompte: (String) -> String) -> [String: Suivi] {
        var dep: [String: Double] = [:], lignes: [String: [Ligne]] = [:]
        let tout = poches + [apport]
        for o in opsP {
            if let trouve = poche(o) {
                let k = trouve.id, c = trouve.c
                dep[k, default: 0] += c.montant
                let prevu = tout.first { $0.id == k }?.compte ?? ""
                let titre = o.note.isEmpty ? o.sc : Analyse.nom(o)
                lignes[k, default: []].append(Ligne(id: o.id, date: o.date, titre: titre, sc: c.sc, montant: c.montant,
                                                    payeAvec: (k == "epargne" || k == "apport" || o.compte == prevu) ? nil : nomCompte(o.compte),
                                                    moitie: o.sc == "Loyer" && o.loyerPartage, op: o))
            }
            dep["epargne", default: 0] -= Calc.sortieEpargneCarte(o)   // payé avec la carte Trade Republic : sort aussi de l'épargne
        }
        var r: [String: Suivi] = [:]
        for p in tout {
            r[p.id] = Suivi(poche: p, budget: montant(p.id), dep: dep[p.id] ?? 0,
                            lignes: (lignes[p.id] ?? []).sorted { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date })
        }
        return r
    }

    /// Trade Republic, méthode d'Arthur (15/11/2026) : tout ce qui est arrivé sur le compte et qui n'est plus en espèces est sur le PEA.
    /// PEA = virements reçus − virements renvoyés − dépenses carte + intérêts − espèces − pertes figées de l'ancien compte-titres vendu.
    /// Vérifié sur ses données : 1 199,89 − 182,44 + 3,13 − 6,08 − 18,85 = 995,65 € (le chiffre de son app Trade Republic).
    /// C'est le montant VERSÉ (prix d'achat), pas la valeur du jour.
    struct TradeRepublic { let especes: Double; let pea: Double; let pertes: Double; let mouvements: [Operation] }
    static func tradeRepublic(_ ops: [Operation], especes: Double) -> TradeRepublic {
        let k = "Trade Republic"
        let lui = ops.filter { $0.compte == k || ($0.cat == .virement && $0.vers == k) }
        var recu = 0.0, renvoye = 0.0, carte = 0.0, interets = 0.0
        for o in lui {
            if o.cat == .virement {
                if o.vers == k && o.compte != k { recu += o.montant }
                if o.compte == k && o.vers != k { renvoye += o.montant }
            } else if o.compte == k && o.cat.estDepense { carte += o.montant }
            else if o.compte == k && o.cat == .revenu && o.sc != "Vente placement" { interets += o.montant }
        }
        // Pertes et frais des placements vendus SUR ce compte (l'ancien compte-titres) : comptés à part, une seule fois
        let pertes = Calc.placements(lui.filter { $0.compte == k }).pertes
        let pea = recu - renvoye - carte + interets - especes - pertes
        return TradeRepublic(especes: especes, pea: pea, pertes: pertes, mouvements: lui.sorted { $0.date > $1.date })
    }
}
