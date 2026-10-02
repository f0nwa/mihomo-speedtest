#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG=$ROOT/config-tools/config.example.yaml

ruby - "$CONFIG" <<'RUBY'
require "yaml"

config = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true)
rules = config.fetch("rules")

def inline_route(rules, host)
  rules.each do |rule|
    type, payload, target = rule.split(",", 3)
    case type
    when "DOMAIN"
      return target if host == payload
    when "DOMAIN-SUFFIX"
      return target if host == payload || host.end_with?(".#{payload}")
    when "MATCH"
      return payload
    end
  end
  nil
end

%w[opencode.ai api.opencode.ai].each do |host|
  route = inline_route(rules, host)
  abort "#{host}: expected AI route, got #{route.inspect}" unless route == "AI"
end

groups = config.fetch("proxy-groups").to_h { |g| [g.fetch("name"), g] }
outer_name = "⚡ Самые быстрые + Fallback"
outer = groups.fetch(outer_name)
pool = groups.fetch("⚡ Быстрый пул")
abort "outer type" unless outer["type"] == "fallback"
abort "fallback order" unless outer["proxies"] == ["⚡ Быстрый пул", "🛡️Fallback-Stable"]
abort "outer interval" unless outer["interval"] == 600
abort "outer timeout" unless outer.fetch("timeout", 5000) == 5000
abort "unexpected use" if outer.key?("use")
abort "pool type" unless pool["type"] == "url-test"
abort "pool source" unless pool["use"] == ["fast"]
abort "pool interval" unless pool["interval"] == 60
abort "pool timeout" unless pool.fetch("timeout", 5000) == 5000
abort "pool visibility" if pool["hidden"]
master = groups.fetch("Заблок. сервисы")
abort "master type" unless master["type"] == "select"
abort "master fallback reference" unless master.fetch("proxies").include?(outer_name)
abort "legacy outer name" if groups.key?("⚡ Самые быстрые")
groups.each_value do |g|
  next if g["name"] == outer_name
  abort "pool exposed" if (g["proxies"] || []).include?("⚡ Быстрый пул")
end
visit = lambda do |name, path|
  abort "group cycle: #{path + [name]}" if path.include?(name)
  (groups.fetch(name)["proxies"] || []).each do |child|
    visit.call(child, path + [name]) if groups.key?(child)
  end
end
groups.each_key { |name| visit.call(name, []) }

bulk_url = "http://www.gstatic.com/generate_204"
fast_url = "https://www.gstatic.com/generate_204"
providers = config.fetch("proxy-providers")
providers.each do |name, provider|
  hc = provider.fetch("health-check")
  seconds, url = name == "fast" ? [60, fast_url] : [300, bulk_url]
  abort "provider interval #{name}" unless hc["interval"] == seconds
  abort "provider url #{name}" unless hc["url"] == url
  abort "provider lazy #{name}" unless hc["lazy"] == true
  abort "provider timeout #{name}" unless hc["timeout"] == 5000
end
["🚀 Авто по пингу", "🛡️Fallback-Stable"].zip([600, 600]).each do |name, interval|
  g = groups.fetch(name)
  abort "bulk interval #{name}" unless g["interval"] == interval
  abort "bulk timeout #{name}" unless g.fetch("timeout", 5000) == 5000
  abort "bulk url" unless g["url"] == bulk_url
  abort "bulk lazy" unless g["lazy"] == true
end
RUBY

echo "test_config_routing: OK"
