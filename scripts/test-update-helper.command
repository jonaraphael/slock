#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Exercise the real app's helper against a throwaway app. The fixture has no
# slock controller, identity, keyboard access, microphone, or network code.
scratch=$(mktemp -d "$PWD/.build/update-helper-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/fixture.swift" <<'SWIFT'
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let observer = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                                       object: nil, queue: .main) { _ in
    let path = Bundle.main.object(forInfoDictionaryKey: "UpdateSmokeOutput") as! String
    try! Data("relaunched\n".utf8).write(to: URL(fileURLWithPath: path))
    NSApp.terminate(nil)
}
app.run()
SWIFT
./scripts/swiftc.command -swift-version 5 -module-cache-path "$PWD/.build/modules" \
  "$scratch/fixture.swift" -o "$scratch/fixture"
python3 - "$scratch" <<'PY'
import os, pathlib, plistlib, shutil, subprocess, sys, time
root = pathlib.Path(sys.argv[1]).resolve()
source = pathlib.Path('dist/slock.app').resolve()
destination = root / 'slock.app'
stage = root / '.slock-update-smoke'
stage.mkdir(mode=0o700)
updated = stage / 'slock.app'
marker = root / 'relaunched.txt'
new_version = plistlib.loads((source / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
for app, version in [(destination, '0.0.0'), (updated, new_version)]:
    shutil.copytree(source, app)
    shutil.copy2(root / 'fixture', app / 'Contents/MacOS/slock')
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleShortVersionString'] = version
    info['UpdateSmokeOutput'] = str(marker)
    info_path.write_bytes(plistlib.dumps(info))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
helper = stage / 'install-update'
shutil.copy2(source / 'Contents/MacOS/slock', helper)
parent = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(2)'])
process = subprocess.Popen([str(helper), '--slock-install-update', str(parent.pid), str(stage),
                            str(destination), '0.0.0', new_version], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    time.sleep(0.3)
    assert not marker.exists(), 'helper installed before the old process exited'
    parent.wait(timeout=5)
    out, err = process.communicate(timeout=30)
    assert process.returncode == 0, (out, err)
    deadline = time.monotonic() + 15
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    assert marker.read_text() == 'relaunched\n', 'updated app did not relaunch'
    info = plistlib.loads((destination / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleShortVersionString'] == new_version
    assert not stage.exists(), 'successful update left its staging directory behind'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(destination)], check=True)
    print('PASS real update helper waited, replaced the app in place, cleaned up, and relaunched it')
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    if parent.poll() is None:
        parent.kill()
        parent.wait()
PY
