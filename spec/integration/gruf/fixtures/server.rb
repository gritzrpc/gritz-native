# frozen_string_literal: true

require "json"
require "logger"
require "active_record"

$LOAD_PATH.unshift(File.expand_path("upstream/proto", __dir__))
require "Products_services_pb"
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ENV.fetch("GRUF_DEMO_DATABASE"))
ActiveRecord::Schema.define do
  create_table :products, force: true do |table|
    table.string :name
    table.float :price
    table.timestamps
  end
end
require_relative "upstream/application_record"
require_relative "upstream/product"
Product.create!(id: 1, name: "apple", price: 1.5)
Product.create!(id: 2, name: "pear", price: 2.5)

stopping = false
Signal.trap("TERM") { stopping = true }
mode = ARGV.fetch(0)
if mode == "original"
  require "gruf"
  Gruf.logger = Logger.new(File::NULL)
  Gruf.controllers_path = File.join(__dir__, "no-autoload")
  Gruf.interceptors = Gruf::Interceptors::Registry.new
  Gruf.interceptors.use(Gruf::Interceptors::Authentication::Basic, credentials: [{ password: "fixture-token" }])
  require_relative "upstream/products_controller"
  server = GRPC::RpcServer.new(pool_size: 4, poll_period: 0.1)
  port = server.add_http2_port("127.0.0.1:0", :this_port_is_insecure)
  server.handle(Rpc::Products::Service)
  thread = Thread.new { server.run }
  raise "original server did not start" unless server.wait_till_running(3)

  address = "127.0.0.1:#{port}"
else
  require "gritz/native"
  require "gritz/compat/gruf"
  require_relative "migrated/products_controller"
  require_relative "migrated/basic"
  config = Gritz::Configuration.new
  config.bind = "127.0.0.1:0"
  config.admin_bind = "127.0.0.1:0"
  config.threads = 4
  config.drain_delay = 0.0
  config.shutdown_timeout = 1.0
  config.middleware.use(Gritz::Compat::Gruf.interceptor(MigratedGrufDemo::Interceptors::Authentication::Basic),
                        credentials: [{ password: "fixture-token" }])
  server = Gritz::Testing::Server.start(config, controllers: [ProductsController], logger: Logger.new(File::NULL))
  address = server.address
end

status = IO.for_fd(3)
invalid = Product.new(name: "")
invalid.valid?
status.puts(JSON.generate(pid: Process.pid, address:, gruf_loaded: !defined?(Gruf).nil?,
                          invalid_model: invalid.invalid?, validation_errors: invalid.errors.to_hash))
status.close
sleep 0.01 until stopping
server.stop
thread&.join(3)
ActiveRecord::Base.connection_pool.disconnect!
