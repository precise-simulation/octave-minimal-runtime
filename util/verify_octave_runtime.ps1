[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RuntimeRoot,
    [string]$ExpectedProfile = '',
    [string]$ArchivePath = '',
    [string]$SevenZip = '7z.exe'
)

$ErrorActionPreference = 'Stop'

function Assert-RuntimeTree([string]$Root, [string]$Profile) {
    $Root = (Resolve-Path -LiteralPath $Root).Path
    $ManifestPath = Join-Path $Root 'runtime-manifest.json'
    $MingwRoot = Join-Path $Root 'mingw64'
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Runtime manifest is missing: $ManifestPath"
    }
    if (-not (Test-Path -LiteralPath $MingwRoot -PathType Container)) {
        throw "Runtime mingw64 directory is missing: $MingwRoot"
    }

    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    if ($Manifest.format_version -ne 1 -or
        $Manifest.artifact -ne 'featool-octave-runtime-win-x64' -or
        $Manifest.platform -ne 'win-x64' -or
        $Manifest.octave_version -ne '11.3.0' -or
        $Manifest.source_distribution -ne 'octave-11.3.0-w64') {
        throw "Runtime manifest identity is invalid: $ManifestPath"
    }
    if ($Profile -and $Manifest.profile -ne $Profile) {
        throw "Expected runtime profile '$Profile', got '$($Manifest.profile)'"
    }

    $ExpectedTopLevel = @('mingw64', 'runtime-manifest.json') | Sort-Object -CaseSensitive
    $ActualTopLevel = @(
        Get-ChildItem -LiteralPath $Root -Force |
            ForEach-Object { $_.Name } |
            Sort-Object -CaseSensitive
    )
    if (Compare-Object -ReferenceObject $ExpectedTopLevel -DifferenceObject $ActualTopLevel -CaseSensitive) {
        throw "Runtime root contains missing or unmanifested top-level entries: $Root"
    }

    $ManifestFiles = @($Manifest.files)
    $ActualFiles = @(
        Get-ChildItem -LiteralPath $MingwRoot -Recurse -File -Force |
            Sort-Object FullName -CaseSensitive
    )
    if ($Manifest.payload_files -ne $ActualFiles.Count -or
        $ManifestFiles.Count -ne $ActualFiles.Count) {
        throw "Runtime file count differs from the manifest: expected $($Manifest.payload_files), found $($ActualFiles.Count)"
    }

    $ExpectedPaths = @(
        $ManifestFiles |
            ForEach-Object { [string]$_.path } |
            Sort-Object -CaseSensitive
    )
    $ActualPaths = @(
        $ActualFiles |
            ForEach-Object { $_.FullName.Substring($MingwRoot.Length + 1).Replace('\', '/') } |
            Sort-Object -CaseSensitive
    )
    if (Compare-Object -ReferenceObject $ExpectedPaths -DifferenceObject $ActualPaths -CaseSensitive) {
        throw 'Runtime file set differs from runtime-manifest.json'
    }

    $PayloadBytes = [long](($ActualFiles | Measure-Object -Property Length -Sum).Sum)
    if ([long]$Manifest.payload_bytes -ne $PayloadBytes) {
        throw "Runtime payload byte count differs from the manifest: expected $($Manifest.payload_bytes), found $PayloadBytes"
    }

    foreach ($Entry in $ManifestFiles) {
        $RelativePath = [string]$Entry.path
        if ([string]::IsNullOrWhiteSpace($RelativePath) -or
            [IO.Path]::IsPathRooted($RelativePath) -or
            $RelativePath -match '(^|/)\.\.(/|$)' -or
            $RelativePath.Contains('\')) {
            throw "Unsafe path in runtime manifest: $RelativePath"
        }
        $FilePath = Join-Path $MingwRoot ($RelativePath.Replace('/', '\'))
        $File = Get-Item -LiteralPath $FilePath
        if ([long]$Entry.bytes -ne [long]$File.Length) {
            throw "Runtime file size mismatch: $RelativePath"
        }
        $Hash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Hash -ne [string]$Entry.sha256) {
            throw "Runtime file SHA-256 mismatch: $RelativePath"
        }
    }

    return [pscustomobject]@{
        Profile = [string]$Manifest.profile
        Files = [int]$ActualFiles.Count
        Bytes = $PayloadBytes
    }
}

$Runtime = Assert-RuntimeTree $RuntimeRoot $ExpectedProfile
Write-Output "runtime_tree=pass"
Write-Output "runtime_profile=$($Runtime.Profile)"
Write-Output "runtime_files=$($Runtime.Files)"
Write-Output "runtime_bytes=$($Runtime.Bytes)"

if ($ArchivePath) {
    $ArchivePath = (Resolve-Path -LiteralPath $ArchivePath).Path
    $SevenZipCommand = Get-Command -Name $SevenZip -ErrorAction Stop
    $SevenZipPath = $SevenZipCommand.Source
    if (-not $SevenZipPath) {
        $SevenZipPath = $SevenZipCommand.Definition
    }

    & $SevenZipPath t $ArchivePath
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip archive integrity test failed with exit code $LASTEXITCODE"
    }

    $TempRoot = [IO.Path]::GetTempPath()
    $ExtractRoot = Join-Path $TempRoot ('featool-octave-archive-check-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
    try {
        & $SevenZipPath x $ArchivePath "-o$ExtractRoot" -y
        if ($LASTEXITCODE -ne 0) {
            throw "7-Zip archive extraction failed with exit code $LASTEXITCODE"
        }
        $ExtractedRuntime = Assert-RuntimeTree $ExtractRoot $ExpectedProfile
        if ($ExtractedRuntime.Files -ne $Runtime.Files -or $ExtractedRuntime.Bytes -ne $Runtime.Bytes) {
            throw 'Extracted archive payload differs from the verified runtime tree'
        }
    } finally {
        Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output 'runtime_archive=pass'
}

Write-Output 'verification=pass'
