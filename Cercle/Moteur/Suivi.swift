import Foundation

/// Prélèvements détectés, prévision de fin de période, enveloppes et objectifs (lot 1 du prototype).
enum Suivi {
    // MARK: Opérations régulières

    struct Recurrent: Identifiable, Hashable {
        var cle: String, nom: String, sc: String, cat: Cat, montant: Double
        var mensuel: Bool, jour: Int, dernier: String, prochain: String, actif: Bool, compte: String
        var id: String { cle }
        var annuel: Double { mensuel ? montant * 12 : montant * 52 }
        var parMois: Double { mensuel ? montant : montant * 52 / 12 }
    }
    static func cle(_ o: Operation) -> String {
        "\(o.sc)|\((o.note.components(separatedBy: " · ").first ?? o.sc).sansAccents.trimmingCharacters(in: .whitespaces))"
    }
    private static func mediane(_ l: [Double]) -> Double {
        let s = l.sorted(), n = s.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Régulière = au moins 3 fois, même thème et même note, intervalle stable (≈ 1 mois ou 1 semaine), montant proche.
    static func recurrents(_ ops: [Operation]) -> [Recurrent] {
        let a = J.auj, limite = J.plus(a, jours: -240)
        var groupes: [String: [Operation]] = [:]
        for o in ops where o.date <= a && o.date >= limite && o.cat != .virement && o.partage == nil { groupes[cle(o), default: []].append(o) }
        var res: [Recurrent] = []
        for (k, l) in groupes {
            let dates = Array(Set(l.map(\.date))).sorted()
            guard dates.count >= 3 else { continue }
            let ecarts = zip(dates, dates.dropFirst()).map { Double(J.ecart($0, $1)) }
            let med = mediane(ecarts)
            let mensuel = (26...35).contains(med), hebdo = (6...8).contains(med)
            guard mensuel || hebdo, mediane(ecarts.map { abs($0 - med) }) <= (mensuel ? 4 : 1.5) else { continue }
            let m = mediane(l.map(\.montant))
            guard mediane(l.map { abs($0.montant - m) }) <= m * 0.2 else { continue }
            let dernier = dates.last!, recent = l.first { $0.date == dernier }!, d = J.date(dernier)
            res.append(Recurrent(cle: k, nom: recent.note.components(separatedBy: " · ").first.flatMap { $0.isEmpty ? nil : $0 } ?? recent.sc,
                                 sc: recent.sc, cat: recent.cat, montant: m, mensuel: mensuel, jour: J.comp(d).j, dernier: dernier,
                                 prochain: J.iso(mensuel ? J.moisSuivant(d) : J.plus(d, jours: 7)),
                                 actif: J.ecart(d, J.aujourdhui) <= (mensuel ? 40 : 12), compte: recent.compte))
        }
        return res.sorted { $0.annuel > $1.annuel }
    }

    struct Echeance: Identifiable, Hashable { var r: Recurrent; var date: String; var enRetard: Bool; var id: String { r.cle + date } }
    /// Échéances après aujourd'hui jusqu'à `fin` ; une échéance dépassée et pas encore vue compte pour demain.
    static func echeances(_ recs: [Recurrent], jusqua fin: String) -> [Echeance] {
        let a = J.auj
        var l: [Echeance] = []
        for r in recs where r.actif {
            let base = J.date(r.prochain)
            var retardVu = false
            for k in 0..<12 {
                let d = J.iso(r.mensuel ? J.moisSuivant(base, k) : J.plus(base, jours: 7 * k))
                if d > fin { break }
                if d > a { l.append(Echeance(r: r, date: d, enRetard: false)) }
                else if !retardVu { retardVu = true; l.append(Echeance(r: r, date: J.plus(a, jours: 1), enRetard: true)) }
            }
        }
        return l.sorted { $0.date < $1.date }
    }

    // MARK: Prévision

    struct Prevision {
        var passes: Int, restants: Int, deja: Double, rythme: Double, depAVenir: Double, depFin: Double, soldeFin: Double, parJour: Double
        var aVenir: [Echeance]
        var total: Int { passes + restants }
    }
    /// Rythme des dépenses courantes depuis le début de la période, prolongé jusqu'à la fin, plus les prélèvements attendus.
    static func prevision(_ opsP: [Operation], _ per: Calc.Periode, soldeAuj: Double, budget: Double, recs: [Recurrent]) -> Prevision {
        let a = min(per.fin, J.auj)
        let passes = J.ecart(per.debut, a) + 1, restants = max(J.ecart(a, per.finBudget), 0)
        let deja = Calc.bilan(opsP).dep
        let cles = Set(recs.map(\.cle))
        let cour = Calc.courantes(opsP.filter { !cles.contains(cle($0)) }).reduce(0) { $0 + $1.montant }
        let rythme = max(cour, 0) / Double(passes)
        let aVenir = echeances(recs.filter { $0.cat != .virement }, jusqua: per.finBudget)
        var dep = 0.0, eff = 0.0
        for e in aVenir {
            let c = Calc.compense(Operation(id: "", date: e.date, profilId: "", cat: e.r.cat, sc: e.r.sc, montant: e.r.montant, note: "", compte: e.r.compte))
            if c.cat.estDepense { dep += c.montant }
            if e.r.compte.isEmpty { eff += e.r.cat == .revenu ? e.r.montant : -e.r.montant }
        }
        return Prevision(passes: passes, restants: restants, deja: deja, rythme: rythme, depAVenir: dep,
                         depFin: deja + rythme * Double(restants) + dep, soldeFin: soldeAuj - rythme * Double(restants) + eff,
                         parJour: max(budget - deja - dep, 0) / Double(max(restants, 1)), aVenir: aVenir)
    }

    // MARK: Enveloppes et objectifs

    struct SuiviEnveloppe: Identifiable { var e: Enveloppe; var depense: Double; var report: Double; var dispo: Double
        var id: String { e.id }
        var reste: Double { dispo - depense }
        var part: Double { dispo > 0 ? depense / dispo * 100 : (depense > 0 ? 999 : 0) }
        var etat: Etat { part > 100 ? .depasse : part >= 80 ? .alerte : .ok }
    }
    enum Etat { case ok, alerte, depasse }
    /// Une enveloppe « avec report » récupère ce qui reste (ou manque) de la période précédente.
    static func enveloppes(_ env: [Enveloppe], _ opsP: [Operation], _ opsPrec: [Operation], facteur: Double) -> [SuiviEnveloppe] {
        let dep = Dictionary(Calc.repartition(opsP).map { ($0.sc, $0.v) }, uniquingKeysWith: +)
        let prec = Dictionary(Calc.repartition(opsPrec).map { ($0.sc, $0.v) }, uniquingKeysWith: +)
        return env.map { e in
            let report = e.report ? e.montant - (prec[e.sc] ?? 0) : 0
            return SuiviEnveloppe(e: e, depense: dep[e.sc] ?? 0, report: report, dispo: e.montant * facteur + report)
        }.sorted { $0.part > $1.part }
    }

    struct SuiviObjectif: Identifiable { var o: Objectif; var actuel: Double; var rythme: Double
        var id: String { o.id }
        var reste: Double { max(o.cible - actuel, 0) }
        var part: Double { o.cible > 0 ? min(actuel / o.cible * 100, 100) : 0 }
        var parMois: Double? {
            guard let d = o.dateVisee else { return nil }
            return reste / max(Double(J.ecart(J.aujourdhui, J.date(d))) / Ref.joursParMois, 1)
        }
        var estimation: Int? { rythme > 0 ? Int((reste / rythme).rounded(.up)) : nil }
        var enRetard: Bool { if let p = parMois { return reste > 0 && rythme < p * 0.95 }; return false }
    }
    /// Progression = épargne nette du support depuis le début (versements − retraits), comme sur le site.
    /// `livret` : solde réel des livrets d'après les relevés (quand le site les a enregistrés). Il remplace la somme
    /// des virements pour un objectif rangé sur le Livret, car celle-ci ignore l'argent d'avant l'historique et les intérêts.
    static func objectifs(_ obj: [Objectif], _ ops: [Operation], livret: Double? = nil) -> [SuiviObjectif] {
        let limite = J.plus(J.auj, jours: -91)
        var total: [String: Double] = [:], recent: [String: Double] = [:]
        for o in ops { let c = Calc.compense(o); guard c.cat == .epargne else { continue }
            total[c.sc, default: 0] += c.montant
            if o.date > limite { recent[c.sc, default: 0] += c.montant } }
        return obj.map { o in
            let actuel = o.support == "Livret" && livret != nil ? livret! : (total[o.support] ?? 0)
            return SuiviObjectif(o: o, actuel: max(actuel, 0), rythme: (recent[o.support] ?? 0) / 3)
        }
    }

    /// Abonnements actifs (thème « Abonnements », payés dans les 40 derniers jours) et leur coût mensuel sur 3 mois.
    static func abonnements(_ ops: [Operation]) -> [(nom: String, mensuel: Double)] {
        let l40 = J.plus(J.auj, jours: -40), l92 = J.plus(J.auj, jours: -92)
        var m: [String: (dernier: String, trim: Double)] = [:]
        for o in ops where o.sc == "Abonnements" && o.date <= J.auj {
            let k = o.note.isEmpty ? "Abonnement" : o.note
            var e = m[k] ?? ("", 0)
            if o.date > e.dernier { e.dernier = o.date }
            if o.date > l92 { e.trim += o.montant }
            m[k] = e
        }
        return m.filter { $0.value.dernier >= l40 }.map { ($0.key, $0.value.trim / 3) }.sorted { $0.mensuel > $1.mensuel }
    }
}
