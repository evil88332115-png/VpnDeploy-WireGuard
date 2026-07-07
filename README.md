# VpnDeploy WireGuard

Windows CLI helper for deploying WireGuard through PuTTY `plink` and `pscp`.

## Files

- `VpnDeploy 2.exe`: original .NET wrapper executable.
- `deploy_wireguard_windows.ps1`: extracted PowerShell deployment script from `VpnDeploy 2.exe`.
- `wireguard_check_start.sh`: extracted remote Linux WireGuard check/start helper.

## Current Modes

The extracted PowerShell script supports:

1. Deploy / redeploy WireGuard.
2. Test an existing WireGuard connection without changing configuration.
3. Add one Linux client to an existing server without rewriting server configuration.

Android root client support is not included in this extracted original version.
