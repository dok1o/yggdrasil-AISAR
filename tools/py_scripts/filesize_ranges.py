import json
import sys

KB, MB, GB = 1024, 1024**2, 1024**3

BOUNDARIES = [
    (1 * KB,    "0 - 1 KB"),
    (4 * KB,    "1 - 4 KB"),
    (16 * KB,   "4 - 16 KB"),
    (32 * KB,   "16 - 32 KB"),
    (64 * KB,   "32 - 64 KB"),
    (128 * KB,   "64 - 128 KB"),
    (256 * KB,  "128 - 256 KB"),
    (512 * KB,  "256 - 512 KB"),
    (768 * KB,  "512 - 768 KB"),
    (1 * MB,    "768 KB - 1 MB"),
    (2 * MB,    "1 - 2 MB"),
    (4 * MB,    "2 - 4 MB"),
    (8 * MB,    "4 - 8 MB"),
    (12 * MB,   "8 - 12 MB"),
    (16 * MB,   "12 - 16 MB"),
    (32 * MB,   "16 - 32 MB"),
    (64 * MB,   "32 - 64 MB"),
    (128 * MB,  "64 - 128 MB"),
    (256 * MB,  "128 - 256 MB"),
    (512 * MB,  "256 - 512 MB"),
    (1 * GB,    "512 MB - 1 GB"),
    (2 * GB,    "1 - 2 GB"),
    (4 * GB,    "2 - 4 GB"),
    (None,      "4 GB+"),
]

def get_size_bucket(size):
    for i, (boundary, _) in enumerate(BOUNDARIES):
        if boundary is None or size < boundary:
            return i
    return len(BOUNDARIES) - 1

def format_human(bytes_val):
    if bytes_val == float('inf'): return "N/A"
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_val < 1024.0:
            return f"{bytes_val:,.1f} {unit}"
        bytes_val /= 1024.0
    return f"{bytes_val:,.1f} PB"

def process_stats(file_path):
    num_buckets = len(BOUNDARIES)
    buckets = [0] * num_buckets
    signature = 0
    total_files = 0
    total_torrents = 0
    min_s, max_s = float('inf'), 0

    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            for line in f:
                try:
                    data = json.loads(line)
                    total_torrents += 1

                    for file_entry in data.get('files', []):
                        size = file_entry.get('size', 0)
                        total_files += 1
                        if size < min_s: min_s = size
                        if size > max_s: max_s = size

                        idx = get_size_bucket(size)
                        buckets[idx] += 1
                        signature |= (1 << idx)

                except (json.JSONDecodeError, KeyError):
                    continue

        if total_files == 0:
            print("No file data found.")
            return

        # Header
        print(f"\n{'Bit':<4} | {'Size Range':<20} | {'Count':<10} | {'%':<7} | Distribution")
        print("-" * 90)

        max_count = max(buckets) if max(buckets) > 0 else 1
        for i in range(num_buckets):
            label = BOUNDARIES[i][1]
            count = buckets[i]
            pct = (count / total_files) * 100
            bar = "█" * int((count / max_count) * 30)
            marker = "●" if (signature & (1 << i)) else "○"
            print(f"{marker} {i:<2} | {label:<20} | {count:<10,} | {pct:>5.1f}% | {bar}")

        print("-" * 90)
        print(f"Torrents:    {total_torrents:,}")
        print(f"Total Files: {total_files:,}")
        print(f"Min Size:    {format_human(min_s)}")
        print(f"Max Size:    {format_human(max_s)}")
        
        # Binary signature adjusted for the number of buckets
        bin_sig = format(signature, f'0{num_buckets}b')
        hex_sig = format(signature, f'0{ (num_buckets+3)//4 }X')
        print(f"\nSignature:   {bin_sig} (0x{hex_sig})")

    except FileNotFoundError:
        print(f"Error: {file_path} not found.")

if __name__ == "__main__":
    process_stats(sys.argv[1] if len(sys.argv) > 1 else 'data.jsonl')
