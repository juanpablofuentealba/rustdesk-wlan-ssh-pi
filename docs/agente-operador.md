# El agente IA como operador remoto

> Cómo usar un agente IA (**Pi**, OpenCode, Claude…) **desde el PC del
> operador** para administrar los PC de los clientes a los que les instalaste
> este kit. El agente **no** vive en el PC del cliente: vive en el tuyo y
> alcanza al cliente por **Tailscale + SSH**.

Complementa a [`PROMPT-AGENTE.txt`](../PROMPT-AGENTE.txt), que sirve para la
**instalación en el cliente**. Este documento es para **operar** después.

---

## Idea

Una vez el cliente tiene RustDesk + sshd + Tailscale y tu clave autorizada,
el agente del operador puede —por SSH— hacer mantención de verdad:
diagnosticar, actualizar, revisar logs, reiniciar y verificar.

```
   TU PC (operador, con el agente)                PC del CLIENTE
 ┌─────────────────────────────────┐            ┌──────────────────────┐
 │  agente IA  ──►  ssh cliente-X   │  Tailscale │  sshd                │
 │       │                          │ ─────────► │  RustDesk (ver)      │
 │       └─►  RustDesk (GUI, ver)   │            │  tailscaled          │
 └─────────────────────────────────┘            └──────────────────────┘
```

- **Ver/controlar pantalla** → RustDesk (GUI; el agente no maneja GUI).
- **Trabajar** → SSH (shell, logs, paquetes): esto es lo que maneja el agente.

---

## Reglas duras para el agente operador

Heredadas de los hallazgos del kit ([`hallazgos.md`](hallazgos.md)):

1. **Nunca mandes bash suelto pegado por SSH** si el cliente puede usar fish:
   usá `bash -s` por stdin (H-23).
2. **No reinicies un cliente sin avisar** (H-27). Si hace falta, `reboot-remoto.sh`.
3. **Buscá en `hallazgos.md` antes de improvisar** un arreglo.
4. **Un portátil cliente que suspende pierde el acceso** (H-29).
5. **No instales `pi`/el agente en el PC del cliente** (ver `estado-sesion.md`,
   "Modelo de producto"): el cliente no lo necesita.
6. Antes de escribir en config privilegiada (sudoers, etc.), **validá la entrada**
   (H-33).

---

## Flujos típicos (lo que le pedís al agente)

### Dar de alta / verificar un cliente
> *"Verificá que el cliente `cliente-juan` quedó bien instalado."*

El agente debería:
1. `ssh -o BatchMode=yes jp@cliente-juan true` (¿responde sin contraseña?).
2. Si no responde, `tailscale status | grep cliente-juan` (¿está en la tailnet?
   ¿online?). Recordá: si la key del operador no está autorizada, SSH pedirá
   contraseña y `BatchMode` falla.
3. Si responde, recopilar: `hostname`, distro, `systemctl is-active rustdesk`,
   `sshd`, `tailscaled`, y comprobar `libdrmtap` si es Wayland (H-14).

### El cliente reporta un problema
> *"El cliente `cliente-maria` no puede conectarse por RustDesk, revisá."*

1. ¿Online en Tailscale? ¿Responde SSH?
2. `journalctl -u rustdesk -n 50` en el cliente → buscar el síntoma exacto.
3. Cruzar con `hallazgos.md`:
   - `cannot open display :0` / portal falla → H-14 (falta DRM, es Wayland).
   - `drm: consumer cache warmed` ausente → H-32 (libdrmtap roto tras update).
   - Sin contraseña permanente → H-15.

### Mantenimiento
> *"Actualizá el cliente `cliente-pedro` y avisá qué cambió."*

Preferí el `update.sh` del kit (que ya verifica `libdrmtap` tras actualizar, H-32)
antes que un `pacman -Syu` a mano.

---

## Seguridad (importante)

- El agente del operador **tiene tu clave SSH**: quien controle al agente,
  controla tus clientes. Tratalo como una herramienta privilegiada.
- **No pegues tokens en el chat del agente** (auth keys, contraseñas). Pasalos
  por stdin o variables de entorno (H-34, y el aviso de `--authkey`).
- El cliente **conserva el control**: puede revocar tu acceso quitando tu línea
  de `authorized_keys` o deshabilitándote en su panel de Tailscale.

---

## Estructura sugerida en el PC del operador

```
~/operador/
├── kit/                 # el kit (se copia al cliente)
├── clientes/            # ficha + diagnósticos de cada cliente
│   └── <host>/
├── alta-cliente.sh      # prepara la instalación de un cliente nuevo
├── conectar.sh <host>   # verifica Tailscale + SSH
├── ayudar.sh <host>     # diagnóstico y guardado
└── flota.sh [-a]        # estado de todos los clientes
```

> Estos scripts de operador son **propios de cada operador** y no van en este
> repo (dependen de tu red, tus nombres y tus claves). Este documento describe
> el patrón; el repo provee el kit que se instala en el cliente.

---

## Cómo arrancar el agente

- **Pi**: poné las instrucciones del operador en un `AGENTS.md` dentro de
  `~/operador/` (Pi lo carga solo cuando trabaja ahí) y abrí Pi desde esa carpeta.
- **Otro agente**: pegá las reglas duras de arriba como primer mensaje.

Ver también [`PROMPT-AGENTE.txt`](../PROMPT-AGENTE.txt) para la fase de
instalación.
