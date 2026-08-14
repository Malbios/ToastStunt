require 'test_helper'

class TestStringOperations < Test::Unit::TestCase

  def test_that_index_finds_position_of_substring_in_a_string
    run_test_as('programmer') do
      assert_equal 0, index('foobar', 'x')
      assert_equal 2, index('foobar', 'o')
    end
  end

  def test_that_index_finds_position_of_substring_in_a_string_with_case_matters
    run_test_as('programmer') do
      assert_equal 0, index('foobar', 'O', 1)
      assert_equal 2, index('foobar', 'O', 0)
    end
  end

  def test_that_index_finds_position_of_substring_in_a_string_with_offset
    run_test_as('programmer') do
      assert_equal 0, index('foobar', 'o', 0, 3)
      assert_equal 1, index('foobar', 'o', 0, 1)
      assert_equal 2, index('foobar', 'o', 0, 0)
    end
  end

  def test_that_index_offset_cannot_be_negative
    run_test_as('programmer') do
      assert_equal E_INVARG, index('foobar', 'o', 0, -1)
    end
  end

  def test_that_index_offset_can_be_larger_than_the_source_string_length
    run_test_as('programmer') do
      assert_equal 0, index('foobar', 'o', 0, 10)
    end
  end

  def test_that_rindex_finds_position_of_substring_in_a_string
    run_test_as('programmer') do
      assert_equal 0, rindex('foobar', 'x')
      assert_equal 3, rindex('foobar', 'o')
    end
  end

  def test_that_rindex_finds_position_of_substring_in_a_string_with_case_matters
    run_test_as('programmer') do
      assert_equal 0, rindex('foobar', 'O', 1)
      assert_equal 3, rindex('foobar', 'O', 0)
    end
  end

  def test_that_rindex_finds_position_of_substring_in_a_string_with_offset
    run_test_as('programmer') do
      assert_equal 2, rindex('foobar', 'o', 0, -4)
      assert_equal 3, rindex('foobar', 'o', 0, -3)
      assert_equal 3, rindex('foobar', 'o', 0, 0)
    end
  end

  def test_that_rindex_offset_cannot_be_positive
    run_test_as('programmer') do
      assert_equal E_INVARG, rindex('foobar', 'o', 0, 1)
    end
  end

  def test_that_rindex_offset_can_be_larger_than_the_source_string_length
    run_test_as('programmer') do
      assert_equal 0, rindex('foobar', 'o', 0, -10)
    end
  end

  def test_that_strfindall_finds_all_positions_of_a_substring
    run_test_as('programmer') do
      assert_equal [2, 4, 6], strfindall('banana', 'a')
      assert_equal [], strfindall('banana', 'x')
    end
  end

  def test_that_strfindall_matches_are_non_overlapping
    run_test_as('programmer') do
      assert_equal [1, 3], strfindall('aaaa', 'aa')
    end
  end

  def test_that_strfindall_finds_all_positions_with_case_matters
    run_test_as('programmer') do
      assert_equal [], strfindall('foobar', 'O', 1)
      assert_equal [2, 3], strfindall('foobar', 'O', 0)
    end
  end

  # Positions are always absolute (relative to the start of `source`), even
  # when an offset is given to start the scan partway through -- unlike
  # index()/rindex(), whose single returned position is relative to the
  # offset itself. Returning absolute positions is far more useful for a
  # "find every occurrence" function, since callers naturally want to index
  # back into the original string with the results.
  def test_that_strfindall_positions_are_absolute_even_with_an_offset
    run_test_as('programmer') do
      assert_equal [4, 6], strfindall('banana', 'a', 0, 2)
    end
  end

  def test_that_strfindall_offset_cannot_be_negative
    run_test_as('programmer') do
      assert_equal E_INVARG, strfindall('foobar', 'o', 0, -1)
    end
  end

  def test_that_strfindall_rejects_an_empty_what_argument
    run_test_as('programmer') do
      assert_equal E_INVARG, strfindall('foobar', '')
    end
  end

  def test_that_strtr_replaces_characters
    run_test_as('programmer') do
      assert_equal 'fbboar', strtr('foobar', 'ob', 'bo')
      assert_equal 'fiibar', strtr('foobar', 'o', 'i')
      assert_equal 'foobar', strtr('foobar', '', '')
    end
  end

  def test_that_in_strtr_from_and_to_can_be_different_lengths
    run_test_as('programmer') do
      assert_equal 'fbbbar', strtr('foobar', 'o', 'bo')
      assert_equal 'fbbar', strtr('foobar', 'ob', 'b')
    end
  end

  def test_that_in_strtr_source_can_be_empty
    run_test_as('programmer') do
      assert_equal '', strtr('', 'x', 'y')
    end
  end

  def test_that_in_strtr_from_and_to_can_match_nothing
    run_test_as('programmer') do
      assert_equal 'foobar', strtr('foobar', 'x', 'y')
    end
  end

  def test_that_strtr_works_with_numbers
    run_test_as('programmer') do
      assert_equal '02a4B', strtr('12345', '135', '0aB')
      assert_equal '02a4B', strtr('12345', '135', '0aB', 1)
    end
  end

  def test_that_strtr_works_with_symbols
    run_test_as('programmer') do
      assert_equal '0@a$B', strtr('!@#$%', '!#%', '0aB')
      assert_equal '0@a$B', strtr('!@#$%', '!#%', '0aB', 1)
    end
  end

  def test_that_strtr_in_case_insensitive_mode_it_preserves_case
    run_test_as('programmer') do
      assert_equal 'FxXbar', strtr('FoObar', 'o', 'x', 0)
      assert_equal 'FxXbar', strtr('FoObar', 'O', 'X', 0)
    end
  end

  def test_that_strtr_in_case_sensitive_mode_it_ignores_case
    run_test_as('programmer') do
      assert_equal 'FxObar', strtr('FoObar', 'o', 'x', 1)
      assert_equal 'FoXbar', strtr('FoObar', 'O', 'X', 1)
    end
  end

  def test_a_few_more_interesting_strtr_cases
    run_test_as('programmer') do
      assert_equal 'BbB', strtr('5xX', '135x', '0aBB', 0)
      assert_equal 'BBX', strtr('5xX', '135x', '0aBB', 1)
      assert_equal '4444', strtr('xXxX', 'xXxX', '1234', 0)
      assert_equal '3434', strtr('xXxX', 'xXxX', '1234', 1)
      assert_equal '11', strtr('xX', 'x', '1', 0)
      assert_equal '1X', strtr('xX', 'x', '1', 1)
      assert_equal 'X', strtr('1', '1', 'X', 0)
      assert_equal 'X', strtr('1', '1', 'X', 1)
    end
  end

  def test_that_a_variety_of_fuzzy_inputs_do_not_break_strtr
    run_test_as('wizard') do
      with_mutating_binary_string("012345678901234567890123456789") do |g|
        100.times do
          s = g.next
          server_log s
          v = strtr(s[0..9], s[10..19], s[20..29])
          assert v.class == String
        end
      end
    end
  end

  def test_that_strtr_does_not_corrupt_high_bytes
    run_test_as('programmer') do
      # Regression test: strtr()'s translation table used to be sized for
      # ASCII only (128 entries) and indexed with a signed char, so any
      # source byte >= 0x80 (including every UTF-8 continuation/lead byte)
      # triggered an out-of-bounds read (and, for `from` bytes >= 0x80, an
      # out-of-bounds write) instead of passing through untouched.
      #
      # 0xFF is excluded: it's the telnet IAC byte, and sending it literally
      # over the wire requires protocol-level doubling (IAC IAC) that this
      # test's plain command()-based helper doesn't do -- a separate,
      # pre-existing telnet-escaping gap unrelated to this fix.
      (0x80..0xFE).each do |b|
        s = [b].pack('C').force_encoding('ASCII-8BIT')
        assert_equal s, strtr(s, 'xyz', 'XYZ')
      end
    end
  end

  def test_that_strtr_can_remap_high_bytes
    run_test_as('programmer') do
      from = [0x80, 0xFE].pack('C*').force_encoding('ASCII-8BIT')
      to = [0x41, 0x42].pack('C*').force_encoding('ASCII-8BIT')
      source = [0x80, 0x81, 0xFE].pack('C*').force_encoding('ASCII-8BIT')
      expected = [0x41, 0x81, 0x42].pack('C*').force_encoding('ASCII-8BIT')
      assert_equal expected, strtr(source, from, to)
    end
  end

  def test_that_multibyte_utf8_survives_the_telnet_connection
    run_test_as('programmer') do
      # Regression test: process_telnet_byte() used to gate every incoming
      # byte through isgraph(), which runs in the server's ("C") locale and
      # is false for every byte >= 0x80 -- every byte of a multi-byte UTF-8
      # character was silently dropped before it ever reached a MOO string.
      # This is a direct exercise of that exact code path: every eval sent
      # over this connection is ordinary telnet input.
      cafe = "caf" + [0xC3, 0xA9].pack('C*').force_encoding('ASCII-8BIT')
      assert_equal cafe, simplify(command(%Q|; return "#{cafe}";|))
    end
  end

  def test_that_a_single_backspace_erases_a_whole_multibyte_character
    run_test_as('programmer') do
      # Regression test: INPUT_APPLY_BACKSPACE's stream_delete_char() call
      # used to remove exactly one byte. A UTF-8 character can be up to 4
      # bytes, so a single backspace right after typing one used to leave a
      # truncated, invalid partial sequence in the input buffer instead of
      # deleting the whole character. Send "caf" + <e-acute, 2 bytes> +
      # <backspace> + "1"; if the fix works, one backspace removes the
      # whole 2-byte character, leaving "caf1" -- not "caf" plus a stray
      # lead byte plus "1".
      line = %Q|; return "caf| +
             [0xC3, 0xA9].pack('C*').force_encoding('ASCII-8BIT') +
             [0x08].pack('C').force_encoding('ASCII-8BIT') +
             %Q|1";|
      assert_equal 'caf1', simplify(command(line))
    end
  end

  def test_that_backspace_after_invalid_continuation_bytes_erases_only_one_byte
    run_test_as('programmer') do
      # Regression test: the backspace fix above used to keep deleting
      # bytes as long as each REMOVED byte was in the continuation-byte
      # range (0x80-0xBF), with no check that they actually formed a
      # valid multi-byte character together -- so a run of bytes from a
      # non-UTF-8 legacy client that happen to fall in that range (no
      # real lead byte before them) had more than one "character" erased
      # by a single backspace. Send "caf" + three continuation-range
      # bytes that don't form a valid sequence (no lead byte precedes
      # them) + <backspace> + "1"; a correct fix erases only the last of
      # the three.
      line = %Q|; return "caf| +
             [0x81, 0x82, 0x83].pack('C*').force_encoding('ASCII-8BIT') +
             [0x08].pack('C').force_encoding('ASCII-8BIT') +
             %Q|1";|
      expected = 'caf'.b + [0x81, 0x82].pack('C*').force_encoding('ASCII-8BIT') + '1'.b
      assert_equal expected, simplify(command(line))
    end
  end

  def test_that_strtr_still_lets_a_later_from_entry_win_over_an_earlier_duplicate
    run_test_as('programmer') do
      # Regression test for the O(n+m) rewrite of strtr()'s from/to
      # lookup (previously a per-source-character linear rescan of
      # `from`): when `from` names the same character more than once,
      # the LAST entry must still win, both for exact/case-sensitive
      # matching and for the ASCII case-insensitive fold path.
      assert_equal 'y', strtr('x', 'xx', 'zy', 1)
      assert_equal 'Y', strtr('A', 'aA', 'xy')
    end
  end

  def test_that_pad_defaults_to_padding_on_the_right_with_a_space
    run_test_as('programmer') do
      assert_equal 'ab   ', simplify(command('; return pad("ab", 5);'))
    end
  end

  def test_that_pad_can_pad_on_the_left
    run_test_as('programmer') do
      assert_equal '   ab', simplify(command('; return pad("ab", 5, " ", "left");'))
    end
  end

  def test_that_pad_can_center_with_both
    run_test_as('programmer') do
      assert_equal '--ab--', simplify(command('; return pad("ab", 6, "-", "both");'))
      assert_equal '-ab--', simplify(command('; return pad("ab", 5, "-", "both");'))
    end
  end

  def test_that_pad_accepts_a_custom_fill_character
    run_test_as('programmer') do
      assert_equal 'ab***', simplify(command('; return pad("ab", 5, "*");'))
    end
  end

  def test_that_pad_only_uses_the_first_character_of_a_multi_character_fill
    run_test_as('programmer') do
      assert_equal 'abxxx', simplify(command('; return pad("ab", 5, "xyz");'))
    end
  end

  def test_that_pad_falls_back_to_a_space_for_an_empty_fill_string
    run_test_as('programmer') do
      assert_equal 'ab   ', simplify(command('; return pad("ab", 5, "");'))
    end
  end

  def test_that_pad_is_a_no_op_when_width_is_already_met_or_exceeded
    run_test_as('programmer') do
      assert_equal 'abcde', simplify(command('; return pad("abcde", 5);'))
      assert_equal 'abcdef', simplify(command('; return pad("abcdef", 3);'))
      assert_equal 'ab', simplify(command('; return pad("ab", -5);'))
    end
  end

  def test_that_pad_rejects_an_unrecognized_side
    run_test_as('programmer') do
      assert_equal E_INVARG, simplify(command('; return pad("ab", 5, " ", "up");'))
    end
  end

  def test_that_strtrim_removes_leading_and_trailing_spaces_by_default
    run_test_as('programmer') do
      assert_equal 'hi', simplify(command('; return strtrim("  hi  ");'))
      assert_equal 'hi', simplify(command('; return strtrim("hi");'))
    end
  end

  def test_that_strtrim_accepts_a_custom_trim_character
    run_test_as('programmer') do
      assert_equal 'hi', simplify(command('; return strtrim("xxhixx", "x");'))
    end
  end

  def test_that_strtriml_only_trims_the_left_side
    run_test_as('programmer') do
      assert_equal 'hi  ', simplify(command('; return strtriml("  hi  ");'))
      assert_equal 'hixx', simplify(command('; return strtriml("xxhixx", "x");'))
    end
  end

  def test_that_strtrimr_only_trims_the_right_side
    run_test_as('programmer') do
      assert_equal '  hi', simplify(command('; return strtrimr("  hi  ");'))
      assert_equal 'xxhi', simplify(command('; return strtrimr("xxhixx", "x");'))
    end
  end

  def test_that_strtrim_variants_are_no_ops_when_there_is_nothing_to_trim
    run_test_as('programmer') do
      assert_equal '', simplify(command('; return strtrim("");'))
      assert_equal '', simplify(command('; return strtrim("   ");'))
    end
  end

  def test_that_strupper_uppercases_a_string
    run_test_as('programmer') do
      assert_equal 'HELLO WORLD', simplify(command('; return strupper("Hello World");'))
      assert_equal '123!@#', simplify(command('; return strupper("123!@#");'))
    end
  end

  def test_that_strlower_lowercases_a_string
    run_test_as('programmer') do
      assert_equal 'hello world', simplify(command('; return strlower("Hello World");'))
      assert_equal '123!@#', simplify(command('; return strlower("123!@#");'))
    end
  end

  def test_that_parse_ordinal_recognizes_numeric_ordinals
    run_test_as('programmer') do
      assert_equal [2, "apple"], simplify(command('; return parse_ordinal("2nd apple");'))
      assert_equal [21, "apples"], simplify(command('; return parse_ordinal("21st apples");'))
      assert_equal [1, ""], simplify(command('; return parse_ordinal("1st");'))
    end
  end

  def test_that_parse_ordinal_recognizes_word_ordinals
    run_test_as('programmer') do
      assert_equal [3, "apple"], simplify(command('; return parse_ordinal("third apple");'))
      assert_equal [20, "apple"], simplify(command('; return parse_ordinal("twentieth apple");'))
      assert_equal [23, "apple"], simplify(command('; return parse_ordinal("twenty-third apple");'))
      assert_equal [99, "apple"], simplify(command('; return parse_ordinal("ninety-ninth apple");'))
    end
  end

  def test_that_parse_ordinal_returns_zero_and_the_input_unchanged_when_there_is_no_leading_ordinal
    run_test_as('programmer') do
      assert_equal [0, "apple"], simplify(command('; return parse_ordinal("apple");'))
      assert_equal [0, ""], simplify(command('; return parse_ordinal("");'))
    end
  end

  # Regression tests mirroring the emptylist/emptymap ones in
  # test_collection_improvements.rb/test_map.rb: the shared empty string
  # singleton's refcount is pinned at creation rather than growing on every
  # copy/creation, to avoid an eventual 32-bit overflow. These can't
  # deterministically force the exact vulnerable refcount state (the same
  # reason the original bug was hard to find at all), but they verify a
  # fresh `""` is never affected by unrelated code growing, copying, or
  # discarding another `""`.

  def test_that_growing_one_fresh_empty_string_does_not_affect_another
    run_test_as('programmer') do
      simplify(command(%Q|; x = ""; y = x + "v"; return 1;|))
      assert_equal "", simplify(command(%Q|; return "";|))
      assert_equal 0, simplify(command(%Q|; return length("");|))
    end
  end

  def test_that_copying_one_fresh_empty_string_does_not_affect_another
    run_test_as('programmer') do
      simplify(command(%Q|; x = ""; y = x; z = x; return 1;|))
      assert_equal "", simplify(command(%Q|; return "";|))
      assert_equal 0, simplify(command(%Q|; return length("");|))
    end
  end

  def test_that_discarding_a_fresh_empty_string_does_not_affect_another
    run_test_as('programmer') do
      simplify(command(%Q|; for i in [1..20]; x = ""; endfor; return 1;|))
      assert_equal "", simplify(command(%Q|; return "";|))
      assert_equal 0, simplify(command(%Q|; return length("");|))
    end
  end

end
