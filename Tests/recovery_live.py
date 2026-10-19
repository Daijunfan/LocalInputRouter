"""Fault injection for owned router processes; never switches or injects input."""
import json, os, signal, subprocess, time
from pathlib import Path
state_file = Path.home() / 'Library/Application Support/DJF Input Router/status.json'
result_file = Path(__file__).resolve().parents[1] / 'artifacts/recovery-20261016.json'

def state():
    return json.loads(state_file.read_text())
def ready(s):
    return s.get('connected') and s.get('voiceReady') and s.get('clipboardReady') and s.get('nativeTrackpad', {}).get('ready')
def wait_ready(old=None, key=None):
    deadline=time.monotonic()+30
    while time.monotonic()<deadline:
        s=state()
        if ready(s) and (key is None or s.get(key)!=old) and time.time()-s.get('updatedAt',0)<3:
            return s
        time.sleep(.05)
    raise RuntimeError('Recovery timed out: '+s['status'])

results=[]
try:
    before=wait_ready()
    if before['destination']!='mac': raise RuntimeError('Input must already be on Mac')
    for key, label, executable, sig in [('corePID','backend crash','DJFDeskflow',signal.SIGKILL),('tunnelPID','SSH tunnel loss','ssh',signal.SIGKILL),('pid','app crash','DJFInputRouter',signal.SIGKILL),('corePID','backend hang','DJFDeskflow',signal.SIGSTOP),('pid','app hang','DJFInputRouter',signal.SIGSTOP)]:
        before=wait_ready()
        if before['destination']!='mac': raise RuntimeError('User switched input; stop diagnostic')
        pid=before[key]
        cmd=subprocess.check_output(['ps','-p',str(pid),'-o','comm='],text=True).strip()
        if not cmd.endswith('/'+executable) and cmd!=executable: raise RuntimeError('Unexpected process '+cmd)
        start=time.monotonic()
        os.kill(pid, sig)
        after=wait_ready(pid,key)
        row={'case':label,'seconds':round(time.monotonic()-start,3),'signal':sig.value,'oldPID':pid,'newPID':after[key],
             'destination':after['destination'],'route':after['connectionRoute'],'allChannels':ready(after)}
        results.append(row); print(json.dumps(row,ensure_ascii=False),flush=True)
finally:
    result_file.write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
