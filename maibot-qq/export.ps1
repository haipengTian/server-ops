param(
    [string]$InstanceRoot = 'E:\workspace\personal\ai\maibot-qq',
    [string]$SnowLumaRoot = 'E:\workspace\personal\code\qq-bot-ui\.runtime\bot\snowluma',
    [string]$BaseCompose = 'E:\workspace\personal\code\qq-bot-ui\compose.bot.yaml',
    [string]$OutputDirectory = 'E:\workspace\personal\ai\maibot-qq\migration',
    [switch]$Cutover
)
$ErrorActionPreference = 'Stop'
$runtime = Join-Path $InstanceRoot 'runtime'
$python = Join-Path $InstanceRoot 'app\.venv\Scripts\python.exe'
if (!(Test-Path -LiteralPath $python)) { throw 'Cannot find the existing MaiBot Python runtime.' }
if ($Cutover) {
    $stateFile = Join-Path $runtime 'data\plugins\haipengtian.nuonuo-photo\state.json'
    if (Test-Path -LiteralPath $stateFile) {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($state.job.status -eq 'running') { throw 'Wait for the current paid image generation to finish.' }
    }
    $processes = @(Get-CimInstance Win32_Process)
    $launchers = @($processes | Where-Object {
        $_.Name -eq 'maibot.exe' -and $_.CommandLine -and $_.CommandLine.Contains($runtime)
    })
    if ($launchers.Count -gt 1) { throw 'Multiple instance launchers found; inspect before stopping.' }
    & docker compose -f $BaseCompose -f (Join-Path $InstanceRoot 'compose.snowluma.yaml') stop snowluma
    if ($LASTEXITCODE -ne 0) { throw 'SnowLuma stop failed; no final archive was created.' }
    foreach ($launcher in $launchers) {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($launcher.ProcessId)"
        if (!$current -or $current.CreationDate -ne $launcher.CreationDate -or !$current.CommandLine.Contains($runtime)) {
            throw 'Launcher process changed; inspect before continuing.'
        }
        & taskkill.exe /PID $launcher.ProcessId /T /F | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'MaiBot process tree did not stop; no final archive was created.' }
    }
    $remaining = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('maibot.exe', 'python.exe') -and $_.CommandLine -and
        ($_.CommandLine.Contains($runtime) -or $_.ExecutablePath -eq $python)
    })
    if ($remaining.Count) { throw 'MaiBot processes remain. Do not mark this export final.' }
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$mode = if ($Cutover) { 'final' } else { 'preview' }
$archive = Join-Path $OutputDirectory ("maibot-$mode-$(Get-Date -Format 'yyyyMMdd-HHmmss').tar.gz")
$exportArgs = @((Join-Path $PSScriptRoot 'migrate.py'), 'export', '--runtime', $runtime,
    '--snowluma', $SnowLumaRoot, '--out', $archive)
if ($Cutover) { $exportArgs += '--quiesced' }
& $python @exportArgs
if ($LASTEXITCODE -ne 0) { throw 'Export failed. If Cutover was selected, both local services remain stopped.' }
Write-Output "Private archive: $archive"
if (!$Cutover) { Write-Output 'Preview only; local services remain running. Make a final -Cutover export before server import.' }
