# PhotoSwipe (nom de travail)

Application iPhone de tri de photos : **swipe à droite pour conserver, à gauche pour mettre de côté à supprimer**. Tout est traité sur l'appareil, sans compte, et rien n'est supprimé sans validation explicite puis confirmation d'iOS.

> État : incréments **A** (cadrage, fondations) et **B** (tri manuel, persistance, permissions) implémentés. La logique est testée (71 tests, Linux et macOS) ; l'app iOS compile en Debug et Release (CI, Xcode 26.3, 0 avertissement) mais n'a pas encore été exécutée sur simulateur ni sur appareil — voir le [rapport de validation](docs/09-rapport-de-validation.md).

## Structure

```
PhotoSwipe.xcodeproj/        Projet Xcode (dossiers synchronisés, schéma partagé)
PhotoSwipe/                  App iOS (SwiftUI, PhotoKit)
  App/                       Point d'entrée, composition, réglages
  Library/                   Accès PhotoKit (autorisation, énumération, changements)
  Imaging/                   Chargement d'images, cache, mode démonstration
  Features/                  Écrans : Onboarding, Home, Months, Sorting, Settings
  Resources/                 Assets, Localizable.xcstrings, PrivacyInfo.xcprivacy
Packages/PhotoSwipeKit/      Logique testable hors Xcode (Swift 6)
  PhotoSwipeCore             Types de domaine et règles (périmètres, réconciliation)
  PhotoSwipeStore            Persistance SQLite (acteur, migrations, WAL)
  PhotoSwipeFeatures         Moteur de session, synchronisation, aperçu, photothèque simulée
Config/                      Info.plist partiel, xcconfig de signature (local non versionné)
Tools/                       Tests Linux via Docker
docs/                        PRD, parcours, architecture, données, backlog, specs, validation
```

## Prérequis

- Mac avec **Xcode 16 ou plus récent** (format de projet à dossiers synchronisés). Pour publier, utiliser la version de Xcode exigée par Apple au moment de l'envoi.
- iOS **18.0** minimum, iPhone.
- Aucune dépendance externe.

## Installation

```bash
git clone <ce dépôt> && cd StoreWipe
cp Config/Local.xcconfig.example Config/Local.xcconfig   # puis renseigner équipe et préfixe
open PhotoSwipe.xcodeproj
```

`Config/Local.xcconfig` (ignoré par git) contient `DEVELOPMENT_TEAM` et `PHOTOSWIPE_BUNDLE_ID_PREFIX`. Sans ce fichier, le projet compile pour le simulateur avec l'identifiant `com.example.photoswipe`.

Si Xcode ne résout pas le paquet local : *File › Add Package Dependencies… › Add Local…* → `Packages/PhotoSwipeKit`, puis ajouter les produits `PhotoSwipeCore`, `PhotoSwipeStore`, `PhotoSwipeFeatures` à la cible `PhotoSwipe`.

## Exécution

- **Simulateur avec photothèque fictive** : *Product › Scheme › Edit Scheme › Run › Arguments* → cocher `-PhotoSwipeDemoLibrary YES` (et éventuellement `-PhotoSwipeDemoAuthorization limited` ou `denied`). 180 photos synthétiques sur 8 mois, données dans une base séparée. Disponible en Debug uniquement.
- **Simulateur avec vraies photos** : glisser des images dans l'app Photos du simulateur, puis lancer sans argument.
- **Appareil** : renseigner `Config/Local.xcconfig`, choisir l'appareil, lancer. Les validations de performance, de mémoire et de PhotoKit se font uniquement sur appareil.
- **Appareil, sans Mac (Windows)** : chaque push produit dans la CI une IPA Release non signée (artefact `PhotoSwipe-ipa-<commit>`, job « IPA non signée »). La télécharger, la décompresser, puis l'installer avec [Sideloadly](https://sideloadly.io) et un Apple ID gratuit (iPhone branché en USB, iTunes ou Apple Devices installé, mode développeur activé sur l'iPhone). L'app expire au bout de 7 jours avec un compte gratuit ; le mode démonstration n'est pas disponible (Debug uniquement).

## Tests

| Où | Commande |
|----|----------|
| Xcode | ⌘U sur le schéma `PhotoSwipe` (exécute les tests du paquet) |
| macOS, terminal | `cd Packages/PhotoSwipeKit && swift test` |
| Linux / sans Xcode | `Tools/test-linux.sh` (Docker, Swift 6.2 + SQLite) |
| CI | `.github/workflows/ci.yml` : tests Linux + tests macOS + compilation iOS Debug et Release |

## Principes de conception (résumé)

- Un swipe enregistre une **décision** ; il ne supprime jamais. La suppression (incrément C) passera par la sélection, une confirmation, puis l'alerte système.
- Décisions validées une à une en transaction SQLite (WAL) : une fermeture forcée ne perd rien ; la pile d'annulation est restaurée au redémarrage.
- Un changement de permission n'est jamais traité comme une suppression ; une photo n'est purgée de l'index que si son absence est confirmée en accès complet.
- Images chargées à la taille de l'écran, préchargement de 3 photos ; téléchargement iCloud visible et désactivable.
- Aucune télémétrie, aucun appel réseau applicatif, journaux sans donnée personnelle.

## Documentation

1. [PRD](docs/01-prd.md)
2. [Parcours et écrans](docs/02-parcours-et-ecrans.md)
3. [Architecture et décisions (ADR)](docs/03-architecture.md)
4. [Modèle de données et transitions](docs/04-modele-de-donnees.md)
5. [Backlog priorisé](docs/05-backlog.md)
6. [Spécification des doublons exacts](docs/06-doublons-exacts.md)
7. [Classification locale : cadrage et plan d'évaluation](docs/07-classification-locale.md)
8. [Confidentialité et flux de données](docs/08-confidentialite.md)
9. [Rapport de validation](docs/09-rapport-de-validation.md)
10. [Checklist TestFlight / App Store](docs/10-checklist-testflight.md)

## Reprendre le projet

- Prochain incrément : **C — sélection et suppression via le système** ([backlog](docs/05-backlog.md#incrément-c--sélection-et-suppression-via-le-système-prochain)).
- Point ouvert avant l'incrément E : la licence des poids MobileCLIP2 semble réservée à la recherche ([détails](docs/07-classification-locale.md#3-candidats-et-état-des-vérifications)).
- Toute modification du schéma de base passe par une nouvelle migration dans `Schema.swift` (ne jamais modifier une migration publiée) et un test.
