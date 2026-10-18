# Installer PhotoSwipe sur un iPhone depuis Windows (sans Mac)

Document destiné à un agent (Claude Cowork) qui pilote le PC Windows de l'utilisateur. Objectif : obtenir la dernière IPA compilée par la CI et l'installer sur l'iPhone avec Sideloadly.

## Rôles

| Qui | Fait quoi |
|-----|-----------|
| **Agent** | Vérifier les prérequis, installer les logiciels, récupérer l'IPA, préparer Sideloadly, diagnostiquer les erreurs |
| **Utilisateur** | Tout ce qui est physique ou secret : brancher le câble, appuyer sur « Faire confiance » sur l'iPhone, activer le mode développeur, saisir le mot de passe Apple et le code 2FA |

**Règles pour l'agent**
- Ne jamais demander, lire, copier ni écrire le mot de passe ou le code 2FA de l'Apple ID. Quand Sideloadly les réclame, s'arrêter et laisser l'utilisateur saisir.
- Ne rien supprimer sur le PC ni sur l'iPhone. L'app installée ne supprime aucune photo (la suppression n'existe pas encore dans le code).
- À chaque point marqué **⏸ UTILISATEUR**, s'arrêter, dire précisément quoi faire, attendre la confirmation.
- Si une étape échoue deux fois de suite, arrêter, résumer l'erreur exacte et demander à l'utilisateur.

## Contexte

- Dépôt : https://github.com/antoinecstl/StoreWipe (public), branche `claude/photoswipe-foundations`. Copie locale : `C:\Opt\Projet_Info\StoreWipe`.
- App iPhone native (SwiftUI + PhotoKit), **iOS 18.0 minimum**, iPhone uniquement.
- La CI GitHub Actions compile à chaque push une IPA **non signée** (job « App iOS · IPA non signée »), publiée comme artefact `PhotoSwipe-ipa-<commit>`. Sideloadly la signe avec l'Apple ID de l'utilisateur au moment de l'installation.
- Identifiant de l'app : `io.github.antoinecstl.photoswipe` (Sideloadly peut le modifier lui-même).
- Apple ID gratuit : l'app **expire au bout de 7 jours** (réinstaller), 3 apps sideloadées maximum à la fois.

## Étape 0 — Prérequis

1. **⏸ UTILISATEUR** : confirmer la version d'iOS (Réglages › Général › Informations). Elle doit être **18.0 ou plus**. Sinon, s'arrêter : l'app ne s'installera pas.
2. Agent : vérifier que `gh` est installé et connecté.
   ```powershell
   gh --version
   gh auth status
   ```
   Si `gh auth status` échoue, demander à l'utilisateur de lancer `gh auth login` (il le tape dans le terminal avec le préfixe `!` si c'est dans Claude Code). Le téléchargement d'un artefact exige d'être connecté, même sur un dépôt public. Solution de repli : téléchargement par le navigateur (étape 2, variante B).

## Étape 1 — Installer les outils sur le PC (une seule fois)

1. **Pilote USB Apple** : installer l'une de ces deux options.
   - *iTunes* depuis le site d'Apple (apple.com/fr/itunes), recommandé par Sideloadly ;
   - ou *Apple Devices* depuis le Microsoft Store.
   Si Sideloadly ne détecte pas l'iPhone plus tard, essayer l'autre option (ne pas garder les deux en même temps).
2. **Sideloadly** : télécharger l'installeur Windows depuis le site officiel **https://sideloadly.io** uniquement, l'exécuter, accepter les valeurs par défaut.
3. Vérifier que Sideloadly se lance.

## Étape 2 — Récupérer la dernière IPA

Créer un dossier de travail dédié, hors du dépôt :

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\Downloads\PhotoSwipe-ipa" | Out-Null
```

**Variante A — ligne de commande (préférée)**

```powershell
cd C:\Opt\Projet_Info\StoreWipe
$run = gh run list --branch claude/photoswipe-foundations --workflow CI --status success --limit 1 --json databaseId,headSha,displayTitle | ConvertFrom-Json
$run
gh run download $run[0].databaseId --pattern "PhotoSwipe-ipa-*" --dir "$env:USERPROFILE\Downloads\PhotoSwipe-ipa"
Get-ChildItem "$env:USERPROFILE\Downloads\PhotoSwipe-ipa" -Recurse
```

Le fichier attendu est `PhotoSwipe.ipa` (environ 700 Ko) dans un sous-dossier nommé `PhotoSwipe-ipa-<commit>`.

**Variante B — navigateur**

1. Ouvrir https://github.com/antoinecstl/StoreWipe/actions (connecté à GitHub).
2. Ouvrir le dernier run **vert** de la branche `claude/photoswipe-foundations`.
3. En bas, section *Artifacts* : télécharger `PhotoSwipe-ipa-<commit>` (un zip), l'extraire pour obtenir `PhotoSwipe.ipa`.

**Contrôle** : l'IPA doit être un zip contenant `Payload/PhotoSwipe.app/`.

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$ipa = Get-ChildItem "$env:USERPROFILE\Downloads\PhotoSwipe-ipa" -Recurse -Filter PhotoSwipe.ipa | Select-Object -First 1
[IO.Compression.ZipFile]::OpenRead($ipa.FullName).Entries | Where-Object FullName -like "Payload/PhotoSwipe.app/Info.plist"
```

## Étape 3 — Préparer l'iPhone

1. **⏸ UTILISATEUR** : brancher l'iPhone au PC en USB, le déverrouiller, appuyer sur **Faire confiance** puis saisir le code de l'iPhone.
2. Agent : ouvrir Sideloadly et vérifier que l'iPhone apparaît dans la liste des appareils. Sinon, voir « Dépannage ».

## Étape 4 — Installer avec Sideloadly

1. Agent : dans Sideloadly, glisser `PhotoSwipe.ipa` dans la zone prévue (ou bouton IPA).
2. Vérifier que l'appareil sélectionné est bien l'iPhone de l'utilisateur.
3. **⏸ UTILISATEUR** : saisir lui-même son Apple ID dans le champ prévu (conseil : un Apple ID secondaire gratuit convient très bien, il évite d'exposer le compte principal).
4. Laisser les options avancées par défaut.
5. Cliquer sur **Start**.
6. **⏸ UTILISATEUR** : saisir le mot de passe Apple si demandé, puis le code 2FA reçu sur ses appareils.
7. Attendre le message de fin (« Done »).

## Étape 5 — Activer l'app sur l'iPhone

**⏸ UTILISATEUR**, dans cet ordre :
1. Réglages › Général › VPN et gestion de l'appareil › sous « App développeur », choisir l'Apple ID › **Faire confiance**.
2. Réglages › Confidentialité et sécurité › tout en bas › **Mode développeur** › activer. L'iPhone redémarre ; confirmer l'activation au redémarrage.
3. Ouvrir l'app **PhotoSwipe**.
4. Au premier lancement, choisir l'accès aux photos (complet, limité ou refusé) ; l'app doit réagir correctement dans les trois cas.

## Étape 6 — Test minimal à faire faire à l'utilisateur

Cette app n'a **jamais tourné** avant ; il faut noter tout ce qui cloche.

1. L'app se lance sans planter.
2. Écran de bienvenue puis demande d'autorisation Photos.
3. Accueil : le nombre de photos et la liste des mois s'affichent ; l'indexation avance.
4. Session de tri : swipe à droite (conserver), à gauche (à supprimer), bouton « Passer », bouton « Annuler ».
5. Fermer l'app de force (balayer vers le haut dans le sélecteur d'apps), la rouvrir : elle reprend sur la même photo.
6. Zoom avec deux doigts : aucune décision accidentelle.
7. Vérifier dans l'app Photos que **aucune photo n'a été supprimée**.

Si quelque chose ne va pas, demander à l'utilisateur une description précise (écran, geste, ce qui était attendu) et, en cas de plantage, le rapport de crash : Réglages › Confidentialité et sécurité › Analyse et améliorations › Données d'analyse › entrées « PhotoSwipe » › partager le texte.

## Mises à jour (boucle de travail)

À chaque nouveau `git push` sur la branche, la CI produit une nouvelle IPA (environ 3 minutes). Refaire les étapes 2 puis 4 : Sideloadly remplace l'app sans perdre ses données (la base de décisions est conservée tant que l'identifiant de l'app ne change pas).

**Tous les 7 jours** : refaire l'étape 4 avec la même IPA, sinon l'app cesse de s'ouvrir.

## Dépannage

| Symptôme | Piste |
|----------|-------|
| `gh run download` : erreur d'authentification | `gh auth login`, ou variante B (navigateur) |
| Aucun artefact | Le dernier run n'est pas vert, ou date de plus de 14 jours : relancer la CI (`gh workflow run CI --ref claude/photoswipe-foundations`) puis reprendre l'étape 2 |
| Sideloadly ne voit pas l'iPhone | Autre câble ou autre port USB ; iPhone déverrouillé avec « Faire confiance » validé ; essayer iTunes à la place d'Apple Devices (ou l'inverse), jamais les deux ; redémarrer Sideloadly |
| Erreur de connexion à l'Apple ID | Vérifier l'Apple ID et le code 2FA ; essayer plus tard (limites d'Apple) ; tester avec un autre Apple ID gratuit |
| « Limite de 10 App ID par semaine » ou « 3 apps maximum » | Attendre une semaine ou supprimer une app sideloadée (elle ne doit pas être supprimée sans l'accord de l'utilisateur) |
| L'app s'installe mais « Développeur non approuvé » | Étape 5, point 1 |
| L'icône est grisée ou l'app ne s'ouvre plus après 7 jours | Certificat expiré : refaire l'étape 4 |
| Le mode développeur n'apparaît pas dans Réglages | Il n'apparaît qu'après la première installation d'une app sideloadée ; relancer l'installation |
| L'app plante au lancement | Récupérer le rapport de crash (étape 6) et le transmettre pour correction |
| Message d'incompatibilité de version | iOS < 18.0 : l'app ne peut pas s'installer |
