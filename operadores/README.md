# Claves públicas de los operadores

Aquí vive la clave **pública** de cada operador de la flota, una por archivo:

```
operadores/<host>.pub     ej: operadores/hp-operador.pub
```

`onboarding.sh --operador-hosts "hp-operador msi-operador"` las descarga de aquí
y las autoriza en el cliente (via `setup-remote-target.sh --key`). Así el
cliente nuevo queda accesible **sin copiar claves a mano** (H-43: una identidad
por operador, nunca compartir la misma clave entre equipos).

## Añadir un operador

```bash
cp ~/.ssh/id_<operador>.pub operadores/<host>.pub
git add operadores/<host>.pub && git commit -m "operadores: alta <host>"
```

Las **privadas** nunca van al repo (está en `.gitignore` y el CI tiene un job
"sin secretos"). Aquí solo se publican las `.pub`.
