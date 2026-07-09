param(
  [int]$TimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Resolve-Path (Join-Path $ScriptDir "..")
$ComposeFile = Join-Path $RootDir "docker-compose.security.yml"
$ProjectName = "juice-shop-security-lab"
$ZapReportDir = Join-Path $RootDir "security-reports\zap"
$ComposeExe = $null
$ComposePrefixArgs = @()

function Test-ComposeCommand {
  param(
    [string]$Exe,
    [string[]]$PrefixArgs = @()
  )

  try {
    & $Exe @PrefixArgs version *> $null
    return $LASTEXITCODE -eq 0
  } catch {
    return $false
  }
}

function Resolve-ComposeCommand {
  if (Test-ComposeCommand -Exe "docker" -PrefixArgs @("compose")) {
    $script:ComposeExe = "docker"
    $script:ComposePrefixArgs = @("compose")
    return
  }

  if ((Get-Command docker-compose -ErrorAction SilentlyContinue) -and (Test-ComposeCommand -Exe "docker-compose")) {
    $script:ComposeExe = "docker-compose"
    $script:ComposePrefixArgs = @()
    return
  }

  throw "Docker Compose no esta disponible. Instala Docker Desktop o habilita 'docker compose'/'docker-compose'."
}

function Invoke-Compose {
  & $ComposeExe @ComposePrefixArgs -p $ProjectName -f $ComposeFile @args
  if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose fallo: $($args -join ' ')"
  }
}

function Wait-ForJuiceShop {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Write-Host "Esperando Juice Shop en http://localhost:3000 ..."

  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:3000" -TimeoutSec 5
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
        Write-Host "Juice Shop esta listo."
        return
      }
    } catch {
      Start-Sleep -Seconds 5
    }
  }

  throw "Juice Shop no estuvo listo despues de $TimeoutSeconds segundos."
}

function Wait-ForWebGoat {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Write-Host "Esperando WebGoat en http://localhost:8082/WebGoat ..."

  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8082/WebGoat" -TimeoutSec 5
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
        Write-Host "WebGoat esta listo."
        return
      }
    } catch {
      Start-Sleep -Seconds 5
    }
  }

  throw "WebGoat no estuvo listo despues de $TimeoutSeconds segundos."
}

function Wait-ForSonarQube {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Write-Host "Esperando SonarQube en http://localhost:9000 ..."

  while ((Get-Date) -lt $deadline) {
    try {
      $status = Invoke-RestMethod -Uri "http://localhost:9000/api/system/status" -TimeoutSec 5
    } catch {
      Start-Sleep -Seconds 5
      continue
    }

    if ($status.status -eq "UP") {
      Write-Host "SonarQube esta listo."
      return
    }

    if ($status.status -eq "DB_MIGRATION_NEEDED") {
      throw "SonarQube requiere migracion de base de datos. Revisa http://localhost:9000/setup"
    }

    Start-Sleep -Seconds 5
  }

  throw "SonarQube no estuvo listo despues de $TimeoutSeconds segundos."
}

function Wait-ForZapUi {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Write-Host "Esperando ZAP Web UI en http://localhost:8081/zap ..."

  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:8081/zap" -TimeoutSec 5
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
        Write-Host "ZAP Web UI esta lista."
        return
      }
    } catch {
      Start-Sleep -Seconds 5
    }
  }

  Write-Warning "ZAP Web UI no respondio despues de $TimeoutSeconds segundos. Revisa logs con: docker logs juice-shop-zap"
}

New-Item -ItemType Directory -Force -Path $ZapReportDir | Out-Null

Write-Host "Validando Docker Compose ..."
Resolve-ComposeCommand

Write-Host "Levantando Juice Shop, WebGoat, SonarQube, PostgreSQL y ZAP ..."
Invoke-Compose up -d sonar-db sonarqube juice-shop webgoat zap

Wait-ForJuiceShop
Wait-ForWebGoat
Wait-ForSonarQube
Wait-ForZapUi

Write-Host ""
Write-Host "Servicios levantados. Los escaneos se ejecutan manualmente desde cada herramienta."
Write-Host "Juice Shop: http://localhost:3000"
Write-Host "WebGoat:    http://localhost:8082/WebGoat"
Write-Host "WebWolf:    http://localhost:9092/WebWolf"
Write-Host "SonarQube:  http://localhost:9000"
Write-Host "ZAP UI:     http://localhost:8081/zap"
Write-Host "ZAP Proxy:  localhost:8090"
Write-Host "ZAP API:    http://localhost:8090/JSON/core/view/version/"
Write-Host "Reportes ZAP: $ZapReportDir"
