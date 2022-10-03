# encoding: utf-8
require "logstash/codecs/base"
require "logstash/util/charset"
require "logstash/json"
require "logstash/event"
require 'logstash/plugin_mixins/ecs_compatibility_support'
require 'logstash/plugin_mixins/ecs_compatibility_support/target_check'
require 'logstash/plugin_mixins/validator_support/field_reference_validation_adapter'
require 'logstash/plugin_mixins/event_support/event_factory_adapter'
require 'logstash/plugin_mixins/event_support/from_json_helper'

# This codec may be used to decode (via inputs) and encode (via outputs)
# full JSON messages. If the data being sent is a JSON array at its root multiple events will be created (one per element).
#
# If you are streaming JSON messages delimited
# by '\n' then see the `json_lines` codec.
#
# Encoding will result in a compact JSON representation (no line terminators or indentation)
#
# If this codec recieves a payload from an input that is not valid JSON, then
# it will fall back to plain text and add a tag `_jsonparsefailure`. Upon a JSON
# failure, the payload will be stored in the `message` field.
class LogStash::Codecs::JSON < LogStash::Codecs::Base

  include LogStash::PluginMixins::ECSCompatibilitySupport(:disabled, :v1, :v8 => :v1)
  include LogStash::PluginMixins::ECSCompatibilitySupport::TargetCheck

  extend LogStash::PluginMixins::ValidatorSupport::FieldReferenceValidationAdapter

  include LogStash::PluginMixins::EventSupport::EventFactoryAdapter
  include LogStash::PluginMixins::EventSupport::FromJsonHelper

  config_name "json"

  # The character encoding used in this codec.
  # Examples include "UTF-8" and "CP1252".
  #
  # JSON requires valid UTF-8 strings, but in some cases, software that
  # emits JSON does so in another encoding (nxlog, for example). In
  # weird cases like this, you can set the `charset` setting to the
  # actual encoding of the text and Logstash will convert it for you.
  #
  # For nxlog users, you may to set this to "CP1252".
  config :charset, :validate => ::Encoding.name_list, :default => "UTF-8"

  # Defines a target field for placing decoded fields.
  # If this setting is omitted, data gets stored at the root (top level) of the event.
  # The target is only relevant while decoding data into a new event.
  config :target, :validate => :field_reference

  def initialize(*params)
    super

    @original_field = ecs_select[disabled: nil, v1: '[event][original]']

    @converter = LogStash::Util::Charset.new(@charset)
    @converter.logger = @logger
  end

  def register
    # no-op
  end

  def decode(data, &block)
    parse_json(@converter.convert(data), &block)
  end

  def encode(event)
    @on_event.call(event, event.to_json)
  end

  private

  def parse_json(json)
    events = events_from_json(json, targeted_event_factory)
    if events.size == 1
      event = events.first
      event.set(@original_field, json.dup.freeze) if @original_field && !event.include?(@original_field)
      yield event
    else
      events.each { |event| yield event }
    end
  rescue => e
    @logger.error("JSON parse error, original data now in message field", message: e.message, exception: e.class, data: json)
    yield parse_json_error_event(json)
  end

  def parse_json_error_event(json)
    event_factory.new_event("message" => json, "tags" => ["_jsonparsefailure"])
  end

end
