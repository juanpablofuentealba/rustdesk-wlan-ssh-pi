# Test de conexión FUERA de la LAN

> **Ya existe en el kit.** El test es el script [`verify-offlan.sh`](../verify-offlan.sh).
> Este documento solo explica **cómo usarlo bien** — no hay que implementar nada.
>
> Es la prueba clave antes de irse de la casa de un cliente: confirma que el
> equipo queda administrable **desde otra red**, no un falso positivo por estar
> en la misma WiFi.

---

## Los 3 puntos que importan

| # | Punto | Detalle |
|---|---|---|
| 1 | **Otra red** | La prueba **solo vale** si el notebook sale por otra red (hotspot 4G ≠ WiFi del cliente). Confirmar con `curl -s https://api.ipify.org` que la IP pública **difiere**. |
| 2 | **Falso positivo** | `verify-offlan.sh` avisa `⚠ ruta LAN` (exit **2**) si alcanza el objetivo **sin pasar por `tailscale0`**. |
| 3 | **Verde = listo** | Exit **0** = *"El acceso remoto funciona fuera de la LAN"*. Recién ahí te vas tranquilo. |

---

## Por qué importa

Probar con notebook y cliente en **la misma WiFi** funciona… y **no prueba nada**.
Desde otra red puede fallar por:

- CGNAT del operador (sin puertos abiertos)
- Doble NAT del router del cliente
- DERP/relay bloqueado
- Firewall que solo permite la subred local

---

## Procedimiento

### Paso 1 — Preparar el escenario

```
PC cliente ── WiFi de su casa ──────► internet
Notebook   ── HOTSPOT 4G/5G ───────► internet   ← red DISTINTA
```

```bash
# En el notebook: desconectar WiFi del cliente, conectar al hotspot.
curl -s https://api.ipify.org; echo     # IP pública del notebook
```

> Repetir en el PC del cliente. **Si las IPs son iguales → misma casa → la prueba NO vale.**

### Paso 2 — Verificar

```bash
./verify-offlan.sh <hostname-o-IP-tailscale>
# ./verify-offlan.sh msi-operador
# ./verify-offlan.sh 100.101.102.103
```

| # | Comprueba | Qué mira |
|---|---|---|
| 1 | Red del operador | IP local, interfaz de salida, IP pública |
| 1b | Ruta al objetivo | ¿alcanzable **sin** `tailscale0`? → invalida la prueba |
| 2 | Tailscale | tailscaled responde; objetivo resuelto y en `tailscale status` |
| 3 | Ruta real | `tailscale ping -c 3` → pong; clasifica directa / DERP / LAN |
| 4 | SSH | entra por IP `100.x` y devuelve hostname |
| 5 | RustDesk | lee el ID (pantalla se prueba a mano, [H-17](hallazgos.md)) |

### Paso 3 — Interpretar

| Salida | Significado | Acción |
|---|---|---|
| `✔ N OK · 0 fallos` | ✅ Prueba real superada | Irse tranquilo |
| `✔` pero `⚠ ruta LAN` (exit 2) | ⚠️ Falso positivo | Usar hotspot y repetir |
| `✘` fallos (exit 1) | ❌ Algo roto | Ver tabla de fallos |
| `via DERP` | ✅ Por relay (más lento) | Aceptable |
| `ruta DIRECTA` | ✅ Lo ideal (perforación de NAT) | Perfecto |

**Exit codes:** `0` OK fuera de LAN · `1` fallos · `2` funciona pero por LAN.

---

## Fallos típicos

| Síntoma | Causa | Arreglo |
|---|---|---|
| SSH `permission denied` | Clave del operador no autorizada | Reinstalar kit con `--key "$(cat ~/.ssh/id_ed25519.pub)"` |
| `no pude resolver '<peer>'` | MagicDNS apagado / nodo no unido | `./unir-tailscale.sh` en el objetivo |
| `⚠ la ruta es LOCAL/privada` | Notebook aún en WiFi del cliente | Pasar a hotspot 4G |
| Sin `pong` en `tailscale ping` | tailscaled caído / DERP bloqueado | `systemctl status tailscaled`; `tailscale netcheck` |
| Muy lento (`via DERP`) | Sin perforación de NAT (CGNAT duro) | Normal en móvil; relay propio opcional |

---

## Checklist antes de irse

- [ ] PC cliente: kit instalado; `sshd`, `tailscaled`, `rustdesk` activos
- [ ] Notebook: **desconectado** de la WiFi del cliente
- [ ] Notebook: en hotspot 4G con IP pública **distinta**
- [ ] `./verify-offlan.sh <objetivo>` → veredicto **verde**
- [ ] SSH por IP `100.x` entra y devuelve hostname
- [ ] RustDesk: pantalla probada a mano
- [ ] Anotado: hostname · IP Tailscale · ID RustDesk · contraseña sudo

---

## El notebook como banco de pruebas móvil

```
Notebook (hotspot 4G) --Tailscale--> PC cliente (WiFi casa)   ← debe entrar
```

Si funciona así, funciona al mudarse de red, cambiar de router o estar tras CGNAT.

---

## Ver también

- [`wol-y-energia-remota.md`](wol-y-energia-remota.md) — encender/apagar remoto
- [`tailscale.md`](tailscale.md) — auth key y acceso sin abrir puertos
- [`caso-real-msi.md`](caso-real-msi.md) — instalación y mantención reales
- [`onboarding-cliente.md`](onboarding-cliente.md) — alta de un cliente nuevo
