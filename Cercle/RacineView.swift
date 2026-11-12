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
    @State private var onglet: Onglet = .resume
    @State private var saisieOuverte = false
    @State private var verrouille = false
    @State private var authEnCours = false     // une seule demande Face ID à la fois
    @State private var revenuDuFond = false    // on ne redemande Face ID tout seul qu'en revenant de l'arrière-plan

    var body: some View {
        Group {
            switch magasin.etat {
            case .demarrage: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(FondView())
            case .deconnecte: ConnexionView()
            case .demo, .connecte:
                // Première connexion : rien à montrer tant que la base n'a pas répondu (jamais d'écran à 0 €)
                if magasin.etat == .connecte && magasin.profil == nil && magasin.chargement { premierChargement } else { onglets }
            }
        }
        // Le fond de l'app est toujours sombre : le mode clair rendrait le texte illisible
        .preferredColorScheme(.dark)
        // Liens des widgets : lecercle://ajouter ouvre la saisie, lecercle://reste revient au Résumé
        .onOpenURL { url in
            switch url.host {
            case "ajouter": saisieOuverte = true
            default: onglet = .resume
            }
        }
        // Verrou, et cache dans le sélecteur d'apps (état « inactif ») pour que les montants ne s'y voient pas
        .overlay { if verrouille || (faceId && phase != .active && !authEnCours) { verrou } }
        .task {
            if faceId { verrouille = true }          // verrouillé AVANT d'afficher les données
            await magasin.demarrer()
            if faceId { deverrouiller() }
        }
        .onChange(of: phase) { _, p in
            if p == .background && faceId { verrouille = true; revenuDuFond = true }
            // La fenêtre Face ID rend l'app « inactive » puis « active » : sans ce drapeau, un refus relancerait Face ID en boucle
            if p == .active && verrouille && revenuDuFond { revenuDuFond = false; deverrouiller() }
            // En revenant dans l'app : on relit la base (une dépense ajoutée par le raccourci ou sur le site apparaît tout de suite)
            // (seulement si la dernière lecture a plus d'une minute : pas de rechargement à chaque aller-retour)
            if p == .active && magasin.etat == .connecte { Task { await magasin.rafraichirSiAncien() } }
        }
    }

    private var onglets: some View {
        TabView(selection: $onglet) {
            Tab("Résumé", systemImage: "chart.pie", value: Onglet.resume) { AccueilView() }
            Tab("Analyses", systemImage: "chart.bar", value: Onglet.analyses) { AnalysesView() }
            Tab("Comptes", systemImage: "building.columns", value: Onglet.activite) { ComptesView() }
            Tab("Cercle", systemImage: "person.2", value: Onglet.cercle) { CercleView() }
            // Le rôle « search » place cet onglet à part, dans un bouton rond en verre : c'est notre « + ».
            // On revient aussitôt à l'onglet précédent et on ouvre la feuille de saisie ; le même fond évite un éclair vide.
            Tab("Ajouter", systemImage: "plus", value: Onglet.ajouter, role: .search) { FondView() }
        }
        .tint(.primary)   // sélection neutre, jamais bleue
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: onglet) { ancien, nouveau in
            if nouveau == .ajouter { onglet = ancien; saisieOuverte = true }
        }
        // Une seule vibration par changement d'onglet (l'aller-retour du « + » n'en déclenche pas deux)
        .sensoryFeedback(trigger: onglet) { ancien, nouveau in
            ancien == .ajouter || nouveau == .ajouter ? nil : .selection
        }
        .sensoryFeedback(.impact(weight: .light), trigger: saisieOuverte) { _, ouverte in ouverte }
        .sheet(isPresented: $saisieOuverte) { SaisieView() }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// Attente de la première lecture de la base, juste après la connexion.
    private var premierChargement: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Chargement de tes comptes…").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FondView())
    }

    /// Écran de verrouillage : flou, Face ID (ou le code de l'iPhone en secours).
    private var verrou: some View {
        VStack(spacing: 18) {
            Image(systemName: "faceid").font(.system(size: 44, weight: .light)).frame(width: 86, height: 86).verre(.regular, in: .rect(cornerRadius: 24))
            Text("Le Cercle est verrouillé").font(.title2.weight(.semibold))
            if verrouille {
                Button { deverrouiller() } label: {
                    Text("Déverrouiller").font(.headline).padding(.horizontal, 40).padding(.vertical, 14).contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .verre(.regular.interactive(), in: .capsule)
                .disabled(authEnCours)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func deverrouiller() {
        guard !authEnCours else { return }
        let c = LAContext()
        var erreur: NSError?
        // Ni Face ID ni code configurés : on ne bloque pas l'accès à ses propres données
        guard c.canEvaluatePolicy(.deviceOwnerAuthentication, error: &erreur) else { verrouille = false; return }
        authEnCours = true
        c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Déverrouiller Le Cercle") { ok, _ in
            Task { @MainActor in
                authEnCours = false
                if ok { withAnimation { verrouille = false } }
            }
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
            Image(systemName: "chart.pie").font(.system(size: 44, weight: .light)).frame(width: 92, height: 92).verre(.regular, in: .rect(cornerRadius: 24))
            Text("Le Cercle").font(.largeTitle.weight(.bold))
            Text("Ton budget, tes analyses et tes comptes partagés.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 10) {
                TextField("E-mail", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(16).verre(.regular, in: .rect(cornerRadius: 16))
                SecureField("Mot de passe", text: $motDePasse).textContentType(.password)
                    .padding(16).verre(.regular, in: .rect(cornerRadius: 16))
            }
            .padding(.top, 10)
            if let e = magasin.erreur { Text(e).font(.footnote).foregroundStyle(Color.alerte).multilineTextAlignment(.center) }
            if !magasin.configure {
                Text("Cette version n'a pas l'adresse de ta base : ajoute les secrets SUPABASE_URL et SUPABASE_PUBLISHABLE_KEY dans GitHub, puis refabrique l'app.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button {
                guard !magasin.chargement else { return }
                Task { await magasin.connecter(email: email.trimmingCharacters(in: .whitespaces), motDePasse: motDePasse) }
            } label: {
                Group { if magasin.chargement { ProgressView() } else { Text("Se connecter").font(.headline) } }
                    .frame(maxWidth: .infinity).padding(.vertical, 14).contentShape(.capsule)   // tout le bouton réagit
            }
            .buttonStyle(.plain)
            .verre(.regular.interactive(), in: .capsule)
            .disabled(email.isEmpty || motDePasse.isEmpty || !magasin.configure || magasin.chargement)
            Spacer()
            Button("Essayer avec des données d'exemple") { magasin.ouvrirDemo() }.font(.subheadline).tint(.secondary)
        }
        .padding(24)
        .background(FondView())
    }
}
