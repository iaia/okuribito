require "okuribito/version"
require "yaml"
require "active_support"
require "active_support/core_ext"

module Okuribito
  class OkuribitoPatch
    CLASS_METHOD_SYMBOL = ".".freeze
    INSTANCE_METHOD_SYMBOL = "#".freeze
    PATTERN = /\A(?<symbol>[#{CLASS_METHOD_SYMBOL}#{INSTANCE_METHOD_SYMBOL}])(?<method_name>.+)\z/

    def initialize(opt = {}, &callback)
      @callback = callback
      @opt ||= opt
    end

    module SimplePatchModule
      def define_patch(method_name, _patch, _id, _opt = {})
        define_method(method_name) do |*args|
          yield(to_s, caller) if block_given?
          super(*args)
        end
      end
    end

    module FunctionalPatchModule
      def define_patch(method_name, patch, id, opt = {})
        patch.instance_variable_set("@#{method_name}_#{id}_called", false)
        define_method(method_name) do |*args|
          if block_given? && !patch.instance_variable_get("@#{method_name}_#{id}_called")
            yield(to_s, caller)
            patch.instance_variable_set("@#{method_name}_#{id}_called", true) if opt[:once_detect]
          end
          super(*args)
        end
      end
    end

    def apply(yaml_path)
      yaml = YAML.load_file(yaml_path)
      yaml.each do |class_name, observe_methods|
        patch_okuribito(class_name, observe_methods)
      end
    end

    def self.module(opt, patch_name)
      if opt.present?
        if FunctionalPatchModule.const_defined?(patch_name)
          Module.new.extend(FunctionalPatchModule)
        else
          FunctionalPatchModule.const_set(patch_name, Module.new.extend(FunctionalPatchModule))
        end
      else
        Module.new.extend(SimplePatchModule)
      end
    end

    def patch_okuribito(class_name, observe_methods)
      return unless Object.const_defined?(class_name) && Object.const_get(class_name).is_a?(Class)

      callback = @callback
      opt ||= @opt
      klass = class_name.constantize

      klass.class_eval do
        i_method_patch = Okuribito::OkuribitoPatch.module(opt, "#{class_name}InstancePatch")
        c_method_patch = Okuribito::OkuribitoPatch.module(opt, "#{class_name}ClassPatch")
        i_method_patched = 0
        c_method_patched = 0

        observe_methods.each do |observe_method|
          next unless (md = PATTERN.match(observe_method))
          symbol = md[:symbol]
          method_name = md[:method_name].to_sym

          case symbol
          when INSTANCE_METHOD_SYMBOL
            next unless klass.instance_methods.include?(method_name)
            i_method_patch.module_eval do
              define_patch(method_name, i_method_patch, "i", opt) do |obj_name, caller_info|
                callback.call(method_name, obj_name, caller_info, class_name, symbol)
              end
            end
            i_method_patched += 1
          when CLASS_METHOD_SYMBOL
            next unless klass.respond_to?(method_name)
            c_method_patch.module_eval do
              define_patch(method_name, c_method_patch, "c", opt) do |obj_name, caller_info|
                callback.call(method_name, obj_name, caller_info, class_name, symbol)
              end
            end
            c_method_patched += 1
          end
        end
        prepend i_method_patch if i_method_patched > 0
        singleton_class.send(:prepend, c_method_patch) if c_method_patched > 0
      end
    end
  end
end
