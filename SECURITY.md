# Security Policy

Este repositorio contiene **scripts de administración remota** (RustDesk +
SSH + Tailscale). Se usan en equipos de producción de clientes, así que la
seguridad y el manejo responsable de hallazgos son parte del proyecto.

---

## Modelo de seguridad (qué hace y qué NO hace el kit)

Entender el diseño evita reportes que en realidad son comportamiento esperado.

**El kit hace:**

- Instala y configura **RustDesk unattended**, **sshd** y **Tailscale** en el
  equipo objetivo (el del cliente).
- Autoriza **la clave pública del operador** en el `authorized_keys` del
  usuario objetivo, con permisos correctos (`700 .ssh`, `600 authorized_keys`).
- Abre **solo el puerto 22/tcp** en el firewall detectado (ufw/firewalld/nftables).
- Registra una regla `sudo` **NOPASSWD acotada**: únicamente
  `/usr/bin/systemctl reboot` y `/usr/bin/systemctl poweroff` (H-27).
  **Nunca** `NOPASSWD: ALL`.
- Verifica la integridad del `.deb` oficial de RustDesk con **sha256** antes de
  extraerlo (necesario para `libdrmtap.so`, el capturador DRM de Wayland).

**El kit NO hace:**

- **No pide, transmite ni guarda la contraseña del cliente.** El acceso se
  establece con la **auth key de Tailscale** del cliente y la **clave pública
  SSH** del operador.
- **No instala el agente IA en el equipo del cliente.** El agente (`pi`) vive
  solo en el equipo del operador (ver `docs/referencia.md`).
- **No abre puertos en el router.** La conectividad se resuelve por Tailscale
  (WireGuard); no hace falta port forwarding.
- **No incluye claves privadas ni auth keys reales** en el repositorio. El CI
  lo comprueba en cada push (job `secrets`).

**El cliente conserva el control:**

- Puede revocar el acceso desde su panel de Tailscale
  (Machines → equipo → Disable).
- Puede quitar la línea del operador de `~/.ssh/authorized_keys`.
- Puede deshabilitar `sshd`, cerrar el puerto o desinstalar RustDesk en
  cualquier momento.

---

## Exposición de nombres de flota (`operadores/*.pub`)

El repo publica las claves **públicas** de cada equipo operador (p. ej.
`operadores/hp-operador.pub`). Las **privadas nunca** están en el repo: el
`.gitignore` las excluye y el CI tiene un job anti-fuga en cada push.

**Qué revela.** Publicar la `.pub` es correcto y necesario para el onboarding
(el cliente autoriza esa clave sin copiarla a mano). El único dato adicional que
expone es el **nombre del equipo operador**, visible en el archivo de la clave.

**Riesgo real.** Es **OSINT de baja severidad**, no un compromiso: los nombres
no permiten derivar la clave privada, ni entrar a la tailnet, ni abrir puertos.
Solo aportan contexto (cuántos operadores hay, cómo se llaman sus máquinas).

**Decisión.** Se **acepta el riesgo** de forma consciente a cambio de simplicidad:
mantener los nombres estables evita romper el onboarding y los `.pub` ya
publicados. Se revisó la alternativa de renombrar y se descartó por ahora.

**Mitigaciones si se quiere endurecer luego.** (1) Nombres **opacos** en los
archivos (`operadores/op-a1.pub`), mapeados a hosts reales fuera del repo;
(2) resolución por **URL firmada** (el `.pub` se entrega desde un servicio con
acceso temporal, no queda versionado). Ambas rompen onboarding, por eso hoy no
se aplican.

---

## Versiones soportadas

Las correcciones de seguridad se aplican sobre la **última versión publicada**
(ver *Releases*). Si usás una copia antigua del kit, actualizá a la última
release antes de reportar.

| Versión | Soportada |
|---|---|
| Última release publicada (`v1.x`) | ✅ |
| Copias sin versión / forks antiguos | ❌ |

---

## Reportar una vulnerabilidad

**No abras un issue público para vulnerabilidades de seguridad.**

1. Usá **GitHub Security Advisories**:
   `https://github.com/juanpablofuentealba/rustdesk-wlan-ssh-pi/security/advisories/new`
   (pestaña **Security → Report a vulnerability** del repositorio).
2. Si no podés usar advisories, escribí al correo del mantenedor que figura en
   el perfil de GitHub (`juanpablofuentealba`), con el asunto
   `[SECURITY] rustdesk-wlan-ssh-pi`.

### Qué incluir en el reporte

- Versión del kit (tag, o `git rev-parse HEAD`).
- Distro del equipo objetivo (Arch/Debian/Fedora) o versión de Windows.
- Descripción del problema y **impacto** (qué permite hacer un atacante).
- Pasos para reproducirlo (comandos exactos).
- Si aplica, prueba de concepto **mínima** y salida observada.

### Qué esperar

- **Acuse de recibo:** en un plazo razonable (repo mantenido por una persona;
  sin SLA formal).
- **Evaluación y fix:** se publica en la siguiente release, con crédito al
  reportero si lo desea.
- **Divulgación coordinada:** te pedimos no publicar el detalle hasta que haya
  un fix disponible.

---

## Fuera de alcance (no son vulnerabilidades del kit)

- Un operador con acceso legítimo puede leer/escribir en el equipo objetivo
  **por diseño** (es administración remota).
- Que el equipo objetivo sea alcanzable por Tailscale es **intencional**.
- Permisos débiles en un `authorized_keys` que el propio usuario modificó a
  mano después de instalar.
- Vulnerabilidades de **RustDesk, Tailscale u OpenSSH**: repórtalas en sus
  proyectos respectivos (aunque agradecemos que nos avises si el kit las
  amplifica).

---

## Buenas prácticas al usar el kit

- Usá **una identidad SSH por operador** (nunca compartas la clave privada;
  ver H-43 en `docs/hallazgos.md`).
- Generá auth keys de Tailscale con **expiración corta** para altas puntuales
  (`Reusable: NO`, `Ephemeral: NO`, `Expiry: 1 día`); ver `docs/tailscale.md`.
- Revisá periódicamente el `authorized_keys` de los clientes y retirá claves
  de operadores que ya no correspondan.
- No guardes claves privadas ni auth keys dentro del kit ni del repositorio.

---

## Licencia

MIT — ver [`LICENSE`](LICENSE). La licencia incluye la exención de garantía
habitual; este documento **no** la modifica.
