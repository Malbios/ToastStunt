require 'test_helper'

# Regression tests for full UTF-8 codepoint-indexed string semantics
# (length(), indexing, and every string builtin now counts and addresses
# characters, not bytes). See docs/ChangeLog.md and the "Unicode support"
# design notes for the invariants these rely on:
#
#   - length()/indexing operate on Unicode codepoints, unconditionally --
#     there is no server option gating this.
#   - Each invalid/stray byte counts as its own one-byte "character", so a
#     string that isn't valid UTF-8 behaves exactly as it always did.
#   - "café" is used throughout as the canonical example: 4 codepoints
#     (c, a, f, é), but 5 bytes, since é is U+00E9 and encodes as the two
#     bytes 0xC3 0xA9.
#
# Expected values that contain non-ASCII characters are built byte-by-byte
# with String#+ (never with "#{}" interpolation) and tagged ASCII-8BIT, to
# match the encoding the test connection's raw socket reads come back as;
# mixing that with string interpolation against a UTF-8-encoded literal in
# this source file is exactly the kind of mismatch that silently produces
# two byte-identical strings Ruby still considers unequal. Command text
# sent *to* the server doesn't have this problem -- plain UTF-8 literals
# from this source file go out over the socket untouched either way -- so
# command strings below freely use "#{}" interpolation.
class TestUnicodeStrings < Test::Unit::TestCase

  EACUTE = [0xC3, 0xA9].pack('C*').force_encoding('ASCII-8BIT')   # 'é', U+00E9, 2 bytes
  SNOWMAN = [0xE2, 0x98, 0x83].pack('C*').force_encoding('ASCII-8BIT')          # U+2603, 3 bytes
  GRINNING_FACE = [0xF0, 0x9F, 0x98, 0x80].pack('C*').force_encoding('ASCII-8BIT') # U+1F600, 4 bytes
  CAFE = 'caf'.b + EACUTE

  def test_that_length_counts_codepoints_not_bytes
    run_test_as('programmer') do
      assert_equal 4, length(CAFE)
      ascii_bytes = simplify(command('; return value_bytes("cafe");'))
      cafe_bytes = simplify(command(%Q|; return value_bytes("#{CAFE}");|))
      # "café" has exactly one more byte than "cafe" (é is 2 bytes, e is 1),
      # even though both are reported as 4 characters long.
      assert_equal ascii_bytes + 1, cafe_bytes
    end
  end

  def test_that_length_counts_a_wider_multibyte_character_as_one
    run_test_as('programmer') do
      assert_equal 1, length(SNOWMAN)
      assert_equal 1, length(GRINNING_FACE)
    end
  end

  def test_that_single_character_read_addresses_codepoints
    run_test_as('programmer') do
      assert_equal 'c', simplify(command(%Q|; return "#{CAFE}"[1];|))
      assert_equal 'a', simplify(command(%Q|; return "#{CAFE}"[2];|))
      assert_equal 'f', simplify(command(%Q|; return "#{CAFE}"[3];|))
      assert_equal EACUTE, simplify(command(%Q|; return "#{CAFE}"[4];|))
    end
  end

  def test_that_single_character_read_out_of_range_is_e_range
    run_test_as('programmer') do
      # "café" is 4 characters (not 5 bytes) -- index 5 is out of range.
      assert_equal E_RANGE, simplify(command(%Q|; return "#{CAFE}"[5];|))
    end
  end

  def test_that_range_read_addresses_codepoints
    run_test_as('programmer') do
      assert_equal 'af'.b + EACUTE, simplify(command(%Q|; return "#{CAFE}"[2..4];|))
      assert_equal CAFE, simplify(command(%Q|; return "#{CAFE}"[1..4];|))
    end
  end

  def test_that_single_character_write_replaces_one_codepoint_with_another
    run_test_as('programmer') do
      # Replace the multi-byte 'é' (index 4) with a single ASCII 'e'.
      assert_equal 'cafe', simplify(command(%Q|; s = "#{CAFE}"; s[4] = "e"; return s;|))
      # Replace a single ASCII character with a multi-byte one.
      assert_equal 'caf'.b + EACUTE + 's'.b,
        simplify(command(%Q|; s = "#{CAFE}s"; s[4] = "#{EACUTE}"; return s;|))
    end
  end

  def test_that_single_character_write_requires_exactly_one_character
    run_test_as('programmer') do
      assert_equal E_INVARG, simplify(command(%Q|; s = "#{CAFE}"; return s[1] = "";|))
      assert_equal E_INVARG, simplify(command(%Q|; s = "#{CAFE}"; return s[1] = "xy";|))
    end
  end

  def test_that_range_write_splices_across_multibyte_boundaries
    run_test_as('programmer') do
      assert_equal 'chai', simplify(command(%Q|; s = "#{CAFE}"; s[2..4] = "hai"; return s;|))
      assert_equal 'chai'.b + EACUTE,
        simplify(command(%Q|; s = "#{CAFE}"; s[2..4] = "hai#{EACUTE}"; return s;|))
    end
  end

  def test_that_index_returns_a_character_position_past_a_multibyte_character
    run_test_as('programmer') do
      # "café bar": c(1) a(2) f(3) é(4) space(5) b(6) a(7) r(8)
      assert_equal 6, index("#{CAFE} bar", 'bar')
    end
  end

  def test_that_rindex_returns_a_character_position_past_a_multibyte_character
    run_test_as('programmer') do
      assert_equal 6, rindex("#{CAFE} bar", 'bar')
    end
  end

  def test_that_strfindall_returns_character_positions_past_a_multibyte_character
    run_test_as('programmer') do
      # "café café": positions of the literal "af" substrings, by character.
      assert_equal [2, 7], strfindall("#{CAFE} #{CAFE}", 'af')
    end
  end

  def test_that_explode_treats_a_multibyte_delimiter_as_one_character
    run_test_as('programmer') do
      # explode() has always used only the first character of its delimiter
      # argument; that "first character" is now a whole codepoint, not a byte.
      assert_equal ['x', 'y'], simplify(command(%Q|; return explode("x#{SNOWMAN}y", "#{SNOWMAN}");|))
    end
  end

  def test_that_reverse_reverses_whole_characters_not_bytes
    run_test_as('programmer') do
      assert_equal EACUTE + 'fac'.b, simplify(command(%Q|; return reverse("#{CAFE}");|))
      # If reverse() were still byte-wise, the two bytes of the snowman
      # would come out swapped/mangled instead of the character surviving
      # intact.
      assert_equal SNOWMAN + 'yx'.b, simplify(command(%Q|; return reverse("xy#{SNOWMAN}");|))
    end
  end

  def test_that_pad_treats_a_multibyte_fill_character_as_one_unit
    run_test_as('programmer') do
      assert_equal 'x'.b + SNOWMAN + SNOWMAN, simplify(command(%Q|; return pad("x", 3, "#{SNOWMAN}");|))
    end
  end

  def test_that_strtrim_variants_treat_a_multibyte_trim_character_as_one_unit
    run_test_as('programmer') do
      assert_equal 'hi', simplify(command(%Q|; return strtrim("#{SNOWMAN}hi#{SNOWMAN}", "#{SNOWMAN}");|))
      assert_equal 'hi'.b + SNOWMAN, simplify(command(%Q|; return strtriml("#{SNOWMAN}hi#{SNOWMAN}", "#{SNOWMAN}");|))
      assert_equal SNOWMAN + 'hi'.b, simplify(command(%Q|; return strtrimr("#{SNOWMAN}hi#{SNOWMAN}", "#{SNOWMAN}");|))
    end
  end

  def test_that_strtr_remaps_whole_multibyte_characters
    run_test_as('programmer') do
      assert_equal 'caf'.b + SNOWMAN, strtr(CAFE, EACUTE, SNOWMAN)
      assert_equal 'cafe', strtr(CAFE, EACUTE, 'e')
    end
  end

  def test_that_match_returns_character_positions_past_multibyte_content
    run_test_as('programmer') do
      result = simplify(command(%Q|; return match("#{CAFE} bar", "bar");|))
      # {start, end, replacements, subject} -- start/end are 1-indexed
      # character positions, not byte offsets.
      assert_equal 6, result[0]
      assert_equal 8, result[1]
    end
  end

  def test_that_substitute_uses_matchs_character_positions
    run_test_as('programmer') do
      result = simplify(command(%Q|; return substitute("%0", match("#{CAFE} bar", "bar"));|))
      assert_equal 'bar', result
    end
  end

  def test_that_pcre_match_returns_character_positions_past_multibyte_content
    run_test_as('programmer') do
      # "café bar": 'a' occurs at character position 2 (inside "café") and
      # position 7 (inside "bar", past the multi-byte 'é'). Matching twice
      # (rather than once) also sidesteps a pre-existing quirk in this test
      # harness's general_expression_parser.rb, where a MOO list containing
      # exactly one map is parsed as that bare map instead of a one-element
      # array.
      result = simplify(command(%Q|; return pcre_match("#{CAFE} bar", "a");|))
      assert_equal [2, 2], result[0]['0']['position']
      assert_equal [7, 7], result[1]['0']['position']
    end
  end

  def test_that_pcre_match_matches_unicode_letters_via_property_classes
    run_test_as('programmer') do
      # Requires PCRE2_UCP: \p{L} must match 'é' as a single Unicode letter,
      # not as two raw continuation/lead bytes. Two letters (rather than
      # one) sidesteps the single-element-list-of-maps harness quirk noted
      # above.
      result = simplify(command(%Q|; return pcre_match("#{EACUTE}#{EACUTE}", "\\\\p{L}");|))
      assert_equal EACUTE, result[0]['0']['match']
      assert_equal [1, 1], result[0]['0']['position']
      assert_equal EACUTE, result[1]['0']['match']
      assert_equal [2, 2], result[1]['0']['position']
    end
  end

  def test_that_pcre_replace_preserves_multibyte_replacement_text
    run_test_as('programmer') do
      assert_equal CAFE + ' bar'.b, simplify(command(%Q|; return pcre_replace("cafe bar", "s/cafe/#{CAFE}/");|))
    end
  end

  def test_that_pcre_match_raises_e_invutf8_on_an_invalid_subject
    run_test_as('programmer') do
      # A lone UTF-8 continuation byte (0x80) is never valid on its own.
      # Send it via chr() (a raw-byte builtin already covered by its own
      # tests) rather than embedding it in the Ruby source, so it isn't
      # mistaken for malformed test code.
      result = simplify(command('; return pcre_match(chr(128), ".");'))
      assert_kind_of MooErr, result
      assert_equal E_INVUTF8, result
    end
  end

  def test_that_pcre_replace_raises_e_invutf8_on_an_invalid_subject
    run_test_as('programmer') do
      result = simplify(command('; return pcre_replace(chr(128), "s/./x/");'))
      assert_kind_of MooErr, result
      assert_equal E_INVUTF8, result
    end
  end

  def test_that_e_invutf8_round_trips_through_toerr_and_error_name
    run_test_as('programmer') do
      assert_equal E_INVUTF8, simplify(command('; return toerr(19);'))
      assert_equal 'Invalid UTF-8 string', simplify(command('; return tostr(E_INVUTF8);'))
    end
  end

  def test_that_an_invalid_byte_counts_as_a_single_character
    run_test_as('programmer') do
      # chr() allows raw bytes >= 128 for any player; 0x80 alone is not
      # valid UTF-8 (a lone continuation byte), so under the invalid-byte
      # policy it counts as its own one-character, one-byte "character"
      # rather than desyncing length() from the rest of the string.
      assert_equal 3, simplify(command('; return length("a" + chr(128) + "b");'))
    end
  end

  def test_that_unichr_builds_a_string_from_a_codepoint
    run_test_as('programmer') do
      assert_equal EACUTE, simplify(command('; return unichr(233);'))
      assert_equal SNOWMAN, simplify(command('; return unichr(9731);'))
    end
  end

  def test_that_unichr_accepts_multiple_codepoints
    run_test_as('programmer') do
      assert_equal EACUTE + SNOWMAN, simplify(command('; return unichr(233, 9731);'))
    end
  end

  def test_that_unichr_round_trips_through_length_and_value_bytes
    run_test_as('programmer') do
      assert_equal 1, simplify(command('; return length(unichr(128512));'))
      ascii_bytes = simplify(command('; return value_bytes("x");'))
      emoji_bytes = simplify(command('; return value_bytes(unichr(128512));'))
      # A 4-byte codepoint takes 3 more bytes than a 1-byte ASCII character.
      assert_equal ascii_bytes + 3, emoji_bytes
    end
  end

  def test_that_unichr_round_trips_through_toliteral
    run_test_as('programmer') do
      assert_equal '"'.b + EACUTE + '"'.b, simplify(command('; return toliteral(unichr(233));'))
    end
  end

  def test_that_unichr_rejects_a_lone_surrogate
    run_test_as('programmer') do
      assert_equal E_INVARG, simplify(command('; return unichr(55296);'))
    end
  end

  def test_that_unichr_rejects_a_codepoint_beyond_the_unicode_range
    run_test_as('programmer') do
      assert_equal E_INVARG, simplify(command('; return unichr(1114112);'))
    end
  end

  def test_that_unichr_rejects_control_codepoints_for_non_wizards
    run_test_as('programmer') do
      assert_equal E_INVARG, simplify(command('; return unichr(7);'))
    end
  end

  # Regression coverage for the O(1)-amortized cursor cache behind
  # codepoint-index <-> byte-offset conversion (src/utf8.cc): a verb that
  # walks a string character-by-character in increasing index order is
  # the pattern that cache exists for. This is a correctness check, not
  # a timing assertion (wall-clock is unreliable in CI) -- it just proves
  # sequential single-character reads over a long, mixed-width string
  # (1/2/3/4-byte characters) reconstruct it exactly, entirely
  # server-side so no non-ASCII value has to round-trip through Ruby.
  def test_that_sequential_character_indexing_reconstructs_a_long_mixed_multibyte_string
    run_test_as('programmer') do
      pattern = "aé中\u{1F600}b"
      cmd = %Q|; pattern = "#{pattern}"; s = ""; for i in [1..400] s = s + pattern; endfor result = ""; for i in [1..length(s)] result = result + s[i]; endfor return result == s;|
      assert_equal 1, simplify(command(cmd))
    end
  end

  # Regression tests for a pre-merge review pass on this branch: several
  # spots that convert between byte offsets and codepoint indices, or that
  # do Unicode-aware case-insensitive comparison, were found inconsistent
  # with the rest of this same feature.

  def test_that_in_operator_matches_index_on_a_string_with_preceding_multibyte_content
    run_test_as('programmer') do
      # `index()` was migrated to codepoint indices; the `in` operator
      # (OP_IN) used the same underlying strindex() but was left
      # returning a raw byte position. "café bar": 'b' is the 6th
      # codepoint (c,a,f,é,space,b) but the 7th byte (é is 2 bytes).
      s = CAFE + ' bar'.b
      assert_equal 6, simplify(command(%Q|; return "b" in "#{s}";|))
      assert_equal 6, index(s, 'b')
    end
  end

  def test_that_pcre_match_returns_the_documented_sentinel_for_a_non_participating_named_group
    run_test_as('programmer') do
      # result_indices() fed PCRE2_UNSET straight into the codepoint
      # converter without checking for it first, turning a
      # non-participating group's documented {0,-1} sentinel into a
      # bogus in-range position. Matching twice (rather than once, which
      # only one of "a"/"b" alone would do) sidesteps the harness's
      # pre-existing single-element-list-of-maps collapse quirk noted
      # above, and also covers non-participation in both directions.
      result = simplify(command('; return pcre_match("ab", "(?<x>a)|(?<y>b)");'))
      assert_equal [1, 1], result[0]['x']['position']
      assert_equal 'a', result[0]['x']['match']
      assert_equal [0, -1], result[0]['y']['position']
      assert_equal '', result[0]['y']['match']
      assert_equal [0, -1], result[1]['x']['position']
      assert_equal '', result[1]['x']['match']
      assert_equal [2, 2], result[1]['y']['position']
      assert_equal 'b', result[1]['y']['match']
    end
  end

  def test_that_pcre_replace_blanks_dangerous_unicode_format_characters
    run_test_as('programmer') do
      # The sanitizer's isprint() pass only applies byte-wise, to
      # single-byte spans; a well-formed multi-byte sequence passed
      # through untouched even when it decodes to a dangerous invisible/
      # directionality-override character (the "Trojan Source" class).
      rtl_override = [0xE2, 0x80, 0xAE].pack('C*').force_encoding('ASCII-8BIT') # U+202E RIGHT-TO-LEFT OVERRIDE
      result = simplify(command(%Q|; return pcre_replace("x", "s/x/#{rtl_override}/");|))
      assert_equal '   ', result
    end
  end

  def test_that_equality_and_ordering_are_unicode_case_fold_aware
    run_test_as('programmer') do
      # str_hash()/verb+property dispatch were made Unicode-case-fold
      # aware; equality()/compare() (backing the `in` operator on lists
      # and the `<`/`>` operators) were left using plain ASCII
      # strcasecmp() -- inconsistent, and equality()'s byte-length
      # fast-reject is actively wrong for fold-equivalent strings of
      # different byte length (the Kelvin sign, 3 bytes, folds to ASCII
      # 'k', 1 byte).
      kelvin = [0xE2, 0x84, 0xAA].pack('C*').force_encoding('ASCII-8BIT') # U+212A KELVIN SIGN
      assert_equal 1, simplify(command(%Q|; return "#{kelvin}" in {"k", "x", "y"};|))
      assert_equal 0, simplify(command(%Q|; return "#{kelvin}" < "k";|))
      assert_equal 0, simplify(command(%Q|; return "#{kelvin}" > "k";|))
    end
  end

  # Regression tests for a second pre-merge review pass on this branch.

  def test_that_match_and_substitute_handle_a_zero_width_match_at_the_start
    run_test_as('programmer') do
      # do_match() converted regs[0].end's byte offset to a codepoint
      # index by testing regs[0].start > 0 instead of regs[0].end > 0.
      # For a zero-width match at the very start of the subject (pattern
      # "^"), regs[0].start=1 but regs[0].end=0, so the wrong guard took
      # the conversion branch and computed (size_t) 0 - 1, underflowing
      # to a bogus "past end of string" position instead of passing 0
      # through unchanged. substitute() then saw start(1) <= end(bogus)
      # and copied the entire rest of the subject into %0 instead of
      # nothing.
      result = simplify(command('; return match("abc", "^");'))
      assert_equal 1, result[0]
      assert_equal 0, result[1]
      assert_equal '', simplify(command('; return substitute("%0", match("abc", "^"));'))
    end
  end

  def test_that_index_rindex_and_strfindall_are_unicode_case_fold_aware
    run_test_as('programmer') do
      # index()/rindex()/strfindall() (via strindex()/strrindex()) still
      # used plain libc strncasecmp() for case-insensitive search,
      # inconsistent with ==/</> now being Unicode-fold-aware. A
      # fold-equivalent match can consume a different number of bytes
      # than the needle itself (the Kelvin sign, 3 bytes, folds to ASCII
      # 'k', 1 byte), so this also exercises that strfindall() advances
      # past a match using the actual matched length, not strlen(what).
      kelvin = [0xE2, 0x84, 0xAA].pack('C*').force_encoding('ASCII-8BIT') # U+212A KELVIN SIGN
      subject = 'x'.b + kelvin + 'y'.b + kelvin + 'z'.b
      assert_equal 2, simplify(command(%Q|; return index("#{subject}", "k", 0);|))
      assert_equal 0, simplify(command(%Q|; return index("#{subject}", "k", 1);|))
      assert_equal 4, simplify(command(%Q|; return rindex("#{subject}", "k", 0);|))
      assert_equal [2, 4], simplify(command(%Q|; return strfindall("#{subject}", "k", 0);|))
    end
  end

  def test_that_strsub_is_unicode_case_fold_aware
    run_test_as('programmer') do
      kelvin = [0xE2, 0x84, 0xAA].pack('C*').force_encoding('ASCII-8BIT') # U+212A KELVIN SIGN
      subject = 'x'.b + kelvin + 'y'.b
      assert_equal 'xKy', simplify(command(%Q|; return strsub("#{subject}", "k", "K", 0);|))
    end
  end

  def test_that_sort_is_unicode_case_fold_aware
    run_test_as('programmer') do
      # sort()'s case-insensitive (non-natural) string comparator still
      # called plain libc strcasecmp() directly, so it could order
      # strings inconsistently with what `<`/`>` (now Unicode-fold-aware)
      # say about the same pair. The Kelvin sign folds to 'k' (between
      # 'j' and 'z' alphabetically), but its raw lead byte (0xE2) sorts
      # after every ASCII letter byte-wise -- a plain strcasecmp put it
      # last; a fold-aware comparator puts it between "j" and "z".
      kelvin = [0xE2, 0x84, 0xAA].pack('C*').force_encoding('ASCII-8BIT') # U+212A KELVIN SIGN
      result = simplify(command(%Q|; return sort({"z", "#{kelvin}", "j"});|))
      assert_equal ['j', kelvin, 'z'], result
    end
  end

end
