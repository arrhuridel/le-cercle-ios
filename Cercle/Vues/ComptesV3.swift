import SwiftUI

/// Un compte ou un livret, tel qu'affiché dans Activité (design v3).
struct CompteV3: Identifiable, Hashable {
    let id: String          // clé du compte, ou « livret:Nom » pour un livret
    let nom: String, banque: String, type: String
    let solde: Double
    let variation: Double   // ce qui a bougé sur 30 jours
    let detail: String?     // placements : investi / disponible
    var large = false
    var logo: String { nom.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
    var estLivret: Bool { id.hasPrefix("livret:") }
}

extension Magasin {
    /// Comptes qui n'existent plus (demande d'Arthur du 07/11/2026).
    static let comptesMasques: Set<String> = ["Prêt Léandre"]

    /// Tous les comptes et livrets, avec leur solde : le compte courant, les autres comptes, les placements et les livrets.
    var comptesV3: [CompteV3] {
        let ops = toutes, il30 = J.plus(J.auj, jours: -30)
        var l: [CompteV3] = []
        for k in comptes where !Magasin.comptesMasques.contains(k) {
            let lui = ops.filter { $0.compte == k || ($0.cat == .virement && $0.vers == k) }
            guard !lui.isEmpty || k.isEmpty else { continue }
            let nom = nomCompte(k), bas = k.lowercased()
            let type = k.isEmpty || ["revolut", "boursobank"].contains(bas) ? "Courant" : (bas.contains("trade") || bas.contains("pea")) ? "Placement" : "Autre"
            var montant = self.solde(k), detail: String? = nil
            let variation = lui.filter { $0.date > il30 }.reduce(0) { $0 + Calc.effet($1, k) }
            if type == "Placement" {   // l'argent investi compte dans le solde (achats − ventes sur ce compte)
                let achats = lui.filter { $0.compte == k && $0.sc == "Investissement" }.reduce(0) { $0 + $1.montant }
                let ventes = lui.filter { $0.compte == k && $0.sc == "Vente placement" }.reduce(0) { $0 + $1.montant }
                let investi = achats - ventes
                detail = "dont \(Fmt.eur(investi, 0)) investis · \(Fmt.eur(montant)) disponibles"
                montant += investi
            }
            l.append(CompteV3(id: k.isEmpty ? "courant" : k, nom: nom, banque: k.isEmpty ? "Crédit Mutuel" : nom, type: type, solde: montant, variation: variation, detail: detail))
        }
        if let lv = livrets {
            for n in lv.noms {
                let s = lv.solde(n, le: J.auj)
                l.append(CompteV3(id: "livret:\(n)", nom: n, banque: "Crédit Mutuel", type: "Livret", solde: s, variation: s - lv.solde(n, le: il30), detail: nil))
            }
        }
        return l
    }
}

// MARK: - Activité (onglet 3) : tous les comptes

struct ComptesView: View {
    @Environment(Magasin.self) private var magasin
    @AppStorage("ordreComptes") private var ordreBrut = ""

    private func ordonner(_ l: [CompteV3]) -> [CompteV3] {
        let ordre = ordreBrut.split(separator: "|").map(String.init)
        var r = l.sorted { (ordre.firstIndex(of: $0.id) ?? 99) < (ordre.firstIndex(of: $1.id) ?? 99) }
        if !r.isEmpty { r[0].large = true }
        if r.count > 1 && (r.count - 1) % 2 == 1 { r[r.count - 1].large = true }   // pas de case vide
        return r
    }
    /// Les cartes rangées en lignes : une grande seule, ou deux petites côte à côte.
    private func lignes(_ l: [CompteV3]) -> [[CompteV3]] {
        var res: [[CompteV3]] = [], attente: [CompteV3] = []
        for c in l {
            if c.large { if !attente.isEmpty { res.append(attente); attente = [] }; res.append([c]) }
            else { attente.append(c); if attente.count == 2 { res.append(attente); attente = [] } }
        }
        if !attente.isEmpty { res.append(attente) }
        return res
    }

    var body: some View {
        let l = ordonner(magasin.comptesV3), total = l.reduce(0) { $0 + $1.solde }
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) { Text("Tous tes comptes").font(.subheadline).foregroundStyle(.secondary); Text("Activité").font(.largeTitle.bold()) }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        NavigationLink { ActiviteView() } label: { Label("Toutes les opérations", systemImage: "list.bullet").labelStyle(.iconOnly).frame(width: 44, height: 44).contentShape(.rect) }
                            .buttonStyle(.plain).verre(.clear.interactive(), in: .circle)
                        Text(Fmt.eur(total, 0)).font(.title2.bold()).monospacedDigit()
                    }
                }
                ForEach(Array(lignes(l).enumerated()), id: \.offset) { _, ligne in
                    HStack(spacing: 10) { ForEach(ligne) { c in carte(c).draggable(c.id).dropDestination(for: String.self) { ids, _ in deplacer(ids.first, vers: c.id, l) } } }
                        .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
            .background(FondView())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: CompteV3.self) { HistoriqueCompteView(compte: $0) }
            .refreshable { await magasin.rafraichir() }
        }
    }

    private func deplacer(_ id: String?, vers cible: String, _ l: [CompteV3]) -> Bool {
        var ids = l.map(\.id)
        guard let id, id != cible, let i = ids.firstIndex(of: id), let j = ids.firstIndex(of: cible) else { return false }
        ids.remove(at: i); ids.insert(id, at: j)
        withAnimation(.spring) { ordreBrut = ids.joined(separator: "|") }
        return true
    }

    private func carte(_ c: CompteV3) -> some View {
        NavigationLink(value: c) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(c.logo).font(.caption.weight(.bold)).frame(width: 34, height: 34).background(.white.opacity(0.12), in: .rect(cornerRadius: 11))
                    Spacer()
                    Text(c.type).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 3).background(.white.opacity(0.07), in: Capsule())
                }
                Spacer(minLength: 4)
                Text(c.nom).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(Fmt.eur(c.solde)).font(c.large ? .title.bold() : .title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(c.detail ?? "\(Fmt.eur(c.variation, signe: true)) sur 30 jours").font(.caption)
                    .foregroundStyle(c.detail == nil && c.variation > 0 ? Color.positif : .secondary).lineLimit(2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .surface(in: .rect(cornerRadius: 24))
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Historique d'un compte (seule la liste défile)

struct HistoriqueCompteView: View {
    @Environment(Magasin.self) private var magasin
    let compte: CompteV3
    @State private var recherche = ""
    @State private var filtre = "Tout"
    @State private var ouverte: Operation?

    struct Ligne: Identifiable { let id: String; let date: String; let titre: String; let sc: String; let montant: Double; let op: Operation? }

    private var lignes: [Ligne] {
        if compte.estLivret, let lv = magasin.livrets {
            let nom = String(compte.id.dropFirst(7))
            var l = (lv.lignes[nom] ?? []).enumerated().map { i, x in Ligne(id: "r\(i)", date: x.date, titre: x.libelle.isEmpty ? "Mouvement" : x.libelle.capitalized, sc: "Livret", montant: x.montant, op: nil) }
            l += lv.flux.enumerated().filter { $0.element.livret == nom && $0.element.jour > lv.finReleves }
                .map { i, f in Ligne(id: "f\(i)", date: f.jour, titre: f.delta > 0 ? "Versement" : "Retrait", sc: "Livret", montant: f.delta, op: nil) }
            return l.sorted { $0.date > $1.date }
        }
        let k = compte.id == "courant" ? "" : compte.id
        return magasin.toutes.filter { $0.compte == k || ($0.cat == .virement && $0.vers == k) }
            .map { Ligne(id: $0.id, date: $0.date, titre: $0.note.isEmpty ? $0.sc : $0.note, sc: $0.sc, montant: Calc.effet($0, k), op: $0) }
            .filter { abs($0.montant) > 0.004 }.sorted { $0.date > $1.date }
    }

    var body: some View {
        let toutes = lignes, il30 = J.plus(J.auj, jours: -30)
        let recentes = toutes.filter { $0.date > il30 }
        let q = recherche.sansAccents.lowercased()
        let vues = toutes.filter { l in
            (filtre == "Tout" || (filtre == "Dépenses" ? l.montant < 0 && l.op?.cat != .virement : filtre == "Entrées" ? l.montant > 0 && l.op?.cat != .virement : l.op?.cat == .virement))
            && (q.isEmpty || "\(l.titre) \(l.sc)".sansAccents.lowercased().contains(q))
        }
        let jours = Dictionary(grouping: vues, by: \.date).sorted { $0.key > $1.key }
        VStack(spacing: 10) {
            HStack(alignment: .bottom) {
                Text(compte.detail ?? "\(compte.banque) · \(toutes.count) opérations").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.eur(compte.solde)).font(.title.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            HStack(spacing: 8) {
                bloc("Entrées sur 30 jours", Fmt.eur(recentes.filter { $0.montant > 0 }.reduce(0) { $0 + $1.montant }, signe: true), .positif)
                bloc("Sorties sur 30 jours", Fmt.eur(recentes.filter { $0.montant < 0 }.reduce(0) { $0 + $1.montant }, signe: true), .primary)
            }
            Picker("Filtre", selection: $filtre) { ForEach(["Tout", "Dépenses", "Entrées", "Virements"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            List {
                ForEach(jours, id: \.key) { jour, l in
                    Section {
                        ForEach(l) { x in
                            Button { ouverte = x.op } label: {
                                HStack(spacing: 12) {
                                    Tuile(sc: x.sc)
                                    VStack(alignment: .leading, spacing: 1) { Text(x.titre).lineLimit(1); Text(x.sc).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    Text(Fmt.eur(x.montant, signe: true)).monospacedDigit().fontWeight(.semibold).foregroundStyle(x.montant > 0 ? Color.positif : .primary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        HStack { Text(J.libelleJour(jour)); Spacer(); Text(Fmt.eur(l.reduce(0) { $0 + $1.montant }, signe: true)).monospacedDigit() }
                    }
                }
                if vues.isEmpty { Text("Aucune opération").foregroundStyle(.secondary).listRowBackground(Color.clear) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 16)
        .background(FondView())
        .navigationTitle(compte.nom)
        .searchable(text: $recherche, prompt: "Rechercher une opération")
        .sheet(item: $ouverte) { DetailOperation(op: $0) }
    }

    private func bloc(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(t).font(.caption).foregroundStyle(.secondary); Text(v).font(.headline).monospacedDigit().foregroundStyle(c) }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).surface(in: .rect(cornerRadius: 18))
    }
}
