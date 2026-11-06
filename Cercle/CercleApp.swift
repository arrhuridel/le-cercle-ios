import SwiftUI

/// Point d'entrée de l'app.
@main
struct CercleApp: App {
    @State private var magasin = Magasin()
    var body: some Scene {
        WindowGroup {
            RacineView().environment(magasin)
        }
    }
}
