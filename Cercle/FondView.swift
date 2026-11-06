import SwiftUI

/// Fond sourd qui dérive très lentement : bleu ardoise, indigo, vert canard, bronze, faible saturation.
/// Le point central du dégradé tourne sur un cercle ; un tour dure environ 4 minutes.
struct FondView: View {
    @Environment(\.accessibilityReduceMotion) private var animationsReduites

    private static let ardoise = Color(red: 0.23, green: 0.35, blue: 0.46)
    private static let indigo = Color(red: 0.28, green: 0.29, blue: 0.52)
    private static let canard = Color(red: 0.17, green: 0.40, blue: 0.39)
    private static let bronze = Color(red: 0.52, green: 0.40, blue: 0.25)
    private static let nuit = Color(red: 0.05, green: 0.06, blue: 0.08)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: animationsReduites)) { contexte in
            let t = Float(contexte.date.timeIntervalSinceReferenceDate / 40)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + 0.15 * sin(t), 0.5 + 0.15 * cos(t * 0.8)], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    Self.ardoise, Self.nuit, Self.indigo,
                    Self.nuit, Self.nuit, Self.nuit,
                    Self.canard, Self.nuit, Self.bronze,
                ]
            )
            .opacity(0.9)
            .ignoresSafeArea()
        }
    }
}
