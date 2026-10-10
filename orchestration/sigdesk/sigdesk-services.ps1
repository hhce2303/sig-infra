#requires -Version 5.1
<#
.SYNOPSIS
  Instala, actualiza y revierte los servicios Go de SIG-Desk como servicios de Windows (NSSM).

.DESCRIPTION
  Reglas de seguridad (el MKS aloja otros servicios que NO se pueden tocar):
    * Solo opera sobre servicios cuyo nombre empieza con 'SIGDesk-' y cuyo ImagePath es la
      copia de NSSM de este módulo ($Root\bin\nssm.exe). Cualquier otro servicio se ignora.
    * Nunca llama Stop/Remove/Restart sobre nada que no cumpla lo anterior.
    * No toca el firewall: los servicios escuchan solo en 127.0.0.1 (LISTEN_HOST).
    * Sin -Apply es un dry-run: imprime qué haría y no cambia nada. 'preflight' y 'status'
      son siempre de solo lectura.
    * Puertos 18080-18083 (el 8080 y el 8082 los usan ManageEngine ServiceDesk y Apache).

  Acciones:
    preflight  Verifica admin, puertos, NSSM y env files. Solo lectura.
    status     Estado de los servicios SIGDesk-*. Solo lectura.
    install    Crea los servicios (inicio automático retardado). Requiere -Source y -Apply.
    update     Reemplaza los .exe con backup y chequeo; revierte solo si falla. Requiere -Source y -Apply.
    rollback   Restaura el release anterior guardado en releases\. Requiere -Apply.
    uninstall  Elimina SOLO los servicios SIGDesk-* (no borra datos ni logs). Requiere -Apply.

  -Source: carpeta con <servicio>.exe y SHA256SUMS (el Release de GitHub descargado), o
  -Tag vX.Y.Z para bajarlo con `gh release download` desde -Repo.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('preflight','status','install','update','rollback','uninstall')]
  [string]$Action,
  [string]$Source,
  [string]$Tag,
  [string]$Repo = 'hhce2303/SIG-Desk-Backend',
  [string]$Root = 'C:\SIG\SIGDesk',
  [string]$NssmSource = 'C:\Program Files\SIGCircuitCheck\nssm.exe',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'

# Orden de despliegue: dependencias primero (tickets llama a organization y resource).
$Services = @(
  @{ Key = 'organization'; Port = 18081 },
  @{ Key = 'resource';     Port = 18082 },
  @{ Key = 'tickets';      Port = 18080 },
  @{ Key = 'workflow';     Port = 18083 }
)
$Prefix    = 'SIGDesk-'
$BindHost  = '127.0.0.1'
$Nssm      = Join-Path $Root 'bin\nssm.exe'
$ConfigDir = Join-Path $Root 'config'
$CurrentDir = Join-Path $Root 'current'
$LogDir    = Join-Path $Root 'logs'
$RelDir    = Join-Path $Root 'releases'

function SvcName($s)  { return "$Prefix$($s.Key)" }
function ExePath($s)  { return Join-Path $CurrentDir "$($s.Key)_service.exe" }
function EnvPath($s)  { return Join-Path $ConfigDir "$($s.Key).env" }
function Say($m)      { Write-Host $m }
function Plan($m)     { if ($Apply) { Write-Host "  -> $m" } else { Write-Host "  [dry-run] $m" -ForegroundColor Yellow } }
function IsAdmin {
  $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Salvaguarda central: ¿este servicio es nuestro? -------------------------------------------
function Get-OwnedService($name) {
  if (-not $name.StartsWith($Prefix)) { throw "BLOQUEADO: '$name' no empieza con '$Prefix'." }
  $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
  if (-not $svc) { return $null }
  if ($svc.PathName -notlike "*$Nssm*") {
    throw "BLOQUEADO: el servicio '$name' existe pero NO usa $Nssm (ImagePath: $($svc.PathName)). No se toca."
  }
  return $svc
}
function Invoke-Nssm {
  if (-not (Test-Path $Nssm)) { throw "No existe $Nssm (corre 'install' para copiarlo)." }
  $out = & $Nssm @args 2>&1
  if ($LASTEXITCODE -ne 0) { throw "nssm $($args -join ' ') falló: $out" }
  return $out
}
function Require-Admin { if (-not (IsAdmin)) { throw "Esta acción necesita PowerShell como Administrador (o usa sin -Apply para ver el plan)." } }

# --- Env files -------------------------------------------------------------------------------
function Read-EnvFile($path) {
  $h = [ordered]@{}
  foreach ($line in Get-Content -LiteralPath $path) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { throw "${path}: línea inválida '$t' (se espera CLAVE=valor)." }
    $h[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
  }
  return $h
}
function Test-EnvFile($s, [ref]$problems) {
  $p = EnvPath $s
  if (-not (Test-Path -LiteralPath $p)) { $problems.Value += "falta $p (copia env\$($s.Key).env.example)"; return $null }
  $e = Read-EnvFile $p
  $required = @('DATABASE_URL')
  if ($s.Key -ne 'workflow') { $required += 'JWT_SECRET' }
  if ($s.Key -eq 'tickets')  { $required += 'TICKETS_INTERNAL_SECRET' }
  foreach ($k in $required) {
    if (-not $e.Contains($k) -or [string]::IsNullOrWhiteSpace($e[$k])) { $problems.Value += "$($s.Key).env: falta $k"; continue }
    if ($e[$k] -match 'CAMBIAR|CHANGE_?ME|dev-only') { $problems.Value += "$($s.Key).env: $k sigue con el valor de ejemplo" }
  }
  foreach ($k in 'JWT_SECRET','TICKETS_INTERNAL_SECRET') {
    if ($e.Contains($k) -and $e[$k].Length -lt 32) { $problems.Value += "$($s.Key).env: $k < 32 caracteres (el servicio no arranca)" }
  }
  foreach ($k in $e.Keys) { if ($e[$k] -match '["\r\n]') { $problems.Value += "$($s.Key).env: $k contiene comillas o saltos de línea (no soportado)" } }
  foreach ($k in 'PORT','LISTEN_HOST') { if ($e.Contains($k)) { $problems.Value += "$($s.Key).env: no definas $k (lo fija este script: $BindHost`:$($s.Port))" } }
  return $e
}

function Test-PortFree($s) {
  $c = Get-NetTCPConnection -State Listen -LocalPort $s.Port -ErrorAction SilentlyContinue
  if (-not $c) { return $true }
  # Si es nuestro propio servicio ya corriendo, no es conflicto.
  $svc = Get-OwnedService (SvcName $s)
  if ($svc -and $svc.ProcessId -and ($c.OwningProcess -contains $svc.ProcessId)) { return $true }
  return $false
}

function Wait-Port($port, $seconds) {
  $until = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $until) {
    try { $c = New-Object Net.Sockets.TcpClient; $c.Connect($BindHost, $port); $c.Close(); return $true } catch { Start-Sleep -Milliseconds 700 }
  }
  return $false
}

function Resolve-Source {
  if ($Source) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "No existe -Source '$Source'." }
    return (Resolve-Path -LiteralPath $Source).Path
  }
  if ($Tag) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "sigdesk-$Tag"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    New-Item -ItemType Directory -Path $tmp | Out-Null
    & gh release download $Tag --repo $Repo --dir $tmp
    if ($LASTEXITCODE -ne 0) { throw "gh release download $Tag falló (¿gh autenticado?)." }
    return $tmp
  }
  throw "Indica -Source <carpeta con los .exe y SHA256SUMS> o -Tag vX.Y.Z."
}
function Test-Checksums($dir) {
  $sums = Join-Path $dir 'SHA256SUMS'
  if (-not (Test-Path $sums)) { throw "Falta SHA256SUMS en $dir. No se instala nada sin verificar." }
  $exp = @{}
  foreach ($l in Get-Content $sums) { if ($l -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $exp[$Matches[2].Trim()] = $Matches[1].ToLower() } }
  foreach ($s in $Services) {
    $f = "$($s.Key)_service.exe"; $p = Join-Path $dir $f
    if (-not (Test-Path $p)) { throw "Falta $f en $dir." }
    if (-not $exp.ContainsKey($f)) { throw "$f no figura en SHA256SUMS." }
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower()
    if ($h -ne $exp[$f]) { throw "SHA256 de $f no coincide (esperado $($exp[$f]), real $h). Abortado." }
  }
  Say "Checksums OK ($($Services.Count) binarios)."
}

# --- Acciones --------------------------------------------------------------------------------
function Do-Preflight {
  $bad = @()
  Say "== Preflight (solo lectura) =="
  Say ("Administrador: {0}" -f (IsAdmin))
  Say ("NSSM origen   : {0}  existe={1}" -f $NssmSource, (Test-Path $NssmSource))
  if (Test-Path $NssmSource) { Say ("  versión/sha256: {0} / {1}" -f (Get-Item $NssmSource).VersionInfo.FileVersion, (Get-FileHash $NssmSource).Hash.Substring(0,16)) }
  foreach ($s in $Services) {
    $n = SvcName $s
    $owned = $null
    try { $owned = Get-OwnedService $n } catch { $bad += $_.Exception.Message }
    $free = Test-PortFree $s
    Say ("{0,-22} puerto {1}: {2}   servicio: {3}" -f $n, $s.Port, $(if ($free) {'libre/propio'} else {'OCUPADO por otro proceso'}), $(if ($owned) {$owned.State} else {'no instalado'}))
    if (-not $free) { $bad += "puerto $($s.Port) ocupado por otro proceso" }
    [void](Test-EnvFile $s ([ref]$bad))
  }
  $fw = Get-NetFirewallProfile | ForEach-Object { "$($_.Name)=$($_.Enabled)" }
  Say ("Firewall: {0} (no se modifica; los servicios escuchan solo en $BindHost)" -f ($fw -join ', '))
  if ($bad.Count) { Say "`nPROBLEMAS:"; $bad | ForEach-Object { Say "  - $_" }; return $false }
  Say "`nPreflight OK."; return $true
}

function Do-Status {
  foreach ($s in $Services) {
    $n = SvcName $s
    try { $o = Get-OwnedService $n } catch { Say "$n : $($_.Exception.Message)"; continue }
    if (-not $o) { Say ("{0,-22} no instalado" -f $n); continue }
    $up = $false; try { $c = New-Object Net.Sockets.TcpClient; $c.Connect($BindHost, $s.Port); $c.Close(); $up = $true } catch {}
    Say ("{0,-22} {1,-9} inicio={2,-10} {3}:{4} {5}" -f $n, $o.State, $o.StartMode, $BindHost, $s.Port, $(if ($up) {'responde'} else {'sin respuesta'}))
  }
}

function Do-Install {
  $dir = Resolve-Source
  Test-Checksums $dir
  if (-not (Do-Preflight)) { throw "Preflight con problemas; corrígelos antes de instalar." }
  if ($Apply) { Require-Admin }
  foreach ($d in $Root,(Join-Path $Root 'bin'),$ConfigDir,$CurrentDir,$LogDir,$RelDir) { if (-not (Test-Path $d)) { Plan "crear $d"; if ($Apply) { New-Item -ItemType Directory -Path $d | Out-Null } } }
  if (-not (Test-Path $Nssm)) { Plan "copiar $NssmSource -> $Nssm (el original no se modifica)"; if ($Apply) { Copy-Item -LiteralPath $NssmSource -Destination $Nssm } }
  foreach ($s in $Services) {
    $n = SvcName $s; $exe = ExePath $s
    if (Get-OwnedService $n) { Say "$n ya existe: se omite (usa 'update' para cambiar el binario)."; continue }
    $e = Read-EnvFile (EnvPath $s)
    Plan "copiar $($s.Key)_service.exe -> $exe"
    if ($Apply) { Copy-Item -LiteralPath (Join-Path $dir "$($s.Key)_service.exe") -Destination $exe -Force }
    Plan "nssm install $n  (LocalService, inicio automático retardado, reinicio al fallar, $BindHost`:$($s.Port))"
    if (-not $Apply) { continue }
    Invoke-Nssm install $n $exe | Out-Null
    $pairs = @("PORT=$($s.Port)", "LISTEN_HOST=$BindHost") + @($e.Keys | ForEach-Object { "$_=$($e[$_])" })
    Invoke-Nssm set $n AppDirectory $CurrentDir | Out-Null
    Invoke-Nssm set $n AppEnvironmentExtra @pairs | Out-Null
    Invoke-Nssm set $n DisplayName "SIG-Desk $($s.Key)_service" | Out-Null
    Invoke-Nssm set $n Description "SIG-Desk $($s.Key)_service (detrás de Kong, solo $BindHost`:$($s.Port))" | Out-Null
    Invoke-Nssm set $n ObjectName 'NT AUTHORITY\LocalService' | Out-Null
    Invoke-Nssm set $n Start SERVICE_DELAYED_AUTO_START | Out-Null
    Invoke-Nssm set $n AppStdout (Join-Path $LogDir "$($s.Key).out.log") | Out-Null
    Invoke-Nssm set $n AppStderr (Join-Path $LogDir "$($s.Key).err.log") | Out-Null
    Invoke-Nssm set $n AppRotateFiles 1 | Out-Null
    Invoke-Nssm set $n AppRotateOnline 1 | Out-Null
    Invoke-Nssm set $n AppRotateBytes 10485760 | Out-Null
    Invoke-Nssm set $n AppExit Default Restart | Out-Null
    Invoke-Nssm set $n AppRestartDelay 10000 | Out-Null     # el servicio sale si Postgres/Kafka aún no están; reintenta
    Invoke-Nssm set $n AppThrottle 15000 | Out-Null
  }
  if ($Apply) {
    # Permisos: las claves de entorno van en el registro del servicio y el config/ tiene secretos.
    Say "Ajustando permisos (solo carpetas y claves SIGDesk)..."
    & icacls $LogDir /grant '*S-1-5-19:(OI)(CI)M' | Out-Null            # LocalService escribe logs
    & icacls $CurrentDir /grant '*S-1-5-19:(OI)(CI)RX' | Out-Null
    & icacls $ConfigDir /inheritance:r /grant '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null   # SYSTEM + Administrators
    foreach ($s in $Services) {
      $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$(SvcName $s)\Parameters"
      if (Test-Path $key) {
        $acl = Get-Acl $key
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @(@('S-1-5-18','FullControl'), @('S-1-5-32-544','FullControl'), @('S-1-5-19','ReadKey'))) {
          $sid = New-Object Security.Principal.SecurityIdentifier($r[0])
          $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule($sid, $r[1], 'ContainerInherit', 'None', 'Allow')))
        }
        Set-Acl $key $acl
      }
    }
  }
  Say "`nInstalación $(if ($Apply) {'aplicada'} else {'simulada'}). Los servicios NO se inician solos aquí: arráncalos con 'Start-Service SIGDesk-<nombre>' cuando Postgres/Kafka/Kong estén arriba."
}

function Restore-Release($s, $relPath) {
  $n = SvcName $s
  $old = Join-Path $relPath "$($s.Key)_service.exe"
  if (-not (Test-Path $old)) { return }
  Stop-Service -Name $n -ErrorAction SilentlyContinue
  (Get-Service $n).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
  Copy-Item -LiteralPath $old -Destination (ExePath $s) -Force
  Start-Service -Name $n
}

function Do-Update {
  $dir = Resolve-Source
  Test-Checksums $dir
  if ($Apply) { Require-Admin }
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bk = Join-Path $RelDir $ts
  Plan "backup de los binarios actuales en $bk"
  if ($Apply) { New-Item -ItemType Directory -Path $bk -Force | Out-Null }
  foreach ($s in $Services) {
    $n = SvcName $s; $o = Get-OwnedService $n
    if (-not $o) { Say "$n no está instalado: se omite."; continue }
    Plan "$n : detener, copiar nuevo .exe, iniciar y verificar $BindHost`:$($s.Port) (si falla, restaura el anterior)"
    if (-not $Apply) { continue }
    $wasRunning = ($o.State -eq 'Running')
    Copy-Item -LiteralPath (ExePath $s) -Destination $bk -Force
    Stop-Service -Name $n; (Get-Service $n).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    Copy-Item -LiteralPath (Join-Path $dir "$($s.Key)_service.exe") -Destination (ExePath $s) -Force
    if (-not $wasRunning) { Say "$n actualizado (estaba detenido; se deja detenido)."; continue }
    Start-Service -Name $n
    $ok = (Wait-Port $s.Port 45)
    if ($ok) { Start-Sleep -Seconds 8; $ok = ((Get-Service $n).Status -eq 'Running') -and (Wait-Port $s.Port 5) }
    if (-not $ok) {
      Say "FALLÓ $n con el binario nuevo: restaurando el anterior..."
      Restore-Release $s $bk
      throw "Update abortado en $n (revertido). Servicios posteriores NO se tocaron. Revisa $LogDir\$($s.Key).err.log."
    }
    Say "$n OK"
  }
  Say "`nUpdate $(if ($Apply) {'aplicado'} else {'simulado'}). Backup: $bk"
}

function Do-Rollback {
  if ($Apply) { Require-Admin }
  $last = Get-ChildItem $RelDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $last) { throw "No hay releases previos en $RelDir." }
  Say "Rollback al backup $($last.FullName)"
  foreach ($s in $Services) {
    $n = SvcName $s
    if (-not (Get-OwnedService $n)) { continue }
    Plan "$n : restaurar $($s.Key)_service.exe desde $($last.Name)"
    if ($Apply) { Restore-Release $s $last.FullName }
  }
}

function Do-Uninstall {
  if ($Apply) { Require-Admin }
  foreach ($s in $Services) {
    $n = SvcName $s
    if (-not (Get-OwnedService $n)) { Say "$n no está instalado."; continue }
    Plan "detener y eliminar el servicio $n (no se borran logs, config ni binarios)"
    if ($Apply) {
      Stop-Service -Name $n -ErrorAction SilentlyContinue
      (Get-Service $n).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
      Invoke-Nssm remove $n confirm | Out-Null
    }
  }
}

switch ($Action) {
  'preflight' { [void](Do-Preflight) }
  'status'    { Do-Status }
  'install'   { Do-Install }
  'update'    { Do-Update }
  'rollback'  { Do-Rollback }
  'uninstall' { Do-Uninstall }
}
