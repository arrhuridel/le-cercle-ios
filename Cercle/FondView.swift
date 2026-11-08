import SwiftUI

/// Les 10 fonds au choix (Le Cercle › Fond), mêmes idées que l'aperçu du 08/11. Couleurs du thème choisi.
/// Le verre liquide « clear » ne se voit que s'il a quelque chose de net à déformer : chaque fond a des formes nettes.
enum StyleFond: String, CaseIterable, Identifiable {
    case formes = "Formes", aurore = "Aurore", grille = "Grille néon", vagues = "Vagues", bokeh = "Bokeh"
    case marbre = "Marbre", prisme = "Prisme", rayures = "Rayures", points = "Points", nuit = "Nuit étoilée"
    var id: String { rawValue }
    static let cle = "fond"
}

struct FondView: View {
    /// Style imposé (aperçus du choix) ; sinon celui des réglages.
    var style: StyleFond? = nil
    var anime = true
    @Environment(\.accessibilityReduceMotion) private var animationsReduites
    @AppStorage(ThemeCouleurs.cle) private var couleurs = ThemeCouleurs.nuit.rawValue
    @AppStorage(StyleFond.cle) private var fondBrut = StyleFond.formes.rawValue

    var body: some View {
        let t = ThemeCouleurs(rawValue: couleurs) ?? .nuit
        let st = style ?? StyleFond(rawValue: fondBrut) ?? .formes
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: animationsReduites || !anime)) { contexte in
            let s = contexte.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                ZStack {
                    t.fond
                    dessin(st, t, g.size, s)
                    if style == nil {
                        // Voile sombre très léger en haut et en bas : les textes restent lisibles sur le verre transparent
                        LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
            }
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.8), value: couleurs)
    }

    @ViewBuilder
    private func dessin(_ st: StyleFond, _ t: ThemeCouleurs, _ z: CGSize, _ s: Double) -> some View {
        let c = t.taches, w = z.width, h = z.height
        switch st {
        case .formes:
            let v = s / 9
            ZStack {
                forme(c[0], w * 0.95, w * (0.05 + 0.08 * sin(v)), h * (0.12 + 0.04 * cos(v * 0.7)))
                forme(c[1], w * 0.85, w * (0.98 + 0.06 * cos(v * 0.8)), h * (0.42 + 0.05 * sin(v * 0.6)))
                forme(c[2], w * 1.05, w * (0.15 + 0.07 * sin(v * 0.5)), h * (0.88 + 0.03 * cos(v)))
                forme(c[3], w * 0.55, w * (0.72 + 0.10 * sin(v * 0.9)), h * (0.70 + 0.06 * cos(v * 0.4)))
                Canvas { ctx, taille in bandes(ctx, taille, pas: 46, decalage: s / 9, couleur: .white.opacity(0.045), epaisseur: 1) }.blendMode(.plusLighter)
            }
        case .aurore:
            let v = s / 6
            ZStack {
                rideau(c[2], w * 0.35, h * 0.95, w * (0.18 + 0.05 * sin(v)), h * 0.2)
                rideau(c[0], w * 0.30, h * 0.85, w * (0.52 + 0.06 * cos(v * 0.8)), h * 0.12)
                rideau(c[1], w * 0.28, h * 0.90, w * (0.84 + 0.04 * sin(v * 1.2)), h * 0.18)
                Ellipse().fill(c[3].opacity(0.6)).frame(width: w * 1.6, height: h * 0.3).blur(radius: 30).position(x: w / 2, y: h * 1.02)
            }
        case .grille:
            Canvas { ctx, taille in
                let horizon = taille.height * 0.45, fuite = CGPoint(x: taille.width / 2, y: horizon)
                ctx.fill(Path(ellipseIn: CGRect(x: taille.width * 0.67, y: taille.height * 0.02, width: taille.width * 0.22, height: taille.width * 0.22)), with: .color(c[3]))
                ctx.fill(Path(CGRect(x: 0, y: horizon, width: taille.width, height: taille.height - horizon)), with: .linearGradient(Gradient(colors: [t.fond, c[1].opacity(0.4)]), startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: taille.height)))
                for i in -12...12 {   // lignes qui partent du point de fuite
                    var p = Path(); p.move(to: fuite); p.addLine(to: CGPoint(x: taille.width / 2 + CGFloat(i) * taille.width * 0.22, y: taille.height))
                    ctx.stroke(p, with: .color(c[0].opacity(0.85)), lineWidth: 1.5)
                }
                let d = (s / 2.5).truncatingRemainder(dividingBy: 1)
                for k in 0..<14 {   // lignes horizontales qui avancent
                    let f = (Double(k) + d) / 14, y = horizon + (taille.height - horizon) * CGFloat(f * f)
                    var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: taille.width, y: y))
                    ctx.stroke(p, with: .color(c[0].opacity(0.85)), lineWidth: 1.5)
                }
            }
        case .vagues:
            Canvas { ctx, taille in
                let centre = CGPoint(x: taille.width / 2, y: taille.height * 1.25), pas: CGFloat = 34
                let d = CGFloat((s / 14).truncatingRemainder(dividingBy: 1)) * pas * 4
                let teintes = [c[0], c[1], c[2], t.fond]
                var r = taille.height * 1.6 + d
                var i = 0
                while r > 0 {
                    ctx.fill(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)), with: .color(teintes[i % 4]))
                    r -= pas; i += 1
                }
            }
        case .bokeh:
            let points: [(CGFloat, CGFloat, CGFloat, Int)] = [(0.15, 0.2, 34, 0), (0.78, 0.12, 22, 1), (0.6, 0.38, 46, 3), (0.25, 0.55, 28, 2), (0.85, 0.62, 58, 0),
                                                              (0.4, 0.82, 40, 1), (0.08, 0.9, 20, 3), (0.92, 0.92, 30, 2), (0.48, 0.08, 14, 2), (0.7, 0.76, 16, 3)]
            ZStack {
                ForEach(points.indices, id: \.self) { i in
                    let p = points[i]
                    Circle().fill(c[p.3]).frame(width: p.2 * 2, height: p.2 * 2)
                        .position(x: w * p.0 + 6 * sin(s / 4 + Double(i)), y: h * p.1 + 6 * cos(s / 5 + Double(i)))
                }
            }
        case .marbre:
            AngularGradient(colors: [c[0], c[1], t.fond, c[2], c[3], t.fond, c[0]], center: UnitPoint(x: 0.35, y: 0.4))
                .hueRotation(.degrees(25 * sin(s / 20)))
        case .prisme:
            let a = (s / 30).truncatingRemainder(dividingBy: 1) * 360
            AngularGradient(gradient: Gradient(stops: [
                .init(color: c[0], location: 0), .init(color: c[0], location: 0.15), .init(color: c[1], location: 0.15), .init(color: c[1], location: 0.33),
                .init(color: t.fond, location: 0.33), .init(color: t.fond, location: 0.46), .init(color: c[2], location: 0.46), .init(color: c[2], location: 0.64),
                .init(color: c[3], location: 0.64), .init(color: c[3], location: 0.8), .init(color: t.fond, location: 0.8), .init(color: t.fond, location: 0.89),
                .init(color: c[0], location: 0.89), .init(color: c[0], location: 1)]), center: UnitPoint(x: 0.62, y: 0.34), angle: .degrees(a))
        case .rayures:
            Canvas { ctx, taille in
                let teintes = [c[0], t.fond, c[1], t.fond, c[2], t.fond], largeurs: [CGFloat] = [64, 28, 64, 28, 64, 28]
                let motif = largeurs.reduce(0, +), d = CGFloat((s / 20).truncatingRemainder(dividingBy: 1)) * motif
                var x = -taille.height - motif + d, i = 0
                while x < taille.width {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + largeurs[i % 6], y: 0))
                    p.addLine(to: CGPoint(x: x + largeurs[i % 6] + taille.height, y: taille.height)); p.addLine(to: CGPoint(x: x + taille.height, y: taille.height))
                    ctx.fill(p, with: .color(teintes[i % 6]))
                    x += largeurs[i % 6]; i += 1
                }
            }
        case .points:
            ZStack {
                RadialGradient(colors: [c[0], .clear], center: UnitPoint(x: 0.25, y: 0.25), startRadius: 0, endRadius: w * 0.9)
                RadialGradient(colors: [c[2], .clear], center: UnitPoint(x: 0.8, y: 0.8), startRadius: 0, endRadius: w * 0.9)
                Canvas { ctx, taille in
                    var y: CGFloat = 9
                    while y < taille.height {
                        var x: CGFloat = 9
                        while x < taille.width { ctx.fill(Path(ellipseIn: CGRect(x: x - 2.4, y: y - 2.4, width: 4.8, height: 4.8)), with: .color(c[1].opacity(0.9))); x += 18 }
                        y += 18
                    }
                }
            }
        case .nuit:
            ZStack {
                Ellipse().fill(c[1].opacity(0.5)).frame(width: w * 1.4, height: h * 0.6).blur(radius: 40).position(x: w / 2, y: 0)
                Canvas { ctx, taille in
                    let etoiles: [(CGFloat, CGFloat, CGFloat)] = [(0.2, 0.15, 1.5), (0.7, 0.22, 1), (0.4, 0.4, 1.5), (0.85, 0.55, 1), (0.12, 0.62, 1.5), (0.55, 0.08, 1),
                                                                   (0.9, 0.12, 1), (0.3, 0.75, 1.5), (0.62, 0.3, 1), (0.05, 0.3, 1), (0.78, 0.4, 1.5), (0.48, 0.6, 1)]
                    for (i, e) in etoiles.enumerated() {
                        let eclat = 0.6 + 0.4 * sin(s * 1.3 + Double(i))
                        ctx.fill(Path(ellipseIn: CGRect(x: taille.width * e.0, y: taille.height * e.1, width: e.2 * 2, height: e.2 * 2)), with: .color(.white.opacity(eclat)))
                    }
                }
                Circle().fill(c[0]).frame(width: w * 1.2, height: w * 1.2).position(x: w / 2, y: h + w * 0.25)
            }
        }
    }

    private func forme(_ couleur: Color, _ taille: CGFloat, _ x: CGFloat, _ y: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [couleur, couleur.opacity(0.85)], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: taille * 0.6))
            .frame(width: taille, height: taille)
            .blur(radius: 6)
            .position(x: x, y: y)
    }
    private func rideau(_ couleur: Color, _ largeur: CGFloat, _ hauteur: CGFloat, _ x: CGFloat, _ y: CGFloat) -> some View {
        Ellipse().fill(LinearGradient(colors: [couleur, couleur.opacity(0)], startPoint: .top, endPoint: .bottom))
            .frame(width: largeur, height: hauteur).blur(radius: 14).position(x: x, y: y + hauteur * 0.3)
    }
    private func bandes(_ ctx: GraphicsContext, _ taille: CGSize, pas: CGFloat, decalage: Double, couleur: Color, epaisseur: CGFloat) {
        let d = CGFloat(decalage.truncatingRemainder(dividingBy: 1)) * pas
        var x: CGFloat = -taille.height + d
        while x < taille.width {
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x + taille.height, y: taille.height))
            ctx.stroke(p, with: .color(couleur), lineWidth: epaisseur)
            x += pas
        }
    }
}
