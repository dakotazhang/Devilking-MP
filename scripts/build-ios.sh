#!/usr/bin/env bash
set -euo pipefail

task_mode="${1:-all}"
case "$task_mode" in test|archive|all) ;; *) echo 'Usage: build-ios.sh [test|archive|all]' >&2; exit 2 ;; esac
test_scope="${IOS_TEST_SCOPE:-all}"
case "$test_scope" in all|connection-lifecycle|tab-performance) ;; *) echo 'IOS_TEST_SCOPE must be all, connection-lifecycle or tab-performance.' >&2; exit 2 ;; esac
if [[ "$task_mode" == archive && "$test_scope" != all ]]; then
  echo 'A focused UI diagnostic cannot create a device archive.' >&2
  exit 2
fi
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$task_root"
mkdir -p build
command -v xcodegen >/dev/null 2>&1 || { echo 'Install xcodegen on the Mac builder first.' >&2; exit 2; }
xcodegen generate --spec ios/project.yml --project ios

if [[ "$task_mode" == test || "$task_mode" == all ]]; then
  simulator_id="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; j=json.load(sys.stdin); candidates=[(runtime,d["udid"]) for runtime,devices in j["devices"].items() if ".iOS-" in runtime for d in devices if d.get("isAvailable",False) and "iPhone" in d.get("name","")]; candidates.sort(reverse=True); print(candidates[0][1] if candidates else "")')"
  [[ -n "$simulator_id" ]] || { echo 'No available iPhone simulator in this Xcode runner.' >&2; exit 3; }
  set --
  if [[ "$test_scope" == connection-lifecycle ]]; then
    set -- '-only-testing:DevilkingMPUITests/UITests/testConnectionLifecycleKeepsCredentialsAndGroupsDoNotRemoveServers'
  elif [[ "$test_scope" == tab-performance ]]; then
    set -- '-only-testing:DevilkingMPUITests/UITabPerformanceRegressionTests'
  fi
  echo "Running test scope: $test_scope" | tee build/test.log
  xcodebuild -project ios/DevilkingMP.xcodeproj -scheme DevilkingMP \
    -configuration Debug -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath build/DerivedData -resultBundlePath build/CoreTests.xcresult \
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
    "$@" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" \
    test 2>&1 | tee -a build/test.log
fi

if [[ "$test_scope" == all && ( "$task_mode" == archive || "$task_mode" == all ) ]]; then
  xcodebuild -project ios/DevilkingMP.xcodeproj -scheme DevilkingMP \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -archivePath build/DevilkingMP.xcarchive -derivedDataPath build/DerivedData \
    IPHONEOS_DEPLOYMENT_TARGET=16.1 CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
    archive 2>&1 | tee build/archive.log
  mkdir -p build/ipa/Payload
  ditto build/DevilkingMP.xcarchive/Products/Applications/DevilkingMP.app \
    build/ipa/Payload/DevilkingMP.app
  (cd build/ipa && zip -qry ../DevilkingMP-unsigned.ipa Payload)
  python3 scripts/validate-package.py --ipa build/DevilkingMP-unsigned.ipa \
    --output build/package-validation.json
  python3 - <<'PY'
import datetime, json, os, pathlib, subprocess
def command(*args):
    return subprocess.check_output(args, text=True).strip()
receipt = {
    "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "source_commit": command("git", "rev-parse", "HEAD"),
    "xcode": command("xcodebuild", "-version"),
    "github_run_id": os.environ.get("GITHUB_RUN_ID"),
    "github_repository": os.environ.get("GITHUB_REPOSITORY"),
    "signed": False,
    "minimum_ios": "16.1",
    "physical_device_verified": False,
}
pathlib.Path("build/build-receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
PY
fi
