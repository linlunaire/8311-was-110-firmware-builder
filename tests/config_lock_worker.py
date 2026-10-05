"""Run actual LuCI save/restore control flow with real Linux POSIX locks."""
import fcntl
import json
import os
from pathlib import Path
import sys
import time

from lupa.lua51 import LuaRuntime

root = Path(sys.argv[1]).resolve()
action = sys.argv[2]
repo = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().REPO_ROOT = repo.as_posix()
handles = {}


def open_lock(path):
    if path not in ("/tmp/8311-config.lock", "/tmp/8311-web-upgrade.lock"):
        raise ValueError("Unexpected worker file")
    fd = os.open(root / Path(path).name, os.O_CREAT | os.O_RDWR, 0o600)
    handles[fd] = fd
    return fd


def try_lock(fd):
    # nixio fd:lock('tlock') uses non-blocking POSIX record locks, not flock.
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def close_lock(fd):
    os.close(handles.pop(fd))
    return True


def write_field():
    with (root / "writers").open("a") as log:
        log.write(action + "\n")
    (root / "entered").touch()
    deadline = time.monotonic() + 8
    while not (root / "release").exists():
        if time.monotonic() >= deadline:
            raise TimeoutError("Lock worker was not released")
        time.sleep(0.01)
    return True


def worker(setup):
    state, tools, controller = setup()
    lua.globals().WORKER_STATE = state
    lua.globals().WORKER_TOOLS = tools
    lua.globals().WORKER_CONTROLLER = controller
    lua.globals().WORKER_ACTION = action
    lua.execute('''
        local s,t,c=WORKER_STATE,WORKER_TOOLS,WORKER_CONTROLLER
        package.loaded.nixio.open=function(path)
            local fd=HOST_OPEN(path)
            return {lock=function() return HOST_LOCK(fd) end, close=function() return HOST_CLOSE(fd) end}
        end
        local fields={{items={{id="hostname",type="text",value="old",maxlength=64}}}}
        c.populate_8311_fwenvs=function() return fields end
        c.fwenvs_8311=function() return fields end
        s.environment="8311_hostname=old\\n"
        t.fwenv_set=function() return HOST_WRITE() end
        if WORKER_ACTION=="save" then
            s.form={hostname="new"}; c.action_save()
        else
            s.form={token="fixture-token",action="restore",confirm="1",content="8311_hostname=new\\n",preserve_pon="1"}
            c.action_recovery()
        end
    ''')
    print(json.dumps({"status": state.status, "success": bool(state.json and state.json.success)}))


for name, value in {"HOST_OPEN": open_lock, "HOST_LOCK": try_lock,
                    "HOST_CLOSE": close_lock, "HOST_WRITE": write_field,
                    "RUN_LOCK_WORKER": worker}.items():
    lua.globals()[name] = value
try:
    lua.execute((repo / "tests/test_lua.lua").read_text())
finally:
    for fd in list(handles):
        close_lock(fd)
