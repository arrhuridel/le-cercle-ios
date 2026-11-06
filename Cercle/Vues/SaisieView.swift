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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Type", selection: $type) { ForEach(Ref.TypeSaisie.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented)
                            .onChange(of: type) { _, _ in if pret { sc = nil; choixManuel = false; indice = "" } }
                        Button { noteActive = false } label: {
                            Text(montantAffiche).font(.system(size: 58, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(montant.isEmpty ? .tertiary : .primary).frame(maxWidth: .infinity)
                                .phaseAnimator([0.0, -10.0, 10.0, 0.0], trigger: secoue) { v, x in v.offset(x: CGFloat(x)) }
                        }
                        .buttonStyle(.plain)
                        Text(indice).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(minHeight: 16)
                        HStack { ForEach([5, 10, 20, 50], id: \.self) { v in Button("\(v) €") { montant = "\(v)" }.puce(false) } }
                        if edition == nil && !raccourcis.isEmpty {
                            Text("Raccourcis").etiquette()
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack { ForEach(raccourcis, id: \.id) { o in Button("\(o.note.isEmpty ? o.sc : o.note) · \(Fmt.eur(o.montant))") { remplir(o) }.puce(false) } }
                            }
                        }
                        HStack {
                            TextField(type == .virement ? "Note (facultatif)" : "Note (ex. Lidl, cinéma…)", text: $note).focused($noteActive)
                                .onChange(of: note) { _, n in deviner(n) }
                            PhotosPicker(selection: $photo, matching: .images) {
                                Image(systemName: lecture ? "hourglass" : "text.viewfinder")
                            }
                            .accessibilityLabel("Lire une capture d'écran ou un ticket")
                        }
                        .padding(14).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
                        if type == .virement {
                            Text("De").etiquette()
                            puces(magasin.comptes, $compte)
                            Text("Vers").etiquette()
                            puces(magasin.comptes, $vers)
                        } else {
                            Text("Catégorie").etiquette()
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                                ForEach(themes, id: \.nom) { t in
                                    Button { sc = t.nom; choixManuel = true; indice = "" } label: {
                                        VStack(spacing: 6) { Tuile(sc: t.nom, taille: 34); Text(t.court).font(.caption2).lineLimit(1) }
                                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                                            .background(sc == t.nom ? Color.primary.opacity(0.14) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 16))
                                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(sc == t.nom ? Color.primary.opacity(0.3) : .clear, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .sensoryFeedback(.selection, trigger: sc)
                            Text(type == .depense ? "Payé avec" : type == .revenu ? "Reçu sur" : "Depuis").etiquette()
                            puces(magasin.comptes, $compte)
                        }
                        DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                        if type != .virement {
                            Menu {
                                ForEach(Ref.devises, id: \.code) { d in Button("\(d.code) · \(d.symbole)") { devise = d.code } }
                            } label: { Label(devise == "EUR" ? "Devise : euro" : "Devise : \(devise), convertie en euros", systemImage: "globe") }
                            .tint(.primary).font(.subheadline)
                        }
                        if edition == nil {
                            Toggle(isOn: $repeter) { VStack(alignment: .leading) { Text("Répéter chaque mois"); Text("Saisie automatique le \(J.comp(date).j) de chaque mois").font(.caption).foregroundStyle(.secondary) } }
                        }
                    }
                    .padding(16)
                }
                if !noteActive { pave }
            }
            .navigationTitle(edition == nil ? "Nouvelle opération" : "Modifier").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } } }
            .onAppear(perform: preparer)
            .onChange(of: photo) { _, p in if let p { Task { await lireCapture(p) } } }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: Pavé numérique

    private var pave: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", ",", "0", "⌫"], id: \.self) { t in
                    Button { touche(t) } label: {
                        Group { if t == "⌫" { Image(systemName: "delete.left") } else { Text(t) } }
                            .font(.title2.weight(.medium)).frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button { Task { await enregistrer() } } label: {
                Text(edition == nil ? "Enregistrer" : "Enregistrer les modifications").font(.headline).frame(maxWidth: .infinity, minHeight: 52)
            }
            .glassEffect(.regular.interactive().tint(.primary.opacity(0.25)), in: .capsule)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
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

    private func puces(_ l: [String], _ choix: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack { ForEach(l, id: \.self) { k in Button(magasin.nomCompte(k)) { choix.wrappedValue = k }.puce(choix.wrappedValue == k) } }
        }
    }

    private func preparer() {
        let comptes = magasin.comptes
        vers = comptes.count > 1 ? comptes[1] : ""
        if let o = edition {
            type = o.cat == .virement ? .virement : (o.cat == .epargne || Ref.mouvementsEpargne.contains(o.sc)) ? .epargne : o.cat == .revenu ? .revenu : .depense
            montant = Fmt.nombre(o.montantDevise ?? o.montant).replacingOccurrences(of: "\u{202f}", with: "").replacingOccurrences(of: " ", with: "")
            sc = o.cat == .virement ? nil : o.sc; choixManuel = true
            note = o.note; compte = o.compte; vers = o.vers ?? vers; date = J.date(o.date); devise = o.devise ?? "EUR"
        }
        DispatchQueue.main.async { pret = true }
    }

    private func remplir(_ o: Operation) {
        type = o.cat == .virement ? .virement : (o.cat == .epargne || Ref.mouvementsEpargne.contains(o.sc)) ? .epargne : o.cat == .revenu ? .revenu : .depense
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
        type = l.montant > 0 ? .revenu : .depense
        montant = String(format: "%.2f", abs(l.montant)).replacingOccurrences(of: ".", with: ",")
        note = prop.note; sc = prop.sc; choixManuel = true; date = J.date(l.date)
        indice = lignes.count > 1 ? "Première ligne lue sur \(lignes.count) : pour tout ajouter, passe par Mon espace › Importer." : "Lu sur l'image : vérifie avant d'enregistrer."
    }

    private func enregistrer() async {
        let brut = Fmt.lire(montant)
        guard brut > 0 else { indice = "Saisis un montant."; secoue += 1; return }
        if type != .virement && sc == nil { indice = "Choisis une catégorie."; secoue += 1; return }
        if type == .virement && compte == vers { indice = "Choisis deux comptes différents."; secoue += 1; return }
        let taux = Ref.devises.first { $0.code == devise }?.taux ?? 1
        let m = (brut * taux * 100).rounded() / 100
        let theme = type == .virement ? "Virement interne" : sc!
        var o = magasin.nouvelleOperation(date: J.iso(date), sc: theme, montant: m, note: note.trimmingCharacters(in: .whitespaces),
                                          compte: compte, vers: type == .virement ? vers : nil,
                                          devise: devise == "EUR" ? nil : devise, montantDevise: devise == "EUR" ? nil : brut)
        if let e = edition {
            o.id = e.id; o.creeLe = e.creeLe; o.source = e.source
            await magasin.modifier(o)
        } else {
            guard await magasin.ajouter(o) else { indice = magasin.erreur ?? "Enregistrement impossible."; return }
            if repeter {
                let c = J.comp(date)
                await magasin.enregistrer(Planifiee(id: UUID().uuidString.lowercased(), profilId: magasin.profil?.id ?? "", cat: o.cat, sc: o.sc, montant: o.montant,
                                                    note: o.note, compte: o.compte, vers: o.vers, jour: c.j, depuis: J.iso(J.moisSuivant(date)), actif: true))
            }
            Notif.apresAjout(o, magasin: magasin)
        }
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
