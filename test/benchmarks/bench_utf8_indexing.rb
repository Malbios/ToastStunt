require 'test_helper'

# Non-CI performance sanity check for the ASCII-fast-path / cursor cache
# behind codepoint-index <-> byte-offset conversion (src/utf8.cc). NOT part
# of the automated suite: test/Makefile's `tests` target is
# $(wildcard tests/*.rb), so this deliberately lives outside test/tests/ to
# avoid being swept into the default `make` run and making it intermittently
# slow/flaky (wall-clock timing is inherently noisy in CI). See
# test/tests/test_unicode_strings.rb's
# test_that_sequential_character_indexing_reconstructs_a_long_mixed_multibyte_string
# for the correctness-only counterpart of this same access pattern.
#
# Run manually against an already-running server, from the test/ directory:
#   ruby -r rubygems -Itests/lib benchmarks/bench_utf8_indexing.rb
#
# Measures wall-clock time for a sequential character-by-character walk --
# the exact access pattern the cursor cache exists for -- over strings of
# increasing length, both pure-ASCII and mixed-width, and reports the
# *scaling ratio* between runs instead of asserting an absolute threshold:
# if the cache is doing its job, walking a string N times longer should
# take roughly N times as long (linear), not N^2 times as long (what an
# unconditional scan-from-0 on every single-character read would produce).
# Building each test string is done in its own, separately-timed command so
# that its cost (a plain MOO-level concatenation loop, not itself under
# test here) never leaks into the walk-loop measurement.
class BenchUtf8Indexing < Test::Unit::TestCase

  LENGTHS = [5000, 50000, 500000]
  MIXED_PATTERN = "a\u{E9}\u{4E2D}\u{1F600}b" # 'a', 'é', '中', grinning-face emoji, 'b' -- 1/2/3/4-byte widths

  def build_and_time_walk(pattern, len)
    # Build via exponential doubling (O(log len) MOO-level operations)
    # rather than a naive per-character concatenation loop (O(len)
    # operations): the latter was measured to exhaust this server's
    # ~60000-tick-per-task budget at just ~1000 iterations of plain string
    # concatenation, silently hanging the connection (a ticks-exhausted
    # task never sends the eval wrapper's closing response marker).
    build = %Q|; pattern = "#{pattern}"; s = pattern; while (length(s) < #{len}) s = s + s; endwhile s = s[1..#{len}]; if (`player.bench_str ! E_PROPNF => -1' == -1) add_property(player, "bench_str", "", {player, "rc"}); endif player.bench_str = s; return length(s);|
    built_len = simplify(command(build))
    raise "setup built #{built_len.inspect} chars, expected #{len}" unless built_len == len

    # The walk itself -- the thing actually under test -- is chunked with
    # a suspend(0) between chunks to reset the tick budget for large
    # lengths, for the same reason. suspend(0) yields to the scheduler and
    # resumes the same task, so the client's single command() call still
    # blocks until the whole (possibly multi-chunk) walk finishes and
    # returns -- the wall-clock measurement below still covers the entire
    # walk, including any suspend/resume scheduling latency. Since the
    # number of chunks (and therefore suspends) scales linearly with len
    # for a fixed chunk size, that latency is itself a linear-order term
    # and doesn't manufacture a false quadratic signal.
    chunk = 1000
    walk = %Q|; s = player.bench_str; result = 0; total = 0; total_len = length(s); while (total < total_len) n = min(#{chunk}, total_len - total); for i in [1..n] result = result + length(s[total + i]); endfor total = total + n; if (total < total_len) suspend(0); endif endwhile return result;|
    t0 = Time.now
    value = simplify(command(walk))
    wall = Time.now - t0
    raise "walk returned #{value.inspect}, expected #{len}" unless value == len

    wall
  end

  def run_and_report(label, pattern)
    puts "  #{label}:"
    results = LENGTHS.map { |len| [len, build_and_time_walk(pattern, len)] }
    results.each { |len, wall| puts "    #{len} chars: #{'%.4f' % wall}s" }

    results.each_cons(2) do |(len_a, wall_a), (len_b, wall_b)|
      length_ratio = len_b.to_f / len_a
      if wall_a < 0.002
        puts "    #{len_a} -> #{len_b}: skipping ratio check, #{len_a}-char run too fast to measure reliably"
        next
      end
      time_ratio = wall_b / wall_a
      puts "    #{len_a} -> #{len_b} (#{'%.1f' % length_ratio}x length): #{'%.1f' % time_ratio}x time"
      # Generous slop (3x the length ratio) since this is a real network
      # round trip on a shared machine, not an isolated microbenchmark --
      # the point is catching an O(n^2) regression (which would blow past
      # even this much slop), not pinning down a precise constant.
      if time_ratio > length_ratio * 3
        puts "    WARNING: #{label} #{len_a} -> #{len_b} took #{'%.1f' % time_ratio}x as long for " \
             "#{'%.1f' % length_ratio}x the length -- looks quadratic, not linear " \
             "(cursor cache may be broken)."
      end
    end
  end

  def test_sequential_indexing_scales_roughly_linearly
    run_test_as('wizard') do
      puts "\nSequential character-by-character indexing benchmark (informational, not a CI gate):"
      run_and_report('ASCII', 'x')
      run_and_report('mixed-width', MIXED_PATTERN)
    end
  end

end
