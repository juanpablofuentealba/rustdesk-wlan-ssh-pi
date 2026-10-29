<#
.SYNOPSIS
  rustdesk-password.ps1 — Fija la contraseña permanente de RustDesk en Windows.

.DESCRIPTION
  Sin contraseña permanente, el acceso unattended es imposible (ver H-15 del
  kit de Linux: un RustDesk "unattended" con contraseña temporal pide PIN cada
  vez). Este script fija la contraseña permanente de RustDesk en Windows.

  Estrategia:
    1. Intenta con la CLI de RustDesk (--password), si la versión la soporta.
    2. Si no, escribe el valor cifrado en la config de RustDesk del usuario.
       RustDesk guarda la contraseña (cifrada) en:
         %APPDATA%\RustDesk\config\RustDesk.toml
       con la clave  password = '<cifrado>'  dentro de [options].
       No se puede escribir el cifrado a mano; hay que dejar que RustDesk lo haga.

  Por eso el método FIABLE es por la GUI (una sola vez, por RustDesk remoto):
    Ajustes → Seguridad → "Contraseña permanente" → fijar la clave.

  Este script:
    - verifica si ya hay contraseña permanente;
    - si no, guía para fijarla (y ofrece intentar por CLI).

.USO
  .\rustdesk-password.ps1 -Check
  .\rustdesk-password.ps1 -Set -Password 'MiClaveSegura'
#>

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Set,
    [string]$Password = ""
)

# Nota: -Set es un switch; la clave va SIEMPRE en -Password.
#   .\rustdesk-password.ps1 -Set -Password 'MiClave'

$ErrorActionPreference = "SilentlyContinue"
function Ok($m){Write-Host "  [OK]    $m" -ForegroundColor Green}
function Bad($m){Write-Host "  [FALLO] $m" -ForegroundColor Red}
function Warn($m){Write-Host "  [AVISO] $m" -ForegroundColor Yellow}
function Info($m){Write-Host "  [info]  $m" -ForegroundColor Cyan}

# encontramos el exe
$rdExe = @(
    "C:\Program Files\RustDesk\rustdesk.exe",
    "$env:ProgramFiles\RustDesk\rustdesk.exe",
    "${env:ProgramFiles(x86)}\RustDesk\rustdesk.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $rdExe) { Bad "RustDesk no está instalado (corré primero setup-remote-target.ps1)"; exit 1 }
Ok "RustDesk: $rdExe"

$cfg = Join-Path $env:APPDATA "RustDesk\config\RustDesk.toml"

if ($Check -or -not $Set) {
    if (Test-Path $cfg) {
        $t = Get-Content $cfg -Raw
        if ($t -match 'password\s*=\s*''([^'']+)''') {
            Ok "hay una contraseña permanente fijada (cifrada, $($Matches[1].Length) chars)"
        } else {
            Warn "NO hay contraseña permanente → unattended pedirá PIN cada vez (H-15)"
            Info "fijala con: .\rustdesk-password.ps1 -Set 'TuClave'   (o por la GUI)"
        }
    } else {
        Warn "no existe $cfg (¿RustDesk arrancó alguna vez como este usuario?)"
        Info "abrí RustDesk una vez y reintentá."
    }
    Info "GUI: Ajustes (engranaje) → Seguridad → Contraseña permanente"
    exit 0
}

# --- -Set ---
if (-not $Password) { Bad "-Set requiere -Password 'TuClave'"; exit 1 }
if ($Password.Length -lt 8) { Warn "clave corta (<8). RustDesk recomienda 8+." }

Info "intentando fijar la contraseña por CLI..."
# OJO: 2>$null en un exe nativo NO siempre silencia su stderr; usar 2>&1 | Out-Null
& $rdExe --password $Password 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Ok "contraseña fijada por CLI"
    exit 0
}

Warn "esta versión de RustDesk no acepta --password por CLI"
Info "Hay que fijarla por la GUI (una vez, por RustDesk remoto):"
Info "  Ajustes (⚙) → Seguridad → 'Contraseña permanente' → escribí: $Password"
Info "  (después podés olvidarla; queda guardada cifrada en la config)"
exit 3
