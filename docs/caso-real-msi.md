# Caso real: el MSI (cliente de referencia)

> **Qué es esto.** La primera instalación y mantención **real, de punta a punta**,
> con este kit: no un laboratorio, sino una máquina de trabajo que se administra
> a diario desde el PC del operador. Sirve como runbook probado y como evidencia
> de que el kit funciona en producción.
>
> Fecha: 26–28 de octubre de 2026 · Operador: HP (CachyOS, `hp-operador`).

---

## La máquina (cliente)

| Campo | Valor |
|---|---|
| Hostname | `MSI` |
| Distro | CachyOS (Arch) |
| Kernel | `7.3.0-4-cachyos` |
| CPU | AMD Ryzen 7 5700G (con Radeon) |
| RAM | 13 GiB |
| GPU | AMD Cezanne (Vega) |
| Disco `/` | 473 GB |
| RustDesk ID | `<id>` (oculto) |
| Tailscale IP | `100.x.y.z` (rango CGNAT de Tailscale) |

No es un portátil: es un **escritorio**. Por eso la parte `--laptop`
(anti-suspensión) no aplica aquí; se aplicó igual por precaución y se puede quitar.

---

## Cómo se instaló (con el kit)

Se clonó el repo **en el propio cliente** y se aplicó el kit:

- `/home/jp/rustdesk-wlan-ssh-pi` — el repo clonado (rama `main`).
- `/home/jp/rustdesk-unattended/` — artefactos del kit:
  - `60-rustdesk-uinput.rules` — regla udev para el control (uinput) en Wayland.
  - `rustdesk-uinput.conf` — módulo uinput al arranque.
  - `LEEME.md`.
- RustDesk **unattended-wayland con `libdrmtap`** (`/usr/lib/rustdesk/libdrmtap.so.0`).
  Es la vía del `.deb` oficial (H-14), no el paquete del repo de la distro.
- `sshd`, `tailscaled` y `rustdesk` activos.
- `sleep.target`/`suspend.target` enmascarados (anti-suspensión).

**Verificación del método:** la presencia de `libdrmtap` y de
`~/rustdesk-unattended/` confirma que se usó el kit, no una instalación manual
suelta.

---

## El operador (HP)

- Tailscale como `hp-operador` (`100.x.y.z`), MagicDNS activo.
- Clave SSH del operador (`~/.ssh/id_ed25519`, `pi-agent@MSI`) autorizada en el
  cliente → entrada **sin contraseña**.
- Scripts propios del operador (no van en este repo):
  `conectar.sh`, `ayudar.sh`, `flota.sh`, `alta-cliente.sh`.

---

## Sesión real de mantención (28 oct 2026)

Todo esto se hizo **desde el HP, sin tocar el MSI físicamente**:

| # | Tarea | Cómo |
|---|---|---|
| 1 | Ver el estado | `tailscale status`, `ssh msi hostname` |
| 2 | Revisar actualizaciones | `pacman -Syu` ya ejecutado; 0 pendientes |
| 3 | **Reinicio remoto** | `systemctl reboot` por SSH; verificado con `boot_id` distinto |
| 4 | Confirmar kernel nuevo | `uname -r` tras el reinicio |
| 5 | Diagnóstico completo | servicios, disco, RAM, logs de RustDesk |
| 6 | Limpiar unidad fallida | `duckdns-update.service` (limpiada) |
| 7 | Desinstalar DWAgent | uninstaller oficial + limpieza de restos |
| 8 | Eliminar DuckDNS | timer + service + script |
| 9 | Auditoría de software | eliminados: waydroid (+imagen 3 GB), jellyfin, antigravity, opencode×2, electron28, freetube, restos de Opera GX |
| 10 | Limpiar `~/.cache` | 27 GB → 2.9 GB (paru 19 GB, Shelly 4.2 GB, …) |
| 11 | Reducir gaming a Steam | quitado el metapaquete; Steam conservado (marcado `--asexplicit`) |
| 12 | Corregir Proton | `CompatToolMapping` global: `proton-cachyos-slr` → `proton_experimental` |
| 13 | Verificación final | servicios OK, 0 huérfanos, disco 71% → 64% |

**Resultado:** ~30 GB liberados, equipo actualizado, todo lo que se usa intacto.

---

## Qué funcionó bien

1. **RustDesk unattended en Wayland.** Pantalla y control desde el HP, con el
   capturador DRM (`libdrmtap`). Es el punto más difícil y funcionó.
2. **SSH por Tailscale sin contraseña.** La operación real (shell, paquetes,
   logs) fue fluida.
3. **MagicDNS.** Resolver `msi` por nombre en vez de IP.
4. **Anti-suspensión.** El equipo no se durmió durante la sesión.
5. **Reinicio remoto verificable.** El `boot_id` confirmó que fue real.
6. **Los hallazgos del kit se usaron en vivo:**
   - H-14 cuando RustDesk intentó X11/portal teniendo Wayland.
   - H-23 cuando un `for` de bash falló por el shell **fish** del cliente.
   - H-32 al preguntarse si el `pacman -Syu` rompería `libdrmtap` (no ocurrió).

---

## Qué costó / salió mal

1. **Intervención manual frecuente.** La instalación del kit es automática, pero
   la *mantención* necesitó decisión humana en casi cada paso (qué borrar, qué
   dejar). El agente asiste, no reemplaza al operador todavía.
2. **`sudo` bloquea la automatización.** Casi todo cambio requiere `sudo`, que
   pide contraseña. En una sesión con un agente sin TTY hay que recurrir a un
   `sudoers.d` temporal (`99-temp-jp`) y **borrarlo al final** — paso propenso a
   olvido. El kit debería tener una vía más limpia para esto.
3. **H-36 apareció aquí.** En Arch, la instalación por `.deb` dejaba RustDesk
   sin entrada de menú ni icono de bandeja (ya corregido en el kit).
4. **Huecos del metapaquete.** `wine-cachyos-opt` y `heroic-games-launcher` no
   se pueden quitar solos: los exige `cachyos-gaming-*`. Pista para documentar
   el desmontaje limpio del gaming.

---

## Lecciones

- **Un cliente de verdad, no un laboratorio, es la única prueba que vale.** El
  MSI fue instalado en su momento y administrado hoy; cada hueco real apareció
  usándolo (H-36), no en un test.
- **El valor del kit está en la doc + el método de RustDesk**, más que en la
  automatización total.
- **`sudo` es el cuello de botella** para que un agente opere solo. Es el
  siguiente problema a resolver.
- **Revisar siempre `pactree -r` antes de desinstalar metapaquetes:** lo que
  parece "una app de más" suele estar atado por un meta (gaming) y arrastraría
  cosas que sí se usan (Steam, Proton).

---

## Reproducir

Desde el operador (con la clave ya autorizada en el cliente):

```bash
tailscale status | grep msi
ssh jp@msi 'hostname'                       # confirmar acceso
ssh jp@msi 'bash -s' <<'EOF'
systemctl is-active rustdesk sshd tailscaled
test -e /usr/lib/rustdesk/libdrmtap.so.0 && echo "unattended OK"
EOF
```

Reinicio remoto verificable:

```bash
before=$(ssh jp@msi cat /proc/sys/kernel/random/boot_id)
ssh jp@msi 'sudo systemctl reboot' || true
# esperar ~1 min; reconectar
after=$(ssh jp@msi cat /proc/sys/kernel/random/boot_id)
[ "$before" != "$after" ] && echo "reinicio real confirmado"
```
