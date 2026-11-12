import SwiftUI
import Charts

/// Une rubrique d'analyse, ouverte en écran poussé depuis Analyses.
struct RubriqueView: View {
    let rubrique: Rubrique
    var body: some View {
        switch rubrique {
        case .conseiller: ConseillerView()
        case .patrimoine: PatrimoineView()
        default:
            Ecran {
                if Self.avecDuree.contains(rubrique) { SelecteurDuree() }
                contenu
            }
                .navigationTitle(rubrique.rawValue).navigationBarTitleDisplayMode(.inline)
        }
    }

    static let avecDuree: Set<Rubrique> = [.ensemble, .depenses, .marchands, .habitudes, .revenus, .epargne, .charges, .jeux, .saisons]

    @ViewBuilder private var contenu: some View {
        switch rubrique {
        case .score: ScoreVue()
        case .rapport: RapportVue()
        case .ensemble: EnsembleVue()
        case .depenses: DepensesVue()
        case .marchands: MarchandsVue()
        case .habitudes: HabitudesVue()
        case .revenus: RevenusVue()
        case .epargne: EpargneVue()
        case .charges: ChargesVue()
        case .comparer: ComparerVue()
        case .anomalies: AnomaliesVue()
        case .simulations: SimulationsVue()
        case .jeux: JeuxVue()
        case .saisons: SaisonsVue()
        default: EmptyView()
        }
    }
}


/// Classement en barres horizontales.
struct Classement: View {
    struct Ligne: Identifiable { var id: String { nom }; var nom: String; var v: Double; var sous: String = ""; var sc: String? = nil }
    let lignes: [Ligne]
    var body: some View {
        let max = lignes.map { abs($0.v) }.max() ?? 1
        CarteVerre(espacement: 12) {
            ForEach(lignes) { l in
                HStack(spacing: 12) {
                    if let sc = l.sc { Tuile(sc: sc) } else { Pastille(symbole: "circle.grid.2x2") }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(l.nom).lineLimit(1); Spacer(); Text(Fmt.eur(l.v, 0)).monospacedDigit().fontWeight(.semibold) }
                        Jauge(part: abs(l.v) / max * 100, couleur: l.sc.map { Ref.theme($0).teinte } ?? .secondary, hauteur: 5)
                        if !l.sous.isEmpty { Text(l.sous).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

private func carte<C: View>(_ titre: String, _ sous: String = "", @ViewBuilder _ c: () -> C) -> some View {
    CarteVerre {
        Text(titre).font(.headline)
        if !sous.isEmpty { Text(sous).font(.footnote).foregroundStyle(.secondary) }
        c()
    }
}

struct EnsembleVue: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    var body: some View {
        let ops = magasin.toutes, m = duree.bilans(ops).map { (mois: $0.t, b: $0.b) }
        carte("Comment respire mon compte ?", "Revenus au-dessus de l'axe, dépenses et épargne en dessous") {
            Chart(m, id: \.mois.cle) { x in
                BarMark(x: .value("Mois", x.mois.libelle), y: .value("€", x.b.rev)).foregroundStyle(Color.positif)
                BarMark(x: .value("Mois", x.mois.libelle), y: .value("€", -(x.b.dep + max(x.b.epa, 0)))).foregroundStyle(Color(red: 0.76, green: 0.6, blue: 0.43))
            }.frame(height: 200)
        }
        carte("Mon solde en fin de mois", "Compte courant") {
            Chart(m, id: \.mois.cle) { x in
                LineMark(x: .value("Mois", x.mois.libelle), y: .value("€", Calc.solde(ops, "", jusqua: x.mois.fin, initial: magasin.soldesInitiaux[""] ?? 0))).interpolationMethod(.catmullRom)
            }.frame(height: 150)
        }
        carte("La règle 50-30-20 dans le temps", "Part des revenus de référence") {
            Chart {
                ForEach(m, id: \.mois.cle) { x in
                    let r = Calc.regle(x.b)
                    LineMark(x: .value("Mois", x.mois.libelle), y: .value("%", r.parts[.besoins] ?? 0)).foregroundStyle(by: .value("Part", "Besoins"))
                    LineMark(x: .value("Mois", x.mois.libelle), y: .value("%", r.parts[.envies] ?? 0)).foregroundStyle(by: .value("Part", "Envies"))
                    LineMark(x: .value("Mois", x.mois.libelle), y: .value("%", r.parts[.epargne] ?? 0)).foregroundStyle(by: .value("Part", "Épargne"))
                }
            }.frame(height: 170)
        }
        let annees = Array(Set(ops.map { String($0.date.prefix(4)) })).sorted()
        TitreSection(texte: "Bilan année par année")
        CarteVerre(espacement: 10) {
            ForEach(annees, id: \.self) { a in
                let b = Calc.bilan(Calc.entre(ops, "\(a)-01-01", "\(a)-12-31"))
                HStack { Text(a).fontWeight(.semibold); Spacer(); Text("revenus \(Fmt.eur(b.rev, 0)) · dépenses \(Fmt.eur(b.dep, 0))").font(.footnote).foregroundStyle(.secondary); Text(Fmt.eur(b.epa, 0)).monospacedDigit() }
            }
        }
    }
}

struct DepensesVue: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    var body: some View {
        let ops = magasin.toutes, debut = duree.debut(ops), opsP = Calc.entre(ops, debut, J.auj)
        let rep = Calc.repartition(opsP), total = rep.reduce(0) { $0 + $1.v }
        let nb = duree.nbMois(ops)
        Text("\(Fmt.eur(total, 0)) de dépenses \(duree.texte)").font(.footnote).foregroundStyle(.secondary)
        let mois = Calc.mensuel(ops, 7).filter { !$0.mois.enCours }.suffix(6)
        Classement(lignes: rep.prefix(10).map { e in
            let v = mois.map { m in Calc.entre(ops, m.mois.debut, m.mois.fin).map(Calc.compense).filter { $0.sc == e.sc }.reduce(0) { $0 + $1.montant } }
            let evo = Calc.evolution(Array(v)).map { abs($0) >= 3 ? " · \($0 > 0 ? "↗" : "↘") \(Fmt.pct(abs($0))) sur 3 mois" : "" } ?? ""
            return Classement.Ligne(nom: e.sc, v: e.v, sous: "\(Fmt.pct(e.v / max(total, 1) * 100)) · \(Fmt.eur(e.v / nb, 0)) par mois" + evo, sc: e.sc)
        })
        carte(duree == .tout ? "Mes 5 postes, année par année" : "Mes 5 postes, mois par mois") {
            Chart {
                ForEach(duree.tranches(ops)) { m in
                    ForEach(rep.prefix(5), id: \.sc) { e in
                        BarMark(x: .value("Mois", m.libelle), y: .value("€", Calc.entre(ops, m.debut, m.fin).map(Calc.compense).filter { $0.sc == e.sc }.reduce(0) { $0 + $1.montant }))
                            .foregroundStyle(Ref.theme(e.sc).teinte)
                    }
                }
            }.frame(height: 190)
        }
        TitreSection(texte: "Mes plus grosses dépenses")
        CarteVerre(espacement: 10) {
            ForEach(opsP.filter { $0.cat.estDepense }.sorted { $0.montant > $1.montant }.prefix(6)) { o in LigneOperation(op: o, magasin: magasin) }
        }
        let tranches: [(String, Double, Double)] = [("< 10 €", 0, 10), ("10–30", 10, 30), ("30–60", 30, 60), ("60–150", 60, 150), ("150 € +", 150, 1e9)]
        carte("Petits et gros achats", "Nombre d'achats par tranche de prix") {
            Chart(tranches, id: \.0) { t in BarMark(x: .value("Tranche", t.0), y: .value("Achats", opsP.filter { $0.cat.estDepense && $0.montant >= t.1 && $0.montant < t.2 }.count)).foregroundStyle(.secondary) }
                .frame(height: 140)
        }
    }
}

struct MarchandsVue: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    var body: some View {
        let opsP = Calc.entre(magasin.toutes, duree.debut(magasin.toutes), J.auj).filter { $0.cat.estDepense && !["Loyer", "Factures", "Assurances", "Espèces"].contains($0.sc) }
        let g = Dictionary(grouping: opsP, by: Analyse.marchand).map { (nom: $0.key, l: $0.value) }.sorted { $0.l.reduce(0) { $0 + $1.montant } > $1.l.reduce(0) { $0 + $1.montant } }
        Text("\(opsP.count) achats \(duree.texte), hors loyer, factures, assurances et espèces").font(.footnote).foregroundStyle(.secondary)
        Classement(lignes: g.prefix(15).map { e in
            let s = e.l.reduce(0) { $0 + $1.montant }
            return Classement.Ligne(nom: e.nom, v: s, sous: "\(e.l.count) achat\(e.l.count > 1 ? "s" : "") · panier moyen \(Fmt.eur(s / Double(e.l.count)))", sc: e.l.first?.sc)
        })
        let villes = Dictionary(grouping: opsP.compactMap { o -> (String, Double)? in
            let p = o.note.components(separatedBy: " · "); return p.count > 1 ? (p[1].trimmingCharacters(in: .whitespaces), o.montant) : nil
        }, by: \.0).map { ($0.key, $0.value.reduce(0) { $0 + $1.1 }) }.sorted { $0.1 > $1.1 }
        if !villes.isEmpty {
            TitreSection(texte: "Où je dépense")
            Classement(lignes: villes.prefix(10).map { Classement.Ligne(nom: $0.0, v: $0.1) })
        }
    }
}

struct HabitudesVue: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    var body: some View {
        let cour = Calc.courantes(Calc.entre(magasin.toutes, duree.debut(magasin.toutes), J.auj))
        let nb = duree.nbMois(magasin.toutes)
        let parJour = Dictionary(grouping: cour, by: \.date).mapValues { $0.reduce(0) { $0 + $1.montant } }
        let maxJ = parJour.values.max() ?? 1
        carte("Le calendrier de mes dépenses", "6 derniers mois · plus la case est claire, plus la journée a coûté") {
            let debut = J.plus(J.aujourdhui, jours: -182), lundi = J.plus(debut, jours: -J.jourSemaine(J.iso(debut)))
            let jours = (0...J.ecart(lundi, J.aujourdhui)).map { J.iso(J.plus(lundi, jours: $0)) }
            LazyHGrid(rows: Array(repeating: GridItem(.fixed(9), spacing: 3), count: 7), spacing: 3) {
                ForEach(jours, id: \.self) { d in
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(parJour[d].map { 0.25 + 0.75 * $0 / maxJ } ?? 0.07)).frame(width: 9, height: 9)
                }
            }
            .frame(height: 85)
        }
        let noms = ["lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim."]
        carte("Mes jours de dépense", "Dépenses courantes moyennes par semaine, \(duree.texte)") {
            Chart(0..<7, id: \.self) { i in BarMark(x: .value("Jour", noms[i]), y: .value("€", cour.filter { J.jourSemaine($0.date) == i }.reduce(0) { $0 + $1.montant } / (nb * 4.345))).foregroundStyle(Color(red: 0.44, green: 0.66, blue: 0.64)) }
                .frame(height: 150)
        }
        let tiers: [(String, ClosedRange<Int>)] = [("1 au 10", 1...10), ("11 au 20", 11...20), ("21 au 31", 21...31)]
        carte("Début ou fin de mois ?", "Dépenses courantes moyennes par mois, \(duree.texte)") {
            Chart(tiers, id: \.0) { t in BarMark(x: .value("Période", t.0), y: .value("€", cour.filter { t.1.contains(J.comp(J.date($0.date)).j) }.reduce(0) { $0 + $1.montant } / nb)).foregroundStyle(Color(red: 0.76, green: 0.6, blue: 0.43)) }
                .frame(height: 140)
        }
        let paies = Calc.joursDePaie(magasin.toutes).suffix(4)
        if paies.count >= 2 {
            carte("Le rythme après la paie", "Dépenses courantes cumulées depuis le jour de paie · en clair, le cycle en cours") {
                Chart {
                    ForEach(Array(paies.enumerated()), id: \.offset) { i, p in
                        let fin = i + 1 < paies.count ? Array(paies)[i + 1] : J.plus(J.auj, jours: 1)
                        let points = (0..<31).compactMap { k -> (Int, Double)? in
                            let d = J.plus(p, jours: k); guard d < fin, d <= J.auj else { return nil }
                            return (k + 1, (0...k).reduce(0) { $0 + (parJour[J.plus(p, jours: $1)] ?? 0) })
                        }
                        ForEach(points, id: \.0) { pt in
                            LineMark(x: .value("Jour", pt.0), y: .value("€", pt.1), series: .value("Cycle", p)).foregroundStyle(i == paies.count - 1 ? Color.primary : Color.secondary.opacity(0.5))
                        }
                    }
                }.frame(height: 170)
            }
        }
    }
}

struct RevenusVue: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    var body: some View {
        let revs = Calc.entre(magasin.toutes, duree.debut(magasin.toutes), J.auj).filter { $0.cat == .revenu && Ref.compensations[$0.sc] == nil }
        let source: (Operation) -> String = { $0.sc == "Salaire" ? Calc.source($0) : $0.sc }
        let tot = revs.reduce(0) { $0 + $1.montant }, sal = revs.filter { $0.sc == "Salaire" }.reduce(0) { $0 + $1.montant }
        HStack {
            Kpi(titre: "Total", valeur: Fmt.eur(tot, 0), sous: duree.texte, couleur: .positif)
            Kpi(titre: "Moyenne", valeur: Fmt.eur(tot / duree.nbMois(magasin.toutes), 0), sous: "par mois")
        }
        carte("D'où vient mon argent ?", "Chaque employeur à part, comme sur le site") {
            Chart {
                ForEach(duree.tranches(magasin.toutes)) { m in
                    ForEach(Array(Set(revs.map(source))).sorted(), id: \.self) { s in
                        BarMark(x: .value("Mois", m.libelle), y: .value("€", revs.filter { source($0) == s && $0.date >= m.debut && $0.date <= m.fin }.reduce(0) { $0 + $1.montant })).foregroundStyle(by: .value("Source", s))
                    }
                }
            }.frame(height: 200)
        }
        Classement(lignes: Dictionary(grouping: revs, by: source).map { Classement.Ligne(nom: $0.key, v: $0.value.reduce(0) { $0 + $1.montant }, sous: "", sc: $0.value.first?.sc) }.sorted { $0.v > $1.v })
        Kpi(titre: "Autonomie", valeur: Fmt.pct(tot > 0 ? sal / tot * 100 : 0), sous: "part du salaire dans les revenus, \(duree.texte)")
    }
}

struct EpargneVue: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    var body: some View {
        let ops = magasin.toutes, m = duree.bilans(ops).map { (mois: $0.t, b: $0.b) }
        let tot = m.reduce(0) { $0 + $1.b.epa }
        HStack {
            Kpi(titre: "Épargné", valeur: Fmt.eur(tot, 0), sous: duree.texte, couleur: tot >= 0 ? .positif : .negatif)
            Kpi(titre: "Moyenne", valeur: Fmt.eur(tot / duree.nbMois(ops), 0), sous: "par mois")
        }
        carte("Est-ce que je mets vraiment de côté ?", duree == .tout ? "Épargne nette de chaque année : versements moins retraits" : "Épargne nette de chaque mois : versements moins retraits") {
            Chart(m, id: \.mois.cle) { x in BarMark(x: .value("Mois", x.mois.libelle), y: .value("€", x.b.epa)).foregroundStyle(x.b.epa >= 0 ? Color.positif : Color.negatif) }.frame(height: 170)
        }
        carte("Mon taux d'épargne", "Repère : 20 %") {
            Chart {
                ForEach(m, id: \.mois.cle) { x in LineMark(x: .value("Mois", x.mois.libelle), y: .value("%", x.b.rev > 0 ? x.b.epa / x.b.rev * 100 : 0)).foregroundStyle(Color.positif) }
                RuleMark(y: .value("Repère", 20)).lineStyle(StrokeStyle(dash: [4])).foregroundStyle(.secondary)
            }.frame(height: 150)
        }
        // Le Livret vient des relevés (solde réel, comme le site) ; les autres supports, des versements nets
        TitreSection(texte: "Mes supports")
        Classement(lignes: Self.supports(ops, magasin.livrets))
    }

    /// Découpé en étapes typées : en une seule expression, le compilateur abandonnait (trop long à vérifier).
    private static func supports(_ ops: [Operation], _ lv: Livrets?) -> [Classement.Ligne] {
        let epargne: [Operation] = ops.map(Calc.compense).filter { o in o.cat == .epargne && (lv == nil || o.sc != "Livret") }
        let groupes: [String: [Operation]] = Dictionary(grouping: epargne, by: { $0.sc })
        var lignes: [Classement.Ligne] = []
        for (sc, l) in groupes {
            let total: Double = l.reduce(0) { $0 + $1.montant }
            lignes.append(Classement.Ligne(nom: sc, v: total, sous: "versements − retraits depuis le début", sc: sc))
        }
        if let lv {
            for n in lv.noms { lignes.append(Classement.Ligne(nom: n, v: lv.solde(n, le: J.auj), sous: "solde d'après tes relevés", sc: "Livret")) }
        }
        return lignes.sorted { $0.v > $1.v }
    }
}

struct ChargesVue: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    var body: some View {
        let ops = magasin.toutes, m = duree.tranches(ops).map { (mois: $0, b: 0) }
        carte("Charges fixes ou dépenses courantes ?", "Ce qui tombe chaque mois quoi qu'il arrive, et le reste") {
            Chart {
                ForEach(m, id: \.mois.cle) { x in
                    let l = Calc.entre(ops, x.mois.debut, x.mois.fin).map(Calc.compense).filter { $0.cat.estDepense }
                    BarMark(x: .value("Mois", x.mois.libelle), y: .value("€", l.filter { Ref.chargesFixes.contains($0.sc) }.reduce(0) { $0 + $1.montant })).foregroundStyle(by: .value("Type", "Charges fixes"))
                    BarMark(x: .value("Mois", x.mois.libelle), y: .value("€", l.filter { !Ref.chargesFixes.contains($0.sc) }.reduce(0) { $0 + $1.montant })).foregroundStyle(by: .value("Type", "Courantes"))
                }
            }.frame(height: 190)
        }
        let abos = Suivi.abonnements(ops)
        Kpi(titre: "Abonnements actifs", valeur: "\(abos.count)", sous: "\(Fmt.eur(abos.reduce(0) { $0 + $1.mensuel }, 0)) par mois")
        NavigationLink("Tous les prélèvements et le calendrier") { PrelevementsView(recs: Suivi.recurrents(ops)) }.tint(.primary).font(.subheadline.weight(.semibold))
    }
}

struct ComparerVue: View {
    @Environment(Magasin.self) private var magasin
    @State private var a1 = J.debutDuMois(J.aujourdhui)
    @State private var a2 = J.aujourdhui
    @State private var b1 = J.debutDuMois(J.plus(J.debutDuMois(J.aujourdhui), jours: -1))
    @State private var b2 = J.plus(J.debutDuMois(J.aujourdhui), jours: -1)
    var body: some View {
        let ops = magasin.toutes
        let A = Calc.entre(ops, J.iso(a1), J.iso(a2)), B = Calc.entre(ops, J.iso(b1), J.iso(b2))
        let ba = Calc.bilan(A), bb = Calc.bilan(B)
        let ja = Double(J.ecart(a1, min(a2, J.aujourdhui)) + 1), jb = Double(J.ecart(b1, b2) + 1)
        CarteVerre {
            Text("Période 1").font(.headline)
            DatePicker("Du", selection: $a1, displayedComponents: .date); DatePicker("Au", selection: $a2, displayedComponents: .date)
            Text("Période 2").font(.headline).padding(.top, 6)
            DatePicker("Du", selection: $b1, displayedComponents: .date); DatePicker("Au", selection: $b2, displayedComponents: .date)
        }
        carte("Ce qui a changé") {
            Text("Tu as dépensé \(Fmt.eur(ba.dep)) contre \(Fmt.eur(bb.dep)) : \(Fmt.eur(abs(ba.dep - bb.dep))) de \(ba.dep > bb.dep ? "plus" : "moins"). Par jour : \(Fmt.eur(ba.dep / ja)) contre \(Fmt.eur(bb.dep / jb)).")
                .font(.subheadline).foregroundStyle(.secondary)
            Chart {
                ForEach([("Revenus", ba.rev, bb.rev), ("Besoins", ba.bes, bb.bes), ("Envies", ba.env, bb.env), ("Épargne", ba.epa, bb.epa)], id: \.0) { c in
                    BarMark(x: .value("Poste", c.0), y: .value("€", c.1)).foregroundStyle(by: .value("Période", "Période 1")).position(by: .value("Période", "1"))
                    BarMark(x: .value("Poste", c.0), y: .value("€", c.2)).foregroundStyle(by: .value("Période", "Période 2")).position(by: .value("Période", "2"))
                }
            }.frame(height: 170)
        }
        let ta = Dictionary(Calc.repartition(A).map { ($0.sc, $0.v) }, uniquingKeysWith: +), tb = Dictionary(Calc.repartition(B).map { ($0.sc, $0.v) }, uniquingKeysWith: +)
        let ecarts = Set(ta.keys).union(tb.keys).map { ($0, (ta[$0] ?? 0) - (tb[$0] ?? 0)) }.filter { abs($0.1) > 0.5 }.sorted { abs($0.1) > abs($1.1) }.prefix(8)
        TitreSection(texte: "Les plus gros changements")
        CarteVerre(espacement: 10) {
            ForEach(Array(ecarts), id: \.0) { sc, d in
                HStack(spacing: 12) { Tuile(sc: sc); Text(sc); Spacer(); Text(Fmt.eur(d, signe: true)).monospacedDigit().foregroundStyle(d < 0 ? Color.positif : Color.negatif) }
            }
        }
    }
}

struct AnomaliesVue: View {
    @Environment(Magasin.self) private var magasin
    @State private var aSupprimer: Operation?
    var body: some View {
        let a = Conseil.anomalies(magasin.ops, ignores: magasin.ignores)
        TitreSection(texte: "Doublons possibles")
        CarteVerre(espacement: 12) {
            if a.doublons.isEmpty { Label("Aucun doublon repéré", systemImage: "checkmark.circle").foregroundStyle(Color.positif) }
            ForEach(a.doublons, id: \.1.id) { x, y in
                HStack(spacing: 12) {
                    Tuile(sc: y.sc)
                    VStack(alignment: .leading) { Text("\(y.note.isEmpty ? y.sc : y.note) · \(Fmt.eur(y.montant))"); Text("saisi le \(J.court(x.date)) et le \(J.court(y.date))").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Supprimer", role: .destructive) { aSupprimer = y }.font(.footnote)
                    Button { magasin.ignorer(y.id) } label: { Image(systemName: "checkmark") }.accessibilityLabel("Ce n'est pas un doublon")
                }
                .buttonStyle(.borderless)
            }
        }
        Color.clear.frame(height: 0)
            .confirmationDialog("Supprimer ce doublon ?", isPresented: Binding(get: { aSupprimer != nil }, set: { if !$0 { aSupprimer = nil } }), titleVisibility: .visible, presenting: aSupprimer) { y in
                Button("Supprimer \(y.note.isEmpty ? y.sc : y.note) du \(J.court(y.date))", role: .destructive) { Task { await magasin.supprimer(y) } }
            } message: { _ in Text("La seconde saisie sera supprimée de la base (site compris). La première reste.") }
        TitreSection(texte: "Dépenses inhabituelles")
        CarteVerre(espacement: 12) {
            if a.inhabituelles.isEmpty { Text("Rien d'inhabituel.").foregroundStyle(.secondary) }
            ForEach(a.inhabituelles.prefix(15), id: \.0.id) { o, med in
                HStack(spacing: 12) {
                    Tuile(sc: o.sc)
                    VStack(alignment: .leading) { Text("\(o.note.isEmpty ? o.sc : o.note) · \(Fmt.eur(o.montant))"); Text("\(J.libelleJour(o.date)) · d'habitude \(Fmt.eur(med)) chez ce marchand").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        Text("Repérés sur ton iPhone : la même opération deux fois à 2 jours d'écart, ou une dépense plus de 2,5 fois plus chère que d'habitude chez le même marchand.").font(.caption).foregroundStyle(.secondary)
    }
}

struct SimulationsVue: View {
    @Environment(Magasin.self) private var magasin
    @State private var envies = 0.0
    @State private var epargne = 0.0
    @State private var mois = 12.0
    @State private var abosCoupes: Set<String> = []
    var body: some View {
        let ops = magasin.toutes, m = Calc.mensuel(ops, 5).filter { !$0.mois.enCours }, nb = Double(max(m.count, 1))
        let env = m.reduce(0) { $0 + $1.b.env } / nb, epa = m.reduce(0) { $0 + $1.b.epa } / nb
        let abos = Suivi.abonnements(ops)
        let gain = env * envies / 100 + abos.filter { abosCoupes.contains($0.nom) }.reduce(0) { $0 + $1.mensuel }
        CarteVerre(espacement: 12) {
            Text("Et si…").font(.headline)
            VStack(alignment: .leading) { HStack { Text("Réduire mes envies de"); Spacer(); Text(Fmt.pct(envies)).bold() }; Slider(value: $envies, in: 0...50, step: 5) }
            VStack(alignment: .leading) { HStack { Text("Épargner en plus chaque mois"); Spacer(); Text(Fmt.eur(epargne, 0)).bold() }; Slider(value: $epargne, in: 0...300, step: 10) }
            VStack(alignment: .leading) { HStack { Text("Sur une durée de"); Spacer(); Text("\(Int(mois)) mois").bold() }; Slider(value: $mois, in: 3...36, step: 3) }
            if !abos.isEmpty {
                Text("Résilier des abonnements").etiquette()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(abos, id: \.nom) { a in Button("\(a.nom) · \(Fmt.eur(a.mensuel, 0))") { if abosCoupes.contains(a.nom) { abosCoupes.remove(a.nom) } else { abosCoupes.insert(a.nom) } }.puce(abosCoupes.contains(a.nom)) } }
                }
            }
        }
        .tint(.primary)
        CarteVerre(espacement: 8) {
            Text("Résultat").font(.headline)
            Text(Fmt.eur((gain + epargne) * mois, 0, signe: true)).font(.largeTitle.weight(.bold)).foregroundStyle(Color.positif).monospacedDigit()
            Text("mis de côté en plus en \(Int(mois)) mois (\(Fmt.eur(gain + epargne, 0)) par mois, dont \(Fmt.eur(gain, 0)) d'économies)").font(.footnote).foregroundStyle(.secondary)
            Text("Ton épargne passerait de \(Fmt.eur(epa, 0)) à \(Fmt.eur(epa + gain + epargne, 0)) par mois.").font(.subheadline)
            ForEach(Suivi.objectifs(magasin.objectifs, ops, livret: magasin.totalLivrets).filter { $0.reste > 0 }) { o in
                let apres = Int((o.reste / max(o.rythme + gain + epargne, 1)).rounded(.up))
                Text("\(o.o.nom) : atteint en \(apres) mois" + (o.estimation.map { " au lieu de \($0)" } ?? "")).font(.subheadline)
            }
        }
    }
}

struct ScoreVue: View {
    @Environment(Magasin.self) private var magasin
    var body: some View {
        let s = Conseil.score(magasin.tableau(), budgetMensuel: magasin.profil?.budget ?? 0)
        CarteVerre {
            Gauge(value: Double(s.total), in: 0...100) { Text("Santé") } currentValueLabel: { Text("\(s.total)").font(.title.bold()) }
                .gaugeStyle(.accessoryCircularCapacity).tint(Color.positif).scaleEffect(2).frame(height: 130).frame(maxWidth: .infinity)
            Text(s.niveau).font(.title2.weight(.semibold)).frame(maxWidth: .infinity)
            Text("Six critères simples, sur tes 6 derniers mois complets").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        CarteVerre(espacement: 14) {
            ForEach(s.criteres) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(c.nom); Spacer(); Text("\(Int(c.points.rounded())) / \(Int(c.max))").monospacedDigit() }
                    Jauge(part: c.points / c.max * 100, couleur: c.points / c.max < 0.5 ? .alerte : .positif, hauteur: 6)
                    Text(c.detail + (c.points < c.max * 0.8 ? " · \(c.conseil)" : "")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Text("Un repère pour progresser, pas un jugement ni un conseil financier réglementé.").font(.caption).foregroundStyle(.secondary)
    }
}

struct JeuxVue: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    var body: some View {
        let j = Calc.entre(magasin.toutes, duree.debut(magasin.toutes), J.auj).filter { $0.sc == "Jeux d'argent" || $0.sc == "Gains de jeux" }
        let mises = j.filter { $0.cat != .revenu }.reduce(0) { $0 + $1.montant }, gains = j.filter { $0.cat == .revenu }.reduce(0) { $0 + $1.montant }
        if j.isEmpty { CarteVerre { Text("Aucun pari ni gain \(duree.texte).").foregroundStyle(.secondary) } }
        else {
            HStack { Kpi(titre: "Misé", valeur: Fmt.eur(mises, 0), sous: duree.texte); Kpi(titre: "Résultat net", valeur: Fmt.eur(gains - mises, 0, signe: true), couleur: gains >= mises ? .positif : .negatif) }
            carte("Mes jeux d'argent, mois par mois", "Gains au-dessus, mises en dessous") {
                Chart(duree.tranches(magasin.toutes)) { m in
                    BarMark(x: .value("Mois", m.libelle), y: .value("€", j.filter { $0.cat == .revenu && $0.date >= m.debut && $0.date <= m.fin }.reduce(0) { $0 + $1.montant })).foregroundStyle(Color.positif)
                    BarMark(x: .value("Mois", m.libelle), y: .value("€", -j.filter { $0.cat != .revenu && $0.date >= m.debut && $0.date <= m.fin }.reduce(0) { $0 + $1.montant })).foregroundStyle(Color.negatif)
                }.frame(height: 180)
            }
        }
    }
}

struct SaisonsVue: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    var body: some View {
        let m = Calc.mensuel(magasin.toutes, duree.moisEntiers(magasin.toutes)).filter { !$0.mois.enCours && $0.b.dep > 0 }
        let parMois = (1...12).map { k -> Double in let l = m.filter { Int($0.mois.cle.suffix(2)) == k }; return l.isEmpty ? 0 : l.reduce(0) { $0 + $1.b.dep } / Double(l.count) }
        let barres: [(cle: String, nom: String, v: Double)] = duree == .tout
            ? (0..<12).map { (cle: "\($0)", nom: J.moisCourts[$0], v: parMois[$0]) }
            : m.map { (cle: $0.mois.cle, nom: $0.mois.libelle, v: $0.b.dep) }
        let plusCher = barres.max { $0.v < $1.v }
        if let plusCher { Kpi(titre: "Le mois le plus cher", valeur: plusCher.nom, sous: Fmt.eur(plusCher.v, 0)) }
        carte("Les mois qui coûtent", duree == .tout ? "Dépenses moyennes de chaque mois de l'année" : "Dépenses de chaque mois complet, \(duree.texte)") {
            Chart(barres, id: \.cle) { b in BarMark(x: .value("Mois", b.nom), y: .value("€", b.v)).foregroundStyle(b.cle == plusCher?.cle ? Color.white : Color(red: 0.77, green: 0.56, blue: 0.54)) }.frame(height: 180)
        }
        Text("La saisonnalité devient fiable avec au moins un an d'historique.").font(.caption).foregroundStyle(.secondary)
    }
}

struct RapportVue: View {
    @Environment(Magasin.self) private var magasin
    @State private var index: Int?
    var body: some View {
        let ops = magasin.toutes
        let mois = Calc.mensuel(ops, 12).filter { !$0.mois.enCours && $0.b.rev + $0.b.dep > 0 }
        if mois.isEmpty { CarteVerre { Text("Il faut au moins un mois complet.").foregroundStyle(.secondary) } }
        else {
            let i = min(index ?? mois.count - 1, mois.count - 1), m = mois[i], p = i > 0 ? mois[i - 1] : nil
            let l = Calc.entre(ops, m.mois.debut, m.mois.fin), rep = Calc.repartition(l)
            Picker("Mois", selection: Binding(get: { i }, set: { index = $0 })) { ForEach(mois.indices, id: \.self) { Text(mois[$0].mois.long.capitalizedPremiere).tag($0) } }.tint(.primary)
            let rapport = VStack(alignment: .leading, spacing: 12) {
                CarteVerre {
                    Text("Rapport mensuel").font(.footnote).foregroundStyle(.secondary)
                    Text(m.mois.long.capitalizedPremiere).font(.title.weight(.bold))
                    Text(Fmt.eur(m.b.dep, 0)).grandChiffre(40, design: .default)
                    if let p, p.b.dep > 0 { Text("dépensés · \(m.b.dep >= p.b.dep ? "+" : "−")\(Fmt.pct(abs(m.b.dep - p.b.dep) / p.b.dep * 100)) par rapport à \(p.mois.libelle)").font(.footnote).foregroundStyle(.secondary) }
                }
                HStack { Kpi(titre: "Revenus", valeur: Fmt.eur(m.b.rev, 0)); Kpi(titre: "Épargne", valeur: Fmt.eur(m.b.epa, 0), couleur: m.b.epa < 0 ? .negatif : .positif) }
                Classement(lignes: rep.prefix(3).map { Classement.Ligne(nom: $0.sc, v: $0.v, sous: "\(Fmt.pct($0.v / max(m.b.dep, 1) * 100)) des dépenses", sc: $0.sc) })
                if let g = l.filter({ $0.cat.estDepense }).max(by: { $0.montant < $1.montant }) {
                    CarteVerre { Text("Plus grosse dépense").font(.headline); LigneOperation(op: g, magasin: magasin) }
                }
            }
            rapport
            ShareLink(item: RapportPDF(vue: AnyView(rapport.environment(magasin).padding().background(Color.white).environment(\.colorScheme, .light)), titre: m.mois.long),
                      preview: SharePreview("Rapport \(m.mois.long)")) {
                Label("Exporter en PDF", systemImage: "doc.richtext").frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .verre(.regular.interactive(), in: .capsule).tint(.primary)
        }
    }
}

/// Le rapport rendu en PDF au moment du partage (ImageRenderer de SwiftUI).
struct RapportPDF: Transferable {
    let vue: AnyView
    let titre: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { r in await r.pdf() }
            .suggestedFileName("rapport-le-cercle.pdf")
    }
    @MainActor func pdf() -> Data {
        let rendu = ImageRenderer(content: vue.frame(width: 400))
        let donnees = NSMutableData()
        rendu.render { taille, dessiner in
            var boite = CGRect(origin: .zero, size: taille)
            guard let consommateur = CGDataConsumer(data: donnees as CFMutableData), let ctx = CGContext(consumer: consommateur, mediaBox: &boite, nil) else { return }
            ctx.beginPDFPage(nil); dessiner(ctx); ctx.endPDFPage(); ctx.closePDF()
        }
        return donnees as Data
    }
}
