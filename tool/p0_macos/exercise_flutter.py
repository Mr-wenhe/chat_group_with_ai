"""真实 Mac2 冷启动复测；仅对本仓库隔离 Flutter counter 样本。"""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import time
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "build/p0_macos/flutter_sample/build/macos/Build/Products/Debug/p0_flutter.app"
OUT = ROOT / "build/p0_macos/flutter-repeat"
SERVER = "http://127.0.0.1:4725"
ELEMENT = "element-6066-11e4-a52e-4f735466cecf"
BUNDLE = "com.chatgroup.p0.p0Flutter"
TRACE = []


def call(method, path, body=None):
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(SERVER + path, data=payload, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as response:
        result = json.load(response)
    # source 的系统菜单只在内存解析；不进入证据或模型上下文。
    TRACE.append({"method": method, "path": path, "body": body,
                  "result": result if path.endswith("/click") else "response received"})
    return result["value"]


def bundle_digest():
    digest = hashlib.sha256()
    for path in sorted(APP.rglob("*")):
        digest.update(str(path.relative_to(APP)).encode())
        digest.update(str(path.lstat().st_mode).encode())
        if path.is_symlink():
            digest.update(str(path.readlink()).encode())
        elif path.is_file():
            digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


def window(session):
    source = ET.fromstring(call("GET", f"/session/{session}/source"))
    target = source.find("XCUIElementTypeWindow")
    assert target is not None and target.attrib["title"] == "p0_flutter"
    return target


def wait_for_counter(session, expected):
    deadline = time.monotonic() + 15
    for _ in range(15):
        target = window(session)
        if any(node.tag == "XCUIElementTypeStaticText" and node.attrib.get("value") == str(expected)
               for node in target.iter()):
            return target
        if time.monotonic() >= deadline:
            break
        time.sleep(1)
    (OUT / f"unexpected-{expected}.xml").write_text(ET.tostring(target, encoding="unicode"))
    raise AssertionError(f"真实 Flutter 计数未达到 {expected}")


def observe(session, target, name):
    (OUT / f"{name}.xml").write_text(ET.tostring(target, encoding="unicode"))
    value = call("POST", f"/session/{session}/element",
                 {"using": "accessibility id", "value": target.attrib["identifier"]})
    image = base64.b64decode(call("GET", f"/session/{session}/element/{value[ELEMENT]}/screenshot"))
    (OUT / f"{name}.png").write_bytes(image)
    expected = str(APP / "Contents/MacOS/p0_flutter")
    processes = subprocess.check_output(["ps", "-Ao", "pid=,comm="], text=True)
    matches = [line for line in processes.splitlines() if expected in line]
    assert len(matches) == 1, "运行中的构建路径不匹配"
    (OUT / f"{name}-process.txt").write_text("\n".join(matches))


def cold_run(number):
    caps = {"platformName": "Mac", "appium:automationName": "Mac2",
            "appium:appPath": str(APP), "appium:bundleId": BUNDLE,
            "appium:systemHost": "127.0.0.1", "appium:systemPort": 10123,
            "appium:noReset": True,
            "appium:newCommandTimeout": 300,
            "appium:environment": {"P0_ENABLE_NATIVE_SEMANTICS": "1"}}
    session = call("POST", "/session", {"capabilities": {"alwaysMatch": caps}})["sessionId"]
    try:
        before = wait_for_counter(session, 0)
        observe(session, before, f"{number}-before")
        button = call("POST", f"/session/{session}/element",
                      {"using": "xpath", "value": "//XCUIElementTypeGroup[@label='p0_flutter']//XCUIElementTypeButton"})
        call("POST", f"/session/{session}/element/{button[ELEMENT]}/click", {})
        # click 返回不保证异步语义树已更新；只观察，不重放点击。
        after = wait_for_counter(session, 1)
        assert any(node.tag == "XCUIElementTypeStaticText" and node.attrib.get("value") == "1"
                   for node in after.iter())
        observe(session, after, f"{number}-after")
    finally:
        call("POST", f"/session/{session}/execute/sync",
             {"script": "macos: terminateApp", "args": [{"bundleId": BUNDLE}]})
        call("DELETE", f"/session/{session}")
        processes = subprocess.check_output(["ps", "-Ao", "comm="], text=True)
        assert str(APP / "Contents/MacOS/p0_flutter") not in processes


OUT.mkdir(exist_ok=True)
initial_digest = bundle_digest()
try:
    cold_run(1)
    cold_run(2)
    assert bundle_digest() == initial_digest, "操作修改了候选包"
    (OUT / "result.json").write_text(json.dumps({"coldRuns": 2, "counterTransitions": [[0, 1], [0, 1]],
                                               "bundleDigest": initial_digest, "bundleUnchanged": True,
                                               "targetProcessesExited": True}, indent=2))
finally:
    (OUT / "actions.json").write_text(json.dumps(TRACE, ensure_ascii=False, indent=2))
