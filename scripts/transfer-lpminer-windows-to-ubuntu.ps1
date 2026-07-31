[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Target,

    [int]$Port = 22,
    [string]$Label = $env:COMPUTERNAME,
    [int]$ShmGiB = 6,
    [switch]$Replace,
    [string]$RemoteDir,
    [string]$IdentityFile
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    throw "[lpminer-win-transfer] ERROR: $Message"
}

function Invoke-Native([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        Fail "$Program failed with exit code $LASTEXITCODE"
    }
}

function To-SftpPath([string]$Path) {
    return ($Path -replace '\\', '/')
}

function Quote-Sftp([string]$Value) {
    return '"' + ($Value -replace '"', '\"') + '"'
}

if ($Port -lt 1 -or $Port -gt 65535) { Fail 'Port must be between 1 and 65535' }
if ($ShmGiB -lt 4) { Fail 'ShmGiB must be at least 4' }
if ([string]::IsNullOrWhiteSpace($Label) -or $Label -notmatch '^[A-Za-z0-9_.-]{1,64}$') {
    Fail 'Label must match [A-Za-z0-9_.-] and be at most 64 characters'
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) { Fail 'Windows OpenSSH client (ssh) is not installed' }
if (-not (Get-Command sftp -ErrorAction SilentlyContinue)) { Fail 'Windows OpenSSH client (sftp) is not installed' }

$sourceItem = Get-Item -LiteralPath $Source -ErrorAction Stop
if (-not $sourceItem.PSIsContainer -and -not $sourceItem.Name.EndsWith('.tar.gz', [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail 'Source file must be a .tar.gz archive; folders are also supported'
}

$scriptDir = Split-Path -Parent $PSCommandPath
$installer = Join-Path $scriptDir 'install-lpminer-bundle-ubuntu.sh'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { Fail "Installer is missing: $installer" }

if ([string]::IsNullOrWhiteSpace($RemoteDir)) {
    $safeName = $sourceItem.Name -replace '[^A-Za-z0-9_.-]', '-'
    $RemoteDir = "/tmp/lpminer-win-bundle-$safeName"
}
if ($RemoteDir -notmatch '^/tmp/[A-Za-z0-9_.-]+$') { Fail 'RemoteDir must be a simple path below /tmp' }

$sshCommon = @('-p', "$Port")
$sftpCommon = @('-P', "$Port")
if (-not [string]::IsNullOrWhiteSpace($IdentityFile)) {
    if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) { Fail "IdentityFile is missing: $IdentityFile" }
    $sshCommon += @('-i', $IdentityFile)
    $sftpCommon += @('-i', $IdentityFile)
}

Invoke-Native 'ssh' ($sshCommon + @($Target, "mkdir -p '$RemoteDir'"))
Write-Host "[lpminer-win-transfer] remote resume directory: $RemoteDir"

$batchFile = Join-Path ([System.IO.Path]::GetTempPath()) ("lpminer-sftp-" + [guid]::NewGuid().ToString('N') + '.txt')
try {
    $batch = New-Object System.Collections.Generic.List[string]
    if ($sourceItem.PSIsContainer) {
        $remoteBundle = "$RemoteDir/bundle"
        $remoteDirectories = New-Object System.Collections.Generic.List[string]
        $remoteDirectories.Add($remoteBundle)
        $directories = Get-ChildItem -LiteralPath $sourceItem.FullName -Directory -Recurse | Sort-Object { $_.FullName.Length }
        foreach ($directory in $directories) {
            $relative = $directory.FullName.Substring($sourceItem.FullName.Length).TrimStart('\', '/')
            $remotePath = "$remoteBundle/" + (To-SftpPath $relative)
            $remoteDirectories.Add($remotePath)
        }
        $remoteMkdir = 'mkdir -p ' + (($remoteDirectories | ForEach-Object { "'$_'" }) -join ' ')
        Invoke-Native 'ssh' ($sshCommon + @($Target, $remoteMkdir))
        $files = Get-ChildItem -LiteralPath $sourceItem.FullName -File -Recurse | Sort-Object FullName
        if ($files.Count -eq 0) { Fail 'Source folder is empty' }
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($sourceItem.FullName.Length).TrimStart('\', '/')
            $remotePath = "$remoteBundle/" + (To-SftpPath $relative)
            $batch.Add("put -a " + (Quote-Sftp (To-SftpPath $file.FullName)) + " $remotePath")
        }
        $remoteBundleArgument = $remoteBundle
    }
    else {
        $remoteArchive = "$RemoteDir/bundle.tar.gz"
        $batch.Add("put -a " + (Quote-Sftp (To-SftpPath $sourceItem.FullName)) + " $remoteArchive")
        $remoteBundleArgument = $remoteArchive
    }
    $batch.Add("put " + (Quote-Sftp (To-SftpPath $installer)) + " $RemoteDir/install-lpminer-bundle-ubuntu.sh")
    [System.IO.File]::WriteAllLines($batchFile, $batch, [System.Text.UTF8Encoding]::new($false))

    Write-Host "[lpminer-win-transfer] uploading with resumable SFTP put -a..."
    Invoke-Native 'sftp' ($sftpCommon + @('-b', $batchFile, $Target))
}
finally {
    Remove-Item -LiteralPath $batchFile -Force -ErrorAction SilentlyContinue
}

$remoteInstaller = "$RemoteDir/install-lpminer-bundle-ubuntu.sh"
$remoteCommand = "bash '$remoteInstaller' --bundle '$remoteBundleArgument' --label '$Label' --shm-gib '$ShmGiB' --replace-repo"
if ($Replace) { $remoteCommand += ' --replace --replace-cache' }
Invoke-Native 'ssh' ($sshCommon + @($Target, $remoteCommand))
Write-Host "[lpminer-win-transfer] complete. Remote bundle: $RemoteDir"
