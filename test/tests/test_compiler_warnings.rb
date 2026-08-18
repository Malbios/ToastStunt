require 'test_helper'

class TestCompilerWarnings < Test::Unit::TestCase

  def setup_verb
    o = create(:nothing)
    add_verb(o, [player, 'rwxd', 'foo'], ['this', 'none', 'this'])
    o
  end

  # set_verb_code() returns a list of diagnostic strings (errors and, now,
  # warnings) -- simplify() unwraps a single-element list to a bare string,
  # so "there's a diagnostic" is checked as "not the empty list" rather than
  # assuming any particular shape.
  def assert_has_diagnostic(result)
    assert_not_equal [], result, "expected a diagnostic, got #{result.inspect}"
  end

  # A warning's message body starts with "Warning: " -- the marker MOOdy's
  # client/sidecar use to tell a non-blocking warning apart from a real
  # compile error in the otherwise-identical flat diagnostic list
  # set_verb_code()/.program both return.
  def assert_has_warning(result)
    assert Array(result).any? { |l| l =~ /Warning: / }, "expected a warning-marked diagnostic, got #{result.inspect}"
  end

  # A genuine syntax error must still return a non-empty diagnostic list AND
  # leave the verb's prior (empty) code untouched -- confirming the new
  # warning callback wiring didn't let real errors through as if they were
  # non-blocking warnings.
  def test_that_a_real_syntax_error_still_blocks_the_save
    run_test_as('programmer') do
      o = setup_verb
      result = set_verb_code(o, 'foo', ['if (1)'])
      assert_has_diagnostic(result)
      assert_equal [], verb_code(o, 'foo')
    end
  end

  # Assignment used as the condition of if/elseif/while now warns, but must
  # NOT block the save -- confirmed by actually calling the verb afterward.
  def test_that_assignment_as_if_condition_warns_but_saves
    run_test_as('programmer') do
      o = setup_verb
      result = set_verb_code(o, 'foo', ['x = 0;', 'if (x = 1)', 'return 1;', 'endif'])
      assert_has_diagnostic(result)
      assert_has_warning(result)
      assert_equal 1, call(o, 'foo')
    end
  end

  def test_that_assignment_as_elseif_condition_warns_but_saves
    run_test_as('programmer') do
      o = setup_verb
      result = set_verb_code(o, 'foo', ['x = 0;', 'if (0)', 'return 0;', 'elseif (x = 1)', 'return 1;', 'endif'])
      assert_has_diagnostic(result)
      assert_equal 1, call(o, 'foo')
    end
  end

  def test_that_assignment_as_while_condition_warns_but_saves
    run_test_as('programmer') do
      o = setup_verb
      result = set_verb_code(o, 'foo', ['x = 0;', 'while (x = 1)', 'return x;', 'endwhile'])
      assert_has_diagnostic(result)
      assert_equal 1, call(o, 'foo')
    end
  end

  def test_that_assignment_as_named_while_condition_warns_but_saves
    run_test_as('programmer') do
      o = setup_verb
      result = set_verb_code(o, 'foo', ['x = 0;', 'while loop (x = 1)', 'return x;', 'endwhile'])
      assert_has_diagnostic(result)
      assert_equal 1, call(o, 'foo')
    end
  end

  # Control case: comparison (not assignment) must not warn.
  def test_that_equality_as_if_condition_does_not_warn
    run_test_as('programmer') do
      o = setup_verb
      result = set_verb_code(o, 'foo', ['x = 0;', 'if (x == 1)', 'return 1;', 'endif'])
      assert_equal [], result
      assert_equal 0, call(o, 'foo')
    end
  end

  # Bare ANY in an inline catch now warns, but must NOT block the save.
  def test_that_bare_any_inline_catch_warns_but_saves
    run_test_as('programmer') do
      o = setup_verb
      result = set_verb_code(o, 'foo', ['x = 0;', 'return `1 / x ! ANY => 0\';'])
      assert_has_diagnostic(result)
      assert_equal 0, call(o, 'foo')
    end
  end

  # Control case: an explicit error code (not bare ANY) must not warn.
  def test_that_specific_code_inline_catch_does_not_warn
    run_test_as('programmer') do
      o = setup_verb
      result = set_verb_code(o, 'foo', ['x = 0;', 'return `1 / x ! E_DIV => 0\';'])
      assert_equal [], result
      assert_equal 0, call(o, 'foo')
    end
  end

  # The interactive `.program` command is the OTHER live compile path (Part
  # A also wired a warning callback into tasks.cc's `client`, separate from
  # the set_verb_code()/parser.y path exercised above). It doesn't go through
  # the "; ..." eval-verb protocol that `command` normally waits on (no
  # PREFIX/SUFFIX markers are emitted for it), so this reads raw lines off
  # the socket directly up to the ".program"-session-ending "N error(s)."
  # summary line instead.
  def test_that_dot_program_warns_but_saves
    run_test_as('wizard') do
      o = setup_verb

      send_string(".program #{o}:foo")
      send_string("x = 0;")
      send_string("if (x = 1)")
      send_string("return 1;")
      send_string("endif")
      send_string(".")

      transcript = []
      loop do
        line = @sock.gets
        break if line.nil?
        line = line.chomp
        transcript << line
        break if line =~ /error\(s\)\.$/
      end

      assert transcript.any? { |l| l =~ /Assignment used as a condition/ },
             "expected a warning in the .program transcript, got #{transcript.inspect}"
      assert transcript.any? { |l| l =~ /Warning: Assignment used as a condition/ },
             "expected the warning to carry the Warning: marker, got #{transcript.inspect}"
      assert transcript.any? { |l| l == "0 error(s)." },
             "warning must not count as an error, got #{transcript.inspect}"
      assert_equal 1, call(o, 'foo')
    end
  end

end
