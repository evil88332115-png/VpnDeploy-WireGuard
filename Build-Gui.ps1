param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "VpnDeploy 2.exe")
)

$ErrorActionPreference = "Stop"
$source = Join-Path $PSScriptRoot "VpnDeployCombinedSingle.cs"
$guiSource = Join-Path $PSScriptRoot "VpnDeployGui.cs"
$work = Join-Path $env:TEMP ("VpnDeployGuiBuild-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null

function Export-EmbeddedArray {
    param([string]$Name, [string]$Destination)
    $text = Get-Content -LiteralPath $source -Raw
    $pattern = 'static readonly string\[\]\s+' + [regex]::Escape($Name) + '\s*=\s*new string\[\]\s*\{(?<body>.*?)\};'
    $match = [regex]::Match($text, $pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw "Embedded array not found: $Name" }
    $chunks = [regex]::Matches($match.Groups['body'].Value, '@"(?<data>[^"]*)"') | ForEach-Object { $_.Groups['data'].Value }
    if ($chunks.Count -eq 0) { throw "Embedded array is empty: $Name" }
    [IO.File]::WriteAllBytes($Destination, [Convert]::FromBase64String(($chunks -join '')))
}

try {
    Export-EmbeddedArray "WgB64" (Join-Path $work "wg-arm64")
    Export-EmbeddedArray "PlinkB64" (Join-Path $work "plink.exe")
    Export-EmbeddedArray "PscpB64" (Join-Path $work "pscp.exe")

    $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    if (-not (Test-Path -LiteralPath $csc)) { throw "C# compiler not found: $csc" }
    $temporaryOutput = Join-Path $work "VpnDeploy 2.exe"
    $resources = @(
        "/resource:$PSScriptRoot\VpnDeployCombined.ps1,VpnDeployCombined.ps1",
        "/resource:$PSScriptRoot\VpnDeployAndroid.ps1,VpnDeployAndroid.ps1",
        "/resource:$PSScriptRoot\wireguard_check_start.sh,wireguard_check_start.sh",
        "/resource:$work\plink.exe,plink.exe",
        "/resource:$work\pscp.exe,pscp.exe",
        "/resource:$work\wg-arm64,wg-arm64"
    )
    & $csc /nologo /target:winexe /optimize+ "/out:$temporaryOutput" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll @resources $guiSource
    if ($LASTEXITCODE -ne 0) { throw "C# build failed with exit code $LASTEXITCODE" }
    Copy-Item -LiteralPath $temporaryOutput -Destination $OutputPath -Force
    Get-Item -LiteralPath $OutputPath
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
