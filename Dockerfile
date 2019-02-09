FROM ruby:alpine

WORKDIR /app
COPY . /app/

RUN bundle install --without development

CMD [ "bundle", "exec", "bin/tracker" ]
