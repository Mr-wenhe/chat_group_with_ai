"""把 src/ 上传到中继服务器并重启服务。

用法（密码只从环境变量读，不落盘、不进命令行参数）：

    python -m venv /tmp/rtdeploy && /tmp/rtdeploy/Scripts/python.exe -m pip install paramiko
    RT_HOST=1.2.3.4 RT_PASSWORD=... /tmp/rtdeploy/Scripts/python.exe scripts/deploy.py

上传后先在服务器上跑一遍测试再重启，避免把编译不过的版本推上去。

加 `RT_ALLOW_UNAUTHENTICATED=true` 会同时把服务端改成不校验共享令牌，让客户端
零配置接入。这个动作等于把中继对任何知道地址的人开放，所以必须显式要求，
部署脚本不会自己替谁做决定。
"""

import json
import os
import sys
import urllib.error
import urllib.request

import paramiko

HOST = os.environ.get("RT_HOST", "")
USER = os.environ.get("RT_USER", "root")
PASSWORD = os.environ.get("RT_PASSWORD", "")
REMOTE_DIR = os.environ.get("RT_DIR", "/opt/chat-group-realtime")
SERVICE = os.environ.get("RT_SERVICE", "chat-group-realtime")
ENV_FILE = os.environ.get("RT_ENV_FILE", "/etc/chat-group-realtime.env")
ALLOW_UNAUTHENTICATED = os.environ.get("RT_ALLOW_UNAUTHENTICATED") == "true"

# 开发开关的名字与 NODE_ENV 的约束都来自服务端 config.ts，这里只是照着写。
DEV_BYPASS_KEY = "ALLOW_UNAUTHENTICATED_DEV"


def ensure_unauthenticated_allowed(client: paramiko.SSHClient) -> None:
    """改写服务端环境文件，让它不再要求共享令牌。

    整份文件按行重建而不是就地追加：`isAuthorized` 一旦发现开发开关就直接放行，
    所以真正要保证的是**不留下会否定它的键**。`config.ts` 只在
    `NODE_ENV !== 'production'` 时才认这个开关，于是 `NODE_ENV` 也必须清掉——
    留着它会让这次部署看起来成功、实际仍然在 401。
    """
    existing = run(
        client, f"cat {ENV_FILE} 2>/dev/null || true", check=False
    ).splitlines()

    kept: list[str] = []
    dropped = 0
    for line in existing:
        if not line.strip():
            continue
        key = line.split("=", 1)[0].strip()
        # 这两个键由本函数统一决定，旧值一律丢弃。
        if key in (DEV_BYPASS_KEY, "NODE_ENV"):
            dropped += 1
            continue
        kept.append(line)
    kept.append(f"{DEV_BYPASS_KEY}=true")

    # 只打印键名：这个文件里有共享令牌，值不该出现在任何日志里。
    keys = sorted(line.split("=", 1)[0].strip() for line in kept)
    print(f"env file keys: {', '.join(keys)} ({dropped} line(s) replaced)")

    sftp = client.open_sftp()
    try:
        with sftp.file(ENV_FILE, "w") as handle:
            handle.write("\n".join(kept) + "\n")
        # 令牌还在里面，权限必须是 600。sftp 新建文件会带 umask 默认权限，
        # 所以显式设一次，而不是假设。
        sftp.chmod(ENV_FILE, 0o600)
    finally:
        sftp.close()


def request_status(url: str, body: bytes | None = None) -> tuple[int, str]:
    """发一个请求，返回 (状态码, 响应体)。非 2xx 也照常返回，不抛异常。"""
    request = urllib.request.Request(
        url,
        data=body,
        method="POST" if body is not None else "GET",
        headers={"content-type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")


def verify_public_endpoint() -> None:
    """从客户端这一侧确认线上真的在按预期工作。

    刻意不从服务器上 curl 127.0.0.1：那台机器上的回环请求拿不到响应（curl 返回
    000），加上 `-s` 把错误也吞了，先前的健康检查一直打印空白——看着像通过，
    实际什么都没验证。而且只有从这里发出去的请求，才和客户端真正会发的一样。
    """
    base = os.environ.get("RT_PUBLIC_URL", f"http://{HOST}:9210").rstrip("/")

    status, body = request_status(f"{base}/healthz")
    if status != 200 or '"ok":true' not in body.replace(" ", ""):
        raise SystemExit(f"health check returned {status}: {body}")
    print(f"healthz OK: {body.strip()}")

    # 不带任何令牌注册一个群：这是客户端零配置接入时走的第一条路。
    payload = json.dumps(
        {
            "name": "deploy-probe",
            "hostUserId": "deploy-probe",
            "hostDisplayName": "deploy-probe",
        }
    ).encode("utf-8")
    status, body = request_status(f"{base}/v1/groups", payload)

    if ALLOW_UNAUTHENTICATED:
        # 开关有没有真的生效只有这一条能证明。进程起得来、healthz 是 200，
        # 但 NODE_ENV 没清干净时每个客户端仍然会 401——那种失败必须在这里暴露。
        if status != 201:
            raise SystemExit(
                f"unauthenticated group creation returned {status}, expected 201: {body}"
            )
        print("unauthenticated group creation OK (no token needed)")
    else:
        # 反向确认：没开开关就必须真的拦住，否则"没开"是假的。
        if status != 401:
            raise SystemExit(
                f"group creation without a token returned {status}, expected 401: {body}"
            )
        print("shared token is enforced (401 without it)")


def source_files() -> list[str]:
    """本地 src/ 下的全部 .ts，外加 package.json。

    刻意不做"只传改动的文件"这种优化：漏传一个被 import 的模块，服务会以
    ERR_MODULE_NOT_FOUND 起不来，而症状只是 systemd 反复重启，很难一眼看出
    是部署少了文件。整目录覆盖既简单又不会漏。
    """
    root = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
    names = sorted(
        name for name in os.listdir(os.path.join(root, "src")) if name.endswith(".ts")
    )
    return ["package.json"] + [f"src/{name}" for name in names]


def run(client: paramiko.SSHClient, command: str, check: bool = True) -> str:
    _, stdout, stderr = client.exec_command(command, timeout=120)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if out.strip():
        print(out.rstrip())
    if err.strip():
        print(err.rstrip(), file=sys.stderr)
    if check and code != 0:
        raise SystemExit(f"command failed ({code}): {command}")
    return out


def main() -> None:
    if not HOST or not PASSWORD:
        raise SystemExit("set RT_HOST and RT_PASSWORD")

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, username=USER, password=PASSWORD, timeout=20)
    try:
        sftp = client.open_sftp()
        try:
            for relative in source_files():
                local = os.path.join(os.path.dirname(__file__), "..", relative)
                remote = f"{REMOTE_DIR}/{relative}"
                sftp.put(os.path.normpath(local), remote)
                print(f"uploaded {relative}")
        finally:
            sftp.close()

        # 先验证再重启：服务端语法/断言不过就不要让线上跑起来。
        run(client, f"cd {REMOTE_DIR} && node --experimental-strip-types --test src/*.test.ts")

        if ALLOW_UNAUTHENTICATED:
            ensure_unauthenticated_allowed(client)
        else:
            print("leaving the shared-token requirement in place")

        run(client, f"systemctl restart {SERVICE}")

        # 重启后必须确认真的起来了。服务起不来时 systemd 只会安静地反复重试，
        # 部署脚本若无条件报成功，就会把"线上其实是坏的"留到用户那一步才发现。
        state = run(client, f"systemctl is-active {SERVICE}", check=False).strip()
        if state != "active":
            run(client, f"journalctl -u {SERVICE} -n 40 --no-pager", check=False)
            raise SystemExit(f"service is {state}, not active")
    finally:
        client.close()

    # SSH 断开之后再探测：这一步验的是"外面的客户端能不能用"，
    # 不是"服务器自己觉得怎么样"。
    verify_public_endpoint()
    print("deploy OK")


if __name__ == "__main__":
    main()
