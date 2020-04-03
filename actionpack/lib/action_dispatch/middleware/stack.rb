# frozen_string_literal: true

require "active_support/inflector/methods"
require "active_support/dependencies"

module ActionDispatch
  class MiddlewareStack
    class Middleware
      attr_reader :args, :kwargs, :block, :klass

      def initialize(klass, *args, **kwargs, &block)
        @klass  = klass
        @args   = args
        @kwargs = kwargs
        @block  = block
      end

      def name; klass.name; end

      def ==(middleware)
        case middleware
        when Middleware
          klass == middleware.klass
        when Class
          klass == middleware
        end
      end

      def inspect
        if klass.is_a?(Class)
          klass.to_s
        else
          klass.class.to_s
        end
      end

      def build(app)
        if kwargs.empty?
          klass.new(app, *args, &block)
        else
          klass.new(app, *args, **kwargs, &block)
        end
      end

      def build_instrumented(app)
        InstrumentationProxy.new(build(app), inspect)
      end
    end

    # This class is used to instrument the execution of a single middleware.
    # It proxies the `call` method transparently and instruments the method
    # call.
    class InstrumentationProxy
      EVENT_NAME = "process_middleware.action_dispatch"

      def initialize(middleware, class_name)
        @middleware = middleware

        @payload = {
          middleware: class_name,
        }
      end

      def call(env)
        ActiveSupport::Notifications.instrument(EVENT_NAME, @payload) do
          @middleware.call(env)
        end
      end
    end

    include Enumerable

    attr_accessor :middlewares

    def initialize
      @middlewares = []
      yield(self) if block_given?
    end

    def each
      @middlewares.each { |x| yield x }
    end

    def size
      middlewares.size
    end

    def last
      middlewares.last
    end

    def [](i)
      middlewares[i]
    end

    def unshift(klass, *args, **kwargs, &block)
      middlewares.unshift(build_middleware(klass, *args, **kwargs, &block))
    end
    ruby2_keywords(:unshift) if respond_to?(:ruby2_keywords, true)

    def initialize_copy(other)
      self.middlewares = other.middlewares.dup
    end

    def insert(index, klass, *args, **kwargs, &block)
      index = assert_index(index, :before)
      middlewares.insert(index, build_middleware(klass, *args, **kwargs, &block))
    end
    ruby2_keywords(:insert) if respond_to?(:ruby2_keywords, true)

    alias_method :insert_before, :insert

    def insert_after(index, *args, **kwargs, &block)
      index = assert_index(index, :after)
      insert(index + 1, *args, **kwargs, &block)
    end
    ruby2_keywords(:insert_after) if respond_to?(:ruby2_keywords, true)

    def swap(target, *args, **kwargs, &block)
      index = assert_index(target, :before)
      insert(index, *args, **kwargs, &block)
      middlewares.delete_at(index + 1)
    end
    ruby2_keywords(:swap) if respond_to?(:ruby2_keywords, true)

    def delete(target)
      middlewares.delete_if { |m| m.klass == target }
    end

    def move(target, source)
      source_index = assert_index(source, :before)
      source_middleware = middlewares.delete_at(source_index)

      target_index = assert_index(target, :before)
      middlewares.insert(target_index, source_middleware)
    end

    alias_method :move_before, :move

    def move_after(target, source)
      source_index = assert_index(source, :after)
      source_middleware = middlewares.delete_at(source_index)

      target_index = assert_index(target, :after)
      middlewares.insert(target_index + 1, source_middleware)
    end

    def use(klass, *args, **kwargs, &block)
      middlewares.push(build_middleware(klass, *args, **kwargs, &block))
    end
    ruby2_keywords(:use) if respond_to?(:ruby2_keywords, true)

    def build(app = nil, &block)
      instrumenting = ActiveSupport::Notifications.notifier.listening?(InstrumentationProxy::EVENT_NAME)
      middlewares.freeze.reverse.inject(app || block) do |a, e|
        if instrumenting
          e.build_instrumented(a)
        else
          e.build(a)
        end
      end
    end

    private
      def assert_index(index, where)
        i = index.is_a?(Integer) ? index : middlewares.index { |m| m.klass == index }
        raise "No such middleware to insert #{where}: #{index.inspect}" unless i
        i
      end

      def build_middleware(klass, *args, **kwargs, &block)
        Middleware.new(klass, *args, **kwargs, &block)
      end
  end
end
