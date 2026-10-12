#requires -Version 5.1
<#
.SYNOPSIS
  Completa C:\SIG\SIGDesk\config\<svc>.env para los 7 servicios de SIG-Desk (v0.2.0+).

.DESCRIPTION
  Requiere PowerShell como Administrador (config\ solo la leen SYSTEM y Administradores).
  Sin -Apply es un dry-run: dice qué claves pondría en cada archivo, sin escribir nada.

  - Reutiliza los valores que ya existen (nunca pisa un secreto ya configurado).
  - JWT_SECRET y TICKETS_INTERNAL_SECRET: se toman de los archivos existentes (deben ser
    iguales en todos los servicios); si faltan en todos, aborta (los define el operador).
  - ORGANIZATION/RESOURCE/CHANGE_INTERNAL_SECRET: si no existen en ningún archivo, se generan
    una vez (48 caracteres aleatorios) y se escriben IGUALES en todos los que los usan.
  - URLs entre servicios: siempre 127.0.0.1:1808x (en el MKS 8080/8082 son de otros programas).
  - URLs de base de datos: se derivan de DATABASE_URL de organization.env cambiando solo el nombre
    de la base (sigdesk_<svc>_local).
  - Antes de escribir, copia config\ a config\backup-<fecha>\. Nunca imprime valores.
#>
[CmdletBinding()]
param(
  [string]$ConfigDir = 'C:\SIG\SIGDesk\config',
  [string]$SigToolsUrl = 'https://api.sig.systems:8091',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'

$Ports = @{ tickets = 18080; organization = 18081; resource = 18082; workflow = 18083; notification = 18084; change = 18087; problem = 18088 }
function Url($svc) { return "http://127.0.0.1:$($Ports[$svc])" }

# Claves por servicio. 'secret:<NOMBRE>' = secreto compartido; 'db:<base>' = URL de base derivada.
$Spec = [ordered]@{
  organization = [ordered]@{ DATABASE_URL = 'db:organization'; KAFKA_BROKERS = 'localhost:9092'; LOG_LEVEL = 'info'
                             JWT_SECRET = 'secret:JWT_SECRET'; ORGANIZATION_INTERNAL_SECRET = 'secret:ORGANIZATION_INTERNAL_SECRET'
                             SIGTOOLS_API_URL = $SigToolsUrl }
  resource     = [ordered]@{ DATABASE_URL = 'db:resource'; KAFKA_BROKERS = 'localhost:9092'; LOG_LEVEL = 'info'
                             JWT_SECRET = 'secret:JWT_SECRET'; RESOURCE_INTERNAL_SECRET = 'secret:RESOURCE_INTERNAL_SECRET'
                             ORGANIZATION_INTERNAL_SECRET = 'secret:ORGANIZATION_INTERNAL_SECRET'; ORGANIZATION_SERVICE_URL = (Url 'organization') }
  tickets      = [ordered]@{ DATABASE_URL = 'db:tickets'; KAFKA_BROKERS = 'localhost:9092'; LOG_LEVEL = 'info'
                             JWT_SECRET = 'secret:JWT_SECRET'; TICKETS_INTERNAL_SECRET = 'secret:TICKETS_INTERNAL_SECRET'
                             RESOURCE_INTERNAL_SECRET = 'secret:RESOURCE_INTERNAL_SECRET'; ORGANIZATION_INTERNAL_SECRET = 'secret:ORGANIZATION_INTERNAL_SECRET'
                             RESOURCE_SERVICE_URL = (Url 'resource'); ORGANIZATION_SERVICE_URL = (Url 'organization'); WORKFLOW_SERVICE_URL = (Url 'workflow')
                             SIGDESK_LIVE_PROFILE = 'true' }
  workflow     = [ordered]@{ DATABASE_URL = 'db:workflow'; KAFKA_BROKERS = 'localhost:9092'; LOG_LEVEL = 'info'; TEMPORAL_HOST = 'localhost:7233'
                             JWT_SECRET = 'secret:JWT_SECRET'; TICKETS_INTERNAL_SECRET = 'secret:TICKETS_INTERNAL_SECRET'; CHANGE_INTERNAL_SECRET = 'secret:CHANGE_INTERNAL_SECRET'
                             TICKETS_SERVICE_URL = (Url 'tickets'); CHANGE_SERVICE_URL = (Url 'change') }
  notification = [ordered]@{ NOTIFICATION_DATABASE_URL = 'db:notification'; KAFKA_BROKERS = 'localhost:9092'; LOG_LEVEL = 'info'
                             JWT_SECRET = 'secret:JWT_SECRET'; ORGANIZATION_INTERNAL_SECRET = 'secret:ORGANIZATION_INTERNAL_SECRET'
                             ORGANIZATION_SERVICE_URL = (Url 'organization') }
  change       = [ordered]@{ CHANGE_DATABASE_URL = 'db:change'; KAFKA_BROKERS = 'localhost:9092'
                             JWT_SECRET = 'secret:JWT_SECRET'; CHANGE_INTERNAL_SECRET = 'secret:CHANGE_INTERNAL_SECRET'; TICKETS_INTERNAL_SECRET = 'secret:TICKETS_INTERNAL_SECRET'
                             RESOURCE_INTERNAL_SECRET = 'secret:RESOURCE_INTERNAL_SECRET'; ORGANIZATION_INTERNAL_SECRET = 'secret:ORGANIZATION_INTERNAL_SECRET'
                             TICKETS_SERVICE_URL = (Url 'tickets'); RESOURCE_SERVICE_URL = (Url 'resource'); ORGANIZATION_SERVICE_URL = (Url 'organization'); CATALOG_SERVICE_URL = (Url 'tickets') }
  problem      = [ordered]@{ PROBLEM_DATABASE_URL = 'db:problem'; KAFKA_BROKERS = 'localhost:9092'
                             JWT_SECRET = 'secret:JWT_SECRET'; CHANGE_INTERNAL_SECRET = 'secret:CHANGE_INTERNAL_SECRET'; TICKETS_INTERNAL_SECRET = 'secret:TICKETS_INTERNAL_SECRET'
                             RESOURCE_INTERNAL_SECRET = 'secret:RESOURCE_INTERNAL_SECRET'; ORGANIZATION_INTERNAL_SECRET = 'secret:ORGANIZATION_INTERNAL_SECRET'
                             TICKETS_SERVICE_URL = (Url 'tickets'); RESOURCE_SERVICE_URL = (Url 'resource'); ORGANIZATION_SERVICE_URL = (Url 'organization')
                             CHANGE_SERVICE_URL = (Url 'change'); CATALOG_SERVICE_URL = (Url 'tickets') }
}

function Read-Env($path) {
  $h = [ordered]@{}
  if (-not (Test-Path -LiteralPath $path)) { return $h }
  foreach ($l in Get-Content -LiteralPath $path) {
    $t = $l.Trim(); if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('='); if ($i -gt 0) { $h[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim() }
  }
  return $h
}
function New-Secret { return -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 48 | ForEach-Object { [char]$_ }) }

$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Ejecuta este script como Administrador." }

$current = @{}; foreach ($svc in $Spec.Keys) { $current[$svc] = Read-Env (Join-Path $ConfigDir "$svc.env") }

# Secretos compartidos: un único valor por nombre en todos los archivos.
$secrets = @{}
foreach ($name in 'JWT_SECRET','TICKETS_INTERNAL_SECRET','ORGANIZATION_INTERNAL_SECRET','RESOURCE_INTERNAL_SECRET','CHANGE_INTERNAL_SECRET') {
  $vals = @($current.Values | ForEach-Object { $_[$name] } | Where-Object { $_ } | Select-Object -Unique)
  if ($vals.Count -gt 1) { throw "$name tiene valores DISTINTOS entre archivos; unifícalo antes (no se muestra el valor)." }
  if ($vals.Count -eq 1) { $secrets[$name] = $vals[0]; Write-Host "  $name : se reutiliza el existente"; continue }
  if ($name -in 'JWT_SECRET','TICKETS_INTERNAL_SECRET') { throw "$name no está en ningún archivo; defínelo primero (es del operador, no se genera)." }
  $secrets[$name] = New-Secret; Write-Host "  $name : NUEVO (generado, 48 caracteres)"
}

$baseDb = $current['organization']['DATABASE_URL']
if (-not $baseDb -or $baseDb -notmatch '/sigdesk_organization_local$') { throw "organization.env debe tener DATABASE_URL terminada en /sigdesk_organization_local (se usa como base)." }

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
if ($Apply) { $bk = Join-Path $ConfigDir "backup-$ts"; New-Item -ItemType Directory -Path $bk | Out-Null; Get-ChildItem $ConfigDir -Filter *.env | Copy-Item -Destination $bk; Write-Host "Respaldo: $bk" }

foreach ($svc in $Spec.Keys) {
  $file = Join-Path $ConfigDir "$svc.env"; $cur = $current[$svc]; $out = [ordered]@{}; $changes = @()
  # Conserva claves extra que el operador haya puesto (p. ej. MICROSOFT_*, INVENTORY_*).
  foreach ($k in $cur.Keys) { $out[$k] = $cur[$k] }
  foreach ($k in $Spec[$svc].Keys) {
    $want = [string]$Spec[$svc][$k]
    if ($want.StartsWith('secret:')) { $v = $secrets[$want.Substring(7)] }
    elseif ($want.StartsWith('db:')) { $v = $baseDb -replace 'sigdesk_organization_local$', "sigdesk_$($want.Substring(3))_local" }
    else { $v = $want }
    $force = ($k -like '*_SERVICE_URL') -or ($k -eq 'SIGTOOLS_API_URL')   # URLs siempre a su valor correcto
    if (-not $out.Contains($k)) { $changes += "+$k" ; $out[$k] = $v }
    elseif ($force -and $out[$k] -ne $v) { $changes += "~$k"; $out[$k] = $v }
  }
  $estado = if (-not (Test-Path $file)) { 'NUEVO' } elseif ($changes.Count) { 'actualiza' } else { 'sin cambios' }
  Write-Host ("{0,-13} {1,-11} {2}" -f "$svc.env", $estado, ($changes -join ' '))
  if ($Apply -and $changes.Count) {
    $lines = @("# $($svc)_service — generado/completado por configurar-entorno.ps1 ($ts). Secretos: no versionar.") + @($out.Keys | ForEach-Object { "$_=$($out[$_])" })
    Set-Content -LiteralPath $file -Value $lines -Encoding ASCII
  }
}
if (-not $Apply) { Write-Host "`nDry-run: no se escribió nada. Repite con -Apply para aplicar." }
