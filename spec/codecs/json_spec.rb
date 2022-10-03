require "logstash/devutils/rspec/spec_helper"
require "logstash/codecs/json"
require "logstash/event"
require "logstash/json"
require "insist"
require 'logstash/plugin_mixins/ecs_compatibility_support/spec_helper'

describe LogStash::Codecs::JSON, :ecs_compatibility_support do

  let(:options) { Hash.new }

  subject do
    LogStash::Codecs::JSON.new(options)
  end

  shared_examples :codec do

    context "#decode" do
      it "should return an event from json data" do
        data = {"foo" => "bar", "baz" => {"bah" => ["a","b","c"]}}
        subject.decode(LogStash::Json.dump(data)) do |event|
          insist { event.is_a? LogStash::Event }
          insist { event.get("foo") } == data["foo"]
          insist { event.get("baz") } == data["baz"]
          insist { event.get("bah") } == data["bah"]
        end
      end

      it "should be fast", :performance => true do
        json = '{"message":"Hello world!","@timestamp":"2013-12-21T07:01:25.616Z","@version":"1","host":"Macintosh.local","sequence":1572456}'
        iterations = 500000
        count = 0

        # Warmup
        10000.times { subject.decode(json) { } }

        start = Time.now
        iterations.times do
          subject.decode(json) do |event|
            count += 1
          end
        end
        duration = Time.now - start
        insist { count } == iterations
        puts "codecs/json rate: #{"%02.0f/sec" % (iterations / duration)}, elapsed: #{duration}s"
      end

      context "processing plain text" do
        it "falls back to plain text" do
          decoded = false
          subject.decode("something that isn't json") do |event|
            decoded = true
            insist { event.is_a?(LogStash::Event) }
            insist { event.get("message") } == "something that isn't json"
            insist { event.get("tags") }.include?("_jsonparsefailure")
          end
          insist { decoded } == true
        end
      end

      describe "scalar values" do
        shared_examples "given a value" do |value_arg|
          context "where value is #{value_arg}" do
            let(:value) { value_arg }
            let(:event) { LogStash::Event.new(value) }
            let(:value_json) { LogStash::Json.dump(value)}
            let(:event) do
              e = nil
              subject.decode(value_json) do |decoded|
                e = decoded
              end
              e
            end

            it "should store the value in 'message'" do
              expect(event.get("message")).to eql(value_json)
            end

            it "should have the json parse failure tag" do
              expect(event.get("tags")).to include("_jsonparsefailure")
            end
          end
        end

        include_examples "given a value", 123
        include_examples "given a value", "hello"
        include_examples "given a value", "-1"
        include_examples "given a value", " "
      end

      context "processing JSON with an array root" do
        let(:data) {
          [
            {"foo" => "bar"},
            {"foo" => "baz"}
          ]
        }
        let(:data_json) {
          LogStash::Json.dump(data)
        }

        it "should yield multiple events" do
          count = 0
          subject.decode(data_json) do |event|
            count += 1
          end
          expect(count).to eql(data.count)
        end

        it "should yield the correct objects" do
          index = 0
          subject.decode(data_json) do |event|
            expect(event.to_hash).to include(data[index])
            index += 1
          end
        end
      end

      context "processing weird binary blobs" do
        it "falls back to plain text and doesn't crash (LOGSTASH-1595)" do
          decoded = false
          blob = (128..255).to_a.pack("C*").force_encoding("ASCII-8BIT")
          subject.decode(blob) do |event|
            decoded = true
            insist { event.is_a?(LogStash::Event) }
            insist { event.get("message").encoding.to_s } == "UTF-8"
          end
          insist { decoded } == true
        end
      end

      context "when json could not be parsed" do

        let(:message) { "random_message" }

        it "add the failure tag" do
          subject.decode(message) do |event|
            expect(event).to include "tags"
          end
        end

        it "uses an array to store the tags" do
          subject.decode(message) do |event|
            expect(event.get('tags')).to be_a Array
          end
        end

        it "add a json parser failure tag" do
          subject.decode(message) do |event|
            expect(event.get('tags')).to include "_jsonparsefailure"
          end
        end
      end

      ecs_compatibility_matrix(:disabled, :v1, :v8 => :v1) do |ecs_select|

        before(:each) do
          allow_any_instance_of(described_class).to receive(:ecs_compatibility).and_return(ecs_compatibility)
        end

        context "with target" do

          let(:options) { super().merge('target' => 'root') }

          let(:message) { ' { "foo": "bar", "baz": { "0": [1, 2, 3], "1": true } } ' }

          context 'sample json' do

            let(:json) { '{ "foo": "bar", "baz": { "0": [1, 2, 3], "1": true } } ' }

            it "yields an event" do
              count = 0
              subject.decode(json) do |event|
                count += 1
                expect( event.include?("foo") ).to be false
                expect( event.include?("baz") ).to be false
                expect( event.get("[root][foo]") ).to eql 'bar'
                expect( event.get("[root][baz]")['1'] ).to be true
              end
              expect( count ).to eql 1
            end

            it 'set event.original in ECS mode' do
              subject.decode(json) do |event|
                if ecs_select.active_mode == :disabled
                  expect( event.get("[event][original]") ).to be nil
                else
                  expect( event.get("[event][original]") ).to eql json
                end
              end
            end

          end

          context 'json array' do

            let(:json) { '[ {"foo": "bar"}, {"baz": { "v": 1.0 } }, {}]' }

            it "yields multiple events" do
              count = 0
              subject.decode(json) do |event|
                expect( event.include?("foo") ).to be false
                expect( event.include?("baz") ).to be false
                count += 1
                case count
                when 1
                  expect( event.get("[root][foo]") ).to eql 'bar'
                when 2
                  expect( event.get("[root][baz]") ).to eql 'v' => 1.0
                end
              end
              expect( count ).to eql 3
            end

            it 'does not set event.original' do
              subject.decode(json) do |event|
                expect( event.include?("[event][original]") ).to be false
              end
            end

          end

        end

        context 'when JSON-coded event includes [event][original]' do
          let(:message) { ' { "foo": "bar", "baz": { "0": [1, 2, 3], "1": true }, "event" : { "original" : "actual_original" } } ' }

          it 'does not overwrite [event][original]' do
            count = 0
            subject.decode(message) do |event|
              count += 1
              expect( event.get('[event][original]') ).to eq("actual_original")
            end
            expect( count ).to eql 1
          end
        end

      end
    end

    context "#encode" do
      it "should return json data" do
        data = {"foo" => "bar", "baz" => {"bah" => ["a","b","c"]}}
        event = LogStash::Event.new(data)
        got_event = false
        subject.on_event do |e, d|
          insist { d.chomp } == event.to_json
          insist { LogStash::Json.load(d)["foo"] } == data["foo"]
          insist { LogStash::Json.load(d)["baz"] } == data["baz"]
          insist { LogStash::Json.load(d)["bah"] } == data["bah"]
          got_event = true
        end
        subject.encode(event)
        insist { got_event }
      end
    end

    context "target" do
      it "should return json data" do
        data = {"foo" => "bar", "baz" => {"bah" => ["a","b","c"]}}
        event = LogStash::Event.new(data)
        got_event = false
        subject.on_event do |e, d|
          insist { d.chomp } == event.to_json
          insist { LogStash::Json.load(d)["foo"] } == data["foo"]
          insist { LogStash::Json.load(d)["baz"] } == data["baz"]
          insist { LogStash::Json.load(d)["bah"] } == data["bah"]
          got_event = true
        end
        subject.encode(event)
        insist { got_event }
      end
    end
  end

  context "default parser choice" do
    it_behaves_like :codec
  end

end
