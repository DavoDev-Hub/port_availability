#!/usr/bin/env bash
#
# check_port.sh - Verifica si un puerto TCP esta ABIERTO o CERRADO.
#
# Uso: ./check_port.sh <puerto> [host] [timeout]
#
# Salida por stdout : OPEN | CLOSED
# Codigos de salida  : 0 = abierto
#                      1 = cerrado
#                      2 = uso incorrecto
#                      3 = error interno

set -uo pipefail

readonly DEFAULT_HOST="127.0.0.1"
readonly DEFAULT_TIMEOUT="3"

readonly EXIT_OPEN=0
readonly EXIT_CLOSED=1
readonly EXIT_USAGE=2
readonly EXIT_ERROR=3

usage() {
    cat <<'EOF'
Uso: check_port.sh <puerto> [host] [timeout]

  puerto   Puerto TCP a verificar (1-65535)
  host     Host o IP a consultar (default 127.0.0.1)
  timeout  Segundos de espera (default 3)

Salida:    OPEN | CLOSED
Codigos:   0=abierto 1=cerrado 2=uso incorrecto 3=error
EOF
}

log_error() {
    printf 'ERROR: %s\n' "$1" >&2
}

is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    return 0
}

is_positive_int() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    (( value >= 1 )) || return 1
    return 0
}

# Intenta la conexion usando el pseudo-socket /dev/tcp de bash.
try_dev_tcp() {
    local host="$1" port="$2" timeout_s="$3"

    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_s" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
    else
        bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
    fi
}

# Alternativa cuando /dev/tcp no esta disponible o el build no lo soporta.
try_netcat() {
    local host="$1" port="$2" timeout_s="$3"

    if command -v nc >/dev/null 2>&1; then
        nc -z -w "$timeout_s" "$host" "$port" >/dev/null 2>&1
    elif command -v ncat >/dev/null 2>&1; then
        ncat -z -w "$timeout_s" "$host" "$port" >/dev/null 2>&1
    else
        return 2
    fi
}

check_port() {
    local host="$1" port="$2" timeout_s="$3" rc

    try_dev_tcp "$host" "$port" "$timeout_s"
    rc=$?

    # rc 2 = timeout agotado (no responde) -> cerrado por filtro.
    if (( rc == 0 )); then
        return $EXIT_OPEN
    fi
    if (( rc == 124 )); then
        return $EXIT_CLOSED
    fi

    try_netcat "$host" "$port" "$timeout_s"
    rc=$?

    case $rc in
        0)        return $EXIT_OPEN ;;
        1|124)    return $EXIT_CLOSED ;;
        2)        return $EXIT_ERROR ;;
        *)        return $EXIT_CLOSED ;;
    esac
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        return $EXIT_OPEN
    fi

    if [[ $# -lt 1 || $# -gt 3 ]]; then
        usage >&2
        return $EXIT_USAGE
    fi

    local port="${1}"
    local host="${2:-$DEFAULT_HOST}"
    local timeout_s="${3:-$DEFAULT_TIMEOUT}"

    if ! is_valid_port "$port"; then
        log_error "puerto invalido: '${port}' (debe ser un entero entre 1 y 65535)"
        return $EXIT_USAGE
    fi

    if ! is_positive_int "$timeout_s"; then
        log_error "timeout invalido: '${timeout_s}' (debe ser un entero positivo)"
        return $EXIT_USAGE
    fi

    check_port "$host" "$port" "$timeout_s"
    local rc=$?

    case $rc in
        $EXIT_OPEN)   printf 'OPEN\n' ;;
        $EXIT_CLOSED) printf 'CLOSED\n' ;;
        *)
            log_error "no se pudo determinar el estado del puerto ${port} en ${host}"
            return $EXIT_ERROR
            ;;
    esac

    return $rc
}

main "$@"