import SwiftUI

/// Fond de l'app, pensé pour le verre liquide « clear » d'Apple : ce verre est transparent et ne se voit que s'il a
/// quelque chose de net à déformer derrière lui. D'où de grosses formes de couleur aux bords nets (peu de flou),
/// de fines bandes de lumière et un fond sombre : le bord des cartes réfracte ces formes, comme sur les fonds d'écran d'iOS 26.
/// Les couleurs suivent le thème choisi (Le Cercle › Thème). Tout s'arrête si « Réduire les animations » est actif.
struct FondView: View {
    @Environment(\.accessibilityReduceMotion) private var animationsReduites
    @AppStorage(ThemeCouleurs.cle) private var couleurs = ThemeCouleurs.nuit.rawValue

    var body: some View {
        let t = ThemeCouleurs(rawValue: couleurs) ?? .nuit, c = t.taches
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: animationsReduites)) { contexte in
            let s = contexte.date.timeIntervalSinceReferenceDate / 9
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    t.fond
                    // Grosses formes nettes : ce sont elles que le verre déforme
                    forme(c[0], w * 0.95, x: w * (0.05 + 0.08 * sin(s)), y: h * (0.12 + 0.04 * cos(s * 0.7)))
                    forme(c[1], w * 0.85, x: w * (0.98 + 0.06 * cos(s * 0.8)), y: h * (0.42 + 0.05 * sin(s * 0.6)))
                    forme(c[2], w * 1.05, x: w * (0.15 + 0.07 * sin(s * 0.5)), y: h * (0.88 + 0.03 * cos(s)))
                    forme(c[3], w * 0.55, x: w * (0.72 + 0.10 * sin(s * 0.9)), y: h * (0.70 + 0.06 * cos(s * 0.4)))
                    // Bandes de lumière fines et diagonales : donnent du détail à réfracter sur le bord des cartes
                    Canvas { ctx, taille in
                        let pas: CGFloat = 46, decale = CGFloat(s.truncatingRemainder(dividingBy: 1)) * pas
                        var x: CGFloat = -taille.height + decale
                        while x < taille.width {
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + taille.height, y: taille.height))
                            ctx.stroke(p, with: .color(.white.opacity(0.045)), lineWidth: 1)
                            x += pas
                        }
                    }
                    .blendMode(.plusLighter)
                    // Voile sombre très léger en haut et en bas : les textes restent lisibles sur le verre transparent
                    LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: w, height: h)
                .clipped()
            }
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.8), value: couleurs)
    }

    /// Une forme ronde saturée, au bord à peine adouci (un vrai flou effacerait la réfraction).
    private func forme(_ couleur: Color, _ taille: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [couleur, couleur.opacity(0.85)], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: taille * 0.6))
            .frame(width: taille, height: taille)
            .blur(radius: 6)
            .position(x: x, y: y)
    }
}
