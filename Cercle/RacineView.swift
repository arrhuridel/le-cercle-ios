import SwiftUI

/// Les onglets. « ajouter » n'est pas un vrai écran : le toucher ouvre la feuille de saisie.
enum Onglet: Hashable {
    case resume, analyses, activite, cercle, ajouter
}

/// La barre d'onglets en verre liquide d'iOS 26, avec le « + » rond séparé.
struct RacineView: View {
    @State private var onglet: Onglet = .resume
    @State private var saisieOuverte = false

    var body: some View {
        TabView(selection: $onglet) {
            Tab("Résumé", systemImage: "chart.pie", value: Onglet.resume) {
                EcranProvisoire(titre: "Résumé", sousTitre: "Dépenses, budget et comptes")
            }
            Tab("Analyses", systemImage: "chart.bar", value: Onglet.analyses) {
                EcranProvisoire(titre: "Analyses", sousTitre: "16 rubriques et le conseiller")
            }
            Tab("Activité", systemImage: "list.bullet", value: Onglet.activite) {
                EcranProvisoire(titre: "Activité", sousTitre: "Toutes tes opérations")
            }
            Tab("Cercle", systemImage: "person.2", value: Onglet.cercle) {
                EcranProvisoire(titre: "Cercle", sousTitre: "Groupes et Mon espace")
            }
            // Le rôle « search » place cet onglet à part, dans un bouton rond en verre : c'est notre « + ».
            // Il n'affiche rien : on revient aussitôt à l'onglet précédent et on ouvre la feuille de saisie.
            Tab("Ajouter", systemImage: "plus", value: Onglet.ajouter, role: .search) {
                Color.clear
            }
        }
        .tint(.primary)   // sélection neutre, jamais bleue
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: onglet) { ancien, nouveau in
            if nouveau == .ajouter {
                onglet = ancien
                saisieOuverte = true
            }
        }
        .sensoryFeedback(.selection, trigger: onglet)
        .sheet(isPresented: $saisieOuverte) {
            FeuilleSaisieProvisoire()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
