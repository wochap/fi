#!/usr/bin/env bash
set -euo pipefail

cd flutter_app
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
