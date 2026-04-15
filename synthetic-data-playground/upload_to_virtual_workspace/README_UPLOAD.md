# Upload Bundle

This folder is the only part you need to upload to virtual workspace.

## Files

- `analyze_synthetic_data.py`: main analyzer (comprehensive checks)
- `analyze_synthetic_data_r.R`: R equivalent analyzer (R kernel friendly)
- `visualize_synthetic_report.py`: creates readable chart artifacts from output CSVs
- `run_synth_analysis.sh`: zero-setup runner (installs dependencies via pip)
- `synthetic_data_analysis.ipynb`: notebook workflow with install + run + report review

## Script run in virtual workspace

```bash
cd upload_to_virtual_workspace
chmod +x run_synth_analysis.sh
./run_synth_analysis.sh "/path/to/real_synthetic_data.csv" "/path/to/CAMCAN_Metadata_SynthSprint (1).xlsx"
```

`run_synth_analysis.sh` auto-creates and uses a local virtual environment at `.venv_synth/`.
By default, outputs go to `../analysis_reports/output` (outside the upload bundle).

### If you do NOT have metadata (common case)

```bash
cd upload_to_virtual_workspace
chmod +x run_synth_analysis.sh
./run_synth_analysis.sh "/path/to/real_synthetic_data.csv"
```

No manual script edits are needed. Only set the real data file path.

### Optional custom output path

```bash
./run_synth_analysis.sh "/path/to/real_synthetic_data.csv" "" "../my_reports/run1"
```

## Notebook run in virtual workspace

1. Open `synthetic_data_analysis.ipynb`
2. Run the install cell
3. Set `DATA_PATH`
4. (Optional) Set `METADATA_PATH`
5. Run all cells

If `METADATA_PATH` does not exist, notebook will continue and run without metadata.

## R kernel / R script equivalent

If your team prefers R (including R kernel workflows), run:

```bash
cd upload_to_virtual_workspace
Rscript analyze_synthetic_data_r.R \
  --data "/path/to/real_synthetic_data.csv" \
  --outdir "../analysis_reports/output_r"
```

Optional metadata:

```bash
Rscript analyze_synthetic_data_r.R \
  --data "/path/to/real_synthetic_data.csv" \
  --metadata "/path/to/CAMCAN_Metadata_SynthSprint (1).xlsx" \
  --outdir "../analysis_reports/output_r"
```

## CWD / path behavior

- `run_synth_analysis.sh` works directly from `upload_to_virtual_workspace`.
- `synthetic_data_analysis.ipynb` auto-detects `analyze_synthetic_data.py` from:
  - current folder, or
  - `./upload_to_virtual_workspace/`
- Script output default: `../analysis_reports/output`
- Notebook output default: `../analysis_reports/output_notebook`
- You only need to set your real dataset path.

## Output files (under your chosen output folder)

- `summary.json`
- `column_profile.csv`
- `numeric_distribution.csv` / `categorical_top_values.csv`
- `validity_flags.csv`
- `pii_column_name_hits.csv`, `pii_value_pattern_hits.csv`
- `quasi_identifier_k_anonymity_snapshot.csv`
- `uniqueness_risk.csv`
- `row_missingness_summary.csv`
- `string_column_profile.csv`
- `numeric_top_correlations.csv`
- `privacy_risk_summary.csv`
- `visuals/VISUAL_INDEX.md`
- `visuals/*.png` (readable charts for evaluation)

If metadata is provided:
- `metadata_dictionary_dump.csv`

## Visual evaluation included

After running either shell script or notebook, the package generates chart PNGs such as:

- top missingness columns
- top uniqueness columns
- top outlier-heavy columns
- top correlated numeric pairs
- privacy risk summary snapshot
- PII pattern hit counts

Open `<output_dir>/visuals/VISUAL_INDEX.md` first, then the listed PNG files.
