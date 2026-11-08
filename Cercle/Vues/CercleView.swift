import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Cercle (design v3) : ton solde dans les groupes, la liste des groupes (elle seule défile) et une carte de réglages rapides.
struct CercleView: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage("faceId") private var faceId = false
    @AppStorage("masque") private var masque = false
    @AppStorage("theme") private var theme = "sombre"
    @State private var nouveauGroupe = false
    @State private var choixTheme = false
    @AppStorage(ThemeCouleurs.cle) private var couleurs = ThemeCouleurs.nuit.rawValue
    @AppStorage("couleursAppliquees") private var couleursAppliquees = ThemeCouleurs.nuit.rawValue
    @State private var edite: Champ?
    @State private var saisie = ""
    enum Champ: String, Identifiable { case budget = "Budget mensuel", objectif = "Objectif d'épargne mensuel"; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            let groupes = magasin.groupes
            let tot = groupes.reduce(0.0) { r, g in r + solde(g) }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tes comptes partagés").font(.subheadline).foregroundStyle(.secondary)
                        Text("Cercle").font(.largeTitle.bold())
                    }
                    Spacer()
                    if !groupes.isEmpty {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(abs(tot) < 0.005 ? "À jour" : Fmt.eur(tot, signe: true)).font(.title2.bold()).monospacedDigit().foregroundStyle(teinte(tot))
                            Text(tot > 0.004 ? "on te doit" : tot < -0.004 ? "tu dois" : "tout est réglé").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if groupes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.3").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Aucun groupe pour l'instant").font(.headline)
                        Text("Coloc, voyage, soirée : partage une dépense, Le Cercle calcule qui doit quoi.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button { nouveauGroupe = true } label: { Text("Créer un groupe").font(.headline).frame(maxWidth: .infinity, minHeight: 46).contentShape(.capsule) }
                            .buttonStyle(.plain).glassEffect(.regular.interactive().tint(.primary.opacity(0.2)), in: .capsule)
                    }
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(.regular, in: .rect(cornerRadius: 26))
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(groupes) { g in
                                NavigationLink { GroupeView(groupeId: g.id) } label: { ligneGroupe(g) }.buttonStyle(.plain)
                            }
                            Button { nouveauGroupe = true } label: {
                                HStack(spacing: 10) { Image(systemName: "plus").frame(width: 30, height: 30).background(.white.opacity(0.1), in: .circle); Text("Nouveau groupe").fontWeight(.semibold); Spacer() }
                                    .padding(14).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22)).contentShape(.rect(cornerRadius: 22))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable { await magasin.rafraichir() }
                }
                espace
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
            .background(FondView())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $nouveauGroupe) { NouveauGroupeView() }
            .sheet(isPresented: $choixTheme, onDismiss: { couleursAppliquees = couleurs }) { ChoixThemeView() }
            .alert(edite?.rawValue ?? "", isPresented: Binding(get: { edite != nil }, set: { if !$0 { edite = nil } }), presenting: edite) { c in
                TextField("Montant en euros", text: $saisie).keyboardType(.decimalPad)
                Button("Enregistrer") { enregistrer(c) }
                Button("Annuler", role: .cancel) { saisie = "" }
            } message: { _ in Text("« 0 » enlève la valeur.") }
            .onAppear { Notif.rappelExpiration() }
        }
    }

    private func solde(_ g: GroupeComplet) -> Double { Tricount.moi(g, profil: magasin.profil?.id).map { Tricount.soldes(g)[$0] ?? 0 } ?? 0 }
    private func teinte(_ v: Double) -> Color { v > 0.004 ? .positif : v < -0.004 ? .negatif : .secondary }

    private func ligneGroupe(_ g: GroupeComplet) -> some View {
        let s = solde(g)
        return HStack(spacing: 12) {
            HStack(spacing: -8) { ForEach(g.participants.prefix(3)) { p in Avatar(nom: p.nom) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(g.groupe.nom).fontWeight(.semibold).lineLimit(1)
                Text("\(g.participants.count) personnes · \(g.depenses.count) dépense\(g.depenses.count > 1 ? "s" : "")").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(abs(s) < 0.005 ? "À jour" : Fmt.eur(s, signe: true)).monospacedDigit().fontWeight(.semibold).foregroundStyle(teinte(s))
                if abs(s) >= 0.005 { Text(s > 0 ? "on te doit" : "tu dois").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(14).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22)).contentShape(.rect(cornerRadius: 22))
    }

    /// Réglages rapides ; le reste est dans « Tous les réglages ».
    private var espace: some View {
        VStack(spacing: 0) {
            // Budget et objectif d'épargne ne se saisissent plus : le total du mois = salaire + CAF, l'épargne = 20 % des revenus (08/11)
            Toggle("Verrouiller avec Face ID", isOn: $faceId).padding(.vertical, 9)
            Divider().opacity(0.4)
            Toggle("Masquer les montants", isOn: $masque).padding(.vertical, 9)
            Divider().opacity(0.4)
            ligneBouton("Thème", couleurs) { choixTheme = true }
            Divider().opacity(0.4)
            HStack {
                Text("Apparence"); Spacer()
                Picker("Apparence", selection: $theme) { Text("Sombre").tag("sombre"); Text("Clair").tag("clair"); Text("Auto").tag("auto") }.labelsHidden().tint(.secondary)
            }
            .padding(.vertical, 3)
            Divider().opacity(0.4)
            NavigationLink { MonEspaceView() } label: {
                HStack { Text("Tous les réglages"); Spacer(); Text("données, membres, compte").font(.footnote).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                    .padding(.vertical, 11).contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .tint(.positif)
        .padding(.horizontal, 16).padding(.vertical, 2)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func ligneBouton(_ titre: String, _ valeur: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(titre); Spacer(); Text(valeur).monospacedDigit().foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                .padding(.vertical, 11).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Un champ vide ne change rien ; « 0 » tapé exprès enlève la valeur.
    private func enregistrer(_ c: Champ) {
        let brut = saisie.filter { !$0.isWhitespace }
        saisie = ""
        guard !brut.isEmpty, Double(brut.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "€", with: "")) != nil else { return }
        let v = Fmt.lire(brut)
        guard v >= 0 else { return }
        Task {
            switch c {
            case .budget: await magasin.majProfil(budget: v)
            case .objectif: await magasin.majProfil(objectifEpargne: v)
            }
        }
    }
}

/// Tous les réglages de Mon espace (visibilité, budget, enveloppes, sécurité, données, membres, compte).
struct MonEspaceView: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage("faceId") private var faceId = false
    @AppStorage("masque") private var masque = false
    @AppStorage("confidentiel") private var confidentiel = false
    @AppStorage("theme") private var theme = "sombre"
    @AppStorage("notifications") private var notifications = true
    @State private var confirmerSortie = false
    @State private var budget = ""
    @State private var objectif = ""

    var body: some View {
        Ecran {
                TitreSection(texte: "Mon espace")
                CarteVerre(espacement: 10) {
                    Text("Visibilité de mon budget").font(.headline)
                    Picker("Visibilité", selection: Binding(get: { magasin.profil?.visibilite ?? "prive" }, set: { v in Task { await magasin.majProfil(visibilite: v) } })) {
                        Text("Privé").tag("prive"); Text("Résumé").tag("resume"); Text("Complet").tag("tout")
                    }
                    .pickerStyle(.segmented)
                    Text(["prive": "Personne ne voit ton budget.", "resume": "Les membres voient tes totaux et pourcentages, sans le détail.", "tout": "Les membres voient ton résumé et le détail de tes opérations."][magasin.profil?.visibilite ?? "prive"] ?? "")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                CarteVerre(espacement: 12) {
                    Text("Le total du mois est ce que tu reçois en salaire et CAF ; l'objectif d'épargne est 20 % de tous tes revenus. Rien à régler.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Enveloppes par catégorie") { EnveloppesView() }
                }
                .tint(.primary)
                CarteVerre(espacement: 12) {
                    Toggle("Verrouiller avec Face ID", isOn: $faceId)
                    Toggle("Masquer les montants", isOn: $masque)
                    Toggle(isOn: $confidentiel) { VStack(alignment: .leading) { Text("Mode confidentiel"); Text("Montants arrondis à la dizaine").font(.caption).foregroundStyle(.secondary) } }
                    Toggle("Notifications d'enveloppes", isOn: $notifications).onChange(of: notifications) { _, v in if v { Notif.autoriser() } }
                    Picker("Apparence", selection: $theme) { Text("Sombre").tag("sombre"); Text("Clair").tag("clair"); Text("Auto").tag("auto") }.pickerStyle(.segmented)
                }
                .tint(.positif)
                CarteVerre(espacement: 12) {
                    NavigationLink("Données : import, capture, règles, sauvegarde") { DonneesView() }
                    NavigationLink("Membres du Cercle") { MembresView() }
                }
                .tint(.primary)
                Button(magasin.etat == .demo ? "Quitter le mode démo" : "Se déconnecter", role: .destructive) {
                    if magasin.etat == .demo { Task { await magasin.deconnecter() } } else { confirmerSortie = true }
                }
                .frame(maxWidth: .infinity).padding(.top, 6)
                .confirmationDialog("Se déconnecter ?", isPresented: $confirmerSortie, titleVisibility: .visible) {
                    Button("Se déconnecter", role: .destructive) { Task { await magasin.deconnecter() } }
                } message: { Text("Tes données restent dans la base. Il faudra ton e-mail et ton mot de passe pour revenir.") }
                Text(magasin.etat == .demo ? "Mode démo : données inventées, rien n'est enregistré." : "Connecté à la base du site : ce que tu ajoutes ici apparaît aussi sur le site.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Réglages")
            .refreshable { await magasin.rafraichir() }
    }

    private func champ(_ titre: String, _ texte: Binding<String>, valeur: Double?, enregistrer: @escaping (Double) async -> Void) -> some View {
        HStack {
            Text(titre)
            Spacer()
            TextField(Fmt.eur(valeur ?? 0, 0), text: texte).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110)
                .onSubmit { valider(texte, enregistrer) }
            Button("OK") { valider(texte, enregistrer) }
                .disabled(texte.wrappedValue.isEmpty)
        }
    }
    /// Un champ vide ne remet jamais le budget à zéro ; « 0 » tapé exprès est accepté (pas de budget).
    private func valider(_ texte: Binding<String>, _ enregistrer: @escaping (Double) async -> Void) {
        let brut = texte.wrappedValue.filter { !$0.isWhitespace }
        texte.wrappedValue = ""
        guard !brut.isEmpty, Double(brut.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "€", with: "")) != nil else { return }
        let v = Fmt.lire(brut)
        if v >= 0 { Task { await enregistrer(v) } }
    }
}

struct Avatar: View {
    let nom: String
    var body: some View {
        let teintes: [Color] = [.init(red: 0.5, green: 0.61, blue: 0.76), .init(red: 0.44, green: 0.66, blue: 0.64), .init(red: 0.76, green: 0.6, blue: 0.43), .init(red: 0.62, green: 0.56, blue: 0.78)]
        Text(String(nom.prefix(1)).uppercased()).font(.caption.weight(.semibold)).frame(width: 30, height: 30)
            .background(teintes[abs(nom.hashValue) % teintes.count].opacity(0.5), in: Circle())
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
    }
}

/// Un groupe : ton solde, qui doit quoi (Payer / Reçu / Réglé, relance), soldes, dépenses, remboursements.
struct GroupeView: View {
    @Environment(Magasin.self) private var magasin
    let groupeId: String
    @State private var ajout = false
    @State private var enCours = false
    @State private var aSupprimer: ASupprimer?
    enum ASupprimer: Identifiable { case depense(String, String), reglement(String, String)
        var id: String { switch self { case .depense(let i, _), .reglement(let i, _): i } }
        var titre: String { switch self { case .depense(_, let t): "Supprimer la dépense « \(t) » ?"; case .reglement(_, let t): "Supprimer le remboursement \(t) ?" } }
    }

    var body: some View {
        if let g = magasin.groupes.first(where: { $0.id == groupeId }) {
            let moi = Tricount.moi(g, profil: magasin.profil?.id)
            let soldes = Tricount.soldes(g), s = moi.map { soldes[$0] ?? 0 } ?? 0
            Ecran {
                CarteVerre {
                    Text("Ton solde").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Text(abs(s) < 0.005 ? Fmt.eur(0) : Fmt.eur(s, signe: true)).grandChiffre(40, design: .default)
                        .foregroundStyle(s > 0.004 ? Color.positif : s < -0.004 ? Color.negatif : .primary).frame(maxWidth: .infinity)
                    Text(s > 0.004 ? "On te doit cette somme" : s < -0.004 ? "Tu dois cette somme" : "Tout est réglé").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                TitreSection(texte: "Qui doit quoi")
                CarteVerre(espacement: 12) {
                    let r = Tricount.remboursements(g)
                    if r.isEmpty { Label("Tout le monde est à jour", systemImage: "checkmark.circle").foregroundStyle(Color.positif) }
                    ForEach(r, id: \.self) { v in
                        HStack(spacing: 10) {
                            Avatar(nom: g.nom(v.de))
                            VStack(alignment: .leading) { Text("\(g.nom(v.de)) → \(g.nom(v.a))"); Text("\(v.de == moi ? "tu dois" : "doit") \(Fmt.eur(v.montant))").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if v.a == moi {
                                ShareLink(item: "Salut \(g.nom(v.de)) ! Petit rappel pour « \(g.groupe.nom) » : il reste \(Fmt.eur(v.montant)) à me rembourser. Merci !") { Image(systemName: "bell") }
                            }
                            Button(v.a == moi ? "Reçu" : v.de == moi ? "Payer" : "Réglé") {
                                guard !enCours else { return }
                                enCours = true
                                Task { await magasin.ajouter(reglement: Reglement(id: UUID().uuidString.lowercased(), groupeId: g.id, de: v.de, a: v.a, montant: v.montant, date: J.auj)); enCours = false }
                            }
                            .puce(true)
                            .disabled(enCours)
                        }
                    }
                }
                TitreSection(texte: "Soldes")
                CarteVerre(espacement: 10) {
                    ForEach(g.participants) { p in
                        let v = soldes[p.id] ?? 0
                        HStack { Avatar(nom: p.nom); Text(p.nom + (p.id == moi ? " (toi)" : "")); Spacer(); Text(abs(v) < 0.005 ? "à jour" : Fmt.eur(v, signe: true)).monospacedDigit().foregroundStyle(v > 0.004 ? Color.positif : v < -0.004 ? Color.negatif : .secondary) }
                    }
                }
                TitreSection(texte: "Dépenses")
                CarteVerre(espacement: 10) {
                    if g.depenses.isEmpty { Text("Aucune dépense pour l'instant.").foregroundStyle(.secondary) }
                    ForEach(g.depenses.sorted { $0.date > $1.date }) { d in
                        let part = moi.flatMap { Tricount.parts(d)[$0] }
                        HStack(spacing: 12) {
                            Tuile(sc: d.sc)
                            VStack(alignment: .leading) {
                                Text(d.titre)
                                Text("\(g.nom(d.payeur)) a payé · \(d.parts.count) pers.\(d.mode != "egal" ? " · parts inégales" : "")\(d.montantDevise.map { " · \(Fmt.nombre($0)) \(d.devise ?? "")" } ?? "") · \(J.court(d.date))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing) { Text(Fmt.eur(d.montant)).monospacedDigit(); Text(part.map { "ta part \(Fmt.eur($0))" } ?? "sans toi").font(.caption).foregroundStyle(.secondary) }
                        }
                        .contextMenu { Button("Supprimer la dépense", role: .destructive) { aSupprimer = .depense(d.id, d.titre) } }
                    }
                }
                if !g.reglements.isEmpty {
                    TitreSection(texte: "Remboursements")
                    CarteVerre(espacement: 10) {
                        ForEach(g.reglements.sorted { $0.date > $1.date }) { r in
                            HStack { Pastille(symbole: "arrow.left.arrow.right"); VStack(alignment: .leading) { Text("\(g.nom(r.de)) → \(g.nom(r.a))"); Text(J.court(r.date)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(Fmt.eur(r.montant)).monospacedDigit() }
                                .contextMenu { Button("Supprimer", role: .destructive) { aSupprimer = .reglement(r.id, "\(g.nom(r.de)) → \(g.nom(r.a))") } }
                        }
                    }
                }
                ShareLink(item: bilan(g, soldes)) { Label("Partager le bilan", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 12) }
                    .glassEffect(.regular.interactive(), in: .capsule).tint(.primary)
                Text("Ta part compte dans tes dépenses. Ce que tu avances et les remboursements sont des virements : ils bougent ton compte sans fausser ton budget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .safeAreaInset(edge: .bottom) {
                Button { ajout = true } label: { Label("Ajouter une dépense partagée", systemImage: "plus").font(.headline).frame(maxWidth: .infinity, minHeight: 50).contentShape(.capsule) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive().tint(.primary.opacity(0.2)), in: .capsule)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .navigationTitle(g.groupe.nom)
            .toolbar { Button { ajout = true } label: { Image(systemName: "plus") }.accessibilityLabel("Ajouter une dépense partagée") }
            .sheet(isPresented: $ajout) { DepensePartageeView(groupe: g) }
            .confirmationDialog(aSupprimer?.titre ?? "", isPresented: Binding(get: { aSupprimer != nil }, set: { if !$0 { aSupprimer = nil } }), titleVisibility: .visible, presenting: aSupprimer) { x in
                Button("Supprimer", role: .destructive) {
                    Task {
                        switch x {
                        case .depense(let id, _): await magasin.supprimerDepense(groupe: g.id, id: id)
                        case .reglement(let id, _): await magasin.supprimerReglement(groupe: g.id, id: id)
                        }
                    }
                }
            }
        }
    }

    private func bilan(_ g: GroupeComplet, _ s: [String: Double]) -> String {
        ([" \(g.groupe.nom) · bilan au \(J.court(J.auj))", "", "Dépenses :"] + g.depenses.map { "· \($0.titre) : \(Fmt.eur($0.montant)) payé par \(g.nom($0.payeur))" }
         + ["", "Soldes :"] + g.participants.map { "· \($0.nom) : \(Fmt.eur(s[$0.id] ?? 0, signe: true))" }
         + ["", "Pour solder :"] + Tricount.remboursements(g).map { "· \(g.nom($0.de)) → \(g.nom($0.a)) : \(Fmt.eur($0.montant))" } + ["", "Envoyé depuis Le Cercle"]).joined(separator: "\n")
    }
}

/// Nouvelle dépense partagée : parts égales, en montants, en pourcentages ou en poids ; devise.
struct DepensePartageeView: View {
    @Environment(Magasin.self) private var magasin
    @Environment(\.dismiss) private var fermer
    let groupe: GroupeComplet
    @State private var titre = ""
    @State private var montant = ""
    @State private var payeur = ""
    @State private var parts: Set<String> = []
    @State private var mode = "egal"
    @State private var valeurs: [String: String] = [:]
    @State private var sc = "Restos & sorties"
    @State private var devise = "EUR"
    @State private var id = UUID().uuidString.lowercased()   // même identifiant à chaque calcul : un second envoi serait refusé, pas dupliqué
    @State private var enCours = false
    @State private var echec: String?

    private var depense: DepensePartagee {
        let brut = Fmt.lire(montant), taux = Ref.devises.first { $0.code == devise }?.taux ?? 1
        let ordre = groupe.participants.map(\.id).filter(parts.contains)
        return DepensePartagee(id: id, groupeId: groupe.id, titre: titre.trimmingCharacters(in: .whitespaces), montant: (brut * taux * 100).rounded() / 100,
                               payeur: payeur, parts: ordre, mode: mode, valeurs: Dictionary(ordre.map { ($0, Fmt.lire(valeurs[$0] ?? "")) }, uniquingKeysWith: { a, _ in a }),
                               sc: sc, date: J.auj, devise: devise == "EUR" ? nil : devise, montantDevise: devise == "EUR" ? nil : brut)
    }
    private var erreur: String? {
        let d = depense, brut = Fmt.lire(montant)
        guard brut > 0, !d.titre.isEmpty, !d.parts.isEmpty else { return nil }
        let tot = d.parts.reduce(0) { $0 + (d.valeurs[$1] ?? 0) }
        if mode == "montants" && abs(tot - brut) > 0.009 { return "Les montants font \(Fmt.nombre(tot)) sur \(Fmt.nombre(brut))." }
        if mode == "pourcent" && abs(tot - 100) > 0.01 { return "Les pourcentages font \(Fmt.nombre(tot, 0)) % au lieu de 100 %." }
        if mode == "parts" && tot <= 0 { return "Donne au moins une part." }
        return nil
    }

    var body: some View {
        let d = depense, moi = Tricount.moi(groupe, profil: magasin.profil?.id)
        NavigationStack {
            Form {
                TextField("Titre (ex. Dîner, essence)", text: $titre)
                HStack {
                    TextField("Montant", text: $montant).keyboardType(.decimalPad)
                    Picker("", selection: $devise) { ForEach(Ref.devises, id: \.code) { Text($0.code).tag($0.code) } }.labelsHidden()
                }
                Picker("Payé par", selection: $payeur) { ForEach(groupe.participants) { Text($0.nom).tag($0.id) } }
                Section("Pour qui") {
                    ForEach(groupe.participants) { p in
                        HStack {
                            Toggle(p.nom, isOn: Binding(get: { parts.contains(p.id) }, set: { if $0 { parts.insert(p.id) } else { parts.remove(p.id) } }))
                            if mode != "egal" && parts.contains(p.id) {
                                TextField("0", text: Binding(get: { valeurs[p.id] ?? "" }, set: { valeurs[p.id] = $0 })).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
                                Text(mode == "montants" ? devise : mode == "pourcent" ? "%" : "part(s)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Picker("Répartition", selection: $mode) { Text("Égales").tag("egal"); Text("Montants").tag("montants"); Text("%").tag("pourcent"); Text("Parts").tag("parts") }.pickerStyle(.segmented)
                }
                Picker("Catégorie", selection: $sc) { ForEach(Ref.themes.filter { $0.cat.estDepense }, id: \.nom) { Text($0.nom).tag($0.nom) } }
                Section {
                    if let echec { Text(echec).foregroundStyle(Color.negatif) }
                    if let e = erreur { Text(e).foregroundStyle(Color.alerte) }
                    else if d.montant > 0 && !d.parts.isEmpty {
                        let mienne = moi.flatMap { Tricount.parts(d)[$0] } ?? 0
                        if devise != "EUR" { Text("\(montant) \(devise) ≈ \(Fmt.eur(d.montant)) (taux de démonstration)") }
                        if mienne > 0 { Text("Ta part : \(Fmt.eur(mienne)), comptée dans tes dépenses (\(sc)).") }
                        Text(payeur == moi ? "Ton compte baisse de \(Fmt.eur(d.montant)), dont \(Fmt.eur(d.montant - mienne)) avancés pour les autres." : mienne > 0 ? "Ton compte ne bouge pas : tu rembourseras plus tard." : "Aucun effet sur ton budget.")
                    }
                }
                .font(.footnote)
            }
            .navigationTitle("Dépense partagée")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") {
                        guard !enCours else { return }
                        enCours = true
                        Task {
                            if await magasin.ajouter(depense: d) { fermer() } else { echec = magasin.erreur ?? "Ajout impossible : réessaie." }
                            enCours = false
                        }
                    }
                    .disabled(enCours || d.montant <= 0 || d.titre.isEmpty || d.parts.isEmpty || erreur != nil || payeur.isEmpty)
                }
            }
            .onAppear { payeur = moi ?? groupe.participants.first?.id ?? ""; parts = Set(groupe.participants.map(\.id)) }
        }
    }
}

struct NouveauGroupeView: View {
    @Environment(Magasin.self) private var magasin
    @Environment(\.dismiss) private var fermer
    @State private var nom = ""
    @State private var amis = ["", ""]
    @State private var enCours = false
    @State private var echec: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom du groupe", text: $nom)
                Section("Participants") {
                    Text("\(magasin.profil?.prenom ?? "Toi") (toi)").foregroundStyle(.secondary)
                    ForEach(amis.indices, id: \.self) { i in TextField("Prénom", text: $amis[i]) }
                    Button("Ajouter un participant") { amis.append("") }
                }
                Text("Si un ami a l'app avec le même prénom, il verra le groupe chez lui.").font(.footnote).foregroundStyle(.secondary)
                if let echec { Text(echec).font(.footnote).foregroundStyle(Color.negatif) }
            }
            .navigationTitle("Nouveau groupe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") {
                        let noms = amis.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        guard !enCours else { return }
                        enCours = true
                        Task {
                            if await magasin.creerGroupe(nom: nom.trimmingCharacters(in: .whitespaces), amis: noms) != nil { fermer() } else { echec = magasin.erreur ?? "Création impossible : réessaie." }
                            enCours = false
                        }
                    }
                    .disabled(enCours || nom.trimmingCharacters(in: .whitespaces).isEmpty || amis.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
        }
    }
}

/// Enveloppes : un plafond par catégorie et par mois, avec report facultatif.
struct EnveloppesView: View {
    @Environment(Magasin.self) private var magasin
    @Environment(\.dismiss) private var fermer
    @State private var montants: [String: String] = [:]
    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Avec le report, ce qui reste (ou ce qui manque) passe sur la période suivante.")) {
                    ForEach(magasin.enveloppes) { e in
                        HStack {
                            Tuile(sc: e.sc, taille: 30)
                            VStack(alignment: .leading) {
                                Text(e.sc)
                                Toggle("Report", isOn: Binding(get: { e.report }, set: { v in var x = e; x.report = v; Task { await magasin.enregistrer(x) } })).font(.caption).tint(.positif)
                            }
                            TextField(Fmt.eur(e.montant, 0), text: Binding(get: { montants[e.id] ?? "" }, set: { montants[e.id] = $0 }))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                                .onSubmit { let v = Fmt.lire(montants[e.id] ?? ""); if v > 0 { var x = e; x.montant = v; Task { await magasin.enregistrer(x) } } }
                        }
                        .swipeActions { Button("Supprimer", role: .destructive) { Task { await magasin.supprimer(enveloppe: e) } } }
                    }
                }
                Section("Ajouter une enveloppe") {
                    ForEach(Ref.themes.filter { t in t.cat.estDepense && !magasin.enveloppes.contains { $0.sc == t.nom } }, id: \.nom) { t in
                        Button { Task { await magasin.enregistrer(Enveloppe(id: UUID().uuidString.lowercased(), profilId: magasin.profil?.id ?? "", sc: t.nom, montant: 50, report: false)) } } label: {
                            HStack { Tuile(sc: t.nom, taille: 30); Text(t.nom); Spacer(); Image(systemName: "plus.circle") }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Enveloppes")
            .toolbar {
                Button("OK") {
                    for e in magasin.enveloppes { let v = Fmt.lire(montants[e.id] ?? ""); if v > 0 { var x = e; x.montant = v; Task { await magasin.enregistrer(x) } } }
                    fermer()
                }
            }
        }
    }
}

struct ObjectifView: View {
    @Environment(Magasin.self) private var magasin
    @Environment(\.dismiss) private var fermer
    let objectif: Objectif?
    @State private var nom = ""
    @State private var cible = ""
    @State private var support = "Projet"
    @State private var avecDate = false
    @State private var date = Date().addingTimeInterval(180 * 86400)
    @State private var enCours = false
    @State private var confirmer = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom (ex. voyage, matelas de sécurité)", text: $nom)
                TextField("Montant à atteindre", text: $cible).keyboardType(.decimalPad)
                Picker("Mis de côté sur", selection: $support) { ForEach(Ref.supports, id: \.self) { Text($0) } }
                Toggle("Date visée", isOn: $avecDate).tint(.positif)
                if avecDate { DatePicker("Date", selection: $date, displayedComponents: .date) }
                if let o = objectif, let s = Suivi.objectifs([o], magasin.toutes, livret: magasin.totalLivrets).first {
                    Section { Text("Déjà \(Fmt.eur(s.actuel, 0)) sur \(Fmt.eur(o.cible, 0)). Rythme sur 3 mois : \(Fmt.eur(s.rythme, 0)) par mois." + (s.parMois.map { " Pour tenir la date : \(Fmt.eur($0, 0)) par mois." } ?? "")).font(.footnote) }
                    Button("Supprimer l'objectif", role: .destructive) { confirmer = true }
                        .confirmationDialog("Supprimer « \(o.nom) » ?", isPresented: $confirmer, titleVisibility: .visible) {
                            Button("Supprimer", role: .destructive) { Task { if await magasin.supprimer(objectif: o) { fermer() } } }
                        }
                }
            }
            .navigationTitle(objectif == nil ? "Nouvel objectif" : "Objectif")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        let o = Objectif(id: objectif?.id ?? UUID().uuidString.lowercased(), profilId: magasin.profil?.id ?? "", nom: nom.trimmingCharacters(in: .whitespaces),
                                         support: support, cible: Fmt.lire(cible), dateVisee: avecDate ? J.iso(date) : nil)
                        guard !enCours else { return }
                        enCours = true
                        Task { if await magasin.enregistrer(o) { fermer() }; enCours = false }
                    }
                    .disabled(enCours || nom.trimmingCharacters(in: .whitespaces).isEmpty || Fmt.lire(cible) <= 0)
                }
            }
            .onAppear {
                if let o = objectif { nom = o.nom; cible = Fmt.nombre(o.cible, 0).replacingOccurrences(of: "\u{202f}", with: ""); support = o.support; if let d = o.dateVisee { avecDate = true; date = J.date(d) } }
            }
        }
    }
}

struct MembresView: View {
    @Environment(Magasin.self) private var magasin
    var body: some View {
        List(magasin.membres) { m in
            HStack { Avatar(nom: m.prenom); Text(m.prenom); Spacer(); Text(["prive": "Privé", "resume": "Résumé", "tout": "Complet"][m.visibilite] ?? m.visibilite).foregroundStyle(.secondary) }
        }
        .scrollContentBackground(.hidden).background(FondView())
        .navigationTitle("Membres du Cercle")
    }
}

/// Données : import d'un relevé CSV ou d'une capture (plusieurs lignes), règles de catégorisation, sauvegarde.
struct DonneesView: View {
    @Environment(Magasin.self) private var magasin
    @State private var importCSV = false
    @State private var photo: PhotosPickerItem?
    @State private var lignes: [Import.Ligne] = []
    @State private var brutes: [Import.Ligne] = []
    @State private var compte = ""
    @State private var message: String?
    @State private var nouvelleRegle = false
    @State private var enCours = false

    var body: some View {
        Form {
            Section("Ajouter des opérations") {
                Button { importCSV = true } label: { Label("Importer un relevé CSV", systemImage: "tablecells") }
                PhotosPicker(selection: $photo, matching: .images) { Label("Capture d'écran ou ticket", systemImage: "text.viewfinder") }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Text("Formats lus : Crédit Mutuel / CIC, Boursobank, Revolut. Trade Republic ne donne que des relevés PDF : saisis ces opérations à la main.").font(.caption).foregroundStyle(.secondary)
            }
            if !lignes.isEmpty {
                Section("À valider : \(lignes.filter(\.garder).count) sur \(lignes.count)") {
                    Picker("Sur le compte", selection: $compte) { ForEach(magasin.comptes, id: \.self) { Text(magasin.nomCompte($0)).tag($0) } }
                    ForEach($lignes) { $l in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                // Case « sans bordure » : dans une ligne de liste, elle ne gêne pas le choix de catégorie
                                Button { l.garder.toggle() } label: {
                                    Image(systemName: l.garder ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(l.garder ? Color.positif : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(l.garder ? "Importer cette ligne" : "Ne pas importer cette ligne")
                                Text(l.note).lineLimit(1)
                                Spacer()
                                Text(Fmt.eur(l.montant, signe: true)).monospacedDigit().foregroundStyle(l.montant > 0 ? Color.positif : .primary)
                            }
                            Text("\(J.court(l.date)) · \(l.libelle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            HStack {
                                Picker("Catégorie", selection: $l.sc) {
                                    ForEach(Ref.themes.filter { $0.cat != .virement && ($0.cat == .revenu) == (l.montant > 0) }, id: \.nom) { Text($0.nom).tag($0.nom) }
                                }
                                .labelsHidden().tint(.primary).pickerStyle(.menu).buttonStyle(.borderless)
                                Text(l.doublon.map { $0.hasPrefix("peut-être") || $0.hasPrefix("saisie nette") ? $0 : "déjà saisie : \($0)" } ?? l.source).badge(l.doublon == nil ? .secondary : .alerte)
                            }
                        }
                    }
                    Button {
                        Task { await valider() }
                    } label: {
                        if enCours { ProgressView() } else { Text("Ajouter les opérations cochées (\(lignes.filter(\.garder).count))").fontWeight(.semibold) }
                    }
                    .disabled(enCours || !lignes.contains(where: \.garder))
                    Text("Une catégorie corrigée devient une règle : la prochaine fois, ce libellé sera classé tout seul.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Règles de catégorisation") {
                ForEach(magasin.regles) { r in
                    VStack(alignment: .leading) { Text("« \(r.motif) »"); Text("→ \(r.sc)\(r.note.isEmpty ? "" : " · " + r.note)").font(.caption).foregroundStyle(.secondary) }
                        .swipeActions { Button("Supprimer", role: .destructive) { magasin.supprimerRegle(r) } }
                }
                Button("Ajouter une règle") { nouvelleRegle = true }
                Text("Les libellés inconnus sont ensuite classés par tes règles, ton historique, puis les règles du site.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sauvegarde") {
                ShareLink(item: SauvegardeJSON(instantane: magasin.instantane), preview: SharePreview("Sauvegarde Le Cercle")) { Label("Exporter une sauvegarde (JSON)", systemImage: "square.and.arrow.up") }
                Text("Tes données sont déjà dans ta base Supabase ; cette copie te sert d'archive personnelle.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
        .scrollContentBackground(.hidden).background(FondView())
        .navigationTitle("Données")
        .fileImporter(isPresented: $importCSV, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { r in
            guard case .success(let url) = r else { return }
            let acces = url.startAccessingSecurityScopedResource()
            defer { if acces { url.stopAccessingSecurityScopedResource() } }
            do {
                let res = try Import.lireCSV(try Data(contentsOf: url))
                if Import.estLivret(res.lignes) {
                    lignes = []; brutes = []
                    message = "C'est le relevé d'un livret : importe-le depuis le site (onglet Opérations, Importer). Il met à jour le solde du livret au lieu de créer des dépenses."
                    return
                }
                if res.format == "Boursobank" || res.format == "Revolut", let c = magasin.comptes.first(where: { $0.lowercased().contains(res.format.lowercased()) }) { compte = c }
                preparer(res.lignes)
                message = "Relevé \(res.format) lu : \(res.lignes.count) lignes. Vérifie le compte ci-dessous."
            } catch { message = error.localizedDescription }
        }
        .onChange(of: photo) { _, p in
            guard let p else { return }
            Task {
                defer { photo = nil }
                guard let d = try? await p.loadTransferable(type: Data.self), let img = UIImage(data: d) else { message = "Image illisible."; return }
                let l = Import.analyserTexte(await Lecteur.texte(img))
                if l.isEmpty { message = "Aucun montant trouvé sur l'image." } else { preparer(l); message = "\(l.count) ligne(s) lue(s) sur l'image : vérifie avant d'ajouter." }
            }
        }
        .sheet(isPresented: $nouvelleRegle) { RegleView() }
        // Les doublons dépendent du compte choisi : on les recherche à nouveau sur le bon compte
        .onChange(of: compte) { _, _ in if !brutes.isEmpty { preparer(brutes) } }
    }

    /// Catégorie proposée et doublons (même sens et même montant sur le compte, à 5 jours près, comme le site).
    private func preparer(_ entree: [Import.Ligne]) {
        brutes = entree
        var pris = Set<String>()
        lignes = entree.map { b in
            var l = b
            let p = Import.proposer(l.libelle, l.montant, regles: magasin.regles, historique: magasin.ops)
            l.sc = p.sc; l.note = p.note; l.source = p.source
            let jour = Import.nettoyer(l.libelle)
            if let j = jour.jour, let m = jour.mois { let c = J.comp(J.date(l.date)); let d = J.faire(c.a - (m > c.m ? 1 : 0), m, j); if J.iso(d) <= l.date { l.date = J.iso(d) } }
            if let d = magasin.toutes.first(where: { o in !pris.contains(o.id) && abs(abs(Calc.effet(o, compte)) - abs(l.montant)) < 0.005 && (Calc.effet(o, compte) > 0) == (l.montant > 0) && abs(J.ecart(o.date, l.date)) <= 5 }) {
                pris.insert(d.id); l.doublon = d.note.isEmpty ? d.sc : d.note; l.garder = false
            } else {
                // Peut-être déjà saisie : même marchand, même sens, à 4 jours près, avec un autre montant (montant net, par exemple)
                let m = Import.mots(l.libelle)
                if !m.isEmpty, let d = magasin.toutes.first(where: { memeMarchand($0, l, m) }) {
                    l.doublon = "peut-être : \(d.note.isEmpty ? d.sc : d.note) (\(Fmt.eur(d.montant)))"; l.garder = false
                }
            }
            return l
        }
        // Saisies nettes ou groupées : des lignes restantes qui, ensemble, font une opération déjà saisie et pas encore reconnue
        guard let debut = lignes.map(\.date).min(), let fin = lignes.map(\.date).max() else { return }
        var restantes = lignes.enumerated().filter { $0.element.doublon == nil || $0.element.doublon!.hasPrefix("peut-être") }.map { (i: $0.offset, date: $0.element.date, montant: $0.element.montant) }
        for o in magasin.toutes where !pris.contains(o.id) && o.date >= J.plus(debut, jours: -6) && o.date <= J.plus(fin, jours: 6) {
            let e = Calc.effet(o, compte)
            guard abs(e) > 0.004, let combo = Import.nettes(restantes, cible: (o.date, (e * 100).rounded() / 100)) else { continue }
            pris.insert(o.id)
            restantes.removeAll { combo.contains($0.i) }
            for i in combo { lignes[i].doublon = "saisie nette ou groupée : \(o.note.isEmpty ? o.sc : o.note) (\(Fmt.eur(o.montant)))"; lignes[i].garder = false }
        }
    }

    /// Même marchand, même sens, à 4 jours près (le montant peut différer : saisie nette, par exemple).
    private func memeMarchand(_ o: Operation, _ l: Import.Ligne, _ m: Set<String>) -> Bool {
        let e = Calc.effet(o, compte)
        guard abs(e) > 0.004, (e > 0) == (l.montant > 0), abs(J.ecart(o.date, l.date)) <= 4 else { return false }
        return !m.isDisjoint(with: Import.mots(o.note + " " + Analyse.marchand(o)))
    }

    /// Ajoute les lignes cochées. Si la base refuse, rien n'est ajouté, les lignes restent à l'écran et le message le dit.
    private func valider() async {
        guard !enCours else { return }
        enCours = true
        defer { enCours = false }
        let gardees = lignes.filter(\.garder)
        guard !gardees.isEmpty else { return }
        let corrigees = gardees.filter { l in l.source == "corrigé" || Import.proposer(l.libelle, l.montant, regles: magasin.regles, historique: magasin.ops).sc != l.sc }
        let ops = gardees.map { l in magasin.nouvelleOperation(date: l.date, sc: l.sc, montant: abs(l.montant), note: l.note, compte: compte, vers: nil, source: "csv") }
        guard await magasin.ajouter(ops) else {
            message = "Rien n'a été ajouté : \(magasin.erreur ?? "la base n'a pas répondu"). Réessaie."
            return
        }
        for l in corrigees {
            let motif = Import.cleLibelle(l.libelle)
            if !motif.isEmpty { magasin.ajouterRegle(Import.Regle(motif: motif, sc: l.sc, note: l.note)) }
        }
        message = "\(ops.count) opération(s) ajoutée(s) sur \(magasin.nomCompte(compte))."
        lignes = []; brutes = []
    }
}

struct RegleView: View {
    @Environment(Magasin.self) private var magasin
    @Environment(\.dismiss) private var fermer
    @State private var motif = ""
    @State private var sc = "Courses"
    @State private var note = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Mot du libellé (ex. NAOLIB)", text: $motif).textInputAutocapitalization(.characters)
                Picker("Catégorie", selection: $sc) { ForEach(Ref.themes.filter { $0.cat != .virement }, id: \.nom) { Text($0.nom).tag($0.nom) } }
                TextField("Note à mettre (facultatif)", text: $note)
            }
            .navigationTitle("Nouvelle règle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                ToolbarItem(placement: .confirmationAction) { Button("OK") { magasin.ajouterRegle(Import.Regle(motif: motif.uppercased(), sc: sc, note: note)); fermer() }.disabled(motif.isEmpty) }
            }
        }
    }
}

/// Sauvegarde JSON : le fichier n'est fabriqué qu'au moment du partage (pas à chaque affichage de l'écran).
struct SauvegardeJSON: Transferable {
    let instantane: Instantane
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { s in
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try e.encode(s.instantane)
        }
        .suggestedFileName("le-cercle-sauvegarde.json")
    }
}
