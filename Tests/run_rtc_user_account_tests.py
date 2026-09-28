"""Run RTC account handling with deterministic SDK/UI doubles and actual source methods."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'Sources/EaseCallUIKit/Classes/CoreService/Implements/CallKitManager+RTC.swift').read_text()


def method(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end]


methods = '\n'.join(method(signature) for signature in [
    'func rtcUserAccount(',
    'func promotePlaceholderIfNeeded(',
    'public func rtcEngine(_ engine: AgoraRtcEngineKit, didUserInfoUpdatedWithUserId',
    'public func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid',
])
template = (root / 'Tests/RTCUserAccountTests.swift').read_text()
with tempfile.TemporaryDirectory(prefix='rtc-account-tests-') as directory:
    test_source = Path(directory) / 'RTCUserAccountTests.swift'
    binary = Path(directory) / 'tests'
    test_source.write_text(template.replace('// IMPLEMENTATION', methods))
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(Path(directory) / 'modules'), str(test_source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
