# Rapport de validation — incréments A et B

Date : 17/10/2026. Ce rapport sépare strictement ce qui a été **exécuté et mesuré** de ce qui reste **à tester**.

## 1. Environnement de développement

| Élément | Valeur |
|---------|--------|
| Système | Linux x86_64 (Ubuntu 24.04), conteneur cloud |
| Swift | 6.2.4 (image Docker officielle `swift:6.2-noble`) + `libsqlite3-dev` |
| Xcode, simulateur iOS, appareil | **Indisponibles** |
| Accès réseau | Hugging Face et download.swift.org bloqués par la politique réseau de l'environnement |

Conséquence : le paquet `PhotoSwipeKit` est compilé et testé ici ; la cible iOS (SwiftUI, PhotoKit, UIKit) est compilée par la CI GitHub Actions sur macOS (§4). **Aucune exécution** de l'app n'a eu lieu, ni sur simulateur ni sur appareil.

## 2. Exécuté et vérifié

| Vérification | Résultat |
|--------------|----------|
| Compilation du paquet en mode de langage Swift 6 (concurrence stricte), `-warnings-as-errors` | ✅ 0 avertissement |
| Tests Swift Testing (`Tools/test-linux.sh`) | ✅ 71 tests, 12 suites, 3 exécutions successives sans échec |
| Syntaxe et références du `project.pbxproj` (analyse par la bibliothèque Python `pbxproj`) | ✅ 26 objets, aucune référence manquante |
| Validité des fichiers JSON du catalogue d'assets, du `Localizable.xcstrings`, des plists et du schéma Xcode | ✅ |
| Icône 1024 × 1024 RVB sans canal alpha | ✅ |
| Contraste texte blanc / couleurs de décision (WCAG) | ✅ Conserver 5,4:1 ; À supprimer 5,9:1 ; accent 7,9:1 (clair) et 5,4:1 (sombre) |
| `AppSettings` (Observation + `didSet`) compilé et exécuté sous Linux en Swift 5 / concurrence complète | ✅ |
| Tests du paquet sous macOS (module `SQLite3` d'Apple) — CI | ✅ |
| Compilation de l'app iOS, simulateur, Debug (arm64) et Release — CI, Xcode 26.3 (17C529), SDK iOS Simulator 26.2, `SWIFT_STRICT_CONCURRENCY = complete` | ✅ 0 erreur, 0 avertissement Swift |

### Couverture fonctionnelle des tests

| Critère d'acceptation | Test(s) | Résultat |
|-----------------------|---------|----------|
| Une photo peut être conservée, reportée ou sélectionnée pour suppression | `presentsNewestFirstAndRecordsDecisions` | ✅ |
| L'annulation restaure correctement la décision (état et date) | `undoRestoresDecisionAndShowsPhotoAgain`, `undoRestoresPreviousDecisionAndDate`, `chainedUndoWalksBackHistory`, `undoIsStaleOnceSuperseded`, `undoTwiceIsStale` | ✅ |
| La progression survit à une fermeture forcée | `committedDecisionIsVisibleWithoutCleanShutdown` (seconde connexion sans fermeture de la première), `resumesOnTheSamePhotoAfterRelaunch` | ✅ (simulation ; à confirmer sur appareil) |
| Aucun swipe ne supprime directement une photo | `markingForDeletionNeverRemovesPhotosFromTheLibrary` ; garantie structurelle : le protocole de photothèque n'expose aucune suppression | ✅ |
| Les accès limités et refusés sont correctement gérés (données) | `limitedAccessNeverDeletesDecisions`, `doesNothingWithoutAuthorization`, `authorizationChangeDuringSyncSkipsReconciliation` | ✅ (logique ; écrans à tester) |
| Une modification externe de la photothèque est réconciliée | `deletionInPhotosPurgesLocalDataInFullAccess`, `hiddenPhotoIsNotTreatedAsDeleted`, `changeNotificationsTriggerAResync`, `massivePurgeIsSuspended` | ✅ |
| Le tri manuel fonctionne sans modèle | Aucun code d'analyse dans le parcours ; tous les tests de session | ✅ |
| Actions rapides sans doublon de présentation | `rapidActionsArePersistedInOrderWithoutRepeats` (40 actions) | ✅ |
| Photos passées : exclues de la session, reproposées ensuite | `deferredPhotosReturnInALaterSessionAfterUnreviewedOnes`, `deferredPhaseOrdersByDeferralAndExcludesHandledInSession` | ✅ |
| Nouvelles photos après une pause : proposées après le point de reprise | `newerPhotosAddedAfterPauseComeAfterTheResumePoint` | ✅ |
| Réinitialisation / effacement | `resetDecisionsKeepsIndex`, `eraseAllRemovesEverything` | ✅ |

## 3. Non vérifié — à tester

| Élément | Où | Priorité |
|---------|----|----------|
| Ouverture du projet dans l'interface Xcode (`xcodebuild` le lit correctement) | Xcode 16+ | Haute |
| Compilation avec Xcode 16 (seul Xcode 26.3 a été utilisé) | Xcode 16 | Basse |
| Parcours complet sur simulateur en mode démonstration | Simulateur | Haute |
| Permissions réelles (complet, limité, refusé, restreint, changements dans Réglages) | Appareil | Haute |
| Énumération PhotoKit, notifications de changement, photos masquées, albums partagés exclus | Appareil | Haute |
| Fluidité du swipe pendant l'indexation, latence d'affichage, mémoire maximale | iPhone 12 + Instruments | Haute |
| Durée d'indexation pour 10 000 et 50 000 photos | Appareil | Moyenne |
| Comportement iCloud (progression, refus réseau, bouton « Télécharger ») | Appareil avec Photos iCloud optimisé | Moyenne |
| Zoom : absence de décision accidentelle | Appareil | Haute |
| VoiceOver, Dynamic Type, réduction des animations | Appareil | Moyenne |
| Rafales : effet réel d'une décision sur la photo représentative | Appareil | Moyenne |

Aucun résultat de simulateur ne sera présenté comme une validation matérielle.

## 4. CI (GitHub Actions)

| Run | Commit | Résultat | Détail |
|-----|--------|----------|--------|
| 1 | `f0b6981` | ❌ | Redéclaration de `Color.keepTint` / `Color.deleteTint` : Xcode génère déjà ces symboles depuis le catalogue d'assets. Tests du paquet verts (Linux et macOS). |
| 2 | `cee22ba` | ❌ | `presentLimitedLibraryPicker` introuvable : la méthode est déclarée dans PhotosUI. |
| 3 | `8afd498` | ✅ | Tests Linux, tests macOS, compilation Debug et Release : aucune erreur, aucun avertissement Swift. |

Les deux erreurs étaient des erreurs de compilation détectées avant toute exécution ; aucune ne concernait la logique testée du paquet.
