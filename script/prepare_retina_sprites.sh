#!/usr/bin/env bash
# Created by Angelo Cammalleri on 29.10.2026.
# Offline export only; no scaler code or dependency is linked into the game.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_temp="$(mktemp -d /private/tmp/space-sprite-export.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
if [[ $# -gt 2 ]]; then
  echo "usage: $0 [xBRZ-1.9-source-directory [output-directory]]" >&2
  exit 64
fi
scaler_source="${1:-$task_temp/xbrz}"
sprite_output="${2:-$project_root/Resources/Modern/Sprites}"
if [[ $# -eq 0 ]]; then
  curl -fsSL --max-time 60 'https://downloads.sourceforge.net/project/xbrz/xBRZ/xBRZ_1.9.zip' -o "$task_temp/xbrz.zip"
  echo 'b2dff73b3abd24a18a7cde78d5ff5ed8f0922296dce6ed734dce2264cd0a0fc9  '"$task_temp/xbrz.zip" | shasum -a 256 -c -
  mkdir "$scaler_source"
  unzip -q "$task_temp/xbrz.zip" -d "$scaler_source"
fi
scaler_source="$(cd "$scaler_source" && pwd)"
(
  cd "$scaler_source"
  shasum -a 256 -c <<'HASHES'
882346f5f6703f286c55d4089af7a8f63140fe13a133318e4be64891689bee0c  xbrz.cpp
004e4ee01324d7c9c6870a02aab58e5344eb209e8940cb7f3302b9f9547a1197  xbrz.h
e7301f66ddbe0785b54b9621148d8d4143f33207be91c430a99847f6e9eb5fda  xbrz_config.h
72202a6a259d0f1b6811c7402cea5b0eeec7479c2e8c5d017ec4bcff8eb1296b  xbrz_tools.h
HASHES
)
xcrun clang++ -std=c++23 -O2 -fobjc-arc -Wall -Wextra -Werror -Wno-unused-function \
  -I "$scaler_source" "$project_root/script/tools/PrepareRetinaSprites.mm" \
  "$scaler_source/xbrz.cpp" -framework Foundation -framework CoreGraphics \
  -framework ImageIO -o "$task_temp/PrepareRetinaSprites"
"$task_temp/PrepareRetinaSprites" "$project_root/Resources/Original" "$sprite_output" "$project_root/script/tools/GameplaySpriteInputs.json"
python3 - "$project_root" "$sprite_output" <<'PY'
import hashlib, json, sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
inputs = json.loads((root/'script/tools/GameplaySpriteInputs.json').read_text())
for entry in inputs:
    name = entry['name']
    entry.update(originalSHA256=digest(root/'Resources/Original'/name),
                 **{'2xSHA256': digest(output/'2x'/name), '4xSHA256': digest(output/'4x'/name)})
manifest = {'exporter': 'xBRZ 1.9, ARGB, default ScalerCfg; isolated atlas cells; linear soft gradients',
            'sourceArchiveSHA256': 'b2dff73b3abd24a18a7cde78d5ff5ed8f0922296dce6ed734dce2264cd0a0fc9',
            'inputLayoutSHA256': digest(root/'script/tools/GameplaySpriteInputs.json'),
            'watchScale': 2, 'metalScale': 4, 'textures': inputs}
(output/'manifest.json').write_text(json.dumps(manifest, indent=2)+chr(10))
print('Exported 16 original gameplay textures at 2x and 4x; original files untouched.')
PY
