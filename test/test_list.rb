# NOTE: following now done in helper.rb (better Readability)
require 'helper'

ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "acts_as_list_test")
ActiveRecord::Schema.verbose = false
ActiveRecord::Base.raise_in_transactional_callbacks = true

def setup_db(position_options = {})
  # AR caches columns options like defaults etc. Clear them!
  ActiveRecord::Base.connection.create_table :mixins do |t|
    t.column :pos, :integer, position_options
    t.column :active, :boolean, default: true
    t.column :parent_id, :integer
    t.column :parent_type, :string
    t.column :created_at, :datetime
    t.column :updated_at, :datetime
    t.column :state, :integer
  end

  mixins = [ Mixin, ListMixin, ListMixinSub1, ListMixinSub2, ListWithStringScopeMixin,
    ArrayScopeListMixin, ZeroBasedMixin, DefaultScopedMixin,
    DefaultScopedWhereMixin, TopAdditionMixin, NoAdditionMixin ]

  mixins << EnumArrayScopeListMixin if rails_4

  ActiveRecord::Base.connection.schema_cache.clear!
  mixins.each do |klass|
    klass.reset_column_information
  end
end

def setup_db_with_default
  setup_db default: 0
end

# Returns true if ActiveRecord is rails3,4 version
def rails_3
  defined?(ActiveRecord::VERSION) && ActiveRecord::VERSION::MAJOR >= 3
end

def rails_4
  defined?(ActiveRecord::VERSION) && ActiveRecord::VERSION::MAJOR >= 4
end

def teardown_db
  ActiveRecord::Base.connection.tables.each do |table|
    ActiveRecord::Base.connection.drop_table(table)
  end
end

class Mixin < ActiveRecord::Base
  self.table_name = 'mixins'
end

class ListMixin < Mixin
  acts_as_list column: "pos", scope: :parent

end

class ListMixinSub1 < ListMixin
end

class ListMixinSub2 < ListMixin
  if rails_3
    validates :pos, presence: true
  else
    validates_presence_of :pos
  end
end

class ListWithStringScopeMixin < Mixin
  acts_as_list column: "pos", scope: 'parent_id = #{parent_id}'
end

class ArrayScopeListMixin < Mixin
  acts_as_list column: "pos", scope: [:parent_id, :parent_type]
end

if rails_4
  class EnumArrayScopeListMixin < Mixin
    STATE_VALUES = %w(active archived)
    enum state: STATE_VALUES

    acts_as_list column: "pos", scope: [:parent_id, :state]
  end
end

class ZeroBasedMixin < Mixin
  acts_as_list column: "pos", top_of_list: 0, scope: [:parent_id]
end

class DefaultScopedMixin < Mixin
  acts_as_list column: "pos"
  default_scope { order('pos ASC') }
end

class DefaultScopedWhereMixin < Mixin
  acts_as_list column: "pos"
  default_scope { order('pos ASC').where(active: true) }

  def self.for_active_false_tests
    unscoped.order('pos ASC').where(active: false)
  end
end

class TopAdditionMixin < Mixin
  acts_as_list column: "pos", add_new_at: :top, scope: :parent_id
end

class NoAdditionMixin < Mixin
  acts_as_list column: "pos", add_new_at: nil, scope: :parent_id
end

class TheAbstractClass < ActiveRecord::Base
  self.abstract_class = true
  self.table_name = 'mixins'
end

class TheAbstractSubclass < TheAbstractClass
  acts_as_list column: "pos", scope: :parent
end

class TheBaseClass < ActiveRecord::Base
  self.table_name = 'mixins'
  acts_as_list column: "pos", scope: :parent
end

class TheBaseSubclass < TheBaseClass
end

class ActsAsListTestCase < Minitest::Test
  def teardown
    teardown_db
  end

  def setup
    setup_db
    (1..5).each do |counter|
      node = ListMixin.new parent_id: 5
      node.save!
    end
  end

  def assert_order order
    assert_equal order, ListMixin.order("id ASC").map(&:pos)
  end

  def test_initial_order
    assert_order [1,2,3,4,5]
  end

  def test_reorder_to_end
    l = ListMixin.where(pos: 3).first
    l.pos = 5
    l.save

    assert_order [1,2,5,3,4]
  end

  def test_reorder_to_beginning
    l = ListMixin.where(pos: 3).first
    l.pos = 1
    l.save

    assert_order [2,3,1,4,5]
  end

  def test_reorder_up
    l = ListMixin.where(pos: 3).first
    l.pos = 4
    l.save
    assert_order [1,2,4,3,5]
  end

  def test_reorder_down
    l = ListMixin.where(pos: 3).first
    l.pos = 2
    l.save

    assert_order [1,3,2,4,5]
  end

  def test_doesnt_save_if_not_needed
    $update_positions_called = false
    node = ListMixin.last

    def node.update_positions
      $update_positions_called = true
    end
    node.state = 12
    node.save

    assert_equal $update_positions_called, false
  end

  def test_skips_cb
    ActiveRecord::Acts::List.skip_callbacks do

      $update_positions_called = false
      node = ListMixin.last

      def node.update_positions
        $update_positions_called = true
      end
      node.pos = 25
      node.save

      assert_equal $update_positions_called, false
    end
  end
end

