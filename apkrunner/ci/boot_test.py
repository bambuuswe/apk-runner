#!/usr/bin/env python3
"""
Boots the Android VM in QEMU on a Linux CI runner, the same way the iOS app
does, and optionally checks that an APK handed over by a stand-in for the iOS
app gets installed and launched.

Modes:
  firstboot  boot once so Android finishes its first-boot setup; the guest
             shuts itself down (see apkrunner.sh)
  test       serve a test APK over the APK Runner protocol and wait until the
             guest reports it launched; screenshots are saved along the way
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time

PORT = 47123


class ApkServer(threading.Thread):
    """Same protocol as Platform/iOS/UTMAPKRunner.swift: 8 byte big-endian
    length, then the APK bytes. Length 0 means nothing queued."""

    def __init__(self, apk_path):
        super().__init__(daemon=True)
        self.pending = [apk_path] if apk_path else []
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", PORT))
        self.sock.listen(4)
        self.polls = 0

    def run(self):
        while True:
            conn, _ = self.sock.accept()
            self.polls += 1
            try:
                if self.pending:
                    path = self.pending[0]
                    with open(path, "rb") as f:
                        data = f.read()
                    conn.sendall(len(data).to_bytes(8, "big") + data)
                    self.pending.pop(0)
                    print(f"[server] sent {path} ({len(data)} bytes)", flush=True)
                else:
                    conn.sendall((0).to_bytes(8, "big"))
            except OSError as e:
                print(f"[server] error: {e}", flush=True)
            finally:
                conn.close()


class Qmp:
    def __init__(self, path):
        for _ in range(100):
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError("QMP socket not available")
        self.file = self.sock.makefile("rw")
        self._read()  # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        while True:
            line = self.file.readline()
            if not line:
                raise RuntimeError("QMP closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            return msg

    def cmd(self, name, **args):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self.file.write(json.dumps(req) + "\n")
        self.file.flush()
        return self._read()


def screenshot(qmp, path):
    try:
        res = qmp.cmd("screendump", filename=path, format="png")
        if "error" in res:
            ppm = path[:-4] + ".ppm"
            qmp.cmd("screendump", filename=ppm)
            subprocess.run(["convert", ppm, path], check=False)
            if os.path.exists(path):
                os.remove(ppm)
    except Exception as e:  # noqa: BLE001
        print(f"screenshot failed: {e}", flush=True)


DIAGNOSTICS = [
    "echo ==== diagnostics",
    "ip addr",
    "ip rule",
    "ip route show table all",
    "getprop | grep -iE 'dhcp|net\\.|eth|wifi'",
    "dumpsys connectivity | head -40",
    "cat /data/local/tmp/apkrunner/log.txt",
    "ps -A | grep -iE 'apk|dhcp'",
    "logcat -d -s EthernetTracker IpClient Ethernet EthernetNetworkFactory | tail -40",
    "echo ==== end",
]


def console_diagnostics(path):
    """Types commands into the guest's root console; output lands in serial.log."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(path)
        s.sendall(b"\n")
        time.sleep(1)
        for cmd in DIAGNOSTICS:
            s.sendall(cmd.encode() + b"\n")
            time.sleep(2)
        time.sleep(3)
        s.close()
    except OSError as e:
        print(f"console diagnostics failed: {e}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vm", required=True, help="AndroidVM directory")
    ap.add_argument("--image", help="disk image (default: <vm>/android.qcow2)")
    ap.add_argument("--mode", choices=["firstboot", "test"], required=True)
    ap.add_argument("--apk")
    ap.add_argument("--display", default="VGA")
    ap.add_argument("--outdir", default="boot-test")
    ap.add_argument("--timeout", type=int, default=1200)
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    image = args.image or os.path.join(args.vm, "android.qcow2")
    with open(os.path.join(args.vm, "cmdline.txt")) as f:
        cmdline = f.read().split()
    cmdline = [c for c in cmdline if c != "quiet"]
    cmdline += ["console=ttyS0", f"apkrunner.ci={args.mode}"]

    server = None
    if args.mode == "test":
        server = ApkServer(args.apk)
        server.start()

    accel = "kvm" if os.access("/dev/kvm", os.R_OK | os.W_OK) else "tcg"
    serial_log = os.path.join(args.outdir, "serial.log")
    serial_sock = os.path.join(args.outdir, "serial.sock")
    qmp_path = os.path.join(args.outdir, "qmp.sock")
    for path in (qmp_path, serial_sock, serial_log):
        if os.path.exists(path):
            os.remove(path)
    qemu = [
        "qemu-system-x86_64",
        "-machine", f"q35,accel={accel}",
        "-cpu", "Nehalem",
        "-smp", "2",
        "-m", "2048",
        "-kernel", os.path.join(args.vm, "vmlinuz"),
        "-initrd", os.path.join(args.vm, "initrd.img"),
        "-append", " ".join(cmdline),
        "-drive", f"file={image},if=none,id=d0,format=qcow2",
        "-device", "virtio-blk-pci,drive=d0",
        "-device", args.display,
        "-display", "none",
        "-netdev", "user,id=n0",
        "-device", "virtio-net-pci,netdev=n0",
        "-device", "qemu-xhci",
        "-device", "usb-tablet",
        "-device", "usb-kbd",
        "-device", "virtio-rng-pci",
        # the guest runs a root shell on the serial console (userdebug build);
        # the socket lets this script type diagnostics into it
        "-chardev", f"socket,id=ser0,path={serial_sock},server=on,wait=off,logfile={serial_log}",
        "-serial", "chardev:ser0",
        "-qmp", f"unix:{qmp_path},server=on,wait=off",
        "-no-reboot",
    ]
    print(f"accel={accel}", flush=True)
    print(" ".join(qemu), flush=True)
    proc = subprocess.Popen(qemu)
    qmp = Qmp(qmp_path)

    start = time.time()
    shot = 0
    next_shot = start + 20
    success = False
    launched_at = None
    while time.time() - start < args.timeout:
        if proc.poll() is not None:
            break
        now = time.time()
        if now >= next_shot:
            shot += 1
            screenshot(qmp, os.path.join(args.outdir, f"shot-{shot:03d}-{int(now - start)}s.png"))
            next_shot = now + 30
        try:
            with open(serial_log, errors="replace") as f:
                log = f.read()
        except OSError:
            log = ""
        if args.mode == "test" and launched_at is None and "apkrunner: launched com.apkrunner.test" in log:
            launched_at = now
            print(f"test app launched after {int(now - start)}s", flush=True)
        if launched_at is not None and now - launched_at > 30:
            screenshot(qmp, os.path.join(args.outdir, "final.png"))
            success = True
            break
        time.sleep(2)

    elapsed = int(time.time() - start)
    if args.mode == "firstboot":
        if proc.poll() is None:
            print(f"guest did not power off within {args.timeout}s", flush=True)
            screenshot(qmp, os.path.join(args.outdir, "final.png"))
            proc.kill()
        else:
            # only apkrunner.sh powers the guest off, after Android finished booting
            with open(serial_log, errors="replace") as f:
                marker = "first boot setup done" in f.read()
            success = proc.returncode == 0
            print(f"guest powered off after {elapsed}s (exit {proc.returncode}), setup marker found: {marker}", flush=True)
    else:
        if proc.poll() is None:
            console_diagnostics(serial_sock)
            try:
                qmp.cmd("quit")
            except Exception:  # noqa: BLE001
                proc.kill()
        if server:
            print(f"[server] guest polled {server.polls} times", flush=True)
        print(f"test {'passed' if success else 'FAILED'} after {elapsed}s", flush=True)
    proc.wait(timeout=60)
    with open(serial_log, errors="replace") as f:
        print("--- serial console (last 200 lines)", flush=True)
        print("".join(f.readlines()[-200:]), flush=True)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
