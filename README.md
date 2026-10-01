# port_availability — Verificador de puertos TCP

**Autor:** JUAN PABLO JIMENEZ MARTIN

Práctica de la materia sobre **PowerShell**. El objetivo es construir una
herramienta que reciba un puerto como argumento e indique si está **abierto** o
**cerrado**. Se resuelve en tres partes:

1. Un script **bash sobre Linux**, empaquetado en una imagen **Docker**.
2. El equivalente en **Windows con PowerShell**.
3. Un script de **Python** que consume cualquiera de los dos con múltiples puertos.

---

## Índice

1. [Objetivo](#objetivo)
2. [Estructura del repositorio](#estructura-del-repositorio)
3. [Requisitos](#requisitos)
4. [Teoría: ¿qué es un puerto y cómo se comprueba?](#teoría-qué-es-un-puerto-y-cómo-se-comprueba)
5. [Parte 1 — Linux con Docker](#parte-1--linux-con-docker)
6. [Parte 2 — Windows con PowerShell](#parte-2--windows-con-powershell)
7. [Parte 3 — Python consumiendo ambos scripts](#parte-3--python-consumiendo-ambos-scripts)
8. [Contrato común y códigos de salida](#contrato-común-y-códigos-de-salida)
9. [Verificaciones realizadas](#verificaciones-realizadas)
10. [Notas importantes](#notas-importantes)
11. [Conclusiones](#conclusiones)

---

## Objetivo

Un puerto es un número de 16 bits (0–65535) que identifica un servicio de red
dentro de un host. Un puerto puede estar:

| Estado | Significado |
|---|---|
| **OPEN** | Algo está escuchando y acepta conexiones TCP. |
| **CLOSED** | El host responde que no hay ningún servicio ahí (conexión rechazada). |
| **FILTERED** | El host no responde; un firewall descartó el paquete silenciosamente. |

Esta práctica implementa un verificador que devuelve `OPEN` o `CLOSED`
(`FILTERED` se reporta como `CLOSED`, indistinguible desde fuera).

Restricciones del enunciado: el script **recibe el puerto como argumento** y
no puede depender de herramientas pesadas. Por eso en Linux se resuelve con el
pseudo-socket `/dev/tcp` de bash en lugar de `telnet` o `nmap`.

---

## Estructura del repositorio

```
port_availability/
├── linux/
│   ├── check_port.sh        # Script bash (Linux)
│   ├── Dockerfile           # Imagen Linux que empaqueta el script
│   └── .dockerignore        # Excluye archivos del contexto de build
├── windows/
│   └── check_port.ps1       # Script PowerShell (Windows)
├── check_ports.py           # Consume ambos con múltiples puertos
├── .gitattributes           # Fijar finales de línea LF en los .sh
├── .gitignore
└── README.md
```

| Archivo | Descripción |
|---|---|
| `linux/check_port.sh` | Script bash. `./check_port.sh <puerto> [host] [timeout]`. |
| `linux/Dockerfile` | Imagen `debian:bookworm-slim` que empaqueta el script. |
| `windows/check_port.ps1` | Equivalente en PowerShell: `-Port`, `-TargetHost`, `-TimeoutSeconds`. |
| `check_ports.py` | Orquestador en Python: varios puertos, en paralelo. |

---

## Requisitos

- **Docker Desktop** (o Docker Engine en Linux).
- **PowerShell 7+** (`pwsh`) o Windows PowerShell 5.1, incluido en Windows.
- **Python 3.8+**, solo para la parte 3.

---

## Teoría: ¿qué es un puerto y cómo se comprueba?

`ping` **no sirve** para esto: mide ICMP (reachabilidad del host), no el estado
de un puerto. Un puerto se comprueba **abriendo una conexión TCP** contra él.

La secuencia TCP es siempre la misma:

```
cliente                                  servidor
  |          SYN --------------------------> |
  | <------- SYN + ACK -------------------- |
  |          ACK --------------------------> |     conexión establecida = OPEN
```

Si el servidor no tiene nada escuchando en ese puerto responde con
`RST` (reset) en lugar de `SYN + ACK`, y el cliente obtiene un
"connection refused" inmediato = **CLOSED**. Si un firewall descarta el
`SYN`, la conexión se queda colgada hasta agotar el timeout = **FILTERED**.

Existen varias formas de hacerlo, de menos a más potente:

| Herramienta | Descripción |
|---|---|
| `/dev/tcp` de bash | pseudo-socket integrado en bash, sin instalar nada |
| `nc -z` | netcat en modo "solo conexión", sin enviar datos |
| `Test-NetConnection` | cmdlet de PowerShell, pero lento y verboso |
| `nmap -p` | escáner completo, innecesario para un solo puerto |

---

## Parte 1 — Linux con Docker

### ¿Por qué Docker?

Para ejecutar un script bash sin instalar nada en mi equipo y garantizar que
funcione igual en el de cualquiera. La imagen es mínima (`debian:bookworm-slim`,
~29 MB) y solo contiene lo indispensable: bash, coreutils y netcat.

### El `Dockerfile`, línea por línea

```dockerfile
FROM debian:bookworm-slim

LABEL maintainer="port_availability"
LABEL description="Verifica si un puerto TCP esta abierto o cerrado"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        coreutils \
        netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY check_port.sh /app/check_port.sh

RUN chmod +x /app/check_port.sh

ENTRYPOINT ["/app/check_port.sh"]
```

| Instrucción | Para qué sirve |
|---|---|
| `FROM debian:bookworm-slim` | Imagen base mínima con Debian 12. |
| `LABEL` | Metadatos; no afectan la ejecución. |
| `RUN apt-get update && install` | Instala `bash`, `coreutils` (el comando `timeout`) y `netcat-openbsd`. El `&&` en una sola capa evita dejar el índice de APT en la imagen. |
| `--no-install-recommends` | No instala paquetes sugeridos: imagen más pequeña. |
| `rm -rf /var/lib/apt/lists/*` | Borra la caché de APT. |
| `WORKDIR /app` | Directorio de trabajo. |
| `COPY` | Copia el script a la imagen. |
| `RUN chmod +x` | Linux no marca el bit de ejecución por defecto. |
| `ENTRYPOINT ["/app/check_port.sh"]` | El contenedor ejecuta el script por defecto, así que el puerto se pasa directo: `docker run --rm port-checker 8080`. |

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
docker run --rm port-checker 59999
# CLOSED      -> exit 1

# puerto abierto
docker run --rm port-checker 18080 host.docker.internal
# OPEN        -> exit 0

# help
docker run --rm port-checker --help

# puerto inválido
docker run --rm port-checker 99999
# ERROR: puerto invalido ...   -> exit 2

# indicação completa: puerto, host y timeout
docker run --rm port-checker 18080 host.docker.internal 5
```

`--rm` borra el contenedor al terminar, así los `docker run` no acumulan basura.

### Cómo funciona `check_port.sh`

**1. Strict mode.** Se usa `set -uo pipefail` pero **no** `-e`, porque el script
necesita interpretar códigos de retorno en lugar de abortar al primer error.

**2. Validación de argumentos.**

```bash
is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1          # solo dígitos
    (( port >= 1 && port <= 65535 )) || return 1    # y en rango
    return 0
}
```

- `local` evita contaminar el scope del script.
- `[[ =~ ]]` es una expresión regular de bash; el rango se evalúa en
  aritmética con `(( ))`.

**3. La conexión con `/dev/tcp`.** Bash trae un pseudo-socket: si escribes en
`/dev/tcp/HOST/PUERTO`, bash abre un socket TCP real contra ese destino.

```bash
timeout "$timeout_s" bash -c "exec 3<>/dev/tcp/${host}/${port}"
```

- `exec 3<>...` abre el descriptor 3 en lectura y escritura, es decir, conecta.
- La conexión se hace en un `bash -c` aparte para poder envolverla en
  `timeout`: si el puerto está filtrado la conexión se quedaría colgada para
  siempre. `timeout` la corta y devuelve **124**.
- No hace falta `nc` ni `telnet`.

**4. Respaldo con netcat.** Si el build de bash no soporta `/dev/tcp`, o el
comando falla por otra razón, se recurre a `nc -z -w`:

```bash
nc -z -w "$timeout_s" "$host" "$port"
```

`-z` solo prueba la conexión sin enviar datos, `-w` es el timeout. Si tampoco
existe `nc` ni `ncat`, la función devuelve `2` y el script termina con error
interno.

**5. Interpretación del resultado.**

| Código devuelto | Significado | Resultado |
|---|---|---|
| `0` | Conexión establecida | `OPEN` |
| `124` | Timeout agotado → filtrado | `CLOSED` |
| `1` | Conexión rechazada | `CLOSED` |
| `2` | Ni `nc` ni `ncat` disponibles | error (exit 3) |

**6. Uso de argumentos opcionales.** `${2:-$DEFAULT_HOST}` devuelve el segundo
argumento o el valor por defecto si no existe o está vacío. Así una sola
variable maneja los tres parámetros.

---

## Parte 2 — Windows con PowerShell

### Uso

```powershell
# puerto abierto / cerrado
.\windows\check_port.ps1 -Port 8080
.\windows\check_port.ps1 -Port 59999

# contra el host visto desde Docker
.\windows\check_port.ps1 -Port 18080 -Host host.docker.internal

# ajustando el timeout y viendo el detalle de cada paso
.\windows\check_port.ps1 -Port 8080 -TimeoutSeconds 5 -Verbose

# help
Get-Help .\windows\check_port.ps1 -Detailed
```

Si la política de ejecución de la máquina lo bloquea:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\windows\check_port.ps1 -Port 8080
```

`pwsh -NoProfile` omite perfiles de PowerShell: más rápido y sin que scripts
del perfil interfieran.

### Cómo funciona `check_port.ps1`

**1. Bloque `param` con validación declarativa.**

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [Parameter(Position = 1)]
    [Alias('Host')]
    [string]$TargetHost = '127.0.0.1',

    [Parameter(Position = 2)]
    [ValidateRange(1, 300)]
    [int]$TimeoutSeconds = 3
)
```

- `[CmdletBinding()]` convierte el script en un cmdlet avanzado y habilita
  parámetros comunes como `-Verbose`.
- `Mandatory` + `Position` permiten invocarlo como `.\check_port.ps1 8080`.
- `[ValidateRange(1, 65535)]` **rechaza el puerto inválido antes de ejecutar
  una sola línea**: no hay que validarlo a mano.
- El parámetro se llama `$TargetHost`, no `$Host`, porque **`$Host` es una
  variable automática reservada** de PowerShell y da error. Con
  `[Alias('Host')]` el usuario igual puede escribir `-Host`.

**2. Strict mode y manejo de errores.**

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

Con `StrictMode` en su versión `Latest`, referenciar una variable no definida es
un error, lo que detecta erratas de tipeo. `$ErrorActionPreference = 'Stop'`
convierte los errores no terminantes (`Write-Error`) en excepciones.

**3. Comprobación del host.**

```powershell
[System.Net.Dns]::GetHostAddresses($ComputerName) | Out-Null
```

Distingue "el host no existe" de "el puerto está cerrado", que son cosas
distintas y merecen códigos de salida distintos (`2` frente a `1`).

**4. La conexión TCP con timeout real.**

```powershell
$connectTask = $client.ConnectAsync($ComputerName, $Port)

if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
    return $false
}
```

Este es el punto clave frente a `Test-NetConnection`:

| | `Test-NetConnection` | `TcpClient.ConnectAsync()` |
|---|---|---|
| Mecanismo | Internos, poco control | Control total del socket |
| Timeout | Difícil de acotar | `.Wait(TimeSpan)` exacto |
| Salida | Objeto enorme con muchas propiedades | Un string |
| Velocidad | Lento (segundos por puerto) | Rápido (milisegundos) |

Como el script se invoca una vez por puerto y `check_ports.py` puede lanzar
muchos, la velocidad importa. `ConnectAsync` devuelve un `Task`: `.Wait()` con
un `TimeSpan` retorna `false` si se agotó el tiempo, y **lanza
`AggregateException`** si la conexión falló (puerto cerrado, host inalcanzable).

**5. Limpieza.**

```powershell
finally {
    $client.Dispose()
}
```

`finally` se ejecuta siempre, haya éxito o excepción, así que el socket nunca
queda abierto (importante cuando se repiten muchas llamadas).

**6. Diagnóstico con `Write-Verbose`.** Los mensajes detallados solo aparecen
con `-Verbose`, así que la salida por `stdout` queda limpia para parsear.

---

## Parte 3 — Python consumiendo ambos scripts

`check_ports.py` **no reimplementa** la verificación: delega en
`linux/check_port.sh` (dentro de Docker) y/o en `windows/check_port.ps1`, lanza
las llamadas en paralelo y agrega los resultados en un reporte. Vive en la raíz
porque depende de las dos carpetas.

### Uso

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

### Salida de ejemplo

```
Resultados (sh) - host: host.docker.internal
--------------------------------------------
     22  CERRADO
  18080  ABIERTO
  59999  CERRADO
    8000  CERRADO
    8001  CERRADO
--------------------------------------------
  Total: 8   Abiertos: 1   Cerrados: 7   Errores: 0
  Puertos abiertos: 18080
```

| Opción | Default | Descripción |
|---|---|---|
| `--backend {sh,ps1,both}` | `sh` | Con qué script(s) verificar |
| `--host` | `127.0.0.1` | Host a consultar |
| `--timeout` | `3` | Segundos de espera por puerto |
| `--image` | `port-checker` | Imagen Docker a usar |
| `--range INICIO-FIN` | — | Rango de puertos |

### Cómo funciona

**1. `argparse` para la interfaz.** Permite `--help` automático y valida
`--backend` contra las opciones válidas.

**2. `parse_ports` normaliza la entrada.** Acepta `22 80 443`, `"22,80,443"` y
`8000-8005` indistintamente, invierte rangos invertidos (`8010-8000`) y elimina
duplicados **conservando el orden** del usuario.

**3. Paralelismo con `ThreadPoolExecutor`.** Cada puerto lanza un proceso
(`docker run` o `pwsh`), que es una tarea de espera pura: liberada el GIL, los
hilos funcionan bien y se ganan segundos cuando hay muchos puertos.

```python
with ThreadPoolExecutor(max_workers=workers) as pool:
    return list(pool.map(checker.check, ports))
```

**4. Aislamiento con `subprocess`.** Cada script corre como proceso aparte, así
que un fallo en el shell script no puede tumbar el script de Python. El
resultado se interpreta con los **códigos de salida**, no parseando texto:

```python
if proc.returncode == 0 and "OPEN" in stdout.upper():
    return Result(port, "OPEN")
if proc.returncode == 1 and "CLOSED" in stdout.upper():
    return Result(port, "CLOSED")
```

**5. `@dataclass(frozen=True)`** para el resultado: inmutable y con
representación automática, más legible que una tupla.

**6. Prechequeo de la imagen.** `image_exists()` consulta
`docker image inspect` una vez y cachea el resultado, para no pagar el coste de
Docker en cada puerto. Si la imagen no existe, el error dice exactamente qué
comando ejecutar.

---

## Contrato común y códigos de salida

Los dos scripts se comportan igual, y esa uniformidad es lo que permite que
Python consuma cualquiera de los dos sin saber cuál es cuál:

```bash
./linux/check_port.sh   <puerto> [host] [timeout]
.\windows\check_port.ps1 -Port <puerto> [-TargetHost <host>] [-TimeoutSeconds <timeout>]
```

| Parámetro | Linux | Windows | Default |
|---|---|---|---|
| puerto | `$1` posicional | `-Port` | obligatorio (1–65535) |
| host | `$2` posicional | `-TargetHost` (alias `-Host`) | `127.0.0.1` |
| timeout | `$3` posicional | `-TimeoutSeconds` | `3` |

**Salida por `stdout`:** `OPEN` o `CLOSED`, una sola línea.

**Códigos de salida:**

| Código | Significado |
|---|---|
| `0` | El puerto está **ABIERTO** |
| `1` | El puerto está **CERRADO** |
| `2` | Uso incorrecto: puerto inválido u host no resoluble |
| `3` | Error interno: no se pudo determinar el estado |

> Excepción conocida: en `check_port.ps1`, un puerto fuera de rango lo rechaza
> el binder de parámetros (`ValidateRange`) antes de que el script arranque, y
> ese error se reporta con código `1`. El puerto inválido igual nunca llega a
> verificarse; es una diferencia de PowerShell, no del diseño.

---

## Verificaciones realizadas

Todo se probó en ejecución real, no solo teóricamente:

| Prueba | Resultado |
|---|---|
| `bash -n check_port.sh` (sintaxis) | correcto |
| `python -m py_compile check_ports.py` | correcto |
| Puerto abierto (listener en 18080) | `OPEN`, exit `0` |
| Puerto cerrado (59999) | `CLOSED`, exit `1` |
| Puerto inválido (99999) | error, exit `2` |
| Host no resoluble (PowerShell) | error, exit `2` |
| `-Verbose` en PowerShell | muestra el detalle de cada paso |
| `check_ports.py` con ambos backends | reporte correcto y consistente |
| Imagen inexistente | error con el comando de build exacto |

---

## Notas importantes

- **`.gitattributes` es obligatorio en este repo.** Con `core.autocrlf=true`,
  un `git clone` en Windows convierte `check_port.sh` a CRLF y el contenedor
  falla con `bad interpreter: /usr/bin/env bash^M`. La regla
  `*.sh text eol=lf` lo evita.
- **`OPEN` no significa que el servicio esté sano**, solo que acepta
  conexiones TCP ahí. Un firewall configurado con `REJECT` se ve igual que un
  servicio real: para distinguir `CLOSED` de `FILTERED` hay que mirar si la
  respuesta fue inmediata o hubo timeout.
- **`check_port.sh` funciona igual sin Docker**, en cualquier Linux con bash,
  pero el enunciado pide correrlo sobre la imagen.

---

## Conclusiones

- `OPEN` o `CLOSED` se determina abriendo una conexión TCP, nunca con `ping`:
  `ping` mide ICMP y no dice nada sobre el puerto.
- Bash puede abrir sockets TCP sin herramientas externas gracias a `/dev/tcp`,
  lo que permite una imagen Docker mínima.
- El timeout no es un detalle: sin él, un puerto filtrado deja el script
  colgado indefinidamente.
- PowerShell expone el mismo concepto con un modelo asíncrono
  (`ConnectAsync` + `Wait`), más controlable y más rápido que
  `Test-NetConnection`.
- Definir un contrato común (misma salida y mismos códigos de salida) es lo que
  permite que un orquestador en Python trate a los dos scripts por igual y los
  ejecute en paralelo.

---

## Autor

**JUAN PABLO JIMENEZ MARTIN**