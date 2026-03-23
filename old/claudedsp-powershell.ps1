# ClaudeDSP - Claude launcher with session management (PowerShell)
#
# Add this function to your $PROFILE:
#   notepad $PROFILE
#
# Usage:
#   claudedsp                       Launch Claude normally
#   claudedsp l                     List saved sessions
#   claudedsp 3                     Resume session #3
#   claudedsp --proj C:\myproject   Launch in a specific directory

function claudedsp {
    $dspDir = "$env:USERPROFILE\.claudedsp"
    $sessionsFile = "$dspDir\sessions.txt"
    $notesDir = "$dspDir\notes"
    $claudeExe = "$env:USERPROFILE\.local\bin\claude.exe"

    if (-not (Test-Path $dspDir)) { New-Item -ItemType Directory -Path $dspDir | Out-Null }
    if (-not (Test-Path $notesDir)) { New-Item -ItemType Directory -Path $notesDir | Out-Null }
    if (-not (Test-Path $sessionsFile)) { New-Item -ItemType File -Path $sessionsFile | Out-Null }

    function Get-Sessions {
        $lines = Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' }
        $sessions = @()
        foreach ($line in $lines) {
            $parts = $line -split '\|', 3
            $sessions += [PSCustomObject]@{ Guid=$parts[0]; Dir=$parts[1]; Desc=$parts[2] }
        }
        return $sessions
    }

    function Save-Sessions($sessions) {
        $lines = $sessions | ForEach-Object { "$($_.Guid)|$($_.Dir)|$($_.Desc)" }
        $lines | Set-Content $sessionsFile
    }

    function Show-List($sessions) {
        Write-Host ""
        Write-Host "  === Saved Sessions ==="
        Write-Host ""
        for ($i = 0; $i -lt $sessions.Count; $i++) {
            Write-Host "  $($i+1). $($sessions[$i].Desc)"
        }
        Write-Host ""
        Write-Host "  E. Edit this list"
    }

    function Do-Edit($sessions) {
        while ($true) {
            Write-Host ""
            Write-Host "  === Edit Sessions ==="
            Write-Host ""
            for ($i = 0; $i -lt $sessions.Count; $i++) {
                Write-Host "  $($i+1). $($sessions[$i].Desc)  [$($sessions[$i].Dir)]"
            }
            Write-Host ""
            Write-Host "  R# = Rename   P# = Path   D# = Delete   M#,# = Move (from,to)   Q = Done"
            Write-Host ""
            $cmd = Read-Host "  >"
            if (-not $cmd -or $cmd -eq 'q' -or $cmd -eq 'Q') { return }

            if ($cmd -match '^[Rr](\d+)$') {
                $num = [int]$Matches[1]
                if ($num -lt 1 -or $num -gt $sessions.Count) { Write-Host "  Invalid #."; continue }
                $sel = $sessions[$num - 1]
                $newName = Read-Host "  New name for '$($sel.Desc)'"
                if ($newName) { $sel.Desc = $newName; Save-Sessions $sessions }
            }
            elseif ($cmd -match '^[Pp](\d+)$') {
                $num = [int]$Matches[1]
                if ($num -lt 1 -or $num -gt $sessions.Count) { Write-Host "  Invalid #."; continue }
                $sel = $sessions[$num - 1]
                $newPath = Read-Host "  New path for '$($sel.Desc)'"
                if ($newPath) { $sel.Dir = $newPath; Save-Sessions $sessions }
            }
            elseif ($cmd -match '^[Dd](\d+)$') {
                $num = [int]$Matches[1]
                if ($num -lt 1 -or $num -gt $sessions.Count) { Write-Host "  Invalid #."; continue }
                $sel = $sessions[$num - 1]
                $confirm = Read-Host "  Delete '$($sel.Desc)'? [y/N]"
                if ($confirm -eq 'y') {
                    $sessions = @($sessions | Where-Object { $_ -ne $sel })
                    Save-Sessions $sessions
                }
            }
            elseif ($cmd -match '^[Mm](\d+),(\d+)$') {
                $from = [int]$Matches[1]; $to = [int]$Matches[2]
                if ($from -lt 1 -or $from -gt $sessions.Count -or $to -lt 1 -or $to -gt $sessions.Count) {
                    Write-Host "  Invalid range."; continue
                }
                $item = $sessions[$from - 1]
                $list = [System.Collections.ArrayList]@($sessions)
                $list.RemoveAt($from - 1)
                $list.Insert($to - 1, $item)
                $sessions = @($list)
                Save-Sessions $sessions
            }
            else { Write-Host "  Unknown command." }
        }
    }

    function Do-PostExit {
        $projKey = (Get-Location).Path -replace ':', '-' -replace '\\', '-'
        $projDir = "$env:USERPROFILE\.claude\projects\$projKey"
        if (-not (Test-Path $projDir)) { return }
        $newest = Get-ChildItem "$projDir\*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $newest) { return }
        $guid = $newest.BaseName
        $sessions = Get-Sessions
        $existing = $sessions | Where-Object { $_.Guid -eq $guid }
        if ($existing) {
            $sessions = @($existing) + @($sessions | Where-Object { $_.Guid -ne $guid })
            Save-Sessions $sessions
            Write-Host ""
            Write-Host "  Session: $($existing.Desc)"
            $rename = Read-Host "  Rename? (Enter to keep)"
            if ($rename) {
                $existing.Desc = $rename
                Save-Sessions $sessions
            }
        } else {
            Write-Host ""
            $desc = Read-Host "  Describe this session (Enter to skip)"
            if (-not $desc) { return }
            $newEntry = [PSCustomObject]@{ Guid=$guid; Dir=(Get-Location).Path; Desc=$desc }
            $sessions = @($newEntry) + @($sessions)
            Save-Sessions $sessions
        }
        Write-Host ""
        $editNotes = Read-Host "  Add/edit notes? [y/N]"
        if ($editNotes -eq 'y') {
            notepad "$notesDir\$guid.txt"
        }
    }

    function Do-Resume($pick, $sessions) {
        if ($pick -lt 1 -or $pick -gt $sessions.Count) {
            Write-Host "  Invalid selection."
            return
        }
        $sel = $sessions[$pick - 1]
        Write-Host ""
        $review = Read-Host "  Review notes? [Y/n]"
        if ($review -ne 'n') {
            Write-Host ""
            Write-Host "  --- Notes: $($sel.Desc) ---"
            Write-Host ""
            $notesPath = "$notesDir\$($sel.Guid).txt"
            if (Test-Path $notesPath) {
                Get-Content $notesPath | Write-Host
            } else {
                Write-Host "  No notes yet."
            }
            Write-Host ""
            Write-Host "  --- End of notes ---"
            Write-Host ""
            Read-Host "  Press Enter to continue"
        }
        if (-not (Test-Path $sel.Dir)) {
            Write-Host "  Error: Project directory not found: $($sel.Dir)"
            return
        }
        $origDir = Get-Location
        Set-Location $sel.Dir
        & $claudeExe --dangerously-skip-permissions --resume $sel.Guid
        Do-PostExit
        Set-Location $origDir
    }

    # --- Main ---
    $firstArg = $args[0]

    # List mode
    if ($firstArg -eq 'l' -or $firstArg -eq 'L' -or $firstArg -eq '-l' -or $firstArg -eq '-L') {
        while ($true) {
            $sessions = Get-Sessions
            if ($sessions.Count -eq 0) {
                Write-Host ""
                Write-Host "  No saved sessions."
                Write-Host ""
                return
            }
            Show-List $sessions
            Write-Host ""
            $pick = Read-Host "  Pick #, new title, or Enter to quit"
            if (-not $pick) { return }
            if ($pick -eq 'e' -or $pick -eq 'E') {
                Do-Edit $sessions
                continue
            }
            if ($pick -match '^\d+$') {
                Do-Resume ([int]$pick) $sessions
                return
            }
            # Non-numeric, non-empty, non-E: treat as new project title
            $dirName = $pick.ToLower() -replace '\s+', '-' -replace '[^a-z0-9_-]', ''
            $newProjDir = Join-Path $HOME $dirName
            if (Test-Path $newProjDir) {
                $n = 1
                while (Test-Path "$newProjDir($n)") { $n++ }
                $newProjDir = "$newProjDir($n)"
            }
            New-Item -ItemType Directory -Path $newProjDir -Force | Out-Null
            Write-Host ""
            Write-Host "  Starting new session: $pick"
            Write-Host "  Project dir: $newProjDir"
            $origDir2 = Get-Location
            Set-Location $newProjDir
            & $claudeExe --dangerously-skip-permissions
            # Find and save the session
            $projKey2 = (Get-Location).Path -replace ':', '-' -replace '\\', '-'
            $projDir2 = "$env:USERPROFILE\.claude\projects\$projKey2"
            if (Test-Path $projDir2) {
                $newest2 = Get-ChildItem "$projDir2\*.jsonl" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($newest2) {
                    $guid2 = $newest2.BaseName
                    $newEntry = [PSCustomObject]@{ Guid=$guid2; Dir=$newProjDir; Desc=$pick }
                    $sessions = @($newEntry) + @(Get-Sessions)
                    Save-Sessions $sessions
                }
            }
            Set-Location $origDir2
            return
        }
        return
    }

    # Direct resume by number
    if ($firstArg -match '^\d+$') {
        $sessions = Get-Sessions
        if ($sessions.Count -eq 0) {
            Write-Host "  No saved sessions."
            return
        }
        Show-List $sessions
        Do-Resume ([int]$firstArg) $sessions
        return
    }

    # Normal mode
    $projDir = $null
    $passArgs = @()
    $i = 0
    while ($i -lt $args.Count) {
        if ($args[$i] -eq '--proj' -and ($i + 1) -lt $args.Count) {
            $projDir = $args[$i + 1]
            $i += 2
        } else {
            $passArgs += $args[$i]
            $i++
        }
    }

    $origDir = Get-Location
    if ($projDir) {
        if (-not (Test-Path $projDir)) {
            Write-Host "Error: Directory not found: $projDir"
            return
        }
        Set-Location $projDir
    }

    # Check if current directory matches an existing session
    $curDir = (Get-Location).Path
    $sessions = Get-Sessions
    $match = $sessions | Where-Object { $_.Dir -eq $curDir } | Select-Object -First 1
    $preName = $null
    if ($passArgs.Count -eq 0) {
        if ($match) {
            Write-Host ""
            Write-Host "  Found existing session: $($match.Desc)"
            $useExisting = Read-Host "  Continue with this session? [Y/n]"
            if ($useExisting -ne 'n') {
                & $claudeExe --dangerously-skip-permissions --resume $match.Guid
                Do-PostExit
                if ($projDir) { Set-Location $origDir }
                return
            }
        } else {
            Write-Host ""
            Write-Host "  No session entry found for this directory."
            $preName = Read-Host "  Name this session (Enter to skip)"
        }
    }

    if ($passArgs.Count -gt 0) {
        & $claudeExe --dangerously-skip-permissions @passArgs
    } else {
        & $claudeExe --dangerously-skip-permissions
    }

    if ($preName) {
        $projKey2 = (Get-Location).Path -replace ':', '-' -replace '\\', '-'
        $projDir2 = "$env:USERPROFILE\.claude\projects\$projKey2"
        if (Test-Path $projDir2) {
            $newest2 = Get-ChildItem "$projDir2\*.jsonl" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest2) {
                $newEntry = [PSCustomObject]@{ Guid=$newest2.BaseName; Dir=(Get-Location).Path; Desc=$preName }
                $sessions = @($newEntry) + @(Get-Sessions)
                Save-Sessions $sessions
            }
        }
    } else {
        Do-PostExit
    }

    if ($projDir) { Set-Location $origDir }
}
