$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$packages = @(Get-ChildItem -LiteralPath (Join-Path $repo 'portable-output') -Directory)
if ($packages.Count -ne 1) { throw 'Expected one portable package.' }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('TrguiNG portable smoke ' + [Guid]::NewGuid().ToString('N'))
$root = Join-Path $fixture 'First location'
$null = New-Item -ItemType Directory -Path $fixture
$roaming = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'trguing.json'
$originalHash = if (Test-Path -LiteralPath $roaming) { (Get-FileHash -LiteralPath $roaming).Hash } else { $null }
$process = $null
try {
    Copy-Item -LiteralPath $packages[0].FullName -Destination $root -Recurse
    $config = Join-Path $root 'Data\trguing.json'
    [IO.File]::WriteAllText($config, '{"servers":[],"configVersion":1,"app":{"onClose":"quit","showTrayIcon":false},"interface":{"theme":"dark"}}')
    foreach ($attempt in 1..2) {
        $process = Start-Process -FilePath (Join-Path $root 'TrguiNG.exe') -WorkingDirectory $fixture -PassThru
        $ready = $false
        foreach ($retry in 1..20) {
            if ($process.HasExited) { throw "TrguiNG exited before becoming ready: $($process.ExitCode)" }
            try {
                $response = Invoke-WebRequest 'http://127.0.0.1:44321/args' -Method Post -ContentType 'application/json' -Body '[]' -TimeoutSec 3 -NoProxy
                if ($response.StatusCode -eq 200) { $ready = $true; break }
            } catch { Start-Sleep -Seconds 1 }
        }
        if (-not $ready) { throw 'The frontend did not signal readiness.' }
        $process.Refresh()
        if (-not $process.CloseMainWindow()) { throw 'Unable to close the application window.' }
        if (-not $process.WaitForExit(20000)) { throw 'Application did not finish saving and exit.' }
        if ($process.ExitCode -ne 0) { throw "Application exit code: $($process.ExitCode)" }
        $saved = Get-Content -LiteralPath (Join-Path $root 'Data\trguing.json') -Raw | ConvertFrom-Json
        if ($saved.interface.theme -ne 'dark' -or $null -eq $saved.interface.filterSections) { throw 'Portable configuration was not read and saved.' }
        if (@(Get-ChildItem -LiteralPath (Join-Path $root 'Data\WebView2') -Force).Count -eq 0) { throw 'WebView2 profile was not created inside Data.' }
        $afterHash = if (Test-Path -LiteralPath $roaming) { (Get-FileHash -LiteralPath $roaming).Hash } else { $null }
        if ($afterHash -ne $originalHash) { throw 'Application changed the installed configuration.' }
        if ($attempt -eq 1) {
            # WebView2 processes can take a moment to release the profile after exit.
            $moved = Join-Path $fixture 'Moved location'
            foreach ($retry in 1..10) {
                try { Move-Item -LiteralPath $root -Destination $moved; break } catch {
                    if ($retry -eq 10) { throw }
                    Start-Sleep -Seconds 1
                }
            }
            $root = $moved
        }
    }
    Write-Host 'PASS: Windows GUI starts, reads/saves portable settings, uses portable WebView2 data, and survives relocation.'
} finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
