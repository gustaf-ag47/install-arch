#!/usr/bin/env python3
"""Pure-logic E2E of the token rotation in bin/claude-token-proxy.

No network, no real tokens: we load the proxy as a module and drive its
selection/rotation functions directly, asserting the account-rollover behaviour
the whole setup depends on. Exits non-zero on any failed assertion.
"""
import importlib.util
from importlib.machinery import SourceFileLoader
import os
import sys
import tempfile
from pathlib import Path

# Isolate CONTROL_DIR (force_cooldown lives there) before importing the module,
# since the proxy computes it from XDG_CACHE_HOME at import time.
TMP = tempfile.mkdtemp(prefix="cc-proxy-test-")
os.environ["XDG_CACHE_HOME"] = TMP

PROXY = Path(__file__).resolve().parent.parent.parent / "dotfiles" / "bin" / "claude-token-proxy"
if not PROXY.exists():  # allow override for odd layouts
    PROXY = Path(os.environ.get("CC_PROXY_PATH", PROXY))

spec = importlib.util.spec_from_file_location(
    "ccproxy", PROXY, loader=SourceFileLoader("ccproxy", str(PROXY)))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

FAILS = []
def check(name, cond):
    print(("  PASS " if cond else "  FAIL ") + name)
    if not cond:
        FAILS.append(name)

def mk(fp_seed, u7=None, u5=None, cooldown=0.0, valid=True):
    t = m.Tok("sk-ant-oat01-" + fp_seed + "x" * 20)
    t.u7, t.u5, t.cooldown_until, t.valid = u7, u5, cooldown, valid
    return t

def set_state(*toks):
    m.STATE.clear()
    m.STATE.extend(toks)

def force_cooldown(*fps):
    p = Path(TMP) / "cc-proxy"
    p.mkdir(parents=True, exist_ok=True)
    (p / "force_cooldown").write_text(" ".join(fps))

print("--- pick() ranking ---")
a = mk("AAAA", u7=0.15, u5=0.9)   # most weekly headroom
b = mk("BBBB", u7=0.95, u5=0.0)   # nearly weekly-exhausted
set_state(a, b)
force_cooldown()  # clear
check("picks lowest weekly-utilization account", m.pick() is a)

print("--- failover excludes the tried account ---")
check("with A excluded, rolls over to B", m.pick(exclude={a.fp}) is b)

print("--- forced cooldown removes an account from selection ---")
force_cooldown(a.fp)
check("A forced down -> selects B", m.pick() is b)

print("--- both accounts down -> no crash, returns None or fallback ---")
force_cooldown(a.fp, b.fp)
res = m.pick()
check("both forced down -> pick() returns None (graceful)", res is None)

print("--- invalid (401/403) account is never selected ---")
force_cooldown()
c = mk("CCCC", u7=0.01, u5=0.0, valid=False)  # best headroom but dead
set_state(c, b)
check("invalid account skipped even with best headroom", m.pick() is b)

print("--- 5h util only breaks ties on equal weekly ---")
d = mk("DDDD", u7=0.50, u5=0.10)
e = mk("EEEE", u7=0.50, u5=0.80)
set_state(d, e)
check("equal weekly -> lower 5h wins", m.pick() is d)

print()
print("==================== ROTATION SUMMARY ====================")
print(f"PASS={6 - len(FAILS)}  FAIL={len(FAILS)}")
sys.exit(1 if FAILS else 0)
