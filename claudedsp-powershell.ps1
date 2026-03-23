Set-Location C:\Users\Bob\documents\github

function claudedsp {
    $dspDir = "$env:USERPROFILE\.claudedsp"
    $sessionsFile = "$dspDir\sessions.txt"
    $notesDir = "$dspDir\notes"
    $claudeExe = "$env:USERPROFILE\.local\bin\claude.exe"
    $cmvExe = "$env:APPDATA\npm\cmv.cmd"

    $defaultRefreshPrompt = @'
Read your memories. This is a fresh session replacing a long previous conversation on this project. Everything you need to know is in:

1. Your memory files (MEMORY.md and all linked files)
2. Any documentation in the project directory (markdown files, QA reviews, specs)
3. The codebase itself (git log for history)
4. project_current_state.md in your memory if it exists

Read all of these before responding. Then tell me what you understand about: the current state of the project, what works, what is pending, and what your behavioral rules are. Do not start any development until I tell you to.
'@

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

    function Show-List($sessions, [int]$highlight = 0) {
        Write-Host ""
        Write-Host "  === Saved Sessions ==="
        Write-Host ""
        for ($i = 0; $i -lt $sessions.Count; $i++) {
            if ($highlight -eq ($i + 1)) {
                Write-Host "  *** $($i+1). $($sessions[$i].Desc)  [Selected] ***" -ForegroundColor Yellow
            } else {
                Write-Host "  $($i+1). $($sessions[$i].Desc)"
            }
        }
        Write-Host ""
        Write-Host "  E. Edit this list"
    }

    function Do-EditList {
        while ($true) {
            $sessions = Get-Sessions
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
            if ($cmd -match '^[rR](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    $newName = Read-Host "  New name for '$($sessions[$idx].Desc)'"
                    if ($newName) {
                        $sessions[$idx].Desc = $newName
                        Save-Sessions $sessions
                    }
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[pP](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    Write-Host "  Current: $($sessions[$idx].Dir)"
                    $newPath = Read-Host "  New path (Enter to keep)"
                    if ($newPath) {
                        if (-not (Test-Path $newPath)) {
                            Write-Host "  Path does not exist: $newPath"
                            continue
                        }
                        $guid = $sessions[$idx].Guid
                        $oldKey = $sessions[$idx].Dir -replace ':', '-' -replace '\\', '-'
                        $newKey = $newPath -replace ':', '-' -replace '\\', '-'
                        $claudeProj = "$env:USERPROFILE\.claude\projects"
                        $oldFile = "$claudeProj\$oldKey\$guid.jsonl"
                        $newDir = "$claudeProj\$newKey"
                        $newFile = "$newDir\$guid.jsonl"
                        if (Test-Path $oldFile) {
                            if (-not (Test-Path $newDir)) { New-Item -ItemType Directory -Path $newDir -Force | Out-Null }
                            Copy-Item $oldFile $newFile
                            Write-Host "  Session file copied to new project directory."
                        } else {
                            Write-Host "  Warning: Session file not found at old path. Resume may not work."
                        }
                        $sessions[$idx].Dir = $newPath
                        Save-Sessions $sessions
                    }
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[dD](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    $confirm = Read-Host "  Delete '$($sessions[$idx].Desc)'? [y/N]"
                    if ($confirm -eq 'y') {
                        $delGuid = $sessions[$idx].Guid
                        $delDesc = $sessions[$idx].Desc
                        $notePath = "$notesDir\$delGuid.txt"
                        if (Test-Path $notePath) {
                            $deletedDir = "$notesDir\deleted"
                            if (-not (Test-Path $deletedDir)) { New-Item -ItemType Directory -Path $deletedDir | Out-Null }
                            $safeName = $delDesc -replace '[\\/:*?"<>|]', '_'
                            $destFile = "$deletedDir\$safeName.txt"
                            $counter = 1
                            while (Test-Path $destFile) {
                                $destFile = "$deletedDir\$safeName ($counter).txt"
                                $counter++
                            }
                            Move-Item $notePath $destFile
                            Write-Host "  Notes archived to deleted\$(Split-Path $destFile -Leaf)"
                        }
                        $sessions = @($sessions | Where-Object { $_ -ne $sessions[$idx] })
                        Save-Sessions $sessions
                    }
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[mM](\d+),(\d+)$') {
                $from = [int]$Matches[1] - 1
                $to = [int]$Matches[2] - 1
                if ($from -ge 0 -and $from -lt $sessions.Count -and $to -ge 0 -and $to -lt $sessions.Count) {
                    $item = $sessions[$from]
                    $list = [System.Collections.ArrayList]@($sessions)
                    $list.RemoveAt($from)
                    $list.Insert($to, $item)
                    $sessions = @($list)
                    Save-Sessions $sessions
                } else { Write-Host "  Invalid numbers." }
            }
            else { Write-Host "  Unknown command." }
        }
    }

    function Do-PostExit($knownGuid) {
        # Auto-snapshot with CMV on exit (suppress output; "active session" warning
        # is a false positive when other Claude sessions are running)
        $cmvExe = "$env:APPDATA\npm\cmv.cmd"
        if (Test-Path $cmvExe) {
            $snapLabel = "auto-exit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            & $cmvExe snapshot $snapLabel --latest *>$null
        }
        if ($knownGuid) {
            $guid = $knownGuid
        } else {
            # Find the most recently modified non-agent .jsonl across ALL project dirs
            $claudeProjects = "$env:USERPROFILE\.claude\projects"
            if (-not (Test-Path $claudeProjects)) { return }
            $newest = Get-ChildItem "$claudeProjects\*\*.jsonl" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike 'agent-*' } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $newest) { return }
            $guid = $newest.BaseName
        }
        $sessions = Get-Sessions
        $existing = $sessions | Where-Object { $_.Guid -eq $guid }
        if ($existing) {
            $sessions = @($existing) + @($sessions | Where-Object { $_.Guid -ne $guid })
            Save-Sessions $sessions
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
            $notePath = "$notesDir\$guid.txt"
            if (-not (Test-Path $notePath)) { New-Item -ItemType File -Path $notePath -Force | Out-Null }
            notepad $notePath
        }

        # Anti-bloat: trim
        Write-Host ""
        $doTrim = Read-Host "  Trim this session? [y/N]"
        if ($doTrim -eq 'y') {
            if (Test-Path $cmvExe) {
                Write-Host "  Trimming session..."
                $trimOutput = & $cmvExe trim --latest --skip-launch 2>&1 | Out-String
                $newGuidMatch = [regex]::Match($trimOutput, 'Session ID:\s*([0-9a-f-]+)')
                if ($newGuidMatch.Success) {
                    $newGuid = $newGuidMatch.Groups[1].Value
                    # Update GUID in sessions.txt
                    $sessions = Get-Sessions
                    foreach ($s in $sessions) {
                        if ($s.Guid -eq $guid) { $s.Guid = $newGuid }
                    }
                    Save-Sessions $sessions
                    # Rename notes file if it exists
                    $oldNotePath = "$notesDir\$guid.txt"
                    if (Test-Path $oldNotePath) {
                        Move-Item $oldNotePath "$notesDir\$newGuid.txt"
                    }
                    $guid = $newGuid
                    $trimOutput -split "`n" | Where-Object { $_ -notmatch 'Session ID:' -and $_.Trim() } | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
                    Write-Host ""
                    Write-Host "  Session trimmed. New ID: $newGuid"
                } else {
                    Write-Host "  Trim failed or no new session ID found."
                    $trimOutput | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
                }
            } else {
                Write-Host "  cmv not found. Skipping trim."
            }
        }

        # Anti-bloat: refresh (deeper clean)
        Write-Host ""
        $doRefresh = Read-Host "  Replace current session with a fresh one? (deeper clean) [y/N]"
        if ($doRefresh -eq 'y') {
            $sessions = Get-Sessions
            $curSession = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
            $curDesc = if ($curSession) { $curSession.Desc } else { "Unnamed" }
            $curDir = if ($curSession) { $curSession.Dir } else { (Get-Location).Path }

            Write-Host ""
            $newName = Read-Host "  Name for new session (Enter for '$curDesc')"
            if (-not $newName) { $newName = $curDesc }

            # Offer to edit the refresh prompt
            $promptFile = "$dspDir\refresh-prompt.tmp"
            $defaultRefreshPrompt | Set-Content $promptFile
            $editPrompt = Read-Host "  Edit the refresh prompt? (Ctrl-S, close when done) [y/N]"
            if ($editPrompt -eq 'y') {
                Start-Process notepad $promptFile -Wait
            }
            $promptText = Get-Content $promptFile -Raw
            Remove-Item $promptFile -ErrorAction SilentlyContinue

            # Run Claude headless from the session's directory
            $refreshOrigDir = Get-Location
            Set-Location $curDir
            Write-Host ""
            # Spinner while Claude creates the session
            $job = Start-Job -ScriptBlock {
                param($exe, $prompt)
                & $exe --dangerously-skip-permissions -p $prompt 2>&1 | Out-Null
            } -ArgumentList $claudeExe, $promptText
            $spin = [char[]]@('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
            $i = 0
            while ($job.State -eq 'Running') {
                Write-Host "`r  $($spin[$i % $spin.Length]) Please wait while the new session is created..." -NoNewline
                Start-Sleep -Milliseconds 100
                $i++
            }
            Receive-Job $job | Out-Null
            Remove-Job $job
            Write-Host "`r  ✓ Done.                                              "
            Set-Location $refreshOrigDir

            # Capture new session GUID
            $projKey = $curDir -replace ':', '-' -replace '\\', '-'
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
            $newest = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) {
                $freshGuid = $newest.BaseName
                # Rewrite sessions: new at top, old "(old)" at bottom
                $sessions = Get-Sessions
                $oldEntry = $null
                $others = @()
                foreach ($s in $sessions) {
                    if ($s.Guid -eq $guid) {
                        $oldDesc = if ($s.Desc -match '\(old\)') { $s.Desc } else { "$($s.Desc) (old)" }
                        $oldEntry = [PSCustomObject]@{ Guid=$s.Guid; Dir=$s.Dir; Desc=$oldDesc }
                    } else {
                        $others += $s
                    }
                }
                $freshEntry = [PSCustomObject]@{ Guid=$freshGuid; Dir=$curDir; Desc=$newName }
                $newSessions = @($freshEntry) + @($others)
                if ($oldEntry) { $newSessions += $oldEntry }
                Save-Sessions $newSessions
                Write-Host ""
                Write-Host "  Fresh session created: $newName"
                Write-Host "  Old session moved to bottom of list."
            } else {
                Write-Host "  Warning: Could not find new session GUID."
            }
        }
    }

    function Do-Resume($pick, $sessions) {
        if ($pick -lt 1 -or $pick -gt $sessions.Count) {
            Write-Host "  Invalid selection."
            return
        }
        $sel = $sessions[$pick - 1]
        $notesPath = "$notesDir\$($sel.Guid).txt"
        if (Test-Path $notesPath) {
            $notesContent = Get-Content $notesPath -ErrorAction SilentlyContinue
            if ($notesContent) {
                Write-Host ""
                $review = Read-Host "  Review notes? [Y/n]"
                if ($review -ne 'n') {
                    Write-Host ""
                    Write-Host "  --- Notes: $($sel.Desc) ---"
                    Write-Host ""
                    $notesContent | Write-Host
                    Write-Host ""
                    Write-Host "  --- End of notes ---"
                    Write-Host ""
                    Read-Host "  Press Enter to continue"
                }
            }
        }
        if (-not (Test-Path $sel.Dir)) {
            Write-Host "  Error: Project directory not found: $($sel.Dir)"
            return
        }
        $origDir = Get-Location
        Set-Location $sel.Dir
        & $claudeExe --dangerously-skip-permissions --resume $sel.Guid
        if ($LASTEXITCODE -eq 0) {
            Do-PostExit $sel.Guid
        } else {
            Write-Host ""
            $delEntry = Read-Host "  Session not found. Delete this entry? [Y/n]"
            if ($delEntry -ne 'n') {
                $sessions = Get-Sessions
                $sessions = @($sessions | Where-Object { $_.Guid -ne $sel.Guid })
                Save-Sessions $sessions
                Write-Host "  Entry removed."
            }
        }
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
            $pick = Read-Host "  Pick a session (Enter to quit)"
            if (-not $pick) { return }
            if ($pick -eq 'e' -or $pick -eq 'E') {
                Do-EditList
                continue
            }
            if ($pick -match '^\d+$') {
                Do-Resume ([int]$pick) $sessions
                return
            }
            # Non-numeric, non-E: treat as new project title
            $safeDirName = $pick.ToLower() -replace '\s+', '-' -replace '[^a-z0-9_-]', ''
            $newProjDir = Join-Path (Get-Location).Path $safeDirName
            $counter = 1
            while (Test-Path $newProjDir) {
                $newProjDir = Join-Path (Get-Location).Path "$safeDirName($counter)"
                $counter++
            }
            New-Item -ItemType Directory -Path $newProjDir -Force | Out-Null
            Write-Host ""
            Write-Host "  Starting new session: $pick"
            Write-Host "  Project dir: $newProjDir"
            $origDir = Get-Location
            Set-Location $newProjDir
            & $claudeExe --dangerously-skip-permissions
            $projKey = (Get-Location).Path -replace ':', '-' -replace '\\', '-'
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
            $newest = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) {
                $newGuid = $newest.BaseName
                $sessions = Get-Sessions
                $newEntry = [PSCustomObject]@{ Guid=$newGuid; Dir=$newProjDir; Desc=$pick }
                $sessions = @($newEntry) + @($sessions)
                Save-Sessions $sessions
            }
            Set-Location $origDir
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
        Show-List $sessions ([int]$firstArg)
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
    $preNamed = $null
    if ($passArgs.Count -eq 0) {
        if ($match) {
            Write-Host ""
            Write-Host "  Session found: $($match.Desc)"
            $rename = Read-Host "  Rename? (Enter to keep)"
            if ($rename) {
                $match.Desc = $rename
                Save-Sessions $sessions
            }
            $useExisting = Read-Host "  Resume this session? [Y/n]"
            if ($useExisting -ne 'n') {
                & $claudeExe --dangerously-skip-permissions --resume $match.Guid
                if ($LASTEXITCODE -eq 0) {
                    Do-PostExit $match.Guid
                } else {
                    Write-Host ""
                    $delEntry = Read-Host "  Session not found. Delete this entry? [Y/n]"
                    if ($delEntry -ne 'n') {
                        $sessions = @($sessions | Where-Object { $_.Guid -ne $match.Guid })
                        Save-Sessions $sessions
                        Write-Host "  Entry removed."
                    }
                }
                if ($projDir) { Set-Location $origDir }
                return
            }
        } else {
            Write-Host ""
            Write-Host "  No session entry found for this directory."
            $preNamed = Read-Host "  Create a name for this session (Enter to skip)"
        }
    }

    if ($passArgs.Count -gt 0) {
        & $claudeExe --dangerously-skip-permissions @passArgs
    } else {
        & $claudeExe --dangerously-skip-permissions
    }

    if ($LASTEXITCODE -ne 0) {
        if ($projDir) { Set-Location $origDir }
        return
    }

    if ($preNamed) {
        $projKey = (Get-Location).Path -replace ':', '-' -replace '\\', '-'
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $newest = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) {
            $newGuid = $newest.BaseName
            $sessions = Get-Sessions
            $newEntry = [PSCustomObject]@{ Guid=$newGuid; Dir=$curDir; Desc=$preNamed }
            $sessions = @($newEntry) + @($sessions)
            Save-Sessions $sessions
        }
        Write-Host ""
        $editNotes = Read-Host "  Add/edit notes? [y/N]"
        if ($editNotes -eq 'y') {
            $notePath = "$notesDir\$newGuid.txt"
            if (-not (Test-Path $notePath)) { New-Item -ItemType File -Path $notePath -Force | Out-Null }
            notepad $notePath
        }
    } else {
        Do-PostExit
    }

    if ($projDir) { Set-Location $origDir }
}

function lst { Get-ChildItem | Sort-Object LastWriteTime -Descending }

function grep {
    param(
        [Parameter(Position=0, Mandatory)][string]$Pattern,
        [Parameter(Position=1)][string]$Path,
        [Alias('r')][switch]$Recurse,
        [Alias('i')][switch]$CaseInsensitive
    )
    $slsArgs = @{ Pattern = $Pattern }
    if (-not $CaseInsensitive) { $slsArgs['CaseSensitive'] = $true }
    if ($Path) {
        Get-ChildItem -Path $Path -Recurse:$Recurse -File | Select-String @slsArgs
    } elseif ($Recurse) {
        Get-ChildItem -Recurse -File | Select-String @slsArgs
    } else {
        $input | Select-String @slsArgs
    }
}
