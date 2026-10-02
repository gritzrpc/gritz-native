# syntax=docker/dockerfile:1
FROM ruby:3.4-bookworm
WORKDIR /app/gritz-native
COPY --from=core /lib /app/gritz-core/lib
COPY --from=core /gritz-core.gemspec /app/gritz-core/gritz-core.gemspec
COPY lib ./lib
COPY gritz-native.gemspec ./gritz-native.gemspec
COPY examples/kubernetes/Gemfile ./Gemfile
RUN bundle install
COPY spec/fixtures/hello ./spec/fixtures/hello
COPY examples/kubernetes/config.rb ./examples/kubernetes/config.rb
COPY --from=tools /ghz /usr/local/bin/ghz
ENTRYPOINT ["bundle", "exec", "ruby", "-rgritz/core", "-rgritz/native", "-e", "exit Gritz::CLI.new(launch: true).run(ARGV)", "--"]
CMD ["start", "-C", "examples/kubernetes/config.rb"]
