# PROTOTYPE driver: run `claude` in a pty, press Ctrl+V, report what appeared and how fast.
import os, pty, select, sys, time, re, fcntl, termios, struct
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.chdir("/workspaces/blueprint-nuxt-module")
    os.execvp("claude", ["claude"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
buf = b""
def strip(b):
    s = b.decode("utf-8","replace")
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>]|\x1b\[<u", "", s)
def pump_until(pat, secs):
    global buf
    end = time.time()+secs
    while time.time() < end:
        r,_,_ = select.select([fd],[],[],0.1)
        if r:
            try: buf += os.read(fd, 65536)
            except OSError: break
        if pat and re.search(pat, strip(buf)): return True
    return False
pump_until(r"Try \"", 15)
os.write(fd, b"hello "); pump_until(None, 0.5)
mark = len(strip(buf))
t0=time.time(); os.write(fd, b"\x16")
hit = pump_until(r"\[Image ?#\d+\]|No image found|hello \S", 6); dt=time.time()-t0
out = strip(buf)[mark:]
chip = re.search(r"\[Image ?#\d+\]", out); toast = re.search(r"No image found[^\n]*", out)
print("RESULT: chip=%s toast=%s ctrl+v->visible=%.2fs" % (chip.group(0) if chip else None, toast.group(0)[:60] if toast else None, dt))
print("TAIL:", re.sub(r"[─]+", "", out)[-400:].replace("\n"," "))
os.write(fd, b"\x03"); time.sleep(0.3); os.write(fd, b"\x03"); time.sleep(0.5)
try: os.kill(pid, 9)
except: pass
