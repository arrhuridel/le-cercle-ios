import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Le conseiller : l'analyse (pistes chiffrées par le moteur de l'app) et une conversation.
/// Les réponses sont rédigées par le modèle d'Apple Intelligence installé sur l'iPhone (Foundation Models),
/// à partir de chiffres calculés par l'app. S'il n'est pas disponible, l'app formule elle-même la réponse.
struct ConseillerView: View {
    @Environment(Magasin.self) private var magasin
    @State private var messages: [Message] = []
    @State private var question = ""
    @State private var reflechit = false

    struct Message: Identifiable { let id = UUID(); let deMoi: Bool; let texte: String }
    private let suggestions = ["Où puis-je économiser ?", "Combien je peux dépenser ce week-end ?", "Analyse mes abonnements", "Comment va mon épargne ?", "Comparé au mois dernier ?"]

    var body: some View {
        let t = magasin.tableau(), recos = Conseil.recommandations(t)
        let total = recos.reduce(0) { $0 + $1.gain }
        ScrollViewReader { defilement in
            Ecran {
                Label(Modele.etat, systemImage: Modele.disponible ? "cpu" : "exclamationmark.triangle")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.quaternary.opacity(0.6), in: Capsule())
                TitreSection(texte: "Mon analyse")
                CarteVerre(espacement: 14) {
                    if recos.isEmpty { Text("Rien à signaler : continue comme ça.").foregroundStyle(.secondary) }
                    ForEach(recos) { r in
                        HStack(alignment: .top, spacing: 12) {
                            Pastille(symbole: r.symbole, teinte: .purple)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(r.titre).fontWeight(.semibold); Spacer(); if r.gain > 1 { Text("≈ \(Fmt.eur(r.gain, 0)) / mois").font(.caption.weight(.semibold)).foregroundStyle(Color.positif) } }
                                Text(r.texte).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if total > 1 { Text("En appliquant tout : environ \(Fmt.eur(total, 0)) par mois, soit \(Fmt.eur(total * 12, 0)) par an.").font(.footnote).foregroundStyle(.secondary) }
                TitreSection(texte: "Discuter")
                CarteVerre(espacement: 10) {
                    ForEach(messages) { m in
                        Text(m.texte).font(.subheadline).padding(10)
                            .background(m.deMoi ? Color.primary : Color.primary.opacity(0.07), in: .rect(cornerRadius: 16))
                            .foregroundStyle(m.deMoi ? Color(uiColor: .systemBackground) : .primary)
                            .frame(maxWidth: .infinity, alignment: m.deMoi ? .trailing : .leading)
                            .id(m.id)
                    }
                    if reflechit { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(suggestions, id: \.self) { s in Button(s) { envoyer(s) }.puce(false) } }
                    }
                    HStack {
                        TextField("Pose ta question…", text: $question).submitLabel(.send).onSubmit { envoyer(question) }
                        Button { envoyer(question) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("Envoyer la question").tint(.primary).disabled(question.isEmpty || reflechit)
                    }
                    .padding(12).background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16))
                }
                Text("Les chiffres sont calculés par l'app sur ton iPhone ; le modèle d'Apple ne fait que rédiger. Rien ne part sur Internet.").font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: messages.count) { _, _ in if let d = messages.last { withAnimation { defilement.scrollTo(d.id, anchor: .bottom) } } }
        }
        .navigationTitle("Conseiller").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if messages.isEmpty {
                messages = [Message(deMoi: false, texte: recos.isEmpty ? "Bonjour \(magasin.profil?.prenom ?? ""). Ton budget est bien tenu. Pose-moi une question."
                                    : "Bonjour \(magasin.profil?.prenom ?? ""). J'ai trouvé \(recos.count) pistes pour mieux gérer ton budget, jusqu'à \(Fmt.eur(total, 0)) par mois. Pose-moi une question.")]
            }
        }
    }

    private func envoyer(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !reflechit else { return }
        messages.append(Message(deMoi: true, texte: q))
        question = ""
        reflechit = true
        let faits = Faits.reponse(q, t: magasin.tableau(), profil: magasin.profil)
        Task {
            let texte = await Modele.rediger(question: q, faits: faits)
            messages.append(Message(deMoi: false, texte: texte))
            reflechit = false
        }
    }
}

/// Le modèle de langage d'Apple, sur l'iPhone. Disponible seulement si Apple Intelligence est activé.
enum Modele {
    static var disponible: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }
    static var etat: String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return "Modèle Apple actif · rien ne quitte ton iPhone"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence désactivé : réponses de l'app"
        case .unavailable(.modelNotReady): return "Modèle Apple en téléchargement : réponses de l'app"
        case .unavailable(.deviceNotEligible): return "Modèle Apple non disponible sur cet appareil"
        default: return "Modèle Apple indisponible : réponses de l'app"
        }
        #else
        return "Réponses calculées par l'app"
        #endif
    }

    /// Le modèle reçoit la question et les faits chiffrés ; il ne doit rien inventer ni recalculer.
    static func rediger(question: String, faits: String) async -> String {
        #if canImport(FoundationModels)
        if disponible {
            let session = LanguageModelSession(instructions: """
                Tu es le conseiller budgétaire de l'app Le Cercle. Réponds en français, en tutoyant, en 2 à 4 phrases simples.
                Utilise uniquement les faits fournis : ne calcule rien, n'invente aucun chiffre. Donne un conseil concret quand c'est utile.
                Tu n'es pas un conseiller en investissement : ne recommande aucun produit financier.
                """)
            if let r = try? await session.respond(to: "Question : \(question)\n\nFaits calculés par l'app :\n\(faits)") {
                return r.content
            }
        }
        #endif
        return faits
    }
}

/// Les faits chiffrés qui répondent à une question (reprise du conseiller du prototype).
enum Faits {
    static func reponse(_ q: String, t: Tableau, profil: Profil?) -> String {
        let n = q.sansAccents
        func a(_ mots: String...) -> Bool { mots.contains { n.contains($0) } }
        if a("econom", "ameliorer", "reduire", "conseil", "gerer") {
            let r = Conseil.recommandations(t).prefix(3)
            return r.isEmpty ? "Ton budget est bien tenu : rien d'évident à couper." : "Mes 3 priorités :\n" + r.enumerated().map { "\($0.offset + 1). \($0.element.titre) : \($0.element.texte)" }.joined(separator: "\n")
        }
        if a("week", "combien", "peux depenser", "reste", "par jour") {
            return "Il te reste \(Fmt.eur(t.budget - t.b.dep, 0)) de budget jusqu'au \(J.court(t.per.finBudget))" + (t.prev.depAVenir > 0 ? ", dont \(Fmt.eur(t.prev.depAVenir, 0)) déjà promis aux prélèvements à venir" : "") + ". Ça laisse \(Fmt.eur(t.prev.parJour, 0)) par jour : pour un week-end, vise \(Fmt.eur(t.prev.parJour * 2, 0)) au maximum."
        }
        if a("abonnement", "abo") {
            let l = Suivi.abonnements(t.ops), m = l.reduce(0) { $0 + $1.mensuel }
            return l.isEmpty ? "Je ne vois aucun abonnement actif." : "\(l.count) abonnements actifs pour \(Fmt.eur(m, 0)) par mois (\(Fmt.eur(m * 12, 0)) par an) : " + l.map { "\($0.nom) \(Fmt.eur($0.mensuel))" }.joined(separator: ", ") + ". Demande-toi lequel tu n'as pas utilisé ce mois-ci."
        }
        if a("epargn", "objectif", "livret", "cote") {
            return "Sur la période, tu as mis de côté \(Fmt.eur(t.b.epa, 0))" + (t.b.rev > 0 ? ", soit \(Fmt.pct(t.b.epa / t.b.rev * 100)) de tes revenus (repère : 20 %)" : "") + ". " + t.objectifs.map { "\($0.o.nom) : \(Fmt.eur($0.actuel, 0)) sur \(Fmt.eur($0.o.cible, 0))" + ($0.enRetard ? " (il faudrait \(Fmt.eur($0.parMois ?? 0, 0)) par mois)" : "") }.joined(separator: " · ")
        }
        if a("mois dernier", "compare", "evolution", "avant") {
            let bp = t.bp ?? Calc.Bilan(), d = t.b.dep - bp.dep
            return "\(t.per.libelle) : \(Fmt.eur(t.b.dep, 0)) dépensés, contre \(Fmt.eur(bp.dep, 0)) au même moment de la période précédente, soit \(Fmt.eur(abs(d), 0)) de \(d > 0 ? "plus" : "moins")."
        }
        if a("grosse", "plus cher", "gros achat") {
            let l = t.opsP.filter { $0.cat.estDepense }.sorted { $0.montant > $1.montant }.prefix(3)
            return l.isEmpty ? "Aucune dépense sur la période." : "Tes plus grosses dépenses de la période : " + l.map { "\($0.note.isEmpty ? $0.sc : $0.note) \(Fmt.eur($0.montant)) (\(J.court($0.date)))" }.joined(separator: ", ") + "."
        }
        if a("prevision", "fin du mois", "fin de mois", "decouvert") {
            return "À ce rythme, tu finirais la période vers \(Fmt.eur(t.prev.depFin, 0)) de dépenses pour un budget de \(Fmt.eur(t.budget, 0)), avec un solde d'environ \(Fmt.eur(t.prev.soldeFin, 0))."
        }
        if let theme = Ref.themes.first(where: { n.contains($0.nom.sansAccents) || n.contains($0.court.sansAccents) }) {
            let cur = t.opsP.map(Calc.compense).filter { $0.sc == theme.nom }.reduce(0) { $0 + $1.montant }
            let env = t.enveloppes.first { $0.e.sc == theme.nom }
            return "\(theme.nom) : \(Fmt.eur(cur, 0)) sur la période en cours." + (env.map { " Ton enveloppe est utilisée à \(Fmt.pct($0.part))." } ?? " Tu n'as pas d'enveloppe pour ce poste : en créer une aide à le suivre.")
        }
        return "En bref : \(Fmt.eur(t.b.dep, 0)) dépensés sur la période, \(Fmt.eur(max(t.budget - t.b.dep, 0), 0)) de budget restant. Je peux t'aider sur tes économies, tes abonnements, ton épargne, tes prévisions ou une catégorie précise."
    }
}
