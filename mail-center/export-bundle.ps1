$ErrorActionPreference = 'Stop'
$releaseName = 'mail-center-ops-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$releaseRoot = Join-Path $PSScriptRoot "dist/$releaseName"
$bundleRoot = Join-Path $releaseRoot 'mail-center'
if (Test-Path -LiteralPath $releaseRoot) { throw 'Release directory already exists; rerun with a new timestamp.' }
[void](New-Item -ItemType Directory -Path "$bundleRoot/tools/nginx/templates" -Force)

function Copy-ReleaseFiles([string]$SourceRoot, [string]$TargetRoot, [string[]]$Entries) {
    foreach ($entry in $Entries) {
        $source = Join-Path $SourceRoot $entry
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing release input: $source" }
        $files = if ((Get-Item -LiteralPath $source).PSIsContainer) { Get-ChildItem -LiteralPath $source -File -Recurse } else { Get-Item -LiteralPath $source }
        foreach ($file in $files) {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Symlink is not a release input: $($file.FullName)" }
            $relative = [IO.Path]::GetRelativePath($SourceRoot, $file.FullName)
            if ($relative -match '(^|[\\/])(\.env[^\\/]*|\.git|node_modules|data|backups)([\\/]|$)' -or $file.Extension -in '.key', '.pem', '.exe') {
                throw "Private or generated file is not a release input: $relative"
            }
            $target = Join-Path $TargetRoot $relative
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            Copy-Item -LiteralPath $file.FullName -Destination $target
            # Linux shell/config files must work after a Windows checkout.
            if ($file.Extension -in '.sh', '.conf', '.yaml', '.template') {
                $contents = [IO.File]::ReadAllText($target).Replace("`r`n", "`n")
                [IO.File]::WriteAllText($target, $contents, [Text.UTF8Encoding]::new($false))
            }
        }
    }
}

Copy-ReleaseFiles $PSScriptRoot $bundleRoot @('compose.yaml', 'gateway', 'lib.sh', 'init.sh', 'install.sh', 'bootstrap-admin.sh', 'setup-web.sh', 'status.sh', 'enable-smtp.sh', 'sync-smtp-certificate.sh', 'backup.sh', 'restore.sh', 'README.md', 'VERIFICATION.md')
Copy-ReleaseFiles (Join-Path $PSScriptRoot '../nginx') "$bundleRoot/tools/nginx" @('add-site.sh', 'lib.sh', 'install.sh', 'reload-after-renew.sh', 'templates', 'README.md')
# This template contains no secret; the real .env is never copied.
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '.env.example') -Destination (Join-Path $bundleRoot '.env.example')
$archive = Join-Path $PSScriptRoot "dist/$releaseName.tar.gz"
& tar -czf $archive -C $releaseRoot mail-center
if ($LASTEXITCODE -ne 0) { throw 'Creating release archive failed.' }
Write-Output "Deployment archive: $archive"
Write-Output "Release directory: $bundleRoot"
