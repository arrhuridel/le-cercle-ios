import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Cercle : groupes de partage (façon Tricount) et Mon espace (réglages, données, sécurité).
struct CercleView: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage("faceId") private var faceId = false
    @AppStorage("masque") private var masque = false
    @AppStorage("confidentiel") private var confidentiel = false
    @AppStorage("theme") private var theme = "sombre"
    @AppStorage("notifications") private var notifications = true
    @State private var nouveauGroupe = false
    @State private var budget = ""
    @State private var objectif = ""

    var body: some View {
        NavigationStack {
            Ecran {
                TitreSection(texte: "Groupes")
                ForEach(magasin.groupes) { g in
                    NavigationLink { GroupeView(groupeId: g.id) } label: {
                        let moi = Tricount.moi(g, profil: magasin.profil?.id), s = moi.map { Tricount.soldes(g)[$0] ?? 0 } ?? 0
                        HStack(spacing: 12) {
                            HStack(spacing: -8) { ForEach(g.participants.prefix(4)) { p in Avatar(nom: p.nom) } }
                            VStack(alignment: .leading) { Text(g.groupe.nom).fontWeight(.semibold).lineLimit(1); Text("\(g.participants.count) personnes · \(g.depenses.count) dépense(s)").font(.footnote).foregroundStyle(.secondary) }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(abs(s) < 0.005 ? "À jour" : Fmt.eur(s, signe: true)).monospacedDigit().fontWeight(.semibold).foregroundStyle(s > 0.004 ? Color.positif : s < -0.004 ? Color.negatif : .secondary)
                                Text(s > 0.004 ? "on te doit" : s < -0.004 ? "tu dois" : "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(14).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                }
                Button { nouveauGroupe = true } label: {
                    HStack { Pastille(symbole: "plus"); VStack(alignment: .leading) { Text("Nouveau groupe"); Text("Coloc, voyage, soirée…").font(.footnote).foregroundStyle(.secondary) }; Spacer() }
                        .padding(14).glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                }
                .buttonStyle(.plain)

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
                    champ("Budget mensuel", $budget, valeur: magasin.profil?.budget) { await magasin.majProfil(budget: $0) }
                    champ("Objectif d'épargne mensuel", $objectif, valeur: magasin.profil?.objectifEpargne) { await magasin.majProfil(objectifEpargne: $0) }
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
                Button(magasin.etat == .demo ? "Quitter le mode démo" : "Se déconnecter", role: .destructive) { Task { await magasin.deconnecter() } }
                    .frame(maxWidth: .infinity).padding(.top, 6)
                Text(magasin.etat == .demo ? "Mode démo : données inventées, rien n'est enregistré." : "Connecté à la base du site : ce que tu ajoutes ici apparaît aussi sur le site.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Cercle")
            .refreshable { await magasin.rafraichir() }
            .sheet(isPresented: $nouveauGroupe) { NouveauGroupeView() }
            .onAppear { Notif.rappelExpiration() }
        }
    }

    private func champ(_ titre: String, _ texte: Binding<String>, valeur: Double?, enregistrer: @escaping (Double) async -> Void) -> some View {
        HStack {
            Text(titre)
            Spacer()
            TextField(Fmt.eur(valeur ?? 0, 0), text: texte).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 110)
                .onSubmit { let v = Fmt.lire(texte.wrappedValue); if v >= 0 { Task { await enregistrer(v) } }; texte.wrappedValue = "" }
            Button("OK") { let v = Fmt.lire(texte.wrappedValue); if v > 0 { Task { await enregistrer(v) } }; texte.wrappedValue = "" }
                .disabled(texte.wrappedValue.isEmpty)
        }
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

    var body: some View {
        if let g = magasin.groupes.first(where: { $0.id == groupeId }) {
            let moi = Tricount.moi(g, profil: magasin.profil?.id)
            let soldes = Tricount.soldes(g), s = moi.map { soldes[$0] ?? 0 } ?? 0
            Ecran {
                CarteVerre {
                    Text("Ton solde").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Text(abs(s) < 0.005 ? Fmt.eur(0) : Fmt.eur(s, signe: true)).font(.system(size: 40, weight: .bold)).monospacedDigit()
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
                                Task { await magasin.ajouter(reglement: Reglement(id: UUID().uuidString.lowercased(), groupeId: g.id, de: v.de, a: v.a, montant: v.montant, date: J.auj)) }
                            }
                            .puce(true)
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
                        .contextMenu { Button("Supprimer la dépense", role: .destructive) { Task { await magasin.supprimerDepense(groupe: g.id, id: d.id) } } }
                    }
                }
                if !g.reglements.isEmpty {
                    TitreSection(texte: "Remboursements")
                    CarteVerre(espacement: 10) {
                        ForEach(g.reglements.sorted { $0.date > $1.date }) { r in
                            HStack { Pastille(symbole: "arrow.left.arrow.right"); VStack(alignment: .leading) { Text("\(g.nom(r.de)) → \(g.nom(r.a))"); Text(J.court(r.date)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(Fmt.eur(r.montant)).monospacedDigit() }
                                .contextMenu { Button("Supprimer", role: .destructive) { Task { await magasin.supprimerReglement(groupe: g.id, id: r.id) } } }
                        }
                    }
                }
                ShareLink(item: bilan(g, soldes)) { Label("Partager le bilan", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 12) }
                    .glassEffect(.regular.interactive(), in: .capsule).tint(.primary)
                Text("Ta part compte dans tes dépenses. Ce que tu avances et les remboursements sont des virements : ils bougent ton compte sans fausser ton budget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle(g.groupe.nom)
            .toolbar { Button { ajout = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $ajout) { DepensePartageeView(groupe: g) }
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

    private var depense: DepensePartagee {
        let brut = Fmt.lire(montant), taux = Ref.devises.first { $0.code == devise }?.taux ?? 1
        let ordre = groupe.participants.map(\.id).filter(parts.contains)
        return DepensePartagee(id: UUID().uuidString.lowercased(), groupeId: groupe.id, titre: titre.trimmingCharacters(in: .whitespaces), montant: (brut * taux * 100).rounded() / 100,
                               payeur: payeur, parts: ordre, mode: mode, valeurs: Dictionary(uniqueKeysWithValues: ordre.map { ($0, Fmt.lire(valeurs[$0] ?? "")) }),
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
                    Button("Ajouter") { Task { await magasin.ajouter(depense: d); fermer() } }
                        .disabled(d.montant <= 0 || d.titre.isEmpty || d.parts.isEmpty || erreur != nil || payeur.isEmpty)
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
            }
            .navigationTitle("Nouveau groupe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") {
                        let noms = amis.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        Task { _ = await magasin.creerGroupe(nom: nom.trimmingCharacters(in: .whitespaces), amis: noms); fermer() }
                    }
                    .disabled(nom.trimmingCharacters(in: .whitespaces).isEmpty || amis.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
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
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom (ex. voyage, matelas de sécurité)", text: $nom)
                TextField("Montant à atteindre", text: $cible).keyboardType(.decimalPad)
                Picker("Mis de côté sur", selection: $support) { ForEach(Ref.supports, id: \.self) { Text($0) } }
                Toggle("Date visée", isOn: $avecDate).tint(.positif)
                if avecDate { DatePicker("Date", selection: $date, displayedComponents: .date) }
                if let o = objectif, let s = Suivi.objectifs([o], magasin.toutes).first {
                    Section { Text("Déjà \(Fmt.eur(s.actuel, 0)) sur \(Fmt.eur(o.cible, 0)). Rythme sur 3 mois : \(Fmt.eur(s.rythme, 0)) par mois." + (s.parMois.map { " Pour tenir la date : \(Fmt.eur($0, 0)) par mois." } ?? "")).font(.footnote) }
                    Button("Supprimer l'objectif", role: .destructive) { Task { await magasin.supprimer(objectif: o); fermer() } }
                }
            }
            .navigationTitle(objectif == nil ? "Nouvel objectif" : "Objectif")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        let o = Objectif(id: objectif?.id ?? UUID().uuidString.lowercased(), profilId: magasin.profil?.id ?? "", nom: nom.trimmingCharacters(in: .whitespaces),
                                         support: support, cible: Fmt.lire(cible), dateVisee: avecDate ? J.iso(date) : nil)
                        Task { await magasin.enregistrer(o); fermer() }
                    }
                    .disabled(nom.trimmingCharacters(in: .whitespaces).isEmpty || Fmt.lire(cible) <= 0)
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
    @State private var compte = ""
    @State private var message: String?
    @State private var nouvelleRegle = false

    var body: some View {
        Form {
            Section("Ajouter des opérations") {
                Button { importCSV = true } label: { Label("Importer un relevé CSV", systemImage: "tablecells") }
                PhotosPicker(selection: $photo, matching: .images) { Label("Capture d'écran ou ticket", systemImage: "text.viewfinder") }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if !lignes.isEmpty {
                Section("À valider : \(lignes.filter(\.garder).count) sur \(lignes.count)") {
                    Picker("Sur le compte", selection: $compte) { ForEach(magasin.comptes, id: \.self) { Text(magasin.nomCompte($0)).tag($0) } }
                    ForEach($lignes) { $l in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Toggle(isOn: $l.garder) { Text(l.note).lineLimit(1) }.tint(.positif)
                                Text(Fmt.eur(l.montant, signe: true)).monospacedDigit().foregroundStyle(l.montant > 0 ? Color.positif : .primary)
                            }
                            Text("\(J.court(l.date)) · \(l.libelle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            HStack {
                                Picker("Catégorie", selection: $l.sc) {
                                    ForEach(Ref.themes.filter { $0.cat != .virement && ($0.cat == .revenu) == (l.montant > 0) }, id: \.nom) { Text($0.nom).tag($0.nom) }
                                }
                                .labelsHidden().tint(.primary)
                                Text(l.doublon.map { "déjà saisie : \($0)" } ?? l.source).badge(l.doublon == nil ? .secondary : .alerte)
                            }
                        }
                    }
                    Button("Ajouter les opérations cochées") { Task { await valider() } }.fontWeight(.semibold)
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
                ShareLink(item: SauvegardeJSON(donnees: magasin.exportJSON()), preview: SharePreview("Sauvegarde Le Cercle")) { Label("Exporter une sauvegarde (JSON)", systemImage: "square.and.arrow.up") }
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
                preparer(res.lignes)
                message = "Relevé lu : \(res.lignes.count) lignes, format \(res.format)."
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
    }

    /// Catégorie proposée et doublons (même sens et même montant sur le compte, à 5 jours près, comme le site).
    private func preparer(_ brutes: [Import.Ligne]) {
        var pris = Set<String>()
        lignes = brutes.map { b in
            var l = b
            let p = Import.proposer(l.libelle, l.montant, regles: magasin.regles, historique: magasin.ops)
            l.sc = p.sc; l.note = p.note; l.source = p.source
            let jour = Import.nettoyer(l.libelle)
            if let j = jour.jour, let m = jour.mois { let c = J.comp(J.date(l.date)); let d = J.faire(c.a - (m > c.m ? 1 : 0), m, j); if J.iso(d) <= l.date { l.date = J.iso(d) } }
            if let d = magasin.toutes.first(where: { o in !pris.contains(o.id) && abs(abs(Calc.effet(o, compte)) - abs(l.montant)) < 0.005 && (Calc.effet(o, compte) > 0) == (l.montant > 0) && abs(J.ecart(o.date, l.date)) <= 5 }) {
                pris.insert(d.id); l.doublon = d.note.isEmpty ? d.sc : d.note; l.garder = false
            }
            return l
        }
    }

    private func valider() async {
        let gardees = lignes.filter(\.garder)
        let ops = gardees.map { l in magasin.nouvelleOperation(date: l.date, sc: l.sc, montant: abs(l.montant), note: l.note, compte: compte, vers: nil, source: "csv") }
        for l in gardees where l.source == "corrigé" || Import.proposer(l.libelle, l.montant, regles: magasin.regles, historique: magasin.ops).sc != l.sc {
            let motif = Import.cleLibelle(l.libelle)
            if !motif.isEmpty { magasin.ajouterRegle(Import.Regle(motif: motif, sc: l.sc, note: l.note)) }
        }
        await magasin.ajouter(ops)
        message = "\(ops.count) opération(s) ajoutée(s)."
        lignes = []
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

struct SauvegardeJSON: Transferable {
    let donnees: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.donnees }.suggestedFileName("le-cercle-sauvegarde.json")
    }
}
