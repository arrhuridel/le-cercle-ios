import Foundation

/// Chiffres partagés entre l'app et ses widgets (même fichier dans les deux cibles).
/// L'app les écrit après chaque mise à jour ; les widgets les lisent. Aucun calcul ici, aucune donnée bancaire détaillée :
/// seulement ce que les widgets affichent.
enum Partage {
    /// Espace partagé entre l'app et les widgets (App Group). Il doit figurer dans les droits des deux cibles.
    static let groupe = "group.fr.lecercle.app"
    private static let cle = "widget.donnees"

    struct Donnees: Codable, Hashable {
        var solde: Double            // compte courant, comme la banque
        var parJour: Double          // ce que tu peux dépenser par jour, prélèvements à venir déduits
        var joursRestants: Int
        var finMois: Double          // estimation au dernier jour du cycle
        var finTexte: String         // « 26 nov. »
        var part: Double             // part de l'argent du mois déjà sortie (0 à 100)
        var besoins: Double, envies: Double, epargne: Double   // en % du salaire + CAF
        var prochains: [Prochain]
        var misAJour: Date

        struct Prochain: Codable, Hashable {
            var nom: String
            var montant: Double
            var date: String         // « 11 nov. »
        }

        /// Aperçu dans la galerie des widgets (chiffres inventés).
        static let exemple = Donnees(solde: 512, parJour: 19, joursRestants: 19, finMois: 42, finTexte: "26 nov.", part: 62,
                                     besoins: 41, envies: 12, epargne: 22,
                                     prochains: [.init(nom: "Abonnement", montant: 6.99, date: "11 nov."), .init(nom: "Salle de sport", montant: 29.9, date: "12 nov."),
                                                 .init(nom: "Forfait mobile", montant: 13.99, date: "12 nov.")],
                                     misAJour: Date())
    }

    static var espace: UserDefaults? { UserDefaults(suiteName: groupe) }

    static func lire() -> Donnees? {
        guard let d = espace?.data(forKey: cle) else { return nil }
        return try? JSONDecoder().decode(Donnees.self, from: d)
    }

    static func ecrire(_ d: Donnees) {
        guard let data = try? JSONEncoder().encode(d) else { return }
        espace?.set(data, forKey: cle)
    }

    /// « 1 234 € » ou « 6,99 € » (format français, sans dépendre du code de l'app).
    static func eur(_ v: Double, decimales: Int = 0) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR"); f.numberStyle = .decimal
        f.minimumFractionDigits = decimales; f.maximumFractionDigits = decimales
        return (f.string(from: NSNumber(value: v)) ?? "\(v)") + " €"
    }
}
