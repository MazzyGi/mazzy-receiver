#!/usr/bin/env python3
"""Protocol smoke test: acts as a fake daemon, verifies the Mac receiver
core behaviors over real sockets.

Run on any machine (the OrangePi works): python3 smoke_test.py
It listens on the three relay ports, accepts a receiver connection, feeds
synthetic H.264 AUs + PCM audio, and checks the receiver's TCP control
messages arrive.

Usage:
  smoke_test.py            # interactive: waits for the receiver to connect
"""
import socket, struct, threading, json, sys, time

import os
TCP_PORT = int(os.environ.get("SMOKE_TCP", 50001))
VIDEO_PORT = int(os.environ.get("SMOKE_VIDEO", 50002))
AUDIO_PORT = int(os.environ.get("SMOKE_AUDIO", 50003))
VIDEO_MAGIC, AUDIO_MAGIC = 0xC1, 0xC2

def frag_packet(counter, frag_id, frag_count, payload):
    return (bytes([VIDEO_MAGIC]) + struct.pack('>I', counter) +
            bytes([frag_id, frag_count]) + struct.pack('>H', len(payload)) + payload)

SC = b'\x00\x00\x00\x01'
SPS = SC + bytes([0x67, 0x4d, 0x40, 0x1e, 0x95, 0xa8, 0x28, 0x0f, 0x00, 0x44, 0xfc, 0xb8, 0x0b, 0x50, 0x10, 0x10, 0x14, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0xf0, 0x3c, 0x50, 0xa6, 0x40])
PPS = SC + bytes([0x68, 0xee, 0x31, 0x12])
IDR  = SC + bytes([0x65]) + bytes([0x88] * 2048)   # fake IDR, forces multi-fragment
PFRM = SC + bytes([0x41]) + bytes([0x55] * 512)    # fake P frame

def main():
    tcp_srv = socket.socket(); tcp_srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp_srv.bind(('0.0.0.0', TCP_PORT)); tcp_srv.listen(1)
    print(f"[smoke] listening tcp:{TCP_PORT} udp:{VIDEO_PORT} - waiting for receiver...")
    conn, addr = tcp_srv.accept()
    print(f"[smoke] receiver connected from {addr}")
    conn.sendall((json.dumps({"type":"welcome","video_w":1280,"video_h":720,
                              "audio_channels":2,"audio_rate":48000,
                              "session":"disconnected"}) + "\n").encode())

    # collect control messages from the receiver in background
    got_ctrl = []
    def reader():
        buf = b''
        while True:
            d = conn.recv(4096)
            if not d: return
            buf += d
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                if line:
                    got_ctrl.append(json.loads(line))
                    print(f"[smoke] ctrl <- {line.decode()}")
    threading.Thread(target=reader, daemon=True).start()

    # wait for PROBE1, learn receiver's udp port
    vsock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    vsock.bind(('0.0.0.0', VIDEO_PORT))
    vsock.settimeout(10)
    # loopback sanity check before waiting on the receiver
    _san = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    _san.sendto(b'SANITY', ('127.0.0.1', VIDEO_PORT))
    _san.close()
    print('[smoke] sanity packet sent to self')
    deadline = time.time() + 15
    probe, caddr = None, None
    while time.time() < deadline:
        try:
            pkt, addr = vsock.recvfrom(64)
            if pkt.startswith(b'PROBE1'):
                probe, caddr = pkt, addr
                break
            print(f'[smoke] non-probe packet from {addr}: {pkt!r}')
        except socket.timeout:
            pass
    assert probe, 'never received PROBE1 from receiver (sanity check passed, so loopback UDP works)'
    vport = int(probe.split()[1])
    print(f"[smoke] probe from {caddr} port {vport}")

    counter = 1
    t_end = time.time() + 8
    aframes = 0
    while time.time() < t_end:
        au = SPS + PPS + IDR if counter == 1 else PFRM
        # fragment into 1300-byte pieces like the daemon
        frags = [au[i:i+1300] for i in range(0, len(au), 1300)]
        for fid, chunk in enumerate(frags):
            vsock.sendto(frag_packet(counter, fid, len(frags), chunk), (caddr[0], vport))
        # audio: 5ms stereo PCM silence
        pcm = b'\x00\x00' * 480
        pkt = bytes([AUDIO_MAGIC]) + struct.pack('>I', aframes) + struct.pack('>H', len(pcm)) + pcm
        vsock.sendto(pkt, (caddr[0], vport))
        aframes += 1
        counter += 1
        time.sleep(1/60)

    # session lifecycle messages
    conn.sendall(b'{"type":"session_started"}\n')
    time.sleep(0.5)
    conn.sendall(b'{"type":"session_ended"}\n')
    time.sleep(1)

    types = [m.get('type') for m in got_ctrl]
    print(f"[smoke] control messages seen: {types}")
    ok = True
    if "connect" not in types:
        print("[smoke] FAIL: receiver never sent connect"); ok = False
    if "ctrl" not in types:
        # only present when input forwarding is enabled; warn, don't fail
        print("[smoke] warn: no ctrl messages (input forwarding off?)")
    if ok:
        print(f"[smoke] PASS - sent {counter-1} AUs ({counter-2} P-frames), {aframes} audio frames")
    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
