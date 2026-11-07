import SwiftUI

// MARK: - Briques du design v3 (verre liquide, sans défilement)

/// Carte en verre qui prend toute la place qu'on lui donne (le contenu est centré verticalement).
struct CarteV3<Contenu: View>: View {
    var espacement: CGFloat = 8
    @ViewBuilder let contenu: Contenu
    var body: some View {
        VStack(alignment: .leading, spacing: espacement) { contenu }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
            .contentShape(.rect(cornerRadius: 26))
    }
}

/// Anneau de progression (part de 0 à 1 et plus).
struct Anneau: View {
    let part: Double
    let couleur: Color
    var epaisseur: CGFloat = 6
    @State private var vu = false
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: epaisseur)
            Circle().trim(from: 0, to: vu ? min(max(part, 0), 1) : 0)
                .stroke(couleur, style: StrokeStyle(lineWidth: epaisseur, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { withAnimation(.spring(response: 1.1, dampingFraction: 0.85)) { vu = true } }
    }
}

extension Color {
    static let besoins = Color(red: 0.56, green: 0.65, blue: 0.78)
    static let envies = Color(red: 0.82, green: 0.66, blue: 0.47)
    static let epargneV3 = Color(red: 0.44, green: 0.81, blue: 0.62)
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
            return Famille(id: k, nom: nom, cible: cible, dep: dep, total: ref * cible / 100, cats: Array(cats))
        }
    }
}

// MARK: - Résumé (onglet 1)

struct AccueilView: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage("modePeriode") private var modeBrut = Calc.Mode.paie.rawValue
    @AppStorage("masque") private var masque = false
    @AppStorage("ordreAccueil") private var ordreBrut = "reste,regle,abos"
    @State private var page: Page?
    enum Page: Hashable { case regle, abos }

    private var ordre: [String] {
        let l = ordreBrut.split(separator: ",").map(String.init).filter { ["reste", "regle", "abos"].contains($0) }
        return l.count == 3 ? l : ["reste", "regle", "abos"]
    }
    private var salutation: String { let h = Calendar.current.component(.hour, from: Date()); return h >= 18 || h < 5 ? "Bonsoir" : "Bonjour" }

    var body: some View {
        let t = magasin.tableau(), r = ResumeV3(t: t)
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Menu {
                            ForEach(Calc.Mode.allCases) { m in Button(m.rawValue) { modeBrut = m.rawValue } }
                        } label: { HStack(spacing: 4) { Text(t.per.libelle); Image(systemName: "chevron.down").font(.caption2) } }
                        .font(.subheadline).foregroundStyle(.secondary)
                        Text(salutation).font(.largeTitle.bold())
                    }
                    Spacer()
                    Button { masque.toggle() } label: { Image(systemName: masque ? "eye.slash" : "eye").frame(width: 40, height: 40) }
                        .buttonStyle(.plain).glassEffect(.regular.interactive(), in: .circle)
                }
                if magasin.etat == .demo { Text("Mode démo : données inventées").badge(.alerte) }
                ForEach(ordre, id: \.self) { k in
                    carte(k, t, r)
                        .draggable(k)   // appui prolongé, puis glisser pour changer l'ordre
                        .dropDestination(for: String.self) { items, _ in deplacer(items.first, vers: k) }
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
            .background(FondView())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $page) { p in
                if p == .regle { RegleView() } else { AbonnementsView() }
            }
            .refreshable { await magasin.rafraichir() }
        }
    }

    private func deplacer(_ id: String?, vers cible: String) -> Bool {
        guard let id, id != cible, var l = Optional(ordre), let i = l.firstIndex(of: id), let j = l.firstIndex(of: cible) else { return false }
        l.remove(at: i); l.insert(id, at: j)
        withAnimation(.spring) { ordreBrut = l.joined(separator: ",") }
        return true
    }

    @ViewBuilder private func carte(_ k: String, _ t: Tableau, _ r: ResumeV3) -> some View {
        switch k {
        case "reste":
            CarteV3(espacement: 10) {
                Text("Il te reste jusqu'au \(J.court(t.per.finBudget))").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.eur(r.reste, 0)).font(.system(size: 54, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(r.reste < 0 ? Color.negatif : .primary).lineLimit(1).minimumScaleFactor(0.6)
                    Text("sur \(Fmt.eur(r.budget, 0))").foregroundStyle(.secondary)
                }
                Jauge(part: r.part, couleur: r.part > 100 ? .negatif : .primary, repere: r.repere, hauteur: 10)
                HStack {
                    Text(r.reste >= 0 ? "\(Fmt.eur(r.parJour, 0)) par jour · \(t.prev.restants) jours" : "Budget dépassé · \(t.prev.restants) jours")
                    Spacer()
                    Text("Prévu : \(Fmt.eur(t.prev.depFin, 0))").foregroundStyle(t.prev.depFin > r.budget ? Color.alerte : .secondary)
                }
                .font(.footnote.weight(.medium))
            }
        case "regle":
            Button { page = .regle } label: {
                CarteV3 {
                    HStack { Text("Règle 50-30-20").font(.headline); Spacer(); Text("Voir le détail ›").font(.footnote).foregroundStyle(.secondary) }
                    HStack {
                        ForEach(r.familles) { f in
                            VStack(spacing: 6) {
                                ZStack {
                                    Anneau(part: f.total > 0 ? f.dep / f.total : 0, couleur: f.couleur)
                                    Text(Fmt.pct(t.b.ref > 0 ? f.dep / t.b.ref * 100 : 0)).font(.subheadline.bold()).monospacedDigit()
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
        default:
            let l = Prelevements.liste(t.ops).filter(\.estAbonnement), total = l.reduce(0) { $0 + $1.montant }
            let j = J.comp(J.aujourdhui).j
            let prochains = l.sorted { ($0.jour - j + 31) % 31 < ($1.jour - j + 31) % 31 }.prefix(3)
            Button { page = .abos } label: {
                CarteV3(espacement: 4) {
                    HStack { Text("Abonnements").font(.headline); Spacer(); Text("\(Fmt.eur(total)) / mois ›").font(.footnote).foregroundStyle(.secondary) }
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
        }
    }
}

// MARK: - 50-30-20 : trois bulles

struct RegleView: View {
    @Environment(Magasin.self) private var magasin
    @State private var choisie: ResumeV3.Famille?

    var body: some View {
        let t = magasin.tableau(), r = ResumeV3(t: t), f = r.familles
        VStack(alignment: .leading, spacing: 8) {
            Text("Ce que tu as déjà dépensé, sur ce que la règle te laisse ce mois-ci.").font(.subheadline).foregroundStyle(.secondary)
            GeometryReader { g in
                let p = positions(g.size)
                ZStack {
                    ForEach(Array(f.enumerated()), id: \.element.id) { i, fa in
                        if i < p.count {
                            bulle(fa).frame(width: p[i].taille, height: p[i].taille).position(p[i].centre)
                        }
                    }
                }
            }
            Text("Calculé sur \(Fmt.eur(t.b.ref, 0)) de revenus · touche une bulle pour le détail").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .background(FondView())
        .navigationTitle("50-30-20")
        .sheet(item: $choisie) { fa in
            NavigationStack {
                List {
                    Section { Text("\(Fmt.eur(fa.dep, 0)) dépensés sur \(Fmt.eur(fa.total, 0)) (\(Int(fa.cible)) % de \(Fmt.eur(t.b.ref, 0)))").foregroundStyle(.secondary) }
                    ForEach(fa.cats, id: \.nom) { c in HStack { Text(c.nom); Spacer(); Text(Fmt.eur(c.montant, 0)).monospacedDigit().foregroundStyle(.secondary) } }
                }
                .navigationTitle(fa.nom)
            }
            .presentationDetents([.medium])
        }
    }

    /// Trois bulles aussi grandes que possible, sans se toucher.
    private func positions(_ s: CGSize) -> [(centre: CGPoint, taille: CGFloat)] {
        let W = s.width, H = s.height
        var k: CGFloat = 1
        while k > 0.4 {
            let s1 = min(W * 0.66, H * 0.52) * k, s2 = s1 * 0.86, s3 = s1 * 0.8, r1 = s1 / 2, r2 = s2 / 2, r3 = s3 / 2
            let c1 = CGPoint(x: r1, y: r1), dx = (W - r2) - c1.x
            let c2 = CGPoint(x: W - r2, y: max(H * 0.48, c1.y + sqrt(max(0, pow(r1 + r2 + 10, 2) - dx * dx))))
            let c3 = CGPoint(x: max(r3, W * 0.36 - r3 * 0.2), y: H - r3)
            let d = { (a: CGPoint, b: CGPoint) in hypot(a.x - b.x, a.y - b.y) }
            if c2.y + r2 <= H && d(c1, c3) >= r1 + r3 + 10 && d(c2, c3) >= r2 + r3 + 10 && c3.x + r3 <= W {
                return [(c1, s1), (c2, s2), (c3, s3)]
            }
            k -= 0.02
        }
        return []
    }

    private func bulle(_ f: ResumeV3.Famille) -> some View {
        let ecart = f.dep - f.total
        let etat: (String, Color) = f.id == "epa" ? (ecart >= 0 ? ("Objectif atteint", .positif) : ("\(Fmt.eur(-ecart, 0)) à mettre", .alerte))
            : (ecart > 0 ? ("\(Fmt.eur(ecart, 0)) de trop", .alerte) : ("\(Fmt.eur(-ecart, 0)) de marge", .positif))
        return Button { choisie = f } label: {
            GeometryReader { g in
                let t = g.size.width
                ZStack {
                    Color.clear.glassEffect(.regular.interactive(), in: .circle)
                    Anneau(part: f.total > 0 ? f.dep / f.total : 0, couleur: f.couleur, epaisseur: 4)
                    VStack(spacing: 3) {
                        HStack(spacing: 5) { Circle().fill(f.couleur).frame(width: 8, height: 8); Text("\(f.nom) · \(Int(f.cible)) %") }
                            .font(.system(size: max(12, t * 0.062))).foregroundStyle(.secondary)
                        Text(Fmt.eur(f.dep, 0)).font(.system(size: t * 0.16, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("sur \(Fmt.eur(f.total, 0))").font(.footnote).foregroundStyle(.secondary)
                        Text(etat.0).font(.caption.weight(.semibold)).foregroundStyle(etat.1)
                            .padding(.horizontal, 10).padding(.vertical, 3).background(.white.opacity(0.08), in: Capsule())
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
    }
}

// MARK: - Abonnements : calendrier du mois

struct AbonnementsView: View {
    @Environment(Magasin.self) private var magasin
    @State private var tout = false
    @State private var jour: JourChoisi?
    struct JourChoisi: Identifiable { let id: Int }

    var body: some View {
        let toutes = Prelevements.liste(magasin.toutes), l = toutes.filter { tout || $0.estAbonnement }
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
                HStack { ForEach(["L", "M", "M", "J", "V", "S", "D"].indices, id: \.self) { i in Text(["L", "M", "M", "J", "V", "S", "D"][i]).font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity) } }
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
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
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
                    Text(Fmt.nombre(somme)).font(.system(size: 10, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
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
