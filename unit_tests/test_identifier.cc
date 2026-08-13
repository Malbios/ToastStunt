// Unit tests for src/identifier.cc's UTF-8-decode + Unicode-identifier-
// classification combinators, the single shared point the lexer
// (src/parser.y) and unparser (ok_identifier() in src/unparse.cc) both
// use so their notion of "valid identifier character" can't drift apart.
#include "catch_amalgamated.hpp"
#include "identifier.h"

TEST_CASE("unicode_id_start_char accepts a valid 2-byte letter", "[identifier]") {
    // U+00E9 e-acute, UTF-8: 0xC3 0xA9
    const char s[] = "\xC3\xA9";
    size_t len; uint32_t cp;
    REQUIRE(unicode_id_start_char(s, 2, &len, &cp));
    REQUIRE(len == 2);
    REQUIRE(cp == 0x00E9);
}

TEST_CASE("unicode_id_start_char accepts a valid 3-byte letter", "[identifier]") {
    // U+4E2D CJK ideograph, UTF-8: 0xE4 0xB8 0xAD
    const char s[] = "\xE4\xB8\xAD";
    size_t len; uint32_t cp;
    REQUIRE(unicode_id_start_char(s, 3, &len, &cp));
    REQUIRE(len == 3);
    REQUIRE(cp == 0x4E2D);
}

TEST_CASE("unicode_id_start_char rejects a symbol even though the UTF-8 is well-formed", "[identifier]") {
    // U+2603 SNOWMAN, UTF-8: 0xE2 0x98 0x83 -- valid bytes, not a letter.
    const char s[] = "\xE2\x98\x83";
    size_t len; uint32_t cp;
    REQUIRE_FALSE(unicode_id_start_char(s, 3, &len, &cp));
}

TEST_CASE("unicode_id_start_char rejects a lone stray continuation byte", "[identifier]") {
    const char s[] = "\x80";
    size_t len; uint32_t cp;
    REQUIRE_FALSE(unicode_id_start_char(s, 1, &len, &cp));
}

TEST_CASE("unicode_id_start_char rejects a sequence truncated by avail", "[identifier]") {
    // The full sequence is 3 bytes (0xE4 0xB8 0xAD) but only 2 are
    // available -- must not read past `avail`, and must reject rather
    // than accept a partial decode.
    const char s[] = "\xE4\xB8\xAD";
    size_t len; uint32_t cp;
    REQUIRE_FALSE(unicode_id_start_char(s, 2, &len, &cp));
}

TEST_CASE("unicode_id_start_char rejects a combining mark at start position", "[identifier]") {
    // U+0301 COMBINING ACUTE ACCENT, UTF-8: 0xCC 0x81 -- valid UTF-8,
    // valid codepoint, but not XID_Start (marks can only continue).
    const char s[] = "\xCC\x81";
    size_t len; uint32_t cp;
    REQUIRE_FALSE(unicode_id_start_char(s, 2, &len, &cp));
}

TEST_CASE("unicode_id_continue_char accepts the same combining mark that unicode_id_start_char rejects", "[identifier]") {
    const char s[] = "\xCC\x81";
    size_t len; uint32_t cp;
    REQUIRE(unicode_id_continue_char(s, 2, &len, &cp));
    REQUIRE(len == 2);
    REQUIRE(cp == 0x0301);
}

TEST_CASE("bounded_avail stops at a NUL terminator short of 4 bytes", "[identifier]") {
    REQUIRE(bounded_avail("ab") == 2);
    REQUIRE(bounded_avail("") == 0);
}

TEST_CASE("bounded_avail caps at 4 bytes even for a longer string", "[identifier]") {
    REQUIRE(bounded_avail("abcdef") == 4);
}
