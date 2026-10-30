# Acceso primero: cómo no perder la conexión con un cliente que no sabe RustDesk

> Lección aprendida con casos reales (cliente Windows, octubre 2026).
> **Regla de oro:** antes de tocar CUALQUIER otra cosa, deja el acceso
> **garantizado y no dependiente del cliente**.

---

## El problema

Muchos clientes:

- **No saben usar RustDesk** (creen que sí, pero no).
- No saben leer/decir su ID y contraseña correctamente.
- No entienden la diferencia entre "contraseña temporal" y "permanente".
- Cuando la conexión se cae, **no saben reconectar** ni darte los datos bien.
- Pueden **cerrar RustDesk sin querer**, reiniciar, o dejar que el equipo se
  **suspenda** (que corta la conexión).

**Consecuencia:** si te conectas con una contraseña **temporal** (o "aceptar
conexión" una sola vez) y la sesión se cae, **pierdes el acceso** y tienes que
volver a guiar al cliente por teléfono, rezando para que lo haga bien.

---

## La solución: "password permanente" ANTES de nada

Lo **primero** que hay que hacer al conectar por RustDesk a un cliente es
**dejar la contraseña permanente fijada**, para que el acceso ya no dependa de:

- Que el cliente te vuelva a leer el ID/contraseña.
- Que el cliente acepte la conexión.
- Que no se caiga la sesión justo cuando haces el trabajo crítico.

### Cómo fijarla (lo haces TÚ, por la pantalla compartida)

En el **RustDesk del cliente**, desde la conexión:

1. **⚙ Ajustes** (engranaje) → **Seguridad**
2. **"Contraseña permanente"** → **Establecer / Cambiar**
3. Pon una contraseña **que tú sepas** (ej. una robusta y anotada en la ficha)
4. **Aceptar**
5. Verifica: **desconéctate y reconéctate** → ya no debe pedir aceptación ni PIN.

> Si tu RustDesk lo soporta, tras fijarla puedes cerrar la sesión y reconectar
> escribiendo el ID + esa contraseña fija, sin depender de nada del cliente.

### Alternativa por línea de comandos (si tienes PowerShell admin)

Usa el script del kit:

```powershell
.\rustdesk-password.ps1 -Set -Password 'ClaveFijaDelOperador'
```

(Ver [H-15](hallazgos.md): sin contraseña permanente, el "unattended" pide
aceptación o PIN cada vez.)

---

## Orden correcto de trabajo con un cliente nuevo

1. **Conectar por RustDesk** (con la contraseña temporal que te den).
2. **⚠️ LO PRIMERO: fijar la contraseña permanente de RustDesk.** ← esta guía
3. **Anotar** en la ficha del cliente (`~/operador/clientes/<nombre>/`) el ID y
   la contraseña.
4. **Ahora sí**, instalar **Tailscale + SSH** (acceso "de verdad", sin relay).
5. Después: diagnóstico, arreglos, optimizaciones.

**Nunca al revés.** Si haces primero Tailscale/SSH/drivers y algo se cae (o el
equipo se suspende), quedas fuera sin poder volver.

---

## Extras para clientes difíciles

- **RustDesk "unattended"**: en las opciones, activa lo que ponga
  "Aceptar conexiones automáticamente" / "Unattended access" (ver [H-15](hallazgos.md)).
- **Evitar la suspensión** mientras trabajas: el equipo del cliente puede
  dormirse y cortar RustDesk. Ver [H-29](hallazgos.md) (laptop-no-suspend).
- **Instalar RustDesk como servicio** (que arranque con el sistema), para que si
  el cliente reinicia, sigas teniendo acceso.
- **Anotar el ID** aunque creas que lo sabes: los IDs pueden cambiar
  (migración de disco, ver [H-42](hallazgos.md)).

---

## Frase para el cliente (si hay que guiarlo)

> "No te preocupes, yo controlo tu pantalla desde aquí. Solo necesito que no
> cierres la ventana de RustDesk y dejes el equipo encendido y enchufado.
> Si la pantalla se pone negra, mueve el ratón."

---

## Checklist rápido (copiar en la ficha del cliente)

```
[ ] RustDesk conectado
[ ] Contraseña PERMANENTE fijada  ← imprescindible
[ ] ID anotado: ____________
[ ] Password anotada: ____________
[ ] RustDesk instalado como servicio (arranca solo)
[ ] Tailscale instalado + unido
[ ] SSH instalado + probado
[ ] Suspensión desactivada mientras se trabaja
```
