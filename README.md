# VpnDeploy WireGuard

Windows CLI helper for deploying WireGuard through PuTTY `plink` and `pscp`.

## Files

- `VpnDeploy 2.exe`: integrated single-file executable.
- `deploy_wireguard_windows.ps1`: extracted PowerShell deployment script from `VpnDeploy 2.exe`.
- `VpnDeployCombined.ps1`: combined menu script with modes 1-4.
- `VpnDeployAndroid.ps1`: Android root client deployment script used by mode 4.
- `VpnDeployCombinedSingle.cs`: source used to build the integrated single-file executable.
- `wireguard_check_start.sh`: extracted remote Linux WireGuard check/start helper.

## Current Modes

The extracted PowerShell script supports:

1. Deploy / redeploy WireGuard.
2. Test an existing WireGuard connection without changing configuration.
3. Add one Linux client to an existing server without rewriting server configuration.
4. Create/update server and deploy an Android root CLI WireGuard client.

The integrated executable embeds the PowerShell scripts, PuTTY `plink`/`pscp`, and the Android arm64 `wg` binary.
