#ifndef Identifier_h
#define Identifier_h

#include <stddef.h>
#include <stdint.h>

/* Classifies the UTF-8 character beginning at s[0] (up to `avail` bytes
 * available) as a valid MOOcode identifier character: unicode_id_start_char
 * for the first character of an identifier (Unicode XID_Start),
 * unicode_id_continue_char for every character after that (XID_Continue).
 * On success, returns true and sets *len (the character's raw byte length,
 * 1-4) and *cp (its codepoint). On failure -- malformed/incomplete UTF-8, or
 * a well-formed character that isn't XID_Start/XID_Continue -- returns
 * false and leaves *len and *cp untouched.
 *
 * Only meaningful for s[0] >= 0x80; ASCII identifier characters
 * (isalpha()/isalnum()/'_') are handled separately by callers. This is the
 * single shared classification point used by both the lexer (src/parser.y)
 * and the unparser (ok_identifier() in src/unparse.cc), so the two can
 * never drift apart on what counts as a valid identifier character. */
extern bool unicode_id_start_char(const char *s, size_t avail, size_t *len, uint32_t *cp);
extern bool unicode_id_continue_char(const char *s, size_t avail, size_t *len, uint32_t *cp);

/* Returns how many bytes starting at `p` are safe to read (up to 4) without
 * running past its NUL terminator, so a caller can safely hand that many
 * bytes to utf8_decode_char()-based logic without either an out-of-bounds
 * read or a full strlen() scan of the whole string. */
extern size_t bounded_avail(const char *p);

#endif /* Identifier_h */
