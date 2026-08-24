require 'test_helper'

class TestAnonymous < Test::Unit::TestCase

  def setup
    run_test_as('wizard') do
      command(%Q|; for t in (queued_tasks()); kill_task(t[1]); endfor;|)
    end
  end


  def test_that_anonymous_objects_created_from_nothing_are_valid
    run_test_as('programmer') do
      assert_equal 1, simplify(command("; return valid(create($nothing, 1));"))
    end
  end

  def test_that_anonymous_objects_created_from_an_empty_list_are_valid
    run_test_as('programmer') do
      assert_equal 1, simplify(command("; return valid(create({}, 1));"))
    end
  end

  def test_that_anonymous_objects_have_parents
    run_test_as('programmer') do
      x = create(:nothing)
      a = create(x)
      b = create(x)
      assert_equal a, simplify(command("; return parent(create({#{a}, #{b}}, 1));"))
      assert_equal [a, b], simplify(command("; return parents(create({#{a}, #{b}}, 1));"))
    end
  end

  def test_that_anonymous_objects_do_not_have_children
    run_test_as('programmer') do
      assert_equal [], simplify(command("; return children(create($anonymous, 1));"))
    end
  end

  def test_that_anonymous_objects_cannot_be_players
    run_test_as('programmer') do
      assert_equal E_TYPE, simplify(command("; is_player(create($anonymous, 1));"))
      assert_equal E_TYPE, simplify(command("; set_player_flag(create($anonymous, 1), 1);"))
    end
  end

  def test_that_the_owner_of_an_anonymous_object_is_the_creator
    run_test_as('programmer') do
      assert_equal player, simplify(command("; return create($anonymous, 1).owner;"))
    end
  end

  def test_that_a_wizard_can_change_the_owner_of_an_anonymous_object
    run_test_as('programmer') do
      assert_equal E_PERM, simplify(command("; a = create($anonymous, 1); a.owner = a.owner;"))
    end
    run_test_as('wizard') do
      assert_equal NOTHING, simplify(command("; a = create($anonymous, 1); a.owner = $nothing; return a.owner;"))
    end
  end

  def test_that_an_anonymous_object_has_a_name
    run_test_as('programmer') do
      assert_equal 'Foo Bar', simplify(command("; a = create($anonymous, 1); a.name = \"Foo Bar\"; return a.name;"))
    end
  end

  def test_that_setting_the_wizard_flag_on_an_anonymous_object_is_illegal
    run_test_as('programmer') do
      assert_equal E_PERM, simplify(command("; create($anonymous, 1).wizard = 0;"))
      assert_equal E_PERM, simplify(command("; create($anonymous, 1).wizard = 1;"))
    end
    run_test_as('wizard') do
      assert_equal E_INVARG, simplify(command("; create($anonymous, 1).wizard = 0;"))
      assert_equal E_INVARG, simplify(command("; create($anonymous, 1).wizard = 1;"))
    end
  end

  def test_that_setting_the_programmer_flag_on_an_anonymous_object_is_illegal
    run_test_as('programmer') do
      assert_equal E_PERM, simplify(command("; create($anonymous, 1).programmer = 0;"))
      assert_equal E_PERM, simplify(command("; create($anonymous, 1).programmer = 1;"))
    end
    run_test_as('wizard') do
      assert_equal E_INVARG, simplify(command("; create($anonymous, 1).programmer = 0;"))
      assert_equal E_INVARG, simplify(command("; create($anonymous, 1).programmer = 1;"))
    end
  end

  def test_that_defined_properties_work_on_anonymous_objects
    run_test_as('programmer') do
      x = create(:nothing)
      add_property(x, 'x', 123, ['player', ''])

      y = create(x)
      add_property(y, 'y', 'abc', ['player', ''])

      z = create(y)
      add_property(z, 'z', [1], ['player', ''])

      assert_equal 123, simplify(command("; a = create(#{z}, 1); return a.x;"))
      assert_equal 'abc', simplify(command("; a = create(#{z}, 1); return a.y;"))
      assert_equal 1, simplify(command("; a = create(#{z}, 1); return a.z;"))
    end
  end

  def test_that_verb_calls_work_on_anonymous_objects
    run_test_as('programmer') do
      x = create(:nothing)
      add_verb(x, ['player', 'xd', 'x'], ['this', 'none', 'this'])
      set_verb_code(x, 'x') do |vc|
        vc << %Q|return 123;|
      end

      y = create(x)
      add_verb(y, ['player', 'xd', 'y'], ['this', 'none', 'this'])
      set_verb_code(y, 'y') do |vc|
        vc << %Q|return "abc";|
      end

      z = create(y)
      add_verb(z, ['player', 'xd', 'z'], ['this', 'none', 'this'])
      set_verb_code(z, 'z') do |vc|
        vc << %Q|return [1 -> 1];|
      end

      assert_equal 123, simplify(command("; a = create(#{z}, 1); return a:x();"))
      assert_equal 'abc', simplify(command("; a = create(#{z}, 1); return a:y();"))
      assert_equal({1 => 1}, simplify(command("; a = create(#{z}, 1); return a:z();")))
    end
  end

  def test_that_valid_returns_true_if_an_anonymous_object_is_valid
    run_test_as('programmer') do
      assert_equal 1, simplify(command("; a = create($anonymous, 1); return valid(a);"))
    end
  end

  def test_that_recycle_invalidates_all_references_to_an_anonymous_object
    run_test_as('programmer') do
      assert_equal 0, simplify(command("; a = create($anonymous, 1); recycle(a); return valid(a);"))
      assert_equal 0, simplify(command("; a = create($anonymous, 1); b = a; recycle(a); return valid(b);"))
      assert_equal 0, simplify(command("; a = create($anonymous, 1); b = a; recycle(b); return valid(a);"))
    end
  end

  def test_that_losing_all_references_to_an_anonymous_object_calls_recycle
    run_test_as('programmer') do
      a = create(:object)
      add_property(a, 'recycle_called', 0, [player, ''])
      add_verb(a, ['player', 'xd', 'recycle'], ['this', 'none', 'this'])
      set_verb_code(a, 'recycle') do |vc|
        vc << %Q<typeof(this) == ANON || raise(E_INVARG);>
        vc << %Q<#{a}.recycle_called = #{a}.recycle_called + 1;>
      end
      assert_equal 0, get(a, 'recycle_called')
      simplify(command("; create(#{a}, 1);"))
      assert_equal 1, get(a, 'recycle_called')
    end
  end

  def test_that_losing_all_references_to_an_anonymous_object_calls_recycle_once
    run_test_as('programmer') do
      a = create(:object)
      add_property(a, 'reference', 0, [player, ''])
      add_property(a, 'recycle_called', 0, [player, ''])
      add_verb(a, ['player', 'xd', 'recycle'], ['this', 'none', 'this'])
      set_verb_code(a, 'recycle') do |vc|
        vc << %Q<typeof(this) == ANON || raise(E_INVARG);>
        vc << %Q<#{a}.recycle_called = #{a}.recycle_called + 1;>
        vc << %Q<#{a}.reference = this;>
      end
      assert_equal 0, get(a, 'recycle_called')
      simplify(command("; create(#{a}, 1);"))
      assert_equal 1, get(a, 'recycle_called')
      simplify(command("; #{a}.reference = 0;"))
      assert_equal 1, get(a, 'recycle_called')
    end
  end

  def test_that_an_anonymous_object_is_invalid_after_it_is_recycled
    run_test_as('programmer') do
      a = create(:object)
      add_property(a, 'reference', 0, [player, ''])
      add_property(a, 'recycle_called', 0, [player, ''])
      add_verb(a, ['player', 'xd', 'recycle'], ['this', 'none', 'this'])
      set_verb_code(a, 'recycle') do |vc|
        vc << %Q<typeof(this) == ANON || raise(E_INVARG);>
        vc << %Q<#{a}.recycle_called = #{a}.recycle_called + 1;>
        vc << %Q<#{a}.reference = this;>
      end
      assert_equal 0, get(a, 'recycle_called')
      simplify(command("; create(#{a}, 1);"))
      assert_equal 1, get(a, 'recycle_called')
      assert_equal 0, simplify(command("; return valid(#{a}.reference);"))
      assert_equal E_INVARG, simplify(command("; recycle(#{a}.reference);"))
      assert_equal E_INVIND, simplify(command("; #{a}.reference.name;"))
    end
  end

  def test_that_recycling_a_parent_does_not_invalidate_an_anonymous_object
    run_test_as('programmer') do
      o = create(:nothing)
      add_verb(o, ['player', 'xd', 'go'], ['this', 'none', 'this'])
      set_verb_code(o, 'go') do |vc|
        vc << %Q|o = create({});|
        vc << %Q|a = create(o, 1);|
        vc << %Q|recycle(o);|
        vc << %Q|return valid(a);|
      end
      assert_equal 1, call(o, 'go')
    end
  end

  def test_that_chparents_on_a_parent_does_not_invalidate_an_anonymous_object
    run_test_as('programmer') do
      o = create(:nothing)
      add_verb(o, ['player', 'xd', 'go'], ['this', 'none', 'this'])
      set_verb_code(o, 'go') do |vc|
        vc << %Q|a = create({});|
        vc << %Q|b = create({});|
        vc << %Q|c = create({a, b});|
        vc << %Q|d = create(c);|
        vc << %Q|m = create(a, 1);|
        vc << %Q|n = create(d, 1);|
        vc << %Q|chparents(c, {b, a});|
        vc << %Q|return {valid(m), valid(n)};|
      end
      assert_equal [1, 1], call(o, 'go')
    end
  end

  def test_that_adding_a_property_to_a_parent_does_not_invalidate_an_anonymous_object
    run_test_as('programmer') do
      o = create(:nothing)
      add_verb(o, ['player', 'xd', 'go'], ['this', 'none', 'this'])
      set_verb_code(o, 'go') do |vc|
        vc << %Q|o = create({});|
        vc << %Q|p = create({o});|
        vc << %Q|a = create(o, 1);|
        vc << %Q|b = create(p, 1);|
        vc << %Q|add_property(p, "xyz", 1, {player, ""});|
        vc << %Q|return {valid(a), valid(b)};|
      end
      assert_equal [1, 1], call(o, 'go')
    end
  end

  def test_that_deleting_a_property_from_a_parent_does_not_invalidate_an_anonymous_object
    run_test_as('programmer') do
      o = create(:nothing)
      add_verb(o, ['player', 'xd', 'go'], ['this', 'none', 'this'])
      set_verb_code(o, 'go') do |vc|
        vc << %Q|o = create({});|
        vc << %Q|p = create({o});|
        vc << %Q|add_property(p, "xyz", 1, {player, ""});|
        vc << %Q|a = create(o, 1);|
        vc << %Q|b = create(p, 1);|
        vc << %Q|delete_property(p, "xyz");|
        vc << %Q|return {valid(a), valid(b)};|
      end
      assert_equal [1, 1], call(o, 'go')
    end
  end

  def test_that_getting_a_property_on_an_invalid_anonymous_object_fails
    run_test_as('programmer') do
      assert_equal E_INVIND, simplify(command('; a = create($anonymous, 1); recycle(a); a.name;'))
    end
  end

  def test_that_setting_a_property_on_an_invalid_anonymous_object_fails
    run_test_as('programmer') do
      assert_equal E_INVIND, simplify(command('; a = create($anonymous, 1); recycle(a); a.name = "Hello";'))
    end
  end

  def test_that_a_verb_call_on_an_invalid_anonymous_object_fails
    run_test_as('programmer') do
      assert_equal E_INVIND, simplify(command('; a = create($anonymous, 1); recycle(a); a:foo();'))
    end
  end

  def test_that_recycling_an_invalid_anonymous_object_doesnt_crash_the_server
    run_test_as('programmer') do
      simplify(command(%Q|; o = create($nothing); p = create(o, 1); add_property(o, "foo", 0, {player, ""});|))
    end
  end

  def test_that_a_long_chain_of_anonymous_objects_doesnt_leak
    run_test_as('programmer') do
      a = create(:object)
      simplify(command(%Q|; add_property(#{a}, "next", #{a}, {player, ""}); |))
      add_verb(a, ['player', 'xd', 'go'], ['this', 'none', 'this'])
      set_verb_code(a, 'go') do |vc|
        lines = <<-EOF
          r = o = create($nothing, 1);
          for i in [1..100];
              n = create($nothing, 1);
              add_property(n, "next", o, {player, ""});
            o = n;
          endfor;
        EOF
        lines.split("\n").each do |line|
          vc << line
        end
      end
      call(a, 'go')
    end
  end

  if @@options['ownership_quota']
      def test_that_ownership_quota_is_not_changed_when_an_anonymous_object_becomes_invalid
          run_test_as('programmer') do
              o = create(:object)

              add_property(player, 'stash', {}, [player, ''])
              add_property(player, 'ownership_quota', 2, [player, ''])
              assert_equal 2, get(player, 'ownership_quota')

              a = simplify(command(%Q|; player.stash["a"] = create(#{o}, 1); return "player.stash[\\\"a\\\"]";|))
              assert_equal 1, get(player, 'ownership_quota')

              assert valid(a)
              chparent(o, :nothing)
              assert !valid(a)

              assert_equal 1, get(player, 'ownership_quota')
          end
      end

      def test_that_ownership_quota_is_changed_when_an_anonymous_object_loses_its_last_reference
          run_test_as('programmer') do
              o = create(:object)

              add_property(player, 'stash', {}, [player, ''])
              add_property(player, 'ownership_quota', 2, [player, ''])
              assert_equal 2, get(player, 'ownership_quota')

              a = simplify(command(%Q|; player.stash["a"] = create(#{o}, 1); return "player.stash[\\\"a\\\"]";|))
              assert_equal 1, get(player, 'ownership_quota')

              command(%Q|; #{a} = 0;|)

              assert_equal 2, get(player, 'ownership_quota')
          end
      end
  end

  # NOTE on the tests below (this comment applies to every test in this file
  # that follows this shape): verbs can no longer be added directly to an
  # anonymous object (commit a47da4d, "Don't allow adding verbs /
  # properties to anonymous objects. This was already documented as not
  # being possible. Now it's enforced."). Each test below now defines its
  # verbs on a throwaway *parent* object and creates the anonymous instance
  # `o` as a child of it, so `o` inherits them normally. `this` inside the
  # verb code is still the anonymous instance `o` when called through it
  # (inheritance doesn't change `this`), so this preserves every test's
  # original intent unchanged.

  # A `try'/`except' catching a raised error sees the stack trace from the
  # point of view of the catching programmer, same as callers()/task_stack()
  # above. The owner-sees-a-valid-reference case is covered by
  # test_that_an_error_stack_trace_contains_valid_anonymous_objects_for_the_owner;
  # this covers the complementary case, a non-owner still correctly denied.

  def test_that_raise_returns_invalid_anonymous_objects_for_everyone_else
    o = nil
    parent = nil
    run_test_as('wizard') do
      add_property(player, 'stash', {}, [player, 'r'])
      parent = create(:nothing)
      set(parent, 'w', 1)

      add_verb(parent, ['player', 'xd', 'boom'], ['this', 'none', 'this'])
      set_verb_code(parent, 'boom') do |vc|
        vc << %Q|set_task_perms(player);|
        vc << %Q|raise(E_INVARG);|
      end

      o = simplify(command(%Q|; o = player.stash["o"] = create(#{parent}, 1); o.r = o.w = 1; return tostr(player) + ".stash[\\\"o\\\"]";|))
    end
    run_test_as('programmer') do
      add_verb(parent, ['player', 'xd', 'c'], ['this', 'none', 'this'])
      set_verb_code(parent, 'c') do |vc|
        vc << %Q|try|
        vc << %Q|  this:boom();|
        vc << %Q|  return "did not raise";|
        vc << %Q|except e (ANY)|
        vc << %Q|  frames = e[4];|
        vc << %Q|  return {frames[1][2], valid(frames[1][1]), valid(frames[1][4])};|
        vc << %Q|endtry|
      end

      # index [4] is verb-loc: always valid, same reasoning as the
      # task_stack() test above.
      assert_equal ["boom", 0, 1], call(o, 'c')
    end
  end

  # This used to assert [["a", 0, 1], ["b", 0, 1]] -- i.e. even the wizard
  # who owns the anonymous object got an invalid placeholder for `this` in
  # the caught error's stack trace. That was the bug itself: raise_error()
  # hardcoded NOTHING as the viewing programmer regardless of who was
  # actually catching, so the anonymizing permission check always failed.
  # Now that it correctly uses the catching frame's own `progr`, the owning
  # wizard sees a valid reference; see
  # test_that_raise_returns_invalid_anonymous_objects_for_everyone_else
  # below for the non-owner case, which is still correctly blanked.
  def test_that_an_error_stack_trace_contains_valid_anonymous_objects_for_the_owner
    run_test_as('wizard') do
      add_property(player, 'stash', {}, [player, 'r'])
      parent = create(:nothing)
      set(parent, 'w', 1)

      add_verb(parent, ['player', 'xd', 'a'], ['this', 'none', 'this'])
      set_verb_code(parent, 'a') do |vc|
        vc << %Q|1/0;|
      end
      add_verb(parent, ['player', 'xd', 'b'], ['this', 'none', 'this'])
      set_verb_code(parent, 'b') do |vc|
        vc << %Q|return this:a();|
      end
      add_verb(parent, ['player', 'xd', 'c'], ['this', 'none', 'this'])
      set_verb_code(parent, 'c') do |vc|
        vc << %Q|try;|
        vc << %Q|this:b();|
        vc << %Q|except ex (ANY);|
        vc << %Q|endtry|
        vc << %Q|return {{ex[4][1][2], valid(ex[4][1][1]), valid(ex[4][1][4])}, {ex[4][2][2], valid(ex[4][2][1]), valid(ex[4][2][4])}};|
      end

      o = simplify(command(%Q|; o = player.stash["o"] = create(#{parent}, 1); o.r = o.w = 1; return tostr(player) + ".stash[\\\"o\\\"]";|))

      # Frame index [4] is verb-loc (the object the verb is actually
      # defined on), not `this`. Since verbs now live on the regular
      # `parent` object rather than the anonymous instance itself, verb-loc
      # is always a valid object here regardless of the anonymous
      # instance's validity -- only index [1] (`this`) tracks that.
      assert_equal [["a", 1, 1], ["b", 1, 1]], call(o, 'c')
    end
  end

  # Regression test for the renumber-does-not-invalidate-anonymous-children
  # behavior in db_renumber_object() (src/db_objects.cc): when a parent is
  # renumbered, its anonymous children's parent references are explicitly
  # fixed up to point at the new number rather than being left dangling.
  # This replaces a test that asserted the opposite (E_INVIND after
  # renumbering), which no longer matches the server's intentional
  # behavior -- see the sibling chparents/add_property/delete_property
  # "does not invalidate" tests above for the same pattern with other
  # structural changes.
  def test_that_renumbering_a_parent_does_not_invalidate_an_anonymous_object
    run_test_as('wizard') do
      o = create(:nothing)
      add_verb(o, ['player', 'xd', 'go'], ['this', 'none', 'this'])
      set_verb_code(o, 'go') do |vc|
        vc << %Q|recycle(create($nothing));|
        vc << %Q|recycle(create($nothing));|
        vc << %Q|a = create($nothing);|
        vc << %Q|add_property(a, "xyz", 1, {player, ""});|
        vc << %Q|m = create(a, 1);|
        vc << %Q|renumber(a);|
        vc << %Q|return m.xyz;|
      end
      assert_equal 1, call(o, 'go')
    end
  end

  ## anons()

  # Anonymous object values have no re-parseable MOO literal syntax, so they
  # can never be captured in Ruby via simplify() and re-interpolated into a
  # later command the way object numbers can -- every anon created below is
  # stashed in a persistent property from the same command that creates it
  # (never returned to Ruby), and only ever manipulated from further MOO
  # code, mirroring the existing "player.stash" pattern this file's other
  # anonymous-object tests already use.
  #
  # Filtered by parent throughout (rather than an unfiltered anons() count),
  # so these tests aren't sensitive to anon instances left behind by other
  # tests in this file -- each test uses its own freshly-created parent(s),
  # mirroring how the waifs() tests in test_waif.rb always filter by class.
  def anons_count(parent)
    simplify(command(%Q|; return length(anons(#{parent}));|))
  end

  def test_that_anons_filters_by_parent
    run_test_as('wizard') do
      p1 = create(:nothing)
      p2 = create(:nothing)
      assert_equal 0, anons_count(p1)
      assert_equal 0, anons_count(p2)
      add_property(player, 'stash', {}, [player, ''])
      simplify(command(%Q|; player.stash["a"] = create(#{p1}, 1); player.stash["b"] = create(#{p1}, 1); player.stash["c"] = create(#{p2}, 1); return 1;|))
      assert_equal 2, anons_count(p1)
      assert_equal 1, anons_count(p2)
      simplify(command("; player.stash = 0; return 1;"))
    end
  end

  def test_that_anons_deduplicates_a_multi_parent_instance
    run_test_as('wizard') do
      p1 = create(:nothing)
      p2 = create(:nothing)
      before = simplify(command("; return length(anons());"))
      add_property(player, 'stash', 0, [player, ''])
      simplify(command(%Q|; player.stash = create({#{p1}, #{p2}}, 1); return 1;|))
      after = simplify(command("; return length(anons());"))
      assert_equal 1, after - before
      assert_equal 1, anons_count(p1)
      assert_equal 1, anons_count(p2)
      simplify(command("; player.stash = 0; return 1;"))
    end
  end

  def test_that_anons_shows_only_owned_anons_to_non_wizards
    p = owner = nil
    run_test_as('programmer') do
      p = create(:nothing)
      owner = player
      add_property(player, 'stash', 0, [player, ''])
      simplify(command(%Q|; player.stash = create(#{p}, 1); return 1;|))
      assert_equal 1, anons_count(p)
    end
    run_test_as('programmer') do
      assert_equal 0, anons_count(p)
    end
    run_test_as('wizard') do
      assert_equal 1, anons_count(p)
      simplify(command(%Q|; #{owner}.stash = 0; return 1;|))
    end
  end

  def test_that_anons_no_longer_shows_a_recycled_anon
    run_test_as('wizard') do
      p = create(:nothing)
      add_property(player, 'stash', 0, [player, ''])
      simplify(command(%Q|; player.stash = create(#{p}, 1); return 1;|))
      assert_equal 1, anons_count(p)
      simplify(command("; player.stash = 0; return 1;"))
      assert_equal 0, anons_count(p)
    end
  end

end
