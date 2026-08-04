#!/usr/bin/env python3
"""Append sanitized Bash-hook metadata without following links."""

import fcntl
import json
import os
import stat
import sys


def fail(message: str) -> None:
    print(f"audit-bash: metadata log unavailable ({message})", file=sys.stderr)
    raise SystemExit(1)


def open_owned_regular(path: str, flags: int) -> int:
    try:
        fd = os.open(path, flags | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError as exc:
        fail(f"open errno={exc.errno}")
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        os.close(fd)
        fail("unsafe file type, owner, or link count")
    os.fchmod(fd, 0o600)
    return fd


def write_all(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            fail("short write")
        view = view[written:]


def main() -> None:
    if len(sys.argv) != 3:
        fail("invalid arguments")
    log_path = sys.argv[1]
    try:
        max_size = int(sys.argv[2])
    except ValueError:
        fail("invalid size")

    raw = sys.stdin.buffer.read(16385)
    if len(raw) > 16384:
        fail("metadata too large")
    try:
        metadata = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("invalid metadata")
    expected = {"timestamp", "tool", "permission_mode", "cwd"}
    if set(metadata) != expected or not all(isinstance(metadata[key], str) for key in expected):
        fail("invalid metadata schema")
    payload = (json.dumps(metadata, separators=(",", ":"), ensure_ascii=False) + "\n").encode()

    log_fd = open_owned_regular(log_path, os.O_RDWR | os.O_APPEND)
    try:
        fcntl.flock(log_fd, fcntl.LOCK_EX)
        if os.fstat(log_fd).st_size > max_size:
            archive_fd = open_owned_regular(log_path + ".1", os.O_WRONLY)
            try:
                os.ftruncate(archive_fd, 0)
                offset = 0
                while True:
                    chunk = os.pread(log_fd, 65536, offset)
                    if not chunk:
                        break
                    write_all(archive_fd, chunk)
                    offset += len(chunk)
                os.fsync(archive_fd)
            finally:
                os.close(archive_fd)
            os.ftruncate(log_fd, 0)
        write_all(log_fd, payload)
        os.fsync(log_fd)
    except OSError as exc:
        fail(f"write errno={exc.errno}")
    finally:
        os.close(log_fd)


if __name__ == "__main__":
    main()
