<#
.SYNOPSIS
    Verifica si un puerto TCP esta abierto o cerrado (equivalente a check_port.sh).

.DESCRIPTION
    Usa la clase System.Net.Sockets.TcpClient de .NET para intentar la
    conexion al host y puerto indicados.

.EXAMPLE
    .\check_port.ps1 -Port 8080
    .\check_port.ps1 -Port 8080 -TargetHost host.docker.internal
    .\check_port.ps1 -Port 8080 -TargetHost 127.0.0.1 -TimeoutSeconds 5

.OUTPUTS
    OPEN | CLOSED

.NOTES
    Codigos de salida: 0 = abierto, 1 = cerrado, 2 = uso incorrecto, 3 = error
#>
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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ExitOpen   = 0
$script:ExitClosed = 1
$script:ExitUsage  = 2
$script:ExitError  = 3

function Test-Port {
    <#
    .SYNOPSIS
        Intenta establecer una conexion TCP y devuelve $true si tiene exito.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $client = [System.Net.Sockets.TcpClient]::new()

    try {
        Write-Verbose "Conectando a ${ComputerName}:${Port} (timeout ${TimeoutSeconds}s)"

        $connectTask = $client.ConnectAsync($ComputerName, $Port)

        if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            Write-Verbose 'Timeout agotado: el host no responde (puerto filtrado).'
            return $false
        }

        # Si la tarea fallo, Wait() lanza AggregateException.
        if ($connectTask.IsFaulted) {
            Write-Verbose "Fallo la conexion: $($connectTask.Exception.GetBaseException().Message)"
            return $false
        }

        if ($client.Connected) {
            Write-Verbose 'Conexion establecida: puerto abierto.'
            return $true
        }

        return $false
    }
    catch [System.Net.Sockets.SocketException] {
        Write-Verbose "SocketException: $($_.Exception.Message)"
        return $false
    }
    catch {
        Write-Verbose "Error inesperado: $($_.Exception.Message)"
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Resolve-Target {
    <#
    .SYNOPSIS
        Valida que el host exista en DNS. Devuelve $false si no se puede resolver.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ComputerName)

    try {
        [System.Net.Dns]::GetHostAddresses($ComputerName) | Out-Null
        return $true
    }
    catch {
        Write-Verbose "No se pudo resolver el host '${ComputerName}'."
        return $false
    }
}

if (-not (Resolve-Target -ComputerName $TargetHost)) {
    # Write-Error es terminante por $ErrorActionPreference = 'Stop';
    # -ErrorAction Continue permite devolver nuestro propio codigo de salida.
    Write-Error "Host invalido o no resoluble: '${TargetHost}'" -ErrorAction Continue
    exit $script:ExitUsage
}

if (Test-Port -ComputerName $TargetHost -Port $Port -TimeoutSeconds $TimeoutSeconds) {
    Write-Output 'OPEN'
    exit $script:ExitOpen
}

Write-Output 'CLOSED'
exit $script:ExitClosed