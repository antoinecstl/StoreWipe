# Rapport de validation — incréments A et B

Date : 17/10/2026. Ce rapport sépare strictement ce qui a été **exécuté et mesuré** de ce qui reste **à tester**.

## 1. Environnement de développement

| Élément | Valeur |
|---------|--------|
| Système | Linux x86_64 (Ubuntu 24.04), conteneur cloud |
| Swift | 6.2.4 (image Docker officielle `swift:6.2-noble`) + `libsqlite3-dev` |
| Xcode, simulateur iOS, appareil | **Indisponibles** |
| Accès réseau | Hugging Face et download.swift.org bloqués par la politique réseau de l'environnement |

Conséquence : le paquet `PhotoSwipeKit` est compilé et testé ; la cible iOS (SwiftUI, PhotoKit, UIKit) **n'a été ni compilée ni exécutée** ici. La CI GitHub Actions (`.github/workflows/ci.yml`) compile l'app pour le simulateur sur macOS ; son résultat est indiqué en §4 lorsqu'il est disponible.

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
| Compilation de la cible iOS | CI macOS ou Xcode local | Bloquant |
| Ouverture du projet dans Xcode (format objectVersion 77, référence de paquet local) | Xcode 16+ | Bloquant |
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

## 4. CI

Résultat de la première exécution : voir la section mise à jour après l'exécution (ou l'onglet Actions du dépôt).
