#!/usr/bin/env python3
"""Run an interactive program (fzf) with DEC2026 synchronized-update
markers stripped from its terminal output.

Background: fzf wraps every frame in ESC[?2026h ... ESC[?2026l. tmux
releases before 3.8 do not handle synchronized output inside popup
overlays, so frames tear and slices of the panes underneath flash
through the popup. Removing the two markers restores the classic
immediate rendering; layout and colours are unaffected.

Usage: fzf-nosync.py command [args...]
Stdin/stdout pipes pass through untouched (item list in, selection
out); only the /dev/tty screen stream is filtered. The child exit
code is preserved.
"""

import fcntl
import os
import pty
import re
import select
import signal
import sys
import termios
from tty import setraw

SYNC_RE = re.compile(rb"\x1b\[\?2026[hl]")
# Longest byte string that can still grow into a marker.
MAX_TAIL = len(b"\x1b[?2026h") - 1


def _winsize(fd):
    return fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)


def _set_winsize(fd, size):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, size)


def _split_tail(buf):
    """Split buf into (safe_to_flush, hold_back).

    A trailing fragment that could still grow into a sync marker is
    held back until more bytes arrive (markers may straddle reads).
    """
    for k in range(min(len(buf), MAX_TAIL), 0, -1):
        frag = buf[-k:]
        if b"\x1b[?2026h".startswith(frag) or b"\x1b[?2026l".startswith(frag):
            return buf[:-k], buf[-k:]
    return buf, b""


def main(argv):
    if not argv:
        print("usage: fzf-nosync.py command [args...]", file=sys.stderr)
        return 2
    try:
        tty = os.open("/dev/tty", os.O_RDWR)
    except OSError:
        # No controlling terminal (e.g. --filter mode in a pipe):
        # nothing to relay, run the command directly.
        try:
            os.execvp(argv[0], argv)
        except OSError as exc:
            print(f"fzf-nosync: exec {argv[0]}: {exc}", file=sys.stderr)
            return 127
    stdin_save = os.dup(0)
    stdout_save = os.dup(1)

    # Raw mode on our terminal side: pass keys (Enter, Ctrl-C, mouse)
    # through untouched instead of letting the line discipline cook them.
    try:
        raw_saved = termios.tcgetattr(tty)
        setraw(tty)
    except termios.error:
        raw_saved = None

    pid, master = pty.fork()
    if pid == 0:
        # Child: keep the caller's pipes on stdin/stdout, screen on pty.
        os.dup2(stdin_save, 0)
        os.dup2(stdout_save, 1)
        try:
            os.execvp(argv[0], argv)
        except OSError as exc:
            print(f"fzf-nosync: exec {argv[0]}: {exc}", file=sys.stderr)
            os._exit(127)

    try:
        _set_winsize(master, _winsize(tty))
    except OSError:
        pass

    def on_winch(_signo, _frame):
        try:
            _set_winsize(master, _winsize(tty))
        except OSError:
            pass

    signal.signal(signal.SIGWINCH, on_winch)

    status = 1
    pending = b""
    try:
        while True:
            readable, _, _ = select.select([master, tty], [], [])
            if tty in readable:
                try:
                    keys = os.read(tty, 65536)
                except OSError:
                    break
                if not keys:
                    break
                try:
                    os.write(master, keys)
                except OSError:
                    break
            if master in readable:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                chunk, pending = _split_tail(pending + data)
                if chunk:
                    try:
                        os.write(tty, SYNC_RE.sub(b"", chunk))
                    except OSError:
                        break
    finally:
        if pending:
            try:
                os.write(tty, SYNC_RE.sub(b"", pending))
            except OSError:
                pass
        # Do not leave fzf running behind us (e.g. relay killed first).
        try:
            os.kill(pid, signal.SIGHUP)
        except (ProcessLookupError, OSError):
            pass
        try:
            _, status = os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        try:
            signal.signal(signal.SIGWINCH, signal.SIG_DFL)
        except OSError:
            pass
        if raw_saved is not None:
            try:
                termios.tcsetattr(tty, termios.TCSADRAIN, raw_saved)
            except OSError:
                pass
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
