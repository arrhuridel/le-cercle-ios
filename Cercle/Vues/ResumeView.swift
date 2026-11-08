import SwiftUI
import Charts

/// Résumé : sélecteur Dépenses / Budget / Comptes, anneau par catégorie, budget, cartes et phrase de synthèse.
struct ResumeView: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage("modePeriode") private var modeBrut = Calc.Mode.paie.rawValue
    @AppStorage("masque") private var masque = false
    @State private var vue = "Dépenses"
    @State private var selection: String?
    @State private var angle: Double?
    // Dates de la période personnalisée, gardées pour tous les écrans (Conseiller, Score, notifications)
    @AppStorage("persoDebut") private var persoDebut = J.iso(J.debutDuMois(J.aujourdhui))
    @AppStorage("persoFin") private var persoFin = J.auj
    @State private var choixPerso = false

    /// Calculé une seule fois par état des données (cache du magasin) : toucher l'anneau ne refait plus tous les calculs.
    private var tableau: Tableau { magasin.tableau(mode: Calc.Mode(rawValue: modeBrut) ?? .paie, perso: (persoDebut, persoFin)) }

    var body: some View {
        let t = tableau
        NavigationStack {
            Ecran {
                Menu {
                    ForEach(Calc.Mode.allCases) { m in
                        Button(m.rawValue) { if m == .perso { choixPerso = true } ; modeBrut = m.rawValue }
                    }
                } label: {
                    Label(t.per.libelle, systemImage: "calendar").font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 7).glassEffect(.regular.interactive(), in: .capsule)
                }
                .tint(.primary)
                if magasin.etat == .demo { Text("Mode démo : données inventées").badge(.alerte) }
                if let e = magasin.erreur { Text(e).font(.footnote).foregroundStyle(Color.alerte) }
                Picker("Vue", selection: $vue) { ForEach(["Dépenses", "Budget", "Comptes"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented)
                alertes(t)
                switch vue {
                case "Budget": BudgetVue(t: t)
                case "Comptes": ComptesVue(t: t)
                default: depenses(t)
                }
                if vue != "Budget" { barreBudget(t) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    Kpi(titre: "Revenus", valeur: Fmt.eur(t.b.rev, 0), sous: ecart(t.b.rev, t.bp?.rev), symbole: "arrow.down.left")
                    Kpi(titre: "Mis de côté", valeur: Fmt.eur(t.b.epa, 0), sous: t.b.rev > 0 ? "\(Fmt.pct(t.b.epa / t.b.rev * 100)) des revenus" : "—", symbole: "banknote")
                    Kpi(titre: "Reste", valeur: Fmt.eur(t.b.reste, 0), sous: "revenus − dépenses − épargne", couleur: t.b.reste < 0 ? .negatif : .primary, symbole: "scalemass")
                    Kpi(titre: "Solde du compte", valeur: Fmt.eur(t.soldeAuj, 0), sous: "au \(J.court(J.auj))", couleur: t.soldeAuj < 0 ? .negatif : .primary, symbole: "building.columns")
                }
                Text(phrase(t)).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 6)
                if let r = Conseil.recommandations(t).first {
                    NavigationLink { ConseillerView() } label: {
                        CarteVerre {
                            Label("Conseil", systemImage: "lightbulb").font(.headline)
                            Text(r.texte).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Résumé")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { masque.toggle() } label: { Image(systemName: masque ? "eye.slash" : "eye").frame(width: 44, height: 44).contentShape(.rect) }
                        .accessibilityLabel(masque ? "Afficher les montants" : "Masquer les montants")
                }
            }
            .refreshable { await magasin.rafraichir() }
            .sheet(isPresented: $choixPerso) {
                NavigationStack {
                    Form {
                        DatePicker("Du", selection: Binding(get: { J.date(persoDebut) }, set: { persoDebut = J.iso($0) }), displayedComponents: .date)
                        DatePicker("Au", selection: Binding(get: { J.date(persoFin) }, set: { persoFin = J.iso($0) }), displayedComponents: .date)
                        Text("Le budget est ramené au nombre de jours de la période.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .navigationTitle("Période").toolbar { Button("OK") { choixPerso = false } }
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func ecart(_ x: Double, _ y: Double?) -> String {
        guard let y, abs(y) > 0.5 else { return "période précédente vide" }
        let p = (x - y) / y * 100
        return "\(p >= 0 ? "+" : "−")\(Fmt.pct(abs(p))) vs période préc."
    }

    private func phrase(_ t: Tableau) -> String {
        let reste = t.budget - t.b.dep
        var s = "\(t.per.mode == .mois ? "Ce mois-ci" : t.per.libelle), tu as dépensé \(Fmt.eur(t.b.dep))"
        if reste >= 0 {
            s += ". Il te reste \(Fmt.eur(reste)) de budget, soit \(Fmt.eur(t.prev.parJour)) par jour jusqu'au \(J.court(t.per.finBudget))"
            if t.prev.depAVenir > 0 { s += ", une fois payés \(Fmt.eur(t.prev.depAVenir, 0)) de prélèvements à venir" }
            s += "."
            if t.prev.depFin > t.budget { s += " À ce rythme, tu finirais vers \(Fmt.eur(t.prev.depFin, 0))." }
        } else { s += ", soit \(Fmt.eur(-reste)) de plus que ton budget." }
        return s
    }

    @ViewBuilder private func alertes(_ t: Tableau) -> some View {
        let l = Conseil.alertes(t)
        if !l.isEmpty {
            TitreSection(texte: "À surveiller")
            CarteVerre(espacement: 10) {
                ForEach(l.prefix(4)) { a in
                    HStack(spacing: 12) {
                        Pastille(symbole: a.symbole, teinte: a.grave ? .negatif : .alerte)
                        Text(a.texte).font(.subheadline)
                    }
                }
                if l.count > 4 { Text("et \(l.count - 4) autre(s) point(s)").font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private func barreBudget(_ t: Tableau) -> some View {
        let part = t.budget > 0 ? t.b.dep / t.budget * 100 : 0
        return CarteVerre(espacement: 10) {
            HStack { Text("Budget de la période").fontWeight(.semibold); Spacer(); Text("\(Fmt.pct(part)) utilisé").foregroundStyle(.secondary) }
            Jauge(part: part, couleur: part > 100 ? .negatif : part > 80 ? .alerte : .primary, repere: Double(t.prev.passes) / Double(max(t.prev.total, 1)) * 100)
            HStack { Text("\(Fmt.eur(t.b.dep, 0)) sur \(Fmt.eur(t.budget, 0))"); Spacer(); Text("jour \(t.prev.passes) sur \(t.prev.total)") }
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Anneau par catégorie : toucher une part la met en avant.
    @ViewBuilder private func depenses(_ t: Tableau) -> some View {
        let rep = Calc.repartition(t.opsP)
        let tete = Array(rep.prefix(6)) + (rep.count > 6 ? [("Autres", rep.dropFirst(6).reduce(0) { $0 + $1.v })] : [])
        let total = tete.reduce(0) { $0 + $1.v }
        if tete.isEmpty {
            CarteVerre { Text("Aucune dépense sur cette période.").foregroundStyle(.secondary) }
        } else {
            CarteVerre {
                Chart(tete, id: \.0) { e in
                    SectorMark(angle: .value("Montant", e.1), innerRadius: .ratio(0.68), outerRadius: .ratio(selection == e.0 ? 1 : 0.92), angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(e.0 == "Autres" ? Color.gray : Ref.theme(e.0).teinte)
                        .opacity(selection == nil || selection == e.0 ? 1 : 0.3)
                }
                .chartAngleSelection(value: $angle)
                .onChange(of: angle) { _, v in
                    guard let v else { return }
                    var cumul = 0.0
                    // glisser sur l'anneau désigne une part ; on ne bascule pas (sinon chaque petit mouvement l'allume puis l'éteint)
                    for e in tete { cumul += e.1; if v <= cumul { if selection != e.0 { selection = e.0 }; break } }
                }
                .chartBackground { _ in
                    VStack(spacing: 2) {
                        let sel = tete.first { $0.0 == selection }
                        Text(sel?.0 ?? "Dépensé").font(.footnote).foregroundStyle(.secondary)
                        Text(Fmt.eur(sel?.1 ?? t.b.dep, 0)).font(.title.weight(.bold)).monospacedDigit()
                        if let sel { Text("\(Fmt.pct(sel.1 / total * 100)) des dépenses").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .frame(height: 230)
                .sensoryFeedback(.selection, trigger: selection)
                ForEach(tete, id: \.0) { e in
                    Button { withAnimation(.spring) { selection = selection == e.0 ? nil : e.0 } } label: {
                        HStack(spacing: 12) {
                            if e.0 == "Autres" { Pastille(symbole: "ellipsis") } else { Tuile(sc: e.0) }
                            VStack(alignment: .leading) { Text(e.0); Text(Fmt.pct(e.1 / total * 100)).font(.footnote).foregroundStyle(.secondary) }
                            Spacer()
                            Text(Fmt.eur(e.1)).monospacedDigit().fontWeight(.semibold)
                        }
                        .padding(6)
                        .background(selection == e.0 ? Color.primary.opacity(0.06) : .clear, in: .rect(cornerRadius: 12))
                        .contentShape(.rect(cornerRadius: 12))   // toute la ligne réagit, pas seulement le texte
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Vue Budget : enveloppes, prélèvements à venir, épargne du mois, règle 50-30-20.
struct BudgetVue: View {
    @Environment(Magasin.self) private var magasin
    let t: Tableau
    @State private var gererEnveloppes = false

    var body: some View {
        let part = t.budget > 0 ? t.b.dep / t.budget * 100 : 0, reste = t.budget - t.b.dep
        CarteVerre(espacement: 8) {
            Text("Budget de la période").font(.headline)
            Text("Le repère montre où tu devrais en être aujourd'hui").font(.footnote).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.eur(t.b.dep, 0)).font(.largeTitle.weight(.bold)).monospacedDigit()
                Text("sur \(Fmt.eur(t.budget, 0))").foregroundStyle(.secondary)
            }
            Jauge(part: part, couleur: part > 100 ? .negatif : part > 80 ? .alerte : .primary, repere: Double(t.prev.passes) / Double(max(t.prev.total, 1)) * 100, hauteur: 10)
            Text(reste >= 0
                 ? "Il te reste \(Fmt.eur(reste)), soit \(Fmt.eur(t.prev.parJour)) par jour pendant \(t.prev.restants) jours. Au rythme actuel (\(Fmt.eur(t.prev.rythme)) par jour hors charges fixes), plus \(Fmt.eur(t.prev.depAVenir, 0)) de prélèvements attendus, tu finirais vers \(Fmt.eur(t.prev.depFin, 0))."
                 : "Budget dépassé de \(Fmt.eur(-reste)).")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        TitreSection(texte: "Enveloppes", action: ("Gérer", { gererEnveloppes = true }))
        CarteVerre(espacement: 12) {
            if t.enveloppes.isEmpty { Button("Créer une enveloppe") { gererEnveloppes = true }.tint(.primary) }
            ForEach(t.enveloppes) { e in
                HStack(spacing: 12) {
                    Tuile(sc: e.e.sc)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(e.e.sc); Spacer(); Text(e.reste >= 0 ? "\(Fmt.eur(e.reste, 0)) restants" : "\(Fmt.eur(-e.reste, 0)) de trop").fontWeight(.semibold).foregroundStyle(Color.etat(e.etat)) }
                        Jauge(part: e.part, couleur: e.etat == .ok ? Ref.theme(e.e.sc).teinte : Color.etat(e.etat), hauteur: 6)
                        Text("\(Fmt.eur(e.depense, 0)) sur \(Fmt.eur(e.dispo, 0))" + (e.e.report ? " · dont \(Fmt.eur(e.report, 0, signe: true)) reporté" : "")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        TitreSection(texte: "À venir d'ici le \(J.court(t.per.finBudget))")
        CarteVerre(espacement: 10) {
            let l = t.prev.aVenir.filter { $0.r.cat != .revenu }
            if l.isEmpty { Text("Aucun prélèvement attendu d'ici la fin de la période.").foregroundStyle(.secondary) }
            ForEach(l.prefix(6)) { e in
                HStack(spacing: 12) {
                    Tuile(sc: e.r.sc)
                    VStack(alignment: .leading) { Text(e.r.nom); Text(e.enRetard ? "attendu, pas encore vu" : J.libelleJour(e.date)).font(.footnote).foregroundStyle(e.enRetard ? Color.alerte : .secondary) }
                    Spacer()
                    Text(Fmt.eur(-e.r.montant, signe: true)).monospacedDigit()
                }
            }
            NavigationLink("Tous les prélèvements et le calendrier") { PrelevementsView(recs: t.recs) }.font(.subheadline.weight(.semibold)).tint(.primary)
        }
        CarteVerre(espacement: 8) {
            Text("Épargne de la période").font(.headline)
            Text("\(Fmt.eur(t.b.epa, 0)) sur \(Fmt.eur(t.objectifEpargne, 0))").font(.title2.weight(.bold)).monospacedDigit()
            Jauge(part: t.objectifEpargne > 0 ? t.b.epa / t.objectifEpargne * 100 : 0, couleur: .positif)
        }
        let rg = Calc.regle(t.b)
        CarteVerre(espacement: 10) {
            Text("Règle 50-30-20").font(.headline)
            Text("Calculée sur salaire, aides et aide familiale : \(Fmt.eur(rg.base, 0))").font(.footnote).foregroundStyle(.secondary)
            ForEach([(Cat.besoins, "Besoins", Color(red: 0.5, green: 0.61, blue: 0.76)), (.envies, "Envies", Color(red: 0.76, green: 0.6, blue: 0.43)), (.epargne, "Épargne", Color.positif)], id: \.1) { c, nom, couleur in
                let p = rg.parts[c] ?? 0, cible = Ref.cibles[c] ?? 0
                VStack(spacing: 4) {
                    HStack { Text(nom); Text("· cible \(Int(cible)) %").foregroundStyle(.secondary); Spacer(); Text(Fmt.pct(p)) }.font(.subheadline)
                    Jauge(part: p, couleur: couleur, repere: cible, hauteur: 6)
                }
            }
            Text(rg.alertes.isEmpty ? "L'équilibre est respecté sur cette période." : "À surveiller : \(rg.alertes.joined(separator: ", ")).")
                .font(.footnote).foregroundStyle(rg.alertes.isEmpty ? Color.secondary : Color.alerte)
        }
        .sheet(isPresented: $gererEnveloppes) { EnveloppesView() }
    }
}

/// Vue Comptes : soldes, groupes, objectifs, épargne et patrimoine.
struct ComptesVue: View {
    @Environment(Magasin.self) private var magasin
    let t: Tableau
    @State private var objectifOuvert: Objectif?
    @State private var nouvelObjectif = false

    var body: some View {
        let groupes = magasin.groupes.compactMap { g -> (GroupeComplet, Double)? in
            guard let moi = Tricount.moi(g, profil: magasin.profil?.id) else { return nil }
            let s = Tricount.soldes(g)[moi] ?? 0
            return abs(s) > 0.004 ? (g, s) : nil
        }
        CarteVerre(espacement: 10) {
            ForEach(magasin.comptes, id: \.self) { k in
                HStack(spacing: 12) {
                    Pastille(symbole: k.isEmpty ? "building.columns" : "creditcard")
                    Text(magasin.nomCompte(k))
                    Spacer()
                    Text(Fmt.eur(magasin.solde(k))).monospacedDigit().fontWeight(.semibold)
                }
            }
            ForEach(groupes, id: \.0.id) { g, s in
                HStack(spacing: 12) {
                    Pastille(symbole: "person.2", teinte: .purple)
                    VStack(alignment: .leading) { Text(g.groupe.nom); Text(s > 0 ? "À recevoir" : "À rembourser").font(.footnote).foregroundStyle(.secondary) }
                    Spacer()
                    Text(Fmt.eur(s, signe: true)).monospacedDigit().foregroundStyle(s > 0 ? Color.positif : Color.negatif)
                }
            }
        }
        CarteVerre {
            Text("Mon argent jour après jour").font(.headline)
            let jours = max(J.ecart(t.per.debut, J.auj), 1)
            let points = stride(from: 0, through: jours, by: max(jours / 40, 1)).map { i -> (Date, Double) in
                let d = J.plus(t.per.debut, jours: i)
                return (J.date(d), Calc.solde(t.ops, "", jusqua: d, initial: magasin.soldesInitiaux[""] ?? 0))
            }
            Chart(points, id: \.0) { p in
                AreaMark(x: .value("Jour", p.0), y: .value("Solde", p.1)).foregroundStyle(.linearGradient(colors: [.primary.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Jour", p.0), y: .value("Solde", p.1)).foregroundStyle(.primary)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 140)
        }
        NavigationLink { PatrimoineView() } label: {
            CarteVerre { HStack { Pastille(symbole: "building.columns", teinte: .purple); Text("Patrimoine et placements"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) } }
                .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        TitreSection(texte: "Objectifs d'épargne", action: ("Nouveau", { nouvelObjectif = true }))
        CarteVerre(espacement: 12) {
            if t.objectifs.isEmpty { Text("Crée un objectif : livret, voyage, projet…").foregroundStyle(.secondary) }
            ForEach(t.objectifs) { o in
                Button { objectifOuvert = o.o } label: {
                    HStack(spacing: 12) {
                        Tuile(sc: o.o.support)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(o.o.nom); Spacer(); Text("\(Fmt.eur(o.actuel, 0)) / \(Fmt.eur(o.o.cible, 0))").monospacedDigit() }
                            Jauge(part: o.part, couleur: o.enRetard ? .alerte : Ref.theme(o.o.support).teinte, hauteur: 6)
                            Text(o.reste <= 0 ? "Objectif atteint" : o.parMois.map { "\(Fmt.eur($0, 0)) par mois pour tenir la date" + (o.enRetard ? " · en retard" : "") }
                                 ?? (o.estimation.map { "atteint dans environ \($0) mois à ton rythme" } ?? "aucun versement ces 3 derniers mois"))
                                .font(.caption).foregroundStyle(o.enRetard ? Color.alerte : .secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: $objectifOuvert) { ObjectifView(objectif: $0) }
        .sheet(isPresented: $nouvelObjectif) { ObjectifView(objectif: nil) }
    }
}
