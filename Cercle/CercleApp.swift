import SwiftUI

/// Point d'entrée de l'app. Pour cette première version, seulement la structure et le style :
/// les données (Supabase) arriveront à l'étape 3.3.
@main
struct CercleApp: App {
    var body: some Scene {
        WindowGroup {
            RacineView()
                .preferredColorScheme(.dark)   // thème sombre par défaut ; le choix viendra dans Mon espace
        }
    }
}
