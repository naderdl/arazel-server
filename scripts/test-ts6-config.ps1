$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Assert($condition, $message) {
    if (-not $condition) { throw $message }
}

function Read-Compose($project, $public = 'false', [switch]$bootstrap) {
    $file = Join-Path $repo "$project/compose.yml"
    Assert (Test-Path $file) "Missing $project Compose project"
    $arguments = @('compose', '--env-file', (Join-Path $repo "$project/.env.example"), '-f', $file)
    if ($bootstrap) {
        $override = Join-Path $repo 'ts/bootstrap.yml'
        Assert (Test-Path $override) 'Missing Manager bootstrap override'
        $arguments += @('-f', $override)
    }
    $previousPublic = $env:TS_MANAGER_PUBLIC
    try {
        $env:TS_MANAGER_PUBLIC = $public
        $json = & docker @arguments config --format json
        Assert ($LASTEXITCODE -eq 0) "Compose render failed: $project"
    } finally { $env:TS_MANAGER_PUBLIC = $previousPublic }
    return ($json | ConvertFrom-Json -AsHashtable)
}

$ts = Read-Compose 'ts'
$infra = Read-Compose 'infra'
Assert ($ts.name -eq 'ts' -and $ts.services.ContainsKey('ts6')) 'TS6 project/service names changed'
$server = $ts.services.ts6
foreach ($project in @($infra, $ts)) {
    foreach ($entry in $project.services.GetEnumerator()) {
        foreach ($port in $entry.Value.ports) {
            if ($port.published -in @('9987', '30033')) {
                Assert ($project.name -eq 'infra' -and $entry.Key -eq 'traefik') 'Only Traefik may publish TS6 ports'
            }
        }
    }
}
Assert (-not $server.ContainsKey('ports')) 'TS6 must publish no host ports'
foreach ($mapping in @(@('9987', 'udp', 'ts6-voice'), @('30033', 'tcp', 'ts6-files'))) {
    $port, $protocol, $entrypoint = $mapping
    $ports = @($infra.services.traefik.ports | Where-Object { $_.published -eq $port -and $_.target -eq [int]$port -and $_.protocol -eq $protocol })
    Assert ($ports.Count -eq 1) "Missing Traefik $port/$protocol mapping"
    $suffix = if ($protocol -eq 'udp') { '/udp' } else { '' }
    Assert ($infra.services.traefik.command -contains "--entrypoints.$entrypoint.address=:$port$suffix") "Missing $entrypoint entrypoint"
    Assert ($server.labels["traefik.$protocol.routers.$entrypoint.entrypoints"] -eq $entrypoint) "Wrong $entrypoint router"
    Assert ($server.labels["traefik.$protocol.routers.$entrypoint.service"] -eq $entrypoint) "Wrong $entrypoint service"
    Assert ($server.labels["traefik.$protocol.services.$entrypoint.loadbalancer.server.port"] -eq $port) "Wrong $entrypoint backend port"
}
Assert ($server.labels['traefik.tcp.routers.ts6-files.rule'] -eq 'HostSNI(`*`)') 'File transfer must use raw TCP HostSNI wildcard'
Assert (-not $server.labels.ContainsKey('traefik.tcp.routers.ts6-files.tls')) 'File transfer must not enable TLS'
Assert ($server.labels['traefik.enable'] -eq 'true' -and $server.labels['traefik.docker.network'] -eq 'proxy') 'TS6 Docker discovery must use proxy'
Assert ($ts.networks.proxy.external -eq $true -and $ts.networks.proxy.name -eq 'proxy') 'proxy must be external'
Assert ($ts.networks.ContainsKey('ts-private') -and -not $ts.networks['ts-private'].internal) 'TS private bridge must allow future outbound traffic'
Assert ($server.networks.ContainsKey('proxy') -and $server.networks.ContainsKey('ts-private')) 'TS6 must join both networks'
Assert ($server.networks['ts-private'].aliases -contains 'ts6.docker') 'Roadies need a dotted Docker alias to avoid TeamSpeak nickname lookup'
Assert ($server.volumes.Count -eq 1) 'TS6 must use one persistent bind'
$volume = $server.volumes[0]
Assert ($volume.type -eq 'bind' -and $volume.target -eq '/var/tsserver' -and $volume.source.Replace('\', '/').EndsWith('/ts/data/ts6')) 'Wrong TS6 persistent bind'
Assert ($server.image -match '^teamspeaksystems/teamspeak6-server:(?!latest)[^@]+@sha256:[a-f0-9]{64}$') 'Pin the official TS6 image by version and digest'
Assert ($server.environment.TSSERVER_LICENSE_ACCEPTED -notin @('1', 'accept')) 'Example must not accept the license'
Assert ($server.environment.TSSERVER_QUERY_HTTP_ALLOW_GUEST -eq '0') 'Guest WebQuery must be disabled'
Assert ($ts.services.ContainsKey('manager-backend')) 'Missing manager-backend'
Assert ($server.environment.TSSERVER_QUERY_HTTP_ENABLED -eq '1' -and $server.environment.TSSERVER_QUERY_HTTP_PORT -eq '10080') 'Private HTTP WebQuery must be enabled on 10080'
Assert ($server.environment.TSSERVER_QUERY_SSH_ALLOW_GUEST -eq '0') 'Guest SSH query must be disabled'
Assert ($server.environment.TSSERVER_METRICS_ENABLED -eq '1' -and $server.environment.TSSERVER_METRICS_IP -eq '0.0.0.0') 'TS6 metrics must be enabled for private Alloy scraping'
Assert ($server.networks.ContainsKey('monitoring') -and $ts.networks.monitoring.external -eq $true) 'TS6 metrics must be reachable on the private monitoring network'
foreach ($name in @('manager-backend', 'manager-frontend')) {
    Assert ($ts.services.ContainsKey($name)) "Missing $name"
    Assert ($ts.services[$name].image -match "^clusterzx/ts6-manager:$($name.Replace('manager-', ''))@sha256:[a-f0-9]{64}$") "Pin $name by digest"
    Assert (-not $ts.services[$name].ContainsKey('ports')) "$name must publish no host ports"
}
$backend = $ts.services['manager-backend']
$frontend = $ts.services['manager-frontend']
Assert ($backend.networks.Count -eq 1 -and $backend.networks.ContainsKey('ts-private')) 'Backend must join only ts-private'
Assert ($backend.networks['ts-private'].aliases -contains 'backend') 'Frontend proxy requires backend alias'
Assert ($backend.volumes.Count -eq 1) 'Manager needs one SQLite bind'
$managerVolume = $backend.volumes[0]
Assert ($managerVolume.type -eq 'bind' -and $managerVolume.target -eq '/app/packages/backend/data' -and $managerVolume.source.Replace('\', '/').EndsWith('/ts/data/manager')) 'Wrong Manager SQLite bind'
Assert ($backend.environment.DATABASE_URL -eq 'file:/app/packages/backend/data/ts6webui.db') 'Wrong Manager database URL'
Assert ($backend.environment.JWT_SECRET -and $backend.environment.ENCRYPTION_KEY) 'Manager secrets must be supplied'
Assert ($backend.environment.FRONTEND_URL -eq 'https://ts-manager.example.com') 'Wrong Manager frontend URL'
Assert (-not $backend.labels -or $backend.labels['traefik.enable'] -ne 'true') 'Manager backend must not be public'
Assert ($frontend.networks.Count -eq 2 -and $frontend.networks.ContainsKey('proxy') -and $frontend.networks.ContainsKey('ts-private')) 'Frontend requires both networks'
Assert ($frontend.labels['traefik.enable'] -eq 'false') 'Manager public route must default disabled'
Assert ($frontend.labels['traefik.docker.network'] -eq 'proxy') 'Manager discovery must use proxy'
Assert ($frontend.labels['traefik.http.routers.ts-manager.rule'] -eq 'Host(`ts-manager.example.com`)') 'Wrong Manager hostname'
Assert ($frontend.labels['traefik.http.routers.ts-manager.entrypoints'] -eq 'websecure' -and $frontend.labels['traefik.http.routers.ts-manager.tls'] -eq 'true') 'Manager requires HTTPS'
Assert ($frontend.labels['traefik.http.routers.ts-manager.tls.certresolver'] -eq 'letsencrypt') 'Wrong Manager certificate resolver'
Assert ($frontend.labels['traefik.http.routers.ts-manager.service'] -eq 'ts-manager' -and $frontend.labels['traefik.http.services.ts-manager.loadbalancer.server.port'] -eq '80') 'Wrong Manager frontend service'
Assert (-not $ts.services.ContainsKey('ts6-sidecar')) 'Optional video sidecar must remain absent'
Assert ($ts.services.ContainsKey('xray')) 'Missing private Xray service'
$xray = $ts.services.xray
Assert ($xray.image -match '^ghcr.io/xtls/xray-core:(?!latest)[^@]+@sha256:[a-f0-9]{64}$') 'Pin the official Xray image by version and digest'
Assert (-not $xray.ContainsKey('ports')) 'Xray must publish no host ports'
Assert ($xray.networks.Count -eq 1 -and $xray.networks.ContainsKey('ts-private')) 'Xray must join only ts-private'
Assert (-not $xray.labels -or $xray.labels['traefik.enable'] -ne 'true') 'Xray must have no public router'
Assert ($ts.networks['ts-private'].driver -eq 'bridge' -and -not $ts.networks['ts-private'].internal) 'Xray bridge must permit outbound traffic'
Assert ($xray.volumes.Count -eq 1) 'Xray must mount one real config'
$xrayVolume = $xray.volumes[0]
Assert ($xrayVolume.type -eq 'bind' -and $xrayVolume.source.Replace('\', '/').EndsWith('/ts/xray') -and $xrayVolume.target -eq '/usr/local/etc/xray' -and $xrayVolume.read_only -eq $true -and $xrayVolume.bind.create_host_path -eq $false) 'Xray config directory must be a read-only bind'
Assert (($xray.command -join ' ') -eq 'run -config /usr/local/etc/xray/config.json') 'Xray must load only the active config, not the candidate or example'
$xrayExample = Get-Content (Join-Path $repo 'ts/xray/config.example.json') -Raw | ConvertFrom-Json -AsHashtable
Assert ($xrayExample.inbounds.Count -eq 1 -and $xrayExample.inbounds[0].protocol -eq 'socks' -and $xrayExample.inbounds[0].listen -eq '0.0.0.0' -and $xrayExample.inbounds[0].port -eq 10808) 'Xray example must listen for bridge SOCKS on 10808'
Assert ($xrayExample.outbounds.Count -eq 1 -and $xrayExample.outbounds[0].protocol -eq 'blackhole') 'Xray example must fail closed without a direct fallback'
$sources = @()
$homes = @()
$names = @()
foreach ($n in 1..3) {
    $name = "roadie-dj$n"
    Assert ($ts.services.ContainsKey($name)) "Missing $name"
    $bot = $ts.services[$name]
    Assert ($bot.image -eq 'roadie-local:0.18.0' -and $bot.build.context.Replace('\', '/').EndsWith('/ts/roadie') -and $bot.build.dockerfile -eq 'Dockerfile') "$name must reuse pinned Roadie image/build"
    Assert (-not $bot.ContainsKey('ports') -and -not $bot.labels) "$name must have no ports or routers"
    Assert ($bot.networks.Count -eq 1 -and $bot.networks.ContainsKey('ts-private')) "$name must join only ts-private"
    Assert ($bot.environment.Count -eq 1 -and $bot.environment.TSBOT_DATA -eq '/data') "$name needs data path without blanket proxy"
    Assert ($bot.volumes.Count -eq 1) "$name needs one state bind"
    $bind = $bot.volumes[0]
    Assert ($bind.type -eq 'bind' -and $bind.target -eq '/data' -and $bind.source.Replace('\', '/').EndsWith("/ts/data/$name") -and $bind.bind.create_host_path -eq $false) "$name needs separate precreated state"
    $sources += $bind.source
    $config = Get-Content (Join-Path $repo "ts/roadie/$name.example.json") -Raw | ConvertFrom-Json -AsHashtable
    Assert ($config.configVersion -eq 1 -and $config.server.address -eq 'ts6.docker:9987') "$name must connect to internal ts6"
    Assert ($config.server.nickname -eq "DJ $n" -and $config.server.homeChannel -eq "REPLACE_DJ${n}_CHANNEL_NAME") "$name needs distinct nickname and home input"
    Assert ($config.follow.idleReturnSeconds -eq 120 -and $config.audio.stayInChannel -eq $false) "$name must return home after idle"
    Assert (($config.audio.ytdlpExtraArgs -join '|') -eq '--proxy|socks5://xray:10808|--js-runtimes|node') "$name must proxy both yt-dlp stages with Node runtime"
    Assert ($config.admins.Count -eq 1 -and $config.admins[0] -eq 'REPLACE_WITH_BOT_ADMIN_UNIQUE_ID') "$name requires actual admin UID"
    $rule = $config.permissions.commands.summon
    Assert ($rule.groups.Count -eq 1 -and $rule.groups[0] -eq -1 -and -not $rule.uids) "$name requires invalid music group placeholder replacement"
    $homes += $config.server.homeChannel
    $names += $config.server.nickname
}
Assert (($sources | Select-Object -Unique).Count -eq 3 -and ($homes | Select-Object -Unique).Count -eq 3 -and ($names | Select-Object -Unique).Count -eq 3) 'Roadies need distinct state, homes and nicknames'
Assert ($ts.services.Count -eq 7) 'Stack must contain only TS6, Manager, Xray and three Roadies'
# Exercise the pinned upstream dispatcher, without connecting to TeamSpeak.
$permissionCheck = @'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { buildConfig } from '/app/dist/config.js';
import { Bot } from '/app/dist/core/bot.js';
const log = { child() { return this; }, info() {}, warn() {}, error() {} };
for (let n = 1; n <= 3; n++) {
  const raw = JSON.parse(readFileSync(`/examples/roadie-dj${n}.example.json`, 'utf8'));
  assert.throws(() => buildConfig(raw), /groups/); // Unedited examples cannot start.
  raw.permissions.commands.summon.groups = [424242];
  raw.server.homeChannel = `#${n}`;
  raw.admins = ['test-admin'];
  const config = buildConfig(raw);
  const users = [
    { id: 1, uid: 'test-admin', name: 'Admin', groups: [] },
    { id: 2, uid: 'test-dj', name: 'DJ', groups: [424242] },
    { id: 3, uid: 'test-ordinary', name: 'Ordinary', groups: [6] },
  ];
  let ran = 0;
  const bot = new Bot({ config, adapter: { users: () => users }, state: {}, log,
    dataDir: '/tmp', builtinCogsDir: '/app/dist/cogs', cooldownMs: 0 });
  bot.cogs.find = () => ({ name: 'summon', perm: 'any', run: async () => { ran++; } });
  assert.equal((await bot.runCommandAs('test-admin', '!summon')).ok, true);
  assert.equal((await bot.runCommandAs('test-dj', '!summon')).ok, true);
  const ordinary = await bot.runCommandAs('test-ordinary', '!summon');
  assert.equal(ordinary.ok, false);
  assert.match(ordinary.replies.join(' '), /permission/);
  assert.equal(ran, 2);
}
console.log('PASS: three configs reject unedited placeholders; upstream summon dispatcher allows music group/admin and denies ordinary user');
'@
$examples = Join-Path $repo 'ts/roadie'
$permissionCheck | & docker run --rm -i --network none --mount "type=bind,source=$examples,target=/examples,readonly" roadie-local:0.18.0 node --input-type=module
Assert ($LASTEXITCODE -eq 0) 'Pinned upstream Roadie permission check failed'
$production = Read-Compose 'ts' 'true'
$productionFrontend = $production.services['manager-frontend']
Assert (-not $productionFrontend.ContainsKey('ports')) 'Production Manager frontend must have no host port'
Assert ($productionFrontend.labels['traefik.enable'] -eq 'true') 'Production Manager public route must be enabled'
Assert ($productionFrontend.labels['traefik.http.routers.ts-manager.entrypoints'] -eq 'websecure' -and $productionFrontend.labels['traefik.http.routers.ts-manager.tls'] -eq 'true') 'Production Manager route must use HTTPS'
$bootstrap = Read-Compose 'ts' 'false' -bootstrap
$bootstrapFrontend = $bootstrap.services['manager-frontend']
Assert ($bootstrapFrontend.ports.Count -eq 1) 'Bootstrap must publish exactly one frontend port'
$bootstrapPort = $bootstrapFrontend.ports[0]
Assert ($bootstrapPort.host_ip -eq '127.0.0.1' -and $bootstrapPort.published -eq '13000' -and $bootstrapPort.target -eq 80 -and $bootstrapPort.protocol -eq 'tcp') 'Bootstrap frontend must bind only 127.0.0.1:13000:80/tcp'
Assert ($bootstrapFrontend.labels['traefik.enable'] -eq 'false') 'Bootstrap Manager must have no enabled public router'
foreach ($mode in @($bootstrap, $production)) {
    Assert (-not $mode.services.ts6.ContainsKey('ports')) 'WebQuery must remain unpublished in every Manager mode'
    $modeBackend = $mode.services['manager-backend']
    Assert (-not $modeBackend.ContainsKey('ports') -and $modeBackend.networks.Count -eq 1 -and $modeBackend.networks.ContainsKey('ts-private')) 'Manager backend must remain private in every mode'
    Assert (-not $modeBackend.labels -or $modeBackend.labels['traefik.enable'] -ne 'true') 'Manager backend must have no public route in every mode'
}
Push-Location $repo
try {
    foreach ($path in @('ts/data/manager/ts6webui.db', 'ts/data/ts6/example.db', 'ts/data/ts6/files/example', 'ts/.env', 'ts/xray/config.json', 'ts/xray/config.candidate.json', 'ts/xray/config.previous.json', 'ts/xray/.xray-orphan.json', 'ts/data/roadie-dj1/identity.json', 'ts/data/roadie-dj2/identity.json', 'ts/data/roadie-dj3/identity.json')) {
        & git check-ignore --quiet $path
        Assert ($LASTEXITCODE -eq 0) "Runtime path must be ignored: $path"
    }
    foreach ($path in @('ts/compose.yml', 'ts/bootstrap.yml', 'ts/.env.example', 'ts/README.md', 'ts/xray/config.example.json', 'ts/roadie/roadie-dj1.example.json', 'ts/roadie/roadie-dj2.example.json', 'ts/roadie/roadie-dj3.example.json')) {
        & git check-ignore --quiet $path
        Assert ($LASTEXITCODE -eq 1) "Versioned TS file must not be ignored: $path"
    }
} finally { Pop-Location }
Write-Host 'PASS: TS6, Manager, three Roadies, private ingress, bootstrap, production, permissions, persistence, Xray fail-closed config and ignore contract'
