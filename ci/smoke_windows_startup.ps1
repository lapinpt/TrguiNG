param([Parameter(Mandatory = $true)][string]$SourceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This test uses an ephemeral GitHub Actions runner profile only.' }
if (Get-Process -Name TrguiNG -ErrorAction SilentlyContinue) { throw 'Another TrguiNG process is running.' }
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$diagnostics = Join-Path $SourceRoot 'startup-diagnostics'
$null = New-Item -ItemType Directory -Path $diagnostics -Force
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('trguing-startup-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
Copy-Item -LiteralPath (Join-Path $SourceRoot 'src-tauri\target\release\TrguiNG.exe') -Destination $fixture
Copy-Item -LiteralPath (Join-Path $SourceRoot 'src-tauri\dbip.mmdb') -Destination $fixture
$roaming = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'trguing.json'
$hadOriginal = Test-Path -LiteralPath $roaming
$originalBytes = if ($hadOriginal) { [IO.File]::ReadAllBytes($roaming) } else { $null }
$originalHash = if ($hadOriginal) { (Get-FileHash -LiteralPath $roaming).Hash } else { $null }
$process = $null
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class StartupWindowProbe {
    private delegate bool EnumProc(IntPtr window, IntPtr param);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr param);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder title, int length);
    public static bool IsVisible(int processId) {
        bool visible = false;
        EnumWindows((window, param) => {
            uint pid; GetWindowThreadProcessId(window, out pid);
            var title = new StringBuilder(512);
            GetWindowText(window, title, title.Capacity);
            // Tray libraries create auxiliary native windows in the same PID.
            // Match the application's documented main-window title/prefix.
            if (pid == (uint)processId && title.ToString().StartsWith("Transmission GUI") && IsWindowVisible(window)) visible = true;
            return true;
        }, IntPtr.Zero);
        return visible;
    }
    public static string Describe(int processId) {
        var result = new StringBuilder();
        EnumWindows((window, param) => {
            uint pid; GetWindowThreadProcessId(window, out pid);
            if (pid == (uint)processId) {
                var title = new StringBuilder(512); GetWindowText(window, title, title.Capacity);
                result.AppendLine("HWND=" + window + " visible=" + IsWindowVisible(window) + " title=" + title);
            }
            return true;
        }, IntPtr.Zero);
        return result.ToString();
    }
}
'@
try {
    foreach ($scenario in @('default', 'hidden', 'no-tray')) {
        $app = @{ onClose = 'quit'; showTrayIcon = ($scenario -eq 'hidden'); openTabs = @(); lastTab = -1 }
        if ($scenario -ne 'default') { $app.hideOnStartup = $true }
        $settings = @{ servers = @(); configVersion = 1; app = $app; interface = @{ theme = 'dark' } }
        [IO.File]::WriteAllText($roaming, ($settings | ConvertTo-Json -Depth 8))
        $stdoutPath = Join-Path $diagnostics ("stdout-$scenario.txt")
        $process = Start-Process -FilePath (Join-Path $fixture 'TrguiNG.exe') -WorkingDirectory $SourceRoot -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError (Join-Path $diagnostics "stderr-$scenario.txt")
        $expected = if ($scenario -eq 'hidden') { 'hidden' } else { 'visible' }
        $ready = $false
        foreach ($retry in 1..30) {
            if ($process.HasExited) { throw "Application exited during $scenario startup." }
            $stdout = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
            if ($stdout -and $stdout.Contains("Main window startup: $expected")) { $ready = $true; break }
            Start-Sleep -Seconds 1
        }
        if (-not $ready) { throw "Startup state $expected was not reached." }
        Start-Sleep -Seconds 2
        Write-Host ([StartupWindowProbe]::Describe($process.Id))
        $visible = [StartupWindowProbe]::IsVisible($process.Id)
        if ($visible -ne ($scenario -ne 'hidden')) { throw "Unexpected main-window visibility for $scenario." }
        Write-Host "PASS: $scenario main-window visibility is $expected, with no configured servers."
        $response = Invoke-WebRequest 'http://127.0.0.1:44321/args' -Method Post -ContentType 'application/json' -Body '[]' -TimeoutSec 10 -NoProxy
        if ($response.StatusCode -ne 200) { throw 'Explicit open request was rejected.' }
        foreach ($retry in 1..10) {
            if ([StartupWindowProbe]::IsVisible($process.Id)) { break }
            Start-Sleep -Milliseconds 300
        }
        if (-not [StartupWindowProbe]::IsVisible($process.Id)) { throw 'Explicit open request did not show the window.' }
        Write-Host "PASS: explicit open request shows the $scenario instance."
        $process.Refresh()
        if (-not $process.CloseMainWindow()) { throw 'Unable to close main window.' }
        if (-not $process.WaitForExit(20000)) { throw 'Application did not save and exit.' }
        if ($process.ExitCode -ne 0) { throw "Application exit code: $($process.ExitCode)" }
        $saved = Get-Content -LiteralPath $roaming -Raw | ConvertFrom-Json
        if ($saved.interface.theme -ne 'dark') { throw 'Installed-mode settings were not preserved.' }
        if ($scenario -ne 'default' -and -not $saved.app.hideOnStartup) { throw 'Startup preference was not saved.' }
        if (Test-Path -LiteralPath (Join-Path $fixture 'Data')) { throw 'Startup PR must not introduce portable storage.' }
    }
} finally {
    if ($null -ne $process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if ($hadOriginal) { [IO.File]::WriteAllBytes($roaming, $originalBytes) } else { Remove-Item -LiteralPath $roaming -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
$restoredHash = if (Test-Path -LiteralPath $roaming) { (Get-FileHash -LiteralPath $roaming).Hash } else { $null }
if ($restoredHash -ne $originalHash) { throw 'The runner profile was not restored.' }
Write-Host 'PASS: isolated startup PR validated independently of portable mode; runner profile restored.'
