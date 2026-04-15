#!/usr/bin/env python3
"""
Create readable visualization artifacts from analysis CSV outputs.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd
import seaborn as sns


def read_if_exists(path: Path) -> pd.DataFrame | None:
    return pd.read_csv(path) if path.exists() else None


def save_barh(df: pd.DataFrame, x: str, y: str, title: str, out: Path, max_rows: int = 20) -> None:
    if df is None or df.empty or x not in df.columns or y not in df.columns:
        return
    plot_df = df.head(max_rows).copy()
    plt.figure(figsize=(11, 7))
    sns.barplot(data=plot_df, x=x, y=y, hue=y, palette="viridis", legend=False)
    plt.title(title)
    plt.tight_layout()
    plt.savefig(out, dpi=160)
    plt.close()


def generate_visuals(outdir: Path, viz_dir: Path) -> list[str]:
    sns.set_theme(style="whitegrid")
    generated: list[str] = []

    column_profile = read_if_exists(outdir / "column_profile.csv")
    if column_profile is not None and not column_profile.empty:
        missing_df = column_profile.sort_values("missing_pct", ascending=False)
        save_barh(
            missing_df,
            x="missing_pct",
            y="column",
            title="Top Columns by Missing Percentage",
            out=viz_dir / "01_missingness_top_columns.png",
        )
        generated.append("01_missingness_top_columns.png")

        unique_df = column_profile.sort_values("unique_pct", ascending=False)
        save_barh(
            unique_df,
            x="unique_pct",
            y="column",
            title="Top Columns by Uniqueness Percentage",
            out=viz_dir / "02_uniqueness_top_columns.png",
        )
        generated.append("02_uniqueness_top_columns.png")

    num_dist = read_if_exists(outdir / "numeric_distribution.csv")
    if num_dist is not None and not num_dist.empty and {"column", "outlier_iqr_count"}.issubset(num_dist.columns):
        outlier_df = num_dist.sort_values("outlier_iqr_count", ascending=False)
        save_barh(
            outlier_df,
            x="outlier_iqr_count",
            y="column",
            title="Top Numeric Columns by IQR Outlier Count",
            out=viz_dir / "03_outliers_iqr_top_columns.png",
        )
        generated.append("03_outliers_iqr_top_columns.png")

    corr = read_if_exists(outdir / "numeric_top_correlations.csv")
    if corr is not None and not corr.empty and {"col_a", "col_b", "pearson_r"}.issubset(corr.columns):
        corr = corr.copy()
        corr["pair"] = corr["col_a"] + " <> " + corr["col_b"]
        corr = corr.sort_values("pearson_r", key=lambda s: s.abs(), ascending=False).head(20)
        plt.figure(figsize=(12, 8))
        sns.barplot(data=corr, x="pearson_r", y="pair", hue="pair", palette="coolwarm", legend=False)
        plt.title("Top Correlated Numeric Column Pairs")
        plt.tight_layout()
        plt.savefig(viz_dir / "04_top_correlated_pairs.png", dpi=160)
        plt.close()
        generated.append("04_top_correlated_pairs.png")

    privacy = read_if_exists(outdir / "privacy_risk_summary.csv")
    if privacy is not None and not privacy.empty:
        row = privacy.iloc[0]
        metrics = pd.DataFrame(
            {
                "metric": [
                    "PII name hits",
                    "PII value hits",
                    "Possible direct-ID cols",
                    "% rows in k=1 groups",
                    "Risk score (0-100)",
                ],
                "value": [
                    row.get("pii_name_hit_count", 0),
                    row.get("pii_value_hit_count", 0),
                    row.get("possible_direct_identifier_columns", 0),
                    row.get("pct_rows_in_k1_groups", 0),
                    row.get("risk_score_0_100", 0),
                ],
            }
        )
        plt.figure(figsize=(10, 6))
        sns.barplot(data=metrics, x="value", y="metric", hue="metric", palette="mako", legend=False)
        plt.title(f"Privacy Risk Summary (Band: {row.get('risk_band', 'unknown')})")
        plt.tight_layout()
        plt.savefig(viz_dir / "05_privacy_risk_summary.png", dpi=160)
        plt.close()
        generated.append("05_privacy_risk_summary.png")

    pii_hits = read_if_exists(outdir / "pii_value_pattern_hits.csv")
    if pii_hits is not None and not pii_hits.empty and "rule" in pii_hits.columns:
        pii_grouped = pii_hits.groupby("rule", as_index=False)["match_count_in_sample"].sum()
        plt.figure(figsize=(9, 5))
        sns.barplot(data=pii_grouped, x="match_count_in_sample", y="rule", hue="rule", palette="rocket", legend=False)
        plt.title("PII Pattern Matches by Rule")
        plt.tight_layout()
        plt.savefig(viz_dir / "06_pii_pattern_hits.png", dpi=160)
        plt.close()
        generated.append("06_pii_pattern_hits.png")

    report = viz_dir / "VISUAL_INDEX.md"
    lines = ["# Visual Report Index", "", "Generated visual artifacts:"]
    for name in generated:
        lines.append(f"- `{name}`")
    if not generated:
        lines.append("- No visuals generated (required CSV inputs not found).")
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return generated


def main() -> None:
    parser = argparse.ArgumentParser(description="Create visualization artifacts from synthetic analysis outputs")
    parser.add_argument("--outdir", default="output", help="Analysis output directory containing CSV reports")
    parser.add_argument("--vizdir", default=None, help="Visualization output directory (default: <outdir>/visuals)")
    args = parser.parse_args()

    outdir = Path(args.outdir).expanduser().resolve()
    vizdir = Path(args.vizdir).expanduser().resolve() if args.vizdir else (outdir / "visuals")
    vizdir.mkdir(parents=True, exist_ok=True)

    generated = generate_visuals(outdir=outdir, viz_dir=vizdir)
    print(f"Generated {len(generated)} visual file(s) in {vizdir}")
    for file_name in generated:
        print(f"- {file_name}")


if __name__ == "__main__":
    main()
