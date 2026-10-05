param([string]$Image='arazel-nginx:local')
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$alpine='alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0'
function Assert($Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Invoke-Docker([string[]]$Arguments,[string]$Action) {
    $result=& docker.exe @Arguments 2>&1
    if($LASTEXITCODE -ne 0){throw "$Action failed: $($result -join "`n")"}
    return $result
}
function Render([string]$Stack,[string]$Public='false',[switch]$Bootstrap,[string]$Issuer='production') {
    $oldPublic=$env:TS_MANAGER_PUBLIC; $oldIssuer=$env:ACME_ENVIRONMENT
    try {
        $env:TS_MANAGER_PUBLIC=$Public; $env:ACME_ENVIRONMENT=$Issuer
        $arguments=@('compose','--env-file',"$repo/$Stack/.env.example",'-f',"$repo/$Stack/compose.yml")
        if($Bootstrap){$arguments+=@('-f',"$repo/ts/bootstrap.yml")}
        return ((Invoke-Docker ($arguments+@('config','--format','json')) "render $Stack") -join "`n" | ConvertFrom-Json -AsHashtable)
    } finally { $env:TS_MANAGER_PUBLIC=$oldPublic; $env:ACME_ENVIRONMENT=$oldIssuer }
}
function Container([string]$Service) { return ((Invoke-Docker @('compose','-f',$file,'ps','-q',$Service) "resolve owned $Service") -join '') }
function Inspect([string]$Service) { return ((Invoke-Docker @('inspect',(Container $Service)) "inspect owned $Service") -join "`n" | ConvertFrom-Json -AsHashtable -NoEnumerate)[0] }
function Address([string]$Service,[string]$Network) { return (Inspect $Service).NetworkSettings.Networks["$prefix-$Network"].IPAddress }
function Fetch([string]$Client,[string]$Url) {
    $result=& docker.exe exec (Container $Client) wget -T 2 -q -O - $Url 2>$null
    if($LASTEXITCODE -eq 0){return ($result -join "`n")}
    return $null
}
function App-Request([string]$Url, [string]$Body='', [string]$Authorization='') {
    $arguments=@('exec',(Container 'auth-client'),'sh','-ec','curl --silent --show-error --max-time 5 --output /tmp/app-response --write-out "%{http_code}\n" "$@"; cat /tmp/app-response','sh')
    if($Body){$arguments+=@('--header','Content-Type: application/json','--data',$Body)}
    if($Authorization){$arguments+=@('--header',"Authorization: $Authorization")}
    $lines=@(Invoke-Docker ($arguments+@($Url)) 'request owned native application')
    return @{Status=[int]$lines[0];Body=($lines | Select-Object -Skip 1) -join "`n"}
}
function Await([scriptblock]$Probe,[string]$Description) {
    $until=[DateTime]::UtcNow.AddSeconds(45)
    do { if(&$Probe){return}; Start-Sleep -Milliseconds 500 } while([DateTime]::UtcNow -lt $until)
    throw "Timeout: $Description"
}
$prefix='arazel-boundary-'+[guid]::NewGuid().ToString('N').Substring(0,10)
$temp=Join-Path ([IO.Path]::GetTempPath()) $prefix
$file=Join-Path $temp 'compose.json'
$lab=@{name=$prefix;services=@{};networks=@{};volumes=@{}}
$ports=@{'ts6'=@(10080,10022,9187);'manager-backend'=@(3001);'manager-frontend'=@(80);'valheim'=@(3000);'lgtm'=@(3000);'alloy'=@(12345);'xray'=@(10808)}
$stagingCreated=$false; $primaryFailure=$false
try {
    New-Item -ItemType Directory $temp | Out-Null
    $users=Join-Path $temp 'usersfile'; Set-Content -LiteralPath $users -Value '' -Encoding ascii
    $readiness=Join-Path $temp 'readiness'; New-Item -ItemType Directory $readiness | Out-Null
    $responder=Join-Path $temp 'responder.sh'
    @'
#!/bin/sh
while IFS= read -r line; do
    [ "$line" != "$(printf '\r')" ] && [ -n "$line" ] || break
done
printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "${#WITNESS}" "$WITNESS"
'@ | Set-Content -LiteralPath $responder -Encoding ascii -NoNewline
    $infra=Render 'infra'; $ts=Render 'ts'; $valheim=Render 'valheim'
    $public=Render 'ts' 'true'; $bootstrap=Render 'ts' 'false' -Bootstrap
    $staging=Render 'infra' -Issuer 'staging'
    $stagingVolume="$prefix-$($staging.volumes.certbot_state.name)"
    foreach($stack in @(@('infra',$infra),@('ts',$ts),@('valheim',$valheim))) {
        $project,$source=$stack
        foreach($network in $source.networks.Keys){$lab.networks[$network]=@{name="$prefix-$network";driver='bridge'}; if($source.networks[$network].internal){$lab.networks[$network].internal=$true}}
        foreach($service in $source.services.Keys){
            if($project -eq 'infra' -and $service -in @('nginx','controller','socket-proxy','certbot')){continue}
            $listeners=if($ports.ContainsKey($service)){(@($ports[$service]) | ForEach-Object {"nc -lk -p $_ -e sh /run/witness.sh & "}) -join ''}else{''}
            $settings=@{image=$alpine;networks=$source.services[$service].networks;environment=@{WITNESS="$project/$service"};volumes=@(@{type='bind';source=$responder;target='/run/witness.sh';read_only=$true});entrypoint=@('sh','-ec');command=@($listeners+'exec sleep 300')}
            if($source.services[$service].ports){
                $settings.ports=@(foreach($binding in $source.services[$service].ports){$copy=$binding.Clone(); $copy.published='0'; $copy})
            }
            $lab.services[$service]=$settings
        }
    }
    $authPassword='Fixture-Auth-'+[guid]::NewGuid().ToString('N')+'!27'
    $lab.volumes['native-manager-state']=@{}; $lab.volumes['native-grafana-state']=@{}
    $manager=$lab.services['manager-backend']
    $manager.image=$ts.services['manager-backend'].image
    $manager.environment=$ts.services['manager-backend'].environment.Clone()
    $manager.environment.JWT_SECRET=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
    $manager.environment.ENCRYPTION_KEY=[guid]::NewGuid().ToString('N')+[guid]::NewGuid().ToString('N')
    $manager.volumes=@('native-manager-state:/app/packages/backend/data'); $manager.Remove('entrypoint'); $manager.Remove('command')
    $grafana=$lab.services.lgtm
    $grafana.image='grafana/otel-lgtm:0.30.0@sha256:46ca028e294bd728e8e930a28e887f640a8f2a9533cc283f79bcc6ab73d2ffd8'
    $grafana.environment=$infra.services.lgtm.environment.Clone(); $grafana.environment.GF_SECURITY_ADMIN_PASSWORD=$authPassword
    $grafana.volumes=@('native-grafana-state:/data'); $grafana.Remove('entrypoint'); $grafana.Remove('command')
    $lab.services['auth-client']=@{image=$Image;networks=@('ts-private','monitoring');entrypoint=@('sh','-ec');command=@('exec sleep 300')}
    # Use real ingress roles, with its host network scoped to a disposable namespace.
    $lab.networks['external-client']=@{name="$prefix-external-client";driver='bridge'}
    $lab.services['netns-host']=@{image=$alpine;command=@('sleep','300');networks=@{'external-client'=@{}};ports=@('127.0.0.1::80','127.0.0.1::443')}
    foreach($service in @('nginx','controller','socket-proxy','certbot')){
        $settings=$infra.services[$service] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        $settings.Remove('build'); $settings.Remove('restart'); $settings.Remove('depends_on'); $settings.Remove('container_name')
        if($service -in @('nginx','controller')){$settings.image=$Image}
        if($service -eq 'nginx'){$settings.network_mode='service:netns-host'; $settings.depends_on=@('netns-host')}
        if($service -eq 'controller'){$settings.depends_on=@('nginx','socket-proxy'); $settings.environment.INGRESS_ENVIRONMENT='lab'; $settings.environment.INGRESS_LAB_NETWORK_PREFIX="$prefix-"}
        if($service -eq 'certbot'){$settings.environment.ACME_ACCEPT_TERMS='false'}
        $settings.volumes=@(foreach($mount in $settings.volumes){
            $copy=$mount.Clone()
            if($copy.type -eq 'volume'){
                $key="infra-$($copy.source)"; $volumeName=$infra.volumes[$copy.source].name; $lab.volumes[$key]=@{name="$prefix-$volumeName"}; $copy.source=$key
            } elseif($copy.target -eq '/var/run/docker.sock'){
                Assert ($service -eq 'socket-proxy') 'An additional ingress role would mount the Docker socket'
            } elseif($copy.target -eq '/etc/nginx/usersfile'){$copy.source=$users
            } elseif($copy.target -eq '/run/arazel-ingress'){$copy.source=$readiness
            } else {
                Assert ($copy.source.Replace('\','/').StartsWith($repo.Replace('\','/')+'/infra/nginx/')) "Unexpected host bind in $service"
            }
            $copy
        })
        $lab.services[$service]=$settings
    }
    foreach($client in @(@('external','external-client'),@('private','ts-private'),@('observer','monitoring'),@('control','ingress-control'))){
        $name,$network=$client; $lab.services[$name]=@{image=$alpine;command=@('sleep','300');networks=@{$network=@{}}}
    }
    # Keep the actual bootstrap's interface choice; randomize only its owned host port.
    $lab.services['manager-frontend'].ports=@(foreach($binding in $bootstrap.services['manager-frontend'].ports){$copy=$binding.Clone(); $copy.published='0'; $copy})
    $lab | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $file
    Invoke-Docker @('compose','-f',$file,'up','-d') 'start isolated rendered topology' | Out-Null
    $ingressPort=(Inspect 'netns-host').NetworkSettings.Ports.'80/tcp'[0].HostPort
    Await { (& curl.exe --noproxy '*' --silent --max-time 2 --output NUL --write-out '%{http_code}' "http://127.0.0.1:$ingressPort/") -eq '400' } 'real controller-selected rejecting HTTP bootstrap'
    foreach($pair in @(@('ts6','ingress-ts6'),@('valheim','ingress-valheim'))){
        $service,$network=$pair
        $metadata=(Invoke-Docker @('network','inspect',"$prefix-$network") 'inspect game gateway') -join "`n" | ConvertFrom-Json
        $gateway=$metadata[0].IPAM.Config[0].Gateway
        $route=(Invoke-Docker @('exec',(Container $service),'ip','-4','route','show','default') 'observe game reply route') -join "`n"
        Assert ($route -match "^default via $([regex]::Escape($gateway)) dev ") "$service reply route bypasses dedicated game gateway: $route"
    }
    Assert ((Fetch 'private' 'http://ts6.docker:10080/') -eq 'ts/ts6') 'Private dotted TS6 alias/WebQuery is unreachable'

    Await { try { (App-Request 'http://backend:3001/api/health').Status -eq 200 } catch { $false } } 'native Manager API on its private alias'
    Await { try { (App-Request 'http://lgtm:3000/api/health').Status -eq 200 } catch { $false } } 'native Grafana on its monitoring connection'
    Assert ((App-Request 'http://backend:3001/api/auth/me').Status -eq 401) 'Native Manager accepts unauthenticated access'
    Assert ((App-Request 'http://backend:3001/api/setup/init' (@{username='fixture-admin';password=$authPassword;displayName='Owned fixture'} | ConvertTo-Json -Compress)).Status -eq 201) 'Native Manager first-admin bootstrap failed in owned state'
    Assert ((App-Request 'http://backend:3001/api/auth/login' '{"username":"fixture-admin","password":"wrong-fixture-password"}').Status -eq 401) 'Native Manager accepts wrong credentials'
    $login=App-Request 'http://backend:3001/api/auth/login' (@{username='fixture-admin';password=$authPassword} | ConvertTo-Json -Compress)
    Assert ($login.Status -eq 200) 'Native Manager rejects its valid fixture login'
    $token=($login.Body | ConvertFrom-Json).accessToken
    $identity=App-Request 'http://backend:3001/api/auth/me' -Authorization "Bearer $token"
    Assert ($identity.Status -eq 200 -and ($identity.Body | ConvertFrom-Json).user.username -eq 'fixture-admin') 'Native Manager does not authorize its authenticated identity'
    Assert ((App-Request 'http://lgtm:3000/api/user').Status -eq 401) 'Native Grafana permits anonymous protected access'
    Assert ((App-Request 'http://lgtm:3000/api/user' -Authorization ('Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('admin:wrong-fixture-password')))).Status -eq 401) 'Native Grafana accepts wrong credentials'
    $identity=App-Request 'http://lgtm:3000/api/user' -Authorization ('Basic '+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("admin:$authPassword")))
    Assert ($identity.Status -eq 200 -and ($identity.Body | ConvertFrom-Json).login -eq 'admin') 'Native Grafana login boundary failed'

    foreach($target in @(
        @('ts6','ts-private',10080,'/','private','ts/ts6'),
        @('ts6','ts-private',10022,'/','private','ts/ts6'),
        @('ts6','monitoring',9187,'/','observer','ts/ts6'),
        @('manager-backend','ts-private',3001,'/api/health','private','ok'),
        @('socket-proxy','ingress-control',2375,'/_ping','control','OK'),
        @('alloy','monitoring',12345,'/','observer','infra/alloy'))){
        $service,$network,$port,$path,$authorized,$expected=$target; $address=Address $service $network
        Assert ($address) "Missing selected private address for $service"
        $url="http://$address`:$port$path"
        $positive=Fetch $authorized $url
        if($service -eq 'manager-backend' -and $null -ne $positive){$positive=($positive | ConvertFrom-Json).status}
        Assert ($positive -eq $expected) "Authorized client cannot reach the exact private $service endpoint"
        Assert ($null -eq (Fetch 'external' $url)) "External client reached private $service port $port"
    }
    $namespace=@{}
    foreach($service in @('nginx','controller','socket-proxy','certbot')){
        $container=Container $service
        $namespace[$service]=(Invoke-Docker @('exec',$container,'readlink','/proc/self/ns/pid') 'observe runtime PID namespace') -join ''
        $capabilities=(Invoke-Docker @('exec',$container,'sh','-ec','while read key value; do [ "$key" != CapEff: ] || printf "%s" "$value"; done < /proc/self/status') 'observe effective role capabilities') -join ''
        Assert (([Convert]::ToUInt64($capabilities,16) -band 0x1000) -eq 0) "$service has forbidden NET_ADMIN"
        $paths=if($service -eq 'socket-proxy'){@()}else{@('/etc/letsencrypt','/var/www/certbot')}
        foreach($path in $paths){
            $probe=& docker.exe exec $container sh -ec "touch '$path/.boundary-write-probe' && rm '$path/.boundary-write-probe'" 2>&1
            if($service -eq 'certbot'){Assert ($LASTEXITCODE -eq 0) "Certbot cannot write $path"}else{Assert ($LASTEXITCODE -ne 0 -and ($probe -join '') -match 'Read-only file system') "$service can mutate certificate/challenge state $path"}
        }
    }
    foreach($access in @(@('nginx','/run/nginx-config',$false),@('nginx','/run/nginx-selected',$false),@('controller','/run/nginx-config',$true),@('controller','/run/nginx-selected',$true),@('controller','/run/nginx-master-runtime',$false),@('controller','/run/nginx-runtime',$true),@('certbot','/run/nginx-selected',$false))){
        $service,$path,$allowed=$access
        $probe=& docker.exe exec (Container $service) sh -ec "touch '$path/.boundary-write-probe' && rm '$path/.boundary-write-probe'" 2>&1
        if($allowed){Assert ($LASTEXITCODE -eq 0) "$service cannot write its owned $path"}else{Assert ($LASTEXITCODE -ne 0 -and ($probe -join '') -match 'Read-only file system') "$service can mutate another role's $path"}
    }
    Assert ($namespace.nginx -eq $namespace.controller) 'Controller does not share the ingress PID namespace'
    Assert ($namespace.certbot -ne $namespace.nginx -and $namespace['socket-proxy'] -ne $namespace.nginx) 'Additional role shares the ingress PID namespace'
    $binding=(Inspect 'manager-frontend').NetworkSettings.Ports.'80/tcp'[0]
    $body=& curl.exe --noproxy '*' --fail --silent "http://127.0.0.1:$($binding.HostPort)/"
    Assert ($LASTEXITCODE -eq 0 -and $body -eq 'ts/manager-frontend') 'Explicit loopback Manager bootstrap is unavailable'
    $gateway=((Invoke-Docker @('network','inspect',"$prefix-external-client") 'inspect external gateway') -join "`n" | ConvertFrom-Json)[0].IPAM.Config[0].Gateway
    Assert ($null -eq (Fetch 'external' "http://$gateway`:$($binding.HostPort)/")) 'External client reached loopback-only Manager bootstrap'
    Invoke-Docker @('exec',(Container 'certbot'),'sh','-ec','printf production > /etc/letsencrypt/.boundary-issuer') 'publish owned issuer-state witness' | Out-Null
    Invoke-Docker @('volume','create',$stagingVolume) 'create mapped owned staging state' | Out-Null; $stagingCreated=$true
    Invoke-Docker @('run','--rm','--network','none','--mount',"type=volume,source=$stagingVolume,target=/state,readonly",$alpine,'sh','-ec','test ! -e /state/.boundary-issuer') 'prove staging does not mount production state' | Out-Null
    Write-Host 'PASS: actual Compose gateways/private aliases and listeners, native Manager/Grafana login, filtered metadata, issuer-separated state, mount/PID/capability boundaries and loopback bootstrap'
    Invoke-Docker @('compose','version') 'report exercised Compose version'
    Invoke-Docker @('version','--format','Engine {{.Server.Version}}') 'report exercised Engine version'
} catch {
    $primaryFailure=$true
    foreach($service in @('ts6','manager-frontend','nginx','controller','socket-proxy','certbot')){
        & docker.exe compose -f $file logs --tail 20 $service 2>&1 | Write-Host
    }
    throw
} finally {
    $cleanupErrors=@()
    if(Test-Path $file){try { Invoke-Docker @('compose','-f',$file,'down','--volumes','--remove-orphans') 'clean only isolated Compose lab' | Out-Null } catch { $cleanupErrors += $_.Exception.Message }}
    if($stagingCreated){try { Invoke-Docker @('volume','rm',$stagingVolume) 'clean owned staging state' | Out-Null } catch { $cleanupErrors += $_.Exception.Message }}
    if(Test-Path $temp){try { Remove-Item -Force -Recurse $temp } catch { $cleanupErrors += $_.Exception.Message }}
    if($cleanupErrors.Count){
        Write-Warning ($cleanupErrors -join ' ; ')
        if(-not $primaryFailure){throw 'Compose-boundary cleanup failed; owned resources named in the warning require repair'}
    }
}
