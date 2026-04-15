#!/usr/bin/env python3
"""
Generate a local mock synthetic dataset for dry-run testing.
"""

import numpy as np
import pandas as pd


def main() -> None:
    np.random.seed(42)
    n = 1200

    df = pd.DataFrame(
        {
            "subject_id": [f"SYN{100000+i}" for i in range(n)],
            "age": np.clip(np.random.normal(48, 12, n).round().astype(int), 18, 90),
            "sex": np.random.choice(["M", "F"], size=n, p=[0.48, 0.52]),
            "site": np.random.choice(["site_a", "site_b", "site_c", "site_d"], size=n, p=[0.25, 0.25, 0.30, 0.20]),
            "zip3": np.random.choice(["021", "100", "303", "606", "941"], size=n),
        }
    )

    # Mimic wide matrix style with many vXX columns.
    for i in range(1, 31):
        col = np.random.normal(loc=50, scale=12, size=n)
        miss_idx = np.random.choice(n, size=int(n * 0.03), replace=False)
        col[miss_idx] = np.nan
        df[f"v{i:02d}"] = np.clip(col, 0, 100).round(1)

    # Inject a few testable edge cases.
    df.loc[5, "subject_id"] = "john.doe@gmail.com"
    df.loc[18, "subject_id"] = "202-555-0199"
    df.loc[77, "v05"] = -9.0
    df = pd.concat([df, df.iloc[[0, 1, 2]]], ignore_index=True)

    out = "mock_level1_synthetic.csv"
    df.to_csv(out, index=False)
    print(f"Wrote {out} with shape {df.shape}")


if __name__ == "__main__":
    main()
