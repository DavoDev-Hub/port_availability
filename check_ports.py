#!/usr/bin/env python3
"""
check_ports.py - Consume check_port.sh (vía Docker) y/o check_port.ps1
para verificar multiples puertos en paralelo.

El script NO reimplementa la lógica de verificación: delega en los scripts
de la práctica y solo orchestra las llamadas, en paralelo, y agrega los
resultados.

Ejemplos:
    python check_ports.py --backend sh 22 80 443
    python check_ports.py --backend ps1 3389 5900
    python check_ports.py --backend sh --range 8000-8010
    python check_ports.py --backend sh "22,80,443"
    python check_ports.py --backend sh 8080 --host host.docker.internal
    python check_ports.py --backend both 80 443

Codigos de salida: 0 = todos los puertos evaluados, 1 = error de uso/ejecucion
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Iterable, Sequence

DIR_SCRIPT = os.path.dirname(os.path.abspath(__file__))
SHELL_SCRIPT = os.path.join(DIR_SCRIPT, "check_port.sh")
PS_SCRIPT = os.path.join(DIR_SCRIPT, "check_port.ps1")
DEFAULT_IMAGE = "port-checker"

EXIT_OK = 0
EXIT_ERROR = 1

MAX_WORKERS = 16


@dataclass(frozen=True)
class Result:
    port: int
    state: str  # OPEN | CLOSED | ERROR
    detail: str = ""


class Checker:
    """Construye y ejecuta el comando que delega la verificación."""

    def __init__(self, backend: str, host: str, timeout: int, image: str) -> None:
        self.backend = backend
        self.host = host
        self.timeout = timeout
        self.image = image

    def build_command(self, port: int) -> list[str]:
        if self.backend == "sh":
            return self._docker_command(port)
        if self.backend == "ps1":
            return self._powershell_command(port)
        raise ValueError(f"backend desconocido: {self.backend}")

    def _docker_command(self, port: int) -> list[str]:
        docker = shutil.which("docker")
        if docker is None:
            raise RuntimeError("docker no se encuentra en el PATH")

        cmd = [
            docker, "run", "--rm",
            "-t",
            self.image,
            str(port),
            self.host,
            str(self.timeout),
        ]
        if not image_exists(self.image):
            raise RuntimeError(
                f"la imagen '{self.image}' no existe. Construyela con:\n"
                f"  docker build -t {self.image} {DIR_SCRIPT}"
            )
        return cmd

    def _powershell_command(self, port: int) -> list[str]:
        shell = shutil.which("pwsh") or shutil.which("powershell")
        if shell is None:
            raise RuntimeError(
                "no se encontro powershell (pwsh) ni Windows PowerShell (powershell)"
            )
        if not os.path.isfile(PS_SCRIPT):
            raise RuntimeError(f"no existe el script: {PS_SCRIPT}")

        return [
            shell,
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", PS_SCRIPT,
            "-Port", str(port),
            "-TargetHost", self.host,
            "-TimeoutSeconds", str(self.timeout),
        ]

    def check(self, port: int) -> Result:
        try:
            cmd = self.build_command(port)
        except (RuntimeError, ValueError) as exc:
            return Result(port, "ERROR", str(exc).replace("\n", " "))

        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=self.timeout + 30,
            )
        except subprocess.TimeoutExpired:
            return Result(port, "ERROR", "timeout del proceso")
        except OSError as exc:
            return Result(port, "ERROR", str(exc))

        stdout = proc.stdout.strip()
        stderr = proc.stderr.strip()

        if proc.returncode == 0 and "OPEN" in stdout.upper():
            return Result(port, "OPEN")
        if proc.returncode == 1 and "CLOSED" in stdout.upper():
            return Result(port, "CLOSED")

        detail = stderr or stdout or f"exit code {proc.returncode}"
        return Result(port, "ERROR", detail.replace("\n", " "))


_image_cache: dict[str, bool] = {}


def image_exists(image: str) -> bool:
    if image in _image_cache:
        return _image_cache[image]

    try:
        proc = subprocess.run(
            ["docker", "image", "inspect", image],
            capture_output=True,
            text=True,
        )
        _image_cache[image] = proc.returncode == 0
    except OSError:
        _image_cache[image] = False

    return _image_cache[image]


def parse_ports(tokens: Sequence[str]) -> list[int]:
    """Acepta puertos sueltos, listas '80,443' y rangos '8000-8010'."""
    ports: list[int] = []

    for token in tokens:
        for chunk in str(token).split(","):
            chunk = chunk.strip()
            if not chunk:
                continue

            if "-" in chunk:
                start_s, _, end_s = chunk.partition("-")
                try:
                    start, end = int(start_s), int(end_s)
                except ValueError:
                    raise ValueError(f"rango invalido: '{chunk}'") from None
                if start > end:
                    start, end = end, start
                if start < 1 or end > 65535:
                    raise ValueError(f"rango fuera de 1-65535: '{chunk}'")
                ports.extend(range(start, end + 1))
                continue

            if not chunk.isdigit() or not (1 <= int(chunk) <= 65535):
                raise ValueError(f"puerto invalido: '{chunk}'")
            ports.append(int(chunk))

    # conserva el orden del usuario y elimina duplicados
    seen: set[int] = set()
    unique: list[int] = []
    for port in ports:
        if port not in seen:
            seen.add(port)
            unique.append(port)
    return unique


def run_all(checker: Checker, ports: Iterable[int]) -> list[Result]:
    ports = list(ports)
    workers = min(MAX_WORKERS, len(ports)) or 1

    with ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(checker.check, ports))


def print_report(results: Sequence[Result], host: str, backend: str) -> None:
    title = f"Resultados ({backend}) - host: {host}"
    print(title)
    print("-" * len(title))

    for res in results:
        if res.state == "OPEN":
            print(f"  {res.port:>5}  ABIERTO")
        elif res.state == "CLOSED":
            print(f"  {res.port:>5}  CERRADO")
        else:
            print(f"  {res.port:>5}  ERROR    {res.detail}")

    open_ports = [r.port for r in results if r.state == "OPEN"]
    closed_ports = [r.port for r in results if r.state == "CLOSED"]
    errors = [r for r in results if r.state == "ERROR"]

    print("-" * len(title))
    print(
        f"  Total: {len(results)}   "
        f"Abiertos: {len(open_ports)}   "
        f"Cerrados: {len(closed_ports)}   "
        f"Errores: {len(errors)}"
    )
    if open_ports:
        print(f"  Puertos abiertos: {', '.join(map(str, open_ports))}")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verifica multiples puertos delegando en check_port.sh / check_port.ps1"
    )
    parser.add_argument(
        "ports",
        nargs="*",
        help="puertos a verificar: 22 80 443 | '22,80,443' | '8000-8010'",
    )
    parser.add_argument(
        "--range",
        dest="range_",
        metavar="INICIO-FIN",
        help="rango de puertos, p.ej. 8000-8010",
    )
    parser.add_argument(
        "--backend",
        choices=("sh", "ps1", "both"),
        default="sh",
        help="sh = Docker+check_port.sh, ps1 = check_port.ps1, both = ambos (default: sh)",
    )
    parser.add_argument("--host", default="127.0.0.1", help="host a consultar (default: 127.0.0.1)")
    parser.add_argument("--timeout", type=int, default=3, help="segundos de espera (default: 3)")
    parser.add_argument("--image", default=DEFAULT_IMAGE, help=f"imagen Docker (default: {DEFAULT_IMAGE})")
    args = parser.parse_args(argv)

    tokens = list(args.ports)
    if args.range_:
        tokens.append(args.range_)

    if not tokens:
        parser.print_usage(sys.stderr)
        print("\nError: debes indicar al menos un puerto.", file=sys.stderr)
        print("Ejemplo: python check_ports.py --backend sh 22 80 443", file=sys.stderr)
        return EXIT_ERROR

    try:
        ports = parse_ports(tokens)
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return EXIT_ERROR

    if not ports:
        print("Error: la lista de puertos esta vacia.", file=sys.stderr)
        return EXIT_ERROR

    backends = ("sh", "ps1") if args.backend == "both" else (args.backend,)

    for backend in backends:
        checker = Checker(backend, args.host, args.timeout, args.image)
        results = run_all(checker, ports)
        print()
        print_report(results, args.host, backend)

        if any(r.state == "ERROR" for r in results):
            print("  Nota: revisa que el script exista y las dependencias esten instaladas.")
        print()

    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())