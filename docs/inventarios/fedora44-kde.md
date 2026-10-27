# Fedora 44 KDE — volcado 2026-10-26T22:28:00-03:00

## Diagnóstico del kit (--check)
```

== Diagnóstico del sistema ==
● OS: Fedora Linux 44 (KDE Plasma Desktop Edition)
● Familia: fedora
● Gestor: dnf5 5.4.1.0
● Kernel: 6.19.10-300.fc44.x86_64
● Hostname: fedora
● Usuario objetivo: jp  (HOME: /home/jp)
▲ Ejecutando como usuario normal: --ssh/--rustdesk requerirán sudo

== RustDesk ==
▲ rustdesk estándar instalado (sin soporte unattended Wayland)
✔ rustdesk.service activo
● Log del server: /home/jp/.local/share/logs/RustDesk/server/rustdesk_rCURRENT.log
    [2026-10-26 22:24:24.543638 -03:00] INFO [src/server/input_service.rs:759] UInput keyboard created
    [2026-10-26 22:24:24.565994 -03:00] INFO [src/server/input_service.rs:761] UInput mouse created
    [2026-10-26 22:24:24.605707 -03:00] INFO [src/ipc.rs:725] Started ipc server at path: /tmp/RustDesk-1000/ipc

== Requisitos RustDesk unattended ==
✔ dispositivo(s) /dev/dri/renderD* presentes
✔ usuario 'jp' en grupo video
✔ /dev/uinput presente
✔ módulo uinput cargado
● Tipo de sesión detectada: wayland
✔ Wayland detectado (ruta DRM aplica)

== SSH ==
✔ openssh instalado
✔ sshd enabled
✔ sshd activo

● Puertos SSH escuchando:
    LISTEN 0      128          0.0.0.0:22         0.0.0.0:*                                          
    LISTEN 0      128             [::]:22            [::]:*                                          

● authorized_keys (/home/jp/.ssh/authorized_keys): 1 línea(s)

== Firewall ==
● Detectado: firewalld-inactive
▲     firewalld instalado pero INACTIVO; --ssh lo activará y permitirá ssh

== Red ==
    enp1s0           UP             192.168.122.11/24 fe80::4813:a7b5:855d:bc41/64 
● IP local: 192.168.122.11

== Resumen ==
✔ Diagnóstico completo. Nada fue modificado.

● Siguientes pasos sugeridos:
●   sudo bash --all --key "(tu clave pública)"
```

## Inventario
```
== Inventario: jp@192.168.122.11 ==

-- Sistema --
  Hostname    : fedora
  Usuario     : jp
  Tipo        : desconocido
  Marca/Modelo: QEMU Standard PC (Q35 + ICH9, 2009)
  Placa/BIOS  : ? / Arch Linux 1.17.0-2-2 04/01/2014
  SO          : Fedora Linux 44 (KDE Plasma Desktop Edition)
  Kernel      : 6.19.10-300.fc44.x86_64 (x86_64)
  Uptime      : 52 minutes

-- CPU --
  AMD Ryzen 7 5700G with Radeon Graphics
  Núcleos     : 4 @ ? MHz

-- Memoria --
  RAM         : 3,8Gi (2,5Gi en uso)
  Swap        : 3,8Gi

-- Almacenamiento --
  Discos      : sr0 1024M QEMU DVD-ROM | vda 30G vda     30G 
  Raíz /      : 5,2G usados de 28G (19%)

-- Gráficos y red --
  GPU         : Red Hat, Inc. Virtio 1.0 GPU (rev 01)
  Red         : Red Hat, Inc. Virtio 1.0 network device (rev 01)
  IP          : 192.168.122.11

-- Sensores --
  Temperatura : ?
  Batería     : ?

```
