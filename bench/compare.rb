#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

abort "Usage: ruby bench/compare.rb BASELINE.json CURRENT.json" unless ARGV.size == 2
begin
  before, after = ARGV.map { |path| JSON.parse(File.read(path)) }
  [before, after].each do |result|
    raise "unsuccessful benchmark" unless result.fetch("passed") == true

    %w[rps p50_ns p95_ns].each do |metric|
      value = result.fetch("median").fetch(metric)
      raise "invalid #{metric}" unless value.is_a?(Numeric) && value.finite? && value.positive?
    end
  end
  %w[scenario transport settings environment].each do |key|
    raise "incomparable #{key}; collect a baseline on the same runner" unless before.fetch(key) == after.fetch(key)
  end
  changes = %w[rps p50_ns p95_ns].to_h do |metric|
    previous, current = [before, after].map { |result| result.fetch("median").fetch(metric) }
    degradation = metric == "rps" ? (previous - current) / previous : (current - previous) / previous
    [metric, degradation]
  end
  puts JSON.generate(degradation: changes)
  raise "performance degraded by at least 10%" if changes.values.any? { |value| value >= 0.1 - 1e-12 }
rescue StandardError => e
  abort "Benchmark comparison failed: #{e.message}"
end
