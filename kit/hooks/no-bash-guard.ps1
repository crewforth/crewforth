# no-bash-guard.ps1 - the gate that runs when no other gate can.
#
# Crewforth's gates are bash scripts. On Windows, when Claude Code finds no Git Bash, a hook that names bash fails
# with "requires bash but Git Bash was not found" and exit 1 - which does not block - and the Bash tool does not
# exist at all: PowerShell is the shell, and nothing guards it (measured in the field, 3.0.1-rc.2).
# One hook in settings.json names no shell. Claude Code runs it through bash where it finds one, and that branch
# exits 0 without starting a process; where it finds none it runs it through PowerShell, and that branch loads this
# file. So this code runs only in the state it exists for.
#
# It is read with Get-Content and run with Invoke-Expression, never as a script file: the default execution policy
# on a Windows client refuses to run .ps1 files, and a gate that the policy switches off is not a gate.
#
# The lookup is Claude Code's own, in its order (read from its 2.1.284 binary; eval/lib/git-bash.sh holds the same
# order for the doctor): CLAUDE_CODE_GIT_BASH_PATH when its name is bash/sh and the file exists, the two default
# Git folders, then <git on PATH>\..\..\bin\bash.exe. A bash found here means Claude Code ran this hook through
# PowerShell for another reason, and the bash gates work: exit 0.
#
# Windows PowerShell 5.1 and PowerShell 7. ASCII only: 5.1 reads a file without a BOM in the ANSI code page.
# Paths are joined with `/` and passed through GetFullPath: Windows prints them with `\`, and the same code can be
# exercised by pwsh on Linux and macOS, where the smoke test runs it.
$ErrorActionPreference = 'Stop'

function Test-CrewBash([string]$p) {
  if (-not $p) { return $false }
  $n = [IO.Path]::GetFileName($p).ToLowerInvariant()
  if (@('bash.exe', 'sh.exe', 'bash', 'sh') -notcontains $n) { return $false }
  return [IO.File]::Exists($p)
}

$found = $null
if (Test-CrewBash $env:CLAUDE_CODE_GIT_BASH_PATH) { $found = $env:CLAUDE_CODE_GIT_BASH_PATH }
if (-not $found) {
  foreach ($c in @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files (x86)\Git\bin\bash.exe')) {
    if ([IO.File]::Exists($c)) { $found = $c; break }
  }
}
if (-not $found) {
  $g = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($g) {
    $d = Split-Path -Parent (Split-Path -Parent $g.Source)
    if ($d) { $c = [IO.Path]::GetFullPath((Join-Path $d 'bin/bash.exe')); if ([IO.File]::Exists($c)) { $found = $c } }
  }
}
if ($found) { exit 0 }

# Not found. Name the path to set when one exists on this machine - checked here, never guessed.
$fix = $null
$v = $env:CLAUDE_CODE_GIT_BASH_PATH
if ($v -and ([IO.Path]::GetFileName($v).ToLowerInvariant() -eq 'git-bash.exe')) {
  $c = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $v) 'bin/bash.exe'))
  if ([IO.File]::Exists($c)) { $fix = $c }
}
if (-not $fix -and $env:LOCALAPPDATA) {
  $c = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs/Git/bin/bash.exe'))
  if ([IO.File]::Exists($c)) { $fix = $c }
}

$m = "GUARD: Crewforth's gates cannot run here, so this tool call is stopped." + [Environment]::NewLine
$m += "Claude Code found no Git Bash. Every Crewforth gate is a bash script: none of them started, and the rules they enforce (commit and push approval, destructive commands, secrets, the gate files) are not being checked." + [Environment]::NewLine
if ($v -and -not (Test-CrewBash $v)) {
  $m += "CLAUDE_CODE_GIT_BASH_PATH is set to '$v', which Claude Code does not accept: it must name bash.exe and exist." + [Environment]::NewLine
}
if ($fix) {
  $m += "Tell the user to set the user environment variable CLAUDE_CODE_GIT_BASH_PATH to `"$fix`"" + [Environment]::NewLine
} else {
  $m += "Tell the user to install Git for Windows in its default folder, or to set the user environment variable CLAUDE_CODE_GIT_BASH_PATH to <Git>\bin\bash.exe" + [Environment]::NewLine
}
$m += "and then to close the terminal and Claude Code and open them again (an open terminal keeps the old value). /crew-doctor confirms it." + [Environment]::NewLine
$m += "Reading and searching still work. Do not look for another way to write or run commands: there is no gate behind it."
[Console]::Error.WriteLine($m)
exit 2
