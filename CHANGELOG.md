## 2.1.0
 - Backward compatible support for `Event#from_json` method https://github.com/logstash-plugins/logstash-codec-json/pull/21

## 2.0.4
 - Reduce the size of the gem by removing the vendor files

## 2.0.3
 - fixed a spec, no change in functionality

## 2.0.0
 - Plugins were updated to follow the new shutdown semantic, this mainly allows Logstash to instruct input plugins to terminate gracefully,
   instead of using Thread.raise on the plugins' threads. Ref: https://github.com/elastic/logstash/pull/3895
 - Dependency on logstash-core update to 2.0

## 1.1.0
  - Handle scalar types (string/number) and be more defensive about crashable errors

## 1.0.1
  - Handle JSON arrays at source root by emitting multiple events
