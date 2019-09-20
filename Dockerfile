FROM python:3.7-stretch

LABEL "com.github.actions.name"="Opspresso Builder"
LABEL "com.github.actions.description"="GitHub Action Builder"
LABEL "com.github.actions.icon"="box"
LABEL "com.github.actions.color"="blue"

LABEL version=v0.0.2
LABEL repository="https://github.com/opspresso/action-builder"
LABEL maintainer="Jungyoul Yu <me@nalbam.com>"
LABEL homepage="https://opspresso.com/"

ENV AWSCLI_VERSION="1.16.242"

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl jq && \
    apt-get -y clean && apt-get -y autoclean && apt-get -y autoremove && \
    pip install --quiet --no-cache-dir awscli==${AWSCLI_VERSION}

ADD entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
