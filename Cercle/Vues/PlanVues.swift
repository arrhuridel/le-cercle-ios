import SwiftUI

// Écrans du plan de virements (validés par Arthur le 15/11/2026 sur l'aperçu imports/apercu_ios) :
//  - Résumé : combien il reste sur chaque compte (l'argent réel), tout l'écran, sans défilement ;
//  - Comptes : ce que j'ai le droit de dépenser jusqu'à la paie, puis ce qu'il reste à mettre de côté ;
//  - page d'un compte : le détail, et chaque dépense depuis la paie.
// Design sobre : surfaces sombres à peine teintées de la couleur de la banque, logo sur fond blanc, jauge fine.

extension Plan.Poche {
    var couleur: Color { Color(red: teinte.0, green: teinte.1, blue: teinte.2) }
}

/// Logo d'une banque : symbole découpé dans le logo officiel, sur fond blanc.
struct LogoBanque: View {
    let image: String
    var taille: CGFloat = 34
    var body: some View {
        Image(image).resizable().interpolation(.high).scaledToFit()
            .frame(width: taille, height: taille)
            .background(Color.white)
            .clipShape(.rect(cornerRadius: taille * 0.29))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Surface sombre de l'app, avec un léger reflet de la couleur de la banque en haut à gauche.
    func carteTeintee(_ couleur: Color, rayon: CGFloat = 20) -> some View {
        self.surface(in: .rect(cornerRadius: rayon))
            .overlay {
                RoundedRectangle(cornerRadius: rayon)
                    .fill(LinearGradient(colors: [couleur.opacity(0.13), .clear], startPoint: .topLeading, endPoint: .center))
                    .allowsHitTesting(false)
            }
            .contentShape(.rect(cornerRadius: rayon))
    }
}

/// Tout ce qu'affichent les écrans du plan, calculé une fois par changement de données ou de montants.
struct VuePlan {
    let suivis: [String: Plan.Suivi]
    let debutPaie: String
    let paieDans: Int
    let soldes: [String: Double]          // argent réel sur chaque compte de poche
    let tr: Plan.TradeRepublic
    let livrets: [(nom: String, montant: Double)]
    var totalLivrets: Double { livrets.reduce(0) { $0 + $1.montant } }
    var total: Double { soldes.values.reduce(0, +) + totalLivrets }
    var objectif: Double { Plan.montant("objectif") }
    func suivi(_ id: String) -> Plan.Suivi? { suivis[id] }
    /// Ce qu'on peut encore dépenser, toutes poches de dépense confondues.
    var aDepenser: Double { Plan.poches.filter { !$0.epargne }.reduce(0) { $0 + max(suivis[$1.id]?.reste ?? 0, 0) } }
}

extension Magasin {
    var plan: VuePlan {
        let montants = (Plan.poches.map(\.id) + ["apport", "objectif"]).map { String(Plan.montant($0)) }.joined(separator: ",")
        return memo("plan|\(montants)") {
            let t = tableau(mode: .paie)
            let prochaine = J.plus(t.per.finBudget, jours: 1)
            let especesTR = solde("Trade Republic")
            let tr = Plan.tradeRepublic(toutes, especes: especesTR)
            var soldes: [String: Double] = [:]
            for p in Plan.poches { soldes[p.id] = p.id == "epargne" ? tr.especes + tr.pea : solde(p.compte) }
            let lv = livrets.map { l in l.noms.map { (nom: $0, montant: l.solde($0, le: J.auj)) } } ?? []
            return VuePlan(suivis: Plan.suivi(t.opsP, nomCompte: { nomCompte($0) }), debutPaie: t.per.debut,
                           paieDans: max(J.ecart(J.auj, prochaine), 0), soldes: soldes, tr: tr, livrets: lv)
        }
    }
}

// MARK: - Résumé : l'argent réel sur chaque compte

struct ResumePlan: View {
    private var montants = SuiviMontantsPlan()   // observe les montants du plan (réglages)
    @Environment(Magasin.self) private var magasin
    @Environment(\.accessibilityReduceMotion) private var reduire
    @State private var apparu = false

    var body: some View {
        let v = magasin.plan
        VStack(spacing: 10) {
            NavigationLink(value: "comptes") { heros(v) }.buttonStyle(.plain)
            VStack(spacing: 8) {
                HStack(spacing: 8) { tuile(Plan.poches[0], v, 0); tuile(Plan.poches[1], v, 1) }
                HStack(spacing: 8) { tuile(Plan.poches[2], v, 2); tuile(Plan.poches[3], v, 3) }
            }
            .frame(maxHeight: .infinity)
            NavigationLink(value: "apport") { carteApport(v) }.buttonStyle(.plain).entree(apparu, 4, reduire)
        }
        .onAppear { apparu = true }
    }

    private func heros(_ v: VuePlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tout ton argent").font(.subheadline).foregroundStyle(.secondary)
            Text(Fmt.eur(v.total, 2)).font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: v.total))
            HStack {
                Text("\(Plan.poches.count) comptes et \(v.livrets.count) livrets")
                Spacer()
                Text("au \(J.court(J.auj))")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .carteTeintee(Plan.poches[0].couleur)
    }

    private func tuile(_ p: Plan.Poche, _ v: VuePlan, _ i: Int) -> some View {
        let solde = v.soldes[p.id] ?? 0
        return NavigationLink(value: p.id) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    LogoBanque(image: p.logo, taille: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.banque).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                        Text(p.nom).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                Text(Fmt.eur(solde, 2)).font(.system(size: 25, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.55)
                    .contentTransition(.numericText(value: solde))
                Text(p.quoi).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Capsule().fill(p.couleur.opacity(0.85)).frame(width: 30, height: 3).padding(.top, 5)
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .carteTeintee(p.couleur)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.banque), \(p.nom) : \(Fmt.eur(solde, 2))")
        .entree(apparu, i, reduire)
    }

    private func carteApport(_ v: VuePlan) -> some View {
        let p = Plan.apport, part = v.objectif > 0 ? v.totalLivrets / v.objectif : 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                LogoBanque(image: p.logo, taille: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.nom).fontWeight(.semibold)
                    Text(p.quoi).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.eur(v.totalLivrets, 0)).font(.title3.weight(.bold)).monospacedDigit()
            }
            Jauge(part: part * 100, couleur: p.couleur, hauteur: 4)
            HStack {
                Text("\(Fmt.pct(part * 100)) de \(Fmt.eur(v.objectif, 0))")
                Spacer()
                Text("il manque \(Fmt.eur(max(v.objectif - v.totalLivrets, 0), 0))")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .carteTeintee(p.couleur)
    }
}

private extension View {
    /// Entrée en cascade (une seule fois, à l'ouverture), sauf si l'iPhone demande de réduire les animations.
    func entree(_ apparu: Bool, _ rang: Int, _ reduire: Bool) -> some View {
        self.opacity(apparu || reduire ? 1 : 0)
            .offset(y: apparu || reduire ? 0 : 10)
            .animation(reduire ? nil : .smooth(duration: 0.45).delay(Double(rang) * 0.05), value: apparu)
    }
}

// MARK: - Comptes : ce que j'ai le droit de dépenser

struct ComptesPlanView: View {
    private var montants = SuiviMontantsPlan()   // observe les montants du plan (réglages)
    @Environment(Magasin.self) private var magasin
    @AppStorage("masque") private var masque = false   // l'écran se redessine quand on masque les montants

    var body: some View {
        let _ = masque
        let v = magasin.plan
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Jusqu'à la paie · \(v.paieDans) jours").font(.subheadline).foregroundStyle(.secondary)
                            Text("Comptes").font(.largeTitle.bold())
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("à dépenser").font(.footnote).foregroundStyle(.secondary)
                            Text(Fmt.eur(v.aDepenser, 0)).font(.title2.bold()).monospacedDigit()
                        }
                        .padding(.bottom, 4)
                    }
                    BandeauEtat()
                    TitreSection(texte: "Ce que tu peux dépenser").padding(.top, 6)
                    ForEach(Plan.poches.filter { !$0.epargne }) { p in
                        if let s = v.suivi(p.id) { ligne(s, v) }
                    }
                    TitreSection(texte: "Ce qu'il reste à mettre de côté").padding(.top, 10)
                    if let s = v.suivi("epargne") { ligne(s, v) }
                    if let s = v.suivi("apport") { ligne(s, v) }
                    NavigationLink { ActiviteView() } label: { lien("list.bullet", "Toutes les opérations") }.buttonStyle(.plain).padding(.top, 6)
                    NavigationLink { TousComptesView() } label: { lien("building.columns", "Tous les comptes et livrets") }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 30)
            }
            .background(FondView())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in PocheDetailView(id: id) }
        }
    }

    private func ligne(_ s: Plan.Suivi, _ v: VuePlan) -> some View {
        let p = s.poche, epargne = p.epargne
        let aVerser = max(s.budget - s.dep, 0)
        let grand = epargne ? aVerser : max(s.reste, 0)
        let gauche = epargne ? (p.id == "apport" ? "Ce mois-ci \(Fmt.eur(s.dep, 0, signe: true)) sur \(Fmt.eur(s.budget, 0))" : "Versé \(Fmt.eur(s.dep, 0)) sur \(Fmt.eur(s.budget, 0))")
                             : "Dépensé \(Fmt.eur(s.dep, 0)) sur \(Fmt.eur(s.budget, 0))"
        return NavigationLink(value: p.id) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    LogoBanque(image: p.logo)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.id == "apport" ? "Apport" : p.nom).fontWeight(.semibold)
                        Text(p.id == "apport" ? "Livret Bleu · jour de paie" : p.id == "epargne" ? "\(p.banque) · le 30" : "\(p.banque) · \(p.quoi)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(Fmt.eur(grand, 0)).font(.title3.weight(.bold)).monospacedDigit()
                        .foregroundStyle(!epargne && s.reste <= 0 ? .secondary : .primary)
                }
                Jauge(part: s.part * 100, couleur: p.couleur, hauteur: 4)
                HStack {
                    Text(gauche)
                    Spacer()
                    Group {
                        if s.depasse { Text("\(Fmt.eur(-s.reste, 0)) de trop").foregroundStyle(Color.negatif) }
                        else if s.fait { Text("objectif atteint").foregroundStyle(Color.positif) }
                        else if epargne && s.dep < 0 { Text("\(Fmt.eur(-s.dep, 0)) retirés").foregroundStyle(Color.negatif) }
                        else if epargne { Text("à verser") }
                        else { Text("\(Fmt.eur(s.reste / Double(max(v.paieDans, 1)), 0)) par jour") }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .carteTeintee(p.couleur)
        }
        .buttonStyle(.plain)
    }

    private func lien(_ icone: String, _ texte: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icone).frame(width: 34, height: 34).background(.white.opacity(0.1), in: .rect(cornerRadius: 11))
            Text(texte).fontWeight(.semibold)
            Spacer()
            Chevron()
        }
        .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 56)
        .surface(in: .rect(cornerRadius: 20)).contentShape(.rect(cornerRadius: 20))
    }
}

// MARK: - Page d'un compte

struct PocheDetailView: View {
    private var montants = SuiviMontantsPlan()   // observe les montants du plan (réglages)
    @Environment(Magasin.self) private var magasin
    let id: String
    @State private var ouverte: Operation?

    var body: some View {
        let v = magasin.plan
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if id == "comptes" { ComptesRaccourci() }
                else if id == "epargne" { tradeRepublic(v) }
                else if id == "apport" { apport(v) }
                else if let s = v.suivi(id) { depenses(s, v) }
            }
            .padding(.horizontal, 16).padding(.bottom, 30)
        }
        .background(FondView())
        .navigationTitle(titre)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $ouverte) { DetailOperation(op: $0) }
    }

    private var titre: String {
        id == "comptes" ? "Comptes" : id == "apport" ? "Apport immobilier" : id == "epargne" ? "Trade Republic" : Plan.poches.first { $0.id == id }?.nom ?? ""
    }

    private func entete(_ p: Plan.Poche, _ titre: String, _ sous: String) -> some View {
        HStack(spacing: 12) {
            LogoBanque(image: p.logo, taille: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(titre).font(.title.bold())
                Text(sous).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }

    private func rangee(_ a: String, _ b: String, _ couleur: Color = .primary) -> some View {
        HStack { Text(a).foregroundStyle(.secondary); Spacer(); Text(b).fontWeight(.semibold).foregroundStyle(couleur).monospacedDigit() }.font(.footnote)
    }

    // Besoins, Envies, Voiture : ce qu'il reste, puis chaque dépense depuis la paie
    private func depenses(_ s: Plan.Suivi, _ v: VuePlan) -> some View {
        let p = s.poche
        return VStack(alignment: .leading, spacing: 10) {
            entete(p, p.nom, "\(p.banque) · \(p.quoi)")
            VStack(alignment: .leading, spacing: 8) {
                Text("Tu peux encore dépenser").font(.subheadline).foregroundStyle(.secondary)
                Text(Fmt.eur(max(s.reste, 0), 0)).font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(s.reste <= 0 ? .secondary : .primary)
                Jauge(part: s.part * 100, couleur: p.couleur, hauteur: 5)
                rangee("Dépensé depuis la paie", "\(Fmt.eur(s.dep, 2)) sur \(Fmt.eur(s.budget, 0))")
                if s.depasse { rangee("Dépassement", Fmt.eur(-s.reste, 2), .negatif) }
                else { rangee("Par jour jusqu'à la paie", Fmt.eur(s.reste / Double(max(v.paieDans, 1)), 2)) }
                rangee("Sur le compte \(p.banque)", Fmt.eur(v.soldes[p.id] ?? 0, 2))
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).carteTeintee(p.couleur)
            if p.id == "besoins" {
                // L'ancienne carte « Il te reste » du Résumé : le solde retracé depuis la paie et les prélèvements à venir
                NavigationLink { ResteDetailView() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Il te reste, en détail").fontWeight(.semibold)
                            Text("Ton solde depuis la paie et les prélèvements à venir").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Chevron()
                    }
                    .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 56)
                    .surface(in: .rect(cornerRadius: 18)).contentShape(.rect(cornerRadius: 18))
                }
                .buttonStyle(.plain)
            }
            TitreSection(texte: "Dépenses depuis la paie · \(s.lignes.count)").padding(.top, 8)
            jours(s.lignes) { l in
                ligneOp(l.titre, [l.sc, l.moitie ? "ta moitié" : nil, l.payeAvec.map { "payé avec \($0)" }].compactMap { $0 }.joined(separator: " · "),
                        -l.montant, l.op)
            }
            historique(p)
        }
    }

    // Trade Republic : espèces et PEA à part, puis les mouvements du compte
    private func tradeRepublic(_ v: VuePlan) -> some View {
        let p = Plan.poches[3], tr = v.tr, s = v.suivi("epargne")
        return VStack(alignment: .leading, spacing: 10) {
            entete(p, "Trade Republic", "Épargne · PEA et espèces")
            VStack(alignment: .leading, spacing: 8) {
                Text("Sur Trade Republic").font(.subheadline).foregroundStyle(.secondary)
                Text(Fmt.eur(tr.especes + tr.pea, 2)).font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                HStack(spacing: 8) {
                    caseTR("Espèces", tr.especes, "disponibles")
                    caseTR("PEA", tr.pea, "versés (prix d'achat)")
                }
                if let s { rangee("Versé ce mois-ci", "\(Fmt.eur(s.dep, 0)) sur \(Fmt.eur(s.budget, 0))", s.fait ? .positif : .primary) }
                if tr.pertes > 0.005 { rangee("Pertes de l'ancien compte-titres", Fmt.eur(tr.pertes, 2)) }
                Text("Le PEA est ce que tu as versé : tout ce qui est arrivé sur le compte et n'est plus en espèces. Sa valeur du jour se lit dans Trade Republic.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).carteTeintee(p.couleur)
            TitreSection(texte: "Mouvements · \(tr.mouvements.count)").padding(.top, 8)
            let lignes = tr.mouvements.map { o in
                Plan.Ligne(id: o.id, date: o.date, titre: o.note.isEmpty ? o.sc : Analyse.marchand(o),
                           sc: Calc.famillePlacement(o) == "PEA" && o.sc == "Investissement" ? "PEA" : o.sc,
                           montant: Calc.effet(o, "Trade Republic"), payeAvec: nil, moitie: false, op: o)
            }
            jours(lignes) { l in ligneOp(l.titre, l.sc, l.montant, l.op) }
            historique(p)
        }
    }

    private func caseTR(_ nom: String, _ montant: Double, _ sous: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nom).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.eur(montant, 2)).font(.title3.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sous).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 14))
    }

    // Apport : les livrets, et les versements ou retraits depuis la paie
    private func apport(_ v: VuePlan) -> some View {
        let p = Plan.apport, s = v.suivi("apport")
        return VStack(alignment: .leading, spacing: 10) {
            entete(p, "Apport immobilier", "Crédit Mutuel · objectif \(Fmt.eur(v.objectif, 0))")
            VStack(alignment: .leading, spacing: 8) {
                Text("Sur tes livrets").font(.subheadline).foregroundStyle(.secondary)
                Text(Fmt.eur(v.totalLivrets, 2)).font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                Jauge(part: v.objectif > 0 ? v.totalLivrets / v.objectif * 100 : 0, couleur: p.couleur, hauteur: 5)
                ForEach(v.livrets, id: \.nom) { l in rangee(l.nom, Fmt.eur(l.montant, 2)) }
                rangee("Il manque", Fmt.eur(max(v.objectif - v.totalLivrets, 0), 0))
                if let s { rangee("Ce mois-ci", "\(Fmt.eur(s.dep, 0, signe: true)) sur \(Fmt.eur(s.budget, 0))", s.dep < 0 ? .negatif : s.fait ? .positif : .primary) }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).carteTeintee(p.couleur)
            TitreSection(texte: "Depuis la paie").padding(.top, 8)
            jours(s?.lignes ?? []) { l in ligneOp(l.montant > 0 ? "Versement" : "Retrait", l.titre, l.montant, l.op) }
        }
    }

    /// Les opérations groupées par jour, avec le total du jour.
    @ViewBuilder
    private func jours<Rendu: View>(_ lignes: [Plan.Ligne], @ViewBuilder rendu: @escaping (Plan.Ligne) -> Rendu) -> some View {
        if lignes.isEmpty {
            Text("Aucune opération depuis la paie").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(20)
        } else {
            let parJour = Dictionary(grouping: lignes, by: \.date).sorted { $0.key > $1.key }
            ForEach(parJour, id: \.key) { jour, l in
                HStack {
                    Text(J.libelleJour(jour))
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(Array(l.enumerated()), id: \.element.id) { i, x in
                        if i > 0 { Divider().overlay(.white.opacity(0.06)) }
                        rendu(x)
                    }
                }
                .padding(.horizontal, 14)
                .surface(in: .rect(cornerRadius: 18))
            }
        }
    }

    private func ligneOp(_ titre: String, _ sous: String, _ montant: Double, _ op: Operation) -> some View {
        Button { ouverte = op } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titre).lineLimit(1)
                    if !sous.isEmpty { Text(sous).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Text(Fmt.eur(montant, 2, signe: true)).fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(montant > 0 ? Color.positif : .primary)
            }
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Lien vers l'historique complet du compte (toutes ses opérations, recherche, filtres).
    @ViewBuilder
    private func historique(_ p: Plan.Poche) -> some View {
        let cle = p.compte.isEmpty ? "courant" : p.compte
        if let c = magasin.comptesV3.first(where: { $0.id == cle }) {
            NavigationLink { HistoriqueCompteView(compte: c) } label: {
                HStack {
                    Text("Tout l'historique du compte").fontWeight(.semibold)
                    Spacer()
                    Chevron()
                }
                .padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 52)
                .surface(in: .rect(cornerRadius: 18)).contentShape(.rect(cornerRadius: 18))
            }
            .buttonStyle(.plain).padding(.top, 8)
        }
    }
}

/// Toucher « Tout ton argent » sur le Résumé : la liste de ce qu'on peut dépenser, sans changer d'onglet.
private struct ComptesRaccourci: View {
    @Environment(Magasin.self) private var magasin
    var body: some View {
        let v = magasin.plan
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Plan.poches) { p in
                NavigationLink(value: p.id) {
                    HStack(spacing: 12) {
                        LogoBanque(image: p.logo)
                        VStack(alignment: .leading, spacing: 1) { Text(p.banque).fontWeight(.semibold); Text(p.nom).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(Fmt.eur(v.soldes[p.id] ?? 0, 2)).fontWeight(.semibold).monospacedDigit()
                        Chevron()
                    }
                    .padding(14).carteTeintee(p.couleur)
                }
                .buttonStyle(.plain)
            }
            ForEach(v.livrets, id: \.nom) { l in
                HStack(spacing: 12) {
                    LogoBanque(image: Plan.apport.logo)
                    Text(l.nom).fontWeight(.semibold)
                    Spacer()
                    Text(Fmt.eur(l.montant, 2)).fontWeight(.semibold).monospacedDigit()
                }
                .padding(14).carteTeintee(Plan.apport.couleur)
            }
            HStack { Text("Total").fontWeight(.semibold); Spacer(); Text(Fmt.eur(v.total, 2)).fontWeight(.bold).monospacedDigit() }
                .padding(.horizontal, 6).padding(.top, 6)
        }
        .padding(.top, 8)
    }
}

// MARK: - Réglages : les montants du plan (gardés sur l'iPhone)

struct CartePlanReglages: View {
    @AppStorage("plan.besoins") private var besoins = 880.0
    @AppStorage("plan.envies") private var envies = 300.0
    @AppStorage("plan.voiture") private var voiture = 150.0
    @AppStorage("plan.epargne") private var epargne = 120.0
    @AppStorage("plan.apport") private var apport = 250.0
    @AppStorage("plan.objectif") private var objectif = 13_000.0

    var body: some View {
        CarteVerre(espacement: 10) {
            Text("Mon plan du mois").font(.headline)
            champ("Besoins", "Crédit Mutuel", $besoins)
            champ("Envies", "Revolut", $envies)
            champ("Voiture", "BoursoBank", $voiture)
            champ("Épargne", "Trade Republic", $epargne)
            champ("Apport chaque mois", "Livret Bleu", $apport)
            champ("Objectif d'apport", "Livret Bleu + Livret Jeune", $objectif)
            Text("Chaque mois repart de zéro à la paie. Enregistré sur cet iPhone.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func champ(_ nom: String, _ sous: String, _ valeur: Binding<Double>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) { Text(nom); Text(sous).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            TextField(nom, value: valeur, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).monospacedDigit()
                .frame(width: 96).padding(.vertical, 8).padding(.horizontal, 10)
                .background(.white.opacity(0.07), in: .rect(cornerRadius: 10))
            Text("€").foregroundStyle(.secondary)
        }
    }
}

/// Les écrans du plan se redessinent dès qu'un montant change dans les réglages.
struct SuiviMontantsPlan: DynamicProperty {
    @AppStorage("plan.besoins") var besoins = 880.0
    @AppStorage("plan.envies") var envies = 300.0
    @AppStorage("plan.voiture") var voiture = 150.0
    @AppStorage("plan.epargne") var epargne = 120.0
    @AppStorage("plan.apport") var apport = 250.0
    @AppStorage("plan.objectif") var objectif = 13_000.0
}
