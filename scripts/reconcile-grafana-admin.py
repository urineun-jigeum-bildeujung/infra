#!/usr/bin/env python3
"""Reconcile the chart's admin Secret with Grafana's persistent database."""
import base64
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request


CONTEXT = os.environ.get("KUBE_CONTEXT", "petflow-dev")
KUBE = ["kubectl", "--context", CONTEXT, "--request-timeout=30s", "-n", "observability"]


def run(args, input_data=None):
    result = subprocess.run(args, input=input_data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, universal_newlines=True)
    if result.returncode:
        raise RuntimeError("Grafana 관리자 복구 명령 실패 (비밀번호/응답 본문 비공개)")
    return result.stdout


def status(url, user=None, password=None):
    headers = {}
    if user is not None:
        token = base64.b64encode((user + ":" + password).encode()).decode()
        headers["Authorization"] = "Basic " + token
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=10) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


def reconcile(url, user, password):
    code = status(url + "/api/user", user, password)
    if code == 200:
        print("[grafana-admin] 관리자 Secret 인증 확인 완료")
        return
    if code != 401 or user != "admin":
        raise RuntimeError("Grafana 관리자 인증 확인 실패: HTTP {}".format(code))
    # Grafana initializes user 1 once; later Helm Secret updates do not update
    # its SQLite password. Feed the existing Secret through stdin only.
    run(KUBE + ["exec", "-i", "statefulset/kube-prometheus-stack-grafana", "-c", "grafana", "--",
                "grafana", "cli", "--homepath", "/usr/share/grafana", "--config", "/etc/grafana/grafana.ini",
                "admin", "reset-admin-password", "--password-from-stdin", "--user-id", "1"], password + "\n")
    # The running Grafana process can retain its previous authentication cache
    # briefly after the CLI commits the new password to SQLite.
    verified = False
    for attempt in range(15):
        code = status(url + "/api/user", user, password)
        if code == 200:
            verified = True
            break
        if code != 401:
            break
        if attempt < 14:
            time.sleep(2)
    if not verified:
        raise RuntimeError("Grafana 관리자 Secret 동기화 후 인증 실패")
    print("[grafana-admin] 기존 관리자 Secret으로 DB 비밀번호 동기화 및 인증 확인 완료 (값 비공개)")


def main():
    secret = json.loads(run(KUBE + ["get", "secret", "kube-prometheus-stack-grafana", "-o", "json"]))
    user = base64.b64decode(secret["data"]["admin-user"]).decode()
    password = base64.b64decode(secret["data"]["admin-password"]).decode()
    if not user or len(password) < 16 or any(c in password for c in "\r\n"):
        raise RuntimeError("Grafana 관리자 Secret 형식/길이 검증 실패")
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    url = "http://127.0.0.1:" + str(port)
    forward = subprocess.Popen(KUBE + ["port-forward", "--address", "127.0.0.1",
                               "service/kube-prometheus-stack-grafana", str(port) + ":80"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if forward.poll() is not None:
                raise RuntimeError("Grafana port-forward 시작 실패")
            try:
                if status(url + "/api/health") == 200:
                    reconcile(url, user, password)
                    return
            except (urllib.error.URLError, OSError):
                pass
            time.sleep(2)
        raise RuntimeError("Grafana API 준비 시간 초과")
    finally:
        forward.terminate()
        forward.wait(timeout=10)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Exception text can include credential-bearing HTTP details.
        print("[grafana-admin] ERROR: 관리자 인증/동기화 실패. Secret과 Grafana 상태를 확인하세요 (값 비공개).", file=sys.stderr)
        sys.exit(1)
