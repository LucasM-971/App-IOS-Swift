# MosiMap (ParkSpot)

Application iOS en **Swift / SwiftUI** pour retrouver sa voiture : enregistrement de la place
de stationnement, détection automatique, guidage à pied jusqu'au véhicule, minuteur de
stationnement avec Live Activity et widgets, historique et offre Premium.

Backend : **Supabase** (Postgres + Edge Functions Deno).

---

## Fonctionnalités

- **Enregistrer sa place** : position GPS, étage, note, photo (chiffrée sur l'appareil).
- **Détection automatique** du stationnement et du départ (mouvement, Bluetooth / CarPlay).
- **Guidage** à pied vers la voiture (carte + itinéraire piéton).
- **Minuteur** de stationnement : notifications, Live Activity, Dynamic Island, widgets écran verrouillé.
- **Historique** synchronisé, avec mode hors ligne et rétention selon l'offre.
- **Intelligence** : prédiction de durée, zones fréquentes, zones à risque, suggestions agenda.
- **Siri / Raccourcis** (« Save my car ») et **CarPlay**.
- **Premium** via StoreKit 2 (mensuel / à vie).
- **Compte** : inscription, connexion Apple, réinitialisation du mot de passe, export et
  suppression des données (RGPD).
- Langues : français, anglais, allemand, espagnol.

## Prérequis

| Outil | Version |
|-------|---------|
| Xcode | 26 ou plus (format de projet 77) |
| iOS (app) | 17.6 minimum |
| iOS (tests) | 26.2 (simulateur) |
| Deno | 2.x (backend uniquement) |
| Supabase CLI | pour déployer le backend |

## Démarrage

```bash
git clone https://github.com/LucasM-971/app-IOS-full-Swift-projet-perso-.git
cd app-IOS-full-Swift-projet-perso-
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
```

Renseigner ensuite `Config/Secrets.xcconfig` (fichier ignoré par git) :

| Clé | Description |
|-----|-------------|
| `PARKSPOT_API_URL` | URL des Edge Functions, ex. `https://<projet>.supabase.co/functions/v1` |
| `PARKSPOT_OAUTH_CALLBACK_SCHEME` | Schéma d'URL de retour (par défaut `parkspot`) |
| `PARKSPOT_PREMIUM_*_PRODUCT_ID` | Identifiants des produits StoreKit |

Puis ouvrir `ParkSpot.xcodeproj` et lancer le schéma **ParkSpot**.

En ligne de commande :

```bash
xcodebuild -project ParkSpot.xcodeproj -scheme ParkSpot \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Architecture

Clean Architecture + MVVM, organisée par feature. Le projet Xcode utilise des
**dossiers synchronisés** : un fichier ajouté dans un dossier est compilé automatiquement
dans la bonne cible.

```
ParkSpot/            Cible app
├── App/             Point d'entrée, cycle de vie, DI, navigation, CarPlay, Siri
├── Features/        Auth, Home, Map, Guidance, History, ParkingDetail, Premium, Settings…
├── Domain/          Entités, protocoles, use cases (sans dépendance UI)
├── Data/            Repositories, sources locales/distantes, DTOs, synchronisation
├── Services/        Localisation, détection, notifications, Live Activity, intelligence
├── Platform/        Sécurité (Keychain, AES-GCM), réseau, stockage
├── DesignSystem/    Thème
└── Resources/       Info.plist, entitlements, Assets, traductions
Shared/              Code partagé app + widgets (App Group)
ParkSpotWidgets/     Live Activity + widgets écran verrouillé
ParkSpotTests/       Tests unitaires
ParkSpotUITests/     Tests UI
Backend/supabase/    Edge Functions (auth, parking, history, users, frequent-zones) + SQL
Config/              xcconfig (secrets locaux non versionnés)
docs/                Documentation (voir docs/ARCHITECTURE.md)
scripts/             Outils (scan de secrets)
```

Les règles de dépendance entre couches sont décrites dans [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Sécurité

- L'app ne parle jamais directement à la base : tout passe par les Edge Functions,
  les tables sont fermées aux rôles `anon` / `authenticated`.
- Jetons stockés dans le **Keychain** (`AfterFirstUnlockThisDeviceOnly`).
- Données locales (historique, file de synchro, photos) **chiffrées en AES-GCM**
  avec une clé conservée dans le Keychain, et protégées par la protection de fichiers iOS.
- Rafraîchissement automatique des jetons, épinglage TLS optionnel
  (`PARKSPOT_TLS_PINNED_HOSTS`, `PARKSPOT_TLS_PINNED_CERT_SHA256`).
- Aucun secret dans le dépôt : `Config/Secrets.xcconfig`, `.env`, certificats et
  profils sont ignorés par git, et `scripts/secret_scan.sh` est lancé en CI.

## Backend (Supabase)

```bash
cd Backend/supabase
deno fmt functions && deno lint functions          # qualité
supabase functions deploy auth parking history users frequent-zones
```

Les scripts SQL de `Backend/supabase/sql/` sont appliqués manuellement, dans l'ordre :
`schema.sql`, `hotfix_signup_trigger.sql`, `history_smart_retention.sql`,
`frequent_zones_premium.sql`.

Variables d'environnement des fonctions (à définir dans Supabase, jamais dans le dépôt) :
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `ALLOWED_ORIGINS`.

## Tests et CI

```bash
./scripts/secret_scan.sh
xcodebuild -project ParkSpot.xcodeproj -scheme ParkSpot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ParkSpotTests CODE_SIGNING_ALLOWED=NO test
```

GitHub Actions (`.github/workflows/ios-ci.yml`) :

1. **quality-checks** (Linux) : scan de secrets, `deno fmt`, `deno lint`, test e2e auth
   (ignoré si les secrets `PARKSPOT_E2E_AUTH_*` ne sont pas configurés).
2. **build-and-test** (macOS, Xcode 26) : build simulateur non signé, tests unitaires,
   rapport de couverture.

## Licence

Projet personnel — tous droits réservés.
