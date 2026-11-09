import SwiftUI

/// Une carte en verre liquide (API native d'iOS 26).
struct CarteVerre<Contenu: View>: View {
    var espacement: CGFloat = 6
    @ViewBuilder let contenu: Contenu
    var body: some View {
        VStack(alignment: .leading, spacing: espacement) { contenu }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(in: .rect(cornerRadius: 24))
    }
}

/// Le symbole d'un thème dans une pastille teintée.
struct Tuile: View {
    let sc: String
    var taille: CGFloat = 36
    var body: some View {
        let t = Ref.theme(sc)
        Image(systemName: t.symbole)
            .font(.system(size: taille * 0.45, weight: .medium))
            .foregroundStyle(t.teinte)
            .frame(width: taille, height: taille)
            .background(t.teinte.opacity(0.22), in: .rect(cornerRadius: taille * 0.3))
    }
}

struct Pastille: View {
    let symbole: String
    var teinte: Color = .secondary
    var body: some View {
        Image(systemName: symbole)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(teinte)
            .frame(width: 36, height: 36)
            .background(teinte.opacity(0.2), in: .rect(cornerRadius: 11))
    }
}

struct TitreSection: View {
    let texte: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        HStack {
            Text(texte.uppercased()).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let action { Button(action.0, action: action.1).font(.subheadline.weight(.semibold)).tint(.primary) }
        }
        .padding(.horizontal, 6).padding(.top, 14)
    }
}

/// Barre de progression fine ; `repere` montre où on devrait en être aujourd'hui.
struct Jauge: View {
    let part: Double
    var couleur: Color = .primary
    var repere: Double? = nil
    var hauteur: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(couleur).frame(width: g.size.width * min(max(part, 0), 100) / 100)
                if let repere { Capsule().fill(.secondary).frame(width: 2, height: hauteur + 8).offset(x: g.size.width * min(repere, 100) / 100 - 1) }
            }
        }
        .frame(height: hauteur)
        .animation(.spring(response: 0.8, dampingFraction: 0.85), value: part)
    }
}

struct Kpi: View {
    let titre: String
    let valeur: String
    var sous: String = ""
    var couleur: Color = .primary
    var symbole: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label { Text(titre) } icon: { if let symbole { Image(systemName: symbole) } }
                .font(.footnote).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            Text(valeur).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(couleur).minimumScaleFactor(0.7).lineLimit(1)
            if !sous.isEmpty { Text(sous).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .surface(in: .rect(cornerRadius: 22))
    }
}

/// Couleurs d'état sourdes (jamais criardes).
extension Color {
    static let positif = Color(red: 0.49, green: 0.79, blue: 0.64)
    static let negatif = Color(red: 0.91, green: 0.58, blue: 0.56)
    static let alerte = Color(red: 0.85, green: 0.71, blue: 0.45)
    static func etat(_ e: Suivi.Etat) -> Color { e == .depasse ? .negatif : e == .alerte ? .alerte : .primary }
}

/// Une ligne d'opération (Activité, groupes, prélèvements).
struct LigneOperation: View {
    let op: Operation
    let magasin: Magasin
    var body: some View {
        HStack(spacing: 12) {
            Tuile(sc: op.sc)
            VStack(alignment: .leading, spacing: 2) {
                Text(op.note.isEmpty ? op.sc : op.note).lineLimit(1)
                HStack(spacing: 4) {
                    if op.partage != nil { Text("Partagé").badge() }
                    if op.source == "auto" { Text("Auto").badge() }
                    if op.statut == "a_verifier" { Text("À vérifier").badge(.alerte) }
                    Text(sousTitre).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(montant.texte).monospacedDigit().fontWeight(.semibold).foregroundStyle(montant.couleur)
        }
        .padding(.vertical, 2)
        // Toute la ligne réagit au toucher, pas seulement le texte (sinon l'espace vide au milieu ne fait rien)
        .contentShape(Rectangle())
    }
    private var sousTitre: String {
        op.cat == .virement ? "\(magasin.nomCompte(op.compte)) → \(magasin.nomCompte(op.vers))" : op.sc + (op.compte.isEmpty ? "" : " · " + magasin.nomCompte(op.compte))
    }
    private var montant: (texte: String, couleur: Color) {
        switch op.cat {
        case .virement:
            if op.vers == "" { return (Fmt.eur(op.montant, signe: true), .positif) }
            if op.compte.isEmpty { return (Fmt.eur(-op.montant, signe: true), .primary) }
            return (Fmt.eur(op.montant), .secondary)
        case .revenu: return (Fmt.eur(op.montant, signe: true), Ref.mouvementsEpargne.contains(op.sc) ? .secondary : .positif)
        case .epargne: return (Fmt.eur(-op.montant, signe: true), .secondary)
        default: return (Fmt.eur(-op.montant, signe: true), .primary)
        }
    }
}

extension Text {
    func badge(_ couleur: Color = .secondary) -> some View {
        self.font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
            .background(couleur.opacity(0.18), in: Capsule()).foregroundStyle(couleur)
    }
}

/// Fond d'écran commun : le dégradé qui dérive, sous un contenu défilant.
/// Grand chiffre (montant principal d'un écran) : sa taille suit le réglage « Taille du texte » de l'iPhone
/// (@ScaledMetric, comme le recommande Apple) et rétrécit plutôt que de déborder.
struct GrandChiffre: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var taille: CGFloat = 40
    let poids: Font.Weight
    let design: Font.Design
    init(_ taille: CGFloat, poids: Font.Weight, design: Font.Design) { _taille = ScaledMetric(wrappedValue: taille, relativeTo: .largeTitle); self.poids = poids; self.design = design }
    func body(content: Content) -> some View {
        content.font(.system(size: taille, weight: poids, design: design)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
    }
}

extension View {
    func grandChiffre(_ taille: CGFloat, poids: Font.Weight = .bold, design: Font.Design = .rounded) -> some View {
        modifier(GrandChiffre(taille, poids: poids, design: design))
    }
}

struct Ecran<Contenu: View>: View {
    @ViewBuilder let contenu: Contenu
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { contenu }
                .padding(.horizontal, 16).padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(FondView())
    }
}


/// Verre liquide dont l'opacité se règle (Le Cercle › Opacité du verre) : 0 = verre « clear » d'Apple, transparent ;
/// 100 = presque dépoli (matière floue et voile blanc ajoutés sous le verre).
struct VerreReglable<S: Shape>: ViewModifier {
    let glass: Glass
    let forme: S
    func body(content: Content) -> some View {
        content.glassEffect(glass, in: forme)
    }
}

/// Surface des cartes de contenu (revue du 09/11) : sombre et presque opaque, lisible sur n'importe quel fond.
/// Apple réserve le verre liquide aux commandes (onglets, boutons, sélecteurs) ; le contenu se pose sur une surface.
struct Surface<S: Shape>: ViewModifier {
    let forme: S
    static let carte = Color(red: 0x1F / 255, green: 0x25 / 255, blue: 0x2B / 255)   // cartes du site
    func body(content: Content) -> some View {
        content
            .background { forme.fill(Self.carte.opacity(0.94)) }
            .overlay { forme.stroke(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.6) }
            .contentShape(forme)
    }
}

extension View {
    func surface<S: Shape>(in forme: S) -> some View { modifier(Surface(forme: forme)) }
    func verre<S: Shape>(_ glass: Glass, in forme: S) -> some View { modifier(VerreReglable(glass: glass, forme: forme)) }
}
