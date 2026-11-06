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

struct AnalysesView: View {
    @Environment(Magasin.self) private var magasin
    @State private var n = 6
    @State private var moisChoisi: String?
    @State private var moisGarde: String?   // dernier mois touché : le détail reste affiché après avoir levé le doigt

    var body: some View {
        let ops = magasin.toutes
        let donnees = Calc.mensuel(ops, n)
        let debut = donnees.first?.mois.debut ?? J.auj
        let nbMois = max(Double(J.ecart(debut, J.auj) + 1) / Ref.joursParMois, 1)
        let b = Calc.bilan(Calc.entre(ops, debut, J.auj))
        let sel = donnees.first { $0.mois.libelle == (moisChoisi ?? moisGarde) }
        NavigationStack {
            Ecran {
                Picker("Durée", selection: $n) { Text("6 mois").tag(6); Text("12 mois").tag(12) }.pickerStyle(.segmented)
                CarteVerre {
                    Text("Revenus et dépenses").font(.headline)
                    Text("Mois par mois, part du loyer remboursée déduite").font(.footnote).foregroundStyle(.secondary)
                    Chart {
                        ForEach(donnees, id: \.mois.cle) { m in
                            BarMark(x: .value("Mois", m.mois.libelle), y: .value("Montant", m.b.rev)).foregroundStyle(by: .value("Série", "Revenus")).position(by: .value("Série", "Revenus")).cornerRadius(4)
                                .opacity(sel == nil || sel?.mois.cle == m.mois.cle ? 1 : 0.3)
                            BarMark(x: .value("Mois", m.mois.libelle), y: .value("Montant", m.b.dep)).foregroundStyle(by: .value("Série", "Dépenses")).position(by: .value("Série", "Dépenses")).cornerRadius(4)
                                .opacity(sel == nil || sel?.mois.cle == m.mois.cle ? 1 : 0.3)
                        }
                    }
                    .chartForegroundStyleScale(["Revenus": Color(red: 0.5, green: 0.7, blue: 0.63), "Dépenses": Color(red: 0.76, green: 0.6, blue: 0.43)])
                    .chartXSelection(value: $moisChoisi)
                    .onChange(of: moisChoisi) { _, v in if let v { moisGarde = v } }
                    .sensoryFeedback(.selection, trigger: moisGarde)
                    .frame(height: 200)
                    if let s = sel {
                        HStack {
                            detail("Revenus", s.b.rev); detail("Dépenses", s.b.dep); detail("Épargne", s.b.epa); detail("Reste", s.b.reste)
                        }
                        Text(s.mois.long.capitalizedPremiere + (s.mois.enCours ? " · mois en cours" : "")).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Touche un mois pour voir le détail.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    Kpi(titre: "Revenus par mois", valeur: Fmt.eur(b.rev / nbMois, 0), sous: "moyenne")
                    Kpi(titre: "Dépenses par mois", valeur: Fmt.eur(b.dep / nbMois, 0), sous: "besoins + envies")
                    Kpi(titre: "Taux d'épargne", valeur: b.rev > 0 ? Fmt.pct(b.epa / b.rev * 100) : "—", sous: "épargne nette / revenus")
                    Kpi(titre: "Épargne nette", valeur: Fmt.eur(b.epa, 0), sous: "sur \(n) mois")
                }
                TitreSection(texte: "Rubriques")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Rubrique.allCases) { r in
                        NavigationLink { RubriqueView(rubrique: r) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: r.symbole).font(.title3).frame(width: 36, height: 36).background(.quaternary, in: .rect(cornerRadius: 11))
                                Text(r.rawValue).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading).padding(14)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                            .contentShape(.rect(cornerRadius: 22))
                        }
                        .buttonStyle(.plain)
                    }
                }
                TitreSection(texte: "Les notes du conseiller")
                CarteVerre(espacement: 12) {
                    ForEach(Conseil.notes(ops, mois: n)) { note in
                        HStack(alignment: .top, spacing: 12) { Pastille(symbole: note.symbole); Text(note.texte).font(.subheadline) }
                    }
                }
                Text("Calculées sur ton iPhone à partir de tes opérations. Ce ne sont pas des conseils financiers réglementés.").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Analyses")
        }
    }

    private func detail(_ t: String, _ v: Double) -> some View {
        VStack(alignment: .leading) { Text(t).font(.caption).foregroundStyle(.secondary); Text(Fmt.eur(v, 0)).font(.subheadline.weight(.semibold)).monospacedDigit() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
