FROM opspresso/awscli
# FROM alpine

LABEL "com.github.actions.name"="Opspresso Builder"
LABEL "com.github.actions.description"="GitHub Action Builder"
LABEL "com.github.actions.icon"="box"
LABEL "com.github.actions.color"="blue"

LABEL version=v0.1.1
LABEL repository="https://github.com/opspresso/action-builder"
LABEL maintainer="Jungyoul Yu <me@nalbam.com>"
LABEL homepage="https://opspresso.com/"

# RUN apk -v --update add bash curl python py-pip groff less mailcap jq

# RUN pip install --upgrade awscli python-magic && \
#     apk -v --purge del py-pip && \
#     rm /var/cache/apk/*

ADD entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
