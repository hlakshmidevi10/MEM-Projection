#!/usr/bin/env python3
import sys
import os
import tempfile
import subprocess
from pathlib import Path

def read_gaf_file(gaf_file):
    """Read GAF file and return entries as list of dictionaries."""
    entries = []
    with open(gaf_file, 'r') as f:
        header = f.readline().strip().split('\t')
        for line in f:
            fields = line.strip().split('\t')
            entry = dict(zip(header, fields))
            # Convert numeric fields
            for field in ['read_id', 'read_st', 'path_len', 'path_st', 'path_end', 'match_len']:
                entry[field] = int(entry[field])
            entries.append(entry)
    return entries

def read_reads_file(reads_file):
    """Read reads.txt file and return list of reads."""
    reads = []
    with open(reads_file, 'r') as f:
        for line in f:
            reads.append(line.strip())
    return reads

def extract_paths_to_file(gaf_entries, output_file):
    """Extract all path_str values to a temporary file for gaftools."""
    with open(output_file, 'w') as f:
        for entry in gaf_entries:
            path = entry['path_str']
            print("writing path str to file: ", path)
            f.write(path + '\n')

def run_gaftools_find_path(paths_file, gfa_file, output_file):
    """Run gaftools find_path command to get sequences for all paths."""
    cmd = ['gaftools', 'find_path', '--paths_file', paths_file, gfa_file, '-o', output_file]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return True
    except subprocess.CalledProcessError as e:
        print(f"Error running gaftools: {e}")
        print(f"Command output: {e.stdout}")
        print(f"Command error: {e.stderr}")
        return False
    except FileNotFoundError:
        print("Error: gaftools not found. Please ensure it's installed and in your PATH.")
        return False

def read_path_sequences(path_seq_file):
    """Read the output from gaftools and return a list of sequences"""
    path_sequences = []
    with open(path_seq_file, 'r') as f:
        for line in f:
            line = line.strip()
            path_sequences.append(line)
    return path_sequences

def validate_entry(entry, read_sequence, path_sequence):
    """Validate a single GAF entry."""
    read_id = entry['read_id']
    read_st = entry['read_st']
    match_len = entry['match_len']
    path_str = entry['path_str']
    path_st = entry['path_st']
    path_name = entry['path_name']

    # Extract matched section from read
    matched_read = read_sequence[read_st:read_st + match_len]


    # Extract corresponding section from path
    path_end = path_st + match_len
    if path_end > len(path_sequence):
        return False, f"Path sequence too short: expected at least {path_end}, got {len(path_sequence)}"

    matched_path = path_sequence[path_st:path_end]

    # Not reqd as gaftools returns the reverse complement sequence from the path direction (< / >) in path_str
    # # Handle reverse complement for reverse paths
    # if '<' in path_str:
    #     matched_path = reverse_complement(matched_path)

    # Compare sequences
    if matched_read.upper() == matched_path.upper():
        return True, "Match"
    else:
        return False, f"Sequence mismatch:\nRead:  {matched_read}\nPath:  {matched_path}"

def reverse_complement(sequence):
    """Return reverse complement of DNA sequence."""
    complement = {'A': 'T', 'T': 'A', 'G': 'C', 'C': 'G', 'N': 'N'}
    return ''.join(complement.get(base.upper(), base) for base in reversed(sequence))

def main():
    if len(sys.argv) != 4:
        print("Usage: python3 validate_gaf.py <gaf_file> <reads_file> <gfa_file>")
        sys.exit(1)

    gaf_file = sys.argv[1]
    reads_file = sys.argv[2]
    gfa_file = sys.argv[3]

    # Check if input files exist
    for file_path in [gaf_file, reads_file, gfa_file]:
        if not os.path.exists(file_path):
            print(f"Error: File {file_path} not found")
            sys.exit(1)

    print("Reading GAF file...")
    gaf_entries = read_gaf_file(gaf_file)

    print("Reading reads file...")
    reads = read_reads_file(reads_file)

    # Create temporary files
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as paths_tmp:
        paths_tmp_name = paths_tmp.name
        print("Extracting unique paths...")
        extract_paths_to_file(gaf_entries, paths_tmp_name)

    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as path_seq_tmp:
        path_seq_tmp_name = path_seq_tmp.name

    try:
        print("Running gaftools to get path sequences...")
        if not run_gaftools_find_path(paths_tmp_name, gfa_file, path_seq_tmp_name):
            print("Failed to run gaftools")
            sys.exit(1)

        print("Reading path sequences...")
        path_sequences = read_path_sequences(path_seq_tmp_name)

        print("Validating GAF entries...")
        valid_count = 0
        total_count = len(gaf_entries)

        for i, entry in enumerate(gaf_entries):
            read_id = entry['read_id']

            # Check if read_id is valid
            if read_id > len(reads):
                print(f"Entry {i+1}: Invalid read_id {read_id} (only {len(reads)} reads available)")
                continue

            # read_id is 1-based
            read_sequence = reads[read_id - 1]
            is_valid, message = validate_entry(entry, read_sequence, path_sequences[i])

            if is_valid:
                valid_count += 1
                print(f"\nEntry {i+1}: VALID - {entry['path_name']}")
            else:
                print(f"\nEntry {i+1}: INVALID - {entry['path_name']} - {message}")

        print(f"\nValidation complete: {valid_count}/{total_count} entries are valid")

    finally:
        # Clean up temporary files
        if os.path.exists(paths_tmp_name):
            os.unlink(paths_tmp_name)
        if os.path.exists(path_seq_tmp_name):
            os.unlink(path_seq_tmp_name)

if __name__ == "__main__":
    main()