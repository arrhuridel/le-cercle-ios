import SwiftUI

/// Fond coloré qui dérive lentement : c'est lui que le verre liquide déforme. Plus il est vivant, plus le verre se voit
/// (revue du 08/11 : l'ancien fond, très sombre, rendait le verre presque invisible). Couleurs du thème choisi.
struct FondView: View {
    @Environment(\.accessibilityReduceMotion) private var animationsReduites
    @AppStorage(ThemeCouleurs.cle) private var couleurs = ThemeCouleurs.nuit.rawValue

    var body: some View {
        let t = ThemeCouleurs(rawValue: couleurs) ?? .nuit, c = t.taches, f = t.fond
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: animationsReduites)) { contexte in
            let s = Float(contexte.date.timeIntervalSinceReferenceDate / 40)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + 0.18 * sin(s), 0.5 + 0.18 * cos(s * 0.8)], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    c[0], f, c[1],
                    f, f, c[3].opacity(0.75),
                    c[2], f, c[3],
                ]
            )
            .opacity(0.95)
            .ignoresSafeArea()
        }
        .background(f.ignoresSafeArea())
        .animation(.smooth(duration: 0.8), value: couleurs)
    }
}
