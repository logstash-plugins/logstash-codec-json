# encoding: utf-8
require "logstash/codecs/base"
require "logstash/util/charset"
require "logstash/json"
require "logstash/event"

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

  # When specified, build a json object based on the mapping structure,
  # taking necessary information from event.
  # This setting allows you to build specific JSON object inside an output configuration that support codecs.
  #
  # * JSON key can either be literal string  `"abc"` or interpolated string `"%{[event_accessor][subfield]}"`
  # * JSON value can either be literal scalar,array,object or interpolated string `"%{[field]}"`, or part of the event `"[field][nested_field]"` (array,hash or scalar)
  #
  # The difference between using interpolated string `"%{[field]}"` or only the accessor `"[field]"` is the resulting element type.
  # Using Interpolated string will always return a string value, while accessor will directly inject the event field as-is if it is an integer,boolean
  #
  config :encode_mapping, :validate => :hash

  def register
    @converter = LogStash::Util::Charset.new(@charset)
    @converter.logger = @logger
  end

  def decode(data, &block)
    parse(@converter.convert(data), &block)
  end

  def build_mapping(event, mapping)
    map = Hash.new
    mapping.each do |key, value|
      k = event.sprintf(key)
      v = build_mapping_value(event,value)
      map[k] = v
    end
    return map
  end

  def build_mapping_value(event,value)
    if value.is_a?(Hash)
      v = build_mapping(event, value)
    elsif value.is_a?(Array)
      v = value.map do |val|
        build_mapping_value(event, val)
      end
    else
      if /^(?:\[[^\[\]]+\])+$/.match(value)
        v = event.get(value)
      else
        v = event.sprintf(value)
      end
    end
    return v
  end

  def encode(event)
    if @encode_mapping
      encode_result = LogStash::Json.dump(build_mapping(event,@encode_mapping))
    else
      encode_result = event.to_json
    end
    @on_event.call(event, encode_result)
  end

  private

  def from_json_parse(json, &block)
    LogStash::Event.from_json(json).each { |event| yield event }
  rescue LogStash::Json::ParserError => e
    @logger.error("JSON parse error, original data now in message field", :error => e, :data => json)
    yield LogStash::Event.new("message" => json, "tags" => ["_jsonparsefailure"])
  end

  def legacy_parse(json, &block)
    decoded = LogStash::Json.load(json)

    case decoded
    when Array
      decoded.each {|item| yield(LogStash::Event.new(item)) }
    when Hash
      yield LogStash::Event.new(decoded)
    else
      @logger.error("JSON codec is expecting array or object/map", :data => json)
      yield LogStash::Event.new("message" => json, "tags" => ["_jsonparsefailure"])
    end
  rescue LogStash::Json::ParserError => e
    @logger.info("JSON parse failure. Falling back to plain-text", :error => e, :data => json)
    yield LogStash::Event.new("message" => json, "tags" => ["_jsonparsefailure"])
  rescue StandardError => e
    # This should NEVER happen. But hubris has been the cause of many pipeline breaking things
    # If something bad should happen we just don't want to crash logstash here.
    @logger.warn(
      "An unexpected error occurred parsing JSON data",
      :data => json,
      :message => e.message,
      :class => e.class.name,
      :backtrace => e.backtrace
    )
  end

  # keep compatibility with all v2.x distributions. only in 2.3 will the Event#from_json method be introduced
  # and we need to keep compatibility for all v2 releases.
  alias_method :parse, LogStash::Event.respond_to?(:from_json) ? :from_json_parse : :legacy_parse

end
