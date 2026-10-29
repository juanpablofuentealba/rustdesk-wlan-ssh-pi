<#
.SYNOPSIS
  inventory.ps1 — Inventario de specs de un PC con Windows (para la ficha del cliente).

.DESCRIPTION
  Recoge hardware, SO, discos, red y estado del kit de acceso remoto.
  Salida en texto, JSON y Markdown. Equivalente Windows de inventory.sh.

.USO
  .\inventory.ps1                 # muestra en pantalla
  .\inventory.ps1 -Out .\         # guarda inventory.{txt,json,md}
#>

[CmdletBinding()]
param(
    [string]$Out = ""
)

$ErrorActionPreference = "SilentlyContinue"

function Ok($m){Write-Host "  [OK]    $m" -ForegroundColor Green}
function Warn($m){Write-Host "  [AVISO] $m" -ForegroundColor Yellow}

function Get-Info {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

    # discos físicos
    $discos = Get-CimInstance Win32_DiskDrive | ForEach-Object {
        [PSCustomObject]@{
            modelo = $_.Model
            tipo   = if ($_.MediaType -match 'SSD' -or $_.Model -match 'SSD|NVMe') { 'SSD' } else { 'disco' }
            gb     = [math]::Round($_.Size/1GB, 0)
        }
    }

    # volúmenes
    $vols = Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object {
        [PSCustomObject]@{
            letra    = $_.DriveLetter
            etiqueta = $_.FileSystemLabel
            total_gb = [math]::Round($_.Size/1GB, 0)
            libre_gb = [math]::Round($_.SizeRemaining/1GB, 0)
            fs       = $_.FileSystem
        }
    }

    # red
    $ips = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notmatch '^127\.' } |
        ForEach-Object { "$($_.IPAddress) ($($_.InterfaceAlias))" }

    # kit de acceso remoto
    $svc = @{}
    foreach ($s in 'sshd', 'Tailscale', 'RustDesk') {
        $g = Get-Service -Name $s -ErrorAction SilentlyContinue
        $svc[$s] = if ($g) { "$($g.Status)" } else { "no instalado" }
    }

    $tailIp = ""
    $tsExe = "C:\Program Files\Tailscale\tailscale.exe"
    if (Test-Path $tsExe) { $tailIp = (& $tsExe ip -4 2>$null | Select-Object -First 1) }

    $rdId = ""
    foreach ($p in "C:\Program Files\RustDesk\rustdesk.exe", "$env:ProgramFiles\RustDesk\rustdesk.exe") {
        if (Test-Path $p) { $rdId = (& $p --get-id 2>$null); break }
    }

    $uptime = (Get-Date) - $os.LastBootUpTime

    [PSCustomObject]@{
        hostname     = $env:COMPUTERNAME
        usuario      = $env:USERNAME
        windows      = $os.Caption
        build        = $os.BuildNumber
        kernel       = $os.Version
        arquitectura = $os.OSArchitecture
        cpu          = $cpu.Name
        nucleos      = $cpu.NumberOfCores
        hilos        = $cpu.NumberOfLogicalProcessors
        ram_gb       = [math]::Round($cs.TotalPhysicalMemory/1GB, 1)
        fabricante   = $cs.Manufacturer
        modelo       = $cs.Model
        chassis      = $cs.PCSystemType   # 1=Desktop 2=Laptop 3=Workstation
        discos       = $discos
        volumenes    = $vols
        ips          = $ips
        uptime       = "{0}d {1}h {2}m" -f $uptime.Days, $uptime.Hours, $uptime.Minutes
        servicios    = $svc
        tailscale_ip = $tailIp
        rustdesk_id  = $rdId
    }
}

# ─── Markdown ────────────────────────────────────────────────────────────
function Get-Markdown {
    param($i)
    @"
# Inventario — $($i.hostname)

| Campo | Valor |
|---|---|
| Usuario | ``$($i.usuario)`` |
| Windows | $($i.windows) (build $($i.build), $($i.arquitectura)) |
| Kernel | ``$($i.kernel)`` |
| Equipo | $($i.fabricante) $($i.modelo) |
| CPU | $($i.cpu) |
| Núcleos | $($i.nucleos) núcleos / $($i.hilos) hilos |
| RAM | $($i.ram_gb) GB |
| Uptime | $($i.uptime) |
| Tailscale IP | ``$($i.tailscale_ip)`` |
| RustDesk ID | ``$($i.rustdesk_id)`` |

## Discos

$(($i.discos | ForEach-Object { "- **$($_.tipo)** $($_.gb) GB — $($_.modelo)" }) -join "`n")

## Volúmenes

$(($i.volumenes | ForEach-Object { "- ``$($_.letra):`` $($_.etiqueta) — $($_.libre_gb)/$($_.total_gb) GB libres ($($_.fs))" }) -join "`n")

## Red

$(($i.ips | ForEach-Object { "- $_" }) -join "`n")

## Kit de acceso remoto

| Servicio | Estado |
|---|---|
| sshd | $($i.servicios['sshd']) |
| Tailscale | $($i.servicios['Tailscale']) |
| RustDesk | $($i.servicios['RustDesk']) |
"@
}

$info = Get-Info

# ─── Texto ───────────────────────────────────────────────────────────────
$txt = @"
=== INVENTARIO WINDOWS ===

Hostname     : $($info.hostname)
Usuario      : $($info.usuario)
Windows      : $($info.windows) (build $($info.build), $($info.arquitectura))
Kernel       : $($info.kernel)
Fabricante   : $($info.fabricante) $($info.modelo)
Chassis      : $($info.chassis)  (1=Desktop 2=Laptop 3=Workstation)
CPU          : $($info.cpu)
Nucleos      : $($info.nucleos) nucleos / $($info.hilos) hilos
RAM          : $($info.ram_gb) GB
Uptime       : $($info.uptime)

--- DISCOS ---
$($info.discos | ForEach-Object { "  $($_.tipo)  $($_.gb) GB  $($_.modelo)" } | Out-String)
--- VOLUMENES ---
$($info.volumenes | ForEach-Object { "  $($_.letra): $($_.etiqueta)  $($_.libre_gb)/$($_.total_gb) GB libres  $($_.fs)" } | Out-String)
--- RED ---
$($info.ips | ForEach-Object { "  $_" } | Out-String)
--- KIT DE ACCESO REMOTO ---
  sshd       : $($info.servicios['sshd'])
  Tailscale  : $($info.servicios['Tailscale'])
  RustDesk   : $($info.servicios['RustDesk'])
  Tailscale IP: $($info.tailscale_ip)
  RustDesk ID : $($info.rustdesk_id)
"@

Write-Host $txt -ForegroundColor Gray

if ($Out) {
    New-Item -ItemType Directory -Force -Path $Out | Out-Null
    $base = Join-Path $Out "inventory"
    $txt | Set-Content "$base.txt" -Encoding UTF8
    $info | ConvertTo-Json -Depth 5 | Set-Content "$base.json" -Encoding UTF8
    Get-Markdown $info | Set-Content "$base.md" -Encoding UTF8
    Ok "guardado: $base.txt / $base.json / $base.md"
}
