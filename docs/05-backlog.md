# Backlog priorisé

Légende : ✅ fait et testé (tests du paquet, Linux et macOS) · 🟡 implémenté et compilé par la CI (Xcode 26.3), non exécuté sur simulateur ni sur appareil · ⬜ à faire.

## Incrément A — Cadrage et fondations ✅

| ID | Élément | Critères d'acceptation | Statut |
|----|---------|------------------------|--------|
| A-01 | PRD, parcours, ADR, modèle de données, spécification des doublons | Documents dans `docs/` | ✅ |
| A-02 | Paquet `PhotoSwipeKit` (Core, Store, Features) | Compile en mode Swift 6 sans avertissement ; tests verts | ✅ |
| A-03 | Projet Xcode à dossiers synchronisés, signature via xcconfig local | Compile pour le simulateur en Debug et Release | ✅ CI (Xcode 26.3, 0 avertissement) ; ouverture dans l'interface Xcode à confirmer |
| A-04 | CI : tests Linux du paquet + compilation iOS sur macOS | Workflow GitHub Actions vert | ✅ |

## Incrément B — Tri manuel, persistance, permissions

| ID | Élément | Critères d'acceptation | Statut |
|----|---------|------------------------|--------|
| B-01 | Conserver / à supprimer / passer | Chaque action enregistre la bonne décision ; la photo suivante s'affiche | ✅ logique · 🟡 UI |
| B-02 | Annuler | Rétablit l'état et la date précédents ; fonctionne après redémarrage ; refuse sans effet si la décision a changé ailleurs | ✅ |
| B-03 | Aucun swipe ne supprime | Le moteur de session n'a aucun accès à une API de suppression ; test : toutes les photos « à supprimer » restent dans la photothèque | ✅ |
| B-04 | Reprise exacte après fermeture forcée | Décision validée visible depuis une nouvelle connexion sans fermeture propre ; reprise sur la même photo | ✅ |
| B-05 | Actions rapides | 40 actions sans attente : aucune photo présentée deux fois, toutes persistées dans l'ordre | ✅ |
| B-06 | Photos passées | Exclues de la session courante, reproposées ensuite après les non examinées | ✅ |
| B-07 | Conservées non reproposées ; revue explicite | Revue sur demande ; « Passer » n'y change rien | ✅ |
| B-08 | Tri par mois | Liste des mois avec compteurs ; session limitée au mois | ✅ logique · 🟡 UI |
| B-09 | Permissions complètes / limitées / refusées / restreintes | Écrans dédiés ; aucune donnée effacée sur refus | 🟡 |
| B-10 | Accès limité ≠ suppression | Photo retirée de la sélection : inaccessible, décision conservée, restaurée si de nouveau autorisée | ✅ |
| B-11 | Réconciliation des suppressions externes | Purge uniquement si l'absence est confirmée en accès complet ; photos masquées non purgées ; purge massive suspendue | ✅ |
| B-12 | Indexation incrémentale | Lots de 400, plus récentes d'abord ; tri possible dès le premier lot ; anti-rebond des notifications | ✅ logique · 🟡 PhotoKit |
| B-13 | Images | Taille écran, préchargement de 3 photos, iCloud visible et contrôlé, photo introuvable gérée | 🟡 |
| B-14 | Zoom sans décision accidentelle | Glissement = déplacement quand zoomé ; pincement annule un swipe | 🟡 |
| B-15 | Réglages : réinitialiser, effacer les données | Confirmations ; photos intactes | ✅ logique · 🟡 UI |
| B-16 | Accessibilité de base | Actions VoiceOver, boutons, raccourcis clavier, Dynamic Type, réduction des animations, contraste | 🟡 |
| B-17 | Mode démonstration (DEBUG) | `-PhotoSwipeDemoLibrary YES` : photothèque fictive sur simulateur | 🟡 |

## Incrément C — Sélection et suppression via le système (implémenté, à tester sur iPhone)

| ID | Élément | Critères d'acceptation |
|----|---------|------------------------|
| C-01 | Grille « À supprimer » | Ouvrir chaque photo ; retirer de la sélection (= conserver) ; compteur exact | ✅ logique · 🟡 UI (retrait d'un toucher ; pas encore de vue plein écran) |
| C-02 | Confirmation explicite | Écran récapitulatif + mention iCloud et « Supprimés récemment » avant la demande système | 🟡 |
| C-03 | Suppression PhotoKit | `PHAssetChangeRequest.deleteAssets` ; annulation par l'utilisateur dans l'alerte iOS → aucun compteur modifié, message neutre | ✅ logique · 🟡 PhotoKit |
| C-04 | Résultat réel | Après l'opération, vérification par identifiant ; seuls les assets réellement absents sont comptés et purgés | ✅ |
| C-05 | Changements concurrents | Photos déjà supprimées, devenues inaccessibles ou modifiées depuis la décision : signalées et exclues | 🟡 partiel (la sélection ne liste que les photos accessibles ; pas de signalement des modifiées) |
| C-06 | Volume estimé | Mesuré par lecture des ressources locales ; affiché avec sa couverture (« pour 45 photos sur 50 ») ; jamais promis comme espace libéré immédiatement | ✅ logique · 🟡 UI (clé `fileSize` de PHAssetResource, non documentée par Apple) |
| C-07 | Bilan de session | Bouton « Revoir la sélection » | 🟡 |

## Incrément D — Captures d'écran et doublons exacts

| ID | Élément | Critères d'acceptation |
|----|---------|------------------------|
| D-01 | Pile « Captures d'écran » | Métadonnées uniquement ; disponible immédiatement après indexation | ✅ logique · 🟡 UI |
| D-02 | Migration `resource_digests` (v4) | Migration testée depuis v3 | ✅ |
| D-03 | Doublons exacts | Conforme à la [spécification](06-doublons-exacts.md) ; tests HEIC/JPEG, retouche, Live Photo, iCloud | ✅ logique (migration v4, `DuplicateScanCoordinator`) · 🟡 PhotoKit : doublons exacts par SHA-256 ; doublons probables en complément |
| D-04 | Groupes de doublons | Exemplaire conservé suggéré avec règle visible ; impossible de tout supprimer | 🟡 règle affichée, un exemplaire toujours conservé ; albums d'appartenance non affichés |
| D-05 | Réglage iCloud doublons | Désactivé par défaut ; statut « non vérifiable » | ✅ logique · 🟡 UI |

## Incrément E — Classifieur local

| ID | Élément | Critères d'acceptation |
|----|---------|------------------------|
| E-00 | **Décision licence** | Modèle retenu avec licence compatible vérifiée sur source primaire | ⏸ non nécessaire pour la version Vision (voir [07](07-classification-locale.md#0-version-actuelle-vision-sans-modèle-embarqué)) |
| E-01 | Scripts `Tools/model-prep` | Export reproductible, vecteurs textuels précalculés, comparaison original/converti |
| E-02 | Évaluation | Rapport par catégorie (précision, rappel, confusion, incertains, latence, mémoire, taille) |
| E-03 | Migration `analyses` + coordinateur d'analyse | Pause, reprise, annulation, adaptation thermique et économie d'énergie, points de reprise | ✅ logique (migration v2, `AnalysisCoordinator`) · 🟡 Vision sur appareil |
| E-04 | Piles par catégorie | Raison affichée ; incertain exclu ; tri manuel inchangé sans modèle | 🟡 piles et catégories personnalisées ; raison affichée à faire |
| E-05 | Aucun appel réseau d'inférence | Vérifié (pas de code réseau ; test sur appareil en mode avion) | 🟡 aucun code réseau ; test en mode avion à faire |

## Incrément F — Optimisation, accessibilité, TestFlight

| ID | Élément |
|----|---------|
| F-01 | Mesures sur iPhone 12 : latence de swipe, mémoire, indexation de 10 k / 50 k photos |
| F-02 | Audit VoiceOver, Dynamic Type (AX5), contraste, réduction des animations sur appareil |
| F-03 | Passage de la cible app en mode Swift 6 |
| F-04 | Tests d'interface (XCUITest) en mode démonstration : onboarding, swipe, annulation, reprise |
| F-05 | Localisation anglaise (catalogue de chaînes prêt) |
| F-06 | [Checklist TestFlight / App Store](10-checklist-testflight.md) |
| F-07 | Synchronisation incrémentale via `PHPhotoLibrary.fetchPersistentChanges(since:)` si l'énumération complète s'avère trop coûteuse |

## Ajouts hors plan initial

| Élément | Statut |
|---------|--------|
| Vidéos dans l'index, le tri, la suppression ; réglage « Inclure les vidéos » ; lecture plein écran | ✅ logique · 🟡 PhotoKit et UI |
| Mesure des tailles en arrière-plan (métadonnées, sans lecture) | ✅ logique · 🟡 PhotoKit |
| Écran « Gros fichiers » (type, seuil, sélection groupée) | 🟡 |
| Ordre du tri réglable (par défaut : plus anciennes d'abord) | ✅ logique · 🟡 UI |
| Pile « Vidéos », marquage en lot avec confirmation | 🟡 |
| Raison affichée dans les piles de catégorie (« Proposée car : … ») | 🟡 |
| Publication de l'IPA non signée dans la pré-release `latest` | ✅ CI |
| Pile « Gros fichiers » à swiper (du plus lourd au plus léger), seuil réglable, accueil réorganisé en piles | ✅ logique · 🟡 UI |
