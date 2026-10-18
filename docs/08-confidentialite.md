# Confidentialité et flux de données

## 1. Flux

| Donnée | Où | Durée | Sortie de l'appareil |
|--------|-----|-------|----------------------|
| Photos (pixels) | Photothèque iOS ; chargées en mémoire à la taille de l'écran | Le temps de l'affichage (cache mémoire PhotoKit borné aux photos affichées et préchargées) | Jamais par l'app |
| Index technique (identifiant local, dates, dimensions, sous-types, favori, empreinte de modification) | `Application Support/PhotoSwipe/PhotoSwipe.sqlite` | Jusqu'à « Effacer les données » ou désinstallation | Non (exclu de la sauvegarde iCloud) |
| Décisions, journal d'annulation, sessions | Même base | Idem | Non |
| Réglages | `UserDefaults` | Idem | Sauvegarde iOS standard des préférences |
| Images iCloud | Téléchargées **par Photos** si autorisé | Gérées par Photos | Requête réseau d'Apple, pas de l'app |
| Journaux | `os.Logger`, sans identifiant de photo, nom de fichier, texte reconnu ni image | Politique système | Uniquement si l'utilisateur partage un diagnostic système |

À venir : empreintes SHA-256 des ressources (D), résultats d'analyse et scores internes (E) — mêmes règles de stockage local. Le texte éventuellement reconnu par Vision ne sera ni stocké ni journalisé.

Protection du fichier de base : `completeUntilFirstUserAuthentication` (permet une reprise de l'indexation en arrière-plan après le premier déverrouillage).

## 2. Déclarations pour la distribution

- **App Privacy (App Store Connect)** : « Données non collectées » (aucune donnée ne quitte l'appareil vers le développeur ou un tiers).
- **Manifeste de confidentialité** (`PhotoSwipe/Resources/PrivacyInfo.xcprivacy`) : pas de suivi, aucun domaine de suivi, aucun type de données collecté ; API à justification déclarée : `UserDefaults` (raison `CA92.1`, accès aux préférences de l'app). À compléter si d'autres API concernées sont utilisées (par exemple espace disque ou horodatages de fichiers).
- **Chiffrement** : `ITSAppUsesNonExemptEncryption = false` (aucun chiffrement propriétaire ; le hachage SHA-256 prévu n'est pas du chiffrement).
- **Texte d'autorisation Photos** : explique l'affichage, la suppression uniquement après confirmation et le traitement local.

## 3. Effacement

« Effacer les données de l'application » :
1. arrête l'indexation ;
2. vide toutes les tables, compacte le fichier (`VACUUM`) et tronque le journal WAL ;
3. vide les caches d'images ;
4. efface les réglages et revient à l'écran de bienvenue.

Aucune photo de la photothèque n'est modifiée ou supprimée par cette action.

## 4. Analyse locale des photos (réglage facultatif)

Quand l'utilisateur active « Reconnaître mes photos », chaque photo est lue en version réduite par les API Vision du système, sur l'appareil. Sont enregistrés dans la base locale : des étiquettes de contenu avec leur confiance, un indicateur « utilitaire », un score d'esthétique, la part de surface couverte par du texte et le nombre de caractères reconnus. **Le texte reconnu, les images et leurs miniatures ne sont jamais conservés ni journalisés.** Aucun réseau n'est utilisé (une photo uniquement présente dans iCloud est ignorée). « Effacer les données de l'application » supprime ces résultats et les catégories créées par l'utilisateur ; désactiver l'analyse l'arrête sans effacer les résultats.
