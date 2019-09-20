FROM python:3.7-stretch

LABEL "com.github.actions.name"="Opspresso Builder"
LABEL "com.github.actions.description"="GitHub Action Builder"
LABEL "com.github.actions.icon"="box"
LABEL "com.github.actions.color"="blue"

LABEL version=v0.0.4
LABEL repository="https://github.com/opspresso/action-builder"
LABEL maintainer="Jungyoul Yu <me@nalbam.com>"
LABEL homepage="https://opspresso.com/"

RUN apt-get install -y curl jq && \
    pip install --quiet --no-cache-dir awscli

ADD entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
