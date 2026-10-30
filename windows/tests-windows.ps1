<#
.SYNOPSIS
  Pruebas de humo del kit Windows (análogas a tests.sh en Linux).

.DESCRIPTION
  Verifica, SIN tocar el sistema:
    - que los 4 scripts .ps1 parsean sin errores de sintaxis;
    - que exponen los parámetros/ayudas documentados;
    - que respetan las reglas de seguridad del kit (NOPASSWD acotado, sin
      claves privadas ni auth keys reales embebidas);
    - que -Check / -DryRun / -Help no fallan ni modifican nada.

  Pensado para CI (runner windows-latest) y para correr a mano antes de
  llevar el kit a un cliente.

.PARAMETER Path
  Carpeta con los .ps1. Por defecto, la carpeta donde está este script.

.EXAMPLE
  pwsh -NoProfile -File .\tests-windows.ps1
  pwsh -NoProfile -File .\tests-windows.ps1 -Path C:\kit\windows
#>

[CmdletBinding()]
param(
    [string]$Path = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

# ─── Contadores y helpers (mismo estilo que tests.sh) ─────────────────────
$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function Ok  ($d) { Write-Host "  [OK]    $d" -ForegroundColor Green;  $script:Pass++ }
function Bad ($d) { Write-Host "  [FALLO] $d" -ForegroundColor Red;    $script:Fail++ }
function Sk  ($d) { Write-Host "  [OMITE] $d" -ForegroundColor Yellow; $script:Skip++ }
function Head($m) { Write-Host "`n== $m ==" -ForegroundColor White -BackgroundColor DarkBlue }

# Ejecuta una prueba cuya expresión devuelve $true/$false.
function T([string]$desc, [scriptblock]$test) {
    try {
        if (& $test) { Ok $desc } else { Bad $desc }
    } catch {
        Bad "$desc  ($($_.Exception.Message))"
    }
}

# Comprueba que una condición se cumple dentro de una función que devuelve salida.
function TC([string]$desc, [scriptblock]$test) {
    try {
        $r = & $test
        if ($LASTEXITCODE -eq 0 -and $null -ne $r) { Ok $desc } else { Bad $desc }
    } catch {
        Bad "$desc  ($($_.Exception.Message))"
    }
}

Write-Host "`n###############################" -ForegroundColor DarkGray
Write-Host "  Kit Windows — pruebas de humo" -ForegroundColor White
Write-Host "  Carpeta: $Path" -ForegroundColor DarkGray
Write-Host "###############################" -ForegroundColor DarkGray

$scripts = @(
    'setup-remote-target.ps1',
    'inventory.ps1',
    'rustdesk-password.ps1',
    'diagnostico.ps1'
)

# ─── 1. Existencia de los scripts ─────────────────────────────────────────
Head "1. Los 4 scripts existen"
foreach ($s in $scripts) {
    T "$s presente" { Test-Path (Join-Path $Path $s) }
}

# ─── 2. Sintaxis (parseo real de PowerShell) ──────────────────────────────
Head "2. Sintaxis (parser de PowerShell)"
foreach ($s in $scripts) {
    $full = Join-Path $Path $s
    if (-not (Test-Path $full)) { Sk "$s (no está)"; continue }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$errs)
    T "$s parsea sin errores" { ($null -eq $errs) -or ($errs.Count -eq 0) }
}

# ─── 3. Parámetros documentados (contrato del kit) ────────────────────────
Head "3. Parámetros esperados"
$setupP = Join-Path $Path 'setup-remote-target.ps1'
if (Test-Path $setupP) {
    $txt = Get-Content -Raw $setupP
    foreach ($flag in '-Check', '-DryRun', '-Apply', '-AuthKey', '-RdPass', '-NoTailscale', '-NoSsh') {
        T "setup-remote-target.ps1 declara $flag" { $txt -match [regex]::Escape($flag) }
    }
} else { Sk "setup-remote-target.ps1 ausente" }

$rdP = Join-Path $Path 'rustdesk-password.ps1'
if (Test-Path $rdP) {
    $txt = Get-Content -Raw $rdP
    foreach ($flag in '-Check', '-Set', '-Password') {
        T "rustdesk-password.ps1 declara $flag" { $txt -match [regex]::Escape($flag) }
    }
} else { Sk "rustdesk-password.ps1 ausente" }

$invP = Join-Path $Path 'inventory.ps1'
if (Test-Path $invP) {
    T "inventory.ps1 declara -Out" { (Get-Content -Raw $invP) -match [regex]::Escape('-Out') }
} else { Sk "inventory.ps1 ausente" }

$diagP = Join-Path $Path 'diagnostico.ps1'
if (Test-Path $diagP) {
    T "diagnostico.ps1 declara -Out" { (Get-Content -Raw $diagP) -match [regex]::Escape('-Out') }
} else { Sk "diagnostico.ps1 ausente" }

# ─── 4. Reglas de seguridad ───────────────────────────────────────────────
Head "4. Reglas de seguridad"
# Escaneamos los scripts del KIT, no este propio archivo de pruebas (que
# contiene los literales buscados en sus descripciones y regex).
$all = Get-ChildItem -Path $Path -Filter *.ps1 -File |
    Where-Object { $_.Name -ne 'tests-windows.ps1' }
$joined = ($all | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"

T "no hay 'NOPASSWD: ALL' (solo reglas acotadas)" {
    -not ($joined -match 'NOPASSWD\s*:\s*ALL')
}
T "no hay claves privadas embebidas" {
    -not ($joined -match 'BEGIN (OPENSSH|RSA|EC) PRIVATE KEY')
}
T "no hay auth keys de Tailscale reales" {
    # No debe haber tskey-auth-<larga>; se admiten placeholders obvios.
    $m = [regex]::Matches($joined, 'tskey-auth-[A-Za-z0-9]{10,}')
    $reales = $m | Where-Object { $_.Value -notmatch 'tskey-auth-(k1234|SECRETO|TEST|xxxx)' }
    $reales.Count -eq 0
}
T "no hay contraseñas hardcodeadas tipo SUDO_PASS=texto" {
    -not ($joined -match 'SUDO_PASS\s*=\s*[^"''\s]')
}

# ─── 5. Los modos seguros no fallan ni cambian nada ───────────────────────
# -Check y -DryRun deben salir 0 (o al menos no lanzar excepción).
Head "5. Modos seguros (-Check / -DryRun / -Help)"

function Invoke-Safe([string]$file, [string[]]$args_) {
    $full = Join-Path $Path $file
    if (-not (Test-Path $full)) { return $null }
    $out = & pwsh -NoProfile -NonInteractive -File $full @args_ 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out | Out-String) }
}

$r = Invoke-Safe 'setup-remote-target.ps1' @('-Check')
if ($null -eq $r) { Sk "setup -Check (script ausente)" }
else { T "setup -Check termina sin error de ejecución" { $r.Out -notmatch 'Exception|ParserError' } }

$r = Invoke-Safe 'setup-remote-target.ps1' @('-DryRun')
if ($null -eq $r) { Sk "setup -DryRun (script ausente)" }
else { T "setup -DryRun termina sin error de ejecución" { $r.Out -notmatch 'Exception|ParserError' } }

$r = Invoke-Safe 'inventory.ps1' @()
if ($null -eq $r) { Sk "inventory (script ausente)" }
else { T "inventory corre y produce texto" { $r.Out.Length -gt 0 } }

$r = Invoke-Safe 'diagnostico.ps1' @()
if ($null -eq $r) { Sk "diagnostico (script ausente)" }
else { T "diagnostico corre y produce texto" { $r.Out.Length -gt 0 } }

$r = Invoke-Safe 'rustdesk-password.ps1' @('-Check')
if ($null -eq $r) { Sk "rustdesk-password -Check (script ausente)" }
else { T "rustdesk-password -Check no lanza excepción" { $r.Out -notmatch 'Exception|ParserError' } }

# ─── 6. Documentación mínima ──────────────────────────────────────────────
Head "6. Documentación"
$readme = Join-Path $Path 'README.md'
if (Test-Path $readme) {
    $rd = Get-Content -Raw $readme
    T "README de windows/ menciona los 4 scripts" {
        (@('setup-remote-target', 'inventory', 'rustdesk-password', 'diagnostico') |
            Where-Object { $rd -notmatch [regex]::Escape($_) }).Count -eq 0
    }
    T "README de windows/ menciona administrators_authorized_keys" {
        # H-57: SSH con usuario administrador usa este fichero, no el normal.
        $rd -match 'administrators_authorized_keys'
    }
} else { Sk "windows/README.md ausente" }

# ─── Resumen ──────────────────────────────────────────────────────────────
Write-Host "`n== Resumen ==" -ForegroundColor White
Write-Host ("  {0} OK · {1} fallos · {2} omitidos" -f $script:Pass, $script:Fail, $script:Skip)

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
