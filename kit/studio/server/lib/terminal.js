// Handing a session back to a real terminal.
//
// The panel cannot drive a session it did not start — measured: no command
// enumerates or writes to another session, and Remote Control controls your own
// session from elsewhere rather than the other way round. So for an observed
// session the honest offer is not a disabled input box, it is a button that
// opens the session where it can actually be driven.
//
// What gets run is returned to the caller verbatim. A panel that launches a
// terminal window should be able to show exactly what it launched.

import { spawn } from 'node:child_process';
import fs from 'node:fs';

/** Shell-quote for the command line the terminal will interpret. */
function q(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

/** PowerShell literal string: a quote is doubled, nothing else is special inside one. */
function psq(s) {
  return `'${String(s).replace(/'/g, "''")}'`;
}

/**
 * A session id is a UUID. It comes from the URL, and on Windows it ends up in a line cmd.exe interprets, where a
 * quote is not a quote (cmd hands `'` to the program as part of the id) and `&` starts a second command. So
 * nothing is built for anything else, and an id that passes needs no quoting in any shell.
 */
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function isSessionId(s) {
  return typeof s === 'string' && SESSION_ID.test(s);
}

/** AppleScript string literal: backslashes and quotes, nothing else. */
function osaQuote(s) {
  return `"${String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

/**
 * The command that opens the session in the Claude Desktop app again (`claude --desktop`, CLI 2.1.299), from its
 * own directory: `--resume <id>` looks for the session among that directory's. On Windows it is a PowerShell line
 * (5.1 and 7; Windows Terminal opens PowerShell): cmd needs `&&` and does not take single quotes, PowerShell 5.1
 * rejects `&&`, and no one line works in both. `shell` says which, so the panel can say so.
 */
export function desktopLine({ cwd, sessionId, platform = process.platform }) {
  if (!isSessionId(sessionId)) return null;
  if (platform === 'win32') {
    return { shell: 'PowerShell', line: `Set-Location -LiteralPath ${psq(cwd)}; claude --desktop --resume ${sessionId}` };
  }
  return { shell: 'sh', line: `cd ${q(cwd)} && claude --desktop --resume ${q(sessionId)}` };
}

/**
 * Build the launch for this platform.
 * Returns null when nothing here knows how to open a terminal, so the caller
 * can say so rather than fail silently.
 */
export function plan({ cwd, sessionId, command, platform = process.platform }) {
  if (command === undefined && !isSessionId(sessionId)) return null;

  if (platform === 'win32') {
    // Windows Terminal when present, the console host otherwise. wt sets the directory itself; what runs inside is
    // cmd.exe, so the line shown is a cmd line: double quotes, `cd /d` for another drive, and the id bare (a UUID).
    const inner = command ?? `claude --resume ${sessionId}`;
    const wt = ['wt.exe', '-d', cwd, 'cmd.exe', '/k', inner];
    return { platform: 'win32', via: 'wt.exe', shell: 'cmd', line: `cd /d "${cwd}" && ${inner}`, argv: wt };
  }

  const inner = command ?? `claude --resume ${q(sessionId)}`;
  const line = `cd ${q(cwd)} && ${inner}`;

  if (platform === 'darwin') {
    return {
      platform: 'darwin',
      via: 'Terminal.app',
      line,
      argv: ['osascript', '-e', `tell application "Terminal" to do script ${osaQuote(line)}`,
        '-e', 'tell application "Terminal" to activate'],
    };
  }

  // Linux and the rest: whichever emulator is actually installed. Names are
  // tried by running them, not by resolving them — a name on PATH that fails
  // to start is the failure mode this ordering exists for.
  const candidates = [
    ['x-terminal-emulator', ['-e', 'bash', '-lc', line]],
    ['gnome-terminal', ['--working-directory', cwd, '--', 'bash', '-lc', line]],
    ['konsole', ['--workdir', cwd, '-e', 'bash', '-lc', line]],
    ['xfce4-terminal', ['--working-directory', cwd, '-e', `bash -lc ${q(line)}`]],
    ['xterm', ['-e', 'bash', '-lc', line]],
  ];
  return { platform, via: 'candidates', line, candidates };
}

/** Launch it, detached, and report what was run. */
export function open({ cwd, sessionId, command }) {
  if (!cwd || !fs.existsSync(cwd)) return { ok: false, reason: `no such directory: ${cwd}` };

  if (command === undefined && !isSessionId(sessionId)) return { ok: false, reason: `not a session id: ${sessionId}` };
  const p = plan({ cwd, sessionId, command });
  if (!p) return { ok: false, reason: `no terminal launcher known for ${process.platform}` };

  const attempts = p.argv ? [p.argv] : p.candidates.map(([bin, args]) => [bin, ...args]);
  const tried = [];

  for (const argv of attempts) {
    const [bin, ...args] = argv;
    try {
      const child = spawn(bin, args, { cwd, detached: true, stdio: 'ignore' });
      child.unref();
      // A spawn that fails asynchronously (ENOENT) reports through 'error';
      // by then this call has returned, so the caller is told what was tried
      // rather than promised that it worked.
      let failed = null;
      child.on('error', (e) => { failed = e; });
      tried.push(bin);
      return { ok: true, via: p.via, ran: argv, line: p.line, tried, asyncError: failed };
    } catch (e) {
      tried.push(`${bin} (${e?.code ?? 'failed'})`);
    }
  }

  return { ok: false, reason: 'no terminal emulator could be started', tried };
}
