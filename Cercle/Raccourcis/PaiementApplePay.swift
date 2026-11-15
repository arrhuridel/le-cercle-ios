import AppIntents
import Foundation
import Supabase

/// « Paiement Apple Pay » : appelé par l'automatisation Raccourcis « Transaction » (à chaque paiement Apple Pay).
/// Reçoit le montant, le commerçant et la carte ; classe la dépense (tes règles, ton historique, puis les règles générales)
/// et l'enregistre dans la base SANS ouvrir l'app. La synchro bancaire la reconnaîtra ensuite (même compte, même montant,
/// à 4 jours près) : pas de doublon.
struct PaiementApplePayIntent: AppIntent {
    static let title: LocalizedStringResource = "Paiement Apple Pay"
    static let description = IntentDescription("Enregistre un paiement Apple Pay dans Le Cercle, déjà classé, sans ouvrir l'app.")
    static let openAppWhenRun = false

    @Parameter(title: "Montant", description: "Le montant du paiement (Transaction › Montant)")
    var montant: Double

    @Parameter(title: "Commerçant", description: "Transaction › Commerçant")
    var commercant: String

    @Parameter(title: "Carte", description: "Transaction › Carte ou titre (sert à trouver le compte)")
    var carte: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Enregistrer \(\.$montant) € chez \(\.$commercant)") { \.$carte }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let m = (abs(montant) * 100).rounded() / 100
        guard m > 0 else { throw AjoutRapide.Erreur(message: "Paiement à 0 € : rien à enregistrer.") }
        let nom = commercant.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = try await AjoutRapide.enregistrerPaiement(commercant: nom, montant: m, compte: ApplePay.compte(carte ?? ""))
        return .result(dialog: "\(Partage.eur(m, decimales: 2)) chez \(r.note) : \(r.sc).")
    }
}

enum ApplePay {
    /// Le compte du Cercle d'après le nom de la carte dans Wallet (« Revolut », « Carte BoursoBank »…). Par défaut : compte courant.
    static func compte(_ carte: String) -> String {
        let c = carte.lowercased()
        if c.contains("revolut") { return "Revolut" }
        if c.contains("bourso") { return "Boursobank" }
        if c.contains("trade") { return "Trade Republic" }
        return ""
    }
}

extension AjoutRapide {
    /// Classe et enregistre un paiement : tes règles et ton historique d'abord (ex. « Burger King » → Restos & sorties).
    static func enregistrerPaiement(commercant: String, montant: Double, compte: String) async throws -> (sc: String, note: String) {
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
            // Les 400 dernières opérations suffisent pour reconnaître un commerçant déjà vu
            let historique: [Operation] = (try? await client.from("operations").select(Operation.colonnes).eq("profil_id", value: p.id)
                .order("date_operation", ascending: false).limit(400).execute().value) ?? []
            var regles: [Import.Regle] = []
            if let d = UserDefaults.standard.data(forKey: "regles"), let lues = try? JSONDecoder().decode([Import.Regle].self, from: d) { regles = lues }
            let choix = Import.proposer(commercant.isEmpty ? "Paiement Apple Pay" : commercant, -montant, regles: regles, historique: historique.reversed())
            let note = commercant.isEmpty ? choix.note : Import.joli(commercant)
            let o = Operation(id: UUID().uuidString.lowercased(), date: J.auj, profilId: p.id, cat: Ref.theme(choix.sc).cat, sc: choix.sc,
                              montant: montant, note: note, compte: compte, vers: nil, source: "auto", statut: "validee", devise: nil, montantDevise: nil)
            try await client.from("operations").insert(o).execute()
            return (choix.sc, note)
        } catch let e as Erreur {
            throw e
        } catch {
            throw Erreur(message: (error as? URLError) != nil ? "Pas de réseau : le paiement n'est pas enregistré." : "La base a refusé l'enregistrement.")
        }
    }
}
