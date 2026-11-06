import SwiftUI

/// Activité : recherche, filtres, opérations groupées par jour avec leur total, suppression d'un glissement.
struct ActiviteView: View {
    @Environment(Magasin.self) private var magasin
    @State private var recherche = ""
    @State private var filtre = "Tout"
    @State private var compte: String? = nil
    @State private var mois: String? = nil
    @State private var limite = 150
    @State private var ouverte: Operation?
    @State private var aSupprimer: Operation?

    private let filtres = ["Tout", "Dépenses", "Revenus", "Épargne", "Partagé"]

    private var filtrees: [Operation] {
        let q = recherche.sansAccents
        return magasin.toutes.filter { o in
            switch filtre {
            case "Dépenses": if !o.cat.estDepense { return false }
            case "Revenus": if !(o.cat == .revenu && !Ref.mouvementsEpargne.contains(o.sc)) { return false }
            case "Épargne": if !(o.cat == .epargne || Ref.mouvementsEpargne.contains(o.sc)) { return false }
            case "Partagé": if o.partage == nil { return false }
            default: break
            }
            if let compte, !(o.compte == compte || (o.cat == .virement && o.vers == compte)) { return false }
            if let mois, !o.date.hasPrefix(mois) { return false }
            return q.isEmpty || "\(o.note) \(o.sc) \(magasin.nomCompte(o.compte))".sansAccents.contains(q)
        }
        .sorted { ($0.date, $0.creeLe ?? "") > ($1.date, $1.creeLe ?? "") }
    }

    var body: some View {
        let ops = filtrees
        let jours = Dictionary(grouping: ops.prefix(limite), by: \.date).sorted { $0.key > $1.key }
        let b = Calc.bilan(ops)
        NavigationStack {
            List {
                Section {
                    Picker("Filtre", selection: $filtre) { ForEach(filtres, id: \.self) { Text($0) } }.pickerStyle(.segmented)
                    HStack {
                        Menu {
                            Button("Tous les comptes") { compte = nil }
                            ForEach(magasin.comptes, id: \.self) { k in Button("\(magasin.nomCompte(k)) · \(Fmt.eur(magasin.solde(k)))") { compte = k } }
                        } label: { Label(compte.map { magasin.nomCompte($0) } ?? "Tous les comptes", systemImage: "building.columns") }
                        Spacer()
                        Menu {
                            Button("Tous les mois") { mois = nil }
                            ForEach(Calc.moisDerniers(12).reversed()) { m in Button(m.long.capitalizedPremiere) { mois = m.cle } }
                        } label: { Label(mois.map { m in Calc.moisDerniers(12).first { $0.cle == m }?.long.capitalizedPremiere ?? m } ?? "Tous les mois", systemImage: "calendar") }
                    }
                    .font(.subheadline).tint(.primary)
                    HStack {
                        if let compte {
                            totaux("Solde", magasin.solde(compte)); totaux("Entrées", ops.reduce(0) { $0 + max(Calc.effet($1, compte), 0) }); totaux("Sorties", ops.reduce(0) { $0 + max(-Calc.effet($1, compte), 0) })
                        } else {
                            totaux("Revenus", b.rev); totaux("Dépenses", b.dep); totaux("Épargne", b.epa)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                if ops.isEmpty {
                    ContentUnavailableView(recherche.isEmpty ? "Aucune opération" : "Aucun résultat", systemImage: "magnifyingglass",
                                           description: Text(recherche.isEmpty ? "Rien dans ce filtre pour l'instant." : "Rien ne correspond à cette recherche."))
                        .listRowBackground(Color.clear)
                }
                ForEach(jours, id: \.key) { jour, l in
                    let dep = l.filter { $0.cat.estDepense }.reduce(0) { $0 + $1.montant }
                    Section {
                        ForEach(l) { o in
                            Button { ouverte = o } label: { LigneOperation(op: o, magasin: magasin) }
                                .buttonStyle(.plain)
                                .swipeActions { Button("Supprimer", role: .destructive) { aSupprimer = o } }
                        }
                    } header: {
                        HStack { Text(J.libelleJour(jour)); Spacer(); if dep > 0 { Text(Fmt.eur(-dep, signe: true)).monospacedDigit() } }
                    }
                }
                if ops.count > limite {
                    Button("Afficher plus (\(ops.count - limite) restantes)") { limite += 200 }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(FondView())
            .searchable(text: $recherche, prompt: "Rechercher une note, une catégorie…")
            .navigationTitle("Activité")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: ExportCSV(ops: ops, magasin: magasin), preview: SharePreview("Opérations (CSV)")) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .refreshable { await magasin.rafraichir() }
            .sheet(item: $ouverte) { DetailOperation(op: $0) }
            .confirmationDialog("Supprimer cette opération ?", isPresented: Binding(get: { aSupprimer != nil }, set: { if !$0 { aSupprimer = nil } }), titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) { if let o = aSupprimer { Task { await magasin.supprimer(o) } } }
            } message: {
                Text(aSupprimer?.partage != nil ? "Elle vient d'un groupe : l'élément sera retiré du groupe, pour tout le monde." : "Cette opération sera supprimée.")
            }
        }
    }

    private func totaux(_ t: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(t).font(.caption).foregroundStyle(.secondary); Text(Fmt.eur(v, 0)).font(.headline).monospacedDigit() }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10).glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/// Détail d'une opération : modifier, supprimer, voir son origine.
struct DetailOperation: View {
    @Environment(Magasin.self) private var magasin
    @Environment(\.dismiss) private var fermer
    let op: Operation
    @State private var edition = false
    @State private var confirmer = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Tuile(sc: op.sc, taille: 56)
                        Text(Fmt.eur(op.cat == .revenu ? op.montant : -op.montant, signe: op.cat != .virement)).font(.system(size: 40, weight: .semibold)).monospacedDigit()
                        Text(op.note.isEmpty ? op.sc : op.note).font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
                Section {
                    LabeledContent("Date", value: J.libelleJour(op.date))
                    LabeledContent("Catégorie", value: op.sc)
                    if op.cat == .virement {
                        LabeledContent("De", value: magasin.nomCompte(op.compte)); LabeledContent("Vers", value: magasin.nomCompte(op.vers))
                    } else { LabeledContent("Compte", value: magasin.nomCompte(op.compte)) }
                    if let d = op.devise, let m = op.montantDevise { LabeledContent("Montant d'origine", value: "\(Fmt.nombre(m)) \(d)") }
                    if let s = op.source, s != "saisie" { LabeledContent("Origine", value: ["csv": "Relevé importé", "banque": "Banque", "capture": "Capture d'écran", "auto": "Saisie automatique"][s] ?? s) }
                }
                if op.partage != nil { Section { Text("Cette opération vient d'un groupe du Cercle : modifie-la depuis le groupe.").font(.footnote).foregroundStyle(.secondary) } }
                Section {
                    if op.partage == nil { Button("Modifier") { edition = true } }
                    Button("Supprimer", role: .destructive) { confirmer = true }
                }
            }
            .navigationTitle("Opération").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fermer") { fermer() } }
            .sheet(isPresented: $edition, onDismiss: { fermer() }) { SaisieView(edition: op) }
            .confirmationDialog("Supprimer cette opération ?", isPresented: $confirmer, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) { Task { await magasin.supprimer(op); fermer() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Export CSV au format du site (point-virgule, virgule décimale), partagé par la feuille iOS.
struct ExportCSV: Transferable {
    let texte: String
    /// Le texte est préparé tout de suite (sur l'écran), le fichier seulement au moment du partage.
    @MainActor init(ops: [Operation], magasin: Magasin) {
        var l = ["date;categorie;theme;montant;note;compte;vers_compte"]
        for o in ops {
            let montant = String(format: "%.2f", o.montant).replacingOccurrences(of: ".", with: ",")
            let champs = [o.date, o.cat.rawValue, o.sc, montant, o.note, magasin.nomCompte(o.compte), o.vers.map { magasin.nomCompte($0) } ?? ""]
            l.append(champs.map { $0.contains(";") ? "\"\($0)\"" : $0 }.joined(separator: ";"))
        }
        texte = "\u{feff}" + l.joined(separator: "\r\n")
    }
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { e in Data(e.texte.utf8) }
            .suggestedFileName("le-cercle-operations.csv")
    }
}
