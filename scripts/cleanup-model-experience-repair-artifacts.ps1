[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [switch]$Clean,
  [string]$DataRoot = 'D:\CodexData\codex-windows-fast-patch'
)

$ErrorActionPreference = 'Stop'
$repairRunsName = 'model-experience-repair-runs'
$repairTempName = 'cwp-tmp'
$verifyScript = Join-Path $PSScriptRoot 'install-computer-use-local.ps1'

function Assert-LocalDirectoryPath {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  if (-not $fullPath.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Repair data must remain on D:\: $fullPath"
  }
  if ([IO.DriveInfo]::new('D:\').DriveType -ne [IO.DriveType]::Fixed) {
    throw 'D: is not a fixed local drive.'
  }
  $current = 'D:\'
  foreach ($part in $fullPath.Substring(3).Split('\')) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $current = Join-Path $current $part
    if (-not (Test-Path -LiteralPath $current)) {
      throw "Repair data path does not exist: $current"
    }
    $item = Get-Item -LiteralPath $current -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "Repair data path is not a normal local directory: $current"
    }
  }
  return $fullPath
}

function ConvertTo-ExtendedPath {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  if ($fullPath.StartsWith('\\?\')) { return $fullPath }
  if ($fullPath.StartsWith('\\')) { return '\\?\UNC\' + $fullPath.Substring(2) }
  return '\\?\' + $fullPath
}

function Assert-NoReparsePointsRecursive {
  param([string]$Path)
  $pending = [Collections.Generic.Stack[string]]::new()
  $pending.Push((ConvertTo-ExtendedPath $Path))
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    try {
      $attributes = [IO.File]::GetAttributes($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
    if (-not ($attributes -band [IO.FileAttributes]::Directory)) {
      throw "Cleanup scan encountered a non-directory: $directory"
    }
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Cleanup found a reparse point; artifacts were retained: $directory"
    }
    try {
      $entries = [IO.Directory]::GetFileSystemEntries($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
    foreach ($entry in $entries) {
      try {
        $entryAttributes = [IO.File]::GetAttributes($entry)
      } catch [IO.DirectoryNotFoundException] {
        continue
      } catch [IO.FileNotFoundException] {
        continue
      }
      if ($entryAttributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Cleanup found a reparse point; artifacts were retained: $entry"
      }
      if ($entryAttributes -band [IO.FileAttributes]::Directory) {
        $pending.Push($entry)
      }
    }
  }
}

function Get-RepairTreeSnapshot {
  param([string]$Path)
  Assert-NoReparsePointsRecursive -Path $Path
  $pending = [Collections.Generic.Stack[string]]::new()
  $pending.Push((ConvertTo-ExtendedPath $Path))
  [long]$fileCount = 0
  [long]$directoryCount = 0
  [long]$bytes = 0
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    try {
      $entries = [IO.Directory]::GetFileSystemEntries($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    }
    foreach ($entry in $entries) {
      try {
        $attributes = [IO.File]::GetAttributes($entry)
      } catch [IO.DirectoryNotFoundException] {
        continue
      } catch [IO.FileNotFoundException] {
        continue
      }
      if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Cleanup found a reparse point; artifacts were retained: $entry"
      }
      if ($attributes -band [IO.FileAttributes]::Directory) {
        $directoryCount++
        $pending.Push($entry)
      } else {
        $fileCount++
        $bytes += ([IO.FileInfo]::new($entry)).Length
      }
    }
  }
  return [pscustomobject]@{ Files = $fileCount; Directories = $directoryCount; Bytes = $bytes }
}

function Remove-DirectoryTreeRobust {
  param([string]$Path)
  $fullPath = [IO.Path]::GetFullPath($Path)
  $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Cleanup target is not an ordinary directory: $fullPath"
  }
  Assert-NoReparsePointsRecursive -Path $fullPath
  $rootPath = ConvertTo-ExtendedPath $fullPath
  $pending = [Collections.Generic.Stack[string]]::new()
  $directories = [Collections.Generic.List[string]]::new()
  $pending.Push($rootPath)
  while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    try {
      $attributes = [IO.File]::GetAttributes($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
    if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Cleanup found a reparse point; artifacts were retained: $directory"
    }
    if (-not ($attributes -band [IO.FileAttributes]::Directory)) {
      throw "Cleanup encountered a non-directory: $directory"
    }
    $directories.Add($directory)
    try {
      $entries = [IO.Directory]::GetFileSystemEntries($directory)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
    foreach ($entry in $entries) {
      try {
        $entryAttributes = [IO.File]::GetAttributes($entry)
      } catch [IO.DirectoryNotFoundException] {
        continue
      } catch [IO.FileNotFoundException] {
        continue
      }
      if ($entryAttributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Cleanup found a reparse point; artifacts were retained: $entry"
      }
      if ($entryAttributes -band [IO.FileAttributes]::Directory) {
        $pending.Push($entry)
      } else {
        try {
          [IO.File]::SetAttributes($entry, [IO.FileAttributes]::Normal)
          [IO.File]::Delete($entry)
        } catch [IO.DirectoryNotFoundException] {
          continue
        } catch [IO.FileNotFoundException] {
          continue
        }
      }
    }
  }
  for ($index = $directories.Count - 1; $index -ge 0; $index--) {
    $directory = $directories[$index]
    try {
      [IO.File]::SetAttributes($directory, [IO.FileAttributes]::Directory)
      [IO.Directory]::Delete($directory, $false)
    } catch [IO.DirectoryNotFoundException] {
      continue
    } catch [IO.FileNotFoundException] {
      continue
    }
  }
  if (Test-Path -LiteralPath $fullPath) {
    throw "Cleanup did not remove: $fullPath"
  }
}

function Test-ActiveRepairProcess {
  param([string]$Path)
  $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
  foreach ($process in $processes) {
    if ($process.ProcessId -eq $PID -or [string]::IsNullOrWhiteSpace($process.CommandLine)) { continue }
    if ($process.CommandLine.IndexOf($Path, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
      return $process
    }
  }
  return $null
}

$dataRootFull = Assert-LocalDirectoryPath -Path $DataRoot
$runsRoot = Join-Path $dataRootFull $repairRunsName
if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) {
  Write-Output "No repair run directory exists: $runsRoot"
  exit 0
}
$runsRootFull = Assert-LocalDirectoryPath -Path $runsRoot
$cutoff = (Get-Date).AddHours(-24)
$candidates = @()
foreach ($directory in Get-ChildItem -LiteralPath $runsRootFull -Directory -Force) {
  if ($directory.Name -notmatch '^\d{8}-\d{6}-[a-f0-9]{32}$') { continue }
  if ($directory.LastWriteTime -ge $cutoff) { continue }
  if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Repair output is a reparse point: $($directory.FullName)"
  }
  $fullPath = [IO.Path]::GetFullPath($directory.FullName)
  if ((Split-Path -Parent $fullPath) -ine $runsRootFull.TrimEnd('\')) {
    throw "Repair output is not a direct child of the run root: $fullPath"
  }
  $sentinel = Join-Path $fullPath '.codex-model-experience-repair'
  if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) { continue }
  $sentinelItem = Get-Item -LiteralPath $sentinel -Force
  if ($sentinelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Repair output ownership marker is a reparse point: $sentinel"
  }
  $sentinelId = [IO.File]::ReadAllText($sentinel).Trim()
  if ($sentinelId -notmatch '^[a-f0-9]{32}$') { continue }
  $snapshot = Get-RepairTreeSnapshot -Path $fullPath
  $candidates += [pscustomobject]@{
    Path = $fullPath
    SentinelId = $sentinelId
    SentinelName = '.codex-model-experience-repair'
    LastWriteTime = $directory.LastWriteTime
    Snapshot = $snapshot
  }
}

$repairTempRoot = Join-Path (Split-Path -Parent $dataRootFull) $repairTempName
if (Test-Path -LiteralPath $repairTempRoot -PathType Container) {
  $repairTempRootFull = Assert-LocalDirectoryPath -Path $repairTempRoot
  foreach ($directory in Get-ChildItem -LiteralPath $repairTempRootFull -Directory -Force) {
    if ($directory.Name -notmatch '^r-[a-f0-9]{12}$' -or $directory.LastWriteTime -ge $cutoff) { continue }
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Repair temp workspace is a reparse point: $($directory.FullName)"
    }
    $fullPath = [IO.Path]::GetFullPath($directory.FullName)
    if ((Split-Path -Parent $fullPath) -ine $repairTempRootFull.TrimEnd('\')) {
      throw "Repair temp workspace is not a direct child of its root: $fullPath"
    }
    $sentinel = Join-Path $fullPath '.codex-model-experience-temp'
    if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) { continue }
    $sentinelItem = Get-Item -LiteralPath $sentinel -Force
    if ($sentinelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw "Repair temp ownership marker is a reparse point: $sentinel"
    }
    $sentinelId = [IO.File]::ReadAllText($sentinel).Trim()
    if ($sentinelId -notmatch '^[a-f0-9]{32}$') { continue }
    $snapshot = Get-RepairTreeSnapshot -Path $fullPath
    $candidates += [pscustomobject]@{
      Path = $fullPath
      SentinelId = $sentinelId
      SentinelName = '.codex-model-experience-temp'
      LastWriteTime = $directory.LastWriteTime
      Snapshot = $snapshot
    }
  }
}

if ($candidates.Count -eq 0) {
  Write-Output 'No marked repair runs older than 24 hours are eligible for cleanup.'
  exit 0
}
foreach ($candidate in $candidates) {
  Write-Output ('Candidate: {0} size={1:N2} GiB files={2} modified={3:yyyy-MM-dd HH:mm:ss}' -f $candidate.Path, ($candidate.Snapshot.Bytes / 1GB), $candidate.Snapshot.Files, $candidate.LastWriteTime)
}

if (-not $Clean) {
  Write-Output 'Dry run only. Pass -Clean to remove eligible run directories.'
  exit 0
}

$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $verifyScript -PathType Leaf) -or -not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
  throw 'Strict verification prerequisites are missing; repair artifacts were retained.'
}
$freeBefore = [IO.DriveInfo]::new('D:\').AvailableFreeSpace
$verifyArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifyScript, '-StrictVerifyOnly', '-VerifyAllBundledPluginsAvailable')
$verifyOutput = @(& $powershellExe @verifyArguments 2>&1)
$verifyExitCode = $LASTEXITCODE
foreach ($line in $verifyOutput) { Write-Host ([string]$line) }
if ($verifyExitCode -ne 0) {
  throw "Strict installed-package verification failed with exit code $verifyExitCode; repair artifacts were retained."
}

foreach ($candidate in $candidates) {
  $activeProcess = Test-ActiveRepairProcess -Path $candidate.Path
  if ($activeProcess) {
    throw "An active process references this repair run; artifacts were retained: pid=$($activeProcess.ProcessId) path=$($candidate.Path)"
  }
  $currentSentinel = Join-Path $candidate.Path $candidate.SentinelName
  if ([IO.File]::ReadAllText($currentSentinel).Trim() -cne $candidate.SentinelId) {
    throw "Repair output ownership marker changed; artifacts were retained: $($candidate.Path)"
  }
  if ($PSCmdlet.ShouldProcess($candidate.Path, 'Remove verified obsolete Codex repair build')) {
    Remove-DirectoryTreeRobust -Path $candidate.Path
  }
}

$remaining = @($candidates | Where-Object { Test-Path -LiteralPath $_.Path })
if ($remaining.Count -gt 0) {
  Write-Output ('Cleanup not applied to: ' + (($remaining | ForEach-Object { $_.Path }) -join ', '))
  exit 0
}
$freeAfter = [IO.DriveInfo]::new('D:\').AvailableFreeSpace
$spaceChange = ($freeAfter - $freeBefore) / 1GB
Write-Output ('CLEANUP_PASSED directories={0} released={1:N2} GiB; sibling transcripts and config backups were retained.' -f $candidates.Count, $spaceChange)
