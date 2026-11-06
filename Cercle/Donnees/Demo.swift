import Foundation

/// Données de démonstration INVENTÉES (mêmes règles que le prototype web), générées à partir d'une graine fixe.
enum Demo {
    struct Jeu { var profil: Profil; var ops: [Operation]; var groupes: [GroupeComplet]; var enveloppes: [Enveloppe]; var objectifs: [Objectif]; var mouvements: [MouvementTitre] }

    /// Générateur pseudo-aléatoire reproductible (mulberry32), pour avoir toujours les mêmes données.
    private struct Graine {
        var a: UInt32
        mutating func suivant() -> Double {
            a = a &+ 0x6D2B79F5
            var t = (a ^ (a >> 15)) &* (1 | a)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4294967296
        }
    }

    static func generer() -> Jeu {
        let pid = "demo-profil"
        var r = Graine(a: 20261106), ops: [Operation] = []
        let auj = J.aujourdhui
        func add(_ d: Date, _ sc: String, _ m: Double, _ note: String, _ compte: String = "", _ vers: String? = nil) {
            guard d <= auj else { return }
            ops.append(Operation(id: UUID().uuidString, date: J.iso(d), profilId: pid, cat: Ref.theme(sc).cat, sc: sc,
                                 montant: (m * 100).rounded() / 100, note: note, compte: compte, vers: vers))
        }
        func pick(_ l: [String]) -> String { l[Int(r.suivant() * Double(l.count)) % l.count] }
        let c0 = J.comp(auj)
        for k in stride(from: 7, through: 0, by: -1) {
            let base = J.faire(c0.a, c0.m - k, 1), c = J.comp(base)
            func jour(_ j: Int) -> Date { J.faire(c.a, c.m, j) }
            let nbj = J.comp(J.finDuMois(base)).j
            func auHasard() -> Date { jour(1 + Int(r.suivant() * Double(nbj))) }
            add(jour(1), "Investissement", 100, k % 3 == 0 ? "PEA · ETF Pays émergents" : "PEA · ETF Monde")
            add(jour(2), "Transport", 31, "Abonnement Naolib")
            add(jour(3), "Loyer", 880, "Loyer · Agence du Port")
            add(jour(4), "Remboursement loyer", 440, "Part de Léa")
            add(jour(5), "Bourse & aides", 118.45, "CAF")
            add(jour(6), "Assurances", 9.5, "Assurance habitation")
            add(jour(8), "Abonnements", 2.99, "iCloud+")
            add(jour(10), "Factures", 38 + r.suivant() * 16, "Électricité")
            add(jour(12), "Factures", 31.99, "Box internet")
            add(jour(14), "Abonnements", 11.99, "Forfait mobile")
            add(jour(15), "Abonnements", 13.49, "Netflix")
            add(jour(20), "Abonnements", 11.12, "Spotify")
            add(jour(26 + Int(r.suivant() * 3)), "Salaire", 1440 + r.suivant() * 40, "Atelier Nord · alternance")
            add(jour(29), "Livret", 150, "Vers le Livret A")
            if k <= 4 { add(jour(29), "Projet", 60, "Voyage au Japon") }
            for s in 0..<4 { add(jour(2 + s * 7 + Int(r.suivant() * 3)), "Courses", 22 + r.suivant() * 48, pick(["Lidl", "Carrefour City", "Super U", "Biocoop"])) }
            for _ in 0..<(5 + Int(r.suivant() * 3)) { add(auHasard(), "Restos & sorties", 9 + r.suivant() * 28, pick(["Pizzeria Napoli", "Le Petit Bistrot", "Burger Factory", "Bar du Coin"]) + " · " + pick(["Nantes", "Rezé"])) }
            for _ in 0..<(6 + Int(r.suivant() * 4)) { add(auHasard(), "Restos & sorties", 2.2 + r.suivant() * 2.6, "Café · Le Comptoir") }
            for _ in 0..<(1 + Int(r.suivant() * 3)) { add(auHasard(), "Shopping", 18 + r.suivant() * 70, pick(["Decathlon", "Fnac", "Zara", "Librairie"])) }
            add(auHasard(), "Loisirs", 11.5, "Cinéma")
            if r.suivant() > 0.5 { add(auHasard(), "Loisirs", 32, "Concert") }
            if r.suivant() > 0.4 { add(auHasard(), "Santé", 8 + r.suivant() * 22, "Pharmacie") }
            if k % 2 == 0 {
                add(jour(9), "Virement interne", 120, "Vers Revolut", "", "Revolut")
                add(jour(16), "Restos & sorties", 18 + r.suivant() * 25, "Ramen Kyo", "Revolut")
            }
            if k % 2 == 1 { add(jour(11), "Jeux d'argent", 15, "Betclic"); if r.suivant() > 0.5 { add(jour(13), "Gains de jeux", 8 + (r.suivant() * 30).rounded(), "Retrait Betclic") } }
            if k == 4 { add(jour(18), "Voyages", 214, "Train · vacances") }
        }
        let j: (Int) -> String = { J.plus(J.auj, jours: -$0) }
        let g1 = "demo-g1", moi = "demo-moi", lea = "demo-lea", hugo = "demo-hugo", ines = "demo-ines"
        let groupe = GroupeComplet(
            groupe: Groupe(id: g1, nom: "Week-end à Lisbonne", creePar: pid),
            participants: [Participant(id: moi, groupeId: g1, nom: "Toi", profilId: pid), Participant(id: lea, groupeId: g1, nom: "Léa"),
                           Participant(id: hugo, groupeId: g1, nom: "Hugo"), Participant(id: ines, groupeId: g1, nom: "Inès")],
            depenses: [
                DepensePartagee(id: "d1", groupeId: g1, titre: "Appartement", montant: 360, payeur: moi, parts: [moi, lea, hugo, ines], mode: "egal", valeurs: [:], sc: "Voyages", date: j(13)),
                DepensePartagee(id: "d2", groupeId: g1, titre: "Dîner à l'Alfama", montant: 96, payeur: hugo, parts: [moi, lea, hugo, ines], mode: "egal", valeurs: [:], sc: "Restos & sorties", date: j(12)),
                DepensePartagee(id: "d3", groupeId: g1, titre: "Musée", montant: 36, payeur: ines, parts: [moi, lea, ines], mode: "egal", valeurs: [:], sc: "Loisirs", date: j(11)),
            ],
            reglements: [Reglement(id: "r1", groupeId: g1, de: hugo, a: moi, montant: 60, date: j(6))])
        let env = [("Courses", 220.0, false), ("Restos & sorties", 170, true), ("Shopping", 90, true), ("Loisirs", 60, false)]
            .map { Enveloppe(id: UUID().uuidString, profilId: pid, sc: $0.0, montant: $0.1, report: $0.2) }
        let c = J.comp(auj)
        let obj = [Objectif(id: "ob1", profilId: pid, nom: "Matelas de sécurité", support: "Livret", cible: 2500, dateVisee: J.iso(J.faire(c.a + 1, 6, 30))),
                   Objectif(id: "ob2", profilId: pid, nom: "Voyage au Japon", support: "Projet", cible: 1800, dateVisee: J.iso(J.faire(c.a + 1, 4, 1)))]
        return Jeu(profil: Profil(id: pid, prenom: "Arthur", visibilite: "resume", budget: 1150, objectifEpargne: 300),
                   ops: ops.sorted { $0.date > $1.date }, groupes: [groupe], enveloppes: env, objectifs: obj, mouvements: [])
    }
}
