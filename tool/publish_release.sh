#!/usr/bin/env bash
# Publish reaxdb_dart to pub.dev and push the release branch/tag.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(rg -n '^version:' pubspec.yaml | head -1 | awk '{print $2}')"

echo "==> reaxdb_dart ${VERSION}"
echo "==> analyze + test"
dart analyze
dart test

echo "==> dry-run"
dart pub publish --dry-run

echo "==> publish to pub.dev"
dart pub publish --force

echo "==> push git + tag v${VERSION}"
git push -u origin HEAD
if ! git rev-parse "v${VERSION}" >/dev/null 2>&1; then
  git tag -a "v${VERSION}" -m "reaxdb_dart ${VERSION}"
fi
git push origin "v${VERSION}"

echo "Done. Package: https://pub.dev/packages/reaxdb_dart/versions/${VERSION}"
