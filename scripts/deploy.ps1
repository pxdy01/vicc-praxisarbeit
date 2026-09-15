<#
.SYNOPSIS
  End-to-End-Deployment der VICC-Praxisarbeit: Docker-Image bauen, lokal testen,
  nach Docker Hub pushen, Azure-Infrastruktur mit Terraform erstellen, API testen.

.DESCRIPTION
  Interaktiv sind nur: Azure-Anmeldung (Browser), Docker-Hub-Token, DB-Passwort,
  Bestätigung von "terraform apply". Ein Protokoll wird unter logs\ abgelegt.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1 -SkipLocalTest
  powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1 -SkipImage     # nur Infrastruktur + Test
#>
[CmdletBinding()]
param(
    [string]$DockerUser    = "patrikzauggipso",
    [string]$ImageName     = "vicc-api",
    [string]$ImageTag      = "2.0.0",
    [string]$SubscriptionId,
    [switch]$SkipImage,       # Build/Test/Push überspringen (Image bereits auf Docker Hub)
    [switch]$SkipLocalTest,   # lokalen Container-Test überspringen
    [switch]$SkipInfra        # nur Image, keine Azure-Ressourcen
)

$ErrorActionPreference = "Stop"
$failed = $false
$RepoRoot = Split-Path -Parent $PSScriptRoot
$AppDir   = Join-Path $RepoRoot "app"
$TfDir    = Join-Path $RepoRoot "terraform"
$Image    = "$DockerUser/${ImageName}:$ImageTag"
$ImageLatest = "$DockerUser/${ImageName}:latest"

$LogDir = Join-Path $RepoRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("deploy-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile | Out-Null

# ------------------------------------------------------------------ #
# Hilfsfunktionen
# ------------------------------------------------------------------ #
function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "  [..]   $Text" -ForegroundColor Gray }
function Write-Warn([string]$Text) { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }

# Führt ein externes Programm aus und bricht bei Exit-Code <> 0 ab
# (lokal EAP=Continue: Windows PowerShell 5.1 wertet stderr sonst als Fehler)
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [string]$ErrorText)
    $ErrorActionPreference = "Continue"
    Write-Host "  > $Exe $($Arguments -join ' ')" -ForegroundColor DarkGray
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$ErrorText (Exit-Code $LASTEXITCODE)" }
}

# Externes Programm ohne Fehlerausgabe; liefert stdout, Exit-Code in $LASTEXITCODE
function Invoke-Silent {
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = "Continue"
    & $Exe @Arguments 2>$null
}

function Test-DockerEngine {
    $null = Invoke-Silent docker @("info", "--format", "{{.ServerVersion}}")
    return ($LASTEXITCODE -eq 0)
}

# JSON-Request mit UTF-8-Body (5.1 sendet Strings sonst als ISO-8859-1)
function Invoke-Json {
    param([string]$Method, [string]$Url, [hashtable]$Body)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
    Invoke-RestMethod -Method $Method -Uri $Url -Body $bytes -ContentType "application/json; charset=utf-8"
}

function Start-DockerEngine {
    if (Test-DockerEngine) { Write-Ok "Docker-Engine läuft"; return }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\Docker Desktop.exe"),
        (Join-Path $env:ProgramFiles  "Docker\Docker\Docker Desktop.exe")
    )
    $exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) { throw "Docker Desktop nicht gefunden. Bitte manuell starten." }

    Write-Info "Starte Docker Desktop ($exe) ..."
    Start-Process -FilePath $exe | Out-Null
    $deadline = (Get-Date).AddMinutes(4)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Test-DockerEngine) { Write-Ok "Docker-Engine läuft"; return }
        Write-Info "warte auf Docker-Engine ..."
    }
    throw "Docker-Engine nicht erreichbar. Docker Desktop öffnen und Status prüfen (Troubleshoot > Restart)."
}

function Test-TcpPort([string]$HostName, [int]$Port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(5000) -and $client.Connected
        $client.Close()
        return $ok
    } catch { return $false }
}

function Wait-HttpOk([string]$Url, [int]$TimeoutMinutes) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20
            if ($r.StatusCode -eq 200) { return $true }
        } catch {
            $code = $null
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            Write-Info ("noch nicht bereit ({0}) ..." -f $(if ($code) { "HTTP $code" } else { $_.Exception.Message }))
        }
        Start-Sleep -Seconds 15
    }
    return $false
}

function Invoke-ApiTests([string]$BaseUrl) {
    $h = Invoke-RestMethod "$BaseUrl/health"
    Write-Ok "GET  /health        -> status=$($h.status), db=$($h.database), pg=$($h.db_version)"

    $t1 = Invoke-Json Post "$BaseUrl/tasks" @{ title = "Deployment testen ($(Get-Date -Format 'HH:mm:ss'))" }
    Write-Ok "POST /tasks         -> id=$($t1.id), title='$($t1.title)'"

    $t2 = Invoke-Json Post "$BaseUrl/tasks" @{ title = "Temporärer Task"; done = $false }
    Write-Ok "POST /tasks         -> id=$($t2.id)"

    $u = Invoke-Json Put "$BaseUrl/tasks/$($t1.id)" @{ done = $true }
    Write-Ok "PUT  /tasks/$($t1.id)       -> done=$($u.done)"

    $g = Invoke-RestMethod "$BaseUrl/tasks/$($t1.id)"
    Write-Ok "GET  /tasks/$($t1.id)       -> done=$($g.done)"

    Invoke-RestMethod -Method Delete "$BaseUrl/tasks/$($t2.id)" | Out-Null
    Write-Ok "DELETE /tasks/$($t2.id)     -> 204"

    $all = @(Invoke-RestMethod "$BaseUrl/tasks")
    Write-Ok "GET  /tasks         -> $($all.Count) Task(s)"
    $all | Format-Table -Property @("id", "title", "done", "created_at") -AutoSize | Out-Host

    $page = Invoke-WebRequest -Uri "$BaseUrl/" -UseBasicParsing
    if ($page.Content -match "VICC Task-API") { Write-Ok "GET  /  (HTML)      -> $($page.StatusCode)" }
    else { throw "HTML-Startseite liefert unerwarteten Inhalt" }
}

# ------------------------------------------------------------------ #
try {
    Set-Location $RepoRoot

    Write-Step "0/6 Voraussetzungen"
    foreach ($tool in @("az", "docker", "terraform", "git")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "'$tool' nicht gefunden (PATH prüfen)."
        }
        Write-Ok "$tool gefunden"
    }

    # -------------------------------------------------------------- #
    if (-not $SkipImage) {
        Write-Step "1/6 Docker-Engine & Docker Hub"
        Start-DockerEngine

        if (Test-TcpPort "registry-1.docker.io" 443) {
            Write-Ok "registry-1.docker.io:443 erreichbar"
        } else {
            Write-Warn "registry-1.docker.io:443 NICHT erreichbar."
            Write-Warn "Aktives VPN (z.B. Sophos Connect) trennen oder anderes Netz verwenden."
            throw "Docker Hub nicht erreichbar"
        }

        Write-Info "Docker-Hub-Login: bei 'Password' den Personal Access Token eingeben"
        Invoke-Native docker @("login", "-u", $DockerUser) "Docker-Hub-Login fehlgeschlagen"

        Write-Step "2/6 Image bauen ($Image)"
        Invoke-Native docker @("build", "--platform", "linux/amd64",
                               "--build-arg", "APP_VERSION=$ImageTag",
                               "-t", $Image, "-t", $ImageLatest, $AppDir) "Docker-Build fehlgeschlagen"
        $user = Invoke-Silent docker @("image", "inspect", $Image, "--format", "{{.Config.User}}")
        Write-Ok "Image gebaut, Container-User: $user"

        if (-not $SkipLocalTest) {
            Write-Step "3/6 Lokaler Test (Postgres + API im Docker-Netz)"
            # Wegwerf-Passwort nur für den lokalen Testcontainer, wird nicht angezeigt
            $localPw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
            $net = "vicc-local"
            Invoke-Silent docker @("rm", "-f", "vicc-api-local", "vicc-pg-local") | Out-Null
            Invoke-Silent docker @("network", "rm", $net) | Out-Null
            try {
                Invoke-Native docker @("network", "create", $net) "Docker-Netz fehlgeschlagen"
                Invoke-Native docker @("run", "-d", "--name", "vicc-pg-local", "--network", $net,
                                       "-e", "POSTGRES_PASSWORD=$localPw", "-e", "POSTGRES_DB=tasks",
                                       "postgres:16-alpine") "Postgres-Container fehlgeschlagen"
                Invoke-Native docker @("run", "-d", "--name", "vicc-api-local", "--network", $net,
                                       "-p", "8000:8000",
                                       "-e", "DB_HOST=vicc-pg-local", "-e", "DB_PORT=5432", "-e", "DB_NAME=tasks",
                                       "-e", "DB_USER=postgres", "-e", "DB_PASSWORD=$localPw",
                                       "-e", "DB_SSLMODE=disable", $Image) "API-Container fehlgeschlagen"

                if (-not (Wait-HttpOk "http://localhost:8000/health" 2)) {
                    Invoke-Silent docker @("logs", "vicc-api-local")
                    throw "Lokaler /health-Check nicht erfolgreich"
                }
                Invoke-ApiTests "http://localhost:8000"
                Write-Info "warte auf Docker-HEALTHCHECK ..."
                Start-Sleep -Seconds 35
                $hs = Invoke-Silent docker @("inspect", "--format", "{{.State.Health.Status}}", "vicc-api-local")
                Write-Ok "Docker-Healthcheck: $hs"
                $who = Invoke-Silent docker @("exec", "vicc-api-local", "whoami")
                Write-Ok "Prozess läuft als: $who"
            } finally {
                Invoke-Silent docker @("rm", "-f", "vicc-api-local", "vicc-pg-local") | Out-Null
                Invoke-Silent docker @("network", "rm", $net) | Out-Null
                $localPw = $null
            }
        }

        Write-Step "4/6 Image pushen"
        Invoke-Native docker @("push", $Image) "Push fehlgeschlagen"
        Invoke-Native docker @("push", $ImageLatest) "Push (latest) fehlgeschlagen"
        Write-Ok "Gepusht: $Image"
        Write-Warn "Repository auf hub.docker.com muss 'Public' sein (sonst Token in terraform.tfvars)."
    }

    if ($SkipInfra) { Write-Ok "Fertig (ohne Infrastruktur)."; return }

    # -------------------------------------------------------------- #
    Write-Step "5/6 Azure & Terraform"
    $null = Invoke-Silent az @("account", "show")
    if ($LASTEXITCODE -ne 0) {
        Write-Info "Azure-Anmeldung im Browser ..."
        Invoke-Native az @("login") "az login fehlgeschlagen"
    }

    if (-not $SubscriptionId) {
        $subs = @((Invoke-Silent az @("account", "list", "--query", "[?state=='Enabled'].{name:name,id:id}", "-o", "json")) -join "`n" | ConvertFrom-Json)
        if ($subs.Count -eq 0) { throw "Keine aktive Azure-Subscription gefunden." }
        if ($subs.Count -eq 1) {
            $SubscriptionId = $subs[0].id
        } else {
            for ($i = 0; $i -lt $subs.Count; $i++) { Write-Host ("  [{0}] {1}  ({2})" -f $i, $subs[$i].name, $subs[$i].id) }
            $sel = Read-Host "  Nummer der Subscription"
            $SubscriptionId = $subs[[int]$sel].id
        }
    }
    Invoke-Native az @("account", "set", "--subscription", $SubscriptionId) "Subscription setzen fehlgeschlagen"
    $subName = Invoke-Silent az @("account", "show", "--query", "name", "-o", "tsv")
    Write-Ok "Subscription: $subName"

    foreach ($ns in @("Microsoft.Web", "Microsoft.DBforPostgreSQL", "Microsoft.Network")) {
        $state = Invoke-Silent az @("provider", "show", "--namespace", $ns, "--query", "registrationState", "-o", "tsv")
        if ($state -ne "Registered") {
            Write-Info "registriere $ns ..."
            Invoke-Native az @("provider", "register", "--namespace", $ns, "--wait") "Provider-Registrierung $ns fehlgeschlagen"
        }
        Write-Ok "$ns registriert"
    }

    # terraform.tfvars ohne Secrets anlegen/aktualisieren
    $tfvars = Join-Path $TfDir "terraform.tfvars"
    $content = @"
# Automatisch erzeugt von scripts/deploy.ps1 - nicht committen (.gitignore)
subscription_id  = "$SubscriptionId"
location         = "switzerlandnorth"
docker_image     = "$DockerUser/$ImageName"
docker_image_tag = "$ImageTag"
"@
    [System.IO.File]::WriteAllText($tfvars, $content, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "terraform.tfvars geschrieben (ohne Passwort)"

    if (-not $env:TF_VAR_postgres_admin_password) {
        Write-Info "PostgreSQL-Admin-Passwort festlegen (12-128 Zeichen, Gross-/Kleinbuchstaben, Ziffer)"
        while ($true) {
            $p1 = Read-Host "  DB-Passwort" -AsSecureString
            $p2 = Read-Host "  DB-Passwort wiederholen" -AsSecureString
            $s1 = [System.Net.NetworkCredential]::new("", $p1).Password
            $s2 = [System.Net.NetworkCredential]::new("", $p2).Password
            if ($s1 -ne $s2) { Write-Warn "Passwörter stimmen nicht überein."; continue }
            if ($s1.Length -lt 12 -or $s1 -cnotmatch "[A-Z]" -or $s1 -cnotmatch "[a-z]" -or $s1 -notmatch "[0-9]") {
                Write-Warn "Anforderungen nicht erfüllt."; continue
            }
            $env:TF_VAR_postgres_admin_password = $s1
            $s1 = $null; $s2 = $null
            break
        }
    }

    Invoke-Native terraform @("-chdir=$TfDir", "init", "-input=false", "-upgrade") "terraform init fehlgeschlagen"
    Invoke-Silent terraform @("-chdir=$TfDir", "fmt", "-recursive") | Out-Null
    Invoke-Native terraform @("-chdir=$TfDir", "validate") "terraform validate fehlgeschlagen"
    Write-Info "Plan wird angezeigt - mit 'yes' bestätigen (Dauer ca. 10-15 Minuten)"
    Invoke-Native terraform @("-chdir=$TfDir", "apply", "-input=false") "terraform apply fehlgeschlagen"

    $url    = Invoke-Silent terraform @("-chdir=$TfDir", "output", "-raw", "app_service_url")
    $app    = Invoke-Silent terraform @("-chdir=$TfDir", "output", "-raw", "app_service_name")
    $rg     = Invoke-Silent terraform @("-chdir=$TfDir", "output", "-raw", "resource_group_name")
    $pgfqdn = Invoke-Silent terraform @("-chdir=$TfDir", "output", "-raw", "postgres_fqdn")
    Invoke-Silent terraform @("-chdir=$TfDir", "output")

    # -------------------------------------------------------------- #
    Write-Step "6/6 End-to-End-Test gegen Azure ($url)"
    Write-Info "Erster Container-Start kann einige Minuten dauern ..."
    if (-not (Wait-HttpOk "$url/health" 15)) {
        Write-Warn "App nicht bereit. Logs: az webapp log tail -g $rg -n $app"
        throw "Azure /health nicht erfolgreich"
    }
    Invoke-ApiTests $url

    Write-Info "Netzwerk-Nachweis PostgreSQL:"
    $pgName = $pgfqdn.Split(".")[0]
    Invoke-Silent az @("postgres", "flexible-server", "show", "-g", $rg, "-n", $pgName,
        "--query", "{publicNetworkAccess:network.publicNetworkAccess, delegatedSubnet:network.delegatedSubnetResourceId, privateDnsZone:network.privateDnsZoneArmResourceId}",
        "-o", "jsonc")
    Invoke-Silent az @("webapp", "vnet-integration", "list", "-g", $rg, "-n", $app, "--query", "[].{name:name, subnet:vnetResourceId}", "-o", "table")
    if (Test-TcpPort $pgfqdn 5432) { Write-Warn "PostgreSQL von aussen erreichbar?!" }
    else { Write-Ok "PostgreSQL von aussen NICHT erreichbar (erwartet)" }

    Write-Step "Fertig"
    Write-Ok "App:  $url"
    Write-Ok "API:  $url/tasks"
    Write-Info "Rückbau: powershell -ExecutionPolicy Bypass -File .\scripts\destroy.ps1"
    Start-Process $url
}
catch {
    $failed = $true
    Write-Host ""
    Write-Host "FEHLER: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
    Write-Host "Protokoll: $LogFile" -ForegroundColor DarkGray
}
if ($failed) { exit 1 }
