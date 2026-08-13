require 'test_helper'

# Regression tests for Unicode support in MOOcode *identifiers* -- local
# variable names, and static obj.name/obj:name(...) property/verb syntax --
# on top of the Phase 2 work in test_unicode_strings.rb that made string
# *values* UTF-8-aware. See docs/ChangeLog.md and the "Unicode support"
# kanban card for the design notes this relies on:
#
#   - Identifier characters follow real Unicode XID_Start/XID_Continue
#     properties (src/unicode_tables.cc, generated from the Unicode
#     Character Database), not a loose "any non-ASCII byte is fine" rule.
#     A letter like 'é' can start an identifier; a symbol like '☃' cannot.
#   - obj.(expr)/obj:(expr)(args)/add_property()/add_verb() already
#     accepted arbitrary UTF-8 names before this -- what's new is *static*
#     syntax (obj.name, obj:name(...), bare variable assignment) and the
#     unparser printing such names back in that bare form instead of the
#     parenthesized dynamic form.
#
# As in test_unicode_strings.rb, expected values containing non-ASCII
# bytes are built with String#+ and tagged ASCII-8BIT (never via "#{}"
# interpolation), to match the encoding raw socket reads come back as.
class TestUnicodeIdentifiers < Test::Unit::TestCase

  EACUTE = [0xC3, 0xA9].pack('C*').force_encoding('ASCII-8BIT')      # 'é', U+00E9, 2 bytes
  EACUTE_UPPER = [0xC3, 0x89].pack('C*').force_encoding('ASCII-8BIT') # 'É', U+00C9, 2 bytes
  CAFE = 'caf'.b + EACUTE
  CAFE_UPPER = 'CAF'.b + EACUTE_UPPER
  KELVIN = [0xE2, 0x84, 0xAA].pack('C*').force_encoding('ASCII-8BIT') # U+212A KELVIN SIGN, case-folds to ASCII 'k'
  SNOWMAN = [0xE2, 0x98, 0x83].pack('C*').force_encoding('ASCII-8BIT') # U+2603, not a letter

  def test_that_a_unicode_local_variable_works_in_static_syntax
    run_test_as('programmer') do
      assert_equal 5, simplify(command(%Q|; #{CAFE} = 5; return #{CAFE};|))
    end
  end

  def test_that_a_unicode_identifier_can_mix_a_letter_start_with_an_ascii_digit_continuation
    run_test_as('programmer') do
      assert_equal 9, simplify(command(%Q|; #{CAFE}2 = 9; return #{CAFE}2;|))
    end
  end

  def test_that_static_property_syntax_accepts_a_unicode_property_name
    run_test_as('wizard') do
      o = create(NOTHING)
      add_property(o, CAFE, 'hi', [player, ''])
      # Read it back via *static* obj.name syntax, not the dynamic
      # obj.(expr) form -- this is the part that needed lexer support.
      assert_equal 'hi', simplify(command(%Q|; return #{obj_ref(o)}.#{CAFE};|))
    end
  end

  def test_that_static_property_write_syntax_accepts_a_unicode_property_name
    run_test_as('wizard') do
      o = create(NOTHING)
      add_property(o, CAFE, 'hi', [player, ''])
      assert_equal 'bye', simplify(command(%Q|; #{obj_ref(o)}.#{CAFE} = "bye"; return #{obj_ref(o)}.#{CAFE};|))
    end
  end

  def test_that_static_verb_call_syntax_accepts_a_unicode_verb_name
    run_test_as('wizard') do
      o = create(NOTHING)
      add_verb(o, [player, 'rxd', CAFE], ['this', 'none', 'this'])
      set_verb_code(o, CAFE) do |vc|
        vc << 'return 42;'
      end
      assert_equal 42, simplify(command(%Q|; return #{obj_ref(o)}:#{CAFE}();|))
    end
  end

  def test_that_verb_code_unparses_a_unicode_property_reference_as_bare_syntax
    run_test_as('wizard') do
      o = create(NOTHING)
      add_property(o, CAFE, 1, [player, ''])
      add_verb(o, [player, 'rxd', 'reader'], ['this', 'none', 'this'])
      set_verb_code(o, 'reader') do |vc|
        vc << %Q|return #{obj_ref(o)}.#{CAFE};|
      end
      # verb_code() returns a bare String when the body is a single line,
      # or an Array of lines otherwise -- normalize to an Array either way.
      source = Array(verb_code(o, 'reader'))
      # Must print the bare obj.café form, not the parenthesized
      # obj.("café") dynamic form -- confirms ok_identifier() in
      # unparse.cc now accepts this name too, in lockstep with the lexer.
      assert source.any? { |line| line.include?(CAFE) && !line.include?('("') },
        "expected verb_code() to print a bare property reference; got:\n#{source.join("\n")}"
    end
  end

  def test_that_a_non_letter_symbol_is_never_accepted_as_part_of_an_identifier
    run_test_as('programmer') do
      # SNOWMAN is a symbol (category So), not a letter -- Unicode
      # XID_Start correctly excludes it. Whatever the compiler does with
      # the invalid byte sequence, the assignment must never actually
      # take effect: #{SNOWMAN} must never end up bound to 9.
      result = simplify(command(%Q|; #{SNOWMAN} = 9; return #{SNOWMAN};|))
      assert_not_equal 9, result
    end
  end

  def test_that_ascii_only_programs_are_completely_unaffected
    run_test_as('programmer') do
      assert_equal 30, simplify(command('; x = 10; y = 20; return x + y;'))
      assert_equal [1, 2, 3], simplify(command('; return {1, 2, 3};'))
    end
  end

  def test_that_strupper_and_strlower_are_unicode_aware
    run_test_as('programmer') do
      cafe_upper = 'CAF'.b + [0xC3, 0x89].pack('C*') # "CAFÉ"
      assert_equal cafe_upper, simplify(command(%Q|; return strupper("#{CAFE}");|))
      assert_equal CAFE, simplify(command(%Q|; return strlower("#{cafe_upper}");|))
    end
  end

  def test_that_strupper_and_strlower_pass_an_invalid_byte_through_unchanged
    run_test_as('programmer') do
      result = simplify(command('; return {strupper("a" + chr(128) + "b"), strlower("a" + chr(128) + "b")};'))
      assert_equal 'A'.b + [0x80].pack('C*') + 'B'.b, result[0]
      assert_equal 'a'.b + [0x80].pack('C*') + 'b'.b, result[1]
    end
  end

  # --- Unicode case-folding in verb/property dispatch (Checkpoint B) ---
  #
  # Verb and property lookup have always been case-insensitive for ASCII
  # names; that folding used to be byte-wise and only covered ASCII (a
  # non-ASCII byte passed through unfolded, so two names differing only in
  # accent-case were previously treated as distinct). Unicode identifiers
  # make this inconsistency a real dispatch-correctness question, not just
  # a cosmetic one -- resolved by extending the fold to real Unicode simple
  # case folding everywhere ASCII already folded.

  def test_that_verb_dispatch_is_case_insensitive_for_unicode_names
    run_test_as('wizard') do
      o = create(NOTHING)
      add_verb(o, [player, 'rxd', CAFE], ['this', 'none', 'this'])
      set_verb_code(o, CAFE) { |vc| vc << 'return 99;' }
      # Call with different case than the declared name.
      assert_equal 99, simplify(command(%Q|; return #{obj_ref(o)}:#{CAFE_UPPER}();|))
    end
  end

  def test_that_property_lookup_is_case_insensitive_for_unicode_names
    run_test_as('wizard') do
      o = create(NOTHING)
      add_property(o, CAFE, 'hi', [player, ''])
      assert_equal 'hi', simplify(command(%Q|; return #{obj_ref(o)}.#{CAFE_UPPER};|))
    end
  end

  def test_that_dispatch_folds_across_differing_byte_lengths_per_character
    run_test_as('wizard') do
      # The Kelvin sign (3 bytes) case-folds to ASCII 'k' (1 byte) -- a
      # verb name containing it must still be found by a plain 'k'-led
      # search word, exercising the fold path that can't be handled by a
      # simple per-byte comparison.
      o = create(NOTHING)
      add_verb(o, [player, 'rxd', KELVIN + 'elvin'], ['this', 'none', 'this'])
      set_verb_code(o, KELVIN + 'elvin') { |vc| vc << 'return 7;' }
      assert_equal 7, simplify(command(%Q|; return #{obj_ref(o)}:kelvin();|))
    end
  end

  def test_that_two_verbs_differing_only_by_accent_case_collide_after_folding
    run_test_as('wizard') do
      # Documented, intentional compatibility risk (see docs/ChangeLog.md):
      # any existing database that already had two non-ASCII verb names
      # differing only by case (possible before this change only via the
      # dynamic add_verb() API, since static syntax couldn't reference
      # them at all) can no longer address them independently by name,
      # once dispatch case-folding covers Unicode too -- every name-based
      # lookup (call dispatch, set_verb_code, etc.) now treats "café" and
      # "CAFÉ" as the same verb identity. Concretely: add_verb() itself
      # still happily creates a second verbdef, but a *second*
      # set_verb_code() call keyed by the fold-equivalent name resolves
      # back to the *first* verbdef (the one verbcasecmp finds first) and
      # overwrites its code, rather than reaching the second verbdef at
      # all. Pinned explicitly here, since it's a real and easy-to-get-
      # wrong consequence of extending the fold, not just a theoretical
      # concern about call dispatch alone.
      o = create(NOTHING)
      add_verb(o, [player, 'rxd', CAFE], ['this', 'none', 'this'])
      set_verb_code(o, CAFE) { |vc| vc << 'return 1;' }
      add_verb(o, [player, 'rxd', CAFE_UPPER], ['this', 'none', 'this'])
      set_verb_code(o, CAFE_UPPER) { |vc| vc << 'return 2;' }
      # Both names resolve to the same verb identity, so both calls see
      # whichever code that shared verb ends up with (here, the second
      # set_verb_code() call's, since it's the one that landed last).
      result_lower = simplify(command(%Q|; return #{obj_ref(o)}:#{CAFE}();|))
      result_upper = simplify(command(%Q|; return #{obj_ref(o)}:#{CAFE_UPPER}();|))
      assert_equal result_lower, result_upper
      assert_equal 2, result_lower
    end
  end

  def test_that_a_program_ending_immediately_after_a_unicode_identifier_compiles_correctly
    run_test_as('wizard') do
      # Regression test for a real bug caught during development (never
      # shipped): the lexer's new "byte >= 0x80 might start/continue a
      # Unicode identifier" check cast the character read from lex_getc()
      # to unsigned char before comparing, and (unsigned char) EOF (-1)
      # casts to 0xFF, which satisfies ">= 0x80" -- so the *end of the
      # program*, right after finishing a Unicode identifier, was briefly
      # misread as "maybe another UTF-8 continuation byte". A verb body
      # with no trailing semicolon after its last statement (valid syntax
      # -- the trailing semicolon is optional at the end of a program) and
      # whose very last token is a multi-byte identifier hits exactly this
      # boundary: the scanner finishes "café"'s last byte, then calls
      # lex_getc() one more time to check for a continuation character,
      # and gets EOF.
      o = create(NOTHING)
      add_verb(o, [player, 'rxd', 't'], ['this', 'none', 'this'])
      set_verb_code(o, 't') { |vc| vc << "#{CAFE} = 42; return #{CAFE}" }
      assert_equal 42, simplify(command(%Q|; return #{obj_ref(o)}:t();|))
    end
  end

  def test_that_multiple_space_separated_aliases_combine_wildcards_and_unicode
    run_test_as('wizard') do
      # A verb declared with three space-separated names: a plain ASCII
      # name, a plain Unicode name, and a star-abbreviated Unicode name --
      # every alias must independently dispatch, case-insensitively, and
      # the wildcard abbreviation on the third alias must not affect the
      # other two.
      o = create(NOTHING)
      names = "look #{CAFE} c*#{CAFE[1..-1]}" # "look café c*afé"
      add_verb(o, [player, 'rxd', names], ['this', 'none', 'this'])
      set_verb_code(o, 'look') { |vc| vc << 'return 1;' }
      assert_equal 1, simplify(command(%Q|; return #{obj_ref(o)}:look();|))
      assert_equal 1, simplify(command(%Q|; return #{obj_ref(o)}:#{CAFE}();|))
      assert_equal 1, simplify(command(%Q|; return #{obj_ref(o)}:#{CAFE_UPPER}();|))
      # Abbreviation of the third alias ("c*afé" -> minimum "c"), matched
      # case-insensitively against the Unicode letter too.
      assert_equal 1, simplify(command(%Q|; return #{obj_ref(o)}:c();|))
      assert_equal 1, simplify(command(%Q|; return #{obj_ref(o)}:C();|))
    end
  end

end
