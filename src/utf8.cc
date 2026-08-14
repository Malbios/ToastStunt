#include "utf8.h"
#include "storage.h"

size_t
utf8_decode_char(const char *s, size_t avail, uint32_t *cp)
{
    unsigned char b0;
    size_t len;
    uint32_t value;
    unsigned char lo1 = 0x80, hi1 = 0xBF; /* valid range for the 2nd byte */

    if (avail == 0) {
        if (cp)
            *cp = 0;
        return 0;
    }

    b0 = (unsigned char) s[0];

    if (b0 < 0x80) {
        if (cp)
            *cp = b0;
        return 1;
    }

    if (b0 >= 0xC2 && b0 <= 0xDF) {
        len = 2;
        value = b0 & 0x1F;
    } else if (b0 >= 0xE0 && b0 <= 0xEF) {
        len = 3;
        value = b0 & 0x0F;
        if (b0 == 0xE0)
            lo1 = 0xA0; /* exclude overlong 3-byte encodings */
        else if (b0 == 0xED)
            hi1 = 0x9F; /* exclude the UTF-16 surrogate range */
    } else if (b0 >= 0xF0 && b0 <= 0xF4) {
        len = 4;
        value = b0 & 0x07;
        if (b0 == 0xF0)
            lo1 = 0x90; /* exclude overlong 4-byte encodings */
        else if (b0 == 0xF4)
            hi1 = 0x8F; /* cap the scalar value at U+10FFFF */
    } else {
        /* A stray continuation byte (0x80-0xBF), an overlong 2-byte
         * lead (0xC0-0xC1), or a byte that's never valid anywhere in
         * UTF-8 (0xF5-0xFF) -- treated as its own one-byte character. */
        if (cp)
            *cp = b0;
        return 1;
    }

    if (len > avail) {
        if (cp)
            *cp = b0;
        return 1;
    }

    for (size_t i = 1; i < len; i++) {
        unsigned char b = (unsigned char) s[i];
        unsigned char lo = (i == 1) ? lo1 : 0x80;
        unsigned char hi = (i == 1) ? hi1 : 0xBF;
        if (b < lo || b > hi) {
            if (cp)
                *cp = b0;
            return 1;
        }
        value = (value << 6) | (b & 0x3F);
    }

    if (cp)
        *cp = value;
    return len;
}

size_t
utf8_strlen(const char *s, size_t byte_len)
{
    size_t count = 0;
    size_t offset = 0;

    while (offset < byte_len) {
        offset += utf8_decode_char(s + offset, byte_len - offset, nullptr);
        count++;
    }

    return count;
}

size_t
utf8_offset_of_char(const char *s, size_t byte_len, size_t char_index,
                     bool ascii_hint, const char *cursor_key)
{
    if (ascii_hint) {
        size_t candidate = char_index - 1;
        return candidate < byte_len ? candidate : byte_len;
    }

    size_t offset = 0;
    size_t n = 1;

    if (cursor_key) {
        size_t hint_n, hint_offset;
        if (memo_cursor_hint(cursor_key, &hint_n, &hint_offset)
                && hint_n <= char_index && hint_offset <= byte_len) {
            n = hint_n;
            offset = hint_offset;
        }
    }

    while (n < char_index && offset < byte_len) {
        offset += utf8_decode_char(s + offset, byte_len - offset, nullptr);
        n++;
    }

    if (cursor_key)
        memo_set_cursor(cursor_key, n, offset);

    return offset;
}

size_t
utf8_char_index_of_offset(const char *s, size_t byte_len, size_t byte_offset,
                           bool ascii_hint, const char *cursor_key)
{
    if (ascii_hint) {
        size_t capped = byte_offset < byte_len ? byte_offset : byte_len;
        return capped + 1;
    }

    size_t offset = 0;
    size_t n = 1;

    if (cursor_key) {
        size_t hint_n, hint_offset;
        if (memo_cursor_hint(cursor_key, &hint_n, &hint_offset)
                && hint_offset <= byte_offset && hint_offset <= byte_len) {
            n = hint_n;
            offset = hint_offset;
        }
    }

    while (offset < byte_len) {
        size_t clen = utf8_decode_char(s + offset, byte_len - offset, nullptr);
        if (byte_offset < offset + clen) {
            if (cursor_key)
                memo_set_cursor(cursor_key, n, offset);
            return n;
        }
        offset += clen;
        n++;
    }

    if (cursor_key)
        memo_set_cursor(cursor_key, n, offset);

    return n;
}

size_t
utf8_encode_char(uint32_t cp, char *buf)
{
    if (cp <= 0x7F) {
        buf[0] = (char) cp;
        return 1;
    } else if (cp <= 0x7FF) {
        buf[0] = (char) (0xC0 | (cp >> 6));
        buf[1] = (char) (0x80 | (cp & 0x3F));
        return 2;
    } else if (cp <= 0xFFFF) {
        if (cp >= 0xD800 && cp <= 0xDFFF)
            return 0; /* lone surrogate: not a valid scalar value */
        buf[0] = (char) (0xE0 | (cp >> 12));
        buf[1] = (char) (0x80 | ((cp >> 6) & 0x3F));
        buf[2] = (char) (0x80 | (cp & 0x3F));
        return 3;
    } else if (cp <= 0x10FFFF) {
        buf[0] = (char) (0xF0 | (cp >> 18));
        buf[1] = (char) (0x80 | ((cp >> 12) & 0x3F));
        buf[2] = (char) (0x80 | ((cp >> 6) & 0x3F));
        buf[3] = (char) (0x80 | (cp & 0x3F));
        return 4;
    }
    return 0; /* beyond U+10FFFF: not encodable */
}
