import SwiftUI
import WidgetKit

// Widgets de Le Cercle : petit (reste du mois), moyen (50-30-20), grand (reste et prélèvements), écran verrouillé.
// Ils lisent les chiffres que l'app dépose dans l'espace partagé (Partage.swift) après chaque mise à jour.

struct Entree: TimelineEntry {
    let date: Date
    let d: Partage.Donnees?
}

struct Fournisseur: TimelineProvider {
    func placeholder(in context: Context) -> Entree { Entree(date: Date(), d: .exemple) }
    func getSnapshot(in context: Context, completion: @escaping (Entree) -> Void) {
        completion(Entree(date: Date(), d: context.isPreview ? (Partage.lire() ?? .exemple) : Partage.lire()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entree>) -> Void) {
        // L'app redemande un affichage à chaque mise à jour ; sinon iOS repasse au plus tard dans 30 minutes
        completion(Timeline(entries: [Entree(date: Date(), d: Partage.lire())], policy: .after(Date().addingTimeInterval(1800))))
    }
}

// MARK: - Fond et petits éléments

private let fondNuit = Color(red: 0.08, green: 0.09, blue: 0.11)
private let besoinsC = Color(red: 0.56, green: 0.65, blue: 0.78)
private let enviesC = Color(red: 0.82, green: 0.66, blue: 0.47)
private let epargneC = Color(red: 0.44, green: 0.81, blue: 0.62)
private let alerteC = Color(red: 1.0, green: 0.76, blue: 0.27)

private struct Fond: View {
    var body: some View {
        ZStack {
            fondNuit
            RadialGradient(colors: [Color(red: 0.25, green: 0.43, blue: 0.64).opacity(0.55), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
            RadialGradient(colors: [Color(red: 0.43, green: 0.33, blue: 0.69).opacity(0.45), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 240)
        }
    }
}

private struct Anneau: View {
    let part: Double, couleur: Color, texte: String
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 6)
            Circle().trim(from: 0, to: min(max(part / 100, 0), 1)).stroke(couleur, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
            Text(texte).font(.caption.weight(.semibold)).monospacedDigit()
        }
    }
}

private struct Jauge: View {
    let part: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(.white).frame(width: g.size.width * min(max(part / 100, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("\(Int(part.rounded())) % de l'argent du mois déjà sorti")
    }
}

private struct SansDonnees: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Le Cercle").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("Ouvre l'app une fois pour afficher tes chiffres.").font(.footnote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private func finTexte(_ d: Partage.Donnees) -> some View {
    Text("Fin du mois ≈ \(d.finMois < 0 ? "−" : "")\(Partage.eur(abs(d.finMois)))")
        .font(.caption2.weight(.medium)).foregroundStyle(d.finMois < 0 ? alerteC : .secondary).lineLimit(1).minimumScaleFactor(0.8)
}

// MARK: - Reste du mois (petit, grand, écran verrouillé)

struct VueReste: View {
    @Environment(\.widgetFamily) private var famille
    let e: Entree

    var body: some View {
        if let d = e.d {
            switch famille {
            case .accessoryCircular: rond(d)
            case .accessoryRectangular: rectangle(d)
            case .accessoryInline: Text("\(Partage.eur(d.solde)) · \(Partage.eur(d.parJour))/jour")
            case .systemLarge: grand(d)
            default: petit(d)
            }
        } else if famille == .accessoryCircular || famille == .accessoryRectangular || famille == .accessoryInline {
            Text("Le Cercle")
        } else {
            SansDonnees()
        }
    }

    private func petit(_ d: Partage.Donnees) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Il te reste").font(.caption).foregroundStyle(.secondary)
            Text(Partage.eur(d.solde)).font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            Spacer(minLength: 0)
            Text("\(Partage.eur(d.parJour)) par jour · \(d.joursRestants) j").font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            finTexte(d)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "lecercle://reste"))
    }

    private func grand(_ d: Partage.Donnees) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Ce mois · jusqu'au \(d.finTexte)").font(.caption).foregroundStyle(.secondary); Spacer(); Text("Le Cercle").font(.caption).foregroundStyle(.tertiary) }
            Text(Partage.eur(d.solde, decimales: 2)).font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            Jauge(part: d.part)
            HStack { Text("\(Partage.eur(d.parJour)) par jour").font(.caption).foregroundStyle(.secondary); Spacer(); finTexte(d) }
            Text("Prochains prélèvements").font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            if d.prochains.isEmpty { Text("Aucun d'ici la fin du mois").font(.footnote) }
            ForEach(d.prochains, id: \.self) { p in
                HStack {
                    Text(p.nom).font(.subheadline).lineLimit(1)
                    Text("· \(p.date)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("−\(Partage.eur(p.montant, decimales: 2))").font(.subheadline).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            Link(destination: URL(string: "lecercle://ajouter")!) {
                Label("Ajouter une dépense", systemImage: "plus").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44).background(.white.opacity(0.14), in: .capsule)
            }
        }
        .widgetURL(URL(string: "lecercle://reste"))
    }

    private func rond(_ d: Partage.Donnees) -> some View {
        Gauge(value: min(max(d.part, 0), 100), in: 0...100) { Text("Mois") } currentValueLabel: { Text("\(Int(d.solde.rounded()))").monospacedDigit() }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
            .accessibilityLabel("Il te reste \(Partage.eur(d.solde))")
    }

    private func rectangle(_ d: Partage.Donnees) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(Partage.eur(d.solde)) · \(Partage.eur(d.parJour))/jour").font(.headline).widgetAccentable().lineLimit(1).minimumScaleFactor(0.7)
            if let p = d.prochains.first { Text("Prochain : \(p.nom) \(Partage.eur(p.montant, decimales: 2))").font(.caption).lineLimit(1) }
            else { Text("Aucun prélèvement à venir").font(.caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 50-30-20 (moyen)

struct VueRegle: View {
    let e: Entree
    var body: some View {
        if let d = e.d {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Règle 50-30-20").font(.subheadline.weight(.semibold)); Spacer(); Text("\(Partage.eur(d.solde)) dispo").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    colonne("Besoins", d.besoins, 50, besoinsC)
                    colonne("Envies", d.envies, 30, enviesC)
                    colonne("Épargne", d.epargne, 20, epargneC)
                }
                .frame(maxHeight: .infinity)
            }
            .widgetURL(URL(string: "lecercle://regle"))
        } else {
            SansDonnees()
        }
    }
    private func colonne(_ nom: String, _ v: Double, _ cible: Double, _ c: Color) -> some View {
        VStack(spacing: 4) {
            Anneau(part: v / cible * 100, couleur: c, texte: "\(Int(v.rounded())) %").frame(width: 58, height: 58)
            Text(nom).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(nom) : \(Int(v.rounded())) % du salaire, pour une cible de \(Int(cible)) %")
    }
}

// MARK: - Déclaration

struct WidgetReste: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.lecercle.reste", provider: Fournisseur()) { e in
            VueReste(e: e).containerBackground(for: .widget) { Fond() }
        }
        .configurationDisplayName("Il te reste")
        .description("Ton solde, ce que tu peux dépenser par jour et la fin du mois estimée.")
        .supportedFamilies([.systemSmall, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct WidgetRegle: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "fr.lecercle.regle", provider: Fournisseur()) { e in
            VueRegle(e: e).containerBackground(for: .widget) { Fond() }
        }
        .configurationDisplayName("Règle 50-30-20")
        .description("Besoins, envies et épargne du mois.")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct WidgetsCercle: WidgetBundle {
    var body: some Widget {
        WidgetReste()
        WidgetRegle()
    }
}
