#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

contextual_checkpoint="$PWD/ml/ContextualAccuracyScorer.pt"
contextual_weights="$PWD/Sources/Keydance/Resources/ContextualAccuracyScorer.weights"
if [[ -f "$contextual_checkpoint" && ( ! -f "$contextual_weights" || "$contextual_checkpoint" -nt "$contextual_weights" ) ]]; then
    python3 scripts/convert-contextual-scorer.py "$contextual_checkpoint" "$contextual_weights"
fi

swift build -c release --product Keydance

app_path="$PWD/dist/Keydance.app"
binary_path="$(swift build -c release --show-bin-path)"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/Keydance" "$app_path/Contents/MacOS/Keydance"
cp Sources/Keydance/Resources/* "$app_path/Contents/Resources/"
cp scripts/Info.plist "$app_path/Contents/Info.plist"

# Build the macOS icon from the supplied Keydance logo.
icon_source="$app_path/Contents/Resources/keydance-icon-source.png"
iconset_path="$app_path/Contents/Resources/Keydance.iconset"
sips --cropToHeightWidth 618 618 Sources/Keydance/Resources/keydance.png --out "$icon_source" >/dev/null
mkdir -p "$iconset_path"
for size in 16 32 128 256 512; do
    double_size=$((size * 2))
    sips -z "$size" "$size" "$icon_source" --out "$iconset_path/icon_${size}x${size}.png" >/dev/null
    sips -z "$double_size" "$double_size" "$icon_source" --out "$iconset_path/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/Keydance.icns"
rm -rf "$iconset_path" "$icon_source"

# Training inputs stay in the gitignored workspace context; the exported model
# and its quality metadata are the only training artifacts retained by the app.
text_model_package="$PWD/ml/SessionTextTransformer.mlpackage"
text_model_metadata="$PWD/ml/SessionTextTransformer.metadata.json"
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
