param()

$ErrorActionPreference = 'Stop'
$script:checks = 0

function Assert([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERT: $Message" }
  $script:checks++
}

$cleanupPath = Join-Path $PSScriptRoot 'cleanup-model-experience-repair-artifacts.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($cleanupPath, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'cleanup script PowerShell syntax'
Assert ($null -ne $ast) 'cleanup script AST'
$source = Get-Content -LiteralPath $cleanupPath -Raw
foreach ($required in @(
  'SupportsShouldProcess = $true',
  'if (-not $Clean)',
  'model-experience-repair-runs',
  '^\d{8}-\d{6}-[a-f0-9]{32}$',
  '.codex-model-experience-repair',
  'cwp-tmp',
  '.codex-model-experience-temp',
  'Get-RepairTreeSnapshot',
  'Assert-NoReparsePointsRecursive',
  'Get-CimInstance -ClassName Win32_Process',
  '-StrictVerifyOnly',
  '-VerifyAllBundledPluginsAvailable',
  '[IO.File]::Delete($entry)',
  '[IO.Directory]::Delete($directory, $false)',
  'sibling transcripts and config backups were retained'
)) {
  Assert ($source.Contains($required)) "cleanup guard: $required"
}
Assert (-not $source.Contains('Remove-Item -Recurse')) 'cleanup does not use recursive PowerShell deletion'

foreach ($name in @('ConvertTo-ExtendedPath', 'Assert-NoReparsePointsRecursive', 'Remove-DirectoryTreeRobust')) {
  $functionAst = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
  }, $true)
  Assert ($null -ne $functionAst) "cleanup helper exists: $name"
  . ([scriptblock]::Create($functionAst.Extent.Text))
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('repair-cleanup-test-' + [guid]::NewGuid().ToString('N'))
try {
  $nested = Join-Path $fixtureRoot 'nested'
  New-Item -ItemType Directory -Path $nested -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $fixtureRoot 'root.txt'), 'root')
  [IO.File]::WriteAllText((Join-Path $nested 'nested.txt'), 'nested')
  Remove-DirectoryTreeRobust -Path $fixtureRoot
  Assert (-not (Test-Path -LiteralPath $fixtureRoot)) 'validated cleanup removes a nested fixture'
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-DirectoryTreeRobust -Path $fixtureRoot
  }
}

Write-Output "REPAIR_ARTIFACT_CLEANUP_TESTS_PASSED checks=$script:checks"
