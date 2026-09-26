#!/usr/bin/env python3
"""
Script to copy Elixir .ex files: removing comments and empty lines
"""

import os
#import re
from pathlib import Path
import shutil

# /tools/py_scripts/
BASE_DIR = Path(__file__).resolve().parents[2]

def remove_elixir_comments(content: str) -> str:
    result = []
    in_double_string = False
    in_single_string = False
    in_heredoc = False
    heredoc_delimiter = None
    current_sigil = None
    i = 0

    # Main character-by-character processing loop
    while i < len(content):
        # --------------------------
        # Check for HEREDOC start (""" or ''')
        # --------------------------
        if not in_heredoc and content[i:i+3] in ['"""', "'''"]:
            in_heredoc = True
            heredoc_delimiter = content[i:i+3]
            result.append(heredoc_delimiter)
            i += 3
            continue

        # --------------------------
        # Check for HEREDOC end
        # --------------------------
        if in_heredoc and content[i:i+len(heredoc_delimiter)] == heredoc_delimiter:
            in_heredoc = False
            result.append(heredoc_delimiter)
            i += len(heredoc_delimiter)
            heredoc_delimiter = None
            continue

        char = content[i]

        # --------------------------
        # Handle SIGIL start (~X<delim>...<delim>, ~X[delim]...[delim], etc.)
        # --------------------------
        if (not in_double_string and not in_single_string and not in_heredoc 
                and not current_sigil and i + 1 < len(content) 
                and content[i] == '~' and content[i+1].isalpha()):
            sigil_type = content[i+1]
            i += 2  # Skip ~ and sigil letter
            if i < len(content):
                sigil_delim = content[i]
                current_sigil = (sigil_type, sigil_delim)
                result.append(f"~{sigil_type}{sigil_delim}")
                i += 1
                continue

        # --------------------------
        # Handle SIGIL end
        # --------------------------
        if current_sigil:
            _, sigil_delim = current_sigil
            if char == sigil_delim:
                current_sigil = None
                result.append(char)
                i += 1
                continue

        # --------------------------
        # Handle regular STRING escapes/quotes (only if not in heredoc/sigil)
        # --------------------------
        if not in_heredoc and not current_sigil:
            # Double quoted string
            if char == '"' and not in_single_string:
                # Check for escaped quote (\")
                if i > 0 and content[i-1] == '\\':
                    result.append(char)
                else:
                    in_double_string = not in_double_string
                    result.append(char)
                i += 1
                continue
            # Single quoted string (charlist)
            if char == "'" and not in_double_string:
                # Check for escaped quote (\')
                if i > 0 and content[i-1] == '\\':
                    result.append(char)
                else:
                    in_single_string = not in_single_string
                    result.append(char)
                i += 1
                continue

        # --------------------------
        # MINIMAL FIX: Only remove FULL-LINE comments, ignore inline #
        # --------------------------
        if char == '#' and not in_double_string and not in_single_string and not in_heredoc and not current_sigil:
            # Check if we're at the start of a line (or after only whitespace)
            if i == 0 or content[i-1] == '\n' or (i > 0 and content[:i].split('\n')[-1].strip() == ""):
                # Skip rest of line
                while i < len(content) and content[i] != '\n':
                    i += 1
                continue
            # Else: inline #, keep it
            result.append(char)
            i += 1
            continue

        # --------------------------
        # Handle COMMENTS (only if NOT in any string/sigil/heredoc context)
        # --------------------------
        if (char == '#' and not in_double_string and not in_single_string 
                and not in_heredoc and not current_sigil):
            # Skip the rest of the line
            while i < len(content) and content[i] != '\n':
                i += 1
            continue

        # --------------------------
        # Add all other characters to result
        # --------------------------
        result.append(char)
        i += 1

    # Split into lines, strip trailing whitespace, remove empty lines
    processed_lines = [line.rstrip() for line in ''.join(result).split('\n') if line.strip()]
    return '\n'.join(processed_lines)


def process_files(source_dir=None, dest_dir=None):
    source_path = (
        Path(source_dir)
        if source_dir
        else BASE_DIR / "backend" / "lib"
    )

    dest_path = (
        Path(dest_dir)
        if dest_dir
        else BASE_DIR / "backend" / "lib_wo_comments"
    )

    if not source_path.exists():
        print(f"Error: Source directory '{source_path}' does not exist.")
        return

    if not source_path.is_dir():
        print(f"Error: '{source_path}' is not a directory.")
        return
	
    dest_path.mkdir(parents=True, exist_ok=True)

    for file in source_path.iterdir():
        if file.is_file():
            shutil.copy2(file, dest_path / file.name)

    if not source_path.exists():
        print(f"Error: Source directory '{source_dir}' does not exist.")
        return

    # Find all .ex files
    ex_files = list(source_path.rglob("*.ex"))

    if not ex_files:
        print(f"No .ex files found in '{source_dir}'")
        return

    print(f"Found {len(ex_files)} .ex file(s)")

    for ex_file in ex_files:
        # Calculate relative path to maintain directory structure
        relative_path = ex_file.relative_to(source_path)
        dest_file = dest_path / relative_path

        # Create destination directory if it doesn't exist
        dest_file.parent.mkdir(parents=True, exist_ok=True)

        # Read, process, and write
        try:
            with open(ex_file, 'r', encoding='utf-8') as f:
                content = f.read()

            processed_content = remove_elixir_comments(content)

            with open(dest_file, 'w', encoding='utf-8') as f:
                f.write(processed_content)

            print(f"Processed: {relative_path}")

        except Exception as e:
            print(f"Error processing {ex_file}: {e}")

    print(f"\nDone! Files saved to '{dest_dir}'")


if __name__ == "__main__":
    process_files()
