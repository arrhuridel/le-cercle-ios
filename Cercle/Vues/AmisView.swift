import SwiftUI

/// Amis (parties 7 et 9, 18/11/2026) : inviter quelqu'un (code d'invitation, base v20), échanger un code d'ami avec un membre
/// déjà inscrit (base v22). Les réponses du questionnaire se modifient sur la web app (même compte).
struct AmisView: View {
    @Environment(Magasin.self) private var magasin
    @State private var invitation: String?
    @State private var codeAmi: String?
    @State private var saisie = ""
    @State private var message: String?
    @State private var enCours = false
    private let site = "https://le-cercle-rvon.onrender.com"

    var body: some View {
        Ecran {
            TitreSection(texte: "Amis")
            CarteVerre(espacement: 10) {
                Text("Inviter un ami").font(.headline)
                Text("Un code par personne, valable 14 jours, une seule fois. Ton ami crée son compte sur la web app avec ce lien.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let c = invitation, let url = URL(string: "\(site)/?code=\(c)") {
                    Text(c).font(.title2.weight(.bold).monospaced())
                    ShareLink("Partager le lien d'invitation", item: url, message: Text("Rejoins-moi sur Le Cercle. Ton code d'invitation : \(c)"))
                } else {
                    Button("Créer une invitation") { Task { invitation = await appel("creer_invitation") } }.disabled(enCours)
                }
            }
            CarteVerre(espacement: 10) {
                Text("Ajouter un ami déjà inscrit").font(.headline)
                Text("Donne-lui ton code, ou saisis le sien : vous vous verrez dans Le Cercle (selon ce que chacun partage).")
                    .font(.footnote).foregroundStyle(.secondary)
                if let c = codeAmi {
                    Text(c).font(.title2.weight(.bold).monospaced())
                    ShareLink("Partager mon code", item: "Mon code d'ami sur Le Cercle : \(c)")
                } else {
                    Button("Créer mon code d'ami") { Task { codeAmi = await appel("creer_code_ami") } }.disabled(enCours)
                }
                HStack {
                    TextField("Code d'un ami", text: $saisie).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Ajouter") {
                        Task {
                            if let prenom = await appel("ajouter_ami", ["code": saisie]) {
                                message = "\(prenom) est maintenant ton ami."; saisie = ""
                                await magasin.rafraichir()
                            }
                        }
                    }
                    .disabled(enCours || saisie.trimmingCharacters(in: .whitespaces).count < 8)
                }
            }
            CarteVerre(espacement: 10) {
                Text("Mes réponses").font(.headline)
                Text("Situation, revenus, logement, banques, règle de budget, objectif : à modifier sur la web app, avec le même compte. Les calculs de l'app suivent tes réponses.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let url = URL(string: site) { Link("Ouvrir la web app", destination: url) }
            }
            .tint(.primary)
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .navigationTitle("Amis")
    }

    /// Appelle une fonction de la base ; en cas de refus, affiche son message et renvoie nil.
    private func appel(_ nom: String, _ params: [String: String] = [:]) async -> String? {
        enCours = true; defer { enCours = false }
        let r = await magasin.appelTexte(nom, params)
        message = r.erreur
        return r.texte
    }
}
