import SwiftUI
import Charts

/// Les rubriques d'analyse (les 9 du site, plus les fonctions premium du prototype).
enum Rubrique: String, CaseIterable, Identifiable {
    case conseiller = "Conseiller", score = "Santé financière", rapport = "Rapport du mois", ensemble = "Vue d'ensemble"
    case depenses = "Dépenses", marchands = "Marchands et lieux", habitudes = "Habitudes", revenus = "Revenus"
    case epargne = "Épargne", patrimoine = "Patrimoine et placements", charges = "Charges fixes", comparer = "Comparer deux périodes"
    case anomalies = "Anomalies et doublons", simulations = "Simulations « et si »", jeux = "Jeux d'argent", saisons = "Saisons"
    var id: String { rawValue }
    var symbole: String {
        switch self {
        case .conseiller: "sparkles"; case .score: "heart.text.square"; case .rapport: "doc.text"; case .ensemble: "chart.bar"
        case .depenses: "chart.pie"; case .marchands: "storefront"; case .habitudes: "calendar"; case .revenus: "briefcase"
        case .epargne: "banknote"; case .patrimoine: "building.columns"; case .charges: "repeat"; case .comparer: "arrow.left.arrow.right"
        case .anomalies: "magnifyingglass"; case .simulations: "slider.horizontal.3"; case .jeux: "dice"; case .saisons: "sun.max"
        }
    }
}

/// Analyses (design v3, sans défilement) : graphique, trois chiffres, le conseil du moment, six rubriques.
struct AnalysesView: View {
    @Environment(Magasin.self) private var magasin
    @State private var n = 6
    @State private var moisChoisi: String?
    @State private var moisGarde: String?   // dernier mois touché : le détail reste affiché après avoir levé le doigt

    private let tuiles: [Rubrique] = [.depenses, .marchands, .habitudes, .revenus, .comparer]

    var body: some View {
        let ops = magasin.toutes, t = magasin.tableau()
        let donnees = Calc.mensuel(ops, n)
        let debut = donnees.first?.mois.debut ?? J.auj
        let nbMois = max(Double(J.ecart(debut, J.auj) + 1) / Ref.joursParMois, 1)
        let b = Calc.bilan(Calc.entre(ops, debut, J.auj))
        let sel = donnees.first { $0.mois.libelle == (moisChoisi ?? moisGarde) }
        let reco = Conseil.recommandations(t).first
        let sante = Conseil.score(t, budgetMensuel: magasin.profil?.budget ?? 0)
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) { Text("Tes tendances").font(.subheadline).foregroundStyle(.secondary); Text("Analyses").font(.largeTitle.bold()) }
                    Spacer()
                    Picker("Durée", selection: $n) { Text("6 mois").tag(6); Text("12 mois").tag(12) }.pickerStyle(.segmented).frame(width: 150)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Revenus et dépenses").font(.headline); Spacer()
                        Text(sel.map { "\($0.mois.long.capitalizedPremiere) : \(Fmt.eur($0.b.dep, 0))" } ?? "touche un mois").font(.footnote).foregroundStyle(.secondary) }
                    Chart {
                        ForEach(donnees, id: \.mois.cle) { m in
                            BarMark(x: .value("Mois", m.mois.libelle), y: .value("Montant", m.b.rev)).foregroundStyle(by: .value("Série", "Revenus")).position(by: .value("Série", "Revenus")).cornerRadius(4)
                                .opacity(sel == nil || sel?.mois.cle == m.mois.cle ? 1 : 0.3)
                            BarMark(x: .value("Mois", m.mois.libelle), y: .value("Montant", m.b.dep)).foregroundStyle(by: .value("Série", "Dépenses")).position(by: .value("Série", "Dépenses")).cornerRadius(4)
                                .opacity(sel == nil || sel?.mois.cle == m.mois.cle ? 1 : 0.3)
                        }
                    }
                    .chartForegroundStyleScale(["Revenus": Color.white.opacity(0.3), "Dépenses": Color.white])
                    .chartXSelection(value: $moisChoisi)
                    .onChange(of: moisChoisi) { _, v in if let v { moisGarde = v } }
                    .sensoryFeedback(.selection, trigger: moisGarde)
                    .frame(maxHeight: .infinity)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
                HStack(spacing: 8) {
                    chiffre("Dépenses/mois", Fmt.eur(b.dep / nbMois, 0), "moyenne \(n) mois")
                    chiffre("Taux d'épargne", b.rev > 0 ? Fmt.pct(b.epa / b.rev * 100) : "—", "repère : 20 %")
                    chiffre("Santé", "\(sante.total)/100", sante.niveau)
                }
                if let reco {
                    NavigationLink { ConseillerView() } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "sparkles").frame(width: 34, height: 34).background(.white.opacity(0.1), in: .rect(cornerRadius: 11))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Le conseil du moment").font(.subheadline.weight(.semibold))
                                Text(reco.texte).font(.footnote).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                if reco.gain > 1 { Text("≈ \(Fmt.eur(reco.gain, 0)) de plus par mois").font(.caption.weight(.semibold)).foregroundStyle(Color.positif) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22)).contentShape(.rect(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(tuiles) { r in NavigationLink { RubriqueView(rubrique: r) } label: { tuile(r.symbole, r.rawValue.replacingOccurrences(of: " et lieux", with: "").replacingOccurrences(of: " deux périodes", with: "")) }.buttonStyle(.plain) }
                    NavigationLink { ToutesRubriquesView() } label: { tuile("square.grid.2x2", "Toutes · 16") }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
            .background(FondView())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func chiffre(_ t: String, _ v: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(v).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(s).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func tuile(_ symbole: String, _ nom: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbole).font(.title3).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(nom).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20)).contentShape(.rect(cornerRadius: 20))
    }
}

/// Les 16 rubriques sur une page entière (4 × 4), et les notes du conseiller.
struct ToutesRubriquesView: View {
    @Environment(Magasin.self) private var magasin
    @State private var notes = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Toutes les façons de regarder ton budget.").font(.subheadline).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(0..<4, id: \.self) { ligne in
                    GridRow {
                        ForEach(Rubrique.allCases[ligne * 4..<ligne * 4 + 4]) { r in
                            NavigationLink { RubriqueView(rubrique: r) } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: r.symbole).font(.title3)
                                    Text(r.rawValue.replacingOccurrences(of: " et placements", with: "").replacingOccurrences(of: " « et si »", with: "")
                                        .replacingOccurrences(of: " deux périodes", with: "").replacingOccurrences(of: " et doublons", with: "").replacingOccurrences(of: " et lieux", with: ""))
                                        .font(.caption.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                                }
                                .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20)).contentShape(.rect(cornerRadius: 20))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
        .background(FondView())
        .navigationTitle("Rubriques")
        .toolbar { Button("Notes") { notes = true } }
        .sheet(isPresented: $notes) {
            NavigationStack {
                List(Conseil.notes(magasin.toutes, mois: 6)) { note in
                    HStack(alignment: .top, spacing: 12) { Pastille(symbole: note.symbole); Text(note.texte).font(.subheadline) }
                }
                .navigationTitle("Les notes du conseiller")
            }
            .presentationDetents([.medium, .large])
        }
    }
}
