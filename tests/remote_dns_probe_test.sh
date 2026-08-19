#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
python3 - "$ROOT/scripts/phases/remote_dns_probe.py" <<'PY'
import importlib.util
import socket
import struct
import sys
import threading

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("remote_dns_probe", path)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def serve(builder):
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("127.0.0.1", 0))
    port = server.getsockname()[1]
    done = []

    def worker():
        try:
            request, address = server.recvfrom(4096)
            server.sendto(builder(request), address)
        finally:
            server.close()
            done.append(True)

    thread = threading.Thread(target=worker)
    thread.start()
    return port, thread, done

def successful_response(request):
    _, qname_end = probe.name(request, 12)
    question = request[12:qname_end + 4]
    owner = b"\xc0\x0c"
    a = owner + struct.pack("!HHI H", 1, 1, 60, 4) + socket.inet_aton("203.0.113.8")
    ns_len = 2 + 10 + 2
    target_offset = 12 + len(question) + len(a) + ns_len
    ns = owner + struct.pack("!HHI H", 2, 1, 60, 2) + struct.pack("!H", 0xC000 | target_offset)
    target = b"\x03ns1\x07example\x03com\x00"
    header = struct.pack("!HHHHHH", struct.unpack("!H", request[:2])[0], 0x8180, 1, 2, 0, 0)
    return header + question + a + ns + target

port, thread, done = serve(successful_response)
records = probe.query("127.0.0.1", "www.example.com", 1, port)
thread.join(2)
assert done and ("www.example.com", "203.0.113.8") in records
assert ("www.example.com", "ns1.example.com") in records

def malformed_response(request):
    _, qname_end = probe.name(request, 12)
    question = request[12:qname_end + 4]
    answer = b"\xc0\x0c" + struct.pack("!HHI H", 1, 1, 60, 3) + b"\x01\x02\x03"
    header = struct.pack("!HHHHHH", struct.unpack("!H", request[:2])[0], 0x8180, 1, 1, 0, 0)
    return header + question + answer

port, thread, done = serve(malformed_response)
try:
    probe.query("127.0.0.1", "www.example.com", 1, port)
except probe.DNSInfrastructure:
    pass
else:
    raise AssertionError("malformed A RDATA must be infrastructure failure")
thread.join(2)
assert done

try:
    probe.name(b"\xc0\x00", 0)
except probe.DNSInfrastructure:
    pass
else:
    raise AssertionError("compressed pointer cycle must be rejected")

answers = {
    ("1.1.1.1", "app.example.test", 2): [],
    ("1.1.1.1", "example.test", 2): [("example.test", "ns1.example.test")],
    ("1.1.1.1", "app.example.test", 1): [("app.example.test", "203.0.113.8")],
    ("8.8.8.8", "app.example.test", 1): [("app.example.test", "203.0.113.8")],
    ("1.1.1.1", "ns1.example.test", 1): [("ns1.example.test", "198.51.100.53")],
    ("198.51.100.53", "app.example.test", 1): [("app.example.test", "203.0.113.8")],
}
old_query = probe.query
probe.query = lambda server, qname, qtype: answers.get((server, qname, qtype), [])
assert probe.main("app.example.test", "203.0.113.8") == 0
answers[("8.8.8.8", "app.example.test", 1)] = [("app.example.test", "198.51.100.9")]
assert probe.main("app.example.test", "203.0.113.8") == 1
probe.query = old_query

print("remote DNS probe parser/query semantics ok")
PY
