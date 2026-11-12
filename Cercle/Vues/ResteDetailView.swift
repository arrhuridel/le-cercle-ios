import SwiftUI

/// « Ce qu'il te reste » : le solde réel du compte courant retracé depuis la paie, au centime (même page que l'aperçu du 08/11).
struct ResteDetailView: View {
    @Environment(Magasin.self) private var magasin
    @State private var ouverts: Set<String> = []

    var body: some View {
        let r = magasin.resteReel
        ScrollView {
            VStack(spacing: 10) {
                // Le chiffre, comme la banque
                VStack(spacing: 4) {
                    Text("Sur ton compte courant").font(.subheadline).foregroundStyle(.secondary)
                    ChiffreAnime(valeur: r.solde, taille: 50, decimales: 2).foregroundStyle(r.solde < 0 ? Color.negatif : .primary)
                    Text("le même chiffre que ta banque").font(.footnote).foregroundStyle(.secondary)
                    Jauge(part: r.part, couleur: .primary, hauteur: 8).padding(.top, 10)
                    HStack {
                        Text("\(Fmt.eur(r.parJour, 0)) par jour · \(r.restants) jours")
                        Spacer()
                        Text("\(Int(r.part.rounded())) % déjà sorti").foregroundStyle(.secondary)
                    }
                    .font(.footnote.weight(.medium))
                }
                .padding(16).frame(maxWidth: .infinity)
                .surface(in: .rect(cornerRadius: 24))

                carte("Avant la paie", "déjà sur le compte") { ligne("=", .primary, "Solde la veille de la paie", nil, Fmt.eur(r.avant)) }
                carte("Reçu ce mois", "salaire + CAF") {
                    ForEach(r.recus) { x in ligne(x.nom == "CAF" ? "C" : "S", .positif, x.nom, "le \(x.detail)", "+" + Fmt.eur(x.montant), .positif) }
                    total("+" + Fmt.eur(r.totalRecus))
                }
                if !r.autres.isEmpty {
                    carte("Autres entrées", "hors salaire") {
                        ForEach(r.autres) { x in ligne(String(x.nom.prefix(1)), x.montant >= 0 ? .positif : .secondary, x.nom, nil, Fmt.eur(x.montant, signe: true), x.montant >= 0 ? .positif : nil) }
                        total(Fmt.eur(r.totalAutres, signe: true))
                    }
                }
                carte("Dépensé", "\(r.nbDepenses) opérations · touche") {
                    ForEach(r.depenses) { f in
                        let ouvert = ouverts.contains(f.nom)
                        Button { withAnimation(.smooth(duration: 0.3)) { if ouvert { ouverts.remove(f.nom) } else { ouverts.insert(f.nom) } } } label: {
                            HStack {
                                pastille(String(f.nom.prefix(1)), f.nom == "Besoins" ? .besoins : .envies)
                                Text(f.nom)
                                Spacer()
                                Text("−" + Fmt.eur(f.total)).monospacedDigit().fontWeight(.semibold)
                                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary).rotationEffect(.degrees(ouvert ? 90 : 0))
                            }
                            .frame(minHeight: 44).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(ouvert ? "Replie le détail" : "Affiche le détail par catégorie")
                        if ouvert {
                            ForEach(f.cats) { c in
                                HStack { Text(c.nom); Spacer(); Text(Fmt.eur(c.montant)).monospacedDigit() }
                                    .font(.subheadline).foregroundStyle(.secondary).padding(.leading, 42)
                            }
                        }
                    }
                    total("−" + Fmt.eur(r.totalDepenses))
                }
                if !r.epargne.isEmpty {
                    carte("Mis de côté", "sorti du compte") {
                        ForEach(r.epargne) { x in ligne(String(x.nom.prefix(1)), .epargneV3, x.nom, nil, "−" + Fmt.eur(x.montant)) }
                        total("−" + Fmt.eur(r.totalEpargne))
                    }
                }
                carte("Le calcul", nil) {
                    calcul("Avant la paie", Fmt.eur(r.avant))
                    calcul("Salaire + CAF", "+" + Fmt.eur(r.totalRecus))
                    if !r.autres.isEmpty { calcul("Autres entrées", Fmt.eur(r.totalAutres, signe: true)) }
                    calcul("Dépensé", "−" + Fmt.eur(r.totalDepenses))
                    if r.totalEpargne != 0 { calcul("Mis de côté", "−" + Fmt.eur(r.totalEpargne)) }
                    Divider()
                    HStack { Text("Sur ton compte").font(.headline); Spacer(); Text(Fmt.eur(r.solde)).font(.headline).monospacedDigit() }
                }
                carte("Fin du mois", "estimation au \(J.court(r.fin))") {
                    calcul("Sur ton compte", Fmt.eur(r.solde))
                    calcul("Prélèvements à venir", "−" + Fmt.eur(r.totalAVenir))
                    calcul("Dépenses courantes · \(Fmt.eur(r.rythme)) par jour × \(r.joursApres) j", "−" + Fmt.eur(r.courantesAVenir))
                    Divider()
                    HStack {
                        Text("Fin du mois").font(.headline); Spacer()
                        Text("≈ " + Fmt.eur(r.finMois)).font(.headline).monospacedDigit().foregroundStyle(r.finMois < 0 ? Color.alerte : .primary)
                    }
                    if !r.aVenir.isEmpty {
                        DisclosureGroup("Les \(r.aVenir.count) prélèvements à venir") {
                            ForEach(r.aVenir) { p in HStack { Text("\(p.nom) · le \(p.detail)"); Spacer(); Text(Fmt.eur(p.montant)).monospacedDigit() }.font(.subheadline).foregroundStyle(.secondary) }
                        }
                        .tint(.primary).font(.subheadline)
                    }
                }
                Text("Ici le loyer compte en entier, parce que c'est ce qui sort de ton compte, et le remboursement de ton coloc apparaît dans les autres entrées. Dans la règle 50-30-20, seule ta moitié du loyer compte. Objectif d'épargne du mois : \(Fmt.eur(r.objectifEpargne, 0)) (20 % de tous tes revenus).")
                    .font(.footnote).foregroundStyle(.secondary).padding(16)
                    .surface(in: .rect(cornerRadius: 24))
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(FondView())
        .navigationTitle("Ce qu'il te reste")
        .navigationBarTitleDisplayMode(.large)
    }

    private func carte<C: View>(_ titre: String, _ droite: String?, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(titre).font(.headline)
                Spacer()
                if let droite { Text(droite).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.bottom, 4)
            c()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .surface(in: .rect(cornerRadius: 24))
    }
    private func pastille(_ t: String, _ c: Color) -> some View {
        Text(t).font(.footnote.weight(.bold)).foregroundStyle(c).frame(width: 30, height: 30).background(c.opacity(0.2), in: .rect(cornerRadius: 10))
    }
    private func ligne(_ p: String, _ c: Color, _ titre: String, _ sous: String?, _ montant: String, _ couleur: Color? = nil) -> some View {
        HStack(spacing: 12) {
            pastille(p, c)
            VStack(alignment: .leading, spacing: 1) {
                Text(titre).lineLimit(1)
                if let sous { Text(sous).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(montant).monospacedDigit().fontWeight(.semibold).foregroundStyle(couleur ?? .primary)
        }
        .frame(minHeight: 44)
    }
    private func total(_ v: String) -> some View {
        VStack(spacing: 6) {
            Divider()
            HStack { Text("Total").fontWeight(.bold); Spacer(); Text(v).fontWeight(.bold).monospacedDigit() }
        }
        .padding(.top, 2)
    }
    private func calcul(_ a: String, _ b: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(a).foregroundStyle(.secondary).lineLimit(2); Spacer(); Text(b).monospacedDigit() }.font(.subheadline)
    }
}
