# Installer Le Cercle sur ton iPhone, sans Mac

Principe : GitHub fabrique l'app sur un de ses Mac (fichier `Cercle.ipa`), puis Sideloadly, sur ton PC Windows,
la signe avec ton Apple ID gratuit et l'installe sur ton iPhone branché en USB.

Cette première version ne contient que la structure : barre d'onglets en verre, fond qui dérive, feuille de saisie.
Elle sert à vérifier que toute la chaîne fonctionne avant d'y mettre les vrais écrans.

## Partie 1. Mettre le projet sur GitHub (une seule fois)

1. Crée un compte sur github.com si tu n'en as pas.
2. Clique sur **+** en haut à droite, puis **New repository**.
3. Nom : `le-cercle-ios`. Coche **Public** ou **Private** :
   - Public : fabrications illimitées et gratuites. Le code est visible, mais il ne contient ni donnée ni clé.
   - Private : environ 15 à 20 fabrications par mois (les minutes de Mac comptent 10 fois sur le quota gratuit).
4. Ne coche rien d'autre, puis clique **Create repository**. Garde la page ouverte : elle affiche l'adresse du dépôt.
5. Envoie le contenu du dossier `app_ios` dans ce dépôt. Le plus simple : dis-le à Claude, en lui donnant l'adresse du
   dépôt ; il prépare et envoie les fichiers avec ton accord (une fenêtre GitHub te demandera de te connecter).

## Partie 2. Fabriquer l'app (à chaque nouvelle version)

6. Sur la page du dépôt, onglet **Actions**. La fabrication démarre toute seule après chaque envoi
   (sinon : **Fabriquer l'app (.ipa)**, puis **Run workflow**).
7. Attends la coche verte (environ 5 à 10 minutes).
8. Clique sur la fabrication, puis, en bas, dans **Artifacts**, sur **Cercle-ipa** : un fichier zip se télécharge.
9. Ouvre le zip : il contient `Cercle.ipa`.

## Partie 3. Préparer Windows (une seule fois)

10. Installe **iTunes** et **iCloud** depuis le site d'Apple (apple.com/fr/itunes et la page iCloud pour Windows),
    pas depuis le Microsoft Store : Sideloadly a besoin de ces versions.
11. Installe **Sideloadly** depuis son site officiel, sideloadly.io.

## Partie 4. Installer sur l'iPhone

12. Branche l'iPhone au PC en USB, déverrouille-le, et touche **Se fier à cet ordinateur**.
13. Ouvre Sideloadly. Ton iPhone apparaît en haut.
14. Glisse `Cercle.ipa` dans la fenêtre de Sideloadly.
15. Tape ton adresse Apple ID dans le champ prévu, puis clique **Start**.
16. Sideloadly te demande ton mot de passe Apple, puis le code de double authentification : tape-les dans Sideloadly.
    Ne les donne jamais à personne, Claude compris.
17. Sur l'iPhone, la première fois :
    - **Réglages, Confidentialité et sécurité, Mode développeur** : active-le, puis laisse l'iPhone redémarrer ;
    - **Réglages, Général, VPN et gestion de l'appareil** : touche ton Apple ID, puis **Faire confiance**.
18. Ouvre Le Cercle.

## À savoir

- **L'app expire au bout de 7 jours** avec un Apple ID gratuit : refais les étapes 12 à 16, sans rien perdre.
- Une nouvelle version s'installe de la même façon : étapes 6 à 9, puis 12 à 16.
- Si Sideloadly affiche une erreur, copie le message et envoie-le à Claude.

## Ce que je n'ai pas pu vérifier d'ici

Je n'ai ni Mac ni Xcode : le code n'a pas encore été compilé. La première fabrication sur GitHub sera le vrai test.
Si elle échoue, envoie-moi le message d'erreur affiché dans l'onglet Actions : je corrige.

À regarder sur ton iPhone :
- le « + » rond, séparé de la barre d'onglets ;
- le verre liquide des cartes ;
- le grand titre qui se réduit quand tu fais défiler ;
- la barre qui se fait plus discrète quand tu descends ;
- le fond qui bouge très lentement.
