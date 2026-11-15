"""Synchronisation des banques (Enable Banking) vers la base du Cercle : site, web app et app iPhone lisent la même base.

    ..\\.venv\\Scripts\\python.exe banque\\synchro.py                 # simulation : montre ce qui serait ajouté, n'écrit RIEN
    ..\\.venv\\Scripts\\python.exe banque\\synchro.py --ecrire        # écrit, avec un journal pour annuler
    ..\\.venv\\Scripts\\python.exe banque\\synchro.py --jours 30      # regarde plus loin en arrière (7 jours par défaut)
    ..\\.venv\\Scripts\\python.exe banque\\synchro.py --annuler <journal.json>

Règles (vérifiées le 15/11/2026 sur les vraies opérations : 101 sur 102 étaient déjà en base, la dernière manquait vraiment) :
- seules les opérations comptabilisées sont prises (« en cours » ignorées : leur libellé change une fois passées) ;
- une opération déjà en base (même compte, même montant, à 4 jours près) n'est pas ajoutée : rien en double avec les relevés
  importés, les saisies à la main ou les virements programmés ; chaque ajout porte une clé `id_banque` unique en base ;
- un virement entre deux comptes d'Arthur (débit d'un côté, crédit de l'autre) devient UN « Virement interne » ;
- classement avec les règles des relevés (`releve.proposer`) ; Trade Republic (montant et date seulement) : achat = PEA,
  moins d'un euro reçu = intérêts, autre crédit = vente de placement (à vérifier) ;
- la carte BoursoBank (compte « CARD ») est ignorée : ses paiements sont déjà sur le compte courant BoursoBank.
Clés : EB_CLE (fichier .pem) ou EB_CLE_TEXTE ; connexions : imports/banque/sessions.json ou EB_SESSIONS (texte JSON) ;
base : SUPABASE_URL + SUPABASE_SECRET_KEY, sinon le secrets.toml local du site.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from collections import Counter
from datetime import date, datetime, timedelta
from pathlib import Path

ICI = Path(__file__).resolve().parent
# Sur l'ordinateur d'Arthur : site_web/banque (clé, connexions et journaux dans dashbord_depenses) ; sur GitHub : banque/ du dépôt
RACINE = ICI.parent.parent if (ICI.parent.parent / "imports").exists() else ICI
sys.path.insert(0, str(ICI))
sys.path.insert(1, str(ICI.parent))
import enable_banking as eb  # noqa: E402
from categories import CATEGORIE  # noqa: E402

os.environ.setdefault("EB_CLE", str(RACINE / f"{eb.APP_ID_DEFAUT}.pem"))
SESSIONS = RACINE / "imports" / "banque" / "sessions.json"
JOURNAUX = RACINE / "imports" / "banque"
ECART_JOURS = 4
PRENOM = os.environ.get("PROFIL_PRENOM", "Arthur")


def sessions() -> dict:
    if os.environ.get("EB_SESSIONS"):
        return json.loads(os.environ["EB_SESSIONS"])
    return json.loads(SESSIONS.read_text(encoding="utf-8"))


def client():
    from supabase import create_client
    if os.environ.get("SUPABASE_URL") and os.environ.get("SUPABASE_SECRET_KEY"):
        return create_client(os.environ["SUPABASE_URL"].rstrip("/").removesuffix("/rest/v1"), os.environ["SUPABASE_SECRET_KEY"])
    import tomllib
    s = tomllib.loads((RACINE / "site_web" / ".streamlit" / "secrets.toml").read_text(encoding="utf-8"))
    return create_client(s["SUPABASE_URL"].rstrip("/").removesuffix("/rest/v1").rstrip("/"), s["SUPABASE_KEY"])


def lire_tout(cl, pid: str) -> list[dict]:
    ops, debut = [], 0
    while True:   # PostgREST renvoie au plus 1 000 lignes par requête
        lot = cl.table("operations").select("*").eq("profil_id", pid).order("id").range(debut, debut + 999).execute().data
        ops += lot
        if len(lot) < 1000:
            return ops
        debut += 1000


# ---------- 1. Lignes des banques ----------

def lignes_banques(depuis: date) -> list[dict]:
    """Opérations comptabilisées de chaque compte relié, au format commun : compte, jour, montant signé (+ entrée), libellé."""
    lignes = []
    for banque, s in sessions().items():
        for c in s["comptes"]:
            if c.get("type") == "CARD":
                continue
            vus = Counter()
            for o in eb.operations(c["uid"], depuis):
                if o.get("status") != "BOOK":
                    continue
                jour = o.get("booking_date") or o.get("transaction_date") or o.get("value_date")
                if not jour or date.fromisoformat(jour[:10]) < depuis:   # Trade Republic renvoie aussi des opérations plus anciennes
                    continue
                montant = abs(float(o["transaction_amount"]["amount"])) * (1 if o["credit_debit_indicator"] == "CRDT" else -1)
                libelle = " ".join(o.get("remittance_information") or []).strip()
                base = f"{c['uid']}|{jour}|{montant:.2f}|{libelle}"
                vus[base] += 1   # deux opérations identiques le même jour : chacune garde sa propre clé
                cle = "eb:" + hashlib.sha1(f"{base}|{vus[base]}".encode()).hexdigest()[:20]
                lignes.append({"banque": banque, "compte": s["compte_base"], "jour": date.fromisoformat(jour[:10]),
                               "montant": round(montant, 2), "libelle": libelle, "cle": cle})
    return lignes


# ---------- 2. Déjà en base ? ----------

def effet(op: dict, compte: str) -> float:
    """Effet d'une opération de la base sur un compte (+ entrée, − sortie), comme le solde de l'app."""
    m = float(op["montant"])
    if op["categorie"] == "Virement":
        return (m if (op.get("vers_compte") or "") == compte and op.get("vers_compte") is not None else 0) - (m if (op.get("compte") or "") == compte else 0)
    if (op.get("compte") or "") != compte:
        return 0.0
    return m if op["categorie"] == "Revenu" else -m


def retirer_doublons(lignes: list[dict], base: list[dict]) -> tuple[list[dict], int]:
    """Garde les lignes absentes de la base. Un virement interne en base peut couvrir ses deux côtés (un par compte)."""
    cles = {o.get("id_banque") for o in base if o.get("id_banque")}
    pris, nouvelles, deja = set(), [], 0
    for l in sorted(lignes, key=lambda l: l["jour"]):
        if l["cle"] in cles:
            deja += 1
            continue
        cand = [o for o in base if (o["id"], l["compte"]) not in pris
                and abs(effet(o, l["compte"]) - l["montant"]) < 0.005
                and abs((date.fromisoformat(o["date_operation"][:10]) - l["jour"]).days) <= ECART_JOURS]
        if cand:
            o = min(cand, key=lambda o: abs((date.fromisoformat(o["date_operation"][:10]) - l["jour"]).days))
            pris.add((o["id"], l["compte"]))
            deja += 1
        else:
            nouvelles.append(l)
    return nouvelles, deja


# ---------- 3. Classement ----------

def operations_a_ajouter(nouvelles: list[dict], pid: str) -> list[dict]:
    import releve

    def ligne(l, sc, desc, compte, vers=None, jour=None, montant=None):
        return {"profil_id": pid, "date_operation": (jour or l["jour"]).isoformat(), "categorie": CATEGORIE[sc],
                "sous_categorie": sc, "montant": round(abs(montant if montant is not None else l["montant"]), 2),
                "description": desc, "compte": compte, "vers_compte": vers, "source": "banque", "id_banque": l["cle"]}

    restantes, ops = list(nouvelles), []
    # Virements entre ses propres comptes : un débit d'un côté, le même crédit de l'autre, à 4 jours près
    for d in [l for l in restantes if l["montant"] < 0]:
        c = next((x for x in restantes if x["montant"] > 0 and x["compte"] != d["compte"] and abs(x["montant"] + d["montant"]) < 0.005
                  and abs((x["jour"] - d["jour"]).days) <= ECART_JOURS), None)
        if c and d in restantes:
            restantes.remove(c); restantes.remove(d)
            nom = lambda k: k or "Crédit Mutuel"
            ops.append(ligne(d, "Virement interne", f"Vers {nom(c['compte'])}", d["compte"], c["compte"]))
    for l in restantes:
        if l["compte"] == "Trade Republic" and not l["libelle"]:
            if l["montant"] < 0:
                ops.append(ligne(l, "Investissement", "Achat PEA", "Trade Republic"))
            elif l["montant"] < 1:
                ops.append(ligne(l, "Intérêts & primes", "Intérêt", "Trade Republic"))
            else:
                ops.append(ligne(l, "Vente placement", "Vente (à vérifier)", "Trade Republic"))
            continue
        p = releve.proposer(releve.LigneReleve(0, l["jour"], l["montant"], l["libelle"], None), PRENOM)
        sc = p.get("sous_categorie") or ("Autre revenu" if l["montant"] > 0 else "Autre envie")
        if sc not in CATEGORIE:
            sc = "Autre revenu" if l["montant"] > 0 else "Autre envie"
        if CATEGORIE[sc] == "Virement":   # virement vers un compte non relié : on le garde comme saisi
            sc = "Autre épargne" if l["montant"] < 0 else "Retrait d'épargne"
        jour = p.get("date") if isinstance(p.get("date"), date) else None
        ops.append(ligne(l, sc, p.get("description") or l["libelle"][:60], l["compte"], jour=jour))
    return sorted(ops, key=lambda o: o["date_operation"])


# ---------- Programme ----------

def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    a = argparse.ArgumentParser()
    a.add_argument("--ecrire", action="store_true")
    a.add_argument("--jours", type=int, default=7)
    a.add_argument("--annuler")
    args = a.parse_args()

    cl = client()
    pid = cl.table("profils").select("id").ilike("prenom", PRENOM).execute().data[0]["id"]
    if args.annuler:
        j = json.loads(Path(args.annuler).read_text(encoding="utf-8"))
        cl.table("operations").delete().in_("id", j["ajouts"]).eq("profil_id", pid).execute()
        print(f"Annulé : {len(j['ajouts'])} opérations retirées.")
        return

    depuis = date.today() - timedelta(days=args.jours)
    lignes = lignes_banques(depuis)
    base = [o for o in lire_tout(cl, pid) if o["date_operation"][:10] >= (depuis - timedelta(days=ECART_JOURS + 6)).isoformat()]
    nouvelles, deja = retirer_doublons(lignes, base)
    ops = operations_a_ajouter(nouvelles, pid)

    print(f"Depuis le {depuis:%d/%m/%Y} : {len(lignes)} opérations à la banque, {deja} déjà en base, {len(ops)} à ajouter.")
    # Sur GitHub, le journal d'exécution d'un dépôt public est lisible par tous : jamais le détail des opérations, seulement les nombres
    for o in ([] if os.environ.get("GITHUB_ACTIONS") else ops):
        sens = "+" if o["categorie"] == "Revenu" else "→" if o["categorie"] == "Virement" else "−"
        compte = o["compte"] or "Crédit Mutuel"
        print(f"  {o['date_operation']}  {compte:<14} {sens}{o['montant']:>9.2f} €  {o['sous_categorie']:<20} {o['description']}"
              + (f" (vers {o['vers_compte'] or 'Crédit Mutuel'})" if o["categorie"] == "Virement" else ""))
    if not args.ecrire:
        print("\nSimulation : rien n'a été écrit. Ajoute --ecrire pour enregistrer." if ops else "\nRien à ajouter.")
        return
    if not ops:
        print("Rien à ajouter.")
        return
    JOURNAUX.mkdir(parents=True, exist_ok=True)
    chemin = JOURNAUX / f"journal_synchro_{datetime.now():%Y%m%d_%H%M%S}.json"
    ids = [r["id"] for r in cl.table("operations").insert(ops).execute().data]
    chemin.write_text(json.dumps({"ajouts": ids, "operations": ops}, ensure_ascii=False, indent=1), encoding="utf-8")
    print("")
    print(f"Écrit : {len(ids)} opérations ajoutées" + ("" if os.environ.get("GITHUB_ACTIONS") else f" · journal pour annuler : {chemin}"))


if __name__ == "__main__":
    try:
        main()
    except eb.ErreurBanque as e:
        print("Erreur banque :", e)
        sys.exit(1)
