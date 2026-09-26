#!/usr/bin/env python3

import sys
from collections import defaultdict


def parse_log(filepath):
    """Parse log file, return dict {ih_hex: count}"""
    data = {}
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) >= 2:
                ih_hex = parts[0].lower()
                count = int(parts[1])
                data[ih_hex] = count
    return data


def main():
    file_a = sys.argv[1] if len(sys.argv) > 1 else "frequent_ihs_a.log"
    file_b = sys.argv[2] if len(sys.argv) > 2 else "frequent_ihs_b.log"

    data_a = parse_log(file_a)
    data_b = parse_log(file_b)

    # Find intersection
    common_ihs = set(data_a.keys()) & set(data_b.keys())

    if not common_ihs:
        print("No matching infohashes found.")
        return

    # Build results with combined frequency for sorting
    results = []
    for ih in common_ihs:
        freq_a = data_a[ih]
        freq_b = data_b[ih]
        results.append((ih, freq_a, freq_b, freq_a + freq_b))

    # Sort by combined frequency descending
    results.sort(key=lambda x: x[3], reverse=True)

    print(f"Found {len(common_ihs)} matching infohashes:\n")
    print(f"{'INFOHASH':<44} {'A':>6} {'B':>6} {'TOTAL':>7}")
    print("-" * 65)

    for ih, freq_a, freq_b, total in results:
        print(f"{ih:<44} {freq_a:>6} {freq_b:>6} {total:>7}")

    print("-" * 65)
    print(f"Total matches: {len(results)}")
    print(f"File A unique: {len(data_a)}, File B unique: {len(data_b)}")


if __name__ == "__main__":
    main()
