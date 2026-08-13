#ifndef Unicode_Tables_h
#define Unicode_Tables_h

/* GENERATED FILE -- do not hand-edit. Regenerate with
 * tools/gen_unicode_tables.py against the Unicode Character Database
 * (see that script for the exact source files/URLs and parsing rules).
 * Unicode version: 17.0.0
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
