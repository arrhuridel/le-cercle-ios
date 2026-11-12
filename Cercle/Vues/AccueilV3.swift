import SwiftUI

// MARK: - Briques du design v3 (surfaces sombres, verre pour les commandes, sans défilement)

/// Carte qui prend toute la place qu'on lui donne (le contenu est centré verticalement).
struct CarteV3<Contenu: View>: View {
    var espacement: CGFloat = 8
    @ViewBuilder let contenu: Contenu
    var body: some View {
        VStack(alignment: .leading, spacing: espacement) { contenu }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .surface(in: .rect(cornerRadius: 24))
            .contentShape(.rect(cornerRadius: 24))
    }
}

/// Anneau de progression (part de 0 à 1 et plus). Il ne s'anime que lorsque la valeur change :
/// revenir sur l'écran ne rejoue rien.
struct Anneau: View {
    let part: Double
    let couleur: Color
    var epaisseur: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduire
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: epaisseur)
            Circle().trim(from: 0, to: min(max(part, 0), 1))
                .stroke(couleur, style: StrokeStyle(lineWidth: epaisseur, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(reduire ? nil : .smooth(duration: 0.3), value: part)
        .accessibilityHidden(true)
    }
}

/// Petit chevron « ouvrir le détail » (une vraie icône, pas un caractère dans le texte).
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
    }
}

extension Color {
    // Couleurs des familles (identité unique de l'app)
    static var besoins: Color { ThemeCouleurs.actuel.besoins }
    static var envies: Color { ThemeCouleurs.actuel.envies }
    static var epargneV3: Color { ThemeCouleurs.actuel.epargne }
}

/// Les chiffres du Résumé v3, calculés une fois à partir du tableau.
struct ResumeV3 {
    let t: Tableau
    /// Sans budget saisi dans le profil, on prend ce que la règle laisse aux besoins et aux envies (80 % des revenus de référence).
    var budget: Double { t.budget > 0 ? t.budget : t.b.ref * 0.8 }
    var reste: Double { budget - t.b.dep }
    var parJour: Double { reste / Double(max(t.prev.restants, 1)) }
    var part: Double { budget > 0 ? t.b.dep / budget * 100 : 0 }
    var repere: Double { Double(t.prev.passes) / Double(max(t.prev.total, 1)) * 100 }

    struct Famille: Identifiable, Hashable {
        let id: String, nom: String, cible: Double, dep: Double, total: Double
        let cats: [Ligne]
        var couleur: Color { id == "bes" ? .besoins : id == "env" ? .envies : .epargneV3 }
        struct Ligne: Hashable { let nom: String; let montant: Double }
    }
    var familles: [Famille] {
        let comp = t.opsP.map(Calc.compense), ref = t.b.ref
        return [(Cat.besoins, "bes", "Besoins", 50.0, t.b.bes), (.envies, "env", "Envies", 30, t.b.env), (.epargne, "epa", "Épargne", 20, t.b.epa)].map { cat, k, nom, cible, dep in
            let parSc = Dictionary(grouping: comp.filter { $0.cat == cat }, by: \.sc).mapValues { $0.reduce(0) { $0 + $1.montant } }
            let cats = parSc.filter { abs($0.value) >= 0.5 }.sorted { $0.value > $1.value }.prefix(6).map { Famille.Ligne(nom: $0.key, montant: $0.value) }
            // Les trois parts se calculent sur la même base : salaire, CAF et aide familiale (règle 7).
            // Avant, l'épargne prenait 20 % de TOUS les revenus (remboursements, cadeaux…), d'où un objectif trop haut.
            let total = ref * cible / 100
            return Famille(id: k, nom: nom, cible: cible, dep: dep, total: total, cats: Array(cats))
        }
    }
}

// MARK: - Résumé (onglet 1)

struct AccueilView: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage("modePeriode") private var modeBrut = Calc.Mode.paie.rawValue
    @AppStorage("masque") private var masque = false
    @State private var page: Page?
    @Namespace private var zoom
    enum Page: Hashable { case regle, abos, reste, reglages }

    var body: some View {
        let t = magasin.tableau(), r = ResumeV3(t: t)
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Menu {
                            ForEach(Calc.Mode.allCases) { m in Button(m.rawValue) { modeBrut = m.rawValue } }
                        } label: {
                            HStack(spacing: 4) { Text(t.per.libelle); Image(systemName: "chevron.down").font(.caption) }
                                .frame(minHeight: 30).contentShape(.rect)
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                        Text("Résumé").font(.largeTitle.bold())
                    }
                    Spacer()
                    // Les deux commandes de l'écran, dans un même groupe de verre
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button { masque.toggle() } label: { Image(systemName: masque ? "eye.slash" : "eye").frame(width: 44, height: 44).contentShape(.circle) }
                                .accessibilityLabel(masque ? "Afficher les montants" : "Masquer les montants")
                                .buttonStyle(.plain).verre(.regular.interactive(), in: .circle)
                            Button { page = .reglages } label: { Image(systemName: "gearshape").frame(width: 44, height: 44).contentShape(.circle) }
                                .accessibilityLabel("Réglages")
                                .buttonStyle(.plain).verre(.regular.interactive(), in: .circle)
                                .matchedTransitionSource(id: Page.reglages, in: zoom)
                        }
                    }
                }
                BandeauEtat()
                if magasin.etat == .demo { Text("Mode démo : données inventées").badge(.alerte) }
                carteReste(r).matchedTransitionSource(id: Page.reste, in: zoom)
                carteRegle(r).matchedTransitionSource(id: Page.regle, in: zoom)
                carteAbonnements.matchedTransitionSource(id: Page.abos, in: zoom)
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
            .background(FondView())
            .toolbar(.hidden, for: .navigationBar)
            .sensoryFeedback(.selection, trigger: masque)
            .navigationDestination(item: $page) { p in
                Group {
                    switch p {
                    case .regle: RegleBullesView()
                    case .abos: AbonnementsView()
                    case .reste: ResteDetailView()
                    case .reglages: MonEspaceView()
                    }
                }
                // La carte touchée s'agrandit jusqu'à devenir la page de détail
                .navigationTransition(.zoom(sourceID: p, in: zoom))
            }
        }
    }

    /// « Il te reste » : le solde réel, puis ce qui est vraiment dépensable une fois les prélèvements passés.
    private func carteReste(_ r: ResumeV3) -> some View {
        let rr = magasin.resteReel
        return Button { page = .reste } label: {
            CarteV3(espacement: 10) {
                HStack { Text("Il te reste jusqu'au \(J.court(rr.fin))"); Spacer(); Chevron() }
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ChiffreAnime(valeur: rr.solde, taille: 48, decimales: 2)
                        .foregroundStyle(rr.solde < 0 ? Color.negatif : .primary)
                    Text("sur ton compte").foregroundStyle(.secondary)
                }
                Jauge(part: rr.part, couleur: .primary, repere: r.repere, hauteur: 10)
                HStack {
                    Text("Après tes prélèvements à venir").foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.eur(rr.solde - rr.totalAVenir, 0)).monospacedDigit().fontWeight(.semibold)
                }
                .font(.footnote)
                HStack {
                    Text(rr.parJour > 0 ? "max \(Fmt.eur(rr.parJour, 0)) par jour · \(rr.restants) jours" : "0 € par jour · \(rr.restants) jours")
                        .foregroundStyle(.secondary)
                    Spacer()
                    // La prévision ne s'affiche ici que si elle annonce un découvert ; sinon elle est dans le détail
                    if rr.finMois < 0 { Text("≈ \(Fmt.eur(rr.finMois, 0)) le \(J.court(rr.fin))").foregroundStyle(Color.alerte).fontWeight(.semibold) }
                }
                .font(.footnote)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Ouvre le détail de ton solde")
    }

    private func carteRegle(_ r: ResumeV3) -> some View {
        Button { page = .regle } label: {
            CarteV3 {
                HStack { Text("Règle 50-30-20").font(.headline); Spacer(); Chevron() }
                HStack {
                    ForEach(r.familles) { f in
                        VStack(spacing: 6) {
                            ZStack {
                                Anneau(part: f.total > 0 ? f.dep / f.total : 0, couleur: f.couleur)
                                Text(Fmt.pct(f.total > 0 ? f.dep / f.total * 100 : 0)).font(.subheadline.bold()).monospacedDigit()
                            }
                            .frame(width: 72, height: 72)
                            Text(f.nom).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Ouvre le détail de la règle")
    }

    /// Les trois prochains abonnements à tomber.
    private var carteAbonnements: some View {
        let l = magasin.prelevements.filter(\.estAbonnement), total = l.reduce(0) { $0 + $1.montant }
        let j = J.comp(J.aujourdhui).j
        let prochains = l.sorted { ($0.jour - j + 31) % 31 < ($1.jour - j + 31) % 31 }.prefix(3)
        return Button { page = .abos } label: {
            CarteV3(espacement: 4) {
                HStack {
                    Text("Abonnements").font(.headline)
                    Spacer()
                    Text("\(Fmt.eur(total)) par mois").font(.footnote).foregroundStyle(.secondary)
                    Chevron()
                }
                if prochains.isEmpty { Text("Aucun abonnement détecté").foregroundStyle(.secondary) }
                ForEach(Array(prochains)) { p in
                    let dans = (p.jour - j + 31) % 31
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.nom).lineLimit(1)
                            Text("\(dans == 0 ? "aujourd'hui" : dans == 1 ? "demain" : "dans \(dans) jours") · le \(p.jour)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.eur(-p.montant, signe: true)).monospacedDigit().fontWeight(.semibold)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Ouvre le calendrier des abonnements")
    }
}

// MARK: - 50-30-20 : trois lignes claires (dépensé, total, marge)

struct RegleBullesView: View {
    @Environment(Magasin.self) private var magasin
    @State private var choisie: ResumeV3.Famille?

    var body: some View {
        let t = magasin.tableau(), r = ResumeV3(t: t)
        VStack(alignment: .leading, spacing: 12) {
            Text("Ce que tu as déjà dépensé, sur ce que la règle te laisse ce mois-ci.").font(.subheadline).foregroundStyle(.secondary)
            ForEach(r.familles) { f in ligne(f) }
            Text("Calculé sur \(Fmt.eur(t.b.ref, 0)) : ton salaire et ta CAF du mois").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .background(FondView())
        .navigationTitle("50-30-20")
        .sensoryFeedback(.selection, trigger: choisie)
        .sheet(item: $choisie) { fa in
            NavigationStack {
                List {
                    Section { Text("\(Fmt.eur(fa.dep, 0)) sur \(Fmt.eur(fa.total, 0)) (\(Int(fa.cible)) % de \(Fmt.eur(t.b.ref, 0)))").foregroundStyle(.secondary) }
                    ForEach(fa.cats, id: \.nom) { c in HStack { Text(c.nom); Spacer(); Text(Fmt.eur(c.montant, 0)).monospacedDigit().foregroundStyle(.secondary) } }
                }
                .navigationTitle(fa.nom)
            }
            .presentationDetents([.medium])
        }
    }

    /// Une famille : son nom, ce qui est dépensé sur ce qui est permis, la jauge et l'écart en clair.
    private func ligne(_ f: ResumeV3.Famille) -> some View {
        let ecart = f.dep - f.total
        let etat: (String, Color) = f.id == "epa" ? (ecart >= 0 ? ("Objectif atteint", .positif) : ("\(Fmt.eur(-ecart, 0)) à mettre", .alerte))
            : (ecart > 0 ? ("\(Fmt.eur(ecart, 0)) de trop", .alerte) : ("\(Fmt.eur(-ecart, 0)) de marge", .positif))
        return Button { choisie = f } label: {
            CarteV3(espacement: 10) {
                HStack(spacing: 8) {
                    Circle().fill(f.couleur).frame(width: 10, height: 10)
                    Text("\(f.nom) · \(Int(f.cible)) %").font(.headline)
                    Spacer()
                    Chevron()
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.eur(f.dep, 0)).grandChiffre(34)
                    Text("sur \(Fmt.eur(f.total, 0))").foregroundStyle(.secondary)
                    Spacer()
                    Text(etat.0).font(.footnote.weight(.semibold)).foregroundStyle(etat.1)
                }
                Jauge(part: f.total > 0 ? f.dep / f.total * 100 : 0, couleur: f.couleur, hauteur: 10)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(f.nom) : \(Fmt.eur(f.dep, 0)) sur \(Fmt.eur(f.total, 0)), \(etat.0)")
        .accessibilityHint("Affiche le détail par catégorie")
    }
}

/// Grand chiffre : il s'affiche tout de suite à sa vraie valeur (jamais « 0 € » à l'ouverture d'un écran)
/// et glisse en 300 ms seulement quand la valeur change (rien si « Réduire les animations »).
struct ChiffreAnime: View {
    let valeur: Double
    var taille: CGFloat = 54
    var decimales = 0
    @Environment(\.accessibilityReduceMotion) private var reduire
    var body: some View {
        Text(Fmt.eur(valeur, decimales)).grandChiffre(taille)
            .contentTransition(.numericText(value: valeur))
            .animation(reduire ? nil : .smooth(duration: 0.3), value: valeur)
            .accessibilityLabel(Fmt.eur(valeur, decimales))
    }
}

// MARK: - Abonnements : calendrier du mois

struct AbonnementsView: View {
    @Environment(Magasin.self) private var magasin
    @State private var tout = false
    @State private var jour: JourChoisi?
    struct JourChoisi: Identifiable { let id: Int }

    var body: some View {
        let toutes = magasin.prelevements, l = toutes.filter { tout || $0.estAbonnement }
        let total = l.reduce(0) { $0 + $1.montant }
        let auj = J.aujourdhui, c = J.comp(auj), debut = J.debutDuMois(auj)
        let nbJours = J.comp(J.finDuMois(auj)).j, decalage = J.jourSemaine(J.iso(debut))
        let cases: [Int?] = [Int?](repeating: nil, count: decalage) + (1...nbJours).map { Optional($0) }
        let semaines: [[Int?]] = stride(from: 0, to: cases.count, by: 7).map { (i: Int) -> [Int?] in
            Array(cases[i..<min(i + 7, cases.count)]) + [Int?](repeating: nil, count: max(0, i + 7 - cases.count))
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                Text(tout ? "\(l.count) prélèvements chaque mois" : "\(l.count) abonnement\(l.count > 1 ? "s" : "") chaque mois").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(Fmt.eur(total)).font(.title.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text("\(Fmt.eur(total * 12, 0)) par an").font(.footnote).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 6) {
                HStack {
                    Text("\(J.mois[c.m - 1].capitalizedPremiere) \(c.a)").fontWeight(.semibold)
                    Spacer()
                    Picker("", selection: $tout) { Text("Abonnements").tag(false); Text("Tout").tag(true) }.pickerStyle(.segmented).frame(width: 190)
                }
                HStack { ForEach(["L", "M", "M", "J", "V", "S", "D"].indices, id: \.self) { i in Text(["L", "M", "M", "J", "V", "S", "D"][i]).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
                ForEach(semaines.indices, id: \.self) { s in
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { i in
                            if let j = semaines[s][i] { caseJour(j, l.filter { $0.jour == j }, auj: c.j) } else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity)
            .surface(in: .rect(cornerRadius: 24))
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .background(FondView())
        .navigationTitle("Abonnements")
        .sensoryFeedback(.selection, trigger: tout)
        .sheet(item: $jour) { jc in
            let d = l.filter { $0.jour == jc.id }
            NavigationStack {
                List {
                    Section { Text(Fmt.eur(-d.reduce(0) { $0 + $1.montant }, signe: true)).font(.largeTitle.bold()).monospacedDigit() }
                    ForEach(d) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(p.nom).fontWeight(.semibold); Spacer(); Text(Fmt.eur(-p.montant, signe: true)).monospacedDigit() }
                            Text("\(p.sc) · \(magasin.nomCompte(p.compte)) · \(Fmt.eur(p.montant * 12, 0)) par an").font(.caption).foregroundStyle(.secondary)
                            Text(p.infos).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("\(jc.id) \(J.mois[c.m - 1])")
            }
            .presentationDetents([.medium])
        }
    }

    private func caseJour(_ j: Int, _ l: [Prelevements.Prelevement], auj: Int) -> some View {
        let somme = l.reduce(0) { $0 + $1.montant }
        return Button { if !l.isEmpty { jour = JourChoisi(id: j) } } label: {
            VStack(spacing: 5) {
                Text("\(j)").font(.callout.weight(j == auj ? .bold : .regular)).foregroundStyle(j < auj ? .secondary : .primary)
                    .overlay { if j == auj { Circle().stroke(.primary, lineWidth: 1.5).frame(width: 28, height: 28) } }
                if !l.isEmpty {
                    Text(Fmt.nombre(somme)).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background((l.allSatisfy { !$0.estAbonnement } ? Color.besoins : .white).opacity(0.18), in: .rect(cornerRadius: 6))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(l.isEmpty)
    }
}
