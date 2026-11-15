"""Static packaging checks. No network operations or administrator actions."""
import json
import pathlib
import plistlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
project = (root / "MojaveRay.xcodeproj/project.pbxproj").read_text()
ids = re.findall(r"^\s*([A-F0-9]{24})(?: /\*.*?\*/)? = \{", project, re.M)
# TargetAttributes references look like definitions, so only check object refs.
references = set(re.findall(r"\b[A-F0-9]{24}\b", project))
assert references <= set(ids)
match = re.search(r'shellScript = ("(?:[^"\\]|\\.)*");', project)
assert match
script = json.loads(match.group(1))
subprocess.run(["bash", "-n"], input=script, text=True, check=True)
assert 'Scripts/BuildControl.sh' in script
assert '$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH' in script
for source in re.findall(r'"\$\(SRCROOT\)/([^"\n]+)"', project):
    target = root / source
    if source == "Vendor/AmneziaWG-Licenses":
        assert target.is_dir(), source
    else:
        assert target.is_file(), source
for shell in list((root / "Scripts").glob("*")) + list((root / "Resources").glob("*.sh")):
    if shell.is_file():
        subprocess.run(["bash", "-n", str(shell)], check=True)
with (root / "Resources/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["CFBundleShortVersionString"] == "1.10.1"
assert info["LSMinimumSystemVersion"] == "11.0"
app_delegate = (root / "Sources/MojaveRay/AppDelegate.swift").read_text()
assert "NSRunningApplication.runningApplications" in app_delegate
assert "DistributedNotificationCenter.default()" in app_delegate
assert "applicationShouldHandleReopen" in app_delegate
assert "NSStatusBar.system.statusItem" in app_delegate
assert 'item.button?.title = "VPN"' in app_delegate
assert 'withTitle: "Вернуться в полный режим"' in app_delegate
assert 'withTitle: "Подключить VPN"' in app_delegate
assert 'withTitle: "Отключить VPN"' in app_delegate
assert 'withTitle: "Выйти"' in app_delegate
assert "windowDidMiniaturize" not in app_delegate
assert "menu.autoenablesItems = false" in app_delegate
assert "connected ? NSColor.systemGreen : NSColor.labelColor" in app_delegate
assert "controller.onConnectionStateChange" in app_delegate
window_source = (root / "Sources/MojaveRay/MainWindowController.swift").read_text()
assert "self?.onConnectionStateChange?(state)" in window_source
assert 'NSButton(title: "Выйти", target: NSApp' in window_source
network = (root / "Sources/MojaveRay/PrivilegedNetworkController.swift").read_text()
assert network.count('with administrator privileges') == 1
assert 'try perform(["stop"])' in network
assert 'func manageInstallation' in network
helper = (root / "Resources/mojaveray-helper.sh").read_text()
assert '/usr/bin/nohup' not in helper
assert '${MOJAVERAY_SERVICE:-0}' in helper
assert '-loglevel warning' in helper
assert 'service-start-full)' in helper
print("PASS: Xcode inputs, scripts, version, single instance, menu bar and service integration")
