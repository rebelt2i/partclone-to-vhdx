<#
.SYNOPSIS
    Converts a Clonezilla / Partclone NTFS image into a dynamic VHDX.

.DESCRIPTION
    Uses WSL (qemu-img, qemu-nbd, sgdisk, partclone) to restore a Partclone
    NTFS image into a GPT-partitioned dynamic VHDX. Mount under Windows with
    Mount-VHD to copy files. Bootability is not a goal.

    On first run the script installs dependencies in WSL and, if needed, builds
    partclone 0.3.52 with XXH128 support (required by newer Clonezilla images).

.PARAMETER ImagePath
    Path to the Partclone image file, or to a Clonezilla folder that contains it
    (e.g. H:\backup\sda3.ntfs-ptcl-img).
    Supports uncompressed files, split parts (.aa/.ab/...), and .gz/.zst/.xz.

.PARAMETER OutputPath
    Destination VHDX path. Defaults next to the image (folder sibling when the
    input is a Clonezilla-named directory).

.PARAMETER SkipToolSetup
    Do not install/build dependencies in WSL.

.PARAMETER Mount
    After a successful restore, mount the VHDX under Windows and assign a drive
    letter (elevates via UAC if the current shell is not admin).

.EXAMPLE
    .\Convert-PartcloneToVhdx.ps1 -ImagePath 'H:\backup\sda3.ntfs-ptcl-img'

.EXAMPLE
    .\Convert-PartcloneToVhdx.ps1 -ImagePath 'H:\backup\nvme0n1p3.ntfs-ptcl-img' -OutputPath 'H:\backup\disk.vhdx' -Mount
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ImagePath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$SkipToolSetup,

    [Parameter()]
    [switch]$Mount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function ConvertTo-WslPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath,
        [switch]$MustExist
    )

    if ($MustExist) {
        $full = (Resolve-Path -LiteralPath $WindowsPath).Path
    }
    else {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WindowsPath)
    }

    $m = [regex]::Match($full, '^(?<drive>[A-Za-z]):\\(?<rest>.*)$')
    if (-not $m.Success) {
        throw "Cannot map path to WSL: $full"
    }

    $drive = $m.Groups['drive'].Value.ToLowerInvariant()
    $rest = ($m.Groups['rest'].Value -replace '\\', '/').TrimEnd('/')
    if ([string]::IsNullOrEmpty($rest)) {
        return "/mnt/$drive"
    }
    return "/mnt/$drive/$rest"
}

function Resolve-ImageInput([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Image path not found: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        $sameName = Join-Path $item.FullName $item.Name
        if (Test-Path -LiteralPath $sameName -PathType Leaf) {
            return [pscustomobject]@{
                Kind     = 'file'
                Path     = $sameName
                BaseName = $item.Name
                Folder   = $item.FullName
            }
        }

        $files = @(Get-ChildItem -LiteralPath $item.FullName -File | Sort-Object Name)
        $aa = $files | Where-Object { $_.Name -match '\.aa$' } | Select-Object -First 1
        if ($aa) {
            $prefix = $aa.FullName -replace '\.aa$', ''
            return [pscustomobject]@{
                Kind     = 'split'
                Path     = $prefix
                BaseName = $item.Name
                Folder   = $item.FullName
            }
        }

        $primary = $files | Where-Object {
            $_.Name -match 'ptcl-img' -and $_.Name -notmatch '\.(aa|ab|ac|ad|ae|af)$'
        } | Select-Object -First 1

        if (-not $primary) {
            throw "No Partclone image found inside folder: $($item.FullName)"
        }

        return [pscustomobject]@{
            Kind     = 'file'
            Path     = $primary.FullName
            BaseName = $item.Name
            Folder   = $item.FullName
        }
    }

    if ($item.Name -match '\.aa$') {
        $prefix = $item.FullName -replace '\.aa$', ''
        return [pscustomobject]@{
            Kind     = 'split'
            Path     = $prefix
            BaseName = $item.BaseName
            Folder   = $item.DirectoryName
        }
    }

    return [pscustomobject]@{
        Kind     = 'file'
        Path     = $item.FullName
        BaseName = $item.Name
        Folder   = $item.DirectoryName
    }
}

function Get-DefaultOutputPath($resolved, [string]$OriginalImagePath) {
    $clean = {
        param($name)
        ($name -replace '\.ntfs-ptcl-img$', '' `
               -replace '\.ptcl-img$', '' `
               -replace '\.gz$', '' `
               -replace '\.zst$', '' `
               -replace '\.xz$', '')
    }

    if ((Test-Path -LiteralPath $OriginalImagePath) -and
        (Get-Item -LiteralPath $OriginalImagePath).PSIsContainer) {
        $folder = (Get-Item -LiteralPath $OriginalImagePath).FullName
        $parent = Split-Path -Parent $folder
        $base = & $clean (Split-Path -Leaf $folder)
        return (Join-Path $parent "$base.vhdx")
    }

    $dir = $resolved.Folder
    $base = & $clean $resolved.BaseName
    return (Join-Path $dir "$base.vhdx")
}

# --- prerequisites ---
Write-Step "Checking prerequisites"
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "WSL is required. Install with: wsl --install"
}

$wslCheck = & wsl.exe -u root -e bash -lc "echo OK"
if ($LASTEXITCODE -ne 0 -or ($wslCheck -join '' ) -notmatch 'OK') {
    throw "Cannot run commands as root in WSL (wsl -u root). Ensure a default Linux distro is installed."
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bashScriptWin = Join-Path $scriptRoot 'wsl\restore-to-vhdx.sh'
if (-not (Test-Path -LiteralPath $bashScriptWin)) {
    throw "Missing helper script: $bashScriptWin"
}
$bashScriptWsl = ConvertTo-WslPath -WindowsPath $bashScriptWin -MustExist

$resolved = Resolve-ImageInput $ImagePath
if (-not $OutputPath) {
    $OutputPath = Get-DefaultOutputPath $resolved $ImagePath
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

if ($resolved.Kind -eq 'file') {
    $imageWsl = ConvertTo-WslPath -WindowsPath $resolved.Path -MustExist
}
else {
    $splitParent = Split-Path -Parent $resolved.Path
    $splitLeaf = Split-Path -Leaf $resolved.Path
    $imageWsl = "$(ConvertTo-WslPath -WindowsPath $splitParent -MustExist)/$splitLeaf"
}

$outputWsl = ConvertTo-WslPath -WindowsPath $OutputPath

Write-Host "Image kind : $($resolved.Kind)"
Write-Host "Image      : $($resolved.Path)"
Write-Host "Image WSL  : $imageWsl"
Write-Host "Output     : $OutputPath"
Write-Host "Output WSL : $outputWsl"

$skip = if ($SkipToolSetup) { '1' } else { '0' }

Write-Step "Running conversion inside WSL (may take a long time / use a lot of disk)"
# Normalize CRLF -> LF for bash, then execute as root.
& wsl.exe -u root -e bash -lc "sed 's/\r$//' '$bashScriptWsl' > /tmp/restore-to-vhdx.sh && chmod +x /tmp/restore-to-vhdx.sh && /tmp/restore-to-vhdx.sh '$($resolved.Kind)' '$imageWsl' '$outputWsl' '$skip'"
if ($LASTEXITCODE -ne 0) {
    throw "WSL restore failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    throw "Expected output VHDX was not created: $OutputPath"
}

$sizeGb = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1GB, 1)
Write-Host ""
Write-Host "VHDX ready: $OutputPath ($sizeGb GiB on disk)" -ForegroundColor Green

if ($Mount) {
    Write-Step "Mounting VHDX under Windows"
    $escaped = $OutputPath.Replace("'", "''")
    $mountScript = @"
`$ErrorActionPreference = 'Stop'
`$vhd = Mount-VHD -Path '$escaped' -Passthru
Start-Sleep -Seconds 2
`$disk = `$vhd | Get-Disk
`$part = `$disk | Get-Partition |
    Where-Object { `$_.Type -ne 'Reserved' -and `$_.Size -gt 1GB } |
    Select-Object -First 1
if (-not `$part) { throw 'No data partition found on VHDX' }
if (-not `$part.DriveLetter) {
    `$used = @((Get-Volume | Where-Object DriveLetter).DriveLetter)
    `$letter = (67..90 | ForEach-Object { [char]`$_ }) |
        Where-Object { `$_ -notin `$used } |
        Select-Object -First 1
    if (-not `$letter) { throw 'No free drive letter' }
    `$part | Set-Partition -NewDriveLetter `$letter
    Start-Sleep -Seconds 1
} else {
    `$letter = `$part.DriveLetter
}
`$vol = Get-Volume -DriveLetter `$letter
Write-Output "Mounted as `$(`$letter): label=`$(`$vol.FileSystemLabel) fs=`$(`$vol.FileSystem)"
"@
    $tmp = Join-Path $env:TEMP 'mount-partclone-vhdx.ps1'
    Set-Content -Path $tmp -Value $mountScript -Encoding UTF8

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
    }
    else {
        Write-Host "Elevation required for Mount-VHD — confirm the UAC prompt..."
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tmp
        )
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Mount later   (Admin): Mount-VHD -Path '$OutputPath'"
Write-Host "Unmount later (Admin): Dismount-VHD -Path '$OutputPath'"
