#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --product Keydance

app_path="$PWD/dist/Keydance.app"
binary_path="$(swift build -c release --show-bin-path)"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/Keydance" "$app_path/Contents/MacOS/Keydance"
cp Sources/Keydance/Resources/* "$app_path/Contents/Resources/"
cp scripts/Info.plist "$app_path/Contents/Info.plist"

text_model_package="$PWD/ml/artifacts/SessionTextTransformer.mlpackage"
text_model_metadata="$PWD/ml/artifacts/SessionTextTransformer.metadata.json"
bundled_model=false
if [[ -d "$text_model_package" ]]; then
    xcrun coremlcompiler compile "$text_model_package" "$app_path/Contents/Resources"
    if [[ -f "$text_model_metadata" ]]; then
        cp "$text_model_metadata" "$app_path/Contents/Resources/SessionTextTransformer.metadata.json"
    fi
    echo "Bundled trained SessionTextTransformer Core ML model"
    bundled_model=true
fi
if [[ "$bundled_model" == false ]]; then
    echo "No trained text model found; app will use the text-aware fallback"
fi

signing_identity="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
if [[ -n "$signing_identity" ]]; then
    codesign --force --deep --options runtime --sign "$signing_identity" "$app_path"
    echo "Signed with $signing_identity"
else
    codesign --force --deep --sign - "$app_path"
    echo "No Apple Development identity found; used an ad-hoc signature"
fi
echo "Built $app_path"
