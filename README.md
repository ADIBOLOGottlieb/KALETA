# 🎭 KALETA — Terrasse & Lounge · Application de commande en ligne

Application mobile (Android / iOS) de commande pour **KALETA — Terrasse & Lounge**, « la nouvelle adresse gourmande de Lomé » (face au lycée d'Agoè, à côté de l'OTR · +228 91 00 84 84 · lundi–jeudi 11h–23h, vendredi–dimanche 16h–02h). Cuisine d'Afrique (8 pays), grillades et pizzas au feu de bois, cocktails signature, chicha, rooftop. Une seule app, quatre rôles : **client**, **livreur**, **gérant** et **propriétaire**. Le rôle du compte connecté détermine l'interface affichée.

- **Client** : commande, envoie sa position et suit sa commande en direct.
- **Gérant** : reçoit les commandes, donne leur statut, attribue les livreurs, tient la caisse et gère le restaurant.
- **Livreur** : prend une livraison et suit la position envoyée par le client.
- **Propriétaire** : la main sur toutes les fonctionnalités, y compris la gestion des gérants.

Pas de compte « cuisine » : un ancien compte cuisine est désactivé au démarrage du serveur (le propriétaire peut le supprimer ou le réactiver comme gérant).

**Design** : l'identité du restaurant — vert nuit (#03150F), vert profond (#0F4F38), vert néon du masque (#5BEA6B) et or des couverts (#D4B566), titres en Playfair Display. **Sombre par défaut** (ambiance lounge ; clair / système au choix dans le profil). Écrans d'accueil animés : fond aux halos néon et rayons de la coiffe du masque, photos réelles du lieu (façade, rooftop, salle, terrasse) en parallaxe, logotype « KALETA » à reflet, formulaires en verre fumé avec champs lumineux au focus, secousse en cas d'erreur, jauge du mot de passe, bouton néon qui se transforme en indicateur de chargement, transitions de page en fondu-zoom. Le logo officiel (`mobile/assets/images/logo_source.png`) passe par `mobile/tool/make_logo.ps1` : masque détouré (`logo_mask.png`, affiché par `AppLogo`), logo complet transparent (`logo_full.png`), icônes sur vert nuit (`logo.png`, `logo_foreground.png`) et logo des pages web ; puis `dart run flutter_launcher_icons`.

**Carte** : la carte réelle du restaurant est chargée sur une base neuve (`backend/src/seed.js`) : menu du jour (l'app n'affiche que celui du jour, dans une « ardoise » en tête de l'accueil), signatures Kaleta, cuisine d'Afrique, brochettes, pizzas, burgers, pâtes, salades, desserts, jus et thés Kaleta, cocktails, bières, vins, chicha et packs. Les coordonnées et horaires du restaurant sont aussi enregistrés. Une base existante n'est jamais modifiée : le gérant ajuste la carte depuis l'app.

```
backend/   API Node.js (Express + SQLite intégré à Node) — déployée sur Render
mobile/    Application Flutter (client, livreur, gérant, propriétaire), icône dans assets/images/logo.png
```

## Fonctionnalités

**Client**
- Inscription et connexion par numéro de téléphone
- Menu par catégories, recherche toujours visible, section « Les plus demandés »
- **Packs de menu** (catégorie « Packs ») : plusieurs plats à un prix réduit, contenu et économie affichés ; un pack disparaît si un de ses plats est épuisé
- Panier (jusqu'à 999 par article, appui long sur la quantité pour la saisir), total estimé avec livraison et frais mobile money
- Livraison : position sur la carte (recherche d'adresse, « Ma position », adresse retrouvée automatiquement) ou adresses enregistrées
- Frais de livraison fixes, **selon la distance** (devis affiché avant de commander, zone maximale) ou **par zone / quartier** (zone choisie ou reconnue d'après la position)
- Horaires d'ouverture affichés (« Fermé — ouvre lundi à 10:00 »), commande impossible hors horaires
- Paiement : espèces, **Flooz** (Moov Africa) ou **Mixx by Yas** par **push USSD** : le client confirme avec son code PIN sur son téléphone (jamais dans l'app)
- **Envoyer ma position, comme sur WhatsApp** : *Partager ma position en direct* (15 min, 1 h ou 8 h : le livreur attribué voit le client bouger sur sa carte, l'itinéraire et l'heure d'arrivée vont jusqu'à lui, le bouton *Itinéraire* le guide là où il est), *Envoyer ma position actuelle* (avec sa précision) ou le point de l'épingle ; partage démarré ou arrêté depuis la commande, notification Android pendant le partage, position visible seulement du client, du livreur attribué et du personnel, effacée à la fin
- **Suivi du livreur en direct** sur la carte (scooter qui avance, heure d'arrivée estimée), annulation tant que la commande est en attente, « Paiement non abouti » → Réessayer / Annuler
- Profil : photo, statistiques, adresses, numéro mobile money préféré, mot de passe, thème clair / sombre / système, aide (appel, WhatsApp, FAQ), suppression du compte

**Admin**
- **Deux niveaux de personnel** : *Propriétaire* (compte créé au premier lancement : la main sur tout ; personne d'autre ne peut le modifier, le désactiver ni le supprimer ; lui seul crée, désactive et supprime les gérants) et *Gérant* (commandes et statuts, caisse, menu, livreurs, réglages, paiements, rapports ; il ne modifie que son propre nom et son mot de passe) ; écran **Gérants** (propriétaire)
- Tableau de bord avec **comparaison au même jour de la semaine dernière** et **pic de commandes** (heures les plus chargées), mise en page **tablette**
- Notification quand un livreur prend une livraison, la livre, et quand le client confirme la réception
- **Horaires d'ouverture automatiques** par jour (plusieurs plages), plus l'interrupteur manuel
- **Journal des erreurs** : plantages de l'app et erreurs du serveur, conservés dans la base (sauvegardée)
- Tableau de bord, commandes (alerte « Nouvelle commande », notification « Paiement reçu »), menu, catégories, clients
- **Paiements à vérifier** : validation manuelle (référence obligatoire, montant contrôlé) ou rejet
- **Encaissements** : totaux par jour et opérateur (encaissé, frais, net, reversé), reversement par lot, export CSV
- **Caisse** : ventes au comptoir (sur place / à emporter, espèces ou push Flooz/Mixx lancé par le caissier), envoyées directement en cuisine
- **Rapports** par période : chiffre d'affaires, panier moyen, répartition app/comptoir, livraison/retrait/sur place, moyens de paiement et commissions, livreurs, jours, plats les plus vendus, export CSV (Excel)
- **Zones de livraison** : prix par quartier, reconnaissance facultative par un cercle sur la carte
- Remboursement d'une commande payée puis annulée
- Paramètres : ouvert/fermé, livraison, minimum, frais de paiement, délai d'annulation des commandes mobile money non payées, compte marchand (numéros masqués)
- Sécurité : journal d'audit de toutes les actions sur l'argent, alertes (pics, paiements en attente, écarts de rapprochement)

## 1. Lancer le backend

Il faut Node.js 22.13 ou plus récent.

```bash
cd backend
npm install
npm start
```

Au premier lancement, l'API crée la base `eza_zozo.db`, la carte KALETA et le compte propriétaire `ADMIN_PHONE` / `ADMIN_PASSWORD` (sur Render : `71572566` et le mot de passe saisi dans Render ; en local sans variables : `71572566` / `admin123`). Le mot de passe n'est jamais écrit dans le dépôt.

### Variables d'environnement

| Variable | Rôle |
|---|---|
| `PORT` | 4000 par défaut |
| `JWT_SECRET` | **obligatoire en production** |
| `DB_PATH` | chemin de la base SQLite |
| `ADMIN_PHONE`, `ADMIN_PASSWORD` | compte admin créé au premier lancement (`ADMIN_PASSWORD` obligatoire en production) |
| `TRUST_PROXY` | `1` derrière Render (vraies IP pour l'anti-abus) |
| `PAYMENT_PROVIDER` | `simulation` (défaut), `paygate` (recommandé au Togo), `kadev`, `direct` |
| `PAYMENT_PROVIDER_FLOOZ`, `PAYMENT_PROVIDER_MIXX` | prestataire différent par opérateur (facultatif) |
| `PAYGATE_AUTH_TOKEN` | clé API PayGate Global (**secret**) |
| `MERCHANT_FLOOZ_NUMBER`, `MERCHANT_MIXX_NUMBER` | numéros marchands du restaurant (affichés masqués dans l'admin) |
| `MERCHANT_DISPLAY_NAME` | nom affiché au client, « KALETA » par défaut |
| `PROVIDER_FEE_PERCENT_FLOOZ`, `PROVIDER_FEE_PERCENT_MIXX` (ou `PROVIDER_FEE_PERCENT` pour les deux) | commission exacte de votre contrat avec l'agrégateur, en % : sert au calcul de la commission réelle et du net (voir « Frais de paiement ») |
| `KADEV_PUBLIC_KEY`, `KADEV_SECRET_KEY`, `KADEV_WEBHOOK_SECRET` | uniquement si `PAYMENT_PROVIDER=kadev` |
| `PAYMENT_EXPIRY_SECONDS` | durée d'une demande de paiement (120 par défaut) |
| `ALLOW_SIMULATION` | `1` : autorise le paiement simulé par le client en production (démonstration uniquement) |
| `BACKUP_GITHUB_REPO`, `BACKUP_GITHUB_TOKEN` | sauvegarde automatique de la base et des photos dans un dépôt GitHub privé (voir § 7) |
| `FIREBASE_SERVICE_ACCOUNT` | compte de service Firebase (JSON brut ou base64) : notifications push |
| `SMS_PROVIDER`, `SMS_HTTP_URL`, `SMS_HTTP_METHOD`, `SMS_HTTP_HEADERS`, `SMS_HTTP_BODY` | passerelle SMS (codes de vérification, mot de passe oublié) ; `none` par défaut |
| `PUBLIC_URL` | adresse publique de l'API (liens des CGU et de la confidentialité) |
| `OSRM_URL`, `NOMINATIM_URL` | serveurs d'itinéraire et d'adresses (par défaut : serveurs publics OpenStreetMap). L'app passe par le serveur, qui met les réponses en cache et respecte 1 requête/s pour Nominatim |

Aucune clé secrète ni aucun numéro marchand n'est écrit dans le code ou dans l'APK : tout passe par ces variables (sur Render : *Environment*).

## 2. Lancer l'application mobile

```bash
cd mobile
flutter pub get

# Émulateur Android (10.0.2.2 = le PC hôte)
flutter run

# Vrai téléphone sur le même Wi-Fi : utilisez l'IP locale du PC
flutter run --dart-define=API_URL=http://192.168.1.20:4000
```

APK : `flutter build apk --release --dart-define=API_URL=https://eza-zozo-api-5fib.onrender.com --dart-define=GOOGLE_MAPS_API_KEY=VOTRE_CLE`

La CI GitHub (`.github/workflows/build-apk.yml`) analyse le code, lance les tests et produit l'APK à chaque push sur `main` qui touche `mobile/` (onglet **Actions** → *Build APK* → *Artifacts*). Les tests du backend (`npm test`) tournent à chaque push qui touche `backend/`.

### Signature de l'APK (clé fixe)
L'APK doit toujours être signé avec **la même clé** : sinon Android refuse d'installer une mise à jour par-dessus l'ancienne version, et la clé Google Maps ne peut pas être restreinte à l'app (l'empreinte SHA-1 changerait à chaque build).

1. La clé est un fichier `.jks`, conservé **hors du dépôt** (jamais sur GitHub). Pour en créer une :
   `keytool -genkeypair -keystore ezazozo-release.jks -storetype PKCS12 -alias ezazozo -keyalg RSA -keysize 2048 -validity 10000`
2. Sur GitHub (*Settings* → *Secrets and variables* → *Actions*), ajoutez :
   - `ANDROID_KEYSTORE_BASE64` : le fichier `.jks` encodé en base64 (`base64 -w0 ezazozo-release.jks`) ;
   - `ANDROID_KEYSTORE_PASSWORD` : son mot de passe (alias `ezazozo`, même mot de passe pour la clé).
3. La CI écrit `android/key.properties` (ignoré par git), signe l'APK et calcule elle-même l'empreinte SHA-1 envoyée par l'app à Google. Sans ces secrets, l'APK est signé avec une clé de débogage.

⚠️ **Sauvegardez le fichier `.jks` et son mot de passe** (clé USB, coffre-fort de mots de passe) : s'ils sont perdus, les téléphones devront désinstaller l'app pour installer une nouvelle version. Au premier passage à la clé fixe, l'ancienne version (signée en débogage) doit être désinstallée une fois.

## 3. Position du client et cartes

### Position depuis l'app Google Maps (gratuit, sans clé)
À la commande, le client touche **« Choisir ma position dans Google Maps »** : l'application Google Maps de son téléphone s'ouvre ; il pose un repère sur sa maison (appui long), touche **Partager** puis **KALETA**. KALETA reçoit le lien et en extrait la position (et le nom / l'adresse du lieu s'ils sont partagés). Autres possibilités : « Copier le lien » dans Google Maps (le lien est détecté au retour dans l'app), coller un lien, des coordonnées ou un plus code, ou « Utiliser ma position actuelle » (GPS). La position est ensuite confirmée sur un aperçu OpenStreetMap, et le livreur l'ouvre directement dans Google Maps.

Aucune API Google n'est utilisée : liens Google Maps décodés dans l'app (liens courts `maps.app.goo.gl` résolus par redirection, coordonnées, plus codes), aperçu OpenStreetMap, adresse via Nominatim, itinéraire via OSRM.

### Carte Google intégrée (facultatif, compte de facturation Google requis)

Sans clé, l'app utilise automatiquement **OpenStreetMap**. Avec une clé, elle affiche les tuiles officielles Google (en français, région Togo), la recherche d'adresse Google et l'adresse du point choisi.

1. Dans Google Cloud, créez une clé et activez **Map Tiles API**, **Places API (New)**, **Geocoding API** et **Routes API** (itinéraires).
2. **Restreignez la clé** (*Identifiants* → la clé) :
   - *Restrictions d'application* → **Applications Android** : nom du package `com.kaleta.app` + empreinte **SHA-1** du certificat qui signe l'APK (`keytool -list -v -keystore <votre.jks>`).
   - *Restrictions d'API* : uniquement les quatre API ci-dessus.
3. Sur GitHub (*Settings* → *Secrets and variables* → *Actions*), ajoutez le secret `GOOGLE_MAPS_API_KEY`. L'empreinte SHA-1 est calculée par la CI à partir de la clé de signature (voir « Signature de l'APK ») : elle doit être en place **avant** de restreindre la clé Google.

### Itinéraires de livraison
Placez d'abord le restaurant sur la carte (admin → **Plus → Paramètres → Position du restaurant**). L'itinéraire restaurant → client s'affiche ensuite sur la carte de choix de la position (avec distance et durée) et dans le détail de chaque commande en livraison, avec un bouton « Ouvrir dans Google Maps » pour le guidage du livreur. Avec une clé Google, le trajet est calculé par la **Routes API** (deux-roues, sinon voiture) ; sans clé, par **OSRM** (serveur public gratuit d'OpenStreetMap, sans garantie de service, durées calculées pour une voiture).

La clé Google Maps est la seule clé présente dans l'APK : c'est pour cela qu'elle doit être restreinte.

## 4. Paiements Flooz / Mixx by Yas

### Parcours
1. Le client commande : le **serveur** calcule le total (sous-total + livraison + frais mobile money, voir « Frais de paiement »). Le montant envoyé par l'app n'est jamais pris en compte.
2. Écran « Payer {total} FCFA » : numéro pré-rempli et modifiable → « Envoyer la demande ».
3. L'opérateur envoie une demande de confirmation (push USSD) sur le téléphone : le client tape son **code PIN** dans la fenêtre de l'opérateur.
4. L'app vérifie le statut toutes les 3 s pendant environ 2 min → « Paiement reçu ✅ », ou « Expiré / Refusé » avec « Réessayer ».
5. Un paiement n'est validé qu'après **revérification auprès du prestataire** (le webhook seul ne suffit jamais). Si le montant reçu est inférieur au total, la commande n'est pas validée et le client voit le message.
6. Une commande mobile money ne passe en cuisine qu'une fois payée ; sans paiement, elle est annulée automatiquement après 30 min (réglable dans les paramètres admin).

### Mode simulation
Sans prestataire configuré (`PAYMENT_PROVIDER=simulation`, valeur actuelle sur Render), aucun argent ne circule : l'écran de paiement affiche « MODE TEST » et deux boutons pour simuler la saisie du code PIN. ⚠️ **En production, n'utilisez jamais la simulation** : n'importe quel client pourrait valider lui-même son paiement.

### Mise en place de PayGate Global (recommandé au Togo)
1. Créez le compte marchand sur paygateglobal.com et fournissez les pièces de l'entreprise.
2. Récupérez la clé API (`auth_token`) dans le tableau de bord, puis sur Render : `PAYMENT_PROVIDER=paygate` et `PAYGATE_AUTH_TOKEN=…`.
3. Déclarez l'URL de retour (callback) : `https://eza-zozo-api-5fib.onrender.com/api/payments/paygate/webhook`. Elle n'est pas signée : le serveur revérifie systématiquement chaque paiement via `/api/v2/status`.
4. Indiquez la commission de votre contrat PayGate dans `PROVIDER_FEE_PERCENT_FLOOZ` / `PROVIDER_FEE_PERCENT_MIXX` (voir ci-dessous).

Flooz utilise le réseau `FLOOZ`, Mixx by Yas (ex-T-Money) le réseau `TMONEY`.

### Frais de paiement
Réglage **« Qui paie les frais »** (`payment_fees_paid_by`, gérant, Paramètres) :

- **`restaurant` (par défaut)** : le client paie le prix affiché (total = commande + livraison, `payment_fee = 0`). Le taux de la commission est quand même figé sur la commande (`payment_fee_percent`) : à l'encaissement (push, validation manuelle, paiement rattrapé), le serveur enregistre la commission réelle `provider_fee = ⌈brut × p/100⌉` et le net `net_amount = brut − commission`, visibles dans **Encaissements** et les rapports. Exemple : 21 000 F à 3,5 % → commission 735 F, net 20 265 F.
- **`client`** : les frais payés par le client sont **exactement la commission de l'agrégateur**, opérateur par opérateur, et le restaurant reçoit exactement commande + livraison. L'agrégateur prélève p % du montant payé : le serveur demande donc au client total = ⌈(commande + livraison) / (1 − p/100)⌉. Exemple : 20 000 F + 1 000 F de livraison avec une commission de 3,5 % → total 21 762 F, commission 762 F, net pour le restaurant 21 000 F.

Le réglage s'applique aux nouvelles commandes (et au changement Flooz ↔ Mixx) ; les commandes déjà passées gardent leur total.


- Le taux vient de `PROVIDER_FEE_PERCENT_FLOOZ` / `PROVIDER_FEE_PERCENT_MIXX` (repli : `PROVIDER_FEE_PERCENT`). Dans l'admin, le champ « frais de paiement » devient alors informatif (« fixés par l'agrégateur »).
- Sans ces variables, ou en mode simulation, c'est le réglage « frais de paiement » de l'admin qui s'applique (2 % par défaut).
- Le taux est enregistré sur chaque commande : un changement ne modifie pas les commandes déjà passées.
- ⚠️ Mettez la commission **exacte** de votre contrat : c'est elle qui calcule le net du restaurant (et, en mode `client`, les frais facturés).

## 5. Argent vers les comptes marchands du restaurant

Avec un agrégateur, l'argent arrive d'abord sur le solde marchand de l'agrégateur, puis il est **reversé** sur les comptes **Flooz Marchand** (Moov Africa) et **Mixx by Yas Marchand** du restaurant — jamais sur un compte personnel.

À faire dans le tableau de bord PayGate :
1. Enregistrez les deux numéros marchands du restaurant (un par opérateur) comme comptes de reversement.
2. Activez le **reversement automatique**, quotidien ou à partir d'un seuil.
3. Renseignez les mêmes numéros dans `MERCHANT_FLOOZ_NUMBER` / `MERCHANT_MIXX_NUMBER` (Render) : ils s'affichent masqués dans l'admin (« 96 •• •• 12 »).

**Délai de reversement : à confirmer avec PayGate** (il dépend du contrat). L'app crée une alerte si un paiement n'est pas reversé après 48 h.

Suivi dans l'admin (**Plus → Encaissements**) : pour chaque paiement, montant brut, frais de l'agrégateur, net dû au restaurant, opérateur, référence opérateur et statut de reversement (`en_attente` → `reverse`). Quand le virement arrive sur le compte marchand, un agent sélectionne les paiements et saisit la référence du virement. Export CSV pour la comptabilité. Un rapprochement quotidien compare les paiements avec le prestataire et alerte en cas d'écart (paiement absent, montant différent, reversement en retard).

**Paiement direct opérateur** : si le restaurant obtient un accès API marchand chez Moov Africa (Flooz) ou Yas (Mixx), le client paie directement le numéro marchand. Les connecteurs `flooz_direct` / `mixx_direct` (`backend/src/payments/providers/direct.js`) sont prêts à être complétés derrière la même interface (`initiate`, `checkStatus`, `verifyWebhook`), sans toucher au reste du code.

**Remboursement** : une commande payée puis annulée crée une alerte « remboursement à prévoir ». Le bouton admin « Rembourser » passe par l'API du prestataire si elle existe ; sinon l'agent saisit la référence du remboursement fait depuis le compte marchand.

Toute action sur l'argent (validation, rejet, reversement, remboursement) est inscrite au journal d'audit avec l'agent qui l'a faite.

## 6. Livreurs

L'admin crée les comptes livreurs (**Plus → Livreurs** : nom, téléphone, mot de passe) ; un livreur se connecte avec son téléphone et arrive directement dans l'espace livreur.

Circuit d'une commande en livraison :
1. Le gérant passe la commande à « Prête » : elle apparaît chez tous les livreurs dans **À livrer** (numéro du client, adresse, montant à encaisser ou « Déjà payé »). Une commande mobile money ne peut être prise qu'une fois payée.
2. Un livreur appuie sur **Je prends cette livraison** (ou l'admin l'attribue depuis le détail de la commande) : elle passe « En livraison ».
3. Un appui sur le client ouvre **Google Maps en guidage moto** vers sa position (ou vers son adresse s'il n'a pas de position).
4. Le livreur appuie sur **Livraison faite**, puis le client appuie sur **J'ai reçu ma commande** : la commande est **complète**.
5. Sans « Reçu » du client, la commande est confirmée automatiquement après 12 h (réglable : Paramètres → Livraison).

**Suivi en direct** : pendant une livraison, le téléphone du livreur envoie sa position toutes les 10 s environ (même écran verrouillé, avec la notification « Livraison en cours »). Le client voit le scooter avancer et l'heure d'arrivée estimée. Le partage s'arrête dès « Livraison faite » ; aucune position n'est enregistrée en dehors d'une livraison.

Un livreur désactivé ne peut plus se connecter ; ses livraisons en cours restent visibles par l'admin, qui peut les réattribuer. Toutes ces actions sont inscrites au journal d'audit.

## 7. Comptes, notifications et pages légales

- **Mot de passe oublié** : le client saisit son numéro. Si une passerelle SMS est configurée, il reçoit un code par SMS ; sinon la demande apparaît chez l'admin (**Plus → Mots de passe oubliés**, notification + badge) avec le code à communiquer par appel ou WhatsApp.
- **Vérification du numéro par SMS** à l'inscription : activée automatiquement dès qu'une passerelle SMS est configurée (`SMS_PROVIDER=http`). Aucun SMS gratuit n'existe au Togo : il faut un compte chez un fournisseur de SMS.
- **Sessions** : changer ou réinitialiser son mot de passe déconnecte les autres appareils ; après un effacement de la base, les anciennes sessions sont refusées (un ancien client ne peut plus tomber sur le compte d'un autre).
- **Numéros** : enregistrés au format `+228XXXXXXXX` (« 90 12 34 56 » et « +228 90123456 » sont le même compte).
- **Notifications push** (Firebase, gratuit) : client (statut de commande, paiement, « confirmez la réception »), livreurs (commande prête, livraison attribuée), admin (nouvelle commande, paiement, mot de passe oublié). Mise en place :
  1. console.firebase.google.com → créer un projet (offre gratuite Spark) → ajouter une app Android `com.kaleta.app` ;
  2. télécharger `google-services.json` → secret GitHub `GOOGLE_SERVICES_JSON` (contenu brut ou base64) ;
  3. Paramètres du projet → Comptes de service → « Générer une nouvelle clé privée » → variable Render `FIREBASE_SERVICE_ACCOUNT`.
  Sans ces réglages, l'app fonctionne normalement, sans notifications.
- **CGU et politique de confidentialité** : acceptation obligatoire à l'inscription ; pages publiques `/legal/cgu` et `/legal/confidentialite` (l'adresse de la seconde est celle à donner à Google Play). ⚠️ Ce sont des modèles : faites-les relire par un juriste avant la publication.

## 8. Hébergement sur Render et données

`render.yaml` décrit le service (offre gratuite). ⚠️ **Sur l'offre gratuite, le disque n'est pas persistant** : à chaque redémarrage, déploiement ou réveil après 15 min d'inactivité, la base de données **et** le dossier `uploads/` (photos du menu et des profils) sont effacés.

### Sauvegarde gratuite dans un dépôt GitHub privé
1. Sur GitHub : **New repository** → par ex. `ezazozo-sauvegardes`, **Private** (il peut rester vide).
2. Jeton : *Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate* : **Only select repositories** → ce dépôt ; permission **Contents : Read and write** uniquement ; expiration la plus longue (notez la date pour le renouveler).
3. Sur Render → service `eza-zozo-api` → *Environment* : `BACKUP_GITHUB_REPO` = `votre-compte/ezazozo-sauvegardes`, `BACKUP_GITHUB_TOKEN` = le jeton.
4. Les journaux Render doivent afficher « sauvegarde GitHub active » puis « sauvegarde envoyée ».

Fonctionnement : au démarrage, la dernière sauvegarde est restaurée (jamais par-dessus une base non vide) ; ensuite, la base est envoyée au plus toutes les 60 s après un changement, toutes les 15 min et à l'arrêt du serveur ; les photos nouvelles sont envoyées une par une. Limites : jusqu'à ~60 s d'écritures perdues en cas d'arrêt brutal, et quelques secondes lors d'un redéploiement. Pour revenir à une version antérieure : remettre l'ancien `ezazozo/eza_zozo.db` en dernier commit du dépôt, puis redémarrer le service. C'est une solution gratuite de secours ; pour une exploitation sérieuse, préférez un disque persistant (offre payante Render) ou une base hébergée.

### Garder le serveur éveillé
La tâche GitHub `keep-alive` n'est pas fiable (GitHub espace les tâches planifiées de plusieurs heures). Utilisez plutôt **UptimeRobot** (gratuit, sans carte bancaire) : *Add New Monitor* → type **HTTP(s)** → URL `https://eza-zozo-api-5fib.onrender.com/api/health` → intervalle **5 minutes**.

### Avant la mise en service réelle
- `PAYMENT_PROVIDER=paygate` (ou kadev) et **retirer `ALLOW_SIMULATION`** : en simulation, n'importe quel client peut valider lui-même son paiement.
- Sauvegarde configurée (ci-dessus) ou disque persistant.
- `ADMIN_PASSWORD` fort ; `JWT_SECRET` généré par Render.
- Google Play : la CI produit aussi le fichier **AAB** (artefact `kaleta-aab`) exigé pour la publication ; chaque build porte un numéro de version croissant (`--build-number`) ; l'APK de production n'autorise que HTTPS (HTTP réservé aux builds de développement).

## 9. Publication sur Google Play et l'App Store

Le même code Flutter produit les deux applications. Les builds se font sur les serveurs de GitHub (onglet **Actions**) : aucun Mac n'est nécessaire.

### Android — Google Play
1. Compte **Google Play Console** au nom du restaurant (25 $, une fois). Préférez un compte « Organisation » (numéro D-U-N-S gratuit) : un compte personnel impose 14 jours de test fermé avec 12 testeurs avant la publication.
2. Créer l'application `com.kaleta.app`, remplir la fiche (icône, captures, description), le formulaire **Sécurité des données** (téléphone, position, photos) et le lien de confidentialité `https://eza-zozo-api-5fib.onrender.com/legal/confidentialite`.
3. Envoyer à la main la **première** version : le fichier `app-release.aab` de l'artefact `kaleta-aab` (workflow *Build APK*). Activer « Play App Signing » (Google garde la clé de distribution ; la clé de la CI sert de clé d'importation).
4. Ensuite, automatique : créer un compte de service Google Cloud, l'inviter dans la Play Console, et mettre sa clé JSON dans le secret GitHub `PLAY_SERVICE_ACCOUNT_JSON`. Chaque build part alors dans la piste **Tests internes** (brouillon) ; on le promeut en production depuis la console. Examen par Google : quelques heures à quelques jours.

### iPhone — App Store
1. Compte **Apple Developer** au nom du restaurant (99 $ par an ; organisation : numéro D-U-N-S).
2. App Store Connect → **Mes apps → +** : nouvelle app, identifiant `com.kaleta.app` (créé d'abord dans developer.apple.com → Identifiers, avec « Push Notifications » coché si Firebase est utilisé).
3. App Store Connect → Utilisateurs et accès → Intégrations → **Clés API** : créer une clé (rôle Admin), télécharger le fichier `.p8`.
4. Secrets GitHub : `APPLE_TEAM_ID`, `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID`, `APPSTORE_API_PRIVATE_KEY` (contenu du `.p8`). Facultatif : `GOOGLE_SERVICE_INFO_PLIST` (Firebase, app iOS) pour les notifications, avec la clé APNs (`.p8` « Apple Push Notifications ») déposée dans Firebase → Paramètres → Cloud Messaging.
5. Le workflow **Build iOS** signe l'app (signature automatique gérée par Apple) et l'envoie sur **TestFlight**. Sans ces secrets, il vérifie seulement que l'app iOS compile.
6. TestFlight : installer sur des iPhone de test (app TestFlight), puis **Soumettre pour examen** avec captures (iPhone 6,7"), description, confidentialité, et un **compte de démonstration** (client et admin) pour l'examinateur. Examen Apple : 1 à 3 jours, souvent avec des allers-retours.

**Différences iPhone** : pas de « Partager → KALETA » depuis Google Maps (le client place sa position sur la carte ou colle le lien) ; le suivi du livreur ne fonctionne qu'app ouverte (les livreurs utilisent Android) ; les notifications exigent Firebase + clé APNs.

## API (résumé)

| Méthode | Route | Accès |
|---|---|---|
| POST | `/api/auth/register` (`accept_terms` obligatoire), `/api/auth/login`, `/api/auth/otp/request`, `/api/auth/otp/verify`, `/api/auth/password/forgot`, `/api/auth/password/reset` | public |
| GET | `/api/legal`, `/legal/cgu`, `/legal/confidentialite` | public |
| POST/DELETE | `/api/push/token` | connecté |
| GET/POST | `/api/admin/password-resets` · POST `/api/admin/password-resets/:id/done` | admin |
| GET/PUT/DELETE | `/api/auth/me` · PUT `/me/password` · POST/DELETE `/me/avatar` · GET `/me/stats` · `/me/addresses[/:id]` | connecté |
| GET | `/api/settings`, `/api/categories`, `/api/products` | public |
| POST/GET | `/api/orders` · GET `/api/orders/:id` · POST `/api/orders/:id/cancel` | client |
| POST | `/api/orders/:id/payments` · GET `/payments/current` · POST `/payments/current/abandon` · `/payments/current/simulate` | client |
| GET/POST | `/api/admin/payments/review` · `/api/admin/payments/:id/validate` · `/:id/reject` · `/api/admin/payments/recent` · `/merchant` · POST `/reconcile` | admin |
| GET/POST | `/api/driver/orders?scope=` (available, mine, history) · POST `/api/driver/orders/:id/take` · `/delivered` · `/release` · GET `/api/driver/stats` | livreur |
| POST | `/api/orders/:id/received` | client |
| POST | `/api/driver/location` (position pendant une livraison) | livreur |
| GET | `/api/delivery/quote?lat=&lng=&zone_id=` (frais de livraison ; mode zone : `zone_id`, `zone_name`) · `/api/delivery/zones` (zones actives) | public |
| GET/POST/PUT/DELETE | `/api/admin/delivery-zones[/:id]` (zone utilisée par une commande : désactivée au lieu d'être supprimée) | gérant |
| POST | `/api/admin/counter-orders` (vente au comptoir : espèces → en cuisine directement ; Flooz/Mixx → le caissier lance le push avec `/api/orders/:id/payments`) | admin |
| GET | `/api/admin/reports?from=&to=` (synthèse par période, 366 jours max) · `/api/admin/reports/export.csv` (une ligne par commande, « ; », UTF-8 avec BOM) | gérant |
| GET | `/api/geo/reverse?lat=&lng=`, `/api/geo/route?from=lat,lng&to=lat,lng` (cache) | connecté |
| POST | `/api/orders/:id/payment-method` (Flooz ↔ Mixx avant le paiement) | client |
| POST | `/api/client-errors` (plantages de l'app) | public |
| GET | `/api/admin/errors?source=` · GET/POST/PATCH/DELETE `/api/admin/staff[/:id]` (gérants : propriétaire seulement) | gérant |
| GET/POST/PATCH | `/api/admin/drivers[/:id]` · PATCH `/api/admin/orders/:id/assign` | admin |
| GET/POST | `/api/admin/collections` · `/collections/export.csv` · POST `/api/admin/settlements` · POST `/api/admin/orders/:id/refund` | admin |
| GET | `/api/admin/stats` (dont `by_channel_today`), `/api/admin/orders?status=&source=` (app ou counter), `/api/admin/users`, `/api/admin/monitoring`, `/api/admin/audit` | admin |
| PATCH | `/api/admin/orders/:id/status` (pas de cuisine avant paiement mobile money) | admin |
| POST/PUT/DELETE | `/api/admin/products[/:id]` (`pack_items: [{product_id, quantity}]` pour un pack), `/api/admin/categories[/:id]` · POST `/api/admin/upload` · PUT `/api/admin/settings` | admin |
| POST | `/api/payments/paygate/webhook`, `/api/payments/kadev/webhook` | prestataires |

« admin » = tout le personnel ; « gérant » = niveau Gérant seulement. Réservés au gérant : statistiques, rapports, zones de livraison, réglages, menu (création/modification), clients, paiements, encaissements, remboursements, surveillance, audit, mots de passe oubliés, personnel, erreurs.

Les prix et montants sont toujours recalculés par le serveur à partir du catalogue.
