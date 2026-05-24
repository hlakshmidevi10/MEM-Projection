#!/usr/bin/env python3
"""
GAF Validation Script v2

Validates GAF alignment entries against a GFA graph.
Handles both forward and reverse paths by converting reverse paths to forward
and reverse-complementing the expected sequence.

Usage:
    python3 validate_gaf_v2.py <gaf_file> <reads_file> <gfa_file> [--sample N]
"""

import sys
import os
import tempfile
import subprocess
from pathlib import Path
import argparse
import random


def read_gaf_file(gaf_file):
    """Read GAF file and return entries as list of dictionaries."""
    entries = []
    with open(gaf_file, 'r') as f:
        header = f.readline().strip().split('\t')
        for line in f:
            fields = line.strip().split('\t')
            if len(fields) < len(header):
                continue
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


def reverse_complement(sequence):
    """Return reverse complement of DNA sequence."""
    complement = {'A': 'T', 'T': 'A', 'G': 'C', 'C': 'G', 'N': 'N',
                  'a': 't', 't': 'a', 'g': 'c', 'c': 'g', 'n': 'n'}
    return ''.join(complement.get(base, base) for base in reversed(sequence))


def parse_path_string(path_str):
    """
    Parse a GAF path string like '>123>456<789' into list of (node_id, is_reverse).
    Returns (nodes_list, is_all_reverse)
    """
    nodes = []
    current_node = ""
    current_reverse = False
    
    for char in path_str:
        if char == '>' or char == '<':
            if current_node:
                nodes.append((current_node, current_reverse))
            current_reverse = (char == '<')
            current_node = ""
        else:
            current_node += char
    
    if current_node:
        nodes.append((current_node, current_reverse))
    
    return nodes


def convert_to_forward_path(path_str):
    """
    Convert a reverse path to forward path for gaftools.
    <A<B<C becomes >C>B>A (reversed order, forward orientation)
    Returns (forward_path_str, needs_revcomp)
    """
    nodes = parse_path_string(path_str)
    
    if not nodes:
        return path_str, False
    
    # Check if all nodes are reverse
    all_reverse = all(is_rev for _, is_rev in nodes)
    
    if all_reverse:
        # Reverse the order and make all forward
        reversed_nodes = [(node, False) for node, _ in reversed(nodes)]
        forward_path = ''.join(f">{node}" for node, _ in reversed_nodes)
        return forward_path, True
    else:
        # Mixed or all forward - return as is
        return path_str, False


def run_gaftools_find_path(paths_file, gfa_file, output_file):
    """Run gaftools find_path command to get sequences for all paths."""
    cmd = ['gaftools', 'find_path', '--paths_file', paths_file, gfa_file, '-o', output_file]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return True, None
    except subprocess.CalledProcessError as e:
        return False, e.stderr
    except FileNotFoundError:
        return False, "gaftools not found"


def validate_entry(entry, read_sequence, path_sequence, needs_revcomp):
    """Validate a single GAF entry."""
    read_id = entry['read_id']
    read_st = entry['read_st']
    match_len = entry['match_len']
    path_str = entry['path_str']
    path_st = entry['path_st']
    path_name = entry['path_name']

    # Extract matched section from read
    matched_read = read_sequence[read_st:read_st + match_len]

    # For reverse paths, we need to reverse complement the path sequence
    if needs_revcomp:
        path_sequence = reverse_complement(path_sequence)
    
    # Extract corresponding section from path
    path_end = path_st + match_len
    if path_end > len(path_sequence):
        return False, f"Path sequence too short: expected at least {path_end}, got {len(path_sequence)}"

    matched_path = path_sequence[path_st:path_end]

    # Compare sequences
    if matched_read.upper() == matched_path.upper():
        return True, "Match"
    else:
        # Show first difference
        for i, (r, p) in enumerate(zip(matched_read.upper(), matched_path.upper())):
            if r != p:
                return False, f"Mismatch at position {i}: read={r}, path={p}\nRead[{max(0,i-5)}:{i+5}]:  {matched_read[max(0,i-5):i+5]}\nPath[{max(0,i-5)}:{i+5}]:  {matched_path[max(0,i-5):i+5]}"
        return False, f"Length mismatch: read={len(matched_read)}, path={len(matched_path)}"


def main():
    parser = argparse.ArgumentParser(description='Validate GAF entries against GFA graph')
    parser.add_argument('gaf_file', help='Input GAF file')
    parser.add_argument('reads_file', help='Input reads file (one read per line)')
    parser.add_argument('gfa_file', help='Input GFA graph file')
    parser.add_argument('--sample', '-s', type=int, default=None,
                        help='Number of entries to sample (default: all)')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Print details for each entry')
    
    args = parser.parse_args()

    # Check if input files exist
    for file_path in [args.gaf_file, args.reads_file, args.gfa_file]:
        if not os.path.exists(file_path):
            print(f"Error: File {file_path} not found")
            sys.exit(1)

    print("Reading GAF file...")
    gaf_entries = read_gaf_file(args.gaf_file)
    print(f"  Loaded {len(gaf_entries)} entries")

    print("Reading reads file...")
    reads = read_reads_file(args.reads_file)
    print(f"  Loaded {len(reads)} reads")

    # Sample if requested
    if args.sample and args.sample < len(gaf_entries):
        print(f"Sampling {args.sample} entries...")
        gaf_entries = random.sample(gaf_entries, args.sample)

    # Process entries in batches to handle gaftools
    print("Converting paths for gaftools...")
    forward_paths = []
    needs_revcomp_flags = []
    
    for entry in gaf_entries:
        path_str = entry['path_str']
        forward_path, needs_revcomp = convert_to_forward_path(path_str)
        forward_paths.append(forward_path)
        needs_revcomp_flags.append(needs_revcomp)

    # Write paths to temp file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as paths_tmp:
        paths_tmp_name = paths_tmp.name
        for path in forward_paths:
            paths_tmp.write(path + '\n')

    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as path_seq_tmp:
        path_seq_tmp_name = path_seq_tmp.name

    try:
        print("Running gaftools to get path sequences...")
        success, error = run_gaftools_find_path(paths_tmp_name, args.gfa_file, path_seq_tmp_name)
        
        if not success:
            print(f"Failed to run gaftools: {error}")
            sys.exit(1)

        print("Reading path sequences...")
        path_sequences = []
        with open(path_seq_tmp_name, 'r') as f:
            for line in f:
                path_sequences.append(line.strip())

        if len(path_sequences) != len(gaf_entries):
            print(f"Warning: Got {len(path_sequences)} sequences for {len(gaf_entries)} entries")

        print("Validating GAF entries...")
        valid_count = 0
        invalid_count = 0
        error_types = {}

        for i, entry in enumerate(gaf_entries):
            if i >= len(path_sequences):
                print(f"Entry {i+1}: No path sequence available")
                invalid_count += 1
                continue
                
            read_id = entry['read_id']

            # Check if read_id is valid (1-based)
            if read_id < 1 or read_id > len(reads):
                print(f"Entry {i+1}: Invalid read_id {read_id} (only {len(reads)} reads available)")
                invalid_count += 1
                continue

            read_sequence = reads[read_id - 1]
            is_valid, message = validate_entry(entry, read_sequence, path_sequences[i], needs_revcomp_flags[i])

            if is_valid:
                valid_count += 1
                if args.verbose:
                    print(f"Entry {i+1}: VALID - {entry['path_name']}")
            else:
                invalid_count += 1
                error_key = message.split(':')[0] if ':' in message else message[:50]
                error_types[error_key] = error_types.get(error_key, 0) + 1
                if args.verbose or invalid_count <= 10:
                    print(f"Entry {i+1}: INVALID - {entry['path_name']} - {message}")

        print(f"\n{'='*60}")
        print("VALIDATION SUMMARY")
        print(f"{'='*60}")
        print(f"Total entries:   {len(gaf_entries)}")
        print(f"Valid entries:   {valid_count} ({100*valid_count/len(gaf_entries):.2f}%)")
        print(f"Invalid entries: {invalid_count} ({100*invalid_count/len(gaf_entries):.2f}%)")
        
        if error_types:
            print(f"\nError breakdown:")
            for error_type, count in sorted(error_types.items(), key=lambda x: -x[1]):
                print(f"  {error_type}: {count}")
        
        print(f"{'='*60}")

    finally:
        # Clean up temporary files
        if os.path.exists(paths_tmp_name):
            os.unlink(paths_tmp_name)
        if os.path.exists(path_seq_tmp_name):
            os.unlink(path_seq_tmp_name)


if __name__ == "__main__":
    main()
