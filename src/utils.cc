/******************************************************************************
  Copyright (c) 1992, 1995, 1996 Xerox Corporation.  All rights reserved.
  Portions of this code were written by Stephen White, aka ghond.
  Use and copying of this software and preparation of derivative works based
  upon this software are permitted.  Any distribution of this software or
  derivative works must comply with all applicable United States export
  control laws.  This software is made available AS IS, and Xerox Corporation
  makes no warranty about the software, its performance or its conformity to
  any specification.  Any person obtaining a copy of this software is requested
  to send their name and post office or electronic mail address to:
    Pavel Curtis
    Xerox PARC
    3333 Coyote Hill Rd.
    Palo Alto, CA 94304
    Pavel@Xerox.Com
 *****************************************************************************/

#include <assert.h>

#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include <unordered_map>
#include <vector>

#include "collection.h"
#include "config.h"
#include "db.h"
#include "db_io.h"
#ifdef ENABLE_GC
#include "garbage.h"
#endif
#include "list.h"
#include "log.h"
#include "map.h"
#include "match.h"
#include "numbers.h"
#include "quota.h"
#include "server.h"
#include "storage.h"
#include "streams.h"
#include "structures.h"
#include "unicode_tables.h"
#include "utf8.h"
#include "waif.h"
#include "utils.h"

/*
 * These versions of strcasecmp() and strncasecmp() depend on ASCII.
 * We implement them here because neither one is in the ANSI standard.
 */

static const char cmap[] =
    "\000\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017"
    "\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037"
    "\040\041\042\043\044\045\046\047\050\051\052\053\054\055\056\057"
    "\060\061\062\063\064\065\066\067\070\071\072\073\074\075\076\077"
    "\100\141\142\143\144\145\146\147\150\151\152\153\154\155\156\157"
    "\160\161\162\163\164\165\166\167\170\171\172\133\134\135\136\137"
    "\140\141\142\143\144\145\146\147\150\151\152\153\154\155\156\157"
    "\160\161\162\163\164\165\166\167\170\171\172\173\174\175\176\177"
    "\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217"
    "\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237"
    "\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257"
    "\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277"
    "\300\301\302\303\304\305\306\307\310\311\312\313\314\315\316\317"
    "\320\321\322\323\324\325\326\327\330\331\332\333\334\335\336\337"
    "\340\341\342\343\344\345\346\347\350\351\352\353\354\355\356\357"
    "\360\361\362\363\364\365\366\367\370\371\372\373\374\375\376\377";

/* Reads one identifier-comparison "unit" at p[0]: for ASCII, that's one
 * byte, folded via cmap[] exactly as before (fast path, zero behavior or
 * performance change for existing ASCII-only verb/property names). For a
 * byte >= 0x80, decodes one UTF-8 character (bounded to at most 4 bytes,
 * and never past the string's own NUL terminator) and folds it via
 * unicode_casefold(). *len is always >= 1, the number of raw bytes
 * consumed; *folded is the value to compare for equality between two
 * characters. Two folded values are equal iff the two source characters
 * are case-equivalent, regardless of whether their raw byte lengths
 * match -- e.g. the Kelvin sign (U+212A, 3 bytes) folds equal to ASCII
 * 'k' (1 byte), which is correct per Unicode simple case folding. This is
 * the single point of truth for case-insensitive character comparison,
 * shared by verbcasecmp(), str_hash(), and unicode_strcasecmp() below, so
 * they can't drift out of sync with each other. */
/* `max_avail' bounds how many bytes of `p' may be looked at, for callers
 * windowed into the middle of a larger NUL-terminated allocation (e.g. a
 * truncated search range) where reading up to the buffer's own NUL would
 * reach past the caller's intended window. Defaults to unbounded (scan to
 * the first NUL within 4 bytes, as before) for the common case of a plain
 * NUL-terminated string. */
static void
fold_peek(const char *p, size_t *len, uint32_t *folded, size_t max_avail = (size_t) -1)
{
    unsigned char c = (unsigned char) *p;
    if (c < 0x80) {
        *len = 1;
        *folded = (unsigned char) cmap[c];
        return;
    }
    size_t bound = max_avail < 4 ? max_avail : 4;
    size_t avail = 0;
    while (avail < bound && p[avail])
        avail++;
    uint32_t cp;
    *len = utf8_decode_char(p, avail, &cp);
    *folded = unicode_casefold(cp);
}

int
verbcasecmp(const char *verb, const char *word)
{
    const unsigned char *w;
    const unsigned char *v = (const unsigned char *) verb;
    enum {
        none, inner, end
    } star;

    if (verb == word) {
        return 1;
    }
    while (*v) {
        w = (const unsigned char *) word;
        star = none;
        while (1) {
            while (*v == '*') {
                v++;
                star = (!*v || *v == ' ') ? end : inner;
            }
            if (!*v || *v == ' ' || !*w)
                break;
            size_t lv, lw;
            uint32_t fv, fw;
            fold_peek((const char *) v, &lv, &fv);
            fold_peek((const char *) w, &lw, &fw);
            if (fv != fw)
                break;
            w += lw;
            v += lv;
        }
        if (!*w ? (star != none || !*v || *v == ' ')
                : (star == end))
            return 1;
        while (*v && *v != ' ')
            v++;
        while (*v == ' ')
            v++;
    }
    return 0;
}

unsigned
str_hash(const char *s)
{
    unsigned ans = 0;

    while (*s) {
        /* Must fold and advance per *character* (via fold_peek()), not
         * per byte: two case-equivalent strings can differ in raw byte
         * length per character (see fold_peek()'s Kelvin sign example),
         * so hashing byte-by-byte could put case-equivalent strings in
         * different buckets. */
        size_t len;
        uint32_t folded;
        fold_peek(s, &len, &folded);
        ans = (ans << 3) + (ans >> 28) + folded;
        s += len;
    }
    return ans;
}

int
unicode_strcasecmp(const char *a, const char *b)
{
    for (;;) {
        size_t la, lb;
        uint32_t fa, fb;
        fold_peek(a, &la, &fa);
        fold_peek(b, &lb, &fb);
        if (fa != fb)
            return fa < fb ? -1 : 1;
        if (fa == 0)
            return 0; /* both strings ended here */
        a += la;
        b += lb;
    }
}

/* Used by the cyclic garbage collector to free values that entered
 * the buffer of possible roots, but subsequently had their refcount
 * drop to zero.  Roughly corresponds to `Free' in Bacon and Rajan.
 */
void
aux_free(Var v)
{
    switch ((int) v.type) {
        case TYPE_LIST:
            myfree(v.v.list, M_LIST);
            break;
        case TYPE_MAP:
            myfree(v.v.tree, M_TREE);
            break;
        case TYPE_ANON:
            assert(db_object_has_flag2(v, FLAG_INVALID));
            myfree(v.v.anon, M_ANON);
            break;
    }
}

#ifdef ENABLE_GC
/* Corresponds to `Decrement' and `Release' in Bacon and Rajan. */
void
complex_free_var(Var v)
{
    switch (v.type) {
        case TYPE_STR:
            if (v.v.str)
                free_str(v.v.str);
            break;
        case TYPE_LIST:
            if (!is_shared_empty(v) && delref(v.v.list) == 0) {
                destroy_list(v);
                gc_set_color(v.v.list, GC_BLACK);
                if (!gc_is_buffered(v.v.list))
                    myfree(v.v.list, M_LIST);
            }
            else
                gc_possible_root(v);
            break;
        case TYPE_MAP:
            if (!is_shared_empty(v) && delref(v.v.tree) == 0) {
                destroy_map(v);
                gc_set_color(v.v.tree, GC_BLACK);
                if (!gc_is_buffered(v.v.tree))
                    myfree(v.v.tree, M_TREE);
            }
            else
                gc_possible_root(v);
            break;
        case TYPE_ITER:
            if (delref(v.v.trav) == 0)
                destroy_iter(v);
            break;
        case TYPE_WAIF:
            if (delref(v.v.waif) == 0) {
                if (destroyed_waifs.count(v.v.waif) == 0)
                    destroyed_waifs[v.v.waif] = false;
            }
            break;
        case TYPE_ANON:
            /* The first time an anonymous object's reference count drops
             * to zero, it isn't immediately destroyed/freed.  Instead, it
             * is queued up to be "recycled" (to have its `recycle' verb
             * called) -- this has the effect of (perhaps temporarily)
             * creating a new reference to the object, as well as setting
             * the recycled flag and (eventually) the invalid flag.
             */
            if (v.v.anon) {
                if (delref(v.v.anon) == 0) {
                    if (db_object_has_flag2(v, FLAG_RECYCLED)) {
                        gc_set_color(v.v.anon, GC_BLACK);
                        if (!gc_is_buffered(v.v.anon))
                            myfree(v.v.anon, M_ANON);
                    }
                    else if (db_object_has_flag2(v, FLAG_INVALID)) {
                        incr_quota(db_object_owner2(v));
                        db_destroy_anonymous_object(v.v.anon);
                        gc_set_color(v.v.anon, GC_BLACK);
                        if (!gc_is_buffered(v.v.anon))
                            myfree(v.v.anon, M_ANON);
                    }
                    else {
                        queue_anonymous_object(v);
                    }
                }
                else {
                    gc_possible_root(v);
                }
            }
            break;
    }
}
#else
void
complex_free_var(Var v)
{
    switch ((int) v.type) {
        case TYPE_STR:
            if (v.v.str)
                free_str(v.v.str);
            break;
        case TYPE_LIST:
            if (!is_shared_empty(v) && delref(v.v.list) == 0)
                destroy_list(v);
            break;
        case TYPE_MAP:
            if (!is_shared_empty(v) && delref(v.v.tree) == 0)
                destroy_map(v);
            break;
        case TYPE_ITER:
            if (delref(v.v.trav) == 0)
                destroy_iter(v);
            break;
        case TYPE_WAIF:
            if (delref(v.v.waif) == 0) {
                if (destroyed_waifs.count(v.v.waif) == 0) {
                    destroyed_waifs[v.v.waif] = false;
                }
            }
            break;
        case TYPE_ANON:
            if (v.v.anon && delref(v.v.anon) == 0) {
                if (db_object_has_flag2(v, FLAG_RECYCLED)) {
                    myfree(v.v.anon, M_ANON);
                }
                else if (db_object_has_flag2(v, FLAG_INVALID)) {
                    incr_quota(db_object_owner2(v));
                    db_destroy_anonymous_object(v.v.anon);
                    myfree(v.v.anon, M_ANON);
                }
                else {
                    queue_anonymous_object(v);
                }
            }
            break;
    }
}
#endif

#ifdef ENABLE_GC
/* Corresponds to `Increment' in Bacon and Rajan. */
Var
complex_var_ref(Var v)
{
    switch (v.type) {
        case TYPE_STR:
            /* Mirrors complex_free_var()'s guard (via free_str()'s own
             * emptystring check): the singleton's refcount is pinned at
             * creation and must never be incremented either. */
            if (v.v.str != emptystring)
                addref(v.v.str);
            break;
        case TYPE_LIST:
            /* Mirrors complex_free_var()'s is_shared_empty() guard: the
             * singleton's refcount is pinned at creation and must never be
             * incremented either, or it would climb forever with nothing to
             * bring it back down. */
            if (!is_shared_empty(v))
                addref(v.v.list);
            break;
        case TYPE_MAP:
            if (!is_shared_empty(v))
                addref(v.v.tree);
            break;
        case TYPE_ITER:
            addref(v.v.trav);
            break;
        case TYPE_WAIF:
            addref(v.v.waif);
            break;
        case TYPE_ANON:
            if (v.v.anon) {
                addref(v.v.anon);
                if (gc_get_color(v.v.anon) != GC_BLACK)
                    gc_set_color(v.v.anon, GC_BLACK);
            }
            break;
    }
    return v;
}
#else
Var
complex_var_ref(Var v)
{
    switch (v.type) {
        case TYPE_STR:
            /* Mirrors complex_free_var()'s guard (via free_str()'s own
             * emptystring check): the singleton's refcount is pinned at
             * creation and must never be incremented either. */
            if (v.v.str != emptystring)
                addref(v.v.str);
            break;
        case TYPE_LIST:
            if (!is_shared_empty(v))
                addref(v.v.list);
            break;
        case TYPE_MAP:
            if (!is_shared_empty(v))
                addref(v.v.tree);
            break;
        case TYPE_ITER:
            addref(v.v.trav);
            break;
        case TYPE_WAIF:
            addref(v.v.waif);
            break;
        case TYPE_ANON:
            if (v.v.anon)
                addref(v.v.anon);
            break;
    }
    return v;
}
#endif

Var
complex_var_dup(Var v)
{
    switch (v.type) {
        case TYPE_STR:
            v.v.str = str_dup(v.v.str);
            break;
        case TYPE_LIST:
            v = list_dup(v);
            break;
        case TYPE_MAP:
            v = map_dup(v);
            break;
        case TYPE_ITER:
            v = iter_dup(v);
            break;
        case TYPE_WAIF:
            v.v.waif = dup_waif(v.v.waif);
            break;
        case TYPE_ANON:
            panic_moo("cannot var_dup() anonymous objects\n");
            break;
    }
    return v;
}

/* could be inlined and use complex_etc like the others, but this should
 * usually be called in a context where we already know the type.
 */
int
var_refcount(Var v)
{
    switch (v.type) {
        case TYPE_STR:
            return refcount(v.v.str);
            break;
        case TYPE_LIST:
            return refcount(v.v.list);
            break;
        case TYPE_MAP:
            return refcount(v.v.tree);
            break;
        case TYPE_ITER:
            return refcount(v.v.trav);
            break;
        case TYPE_ANON:
            if (v.v.anon)
                return refcount(v.v.anon);
            break;
        case TYPE_WAIF:
            return refcount(v.v.waif);
            break;
    }
    return 1;
}

int
is_true(Var v)
{
    switch (v.type)
    {
        case TYPE_INT:
            return v.v.num != 0;
        case TYPE_FLOAT:
            return v.v.fnum != 0.0;
        case TYPE_STR:
            return v.v.str && *v.v.str != '\0';
        case TYPE_LIST:
            return v.v.list[0].v.num != 0;
        case TYPE_MAP:
            return !mapempty(v);
        case TYPE_BOOL:
            return v.v.truth == true;
        default:
            return 0;
    }
}

/* What is the sound of the comparison:
 *   [1 -> 2] < [2 -> 1]
 * I don't know either; therefore, I do not compare maps
 * (nor other collection types, for the time being).
 */
int
compare(Var lhs, Var rhs, int case_matters)
{
    if (lhs.type == rhs.type) {
        switch (lhs.type) {
            case TYPE_INT:
                return lhs.v.num - rhs.v.num;
            case TYPE_OBJ:
                return lhs.v.obj - rhs.v.obj;
            case TYPE_ERR:
                return lhs.v.err - rhs.v.err;
            case TYPE_STR:
                if (lhs.v.str == rhs.v.str)
                    return 0;
                else if (case_matters)
                    return strcmp(lhs.v.str, rhs.v.str);
                else
                    return unicode_strcasecmp(lhs.v.str, rhs.v.str);
            case TYPE_FLOAT:
                if (lhs.v.fnum == rhs.v.fnum)
                    return 0;
                else
                    return (lhs.v.fnum - rhs.v.fnum) < 0.0 ? -1 : 1;
            case TYPE_WAIF:
                return lhs.v.waif == rhs.v.waif ? 0 : 1;
            case TYPE_ANON:
                return lhs.v.anon == rhs.v.anon ? 0 : 1;
            case TYPE_BOOL:
                return lhs.v.truth == rhs.v.truth ? 0 : 1;
            default:
                panic_moo("COMPARE: Invalid value type");
        }
    }
    return lhs.type - rhs.type;
}

int
equality(Var lhs, Var rhs, int case_matters)
{
    if (lhs.type == rhs.type) {
        switch (lhs.type) {
            case TYPE_CLEAR:
                return 1;
            case TYPE_NONE:
                return 1;
            case TYPE_INT:
                return lhs.v.num == rhs.v.num;
            case TYPE_OBJ:
                return lhs.v.obj == rhs.v.obj;
            case TYPE_ERR:
                return lhs.v.err == rhs.v.err;
            case TYPE_STR:
                if (lhs.v.str == rhs.v.str)
                    return 1;
                else if (case_matters) {
                    /* This byte-length fast-reject is only valid for exact
                     * comparison -- Unicode case-folding (below) doesn't
                     * preserve byte length (e.g. the Kelvin sign, 3 bytes,
                     * folds to ASCII 'k', 1 byte), so it must not gate the
                     * case-insensitive path. */
#ifdef MEMO_SIZE
                    if (memo_strlen(lhs.v.str) != memo_strlen(rhs.v.str))
                        return 0;
#endif /* memo_strlen */
                    return !strcmp(lhs.v.str, rhs.v.str);
                } else
                    return !unicode_strcasecmp(lhs.v.str, rhs.v.str);
            case TYPE_FLOAT:
                return lhs.v.fnum == rhs.v.fnum;
            case TYPE_LIST:
                return listequal(lhs, rhs, case_matters);
            case TYPE_MAP:
                return mapequal(lhs, rhs, case_matters);
            case TYPE_ANON:
                return lhs.v.anon == rhs.v.anon;
            case TYPE_WAIF:
                return lhs.v.waif == rhs.v.waif;
            case TYPE_BOOL:
                return lhs.v.truth == rhs.v.truth;
            default:
                panic_moo("EQUALITY: Unknown value type");
        }
    } else {
        if (lhs.type == TYPE_BOOL && rhs.type == TYPE_INT) {
            return rhs.v.num == lhs.v.truth;
        }
        else         if (rhs.type == TYPE_BOOL && lhs.type == TYPE_INT) {
            return lhs.v.num == rhs.v.truth;
        }
    }
    return 0;
}

/* Attempts to match `what' (case-sensitive byte comparison, or per-
 * character Unicode case fold via fold_peek()) starting at s, restricted
 * to the first `avail' bytes of `s' -- `s' may point into the middle of a
 * larger NUL-terminated allocation, so `avail' keeps a windowed/truncated
 * search from matching into bytes outside the intended window. Returns
 * the number of bytes of `s' the match consumed, or 0 if `what' doesn't
 * match here (`what' is never empty at any call site, so 0 is never
 * confusable with a genuine zero-length match). Under case-insensitive
 * Unicode folding the consumed byte count can differ from strlen(what) --
 * e.g. the Kelvin sign (3 bytes) folds equal to ASCII 'k' (1 byte) -- so
 * callers must use the returned count, not strlen(what), to advance past
 * a match. */
static size_t
match_at(const char *s, size_t avail, const char *what, int what_len, int case_counts)
{
    if (case_counts)
        return ((size_t) what_len <= avail && memcmp(s, what, (size_t) what_len) == 0)
               ? (size_t) what_len : 0;

    size_t consumed = 0;
    const char *w = what;
    while (*w) {
        if (consumed >= avail)
            return 0;
        size_t ls, lw;
        uint32_t fs, fw;
        fold_peek(s + consumed, &ls, &fs, avail - consumed);
        fold_peek(w, &lw, &fw);
        if (fs != fw)
            return 0;
        consumed += ls;
        w += lw;
    }
    return consumed;
}

void
stream_add_strsub(Stream *str, const char *source, const char *what, const char *with, int case_counts)
{
    int lwhat = strlen(what);
    size_t remaining = strlen(source);

    while (remaining > 0) {
        size_t matched = match_at(source, remaining, what, lwhat, case_counts);
        if (matched) {
            stream_add_string(str, with);
            source += matched;
            remaining -= matched;
        } else {
            stream_add_char(str, *source++);
            remaining--;
        }
    }
}

struct strtr_span { size_t start, len; uint32_t cp; };

static std::vector<strtr_span>
strtr_split_chars(const char *s, size_t len)
{
    std::vector<strtr_span> chars;
    size_t i = 0;
    while (i < len) {
        uint32_t cp;
        size_t clen = utf8_decode_char(s + i, len - i, &cp);
        chars.push_back({i, clen, cp});
        i += clen;
    }
    return chars;
}

const char *
strtr(const char *source, int source_len,
      const char *from, int from_len,
      const char *to, int to_len,
      int case_counts)
{
    static Stream *str = nullptr;

    if (!str)
        str = new_stream(100);

    /* Whole-character (not byte) from/to mapping: each character in
     * `from' maps to the same-position character in `to' (or deletion,
     * if `from' has more characters than `to'). Case-insensitive
     * matching (and case-preserving output) only applies to single-byte
     * ASCII letters, mirroring this builtin's historical behavior --
     * full Unicode case folding is out of scope. */
    std::vector<strtr_span> from_chars = strtr_split_chars(from, (size_t) from_len);
    std::vector<strtr_span> to_chars = strtr_split_chars(to, (size_t) to_len);

    /* Two lookup tables built once, rather than rescanning all of
     * `from_chars' for every source character (O(source_len * from_len)).
     * `exact' maps a codepoint to the last (highest-index) `from' entry
     * with that exact codepoint. `ascii_fold' maps a folded ASCII letter
     * to the last single-byte-alpha `from' entry naming it (either
     * case), used only when `!case_counts' -- an alpha byte can only
     * ever collide with another alpha `from' entry, so for an alpha
     * source character `ascii_fold' alone covers everything `exact'
     * would have matched too. Forward iteration makes the
     * last-populated (overwritten) entry the highest-index match,
     * matching the historical byte-table implementation's
     * overwrite-in-declaration-order behavior. */
    std::unordered_map<uint32_t, size_t> exact;
    std::unordered_map<int, size_t> ascii_fold;
    for (size_t f = 0; f < from_chars.size(); f++) {
        const strtr_span &fs = from_chars[f];
        exact[fs.cp] = f;
        if (!case_counts && fs.len == 1 && isalpha((unsigned char) from[fs.start]))
            ascii_fold[tolower((unsigned char) from[fs.start])] = f;
    }

    size_t si = 0;
    while (si < (size_t) source_len) {
        uint32_t scp;
        size_t sclen = utf8_decode_char(source + si, (size_t) source_len - si, &scp);
        int match = -1;

        if (!case_counts && sclen == 1 && isalpha((unsigned char) source[si])) {
            auto it = ascii_fold.find(tolower((unsigned char) source[si]));
            if (it != ascii_fold.end())
                match = (int) it->second;
        } else {
            auto it = exact.find(scp);
            if (it != exact.end())
                match = (int) it->second;
        }

        if (match >= 0) {
            if ((size_t) match < to_chars.size()) {
                const strtr_span &fs = from_chars[match];
                const strtr_span &ts = to_chars[match];
                if (!case_counts && fs.len == 1 && sclen == 1 && ts.len == 1
                        && isalpha((unsigned char) from[fs.start])) {
                    bool upper = isupper((unsigned char) source[si]);
                    unsigned char c = (unsigned char) to[ts.start];
                    stream_add_char(str, (char) (upper ? toupper(c) : tolower(c)));
                } else {
                    for (size_t k = 0; k < ts.len; k++)
                        stream_add_char(str, to[ts.start + k]);
                }
            }
            /* else: this `from' character has no `to' counterpart -- delete it. */
        } else {
            for (size_t k = 0; k < sclen; k++)
                stream_add_char(str, source[si + k]);
        }

        si += sclen;
    }

    return reset_stream(str);
}

int
strindex(const char *source, int source_len,
         const char *what, int what_len, int case_counts, size_t *out_matched_len)
{
    if (what_len == 0) {
        if (out_matched_len)
            *out_matched_len = 0;
        return 1;
    }

    for (const char *s = source; s <= source + source_len; s++) {
        size_t matched = match_at(s, (size_t) (source + source_len - s), what, what_len, case_counts);
        if (matched) {
            if (out_matched_len)
                *out_matched_len = matched;
            return (int) (s - source) + 1;
        }
    }
    return 0;
}

int
strrindex(const char *source, int source_len,
          const char *what, int what_len, int case_counts)
{
    if (what_len == 0)
        return source_len + 1;

    for (const char *s = source + source_len; s >= source; s--) {
        if (match_at(s, (size_t) (source + source_len - s), what, what_len, case_counts))
            return (int) (s - source) + 1;
    }
    return 0;
}

Var
get_system_property(const char *name)
{
    Var value;
    db_prop_handle h;

    if (!valid(SYSTEM_OBJECT)) {
        value.type = TYPE_ERR;
        value.v.err = E_INVIND;
        return value;
    }
    h = db_find_property(Var::new_obj(SYSTEM_OBJECT), name, &value);
    if (!h.ptr) {
        value.type = TYPE_ERR;
        value.v.err = E_PROPNF;
    } else if (!db_is_property_built_in(h)) /* make two cases the same */
        value = var_ref(value);
    return value;
}

Objid
get_system_object(const char *name)
{
    Var value;

    value = get_system_property(name);
    if (value.type != TYPE_OBJ) {
        free_var(value);
        return NOTHING;
    } else
        return value.v.obj;
}

int
value_bytes(Var v)
{
    int size = sizeof(Var);

    switch (v.type) {
        case TYPE_STR:
            size += memo_strlen(v.v.str) + 1;
            break;
        case TYPE_FLOAT:
            size += sizeof(double);
            break;
        case TYPE_LIST:
            size += list_sizeof(v.v.list);
            break;
        case TYPE_MAP:
            size += map_sizeof(v.v.tree);
            break;
        case TYPE_WAIF:
            size += waif_bytes(v.v.waif);
            break;
        default:
            break;
    }

    return size;
}

void
stream_add_raw_bytes_to_clean(Stream *s, const char *buffer, int buflen)
{
    int i;

    for (i = 0; i < buflen; i++) {
        unsigned char c = buffer[i];

        if (isgraph(c) || c == ' ')
            stream_add_char(s, c);
        /* else
            drop it */
    }
}

const char *
raw_bytes_to_clean(const char *buffer, int buflen)
{
    static Stream *s = nullptr;

    if (!s)
        s = new_stream(buflen + 1);

    stream_add_raw_bytes_to_clean(s, buffer, buflen);

    return reset_stream(s);
}

const char *
clean_to_raw_bytes(const char *buffer, int *buflen)
{
    *buflen = strlen(buffer);
    return buffer;
}

void
stream_add_raw_bytes_to_binary(Stream *s, const char *buffer, int buflen)
{
    int i;

    for (i = 0; i < buflen; i++) {
        unsigned char c = buffer[i];

        if (c != '~' && (isgraph(c) || c == ' '))
            stream_add_char(s, c);
        else
            stream_printf(s, "~%02X", (int) c);
    }
}

const char *
raw_bytes_to_binary(const char *buffer, int buflen)
{
    static Stream *s = nullptr;

    if (!s)
        s = new_stream(100);

    stream_add_raw_bytes_to_binary(s, buffer, buflen);

    return reset_stream(s);
}

const char *
binary_to_raw_bytes(const char *binary, int *buflen)
{
    static Stream *s = nullptr;
    const char *ptr = binary;

    if (!s)
        s = new_stream(100);
    else
        reset_stream(s);

    while (*ptr) {
        unsigned char c = *ptr++;

        if (c != '~')
            stream_add_char(s, c);
        else {
            int i;
            char cc = 0;

            for (i = 1; i <= 2; i++) {
                c = toupper(*ptr++);
                if (('0' <= c && c <= '9') || ('A' <= c && c <= 'F'))
                    cc = cc * 16 + (c <= '9' ? c - '0' : c - 'A' + 10);
                else
                    return nullptr;
            }

            stream_add_char(s, cc);
        }
    }

    *buflen = stream_length(s);
    return reset_stream(s);
}

Var
anonymizing_var_ref(Var v, Objid progr)
{
    Var r;

    if (TYPE_ANON != v.type)
        return var_ref(v);

    if (valid(progr)
            && (is_wizard(progr) || db_object_owner2(v) == progr))
        return var_ref(v);

    r.type = TYPE_ANON;
    r.v.anon = nullptr;

    return r;
}
