#!/usr/bin/env bash
set -euo pipefail

# Run from this folder:
#   cd synthetic-data-playground/local_tests
#   chmod +x run_local_dry_run.sh
#   ./run_local_dry_run.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# Zero-setup dependency install.
python3 -m pip install --upgrade pip
python3 -m pip install pandas numpy openpyxl pyarrow

python3 generate_mock_synthetic_data.py

# Run analyzer from upload bundle against mock data.
CMD=(python3 ../upload_to_virtual_workspace/analyze_synthetic_data.py \
  --data ./mock_level1_synthetic.csv \
  --outdir ../read_reports/local_dry_run_output)

if [[ -f "./CAMCAN_Metadata_SynthSprint (1).xlsx" ]]; then
  CMD+=(--metadata "./CAMCAN_Metadata_SynthSprint (1).xlsx")
else
  echo "Metadata workbook not found in local_tests; running without --metadata."
fi

"${CMD[@]}"

echo "Local dry run complete."
echo "Read outputs in: ../read_reports/local_dry_run_output"
