"""Binary-safe cart-only export/restore over a verified TLS port-forward."""
import base64
import contextlib
import hashlib
import json
import socket
import ssl
import subprocess
import tempfile
import time
from pathlib import Path

from common import get, require, utc


class Redis:
    def __init__(self, connection):
        self.connection = connection
        self.reader = connection.makefile("rb")

    def command(self, *args):
        parts = [a if isinstance(a, bytes) else str(a).encode() for a in args]
        wire = b"*%d\r\n" % len(parts)
        for part in parts:
            wire += b"$%d\r\n" % len(part) + part + b"\r\n"
        self.connection.sendall(wire)
        return self.response()

    def response(self):
        line = self.reader.readline()
        require(line.endswith(b"\r\n"), "Redis connection closed")
        kind, value = line[:1], line[1:-2]
        if kind == b"-":
            raise RuntimeError("Redis command failed (server response redacted)")
        if kind == b"+":
            return value
        if kind == b":":
            return int(value)
        if kind == b"$":
            length = int(value)
            if length == -1:
                return None
            result = self.reader.read(length)
            require(len(result) == length and self.reader.read(2) == b"\r\n", "invalid RESP bulk")
            return result
        if kind == b"*":
            return [self.response() for _ in range(int(value))]
        raise RuntimeError("unsupported RESP response")


@contextlib.contextmanager
def connect(namespace="redis"):
    import os
    auth = get("secret", "redis-auth", namespace)["data"]
    cert = get("secret", "redis-server-mtls-cert", namespace)["data"]
    # Dedicated, short-lived local port-forward; no credentials in argv or output.
    args = ["kubectl", "--request-timeout=30s"]
    args += ["--kubeconfig", os.environ["KUBECONFIG"]] if os.environ.get("KUBECONFIG") else ["--context", "petflow-dev"]
    args += ["-n", namespace, "port-forward", "--address=127.0.0.1", "svc/redis-master", ":6379"]
    with tempfile.TemporaryFile(mode="w+") as output:
        proc = subprocess.Popen(args, stdout=output, stderr=output, universal_newlines=True)
        try:
            import re
            port = None
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                output.seek(0)
                match = re.search(r"Forwarding from 127\.0\.0\.1:(\d+)", output.read())
                if match:
                    port = int(match.group(1))
                    break
                require(proc.poll() is None, "Redis port-forward failed")
                time.sleep(0.2)
            require(port is not None, "Redis port-forward timed out")
            ca = base64.b64decode(cert["ca.crt"]).decode()
            context = ssl.create_default_context(cadata=ca)
            raw = socket.create_connection(("127.0.0.1", port), timeout=60)
            connection = context.wrap_socket(raw, server_hostname="redis-master." + namespace + ".svc.cluster.local")
            try:
                client = Redis(connection)
                client.command("AUTH", base64.b64decode(auth["redis-password"]))
                yield client
            finally:
                connection.close()
        finally:
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=10)


def keys(client):
    cursor, seen = b"0", set()
    while True:
        cursor, batch = client.command("SCAN", cursor, "MATCH", "cart:*", "COUNT", 500)
        for key in batch:
            require(key.startswith(b"cart:"), "non-cart key")
            if key not in seen:
                seen.add(key)
                yield key
        if cursor == b"0":
            break


def capture(client, databases):
    records = []
    # Read value and expiration in one atomic Redis command, including expiry races.
    script = ("local v=redis.call('DUMP',KEYS[1]); if not v then return {} end; "
              "return {v,redis.call('PEXPIRETIME',KEYS[1]),redis.call('TYPE',KEYS[1]).ok}")
    for database in databases:
        client.command("SELECT", database)
        for key in keys(client):
            result = client.command("EVAL", script, 1, key)
            if not result:
                continue
            value, expires, kind = result
            require(expires == -1 or expires > 0, "invalid cart expiration")
            records.append({"db": database, "key": base64.b64encode(key).decode(),
                            "dump": base64.b64encode(value).decode(),
                            "expiresAtMs": None if expires == -1 else expires,
                            "type": kind.decode()})
    return sorted(records, key=lambda r: (r["db"], r["key"]))


def fingerprint(records):
    return hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest()


def export_cart(databases):
    with connect() as client:
        records = capture(client, databases)
        version = client.command("INFO", "server").decode()
        version = next(line.split(":", 1)[1].strip() for line in version.splitlines()
                       if line.startswith("redis_version:"))
    return {"schemaVersion": 1, "redisVersion": version, "databases": databases, "extractedAt": utc(),
            "records": records, "count": len(records), "fingerprint": fingerprint(records)}


def validate_payload(payload):
    require(payload.get("schemaVersion") == 1, "invalid cart backup format")
    require(payload.get("databases") == [0], "only Redis database 0 is qualified")
    records = payload["records"]
    require(payload["count"] == len(records), "cart count mismatch")
    require(payload["fingerprint"] == fingerprint(records), "cart content checksum mismatch")
    seen = set()
    for record in records:
        key = base64.b64decode(record["key"], validate=True)
        base64.b64decode(record["dump"], validate=True)
        require(key.startswith(b"cart:") and record["db"] in payload["databases"], "cart allowlist violation")
        require((record["db"], key) not in seen, "duplicate cart key")
        seen.add((record["db"], key))
        require(record["expiresAtMs"] is None or record["expiresAtMs"] > 0, "invalid expiration")


def assert_unchanged(payload):
    with connect() as client:
        actual = capture(client, payload["databases"])
        now = client.command("TIME")
        now_ms = int(now[0]) * 1000 + int(now[1]) // 1000
        expected = [r for r in payload["records"] if r["expiresAtMs"] is None or r["expiresAtMs"] > now_ms]
        actual = [r for r in actual if r["expiresAtMs"] is None or r["expiresAtMs"] > now_ms]
        require(fingerprint(expected) == fingerprint(actual), "cart data changed during maintenance")


def restore_cart(payload, allow_partial=False):
    validate_payload(payload)
    databases = payload["databases"]
    with connect() as client:
        server = client.command("INFO", "server").decode()
        version = next(line.split(":", 1)[1].strip() for line in server.splitlines()
                       if line.startswith("redis_version:"))
        require(version == payload["redisVersion"], "Redis version differs from backup")
        for database in databases:
            client.command("SELECT", database)
            if not allow_partial:
                require(client.command("DBSIZE") == 0, "refusing to overwrite nonempty Redis")
        present = capture(client, databases) if allow_partial else []
        expected_by_key = {(r["db"], r["key"]): r for r in payload["records"]}
        present_by_key = {(r["db"], r["key"]): r for r in present}
        for key, record in present_by_key.items():
            require(expected_by_key.get(key) == record, "partial cart restore contains unexpected or modified data")
        for database in databases:
            client.command("SELECT", database)
            require(client.command("DBSIZE") == len([r for r in present if r["db"] == database]),
                    "non-cart keys exist during partial restore")
        now = client.command("TIME")
        now_ms = int(now[0]) * 1000 + int(now[1]) // 1000
        restored, expired = 0, 0
        for record in payload["records"]:
            expiry = record["expiresAtMs"]
            if expiry is not None and expiry <= now_ms:
                expired += 1
                continue
            if (record["db"], record["key"]) in present_by_key:
                restored += 1
                continue
            client.command("SELECT", record["db"])
            arguments = ["RESTORE", base64.b64decode(record["key"]), expiry or 0,
                         base64.b64decode(record["dump"])]
            if expiry is not None:
                arguments.append("ABSTTL")
            client.command(*arguments)
            restored += 1
        # Ensure writes have reached AOF; Redis 7.4 supports WAITAOF.
        require(client.command("WAITAOF", 1, 0, 30000)[0] == 1, "AOF fsync not confirmed")
        actual = capture(client, databases)
        now = client.command("TIME")
        now_ms = int(now[0]) * 1000 + int(now[1]) // 1000
        expected = [r for r in payload["records"] if r["expiresAtMs"] is None or r["expiresAtMs"] > now_ms]
        # Keys expiring during verification must be ignored on both sides.
        actual = [r for r in actual if r["expiresAtMs"] is None or r["expiresAtMs"] > now_ms]
        require(fingerprint(actual) == fingerprint(expected), "restored cart contents differ")
        for database in databases:
            client.command("SELECT", database)
            require(client.command("DBSIZE") == len([r for r in actual if r["db"] == database]),
                    "unexpected non-cart keys after restore")
    return {"restored": restored, "expired": expired, "verified": True, "aofFsyncVerified": True}
