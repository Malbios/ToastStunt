// Unit tests for unicode_strcasecmp() (src/utils.cc), the Unicode-aware
// replacement for libc strcasecmp() used at property/variable-name
// equality checks (src/db_properties.cc, src/sym_table.cc), plus
// consistency checks against str_hash() -- the two must always agree,
// since a hash-bucket pre-filter that disagrees with the equality check
// it guards would make case-insensitive lookups silently miss real
// matches.
#include "catch_amalgamated.hpp"
#include "utils.h"

TEST_CASE("unicode_strcasecmp matches identical ASCII strings", "[unicode_strcasecmp]") {
    REQUIRE(unicode_strcasecmp("hello", "hello") == 0);
}

TEST_CASE("unicode_strcasecmp is case-insensitive for ASCII", "[unicode_strcasecmp]") {
    REQUIRE(unicode_strcasecmp("Hello", "HELLO") == 0);
}

TEST_CASE("unicode_strcasecmp orders differing ASCII strings consistently with strcasecmp", "[unicode_strcasecmp]") {
    REQUIRE(unicode_strcasecmp("abc", "abd") < 0);
    REQUIRE(unicode_strcasecmp("abd", "abc") > 0);
}

TEST_CASE("unicode_strcasecmp detects a length difference", "[unicode_strcasecmp]") {
    REQUIRE(unicode_strcasecmp("abc", "ab") != 0);
    REQUIRE(unicode_strcasecmp("ab", "abc") != 0);
}

TEST_CASE("unicode_strcasecmp folds Unicode letters case-insensitively", "[unicode_strcasecmp][unicode]") {
    REQUIRE(unicode_strcasecmp("caf\xC3\xA9", "CAF\xC3\x89") == 0); // café vs CAFÉ
}

TEST_CASE("unicode_strcasecmp folds across differing byte lengths per character", "[unicode_strcasecmp][unicode]") {
    // Kelvin sign (3 bytes) vs ASCII 'k' (1 byte).
    REQUIRE(unicode_strcasecmp("\xE2\x84\xAA" "elvin", "kelvin") == 0);
}

TEST_CASE("unicode_strcasecmp distinguishes non-case-equivalent Unicode letters", "[unicode_strcasecmp][unicode]") {
    REQUIRE(unicode_strcasecmp("caf\xC3\xA9", "caf\xC3\xA8") != 0); // é vs è
}

TEST_CASE("str_hash agrees with unicode_strcasecmp for ASCII case-insensitivity", "[unicode_strcasecmp][str_hash]") {
    REQUIRE(str_hash("Hello") == str_hash("HELLO"));
    REQUIRE((unicode_strcasecmp("Hello", "HELLO") == 0));
}

TEST_CASE("str_hash agrees with unicode_strcasecmp for a Unicode letter", "[unicode_strcasecmp][str_hash]") {
    REQUIRE(str_hash("caf\xC3\xA9") == str_hash("CAF\xC3\x89"));
    REQUIRE((unicode_strcasecmp("caf\xC3\xA9", "CAF\xC3\x89") == 0));
}

TEST_CASE("str_hash agrees with unicode_strcasecmp across the Kelvin-sign byte-length mismatch", "[unicode_strcasecmp][str_hash]") {
    // The case this whole design exists for: two case-equivalent strings
    // whose *byte lengths* differ per character must still land in the
    // same hash bucket, or a case-insensitive lookup keyed by str_hash()
    // could miss a real match that unicode_strcasecmp() would confirm.
    REQUIRE(str_hash("\xE2\x84\xAA" "elvin") == str_hash("kelvin"));
    REQUIRE((unicode_strcasecmp("\xE2\x84\xAA" "elvin", "kelvin") == 0));
}
