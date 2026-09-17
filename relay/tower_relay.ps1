# tower_relay.ps1 — no Python required
# Polls Anya board and writes state.json for the CET mod.
# Also forwards the mod's observed.json (what the game sees) to the board's
# /observed — CET cannot open a socket, so this is its only way out.
#
# PowerShell (as Admin not required):
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\tools\tower_relay.ps1
#   .\relay\tower_relay.ps1 -Board http://192.168.1.10:8787 -Out "D:\Games\Cyberpunk 2077\bin\x64\plugins\cyber_engine_tweaks\mods\AnyaBoard\state.json"
#
# Ctrl+C to stop.

param(
    [string]$Board = "http://127.0.0.1:8787",
    [string]$Out = "",
    [double]$IntervalSec = 0.35
)

$ErrorActionPreference = "Stop"
$Board = $Board.TrimEnd("/")

if ([string]::IsNullOrWhiteSpace($Out)) {
    # Default: next to this script's repo path if present
    $repoCet = Join-Path $PSScriptRoot "..\game\cet\AnyaBoard\state.json"
    $repoCet = [System.IO.Path]::GetFullPath($repoCet)
    if (Test-Path (Split-Path $repoCet -Parent)) {
        $Out = $repoCet
    } else {
        $Out = Join-Path (Get-Location) "state.json"
    }
}

$OutDir = Split-Path -Parent $Out
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

Write-Host "[tower_relay] board=$Board"
Write-Host "[tower_relay] out=$Out"
Write-Host "[tower_relay] interval=${IntervalSec}s"
Write-Host "[tower_relay] Ctrl+C to stop"
Write-Host ""

$lastSeq = $null
$fails = 0

# observed.json sits next to state.json; CET writes it every ~500ms.
$ObservedPath = Join-Path $OutDir "observed.json"
$lastObservedWrite = [DateTime]::MinValue
$observedFails = 0
$observedSent = 0

function Read-Shared {
    param([string]$Path)
    # FileShare.ReadWrite so reading never blocks CET's next write.
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($fs)
        return $reader.ReadToEnd()
    } finally {
        $fs.Close()
    }
}

function Put-Json {
    param([string]$Url, [string]$Json)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = "PUT"
    $req.ContentType = "application/json"
    $req.ContentLength = $bytes.Length
    $req.Timeout = 1500
    $req.ReadWriteTimeout = 1500
    $stream = $req.GetRequestStream()
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
    $resp = $req.GetResponse()
    $resp.Close()
}

function Get-BoardState {
    param([string]$Url)
    # Use .NET WebClient / HttpWebRequest for broad Win10 compatibility
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = "GET"
    $req.Accept = "application/json"
    $req.Timeout = 2000
    $req.ReadWriteTimeout = 2000
    try {
        $resp = $req.GetResponse()
        try {
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Close()
            return $body
        } finally {
            $resp.Close()
        }
    } catch {
        throw $_.Exception.Message
    }
}

while ($true) {
    try {
        $json = Get-BoardState -Url "$Board/state"
        # Validate it looks like JSON object
        if (-not $json.Trim().StartsWith("{")) {
            throw "non-json response: $($json.Substring(0, [Math]::Min(80, $json.Length)))"
        }

        $tmp = "$Out.tmp"
        [System.IO.File]::WriteAllText($tmp, $json + "`n")

        # Publish atomically.
        #
        # Move-Item -Force is NOT atomic: it deletes the destination and then
        # renames, leaving a window where state.json does not exist. CET reading
        # in that window logs "not found"; CET holding the file open when the
        # delete lands makes the move fail with "Cannot create a file when that
        # file already exists" and the update is dropped.
        #
        # File.Replace is a single atomic operation with no such gap. It can
        # still lose a race against a reader holding the handle, so retry
        # briefly — CET's read is open-read-close inside one tick.
        $published = $false
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Out) {
                    [System.IO.File]::Replace($tmp, $Out, $null)
                } else {
                    [System.IO.File]::Move($tmp, $Out)
                }
                $published = $true
                break
            } catch {
                Start-Sleep -Milliseconds 15
            }
        }
        if (-not $published) {
            # Fall back to the old non-atomic path rather than dropping the
            # update. Leaves a brief gap where state.json is absent; the mod
            # tolerates a single missed read, so this self-heals.
            Move-Item -Force -Path $tmp -Destination $Out
        }

        # Parse seq/mode for logging (ConvertFrom-Json is fine on Win10 PS 5.1)
        $obj = $json | ConvertFrom-Json
        $seq = $obj.seq
        $mode = $obj.mode
        $line = ""
        if ($obj.dialogue -and $obj.dialogue.text) {
            $line = [string]$obj.dialogue.text
            if ($line.Length -gt 50) { $line = $line.Substring(0, 50) + "..." }
        }

        if ($seq -ne $lastSeq) {
            Write-Host ("[tower_relay] seq={0} mode={1} dialogue={2}" -f $seq, $mode, $line)
            $lastSeq = $seq
        }
        $fails = 0
    } catch {
        $fails++
        if ($fails -eq 1 -or ($fails % 20) -eq 0) {
            Write-Host ("[tower_relay] fail #{0}: {1}" -f $fails, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    # Game -> board. Separate try: a perception hiccup must not look like the
    # state path failing, and vice versa.
    try {
        if (Test-Path -LiteralPath $ObservedPath) {
            $written = [System.IO.File]::GetLastWriteTimeUtc($ObservedPath)
            if ($written -ne $lastObservedWrite) {
                $obsJson = (Read-Shared -Path $ObservedPath).Trim()
                # CET writes in place; a read can land mid-write. Skip anything
                # that is not a whole JSON object and take the next one.
                $whole = $false
                if ($obsJson.StartsWith("{") -and $obsJson.EndsWith("}")) {
                    try { $null = $obsJson | ConvertFrom-Json; $whole = $true } catch { }
                }
                if ($whole) {
                    Put-Json -Url "$Board/observed" -Json $obsJson
                    $lastObservedWrite = $written
                    $observedSent++
                    if ($observedSent -eq 1) {
                        Write-Host "[tower_relay] forwarding observed.json -> $Board/observed"
                    }
                    $observedFails = 0
                }
            }
        }
    } catch {
        $observedFails++
        if ($observedFails -eq 1 -or ($observedFails % 20) -eq 0) {
            Write-Host ("[tower_relay] observed fail #{0}: {1}" -f $observedFails, $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    Start-Sleep -Seconds $IntervalSec
}
