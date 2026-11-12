import Foundation

/// Prélèvements qui reviennent chaque mois, comme l'aperçu v3 validé par Arthur le 07/11/2026 :
/// - un même service noté de plusieurs façons ne compte qu'une fois : noms connus (alias), puis regroupement
///   automatique des noms proches (« elec », « électricité », « Électricité Alterna » = Électricité) ;
/// - actif s'il a été payé il y a moins de 45 jours ; montant = dernier paiement (les prix changent) ;
/// - montant variable (électricité, factures qui changent) : moyenne ramenée à un mois, depuis le début du
///   contrat (7 août 2026 pour l'électricité), affichée « environ » (demandes du 12/11/2026) ; loyer partagé : ta moitié ;
/// - certains abonnements ont une date de fin connue (la salle s'arrête en décembre 2026).
enum Prelevements {
    struct Prelevement: Identifiable, Hashable {
        var nom: String, montant: Double, jour: Int, sc: String, compte: String
        var estAbonnement: Bool       // « Abonnements » ; le reste (loyer, factures, assurances, frais) est une charge
        var infos: String
        /// Montant qui change d'un mois à l'autre : `montant` est alors une moyenne, affichée « environ ».
        var variable = false
        /// Les opérations regroupées sous ce prélèvement (pour savoir s'il est déjà passé ce mois-ci).
        var ids: Set<String> = []
        var id: String { nom }

        /// « 24,99 € », ou « ≈ 28 € » pour un montant variable.
        var montantTexte: String { variable ? "≈ " + Fmt.eur(montant, 0) : Fmt.eur(montant) }
        /// Même chose, en négatif (sortie d'argent).
        var sortieTexte: String { variable ? "≈ " + Fmt.eur(-montant, 0, signe: true) : Fmt.eur(-montant, signe: true) }
    }

    /// Un même service écrit de plusieurs façons dans les notes (relevé lors des audits du 07/11 et du 12/11).
    static let alias: [String: String] = [
        "icloud+": "iCloud+", "icloud": "iCloud+",
        "apple music": "Apple Music", "apple musique": "Apple Music",
        "google one": "Google One (Gemini)", "paiement cb google one": "Google One (Gemini)", "gemini pro": "Google One (Gemini)",
        "claude": "Claude (Anthropic)", "anthropic": "Claude (Anthropic)",
        "gmf": "GMF assurance auto", "gmf (assurance auto)": "GMF assurance auto", "auto": "GMF assurance auto",
        "uber eat": "Uber One", "uber one": "Uber One",
        "cap residentiel": "Loyer", "loyer": "Loyer",
        "cotisation eurocompte jeune": "Cotisation bancaire", "frais cotisation banque": "Cotisation bancaire",
        "salle": "Fitness Océane", "prime video": "Amazon Prime",
    ]
    /// Abonnements qui s'arrêtent à une date connue : (année, mois) du dernier paiement.
    static let fins: [String: (Int, Int)] = ["Fitness Océane": (2026, 12)]
    /// Date de début connue d'un contrat à montant variable (l'électricité a commencé le 7 août 2026).
    static let debuts: [String: String] = ["Électricité": "2026-08-07"]

    /// Montant mensuel d'une facture variable, payée à terme échu : chaque paiement règle le mois précédent.
    /// On divise tout ce qui a été payé par le nombre de jours couverts (du début du contrat, ou du 1er du mois
    /// avant le premier paiement, jusqu'à la fin du mois avant le dernier paiement), puis on ramène à un mois.
    /// Un premier mois incomplet (contrat commencé le 7) ne tire donc plus la moyenne vers le bas.
    static func moyenneMensuelle(_ l: [Operation], debut connu: String?) -> Double {
        guard let premier = l.first, let dernier = l.last else { return 0 }
        let debut = connu ?? J.iso(J.debutDuMois(J.moisSuivant(J.debutDuMois(J.date(premier.date)), -1)))
        let fin = J.iso(J.plus(J.debutDuMois(J.date(dernier.date)), jours: -1))
        let jours = max(J.ecart(debut, fin) + 1, 1)
        let total = l.reduce(0) { $0 + $1.montant }
        return total / Double(jours) * Ref.joursParMois
    }

    /// Mots qui ne disent rien du service : retirés avant de comparer deux noms.
    static let motsVides: Set<String> = ["paiement", "cb", "carte", "prlv", "prelevement", "sepa", "forfait", "abonnement", "abo",
                                         "facture", "mensuel", "mensualite", "de", "du", "des", "la", "le", "les", "l", "d", "et", "mon", "ma"]
    /// Fournisseurs d'électricité : tout ce qui les nomme, ou contient « élec », devient « Électricité ».
    static let fournisseursElec: Set<String> = ["alterna", "edf", "engie", "totalenergies", "ekwateur", "octopus", "vattenfall", "ohm"]

    static func service(_ o: Operation) -> String {
        let brut = Analyse.marchand(o)
        return alias[brut.sansAccents.lowercased().trimmingCharacters(in: .whitespaces)] ?? brut
    }

    /// Les mots qui comptent dans un nom, sans accents ni majuscules.
    static func mots(_ nom: String) -> [String] {
        nom.sansAccents.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !motsVides.contains($0) }
    }

    /// Famille reconnue à coup sûr (aujourd'hui : l'électricité).
    static func famille(_ m: [String]) -> String? {
        m.contains(where: { $0.hasPrefix("elec") || fournisseursElec.contains($0) }) ? "Électricité" : nil
    }

    /// Deux noms désignent-ils le même service ? Mêmes mots, mots de l'un tous dans l'autre
    /// (« bouygues » et « Forfait Bouygues »), ou presque la même orthographe (faute de frappe).
    static func memeService(_ a: [String], _ b: [String]) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let sa = Set(a), sb = Set(b)
        let petit = sa.count <= sb.count ? sa : sb, grand = sa.count <= sb.count ? sb : sa
        if petit.isSubset(of: grand) && petit.contains(where: { $0.count >= 4 }) { return true }
        let x = a.joined(separator: " "), y = b.joined(separator: " ")
        return min(x.count, y.count) >= 5 && proximite(x, y) >= 0.8
    }

    /// Ressemblance de deux textes, de 0 à 1 (1 = identiques), d'après le nombre de lettres à changer.
    static func proximite(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var avant = Array(0...y.count)
        for i in 1...x.count {
            var ligne = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                ligne[j] = min(avant[j] + 1, ligne[j - 1] + 1, avant[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            avant = ligne
        }
        return 1 - Double(avant[y.count]) / Double(max(x.count, y.count))
    }

    /// Regroupe les noms de services qui désignent la même chose. Renvoie, pour chaque nom, le nom du groupe.
    static func regrouper(_ noms: [String: Int]) -> [String: String] {
        let liste = noms.keys.sorted()
        let decoupes = liste.map(mots)
        var parent = Array(liste.indices)
        func racine(_ i: Int) -> Int { var k = i; while parent[k] != k { k = parent[k] }; return k }
        for i in liste.indices {
            for j in liste.indices where j > i {
                let fi = famille(decoupes[i]), fj = famille(decoupes[j])
                let lies = (fi != nil && fi == fj) || (fi == nil && fj == nil && memeService(decoupes[i], decoupes[j]))
                if lies { parent[racine(j)] = racine(i) }
            }
        }
        var membres: [Int: [Int]] = [:]
        for i in liste.indices { membres[racine(i), default: []].append(i) }
        var res: [String: String] = [:]
        for (_, l) in membres {
            // Nom du groupe : la famille connue, sinon le nom le plus utilisé (à égalité, le plus long)
            let nomGroupe = l.compactMap { famille(decoupes[$0]) }.first
                ?? l.map { liste[$0] }.max { (noms[$0] ?? 0, $0.count) < (noms[$1] ?? 0, $1.count) }!
            for i in l { res[liste[i]] = nomGroupe }
        }
        return res
    }

    static func liste(_ ops: [Operation]) -> [Prelevement] {
        let a = J.auj, limite = J.plus(a, jours: -400), c = J.comp(J.aujourdhui)
        let retenues = ops.filter { Ref.chargesFixes.contains($0.sc) && $0.date <= a && $0.date > limite && $0.partage == nil }
        var frequence: [String: Int] = [:]
        for o in retenues { frequence[service(o), default: 0] += 1 }
        let groupeDe = regrouper(frequence)
        var groupes: [String: [Operation]] = [:]
        for o in retenues { groupes[groupeDe[service(o)] ?? service(o), default: []].append(o) }

        var res: [Prelevement] = []
        for (nom, l0) in groupes {
            let l = l0.sorted { $0.date < $1.date }
            guard let der = l.last, J.ecart(der.date, a) <= 45 else { continue }   // arrêté
            if let f = fins[nom], (c.a, c.m) > f { continue }                      // terminé
            let sc = Dictionary(grouping: l, by: \.sc).max { $0.value.count < $1.value.count }?.key ?? der.sc
            let variable = famille(mots(nom)) != nil || (sc == "Factures" && Set(l.map(\.montant)).count > 2)
            var montant = der.montant, affiche = nom
            if variable { montant = moyenneMensuelle(l, debut: debuts[nom]) }
            if sc == "Loyer" && der.loyerPartage { affiche = "Loyer (ta part)"; montant = der.montant / 2 }
            let prix = l.map { ($0.montant * 100).rounded() / 100 }
            // Ancien prix : un prix différent payé au moins deux fois (évite les frais ponctuels)
            let dernierPrix = prix.last ?? 0
            let avant = prix.dropLast().reversed().first { candidat in abs(candidat - dernierPrix) > 0.01 && prix.filter { $0 == candidat }.count >= 2 }
            let premier = J.comp(J.date(l[0].date))
            var infos = "depuis \(J.moisCourts[premier.m - 1]) \(premier.a) · \(l.count) paiement\(l.count > 1 ? "s" : "")"
            if variable { infos += " · montant variable : moyenne" + (debuts[nom].map { " depuis le \(J.court($0))" } ?? " par mois") }
            if let avant, !variable, sc != "Loyer" { infos += " · avant \(Fmt.eur(avant))" }
            if l.count == 1 { infos += " · nouveau" }
            if let f = fins[nom] { infos += " · s'arrête en \(J.mois[f.1 - 1]) \(f.0)" }
            res.append(Prelevement(nom: affiche, montant: (montant * 100).rounded() / 100, jour: J.comp(J.date(der.date)).j, sc: sc,
                                   compte: der.compte, estAbonnement: sc == "Abonnements", infos: infos,
                                   variable: variable, ids: Set(l.map(\.id))))
        }
        return res.sorted { ($0.jour, $0.nom) < ($1.jour, $1.nom) }
    }
}
