// Unit tests for src/unicode_tables.cc's generated lookup tables. Spot
// checks known Unicode facts rather than re-deriving the whole table --
// the table itself is generated (see tools/gen_unicode_tables.py) and
// should not be hand-verified line by line here.
#include "catch_amalgamated.hpp"
#include "unicode_tables.h"

TEST_CASE("unicode_is_id_start accepts ASCII letters", "[unicode_tables]") {
    REQUIRE(unicode_is_id_start('A'));
    REQUIRE(unicode_is_id_start('a'));
    REQUIRE(unicode_is_id_start('Z'));
}

TEST_CASE("unicode_is_id_start rejects ASCII digits (continue-only)", "[unicode_tables]") {
    REQUIRE_FALSE(unicode_is_id_start('5'));
}

TEST_CASE("unicode_is_id_continue accepts ASCII digits", "[unicode_tables]") {
    REQUIRE(unicode_is_id_continue('5'));
}

TEST_CASE("a combining mark is id_continue but not id_start", "[unicode_tables]") {
    // U+0301 COMBINING ACUTE ACCENT
    REQUIRE(unicode_is_id_continue(0x0301));
    REQUIRE_FALSE(unicode_is_id_start(0x0301));
}

TEST_CASE("a CJK ideograph is both id_start and id_continue", "[unicode_tables]") {
    // U+4E2D, 中 (CJK UNIFIED IDEOGRAPH-4E2D)
    REQUIRE(unicode_is_id_start(0x4E2D));
    REQUIRE(unicode_is_id_continue(0x4E2D));
}

TEST_CASE("an emoji is neither id_start nor id_continue", "[unicode_tables]") {
    // U+1F600 GRINNING FACE
    REQUIRE_FALSE(unicode_is_id_start(0x1F600));
    REQUIRE_FALSE(unicode_is_id_continue(0x1F600));
}

TEST_CASE("a symbol (not a letter) is neither id_start nor id_continue", "[unicode_tables]") {
    // U+2603 SNOWMAN
    REQUIRE_FALSE(unicode_is_id_start(0x2603));
    REQUIRE_FALSE(unicode_is_id_continue(0x2603));
}

TEST_CASE("unicode_casefold folds accented upper/lower to the same value", "[unicode_tables]") {
    // U+00C9 LATIN CAPITAL LETTER E WITH ACUTE, U+00E9 lowercase
    REQUIRE(unicode_casefold(0x00C9) == unicode_casefold(0x00E9));
}

TEST_CASE("unicode_casefold folds the Kelvin sign to ASCII k", "[unicode_tables]") {
    // U+212A KELVIN SIGN case-folds to U+006B ('k'), a 3-byte codepoint
    // folding to a 1-byte one -- exercises the "byte length isn't
    // preserved by folding" case that callers must handle correctly.
    REQUIRE(unicode_casefold(0x212A) == 0x006B);
}

TEST_CASE("unicode_casefold is the identity for a codepoint with no mapping", "[unicode_tables]") {
    REQUIRE(unicode_casefold(0x4E2D) == 0x4E2D);
}

TEST_CASE("unicode_simple_upper and unicode_simple_lower are inverses for e-acute", "[unicode_tables]") {
    REQUIRE(unicode_simple_upper(0x00E9) == 0x00C9);
    REQUIRE(unicode_simple_lower(0x00C9) == 0x00E9);
}

TEST_CASE("unicode_simple_upper/lower are the identity for ASCII digits and CJK", "[unicode_tables]") {
    REQUIRE(unicode_simple_upper('5') == '5');
    REQUIRE(unicode_simple_lower('5') == '5');
    REQUIRE(unicode_simple_upper(0x4E2D) == 0x4E2D);
    REQUIRE(unicode_simple_lower(0x4E2D) == 0x4E2D);
}
