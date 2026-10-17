# Architecture et décisions

## 1. Vue d'ensemble

```
┌────────────────────────── App iOS (PhotoSwipe/) ──────────────────────────┐
│ SwiftUI : Onboarding · Accueil · Mois · Tri · Bilan · Réglages            │
│ AppEnvironment (composition) · AppSettings (UserDefaults)                 │
│ PhotoKitLibraryService (PhotoKit) · PhotoKitImageProvider (images, cache) │
└───────────────┬───────────────────────────────────────────────────────────┘
                │ protocoles (PhotoLibraryService, AssetImageProviding)
┌───────────────▼──────────── Packages/PhotoSwipeKit ───────────────────────┐
│ PhotoSwipeFeatures : SortingSessionModel · SessionLauncher                 │
│                      LibrarySyncCoordinator · LibraryOverviewModel         │
│                      InMemoryPhotoLibrary (tests, démonstration)           │
│ PhotoSwipeStore    : PhotoSwipeStore (acteur SQLite, migrations)           │
│ PhotoSwipeCore     : types de domaine, règles (périmètres, réconciliation) │
└────────────────────────────────────────────────────────────────────────────┘
```

| Composant demandé | Emplacement | État |
|-------------------|-------------|------|
| Accès à la photothèque | `PhotoSwipe/Library/PhotoKitLibraryService.swift` | B |
| Chargement et cache des images | `PhotoSwipe/Imaging/` | B |
| Moteur de sessions de tri | `PhotoSwipeFeatures/SortingSessionModel.swift` | B |
| Persistance | `PhotoSwipeStore/` | B |
| Orchestration de l'indexation | `PhotoSwipeFeatures/LibrarySyncCoordinator.swift` | B (analyse : E) |
| Suppression et réconciliation | `PhotoSwipeCore/ReconciliationPlanner.swift` | Réconciliation B, suppression C |
| Détection des doublons | — | D |
| Classification, analyse de qualité | — | E |
| Interface utilisateur | `PhotoSwipe/Features/` | B |

## 2. Décisions (ADR)

### ADR-001 — Application native, iOS 18 minimum
**Décision** : Swift, SwiftUI, PhotoKit, Swift Concurrency, Observation. Cible minimale **iOS 18.0**, iPhone uniquement.
**Raisons** : l'objectif matériel iPhone 12/13+ est couvert par iOS 18 (et iOS 26) ; iOS 18 apporte les API Vision en Swift dont `CalculateImageAestheticsScoresRequest` (score esthétique, indicateur « utility »), utiles à l'incrément E, ainsi que `Mutex` (Synchronization) et `onGeometryChange`.
**Compromis** : exclut les appareils restés sous iOS 17. Compatibilité matérielle ≠ disponibilité des API : les deux sont à confirmer par des tests sur appareil.
**Outils** : Xcode 16 minimum pour ouvrir le projet (format à dossiers synchronisés) ; la publication App Store exige le SDK imposé par Apple au moment de l'envoi (Xcode 26 au moment de la rédaction — à revérifier).

### ADR-002 — Persistance : SQLite système plutôt que SwiftData / Core Data
**Décision** : bibliothèque SQLite fournie par le système (`import SQLite3`), enveloppe minimale (~250 lignes), acteur `PhotoSwipeStore`, mode WAL, migrations versionnées par `PRAGMA user_version`.
**Raisons** :
1. Volumétrie : 10 000 à 100 000 lignes, écritures fréquentes pendant l'indexation ; requêtes de piles par pagination « keyset » et agrégats par mois maîtrisés et indexés.
2. Durabilité : chaque décision est validée dans sa propre transaction ; elle survit à une fermeture forcée.
3. Testabilité : le même code compile sous Linux, ce qui permet d'exécuter les tests de persistance hors Xcode (CI, cet environnement).
4. Aucune dépendance externe.
**Compromis** : SQL écrit à la main, mappage manuel. Réversible : l'accès passe par l'acteur et des types de domaine ; un remplacement par SwiftData ne toucherait pas l'interface.

### ADR-003 — Paquet local `PhotoSwipeKit`, testable hors Xcode
**Décision** : toute la logique sans UIKit/PhotoKit (domaine, persistance, moteur de session, synchronisation) vit dans un paquet Swift local en **mode de langage Swift 6** (concurrence vérifiée). Tests en Swift Testing.
**Raisons** : vitesse des tests, isolement, exécution sous Linux (Docker `swift:6.2`), interfaces remplaçables (`PhotoLibraryService`, classifieur à venir).

### ADR-004 — Index local miroir et piles calculées par requêtes
**Décision** : un index minimal de la photothèque (identifiant local, dates, dimensions, sous-types, favori, empreinte de modification, visibilité) est tenu en base. Les piles de tri sont des requêtes paginées sur cet index, triées par date décroissante puis identifiant.
**Raisons** : piles par mois, par état, et bientôt par catégorie, sans charger la photothèque en mémoire ; reprise exacte via un curseur persistant.
**Indexation** : énumération PhotoKit par lots de 400, des plus récentes aux plus anciennes ; le tri commence dès le premier lot. Une passe interrompue ne modifie rien d'autre que les lignes déjà vues.

### ADR-005 — Décisions optimistes, persistance en file sérielle
**Décision** : l'interface passe à la photo suivante immédiatement ; l'écriture suit dans une file sérielle. Les rechargements de pile passent par la même file et excluent les photos dont l'écriture est en attente.
**Raisons** : fluidité du swipe ; impossibilité de présenter deux fois une photo ; annulation toujours appliquée après l'écriture qu'elle annule. En cas d'échec d'écriture, la photo revient à l'écran avec un message.

### ADR-006 — Réconciliation prudente
**Décision** :
- accès complet : une photo absente de l'énumération n'est purgée que si PhotoKit ne la retrouve plus par identifiant (photos masquées incluses) ;
- accès limité : une photo absente est seulement marquée inaccessible (décision conservée) ;
- autorisation modifiée pendant une passe : aucune réconciliation, nouvelle passe ;
- purge massive suspecte (≥ 200 photos et ≥ 50 % de l'index) : suspendue, photos marquées inaccessibles, message affiché.
**Raison** : « un changement de permission ne doit pas être interprété comme une suppression ».

### ADR-007 — Images : résolution adaptée, préchargement borné, iCloud explicite
**Décision** : `PHCachingImageManager`, taille demandée = zone d'affichage × échelle de l'écran (plafond 4096 px, version plus détaillée seulement au-delà de 1,5× de zoom) ; préchargement des 3 photos suivantes ; téléchargement iCloud pour l'affichage autorisé par défaut, désactivable, avec progression visible et bouton « Télécharger » ponctuel. Aucune copie complète n'est écrite sur disque.
**À mesurer** : mémoire maximale et temps d'affichage sur iPhone 12.

### ADR-008 — Cible app en Swift 5 + vérification de concurrence « complete »
**Décision** : le paquet est en Swift 6 (vérifié ici). La cible app, non compilable dans cet environnement, est en Swift 5 avec `SWIFT_STRICT_CONCURRENCY = complete` : les éventuels problèmes de concurrence liés aux annotations PhotoKit apparaissent en avertissements, pas en erreurs bloquantes.
**Constat** : première compilation CI (Xcode 26.3) sans aucun avertissement avec cette vérification. **Suite** : passer la cible en Swift 6 (backlog F-03).

### ADR-009 — Projet Xcode à dossiers synchronisés, signature hors dépôt
**Décision** : `project.pbxproj` au format Xcode 16 (`PBXFileSystemSynchronizedRootGroup`) : tout fichier ajouté sous `PhotoSwipe/` est compilé ou embarqué sans modifier le projet. Équipe et identifiant de bundle viennent de `Config/Local.xcconfig` (ignoré par git) via `Config/Shared.xcconfig`.

### ADR-010 — Aucune dépendance externe
Ni SDK d'analyse, ni bibliothèque réseau, ni ORM. Les seules dépendances sont des frameworks Apple.

### ADR-011 — Classifieur remplaçable et facultatif
Le tri manuel ne dépend d'aucune analyse. Le classifieur sera derrière un protocole, désactivable, versionné (modèle + taxonomie) ; les scores internes ne seront jamais présentés comme des probabilités. Le choix du modèle est conditionné à la licence (voir [classification locale](07-classification-locale.md)).

### ADR-012 — Aucune télémétrie, journaux sans données personnelles
`os.Logger` uniquement, sans identifiant de photo, nom de fichier, texte reconnu ni image. Aucune collecte (manifeste de confidentialité : aucune donnée collectée).

### ADR-013 — Pas d'API privée pour la taille des fichiers
La lecture de `fileSize` par KVC sur `PHAssetResource` n'est pas documentée : elle n'est pas utilisée. Le volume est mesuré en lisant les ressources locales (`PHAssetResourceManager`), ce que la détection de doublons fait de toute façon. Tant qu'il n'est pas mesuré, il n'est pas affiché.

## 3. Concurrence

| Élément | Isolation |
|---------|-----------|
| Modèles d'interface (`SortingSessionModel`, `LibrarySyncCoordinator`, `LibraryOverviewModel`, `AppEnvironment`) | `@MainActor` |
| Base (`PhotoSwipeStore`) | acteur dédié (hors fil principal) |
| Énumération PhotoKit | `Task.detached(priority: .utility)` |
| Chargement d'images | callbacks PhotoKit → `AsyncStream` consommé sur le fil principal |
| Observateur de changements PhotoKit | verrou interne, notification → `AsyncStream` avec anti-rebond de 800 ms |

## 4. Évolutions prévues sans surconception

- **C** : `deleteAssets` sera ajouté au protocole de photothèque ; la suppression ne sera appelable que depuis l'écran de sélection après confirmation.
- **D** : table `resource_digests` (migration v2), énumération des ressources par `PHAssetResource`.
- **E** : table `analyses` (migration v3) avec états d'analyse séparés des décisions ; `ScanCoordinator` avec pause, reprise, adaptation à l'état thermique et au mode économie d'énergie.
