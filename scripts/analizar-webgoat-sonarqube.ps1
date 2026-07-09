param(
  [string]$SonarToken = "",
  [string]$ProjectKey = "WebGoat2025",
  [string]$ProjectName = "WebGoat and WebWolf 2025",
  [string]$SonarUrl = "http://localhost:9000",
  [string]$SonarAdminUser = "admin",
  [string]$SonarAdminPassword = "admin",
  [switch]$SkipPrepareProject,
  [string]$MavenImage = "maven:3.9.9-eclipse-temurin-23",
  [string]$ComposeNetwork = "juice-shop-security-lab_security-lab"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Resolve-Path (Join-Path $ScriptDir "..")
$SourceDir = Join-Path $RootDir "WebGoat-2025.3"
$WorkRoot = Join-Path $RootDir ".sonar-work"
$RunId = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$WorkDir = Join-Path $WorkRoot "webgoat-$RunId"

if (-not (Test-Path $SourceDir)) {
  throw "No se encontro WebGoat-2025.3 en: $SourceDir"
}

function New-BasicAuthHeader {
  param(
    [string]$User,
    [string]$Password
  )

  $pair = "$User`:$Password"
  $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
  return @{ Authorization = "Basic $basic" }
}

function Invoke-SonarPost {
  param(
    [string]$Path,
    [hashtable]$Headers,
    [string]$Body
  )

  Invoke-RestMethod `
    -Method Post `
    -Uri "$SonarUrl$Path" `
    -Headers $Headers `
    -Body $Body `
    -ContentType "application/x-www-form-urlencoded" `
    -TimeoutSec 30
}

function Ensure-SonarProject {
  param([hashtable]$Headers)

  $encodedProjectKey = [uri]::EscapeDataString($ProjectKey)
  $projectSearch = Invoke-RestMethod `
    -Uri "$SonarUrl/api/projects/search?projects=$encodedProjectKey" `
    -Headers $Headers `
    -TimeoutSec 30

  if ($projectSearch.components.Count -gt 0) {
    Write-Host "Proyecto SonarQube existente: $ProjectKey"
    return
  }

  Write-Host "Creando proyecto SonarQube: $ProjectKey"
  $body = "project=$encodedProjectKey&name=$([uri]::EscapeDataString($ProjectName))"
  Invoke-SonarPost -Path "/api/projects/create" -Headers $Headers -Body $body | Out-Null
}

function New-SonarAnalysisToken {
  param([hashtable]$Headers)

  $tokenName = "webgoat-analysis-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
  $body = "name=$([uri]::EscapeDataString($tokenName))"
  $result = Invoke-SonarPost -Path "/api/user_tokens/generate" -Headers $Headers -Body $body

  if (-not $result.token) {
    throw "SonarQube no devolvio token."
  }

  Write-Host "Token temporal de analisis generado con el usuario $SonarAdminUser."
  return $result.token
}

if (-not $SkipPrepareProject) {
  try {
    $adminHeaders = New-BasicAuthHeader -User $SonarAdminUser -Password $SonarAdminPassword
    Ensure-SonarProject -Headers $adminHeaders
    $SonarToken = New-SonarAnalysisToken -Headers $adminHeaders
  } catch {
    Write-Warning "No se pudo preparar SonarQube con $SonarAdminUser. Se usara el token recibido. Detalle: $($_.Exception.Message)"
  }
}

if ([string]::IsNullOrWhiteSpace($SonarToken)) {
  throw "Falta token de SonarQube. Usa -SonarToken o permite preparar el proyecto con credenciales admin."
}

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

Write-Host "Copiando WebGoat/WebWolf a carpeta temporal para no modificar el proyecto original ..."
robocopy $SourceDir $WorkDir /MIR /XD target .git .idea .vscode /XF .classpath .project | Out-Null
$robocopyCode = $LASTEXITCODE
if ($robocopyCode -gt 7) {
  throw "Robocopy fallo con codigo $robocopyCode"
}

Write-Host "Ejecutando analisis de WebGoat/WebWolf con Maven + JDK 23 en Docker ..."
docker run --rm `
  --network $ComposeNetwork `
  -v "${WorkDir}:/workspace" `
  -v "webgoat_maven_cache:/root/.m2" `
  -w /workspace `
  $MavenImage `
  mvn -B -P local-server compile sonar:sonar `
    "-DskipTests=true" `
    "-Dmaven.test.skip=true" `
    "-Dspotless.check.skip=true" `
    "-Dcheckstyle.skip=true" `
    "-Dsonar.projectKey=$ProjectKey" `
    "-Dsonar.host.url=http://juice-shop-sonarqube:9000" `
    "-Dsonar.scm.disabled=true" `
    "-Dsonar.login=$SonarToken"

if ($LASTEXITCODE -ne 0) {
  throw "El analisis de WebGoat en SonarQube fallo."
}

Write-Host "Analisis de WebGoat/WebWolf enviado a SonarQube como proyecto: $ProjectKey"
Write-Host "Carpeta temporal usada: $WorkDir"
