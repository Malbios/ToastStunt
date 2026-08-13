require 'open3'

require 'test_helper'

class Array

  def include_sequence?(sequence)
    items = self.to_enum
    sequence.each do |i|
      return false unless loop { break true if items.next == i }
    end
    true
  end

end

class TestCannedDbs < Test::Unit::TestCase

  private

  # NOTE: each `wait.value` below runs *after* the corresponding stream is
  # fully drained via readlines, not before. Waiting on the child first
  # (the original order here) is a classic Open3 deadlock: if the child
  # writes enough output to fill the pipe's OS buffer before exiting, it
  # blocks on its own write() while we block on wait.value, and neither
  # side ever proceeds. readlines blocking until EOF (i.e. until the child
  # closes the pipe, which happens at or before exit) gives the same
  # synchronization safely.
  def diff(first, second)
    _, diff, _, wait = Open3.popen3 %[diff #{first} #{second}]
    lines = diff.readlines.map(&:chomp)
    wait.value

    lines
  end

  def log_and_diff(original, backup)
    _, _, log, wait = Open3.popen3 %[./moo #{original} #{backup} 9899]
    log_lines = log.readlines.map(&:chomp)
    wait.value

    _, diff, _, wait = Open3.popen3 %[diff #{original} #{backup}]
    diff_lines = diff.readlines.map(&:chomp)
    wait.value

    [log_lines, diff_lines]
  end

  public

  def test_that_creating_garbage_and_then_shutting_down_leaves_a_pending_anonymous_object
    log1, diff1 = log_and_diff('tests/Anon1.db', '/tmp/Foo.db')
    log2, diff2 = log_and_diff('/tmp/Foo.db', '/tmp/Bar.db')

    delta = [
      '< 0 values pending finalization',
      '---',
      '> 1 values pending finalization',
      '> 12',
      '> 4'
    ]

    assert log1.none? { |l| l =~ /recycle called/ }
    assert log2.any? { |l| l =~ /recycle called/ }

    assert diff1.include_sequence? delta
    assert_equal [], diff2
  end

  def test_that_creating_cyclic_garbage_and_then_shutting_down_leaves_pending_anonymous_objects
    log1, diff1 = log_and_diff('tests/Anon2.db', '/tmp/Foo.db')
    log2, diff2 = log_and_diff('/tmp/Foo.db', '/tmp/Bar.db')

    delta = [
      '< 0 values pending finalization',
      '---',
      '> 2 values pending finalization',
      '> 12',
      '> 4',
      '> 12',
      '> 5'
    ]

    assert log1.none? { |l| l =~ /recycle called/ }
    assert log2.any? { |l| l =~ /recycle called on A/ }
    assert log2.any? { |l| l =~ /recycle called on B/ }

    assert diff1.include_sequence? delta
    assert_equal [], diff2
  end

  def test_that_creating_garbage_and_letting_the_server_clean_up_leaves_the_database_as_is
    log1, diff1 = log_and_diff('tests/Anon3.db', '/tmp/Foo.db')
    log2, diff2 = log_and_diff('/tmp/Foo.db', '/tmp/Bar.db')

    assert log1.any? { |l| l =~ /recycle called/ }
    assert log2.any? { |l| l =~ /recycle called/ }

    assert_equal [], diff1
    assert_equal [], diff2
  end

  def test_that_chains_of_objects_are_cleaned_up_correctly
    log1, diff1 = log_and_diff('tests/Anon4.db', '/tmp/Foo.db')
    log2, diff2 = log_and_diff('/tmp/Foo.db', '/tmp/Bar.db')
    log3, diff3 = log_and_diff('/tmp/Bar.db', '/tmp/Baz.db')

    assert log1.any? { |l| l =~ /\$one is valid/ }
    assert log1.any? { |l| l =~ /\$one\.two is valid/ }
    assert log2.any? { |l| l =~ /\$one is valid/ }
    assert log2.any? { |l| l =~ /\$one\.two is invalid/ }
    assert log3.any? { |l| l =~ /\$one is invalid/ }
    assert log3.any? { |l| l =~ /\$one\.two is invalid/ }

    assert_equal [], diff('tests/Anon4.db', '/tmp/Baz.db')

    delta2 = [
      '< 0 values pending finalization',
      '---',
      '> 1 values pending finalization',
      '> 12',
      '> 4'
    ]

    delta3 = [
      '< 1 values pending finalization',
      '< 12',
      '< 4',
      '---',
      '> 0 values pending finalization'
    ]

    assert diff2.include_sequence? delta2
    assert diff3.include_sequence? delta3
  end

  def test_that_loaded_anonymous_objects_are_accounted_for_correctly
    log1, diff1 = log_and_diff('tests/Anon5.db', '/tmp/Foo.db')
    log2, diff2 = log_and_diff('/tmp/Foo.db', '/tmp/Bar.db')
    log3, diff3 = log_and_diff('/tmp/Bar.db', '/tmp/Baz.db')

    delta1 = [
      '10c10',
      '< 4',
      '---',
      '> 5'
    ]

    assert diff1.include_sequence? delta1
    assert_equal [], diff2
    assert_equal [], diff3
  end

  def test_that_invalid_values_pending_finalization_are_removed
    log1, diff1 = log_and_diff('tests/Anon6.db', '/tmp/Foo.db')

    delta1 = [
      '< 1 values pending finalization',
      '< 12',
      '< -1',
      '---',
      '> 0 values pending finalization'
    ]

    assert diff1.include_sequence? delta1

    assert log1.any? { |l| l =~ /shazam/ }
  end

  def test_that_check_for_invalid_objects_succeeds
    log, _ = log_and_diff('tests/Broken1.db', '/dev/null')

    assert log.any? { |l| l =~ /#0.parent = #103 <invalid> ... removed/ }
    assert log.any? { |l| l =~ /#0.child = #104 <invalid> ... removed/ }
    assert log.any? { |l| l =~ /#0.location = #101 <invalid> ... fixed/ }
    assert log.any? { |l| l =~ /#0.content = #102 <invalid> ... removed/ }
  end

  def test_that_check_for_invalid_object_types_succeeds
    log, _ = log_and_diff('tests/Broken2.db', '/dev/null')

    assert log.any? { |l| l =~ /#0.parents is not an object or list of objects/ }
    assert log.any? { |l| l =~ /#0.children is not a list of objects/ }
    assert log.any? { |l| l =~ /#0.location is not an object/ }
    assert log.any? { |l| l =~ /#0.contents is not a list of objects/ }
    assert log.any? { |l| l =~ /#1.parents is not an object or list of objects/ }
    assert log.any? { |l| l =~ /#1.children is not a list of objects/ }
    assert log.any? { |l| l =~ /#1.location is not an object/ }
    assert log.any? { |l| l =~ /#1.contents is not a list of objects/ }
  end


  def test_that_check_for_cycles_succeeds
    log, _ = log_and_diff('tests/Broken3.db', '/dev/null')

    assert log.any? { |l| l =~ /Cycle in parent chain of #0/ }
    assert log.any? { |l| l =~ /Cycle in location chain of #0/ }
    assert log.any? { |l| l =~ /Cycle in parent chain of #1/ }
    assert log.any? { |l| l =~ /Cycle in location chain of #1/ }
    assert log.any? { |l| l =~ /Cycle in parent chain of #2/ }
    assert log.any? { |l| l =~ /Cycle in location chain of #2/ }
    assert log.any? { |l| l =~ /Cycle in parent chain of #3/ }
    assert log.any? { |l| l =~ /Cycle in location chain of #3/ }
  end

  def test_that_check_for_inconsistencies_top_down_succeeds
    log, _ = log_and_diff('tests/Broken4.db', '/dev/null')

    assert log.any? { |l| l =~ /#0 not in it's location's \(#2\) contents/ }
    assert log.any? { |l| l =~ /#0 not in it's parent's \(#1\) children/ }
    assert log.any? { |l| l =~ /#1 not in it's location's \(#2\) contents/ }
    assert log.any? { |l| l =~ /#2 not in it's parent's \(#1\) children/ }
    assert log.any? { |l| l =~ /#3 not in it's location's \(#2\) contents/ }
    assert log.any? { |l| l =~ /#3 not in it's parent's \(#1\) children/ }
  end

  def test_that_check_for_inconsistencies_bottom_up_succeeds
    log, _ = log_and_diff('tests/Broken5.db', '/dev/null')

    assert log.any? { |l| l =~ /#1 not in it's child's \(#0\) parents/ }
    assert log.any? { |l| l =~ /#2 not in it's content's \(#3\) location/ }
  end

  # BiFuncCallSuspend1.db is stored at "Format Version 17" (DBV_Bool),
  # predating the DBV_BiFuncId16 bump that widened OP_BI_FUNC_CALL's
  # bytecode operand from 1 to 2 bytes. Its #0:server_started() forks a
  # task to shut the server down immediately, while the main task suspends
  # (a builtin call) for 1 real second - so the checkpoint below captures a
  # task genuinely paused mid-BI_FUNC_CALL, with its pc a raw byte offset
  # into 1-byte-operand bytecode. Reloading it forces write_activ/read_activ
  # to recompile that same verb source and reapply the stored pc against
  # the freshly generated bytecode; this only lines up correctly if the
  # operand width is derived from the *reloaded program's own* recorded
  # version rather than from the live (now on this build, 65535-capable)
  # builtin table. See bi_func_id_bytes() in functions.cc.
  #
  # Every dump() stamps its *file header* with current_db_version regardless
  # of what version it was loaded at, but each suspended activation carries
  # its own "language version" tag (write_activ/read_activ) recorded at the
  # moment it originally suspended - so the first reload (phase 2) still
  # decodes the pc as 1-byte-wide, matching how it was originally compiled.
  # Once that first suspended task resumes and finishes, nothing is left
  # suspended in the phase-2 dump; server_started() forks+suspends again on
  # the next boot exactly as phase 1 did, but this time the verb recompiles
  # under the file's now-current version, giving phases 3-4 the same round
  # trip through the *new* 2-byte-wide encoding introduced by DBV_BiFuncId16
  # (the exact "language version" number stamped is whatever DB_Version is
  # current on this build -- not necessarily DBV_BiFuncId16 itself, since
  # later versions may have appended further entries -- so it moves forward
  # whenever a new DB version is added, e.g. DBV_Utf8Errors).
  def test_that_a_task_suspended_mid_builtin_call_survives_a_checkpoint_and_resumes
    log1, _ = log_and_diff('tests/BiFuncCallSuspend1.db', '/tmp/BiFuncCallSuspend1.db')

    assert log1.none? { |l| l =~ /BIFUNC_SUSPEND_RESUME_OK/ },
           'task should not have had a chance to resume in the same run it was suspended in'
    assert File.read('/tmp/BiFuncCallSuspend1.db') =~ /^1 suspended tasks$/,
           'checkpoint should have persisted exactly one suspended task'
    assert File.read('/tmp/BiFuncCallSuspend1.db') =~ /^language version 17$/,
           'suspended task should have been compiled under the legacy 1-byte-operand version'

    log2, _ = log_and_diff('/tmp/BiFuncCallSuspend1.db', '/tmp/BiFuncCallSuspend2.db')

    assert log2.any? { |l| l =~ /BIFUNC_SUSPEND_RESUME_OK/ },
           'task suspended mid-builtin-call (1-byte operand) should resume correctly after reload'

    log3, _ = log_and_diff('/tmp/BiFuncCallSuspend2.db', '/tmp/BiFuncCallSuspend3.db')

    assert log3.none? { |l| l =~ /BIFUNC_SUSPEND_RESUME_OK/ },
           'task should not have had a chance to resume in the same run it was suspended in'
    assert File.read('/tmp/BiFuncCallSuspend3.db') =~ /^1 suspended tasks$/,
           'second checkpoint should have persisted exactly one suspended task'
    assert File.read('/tmp/BiFuncCallSuspend3.db') =~ /^language version 19$/,
           'second suspended task should have been compiled under the new 2-byte-operand version'

    log4, _ = log_and_diff('/tmp/BiFuncCallSuspend3.db', '/tmp/BiFuncCallSuspend4.db')

    assert log4.any? { |l| l =~ /BIFUNC_SUSPEND_RESUME_OK/ },
           'task suspended mid-builtin-call (2-byte operand) should resume correctly after reload'
  end

end
