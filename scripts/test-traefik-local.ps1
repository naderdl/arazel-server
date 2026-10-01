$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$infraFile = Join-Path $repo 'infra/compose.yml'
$valheimFile = Join-Path $repo 'valheim/compose.yml'
$infraEnv = Join-Path $repo 'infra/.env.example'
$valheimEnv = Join-Path $repo 'valheim/.env.example'
$tsFile = Join-Path $repo 'ts/compose.yml'
$tsEnv = Join-Path $repo 'ts/.env.example'

function Read-Compose($file, $envFile) {
    $json = & docker compose --env-file $envFile -f $file config --format json
    if ($LASTEXITCODE -ne 0) { throw "Compose render failed: $file" }
    return ($json | ConvertFrom-Json -AsHashtable)
}

function Docker-Run($arguments, $description) {
    & docker @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker failed: $description" }
}

function Host-Port($container, $port) {
    $mapping = & docker port $container $port
    if ($LASTEXITCODE -ne 0) { throw "No host mapping for $port" }
    return [int](($mapping | Select-Object -First 1) -split ':')[-1]
}

$infra = Read-Compose $infraFile $infraEnv
$valheim = Read-Compose $valheimFile $valheimEnv
$ts = Read-Compose $tsFile $tsEnv
$previousManagerPublic = $env:TS_MANAGER_PUBLIC
try {
    $env:TS_MANAGER_PUBLIC = 'true'
    $managerLabels = (Read-Compose $tsFile $tsEnv).services.'manager-frontend'.labels
} finally {
    $env:TS_MANAGER_PUBLIC = $previousManagerPublic
}
$expectedPorts = @('80/tcp', '443/tcp', '2456/udp', '2457/udp', '2458/udp', '9987/udp', '30033/tcp' | Sort-Object)
$actualPorts = @($infra.services.traefik.ports | ForEach-Object { "$($_.published)/$($_.protocol)" } | Sort-Object)
if (Compare-Object $expectedPorts $actualPorts) { throw 'Traefik host ports differ from the design' }
if ($infra.services.lgtm.ContainsKey('ports') -or $infra.services.alloy.ContainsKey('ports') -or $valheim.services.valheim.ContainsKey('ports') -or $ts.services.ts6.ContainsKey('ports')) {
    throw 'An application still publishes a host port'
}
if ($infra.services.lgtm.labels['traefik.docker.network'] -ne 'proxy' -or $valheim.services.valheim.labels['traefik.docker.network'] -ne 'proxy' -or $ts.services.ts6.labels['traefik.docker.network'] -ne 'proxy') {
    throw 'Application Traefik network differs from proxy'
}
$id = [guid]::NewGuid().ToString('N').Substring(0, 10)
$network = "game-stack-test-$id"
$proxy = "$network-proxy"
$grafana = "$network-grafana"
$game = "$network-valheim"
$teamspeak = "$network-ts6"
$manager = "$network-manager"
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempDir = Join-Path $tempRoot $network
$containers = @($proxy, $grafana, $game, $teamspeak, $manager)
$networkCreated = $false

try {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $mockFile = Join-Path $tempDir 'mock.py'
    $usersFile = Join-Path $tempDir 'usersfile'
    @'
import os, socket, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

name = os.environ['MOCK_NAME']

def udp(port):
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(('0.0.0.0', port))
    while True:
        data, address = server.recvfrom(4096)
        server.sendto(name.encode() + b':' + data, address)

def tcp(port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(('0.0.0.0', port))
    server.listen()
    while True:
        connection, _ = server.accept()
        with connection:
            data = b''
            while not data.endswith(b'\n'):
                chunk = connection.recv(4096)
                if not chunk:
                    break
                data += chunk
            connection.sendall(name.encode() + b':' + data)

for port in ((9987,) if name == 'ts6' else (2456, 2457, 2458)):
    threading.Thread(target=udp, args=(port,), daemon=True).start()
if name == 'ts6':
    threading.Thread(target=tcp, args=(30033,), daemon=True).start()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (name + '-ok').encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

ThreadingHTTPServer(('0.0.0.0', 80 if name == 'manager' else 3000), Handler).serve_forever()
'@ | Set-Content -LiteralPath $mockFile -Encoding utf8
    # Public Traefik documentation's test/test credential; never use in deployment.
    'test:$apr1$H6uskkkW$IgXLP6ewTrSuBkTrqE8wj/' | Set-Content -LiteralPath $usersFile -Encoding ascii

    & docker network create $network | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create isolated Docker network' }
    $networkCreated = $true

    foreach ($item in @(@($grafana, 'grafana', $infra.services.lgtm.labels), @($game, 'valheim', $valheim.services.valheim.labels), @($teamspeak, 'ts6', $ts.services.ts6.labels), @($manager, 'manager', $managerLabels))) {
        $name, $mockName, $labels = $item
        $args = @('run', '-d', '--name', $name, '--network', $network,
            '--mount', "type=bind,source=$mockFile,target=/mock.py,readonly",
            '-e', "MOCK_NAME=$mockName")
        foreach ($label in $labels.GetEnumerator()) {
            $value = if ($label.Key -eq 'traefik.docker.network') { $network } else { $label.Value }
            $args += @('--label', "$($label.Key)=$value")
        }
        $args += @('python:3.13-alpine', 'python', '-u', '/mock.py')
        Docker-Run $args $name
    }

    $command = @($infra.services.traefik.command | ForEach-Object {
        if ($_ -eq '--providers.docker.network=proxy') { "--providers.docker.network=$network" } else { $_ }
    })
    # Keep ACME requests inside the container during this local-only test.
    $command += '--certificatesresolvers.letsencrypt.acme.caserver=http://127.0.0.1:65534/directory'
    $args = @('run', '-d', '--name', $proxy, '--network', $network,
        '-p', '127.0.0.1::80/tcp', '-p', '127.0.0.1::443/tcp',
        '-p', '127.0.0.1::2456/udp', '-p', '127.0.0.1::2457/udp', '-p', '127.0.0.1::2458/udp',
        '-p', '127.0.0.1::9987/udp', '-p', '127.0.0.1::30033/tcp',
        '-v', '/var/run/docker.sock:/var/run/docker.sock:ro',
        '--mount', "type=bind,source=$usersFile,target=/etc/traefik/usersfile,readonly",
        $infra.services.traefik.image) + $command
    Docker-Run $args $proxy

    $httpsPort = Host-Port $proxy '443/tcp'
    $httpPort = Host-Port $proxy '80/tcp'
    $ready = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $grafanaReply = & curl.exe --noproxy '*' --silent --insecure --resolve "monitor.example.com:${httpsPort}:127.0.0.1" "https://monitor.example.com:${httpsPort}/"
        if ($grafanaReply -eq 'grafana-ok') { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw 'Grafana HTTPS route did not become ready' }

    $managerReply = & curl.exe --noproxy '*' --silent --insecure --resolve "ts-manager.example.com:${httpsPort}:127.0.0.1" "https://ts-manager.example.com:${httpsPort}/"
    if ($managerReply -ne 'manager-ok') { throw "Manager HTTPS route failed: $managerReply" }

    $unauthorized = & curl.exe --noproxy '*' --silent --insecure --output NUL --write-out '%{http_code}' --resolve "valheim.example.com:${httpsPort}:127.0.0.1" "https://valheim.example.com:${httpsPort}/"
    if ($unauthorized -ne '401') { throw "Huginn without credentials returned $unauthorized" }
    $authorized = & curl.exe --noproxy '*' --silent --insecure --user 'test:test' --resolve "valheim.example.com:${httpsPort}:127.0.0.1" "https://valheim.example.com:${httpsPort}/"
    if ($authorized -ne 'valheim-ok') { throw "Huginn BasicAuth failed: $authorized" }
    $redirect = & curl.exe --noproxy '*' --silent --output NUL --write-out '%{http_code}' --resolve "monitor.example.com:${httpPort}:127.0.0.1" "http://monitor.example.com:${httpPort}/"
    if ($redirect -notin @('301', '302', '307', '308')) { throw "HTTP redirect returned $redirect" }

    foreach ($port in @(2456, 2457, 2458, 9987)) {
        $hostPort = Host-Port $proxy "$port/udp"
        $client = [Net.Sockets.UdpClient]::new()
        try {
            $client.Client.ReceiveTimeout = 5000
            $bytes = [Text.Encoding]::UTF8.GetBytes("ping$port")
            [void]$client.Send($bytes, $bytes.Length, '127.0.0.1', $hostPort)
            $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
            $reply = [Text.Encoding]::UTF8.GetString($client.Receive([ref]$remote))
            $expectedName = if ($port -eq 9987) { 'ts6' } else { 'valheim' }
            if ($reply -ne "${expectedName}:ping$port") { throw "UDP $port returned $reply" }
        } finally {
            $client.Dispose()
        }
    }
    $client = [Net.Sockets.TcpClient]::new()
    try {
        [void]$client.ConnectAsync('127.0.0.1', (Host-Port $proxy '30033/tcp')).WaitAsync([TimeSpan]::FromSeconds(5)).GetAwaiter().GetResult()
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $stream.WriteTimeout = 5000
        $bytes = [Text.Encoding]::UTF8.GetBytes("ping30033`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $reader = [IO.StreamReader]::new($stream)
        $reply = $reader.ReadLine()
        if ($reply -ne 'ts6:ping30033') { throw "TCP 30033 returned $reply" }
    } finally {
        $client.Dispose()
    }
    'PASS: HTTPS Grafana and Manager, Huginn BasicAuth, HTTP redirect, Valheim UDP 2456-2458, TS6 UDP 9987 and raw TCP 30033 through local Traefik'
} catch {
    if ($networkCreated) { & docker logs $proxy --tail 40 2>$null }
    throw
} finally {
    foreach ($container in $containers) { & docker rm -f $container 2>$null | Out-Null }
    if ($networkCreated) { & docker network rm $network 2>$null | Out-Null }
    $resolved = [IO.Path]::GetFullPath($tempDir)
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
