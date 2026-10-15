"""P0 现场脚本；需要已启动的 loopback Appium 和指定样本会话。"""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/p0_macos"
SESSION = json.loads((OUT / "session-response.json").read_text())["value"]["sessionId"]
BASE = "http://127.0.0.1:4725/session/" + SESSION
KEY = "element-6066-11e4-a52e-4f735466cecf"
VARIANT = sys.argv[1]
assert VARIANT in ("bug", "fixed")
APP = OUT / VARIANT / "P0Sample.app"
BUNDLE_ID = "com.chatgroup.p0.sample"
TRACE = []
PAUSED = False


def request(method, path, body=None):
    if PAUSED and method != "GET":
        raise RuntimeError("P0 操作已暂停")
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=payload, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as response:
        value = json.load(response)["value"]
    TRACE.append({"method": method, "path": path, "body": body})
    return value


def execute(script, arguments):
    return request("POST", "/execute/sync", {"script": script, "args": [arguments]})


def element(identifier):
    return request("POST", "/element", {"using": "accessibility id", "value": identifier})[KEY]


def observe(name):
    tree = ET.fromstring(request("GET", "/source"))
    window = tree.find("XCUIElementTypeWindow")
    assert window is not None and window.attrib["identifier"] == "p0-window"
    (OUT / f"{VARIANT}-{name}.xml").write_text(ET.tostring(window, encoding="unicode"))
    screenshot = request("GET", "/element/" + element("p0-window") + "/screenshot")
    (OUT / f"{VARIANT}-{name}.png").write_bytes(base64.b64decode(screenshot))
    processes = subprocess.check_output(["ps", "-Ao", "pid=,comm="], text=True)
    matching = [line for line in processes.splitlines() if str(APP / "Contents/MacOS/P0Sample") in line]
    assert len(matching) == 1, "运行路径与本轮构建不一致"
    (OUT / f"{VARIANT}-{name}-process.txt").write_text("\n".join(matching))
    image = (OUT / f"{VARIANT}-{name}.png").read_bytes()
    width = int.from_bytes(image[16:20], "big")
    height = int.from_bytes(image[20:24], "big")
    (OUT / f"{VARIANT}-{name}-geometry.json").write_text(json.dumps(
        {"window": window.attrib, "imagePixels": [width, height],
         "scale": [width / float(window.attrib["width"]), height / float(window.attrib["height"])]}))
    return window


try:
    observe("before")
    field = element("p0-note")
    request("POST", f"/element/{field}/click", {})
    request("POST", f"/element/{field}/clear", {})
    note = "P0-" + VARIANT + "-重启核对"
    request("POST", f"/element/{field}/value", {"text": note})
    request("POST", "/element/" + element("p0-save") + "/click", {})
    after = observe("saved")
    assert any(node.attrib.get("value") == "已保存：" + note for node in after.iter())
    execute("macos: terminateApp", {"bundleId": BUNDLE_ID})
    execute("macos: launchApp", {"bundleId": BUNDLE_ID, "path": str(APP),
                               "environment": {"P0_DATA_DIR": str(OUT / "data")}})
    reopened = observe("reopened")
    actual = next(node.attrib["value"] for node in reopened.iter()
                  if node.attrib.get("identifier") == "p0-note")
    persisted = (OUT / "data/note.txt").read_text()
    assert actual == persisted
    assert (actual == note) == (VARIANT == "fixed"), "故障版应检测到不一致；修复版必须一致"
    if VARIANT == "fixed":
        rect = {key: float(reopened.attrib[key]) for key in ("x", "y", "width", "height")}
        execute("macos: clickAndDrag", {"duration": 1,
                "startX": rect["x"] + rect["width"] - 1,
                "startY": rect["y"] + rect["height"] - 1,
                "endX": rect["x"] + rect["width"] + 99,
                "endY": rect["y"] + rect["height"] + 79})
        resized = observe("resized")
        assert float(resized.attrib["width"]) > rect["width"]
        pending_save = element("p0-save")
        before_pause = hashlib.sha256((OUT / "data/note.txt").read_bytes()).hexdigest()
        action_count = len(TRACE)
        PAUSED = True
        try:
            request("POST", f"/element/{pending_save}/click", {})
            raise AssertionError("暂停未拦截")
        except RuntimeError:
            pass
        assert len(TRACE) == action_count
        assert hashlib.sha256((OUT / "data/note.txt").read_bytes()).hexdigest() == before_pause
        PAUSED = False
        execute("macos: terminateApp", {"bundleId": BUNDLE_ID})
        request("DELETE", "")
        processes = subprocess.check_output(["ps", "-Ao", "comm="], text=True)
        assert str(APP / "Contents/MacOS/P0Sample") not in processes
        (OUT / "control-result.json").write_text(json.dumps(
            {"pauseBlockedBeforeDispatch": True, "dataUnchanged": True,
             "targetProcessExited": True, "sessionDeleted": True}))
    (OUT / f"{VARIANT}-result.json").write_text(json.dumps(
        {"expected": note, "actual": actual, "defectDetected": actual != note}, ensure_ascii=False))
finally:
    (OUT / f"{VARIANT}-actions.json").write_text(json.dumps(TRACE, ensure_ascii=False, indent=2))
