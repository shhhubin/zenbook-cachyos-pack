#!/usr/bin/env python3
"""4-thread test (realistic single AI request / light build) with freq + Tctl logging."""
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
    return [int(open(f"/sys/devices/system/cpu/cpu{c}/cpufreq/scaling_cur_freq").read().strip())/1000 for c in range(16)]

def read_tctl():
    for h in os.listdir('/sys/class/hwmon'):
        p = f"/sys/class/hwmon/{h}"
        try:
            if open(f"{p}/name").read().strip() == 'k10temp':
                return int(open(f"{p}/temp1_input").read().strip())/1000
        except Exception:
            pass
    return -1

def main():
    nproc = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    dur = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    print(f"test_start procs={nproc} duration={dur}s profile={open('/sys/firmware/acpi/platform_profile').read().strip()} epp={open('/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference').read().strip()}")
    q = mp.Queue()
    procs = [mp.Process(target=burn, args=(dur, q)) for _ in range(nproc)]
    for p in procs: p.start()
    t0 = time.time(); rows = []
    while time.time() - t0 < dur:
        time.sleep(3)
        fs = read_freqs(); tctl = read_tctl()
        active = sorted(fs, reverse=True)[:nproc]
        rows.append([round(time.time()-t0,1), round(sum(active)/len(active),1), round(max(fs),1), round(min(fs),1), round(tctl,1)])
        print(f"t={rows[-1][0]:5.1f}s top{nproc}avg={rows[-1][1]:6.1f} max={rows[-1][2]:6.1f} min={rows[-1][3]:6.1f} Tctl={rows[-1][4]:5.1f}")
        sys.stdout.flush()
    for p in procs: p.join()
    print("test_end")
    print(f"AVG_top{nproc}={sum(r[1] for r in rows)/len(rows):.1f} MAX_Tctl={max(r[4] for r in rows):.1f}")

if __name__ == '__main__':
    main()
