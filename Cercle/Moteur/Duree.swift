import SwiftUI

/// Durée regardée dans les rubriques : 6 mois, 12 mois ou depuis toujours. Gardée d'une rubrique à l'autre.
enum Duree: String, CaseIterable, Identifiable {
    case six = "6", douze = "12", tout = "tout"
    var id: String { rawValue }
    var titre: String {
        switch self {
        case .six: return "6 mois"
        case .douze: return "12 mois"
        case .tout: return "Toujours"
        }
    }
    var texte: String { self == .tout ? "depuis le début" : "sur \(rawValue) mois" }
    /// Clé commune de stockage (AppStorage) pour toutes les rubriques.
    static let cle = "dureeRubrique"

    /// Une tranche de graphique : un mois (6 ou 12 mois) ou une année (depuis toujours).
    struct Tranche: Identifiable, Hashable {
        var cle: String, libelle: String, debut: String, fin: String
        var id: String { cle }
    }

    func debut(_ ops: [Operation]) -> String {
        switch self {
        case .tout: return ops.lazy.map(\.date).min() ?? J.auj
        case .six: return Calc.moisDerniers(6).first!.debut
        case .douze: return Calc.moisDerniers(12).first!.debut
        }
    }
    /// Nombre de mois couverts (pour les moyennes « par mois »).
    func nbMois(_ ops: [Operation]) -> Double { max(Double(J.ecart(debut(ops), J.auj) + 1) / Ref.joursParMois, 1) }
    /// Nombre de mois calendaires couverts, mois en cours compris.
    func moisEntiers(_ ops: [Operation]) -> Int {
        let a = J.comp(J.date(debut(ops))), b = J.comp(J.aujourdhui)
        return max((b.a - a.a) * 12 + b.m - a.m + 1, 1)
    }
    func tranches(_ ops: [Operation]) -> [Tranche] {
        switch self {
        case .tout:
            let a1 = J.comp(J.aujourdhui).a, a0 = min(Int(debut(ops).prefix(4)) ?? a1, a1)
            return (a0...a1).map { a in Tranche(cle: "\(a)", libelle: "\(a)", debut: "\(a)-01-01", fin: min("\(a)-12-31", J.auj)) }
        default:
            return Calc.moisDerniers(self == .six ? 6 : 12).map { Tranche(cle: $0.cle, libelle: $0.libelle, debut: $0.debut, fin: $0.fin) }
        }
    }
    func bilans(_ ops: [Operation]) -> [(t: Tranche, b: Calc.Bilan)] {
        tranches(ops).map { ($0, Calc.bilan(Calc.entre(ops, $0.debut, $0.fin))) }
    }
}

/// Le sélecteur 6 mois / 12 mois / Toujours, en haut des rubriques.
struct SelecteurDuree: View {
    @AppStorage(Duree.cle) private var duree: Duree = .douze
    var body: some View {
        Picker("Durée", selection: $duree) {
            ForEach(Duree.allCases) { Text($0.titre).tag($0) }
        }
        .pickerStyle(.segmented)
        .sensoryFeedback(.selection, trigger: duree)
    }
}
