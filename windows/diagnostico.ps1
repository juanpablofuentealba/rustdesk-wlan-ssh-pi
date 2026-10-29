<#
.SYNOPSIS
  diagnostico.ps1 — Diagnóstico de hardware y apagones para Windows.

.DESCRIPTION
  Recoge las señales que explican por qué un PC "se apaga solo" o "va lento":
  eventos de apagón, temperaturas, salud de discos (SMART), RAM, batería,
  uptime y consumo. Pensado para correrlo EN el equipo del cliente vía:

      irm https://raw.githubusercontent.com/juanpablofuentealba/rustdesk-wlan-ssh-pi/main/windows/diagnostico.ps1 | iex

  (una sola línea, sin pegar comandos largos).

  También se puede descargar y correr local:

      .\diagnostico.ps1               # muestra en pantalla
      .\diagnostico.ps1 -Out C:\kit   # guarda diag.txt + diag.json

.NOTES
  - Requiere PowerShell como ADMINISTRADOR para el diagnóstico completo
    (SMART, eventos del sistema). Sin admin, da lo que puede y lo avisa.
  - NO cambia nada: solo lee. Es seguro.
  - No envía datos a ninguna parte: imprime/guarda localmente.
#>

[CmdletBinding()]
param(
    # Carpeta donde guardar el informe. Si se omite, solo muestra en pantalla.
    [string]$Out = ""
)

$ErrorActionPreference = "SilentlyContinue"

# ─── Utilidades de salida ────────────────────────────────────────────────
function Head($m){ Write-Host "`n== $m ==" -ForegroundColor White -BackgroundColor DarkBlue }
function Info($m){ Write-Host "  $m" -ForegroundColor Gray }
function Ok($m)  { Write-Host "  [OK]    $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [AVISO] $m" -ForegroundColor Yellow }
function Bad($m) { Write-Host "  [ALERTA] $m" -ForegroundColor Red }

# ¿Somos admin?
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$esAdmin = Test-Admin
$fecha = Get-Date

# Buffer con todo el informe en texto (para guardarlo igual que se muestra)
$buf = New-Object System.Collections.Generic.List[string]
function Say($m) { $buf.Add([string]$m); Write-Host $m }

# ─── Encabezado ──────────────────────────────────────────────────────────
Say "════════════════════════════════════════════════════════"
Say "  DIAGNÓSTICO DE HARDWARE — Windows"
Say "════════════════════════════════════════════════════════"
Say "  Fecha   : $($fecha.ToString('yyyy-MM-dd HH:mm:ss'))"
Say "  Equipo  : $env:COMPUTERNAME"
Say "  Usuario : $env:USERNAME"
Say "  Admin   : $(if($esAdmin){'SÍ'}else{'NO (diagnóstico parcial)'})"

# ─── 1. Sistema ──────────────────────────────────────────────────────────
Head "1. SISTEMA"
$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$bios= Get-CimInstance Win32_BIOS
$bb  = Get-CimInstance Win32_BaseBoard

Say "  Windows   : $($os.Caption) (build $($os.BuildNumber), $($os.OSArchitecture))"
Say "  Kernel    : $($os.Version)"
Say "  Equipo    : $($cs.Manufacturer) $($cs.Model)  [tipo $($cs.PCSystemType): 1=escritorio 2=portátil]"
Say "  BIOS      : $($bios.Manufacturer) $($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"
Say "  Placa     : $($bb.Manufacturer) $($bb.Product)"
Say "  CPU       : $($cpu.Name)"
Say "  Núcleos   : $($cpu.NumberOfCores) núcleos / $($cpu.NumberOfLogicalProcessors) hilos"
Say "  RAM       : $([math]::Round($cs.TotalPhysicalMemory/1GB,1)) GB"
$up = $fecha - $os.LastBootUpTime
Say "  Uptime    : $($up.Days)d $($up.Hours)h $($up.Minutes)m  (último arranque: $($os.LastBootUpTime))"

# ─── 2. Apagones / Eventos críticos ──────────────────────────────────────
Head "2. APAGONES Y EVENTOS CRÍTICOS"
Say "  (Kernel-Power 41 = apagón BRUSCO; 6008 = apagado inesperado; 1074 = planeado)"
Say ""
$ev = Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,6008,1074,1076,1001} -MaxEvents 20 -EA 0
if ($ev) {
    foreach ($e in $ev) {
        $tipo = switch ($e.Id) {
            41   { "APAGÓN BRUSCO (hardware/energía)" }
            6008 { "apagado inesperado" }
            1074 { "apagado planeado (software/update)" }
            1076 { "motivo de apagado registrado" }
            1001 { "BugCheck / pantallazo azul (BSOD)" }
            default { "evento $($e.Id)" }
        }
        Say ("  {0}  [{1}]  {2}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'), $e.Id, $tipo)
    }
    $bruscos = ($ev | Where-Object Id -eq 41).Count
    if ($bruscos -ge 3) { Say ""; Bad "$bruscos apagones BRUSCOS (Id 41) → fuerte indicio de HARDWARE (energía/térmico)" }
    elseif ($bruscos -ge 1) { Say ""; Warn "$bruscos apagón(es) brusco(s) (Id 41) → revisar energía/temperatura" }
} else {
    Info "  (sin eventos 41/6008/1074 en este log)"
}

# Minidumps (BSOD)
$dumps = Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -EA 0 | Sort-Object LastWriteTime -Desc | Select-Object -First 5
if ($dumps) {
    Say ""
    Say "  Minidumps (pantallazos azules):"
    foreach ($d in $dumps) { Say "    $($d.LastWriteTime)  $($d.Name)  ($([math]::Round($d.Length/1KB)) KB)" }
} else {
    Info "  (sin minidumps de BSOD)"
}

# ─── 3. Temperaturas ─────────────────────────────────────────────────────
Head "3. TEMPERATURAS (ACPI)"
$temps = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -EA 0
if ($temps) {
    foreach ($t in $temps) {
        $c = [math]::Round(($t.CurrentTemperature/10 - 273.15), 1)
        $txt = "  $($t.InstanceName): $c C"
        if ($c -ge 85) { Bad "$txt  ← MUY ALTA" } elseif ($c -ge 75) { Warn "$txt" } else { Say $txt }
    }
} else {
    Info "  (el firmware no expone temperaturas ACPI; usar HWiNFO/Core Temp)"
}

# ─── 4. Discos y SMART ───────────────────────────────────────────────────
Head "4. DISCOS Y SMART"
$pd = Get-PhysicalDisk -EA 0
if ($pd) {
    foreach ($d in $pd) {
        $txt = "  {0}  [{1}]  {2} GB  Salud:{3}  Estado:{4}" -f `
            $d.FriendlyName, $d.MediaType, [math]::Round($d.Size/1GB), $d.HealthStatus, $d.OperationalStatus
        if ($d.HealthStatus -ne 'Healthy' -or $d.OperationalStatus -ne 'OK') { Bad $txt } else { Say $txt }
    }
    # Contadores SMART (requiere admin)
    if ($esAdmin) {
        Say ""
        Say "  Datos SMART (relevantes):"
        foreach ($d in $pd) {
            $s = $d | Get-StorageReliabilityCounter -EA 0
            if ($s) {
                Say ("    {0}: Temp {1}C  Horas encendido {2}  Sectores reasignados {3}  Errores lectura {4}" -f `
                    $d.FriendlyName, $s.Temperature, $s.PowerOnHours, $s.ReadErrorsTotal, $s.ReadErrorsUncorrected)
                if ($s.Temperature -ge 50) { Warn "      ← disco caliente ($($s.Temperature) C)" }
            }
        }
    }
} else {
    Info "  (no se pudieron leer discos físicos)"
}

# Volúmenes (espacio)
Say ""
Say "  Volúmenes:"
foreach ($v in (Get-Volume -EA 0 | Where-Object DriveLetter)) {
    $pct = if ($v.Size) { [math]::Round(100*($v.Size-$v.SizeRemaining)/$v.Size) } else { 0 }
    $txt = "    {0}: [{1}] {2} GB libres de {3} GB ({4}% usado) {5}" -f `
        $v.DriveLetter, $v.FileSystemLabel, [math]::Round($v.SizeRemaining/1GB), [math]::Round($v.Size/1GB), $pct, $v.FileSystem
    if ($pct -ge 90) { Bad "$txt  ← CASI LLENO" } else { Say $txt }
}

# ─── 5. Memoria (RAM) ────────────────────────────────────────────────────
Head "5. MEMORIA RAM"
$ram = Get-CimInstance Win32_PhysicalMemory -EA 0
if ($ram) {
    foreach ($r in $ram) {
        Say "  $($r.BankLabel)/$($r.DeviceLocator): $([math]::Round($r.Capacity/1GB)) GB  $($r.Speed) MHz  $($r.Manufacturer) $($r.PartNumber)"
    }
}
# Errores de memoria registrados
$memErr = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results'} -MaxEvents 3 -EA 0
if ($memErr) { Warn "  Hay resultados de diagnóstico de memoria (revisar por errores)"; $memErr | ForEach-Object { Say "    $($_.TimeCreated): $($_.Message)" } }
else { Info "  (sin resultados de diagnóstico de memoria recientes)" }

# ─── 6. Batería / energía (portátiles) ───────────────────────────────────
Head "6. ENERGÍA / BATERÍA"
$bat = Get-CimInstance Win32_Battery -EA 0
if ($bat) {
    foreach ($b in $bat) {
        Say "  Batería: $($b.Name)  Carga: $($b.EstimatedChargeRemaining)%  Enchufado: $(if($b.BatteryStatus -eq 2){'SÍ'}else{'NO'})"
    }
    # Informe de batería (powercfg) — requiere admin
    if ($esAdmin) {
        $tmp = Join-Path $env:TEMP "battery-report.html"
        powercfg /batteryreport /output $tmp 2>&1 | Out-Null
        if (Test-Path $tmp) { Say "  Informe de batería: $tmp" }
    }
} else {
    Info "  (sin batería → PC de escritorio)"
}

# Kernel-Power config y plan
$plan = (powercfg /getactivescheme 2>$null)
if ($plan) { Say "  Plan de energía: $plan" }

# ─── 7. Procesos que más consumen ────────────────────────────────────────
Head "7. TOP 10 PROCESOS (CPU / RAM)"
Say "  (por memoria de trabajo)"
Get-Process | Sort-Object WorkingSet64 -Desc | Select-Object -First 10 | ForEach-Object {
    Say ("   {0,-30} {1,8:N0} MB   CPU:{2:N0}s" -f $_.ProcessName, ($_.WorkingSet64/1MB), $_.CPU)
}

# ─── 8. Resumen y recomendación ──────────────────────────────────────────
Head "8. RESUMEN"
# Temperatura máxima detectada
$tmaxTxt = "n/d"
if ($temps) { $tmaxTxt = "{0:N1} C" -f (($temps | ForEach-Object { $_.CurrentTemperature/10 - 273.15 } | Measure-Object -Maximum).Maximum) }
$bruscosTxt = if ($ev) { ($ev | Where-Object Id -eq 41).Count } else { 0 }
$discoMal = ($pd | Where-Object { $_.HealthStatus -ne 'Healthy' }).Count
Say "  Apagones bruscos (Id 41) : $bruscosTxt"
Say "  Temperatura máx (ACPI)   : $tmaxTxt"
Say "  Discos con salud ≠ OK    : $discoMal"
Say "  Minidumps BSOD            : $(if($dumps){$dumps.Count}else{0})"
Say ""
Say "  Interpretación rápida:"
Say "   - Varios 'Id 41' + temperatura alta  → SOBRECALENTAMIENTO (limpiar/reemplazar pasta/ventilador)"
Say "   - Varios 'Id 41' + temps normales    → FUENTE DE ALIMENTACIÓN / energía / RAM"
Say "   - 'Id 1074' en los apagados          → era actualización o software (no hardware)"
Say "   - Minidumps (BSOD)                   → RAM o driver (probar MemTest86)"
Say "   - Disco 'Caution/Bad'                → reemplazar disco"

# ─── Guardar informe ─────────────────────────────────────────────────────
if ($Out) {
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    $txtPath = Join-Path $Out "diag.txt"
    $jsonPath = Join-Path $Out "diag.json"
    ($buf -join "`r`n") | Set-Content $txtPath -Encoding UTF8

    $json = [PSCustomObject]@{
        fecha        = $fecha.ToString('s')
        hostname     = $env:COMPUTERNAME
        windows      = "$($os.Caption) build $($os.BuildNumber)"
        fabricante   = "$($cs.Manufacturer) $($cs.Model)"
        cpu          = $cpu.Name
        ram_gb       = [math]::Round($cs.TotalPhysicalMemory/1GB,1)
        uptime       = "$($up.Days)d $($up.Hours)h"
        apagones_41  = $bruscosTxt
        temp_max_c   = if ($temps) { [math]::Round((($temps | ForEach-Object { $_.CurrentTemperature/10 - 273.15 } | Measure-Object -Maximum).Maximum),1) } else { $null }
        discos_salud = @($pd | ForEach-Object { "$($_.FriendlyName):$($_.HealthStatus)" })
        bsod_dumps   = @($dumps | ForEach-Object { $_.Name })
        bateria      = if ($bat) { "$($bat[0].EstimatedChargeRemaining)%" } else { "sin bateria" }
    }
    $json | ConvertTo-Json -Depth 5 | Set-Content $jsonPath -Encoding UTF8

    Write-Host ""
    Write-Host "  ✔ Informe guardado:" -ForegroundColor Green
    Write-Host "     $txtPath"
    Write-Host "     $jsonPath"
    Write-Host "  Pasá ese archivo (o una captura) para interpretarlo."
}

Say ""
Say "════════════════════════════════════════════════════════"
Say "  Diagnóstico completo. No se cambió nada en el equipo."
Say "════════════════════════════════════════════════════════"
