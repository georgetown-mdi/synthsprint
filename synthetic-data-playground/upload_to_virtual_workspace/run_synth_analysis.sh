#!/usr/bin/env bash
set -euo pipefail

CALLER_CWD="$(pwd)"

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
# ./run_synth_analysis.sh "/path/to/level1_synthetic.csv" "/path/to/CAMCAN_Metadata_SynthSprint (1).xlsx" "../analysis_reports/output"
DATA_FILE="${1:-}"
METADATA_FILE="${2:-}"
OUTDIR="${3:-../analysis_reports/output}"

if [[ -z "${DATA_FILE}" ]]; then
  echo "Usage: $0 <synthetic_data_file> [metadata_xlsx] [output_dir]"
  exit 1
fi

# Resolve user-provided paths from caller cwd (not script cwd).
if [[ "${DATA_FILE}" != /* ]]; then
  DATA_FILE="${CALLER_CWD}/${DATA_FILE}"
fi
if [[ -n "${METADATA_FILE}" && "${METADATA_FILE}" != /* ]]; then
  METADATA_FILE="${CALLER_CWD}/${METADATA_FILE}"
fi
if [[ "${OUTDIR}" != /* ]]; then
  OUTDIR="${CALLER_CWD}/${OUTDIR}"
fi

mkdir -p "${OUTDIR}"
ANALYZE_CMD=(python analyze_synthetic_data.py --data "${DATA_FILE}" --outdir "${OUTDIR}")
if [[ -n "${METADATA_FILE}" ]]; then
  ANALYZE_CMD+=(--metadata "${METADATA_FILE}")
fi
"${ANALYZE_CMD[@]}"

python visualize_synthetic_report.py --outdir "${OUTDIR}"

echo "Done. Open:"
echo "- ${OUTDIR}/summary.json"
echo "- ${OUTDIR}/*.csv"
echo "- ${OUTDIR}/visuals/VISUAL_INDEX.md"
echo "- ${OUTDIR}/visuals/*.png"
