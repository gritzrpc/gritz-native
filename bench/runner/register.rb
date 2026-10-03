# frozen_string_literal: true

require "json"
require "open3"

container = ARGV.fetch(0) { abort "Usage: ruby bench/runner/register.rb SETUP_CONTAINER" }
response, status = Open3.capture2e("gh", "api", "--method", "POST", "repos/gritzrpc/gritz-native/actions/runners/registration-token")
abort "GitHub runner registration token request failed" unless status.success?
token = JSON.parse(response).fetch("token")
# Send the short-lived registration token over stdin; keep it out of command logs and workspace files.
command = <<~SH
  read -r registration_token
  exec ./config.sh --unattended --url https://github.com/gritzrpc/gritz-native \
    --token "$registration_token" --name gritz-benchmark-arm64 \
    --labels colima-arm64-2cpu-1g --work _work
SH
output, status = Open3.capture2e("docker", "exec", "-i", "-w", "/opt/actions-runner", container, "sh", "-c", command,
                                 stdin_data: "#{token}\n")
puts output.gsub(token, "[REDACTED]")
abort "Runner registration failed" unless status.success?
