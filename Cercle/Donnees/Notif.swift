import UserNotifications

/// Notifications locales (créées sur l'iPhone, aucun serveur) : enveloppe presque vide, budget dépassé,
/// et rappel avant l'expiration de l'app (7 jours avec un Apple ID gratuit).
enum Notif {
    static func autoriser() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private static func envoyer(_ id: String, _ texte: String, dans secondes: TimeInterval = 1) {
        let c = UNMutableNotificationContent()
        c.title = "Le Cercle"
        c.body = texte
        c.sound = .default
        let r = UNNotificationRequest(identifier: id, content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(secondes, 1), repeats: false))
        UNUserNotificationCenter.current().add(r)
    }

    /// Après un ajout : prévient si l'enveloppe de cette catégorie passe 80 % ou si le budget est dépassé.
    @MainActor static func apresAjout(_ o: Operation, magasin: Magasin) {
        guard UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true else { return }
        let t = magasin.tableau()   // même période que le Résumé, personnalisée comprise
        if let e = t.enveloppes.first(where: { $0.e.sc == o.sc }), e.etat != .ok {
            envoyer("env-\(o.id)", e.etat == .depasse ? "\(o.sc) : enveloppe dépassée de \(Fmt.eur(-e.reste, 0))." : "\(o.sc) : \(Fmt.pct(e.part)) de l'enveloppe utilisés, il reste \(Fmt.eur(e.reste, 0)).", dans: 3)
        } else if t.b.dep > t.budget && t.budget > 0 {
            envoyer("budget-\(o.id)", "Budget de la période dépassé de \(Fmt.eur(t.b.dep - t.budget, 0)).", dans: 3)
        }
    }

    /// Rappel 6 jours après l'installation : l'app installée avec un Apple ID gratuit expire au bout de 7 jours.
    /// La date d'installation est celle du dossier de l'app : elle change à chaque réinstallation avec Sideloadly.
    static func rappelExpiration() {
        let attributs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath)
        let installe = (attributs?[.creationDate] as? Date) ?? Date()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["expiration"])
        let dans = installe.addingTimeInterval(6 * 86400).timeIntervalSinceNow
        if dans > 0 { envoyer("expiration", "L'app expire demain : rebranche ton iPhone et réinstalle-la avec Sideloadly (tes données restent).", dans: dans) }
    }
}
