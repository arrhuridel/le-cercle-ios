import SwiftUI

/// Fond unique de l'app (choix du 09/11 : une seule identité, la plus claire possible pour une app de budget).
/// Les couleurs du site : fond #14181C, avec une seule lueur bleu-gris très douce en haut. Fixe : rien ne bouge
/// derrière les chiffres, et le verre des commandes (onglets, boutons) a juste assez de relief pour se voir.
struct FondView: View {
    static let fond = Color(red: 0x14 / 255, green: 0x18 / 255, blue: 0x1C / 255)
    static let lueur = Color(red: 0x2E / 255, green: 0x41 / 255, blue: 0x55 / 255)

    var body: some View {
        ZStack {
            Self.fond
            RadialGradient(colors: [Self.lueur.opacity(0.75), .clear], center: UnitPoint(x: 0.2, y: -0.05), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.24, green: 0.84, blue: 0.55).opacity(0.07), .clear], center: UnitPoint(x: 0.9, y: 1.05), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}
