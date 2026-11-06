import SwiftUI

/// Écran de démonstration : grand titre qui se réduit au défilement, cartes en verre sur le fond qui dérive.
/// Il sera remplacé écran par écran à partir de l'étape 3.4.
struct EcranProvisoire: View {
    let titre: String
    let sousTitre: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CarteVerre {
                        Text(sousTitre).font(.headline)
                        Text("Première version : elle sert à vérifier la chaîne de fabrication (GitHub, puis Sideloadly) et le verre liquide sur ton iPhone.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(1...6, id: \.self) { numero in
                        CarteVerre {
                            HStack {
                                Image(systemName: "sparkles")
                                    .frame(width: 36, height: 36)
                                    .glassEffect(.regular, in: .rect(cornerRadius: 11))
                                Text("Carte \(numero)")
                                Spacer()
                                Text("0,00 €").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Le Cercle \(versionApp)")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle(titre)
            .background(FondView())
        }
    }

    private var versionApp: String {
        let infos = Bundle.main.infoDictionary
        let version = infos?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infos?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Une carte en verre liquide (API native d'iOS 26).
struct CarteVerre<Contenu: View>: View {
    @ViewBuilder let contenu: Contenu

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { contenu }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// Feuille « Nouvelle opération » provisoire : poignée, grand montant, bouton en verre.
struct FeuilleSaisieProvisoire: View {
    @Environment(\.dismiss) private var fermer

    var body: some View {
        VStack(spacing: 20) {
            Text("Nouvelle opération").font(.headline).padding(.top, 24)
            Text("0,00 €")
                .font(.system(size: 58, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("Le pavé numérique et les catégories arrivent à l'étape 3.4.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Fermer") { fermer() }
                .font(.headline)
                .padding(.horizontal, 40)
                .padding(.vertical, 14)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }
}
