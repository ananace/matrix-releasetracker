FROM ruby:alpine AS builder

COPY Gemfile matrix_releasetracker.gemspec /build/
COPY bin /build/bin/
COPY lib /build/lib/
WORKDIR /build

RUN apk add --no-cache ruby-dev postgresql-dev sqlite-dev gcc g++ make \
 && bundle config set --local path 'vendor' \
 && bundle config set --local without 'development' \
 && bundle install


FROM ruby:alpine

COPY --from=builder /build /app
WORKDIR /app

RUN apk add --no-cache sqlite-libs postgresql-libs \
 && bundle config set --local path 'vendor' \
 && bundle config set --local without 'development'

ENTRYPOINT [ "/usr/bin/bundle", "exec", "bin/tracker" ]
