#!/usr/bin/env python3
"""Generates src/include/unicode_tables.h and src/unicode_tables.cc from the
official Unicode Character Database (UCD) text files. This is a one-time (or
rerun-on-Unicode-version-bump) offline step -- the server build itself never
touches the network or re-parses UCD data.

Usage:
    python3 tools/gen_unicode_tables.py <ucd-dir> [--unicode-version X.Y.Z]

<ucd-dir> must contain DerivedCoreProperties.txt, CaseFolding.txt, and
UnicodeData.txt, downloaded from e.g.
https://www.unicode.org/Public/UCD/latest/ucd/

Output is written to src/include/unicode_tables.h and src/unicode_tables.cc,
relative to the repository root (this script's grandparent directory).
"""

import re
import sys
from pathlib import Path


def parse_derived_core_ranges(path, prop_name):
    """Returns a sorted, merged list of (lo, hi) inclusive codepoint ranges
    for the given derived property (e.g. 'XID_Start', 'XID_Continue')."""
    pattern = re.compile(
        r'^([0-9A-Fa-f]{4,6})(?:\.\.([0-9A-Fa-f]{4,6}))?\s*;\s*' + prop_name + r'\s*(?:#|$)'
    )
    ranges = []
    with open(path, encoding='utf-8') as f:
        for line in f:
            m = pattern.match(line)
            if not m:
                continue
            lo = int(m.group(1), 16)
            hi = int(m.group(2), 16) if m.group(2) else lo
            ranges.append((lo, hi))

    ranges.sort()
    merged = []
    for lo, hi in ranges:
        if merged and lo <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
        else:
            merged.append((lo, hi))
    return merged


def parse_case_folding(path):
    """Returns a sorted list of (cp, folded_cp) pairs from CaseFolding.txt,
    keeping only status C (common) and S (simple) lines -- skipping F (full,
    which can expand to multiple codepoints) and T (Turkic-locale-specific
    alternates), per the project's explicit simple-case-folding-only,
    no-locale-variants scope decision."""
    pairs = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.split('#', 1)[0].strip()
            if not line:
                continue
            fields = [x.strip() for x in line.split(';')]
            if len(fields) < 3:
                continue
            cp_hex, status, mapping_hex = fields[0], fields[1], fields[2]
            if status not in ('C', 'S'):
                continue
            cp = int(cp_hex, 16)
            mapped = int(mapping_hex, 16)
            if mapped != cp:
                pairs[cp] = mapped
    return sorted(pairs.items())


def parse_unicode_data_case_mappings(path):
    """Returns two sorted lists of (cp, mapped_cp) pairs: simple uppercase
    (field 12) and simple lowercase (field 13) from UnicodeData.txt. Range
    entries (e.g. '<CJK Ideograph Extension A, First>'/'Last>', used for
    large contiguous blocks like CJK/Hangul) always have empty mapping
    fields and are naturally skipped -- no special-casing needed."""
    upper = {}
    lower = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            fields = line.rstrip('\n').split(';')
            if len(fields) < 14:
                continue
            cp = int(fields[0], 16)
            upper_hex = fields[12].strip()
            lower_hex = fields[13].strip()
            if upper_hex:
                mapped = int(upper_hex, 16)
                if mapped != cp:
                    upper[cp] = mapped
            if lower_hex:
                mapped = int(lower_hex, 16)
                if mapped != cp:
                    lower[cp] = mapped
    return sorted(upper.items()), sorted(lower.items())


def format_ranges(name, ranges):
    lines = [f'static const CPRange {name}[] = {{']
    for i in range(0, len(ranges), 4):
        chunk = ranges[i:i + 4]
        entries = ', '.join(f'{{0x{lo:04X}, 0x{hi:04X}}}' for lo, hi in chunk)
        lines.append(f'    {entries},')
    lines.append('};')
    lines.append(f'static const size_t {name}_count = sizeof({name}) / sizeof({name}[0]);')
    return '\n'.join(lines)


def format_pairs(name, pairs):
    lines = [f'static const CPPair {name}[] = {{']
    for i in range(0, len(pairs), 4):
        chunk = pairs[i:i + 4]
        entries = ', '.join(f'{{0x{cp:04X}, 0x{mapped:04X}}}' for cp, mapped in chunk)
        lines.append(f'    {entries},')
    lines.append('};')
    lines.append(f'static const size_t {name}_count = sizeof({name}) / sizeof({name}[0]);')
    return '\n'.join(lines)


HEADER_TEMPLATE = """#ifndef Unicode_Tables_h
#define Unicode_Tables_h

/* GENERATED FILE -- do not hand-edit. Regenerate with
 * tools/gen_unicode_tables.py against the Unicode Character Database
 * (see that script for the exact source files/URLs and parsing rules).
 * Unicode version: {unicode_version}
 */

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

/* True iff `cp` may start a MOOcode identifier (Unicode XID_Start), or
 * continue one after the first character (XID_Continue). ASCII identifier
 * characters (isalpha/isalnum/'_') are handled separately by callers; these
 * only need to be consulted for cp >= 0x80. */
extern bool unicode_is_id_start(uint32_t cp);
extern bool unicode_is_id_continue(uint32_t cp);

/* Unicode simple case folding (comparison-oriented; see CaseFolding.txt
 * status C+S, never F or T) and simple upper/lowercase mapping
 * (display-oriented; see UnicodeData.txt fields 12/13). All three are
 * always exactly one codepoint in, one codepoint out -- no multi-character
 * expansions (e.g. German sharp s to "SS") and no locale-specific
 * alternates (e.g. Turkish dotless i), by design. A codepoint with no
 * entry in the underlying table maps to itself. */
extern uint32_t unicode_casefold(uint32_t cp);
extern uint32_t unicode_simple_upper(uint32_t cp);
extern uint32_t unicode_simple_lower(uint32_t cp);

#endif /* Unicode_Tables_h */
"""

SOURCE_TEMPLATE = """#include "unicode_tables.h"

/* GENERATED FILE -- do not hand-edit. See unicode_tables.h. */

struct CPRange {{
    uint32_t lo, hi;
}};

struct CPPair {{
    uint32_t cp, mapped;
}};

{xid_start_table}

{xid_continue_table}

{casefold_table}

{upper_table}

{lower_table}

static bool
range_lookup(const CPRange *table, size_t count, uint32_t cp)
{{
    size_t lo = 0, hi = count;
    while (lo < hi) {{
        size_t mid = lo + (hi - lo) / 2;
        if (cp < table[mid].lo)
            hi = mid;
        else if (cp > table[mid].hi)
            lo = mid + 1;
        else
            return true;
    }}
    return false;
}}

static uint32_t
pair_lookup(const CPPair *table, size_t count, uint32_t cp)
{{
    size_t lo = 0, hi = count;
    while (lo < hi) {{
        size_t mid = lo + (hi - lo) / 2;
        if (table[mid].cp < cp)
            lo = mid + 1;
        else
            hi = mid;
    }}
    if (lo < count && table[lo].cp == cp)
        return table[lo].mapped;
    return cp;
}}

bool
unicode_is_id_start(uint32_t cp)
{{
    return range_lookup(kXidStartRanges, kXidStartRanges_count, cp);
}}

bool
unicode_is_id_continue(uint32_t cp)
{{
    return range_lookup(kXidContinueRanges, kXidContinueRanges_count, cp);
}}

uint32_t
unicode_casefold(uint32_t cp)
{{
    return pair_lookup(kCaseFold, kCaseFold_count, cp);
}}

uint32_t
unicode_simple_upper(uint32_t cp)
{{
    return pair_lookup(kSimpleUpper, kSimpleUpper_count, cp);
}}

uint32_t
unicode_simple_lower(uint32_t cp)
{{
    return pair_lookup(kSimpleLower, kSimpleLower_count, cp);
}}
"""


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    ucd_dir = Path(sys.argv[1])
    unicode_version = 'unknown'
    for arg in sys.argv[2:]:
        if arg.startswith('--unicode-version='):
            unicode_version = arg.split('=', 1)[1]

    if unicode_version == 'unknown':
        # Try to sniff it from CaseFolding.txt's header comment.
        try:
            with open(ucd_dir / 'CaseFolding.txt', encoding='utf-8') as f:
                first_line = f.readline()
            m = re.search(r'CaseFolding-([\d.]+)\.txt', first_line)
            if m:
                unicode_version = m.group(1)
        except OSError:
            pass

    xid_start = parse_derived_core_ranges(ucd_dir / 'DerivedCoreProperties.txt', 'XID_Start')
    xid_continue = parse_derived_core_ranges(ucd_dir / 'DerivedCoreProperties.txt', 'XID_Continue')
    casefold = parse_case_folding(ucd_dir / 'CaseFolding.txt')
    upper, lower = parse_unicode_data_case_mappings(ucd_dir / 'UnicodeData.txt')

    print(f'Unicode version: {unicode_version}', file=sys.stderr)
    print(f'XID_Start ranges: {len(xid_start)}', file=sys.stderr)
    print(f'XID_Continue ranges: {len(xid_continue)}', file=sys.stderr)
    print(f'Case fold pairs: {len(casefold)}', file=sys.stderr)
    print(f'Simple upper pairs: {len(upper)}', file=sys.stderr)
    print(f'Simple lower pairs: {len(lower)}', file=sys.stderr)

    repo_root = Path(__file__).resolve().parent.parent
    header_path = repo_root / 'src' / 'include' / 'unicode_tables.h'
    source_path = repo_root / 'src' / 'unicode_tables.cc'

    header_path.write_text(HEADER_TEMPLATE.format(unicode_version=unicode_version), encoding='utf-8')

    source = SOURCE_TEMPLATE.format(
        xid_start_table=format_ranges('kXidStartRanges', xid_start),
        xid_continue_table=format_ranges('kXidContinueRanges', xid_continue),
        casefold_table=format_pairs('kCaseFold', casefold),
        upper_table=format_pairs('kSimpleUpper', upper),
        lower_table=format_pairs('kSimpleLower', lower),
    )
    source_path.write_text(source, encoding='utf-8')

    print(f'Wrote {header_path}', file=sys.stderr)
    print(f'Wrote {source_path}', file=sys.stderr)


if __name__ == '__main__':
    main()
