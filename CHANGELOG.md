# Changelog

Todos los cambios relevantes de este kit se documentan acá.
El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/)
y el versionado [SemVer](https://semver.org/lang/es/).

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
- **`windows/`** — kit para Windows 10/11: `setup-remote-target.ps1`,
  `inventory.ps1`, `rustdesk-password.ps1`, `diagnostico.ps1`
  (H-45..H-47, H-51..H-62).
- **`docs/hallazgos.md`** — H-01..H-63: problemas reales encontrados y su
  solución, con evidencia.
- **Documentación estratificada**: `docs/guia-desde-cero.md` (principiantes),
  `docs/referencia.md` (técnico), `docs/acceso-primero.md` (fijar el acceso
  antes de todo, H-53), `docs/tailscale.md`, `docs/onboarding-cliente.md`,
  `docs/agente-operador.md`, `docs/operador-multiple.md`, `docs/vpn-remoto.md`,
  `PASOS-EN-ORDEN.txt`, `LEEME-PRIMERO.txt`, `PROMPT-AGENTE.txt`.
- **Casos reales documentados**: `docs/caso-real-msi.md`,
  `docs/caso-real-apagon-solo.md`, `docs/caso-real-rai-omen.md`.
- **`SECURITY.md`** — política de seguridad y cómo reportar vulnerabilidades.
- **CI** (`.github/workflows/ci.yml`): shellcheck 0.10.0 fijo, `tests.sh`,
  `bash -n` y detección de secretos (claves privadas y auth keys).

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

[1.0.0]: https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi/releases/tag/v1.0.0
