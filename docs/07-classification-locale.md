# Prétri intelligent local — cadrage et plan d'évaluation (incrément E)

Statut : **cadrage.** Aucun modèle n'est intégré. Le tri manuel ne dépend d'aucune analyse.

## 1. Taxonomie : des attributs indépendants

Une photo reçoit plusieurs attributs, pas une seule étiquette exclusive.

| Attribut | Valeurs | Source |
|----------|---------|--------|
| Contenu visuel | cours · document · reçu/facture · image utilitaire · photo personnelle · incertain | modèle de vision local |
| Capture d'écran | oui / non | **métadonnées** (`PHAssetMediaSubtype.photoScreenshot`), prioritaires sur le modèle |
| Défauts techniques | flou marqué · mauvaise exposition · obstruction · aucun | analyse de qualité (Vision et/ou heuristiques), distincte |

Une capture d'écran peut aussi être un « cours ». Ne jamais confondre : catégorie visuelle, défaut technique, importance personnelle et intention de suppression. Un reçu ou un cours n'est pas « inutile » : la catégorie sert seulement à regrouper des photos dans une pile, avec la raison affichée (« Proposée car : ressemble à un reçu »).

« Incertain » est un résultat légitime : la photo reste disponible dans le tri manuel et n'apparaît dans aucune catégorie.

## 2. Approche envisagée

Classement « zéro-shot » par similarité image-texte :
1. hors ligne, calcul des **représentations textuelles** de plusieurs formulations par catégorie (en anglais ou en français : la formulation retenue est celle qui donne les meilleurs résultats mesurés) ;
2. sur l'appareil, **seul l'encodeur d'images** est embarqué, avec les vecteurs textuels précalculés (quelques Kio) ;
3. décision par seuils calibrés par catégorie et marge minimale avec la deuxième catégorie ; sinon « incertain ».

Les scores de similarité ne sont **pas** des probabilités : ils ne sont jamais affichés comme tels.

## 3. Candidats et état des vérifications

| Candidat | Rôle | Licence (constat au 17/10/2026) | Statut |
|----------|------|----------------------------------|--------|
| MobileCLIP2-S2 / S0 (Apple) | candidats initiaux | Les cartes de modèle Hugging Face indiquent la licence **apple-amlr** ; d'après le texte trouvé, elle limite l'usage à des « Research Purposes » non commerciales et exclut l'usage dans un produit. | ⚠️ **Bloquant pour une distribution App Store**, sauf licence spécifique d'Apple. À confirmer sur le fichier `LICENSE` officiel (non téléchargeable depuis cet environnement : hôte bloqué). |
| MobileCLIP (v1) | alternative légère | Une mise à jour d'une carte de modèle aurait remplacé l'ancienne mention « apple-ascl » par « apple-amlr ». | ⚠️ À vérifier, probablement même contrainte. |
| SigLIP 2 (Google) | référence qualité / candidat | Apache 2.0 selon plusieurs sources secondaires ; carte officielle non consultée. | À confirmer. Taille de l'encodeur d'images (variante base) à mesurer sur iPhone 12. |
| Vision (Apple) : `ClassifyImageRequest`, `CalculateImageAestheticsScoresRequest` (iOS 18, indicateur « utility »), reconnaissance de texte | base sans modèle embarqué | API système, aucune licence de poids | À évaluer comme référence et comme complément (densité de texte pour documents et reçus ; le texte reconnu n'est ni stocké ni journalisé). |

Sources consultées (secondaires, à recouper avec les sources primaires) :
- Carte de modèle Hugging Face d'un checkpoint MobileCLIP2 mentionnant `license: apple-amlr` : <https://huggingface.co/apple/mobileclip2_coca_dfn2b_s13b_context77/blob/main/README.md>
- Dépôt MobileCLIP2-S3 sur Hugging Face : <https://huggingface.co/apple/MobileCLIP2-S3/commit/7793fd3dc61d30c444fcfbf99f758e86974e8556>
- Documentation Apple `CalculateImageAestheticsScoresRequest` (iOS 18.0+) : <https://developer.apple.com/documentation/vision/calculateimageaestheticsscoresrequest>
- Documentation Apple `isUtility` : <https://developer.apple.com/documentation/vision/vnimageaestheticsscoresobservation/isutility>
- Fiche tierce SigLIP 2 base (Apache 2.0) : <https://docs.voxel51.com/model_zoo/models/google_siglip2_base_patch16_224.html>

**Ne pas supposer** qu'une démonstration iOS de MobileCLIP valide chaque variante MobileCLIP2, ni qu'une conversion tierce (ONNX, Core ML) change la licence des poids.

## 4. Vérifications préalables à toute intégration (checklist)

1. Sources officielles et poids disponibles (dépôt, empreintes des fichiers).
2. Licence des poids **et** du code, compatibilité avec une app distribuée gratuitement sur l'App Store.
3. Chemin d'export réel vers Core ML (coremltools depuis PyTorch), version des outils.
4. Prétraitement exact (taille d'entrée, recadrage, normalisation) et tokenizer (uniquement hors ligne).
5. Taille du modèle, mémoire maximale, latence médiane et haute sur iPhone 12 (rapport de performance Core ML d'Xcode + Instruments).
6. Écart original / converti : similarité cosinus des embeddings sur ≥ 200 images (seuil d'acceptation à fixer, par exemple ≥ 0,99 en moyenne et ≥ 0,98 au minimum).
7. Précision par catégorie sur notre jeu de validation.

## 5. Protocole d'évaluation

- **Jeu de données** : plusieurs centaines de photos représentatives, obtenues avec autorisation explicite des personnes concernées, stockées hors dépôt (`Tools/model-prep/data/`, ignoré par git). Stratifié par catégorie, incluant captures d'écran, photos iCloud et cas ambigus.
- **Séparation** : jeu d'ajustement (choix des formulations et des seuils) distinct du jeu de validation (mesure finale, utilisé une seule fois par configuration retenue).
- **Mesures** : précision et rappel par catégorie, matrice de confusion, proportion d'« incertain », erreurs sur des documents potentiellement importants (pièces d'identité, contrats, ordonnances) à lister une par une, latence médiane et p95, mémoire maximale, taille, durée d'un scan représentatif, impact thermique et énergétique (Instruments, appareil réel).
- **Règle de communication** : aucun taux global ne masque une catégorie faible ; chaque catégorie est publiée avec son effectif.

## 6. Alternative si aucun modèle n'est utilisable

Si aucun modèle à licence compatible n'atteint la qualité requise : livrer la V1 avec les captures d'écran (métadonnées), les doublons exacts et une catégorie « utilitaire » fondée sur les API Vision du système, et documenter l'écart. **Aucune bascule vers une API distante.**

## 7. Question ouverte

La licence de MobileCLIP2 semble incompatible avec une distribution App Store. Proposition : évaluer en priorité la base Vision (sans licence) et SigLIP 2 (licence à confirmer), en gardant MobileCLIP2 uniquement comme référence de recherche hors ligne si sa licence le permet. Décision à valider avant l'incrément E.
