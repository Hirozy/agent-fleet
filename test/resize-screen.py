"""Quiet resize fixture: expansion leaves synchronized output open.

Only paints on startup and SIGWINCH; never reads input. A viewer must refresh
the completed grid without waiting for another keystroke or output chunk.
"""
import os
import signal
import time

dirty = True
last_cols = None


def resized(_signal, _frame):
    global dirty
    dirty = True


signal.signal(signal.SIGWINCH, resized)
os.write(1, b"\x1b[?1049h")
while True:
    if dirty:
        dirty = False
        time.sleep(0.05)
        cols, rows = os.get_terminal_size(0)
        lines = [f"SIZE {cols} {rows}", "L" + "-" * (cols - 2) + "R"]
        screen = "\x1b[?2026h\x1b[2J" + "".join(
            f"\x1b[{row + 1};1H{line}" for row, line in enumerate(lines)
        ) + f"\x1b[{rows};1HINPUT {cols} {rows}"
        if last_cols is None or cols <= last_cols:
            screen += "\x1b[?2026l"
        last_cols = cols
        os.write(1, screen.encode())
    time.sleep(0.02)
