#!/usr/bin/env bash
set -euo pipefail

# Zero-setup bootstrap for a clean virtual workspace.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

VENV_DIR=".venv_synth"
if [[ ! -d "${VENV_DIR}" ]]; then
  python3 -m venv "${VENV_DIR}"
fi
source "${VENV_DIR}/bin/activate"

python -m pip install --upgrade pip
python -m pip install pandas numpy openpyxl pyarrow matplotlib seaborn

# Usage:
# ./run_synth_analysis.sh "/path/to/level1_synthetic.csv" "/path/to/CAMCAN_Metadata_SynthSprint (1).xlsx"
DATA_FILE="${1:-}"
METADATA_FILE="${2:-}"

if [[ -z "${DATA_FILE}" ]]; then
  echo "Usage: $0 <synthetic_data_file> [metadata_xlsx]"
  exit 1
fi

ANALYZE_CMD=(python analyze_synthetic_data.py --data "${DATA_FILE}" --outdir output)
if [[ -n "${METADATA_FILE}" ]]; then
  ANALYZE_CMD+=(--metadata "${METADATA_FILE}")
fi
"${ANALYZE_CMD[@]}"

python visualize_synthetic_report.py --outdir output

echo "Done. Open:"
echo "- output/summary.json"
echo "- output/*.csv"
echo "- output/visuals/VISUAL_INDEX.md"
echo "- output/visuals/*.png"
