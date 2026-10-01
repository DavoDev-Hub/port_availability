# Imagen Linux para ejecutar check_port.sh
#
# Construir : docker build -t port-checker .
# Ejecutar   : docker run --rm port-checker 8080
#             docker run --rm port-checker 8080 127.0.0.1 2
#
# NOTA: dentro del contenedor 127.0.0.1 es el PROPIO contenedor.
# Para consultar un puerto del equipo anfitrion usa:
#   docker run --rm port-checker 8080 host.docker.internal
# o en Linux:
#   docker run --rm --network host port-checker 8080

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