param(
    [string]$ServerIp,
    [string]$ServerUser = "pcp",
    [string]$ServerPassword = "pcp",
    [string]$ServerHostKey = "",
    [string]$AndroidIp,
    [string]$AndroidUser = "root",
    [string]$AndroidPassword = "p",
    [int]$AndroidSshPort = 22,
    [string]$AndroidHostKey = "",
    [string]$AndroidWgBinary = "",
    [string]$WgIf = "wg0",
    [int]$ListenPort = 51820,
    [string]$VpnNetwork = "10.66.66.0/24",
    [string]$ServerVpnCidr = "10.66.66.1/24",
    [string]$AndroidVpnCidr = "10.66.66.3/32",
    [string]$Endpoint = "",
    [string]$AllowedIPs = "10.66.66.0/24",
    [string]$ClientName = "android-root"
)

$ErrorActionPreference = "Stop"
$script:HostKeyMap = @{}
$script:HostKeyMap["192.168.23.167:22"] = "SHA256:fkvFUVUsD8fb99L67eLsqGQFZiwo8/0dLOlg8L1M5fE"
$script:HostKeyMap["192.168.23.101:22"] = "SHA256:93+dAH7QQmP4nmPQ9UsJAB7dQ13x3uB7tx1gxO1hiNY"
$script:HostKeyMap["192.168.23.140:22"] = "SHA256:9EBe/l5ctiSPxyoKux+pd6bVq6XkCFamU80pa6GJN/w"
$script:HostKeyMap["192.168.23.140:8022"] = "SHA256:9EBe/l5ctiSPxyoKux+pd6bVq6XkCFamU80pa6GJN/w"

function Read-Value {
    param(
        [string]$Prompt,
        [string]$Default = "",
        [bool]$Required = $false
    )
    while ($true) {
        if ($Default) {
            $text = Read-Host "$Prompt [$Default]"
            if ([string]::IsNullOrWhiteSpace($text)) { $text = $Default }
        } else {
            $text = Read-Host "$Prompt"
        }
        if (-not $Required -or -not [string]::IsNullOrWhiteSpace($text)) {
            return $text
        }
        Write-Host "This field is required." -ForegroundColor Yellow
    }
}

function Read-IpValue {
    param([string]$Prompt)
    while ($true) {
        $text = Read-Host "$Prompt [192.168.xx.xx]"
        if ($text -match '^\d{1,3}(\.\d{1,3}){3}$') {
            return $text
        }
        Write-Host "This field has no default. Enter the actual IP, for example 192.168.23.167." -ForegroundColor Yellow
    }
}

function Get-HostKeyMapKey {
    param([string]$RemoteHost, [int]$Port = 22)
    return "$RemoteHost`:$Port"
}

function Get-PlinkArgs {
    param([string]$RemoteHost, [string]$HostKey, [int]$Port = 22)
    $key = Get-HostKeyMapKey $RemoteHost $Port
    $args = @("-batch", "-ssh")
    if ($Port -ne 22) {
        $args += @("-P", ([string]$Port))
    }
    if ($script:HostKeyMap.ContainsKey($key) -and $script:HostKeyMap[$key]) {
        $args += @("-hostkey", $script:HostKeyMap[$key])
    } elseif (-not [string]::IsNullOrWhiteSpace($HostKey)) {
        $args += @("-hostkey", $HostKey)
    }
    return $args
}

function Trust-HostKeyFromOutput {
    param([string]$RemoteHost, [int]$Port, [object[]]$Output)

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
    Write-Host "SSH host key needs confirmation for $RemoteHost`:$Port" -ForegroundColor Yellow
    Write-Host "Fingerprint: $fingerprint" -ForegroundColor Yellow
    Write-Host "If this IP was reinstalled or changed to a new device, this can be expected."
    $answer = Read-Host "Trust this host key and continue? [y/N]"
    if ($answer -in @("y", "Y", "yes", "YES")) {
        $script:HostKeyMap[(Get-HostKeyMapKey $RemoteHost $Port)] = $fingerprint
        Write-Host "Using host key for this deployment: $fingerprint"
        return $true
    }

    return $false
}

function Invoke-Remote {
    param(
        [string]$Ip,
        [string]$User,
        [string]$Password,
        [string]$HostKey,
        [string]$Command,
        [int]$Port = 22
    )
    for ($try = 0; $try -lt 2; $try++) {
        $args = Get-PlinkArgs $Ip $HostKey $Port
        $args += @("-l", $User, "-pw", $Password, $Ip, $Command)
        $oldErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & plink.exe @args 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorAction
        }
        if ($output) { $output | ForEach-Object { Write-Host $_ } }
        if ($code -eq 0) {
            return
        }
        if ($try -eq 0 -and (Trust-HostKeyFromOutput $Ip $Port $output)) {
            continue
        }
        throw "Remote command failed: $User@$Ip`:$Port :: $Command"
    }
}

function Copy-ToRemote {
    param(
        [string]$Source,
        [string]$Ip,
        [string]$User,
        [string]$Password,
        [string]$HostKey,
        [string]$Destination,
        [int]$Port = 22
    )
    for ($try = 0; $try -lt 2; $try++) {
        $args = @("-batch")
        if ($Port -ne 22) {
            $args += @("-P", ([string]$Port))
        }
        $key = Get-HostKeyMapKey $Ip $Port
        if ($script:HostKeyMap.ContainsKey($key) -and $script:HostKeyMap[$key]) {
            $args += @("-hostkey", $script:HostKeyMap[$key])
        } elseif (-not [string]::IsNullOrWhiteSpace($HostKey)) {
            $args += @("-hostkey", $HostKey)
        }
        $args += @("-pw", $Password, $Source, "$User@$Ip`:$Destination")
        $oldErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & pscp.exe @args 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorAction
        }
        if ($output) { $output | ForEach-Object { Write-Host $_ } }
        if ($code -eq 0) {
            return
        }
        if ($try -eq 0 -and (Trust-HostKeyFromOutput $Ip $Port $output)) {
            continue
        }
        if (Test-Path -LiteralPath $Source) {
            Write-Host "pscp failed; trying base64-over-ssh upload fallback..." -ForegroundColor Yellow
            $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Source)))
            $destQ = "'" + $Destination.Replace("'", "'\''") + "'"
            $fallbackCmd = "mkdir -p `$(dirname $destQ) && base64 -d > $destQ"
            $plinkArgs = Get-PlinkArgs $Ip $HostKey $Port
            $plinkArgs += @("-l", $User, "-pw", $Password, $Ip, $fallbackCmd)
            $oldErrorAction = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $output = $b64 | & plink.exe @plinkArgs 2>&1
                $code = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldErrorAction
            }
            if ($output) { $output | ForEach-Object { Write-Host $_ } }
            if ($code -ne 0) {
                throw "Base64 upload fallback failed: $Source -> $User@$Ip`:$Port`:$Destination"
            }
            return
        }
        throw "Copy failed: $Source -> $User@$Ip`:$Port`:$Destination"
    }
}

function Copy-FromRemote {
    param(
        [string]$Ip,
        [string]$User,
        [string]$Password,
        [string]$HostKey,
        [string]$Source,
        [string]$Destination,
        [int]$Port = 22
    )
    for ($try = 0; $try -lt 2; $try++) {
        $args = @("-batch")
        if ($Port -ne 22) {
            $args += @("-P", ([string]$Port))
        }
        $key = Get-HostKeyMapKey $Ip $Port
        if ($script:HostKeyMap.ContainsKey($key) -and $script:HostKeyMap[$key]) {
            $args += @("-hostkey", $script:HostKeyMap[$key])
        } elseif (-not [string]::IsNullOrWhiteSpace($HostKey)) {
            $args += @("-hostkey", $HostKey)
        }
        $args += @("-pw", $Password, "$User@$Ip`:$Source", $Destination)
        $oldErrorAction = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & pscp.exe @args 2>&1
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorAction
        }
        if ($output) { $output | ForEach-Object { Write-Host $_ } }
        if ($code -eq 0) {
            return
        }
        if ($try -eq 0 -and (Trust-HostKeyFromOutput $Ip $Port $output)) {
            continue
        }
        throw "Copy failed: $User@$Ip`:$Port`:$Source -> $Destination"
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Shell-SingleQuote {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Invoke-AndroidRootRemote {
    param(
        [string]$Command
    )
    if ($AndroidUser -eq "root") {
        Invoke-Remote $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey $Command $AndroidSshPort
    } else {
        Invoke-Remote $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey ("su -c " + (Shell-SingleQuote $Command)) $AndroidSshPort
    }
}

function Require-Tool {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool not found in PATH: $Name"
    }
}

Require-Tool "plink.exe"
Require-Tool "pscp.exe"

Write-Host "Android WireGuard Deploy"
Write-Host "Mode: create/update Ubuntu server + add Android CLI client"
Write-Host ""

if (-not $ServerIp) { $ServerIp = Read-IpValue "Server SSH IP" }
$ServerUser = Read-Value "Server SSH User" $ServerUser $true
$ServerPassword = Read-Value "Server SSH Password" $ServerPassword $true

if (-not $AndroidIp) { $AndroidIp = Read-IpValue "Android SSH IP" }
$AndroidUser = Read-Value "Android SSH User" $AndroidUser $true
$AndroidPassword = Read-Value "Android SSH Password" $AndroidPassword $true
if (-not $Endpoint) { $Endpoint = "$ServerIp`:$ListenPort" }
if ($Endpoint -match '^\d+$') {
    $Endpoint = "$ServerIp`:$Endpoint"
    Write-Host "Endpoint port only detected; using: $Endpoint" -ForegroundColor Yellow
} elseif ($Endpoint -notmatch '^\[?[A-Za-z0-9:.%-]+\]?:\d+$') {
    throw "Android connect endpoint must be host:port, for example $ServerIp`:$ListenPort"
}
if ($ClientName -notmatch '^[A-Za-z0-9_.-]+$') {
    throw "Android client name can only contain letters, numbers, underscore, dot, and dash."
}
$defaultAndroidWgBinary = Join-Path (Get-Location) "android-bin\wg-arm64"
if ([string]::IsNullOrWhiteSpace($AndroidWgBinary) -and (Test-Path -LiteralPath $defaultAndroidWgBinary)) {
    $AndroidWgBinary = $defaultAndroidWgBinary
}

Write-Host ""
Write-Host "Deployment summary:"
Write-Host "  Server : $ServerUser@$ServerIp -> $ServerVpnCidr"
Write-Host "  Android: $AndroidUser@$AndroidIp`:$AndroidSshPort -> $AndroidVpnCidr"
Write-Host "  Endpoint: $Endpoint"
Write-Host "  AllowedIPs: $AllowedIPs"
Write-Host "  Interface: $WgIf"
Write-Host ""
$confirm = Read-Value "Start deployment? Type y to continue" "y" $true
if ($confirm -notmatch '^[Yy]$') {
    Write-Host "Cancelled."
    exit 0
}

Write-Host "Checking SSH connections..."
Invoke-Remote $ServerIp $ServerUser $ServerPassword $ServerHostKey "echo server-ok; uname -a; command -v wg || true; command -v wg-quick || true"
Invoke-Remote $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey "echo android-ok; id; su -c id 2>/dev/null || true; uname -a; getprop ro.build.version.release 2>/dev/null || true; ls -l /dev/net/tun 2>/dev/null || true" $AndroidSshPort

$work = Join-Path $env:TEMP ("VpnDeployAndroid-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null

$serverScript = @'
#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

WG_IF="$1"
LISTEN_PORT="$2"
SERVER_CIDR="$3"
CLIENT_CIDR="$4"
ENDPOINT="$5"
ALLOWED_IPS="$6"
CLIENT_NAME="$7"

WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/$WG_IF.conf"
OUT_DIR="/tmp/vpn-android-$CLIENT_NAME"
CLIENT_CONF="$OUT_DIR/$CLIENT_NAME.conf"
CLIENT_SETCONF="$OUT_DIR/$CLIENT_NAME.setconf"

if command -v apt-get >/dev/null 2>&1; then
  if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables wireguard-go || DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables
  fi
else
  echo "ERROR: server must be apt-get based Linux for this deploy script." >&2
  exit 1
fi

command -v wg >/dev/null 2>&1
command -v wg-quick >/dev/null 2>&1

WG_QUICK_CMD="wg-quick"
WIREGUARD_GO_BIN=""
for bin in wireguard-go /usr/bin/wireguard-go /usr/sbin/wireguard-go /usr/local/bin/wireguard-go /usr/local/sbin/wireguard-go /usr/bin/wireguard; do
  if command -v "$bin" >/dev/null 2>&1; then
    WIREGUARD_GO_BIN="$(command -v "$bin")"
    break
  elif [ -x "$bin" ]; then
    WIREGUARD_GO_BIN="$bin"
    break
  fi
done
WG_KERNEL_TEST="wgtest$$"
if ip link add "$WG_KERNEL_TEST" type wireguard >/dev/null 2>&1; then
  ip link delete "$WG_KERNEL_TEST" >/dev/null 2>&1 || true
else
  if [ -z "$WIREGUARD_GO_BIN" ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard-go || true
    for bin in wireguard-go /usr/bin/wireguard-go /usr/sbin/wireguard-go /usr/local/bin/wireguard-go /usr/local/sbin/wireguard-go /usr/bin/wireguard; do
      if command -v "$bin" >/dev/null 2>&1; then
        WIREGUARD_GO_BIN="$(command -v "$bin")"
        break
      elif [ -x "$bin" ]; then
        WIREGUARD_GO_BIN="$bin"
        break
      fi
    done
  fi
  if [ -n "$WIREGUARD_GO_BIN" ]; then
    if [ ! -e /dev/net/tun ]; then
      echo "ERROR: kernel WireGuard is not supported and /dev/net/tun is missing, so wireguard-go cannot run." >&2
      exit 1
    fi
    WG_QUICK_CMD="env WG_QUICK_USERSPACE_IMPLEMENTATION=$WIREGUARD_GO_BIN wg-quick"
    echo "Kernel WireGuard is not supported; using wireguard-go userspace backend: $WIREGUARD_GO_BIN"
  else
    echo "ERROR: kernel WireGuard is not supported and wireguard-go is not installed." >&2
    echo "Install wireguard-go or enable CONFIG_WIREGUARD in the server kernel." >&2
    exit 1
  fi
fi

mkdir -p "$WG_DIR" "$OUT_DIR" "$WG_DIR/keys"
chmod 700 "$WG_DIR"

if ip link show "$WG_IF" >/dev/null 2>&1; then
  $WG_QUICK_CMD down "$WG_IF" >/dev/null 2>&1 || ip link delete "$WG_IF" >/dev/null 2>&1 || true
fi

umask 077
SERVER_PRIV="$(wg genkey)"
printf '%s\n' "$SERVER_PRIV" > "$WG_DIR/keys/server.key"
chmod 600 "$WG_DIR/keys/server.key"
cat > "$WG_CONF" <<EOF
[Interface]
Address = $SERVER_CIDR
ListenPort = $LISTEN_PORT
PrivateKey = $SERVER_PRIV
SaveConfig = false
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -C FORWARD -i $WG_IF -j ACCEPT 2>/dev/null || iptables -A FORWARD -i $WG_IF -j ACCEPT; iptables -C FORWARD -o $WG_IF -j ACCEPT 2>/dev/null || iptables -A FORWARD -o $WG_IF -j ACCEPT
PostDown = iptables -D FORWARD -i $WG_IF -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o $WG_IF -j ACCEPT 2>/dev/null || true

EOF
chmod 600 "$WG_CONF"
SERVER_PUB="$(printf '%s\n' "$SERVER_PRIV" | wg pubkey)"

CLIENT_IP="${CLIENT_CIDR%/*}"

umask 077
CLIENT_PRIV="$(wg genkey)"
CLIENT_PUB="$(printf '%s\n' "$CLIENT_PRIV" | wg pubkey)"
PSK="$(wg genpsk)"

cat >> "$WG_CONF" <<EOF

[Peer]
# $CLIENT_NAME
PublicKey = $CLIENT_PUB
PresharedKey = $PSK
AllowedIPs = $CLIENT_CIDR
EOF

cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $CLIENT_CIDR

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $PSK
Endpoint = $ENDPOINT
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
EOF

cat > "$CLIENT_SETCONF" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $PSK
Endpoint = $ENDPOINT
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
EOF

chmod 600 "$CLIENT_CONF" "$CLIENT_SETCONF"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  chown -R "$SUDO_USER:$SUDO_USER" "$OUT_DIR" 2>/dev/null || true
fi

if systemctl list-unit-files "wg-quick@$WG_IF.service" >/dev/null 2>&1; then
  systemctl disable "wg-quick@$WG_IF" >/dev/null 2>&1 || true
fi

if ip link show "$WG_IF" >/dev/null 2>&1; then
  wg syncconf "$WG_IF" "$(wg-quick strip "$WG_IF")"
else
  $WG_QUICK_CMD up "$WG_IF"
fi

echo "SERVER_CONFIG=$WG_CONF"
echo "CLIENT_CONF=$CLIENT_CONF"
echo "CLIENT_SETCONF=$CLIENT_SETCONF"
echo "SERVER_PUBLIC_KEY=$SERVER_PUB"
wg show "$WG_IF"
'@

$androidScript = @'
#!/system/bin/sh
set -eu

WG_IF="$1"
CLIENT_CIDR="$2"
ROUTES="$3"
WG_BIN="$4"
SETCONF="$5"
SERVER_IP="$6"

if [ ! -x "$WG_BIN" ]; then
  echo "ERROR: wg binary is missing or not executable: $WG_BIN" >&2
  exit 42
fi

if ! ip link add "$WG_IF" type wireguard 2>/dev/null; then
  ip link delete "$WG_IF" 2>/dev/null || true
  ip link add "$WG_IF" type wireguard
fi

ip address add "$CLIENT_CIDR" dev "$WG_IF" 2>/dev/null || true
"$WG_BIN" setconf "$WG_IF" "$SETCONF"
ip link set "$WG_IF" up

if command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -i "$WG_IF" -j ACCEPT 2>/dev/null || iptables -A INPUT -i "$WG_IF" -j ACCEPT 2>/dev/null || true
fi

OLDIFS="$IFS"
IFS=","
for route in $ROUTES; do
  route="$(echo "$route" | tr -d ' ')"
  [ -z "$route" ] && continue
  case "$route" in
    0.0.0.0/0|::/0)
      echo "ERROR: Android CLI mode does not manage default routes. Use VPN subnet AllowedIPs, for example 10.66.66.0/24." >&2
      exit 43
      ;;
    *)
      ip route replace "$route" dev "$WG_IF" 2>/dev/null || true
      ;;
  esac
done
IFS="$OLDIFS"

"$WG_BIN" show "$WG_IF"
ping -I "$WG_IF" -c 3 -W 2 "$SERVER_IP"
'@

$serverScriptPath = Join-Path $work "server_android_peer.sh"
$androidScriptPath = Join-Path $work "android_wg_up.sh"
Write-Utf8NoBom $serverScriptPath $serverScript
Write-Utf8NoBom $androidScriptPath $androidScript
$androidRemoteDir = "/data/local/tmp/wireguard"

Write-Host "Uploading server deployment script..."
Copy-ToRemote $serverScriptPath $ServerIp $ServerUser $ServerPassword $ServerHostKey "/tmp/server_android_peer.sh"
Invoke-Remote $ServerIp $ServerUser $ServerPassword $ServerHostKey "chmod +x /tmp/server_android_peer.sh"

$serverVpnIp = $ServerVpnCidr.Split('/')[0]
$serverCmd = "printf '%s\n' '$ServerPassword' | sudo -S -p '' /tmp/server_android_peer.sh '$WgIf' '$ListenPort' '$ServerVpnCidr' '$AndroidVpnCidr' '$Endpoint' '$AllowedIPs' '$ClientName'"
Write-Host "Configuring server and adding Android peer..."
Invoke-Remote $ServerIp $ServerUser $ServerPassword $ServerHostKey $serverCmd

Write-Host "Downloading generated Android config..."
$localClientConf = Join-Path (Get-Location) "$ClientName.conf"
$localSetConf = Join-Path (Get-Location) "$ClientName.setconf"
Copy-FromRemote $ServerIp $ServerUser $ServerPassword $ServerHostKey "/tmp/vpn-android-$ClientName/$ClientName.conf" $localClientConf
Copy-FromRemote $ServerIp $ServerUser $ServerPassword $ServerHostKey "/tmp/vpn-android-$ClientName/$ClientName.setconf" $localSetConf

Write-Host "Uploading Android configs..."
Invoke-Remote $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey "mkdir -p '$androidRemoteDir'" $AndroidSshPort
Copy-ToRemote $localClientConf $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey "$androidRemoteDir/$ClientName.conf" $AndroidSshPort
Copy-ToRemote $localSetConf $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey "$androidRemoteDir/$ClientName.setconf" $AndroidSshPort
Copy-ToRemote $androidScriptPath $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey "$androidRemoteDir/android_wg_up.sh" $AndroidSshPort
Invoke-Remote $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey "chmod +x '$androidRemoteDir/android_wg_up.sh'" $AndroidSshPort

$androidWgPath = "$androidRemoteDir/wg"
if (-not [string]::IsNullOrWhiteSpace($AndroidWgBinary)) {
    if (-not (Test-Path -LiteralPath $AndroidWgBinary)) {
        throw "Android wg binary not found: $AndroidWgBinary"
    }
    Write-Host "Uploading Android wg binary..."
    Copy-ToRemote $AndroidWgBinary $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey $androidWgPath $AndroidSshPort
    Invoke-Remote $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey "chmod 755 $androidWgPath" $AndroidSshPort
}

Write-Host "Checking Android wg binary..."
$remoteWgPath = ""
$androidWgCandidates = @(
    $androidWgPath,
    "/system/bin/wg",
    "/vendor/bin/wg",
    "/data/data/com.termux/files/usr/bin/wg"
)
foreach ($candidate in $androidWgCandidates) {
    if ($remoteWgPath) { break }
    try {
        Invoke-Remote $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey "test -x '$candidate'" $AndroidSshPort
        $remoteWgPath = $candidate
    } catch {
        continue
    }
}

if (-not $remoteWgPath) {
    $installTermux = Read-Value "Android wg not found. Install Termux wireguard-tools now? [y/N]" "n" $true
    if ($installTermux -match '^[Yy]$') {
        Invoke-Remote $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey "TERMUX_DIR=/data/data/com.termux; TERMUX_USER=`$(stat -c %U `"`$TERMUX_DIR`" 2>/dev/null || ls -ld `"`$TERMUX_DIR`" 2>/dev/null | awk '{print `$3}'); if [ -z `"`$TERMUX_USER`" ]; then echo 'ERROR: cannot detect Termux app user from /data/data/com.termux' >&2; exit 1; fi; echo `"Detected Termux user: `$TERMUX_USER`"; if [ `"`$(id -u)`" = 0 ]; then su `"`$TERMUX_USER`" sh -c 'export PATH=/data/data/com.termux/files/usr/bin:/system/bin:/system/xbin:$PATH; pkg install -y wireguard-tools'; else export PATH=/data/data/com.termux/files/usr/bin:/system/bin:/system/xbin:`$PATH; pkg install -y wireguard-tools; fi" $AndroidSshPort
        try {
            Invoke-Remote $AndroidIp $AndroidUser $AndroidPassword $AndroidHostKey "test -x /data/data/com.termux/files/usr/bin/wg" $AndroidSshPort
            $remoteWgPath = "/data/data/com.termux/files/usr/bin/wg"
        } catch {
            $remoteWgPath = ""
        }
    }
}

if ($remoteWgPath) {
    Write-Host "Starting Android WireGuard interface..."
    $androidStartCmd = "'$androidRemoteDir/android_wg_up.sh' '$WgIf' '$AndroidVpnCidr' '$AllowedIPs' '$remoteWgPath' '$androidRemoteDir/$ClientName.setconf' '$serverVpnIp'"
    Invoke-AndroidRootRemote $androidStartCmd
    $androidVpnIp = $AndroidVpnCidr.Split('/')[0]
    Write-Host "Testing server to Android VPN IP..."
    try {
        Invoke-Remote $ServerIp $ServerUser $ServerPassword $ServerHostKey "printf '%s\n' '$ServerPassword' | sudo -S -p '' ping -I '$WgIf' -c 3 -W 2 '$androidVpnIp'"
    } catch {
        Write-Host "WARN: Android-to-server VPN ping passed, but server-to-Android ICMP did not reply." -ForegroundColor Yellow
        Write-Host "WARN: This can be Android firewall/ICMP policy; WireGuard handshake and client route are already verified." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "RESULT,ANDROID_WIREGUARD,DEPLOY,PASS" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Server peer and Android config were created, but Android CLI activation was skipped." -ForegroundColor Yellow
    Write-Host "Reason: Android has no wg binary at $androidWgPath and no local -AndroidWgBinary was provided." -ForegroundColor Yellow
    Write-Host "Provide an Android arm64 wg binary and rerun with -AndroidWgBinary <path>." -ForegroundColor Yellow
    Write-Host "Config on Android: $androidRemoteDir/$ClientName.conf"
    Write-Host "Local config: $localClientConf"
    Write-Host "RESULT,ANDROID_WIREGUARD,CONFIG_ONLY,PASS" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done."
