# VICC Praxisarbeit – Container-PaaS auf Azure

Pendenzen- und Störungsverwaltung (Weboberfläche und REST-API) als Docker-Container
auf **Azure App Service (Linux)** mit
**Azure Database for PostgreSQL – Flexible Server** als Backend. Die Datenbank
ist ausschliesslich privat erreichbar (VNet-Integration + delegiertes Subnetz +
Private DNS Zone, `public_network_access_enabled = false`). Die gesamte
Infrastruktur wird mit Terraform erstellt und wieder abgebaut.

```
Internet ──HTTPS──> App Service (Linux, B1) ── Container patrikzauggipso/vicc-api:3.0.0
                         │ VNet-Integration (snet-app, 10.20.1.0/24)
                         ▼
                    VNet 10.20.0.0/16 ── Private DNS Zone *.private.postgres.database.azure.com
                         │
                         ▼
                    PostgreSQL Flexible Server (B_Standard_B1ms, snet-db 10.20.2.0/24, kein Public Access)
```

## Repository-Struktur

| Pfad | Inhalt |
|---|---|
| `app/app.py` | Flask-Anwendung: Oberfläche (`/`), `/health`, `/stats`, `/tasks` CRUD, Formular-Routen `/ui/...` |
| `app/requirements.txt` | Flask, psycopg2-binary, gunicorn |
| `app/Dockerfile` | `python:3.12-slim`, Nicht-root-User, `HEALTHCHECK`, gunicorn |
| `app/.env.example` | Vorlage für lokalen Container-Test |
| `terraform/versions.tf` | Terraform-/Provider-Versionen, Provider-Konfiguration |
| `terraform/main.tf` | Resource Group, Namens-Suffix |
| `terraform/network.tf` | VNet, 2 delegierte Subnetze, Private DNS Zone + VNet-Link |
| `terraform/database.tf` | PostgreSQL Flexible Server + Datenbank |
| `terraform/appservice.tf` | App Service Plan + Linux Web App |
| `terraform/variables.tf` / `outputs.tf` | Variablen / Outputs |
| `terraform/terraform.tfvars.example` | Vorlage ohne echte Werte |

## API

| Methode | Pfad | Beschreibung | Status |
|---|---|---|---|
| GET | `/` | Oberfläche: Erfassung, Filter, Auswertung, Liste (Browser) | 200 |
| GET | `/health` | prüft DB-Verbindung | 200 / 503 |
| GET | `/stats` | Kennzahlen nach Status und Kategorie | 200 |
| GET | `/tasks` | alle Meldungen, optional `?status=` / `?prio=` | 200 |
| POST | `/tasks` | `{"title": "...", "category": "...", "priority": "...", "status": "...", "reporter": "..."}` | 201 / 400 |
| GET | `/tasks/{id}` | eine Meldung | 200 / 404 |
| PUT | `/tasks/{id}` | einzelne Felder, z. B. `{"status": "erledigt"}` | 200 / 400 / 404 |
| DELETE | `/tasks/{id}` | Meldung löschen | 204 / 404 |
| POST | `/ui/meldungen` | Formular: Meldung erfassen | 303 |
| POST | `/ui/meldungen/{id}/status` | Formular: Status weiterschalten | 303 |
| POST | `/ui/meldungen/{id}/loeschen` | Formular: Meldung löschen | 303 |

Konfiguration über Umgebungsvariablen: `DB_HOST`, `DB_PORT`, `DB_NAME`,
`DB_USER`, `DB_PASSWORD`, `DB_SSLMODE`, optional `PORT` (Default 8000).
Die Tabelle `tasks` wird beim ersten Zugriff automatisch angelegt und um die Felder
`category`, `priority`, `status` und `reporter` ergänzt.

Erlaubte Werte: Kategorie `Netzwerk`, `Hardware`, `Software`, `Konto`, `Sonstiges` ·
Priorität `hoch`, `mittel`, `tief` · Status `offen`, `in Arbeit`, `erledigt`.

---

## Schnellstart (ein Skript)

`scripts/deploy.ps1` führt die Schritte 1–6 unten automatisiert aus
(Docker Desktop starten, Build, lokaler Test, Push, Terraform, End-to-End-Test)
und schreibt ein Protokoll nach `logs/`. Interaktiv sind nur Azure-Login,
Docker-Hub-Token, DB-Passwort und die Bestätigung von `terraform apply`.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
# Varianten
powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1 -SkipLocalTest
powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1 -SkipImage      # Image ist schon auf Docker Hub
powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1 -ImageTag 2.0.1

# Rückbau
powershell -ExecutionPolicy Bypass -File .\scripts\destroy.ps1
```

## Anleitung Schritt für Schritt (Windows PowerShell)

Voraussetzungen: Azure CLI, Docker Desktop, Terraform ≥ 1.6, Git.
Alle Befehle aus dem Repository-Root, sofern nicht anders angegeben.

### 1. Anmelden

```powershell
az login
az account list -o table
az account set --subscription "<SUBSCRIPTION-ID>"
az account show --query "{name:name, id:id}" -o table

# Resource Provider (einmalig pro Subscription)
az provider register --namespace Microsoft.Web
az provider register --namespace Microsoft.DBforPostgreSQL
az provider register --namespace Microsoft.Network

# Docker Hub: Passwort bzw. Access Token wird interaktiv abgefragt
docker login -u patrikzauggipso
```

### 2. Image bauen

```powershell
docker build --platform linux/amd64 `
  -t patrikzauggipso/vicc-api:3.0.0 `
  -t patrikzauggipso/vicc-api:latest `
  ./app
```

### 3. Lokal testen (Postgres im Container)

```powershell
# Test-Passwort interaktiv setzen (nur lokal, nur in dieser Session)
$env:LOCAL_PG_PASSWORD = Read-Host "Lokales Test-Passwort"

docker network create vicc-local
docker run -d --name vicc-pg-local --network vicc-local `
  -e POSTGRES_PASSWORD=$env:LOCAL_PG_PASSWORD -e POSTGRES_DB=tasks `
  postgres:16-alpine

docker run -d --name vicc-api-local --network vicc-local -p 8000:8000 `
  -e DB_HOST=vicc-pg-local -e DB_PORT=5432 -e DB_NAME=tasks `
  -e DB_USER=postgres -e DB_PASSWORD=$env:LOCAL_PG_PASSWORD -e DB_SSLMODE=disable `
  patrikzauggipso/vicc-api:3.0.0

Start-Sleep -Seconds 5
Invoke-RestMethod http://localhost:8000/health
Invoke-RestMethod -Method Post http://localhost:8000/tasks `
  -ContentType "application/json" -Body '{"title":"lokaler Test"}'
Invoke-RestMethod http://localhost:8000/tasks
docker inspect --format "{{.State.Health.Status}}" vicc-api-local   # nach ~30 s: healthy
docker exec vicc-api-local whoami                                    # app (nicht root)

# Aufräumen
docker rm -f vicc-api-local vicc-pg-local
docker network rm vicc-local
```

### 4. Image pushen

```powershell
docker push patrikzauggipso/vicc-api:3.0.0
docker push patrikzauggipso/vicc-api:latest
```

Das Repository auf Docker Hub muss **öffentlich** sein. Bei privatem Repository
einen Read-only Access Token erstellen und in `terraform.tfvars`
(`docker_registry_username` / `docker_registry_password`) eintragen.

### 5. Infrastruktur erstellen

```powershell
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars
# terraform.tfvars öffnen und subscription_id eintragen
notepad terraform.tfvars

# DB-Passwort nur als Umgebungsvariable (nicht in Dateien)
# Anforderungen: 12-128 Zeichen, Gross-/Kleinbuchstaben, Ziffer
$sec = Read-Host "PostgreSQL-Admin-Passwort" -AsSecureString
$env:TF_VAR_postgres_admin_password = [System.Net.NetworkCredential]::new("", $sec).Password

terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
terraform apply          # Plan prüfen, mit "yes" bestätigen (Dauer ca. 10-15 min)
terraform output
```

> Keine Plan-Dateien mit `terraform plan -out=...` erzeugen: Sie enthalten
> Secrets im Klartext. `terraform apply` erstellt und zeigt den Plan selbst.

### 6. End-to-End-Test

Der erste Start dauert einige Minuten (Image-Pull, Container-Start).

```powershell
$URL  = terraform output -raw app_service_url
$APP  = terraform output -raw app_service_name
$RG   = terraform output -raw resource_group_name
$PGFQDN = terraform output -raw postgres_fqdn

# Web-API
Invoke-RestMethod "$URL/health"
Invoke-RestMethod -Method Post "$URL/tasks" -ContentType "application/json" `
  -Body '{"title":"Deployment auf Azure testen"}'
Invoke-RestMethod -Method Post "$URL/tasks" -ContentType "application/json" `
  -Body '{"title":"Dokumentation schreiben","done":false}'
Invoke-RestMethod "$URL/tasks"
Invoke-RestMethod -Method Put "$URL/tasks/1" -ContentType "application/json" -Body '{"done":true}'
Invoke-RestMethod "$URL/tasks/1"
Invoke-RestMethod -Method Delete "$URL/tasks/2"
Invoke-RestMethod "$URL/tasks"

# Alternativ mit curl.exe
curl.exe -s "$URL/health"
curl.exe -s "$URL/tasks"

# Browser
Start-Process $URL

# Nachweis: DB ist nicht öffentlich
az postgres flexible-server show -g $RG -n ($PGFQDN.Split('.')[0]) `
  --query "{public:network.publicNetworkAccess, subnet:network.delegatedSubnetResourceId}" -o jsonc
Resolve-DnsName $PGFQDN          # CNAME auf *.private.postgres.database.azure.com, keine öffentliche IP
Test-NetConnection $PGFQDN -Port 5432   # schlägt von aussen fehl

# VNet-Integration der Web App
az webapp vnet-integration list -g $RG -n $APP -o table

# Container-Logs live
az webapp log tail -g $RG -n $APP
```

### 7. Neues Image ausrollen (optional)

```powershell
# (im Ordner terraform)
docker build --platform linux/amd64 --build-arg APP_VERSION=2.0.1 -t patrikzauggipso/vicc-api:2.0.1 ../app
docker push patrikzauggipso/vicc-api:2.0.1
terraform apply -var "docker_image_tag=2.0.1"
```

### 8. Rückbau

```powershell
terraform destroy        # mit "yes" bestätigen
Remove-Item Env:TF_VAR_postgres_admin_password
az group list --query "[?starts_with(name,'rg-vicc')].name" -o table   # sollte leer sein
```

---

## Git-Hygiene

`.gitignore` schliesst u.a. `terraform.tfvars`, `*.tfstate*`, `.terraform/`,
`.terraform.lock.hcl`, `*.tfplan`, `tfplan`, `.env` und `__pycache__/` aus.

Vor jedem Commit/Push:

```powershell
git status
git diff --cached --name-only
# Darf keine Treffer liefern:
git ls-files | Select-String -Pattern "tfstate|tfvars$|tfplan|\.env$"
```

## Troubleshooting

| Symptom | Prüfung |
|---|---|
| `/health` → 503 | `az webapp log tail …`; DB-Status `az postgres flexible-server show … --query state` |
| App startet nicht (Application Error) | Image öffentlich? `WEBSITES_PORT=8000` gesetzt? Logs prüfen |
| `LocationIsOfferRestricted` bei PostgreSQL | `az postgres flexible-server list-skus -l switzerlandnorth -o table`; ggf. `location` anpassen |
| `MissingSubscriptionRegistration` | Resource Provider registrieren (Schritt 1) |
| Passwort abgelehnt | Anforderungen siehe Schritt 5 |
