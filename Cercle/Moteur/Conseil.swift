import Foundation

/// Tout ce que le Résumé et le conseiller utilisent, calculé une seule fois.
struct Tableau {
    var ops: [Operation]           // toutes les opérations, celles des groupes comprises
    var per: Calc.Periode
    var opsP: [Operation]
    var opsPrec: [Operation]
    var b: Calc.Bilan
    var bp: Calc.Bilan?
    var budget: Double
    var objectifEpargne: Double
    var soldeAuj: Double
    var recs: [Suivi.Recurrent]
    var prev: Suivi.Prevision
    var enveloppes: [Suivi.SuiviEnveloppe]
    var objectifs: [Suivi.SuiviObjectif]
    /// Solde réel des livrets d'après les relevés (nil si le site n'en a pas enregistré)
    var livret: Double?

    init(ops: [Operation], mode: Calc.Mode, perso: (String, String)?, budgetMensuel: Double, objectifEpargne: Double,
         enveloppes env: [Enveloppe], objectifs obj: [Objectif], soldeInitial: Double, livret: Double? = nil) {
        self.livret = livret
        // Calculs dans des variables locales d'abord : Swift interdit de lire `self` avant que tout soit rempli
        let p = Calc.periode(mode, ops, perso: perso)
        let dansP = Calc.entre(ops, p.debut, p.fin)
        var prec: [Operation] = []
        if let d = p.precDebut { prec = Calc.entre(ops, d, p.precFin ?? d) }
        let bud = budgetMensuel * p.facteur
        let solde = Calc.solde(ops, "", jusqua: J.auj, initial: soldeInitial)
        let r = Suivi.recurrents(ops)
        self.ops = ops
        per = p
        opsP = dansP
        opsPrec = prec
        b = Calc.bilan(dansP)
        bp = p.precDebut == nil ? nil : Calc.bilan(prec)
        budget = bud
        self.objectifEpargne = objectifEpargne * p.facteur
        soldeAuj = solde
        recs = r
        prev = Suivi.prevision(dansP, p, soldeAuj: solde, budget: bud, recs: r.filter { $0.cat != .virement })
        enveloppes = Suivi.enveloppes(env, dansP, prec, facteur: p.facteur)
        objectifs = Suivi.objectifs(obj, ops, livret: livret)
    }
}

enum Conseil {
    struct Alerte: Identifiable { var id = UUID(); var symbole: String; var grave: Bool; var texte: String }
    /// « À surveiller » : budget menacé ou dépassé, enveloppes, solde prévu négatif, prélèvement attendu, objectif en retard.
    static func alertes(_ t: Tableau) -> [Alerte] {
        var l: [Alerte] = []
        if t.prev.depFin > t.budget && t.b.dep <= t.budget { l.append(Alerte(symbole: "chart.line.uptrend.xyaxis", grave: false, texte: "Budget menacé : environ \(Fmt.eur(t.prev.depFin, 0)) prévus pour \(Fmt.eur(t.budget, 0))")) }
        if t.b.dep > t.budget { l.append(Alerte(symbole: "exclamationmark.circle", grave: true, texte: "Budget dépassé de \(Fmt.eur(t.b.dep - t.budget, 0))")) }
        for e in t.enveloppes where e.etat != .ok {
            l.append(Alerte(symbole: Ref.theme(e.e.sc).symbole, grave: e.etat == .depasse,
                            texte: e.etat == .depasse ? "\(e.e.sc) : dépassé de \(Fmt.eur(-e.reste, 0))" : "\(e.e.sc) : \(Fmt.pct(e.part)) de l'enveloppe utilisés"))
        }
        if t.prev.soldeFin < 0 { l.append(Alerte(symbole: "building.columns", grave: true, texte: "Solde prévu au \(J.court(t.per.finBudget)) : \(Fmt.eur(t.prev.soldeFin, 0))")) }
        for e in t.prev.aVenir where e.enRetard && e.r.cat != .revenu { l.append(Alerte(symbole: "clock", grave: false, texte: "\(e.r.nom) attendu le \(J.court(e.r.prochain)), pas encore vu")) }
        for o in t.objectifs where o.enRetard { l.append(Alerte(symbole: "flag", grave: false, texte: "\(o.o.nom) : il faudrait \(Fmt.eur(o.parMois ?? 0, 0)) par mois (rythme actuel \(Fmt.eur(o.rythme, 0)))")) }
        return l
    }

    struct Note: Identifiable { var id = UUID(); var symbole: String; var texte: String }
    /// Notes du conseiller (reprise de notes_conseiller du site), sur les n derniers mois.
    static func notes(_ ops: [Operation], mois n: Int) -> [Note] {
        let mois = Calc.moisDerniers(n), debut = mois.first!.debut
        let opsP = Calc.entre(ops, debut, J.auj)
        let nbMois = max(Double(J.ecart(debut, J.auj) + 1) / Ref.joursParMois, 1)
        let dep = opsP.map(Calc.compense).filter { $0.cat.estDepense }
        guard !dep.isEmpty else { return [Note(symbole: "info.circle", texte: "Pas encore assez d'opérations pour en tirer des enseignements.")] }
        var l: [Note] = []
        let cour = Calc.courantes(opsP).reduce(0) { $0 + $1.montant }
        let complets = Calc.mensuel(ops, 12).filter { !$0.mois.enCours }.map { m in Calc.courantes(Calc.entre(ops, m.mois.debut, m.mois.fin)).reduce(0) { $0 + $1.montant } }
        var t = "Ton train de vie courant (hors loyer, factures, abonnements et achats exceptionnels) est de \(Fmt.eur(cour / nbMois, 0)) par mois"
        if let e = Calc.evolution(complets) { t += " ; sur les 3 derniers mois, il est en \(e > 0 ? "hausse" : "baisse") de \(Fmt.pct(abs(e)))" }
        l.append(Note(symbole: "gauge.with.dots.needle.33percent", texte: t + "."))
        let envies = Calc.repartition(opsP).filter { Ref.theme($0.sc).cat == .envies }
        if let p = envies.first { let tot = envies.reduce(0) { $0 + $1.v }
            l.append(Note(symbole: Ref.theme(p.sc).symbole, texte: "Tes envies vont d'abord aux \(p.sc) : \(Fmt.eur(p.v, 0)), soit \(Fmt.pct(p.v / tot * 100)) des envies.")) }
        let pleins = Calc.mensuel(ops, n).filter { !$0.mois.enCours }
        if pleins.count > 1, let max = pleins.max(by: { $0.b.dep < $1.b.dep }) {
            let grosse = Calc.entre(ops, max.mois.debut, max.mois.fin).filter { $0.cat.estDepense }.max { $0.montant < $1.montant }
            l.append(Note(symbole: "calendar", texte: "Ton mois le plus dépensier : \(max.mois.long) avec \(Fmt.eur(max.b.dep, 0))" + (grosse.map { ", porté par « \($0.note.isEmpty ? $0.sc : $0.note) » (\(Fmt.eur($0.montant, 0)))" } ?? "") + "."))
        }
        let petits = opsP.filter { $0.cat.estDepense && $0.montant < 10 }
        if petits.count >= 10 { let s = petits.reduce(0) { $0 + $1.montant }
            l.append(Note(symbole: "cup.and.saucer", texte: "\(petits.count) petits achats de moins de 10 € pèsent \(Fmt.eur(s, 0)), soit \(Fmt.eur(s / nbMois, 0)) par mois : l'effet « café »."))
        }
        let b = Calc.bilan(opsP)
        l.append(Note(symbole: "banknote", texte: b.epa >= 0
            ? "Épargne nette de la période : \(Fmt.eur(b.epa, 0))" + (b.rev > 0 ? ", soit \(Fmt.pct(b.epa / b.rev * 100)) de tes revenus." : ".")
            : "Tu as retiré de ton épargne \(Fmt.eur(-b.epa, 0)) de plus que tu n'y as versé."))
        let abos = Suivi.abonnements(ops)
        if !abos.isEmpty { let m = abos.reduce(0) { $0 + $1.mensuel }
            l.append(Note(symbole: "repeat", texte: "Tes \(abos.count) abonnements actifs coûtent \(Fmt.eur(m, 0)) par mois, soit \(Fmt.eur(m * 12, 0)) par an.")) }
        let env = Calc.courantes(opsP).filter { $0.cat == .envies }, tot = env.reduce(0) { $0 + $1.montant }
        if tot > 0 { let we = env.filter { J.jourSemaine($0.date) >= 5 }.reduce(0) { $0 + $1.montant }
            l.append(Note(symbole: "sun.max", texte: "\(Fmt.pct(we / tot * 100)) de tes envies sont dépensées le week-end, qui ne représente que 29 % des jours.")) }
        return l
    }

    struct Reco: Identifiable { var id = UUID(); var symbole: String; var titre: String; var texte: String; var gain: Double; var urgent = false; var action: Action? = nil }
    enum Action { case enveloppes, prelevements, saisie, objectif(String) }

    /// Pistes d'amélioration avec un gain estimé par mois : l'urgent d'abord, puis les plus grosses économies.
    static func recommandations(_ t: Tableau) -> [Reco] {
        let mois = Calc.mensuel(t.ops, 4).filter { !$0.mois.enCours }, nb = Double(max(mois.count, 1))
        guard let premier = mois.first, let dernier = mois.last else { return [] }
        let ops3 = Calc.entre(t.ops, premier.mois.debut, dernier.mois.fin)
        let rev = mois.reduce(0) { $0 + $1.b.rev } / nb
        let theme = Dictionary(Calc.repartition(ops3).map { ($0.sc, $0.v / nb) }, uniquingKeysWith: +)
        var l: [Reco] = []
        if let r = theme["Restos & sorties"], rev > 0, r / rev > 0.1 {
            l.append(Reco(symbole: "fork.knife", titre: "Restos et sorties", texte: "Tu y consacres \(Fmt.eur(r, 0)) par mois, soit \(Fmt.pct(r / rev * 100)) de tes revenus. Une limite à \(Fmt.eur(r * 0.75, 0)) te ferait gagner \(Fmt.eur(r * 0.25, 0)) par mois.", gain: r * 0.25, action: .enveloppes))
        }
        let abos = Suivi.abonnements(t.ops)
        if abos.count >= 3, let min = abos.map(\.mensuel).min() {
            let m = abos.reduce(0) { $0 + $1.mensuel }
            l.append(Reco(symbole: "repeat", titre: "Abonnements", texte: "\(abos.count) abonnements pour \(Fmt.eur(m, 0)) par mois (\(Fmt.eur(m * 12, 0)) par an). Supprimer le moins utilisé économise au moins \(Fmt.eur(min, 0)) par mois.", gain: min, action: .prelevements))
        }
        let petits = ops3.filter { $0.cat.estDepense && $0.montant < 10 }
        if petits.count >= 12 { let m = petits.reduce(0) { $0 + $1.montant } / nb
            l.append(Reco(symbole: "cup.and.saucer", titre: "Petits achats", texte: "\(Int(Double(petits.count) / nb)) achats de moins de 10 € par mois, \(Fmt.eur(m, 0)) au total. En éviter la moitié : \(Fmt.eur(m * 0.4, 0)) de gagné.", gain: m * 0.4))
        }
        let epa = mois.reduce(0) { $0 + $1.b.epa } / nb
        if rev > 0, epa / rev < 0.2 {
            l.append(Reco(symbole: "banknote", titre: "Épargne automatique", texte: "Tu épargnes \(Fmt.pct(epa / rev * 100)) de tes revenus. Pour atteindre 20 %, programme \(Fmt.eur(rev * 0.2 - epa, 0)) de plus le jour de la paie : l'épargne passe avant les envies.", gain: rev * 0.2 - epa, action: .saisie))
        }
        if let j = theme["Jeux d'argent"], j > 0 { l.append(Reco(symbole: "dice", titre: "Jeux d'argent", texte: "Les jeux te coûtent \(Fmt.eur(j, 0)) par mois en net. Une limite de mises dans les applis de paris évite les dérapages.", gain: j)) }
        if t.prev.depFin > t.budget {
            l.append(Reco(symbole: "gauge.with.dots.needle.67percent", titre: "Fin de période", texte: "À ce rythme, tu dépasserais ton budget de \(Fmt.eur(t.prev.depFin - t.budget, 0)). Reste sous \(Fmt.eur(t.prev.parJour, 0)) par jour jusqu'au \(J.court(t.per.finBudget)).", gain: 0, urgent: true))
        }
        for o in t.objectifs where o.enRetard {
            l.append(Reco(symbole: "flag", titre: o.o.nom, texte: "Pour tenir la date, il faut \(Fmt.eur(o.parMois ?? 0, 0)) par mois ; tu mets \(Fmt.eur(o.rythme, 0)). Augmente le virement ou repousse la date.", gain: 0, action: .objectif(o.o.id)))
        }
        return l.sorted { ($0.urgent ? 1 : 0, $0.gain) > ($1.urgent ? 1 : 0, $1.gain) }
    }

    struct Critere: Identifiable { var id: String { nom }; var nom: String; var max: Double; var points: Double; var detail: String; var conseil: String }
    /// Score de santé financière sur 100 : six critères expliqués, sur les 6 derniers mois complets.
    static func score(_ t: Tableau, budgetMensuel: Double) -> (total: Int, niveau: String, criteres: [Critere]) {
        let mois = Calc.mensuel(t.ops, 7).filter { !$0.mois.enCours }, nb = Double(max(mois.count, 1))
        let rev = mois.reduce(0) { $0 + $1.b.rev }, dep = mois.reduce(0) { $0 + $1.b.dep }, epa = mois.reduce(0) { $0 + $1.b.epa }
        let depMoy = dep / nb, taux = rev > 0 ? epa / rev : 0
        let respectes = mois.filter { $0.b.dep <= budgetMensuel }.count
        let livret = t.livret ?? max(t.ops.map(Calc.compense).filter { $0.sc == "Livret" }.reduce(0) { $0 + $1.montant }, 0)
        let reserve = (t.soldeAuj + livret) / max(depMoy, 1)
        let fixes = mois.reduce(0) { r, m in r + Calc.entre(t.ops, m.mois.debut, m.mois.fin).map(Calc.compense).filter { $0.cat.estDepense && Ref.chargesFixes.contains($0.sc) }.reduce(0) { $0 + $1.montant } } / nb
        let partFixes = rev > 0 ? fixes / (rev / nb) : 1
        let ecart = sqrt(mois.reduce(0) { $0 + pow($1.b.dep - depMoy, 2) } / nb), cv = depMoy > 0 ? ecart / depMoy : 1
        let jeux = t.ops.map(Calc.compense).filter { $0.sc == "Jeux d'argent" }.reduce(0) { $0 + $1.montant }
        func lim(_ x: Double, _ a: Double, _ b: Double) -> Double { max(0, min(1, (x - a) / (b - a))) }
        let c = [
            Critere(nom: "Taux d'épargne", max: 25, points: 25 * lim(taux, 0, 0.2), detail: "\(Fmt.pct(taux * 100)) des revenus épargnés (cible 20 %)", conseil: "Programme un virement vers le livret le jour de la paie."),
            Critere(nom: "Budget respecté", max: 20, points: 20 * Double(respectes) / nb, detail: "\(respectes) mois sur \(Int(nb)) sous \(Fmt.eur(budgetMensuel, 0))", conseil: "Fixe des enveloppes sur les postes qui dérapent."),
            Critere(nom: "Réserve de sécurité", max: 20, points: 20 * lim(reserve, 0, 3), detail: String(format: "%.1f mois de dépenses de côté (cible 3)", reserve).replacingOccurrences(of: ".", with: ","), conseil: "Vise 3 mois de dépenses sur un livret disponible."),
            Critere(nom: "Charges fixes", max: 15, points: 15 * (1 - lim(partFixes, 0.5, 0.8)), detail: "\(Fmt.pct(partFixes * 100)) des revenus (au-delà de 50 %, peu de marge)", conseil: "Renégocie forfait, box et assurance chaque année."),
            Critere(nom: "Régularité", max: 10, points: 10 * (1 - lim(cv, 0.15, 0.5)), detail: "dépenses qui varient de \(Fmt.pct(cv * 100)) d'un mois à l'autre", conseil: "Lisse les grosses dépenses avec une enveloppe « imprévus »."),
            Critere(nom: "Jeux et découvert", max: 10, points: max(0, 10 - (jeux > 0 ? 5 * lim(jeux, 0, 100) : 0) - (mois.contains { $0.b.reste < 0 } ? 3 : 0)), detail: jeux > 0 ? "\(Fmt.eur(jeux, 0)) perdus aux jeux depuis le début" : "aucune perte aux jeux", conseil: "Fixe une limite mensuelle de mises."),
        ]
        let total = Int(c.reduce(0) { $0 + $1.points }.rounded())
        return (total, total >= 80 ? "Excellent" : total >= 65 ? "Bon" : total >= 50 ? "Correct" : "À améliorer", c)
    }

    /// Doublons possibles (même note, même montant, à 2 jours) et dépenses inhabituelles (> 2,5 fois l'habitude du marchand).
    static func anomalies(_ ops: [Operation], ignores: Set<String>) -> (doublons: [(Operation, Operation)], inhabituelles: [(Operation, Double)]) {
        let dep = ops.filter { $0.cat.estDepense && $0.partage == nil }.sorted { $0.date < $1.date }
        var doub: [(Operation, Operation)] = []
        for i in dep.indices {
            var j = i + 1
            while j < dep.count && J.ecart(dep[i].date, dep[j].date) <= 2 {
                if dep[i].montant == dep[j].montant && dep[i].note.sansAccents == dep[j].note.sansAccents && dep[i].sc == dep[j].sc && !ignores.contains(dep[j].id) { doub.append((dep[i], dep[j])) }
                j += 1
            }
        }
        var parMarchand: [String: [Operation]] = [:]
        for o in dep { parMarchand[Analyse.marchand(o).sansAccents, default: []].append(o) }
        var inh: [(Operation, Double)] = []
        for l in parMarchand.values where l.count >= 4 {
            let med = l.map(\.montant).sorted()[l.count / 2]
            for o in l where o.montant > med * 2.5 && o.montant - med > 20 { inh.append((o, med)) }
        }
        return (doub, inh.sorted { $0.0.date > $1.0.date })
    }
}

enum Analyse {
    static func marchand(_ o: Operation) -> String {
        let brut = o.note.components(separatedBy: " · ").first ?? ""
        let m = brut.replacingOccurrences(of: #"\s*\(\d+ achats\)$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? o.sc : m.prefix(1).uppercased() + m.dropFirst()
    }
}
