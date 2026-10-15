#!/bin/zsh
# xcodebuild hangs loading projects from this iCloud-synced folder, so mirror to a local scratch dir and build there.
#   Tools/build.sh sim               → Debug build for the simulator (BOSS_SIM, default "iPhone 17 Pro")
#   Tools/build.sh device            → Release build for a connected iPhone (team YOUR_TEAM_ID)
#   Tools/build.sh test              → BossCoreTests on the simulator
# Extra args go to xcodebuild. Work dir: BOSS_BUILD_DIR (default $TMPDIR/BossCalendarBuild).
set -e
APP="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${BOSS_BUILD_DIR:-${TMPDIR:-/tmp}/BossCalendarBuild}"
SIM="${BOSS_SIM:-iPhone 17 Pro}"
CMD="${1:-sim}"
[[ $# -gt 0 ]] && shift
mkdir -p "$WORK/src"
rsync -a --delete --exclude 'BossCalendar.xcodeproj' --exclude 'Documentation' --exclude '* 2.*' --exclude '* 2' \
  "$APP/" "$WORK/src/BossCalendar/"
cd "$WORK/src/BossCalendar"
xcodegen generate --quiet
SIMDEST="platform=iOS Simulator,name=$SIM"
case "$CMD" in
  sim)
    xcodebuild -project BossCalendar.xcodeproj -scheme BossCalendar -configuration Debug \
      -destination "$SIMDEST" -derivedDataPath "$WORK/dd" build "$@" ;;
  device)
    xcodebuild -project BossCalendar.xcodeproj -scheme BossCalendar -configuration Release \
      -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath "$WORK/dd" build "$@" ;;
  test)
    xcodebuild -project BossCalendar.xcodeproj -scheme BossCalendar -configuration Debug \
      -destination "$SIMDEST" -derivedDataPath "$WORK/dd" test "$@" ;;
  *)
    echo "usage: Tools/build.sh sim|device|test [xcodebuild args…]" >&2
    exit 2 ;;
esac
