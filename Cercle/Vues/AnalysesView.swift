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

/// Analyses (sans défilement) : la durée, le graphique des revenus et dépenses, puis quatre tuiles.
/// Chaque tuile montre déjà son chiffre clé (dépenses par mois, taux d'épargne, patrimoine, charges fixes)
/// et ouvre sa page de détail. Refait le 12/11/2026.
struct AnalysesView: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    @AppStorage("masque") private var masque = false   // l'écran se redessine quand on masque les montants
    @State private var choisi: String?
    @State private var garde: String?   // dernière barre touchée : le détail reste affiché après avoir levé le doigt

    var body: some View {
        let _ = masque
        // Calculs gardés en mémoire : glisser le doigt sur le graphique ne recalcule pas l'historique
        let points: [PointAnalyse] = magasin.bilansAnalyse(duree)
        let r: ResumeAnalyses = magasin.resumeAnalyses(duree)
        let sel: PointAnalyse? = points.first { $0.libelle == (choisi ?? garde) } ?? points.last
        let vide: Bool = points.allSatisfy { $0.rev == 0 && $0.dep == 0 }
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tes tendances").font(.subheadline).foregroundStyle(.secondary)
                    Text("Analyses").font(.largeTitle.bold())
                }
                SelecteurDuree()
                BandeauEtat()
                graphique(points, sel, vide)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    NavigationLink { DepensesDetail() } label: {
                        tuile("chart.pie", "Dépenses", Fmt.eur(r.depensesParMois, 0), "par mois en moyenne")
                    }
                    .buttonStyle(.plain)
                    NavigationLink { EpargneDetail() } label: {
                        tuile("banknote", "Épargne", r.tauxEpargne.map { Fmt.pct($0) } ?? "—", "de ton salaire et CAF · repère 20 %")
                    }
                    .buttonStyle(.plain)
                    NavigationLink { PatrimoineDetail() } label: {
                        tuile("building.columns", "Patrimoine", Fmt.eur(r.patrimoine, 0), "tout ton argent aujourd'hui")
                    }
                    .buttonStyle(.plain)
                    NavigationLink { ChargesDetail() } label: {
                        tuile("repeat", "Charges fixes", Fmt.eur(r.chargesParMois, 0), "par mois · \(r.nbCharges) prélèvements")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
            .background(FondView())
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: duree) { _, _ in choisi = nil; garde = nil }
        }
    }

    /// Le graphique et, au-dessus, le détail de la barre touchée (par défaut : la dernière période).
    private func graphique(_ points: [PointAnalyse], _ sel: PointAnalyse?, _ vide: Bool) -> some View {
        let plafond: Double = max(points.map { max($0.rev, $0.dep) }.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Revenus et dépenses").font(.headline)
                Spacer()
                Text(sel?.libelle ?? "").font(.footnote).foregroundStyle(.secondary)
            }
            if let s = sel, !vide {
                HStack(spacing: 14) {
                    legende(Self.vert, "Revenus", Fmt.eur(s.rev, 0))
                    legende(Self.rouge, "Dépenses", Fmt.eur(s.dep, 0))
                    Spacer(minLength: 0)
                    Text(Fmt.eur(s.rev - s.dep, 0, signe: true)).font(.footnote.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(s.rev - s.dep < 0 ? Self.rouge : Self.vert)
                }
            }
            if vide {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar").font(.title2).foregroundStyle(.secondary)
                    Text("Pas encore d'opérations sur cette durée.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Revenus en vert au-dessus de la ligne du zéro, dépenses en rouge en dessous (demande du 12/11/2026)
                Chart {
                    RuleMark(y: .value("Zéro", 0)).foregroundStyle(.white.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
                    ForEach(points) { p in
                        BarMark(x: .value("Période", p.libelle), y: .value("Montant", p.rev))
                            .foregroundStyle(Self.vert).cornerRadius(4)
                            .opacity(opacite(p, sel))
                        BarMark(x: .value("Période", p.libelle), y: .value("Montant", -p.dep))
                            .foregroundStyle(Self.rouge).cornerRadius(4)
                            .opacity(opacite(p, sel))
                    }
                }
                .chartXSelection(value: $choisi)
                .chartYScale(domain: -plafond...plafond)
                // Les montants de l'axe sont écrits sans signe : « 1 000 » en haut comme en bas
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { v in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(Fmt.nombre(abs(d), 0)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .onChange(of: choisi) { _, v in if let v { garde = v } }
                .sensoryFeedback(.selection, trigger: garde)
                .frame(maxHeight: .infinity)
                .accessibilityLabel("Revenus et dépenses \(duree.texte). Touche une barre pour voir une période.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface(in: .rect(cornerRadius: 24))
    }

    /// Vert et rouge francs de l'identité de l'app (#3DD68C, #FF6B6B), plus lisibles que les teintes sourdes des textes.
    static let vert = Color(red: 0x3D / 255, green: 0xD6 / 255, blue: 0x8C / 255)
    static let rouge = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x6B / 255)

    /// La période touchée reste vive, les autres pâlissent.
    private func opacite(_ p: PointAnalyse, _ sel: PointAnalyse?) -> Double {
        guard let sel else { return 1 }
        return sel.cle == p.cle ? 1 : 0.35
    }

    private func legende(_ couleur: Color, _ nom: String, _ valeur: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(couleur).frame(width: 10, height: 10)
            Text(nom).foregroundStyle(.secondary)
            Text(valeur).monospacedDigit().fontWeight(.semibold)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    /// Une rubrique : son nom, son chiffre clé, une précision. Toute la tuile ouvre le détail.
    private func tuile(_ symbole: String, _ nom: String, _ valeur: String, _ sous: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbole).foregroundStyle(.secondary).frame(width: 20)
                Text(nom).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Chevron()
            }
            Text(valeur).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sous).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .surface(in: .rect(cornerRadius: 16)).contentShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
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
