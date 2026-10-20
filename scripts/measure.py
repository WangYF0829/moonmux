#!/usr/bin/env python3
"""measure.py -- run a command and report its peak working set.

Windows-only helper used by the resource review. It starts the target with
subprocess, polls GetProcessMemoryInfo while it runs, and always closes the
process handle. Not part of the shipped tool.

    python scripts/measure.py <exe> <args...>
"""

import ctypes
import ctypes.wintypes as wt
import subprocess
import sys
import time

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010


class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
    _fields_ = [
        ("cb", wt.DWORD),
        ("PageFaultCount", wt.DWORD),
        ("PeakWorkingSetSize", ctypes.c_size_t),
        ("WorkingSetSize", ctypes.c_size_t),
        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
        ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
        ("PagefileUsage", ctypes.c_size_t),
        ("PeakPagefileUsage", ctypes.c_size_t),
    ]


def peak_working_set(pid):
    """Return peak working set in bytes, or 0 if the process handle is gone."""
    access = PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
    handle = ctypes.windll.kernel32.OpenProcess(access, False, pid)
    if not handle:
        return 0
    try:
        counters = PROCESS_MEMORY_COUNTERS()
        counters.cb = ctypes.sizeof(counters)
        ok = ctypes.windll.psapi.GetProcessMemoryInfo(
            handle, ctypes.byref(counters), counters.cb
        )
        return counters.PeakWorkingSetSize if ok else 0
    finally:
        # Always release the handle, otherwise this measurement tool itself
        # would be the thing leaking handles.
        ctypes.windll.kernel32.CloseHandle(handle)


def main():
    if len(sys.argv) < 2:
        print("usage: measure.py <exe> [args...]")
        return 2
    started = time.time()
    proc = subprocess.Popen(sys.argv[1:], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    peak = 0
    while proc.poll() is None:
        peak = max(peak, peak_working_set(proc.pid))
        time.sleep(0.005)
    elapsed = time.time() - started
    print(
        "peak_mb=%.1f wall_s=%.2f rc=%d"
        % (peak / (1024 * 1024), elapsed, proc.returncode)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
