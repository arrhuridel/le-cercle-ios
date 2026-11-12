import SwiftUI
import Charts

// Les quatre pages de détail d'Analyses (Dépenses, Épargne, Patrimoine, Charges fixes), refaites le 12/11/2026.
// Même construction partout : un grand chiffre, un graphique, une liste. Tous les calculs sont gardés en mémoire
// par le magasin (ils ne sont refaits que lorsque les données changent), et les montants sont mis en forme à l'affichage.

// MARK: - Calculs (gardés en mémoire)

/// Un mois (ou une année, sur « Toujours ») du graphique : revenus, dépenses, épargne et base de la règle 50-30-20.
struct PointAnalyse: Identifiable {
    let cle: String, libelle: String
    let rev: Double, dep: Double, epa: Double, ref: Double
    var id: String { cle }
}

struct AnalyseDepenses {
    struct Poste: Identifiable { let sc: String; let v: Double; let part: Double; var id: String { sc } }
    let total: Double, parMois: Double
    let postes: [Poste]
    let grosses: [Operation]
}

struct AnalyseEpargne {
    struct Support: Identifiable { let nom: String; let v: Double; let sous: String; let sc: String; var id: String { nom } }
    let total: Double, parMois: Double
    /// Part de l'épargne dans les revenus de référence (salaire, CAF, aide familiale), en %. nil sans revenu.
    let taux: Double?
    let supports: [Support]
}

struct PointCharges: Identifiable {
    let cle: String, libelle: String
    let fixes: Double, courantes: Double
    var id: String { cle }
}

struct PointPatrimoine: Identifiable {
    let jour: Date
    let v: Double
    var id: Date { jour }
}

struct AnalysePatrimoine {
    struct Groupe: Identifiable { let nom: String; let total: Double; let comptes: [CompteV3]; var id: String { nom } }
    let total: Double
    let groupes: [Groupe]
    let courbe: [PointPatrimoine]
    /// Ce qui a bougé sur la durée de la courbe (6 mois).
    var variation: Double { (courbe.last?.v ?? 0) - (courbe.first?.v ?? 0) }
}

/// Les quatre chiffres affichés sur les tuiles de la page Analyses.
struct ResumeAnalyses {
    let depensesParMois: Double
    let tauxEpargne: Double?
    let patrimoine: Double
    let chargesParMois: Double
    let nbCharges: Int
}

extension Magasin {
    func bilansAnalyse(_ d: Duree) -> [PointAnalyse] {
        memo("analyse.bilans|" + d.rawValue) {
            d.bilans(toutes).map { x in
                PointAnalyse(cle: x.t.cle, libelle: x.t.libelle, rev: x.b.rev, dep: x.b.dep, epa: x.b.epa, ref: x.b.ref)
            }
        }
    }

    func analyseDepenses(_ d: Duree) -> AnalyseDepenses {
        memo("analyse.depenses|" + d.rawValue) {
            let ops: [Operation] = toutes
            let periode: [Operation] = Calc.entre(ops, d.debut(ops), J.auj)
            let rep = Calc.repartition(periode)
            let total: Double = rep.reduce(0) { $0 + $1.v }
            let postes: [AnalyseDepenses.Poste] = rep.map { e in
                AnalyseDepenses.Poste(sc: e.sc, v: e.v, part: total > 0 ? e.v / total * 100 : 0)
            }
            let achats: [Operation] = periode.filter { $0.cat.estDepense && !Ref.chargesFixes.contains($0.sc) }
            let grosses: [Operation] = Array(achats.sorted { $0.montant > $1.montant }.prefix(5))
            return AnalyseDepenses(total: total, parMois: total / d.nbMois(ops), postes: postes, grosses: grosses)
        }
    }

    func analyseEpargne(_ d: Duree) -> AnalyseEpargne {
        memo("analyse.epargne|" + d.rawValue) {
            let ops: [Operation] = toutes
            let points: [PointAnalyse] = bilansAnalyse(d)
            let total: Double = points.reduce(0) { $0 + $1.epa }
            let base: Double = points.reduce(0) { $0 + $1.ref }
            // Le Livret vient des relevés (solde réel, comme le site) ; les autres supports, des versements nets
            let lv: Livrets? = livrets
            let epargne: [Operation] = ops.map(Calc.compense).filter { o in o.cat == .epargne && (lv == nil || o.sc != "Livret") }
            let groupes: [String: [Operation]] = Dictionary(grouping: epargne, by: { $0.sc })
            var supports: [AnalyseEpargne.Support] = []
            for (sc, l) in groupes {
                let somme: Double = l.reduce(0) { $0 + $1.montant }
                supports.append(AnalyseEpargne.Support(nom: sc, v: somme, sous: "versements moins retraits, depuis le début", sc: sc))
            }
            if let lv {
                for n in lv.noms {
                    supports.append(AnalyseEpargne.Support(nom: n, v: lv.solde(n, le: J.auj), sous: "solde d'après tes relevés", sc: "Livret"))
                }
            }
            supports.sort { $0.v > $1.v }
            return AnalyseEpargne(total: total, parMois: total / d.nbMois(ops), taux: base > 0 ? total / base * 100 : nil, supports: supports)
        }
    }

    func analyseCharges(_ d: Duree) -> [PointCharges] {
        memo("analyse.charges|" + d.rawValue) {
            let ops: [Operation] = toutes
            return d.tranches(ops).map { t in
                let l: [Operation] = Calc.entre(ops, t.debut, t.fin).map(Calc.compense).filter { $0.cat.estDepense }
                let fixes: Double = l.filter { Ref.chargesFixes.contains($0.sc) }.reduce(0) { $0 + $1.montant }
                let courantes: Double = l.filter { !Ref.chargesFixes.contains($0.sc) }.reduce(0) { $0 + $1.montant }
                return PointCharges(cle: t.cle, libelle: t.libelle, fixes: fixes, courantes: courantes)
            }
        }
    }

    /// Tout l'argent à une date : soldes des comptes, argent investi sur les comptes de placement, livrets.
    /// Même définition que le total de l'onglet Comptes (les deux écrans affichent donc le même chiffre).
    private func patrimoine(le jour: String, _ ops: [Operation], _ cles: [String], _ lv: Livrets?) -> Double {
        var somme: Double = 0
        for k in cles {
            somme += Calc.solde(ops, k, jusqua: jour, initial: soldesInitiaux[k] ?? 0)
            let bas = k.lowercased()
            if bas.contains("trade") || bas.contains("pea") {
                for o in ops where o.compte == k && o.date <= jour {
                    if o.sc == "Investissement" { somme += o.montant }
                    if o.sc == "Vente placement" { somme -= o.montant }
                }
            }
        }
        return somme + (lv?.total(le: jour) ?? 0)
    }

    var analysePatrimoine: AnalysePatrimoine {
        memo("analyse.patrimoine|\(Fmt.masque)|\(Fmt.confidentiel)") {
            let l: [CompteV3] = comptesV3
            let total: Double = l.reduce(0) { $0 + $1.solde }
            let ordre: [(String, String)] = [("Courant", "Comptes"), ("Livret", "Livrets"), ("Placement", "Placements"), ("Autre", "Autres")]
            var groupes: [AnalysePatrimoine.Groupe] = []
            for (type, nom) in ordre {
                let c: [CompteV3] = l.filter { $0.type == type }
                if !c.isEmpty { groupes.append(AnalysePatrimoine.Groupe(nom: nom, total: c.reduce(0) { $0 + $1.solde }, comptes: c)) }
            }
            let ops: [Operation] = toutes, cles: [String] = comptes, lv: Livrets? = livrets
            var courbe: [PointPatrimoine] = []
            for k in stride(from: 180, through: 0, by: -6) {
                let jour: String = J.plus(J.auj, jours: -k)
                courbe.append(PointPatrimoine(jour: J.date(jour), v: patrimoine(le: jour, ops, cles, lv)))
            }
            return AnalysePatrimoine(total: total, groupes: groupes, courbe: courbe)
        }
    }

    func resumeAnalyses(_ d: Duree) -> ResumeAnalyses {
        memo("analyse.resume|" + d.rawValue + "|\(Fmt.masque)|\(Fmt.confidentiel)") {
            let points: [PointAnalyse] = bilansAnalyse(d)
            let nb: Double = d.nbMois(toutes)
            let dep: Double = points.reduce(0) { $0 + $1.dep }
            let epa: Double = points.reduce(0) { $0 + $1.epa }
            let base: Double = points.reduce(0) { $0 + $1.ref }
            let charges: [Prelevements.Prelevement] = prelevements
            return ResumeAnalyses(depensesParMois: dep / nb, tauxEpargne: base > 0 ? epa / base * 100 : nil,
                                  patrimoine: comptesV3.reduce(0) { $0 + $1.solde },
                                  chargesParMois: charges.reduce(0) { $0 + $1.montant }, nbCharges: charges.count)
        }
    }
}

// MARK: - Briques communes aux quatre pages

/// Page de détail : le sélecteur de durée (si utile), puis le contenu qui défile.
struct PageAnalyse<Contenu: View>: View {
    let titre: String
    var avecDuree = true
    @ViewBuilder let contenu: Contenu
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if avecDuree { SelecteurDuree() }
                BandeauEtat()
                contenu
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(FondView())
        .navigationTitle(titre).navigationBarTitleDisplayMode(.large)
    }
}

/// Le chiffre principal de la page.
struct HeroAnalyse: View {
    let label: String
    let valeur: String
    var sous: String = ""
    var couleur: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(valeur).grandChiffre(40).foregroundStyle(couleur)
            if !sous.isEmpty { Text(sous).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .surface(in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

struct CarteAnalyse<Contenu: View>: View {
    let titre: String
    var sous: String = ""
    @ViewBuilder let contenu: Contenu
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(titre).font(.headline)
                Spacer()
                if !sous.isEmpty { Text(sous).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            contenu
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .surface(in: .rect(cornerRadius: 24))
    }
}

/// Une ligne de classement : pastille du thème, nom, montant, jauge et précision.
struct LignePoste: View {
    let sc: String
    let nom: String
    let montant: String
    /// Longueur de la jauge, de 0 à 100.
    let part: Double
    var sous: String = ""
    var body: some View {
        HStack(spacing: 12) {
            Tuile(sc: sc)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(nom).lineLimit(1); Spacer(); Text(montant).monospacedDigit().fontWeight(.semibold) }
                Jauge(part: part, couleur: Ref.theme(sc).teinte, hauteur: 5)
                if !sous.isEmpty { Text(sous).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

/// Moyenne des périodes terminées : la période en cours (mois ou année pas fini) est laissée de côté,
/// sinon elle tirerait la moyenne vers le bas. S'il n'y a qu'une période, on la garde.
func moyenneTerminee(_ barres: [Barre]) -> Double? {
    let l = barres.count > 1 ? Array(barres.dropLast()) : barres
    guard !l.isEmpty else { return nil }
    return l.reduce(0) { $0 + $1.v } / Double(l.count)
}

struct VideAnalyse: View {
    let texte: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar").font(.title2).foregroundStyle(.secondary)
            Text(texte).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity)
        .surface(in: .rect(cornerRadius: 24))
    }
}

// MARK: - Dépenses

struct DepensesDetail: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    @AppStorage("masque") private var masque = false

    var body: some View {
        let _ = masque
        let a: AnalyseDepenses = magasin.analyseDepenses(duree)
        let barres: [Barre] = magasin.bilansAnalyse(duree).map { Barre(cle: $0.cle, libelle: $0.libelle, v: $0.dep) }
        PageAnalyse(titre: "Dépenses") {
            HeroAnalyse(label: "Dépensé \(duree.texte)", valeur: Fmt.eur(a.total, 0), sous: "\(Fmt.eur(a.parMois, 0)) par mois en moyenne")
            if a.postes.isEmpty {
                VideAnalyse(texte: "Aucune dépense sur cette durée.")
            } else {
                CarteAnalyse(titre: duree == .tout ? "Année par année" : "Mois par mois") {
                    BarresInteractives(barres: barres, couleur: .rougeVif, repere: moyenneTerminee(barres), hausseBonne: false)
                }
                CarteAnalyse(titre: "Par catégorie", sous: "touche une part") {
                    AnneauCategories(postes: a.postes, total: a.total)
                }
                if !a.grosses.isEmpty {
                    CarteAnalyse(titre: "Plus gros achats", sous: "hors charges fixes") {
                        ForEach(a.grosses) { o in LigneOperation(op: o, magasin: magasin).frame(minHeight: 44) }
                    }
                }
            }
        }
    }
}

// MARK: - Épargne

struct EpargneDetail: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    @AppStorage("masque") private var masque = false

    var body: some View {
        let _ = masque
        let a: AnalyseEpargne = magasin.analyseEpargne(duree)
        let barres: [Barre] = magasin.bilansAnalyse(duree).map { Barre(cle: $0.cle, libelle: $0.libelle, v: $0.epa, base: $0.ref) }
        // Objectif de chaque période : 20 % du salaire et de la CAF reçus (moyenne des périodes terminées)
        let objectifs: [Barre] = barres.map { Barre(cle: $0.cle, libelle: $0.libelle, v: $0.base * 0.2) }
        let plusGros: Double = a.supports.map { abs($0.v) }.max() ?? 1
        PageAnalyse(titre: "Épargne") {
            HeroAnalyse(label: "Mis de côté \(duree.texte)", valeur: Fmt.eur(a.total, 0),
                        sous: sousTitre(a), couleur: a.total < 0 ? .negatif : .primary)
            CarteAnalyse(titre: duree == .tout ? "Année par année" : "Mois par mois", sous: "versements moins retraits") {
                BarresInteractives(barres: barres, repere: moyenneTerminee(objectifs), nomRepere: "objectif de 20 %",
                                   precision: { b in b.base > 0 ? "\(Fmt.pct(b.v / b.base * 100)) de ton salaire et de ta CAF" : "" })
            }
            if a.supports.isEmpty {
                VideAnalyse(texte: "Aucune épargne enregistrée pour l'instant.")
            } else {
                CarteAnalyse(titre: "Où est ton épargne") {
                    ForEach(a.supports) { s in
                        LignePoste(sc: s.sc, nom: s.nom, montant: Fmt.eur(s.v, 0), part: plusGros > 0 ? abs(s.v) / plusGros * 100 : 0, sous: s.sous)
                    }
                }
            }
        }
    }

    private func sousTitre(_ a: AnalyseEpargne) -> String {
        let moyenne = "\(Fmt.eur(a.parMois, 0)) par mois"
        guard let t = a.taux else { return moyenne }
        return moyenne + " · \(Fmt.pct(t)) de ton salaire et de ta CAF (repère : 20 %)"
    }
}

// MARK: - Patrimoine

struct PatrimoineDetail: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage("masque") private var masque = false

    var body: some View {
        let _ = masque
        let a: AnalysePatrimoine = magasin.analysePatrimoine
        PageAnalyse(titre: "Patrimoine", avecDuree: false) {
            HeroAnalyse(label: "Tout ton argent aujourd'hui", valeur: Fmt.eur(a.total, 0),
                        sous: "\(Fmt.eur(a.variation, 0, signe: true)) en 6 mois",
                        couleur: a.total < 0 ? .negatif : .primary)
            CarteAnalyse(titre: "Sur 6 mois", sous: "comptes, livrets et placements") {
                CourbeInteractive(points: a.courbe)
            }
            ForEach(a.groupes) { g in
                CarteAnalyse(titre: g.nom, sous: Fmt.eur(g.total, 0)) {
                    ForEach(g.comptes) { c in ligne(c, total: a.total) }
                }
            }
            Text("Même total que l'onglet Comptes. Les placements comptent pour l'argent disponible plus ce que tu as investi, pas pour leur valeur du jour.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
    }

    private func ligne(_ c: CompteV3, total: Double) -> some View {
        HStack(spacing: 12) {
            Text(c.logo).font(.caption.weight(.bold)).frame(width: 36, height: 36).background(.white.opacity(0.12), in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.nom).lineLimit(1)
                Text(c.detail ?? (total > 0 ? "\(Fmt.pct(c.solde / total * 100)) du total" : c.banque)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(Fmt.eur(c.solde, 0)).monospacedDigit().fontWeight(.semibold)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Charges fixes

struct ChargesDetail: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    @AppStorage("masque") private var masque = false

    var body: some View {
        let _ = masque
        let l: [Prelevements.Prelevement] = magasin.prelevements.sorted { $0.montant > $1.montant }
        let total: Double = l.reduce(0) { $0 + $1.montant }
        let base: Double = magasin.tableau(mode: .paie).b.ref
        let points: [PointCharges] = magasin.analyseCharges(duree)
        PageAnalyse(titre: "Charges fixes") {
            HeroAnalyse(label: "Ce qui tombe chaque mois", valeur: Fmt.eur(total),
                        sous: base > 0 ? "\(Fmt.pct(total / base * 100)) de ton salaire et de ta CAF · \(l.count) prélèvements" : "\(l.count) prélèvements")
            CarteAnalyse(titre: "Fixes et courantes", sous: duree == .tout ? "par année" : "par mois") {
                BarresEmpilees(points: points)
            }
            if l.isEmpty {
                VideAnalyse(texte: "Aucun prélèvement régulier détecté.")
            } else {
                CarteAnalyse(titre: "Tes prélèvements", sous: "du plus gros au plus petit") {
                    ForEach(l) { p in
                        HStack(spacing: 12) {
                            Tuile(sc: p.sc)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.nom).lineLimit(1)
                                Text("le \(p.jour) · \(p.estAbonnement ? "abonnement" : p.sc.lowercased())").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(p.montantTexte).monospacedDigit().fontWeight(.semibold)
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                    }
                }
                NavigationLink { AbonnementsView() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar").frame(width: 34, height: 34).background(.white.opacity(0.1), in: .rect(cornerRadius: 11))
                        Text("Voir le calendrier du mois").fontWeight(.semibold)
                        Spacer()
                        Chevron()
                    }
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 56)
                    .surface(in: .rect(cornerRadius: 24)).contentShape(.rect(cornerRadius: 24))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
