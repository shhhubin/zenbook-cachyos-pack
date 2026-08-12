#!/usr/bin/env python3
"""Sustained CPU test for UM3406KA: log per-cpu freq + Tctl every 3s during 16-thread load."""
import multiprocessing as mp
import os, time, sys, json

def burn(duration_s, q):
    t0 = time.time()
    x = 0
    while time.time() - t0 < duration_s:
        for _ in range(200000):
            x = (x * 31 + 7) % 1000000007
    q.put(x)

def read_freqs():
    freqs = []
    for c in range(16):
        try:
            with open(f"/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_cur_freq") as f:
                freqs.append(int(f.read().strip()) / 1000)
        except Exception:
            freqs.append(0.0)
    return freqs

def read_tctl():
    for h in os.listdir('/sys/class/hwmon'):
        p = f"/sys/class/hwmon/{h}"
        try:
            if open(f"{p}/name").read().strip() == 'k10temp':
                return int(open(f"{p}/temp1_input").read().strip()) / 1000
        except Exception:
            pass
    return -1

def main():
    dur = float(sys.argv[1]) if len(sys.argv) > 1 else 90.0
    print(f"test_start ts={time.strftime('%H:%M:%S')} duration={dur}s procs=16")
    q = mp.Queue()
    procs = [mp.Process(target=burn, args=(dur, q)) for _ in range(16)]
    for p in procs: p.start()
    t0 = time.time()
    rows = []
    while time.time() - t0 < dur:
        time.sleep(3)
        fs = read_freqs()
        tctl = read_tctl()
        avg = sum(fs)/len(fs)
        mx = max(fs)
        rows.append([round(time.time()-t0,1), round(avg,1), round(mx,1), round(min(fs),1), round(tctl,1)])
        print(f"t={rows[-1][0]:5.1f}s avg={avg:6.1f} max={mx:6.1f} min={min(fs):6.1f} Tctl={tctl:5.1f}")
        sys.stdout.flush()
    for p in procs: p.join()
    print("test_end ts=", time.strftime('%H:%M:%S'))
    print("SUMMARY rows=", json.dumps(rows))
    print(f"AVG_avg={sum(r[1] for r in rows)/len(rows):.1f} AVG_Tctl={sum(r[4] for r in rows)/len(rows):.1f} MAX_Tctl={max(r[4] for r in rows):.1f}")

if __name__ == '__main__':
    main()
