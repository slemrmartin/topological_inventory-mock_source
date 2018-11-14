require "mock_collector/openshift/event"

module MockCollector
  module Openshift
    class EventGenerator
      DEFAULT_INTERVAL = 5

      # Now only pods are enabled to generate events
      def self.start(entity_type, server, &block)
        return unless entity_type&.watch_enabled?

        generator = self.new(entity_type, server)

        generator.start(&block)
      end

      attr_reader :server

      delegate :class_for, :to => :server

      # @param entity_type [MockCollector::EntityType]
      # @param server [MockCollector::Openshift::Server]
      def initialize(entity_type, server)
        @entity_type = entity_type
        @server = server
        @check_interval = (::Settings.events&.check_interval || DEFAULT_INTERVAL).to_i
      end

      def start
        loop do
          %i(added modified deleted).each do |operation|
            create_events(operation) do |event|
              yield event unless event.nil?
            end
          end

          sleep(@check_interval)
        end
      end

      protected

      def create_events(operation)
        deleted_entities = @entity_type.stats[:deleted].value
        remaining_active_entities = @entity_type.stats[:total].value - deleted_entities

        # binding.pry
        events_count = events_per_check(operation)
        if operation == :deleted || operation == :modified
          events_count = [events_count, remaining_active_entities].min
        end

        (deleted_entities..deleted_entities + events_count - 1).each do |index|
          entity = case operation
                   when :added then @entity_type.add_entity
                   when :deleted then @entity_type.archive_entity
                   when :modified then @entity_type.modify_entity(index)
                   end
          yield make_event(entity, operation) unless entity.nil?
        end
      end

      def make_event(entity, operation)
        klass = class_for(:event)
        # save memory with 1 event per generator
        @event ||= klass.new
        @event.object = entity
        @event.type = klass::OPERATIONS[operation]
        @event
      end

      def events_per_check(operation)
        amount_unit = ::Settings.events&.per_hour_unit || :unknown
        amount_events = ::Settings.events&.per_hour&.send(operation).to_i

        events_per_hour = case amount_unit
                           when :fixed then amount_events
                           when :percents then @entity_type.stats[:total].value * (amount_events / 100.0)
                           else raise "Undefined settings events/per hour unit. Possible values: [:fixed, :percents]"
                           end
        events_per_check = (events_per_hour / 3600.0 * @check_interval).ceil

        events_per_check = [events_per_check, @entity_type.stats[:total].value].min

        events_per_check.zero? && operation == :added ? 1 : events_per_check
      end
    end
  end
end
