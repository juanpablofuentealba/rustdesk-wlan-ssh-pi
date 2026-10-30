# Encendido y energía remotos (Wake-on-LAN + apagado/reinicio)

> Cómo encender, apagar y reiniciar un equipo **remoto** desde el operador,
> incluso cuando el equipo está apagado.

---

## El problema: Tailscale NO despierta equipos apagados

Un error común es pensar que se puede hacer:

```bash
wakeonlan <IP-de-Tailscale-del-equipo-apagado>   # ❌ NO funciona
```

**Por qué no funciona:**

- El **magic packet** de Wake-on-LAN es un **broadcast Ethernet (capa 2)**.
- **Tailscale solo transporta IP (capa 3)** — no reenvía broadcast de capa 2.
- El equipo apagado no tiene nadie escuchando en Tailscale.

Es decir: **Tailscale por sí solo jamás despertará un equipo apagado.**

---

## La solución: el operador como relé

Si el **operador** (un equipo que **sí está encendido**) comparte la **LAN** con
el equipo apagado, puede enviar el magic packet **localmente**:

```
   móvil (Android)  ──Tailscale──►  operador (encendido)
                                        │
                                        │ magic packet (broadcast LAN)
                                        ▼
                                   equipo apagado  ──► despierta
```

Tailscale no despierta nada: lo hace el **operador, dentro de la LAN**.

### Uso

```bash
# Desde el operador:
./wol-despertar.sh --mac 30:9c:23:db:10:24 --bcast 192.168.1.255

# Con espera a que responda:
./wol-despertar.sh --mac 30:9c:23:db:10:24 --wait --check 'ssh jp@host hostname'

# Desde el móvil por Tailscale (pide al operador que lo haga):
ssh jp@operador './wol-despertar.sh --mac 30:9c:23:db:10:24 --wait \
  --check "ssh jp@host hostname"'
```

### Aprender la MAC de un equipo Linux encendido

En vez de anotar la MAC a mano, el script puede leerla por SSH:

```bash
./wol-despertar.sh --learn-ssh jp@host --bcast 192.168.1.255
```

---

## Preparar el equipo destino (¡imprescindible!)

El WoL **no funciona solo con el script**: hay que activarlo en el equipo.

### En Linux (NIC por cable)

```bash
# 1. Activar (g = magic packet)
sudo ethtool -s enp37s0 wol g

# 2. Verificar
sudo ethtool enp37s0 | grep -i wake      # → Wake-on: g

# 3. Persistir tras reinicio
sudo tee /etc/systemd/system/wol-enable.service >/dev/null <<'EOF'
[Unit]
Description=Enable Wake-on-LAN
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/bin/ethtool -s enp37s0 wol g
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now wol-enable.service
```

### En la BIOS

Si tras apagar el equipo el **LED de la NIC se apaga**, la placa no alimenta la
NIC en standby y hay que activarlo en la BIOS:

```
Advanced → Wake Up Event Setup → Resume By PCI-E/LAN = Enabled
```

**Ojo:** el WoL clásico **solo funciona por cable ethernet**. Despertar por WiFi
requiere WoWLAN, mucho menos soportado.

---

## Apagar y reiniciar remoto (sin exponer la contraseña)

```bash
./energia-remota.sh apagar    jp@host            # pide confirmación
./energia-remota.sh reiniciar jp@host
./energia-remota.sh apagar    jp@host --delay 10 # en 10 minutos
./energia-remota.sh cancelar  jp@host
```

### Seguridad de la contraseña sudo

**Nunca** hacer `ssh host "echo PASS | sudo -S poweroff"`: deja la clave
**visible en `ps`** del equipo remoto. En su lugar, guardarla aparte:

```bash
mkdir -p ~/.config/operador-secrets && chmod 700 ~/.config/operador-secrets
install -m600 /dev/stdin ~/.config/operador-secrets/sudo   # pegar clave + Ctrl-D
```

El script lee ese archivo y la pasa por **STDIN** → invisible en `ps`, en el
historial y en los logs. El script en sí **no contiene secretos**.

---

## Errores típicos y cómo diagnosticarlos

| Síntoma | Causa probable | Arreglo |
|---|---|---|
| El magic packet no despierta | Se mandó **antes** de que el equipo acabara de apagarse | Esperar a que el ping dé 100% loss y el ARP esté `FAILED` (~40 s) |
| No despierta nunca | NIC sin WoL | `ethtool -s <if> wol g` + servicio |
| No despierta nunca | BIOS no alimenta la NIC | `Resume By PCI-E/LAN = Enabled` |
| No despierta | El AP filtra el broadcast WiFi→LAN | Conectar el operador **por cable** |
| Despierta y vuelve a dormirse | ACPI/suspensión | Ver `laptop-no-suspend.sh` |

**Lección clave:** el WoL suele estar bien configurado; la mayoría de los fallos
son por **mandar el paquete demasiado pronto** (antes de que el equipo termine
de apagarse). Confirmar el apagado (ping + ARP) antes de mandarlo.
