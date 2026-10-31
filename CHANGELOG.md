# Changelog

Todos los cambios relevantes de este kit se documentan acá.
El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/)
y el versionado [SemVer](https://semver.org/lang/es/).

## [1.2.0] — 2026-10-31

**Refactor estructural + seguridad**: el monolito pasa a módulos, un helper
único de sudo, y varios ajustes de seguridad. Se resuelven los issues #27–#32.

### Añadido

- **`lib/` (8 módulos)** — `setup-remote-target.sh` se parte en módulos que se
  cargan con `source`. El archivo pasa de **1.629 → 219 líneas** (orquestador):
  - `lib/sudo.sh` — helper **único** de sudo (ver abajo).
  - `lib/sr-t-ui.sh` — colores y `ok/warn/err/info/hdr`.
  - `lib/sr-t-distro.sh` — detección de distro y `pkg_*`.
  - `lib/sr-t-core.sh` — helpers base (`run`, `confirm`, `need_root`, firewall).
  - `lib/sr-t-deps.sh` — dependencias/AUR de RustDesk.
  - `lib/sr-t-rustdesk.sh` — instalación de RustDesk por familia + DRM.
  - `lib/sr-t-ssh.sh` — `setup_ssh` (sshd + firewall).
  - `lib/sr-t-tailscale.sh` — `setup_tailscale` + `setup_laptop`.
  - `lib/sr-t-check.sh` — `run_check` (diagnóstico `--check`).
  Al usar `source`, una variable global compartida (`TS_HOSTNAME`) se **exporta**
  para evitar el aviso SC2034.
- **`verify-docs-consistency.sh`** — comprueba coherencia **entre** documentos:
  conteo de tests, versión (README vs. CHANGELOG) y enlaces internos (127
  revisados). Corrige drift ya existente (README v1.0.0→v1.1.1, AGENTS ~474→~667).
- **`--sha256 <hex>` en `onboarding.sh`** — verifica el hash del tarball del kit
  antes de extraer/ejecutar.

### Cambiado

- **Seguridad — helper único de sudo (issue #28).** Antes cada script resolvía
  la clave a su manera (`sudo -S`, `sudow`/SUDO_ASKPASS, archivos); esa dispersión
  causó **H-68** (`sudo -S` se comía stdin). Ahora todo pasa por `lib/sudo.sh`
  con `sudo -A` (askpass), dejando **stdin libre** para datos. Migrados:
  `instalar-todo.sh`, `rustdesk-password.sh`, `energia-remota.sh`,
  `install-rustdesk-unattended-fedora.sh`. `sudow` se conserva como alias.
- **Seguridad — sin `eval` sobre entrada del operador (issue #31).**
  `wol-despertar.sh` parte `--check` con `read -ra` y lo ejecuta directo (valida
  el ejecutable); `instalar-todo.sh` pasa a `chk()` con funciones.
- **Onboarding sin `curl | sudo bash` (issue #32).** La doc
  (`README.md`, `INSTALAR.md`, `REPO.txt`, `LEEME-PRIMERO.txt`,
  `docs/onboarding-cliente.md`) pasa a **descargar → verificar → ejecutar**,
  mencionando siempre `git clone` y `--local <dir>`.
- **`make-kit.sh`** incluye `lib/` (todos los módulos) en el kit empaquetado.
- **CI** lint-ea `lib/*.sh` (shellcheck + `bash -n`).

### Documentado

- **`docs/resumen.md`** — resumen ejecutivo de **1 página**.
- **`docs/test-fuera-de-lan.md`** — cómo usar `verify-offlan.sh` bien (otra red,
  detección de falso positivo, checklist antes de irse).
- **`SECURITY.md`** — sección *Exposición de nombres de flota*
  (`operadores/*.pub`): OSINT de baja severidad, riesgo aceptado y mitigaciones.

### Corregido

- **`verify-docs.sh`** — tras partir el monolito, la comprobación de assets
  `sciter/suse` apunta a `lib/sr-t-rustdesk.sh`.
- **IP real → ejemplo ficticio** en `docs/test-fuera-de-lan.md` (lo detectó el
  test anti-fuga de `tests.sh`).

### Notas

- **Tests:** `./tests.sh` → 755 OK · 0 fallos (2 omitidos).
- **Cierra:** #27, #28, #29, #30, #31, #32.

## [1.1.1] — 2026-10-31

**Documentación**: resumen ejecutivo y test fuera de la LAN, en el repo.

### Añadido

- **`docs/resumen.md`** — resumen ejecutivo de **una página**: qué es el kit, las
  3 piezas, instalación en 3 comandos, checklist previo, scripts clave, distros
  y mapa de "qué doc abrir". Pensado para no releer ~900 líneas.
- **`docs/test-fuera-de-lan.md`** — cómo usar bien `verify-offlan.sh`: los **3
  puntos que importan** (otra red, detección del falso positivo `⚠ ruta LAN` con
  exit 2, veredicto verde), tabla de fallos típicos y checklist antes de irse.

### Cambiado

- **`README.md`** — aviso *"¿Poco tiempo? → `docs/resumen.md`"* al inicio y dos
  filas nuevas en la tabla de Documentación.
- **`docs/resumen.md`** — enlaza `docs/test-fuera-de-lan.md`.

## [1.1.0] — 2026-10-30

**Onboarding en una línea**: dar de alta un cliente nuevo sin clonar nada.

### Añadido

- **`onboarding.sh`** — instalador de **una línea**: baja y verifica el kit
  (MANIFEST), autoriza las claves de los operadores desde `operadores/*.pub`,
  corre `instalar-todo.sh` y **emite la ficha** (ID/contraseña/IP tailnet).
  Soporta `--operador-hosts`, `--tailnet-host`, `--local` (offline),
  `--authkey-stdin`, `--skip-tailscale`, `--tailscale-luego`, `--dry-run`.
- **`operadores/`** — claves **públicas** de la flota, una por operador
  (`id_<host>.pub` → `operadores/<host>.pub`). El onboarding las resuelve por
  nombre; las privadas nunca van al repo (H-43).
- **`docs/onboarding-cliente.md`** — guía del flujo completo operador → cliente
  → verificación.
- **`nuevo-cliente.sh`** (en el operador, fuera del repo) — genera ficha, kit
  con `operador.pub` y MANIFEST verificado, y **la línea de onboarding** con la
  contraseña ya generada.
- **`--tailnet-host`** en `instalar-todo.sh` y `setup-remote-target.sh`: fija el
  nombre del equipo en la tailnet (`cliente-<nombre>` por defecto).

### Cambiado

- **`make-kit.sh`** ahora incluye `onboarding.sh`, `operadores/`,
  `wol-despertar.sh`, `energia-remota.sh`, `AGENTS.md` y `README.md`.
- **H-67**: `trusted_devices` sin `unlock_pin` hace que RustDesk pida la
  contraseña personal (no confundir con la de acceso remoto).

## [1.0.0] — 2026-10-30

Primera versión estable del kit: **administración remota de punta a punta**
(RustDesk unattended + SSH + Tailscale), probada en campo sobre Arch, Debian y
Fedora, con kit aparte para Windows 10/11.

### Añadido

- **`instalar-todo.sh`** — un solo comando que hace todo en el equipo del
  cliente: RustDesk unattended + sshd + firewall + clave del operador +
  Tailscale + anti-suspensión de portátil + contraseña + verificación.
  Con `--dry-run` (simulacro) y `--tailscale-luego`.
- **`setup-remote-target.sh`** — configuración por partes con `--check`
  (diagnóstico), `--dry-run` (simulacro) y `--laptop`.
- **`unir-tailscale.sh`** — une el equipo a la tailnet pidiendo/pegando la
  auth key (H-30).
- **`laptop-no-suspend.sh`** — evita que los portátiles suspendan y se pierda
  el acceso remoto (H-29).
- **`reboot-remoto.sh`** — reinicio remoto desatendido mediante una regla
  `sudo` **NOPASSWD acotada** (solo `reboot`/`poweroff`, nunca `ALL`; H-27).
- **`update.sh`** — mantenimiento: actualiza sistema + RustDesk + Tailscale
  (Arch/Debian/Fedora), con `--check` y `--dry-run`.
- **`rustdesk-password.sh`** — fija la contraseña permanente de RustDesk (H-15).
- **`install-rustdesk-unattended-fedora.sh`** — RustDesk con capturador DRM en
  Fedora/RHEL extrayéndolo del `.deb` oficial (H-14).
- **`verify-offlan.sh`** — verifica el acceso desde fuera de la LAN.
- **`inventory.sh`** — ficha de specs del equipo (texto/JSON/Markdown).
- **`clip-vm.sh`** — puente de portapapeles host↔VM por SSH.
- **`verify-docs.sh`** — valida comandos de Tailscale y URLs de la documentación.
- **`make-kit.sh`** — empaqueta el kit para pendrive o tarball.
- **`tests.sh`** — pruebas de humo antes de un cliente nuevo (653 en entorno
  Linux completo; las dependencias ausentes se omiten, no fallan).
- **`wol-despertar.sh`** — despierta (Wake-on-LAN) un equipo apagado usando
  al operador como relé dentro de su LAN (H-64).
- **`energia-remota.sh`** — apaga/reinicia un equipo remoto por SSH, con la
  clave `sudo` por STDIN (nunca en `ps`).
- **`windows/`** — kit para Windows 10/11: `setup-remote-target.ps1`,
  `inventory.ps1`, `rustdesk-password.ps1`, `diagnostico.ps1`
  (H-45..H-47, H-51..H-62).
- **`docs/hallazgos.md`** — H-01..H-66: problemas reales encontrados y su
  solución, con evidencia (incluye **H-64** WoL remoto con el operador como
  relé, **H-65** Tailscale en Android vía `proot`+userspace y **H-66** SSH
  caído con el equipo vivo: `tailscale ping` OK ≠ `sshd` funcionando).
- **Documentación estratificada**: `docs/guia-desde-cero.md` (principiantes),
  `docs/referencia.md` (técnico), `docs/acceso-primero.md` (fijar el acceso
  antes de todo, H-53), `docs/tailscale.md`, `docs/onboarding-cliente.md`,
  `docs/agente-operador.md`, `docs/operador-multiple.md`,
  `docs/android-operador.md`, `docs/wol-y-energia-remota.md`,
  `docs/vpn-remoto.md`, `PASOS-EN-ORDEN.txt`, `LEEME-PRIMERO.txt`,
  `PROMPT-AGENTE.txt`.
- **Casos reales documentados**: `docs/caso-real-msi.md`,
  `docs/caso-real-apagon-solo.md`, `docs/caso-real-rai-omen.md`.
- **`SECURITY.md`** — política de seguridad y cómo reportar vulnerabilidades.
- **`windows/tests-windows.ps1`** — pruebas de humo del kit Windows
  (sintaxis, parámetros, reglas de seguridad); no toca el sistema.
- **CI** (`.github/workflows/ci.yml`): shellcheck 0.10.0 fijo, `tests.sh`,
  `bash -n`, detección de secretos (claves privadas y auth keys),
  **PSScriptAnalyzer** sobre `windows/` y **`tests-windows.ps1`** en runner
  `windows-latest`.
- **`docs/hallazgos.md`**: índice agrupado por categoría, con **top 10** para
  nuevos lectores.
- **`CHANGELOG.md`** y etiqueta **`v1.0.0`**.

### Notas de diseño

- **Multi-distro real**: Arch (CachyOS/Manjaro/EndeavourOS), Debian
  (Ubuntu/Mint/Pop!_OS) y Fedora (RHEL/Rocky/AlmaLinux), con detección por
  familia vía `/etc/os-release`.
- En **Arch y Fedora se usa el `.deb` oficial** de RustDesk porque es el único
  que trae `libdrmtap.so` (captura DRM para unattended en Wayland). El kit lo
  descarga, verifica su **sha256** y lo extrae a mano (H-14, H-24).
- **Seguridad por diseño**: no se pide ni guarda la contraseña del cliente; se
  usa auth key de Tailscale + clave pública SSH del operador, con una identidad
  por operador (H-43).
- **El agente IA vive solo en el equipo del operador**, nunca en el del
  cliente.

### Verificado en campo

- Instalación y mantención de punta a punta en un cliente real
  (`docs/caso-real-msi.md`).
- Diagnóstico de "se apaga solo" en Windows = Modern Standby
  (`docs/caso-real-apagon-solo.md`, `docs/caso-real-rai-omen.md`).
- Malla de **3 operadores** (HP, MSI y móvil Android/Termux) todos-contra-todos
  (`docs/operador-multiple.md`, H-63).
- Despertar un equipo **apagado** (WoL con el operador como relé) y apagado/
  reinicio remoto por SSH (`docs/wol-y-energia-remota.md`, H-64).
- Tailscale en Android **sin** los binarios de Termux, vía `proot`+userspace
  (`docs/android-operador.md`, H-65).
- Corte de SSH con el equipo encendido y en uso: diagnóstico por capas
  (RustDesk > puerto 22 > login > `tailscale ping`) y regla de **no intervenir**
  mientras el cliente usa el equipo (`docs/caso-real-rai-omen.md`, H-66).

[1.0.0]: https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi/releases/tag/v1.0.0
