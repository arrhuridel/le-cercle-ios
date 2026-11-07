import Foundation

/// Reprise des règles de calcul du site (`app.py`) : compensations, bilan, règle 50-30-20, soldes, périodes, prévision.
enum Calc {
    /// Vue « calculs », comme `compenser` du site : un retrait de livret devient une épargne négative…
    /// Loyer (règle d'Arthur du 07/11/2026) : avec un colocataire, le loyer compte toujours pour moitié,
    /// et le « Remboursement loyer » est alors déjà déduit (il compte 0).
    static func compense(_ o: Operation) -> Operation {
        if o.sc == "Loyer" && o.loyerPartage { var c = o; c.montant = o.montant / 2; c.loyerPartage = false; return c }
        if o.sc == "Remboursement loyer" { var c = o; c.sc = "Loyer"; c.cat = .besoins; c.montant = 0; return c }
        guard let cible = Ref.compensations[o.sc] else { return o }
        var c = o
        c.sc = cible.0; c.cat = cible.1; c.montant = -o.montant
        return c
    }

    /// Marque les loyers partagés : un « Remboursement loyer » tombe à 45 jours ou moins (même règle que le site).
    /// Un loyer payé seul, sans remboursement autour, reste entier.
    static func marquerLoyers(_ ops: [Operation]) -> [Operation] {
        let remb = ops.filter { $0.sc == "Remboursement loyer" }.map { J.date($0.date) }
        guard !remb.isEmpty else { return ops }
        return ops.map { o in
            guard o.sc == "Loyer" else { return o }
            var c = o
            let d = J.date(o.date)
            c.loyerPartage = remb.contains { abs($0.timeIntervalSince(d)) <= 45 * 86400 }
            return c
        }
    }

    struct Bilan {
        var rev = 0.0, bes = 0.0, env = 0.0, epa = 0.0, ref = 0.0
        var dep: Double { bes + env }
        var reste: Double { rev - dep - epa }
    }

    static func bilan<S: Sequence>(_ ops: S) -> Bilan where S.Element == Operation {
        var b = Bilan()
        for o in ops {
            let c = compense(o)
            switch c.cat {
            case .revenu: b.rev += c.montant; if Ref.revenusReference.contains(c.sc) { b.ref += c.montant }
            case .besoins: b.bes += c.montant
            case .envies: b.env += c.montant
            case .epargne: b.epa += c.montant
            case .virement: break
            }
        }
        return b
    }

    struct Regle { var parts: [Cat: Double]; var alertes: [String]; var base: Double }
    /// Parts calculées sur les revenus de référence (salaire, aides, aide familiale), tolérance de 5 points.
    static func regle(_ b: Bilan) -> Regle {
        let base = b.ref > 0 ? b.ref : max(b.bes, 0) + max(b.env, 0) + max(b.epa, 0)
        let p: (Double) -> Double = { base > 0 ? $0 / base * 100 : 0 }
        let parts: [Cat: Double] = [.besoins: p(b.bes), .envies: p(b.env), .epargne: p(b.epa)]
        var a: [String] = []
        if parts[.besoins]! > 55 { a.append("besoins trop élevés") }
        if parts[.envies]! > 35 { a.append("envies trop élevées") }
        if parts[.epargne]! < 15 { a.append("épargne insuffisante") }
        return Regle(parts: parts, alertes: a, base: base)
    }

    /// Effet d'une opération sur un compte : + ce qui entre, − ce qui sort ; un virement bouge deux comptes.
    static func effet(_ o: Operation, _ compte: String) -> Double {
        if o.cat == .virement { return (o.vers == compte ? o.montant : 0) - (o.compte == compte ? o.montant : 0) }
        guard o.compte == compte else { return 0 }
        return o.cat == .revenu ? o.montant : -o.montant
    }
    static func solde(_ ops: [Operation], _ compte: String, jusqua: String, initial: Double = 0) -> Double {
        ops.reduce(initial) { $1.date <= jusqua ? $0 + effet($1, compte) : $0 }
    }
    static func entre(_ ops: [Operation], _ debut: String, _ fin: String) -> [Operation] {
        ops.filter { $0.date >= debut && $0.date <= fin }
    }
    /// Dépenses du quotidien : sans charges fixes ni achats exceptionnels.
    static func courantes(_ ops: [Operation]) -> [Operation] {
        ops.map(compense).filter { $0.cat.estDepense && !Ref.chargesFixes.contains($0.sc) && $0.montant <= Ref.seuilExceptionnel }
    }
    /// Dépenses par thème, de la plus grosse à la plus petite.
    static func repartition(_ ops: [Operation]) -> [(sc: String, v: Double)] {
        var m: [String: Double] = [:]
        for o in ops { let c = compense(o); if c.cat.estDepense { m[c.sc, default: 0] += c.montant } }
        return m.filter { $0.value > 0.004 }.map { ($0.key, $0.value) }.sorted { $0.v > $1.v }
    }
    static func comptes(_ ops: [Operation]) -> [String] {
        var n: [String: Int] = [:]
        for o in ops where !o.compte.hasPrefix("cercle:") { n[o.compte, default: 0] += 1 }
        for o in ops where o.cat == .virement { if let v = o.vers, !v.hasPrefix("cercle:") { n[v, default: 0] += 1 } }
        n[""] = nil
        return [""] + n.sorted { $0.value > $1.value }.map(\.key)
    }

    // MARK: Périodes

    enum Mode: String, CaseIterable, Identifiable { case paie = "Depuis la paie", mois = "Mois civil", perso = "Personnalisée"; var id: String { rawValue } }

    struct Periode: Hashable {
        var mode: Mode
        var debut: String
        var fin: String
        var finBudget: String
        var precDebut: String?
        var precFin: String?
        var libelle: String
        /// Un mois ou un cycle de paie comptent pour un mois entier dans le budget ; une période libre, au prorata.
        var facteur: Double { mode == .perso ? Double(J.ecart(debut, fin) + 1) / Ref.joursParMois : 1 }
    }

    static func source(_ o: Operation) -> String {
        guard o.sc == "Salaire" else { return o.sc }
        let nom = Analyse.marchand(o).replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return nom.isEmpty ? "Salaire" : nom
    }
    /// Règle 1 : seules les paies du salaire principal (le plus gros sur 6 mois) ouvrent un cycle.
    static func joursDePaie(_ ops: [Operation]) -> [String] {
        let sal = ops.filter { $0.sc == "Salaire" }
        guard !sal.isEmpty else { return [] }
        let limite = J.plus(J.auj, jours: -183)
        let recents = sal.filter { $0.date >= limite }
        var parSource: [String: Double] = [:]
        for o in recents.isEmpty ? sal : recents { parSource[source(o), default: 0] += o.montant }
        guard let principal = parSource.max(by: { $0.value < $1.value })?.key else { return [] }
        var jours: [String] = []
        for d in Set(sal.filter { source($0) == principal }.map(\.date)).sorted() {
            if let der = jours.last, J.ecart(der, d) < 20 { continue }
            jours.append(d)
        }
        return jours
    }

    static func periode(_ mode: Mode, _ ops: [Operation], perso: (String, String)? = nil) -> Periode {
        let a = J.auj
        if mode == .perso, let (d, f) = perso {
            let n = J.ecart(d, f) + 1
            return Periode(mode: .perso, debut: d, fin: f, finBudget: f, precDebut: J.plus(d, jours: -n), precFin: J.plus(d, jours: -1),
                           libelle: "Du \(J.court(d)) au \(J.court(f))")
        }
        if mode == .paie {
            let jp = joursDePaie(ops).filter { $0 <= a }
            if let debut = jp.last {
                let finB = J.iso(J.plus(J.moisSuivant(J.date(debut)), jours: -1))
                var pd: String?, pf: String?
                if jp.count > 1 {
                    pd = jp[jp.count - 2]
                    let f = J.plus(pd!, jours: J.ecart(debut, a))
                    pf = f < debut ? f : J.plus(debut, jours: -1)
                }
                return Periode(mode: .paie, debut: debut, fin: a, finBudget: finB, precDebut: pd, precFin: pf, libelle: "Depuis la paie du \(J.court(debut))")
            }
        }
        let auj = J.aujourdhui, c = J.comp(auj)
        let p0 = J.faire(c.a, c.m - 1, 1)
        let pf = J.faire(c.a, c.m - 1, c.j)
        return Periode(mode: .mois, debut: J.iso(J.debutDuMois(auj)), fin: a, finBudget: J.iso(J.finDuMois(auj)),
                       precDebut: J.iso(p0), precFin: J.iso(pf), libelle: J.mois[c.m - 1].capitalizedPremiere)
    }

    // MARK: Mois par mois

    struct Mois: Identifiable, Hashable {
        var cle: String, debut: String, fin: String, libelle: String, long: String, enCours: Bool
        var id: String { cle }
    }
    static func moisDerniers(_ n: Int) -> [Mois] {
        let auj = J.aujourdhui, c = J.comp(auj)
        return (0..<n).reversed().map { k in
            let d = J.faire(c.a, c.m - k, 1), f = J.finDuMois(d), cc = J.comp(d)
            return Mois(cle: String(J.iso(d).prefix(7)), debut: J.iso(d), fin: J.iso(min(f, auj)), libelle: J.moisCourts[cc.m - 1],
                        long: "\(J.mois[cc.m - 1]) \(cc.a)", enCours: k == 0)
        }
    }
    static func mensuel(_ ops: [Operation], _ n: Int) -> [(mois: Mois, b: Bilan)] {
        moisDerniers(n).map { ($0, bilan(entre(ops, $0.debut, $0.fin))) }
    }
    /// Variation (en %) des 3 derniers mois par rapport aux 3 précédents.
    static func evolution(_ v: [Double]) -> Double? {
        guard v.count >= 6 else { return nil }
        let r = v.suffix(3).reduce(0, +), a = v.suffix(6).prefix(3).reduce(0, +)
        return a > 0 ? (r - a) / a * 100 : nil
    }
}
