[CmdletBinding()]
param(
    [string]$OctaveRoot = 'C:\Program Files\GNU Octave\Octave-11.3.0',
    [string]$Destination = (Join-Path $env:TEMP 'featool-octave-runtime'),
    [string]$FeatoolRoot = '',
    [string]$PyRuntimeSource = '',
    [switch]$ValidatePackagedPyRuntime,
    [switch]$StrictIsolation,
    [switch]$GraphicsSupport,
    [switch]$Validate
)

$ErrorActionPreference = 'Stop'

$ExpectedVersion = '11.3.0'
$ArtifactName = 'featool-octave-runtime-win-x64'

$RequiredBin = @(
    'libamd.dll',
    'libarpack-2.dll',
    'libblas.dll',
    'libbz2.dll',
    'libcamd.dll',
    'libccolamd.dll',
    'libcholmod.dll',
    'libcolamd.dll',
    'libcurl-4.dll',
    'libcxsparse.dll',
    'libexpat-1.dll',
    'libfftw3-3.dll',
    'libfftw3f-3.dll',
    'libfontconfig-1.dll',
    'libfreetype-6.dll',
    'libgcc_s_seh-1.dll',
    'libgcrypt-20.dll',
    'libgfortran-5.dll',
    'libgl2ps.dll',
    'libgmp-10.dll',
    'libgnutls-30.dll',
    'libgomp-1.dll',
    'libgpg-error-0.dll',
    'libGraphicsMagick++-12.dll',
    'libGraphicsMagick-3.dll',
    'libhdf5.dll',
    'libhogweed-6.dll',
    'libiconv-2.dll',
    'libidn2-0.dll',
    'libintl-8.dll',
    'liblapack.dll',
    'liblcms2-2.dll',
    'libltdl-7.dll',
    'libnettle-8.dll',
    'liboctave-13.dll',
    'liboctinterp-15.dll',
    'liboctmex-1.dll',
    'libpcre2-8-0.dll',
    'libpng16-16.dll',
    'libqrupdate-1.dll',
    'libquadmath-0.dll',
    'libreadline8.dll',
    'libspqr.dll',
    'libssh2-1.dll',
    'libstdc++-6.dll',
    'libsuitesparseconfig.dll',
    'libtasn1-6.dll',
    'libtermcap.dll',
    'libumfpack.dll',
    'libunistring-5.dll',
    'libwinpthread-1.dll',
    'libxerbla.dll',
    'libz.dll',
    'octave-cli.exe'
)

$GraphicsBin = @(
    'icudt78.dll',
    'icuin78.dll',
    'icuuc78.dll',
    'libdouble-conversion.dll',
    'libjasper.dll',
    'libjpeg-9.dll',
    'liblzma-5.dll',
    'libmng-2.dll',
    'liboctgui-14.dll',
    'libpcre2-16-0.dll',
    'libsharpyuv-0.dll',
    'libtiff-6.dll',
    'libwebp-7.dll',
    'libwebpdemux-2.dll',
    'libwebpmux-3.dll',
    'libzstd.dll',
    'octave.exe',
    'octave-gui.exe',
    'qscintilla2_qt6.dll',
    'Qt6Core.dll',
    'Qt6Gui.dll',
    'Qt6Help.dll',
    'Qt6Network.dll',
    'Qt6OpenGL.dll',
    'Qt6OpenGLWidgets.dll',
    'Qt6PrintSupport.dll',
    'Qt6Sql.dll',
    'Qt6Svg.dll',
    'Qt6Widgets.dll'
)

$GraphicsPluginDirectories = @(
    'iconengines',
    'imageformats',
    'platforms',
    'styles'
)

if ($GraphicsSupport) {
    $RequiredBin += $GraphicsBin
}

$PrunedShareExtensions = @(
    '.cc-tst',
    '.css',
    '.html',
    '.ico',
    '.ipynb',
    '.log',
    '.ofig',
    '.qch',
    '.qhc',
    '.svg',
    '.texi',
    '.tst',
    '.txi'
)

function Get-FullPath([string]$Path) {
    $FullPath = $null
    if ([IO.Path]::IsPathRooted($Path)) {
        $FullPath = [IO.Path]::GetFullPath($Path)
    } else {
        $FullPath = [IO.Path]::GetFullPath((Join-Path (Get-Location) $Path))
    }
    $PathRoot = [IO.Path]::GetPathRoot($FullPath)
    if ($FullPath.Length -gt $PathRoot.Length) {
        $FullPath = $FullPath.TrimEnd('\')
    }
    return $FullPath
}

function Test-IsSameOrChildPath([string]$Path, [string]$Parent) {
    if ($Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Copy-Tree([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Required Octave directory is missing: $Source"
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Target -Recurse -Force
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-CheckedOctave([string]$OctaveExe, [string[]]$Arguments, [string]$Label) {
    & $OctaveExe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

$OctaveRoot = Get-FullPath (Resolve-Path -LiteralPath $OctaveRoot).Path
$Destination = Get-FullPath $Destination
$RepositoryRoot = Get-FullPath (Split-Path -Parent $PSScriptRoot)
$SourceMingw = Join-Path $OctaveRoot 'mingw64'
$SourceBin = Join-Path $SourceMingw 'bin'
$SourceOctave = Join-Path $SourceBin 'octave-cli.exe'
$RuntimeMingw = Join-Path $Destination 'mingw64'
$RuntimeBin = Join-Path $RuntimeMingw 'bin'
$RuntimeOctave = Join-Path $RuntimeBin 'octave-cli.exe'
$RuntimeGraphicsOctave = Join-Path $RuntimeBin 'octave.exe'

if ($Validate) {
    if (-not $FeatoolRoot) {
        throw "FeatoolRoot is required with -Validate"
    }
    $FeatoolRoot = Get-FullPath (Resolve-Path -LiteralPath $FeatoolRoot).Path
}

if ($PyRuntimeSource) {
    if (-not $Validate) {
        throw "PyRuntimeSource is only used with -Validate"
    }
    $PyRuntimeSource = Get-FullPath (Resolve-Path -LiteralPath $PyRuntimeSource).Path
    if (-not (Test-Path -LiteralPath (Join-Path $PyRuntimeSource 'pyruntime\backend.py') -PathType Leaf)) {
        throw "PyRuntime source backend not found: $PyRuntimeSource"
    }
}

if ($ValidatePackagedPyRuntime) {
    if (-not $Validate) {
        throw "ValidatePackagedPyRuntime is only used with -Validate"
    }
    if ($PyRuntimeSource) {
        throw "ValidatePackagedPyRuntime cannot be combined with PyRuntimeSource"
    }
}

if ($StrictIsolation -and -not $Validate) {
    throw "StrictIsolation is only used with -Validate"
}

if (-not (Test-Path -LiteralPath $SourceOctave -PathType Leaf)) {
    throw "GNU Octave CLI not found: $SourceOctave"
}
if ($Validate -and -not (Test-Path -LiteralPath (Join-Path $FeatoolRoot 'featool') -PathType Container)) {
    throw "FEATool source directory not found under FeatoolRoot: $FeatoolRoot"
}
if ($ValidatePackagedPyRuntime) {
    $PackagedPyRuntime = Join-Path $FeatoolRoot 'featool\bin\pyrt\win-x64'
    foreach ($RequiredPackagedPath in @(
        'manifest.json',
        'bridge.mex'
    )) {
        $Candidate = Join-Path $PackagedPyRuntime $RequiredPackagedPath
        if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
            throw "Packaged PyRuntime component is missing: $Candidate"
        }
    }
}
if ($Destination -eq [IO.Path]::GetPathRoot($Destination)) {
    throw "Refusing to use a filesystem root as Destination: $Destination"
}
$ProtectedRoots = @($OctaveRoot, $RepositoryRoot)
if ($FeatoolRoot) {
    $ProtectedRoots += $FeatoolRoot
}
if ($PyRuntimeSource) {
    $ProtectedRoots += $PyRuntimeSource
}
foreach ($ProtectedRoot in $ProtectedRoots) {
    if ((Test-IsSameOrChildPath $Destination $ProtectedRoot) -or
        (Test-IsSameOrChildPath $ProtectedRoot $Destination)) {
        throw "Destination and protected input/repository paths must not contain one another: $Destination and $ProtectedRoot"
    }
}

$VersionOutput = @(& $SourceOctave --quiet --no-init-all --no-window-system --eval 'disp(OCTAVE_VERSION)' 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Could not query Octave version from $SourceOctave"
}
$OctaveVersion = ($VersionOutput | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Select-Object -Last 1).Trim()
if ($OctaveVersion -ne $ExpectedVersion) {
    throw "Expected GNU Octave $ExpectedVersion, got '$OctaveVersion'"
}

foreach ($Name in $RequiredBin) {
    $Source = Join-Path $SourceBin $Name
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required Octave runtime file is missing: $Source"
    }
}

if (Test-Path -LiteralPath $Destination) {
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        throw "Destination exists but is not a directory: $Destination"
    }
    $DestinationItem = Get-Item -LiteralPath $Destination
    if (($DestinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to replace a linked/reparse-point Destination: $Destination"
    }
    $ExistingManifestPath = Join-Path $Destination 'runtime-manifest.json'
    if (-not (Test-Path -LiteralPath $ExistingManifestPath -PathType Leaf)) {
        throw "Destination already exists and is not a generated FEATool Octave runtime: $Destination"
    }
    try {
        $ExistingManifest = Get-Content -LiteralPath $ExistingManifestPath -Raw | ConvertFrom-Json
    } catch {
        throw "Destination contains an unreadable runtime manifest and will not be replaced: $ExistingManifestPath"
    }
    if ($ExistingManifest.format_version -ne 1 -or
        $ExistingManifest.artifact -ne $ArtifactName -or
        $ExistingManifest.platform -ne 'win-x64' -or
        $ExistingManifest.octave_version -ne $ExpectedVersion) {
        throw "Destination manifest does not identify a compatible generated FEATool Octave runtime: $ExistingManifestPath"
    }
    Remove-Item -LiteralPath $Destination -Recurse -Force
}
New-Item -ItemType Directory -Path $RuntimeBin -Force | Out-Null

foreach ($Name in $RequiredBin) {
    Copy-Item -LiteralPath (Join-Path $SourceBin $Name) -Destination (Join-Path $RuntimeBin $Name)
}

if ($GraphicsSupport) {
    foreach ($Directory in $GraphicsPluginDirectories) {
        Copy-Tree `
            (Join-Path $SourceMingw "qt6\plugins\$Directory") `
            (Join-Path $RuntimeMingw "qt6\plugins\$Directory")
    }

    # The stock qt.conf contains an absolute installation prefix.  Generate a
    # relocatable one so Qt resolves plugins inside this stripped runtime.
    Write-Utf8NoBom (Join-Path $RuntimeBin 'qt.conf') @'
[Paths]
Prefix=..
Plugins=qt6/plugins
'@
}

Copy-Tree (Join-Path $SourceMingw 'share\octave') (Join-Path $RuntimeMingw 'share\octave')
Copy-Tree (Join-Path $SourceMingw 'lib\octave') (Join-Path $RuntimeMingw 'lib\octave')
Copy-Tree (Join-Path $SourceMingw 'etc') (Join-Path $RuntimeMingw 'etc')
Copy-Tree (Join-Path $SourceMingw 'share\licenses') (Join-Path $RuntimeMingw 'share\licenses')

foreach ($Relative in @('share\octave\packages', 'lib\octave\packages')) {
    $Path = Join-Path $RuntimeMingw $Relative
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

Get-ChildItem -LiteralPath (Join-Path $RuntimeMingw 'lib\octave') -Recurse -File |
    Where-Object { $_.Extension -in @('.a', '.la') } |
    Remove-Item -Force

Get-ChildItem -LiteralPath (Join-Path $RuntimeMingw 'share\octave') -Recurse -File |
    Where-Object { $_.Extension -in $PrunedShareExtensions } |
    Remove-Item -Force

$PayloadFiles = @(
    Get-ChildItem -LiteralPath $RuntimeMingw -Recurse -File |
        Sort-Object FullName
)
$PayloadBytes = [long](($PayloadFiles | Measure-Object Length -Sum).Sum)
$ManifestFiles = @(
    foreach ($File in $PayloadFiles) {
        [ordered]@{
            path = $File.FullName.Substring($RuntimeMingw.Length + 1).Replace('\', '/')
            bytes = [long]$File.Length
            sha256 = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
)
$Manifest = [ordered]@{
    format_version = 1
    artifact = $ArtifactName
    profile = $(if ($GraphicsSupport) { 'featool-qt-graphics' } else { 'headless-cli-featool' })
    platform = 'win-x64'
    octave_version = $OctaveVersion
    source_distribution = 'octave-11.3.0-w64'
    native_bin_files = $RequiredBin.Count
    payload_files = $PayloadFiles.Count
    payload_bytes = $PayloadBytes
    files = $ManifestFiles
}
$ManifestPath = Join-Path $Destination 'runtime-manifest.json'
Write-Utf8NoBom $ManifestPath (($Manifest | ConvertTo-Json -Depth 5) + "`n")

Write-Output "runtime=$Destination"
Write-Output "octave=$OctaveVersion"
Write-Output "payload_files=$($PayloadFiles.Count)"
Write-Output "payload_bytes=$PayloadBytes"
Write-Output ("payload_mib={0:N1}" -f ($PayloadBytes / 1MB))
Write-Output "manifest=$ManifestPath"

if (-not $Validate) {
    return
}

$OldPath = $env:PATH
$OldOctaveHome = $env:OCTAVE_HOME
$OldOctaveExecHome = $env:OCTAVE_EXEC_HOME
$OldOctavePath = $env:OCTAVE_PATH
$OldPyRuntimeSource = $env:FEATOOL_PYRUNTIME_SOURCE
$IsolationEnvironmentNames = @(
    'PYTHONHOME',
    'PYTHONPATH',
    'TCL_LIBRARY',
    'TK_LIBRARY',
    'MEX_BRIDGE_BACKEND_PATH',
    'MEX_BRIDGE_BACKEND_MODULE',
    'MEX_BRIDGE_BACKEND_ENTRY',
    'MEX_BRIDGE_CALLBACK_ALLOWLIST'
)
$OldIsolationEnvironment = @{}
foreach ($Name in $IsolationEnvironmentNames) {
    $OldIsolationEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
}
$ProbeDir = Join-Path $env:TEMP ('featool-octave-runtime-probe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ProbeDir -Force | Out-Null

try {
    $CleanPathEntries = @()
    $RemovedPathEntries = 0
    foreach ($Entry in ($OldPath -split ';')) {
        if (-not $Entry) {
            continue
        }
        $Candidate = $Entry.Trim().Trim('"')
        $IsOctavePath = $Candidate -match '(?i)(?:^|\\)GNU Octave\\Octave-[^\\]+(?:\\|$)'
        if (-not $IsOctavePath -and [IO.Path]::IsPathRooted($Candidate)) {
            $CandidateFullPath = Get-FullPath $Candidate
            $IsOctavePath = Test-IsSameOrChildPath $CandidateFullPath $OctaveRoot
        }
        if ($IsOctavePath) {
            $RemovedPathEntries++
        } else {
            $CleanPathEntries += $Entry
        }
    }
    $CleanPath = $CleanPathEntries -join ';'
    if ($StrictIsolation) {
        $SystemRoot = [Environment]::GetEnvironmentVariable('SystemRoot', 'Process')
        if (-not $SystemRoot) {
            throw 'SystemRoot is unavailable for strict runtime isolation'
        }
        $SystemPath = @(
            (Join-Path $SystemRoot 'System32'),
            $SystemRoot,
            (Join-Path $SystemRoot 'System32\Wbem')
        ) -join ';'
        $env:PATH = "$RuntimeBin;$SystemPath"
        foreach ($Name in $IsolationEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($Name, $null, 'Process')
        }
        Remove-Item Env:FEATOOL_PYRUNTIME_SOURCE -ErrorAction SilentlyContinue
    } else {
        $env:PATH = "$RuntimeBin;$CleanPath"
    }
    $env:OCTAVE_HOME = $RuntimeMingw
    $env:OCTAVE_EXEC_HOME = $RuntimeMingw
    Remove-Item Env:OCTAVE_PATH -ErrorAction SilentlyContinue

    Invoke-CheckedOctave $RuntimeOctave @(
        '--quiet', '--no-init-all', '--no-window-system',
        (Join-Path $FeatoolRoot 'test\test_smoke.m')
    ) 'FEATool smoke test'

    $RepoForOctave = $FeatoolRoot.Replace('\', '/').Replace("'", "''")
    foreach ($Selector in @(
        'testModelsAndExamples:test_ex_poisson1',
        'testSolvPoisson1',
        'testAssemblea',
        'testSolver:test_solvetime_BE_diffusion2',
        'testSolver:test_solvestat_newton_partial_solcomp'
    )) {
        $Eval = "cd('$RepoForOctave'); addpath(pwd); [ok,r]=test_runner('select','$Selector'); if ~ok, exit(1); end"
        Invoke-CheckedOctave $RuntimeOctave @(
            '--quiet', '--no-init-all', '--no-window-system', '--eval', $Eval
        ) "FEATool $Selector"
    }

    if ($GraphicsSupport) {
        $GraphicsEval = @"
assert(any(strcmp(available_graphics_toolkits(),'qt')));
graphics_toolkit('qt');
f=figure('visible','on','name','FEATool graphics validation');
plot([0 1 2],[0 1 0]); title('FEATool plot validation'); drawnow();
h=waitbar(0,'FEATool waitbar validation','createcancelbtn','set(gcbf,''userdata'',1)');
waitbar(0.5,h,'Halfway'); drawnow();
assert(strcmp(graphics_toolkit(),'qt'));
assert(ishghandle(f)); assert(ishghandle(h));
close(h); close(f);
disp('QT_GRAPHICS_WAITBAR_PROBE=pass');
exit(0);
"@
        Invoke-CheckedOctave $RuntimeGraphicsOctave @(
            '--no-gui', '--quiet', '--no-init-all', '--eval', $GraphicsEval
        ) 'Octave Qt plot/waitbar probe'

        $FeatoolGraphicsEval = @"
root='$RepoForOctave';
addpath(genpath(fullfile(root,'featool')));
grid2=rectgrid(2,2);
u2=grid2.p(1,:)+grid2.p(2,:);
h=postplot(grid2,u2,'surfexpr','u','isoexpr','u','arrowexpr',{'1','0'});
assert(~isempty(h)); drawnow(); close all;
disp('FEATOOL_POSTPLOT_2D=pass');
grid2=rectgrid(2,2);
h=plotgrid(grid2,'nodelabels',1,'cellabels',1);
assert(~isempty(h)); drawnow(); close all;
disp('FEATOOL_PLOTGRID_LABELS=pass');
grid3=blockgrid(1,1,1);
u3=sum(grid3.p,1);
h=postplot(grid3,u3,'sliceexpr','u','slicex',0.5,'slicey',0.5,'slicez',0.5);
assert(~isempty(h)); drawnow(); close all;
disp('FEATOOL_POSTPLOT_3D_SLICE=pass');
h=postplot(grid3,u3,'surfexpr','u','selexpr','x<0.75');
assert(~isempty(h)); drawnow(); close all;
disp('FEATOOL_POSTPLOT_3D_SURFACE=pass');
h=gui_Waitbar(0.1,[],'FEATool waitbar validation');
assert(ishghandle(h));
gui_Waitbar(0.5,h,'Halfway'); drawnow();
gui_Waitbar(1.0,h,'Done',-1); drawnow();
assert(~ishghandle(h)); close all;
disp('FEATOOL_GUI_WAITBAR=pass');
disp('FEATOOL_PRODUCTION_GRAPHICS=pass');
exit(0);
"@
        Invoke-CheckedOctave $RuntimeGraphicsOctave @(
            '--no-gui', '--quiet', '--no-init-all', '--eval', $FeatoolGraphicsEval
        ) 'FEATool production graphics probe'
    }

    $MexSource = Join-Path $ProbeDir 'octave_runtime_mex_probe.c'
    $MexOutput = Join-Path $ProbeDir 'octave_runtime_mex_probe.mex'
    Write-Utf8NoBom $MexSource @'
#include "mex.h"
void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
  double x = nrhs ? mxGetScalar(prhs[0]) : 0.0;
  if (nlhs) plhs[0] = mxCreateDoubleScalar(x + 1.0);
}
'@

    $Mkoctfile = Join-Path $SourceBin 'mkoctfile.exe'
    if (-not (Test-Path -LiteralPath $Mkoctfile -PathType Leaf)) {
        throw "MEX validation requires the source development tool: $Mkoctfile"
    }
    $BuildPath = $env:PATH
    $BuildOctaveHome = $env:OCTAVE_HOME
    $BuildOctaveExecHome = $env:OCTAVE_EXEC_HOME
    try {
        $env:PATH = "$SourceBin;$BuildPath"
        $env:OCTAVE_HOME = $SourceMingw
        $env:OCTAVE_EXEC_HOME = $SourceMingw
        & $Mkoctfile --mex $MexSource -o $MexOutput
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $MexOutput -PathType Leaf)) {
            throw "Could not compile Octave MEX validation probe"
        }
    } finally {
        $env:PATH = $BuildPath
        $env:OCTAVE_HOME = $BuildOctaveHome
        $env:OCTAVE_EXEC_HOME = $BuildOctaveExecHome
    }

    $ProbeForOctave = $ProbeDir.Replace('\', '/').Replace("'", "''")
    $MexEval = "addpath('$ProbeForOctave'); y=octave_runtime_mex_probe(41); assert(y==42); disp('MEX_RUNTIME_PROBE=pass')"
    Invoke-CheckedOctave $RuntimeOctave @(
        '--quiet', '--no-init-all', '--no-window-system', '--eval', $MexEval
    ) 'Octave MEX runtime probe'

    if ($PyRuntimeSource -or $ValidatePackagedPyRuntime) {
        if ($PyRuntimeSource) {
            $env:FEATOOL_PYRUNTIME_SOURCE = $PyRuntimeSource
        } else {
            Remove-Item Env:FEATOOL_PYRUNTIME_SOURCE -ErrorAction SilentlyContinue
        }
        $FeatoolForOctave = (Join-Path $FeatoolRoot 'featool').Replace('\', '/').Replace("'", "''")
        $BridgeSetup = "root='$FeatoolForOctave'; addpath(root,fullfile(root,'app'),fullfile(root,'core'),fullfile(root,'ellib'),fullfile(root,'grid'),fullfile(root,'gui'),fullfile(root,'physmodes'),fullfile(root,'python'),fullfile(root,'post'),fullfile(root,'util')); app_config('python',1);"
        if ($ValidatePackagedPyRuntime) {
            $ExpectedRuntimeForOctave = $PackagedPyRuntime.Replace('\', '/').Replace("'", "''")
            $BridgeSetup += " info=pyengine('runtime'); assert(info.available); assert(strcmpi(strrep(info.path,'\','/'),'$ExpectedRuntimeForOctave'));"
        }

        Invoke-CheckedOctave $RuntimeOctave @(
            '--quiet', '--no-init-all', '--no-window-system', '--eval',
            ($BridgeSetup + " assert(pyengine('start',false)); assert(pyengine('check')); disp('PYENGINE_HEADLESS=pass')")
        ) 'FEATool Python bridge headless probe'

        Invoke-CheckedOctave $RuntimeOctave @(
            '--quiet', '--no-init-all', '--no-window-system', '--eval',
            ($BridgeSetup + " assert(pyengine('start',true)); assert(pyengine('check')); disp('PYENGINE_TK=pass')")
        ) 'FEATool Python bridge Tk probe'
    }

    Write-Output 'validation=pass'
    Write-Output "validation_octave_path_entries_removed=$RemovedPathEntries"
    Write-Output ("validation_path_mode=" + $(if ($StrictIsolation) { 'strict' } else { 'ambient-non-octave' }))
    if ($ValidatePackagedPyRuntime) {
        Write-Output 'validation_pyruntime=packaged'
    } elseif ($PyRuntimeSource) {
        Write-Output 'validation_pyruntime=source-override'
    }
} finally {
    $env:PATH = $OldPath
    if ($null -eq $OldOctaveHome) {
        Remove-Item Env:OCTAVE_HOME -ErrorAction SilentlyContinue
    } else {
        $env:OCTAVE_HOME = $OldOctaveHome
    }
    if ($null -eq $OldOctaveExecHome) {
        Remove-Item Env:OCTAVE_EXEC_HOME -ErrorAction SilentlyContinue
    } else {
        $env:OCTAVE_EXEC_HOME = $OldOctaveExecHome
    }
    if ($null -eq $OldOctavePath) {
        Remove-Item Env:OCTAVE_PATH -ErrorAction SilentlyContinue
    } else {
        $env:OCTAVE_PATH = $OldOctavePath
    }
    if ($null -eq $OldPyRuntimeSource) {
        Remove-Item Env:FEATOOL_PYRUNTIME_SOURCE -ErrorAction SilentlyContinue
    } else {
        $env:FEATOOL_PYRUNTIME_SOURCE = $OldPyRuntimeSource
    }
    foreach ($Name in $IsolationEnvironmentNames) {
        [Environment]::SetEnvironmentVariable($Name, $OldIsolationEnvironment[$Name], 'Process')
    }
    Remove-Item -LiteralPath $ProbeDir -Recurse -Force -ErrorAction SilentlyContinue
}
