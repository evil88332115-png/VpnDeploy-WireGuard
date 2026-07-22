# VpnDeploy WireGuard

Windows GUI helper for deploying WireGuard through embedded PuTTY `plink` and `pscp`.

## Files

- `VpnDeploy 2.exe`: integrated single-file GUI executable.
- `VpnDeployGui.cs`: Windows Forms GUI source.
- `Build-Gui.ps1`: reproducible GUI build script.
- `deploy_wireguard_windows.ps1`: extracted PowerShell deployment script from `VpnDeploy 2.exe`.
- `VpnDeployCombined.ps1`: combined menu script with Linux and Android deploy modes.
- `VpnDeployAndroid.ps1`: Android root client deployment script used by mode 2.
- `VpnDeployCombinedSingle.cs`: source used to build the integrated single-file executable.
- `wireguard_check_start.sh`: extracted remote Linux WireGuard check/start helper.

## GUI

The main window provides two buttons:

1. Linux Server + Linux Client. This rewrites the `wg0` configuration and regenerates keys on each deployment.
2. Linux Server + Android Root Client.

After selecting a mode, all SSH and WireGuard fields are entered in one dialog. Existing defaults such as users, passwords, VPN network, and ports are filled automatically; device IP addresses remain blank to prevent deploying to the wrong host. The lower log panel shows live output and the final PASS/FAIL result, and the application remains open after each deployment.

New or changed SSH host keys display their fingerprint and require explicit confirmation.

On Linux hosts without a WireGuard kernel module, deployment installs and verifies `wireguard-go` and uses `/dev/net/tun` as the userspace backend. It no longer silently continues without a usable backend.

## Build

Run in Windows PowerShell:

```powershell
.\Build-Gui.ps1
```

The integrated executable embeds the PowerShell scripts, PuTTY `plink`/`pscp`, and the Android arm64 `wg` binary.
