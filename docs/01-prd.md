# PRD — PhotoSwipe (nom de travail)

> « Trie facilement tes photos, retrouve ce qui t'encombre et garde le contrôle sur tes souvenirs. »

Le nom « PhotoSwipe » est provisoire ; sa disponibilité commerciale (App Store, marques) n'a pas été vérifiée.

## 1. Problème

Une photothèque de plusieurs milliers de photos accumule des contenus utilitaires (captures d'écran, reçus, tableaux de cours, étiquettes) mêlés aux souvenirs. L'app Photos permet de supprimer, mais pas de **parcourir vite, décider sans risque et reprendre plus tard**. Deux freins dominent : la peur de supprimer par erreur et la méfiance envers les services qui envoient les photos sur un serveur.

## 2. Cible

- **Principale** : une personne avec plusieurs milliers de photos, qui trie par sessions courtes (quelques minutes), sur iPhone 12 ou plus récent.
- **Secondaires** : étudiants (photos de tableaux et de diapositives), personnes qui photographient reçus, étiquettes et horaires « pour plus tard ».

Besoins prioritaires : faire du ménage sans effort, éviter les suppressions accidentelles, repérer vite l'utilitaire encombrant, reprendre exactement là où l'on s'est arrêté, comprendre pourquoi une photo est proposée, préserver la confidentialité.

## 3. Principes non négociables (rappel)

| # | Principe | Traduction dans le produit |
|---|----------|----------------------------|
| 1 | Aucune photo envoyée à un serveur pour analyse | Aucun appel réseau applicatif ; seule la récupération iCloud par Photos peut utiliser Internet |
| 2–3 | Ni compte ni API payante | Aucune dépendance réseau |
| 4–5 | Un swipe ne supprime jamais ; suppression = validation explicite + flux système | Décision « À supprimer » = sélection en attente ; suppression via la confirmation iOS (incrément C) |
| 6 | L'IA suggère, ne décide pas | Les catégories ne font que regrouper des photos dans des piles |
| 7 | Pas de faux « doublon exact » | Définition binaire stricte, sans similarité visuelle ([spécification](06-doublons-exacts.md)) |
| 8–9 | Persistance ; les conservées ne reviennent pas | Base locale transactionnelle ; revue des conservées uniquement sur demande |
| 10–11 | Échecs d'analyse et absence de modèle n'empêchent pas le tri | Tri manuel indépendant de toute analyse |
| 12 | Aucune promesse non mesurée | Pas de chiffre de précision, de vitesse ni de gain d'espace sans mesure |

## 4. Périmètre

**V1** : accès à la photothèque (complet, limité, refusé, restreint, changements) ; tri par swipe et boutons ; navigation par mois ; conserver / à supprimer / passer / annuler ; sélection à supprimer consultable avant confirmation ; reprise de progression ; captures d'écran (métadonnées) ; doublons exacts ; prétri local par catégories ; suivi et reprise du scan ; réglages de confidentialité, d'analyse et de réinitialisation.

**Hors V1** : Android et bureau ; comptes, partage, synchronisation propriétaire ; reconnaissance des personnes ; retouche ; suppression automatique ; photos simplement similaires ; vidéos ; monétisation ; apprentissage automatique à partir des swipes.

## 5. Critères de succès

Le succès ne se mesure pas au nombre de suppressions. Sans télémétrie externe, les mesures viennent de tests instrumentés et des retours TestFlight (questionnaire, entretiens).

| Dimension | Indicateur | Cible / méthode |
|-----------|-----------|-----------------|
| Fiabilité | Décisions perdues après fermeture forcée | 0 (tests automatisés + test manuel sur appareil) |
| Sécurité | Suppressions sans validation explicite | 0 (garantie structurelle + tests) |
| Fluidité | Délai entre la fin d'un swipe et l'affichage de la photo suivante | À mesurer sur iPhone 12 (Instruments) avant de fixer une cible |
| Confiance | Testeurs qui comprennent que le swipe ne supprime pas | Questionnaire TestFlight |
| Temps gagné | Photos examinées par minute de session | Compteur local affiché, non transmis |
| Utilité du prétri | Part des photos d'une catégorie réellement jugées utilitaires | Évaluation hors ligne (incrément E) |

## 6. Décisions produit déjà prises (réversibles)

- iPhone uniquement, orientation portrait.
- Ordre de présentation : des plus récentes aux plus anciennes.
- « Passer » = **reportée** : la photo n'est plus proposée dans la session en cours et revient lors d'une session ultérieure, après les photos jamais examinées.
- Une seule session active : en démarrer une autre (par exemple un mois) clôt la précédente sans perdre aucune décision.
- Les photos conservées ne reviennent que via « Revoir les photos conservées ».
- Le volume libéré n'est affiché que lorsqu'il a été mesuré (pas d'API privée de taille de fichier).

## 7. Risques principaux

| Risque | Impact | Mitigation |
|--------|--------|-----------|
| Licence des poids MobileCLIP2 réservée à la recherche | Bloque l'usage dans une app distribuée | Évaluer d'abord des alternatives à licence compatible ([classification](07-classification-locale.md)) |
| Photothèques de 50 000+ photos | Indexation longue, mémoire | Index incrémental par lots, tri possible dès le premier lot, mesures sur appareil |
| Originaux uniquement dans iCloud | Affichage lent, doublons non vérifiables | Téléchargement explicite et visible, statut « non vérifiable » |
| Revue App Store (suppression, accès Photos) | Rejet | Textes clairs, flux système, notes de revue ([checklist](10-checklist-testflight.md)) |
