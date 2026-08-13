#include "identifier.h"

#include "unicode_tables.h"
#include "utf8.h"

static bool
classify(const char *s, size_t avail, size_t *len, uint32_t *cp, bool (*is_valid)(uint32_t))
{
    if (avail == 0)
        return false;

    uint32_t c;
    size_t l = utf8_decode_char(s, avail, &c);

    /* utf8_decode_char() reports a length of 1 both for a genuine single-byte
     * character and for its invalid/stray-byte fallback; since this function
     * is only ever meaningful for s[0] >= 0x80 (ASCII is handled elsewhere),
     * a length of 1 here always means "not valid UTF-8 starting here". */
    if (l == 1 && (unsigned char) s[0] >= 0x80)
        return false;

    if (!is_valid(c))
        return false;

    *len = l;
    *cp = c;
    return true;
}

bool
unicode_id_start_char(const char *s, size_t avail, size_t *len, uint32_t *cp)
{
    return classify(s, avail, len, cp, unicode_is_id_start);
}

bool
unicode_id_continue_char(const char *s, size_t avail, size_t *len, uint32_t *cp)
{
    return classify(s, avail, len, cp, unicode_is_id_continue);
}

size_t
bounded_avail(const char *p)
{
    size_t n = 0;
    while (n < 4 && p[n] != '\0')
        n++;
    return n;
}
