import SwiftUI

/// Les 5 catégories du site (colonne `categorie` de la table operations).
enum Cat: String, Codable, CaseIterable {
    case revenu = "Revenu"
    case besoins = "50% - Besoins"
    case envies = "30% - Envies"
    case epargne = "20% - Épargne"
    case virement = "Virement"

    var court: String {
        switch self {
        case .revenu: "Revenus"
        case .besoins: "Besoins"
        case .envies: "Envies"
        case .epargne: "Épargne"
        case .virement: "Virements"
        }
    }
    var estDepense: Bool { self == .besoins || self == .envies }
}

/// Un thème (colonne `sous_categorie`) : sa catégorie 50-30-20, son symbole Apple, un libellé court, une teinte sourde.
struct Theme {
    let nom: String
    let cat: Cat
    let symbole: String
    let court: String
    let teinte: Color
}

/// Référentiel repris du site (`app.py`) et du prototype.
enum Ref {
    private static func c(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let themes: [Theme] = [
        Theme(nom: "Salaire", cat: .revenu, symbole: "briefcase", court: "Salaire", teinte: c(0x7FA6C9)),
        Theme(nom: "Bourse & aides", cat: .revenu, symbole: "graduationcap", court: "Aides", teinte: c(0x8C8FD0)),
        Theme(nom: "Aide familiale", cat: .revenu, symbole: "figure.2.and.child.holdinghands", court: "Famille", teinte: c(0xA58BC0)),
        Theme(nom: "Job / freelance", cat: .revenu, symbole: "laptopcomputer", court: "Job", teinte: c(0x6FB0AC)),
        Theme(nom: "Cadeau reçu", cat: .revenu, symbole: "gift", court: "Cadeau", teinte: c(0xC49A7A)),
        Theme(nom: "Remboursement", cat: .revenu, symbole: "arrow.uturn.backward", court: "Rembours.", teinte: c(0x8FB09A)),
        Theme(nom: "Remboursement loyer", cat: .revenu, symbole: "house", court: "Loyer coloc", teinte: c(0x8FA2B8)),
        Theme(nom: "Gains de jeux", cat: .revenu, symbole: "dice", court: "Gains jeux", teinte: c(0xB99A6A)),
        Theme(nom: "Dépôt espèces", cat: .revenu, symbole: "banknote", court: "Dépôt cash", teinte: c(0x9AAE88)),
        Theme(nom: "Intérêts & primes", cat: .revenu, symbole: "percent", court: "Intérêts", teinte: c(0x7FB3A0)),
        Theme(nom: "Autre revenu", cat: .revenu, symbole: "plus.circle", court: "Autre", teinte: c(0x9AA3AE)),
        Theme(nom: "Retrait d'épargne", cat: .revenu, symbole: "arrow.up.bin", court: "Retrait", teinte: c(0x7FB3A0)),
        Theme(nom: "Vente placement", cat: .revenu, symbole: "chart.line.downtrend.xyaxis", court: "Vente", teinte: c(0x7FB3A0)),
        Theme(nom: "Loyer", cat: .besoins, symbole: "house", court: "Loyer", teinte: c(0x7F9CC2)),
        Theme(nom: "Courses", cat: .besoins, symbole: "cart", court: "Courses", teinte: c(0x6FA9A4)),
        Theme(nom: "Transport", cat: .besoins, symbole: "tram", court: "Transport", teinte: c(0x8F92CC)),
        Theme(nom: "Voiture", cat: .besoins, symbole: "car", court: "Voiture", teinte: c(0x8696A8)),
        Theme(nom: "Factures", cat: .besoins, symbole: "bolt", court: "Factures", teinte: c(0xB8A06E)),
        Theme(nom: "Santé", cat: .besoins, symbole: "cross.case", court: "Santé", teinte: c(0xC48A8A)),
        Theme(nom: "Assurances", cat: .besoins, symbole: "shield", court: "Assurances", teinte: c(0x8AA0B0)),
        Theme(nom: "Études", cat: .besoins, symbole: "book", court: "Études", teinte: c(0x9C94C4)),
        Theme(nom: "Frais bancaires", cat: .besoins, symbole: "building.columns", court: "Frais banque", teinte: c(0x98A0A8)),
        Theme(nom: "Autre besoin", cat: .besoins, symbole: "shippingbox", court: "Autre", teinte: c(0x9AA3AE)),
        Theme(nom: "Restos & sorties", cat: .envies, symbole: "fork.knife", court: "Restos", teinte: c(0xC29A6E)),
        Theme(nom: "Shopping", cat: .envies, symbole: "bag", court: "Shopping", teinte: c(0xB48AAE)),
        Theme(nom: "Loisirs", cat: .envies, symbole: "gamecontroller", court: "Loisirs", teinte: c(0x7FAFC4)),
        Theme(nom: "Voyages", cat: .envies, symbole: "airplane", court: "Voyages", teinte: c(0x6FA0B8)),
        Theme(nom: "Abonnements", cat: .envies, symbole: "repeat", court: "Abos", teinte: c(0x9E8FC8)),
        Theme(nom: "Cadeaux offerts", cat: .envies, symbole: "gift", court: "Cadeaux", teinte: c(0xC4908A)),
        Theme(nom: "Jeux d'argent", cat: .envies, symbole: "dice", court: "Jeux", teinte: c(0xB0946A)),
        Theme(nom: "Espèces", cat: .envies, symbole: "banknote", court: "Espèces", teinte: c(0x9AAE88)),
        Theme(nom: "Autre envie", cat: .envies, symbole: "sparkles", court: "Autre", teinte: c(0xA8A08E)),
        Theme(nom: "Livret", cat: .epargne, symbole: "banknote.fill", court: "Livret", teinte: c(0x7FB3A0)),
        Theme(nom: "Investissement", cat: .epargne, symbole: "chart.line.uptrend.xyaxis", court: "Placement", teinte: c(0x6FA9B8)),
        Theme(nom: "Projet", cat: .epargne, symbole: "flag", court: "Projet", teinte: c(0xA8A0C8)),
        Theme(nom: "Autre épargne", cat: .epargne, symbole: "wallet.bifold", court: "Autre", teinte: c(0x9AB0A0)),
        Theme(nom: "Virement interne", cat: .virement, symbole: "arrow.left.arrow.right", court: "Virement", teinte: c(0x9AA3AE)),
    ]
    static let parNom: [String: Theme] = Dictionary(uniqueKeysWithValues: themes.map { ($0.nom, $0) })
    static func theme(_ nom: String) -> Theme {
        parNom[nom] ?? Theme(nom: nom, cat: .envies, symbole: "circle", court: nom, teinte: .gray)
    }

    /// Entrées qui réduisent une sortie au lieu de compter comme un revenu (règle 6 du site et suivantes).
    static let compensations: [String: (String, Cat)] = [
        "Remboursement loyer": ("Loyer", .besoins),
        "Gains de jeux": ("Jeux d'argent", .envies),
        "Dépôt espèces": ("Espèces", .envies),
        "Retrait d'épargne": ("Livret", .epargne),
        "Vente placement": ("Investissement", .epargne),
    ]
    static let revenusReference: Set<String> = ["Salaire", "Bourse & aides", "Aide familiale"]   // règle 7
    static let chargesFixes: Set<String> = ["Loyer", "Factures", "Assurances", "Abonnements", "Frais bancaires"]
    static let mouvementsEpargne: Set<String> = ["Livret", "Investissement", "Projet", "Autre épargne", "Retrait d'épargne", "Vente placement"]
    static let seuilExceptionnel = 1000.0
    static let cibles: [Cat: Double] = [.besoins: 50, .envies: 30, .epargne: 20]
    static let tolerance = 5.0
    static let joursParMois = 30.44
    static let supports = ["Livret", "Projet", "Investissement", "Autre épargne"]

    /// Taux de démonstration (l'app ira chercher le taux du jour plus tard).
    static let devises: [(code: String, symbole: String, taux: Double)] = [
        ("EUR", "€", 1), ("USD", "$", 0.92), ("GBP", "£", 1.17), ("CHF", "CHF", 1.05), ("JPY", "¥", 0.0061),
    ]

    /// Types proposés dans la feuille de saisie.
    enum TypeSaisie: String, CaseIterable, Identifiable {
        case depense = "Dépense", revenu = "Revenu", epargne = "Épargne", virement = "Virement"
        var id: String { rawValue }
        var themes: [Theme] {
            Ref.themes.filter { t in
                switch self {
                case .depense: t.cat.estDepense
                case .revenu: t.cat == .revenu && !Ref.mouvementsEpargne.contains(t.nom)
                case .epargne: t.cat == .epargne || (t.cat == .revenu && Ref.mouvementsEpargne.contains(t.nom))
                case .virement: false
                }
            }
        }
    }
}
