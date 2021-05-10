# encoding: utf-8
require "logstash/codecs/base"
require "logstash/util/charset"
require "logstash/json"
require "logstash/event"

require 'logstash/plugin_mixins/ecs_compatibility_support'

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

  include LogStash::PluginMixins::ECSCompatibilitySupport

  config_name "json"

  # The character encoding used in this codec. Examples include "UTF-8" and
  # "CP1252".
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
  config :target, :validate => :string

  def register
    @converter = LogStash::Util::Charset.new(@charset)
    @converter.logger = @logger
  end

  def decode(data, &block)
    parse(@converter.convert(data), &block)
  end

  def encode(event)
    @on_event.call(event, event.to_json)
  end

  private

  def parse(json)
    decoded = LogStash::Json.load(json)

    case decoded
    when Array
      decoded.each { |item| yield(LogStash::Event.new(item)) }
    when Hash
      yield LogStash::Event.new(decoded)
    else
      @logger.error("JSON type error, original data now in message field", type: decoded.class, data: json)
      yield parse_error_event(json)
    end
  rescue => e
    @logger.error("JSON parse error, original data now in message field", message: e.message, exception: e.class, data: json)
    yield parse_error_event(json)
  end

  def parse_error_event(json)
    LogStash::Event.new("message" => json, "tags" => ["_jsonparsefailure"])
  end

end
