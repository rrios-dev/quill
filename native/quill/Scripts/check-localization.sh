#!/bin/bash
#
# Quill's localization check (PLAN P5-T2): Ámbar's generic checker, pointed at Quill's
# resources. Every UI string in es and en with the same keys, format specifiers and plural
# categories; no value empty or copied from Spanish outside Scripts/untranslated-allowed.txt;
# InfoPlist.strings in both; every key the code uses exists. AppCore's bundle may carry
# more languages than Quill announces, never fewer.
#
#   Scripts/check-localization.sh
#
set -euo pipefail

QUILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$(cd "$QUILL/.." && pwd)"

LOCALIZATION_SCAN_ROOT="$QUILL" \
LOCALIZATION_APP_RESOURCES="$QUILL/apps/Quill/Resources" \
LOCALIZATION_APP_PLIST="$QUILL/apps/Quill/Info.plist" \
LOCALIZATION_INFOPLIST_RESOURCES="$QUILL/apps/Quill/BundleResources" \
LOCALIZATION_PACKAGES="$NATIVE/packages/AppCore/Resources=AppCore" \
LOCALIZATION_PACKAGE_LANGUAGES=superset \
LOCALIZATION_CATALOGS="$QUILL/apps/Quill/Resources/es.lproj/Localizable.strings:$QUILL/apps/Quill/Resources/es.lproj/Localizable.stringsdict:$NATIVE/packages/AppCore/Resources/es.lproj/Localizable.strings" \
LOCALIZATION_MIN_CALLS=10 \
LOCALIZATION_EXTRA_USE='PickerCopy\.string\(\s*"([^"]+)"' \
LOCALIZATION_ALLOWLIST="$QUILL/Scripts/untranslated-allowed.txt" \
  "$NATIVE/Scripts/check-localization.sh"
