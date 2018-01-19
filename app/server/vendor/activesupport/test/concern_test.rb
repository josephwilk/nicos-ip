require 'abstract_unit'
require 'active_support/concern'

class ConcernTest < ActiveSupport::TestCase
  module Baz
    extend ActiveSupport::Concern

    class_methods do
      def baz
        "baz"
      end

      def included_ran=(value)
        @@included_ran = value
      end

      def included_ran
        @@included_ran
      end
    end

    included do
      self.included_ran = true
    end

    def baz
      "baz"
    end
  end

  module Bar
    extend ActiveSupport::Concern

    include Baz

    module ClassMethods
      def baz
        "bar's baz + " + super
      end
    end

    def bar
      "bar"
    end

    def baz
      "bar+" + super
    end
  end

  module Foo
    extend ActiveSupport::Concern

    include Bar, Baz
  end

  def setup
    @klass = Class.new
  end

  def test_module_is_included_normally
    @klass.send(:include, Baz)
    assert_equal "baz", @klass.new.baz
    assert @klass.included_modules.include?(ConcernTest::Baz)
  end

  def test_class_methods_are_extended
    @klass.send(:include, Baz)
    assert_equal "baz", @klass.baz
    assert_equal ConcernTest::Baz::ClassMethods, (class << @klass; self.included_modules; end)[0]
  end

  def test_included_block_is_ran
    @klass.send(:include, Baz)
    assert_equal true, @klass.included_ran
  end

  def test_modules_dependencies_are_met
    @klass.send(:include, Bar)
    assert_equal "bar", @klass.new.bar
    assert_equal "bar+baz", @klass.new.baz
    assert_equal "bar's baz + baz", @klass.baz
    assert @klass.included_modules.include?(ConcernTest::Bar)
  end

  def test_dependencies_with_multiple_modules
    @klass.send(:include, Foo)
    assert_equal [ConcernTest::Foo, ConcernTest::Bar, ConcernTest::Baz], @klass.included_modules[0..2]
  end

  def test_raise_on_multiple_included_calls
    assert_raises(ActiveSupport::Concern::MultipleIncludedBlocks) do
      Module.new do
        extend ActiveSupport::Concern

        included do
        end

        included do
        end
      end
    end
  end
end
