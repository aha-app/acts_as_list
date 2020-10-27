module ActiveRecord
  module Acts #:nodoc:
    module List #:nodoc:
      def self.included(base)
        base.extend(ClassMethods)
      end

      # Add ability to skip callbacks for save/update.
      def self.skip_callbacks
        old_skip_cb = @skip_cb
        @skip_cb = true
        begin
          yield
        ensure
          @skip_cb = old_skip_cb
        end
      end

      # Return .skip_cb value.
      def self.skip_cb?
        @skip_cb == true
      end

      def self.with_delayed_updates
        @delayed_updates = true

        yield
      ensure
        @delayed_updates = false
      end

      def self.delayed_updates?
        @delayed_updates == true
      end

      # This +acts_as+ extension provides the capabilities for sorting and reordering a number of objects in a list.
      # The class that has this specified needs to have a +position+ column defined as an integer on
      # the mapped database table.
      #
      # Todo list example:
      #
      #   class TodoList < ActiveRecord::Base
      #     has_many :todo_items, order: "position"
      #   end
      #
      #   class TodoItem < ActiveRecord::Base
      #     belongs_to :todo_list
      #     acts_as_list scope: :todo_list
      #   end
      #
      #   todo_list.first.move_to_bottom
      #   todo_list.last.move_higher
      module ClassMethods
        # Configuration options are:
        #
        # * +column+ - specifies the column name to use for keeping the position integer (default: +position+)
        # * +scope+ - restricts what is to be considered a list. Given a symbol, it'll attach <tt>_id</tt>
        #   (if it hasn't already been added) and use that as the foreign key restriction. It's also possible
        #   to give it an entire string that is interpolated if you need a tighter scope than just a foreign key.
        #   Example: <tt>acts_as_list scope: 'todo_list_id = #{todo_list_id} AND completed = 0'</tt>
        # * +top_of_list+ - defines the integer used for the top of the list. Defaults to 1. Use 0 to make the collection
        #   act more like an array in its indexing.
        # * +add_new_at+ - specifies whether objects get added to the :top or :bottom of the list. (default: +bottom+)
        #                   `nil` will result in new items not being added to the list on create
        def acts_as_list(options = {})
          configuration = { column: "position", scope: "1 = 1", top_of_list: 1, add_new_at: :bottom}
          configuration.update(options) if options.is_a?(Hash)

          configuration[:scope] = "#{configuration[:scope]}_id".intern if configuration[:scope].is_a?(Symbol) && configuration[:scope].to_s !~ /_id$/
          rails_changes_method = Rails.version < "5.1" ? "changes" : "saved_changes"
          if configuration[:scope].is_a?(Symbol)
            scope_methods = %(
              def scope_condition
                { :#{configuration[:scope].to_s} => send(:#{configuration[:scope].to_s}) }
              end

              def scope_changed?
                #{rails_changes_method}.include?(scope_name.to_s)
              end
            )
          elsif configuration[:scope].is_a?(Array)
            scope_methods = %(
              def attrs
                %w(#{configuration[:scope].join(" ")}).inject({}) do |memo,column|
                  memo[column.intern] = read_attribute(column.intern); memo
                end
              end

              def scope_changed?
                (attrs.keys & #{rails_changes_method}.keys.map(&:to_sym)).any?
              end

              def scope_condition
                attrs
              end
            )
          else
            scope_methods = %(
              def scope_condition
                "#{configuration[:scope]}"
              end

              def scope_changed?() false end
            )
          end

          class_eval <<-EOV
            include ::ActiveRecord::Acts::List::InstanceMethods

            def acts_as_list_top
              #{configuration[:top_of_list]}.to_i
            end

            def acts_as_list_class
              ::#{self.name}
            end

            def position_column
              '#{configuration[:column]}'
            end

            def scope_name
              '#{configuration[:scope]}'
            end

            def add_new_at
              '#{configuration[:add_new_at]}'
            end

            def #{configuration[:column]}=(position)
              write_attribute(:#{configuration[:column]}, position)
              @position_changed = true
            end

            #{scope_methods}

            # only add to attr_accessible
            # if the class has some mass_assignment_protection

            if defined?(accessible_attributes) and !accessible_attributes.blank?
              attr_accessible :#{configuration[:column]}
            end

            after_destroy :update_positions, unless: -> { ActiveRecord::Acts::List.skip_cb? }
            after_create :update_positions, unless: -> { ActiveRecord::Acts::List.skip_cb? }
            after_update :update_positions_if_necessary, unless: -> { ActiveRecord::Acts::List.skip_cb? }

            scope :in_list, lambda { where("#{table_name}.#{configuration[:column]} IS NOT NULL") }

            def self.move_after_record_with_position(records, targeted_record_position)
              transaction do
                ActiveRecord::Acts::List.skip_callbacks do
                  records.reverse.each do |record|
                    record.update(#{configuration[:column]}: targeted_record_position.to_i + 1)
                    record.touch
                  end
                end

                records.first.update_positions(order: "DESC")
              end
            end
          EOV

          self.send(:before_create, "add_to_list_#{configuration[:add_new_at]}".to_sym)
        end
      end

      # All the methods available to a record that has had <tt>acts_as_list</tt> specified. Each method works
      # by assuming the object to be the item in the list, so <tt>chapter.move_lower</tt> would move that chapter
      # lower in the list of all chapters. Likewise, <tt>chapter.first?</tt> would return +true+ if that chapter is
      # the first in the list of all chapters.
      module InstanceMethods
        # https://github.com/brendon/acts_as_list/commit/75ec5b9b3a7e72a35bc5bd95ca9061d44ece2a76
        def position_before_save_changed?
          if ActiveRecord::VERSION::MAJOR >= 5 && ActiveRecord::VERSION::MINOR >= 1
            saved_change_to_attribute? position_column
          else
            send "#{position_column}_changed?"
          end
        end
        # https://github.com/brendon/acts_as_list/commit/64b6e15200f1e8eddfbeedf35a225258585b13b4
        def position_before_save
          if ActiveRecord::VERSION::MAJOR >= 5 && ActiveRecord::VERSION::MINOR >= 1
            send("#{position_column}_before_last_save")
          else
            send("#{position_column}_was")
          end
        end

        def update_positions_if_necessary
          update_positions if scope_changed? || position_before_save_changed?
        end

        def update_positions(order: nil)
          tn = ActiveRecord::Base.connection.quote_table_name acts_as_list_class.table_name
          pk = ActiveRecord::Base.connection.quote_column_name acts_as_list_class.primary_key
          up = ActiveRecord::Base.connection.quote_table_name "updated_positions"

          c = [position_before_save, position] if position_before_save && position

          sort_order = if order 
            order
          elsif c && c[0] && c[1] && (c[0] < c[1])
            # the position moved UP
            # We should order colliding positions by newest last
            "ASC"
          else
            # The position moved DOWN
            # we should order colliding positions by newest first
            "DESC"
          end

          nulls_go = if add_new_at == :top
            "FIRST"
          else
            "LAST"
          end

          window_function = acts_as_list_list
            .select("row_number() OVER ( ORDER BY #{position_column} ASC NULLS #{nulls_go}, updated_at #{sort_order}) AS #{position_column}, #{pk}")
            .to_sql

          sql = <<~SQL
            UPDATE #{tn} SET #{position_column} = #{up}.#{position_column}
            FROM (#{window_function}) AS updated_positions WHERE #{tn}.#{pk}=#{up}.#{pk}
          SQL

          if ActiveRecord::Acts::List.delayed_updates?
            delay(unique: true, in: 10.seconds)._execute_position_update!(sql)
          else
            _execute_position_update!(sql)
          end
        end

        # Exists as it's own method so it can be easily delayed. connection.delay.execute results
        # in a 'stack level too deep error' when serializing.
        def _execute_position_update!(sql)
          acts_as_list_class.connection.execute(sql)
        end

        def reload_position
          reload
        end

        def add_to_list_top
          self.assign_attributes({self.position_column => acts_as_list_list.minimum(self.position_column) || 1 }, {without_protection: true}) if self[self.position_column].nil?
        end

        def add_to_list_bottom
          self.assign_attributes({self.position_column => (acts_as_list_list.maximum(self.position_column) || 0) + 1}, {without_protection: true}) if self[self.position_column].nil?
        end

        def first?
          self.send(position_column) == acts_as_list_top
        end

        def last?
          self.send(position_column) == bottom_position_in_list
        end

        # Return the next n higher items in the list
        # selects all higher items by default
        def higher_items(limit=nil)
          limit ||= acts_as_list_list.count
          position_value = send(position_column)
          acts_as_list_list.
            where("#{position_column} < ?", position_value).
            where("#{position_column} >= ?", position_value - limit).
            limit(limit).
            order("#{acts_as_list_class.table_name}.#{position_column} ASC")
        end

        # Return the next lower item in the list.
        def lower_item
          lower_items(1).first
        end

        # Return the next n lower items in the list
        # selects all lower items by default
        def lower_items(limit=nil)
          limit ||= acts_as_list_list.count
          position_value = send(position_column)
          acts_as_list_list.
            where("#{position_column} > ?", position_value).
            where("#{position_column} <= ?", position_value + limit).
            limit(limit).
            order("#{acts_as_list_class.table_name}.#{position_column} ASC")
        end

        def default_position
          acts_as_list_class.columns_hash[position_column.to_s].default
        end

        def default_position?
          default_position && default_position.to_i == send(position_column)
        end

        # Sets the new position and saves it
        def set_list_position(new_position)
          write_attribute position_column, new_position
          save(validate: false)
          update_positions
        end

        private

        def acts_as_list_list
          acts_as_list_class.unscoped do
            acts_as_list_class.where(scope_condition)
          end
        end
      end
    end
  end
end
