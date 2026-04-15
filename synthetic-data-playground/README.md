# Synthetic Data Playground

Use this folder as the single source of truth for:
- what to upload to virtual workspace,
- what to run locally for dry runs,
- where to read outputs.

## Folder structure

```text
synthetic-data-playground/
  upload_to_virtual_workspace/
    analyze_synthetic_data.py
    run_synth_analysis.sh
  local_tests/
    generate_mock_synthetic_data.py
    run_local_dry_run.sh
    CAMCAN_Metadata_SynthSprint (1).xlsx
  read_reports/
    local_dry_run_output/   (created after local dry run)
```

## 1) Upload this to virtual workspace

Upload the full `upload_to_virtual_workspace/` folder.

Then in virtual workspace:

```bash
cd upload_to_virtual_workspace
chmod +x run_synth_analysis.sh
./run_synth_analysis.sh "/path/to/your_real_level1_synthetic_data.csv" "/path/to/CAMCAN_Metadata_SynthSprint (1).xlsx"
```

## 2) Local dry run (mock data)

```bash
cd local_tests
chmod +x run_local_dry_run.sh
./run_local_dry_run.sh
```

This generates mock data and runs the analyzer end-to-end.

## 3) Read outputs

- Local dry run reports: `read_reports/local_dry_run_output/`
- Key files to read first:
  - `summary.json`
  - `column_profile.csv`
  - `pii_value_pattern_hits.csv` (if present)
  - `quasi_identifier_k_anonymity_snapshot.csv` (if present)
