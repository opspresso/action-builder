FROM opspresso/builder:v0.10.3

LABEL "com.github.actions.name"="Opspresso Builder"
LABEL "com.github.actions.description"="GitHub Action Builder"
LABEL "com.github.actions.icon"="box"
LABEL "com.github.actions.color"="blue"

LABEL version=v0.7.0
LABEL repository="https://github.com/opspresso/action-builder"
LABEL maintainer="Jungyoul Yu <me@nalbam.com>"
LABEL homepage="https://opspresso.com/"

ADD entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
