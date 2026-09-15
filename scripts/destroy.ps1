<#
.SYNOPSIS
  Rückbau aller Azure-Ressourcen der VICC-Praxisarbeit (terraform destroy).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\destroy.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TfDir    = Join-Path $RepoRoot "terraform"

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [string]$ErrorText)
    $ErrorActionPreference = "Continue"
    Write-Host "  > $Exe $($Arguments -join ' ')" -ForegroundColor DarkGray
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$ErrorText (Exit-Code $LASTEXITCODE)" }
}

if (-not (Test-Path (Join-Path $TfDir "terraform.tfstate"))) {
    Write-Host "Kein terraform.tfstate gefunden - nichts zurückzubauen." -ForegroundColor Yellow
    exit 0
}

# destroy benötigt alle Pflichtvariablen; Wert des Passworts ist hier irrelevant
$setDummy = $false
if (-not $env:TF_VAR_postgres_admin_password) {
    $env:TF_VAR_postgres_admin_password = "Destroy-Only-Placeholder-1"
    $setDummy = $true
}

try {
    $rg = & { $ErrorActionPreference = "Continue"; & terraform "-chdir=$TfDir" output -raw resource_group_name 2>$null }
    Write-Host "Resource Group: $rg" -ForegroundColor Cyan
    Invoke-Native terraform @("-chdir=$TfDir", "destroy", "-input=false") "terraform destroy fehlgeschlagen"
    Write-Host ""
    Write-Host "Verbleibende VICC-Resource-Groups (sollte leer sein):" -ForegroundColor Cyan
    Invoke-Native az @("group", "list", "--query", "[?starts_with(name,'rg-vicc')].name", "-o", "table") "az group list fehlgeschlagen"
}
finally {
    if ($setDummy) { Remove-Item Env:TF_VAR_postgres_admin_password -ErrorAction SilentlyContinue }
}
