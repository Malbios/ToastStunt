require 'test_helper'

class TestObjectsAndProperties < Test::Unit::TestCase

  def setup
    run_test_as('programmer') do
      @obj = simplify(command(%Q|; o = create($nothing); o.r = 1; o.w = 1; return o;|))
    end
  end

  ## Must redefine this because anonymous objects can't be
  ## passed in/out/through Ruby-space.
  def create(parents = nil, *args)
    case parents
    when Array
      parents = '{' + parents.map { |p| obj_ref(p) }.join(', ') + '}'
    else
      parents = obj_ref(parents)
    end

    p = rand(36**5).to_s(36)

    unless args.empty?
      args = args.map { |a| value_ref(a) }.join(', ')
      simplify(command(%Q|; add_property(#{@obj}, "_#{p}", create(#{parents}, #{args}), {player, "rw"}); return "#{@obj}._#{p}";|))
    else
      simplify(command(%Q|; add_property(#{@obj}, "_#{p}", create(#{parents}), {player, "rw"}); return "#{@obj}._#{p}";|))
    end
  end

  ## Must redefine this because anonymous objects can't be
  ## passed in/out/through Ruby-space.
  def create(parents, *args)
    case parents
    when Array
      parents = '{' + parents.map { |p| obj_ref(p) }.join(', ') + '}'
    else
      parents = obj_ref(parents)
    end

    p = rand(36**5).to_s(36)

    owner = nil
    anon = nil

    unless args.empty?
      if args.length > 1
        owner, anon = *args
      elsif args[0].kind_of? Numeric
        anon = args[0]
      else
        owner = args[0]
      end
    end

    if !owner.nil? and !anon.nil?
      simplify(command(%Q|; add_property(#{@obj}, "_#{p}", create(#{parents}, #{obj_ref(owner)}, #{value_ref(anon)}), {player, "rw"}); return "#{@obj}._#{p}";|))
    elsif !owner.nil?
      simplify(command(%Q|; add_property(#{@obj}, "_#{p}", create(#{parents}, #{obj_ref(owner)}), {player, "rw"}); return "#{@obj}._#{p}";|))
    elsif !anon.nil?
      simplify(command(%Q|; add_property(#{@obj}, "_#{p}", create(#{parents}, #{value_ref(anon)}), {player, "rw"}); return "#{@obj}._#{p}";|))
    else
      simplify(command(%Q|; add_property(#{@obj}, "_#{p}", create(#{parents}), {player, "rw"}); return "#{@obj}._#{p}";|))
    end
  end

  def typeof(*args)
    simplify(command(%Q|; return typeof(#{args.join(', ')});|))
  end

  SCENARIOS = [
    [:object, 0],
    [:anonymous, 1]
  ]

  # add_property()/delete_property()/set_property_info() now always fail
  # with E_TYPE when called directly on an anonymous object (commit
  # a47da4d, "Don't allow adding verbs / properties to anonymous
  # objects."), before any of the validity/permission/name checks a given
  # test below is otherwise exercising even run. Tests that call one of
  # these three directly on a SCENARIOS object branch on
  # `args[0] == :anonymous` to assert E_TYPE instead of their original,
  # now-impossible-for-anonymous-objects scenario.

  ## add_property

  def test_that_add_property_works_on_objects
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        r = add_property(o, 'foobar', 0, ['player', ''])
        if args[0] == :anonymous
          assert_equal E_TYPE, r
        else
          assert_not_equal E_TYPE, r
          assert_not_equal E_INVARG, r
          assert_not_equal E_PERM, r
          assert_equal 'abc', set(o, 'foobar', 'abc')
          assert_equal 'abc', get(o, 'foobar')
        end
      end
    end
  end

  def test_that_add_property_fails_if_the_owner_is_not_valid
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_equal E_INVARG, add_property(o, 'foobar', 0, [:nothing, ''])
      end
    end
  end

  def test_that_add_property_fails_if_the_perms_are_garbage
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_equal E_INVARG, add_property(o, 'foobar', 0, ['player', 'abc'])
      end
    end
  end

  def test_that_add_property_fails_if_the_object_is_not_valid
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        recycle(o)
        expected = args[0] == :anonymous ? E_TYPE : E_INVARG
        assert_equal expected, add_property(o, 'foobar', 0, ['player', ''])
      end
    end
  end

  def test_that_add_property_fails_if_the_property_is_built_in
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        expected = args[0] == :anonymous ? E_TYPE : E_INVARG
        assert_equal expected, add_property(o, 'name', 0, ['player', ''])
      end
    end
  end

  def test_that_add_property_fails_if_the_property_is_already_defined_on_an_ancestor
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = simplify(command(%Q|; return create($nothing);|))
        add_property(o, 'foobar', 123, ['player', ''])
        p = create(o, args[1])
        expected = args[0] == :anonymous ? E_TYPE : E_INVARG
        assert_equal expected, add_property(p, 'foobar', 0, ['player', ''])
      end
    end
  end

  # only permanent objects can have descendants

  def test_that_add_property_fails_if_the_property_is_already_defined_on_a_descendant
    run_test_as('programmer') do
      x = simplify(command(%Q|; return create($nothing);|))
      o = simplify(command(%Q|; return create(#{x});|))
      add_property(o, 'foobar', 0, ['player', 'rw'])
      assert_equal E_INVARG, add_property(x, 'foobar', 0, ['player', ''])
    end
  end

  def test_that_add_property_fails_if_the_programmer_does_not_have_write_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        set(o, 'w', 0)
      end
      run_test_as('programmer') do
        expected = args[0] == :anonymous ? E_TYPE : E_PERM
        assert_equal expected, add_property(o, 'foobar', 0, ['player', ''])
      end
    end
  end

  def test_that_add_property_succeeds_if_the_programmer_has_write_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        set(o, 'w', 1)
      end
      run_test_as('programmer') do
        assert_not_equal E_PERM, add_property(o, 'foobar', 0, ['player', ''])
      end
    end
  end

  def test_that_add_property_succeeds_if_the_programmer_is_a_wizard
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        set(o, 'w', 0)
      end
      run_test_as('wizard') do
        assert_not_equal E_PERM, add_property(o, 'foobar', 0, ['player', ''])
      end
    end
  end

  def test_that_add_property_fails_if_the_programmer_is_not_the_owner_specified_in_propinfo
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        expected = args[0] == :anonymous ? E_TYPE : E_PERM
        assert_equal expected, add_property(o, 'foobar', 0, [:system, ''])
      end
    end
  end

  def test_that_add_property_succeeds_if_the_programmer_is_the_owner_specified_in_propinfo
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_not_equal E_PERM, add_property(o, 'foobar', 0, [player, ''])
      end
    end
  end

  def test_that_add_property_sets_the_owner_if_the_programmer_is_a_wizard
    SCENARIOS.each do |args|
      run_test_as('wizard') do
        o = create(*args)
        assert_not_equal E_PERM, add_property(o, 'foobar', 0, [:system, ''])
      end
    end
  end

  ## delete_property

  def test_that_delete_property_works_on_objects
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, ['player', ''])
        r = delete_property(o, 'foobar')
        if args[0] == :anonymous
          assert_equal E_TYPE, r
        else
          assert_not_equal E_TYPE, r
          assert_not_equal E_INVARG, r
          assert_not_equal E_PERM, r
          assert_not_equal E_PROPNF, r
        end
      end
    end
  end

  def test_that_delete_property_fails_if_the_object_is_not_valid
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        recycle(o)
        expected = args[0] == :anonymous ? E_TYPE : E_INVARG
        assert_equal expected, delete_property(o, 'foobar')
      end
    end
  end

  def test_that_delete_property_fails_if_the_property_does_not_exist
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        expected = args[0] == :anonymous ? E_TYPE : E_PROPNF
        assert_equal expected, delete_property(o, 'foobar')
      end
    end
  end

  def test_that_delete_property_fails_if_the_property_is_built_in
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        expected = args[0] == :anonymous ? E_TYPE : E_PROPNF
        assert_equal expected, delete_property(o, 'name')
      end
    end
  end

  def test_that_delete_property_fails_if_the_programmer_does_not_have_write_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, ['player', ''])
        set(o, 'w', 0)
      end
      run_test_as('programmer') do
        expected = args[0] == :anonymous ? E_TYPE : E_PERM
        assert_equal expected, delete_property(o, 'foobar')
      end
    end
  end

  def test_that_delete_property_succeeds_if_the_programmer_has_write_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, ['player', ''])
        set(o, 'w', 1)
      end
      run_test_as('programmer') do
        assert_not_equal E_PERM, delete_property(o, 'foobar')
      end
    end
  end

  def test_that_delete_property_succeeds_if_the_programmer_is_a_wizard
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, ['player', ''])
        set(o, 'w', 0)
      end
      run_test_as('wizard') do
        assert_not_equal E_PERM, delete_property(o, 'foobar')
      end
    end
  end

  ## reorder_property

  # reorder_property() moves a property already defined directly on the
  # object to a new 1-based position among that object's own properties,
  # without deleting and re-adding it (which would lose its
  # owner/permissions and briefly disrupt anything else keyed off its
  # current definition). It checks obj.is_obj() first, same as
  # add_property()/delete_property(), so it's E_TYPE against an anonymous
  # object regardless of what else a given test below is otherwise
  # exercising.

  def test_that_reorder_property_works_on_objects
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'p1', 1, ['player', ''])
        add_property(o, 'p2', 2, ['player', ''])
        add_property(o, 'p3', 3, ['player', ''])
        r = simplify(command(%Q|; return reorder_property(#{obj_ref(o)}, "p1", 3);|))
        if args[0] == :anonymous
          assert_equal E_TYPE, r
        else
          assert_equal 0, r
          assert_equal ['p2', 'p3', 'p1'], properties(o)
          assert_equal 1, get(o, 'p1')
          assert_equal 2, get(o, 'p2')
          assert_equal 3, get(o, 'p3')
        end
      end
    end
  end

  def test_that_reorder_property_fails_if_the_object_is_not_valid
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        recycle(o)
        expected = args[0] == :anonymous ? E_TYPE : E_INVARG
        assert_equal expected, simplify(command(%Q|; return reorder_property(#{obj_ref(o)}, "foobar", 1);|))
      end
    end
  end

  def test_that_reorder_property_rejects_a_non_object_argument
    run_test_as('programmer') do
      assert_equal E_TYPE, simplify(command('; return reorder_property(5, "foobar", 1);'))
    end
  end

  def test_that_reorder_property_fails_if_the_property_does_not_exist
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        expected = args[0] == :anonymous ? E_TYPE : E_PROPNF
        assert_equal expected, simplify(command(%Q|; return reorder_property(#{obj_ref(o)}, "foobar", 1);|))
      end
    end
  end

  def test_that_reorder_property_fails_if_the_new_index_is_out_of_range
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'p1', 1, ['player', ''])
        add_property(o, 'p2', 2, ['player', ''])
        expected = args[0] == :anonymous ? E_TYPE : E_INVARG
        assert_equal expected, simplify(command(%Q|; return reorder_property(#{obj_ref(o)}, "p1", 0);|))
        assert_equal expected, simplify(command(%Q|; return reorder_property(#{obj_ref(o)}, "p1", -1);|))
        assert_equal expected, simplify(command(%Q|; return reorder_property(#{obj_ref(o)}, "p1", 3);|))
      end
    end
  end

  def test_that_reorder_property_fails_if_the_programmer_does_not_have_write_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, ['player', ''])
        set(o, 'w', 0)
      end
      run_test_as('programmer') do
        expected = args[0] == :anonymous ? E_TYPE : E_PERM
        assert_equal expected, simplify(command(%Q|; return reorder_property(#{obj_ref(o)}, "foobar", 1);|))
      end
    end
  end

  def test_that_reorder_property_succeeds_if_the_programmer_has_write_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'p1', 1, ['player', ''])
        add_property(o, 'p2', 2, ['player', ''])
        set(o, 'w', 1)
      end
      run_test_as('programmer') do
        assert_not_equal E_PERM, simplify(command(%Q|; return reorder_property(#{obj_ref(o)}, "p1", 2);|))
      end
    end
  end

  def test_that_reorder_property_succeeds_if_the_programmer_is_a_wizard
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'p1', 1, ['player', ''])
        add_property(o, 'p2', 2, ['player', ''])
        set(o, 'w', 0)
      end
      run_test_as('wizard') do
        assert_not_equal E_PERM, simplify(command(%Q|; return reorder_property(#{obj_ref(o)}, "p1", 2);|))
      end
    end
  end

  def test_that_reorder_property_to_its_current_position_is_a_noop
    run_test_as('programmer') do
      o = create(NOTHING)
      add_property(o, 'p1', 1, ['player', ''])
      add_property(o, 'p2', 2, ['player', ''])
      assert_equal 0, simplify(command(%Q|; return reorder_property(#{obj_ref(o)}, "p2", 2);|))
      assert_equal ['p1', 'p2'], properties(o)
    end
  end

  # The highest-risk case: property values live in a flat array shared
  # across the whole ancestor chain, so reordering a propdef on the
  # parent must relocate the corresponding value slot on every
  # descendant too, without disturbing any of the descendant's other
  # slots (inherited or its own).
  def test_that_reorder_property_preserves_values_on_descendants
    run_test_as('programmer') do
      parent = create(NOTHING)
      child = create(parent)
      add_property(parent, 'p1', 1, ['player', ''])
      add_property(parent, 'p2', 2, ['player', ''])
      add_property(parent, 'p3', 3, ['player', ''])
      add_property(child, 'c1', 'own', ['player', ''])
      add_property(child, 'c2', 'own2', ['player', ''])
      set(child, 'p2', 99)

      assert_equal 0, simplify(command(%Q|; return reorder_property(#{obj_ref(parent)}, "p1", 3);|))

      assert_equal ['p2', 'p3', 'p1'], properties(parent)
      assert_equal ['c1', 'c2'], properties(child)

      assert_equal 1, get(parent, 'p1')
      assert_equal 2, get(parent, 'p2')
      assert_equal 3, get(parent, 'p3')

      assert_equal 1, get(child, 'p1')
      assert_equal 99, get(child, 'p2')
      assert_equal 3, get(child, 'p3')
      assert_equal 'own', get(child, 'c1')
      assert_equal 'own2', get(child, 'c2')
    end
  end

  def test_that_reorder_property_preserves_values_on_an_anonymous_descendant
    run_test_as('programmer') do
      parent = simplify(command(%Q|; return create($nothing);|))
      add_property(parent, 'p1', 1, ['player', ''])
      add_property(parent, 'p2', 2, ['player', ''])
      add_property(parent, 'p3', 3, ['player', ''])
      child = create(parent, 1)
      set(child, 'p2', 99)

      assert_equal 0, simplify(command(%Q|; return reorder_property(#{obj_ref(parent)}, "p1", 3);|))

      assert_equal 1, get(child, 'p1')
      assert_equal 99, get(child, 'p2')
      assert_equal 3, get(child, 'p3')
    end
  end

  ## is_clear_property

  def test_that_is_clear_property_works_on_objects
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = simplify(command(%Q|; return create($nothing);|))
        add_property(o, 'foobar', 123, ['player', ''])
        p = create(o, args[1])
        assert_equal 1, is_clear_property(p, 'foobar')
        set(p, 'foobar', 'hello')
        assert_equal 0, is_clear_property(p, 'foobar')
      end
    end
  end

  def test_that_is_clear_property_fails_if_the_object_is_not_valid
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        recycle(o)
        assert_equal E_INVARG, is_clear_property(o, 'foobar')
      end
    end
  end

  def test_that_is_clear_property_fails_if_the_property_does_not_exist
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_equal E_PROPNF, is_clear_property(o, 'foobar')
      end
    end
  end

  def test_that_is_clear_property_returns_false_if_the_property_is_built_in
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_equal 0, is_clear_property(o, 'name')
      end
    end
  end

  # An anonymous object can never be a property's definer (add_property()
  # on one always fails), so that half of this scenario just confirms
  # the failure instead.
  def test_that_is_clear_property_returns_false_if_called_on_the_definer
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        r = add_property(o, 'foobar', 0, ['player', ''])
        if args[0] == :anonymous
          assert_equal E_TYPE, r
        else
          assert_equal 0, is_clear_property(o, 'foobar')
        end
      end
    end
  end

  def test_that_is_clear_property_fails_if_the_programmer_does_not_have_read_permission
    SCENARIOS.each do |args|
      p = nil
      run_test_as('programmer') do
        o = simplify(command(%Q|; return create($nothing);|))
        add_property(o, 'foobar', 0, ['player', ''])
        p = create(o, args[1])
      end
      run_test_as('programmer') do
        assert_equal E_PERM, is_clear_property(p, 'foobar')
      end
    end
  end

  def test_that_is_clear_property_succeeds_if_the_programmer_has_read_permission
    SCENARIOS.each do |args|
      p = nil
      run_test_as('programmer') do
        o = simplify(command(%Q|; return create($nothing);|))
        add_property(o, 'foobar', 0, ['player', 'r'])
        p = create(o, args[1])
      end
      run_test_as('programmer') do
        assert_not_equal E_PERM, is_clear_property(p, 'foobar')
      end
    end
  end

  def test_that_is_clear_property_succeeds_if_the_programmer_is_a_wizard
    SCENARIOS.each do |args|
      p = nil
      run_test_as('programmer') do
        o = simplify(command(%Q|; return create($nothing);|))
        add_property(o, 'foobar', 0, ['player', ''])
        p = create(o, args[1])
      end
      run_test_as('wizard') do
        assert_not_equal E_PERM, is_clear_property(p, 'foobar')
      end
    end
  end

  ## clear_property

  # The implementation of `clear_property()' isn't perfectly
  # consistent with the documentation in the standard server.
  # Specifically, non-wizard, non-owners can't clear a property, even
  # if the property is writable -- contrary to what the docs say.
  # Stunt fixes this inconsistency.

  def test_that_clear_property_works_on_objects
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = simplify(command(%Q|; return create($nothing);|))
        add_property(o, 'foobar', 123, ['player', ''])
        p = create(o, args[1])
        set(p, 'foobar', 'hello')
        assert_equal 'hello', get(p, 'foobar')
        clear_property(p, 'foobar')
        assert_equal 123, get(p, 'foobar')
      end
    end
  end

  def test_that_clear_property_fails_if_the_object_is_not_valid
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        recycle(o)
        assert_equal E_INVARG, clear_property(o, 'foobar')
      end
    end
  end

  def test_that_clear_property_fails_if_the_property_does_not_exist
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_equal E_PROPNF, clear_property(o, 'foobar')
      end
    end
  end

  def test_that_clear_property_raises_an_error_if_the_property_is_built_in
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_equal E_PERM, clear_property(o, 'name')
      end
    end
  end

  # An anonymous object can never be a property's definer (add_property()
  # on one always fails), so that half of this scenario just confirms
  # the failure instead.
  def test_that_clear_property_raises_an_error_if_called_on_the_definer
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        r = add_property(o, 'foobar', 0, ['player', ''])
        if args[0] == :anonymous
          assert_equal E_TYPE, r
        else
          assert_equal E_INVARG, clear_property(o, 'foobar')
        end
      end
    end
  end

  def test_that_clear_property_fails_if_the_programmer_does_not_have_write_permission
    SCENARIOS.each do |args|
      p = nil
      run_test_as('programmer') do
        o = simplify(command(%Q|; return create($nothing);|))
        add_property(o, 'foobar', 0, ['player', ''])
        p = create(o, args[1])
      end
      run_test_as('programmer') do
        assert_equal E_PERM, clear_property(p, 'foobar')
      end
    end
  end

  def test_that_clear_property_succeeds_if_the_programmer_has_write_permission
    SCENARIOS.each do |args|
      p = nil
      run_test_as('programmer') do
        o = simplify(command(%Q|; return create($nothing);|))
        add_property(o, 'foobar', 0, ['player', 'w'])
        p = create(o, args[1])
      end
      run_test_as('programmer') do
        assert_not_equal E_PERM, clear_property(p, 'foobar')
      end
    end
  end

  def test_that_clear_property_succeeds_if_the_programmer_is_a_wizard
    SCENARIOS.each do |args|
      p = nil
      run_test_as('programmer') do
        o = simplify(command(%Q|; return create($nothing);|))
        add_property(o, 'foobar', 0, ['player', ''])
        p = create(o, args[1])
      end
      run_test_as('wizard') do
        assert_not_equal E_PERM, clear_property(p, 'foobar')
      end
    end
  end

  ## property_info

  # add_property() always fails on an anonymous object directly, so this
  # (and the read-permission test below) define the property on a real
  # parent and query it through an anonymous child instead --
  # property_info() itself is still permissive of anonymous objects, so
  # this still exercises the intended behavior.
  def test_that_property_info_works_on_objects
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        parent = simplify(command(%Q|; return create($nothing);|))
        o = create(parent, args[1])
        add_property(parent, 'foobar', 0, [player, 'rw'])
        assert_equal [player, 'rw'], property_info(o, 'foobar')
      end
    end
  end

  def test_that_property_info_fails_if_the_object_is_not_valid
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        recycle(o)
        assert_equal E_INVARG, property_info(o, 'foobar')
      end
    end
  end

  def test_that_property_info_fails_if_the_property_does_not_exist
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_equal E_PROPNF, property_info(o, 'foobar')
      end
    end
  end

  def test_that_property_info_raises_an_error_if_the_property_is_built_in
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_equal E_PROPNF, property_info(o, 'name')
      end
    end
  end

  def test_that_property_info_fails_if_the_programmer_does_not_have_read_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        parent = simplify(command(%Q|; return create($nothing);|))
        o = create(parent, args[1])
        add_property(parent, 'foobar', 0, ['player', ''])
      end
      run_test_as('programmer') do
        assert_equal E_PERM, property_info(o, 'foobar')
      end
    end
  end

  def test_that_property_info_succeeds_if_the_programmer_has_read_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, ['player', 'r'])
      end
      run_test_as('programmer') do
        assert_not_equal E_PERM, property_info(o, 'foobar')
      end
    end
  end

  def test_that_property_info_succeeds_if_the_programmer_is_a_wizard
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, ['player', ''])
      end
      run_test_as('wizard') do
        assert_not_equal E_PERM, property_info(o, 'foobar')
      end
    end
  end

  ## set_property_info

  # set_property_info() checks obj.is_obj() before anything else --
  # including before looking up the property at all -- so it always
  # fails with E_TYPE against an anonymous object regardless of what a
  # given test below is otherwise exercising.
  def test_that_set_property_info_works_on_objects
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, [player, 'rw'])
        r = set_property_info(o, 'foobar', [player, 'c'])
        if args[0] == :anonymous
          assert_equal E_TYPE, r
        else
          assert_equal [player, 'c'], property_info(o, 'foobar')
        end
      end
    end
  end

  def test_that_set_property_info_fails_if_the_object_is_not_valid
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        recycle(o)
        expected = args[0] == :anonymous ? E_TYPE : E_INVARG
        assert_equal expected, set_property_info(o, 'foobar', [player, ''])
      end
    end
  end

  def test_that_set_property_info_fails_if_the_property_does_not_exist
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        expected = args[0] == :anonymous ? E_TYPE : E_PROPNF
        assert_equal expected, set_property_info(o, 'foobar', [player, ''])
      end
    end
  end

  def test_that_set_property_info_raises_an_error_if_the_property_is_built_in
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        expected = args[0] == :anonymous ? E_TYPE : E_PROPNF
        assert_equal expected, set_property_info(o, 'name', [player, ''])
      end
    end
  end

  def test_that_set_property_info_fails_if_the_programmer_does_not_have_write_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, ['player', ''])
      end
      run_test_as('programmer') do
        expected = args[0] == :anonymous ? E_TYPE : E_PERM
        assert_equal expected, set_property_info(o, 'foobar', [player, ''])
      end
    end
  end

  def test_that_set_property_info_fails_even_if_the_programmer_has_write_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, ['player', 'w'])
      end
      run_test_as('programmer') do
        expected = args[0] == :anonymous ? E_TYPE : E_PERM
        assert_equal expected, set_property_info(o, 'foobar', [player, ''])
      end
    end
  end

  def test_that_set_property_info_succeeds_if_the_programmer_is_a_wizard
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        add_property(o, 'foobar', 0, ['player', ''])
      end
      run_test_as('wizard') do
        assert_not_equal E_PERM, set_property_info(o, 'foobar', [player, ''])
      end
    end
  end

  ## properties

  # Unlike property_info()/get()/set(), properties() only lists propdefs
  # defined directly on the object itself, not inherited ones -- so
  # there's no way to make it return anything but [] for an anonymous
  # object, since add_property() can never define one there.
  def test_that_properties_works_on_objects
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_equal [], properties(o)
        r = add_property(o, 'foobar', 0, [player, 'rw'])
        if args[0] == :anonymous
          assert_equal E_TYPE, r
          assert_equal [], properties(o)
        else
          assert_equal 'foobar', properties(o)
        end
      end
    end
  end

  def test_that_properties_fails_if_the_object_is_not_valid
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        recycle(o)
        assert_equal E_INVARG, properties(o)
      end
    end
  end

  def test_that_properties_fails_if_the_programmer_does_not_have_read_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        set(o, 'r', 0)
      end
      run_test_as('programmer') do
        assert_equal E_PERM, properties(o)
      end
    end
  end

  def test_that_properties_succeeds_if_the_programmer_has_read_permission
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        set(o, 'r', 1)
      end
      run_test_as('programmer') do
        assert_not_equal E_PERM, properties(o)
      end
    end
  end

  def test_that_properties_succeeds_if_the_programmer_is_a_wizard
    SCENARIOS.each do |args|
      o = nil
      run_test_as('programmer') do
        o = create(*args)
        set(o, 'r', 0)
      end
      run_test_as('wizard') do
        assert_not_equal E_PERM, properties(o)
      end
    end
  end

  def test_that_properties_and_inheritance_work
    SCENARIOS.each do |args|
      # delete_property() always fails with E_TYPE on an anonymous
      # object (m/n below), regardless of whether the property being
      # deleted is actually inherited (E_PROPNF).
      delete_property_expected = args[0] == :anonymous ? E_TYPE : E_PROPNF
      run_test_as('wizard') do
        e = create(NOTHING)
        b = create(NOTHING)
        c = create(NOTHING)

        add_property(e, 'e1', 'e1', [player, ''])
        add_property(e, 'e', 'e', [player, ''])
        add_property(b, 'b1', ['b1'], [player, 'r'])
        add_property(b, 'b', ['b'], [player, 'r'])
        add_property(c, 'c', location, [player, 'w'])

        m = create(e, args[1])
        n = create(e, args[1])

        assert_equal [player, ''], property_info(e, 'e')
        assert_equal [player, ''], property_info(e, 'e1')
        assert_equal E_PROPNF, property_info(e, 'b')
        assert_equal E_PROPNF, property_info(e, 'b1')
        assert_equal E_PROPNF, property_info(e, 'c')
        assert_equal [player, ''], property_info(m, 'e1')
        assert_equal [player, ''], property_info(m, 'e')
        assert_equal E_PROPNF, property_info(n, 'b1')
        assert_equal E_PROPNF, property_info(n, 'b')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal E_PROPNF, get(e, 'b')
        assert_equal E_PROPNF, get(e, 'b1')
        assert_equal E_PROPNF, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(n, 'e1')

        assert_equal 'ee', set(e, 'e', 'ee')
        assert_equal E_PROPNF, set(e, 'b', 'bb')
        assert_equal E_PROPNF, set(e, 'c', 'cc')
        assert_equal '11', set(m, 'e', '11')
        assert_equal 'ee', set(n, 'e', 'ee')

        assert_equal 'ee', get(e, 'e')
        assert_equal E_PROPNF, get(e, 'b')
        assert_equal E_PROPNF, get(e, 'c')
        assert_equal '11', get(m, 'e')
        assert_equal 'ee', get(n, 'e')

        assert_equal 'e', set(e, 'e', 'e')

        assert_equal 'e', get(e, 'e')
        assert_equal E_PROPNF, get(e, 'b')
        assert_equal E_PROPNF, get(e, 'c')
        assert_equal '11', get(m, 'e')
        assert_equal 'ee', get(n, 'e')

        clear_property(m, 'e')
        clear_property(n, 'e')

        chparent(e, b)

        assert_equal [player, ''], property_info(e, 'e')
        assert_equal [player, ''], property_info(e, 'e1')
        assert_equal [player, 'r'], property_info(e, 'b')
        assert_equal [player, 'r'], property_info(e, 'b1')
        assert_equal E_PROPNF, property_info(e, 'c')
        assert_equal [player, ''], property_info(m, 'e1')
        assert_equal [player, ''], property_info(m, 'e')
        assert_equal [player, 'r'], property_info(n, 'b1')
        assert_equal [player, 'r'], property_info(n, 'b')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal 'b', get(e, 'b')
        assert_equal 'b1', get(e, 'b1')
        assert_equal E_PROPNF, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(n, 'e1')

        chparent(e, c)

        assert_equal [player, ''], property_info(e, 'e')
        assert_equal [player, ''], property_info(e, 'e1')
        assert_equal E_PROPNF, property_info(e, 'b')
        assert_equal E_PROPNF, property_info(e, 'b1')
        assert_equal [player, 'w'], property_info(e, 'c')
        assert_equal [player, ''], property_info(m, 'e1')
        assert_equal [player, ''], property_info(m, 'e')
        assert_equal E_PROPNF, property_info(n, 'b1')
        assert_equal E_PROPNF, property_info(n, 'b')
        assert_equal [player, 'w'], property_info(m, 'c')
        assert_equal [player, 'w'], property_info(n, 'c')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal E_PROPNF, get(e, 'b')
        assert_equal E_PROPNF, get(e, 'b1')
        assert_equal location, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(n, 'e1')
        assert_equal location, get(m, 'c')
        assert_equal location, get(n, 'c')

        chparent(m, NOTHING)
        chparent(n, NOTHING)

        delete_property(c, 'c')
        add_property(c, 'c', 'c', [player, 'c'])

        chparent(m, e)
        chparent(n, e)

        assert_equal [player, ''], property_info(e, 'e')
        assert_equal [player, ''], property_info(e, 'e1')
        assert_equal E_PROPNF, property_info(e, 'b')
        assert_equal E_PROPNF, property_info(e, 'b1')
        assert_equal [player, 'c'], property_info(e, 'c')
        assert_equal [player, ''], property_info(m, 'e1')
        assert_equal [player, ''], property_info(m, 'e')
        assert_equal E_PROPNF, property_info(n, 'b1')
        assert_equal E_PROPNF, property_info(n, 'b')
        assert_equal [player, 'c'], property_info(m, 'c')
        assert_equal [player, 'c'], property_info(n, 'c')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal E_PROPNF, get(e, 'b')
        assert_equal E_PROPNF, get(e, 'b1')
        assert_equal 'c', get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(n, 'e1')
        assert_equal 'c', get(m, 'c')
        assert_equal 'c', get(n, 'c')

        assert_equal delete_property_expected, delete_property(m, 'e')
        assert_equal delete_property_expected, delete_property(n, 'e')

        chparent(m, NOTHING)
        chparent(n, NOTHING)

        delete_property(c, 'c')

        chparent(m, e)
        chparent(n, e)

        assert_equal 'e', get(e, 'e')
        assert_equal E_PROPNF, get(e, 'b')
        assert_equal E_PROPNF, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e', get(n, 'e')

        chparent(m, NOTHING)
        chparent(n, NOTHING)

        add_property(c, 'c', location, [player, 'w'])

        chparent(m, e)
        chparent(n, e)

        chparents(e, [b, c])

        assert_equal [player, ''], property_info(e, 'e')
        assert_equal [player, ''], property_info(e, 'e1')
        assert_equal [player, 'r'], property_info(e, 'b')
        assert_equal [player, 'r'], property_info(e, 'b1')
        assert_equal [player, 'w'], property_info(e, 'c')
        assert_equal [player, ''], property_info(m, 'e')
        assert_equal [player, ''], property_info(m, 'e1')
        assert_equal [player, 'r'], property_info(m, 'b')
        assert_equal [player, 'r'], property_info(m, 'b1')
        assert_equal [player, 'w'], property_info(m, 'c')
        assert_equal [player, ''], property_info(n, 'e')
        assert_equal [player, ''], property_info(n, 'e1')
        assert_equal [player, 'r'], property_info(n, 'b')
        assert_equal [player, 'r'], property_info(n, 'b1')
        assert_equal [player, 'w'], property_info(n, 'c')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal 'b', get(e, 'b')
        assert_equal 'b1', get(e, 'b1')
        assert_equal location, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e1', get(n, 'e1')
        assert_equal 'b', get(m, 'b')
        assert_equal 'b', get(n, 'b')
        assert_equal 'b1', get(m, 'b1')
        assert_equal 'b1', get(n, 'b1')
        assert_equal location, get(m, 'c')
        assert_equal location, get(n, 'c')

        assert_equal 'ee', set(e, 'e', 'ee')
        assert_equal 'bb', set(e, 'b', ['bb'])
        assert_equal location, set(e, 'c', location)
        assert_equal '11', set(m, 'e', '11')
        assert_equal 'ee', set(n, 'e', 'ee')
        assert_equal '22', set(m, 'b', ['22'])
        assert_equal 'bb', set(n, 'b',  ['bb'])
        assert_equal location, set(m, 'c', location)
        assert_equal location, set(n, 'c', location)

        assert_equal 'ee', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal 'bb', get(e, 'b')
        assert_equal 'b1', get(e, 'b1')
        assert_equal location, get(e, 'c')
        assert_equal '11', get(m, 'e')
        assert_equal 'ee', get(n, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e1', get(n, 'e1')
        assert_equal '22', get(m, 'b')
        assert_equal 'bb', get(n, 'b')
        assert_equal 'b1', get(m, 'b1')
        assert_equal 'b1', get(n, 'b1')
        assert_equal location, get(m, 'c')
        assert_equal location, get(n, 'c')

        assert_equal 'e', set(e, 'e',  'e')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal 'bb', get(e, 'b')
        assert_equal 'b1', get(e, 'b1')
        assert_equal location, get(e, 'c')
        assert_equal '11', get(m, 'e')
        assert_equal 'ee', get(n, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e1', get(n, 'e1')
        assert_equal '22', get(m, 'b')
        assert_equal 'bb', get(n, 'b')
        assert_equal 'b1', get(m, 'b1')
        assert_equal 'b1', get(n, 'b1')
        assert_equal location, get(m, 'c')
        assert_equal location, get(n, 'c')

        clear_property(m, 'e')
        clear_property(n, 'e')
        clear_property(m, 'b')
        clear_property(n, 'b')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal 'bb', get(e, 'b')
        assert_equal 'b1', get(e, 'b1')
        assert_equal location, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e1', get(n, 'e1')
        assert_equal 'bb', get(m, 'b')
        assert_equal 'bb', get(n, 'b')
        assert_equal 'b1', get(m, 'b1')
        assert_equal 'b1', get(n, 'b1')
        assert_equal location, get(m, 'c')
        assert_equal location, get(n, 'c')

        assert_equal 'b', set(e, 'b',  ['b'])

        chparents(e, [c, b])

        assert_equal [player, ''], property_info(e, 'e')
        assert_equal [player, ''], property_info(e, 'e1')
        assert_equal [player, 'r'], property_info(e, 'b')
        assert_equal [player, 'r'], property_info(e, 'b1')
        assert_equal [player, 'w'], property_info(e, 'c')
        assert_equal [player, ''], property_info(m, 'e')
        assert_equal [player, ''], property_info(m, 'e1')
        assert_equal [player, 'r'], property_info(m, 'b')
        assert_equal [player, 'r'], property_info(m, 'b1')
        assert_equal [player, 'w'], property_info(m, 'c')
        assert_equal [player, ''], property_info(n, 'e')
        assert_equal [player, ''], property_info(n, 'e1')
        assert_equal [player, 'r'], property_info(n, 'b')
        assert_equal [player, 'r'], property_info(n, 'b1')
        assert_equal [player, 'w'], property_info(n, 'c')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal 'b', get(e, 'b')
        assert_equal 'b1', get(e, 'b1')
        assert_equal location, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e1', get(n, 'e1')
        assert_equal 'b', get(m, 'b')
        assert_equal 'b', get(n, 'b')
        assert_equal 'b1', get(m, 'b1')
        assert_equal 'b1', get(n, 'b1')
        assert_equal location, get(m, 'c')
        assert_equal location, get(n, 'c')

        assert_equal delete_property_expected, delete_property(m, 'e')
        assert_equal delete_property_expected, delete_property(n, 'e')

        chparent(m, NOTHING)
        chparent(n, NOTHING)

        delete_property(c, 'c')

        chparent(m, e)
        chparent(n, e)

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal 'b', get(e, 'b')
        assert_equal 'b1', get(e, 'b1')
        assert_equal E_PROPNF, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e1', get(n, 'e1')
        assert_equal 'b', get(m, 'b')
        assert_equal 'b', get(n, 'b')
        assert_equal 'b1', get(m, 'b1')
        assert_equal 'b1', get(n, 'b1')
        assert_equal E_PROPNF, get(m, 'c')
        assert_equal E_PROPNF, get(n, 'c')

        r = create([])

        add_property(r, 'rrrr', 'rrrr', [player, ''])
        add_property(r, 'rrr', 'rrr', [player, 'r'])
        add_property(r, 'rr', 'rr', [player, 'w'])

         chparents(e, [b, r, c])

        assert_equal [player, ''], property_info(e, 'e')
        assert_equal [player, ''], property_info(e, 'e1')
        assert_equal [player, 'r'], property_info(e, 'b')
        assert_equal [player, 'r'], property_info(e, 'b1')
        assert_equal [player, 'w'], property_info(e, 'rr')
        assert_equal [player, 'r'], property_info(e, 'rrr')
        assert_equal [player, ''], property_info(e, 'rrrr')
        assert_equal E_PROPNF, property_info(e, 'c')
        assert_equal [player, ''], property_info(m, 'e')
        assert_equal [player, ''], property_info(m, 'e1')
        assert_equal [player, 'r'], property_info(m, 'b')
        assert_equal [player, 'r'], property_info(m, 'b1')
        assert_equal [player, 'w'], property_info(m, 'rr')
        assert_equal [player, 'r'], property_info(m, 'rrr')
        assert_equal [player, ''], property_info(m, 'rrrr')
        assert_equal E_PROPNF, property_info(m, 'c')
        assert_equal [player, ''], property_info(n, 'e')
        assert_equal [player, ''], property_info(n, 'e1')
        assert_equal [player, 'r'], property_info(n, 'b')
        assert_equal [player, 'r'], property_info(n, 'b1')
        assert_equal [player, 'w'], property_info(n, 'rr')
        assert_equal [player, 'r'], property_info(n, 'rrr')
        assert_equal [player, ''], property_info(n, 'rrrr')
        assert_equal E_PROPNF, property_info(n, 'c')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal 'b', get(e, 'b')
        assert_equal 'b1', get(e, 'b1')
        assert_equal 'rr', get(e, 'rr')
        assert_equal 'rrr', get(e, 'rrr')
        assert_equal 'rrrr', get(e, 'rrrr')
        assert_equal E_PROPNF, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e1', get(n, 'e1')
        assert_equal 'b', get(m, 'b')
        assert_equal 'b', get(n, 'b')
        assert_equal 'b1', get(m, 'b1')
        assert_equal 'b1', get(n, 'b1')
        assert_equal 'rr', get(m, 'rr')
        assert_equal 'rrr', get(m, 'rrr')
        assert_equal 'rrrr', get(m, 'rrrr')
        assert_equal 'rr', get(n, 'rr')
        assert_equal 'rrr', get(n, 'rrr')
        assert_equal 'rrrr', get(n, 'rrrr')
        assert_equal E_PROPNF, get(m, 'c')
        assert_equal E_PROPNF, get(n, 'c')

        chparent(m, NOTHING)
        chparent(n, NOTHING)

        delete_property(r, 'rrr')

        chparent(m, e)
        chparent(n, e)

        assert_equal [player, ''], property_info(e, 'e')
        assert_equal [player, ''], property_info(e, 'e1')
        assert_equal [player, 'r'], property_info(e, 'b')
        assert_equal [player, 'r'], property_info(e, 'b1')
        assert_equal [player, 'w'], property_info(e, 'rr')
        assert_equal E_PROPNF, property_info(e, 'rrr')
        assert_equal [player, ''], property_info(e, 'rrrr')
        assert_equal E_PROPNF, property_info(e, 'c')
        assert_equal [player, ''], property_info(m, 'e')
        assert_equal [player, ''], property_info(m, 'e1')
        assert_equal [player, 'r'], property_info(m, 'b')
        assert_equal [player, 'r'], property_info(m, 'b1')
        assert_equal [player, 'w'], property_info(m, 'rr')
        assert_equal E_PROPNF, property_info(m, 'rrr')
        assert_equal [player, ''], property_info(m, 'rrrr')
        assert_equal E_PROPNF, property_info(m, 'c')
        assert_equal [player, ''], property_info(n, 'e')
        assert_equal [player, ''], property_info(n, 'e1')
        assert_equal [player, 'r'], property_info(n, 'b')
        assert_equal [player, 'r'], property_info(n, 'b1')
        assert_equal [player, 'w'], property_info(n, 'rr')
        assert_equal E_PROPNF, property_info(n, 'rrr')
        assert_equal [player, ''], property_info(n, 'rrrr')
        assert_equal E_PROPNF, property_info(n, 'c')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal 'b', get(e, 'b')
        assert_equal 'b1', get(e, 'b1')
        assert_equal 'rr', get(e, 'rr')
        assert_equal E_PROPNF, get(e, 'rrr')
        assert_equal 'rrrr', get(e, 'rrrr')
        assert_equal E_PROPNF, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e1', get(n, 'e1')
        assert_equal 'b', get(m, 'b')
        assert_equal 'b', get(n, 'b')
        assert_equal 'b1', get(m, 'b1')
        assert_equal 'b1', get(n, 'b1')
        assert_equal 'rr', get(m, 'rr')
        assert_equal E_PROPNF, get(m, 'rrr')
        assert_equal 'rrrr', get(m, 'rrrr')
        assert_equal 'rr', get(n, 'rr')
        assert_equal E_PROPNF, get(n, 'rrr')
        assert_equal 'rrrr', get(n, 'rrrr')
        assert_equal E_PROPNF, get(m, 'c')
        assert_equal E_PROPNF, get(n, 'c')

        chparents(e, [c, b])

        assert_equal [player, ''], property_info(e, 'e')
        assert_equal [player, ''], property_info(e, 'e1')
        assert_equal [player, 'r'], property_info(e, 'b')
        assert_equal [player, 'r'], property_info(e, 'b1')
        assert_equal E_PROPNF, property_info(e, 'rr')
        assert_equal E_PROPNF, property_info(e, 'rrr')
        assert_equal E_PROPNF, property_info(e, 'rrrr')
        assert_equal E_PROPNF, property_info(e, 'c')
        assert_equal [player, ''], property_info(m, 'e')
        assert_equal [player, ''], property_info(m, 'e1')
        assert_equal [player, 'r'], property_info(m, 'b')
        assert_equal [player, 'r'], property_info(m, 'b1')
        assert_equal E_PROPNF, property_info(m, 'rr')
        assert_equal E_PROPNF, property_info(m, 'rrr')
        assert_equal E_PROPNF, property_info(m, 'rrrr')
        assert_equal E_PROPNF, property_info(m, 'c')
        assert_equal [player, ''], property_info(n, 'e')
        assert_equal [player, ''], property_info(n, 'e1')
        assert_equal [player, 'r'], property_info(n, 'b')
        assert_equal [player, 'r'], property_info(n, 'b1')
        assert_equal E_PROPNF, property_info(n, 'rr')
        assert_equal E_PROPNF, property_info(n, 'rrr')
        assert_equal E_PROPNF, property_info(n, 'rrrr')
        assert_equal E_PROPNF, property_info(n, 'c')

        assert_equal 'e', get(e, 'e')
        assert_equal 'e1', get(e, 'e1')
        assert_equal 'b', get(e, 'b')
        assert_equal 'b1', get(e, 'b1')
        assert_equal E_PROPNF, get(e, 'rr')
        assert_equal E_PROPNF, get(e, 'rrr')
        assert_equal E_PROPNF, get(e, 'rrrr')
        assert_equal E_PROPNF, get(e, 'c')
        assert_equal 'e', get(m, 'e')
        assert_equal 'e', get(n, 'e')
        assert_equal 'e1', get(m, 'e1')
        assert_equal 'e1', get(n, 'e1')
        assert_equal 'b', get(m, 'b')
        assert_equal 'b', get(n, 'b')
        assert_equal 'b1', get(m, 'b1')
        assert_equal 'b1', get(n, 'b1')
        assert_equal E_PROPNF, get(m, 'rr')
        assert_equal E_PROPNF, get(m, 'rrr')
        assert_equal E_PROPNF, get(m, 'rrrr')
        assert_equal E_PROPNF, get(n, 'rr')
        assert_equal E_PROPNF, get(n, 'rrr')
        assert_equal E_PROPNF, get(n, 'rrrr')
        assert_equal E_PROPNF, get(m, 'c')
        assert_equal E_PROPNF, get(n, 'c')
      end
    end
  end

  def test_that_adding_and_deleting_properties_works_with_multiple_inheritance
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        a = create(NOTHING)
        add_property(a, 'x', 1, [player, ''])
        add_property(a, 'y', 2, [player, ''])
        add_property(a, 'z', 3, [player, ''])

        b = create(a)
        add_property(b, 'm', 4, [player, ''])
        add_property(b, 'n', 5, [player, ''])

        c = create(b)
        add_property(c, 'c', 6, [player, ''])

        d = create([a, c], args[1])

        assert_equal 1, get(d, 'x')
        assert_equal 2, get(d, 'y')
        assert_equal 3, get(d, 'z')
        assert_equal 4, get(d, 'm')
        assert_equal 5, get(d, 'n')
        assert_equal 6, get(d, 'c')

        assert_equal 1, get(c, 'x')
        assert_equal 2, get(c, 'y')
        assert_equal 3, get(c, 'z')
        assert_equal 4, get(c, 'm')
        assert_equal 5, get(c, 'n')
        assert_equal 6, get(c, 'c')

        chparent(d, NOTHING)

        delete_property(a, 'y')

        chparents(d, [a, c])

        assert_equal 1, get(d, 'x')
        assert_equal E_PROPNF, get(d, 'y')
        assert_equal 3, get(d, 'z')
        assert_equal 4, get(d, 'm')
        assert_equal 5, get(d, 'n')
        assert_equal 6, get(d, 'c')

        assert_equal 1, get(c, 'x')
        assert_equal E_PROPNF, get(c, 'y')
        assert_equal 3, get(c, 'z')
        assert_equal 4, get(c, 'm')
        assert_equal 5, get(c, 'n')
        assert_equal 6, get(c, 'c')

        chparent(d, NOTHING)

        delete_property(b, 'm')

        chparents(d, [a, c])

        assert_equal 1, get(d, 'x')
        assert_equal E_PROPNF, get(d, 'y')
        assert_equal 3, get(d, 'z')
        assert_equal E_PROPNF, get(d, 'm')
        assert_equal 5, get(d, 'n')
        assert_equal 6, get(d, 'c')

        assert_equal 1, get(c, 'x')
        assert_equal E_PROPNF, get(c, 'y')
        assert_equal 3, get(c, 'z')
        assert_equal E_PROPNF, get(c, 'm')
        assert_equal 5, get(c, 'n')
        assert_equal 6, get(c, 'c')

        chparent(d, NOTHING)

        add_property(a, 's', 7, [player, ''])

        chparents(d, [a, c])

        assert_equal 1, get(d, 'x')
        assert_equal 3, get(d, 'z')
        assert_equal 5, get(d, 'n')
        assert_equal 6, get(d, 'c')
        assert_equal 7, get(d, 's')

        assert_equal 1, get(c, 'x')
        assert_equal 3, get(c, 'z')
        assert_equal 5, get(c, 'n')
        assert_equal 6, get(c, 'c')
        assert_equal 7, get(c, 's')

        chparent(d, NOTHING)

        add_property(b, 't', 8, [player, ''])

        chparents(d, [a, c])

        assert_equal 1, get(d, 'x')
        assert_equal 3, get(d, 'z')
        assert_equal 5, get(d, 'n')
        assert_equal 6, get(d, 'c')
        assert_equal 7, get(d, 's')
        assert_equal 8, get(d, 't')

        assert_equal 1, get(c, 'x')
        assert_equal 3, get(c, 'z')
        assert_equal 5, get(c, 'n')
        assert_equal 6, get(c, 'c')
        assert_equal 7, get(c, 's')
        assert_equal 8, get(c, 't')
      end
    end
  end

  ## has_property

  # has_property() is a thin wrapper around the same db_find_property()
  # search obj.name itself resolves through -- ancestor-aware, and
  # matching built-in properties too -- but returns a bare 0/1 with no
  # permission gate at all (unlike property_info(), which gates the
  # {owner, perms} detail behind the property's own read permission).
  # That's intentional: a boolean "would this resolve" leaks nothing
  # beyond what trial-and-error reading already would. Mirrors
  # test_objects_and_verbs.rb's verb_callable tests.

  def test_that_has_property_fails_if_the_object_is_not_valid
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        recycle(o)
        assert_equal E_INVARG, simplify(command(%Q|; return has_property(#{obj_ref(o)}, "foobar");|))
      end
    end
  end

  def test_that_has_property_rejects_a_non_object_argument
    run_test_as('programmer') do
      assert_equal E_TYPE, simplify(command('; return has_property(5, "foobar");'))
    end
  end

  def test_that_has_property_returns_false_if_the_property_does_not_exist
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        assert_equal 0, simplify(command(%Q|; return has_property(#{obj_ref(o)}, "foobar");|))
      end
    end
  end

  def test_that_has_property_returns_true_for_a_property_defined_directly_on_the_object
    SCENARIOS.each do |args|
      run_test_as('programmer') do
        o = create(*args)
        if args[0] == :anonymous
          definer = simplify(command(%Q|; return create($nothing);|))
          o = create(definer, args[1])
        else
          definer = o
        end
        add_property(definer, 'foo', 0, [player, ''])
        assert_equal 1, simplify(command(%Q|; return has_property(#{obj_ref(o)}, "foo");|))
      end
    end
  end

  def test_that_has_property_returns_true_for_an_inherited_property
    run_test_as('programmer') do
      parent = create(NOTHING)
      child = create(parent)
      add_property(parent, 'foo', 0, [player, ''])
      assert_equal 1, simplify(command(%Q|; return has_property(#{obj_ref(child)}, "foo");|))
    end
  end

  def test_that_has_property_returns_true_for_a_built_in_property
    run_test_as('programmer') do
      o = create(NOTHING)
      assert_equal 1, simplify(command(%Q|; return has_property(#{obj_ref(o)}, "name");|))
      assert_equal 1, simplify(command(%Q|; return has_property(#{obj_ref(o)}, "owner");|))
    end
  end

  def test_that_has_property_ignores_object_read_permission
    run_test_as('programmer') do
      o = create(NOTHING)
      set(o, 'r', 0)
      add_property(o, 'foo', 0, [player, ''])
      assert_equal 1, simplify(command(%Q|; return has_property(#{obj_ref(o)}, "foo");|))
    end
  end

  def test_that_has_property_ignores_the_propertys_own_read_permission
    run_test_as('programmer') do
      o = create(NOTHING)
      add_property(o, 'foo', 0, [player, ''])
      assert_equal 1, simplify(command(%Q|; return has_property(#{obj_ref(o)}, "foo");|))
    end
  end

end
