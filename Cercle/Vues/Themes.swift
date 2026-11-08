import SwiftUI

/// Les 10 thèmes de couleurs (mêmes valeurs que l'aperçu du 08/11) : fond, 4 taches de couleur derrière le verre,
/// couleurs Besoins / Envies / Épargne. Choisi dans Le Cercle › Thème, gardé dans les réglages de l'iPhone.
enum ThemeCouleurs: String, CaseIterable, Identifiable {
    case nuit = "Nuit", graphite = "Graphite", ocean = "Océan", aurore = "Aurore", foret = "Forêt"
    case desert = "Désert", bordeaux = "Bordeaux", orNoir = "Or noir", neon = "Néon", glacier = "Glacier"
    var id: String { rawValue }

    private static func h(_ v: UInt32) -> Color { Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255) }

    private var valeurs: (fond: UInt32, taches: [UInt32], familles: [UInt32]) {
        switch self {
        case .nuit: (0x0E1216, [0x3F6EA3, 0x6E54B0, 0x2B8580, 0xB5864A], [0x8FA6C8, 0xD2A878, 0x6FCF9F])
        case .graphite: (0x0C0C0E, [0x4A4A52, 0x2E2E34, 0x6B6B73, 0x8A8478], [0xC8CCD2, 0xA39C90, 0xE6E8EB])
        case .ocean: (0x061520, [0x0E6BA8, 0x1B9AAA, 0x0B3C5D, 0x3FC1C9], [0x7FB7E6, 0xF2C57C, 0x5FE0C1])
        case .aurore: (0x120A1A, [0x7B2FF7, 0xF72585, 0x4361EE, 0xB5179E], [0x9D8DF1, 0xF49AC1, 0x72EFDD])
        case .foret: (0x0A140F, [0x1F5F3F, 0x3E7B4F, 0x7A8F3A, 0x20463A], [0x9CC5A1, 0xE0C27A, 0x7EE0A0])
        case .desert: (0x17110B, [0xB5703A, 0x8C4A2F, 0xD9A35B, 0x5E3B26], [0xE3C9A0, 0xF09A5B, 0xA8D58A])
        case .bordeaux: (0x160A0D, [0x7A1F33, 0xA63A50, 0x4A1A2A, 0xC7845A], [0xD9A0AE, 0xE8B07A, 0x8FD3B0])
        case .orNoir: (0x0B0A08, [0x8A6A2F, 0x3A2E1A, 0xC9A45C, 0x5A4A2A], [0xD8C39A, 0xE5B45A, 0xB9D98A])
        case .neon: (0x05060D, [0x00B4A0, 0x7B3FD0, 0xD1449A, 0x0090D0], [0x38C6FF, 0xFF6FC2, 0x2EF2D0])
        case .glacier: (0x0B1320, [0x6FA8DC, 0xA7C7E7, 0x3D5A80, 0xCFE8EF], [0xA7C7E7, 0xF4D58D, 0x8EE3EF])
        }
    }
    var fond: Color { Self.h(valeurs.fond) }
    var taches: [Color] { valeurs.taches.map(Self.h) }
    var besoins: Color { Self.h(valeurs.familles[0]) }
    var envies: Color { Self.h(valeurs.familles[1]) }
    var epargne: Color { Self.h(valeurs.familles[2]) }

    static let cle = "couleurs"
    static var actuel: ThemeCouleurs { ThemeCouleurs(rawValue: UserDefaults.standard.string(forKey: cle) ?? "") ?? .nuit }
}

/// Choix du thème : on touche, l'app change tout de suite derrière la feuille.
struct ChoixThemeView: View {
    @AppStorage(ThemeCouleurs.cle) private var couleurs = ThemeCouleurs.nuit.rawValue
    @Environment(\.dismiss) private var fermer

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(ThemeCouleurs.allCases) { t in
                        Button { couleurs = t.rawValue } label: { tuile(t) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Thème \(t.rawValue)")
                            .accessibilityAddTraits(couleurs == t.rawValue ? .isSelected : [])
                    }
                }
                .padding(16)
            }
            .background(FondView())
            .navigationTitle("Thème")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { fermer() } } }
            .sensoryFeedback(.selection, trigger: couleurs)
        }
        .presentationDetents([.medium, .large])
    }

    private func tuile(_ t: ThemeCouleurs) -> some View {
        let tc = t.taches
        return VStack(alignment: .leading) {
            Text(t.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            Spacer()
            HStack(spacing: 5) { ForEach([t.besoins, t.envies, t.epargne], id: \.self) { c in Circle().fill(c).frame(width: 12, height: 12) } }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background {
            ZStack {
                t.fond
                RadialGradient(colors: [tc[0], .clear], center: .topLeading, startRadius: 0, endRadius: 120)
                RadialGradient(colors: [tc[1], .clear], center: .trailing, startRadius: 0, endRadius: 110)
                RadialGradient(colors: [tc[2], .clear], center: .bottom, startRadius: 0, endRadius: 100)
            }
            .clipShape(.rect(cornerRadius: 20))
        }
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(couleurs == t.rawValue ? Color.white : .white.opacity(0.18), lineWidth: couleurs == t.rawValue ? 2 : 0.5))
    }
}
