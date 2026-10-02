# frozen_string_literal: true

require "google/protobuf/descriptor_pb"
require "grpc/reflection/v1/reflection_services_pb"
require "grpc/reflection/v1alpha/reflection_services_pb"

module Gritz
  module Transport
    class Native
      # Exposes only registered services and their transitive protobuf imports.
      # @api private
      class Reflection
        PROTOCOLS = [Grpc::Reflection::V1, Grpc::Reflection::V1alpha].freeze

        def self.build(service_names)
          names = (service_names + PROTOCOLS.map { |types| types::ServerReflection::Service.service_name }).uniq.sort
          database = new(names)
          PROTOCOLS.map do |types|
            Class.new(types::ServerReflection::Service) do
              self.service_name = types::ServerReflection::Service.service_name
              define_method(:server_reflection_info) do |requests, _call|
                requests.lazy.map { |request| database.response(request, types) }
              end
            end.new
          end
        end

        def initialize(service_names)
          @services = service_names
          @files = {}
          @symbols = {}
          @messages = Set.new
          @extensions = {}
          @pool = Google::Protobuf::DescriptorPool.generated_pool
          service_names.each do |name|
            descriptor = @pool.lookup(name)
            unless descriptor.is_a?(Google::Protobuf::ServiceDescriptor)
              raise ConfigurationError, "Reflection requires a protobuf service descriptor for #{name}"
            end

            index_file(descriptor.file_descriptor.to_proto)
          end
        end

        def response(request, types)
          payload = case request.message_request
                    when :list_services
                      { list_services_response: types::ListServiceResponse.new(service: @services.map { |name| types::ServiceResponse.new(name:) }) }
                    when :file_by_filename
                      file_response(request.file_by_filename, types)
                    when :file_containing_symbol
                      file_response(@symbols[request.file_containing_symbol], types)
                    when :file_containing_extension
                      extension = request.file_containing_extension
                      file_response(@extensions[[extension.containing_type, extension.extension_number]], types)
                    when :all_extension_numbers_of_type
                      name = request.all_extension_numbers_of_type
                      if @messages.include?(name)
                        numbers = @extensions.keys.filter_map { |type, number| number if type == name }
                        { all_extension_numbers_response: types::ExtensionNumberResponse.new(base_type_name: name, extension_number: numbers.sort) }
                      else
                        error(types, GRPC::Core::StatusCodes::NOT_FOUND, "Message type not found")
                      end
                    else
                      error(types, GRPC::Core::StatusCodes::INVALID_ARGUMENT, "Reflection request is missing")
                    end
          types::ServerReflectionResponse.new(valid_host: request.host, original_request: request, **payload)
        end

        private

        def index_file(file)
          return if @files.key?(file.name)

          @files[file.name] = file
          index_messages(file.message_type, file.package, file.name)
          index_enums(file.enum_type, file.package, file.name)
          index_extensions(file.extension, file.package, file.name)
          file.service.each do |service|
            name = qualify(file.package, service.name)
            @symbols[name] = file.name
            service["method"].each { |method| @symbols["#{name}.#{method.name}"] = file.name }
          end
          file.dependency.each do |name|
            descriptor = @pool.lookup(name)
            raise ConfigurationError, "Reflection cannot find imported protobuf file #{name}" unless descriptor

            index_file(descriptor.to_proto)
          end
        end

        def index_messages(messages, scope, file)
          messages.each do |message|
            name = qualify(scope, message.name)
            @symbols[name] = file
            @messages.add(name)
            (message.field.to_a + message.oneof_decl.to_a).each { |field| @symbols["#{name}.#{field.name}"] = file }
            index_messages(message.nested_type, name, file)
            index_enums(message.enum_type, name, file)
            index_extensions(message.extension, name, file)
          end
        end

        def index_enums(enums, scope, file)
          enums.each do |enum|
            name = qualify(scope, enum.name)
            @symbols[name] = file
            enum.value.each { |value| @symbols["#{name}.#{value.name}"] = @symbols[qualify(scope, value.name)] = file }
          end
        end

        def index_extensions(extensions, scope, file)
          extensions.each do |extension|
            @symbols[qualify(scope, extension.name)] = file
            @extensions[[extension.extendee.delete_prefix("."), extension.number]] = file
          end
        end

        def qualify(scope, name) = scope.empty? ? name : "#{scope}.#{name}"

        def file_response(name, types)
          return error(types, GRPC::Core::StatusCodes::NOT_FOUND, "Protobuf file or symbol not found") unless @files.key?(name)

          seen = Set.new
          files = []
          visit = lambda do |file_name|
            return unless seen.add?(file_name)

            file = @files.fetch(file_name)
            file.dependency.each { |dependency| visit.call(dependency) }
            files << Google::Protobuf::FileDescriptorProto.encode(file)
          end
          visit.call(name)
          { file_descriptor_response: types::FileDescriptorResponse.new(file_descriptor_proto: files.reverse) }
        end

        def error(types, code, message)
          { error_response: types::ErrorResponse.new(error_code: code, error_message: message) }
        end
      end
    end
  end
end
