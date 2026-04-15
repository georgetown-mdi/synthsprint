#!/usr/bin/env python3
"""
Portable synthetic-data profiler:
- Distribution and validity checks
- PII pattern and quasi-identifier risk checks
- Additional diagnostics (duplicates, outliers, correlations, uniqueness risk)
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import pandas as pd


PII_NAME_PATTERNS = {
    "possible_name_column": re.compile(r"(name|first|last|middle|fullname)", re.I),
    "possible_email_column": re.compile(r"(email|e-mail|mail)", re.I),
    "possible_phone_column": re.compile(r"(phone|mobile|tel|contact)", re.I),
    "possible_address_column": re.compile(r"(address|street|city|state|zip|postal)", re.I),
    "possible_dob_column": re.compile(r"(dob|birth|date_of_birth)", re.I),
    "possible_id_column": re.compile(r"(ssn|social|passport|license|mrn|nhs|patient_id|id$)", re.I),
}

PII_VALUE_PATTERNS = {
    "email_like": re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I),
    "phone_like": re.compile(r"\b(?:\+?\d{1,3}[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?){1,2}\d{4}\b"),
    "ssn_like": re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
    "ip_like": re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
    "url_like": re.compile(r"\bhttps?://[^\s]+\b", re.I),
}

QUASI_ID_HINTS = re.compile(r"(age|sex|gender|ethnic|race|zip|postal|region|site|center|dob|birth)", re.I)


def load_table(path: Path, sheet: str | None = None) -> pd.DataFrame:
    suffix = path.suffix.lower()
    if suffix in {".csv", ".tsv"}:
        sep = "\t" if suffix == ".tsv" else ","
        return pd.read_csv(path, sep=sep)
    if suffix == ".xlsx":
        return pd.read_excel(path, sheet_name=sheet if sheet else 0)
    if suffix == ".parquet":
        return pd.read_parquet(path)
    raise ValueError(f"Unsupported file type: {suffix}")


def infer_type_summary(df: pd.DataFrame) -> pd.DataFrame:
    rows = []
    n = len(df)
    for col in df.columns:
        s = df[col]
        missing = int(s.isna().sum())
        unique = int(s.nunique(dropna=True))
        dtype = str(s.dtype)
        rows.append(
            {
                "column": col,
                "dtype": dtype,
                "missing_count": missing,
                "missing_pct": round((missing / n * 100) if n else 0, 3),
                "unique_count": unique,
                "unique_pct": round((unique / n * 100) if n else 0, 3),
                "is_constant": unique <= 1,
            }
        )
    return pd.DataFrame(rows).sort_values(["missing_pct", "unique_pct"], ascending=[False, False])


def column_string_profile(df: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for col in df.columns:
        s = df[col]
        if pd.api.types.is_numeric_dtype(s):
            continue
        series = s.dropna().astype(str)
        if series.empty:
            continue
        lengths = series.str.len()
        numeric_like = series.str.fullmatch(r"[-+]?\d+(\.\d+)?", na=False).mean() * 100
        date_like = series.str.fullmatch(r"\d{4}[-/]\d{1,2}[-/]\d{1,2}", na=False).mean() * 100
        rows.append(
            {
                "column": col,
                "non_null_count": int(series.shape[0]),
                "avg_len": float(lengths.mean()),
                "p95_len": float(lengths.quantile(0.95)),
                "max_len": int(lengths.max()),
                "pct_numeric_like_strings": float(numeric_like),
                "pct_date_like_strings": float(date_like),
            }
        )
    return pd.DataFrame(rows)


def distribution_summary(df: pd.DataFrame) -> Dict[str, pd.DataFrame]:
    numeric = df.select_dtypes(include=[np.number]).copy()
    non_numeric = df.select_dtypes(exclude=[np.number]).copy()

    out = {}
    if not numeric.empty:
        desc = numeric.describe(percentiles=[0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99]).T
        desc["iqr"] = desc["75%"] - desc["25%"]
        desc["outlier_iqr_count"] = 0
        for col in numeric.columns:
            q1 = numeric[col].quantile(0.25)
            q3 = numeric[col].quantile(0.75)
            iqr = q3 - q1
            if pd.isna(iqr) or iqr == 0:
                continue
            low = q1 - 1.5 * iqr
            high = q3 + 1.5 * iqr
            desc.loc[col, "outlier_iqr_count"] = int(((numeric[col] < low) | (numeric[col] > high)).sum())
        out["numeric_distribution"] = desc.reset_index(names=["column"])

    if not non_numeric.empty:
        cat_rows: List[Dict[str, object]] = []
        for col in non_numeric.columns:
            vc = non_numeric[col].astype("string").value_counts(dropna=True).head(10)
            cat_rows.append(
                {
                    "column": col,
                    "top_values": json.dumps(vc.index.tolist(), ensure_ascii=True),
                    "top_counts": json.dumps(vc.values.tolist(), ensure_ascii=True),
                }
            )
        out["categorical_top_values"] = pd.DataFrame(cat_rows)

    return out


def numeric_correlation_pairs(df: pd.DataFrame, top_n: int = 100) -> pd.DataFrame:
    numeric = df.select_dtypes(include=[np.number])
    if numeric.shape[1] < 2:
        return pd.DataFrame()
    corr = numeric.corr(method="pearson", min_periods=20)
    rows = []
    cols = corr.columns.tolist()
    for i in range(len(cols)):
        for j in range(i + 1, len(cols)):
            c1, c2 = cols[i], cols[j]
            val = corr.loc[c1, c2]
            if pd.isna(val):
                continue
            rows.append({"col_a": c1, "col_b": c2, "pearson_r": float(val), "abs_r": float(abs(val))})
    if not rows:
        return pd.DataFrame()
    return pd.DataFrame(rows).sort_values("abs_r", ascending=False).head(top_n)


def detect_pii(df: pd.DataFrame, scan_limit: int) -> Tuple[pd.DataFrame, pd.DataFrame]:
    name_hits = []
    for col in df.columns:
        for label, pat in PII_NAME_PATTERNS.items():
            if pat.search(str(col)):
                name_hits.append({"column": col, "rule": label, "evidence": "column_name_match"})

    value_hits = []
    sample_df = df.head(scan_limit)
    for col in sample_df.columns:
        series = sample_df[col].dropna().astype(str)
        if series.empty:
            continue
        joined = "\n".join(series.head(5000).tolist())
        for rule, pat in PII_VALUE_PATTERNS.items():
            matches = pat.findall(joined)
            if matches:
                value_hits.append(
                    {
                        "column": col,
                        "rule": rule,
                        "match_count_in_sample": len(matches),
                        "example_match": str(matches[0])[:80],
                    }
                )
    return pd.DataFrame(name_hits), pd.DataFrame(value_hits)


def uniqueness_risk(df: pd.DataFrame) -> pd.DataFrame:
    n = len(df)
    if n == 0:
        return pd.DataFrame()
    rows = []
    for col in df.columns:
        unique_count = int(df[col].nunique(dropna=True))
        unique_pct = unique_count / n * 100
        rows.append(
            {
                "column": col,
                "unique_count": unique_count,
                "unique_pct": float(unique_pct),
                "possible_direct_identifier": bool(unique_pct >= 95 and unique_count > 50),
            }
        )
    return pd.DataFrame(rows).sort_values("unique_pct", ascending=False)


def quasi_identifier_risk(df: pd.DataFrame, max_cols: int = 5) -> pd.DataFrame:
    n = len(df)
    candidates = []
    for col in df.columns:
        col_str = str(col)
        unique_pct = (df[col].nunique(dropna=True) / n * 100) if n else 0
        if QUASI_ID_HINTS.search(col_str) or (3 < unique_pct < 95):
            # Prioritize likely quasi-identifiers by explicit hint + uniqueness.
            hint_score = 100 if QUASI_ID_HINTS.search(col_str) else 0
            risk_score = hint_score + min(99.0, abs(unique_pct - 50.0))
            candidates.append((col, risk_score))
    cols = [c for c, _ in sorted(candidates, key=lambda x: x[1], reverse=True)[:max_cols]]
    if len(cols) < 2:
        return pd.DataFrame()

    grouped = df[cols].fillna("__NA__").astype(str).groupby(cols, dropna=False).size().reset_index(name="k")
    k_stats = {
        "columns_used": ",".join(cols),
        "rows_total": n,
        "groups_total": int(len(grouped)),
        "k_min": int(grouped["k"].min()),
        "k_5th_percentile": float(grouped["k"].quantile(0.05)),
        "k_median": float(grouped["k"].median()),
        "groups_with_k_1": int((grouped["k"] == 1).sum()),
        "pct_rows_in_k_1_groups": float((grouped[grouped["k"] == 1]["k"].sum() / n * 100) if n else 0),
    }
    return pd.DataFrame([k_stats])


def row_level_missingness(df: pd.DataFrame) -> pd.DataFrame:
    if df.empty:
        return pd.DataFrame()
    row_missing = df.isna().sum(axis=1)
    return pd.DataFrame(
        [
            {
                "rows_total": int(df.shape[0]),
                "cols_total": int(df.shape[1]),
                "mean_missing_per_row": float(row_missing.mean()),
                "p95_missing_per_row": float(row_missing.quantile(0.95)),
                "rows_with_any_missing_pct": float((row_missing > 0).mean() * 100),
                "rows_all_missing_pct": float((row_missing == df.shape[1]).mean() * 100),
            }
        ]
    )


def simple_validity_flags(df: pd.DataFrame) -> pd.DataFrame:
    flags = []
    for col in df.select_dtypes(include=[np.number]).columns:
        s = df[col].dropna()
        if s.empty:
            continue
        if (s < 0).mean() > 0:
            flags.append({"column": col, "rule": "has_negative_values", "pct_negative": float((s < 0).mean() * 100)})
        # Flags likely binary/ordinal variables with unexpected cardinality.
        if s.nunique() <= 12 and s.nunique() > 2 and set(s.unique()).issubset(set(range(1000))):
            flags.append(
                {
                    "column": col,
                    "rule": "possible_coded_variable_review_levels",
                    "distinct_levels": int(s.nunique()),
                }
            )
    return pd.DataFrame(flags)


def privacy_risk_summary(
    name_hits: pd.DataFrame,
    value_hits: pd.DataFrame,
    uniqueness_df: pd.DataFrame,
    k_df: pd.DataFrame,
) -> pd.DataFrame:
    direct_id_cols = 0
    if not uniqueness_df.empty:
        direct_id_cols = int(uniqueness_df["possible_direct_identifier"].sum())

    k_one_pct = 0.0
    if not k_df.empty and "pct_rows_in_k_1_groups" in k_df.columns:
        k_one_pct = float(k_df.iloc[0]["pct_rows_in_k_1_groups"])

    risk_score = 0
    risk_score += min(30, len(name_hits) * 4)
    risk_score += min(30, len(value_hits) * 7)
    risk_score += min(25, direct_id_cols * 5)
    risk_score += min(15, int(k_one_pct / 2))

    if risk_score >= 60:
        risk_band = "high"
    elif risk_score >= 30:
        risk_band = "medium"
    else:
        risk_band = "low"

    return pd.DataFrame(
        [
            {
                "risk_score_0_100": int(risk_score),
                "risk_band": risk_band,
                "pii_name_hit_count": int(len(name_hits)),
                "pii_value_hit_count": int(len(value_hits)),
                "possible_direct_identifier_columns": int(direct_id_cols),
                "pct_rows_in_k1_groups": float(k_one_pct),
            }
        ]
    )


def write_table(df: pd.DataFrame, out_path: Path) -> None:
    if df is None or df.empty:
        return
    df.to_csv(out_path, index=False)


def main() -> None:
    parser = argparse.ArgumentParser(description="Synthetic dataset quality + privacy profiler")
    parser.add_argument("--data", required=True, help="Path to synthetic dataset (csv/tsv/xlsx/parquet)")
    parser.add_argument("--sheet", default=None, help="Excel sheet name if data is xlsx")
    parser.add_argument("--metadata", default=None, help="Optional metadata dictionary workbook path")
    parser.add_argument("--outdir", default="output", help="Output directory")
    parser.add_argument("--scan-limit", type=int, default=5000, help="Max rows to scan for value-based PII patterns")
    args = parser.parse_args()
    if args.scan_limit < 1:
        raise ValueError("--scan-limit must be >= 1")

    data_path = Path(args.data).expanduser().resolve()
    outdir = Path(args.outdir).expanduser().resolve()
    outdir.mkdir(parents=True, exist_ok=True)

    df = load_table(data_path, sheet=args.sheet)
    profile = infer_type_summary(df)
    write_table(profile, outdir / "column_profile.csv")

    for name, table in distribution_summary(df).items():
        write_table(table, outdir / f"{name}.csv")

    name_hits, value_hits = detect_pii(df, args.scan_limit)
    write_table(name_hits, outdir / "pii_column_name_hits.csv")
    write_table(value_hits, outdir / "pii_value_pattern_hits.csv")

    write_table(simple_validity_flags(df), outdir / "validity_flags.csv")
    k_df = quasi_identifier_risk(df)
    write_table(k_df, outdir / "quasi_identifier_k_anonymity_snapshot.csv")
    uniqueness_df = uniqueness_risk(df)
    write_table(uniqueness_df, outdir / "uniqueness_risk.csv")
    write_table(row_level_missingness(df), outdir / "row_missingness_summary.csv")
    write_table(column_string_profile(df), outdir / "string_column_profile.csv")
    write_table(numeric_correlation_pairs(df), outdir / "numeric_top_correlations.csv")
    write_table(privacy_risk_summary(name_hits, value_hits, uniqueness_df, k_df), outdir / "privacy_risk_summary.csv")

    dup_count = int(df.duplicated().sum())
    summary = {
        "input_file": str(data_path),
        "rows": int(df.shape[0]),
        "columns": int(df.shape[1]),
        "duplicate_rows": dup_count,
        "duplicate_row_pct": float((dup_count / len(df) * 100) if len(df) else 0),
        "numeric_column_count": int(df.select_dtypes(include=[np.number]).shape[1]),
        "non_numeric_column_count": int(df.select_dtypes(exclude=[np.number]).shape[1]),
        "outputs": sorted(str(p.name) for p in outdir.glob("*.csv")),
    }

    # Optional metadata parse for quick dictionary export.
    if args.metadata:
        md_path = Path(args.metadata).expanduser().resolve()
        try:
            md = pd.read_excel(md_path, sheet_name=0)
            md.to_csv(outdir / "metadata_dictionary_dump.csv", index=False)
            summary["metadata_loaded"] = True
        except Exception as exc:  # pragma: no cover
            summary["metadata_loaded"] = False
            summary["metadata_error"] = str(exc)

    with open(outdir / "summary.json", "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    print(json.dumps(summary, indent=2))
    print(f"\nAnalysis complete. Files written to: {outdir}")


if __name__ == "__main__":
    main()
