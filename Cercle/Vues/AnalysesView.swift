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
        case .conseiller: "lightbulb"; case .score: "heart.text.square"; case .rapport: "doc.text"; case .ensemble: "chart.bar"
        case .depenses: "chart.pie"; case .marchands: "storefront"; case .habitudes: "calendar"; case .revenus: "briefcase"
        case .epargne: "banknote"; case .patrimoine: "building.columns"; case .charges: "repeat"; case .comparer: "arrow.left.arrow.right"
        case .anomalies: "magnifyingglass"; case .simulations: "slider.horizontal.3"; case .jeux: "dice"; case .saisons: "sun.max"
        }
    }
}

/// Analyses (sans défilement) : le graphique des revenus et dépenses, trois chiffres, quatre rubriques essentielles.
struct AnalysesView: View {
    @Environment(Magasin.self) private var magasin
    @State private var n = 6
    @State private var moisChoisi: String?
    @State private var moisGarde: String?   // dernier mois touché : le détail reste affiché après avoir levé le doigt

    /// Les quatre rubriques utiles pour suivre son argent (les autres ne sont plus proposées).
    private let tuiles: [(Rubrique, String)] = [(.depenses, "Dépenses"), (.epargne, "Épargne"), (.patrimoine, "Patrimoine"), (.charges, "Charges fixes")]

    var body: some View {
        // Ces calculs sont gardés en mémoire : glisser le doigt sur le graphique ne recalcule plus tout l'historique
        let donnees = magasin.memo("analyses.mensuel|\(n)") { Calc.mensuel(magasin.toutes, n) }
        let debut = donnees.first?.mois.debut ?? J.auj
        let nbMois = max(Double(J.ecart(debut, J.auj) + 1) / Ref.joursParMois, 1)
        let b = magasin.memo("analyses.bilan|\(n)") { Calc.bilan(Calc.entre(magasin.toutes, debut, J.auj)) }
        let sel = donnees.first { $0.mois.libelle == (moisChoisi ?? moisGarde) }
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) { Text("Tes tendances").font(.subheadline).foregroundStyle(.secondary); Text("Analyses").font(.largeTitle.bold()) }
                    Spacer()
                    Picker("Durée", selection: $n) { Text("6 mois").tag(6); Text("12 mois").tag(12) }.pickerStyle(.segmented).frame(width: 150)
                        .padding(.bottom, 6)
                }
                BandeauEtat()
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
                    .chartYScale(domain: 0...max(donnees.map { max($0.b.rev, $0.b.dep) }.max() ?? 1, 1))
                    .onChange(of: moisChoisi) { _, v in if let v { moisGarde = v } }
                    .sensoryFeedback(.selection, trigger: moisGarde)
                    .frame(maxHeight: .infinity)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .surface(in: .rect(cornerRadius: 24))
                HStack(spacing: 8) {
                    chiffre("Dépenses/mois", Fmt.eur(b.dep / nbMois, 0), "sur \(n) mois")
                    chiffre("Épargne", b.rev > 0 ? Fmt.pct(b.epa / b.rev * 100) : "—", "repère : 20 %")
                    chiffre("Revenus/mois", Fmt.eur(b.rev / nbMois, 0), "sur \(n) mois")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    ForEach(tuiles, id: \.0) { r, nom in
                        NavigationLink { RubriqueView(rubrique: r) } label: { tuile(r.symbole, nom) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
            .background(FondView())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func chiffre(_ t: String, _ v: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(v).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .surface(in: .rect(cornerRadius: 16))
    }

    /// Une rubrique : icône, nom, chevron, sur une ligne de 56 pt (facile à toucher).
    private func tuile(_ symbole: String, _ nom: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbole).foregroundStyle(.secondary).frame(width: 24)
            Text(nom).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Chevron()
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .surface(in: .rect(cornerRadius: 16)).contentShape(.rect(cornerRadius: 16))
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
                                .surface(in: .rect(cornerRadius: 24)).contentShape(.rect(cornerRadius: 24))
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
