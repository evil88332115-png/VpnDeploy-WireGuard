param(
    [string]$ServerIp,
    [string]$ServerUser,
    [string]$ServerPassword,
    [string]$ServerHostKey,
    [string]$ClientIp,
    [string]$ClientUser,
    [string]$ClientPassword,
    [string]$ClientHostKey,
    [string]$VpnNetwork = "10.66.66.0/24",
    [string]$ServerVpnCidr = "10.66.66.1/24",
    [string]$ServerVpnIp = "10.66.66.1",
    [string]$ClientVpnCidr = "10.66.66.2/32",
    [string]$ClientVpnIp = "10.66.66.2",
    [string]$ListenPort = "51820",
    [string]$WgIf = "wg0"
)

$ErrorActionPreference = "Stop"

function Ask-Default {
    param(
        [string]$Prompt,
        [string]$Default = ""
    )
    if ($Default) {
        $value = Read-Host "$Prompt [$Default，Enter 使用預設]"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        return $value
    }
    return (Read-Host $Prompt)
}

function Ask-Ip {
    param(
        [string]$Prompt,
        [string]$Hint = "192.168.xx.xx"
    )
    do {
        $value = Read-Host "$Prompt [$Hint，請輸入實際 IP]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host "這個欄位沒有可用預設值，請輸入實際 IP，例如 192.168.23.177。"
            continue
        }
        if ($value -match "xx|XX") {
            Write-Host "IP 不可以包含 xx，請輸入實際 IP。"
            continue
        }
        if ($value -notmatch "^\d{1,3}(\.\d{1,3}){3}$") {
            Write-Host "IP 格式不正確，請輸入例如 192.168.23.177。"
            continue
        }
        return $value
    } while ($true)
}

function Ask-Ip-Default {
    param(
        [string]$Prompt,
        [string]$Default
    )
    do {
        $value = Ask-Default $Prompt $Default
        if ($value -match "xx|XX") {
            Write-Host "IP 不可以包含 xx，請輸入實際 IP。"
            continue
        }
        if ($value -notmatch "^\d{1,3}(\.\d{1,3}){3}$") {
            Write-Host "IP 格式不正確，請輸入例如 10.66.66.1。"
            continue
        }
        return $value
    } while ($true)
}

function Ask-Cidr-Default {
    param(
        [string]$Prompt,
        [string]$Default
    )
    do {
        $value = Ask-Default $Prompt $Default
        if ($value -match "xx|XX") {
            Write-Host "CIDR 不可以包含 xx，請輸入實際網段。"
            continue
        }
        if ($value -notmatch "^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$") {
            Write-Host "CIDR 格式不正確，請輸入例如 10.66.66.2/32。"
            continue
        }
        return $value
    } while ($true)
}

function Ask-Required {
    param([string]$Prompt)
    do {
        $value = Read-Host $Prompt
    } while ([string]::IsNullOrWhiteSpace($value))
    return $value
}

function Need-Command {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "找不到 $Name。請先安裝 PuTTY，並確認 plink.exe / pscp.exe 在 PATH 裡。"
    }
}

function Get-HostKeyArgs {
    param([string]$RemoteHost)
    if ($script:HostKeyMap.ContainsKey($RemoteHost) -and $script:HostKeyMap[$RemoteHost]) {
        return @("-hostkey", $script:HostKeyMap[$RemoteHost])
    }
    return @()
}

function Trust-HostKey-FromOutput {
    param(
        [string]$RemoteHost,
        [string[]]$Output
    )
    $text = ($Output -join "`n")
    if ($text -notmatch "host key|Host key|fingerprint|POTENTIAL SECURITY BREACH|Cannot confirm a host key") {
        return $false
    }

    $match = [regex]::Match($text, "SHA256:[A-Za-z0-9+/=]+")
    if (-not $match.Success) {
        return $false
    }

    $fingerprint = $match.Value
    Write-Host ""
    Write-Host "SSH host key needs confirmation for $RemoteHost"
    Write-Host "Fingerprint: $fingerprint"
    Write-Host "If this IP was reinstalled or changed to a new device, this is expected."
    $answer = Read-Host "Trust this host key and continue? [y/N]"
    if ($answer -in @("y", "Y", "yes", "YES")) {
        $script:HostKeyMap[$RemoteHost] = $fingerprint
        Write-Host "Using host key for this deployment: $fingerprint"
        return $true
    }

    return $false
}

function Invoke-Plink {
    param(
        [string]$RemoteHost,
        [string]$User,
        [string]$Password,
        [string]$Command,
        [switch]$AllowFail
    )
    for ($try = 0; $try -lt 2; $try++) {
        $args = @("-ssh", "-batch") + (Get-HostKeyArgs $RemoteHost) + @("-l", $User, "-pw", $Password, $RemoteHost, $Command)
        $oldErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & plink @args 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldErrorAction
        }
        if ($output) { $output | ForEach-Object { Write-Host $_ } }
        if ($code -eq 0 -or $AllowFail) {
            return @{ ExitCode = $code; Output = $output }
        }
        if ($try -eq 0 -and (Trust-HostKey-FromOutput $RemoteHost $output)) {
            continue
        }
        return @{ ExitCode = $code; Output = $output }
    }
}

function Invoke-Pscp {
    param(
        [string]$RemoteHost,
        [string]$User,
        [string]$Password,
        [string]$LocalPath,
        [string]$RemotePath
    )
    for ($try = 0; $try -lt 2; $try++) {
        $args = @("-scp", "-batch") + (Get-HostKeyArgs $RemoteHost) + @("-pw", $Password, $LocalPath, "${User}@${RemoteHost}:$RemotePath")
        $oldErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & pscp @args 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldErrorAction
        }
        if ($output) { $output | ForEach-Object { Write-Host $_ } }
        if ($code -eq 0) {
            return @{ ExitCode = $code; Output = $output }
        }
        if ($try -eq 0 -and (Trust-HostKey-FromOutput $RemoteHost $output)) {
            continue
        }
        return @{ ExitCode = $code; Output = $output }
    }
}

function Run-Remote {
    param(
        [string]$RemoteHost,
        [string]$User,
        [string]$Password,
        [string]$Command
    )
    $result = Invoke-Plink $RemoteHost $User $Password $Command
    if ($result.ExitCode -ne 0) {
        throw ('Remote command failed: {0}@{1} :: {2}' -f $User, $RemoteHost, $Command)
    }
}

function Run-Remote-AllowFail {
    param(
        [string]$RemoteHost,
        [string]$User,
        [string]$Password,
        [string]$Command
    )
    [void](Invoke-Plink $RemoteHost $User $Password $Command -AllowFail)
}

function Sudo-Remote {
    param(
        [string]$RemoteHost,
        [string]$User,
        [string]$Password,
        [string]$Command
    )
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Command))
    $sudoCmd = "printf '%s\n' '$Password' | sudo -S -p '' sh -c 'echo $b64 | base64 -d | sh'"
    Run-Remote $RemoteHost $User $Password $sudoCmd
}

function Copy-To-Remote {
    param(
        [string]$RemoteHost,
        [string]$User,
        [string]$Password,
        [string]$LocalPath,
        [string]$RemotePath
    )
    $result = Invoke-Pscp $RemoteHost $User $Password $LocalPath $RemotePath
    if ($result.ExitCode -ne 0) {
        throw ('Upload failed: {0} -> {1}@{2}:{3}' -f $LocalPath, $User, $RemoteHost, $RemotePath)
    }
}

function Write-Utf8NoBomLf {
    param(
        [string]$Path,
        [string]$Content
    )
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $Content = $Content -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Get-Remote-Text {
    param(
        [string]$RemoteHost,
        [string]$User,
        [string]$Password,
        [string]$Command
    )
    $result = Invoke-Plink $RemoteHost $User $Password $Command
    if ($result.ExitCode -ne 0) {
        throw ('Remote read failed: {0}@{1} :: {2}' -f $User, $RemoteHost, $Command)
    }
    $clean = @()
    foreach ($line in $result.Output) {
        $text = [string]$line
        if ($text -match '^\[sudo\] password for .*:\s*$') {
            continue
        }
        if ($text -match '^sudo: .*password.*$') {
            continue
        }
        $clean += $text
    }
    return (($clean -join "`n").Trim())
}

function Write-Manual-Test-Commands {
    param(
        [string]$ServerUser,
        [string]$ClientUser,
        [string]$ServerVpnIp,
        [string]$ClientVpnIp
    )
    Write-Host ""
    Write-Host "後續手動測試指令："
    Write-Host "  Server 上測 client:"
    Write-Host "    WG_TEST=yes sudo /home/$ServerUser/wireguard_check_start.sh server $ClientVpnIp"
    Write-Host "  Client 上測 server:"
    Write-Host "    WG_TEST=yes sudo /home/$ClientUser/wireguard_check_start.sh client $ServerVpnIp"
    Write-Host "  只啟動/查看狀態，不 ping:"
    Write-Host "    WG_TEST=no sudo /home/$ServerUser/wireguard_check_start.sh server $ClientVpnIp"
    Write-Host "    WG_TEST=no sudo /home/$ClientUser/wireguard_check_start.sh client $ServerVpnIp"
}

Need-Command "plink"
Need-Command "pscp"

Write-Host ""
Write-Host "模式："
Write-Host "  1) 部署 / 重新部署 WireGuard"
Write-Host "  2) 只測試現有 WireGuard 連線，不改設定"
Write-Host "  3) 新增一台 client 到既有 server，不重寫 server 設定"
Write-Host "  4) 建立 server + Android root client CLI 部署"
$Mode = Ask-Default "請選擇模式" "1"

if ($Mode -notin @("1", "2", "3", "4")) {
    throw "無效模式，請輸入 1、2、3 或 4。"
}


if ($Mode -eq "4") {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $androidScript = Join-Path $scriptDir "VpnDeployAndroid.ps1"
    if (-not (Test-Path -LiteralPath $androidScript)) {
        throw "找不到 VpnDeployAndroid.ps1。"
    }
    & $androidScript
    exit $LASTEXITCODE
}
if (-not $ServerIp) { $ServerIp = Ask-Ip "Server SSH IP (existing VPN server machine)" }
if (-not $ServerUser) { $ServerUser = Ask-Default "Server SSH User" "p" }
if (-not $ServerPassword) { $ServerPassword = Ask-Default "Server SSH Password" "p" }
if (-not $ServerHostKey) { $ServerHostKey = Ask-Default "Server SSH HostKey optional, Enter to skip" "" }
if (-not $ClientIp) { $ClientIp = Ask-Ip "Client SSH IP (client machine to configure, not the server)" }
if (-not $ClientUser) { $ClientUser = Ask-Default "Client SSH User" "p" }
if (-not $ClientPassword) { $ClientPassword = Ask-Default "Client SSH Password" "p" }
if (-not $ClientHostKey) { $ClientHostKey = Ask-Default "Client SSH HostKey optional, Enter to skip" "" }

if ($ServerIp -match "xx|XX" -or $ServerIp -notmatch "^\d{1,3}(\.\d{1,3}){3}$") {
    throw "ServerIp 必須是實際 IP，例如 192.168.23.177，不可使用 192.168.xx.xx。"
}
if ($ClientIp -match "xx|XX" -or $ClientIp -notmatch "^\d{1,3}(\.\d{1,3}){3}$") {
    throw "ClientIp 必須是實際 IP，例如 192.168.23.101，不可使用 192.168.xx.xx。"
}
if ($ServerIp -eq $ClientIp) {
    throw "Server SSH IP 和 Client SSH IP 不可以相同。Server 請填 VPN server 的 LAN IP；Client 請填要設定的 client 那台機器 LAN IP。"
}

Write-Host ""
Write-Host "SSH 角色確認："
Write-Host "  Server SSH target: $ServerUser@$ServerIp"
Write-Host "  Client SSH target: $ClientUser@$ClientIp"
Write-Host ""
Write-Host "請確認 Server 是 VPN server 那台，Client 是要被設定成 VPN client 的另一台。"
$roleConfirm = Ask-Default "角色正確？輸入 y 繼續" "y"
if ($roleConfirm -notin @("y", "Y", "yes", "YES")) {
    Write-Host "已取消。請重新執行並修正 Server/Client IP。"
    exit 0
}

$script:HostKeyMap = @{}
if ($ServerHostKey) { $script:HostKeyMap[$ServerIp] = $ServerHostKey }
if ($ClientHostKey) { $script:HostKeyMap[$ClientIp] = $ClientHostKey }

if ($Mode -eq "2") {
    $ServerVpnIp = Ask-Ip-Default "Server VPN IP" $ServerVpnIp
    $ClientVpnIp = Ask-Ip-Default "Client VPN IP" $ClientVpnIp

    Write-Host ""
    Write-Host "測試現有連線："
    Write-Host "  Server: $ServerUser@$ServerIp ping $ClientVpnIp"
    Write-Host "  Client: $ClientUser@$ClientIp ping $ServerVpnIp"
    Write-Host ""

    Write-Host "確認 SSH 連線..."
    Run-Remote $ServerIp $ServerUser $ServerPassword "echo server-ok; uname -m"
    Run-Remote $ClientIp $ClientUser $ClientPassword "echo client-ok; uname -m"

    Write-Host "執行 server 檢查..."
    Run-Remote $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' env WG_IF=$WgIf WG_TEST=yes /home/$ServerUser/wireguard_check_start.sh server $ClientVpnIp"

    Write-Host "執行 client 檢查..."
    Run-Remote $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' env WG_IF=$WgIf WG_TEST=yes /home/$ClientUser/wireguard_check_start.sh client $ServerVpnIp"

    Write-Host ""
    Write-Host "[OK] 現有 WireGuard 連線測試完成"
    Write-Manual-Test-Commands $ServerUser $ClientUser $ServerVpnIp $ClientVpnIp
    exit 0
}

if ($Mode -eq "3") {
    $VpnNetwork = Ask-Default "VPN Network" $VpnNetwork
    $ServerVpnIp = Ask-Ip-Default "Server VPN IP" $ServerVpnIp
    $ClientVpnCidr = Ask-Cidr-Default "New Client VPN CIDR" "10.66.66.3/32"
    $ClientVpnIp = ($ClientVpnCidr -split "/")[0]

    Write-Host ""
    Write-Host "新增 client 設定："
    Write-Host "  Existing Server: $ServerUser@$ServerIp"
    Write-Host "  New Client: $ClientUser@$ClientIp -> $ClientVpnCidr"
    Write-Host "  Endpoint: 會從 server 目前 ListenPort 自動帶入"
    Write-Host "  Server 不會 wg-quick down，只追加 peer 並即時 wg set"
    Write-Host ""

    $confirm = Ask-Default "新增 client？輸入 y 繼續" "y"
    if ($confirm -notin @("y", "Y", "yes", "YES")) {
        Write-Host "已取消。"
        exit 0
    }

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $checkScript = Join-Path $scriptDir "wireguard_check_start.sh"
    if (-not (Test-Path $checkScript)) {
        throw "找不到 wireguard_check_start.sh，請把它放在同一個資料夾。"
    }

    Write-Host "確認 SSH 連線..."
    Run-Remote $ServerIp $ServerUser $ServerPassword "echo server-ok; uname -m"
    Run-Remote $ClientIp $ClientUser $ClientPassword "echo client-ok; uname -m"

    Write-Host "確認工具與既有 server 設定..."
    $installCmd = "if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y wireguard iptables wireguard-go || apt-get install -y wireguard iptables; else echo 'Only apt-get Linux is supported by this deploy script'; exit 1; fi"
    Sudo-Remote $ClientIp $ClientUser $ClientPassword $installCmd
    Sudo-Remote $ServerIp $ServerUser $ServerPassword "command -v wg >/dev/null 2>&1 || exit 1; test -f /etc/wireguard/$WgIf.conf; test -s /etc/wireguard/keys/server.key || exit 1; if [ ! -s /etc/wireguard/keys/server.pub ]; then wg pubkey < /etc/wireguard/keys/server.key > /etc/wireguard/keys/server.pub; fi"
    $ServerListenPort = Get-Remote-Text $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' sed -n 's/^ListenPort *= *//p' /etc/wireguard/$WgIf.conf | tail -n 1"
    if ([string]::IsNullOrWhiteSpace($ServerListenPort)) {
        $ServerListenPort = $ListenPort
    }
    $Endpoint = Ask-Default "Client connect endpoint" "${ServerIp}:$ServerListenPort"

    Write-Host "準備新 client key..."
    $prepKeys = "mkdir -p /etc/wireguard/keys; chmod 700 /etc/wireguard /etc/wireguard/keys"
    Sudo-Remote $ClientIp $ClientUser $ClientPassword $prepKeys
    $genClientKey = "umask 077; if [ ! -s /etc/wireguard/keys/client.key ]; then wg genkey > /etc/wireguard/keys/client.key; wg pubkey < /etc/wireguard/keys/client.key > /etc/wireguard/keys/client.pub; fi"
    Sudo-Remote $ClientIp $ClientUser $ClientPassword $genClientKey

    $serverPub = Get-Remote-Text $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' cat /etc/wireguard/keys/server.pub | tail -n 1"
    $clientPriv = Get-Remote-Text $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' cat /etc/wireguard/keys/client.key | tail -n 1"
    $clientPub = Get-Remote-Text $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' cat /etc/wireguard/keys/client.pub | tail -n 1"

    $clientConf = @"
[Interface]
Address = $ClientVpnCidr
PrivateKey = $clientPriv

[Peer]
# server $ServerIp
PublicKey = $serverPub
Endpoint = $Endpoint
AllowedIPs = $VpnNetwork
PersistentKeepalive = 25
"@

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wg-add-client-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $clientConfPath = Join-Path $tmp "client-wg0.conf"
        Write-Utf8NoBomLf $clientConfPath $clientConf

        Write-Host "上傳新 client 設定與檢查腳本..."
        Copy-To-Remote $ClientIp $ClientUser $ClientPassword $clientConfPath "/tmp/wg0.conf"
        Copy-To-Remote $ServerIp $ServerUser $ServerPassword $checkScript "/home/$ServerUser/wireguard_check_start.sh"
        Copy-To-Remote $ClientIp $ClientUser $ClientPassword $checkScript "/home/$ClientUser/wireguard_check_start.sh"
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }

    Write-Host "追加 server peer，不中斷既有 client..."
    $appendPeer = "set -e; conf=/etc/wireguard/$WgIf.conf; test -f `$conf; if grep -Fq '$clientPub' `$conf; then echo 'Peer public key already exists in server config'; else if grep -Fq 'AllowedIPs = $ClientVpnCidr' `$conf; then echo 'VPN IP already exists in server config'; exit 1; fi; cp -a `$conf `$conf.bak.`$(date +%Y%m%d%H%M%S); printf '\n[Peer]\n# client $ClientIp\nPublicKey = $clientPub\nAllowedIPs = $ClientVpnCidr\n' >> `$conf; chmod 600 `$conf; fi; if ip link show $WgIf >/dev/null 2>&1; then wg set $WgIf peer '$clientPub' allowed-ips '$ClientVpnCidr'; fi"
    Sudo-Remote $ServerIp $ServerUser $ServerPassword $appendPeer

    Write-Host "套用新 client 設定..."
    $applyClientConf = "if [ -e /etc/wireguard/$WgIf.conf ]; then cp -a /etc/wireguard/$WgIf.conf /etc/wireguard/$WgIf.conf.bak.`$(date +%Y%m%d%H%M%S); fi; mv /tmp/wg0.conf /etc/wireguard/$WgIf.conf; chmod 600 /etc/wireguard/$WgIf.conf"
    Sudo-Remote $ClientIp $ClientUser $ClientPassword $applyClientConf
    Run-Remote $ServerIp $ServerUser $ServerPassword "chmod +x /home/$ServerUser/wireguard_check_start.sh"
    Run-Remote $ClientIp $ClientUser $ClientPassword "chmod +x /home/$ClientUser/wireguard_check_start.sh"
    Run-Remote-AllowFail $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' systemctl disable wg-quick@$WgIf >/dev/null 2>&1 || true"
    Run-Remote-AllowFail $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' wg-quick down $WgIf >/dev/null 2>&1 || true"

    Write-Host "確認 server 介面，不重啟 server..."
    Run-Remote $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' env WG_IF=$WgIf WG_TEST=no /home/$ServerUser/wireguard_check_start.sh server $ClientVpnIp"

    Write-Host "啟動新 client..."
    Run-Remote $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' env WG_IF=$WgIf WG_TEST=yes /home/$ClientUser/wireguard_check_start.sh client $ServerVpnIp"

    Write-Host "最終互 ping 驗證..."
    Run-Remote $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' ping -c 3 -W 1 $ClientVpnIp"
    Run-Remote $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' ping -c 3 -W 1 $ServerVpnIp"

    Write-Host ""
    Write-Host "[OK] 新 client 已加入既有 server"
    Write-Host "  Server VPN IP: $ServerVpnIp"
    Write-Host "  New Client VPN IP: $ClientVpnIp"
    Write-Manual-Test-Commands $ServerUser $ClientUser $ServerVpnIp $ClientVpnIp
    exit 0
}

if ($Mode -ne "1") {
    throw "無效模式，請輸入 1、2 或 3。"
}

$ListenPort = Ask-Default "WireGuard Listen Port" $ListenPort
$VpnNetwork = Ask-Default "VPN Network" $VpnNetwork
$ServerVpnCidr = Ask-Cidr-Default "Server VPN CIDR" $ServerVpnCidr
$ClientVpnCidr = Ask-Cidr-Default "Client VPN CIDR" $ClientVpnCidr
$ServerVpnIp = ($ServerVpnCidr -split "/")[0]
$ClientVpnIp = ($ClientVpnCidr -split "/")[0]
$Endpoint = Ask-Default "Client connect endpoint" "${ServerIp}:$ListenPort"

Write-Host ""
Write-Host "部署設定："
Write-Host "  Server: $ServerUser@$ServerIp -> $ServerVpnCidr"
Write-Host "  Client: $ClientUser@$ClientIp -> $ClientVpnCidr"
Write-Host "  Endpoint: $Endpoint"
Write-Host "  不會設定開機自動啟動"
Write-Host ""

$confirm = Ask-Default "開始部署？輸入 y 繼續" "y"
if ($confirm -notin @("y", "Y", "yes", "YES")) {
    Write-Host "已取消。"
    exit 0
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$checkScript = Join-Path $scriptDir "wireguard_check_start.sh"
if (-not (Test-Path $checkScript)) {
    throw "找不到 wireguard_check_start.sh，請把它放在同一個資料夾。"
}

Write-Host "確認 SSH 連線..."
Run-Remote $ServerIp $ServerUser $ServerPassword "echo server-ok; uname -m"
Run-Remote $ClientIp $ClientUser $ClientPassword "echo client-ok; uname -m"

Write-Host "安裝 WireGuard 工具..."
$installCmd = "if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y wireguard iptables wireguard-go || apt-get install -y wireguard iptables; else echo 'Only apt-get Linux is supported by this deploy script'; exit 1; fi"
Sudo-Remote $ServerIp $ServerUser $ServerPassword $installCmd
Sudo-Remote $ClientIp $ClientUser $ClientPassword $installCmd

Write-Host "準備 WireGuard 目錄與 key..."
$prepKeys = "mkdir -p /etc/wireguard/keys; chmod 700 /etc/wireguard /etc/wireguard/keys"
Sudo-Remote $ServerIp $ServerUser $ServerPassword $prepKeys
Sudo-Remote $ClientIp $ClientUser $ClientPassword $prepKeys

$genServerKey = "umask 077; if [ ! -s /etc/wireguard/keys/server.key ]; then wg genkey > /etc/wireguard/keys/server.key; wg pubkey < /etc/wireguard/keys/server.key > /etc/wireguard/keys/server.pub; fi"
$genClientKey = "umask 077; if [ ! -s /etc/wireguard/keys/client.key ]; then wg genkey > /etc/wireguard/keys/client.key; wg pubkey < /etc/wireguard/keys/client.key > /etc/wireguard/keys/client.pub; fi"
Sudo-Remote $ServerIp $ServerUser $ServerPassword $genServerKey
Sudo-Remote $ClientIp $ClientUser $ClientPassword $genClientKey

$serverPriv = Get-Remote-Text $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' cat /etc/wireguard/keys/server.key | tail -n 1"
$serverPub = Get-Remote-Text $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' cat /etc/wireguard/keys/server.pub | tail -n 1"
$clientPriv = Get-Remote-Text $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' cat /etc/wireguard/keys/client.key | tail -n 1"
$clientPub = Get-Remote-Text $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' cat /etc/wireguard/keys/client.pub | tail -n 1"

$serverConf = @"
[Interface]
Address = $ServerVpnCidr
ListenPort = $ListenPort
PrivateKey = $serverPriv

[Peer]
# client $ClientIp
PublicKey = $clientPub
AllowedIPs = $ClientVpnCidr
"@

$clientConf = @"
[Interface]
Address = $ClientVpnCidr
PrivateKey = $clientPriv

[Peer]
# server $ServerIp
PublicKey = $serverPub
Endpoint = $Endpoint
AllowedIPs = $VpnNetwork
PersistentKeepalive = 25
"@

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wg-deploy-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $serverConfPath = Join-Path $tmp "server-wg0.conf"
    $clientConfPath = Join-Path $tmp "client-wg0.conf"
    Write-Utf8NoBomLf $serverConfPath $serverConf
    Write-Utf8NoBomLf $clientConfPath $clientConf

    Write-Host "上傳設定與檢查腳本..."
    Copy-To-Remote $ServerIp $ServerUser $ServerPassword $serverConfPath "/tmp/wg0.conf"
    Copy-To-Remote $ClientIp $ClientUser $ClientPassword $clientConfPath "/tmp/wg0.conf"
    Copy-To-Remote $ServerIp $ServerUser $ServerPassword $checkScript "/home/$ServerUser/wireguard_check_start.sh"
    Copy-To-Remote $ClientIp $ClientUser $ClientPassword $checkScript "/home/$ClientUser/wireguard_check_start.sh"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host "套用設定..."
$applyConf = "if [ -e /etc/wireguard/$WgIf.conf ]; then cp -a /etc/wireguard/$WgIf.conf /etc/wireguard/$WgIf.conf.bak.`$(date +%Y%m%d%H%M%S); fi; mv /tmp/wg0.conf /etc/wireguard/$WgIf.conf; chmod 600 /etc/wireguard/$WgIf.conf"
Sudo-Remote $ServerIp $ServerUser $ServerPassword $applyConf
Sudo-Remote $ClientIp $ClientUser $ClientPassword $applyConf
Run-Remote $ServerIp $ServerUser $ServerPassword "chmod +x /home/$ServerUser/wireguard_check_start.sh"
Run-Remote $ClientIp $ClientUser $ClientPassword "chmod +x /home/$ClientUser/wireguard_check_start.sh"

Write-Host "確認不開機自動啟動..."
Run-Remote-AllowFail $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' systemctl disable wg-quick@$WgIf >/dev/null 2>&1 || true"
Run-Remote-AllowFail $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' systemctl disable wg-quick@$WgIf >/dev/null 2>&1 || true"

Write-Host "重啟 WireGuard 測試介面..."
Run-Remote-AllowFail $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' wg-quick down $WgIf >/dev/null 2>&1 || true"
Run-Remote-AllowFail $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' wg-quick down $WgIf >/dev/null 2>&1 || true"

Write-Host "啟動 server..."
Run-Remote $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' env WG_IF=$WgIf WG_TEST=no /home/$ServerUser/wireguard_check_start.sh server $ClientVpnIp"

Write-Host "啟動 client..."
Run-Remote $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' env WG_IF=$WgIf WG_TEST=yes /home/$ClientUser/wireguard_check_start.sh client $ServerVpnIp"

Write-Host "最終互 ping 驗證..."
Run-Remote $ServerIp $ServerUser $ServerPassword "printf '%s\n' '$ServerPassword' | sudo -S -p '' ping -c 3 -W 1 $ClientVpnIp"
Run-Remote $ClientIp $ClientUser $ClientPassword "printf '%s\n' '$ClientPassword' | sudo -S -p '' ping -c 3 -W 1 $ServerVpnIp"

Write-Host ""
Write-Host "[OK] WireGuard 部署完成"
Write-Host "  Server VPN IP: $ServerVpnIp"
Write-Host "  Client VPN IP: $ClientVpnIp"
Write-Manual-Test-Commands $ServerUser $ClientUser $ServerVpnIp $ClientVpnIp
