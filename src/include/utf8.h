/* UTF-8 decode-and-advance primitive, and the codepoint-indexed
 * operations built on it, for treating MOO strings as sequences of
 * Unicode characters rather than raw bytes.
 *
 * Invalid-byte policy: any byte that isn't part of a well-formed UTF-8
 * sequence (a stray continuation byte, an overlong encoding, a lone
 * surrogate U+D800-U+DFFF, or anything beyond U+10FFFF) is treated as
 * its own one-byte "character". This keeps the sum of every character's
 * byte length always equal to the string's total byte length, an
 * invariant every function here (and every caller) relies on for
 * correctness and termination.
 */

#ifndef Utf8_h
#define Utf8_h

#include <stddef.h>
#include <stdint.h>

/* Decode one character starting at s[0]; only ever reads s[0..avail).
 * Always consumes between 1 and min(4, avail) bytes, never 0, so
 * callers can loop unconditionally without risk of getting stuck. If
 * cp is not null, writes the decoded scalar value there (or the raw
 * byte value, for an invalid/stray byte treated as its own character).
 */
extern size_t utf8_decode_char(const char *s, size_t avail, uint32_t *cp);

/* Bytes occupied by the character starting at s[0]. */
static inline size_t
utf8_char_byte_length(const char *s, size_t avail)
{
    return utf8_decode_char(s, avail, nullptr);
}

/* Character (not byte) count of s[0..byte_len). */
extern size_t utf8_strlen(const char *s, size_t byte_len);

/* Byte offset at which the char_index'th (1-based) character begins.
 * char_index may be one greater than the string's character count, in
 * which case this returns byte_len -- usable directly as an exclusive
 * end bound for [i..j] ranges. char_index must be >= 1 and callers are
 * expected to have already range-checked it; out-of-range values clamp
 * to byte_len rather than reading past the string.
 *
 * ascii_hint: pass true iff the caller has already established (e.g.
 * via memo_cplen(base) == memo_strlen(base)) that the string this
 * character range came from is pure ASCII -- valid for any substring of
 * such a string too, so it's safe to pass even when `s' points into the
 * middle of one. When true, this is an O(1) direct return with no scan.
 *
 * cursor_key: the true base pointer of an interned string (suitable for
 * memo_cursor_hint()/memo_set_cursor() in storage.h), or nullptr. Passing
 * a pointer into the middle of a string here is a memory-safety bug --
 * only pass a value when `s' truly is (or cursor_key otherwise indexes)
 * that same interned string's own allocation start. When non-null and
 * ascii_hint is false, resumes scanning from the last position looked up
 * for this string when that's at or before char_index, and records the
 * new position afterward, turning sequential forward access into O(n)
 * total instead of O(n^2); any other access pattern falls back to
 * today's scan-from-0 behavior, with identical results either way.
 */
extern size_t utf8_offset_of_char(const char *s, size_t byte_len, size_t char_index,
                                   bool ascii_hint, const char *cursor_key);

/* Inverse of the above: the (1-based) index of the character containing
 * byte_offset. byte_offset == byte_len returns one past the last
 * character's index, mirroring utf8_offset_of_char's convention.
 * ascii_hint/cursor_key as above.
 */
extern size_t utf8_char_index_of_offset(const char *s, size_t byte_len, size_t byte_offset,
                                         bool ascii_hint, const char *cursor_key);

/* Encode a single Unicode scalar value as UTF-8 into buf, which must
 * have room for at least 4 bytes. Returns the number of bytes written
 * (1-4), or 0 if cp is not a valid, encodable scalar value (a surrogate
 * U+D800-U+DFFF, or beyond U+10FFFF).
 */
extern size_t utf8_encode_char(uint32_t cp, char *buf);

#endif /* Utf8_h */
