# Set Scrollback's collector up on Windows. No admin rights, no installer.
#
# UNVERIFIED: written without a Windows machine to run it on. Run
# `python core\scroll.py probe` first, and read what it says before trusting
# anything below.
#
#   powershell -ExecutionPolicy Bypass -File core\install.ps1
#
# What it does, in order: find Python, find the agent CLI, write paths.conf and
# schedule.conf if they are missing, register the two scheduled tasks, then
# check its own work and print what is still wrong.

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Core = Join-Path $Repo 'core'
$Conf = Join-Path $env:USERPROFILE '.beatbar'
$missing = @()

function Say($s) { Write-Host $s }
function Bad($s) { Write-Host "  MISSING  $s"; $script:missing += $s }

Say "Scrollback setup"
Say ""

# --- Python. 3.9 or newer, for zoneinfo.
$py = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
if (-not $py) { $py = (Get-Command py.exe -ErrorAction SilentlyContinue).Source }
if ($py) {
  $v = & $py -c "import sys;print('%d.%d' % sys.version_info[:2])"
  Say "  python    $py ($v)"
  if ([version]$v -lt [version]'3.9') { Bad "Python 3.9 or newer (zoneinfo)" }
  # Windows has no OS timezone database, so zoneinfo needs tzdata to resolve a
  # name like Europe/Prague. Without it the clock beside each chat falls back to
  # local time, which is usually right and occasionally not.
  & $py -c "import zoneinfo;zoneinfo.ZoneInfo('Europe/Prague')" 2>$null
  if ($LASTEXITCODE -ne 0) { Say "  tzdata    absent, times fall back to local. pip install tzdata" }
} else { Bad "Python 3.9+ on PATH" }

# --- The agent CLI. Optional: with no write-up command the digest still runs,
# and the digest is the part that needs no agent at all.
$claude = (Get-Command claude.exe -ErrorAction SilentlyContinue).Source
if (-not $claude) { $claude = (Get-Command claude.cmd -ErrorAction SilentlyContinue).Source }
if ($claude) { Say "  agent     $claude" }
else { Say "  agent     not found. Collection still works; the write-up step will be skipped." }

# --- Where the work is. Ask rather than guess: OneDrive folder redirection
# moves Documents and friends without telling anyone, and a collector pointed at
# the wrong tree collects zero and looks like a quiet week.
$work = Read-Host "  Your work folder [$env:USERPROFILE\Work]"
if (-not $work) { $work = Join-Path $env:USERPROFILE 'Work' }
if (-not (Test-Path $work)) { Bad "work folder $work does not exist" }
if ($work -like "*OneDrive*") {
  Say "  NOTE      that path is inside OneDrive. Sync rewrites file times, which"
  Say "            is exactly the noise the digest has to see through, and Files"
  Say "            On-Demand can leave a transcript unreadable. Prefer a local folder."
}

$projects = Join-Path $env:USERPROFILE '.claude\projects'
if (-not (Test-Path $projects)) { Bad "$projects (no agent transcripts here yet)" }

New-Item -ItemType Directory -Force -Path $Conf | Out-Null
$pathsConf = Join-Path $Conf 'paths.conf'
if (-not (Test-Path $pathsConf)) {
  # LF and no BOM, deliberately. Both files are also read by shell on the Mac
  # side of a shared checkout, and a CR at the end of a value is invisible until
  # something built from it fails.
  $body = "# Written by Scrollback setup.`nWORKDIR=$work`nPROJECTS=$projects`nLOGDIR=$env:LOCALAPPDATA\Scrollback\logs`nAGENT_CLI=$claude`n"
  [IO.File]::WriteAllText($pathsConf, $body.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
  Say "  wrote     $pathsConf"
} else { Say "  kept      $pathsConf" }

$schedConf = Join-Path $Repo 'schedule.conf'
if (-not (Test-Path $schedConf)) {
  $ex = Join-Path $Repo 'schedule.conf.example'
  if (Test-Path $ex) { Copy-Item $ex $schedConf; Say "  wrote     $schedConf" }
}

# --- Does it actually see anything? A setup that finishes green while pointing
# at an empty folder is the founding bug of this whole tool wearing a hat.
if ($py) {
  Say ""
  & $py (Join-Path $Core 'scroll.py') probe
  Say ""
  $n = (& $py (Join-Path $Core 'scroll.py') chats --all | Measure-Object -Line).Lines
  if ($n -eq 0) {
    Bad "no chats found today. Check the prefix line in probe above: if it does not match a real folder name, encode_cwd() in scroll.py needs the real rule."
  }
}

# --- The two scheduled tasks.
if ($py -and $missing.Count -eq 0) {
  Say "registering scheduled tasks"
  & $py (Join-Path $Core 'sched_win.py') apply
  & $py (Join-Path $Core 'sched_win.py') status
}

Say ""
if ($missing.Count -eq 0) {
  Say "Done. `"$py $Core\scroll.py status`" tells you whether it is working."
} else {
  Say "Not finished. Fix these and run this again:"
  $missing | ForEach-Object { Say "  - $_" }
  exit 1
}
