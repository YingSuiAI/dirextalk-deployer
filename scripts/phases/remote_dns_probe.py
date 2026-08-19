#!/usr/bin/env python3
"""Bounded DNS proof executed on the deployed host before Caddy is started."""
import random
import socket
import struct
import sys

class DNSInfrastructure(Exception):
    pass

def name(data, offset):
    labels = []
    seen = set()
    while True:
        if offset >= len(data):
            raise DNSInfrastructure()
        length = data[offset]
        if length == 0:
            return ".".join(labels), offset + 1
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(data):
                raise DNSInfrastructure()
            pointer = ((length & 0x3F) << 8) | data[offset + 1]
            if pointer in seen:
                raise DNSInfrastructure()
            seen.add(pointer)
            pointed, _ = name(data, pointer)
            labels.append(pointed)
            return ".".join(labels), offset + 2
        if length > 63 or offset + 1 + length > len(data):
            raise DNSInfrastructure()
        labels.append(data[offset + 1:offset + 1 + length].decode("ascii", "ignore"))
        offset += 1 + length

def query(server, qname, qtype):
    ident = random.randrange(1, 65535)
    labels = qname.rstrip(".").split(".")
    question = b"".join(bytes([len(label)]) + label.encode("idna") for label in labels) + b"\0"
    packet = struct.pack("!HHHHHH", ident, 0x0100, 1, 0, 0, 0) + question + struct.pack("!HH", qtype, 1)
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(3)
        sock.sendto(packet, (server, 53))
        data, _ = sock.recvfrom(4096)
    except (OSError, socket.timeout) as exc:
        raise DNSInfrastructure() from exc
    finally:
        try:
            sock.close()
        except Exception:
            pass
    if len(data) < 12 or struct.unpack("!H", data[:2])[0] != ident:
        raise DNSInfrastructure()
    flags = struct.unpack("!H", data[2:4])[0]
    rcode = flags & 15
    if rcode == 3:
        return []
    if rcode != 0:
        raise DNSInfrastructure()
    qd, an, ns, ar = struct.unpack("!HHHH", data[4:12])
    offset = 12
    for _ in range(qd):
        _, offset = name(data, offset)
        offset += 4
    records = []
    for _ in range(an + ns + ar):
        owner, offset = name(data, offset)
        if offset + 10 > len(data):
            raise DNSInfrastructure()
        rtype, _, _, rdlen = struct.unpack("!HHI H", data[offset:offset + 10])
        offset += 10
        rdata = data[offset:offset + rdlen]
        offset += rdlen
        if rtype == 1 and rdlen == 4:
            records.append((owner, socket.inet_ntoa(rdata)))
        elif rtype == 2:
            target, _ = name(data, offset - rdlen)
            records.append((owner, target.rstrip(".")))
    return records

def ns_servers(domain):
    labels = domain.rstrip(".").split(".")
    for index in range(len(labels) - 1):
        zone = ".".join(labels[index:])
        records = query("1.1.1.1", zone, 2)
        servers = [value for _, value in records if value]
        if servers:
            return servers
    return []

def main(domain, wanted):
    servers = ns_servers(domain)
    if not servers:
        return 1
    for resolver in ("1.1.1.1", "8.8.8.8"):
        records = query(resolver, domain, 1)
        if wanted not in [value for _, value in records]:
            return 1
    for server_name in servers:
        addresses = query("1.1.1.1", server_name, 1)
        addresses = [value for _, value in addresses]
        if not addresses:
            return 1
        for address in addresses:
            records = query(address, domain, 1)
            if wanted not in [value for _, value in records]:
                return 1
    return 0

try:
    sys.exit(main(sys.argv[1], sys.argv[2]))
except (DNSInfrastructure, IndexError, ValueError):
    sys.exit(2)
