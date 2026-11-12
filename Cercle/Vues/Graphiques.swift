import SwiftUI
import Charts

// Graphiques touchables de l'app (refaits le 12/11/2026, demande d'Arthur : plus visuels, plus interactifs).
// Principe commun : on touche ou on glisse le doigt sur le graphique, la période ou la part touchée reste vive,
// les autres pâlissent, et son détail s'affiche au-dessus. Une petite vibration accompagne chaque changement.

// MARK: - Couleurs

extension Color {
    /// Vert, rouge et jaune francs de l'identité de l'app (#3DD68C, #FF6B6B, #FFC145) : réservés aux graphiques,
    /// les textes gardent les teintes adoucies.
    static let vertVif = Color(red: 0x3D / 255, green: 0xD6 / 255, blue: 0x8C / 255)
    static let rougeVif = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x6B / 255)
    static let jauneVif = Color(red: 0xFF / 255, green: 0xC1 / 255, blue: 0x45 / 255)
    static let cielVif = Color(red: 0x4F / 255, green: 0xC3 / 255, blue: 0xF7 / 255)
    static let violetVif = Color(red: 0xB3 / 255, green: 0x88 / 255, blue: 0xFF / 255)
    static let orangeVif = Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x65 / 255)
    /// Couleurs des parts d'un graphique en anneau, de la plus grosse à la plus petite.
    static let paletteGraphiques: [Color] = [rougeVif, jauneVif, vertVif, cielVif, violetVif, orangeVif]
}

/// Axe des montants : sans signe (« 1 000 » en haut comme en bas), quatre repères, lignes très discrètes.
func axeEuros() -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) { v in
        AxisGridLine().foregroundStyle(.white.opacity(0.08))
        AxisValueLabel {
            if let d = v.as(Double.self) { Text(Fmt.nombre(abs(d), 0)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Dégradé d'une barre : couleur pleine près de la ligne du zéro… à l'opposé, plus légère vers l'extrémité.
func degradeBarre(_ c: Color, negative: Bool = false) -> LinearGradient {
    LinearGradient(colors: [c, c.opacity(0.55)], startPoint: negative ? .bottom : .top, endPoint: negative ? .top : .bottom)
}

/// La période touchée reste vive, les autres pâlissent.
func opaciteSelection(_ cle: String, _ choisie: String?) -> Double {
    guard let choisie else { return 1 }
    return choisie == cle ? 1 : 0.3
}

// MARK: - Barres par période

struct Barre: Identifiable {
    let cle: String
    let libelle: String
    let v: Double
    /// Base de comparaison facultative (salaire et CAF de la période, pour l'épargne).
    var base: Double = 0
    var id: String { cle }
}

/// Une barre par mois (ou par année), une ligne pointillée de repère (moyenne, objectif),
/// et au-dessus le détail de la barre touchée comparé au repère.
struct BarresInteractives: View {
    let barres: [Barre]
    var couleur: Color = .vertVif
    var couleurNegative: Color = .rougeVif
    var repere: Double? = nil
    var nomRepere = "moyenne"
    /// Vrai si dépasser le repère est une bonne nouvelle (épargne), faux sinon (dépenses).
    var hausseBonne = true
    var precision: (Barre) -> String = { _ in "" }

    @State private var choisi: String?
    @State private var garde: String?

    var body: some View {
        let sel: Barre? = barres.first { $0.libelle == (choisi ?? garde) }
        VStack(alignment: .leading, spacing: 10) {
            entete(sel)
            graphique(sel)
        }
    }

    @ViewBuilder private func entete(_ sel: Barre?) -> some View {
        if let b = sel {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(b.libelle.capitalizedPremiere).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.eur(b.v, 0)).font(.title3.bold()).monospacedDigit().foregroundStyle(b.v < 0 ? couleurNegative : couleur)
                }
                if !precision(b).isEmpty { Text(precision(b)).font(.footnote).foregroundStyle(.secondary) }
                if let r = repere { Text(ecart(b.v - r)).font(.footnote.weight(.semibold)).foregroundStyle(teinteEcart(b.v - r)) }
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { garde = nil; choisi = nil }   // toucher le détail revient à la vue d'ensemble
        } else {
            HStack(spacing: 8) {
                Text("Touche une barre").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if let r = repere {
                    Rectangle().fill(.white.opacity(0.6)).frame(width: 14, height: 1.5)
                    Text("\(nomRepere) \(Fmt.eur(r, 0))").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(minHeight: 44, alignment: .leading)
        }
    }

    private func ecart(_ d: Double) -> String {
        if abs(d) < 0.5 { return "Pile sur la \(nomRepere)" }
        return "\(Fmt.eur(d, 0, signe: true)) par rapport à la \(nomRepere)"
    }

    private func teinteEcart(_ d: Double) -> Color {
        if abs(d) < 0.5 { return .secondary }
        return (d > 0) == hausseBonne ? .vertVif : .rougeVif
    }

    private func remplissage(_ b: Barre) -> LinearGradient {
        degradeBarre(b.v < 0 ? couleurNegative : couleur, negative: b.v < 0)
    }

    private func graphique(_ sel: Barre?) -> some View {
        Chart {
            ForEach(barres) { b in
                BarMark(x: .value("Période", b.libelle), y: .value("Montant", b.v))
                    .foregroundStyle(remplissage(b))
                    .cornerRadius(5)
                    .opacity(opaciteSelection(b.cle, sel?.cle))
            }
            if let r = repere {
                RuleMark(y: .value("Repère", r))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
        }
        .chartXSelection(value: $choisi)
        .chartYAxis { axeEuros() }
        .onChange(of: choisi) { _, v in if let v { garde = v } }
        .sensoryFeedback(.selection, trigger: garde)
        .frame(height: 190)
        .accessibilityLabel(barres.map { "\($0.libelle) : \(Fmt.eur($0.v, 0))" }.joined(separator: ", "))
    }
}

// MARK: - Barres empilées (charges fixes et dépenses courantes)

struct BarresEmpilees: View {
    let points: [PointCharges]
    @State private var choisi: String?
    @State private var garde: String?

    var body: some View {
        let sel: PointCharges? = points.first { $0.libelle == (choisi ?? garde) }
        VStack(alignment: .leading, spacing: 10) {
            entete(sel)
            graphique(sel)
        }
    }

    private func entete(_ sel: PointCharges?) -> some View {
        let n = Double(max(points.count, 1))
        let fixes = sel?.fixes ?? points.reduce(0) { $0 + $1.fixes } / n
        let courantes = sel?.courantes ?? points.reduce(0) { $0 + $1.courantes } / n
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(sel.map { $0.libelle.capitalizedPremiere } ?? "En moyenne").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.eur(fixes + courantes, 0)).font(.title3.bold()).monospacedDigit()
            }
            HStack(alignment: .bottom, spacing: 16) {
                legende(.jauneVif, "Fixes", Fmt.eur(fixes, 0))
                legende(Color.rougeVif.opacity(0.8), "Courantes", Fmt.eur(courantes, 0))
                Spacer(minLength: 8)
                if fixes + courantes > 0 {
                    legendeDroite("Part fixe", Fmt.pct(fixes / (fixes + courantes) * 100))
                }
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture { garde = nil; choisi = nil }
    }

    private func graphique(_ sel: PointCharges?) -> some View {
        Chart {
            ForEach(points) { p in
                BarMark(x: .value("Période", p.libelle), y: .value("Montant", p.fixes))
                    .foregroundStyle(by: .value("Type", "Charges fixes"))
                    .opacity(opaciteSelection(p.cle, sel?.cle))
                BarMark(x: .value("Période", p.libelle), y: .value("Montant", p.courantes))
                    .foregroundStyle(by: .value("Type", "Dépenses courantes"))
                    .opacity(opaciteSelection(p.cle, sel?.cle))
            }
        }
        .chartForegroundStyleScale(["Charges fixes": Color.jauneVif, "Dépenses courantes": Color.rougeVif.opacity(0.8)])
        .chartLegend(.hidden)
        .chartXSelection(value: $choisi)
        .chartYAxis { axeEuros() }
        .onChange(of: choisi) { _, v in if let v { garde = v } }
        .sensoryFeedback(.selection, trigger: garde)
        .frame(height: 200)
        .accessibilityLabel("Charges fixes et dépenses courantes, par période")
    }
}

/// Légende d'un graphique : le carré de couleur et le nom sur une ligne, le montant en dessous.
/// Sur deux lignes, le nom n'est plus coupé quand le montant a un chiffre de plus (retour d'Arthur du 12/11).
func legende(_ couleur: Color, _ nom: String, _ valeur: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(couleur).frame(width: 10, height: 10)
            Text(nom).font(.caption).foregroundStyle(.secondary).fixedSize()
        }
        Text(valeur).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
    }
    .accessibilityElement(children: .combine)
}

/// Même présentation, alignée à droite (l'écart ou la part, au bout de la ligne de légende).
func legendeDroite(_ nom: String, _ valeur: String, _ couleur: Color = .primary) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
        Text(nom).font(.caption).foregroundStyle(.secondary).fixedSize()
        Text(valeur).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(couleur).lineLimit(1).minimumScaleFactor(0.7)
    }
    .accessibilityElement(children: .combine)
}

// MARK: - Anneau des catégories

struct PartAnneau: Identifiable {
    let nom: String
    let sc: String?
    let v: Double
    let couleur: Color
    var id: String { nom }
}

/// Anneau des dépenses par catégorie : on touche une part (ou une ligne de la liste),
/// son montant et sa part du total s'affichent au centre.
struct AnneauCategories: View {
    let postes: [AnalyseDepenses.Poste]
    let total: Double
    @State private var angle: Double?
    @State private var garde: String?

    private var parts: [PartAnneau] {
        var l: [PartAnneau] = []
        for (i, p) in postes.prefix(6).enumerated() {
            l.append(PartAnneau(nom: p.sc, sc: p.sc, v: p.v, couleur: Color.paletteGraphiques[i % Color.paletteGraphiques.count]))
        }
        let reste: Double = postes.dropFirst(6).reduce(0) { $0 + $1.v }
        if reste > 0.5 { l.append(PartAnneau(nom: "Autres", sc: nil, v: reste, couleur: Color.white.opacity(0.3))) }
        return l
    }

    /// La part qui se trouve sous le doigt : on additionne les parts dans l'ordre jusqu'à dépasser l'angle touché.
    private static func trouver(_ angle: Double, _ l: [PartAnneau]) -> PartAnneau? {
        var cumul = 0.0
        for p in l {
            cumul += p.v
            if angle <= cumul { return p }
        }
        return l.last
    }

    var body: some View {
        let l = parts
        let sel: PartAnneau? = garde.flatMap { g in l.first { $0.nom == g } }
        VStack(spacing: 12) {
            ZStack {
                anneau(l, sel)
                centre(sel).allowsHitTesting(false)
            }
            .frame(height: 230)
            VStack(spacing: 2) {
                ForEach(l) { p in ligne(p, sel) }
            }
        }
    }

    private func anneau(_ l: [PartAnneau], _ sel: PartAnneau?) -> some View {
        Chart(l) { p in
            SectorMark(angle: .value("Montant", p.v), innerRadius: .ratio(0.64), angularInset: 1.5)
                .cornerRadius(5)
                .foregroundStyle(p.couleur)
                .opacity(opaciteSelection(p.nom, sel?.nom))
        }
        .chartAngleSelection(value: $angle)
        .onChange(of: angle) { _, a in
            if let a, let p = Self.trouver(a, l) { garde = p.nom }
        }
        .sensoryFeedback(.selection, trigger: garde)
        .accessibilityLabel(l.map { "\($0.nom) : \(Fmt.eur($0.v, 0))" }.joined(separator: ", "))
    }

    private func centre(_ sel: PartAnneau?) -> some View {
        VStack(spacing: 2) {
            Text(sel?.nom ?? "Total").font(.footnote).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            Text(Fmt.eur(sel?.v ?? total, 0)).font(.title2.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            if let s = sel, total > 0 {
                Text("\(Fmt.pct(s.v / total * 100)) du total").font(.footnote).foregroundStyle(s.couleur)
            }
        }
        .frame(maxWidth: 130)
    }

    private func ligne(_ p: PartAnneau, _ sel: PartAnneau?) -> some View {
        let active = sel?.nom == p.nom
        return Button {
            garde = active ? nil : p.nom
        } label: {
            HStack(spacing: 10) {
                Circle().fill(p.couleur).frame(width: 10, height: 10)
                Text(p.nom).lineLimit(1)
                Spacer()
                Text(Fmt.eur(p.v, 0)).monospacedDigit().fontWeight(.semibold)
                Text(total > 0 ? Fmt.pct(p.v / total * 100) : "").font(.footnote).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .background(active ? Color.white.opacity(0.08) : .clear, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(opaciteSelection(p.nom, sel?.nom) < 1 ? 0.6 : 1)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Courbe dans le temps (patrimoine)

/// Courbe lissée sur dégradé, verte si elle monte, rouge si elle baisse. Glisser le doigt affiche
/// le montant du jour touché et l'écart avec aujourd'hui.
struct CourbeInteractive: View {
    let points: [PointPatrimoine]
    @State private var choisi: Date?

    private func proche(_ d: Date?) -> PointPatrimoine? {
        guard let d else { return nil }
        return points.min { abs($0.jour.timeIntervalSince(d)) < abs($1.jour.timeIntervalSince(d)) }
    }

    var body: some View {
        let sel = proche(choisi)
        let valeurs = points.map(\.v)
        let mini = valeurs.min() ?? 0, maxi = valeurs.max() ?? 1
        let marge = max((maxi - mini) * 0.15, 10)
        let monte = (points.last?.v ?? 0) >= (points.first?.v ?? 0)
        VStack(alignment: .leading, spacing: 10) {
            entete(sel)
            courbe(sel, bas: mini - marge, haut: maxi + marge, couleur: monte ? .vertVif : .rougeVif)
        }
    }

    private func entete(_ sel: PointPatrimoine?) -> some View {
        let actuel = points.last?.v ?? 0
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sel.map { "Le " + J.court(J.iso($0.jour)) } ?? "Aujourd'hui").font(.subheadline).foregroundStyle(.secondary)
                if let s = sel {
                    let d = actuel - s.v
                    Text("\(Fmt.eur(d, 0, signe: true)) depuis").font(.footnote.weight(.semibold)).foregroundStyle(d >= 0 ? Color.vertVif : Color.rougeVif)
                } else {
                    Text("Glisse le doigt sur la courbe").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(Fmt.eur(sel?.v ?? actuel, 0)).font(.title3.bold()).monospacedDigit()
        }
        .frame(minHeight: 44)
    }

    private func courbe(_ sel: PointPatrimoine?, bas: Double, haut: Double, couleur: Color) -> some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Jour", p.jour), yStart: .value("Bas", bas), yEnd: .value("Total", p.v))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [couleur.opacity(0.35), couleur.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Jour", p.jour), y: .value("Total", p.v))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(couleur)
            }
            if let s = sel {
                RuleMark(x: .value("Jour", s.jour)).foregroundStyle(.white.opacity(0.35))
                PointMark(x: .value("Jour", s.jour), y: .value("Total", s.v)).symbolSize(90).foregroundStyle(.white)
            }
        }
        .chartYScale(domain: bas...haut)
        .chartXSelection(value: $choisi)
        .chartYAxis { axeEuros() }
        .sensoryFeedback(.selection, trigger: sel?.jour)
        .frame(height: 200)
        .accessibilityLabel("Évolution de ton argent : de \(Fmt.eur(points.first?.v ?? 0, 0)) à \(Fmt.eur(points.last?.v ?? 0, 0))")
    }
}
