# VpnDeploy WireGuard

Windows CLI helper for deploying WireGuard through PuTTY `plink` and `pscp`.

## Files

- `VpnDeploy 2.exe`: integrated single-file executable.
- `deploy_wireguard_windows.ps1`: extracted PowerShell deployment script from `VpnDeploy 2.exe`.
- `VpnDeployCombined.ps1`: combined menu script with Linux and Android deploy modes.
- `VpnDeployAndroid.ps1`: Android root client deployment script used by mode 2.
- `VpnDeployCombinedSingle.cs`: source used to build the integrated single-file executable.
- `wireguard_check_start.sh`: extracted remote Linux WireGuard check/start helper.

## Current Modes

The integrated menu currently shows:

1. Deploy / redeploy WireGuard between Linux server and Linux client. This rewrites the `wg0` configuration and regenerates keys on each deployment.
2. Create server and deploy an Android root CLI WireGuard client.

The integrated executable embeds the PowerShell scripts, PuTTY `plink`/`pscp`, and the Android arm64 `wg` binary.
