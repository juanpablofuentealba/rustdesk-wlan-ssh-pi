<#
.SYNOPSIS
  setup-remote-target.ps1 — Prepara un PC con Windows para soporte remoto.

.DESCRIPTION
  Equivalente Windows de setup-remote-target.sh (el kit de Linux). Instala y
  configura, de forma desatendida y VERIFICABLE:

    1. RustDesk  — acceso visual (unattended-friendly), para ver/controlar.
    2. OpenSSH Server — acceso "shell" (PowerShell/CMD) por red.
    3. Tailscale — red privada, para llegar sin abrir puertos.
    4. winget    — para instalar/actualizar programas en remoto.

  Pensado para PCs de clientes con Windows 10 u 11.

.USO
  .\setup-remote-target.ps1 -Check              # diagnostico (no cambia nada)
  .\setup-remote-target.ps1 -DryRun             # simula (muestra que haria)
  .\setup-remote-target.ps1 -Apply              # aplica (requiere Administrador)
  .\setup-remote-target.ps1 -Apply -AuthKey tskey-auth-xxxx   # + unir a Tailscale
  .\setup-remote-target.ps1 -Apply -AuthKey tskey-auth-xxxx -RdPass 'MiClave'

.NOTES
  - Debe ejecutarse COMO ADMINISTRADOR para -Apply.
  - Idempotente: si algo ya esta instalado, lo respeta.
  - NO instala nada sin -Apply (a menos que sea -Check/-DryRun).
  - La auth key de Tailscale se genera en:
      https://login.tailscale.com/admin/settings/keys  (se muestra UNA vez)
#>

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Apply,
    [string]$AuthKey = "",
    [string]$RdPass  = "",
    [string]$Hostname = "",
    [switch]$NoTailscale,
    [switch]$NoSsh
)

$ErrorActionPreference = "Stop"
$script:Fail = 0

# ─── Helpers de salida ───────────────────────────────────────────────────
function Ok   ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "  [FALLO] $m" -ForegroundColor Red; $script:Fail++ }
function Warn ($m) { Write-Host "  [AVISO] $m" -ForegroundColor Yellow }
function Info ($m) { Write-Host "  [info] $m" -ForegroundColor Cyan }
function Head ($m) { Write-Host "`n== $m ==" -ForegroundColor White -BackgroundColor DarkBlue }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ¿está instalado un programa? (por nombre en el registro de desinstalación)
function Get-Installed {
    param([string]$NamePattern)
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match $NamePattern } |
        Select-Object -First 1
}

# Descarga un archivo (con progreso y verificación de tamaño)
function Get-Download {
    param([string]$Url, [string]$OutFile)
    Info "descargando: $Url"
    try {
        $ProgressPreference = 'SilentlyContinue'   # acelera Invoke-WebRequest
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        $size = (Get-Item $OutFile).Length
        if ($size -lt 100KB) { throw "archivo sospechosamente pequeño ($size bytes)" }
        Ok "descargado ($([math]::Round($size/1MB,1)) MB)"
        return $true
    } catch {
        Bad "no se pudo descargar: $_"
        return $false
    }
}

# ─── Encabezado ──────────────────────────────────────────────────────────
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host "  KIT DE ACCESO REMOTO — Windows" -ForegroundColor White
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor DarkGray

$modo = if ($Check) { "CHECK" } elseif ($DryRun) { "DRY-RUN" } elseif ($Apply) { "APLICAR" } else { "" }
if (-not $modo) {
    Write-Host "`nUso:" -ForegroundColor Yellow
    Write-Host "  .\setup-remote-target.ps1 -Check     # diagnostico"
    Write-Host "  .\setup-remote-target.ps1 -DryRun    # simular"
    Write-Host "  .\setup-remote-target.ps1 -Apply     # aplicar (como Administrador)"
    exit 2
}

# Windows 10/11
$os = Get-CimInstance Win32_OperatingSystem
$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
$esAdmin = Test-Admin

Head "SISTEMA"
Info "Windows : $($os.Caption) (build $build)"
Info "PC      : $env:COMPUTERNAME"
Info "usuario : $env:USERNAME"
Info "modo    : $modo"
if ($esAdmin) { Ok "ejecutando como Administrador" } else { Warn "NO sos Administrador (necesario para -Apply)" }

if ($Apply -and -not $esAdmin) {
    Bad "-Apply requiere Administrador. Abrí PowerShell 'como Administrador'."
    exit 1
}

# ─── Hostname (opcional) ─────────────────────────────────────────────────
# Cambiar el nombre del equipo facilita identificarlo en la tailnet.
if ($Hostname) {
    if ($env:COMPUTERNAME -ieq $Hostname) {
        Ok "hostname ya es '$Hostname'"
    } elseif ($Apply) {
        try {
            Rename-Computer -NewName $Hostname -Force -ErrorAction Stop
            Warn "hostname -> '$Hostname' (requiere reinicio para aplicarse)"
        } catch { Bad "no se pudo renombrar el equipo: $_" }
    } else {
        Info "(en -Apply: renombraria el equipo a '$Hostname')"
    }
}

# ─── 1. RustDesk ─────────────────────────────────────────────────────────
Head "1. RustDesk (acceso visual)"
$rd = Get-Installed 'RustDesk'
if ($rd) {
    Ok "RustDesk ya instalado: $($rd.DisplayName) $($rd.DisplayVersion)"
} else {
    Warn "RustDesk NO instalado"
    if ($Apply) {
        $rdVer = "1.5.0"
        $url   = "https://github.com/rustdesk/rustdesk/releases/download/$rdVer/rustdesk-$rdVer-x86_64.msi"
        $msi   = Join-Path $env:TEMP "rustdesk-$rdVer-x86_64.msi"
        if (Get-Download $url $msi) {
            Info "instalando RustDesk (msi silencioso)..."
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
            if ($p.ExitCode -eq 0) { Ok "RustDesk instalado" } else { Bad "msiexec devolvio $($p.ExitCode)" }
        }
    } else {
        Info "(en -Apply: descargaria el .msi y lo instalaria en silencio)"
    }
}

# Contraseña permanente de RustDesk (para acceso UNATTENDED, ver H-15).
# Sin ella, cada conexión pide aceptación o contraseña temporal.
if ($RdPass) {
    $rdExe = @(
        "$env:ProgramFiles\RustDesk\rustdesk.exe",
        "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $rdExe) {
        Warn "RustDesk no está presente todavía; no se puede fijar -RdPass"
    } elseif ($Apply) {
        if ($RdPass.Length -lt 8) { Warn "clave corta (<8); RustDesk recomienda 8+" }
        Info "fijando contraseña permanente de RustDesk..."
        # RustDesk >=1.5 puede no aceptar --password por CLI; si falla, se guía por GUI.
        & $rdExe --password $RdPass 2>&1 | Out-Null
        $rc = $LASTEXITCODE
        $cfg = Join-Path $env:APPDATA "RustDesk\config\RustDesk.toml"
        $has = $false
        if (Test-Path $cfg) { $has = (Get-Content $cfg -Raw) -match "password\s*=\s*'" }
        if ($rc -eq 0 -or $has) {
            Ok "contraseña permanente de RustDesk fijada"
        } else {
            Warn "esta versión no acepta --password; fijala por la GUI:"
            Info "  Ajustes (⚙) → Seguridad → 'Contraseña permanente'"
        }
    } else {
        Info "(en -Apply: fijaria la contraseña permanente de RustDesk)"
    }
}

# ─── 2. OpenSSH Server ───────────────────────────────────────────────────
Head "2. OpenSSH Server (acceso shell)"
if ($NoSsh) {
    Info "omitido (-NoSsh)"
} else {
    $sshSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshSvc) {
        Ok "sshd presente (estado: $($sshSvc.Status))"
    } else {
        Warn "OpenSSH Server NO instalado"
        if ($Apply) {
            Info "instalando OpenSSH.Server (feature de Windows)..."
            try {
                $r = Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
                if ($r.RestartNeeded) { Warn "requiere reinicio" }
                Ok "OpenSSH Server instalado"
            } catch {
                Bad "no se pudo instalar OpenSSH.Server: $_"
                Info "alternativa manual: Configuración → Aplicaciones → Características opcionales → 'Servidor OpenSSH'"
            }
        } else {
            Info "(en -Apply: Add-WindowsCapability OpenSSH.Server)"
        }
    }
    if ($Apply) {
        try {
            Set-Service  -Name sshd -StartupType Automatic
            Start-Service -Name sshd
            Ok "sshd arrancado y en automatico"
            # firewall: permitir SSH
            if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
                    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
                Ok "regla de firewall SSH creada (puerto 22)"
            } else {
                Ok "regla de firewall SSH ya existe"
            }
        } catch { Bad "no se pudo arrancar/configurar sshd: $_" }
    }
}

# ─── 3. Tailscale ────────────────────────────────────────────────────────
Head "3. Tailscale (red privada)"
if ($NoTailscale) {
    Info "omitido (-NoTailscale)"
} else {
    $ts = Get-Installed 'Tailscale'
    if ($ts) {
        Ok "Tailscale ya instalado: $($ts.DisplayVersion)"
    } else {
        Warn "Tailscale NO instalado"
        if ($Apply) {
            $url = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi"
            $msi = Join-Path $env:TEMP "tailscale-setup.msi"
            if (Get-Download $url $msi) {
                Info "instalando Tailscale (msi silencioso)..."
                $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
                if ($p.ExitCode -eq 0) { Ok "Tailscale instalado" } else { Bad "msiexec devolvio $($p.ExitCode)" }
            }
        } else {
            Info "(en -Apply: descargaria e instalaria Tailscale)"
        }
    }

    if ($Apply -and -not $NoTailscale) {
        $tsExe = "C:\Program Files\Tailscale\tailscale.exe"
        if ($AuthKey) {
            if ($AuthKey -notmatch '^tskey-auth-') {
                Bad "la auth key no empieza con 'tskey-auth-' (revisá la key)"
            } elseif (Test-Path $tsExe) {
                Info "uniendo a la tailnet..."
                & $tsExe up --authkey $AuthKey --unattended --accept-routes
                if ($LASTEXITCODE -eq 0) { Ok "unido a la tailnet" } else { Bad "tailscale up devolvio $LASTEXITCODE" }
            }
        } else {
            Warn "sin -AuthKey: Tailscale queda instalado pero SIN unir"
            Info "unilo con:  tailscale up --authkey tskey-auth-... --unattended"
            Info "la key se crea en https://login.tailscale.com/admin/settings/keys"
        }
    }
}

# ─── 4. winget ───────────────────────────────────────────────────────────
Head "4. winget (instalar/actualizar programas)"
$wg = Get-Command winget -ErrorAction SilentlyContinue
if ($wg) {
    $ver = (winget --version) 2>$null
    Ok "winget disponible ($ver)"
} else {
    Warn "winget NO disponible"
    Info "se instala con 'App Installer' desde la Microsoft Store, o:"
    Info "  Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
}

# ─── Resumen ─────────────────────────────────────────────────────────────
Head "RESUMEN"
if ($Check -or $DryRun) {
    Info "Esto fue un diagnóstico. Para aplicar: .\setup-remote-target.ps1 -Apply -AuthKey tskey-auth-..."
} else {
    if ($script:Fail -eq 0) {
        Ok "Todo listo. Reiniciá si Windows lo pide (features de OpenSSH)."
    } else {
        Bad "$($script:Fail) problema(s). Revisá los mensajes de arriba."
    }
}
exit $script:Fail
