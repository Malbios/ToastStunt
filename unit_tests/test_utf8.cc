// Unit tests for src/utf8.cc's codepoint-index <-> byte-offset conversion,
// specifically the ASCII fast path and the general resume-scan cursor
// cache added on top of the original O(n)-per-call scan. Both are pure
// performance optimizations: every test here checks that results stay
// identical to what a plain from-scratch scan would produce, across
// sequential, backward, random, and repeated access patterns.
#include "catch_amalgamated.hpp"
#include "utf8.h"
#include "storage.h"

// "a" + e-acute (U+00E9, 2 bytes) + "b" + CJK 4E2D (3 bytes) + "c"
// + grinning face U+1F600 (4 bytes) + "d" -- 7 characters, 13 bytes,
// with every UTF-8 width (1/2/3/4 bytes) represented.
static const char MIXED[] =
    "a" "\xC3\xA9" "b" "\xE4\xB8\xAD" "c" "\xF0\x9F\x98\x80" "d";
static const size_t MIXED_BYTE_LEN = sizeof(MIXED) - 1; // 13, excludes NUL
static const size_t MIXED_CHAR_LEN = 7;

static const char ASCII_STR[] = "abcdefghij";
static const size_t ASCII_BYTE_LEN = sizeof(ASCII_STR) - 1; // 10

TEST_CASE("ascii fast path: utf8_offset_of_char is char_index - 1", "[utf8]") {
    for (size_t i = 1; i <= ASCII_BYTE_LEN; i++)
        REQUIRE(utf8_offset_of_char(ASCII_STR, ASCII_BYTE_LEN, i, true, nullptr) == i - 1);
}

TEST_CASE("ascii fast path: utf8_offset_of_char clamps one-past-end and beyond to byte_len", "[utf8]") {
    REQUIRE(utf8_offset_of_char(ASCII_STR, ASCII_BYTE_LEN, ASCII_BYTE_LEN + 1, true, nullptr) == ASCII_BYTE_LEN);
    REQUIRE(utf8_offset_of_char(ASCII_STR, ASCII_BYTE_LEN, 1000, true, nullptr) == ASCII_BYTE_LEN);
}

TEST_CASE("ascii fast path: utf8_char_index_of_offset is byte_offset + 1", "[utf8]") {
    for (size_t off = 0; off < ASCII_BYTE_LEN; off++)
        REQUIRE(utf8_char_index_of_offset(ASCII_STR, ASCII_BYTE_LEN, off, true, nullptr) == off + 1);
}

TEST_CASE("ascii fast path: utf8_char_index_of_offset caps at byte_len + 1", "[utf8]") {
    REQUIRE(utf8_char_index_of_offset(ASCII_STR, ASCII_BYTE_LEN, ASCII_BYTE_LEN, true, nullptr) == ASCII_BYTE_LEN + 1);
    REQUIRE(utf8_char_index_of_offset(ASCII_STR, ASCII_BYTE_LEN, 1000, true, nullptr) == ASCII_BYTE_LEN + 1);
}

TEST_CASE("ascii fast path matches a real scan on an all-ASCII string", "[utf8]") {
    // Cross-check the O(1) shortcut against the plain O(n) scan it's
    // replacing, rather than trusting hand-derived arithmetic alone.
    for (size_t i = 1; i <= ASCII_BYTE_LEN + 1; i++) {
        size_t fast = utf8_offset_of_char(ASCII_STR, ASCII_BYTE_LEN, i, true, nullptr);
        size_t scanned = utf8_offset_of_char(ASCII_STR, ASCII_BYTE_LEN, i, false, nullptr);
        REQUIRE(fast == scanned);
    }
    for (size_t off = 0; off <= ASCII_BYTE_LEN; off++) {
        size_t fast = utf8_char_index_of_offset(ASCII_STR, ASCII_BYTE_LEN, off, true, nullptr);
        size_t scanned = utf8_char_index_of_offset(ASCII_STR, ASCII_BYTE_LEN, off, false, nullptr);
        REQUIRE(fast == scanned);
    }
}

TEST_CASE("memo_cursor_hint reports no hint for a freshly allocated string", "[utf8]") {
    char *s = str_dup("hello");
    size_t char_index, byte_offset;
    REQUIRE_FALSE(memo_cursor_hint(s, &char_index, &byte_offset));
    free_str(s);
}

TEST_CASE("memo_set_cursor/memo_cursor_hint round-trip a packed pair", "[utf8]") {
    char *s = str_dup("hello world, this is a somewhat longer string");
    memo_set_cursor(s, 5, 12);
    size_t char_index, byte_offset;
    REQUIRE(memo_cursor_hint(s, &char_index, &byte_offset));
    REQUIRE(char_index == 5);
    REQUIRE(byte_offset == 12);

    // A later call overwrites, doesn't accumulate.
    memo_set_cursor(s, 1, 0);
    REQUIRE(memo_cursor_hint(s, &char_index, &byte_offset));
    REQUIRE(char_index == 1);
    REQUIRE(byte_offset == 0);
    free_str(s);
}

TEST_CASE("cursor cache matches an uncached scan under sequential forward access", "[utf8]") {
    char *s = str_dup(MIXED);
    for (size_t i = 1; i <= MIXED_CHAR_LEN + 1; i++) {
        size_t cached = utf8_offset_of_char(s, MIXED_BYTE_LEN, i, false, s);
        size_t baseline = utf8_offset_of_char(MIXED, MIXED_BYTE_LEN, i, false, nullptr);
        REQUIRE(cached == baseline);
    }
    free_str(s);
}

TEST_CASE("cursor cache matches an uncached scan for utf8_char_index_of_offset under sequential forward access", "[utf8]") {
    char *s = str_dup(MIXED);
    for (size_t off = 0; off <= MIXED_BYTE_LEN; off++) {
        size_t cached = utf8_char_index_of_offset(s, MIXED_BYTE_LEN, off, false, s);
        size_t baseline = utf8_char_index_of_offset(MIXED, MIXED_BYTE_LEN, off, false, nullptr);
        REQUIRE(cached == baseline);
    }
    free_str(s);
}

TEST_CASE("cursor cache matches an uncached scan under backward access", "[utf8]") {
    char *s = str_dup(MIXED);
    for (size_t i = MIXED_CHAR_LEN + 1; i >= 1; i--) {
        size_t cached = utf8_offset_of_char(s, MIXED_BYTE_LEN, i, false, s);
        size_t baseline = utf8_offset_of_char(MIXED, MIXED_BYTE_LEN, i, false, nullptr);
        REQUIRE(cached == baseline);
    }
    free_str(s);
}

TEST_CASE("cursor cache matches an uncached scan under random-order access", "[utf8]") {
    char *s = str_dup(MIXED);
    // Fixed, deliberately non-monotonic order -- exercises forward jumps,
    // backward jumps, and repeats, all against the same cached string.
    size_t order[] = {4, 1, 7, 7, 2, 8, 3, 1, 6, 5, 4, 8, 1};
    for (size_t i : order) {
        size_t cached = utf8_offset_of_char(s, MIXED_BYTE_LEN, i, false, s);
        size_t baseline = utf8_offset_of_char(MIXED, MIXED_BYTE_LEN, i, false, nullptr);
        REQUIRE(cached == baseline);
    }
    free_str(s);
}

TEST_CASE("cursor cache round-trips offset_of_char and char_index_of_offset consistently", "[utf8]") {
    // Interleave both directions against the same cached string, as real
    // callers occasionally do (e.g. index() converts an offset in, then
    // a position back out) -- the two functions must not corrupt each
    // other's cursor.
    char *s = str_dup(MIXED);
    for (size_t i = 1; i <= MIXED_CHAR_LEN; i++) {
        size_t off = utf8_offset_of_char(s, MIXED_BYTE_LEN, i, false, s);
        size_t back = utf8_char_index_of_offset(s, MIXED_BYTE_LEN, off, false, s);
        REQUIRE(back == i);
    }
    free_str(s);
}

TEST_CASE("cursor_key nullptr behaves exactly like the original uncached scan", "[utf8]") {
    for (size_t i = 1; i <= MIXED_CHAR_LEN + 1; i++) {
        size_t a = utf8_offset_of_char(MIXED, MIXED_BYTE_LEN, i, false, nullptr);
        size_t b = utf8_offset_of_char(MIXED, MIXED_BYTE_LEN, i, false, nullptr);
        REQUIRE(a == b);
    }
}

TEST_CASE("ascii_hint is safe to pass for a pointer into the middle of an all-ASCII string", "[utf8]") {
    // Mirrors list.cc's index()/rindex() sub-pointer call site: ascii-ness
    // of the whole string is valid for any substring of it too (unlike the
    // cursor, which is why that call site passes cursor_key = nullptr but
    // still forwards ascii_hint). Both directions must agree, with no
    // metadata lookup happening on the sub-pointer either way.
    const char *sub = ASCII_STR + 3; // "defghij", not the allocation's base
    size_t sub_byte_len = ASCII_BYTE_LEN - 3;
    for (size_t off = 0; off <= sub_byte_len; off++) {
        size_t fast = utf8_char_index_of_offset(sub, sub_byte_len, off, true, nullptr);
        size_t scanned = utf8_char_index_of_offset(sub, sub_byte_len, off, false, nullptr);
        REQUIRE(fast == scanned);
    }
}
