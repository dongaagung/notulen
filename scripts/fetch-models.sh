#!/bin/bash
# Downloads the pinned FluidAudio diarization models into
# Models/speaker-diarization/ (gitignored). The bundle step copies them into
# the app, so it never downloads at runtime. Fails if any file is missing.
set -euo pipefail

REVISION=df2625ac79a7ac6b65ad868fee6d80f320da4232
BASE="https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/$REVISION"
cd "$(dirname "$0")/.."
DEST=Models/speaker-diarization

rm -rf Models
mkdir -p "$DEST"

fetch() {
    mkdir -p "$DEST/$(dirname "$1")"
    curl -fL --retry 3 --silent --show-error -o "$DEST/$1" "$BASE/$1"
}

for model in Segmentation FBank Embedding PldaRho; do
    for file in coremldata.bin analytics/coremldata.bin metadata.json model.mil weights/weight.bin; do
        fetch "$model.mlmodelc/$file"
    done
done
fetch plda-parameters.json
# Notices are nice to have; the attribution text in About carries the notice anyway.
for file in LICENSE NOTICE.md; do
    fetch "$file" || echo "warning: $file not downloaded; continuing" >&2
done

# FluidAudio refuses to load a folder without its revision marker.
printf '%s' "$REVISION" > "$DEST/.fluidaudio-revision"
echo "Models ready in $DEST ($(du -sh "$DEST" | cut -f1))"
