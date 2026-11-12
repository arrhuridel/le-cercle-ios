import SwiftUI
import Charts

/// Abonnements et prélèvements détectés, calendrier des 5 prochaines semaines, saisie automatique.
struct PrelevementsView: View {
    @Environment(Magasin.self) private var magasin
    let recs: [Suivi.Recurrent]
    @State private var ouvert: Suivi.Recurrent?

    struct Famille { let titre: String; let garder: (Suivi.Recurrent) -> Bool }
    static let familles: [Famille] = [
        Famille(titre: "Abonnements") { $0.sc == "Abonnements" },
        Famille(titre: "Charges fixes") { $0.cat == .besoins },
        Famille(titre: "Autres dépenses régulières") { $0.cat == .envies && $0.sc != "Abonnements" },
        Famille(titre: "Épargne programmée") { $0.cat == .epargne },
        Famille(titre: "Revenus réguliers") { $0.cat == .revenu },
    ]

    var body: some View {
        let actifs = recs.filter(\.actif)
        let compense = actifs.filter { Ref.compensations[$0.sc].map { $0.1 != .epargne } ?? false }.reduce(0) { $0 + $1.parMois }
        let total = actifs.filter { $0.cat.estDepense }.reduce(0) { $0 + $1.parMois } - compense
        let abos = actifs.filter { $0.sc == "Abonnements" }
        let ech = Suivi.echeances(actifs, jusqua: J.plus(J.auj, jours: 34))
        Ecran {
            HStack {
                Kpi(titre: "Prélèvements", valeur: Fmt.eur(total, 0), sous: "par mois\(compense > 0 ? ", part remboursée déduite" : "") · \(Fmt.eur(total * 12, 0)) par an")
                Kpi(titre: "Abonnements", valeur: "\(abos.count)", sous: "\(Fmt.eur(abos.reduce(0) { $0 + $1.parMois }, 0)) par mois")
            }
            CarteVerre {
                Text("Les 5 prochaines semaines").font(.headline)
                Text("Un point par prélèvement attendu, vert pour un revenu").font(.footnote).foregroundStyle(.secondary)
                let lundi = J.plus(J.aujourdhui, jours: -J.jourSemaine(J.auj))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(["L", "M", "M", "J", "V", "S", "D"].indices, id: \.self) { i in Text(["L", "M", "M", "J", "V", "S", "D"][i]).font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                    ForEach(0..<35, id: \.self) { i in caseJour(J.iso(J.plus(lundi, jours: i)), ech) }
                }
            }
            ForEach(Self.familles, id: \.titre) { famille in
                let l = actifs.filter(famille.garder)
                if !l.isEmpty { TitreSection(texte: famille.titre); CarteVerre(espacement: 10) { ForEach(l) { ligne($0) } } }
            }
            let arretes = recs.filter { !$0.actif }
            if !arretes.isEmpty { TitreSection(texte: "Arrêtés"); CarteVerre(espacement: 10) { ForEach(arretes) { ligne($0) } } }
            Text("Détectés automatiquement : même catégorie, même note, au moins 3 fois, à intervalle régulier et pour un montant proche.").font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Prélèvements").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(ouvert?.nom ?? "", isPresented: Binding(get: { ouvert != nil }, set: { if !$0 { ouvert = nil } }), titleVisibility: .visible) {
            if let r = ouvert, r.actif, !magasin.planifiees.contains(where: { $0.sc == r.sc && $0.note.hasPrefix(r.nom) && $0.actif }) {
                Button("Saisir automatiquement chaque mois") {
                    let modele = magasin.ops.first { Suivi.cle($0) == r.cle }
                    Task { await magasin.enregistrer(Planifiee(id: UUID().uuidString.lowercased(), profilId: magasin.profil?.id ?? "", cat: r.cat, sc: r.sc, montant: r.montant,
                                                               note: modele?.note ?? r.nom, compte: r.compte, vers: nil, jour: r.jour, depuis: r.prochain, actif: true)) }
                }
            }
        } message: {
            if let r = ouvert { Text("\(Fmt.eur(r.montant)) \(r.mensuel ? "chaque mois, vers le \(r.jour)" : "chaque semaine") · \(Fmt.eur(r.annuel, 0)) par an") }
        }
    }

    /// Une case du calendrier : le numéro du jour, un point par échéance (orange = sortie, vert = revenu).
    private func caseJour(_ d: String, _ ech: [Suivi.Echeance]) -> some View {
        let l = ech.filter { $0.date == d }
        let sortie = l.contains { $0.r.cat != .revenu }
        let entree = l.contains { $0.r.cat == .revenu }
        let passe = d < J.auj, aujourdhui = d == J.auj
        let fond: Double = aujourdhui ? 0.15 : (passe ? 0 : 0.05)
        return VStack(spacing: 3) {
            Text("\(J.comp(J.date(d)).j)").font(.caption).monospacedDigit().fontWeight(aujourdhui ? .bold : .regular)
            HStack(spacing: 2) {
                if sortie { Circle().fill(Color.alerte).frame(width: 5, height: 5) }
                if entree { Circle().fill(Color.positif).frame(width: 5, height: 5) }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(Color.primary.opacity(fond), in: .rect(cornerRadius: 10))
        .opacity(passe ? 0.35 : 1)
    }

    private func ligne(_ r: Suivi.Recurrent) -> some View {
        Button { ouvert = r } label: {
            HStack(spacing: 12) {
                Tuile(sc: r.sc)
                VStack(alignment: .leading) {
                    Text(r.nom)
                    Text("\(r.mensuel ? "chaque mois, vers le \(r.jour)" : "chaque semaine") · \(r.actif ? "prochain \(J.court(r.prochain))" : "dernier \(J.court(r.dernier))")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) { Text(Fmt.eur(r.montant)).monospacedDigit().fontWeight(.semibold); Text("\(Fmt.eur(r.annuel, 0)) par an").font(.caption).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())   // toute la ligne réagit, pas seulement le texte
        }
        .buttonStyle(.plain)
    }
}

/// Patrimoine net (comptes, livrets, placements, groupes) et placements : parts × cours du jour.
struct PatrimoineView: View {
    @Environment(Magasin.self) private var magasin
    @State private var ajoutMouvement = false

    /// Cours d'un titre à une date : le dernier connu dans la table `cours` (rempli chaque nuit par le script de cours).
    private func cours(_ titre: String, _ date: String) -> Double? {
        magasin.cours.filter { $0.titre == titre && $0.date <= date }.max { $0.date < $1.date }?.prix
    }

    var body: some View {
        let ops = magasin.toutes
        let comptes = magasin.comptes.reduce(0) { $0 + magasin.solde($1) }
        // Livrets : soldes réels des relevés (comme le site) ; à défaut, la somme des virements
        let lv = magasin.livrets
        let livrets = lv?.total(le: J.auj) ?? max(ops.map(Calc.compense).filter { $0.sc == "Livret" }.reduce(0) { $0 + $1.montant }, 0)
        let verse = ops.map(Calc.compense).filter { $0.sc == "Investissement" }.reduce(0) { $0 + $1.montant }
        let titres = Dictionary(grouping: magasin.mouvements, by: \.titre)
        let positions = titres.map { t, l -> (titre: String, parts: Double, investi: Double, valeur: Double?) in
            let parts = l.reduce(0) { $0 + ($1.sens == "achat" ? $1.parts : -$1.parts) }
            let investi = l.reduce(0) { $0 + ($1.sens == "achat" ? 1 : -1) * $1.parts * ($1.prix ?? cours(t, $1.date) ?? 0) }
            return (t, parts, investi, cours(t, J.auj).map { $0 * parts })
        }.sorted { $0.titre < $1.titre }
        let valeur = positions.compactMap(\.valeur).reduce(0, +)
        let placements = positions.isEmpty ? verse : valeur
        Ecran {
            CarteVerre {
                Text("Patrimoine net").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Text(Fmt.eur(comptes + livrets + placements, 0)).grandChiffre(38, design: .default).frame(maxWidth: .infinity)
                Text("comptes \(Fmt.eur(comptes, 0)) · épargne livret \(Fmt.eur(livrets, 0)) · placements \(Fmt.eur(placements, 0))").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            CarteVerre {
                Text("Mon patrimoine dans le temps").font(.headline)
                let points = stride(from: 180, through: 0, by: -6).map { k -> (Date, Double) in
                    let d = J.plus(J.auj, jours: -k)
                    let c = magasin.comptes.reduce(0) { $0 + Calc.solde(ops, $1, jusqua: d, initial: magasin.soldesInitiaux[$1] ?? 0) }
                    let avant = Calc.entre(ops, "2000-01-01", d).map(Calc.compense).filter { $0.cat == .epargne }
                    let autres = avant.filter { $0.sc != "Livret" }.reduce(0) { $0 + $1.montant }
                    let livret = lv?.total(le: d) ?? avant.filter { $0.sc == "Livret" }.reduce(0) { $0 + $1.montant }
                    return (J.date(d), c + livret + autres)
                }
                Chart(points, id: \.0) { p in
                    AreaMark(x: .value("Jour", p.0), y: .value("€", p.1)).foregroundStyle(.linearGradient(colors: [.primary.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Jour", p.0), y: .value("€", p.1))
                }.frame(height: 160)
                Text("Comptes + livrets (soldes des relevés) + placements à leur montant versé.").font(.caption).foregroundStyle(.secondary)
            }
            TitreSection(texte: "Livrets")
            CarteVerre(espacement: 10) {
                if let lv {
                    ForEach(lv.noms, id: \.self) { n in
                        HStack { Pastille(symbole: "banknote.fill", teinte: .positif); Text(n); Spacer(); Text(Fmt.eur(lv.solde(n, le: J.auj))).monospacedDigit().fontWeight(.semibold) }
                    }
                    if let i = lv.interets.last { Text("Intérêts \(i.annee) : \(Fmt.eur(i.montant))").font(.footnote).foregroundStyle(.secondary) }
                    Text("D'après tes relevés jusqu'au \(J.court(lv.finReleves)), puis tes virements depuis le compte courant.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Aucun relevé de livret enregistré : le solde affiché est la somme de tes virements, qui ignore l'argent d'avant ton historique.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            TitreSection(texte: "Placements", action: ("Ajouter un mouvement", { ajoutMouvement = true }))
            CarteVerre(espacement: 10) {
                if positions.isEmpty {
                    Text("Versé sur tes placements depuis le début : \(Fmt.eur(verse, 0)).").font(.subheadline)
                    Text("Ajoute tes achats de titres (code de l'ETF, nombre de parts) pour suivre leur valeur au cours du jour.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(positions, id: \.titre) { p in
                    HStack(spacing: 12) {
                        Pastille(symbole: "chart.line.uptrend.xyaxis", teinte: .teal)
                        VStack(alignment: .leading) { Text(p.titre); Text("\(Fmt.nombre(p.parts, 2)) parts").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(p.valeur.map { Fmt.eur($0, 0) } ?? "cours inconnu").monospacedDigit().fontWeight(.semibold)
                            if let v = p.valeur { Text("\(Fmt.eur(v - p.investi, 0, signe: true))").font(.caption).foregroundStyle(v >= p.investi ? Color.positif : Color.negatif) }
                        }
                    }
                }
            }
            Text("Les cours sont enregistrés chaque nuit dans ta base par le script de cours (étape banque). En attendant, la valeur affichée est le montant versé.").font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Patrimoine").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $ajoutMouvement) { MouvementView() }
    }
}

struct MouvementView: View {
    @Environment(Magasin.self) private var magasin
    @Environment(\.dismiss) private var fermer
    @State private var titre = "CW8.PA"
    @State private var enveloppe = "PEA"
    @State private var achat = true
    @State private var parts = ""
    @State private var prix = ""
    @State private var date = Date()
    var body: some View {
        NavigationStack {
            Form {
                Picker("Sens", selection: $achat) { Text("Achat").tag(true); Text("Vente").tag(false) }.pickerStyle(.segmented)
                TextField("Code du titre (ex. CW8.PA)", text: $titre).textInputAutocapitalization(.characters)
                Picker("Enveloppe", selection: $enveloppe) { Text("PEA").tag("PEA"); Text("Compte-titres").tag("Compte-titres") }
                TextField("Nombre de parts", text: $parts).keyboardType(.decimalPad)
                TextField("Prix par part (vide = cours du jour)", text: $prix).keyboardType(.decimalPad)
                DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
            }
            .navigationTitle("Mouvement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { fermer() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        let p = Fmt.lire(parts); guard p > 0 else { return }
                        Task {
                            await magasin.enregistrer(MouvementTitre(id: UUID().uuidString.lowercased(), profilId: magasin.profil?.id ?? "", date: J.iso(date), titre: titre.uppercased(),
                                                                     enveloppe: enveloppe, sens: achat ? "achat" : "vente", parts: p, prix: Fmt.lire(prix) > 0 ? Fmt.lire(prix) : nil))
                            fermer()
                        }
                    }
                }
            }
        }
    }
}
