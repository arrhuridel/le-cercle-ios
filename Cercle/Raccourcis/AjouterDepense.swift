import AppIntents
import Foundation
import Supabase
import WidgetKit

/// Raccourci « Ajouter une dépense » : montant, catégorie et note demandés dans une petite fenêtre système,
/// puis enregistrés dans la base SANS ouvrir l'app. À brancher sur « Toucher le dos » (Réglages › Accessibilité › Toucher),
/// le bouton Action ou le Centre de contrôle.
struct AjouterDepenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Ajouter une dépense"
    static let description = IntentDescription("Enregistre une dépense dans Le Cercle sans ouvrir l'app.")
    static let openAppWhenRun = false

    @Parameter(title: "Montant", description: "En euros")
    var montant: Double

    @Parameter(title: "Catégorie")
    var categorie: CategorieDepense

    @Parameter(title: "Note", description: "Facultatif : Lidl, cinéma…")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Ajouter \(\.$montant) € en \(\.$categorie)") { \.$note }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = (montant * 100).rounded() / 100
        guard m > 0 else { throw AjoutRapide.Erreur(message: "Indique un montant supérieur à zéro.") }
        try await AjoutRapide.enregistrer(sc: categorie.sousCategorie, montant: m, note: note?.trimmingCharacters(in: .whitespaces) ?? "")
        // Les widgets suivent tout de suite, sans attendre l'ouverture de l'app
        if var d = Partage.lire() {
            d.solde -= m
            d.finMois -= m
            d.parJour = (d.parJour * Double(max(d.joursRestants, 1)) - m) / Double(max(d.joursRestants, 1))
            d.misAJour = Date()
            Partage.ecrire(d)
            WidgetCenter.shared.reloadAllTimelines()
        }
        return .result(dialog: "\(Partage.eur(m, decimales: m.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2)) en \(categorie.sousCategorie) : c'est enregistré.")
    }
}

/// Les catégories de dépense proposées dans la fenêtre (les plus utilisées d'abord).
enum CategorieDepense: String, AppEnum {
    case courses, restos, transport, shopping, loisirs, autreEnvie, jeux, especes, sante, voiture, cadeaux, voyages, abonnements, factures, autreBesoin

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Catégorie"
    static let caseDisplayRepresentations: [CategorieDepense: DisplayRepresentation] = [
        .courses: "Courses", .restos: "Restos & sorties", .transport: "Transport", .shopping: "Shopping", .loisirs: "Loisirs",
        .autreEnvie: "Autre envie", .jeux: "Jeux d'argent", .especes: "Espèces", .sante: "Santé", .voiture: "Voiture",
        .cadeaux: "Cadeaux offerts", .voyages: "Voyages", .abonnements: "Abonnements", .factures: "Factures", .autreBesoin: "Autre besoin",
    ]

    /// Nom de la sous-catégorie dans la base (le même que sur le site).
    var sousCategorie: String {
        switch self {
        case .courses: "Courses"
        case .restos: "Restos & sorties"
        case .transport: "Transport"
        case .shopping: "Shopping"
        case .loisirs: "Loisirs"
        case .autreEnvie: "Autre envie"
        case .jeux: "Jeux d'argent"
        case .especes: "Espèces"
        case .sante: "Santé"
        case .voiture: "Voiture"
        case .cadeaux: "Cadeaux offerts"
        case .voyages: "Voyages"
        case .abonnements: "Abonnements"
        case .factures: "Factures"
        case .autreBesoin: "Autre besoin"
        }
    }
}

/// Le raccourci apparaît tout seul dans l'app Raccourcis, et donc dans « Toucher le dos ».
struct RaccourcisCercle: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AjouterDepenseIntent(),
                    phrases: ["Ajouter une dépense dans \(.applicationName)", "Nouvelle dépense \(.applicationName)"],
                    shortTitle: "Ajouter une dépense", systemImageName: "plus.circle")
    }
}

/// Écriture directe dans la base, avec la session déjà ouverte dans l'app (aucun mot de passe redemandé).
enum AjoutRapide {
    struct Erreur: Error, CustomLocalizedStringResourceConvertible {
        let message: String
        var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
    }

    static func enregistrer(sc: String, montant: Double, note: String) async throws {
        let url = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String ?? ""
        let cle = Bundle.main.object(forInfoDictionaryKey: "SupabaseKey") as? String ?? ""
        guard let u = URL(string: url), u.scheme == "https", !cle.isEmpty else {
            throw Erreur(message: "Cette version de l'app n'a pas l'adresse de ta base.")
        }
        let client = SupabaseClient(supabaseURL: u, supabaseKey: cle)
        do { _ = try await client.auth.session } catch {
            throw Erreur(message: "Ouvre Le Cercle et connecte-toi une fois, puis réessaie.")
        }
        do {
            let profils: [Profil] = try await client.from("profils").select(Profil.colonnes).limit(1).execute().value
            guard let p = profils.first else { throw Erreur(message: "Profil introuvable dans la base.") }
            let o = Operation(id: UUID().uuidString.lowercased(), date: J.auj, profilId: p.id, cat: Ref.theme(sc).cat, sc: sc,
                              montant: montant, note: note, compte: "", vers: nil, source: "saisie", statut: "validee", devise: nil, montantDevise: nil)
            try await client.from("operations").insert(o).execute()
        } catch let e as Erreur {
            throw e
        } catch {
            throw Erreur(message: (error as? URLError) != nil ? "Pas de réseau : la dépense n'est pas enregistrée." : "La base a refusé l'enregistrement.")
        }
    }
}
