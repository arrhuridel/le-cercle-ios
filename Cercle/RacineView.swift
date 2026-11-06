import SwiftUI
import LocalAuthentication

/// Les onglets. « ajouter » n'est pas un vrai écran : le toucher ouvre la feuille de saisie.
enum Onglet: Hashable {
    case resume, analyses, activite, cercle, ajouter
}

/// Racine : connexion, puis la barre d'onglets en verre liquide d'iOS 26 avec le « + » rond séparé.
struct RacineView: View {
    @Environment(Magasin.self) private var magasin
    @Environment(\.scenePhase) private var phase
    @AppStorage("faceId") private var faceId = false
    @AppStorage("theme") private var theme = "sombre"
    @State private var onglet: Onglet = .resume
    @State private var saisieOuverte = false
    @State private var verrouille = false

    var body: some View {
        Group {
            switch magasin.etat {
            case .demarrage: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(FondView())
            case .deconnecte: ConnexionView()
            case .demo, .connecte: onglets
            }
        }
        .preferredColorScheme(theme == "clair" ? .light : theme == "auto" ? nil : .dark)
        .overlay { if verrouille { verrou } }
        .task { await magasin.demarrer(); if faceId { verrouille = true; deverrouiller() } }
        .onChange(of: phase) { _, p in
            if p == .background && faceId { verrouille = true }
            if p == .active && verrouille { deverrouiller() }
        }
    }

    private var onglets: some View {
        TabView(selection: $onglet) {
            Tab("Résumé", systemImage: "chart.pie", value: Onglet.resume) { ResumeView() }
            Tab("Analyses", systemImage: "chart.bar", value: Onglet.analyses) { AnalysesView() }
            Tab("Activité", systemImage: "list.bullet", value: Onglet.activite) { ActiviteView() }
            Tab("Cercle", systemImage: "person.2", value: Onglet.cercle) { CercleView() }
            // Le rôle « search » place cet onglet à part, dans un bouton rond en verre : c'est notre « + ».
            // Il n'affiche rien : on revient aussitôt à l'onglet précédent et on ouvre la feuille de saisie.
            Tab("Ajouter", systemImage: "plus", value: Onglet.ajouter, role: .search) { Color.clear }
        }
        .tint(.primary)   // sélection neutre, jamais bleue
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: onglet) { ancien, nouveau in
            if nouveau == .ajouter { onglet = ancien; saisieOuverte = true }
        }
        .sensoryFeedback(.selection, trigger: onglet)
        .sheet(isPresented: $saisieOuverte) { SaisieView() }
    }

    /// Écran de verrouillage : flou, Face ID (ou le code de l'iPhone en secours).
    private var verrou: some View {
        VStack(spacing: 18) {
            Image(systemName: "faceid").font(.system(size: 44, weight: .light)).frame(width: 86, height: 86).glassEffect(.regular, in: .rect(cornerRadius: 26))
            Text("Le Cercle est verrouillé").font(.title2.weight(.semibold))
            Button("Déverrouiller") { deverrouiller() }
                .font(.headline).padding(.horizontal, 40).padding(.vertical, 14).glassEffect(.regular.interactive(), in: .capsule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func deverrouiller() {
        let c = LAContext()
        c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Déverrouiller Le Cercle") { ok, _ in
            Task { @MainActor in if ok { withAnimation { verrouille = false } } }
        }
    }
}

/// Connexion avec le compte Supabase (le même e-mail que celui relié à ton profil du site).
struct ConnexionView: View {
    @Environment(Magasin.self) private var magasin
    @State private var email = ""
    @State private var motDePasse = ""

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "chart.pie").font(.system(size: 44, weight: .light)).frame(width: 92, height: 92).glassEffect(.regular, in: .rect(cornerRadius: 26))
            Text("Le Cercle").font(.largeTitle.weight(.bold))
            Text("Ton budget, tes analyses et tes comptes partagés.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 10) {
                TextField("E-mail", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 16))
                SecureField("Mot de passe", text: $motDePasse).textContentType(.password)
                    .padding(14).glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
            .padding(.top, 10)
            if let e = magasin.erreur { Text(e).font(.footnote).foregroundStyle(Color.alerte).multilineTextAlignment(.center) }
            if !magasin.configure {
                Text("Cette version n'a pas l'adresse de ta base : ajoute les secrets SUPABASE_URL et SUPABASE_PUBLISHABLE_KEY dans GitHub, puis refabrique l'app.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button {
                Task { await magasin.connecter(email: email, motDePasse: motDePasse) }
            } label: {
                Group { if magasin.chargement { ProgressView() } else { Text("Se connecter").font(.headline) } }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .disabled(email.isEmpty || motDePasse.isEmpty || !magasin.configure)
            Spacer()
            Button("Essayer avec des données d'exemple") { magasin.ouvrirDemo() }.font(.subheadline).tint(.secondary)
        }
        .padding(24)
        .background(FondView())
    }
}
