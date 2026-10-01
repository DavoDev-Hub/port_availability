# port_availability

Práctica: **verificar si un puerto TCP está abierto o cerrado**, primero sobre Linux
usando Docker, luego el equivalente en Windows con PowerShell, y finalmente un
script de Python que consume ambos scripts enviando múltiples puertos.

---

## Estructura del repositorio

```
port_availability/
├── linux/
│   ├── check_port.sh        # Script bash (Linux)
│   ├── Dockerfile           # Imagen Linux que empaqueta el script
│   └── .dockerignore
├── windows/
│   └── check_port.ps1       # Script PowerShell (Windows)
├── check_ports.py           # Consume ambos con múltiples puertos
├── .gitattributes
└── README.md
```

| Archivo | Descripción |
|---|---|
| `linux/check_port.sh` | Script **bash (Linux)**. Recibe un puerto como argumento y devuelve `OPEN` o `CLOSED`. |
| `linux/Dockerfile` | Imagen de Linux (`debian:bookworm-slim`) que empaqueta el script bash. |
| `windows/check_port.ps1` | Script **PowerShell (Windows)**, equivalente funcional al anterior. |
| `check_ports.py` | Script **Python** que invoca a los dos anteriores con múltiples puertos en paralelo. |

---

## Contrato común

Los dos scripts de verificación se comportan exactamente igual, para que
`check_ports.py` pueda consumir cualquiera de los dos:

```
./linux/check_port.sh   <puerto> [host] [timeout]
.\windows\check_port.ps1 -Port <puerto> [-TargetHost <host>] [-TimeoutSeconds <timeout>]
```

| Parámetro | Linux | Windows | Valor por defecto |
|---|---|---|---|
| puerto | `$1` posicional | `-Port` | obligatorio (1–65535) |
| host | `$2` posicional | `-TargetHost` (alias `-Host`) | `127.0.0.1` |
| timeout | `$3` posicional | `-TimeoutSeconds` | `3` segundos |

**Salida por `stdout`:** `OPEN` o `CLOSED` (una sola línea, fácil de parsear).

**Códigos de salida:**

| Código | Significado |
|---|---|
| `0` | El puerto está **ABIERTO** |
| `1` | El puerto está **CERRADO** |
| `2` | Uso incorrecto (argumentos inválidos, host no resoluble) |
| `3` | Error interno (no se pudo determinar el estado) |

> Excepción: en `check_port.ps1`, un puerto fuera de rango lo rechaza el propio
> binder de parámetros de PowerShell (`ValidateRange`) antes de ejecutar el
> script, y ese error se reporta con código `1`. El puerto inválido igual nunca
> llega a verificarse.

---

## Parte 1 — Linux con Docker

### Construir la imagen

```bash
docker build -t port-checker linux/
```

> El contexto de build es la carpeta `linux/`, porque ahí están el `Dockerfile`
> y el `check_port.sh` que copia. También funciona
> `docker build -t port-checker -f linux/Dockerfile .` desde la raíz.

### Ejecutar

```bash
# puerto cerrado
docker run --rm port-checker 8080
# CLOSED   (exit 1)

# puerto abierto
docker run --rm port-checker 8080 host.docker.internal
# OPEN     (exit 0)

# help
docker run --rm port-checker --help
```

### ⚠️ La trampa clásica de Docker: `127.0.0.1`

Dentro de un contenedor, `127.0.0.1` es **el propio contenedor**, no tu
computador. Por eso este comando siempre dice `CLOSED`:

```bash
docker run --rm port-checker 18080 127.0.0.1   # ❌ pregunta al contenedor
```

Para consultar un puerto de tu máquina anfitriona usa:

```bash
# Windows / Mac
docker run --rm port-checker 18080 host.docker.internal   # ✅

# Linux (comparte la pila de red del host)
docker run --rm --network host port-checker 18080          # ✅
```

Comprobación rápida para demostrar la diferencia:

```bash
docker run --rm port-checker 18080 127.0.0.1            # CLOSED
docker run --rm port-checker 18080 host.docker.internal # OPEN
```

### Cómo funciona `check_port.sh`

1. **Valida** el puerto (entero entre 1 y 65535) y el timeout.
2. Intenta la conexión con el pseudo-socket de **bash**: `exec 3<>/dev/tcp/HOST/PORT`.
   No requiere `nc` ni `telnet`, está en el propio bash.
3. Envuelve el intento en el comando `timeout` de coreutils para no colgarse si
   el puerto está filtrado (firewall que descarta silenciosamente).
4. Si bash no soporta `/dev/tcp`, cae a **`nc -z -w`** como alternativa.
5. Interpreta el resultado: `rc=0` → `OPEN`; `rc=124` (timeout) → `CLOSED`.

---

## Parte 2 — PowerShell (Windows)

```powershell
# puerto abierto / cerrado
.\windows\check_port.ps1 -Port 8080
.\windows\check_port.ps1 -Port 59999

# contra el host visto desde Docker
.\windows\check_port.ps1 -Port 18080 -Host host.docker.internal

# ajustando el timeout y viendo el detalle
.\windows\check_port.ps1 -Port 8080 -TimeoutSeconds 5 -Verbose
```

Si tu equipo tiene política de ejecución restringida:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\windows\check_port.ps1 -Port 8080
```

### Cómo funciona `check_port.ps1`

1. `ValidateRange(1, 65535)` valida el puerto en la propia declaración del
   parámetro.
2. `Resolve-Target` usa `[System.Net.Dns]::GetHostAddresses()` para confirmar
   que el host existe (distingue "host mal escrito" de "puerto cerrado").
3. `Test-Port` instancia `System.Net.Sockets.TcpClient`, llama a
   `ConnectAsync()` y espera con `.Wait(TimeSpan)`. Esto es **asíncrono con
   timeout real**, a diferencia de `Test-NetConnection`, que además devuelve un
   objeto enorme por puerto y es bastante más lento.
4. Si la tarea falla, `.Wait()` lanza `AggregateException`; si el puerto está
   filtrado, `.Wait()` retorna `false` por timeout. Ambos casos → `CLOSED`.
5. `$client.Dispose()` en el bloque `finally` libera el socket.

---

## Parte 3 (extra) — Python consumiendo ambos scripts

`check_ports.py` **no reimplementa** la verificación: delega en `check_port.sh`
(corriendo dentro de Docker) y/o en `check_port.ps1`, lanza las llamadas en
paralelo con `ThreadPoolExecutor` y agrega los resultados en un reporte.

```bash
# varios puertos sueltos
python check_ports.py --backend sh 22 80 443 8080

# lista separada por comas y rangos
python check_ports.py --backend ps1 "22,80,443" --range 8000-8005

# ejecutar las dos versiones y comparar
python check_ports.py --backend both 22 80 443

# probando un puerto abierto del host
python check_ports.py --backend sh 18080 --host host.docker.internal

# otra imagen o timeout
python check_ports.py --backend sh 80 --image port-checker --timeout 5
```

Salida de ejemplo:

```
Resultados (sh) - host: host.docker.internal
--------------------------------------------
     22  CERRADO
  18080  ABIERTO
  59999  CERRADO
   8000  CERRADO
--------------------------------------------
  Total: 8   Abiertos: 1   Cerrados: 7   Errores: 0
  Puertos abiertos: 18080
```

Opciones:

| Opción | Default | Descripción |
|---|---|---|
| `--backend {sh,ps1,both}` | `sh` | Con qué script(s) verificar |
| `--host` | `127.0.0.1` | Host a consultar |
| `--timeout` | `3` | Segundos de espera por puerto |
| `--image` | `port-checker` | Imagen Docker a usar |
| `--range INICIO-FIN` | — | Rango de puertos |

---

## Requisitos

- Docker Desktop (o Docker Engine en Linux).
- PowerShell 7+ (`pwsh`) o Windows PowerShell 5.1 — ya viene incluido en Windows.
- Python 3.8+ solo para la parte opcional.

---

## Notas importantes

- **`.gitattributes` es obligatorio en este repo.** El equipo tiene
  `core.autocrlf=true`; sin la regla `*.sh text eol=lf`, un `git clone` en
  Windows convierte `check_port.sh` a CRLF y el contenedor falla con
  `bad interpreter: /usr/bin/env bash^M`. Si tu clon falla con ese error,
  ejecuta `git add --renormalize .` y vuelve a commitear.
- **`OPEN` significa "algo acepta conexiones TCP ahí"**, no que el servicio esté
  sano. Un firewall con `REJECT` se ve igual que un servicio real.
- **CERRADO tiene dos causas distintas**: conexión rechazada rápido (*closed*)
  o sin respuesta por timeout (*filtered*). El script reporta `CLOSED` en ambos
  casos; si necesitas distinguirlos, revisa el detalle con `-Verbose` en
  PowerShell.
- `check_port.sh` funciona igual sin Docker (en cualquier Linux con bash),
  pero la práctica pide correrlo sobre la imagen.

---

## Ideas para el video

1. `docker build -t port-checker linux/` y explicar qué hace cada línea del `Dockerfile`.
2. `docker run` con un puerto cerrado y luego con uno abierto.
3. Demostrar la trampa de `127.0.0.1` vs `host.docker.internal`.
4. El mismo puerto en `windows\check_port.ps1`.
5. `check_ports.py --backend both` comparando los dos resultados.