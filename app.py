"""
Le Cercle — gestion privée entre amis (Streamlit + Supabase).

Chaque membre a son profil (prénom + code PIN), saisit ses revenus, dépenses et épargne,
et choisit ce que les autres peuvent voir : rien, un résumé, ou tout.
Interface minimaliste qui se comporte comme une application : en-tête et barre d'onglets fixes,
la page ne défile jamais (seul le contenu de l'écran défile), saisie au pavé numérique,
tableaux de bord et analyses de tout l'historique.

Lancement local :
    pip install -r requirements.txt
    streamlit run app.py

Secrets attendus (.streamlit/secrets.toml ou variables d'environnement sur Render) :
    APP_PASSWORD, SUPABASE_URL, SUPABASE_KEY

Organisation du fichier :
    1. Configuration & constantes
    2. Utilitaires (formatage, dates, PIN)
    3. Accès base de données (Supabase)
    4. Préparation & calculs (pandas)
    5. Design : feuille de style et composants HTML
    6. Graphiques (plotly)
    7. Écrans de connexion (mot de passe commun, profils)
    8. Interface connectée (menu profil + 5 onglets, dont les analyses)
    9. Point d'entrée
"""

from __future__ import annotations

import hashlib
import hmac
import math
import os
import re
import secrets
import time
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from functools import lru_cache
from html import escape
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st
from postgrest.exceptions import APIError
from supabase import Client, create_client

import releve

# =====================================================================
# 1. CONFIGURATION & CONSTANTES
# =====================================================================

ICONE = Path(__file__).with_name("static") / "icon-192.png"
st.set_page_config(page_title="Le Cercle · Gestion privée", page_icon=str(ICONE) if ICONE.exists() else ":material/donut_large:",
                   layout="wide")

VERSION_APP = "23 · appuis justes sur iPhone"  # à changer à chaque mise en ligne
MARQUE, SOUS_MARQUE = "Le Cercle", "Gestion privée"
FUSEAU = ZoneInfo("Europe/Paris")

TABLE_PROFILS = "profils"
TABLE_OPERATIONS = "operations"
COLONNES_PROFIL = "id,prenom,visibilite,budget_mensuel_max,objectif_epargne"

CAT_REVENU = "Revenu"
CAT_BESOINS = "50% - Besoins"
CAT_ENVIES = "30% - Envies"
CAT_EPARGNE = "20% - Épargne"
CAT_VIREMENT = "Virement"  # entre deux de ses propres comptes : ni revenu, ni dépense, ni épargne
CATEGORIES_SORTIES = [CAT_BESOINS, CAT_ENVIES, CAT_EPARGNE]
CATEGORIES_DEPENSES = [CAT_BESOINS, CAT_ENVIES]

# Comptes : chaque opération appartient à un compte. Le compte courant (celui dont l'app suit le solde,
# comparé à la banque) a un nom vide en base ; les autres portent leur nom (« Revolut », « Livret A »…).
# Un virement part de `compte` et arrive sur `vers_compte`.
COMPTE_COURANT = ""
NOM_COMPTE_COURANT = "Compte courant"
NOUVEAU_COMPTE = "＋ Nouveau compte"
SC_VIREMENT = "Virement interne"

# Règle 50-30-20 : part des revenus visée pour chaque catégorie (en %)
CIBLES = {CAT_BESOINS: 50.0, CAT_ENVIES: 30.0, CAT_EPARGNE: 20.0}
TOLERANCE_PTS = 5.0  # marge (en points de %) avant de signaler un écart

NOMS_COURTS = {CAT_REVENU: "Revenus", CAT_BESOINS: "Besoins", CAT_ENVIES: "Envies", CAT_EPARGNE: "Épargne",
               CAT_VIREMENT: "Virements"}
GROUPES = ["Besoins", "Envies", "Épargne"]

# Sous-catégorie -> (catégorie 50-30-20, icône Material). Le choix de la sous-catégorie
# détermine automatiquement la catégorie : un seul clic pour l'utilisateur.
SOUS_CATEGORIES: dict[str, tuple[str, str]] = {
    "Salaire": (CAT_REVENU, "work"),
    "Bourse & aides": (CAT_REVENU, "school"),
    "Aide familiale": (CAT_REVENU, "family_restroom"),
    "Job / freelance": (CAT_REVENU, "laptop_mac"),
    "Cadeau reçu": (CAT_REVENU, "redeem"),
    "Remboursement": (CAT_REVENU, "undo"),
    "Remboursement loyer": (CAT_REVENU, "home_work"),
    "Gains de jeux": (CAT_REVENU, "casino"),
    "Dépôt espèces": (CAT_REVENU, "payments"),
    "Intérêts & primes": (CAT_REVENU, "percent"),
    "Autre revenu": (CAT_REVENU, "add_circle"),
    "Retrait d'épargne": (CAT_REVENU, "move_up"),
    "Vente placement": (CAT_REVENU, "trending_down"),
    "Loyer": (CAT_BESOINS, "home"),
    "Courses": (CAT_BESOINS, "shopping_cart"),
    "Transport": (CAT_BESOINS, "train"),
    "Voiture": (CAT_BESOINS, "directions_car"),
    "Factures": (CAT_BESOINS, "bolt"),
    "Santé": (CAT_BESOINS, "medical_services"),
    "Assurances": (CAT_BESOINS, "shield"),
    "Études": (CAT_BESOINS, "menu_book"),
    "Frais bancaires": (CAT_BESOINS, "account_balance"),
    "Autre besoin": (CAT_BESOINS, "inventory_2"),
    "Restos & sorties": (CAT_ENVIES, "restaurant"),
    "Shopping": (CAT_ENVIES, "shopping_bag"),
    "Loisirs": (CAT_ENVIES, "sports_esports"),
    "Voyages": (CAT_ENVIES, "flight"),
    "Abonnements": (CAT_ENVIES, "subscriptions"),
    "Cadeaux offerts": (CAT_ENVIES, "card_giftcard"),
    "Jeux d'argent": (CAT_ENVIES, "casino"),
    "Espèces": (CAT_ENVIES, "local_atm"),
    "Autre envie": (CAT_ENVIES, "auto_awesome"),
    "Livret": (CAT_EPARGNE, "savings"),
    "Investissement": (CAT_EPARGNE, "trending_up"),
    "Projet": (CAT_EPARGNE, "flag"),
    "Autre épargne": (CAT_EPARGNE, "account_balance_wallet"),
    SC_VIREMENT: (CAT_VIREMENT, "sync_alt"),
}
# Icône de chaque thème (listes, pastilles de saisie), comme dans les applis de banque
EMOJIS = {
    "Salaire": "💼", "Bourse & aides": "🎓", "Aide familiale": "👪", "Job / freelance": "💻", "Cadeau reçu": "🎁",
    "Remboursement": "↩️", "Remboursement loyer": "🏠", "Gains de jeux": "🎰", "Dépôt espèces": "💵",
    "Intérêts & primes": "💹", "Autre revenu": "➕", "Retrait d'épargne": "🐷", "Vente placement": "📉",
    "Loyer": "🏠", "Courses": "🛒", "Transport": "🚆", "Voiture": "🚗", "Factures": "🧾", "Santé": "💊",
    "Assurances": "🛡️", "Études": "📚", "Frais bancaires": "🏦", "Autre besoin": "📦",
    "Restos & sorties": "🍽️", "Shopping": "🛍️", "Loisirs": "🎮", "Voyages": "✈️", "Abonnements": "📅",
    "Cadeaux offerts": "🎁", "Jeux d'argent": "🎲", "Espèces": "💶", "Autre envie": "✨",
    "Livret": "🐷", "Investissement": "📈", "Projet": "🎯", "Autre épargne": "💰", SC_VIREMENT: "🔁",
}

# Entrées d'argent qui compensent une sortie au lieu de compter comme un revenu :
# sous-catégorie saisie (côté Revenu) -> (sortie compensée, sa catégorie). Exemples :
#   loyer 907 € partagé, le colocataire rembourse 453,50 €  -> loyer net 453,50 €
#   200 € retirés du livret                                -> épargne nette −200 €
#   15 € gagnés au pari                                    -> jeux d'argent nets −15 €
COMPENSATIONS = {
    "Remboursement loyer": ("Loyer", CAT_BESOINS),
    "Gains de jeux": ("Jeux d'argent", CAT_ENVIES),
    "Dépôt espèces": ("Espèces", CAT_ENVIES),
    "Retrait d'épargne": ("Livret", CAT_EPARGNE),
    "Vente placement": ("Investissement", CAT_EPARGNE),
}

# Revenus réguliers servant de base à la règle 50-30-20. Les autres entrées (cadeaux, remboursements,
# petits jobs…) comptent dans le solde et le reste, mais pas dans la règle.
REVENUS_REFERENCE = {"Salaire", "Bourse & aides", "Aide familiale"}

# Dépenses qui ne tombent qu'une fois par mois : exclues du « rythme » quotidien
CHARGES_FIXES = {"Loyer", "Factures", "Assurances", "Abonnements", "Frais bancaires"}
SEUIL_EXCEPTIONNEL = 1000.0  # une dépense au-delà est un achat exceptionnel (voiture, ordinateur…)

# Virements entre le compte et l'épargne (livrets, placements) : ni revenu ni dépense, seulement de l'épargne
MOUVEMENTS_EPARGNE = {"Livret", "Investissement", "Projet", "Autre épargne", "Retrait d'épargne", "Vente placement"}

TYPES_OPERATION = ["Dépense", "Revenu", "Épargne", "Virement"]
CLES_TYPES = {"Dépense": "depense", "Revenu": "revenu", "Épargne": "epargne", "Virement": "virement"}  # sans accent


def type_saisie(nom: str) -> str:
    """Type proposé dans l'onglet Ajouter : un retrait d'épargne se range avec l'épargne."""
    cat = SOUS_CATEGORIES[nom][0]
    if cat == CAT_VIREMENT:
        return "Virement"
    if nom in COMPENSATIONS and COMPENSATIONS[nom][1] == CAT_EPARGNE or cat == CAT_EPARGNE:
        return "Épargne"
    return "Revenu" if cat == CAT_REVENU else "Dépense"


def type_affiche(categorie: str, sous_categorie: str) -> str:
    """Type montré à l'écran : un retrait du livret est de l'épargne (en négatif), pas un revenu."""
    if categorie == CAT_VIREMENT:
        return NOMS_COURTS[CAT_VIREMENT]
    if sous_categorie in MOUVEMENTS_EPARGNE:
        return "Épargne"
    return NOMS_COURTS.get(categorie, "")


VISIBILITES = {
    "prive": "Privé — personne ne voit mon budget",
    "resume": "Résumé — totaux et pourcentages, sans le détail",
    "tout": "Complet — résumé et détail des opérations",
}

ONGLETS = [":material/donut_large: Résumé", ":material/insights: Analyses", ":material/add: Ajouter",
           ":material/receipt_long: Activité", ":material/groups: Cercle"]
TITRES_ONGLETS = ["Résumé", "Analyses", "Nouvelle opération", "Activité", "Le Cercle"]
CLES_ECRANS = ["resume", "analyses", "ajouter", "activite", "cercle"]

TAILLE_PAGE = 1000            # nombre max de lignes renvoyées par requête PostgREST
PBKDF2_ITERATIONS = 200_000   # coût du hachage des PIN
MAX_ESSAIS_PIN = 5            # essais avant blocage temporaire
BLOCAGE_SECONDES = 60
COOKIE_SESSION = "budget_session"   # « se souvenir de cet appareil »
DUREE_SESSION_JOURS = 180

MOIS_FR = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet",
           "août", "septembre", "octobre", "novembre", "décembre"]
MOIS_COURTS = ["Janv.", "Févr.", "Mars", "Avr.", "Mai", "Juin", "Juil.", "Août", "Sept.", "Oct.", "Nov.", "Déc."]
JOURS_FR = ["lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim."]
JOURS_LONGS = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"]

# --- Couleurs -------------------------------------------------------------------------------
# Thème « ardoise » minimaliste. Les teintes des graphiques sont la palette de référence pour fond
# sombre, validée sur le fond des cartes (#1F252B) : bande de luminosité, saturation, séparation pour
# les daltoniens (ordre fixe des teintes), contraste. Une série seule prend la 1re teinte (ACCENT).
FOND, SURFACE, SURFACE_2 = "#14181C", "#1F252B", "#2A3138"   # SURFACE sert aussi d'espace entre les barres
ENCRE, ENCRE_2, MUET = "#F3F5F7", "#A7B0B9", "#717B85"
GRILLE, AXE = "rgba(243,245,247,0.06)", "rgba(243,245,247,0.16)"
PALETTE = ["#3987E5", "#D95926", "#199E70", "#C98500", "#D55181", "#008300", "#9085E9", "#E66767"]
ACCENT, ACCENT_CLAIR = PALETTE[0], "#86B6EF"
C_POS, C_NEG, C_ALERTE = "#3DD68C", "#FF6B6B", "#FFC145"   # textes d'état (toujours avec un mot ou une flèche)
SERIE = {"Revenus": PALETTE[6], "Besoins": PALETTE[0], "Envies": PALETTE[1], "Épargne": PALETTE[2],
         "Dépenses": PALETTE[7], "Pas encore utilisé": "#2E353D", "Autres": "#4A535C"}
COULEURS = SERIE
RAMPE = [[0.0, SURFACE], [0.25, "#184F95"], [0.55, "#2A78D6"], [0.8, "#5598E7"], [1.0, "#9EC5F4"]]

# Villes reconnues dans les libellés importés (« Burger King · Olivet »)
VILLES_CONNUES = {
    "Olivet", "Orléans", "Nantes", "Rezé", "Saint-Herblain", "Basse-Goulaine", "Piriac-sur-Mer",
    "La Tranche-sur-Mer", "Les Sables-d'Olonne", "Pont-Saint-Martin", "Saint-Sébastien", "Milan", "Stockholm",
    "Tours", "Guérande", "Montpellier", "La Baule", "Hossegor", "Capbreton", "Saint-Jean-de-Braye", "Périgny",
    "Saint-Étienne-de-Montluc", "Saint-Nazaire", "Trignac", "Pornic", "Vertou", "Ingré", "Saran", "La Rochelle",
    "La Roche-sur-Yon", "Angers", "Rennes", "Dijon", "Lyon", "Le Vigeant", "Talmont-Saint-Hilaire",
    "L'Île-d'Olonne", "Château-d'Olonne", "Montbert", "Geneston", "Bouaye", "Orvault", "Blain", "Mesquer",
    "Saint-Gildas", "Arzon", "Longeville-sur-Mer", "Le Bernard", "Thouaré-sur-Loire", "Montaigu",
    "Serre Chevalier", "L'Alpe d'Huez", "Les Adrets", "Moirans", "Bratislava", "Vienne", "Arles", "Agde",
    "Pérols", "Sète", "Bergame", "Chartres-de-Bretagne", "Poitiers", "Saumur", "Bourgueil", "Sainte-Pazanne",
    "Sainte-Anne-sur-Brivet", "La Turballe", "Paris", "Aigrefeuille", "Saint-Aubin", "La Ferrière",
    "Saint-Hilaire", "Saint-Hilaire-de-Riez", "Fleury-les-Aubrais", "Croix", "Saint-Pryvé",
    "Saint-Philbert-de-Grand-Lieu", "Saint-Viaud", "Saint-Jean", "Lesperon", "Labenne", "Saugon",
    "Les Sorinières", "La Montagne", "Mérieux", "Tillé", "Druye", "Noyal-Châtillon", "Saint-Martin",
    "Saint-Aunès", "Barbazan-Debat", "Lohéac", "Ruaudin", "Échirolles", "Verrières", "Saint-André",
    "Sargé-lès-le-Mans", "Meung", "Les Essarts", "Verneuil", "Longué-Jumelles", "Arzal",
}

# Noms saisis à la main -> nom unifié du marchand (pour regrouper « mcdo » et « McDonald's »)
ALIAS_MARCHANDS = {
    "mcdo": "McDonald's", "mc do": "McDonald's", "macdo": "McDonald's", "mc donald's": "McDonald's",
    "super u": "Super U", "o'tacos": "O'Tacos", "otacos": "O'Tacos", "bk": "Burger King",
    "crous repas": "Izly · Crous", "crous": "Izly · Crous", "uber": "Uber", "bouygues": "Forfait Bouygues",
    "5g box": "Box Bouygues", "salle": "Fitness Océane", "icloud": "iCloud+", "apple music": "Apple Music",
    "prime vidéo": "Amazon Prime", "prime video": "Amazon Prime", "loto": "FDJ", "betclic": "Betclic",
    "casino": "Casino", "warehouse": "Warehouse", "essence": "Carburant", "trade republic": "Trade Republic",
    "livret bleu": "Livret Bleu", "elec": "Électricité Alterna", "revolut": "Revolut", "aleop": "Aléop",
    "gemini pro": "Google One", "bicloo": "Bicloo", "carburant petro-ouest": "Carburant",
}
RE_JEUX = re.compile(r"casino|betclic|winamax|\bfdj\b|loto|\bpmu\b|paris sportifs|poker|unibet|b play|🎰", re.I)


# =====================================================================
# 2. UTILITAIRES
# =====================================================================

def fmt_eur(valeur: float, signe: bool = False) -> str:
    """Formate un montant à la française : 1 234,56 € (avec +/− si demandé)."""
    texte = f"{abs(float(valeur)) if signe else float(valeur):,.2f}"
    texte = texte.replace(",", " ").replace(".", ",") + " €"  # espaces insécables
    if signe:
        texte = ("+" if valeur >= 0 else "−") + texte
    return texte.replace("-", "−")


def fmt_eur0(valeur: float, signe: bool = False) -> str:
    """Montant arrondi à l'euro : 1 234 €."""
    texte = f"{abs(round(float(valeur))) if signe else round(float(valeur)):,.0f}".replace(",", " ") + " €"
    if signe:
        texte = ("+" if valeur >= 0 else "−") + texte
    return texte.replace("-", "−")


def fmt_pct(valeur: float) -> str:
    return f"{valeur:.0f} %".replace("-", "−")


def libelle_mois(periode: pd.Period) -> str:
    """« Octobre 2026 »"""
    return f"{MOIS_FR[periode.month - 1].capitalize()} {periode.year}"


def libelle_mois_court(periode: pd.Period) -> str:
    """« Oct. 26 »"""
    return f"{MOIS_COURTS[periode.month - 1]} {periode.year % 100:02d}"


def aujourdhui() -> date:
    """Date du jour à Paris (le serveur d'hébergement est à l'heure UTC)."""
    return datetime.now(FUSEAU).date()


def mois_courant() -> pd.Period:
    return pd.Period(aujourdhui(), freq="M")


# Libellés raccourcis pour les tuiles de saisie (le nom complet reste celui enregistré en base)
LIBELLES_TUILES = {
    "Abonnements": "Abos", "Remboursement loyer": "Rembours. loyer", "Retrait d'épargne": "Retrait",
    "Vente placement": "Vente", "Frais bancaires": "Frais banque", "Dépôt espèces": "Dépôt cash",
    "Bourse & aides": "Aides", "Aide familiale": "Famille", "Job / freelance": "Job",
    "Restos & sorties": "Restos", "Cadeaux offerts": "Cadeaux", "Jeux d'argent": "Jeux",
    "Gains de jeux": "Gains jeux", "Remboursement": "Rembours.", "Investissement": "Placement",
    "Intérêts & primes": "Intérêts",
}


def libelle_sous_categorie(nom: str) -> str:
    """« 🛒 Courses » (libellé court pour les pastilles de saisie)."""
    return f"{EMOJIS.get(nom, '•')} {LIBELLES_TUILES.get(nom, nom)}"


def est_mobile() -> bool:
    """Détecte un téléphone via l'en-tête User-Agent du navigateur."""
    try:
        agent = st.context.headers.get("User-Agent", "") or ""
    except Exception:
        return False
    return bool(re.search(r"iPhone|Android|Mobile", agent))


def lire_secret(nom: str) -> str | None:
    """Lit un secret : variable d'environnement (hébergeur type Render), sinon st.secrets.

    Ne lève jamais d'exception (fichier ou clé absents).
    """
    valeur = os.environ.get(nom)
    if not valeur:
        try:
            valeur = st.secrets[nom]
        except Exception:
            return None
    return str(valeur).strip() if valeur else None


def hacher_pin(pin: str) -> str:
    """Hache un PIN avec PBKDF2-SHA256 et un sel aléatoire : « pbkdf2$<sel>$<hash> »."""
    sel = secrets.token_bytes(16)
    empreinte = hashlib.pbkdf2_hmac("sha256", pin.encode(), sel, PBKDF2_ITERATIONS)
    return f"pbkdf2${sel.hex()}${empreinte.hex()}"


def pin_correct(pin: str, stocke: str) -> bool:
    """Vérifie un PIN contre son hachage (comparaison en temps constant)."""
    try:
        _, sel_hex, empreinte_hex = stocke.split("$")
        calcul = hashlib.pbkdf2_hmac("sha256", pin.encode(), bytes.fromhex(sel_hex), PBKDF2_ITERATIONS)
    except (ValueError, AttributeError):
        return False
    return hmac.compare_digest(calcul.hex(), empreinte_hex)


def pin_valide(pin: str) -> bool:
    return bool(re.fullmatch(r"\d{4,6}", pin or ""))


def notifier(message: str) -> None:
    """Mémorise un message affiché en toast après le prochain st.rerun()."""
    st.session_state["flash"] = message


def afficher_notification() -> None:
    message = st.session_state.pop("flash", None)
    if message:
        st.toast(message, icon=":material/check_circle:")


# =====================================================================
# 3. ACCÈS BASE DE DONNÉES (SUPABASE)
# =====================================================================

class ErreurBaseDeDonnees(Exception):
    """Erreur avec un message lisible par l'utilisateur."""


def message_erreur_db(exc: Exception) -> str:
    """Traduit une exception technique en message clair."""
    if isinstance(exc, ErreurBaseDeDonnees):
        return str(exc)
    if isinstance(exc, APIError):
        code = str(exc.code or "")
        if code in {"PGRST205", "42P01", "PGRST204", "42703"}:
            return ("Les tables de la base ne sont pas à jour. "
                    "Exécutez le script `schema.sql` dans le SQL Editor de Supabase.")
        if code == "PGRST125":
            return ("URL Supabase incorrecte : `SUPABASE_URL` doit être de la forme "
                    "`https://xxxx.supabase.co`, sans chemin après `.co`.")
        if code == "23505":
            return "Ce prénom est déjà utilisé : choisis-en un autre."
        if code == "23514":
            return "La base a refusé l'opération : une valeur ne respecte pas les règles (montant, catégorie…)."
        if code == "42501" and "row-level security" in str(exc.message):
            return ("Écriture bloquée par la sécurité RLS de Supabase. "
                    "Exécutez la dernière version de `schema.sql` (section 3) dans le SQL Editor.")
        if code in {"42501", "401", "PGRST301"}:
            return "Accès refusé par Supabase : vérifiez `SUPABASE_KEY` et les droits (GRANT) du script SQL."
        return f"Erreur Supabase ({code or 'inconnue'}) : {exc.message}"
    texte = str(exc)
    if "Invalid API key" in texte or "401" in texte:
        return "Clé Supabase invalide : vérifiez `SUPABASE_KEY` dans les secrets."
    return ("Impossible de joindre Supabase. Vérifiez votre connexion Internet, "
            f"`SUPABASE_URL` et que le projet n'est pas en pause. (Détail : {type(exc).__name__})")


@st.cache_resource(show_spinner=False)
def get_client() -> Client:
    """Crée (une seule fois par processus) le client Supabase à partir des secrets."""
    url = lire_secret("SUPABASE_URL")
    cle = lire_secret("SUPABASE_KEY")
    if not url or not cle:
        raise ErreurBaseDeDonnees(
            "Les secrets `SUPABASE_URL` et/ou `SUPABASE_KEY` sont manquants dans `.streamlit/secrets.toml`."
        )
    # Tolère une URL copiée avec le chemin de l'API (ex. ".../rest/v1/") : le client l'ajoute lui-même
    url = url.rstrip("/").removesuffix("/rest/v1").rstrip("/")
    return create_client(url, cle)


def _lire_tout(requete_fabrique) -> list[dict]:
    """Exécute une requête page par page (PostgREST limite à 1000 lignes par réponse)."""
    lignes: list[dict] = []
    debut = 0
    while True:
        lot = requete_fabrique().range(debut, debut + TAILLE_PAGE - 1).execute().data or []
        lignes.extend(lot)
        if len(lot) < TAILLE_PAGE:
            return lignes
        debut += TAILLE_PAGE


@st.cache_data(ttl=60, show_spinner=False)
def charger_profils() -> pd.DataFrame:
    """Liste des profils (sans le hachage des PIN), mise en cache 60 s."""
    lignes = _lire_tout(lambda: get_client().table(TABLE_PROFILS).select(COLONNES_PROFIL).order("prenom"))
    return preparer_profils(pd.DataFrame(lignes))


@st.cache_data(ttl=60, show_spinner=False)
def charger_operations(profil_ids: tuple[str, ...]) -> pd.DataFrame:
    """Opérations des profils demandés uniquement (les profils privés des autres ne sont jamais chargés)."""
    if not profil_ids:
        return preparer_operations(pd.DataFrame())
    lignes = _lire_tout(
        lambda: get_client().table(TABLE_OPERATIONS).select("*")
        .in_("profil_id", list(profil_ids)).order("date_operation", desc=True).order("id")
    )
    return preparer_operations(pd.DataFrame(lignes))


@st.cache_data(ttl=60, show_spinner=False)
def charger_objectifs_epargne(profil_id: str) -> dict[str, float]:
    """Objectifs par catégorie d'épargne (ex. {"Livret": 3000}). Colonne lue à part : si le script SQL
    qui l'ajoute n'a pas encore été exécuté, seule cette fonction échoue, pas toute l'application."""
    rep = get_client().table(TABLE_PROFILS).select("objectifs_epargne").eq("id", profil_id).limit(1).execute()
    valeurs = (rep.data[0].get("objectifs_epargne") if rep.data else None) or {}
    return {nom: float(v) for nom, v in valeurs.items() if v}


@st.cache_data(ttl=60, show_spinner=False)
def charger_regles_import(profil_id: str) -> dict[str, list[str]]:
    """Corrections retenues lors des imports : libellé bancaire -> [catégorie, note]. Colonne lue à part :
    tant que `schema.sql` (v15) n'a pas été exécuté, l'import marche mais n'apprend pas de tes corrections."""
    rep = get_client().table(TABLE_PROFILS).select("regles_import").eq("id", profil_id).limit(1).execute()
    return (rep.data[0].get("regles_import") if rep.data else None) or {}


@st.cache_data(ttl=60, show_spinner=False)
def charger_avoirs(profil_id: str) -> dict:
    """Relevés des livrets enregistrés ({"Livret Bleu": {"lignes": [[date, montant, solde, libellé], …]}}).
    Colonne lue à part : sans le script `schema.sql` (v17), seule cette fonction échoue."""
    rep = get_client().table(TABLE_PROFILS).select("avoirs").eq("id", profil_id).limit(1).execute()
    return (rep.data[0].get("avoirs") if rep.data else None) or {}


@st.cache_data(ttl=300, show_spinner=False)
def colonnes_comptes() -> bool:
    """Les colonnes `compte` et `vers_compte` existent-elles ? (ajoutées par `schema.sql` v18). Sans elles,
    tout reste sur le compte courant et la saisie ne propose ni autre compte ni virement."""
    try:
        get_client().table(TABLE_OPERATIONS).select("compte,vers_compte").limit(1).execute()
    except Exception:  # noqa: BLE001
        return False
    return True


def avoirs_ou_rien(profil_id: str) -> dict | None:
    """Les relevés des livrets, {} s'il n'y en a pas encore, None si la colonne n'existe pas en base."""
    try:
        return charger_avoirs(profil_id)
    except Exception:  # noqa: BLE001
        return None


def renommer_operations(renommages: list[tuple[str, str]], profil_id: str) -> None:
    """Change la note de plusieurs opérations (ex. « Depuis mon livret » -> « Depuis le Livret Bleu »)."""
    for op_id, note in renommages:
        get_client().table(TABLE_OPERATIONS).update({"description": note}).eq("id", op_id).eq("profil_id", profil_id) \
            .execute()
    vider_cache()


def vider_cache() -> None:
    """Force le rechargement des données après une écriture."""
    charger_profils.clear()
    charger_avoirs.clear()
    charger_operations.clear()
    charger_objectifs_epargne.clear()
    charger_regles_import.clear()
    colonnes_comptes.clear()
    index_historique.clear()
    raccourcis_frequents.clear()


def lire_pin_hash(profil_id: str) -> str | None:
    """Lit le hachage du PIN directement en base (jamais mis en cache)."""
    rep = get_client().table(TABLE_PROFILS).select("pin_hash").eq("id", profil_id).limit(1).execute()
    return rep.data[0]["pin_hash"] if rep.data else None


def creer_profil(prenom: str, pin_hash: str, visibilite: str) -> str:
    """Crée un profil (PIN déjà haché) et retourne son identifiant."""
    rep = get_client().table(TABLE_PROFILS).insert({
        "prenom": prenom, "pin_hash": pin_hash, "visibilite": visibilite,
    }).execute()
    vider_cache()
    return rep.data[0]["id"]


def modifier_profil(profil_id: str, **champs) -> None:
    get_client().table(TABLE_PROFILS).update(champs).eq("id", profil_id).execute()
    vider_cache()


def _ligne_operation(sous_categorie: str, montant: float, jour: date, description: str,
                     compte: str = COMPTE_COURANT, vers: str | None = None) -> dict:
    """Ligne à écrire en base. `vers` : compte d'arrivée d'un virement (None pour les autres opérations)."""
    virement = SOUS_CATEGORIES[sous_categorie][0] == CAT_VIREMENT
    if virement and (vers is None or vers == compte):
        raise ErreurBaseDeDonnees("Un virement doit aller d'un compte vers un autre compte.")
    ligne = {
        "categorie": SOUS_CATEGORIES[sous_categorie][0],
        "sous_categorie": sous_categorie,
        "montant": round(float(montant), 2),
        "date_operation": jour.isoformat(),
        "description": description.strip(),
    }
    if colonnes_comptes():
        ligne |= {"compte": compte.strip(), "vers_compte": vers.strip() if virement else None}
    elif compte or virement:
        raise ErreurBaseDeDonnees("Pour utiliser plusieurs comptes, exécute d'abord la dernière version de "
                                  "schema.sql dans Supabase.")
    return ligne


def ajouter_operation(profil_id: str, sous_categorie: str, montant: float, jour: date, description: str,
                      compte: str = COMPTE_COURANT, vers: str | None = None) -> str:
    """Enregistre une opération et retourne son identifiant (pour pouvoir l'annuler)."""
    ligne = _ligne_operation(sous_categorie, montant, jour, description, compte, vers)
    rep = get_client().table(TABLE_OPERATIONS).insert({"profil_id": profil_id, **ligne}).execute()
    vider_cache()
    return rep.data[0]["id"]


def ajouter_operations(profil_id: str, lignes: list[dict]) -> int:
    """Enregistre plusieurs opérations d'un coup (import du relevé), par paquets de 500."""
    nb = 0
    for i in range(0, len(lignes), 500):
        paquet = [{"profil_id": profil_id, **_ligne_operation(l["sous_categorie"], l["montant"], l["jour"],
                                                              l["description"], l.get("compte", COMPTE_COURANT),
                                                              l.get("vers"))} for l in lignes[i:i + 500]]
        nb += len(get_client().table(TABLE_OPERATIONS).insert(paquet).execute().data or [])
    vider_cache()
    return nb


def modifier_operation(op_id: str, profil_id: str, sous_categorie: str, montant: float,
                       jour: date, description: str, compte: str = COMPTE_COURANT, vers: str | None = None) -> None:
    """Modifie une opération — le filtre sur profil_id empêche de toucher à celles des autres."""
    ligne = _ligne_operation(sous_categorie, montant, jour, description, compte, vers)
    get_client().table(TABLE_OPERATIONS).update(ligne).eq("id", op_id).eq("profil_id", profil_id).execute()
    vider_cache()


def supprimer_operations(op_ids: list[str], profil_id: str) -> None:
    for i in range(0, len(op_ids), 200):
        get_client().table(TABLE_OPERATIONS).delete().in_("id", op_ids[i:i + 200]).eq("profil_id", profil_id).execute()
    vider_cache()


def supprimer_operation(op_id: str, profil_id: str) -> None:
    get_client().table(TABLE_OPERATIONS).delete().eq("id", op_id).eq("profil_id", profil_id).execute()
    vider_cache()


def executer(action, *args, succes: str | None = None, **kwargs) -> bool:
    """Exécute une écriture en base ; affiche une erreur claire en cas d'échec."""
    try:
        action(*args, **kwargs)
    except Exception as exc:  # noqa: BLE001 — on veut un message clair quelle que soit l'erreur
        st.error(message_erreur_db(exc))
        return False
    if succes:
        notifier(succes)
    return True


def stopper_sur_erreur(exc: Exception) -> None:
    """Affiche l'erreur de connexion avec un bouton « Réessayer », puis arrête le script."""
    st.error(f"Connexion à la base de données impossible.\n\n{message_erreur_db(exc)}")
    if st.button("Réessayer", icon=":material/refresh:"):
        vider_cache()
        get_client.clear()
        st.rerun()
    st.stop()


# =====================================================================
# 4. PRÉPARATION & CALCULS (PANDAS)
# =====================================================================

COLONNES_OPERATIONS = ["id", "created_at", "date_operation", "profil_id",
                       "categorie", "sous_categorie", "montant", "description", "compte", "vers_compte"]
JOURS_PAR_MOIS = 30.44


def preparer_profils(df: pd.DataFrame) -> pd.DataFrame:
    colonnes = COLONNES_PROFIL.split(",")
    if df.empty:
        df = pd.DataFrame(columns=colonnes)
    df = df.reindex(columns=colonnes).copy()
    for col in ("id", "prenom", "visibilite"):
        df[col] = df[col].fillna("").astype(str)
    for col in ("budget_mensuel_max", "objectif_epargne"):
        df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0.0).astype(float)
    return df


def preparer_operations(df: pd.DataFrame) -> pd.DataFrame:
    """Garantit les colonnes et les types (montants en float, dates en datetime)."""
    if df.empty:
        df = pd.DataFrame(columns=COLONNES_OPERATIONS)
    df = df.reindex(columns=COLONNES_OPERATIONS).copy()
    df["montant"] = pd.to_numeric(df["montant"], errors="coerce").fillna(0.0).astype(float)
    df["date_operation"] = pd.to_datetime(df["date_operation"], errors="coerce")
    df["created_at"] = pd.to_datetime(df["created_at"], utc=True, errors="coerce", format="ISO8601")
    for col in ("id", "profil_id", "categorie", "sous_categorie", "description", "compte", "vers_compte"):
        df[col] = df[col].fillna("").astype(str)  # sans les colonnes v18 : tout est sur le compte courant
    df = df.dropna(subset=["date_operation"])
    df["mois"] = df["date_operation"].dt.to_period("M")
    return df.sort_values(["date_operation", "created_at"], ascending=False).reset_index(drop=True)


def compenser(df: pd.DataFrame) -> pd.DataFrame:
    """Vue « calculs » : une entrée qui compense une sortie devient cette sortie, en négatif.

    Ex. un remboursement de loyer réduit le loyer (et les besoins) au lieu de gonfler les revenus ;
    un retrait du livret réduit l'épargne nette. L'historique, lui, continue d'afficher l'opération
    telle qu'elle a été saisie. Sans effet si déjà appliqué.
    """
    masque = df["sous_categorie"].isin(list(COMPENSATIONS))
    if not masque.any():
        return df
    df = df.copy()
    cibles = df.loc[masque, "sous_categorie"].map(COMPENSATIONS)
    df.loc[masque, "categorie"] = cibles.str[1]
    df.loc[masque, "sous_categorie"] = cibles.str[0]
    df.loc[masque, "montant"] = -df.loc[masque, "montant"]
    return df


def bilan(df: pd.DataFrame) -> dict[str, float]:
    """Totaux d'une période : revenus, besoins, envies, épargne, dépenses, reste
    et « reference » (salaire + aides : la base de la règle 50-30-20)."""
    comp = compenser(df)
    sommes = comp.groupby("categorie")["montant"].sum()
    total = {cat: float(sommes.get(cat, 0.0)) for cat in (CAT_REVENU, *CATEGORIES_SORTIES)}
    depenses = total[CAT_BESOINS] + total[CAT_ENVIES]
    reference = comp.loc[(comp["categorie"] == CAT_REVENU) & comp["sous_categorie"].isin(REVENUS_REFERENCE),
                         "montant"].sum()
    return {
        **total,
        "depenses": depenses,
        "reste": total[CAT_REVENU] - depenses - total[CAT_EPARGNE],
        "reference": float(reference),
    }


def analyse_regle(b: dict[str, float]) -> tuple[dict[str, float], list[str]]:
    """Part de chaque catégorie dans les revenus de référence (salaire + aides) et écarts à la règle.

    Sans salaire ni aide sur la période, on se rabat sur le total des sorties pour garder un repère.
    """
    base = b["reference"] or sum(max(b[c], 0.0) for c in CATEGORIES_SORTIES)
    parts = {c: (b[c] / base * 100 if base > 0 else 0.0) for c in CATEGORIES_SORTIES}
    problemes = []
    if parts[CAT_BESOINS] > CIBLES[CAT_BESOINS] + TOLERANCE_PTS:
        problemes.append("besoins trop élevés")
    if parts[CAT_ENVIES] > CIBLES[CAT_ENVIES] + TOLERANCE_PTS:
        problemes.append("envies trop élevées")
    if parts[CAT_EPARGNE] < CIBLES[CAT_EPARGNE] - TOLERANCE_PTS:
        problemes.append("épargne insuffisante")
    return parts, problemes


def montant_signe(df: pd.DataFrame, compte: str = COMPTE_COURANT) -> pd.Series:
    """Effet de chaque opération sur un compte (le compte courant par défaut) : + pour l'argent qui entre
    (revenus), − pour l'argent qui sort (dépenses, épargne). Une opération d'un autre compte compte pour 0 ;
    un virement compte en − sur le compte de départ et en + sur le compte d'arrivée."""
    montant = df["montant"]
    comptes = df["compte"] if "compte" in df else pd.Series(COMPTE_COURANT, index=df.index)
    vers = df["vers_compte"] if "vers_compte" in df else pd.Series(COMPTE_COURANT, index=df.index)
    virement = df["categorie"] == CAT_VIREMENT
    effet = montant.where(df["categorie"] == CAT_REVENU, -montant).where(comptes == compte, 0.0)
    return effet.where(~virement, montant.where(vers == compte, 0.0) - montant.where(comptes == compte, 0.0))


def solde_jusqua(df_comp: pd.DataFrame, jour: date, compte: str = COMPTE_COURANT) -> float:
    """Argent sur un compte à la fin d'un jour : entrées − sorties de toutes ses opérations saisies."""
    jusque = df_comp[df_comp["date_operation"] <= pd.Timestamp(jour)]
    return float(montant_signe(jusque, compte).sum())


def nom_compte(compte: str) -> str:
    return compte or NOM_COMPTE_COURANT


def comptes_de(df: pd.DataFrame) -> list[str]:
    """Les comptes de la personne : le compte courant d'abord, puis les autres du plus au moins utilisé."""
    noms = pd.concat([df["compte"], df.loc[df["categorie"] == CAT_VIREMENT, "vers_compte"]])
    autres = noms[noms != COMPTE_COURANT].value_counts()
    return [COMPTE_COURANT, *autres.index]


def touche_compte(df: pd.DataFrame, compte: str) -> pd.Series:
    """Opérations qui font bouger un compte : les siennes et les virements qui en partent ou y arrivent."""
    return (df["compte"] == compte) | ((df["categorie"] == CAT_VIREMENT) & (df["vers_compte"] == compte))


def soldes_comptes_jour(df_comp: pd.DataFrame, comptes: list[str], debut: date, fin: date) -> pd.DataFrame:
    """Solde de chaque compte à la fin de chaque jour (une colonne par compte)."""
    jours = pd.date_range(debut, fin, freq="D")
    quand = df_comp["date_operation"].dt.normalize()
    premier = min(quand.min(), pd.Timestamp(debut)) if len(df_comp) else pd.Timestamp(debut)
    tous = pd.date_range(premier, pd.Timestamp(fin), freq="D")
    return pd.DataFrame({
        c: montant_signe(df_comp, c).groupby(quand).sum().reindex(tous, fill_value=0.0).cumsum().reindex(jours)
        for c in comptes}, index=jours)


@dataclass(frozen=True)
class Periode:
    """Intervalle affiché par les tableaux de bord (bornes incluses)."""
    debut: date
    fin: date
    libelle: str
    cycle: bool = False                           # cycle de paie (d'une paie à la veille de la suivante)
    cycle_precedent: "Periode | None" = None      # même nombre de jours, au début du cycle précédent

    @property
    def nb_jours(self) -> int:
        return (self.fin - self.debut).days + 1

    @property
    def est_mois_complet(self) -> bool:
        mois = pd.Period(self.debut, freq="M")
        return self.debut == mois.start_time.date() and self.fin == mois.end_time.date()

    def filtrer(self, df: pd.DataFrame) -> pd.DataFrame:
        return df[df["date_operation"].between(pd.Timestamp(self.debut), pd.Timestamp(self.fin))]

    def precedente(self) -> "Periode":
        """Période de même durée juste avant (le mois précédent pour un mois complet, le même moment du
        cycle de paie précédent pour un cycle)."""
        if self.cycle_precedent is not None:
            return self.cycle_precedent
        if self.est_mois_complet:
            mois = pd.Period(self.debut, freq="M") - 1
            return periode_du_mois(mois)
        fin = self.debut - timedelta(days=1)
        debut = fin - timedelta(days=self.nb_jours - 1)
        return Periode(debut, fin, f"du {debut:%d/%m} au {fin:%d/%m}")


MODES_PERIODE = ["Mois", "Depuis la paie", "Personnalisée"]


def periode_du_mois(mois: pd.Period) -> Periode:
    return Periode(mois.start_time.date(), mois.end_time.date(), libelle_mois(mois))


def choisir_periode(df: pd.DataFrame, cle: str, avec_paie: bool = True, mode_defaut: str = "Mois") -> Periode:
    """Sélecteur de période : un mois, un cycle de paie (paie du salaire principal → veille de la suivante)
    ou deux dates."""
    modes = MODES_PERIODE if avec_paie else [m for m in MODES_PERIODE if m != "Depuis la paie"]
    st.session_state.setdefault(f"{cle}_mode", mode_defaut if mode_defaut in modes else "Mois")
    with st.container(horizontal=True, vertical_alignment="center", key=f"filtres_{cle}"):
        mode = st.segmented_control("Période", modes, required=True, key=f"{cle}_mode",
                                    label_visibility="collapsed")

        if mode == "Depuis la paie":
            # Seules les paies du salaire principal ouvrent un cycle ; les autres salaires (petit job…)
            # comptent dans les revenus du cycle où ils tombent
            principal = employeur_principal(df)
            jours_paie = sorted(jours_de_paie(df), reverse=True)
            if not jours_paie:  # pas de salaire saisi : on se base sur les autres revenus
                autres = df[(df["categorie"] == CAT_REVENU)
                            & ~df["sous_categorie"].isin(MOUVEMENTS_EPARGNE | set(COMPENSATIONS))]
                jours_paie = sorted({d.date() for d in autres["date_operation"]}, reverse=True)
            if jours_paie:
                choix = st.selectbox(
                    "Paie", range(len(jours_paie)), key=f"{cle}_paie", label_visibility="collapsed",
                    width=250, format_func=lambda i: f"Depuis la paie du {jours_paie[i]:%d/%m}" if i == 0
                    else f"Paie du {jours_paie[i]:%d/%m/%y}",
                    help=(f"Le mois budgétaire commence à chaque paie de ton salaire principal ({principal}). "
                          "Tes autres revenus comptent dans le cycle où ils arrivent.") if principal else None, filter_mode=None,
                )
                debut = jours_paie[choix]
                fin = jours_paie[choix - 1] - timedelta(days=1) if choix > 0 else max(aujourdhui(), debut)
                avant = None
                if choix + 1 < len(jours_paie):  # repère : le cycle précédent, au même nombre de jours
                    d0 = jours_paie[choix + 1]
                    f0 = min(debut - timedelta(days=1), d0 + (fin - debut))
                    avant = Periode(d0, f0, f"paie du {d0:%d/%m}", cycle=True)
                libelle = f"Depuis la paie du {debut:%d/%m}" if choix == 0 else f"Paie du {debut:%d/%m} au {fin:%d/%m}"
                return Periode(debut, fin, libelle, cycle=True, cycle_precedent=avant)
            st.caption("Aucun revenu saisi : affichage du mois en cours.")
            return periode_du_mois(mois_courant())

        if mode == "Personnalisée":
            debut_defaut = mois_courant().start_time.date()
            choix = st.date_input("Du … au …", value=(debut_defaut, aujourdhui()), format="DD/MM/YYYY",
                                  key=f"{cle}_dates", label_visibility="collapsed", width=240)
            if isinstance(choix, (tuple, list)) and len(choix) == 2:
                debut, fin = choix
                return Periode(debut, fin, f"Du {debut:%d/%m/%Y} au {fin:%d/%m/%Y}")
            st.caption("Choisis la date de fin.")  # sélection en cours : une seule date
            debut = choix[0] if isinstance(choix, (tuple, list)) and choix else debut_defaut
            return Periode(debut, debut, f"Le {debut:%d/%m/%Y}")

        options = sorted(set(df["mois"].dropna()) | {mois_courant()}, reverse=True)
        mois = st.selectbox("Mois", options, format_func=libelle_mois, key=f"{cle}_mois",
                            label_visibility="collapsed", width=200, filter_mode=None)
        return periode_du_mois(mois)


def limites_periode(profil: pd.Series, periode: Periode) -> tuple[float, float]:
    """Budget et objectif d'épargne mensuels, ramenés à la durée de la période (au prorata des jours) ;
    un cycle de paie compte pour un mois entier."""
    facteur = 1.0 if periode.est_mois_complet or periode.cycle else periode.nb_jours / JOURS_PAR_MOIS
    return float(profil["budget_mensuel_max"]) * facteur, float(profil["objectif_epargne"]) * facteur


# --- Analyses de l'historique -----------------------------------------------------------------

@lru_cache(maxsize=8192)
def marchand_de(description: str, sous_categorie: str) -> str:
    """« Burger King · Olivet » -> « Burger King » ; « mcdo » -> « McDonald's » ; vide -> la catégorie."""
    texte = re.sub(r"\s*\(\d+ achats\)$", "", description.split(" · ")[0]).strip()
    if not texte:
        return sous_categorie
    return ALIAS_MARCHANDS.get(texte.casefold(), texte[:1].upper() + texte[1:])


@lru_cache(maxsize=8192)
def ville_de(description: str) -> str:
    morceaux = description.split(" · ")
    if len(morceaux) < 2:
        return ""
    ville = re.sub(r"\s*\(.*\)$", "", morceaux[1]).strip()
    return ville if ville in VILLES_CONNUES else ""


def enrichir(df: pd.DataFrame) -> pd.DataFrame:
    """Ajoute le marchand et la ville déduits de la note (pour les analyses)."""
    df = df.copy()
    df["marchand"] = [marchand_de(d, s) for d, s in zip(df["description"], df["sous_categorie"])]
    df["ville"] = [ville_de(d) for d in df["description"]]
    return df


@st.cache_data(ttl=300, show_spinner=False)
def index_historique(profil_id: str) -> dict:
    """Ce que l'historique enseigne : pour chaque marchand ou note déjà saisis, les catégories et montants
    utilisés (les 4 derniers mois comptent triple), et la fréquence de chaque catégorie sur 6 mois."""
    df = enrichir(charger_operations((profil_id,)))
    df = df[df["categorie"] != CAT_VIREMENT]  # un virement se saisit à part (type « Virement »)
    recent = pd.Timestamp(aujourdhui() - timedelta(days=120))
    index: dict[str, list[tuple[str, float, float]]] = {}
    noms: dict[str, str] = {}
    for desc, marchand, sc, montant, quand in zip(df["description"], df["marchand"], df["sous_categorie"],
                                                 df["montant"], df["date_operation"]):
        poids = 3.0 if quand >= recent else 1.0
        for cle in {releve.cle_texte(marchand), releve.cle_texte(desc)}:
            if len(cle) >= 2:
                index.setdefault(cle, []).append((sc, float(montant), poids))
                noms.setdefault(cle, marchand)
    six_mois = df[df["date_operation"] >= pd.Timestamp(aujourdhui() - timedelta(days=180))]
    return {"index": index, "noms": noms, "usage": six_mois["sous_categorie"].value_counts().to_dict()}


def correspondances(texte: str, idx: dict) -> tuple[list[tuple[str, float, float]], str]:
    """Opérations passées qui ressemblent à `texte` (même marchand ou même note), et le nom du marchand."""
    k = releve.cle_texte(texte)
    if len(k) < 2:
        return [], ""
    alias = releve.cle_texte(ALIAS_MARCHANDS.get(texte.strip().casefold(), texte))
    trouves = list(idx["index"].get(k, [])) + (list(idx["index"].get(alias, [])) if alias != k else [])
    nom = idx["noms"].get(k) or idx["noms"].get(alias, "")
    if not trouves and len(k) >= 3:
        mots = set(k.split())
        for cle, liste in idx["index"].items():
            mots_cle = set(cle.split())
            if cle.startswith(k) or (len(cle) >= 4 and mots_cle <= mots) or (len(k) >= 4 and mots <= mots_cle):
                trouves.extend(liste)
                nom = nom or idx["noms"].get(cle, "")
    return trouves, nom


def meilleure_categorie(trouves: list[tuple[str, float, float]], montant: float | None,
                        credit: bool | None = None) -> tuple[str | None, float]:
    """Catégorie la plus probable (les montants proches pèsent plus) et sa part des voix (0 à 1)."""
    scores: dict[str, float] = defaultdict(float)
    for sc, m, poids in trouves:
        if sc not in SOUS_CATEGORIES or (credit is not None and (SOUS_CATEGORIES[sc][0] == CAT_REVENU) != credit):
            continue
        proche = math.exp(-abs(math.log(max(m, 0.01) / max(montant, 0.01)))) if montant else 0.5
        scores[sc] += poids * (0.4 + proche)
    if not scores:
        return None, 0.0
    meilleure = max(scores, key=scores.get)
    return meilleure, scores[meilleure] / sum(scores.values())


def deviner_saisie(note: str, idx: dict, montant: float | None) -> dict | None:
    """Catégorie (et montant habituel) déduits de la note : d'abord l'historique, sinon les règles d'enseignes."""
    if len(releve.cle_texte(note)) < 2:
        return None
    trouves, nom = correspondances(note, idx)
    sc, _ = meilleure_categorie(trouves, montant)
    if sc:
        memes = [m for s, m, _ in trouves if s == sc]
        valeur, nb = Counter(round(m, 2) for m in memes).most_common(1)[0]
        habituel = valeur if nb >= 2 and nb / len(memes) >= 0.5 else None
        return {"sc": sc, "nb": len(memes), "nom": nom, "montant": habituel}
    for signe in (-1.0, 1.0):
        p = releve.proposer(releve.LigneReleve(0, aujourdhui(), signe * (montant or 1.0), note.upper(), None))
        if p["sur"]:
            return {"sc": p["sous_categorie"], "nb": 0, "nom": "", "montant": None}
    return None


@st.cache_data(ttl=300, show_spinner=False)
def raccourcis_frequents(profil_id: str, nb: int = 6) -> list[dict]:
    """Les opérations qui reviennent à l'identique (même marchand, même montant) ces 4 derniers mois."""
    df = enrichir(charger_operations((profil_id,)))
    recent = df[(df["date_operation"] >= pd.Timestamp(aujourdhui() - timedelta(days=120)))
                & ~df["sous_categorie"].isin(["Retrait d'épargne", "Vente placement", "Dépôt espèces", "Espèces",
                                              "Intérêts & primes"])]
    if recent.empty:
        return []
    g = (recent.groupby(["sous_categorie", "marchand", "montant", "compte", "vers_compte"], sort=False)
         .agg(nb=("id", "size"), dernier=("date_operation", "max"), description=("description", "first"))
         .reset_index())
    g = g[g["nb"] >= 2].sort_values(["nb", "dernier"], ascending=False).head(nb)
    return [{"sc": r.sous_categorie, "nom": r.marchand, "montant": float(r.montant),
             "description": r.description or r.marchand, "compte": r.compte,
             "vers": r.vers_compte if r.sous_categorie == SC_VIREMENT else None} for r in g.itertuples()]


@dataclass
class Livrets:
    """Soldes des livrets jour par jour : exacts sur la période des relevés, prolongés ensuite avec les
    virements du compte courant, et reconstitués (au total) avant le premier relevé."""
    soldes: pd.DataFrame      # une colonne par livret, depuis le début des relevés
    total: pd.Series          # total des livrets sur tout l'historique
    debut_releves: date
    fin_releves: date
    interets: pd.DataFrame    # une ligne par année, une colonne par livret
    taux: dict[str, float]    # dernier taux connu (en %), quand le relevé l'indique


def livret_vise(sous_categorie: str, description: str, noms: list[str]) -> str | None:
    """Livret concerné par un virement du compte courant (None si ce n'est pas un livret de la banque)."""
    texte = description.casefold()
    if "boursobank" in texte or sous_categorie not in ("Livret", "Retrait d'épargne"):
        return None
    for nom in noms:
        if nom.casefold() in texte:
            return nom
    if "livret" in texte:  # « Depuis mon livret » : le livret qui sert de compte tampon (le Bleu, sinon le 1er)
        return next((n for n in noms if "bleu" in n.casefold()), noms[0])
    return None


def calculer_livrets(avoirs: dict, brut_tout: pd.DataFrame, fin: date) -> Livrets | None:
    noms = [n for n, v in (avoirs or {}).items() if isinstance(v, dict) and v.get("lignes")]
    if not noms:
        return None
    lignes = {n: sorted(avoirs[n]["lignes"], key=lambda l: l[0]) for n in noms}
    debut_rel = min(date.fromisoformat(l[0][0]) for l in lignes.values())
    fin_rel = max(date.fromisoformat(l[-1][0]) for l in lignes.values())
    jours = pd.date_range(min(debut_rel, fin), max(fin, debut_rel), freq="D")
    soldes = {}
    for n, ls in lignes.items():
        depart = float(ls[0][2]) - float(ls[0][1])
        par_jour = pd.Series({pd.Timestamp(l[0]): float(l[2]) for l in ls})  # le dernier solde du jour l'emporte
        soldes[n] = par_jour.reindex(jours).ffill().fillna(depart)
    soldes = pd.DataFrame(soldes, index=jours)
    # Après le dernier relevé : versements (+) et retraits (−) enregistrés sur le compte courant
    flux = brut_tout[brut_tout["sous_categorie"].isin(["Livret", "Retrait d'épargne"])]
    sens = flux["sous_categorie"].map(lambda s: 1.0 if s == "Livret" else -1.0) * flux["montant"]
    vises = [livret_vise(s, d, noms) for s, d in zip(flux["sous_categorie"], flux["description"])]
    apres = pd.DataFrame({"jour": flux["date_operation"].dt.normalize(), "livret": vises, "delta": sens})
    apres = apres[apres["livret"].notna()]
    for n, g in apres[apres["jour"] > pd.Timestamp(fin_rel)].groupby("livret"):
        cumul = g.groupby("jour")["delta"].sum().reindex(jours, fill_value=0.0).cumsum()
        soldes[n] = soldes[n] + cumul
    # Avant le premier relevé : total reconstitué en remontant les virements (intérêts antérieurs inconnus)
    avant = apres[apres["jour"] < pd.Timestamp(debut_rel)]
    total = soldes.sum(axis=1)
    if not avant.empty:
        jours_avant = pd.date_range(avant["jour"].min() - pd.Timedelta(days=1), pd.Timestamp(debut_rel)
                                    - pd.Timedelta(days=1), freq="D")
        f = avant.groupby("jour")["delta"].sum().reindex(jours_avant, fill_value=0.0)
        apres_t = f[::-1].cumsum()[::-1].shift(-1, fill_value=0.0)  # virements strictement après le jour t
        depart = sum(float(ls[0][2]) - float(ls[0][1]) for ls in lignes.values())
        total = pd.concat([depart - apres_t, total])
    interets = {}
    taux = {}
    for n, ls in lignes.items():
        for d, m, _, lib in ls:
            if "INTERET" in str(lib).upper():
                interets.setdefault(int(d[:4]), {})[n] = float(m)
            t = re.search(r"TAUX.*?(\d+)\s(\d{3})\s?%", str(lib).upper())
            if t:
                taux[n] = float(f"{t.group(1)}.{t.group(2)}")
    interets = pd.DataFrame(interets).T.reindex(columns=noms).fillna(0.0).sort_index()
    return Livrets(soldes, total, debut_rel, fin_rel, interets, taux)


def serie_patrimoine(comp_tout: pd.DataFrame, livrets: Livrets | None, debut: date, fin: date) -> pd.DataFrame:
    """Compte courant, autres comptes, livrets et placements (montant net versé) jour par jour."""
    jours = pd.date_range(debut, fin, freq="D")
    comptes = comptes_de(comp_tout)
    soldes = soldes_comptes_jour(comp_tout, comptes, debut, fin)
    quand = comp_tout["date_operation"].dt.normalize()
    tous = pd.date_range(min(quand.min(), pd.Timestamp(debut)), pd.Timestamp(fin), freq="D")
    place = comp_tout[(comp_tout["categorie"] == CAT_EPARGNE) & (comp_tout["sous_categorie"] == "Investissement")]
    placements = (place.groupby(place["date_operation"].dt.normalize())["montant"].sum()
                  .reindex(tous, fill_value=0.0).cumsum().reindex(jours))
    series = {"Compte courant": soldes[COMPTE_COURANT]}
    if len(comptes) > 1:
        series["Autres comptes"] = soldes[comptes[1:]].sum(axis=1)
    if livrets is not None:
        series["Livrets"] = livrets.total.reindex(jours).ffill().fillna(float(livrets.total.iloc[0]))
    series["Placements"] = placements
    return pd.DataFrame(series, index=jours)


def entre(df: pd.DataFrame, debut: date, fin: date) -> pd.DataFrame:
    return df[df["date_operation"].between(pd.Timestamp(debut), pd.Timestamp(fin))]


def depenses_de(df: pd.DataFrame) -> pd.DataFrame:
    return df[df["categorie"].isin(CATEGORIES_DEPENSES)]


def depenses_courantes(comp: pd.DataFrame) -> pd.DataFrame:
    """Dépenses du quotidien : sans les charges fixes ni les achats exceptionnels (> 1 000 €)."""
    d = depenses_de(comp)
    return d[~d["sous_categorie"].isin(CHARGES_FIXES) & (d["montant"] <= SEUIL_EXCEPTIONNEL)]


def mois_entre(debut: date, fin: date) -> pd.PeriodIndex:
    return pd.period_range(pd.Period(debut, freq="M"), pd.Period(fin, freq="M"), freq="M")


def nb_mois_ecoules(debut: date, fin: date) -> float:
    return max(((fin - debut).days + 1) / JOURS_PAR_MOIS, 1.0)


def table_mensuelle(comp: pd.DataFrame, comp_tout: pd.DataFrame, debut: date, fin: date) -> pd.DataFrame:
    """Mois par mois : revenus, besoins, envies, épargne nette, dépenses, reste, solde en fin de mois."""
    mois = mois_entre(debut, fin)
    sommes = (comp.groupby(["mois", "categorie"])["montant"].sum().unstack(fill_value=0.0)
              .reindex(index=mois, columns=[CAT_REVENU, *CATEGORIES_SORTIES], fill_value=0.0))
    t = pd.DataFrame({
        "revenus": sommes[CAT_REVENU], "besoins": sommes[CAT_BESOINS], "envies": sommes[CAT_ENVIES],
        "epargne": sommes[CAT_EPARGNE],
    }, index=mois)
    ref = comp[(comp["categorie"] == CAT_REVENU) & comp["sous_categorie"].isin(REVENUS_REFERENCE)]
    t["reference"] = ref.groupby("mois")["montant"].sum().reindex(mois, fill_value=0.0)
    remb = comp[comp["sous_categorie"] == "Remboursement"]
    t["remboursements"] = remb.groupby("mois")["montant"].sum().reindex(mois, fill_value=0.0)
    t["depenses"] = t["besoins"] + t["envies"]
    t["reste"] = t["revenus"] - t["depenses"] - t["epargne"]
    flux = montant_signe(comp_tout).groupby(comp_tout["mois"]).sum().sort_index().cumsum()
    t["solde_fin"] = flux.reindex(flux.index.union(mois)).ffill().fillna(0.0).reindex(mois)
    t["libelle"] = [libelle_mois_court(p) for p in mois]
    return t


def evolution(serie: pd.Series, n: int = 3) -> float | None:
    """Variation (en %) des n derniers mois par rapport aux n précédents."""
    if len(serie) < 2 * n:
        return None
    recent, avant = serie.iloc[-n:].sum(), serie.iloc[-2 * n:-n].sum()
    return (recent - avant) / avant * 100 if avant > 0 else None


def rang_sous_categories(comp_tout: pd.DataFrame, n: int = 7) -> list[str]:
    """Les n thèmes de dépense les plus lourds sur tout l'historique : couleurs stables d'un filtre à l'autre."""
    d = depenses_de(comp_tout).groupby("sous_categorie")["montant"].sum().sort_values(ascending=False)
    return [s for s, m in d.items() if m > 0][:n]


def source_revenu(sous_categorie: str, description: str) -> str:
    """D'où vient un revenu : l'employeur pour un salaire (« Boulangerie (job d'été) » -> « Boulangerie »),
    sinon le thème (« Bourse & aides », « Aide familiale »…)."""
    if sous_categorie != "Salaire":
        return sous_categorie
    nom = re.sub(r"\s*\(.*\)$", "", marchand_de(description, sous_categorie)).strip()
    return nom or "Salaire"


def sources_de(df: pd.DataFrame) -> pd.Series:
    return pd.Series([source_revenu(sc, d) for sc, d in zip(df["sous_categorie"], df["description"])],
                     index=df.index, dtype=object)


def employeur_principal(df: pd.DataFrame) -> str | None:
    """L'employeur dont la paie ouvre le mois budgétaire : celui qui a versé le plus de salaire ces
    6 derniers mois (à défaut, sur tout l'historique). Les autres salaires (job d'été, petit boulot)
    comptent dans les revenus, mais ne fixent pas les dates des cycles."""
    sal = df[(df["categorie"] == CAT_REVENU) & (df["sous_categorie"] == "Salaire")]
    if sal.empty:
        return None
    recents = sal[sal["date_operation"] >= pd.Timestamp(aujourdhui() - timedelta(days=183))]
    base = recents if not recents.empty else sal
    return str(base.groupby(sources_de(base))["montant"].sum().idxmax())


def jours_de_paie(df: pd.DataFrame) -> list[date]:
    """Dates de paie du salaire principal, de la plus ancienne à la plus récente (au moins 20 jours d'écart)."""
    principal = employeur_principal(df)
    if principal is None:
        return []
    sal = df[(df["categorie"] == CAT_REVENU) & (df["sous_categorie"] == "Salaire")]
    sal = sal[sources_de(sal) == principal]
    jours: list[date] = []
    for jour in sorted({d.date() for d in sal["date_operation"]}):
        if not jours or (jour - jours[-1]).days >= 20:
            jours.append(jour)
    return jours


def cycles_paie(brut_tout: pd.DataFrame) -> list[date]:
    """Dates de début des cycles de paie : les paies du salaire principal ; sans salaire, les gros revenus
    réguliers espacés d'au moins 20 jours."""
    jours = jours_de_paie(brut_tout)
    if jours:
        return jours
    rev = brut_tout[brut_tout["sous_categorie"].isin(REVENUS_REFERENCE) & (brut_tout["montant"] >= 300)]
    debuts: list[date] = []
    for jour in sorted({d.date() for d in rev["date_operation"]}):
        if not debuts or (jour - debuts[-1]).days >= 20:
            debuts.append(jour)
    return debuts


def abonnements(brut_tout: pd.DataFrame, fin: date) -> pd.DataFrame:
    """Charges récurrentes (abonnements, loyer, factures, assurances) vues sur les 12 derniers mois."""
    d = brut_tout[brut_tout["sous_categorie"].isin(CHARGES_FIXES - {"Frais bancaires"})
                  & (brut_tout["date_operation"] <= pd.Timestamp(fin))]
    if d.empty:
        return pd.DataFrame()
    an = d[d["date_operation"] > pd.Timestamp(fin - timedelta(days=365))]
    trim = d[d["date_operation"] > pd.Timestamp(fin - timedelta(days=92))]
    lignes = []
    for marchand, g in d.groupby("marchand"):
        g_an = an[an["marchand"] == marchand]
        if g_an.empty:
            continue
        derniere = g["date_operation"].max().date()
        mois_payes = g_an["mois"].nunique()
        lignes.append({
            "Service": marchand,
            "Catégorie": g["sous_categorie"].mode().iat[0],
            "Montant habituel (€)": round(float(g_an["montant"].median()), 2),
            "Mois payés sur 12": int(mois_payes),
            "Payé sur 12 mois (€)": round(float(g_an["montant"].sum()), 2),
            "Coût mensuel actuel (€)": round(float(trim[trim["marchand"] == marchand]["montant"].sum()) / 3, 2),
            "Dernier paiement": derniere,
            "Statut": "Actif" if (fin - derniere).days <= 40 else "Arrêté",
        })
    if not lignes:
        return pd.DataFrame()
    return pd.DataFrame(lignes).sort_values("Payé sur 12 mois (€)", ascending=False).reset_index(drop=True)


def operations_jeux(brut: pd.DataFrame) -> pd.DataFrame:
    """Mises et gains : catégories dédiées, ou note qui évoque un pari, un casino, le loto…"""
    masque = (brut["sous_categorie"].isin(["Jeux d'argent", "Gains de jeux"])
              | brut["description"].str.contains(RE_JEUX, na=False))
    d = brut[masque].copy()
    d["sens"] = d["categorie"].map(lambda c: "Gains" if c == CAT_REVENU else "Mises")
    texte = d["description"].str.lower()
    d["operateur"] = "Autre"
    for motif, nom in ((r"betclic", "Betclic"), (r"winamax", "Winamax"), (r"fdj|loto", "FDJ"),
                       (r"pmu|pari mutuel", "PMU"), (r"casino|🎰", "Casino"), (r"poker", "Poker"),
                       (r"b play", "B Play")):
        d.loc[texte.str.contains(motif, regex=True) & (d["operateur"] == "Autre"), "operateur"] = nom
    return d


# =====================================================================
# 5. DESIGN : FEUILLE DE STYLE ET COMPOSANTS HTML
# =====================================================================

CSS = """
<style>
:root {
  --fond:#14181C; --carte:#1F252B; --carte-2:#2A3138; --carte-3:#353D46; --bord:rgba(255,255,255,.06);
  --texte:#F3F5F7; --doux:#A7B0B9; --muet:#717B85; --piste:rgba(255,255,255,.07);
  --pos:#3DD68C; --neg:#FF6B6B; --warn:#FFC145; --bleu:#3987E5;
  --sans:"Manrope", system-ui, -apple-system, "Segoe UI", sans-serif;
  --haut:62px;  /* en-tête */
  --bas:66px;   /* barre d'onglets du téléphone */
  --rail:92px;  /* rail d'onglets de l'ordinateur */
  --rayon:24px;
  --sur:env(safe-area-inset-top, 0px); --sous:env(safe-area-inset-bottom, 0px);
}

/* ---------- Comportement d'application : la page ne défile jamais ---------- */
html, body { height:100%; overflow:hidden !important; overscroll-behavior:none; background:var(--fond); }
/* La page entière ne glisse jamais (ni de côté, ni en élastique) ; seul l'écran défile */
html, body { overflow-x:hidden !important; touch-action:manipulation; }
.stApp {
  height:100dvh; overflow:hidden;
  background:
    radial-gradient(120% 52% at 50% -14%, rgba(57,135,229,.17), transparent 62%),
    radial-gradient(80% 45% at 105% 105%, rgba(144,133,233,.09), transparent 60%),
    var(--fond);
}
[data-testid="stAppViewContainer"], [data-testid="stMain"] { height:100dvh; overflow:hidden !important; }
header[data-testid="stHeader"], [data-testid="stStatusWidget"], [data-testid="stToolbar"],
footer, #MainMenu, [data-testid="stDecoration"], [data-testid="stSidebar"] { display:none !important; }
.block-container { max-width:none !important; padding:0 !important; height:100dvh; }
* { -webkit-tap-highlight-color:transparent; }
button { -webkit-user-select:none; user-select:none; touch-action:manipulation; }
input, textarea, select { font-size:16px !important; }  /* évite le zoom automatique sur iPhone */
::selection { background:rgba(57,135,229,.35); }
.pos { color:var(--pos); } .neg { color:var(--neg); } .warn { color:var(--warn); } .or { color:var(--texte); }
body, .stApp, p, li, input, textarea, button { font-family:var(--sans); }
.stApp { font-variant-numeric:tabular-nums; }

/* Écrans : un seul bloc défile, entre l'en-tête et la barre d'onglets fixes */
div[class*="st-key-ecran_"] {
  position:fixed; z-index:1; left:0; right:0;
  top:calc(var(--haut) + var(--sur)); bottom:calc(var(--bas) + var(--sous));
  overflow-y:auto; overflow-x:hidden; overscroll-behavior:contain; -webkit-overflow-scrolling:touch;
  padding:2px 16px 28px; gap:14px !important; scrollbar-width:none; width:auto !important; box-sizing:border-box;
}
div[class*="st-key-ecran_"]::-webkit-scrollbar { display:none; }
/* En-tête d'écran (filtres, sous-vues) collé en haut du bloc qui défile */
div[class*="st-key-tete_"] {
  position:sticky; top:-2px; z-index:30; margin:0; padding:6px 0 10px; gap:10px !important;
  background:linear-gradient(180deg, rgba(20,24,28,.96) 78%, rgba(20,24,28,0));
  -webkit-backdrop-filter:blur(14px); backdrop-filter:blur(14px);
}
/* Écrans de connexion : centrés, sans barre d'onglets */
div.st-key-ecran_login { top:var(--sur); bottom:var(--sous); padding-top:16px; }
div.st-key-ecran_login > [data-testid="stLayoutWrapper"] { margin:auto 0; }

/* ---------- En-tête : titre de l'écran + avatar ---------- */
.st-key-entete {
  position:fixed; z-index:40; top:0; left:0; right:0; height:calc(var(--haut) + var(--sur));
  padding:var(--sur) 16px 0 18px !important; display:flex; align-items:center; width:auto !important; box-sizing:border-box;
  background:linear-gradient(180deg, rgba(20,24,28,.94), rgba(20,24,28,.80));
  -webkit-backdrop-filter:blur(18px); backdrop-filter:blur(18px);
}
.st-key-entete > div { width:100%; }
.titre-ecran { font:800 1.62rem/1.05 var(--sans); letter-spacing:-.02em; color:var(--texte); }
.salut-ecran { font:600 .76rem var(--sans); color:var(--muet); margin-bottom:2px; }
/* Téléphone : titre centré, l'avatar à droite */
@media (max-width: 899px) {
  .st-key-entete > [data-testid="stElementContainer"]:first-child { flex:1 1 auto !important; width:auto !important;
    min-width:0; padding-left:42px; }
  .st-key-entete > :not(:first-child) { flex:0 0 auto !important; width:auto !important; }
  .entete-titre { text-align:center; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .titre-ecran { font-size:1.3rem; }
  div[class*="st-key-filtres_"] { justify-content:center !important; }
}
.st-key-entete [data-testid="stPopover"] button {
  width:42px; height:42px; min-height:42px; border-radius:50% !important; padding:0;
  background:var(--carte-2) !important; border:0 !important; justify-content:center;
}
.st-key-entete [data-testid="stPopover"] button p { font:800 1rem var(--sans); color:var(--texte); }
.st-key-entete [data-testid="stPopover"] button [data-testid="stIconMaterial"],
.st-key-entete [data-testid="stPopover"] button svg { display:none; }

/* ---------- Barre d'onglets fixe en bas (téléphone) ---------- */
.st-key-nav [data-testid="stTabs"] > div:first-child, .st-key-nav [role="tablist"] { overflow:visible; }
.st-key-nav [role="tablist"] {
  position:fixed !important; z-index:50; left:0; right:0; bottom:0; height:calc(var(--bas) + var(--sous)) !important;
  margin:0 !important; padding:0 6px var(--sous) !important; gap:0 !important; display:flex; align-items:center;
  justify-content:space-around; border:0 !important; border-top:1px solid var(--bord) !important; border-radius:0;
  background:rgba(22,26,31,.92); -webkit-backdrop-filter:blur(20px); backdrop-filter:blur(20px); box-shadow:none;
}
.st-key-nav [role="tablist"]::before, .st-key-nav [role="tablist"]::after,
.st-key-nav [data-testid="stTab"]::before, .st-key-nav [data-testid="stTab"]::after,
.st-key-nav .react-aria-SelectionIndicator { display:none !important; }
.st-key-nav [data-testid="stTab"] {
  flex:1 1 0; height:100% !important; padding:6px 0 4px !important; border:0 !important; background:transparent !important;
  box-shadow:none !important; border-radius:0; display:flex; align-items:center; justify-content:center; min-width:0;
}
.st-key-nav [data-testid="stTab"] p {
  display:flex; flex-direction:column; align-items:center; gap:3px; margin:0;
  font:700 .64rem/1 var(--sans); letter-spacing:.01em; color:var(--muet);
}
.st-key-nav [data-testid="stTab"] p span[role="img"] { font-size:1.5rem !important; color:var(--muet); line-height:1; }
.st-key-nav [data-testid="stTab"][aria-selected="true"] p,
.st-key-nav [data-testid="stTab"][aria-selected="true"] p span[role="img"] { color:var(--texte); }
/* Bouton central « + » */
.st-key-nav [data-testid="stTab"]:nth-child(3) p { font-size:0; gap:0; }
.st-key-nav [data-testid="stTab"]:nth-child(3) p span[role="img"] {
  width:50px; height:50px; border-radius:50%; display:flex !important; align-items:center; justify-content:center;
  line-height:1 !important; vertical-align:middle !important;
  font-size:1.9rem !important; color:#14181C !important; background:var(--texte);
  box-shadow:0 10px 26px -10px rgba(243,245,247,.55);
}
.st-key-nav [data-testid="stTabPanel"] { padding:0 !important; }
.st-key-nav, .st-key-nav [data-testid="stTabs"] { gap:0 !important; }

/* ---------- Cartes ---------- */
div[class*="st-key-carte"] {
  background:var(--carte); border:1px solid var(--bord); border-radius:var(--rayon); padding:18px 18px 14px;
  gap:10px !important;
}
.surtitre { font:700 .74rem/1.2 var(--sans); color:var(--muet); margin-bottom:4px; letter-spacing:.01em; }
.question { font:800 1.18rem/1.2 var(--sans); letter-spacing:-.01em; color:var(--texte); }
.precision { font-size:.84rem; color:var(--doux); margin:3px 0 4px; line-height:1.4; }
.phrase { font-size:.92rem; line-height:1.55; margin-top:8px; color:var(--doux); }
.phrase b { font-weight:700; color:var(--texte); }
.phrase b.pos { color:var(--pos); } .phrase b.neg { color:var(--neg); } .phrase b.warn { color:var(--warn); }
.note { font-size:.82rem; color:var(--muet); margin-top:8px; line-height:1.5; }
.note b { color:var(--doux); }
.sous-titre { font:800 1rem var(--sans); margin:12px 0 2px; color:var(--texte); }

/* ---------- Chiffre principal (façon Quanto : un grand nombre, centré) ---------- */
.hero { text-align:center; padding:6px 0 2px; }
.hero-lbl { font:700 .82rem var(--sans); color:var(--doux); }
.hero-montant { font:800 3rem/1.05 var(--sans); letter-spacing:-.03em; color:var(--texte); white-space:nowrap; margin-top:4px; }
.hero-montant .cts { font-size:.5em; color:var(--doux); font-weight:700; letter-spacing:0; }
.hero-montant.neg { color:var(--neg); }
.hero-sous { font-size:.8rem; color:var(--muet); margin-top:4px; }
.delta { display:inline-flex; align-items:center; gap:4px; font:700 .8rem var(--sans); margin-top:6px; white-space:nowrap; }
.delta .ms { font-size:16px; }
.puce { display:none; }

/* Pastilles de chiffres (revenus, épargne, reste, solde…) */
.kpis { display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-top:4px; }
.kpi { background:var(--carte); border:1px solid var(--bord); border-radius:18px; padding:11px 12px 10px; min-width:0; }
.kpi .lbl { font:700 .7rem var(--sans); color:var(--muet); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.kpi .val { font:800 1.06rem var(--sans); margin-top:4px; color:var(--texte); white-space:nowrap; letter-spacing:-.01em; }
.kpi .val .cts { font-size:.72em; color:var(--doux); font-weight:700; }
.kpi .sub { font-size:.72rem; color:var(--muet); margin-top:2px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.kpi .delta { font-size:.7rem; margin-top:3px; }
.hero-grille { display:none; }

/* ---------- Tuiles de chiffres ---------- */
.tuiles { display:grid; grid-template-columns:repeat(auto-fit, minmax(150px, 1fr)); gap:8px; margin:2px 0; }
.tuile { background:var(--carte-2); border-radius:18px; padding:12px 14px 11px; min-width:0; }
.tuile.accent { background:linear-gradient(150deg, rgba(57,135,229,.30), rgba(57,135,229,.08)); }
.tuile.accent .lbl, .tuile.accent .sub { color:#C3D7F2; }
.tuile .lbl { font:700 .72rem var(--sans); color:var(--muet); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.tuile .val { font:800 1.2rem var(--sans); margin-top:4px; color:var(--texte); white-space:nowrap; overflow:hidden;
  text-overflow:ellipsis; letter-spacing:-.01em; }
.tuile .val .cts { font-size:.7em; color:var(--doux); font-weight:700; }
.tuile .val.texte { font-size:.98rem; white-space:normal; line-height:1.25; }
.tuile .val.neg { color:var(--neg); } .tuile .val.pos { color:var(--pos); }
.tuile .sub { font-size:.74rem; color:var(--muet); margin-top:2px; line-height:1.35; }
.bloc-avoirs { display:flex; justify-content:space-between; align-items:baseline; margin:12px 2px 2px;
  font:800 .82rem var(--sans); color:var(--doux); }
.bloc-avoirs span { font:800 .9rem var(--sans); color:var(--texte); }

/* ---------- Barres de progression ---------- */
.barre { margin:12px 0 4px; }
.barre-tete { display:flex; justify-content:space-between; gap:8px; font-size:.9rem; margin-bottom:7px; color:var(--texte); }
.barre-tete b { font-weight:700; }
.barre-tete span { color:var(--doux); white-space:nowrap; }
.piste { position:relative; height:8px; background:var(--piste); border-radius:99px; }
.remplissage { height:100%; border-radius:99px; }
.repere { position:absolute; top:-4px; width:2px; height:16px; background:var(--texte); opacity:.5; }

/* ---------- Listes (opérations, catégories, objectifs) ---------- */
.ligne { display:flex; align-items:center; gap:12px; padding:10px 0; border-bottom:1px solid var(--bord); }
.ligne:last-child { border-bottom:0; }
.pastille { width:42px; height:42px; border-radius:14px; display:flex; align-items:center; justify-content:center;
  flex-shrink:0; background:var(--carte-2); font-size:1.3rem; line-height:1; }
.ms { font-family:'Material Symbols Rounded'; font-size:20px; line-height:1; font-weight:400;
  font-feature-settings:'liga'; -webkit-font-smoothing:antialiased; }
.point { width:9px; height:9px; border-radius:50%; flex-shrink:0; }
.ligne .corps { flex:1; min-width:0; }
.ligne .t { font:700 .95rem var(--sans); color:var(--texte); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.ligne .t .nb { display:inline-block; margin-left:6px; padding:1px 7px; border-radius:99px; background:var(--carte-2);
  color:var(--doux); font:700 .7rem var(--sans); vertical-align:2px; }
.ligne .s { font-size:.8rem; color:var(--muet); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; margin-top:2px; }
.ligne .m { font:800 .95rem var(--sans); white-space:nowrap; color:var(--texte); text-align:right; }
.ligne .m small { display:block; font:700 .7rem var(--sans); color:var(--muet); margin-top:2px; }
.ligne .s .compte { color:var(--doux); font-weight:700; }
.jour-tete { display:flex; justify-content:space-between; font:700 .8rem var(--sans); color:var(--muet); margin:14px 4px 6px; }
.groupe { margin-top:14px; }
.groupe:first-child { margin-top:2px; }
.groupe-tete { display:flex; align-items:center; gap:9px; font:800 .95rem var(--sans); color:var(--texte); margin-bottom:2px; }
.groupe-tete .m { margin-left:auto; }
.groupe .ligne { padding:8px 0; }

/* ---------- Notes du conseiller ---------- */
.lettre { border-radius:var(--rayon); padding:18px 18px 14px; background:var(--carte); border:1px solid var(--bord); }
.lettre-intro { font:800 1.05rem var(--sans); color:var(--texte); margin:2px 0 8px; }
.lettre ul { list-style:none; padding:0; margin:0; display:grid; grid-template-columns:1fr 1fr; gap:4px 28px; }
.lettre li { display:flex; gap:11px; padding:9px 0; border-bottom:1px solid var(--bord); font-size:.88rem; line-height:1.5; color:var(--doux); }
.lettre li b { color:var(--texte); }
.lettre li .ms { color:var(--texte); font-size:19px; margin-top:1px; }
.lettre .signature { color:var(--muet); text-align:right; margin-top:10px; font-size:.86rem; }

/* ---------- Membres du cercle ---------- */
.amis { display:grid; grid-template-columns:repeat(auto-fill, minmax(230px, 1fr)); gap:10px; }
.ami { background:var(--carte); border:1px solid var(--bord); border-radius:var(--rayon); padding:16px 18px; }
.ami .nom { font:800 1.1rem var(--sans); display:flex; justify-content:space-between; align-items:baseline; color:var(--texte); }
.ami .nom small { font:700 .7rem var(--sans); color:var(--muet); }

/* ---------- Marque & connexion ---------- */
.monogramme { width:64px; height:64px; border-radius:22px; display:flex; align-items:center; justify-content:center;
  font:800 2rem var(--sans); color:#14181C; flex-shrink:0;
  background:linear-gradient(145deg, #F3F5F7, #A9B7C4); box-shadow:0 18px 40px -18px rgba(57,135,229,.6); }
.monogramme.petit { width:38px; height:38px; border-radius:13px; font-size:1.2rem; }
.marque-bloc { display:flex; align-items:center; gap:12px; }
.marque-bloc.centre { flex-direction:column; text-align:center; gap:10px; margin:2px 0 18px; }
.marque { font:800 1.9rem var(--sans); letter-spacing:-.02em; line-height:1; color:var(--texte); }
.marque-sous { font:700 .8rem var(--sans); color:var(--muet); margin-top:6px; }
.filet { display:none; }
.st-key-carte_login { width:100%; max-width:420px; margin:auto; padding:26px 22px 20px !important; }

/* ---------- Boutons ---------- */
button[kind="primary"], button[kind="primaryFormSubmit"],
button[data-testid="stBaseButton-primary"], button[data-testid="stBaseButton-primaryFormSubmit"] {
  min-height:52px; border:0 !important; border-radius:999px !important; background:var(--texte) !important;
  box-shadow:0 14px 30px -18px rgba(243,245,247,.6);
}
button[kind="primary"] p, button[kind="primaryFormSubmit"] p,
button[data-testid="stBaseButton-primary"] p, button[data-testid="stBaseButton-primaryFormSubmit"] p {
  color:#14181C !important; font:800 .98rem var(--sans) !important;
}
button[data-testid="stBaseButton-primary"]:hover, button[data-testid="stBaseButton-primaryFormSubmit"]:hover { filter:brightness(.94); }
button[kind="secondary"], button[kind="secondaryFormSubmit"],
button[data-testid="stBaseButton-secondary"], button[data-testid="stBaseButton-secondaryFormSubmit"],
[data-testid="stPopover"] button, [data-testid="stDownloadButton"] button {
  border:0 !important; background:var(--carte-2) !important; border-radius:999px !important; min-height:40px;
}
button[data-testid="stBaseButton-secondary"] p, [data-testid="stPopover"] button p, [data-testid="stDownloadButton"] button p {
  font-weight:700; color:var(--texte);
}
button[kind="tertiary"] p, button[data-testid="stBaseButton-tertiary"] p { color:var(--doux); font-weight:700; }

/* ---------- Pastilles de choix (pills, segmented) ---------- */
button[data-variant="pills"], button[data-variant="segmented_control"] {
  border:0 !important; border-radius:999px !important; background:var(--carte-2) !important; min-height:36px;
  padding:0 14px; box-shadow:none !important; outline:none !important;
}
button[data-variant="pills"] p, button[data-variant="segmented_control"] p,
button[data-variant="pills"] [data-testid="stIconMaterial"], button[data-variant="segmented_control"] [data-testid="stIconMaterial"] {
  color:var(--doux) !important; font:700 .86rem var(--sans);
}
button[data-variant="pills"] [data-testid="stIconMaterial"], button[data-variant="segmented_control"] [data-testid="stIconMaterial"] {
  font-size:1.05rem !important; font-family:'Material Symbols Rounded' !important; font-weight:400 !important;
}
button[data-variant="pills"][aria-checked="true"], button[data-variant="segmented_control"][aria-checked="true"] {
  background:var(--texte) !important;
}
button[data-variant="pills"][aria-checked="true"] p, button[data-variant="segmented_control"][aria-checked="true"] p,
button[data-variant="pills"][aria-checked="true"] [data-testid="stIconMaterial"],
button[data-variant="segmented_control"][aria-checked="true"] [data-testid="stIconMaterial"] { color:#14181C !important; }
[data-testid="stButtonGroup"] [role="radiogroup"], [data-testid="stButtonGroup"] > div { gap:6px; }
/* Contrôle segmenté : une seule piste arrondie */
[data-testid="stButtonGroup"]:has(button[data-variant="segmented_control"]) [role="radiogroup"] {
  background:var(--carte-2); border-radius:999px; padding:3px; gap:2px !important; flex-wrap:nowrap; width:100%;
}
button[data-variant="segmented_control"] { background:transparent !important; flex:1 1 auto; min-height:32px; padding:0 10px; }
button[data-variant="segmented_control"][aria-checked="true"] { background:var(--texte) !important; }
/* Pastilles : jamais de défilement de côté, elles passent à la ligne et restent centrées */
[data-testid="stButtonGroup"] [role="radiogroup"] { flex-wrap:wrap !important; justify-content:center; }
[data-testid="stButtonGroup"]:has(button[data-variant="segmented_control"]) [role="radiogroup"] { flex-wrap:nowrap !important; }
/* Vues du Résumé : cases égales, icône au-dessus du nom */
.st-key-resume_vue button[data-variant="segmented_control"], .st-key-ami_vue button[data-variant="segmented_control"] {
  flex:1 1 0 !important; min-width:0; min-height:52px; padding:5px 2px !important; border-radius:18px !important;
}
.st-key-resume_vue [role="radiogroup"], .st-key-ami_vue [role="radiogroup"] { border-radius:22px !important; }
.st-key-resume_vue, .st-key-ami_vue, .st-key-resume_vue [data-testid="stButtonGroup"], .st-key-ami_vue [data-testid="stButtonGroup"],
.st-key-resume_vue [role="radiogroup"], .st-key-ami_vue [role="radiogroup"] { width:100% !important; max-width:none !important; }
.st-key-resume_vue button > div, .st-key-resume_vue button > div > span,
.st-key-ami_vue button > div, .st-key-ami_vue button > div > span {
  display:flex !important; flex-direction:column; align-items:center; gap:3px; min-width:0;
}
.st-key-resume_vue button p, .st-key-ami_vue button p { font-size:.68rem !important; white-space:nowrap; }
.st-key-resume_vue button [data-testid="stIconMaterial"], .st-key-ami_vue button [data-testid="stIconMaterial"] {
  font-size:1.2rem !important; margin:0 !important;
}
/* Analyses : les deux menus se partagent la largeur */
.st-key-choix_analyse { flex-wrap:nowrap !important; }
.st-key-choix_analyse > div { flex:1 1 0 !important; min-width:0 !important; width:auto !important; }
@media (max-width: 899px) {  /* téléphone : les deux menus l'un sous l'autre, en pleine largeur */
  .st-key-choix_analyse { flex-direction:column !important; gap:8px !important; }
  .st-key-choix_analyse > div { width:100% !important; }
}
/* Saisie : grille de catégories, 4 par ligne */
[class*="st-key-ajout_sous"], [class*="st-key-ajout_sous"] [data-testid="stButtonGroup"] { width:100% !important; }
[class*="st-key-ajout_sous"] [role="radiogroup"] { display:grid !important; grid-template-columns:repeat(4, 1fr);
  gap:6px; width:100%; }
[class*="st-key-ajout_sous"] button { width:100%; min-width:0; min-height:40px; border-radius:14px !important;
  padding:2px 4px !important; justify-content:center; }
[class*="st-key-ajout_sous"] button p { font-size:.74rem !important; line-height:1.1; white-space:normal; text-align:center; }
.st-key-ajout_options { justify-content:center; flex-wrap:nowrap !important; }
.st-key-ajout_options [data-testid="stPopover"] button { padding:0 12px; }
.st-key-ajout_options [data-testid="stPopover"] button div[aria-hidden="true"] { display:none; }  /* sans chevron */
@media (max-width: 899px) { .st-key-carte_ajout [data-testid="stCaptionContainer"] { display:none; } }
[data-testid="stButtonGroup"] button { flex-shrink:0; }

/* ---------- Champs ---------- */
[data-testid="stTextInputRootElement"], [data-baseweb="select"] > div, [data-testid="stDateInputField"],
[data-baseweb="input"], .stNumberInput [data-baseweb="input"] {
  background:var(--carte-2) !important; border:0 !important; border-radius:16px !important;
}
[data-testid="stWidgetLabel"] p { color:var(--muet); font:700 .76rem var(--sans); }
.stNumberInput button { display:none; }
[data-testid="stExpander"] details { border:0 !important; background:var(--carte); border-radius:18px; }
[data-testid="stExpander"] summary p { color:var(--doux); font-weight:700; font-size:.88rem; }
[data-testid="stDataFrame"], [data-testid="stDataEditor"] { border-radius:18px; overflow:hidden; }
[data-testid="stAlertContainer"] { border-radius:16px; border:0; }
[data-testid="stAlertContainer"]:has([data-testid="stAlertContentInfo"]) { background:var(--carte-2) !important; }
[data-testid="stAlertContentInfo"] p { color:var(--texte); }
[data-baseweb="menu"] li[aria-selected="true"], [role="option"][aria-selected="true"] { background:rgba(255,255,255,.09) !important; }
[data-baseweb="menu"] li:hover, [role="option"]:hover { background:rgba(255,255,255,.06) !important; }
[data-baseweb="tag"] { background:var(--carte-3) !important; border-radius:99px !important; }
[data-baseweb="tag"] span { color:var(--texte) !important; }
[data-baseweb="popover"] > div { border-radius:20px !important; }
div[data-testid="stPopoverBody"] { background:var(--carte) !important; border:1px solid var(--bord) !important; border-radius:20px !important; }
div[role="dialog"] { background:var(--carte) !important; border-radius:26px !important; }
.entete-section { margin:2px 0 0; }
.entete-section .surtitre { margin-bottom:2px; }
.entete-section .question { font-size:1.4rem; }
.entete-section .precision { margin-bottom:0; }

/* Écran Activité : la recherche prend la place restante */
.st-key-filtres_ops { flex-wrap:nowrap !important; }
.st-key-filtres_ops > div:first-child { flex:1 1 auto !important; min-width:0 !important; }
.st-key-filtres_ops > div:not(:first-child) { flex:0 0 auto !important; width:auto !important; }
.st-key-filtres_ops [data-testid="stTextInputRootElement"] { border-radius:999px !important; }
.st-key-import_ouvrir button { width:40px; padding:0; }

/* ---------- Saisie : montant, pavé numérique, catégories ---------- */
.st-key-carte_ajout { background:none !important; border:0 !important; padding:0 !important; gap:10px !important; }
.st-key-ajout_type [data-testid="stButtonGroup"], .st-key-ajout_type > div { width:100%; }
.st-key-ajout_type button { flex:1 1 0; }
.st-key-ajout_options { gap:6px !important; }
.st-key-ajout_options [data-testid="stPopover"] button { min-height:38px; padding:0 14px; }
.st-key-ajout_options [data-testid="stPopover"] button p { font:700 .86rem var(--sans); }
.devine { font-size:.8rem; color:var(--doux); margin:-4px 2px 0; }
.devine b { color:var(--texte); font-weight:700; }
.etiquette { font:700 .72rem var(--sans); color:var(--muet); margin:2px 2px -8px; }
.st-key-ajout_confirmer_ligne { background:var(--carte-2); border-radius:18px; padding:8px 8px 8px 14px; gap:8px; }
.st-key-ajout_confirmer_ligne button { min-height:38px !important; }
.st-key-ajout_annuler_ligne { background:rgba(61,214,140,.10); border-radius:16px; padding:2px 6px 2px 14px; }
.st-key-ajout_annuler_ligne .note { color:var(--pos); }

/* ---------- Lignes d'opérations avec boutons modifier / supprimer ---------- */
div[class*="st-key-suppr_"] button, div[class*="st-key-modif_"] button {
  min-width:40px; min-height:40px; border-radius:14px !important; margin-left:4px; padding:0 6px;
  background:var(--carte-2) !important; border:0 !important;
}
div[class*="st-key-suppr_"] [data-testid="stIconMaterial"] { color:var(--neg) !important; }
div[class*="st-key-recent_"], div[class*="st-key-op_"] { flex-wrap:nowrap !important; align-items:center; border-bottom:1px solid var(--bord); }
div[class*="st-key-recent_"]:last-child, div[class*="st-key-op_"]:last-child { border-bottom:0; }
div[class*="st-key-recent_"] .ligne, div[class*="st-key-op_"] .ligne { border-bottom:0; padding:8px 0; }
div[class*="st-key-recent_"] > div:first-child, div[class*="st-key-op_"] > div:first-child { flex:1 1 auto !important; min-width:0 !important; }
div[class*="st-key-recent_"] > div:not(:first-child), div[class*="st-key-op_"] > div:not(:first-child) { flex:0 0 auto !important; width:auto !important; }
div[class*="st-key-jour_"] { background:var(--carte); border:1px solid var(--bord); border-radius:var(--rayon); padding:4px 14px; gap:0 !important; }

/* ---------- Ordinateur : rail d'onglets à gauche, contenu plus large ---------- */
@media (min-width: 900px) {
  :root { --bas:0px; --haut:74px; }
  .st-key-nav [role="tablist"] {
    top:0; bottom:0; right:auto; width:var(--rail); height:100dvh !important; flex-direction:column;
    justify-content:center; gap:10px !important; padding:0 !important; border-top:0 !important;
    border-right:1px solid var(--bord) !important; background:rgba(18,22,26,.75);
  }
  .st-key-nav [data-testid="stTab"] { flex:0 0 auto; width:100%; height:64px !important; }
  .st-key-entete { left:var(--rail); padding:0 40px !important; background:transparent; -webkit-backdrop-filter:none; backdrop-filter:none; }
  .titre-ecran { font-size:1.9rem; }
  div[class*="st-key-ecran_"] { left:var(--rail); padding:2px max(40px, calc((100vw - var(--rail) - 1200px) / 2)) 40px; }
  div.st-key-ecran_login { left:0; }
  div.st-key-ecran_ajouter > div { max-width:520px; margin:0 auto; width:100%; }
  .hero-montant { font-size:3.4rem; }
}
@media (max-width: 899px) {
  div[class*="st-key-ecran_"] { padding-left:max(16px, calc((100vw - 560px) / 2)); padding-right:max(16px, calc((100vw - 560px) / 2)); }
  .phrase { text-align:center; }
  .lettre ul { grid-template-columns:1fr; }
  .kpis, .tuiles { grid-template-columns:1fr 1fr; }
  div[class*="st-key-carte"] { padding:16px 14px 12px; }
  .tuile { padding:11px 12px 10px; }
  .tuile .val { font-size:1.08rem; }
}
@media (max-width: 380px) {
  .hero-montant { font-size:2.6rem; }
  .titre-ecran { font-size:1.45rem; }
}
.version { display:none; }
</style>
"""


# Balises « application web » ajoutées dans <head> (Streamlit ne permet pas de les déclarer
# autrement) : plein écran sur iPhone, icône d'écran d'accueil, couleur de la barre d'état.
# Les fichiers sont servis depuis le dossier static/ (server.enableStaticServing).
SCRIPT_PWA = """
<script>
(() => {
  const head = document.head;
  if (head.dataset.pwa) return;
  head.dataset.pwa = "1";
  const ajouter = (tag, attrs) => {
    const el = document.createElement(tag);
    Object.entries(attrs).forEach(([k, v]) => el.setAttribute(k, v));
    head.appendChild(el);
  };
  ajouter("meta", {name: "apple-mobile-web-app-capable", content: "yes"});
  ajouter("meta", {name: "mobile-web-app-capable", content: "yes"});
  ajouter("meta", {name: "apple-mobile-web-app-status-bar-style", content: "black-translucent"});
  ajouter("meta", {name: "apple-mobile-web-app-title", content: "Le Cercle"});
  ajouter("meta", {name: "theme-color", content: "#14181C"});
  ajouter("link", {rel: "apple-touch-icon", href: "app/static/apple-touch-icon.png"});
  ajouter("link", {rel: "manifest", href: "app/static/manifest.json"});
  // Pas de zoom automatique ni de double-tap zoom : comportement d'application
  const viewport = document.querySelector('meta[name="viewport"]');
  if (viewport) {
    viewport.content = "width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover";
  }

  // Champs montant et PIN : clavier numérique de l'iPhone + filtrage des caractères en direct.
  // La valeur est réécrite via le setter natif pour que React (Streamlit) voie la correction.
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
  const filtrer = (el, nettoyer) => el.addEventListener("input", () => {
    const propre = nettoyer(el.value);
    if (propre !== el.value) {
      setter.call(el, propre);
      el.dispatchEvent(new Event("input", {bubbles: true}));
    }
  });
  const montant = (v) => {
    v = v.replace(/[^0-9.,]/g, "");
    const i = v.search(/[.,]/);  // un seul séparateur, 2 décimales max
    return i < 0 ? v.slice(0, 7) : v.slice(0, Math.min(i, 7)) + "," + v.slice(i + 1).replace(/[.,]/g, "").slice(0, 2);
  };
  const ameliorer = () => {
    document.querySelectorAll('.st-key-ajout_montant input, [class*="st-key-montant"] input').forEach((el) => {
      if (el.dataset.budget) return;
      el.dataset.budget = "1";
      Object.assign(el, {inputMode: "decimal", autocomplete: "off", enterKeyHint: "done"});
      filtrer(el, montant);
    });
    document.querySelectorAll('[class*="st-key-pin"] input').forEach((el) => {
      if (el.dataset.budget) return;
      el.dataset.budget = "1";
      Object.assign(el, {inputMode: "numeric", pattern: "[0-9]*", autocomplete: "off"});
      filtrer(el, (v) => v.replace(/[^0-9]/g, ""));
    });
  };
  // iPhone (app de l'écran d'accueil) : quand le clavier se ferme, Safari laisse parfois la page décalée
  // vers le haut ; l'affichage et les appuis ne correspondent plus (on touche ⌫, il lit 9). On la recale.
  const saisieActive = () => {
    const el = document.activeElement;
    if (!el || el.getAttribute("inputmode") === "none") return false;  // menu déroulant : pas de clavier
    return el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable;
  };
  const recaler = () => {
    if (saisieActive()) return;
    if (window.scrollX || window.scrollY) window.scrollTo(0, 0);
    if (document.documentElement.scrollTop) document.documentElement.scrollTop = 0;
    if (document.body.scrollTop) document.body.scrollTop = 0;
  };
  const recalerPlusTard = () => { setTimeout(recaler, 80); setTimeout(recaler, 400); };
  document.addEventListener("focusout", recalerPlusTard, true);
  window.addEventListener("scroll", recaler, {passive: true});
  window.addEventListener("resize", recalerPlusTard);
  window.addEventListener("orientationchange", recalerPlusTard);
  window.addEventListener("pageshow", recalerPlusTard);
  document.addEventListener("visibilitychange", recalerPlusTard);
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", recalerPlusTard);
    window.visualViewport.addEventListener("scroll", recalerPlusTard);
  }
  recalerPlusTard();
  // (Aucune balise HTML écrite en texte dans ce script : Streamlit l'écarterait.)
  new MutationObserver(ameliorer).observe(document.body, {childList: true, subtree: true});
  ameliorer();
})();
</script>
"""


def injecter_css() -> None:
    st.html(CSS)
    st.html(SCRIPT_PWA, unsafe_allow_javascript=True)


def montant_html(valeur: float, signe: bool = False) -> str:
    """Montant avec les centimes plus petits : 1 234<span>,56 €</span>."""
    texte = fmt_eur(valeur, signe=signe)
    entier, _, reste = texte.partition(",")
    return f"{entier}<span class='cts'>,{reste}</span>"


def titre_carte(question: str, precision: str = "", surtitre: str = "") -> None:
    """Titre de carte : surtitre doré, question en serif, précision facultative."""
    st.html((f"<div class='surtitre'>{escape(surtitre)}</div>" if surtitre else "")
            + f"<div class='question'>{escape(question)}</div>"
            + (f"<div class='precision'>{escape(precision)}</div>" if precision else ""))


def carte(cle: str):
    """Conteneur stylé en carte (voir CSS : div[class*='st-key-carte'])."""
    return st.container(key=f"carte_{cle}")


def html_delta(actuel: float, precedent: float, hausse_bonne: bool, libelle: str) -> str:
    """« ▲ 12 % vs sept. » coloré selon que la hausse est une bonne nouvelle ou non."""
    if abs(precedent) < 0.5:
        return ""
    variation = (actuel - precedent) / abs(precedent) * 100
    if abs(variation) < 0.5:
        return f"<div class='delta' style='color:var(--doux)'>= stable {escape(libelle)}</div>"
    hausse = variation > 0
    classe = "pos" if hausse == hausse_bonne else "neg"
    return (f"<div class='delta {classe}'>{'▲' if hausse else '▼'} {fmt_pct(abs(variation))} "
            f"<span style='color:var(--muet);font-weight:500'>{escape(libelle)}</span></div>")


def html_tuiles(tuiles: list[tuple]) -> str:
    """Rangée de chiffres clés : (libellé, valeur HTML, sous-texte[, classe de valeur[, accent]])."""
    morceaux = []
    for i, t in enumerate(tuiles):
        lbl, val, sub = t[0], t[1], t[2]
        classe = t[3] if len(t) > 3 else ""
        accent = " accent" if (len(t) > 4 and t[4]) or (len(t) <= 4 and i == 0) else ""
        morceaux.append(f"<div class='tuile{accent}'><div class='lbl'>{escape(lbl)}</div>"
                        f"<div class='val {classe}'>{val}</div><div class='sub'>{sub}</div></div>")
    return f"<div class='tuiles'>{''.join(morceaux)}</div>"


def phrase_resume(b: dict[str, float], prenom: str | None) -> str:
    """Le bilan de la période en une phrase."""
    sujet, reste_a = ("tu as", "Il te reste") if prenom is None else (f"{escape(prenom)} a", "Il lui reste")
    phrase = (f"Sur cette période, {sujet} reçu <b>{fmt_eur(b[CAT_REVENU])}</b>, dépensé "
              f"<b>{fmt_eur(b['depenses'])}</b> et mis <b>{fmt_eur(b[CAT_EPARGNE])}</b> de côté. ")
    if b["reste"] >= 0:
        phrase += f"{reste_a} <b class='pos'>{fmt_eur(b['reste'])}</b>."
    else:
        phrase += f"Les sorties dépassent les revenus de <b class='neg'>{fmt_eur(-b['reste'])}</b>."
    return f"<div class='phrase'>{phrase}</div>"


def html_barre(libelle: str, valeur: float, cible: float, couleur: str, texte: str,
               repere: float | None = None) -> str:
    """Barre de progression ; `repere` (en % de la piste) affiche un trait vertical (cible)."""
    largeur = max(0.0, min(valeur / cible * 100, 100.0)) if cible > 0 else 0.0
    trait = f"<div class='repere' style='left:{repere:.1f}%'></div>" if repere is not None else ""
    return f"""
    <div class="barre">
      <div class="barre-tete"><b>{escape(libelle)}</b><span>{texte}</span></div>
      <div class="piste"><div class="remplissage" style="width:{largeur:.1f}%;background:{couleur}"></div>{trait}</div>
    </div>"""


def html_limites(b: dict[str, float], budget: float, objectif: float, prorata: bool = False) -> str:
    """Barres budget / objectif d'épargne avec message d'état."""
    morceaux = []
    if budget > 0:
        ratio = b["depenses"] / budget
        couleur = C_NEG if ratio > 1 else C_ALERTE if ratio >= 0.8 else ACCENT
        morceaux.append(html_barre("Budget dépenses", b["depenses"], budget, couleur,
                                   f"{fmt_eur(b['depenses'])} / {fmt_eur(budget)}"))
        if ratio > 1:
            morceaux.append(f"<div class='note neg'>▲ Budget dépassé de {fmt_eur(b['depenses'] - budget)}</div>")
        elif ratio >= 0.8:
            morceaux.append("<div class='note warn'>● Plus de 80 % du budget est consommé</div>")
    if objectif > 0:
        morceaux.append(html_barre("Objectif d'épargne", b[CAT_EPARGNE], objectif, SERIE["Épargne"],
                                   f"{fmt_eur(b[CAT_EPARGNE])} / {fmt_eur(objectif)}"))
        if b[CAT_EPARGNE] >= objectif:
            morceaux.append("<div class='note pos'>✓ Objectif atteint</div>")
    if morceaux and prorata:
        morceaux.append("<div class='note'>Limites mensuelles ramenées à la durée de la période.</div>")
    return "".join(morceaux)


def montants_regle(b: dict[str, float]) -> dict[str, tuple[float, float, float]]:
    """Pour chaque catégorie : (montant prévu par la règle, montant réel, écart prévu − réel).

    Ex. salaire + aides = 2 100 € -> besoins prévus 1 050 €, envies 630 €, épargne 420 €.
    """
    return {cat: (b["reference"] * CIBLES[cat] / 100, b[cat], b["reference"] * CIBLES[cat] / 100 - b[cat])
            for cat in CATEGORIES_SORTIES}


def phrase_regle(b: dict[str, float], je: bool = True) -> str:
    """« Pour respecter la règle, tu peux encore dépenser … »"""
    if not b["reference"]:
        return ""
    m = montants_regle(b)
    morceaux = []
    for cat, mot in ((CAT_BESOINS, "en besoins"), (CAT_ENVIES, "en envies")):
        ecart = m[cat][2]
        morceaux.append(f"<b class='pos'>{fmt_eur(ecart)}</b> {mot}" if ecart >= 0
                        else f"<b class='neg'>rien</b> {mot} (dépassé de {fmt_eur(-ecart)})")
    epargne = m[CAT_EPARGNE][2]
    fin = (f"et mettre encore <b class='warn'>{fmt_eur(epargne)}</b> de côté" if epargne > 0
           else "et ton épargne est déjà atteinte")
    sujet = "tu peux encore dépenser" if je else "il reste"
    html = f"<div class='phrase'>Pour respecter la règle, {sujet} {morceaux[0]} et {morceaux[1]}, {fin}.</div>"
    utilise = sum(max(b[c], 0.0) for c in CATEGORIES_SORTIES)
    depasse = utilise - b["reference"]
    if depasse > 0.005:  # plus utilisé que les revenus réguliers : d'où vient la différence ?
        autres = max(b[CAT_REVENU] - b["reference"], 0.0)
        par_autres = min(depasse, autres)
        par_solde = depasse - par_autres
        origine = []
        if par_autres > 0.005:
            origine.append(f"<b>{fmt_eur(par_autres)}</b> des autres entrées (cadeaux, remboursements, espèces…)")
        if par_solde > 0.005:
            origine.append(f"<b>{fmt_eur(par_solde)}</b> pris sur l'argent déjà présent sur le compte")
        html += (f"<div class='phrase'>Au total, <b>{fmt_eur(utilise)}</b> ont été utilisés pour "
                 f"<b>{fmt_eur(b['reference'])}</b> de revenus réguliers. Les {fmt_eur(depasse)} de plus viennent de "
                 + " et de ".join(origine) + ". L'anneau montre la répartition de tout ce qui a été utilisé.</div>")
    return html


def html_objectifs(b: dict[str, float]) -> str:
    """La règle 50-30-20 en euros : prévu, dépensé, reste à dépenser (ou dépassement), catégorie par catégorie."""
    parts, problemes = analyse_regle(b)
    lignes = []
    if b["reference"]:
        for cat, (prevu, reel, ecart) in montants_regle(b).items():
            nom = NOMS_COURTS[cat]
            if cat == CAT_EPARGNE:
                etat_cat = (f"<span class='warn'>encore {fmt_eur(ecart)} à mettre de côté</span>" if ecart > 0
                            else "<span class='pos'>objectif atteint</span>")
                texte = f"{fmt_eur(reel)} mis de côté sur {fmt_eur(prevu)} prévus"
            else:
                etat_cat = (f"<span class='pos'>reste {fmt_eur(ecart)} à dépenser</span>" if ecart >= 0
                            else f"<span class='neg'>dépassé de {fmt_eur(-ecart)}</span>")
                texte = f"{fmt_eur(reel)} dépensés sur {fmt_eur(prevu)} prévus"
            couleur = C_NEG if (cat != CAT_EPARGNE and ecart < 0) else COULEURS[nom]
            lignes.append(
                html_barre(f"{nom} · {fmt_pct(CIBLES[cat])}", reel, prevu, couleur, f"{fmt_pct(parts[cat])} réalisé")
                + f"<div class='note' style='margin-top:4px'>{texte} · <b>{etat_cat}</b></div>"
            )
    else:  # pas de salaire ni d'aide : on ne peut afficher que des pourcentages des sorties
        for cat in CATEGORIES_SORTIES:
            nom = NOMS_COURTS[cat]
            lignes.append(html_barre(f"{nom} · objectif {fmt_pct(CIBLES[cat])}", parts[cat], 100.0,
                                     COULEURS[nom], f"{fmt_pct(parts[cat])} des sorties", repere=CIBLES[cat]))
    if not b["reference"]:
        etat = ("<div class='note'>Aucun salaire ni aide sur la période : "
                "pourcentages calculés sur les sorties.</div>")
    elif problemes:
        etat = f"<div class='note warn'>● À surveiller : {', '.join(problemes)}.</div>"
    else:
        etat = "<div class='note pos'>✓ Bravo, la règle 50-30-20 est respectée.</div>"
    base = ""
    if b["reference"]:
        autres = b[CAT_REVENU] - b["reference"]
        base = (f"<div class='note'>Base de calcul : salaire, aides et aide familiale = <b>{fmt_eur(b['reference'])}</b>"
                + (f". Les autres entrées ({fmt_eur(autres)} : cadeaux, remboursements…) ne comptent pas "
                   "dans la règle." if autres > 0.005 else ".") + "</div>")
    return "".join(lignes) + etat + base


def html_detail_groupes(df_comp: pd.DataFrame) -> str:
    """Les thèmes saisis (courses, loyer, abonnements…) regroupés automatiquement dans les 3 catégories."""
    blocs = []
    for cat in CATEGORIES_SORTIES:
        nom = NOMS_COURTS[cat]
        lignes_cat = df_comp[df_comp["categorie"] == cat]
        par_theme = (lignes_cat.groupby("sous_categorie")["montant"]
                     .agg(montant="sum", nb=lambda s: int((s > 0).sum()))
                     .query("montant > 0").sort_values("montant", ascending=False))
        total = float(par_theme["montant"].sum())
        if total <= 0:
            continue
        lignes = "".join(
            f"<div class='ligne'><div class='pastille'>{EMOJIS.get(theme, '•')}</div>"
            f"<div class='corps'><div class='t'>{escape(theme)}</div>"
            f"<div class='s'>{nb} opération{'s' if nb > 1 else ''} · {fmt_pct(montant / total * 100)}</div></div>"
            f"<div class='m'>{fmt_eur(montant)}</div></div>"
            for theme, montant, nb in par_theme.itertuples()
        )
        blocs.append(f"<div class='groupe'><div class='groupe-tete'><div class='point' "
                     f"style='background:{COULEURS[nom]}'></div>{nom}<span class='m'>{fmt_eur(total)}</span>"
                     f"</div>{lignes}</div>")
    return "".join(blocs) or "<div class='note'>Aucune dépense sur cette période.</div>"


def vu_du_compte(source: str, destination: str, compte: str | None) -> str:
    """Compte depuis lequel on regarde un virement : celui affiché, sinon le compte courant s'il est concerné,
    sinon le compte de départ."""
    if compte is not None:
        return compte
    return COMPTE_COURANT if COMPTE_COURANT in (source, destination) else source


def html_ligne_operation(op: pd.Series, avec_annee: bool = False, compte: str | None = None) -> str:
    """Une opération, façon application bancaire : icône, catégorie, date · note, montant signé.

    `compte` : compte dont on affiche les mouvements (montants vus de ce compte) ; None pour tous les comptes,
    où une opération hors compte courant porte le nom de son compte."""
    nom = type_affiche(op["categorie"], op["sous_categorie"])
    icone = EMOJIS.get(op["sous_categorie"], "•")
    quand = f"{op['date_operation']:%d/%m/%Y}" if avec_annee else f"{op['date_operation']:%d/%m}"
    source, destination = op.get("compte", COMPTE_COURANT), op.get("vers_compte", COMPTE_COURANT)
    classe = ""
    if op["categorie"] == CAT_VIREMENT:  # « Vers Revolut » / « Depuis Boursobank », vu du compte affiché
        arrive = destination == vu_du_compte(source, destination, compte)
        titre = f"Depuis {nom_compte(source)}" if arrive else f"Vers {nom_compte(destination)}"
        if compte is None and COMPTE_COURANT not in (source, destination):
            titre = f"{nom_compte(source)} → {nom_compte(destination)}"
        valeur = op["montant"] if arrive else -op["montant"]
        note = op["description"].strip()
        sous = "Virement entre mes comptes" + (f" · {escape(note)}" if note and not
                                               note.startswith(("Vers ", "Depuis ")) else "")
    else:
        entree = op["categorie"] == CAT_REVENU
        titre = op["sous_categorie"]
        valeur = op["montant"] if entree else -op["montant"]
        sous = escape(op["description"]) or nom
        if source != COMPTE_COURANT and compte is None:
            sous = f"<span class='compte'>{escape(source)}</span> · {sous}"
        if entree and nom == "Revenus":  # en vert seulement les vrais revenus (pas un retrait du livret)
            classe = "pos"
    return f"""
    <div class="ligne">
      <div class="pastille">{icone}</div>
      <div class="corps"><div class="t">{escape(titre)}</div>
        <div class="s">{quand} · {sous}</div></div>
      <div class="m {classe}">{fmt_eur(valeur, signe=True)}</div>
    </div>"""


def html_mouvements(df: pd.DataFrame, limite: int = 6, avec_annee: bool = False) -> str:
    """Liste des derniers mouvements."""
    lignes = [html_ligne_operation(op, avec_annee) for _, op in df.head(limite).iterrows()]
    return "".join(lignes) or "<div class='note'>Aucun mouvement.</div>"


def html_lettre(prenom: str, notes: list[tuple[str, str]]) -> str:
    """« Notes de votre conseiller » : les enseignements de l'historique, en une lettre."""
    items = "".join(f"<li><span class='ms'>{icone}</span><span>{texte}</span></li>" for icone, texte in notes)
    return (f"<div class='lettre'><div class='surtitre'>Notes de votre conseiller</div>"
            f"<div class='lettre-intro'>Cher {escape(prenom)},</div><ul>{items}</ul>"
            f"<div class='signature'>— Votre banquier privé</div></div>")


def entete_section(surtitre: str, titre: str, texte: str = "") -> None:
    st.html(f"<div class='entete-section'><div class='surtitre'>{escape(surtitre)}</div>"
            f"<div class='question'>{escape(titre)}</div>"
            + (f"<div class='precision'>{texte}</div>" if texte else "") + "</div>")


def voir_donnees(donnees: pd.DataFrame, cle: str, config: dict | None = None) -> None:
    """Version tableau d'un graphique (lisible sans les couleurs, exportable)."""
    with st.expander("Voir les données", icon=":material/table_view:"):
        st.dataframe(donnees, hide_index=True, column_config=config or {}, key=f"donnees_{cle}")


# =====================================================================
# 6. GRAPHIQUES (PLOTLY)
# =====================================================================

# Pas de zoom ni de barre d'outils : les graphiques se lisent, ils ne se manipulent pas.
CONFIG_GRAPHE = {"displayModeBar": False, "scrollZoom": False}


def styliser(fig, hauteur: int = 300, legende: bool = True, suffixe: str = " €", zero: bool = False):
    """Style commun : traits fins, grille discrète, info-bulles sombres à liseré doré."""
    fig.update_layout(
        height=hauteur, margin=dict(t=10, b=8, l=4, r=6),
        paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)",
        font=dict(family="Manrope, sans-serif", size=12, color=ENCRE_2), showlegend=legende,
        legend=dict(orientation="h", yanchor="bottom", y=1.02, xanchor="left", x=0, title=None,
                    font=dict(color=ENCRE_2, size=12), itemsizing="constant"),
        dragmode=False, separators=", ",  # virgule décimale, espace pour les milliers
        barcornerradius=4,
        hoverlabel=dict(bgcolor=SURFACE_2, bordercolor="rgba(243,245,247,0.14)",
                        font=dict(family="Manrope, sans-serif", size=13, color=ENCRE)),
    )
    fig.update_xaxes(showgrid=False, zeroline=False, title=None, fixedrange=True, showline=True,
                     linecolor=AXE, linewidth=1, tickfont=dict(color=MUET), ticks="")
    fig.update_yaxes(gridcolor=GRILLE, gridwidth=1, zeroline=zero, zerolinecolor=AXE, zerolinewidth=1,
                     title=None, ticksuffix=suffixe, tickformat=",.0f", fixedrange=True,
                     tickfont=dict(color=MUET), showline=False)
    fig.update_traces(marker_line_color=SURFACE, marker_line_width=2, selector=dict(type="bar"))
    return fig


def lavis(couleur: str, opacite: float) -> str:
    """« #279A86 » -> « rgba(39,154,134,0.42) » : un aplat transparent plutôt qu'un bloc saturé."""
    r, v, b = (int(couleur[i:i + 2], 16) for i in (1, 3, 5))
    return f"rgba({r},{v},{b},{opacite})"


def tracer(fig, cle: str) -> None:
    st.plotly_chart(fig, config=CONFIG_GRAPHE, key=f"graphe_{cle}")


def libelle_jour(jour: pd.Timestamp) -> str:
    """« sam. 04/10 »"""
    return f"{JOURS_FR[jour.weekday()]} {jour:%d/%m}"


def jours_affiches(periode: Periode) -> pd.DatetimeIndex:
    """Jours de la période, sans aller dans le futur."""
    debut, fin = pd.Timestamp(periode.debut), pd.Timestamp(periode.fin)
    return pd.date_range(debut, max(debut, min(fin, pd.Timestamp(aujourdhui()))), freq="D")


def graphique_solde(df_comp: pd.DataFrame, periode: Periode, prevision: dict | None = None):
    """Courbe de l'argent sur le compte à la fin de chaque jour. Retourne (figure, données).

    `prevision` (voir prevision_fin_mois) ajoute un prolongement en pointillés jusqu'à la fin du mois.
    """
    jours = jours_affiches(periode)
    flux = montant_signe(df_comp).groupby(df_comp["date_operation"].dt.normalize()).sum()
    depart = float(flux[flux.index < jours[0]].sum())
    solde = flux.reindex(jours, fill_value=0.0).cumsum() + depart
    donnees = pd.DataFrame({"jour": jours, "solde": solde.to_numpy(dtype=float),
                            "libelle": [libelle_jour(j) for j in jours]})

    fig = go.Figure()
    fig.add_scatter(x=donnees["jour"], y=donnees["solde"], mode="lines", name="Solde", customdata=donnees[["libelle"]],
                    line=dict(color=ACCENT, width=2, shape="hv"), fill="tozeroy", fillcolor="rgba(57,135,229,0.12)",
                    hovertemplate="<b>%{customdata[0]}</b><br>Sur le compte : %{y:,.2f} €<extra></extra>")
    if (donnees["solde"] < 0).any():
        fig.add_hline(y=0, line=dict(color=C_NEG, width=1, dash="dot"))
    dernier = donnees.iloc[-1]
    fig.add_scatter(x=[dernier["jour"]], y=[dernier["solde"]], mode="markers+text",
                    marker=dict(size=10, color=ACCENT, line=dict(color=SURFACE, width=2)), text=[fmt_eur(dernier["solde"])],
                    textposition="top left", textfont=dict(color=ENCRE), hoverinfo="skip", showlegend=False)
    if prevision and prevision["jours_restants"] > 0:
        fin = pd.Timestamp(prevision["fin"])
        fig.add_scatter(x=[dernier["jour"], fin], y=[dernier["solde"], prevision["solde_fin"]],
                        mode="lines+markers+text", line=dict(color=ACCENT_CLAIR, width=2, dash="dot"),
                        marker=dict(size=[0, 9], color=ACCENT_CLAIR), text=["", f"≈ {fmt_eur(prevision['solde_fin'])}"],
                        textposition="bottom left", textfont=dict(color=ENCRE_2), showlegend=False,
                        hovertemplate="Prévision au %{x|%d/%m} : %{y:,.2f} €<extra></extra>")
    fig.update_xaxes(tickformat="%d/%m")
    return styliser(fig, 280, legende=False), donnees


def graphique_depenses_jour(brut_periode: pd.DataFrame, periode: Periode, avec_detail: bool):
    """Bâtons des dépenses de chaque jour (besoins + envies empilés), détail au survol.

    Retourne (figure, moyenne par jour, total par jour).
    """
    jours = jours_affiches(periode)
    depenses = brut_periode[brut_periode["categorie"].isin(CATEGORIES_DEPENSES)]
    depenses = depenses.assign(jour=depenses["date_operation"].dt.normalize())
    lignes = []
    for cat in CATEGORIES_DEPENSES:
        d = depenses[depenses["categorie"] == cat]
        totaux = d.groupby("jour")["montant"].sum().reindex(jours, fill_value=0.0)
        details = d.groupby(["jour", "sous_categorie"])["montant"].sum()
        for jour, total in totaux.items():
            detail = ""
            if avec_detail and total > 0:
                themes = details.loc[jour].sort_values(ascending=False)
                detail = "<br>".join(f"{escape(t)} : {fmt_eur(m)}" for t, m in themes.items())
            lignes.append({"jour": jour, "groupe": NOMS_COURTS[cat], "montant": float(total),
                           "libelle": libelle_jour(jour), "detail": detail})
    donnees = pd.DataFrame(lignes)

    fig = px.bar(donnees, x="jour", y="montant", color="groupe", color_discrete_map=COULEURS,
                 custom_data=["libelle", "detail"], category_orders={"groupe": ["Besoins", "Envies"]})
    fig.update_traces(hovertemplate="<b>%{customdata[0]}</b> · %{fullData.name} : %{y:,.2f} €"
                                    "<br>%{customdata[1]}<extra></extra>")
    par_jour = donnees.groupby("jour")["montant"].sum()
    moyenne = float(par_jour.sum()) / len(jours)
    if moyenne > 0:
        fig.add_hline(y=moyenne, line=dict(color=ENCRE_2, width=1, dash="dot"),
                      annotation_text=f"moyenne {fmt_eur0(moyenne)}", annotation_position="top left",
                      annotation_font=dict(color=ENCRE_2, size=11))
    fig.update_layout(barmode="stack", bargap=0.3)
    fig.update_xaxes(tickformat="%d/%m")
    return styliser(fig, 300), moyenne, par_jour


def graphique_camembert(b: dict[str, float]):
    """Anneau 50-30-20 : comment le salaire et les aides ont été utilisés (besoins, envies, épargne, reste)."""
    valeurs = {NOMS_COURTS[c]: max(b[c], 0.0) for c in CATEGORIES_SORTIES}
    non_utilise = b["reference"] - sum(valeurs.values())
    if b["reference"] > 0 and non_utilise > 0:
        valeurs["Pas encore utilisé"] = non_utilise
    donnees = pd.DataFrame({"part": list(valeurs), "montant": list(valeurs.values())}).query("montant > 0")
    fig = px.pie(donnees, names="part", values="montant", color="part", color_discrete_map=COULEURS, hole=0.8)
    fig.update_traces(sort=False, textinfo="none", marker=dict(line=dict(color=SURFACE, width=4)),
                      hovertemplate="<b>%{label}</b><br>%{value:,.2f} € · %{percent}<extra></extra>")
    styliser(fig, 290)
    fig.update_layout(legend=dict(orientation="h", yanchor="top", y=-0.02, xanchor="center", x=0.5))
    utilise = sum(max(b[c], 0.0) for c in CATEGORIES_SORTIES)
    if b["reference"] > 0:
        part = utilise / b["reference"] * 100
        fig.add_annotation(x=0.5, y=0.56, xref="paper", yref="paper", showarrow=False, text=f"<b>{part:.0f} %</b>",
                           font=dict(size=28 if part < 1000 else 22, color=C_NEG if part > 100 else ENCRE,
                                     family="Manrope, sans-serif"))
        fig.add_annotation(x=0.5, y=0.42, xref="paper", yref="paper", showarrow=False,
                           text="des revenus réguliers", font=dict(size=11, color=ENCRE_2, family="Manrope, sans-serif"))
    return fig


def graphique_mensuel(df_comp: pd.DataFrame, nb_mois: int = 6):
    """Mois après mois : besoins, envies et épargne empilés en barres, revenus en ligne."""
    mois = pd.period_range(mois_courant() - (nb_mois - 1), mois_courant(), freq="M")
    groupe = df_comp["categorie"].map(NOMS_COURTS)
    table = (df_comp.assign(groupe=groupe).groupby(["mois", "groupe"])["montant"].sum()
             .unstack(fill_value=0.0).reindex(index=mois, columns=[*GROUPES, "Revenus"], fill_value=0.0))
    table["libelle"] = [libelle_mois_court(p) for p in table.index]
    barres = table.reset_index(drop=True).melt(id_vars="libelle", value_vars=GROUPES,
                                               var_name="groupe", value_name="montant")
    fig = px.bar(barres, x="libelle", y="montant", color="groupe", color_discrete_map=COULEURS,
                 category_orders={"groupe": GROUPES})
    fig.update_traces(hovertemplate="<b>%{x}</b> · %{fullData.name} : %{y:,.2f} €<extra></extra>")
    fig.add_scatter(x=table["libelle"], y=table["Revenus"], mode="lines+markers", name="Revenus",
                    line=dict(color=COULEURS["Revenus"], width=2), marker=dict(size=8, line=dict(color=SURFACE, width=2)),
                    hovertemplate="<b>%{x}</b> · Revenus : %{y:,.2f} €<extra></extra>")
    fig.update_layout(barmode="relative", bargap=0.45)
    return styliser(fig, 320, zero=True)


def graphique_comparaison(b1: dict[str, float], b2: dict[str, float], nom1: str, nom2: str):
    """Barres côte à côte : revenus, besoins, envies, épargne pour les deux périodes."""
    lignes = []
    for nom_periode, b in ((nom1, b1), (nom2, b2)):
        for cat in (CAT_REVENU, *CATEGORIES_SORTIES):
            lignes.append({"poste": NOMS_COURTS[cat], "periode": nom_periode, "montant": b[cat]})
    fig = px.bar(pd.DataFrame(lignes), x="poste", y="montant", color="periode", barmode="group",
                 color_discrete_sequence=[PALETTE[0], PALETTE[1]])
    fig.update_traces(hovertemplate="<b>%{x}</b> · %{fullData.name}<br>%{y:,.2f} €<extra></extra>")
    fig.update_layout(bargap=0.35, bargroupgap=0.08)
    return styliser(fig, 280)


# --- Graphiques des analyses ------------------------------------------------------------------

def fig_flux_mensuels(tm: pd.DataFrame):
    """Revenus au-dessus de l'axe, dépenses en dessous : la respiration du compte, mois par mois."""
    fig = go.Figure()
    fig.add_bar(x=tm["libelle"], y=tm["revenus"], name="Revenus", marker_color=SERIE["Revenus"],
                customdata=tm[["reste", "epargne"]],
                hovertemplate="<b>%{x}</b><br>Revenus : %{y:,.0f} €<br>Épargne nette : %{customdata[1]:,.0f} €"
                              "<br>Reste du mois : %{customdata[0]:,.0f} €<extra></extra>")
    fig.add_bar(x=tm["libelle"], y=-tm["depenses"], name="Dépenses", marker_color=SERIE["Dépenses"],
                customdata=tm[["depenses", "besoins", "envies"]],
                hovertemplate="<b>%{x}</b><br>Dépenses : %{customdata[0]:,.0f} €"
                              "<br>dont besoins %{customdata[1]:,.0f} € · envies %{customdata[2]:,.0f} €<extra></extra>")
    fig.update_layout(barmode="relative", bargap=0.42, hovermode="x unified")
    return styliser(fig, 340, zero=True)


def fig_solde_historique(comp_tout: pd.DataFrame, debut: date, fin: date):
    """Le solde du compte jour après jour, avec le point le plus bas et le plus haut."""
    flux = montant_signe(comp_tout).groupby(comp_tout["date_operation"].dt.normalize()).sum()
    tous = pd.date_range(min(flux.index.min(), pd.Timestamp(debut)), pd.Timestamp(fin), freq="D")
    solde = flux.reindex(tous, fill_value=0.0).cumsum()
    solde = solde[solde.index >= pd.Timestamp(debut)]
    fig = go.Figure()
    fig.add_scatter(x=solde.index, y=solde.values, mode="lines", name="Solde", line=dict(color=ACCENT, width=2),
                    fill="tozeroy", fillcolor="rgba(57,135,229,0.12)",
                    hovertemplate="%{x|%d/%m/%Y}<br><b>%{y:,.2f} €</b><extra></extra>")
    for jour, etiquette, position in ((solde.idxmin(), "au plus bas", "bottom center"),
                                      (solde.idxmax(), "au plus haut", "top center")):
        fig.add_scatter(x=[jour], y=[solde[jour]], mode="markers+text", showlegend=False, hoverinfo="skip",
                        marker=dict(size=9, color=ACCENT_CLAIR, line=dict(color=SURFACE, width=2)),
                        text=[f"{etiquette} · {fmt_eur0(solde[jour])}"], textposition=position,
                        textfont=dict(color=ENCRE_2, size=11))
    if (solde < 0).any():
        fig.add_hline(y=0, line=dict(color=C_NEG, width=1, dash="dot"))
    fig.update_layout(hovermode="x unified")
    fig.update_xaxes(tickformat="%b %y")
    return styliser(fig, 300, legende=False), solde


def fig_regle_historique(tm: pd.DataFrame):
    """Part du salaire et des aides consacrée aux besoins, aux envies et à l'épargne (sur 3 mois glissants :
    un loyer payé le 30 et un salaire reçu le 1er ne doivent pas faire exploser un mois isolé)."""
    lisse = tm[["reference", "besoins", "envies", "epargne"]].rolling(3, min_periods=1).sum()
    base = lisse["reference"].where(lisse["reference"] > 0)
    fig = go.Figure()
    for col, nom, cat in (("besoins", "Besoins", CAT_BESOINS), ("envies", "Envies", CAT_ENVIES),
                          ("epargne", "Épargne", CAT_EPARGNE)):
        y = (lisse[col] / base * 100).round(0)
        fig.add_scatter(x=tm["libelle"], y=y, mode="lines+markers", name=f"{nom} (cible {CIBLES[cat]:.0f} %)",
                        line=dict(color=SERIE[nom], width=2), marker=dict(size=7, line=dict(color=SURFACE, width=2)),
                        connectgaps=False, hovertemplate=f"{nom} : %{{y:.0f}} %<extra></extra>")
        fig.add_hline(y=CIBLES[cat], line=dict(color=SERIE[nom], width=1, dash="dot"), opacity=0.7)
    fig.update_layout(hovermode="x unified")
    styliser(fig, 320, suffixe=" %", zero=True)
    fig.update_yaxes(range=[-60, 170])
    return fig


def fig_treemap(comp: pd.DataFrame):
    d = (depenses_de(comp).groupby(["categorie", "sous_categorie"])["montant"].sum().reset_index()
         .query("montant > 0"))
    d["groupe"] = d["categorie"].map(NOMS_COURTS)
    fig = px.treemap(d, path=["groupe", "sous_categorie"], values="montant", color="groupe",
                     color_discrete_map={"Besoins": SERIE["Besoins"], "Envies": SERIE["Envies"], "(?)": SURFACE})
    fig.update_traces(texttemplate="<b>%{label}</b><br>%{value:,.0f} €<br>%{percentRoot:.0%}",
                      textfont=dict(color="#FFFFFF", family="Manrope, sans-serif", size=13),
                      marker=dict(line=dict(color=SURFACE, width=2), cornerradius=6),
                      root_color="rgba(0,0,0,0)", tiling=dict(pad=3),
                      hovertemplate="<b>%{label}</b><br>%{value:,.2f} € · %{percentRoot:.1%} des dépenses<extra></extra>")
    fig.update_layout(height=420, margin=dict(t=4, b=4, l=0, r=0), paper_bgcolor="rgba(0,0,0,0)",
                      font=dict(family="Manrope, sans-serif"),
                      hoverlabel=dict(bgcolor=SURFACE_2, bordercolor="rgba(243,245,247,0.14)",
                                      font=dict(size=13, color=ENCRE)))
    return fig


def fig_themes_mensuels(comp: pd.DataFrame, comp_tout: pd.DataFrame, debut: date, fin: date):
    """Dépenses empilées par thème, mois par mois (7 thèmes principaux + « Autres »)."""
    top = rang_sous_categories(comp_tout, 7)
    couleurs = {t: PALETTE[i] for i, t in enumerate(top)} | {"Autres": SERIE["Autres"]}
    d = depenses_de(comp).assign(serie=lambda x: x["sous_categorie"].where(x["sous_categorie"].isin(top), "Autres"))
    mois = mois_entre(debut, fin)
    table = (d.groupby(["mois", "serie"])["montant"].sum().unstack(fill_value=0.0)
             .reindex(index=mois, columns=[*top, "Autres"], fill_value=0.0))
    fig = go.Figure()
    for serie in [*top, "Autres"]:
        fig.add_bar(x=[libelle_mois_court(p) for p in mois], y=table[serie], name=serie,
                    marker_color=couleurs[serie], hovertemplate=f"{escape(serie)} : %{{y:,.0f}} €<extra></extra>")
    fig.update_layout(barmode="relative", bargap=0.4, hovermode="x unified")
    return styliser(fig, 380, zero=True), table


def fig_barres_horizontales(noms: list[str], valeurs: list[float], couleur: str, hauteur: int | None = None,
                            textes: list[str] | None = None, survol: str = "%{y} : %{x:,.2f} €"):
    """Classement en barres horizontales, valeur au bout de la barre."""
    fig = go.Figure()
    fig.add_bar(y=noms[::-1], x=valeurs[::-1], orientation="h", marker_color=couleur,
                text=(textes or [fmt_eur0(v) for v in valeurs])[::-1], textposition="outside",
                textfont=dict(color=ENCRE_2, size=12), cliponaxis=False,
                hovertemplate=survol + "<extra></extra>")
    fig.update_layout(bargap=0.38)
    styliser(fig, hauteur or max(220, 34 * len(noms) + 30), legende=False)
    fig.update_xaxes(showgrid=False, showticklabels=False, showline=False)  # la valeur est au bout de la barre
    fig.update_yaxes(showgrid=False, ticksuffix="", tickfont=dict(color=ENCRE_2, size=12), automargin=True)
    fig.update_layout(margin=dict(t=6, b=6, l=4, r=70))
    return fig


def fig_tickets(brut: pd.DataFrame):
    """Combien d'achats dans chaque tranche de prix, et ce qu'ils pèsent au total."""
    d = depenses_de(brut)
    d = d[~d["sous_categorie"].isin(COMPENSATIONS)]
    bornes = [0, 5, 10, 20, 50, 100, 500, float("inf")]
    noms = ["< 5 €", "5–10 €", "10–20 €", "20–50 €", "50–100 €", "100–500 €", "> 500 €"]
    tranches = pd.cut(d["montant"], bornes, labels=noms, right=False)
    t = d.groupby(tranches, observed=False)["montant"].agg(nb="count", total="sum").reindex(noms, fill_value=0)
    fig = go.Figure()
    fig.add_bar(x=noms, y=t["nb"], marker_color=ACCENT, customdata=t[["total"]],
                text=[f"{int(n)}" for n in t["nb"]], textposition="outside", textfont=dict(color=ENCRE_2),
                cliponaxis=False,
                hovertemplate="<b>%{x}</b><br>%{y} achats · %{customdata[0]:,.0f} € au total<extra></extra>")
    fig.update_layout(bargap=0.45)
    styliser(fig, 280, legende=False, suffixe="")
    fig.update_layout(margin=dict(t=24, b=8, l=4, r=6))
    return fig, t


def fig_calendrier(brut: pd.DataFrame, fin: date):
    """Calendrier des dépenses des 12 derniers mois : une case par jour, plus dorée quand on dépense plus."""
    d = depenses_de(brut)
    d = d[~d["sous_categorie"].isin(COMPENSATIONS)]
    debut = fin - timedelta(days=364)
    debut -= timedelta(days=debut.weekday())  # on commence un lundi
    jours = pd.date_range(debut, fin, freq="D")
    par_jour = d.groupby(d["date_operation"].dt.normalize())["montant"].sum().reindex(jours, fill_value=0.0)
    semaines = sorted({(j - pd.Timedelta(days=j.weekday())) for j in jours})
    index_semaine = {s: i for i, s in enumerate(semaines)}
    z = [[None] * len(semaines) for _ in range(7)]
    texte = [[""] * len(semaines) for _ in range(7)]
    for jour, montant in par_jour.items():
        i = index_semaine[jour - pd.Timedelta(days=jour.weekday())]
        z[jour.weekday()][i] = float(montant)
        texte[jour.weekday()][i] = f"{JOURS_FR[jour.weekday()]} {jour:%d/%m/%Y}"
    plafond = float(par_jour[par_jour > 0].quantile(0.92)) if (par_jour > 0).any() else 1.0
    fig = go.Figure(go.Heatmap(
        z=z, x=[s.strftime("%d/%m/%y") for s in semaines], y=JOURS_FR, text=texte, xgap=3, ygap=3,
        colorscale=RAMPE, zmin=0, zmax=max(plafond, 1.0), showscale=True,
        colorbar=dict(thickness=8, outlinewidth=0, ticksuffix=" €", tickfont=dict(color=MUET, size=10), len=0.9),
        hovertemplate="%{text}<br><b>%{z:,.2f} €</b> dépensés<extra></extra>",
    ))
    debut_mois = [s for s in semaines if s.day <= 7]
    fig.update_xaxes(tickvals=[s.strftime("%d/%m/%y") for s in debut_mois],
                     ticktext=[MOIS_COURTS[s.month - 1] for s in debut_mois])
    styliser(fig, 250, legende=False, suffixe="")
    fig.update_yaxes(autorange="reversed", showgrid=False, tickfont=dict(color=MUET, size=11))
    fig.update_xaxes(showline=False)
    return fig, par_jour


def fig_jours_semaine(brut: pd.DataFrame, debut: date, fin: date):
    d = depenses_courantes(compenser(brut))
    jours = pd.date_range(debut, fin, freq="D")
    nb_jours = pd.Series(jours.weekday).value_counts().reindex(range(7), fill_value=0)
    totaux = d.groupby(d["date_operation"].dt.weekday)["montant"].sum().reindex(range(7), fill_value=0.0)
    moyenne = (totaux / nb_jours.replace(0, pd.NA)).fillna(0.0).astype(float)
    fig = go.Figure()
    fig.add_bar(x=[j.capitalize() for j in JOURS_LONGS], y=moyenne, marker_color=ACCENT,
                text=[fmt_eur0(v) for v in moyenne], textposition="outside", textfont=dict(color=ENCRE_2),
                cliponaxis=False, hovertemplate="<b>%{x}</b> : %{y:,.2f} € en moyenne<extra></extra>")
    fig.update_layout(bargap=0.62)
    styliser(fig, 270, legende=False)
    fig.update_layout(margin=dict(t=24, b=8, l=4, r=6))
    return fig, moyenne


def fig_cycle_paie(brut_tout: pd.DataFrame, debuts: list[date]):
    """Dépenses cumulées depuis la paie : le rythme habituel comparé au cycle en cours."""
    courantes = depenses_courantes(compenser(brut_tout))
    par_jour = courantes.groupby(courantes["date_operation"].dt.normalize())["montant"].sum()
    courbes = []
    for d1, d2 in zip(debuts, debuts[1:]):
        duree = (d2 - d1).days
        if 20 <= duree <= 40:
            jours = pd.date_range(d1, d1 + timedelta(days=min(duree, 31) - 1), freq="D")
            courbes.append(par_jour.reindex(jours, fill_value=0.0).cumsum().to_numpy())
    if len(courbes) < 3:
        return None, None
    longueur = max(len(c) for c in courbes)
    moyenne = [sum(c[i] for c in courbes if len(c) > i) / sum(1 for c in courbes if len(c) > i)
               for i in range(longueur)]
    en_cours_debut = debuts[-1]
    jours_cours = pd.date_range(en_cours_debut, min(aujourdhui(), en_cours_debut + timedelta(days=40)), freq="D")
    en_cours = par_jour.reindex(jours_cours, fill_value=0.0).cumsum()
    fig = go.Figure()
    fig.add_scatter(x=list(range(longueur)), y=moyenne, mode="lines", name=f"Ton rythme habituel ({len(courbes)} cycles)",
                    line=dict(color=SERIE["Besoins"], width=2),
                    hovertemplate="Jour %{x} : %{y:,.0f} € en moyenne<extra></extra>")
    fig.add_scatter(x=list(range(len(en_cours))), y=en_cours.values, mode="lines+markers",
                    name=f"Cycle en cours (depuis le {en_cours_debut:%d/%m})",
                    line=dict(color=ACCENT, width=2), marker=dict(size=[0] * (len(en_cours) - 1) + [9], color=ACCENT,
                                                              line=dict(color=SURFACE, width=2)),
                    hovertemplate="Jour %{x} : %{y:,.0f} €<extra></extra>")
    fig.update_layout(hovermode="x unified")
    styliser(fig, 300)
    fig.update_xaxes(title=dict(text="jours depuis la paie", font=dict(color=MUET, size=11)), tickformat="d")
    return fig, {"moyenne": moyenne, "en_cours": en_cours, "debut": en_cours_debut}


def fig_empile(tm_index: pd.PeriodIndex, table: pd.DataFrame, couleurs: dict[str, str], hauteur: int = 330):
    """Barres empilées génériques (une colonne de `table` = une série)."""
    fig = go.Figure()
    for serie in table.columns:
        fig.add_bar(x=[libelle_mois_court(p) for p in tm_index], y=table[serie], name=serie,
                    marker_color=couleurs[serie], hovertemplate=f"{escape(str(serie))} : %{{y:,.0f}} €<extra></extra>")
    fig.update_layout(barmode="relative", bargap=0.4, hovermode="x unified")
    return styliser(fig, hauteur, zero=True)


def fig_polarite(libelles: list[str], valeurs: pd.Series, nom_pos: str, nom_neg: str, hauteur: int = 300):
    """Barres positives / négatives (épargne nette, résultat…) : deux couleurs qui s'opposent."""
    fig = go.Figure()
    fig.add_bar(x=libelles, y=valeurs.clip(lower=0), name=nom_pos, marker_color=SERIE["Épargne"],
                hovertemplate=f"{nom_pos} : %{{y:,.0f}} €<extra></extra>")
    fig.add_bar(x=libelles, y=valeurs.clip(upper=0), name=nom_neg, marker_color=SERIE["Dépenses"],
                hovertemplate=f"{nom_neg} : %{{y:,.0f}} €<extra></extra>")
    fig.update_layout(barmode="relative", bargap=0.4, hovermode="x unified")
    return styliser(fig, hauteur, zero=True)


# =====================================================================
# 7. ÉCRANS DE CONNEXION
# =====================================================================

# --- Session persistante (« se souvenir de cet appareil ») ---------------------------------
# Après une connexion réussie, le navigateur reçoit un cookie contenant un jeton signé :
#     <profil_id>.<expiration>.<signature HMAC>
# La signature inclut le hachage actuel du PIN : changer de PIN invalide tous les jetons
# existants. La clé de signature dérive des secrets (ou de SESSION_SECRET s'il est défini) :
# changer le mot de passe du groupe déconnecte donc tous les appareils.

def _cle_session() -> bytes:
    secret = lire_secret("SESSION_SECRET")
    if secret:
        return secret.encode()
    base = f"budget-session|{lire_secret('APP_PASSWORD') or ''}|{lire_secret('SUPABASE_KEY') or ''}"
    return hashlib.sha256(base.encode()).digest()


def _signature(profil_id: str, expiration: str, pin_hash: str) -> str:
    message = f"{profil_id}.{expiration}.{pin_hash}".encode()
    return hmac.new(_cle_session(), message, hashlib.sha256).hexdigest()


def creer_jeton(profil_id: str, pin_hash: str) -> str:
    expiration = str(int(time.time()) + DUREE_SESSION_JOURS * 86_400)
    return f"{profil_id}.{expiration}.{_signature(profil_id, expiration, pin_hash)}"


def profil_du_jeton(jeton: str) -> str | None:
    """Retourne l'identifiant du profil si le jeton est valide (peut lever une erreur réseau)."""
    morceaux = jeton.split(".")
    if len(morceaux) != 3 or not morceaux[1].isdigit() or int(morceaux[1]) < time.time():
        return None
    profil_id, expiration, signature = morceaux
    stocke = lire_pin_hash(profil_id)
    if not stocke or not hmac.compare_digest(signature, _signature(profil_id, expiration, stocke)):
        return None
    return profil_id


def memoriser_appareil(profil_id: str, pin_hash: str) -> None:
    """Demande la pose du cookie de session au prochain affichage."""
    st.session_state["cookie_action"] = creer_jeton(profil_id, pin_hash)


def restaurer_session() -> None:
    """À l'ouverture de l'app : reconnecte automatiquement si l'appareil a un jeton valide."""
    if st.session_state.get("session_verifiee"):
        return
    try:
        jeton = st.context.cookies.get(COOKIE_SESSION)
    except Exception:
        jeton = None
    if jeton and not st.session_state.get("profil_id"):
        try:
            profil_id = profil_du_jeton(jeton)
        except Exception:
            return  # base injoignable : on réessaiera au prochain affichage sans effacer le cookie
        if profil_id:
            st.session_state["authentifie"] = True
            st.session_state["profil_id"] = profil_id
        else:
            st.session_state["cookie_action"] = ""  # jeton expiré ou révoqué : on le nettoie
    st.session_state["session_verifiee"] = True


def synchroniser_cookie() -> None:
    """Pose ou efface le cookie dans le navigateur (Streamlit ne sait pas le faire côté serveur)."""
    action = st.session_state.pop("cookie_action", None)
    if action is None:
        return
    duree = DUREE_SESSION_JOURS * 86_400 if action else 0
    st.html(
        f"""<script>document.cookie = "{COOKIE_SESSION}={action}; Max-Age={duree}; Path=/; SameSite=Lax"
        + (location.protocol === "https:" ? "; Secure" : "");</script>""",
        unsafe_allow_javascript=True,
    )


def entete_marque() -> None:
    st.html(f"<div class='marque-bloc centre'><div class='monogramme'>C</div>"
            f"<div><div class='marque'>{MARQUE}</div><div class='marque-sous'>{SOUS_MARQUE}</div></div>"
            f"<div class='filet'></div></div>")


def ecran_mot_de_passe_commun() -> bool:
    """1re porte : mot de passe partagé entre amis. Retourne True si franchie."""
    if st.session_state.get("authentifie"):
        return True

    attendu = lire_secret("APP_PASSWORD")
    if attendu is None:
        st.error("Le secret `APP_PASSWORD` est introuvable. "
                 "Renseignez-le dans `.streamlit/secrets.toml` (ou dans les Secrets de Streamlit Cloud).")
        return False

    with st.container(key="ecran_login"), carte("login"):
        entete_marque()
        with st.form("connexion", border=False):
            saisie = st.text_input("Mot de passe du cercle", type="password")
            valider = st.form_submit_button("Entrer", type="primary", width="stretch")
        if valider:
            if hmac.compare_digest(saisie.encode(), attendu.encode()):
                st.session_state["authentifie"] = True
                st.rerun()
            st.error("Mot de passe incorrect.")
        st.html("<div class='note' style='text-align:center'>Accès réservé aux membres du cercle.</div>")
    return False


def tenter_connexion(profil: pd.Series, pin: str) -> None:
    """Vérifie le PIN, avec blocage temporaire après plusieurs échecs."""
    essais = st.session_state.setdefault("essais_pin", {})
    nb, bloque_jusqua = essais.get(profil["id"], (0, 0.0))
    if time.time() < bloque_jusqua:
        st.error(f"Trop d'essais. Réessaie dans {int(bloque_jusqua - time.time()) + 1} s.")
        return
    try:
        stocke = lire_pin_hash(profil["id"])
    except Exception as exc:  # noqa: BLE001
        st.error(message_erreur_db(exc))
        return
    if stocke and pin_correct(pin, stocke):
        essais.pop(profil["id"], None)
        st.session_state["profil_id"] = profil["id"]
        memoriser_appareil(profil["id"], stocke)
        st.rerun()
    nb += 1
    if nb >= MAX_ESSAIS_PIN:
        essais[profil["id"]] = (0, time.time() + BLOCAGE_SECONDES)
        st.error(f"Code incorrect. Trop d'essais : attends {BLOCAGE_SECONDES} s.")
    else:
        essais[profil["id"]] = (nb, 0.0)
        st.error(f"Code incorrect ({MAX_ESSAIS_PIN - nb} essai(s) restant(s)).")


def formulaire_creation_profil(profils: pd.DataFrame) -> None:
    with st.form("creation_profil", border=False):
        prenom = st.text_input("Prénom", max_chars=30, placeholder="Léa")
        c1, c2 = st.columns(2)
        pin = c1.text_input("Code PIN", type="password", max_chars=6, placeholder="4 à 6 chiffres",
                            key="pin_creation")
        pin2 = c2.text_input("Confirmation", type="password", max_chars=6, placeholder="Répéter le code",
                             key="pin_confirmation")
        visibilite = st.radio("Visibilité de mon budget", list(VISIBILITES),
                              format_func=VISIBILITES.get, index=1,
                              help="Modifiable à tout moment depuis le menu Profil.")
        valider = st.form_submit_button("Créer mon profil", type="primary", width="stretch")
    if not valider:
        return

    prenom = " ".join(prenom.split()).title()
    erreurs = []
    if not re.fullmatch(r"[A-Za-zÀ-ÖØ-öø-ÿ' .-]{2,30}", prenom):
        erreurs.append("Le prénom doit contenir 2 à 30 lettres.")
    elif prenom.casefold() in set(profils["prenom"].str.casefold()):
        erreurs.append("Ce prénom est déjà utilisé : choisis-en un autre (ex. « Léa M. »).")
    if not pin_valide(pin):
        erreurs.append("Le code PIN doit contenir 4 à 6 chiffres.")
    elif pin != pin2:
        erreurs.append("Les deux codes PIN ne correspondent pas.")
    for erreur in erreurs:
        st.error(erreur)
    if erreurs:
        return

    pin_hash = hacher_pin(pin)
    try:
        st.session_state["profil_id"] = creer_profil(prenom, pin_hash, visibilite)
    except Exception as exc:  # noqa: BLE001
        st.error(message_erreur_db(exc))
        return
    memoriser_appareil(st.session_state["profil_id"], pin_hash)
    notifier(f"Bienvenue {prenom}. Ajoute ta première opération.")
    st.session_state["onglet"] = ONGLETS[2]
    st.rerun()


def ecran_choix_profil(profils: pd.DataFrame) -> None:
    """2e porte : choisir son profil + PIN, ou en créer un."""
    afficher_notification()
    with st.container(key="ecran_login"), carte("login"):
        entete_marque()
        onglet_connexion, onglet_creation = st.tabs(["Connexion", "Nouveau membre"])
        with onglet_connexion:
            if profils.empty:
                st.caption("Aucun profil pour l'instant : crée le premier dans « Nouveau membre ».")
            else:
                prenom = st.pills("Qui êtes-vous ?", profils["prenom"].tolist(), key="login_prenom")
                if prenom:
                    profil = profils[profils["prenom"] == prenom].iloc[0]
                    with st.form("pin", border=False):
                        pin = st.text_input(f"Code PIN de {prenom}", type="password", max_chars=6,
                                            key="pin_login")
                        valider = st.form_submit_button("Se connecter", type="primary", width="stretch")
                    if valider:
                        tenter_connexion(profil, pin)
        with onglet_creation:
            formulaire_creation_profil(profils)


# =====================================================================
# 8. INTERFACE CONNECTÉE
# =====================================================================

def deconnecter() -> None:
    """Déconnexion explicite : oublie aussi l'appareil (le cookie de session est effacé)."""
    for cle in ("profil_id", "onglet", "login_prenom"):
        st.session_state.pop(cle, None)
    st.session_state["cookie_action"] = ""


def menu_profil(profil: pd.Series) -> None:
    """Popover : visibilité, limites, PIN, déconnexion."""
    with st.popover(profil["prenom"][:1].upper() or "?", help="Mon espace"):
        st.html(f"<div class='question'>{escape(profil['prenom'])}</div><div class='precision'>Mon espace</div>")
        with st.form("preferences", border=False):
            visibilite = st.radio("Visibilité de mon budget", list(VISIBILITES), format_func=VISIBILITES.get,
                                  index=list(VISIBILITES).index(profil["visibilite"])
                                  if profil["visibilite"] in VISIBILITES else 0)
            budget = st.number_input("Budget dépenses mensuel (€) — 0 = aucun", min_value=0.0, step=50.0,
                                     value=float(profil["budget_mensuel_max"]), format="%.2f")
            objectif = st.number_input("Objectif d'épargne mensuel (€) — 0 = aucun", min_value=0.0, step=50.0,
                                       value=float(profil["objectif_epargne"]), format="%.2f")
            if st.form_submit_button("Enregistrer", type="primary", width="stretch"):
                if executer(modifier_profil, profil["id"], visibilite=visibilite,
                            budget_mensuel_max=round(budget, 2), objectif_epargne=round(objectif, 2),
                            succes="Profil mis à jour"):
                    st.rerun()

        st.divider()
        with st.form("changer_pin", border=False, clear_on_submit=True):
            st.caption("Changer mon code PIN")
            ancien = st.text_input("Code actuel", type="password", max_chars=6, key="pin_ancien")
            nouveau = st.text_input("Nouveau code (4 à 6 chiffres)", type="password", max_chars=6,
                                    key="pin_nouveau")
            if st.form_submit_button("Changer le code", width="stretch"):
                try:
                    stocke = lire_pin_hash(profil["id"])
                except Exception as exc:  # noqa: BLE001
                    stocke = None
                    st.error(message_erreur_db(exc))
                if stocke is None:
                    pass
                elif not pin_correct(ancien, stocke):
                    st.error("Code actuel incorrect.")
                elif not pin_valide(nouveau):
                    st.error("Le nouveau code doit contenir 4 à 6 chiffres.")
                else:
                    # Le nouveau PIN invalide les sessions des autres appareils ; celui-ci reste connecté
                    nouveau_hash = hacher_pin(nouveau)
                    if executer(modifier_profil, profil["id"], pin_hash=nouveau_hash, succes="Code PIN modifié"):
                        memoriser_appareil(profil["id"], nouveau_hash)
                        st.rerun()

        st.divider()
        st.button("Se déconnecter", icon=":material/logout:", on_click=deconnecter, width="stretch")
        st.caption(f"Version {VERSION_APP}")


# --- Prévision de fin de mois -------------------------------------------------------------

def prevision_fin_mois(df_comp: pd.DataFrame, budget_mensuel: float) -> dict:
    """Projette la fin du mois en cours au rythme actuel des dépenses courantes (hors charges fixes)."""
    jour, mois = aujourdhui(), mois_courant()
    debut, fin = mois.start_time.date(), mois.end_time.date()
    passes, restants = (jour - debut).days + 1, (fin - jour).days
    du_mois = df_comp[df_comp["date_operation"].between(pd.Timestamp(debut), pd.Timestamp(jour))]
    depenses = du_mois[du_mois["categorie"].isin(CATEGORIES_DEPENSES)]
    deja = float(depenses["montant"].sum())
    courantes = float(depenses.loc[~depenses["sous_categorie"].isin(CHARGES_FIXES), "montant"].sum())
    rythme = max(courantes, 0.0) / passes
    return {
        "fin": fin, "mois": mois, "jours_restants": restants, "rythme": rythme, "deja": deja,
        "depenses_fin": deja + rythme * restants,
        "solde_fin": solde_jusqua(df_comp, jour) - rythme * restants,
        "budget": budget_mensuel,
    }


def html_prevision(p: dict) -> str:
    """La prévision en mots simples, avec un conseil concret si le budget risque d'être dépassé."""
    nom_mois = MOIS_FR[p["mois"].month - 1]
    html = html_tuiles([
        (f"Solde estimé au {p['fin']:%d/%m}", f"≈ {montant_html(p['solde_fin'])}", "si tu continues au même rythme",
         "pos" if p["solde_fin"] >= 0 else "neg", True),
        ("Rythme quotidien", montant_html(p["rythme"]), "dépenses courantes par jour", "", False),
        (f"Dépenses de {nom_mois}", f"≈ {montant_html(p['depenses_fin'])}", "projection fin de mois", "", False),
    ])
    html += (f"<div class='phrase'>Tes dépenses courantes (hors loyer, factures, assurances, abonnements) sont de "
             f"<b>{fmt_eur(p['rythme'])}</b> par jour en moyenne. À ce rythme, tes dépenses de {nom_mois} atteindront "
             f"environ <b>{fmt_eur(p['depenses_fin'])}</b>.</div>")
    budget = p["budget"]
    if budget > 0:
        if p["depenses_fin"] > budget:
            par_jour = max(budget - p["deja"], 0.0) / max(p["jours_restants"], 1)
            html += (f"<div class='phrase neg'>▲ Soit <b>{fmt_eur(p['depenses_fin'] - budget)}</b> au-dessus de ton "
                     f"budget de {fmt_eur(budget)}. Pour rester dans ton budget : pas plus de "
                     f"<b>{fmt_eur(par_jour)}</b> par jour d'ici la fin du mois.</div>")
        else:
            html += (f"<div class='phrase pos'>✓ Tu resterais dans ton budget de {fmt_eur(budget)}, avec environ "
                     f"<b>{fmt_eur(budget - p['depenses_fin'])}</b> de marge.</div>")
    return html + ("<div class='note'>Estimation simple : elle suppose que tes charges fixes du mois "
                   "sont déjà payées.</div>")


# --- Comparaison de deux périodes choisies ---------------------------------------------------

def choisir_intervalle(libelle: str, defaut: tuple[date, date], cle: str) -> Periode | None:
    """Sélecteur « du … au … » ; None tant que la date de fin n'est pas choisie."""
    choix = st.date_input(libelle, value=defaut, format="DD/MM/YYYY", key=cle)
    if isinstance(choix, (tuple, list)) and len(choix) == 2:
        debut, fin = choix
        return Periode(debut, fin, f"du {debut:%d/%m/%Y} au {fin:%d/%m/%Y}")
    return None


def html_ecarts_themes(c1: pd.DataFrame, c2: pd.DataFrame, limite: int = 8) -> str:
    """Les thèmes qui ont le plus changé entre les deux périodes, avec une flèche et l'écart en euros."""
    def par_theme(d: pd.DataFrame) -> pd.Series:
        d = d[d["categorie"].isin(CATEGORIES_SORTIES)]
        return d.groupby("sous_categorie")["montant"].sum()

    t1, t2 = par_theme(c1), par_theme(c2)
    themes = t1.index.union(t2.index)
    ecarts = pd.DataFrame({"p1": t1.reindex(themes, fill_value=0.0), "p2": t2.reindex(themes, fill_value=0.0)})
    ecarts["ecart"] = ecarts["p1"] - ecarts["p2"]
    ecarts = ecarts[ecarts["ecart"].abs() >= 0.01]
    ecarts = ecarts.reindex(ecarts["ecart"].abs().sort_values(ascending=False).index).head(limite)
    lignes = []
    for theme, ligne in ecarts.iterrows():
        est_epargne = SOUS_CATEGORIES.get(theme, ("", ""))[0] == CAT_EPARGNE
        hausse = ligne["ecart"] > 0
        bon = hausse if est_epargne else not hausse   # plus d'épargne = bien ; plus de dépense = moins bien
        lignes.append(f"""
        <div class="ligne">
          <span class="ms {'pos' if bon else 'neg'}">{'arrow_upward' if hausse else 'arrow_downward'}</span>
          <div class="corps"><div class="t">{escape(theme)}</div>
            <div class="s">{fmt_eur(ligne['p1'])} contre {fmt_eur(ligne['p2'])}</div></div>
          <div class="m {'pos' if bon else 'neg'}">{fmt_eur(ligne['ecart'], signe=True)}</div>
        </div>""")
    return "".join(lignes) or "<div class='note'>Aucune différence notable entre les deux périodes.</div>"


def carte_comparaison(df_comp: pd.DataFrame, periode: Periode, prenom: str | None, avec_detail: bool,
                      prefixe: str) -> None:
    """Compare deux intervalles choisis librement (par défaut : la période affichée et le mois précédent)."""
    je = prenom is None
    precedent = pd.Period(periode.debut, freq="M") - 1
    with carte(f"{prefixe}_comparaison"):
        titre_carte("Qu'est-ce qui a changé ?" if je else f"Ce qui a changé pour {prenom}",
                    "Choisis les deux périodes à comparer", "Comparaison")
        gauche, droite = st.columns(2)
        # Les clés dépendent de la période du haut : changer celle-ci remet les choix par défaut
        suffixe = f"{periode.debut:%Y%m%d}_{periode.fin:%Y%m%d}"
        with gauche:
            p1 = choisir_intervalle("Comparer", (periode.debut, periode.fin), f"{prefixe}_cmp1_{suffixe}")
        with droite:
            p2 = choisir_intervalle("avec", (precedent.start_time.date(), precedent.end_time.date()),
                                    f"{prefixe}_cmp2_{suffixe}")
        if p1 is None or p2 is None:
            st.caption("Choisis la date de fin de chaque période.")
            return
        c1, c2 = p1.filtrer(df_comp), p2.filtrer(df_comp)
        b1, b2 = bilan(c1), bilan(c2)
        nom1, nom2 = f"{p1.debut:%d/%m} → {p1.fin:%d/%m}", f"{p2.debut:%d/%m} → {p2.fin:%d/%m}"

        ecart = b1["depenses"] - b2["depenses"]
        sujet = "tu as dépensé" if je else f"{escape(prenom)} a dépensé"
        phrase = (f"Du {p1.debut:%d/%m} au {p1.fin:%d/%m}, {sujet} <b>{fmt_eur(b1['depenses'])}</b>, contre "
                  f"<b>{fmt_eur(b2['depenses'])}</b> du {p2.debut:%d/%m} au {p2.fin:%d/%m} : ")
        phrase += (f"<b class='neg'>{fmt_eur(ecart)} de plus</b>." if ecart > 0.005
                   else f"<b class='pos'>{fmt_eur(-ecart)} de moins</b>." if ecart < -0.005 else "autant.")
        # Jours réellement écoulés (une période qui finit dans le futur n'est pas encore terminée)
        j1, j2 = (max((min(p.fin, aujourdhui()) - p.debut).days + 1, 1) for p in (p1, p2))
        if j1 != j2:  # durées différentes : la moyenne par jour est plus parlante
            phrase += (f" Par jour : <b>{fmt_eur(b1['depenses'] / j1)}</b> contre "
                       f"<b>{fmt_eur(b2['depenses'] / j2)}</b> "
                       f"({j1} jour{'s' if j1 > 1 else ''} écoulé{'s' if j1 > 1 else ''} contre {j2}).")
        st.html(f"<div class='phrase'>{phrase}</div>")
        tracer(graphique_comparaison(b1, b2, nom1, nom2), f"{prefixe}_comparaison")
        if avec_detail:
            st.html("<div class='sous-titre'>Les plus gros changements</div>" + html_ecarts_themes(c1, c2))


# --- Objectifs d'épargne par catégorie --------------------------------------------------------

def carte_objectifs_epargne(df_comp: pd.DataFrame, profil: pd.Series) -> None:
    """Total mis de côté depuis le début dans chaque catégorie d'épargne, comparé à son objectif."""
    noms = [nom for nom, (cat, _) in SOUS_CATEGORIES.items() if cat == CAT_EPARGNE]
    try:
        objectifs, colonne_ok = charger_objectifs_epargne(profil["id"]), True
    except Exception:  # noqa: BLE001 — colonne pas encore créée dans Supabase
        objectifs, colonne_ok = {}, False
    epargne = df_comp[df_comp["categorie"] == CAT_EPARGNE]
    totaux = epargne.groupby("sous_categorie")["montant"].sum()
    trois_mois = pd.Timestamp(aujourdhui() - timedelta(days=90))
    rythme_mensuel = epargne[epargne["date_operation"] >= trois_mois].groupby("sous_categorie")["montant"].sum() / 3

    with carte("moi_objectifs"):
        titre_carte("Où en sont mes objectifs d'épargne ?",
                    "Épargne nette (versements − retraits) depuis le début, par support", "Objectifs")
        morceaux = []
        for nom in noms:
            total, objectif = float(totaux.get(nom, 0.0)), objectifs.get(nom, 0.0)
            rythme = float(rythme_mensuel.get(nom, 0.0))
            if objectif > 0:
                morceaux.append(html_barre(nom, total, objectif, SERIE["Épargne"],
                                           f"{fmt_eur(total)} / {fmt_eur(objectif)}"))
                if total >= objectif:
                    morceaux.append("<div class='note pos' style='margin-top:4px'>✓ Objectif atteint, bravo !</div>")
                else:
                    reste = objectif - total
                    delai = (f" · à ton rythme (≈ {fmt_eur(rythme)} par mois), atteint dans environ "
                             f"<b>{math.ceil(reste / rythme)} mois</b>") if rythme > 0 else ""
                    morceaux.append(f"<div class='note' style='margin-top:4px'>Encore <b>{fmt_eur(reste)}</b> "
                                    f"à mettre de côté{delai}</div>")
            elif abs(total) > 0.005:
                morceaux.append(f"<div class='ligne'><div class='corps'><div class='t'>{nom}</div>"
                                f"<div class='s'>pas encore d'objectif</div></div>"
                                f"<div class='m {'neg' if total < 0 else ''}'>{fmt_eur(total)}</div></div>")
        st.html("".join(morceaux) or "<div class='note'>Fixe un objectif ci-dessous pour suivre ta "
                                     "progression (ex. Livret : 3 000 €).</div>")
        if not colonne_ok:
            st.info("Pour enregistrer des objectifs, exécute d'abord la mise à jour de `schema.sql` dans Supabase.")
            return
        with st.expander("Modifier mes objectifs d'épargne"):
            with st.form("objectifs_epargne", border=False):
                valeurs = {nom: st.number_input(f"{nom} (€) — 0 = aucun objectif", min_value=0.0, step=50.0,
                                                value=float(objectifs.get(nom, 0.0)), format="%.0f")
                           for nom in noms}
                if st.form_submit_button("Enregistrer", type="primary", width="stretch"):
                    nouveaux = {nom: round(v, 2) for nom, v in valeurs.items() if v > 0}
                    if executer(modifier_profil, profil["id"], objectifs_epargne=nouveaux,
                                succes="Objectifs d'épargne enregistrés"):
                        st.rerun()


VUES_RESUME = {"Dépenses": "donut_large", "Comptes": "account_balance_wallet", "Budget": "track_changes",
               "Tendances": "bar_chart", "Comparer": "compare_arrows"}


@dataclass
class Tableau:
    """Ce que montre le Résumé d'un profil sur une période (le sien, ou celui d'un ami)."""
    df: pd.DataFrame           # tout l'historique, tel que saisi
    df_comp: pd.DataFrame      # idem, entrées compensées (remboursement de loyer, retrait de livret…)
    brut: pd.DataFrame         # opérations de la période, telles que saisies
    comp: pd.DataFrame         # opérations de la période, compensées
    b: dict[str, float]
    b_prec: dict[str, float]
    libelle_prec: str
    periode: Periode
    profil: pd.Series
    prenom: str | None         # None pour soi-même (« je »)
    avec_detail: bool          # False : ami en mode « résumé » (ni thèmes ni opérations)
    prefixe: str

    @property
    def je(self) -> bool:
        return self.prenom is None


def preparer_tableau(df: pd.DataFrame, periode: Periode, profil: pd.Series, prenom: str | None,
                     avec_detail: bool, prefixe: str) -> Tableau:
    brut = periode.filtrer(df)
    comp = compenser(brut)
    precedente = periode.precedente()
    libelle_prec = ("vs paie précédente" if periode.cycle and periode.cycle_precedent is not None
                    else "vs " + MOIS_COURTS[precedente.debut.month - 1].lower() if periode.est_mois_complet
                    else "vs période précédente")
    return Tableau(df, compenser(df), brut, comp, bilan(comp), bilan(compenser(precedente.filtrer(df))),
                   libelle_prec, periode, profil, prenom, avec_detail, prefixe)


def couleurs_sous_categories(df_comp: pd.DataFrame) -> dict[str, str]:
    """Une teinte fixe par thème de dépense (les 8 plus lourds de tout l'historique, dans l'ordre de la palette) :
    un thème garde sa couleur d'un mois à l'autre ; les autres sont regroupés en gris."""
    return {sc: PALETTE[i] for i, sc in enumerate(rang_sous_categories(df_comp, 8))}


def html_delta_court(actuel: float, precedent: float, hausse_bonne: bool, libelle: str) -> str:
    """« ▲ 12 % vs sept. » en petit, coloré selon que la hausse est une bonne nouvelle."""
    if abs(precedent) < 0.5:
        return ""
    variation = (actuel - precedent) / abs(precedent) * 100
    if abs(variation) < 0.5:
        return f"<div class='delta' style='color:var(--muet)'>= stable {escape(libelle)}</div>"
    hausse = variation > 0
    classe = "pos" if hausse == hausse_bonne else "neg"
    return (f"<div class='delta {classe}'><span class='ms'>{'trending_up' if hausse else 'trending_down'}</span>"
            f"{fmt_pct(abs(variation))} <span style='color:var(--muet)'>{escape(libelle)}</span></div>")


def graphique_anneau_depenses(t: Tableau, couleurs: dict[str, str]):
    """Anneau des dépenses de la période par thème, le total au centre (comme une appli de banque)."""
    d = depenses_de(t.comp).groupby("sous_categorie")["montant"].sum()
    d = d[d > 0].sort_values(ascending=False)
    connus = [s for s in d.index if s in couleurs]
    autres = float(d[[s for s in d.index if s not in couleurs]].sum())
    noms = connus + (["Autres"] if autres > 0 else [])
    valeurs = [float(d[s]) for s in connus] + ([autres] if autres > 0 else [])
    teintes = [couleurs[s] for s in connus] + ([SERIE["Autres"]] if autres > 0 else [])
    fig = go.Figure(go.Pie(labels=noms, values=valeurs, hole=0.82, sort=False, direction="clockwise",
                           marker=dict(colors=teintes, line=dict(color=FOND, width=4)), textinfo="none",
                           hovertemplate="<b>%{label}</b><br>%{value:,.2f} € · %{percent}<extra></extra>"))
    variation = ""
    if abs(t.b_prec["depenses"]) >= 0.5:
        ecart = (t.b["depenses"] - t.b_prec["depenses"]) / abs(t.b_prec["depenses"]) * 100
        teinte = C_NEG if ecart > 0.5 else C_POS if ecart < -0.5 else ENCRE_2
        variation = (f"<span style='color:{teinte}'>{'▲' if ecart > 0 else '▼'} {fmt_pct(abs(ecart))}</span> "
                     f"{t.libelle_prec}")
    en_cours = t.periode.debut <= aujourdhui() <= t.periode.fin
    titre = ("Depuis la paie" if t.periode.cycle and en_cours
             else "Ce mois-ci" if t.periode.est_mois_complet and en_cours else "Dépensé")
    fig.add_annotation(x=0.5, y=0.64, xref="paper", yref="paper", showarrow=False, text=titre,
                       font=dict(family="Manrope, sans-serif", size=13, color=ENCRE_2))
    fig.add_annotation(x=0.5, y=0.5, xref="paper", yref="paper", showarrow=False,
                       text=f"<b>{fmt_eur0(t.b['depenses'])}</b>",
                       font=dict(family="Manrope, sans-serif", size=31, color=ENCRE))
    if variation:
        fig.add_annotation(x=0.5, y=0.35, xref="paper", yref="paper", showarrow=False, text=variation,
                           font=dict(family="Manrope, sans-serif", size=12, color=MUET))
    fig.update_layout(height=236, margin=dict(t=0, b=0, l=0, r=0), showlegend=False, dragmode=False,
                      paper_bgcolor="rgba(0,0,0,0)", plot_bgcolor="rgba(0,0,0,0)", separators=", ",
                      hoverlabel=dict(bgcolor=SURFACE_2, bordercolor="rgba(243,245,247,0.14)",
                                      font=dict(family="Manrope, sans-serif", size=13, color=ENCRE)))
    return fig


def html_kpis(t: Tableau, solde: float | None) -> str:
    """Les chiffres de la période en pastilles : revenus, épargne, reste, solde du compte."""
    b, bp = t.b, t.b_prec
    taux = b[CAT_EPARGNE] / b["reference"] * 100 if b["reference"] else 0.0
    kpis = [
        ("Revenus", montant_html(b[CAT_REVENU]), "", html_delta_court(b[CAT_REVENU], bp[CAT_REVENU], True, "")),
        ("Mis de côté", montant_html(b[CAT_EPARGNE]), f"{fmt_pct(taux)} du salaire" if b["reference"] else "", ""),
        ("Reste", montant_html(b["reste"]), "revenus − sorties", "", "pos" if b["reste"] >= 0 else "neg"),
    ]
    if solde is not None:
        kpis.append(("Solde du compte", montant_html(solde), f"au {aujourdhui():%d/%m}", "", "neg" if solde < 0 else ""))
    else:
        kpis.append(("Dépensé", montant_html(b["depenses"]), "besoins + envies", ""))
    morceaux = []
    for k in kpis:
        lbl, val, sub, delta = k[:4]
        classe = k[4] if len(k) > 4 else ""
        morceaux.append(f"<div class='kpi'><div class='lbl'>{lbl}</div><div class='val {classe}'>{val}</div>"
                        + (f"<div class='sub'>{sub}</div>" if sub else "") + delta + "</div>")
    return f"<div class='kpis'>{''.join(morceaux)}</div>"


def html_liste_categories(comp: pd.DataFrame, couleurs: dict[str, str]) -> str:
    """Les thèmes de dépense de la période, du plus lourd au plus léger : icône, nombre d'achats, montant, part."""
    d = depenses_de(comp)
    g = (d.groupby(["sous_categorie", "categorie"])["montant"]
         .agg(montant="sum", nb=lambda s: int((s > 0).sum())).reset_index()
         .query("montant > 0").sort_values("montant", ascending=False))
    total = float(g["montant"].sum())
    if total <= 0:
        return "<div class='note'>Aucune dépense sur cette période.</div>"
    lignes = []
    for sc, cat, montant, nb in g.itertuples(index=False):
        teinte = couleurs.get(sc, SERIE["Autres"])
        lignes.append(
            f"<div class='ligne'><div class='pastille' style='background:{lavis(teinte, 0.24)}'>{EMOJIS.get(sc, '•')}</div>"
            f"<div class='corps'><div class='t'>{escape(sc)}<span class='nb'>{nb}</span></div>"
            f"<div class='s'>{NOMS_COURTS[cat]}</div></div>"
            f"<div class='m'>{fmt_eur(montant)}<small>{fmt_pct(montant / total * 100)}</small></div></div>")
    return "".join(lignes)


def html_solde(solde: float, depuis: date, nb_operations: int, je: bool) -> str:
    nb = f"{nb_operations:,}".replace(",", " ")
    return (f"<div class='hero'><div class='hero-lbl'>{'Mon solde' if je else 'Son solde'} au {aujourdhui():%d/%m/%Y}</div>"
            f"<div class='hero-montant {'neg' if solde < 0 else ''}'>{montant_html(solde)}</div>"
            f"<div class='hero-sous'>Compte courant · calculé à partir de {nb} opérations depuis le {depuis:%d/%m/%Y}</div></div>")


def choisir_vue_resume(cle: str, je: bool) -> str:
    vues = [v for v in VUES_RESUME if je or v != "Comptes"]
    st.session_state.setdefault(cle, vues[0])
    if st.session_state[cle] not in vues:
        st.session_state[cle] = vues[0]
    return st.segmented_control("Vue", vues, key=cle, required=True, label_visibility="collapsed", width="stretch",
                                format_func=lambda v: f":material/{VUES_RESUME[v]}: {v}")


def resume_depenses(t: Tableau) -> None:
    """Vue « Dépenses » : l'anneau des thèmes, les chiffres clés, la liste des thèmes, les dernières opérations."""
    couleurs = couleurs_sous_categories(t.df_comp)
    gauche, droite = st.columns([5, 6], gap="medium")
    with gauche:
        if t.avec_detail and t.b["depenses"] > 0:
            tracer(graphique_anneau_depenses(t, couleurs), f"{t.prefixe}_anneau")
        else:
            st.html(f"<div class='hero'><div class='hero-lbl'>Dépensé · {escape(t.periode.libelle)}</div>"
                    f"<div class='hero-montant'>{montant_html(t.b['depenses'])}</div>"
                    + html_delta_court(t.b["depenses"], t.b_prec["depenses"], False, t.libelle_prec) + "</div>")
        solde = solde_jusqua(t.df_comp, aujourdhui()) if t.je else None
        budget, objectif = limites_periode(t.profil, t.periode)
        st.html(html_kpis(t, solde) + phrase_resume(t.b, t.prenom)
                + html_limites(t.b, budget, objectif, prorata=not t.periode.est_mois_complet))
    if not t.avec_detail:
        with droite:
            st.caption(f"{escape(t.prenom or '')} partage uniquement son résumé : le détail n'est pas visible.")
        return
    with droite, carte(f"{t.prefixe}_categories"):
        nb = int((depenses_de(t.comp).groupby("sous_categorie")["montant"].sum() > 0).sum())
        titre_carte("Par catégorie", f"{nb} catégorie{'s' if nb > 1 else ''} · {t.periode.libelle}")
        st.html(html_liste_categories(t.comp, couleurs))
    with droite, carte(f"{t.prefixe}_mouvements"):
        titre_carte("Dernières opérations" if t.je else f"Les dernières opérations de {t.prenom}", t.periode.libelle)
        st.html(html_mouvements(t.brut, limite=8))


def resume_comptes(t: Tableau) -> None:
    """Vue « Comptes » (pour soi) : le solde, chaque compte et livret, la prévision et la courbe du solde."""
    depuis = t.df["date_operation"].min().date()
    gauche, droite = st.columns([1, 1], gap="medium")
    with gauche:
        st.html(html_solde(solde_jusqua(t.df_comp, aujourdhui()), depuis, len(t.df), True))
        carte_avoirs(t.df, t.profil)
    prevision = None
    if t.periode.debut <= aujourdhui() <= t.periode.fin:
        prevision = prevision_fin_mois(t.df_comp, float(t.profil["budget_mensuel_max"]))
        with droite, carte(f"{t.prefixe}_prevision"):
            titre_carte("Combien me restera-t-il à la fin du mois ?",
                        f"Estimation au rythme actuel · il reste {prevision['jours_restants']} jour(s)", "Prévision")
            st.html(html_prevision(prevision))
    with droite, carte(f"{t.prefixe}_solde"):
        titre_carte("Mon argent jour après jour", "Le solde du compte courant à la fin de chaque journée"
                    + (" · en pointillés : la prévision" if prevision else ""), "Trésorerie")
        fig, serie = graphique_solde(t.df_comp, t.periode, prevision)
        tracer(fig, f"{t.prefixe}_solde")
        bas, haut = serie.loc[serie["solde"].idxmin()], serie.loc[serie["solde"].idxmax()]
        st.html(f"<div class='note'>Au plus bas : <b>{fmt_eur(bas['solde'])}</b> le {bas['libelle']} · "
                f"au plus haut : <b>{fmt_eur(haut['solde'])}</b> le {haut['libelle']}</div>")


def html_base_reference(comp: pd.DataFrame) -> str:
    """« Entreprise 1 305,36 € · Bourse & aides 394,03 € · Boulangerie 572,30 € » : la base de la règle 50-30-20."""
    ref = comp[(comp["categorie"] == CAT_REVENU) & comp["sous_categorie"].isin(REVENUS_REFERENCE)]
    if ref.empty:
        return ""
    par = ref.groupby(sources_de(ref))["montant"].sum().sort_values(ascending=False)
    return ("<div class='note'>Revenus réguliers de la période : "
            + " · ".join(f"{escape(str(nom))} <b>{fmt_eur(m)}</b>" for nom, m in par.items() if m > 0.005) + ".</div>")


def resume_budget(t: Tableau) -> None:
    """Vue « Budget » : la règle 50-30-20, les objectifs d'épargne, le détail par groupe."""
    with carte(f"{t.prefixe}_regle"):
        titre_carte("Est-ce que je respecte la règle 50-30-20 ?" if t.je else f"La règle 50-30-20 pour {t.prenom}",
                    "Sur le salaire, les aides et l'aide familiale : 50 % pour les besoins, 30 % pour les envies, "
                    "20 % pour l'épargne", "Équilibre")
        if not (t.b[CAT_REVENU] or t.b["depenses"] or t.b[CAT_EPARGNE]):
            st.html("<div class='note'>Rien à afficher sur cette période.</div>")
        else:
            if t.b["reference"]:
                st.html(phrase_regle(t.b, t.je) + html_base_reference(t.comp))
            gauche, droite = st.columns([1, 1], gap="large", vertical_alignment="center")
            with gauche:
                tracer(graphique_camembert(t.b), f"{t.prefixe}_camembert")
            with droite:
                st.html(html_objectifs(t.b))
    gauche, droite = st.columns([1, 1], gap="medium")
    if t.je:
        with gauche:
            carte_objectifs_epargne(t.df_comp, t.profil)
    if t.avec_detail:
        with droite if t.je else gauche, carte(f"{t.prefixe}_detail"):
            titre_carte("Où part mon argent, en détail ?" if t.je else f"Où part l'argent de {t.prenom} ?",
                        "Les thèmes regroupés en besoins, envies et épargne", "Répartition")
            st.html(html_detail_groupes(t.comp))


def resume_tendances(t: Tableau) -> None:
    """Vue « Tendances » : chaque jour de la période, puis les 6 derniers mois."""
    gauche, droite = st.columns([1, 1], gap="medium")
    with gauche, carte(f"{t.prefixe}_jours"):
        titre_carte("Combien j'ai dépensé chaque jour ?" if t.je else f"Combien {t.prenom} a dépensé chaque jour ?",
                    "Besoins et envies empilés · trait pointillé : la moyenne", "Dépenses")
        if t.brut[t.brut["categorie"].isin(CATEGORIES_DEPENSES)].empty:
            st.html("<div class='note'>Aucune dépense sur cette période.</div>")
        else:
            fig, moyenne, par_jour = graphique_depenses_jour(t.brut, t.periode, t.avec_detail)
            tracer(fig, f"{t.prefixe}_jours")
            jour_max = par_jour.idxmax()
            sans = int((par_jour == 0).sum())
            st.html(f"<div class='note'>En moyenne <b>{fmt_eur(moyenne)}</b> par jour · jour le plus dépensier : "
                    f"<b>{libelle_jour(jour_max)}</b> ({fmt_eur(par_jour.max())})"
                    + (f" · {sans} jour{'s' if sans > 1 else ''} sans dépense" if sans else "") + "</div>")
    if t.df["mois"].nunique() > 1:
        with droite, carte(f"{t.prefixe}_tendance"):
            titre_carte("Comment j'évolue mois après mois ?" if t.je else f"L'évolution de {t.prenom} mois après mois",
                        "Dépenses et épargne nette en barres, revenus en ligne · 6 derniers mois", "Tendance")
            tracer(graphique_mensuel(t.df_comp), f"{t.prefixe}_tendance")


def afficher_tableau_de_bord(df: pd.DataFrame, periode: Periode, profil: pd.Series, prenom: str | None = None,
                             avec_detail: bool = True, prefixe: str = "moi", vue: str = "Dépenses") -> None:
    """Le Résumé d'un profil sur une période, vue par vue (une vue tient dans l'écran du téléphone)."""
    t = preparer_tableau(df, periode, profil, prenom, avec_detail, prefixe)
    if vue == "Comptes" and t.je:
        resume_comptes(t)
    elif vue == "Budget":
        resume_budget(t)
    elif vue == "Tendances":
        resume_tendances(t)
    elif vue == "Comparer":
        carte_comparaison(t.df_comp, periode, prenom, avec_detail, prefixe)
    else:
        resume_depenses(t)


def carte_avoirs(df: pd.DataFrame, profil: pd.Series) -> None:
    """Patrimoine du jour : chaque compte, chaque livret, placements (montant net versé), total."""
    avoirs = avoirs_ou_rien(profil["id"])
    jour = aujourdhui()
    livrets = calculer_livrets(avoirs, df, jour) if avoirs else None
    with carte("moi_avoirs"):
        comp = compenser(df)
        comptes = comptes_de(comp)
        titre_carte("Où est mon argent ?", ("Mes comptes" if len(comptes) > 1 else "Compte courant")
                    + ", livrets et placements à ce jour", "Mes avoirs")
        tuiles, epargne, compte = [], [], 0.0
        for c in comptes:
            solde = solde_jusqua(comp, jour, c)
            compte += solde
            if c == COMPTE_COURANT:
                sous = "solde calculé"
            else:
                derniere = df.loc[touche_compte(df, c) & (df["date_operation"] <= pd.Timestamp(jour)), "date_operation"]
                sous = f"dernier mouvement le {derniere.max():%d/%m/%Y}" if len(derniere) else "aucun mouvement"
            tuiles.append((nom_compte(c), montant_html(solde), sous, "neg" if solde < -0.005 else "", False))
        place = comp[(comp["categorie"] == CAT_EPARGNE) & (comp["sous_categorie"] == "Investissement")]
        placements = float(place["montant"].sum())
        if livrets:
            for nom in livrets.soldes.columns:
                taux = livrets.taux.get(nom)
                epargne.append((nom, montant_html(float(livrets.soldes[nom].iloc[-1])),
                                f"taux {str(taux).replace('.', ',')} % net" if taux else "livret", "", False))
        epargne.append(("Placements", montant_html(placements), "montant net versé", "", False))
        mis_de_cote = placements + (float(livrets.total.iloc[-1]) if livrets else 0.0)
        total = compte + mis_de_cote
        if len(comptes) > 1:  # deux blocs : l'argent disponible sur les comptes, puis l'épargne
            st.html(f"<div class='bloc-avoirs'>Comptes<span>{fmt_eur(compte)}</span></div>" + html_tuiles(tuiles)
                    + f"<div class='bloc-avoirs'>Épargne et placements<span>{fmt_eur(mis_de_cote)}</span></div>"
                    + html_tuiles([*epargne, ("Patrimoine", montant_html(total), "comptes + épargne", "", True)]))
        else:
            st.html(html_tuiles([*tuiles, *epargne, ("Patrimoine", montant_html(total), "au total", "", True)]))
        if len(comptes) > 1:
            st.html("<div class='note'>Soldes des comptes calculés à partir de leurs opérations. Les virements entre "
                    "tes comptes ne comptent ni comme revenus ni comme dépenses ; ce que tu paies depuis n'importe quel "
                    "compte compte bien dans tes dépenses.</div>")
        if livrets:
            derniers = livrets.interets.iloc[-1] if not livrets.interets.empty else None
            st.html(f"<div class='note'>Livrets d'après tes relevés jusqu'au {livrets.fin_releves:%d/%m/%Y}, complétés "
                    "par tes virements depuis"
                    + (f" · intérêts {livrets.interets.index[-1]} : <b>{fmt_eur(derniers.sum())}</b>"
                       if derniers is not None else "") + ".</div>")
        elif avoirs is None:
            st.html("<div class='note'>Pour voir tes livrets ici, exécute la dernière version de <code>schema.sql</code> "
                    "dans Supabase, puis importe leurs relevés CSV depuis l'onglet Opérations.</div>")
        else:
            st.html("<div class='note'>Importe les relevés CSV de tes livrets depuis l'onglet Opérations pour voir "
                    "leurs soldes ici.</div>")


def onglet_resume(df: pd.DataFrame, profil: pd.Series) -> None:
    if df.empty:
        with carte("vide"):
            titre_carte("Bienvenue au Cercle", surtitre="Premiers pas")
            st.write("Ton tableau de bord est vide. Commence par ajouter tes revenus et tes dépenses "
                     "avec le bouton **+** en bas de l'écran.")
        return
    with st.container(key="tete_resume"):
        vue = choisir_vue_resume("resume_vue", je=True)
        periode = choisir_periode(df, "budget", mode_defaut="Depuis la paie")
    afficher_tableau_de_bord(df, periode, profil, vue=vue)


# --- Analyses de tout l'historique ----------------------------------------------------------

@dataclass
class Contexte:
    """Données d'une analyse : la période choisie et tout l'historique (pour les repères)."""
    brut: pd.DataFrame        # opérations de la période, telles que saisies
    comp: pd.DataFrame        # idem, entrées compensées (remboursement de loyer, retrait de livret…)
    brut_tout: pd.DataFrame
    comp_tout: pd.DataFrame
    debut: date
    fin: date
    libelle: str
    tm: pd.DataFrame          # table mensuelle de la période
    prenom: str
    livrets: Livrets | None = None

    @property
    def mois(self) -> float:
        return nb_mois_ecoules(self.debut, self.fin)


SECTIONS_ANALYSE = {
    "Vue d'ensemble": "📊", "Dépenses": "🍩", "Marchands & lieux": "🏪", "Habitudes": "🗓️", "Revenus": "💶",
    "Épargne": "🐷", "Charges fixes": "🔁", "Jeux d'argent": "🎲", "Saisons": "☀️",
}


def choisir_bornes_analyse(brut_tout: pd.DataFrame) -> tuple[date, date, str]:
    jour = aujourdhui()
    premier = brut_tout["date_operation"].min().date()
    annees = sorted({d.year for d in brut_tout["date_operation"]}, reverse=True)
    options = ["Tout l'historique", "12 derniers mois", *[str(a) for a in annees]]
    st.session_state.setdefault("ana_periode", "Tout l'historique")
    if st.session_state["ana_periode"] not in options:
        st.session_state["ana_periode"] = "Tout l'historique"
    choix = st.selectbox("Période", options, key="ana_periode", label_visibility="collapsed",
                         format_func=lambda o: f"📅 {o}", filter_mode=None)
    if choix == "12 derniers mois":
        debut, fin = (pd.Period(jour, freq="M") - 11).start_time.date(), jour
    elif choix.isdigit():
        debut, fin = date(int(choix), 1, 1), min(date(int(choix), 12, 31), jour)
    else:
        debut, fin = premier, jour
    debut = max(debut, premier)
    return debut, fin, f"du {debut:%d/%m/%Y} au {fin:%d/%m/%Y}"


def notes_conseiller(ctx: Contexte) -> list[tuple[str, str]]:
    """Les enseignements chiffrés de la période, formulés comme un conseiller le ferait."""
    notes: list[tuple[str, str]] = []
    comp, brut, tm = ctx.comp, ctx.brut, ctx.tm
    dep = depenses_de(comp)
    if dep.empty:
        return [("info", "Pas encore assez d'opérations sur cette période pour en tirer des enseignements.")]

    courantes = depenses_courantes(comp)
    par_mois = courantes.groupby("mois")["montant"].sum().reindex(tm.index, fill_value=0.0)
    complets = par_mois[par_mois.index < mois_courant()]
    evo = evolution(complets)
    texte = (f"Ton train de vie courant (hors loyer, factures, abonnements et achats exceptionnels) est de "
             f"<b>{fmt_eur0(courantes['montant'].sum() / ctx.mois)}</b> par mois")
    if evo is not None:
        texte += (f" ; sur les 3 derniers mois il est en <b class='{'neg' if evo > 0 else 'pos'}'>"
                  f"{'hausse' if evo > 0 else 'baisse'} de {fmt_pct(abs(evo))}</b> par rapport aux 3 précédents")
    notes.append(("speed", texte + "."))

    envies = dep[dep["categorie"] == CAT_ENVIES].groupby("sous_categorie")["montant"].sum().sort_values(ascending=False)
    if not envies.empty and envies.iloc[0] > 0:
        part = envies.iloc[0] / max(envies[envies > 0].sum(), 1) * 100
        notes.append(("restaurant", f"Tes envies vont d'abord aux <b>{escape(envies.index[0])}</b> : "
                                    f"<b>{fmt_eur0(envies.iloc[0])}</b>, soit {fmt_pct(part)} des envies "
                                    f"({fmt_eur0(envies.iloc[0] / ctx.mois)} par mois)."))

    if len(tm) > 1 and tm["depenses"].max() > 0:
        mois_max = tm["depenses"].idxmax()
        grosses = depenses_de(brut[brut["mois"] == mois_max]).sort_values("montant", ascending=False)
        detail = ""
        if not grosses.empty:
            g = grosses.iloc[0]
            detail = f", porté par « {escape(g['description'] or g['sous_categorie'])} » ({fmt_eur0(g['montant'])})"
        notes.append(("event", f"Ton mois le plus dépensier : <b>{libelle_mois(mois_max)}</b> avec "
                               f"<b>{fmt_eur0(tm.loc[mois_max, 'depenses'])}</b>{detail}."))

    petits = depenses_de(brut)
    petits = petits[(petits["montant"] < 10) & ~petits["sous_categorie"].isin(COMPENSATIONS)]
    if len(petits) >= 10:
        notes.append(("local_cafe", f"<b>{len(petits)}</b> petits achats de moins de 10 € pèsent "
                                    f"<b>{fmt_eur0(petits['montant'].sum())}</b> au total, soit "
                                    f"{fmt_eur0(petits['montant'].sum() / ctx.mois)} par mois : l'effet « café »."))

    epargne = float(comp[comp["categorie"] == CAT_EPARGNE]["montant"].sum())
    revenus = float(comp[comp["categorie"] == CAT_REVENU]["montant"].sum())
    if epargne >= 0:
        notes.append(("savings", f"Épargne nette de la période : <b class='pos'>{fmt_eur0(epargne)}</b>"
                                 + (f", soit {fmt_pct(epargne / revenus * 100)} de tes revenus." if revenus > 0 else ".")))
    else:
        notes.append(("savings", f"Sur la période, tu as retiré de ton épargne <b class='neg'>{fmt_eur0(-epargne)}</b> "
                                 "de plus que tu n'y as versé : les livrets servent surtout de réserve de trésorerie."))

    abos = abonnements(ctx.brut_tout, ctx.fin)
    if not abos.empty:
        actifs = abos[(abos["Statut"] == "Actif") & (abos["Catégorie"] == "Abonnements")]
        if not actifs.empty:
            mensuel = float(actifs["Coût mensuel actuel (€)"].sum())
            notes.append(("subscriptions", f"Tes <b>{len(actifs)}</b> abonnements actifs coûtent "
                                           f"<b>{fmt_eur0(mensuel)}</b> par mois, soit <b>{fmt_eur0(mensuel * 12)}</b> par an."))

    jeux = operations_jeux(brut)
    if not jeux.empty:
        net = float(jeux.loc[jeux["sens"] == "Gains", "montant"].sum() - jeux.loc[jeux["sens"] == "Mises", "montant"].sum())
        notes.append(("casino", f"Jeux d'argent : résultat net de <b class='{'pos' if net >= 0 else 'neg'}'>"
                                f"{fmt_eur0(net, signe=True)}</b> sur la période "
                                f"({fmt_eur0(jeux.loc[jeux['sens'] == 'Mises', 'montant'].sum())} misés)."))

    env = depenses_courantes(comp)
    env = env[env["categorie"] == CAT_ENVIES]
    if env["montant"].sum() > 0:
        weekend = env[env["date_operation"].dt.weekday >= 5]["montant"].sum() / env["montant"].sum() * 100
        notes.append(("weekend", f"<b>{fmt_pct(weekend)}</b> de tes envies sont dépensées le week-end "
                                 f"(qui ne représente que 29 % des jours)."))

    if ctx.livrets and ctx.fin >= ctx.livrets.debut_releves:
        lv = ctx.livrets
        detail = ", ".join(f"{n} {fmt_eur0(lv.soldes[n].reindex([pd.Timestamp(ctx.fin)]).ffill().iloc[-1])}"
                           for n in lv.soldes.columns)
        texte = f"Tes livrets totalisent <b>{fmt_eur0(lv.total.reindex([pd.Timestamp(ctx.fin)]).iloc[-1])}</b> ({detail})"
        if not lv.interets.empty:
            texte += (f" et t'ont rapporté <b>{fmt_eur0(lv.interets.iloc[-1].sum())}</b> d'intérêts en "
                      f"{lv.interets.index[-1]}")
        notes.append(("account_balance", texte + "."))
        periode_tot = lv.total[(lv.total.index >= pd.Timestamp(ctx.debut)) & (lv.total.index <= pd.Timestamp(ctx.fin))]
        if len(periode_tot) > 30:
            haut = periode_tot.idxmax()
            notes.append(("trending_down" if periode_tot.iloc[-1] < periode_tot.max() else "trending_up",
                          f"Au plus haut, tes livrets ont atteint <b>{fmt_eur0(periode_tot.max())}</b> "
                          f"(le {haut:%d/%m/%Y}) ; ils sont aujourd'hui à <b>{fmt_eur0(periode_tot.iloc[-1])}</b>."))

    ref = comp[comp["categorie"] == CAT_REVENU]
    if revenus > 0:
        salaire = ref[ref["sous_categorie"] == "Salaire"]["montant"].sum() / revenus * 100
        famille = ref[ref["sous_categorie"] == "Aide familiale"]["montant"].sum() / revenus * 100
        notes.append(("work", f"Tes revenus viennent à <b>{fmt_pct(salaire)}</b> de ton salaire"
                              + (f" et à <b>{fmt_pct(famille)}</b> de l'aide familiale" if famille >= 1 else "")
                              + "."))
    return notes


def section_vue_ensemble(ctx: Contexte) -> None:
    b = bilan(ctx.brut)
    tm = ctx.tm
    taux = b[CAT_EPARGNE] / b[CAT_REVENU] * 100 if b[CAT_REVENU] > 0 else 0.0
    st.html(html_tuiles([
        ("Revenus", montant_html(b[CAT_REVENU]), f"{fmt_eur0(b[CAT_REVENU] / ctx.mois)} par mois"),
        ("Dépenses", montant_html(b["depenses"]), f"{fmt_eur0(b['depenses'] / ctx.mois)} par mois", "", False),
        ("Épargne nette", montant_html(b[CAT_EPARGNE]), f"{fmt_pct(taux)} des revenus",
         "pos" if b[CAT_EPARGNE] >= 0 else "neg", False),
        ("Flux net", montant_html(b["reste"]), "revenus − dépenses − épargne", "pos" if b["reste"] >= 0 else "neg", False),
        ("Opérations", f"{len(ctx.brut):,}".replace(",", " "), f"sur {ctx.mois:.0f} mois", "", False),
    ]))
    st.html(html_lettre(ctx.prenom, notes_conseiller(ctx)))

    with carte("ana_flux"):
        titre_carte("Comment respire mon compte ?", "Revenus au-dessus de l'axe, dépenses en dessous, mois par mois",
                    "Flux mensuels")
        tracer(fig_flux_mensuels(tm), "ana_flux")
        voir_donnees(tm.assign(Mois=tm["libelle"])[["Mois", "revenus", "depenses", "epargne", "reste", "solde_fin"]]
                     .rename(columns={"revenus": "Revenus (€)", "depenses": "Dépenses (€)", "epargne": "Épargne nette (€)",
                                      "reste": "Reste (€)", "solde_fin": "Solde fin de mois (€)"}).round(2), "flux")

    with carte("ana_solde"):
        titre_carte("L'évolution de mon solde", "Le compte courant à la fin de chaque journée · " + ctx.libelle,
                    "Trésorerie")
        fig, solde = fig_solde_historique(ctx.comp_tout, ctx.debut, ctx.fin)
        tracer(fig, "ana_solde")
        st.html(f"<div class='note'>Solde moyen : <b>{fmt_eur(solde.mean())}</b> · "
                f"{int((solde < 50).sum())} jour(s) sous 50 € sur {len(solde)}.</div>")
    with carte("ana_regle"):
        titre_carte("La règle 50-30-20 dans le temps", "Part du salaire, des aides et de l'aide familiale, "
                    "en moyenne glissante sur 3 mois", "Équilibre")
        tracer(fig_regle_historique(tm), "ana_regle")
        st.html("<div class='note'>Pointillés : les cibles (50 % besoins, 30 % envies, 20 % épargne). "
                "L'échelle est limitée à 170 % : passe sur un point pour la valeur exacte.</div>")

    with carte("ana_annees"):
        titre_carte("Le bilan année par année", "Revenus, dépenses et épargne nette de chaque année civile", "Bilan")
        annees = []
        for annee, g in ctx.comp.groupby(ctx.comp["date_operation"].dt.year):
            bb = bilan(g)
            d1 = max(date(int(annee), 1, 1), ctx.debut)
            d2 = min(date(int(annee), 12, 31), ctx.fin)
            annees.append({"Année": str(annee), "Revenus (€)": round(bb[CAT_REVENU]),
                           "Dépenses (€)": round(bb["depenses"]), "dont besoins (€)": round(bb[CAT_BESOINS]),
                           "dont envies (€)": round(bb[CAT_ENVIES]), "Épargne nette (€)": round(bb[CAT_EPARGNE]),
                           "Taux d'épargne": round(bb[CAT_EPARGNE] / bb[CAT_REVENU] * 100, 1) if bb[CAT_REVENU] else 0.0,
                           "Dépense / mois (€)": round(bb["depenses"] / nb_mois_ecoules(d1, d2))})
        st.dataframe(pd.DataFrame(annees), hide_index=True, key="ana_table_annees", column_config={
            "Taux d'épargne": st.column_config.NumberColumn(format="%.1f %%"),
            **{c: st.column_config.NumberColumn(format="localized") for c in
               ("Revenus (€)", "Dépenses (€)", "dont besoins (€)", "dont envies (€)", "Épargne nette (€)",
                "Dépense / mois (€)")},
        })


def section_depenses(ctx: Contexte) -> None:
    dep = depenses_de(ctx.comp)
    brut_dep = depenses_de(ctx.brut)
    brut_dep = brut_dep[~brut_dep["sous_categorie"].isin(COMPENSATIONS)]
    remb = float(ctx.comp[ctx.comp["sous_categorie"] == "Remboursement"]["montant"].sum())
    total = float(dep["montant"].sum())
    st.html(html_tuiles([
        ("Dépenses nettes", montant_html(total), f"{fmt_eur0(total / ctx.mois)} par mois"),
        ("Besoins", montant_html(dep[dep["categorie"] == CAT_BESOINS]["montant"].sum()),
         f"{fmt_pct(dep[dep['categorie'] == CAT_BESOINS]['montant'].sum() / total * 100 if total else 0)} des dépenses", "", False),
        ("Envies", montant_html(dep[dep["categorie"] == CAT_ENVIES]["montant"].sum()),
         f"{fmt_pct(dep[dep['categorie'] == CAT_ENVIES]['montant'].sum() / total * 100 if total else 0)} des dépenses", "", False),
        ("Remboursé par tes proches", montant_html(remb), f"dépenses après remboursements : {fmt_eur0(total - remb)}", "", False),
        ("Panier moyen", montant_html(brut_dep["montant"].median() if not brut_dep.empty else 0),
         f"médiane de {len(brut_dep):,} achats".replace(",", " "), "", False),
    ]))
    with carte("ana_treemap"):
        titre_carte("Où part mon argent ?", "Chaque rectangle est proportionnel au montant dépensé · " + ctx.libelle,
                    "Cartographie")
        tracer(fig_treemap(ctx.comp), "ana_treemap")
        st.html("<div class='note'>Montants nets : le loyer est diminué de la part du colocataire, les jeux de "
                "leurs gains, les retraits d'espèces des espèces redéposées.</div>")

    with carte("ana_themes"):
        titre_carte("Mes thèmes de dépense, mois par mois", "Les 7 thèmes les plus lourds de l'historique, le reste "
                    "dans « Autres »", "Évolution")
        fig, table = fig_themes_mensuels(ctx.comp, ctx.comp_tout, ctx.debut, ctx.fin)
        tracer(fig, "ana_themes")

    with carte("ana_classement"):
        titre_carte("Le classement de mes postes", "Total, part, moyenne mensuelle et tendance sur 12 mois",
                    "Classement")
        mois = mois_entre(ctx.debut, ctx.fin)
        lignes = []
        par_theme = dep.groupby("sous_categorie")
        for theme, g in par_theme:
            t = float(g["montant"].sum())
            if t <= 0:
                continue
            serie = g.groupby("mois")["montant"].sum().reindex(mois, fill_value=0.0)
            evo = evolution(serie[serie.index < mois_courant()])
            lignes.append({"Poste": theme, "Catégorie": NOMS_COURTS[SOUS_CATEGORIES.get(theme, (CAT_ENVIES,))[0]],
                           "Total (€)": round(t, 2), "Part": round(t / total * 100, 1) if total else 0,
                           "Par mois (€)": round(t / ctx.mois, 2),
                           "12 derniers mois": [round(float(v), 2) for v in serie.iloc[-12:]],
                           "3 mois vs 3 précédents": round(evo, 0) if evo is not None else float("nan"),
                           "Opérations": int(len(g))})
        classement = pd.DataFrame(lignes).sort_values("Total (€)", ascending=False)
        st.dataframe(classement, hide_index=True, key="ana_classement_table", column_config={
            "Total (€)": st.column_config.NumberColumn(format="localized"),
            "Par mois (€)": st.column_config.NumberColumn(format="localized"),
            "Part": st.column_config.ProgressColumn(format="%.0f %%", min_value=0, max_value=100, color="#3987E5"),
            "12 derniers mois": st.column_config.AreaChartColumn(y_min=0, color="#3987E5"),
            "3 mois vs 3 précédents": st.column_config.NumberColumn(format="%+.0f %%"),
        })

    gauche, droite = st.columns(2, gap="medium")
    with gauche, carte("ana_top"):
        titre_carte("Mes plus grosses dépenses", ctx.libelle, "Exceptionnel")
        st.html(html_mouvements(brut_dep.sort_values("montant", ascending=False), limite=10, avec_annee=True))
    with droite, carte("ana_tickets"):
        titre_carte("Petits et gros achats", "Nombre d'achats par tranche de prix", "Tickets")
        fig, t = fig_tickets(ctx.brut)
        tracer(fig, "ana_tickets")
        petits = t.loc[["< 5 €", "5–10 €"], ["nb", "total"]].sum()
        st.html(f"<div class='note'>Les achats de moins de 10 € représentent <b>{int(petits['nb'])}</b> opérations "
                f"et <b>{fmt_eur0(petits['total'])}</b> ; ceux de plus de 100 € pèsent "
                f"<b>{fmt_eur0(t.loc[['100–500 €', '> 500 €'], 'total'].sum())}</b>.</div>")
        voir_donnees(t.reset_index().rename(columns={"montant": "Tranche", "index": "Tranche", "nb": "Achats",
                                                     "total": "Total (€)"}).round(2), "tickets")


HORS_MARCHANDS = {"Loyer", "Factures", "Assurances", "Frais bancaires", "Espèces"}


def section_marchands(ctx: Contexte) -> None:
    # Les enseignes du quotidien : sans loyer, factures, retraits d'espèces, virements ni achats exceptionnels
    d = depenses_de(ctx.brut)
    d = d[~d["sous_categorie"].isin(set(COMPENSATIONS) | HORS_MARCHANDS) & (d["montant"] <= SEUIL_EXCEPTIONNEL)
          & ~d["description"].str.startswith("Virement")]
    if d.empty:
        st.info("Aucune dépense sur cette période.")
        return
    mois = mois_entre(ctx.debut, ctx.fin)
    stats = d.groupby("marchand").agg(total=("montant", "sum"), visites=("montant", "size"),
                                      premier=("date_operation", "min"), dernier=("date_operation", "max"),
                                      theme=("sous_categorie", lambda s: s.mode().iat[0]))
    stats = stats.sort_values("total", ascending=False)
    fidele = stats.sort_values("visites", ascending=False).iloc[0]
    st.html(html_tuiles([
        ("Marchands différents", f"{len(stats)}", f"sur {len(d):,} achats".replace(",", " ")),
        ("Marchand n° 1", escape(stats.index[0]), f"{fmt_eur0(stats.iloc[0]['total'])} dépensés", "texte", False),
        ("Le plus fréquenté", escape(stats.sort_values('visites', ascending=False).index[0]),
         f"{int(fidele['visites'])} passages", "texte", False),
        ("Dépense par passage", montant_html(d["montant"].mean()), "en moyenne", "", False),
        ("Top 10", fmt_pct(stats["total"].head(10).sum() / stats["total"].sum() * 100), "des dépenses chez 10 marchands",
         "", False),
    ]))
    gauche, droite = st.columns([3, 2], gap="medium")
    with gauche, carte("ana_marchands"):
        titre_carte("Chez qui je dépense le plus", "Les 15 premiers marchands, hors loyer, factures, espèces et "
                    "achats exceptionnels", "Marchands")
        top = stats.head(15)
        tracer(fig_barres_horizontales(list(top.index), list(top["total"]), ACCENT,
                                       survol="<b>%{y}</b> : %{x:,.2f} €"), "ana_marchands")
    with droite, carte("ana_villes"):
        titre_carte("Où je dépense", "Les villes des paiements par carte", "Lieux")
        villes = d[d["ville"] != ""].groupby("ville")["montant"].agg(["sum", "size"]).sort_values("sum", ascending=False)
        if villes.empty:
            st.html("<div class='note'>Aucune ville reconnue dans les notes de cette période.</div>")
        else:
            top_v = villes.head(12)
            tracer(fig_barres_horizontales(list(top_v.index), list(top_v["sum"]), SERIE["Besoins"],
                                           survol="<b>%{y}</b> : %{x:,.2f} €"), "ana_villes")
            st.html(f"<div class='note'>{len(villes)} villes · la première, <b>{escape(villes.index[0])}</b>, "
                    f"concentre {fmt_pct(villes.iloc[0]['sum'] / villes['sum'].sum() * 100)} des achats localisés.</div>")

    with carte("ana_fidelite"):
        titre_carte("Mes marchands à la loupe", "Fréquence, panier moyen et évolution sur 12 mois", "Fidélité")
        lignes = []
        for marchand, s in stats.head(60).iterrows():
            serie = d[d["marchand"] == marchand].groupby("mois")["montant"].sum().reindex(mois, fill_value=0.0)
            lignes.append({"Marchand": marchand, "Thème": s["theme"], "Total (€)": round(s["total"], 2),
                           "Passages": int(s["visites"]), "Panier moyen (€)": round(s["total"] / s["visites"], 2),
                           "12 derniers mois": [round(float(v), 2) for v in serie.iloc[-12:]],
                           "Premier achat": s["premier"].date(), "Dernier achat": s["dernier"].date()})
        st.dataframe(pd.DataFrame(lignes), hide_index=True, key="ana_marchands_table", column_config={
            "Total (€)": st.column_config.NumberColumn(format="localized"),
            "Panier moyen (€)": st.column_config.NumberColumn(format="localized"),
            "12 derniers mois": st.column_config.BarChartColumn(y_min=0, color="#3987E5"),
            "Premier achat": st.column_config.DateColumn(format="DD/MM/YYYY"),
            "Dernier achat": st.column_config.DateColumn(format="DD/MM/YYYY"),
        })

    with carte("ana_loupe"):
        titre_carte("Zoom sur un marchand", "Choisis un marchand pour voir toutes ses opérations", "Explorer")
        choix = st.selectbox("Marchand", list(stats.index), key="ana_marchand_choix", label_visibility="collapsed",
                             format_func=lambda m: f"{m} · {fmt_eur0(stats.loc[m, 'total'])}")
        ops = d[d["marchand"] == choix].sort_values("date_operation", ascending=False)
        s = stats.loc[choix]
        st.html(html_tuiles([
            ("Total", montant_html(s["total"]), f"{int(s['visites'])} passages"),
            ("Panier moyen", montant_html(s["total"] / s["visites"]), f"thème : {escape(s['theme'])}", "", False),
            ("Premier achat", f"{s['premier']:%d/%m/%Y}", "", "", False),
            ("Dernier achat", f"{s['dernier']:%d/%m/%Y}", "", "", False),
        ]))
        serie = ops.groupby("mois")["montant"].sum().reindex(mois, fill_value=0.0)
        fig = go.Figure(go.Bar(x=[libelle_mois_court(p) for p in mois], y=serie, marker_color=ACCENT,
                               hovertemplate="<b>%{x}</b> : %{y:,.2f} €<extra></extra>"))
        fig.update_layout(bargap=0.4)
        tracer(styliser(fig, 220, legende=False), "ana_loupe")
        st.html(html_mouvements(ops, limite=12, avec_annee=True))


def section_habitudes(ctx: Contexte) -> None:
    courantes = depenses_courantes(ctx.comp)
    jours = pd.date_range(ctx.debut, ctx.fin, freq="D")
    par_jour = courantes.groupby(courantes["date_operation"].dt.normalize())["montant"].sum().reindex(jours, fill_value=0.0)
    sans = par_jour <= 0
    serie_max, serie = 0, 0
    for v in sans:
        serie = serie + 1 if v else 0
        serie_max = max(serie_max, serie)
    fig_sem, moyenne_sem = fig_jours_semaine(ctx.brut, ctx.debut, ctx.fin)
    jour_top = int(moyenne_sem.idxmax())
    st.html(html_tuiles([
        ("Par jour", montant_html(par_jour.mean()), "dépenses courantes en moyenne"),
        ("Jour le plus cher", JOURS_LONGS[jour_top].capitalize(), f"{fmt_eur0(moyenne_sem.iloc[jour_top])} en moyenne", "", False),
        ("Jours sans dépense", fmt_pct(sans.mean() * 100), f"{int(sans.sum())} jours sur {len(jours)}", "", False),
        ("Record sans dépenser", f"{serie_max} jours", "d'affilée", "", False),
        ("Le plus gros jour", montant_html(par_jour.max()), f"le {par_jour.idxmax():%d/%m/%Y}", "", False),
    ]))
    with carte("ana_calendrier"):
        titre_carte("Le calendrier de mes dépenses", "Une case par jour sur 12 mois · plus la case est dorée, plus "
                    "la journée a coûté", "Calendrier")
        fig, _ = fig_calendrier(ctx.brut_tout, ctx.fin)
        tracer(fig, "ana_calendrier")

    gauche, droite = st.columns(2, gap="medium")
    with gauche, carte("ana_semaine"):
        titre_carte("Mes jours de dépense", "Dépenses courantes moyennes selon le jour de la semaine", "Semaine")
        tracer(fig_sem, "ana_semaine")
    with droite, carte("ana_cycle"):
        titre_carte("Le rythme après la paie", "Dépenses courantes cumulées depuis le jour de paie", "Cycle de paie")
        fig, info = fig_cycle_paie(ctx.brut_tout, cycles_paie(ctx.brut_tout))
        if fig is None:
            st.html("<div class='note'>Pas assez de cycles de paie pour dessiner un rythme habituel.</div>")
        else:
            tracer(fig, "ana_cycle")
            jour = len(info["en_cours"]) - 1
            habituel = info["moyenne"][min(jour, len(info["moyenne"]) - 1)]
            ecart = float(info["en_cours"].iloc[-1]) - habituel
            st.html(f"<div class='note'>Au jour {jour} du cycle, tu as dépensé <b>{fmt_eur0(info['en_cours'].iloc[-1])}</b>, "
                    f"soit <b class='{'neg' if ecart > 0 else 'pos'}'>{fmt_eur0(abs(ecart))} "
                    f"{'de plus' if ecart > 0 else 'de moins'}</b> que d'habitude à ce stade.</div>")

    with carte("ana_moments"):
        titre_carte("Début ou fin de mois ?", "Dépenses courantes moyennes selon le jour du mois", "Calendrier du mois")
        d = courantes.assign(jour=courantes["date_operation"].dt.day)
        nb_mois = max(len(mois_entre(ctx.debut, ctx.fin)), 1)
        par_jour_mois = d.groupby("jour")["montant"].sum().reindex(range(1, 32), fill_value=0.0) / nb_mois
        fig = go.Figure(go.Bar(x=list(range(1, 32)), y=par_jour_mois, marker_color=SERIE["Besoins"],
                               hovertemplate="Le %{x} du mois : %{y:,.2f} € en moyenne<extra></extra>"))
        fig.update_layout(bargap=0.35)
        tracer(styliser(fig, 240, legende=False), "ana_moments")
        premiere, seconde = par_jour_mois.loc[1:15].sum(), par_jour_mois.loc[16:31].sum()
        st.html(f"<div class='note'>Première quinzaine : <b>{fmt_eur0(premiere)}</b> par mois · seconde quinzaine : "
                f"<b>{fmt_eur0(seconde)}</b>.</div>")


def section_revenus(ctx: Contexte) -> None:
    rev = ctx.comp[ctx.comp["categorie"] == CAT_REVENU]
    if rev.empty:
        st.info("Aucun revenu sur cette période.")
        return
    total = float(rev["montant"].sum())
    ref = float(rev[rev["sous_categorie"].isin(REVENUS_REFERENCE)]["montant"].sum())
    par_sc = rev.groupby("sous_categorie")["montant"].sum().sort_values(ascending=False)
    principal = employeur_principal(ctx.brut_tout)
    debut_principal = jours_de_paie(ctx.brut_tout)[0] if principal else None
    salaires = rev[rev["sous_categorie"] == "Salaire"]
    par_employeur = salaires.groupby(sources_de(salaires))["montant"].sum().sort_values(ascending=False)
    detail_salaire = " · ".join(f"{escape(str(n))} {fmt_pct(m / max(par_employeur.sum(), 0.01) * 100)}"
                                for n, m in par_employeur.head(3).items())
    st.html(html_tuiles([
        ("Revenus", montant_html(total), f"{fmt_eur0(total / ctx.mois)} par mois"),
        ("Revenus réguliers", montant_html(ref), "salaires, aides, aide familiale", "", False),
        ("Salaires", montant_html(par_sc.get("Salaire", 0.0)), detail_salaire or "aucun salaire", "", False),
        *([(f"Salaire principal · {principal}", montant_html(float(par_employeur.get(principal, 0.0))),
            f"ouvre le mois budgétaire · depuis le {debut_principal:%d/%m/%Y}", "", False)] if principal else []),
        ("Cadeaux reçus", montant_html(par_sc.get("Cadeau reçu", 0.0)), "anniversaires, fêtes, coups de pouce", "", False),
        ("Remboursements", montant_html(par_sc.get("Remboursement", 0.0)), "parts payées par tes proches", "", False),
    ]))
    mois = mois_entre(ctx.debut, ctx.fin)
    # Une série par employeur (salaire principal, job d'été…) et par type d'aide ; couleurs fixes d'une
    # période à l'autre (rang sur tout l'historique)
    rev_tout = ctx.comp_tout[ctx.comp_tout["categorie"] == CAT_REVENU]
    ordre = list(rev_tout.groupby(sources_de(rev_tout))["montant"].sum().sort_values(ascending=False).index[:6])
    serie = sources_de(rev).where(sources_de(rev).isin(ordre), "Autres")
    table = (rev.assign(serie=serie).groupby(["mois", "serie"])["montant"].sum().unstack(fill_value=0.0)
             .reindex(index=mois, columns=[*ordre, "Autres"], fill_value=0.0))
    table = table.loc[:, table.abs().sum() > 0.005]
    couleurs = {s: PALETTE[i] for i, s in enumerate(ordre)} | {"Autres": SERIE["Autres"]}
    with carte("ana_revenus"):
        titre_carte("D'où vient mon argent ?", "Revenus empilés par source (chaque employeur à part), mois par mois",
                    "Sources")
        fig = fig_empile(mois, table, couleurs)
        if debut_principal and mois[0] <= pd.Period(debut_principal, freq="M") <= mois[-1]:
            repere = libelle_mois_court(pd.Period(debut_principal, freq="M"))
            fig.add_vline(x=repere, line=dict(color=ENCRE_2, width=1, dash="dot"))
            fig.add_annotation(x=repere, y=1, yref="paper", showarrow=False, xanchor="left", yanchor="top",
                               text=f"  1er salaire {escape(principal)}", font=dict(color=ENCRE_2, size=11))
        tracer(fig, "ana_revenus")
        if debut_principal:
            avant = rev_tout[rev_tout["date_operation"] < pd.Timestamp(debut_principal)]
            apres = rev_tout[rev_tout["date_operation"] >= pd.Timestamp(debut_principal)]
            if not avant.empty and not apres.empty:
                part = float(apres[sources_de(apres) == principal]["montant"].sum()) / max(float(apres["montant"].sum()), 0.01)
                avant_src = avant.groupby(sources_de(avant))["montant"].sum().sort_values(ascending=False).head(3)
                st.html(f"<div class='note'>Depuis ton 1er salaire {escape(principal)} ({debut_principal:%d/%m/%Y}), "
                        f"il représente <b>{fmt_pct(part * 100)}</b> de tes revenus. Avant, tes principales sources étaient : "
                        + ", ".join(f"{escape(str(n))} ({fmt_eur0(m)})" for n, m in avant_src.items()) + ".</div>")

    gauche, droite = st.columns(2, gap="medium")
    with gauche, carte("ana_payeurs"):
        titre_carte("Mes principales sources", "Classées par montant reçu", "Classement")
        sources = (rev.assign(source=rev["sous_categorie"] + " · " + rev["marchand"])
                   .groupby("source")["montant"].sum().sort_values(ascending=False).head(10))
        tracer(fig_barres_horizontales(list(sources.index), list(sources.values), SERIE["Revenus"]), "ana_payeurs")
    with droite, carte("ana_autonomie"):
        titre_carte("Mon autonomie financière", "Part du salaire et de l'aide familiale dans les revenus "
                    "(moyenne glissante sur 3 mois)", "Autonomie")
        tot = rev.groupby("mois")["montant"].sum().reindex(mois, fill_value=0.0).rolling(3, min_periods=1).sum()
        fig = go.Figure()
        for sc, couleur in (("Salaire", PALETTE[0]), ("Aide familiale", PALETTE[1])):
            part = (rev[rev["sous_categorie"] == sc].groupby("mois")["montant"].sum().reindex(mois, fill_value=0.0)
                    .rolling(3, min_periods=1).sum() / tot.where(tot > 0) * 100)
            fig.add_scatter(x=[libelle_mois_court(p) for p in mois], y=part.round(0), mode="lines", name=sc,
                            line=dict(color=couleur, width=2), hovertemplate=f"{sc} : %{{y:.0f}} %<extra></extra>")
        fig.update_layout(hovermode="x unified")
        styliser(fig, 300, suffixe=" %")
        fig.update_yaxes(range=[0, 105])
        tracer(fig, "ana_autonomie")


def section_epargne(ctx: Contexte) -> None:
    brut_ep = ctx.brut[(ctx.brut["categorie"] == CAT_EPARGNE)
                       | ctx.brut["sous_categorie"].isin(["Retrait d'épargne", "Vente placement"])].copy()
    if brut_ep.empty:
        st.info("Aucun mouvement d'épargne sur cette période.")
        return
    brut_ep["sens"] = brut_ep["categorie"].map(lambda c: "Retiré" if c == CAT_REVENU else "Versé")

    def support(ligne) -> str:
        texte = f"{ligne['description']} {ligne['marchand']}".lower()
        if "boursobank" in texte:
            return "Boursobank"
        if "livret bleu" in texte:
            return "Livret Bleu"
        if "livret jeune" in texte:
            return "Livret Jeune"
        if "livret" in texte or ligne["sous_categorie"] in ("Livret", "Retrait d'épargne"):
            return "Livrets (non précisé)"
        if "trade republic" in texte:
            return "Trade Republic"
        if "bitstack" in texte:
            return "Bitstack"
        return ligne["marchand"]

    brut_ep["support"] = brut_ep.apply(support, axis=1)
    verse = float(brut_ep[brut_ep["sens"] == "Versé"]["montant"].sum())
    retire = float(brut_ep[brut_ep["sens"] == "Retiré"]["montant"].sum())
    comp_ep = ctx.comp[ctx.comp["categorie"] == CAT_EPARGNE]
    placements = float(comp_ep[comp_ep["sous_categorie"] == "Investissement"]["montant"].sum())
    revenus = float(ctx.comp[ctx.comp["categorie"] == CAT_REVENU]["montant"].sum())
    tm = ctx.tm
    st.html(html_tuiles([
        ("Épargne nette", montant_html(verse - retire), f"{fmt_pct((verse - retire) / revenus * 100) if revenus else '—'} "
         "des revenus", "pos" if verse >= retire else "neg"),
        ("Versé", montant_html(verse), f"{int((brut_ep['sens'] == 'Versé').sum())} versements", "", False),
        ("Retiré", montant_html(retire), f"{int((brut_ep['sens'] == 'Retiré').sum())} retraits", "", False),
        ("Placements nets", montant_html(placements), "Trade Republic, Bitstack…", "", False),
        ("Meilleur mois", libelle_mois(tm["epargne"].idxmax()) if len(tm) else "—",
         fmt_eur0(tm["epargne"].max()) if len(tm) else "", "texte", False),
    ]))
    with carte("ana_epargne"):
        titre_carte("Est-ce que je mets vraiment de côté ?", "Épargne nette de chaque mois : versements − retraits",
                    "Épargne nette")
        tracer(fig_polarite(list(tm["libelle"]), tm["epargne"], "Mis de côté", "Puisé dans l'épargne"), "ana_epargne")
        mois_negatifs = int((tm["epargne"] < 0).sum())
        st.html(f"<div class='note'>{mois_negatifs} mois sur {len(tm)} où tu as plus retiré que versé. "
                "Les livrets jouent le rôle de compte tampon : l'argent y entre et en ressort vite.</div>")

    gauche, droite = st.columns(2, gap="medium")
    with gauche, carte("ana_cumul"):
        titre_carte("Le cumul par support", "Épargne nette accumulée depuis le début de la période", "Cumul")
        mois = mois_entre(ctx.debut, ctx.fin)
        fig = go.Figure()
        for sc, nom, couleur in (("Livret", "Livrets", SERIE["Épargne"]), ("Investissement", "Placements", PALETTE[6])):
            cumul = (comp_ep[comp_ep["sous_categorie"] == sc].groupby("mois")["montant"].sum()
                     .reindex(mois, fill_value=0.0).cumsum())
            fig.add_scatter(x=[libelle_mois_court(p) for p in mois], y=cumul, mode="lines", name=nom,
                            line=dict(color=couleur, width=2), hovertemplate=f"{nom} : %{{y:,.0f}} €<extra></extra>")
        fig.update_layout(hovermode="x unified")
        tracer(styliser(fig, 300, zero=True), "ana_cumul")
    with droite, carte("ana_supports"):
        titre_carte("Mes supports d'épargne", "Ce qui a été versé et retiré sur chaque support", "Supports")
        t = brut_ep.pivot_table(index="support", columns="sens", values="montant", aggfunc="sum", fill_value=0.0)
        t = t.reindex(columns=["Versé", "Retiré"], fill_value=0.0)
        t["Net (€)"] = t["Versé"] - t["Retiré"]
        t = t.sort_values("Versé", ascending=False).reset_index().rename(
            columns={"support": "Support", "Versé": "Versé (€)", "Retiré": "Retiré (€)"}).round(2)
        st.dataframe(t, hide_index=True, key="ana_supports_table", column_config={
            c: st.column_config.NumberColumn(format="localized") for c in ("Versé (€)", "Retiré (€)", "Net (€)")})
        if (t["Support"] == "Livrets (non précisé)").any():
            st.html("<div class='note'>« Non précisé » : retraits antérieurs aux relevés de tes livrets, dont on ne sait "
                    "pas de quel livret ils viennent.</div>")

    lv = ctx.livrets
    if lv is None:
        st.html("<div class='note'>Importe les relevés CSV de tes livrets (onglet Opérations) pour voir ici leurs "
                "soldes réels, tes intérêts et ton patrimoine.</div>")
        return
    with carte("ana_patrimoine"):
        pat = serie_patrimoine(ctx.comp_tout, lv, ctx.debut, ctx.fin)
        titre_carte("Mon patrimoine", ("Comptes" if "Autres comptes" in pat else "Compte courant")
                    + ", livrets et placements (montant net versé), jour après jour", "Patrimoine")
        fig = go.Figure()
        for nom, couleur in (("Livrets", SERIE["Épargne"]), ("Placements", PALETTE[6]), ("Autres comptes", PALETTE[3]),
                             ("Compte courant", SERIE["Besoins"])):
            if nom not in pat:
                continue
            fig.add_scatter(x=pat.index, y=pat[nom], name=nom, mode="lines", stackgroup="patrimoine",
                            line=dict(color=couleur, width=1.5), fillcolor=lavis(couleur, 0.42),
                            hovertemplate=f"{nom} : %{{y:,.0f}} €<extra></extra>")
        if ctx.debut < lv.debut_releves <= ctx.fin:
            fig.add_vline(x=pd.Timestamp(lv.debut_releves), line=dict(color=ENCRE_2, width=1, dash="dot"))
            fig.add_annotation(x=pd.Timestamp(lv.debut_releves), y=1, yref="paper", showarrow=False, xanchor="left",
                               text="  relevés des livrets", font=dict(color=ENCRE_2, size=11))
        fig.update_layout(hovermode="x unified")
        fig.update_xaxes(tickformat="%b %y")
        tracer(styliser(fig, 340, zero=True), "ana_patrimoine")
        total = pat.sum(axis=1)
        st.html(f"<div class='note'>Patrimoine au {ctx.fin:%d/%m/%Y} : <b>{fmt_eur(total.iloc[-1])}</b> · au plus haut "
                f"<b>{fmt_eur(total.max())}</b> le {total.idxmax():%d/%m/%Y}. Avant le {lv.debut_releves:%d/%m/%Y}, les "
                "livrets sont reconstitués à partir de tes virements (intérêts de ces années-là non comptés).</div>")
    gauche, droite = st.columns([3, 2], gap="medium")
    with gauche, carte("ana_livrets"):
        titre_carte("Mes livrets", "Solde de chaque livret depuis le début des relevés", "Livrets")
        sl = lv.soldes[(lv.soldes.index >= pd.Timestamp(ctx.debut)) & (lv.soldes.index <= pd.Timestamp(ctx.fin))]
        if sl.empty:
            st.html("<div class='note'>Pas de relevé de livret sur cette période.</div>")
        else:
            fig = go.Figure()
            for i, nom in enumerate(sl.columns):
                fig.add_scatter(x=sl.index, y=sl[nom], name=nom, mode="lines", line=dict(color=PALETTE[[3, 0, 1, 4][i % 4]],
                                width=2, shape="hv"), hovertemplate=f"{nom} : %{{y:,.2f}} €<extra></extra>")
            fig.update_layout(hovermode="x unified")
            fig.update_xaxes(tickformat="%b %y")
            tracer(styliser(fig, 300), "ana_livrets")
    with droite, carte("ana_interets"):
        titre_carte("Mes intérêts", "Ce que tes livrets t'ont rapporté chaque année", "Intérêts")
        if lv.interets.empty:
            st.html("<div class='note'>Aucun versement d'intérêts dans les relevés.</div>")
        else:
            t = lv.interets.copy()
            t["Total"] = t.sum(axis=1)
            st.dataframe(t.reset_index(names="Année").assign(Année=lambda d: d["Année"].astype(str)).round(2),
                         hide_index=True, key="ana_interets_table",
                         column_config={c: st.column_config.NumberColumn(f"{c} (€)", format="localized")
                                        for c in t.columns})
            if lv.taux:
                st.html("<div class='note'>Dernier taux connu : " + " · ".join(
                    f"{n} {str(v).replace('.', ',')} % net" for n, v in lv.taux.items()) + ".</div>")


def section_charges(ctx: Contexte) -> None:
    abos = abonnements(ctx.brut_tout, ctx.fin)
    dep = depenses_de(ctx.comp)
    fixes = dep[dep["sous_categorie"].isin(CHARGES_FIXES)]
    total_fixes = float(fixes["montant"].sum())
    actifs = abos[(abos["Statut"] == "Actif") & (abos["Catégorie"] == "Abonnements")] if not abos.empty else abos
    mensuel = float(actifs["Coût mensuel actuel (€)"].sum()) if not actifs.empty else 0.0
    st.html(html_tuiles([
        ("Charges fixes", montant_html(total_fixes / ctx.mois), "par mois en moyenne (loyer net, factures…)"),
        ("Part des dépenses", fmt_pct(total_fixes / dep["montant"].sum() * 100 if dep["montant"].sum() else 0),
         "consacrée aux charges fixes", "", False),
        ("Abonnements actifs", f"{len(actifs)}", "prélevés ces 40 derniers jours", "", False),
        ("Coût des abonnements", montant_html(mensuel), f"par mois · {fmt_eur0(mensuel * 12)} par an", "", False),
    ]))
    with carte("ana_abos"):
        titre_carte("Mes abonnements et charges récurrentes", "Vus sur les 12 derniers mois · « Arrêté » = plus "
                    "de paiement depuis 40 jours", "Récurrent")
        if abos.empty:
            st.html("<div class='note'>Aucune charge récurrente détectée.</div>")
        else:
            st.dataframe(abos, hide_index=True, key="ana_abos_table", column_config={
                "Payé sur 12 mois (€)": st.column_config.ProgressColumn(
                    format="%.0f €", min_value=0, max_value=float(abos["Payé sur 12 mois (€)"].max()), color="#3987E5"),
                "Montant habituel (€)": st.column_config.NumberColumn(format="localized"),
                "Coût mensuel actuel (€)": st.column_config.NumberColumn(format="localized"),
                "Dernier paiement": st.column_config.DateColumn(format="DD/MM/YYYY"),
            })
    with carte("ana_fixes"):
        titre_carte("Charges fixes ou dépenses courantes ?", "Ce qui tombe chaque mois quoi qu'il arrive, et le reste",
                    "Structure")
        mois = mois_entre(ctx.debut, ctx.fin)
        table = pd.DataFrame({
            "Charges fixes": fixes.groupby("mois")["montant"].sum().reindex(mois, fill_value=0.0),
            "Dépenses courantes": dep[~dep["sous_categorie"].isin(CHARGES_FIXES)].groupby("mois")["montant"].sum()
            .reindex(mois, fill_value=0.0),
        })
        tracer(fig_empile(mois, table, {"Charges fixes": SERIE["Besoins"], "Dépenses courantes": SERIE["Envies"]}),
               "ana_fixes")
    apps = ctx.brut[(ctx.brut["marchand"] == "App Store")]
    if not apps.empty:
        with carte("ana_apps"):
            titre_carte("Les achats dans les applications", "Paiements Apple hors Apple Music et iCloud+", "App Store")
            st.html(html_tuiles([
                ("Total", montant_html(apps["montant"].sum()), f"{len(apps)} achats"),
                ("Par mois", montant_html(apps["montant"].sum() / ctx.mois), "en moyenne", "", False),
                ("Mois record", libelle_mois(apps.groupby("mois")["montant"].sum().idxmax()),
                 fmt_eur0(apps.groupby("mois")["montant"].sum().max()), "", False),
            ]))


def section_jeux(ctx: Contexte) -> None:
    jeux = operations_jeux(ctx.brut)
    if jeux.empty:
        st.info("Aucun pari, loto ni casino sur cette période.")
        return
    mises = jeux[jeux["sens"] == "Mises"]
    gains = jeux[jeux["sens"] == "Gains"]
    net = float(gains["montant"].sum() - mises["montant"].sum())
    st.html(html_tuiles([
        ("Résultat net", montant_html(net, signe=True), "gains − mises", "pos" if net >= 0 else "neg"),
        ("Misé", montant_html(mises["montant"].sum()), f"{len(mises)} mises", "", False),
        ("Gagné", montant_html(gains["montant"].sum()), f"{len(gains)} retraits de gains", "", False),
        ("Mise moyenne", montant_html(mises["montant"].mean() if not mises.empty else 0), "par opération", "", False),
        ("Retour", fmt_pct(gains["montant"].sum() / mises["montant"].sum() * 100) if mises["montant"].sum() else "—",
         "des mises récupérées", "", False),
    ]))
    mois = mois_entre(ctx.debut, ctx.fin)
    m = mises.groupby("mois")["montant"].sum().reindex(mois, fill_value=0.0)
    g = gains.groupby("mois")["montant"].sum().reindex(mois, fill_value=0.0)
    with carte("ana_jeux"):
        titre_carte("Mes jeux d'argent, mois par mois", "Gains au-dessus de l'axe, mises en dessous · la ligne suit "
                    "le résultat cumulé", "Paris & casino")
        x = [libelle_mois_court(p) for p in mois]
        fig = go.Figure()
        fig.add_bar(x=x, y=g, name="Gains", marker_color=SERIE["Épargne"], hovertemplate="Gains : %{y:,.0f} €<extra></extra>")
        fig.add_bar(x=x, y=-m, name="Mises", marker_color=SERIE["Dépenses"], customdata=m,
                    hovertemplate="Mises : %{customdata:,.0f} €<extra></extra>")
        fig.add_scatter(x=x, y=(g - m).cumsum(), name="Résultat cumulé", mode="lines",
                        line=dict(color=SERIE["Revenus"], width=2),
                        hovertemplate="Résultat cumulé : %{y:,.0f} €<extra></extra>")
        fig.update_layout(barmode="relative", bargap=0.4, hovermode="x unified")
        tracer(styliser(fig, 320, zero=True), "ana_jeux")
    with carte("ana_operateurs"):
        titre_carte("Par opérateur", "Mises, gains et résultat chez chaque opérateur", "Détail")
        t = jeux.pivot_table(index="operateur", columns="sens", values="montant", aggfunc="sum", fill_value=0.0)
        t = t.reindex(columns=["Mises", "Gains"], fill_value=0.0)
        t["Résultat (€)"] = t["Gains"] - t["Mises"]
        t = t.sort_values("Mises", ascending=False).reset_index().rename(
            columns={"operateur": "Opérateur", "Mises": "Misé (€)", "Gains": "Gagné (€)"}).round(2)
        st.dataframe(t, hide_index=True, key="ana_operateurs_table", column_config={
            c: st.column_config.NumberColumn(format="localized") for c in ("Misé (€)", "Gagné (€)", "Résultat (€)")})
        st.html("<div class='note'>Sont comptés : les catégories « Jeux d'argent » et « Gains de jeux », et toute note "
                "qui mentionne un casino, Betclic, Winamax, la FDJ, le loto ou le PMU.</div>")


def section_saisons(ctx: Contexte) -> None:
    dep = depenses_de(ctx.comp)
    mensuel = dep.groupby("mois")["montant"].sum()
    complets = mensuel[(mensuel.index < mois_courant())
                       & (mensuel.index >= pd.Period(ctx.brut_tout["date_operation"].min(), freq="M") + 1)]
    if complets.empty:
        st.info("Il faut au moins un mois complet pour étudier les saisons.")
        return
    par_mois_annee = complets.groupby(complets.index.month).mean().reindex(range(1, 13))
    gauche, droite = st.columns(2, gap="medium")
    with gauche, carte("ana_saison"):
        titre_carte("Les mois qui coûtent", "Dépenses moyennes de chaque mois de l'année", "Saisonnalité")
        fig = go.Figure(go.Bar(x=MOIS_COURTS, y=par_mois_annee, marker_color=ACCENT,
                               text=[fmt_eur0(v) if pd.notna(v) else "" for v in par_mois_annee], textposition="outside",
                               textfont=dict(color=ENCRE_2, size=10), cliponaxis=False,
                               hovertemplate="<b>%{x}</b> : %{y:,.0f} € en moyenne<extra></extra>"))
        fig.update_layout(bargap=0.4)
        styliser(fig, 300, legende=False)
        fig.update_layout(margin=dict(t=24, b=8, l=4, r=6))
        tracer(fig, "ana_saison")
        if par_mois_annee.notna().any():
            st.html(f"<div class='note'>Mois le plus cher en moyenne : <b>{MOIS_FR[int(par_mois_annee.idxmax()) - 1]}</b> · "
                    f"le plus sobre : <b>{MOIS_FR[int(par_mois_annee.idxmin()) - 1]}</b>.</div>")
    with droite, carte("ana_carte_chaleur"):
        titre_carte("Année après année", "Dépenses de chaque mois · plus la case est dorée, plus le mois a coûté",
                    "Heatmap")
        annees = sorted({p.year for p in mensuel.index})
        z = [[float(mensuel.get(pd.Period(year=a, month=m, freq="M"), float("nan"))) for m in range(1, 13)] for a in annees]
        fig = go.Figure(go.Heatmap(z=z, x=MOIS_COURTS, y=[str(a) for a in annees], colorscale=RAMPE, xgap=3, ygap=3,
                                   colorbar=dict(thickness=8, outlinewidth=0, ticksuffix=" €",
                                                 tickfont=dict(color=MUET, size=10)),
                                   hovertemplate="%{x} %{y} : <b>%{z:,.0f} €</b><extra></extra>", zmin=0,
                                   zmax=float(complets.quantile(0.9))))
        styliser(fig, 300, legende=False, suffixe="")
        fig.update_yaxes(showgrid=False, type="category")
        fig.update_xaxes(showline=False)
        tracer(fig, "ana_carte_chaleur")
        voir_donnees(pd.DataFrame(z, index=[str(a) for a in annees], columns=MOIS_COURTS).round(0)
                     .reset_index(names="Année"), "chaleur")

    with carte("ana_annuel"):
        titre_carte("Mes postes d'une année sur l'autre", "Les 6 postes principaux de la période, comparés par année",
                    "Comparaison annuelle")
        annees_tout = sorted({d.year for d in ctx.brut_tout["date_operation"]})
        couleur_annee = {a: PALETTE[i % len(PALETTE)] for i, a in enumerate(annees_tout[-4:])}
        top = list(dep.groupby("sous_categorie")["montant"].sum().sort_values(ascending=False).index[:6])
        fig = go.Figure()
        for annee in sorted({d.year for d in dep["date_operation"]})[-4:]:
            g = dep[(dep["date_operation"].dt.year == annee)].groupby("sous_categorie")["montant"].sum().reindex(top,
                                                                                                                 fill_value=0.0)
            fig.add_bar(x=top, y=g, name=str(annee), marker_color=couleur_annee.get(annee, ACCENT),
                        hovertemplate=f"{annee} · %{{x}} : %{{y:,.0f}} €<extra></extra>")
        fig.update_layout(barmode="group", bargap=0.3, bargroupgap=0.08)
        tracer(styliser(fig, 320), "ana_annuel")
        st.html("<div class='note'>L'année en cours n'est pas terminée : compare-la avec prudence.</div>")


def onglet_analyses(df: pd.DataFrame, profil: pd.Series) -> None:
    if df.empty:
        st.info("Les analyses apparaîtront dès que des opérations auront été enregistrées.")
        return
    brut_tout = enrichir(df)
    comp_tout = compenser(brut_tout)
    with st.container(key="tete_analyses"), st.container(horizontal=True, gap="small", key="choix_analyse"):
        debut, fin, libelle = choisir_bornes_analyse(brut_tout)
        st.session_state.setdefault("ana_section", "Vue d'ensemble")
        section = st.selectbox("Rubrique", list(SECTIONS_ANALYSE), key="ana_section", label_visibility="collapsed",
                               format_func=lambda s: f"{SECTIONS_ANALYSE[s]} {s}", filter_mode=None)
    brut, comp = entre(brut_tout, debut, fin), entre(comp_tout, debut, fin)
    avoirs = avoirs_ou_rien(profil["id"])
    ctx = Contexte(brut=brut, comp=comp, brut_tout=brut_tout, comp_tout=comp_tout, debut=debut, fin=fin,
                   libelle=libelle, tm=table_mensuelle(comp, comp_tout, debut, fin), prenom=profil["prenom"],
                   livrets=calculer_livrets(avoirs, brut_tout, fin) if avoirs else None)
    entete_section(f"Analyses · {libelle}", section, {
        "Vue d'ensemble": "Le grand tableau de ton historique : flux, solde, équilibre et enseignements.",
        "Dépenses": "Comment se répartit chaque euro dépensé, et comment cela évolue.",
        "Marchands & lieux": "Les enseignes et les villes où part ton argent.",
        "Habitudes": "Tes rythmes : jours de la semaine, cycle de paie, calendrier.",
        "Revenus": "D'où vient l'argent, et la montée de ton autonomie.",
        "Épargne": "Ce qui est vraiment mis de côté, support par support.",
        "Charges fixes": "Abonnements et charges qui tombent chaque mois.",
        "Jeux d'argent": "Paris sportifs, loto et casino : mises, gains, résultat.",
        "Saisons": "Les mois qui coûtent et la comparaison d'une année sur l'autre.",
    }[section])
    {
        "Vue d'ensemble": section_vue_ensemble, "Dépenses": section_depenses, "Marchands & lieux": section_marchands,
        "Habitudes": section_habitudes, "Revenus": section_revenus, "Épargne": section_epargne,
        "Charges fixes": section_charges, "Jeux d'argent": section_jeux, "Saisons": section_saisons,
    }[section](ctx)


# --- Saisie ------------------------------------------------------------------------------------

def lire_montant(texte: str | None) -> float | None:
    """« 12,50 », « 12.5 », « 1 200 € » -> float ; None si invalide ou nul."""
    propre = re.sub(r"[\s €]", "", texte or "").replace(",", ".")
    if not re.fullmatch(r"\d{1,7}(\.\d{0,2})?", propre):
        return None
    valeur = float(propre)
    return valeur if valeur > 0 else None


def compte_choisi(cle: str) -> str | None:
    """Compte d'une rangée de choix de l'onglet Ajouter : '' pour le compte courant, le nom pour un autre compte,
    le nom saisi pour un nouveau compte (un nom déjà connu, à la casse près, reprend le compte existant).
    None si rien n'est choisi ou si le nouveau compte n'a pas encore de nom."""
    etat = st.session_state
    choix = etat.get(cle)
    if choix is None:
        return None
    if choix == NOM_COMPTE_COURANT:
        return COMPTE_COURANT
    if choix != NOUVEAU_COMPTE:
        return choix
    nom = re.sub(r"\s+", " ", etat.get(f"{cle}_nouveau") or "").strip()[:30]
    if not nom:
        return None
    if nom.casefold() == NOM_COMPTE_COURANT.casefold():
        return COMPTE_COURANT
    connus = [*etat.get("ajout_comptes_connus", []), *etat.get("ajout_livrets_connus", [])]
    return next((c for c in connus if c.casefold() == nom.casefold()), nom)


def valider_ajout(profil_id: str, cle_sous: str) -> None:
    """Callback du bouton « Ajouter » : exécuté avant le réaffichage, il peut donc vider les champs.

    Toutes les valeurs sont relues dans session_state : ce sont les plus récentes saisies.
    """
    etat = st.session_state
    pave = etat.get("ajout_pave") or {}
    montant = lire_montant(pave.get("valider") if isinstance(pave, dict) else getattr(pave, "valider", None))
    virement = etat.get("ajout_type") == "Virement"
    sous_categorie = SC_VIREMENT if virement else etat.get(cle_sous)
    description = etat.get("ajout_description") or ""
    quand = etat.get("ajout_quand", "Aujourd'hui")
    if quand == "Autre date":
        jour = etat.get("ajout_date") or aujourdhui()
    else:
        jour = aujourdhui() - timedelta(days=1 if quand == "Hier" else 0)
    erreurs = []
    if montant is None:
        erreurs.append("Saisis un montant valide, par exemple 12,50.")
    compte = compte_choisi("ajout_compte") if etat.get("ajout_compte") is not None else COMPTE_COURANT
    vers = compte_choisi("ajout_vers") if virement else None
    if compte is None:
        erreurs.append("Donne un nom au nouveau compte.")
    if virement:
        if etat.get("ajout_vers") is None:
            erreurs.append("Choisis le compte qui reçoit le virement.")
        elif vers is None:
            erreurs.append("Donne un nom au nouveau compte qui reçoit le virement.")
        elif vers == compte:
            erreurs.append("Choisis deux comptes différents pour le virement.")
    if not sous_categorie:
        erreurs.append("Choisis une catégorie.")
    ou = (f" · {nom_compte(compte)} → {nom_compte(vers or '')}" if virement
          else (f" · {compte}" if compte else ""))
    livrets = etat.get("ajout_livrets_connus", [])
    if virement and not erreurs and (compte in livrets or vers in livrets):
        # Un livret n'est pas un compte : un versement est de l'épargne (« Livret »), un retrait un « Retrait
        # d'épargne », sur le compte courant, avec le nom du livret dans la note pour que son solde suive
        livret, autre = (compte, vers) if compte in livrets else (vers, compte)
        if autre != COMPTE_COURANT:
            erreurs.append("Un livret se vire seulement avec le compte courant.")
        else:
            retrait = livret == compte
            note = description.strip()
            sous_categorie = "Retrait d'épargne" if retrait else "Livret"
            description = (f"Depuis le {livret}" if retrait else f"Vers le {livret}") + (f" · {note}" if note else "")
            compte, vers, virement = COMPTE_COURANT, None, False
    if virement and not description.strip() and vers is not None:
        description = f"Vers {nom_compte(vers)}" if vers else f"Depuis {nom_compte(compte)}"
    if not erreurs:
        try:
            op_id = ajouter_operation(profil_id, sous_categorie, montant, jour, description, compte, vers)
        except Exception as exc:  # noqa: BLE001
            erreurs.append(message_erreur_db(exc))
    if erreurs:
        etat["ajout_erreurs"] = erreurs
        return
    notifier(f"{sous_categorie} · {fmt_eur(montant)}{ou} ajouté")
    etat["dernier_ajout"] = {"id": op_id, "texte": f"{description.strip() or sous_categorie} · {fmt_eur(montant)}{ou}"}
    # Formulaire vidé pour la saisie suivante (retour au compte courant : pas de saisie par erreur sur un autre compte)
    etat["ajout_jeton"] = etat.get("ajout_jeton", 0) + 1   # le pavé numérique repart de zéro
    etat["ajout_suggestion"] = ""
    etat["ajout_description"] = ""
    etat["ajout_quand"] = "Aujourd'hui"
    etat["ajout_compte"] = NOM_COMPTE_COURANT
    etat["ajout_vers"] = None
    etat["ajout_compte_nouveau"] = etat["ajout_vers_nouveau"] = ""
    if cle_sous in etat:
        etat[cle_sous] = None
    etat["ajout_devine"] = etat["ajout_devine_applique"] = None


def note_modifiee(profil_id: str) -> None:
    """Callback de la note : devine la catégorie (et le montant habituel) sans écraser un choix déjà fait."""
    etat = st.session_state
    if etat.get("ajout_type") == "Virement":  # pas de catégorie à deviner pour un virement entre mes comptes
        etat["ajout_devine"] = None
        return
    try:
        idx = index_historique(profil_id)
    except Exception:  # noqa: BLE001 — base injoignable : pas de suggestion
        return
    devine = deviner_saisie(etat.get("ajout_description") or "", idx, None)
    etat["ajout_devine"] = devine
    if not devine:
        return
    cle_actuelle = f"ajout_sous_{CLES_TYPES[etat.get('ajout_type') or 'Dépense']}"
    choix = etat.get(cle_actuelle)
    if choix and choix != etat.get("ajout_devine_applique"):
        return  # catégorie choisie à la main : on la respecte
    if choix:
        etat[cle_actuelle] = None
    type_devine = type_saisie(devine["sc"])
    etat["ajout_type"] = type_devine
    etat[f"ajout_sous_{CLES_TYPES[type_devine]}"] = devine["sc"]
    etat["ajout_devine_applique"] = devine["sc"]
    # Montant habituel : le pavé l'affiche seulement s'il est vide (ou montre encore une suggestion précédente)
    etat["ajout_suggestion"] = f"{devine['montant']:.2f}".replace(".", ",") if devine["montant"] else ""


def oublier_raccourci() -> None:
    st.session_state["ajout_raccourci"] = None


def ajout_rapide(profil_id: str, favoris: list[dict]) -> None:
    """Callback du bouton « Ajouter » d'un raccourci confirmé : enregistre l'opération à la date du jour."""
    etat = st.session_state
    i = etat.get("ajout_raccourci")
    etat["ajout_raccourci"] = None
    if i is None or i >= len(favoris):
        return
    r = favoris[i]
    try:
        op_id = ajouter_operation(profil_id, r["sc"], r["montant"], aujourdhui(), r["description"],
                                  r.get("compte", COMPTE_COURANT), r.get("vers"))
    except Exception as exc:  # noqa: BLE001
        etat["ajout_erreurs"] = [message_erreur_db(exc)]
        return
    texte = f"{r['description']} · {fmt_eur(r['montant'])}" + (f" · {r['compte']}" if r.get("compte") else "")
    etat["dernier_ajout"] = {"id": op_id, "texte": texte}
    notifier(f"{texte} ajouté")


def annuler_dernier_ajout(profil_id: str) -> None:
    dernier = st.session_state.pop("dernier_ajout", None)
    if not dernier:
        return
    try:
        supprimer_operation(dernier["id"], profil_id)
    except Exception as exc:  # noqa: BLE001
        st.session_state["ajout_erreurs"] = [message_erreur_db(exc)]
        return
    notifier("Ajout annulé")


AIDES_TYPES = {
    "Dépense": "Besoins : loyer, courses, transport… · Envies : sorties, shopping, loisirs…",
    "Revenu": "Remboursement loyer, gains de jeux et dépôt d'espèces viennent en déduction de la dépense concernée.",
    "Épargne": "Retrait et vente diminuent l'épargne nette (l'argent revient sur le compte).",
    "Virement": "Entre deux de tes comptes : ni revenu ni dépense, seuls les soldes des deux comptes bougent. "
                "Vers un livret, c'est de l'épargne ; depuis un livret, un retrait d'épargne.",
}
LIBELLES_COMPTE = {"Dépense": "Payé avec", "Revenu": "Reçu sur", "Épargne": "Depuis"}


def rangee_comptes(libelle: str, cle: str, comptes: list[str], requis: bool, livrets: list[str] = ()) -> None:
    """Choix d'un compte en un toucher (le compte courant d'abord, puis les livrets pour un virement),
    avec « Nouveau compte » et son nom."""
    options = [nom_compte(c) for c in comptes] + [l for l in livrets if l not in comptes] + [NOUVEAU_COMPTE]

    def icone(o: str) -> str:
        if o == NOUVEAU_COMPTE:
            return o
        nom = "account_balance" if o == NOM_COMPTE_COURANT else "savings" if o in livrets else "credit_card"
        return f":material/{nom}: {o}"

    if st.session_state.get(cle) not in [*options, None] or (requis and st.session_state.get(cle) is None):
        st.session_state[cle] = NOM_COMPTE_COURANT if requis else None
    st.html(f"<div class='etiquette'>{escape(libelle)}</div>")
    st.pills(libelle, options, key=cle, required=requis, label_visibility="collapsed", format_func=icone)
    if st.session_state.get(cle) == NOUVEAU_COMPTE:
        st.text_input("Nom du compte", key=f"{cle}_nouveau", max_chars=30, label_visibility="collapsed",
                      placeholder="Nom du compte (Revolut, Lydia, PayPal…)")


# --- Pavé numérique ----------------------------------------------------------------------------
# Deux petits composants JavaScript : le montant affiché en grand et le pavé (avec « Enregistrer »).
# Les touches ne passent pas par le serveur (rien ne se recharge pendant la saisie) ; le montant n'est
# envoyé qu'au moment d'enregistrer. Les deux composants partagent l'état window.__cerclePave.
# Sur ordinateur, le clavier marche aussi (chiffres, virgule, retour arrière, Entrée).

JS_AFFICHAGE_MONTANT = """
export default function(component) {
  const { parentElement } = component;
  let el = parentElement.querySelector('.montant');
  if (!el) {
    el = document.createElement('div');
    el.className = 'montant';
    parentElement.appendChild(el);
  }
  const groupes = (t) => t.replace(/\\B(?=(\\d{3})+(?!\\d))/g, '\\u202f');
  const maj = () => {
    const v = (window.__cerclePave && window.__cerclePave.valeur) || '';
    const morceaux = v.split(',');
    el.classList.toggle('vide', !v);
    el.innerHTML = '<span class="e">' + groupes(morceaux[0] || '0') + '</span>'
      + (v.includes(',') ? '<span class="d">,' + (morceaux[1] || '') + '</span>' : '')
      + '<span class="u">€</span>';
  };
  window.addEventListener('cercle-pave', maj);
  maj();
  return () => window.removeEventListener('cercle-pave', maj);
}
"""
CSS_AFFICHAGE_MONTANT = """
.montant {
  text-align: center; color: #F3F5F7; white-space: nowrap; padding: 10px 0 6px;
  font: 800 3.5rem/1.05 var(--sans, system-ui); letter-spacing: -0.03em; font-variant-numeric: tabular-nums;
}
.montant .d { font-size: 0.62em; }
.montant .u { font-size: 0.42em; margin-left: 6px; color: #A7B0B9; vertical-align: 0.95em; }
.montant.vide .e { color: #4A535C; }
"""

JS_PAVE = """
export default function(component) {
  const { parentElement, data, setTriggerValue } = component;
  const etat = window.__cerclePave = window.__cerclePave || { valeur: '', jeton: null, vu: '', auto: false };
  const signaler = () => window.dispatchEvent(new Event('cercle-pave'));
  if (etat.jeton !== data.jeton) {           // nouvelle opération : montant remis à zéro
    etat.jeton = data.jeton; etat.valeur = ''; etat.vu = ''; etat.auto = false;
  }
  const suggestion = data.suggestion || '';
  if (suggestion !== etat.vu) {              // montant habituel deviné d'après la note
    etat.vu = suggestion;
    if (etat.valeur === '' || etat.auto) { etat.valeur = suggestion; etat.auto = !!suggestion; }
  }
  let grille = parentElement.querySelector('.grille');
  if (!grille) {
    grille = document.createElement('div');
    grille.className = 'grille';
    for (const t of ['1', '2', '3', '4', '5', '6', '7', '8', '9', ',', '0', 'del']) {
      const b = document.createElement('button');
      b.type = 'button';
      b.dataset.t = t;
      b.textContent = t === 'del' ? '⌫' : t;
      b.setAttribute('aria-label', t === 'del' ? 'Effacer' : t);
      grille.appendChild(b);
    }
    const ok = document.createElement('button');
    ok.type = 'button';
    ok.className = 'ok';
    ok.dataset.t = 'ok';
    grille.appendChild(ok);
    parentElement.appendChild(grille);
  }
  grille.querySelector('.ok').textContent = data.libelle || 'Enregistrer';
  const toucher = (t) => {
    let v = etat.valeur;
    etat.auto = false;
    if (t === 'del') v = v.slice(0, -1);
    else if (t === ',') { if (!v.includes(',')) v = (v || '0') + ','; }
    else if (v.includes(',')) { if (v.split(',')[1].length < 2) v += t; }
    else if (v.length < 6) v = (v === '0' ? '' : v) + t;
    etat.valeur = v;
    signaler();
  };
  etat.valider = () => setTriggerValue('valider', etat.valeur);
  grille.onclick = (ev) => {
    const b = ev.target.closest('button');
    if (!b) return;
    if (b.dataset.t === 'ok') { etat.valider(); return; }
    toucher(b.dataset.t);
    if (navigator.vibrate) navigator.vibrate(6);
  };
  // Clavier de l'ordinateur, sauf quand on écrit dans un champ (la note, par exemple)
  if (window.__cercleClavier) document.removeEventListener('keydown', window.__cercleClavier);
  window.__cercleClavier = (ev) => {
    const actif = document.activeElement;
    if (actif && (actif.tagName === 'INPUT' || actif.tagName === 'TEXTAREA' || actif.isContentEditable)) return;
    if (!parentElement.isConnected) return;
    if (/^[0-9]$/.test(ev.key)) toucher(ev.key);
    else if (ev.key === ',' || ev.key === '.') toucher(',');
    else if (ev.key === 'Backspace') toucher('del');
    else if (ev.key === 'Enter') etat.valider();
    else return;
    ev.preventDefault();
  };
  document.addEventListener('keydown', window.__cercleClavier);
  signaler();
}
"""
CSS_PAVE = """
.grille {
  display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px;
  font-family: var(--sans, system-ui);
}
.grille button {
  height: 52px; border: 0; border-radius: 16px; background: #2A3138; color: #F3F5F7;
  font: 600 1.45rem var(--sans, system-ui); cursor: pointer; touch-action: manipulation;
  -webkit-tap-highlight-color: transparent; user-select: none; -webkit-user-select: none;
  transition: background 0.08s, transform 0.08s;
}
.grille button:active { background: #3A424B; transform: scale(0.97); }
.grille .ok {
  grid-column: 1 / -1; height: 54px; margin-top: 4px; border-radius: 999px;
  background: #F3F5F7; color: #14181C; font: 800 1rem var(--sans, system-ui);
  box-shadow: 0 14px 30px -18px rgba(243, 245, 247, 0.6);
}
.grille .ok:active { background: #D9DEE3; }
@media (max-height: 860px) { .grille button { height: 47px; } .grille .ok { height: 50px; } }
@media (max-height: 740px) { .grille button { height: 42px; } .grille .ok { height: 46px; } }
"""
affichage_montant = st.components.v2.component("cercle_affichage_montant", js=JS_AFFICHAGE_MONTANT,
                                               css=CSS_AFFICHAGE_MONTANT)
pave_numerique = st.components.v2.component("cercle_pave_numerique", js=JS_PAVE, css=CSS_PAVE)


NB_TUILES = 8  # cases de catégories visibles d'emblée (la dernière ouvre la liste complète)
PLUS_DE_CATEGORIES, MOINS_DE_CATEGORIES = "⋯ Toutes", "▴ Moins"


def basculer_categories(cle_sous: str) -> None:
    """La case « ⋯ Toutes » (ou « ▴ Moins ») déplie ou replie la grille au lieu d'être une catégorie."""
    etat = st.session_state
    if etat.get(cle_sous) in (PLUS_DE_CATEGORIES, MOINS_DE_CATEGORIES):
        etat["ajout_toutes"] = etat[cle_sous] == PLUS_DE_CATEGORIES
        etat[cle_sous] = None


def libelle_date_saisie() -> str:
    quand = st.session_state.get("ajout_quand", "Aujourd'hui")
    if quand == "Autre date":
        jour = st.session_state.get("ajout_date") or aujourdhui()
        return f"{JOURS_FR[jour.weekday()].capitalize()} {jour:%d/%m}"
    return quand


@st.fragment
def onglet_ajouter(profil: pd.Series) -> None:
    # Fragment : toucher une pastille, changer de type ou ajouter une opération ne recalcule que ce bloc,
    # pas toute l'application (indispensable sur l'hébergement gratuit, peu puissant).
    afficher_notification()  # confirmation d'ajout (le callback s'exécute avant ce réaffichage)
    try:
        idx, favoris = index_historique(profil["id"]), raccourcis_frequents(profil["id"])
        comptes = comptes_de(charger_operations((profil["id"],))) if colonnes_comptes() else []
    except Exception:  # noqa: BLE001 — base injoignable : la saisie reste possible, sans suggestions
        idx, favoris, comptes = {"index": {}, "noms": {}, "usage": {}}, [], []
    # Livrets dont le relevé est enregistré : proposés dans les virements, enregistrés comme de l'épargne
    livrets = [n for n, v in (avoirs_ou_rien(profil["id"]) or {}).items() if isinstance(v, dict) and v.get("lignes")]
    etat = st.session_state
    etat["ajout_comptes_connus"] = [c for c in comptes if c]
    etat["ajout_livrets_connus"] = livrets
    etat.setdefault("ajout_jeton", 0)
    etat.setdefault("ajout_description", "")
    etat.setdefault("ajout_quand", "Aujourd'hui")
    with carte("ajout"):
        dernier = etat.get("dernier_ajout")
        if dernier:
            with st.container(horizontal=True, vertical_alignment="center", horizontal_alignment="distribute",
                              key="ajout_annuler_ligne"):
                st.html(f"<div class='note' style='margin:0'>✓ {escape(dernier['texte'])} enregistré</div>",
                        width="content")
                st.button("Annuler", icon=":material/undo:", type="tertiary", key="ajout_annuler",
                          on_click=annuler_dernier_ajout, args=(profil["id"],))

        types = TYPES_OPERATION if comptes else TYPES_OPERATION[:3]  # virements : colonnes v18 nécessaires
        if etat.get("ajout_type") not in types:
            etat["ajout_type"] = "Dépense"
        type_op = st.segmented_control("Type", types, required=True, key="ajout_type",
                                       label_visibility="collapsed", width="stretch")
        cle_sous = f"ajout_sous_{CLES_TYPES[type_op]}"

        # Le montant, en grand (il se tape sur le pavé plus bas)
        affichage_montant(key="ajout_affichage", data={"jeton": etat["ajout_jeton"]})

        # Date et compte : deux pastilles qui s'ouvrent au toucher
        with st.container(horizontal=True, gap="small", key="ajout_options"):
            with st.popover(f"📅 {libelle_date_saisie()}"):
                quand = st.segmented_control("Date", ["Aujourd'hui", "Hier", "Autre date"], required=True,
                                             key="ajout_quand", label_visibility="collapsed", width="stretch")
                if quand == "Autre date":
                    st.date_input("Date", value=aujourdhui(), format="DD/MM/YYYY", key="ajout_date",
                                  label_visibility="collapsed")
            if comptes and type_op != "Virement":
                choix = etat.get("ajout_compte") or NOM_COMPTE_COURANT
                court = "Courant" if choix == NOM_COMPTE_COURANT else "Nouveau" if choix == NOUVEAU_COMPTE else choix
                with st.popover(f"🏦 {court}"):
                    rangee_comptes(LIBELLES_COMPTE[type_op], "ajout_compte", comptes, requis=True)
            if favoris:  # ce qui revient à l'identique, enregistré après confirmation
                with st.popover("⚡ Raccourcis"):
                    choisi = st.pills("Raccourcis", list(range(len(favoris))), key="ajout_raccourci",
                                      label_visibility="collapsed",
                                      format_func=lambda i: f"{EMOJIS.get(favoris[i]['sc'], '•')} "
                                                            f"{favoris[i]['nom']} · {fmt_eur(favoris[i]['montant'])}"
                                                            + (f" · {favoris[i]['compte']}" if favoris[i]["compte"]
                                                               and favoris[i]["vers"] is None else ""))
                    if choisi is not None and choisi < len(favoris):
                        r = favoris[choisi]
                        sur = ("" if not r["compte"] or r["vers"] is not None else f" sur {escape(r['compte'])}")
                        st.html(f"<div class='phrase' style='margin:4px 0 0'>Ajouter <b>{escape(r['description'])} · "
                                f"{fmt_eur(r['montant'])}</b>{sur} aujourd'hui ?</div>")
                        with st.container(horizontal=True, key="ajout_confirmer_ligne"):
                            st.button("Ajouter", type="primary", icon=":material/check:", key="ajout_raccourci_ok",
                                      on_click=ajout_rapide, args=(profil["id"], favoris))
                            st.button("Non", type="tertiary", key="ajout_raccourci_non", on_click=oublier_raccourci)

        st.text_input("Note", max_chars=200, key="ajout_description", on_change=note_modifiee,
                      args=(profil["id"],), label_visibility="collapsed",
                      placeholder="Note (facultative)" if type_op == "Virement" else "Note : mcdo, Leclerc, loyer…")
        if type_op == "Virement":
            rangee_comptes("De", "ajout_compte", comptes, requis=True, livrets=livrets)
            rangee_comptes("Vers", "ajout_vers", comptes, requis=False, livrets=livrets)
        else:
            devine = etat.get("ajout_devine")
            if devine and etat.get(cle_sous) == devine["sc"]:
                appui = (f"d'après {devine['nb']} opération{'s' if devine['nb'] > 1 else ''} « {escape(devine['nom'])} »"
                         if devine["nb"] else "d'après la note")
                st.html(f"<div class='devine'>✦ Catégorie devinée : <b>{escape(devine['sc'])}</b> · {appui}</div>")
            # Grille de 8 cases : les 7 catégories les plus utilisées et « Toutes » (sans défilement de côté)
            options = [nom for nom in SOUS_CATEGORIES if type_saisie(nom) == type_op]
            usage = idx.get("usage", {})
            triees = sorted(options, key=lambda n: (-usage.get(n, 0), options.index(n)))
            toutes = etat.get("ajout_toutes", False)
            visibles = triees if toutes else triees[:NB_TUILES - 1]
            choix = etat.get(cle_sous)
            if choix and choix not in visibles and choix != PLUS_DE_CATEGORIES:
                visibles = [*visibles[:-1], choix] if not toutes else visibles
            if len(triees) > NB_TUILES - 1:
                visibles = [*visibles, MOINS_DE_CATEGORIES if toutes else PLUS_DE_CATEGORIES]
            st.pills("Catégorie", visibles, key=cle_sous, label_visibility="collapsed",
                     format_func=lambda n: n if n in (PLUS_DE_CATEGORIES, MOINS_DE_CATEGORIES) else libelle_sous_categorie(n),
                     on_change=basculer_categories, args=(cle_sous,))

        for erreur in etat.pop("ajout_erreurs", []):
            st.error(erreur)
        pave_numerique(key="ajout_pave", data={"jeton": etat["ajout_jeton"], "suggestion": etat.get("ajout_suggestion", ""),
                                               "libelle": "Enregistrer"},
                       on_valider_change=lambda: valider_ajout(profil["id"], cle_sous))
        st.caption(AIDES_TYPES[type_op])

    try:  # relu ici (cache vidé après un ajout) pour afficher tout de suite la nouvelle opération
        recents = charger_operations((profil["id"],))
    except Exception as exc:  # noqa: BLE001
        st.error(message_erreur_db(exc))
        return
    if not recents.empty:
        recents = recents.sort_values("created_at", ascending=False)
        with carte("recents"):
            titre_carte("Derniers ajouts", "Une erreur ? Modifie ou supprime directement ici")
            lignes_avec_actions(recents, profil, "recent", 5)


@st.dialog("Modifier l'opération")
def dialogue_modifier(op: pd.Series, profil_id: str) -> None:
    virement = op["categorie"] == CAT_VIREMENT
    comptes = comptes_de(charger_operations((profil_id,))) if colonnes_comptes() else [COMPTE_COURANT]
    libelles = [nom_compte(c) for c in comptes]

    def position(compte: str) -> int:
        return libelles.index(nom_compte(compte)) if nom_compte(compte) in libelles else 0

    noms = [n for n in SOUS_CATEGORIES if n != SC_VIREMENT]
    index = noms.index(op["sous_categorie"]) if op["sous_categorie"] in noms else 0
    with st.form("modifier", border=False):
        vers = None
        if virement:
            sous_categorie = SC_VIREMENT
            c1, c2 = st.columns(2)
            de = c1.selectbox("De", libelles, index=position(op["compte"]), filter_mode=None)
            vers = c2.selectbox("Vers", libelles, index=position(op["vers_compte"]), filter_mode=None)
        else:
            sous_categorie = st.selectbox(
                "Catégorie", noms, index=index,
                format_func=lambda n: f"{n} · {type_saisie(n)}", filter_mode=None,
            )
            de = (st.selectbox("Compte", libelles, index=position(op["compte"]), filter_mode=None) if len(comptes) > 1
                  else nom_compte(op["compte"]))
        c1, c2 = st.columns(2)
        texte_montant = c1.text_input("Montant (€)", value=f"{op['montant']:.2f}".replace(".", ","),
                                      max_chars=10, key="montant_modif")
        jour = c2.date_input("Date", value=op["date_operation"].date(), format="DD/MM/YYYY")
        description = st.text_input("Note", value=op["description"], max_chars=200)
        valider = st.form_submit_button("Enregistrer", type="primary", width="stretch")
    if valider:
        montant = lire_montant(texte_montant)
        compte = COMPTE_COURANT if de == NOM_COMPTE_COURANT else de
        arrivee = None if vers is None else (COMPTE_COURANT if vers == NOM_COMPTE_COURANT else vers)
        if montant is None:
            st.error("Saisis un montant valide, par exemple 12,50.")
        elif virement and arrivee == compte:
            st.error("Choisis deux comptes différents pour le virement.")
        elif executer(modifier_operation, op["id"], profil_id, sous_categorie, montant, jour, description,
                      compte, arrivee, succes="Opération modifiée"):
            st.rerun()


@st.dialog("Supprimer l'opération")
def dialogue_supprimer(op: pd.Series, profil_id: str) -> None:
    st.html(html_ligne_operation(op, avec_annee=True))
    st.caption("Cette action est définitive.")
    c1, c2 = st.columns(2)
    if c1.button("Annuler", width="stretch"):
        st.rerun()
    if c2.button("Supprimer", type="primary", width="stretch", icon=":material/delete:"):
        if executer(supprimer_operation, op["id"], profil_id, succes="Opération supprimée"):
            st.rerun()


@st.dialog("Supprimer les opérations")
def dialogue_supprimer_plusieurs(ops: pd.DataFrame, profil_id: str) -> None:
    st.html(html_mouvements(ops, limite=8, avec_annee=True))
    if len(ops) > 8:
        st.caption(f"… et {len(ops) - 8} autre(s).")
    st.caption("Cette action est définitive.")
    c1, c2 = st.columns(2)
    if c1.button("Annuler", width="stretch", key="suppr_multi_annuler"):
        st.rerun()
    if c2.button(f"Supprimer ({len(ops)})", type="primary", width="stretch", icon=":material/delete:",
                 key="suppr_multi_ok"):
        if executer(supprimer_operations, list(ops["id"]), profil_id,
                    succes=f"{len(ops)} opération{'s' if len(ops) > 1 else ''} supprimée{'s' if len(ops) > 1 else ''}"):
            st.rerun()


def effet_affiche(df: pd.DataFrame, compte: str | None = None) -> pd.Series:
    """Montant signé affiché : vu du compte choisi, sinon du compte de l'opération (virement : voir vu_du_compte)."""
    if compte is not None:
        return montant_signe(df, compte)
    signe = df["montant"].where(df["categorie"] == CAT_REVENU, -df["montant"])
    arrivee = [vu_du_compte(s, d, None) == d for s, d in zip(df["compte"], df["vers_compte"])]
    return signe.where(~((df["categorie"] == CAT_VIREMENT) & pd.Series(arrivee, index=df.index, dtype=bool)),
                       df["montant"])


def libelle_compte_op(op_compte: str, vers: str, categorie: str) -> str:
    return f"{nom_compte(op_compte)} → {nom_compte(vers)}" if categorie == CAT_VIREMENT else nom_compte(op_compte)


def tableau_operations(df: pd.DataFrame, cle: str | None = None, compte: str | None = None):
    """Tableau d'opérations (montants signés : + revenus, − sorties). Retourne l'événement de sélection."""
    vue = df.assign(
        type=[type_affiche(c, s) for c, s in zip(df["categorie"], df["sous_categorie"])],
        montant_signe=effet_affiche(df, compte),
        nom_compte=[libelle_compte_op(c, v, cat) for c, v, cat in zip(df["compte"], df["vers_compte"], df["categorie"])],
    )
    colonnes = ["date_operation", "sous_categorie", "type", "montant_signe", "description"]
    if (vue["nom_compte"] != NOM_COMPTE_COURANT).any():
        colonnes.insert(3, "nom_compte")
    options = dict(on_select="rerun", selection_mode="multi-row", key=cle) if cle else {}
    return st.dataframe(
        vue[colonnes],
        hide_index=True,
        column_config={
            "date_operation": st.column_config.DateColumn("Date", format="DD/MM/YYYY"),
            "sous_categorie": "Catégorie",
            "type": "Type",
            "nom_compte": st.column_config.TextColumn("Compte", width="medium"),
            "montant_signe": st.column_config.NumberColumn("Montant (€)", format="%+.2f"),
            "description": st.column_config.TextColumn("Note", width="large"),
        },
        height=560,
        **options,
    )


LIMITE_LISTE_MOBILE = 60


def lignes_avec_actions(vue: pd.DataFrame, profil: pd.Series, prefixe: str, limite: int,
                        compte: str | None = None) -> None:
    """Une ligne par opération, avec deux boutons bien visibles : modifier (crayon) et supprimer (corbeille)."""
    for _, op in vue.head(limite).iterrows():
        with st.container(horizontal=True, vertical_alignment="center", gap=None, key=f"{prefixe}_{op['id']}"):
            st.html(html_ligne_operation(op, compte=compte))
            if st.button("", icon=":material/edit:", type="tertiary", key=f"modif_{prefixe}_{op['id']}",
                         help="Modifier"):
                dialogue_modifier(op, profil["id"])
            if st.button("", icon=":material/delete:", type="tertiary", key=f"suppr_{prefixe}_{op['id']}",
                         help="Supprimer"):
                dialogue_supprimer(op, profil["id"])


def libelle_jour_long(jour: pd.Timestamp) -> str:
    """« Lundi 27 octobre » (avec l'année si ce n'est pas l'année en cours)."""
    texte = f"{JOURS_LONGS[jour.weekday()].capitalize()} {jour.day} {MOIS_FR[jour.month - 1]}"
    return texte if jour.year == aujourdhui().year else f"{texte} {jour.year}"


def liste_operations_mobile(vue: pd.DataFrame, profil: pd.Series, compte: str | None = None) -> None:
    """Historique tactile regroupé par jour (total du jour en tête), avec les boutons modifier / supprimer."""
    st.caption(f"{len(vue)} opération(s)"
               + (f" — les {LIMITE_LISTE_MOBILE} plus récentes" if len(vue) > LIMITE_LISTE_MOBILE else ""))
    d = vue.head(LIMITE_LISTE_MOBILE)
    effet = effet_affiche(d, compte)
    for jour, groupe in d.groupby(d["date_operation"].dt.normalize(), sort=False):
        st.html(f"<div class='jour-tete'><span>{libelle_jour_long(jour)}</span>"
                f"<span>{fmt_eur(float(effet[groupe.index].sum()), signe=True)}</span></div>")
        with st.container(key=f"jour_{jour:%Y%m%d}"):
            lignes_avec_actions(groupe, profil, "op", len(groupe), compte)


# Mots trop courants pour dire que deux opérations parlent du même marchand
MOTS_VIDES = {"virement", "retrait", "especes", "depuis", "vers", "mon", "compte", "remboursement", "achats",
              "les", "des", "aux", "sur", "carburant"}


def preparer_import(lignes: list, debut: date, df: pd.DataFrame, profil: pd.Series) -> tuple[pd.DataFrame, dict, bool]:
    """Pour chaque ligne du relevé : catégorie proposée et opération déjà enregistrée qui lui correspond.

    Priorité : tes corrections passées (libellé identique), puis ton historique (même marchand, montant
    proche), puis les règles d'enseignes. Une ligne est « déjà enregistrée » s'il existe une opération du
    même sens et du même montant à 5 jours près ; elle est « peut-être saisie » si le même marchand
    apparaît à 4 jours près avec un autre montant (montant saisi net d'un remboursement, par exemple).
    """
    idx = index_historique(profil["id"])
    try:
        regles, regles_ok = dict(charger_regles_import(profil["id"])), True
    except Exception:  # noqa: BLE001 — colonne pas encore créée dans Supabase
        regles, regles_ok = {}, False
    existantes = enrichir(df[df["date_operation"] >= pd.Timestamp(debut - timedelta(days=7))])
    # Seules comptent les opérations qui font bouger le compte courant (pas celles payées depuis un autre compte) ;
    # un virement vers un autre compte est une sortie, un virement qui en revient une entrée
    effet = montant_signe(existantes)
    existantes = existantes.assign(credit=effet > 0, montant=effet.abs())[effet.abs() > 0.004]
    par_montant: dict[tuple[float, bool], list] = defaultdict(list)
    for e in zip(existantes["id"], existantes["date_operation"].dt.date, existantes["montant"],
                 existantes["credit"], existantes["description"], existantes["sous_categorie"],
                 existantes["marchand"]):
        par_montant[(round(float(e[2]), 2), bool(e[3]))].append(e)
    utilises: set[str] = set()
    sortie = []
    for l in sorted((l for l in lignes if l.compta >= debut), key=lambda l: (l.compta, l.numero)):
        p = releve.proposer(l, profil["prenom"])
        credit = l.montant > 0
        sc, note = p["sous_categorie"], p["description"]
        source = "règle" if p["sur"] else "à vérifier"
        cle = releve.cle_libelle(l.libelle)
        if isinstance(regles.get(cle), list) and len(regles[cle]) == 2 and regles[cle][0] in SOUS_CATEGORIES:
            sc, note, source = regles[cle][0], regles[cle][1], "ta correction"
        else:
            trouves, _ = correspondances(marchand_de(note, sc), idx)
            sc_h, part = meilleure_categorie(trouves, abs(l.montant), credit=credit)
            if sc_h and sc_h != sc and (not p["sur"] or (part >= 0.6 and len(trouves) >= 3)):
                sc, source = sc_h, "ton historique"
            elif sc_h == sc and not p["sur"]:
                source = "ton historique"
        if sc not in SOUS_CATEGORIES or (SOUS_CATEGORIES[sc][0] == CAT_REVENU) != credit:
            sc = "Autre revenu" if credit else "Autre envie"
        # Déjà enregistrée ? (même sens, même montant, à 5 jours près ; à égalité, le même marchand d'abord)
        mots = {m for m in releve.cle_texte(marchand_de(note, sc)).split() if len(m) >= 3} - MOTS_VIDES
        meilleur = None
        for e in par_montant.get((round(abs(l.montant), 2), credit), []):
            ecart = abs((e[1] - p["date"]).days)
            if e[0] in utilises or ecart > 5:
                continue
            score = ecart - (3 if mots & set(releve.cle_texte(f"{e[6]} {e[4]}").split()) else 0)
            if meilleur is None or score < meilleur[1]:
                meilleur = (e, score)
        statut, importer = f"Nouvelle · {source}", True
        if meilleur:
            utilises.add(meilleur[0][0])
            statut, importer = f"Déjà enregistrée · {meilleur[0][4] or meilleur[0][5]}", False
        else:
            proches = existantes[(existantes["credit"] == credit)
                                 & ((existantes["date_operation"] - pd.Timestamp(p["date"])).dt.days.abs() <= 4)]
            for desc, marchand, montant in zip(proches["description"], proches["marchand"], proches["montant"]):
                if mots & set(releve.cle_texte(f"{marchand} {desc}").split()):
                    statut, importer = f"Peut-être déjà saisie · {desc or marchand} ({fmt_eur(montant)})", False
                    break
        sortie.append({"Importer": importer, "Date": p["date"], "Libellé banque": l.libelle,
                       "Montant (€)": l.montant, "Catégorie": sc, "Note": note[:200], "Statut": statut,
                       "_cle": cle, "_sc": sc, "_note": note[:200]})
    return pd.DataFrame(sortie), regles, regles_ok


def choisir_nature_releve(lignes: list, profil: pd.Series, n: int) -> str:
    """Compte courant ou livret ? Devinée d'après les libellés, modifiable."""
    texte = " ".join(l.libelle.upper() for l in lignes)
    virements = sum(1 for l in lignes if re.match(r"VIR C/C|VIR DE M|INTERETS", l.libelle.upper()))
    connus = list((avoirs_ou_rien(profil["id"]) or {}).keys())
    options = ["Mon compte courant", *dict.fromkeys(["Livret Bleu", "Livret Jeune", *connus]), "Un autre livret"]
    if "LIVRET BLEU" in texte:
        devine = "Livret Bleu"
    elif "LIVRET JEUNE" in texte:
        devine = "Livret Jeune"
    elif virements >= 0.8 * len(lignes):
        devine = "Un autre livret"
    else:
        devine = "Mon compte courant"
    nature = st.segmented_control("Ce relevé est celui de", options, default=devine, required=True,
                                  key=f"import_nature_{n}")
    if nature == "Un autre livret":
        nature = st.text_input("Nom du livret", placeholder="Livret A, LDDS…", key=f"import_nom_livret_{n}").strip() \
            or "Un autre livret"
    return nature


def import_releve_livret(contenu: bytes, nom: str, df: pd.DataFrame, profil: pd.Series, n: int) -> None:
    """Relevé d'un livret : on enregistre ses soldes et intérêts, et on précise d'où viennent les retraits."""
    if nom == "Un autre livret":
        st.caption("Donne un nom à ce livret pour l'enregistrer.")
        return
    avoirs = avoirs_ou_rien(profil["id"])
    if avoirs is None:
        st.info("Pour enregistrer les livrets, exécute d'abord la dernière version de `schema.sql` dans Supabase.")
        return
    lignes = releve.lire_releve(contenu, garder_zero=True)
    nouvelles = [[l.compta.isoformat(), l.montant, l.solde, l.libelle] for l in lignes if l.solde is not None]
    anciennes = (avoirs.get(nom) or {}).get("lignes", [])
    vus = {tuple(x) for x in anciennes}
    fusion = sorted([*map(list, anciennes), *[x for x in nouvelles if tuple(x) not in vus]], key=lambda x: x[0])
    interets = [(l.compta.year, l.montant) for l in lignes if "INTERET" in l.libelle.upper()]
    # Retraits du livret = « Depuis mon livret » sur le compte courant, même montant, à 3 jours près
    candidats = df[(df["sous_categorie"] == "Retrait d'épargne") & df["description"].str.casefold().eq("depuis mon livret")]
    renommages, pris = [], set()
    for l in lignes:
        if l.montant >= 0 or "INTERET" in l.libelle.upper():
            continue
        proches = candidats[(~candidats["id"].isin(pris)) & ((candidats["montant"] - abs(l.montant)).abs() < 0.005)
                            & ((candidats["date_operation"] - pd.Timestamp(l.compta)).dt.days.abs() <= 3)]
        if not proches.empty:
            op_id = proches.iloc[0]["id"]
            pris.add(op_id)
            renommages.append((op_id, f"Depuis le {nom}"))
    fin = max(lignes, key=lambda l: (l.compta, l.numero))
    st.html(html_tuiles([
        ("Lignes", f"{len(lignes)}", f"du {min(l.compta for l in lignes):%d/%m/%Y} au {fin.compta:%d/%m/%Y}"),
        ("Solde", montant_html(fin.solde or 0.0), f"au {fin.compta:%d/%m/%Y}", "", False),
        ("Intérêts", montant_html(sum(m for _, m in interets)), ", ".join(str(a) for a, _ in interets) or "aucun",
         "", False),
        ("Retraits reconnus", f"{len(renommages)}", "sur ton compte courant", "", False),
    ]))
    if st.button(f"Enregistrer le relevé du {nom}", type="primary", icon=":material/account_balance:",
                 key=f"import_livret_ok_{n}"):
        if not executer(modifier_profil, profil["id"], avoirs={**avoirs, nom: {"lignes": [list(x) for x in fusion]}},
                        succes=f"Relevé du {nom} enregistré"):
            return
        if renommages and not executer(renommer_operations, renommages, profil["id"]):
            return
        st.session_state["import_n"] = n + 1
        st.rerun()


@st.dialog("Importer un relevé bancaire", width="large")
def dialogue_import_releve(df: pd.DataFrame, profil: pd.Series) -> None:
    carte_import_releve(df, profil)


def carte_import_releve(df: pd.DataFrame, profil: pd.Series) -> None:
    """Import du relevé CSV : la banque fait la saisie, tu ne fais que vérifier."""
    n = st.session_state.setdefault("import_n", 0)
    with st.container(key="import_releve"):
        st.caption("Télécharge tes opérations au format CSV depuis ton espace bancaire en ligne, puis dépose le "
                   "fichier ici. Relevé du compte courant : l'app repère ce qui est déjà enregistré, propose une "
                   "catégorie pour le reste et retient tes corrections. Relevé d'un livret : l'app enregistre ses "
                   "soldes et ses intérêts pour suivre ton patrimoine.")
        fichier = st.file_uploader("Relevé CSV", type=["csv"], key=f"import_fichier_{n}", label_visibility="collapsed")
        if not fichier:
            return
        try:
            lignes = releve.lire_releve(fichier.getvalue())
        except releve.ReleveIllisible as exc:
            st.error(str(exc))
            return
        nature = choisir_nature_releve(lignes, profil, n)
        if nature != "Mon compte courant":
            import_releve_livret(fichier.getvalue(), nature, df, profil, n)
            return
        premier, dernier = min(l.compta for l in lignes), max(l.compta for l in lignes)
        defaut = premier
        if not df.empty:
            defaut = min(max(premier, df["date_operation"].max().date() - timedelta(days=31)), dernier)
        debut = st.date_input("Proposer les opérations à partir du", value=defaut, min_value=premier,
                              max_value=dernier, format="DD/MM/YYYY", key=f"import_debut_{n}")
        table, regles, regles_ok = preparer_import(lignes, debut, df, profil)
        if table.empty:
            st.info("Aucune opération du relevé à partir de cette date.")
            return
        avec_solde = [l for l in lignes if l.solde is not None]
        tuiles = [("Lignes du relevé", f"{len(lignes)}", f"du {premier:%d/%m/%Y} au {dernier:%d/%m/%Y}"),
                  ("Déjà enregistrées", f"{int((~table['Importer']).sum())}", "décochées d'office", "", False),
                  ("À importer", f"{int(table['Importer'].sum())}", "cochées, à vérifier", "", False)]
        if avec_solde:
            fin = max(avec_solde, key=lambda l: (l.compta, l.numero))
            solde_app = solde_jusqua(compenser(df), fin.compta)
            tuiles.append((f"Solde banque au {fin.compta:%d/%m}", montant_html(fin.solde),
                           f"l'app indique {fmt_eur(solde_app)} avant import", "", False))
        st.html(html_tuiles(tuiles))
        edite = st.data_editor(
            table, hide_index=True, key=f"import_table_{n}_{debut:%Y%m%d}", height=min(560, 38 * len(table) + 40),
            column_order=["Importer", "Date", "Libellé banque", "Montant (€)", "Catégorie", "Note", "Statut"],
            disabled=["Libellé banque", "Montant (€)", "Statut"],
            column_config={
                "Importer": st.column_config.CheckboxColumn(width="small"),
                "Date": st.column_config.DateColumn(format="DD/MM/YYYY"),
                "Montant (€)": st.column_config.NumberColumn(format="%+.2f"),
                "Catégorie": st.column_config.SelectboxColumn(
                    options=[n for n in SOUS_CATEGORIES if n != SC_VIREMENT], required=True),
                "Note": st.column_config.TextColumn(max_chars=200),
                "Libellé banque": st.column_config.TextColumn(width="medium"),
                "Statut": st.column_config.TextColumn(width="medium"),
            },
        )
        choisies = edite[edite["Importer"]].to_dict("records")
        if not regles_ok:
            st.caption("Pour que l'app retienne tes corrections d'un import à l'autre, exécute la dernière version "
                       "de `schema.sql` dans Supabase.")
        if st.button(f"Importer {len(choisies)} opération{'s' if len(choisies) > 1 else ''}", type="primary",
                     icon=":material/download_done:", disabled=not choisies, key=f"import_valider_{n}"):
            mauvais = [r for r in choisies if (SOUS_CATEGORIES[r["Catégorie"]][0] == CAT_REVENU) != (r["Montant (€)"] > 0)]
            if mauvais:
                st.error(f"{len(mauvais)} ligne(s) ont une catégorie de revenu pour une sortie d'argent (ou l'inverse), "
                         f"par exemple « {mauvais[0]['Libellé banque']} ». Corrige-les avant d'importer.")
                return
            lignes_db = [{"sous_categorie": r["Catégorie"], "montant": abs(r["Montant (€)"]), "jour": r["Date"],
                          "description": str(r["Note"] or "")} for r in choisies]
            if not executer(ajouter_operations, profil["id"], lignes_db,
                            succes=f"{len(lignes_db)} opérations importées"):
                return
            corrections = {r["_cle"]: [r["Catégorie"], str(r["Note"] or "")] for r in choisies
                           if (r["Catégorie"], str(r["Note"] or "")) != (r["_sc"], r["_note"])}
            if corrections and regles_ok:
                regles.update(corrections)
                try:
                    modifier_profil(profil["id"], regles_import=dict(list(regles.items())[-2000:]))
                except Exception:  # noqa: BLE001 — l'import est fait ; seules les corrections ne sont pas retenues
                    pass
            st.session_state["import_n"] = n + 1  # nouveau sélecteur de fichier, vide
            st.rerun()


def onglet_operations(df: pd.DataFrame, profil: pd.Series) -> None:
    if df.empty:
        st.caption("Aucune opération pour l'instant.")
        if st.button("Importer un relevé bancaire (CSV)", icon=":material/upload_file:", key="import_ouvrir_vide"):
            dialogue_import_releve(df, profil)
        return

    tete = st.container(key="tete_activite")
    # Plusieurs comptes : on choisit celui dont on veut voir les mouvements (avec son solde du jour)
    comptes, compte = comptes_de(df), None
    if len(comptes) > 1:
        comp, jour = compenser(df), aujourdhui()
        soldes = {c: solde_jusqua(comp, jour, c) for c in comptes}
        if st.session_state.get("histo_compte", "Tous") not in ["Tous", *comptes]:
            st.session_state["histo_compte"] = "Tous"
        st.session_state.setdefault("histo_compte", "Tous")
        with tete:
            choix = st.selectbox("Compte", ["Tous", *comptes], key="histo_compte", label_visibility="collapsed",
                                 format_func=lambda c: "🏦 Tous les comptes" if c == "Tous"
                                 else f"🏦 {nom_compte(c)} · {fmt_eur(soldes[c])}", filter_mode=None)
        compte = None if choix == "Tous" else choix

    with tete, st.container(horizontal=True, vertical_alignment="center", gap="small", key="filtres_ops"):
        recherche = st.text_input("Rechercher", key="histo_recherche", placeholder="Rechercher un marchand, une note…",
                                  label_visibility="collapsed", icon=":material/search:")
        actifs = sum(bool(st.session_state.get(k)) and st.session_state.get(k) not in ("Tous", "Tout")
                     for k in ("histo_mois", "histo_type", "histo_themes"))
        with st.popover(f"Filtres · {actifs}" if actifs else "Filtres", icon=":material/tune:"):
            mois_options = ["Tous", *sorted(set(df["mois"]), reverse=True)]
            mois = st.selectbox("Mois", mois_options, key="histo_mois",
                                format_func=lambda m: "Tous les mois" if m == "Tous" else libelle_mois(m), filter_mode=None)
            filtre = st.selectbox("Type", ["Tout", "Revenus", "Besoins", "Envies", "Épargne", "Virements"],
                                  key="histo_type", filter_mode=None)
            themes = st.multiselect("Catégories", sorted(set(df["sous_categorie"])), key="histo_themes",
                                    placeholder="Toutes")
        if st.button("", icon=":material/upload_file:", help="Importer un relevé bancaire (CSV)", key="import_ouvrir"):
            dialogue_import_releve(df, profil)

    vue = df if compte is None else df[touche_compte(df, compte)]
    vue = vue if mois == "Tous" else vue[vue["mois"] == mois]
    if filtre != "Tout":
        vue = vue[[type_affiche(c, sc) == filtre for c, sc in zip(vue["categorie"], vue["sous_categorie"])]]
    if themes:
        vue = vue[vue["sous_categorie"].isin(themes)]
    if recherche.strip():
        motif = re.escape(recherche.strip())
        vue = vue[vue["description"].str.contains(motif, case=False, na=False)
                  | vue["sous_categorie"].str.contains(motif, case=False, na=False)]
    vue = vue.reset_index(drop=True)

    if vue.empty:
        st.caption("Aucune opération pour ces filtres.")
        return

    # Les virements entre le compte et les livrets ne sont ni des revenus ni des dépenses : épargne nette à part ;
    # ceux entre deux de mes comptes ne comptent nulle part, sauf dans le solde des deux comptes
    b = bilan(vue)
    if compte is not None:
        effet = montant_signe(vue, compte)
        st.html(html_tuiles([
            (nom_compte(compte), montant_html(soldes[compte]), f"solde au {jour:%d/%m/%Y}",
             "neg" if soldes[compte] < -0.005 else "", True),
            ("Entrées", montant_html(float(effet[effet > 0].sum())), "revenus et virements reçus", "pos", False),
            ("Sorties", montant_html(float(-effet[effet < 0].sum())), "dépenses, épargne, virements envoyés", "", False),
            ("Dépenses", montant_html(b["depenses"]), "payées depuis ce compte", "", False),
        ]))
    else:
        internes = vue[vue["sous_categorie"].isin(MOUVEMENTS_EPARGNE)]
        virements = int((vue["categorie"] == CAT_VIREMENT).sum())
        st.html(html_tuiles([
            ("Opérations", f"{len(vue):,}".replace(",", " "), "correspondant aux filtres"
             + (f" · dont {virements} virement{'s' if virements > 1 else ''} entre mes comptes" if virements else "")),
            ("Revenus", montant_html(b[CAT_REVENU]), "hors retraits de livret et virements", "pos", False),
            ("Dépenses", montant_html(b["depenses"]), "besoins + envies, tous comptes", "", False),
            ("Épargne nette", montant_html(b[CAT_EPARGNE]), f"{len(internes)} virement(s) avec l'épargne",
             "pos" if b[CAT_EPARGNE] >= 0 else "neg", False),
        ]))

    if est_mobile():
        liste_operations_mobile(vue, profil, compte)
        return

    st.caption("Coche la case au début d'une ou plusieurs lignes pour les modifier ou les supprimer.")
    evenement = tableau_operations(vue, cle="histo_table", compte=compte)
    lignes = [i for i in (evenement.selection.rows if evenement else []) if i < len(vue)]
    with st.container(horizontal=True, vertical_alignment="center"):
        if len(lignes) == 1 and st.button("Modifier", icon=":material/edit:"):
            dialogue_modifier(vue.iloc[lignes[0]], profil["id"])
        if lignes and st.button(f"Supprimer ({len(lignes)})", icon=":material/delete:", key="suppr_selection"):
            dialogue_supprimer_plusieurs(vue.iloc[lignes], profil["id"])
        export = (vue.drop(columns=["mois", "profil_id", "id"])
                  .to_csv(index=False, sep=";", decimal=",").encode("utf-8-sig"))
        st.download_button("Exporter CSV", export, file_name="mes_operations.csv", mime="text/csv",
                           icon=":material/download:")


# --- Le cercle (amis) -------------------------------------------------------------------------

def html_cartes_amis(visibles: pd.DataFrame, df_periode: pd.DataFrame) -> str:
    """Une carte par membre visible : reste de la période, dépenses, épargne."""
    cartes = []
    for _, ami in visibles.iterrows():
        b = bilan(df_periode[df_periode["profil_id"] == ami["id"]])
        taux = b[CAT_EPARGNE] / b["reference"] * 100 if b["reference"] else 0.0
        mode = "Complet" if ami["visibilite"] == "tout" else "Résumé"
        cartes.append(f"""
        <div class="ami">
          <div class="nom">{escape(ami['prenom'])}<small>{mode}</small></div>
          <div class="kpi" style="padding-top:8px">
            <div class="lbl">Reste sur la période</div>
            <div class="val {'pos' if b['reste'] >= 0 else 'neg'}">{montant_html(b['reste'])}</div>
            <div class="sub">dépensé {fmt_eur(b['depenses'])} · mis de côté {fmt_eur(b[CAT_EPARGNE])}</div>
          </div>
          {html_barre("Part du salaire et des aides épargnée", taux, 100.0, SERIE["Épargne"], fmt_pct(taux), repere=20.0)}
        </div>""")
    return f"<div class='amis'>{''.join(cartes)}</div>"


def onglet_cercle(profils: pd.DataFrame, profil: pd.Series) -> None:
    autres = profils[profils["id"] != profil["id"]]
    visibles = autres[autres["visibilite"] != "prive"]
    nb_prives = len(autres) - len(visibles)

    st.html("<div class='precision'>Les budgets que tes amis ont choisi de partager.</div>")
    if profil["visibilite"] == "prive":
        st.caption("Ton profil est privé : les membres ne voient pas ton budget (modifiable dans « Mon espace »).")
    if visibles.empty:
        st.caption("Aucun membre n'a encore rendu son budget visible."
                   + (f" {nb_prives} profil(s) privé(s)." if nb_prives else ""))
        return

    df = charger_operations(tuple(visibles["id"]))
    with st.container(key="tete_cercle"):
        # Pas de mode « paie » ici : chaque ami a ses propres dates de salaire
        periode = choisir_periode(df, "amis", avec_paie=False)

    st.html(html_cartes_amis(visibles, periode.filtrer(df)))
    if nb_prives:
        st.caption(f"{nb_prives} profil(s) privé(s) non affiché(s).")

    prenom = st.pills("Voir le tableau de bord de", visibles["prenom"].tolist(), key="amis_choix")
    if not prenom:
        return
    ami = visibles[visibles["prenom"] == prenom].iloc[0]
    df_ami = df[df["profil_id"] == ami["id"]]
    vue = choisir_vue_resume("ami_vue", je=False)
    afficher_tableau_de_bord(df_ami, periode, ami, prenom=ami["prenom"],
                             avec_detail=ami["visibilite"] == "tout", prefixe="ami", vue=vue)


# =====================================================================
# 9. POINT D'ENTRÉE
# =====================================================================

def salutation() -> str:
    heure = datetime.now(FUSEAU).hour
    return "Bonsoir" if heure >= 18 or heure < 5 else "Bonjour"


def entete_connecte(profil: pd.Series, actif: str) -> None:
    """En-tête fixe : le titre de l'écran et l'avatar (menu du profil)."""
    titre = TITRES_ONGLETS[ONGLETS.index(actif)]
    with st.container(horizontal=True, vertical_alignment="center", horizontal_alignment="distribute", key="entete"):
        st.html(f"<div class='entete-titre'><div class='salut-ecran'>{salutation()}, {escape(profil['prenom'])}</div>"
                f"<div class='titre-ecran'>{escape(titre)}</div></div>", width="content")
        menu_profil(profil)


def interface_connectee(profils: pd.DataFrame, profil: pd.Series) -> None:
    """Tout ce qui s'affiche une fois le membre identifié (séparé de main() pour les tests locaux).

    Comportement d'application : l'en-tête et la barre d'onglets restent fixes, la page ne défile jamais ;
    seul le contenu de l'écran défile, à l'intérieur de son cadre.
    """
    try:
        mes_operations = charger_operations((profil["id"],))
    except Exception as exc:  # noqa: BLE001
        stopper_sur_erreur(exc)

    # Sur téléphone on ouvre directement la saisie, sur ordinateur le résumé
    st.session_state.setdefault("onglet", ONGLETS[2] if est_mobile() else ONGLETS[0])
    if st.session_state["onglet"] not in ONGLETS:
        st.session_state["onglet"] = ONGLETS[0]
    actif = st.session_state["onglet"]
    entete_connecte(profil, actif)
    afficher_notification()
    with st.container(key="nav"):
        onglets = st.tabs(ONGLETS, key="onglet", on_change="rerun")

    # Seul l'onglet affiché est calculé : l'hébergement gratuit a très peu de puissance,
    # et recalculer les 5 onglets à chaque toucher rendait l'app lente (page grisée).
    # Changer d'onglet relance l'affichage (on_change="rerun"), le nouvel onglet est alors calculé.
    rendus = [
        lambda: onglet_resume(mes_operations, profil),
        lambda: onglet_analyses(mes_operations, profil),
        lambda: onglet_ajouter(profil),
        lambda: onglet_operations(mes_operations, profil),
        lambda: onglet_cercle(profils, profil),
    ]
    for nom, cle, onglet, rendu in zip(ONGLETS, CLES_ECRANS, onglets, rendus):
        with onglet:
            if actif != nom:
                continue
            with st.container(key=f"ecran_{cle}"):
                try:
                    rendu()
                except st.errors.StreamlitAPIException:
                    raise  # bug d'affichage : ne pas le masquer derrière un faux message réseau
                except (APIError, ErreurBaseDeDonnees, ConnectionError) as exc:
                    st.error(message_erreur_db(exc))


def main() -> None:
    injecter_css()
    restaurer_session()
    synchroniser_cookie()
    if not ecran_mot_de_passe_commun():
        st.stop()

    try:
        profils = charger_profils()
    except Exception as exc:  # noqa: BLE001
        stopper_sur_erreur(exc)

    profil_id = st.session_state.get("profil_id")
    profil_ligne = profils[profils["id"] == profil_id] if profil_id else profils.iloc[0:0]
    if profil_ligne.empty:
        st.session_state.pop("profil_id", None)  # profil inexistant ou supprimé
        ecran_choix_profil(profils)
        st.stop()
    interface_connectee(profils, profil_ligne.iloc[0])


if __name__ == "__main__":
    main()
