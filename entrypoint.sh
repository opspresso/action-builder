#!/bin/sh

set -e

CMD=${1}

if [ -z "${CMD}" ]; then
  echo "CMD is not set."
  exit 1
fi

if [ -z "${GITHUB_TOKEN}" ]; then
  echo "GITHUB_TOKEN is not set."
  exit 1
fi

if [ -z "${TAG_NAME}" ]; then
  if [ -f ./target/TAG_NAME ]; then
    TAG_NAME=$(cat ./target/TAG_NAME | xargs)
  elif [ -f ./target/VERSION ]; then
    TAG_NAME=$(cat ./target/VERSION | xargs)
  fi
  if [ -z "${TAG_NAME}" ]; then
    echo "TAG_NAME is not set."
    exit 1
  fi
fi

if [ -z "${TARGET_COMMITISH}" ]; then
  TARGET_COMMITISH="master"
fi

if [ -z "${DRAFT}" ]; then
  DRAFT="false"
fi

if [ -z "${PRERELEASE}" ]; then
  PRERELEASE="false"
fi

_release_id() {
    URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
    RELEASE_ID=$(curl -s ${URL} | TAG_NAME=${TAG_NAME} jq -r '.[] | select(.tag_name == env.TAG_NAME) | .id' | xargs)
    echo "RELEASE_ID: ${RELEASE_ID}"
}

_release_assets() {
    LIST=/tmp/release-list
    ls ${ASSET_PATH} | sort > ${LIST}

    while read FILENAME; do
        FILEPATH=${ASSET_PATH}/${FILENAME}
        FILETYPE=$(file -b --mime-type "${FILEPATH}")
        FILESIZE=$(stat -c%s "${FILEPATH}")

        CONTENT_TYPE_HEADER="Content-Type: ${FILETYPE}"
        CONTENT_LENGTH_HEADER="Content-Length: ${FILESIZE}"

        echo "github releases assets ${RELEASE_ID} ${FILENAME} ${FILETYPE} ${FILESIZE}"
        URL="https://uploads.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}/assets?name=${FILENAME}"
        curl \
            -sSL \
            -X POST \
            -H "${AUTH_HEADER}" \
            -H "${CONTENT_TYPE_HEADER}" \
            -H "${CONTENT_LENGTH_HEADER}" \
            --data-binary @${FILEPATH} \
            ${URL}
    done < ${LIST}
}

_release() {
    AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"

    _release_id
    if [ ! -z "${RELEASE_ID}" ]; then
        echo "github releases delete ${RELEASE_ID}"
        URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/${RELEASE_ID}"
        curl \
            -sSL \
            -X DELETE \
            -H "${AUTH_HEADER}" \
            ${URL}
        sleep 1
    fi

    echo "github releases create ${TAG_NAME} ${DRAFT} ${PRERELEASE}"
    URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases"
    curl \
        -sSL \
        -X POST \
        -H "${AUTH_HEADER}" \
        --data @- \
        ${URL} <<END
{
 "tag_name": "${TAG_NAME}",
 "target_commitish": "${TARGET_COMMITISH}",
 "name": "${NAME}",
 "body": "${BODY}",
 "draft": ${DRAFT},
 "prerelease": ${PRERELEASE}
}
END
    sleep 1

    _release_id
    if [ -z "${RELEASE_ID}" ]; then
        echo "RELEASE_ID is not set."
        exit 1
    fi

    if [ ! -z "${ASSET_PATH}" ] && [ -d "${ASSET_PATH}" ]; then
        _release_assets
    fi
}

_release
