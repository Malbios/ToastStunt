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
#include <stdlib.h>
#include <algorithm> // std::sort
#include "dependencies/strnatcmp.c" // natural sorting
#include <mutex>
#include <vector>

#include <ctype.h>
#include <string.h>
#include "my-math.h"

#include "bf_register.h"
#include "collection.h"
#include "config.h"
#include "functions.h"
#include "list.h"
#include "log.h"
#include "map.h"
#include "options.h"
#include "pattern.h"
#include "streams.h"
#include "storage.h"
#include "structures.h"
#include "unicode_tables.h"
#include "unparse.h"
#include "utils.h"
#include "server.h"
#include "background.h"   // Threads
#include "random.h"

/* Bandaid: Something is killing all of our references to the
 * empty list, which is causing the server to crash. So this is
 * now a global and utils.cc won't free the list if it's emptylist.
 * Its refcount is pinned at the value mymalloc() gives it at creation
 * and is never incremented or decremented again -- new_list() and
 * complex_var_ref() (utils.cc) both skip the addref that would
 * otherwise apply, mirroring complex_free_var()'s skipped decref.
 * Without that symmetry the count would climb forever (nothing ever
 * brings it back down) and eventually overflow and wrap back through
 * zero, reproducing the exact premature-free crash this bandaid
 * exists to prevent. */
Var emptylist;

Var
new_list(int size)
{
    Var list;
    Var *ptr;

    if (size == 0) {
        static std::once_flag emptylist_init;

        std::call_once(emptylist_init, []() {
            Var *ptr = (Var *)mymalloc(1 * sizeof(Var), M_LIST);
            if (ptr == nullptr)
                panic_moo("EMPTY_LIST: mymalloc failed");

            emptylist.type = TYPE_LIST;
            emptylist.v.list = ptr;
            emptylist.v.list[0].type = TYPE_INT;
            emptylist.v.list[0].v.num = 0;
        });

#ifdef ENABLE_GC
        assert(gc_get_color(emptylist.v.list) == GC_GREEN);
#endif

        return emptylist;
    }

    if ((ptr = (Var *)mymalloc((size + 1) * sizeof(Var), M_LIST)) == nullptr)
        panic_moo("EMPTY_LIST: mymalloc failed");

    list.type = TYPE_LIST;
    list.v.list = ptr;
    list.v.list[0].type = TYPE_INT;
    list.v.list[0].v.num = size;

#ifdef ENABLE_GC
    gc_set_color(list.v.list, GC_YELLOW);
#endif

    return list;
}

/* called from utils.c */
void
destroy_list(Var list)
{
    int i;
    Var *pv;

    for (i = list.v.list[0].v.num, pv = list.v.list + 1; i > 0; i--, pv++)
        free_var(*pv);

    /* Since this list could possibly be the root of a cycle, final
     * destruction is handled in the garbage collector if garbage
     * collection is enabled.
     */
#ifndef ENABLE_GC
    myfree(list.v.list, M_LIST);
#endif
}

/* called from utils.c */
Var
list_dup(Var list)
{
    int i, n = list.v.list[0].v.num;
    Var _new = new_list(n);

    for (i = 1; i <= n; i++)
        _new.v.list[i] = var_ref(list.v.list[i]);

#ifdef ENABLE_GC
    gc_set_color(_new.v.list, gc_get_color(list.v.list));
#endif

    return _new;
}

int
listforeach(Var list, listfunc func, void *data)
{   /* does NOT consume `list' */
    int i, n;
    int first = 1;
    int ret;

    for (i = 1, n = list.v.list[0].v.num; i <= n; i++) {
        if ((ret = (*func)(list.v.list[i], data, first)))
            return ret;
        first = 0;
    }

    return 0;
}

Var
setadd(Var list, Var value)
{
    if (ismember(value, list, 0)) {
        free_var(value);
        return list;
    }
    return listappend(list, value);
}

Var
setremove(Var list, Var value)
{
    int i;

    if ((i = ismember(value, list, 0)) != 0) {
        return listdelete(list, i);
    } else {
        return list;
    }
}

Var
listset(Var list, Var value, int pos)
{   /* consumes `list', `value' */
    Var _new = list;

    if (is_shared_empty(list) || var_refcount(list) > 1) {
        _new = var_dup(list);
        free_var(list);
    }

#ifdef MEMO_SIZE
    /* reset the memoized size */
    var_metadata *metadata = ((var_metadata*)_new.v.list) - 1;
    metadata->size = 0;
#endif

    free_var(_new.v.list[pos]);
    _new.v.list[pos] = value;

#ifdef ENABLE_GC
    gc_set_color(_new.v.list, GC_YELLOW);
#endif

    return _new;
}

static Var
doinsert(Var list, Var value, int pos)
{
    Var _new;
    int i;
    int size = list.v.list[0].v.num + 1;

    /* Bandaid: See the top of list.cc for an explanation */
    if (!is_shared_empty(list) && var_refcount(list) == 1 && pos == size) {
        list.v.list = (Var *) myrealloc(list.v.list, (size + 1) * sizeof(Var), M_LIST);
#ifdef MEMO_SIZE
        /* reset the memoized size */
        var_metadata *metadata = ((var_metadata*)list.v.list) - 1;
        metadata->size = 0;
#endif
        list.v.list[0].v.num = size;
        list.v.list[pos] = value;

#ifdef ENABLE_GC
        gc_set_color(list.v.list, GC_YELLOW);
#endif

        return list;
    }
    _new = new_list(size);
    for (i = 1; i < pos; i++)
        _new.v.list[i] = var_ref(list.v.list[i]);
    _new.v.list[pos] = value;
    for (i = pos; i <= list.v.list[0].v.num; i++)
        _new.v.list[i + 1] = var_ref(list.v.list[i]);

    free_var(list);

#ifdef ENABLE_GC
    gc_set_color(_new.v.list, GC_YELLOW);
#endif

    return _new;
}

Var
listinsert(Var list, Var value, int pos)
{
    if (pos <= 0)
        pos = 1;
    else if (pos > list.v.list[0].v.num)
        pos = list.v.list[0].v.num + 1;
    return doinsert(list, value, pos);
}

Var
listappend(Var list, Var value)
{
    return doinsert(list, value, list.v.list[0].v.num + 1);
}

Var
listdelete(Var list, int pos)
{
    Var _new;
    int i;
    int size = list.v.list[0].v.num - 1;

    _new = new_list(size);
    for (i = 1; i < pos; i++) {
        _new.v.list[i] = var_ref(list.v.list[i]);
    }
    for (i = pos + 1; i <= list.v.list[0].v.num; i++)
        _new.v.list[i - 1] = var_ref(list.v.list[i]);

    free_var(list);

#ifdef ENABLE_GC
    if (size > 0)       /* only non-empty lists */
        gc_set_color(_new.v.list, GC_YELLOW);
#endif

    return _new;
}

Var
listconcat(Var first, Var second)
{
    int lsecond = second.v.list[0].v.num;
    int lfirst = first.v.list[0].v.num;
    Var _new;
    int i;

    _new = new_list(lsecond + lfirst);
    for (i = 1; i <= lfirst; i++)
        _new.v.list[i] = var_ref(first.v.list[i]);
    for (i = 1; i <= lsecond; i++)
        _new.v.list[i + lfirst] = var_ref(second.v.list[i]);

    free_var(first);
    free_var(second);

#ifdef ENABLE_GC
    if (lsecond + lfirst > 0)   /* only non-empty lists */
        gc_set_color(_new.v.list, GC_YELLOW);
#endif

    return _new;
}

Var
listrangeset(Var base, int from, int to, Var value)
{
    /* base and value are free'd */
    int index, offset = 0;
    int val_len = value.v.list[0].v.num;
    int base_len = base.v.list[0].v.num;
    int lenleft = (from > 1) ? from - 1 : 0;
    int lenmiddle = val_len;
    int lenright = (base_len > to) ? base_len - to : 0;
    int newsize = lenleft + lenmiddle + lenright;
    Var ans;

    ans = new_list(newsize);
    for (index = 1; index <= lenleft; index++)
        ans.v.list[++offset] = var_ref(base.v.list[index]);
    for (index = 1; index <= lenmiddle; index++)
        ans.v.list[++offset] = var_ref(value.v.list[index]);
    for (index = 1; index <= lenright; index++)
        ans.v.list[++offset] = var_ref(base.v.list[to + index]);

    free_var(base);
    free_var(value);

#ifdef ENABLE_GC
    if (newsize > 0)    /* only non-empty lists */
        gc_set_color(ans.v.list, GC_YELLOW);
#endif

    return ans;
}

Var
sublist(Var list, int lower, int upper)
{
    if (lower > upper) {
        Var empty = new_list(0);
        free_var(list);
        return empty;
    } else {
        Var r;
        int i;

        r = new_list(upper - lower + 1);
        for (i = lower; i <= upper; i++)
            r.v.list[i - lower + 1] = var_ref(list.v.list[i]);

        free_var(list);

#ifdef ENABLE_GC
        gc_set_color(r.v.list, GC_YELLOW);
#endif

        return r;
    }
}

int
listequal(Var lhs, Var rhs, int case_matters)
{
    if (lhs.v.list == rhs.v.list)
        return 1;

    if (lhs.v.list[0].v.num != rhs.v.list[0].v.num)
        return 0;

    int i, c = lhs.v.list[0].v.num;
    for (i = 1; i <= c; i++) {
        if (!equality(lhs.v.list[i], rhs.v.list[i], case_matters))
            return 0;
    }

    return 1;
}

static void
stream_add_tostr(Stream * s, Var v)
{
    switch (v.type) {
        case TYPE_INT:
            stream_printf(s, "%" PRIdN, v.v.num);
            break;
        case TYPE_OBJ:
            stream_printf(s, "#%" PRIdN, v.v.obj);
            break;
        case TYPE_STR:
            stream_add_string(s, v.v.str);
            break;
        case TYPE_ERR:
            stream_add_string(s, unparse_error(v.v.err));
            break;
        case TYPE_FLOAT:
            unparse_value(s, v);
            break;
        case TYPE_MAP:
            stream_add_string(s, "[map]");
            break;
        case TYPE_LIST:
            stream_add_string(s, "{list}");
            break;
        case TYPE_ANON:
            stream_add_string(s, "*anonymous*");
            break;
        case TYPE_WAIF:
            stream_add_string(s, "[[waif]]");
            break;
        case TYPE_BOOL:
            stream_add_string(s, v.v.truth ? "true" : "false");
            break;
        default:
            panic_moo("STREAM_ADD_TOSTR: Unknown Var type");
    }
}

const char *
value2str(Var value)
{
    if (value.type == TYPE_STR) {
        /* do this case separately to avoid two copies
         * and to ensure that the stream never grows */
        return str_ref(value.v.str);
    }
    else {
        static Stream *s = nullptr;
        if (!s)
            s = new_stream(32);
        stream_add_tostr(s, value);
        return str_dup(reset_stream(s));
    }
}

static int
print_map_to_stream(Var key, Var value, void *sptr, int first)
{
    Stream *s = (Stream *)sptr;

    if (!first) {
        stream_add_string(s, ", ");
    }

    unparse_value(s, key);
    stream_add_string(s, " -> ");
    unparse_value(s, value);

    return 0;
}

void
unparse_value(Stream * s, Var v)
{
    switch (v.type) {
        case TYPE_INT:
            stream_printf(s, "%" PRIdN, v.v.num);
            break;
        case TYPE_OBJ:
            stream_printf(s, "#%" PRIdN, v.v.obj);
            break;
        case TYPE_ERR:
            stream_add_string(s, error_name(v.v.err));
            break;
        case TYPE_FLOAT:
            char buffer[41];
            snprintf(buffer, 40, "%.*g", DBL_DIG, v.v.fnum);
            if (!strchr(buffer, '.') && !strchr(buffer, 'e'))
                strncat(buffer, ".0", 40);
            stream_add_string(s, buffer);
            break;
        case TYPE_STR:
        {
            const char *str = v.v.str;

            stream_add_char(s, '"');
            while (*str) {
                switch (*str) {
                    case '"':
                    case '\\':
                        stream_add_char(s, '\\');
                    /* fall thru */
                    default:
                        stream_add_char(s, *str++);
                }
            }
            stream_add_char(s, '"');
        }
        break;
        case TYPE_LIST:
        {
            const char *sep = "";
            int len, i;

            stream_add_char(s, '{');
            len = v.v.list[0].v.num;
            for (i = 1; i <= len; i++) {
                stream_add_string(s, sep);
                sep = ", ";
                unparse_value(s, v.v.list[i]);
            }
            stream_add_char(s, '}');
        }
        break;
        case TYPE_MAP:
        {
            stream_add_char(s, '[');
            mapforeach(v, print_map_to_stream, (void *)s);
            stream_add_char(s, ']');
        }
        break;
        case TYPE_ANON:
            stream_add_string(s, "*anonymous*");
            break;
        case TYPE_WAIF:
            stream_printf(s, "[[class = #%" PRIdN ", owner = #%" PRIdN "]]", v.v.waif->_class, v.v.waif->owner);
            break;
        case TYPE_BOOL:
            stream_printf(s, v.v.truth ? "true" : "false");
            break;
        default:
            errlog("UNPARSE_VALUE: Unknown Var type = %d\n", v.type);
            stream_add_string(s, ">>Unknown value<<");
    }
}

/* called from utils.c */
int
list_sizeof(Var *list)
{
#ifdef MEMO_SIZE
    var_metadata *metadata = ((var_metadata*)list) - 1;
#endif
    int i, len, size;

#ifdef MEMO_SIZE
    if ((size = metadata->size))
        return size;
#endif

    size = sizeof(Var); /* for the `length' element */
    len = list[0].v.num;
    for (i = 1; i <= len; i++) {
        size += value_bytes(list[i]);
    }

#ifdef MEMO_SIZE
    metadata->size = size;
#endif

    return size;
}

Var
strrangeset(Var base, int from, int to, Var value)
{
    /* base and value are free'd. `from'/`to' are codepoint indices into
     * base; the left/right segments they bound are resolved to byte
     * offsets, but (like substr()) the copies themselves stay
     * byte-oriented -- only the two boundaries need codepoint awareness.
     */
    size_t base_byte_len = memo_strlen(base.v.str);
    size_t base_cp_len = memo_cplen(base.v.str);
    bool base_ascii = base_cp_len == base_byte_len;
    size_t left_end = (from > 1) ? utf8_offset_of_char(base.v.str, base_byte_len, (size_t) from, base_ascii, base.v.str) : 0;
    size_t right_start = ((size_t) to < base_cp_len)
                          ? utf8_offset_of_char(base.v.str, base_byte_len, (size_t) to + 1, base_ascii, base.v.str)
                          : base_byte_len;
    size_t val_len = memo_strlen(value.v.str);
    size_t lenright = base_byte_len - right_start;
    size_t newsize = left_end + val_len + lenright;

    Var ans;
    char *s;
    size_t offset = 0;

    ans.type = TYPE_STR;
    s = (char *) mymalloc(newsize + 1, M_STRING);

    memcpy(s + offset, base.v.str, left_end);
    offset += left_end;
    memcpy(s + offset, value.v.str, val_len);
    offset += val_len;
    memcpy(s + offset, base.v.str + right_start, lenright);
    offset += lenright;
    s[offset] = '\0';

    ans.v.str = s;
    free_var(base);
    free_var(value);
    return ans;
}

Var
substr(Var str, int lower, int upper)
{
    Var r;

    r.type = TYPE_STR;
    if (lower > upper)
        r.v.str = str_dup("");
    else {
        /* Codepoint-awareness is only needed to resolve the two
         * boundaries; the copy itself stays a plain byte range. */
        size_t byte_len = memo_strlen(str.v.str);
        bool ascii = memo_cplen(str.v.str) == byte_len;
        size_t start = utf8_offset_of_char(str.v.str, byte_len, (size_t) lower, ascii, str.v.str);
        size_t end = utf8_offset_of_char(str.v.str, byte_len, (size_t) upper + 1, ascii, str.v.str);
        char *s = (char *) mymalloc(end - start + 1, M_STRING);

        memcpy(s, str.v.str + start, end - start);
        s[end - start] = '\0';
        r.v.str = s;
    }
    free_var(str);
    return r;
}

Var
strget(Var str, int i)
{
    Var r;
    size_t byte_len = memo_strlen(str.v.str);
    bool ascii = memo_cplen(str.v.str) == byte_len;
    size_t start = utf8_offset_of_char(str.v.str, byte_len, (size_t) i, ascii, str.v.str);
    size_t clen = utf8_char_byte_length(str.v.str + start, byte_len - start);
    char *s = (char *) mymalloc(clen + 1, M_STRING);

    memcpy(s, str.v.str + start, clen);
    s[clen] = '\0';

    r.type = TYPE_STR;
    r.v.str = s;
    return r;
}

/**** helpers for catching overly large allocations ****/

#define TRY_STREAM enable_stream_exceptions()
#define ENDTRY_STREAM disable_stream_exceptions()

static package
make_space_pack()
{
    if (server_flag_option_cached(SVO_MAX_CONCAT_CATCHABLE))
        return make_error_pack(E_QUOTA);
    else
        return make_abort_pack(ABORT_SECONDS);
}

/**** built in functions ****/

static package
bf_length(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var r;
    switch (arglist.v.list[1].type) {
        case TYPE_LIST:
            r.type = TYPE_INT;
            r.v.num = arglist.v.list[1].v.list[0].v.num;
            break;
        case TYPE_MAP:
            r.type = TYPE_INT;
            r.v.num = maplength(arglist.v.list[1]);
            break;
        case TYPE_STR:
            r.type = TYPE_INT;
            r.v.num = memo_cplen(arglist.v.list[1].v.str);
            break;
        default:
            free_var(arglist);
            return make_error_pack(E_TYPE);
            break;
    }

    free_var(arglist);
    return make_var_pack(r);
}

static package
bf_setadd(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var r;
    Var lst = var_ref(arglist.v.list[1]);
    Var elt = var_ref(arglist.v.list[2]);

    free_var(arglist);

    r = setadd(lst, elt);

    if (value_bytes(r) <= server_int_option_cached(SVO_MAX_LIST_VALUE_BYTES))
        return make_var_pack(r);
    else {
        free_var(r);
        return make_space_pack();
    }
}


static package
bf_setremove(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var r;

    r = setremove(var_ref(arglist.v.list[1]), arglist.v.list[2]);
    free_var(arglist);

    if (value_bytes(r) <= server_int_option_cached(SVO_MAX_LIST_VALUE_BYTES))
        return make_var_pack(r);
    else {
        free_var(r);
        return make_space_pack();
    }
}

/* Return a copy of the list with every occurrence of value removed. */
void listremove_all_thread_callback(Var arglist, Var *ret, void *extra_data)
{
    Var list = arglist.v.list[1];
    Var value = arglist.v.list[2];
    bool case_matters = arglist.v.list[0].v.num < 3 || is_true(arglist.v.list[3]);

    *ret = new_list(0);
    for (int i = 1, len = list.v.list[0].v.num; i <= len; i++)
        if (!equality(value, list.v.list[i], case_matters))
            *ret = listappend(*ret, var_ref(list.v.list[i]));
}

static package
bf_listremove_all(Var arglist, Byte next, void *vdata, Objid progr)
{
    return background_thread(listremove_all_thread_callback, &arglist);
}

/* Return a copy of the list with duplicate elements removed, keeping the
 * first occurrence of each. Faster in practice than the setadd()-in-a-loop
 * workaround it replaces: each setadd() call independently rescans the
 * result-so-far via ismember() and does its own MOO-level dispatch/quota
 * check, whereas this does a single pass reusing the in-progress result
 * buffer directly. Still O(n^2) worst case -- Var has no general hashing
 * mechanism (lists/maps are recursively comparable, not hashable), so a
 * sub-O(n^2) generic dedup isn't available without new infrastructure.
 */
void listunique_thread_callback(Var arglist, Var *ret, void *extra_data)
{
    Var list = arglist.v.list[1];
    bool case_matters = arglist.v.list[0].v.num < 2 || is_true(arglist.v.list[2]);

    *ret = new_list(0);
    for (int i = 1, len = list.v.list[0].v.num; i <= len; i++) {
        bool dup = false;
        for (int j = 1, rlen = ret->v.list[0].v.num; j <= rlen; j++) {
            if (equality(list.v.list[i], ret->v.list[j], case_matters)) {
                dup = true;
                break;
            }
        }
        if (!dup)
            *ret = listappend(*ret, var_ref(list.v.list[i]));
    }
}

static package
bf_listunique(Var arglist, Byte next, void *vdata, Objid progr)
{
    return background_thread(listunique_thread_callback, &arglist);
}


static package
insert_or_append(Var arglist, int append1)
{
    int pos;
    Var r;
    Var lst = var_ref(arglist.v.list[1]);
    Var elt = var_ref(arglist.v.list[2]);

    if (arglist.v.list[0].v.num == 2)
        pos = append1 ? lst.v.list[0].v.num + 1 : 1;
    else {
        pos = arglist.v.list[3].v.num + append1;
        if (pos <= 0)
            pos = 1;
        else if (pos > lst.v.list[0].v.num + 1)
            pos = lst.v.list[0].v.num + 1;
    }
    free_var(arglist);

    r = doinsert(lst, elt, pos);

    if (value_bytes(r) <= server_int_option_cached(SVO_MAX_LIST_VALUE_BYTES))
        return make_var_pack(r);
    else {
        free_var(r);
        return make_space_pack();
    }
}


static package
bf_listappend(Var arglist, Byte next, void *vdata, Objid progr)
{
    return insert_or_append(arglist, 1);
}


static package
bf_listinsert(Var arglist, Byte next, void *vdata, Objid progr)
{
    return insert_or_append(arglist, 0);
}


static package
bf_listdelete(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var r;
    if (arglist.v.list[2].v.num <= 0
            || arglist.v.list[2].v.num > arglist.v.list[1].v.list[0].v.num) {
        free_var(arglist);
        return make_error_pack(E_RANGE);
    }

    r = listdelete(var_ref(arglist.v.list[1]), arglist.v.list[2].v.num);

    free_var(arglist);

    if (value_bytes(r) <= server_int_option_cached(SVO_MAX_LIST_VALUE_BYTES))
        return make_var_pack(r);
    else {
        free_var(r);
        return make_space_pack();
    }
}


static package
bf_listset(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var r;

    Var lst = var_ref(arglist.v.list[1]);
    Var elt = var_ref(arglist.v.list[2]);
    int pos = arglist.v.list[3].v.num;

    free_var(arglist);

    if (pos <= 0 || pos > listlength(lst)) {
        free_var(lst);
        free_var(elt);
        return make_error_pack(E_RANGE);
    }

    r = listset(lst, elt, pos);

    if (value_bytes(r) <= server_int_option_cached(SVO_MAX_LIST_VALUE_BYTES))
        return make_var_pack(r);
    else {
        free_var(r);
        return make_space_pack();
    }
}

static package
bf_listget(Var arglist, Byte next, void *vdata, Objid progr)
{
    int nargs = arglist.v.list[0].v.num;
    Var list = arglist.v.list[1];
    Num index = arglist.v.list[2].v.num;
    Var ret;

    if (index >= 1 && index <= listlength(list))
        ret = var_ref(list.v.list[index]);
    else if (nargs >= 3)
        ret = var_ref(arglist.v.list[3]);
    else
        ret = Var::new_int(0);

    free_var(arglist);

    return make_var_pack(ret);
}

static package
bf_equal(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var r;

    r.type = TYPE_INT;
    r.v.num = equality(arglist.v.list[1], arglist.v.list[2], 1);
    free_var(arglist);
    return make_var_pack(r);
}

/* Return a list of substrings of an argument separated by a delimiter. */
static package
bf_explode(Var arglist, Byte next, void *vdata, Objid progr)
{
    const int nargs = arglist.v.list[0].v.num;
    const bool adjacent_delim = (nargs > 2 && is_true(arglist.v.list[3]));

    /* strsep()/strtok() are fundamentally single-byte-delimiter libc
     * calls, so the delimiter is scanned by hand here -- it's the first
     * whole CHARACTER of the delimiter argument (1-4 bytes), not just
     * its first byte. */
    char delim[4];
    size_t delim_len = 1;
    if (nargs > 1 && memo_strlen(arglist.v.list[2].v.str) > 0) {
        const char *delim_arg = arglist.v.list[2].v.str;
        delim_len = utf8_char_byte_length(delim_arg, memo_strlen(delim_arg));
        memcpy(delim, delim_arg, delim_len);
    } else {
        delim[0] = ' ';
    }

    const char *str = arglist.v.list[1].v.str;
    size_t str_len = memo_strlen(str);
    Var ret = new_list(0);

    auto append_span = [&](size_t start, size_t span_len) {
        char *s = (char *) mymalloc(span_len + 1, M_STRING);
        memcpy(s, str + start, span_len);
        s[span_len] = '\0';
        Var v;
        v.type = TYPE_STR;
        v.v.str = s;
        ret = listappend(ret, v);
    };

    size_t pos = 0;
    if (adjacent_delim) {
        /* strsep()-equivalent: every delimiter occurrence starts a new
         * token, including empty tokens between adjacent delimiters and
         * at the start/end of the string. */
        size_t token_start = 0;
        while (pos + delim_len <= str_len) {
            if (memcmp(str + pos, delim, delim_len) == 0) {
                append_span(token_start, pos - token_start);
                pos += delim_len;
                token_start = pos;
            } else {
                pos++;
            }
        }
        append_span(token_start, str_len - token_start);
    } else {
        /* strtok()-equivalent: runs of delimiters collapse to one
         * separator; leading/trailing delimiters produce no empty
         * tokens. */
        while (pos < str_len) {
            while (pos + delim_len <= str_len && memcmp(str + pos, delim, delim_len) == 0)
                pos += delim_len;
            if (pos >= str_len)
                break;
            size_t token_start = pos;
            while (pos < str_len && !(pos + delim_len <= str_len && memcmp(str + pos, delim, delim_len) == 0))
                pos++;
            append_span(token_start, pos - token_start);
        }
    }

    free_var(arglist);
    return make_var_pack(ret);
}

static package
bf_reverse(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var ret;

    if (arglist.v.list[1].type == TYPE_LIST) {
        int elements = arglist.v.list[1].v.list[0].v.num;
        ret = new_list(elements);

        for (size_t x = elements, y = 1; x >= 1; x--, y++) {
            ret.v.list[y] = var_ref(arglist.v.list[1].v.list[x]);
        }
    } else if (arglist.v.list[1].type == TYPE_STR) {
        const char *str = arglist.v.list[1].v.str;
        size_t byte_len = memo_strlen(str);
        if (memo_cplen(str) <= 1) {
            ret = var_ref(arglist.v.list[1]);
        } else {
            /* Reversing by byte would corrupt multi-byte characters.
             * Walk the string forward decoding one character span at a
             * time, and place each span at its mirrored position in the
             * output -- the character's own bytes stay in order, only
             * the sequence of characters reverses. */
            char *new_str = (char *)mymalloc(byte_len + 1, M_STRING);
            size_t offset = 0, out = byte_len;

            new_str[byte_len] = '\0';
            while (offset < byte_len) {
                size_t clen = utf8_char_byte_length(str + offset, byte_len - offset);
                out -= clen;
                memcpy(new_str + out, str + offset, clen);
                offset += clen;
            }
            ret.type = TYPE_STR;
            ret.v.str = new_str;
        }
    } else {
        ret.type = TYPE_ERR;
        ret.v.err = E_INVARG;
    }

    free_var(arglist);
    return ret.type == TYPE_ERR ? make_error_pack(ret.v.err) : make_var_pack(ret);
}

static package
bf_slice(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var ret;
    int nargs = arglist.v.list[0].v.num;
    Var alist = arglist.v.list[1];
    Var index = (nargs < 2 ? Var::new_int(1) : arglist.v.list[2]);
    Var default_map_value = (nargs >= 3 ? arglist.v.list[3] : nothing);

    // Validate the types here since we used TYPE_ANY to allow lists and ints
    if (nargs > 1 && index.type != TYPE_LIST && index.type != TYPE_INT && index.type != TYPE_STR) {
        free_var(arglist);
        return make_error_pack(E_INVARG);
    }

    // Check that that index isn't an empty list and doesn't contain negative or zeroes
    if (index.type == TYPE_LIST) {
        if (index.v.list[0].v.num == 0) {
            free_var(arglist);
            return make_error_pack(E_RANGE);
        }

        for (int x = 1; x <= index.v.list[0].v.num; x++) {
            if (index.v.list[x].type != TYPE_INT || index.v.list[x].v.num <= 0) {
                free_var(arglist);
                return make_error_pack((index.v.list[x].type != TYPE_INT ? E_INVARG : E_RANGE));
            }
        }
    } else if (index.v.num <= 0) {
        free_var(arglist);
        return make_error_pack(E_RANGE);
    }

    /* Ideally, we could allocate the list with the number of elements in our first list.
     * Unfortunately, if we need to return an error in the middle of setting elements in the return list,
     * we can't free_var the entire list because some elements haven't been set yet. So instead we do it the
     * old fashioned way unless/until somebody wants to refactor this to do all the error checking ahead of time. */
    ret = new_list(0);

    for (int x = 1; x <= alist.v.list[0].v.num; x++) {
        Var element = alist.v.list[x];
        if ((element.type != TYPE_LIST && element.type != TYPE_STR && element.type != TYPE_MAP)
                || ((element.type == TYPE_MAP && index.type != TYPE_STR) || (index.type == TYPE_STR && element.type != TYPE_MAP))) {
            free_var(arglist);
            free_var(ret);
            return make_error_pack(E_INVARG);
        }
        if (index.type == TYPE_STR) {
            if (element.type != TYPE_MAP) {
                free_var(arglist);
                free_var(ret);
                return make_error_pack(E_INVARG);
            } else {
                Var tmp;
                if (maplookup(element, index, &tmp, 0) != nullptr)
                    ret = listappend(ret, var_ref(tmp));
                else if (nargs >= 3)
                    ret = listappend(ret, var_ref(default_map_value));
            }
        } else if (index.type == TYPE_INT) {
            if (index.v.num > (element.type == TYPE_STR ? (int) memo_cplen(element.v.str) : element.v.list[0].v.num)) {
                free_var(arglist);
                free_var(ret);
                return make_error_pack(E_RANGE);
            } else {
                ret = listappend(ret, (element.type == TYPE_STR ? substr(var_ref(element), index.v.num, index.v.num) : var_ref(element.v.list[index.v.num])));
            }
        } else if (index.type == TYPE_LIST) {
            Var tmp = new_list(0);
            for (int y = 1; y <= index.v.list[0].v.num; y++) {
                if (index.v.list[y].v.num > (element.type == TYPE_STR ? (int) memo_cplen(element.v.str) : element.v.list[0].v.num)) {
                    free_var(arglist);
                    free_var(ret);
                    free_var(tmp);
                    return make_error_pack(E_RANGE);
                } else {
                    tmp = listappend(tmp, (element.type == TYPE_STR ? substr(var_ref(element), index.v.list[y].v.num, index.v.list[y].v.num) : var_ref(element.v.list[index.v.list[y].v.num])));
                }
            }
            ret = listappend(ret, tmp);
        }
    }
    free_var(arglist);
    return make_var_pack(ret);
}

/* Sorts various MOO types using std::sort.
 * Args: LIST <values to sort>, [LIST <values to sort by>], [INT <natural sort ordering?>], [INT <reverse?>] */
void sort_callback(Var arglist, Var *ret, void *extra_data)
{
    const int nargs = arglist.v.list[0].v.num;
    const int list_to_sort = (nargs >= 2 && arglist.v.list[2].v.list[0].v.num > 0 ? 2 : 1);
    const bool natural = (nargs >= 3 && is_true(arglist.v.list[3]));
    const bool reverse = (nargs >= 4 && is_true(arglist.v.list[4]));

    if (arglist.v.list[list_to_sort].v.list[0].v.num == 0) {
        *ret = new_list(0);
        return;
    } else if (list_to_sort == 2 && arglist.v.list[1].v.list[0].v.num != arglist.v.list[2].v.list[0].v.num) {
        ret->type = TYPE_ERR;
        ret->v.err = E_INVARG;
        return;
    }

    // Create and sort a vector of indices rather than values. This makes it easier to sort a list by another list.
    std::vector<size_t> s(arglist.v.list[list_to_sort].v.list[0].v.num);
    const var_type type_to_sort = arglist.v.list[list_to_sort].v.list[1].type;

    const Num list_length = arglist.v.list[list_to_sort].v.list[0].v.num;
    for (int count = 1; count <= list_length; count++)
    {
        var_type type = arglist.v.list[list_to_sort].v.list[count].type;
        if (type != type_to_sort || type == TYPE_LIST || type == TYPE_MAP || type == TYPE_ANON || type == TYPE_WAIF)
        {
            ret->type = TYPE_ERR;
            ret->v.err = E_TYPE;
            return;
        }
        s[count - 1] = count;
    }

    struct VarCompare {
        VarCompare(const Var *Arglist, const bool Natural) : m_Arglist(Arglist), m_Natural(Natural) {}

        bool operator()(const size_t a, const size_t b) const
        {
            const Var lhs = m_Arglist[a];
            const Var rhs = m_Arglist[b];

            switch (rhs.type) {
                case TYPE_INT:
                    return lhs.v.num < rhs.v.num;
                case TYPE_FLOAT:
                    return lhs.v.fnum < rhs.v.fnum;
                case TYPE_OBJ:
                    return lhs.v.obj < rhs.v.obj;
                case TYPE_ERR:
                    return ((int) lhs.v.err) < ((int) rhs.v.err);
                case TYPE_STR:
                    return (m_Natural ? strnatcasecmp(lhs.v.str, rhs.v.str) : strcasecmp(lhs.v.str, rhs.v.str)) < 0;
                default:
                    errlog("Unknown type in sort compare: %d\n", rhs.type);
                    return 0;
            }
        }
        const Var *m_Arglist;
        const bool m_Natural;
    };

    std::sort(s.begin(), s.end(), VarCompare(arglist.v.list[list_to_sort].v.list, natural));

    *ret = new_list(s.size());

    if (reverse)
        std::reverse(std::begin(s), std::end(s));

    int moo_list_pos = 0;
    for (const auto &it : s) {
        ret->v.list[++moo_list_pos] = var_ref(arglist.v.list[1].v.list[it]);

    }
}

static package
bf_sort(Var arglist, Byte next, void *vdata, Objid progr)
{
    return background_thread(sort_callback, &arglist);
}

void all_members_thread_callback(Var arglist, Var *ret, void *extra_data)
{
    *ret = new_list(0);
    Var data = arglist.v.list[1];
    Var *thelist = arglist.v.list[2].v.list;

    for (int x = 1, list_size = arglist.v.list[2].v.list[0].v.num; x <= list_size; x++)
        if (equality(data, thelist[x], 0))
            *ret = listappend(*ret, Var::new_int(x));
}

/* Return the indices of all elements of a value in a list. */
static package
bf_all_members(Var arglist, Byte next, void *vdata, Objid progr)
{
    return background_thread(all_members_thread_callback, &arglist);
}

static package
bf_strsub(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (source, what, with [, case-matters]) */
    int case_matters = 0;
    Stream *s;
    package p;

    if (arglist.v.list[0].v.num == 4)
        case_matters = is_true(arglist.v.list[4]);
    if (arglist.v.list[2].v.str[0] == '\0') {
        free_var(arglist);
        return make_error_pack(E_INVARG);
    }
    s = new_stream(100);
    TRY_STREAM;
    try {
        Var r;
        stream_add_strsub(s, arglist.v.list[1].v.str, arglist.v.list[2].v.str,
                          arglist.v.list[3].v.str, case_matters);
        r.type = TYPE_STR;
        r.v.str = str_dup(stream_contents(s));
        p = make_var_pack(r);
    }
    catch (stream_too_big& exception) {
        p = make_space_pack();
    }
    ENDTRY_STREAM;
    free_stream(s);
    free_var(arglist);
    return p;
}

static int
signum(int x)
{
    return x < 0 ? -1 : (x > 0 ? 1 : 0);
}

static package
bf_strcmp(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (string1, string2) */
    Var r;

    r.type = TYPE_INT;
    r.v.num = signum(strcmp(arglist.v.list[1].v.str, arglist.v.list[2].v.str));
    free_var(arglist);
    return make_var_pack(r);
}

static package
bf_strtr(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (subject, from, to [, case_matters]) */
    Var r;
    int case_matters = 0;

    if (arglist.v.list[0].v.num > 3)
        case_matters = is_true(arglist.v.list[4]);
    r.type = TYPE_STR;
    r.v.str = str_dup(strtr(arglist.v.list[1].v.str, memo_strlen(arglist.v.list[1].v.str),
                            arglist.v.list[2].v.str, memo_strlen(arglist.v.list[2].v.str),
                            arglist.v.list[3].v.str, memo_strlen(arglist.v.list[3].v.str),
                            case_matters));
    free_var(arglist);
    return make_var_pack(r);
}

static package
bf_index(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (source, what [, case-matters [, offset]]) */
    Var r;
    int case_matters = 0;
    int offset = 0;

    if (arglist.v.list[0].v.num > 2)
        case_matters = is_true(arglist.v.list[3]);
    if (arglist.v.list[0].v.num > 3)
        offset = arglist.v.list[4].v.num;
    if (offset < 0) {
        free_var(arglist);
        return make_error_pack(E_INVARG);
    }

    /* `offset' skips the first `offset' characters before searching, and
     * the result (like the byte-based version before it) is a position
     * relative to that skipped-past point, not the start of the whole
     * string. The strindex() scan itself stays byte-oriented -- safe
     * because of UTF-8's self-synchronizing property -- only the offset
     * in and the position out need codepoint conversion. */
    const char *source = arglist.v.list[1].v.str;
    size_t source_byte_len = memo_strlen(source);
    bool source_ascii = memo_cplen(source) == source_byte_len;
    size_t skip = utf8_offset_of_char(source, source_byte_len, (size_t) offset + 1, source_ascii, source);
    int byte_pos = strindex(source + skip, source_byte_len - skip,
                             arglist.v.list[2].v.str, memo_strlen(arglist.v.list[2].v.str),
                             case_matters);

    /* `source + skip' points into the middle of `source''s allocation,
     * not its true base -- unsafe to key a cursor off of, but ascii-ness
     * is a per-byte property so it's still valid to pass through. */
    r.type = TYPE_INT;
    r.v.num = byte_pos
              ? (int) utf8_char_index_of_offset(source + skip, source_byte_len - skip, byte_pos - 1, source_ascii, nullptr)
              : 0;

    free_var(arglist);
    return make_var_pack(r);
}

static package
bf_rindex(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (source, what [, case-matters [, offset]]) */
    Var r;

    int case_matters = 0;
    int offset = 0;

    if (arglist.v.list[0].v.num > 2)
        case_matters = is_true(arglist.v.list[3]);
    if (arglist.v.list[0].v.num > 3)
        offset = arglist.v.list[4].v.num;
    if (offset > 0) {
        free_var(arglist);
        return make_error_pack(E_INVARG);
    }

    /* `offset' (<= 0) ignores the last |offset| characters when
     * searching; the result is an absolute character position in the
     * (untruncated) original string. */
    const char *source = arglist.v.list[1].v.str;
    size_t source_byte_len = memo_strlen(source);
    int source_cp_len = (int) memo_cplen(source);
    bool source_ascii = (size_t) source_cp_len == source_byte_len;
    int keep_chars = source_cp_len + offset;
    size_t search_byte_len = keep_chars > 0
                              ? utf8_offset_of_char(source, source_byte_len, (size_t) keep_chars + 1, source_ascii, source)
                              : 0;
    int byte_pos = strrindex(source, (int) search_byte_len,
                              arglist.v.list[2].v.str, memo_strlen(arglist.v.list[2].v.str),
                              case_matters);

    r.type = TYPE_INT;
    r.v.num = byte_pos ? (int) utf8_char_index_of_offset(source, source_byte_len, byte_pos - 1, source_ascii, source) : 0;

    free_var(arglist);
    return make_var_pack(r);
}

static package
bf_strfindall(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (source, what [, case-matters [, offset]]) */
    int case_matters = 0;
    int offset = 0;

    if (arglist.v.list[0].v.num > 2)
        case_matters = is_true(arglist.v.list[3]);
    if (arglist.v.list[0].v.num > 3)
        offset = arglist.v.list[4].v.num;

    const char *what = arglist.v.list[2].v.str;
    if (offset < 0 || what[0] == '\0') {
        free_var(arglist);
        return make_error_pack(E_INVARG);
    }

    const char *source = arglist.v.list[1].v.str;
    size_t source_byte_len = memo_strlen(source);
    bool source_ascii = memo_cplen(source) == source_byte_len;
    int what_len = memo_strlen(what);

    /* `pos' tracks a byte offset throughout (needed for the byte-oriented
     * strindex() scan and to correctly advance past a just-found match),
     * but each reported position is converted to an absolute character
     * index in the original string. */
    Var ret = new_list(0);
    size_t pos = utf8_offset_of_char(source, source_byte_len, (size_t) offset + 1, source_ascii, source);
    while (pos < source_byte_len) {
        int found = strindex(source + pos, source_byte_len - pos, what, what_len, case_matters);
        if (!found)
            break;
        Var v;
        v.type = TYPE_INT;
        v.v.num = (int) utf8_char_index_of_offset(source, source_byte_len, pos + found - 1, source_ascii, source);
        ret = listappend(ret, v);
        pos += (found - 1) + what_len;
    }

    free_var(arglist);
    return make_var_pack(ret);
}

static package
bf_tostr(Var arglist, Byte next, void *vdata, Objid progr)
{
    package p;
    Stream *s = new_stream(100);

    TRY_STREAM;
    try {
        Var r;
        int i;

        for (i = 1; i <= arglist.v.list[0].v.num; i++) {
            stream_add_tostr(s, arglist.v.list[i]);
        }
        r.type = TYPE_STR;
        r.v.str = str_dup(stream_contents(s));
        p = make_var_pack(r);
    }
    catch (stream_too_big& exception) {
        p = make_space_pack();
    }
    ENDTRY_STREAM;
    free_stream(s);
    free_var(arglist);
    return p;
}

static package
bf_toliteral(Var arglist, Byte next, void *vdata, Objid progr)
{
    package p;
    Stream *s = new_stream(100);

    TRY_STREAM;
    try {
        Var r;

        unparse_value(s, arglist.v.list[1]);
        r.type = TYPE_STR;
        r.v.str = str_dup(stream_contents(s));
        p = make_var_pack(r);
    }
    catch (stream_too_big& exception) {
        p = make_space_pack();
    }
    ENDTRY_STREAM;
    free_stream(s);
    free_var(arglist);
    return p;
}

struct pat_cache_entry {
    char *string;
    int case_matters;
    Pattern pattern;
    struct pat_cache_entry *next;
};

static struct pat_cache_entry *pat_cache;
static struct pat_cache_entry pat_cache_entries[PATTERN_CACHE_SIZE];

static void
setup_pattern_cache()
{
    int i;

    for (i = 0; i < PATTERN_CACHE_SIZE; i++) {
        pat_cache_entries[i].string = nullptr;
        pat_cache_entries[i].pattern.ptr = nullptr;
    }

    for (i = 0; i < PATTERN_CACHE_SIZE - 1; i++)
        pat_cache_entries[i].next = &(pat_cache_entries[i + 1]);
    pat_cache_entries[PATTERN_CACHE_SIZE - 1].next = nullptr;

    pat_cache = &(pat_cache_entries[0]);
}

static Pattern
get_pattern(const char *string, int case_matters)
{
    struct pat_cache_entry *entry, **entry_ptr;

    entry = pat_cache;
    entry_ptr = &pat_cache;

    while (1) {
        if (entry->string && !strcmp(string, entry->string)
                && case_matters == entry->case_matters) {
            /* A cache hit; move this entry to the front of the cache. */
            break;
        } else if (!entry->next) {
            /* A cache miss; this is the last entry in the cache, so reuse that
             * one for this pattern, moving it to the front of the cache iff
             * the compilation succeeds.
             */
            if (entry->string) {
                free_str(entry->string);
                free_pattern(entry->pattern);
            }
            entry->pattern = new_pattern(string, case_matters);
            entry->case_matters = case_matters;
            if (!entry->pattern.ptr)
                entry->string = nullptr;
            else
                entry->string = str_dup(string);
            break;
        } else {
            /* not done searching the cache... */
            entry_ptr = &(entry->next);
            entry = entry->next;
        }
    }

    *entry_ptr = entry->next;
    entry->next = pat_cache;
    pat_cache = entry;
    return entry->pattern;
}

Var
do_match(Var arglist, int reverse)
{
    const char *subject, *pattern;
    int i;
    Pattern pat;
    Var ans;
    Match_Indices regs[10];

    subject = arglist.v.list[1].v.str;
    pattern = arglist.v.list[2].v.str;
    pat = get_pattern(pattern, (arglist.v.list[0].v.num == 3
                                && is_true(arglist.v.list[3])));

    if (!pat.ptr) {
        ans.type = TYPE_ERR;
        ans.v.err = E_INVARG;
    } else
        switch (match_pattern(pat, subject, regs, reverse)) {
            default:
                panic_moo("do_match:  match_pattern returned unfortunate value.\n");
            /*notreached*/
            case MATCH_SUCCEEDED:
            {
                /* match_pattern() (a byte-oriented legacy engine, not
                 * PCRE2) reports 1-based, closed-interval BYTE
                 * positions; convert to codepoint positions here, at
                 * the MOO-facing boundary, leaving the engine itself
                 * untouched. A group that didn't participate in the
                 * match is sentinel-marked (start=0, end=-1, see
                 * invalid_pair()) and must be passed through as-is,
                 * not converted. */
                size_t subj_byte_len = memo_strlen(subject);
                bool subj_ascii = memo_cplen(subject) == subj_byte_len;
                ans = new_list(4);
                ans.v.list[1].type = TYPE_INT;
                ans.v.list[2].type = TYPE_INT;
                ans.v.list[4].type = TYPE_STR;
                ans.v.list[1].v.num = regs[0].start > 0
                    ? (int) utf8_char_index_of_offset(subject, subj_byte_len, (size_t) regs[0].start - 1, subj_ascii, subject)
                    : regs[0].start;
                ans.v.list[2].v.num = regs[0].start > 0
                    ? (int) utf8_char_index_of_offset(subject, subj_byte_len, (size_t) regs[0].end - 1, subj_ascii, subject)
                    : regs[0].end;
                ans.v.list[3] = new_list(9);
                ans.v.list[4].v.str = str_ref(subject);
                for (i = 1; i <= 9; i++) {
                    ans.v.list[3].v.list[i] = new_list(2);
                    ans.v.list[3].v.list[i].v.list[1].type = TYPE_INT;
                    ans.v.list[3].v.list[i].v.list[1].v.num = regs[i].start > 0
                        ? (int) utf8_char_index_of_offset(subject, subj_byte_len, (size_t) regs[i].start - 1, subj_ascii, subject)
                        : regs[i].start;
                    ans.v.list[3].v.list[i].v.list[2].type = TYPE_INT;
                    ans.v.list[3].v.list[i].v.list[2].v.num = regs[i].start > 0
                        ? (int) utf8_char_index_of_offset(subject, subj_byte_len, (size_t) regs[i].end - 1, subj_ascii, subject)
                        : regs[i].end;
                }
                break;
            }
            case MATCH_FAILED:
                ans = new_list(0);
                break;
            case MATCH_ABORTED:
                ans.type = TYPE_ERR;
                ans.v.err = E_QUOTA;
                break;
        }

    return ans;
}

static package
bf_match(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var ans;

    ans = do_match(arglist, 0);
    free_var(arglist);
    if (ans.type == TYPE_ERR)
        return make_error_pack(ans.v.err);
    else
        return make_var_pack(ans);
}

static package
bf_rmatch(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var ans;

    ans = do_match(arglist, 1);
    free_var(arglist);
    if (ans.type == TYPE_ERR)
        return make_error_pack(ans.v.err);
    else
        return make_var_pack(ans);
}

int
invalid_pair(int num1, int num2, int max)
{
    if ((num1 == 0 && num2 == -1)
            || (num1 > 0 && num2 >= num1 - 1 && num2 <= max))
        return 0;
    else
        return 1;
}

int
check_subs_list(Var subs)
{
    const char *subj;
    int subj_length, loop;

    if (subs.type != TYPE_LIST || subs.v.list[0].v.num != 4
            || subs.v.list[1].type != TYPE_INT
            || subs.v.list[2].type != TYPE_INT
            || subs.v.list[3].type != TYPE_LIST
            || subs.v.list[3].v.list[0].v.num != 9
            || subs.v.list[4].type != TYPE_STR)
        return 1;
    subj = subs.v.list[4].v.str;
    subj_length = memo_cplen(subj);
    if (invalid_pair(subs.v.list[1].v.num, subs.v.list[2].v.num,
                     subj_length))
        return 1;

    for (loop = 1; loop <= 9; loop++) {
        Var pair;
        pair = subs.v.list[3].v.list[loop];
        if (pair.type != TYPE_LIST
                || pair.v.list[0].v.num != 2
                || pair.v.list[1].type != TYPE_INT
                || pair.v.list[2].type != TYPE_INT
                || invalid_pair(pair.v.list[1].v.num, pair.v.list[2].v.num,
                                subj_length))
            return 1;
    }
    return 0;
}

static package
bf_substitute(Var arglist, Byte next, void *vdata, Objid progr)
{
    int template_length;
    const char *_template, *subject;
    Var subs, ans;
    package p;
    Stream *s;
    char c = '\0';

    _template = arglist.v.list[1].v.str;
    template_length = memo_strlen(_template);
    subs = arglist.v.list[2];

    if (check_subs_list(subs)) {
        free_var(arglist);
        return make_error_pack(E_INVARG);
    }
    subject = subs.v.list[4].v.str;

    s = new_stream(template_length);
    TRY_STREAM;
    try {
        while ((c = *(_template++)) != '\0') {
            if (c != '%')
                stream_add_char(s, c);
            else if ((c = *(_template++)) == '%')
                stream_add_char(s, '%');
            else {
                /* start/end are 1-based codepoint positions (do_match()
                 * converts match_pattern()'s raw byte offsets at the
                 * MOO-facing boundary) -- resolve them to a byte range
                 * before copying, rather than indexing `subject' by
                 * position directly. */
                int start = 0, end = 0;
                if (c >= '1' && c <= '9') {
                    Var pair = subs.v.list[3].v.list[c - '0'];
                    start = pair.v.list[1].v.num;
                    end = pair.v.list[2].v.num;
                } else if (c == '0') {
                    start = subs.v.list[1].v.num;
                    end = subs.v.list[2].v.num;
                } else {
                    p = make_error_pack(E_INVARG);
                    goto oops;
                }
                if (start <= end) {
                    size_t subj_byte_len = memo_strlen(subject);
                    bool subj_ascii = memo_cplen(subject) == subj_byte_len;
                    size_t byte_start = utf8_offset_of_char(subject, subj_byte_len, (size_t) start, subj_ascii, subject);
                    size_t byte_end = utf8_offset_of_char(subject, subj_byte_len, (size_t) end + 1, subj_ascii, subject);
                    for (size_t k = byte_start; k < byte_end; k++)
                        stream_add_char(s, subject[k]);
                }
            }
        }
        ans.type = TYPE_STR;
        ans.v.str = str_dup(stream_contents(s));
        p = make_var_pack(ans);
oops: ;
    }
    catch (stream_too_big& exception) {
        p = make_space_pack();
    }
    ENDTRY_STREAM;
    free_var(arglist);
    free_stream(s);
    return p;
}

static package
bf_value_bytes(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var r;

    r.type = TYPE_INT;
    r.v.num = value_bytes(arglist.v.list[1]);
    free_var(arglist);
    return make_var_pack(r);
}

static package
bf_decode_binary(Var arglist, Byte next, void *vdata, Objid progr)
{
    int length;
    const char *bytes = binary_to_raw_bytes(arglist.v.list[1].v.str, &length);
    int nargs = arglist.v.list[0].v.num;
    int fully = (nargs >= 2 && is_true(arglist.v.list[2]));
    Var r;
    int i;

    free_var(arglist);
    if (!bytes)
        return make_error_pack(E_INVARG);

    if (fully) {
        r = new_list(length);
        for (i = 1; i <= length; i++) {
            r.v.list[i].type = TYPE_INT;
            r.v.list[i].v.num = (unsigned char) bytes[i - 1];
        }
    } else {
        int count, in_string;
        Stream *s = new_stream(50);

        for (count = in_string = 0, i = 0; i < length; i++) {
            unsigned char c = bytes[i];

            if (isgraph(c) || c == ' ' || c == '\t') {
                if (!in_string)
                    count++;
                in_string = 1;
            } else {
                count++;
                in_string = 0;
            }
        }

        r = new_list(count);
        for (count = 1, in_string = 0, i = 0; i < length; i++) {
            unsigned char c = bytes[i];

            if (isgraph(c) || c == ' ' || c == '\t') {
                stream_add_char(s, c);
                in_string = 1;
            } else {
                if (in_string) {
                    r.v.list[count].type = TYPE_STR;
                    r.v.list[count].v.str = str_dup(reset_stream(s));
                    count++;
                }
                r.v.list[count].type = TYPE_INT;
                r.v.list[count].v.num = c;
                count++;
                in_string = 0;
            }
        }

        if (in_string) {
            r.v.list[count].type = TYPE_STR;
            r.v.list[count].v.str = str_dup(reset_stream(s));
        }
        free_stream(s);
    }

    if (value_bytes(r) <= server_int_option_cached(SVO_MAX_LIST_VALUE_BYTES))
        return make_var_pack(r);
    else {
        free_var(r);
        return make_space_pack();
    }
}

static int
encode_binary(Stream * s, Var v, int minimum, int maximum)
{
    int i;

    switch (v.type) {
        case TYPE_INT:
            if (v.v.num < minimum || v.v.num > maximum)
                return 0;
            stream_add_char(s, (char) v.v.num);
            break;
        case TYPE_STR:
            stream_add_string(s, v.v.str);
            break;
        case TYPE_LIST:
            for (i = 1; i <= v.v.list[0].v.num; i++)
                if (!encode_binary(s, v.v.list[i], minimum, maximum))
                    return 0;
            break;
        default:
            return 0;
    }

    return 1;
}

static package
bf_encode_binary(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var r;
    package p;
    Stream *s = new_stream(100);
    Stream *s2 = new_stream(100);

    TRY_STREAM;
    try {
        if (encode_binary(s, arglist, 0, 255)) {
            stream_add_raw_bytes_to_binary(
                s2, stream_contents(s), stream_length(s));
            r.type = TYPE_STR;
            r.v.str = str_dup(stream_contents(s2));
            p = make_var_pack(r);
        }
        else
            p = make_error_pack(E_INVARG);
    }
    catch (stream_too_big& exception) {
        p = make_space_pack();
    }
    ENDTRY_STREAM;
    free_stream(s2);
    free_stream(s);
    free_var(arglist);
    return p;
}

static package
bf_chr(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var r;
    package p;
    Stream *s = new_stream(100);

    TRY_STREAM;
    try {
        int encoded = (!is_wizard(progr) ? encode_binary(s, arglist, 32, 254) : encode_binary(s, arglist, 0, 255));
        if (encoded) {
            r.type = TYPE_STR;
            r.v.str = str_dup(stream_contents(s));
            p = make_var_pack(r);
        }
        else
            p = make_error_pack(E_INVARG);
    }
    catch (stream_too_big& exception) {
        p = make_space_pack();
    }
    ENDTRY_STREAM;
    free_stream(s);
    free_var(arglist);
    return p;
}

/* Companion to chr(): each argument is a Unicode codepoint (not a raw byte),
 * encoded as 1-4 UTF-8 bytes and concatenated, so verb code can build
 * non-ASCII text directly instead of chaining multiple single-byte chr()
 * calls. As with chr(), non-wizards can't produce control characters --
 * here that means the C0 (0-0x1F) and C1 (0x7F-0x9F) control codepoints,
 * regardless of how many bytes they'd encode to. */
static package
bf_unichr(Var arglist, Byte next, void *vdata, Objid progr)
{
    Var r;
    package p;
    Stream *s = new_stream(64);
    bool ok = true;
    bool wiz = is_wizard(progr);

    TRY_STREAM;
    try {
        for (int i = 1; ok && i <= arglist.v.list[0].v.num; i++) {
            Num cp = arglist.v.list[i].v.num;
            char buf[4];
            size_t len;

            if (cp < 0 || cp > 0x10FFFF ||
                (!wiz && (cp <= 0x1F || (cp >= 0x7F && cp <= 0x9F))) ||
                (len = utf8_encode_char((uint32_t) cp, buf)) == 0) {
                ok = false;
                break;
            }

            for (size_t j = 0; j < len; j++)
                stream_add_char(s, buf[j]);
        }

        if (ok) {
            r.type = TYPE_STR;
            r.v.str = str_dup(stream_contents(s));
            p = make_var_pack(r);
        }
        else
            p = make_error_pack(E_INVARG);
    }
    catch (stream_too_big& exception) {
        p = make_space_pack();
    }
    ENDTRY_STREAM;
    free_stream(s);
    free_var(arglist);
    return p;
}

static package
bf_parse_ansi(Var arglist, Byte next, void *vdata, Objid progr)
{
#define ANSI_TAG_TO_CODE(tag, code, case_matters)           \
    {                                   \
        stream_add_strsub(str, reset_stream(tmp), tag, code, case_matters); \
        stream_add_string(tmp, reset_stream(str));              \
    }

    Var r;
    r.type = TYPE_STR;

    Stream *str = new_stream(50);
    Stream *tmp = new_stream(50);
    const char *random_codes[] = {"\e[31m", "\e[32m", "\e[33m", "\e[34m", "\e[35m", "\e[35m", "\e[36m"};

    stream_add_string(tmp, arglist.v.list[1].v.str);
    free_var(arglist);

    ANSI_TAG_TO_CODE("[red]",        "\e[31m",   0);
    ANSI_TAG_TO_CODE("[green]",      "\e[32m",   0);
    ANSI_TAG_TO_CODE("[yellow]",     "\e[33m",   0);
    ANSI_TAG_TO_CODE("[blue]",       "\e[34m",   0);
    ANSI_TAG_TO_CODE("[purple]",     "\e[35m",   0);
    ANSI_TAG_TO_CODE("[cyan]",       "\e[36m",   0);
    ANSI_TAG_TO_CODE("[normal]",     "\e[0m",    0);
    ANSI_TAG_TO_CODE("[inverse]",    "\e[7m",    0);
    ANSI_TAG_TO_CODE("[underline]",  "\e[4m",    0);
    ANSI_TAG_TO_CODE("[bold]",       "\e[1m",    0);
    ANSI_TAG_TO_CODE("[bright]",     "\e[1m",    0);
    ANSI_TAG_TO_CODE("[unbold]",     "\e[22m",   0);
    ANSI_TAG_TO_CODE("[blink]",      "\e[5m",    0);
    ANSI_TAG_TO_CODE("[unblink]",    "\e[25m",   0);
    ANSI_TAG_TO_CODE("[magenta]",    "\e[35m",   0);
    ANSI_TAG_TO_CODE("[unbright]",   "\e[22m",   0);
    ANSI_TAG_TO_CODE("[white]",      "\e[37m",   0);
    ANSI_TAG_TO_CODE("[gray]",       "\e[1;30m", 0);
    ANSI_TAG_TO_CODE("[grey]",       "\e[1;30m", 0);
    ANSI_TAG_TO_CODE("[beep]",       "\a",       0);
    ANSI_TAG_TO_CODE("[black]",      "\e[30m",   0);
    ANSI_TAG_TO_CODE("[b:black]",   "\e[40m",   0);
    ANSI_TAG_TO_CODE("[b:red]",     "\e[41m",   0);
    ANSI_TAG_TO_CODE("[b:green]",   "\e[42m",   0);
    ANSI_TAG_TO_CODE("[b:yellow]",  "\e[43m",   0);
    ANSI_TAG_TO_CODE("[b:blue]",    "\e[44m",   0);
    ANSI_TAG_TO_CODE("[b:magenta]", "\e[45m",   0);
    ANSI_TAG_TO_CODE("[b:purple]",  "\e[45m",   0);
    ANSI_TAG_TO_CODE("[b:cyan]",    "\e[46m",   0);
    ANSI_TAG_TO_CODE("[b:white]",   "\e[47m",   0);

    char *t = reset_stream(tmp);
    while (*t) {
        if (!strncasecmp(t, "[random]", 8)) {
            stream_add_string(str, random_codes[RANDOM() % 6]);
            t += 8;
        } else
            stream_add_char(str, *t++);
    }

    stream_add_strsub(tmp, reset_stream(str), "[null]", "", 0);

    ANSI_TAG_TO_CODE("[null]", "", 0);

    r.v.str = str_dup(reset_stream(tmp));

    free_stream(tmp);
    free_stream(str);
    return make_var_pack(r);

#undef ANSI_TAG_TO_CODE
}

static package
bf_remove_ansi(Var arglist, Byte next, void *vdata, Objid progr)
{

#define MARK_FOR_REMOVAL(tag)                   \
    {                               \
        stream_add_strsub(tmp, reset_stream(tmp), tag, "", 0);  \
    }
    Var r;
    Stream *tmp;

    tmp = new_stream(50);
    stream_add_string(tmp, arglist.v.list[1].v.str);
    free_var(arglist);

    MARK_FOR_REMOVAL("[red]");
    MARK_FOR_REMOVAL("[green]");
    MARK_FOR_REMOVAL("[yellow]");
    MARK_FOR_REMOVAL("[blue]");
    MARK_FOR_REMOVAL("[purple]");
    MARK_FOR_REMOVAL("[cyan]");
    MARK_FOR_REMOVAL("[normal]");
    MARK_FOR_REMOVAL("[inverse]");
    MARK_FOR_REMOVAL("[underline]");
    MARK_FOR_REMOVAL("[bold]");
    MARK_FOR_REMOVAL("[bright]");
    MARK_FOR_REMOVAL("[unbold]");
    MARK_FOR_REMOVAL("[blink]");
    MARK_FOR_REMOVAL("[unblink]");
    MARK_FOR_REMOVAL("[magenta]");
    MARK_FOR_REMOVAL("[unbright]");
    MARK_FOR_REMOVAL("[white]");
    MARK_FOR_REMOVAL("[gray]");
    MARK_FOR_REMOVAL("[grey]");
    MARK_FOR_REMOVAL("[beep]");
    MARK_FOR_REMOVAL("[black]");
    MARK_FOR_REMOVAL("[b:black]");
    MARK_FOR_REMOVAL("[b:red]");
    MARK_FOR_REMOVAL("[b:green]");
    MARK_FOR_REMOVAL("[b:yellow]");
    MARK_FOR_REMOVAL("[b:blue]");
    MARK_FOR_REMOVAL("[b:magenta]");
    MARK_FOR_REMOVAL("[b:purple]");
    MARK_FOR_REMOVAL("[b:cyan]");
    MARK_FOR_REMOVAL("[b:white]");
    MARK_FOR_REMOVAL("[random]");
    MARK_FOR_REMOVAL("[null]");

    r.type = TYPE_STR;
    r.v.str = str_dup(reset_stream(tmp));

    free_stream(tmp);
    return make_var_pack(r);

#undef MARK_FOR_REMOVAL
}

static package
bf_pad(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (str, width [, char] [, side]) */
    int nargs = arglist.v.list[0].v.num;
    const char *str = arglist.v.list[1].v.str;
    int width = arglist.v.list[2].v.num;
    size_t byte_len = memo_strlen(str);
    size_t cp_len = memo_cplen(str);

    /* `fill' is the first whole CHARACTER of the fill argument (1-4
     * bytes), not just its first byte. */
    const char *fill = " ";
    size_t fill_len = 1;
    if (nargs >= 3 && memo_strlen(arglist.v.list[3].v.str) > 0) {
        fill = arglist.v.list[3].v.str;
        fill_len = utf8_char_byte_length(fill, memo_strlen(fill));
    }

    const char *side = (nargs >= 4) ? arglist.v.list[4].v.str : "right";
    if (strcmp(side, "left") && strcmp(side, "right") && strcmp(side, "both")) {
        free_var(arglist);
        return make_error_pack(E_INVARG);
    }

    /* Signed comparison on purpose: width can be negative (meaning "no
     * padding needed"), and casting it to size_t first would wrap a
     * negative value into an enormous unsigned one, defeating this
     * no-op check entirely. */
    if (width <= (int) cp_len) {
        Var r = str_dup_to_var(str);
        free_var(arglist);
        return make_var_pack(r);
    }

    size_t total_pad = (size_t) width - cp_len;
    size_t left_pad = !strcmp(side, "left") ? total_pad
                     : !strcmp(side, "both") ? total_pad / 2
                     : 0;
    size_t right_pad = total_pad - left_pad;
    size_t out_byte_len = left_pad * fill_len + byte_len + right_pad * fill_len;

    if (out_byte_len > stream_alloc_maximum) {
        free_var(arglist);
        return make_space_pack();
    }

    char *buf = (char *)mymalloc(out_byte_len + 1, M_STRING);
    size_t pos = 0;
    for (size_t i = 0; i < left_pad; i++, pos += fill_len)
        memcpy(buf + pos, fill, fill_len);
    memcpy(buf + pos, str, byte_len);
    pos += byte_len;
    for (size_t i = 0; i < right_pad; i++, pos += fill_len)
        memcpy(buf + pos, fill, fill_len);
    buf[pos] = '\0';

    Var r;
    r.type = TYPE_STR;
    r.v.str = buf;
    free_var(arglist);
    return make_var_pack(r);
}

static package
do_strtrim(Var arglist, bool trim_left, bool trim_right)
{
    int nargs = arglist.v.list[0].v.num;
    const char *str = arglist.v.list[1].v.str;
    size_t byte_len = memo_strlen(str);

    /* `trim_char' is the first whole CHARACTER of the trim argument
     * (1-4 bytes), compared as a span rather than a single byte. */
    const char *trim_char = " ";
    size_t trim_len = 1;
    if (nargs >= 2 && memo_strlen(arglist.v.list[2].v.str) > 0) {
        trim_char = arglist.v.list[2].v.str;
        trim_len = utf8_char_byte_length(trim_char, memo_strlen(trim_char));
    }

    size_t start = 0, end = byte_len;
    if (trim_left)
        while (end - start >= trim_len && memcmp(str + start, trim_char, trim_len) == 0)
            start += trim_len;
    if (trim_right)
        while (end - start >= trim_len && memcmp(str + end - trim_len, trim_char, trim_len) == 0)
            end -= trim_len;

    size_t newlen = end - start;
    char *buf = (char *)mymalloc(newlen + 1, M_STRING);
    memcpy(buf, str + start, newlen);
    buf[newlen] = '\0';

    Var r;
    r.type = TYPE_STR;
    r.v.str = buf;
    free_var(arglist);
    return make_var_pack(r);
}

static package
bf_strtrim(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (str [, char]) */
    return do_strtrim(arglist, true, true);
}

static package
bf_strtriml(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (str [, char]) */
    return do_strtrim(arglist, true, false);
}

static package
bf_strtrimr(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (str [, char]) */
    return do_strtrim(arglist, false, true);
}

static package
do_str_case(Var arglist, bool upper)
{
    const char *str = arglist.v.list[1].v.str;
    size_t byte_len = memo_strlen(str);
    Stream *s = new_stream(byte_len + 8);
    size_t i = 0;

    while (i < byte_len) {
        uint32_t cp;
        size_t clen = utf8_decode_char(str + i, byte_len - i, &cp);

        if (clen == 1 && (unsigned char) str[i] >= 0x80) {
            /* utf8_decode_char()'s invalid-byte fallback: this isn't a
             * real codepoint (its numeric value just happens to collide
             * with one, since it's the raw byte value), so it must pass
             * through untouched rather than being run through the
             * case-mapping table. */
            stream_add_char(s, str[i]);
        } else {
            uint32_t mapped = upper ? unicode_simple_upper(cp) : unicode_simple_lower(cp);
            char enc[4];
            size_t elen = utf8_encode_char(mapped, enc);
            for (size_t j = 0; j < elen; j++)
                stream_add_char(s, enc[j]);
        }
        i += clen;
    }

    Var r;
    r.type = TYPE_STR;
    r.v.str = str_dup(reset_stream(s));
    free_stream(s);
    free_var(arglist);
    return make_var_pack(r);
}

static package
bf_strupper(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (str) */
    return do_str_case(arglist, true);
}

static package
bf_strlower(Var arglist, Byte next, void *vdata, Objid progr)
{   /* (str) */
    return do_str_case(arglist, false);
}

void
register_list(void)
{
    register_function("value_bytes", 1, 1, bf_value_bytes, TYPE_ANY);

    register_function("decode_binary", 1, 2, bf_decode_binary,
                      TYPE_STR, TYPE_ANY);
    register_function("encode_binary", 0, -1, bf_encode_binary);
    register_function("chr", 0, -1, bf_chr);
    register_function("unichr", 1, -1, bf_unichr, TYPE_INT);
    /* list */
    register_function("length", 1, 1, bf_length, TYPE_ANY);
    register_function("setadd", 2, 2, bf_setadd, TYPE_LIST, TYPE_ANY);
    register_function("setremove", 2, 2, bf_setremove, TYPE_LIST, TYPE_ANY);
    register_function("listremove_all", 2, 3, bf_listremove_all,
                      TYPE_LIST, TYPE_ANY, TYPE_INT);
    register_function("listunique", 1, 2, bf_listunique,
                      TYPE_LIST, TYPE_INT);
    register_function("listappend", 2, 3, bf_listappend,
                      TYPE_LIST, TYPE_ANY, TYPE_INT);
    register_function("listinsert", 2, 3, bf_listinsert,
                      TYPE_LIST, TYPE_ANY, TYPE_INT);
    register_function("listdelete", 2, 2, bf_listdelete, TYPE_LIST, TYPE_INT);
    register_function("listset", 3, 3, bf_listset,
                      TYPE_LIST, TYPE_ANY, TYPE_INT);
    register_function("listget", 2, 3, bf_listget,
                      TYPE_LIST, TYPE_INT, TYPE_ANY);
    register_function("equal", 2, 2, bf_equal, TYPE_ANY, TYPE_ANY);
    register_function("explode", 1, 3, bf_explode, TYPE_STR, TYPE_STR, TYPE_INT);
    register_function("reverse", 1, 1, bf_reverse, TYPE_ANY);
    register_function("slice", 1, 3, bf_slice, TYPE_LIST, TYPE_ANY, TYPE_ANY);
    register_function("sort", 1, 4, bf_sort, TYPE_LIST, TYPE_LIST, TYPE_INT, TYPE_INT);
    register_function("all_members", 2, 2, bf_all_members, TYPE_ANY, TYPE_LIST);

    /* string */
    register_function("tostr", 0, -1, bf_tostr);
    register_function("toliteral", 1, 1, bf_toliteral, TYPE_ANY);
    setup_pattern_cache();
    register_function("match", 2, 3, bf_match, TYPE_STR, TYPE_STR, TYPE_ANY);
    register_function("rmatch", 2, 3, bf_rmatch, TYPE_STR, TYPE_STR, TYPE_ANY);
    register_function("substitute", 2, 2, bf_substitute, TYPE_STR, TYPE_LIST);
    register_function("index", 2, 4, bf_index,
                      TYPE_STR, TYPE_STR, TYPE_ANY, TYPE_INT);
    register_function("rindex", 2, 4, bf_rindex,
                      TYPE_STR, TYPE_STR, TYPE_ANY, TYPE_INT);
    register_function("strfindall", 2, 4, bf_strfindall,
                      TYPE_STR, TYPE_STR, TYPE_ANY, TYPE_INT);
    register_function("strcmp", 2, 2, bf_strcmp, TYPE_STR, TYPE_STR);
    register_function("strsub", 3, 4, bf_strsub,
                      TYPE_STR, TYPE_STR, TYPE_STR, TYPE_ANY);
    register_function("strtr", 3, 4, bf_strtr,
                      TYPE_STR, TYPE_STR, TYPE_STR, TYPE_ANY);
    register_function("parse_ansi", 1, 1, bf_parse_ansi, TYPE_STR);
    register_function("remove_ansi", 1, 1, bf_remove_ansi, TYPE_STR);
    register_function("pad", 2, 4, bf_pad, TYPE_STR, TYPE_INT, TYPE_STR, TYPE_STR);
    register_function("strtrim", 1, 2, bf_strtrim, TYPE_STR, TYPE_STR);
    register_function("strtriml", 1, 2, bf_strtriml, TYPE_STR, TYPE_STR);
    register_function("strtrimr", 1, 2, bf_strtrimr, TYPE_STR, TYPE_STR);
    register_function("strupper", 1, 1, bf_strupper, TYPE_STR);
    register_function("strlower", 1, 1, bf_strlower, TYPE_STR);
}
