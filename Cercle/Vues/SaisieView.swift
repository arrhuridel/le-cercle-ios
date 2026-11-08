import SwiftUI
import PhotosUI

/// Feuille « Nouvelle opération » (ou modification) : grand montant, pavé numérique intégré, catégories, comptes,
/// raccourcis, date, répétition mensuelle, devise et lecture d'une capture d'écran.
struct SaisieView: View {
    @Environment(Magasin.self) private var magasin
    @Environment(\.dismiss) private var fermer
    var edition: Operation? = nil

    @State private var type: Ref.TypeSaisie = .depense
    @State private var montant = ""
    @State private var sc: String?
    @State private var choixManuel = false
    @State private var note = ""
    @State private var compte = ""
    @State private var vers = ""
    @State private var date = Date()
    @State private var repeter = false
    @State private var devise = "EUR"
    @State private var indice = ""
    @State private var photo: PhotosPickerItem?
    @State private var lecture = false
    @State private var secoue = 0
    @FocusState private var noteActive: Bool
    @State private var pret = false
    @State private var enCours = false     // empêche un double enregistrement (double tap, bouton du haut + bouton du bas)
    @State private var livret = ""         // livret visé par un versement ou un retrait

    @Environment(\.accessibilityReduceMotion) private var reduire
    @State private var reussi = false      // animation de réussite avant la fermeture

    /// Design v3 : tout tient sur un écran, sans défilement. Les réglages rares (compte, devise, répétition) sont dans « Options ».
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Picker("Type", selection: $type) { ForEach(Ref.TypeSaisie.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .onChange(of: type) { _, nt in
                        // Un raccourci ou une capture règle le type ET la catégorie : on ne garde la catégorie que si elle va avec le type.
                        guard pret, let s = sc, !nt.themes.contains(where: { $0.nom == s }) else { return }
                        sc = nil; choixManuel = false; indice = ""
                    }
                Button { noteActive = false } label: {
                    Text(montantAffiche).grandChiffre(54, poids: .semibold)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .foregroundStyle(montant.isEmpty ? .tertiary : .primary).frame(maxWidth: .infinity)
                        .contentTransition(.numericText())
                        .phaseAnimator(reduire ? [0.0] : [0.0, -8.0, 8.0, 0.0], trigger: secoue) { v, x in v.offset(x: CGFloat(x)) } animation: { _ in .linear(duration: 0.06) }
                }
                .buttonStyle(.plain)
                Text(indice.isEmpty ? (sc == nil && type != .virement ? "Choisis une catégorie, puis tape le montant" : "") : indice)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity).frame(height: 16)
                // Raccourcis (ou montants rapides quand il n'y en a pas)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if edition == nil && !raccourcis.isEmpty {
                            ForEach(raccourcis, id: \.id) { o in Button("\(o.note.isEmpty ? o.sc : o.note) · \(Fmt.eur(o.montant))") { remplir(o) }.puce(false) }
                        } else {
                            ForEach([5, 10, 20, 50], id: \.self) { v in Button("\(v) €") { montant = "\(v)" }.puce(false) }
                        }
                    }
                }
                .scrollClipDisabled()
                if type == .virement {
                    ligne("De") { puces(magasin.comptes, $compte) }
                    ligne("Vers") { puces(magasin.comptes, $vers) }
                } else {
                    categories
                    if let noms = nomsLivrets, sc == "Livret" || sc == "Retrait d'épargne" {
                        ligne(sc == "Livret" ? "Vers" : "Depuis") {
                            ScrollView(.horizontal, showsIndicators: false) { HStack { ForEach(noms, id: \.self) { n in Button(n) { livret = n }.puce(livret == n) } } }
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField(type == .virement ? "Note (facultatif)" : "Note : Lidl, cinéma…", text: $note).focused($noteActive)
                        .onChange(of: note) { _, n in deviner(n) }
                        .padding(.horizontal, 14).frame(height: 40)
                        .glassEffect(.regular, in: .capsule)
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date).labelsHidden().tint(.primary)
                    PhotosPicker(selection: $photo, matching: .images) {
                        Image(systemName: lecture ? "hourglass" : "text.viewfinder").frame(width: 40, height: 40).glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Lire une capture d'écran ou un ticket")
                    options
                }
                Spacer(minLength: 0)
                if !noteActive { pave }
            }
            .padding(.horizontal, 16).padding(.top, 4)
            .background(FondView())
            .overlay { if reussi { succes } }
            .navigationTitle(edition == nil ? "Nouvelle opération" : "Modifier").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                // « Enregistrer » reste accessible en haut même quand le clavier cache le pavé
                ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { Task { await enregistrer() } }.fontWeight(.semibold).disabled(enCours) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("OK") { noteActive = false } }
            }
            .onAppear(perform: preparer)
            .onChange(of: photo) { _, p in if let p { Task { await lireCapture(p) } } }
            .sensoryFeedback(.success, trigger: reussi)
        }
        .presentationDragIndicator(.visible)
    }

    /// Les catégories sur une ligne qui défile de côté ; la catégorie choisie est mise en valeur.
    private var categories: some View {
        ScrollViewReader { lecteur in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(themes, id: \.nom) { t in
                        Button { withAnimation(.snappy) { sc = t.nom }; choixManuel = true; indice = "" } label: {
                            VStack(spacing: 5) { Tuile(sc: t.nom, taille: 32); Text(t.court).font(.caption2.weight(.medium)).lineLimit(1) }
                                .frame(width: 70, height: 70)
                                .background(sc == t.nom ? Color.primary.opacity(0.16) : Color.clear, in: .rect(cornerRadius: 18))
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                                .scaleEffect(sc == t.nom ? 1.04 : 1)
                        }
                        .buttonStyle(.plain)
                        .id(t.nom)
                    }
                }
                .padding(.vertical, 3)
            }
            .scrollClipDisabled()
            .sensoryFeedback(.selection, trigger: sc)
            .onChange(of: sc) { _, n in if let n { withAnimation { lecteur.scrollTo(n, anchor: .center) } } }
        }
    }

    /// Réglages rares : compte, devise et répétition mensuelle.
    private var options: some View {
        Menu {
            if type != .virement {
                Picker(type == .depense ? "Payé avec" : type == .revenu ? "Reçu sur" : "Depuis", selection: $compte) {
                    ForEach(magasin.comptes, id: \.self) { Text(magasin.nomCompte($0)).tag($0) }
                }
                Picker("Devise", selection: $devise) {
                    ForEach(Ref.devises, id: \.code) { d in Text("\(d.code) · \(d.symbole)").tag(d.code) }
                }
            }
            if edition == nil { Toggle("Répéter chaque mois (le \(J.comp(date).j))", isOn: $repeter) }
        } label: {
            Image(systemName: repeter || devise != "EUR" ? "slider.horizontal.below.square.filled.and.square" : "slider.horizontal.3")
                .frame(width: 40, height: 40).glassEffect(.regular.interactive(), in: .circle)
        }
        .tint(.primary)
        .accessibilityLabel("Options : compte, devise, répétition")
    }

    private func ligne<C: View>(_ titre: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { Text(titre).etiquette().frame(width: 52, alignment: .leading); c() }
    }

    private var succes: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 40, weight: .semibold))
                .frame(width: 96, height: 96).glassEffect(.regular, in: .circle)
            Text("Enregistré").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: Pavé numérique

    private var pave: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", ",", "0", "⌫"], id: \.self) { t in
                    Button { touche(t) } label: {
                        Group { if t == "⌫" { Image(systemName: "delete.left") } else { Text(t) } }
                            .font(.title2.weight(.medium)).frame(maxWidth: .infinity, minHeight: 50)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18)).contentShape(.rect(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { Task { await enregistrer() } } label: {
                Group { if enCours { ProgressView() } else { Text(edition == nil ? "Enregistrer" : "Enregistrer les modifications") } }
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 52).contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .disabled(enCours)
            .glassEffect(.regular.interactive().tint(.primary.opacity(0.25)), in: .capsule)
        }
        .padding(.top, 4).padding(.bottom, 12)
        .sensoryFeedback(.impact(weight: .light), trigger: montant)
    }

    private var montantAffiche: String {
        if Fmt.masque && !montant.isEmpty { return "•••• €" }
        let p = montant.split(separator: ",", omittingEmptySubsequences: false)
        let ent = Fmt.nombre(Double(p.first ?? "0") ?? 0, 0)
        let symbole = Ref.devises.first { $0.code == devise }?.symbole ?? "€"
        return (montant.isEmpty ? "0" : ent + (p.count > 1 ? "," + p[1] : "")) + " " + symbole
    }

    private func touche(_ t: String) {
        switch t {
        case "⌫": if !montant.isEmpty { montant.removeLast() }
        case ",": if !montant.contains(",") { montant = (montant.isEmpty ? "0" : montant) + "," }
        default:
            let p = montant.split(separator: ",", omittingEmptySubsequences: false)
            if p.count > 1 && p[1].count >= 2 { return }
            if p.count == 1 && (p.first?.count ?? 0) >= 6 { return }
            montant = montant == "0" ? t : montant + t
        }
    }

    // MARK: Données

    private var themes: [Theme] {
        let limite = J.plus(J.auj, jours: -180)
        var usage: [String: Int] = [:]
        for o in magasin.ops where o.date >= limite { usage[o.sc, default: 0] += 1 }
        return type.themes.sorted { (usage[$0.nom] ?? 0) > (usage[$1.nom] ?? 0) }
    }

    /// Opérations identiques (même thème, note, montant) vues au moins 2 fois en 4 mois.
    private var raccourcis: [Operation] {
        let limite = J.plus(J.auj, jours: -120)
        var g: [String: (o: Operation, n: Int)] = [:]
        for o in magasin.ops where o.date >= limite && o.cat != .virement {
            let k = "\(o.sc)|\(o.note)|\(o.montant)|\(o.compte)"
            g[k] = (g[k]?.o ?? o, (g[k]?.n ?? 0) + 1)
        }
        return g.values.filter { $0.n >= 2 }.sorted { $0.n > $1.n }.prefix(6).map(\.o)
    }

    /// Noms des livrets connus par les relevés du site (nil s'il n'y en a pas).
    private var nomsLivrets: [String]? {
        guard let n = magasin.livrets?.noms, !n.isEmpty else { return nil }
        return n
    }

    private static func typePour(cat: Cat, sc: String) -> Ref.TypeSaisie {
        cat == .virement ? .virement : (cat == .epargne || Ref.mouvementsEpargne.contains(sc)) ? .epargne : cat == .revenu ? .revenu : .depense
    }

    private func puces(_ l: [String], _ choix: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack { ForEach(l, id: \.self) { k in Button(magasin.nomCompte(k)) { choix.wrappedValue = k }.puce(choix.wrappedValue == k) } }
        }
    }

    private func preparer() {
        let comptes = magasin.comptes
        vers = comptes.count > 1 ? comptes[1] : ""
        if let o = edition {
            type = Self.typePour(cat: o.cat, sc: o.sc)
            montant = Fmt.nombre(o.montantDevise ?? o.montant).replacingOccurrences(of: "\u{202f}", with: "").replacingOccurrences(of: " ", with: "")
            sc = o.cat == .virement ? nil : o.sc; choixManuel = true
            note = o.note; compte = o.compte; vers = o.vers ?? vers; date = J.date(o.date); devise = o.devise ?? "EUR"
            livret = nomsLivrets.flatMap { Livrets.vise(o.sc, o.note, $0) } ?? ""
        }
        DispatchQueue.main.async { pret = true }
    }

    private func remplir(_ o: Operation) {
        type = Self.typePour(cat: o.cat, sc: o.sc)
        livret = nomsLivrets.flatMap { Livrets.vise(o.sc, o.note, $0) } ?? ""
        sc = o.sc; choixManuel = true; note = o.note; compte = o.compte
        montant = String(format: "%.2f", o.montant).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: ",00", with: "")
        indice = "Rempli depuis un raccourci"
    }

    /// Catégorie proposée d'après l'historique : la dernière note qui commence pareil (comme sur le site).
    private func deviner(_ n: String) {
        let q = n.sansAccents.trimmingCharacters(in: .whitespaces)
        guard !choixManuel, type != .virement, q.count >= 2 else { return }
        let possibles = Set(type.themes.map(\.nom))
        if let o = magasin.ops.first(where: { possibles.contains($0.sc) && $0.note.sansAccents.hasPrefix(q) }), o.sc != sc {
            sc = o.sc; indice = "Catégorie proposée d'après ton historique : \(o.sc)"
        }
    }

    private func lireCapture(_ p: PhotosPickerItem) async {
        lecture = true
        defer { lecture = false; photo = nil }
        guard let d = try? await p.loadTransferable(type: Data.self), let img = UIImage(data: d) else { indice = "Image illisible."; return }
        let lignes = Import.analyserTexte(await Lecteur.texte(img))
        guard let l = lignes.first else { indice = "Aucun montant trouvé sur l'image."; return }
        let prop = Import.proposer(l.libelle, l.montant, regles: magasin.regles, historique: magasin.ops)
        // Le type suit la catégorie proposée (un virement vers le livret va dans Épargne, par exemple)
        type = Self.typePour(cat: Ref.theme(prop.sc).cat, sc: prop.sc)
        montant = String(format: "%.2f", abs(l.montant)).replacingOccurrences(of: ".", with: ",")
        note = prop.note; sc = type == .virement ? nil : prop.sc; choixManuel = true; date = J.date(l.date)
        indice = lignes.count > 1 ? "Première ligne lue sur \(lignes.count) : pour tout ajouter, passe par Mon espace › Importer." : "Lu sur l'image : vérifie avant d'enregistrer."
    }

    private func enregistrer() async {
        guard !enCours else { return }
        enCours = true
        defer { enCours = false }
        let brut = Fmt.lire(montant)
        guard brut > 0 else { indice = "Saisis un montant."; secoue += 1; return }
        if type != .virement && sc == nil { indice = "Choisis une catégorie."; secoue += 1; return }
        if type == .virement && compte == vers { indice = "Choisis deux comptes différents."; secoue += 1; return }
        let theme = type == .virement ? "Virement interne" : sc!
        let estLivret = theme == "Livret" || theme == "Retrait d'épargne"
        if estLivret, nomsLivrets != nil, livret.isEmpty { indice = "Choisis le livret."; secoue += 1; return }
        let taux = Ref.devises.first { $0.code == devise }?.taux ?? 1
        var m = (brut * taux * 100).rounded() / 100
        // Modification sans changer le montant ni la devise : on garde le montant en euros d'origine (le taux a pu bouger)
        if let e = edition, (e.devise ?? "EUR") == devise, abs((e.montantDevise ?? e.montant) - brut) < 0.005 { m = e.montant }
        var texte = note.trimmingCharacters(in: .whitespaces)
        // Le nom du livret doit figurer dans la note : c'est ainsi que le site et l'app suivent son solde
        if estLivret, !livret.isEmpty, !texte.lowercased().contains(livret.lowercased()) {
            let lien = (theme == "Livret" ? "Vers le " : "Depuis le ") + livret
            texte = texte.isEmpty ? lien : texte + " · " + lien
        }
        var o = magasin.nouvelleOperation(date: J.iso(date), sc: theme, montant: m, note: texte,
                                          compte: compte, vers: type == .virement ? vers : nil,
                                          devise: devise == "EUR" ? nil : devise, montantDevise: devise == "EUR" ? nil : brut)
        if let e = edition {
            o.id = e.id; o.creeLe = e.creeLe; o.source = e.source
            guard await magasin.modifier(o) else { indice = magasin.erreur ?? "Modification impossible."; return }
        } else {
            guard await magasin.ajouter(o) else { indice = magasin.erreur ?? "Enregistrement impossible."; return }
            if repeter {
                let c = J.comp(date)
                await magasin.enregistrer(Planifiee(id: UUID().uuidString.lowercased(), profilId: magasin.profil?.id ?? "", cat: o.cat, sc: o.sc, montant: o.montant,
                                                    note: o.note, compte: o.compte, vers: o.vers, jour: c.j, depuis: J.iso(J.moisSuivant(date)), actif: true))
            }
            Notif.apresAjout(o, magasin: magasin)
        }
        withAnimation(reduire ? nil : .smooth(duration: 0.25)) { reussi = true }
        try? await Task.sleep(for: .milliseconds(650))
        fermer()
    }
}

extension Text {
    func etiquette() -> some View { self.font(.footnote.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 4) }
}

extension View {
    /// Une « puce » : sélection neutre, jamais bleue.
    func puce(_ active: Bool) -> some View {
        self.font(.subheadline.weight(.medium)).padding(.horizontal, 13).padding(.vertical, 8)
            .background(active ? Color.primary.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(active ? .primary : .secondary)
            .buttonStyle(.plain)
    }
}
