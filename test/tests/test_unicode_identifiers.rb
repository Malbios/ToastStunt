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
  CAFE = 'caf'.b + EACUTE
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

end
