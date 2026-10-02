# frozen_string_literal: true

require "spec_helper"
require "base64"
require "digest"
require "json"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("fixtures/upstream/proto", __dir__))
require "Products_services_pb"

RSpec.describe "Official gruf-demo controller migration" do
  before(:context) do
    @directory = Dir.mktmpdir("gritz-gruf-demo")
    @children = {}
    %w[original migrated].each do |mode|
      reader, writer = IO.pipe
      log = File.join(@directory, "#{mode}.log")
      child = { reader:, log: }
      @children[mode] = child
      child[:pid] = Process.spawn({ "GRUF_DEMO_DATABASE" => File.join(@directory, "#{mode}.sqlite3"), "RACK_ENV" => "production" },
                                  RbConfig.ruby, File.expand_path("fixtures/server.rb", __dir__), mode,
                                  3 => writer, out: log, err: %i[child out], pgroup: true)
      writer.close
      expect(reader.wait_readable(10)).to be_truthy, File.read(log)
      line = reader.gets
      expect(line).not_to be_nil, File.read(log)
      child[:status] = JSON.parse(line)
      reader.close
    end
  end

  after(:context) do
    @children&.each_value do |child|
      child[:reader].close unless child[:reader].closed?
      pid = child[:pid]
      next unless pid
      next if (child[:exit] = Process.waitpid2(pid, Process::WNOHANG)&.last)

      begin
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        # Reap a child that exited before teardown as well.
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4
      until (child[:exit] = Process.waitpid2(pid, Process::WNOHANG)&.last)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          Process.kill("KILL", -pid)
          child[:exit] = Process.waitpid2(pid).last
          break
        end
        sleep 0.01
      end
    end
    @children&.each_value do |child| # rubocop:disable Style/CombinableLoops -- Reap every child before assertions can fail.
      next unless child[:pid]

      expect(child[:exit]).to be_success, File.read(child[:log])
      expect { Process.kill(0, child[:pid]) }.to raise_error(Errno::ESRCH)
    end
  ensure
    FileUtils.remove_entry(@directory) if @directory
  end

  def invoke(mode, method, request, auth: true)
    address = @children.fetch(mode).fetch(:status).fetch("address")
    channel = GRPC::Core::Channel.new(address, { "grpc.use_local_subchannel_pool" => 1, "grpc.enable_retries" => 0 }, :this_channel_is_insecure)
    stub = Rpc::Products::Stub.new(address, :this_channel_is_insecure, channel_override: channel)
    metadata = auth ? { "authorization" => "Basic #{Base64.strict_encode64('user:fixture-token')}" } : {}
    response = stub.public_send(method, request, deadline: Time.now + 5, metadata:)
    response.respond_to?(:each) ? response.map(&:to_h) : response.to_h
  rescue GRPC::BadStatus => e
    { code: e.code, message: e.details, error: JSON.parse(e.metadata.fetch("error-internal-bin")) }
  ensure
    channel&.close
  end

  it "changes only the controller superclass and keeps upstream files and license" do
    original = File.read(File.expand_path("fixtures/upstream/products_controller.rb", __dir__))
    migrated = File.read(File.expand_path("fixtures/migrated/products_controller.rb", __dir__))
    expect(migrated).to eq(original.sub("Gruf::Controllers::Base", "Gritz::Compat::Gruf::Controller"))
    expect(File.read(File.expand_path("fixtures/upstream/LICENSE.md", __dir__))).to include("BigCommerce", "Permission is hereby granted")
    expect(@children.fetch("original")[:status]).to include("gruf_loaded" => true, "invalid_model" => true)
    expect(@children.fetch("migrated")[:status]).to include("gruf_loaded" => false, "invalid_model" => true)
  end

  it "verifies each unmodified upstream fixture against its recorded SHA256 and source revision" do
    directory = File.expand_path("fixtures/upstream", __dir__)
    manifest = JSON.parse(File.read(File.join(directory, "SOURCES.json")))
    expect(manifest).to include("gruf_version" => "2.22.0", "demo_commit" => "4381b12192fdc9e5e00da89c4b1fd41c77857044")
    manifest.fetch("files").each do |entry|
      expect(Digest::SHA256.file(File.join(directory, entry.fetch("file"))).hexdigest).to eq(entry.fetch("sha256"))
      expect(entry.fetch("source")).to start_with("https://github.com/bigcommerce/")
    end
  end

  it "retains the original model's presence validation errors" do
    expect(@children.fetch("original")[:status].fetch("validation_errors")).to eq("name" => ["can't be blank"])
    expect(@children.fetch("migrated")[:status].fetch("validation_errors")).to eq(@children.fetch("original")[:status].fetch("validation_errors"))
  end

  it "matches the original unary response from the actual ActiveRecord model" do
    request = Rpc::GetProductReq.new(id: 1)
    original = invoke("original", :get_product, request)
    expect(original).to eq(product: { id: 1, name: "apple", price: 1.5 })
    expect(invoke("migrated", :get_product, request)).to eq(original)
  end

  it "matches the original server-streaming values and order" do
    request = Rpc::GetProductsReq.new(search: "", limit: 2)
    original = invoke("original", :get_products, request)
    expect(original).to eq([{ id: 1, name: "apple", price: 1.5 }, { id: 2, name: "pear", price: 2.5 }])
    expect(invoke("migrated", :get_products, request)).to eq(original)
  end

  it "matches the original client-streaming response" do
    request = [Rpc::Product.new(name: "first", price: 3), Rpc::Product.new(name: "second", price: 4)]
    original = invoke("original", :create_products, request)
    expect(original).to eq(products: [{ name: "first", price: 3.0 }, { name: "second", price: 4.0 }])
    expect(invoke("migrated", :create_products, request)).to eq(original)
  end

  it "matches the original bidi values and order" do
    request = [Rpc::Product.new(name: "first", price: 3), Rpc::Product.new(name: "second", price: 4)]
    original = invoke("original", :create_products_in_stream, request)
    expect(original).to eq([{ name: "first", price: 3.0 }, { name: "second", price: 4.0 }])
    expect(invoke("migrated", :create_products_in_stream, request)).to eq(original)
  end

  it "matches original not-found status, message and serialized application code" do
    request = Rpc::GetProductReq.new(id: 999)
    original = invoke("original", :get_product, request)
    expect(original).to include(code: 5, message: "Failed to find Product with ID: 999")
    expect(original[:error]).to include("app_code" => "product_not_found")
    expect(invoke("migrated", :get_product, request)).to eq(original)
  end

  it "preserves the original Basic authentication rejection before dispatch" do
    request = Rpc::GetProductReq.new(id: 1)
    original = invoke("original", :get_product, request, auth: false)
    expect(original).to include(code: 16, message: "")
    expect(invoke("migrated", :get_product, request, auth: false)).to eq(original)
  end
end
