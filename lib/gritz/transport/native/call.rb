# frozen_string_literal: true

module Gritz
  module Transport
    class Native
      # Translates the public grpc views into the Call contract.
      # @api private
      class Call
        include Gritz::Call

        attr_reader :method_descriptor

        def initialize(method_descriptor:, view:, messages:, writer: nil)
          @method_descriptor = method_descriptor
          @view = view
          @messages = messages.to_enum
          @writer = writer
        end

        # SingleReqView and MultiReqView both expose these methods in grpc 1.83.
        # Client streams add each_remote_read; bidi passes a separate request enum.
        def metadata = @view.metadata
        # C-core represents an unset deadline as a Time at epoch - 1, not nil.
        def deadline = @view.deadline.to_r == -1 ? nil : @view.deadline
        def peer = @view.peer
        def peer_identity = @view.peer_cert
        def cancelled? = @view.cancelled?
        def trailing_metadata = @view.output_metadata
        def send_initial_metadata(metadata = {}) = @view.send_initial_metadata(metadata)
        def merge_initial_metadata(metadata = {}) = @view.merge_metadata_to_send(metadata)

        def read
          @messages.next
        rescue StopIteration
          nil
        end

        def each_message
          return enum_for(:each_message) unless block_given?

          loop do
            message = read
            break unless message

            yield message
          end
        end

        def write(message)
          raise Gritz::Errors::Internal, "RPC does not have a response stream" unless @writer

          @view.send_initial_metadata
          @writer << message
        end
      end
    end
  end
end
